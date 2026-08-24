-module(quod_ask_router).
-moduledoc """
Bounded origin-side transport router for distributed proof scopes.

The router owns correlation, authenticated-link binding and cleanup only.  It
never contains an Erlog state, an overlay, a continuation, or a Prolog term.
Opening a pinned request link is asynchronous; the pending scope is admitted
before any `scope_open` frame can be sent.  A remote handle is bound to this
exact router generation, wire binding, and request-link process, so a restarted
router cannot adopt a volatile session from its predecessor.
The same owner record retains the first fatal poison until a synchronous final
fence atomically checks link liveness and detaches that proof's remote scopes.

This is the only remote-scope protocol. Invalid non-scope frames are rejected
by the fixed `quod_scope_wire` decoder.
""".

-behaviour(gen_server).
-compile({no_auto_import, [unregister/1]}).

-include("quod_proof_limits.hrl").

-export([start_link/0,
         identify/3, ensure_scope/4, identity/3,
         command/3, cancel/2, close/2, finalize/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export_type([remote_handle/0]).

-ifdef(TEST).
-export([identify/4, ensure_scope/5, unregister/1,
         test_start_link/2, test_start_link/3, test_stats/1]).
-endif.

-define(KEY, {ask_router, node}).
-define(ID_BYTES, (?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS div 8)).
-define(AGENT_IDENTITY_CHANNEL, <<"quod.agent.identity">>).

-type binding() :: quod_scope_wire:binding().
-type remote_handle() ::
        {remote_scope, pid(), binary(), binding(), pid()}.
-type pending() :: {pending, pid(), binary(), reference()}.

-record(request, {
    command_seq :: pos_integer(),
    deliver = true :: boolean()
}).

-record(scope, {
    key :: {binary(), binary()},
    reuse_key :: {pid(), binary(), {binary(), binary()}},
    owner :: pid(),
    target_key :: binary(),
    binding :: binding(),
    open_ref :: reference(),
    open_frame :: binary(),
    request_channel :: binary(),
    request_link = undefined :: undefined | pid(),
    return_link = undefined :: undefined | pid(),
    status = opening :: opening | active,
    next_command_seq = 2 :: pos_integer(),
    last_command_seq = 1 :: non_neg_integer(),
    last_request_id :: binary(),
    next_event_seq = 1 :: pos_integer(),
    generation = undefined :: undefined | non_neg_integer(),
    dirty = undefined :: undefined | boolean(),
    pending = #{} :: #{binary() => #request{}}
}).

-record(owner, {
    mref :: reference(),
    proof_id = undefined :: undefined | binary(),
    poison = healthy :: healthy | {poisoned, term()},
    finalization = open :: open | {sealed, ok | {error, term()}},
    scopes = #{} :: map(),
    probes = #{} :: map(),
    identity = none :: none |
        {collecting, reference(), pid(), reference()} |
        {ready, quod_agent_identity:certificate()}
}).

-record(probe, {
    open_ref :: reference(),
    owner :: pid(),
    namespace :: binary(),
    request_id :: binary(),
    frame :: binary(),
    request_channel :: binary(),
    target_key = undefined :: undefined | binary(),
    request_link = undefined :: undefined | pid(),
    link_mref = undefined :: undefined | reference(),
    timer :: reference()
}).

-record(link, {
    mref :: reference(),
    scopes = #{} :: map()
}).

-record(inbound_identity, {
    link :: pid(),
    request_id :: <<_:128>>,
    timer :: reference(),
    token :: reference()
}).

-record(s, {
    generation :: binary(),
    origin_key :: binary(),
    return_channel :: binary(),
    subscribed = true :: boolean(),
    open_fun :: fun((binary(), term(), binary()) -> reference()),
    identify_fun :: fun((term(), binary()) -> reference()),
    scopes = #{} :: map(),
    reuse = #{} :: map(),
    opens = #{} :: map(),
    owners = #{} :: map(),
    retained_owners = 0 :: non_neg_integer(),
    owner_refs = #{} :: map(),
    peers = #{} :: map(),
    request_links = #{} :: map(),
    return_links = #{} :: map(),
    probes = #{} :: map(),
    probe_requests = #{} :: map(),
    probe_refs = #{} :: map(),
    identity_inbound = #{} :: map()
}).

%% ------------------------------------------------------------------
%% Public API
%% ------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link(quod_reg:via(?KEY), ?MODULE, [], []).

-spec ensure_scope(term(), binding(), quod_scope_wire:authentication(),
                   non_neg_integer()) ->
          {ok, remote_handle()} | pending() | {error, term()}.
ensure_scope(Endpoint, Binding, Authentication, RemainingMs) ->
    with_router(
      fun(Router) ->
          ensure_scope(Router, Endpoint, Binding, Authentication, RemainingMs)
      end).

-spec ensure_scope(gen_server:server_ref(), term(), binding(),
                   quod_scope_wire:authentication(), non_neg_integer()) ->
          {ok, remote_handle()} | pending() | {error, term()}.
ensure_scope(Router, Endpoint, Binding, Authentication, RemainingMs) ->
    guarded_call(
      Router,
      {ensure_scope, self(), Endpoint, Binding, Authentication, RemainingMs}).

-spec identify(term(), binary(), non_neg_integer()) ->
          pending() | {error, term()}.
identify(Endpoint, Namespace, RemainingMs) ->
    with_router(
      fun(Router) -> identify(Router, Endpoint, Namespace, RemainingMs) end).

-spec identify(gen_server:server_ref(), term(), binary(), non_neg_integer()) ->
          pending() | {error, term()}.
identify(Router, Endpoint, Namespace, RemainingMs) ->
    guarded_call(
      Router,
      {identify, self(), Endpoint, Namespace, RemainingMs}).

-spec command(remote_handle(), non_neg_integer(), term()) ->
          {ok, binary()} | {sent, binary()} | {error, term()}.
command({remote_scope, Router, RouterGeneration, Binding, RequestLink} = Handle,
        RemainingMs, Operation)
  when is_pid(Router), is_binary(RouterGeneration), is_pid(RequestLink) ->
    guarded_call(
      Router,
      {command, self(), Handle, RouterGeneration, Binding, RequestLink,
       RemainingMs, Operation});
command(_Handle, _RemainingMs, _Operation) ->
    {error, invalid_handle}.

-doc "Stop delivery of one timed-out command while retaining bounded correlation.".
-spec cancel(remote_handle(), binary()) -> ok | {error, term()}.
cancel({remote_scope, Router, RouterGeneration, Binding, RequestLink} = Handle,
       RequestId)
  when is_pid(Router), is_binary(RouterGeneration), is_pid(RequestLink),
       is_binary(RequestId) ->
    guarded_call(
      Router,
      {cancel, self(), Handle, RouterGeneration, Binding, RequestLink,
       RequestId});
cancel(_Handle, _RequestId) ->
    {error, invalid_handle}.

%% Queue the close before forgetting the local correlation entry.  Both calls
%% are sent by the same process, so the gen_server observes them in order.  A
%% target may still emit its terminal scope_closed event, but the origin never
%% waits for it.
-spec close(remote_handle(), non_neg_integer()) -> ok.
close(Handle, RemainingMs) ->
    _ = command(Handle, RemainingMs, scope_close),
    unregister(Handle).

-spec unregister(remote_handle()) -> ok.
unregister({remote_scope, Router, RouterGeneration, Binding, RequestLink} = Handle)
  when is_pid(Router), is_binary(RouterGeneration), is_pid(RequestLink) ->
    try gen_server:cast(
          Router,
          {unregister, self(), Handle, RouterGeneration, Binding, RequestLink})
    catch exit:_ -> ok
    end,
    ok;
unregister(_Handle) ->
    ok.

-doc "Atomically detach one proof's remote scopes and return its retained poison.".
-spec finalize(gen_server:server_ref(), <<_:256>>) -> ok | {error, term()}.
finalize(Router, <<_:256>> = ProofId) ->
    guarded_call(Router, {finalize, self(), ProofId});
finalize(_Router, _ProofId) ->
    {error, bad_proof_id}.

-doc "Acquire or reuse this proof's one origin-agent identity certificate.".
-spec identity(quod_client_goal:evidence(), <<_:256>>, non_neg_integer()) ->
          {ok, quod_agent_identity:certificate()} |
          {pending, pid(), binary(), reference()} | {error, term()}.
identity(Evidence, <<_:256>> = ProofId, RemainingMs)
  when is_map(Evidence), is_integer(RemainingMs), RemainingMs >= 0 ->
    with_router(
      fun(Router) ->
          guarded_call(
            Router,
            {identity, self(), Evidence, ProofId, RemainingMs})
      end);
identity(_Evidence, _ProofId, _RemainingMs) ->
    {error, invalid_request}.

with_router(Fun) ->
    case quod_reg:where(?KEY) of
        Router when is_pid(Router) -> Fun(Router);
        undefined -> {error, unavailable}
    end.

guarded_call(Router, Request) ->
    try gen_server:call(Router, Request)
    catch exit:_ -> {error, unavailable}
    end.

-ifdef(TEST).
test_start_link(NodeKey, OpenFun)
  when is_binary(NodeKey), byte_size(NodeKey) =:= 32, is_function(OpenFun, 3) ->
    IdentifyFun = fun(_Endpoint, _Channel) -> make_ref() end,
    test_start_link(NodeKey, OpenFun, IdentifyFun).

test_start_link(NodeKey, OpenFun, IdentifyFun)
  when is_binary(NodeKey), byte_size(NodeKey) =:= 32,
       is_function(OpenFun, 3), is_function(IdentifyFun, 2) ->
    gen_server:start_link(
      ?MODULE, {test, NodeKey, OpenFun, IdentifyFun}, []).

test_stats(Router) ->
    gen_server:call(Router, test_stats).
-endif.

%% ------------------------------------------------------------------
%% gen_server
%% ------------------------------------------------------------------

init([]) ->
    OriginKey = required_origin_key(),
    ReturnChannel = quod_scope_wire:return_channel(OriginKey),
    true = quod_reg:subscribe({channel, ReturnChannel}),
    true = quod_reg:subscribe({channel, ?AGENT_IDENTITY_CHANNEL}),
    {ok, new_state(OriginKey, ReturnChannel, true,
                   fun quod_quic:open_link_pinned/3,
                   fun quod_quic:open_link_identified/2)};
init({test, OriginKey, OpenFun, IdentifyFun}) ->
    ReturnChannel = quod_scope_wire:return_channel(OriginKey),
    {ok, new_state(
           OriginKey, ReturnChannel, false, OpenFun, IdentifyFun)}.

new_state(OriginKey, ReturnChannel, Subscribed, OpenFun, IdentifyFun) ->
    #s{generation = crypto:strong_rand_bytes(?ID_BYTES),
       origin_key = OriginKey,
       return_channel = ReturnChannel,
       subscribed = Subscribed,
       open_fun = OpenFun,
       identify_fun = IdentifyFun}.

required_origin_key() ->
    case application:get_env(quod, node_pubkey) of
        {ok, NodeKey} when is_binary(NodeKey), byte_size(NodeKey) =:= 32 ->
            NodeKey;
        _ ->
            error(node_pubkey_required)
    end.

handle_call({identify, Owner, Endpoint, Namespace, RemainingMs}, _From, S0) ->
    case start_probe(Owner, Endpoint, Namespace, RemainingMs, S0) of
        {ok, OpenRef, S1} -> {reply, pending(OpenRef, S1), S1};
        {error, _} = Error -> {reply, Error, S0}
    end;
handle_call(
  {ensure_scope, Owner, Endpoint, Binding, Authentication, RemainingMs},
  _From, S0) ->
    case validate_open(
           Owner, Endpoint, Binding, Authentication, RemainingMs, S0) of
        {reuse, #scope{status = active} = Scope} ->
            {reply, {ok, handle(Scope, S0)}, S0};
        {reuse, #scope{open_ref = OpenRef}} ->
            {reply, pending(OpenRef, S0), S0};
        {new, Fields, OpenFrame} ->
            case admit_scope(Owner, maps:get(proof_id, Fields),
                             maps:get(target_key, Fields), S0) of
                ok ->
                    {OpenRef, S1} = insert_opening_scope(
                                      Owner, Endpoint, Fields, OpenFrame, S0),
                    {reply, pending(OpenRef, S1), S1};
                {error, _} = Error ->
                    {reply, Error, S0}
            end;
        {error, _} = Error ->
            {reply, Error, S0}
    end;
handle_call(
  {identity, Owner, Evidence, ProofId, RemainingMs}, _From, S0)
  when is_pid(Owner) ->
    case ensure_identity(
           Owner, Evidence, ProofId, RemainingMs, S0) of
        {{ok, Certificate}, S1} ->
            {reply, {ok, Certificate}, S1};
        {{pending, Ref}, S1} ->
            {reply, {pending, self(), S1#s.generation, Ref}, S1};
        {{error, _} = Error, S1} ->
            {reply, Error, S1}
    end;
handle_call({finalize, Owner, ProofId}, _From, S0) ->
    {Result, S1} = finalize_owner(Owner, ProofId, S0),
    {reply, Result, S1};
handle_call(
  {command, Owner, Handle, RouterGeneration, Binding, RequestLink,
   RemainingMs, Operation}, _From, S0) ->
    case find_exact_scope(
           Owner, Handle, RouterGeneration, Binding, RequestLink, S0) of
        {ok, Scope0} ->
            case build_active_command(Scope0, RemainingMs, Operation) of
                {ok, ReplyKind, RequestId, Frame, Scope1} ->
                    quod_link:send_ordered(RequestLink, Frame),
                    {reply, {ReplyKind, RequestId}, put_scope(Scope1, S0)};
                {error, _} = Error ->
                    {reply, Error, S0}
            end;
        {error, _} = Error ->
            {reply, Error, S0}
    end;
handle_call(
  {cancel, Owner, Handle, RouterGeneration, Binding, RequestLink, RequestId},
  _From, S0) ->
    case find_exact_scope(
           Owner, Handle, RouterGeneration, Binding, RequestLink, S0) of
        {ok, Scope0 = #scope{pending = Pending0}} ->
            Pending1 = case maps:get(RequestId, Pending0, undefined) of
                           Request = #request{} ->
                               Pending0#{RequestId =>
                                             Request#request{deliver = false}};
                           undefined ->
                               Pending0
                       end,
            {reply, ok,
             put_scope(Scope0#scope{pending = Pending1}, S0)};
        {error, _} = Error ->
            {reply, Error, S0}
    end;
handle_call(test_stats, _From, S) ->
    {reply,
     #{generation => S#s.generation,
       scopes => map_size(S#s.scopes),
       owners => map_size(S#s.owners),
       retained_owners => S#s.retained_owners,
       entries => router_entry_count(S),
       peers => S#s.peers,
       opens => map_size(S#s.opens),
       probes => map_size(S#s.probes),
       request_links => map_size(S#s.request_links),
       return_links => map_size(S#s.return_links)},
     S};
handle_call(_Request, _From, S) ->
    {reply, {error, unknown_request}, S}.

pending(OpenRef, #s{generation = Generation}) ->
    {pending, self(), Generation, OpenRef}.

handle_cast(
  {unregister, Owner, Handle, RouterGeneration, Binding, RequestLink}, S0) ->
    case find_exact_scope(
           Owner, Handle, RouterGeneration, Binding, RequestLink, S0) of
        {ok, Scope} -> {noreply, drop_scope(Scope#scope.key, S0)};
        {error, _} -> {noreply, S0}
    end;
handle_cast(
  {identity_result, Owner, ProofId, Ref, Result}, S0) ->
    {noreply, finish_identity(Owner, ProofId, Ref, Result, S0)};
handle_cast(_Message, S) ->
    {noreply, S}.

handle_info({link_up, OpenRef, PeerKey, Channel, LinkPid}, S0)
  when is_reference(OpenRef), is_binary(PeerKey), is_binary(Channel),
       is_pid(LinkPid) ->
    {noreply, handle_link_up(OpenRef, PeerKey, Channel, LinkPid, S0)};
handle_info({link_error, OpenRef, PeerKey, Channel}, S0)
  when is_reference(OpenRef), is_binary(Channel) ->
    {noreply, handle_link_error(OpenRef, PeerKey, Channel, S0)};
handle_info(
  {quod_message, {PeerIdentity, ReturnLink}, Channel, Payload},
  S0 = #s{return_channel = Channel}) when is_pid(ReturnLink) ->
    S1 = case quod_scope_wire:decode_response(Payload) of
             {ok, Response = {scope_identity_response, _, _, _, _}} ->
                 handle_identity_response(
                   PeerIdentity, ReturnLink, Response, S0);
             {ok, Event = {scope_event, _, _, _, _, _, _, _}} ->
                 handle_event(PeerIdentity, ReturnLink, Event, S0);
             {error, _} -> S0
    end,
    {noreply, S1};
handle_info(
  {quod_message, {PeerIdentity, Link}, Channel, Payload}, S0)
  when Channel =:= ?AGENT_IDENTITY_CHANNEL, is_pid(Link) ->
    {noreply, handle_identity_request(PeerIdentity, Link, Payload, S0)};
handle_info(
  {quod_agent_attestation,
   {inbound_agent_identity, Key}, Result}, S0) ->
    {noreply, finish_inbound_identity(Key, Result, S0)};
handle_info({inbound_agent_identity_timeout, Key, Token}, S0) ->
    {noreply, expire_inbound_identity(Key, Token, S0)};
handle_info({probe_timeout, OpenRef}, S0) when is_reference(OpenRef) ->
    {noreply, fail_probe(OpenRef, timeout, S0)};
handle_info({'DOWN', MRef, process, Pid, Reason}, S0) ->
    {noreply, handle_down(MRef, Pid, Reason, S0)};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, S) ->
    maps:foreach(
      fun(_Key, Scope) -> send_direct_close(Scope) end,
      S#s.scopes),
    maps:foreach(
      fun(_OpenRef, Probe) -> cancel_probe_timer(Probe#probe.timer) end,
      S#s.probes),
    maps:foreach(
      fun(_Owner, #owner{identity = Identity}) ->
          cleanup_identity_collection(Identity)
      end, S#s.owners),
    maps:foreach(
      fun(_Key, #inbound_identity{timer = Timer}) ->
          _ = erlang:cancel_timer(Timer, [{async, true}, {info, false}])
      end, S#s.identity_inbound),
    case S#s.subscribed of
        true ->
            _ = try quod_reg:unsubscribe({channel, S#s.return_channel})
                catch _:_ -> ok
                end,
            _ = try quod_reg:unsubscribe({channel, ?AGENT_IDENTITY_CHANNEL})
                catch _:_ -> ok
                end;
        false -> ok
    end,
    ok.

%% ------------------------------------------------------------------
%% Admission and open
%% ------------------------------------------------------------------

start_probe(Owner, Endpoint, Namespace, RemainingMs, S0)
  when is_pid(Owner), is_binary(Namespace),
       is_integer(RemainingMs), RemainingMs >= 0,
       RemainingMs =< ?QUOD_SCOPE_WIRE_MAX_UINT64 ->
    case {quod_quic:valid_endpoint(Endpoint), admit_probe(Owner, S0)} of
        {false, _} -> {error, invalid_endpoint};
        {true, {error, _} = Error} -> Error;
        {true, ok} ->
            RequestId = new_id(),
            ProbeFrame = {scope_identity_probe, RequestId,
                          S0#s.origin_key, Namespace},
            case quod_scope_wire:encode_identity_probe(ProbeFrame) of
                {ok, Frame} ->
                    Channel = quod_scope_wire:request_channel(Namespace),
                    OpenRef = (S0#s.identify_fun)(Endpoint, Channel),
                    TimeoutMs = erlang:min(
                                  RemainingMs,
                                  ?QUOD_SCOPE_COMMAND_TIMEOUT_MS),
                    Timer = erlang:send_after(
                              TimeoutMs, self(), {probe_timeout, OpenRef}),
                    Probe = #probe{
                        open_ref = OpenRef, owner = Owner,
                        namespace = Namespace, request_id = RequestId,
                        frame = Frame, request_channel = Channel,
                        timer = Timer},
                    S1 = add_owner_probe(Owner, OpenRef, S0),
                    {ok, OpenRef,
                     S1#s{probes = (S1#s.probes)#{OpenRef => Probe},
                           probe_requests = (S1#s.probe_requests)#{
                               RequestId => OpenRef}}};
                {error, _} = Error -> Error
            end
    end;
start_probe(_Owner, _Endpoint, _Namespace, _RemainingMs, _S0) ->
    {error, invalid_probe}.

admit_probe(Owner, S) ->
    case probe_owner_admission(maps:get(Owner, S#s.owners, undefined)) of
        {error, _} = Error -> Error;
        ok ->
            case router_entry_count(S) >= ?QUOD_MAX_ROUTER_SCOPES of
                true -> {error, router_full};
                false ->
                    case owner_entry_count(Owner, S) >=
                         ?QUOD_MAX_ROUTER_SCOPES_PER_OWNER of
                        true -> {error, owner_scope_limit};
                        false -> ok
                    end
            end
    end.

probe_owner_admission(undefined) -> ok;
probe_owner_admission(#owner{finalization = {sealed, _}}) ->
    {error, proof_finalized};
probe_owner_admission(#owner{poison = {poisoned, Reason}}) ->
    {error, {proof_poisoned, Reason}};
probe_owner_admission(#owner{}) -> ok.

ensure_identity(Owner, Evidence, ProofId, RemainingMs,
                     S = #s{owners = Owners}) ->
    case maps:get(Owner, Owners, undefined) of
        #owner{proof_id = ProofId,
               identity = {ready, Certificate}} ->
            {{ok, Certificate}, S};
        #owner{proof_id = ProofId,
               identity = {collecting, Ref, _Pid, _MRef}} ->
            {{pending, Ref}, S};
        #owner{} = Existing ->
            case owner_admission(Existing, ProofId) of
                ok -> start_identity_collection(
                        Owner, Evidence, ProofId, RemainingMs, S);
                {error, _} = Error -> {Error, S}
            end;
        undefined ->
            start_identity_collection(
              Owner, Evidence, ProofId, RemainingMs, S)
    end.

start_identity_collection(
  Owner, Evidence, ProofId, RemainingMs,
  S = #s{owners = Owners, owner_refs = OwnerRefs})
  when RemainingMs > 0 ->
    case agent_identity_collection_input(Evidence, ProofId, RemainingMs) of
        {ok, Input} ->
            Router = self(),
            Ref = make_ref(),
            {Pid, MRef} = spawn_monitor(
                            fun() ->
                                Result = collect_agent_identity(
                                           Router, Ref, Input),
                                gen_server:cast(
                                  Router,
                                  {identity_result, Owner, ProofId,
                                   Ref, Result})
                            end),
            case maps:get(Owner, Owners, undefined) of
                undefined ->
                    OwnerMRef = monitor(process, Owner),
                    OwnerState = #owner{
                                   mref = OwnerMRef, proof_id = ProofId,
                                   identity =
                                       {collecting, Ref, Pid, MRef}},
                    S1 = put_owner(Owner, OwnerState, S),
                    {{pending, Ref},
                     S1#s{owner_refs = OwnerRefs#{OwnerMRef => Owner}}};
                Existing = #owner{} ->
                    S1 = put_owner(
                           Owner,
                           Existing#owner{
                             proof_id = ProofId,
                             identity = {collecting, Ref, Pid, MRef}}, S),
                    {{pending, Ref}, S1}
            end;
        {error, _} = Error -> {Error, S}
    end;
start_identity_collection(
  _Owner, _Evidence, _ProofId, _RemainingMs, S) ->
    {{error, timeout}, S}.

agent_identity_collection_input(
  Evidence = #{request := #{agent_namespace := Ns,
                            agent_genesis_anchor := Anchor,
                            not_after_ms := RequestNotAfter}},
  ProofId, RemainingMs) ->
    case quod_simplex:identity_view(Ns) of
        {ok, View = #{identity := {Ns, Anchor},
                      committee := [_ | _], committee_id := CommitteeId}} ->
            Now = quod_time:now_ms(),
            NotAfter = min(RequestNotAfter, Now + RemainingMs),
            case NotAfter > Now andalso
                 quod_agent_identity:statement(
                   Evidence, ProofId, CommitteeId, NotAfter) =/=
                     {error, invalid_request} of
                true ->
                    {ok, #{evidence => Evidence, proof_id => ProofId,
                           remaining_ms => RemainingMs,
                           not_after => NotAfter, view => View}};
                false -> {error, invalid_request}
            end;
        _ -> {error, unavailable}
    end;
agent_identity_collection_input(_Evidence, _ProofId, _RemainingMs) ->
    {error, invalid_request}.

finish_identity(Owner, ProofId, Ref, Result,
                     S = #s{owners = Owners}) ->
    case maps:get(Owner, Owners, undefined) of
        Existing = #owner{
                     proof_id = ProofId,
                     identity = {collecting, Ref, _Pid, MRef}} ->
            demonitor(MRef, [flush]),
            case Result of
                {ok, Certificate} ->
                    Owner ! {quod_agent_identity, Ref,
                             {ok, Certificate}},
                    put_owner(
                      Owner,
                      Existing#owner{identity = {ready, Certificate}}, S);
                {error, Reason} ->
                    Owner ! {quod_agent_identity, Ref, {error, Reason}},
                    put_owner(
                      Owner, Existing#owner{identity = none}, S)
            end;
        _ -> S
    end.

handle_identity_request(PeerIdentity, Link, Payload,
                             S = #s{identity_inbound = Inbound}) ->
    PeerKey = quod_link:peer_key(PeerIdentity),
    case {PeerKey, quod_agent_identity:decode_request(Payload),
          map_size(Inbound) < ?QUOD_MAX_ROUTER_SCOPES} of
        {<<_:256>>, {ok, Request =
                           {agent_identity_request, RequestId,
                            _ProofId, RequestBytes, Signature, _NotAfter}},
         true} ->
            Key = {PeerKey, RequestId},
            case {maps:is_key(Key, Inbound),
                  quod_client_goal:verify(RequestBytes, Signature)} of
                {false, {ok, #{request := #{agent_namespace := Ns}}}} ->
                    case quod_reg:where({quod_prolog, Ns}) of
                        Pid when is_pid(Pid) ->
                            Token = make_ref(),
                            Timer = erlang:send_after(
                                      ?QUOD_SCOPE_COMMAND_TIMEOUT_MS,
                                      self(),
                                      {inbound_agent_identity_timeout,
                                       Key, Token}),
                            quod_prolog:request_agent_attestation(
                              Ns, Request, self(),
                              {inbound_agent_identity, Key}),
                            S#s{identity_inbound = Inbound#{
                                  Key => #inbound_identity{
                                    link = Link,
                                    request_id = RequestId,
                                    timer = Timer,
                                    token = Token}}};
                        undefined -> S
                    end;
                _ -> S
            end;
        _ -> S
    end.

finish_inbound_identity(Key, Result,
                             S = #s{identity_inbound = Inbound}) ->
    case maps:take(Key, Inbound) of
        {#inbound_identity{link = Link,
                                request_id = RequestId,
                                timer = Timer}, Rest} ->
            _ = erlang:cancel_timer(
                  Timer, [{async, true}, {info, false}]),
            case Result of
                {ok, Signer,
                 {agent_identity_v1, _Network, _Identity, _ProofId,
                  _RequestDigest, _AgentRef, _SigningKey,
                  CommitteeId, NotAfter, active}, Signature} ->
                    {_PeerKey, RequestId} = Key,
                    case quod_agent_identity:encode_response(
                           {agent_identity_response, RequestId,
                            Signer, CommitteeId, NotAfter, Signature}) of
                        {ok, Frame} -> quod_link:send_ordered(Link, Frame);
                        {error, _} -> ok
                    end;
                _ -> ok
            end,
            S#s{identity_inbound = Rest};
        error -> S
    end.

expire_inbound_identity(Key, Token,
                             S = #s{identity_inbound = Inbound}) ->
    case maps:get(Key, Inbound, undefined) of
        #inbound_identity{token = Token} ->
            S#s{identity_inbound = maps:remove(Key, Inbound)};
        _ -> S
    end.

collect_agent_identity(
  _Router, Ref,
  #{evidence := Evidence,
    proof_id := ProofId,
    remaining_ms := RemainingMs,
    not_after := NotAfter,
    view := #{identity := Identity,
                     self := Self,
                     committee := Committee,
                     committee_id := CommitteeId,
                     route_candidates := InitialRoutes}}) ->
    true = quod_reg:subscribe({channel, ?AGENT_IDENTITY_CHANNEL}),
    try
        Routes = case quod_foreign_log:route_hints(Identity, InitialRoutes) of
                     {ok, Hints} -> Hints;
                     {error, _} -> InitialRoutes
                 end,
        {ok, Statement} = quod_agent_identity:statement(
                            Evidence, ProofId, CommitteeId, NotAfter),
        {ok, StatementBytes} =
            quod_agent_identity:statement_bytes(Statement),
        RequestId = new_id(),
        Request = {agent_identity_request, RequestId, ProofId,
                   maps:get(request_bytes, Evidence),
                   maps:get(signature, Evidence), NotAfter},
        {ok, Frame} = quod_agent_identity:encode_request(Request),
        quod_prolog:request_agent_attestation(
          element(1, Identity), Request, self(),
          {agent_identity_collection, Ref, Self}),
        {Opens, Waiting} = open_identity_routes(
                             Committee -- [Self], Routes, #{}),
        Deadline = quod_time:mono_ms() + RemainingMs,
        collect_agent_identity_loop(
          Ref, RequestId, Statement, StatementBytes, Committee,
          Routes, Frame, Deadline, Opens, Waiting, #{})
    after
        _ = try quod_reg:unsubscribe({channel, ?AGENT_IDENTITY_CHANNEL})
            catch _:_ -> ok
            end
    end.

open_identity_routes([], _Routes, Opens) -> {Opens, #{}};
open_identity_routes([Peer | Rest], Routes, Opens0) ->
    Candidates = proplists:get_value(Peer, Routes, []),
    {Opens1, Waiting1} = open_identity_candidate(
                           Peer, Candidates, Opens0),
    {Opens2, Waiting2} = open_identity_routes(Rest, Routes, Opens1),
    {Opens2, maps:merge(Waiting1, Waiting2)}.

open_identity_candidate(Peer, [Endpoint | Rest], Opens) ->
    OpenRef = quod_quic:open_link_pinned(
                Peer, Endpoint, ?AGENT_IDENTITY_CHANNEL),
    {Opens#{OpenRef => {Peer, Rest}}, #{Peer => true}};
open_identity_candidate(Peer, [], Opens) ->
    {Opens, #{Peer => true}}.

collect_agent_identity_loop(
  Ref, RequestId, Statement, StatementBytes, Committee, Routes,
  Frame, Deadline, Opens, Waiting, Signatures) ->
    case map_size(Signatures) >= quod_quorum:threshold(length(Committee)) of
        true ->
            SignatureRows = lists:sort(maps:to_list(Signatures)),
            case quod_agent_identity:certificate(
                   Statement, SignatureRows, Routes) of
                {ok, Certificate} -> {ok, Certificate};
                {error, _} -> {error, invalid_request}
            end;
        false ->
            Remaining = max(0, Deadline - quod_time:mono_ms()),
            case Remaining of
                0 -> {error, unavailable};
                _ ->
                    receive
                        {quod_agent_attestation,
                         {agent_identity_collection, Ref, Signer},
                         {ok, Signer, Statement, Signature}} ->
                            collect_agent_identity_loop(
                              Ref, RequestId, Statement, StatementBytes,
                              Committee, Routes, Frame, Deadline, Opens,
                              maps:remove(Signer, Waiting),
                              add_identity_signature(
                                Signer, Signature, StatementBytes,
                                Committee, Signatures));
                        {quod_agent_attestation,
                         {agent_identity_collection, Ref, Signer}, _Error} ->
                            collect_agent_identity_loop(
                              Ref, RequestId, Statement, StatementBytes,
                              Committee, Routes, Frame, Deadline, Opens,
                              maps:remove(Signer, Waiting), Signatures);
                        {link_up, OpenRef, Peer, ?AGENT_IDENTITY_CHANNEL, Link}
                          when is_pid(Link) ->
                            case maps:take(OpenRef, Opens) of
                                {{Peer, _Rest}, Opens1} ->
                                    quod_link:send_ordered(Link, Frame),
                                    collect_agent_identity_loop(
                                      Ref, RequestId, Statement,
                                      StatementBytes, Committee, Routes,
                                      Frame, Deadline, Opens1, Waiting,
                                      Signatures);
                                _ ->
                                    collect_agent_identity_loop(
                                      Ref, RequestId, Statement,
                                      StatementBytes, Committee, Routes,
                                      Frame, Deadline, Opens, Waiting,
                                      Signatures)
                            end;
                        {link_error, OpenRef, Peer, ?AGENT_IDENTITY_CHANNEL} ->
                            {Opens1, Waiting1} =
                                retry_identity_route(
                                  OpenRef, Peer, Opens, Waiting),
                            collect_agent_identity_loop(
                              Ref, RequestId, Statement, StatementBytes,
                              Committee, Routes, Frame, Deadline, Opens1,
                              Waiting1, Signatures);
                        {quod_message, {PeerIdentity, _Link},
                         ?AGENT_IDENTITY_CHANNEL, Payload} ->
                            Signatures1 =
                                accept_identity_response(
                                  quod_link:peer_key(PeerIdentity), Payload,
                                  RequestId, Statement, StatementBytes,
                                  Committee, Signatures),
                            collect_agent_identity_loop(
                              Ref, RequestId, Statement, StatementBytes,
                              Committee, Routes, Frame, Deadline, Opens,
                              Waiting, Signatures1)
                    after Remaining ->
                        {error, unavailable}
                    end
            end
    end.

retry_identity_route(OpenRef, Peer, Opens, Waiting) ->
    case maps:take(OpenRef, Opens) of
        {{Peer, Rest}, Opens1} ->
            case open_identity_candidate(Peer, Rest, Opens1) of
                {Opens2, _} -> {Opens2, Waiting}
            end;
        _ -> {Opens, Waiting}
    end.

accept_identity_response(
  <<_:256>> = Peer, Payload, RequestId,
  {agent_identity_v1, _Network, _Identity, _ProofId,
   _RequestDigest, _AgentRef, _SigningKey,
   CommitteeId, NotAfter, active},
  StatementBytes, Committee, Signatures) ->
    case quod_agent_identity:decode_response(Payload) of
        {ok, {agent_identity_response, RequestId, Peer,
              CommitteeId, NotAfter, Signature}} ->
            add_identity_signature(
              Peer, Signature, StatementBytes, Committee, Signatures);
        _ -> Signatures
    end;
accept_identity_response(
  _Peer, _Payload, _RequestId, _Statement, _StatementBytes,
  _Committee, Signatures) -> Signatures.

add_identity_signature(
  <<_:256>> = Signer, <<_:512>> = Signature,
  StatementBytes, Committee, Signatures) ->
    case lists:member(Signer, Committee) andalso
         not maps:is_key(Signer, Signatures) andalso
         quod_identity:verify(Signature, StatementBytes, Signer) of
        true -> Signatures#{Signer => Signature};
        false -> Signatures
    end;
add_identity_signature(
  _Signer, _Signature, _StatementBytes, _Committee, Signatures) ->
    Signatures.

validate_open(Owner, Endpoint, Binding, Authentication, RemainingMs,
              #s{origin_key = OriginKey, reuse = Reuse, scopes = Scopes})
  when is_pid(Owner) ->
    case open_fields(Binding, Authentication, OriginKey) of
        {ok, Fields} ->
            ProofId = maps:get(proof_id, Fields),
            TargetIdentity = maps:get(target_identity, Fields),
            ReuseKey = {Owner, ProofId, TargetIdentity},
            case maps:get(ReuseKey, Reuse, undefined) of
                ScopeKey when ScopeKey =/= undefined ->
                    case maps:get(ScopeKey, Scopes, undefined) of
                        #scope{} = Existing ->
                            case reusable_binding(Binding, Existing#scope.binding) of
                                true -> {reuse, Existing};
                                false -> {error, scope_binding_conflict}
                            end;
                        undefined ->
                            {error, unavailable}
                    end;
                undefined ->
                    validate_new_open(
                      Endpoint, Binding, Authentication, RemainingMs,
                      Fields#{reuse_key => ReuseKey})
            end;
        {error, _} = Error -> Error
    end;
validate_open(_Owner, _Endpoint, _Binding, _Authentication, _RemainingMs, _S) ->
    {error, invalid_owner}.

validate_new_open(Endpoint, Binding, Authentication, RemainingMs, Fields) ->
    RequestId = new_id(),
    Command = {scope_command, Binding, 1, RequestId, RemainingMs,
               {scope_open, Authentication}},
    case {quod_quic:valid_endpoint(Endpoint),
          quod_scope_wire:encode_command(Command)} of
        {false, _} -> {error, invalid_endpoint};
        {true, {ok, Frame}} ->
            {new, Fields#{open_request_id => RequestId}, Frame};
        {true, {error, _} = Error} -> Error
    end.

open_fields(
  Binding = {scope_binding, OriginKey, TargetKey, ProofId, ScopeId,
             _OriginIdentity, TargetIdentity = {TargetNs, Anchor}, _Mode,
             Principal, AuthenticationDigest},
  Authentication, OriginKey)
  when is_binary(TargetKey), byte_size(TargetKey) =:= 32,
       is_binary(ProofId), byte_size(ProofId) =:= 32,
       is_binary(ScopeId), byte_size(ScopeId) =:= ?ID_BYTES,
       is_binary(TargetNs), byte_size(TargetNs) > 0,
       is_binary(Anchor), byte_size(Anchor) =:= 32,
       is_binary(AuthenticationDigest), byte_size(AuthenticationDigest) =:= 32 ->
    case scope_authentication_matches(
           Principal, Authentication, AuthenticationDigest, OriginKey) of
        true ->
            {ok, #{binding => Binding,
                   key => {ProofId, ScopeId},
                   proof_id => ProofId,
                   target_key => TargetKey,
                   target_identity => TargetIdentity,
                   request_channel =>
                       quod_scope_wire:request_channel(TargetNs)}};
        false ->
            {error, invalid_binding}
    end;
open_fields(_Binding, _Authentication, _OriginKey) ->
    {error, invalid_binding}.

scope_authentication_matches({node, OriginKey}, node, Digest, OriginKey) ->
    quod_scope_wire:authentication_digest(node) =:= {ok, Digest};
scope_authentication_matches(
  Principal = {agent, _},
  {signed_goal, _RequestBytes, <<_:512>>, _Certificate} = Authentication,
  Digest, _OriginKey) ->
    quod_agent_ref:valid_principal(Principal) andalso
        quod_scope_wire:authentication_digest(Authentication) =:= {ok, Digest};
scope_authentication_matches(_Principal, _Authentication, _Digest, _OriginKey) ->
    false.

reusable_binding(
  {scope_binding, OriginKey, _NewTargetKey, ProofId, _NewScopeId,
   OriginIdentity, TargetIdentity, Mode, Principal, AuthenticationDigest},
  {scope_binding, OriginKey, _OldTargetKey, ProofId, _OldScopeId,
   OriginIdentity, TargetIdentity, Mode, Principal, AuthenticationDigest}) -> true;
reusable_binding(_, _) -> false.

admit_scope(Owner, ProofId, TargetKey, S) ->
    OwnerState = maps:get(Owner, S#s.owners, undefined),
    case owner_admission(OwnerState, ProofId) of
        {error, _} = Error -> Error;
        ok ->
            case router_entry_count(S) >= ?QUOD_MAX_ROUTER_SCOPES of
                true -> {error, router_full};
                false ->
                    OwnerCount = owner_entry_count(Owner, S),
                    PeerCount = maps:get(TargetKey, S#s.peers, 0),
                    case {OwnerCount >= ?QUOD_MAX_ROUTER_SCOPES_PER_OWNER,
                          PeerCount >= ?QUOD_MAX_ROUTER_SCOPES_PER_PEER} of
                        {true, _} -> {error, owner_scope_limit};
                        {_, true} -> {error, peer_scope_limit};
                        _ -> ok
                    end
            end
    end.

owner_admission(undefined, _ProofId) -> ok;
owner_admission(#owner{finalization = {sealed, _}}, _ProofId) ->
    {error, proof_finalized};
owner_admission(#owner{poison = {poisoned, Reason}}, _ProofId) ->
    {error, {proof_poisoned, Reason}};
owner_admission(#owner{proof_id = undefined}, _ProofId) -> ok;
owner_admission(#owner{proof_id = ProofId}, ProofId) -> ok;
owner_admission(#owner{}, _ProofId) -> {error, owner_proof_conflict}.

insert_opening_scope(Owner, Endpoint, Fields, OpenFrame, S0) ->
    TargetKey = maps:get(target_key, Fields),
    RequestChannel = maps:get(request_channel, Fields),
    OpenRef = (S0#s.open_fun)(TargetKey, Endpoint, RequestChannel),
    ScopeKey = maps:get(key, Fields),
    OpenRequestId = maps:get(open_request_id, Fields),
    Scope = #scope{
        key = ScopeKey,
        reuse_key = maps:get(reuse_key, Fields),
        owner = Owner,
        target_key = TargetKey,
        binding = maps:get(binding, Fields),
        open_ref = OpenRef,
        open_frame = OpenFrame,
        request_channel = RequestChannel,
        last_request_id = OpenRequestId,
        pending = #{OpenRequestId => #request{command_seq = 1}}
    },
    S1 = put_scope(Scope, S0),
    S2 = add_owner_scope(Owner, ScopeKey, S1),
    {OpenRef,
     S2#s{reuse = (S2#s.reuse)#{Scope#scope.reuse_key => ScopeKey},
          opens = (S2#s.opens)#{OpenRef => ScopeKey},
          peers = increment(TargetKey, S2#s.peers)}}.

router_entry_count(#s{scopes = Scopes, probes = Probes,
                      retained_owners = RetainedOwners}) ->
    map_size(Scopes) + map_size(Probes) + RetainedOwners.

owner_entry_count(Owner, #s{owners = Owners}) ->
    case maps:get(Owner, Owners, undefined) of
        #owner{scopes = Scopes, probes = Probes} ->
            map_size(Scopes) + map_size(Probes);
        undefined -> 0
    end.

add_owner_scope(OwnerPid, ScopeKey,
                S = #s{owners = Owners, owner_refs = OwnerRefs}) ->
    {ProofId, _ScopeId} = ScopeKey,
    case maps:get(OwnerPid, Owners, undefined) of
        undefined ->
            MRef = monitor(process, OwnerPid),
            Owner = #owner{mref = MRef, proof_id = ProofId,
                           scopes = #{ScopeKey => true}},
            S1 = put_owner(OwnerPid, Owner, S),
            S1#s{owner_refs = OwnerRefs#{MRef => OwnerPid}};
        Owner = #owner{proof_id = OwnerProofId, scopes = Scopes}
          when OwnerProofId =:= undefined; OwnerProofId =:= ProofId ->
            put_owner(
              OwnerPid,
              Owner#owner{proof_id = ProofId,
                          scopes = Scopes#{ScopeKey => true}}, S)
    end.

add_owner_probe(OwnerPid, OpenRef,
                S = #s{owners = Owners, owner_refs = OwnerRefs}) ->
    case maps:get(OwnerPid, Owners, undefined) of
        undefined ->
            MRef = monitor(process, OwnerPid),
            Owner = #owner{mref = MRef, probes = #{OpenRef => true}},
            S1 = put_owner(OwnerPid, Owner, S),
            S1#s{owner_refs = OwnerRefs#{MRef => OwnerPid}};
        Owner = #owner{probes = Probes} ->
            put_owner(
              OwnerPid, Owner#owner{probes = Probes#{OpenRef => true}}, S)
    end.

put_owner(OwnerPid, Owner,
          S = #s{owners = Owners, retained_owners = RetainedOwners}) ->
    WasRetained = retained_owner(maps:get(OwnerPid, Owners, undefined)),
    IsRetained = retained_owner(Owner),
    S#s{owners = Owners#{OwnerPid => Owner},
        retained_owners = retained_owner_transition(
                            WasRetained, IsRetained, RetainedOwners)}.

retained_owner(#owner{scopes = Scopes, probes = Probes}) ->
    map_size(Scopes) =:= 0 andalso map_size(Probes) =:= 0;
retained_owner(undefined) ->
    false.

retained_owner_transition(false, true, Count) -> Count + 1;
retained_owner_transition(true, false, Count) when Count > 0 -> Count - 1;
retained_owner_transition(Same, Same, Count) -> Count.

%% ------------------------------------------------------------------
%% Command and event correlation
%% ------------------------------------------------------------------

build_active_command(
  #scope{status = active}, _RemainingMs, {scope_open, _Authentication}) ->
    {error, {protocol_error, unexpected_scope_command}};
build_active_command(
  Scope = #scope{status = active, next_command_seq = CommandSeq,
                 pending = Pending},
  RemainingMs, Operation)
  when CommandSeq =< ?QUOD_SCOPE_WIRE_MAX_UINT64 ->
    ExpectsEvent = command_expects_event(Operation),
    case ExpectsEvent andalso
         map_size(Pending) >= ?QUOD_MAX_ROUTER_PENDING_PER_SCOPE of
        true ->
            {error, pending_request_limit};
        false ->
            build_bounded_command(
              Scope, RemainingMs, Operation, ExpectsEvent)
    end;
build_active_command(#scope{status = active}, _RemainingMs, _Operation) ->
    {error, command_sequence_exhausted}.

build_bounded_command(
  Scope = #scope{next_command_seq = CommandSeq, pending = Pending},
  RemainingMs, Operation, ExpectsEvent) ->
    RequestId = unique_request_id(Pending),
    Command = {scope_command, Scope#scope.binding, CommandSeq, RequestId,
               RemainingMs, Operation},
    case quod_scope_wire:encode_command(Command) of
        {ok, Frame} ->
            Pending1 = case ExpectsEvent of
                           true -> Pending#{
                               RequestId => #request{command_seq = CommandSeq}};
                           false -> Pending
                       end,
            Scope1 = Scope#scope{next_command_seq = CommandSeq + 1,
                                 last_command_seq = CommandSeq,
                                 last_request_id = RequestId,
                                 pending = Pending1},
            ReplyKind = case ExpectsEvent of true -> ok; false -> sent end,
            {ok, ReplyKind, RequestId, Frame, Scope1};
        {error, _} = Error -> Error
    end.

%% Commands with a correlated terminal event occupy one bounded pending slot.
%% Controller replies resume an existing invocation demand, so they do not.
%% Scope close is also reply-free: cleanup must remain sendable when every
%% pending slot is occupied. close/2 then unregisters in sender order; an
%% optional fast scope_closed event may remove the scope first.
command_expects_event(scope_close) -> false;
command_expects_event(scope_seal) -> true;
command_expects_event({scope_attest, _}) -> true;
command_expects_event({bind_group_effects, _, _}) -> true;
command_expects_event({submit_plan, _, _, _, _}) -> true;
command_expects_event({invoke_open, _, _, _, _}) -> true;
command_expects_event({invoke_next, _, _}) -> true;
command_expects_event({materialize, _, _, _, _}) -> true;
command_expects_event({batch_restore, _}) -> true;
command_expects_event({batch_release, _}) -> true;
command_expects_event(_) -> false.

handle_event(
  PeerIdentity, ReturnLink,
  Event = {scope_event, Binding, _EventSeq, _RequestId,
           _AcceptedSeq, _Generation, _Dirty, _Operation}, S0) ->
    case scope_key(Binding) of
        {ok, ScopeKey} ->
            validate_and_route_event(
              ScopeKey, PeerIdentity, ReturnLink, Event, S0);
        error -> S0
    end.

validate_and_route_event(
  ScopeKey, PeerIdentity, ReturnLink,
  {scope_event, Binding, EventSeq, RequestId, AcceptedSeq,
   Generation, Dirty, Operation},
  S0 = #s{scopes = Scopes}) ->
    case maps:get(ScopeKey, Scopes, undefined) of
        undefined -> S0;
        Scope0 ->
            Deliver = request_delivery(RequestId, Scope0),
            case validate_event_owner(
                   Scope0, PeerIdentity, ReturnLink, Binding, EventSeq,
                   RequestId, AcceptedSeq, Generation, Dirty, Operation) of
                {ok, Scope1} ->
                    {Scope2, S1} = bind_return_link(ReturnLink, Scope1, S0),
                    route_valid_event(
                      Operation, RequestId, Deliver, Scope2, S1);
                {error, Reason} ->
                    poison_owner(Scope0#scope.owner,
                                 {protocol_error, Reason}, S0)
            end
    end.

request_delivery(RequestId, #scope{pending = Pending}) ->
    case maps:get(RequestId, Pending, undefined) of
        #request{deliver = Deliver} -> Deliver;
        undefined -> true
    end.

validate_event_owner(
  Scope, PeerIdentity, ReturnLink, Binding, EventSeq, RequestId,
  AcceptedSeq, Generation, Dirty, Operation) ->
    Checks = [
        {peer_binding,
         quod_link:peer_key(PeerIdentity) =:= Scope#scope.target_key},
        {session_binding, Binding =:= Scope#scope.binding},
        {return_link, Scope#scope.return_link =:= undefined orelse
                      Scope#scope.return_link =:= ReturnLink},
        {event_sequence, EventSeq =:= Scope#scope.next_event_seq},
        {request_binding, request_matches(
                            RequestId, AcceptedSeq, Operation, Scope)},
        {generation, valid_generation(Generation, Dirty, Scope)},
        {session_binding, scope_error_matches_target(Operation, Scope)},
        {unexpected_scope_event, valid_status_event(Operation, Scope#scope.status)}
    ],
    case first_failed(Checks) of
        none ->
            Pending1 = case event_terminal(Operation) of
                           true -> maps:remove(RequestId, Scope#scope.pending);
                           false -> Scope#scope.pending
                       end,
            {ok, Scope#scope{
                    next_event_seq = EventSeq + 1,
                    generation = Generation,
                    dirty = Dirty,
                    pending = Pending1}};
        Reason -> {error, Reason}
    end.

scope_error_matches_target(
  {scope_error, Reason},
  #scope{binding = {scope_binding, _, _, _, _, _, {TargetNs, _}, _, _, _}}) ->
    quod_scope_wire:scope_error_matches_target(Reason, TargetNs);
scope_error_matches_target(_Operation, #scope{}) ->
    true.

request_matches(RequestId, AcceptedSeq, Operation,
                #scope{pending = Pending} = Scope) ->
    case maps:get(RequestId, Pending, undefined) of
        #request{command_seq = AcceptedSeq} -> true;
        _ -> valid_untracked_terminal(
               RequestId, AcceptedSeq, Operation, Scope)
    end.

valid_untracked_terminal(
  RequestId, AcceptedSeq, scope_closed,
  #scope{status = active, last_request_id = RequestId,
         last_command_seq = AcceptedSeq}) ->
    true;
valid_untracked_terminal(
  RequestId, AcceptedSeq, {scope_error, {Kind, TargetNs}},
  #scope{status = active,
         binding = {scope_binding, _, _, _, _, _, {TargetNs, _}, _, _, _},
         last_request_id = RequestId, last_command_seq = AcceptedSeq}) ->
    Kind =:= scope_expired orelse Kind =:= proof_limit_exceeded;
valid_untracked_terminal(_RequestId, _AcceptedSeq, _Operation, _Scope) ->
    false.

valid_generation(Generation, Dirty, #scope{generation = undefined}) ->
    Generation =:= 0 andalso Dirty =:= false;
valid_generation(Generation, Dirty,
                 #scope{generation = Current, dirty = CurrentDirty}) ->
    Generation > Current orelse
        (Generation =:= Current andalso Dirty =:= CurrentDirty).

valid_status_event({scope_opened, _BaseHeight}, opening) -> true;
valid_status_event({scope_error, _Reason}, opening) -> true;
valid_status_event({scope_opened, _BaseHeight}, active) -> false;
valid_status_event(_Operation, active) -> true;
valid_status_event(_Operation, opening) -> false.

%% Nested selection and controller events are requests made while the target
%% is still servicing one invocation demand.  They retain that demand's exact
%% RequestId/AcceptedCommandSeq until its final invocation result arrives.
event_terminal({nested_open, _, _, _, _}) -> false;
event_terminal({nested_next, _, _, _}) -> false;
event_terminal({nested_cancel, _, _}) -> false;
event_terminal({tx_activate, _, _, _, _}) -> false;
event_terminal({tx_finish, _, _, _, _, _}) -> false;
event_terminal({savepoint_allocate, _, _, _}) -> false;
event_terminal({savepoint_restore, _, _, _, _}) -> false;
event_terminal(_) -> true.

first_failed([]) -> none;
first_failed([{_Reason, true} | Rest]) -> first_failed(Rest);
first_failed([{Reason, false} | _]) -> Reason.

route_valid_event({scope_opened, BaseHeight}, _RequestId, _Deliver,
                  Scope0 = #scope{status = opening, owner = Owner,
                                  open_ref = OpenRef}, S0) ->
    Scope1 = Scope0#scope{status = active, open_frame = <<>>},
    S1 = put_scope(Scope1, S0#s{opens = maps:remove(OpenRef, S0#s.opens)}),
    Owner ! {quod_scope_open, OpenRef,
             {ok, handle(Scope1, S1), BaseHeight,
              Scope1#scope.generation, Scope1#scope.dirty}},
    S1;
route_valid_event({scope_error, Reason}, _RequestId, _Deliver,
                  Scope = #scope{status = opening, owner = Owner,
                                 open_ref = OpenRef}, S0) ->
    Owner ! {quod_scope_open, OpenRef, {error, Reason}},
    drop_scope(Scope#scope.key, S0);
route_valid_event(scope_closed, _RequestId, _Deliver, Scope, S0) ->
    drop_scope(Scope#scope.key, S0);
route_valid_event({scope_error, Reason} = Operation, RequestId, Deliver,
                  Scope = #scope{owner = Owner}, S0) ->
    _ = deliver_event(Deliver, Owner, Scope, RequestId, Operation, S0),
    poison_owner(Owner, {scope_error, Reason}, S0);
route_valid_event(Operation, RequestId, Deliver,
                  Scope = #scope{owner = Owner}, S0) ->
    _ = deliver_event(Deliver, Owner, Scope, RequestId, Operation, S0),
    put_scope(Scope, S0).

deliver_event(true, Owner, Scope, RequestId, Operation, S) ->
    Owner ! {quod_scope_event, handle(Scope, S), RequestId,
             Scope#scope.generation, Scope#scope.dirty, Operation};
deliver_event(false, _Owner, _Scope, _RequestId, _Operation, _S) ->
    ok.

%% ------------------------------------------------------------------
%% Link lifecycle and cleanup
%% ------------------------------------------------------------------

handle_probe_link_up(
  Probe = #probe{open_ref = OpenRef, request_channel = Channel,
                 request_link = undefined, frame = Frame},
  PeerKey, Channel, LinkPid, S0)
  when is_binary(PeerKey), byte_size(PeerKey) =:= 32 ->
    MRef = monitor(process, LinkPid),
    Probe1 = Probe#probe{target_key = PeerKey, request_link = LinkPid,
                         link_mref = MRef},
    quod_link:send_ordered(LinkPid, Frame),
    S0#s{probes = (S0#s.probes)#{OpenRef => Probe1},
         probe_refs = (S0#s.probe_refs)#{MRef => OpenRef}};
handle_probe_link_up(#probe{request_link = LinkPid},
                     _PeerKey, _Channel, LinkPid, S0) ->
    S0;
handle_probe_link_up(#probe{open_ref = OpenRef},
                     _PeerKey, _Channel, _LinkPid, S0) ->
    fail_probe(OpenRef, link_binding_mismatch, S0).

handle_identity_response(
  PeerIdentity, _ReturnLink,
  {scope_identity_response, RequestId, ResponseKey,
   TargetIdentity = {Namespace, _Anchor}, Role},
  S0 = #s{probe_requests = ProbeRequests, probes = Probes}) ->
    case maps:get(RequestId, ProbeRequests, undefined) of
        undefined -> S0;
        OpenRef ->
            Probe = maps:get(OpenRef, Probes),
            case quod_link:peer_key(PeerIdentity) =:=
                     Probe#probe.target_key andalso
                 ResponseKey =:= Probe#probe.target_key andalso
                 Namespace =:= Probe#probe.namespace of
                true ->
                    Probe#probe.owner !
                        {quod_scope_identity, OpenRef,
                         {ok, ResponseKey, TargetIdentity, Role}},
                    drop_probe(OpenRef, S0);
                false ->
                    fail_probe(OpenRef, identity_binding, S0)
            end
    end.

fail_probe(OpenRef, Reason, S0 = #s{probes = Probes}) ->
    case maps:get(OpenRef, Probes, undefined) of
        #probe{owner = Owner} ->
            Owner ! {quod_scope_identity, OpenRef, {error, Reason}},
            drop_probe(OpenRef, S0);
        undefined -> S0
    end.

drop_probe(OpenRef,
           S0 = #s{probes = Probes, probe_requests = Requests,
                   probe_refs = ProbeRefs}) ->
    case maps:take(OpenRef, Probes) of
        {Probe, Probes1} ->
            cancel_probe_timer(Probe#probe.timer),
            ProbeRefs1 = case Probe#probe.link_mref of
                             undefined -> ProbeRefs;
                             MRef ->
                                 demonitor(MRef, [flush]),
                                 maps:remove(MRef, ProbeRefs)
                         end,
            S1 = S0#s{
                probes = Probes1,
                probe_requests = maps:remove(Probe#probe.request_id, Requests),
                probe_refs = ProbeRefs1},
            remove_owner_probe(Probe#probe.owner, OpenRef, S1);
        error -> S0
    end.

cancel_probe_timer(Timer) ->
    _ = erlang:cancel_timer(Timer, [{async, true}, {info, false}]),
    ok.

handle_link_up(OpenRef, PeerKey, Channel, LinkPid,
               S0 = #s{opens = Opens, scopes = Scopes, probes = Probes}) ->
    case maps:get(OpenRef, Opens, undefined) of
        undefined ->
            case maps:get(OpenRef, Probes, undefined) of
                #probe{} = Probe ->
                    handle_probe_link_up(
                      Probe, PeerKey, Channel, LinkPid, S0);
                undefined -> S0
            end;
        ScopeKey ->
            Scope0 = maps:get(ScopeKey, Scopes),
            case PeerKey =:= Scope0#scope.target_key andalso
                 Channel =:= Scope0#scope.request_channel of
                true when Scope0#scope.request_link =:= undefined ->
                    Scope1 = Scope0#scope{request_link = LinkPid},
                    S1 = bind_request_link(LinkPid, Scope1, S0),
                    quod_link:send_ordered(LinkPid, Scope1#scope.open_frame),
                    put_scope(Scope1, S1);
                true when Scope0#scope.request_link =:= LinkPid ->
                    %% An idempotent transport notification must not duplicate
                    %% the accepted scope_open command.
                    S0;
                true ->
                    fail_open(Scope0, link_binding_mismatch, S0);
                false ->
                    fail_open(Scope0, link_binding_mismatch, S0)
            end
    end.

handle_link_error(OpenRef, PeerKey, Channel,
                  S0 = #s{opens = Opens, scopes = Scopes, probes = Probes}) ->
    case maps:get(OpenRef, Opens, undefined) of
        undefined ->
            case maps:get(OpenRef, Probes, undefined) of
                #probe{request_channel = Channel} ->
                    %% The identified dial has no expected key before TLS
                    %% authentication, so only its exact ref/channel bind this
                    %% asynchronous failure.
                    _ = PeerKey,
                    fail_probe(OpenRef, unavailable, S0);
                #probe{} -> fail_probe(OpenRef, link_binding_mismatch, S0);
                undefined -> S0
            end;
        ScopeKey ->
            Scope = maps:get(ScopeKey, Scopes),
            case PeerKey =:= Scope#scope.target_key andalso
                 Channel =:= Scope#scope.request_channel of
                true -> fail_open(Scope, unavailable, S0);
                false -> fail_open(Scope, link_binding_mismatch, S0)
            end
    end.

fail_open(#scope{owner = Owner, open_ref = OpenRef, key = ScopeKey}, Reason, S0) ->
    Owner ! {quod_scope_open, OpenRef, {error, Reason}},
    drop_scope(ScopeKey, S0).

handle_down(MRef, Pid, Reason,
            S = #s{owner_refs = OwnerRefs,
                   probe_refs = ProbeRefs,
                   request_links = RequestLinks,
                   return_links = ReturnLinks}) ->
    case maps:get(MRef, OwnerRefs, undefined) of
        Owner when is_pid(Owner) ->
            drop_owner(Owner, S);
        undefined ->
            case maps:get(MRef, ProbeRefs, undefined) of
                OpenRef when is_reference(OpenRef) ->
                    fail_probe(OpenRef, {request_link_down, Reason}, S);
                undefined ->
                    case identity_collector_owner(MRef, S#s.owners) of
                        {ok, Owner, ProofId, Ref} ->
                            finish_identity(
                              Owner, ProofId, Ref, {error, unavailable}, S);
                        error ->
                            case link_down_kind(
                                   MRef, Pid, RequestLinks, ReturnLinks) of
                                {request, ScopeKeys} ->
                                    poison_scope_owners(ScopeKeys, S);
                                {return, ScopeKeys} ->
                                    poison_scope_owners(ScopeKeys, S);
                                none -> S
                            end
                    end
            end
    end.

identity_collector_owner(MRef, Owners) ->
    maps:fold(
      fun(Owner,
          #owner{proof_id = ProofId,
                 identity = {collecting, Ref, _Pid, MRef0}}, error)
            when MRef0 =:= MRef -> {ok, Owner, ProofId, Ref};
         (_Owner, _State, Acc) -> Acc
      end, error, Owners).

link_down_kind(MRef, Pid, RequestLinks, ReturnLinks) ->
    case maps:get(Pid, RequestLinks, undefined) of
        #link{mref = MRef, scopes = ScopeKeys} -> {request, ScopeKeys};
        _ ->
            case maps:get(Pid, ReturnLinks, undefined) of
                #link{mref = MRef, scopes = ScopeKeys} -> {return, ScopeKeys};
                _ -> none
            end
    end.

poison_scope_owners(ScopeKeys, S0) ->
    Failures = maps:fold(
                 fun(ScopeKey, _True, Acc) ->
                     case maps:get(ScopeKey, S0#s.scopes, undefined) of
                         #scope{owner = Owner} = Scope ->
                             Failure = scope_unreachable(Scope),
                             maps:update_with(
                               Owner,
                               fun(Existing) -> erlang:min(Existing, Failure) end,
                               Failure, Acc);
                         undefined -> Acc
                     end
                 end, #{}, ScopeKeys),
    maps:fold(fun(Owner, Reason, Acc) -> poison_owner(Owner, Reason, Acc) end,
              S0, Failures).

poison_owner(Owner, Reason, S0 = #s{owners = Owners}) ->
    case maps:get(Owner, Owners, undefined) of
        Owner0 = #owner{poison = healthy, scopes = ScopeKeys} ->
            Owner1 = Owner0#owner{poison = {poisoned, Reason}},
            S1 = put_owner(Owner, Owner1, S0),
            maps:foreach(
              fun(ScopeKey, _True) ->
                  case maps:get(ScopeKey, S1#s.scopes, undefined) of
                      #scope{status = opening, open_ref = OpenRef} ->
                          Owner ! {quod_scope_open, OpenRef, {error, Reason}};
                      #scope{} = Scope ->
                          Owner ! {quod_scope_down,
                                   handle_or_pending(Scope, S1), Reason};
                      undefined -> ok
                  end
              end, ScopeKeys),
            clear_owner_resources(Owner, S1);
        #owner{poison = {poisoned, _}} -> S0;
        undefined -> S0
    end.

finalize_owner(Owner, ProofId, S0 = #s{owners = Owners}) ->
    case maps:get(Owner, Owners, undefined) of
        undefined -> {ok, S0};
        #owner{proof_id = OtherProofId}
          when OtherProofId =/= undefined, OtherProofId =/= ProofId ->
            {{error, not_allowed}, S0};
        #owner{finalization = {sealed, Result}} ->
            {Result, S0};
        #owner{} ->
            S1 = poison_dead_links(Owner, S0),
            seal_owner(Owner, ProofId, S1)
    end.

seal_owner(Owner, ProofId, S0 = #s{owners = Owners}) ->
    case maps:get(Owner, Owners, undefined) of
        undefined -> {ok, S0};
        #owner{finalization = {sealed, Result}} -> {Result, S0};
        Owner0 = #owner{poison = Poison} ->
            Result = case Poison of
                         healthy -> ok;
                         {poisoned, PoisonReason} -> {error, PoisonReason}
                     end,
            Owner1 = Owner0#owner{proof_id = ProofId,
                                  finalization = {sealed, Result}},
            S1 = put_owner(Owner, Owner1, S0),
            {Result, clear_owner_resources(Owner, S1)}
    end.

poison_dead_links(Owner, S0 = #s{owners = Owners, scopes = Scopes}) ->
    case maps:get(Owner, Owners, undefined) of
        #owner{poison = healthy, scopes = ScopeKeys} ->
            case maps:fold(
                   fun(ScopeKey, _True, healthy) ->
                           scope_link_health(maps:get(ScopeKey, Scopes));
                      (_ScopeKey, _True, Failure) -> Failure
                   end, healthy, ScopeKeys) of
                healthy -> S0;
                {dead, Reason} -> poison_owner(Owner, Reason, S0)
            end;
        _ -> S0
    end.

scope_link_health(#scope{status = active, request_link = RequestLink,
                         return_link = ReturnLink} = Scope) ->
    case link_alive(RequestLink) of
        false -> {dead, scope_unreachable(Scope)};
        true ->
            case link_alive(ReturnLink) of
                true -> healthy;
                false -> {dead, scope_unreachable(Scope)}
            end
    end;
scope_link_health(#scope{}) ->
    {dead, {protocol_error, unfinished_scope}}.

link_alive(Pid) when is_pid(Pid) -> erlang:is_process_alive(Pid);
link_alive(_) -> false.

scope_unreachable(
  #scope{binding = {scope_binding, _, _, _, _, _, {TargetNs, _}, _, _, _}}) ->
    {ontology_unreachable, TargetNs}.

drop_owner(Owner, S0) ->
    remove_owner_entry(Owner, clear_owner_resources(Owner, S0)).

clear_owner_resources(Owner, S0 = #s{owners = Owners}) ->
    case maps:get(Owner, Owners, undefined) of
        OwnerState = #owner{scopes = ScopeKeys, probes = OpenRefs,
                            identity = Identity} ->
            cleanup_identity_collection(Identity),
            maps:foreach(
              fun(ScopeKey, _True) ->
                  case maps:get(ScopeKey, S0#s.scopes, undefined) of
                      #scope{} = Scope -> send_direct_close(Scope);
                      undefined -> ok
                  end
              end, ScopeKeys),
            S1 = maps:fold(
                   fun(ScopeKey, _True, Acc) -> drop_scope(ScopeKey, Acc) end,
                   S0, ScopeKeys),
            S2 = maps:fold(
              fun(OpenRef, _True, Acc) -> drop_probe(OpenRef, Acc) end,
              S1, OpenRefs),
            case maps:get(Owner, S2#s.owners, undefined) of
                Current = #owner{} ->
                    put_owner(Owner, Current#owner{identity = none}, S2);
                undefined ->
                    _ = OwnerState,
                    S2
            end;
        undefined -> S0
    end.

cleanup_identity_collection({collecting, _Ref, Pid, MRef}) ->
    demonitor(MRef, [flush]),
    exit(Pid, kill),
    ok;
cleanup_identity_collection(_Identity) -> ok.

remove_owner_entry(
  Owner,
  S0 = #s{owners = Owners, owner_refs = OwnerRefs,
          retained_owners = RetainedOwners}) ->
    case maps:take(Owner, Owners) of
        {OwnerState = #owner{mref = MRef}, Owners1} ->
            demonitor(MRef, [flush]),
            S0#s{owners = Owners1,
                 retained_owners = retained_owner_removed(
                                     OwnerState, RetainedOwners),
                 owner_refs = maps:remove(MRef, OwnerRefs)};
        error -> S0
    end.

retained_owner_removed(Owner, Count) ->
    retained_owner_transition(retained_owner(Owner), false, Count).

drop_scope(ScopeKey, S0 = #s{scopes = Scopes}) ->
    case maps:take(ScopeKey, Scopes) of
        {Scope, Scopes1} ->
            S1 = S0#s{
                scopes = Scopes1,
                reuse = maps:remove(Scope#scope.reuse_key, S0#s.reuse),
                opens = maps:remove(Scope#scope.open_ref, S0#s.opens),
                peers = decrement(Scope#scope.target_key, S0#s.peers)},
            S2 = remove_owner_scope(Scope#scope.owner, ScopeKey, S1),
            S3 = remove_link_scope(request, Scope#scope.request_link, ScopeKey, S2),
            remove_link_scope(return, Scope#scope.return_link, ScopeKey, S3);
        error -> S0
    end.

remove_owner_scope(OwnerPid, ScopeKey,
                   S = #s{owners = Owners}) ->
    case maps:get(OwnerPid, Owners, undefined) of
        Owner = #owner{scopes = ScopeKeys, probes = Probes,
                       identity = Identity} ->
            ScopeKeys1 = maps:remove(ScopeKey, ScopeKeys),
            case map_size(ScopeKeys1) + map_size(Probes) of
                0 when Owner#owner.poison =:= healthy,
                       Owner#owner.finalization =:= open,
                       Identity =:= none ->
                    remove_owner_entry(OwnerPid, S);
                _ ->
                    put_owner(
                      OwnerPid, Owner#owner{scopes = ScopeKeys1}, S)
            end;
        undefined -> S
    end.

remove_owner_probe(OwnerPid, OpenRef,
                   S = #s{owners = Owners}) ->
    case maps:get(OwnerPid, Owners, undefined) of
        Owner = #owner{scopes = Scopes, probes = Probes,
                       identity = Identity} ->
            Probes1 = maps:remove(OpenRef, Probes),
            case map_size(Scopes) + map_size(Probes1) of
                0 when Owner#owner.poison =:= healthy,
                       Owner#owner.finalization =:= open,
                       Identity =:= none ->
                    remove_owner_entry(OwnerPid, S);
                _ ->
                    put_owner(
                      OwnerPid, Owner#owner{probes = Probes1}, S)
            end;
        undefined -> S
    end.

bind_request_link(LinkPid, Scope, S) ->
    add_link_scope(request, LinkPid, Scope#scope.key, S).

bind_return_link(LinkPid, Scope = #scope{return_link = undefined}, S0) ->
    Scope1 = Scope#scope{return_link = LinkPid},
    {Scope1,
     put_scope(Scope1, add_link_scope(return, LinkPid, Scope#scope.key, S0))};
bind_return_link(_LinkPid, Scope, S) ->
    {Scope, put_scope(Scope, S)}.

add_link_scope(Kind, LinkPid, ScopeKey, S0) ->
    Links0 = links(Kind, S0),
    Link = case maps:get(LinkPid, Links0, undefined) of
               undefined -> #link{mref = monitor(process, LinkPid),
                                  scopes = #{ScopeKey => true}};
               Existing = #link{scopes = ScopeKeys} ->
                   Existing#link{scopes = ScopeKeys#{ScopeKey => true}}
           end,
    set_links(Kind, Links0#{LinkPid => Link}, S0).

remove_link_scope(_Kind, undefined, _ScopeKey, S) -> S;
remove_link_scope(Kind, LinkPid, ScopeKey, S0) ->
    Links0 = links(Kind, S0),
    case maps:get(LinkPid, Links0, undefined) of
        Link = #link{mref = MRef, scopes = ScopeKeys} ->
            ScopeKeys1 = maps:remove(ScopeKey, ScopeKeys),
            case map_size(ScopeKeys1) of
                0 ->
                    demonitor(MRef, [flush]),
                    set_links(Kind, maps:remove(LinkPid, Links0), S0);
                _ ->
                    set_links(Kind, Links0#{
                        LinkPid => Link#link{scopes = ScopeKeys1}}, S0)
            end;
        undefined -> S0
    end.

links(request, #s{request_links = Links}) -> Links;
links(return, #s{return_links = Links}) -> Links.

set_links(request, Links, S) -> S#s{request_links = Links};
set_links(return, Links, S) -> S#s{return_links = Links}.

send_direct_close(#scope{request_link = LinkPid, binding = Binding,
                         next_command_seq = Seq})
  when is_pid(LinkPid), Seq =< ?QUOD_SCOPE_WIRE_MAX_UINT64 ->
    Command = {scope_command, Binding, Seq, new_id(), 0, scope_close},
    case quod_scope_wire:encode_command(Command) of
        {ok, Frame} -> quod_link:send_ordered(LinkPid, Frame);
        {error, _} -> ok
    end;
send_direct_close(_Scope) -> ok.

%% ------------------------------------------------------------------
%% Exact handles and small helpers
%% ------------------------------------------------------------------

find_exact_scope(Owner, Handle, RouterGeneration, Binding, RequestLink,
                 S = #s{generation = RouterGeneration, scopes = Scopes}) ->
    case scope_key(Binding) of
        {ok, ScopeKey} ->
            case maps:get(ScopeKey, Scopes, undefined) of
                Scope = #scope{owner = Owner, binding = Binding,
                               request_link = RequestLink, status = active} ->
                    case Handle =:= handle(Scope, S) of
                        true -> {ok, Scope};
                        false -> {error, invalid_handle}
                    end;
                _ -> {error, invalid_handle}
            end;
        error -> {error, invalid_handle}
    end;
find_exact_scope(_Owner, _Handle, _RouterGeneration, _Binding, _RequestLink, _S) ->
    {error, stale_router}.

scope_key({scope_binding, _OriginKey, _TargetKey, ProofId, ScopeId,
           _OriginIdentity, _TargetIdentity, _Mode,
           _Principal, _AuthenticationDigest}) ->
    {ok, {ProofId, ScopeId}};
scope_key(_) -> error.

handle(#scope{binding = Binding, request_link = RequestLink},
       #s{generation = Generation}) when is_pid(RequestLink) ->
    {remote_scope, self(), Generation, Binding, RequestLink}.

handle_or_pending(#scope{request_link = Link} = Scope, S) when is_pid(Link) ->
    handle(Scope, S);
handle_or_pending(#scope{binding = Binding}, #s{generation = Generation}) ->
    {pending_remote_scope, self(), Generation, Binding}.

put_scope(Scope = #scope{key = ScopeKey}, S = #s{scopes = Scopes}) ->
    S#s{scopes = Scopes#{ScopeKey => Scope}}.

unique_request_id(Pending) ->
    Id = new_id(),
    case maps:is_key(Id, Pending) of
        true -> unique_request_id(Pending);
        false -> Id
    end.

new_id() -> crypto:strong_rand_bytes(?ID_BYTES).

increment(Key, Counts) -> Counts#{Key => maps:get(Key, Counts, 0) + 1}.

decrement(Key, Counts) ->
    case maps:get(Key, Counts, 0) of
        N when N > 1 -> Counts#{Key => N - 1};
        _ -> maps:remove(Key, Counts)
    end.
