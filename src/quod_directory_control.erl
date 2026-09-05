-module(quod_directory_control).
-moduledoc """
Signed dissemination and renewal for `quod_directory`.

This process owns no directory answer index. It verifies and forwards
immutable signed generations, while the directory service remains the
sole ETS writer.
Directory-control authority comes from the local root ontology's committed
`peer_admitted/4` facts. A monitored worker reads that snapshot without
blocking this process. Live transport hints locate known keys; the root
ontology's existing join contacts can also discover an authenticated key, but
the link is retained and its endpoint promoted only when that exact key occurs
in the proved root set. Both paths suppress automatic address-cache learning.
Public snapshot reads do not confer ingest authority: this process accepts
snapshot replies only on its exact current outbound control links, and accepts
relayed announcements only from a current root control peer.
""".

-behaviour(gen_server).

-include("quod_directory_limits.hrl").

-export([start_link/0, start_link/1, start_tracking/0, hosting_changed/4,
         route_needed/1,
         stats/0, channel/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-ifdef(TEST).
-export([decode_control/1,
         test_set_control_peers/1, test_set_control_link/3,
         test_control_state/0, test_apply_peer_result/1,
         test_install_control_link/3,
         test_set_pending_link/3, test_validate_peer_proof/1,
         test_set_hosting_snapshot/2, test_set_manager_epoch/1,
         test_partition_hosted/1]).
-endif.

-define(KEY, {directory, control}).
-define(ROOT_NS, <<"quod:root">>).
-define(RENEW_MS, 10000).
-define(PEER_RETRY_MS, 1000).
-define(PEER_QUERY_TIMEOUT_MS, 5000).
-define(CONTROL_DIAL_LIMIT, 4).
-define(CONTROL_DIAL_TIMEOUT_MS, 11000).
-define(MAX_CONTROL_BYTES, (1 bsl 20)).
-define(MAX_ANNOUNCE_FRAME_BYTES, (17 * 1024)).

-record(s, {
    channel,
    enabled = false,
    self_key = undefined,
    signer = undefined,
    endpoint = undefined,
    epoch = undefined,
    generation = 0,
    hosted = [],
    root_contacts = [],
    generations = #{},
    assemblies = #{},
    validations = #{},
    control_peers = #{},
    dial_queue = {[], []},
    pending_links = #{},
    pending_contacts = #{},
    control_links = #{},
    peer_query = undefined,
    peer_refresh_pending = false,
    peer_height = undefined,
    peer_status = never_succeeded,
    renew_ms = ?RENEW_MS,
    directory_ref = undefined,
    manager_monitor = undefined,
    manager_pid = undefined,
    hosting_revision = -1,
    hosting_projection = [],
    private_projection = [],
    route_demands = #{},
    route_demanded = 0,
    route_wakes = 0,
    tracking = false
}).

start_link() ->
    start_link(application:get_env(quod, directory, #{})).

start_link(Opts) ->
    gen_server:start_link(quod_reg:via(?KEY), ?MODULE, Opts, []).

-doc """
Start advertising the manager's complete committed ready projection. Each
descriptor carries the namespace's immutable genesis anchor and current
validator/observer role.
This is called once after application startup; later manager revisions replace
the snapshot and renewals only revalidate its current live state.
""".
-spec start_tracking() -> ok | {error, term()}.
start_tracking() ->
    gen_server:call(quod_reg:via(?KEY), start_tracking, 10000).

-doc "Install one manager-epoch-bound ready-hosting snapshot.".
hosting_changed(ManagerPid, Revision, Names, Private)
  when is_pid(ManagerPid), is_integer(Revision), Revision >= 0,
       is_list(Names), is_list(Private) ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            gen_server:cast(Pid,
                            {hosting_changed, ManagerPid, Revision,
                             Names, Private}),
            ok;
        undefined -> ok
    end.

-doc "Request immediate resynchronization for one missing exact route.".
-spec route_needed({binary(), <<_:256>>}) -> ok.
route_needed({Ns, <<_:256>>} = Identity) when is_binary(Ns) ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) -> gen_server:cast(Pid, {route_needed, Identity});
        undefined -> ok
    end;
route_needed(_) -> ok.

stats() ->
    try gen_server:call(quod_reg:via(?KEY), stats, 1000)
    catch exit:_ -> undefined
    end.

-ifdef(TEST).
test_set_control_peers(Keys) ->
    sys:replace_state(
      quod_reg:via(?KEY),
      fun(S) ->
          S#s{control_peers = maps:from_keys(Keys, true)}
      end),
    ok.

test_set_control_link(NodeKey, Endpoint, LinkPid) ->
    sys:replace_state(
      quod_reg:via(?KEY),
      fun(S) ->
          install_test_control_link(NodeKey, Endpoint, LinkPid, S)
      end),
    ok.

test_control_state() ->
    S = sys:get_state(quod_reg:via(?KEY)),
    #{control_peers => S#s.control_peers,
      dial_queue => queue:to_list(S#s.dial_queue),
      pending_links => S#s.pending_links,
      pending_contacts => S#s.pending_contacts,
      control_links => S#s.control_links,
      peer_query => S#s.peer_query,
      peer_height => S#s.peer_height,
      peer_status => S#s.peer_status,
      manager_pid => S#s.manager_pid,
      hosting_revision => S#s.hosting_revision,
      hosting_projection => S#s.hosting_projection,
      route_demands => maps:keys(S#s.route_demands)}.

test_apply_peer_result(Result) ->
    sys:replace_state(
      quod_reg:via(?KEY),
      fun(S) -> apply_peer_result(Result, S) end),
    ok.

test_install_control_link(NodeKey, Endpoint, LinkPid) ->
    sys:replace_state(
      quod_reg:via(?KEY),
      fun(S) ->
          install_control_link(NodeKey, Endpoint, LinkPid, S)
      end),
    ok.

test_set_pending_link(NodeKey, Endpoint, OpenRef) ->
    sys:replace_state(
      quod_reg:via(?KEY),
      fun(S) ->
          TimerRef = erlang:send_after(
                       60000, self(),
                       {directory_control_dial_timeout,
                        NodeKey, Endpoint, OpenRef}),
          S#s{pending_links =
                  (S#s.pending_links)#{
                    NodeKey => {Endpoint, OpenRef, TimerRef}}}
      end),
    ok.

test_validate_peer_proof(Result) ->
    validate_peer_proof(Result).

test_set_hosting_snapshot(Revision, Names) ->
    Caller = self(),
    sys:replace_state(
      quod_reg:via(?KEY),
      fun(S) -> S#s{manager_pid = Caller,
                    hosting_revision = -1}
      end),
    ok = hosting_changed(Caller, Revision, Names, []),
    _ = sys:get_state(quod_reg:via(?KEY)),
    ok.

test_set_manager_epoch(ManagerPid) when is_pid(ManagerPid) ->
    sys:replace_state(
      quod_reg:via(?KEY),
      fun(S) -> S#s{manager_pid = ManagerPid,
                    hosting_revision = -1,
                    hosting_projection = []}
      end),
    ok.
-endif.

channel() ->
    term_to_binary(quod_directory_control, [deterministic]).

init(Opts) ->
    Channel = channel(),
    true = quod_reg:subscribe({channel, Channel}),
    true = quod_reg:subscribe({runtime, ?ROOT_NS}),
    case control_config(Opts) of
        {ok, Cfg} ->
            Base = #s{channel = Channel,
                      self_key = local_node_key(),
                      root_contacts = maps:get(root_contacts, Cfg),
                      renew_ms = maps:get(renew_ms, Cfg),
                      manager_monitor =
                        quod_reg:monitor_name({namespace_manager, node}, follow),
                      directory_ref =
                        quod_reg:monitor_name({directory, node}, follow)},
            Base1 = refresh_manager_snapshot(
                      Base#s{manager_pid =
                               quod_reg:where({namespace_manager, node})}),
            case serving_identity(Cfg) of
                disabled ->
                    {ok, recover_lifecycle(Base1)};
                {ok, Identity} ->
                    {ok, recover_lifecycle(
                           Base1#s{
                             enabled = true,
                             self_key = maps:get(node_key, Identity),
                             signer = maps:get(signer, Identity),
                             endpoint = maps:get(endpoint, Identity),
                             epoch = maps:get(epoch, Identity)})};
                {error, Reason} ->
                    {stop, {directory_identity_failed, Reason}}
            end;
        {error, Reason} ->
            {stop, {bad_directory_control_config, Reason}}
    end.

