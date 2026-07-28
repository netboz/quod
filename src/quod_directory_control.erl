-module(quod_directory_control).
-moduledoc """
Signed dissemination and renewal for `quod_directory`.

This process owns no query state. It verifies and forwards immutable signed
records, while the bounded directory service remains the sole ETS writer.
Each configured bootstrap endpoint's first successful contact uses the
transport's scoped TOFU/no-learn mode; after its certificate key is known,
periodic resync and every later send are pinned to that key and endpoint.
Public snapshot reads do not confer ingest authority: this process accepts
snapshot replies only on its configured bootstrap links, and accepts relayed
announcements only from an allowlisted system host or configured bootstrap.
""".

-behaviour(gen_server).

-include("quod_directory_limits.hrl").

-export([start_link/0, start_link/1, start_tracking/0, namespace_changed/0,
         stats/0, channel/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-ifdef(TEST).
-export([snapshot_page/2, decode_control/1, test_ingest/2,
         test_seed_links/0]).
-endif.

-define(KEY, {directory, control}).
-define(RENEW_MS, 10000).
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
    bootstrap_seeds = [],
    bootstrap_queue = [],
    pending_seed = undefined,
    bootstrap_bindings = #{},
    seed_links = #{},
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

test_seed_links() ->
    S = sys:get_state(quod_reg:via(?KEY)),
    maps:keys(S#s.seed_links).
-endif.

channel() ->
    term_to_binary(quod_directory_control, [deterministic]).

init(Opts) ->
    Channel = channel(),
    true = quod_reg:subscribe({channel, Channel}),
    case control_config(Opts) of
        {ok, Cfg} ->
            case serving_identity(Cfg) of
                disabled ->
                    {ok, recover_lifecycle(#s{channel = Channel,
                            allowlist = maps:get(allowlist, Cfg),
                            allowed_keys = maps:get(allowed_keys, Cfg),
                            bootstrap_seeds = maps:get(bootstraps, Cfg),
                            bootstrap_queue = maps:get(bootstraps, Cfg),
                            renew_ms = maps:get(renew_ms, Cfg)})};
                {ok, Identity} ->
                    {ok, recover_lifecycle(#s{channel = Channel,
                            enabled = true,
                            self_key = maps:get(node_key, Identity),
                            signer = maps:get(signer, Identity),
                            endpoint = maps:get(endpoint, Identity),
                            epoch = maps:get(epoch, Identity),
                            allowlist = maps:get(allowlist, Cfg),
                            allowed_keys = maps:get(allowed_keys, Cfg),
                            bootstrap_seeds = maps:get(bootstraps, Cfg),
                            bootstrap_queue = maps:get(bootstraps, Cfg),
                            renew_ms = maps:get(renew_ms, Cfg)})};
                {error, Reason} ->
                    {stop, {directory_identity_failed, Reason}}
            end;
        {error, Reason} ->
            {stop, {bad_directory_control_config, Reason}}
    end.

handle_call(start_tracking, _From, S) ->
    case observed_namespaces() of
        {ok, Namespaces} ->
            case set_hosted_now(Namespaces, S) of
                {ok, S1} ->
                    application:set_env(quod, directory_tracking, true),
                    {reply, ok, S1};
                {error, Reason} ->
                    {reply, {error, Reason}, S}
            end;
        unavailable ->
            {reply, {error, namespace_supervisor_unavailable}, S}
    end;
handle_call(stats, _From, S) ->
    {reply, #{enabled => S#s.enabled,
              tracking => S#s.tracking,
              records => map_size(
                           active_records(
                             quod_time:mono_ms(), S#s.records)),
              bootstraps => map_size(S#s.bootstrap_bindings),
              epoch => S#s.epoch,
              sequence => S#s.sequence}, S};
handle_call(_Request, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(namespace_changed, S = #s{tracking = true}) ->
    case observed_namespaces() of
        {ok, Namespaces} ->
            case set_hosted_now(Namespaces, S) of
                {ok, S1} -> {noreply, S1};
                {error, Reason} ->
                    logger:warning(
                      "quod: directory namespace reconciliation failed: ~p",
                      [Reason]),
                    {noreply, S}
            end;
        unavailable ->
            {noreply, S}
    end;
handle_cast(_Message, S) ->
    {noreply, S}.

handle_info(directory_tick, S) ->
    {noreply, directory_tick(S)};
handle_info(recover_tracking, S) ->
    case observed_namespaces() of
        {ok, Namespaces} ->
            case normalize_hosted(
                   Namespaces, S#s.self_key, S#s.allowlist) of
                {ok, Hosted} ->
                    case hosted_ready(Hosted) of
                        true ->
                            case set_normalized_hosted(Hosted, S) of
                                {ok, S1} -> {noreply, S1};
                                {error, _} ->
                                    schedule_tracking_recovery(),
                                    {noreply, S}
                            end;
                        false ->
                            schedule_tracking_recovery(),
                            {noreply, S}
                    end;
                {error, _} ->
                    schedule_tracking_recovery(),
                    {noreply, S}
            end;
        unavailable ->
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
            S = #s{channel = Channel, pending_seed = {Endpoint, Ref}})
  when is_binary(PeerKey), byte_size(PeerKey) =:= 32,
       Endpoint =/= undefined ->
    _ = monitor(process, LinkPid),
    S1 = S#s{
           pending_seed = undefined,
           bootstrap_bindings =
               (S#s.bootstrap_bindings)#{Endpoint => PeerKey},
           seed_links = (S#s.seed_links)#{LinkPid => {Endpoint, PeerKey}}},
    send_current_and_resync(LinkPid, S1),
    {noreply, contact_next_bootstrap(S1)};
handle_info({link_error, Ref, _Peer, Channel},
            S = #s{channel = Channel, pending_seed = {_Endpoint, Ref}}) ->
    {noreply, contact_next_bootstrap(S#s{pending_seed = undefined})};
handle_info({quod_message, {{PeerKey, PeerEndpoint}, LinkPid}, Channel, Payload},
            S = #s{channel = Channel})
  when is_binary(PeerKey), byte_size(PeerKey) =:= 32 ->
    {noreply, inbound(
                Payload, {direct_link, PeerKey, PeerEndpoint, LinkPid}, S)};
handle_info({quod_message, {PeerKey, LinkPid}, Channel, Payload},
            S = #s{channel = Channel})
  when is_binary(PeerKey), byte_size(PeerKey) =:= 32 ->
    %% Payload received on a link we opened (notably bootstrap resync). Its
    %% TLS key was bound before link_up; the dial endpoint is tracked privately.
    Source =
        case maps:get(LinkPid, S#s.seed_links, undefined) of
            {_Endpoint, PeerKey} -> {seed_link, PeerKey, LinkPid};
            _ -> {pinned_link, PeerKey, LinkPid}
        end,
    {noreply, inbound(Payload, Source, S)};
handle_info({'DOWN', Ref, process, _Pid, _Reason},
            S = #s{directory_ref = Ref}) when is_reference(Ref) ->
    _ = erlang:send_after(100, self(), recover_directory),
    {noreply, S#s{directory_ref = undefined}};
handle_info({'DOWN', _Ref, process, LinkPid, _Reason},
            S = #s{seed_links = Links}) ->
    {noreply, S#s{seed_links = maps:remove(LinkPid, Links)}};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, S) ->
    _ = catch quod_reg:unsubscribe({channel, S#s.channel}),
    ok.

%%%===================================================================
%%% local lifecycle
%%%===================================================================

set_hosted_now(Namespaces, S = #s{self_key = NodeKey,
                                  allowlist = Allowlist}) ->
    case normalize_hosted(Namespaces, NodeKey, Allowlist) of
        {ok, Hosted} ->
            set_normalized_hosted(Hosted, S);
        {error, _} ->
            {error, bad_namespaces}
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
    {ok, S};
set_normalized_hosted(Hosted, S = #s{tracking = WasTracking}) ->
    S1 = contact_next_bootstrap(
           S#s{hosted = Hosted, tracking = true}),
    maybe_start_tick(not WasTracking, S1#s.renew_ms),
    case can_advertise(S1) of
        false ->
            {ok, S1};
        true ->
            {ok, publish_hosted(S1, S1#s.self_key)}
    end.

publish_hosted(S, NodeKey) ->
    case sign_current(S) of
        {ok, SignedRecord, S1} ->
            case accept_signed(
                   SignedRecord, {direct, NodeKey, S#s.endpoint},
                   false, S1) of
                {ok, S2} ->
                    send_bootstraps(
                      announce_frame(SignedRecord),
                      contact_next_bootstrap(
                        fanout(SignedRecord, NodeKey, S2)));
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

maybe_start_tick(true, Milliseconds) -> arm_tick(Milliseconds);
maybe_start_tick(false, _Milliseconds) -> ok.

directory_tick(S = #s{tracking = false}) ->
    S;
directory_tick(S = #s{renew_ms = RenewMs}) ->
    arm_tick(RenewMs),
    S0 = S#s{records =
                 active_records(quod_time:mono_ms(), S#s.records)},
    SBootstrap = maintain_bootstraps(S0),
    case can_advertise(SBootstrap) of
        true -> renew_advertisement(SBootstrap);
        false -> SBootstrap
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
                            send_bootstraps(
                              announce_frame(SignedRecord),
                              fanout(SignedRecord, S2#s.self_key, S2));
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
    case source_matches(Record, Source) of
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
                                true -> {ok, fanout(SignedRecord, NodeKey, S1)};
                                false -> {ok, S1}
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

source_matches(Record, {direct, PeerKey, PeerEndpoint}) ->
    quod_directory_record:node_key(Record) =:= PeerKey
        andalso quod_directory_record:endpoint(Record) =:= PeerEndpoint;
source_matches(_Record, relay) ->
    true;
source_matches(_Record, resync) ->
    true;
source_matches(_Record, _) ->
    false.

fanout(SignedRecord, AuthorKey, S = #s{self_key = SelfKey}) ->
    Frame = announce_frame(SignedRecord),
    lists:foreach(
      fun({NodeKey, Endpoint}) ->
          case NodeKey =/= AuthorKey andalso NodeKey =/= SelfKey of
              true ->
                  quod_quic:send_pinned(
                    NodeKey, Endpoint, S#s.channel, Frame);
              false ->
                  ok
          end
      end,
      quod_directory:system_routes()),
    S.

send_bootstraps(Frame, S = #s{bootstrap_bindings = Bindings}) ->
    _ = maps:fold(
          fun(Endpoint, NodeKey, ok) ->
              quod_quic:send_pinned(NodeKey, Endpoint, S#s.channel, Frame)
          end, ok, Bindings),
    S.

%%%===================================================================
%%% bootstrap + resync
%%%===================================================================

contact_next_bootstrap(S = #s{pending_seed = undefined,
                              bootstrap_queue = [Endpoint | Rest]}) ->
    Ref = quod_quic:open_link_seed(Endpoint, S#s.channel),
    S#s{pending_seed = {Endpoint, Ref}, bootstrap_queue = Rest};
contact_next_bootstrap(S) ->
    S.

maintain_bootstraps(S) ->
    retry_missing_bootstraps(send_bootstrap_resyncs(S)).

send_bootstrap_resyncs(
  S = #s{bootstrap_bindings = Bindings, seed_links = SeedLinks}) ->
    Live =
        maps:fold(
          fun(LinkPid, {Endpoint, NodeKey}, Acc) ->
              Acc#{{Endpoint, NodeKey} => LinkPid}
          end, #{}, SeedLinks),
    Frame = resync_request_frame(0),
    _ = maps:fold(
          fun(Endpoint, NodeKey, ok) ->
              case maps:get({Endpoint, NodeKey}, Live, undefined) of
                  LinkPid when is_pid(LinkPid) ->
                      quod_link:send(LinkPid, Frame);
                  undefined ->
                      quod_quic:send_pinned(
                        NodeKey, Endpoint, S#s.channel, Frame)
              end
          end, ok, Bindings),
    S.

retry_missing_bootstraps(
  S = #s{pending_seed = undefined, bootstrap_queue = [],
         bootstrap_seeds = Seeds, bootstrap_bindings = Bindings}) ->
    Missing = [Endpoint || Endpoint <- Seeds,
                           not maps:is_key(Endpoint, Bindings)],
    contact_next_bootstrap(S#s{bootstrap_queue = Missing});
retry_missing_bootstraps(S) ->
    S.

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
            %% configured bootstraps are the only additional relay authority.
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
            case bootstrap_snapshot_source(Source, S) of
                false ->
                    S;
                true ->
                    S1 = lists:foldl(
                           fun(SignedRecord, Acc) ->
                               case accept_signed(
                                      SignedRecord, resync, false, Acc) of
                                   {ok, Accepted} -> Accepted;
                                   {error, _} -> Acc
                               end
                           end, S, Records),
                    maybe_request_next(Source, Next),
                    S1
            end;
        error ->
            S
    end.

record_source(Record, {direct_link, PeerKey, PeerEndpoint, _LinkPid}) ->
    case quod_directory_record:node_key(Record) =:= PeerKey of
        true -> {direct, PeerKey, PeerEndpoint};
        false -> relay
    end;
record_source(_Record, _Source) ->
    relay.

control_source_allowed(Source, #s{allowed_keys = AllowedKeys} = S) ->
    case source_link_and_key(Source) of
        {ok, _LinkPid, PeerKey} ->
            maps:is_key(PeerKey, AllowedKeys) orelse
                bootstrap_peer(PeerKey, S);
        error ->
            false
    end.

bootstrap_peer(PeerKey, #s{bootstrap_bindings = Bindings}) ->
    lists:member(PeerKey, maps:values(Bindings)).

bootstrap_snapshot_source(
  {seed_link, PeerKey, LinkPid}, #s{seed_links = SeedLinks}) ->
    case maps:get(LinkPid, SeedLinks, undefined) of
        {_Endpoint, PeerKey} -> true;
        _ -> false
    end;
bootstrap_snapshot_source(
  {pinned_link, PeerKey, _LinkPid}, S) ->
    bootstrap_peer(PeerKey, S);
bootstrap_snapshot_source(_Source, _S) ->
    false.

maybe_send_snapshot(Source, Cursor, S) ->
    case source_link_and_key(Source) of
        {ok, LinkPid, PeerKey} ->
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
            end;
        error ->
            S
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

maybe_request_next(_Source, done) ->
    ok;
maybe_request_next(Source, Next) when is_integer(Next), Next >= 0 ->
    case source_link_and_key(Source) of
        {ok, LinkPid, _PeerKey} ->
            quod_link:send(LinkPid, resync_request_frame(Next));
        error ->
            ok
    end.

source_link_and_key({direct_link, PeerKey, _Endpoint, LinkPid}) ->
    {ok, LinkPid, PeerKey};
source_link_and_key({seed_link, PeerKey, LinkPid}) ->
    {ok, LinkPid, PeerKey};
source_link_and_key({pinned_link, PeerKey, LinkPid}) ->
    {ok, LinkPid, PeerKey};
source_link_and_key(_) ->
    error.

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
take_page(Remaining, 0, _BytesLeft, Acc) ->
    {Acc, Remaining =/= []};
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
    Bootstraps = maps:get(bootstraps, Opts, []),
    RenewMs = maps:get(renew_ms, Opts, ?RENEW_MS),
    case quod_directory_auth:normalize_allowlist(
           maps:get(allowlist, Opts, #{})) of
        {ok, Allowlist}
          when is_list(Bootstraps), length(Bootstraps) =< 32,
               is_integer(RenewMs), RenewMs >= ?RENEW_MS ->
            case lists:all(fun quod_quic:valid_endpoint/1, Bootstraps) of
                true ->
                    {ok, #{allowlist => Allowlist,
                           allowed_keys =>
                               quod_directory_auth:node_key_index(
                                 Allowlist),
                           bootstraps => lists:usort(Bootstraps),
                           renew_ms => RenewMs,
                           identity_dir =>
                               maps:get(identity_dir, Opts, undefined)}};
                false ->
                    {error, bad_config}
            end;
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
    S#s{directory_ref = DirectoryRef}.

schedule_tracking_recovery() ->
    _ = erlang:send_after(100, self(), recover_tracking),
    ok.

observed_namespaces() ->
    case quod_reg:where({quod_ns_sup, node}) of
        Pid when is_pid(Pid) ->
            %% gproc names are unique already. Filter the potentially large
            %% private set before sorting the bounded public subset.
            {ok, quod_ns_sup:namespaces()};
        undefined ->
            unavailable
    end.

reconcile_observed_hosted(S = #s{self_key = NodeKey,
                                 allowlist = Allowlist}) ->
    case observed_namespaces() of
        {ok, Namespaces} ->
            case normalize_hosted(Namespaces, NodeKey, Allowlist) of
                {ok, Hosted} ->
                    {ok, S#s{hosted = Hosted}};
                {error, _} ->
                    {error, bad_namespaces}
            end;
        unavailable ->
            {error, namespace_supervisor_unavailable}
    end.

hosted_ready(Hosted) ->
    lists:all(
      fun(Ns) ->
          quod_reg:where({quod_prolog, Ns}) =/= undefined
      end, Hosted).

recover_directory_state(S) ->
    %% Peer leases cannot be restored without extending their receiver-local
    %% expiry. Drop them and obtain fresh authenticated announcements/resync.
    S1 = maintain_bootstraps(S#s{records = #{}}),
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
