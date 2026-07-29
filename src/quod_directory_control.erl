-module(quod_directory_control).
-moduledoc """
Signed dissemination and renewal for `quod_directory`.

This process owns no directory answer index. It verifies and forwards
immutable signed records, while the bounded directory service remains the
sole ETS writer.
Directory-control authority comes from the local root ontology's committed
`peer_admitted/4` facts. A monitored worker reads that snapshot without
blocking this process; live transport hints locate the resulting keys, and
every directory link pins the peer key while suppressing address-cache learns.
Public snapshot reads do not confer ingest authority: this process accepts
snapshot replies only on its exact current outbound control links, and accepts
relayed announcements only from a current root control peer.
""".

-behaviour(gen_server).

-include("quod_directory_limits.hrl").

-export([start_link/0, start_link/1, start_tracking/0, namespace_changed/0,
         stats/0, channel/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-ifdef(TEST).
-export([snapshot_page/2, decode_control/1, test_ingest/2,
         test_set_control_peers/1, test_set_control_link/3,
         test_control_state/0, test_apply_peer_result/1,
         test_install_control_link/3,
         test_set_pending_link/3, test_validate_peer_proof/1]).
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
-define(MAX_RESYNC_RECORDS, 128).
-define(MAX_RESYNC_BYTES, (900 * 1024)).
-define(RESYNC_MIN_MS, 5000).
-define(RESYNC_SESSION_TTL_MS, 30000).

-record(s, {
    channel,
    enabled = false,
    self_key = undefined,
    signer = undefined,
    endpoint = undefined,
    epoch = undefined,
    sequence = 0,
    hosted = [],
    allowlist = #{},
    allowed_keys = #{},
    records = #{},
    control_peers = #{},
    dial_queue = {[], []},
    pending_links = #{},
    control_links = #{},
    peer_query = undefined,
    peer_height = undefined,
    peer_status = never_succeeded,
    last_resync = #{},
    renew_ms = ?RENEW_MS,
    directory_ref = undefined,
    tracking = false
}).

start_link() ->
    start_link(application:get_env(quod, directory, #{})).

start_link(Opts) ->
    gen_server:start_link(quod_reg:via(?KEY), ?MODULE, Opts, []).

-doc """
Start advertising the complete allowlisted intersection of namespaces actually
registered under `quod_ns_sup`. This is called once after application startup;
later namespace changes and renewals re-read that live registry.
""".
-spec start_tracking() -> ok | {error, term()}.
start_tracking() ->
    gen_server:call(quod_reg:via(?KEY), start_tracking, 10000).

-doc """
Reconcile advertisements with the namespaces currently owned by `quod_ns_sup`.
Lifecycle callers use this asynchronous notification; the periodic renewal also
reconciles, so a lost notification cannot leave a stale hosted set indefinitely.
""".
-spec namespace_changed() -> ok.
namespace_changed() ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            gen_server:cast(Pid, namespace_changed);
        undefined ->
            ok
    end.

stats() ->
    try gen_server:call(quod_reg:via(?KEY), stats, 1000)
    catch exit:_ -> undefined
    end.

-ifdef(TEST).
test_ingest(SignedRecord, Source) ->
    Caller = self(),
    Ref = make_ref(),
    _ = sys:replace_state(
          quod_reg:via(?KEY),
          fun(S) ->
              case accept_signed(SignedRecord, Source, false, S) of
                  {ok, S1} ->
                      Caller ! {Ref, ok},
                      S1;
                  {error, Reason} ->
                      Caller ! {Ref, {error, Reason}},
                      S
              end
          end),
    receive {Ref, Result} -> Result end.

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
      control_links => S#s.control_links,
      peer_query => S#s.peer_query,
      peer_height => S#s.peer_height,
      peer_status => S#s.peer_status}.

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
-endif.

channel() ->
    term_to_binary(quod_directory_control, [deterministic]).

init(Opts) ->
    Channel = channel(),
    true = quod_reg:subscribe({channel, Channel}),
    case control_config(Opts) of
        {ok, Cfg} ->
            Base = #s{channel = Channel,
                      self_key = local_node_key(),
                      allowlist = maps:get(allowlist, Cfg),
                      allowed_keys = maps:get(allowed_keys, Cfg),
                      renew_ms = maps:get(renew_ms, Cfg)},
            case serving_identity(Cfg) of
                disabled ->
                    {ok, recover_lifecycle(Base)};
                {ok, Identity} ->
                    {ok, recover_lifecycle(
                           Base#s{
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
              records => map_size(
                           active_records(
                             quod_time:mono_ms(), S#s.records)),
              control_peer_count => map_size(S#s.control_peers),
              control_link_count => map_size(S#s.control_links),
              control_pending_count => map_size(S#s.pending_links),
              root_proof_height => S#s.peer_height,
              root_proof_status => S#s.peer_status,
              epoch => S#s.epoch,
              sequence => S#s.sequence}, S};
handle_call(_Request, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(namespace_changed, S = #s{tracking = true}) ->
    case set_observed_hosted(S) of
        {ok, S1} ->
            {noreply, S1};
        {error, namespace_supervisor_unavailable} ->
            {noreply, S};
        {error, Reason} ->
            logger:warning(
              "quod: directory namespace reconciliation failed: ~p",
              [Reason]),
            {noreply, S}
    end;
handle_cast(_Message, S) ->
    {noreply, S}.

handle_info(directory_tick, S) ->
    {noreply, directory_tick(S)};
handle_info(refresh_control_peers, S) ->
    {noreply, maybe_start_peer_query(S)};
handle_info({directory_peer_result, Token, Result}, S) ->
    {noreply, handle_peer_result(Token, Result, S)};
handle_info({directory_peer_query_timeout, Token}, S) ->
    {noreply, handle_peer_query_timeout(Token, S)};
handle_info(
  {directory_control_dial_timeout, NodeKey, Endpoint, OpenRef}, S) ->
    {noreply,
     handle_control_dial_timeout(NodeKey, Endpoint, OpenRef, S)};
handle_info(recover_tracking, S) ->
    case observed_hosted(S) of
        {ok, Hosted} ->
            case hosted_ready(Hosted) of
                true ->
                    {noreply,
                     set_normalized_hosted(Hosted, S)};
                false ->
                    schedule_tracking_recovery(),
                    {noreply, S}
            end;
        {error, _} ->
            schedule_tracking_recovery(),
            {noreply, S}
    end;
handle_info(recover_directory, S) ->
    case quod_reg:where({directory, node}) of
        Pid when is_pid(Pid) ->
            Ref = monitor(process, Pid),
            {noreply, recover_directory_state(
                        S#s{directory_ref = Ref})};
        undefined ->
            _ = erlang:send_after(100, self(), recover_directory),
            {noreply, S}
    end;
handle_info({link_up, Ref, PeerKey, Channel, LinkPid},
            S = #s{channel = Channel}) ->
    {noreply, handle_control_link_up(
                Ref, PeerKey, LinkPid, S)};
handle_info({link_error, Ref, PeerKey, Channel},
            S = #s{channel = Channel})
  when is_binary(PeerKey), byte_size(PeerKey) =:= 32 ->
    {noreply, handle_control_link_error(PeerKey, Ref, S)};
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
handle_info({'DOWN', Ref, process, _Pid, _Reason},
            S = #s{directory_ref = Ref}) when is_reference(Ref) ->
    _ = erlang:send_after(100, self(), recover_directory),
    {noreply, S#s{directory_ref = undefined}};
handle_info({'DOWN', Ref, process, Pid, Reason}, S) ->
    case handle_peer_query_down(Ref, Pid, Reason, S) of
        {matched, S1} ->
            {noreply, S1};
        unmatched ->
            {noreply, handle_control_link_down(Ref, Pid, S)}
    end;
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, S) ->
    cleanup_control_state(S),
    _ = catch quod_reg:unsubscribe({channel, S#s.channel}),
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

root_peer_proof() ->
    Key = {'DirectoryControlKey'},
    Keys = {'DirectoryControlKeys'},
    Goal = {findall, Key, {directory_control_peer, Key}, Keys},
    validate_peer_proof(
      quod_prolog:prove_ro(?ROOT_NS, Goal, ?ROOT_NS)).

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
    apply_peer_result(Result, S0);
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
    S#s{peer_query = undefined,
        peer_status = {error, timeout}};
handle_peer_query_timeout(_Token, S) ->
    S.

handle_peer_query_down(
  MonitorRef, Pid, Reason,
  S = #s{peer_query = {Pid, MonitorRef, _Token, TimerRef}}) ->
    cancel_timer(TimerRef),
    schedule_peer_retry(),
    {matched,
     S#s{peer_query = undefined,
         peer_status = {error, {worker_down, Reason}}}};
handle_peer_query_down(_MonitorRef, _Pid, _Reason, _S) ->
    unmatched.

schedule_peer_retry() ->
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
    pump_control_dials(refresh_control_endpoints(S)).

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

pump_control_dials(
  S = #s{pending_links = Pending})
  when map_size(Pending) >= ?CONTROL_DIAL_LIMIT ->
    S;
pump_control_dials(S = #s{dial_queue = Queue}) ->
    case queue:out(Queue) of
        {empty, _} ->
            S;
        {{value, {NodeKey, Endpoint}}, Rest} ->
            S0 = S#s{dial_queue = Rest},
            case should_open_control(NodeKey, Endpoint, S0) of
                false ->
                    pump_control_dials(S0);
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
    Frame = resync_request_frame(0),
    maps:foreach(
      fun(_NodeKey, {_Endpoint, LinkPid, _MonitorRef}) ->
          quod_link:send(LinkPid, Frame)
      end, Links),
    S.

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
     control_links = Links}) ->
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

normalize_hosted(Namespaces, NodeKey, Allowlist) when is_list(Namespaces) ->
    %% The wire cap applies to the public advertisement, not to every private
    %% ontology this node may host locally.
    Hosted = lists:usort(
               [Ns || Ns <- Namespaces,
                      quod_directory_auth:allowed(
                        NodeKey, Ns, Allowlist)]),
    case quod_directory_auth:validate_namespaces(
           Hosted, ?DIRECTORY_MAX_NAMESPACES) of
        {ok, _} = Valid -> Valid;
        error -> {error, bad_namespaces}
    end;
normalize_hosted(_Namespaces, _NodeKey, _Allowlist) ->
    {error, bad_namespaces}.

set_normalized_hosted(Hosted, S = #s{tracking = true, hosted = Hosted}) ->
    S;
set_normalized_hosted(Hosted, S) ->
    S1 = maintain_directory_control(
           S#s{hosted = Hosted, tracking = true}),
    case can_advertise(S1) of
        false ->
            S1;
        true ->
            publish_hosted(S1, S1#s.self_key)
    end.

publish_hosted(S, NodeKey) ->
    case sign_current(S) of
        {ok, SignedRecord, S1} ->
            case accept_signed(
                   SignedRecord, {direct, NodeKey, S#s.endpoint},
                   false, S1) of
                {ok, S2} ->
                    send_control_frame(
                      announce_frame(SignedRecord),
                      NodeKey, S2);
                {error, rate_limited} ->
                    %% `hosted` is already the desired complete set. The single
                    %% periodic renewal retries it after the admission window.
                    S1;
                {error, Reason} ->
                    logger:warning(
                      "quod: local directory hosted-set update rejected: ~p",
                      [Reason]),
                    S1
            end;
        {error, Reason} ->
            logger:warning(
              "quod: directory hosted-set signing failed: ~p", [Reason]),
            S
    end.

directory_tick(S = #s{renew_ms = RenewMs}) ->
    arm_tick(RenewMs),
    S0 = S#s{records =
                 active_records(quod_time:mono_ms(), S#s.records)},
    SControl = maintain_directory_control(S0),
    case SControl#s.tracking andalso can_advertise(SControl) of
        true -> renew_advertisement(SControl);
        false -> SControl
    end.

renew_advertisement(S) ->
    case reconcile_observed_hosted(S) of
        {ok, S0} ->
            case sign_current(S0) of
                {ok, SignedRecord, S1} ->
                    case accept_signed(
                           SignedRecord,
                           {direct, S1#s.self_key, S1#s.endpoint},
                           false, S1) of
                        {ok, S2} ->
                            send_control_frame(
                              announce_frame(SignedRecord),
                              S2#s.self_key, S2);
                        {error, Reason} ->
                            logger:warning(
                              "quod: local directory renewal rejected: ~p",
                              [Reason]),
                            S1
                    end;
                {error, Reason} ->
                    logger:warning(
                      "quod: directory renewal signing failed: ~p", [Reason]),
                    S0
            end;
        {error, Reason} ->
            %% Never extend an advertisement when the node cannot prove its
            %% current hosted set. The old remote route will expire naturally.
            logger:warning(
              "quod: directory renewal skipped: ~p", [Reason]),
            S
    end.

can_advertise(#s{enabled = true, self_key = NodeKey,
                 allowed_keys = AllowedKeys}) ->
    maps:is_key(NodeKey, AllowedKeys);
can_advertise(_S) ->
    false.

sign_current(S = #s{self_key = NodeKey, endpoint = Endpoint,
                    hosted = Hosted, epoch = Epoch, sequence = Sequence,
                    signer = Signer}) ->
    Next = Sequence + 1,
    case quod_directory_record:sign(
           NodeKey, Endpoint, Hosted, Epoch, Next, Signer) of
        {ok, SignedRecord} ->
            {ok, SignedRecord, S#s{sequence = Next}};
        {error, _} = Error ->
            Error
    end.

arm_tick(Milliseconds) ->
    _ = erlang:send_after(Milliseconds, self(), directory_tick),
    ok.

%%%===================================================================
%%% signed ingress + dissemination
%%%===================================================================

accept_signed(SignedRecord, Source, Disseminate, S) ->
    case quod_directory_record:decode(SignedRecord) of
        {ok, Record} ->
            accept_decoded(
              Record, SignedRecord, Source, Disseminate, S);
        {error, _} = Error ->
            Error
    end.

accept_decoded(Record, SignedRecord, Source, Disseminate, S) ->
    case source_matches(Record, Source, S) of
        true ->
            NodeKey = quod_directory_record:node_key(Record),
            case install_directory_record(Record) of
                {ok, ExpiresAt} ->
                    %% Cache the directory owner's exact receiver-local
                    %% lease deadline; control never reconstructs TTL policy.
                    S1 = S#s{records =
                                (S#s.records)#{
                                  NodeKey =>
                                      {SignedRecord, ExpiresAt}}},
                    case Disseminate of
                        true ->
                            {ok,
                             fanout(
                               SignedRecord, NodeKey,
                               source_peer_key(Source), S1)};
                        false ->
                            {ok, S1}
                    end;
                {error, _} = Error ->
                    Error
            end;
        false ->
            {error, source_mismatch}
    end.

install_directory_record(Record) ->
    try
        quod_directory:install_record(
          quod_directory_record:node_key(Record),
          quod_directory_record:endpoint(Record),
          quod_directory_record:namespaces(Record),
          quod_directory_record:epoch(Record),
          quod_directory_record:sequence(Record))
    catch
        exit:_ -> {error, directory_unavailable}
    end.

source_matches(Record, {direct, PeerKey, PeerEndpoint}, _S) ->
    quod_directory_record:node_key(Record) =:= PeerKey
        andalso quod_directory_record:endpoint(Record) =:= PeerEndpoint;
source_matches(
  _Record, {relay, PeerKey},
  #s{control_peers = Peers}) ->
    maps:is_key(PeerKey, Peers);
source_matches(
  _Record, {resync, PeerKey, LinkPid}, S) ->
    control_link_current(PeerKey, LinkPid, S);
source_matches(_Record, _Source, _S) ->
    false.

source_peer_key({direct, PeerKey, _Endpoint}) ->
    PeerKey;
source_peer_key({relay, PeerKey}) ->
    PeerKey;
source_peer_key({resync, PeerKey, _LinkPid}) ->
    PeerKey.

fanout(
  SignedRecord, AuthorKey, SourceKey,
  S = #s{self_key = SelfKey, control_peers = Peers}) ->
    case maps:is_key(SelfKey, Peers) of
        true ->
            send_control_frame(
              announce_frame(SignedRecord),
              AuthorKey, SourceKey, S);
        false ->
            S
    end.

%%%===================================================================
%%% control-link resync
%%%===================================================================

send_current_and_resync(LinkPid, S) ->
    Now = quod_time:mono_ms(),
    case maps:get(S#s.self_key, S#s.records, undefined) of
        {Signed, ExpiresAt}
          when is_binary(Signed), ExpiresAt > Now ->
            quod_link:send(LinkPid, announce_frame(Signed));
        _ ->
            ok
    end,
    quod_link:send(LinkPid, resync_request_frame(0)).

inbound(Payload, Source, S) ->
    case decode_control(Payload) of
        {announce, SignedRecord} ->
            %% Reject public readers before record decoding/signature work.
            %% Every legitimate direct author is itself allowlisted somewhere;
            %% committed root control peers are the only additional relay
            %% authority.
            case control_source_allowed(Source, S) of
                false ->
                    S;
                true ->
                    case quod_directory_record:decode(SignedRecord) of
                        {ok, Record} ->
                            RecordSource = record_source(Record, Source),
                            case accept_decoded(
                                   Record, SignedRecord, RecordSource,
                                   true, S) of
                                {ok, S1} -> S1;
                                {error, _} -> S
                            end;
                        {error, _} ->
                            S
                    end
            end;
        {resync_request, Cursor} ->
            maybe_send_snapshot(Source, Cursor, S);
        {snapshot, Records, Next} ->
            case control_snapshot_source(Source, S) of
                error ->
                    S;
                {ok, ResyncSource, LinkPid} ->
                    S1 = lists:foldl(
                           fun(SignedRecord, Acc) ->
                               case accept_signed(
                                      SignedRecord, ResyncSource,
                                      false, Acc) of
                                   {ok, Accepted} -> Accepted;
                                   {error, _} -> Acc
                               end
                           end, S, Records),
                    maybe_request_next(LinkPid, Next),
                    S1
            end;
        error ->
            S
    end.

record_source(Record, {direct_link, PeerKey, PeerEndpoint, _LinkPid}) ->
    case quod_directory_record:node_key(Record) =:= PeerKey
             andalso quod_directory_record:endpoint(Record)
                         =:= PeerEndpoint of
        true -> {direct, PeerKey, PeerEndpoint};
        false -> {relay, PeerKey}
    end;
record_source(_Record, {pinned_link, PeerKey, _LinkPid}) ->
    {relay, PeerKey}.

control_source_allowed(
  Source,
  #s{allowed_keys = AllowedKeys, control_peers = Peers}) ->
    {_LinkPid, PeerKey} = source_link_and_key(Source),
    maps:is_key(PeerKey, AllowedKeys) orelse
        maps:is_key(PeerKey, Peers).

control_snapshot_source(
  {pinned_link, PeerKey, LinkPid}, S) ->
    case control_link_current(PeerKey, LinkPid, S) of
        true -> {ok, {resync, PeerKey, LinkPid}, LinkPid};
        false -> error
    end;
control_snapshot_source(_Source, _S) ->
    error.

maybe_send_snapshot(Source, Cursor, S) ->
    {LinkPid, PeerKey} = source_link_and_key(Source),
    Now = quod_time:mono_ms(),
    Sessions = active_resync_sessions(Now, S#s.last_resync),
    %% System routes are intentionally discoverable. The authenticated
    %% link identifies and rate-limits the reader; the advertisement
    %% allowlist is authority to answer, never a read ACL.
    case resync_capacity(PeerKey, Sessions)
             andalso resync_allowed(
                       Cursor, Now,
                       maps:get(PeerKey, Sessions, undefined)) of
        false ->
            S#s{last_resync = Sessions};
        true ->
            ActiveRecords = active_records(Now, S#s.records),
            {Records, Next} = snapshot_page(
                                Cursor, ActiveRecords),
            quod_link:send(LinkPid, snapshot_frame(Records, Next)),
            Resync1 =
                case Next of
                    done ->
                        Sessions#{PeerKey => {Now, done}};
                    _ ->
                        Sessions#{PeerKey => {Now, Next}}
                end,
            S#s{records = ActiveRecords,
                last_resync = Resync1}
    end.

resync_allowed(0, Now, undefined) ->
    is_integer(Now);
resync_allowed(0, Now, {Last, _Expected}) ->
    Now - Last >= ?RESYNC_MIN_MS;
resync_allowed(Cursor, _Now, {_Last, Cursor}) when Cursor > 0 ->
    true;
resync_allowed(_Cursor, _Now, _Session) ->
    false.

resync_capacity(PeerKey, Sessions) ->
    maps:is_key(PeerKey, Sessions) orelse
        map_size(Sessions) < 2048.

active_resync_sessions(Now, Sessions) ->
    maps:filter(
      fun(_PeerKey, {Last, _Expected}) ->
          is_integer(Last) andalso
              Now - Last < ?RESYNC_SESSION_TTL_MS
      end, Sessions).

maybe_request_next(_LinkPid, done) ->
    ok;
maybe_request_next(LinkPid, Next) when is_integer(Next), Next >= 0 ->
    quod_link:send(LinkPid, resync_request_frame(Next)).

source_link_and_key({direct_link, PeerKey, _Endpoint, LinkPid}) ->
    {LinkPid, PeerKey};
source_link_and_key({pinned_link, PeerKey, LinkPid}) ->
    {LinkPid, PeerKey}.

snapshot_page(Cursor, RecordsMap) ->
    Ordered = lists:keysort(1, maps:to_list(RecordsMap)),
    Remaining = drop(Cursor, Ordered),
    {PagePairs, More} = take_page(
                          Remaining, ?MAX_RESYNC_RECORDS,
                          ?MAX_RESYNC_BYTES, []),
    Page = [Record || {_NodeKey, {Record, _ExpiresAt}} <-
                          lists:reverse(PagePairs)],
    Next = case More of
               true -> Cursor + length(Page);
               false -> done
           end,
    {Page, Next}.

take_page([], _Count, _BytesLeft, Acc) ->
    {Acc, false};
take_page(_Remaining, 0, _BytesLeft, Acc) ->
    {Acc, true};
take_page(
  [{_NodeKey, {Record, _ExpiresAt}} = Pair | Rest],
  Count, BytesLeft, Acc) ->
    Size = byte_size(Record) + 16,
    case Size =< BytesLeft orelse Acc =:= [] of
        true ->
            take_page(Rest, Count - 1, BytesLeft - Size,
                      [Pair | Acc]);
        false ->
            {Acc, true}
    end.

drop(0, List) ->
    List;
drop(_Count, []) ->
    [];
drop(Count, [_ | Rest]) when Count > 0 ->
    drop(Count - 1, Rest).

%%%===================================================================
%%% control wire + config
%%%===================================================================

announce_frame(SignedRecord) ->
    term_to_binary(
      {quod_directory_announce, SignedRecord}, [deterministic]).

resync_request_frame(Cursor) ->
    term_to_binary(
      {quod_directory_resync, Cursor}, [deterministic]).

snapshot_frame(Records, Next) ->
    term_to_binary(
      {quod_directory_snapshot, Records, Next}, [deterministic]).

decode_control(Payload)
  when is_binary(Payload), byte_size(Payload) =< ?MAX_CONTROL_BYTES ->
    case quod_safe_term:decode(Payload, ?MAX_CONTROL_BYTES) of
        {ok, {quod_directory_announce, SignedRecord}}
          when is_binary(SignedRecord),
               byte_size(Payload) =< ?MAX_ANNOUNCE_FRAME_BYTES ->
            {announce, SignedRecord};
        {ok, {quod_directory_resync, Cursor}}
          when is_integer(Cursor), Cursor >= 0 ->
            {resync_request, Cursor};
        {ok, {quod_directory_snapshot, Records, Next}}
          when is_list(Records), length(Records) =< ?MAX_RESYNC_RECORDS,
               (Next =:= done orelse
                    (is_integer(Next) andalso Next >= 0)) ->
            case lists:all(fun is_binary/1, Records) of
                true -> {snapshot, Records, Next};
                false -> error
            end;
        _ ->
            error
    end;
decode_control(_) ->
    error.

control_config(Opts) when is_map(Opts) ->
    RenewMs = maps:get(renew_ms, Opts, ?RENEW_MS),
    case quod_directory_auth:normalize_allowlist(
           maps:get(allowlist, Opts, #{})) of
        {ok, Allowlist}
          when is_integer(RenewMs), RenewMs >= ?RENEW_MS ->
            {ok, #{allowlist => Allowlist,
                   allowed_keys =>
                       quod_directory_auth:node_key_index(
                         Allowlist),
                   renew_ms => RenewMs,
                   identity_dir =>
                       maps:get(identity_dir, Opts, undefined)}};
        _ ->
            {error, bad_config}
    end;
control_config(_) ->
    {error, bad_config}.

serving_identity(#{identity_dir := undefined}) ->
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
    DirectoryRef =
        case quod_reg:where({directory, node}) of
            Pid when is_pid(Pid) -> monitor(process, Pid);
            undefined -> undefined
        end,
    case application:get_env(quod, directory_tracking, false) of
        true -> schedule_tracking_recovery();
        false -> ok
    end,
    self() ! directory_tick,
    S#s{directory_ref = DirectoryRef}.

schedule_tracking_recovery() ->
    _ = erlang:send_after(100, self(), recover_tracking),
    ok.

observed_hosted(#s{self_key = NodeKey, allowlist = Allowlist}) ->
    case quod_reg:where({quod_ns_sup, node}) of
        Pid when is_pid(Pid) ->
            %% gproc names are unique already. Filter the potentially large
            %% private set before sorting the bounded public subset.
            normalize_hosted(
              quod_ns_sup:namespaces(), NodeKey, Allowlist);
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

hosted_ready(Hosted) ->
    lists:all(
      fun(Ns) ->
          quod_reg:where({quod_prolog, Ns}) =/= undefined
      end, Hosted).

recover_directory_state(S) ->
    %% Peer leases cannot be restored without extending their receiver-local
    %% expiry. Drop them and obtain fresh authenticated announcements/resync.
    S1 = maintain_directory_control(S#s{records = #{}}),
    case {S1#s.tracking, can_advertise(S1),
          reconcile_observed_hosted(S1)} of
        {true, true, {ok, S2}} ->
            publish_hosted(S2, S2#s.self_key);
        _ ->
            S1
    end.

active_records(Now, Records) ->
    maps:filter(
      fun(_NodeKey, {_SignedRecord, ExpiresAt}) ->
          is_integer(ExpiresAt) andalso ExpiresAt > Now
      end, Records).