handle_call(start_tracking, _From, S) ->
    case set_observed_hosted(S) of
        {ok, S1} ->
            application:set_env(quod, directory_tracking, true),
            {reply, ok, S1};
        {error, Reason} ->
            {reply, {error, Reason}, S}
    end;
handle_call(stats, _From, S) ->
    {reply, #{enabled => S#s.enabled,
              tracking => S#s.tracking,
              records => map_size(S#s.generations),
              control_peer_count => map_size(S#s.control_peers),
              control_link_count => map_size(S#s.control_links),
              control_pending_count => map_size(S#s.pending_links),
              root_contact_count => length(S#s.root_contacts),
              root_contact_pending_count =>
                  map_size(S#s.pending_contacts),
              root_proof_height => S#s.peer_height,
              root_proof_status => S#s.peer_status,
              epoch => S#s.epoch,
              sequence => S#s.generation,
              route_demands => map_size(S#s.route_demands),
              route_demanded => S#s.route_demanded,
              route_wakes => S#s.route_wakes}, S};
handle_call(_Request, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast({hosting_changed, ManagerPid, Revision, Names, Private},
            S = #s{manager_pid = ManagerPid,
                   hosting_revision = Previous})
  when Revision > Previous ->
    install_private_projection(Private),
    S1 = S#s{hosting_revision = Revision, hosting_projection = Names,
             private_projection = Private},
    case S1#s.tracking of
        true ->
            case set_observed_hosted(S1) of
                {ok, S2} -> {noreply, S2};
                {error, _} -> {noreply, S1}
            end;
        false -> {noreply, S1}
    end;
handle_cast({hosting_changed, _ManagerPid, _Revision, _Names, _Private}, S) ->
    {noreply, S};
handle_cast({route_needed, Identity}, S) ->
    {noreply, register_route_demand(Identity, S)};
handle_cast(_Message, S) ->
    {noreply, S}.

handle_info(directory_tick, S) ->
    {noreply, directory_tick(S)};
handle_info(refresh_control_peers, S) ->
    {noreply, maybe_start_peer_query(S)};
handle_info({replay_ready, _Id, _Height}, S) ->
    {noreply, request_peer_refresh(S)};
handle_info({applied_live, Envelope}, S) ->
    case root_control_authority_changed(Envelope) of
        true -> {noreply, request_peer_refresh(S)};
        false -> {noreply, S}
    end;
handle_info({directory_peer_result, Token, Result}, S) ->
    {noreply, handle_peer_result(Token, Result, S)};
handle_info({directory_peer_query_timeout, Token}, S) ->
    {noreply, handle_peer_query_timeout(Token, S)};
handle_info({gproc, registered, Ref, _Name},
            S = #s{manager_monitor = Ref}) ->
    S1 = refresh_manager_snapshot(
           S#s{manager_pid = quod_reg:where({namespace_manager, node}),
               hosting_revision = -1, hosting_projection = []}),
    {noreply, recover_tracking_event(S1)};
handle_info({gproc, unreg, Ref, _Name},
            S = #s{manager_monitor = Ref}) ->
    {noreply, S#s{manager_pid = undefined,
                  hosting_revision = -1, hosting_projection = []}};
handle_info({gproc, registered, Ref, _Name},
            S = #s{directory_ref = Ref}) ->
    {noreply, recover_directory_state(S)};
handle_info({gproc, unreg, Ref, _Name}, S = #s{directory_ref = Ref}) ->
    {noreply, maintain_directory_control(S)};
handle_info(
  {directory_control_dial_timeout, NodeKey, Endpoint, OpenRef}, S) ->
    {noreply,
     handle_control_dial_timeout(NodeKey, Endpoint, OpenRef, S)};
handle_info(
  {directory_contact_dial_timeout, Endpoint, OpenRef}, S) ->
    {noreply,
     handle_contact_dial_timeout(Endpoint, OpenRef, S)};
handle_info({link_up, Ref, PeerKey, Channel, LinkPid},
            S = #s{channel = Channel}) ->
    {noreply, handle_directory_link_up(
                Ref, PeerKey, LinkPid, S)};
handle_info({link_error, Ref, PeerKey, Channel},
            S = #s{channel = Channel}) ->
    {noreply, handle_directory_link_error(PeerKey, Ref, S)};
handle_info({quod_message, {{PeerKey, PeerEndpoint}, LinkPid}, Channel, Payload},
            S = #s{channel = Channel})
  when is_binary(PeerKey), byte_size(PeerKey) =:= 32,
       is_pid(LinkPid) ->
    {noreply, inbound(
                Payload, {direct_link, PeerKey, PeerEndpoint, LinkPid}, S)};
handle_info({quod_message, {PeerKey, LinkPid}, Channel, Payload},
            S = #s{channel = Channel})
  when is_binary(PeerKey), byte_size(PeerKey) =:= 32,
       is_pid(LinkPid) ->
    %% An outbound directory link is TLS-pinned to PeerKey. Its endpoint and
    %% monitor remain private in control_links. Snapshots require that exact
    %% current link; announcements require current root-relay authority.
    {noreply, inbound(
                Payload, {pinned_link, PeerKey, LinkPid}, S)};
handle_info({directory_generation_validated, Token, Result}, S) ->
    {noreply, finish_generation_validation(Token, Result, S)};
handle_info({directory_route_available, Identity}, S) ->
    {noreply, clear_route_demand(Identity, S)};
handle_info({'DOWN', Ref, process, Pid, Reason}, S) ->
    case handle_generation_validation_down(Ref, Pid, Reason, S) of
        {matched, S1} -> {noreply, S1};
        unmatched -> case handle_peer_query_down(Ref, Pid, Reason, S) of
        {matched, S1} ->
            {noreply, S1};
        unmatched ->
            {noreply, handle_control_link_down(Ref, Pid, S)}
        end
    end;
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, S) ->
    maps:foreach(
      fun(_Author, #{pid := Pid, mref := MRef}) ->
          demonitor(MRef, [flush]),
          exit(Pid, kill)
      end, S#s.validations),
    cleanup_control_state(S),
    _ = catch quod_reg:demonitor_name(
                {namespace_manager, node}, S#s.manager_monitor),
    _ = catch quod_reg:demonitor_name(
                {directory, node}, S#s.directory_ref),
    _ = catch quod_reg:unsubscribe({channel, S#s.channel}),
    _ = catch quod_reg:unsubscribe({runtime, ?ROOT_NS}),
    _ = [catch quod_reg:unsubscribe({directory_route, Identity})
         || Identity <- maps:keys(S#s.route_demands)],
    ok.

%%%===================================================================
%%% root-derived control peers
%%%===================================================================

maybe_start_peer_query(S = #s{peer_query = undefined}) ->
    Parent = self(),
    Token = make_ref(),
    {Pid, MonitorRef} =
        spawn_monitor(
          fun() ->
              Result =
                  try root_peer_proof()
                  catch
                      Class:Reason ->
                          {error, {Class, Reason}}
                  end,
              Parent ! {directory_peer_result, Token, Result}
          end),
    TimerRef = erlang:send_after(
                 ?PEER_QUERY_TIMEOUT_MS, self(),
                 {directory_peer_query_timeout, Token}),
    S#s{peer_query = {Pid, MonitorRef, Token, TimerRef},
        peer_status = querying};
maybe_start_peer_query(S) ->
    S.

request_peer_refresh(S = #s{peer_query = undefined}) ->
    maybe_start_peer_query(S#s{peer_refresh_pending = false});
request_peer_refresh(S) ->
    %% A query which began before this committed root edge may have captured
    %% the older snapshot. Coalesce another read instead of losing the edge.
    S#s{peer_refresh_pending = true}.

continue_peer_refresh(
  S = #s{peer_query = undefined, peer_refresh_pending = true}) ->
    maybe_start_peer_query(S#s{peer_refresh_pending = false});
continue_peer_refresh(S) ->
    S.

root_control_authority_changed(Envelope) when is_map(Envelope) ->
    quod_diff:touches_functor(
      maps:get(diff, Envelope, []), {peer_admitted, 4});
root_control_authority_changed(_) -> false.

root_peer_proof() ->
    Key = {'DirectoryControlKey'},
    Keys = {'DirectoryControlKeys'},
    Goal = {findall, Key, {directory_control_peer, Key}, Keys},
    validate_peer_proof(
      quod_prolog:prove_ro(?ROOT_NS, Goal)).

validate_peer_proof(
  {ok, [Bindings], Height})
  when is_map(Bindings), is_integer(Height), Height >= 0 ->
    case maps:find('DirectoryControlKeys', Bindings) of
        {ok, Keys} when is_list(Keys) ->
            case peer_key_set(Keys, #{}) of
                {ok, Peers} ->
                    {ok, Height, Peers};
                error ->
                    {error, malformed_peer_keys}
            end;
        _ ->
            {error, malformed_peer_bindings}
    end;
validate_peer_proof({error, Reason}) ->
    {error, Reason};
validate_peer_proof(fail) ->
    {error, fail};
validate_peer_proof({fail, _Reasons}) ->
    {error, fail};
validate_peer_proof(_) ->
    {error, malformed_peer_proof}.

peer_key_set([], Peers) ->
    {ok, Peers};
peer_key_set([Key | Rest], Peers)
  when is_binary(Key), byte_size(Key) =:= 32 ->
    case maps:is_key(Key, Peers) of
        true ->
            error;
        false ->
            peer_key_set(Rest, Peers#{Key => true})
    end;
peer_key_set(_Keys, _Peers) ->
    error.

handle_peer_result(
  Token, Result,
  S = #s{peer_query = {_Pid, MonitorRef, Token, TimerRef}}) ->
    cancel_timer(TimerRef),
    demonitor(MonitorRef, [flush]),
    S0 = S#s{peer_query = undefined},
    continue_peer_refresh(apply_peer_result(Result, S0));
handle_peer_result(_Token, _Result, S) ->
    S.

apply_peer_result(Result, S) ->
    case Result of
        {ok, Height, Peers} when is_map(Peers) ->
            reconcile_control_peers(Peers, Height, S);
        {error, Reason} ->
            schedule_peer_retry(),
            S#s{peer_status = {error, Reason}};
        _ ->
            schedule_peer_retry(),
            S#s{peer_status = {error, malformed_peer_result}}
    end.

handle_peer_query_timeout(
  Token,
  S = #s{peer_query = {Pid, MonitorRef, Token, TimerRef}}) ->
    cancel_timer(TimerRef),
    _ = catch exit(Pid, kill),
    demonitor(MonitorRef, [flush]),
    schedule_peer_retry(),
    continue_peer_refresh(
      S#s{peer_query = undefined,
          peer_status = {error, timeout}});
handle_peer_query_timeout(_Token, S) ->
    S.

handle_peer_query_down(
  MonitorRef, Pid, Reason,
  S = #s{peer_query = {Pid, MonitorRef, _Token, TimerRef}}) ->
    cancel_timer(TimerRef),
    schedule_peer_retry(),
    {matched,
     continue_peer_refresh(
       S#s{peer_query = undefined,
           peer_status = {error, {worker_down, Reason}}})};
handle_peer_query_down(_MonitorRef, _Pid, _Reason, _S) ->
    unmatched.

schedule_peer_retry() ->
    %% This is the root-authority liveness fallback, not ordinary namespace
    %% recovery: successful root projection changes wake reconciliation.
    _ = erlang:send_after(
          ?PEER_RETRY_MS, self(), refresh_control_peers),
    ok.

reconcile_control_peers(Peers, Height, S) ->
    %% Revoke relay authority before retiring its transports. No other mailbox
    %% message can interleave with this serialized state transition.
    S0 = S#s{control_peers = Peers,
             peer_height = Height,
             peer_status = ok},
    S1 = retire_removed_controls(S0),
    maintain_control_links(S1).

retire_removed_controls(
  S = #s{control_peers = Peers, pending_links = Pending,
         control_links = Links}) ->
    Pending1 =
        maps:fold(
          fun(NodeKey, Entry = {_Endpoint, _OpenRef, TimerRef}, Acc) ->
              case maps:is_key(NodeKey, Peers) of
                  true ->
                      Acc#{NodeKey => Entry};
                  false ->
                      cancel_timer(TimerRef),
                      Acc
              end
          end, #{}, Pending),
    Links1 =
        maps:fold(
          fun(NodeKey, Entry, Acc) ->
              case maps:is_key(NodeKey, Peers) of
                  true ->
                      Acc#{NodeKey => Entry};
                  false ->
                      retire_control_link(Entry),
                      Acc
              end
          end, #{}, Links),
    S#s{pending_links = Pending1,
        control_links = Links1}.

maintain_directory_control(S) ->
    S1 = maybe_start_peer_query(S),
    S2 = maintain_control_links(S1),
    send_control_resyncs(S2).

maintain_control_links(S) ->
    S1 = refresh_control_endpoints(S),
    S2 = pump_root_contacts(S1),
    pump_control_dials(S2).

%% Root contacts are the root ontology's existing join endpoints, not directory
%% authorities. Dial them without automatic cache learning, authenticate the
%% returned key, and promote the endpoint only after the local root proof says
%% that exact key is a current control peer. Contacts are tried before stale
%% key-cache candidates so a completely rotated fleet can recover.
pump_root_contacts(S = #s{root_contacts = Contacts}) ->
    lists:foldl(fun maybe_open_root_contact/2, S, Contacts).

maybe_open_root_contact(
  Endpoint,
  S = #s{pending_contacts = Pending, control_links = Links}) ->
    case total_pending(S) < ?CONTROL_DIAL_LIMIT
         andalso not maps:is_key(Endpoint, Pending)
         andalso not live_control_at_endpoint(Endpoint, Links) of
        false ->
            S;
        true ->
            OpenRef = quod_quic:open_link_identified(
                        Endpoint, S#s.channel),
            TimerRef = erlang:send_after(
                         ?CONTROL_DIAL_TIMEOUT_MS, self(),
                         {directory_contact_dial_timeout,
                          Endpoint, OpenRef}),
            S#s{pending_contacts =
                    Pending#{Endpoint => {OpenRef, TimerRef}}}
    end.

live_control_at_endpoint(Endpoint, Links) ->
    maps:fold(
      fun(_NodeKey, {Endpoint0, LinkPid, _MonitorRef}, Found) ->
              Found orelse
                  (Endpoint0 =:= Endpoint
                   andalso is_pid(LinkPid)
                   andalso is_process_alive(LinkPid))
      end, false, Links).

total_pending(#s{pending_links = Pending,
                 pending_contacts = Contacts}) ->
    map_size(Pending) + map_size(Contacts).

refresh_control_endpoints(
  S = #s{control_peers = Peers, self_key = SelfKey,
         pending_links = Pending, control_links = Links}) ->
    Pending1 =
        maps:fold(
          fun(NodeKey, Entry = {Endpoint, _OpenRef, TimerRef}, Acc) ->
              case control_candidate_current(
                     NodeKey, Endpoint, Peers, SelfKey) of
                  true ->
                      Acc#{NodeKey => Entry};
                  false ->
                      cancel_timer(TimerRef),
                      Acc
              end
          end, #{}, Pending),
    Queue =
        maps:fold(
          fun(NodeKey, _Allowed, Acc) ->
              queue_control_candidate(
                NodeKey, SelfKey, Pending1, Links, Acc)
          end, queue:new(), Peers),
    S#s{pending_links = Pending1,
        dial_queue = Queue}.

queue_control_candidate(
  NodeKey, SelfKey, Pending, Links, Queue) ->
    case NodeKey =/= SelfKey of
        false ->
            Queue;
        true ->
            case quod_quic:resolve(NodeKey) of
                {ok, Endpoint} ->
                    case {maps:get(NodeKey, Pending, undefined),
                          maps:get(NodeKey, Links, undefined)} of
                        {{Endpoint, _OpenRef, _TimerRef}, _} ->
                            Queue;
                        {_, {Endpoint, LinkPid, _MonitorRef}}
                          when is_pid(LinkPid) ->
                            case is_process_alive(LinkPid) of
                                true ->
                                    Queue;
                                false ->
                                    queue:in({NodeKey, Endpoint}, Queue)
                            end;
                        {undefined, _} ->
                            queue:in({NodeKey, Endpoint}, Queue);
                        {_PendingOtherEndpoint, _} ->
                            Queue
                    end;
                error ->
                    Queue
            end
    end.

control_candidate_current(NodeKey, Endpoint, Peers, SelfKey) ->
    NodeKey =/= SelfKey
        andalso maps:is_key(NodeKey, Peers)
        andalso quod_quic:resolve(NodeKey) =:= {ok, Endpoint}.

pump_control_dials(S) ->
    case total_pending(S) >= ?CONTROL_DIAL_LIMIT of
        true ->
            S;
        false ->
            pump_control_dial_queue(S)
    end.

pump_control_dial_queue(S = #s{dial_queue = Queue}) ->
    case queue:out(Queue) of
        {empty, _} ->
            S;
        {{value, {NodeKey, Endpoint}}, Rest} ->
            S0 = S#s{dial_queue = Rest},
            case should_open_control(NodeKey, Endpoint, S0) of
                false ->
                    pump_control_dial_queue(S0);
                true ->
                    OpenRef = quod_quic:open_link_pinned(
                                NodeKey, Endpoint, S0#s.channel),
                    TimerRef = erlang:send_after(
                                 ?CONTROL_DIAL_TIMEOUT_MS, self(),
                                 {directory_control_dial_timeout,
                                  NodeKey, Endpoint, OpenRef}),
                    Pending1 = (S0#s.pending_links)#{
                                 NodeKey =>
                                     {Endpoint, OpenRef, TimerRef}},
                    pump_control_dials(
                      S0#s{pending_links = Pending1})
            end
    end.

should_open_control(
  NodeKey, Endpoint,
  #s{control_peers = Peers, self_key = SelfKey,
     pending_links = Pending, control_links = Links}) ->
    control_candidate_current(NodeKey, Endpoint, Peers, SelfKey)
        andalso not maps:is_key(NodeKey, Pending)
        andalso not exact_live_control(
                      Endpoint, maps:get(NodeKey, Links, undefined)).

exact_live_control(
  Endpoint, {Endpoint, LinkPid, _MonitorRef}) when is_pid(LinkPid) ->
    is_process_alive(LinkPid);
exact_live_control(_Endpoint, _Entry) ->
    false.

handle_control_dial_timeout(
  NodeKey, Endpoint, OpenRef,
  S = #s{pending_links = Pending}) ->
    case maps:get(NodeKey, Pending, undefined) of
        {Endpoint, OpenRef, TimerRef} ->
            cancel_timer(TimerRef),
            pump_control_dials(
              S#s{pending_links = maps:remove(NodeKey, Pending)});
        _ ->
            S
    end.

handle_contact_dial_timeout(
  Endpoint, OpenRef,
  S = #s{pending_contacts = Pending}) ->
    case maps:get(Endpoint, Pending, undefined) of
        {OpenRef, TimerRef} ->
            cancel_timer(TimerRef),
            pump_control_dials(
              S#s{pending_contacts =
                      maps:remove(Endpoint, Pending)});
        _ ->
            S
    end.

handle_directory_link_error(Peer, OpenRef, S) ->
    case take_pending_contact(OpenRef, S) of
        {ok, _Endpoint, S0} ->
            %% Do not immediately redial the failed endpoint in this mailbox
            %% turn. Other queued key candidates may proceed; later control
            %% link, authority, or exact-demand events own further progress.
            pump_control_dials(S0);
        error when is_binary(Peer), byte_size(Peer) =:= 32 ->
            handle_control_link_error(Peer, OpenRef, S);
        error ->
            S
    end.

handle_directory_link_up(OpenRef, PeerKey, LinkPid, S) ->
    case take_pending_contact(OpenRef, S) of
        {ok, Endpoint, S0} ->
            handle_root_contact_link_up(
              Endpoint, PeerKey, LinkPid, S0);
        error ->
            handle_control_link_up(
              OpenRef, PeerKey, LinkPid, S)
    end.

take_pending_contact(
  OpenRef, S = #s{pending_contacts = Pending}) ->
    case pending_contact_by_ref(OpenRef, Pending) of
        {ok, Endpoint, TimerRef} ->
            cancel_timer(TimerRef),
            {ok, Endpoint,
             S#s{pending_contacts =
                     maps:remove(Endpoint, Pending)}};
        error ->
            error
    end.

pending_contact_by_ref(OpenRef, Pending) ->
    maps:fold(
      fun(Endpoint, {Ref, TimerRef}, error)
            when Ref =:= OpenRef ->
              {ok, Endpoint, TimerRef};
         (_Endpoint, _Entry, Acc) ->
              Acc
      end, error, Pending).

handle_root_contact_link_up(
  Endpoint, PeerKey, LinkPid,
  S = #s{root_contacts = Contacts, control_peers = Peers,
         self_key = SelfKey})
  when is_binary(PeerKey), byte_size(PeerKey) =:= 32,
       is_pid(LinkPid) ->
    case lists:member(Endpoint, Contacts)
         andalso PeerKey =/= SelfKey
         andalso maps:is_key(PeerKey, Peers) of
        true ->
            %% Promotion is deliberate and occurs only after transport
            %% authentication plus root-Prolog authorization. This live
            %% observation also repairs the shared key cache used by root.
            ok = quod_quic:learn(PeerKey, Endpoint),
            S1 = install_control_link(
                   PeerKey, Endpoint, LinkPid, S),
            pump_control_dials(
              pump_root_contacts(
                refresh_control_endpoints(S1)));
        false ->
            _ = quod_link:close(LinkPid),
            pump_control_dials(S)
    end;
handle_root_contact_link_up(
  _Endpoint, _PeerKey, LinkPid, S) ->
    _ = quod_link:close(LinkPid),
    pump_control_dials(S).

handle_control_link_error(
  NodeKey, OpenRef, S = #s{pending_links = Pending}) ->
    case maps:get(NodeKey, Pending, undefined) of
        {_Endpoint, OpenRef, TimerRef} ->
            cancel_timer(TimerRef),
            pump_control_dials(
              S#s{pending_links = maps:remove(NodeKey, Pending)});
        _ ->
            S
    end.

handle_control_link_up(
  OpenRef, NodeKey, LinkPid,
  S = #s{pending_links = Pending, control_peers = Peers,
         self_key = SelfKey})
  when is_binary(NodeKey), byte_size(NodeKey) =:= 32,
       is_pid(LinkPid) ->
    case maps:get(NodeKey, Pending, undefined) of
        {Endpoint, OpenRef, TimerRef} ->
            cancel_timer(TimerRef),
            S0 = S#s{pending_links = maps:remove(NodeKey, Pending)},
            case control_candidate_current(
                   NodeKey, Endpoint, Peers, SelfKey) of
                true ->
                    pump_control_dials(
                      install_control_link(
                        NodeKey, Endpoint, LinkPid, S0));
                false ->
                    %% The open belongs to a retired endpoint/generation.
                    %% quod_quic owns LinkPid; closing it here could kill a
                    %% reused current link returned to another OpenRef.
                    pump_control_dials(S0)
            end;
        _ ->
            %% Unknown or late result. See the reuse note above.
            S
    end;
handle_control_link_up(_OpenRef, _NodeKey, _LinkPid, S) ->
    S.

install_control_link(
  NodeKey, Endpoint, LinkPid,
  S = #s{control_links = Links}) ->
    case maps:get(NodeKey, Links, undefined) of
        {Endpoint, LinkPid, _MonitorRef} ->
            send_current_and_resync(LinkPid, S),
            S;
        {OldEndpoint, LinkPid, _MonitorRef}
          when OldEndpoint =/= Endpoint ->
            logger:warning(
              "quod: directory pinned link reused across endpoints for ~p",
              [NodeKey]),
            S;
        OldEntry ->
            MonitorRef = monitor(process, LinkPid),
            S1 = S#s{control_links =
                         Links#{
                           NodeKey =>
                               {Endpoint, LinkPid, MonitorRef}}},
            case OldEntry of
                undefined -> ok;
                _ -> retire_control_link(OldEntry)
            end,
            send_current_and_resync(LinkPid, S1),
            S1
    end.

handle_control_link_down(MonitorRef, LinkPid,
                         S = #s{control_links = Links}) ->
    case control_by_monitor(MonitorRef, LinkPid, Links) of
        {ok, NodeKey} ->
            S0 = S#s{control_links = maps:remove(NodeKey, Links)},
            maintain_control_links(maybe_start_peer_query(S0));
        error ->
            S
    end.

control_by_monitor(MonitorRef, LinkPid, Links) ->
    maps:fold(
      fun(NodeKey, {_Endpoint, Pid, Ref}, error)
            when Pid =:= LinkPid, Ref =:= MonitorRef ->
              {ok, NodeKey};
         (_NodeKey, _Entry, Acc) ->
              Acc
      end, error, Links).

retire_control_link({_Endpoint, LinkPid, MonitorRef}) ->
    demonitor(MonitorRef, [flush]),
    _ = catch quod_link:close(LinkPid),
    ok.

send_control_resyncs(S = #s{control_links = Links}) ->
    Frame = resync_request_frame(),
    maps:foreach(
      fun(_NodeKey, {_Endpoint, LinkPid, _MonitorRef}) ->
          quod_link:send(LinkPid, Frame)
      end, Links),
    S.

register_route_demand(Identity, S0) ->
    case add_route_demand(Identity, S0) of
        {added, S1} -> maintain_directory_control(S1);
        {same, S1} -> S1
    end.

add_route_demand(
  {Ns, Anchor} = Identity,
  S = #s{route_demands = Demands})
  when is_binary(Ns), is_binary(Anchor), byte_size(Anchor) =:= 32 ->
    case maps:is_key(Identity, Demands) orelse route_is_available(Identity) of
        true ->
            {same, S};
        false ->
            true = quod_reg:subscribe({directory_route, Identity}),
            %% Close the install-vs-subscribe race. The directory published
            %% the edge if installation won; the direct reread avoids retaining
            %% a demand after that already-complete transition.
            case route_is_available(Identity) of
                true ->
                    _ = catch quod_reg:unsubscribe(
                                {directory_route, Identity}),
                    {same, S};
                false ->
                    {added,
                     S#s{route_demands =
                             Demands#{Identity => erlang:monotonic_time()},
                         route_demanded = S#s.route_demanded + 1}}
            end
    end;
add_route_demand(_Identity, S) ->
    {same, S}.

clear_route_demand(Identity, S = #s{route_demands = Demands}) ->
    case maps:take(Identity, Demands) of
        {StartedAt, Rest} ->
            _ = catch quod_reg:unsubscribe({directory_route, Identity}),
            quod_metrics:observe_directory_rebuild(
              ok, max(0, erlang:monotonic_time() - StartedAt)),
            S#s{route_demands = Rest, route_wakes = S#s.route_wakes + 1};
        error -> S
    end.

route_is_available({Ns, Anchor}) ->
    case quod_directory:validator_routes(Ns, Anchor) of
        {ok, [_ | _]} -> true;
        _ -> false
    end.

send_control_frame(Frame, SkipKey, S) ->
    send_control_frame(Frame, SkipKey, SkipKey, S).

send_control_frame(Frame, SkipKey1, SkipKey2,
                   S = #s{control_links = Links}) ->
    maps:foreach(
      fun(NodeKey, {_Endpoint, LinkPid, _MonitorRef}) ->
          case NodeKey =:= SkipKey1 orelse NodeKey =:= SkipKey2 of
              true -> ok;
              false -> quod_link:send(LinkPid, Frame)
          end
      end, Links),
    S.

control_link_current(
  NodeKey, LinkPid, #s{control_links = Links}) ->
    case maps:get(NodeKey, Links, undefined) of
        {_Endpoint, LinkPid, MonitorRef}
          when is_reference(MonitorRef) ->
            true;
        _ ->
            false
    end.

cleanup_control_state(
  #s{peer_query = PeerQuery, pending_links = Pending,
     pending_contacts = Contacts, control_links = Links}) ->
    case PeerQuery of
        {Pid, MonitorRef, _Token, TimerRef} ->
            cancel_timer(TimerRef),
            _ = catch exit(Pid, kill),
            demonitor(MonitorRef, [flush]);
        undefined ->
            ok
    end,
    maps:foreach(
      fun(_NodeKey, {_Endpoint, _OpenRef, TimerRef}) ->
          cancel_timer(TimerRef)
      end, Pending),
    maps:foreach(
      fun(_Endpoint, {_OpenRef, TimerRef}) ->
          cancel_timer(TimerRef)
      end, Contacts),
    maps:foreach(
      fun(_NodeKey, {_Endpoint, _LinkPid, MonitorRef}) ->
          demonitor(MonitorRef, [flush])
      end, Links),
    ok.

cancel_timer(TimerRef) when is_reference(TimerRef) ->
    _ = erlang:cancel_timer(TimerRef),
    ok.

local_node_key() ->
    case application:get_env(quod, node_pubkey) of
        {ok, NodeKey}
          when is_binary(NodeKey), byte_size(NodeKey) =:= 32 ->
            NodeKey;
        _ ->
            undefined
    end.

-ifdef(TEST).
install_test_control_link(
  NodeKey, Endpoint, LinkPid,
  S = #s{control_links = Links}) ->
    case maps:get(NodeKey, Links, undefined) of
        {_OldEndpoint, _OldPid, OldMonitorRef} ->
            demonitor(OldMonitorRef, [flush]);
        undefined ->
            ok
    end,
    MonitorRef = monitor(process, LinkPid),
    S#s{control_links =
            Links#{NodeKey => {Endpoint, LinkPid, MonitorRef}}}.
-endif.

%%%===================================================================
%%% local lifecycle
%%%===================================================================

set_observed_hosted(S) ->
    case observed_hosted(S) of
        {ok, Hosted} ->
            {ok, set_normalized_hosted(Hosted, S)};
        {error, _} = Error ->
            Error
    end.

normalize_hosted(Projection) ->
    %% Eligibility is the committed manager projection.  This owner merely
    %% intersects it with live, exact-anchor runtimes; configuration is not a
    %% second namespace authority and private rows never reach the wire.
    Public = [Row || #{visibility := discoverable} = Row <- Projection],
    describe_hosted(Public, []).

describe_hosted([#{namespace := Ns, anchor := Expected,
                   source := Source} | Rest], Acc) ->
    case {quod_simplex:genesis_hash(Ns), quod_simplex:status(Ns)} of
        {Expected, #{role := Role}}
          when Role =:= validator; Role =:= observer ->
            describe_hosted(Rest, [{Ns, Expected, Role, Source} | Acc]);
        _ ->
            {error, {hosted_descriptor_unavailable, Ns}}
    end;
describe_hosted([], Acc) ->
    Hosted = lists:reverse(Acc),
    case quod_directory_shape:validate_hosted(Hosted) of
        {ok, Hosted} -> {ok, Hosted};
        error -> {error, bad_hosted}
    end.

set_normalized_hosted(Hosted, S = #s{tracking = true, hosted = Hosted}) ->
    S;
set_normalized_hosted(Hosted, S) ->
    S1 = maintain_directory_control(
           S#s{hosted = Hosted, tracking = true}),
    case can_advertise(S1) of
        false ->
            S1;
        true ->
            publish_hosted(S1)
    end.

publish_hosted(S) ->
    case advertise_current(S) of
        {ok, S1} ->
            S1;
        {error, Reason, S1} ->
            logger:warning(
              "quod: local directory hosted-set update rejected: ~p",
              [Reason]),
            S1
    end.

directory_tick(S = #s{renew_ms = RenewMs}) ->
    arm_tick(RenewMs),
    %% This clock exists only for lease and root-control transport liveness.
    %% Route discovery and peer-set authority are driven by exact demand and
    %% committed root-runtime edges respectively; no resync is sent here.
    S1 = maintain_control_links(S),
    case S1#s.tracking andalso can_advertise(S1) of
        true -> renew_advertisement(S1);
        false -> S1
    end.

renew_advertisement(S) ->
    case reconcile_observed_hosted(S) of
        {ok, S0} ->
            case advertise_current(S0) of
                {ok, S1} ->
                    S1;
                {error, Reason, S1} ->
                    logger:warning(
                      "quod: local directory renewal rejected: ~p",
                      [Reason]),
                    S1
            end;
        {error, Reason} ->
            %% Never extend an advertisement when the node cannot prove its
            %% current hosted set. The old remote route will expire naturally.
            logger:warning(
              "quod: directory renewal skipped: ~p", [Reason]),
            S
    end.

advertise_current(S) ->
    case sign_current(S) of
        {ok, Generations, S1} ->
            install_local_generations(Generations, S1);
        {error, Reason} ->
            {error, Reason, S}
    end.

install_local_generations([], S) -> {ok, S};
install_local_generations([{Pages, Complete} | Rest], S) ->
    case install_generation(Complete) of
        {ok, ExpiresAt} ->
            Author = quod_directory_generation:author(Complete),
            Entry = #{pages => Pages, expires_at => ExpiresAt},
            S1 = S#s{generations =
                         (S#s.generations)#{Author => Entry}},
            S2 = send_generation_pages(Pages, S1#s.self_key, S1),
            install_local_generations(Rest, S2);
        {error, Reason} -> {error, Reason, S}
    end.

can_advertise(#s{enabled = true}) ->
    true;
can_advertise(_S) ->
    false.

sign_current(S = #s{self_key = NodeKey, endpoint = Endpoint,
                    hosted = Hosted, epoch = Epoch, generation = Generation,
                    signer = Signer}) ->
    Next = Generation + 1,
    {RootRows, NodeRows} = partition_hosted(Hosted),
    case generation_specs(RootRows, NodeRows, S) of
        {ok, Specs} ->
            case sign_generation_specs(
                   Specs, NodeKey, Endpoint, Epoch, Next, Signer, []) of
                {ok, Generations} ->
                    {ok, Generations, S#s{generation = Next}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

partition_hosted(Hosted) ->
    lists:partition(
      fun({_Ns, _Anchor, _Role, Source}) ->
          Source =:= bootstrap orelse Source =:= system
      end, Hosted).

-ifdef(TEST).
test_partition_hosted(Hosted) -> partition_hosted(Hosted).
-endif.

generation_specs(RootRows, NodeRows,
                 #s{self_key = SelfKey, control_peers = Peers}) ->
    RootAuthor =
        case {maps:is_key(SelfKey, Peers),
              quod_simplex:genesis_hash(?ROOT_NS)} of
            {true, <<_:256>> = Anchor} -> {root_bootstrap, Anchor, SelfKey};
            _ -> unavailable
        end,
    NodeAuthor =
        case quod_node_actor:principal() of
            {ok, {agent, Blob}} -> {node_actor, Blob};
            _ -> unavailable
        end,
    case {generation_spec(RootAuthor, RootRows),
          generation_spec(NodeAuthor, NodeRows)} of
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error;
        {RootSpec, NodeSpec} ->
            Specs = [Spec || Spec <- [RootSpec, NodeSpec], Spec =/= none],
            case Specs of
                [] -> {error, advertisement_author_unavailable};
                _ -> {ok, Specs}
            end
    end.

%% An available author publishes an empty generation too: that is how removal
%% atomically withdraws its previous rows. Missing authority is acceptable only
%% when that authority has no rows to claim.
generation_spec(unavailable, []) -> none;
generation_spec(unavailable, _Rows) -> {error, advertisement_author_unavailable};
generation_spec(Author, Rows) -> {Author, Rows}.

sign_generation_specs([], _NodeKey, _Endpoint, _Epoch, _Generation, _Signer,
                      Acc) ->
    {ok, lists:reverse(Acc)};
sign_generation_specs([{Author, Rows} | Rest], NodeKey, Endpoint, Epoch,
                      Generation, Signer, Acc) ->
    case quod_directory_generation:sign_generation(
           Author, NodeKey, Endpoint, Epoch, Generation, Rows, Signer) of
        {ok, Pages} ->
            case assemble_pages(Pages) of
                {ok, Complete} ->
                    sign_generation_specs(Rest, NodeKey, Endpoint, Epoch,
                                          Generation, Signer,
                                          [{Pages, Complete} | Acc]);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

assemble_pages(Pages) ->
    lists:foldl(
      fun(_Encoded, {error, _} = Error) -> Error;
         (_Encoded, {ok, _} = Complete) -> Complete;
         (Encoded, Assembly) ->
              case quod_directory_generation:decode(Encoded) of
                  {ok, Page} ->
                      case quod_directory_generation:assemble(Page, Assembly) of
                          {pending, Next} -> Next;
                          {complete, Complete} -> {ok, Complete};
                          {error, _} = Error -> Error
                      end;
                  {error, _} = Error -> Error
              end
      end, undefined, Pages).

install_generation(Generation) ->
    try quod_directory:install_generation(Generation)
    catch exit:_ -> {error, directory_unavailable}
    end.

send_generation_pages(Pages, SkipKey, S) ->
    lists:foldl(
      fun(Page, Acc) ->
          send_control_frame(generation_frame(Page), SkipKey, Acc)
      end, S, Pages).

arm_tick(Milliseconds) ->
    _ = erlang:send_after(Milliseconds, self(), directory_tick),
    ok.

%%%===================================================================
%%% signed ingress + dissemination
%%%===================================================================

ingest_generation_page(SignedPage, Source, S) ->
    case quod_directory_generation:decode(SignedPage) of
        {ok, Page} ->
            case generation_source_allowed(Page, Source, S) of
                true -> assemble_generation_page(Page, SignedPage, Source, S);
                false -> S
            end;
        {error, _} -> S
    end.

generation_source_allowed(Page,
                          {direct_link, PeerKey, PeerEndpoint, _LinkPid},
                          #s{control_peers = Peers}) ->
    Direct = quod_directory_generation:node_key(Page) =:= PeerKey andalso
        quod_directory_generation:endpoint(Page) =:= PeerEndpoint,
    Direct andalso
        case quod_directory_generation:author(Page) of
            {root_bootstrap, _, PeerKey} -> maps:is_key(PeerKey, Peers);
            {node_actor, _} -> true
        end;
generation_source_allowed(_Page, {pinned_link, PeerKey, LinkPid}, S) ->
    control_link_current(PeerKey, LinkPid, S).

assemble_generation_page(Page, SignedPage, Source,
                         S = #s{assemblies = Assemblies}) ->
    Author = quod_directory_generation:author(Page),
    Current = maps:get(Author, Assemblies, undefined),
    case quod_directory_generation:assemble(Page, assembly_value(Current)) of
        {pending, Assembly} ->
            Pages = remember_signed_page(Page, SignedPage, assembly_pages(Current)),
            S#s{assemblies = Assemblies#{Author =>
                                             #{assembly => Assembly,
                                               pages => Pages}}};
        {complete, Complete} ->
            Pages = remember_signed_page(Page, SignedPage, assembly_pages(Current)),
            S1 = S#s{assemblies = maps:remove(Author, Assemblies)},
            begin_generation_validation(Complete, ordered_signed_pages(Pages),
                                        source_peer_key_for_wire(Source), S1);
        {error, _} -> S
    end.

assembly_value(#{assembly := Assembly}) -> Assembly;
assembly_value(_) -> undefined.

assembly_pages(#{pages := Pages}) -> Pages;
assembly_pages(_) -> #{}.

remember_signed_page(Page, SignedPage, Pages) ->
    Pages#{quod_directory_generation:page(Page) => SignedPage}.

ordered_signed_pages(Pages) ->
    [Page || {_Index, Page} <- lists:keysort(1, maps:to_list(Pages))].

source_peer_key_for_wire({direct_link, PeerKey, _Endpoint, _Pid}) -> PeerKey;
source_peer_key_for_wire({pinned_link, PeerKey, _Pid}) -> PeerKey.

begin_generation_validation(Complete, Pages, SourceKey,
                            S = #s{validations = Validations}) ->
    Author = quod_directory_generation:author(Complete),
    case maps:get(Author, Validations, undefined) of
        undefined ->
            start_generation_validation(Author, Complete, Pages, SourceKey, S);
        #{complete := Active} = Entry ->
            case generation_order(Complete, Active) of
                newer ->
                    stop_generation_validation(Entry),
                    S0 = S#s{validations = maps:remove(Author, Validations)},
                    start_generation_validation(
                      Author, Complete, Pages, SourceKey, S0);
                _ -> S
            end
    end.

start_generation_validation(Author, Complete, Pages, SourceKey, S) ->
    Parent = self(), Token = make_ref(),
    %% Authority is frozen for this validation worker. A concurrent root view
    %% change governs the next generation; it cannot rewrite work in flight.
    ControlPeers = S#s.control_peers,
    {Pid, MRef} = spawn_monitor(fun() ->
        Result = validate_remote_generation(Complete, ControlPeers),
        Parent ! {directory_generation_validated, Token, Result}
    end),
    Entry = #{pid => Pid, mref => MRef, token => Token,
              complete => Complete, pages => Pages, source_key => SourceKey},
    S#s{validations = (S#s.validations)#{Author => Entry}}.

stop_generation_validation(#{pid := Pid, mref := MRef}) ->
    demonitor(MRef, [flush]),
    exit(Pid, kill).

generation_order(A, B) ->
    case {quod_directory_generation:epoch(A),
          quod_directory_generation:generation(A),
          quod_directory_generation:epoch(B),
          quod_directory_generation:generation(B)} of
        {AE, _AG, BE, _BG} when AE > BE -> newer;
        {AE, AG, AE, BG} when AG > BG -> newer;
        _ -> stale
    end.

validate_remote_generation(Page, ControlPeers) ->
    case system_catalogue() of
        {ok, Catalog} ->
            case quod_directory_generation:author(Page) of
                {root_bootstrap, _, _} ->
                    case maps:is_key(
                           quod_directory_generation:node_key(Page),
                           ControlPeers) of
                        true -> quod_directory_generation:validate_projection(
                                  Page, #{}, Catalog);
                        false -> {error, unauthorized_generation}
                    end;
                {node_actor, Blob} ->
                    validate_node_generation(Page, Blob, Catalog)
            end;
        {error, _} = Error -> Error
    end.

system_catalogue() ->
    case quod_system_ontology:catalog() of
        {ok, _Height, Descriptors, _Rejected} ->
            {ok, [{maps:get(namespace, D), maps:get(anchor, D)}
                  || D <- Descriptors]};
        {error, _} = Error -> Error
    end.

validate_node_generation(Page, Blob, Catalog) ->
    case quod_agent_ref:decode(Blob) of
        {ok, #{identity := Identity}} ->
            NodeKey = quod_directory_generation:node_key(Page),
            Endpoint = quod_directory_generation:endpoint(Page),
            Routes = [{NodeKey, [Endpoint]}],
            case quod_foreign_log:current(
                   Routes, Identity, {NodeKey, Endpoint}, 10000) of
                {ok, _View} ->
                    validate_followed_node_generation(Page, Identity, Catalog);
                {error, _} = Error -> Error
            end;
        _ -> {error, bad_generation}
    end.

validate_followed_node_generation(Page, Identity, Catalog) ->
    case quod_foreign_log:follow(Identity) of
        {ok, FollowRef} ->
            try await_node_projection(Page, Identity, FollowRef, Catalog)
            after quod_foreign_log:unfollow(FollowRef) end;
        {error, _} = Error -> Error
    end.

await_node_projection(Page, Identity, FollowRef, Catalog) ->
    receive
        {quod_foreign_follow, FollowRef, NoticeRef, Identity, Notice} ->
            ok = quod_foreign_log:ack(FollowRef, NoticeRef),
            case Notice of
                {resnapshot, _Height, _Projection, _Freshness} ->
                    case quod_foreign_log:projection_clauses(
                           FollowRef, [{agent_key, 3}, {hosts_ontology, 4}],
                           5000) of
                        {ok, Clauses} ->
                            quod_directory_generation:validate_projection(
                              Page, Clauses, Catalog);
                        {error, _} = Error -> Error
                    end;
                {building, _} ->
                    await_node_projection(Page, Identity, FollowRef, Catalog);
                {advanced, _From, _To, _Pubs, _Projection, _Freshness} ->
                    await_node_projection(Page, Identity, FollowRef, Catalog);
                {unreachable, Reason, _Height} -> {error, Reason}
            end
    after 10000 -> {error, validation_timeout}
    end.

finish_generation_validation(Token, Result,
                             S = #s{validations = Validations}) ->
    case validation_by_token(Token, Validations) of
        {ok, Author, #{mref := MRef, complete := Complete, pages := Pages,
                      source_key := SourceKey}} ->
            demonitor(MRef, [flush]),
            S0 = S#s{validations = maps:remove(Author, Validations)},
            case Result of
                ok ->
                    case install_generation(Complete) of
                        {ok, ExpiresAt} ->
                            Entry = #{pages => Pages, expires_at => ExpiresAt},
                            S1 = S0#s{generations =
                                         (S0#s.generations)#{Author => Entry}},
                            relay_validated_generation(
                              Pages, SourceKey, S1);
                        {error, _} -> S0
                    end;
                {error, _} -> S0
            end;
        error -> S
    end.

relay_validated_generation(Pages, SourceKey,
                           S = #s{self_key = SelfKey,
                                  control_peers = ControlPeers}) ->
    case maps:is_key(SelfKey, ControlPeers) of
        true -> send_generation_pages(Pages, SourceKey, S);
        false -> S
    end.

validation_by_token(Token, Validations) ->
    maps:fold(fun(Author, #{token := T} = Entry, error) when T =:= Token ->
                      {ok, Author, Entry};
                 (_Author, _Entry, Acc) -> Acc
              end, error, Validations).

handle_generation_validation_down(MRef, Pid, _Reason,
                                  S = #s{validations = Validations}) ->
    case maps:fold(
           fun(Author, #{pid := P, mref := R}, error)
                 when P =:= Pid, R =:= MRef -> {ok, Author};
              (_Author, _Entry, Acc) -> Acc
           end, error, Validations) of
        {ok, Author} ->
            {matched, S#s{validations = maps:remove(Author, Validations)}};
        error -> unmatched
    end.

send_cached_generations(Source, S = #s{generations = Generations}) ->
    {LinkPid, _PeerKey} = source_link_and_key(Source),
    Live = live_generations(Generations),
    maps:foreach(
      fun(_Author, #{pages := Pages}) ->
          lists:foreach(
            fun(Page) -> quod_link:send(LinkPid, generation_frame(Page)) end,
            Pages)
      end, Live),
    S#s{generations = Live}.


%%%===================================================================
%%% control-link resync
%%%===================================================================

send_current_and_resync(LinkPid, S) ->
    maps:foreach(
      fun(_Author, #{pages := Pages}) ->
          lists:foreach(
            fun(Page) -> quod_link:send(LinkPid, generation_frame(Page)) end,
            Pages)
      end, live_generations(S#s.generations)),
    quod_link:send(LinkPid, resync_request_frame()).

live_generations(Generations) ->
    Now = quod_time:mono_ms(),
    maps:filter(
      fun(_Author, #{expires_at := ExpiresAt}) -> ExpiresAt > Now end,
      Generations).

inbound(Payload, Source, S) ->
    case decode_control(Payload) of
        {generation, SignedPage} ->
            ingest_generation_page(SignedPage, Source, S);
        resync_request ->
            send_cached_generations(Source, S);
        error -> S
    end.

source_link_and_key({direct_link, PeerKey, _Endpoint, LinkPid}) ->
    {LinkPid, PeerKey};
source_link_and_key({pinned_link, PeerKey, LinkPid}) ->
    {LinkPid, PeerKey}.

decode_control(Payload)
  when is_binary(Payload), byte_size(Payload) =< ?MAX_CONTROL_BYTES ->
    case quod_safe_term:decode(Payload, ?MAX_CONTROL_BYTES) of
        {ok, {quod_directory_generation, SignedPage}}
          when is_binary(SignedPage),
               byte_size(SignedPage) =< ?MAX_ANNOUNCE_FRAME_BYTES ->
            {generation, SignedPage};
        {ok, quod_directory_generation_resync} -> resync_request;
        _ -> error
    end;
decode_control(_) -> error.

generation_frame(SignedPage) ->
    term_to_binary({quod_directory_generation, SignedPage}, [deterministic]).

resync_request_frame() ->
    term_to_binary(quod_directory_generation_resync, [deterministic]).

control_config(Opts) when is_map(Opts) ->
    RenewMs = maps:get(renew_ms, Opts, ?RENEW_MS),
    case normalize_root_contacts(maps:get(root_contacts, Opts, [])) of
        {ok, RootContacts}
          when is_integer(RenewMs), RenewMs >= ?RENEW_MS ->
            {ok, #{root_contacts => RootContacts,
                   renew_ms => RenewMs,
                   identity_dir =>
                       maps:get(identity_dir, Opts, undefined)}};
        _ ->
            {error, bad_config}
    end;
control_config(_) ->
    {error, bad_config}.

normalize_root_contacts(Contacts) when is_list(Contacts) ->
    Normalized = lists:usort(Contacts),
    case lists:all(
                   fun quod_quic:valid_endpoint/1, Normalized) of
        true -> {ok, Normalized};
        false -> error
    end;
normalize_root_contacts(_) ->
    error.

serving_identity(#{identity_dir := undefined}) ->
    %% Test-only non-serving mode. Production configuration always supplies
    %% the node identity directory through quod_app:apply_directory/1.
    disabled;
serving_identity(#{identity_dir := IdentityDir}) ->
    case {application:get_env(quod, node_pubkey),
          application:get_env(quod, identity_key),
          application:get_env(quod, node_addr)} of
        {{ok, NodeKey}, {ok, Signer}, {ok, Endpoint}}
          when is_binary(NodeKey), byte_size(NodeKey) =:= 32 ->
            case quod_quic:valid_endpoint(Endpoint) of
                false ->
                    {error, bad_endpoint};
                true ->
                    case quod_identity:advance_directory_epoch(IdentityDir) of
                        {ok, Epoch} ->
                            {ok, #{node_key => NodeKey, signer => Signer,
                                   endpoint => Endpoint, epoch => Epoch}};
                        {error, Reason} ->
                            {error, Reason}
                    end
            end;
        _ ->
            {error, missing_identity}
    end.

%%%===================================================================
%%% supervision recovery
%%%===================================================================

recover_lifecycle(S) ->
    arm_tick(S#s.renew_ms),
    maintain_directory_control(
      recover_route_demands(recover_tracking_event(S))).

recover_route_demands(S0) ->
    Identities = route_waiting_identities(),
    %% Re-enter through the directory owner: it is the single place that can
    %% translate a private target into its committed HostNodeRef identity.
    _ = [quod_directory:route_needed(Identity) || Identity <- Identities],
    S0.

route_waiting_identities() ->
    try
        lists:usort(
          [Identity
           || {Ns, Anchor} = Identity <-
                  gproc:select(
                    [{{{p, l, {directory_route, '$1'}}, '_', '_'},
                       [], ['$1']}]),
              is_binary(Ns), is_binary(Anchor), byte_size(Anchor) =:= 32])
    catch _:_ -> []
    end.

recover_tracking_event(S) ->
    case application:get_env(quod, directory_tracking, false) of
        true ->
            case set_observed_hosted(S) of
                {ok, S1} -> S1;
                {error, _} -> S
            end;
        false -> S
    end.

refresh_manager_snapshot(S = #s{manager_pid = Pid}) when is_pid(Pid) ->
    case catch quod_namespace_manager:hosting_snapshot() of
        {ok, Revision, Projection, Private}
          when is_integer(Revision), Revision >= 0, is_list(Projection),
               is_list(Private) ->
            install_private_projection(Private),
            S#s{hosting_revision = Revision,
                hosting_projection = Projection,
                private_projection = Private};
        _ -> S
    end;
refresh_manager_snapshot(S) -> S.

install_private_projection(Private) ->
    case quod_reg:where({directory, node}) of
        Pid when is_pid(Pid) ->
            _ = quod_directory:install_private_projection(Private),
            ok;
        undefined -> ok
    end.

observed_hosted(#s{hosting_projection = Projection}) ->
    case quod_reg:where({quod_ns_sup, node}) of
        Pid when is_pid(Pid) ->
            normalize_hosted(Projection);
        undefined ->
            {error, namespace_supervisor_unavailable}
    end.

reconcile_observed_hosted(S) ->
    case observed_hosted(S) of
        {ok, Hosted} ->
            {ok, S#s{hosted = Hosted}};
        {error, _} = Error ->
            Error
    end.

recover_directory_state(S) ->
    %% Reinstall only freshly received or locally re-signed generations.
    S1 = recover_route_demands(
           maintain_directory_control(
             S#s{generations = #{}, assemblies = #{}})),
    case {S1#s.tracking, can_advertise(S1),
          reconcile_observed_hosted(S1)} of
        {true, true, {ok, S2}} ->
            publish_hosted(S2);
        _ ->
            S1
    end.
