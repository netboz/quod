-module(quod_foreign_log).
-moduledoc """
Bounded node-wide verifier/cache for foreign certified DTX references.

The owner is intentionally separate from every hosted namespace.  It selects
from certified directory/history routes, caller-supplied historical routes,
and bounded contacts learned from authenticated peers.  Callers may also name
one explicit authenticated route.  The owner admits an exact certified
reference under global/per-peer and history/cache bounds, then a monitored
worker pulls the existing catch-up page format over an identity-pinned
connection.  The worker folds the history from the caller-pinned
`{Namespace, GenesisAnchor}` through `quod_catchup`; no route, peer response,
cache checkpoint, or reference field is trusted by itself.
Success additionally requires that `PeerKey` belongs to the committee in the
verified post-reference-slot projection; a directory `validator` label is only
a candidate hint.  A non-member is a retryable route failure, never proof that
the certified reference itself is invalid.

The same owner also derives a certificate-verified current committee view for
an anchored identity. `quod_dtx_current_view` uses that frozen view to select
distinct current validator keys and to bind outcome/application probes to one
committee id and minimum slot. Routes remain transport hints and never become
committee evidence.

`verify/5`, `verify_reference/3`, and the current-view APIs are synchronous only from the caller's
perspective. The gen_server never waits for network, disk replay, certificate
verification, or crypto; DTX validation callers invoke them from their existing
asynchronous verdict/recovery worker boundary.

Long-lived ontology follows are another consumer of this same owner and cache.
They add no verifier or history path: a short monitored verification worker
advances at most one certified page, and one unregistered materializer folds
only the already-persisted cache through `quod_committed_projection`.
""".

-behaviour(gen_server).

-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").
-include("quod_directory_limits.hrl").
-include("quod_transport_limits.hrl").

-export([start_link/0, start_link/1,
         verify/5, verify_reference/3, verify_local/4,
         verify_current/3, verify_local_current/3,
         current/3, local_current/3,
         observe_candidate/2, route_hints/2,
         follow/1, ack/2, unfollow/1,
         required_references/1, stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-ifdef(TEST).
-export([cache_namespace/1, valid_projection/2]).
-endif.

-define(KEY, {foreign_log, node}).
-define(DEFAULT_PAGE_TIMEOUT_MS, 8000).
-define(MANIFEST, "identity.term").
-define(CHECKPOINT, "checkpoint.term").
-define(LOG, "log.0001").
-define(CACHE_VERSION, 2).
-define(MAX_UINT64, 16#FFFFFFFFFFFFFFFF).
-define(MAX_TIMER_MS, 16#FFFFFFFF).
-define(MANIFEST_RESERVE_BYTES, 4096).
-define(MAX_CURRENT_ROUTE_HINTS, (2 * ?MAX_VALIDATORS)).
-define(MAX_BOOTSTRAP_IDENTITIES_PER_PEER, ?DIRECTORY_MAX_NAMESPACES).
-define(DEFAULT_FOLLOW_POLL_MS, 5000).
-define(DEFAULT_FOLLOW_RETRY_MS, 250).
-define(DEFAULT_FOLLOW_MAX_RETRY_MS, 30000).
-define(MAX_CHANGED_HEADS, ?QUOD_MAX_PLAN_DIFF_OPS).

-record(consumer, {
          pid :: pid(),
          mref :: reference(),
          outstanding = none :: none | {reference(), term()},
          pending = none :: none | term()
         }).

-record(materializer, {
          pid :: pid(),
          mref :: reference(),
          generation :: reference(),
          height = 0 :: non_neg_integer(),
          projection_id = none :: none | <<_:256>>,
          memory_bytes = 0 :: non_neg_integer()
         }).

-record(history, {
          identity :: {binary(), <<_:256>>},
          cache_ns :: binary(),
          height = 0 :: non_neg_integer(),
          bytes = 0 :: non_neg_integer(),
          projection = undefined :: undefined | map(),
          last_used = 0 :: integer(),
          active = none :: none | reference(),
          consumers = #{} :: #{reference() => #consumer{}},
          follow_timer = none :: none | reference(),
          follow_token = none :: none | reference(),
          retry_ms = ?DEFAULT_FOLLOW_RETRY_MS :: pos_integer(),
          materializer = none :: none | #materializer{},
          last_probe_ms = 0 :: integer(),
          last_advance_ms = 0 :: integer(),
          hinted_height = unknown :: unknown | non_neg_integer(),
          current_view = unconfirmed :: confirmed | unconfirmed,
          projection_state = building :: building | ready,
          reachability = unknown :: reachable | unknown | {unreachable, term()},
          bootstrap_hints = [] :: [{<<_:256>>, term()}]
         }).

-record(request, {
          from :: gen_server:from() | {follow, {binary(), <<_:256>>}, reference()},
          peer :: term(),
          identity :: {binary(), <<_:256>>},
          worker :: pid(),
          mref :: reference(),
          timer :: reference(),
          timed_out = false :: boolean()
         }).

-record(pull, {
          from :: gen_server:from(),
          request_ref :: reference(),
          peer :: <<_:256>>,
          timer :: reference()
         }).

-record(s, {
          root :: file:filename_all(),
          fetch_fun = undefined :: undefined | function(),
          page_timeout_ms = ?DEFAULT_PAGE_TIMEOUT_MS :: pos_integer(),
          pending = #{} :: #{reference() => #request{}},
          peer_counts = #{} :: #{term() => pos_integer()},
          pulls = #{} :: #{reference() => #pull{}},
          histories = #{} :: #{{binary(), binary()} => #history{}},
          follows = #{} :: #{reference() => {binary(), <<_:256>>}},
          total_bytes = 0 :: non_neg_integer(),
          projection_bytes = 0 :: non_neg_integer(),
          projection_max_bytes = ?QUOD_MAX_FOREIGN_PROJECTION_BYTES :: pos_integer(),
          follow_poll_ms = ?DEFAULT_FOLLOW_POLL_MS :: pos_integer(),
          follow_retry_ms = ?DEFAULT_FOLLOW_RETRY_MS :: pos_integer(),
          follow_max_retry_ms = ?DEFAULT_FOLLOW_MAX_RETRY_MS :: pos_integer(),
          follow_polls = 0 :: non_neg_integer(),
          follow_pages = 0 :: non_neg_integer(),
          follow_entries = 0 :: non_neg_integer(),
          follow_bytes = 0 :: non_neg_integer(),
          follow_coalesced = 0 :: non_neg_integer(),
          follow_retries = 0 :: non_neg_integer(),
          projection_rebuilds = 0 :: non_neg_integer(),
          max_follow_lag = 0 :: non_neg_integer(),
          bootstrap_accepted = 0 :: non_neg_integer(),
          bootstrap_rejected = 0 :: non_neg_integer(),
          bootstrap_evicted = 0 :: non_neg_integer(),
          channels = #{} :: #{binary() => {binary(), pos_integer()}}
         }).

%%%===================================================================
%%% Public API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link(application:get_env(quod, foreign_log, #{})).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) when is_map(Opts) ->
    gen_server:start_link(quod_reg:via(?KEY), ?MODULE, Opts, []).

-doc """
Verify one exact foreign DTX reference through one explicit source.

This is the low-level exact-source form used for isolated verification and
adversarial checks. Normal DTX recovery uses `verify_reference/3`, which
selects and rotates sources inside this owner. Both forms use the same cache,
history fold, certificate checks, and resource accounting.
""".
-spec verify(<<_:256>>, term(), quod_dtx:certified_ref(),
             'begin' | prepare | decision | finalize | complete,
             pos_integer()) ->
          {ok, map()} | {error, term()}.
verify(PeerKey, Endpoint, Ref, ExpectedPhase, TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            try gen_server:call(
                  Pid, {verify, PeerKey, Endpoint, Ref, ExpectedPhase,
                        TimeoutMs}, TimeoutMs + 1000)
            catch exit:_ -> {error, retry}
            end;
        undefined ->
            {error, retry}
    end;
verify(_PeerKey, _Endpoint, _Ref, _ExpectedPhase, _TimeoutMs) ->
    {error, bad_foreign_reference}.

-doc """
Verify one exact foreign DTX reference through the shared source selector.

Certified directory routes, certified history routes, and bounded authenticated
bootstrap candidates are transport hints only.  The existing history verifier
still proves the exact anchor, phase, certificate chain, and serving committee.
""".
-spec verify_reference(quod_dtx:certified_ref(),
                       'begin' | prepare | decision | finalize | complete,
                       pos_integer()) -> {ok, map()} | {error, term()}.
verify_reference(Ref, ExpectedPhase, TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            try gen_server:call(
                  Pid, {verify_reference, Ref, ExpectedPhase, TimeoutMs},
                  TimeoutMs + 1000)
            catch exit:_ -> {error, retry}
            end;
        undefined ->
            {error, retry}
    end;
verify_reference(_Ref, _ExpectedPhase, _TimeoutMs) ->
    {error, bad_foreign_reference}.

-doc """
Remember one TLS-authenticated node contact as an untrusted source candidate.

The call is asynchronous so an ingress statem never blocks on cache ownership.
It grants no ontology role and is useful only if later certified history from
that endpoint proves the exact supplied identity.
""".
-spec observe_candidate({binary(), <<_:256>>}, {<<_:256>>, term()}) -> ok.
observe_candidate(Identity, {PeerKey, Endpoint}) ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            gen_server:cast(Pid, {observe_candidate, Identity,
                                  PeerKey, Endpoint});
        undefined ->
            ok
    end;
observe_candidate(_Identity, _Contact) ->
    ok.

-doc """
Return the one bounded route-hint view for an exact ontology identity.

`Supplied` may contain already-certified historical routes from a caller.  It
is merged inside the foreign-log owner with directory, cached-history, and
authenticated bootstrap hints; no caller should reimplement that merge.
""".
-spec route_hints({binary(), <<_:256>>}, [{<<_:256>>, term()}]) ->
          {ok, [{<<_:256>>, term()}]} |
          {error, unavailable | anchor_conflict | invalid_request}.
route_hints(Identity, Supplied) ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            try gen_server:call(Pid, {route_hints, Identity, Supplied}, 1000)
            catch exit:_ -> {error, unavailable}
            end;
        undefined ->
            {error, unavailable}
    end.

-doc """
Verify one exact reference against a co-hosted namespace's durable ledger.

The same bounded cache and forward verifier as `verify/5` are used, but pages
come from `LedgerRoot` instead of the network and no route-peer membership
claim is needed.  Returned generation, committee, committee id, and validator
routes are those immediately after the referenced slot, never current state.
""".
-spec verify_local(file:filename_all(), quod_dtx:certified_ref(),
                   'begin' | prepare | decision | finalize | complete,
                   pos_integer()) ->
          {ok, map()} | {error, term()}.
verify_local(LedgerRoot, Ref, ExpectedPhase, TimeoutMs)
  when (is_list(LedgerRoot) orelse is_binary(LedgerRoot)),
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            try gen_server:call(
                  Pid,
                  {verify_local, LedgerRoot, Ref, ExpectedPhase, TimeoutMs},
                  TimeoutMs + 1000)
            catch exit:_ -> {error, retry}
            end;
        undefined ->
            {error, retry}
    end;
verify_local(_LedgerRoot, _Ref, _ExpectedPhase, _TimeoutMs) ->
    {error, bad_foreign_reference}.

-doc """
Return one quorum-corroborated certified view at or after `FinalizeRef`.

`Routes` are identity-pinned fetch hints, never committee evidence.  The
worker verifies the exact Finalize, takes one bounded snapshot of the available
next page, folds only the longest certificate-valid prefix observed in that
snapshot, then requires a full quorum of distinct keys in the resulting
committee to report a durable height at least as high.  Content appended after
the snapshot is deliberately not chased; an applied-status committee-id
mismatch makes the caller take another snapshot.
""".
-spec verify_current([{<<_:256>>, term()}], quod_dtx:certified_ref(),
                     pos_integer()) ->
          {ok, map()} | {error, term()}.
verify_current(Routes0, Ref, TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case normalize_route_hints(Routes0) of
        {ok, [_ | _] = Routes} ->
            case quod_reg:where(?KEY) of
                Pid when is_pid(Pid) ->
                    try gen_server:call(
                          Pid, {verify_current, Routes, Ref, TimeoutMs},
                          TimeoutMs + 1000)
                    catch exit:_ -> {error, retry}
                    end;
                undefined ->
                    {error, retry}
            end;
        error ->
            {error, bad_foreign_reference}
    end;
verify_current(_Routes, _Ref, _TimeoutMs) ->
    {error, bad_foreign_reference}.

-doc """
Return the certified projection at a co-hosted ledger's captured durable head.

The exact Finalize and every entry through that head are folded through the
same verifier/cache as foreign history.  No network route or remote height is
consulted.
""".
-spec verify_local_current(file:filename_all(), quod_dtx:certified_ref(),
                           pos_integer()) ->
          {ok, map()} | {error, term()}.
verify_local_current(LedgerRoot, Ref, TimeoutMs)
  when (is_list(LedgerRoot) orelse is_binary(LedgerRoot)),
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            try gen_server:call(
                  Pid, {verify_local_current, LedgerRoot, Ref, TimeoutMs},
                  TimeoutMs + 1000)
            catch exit:_ -> {error, retry}
            end;
        undefined ->
            {error, retry}
    end;
verify_local_current(_LedgerRoot, _Ref, _TimeoutMs) ->
    {error, bad_foreign_reference}.

-doc """
Return one certificate-verified current committee view for an anchored identity.

Unlike `verify_current/3`, this form has no phase reference to establish first.
It starts from the pinned genesis anchor, advances the shared bounded history
cache through certified entries, then requires a full quorum of the resulting
committee to corroborate the captured durable height.  Supplied routes remain
identity-pinned fetch hints only.
""".
-spec current([{<<_:256>>, term()}], {binary(), <<_:256>>}, pos_integer()) ->
          {ok, map()} | {error, term()}.
current(Routes0, Identity, TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case {normalize_route_hints(Routes0), valid_identity(Identity)} of
        {{ok, [_ | _] = Routes}, true} ->
            case quod_reg:where(?KEY) of
                Pid when is_pid(Pid) ->
                    try gen_server:call(
                          Pid, {current, Routes, Identity, TimeoutMs},
                          TimeoutMs + 1000)
                    catch exit:_ -> {error, retry}
                    end;
                undefined ->
                    {error, retry}
            end;
        _ ->
            {error, bad_foreign_reference}
    end;
current(_Routes, _Identity, _TimeoutMs) ->
    {error, bad_foreign_reference}.

-doc """
Return the certified current view at a co-hosted anchored ledger's captured
durable head.  It uses the same shared cache and history fold as `current/3`,
without requiring a DTX phase reference.
""".
-spec local_current(file:filename_all(), {binary(), <<_:256>>},
                    pos_integer()) ->
          {ok, map()} | {error, term()}.
local_current(LedgerRoot, Identity, TimeoutMs)
  when (is_list(LedgerRoot) orelse is_binary(LedgerRoot)),
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case valid_identity(Identity) of
        true ->
            case quod_reg:where(?KEY) of
                Pid when is_pid(Pid) ->
                    try gen_server:call(
                          Pid,
                          {local_current, LedgerRoot, Identity, TimeoutMs},
                          TimeoutMs + 1000)
                    catch exit:_ -> {error, retry}
                    end;
                undefined ->
                    {error, retry}
            end;
        false ->
            {error, bad_foreign_reference}
    end;
local_current(_LedgerRoot, _Identity, _TimeoutMs) ->
    {error, bad_foreign_reference}.

-doc "Start one monitored consumer of the shared certified target projection.".
-spec follow({binary(), <<_:256>>}) ->
          {ok, reference()} |
          {error, invalid_identity | capacity | unavailable}.
follow(Identity) ->
    case valid_identity(Identity) of
        true ->
            case quod_reg:where(?KEY) of
                Pid when is_pid(Pid) ->
                    try gen_server:call(Pid, {follow, Identity}, 1000)
                    catch exit:_ -> {error, unavailable}
                    end;
                undefined ->
                    {error, unavailable}
            end;
        false ->
            {error, invalid_identity}
    end.

-doc "Acknowledge installation of one exact local follow notice.".
-spec ack(reference(), reference()) -> ok.
ack(FollowRef, NoticeRef)
  when is_reference(FollowRef), is_reference(NoticeRef) ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            try gen_server:call(Pid, {ack, FollowRef, NoticeRef}, 1000)
            catch exit:_ -> ok
            end;
        undefined -> ok
    end;
ack(_FollowRef, _NoticeRef) ->
    ok.

-doc "Remove one exact follow owned by the calling consumer.".
-spec unfollow(reference()) -> ok.
unfollow(FollowRef) when is_reference(FollowRef) ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            try gen_server:call(Pid, {unfollow, FollowRef}, 1000)
            catch exit:_ -> ok
            end;
        undefined -> ok
    end;
unfollow(_FollowRef) ->
    ok.

-doc """
Return every foreign reference carried by one decoded DTX control or record.

This is the exhaustive pure seam used before a validator calls
`quod_dtx:preview/6`/`reduce/4`; a future control kind cannot silently inherit
an empty foreign-check set.  Row order is the control's canonical target order.
""".
-spec required_references(quod_dtx:control() | quod_dtx:control_record()) ->
          {ok, [{'begin' | prepare | decision | finalize,
                 quod_dtx:certified_ref()}]} |
          {error, invalid_control}.
required_references(ControlOrRecord) ->
    try
        case quod_dtx:record_kind(ControlOrRecord) of
            invalid ->
                required_references(
                  quod_dtx:control_kind(ControlOrRecord),
                  quod_dtx:control_body(ControlOrRecord));
            Kind ->
                required_references(Kind, ControlOrRecord)
        end
    catch
        error:function_clause -> {error, invalid_control};
        error:{badmatch, _} -> {error, invalid_control}
    end.

required_references('begin', _Begin) ->
    {ok, []};
required_references(
  prepare,
  {quod_dtx_prepare, 2, _GroupId, BeginRef, _Manifest,
   _PlanDigest, _PlanBlob}) ->
    checked_references([{'begin', BeginRef}]);
required_references(
  decision,
  {quod_dtx_decision, 2, _GroupId, BeginRef, _Verdict, Rows, _Reasons}) ->
    case reference_rows(Rows, prepare, 0, []) of
        {ok, References} ->
            checked_references([{'begin', BeginRef} | References]);
        error ->
            {error, invalid_control}
    end;
required_references(
  finalize,
  {quod_dtx_finalize, 2, _GroupId, DecisionRef, _Verdict,
   PrepareRef, _Generation}) ->
    Tail = case PrepareRef of none -> []; _ -> [{prepare, PrepareRef}] end,
    checked_references([{decision, DecisionRef} | Tail]);
required_references(
  complete,
  {quod_dtx_complete, 2, _GroupId, DecisionRef, Rows}) ->
    case finalize_rows(Rows, 0, []) of
        {ok, References} ->
            checked_references([{decision, DecisionRef} | References]);
        error ->
            {error, invalid_control}
    end;
required_references(_Kind, _Record) ->
    {error, invalid_control}.

reference_rows([], _Phase, _Count, Acc) -> {ok, lists:reverse(Acc)};
reference_rows([{Identity, Ref} | Rest], Phase, Count, Acc)
  when Count < ?QUOD_MAX_DTX_PARTICIPANTS ->
    case ref_identity(Ref) of
        Identity ->
            reference_rows(Rest, Phase, Count + 1, [{Phase, Ref} | Acc]);
        _ -> error
    end;
reference_rows(_, _Phase, _Count, _Acc) -> error.

finalize_rows([], _Count, Acc) -> {ok, lists:reverse(Acc)};
finalize_rows([{Identity, Ref, Generation} | Rest], Count, Acc)
  when Count < ?QUOD_MAX_DTX_PARTICIPANTS,
       is_integer(Generation), Generation >= 0,
       Generation =< ?MAX_UINT64 ->
    case ref_identity(Ref) of
        Identity ->
            finalize_rows(Rest, Count + 1, [{finalize, Ref} | Acc]);
        _ -> error
    end;
finalize_rows(_, _Count, _Acc) -> error.

checked_references(References) ->
    case lists:all(
           fun({_Phase, Ref}) -> quod_dtx:validate_certified_ref(Ref) end,
           References) of
        true -> {ok, References};
        false -> {error, invalid_control}
    end.

-spec stats() -> map().
stats() ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            try gen_server:call(Pid, stats)
            catch exit:_ -> empty_stats()
            end;
        undefined -> empty_stats()
    end.

empty_stats() ->
    #{pending => 0, pulls => 0, histories => 0, cache_bytes => 0,
      peers => 0, follow_consumers => 0, followed_histories => 0,
      projection_workers => 0, projection_bytes => 0,
      follow_building => 0, follow_unreachable => 0,
      follow_capacity_limited => 0, follow_polls => 0, follow_pages => 0,
      follow_entries => 0, follow_bytes => 0, follow_coalesced => 0,
      follow_retries => 0, projection_rebuilds => 0, max_follow_lag => 0}.

%%%===================================================================
%%% gen_server
%%%===================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    Root = maps:get(
             cache_dir, Opts,
             filename:join(
               quod_ledger_store:default_data_dir(), "foreign-log")),
    FetchFun = maps:get(fetch_fun, Opts, undefined),
    PageTimeout = maps:get(page_timeout_ms, Opts, ?DEFAULT_PAGE_TIMEOUT_MS),
    FollowPoll = maps:get(follow_poll_ms, Opts, ?DEFAULT_FOLLOW_POLL_MS),
    FollowRetry = maps:get(follow_retry_ms, Opts, ?DEFAULT_FOLLOW_RETRY_MS),
    FollowMaxRetry = maps:get(
                       follow_max_retry_ms, Opts,
                       ?DEFAULT_FOLLOW_MAX_RETRY_MS),
    ProjectionMax = maps:get(
                      projection_max_bytes, Opts,
                      ?QUOD_MAX_FOREIGN_PROJECTION_BYTES),
    case valid_options(Root, FetchFun, PageTimeout, FollowPoll, FollowRetry,
                       FollowMaxRetry, ProjectionMax) of
        true ->
            %% Materialized projections are rebuildable P state. A normal
            %% worker shutdown removes its generation directory; clearing the
            %% dedicated parent here also reclaims anything left by an
            %% untrappable kill before this owner restarted.
            cleanup_projection_dirs(Root),
            {Histories, Total} = load_histories(Root),
            S0 = #s{root = Root, fetch_fun = FetchFun,
                    page_timeout_ms = PageTimeout,
                    follow_poll_ms = FollowPoll,
                    follow_retry_ms = FollowRetry,
                    follow_max_retry_ms = FollowMaxRetry,
                    projection_max_bytes = ProjectionMax,
                    histories = Histories, total_bytes = Total},
            {ok, subscribe_histories(S0)};
        false ->
            {stop, bad_foreign_log_config}
    end.

valid_options(Root, FetchFun, PageTimeout, FollowPoll, FollowRetry,
              FollowMaxRetry, ProjectionMax) ->
    (is_list(Root) orelse is_binary(Root)) andalso
        (FetchFun =:= undefined orelse is_function(FetchFun, 5)) andalso
        is_integer(PageTimeout) andalso PageTimeout > 0 andalso
        PageTimeout =< ?MAX_TIMER_MS - 1000 andalso
        valid_timer(FollowPoll) andalso valid_timer(FollowRetry) andalso
        valid_timer(FollowMaxRetry) andalso FollowRetry =< FollowMaxRetry andalso
        is_integer(ProjectionMax) andalso ProjectionMax > 0 andalso
        ProjectionMax =< ?QUOD_MAX_FOREIGN_PROJECTION_BYTES.

valid_timer(Value) ->
    is_integer(Value) andalso Value > 0 andalso Value =< ?MAX_TIMER_MS.

cleanup_projection_dirs(Root) ->
    _ = file:del_dir_r(filename:join(Root, "projections")),
    ok.

handle_call(stats, _From, S) ->
    Followed = [H || H <- maps:values(S#s.histories),
                     map_size(H#history.consumers) > 0],
    Reply = #{pending => map_size(S#s.pending),
              pulls => map_size(S#s.pulls),
              histories => map_size(S#s.histories),
              cache_bytes => S#s.total_bytes,
              peers => map_size(S#s.peer_counts),
              follow_consumers => map_size(S#s.follows),
              followed_histories => length(Followed),
              projection_workers => length(
                                      [ok || #history{materializer = M} <- Followed,
                                             M =/= none]),
              projection_bytes => S#s.projection_bytes,
              follow_building => length(
                                   [ok || #history{projection_state = building} <-
                                              Followed]),
              follow_unreachable => length(
                                      [ok || #history{
                                               reachability =
                                                   {unreachable, _}} <- Followed]),
              follow_capacity_limited => length(
                                           [ok || #history{
                                                    reachability =
                                                        {unreachable,
                                                         capacity}} <- Followed]),
              follow_polls => S#s.follow_polls,
              follow_pages => S#s.follow_pages,
              follow_entries => S#s.follow_entries,
              follow_bytes => S#s.follow_bytes,
              follow_coalesced => S#s.follow_coalesced,
              follow_retries => S#s.follow_retries,
              projection_rebuilds => S#s.projection_rebuilds,
              max_follow_lag => S#s.max_follow_lag,
              bootstrap_candidates => lists:sum(
                                        [length(H#history.bootstrap_hints)
                                         || H <- maps:values(S#s.histories)]),
              bootstrap_accepted => S#s.bootstrap_accepted,
              bootstrap_rejected => S#s.bootstrap_rejected,
              bootstrap_evicted => S#s.bootstrap_evicted},
    {reply, Reply, S};
handle_call({follow, Identity}, From, S0) ->
    {ConsumerPid, _Tag} = From,
    case add_follow(Identity, ConsumerPid, S0) of
        {ok, FollowRef, S1} -> {reply, {ok, FollowRef}, S1};
        {error, Reason, S1} -> {reply, {error, Reason}, S1}
    end;
handle_call({ack, FollowRef, NoticeRef}, From, S0) ->
    {ConsumerPid, _Tag} = From,
    {reply, ok, acknowledge_follow(FollowRef, NoticeRef, ConsumerPid, S0)};
handle_call({unfollow, FollowRef}, From, S0) ->
    {ConsumerPid, _Tag} = From,
    {reply, ok, remove_follow(FollowRef, ConsumerPid, S0)};
handle_call(
  {verify, Peer, Endpoint, Ref, Phase, TimeoutMs}, From, S0) ->
    case validate_route_request(Peer, Endpoint, Ref, Phase, TimeoutMs) of
        {ok, Identity} ->
            begin_verification(
              Peer, Endpoint, Ref, Phase, TimeoutMs,
              S0#s.fetch_fun, Identity, From, S0);
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call(
  {verify_reference, Ref, Phase, TimeoutMs}, From, S0) ->
    case validate_reference_request(Ref, Phase, TimeoutMs) of
        {ok, Identity} ->
            case selected_route_hints(Identity, [], S0) of
                {ok, [{ChargePeer, _} | _] = Routes} ->
                    begin_worker(
                      ChargePeer, Identity, TimeoutMs,
                      {exact_routes, Routes, Ref, Phase},
                      S0#s.fetch_fun, From, S0);
                {ok, []} ->
                    {reply, {error, retry}, S0};
                {error, anchor_conflict} ->
                    {reply, {error, retry}, S0}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call({route_hints, Identity, Supplied}, _From, S0) ->
    case {valid_identity(Identity), normalize_route_hints(Supplied)} of
        {true, {ok, Normalized}} ->
            case selected_route_hints(Identity, Normalized, S0) of
                {ok, [_ | _] = Routes} -> {reply, {ok, Routes}, S0};
                {ok, []} -> {reply, {error, unavailable}, S0};
                {error, anchor_conflict} ->
                    {reply, {error, anchor_conflict}, S0}
            end;
        _ ->
            {reply, {error, invalid_request}, S0}
    end;
handle_call(
  {verify_local, LedgerRoot, Ref, Phase, TimeoutMs}, From, S0) ->
    case validate_local_request(LedgerRoot, Ref, Phase, TimeoutMs) of
        {ok, Identity} ->
            LocalPeer = {local, Identity},
            FetchFun =
                fun(_Peer, _Endpoint, Ns, FromIndex, ToIndex) ->
                    quod_catchup:serve_blocks(
                      Ns, LedgerRoot, FromIndex, ToIndex)
                end,
            begin_verification(
              LocalPeer, local, Ref, Phase, TimeoutMs,
              FetchFun, Identity, From, S0);
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call(
  {verify_current, Routes, Ref, TimeoutMs}, From, S0) ->
    case validate_current_request(Routes, Ref, TimeoutMs) of
        {ok, Identity} ->
            [{ChargePeer, _} | _] = Routes,
            begin_worker(
              ChargePeer, Identity, TimeoutMs,
              {current, Routes, Ref}, S0#s.fetch_fun, From, S0);
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call(
  {verify_local_current, LedgerRoot, Ref, TimeoutMs}, From, S0) ->
    case validate_local_current_request(
           LedgerRoot, Ref, TimeoutMs) of
        {ok, Identity} ->
            LocalPeer = {local, Identity},
            FetchFun =
                fun(_Peer, _Endpoint, Ns, FromIndex, ToIndex) ->
                    quod_catchup:serve_blocks(
                      Ns, LedgerRoot, FromIndex, ToIndex)
                end,
            begin_worker(
              LocalPeer, Identity, TimeoutMs,
              {local_current, LedgerRoot, Ref}, FetchFun, From, S0);
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call(
  {current, Routes, Identity, TimeoutMs}, From, S0) ->
    case validate_current_identity_request(
           Routes, Identity, TimeoutMs) of
        ok ->
            [{ChargePeer, _} | _] = Routes,
            begin_worker(
              ChargePeer, Identity, TimeoutMs,
              {current_identity, Routes, Identity},
              S0#s.fetch_fun, From, S0);
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call(
  {local_current, LedgerRoot, Identity, TimeoutMs}, From, S0) ->
    case validate_local_current_identity_request(
           LedgerRoot, Identity, TimeoutMs) of
        ok ->
            LocalPeer = {local, Identity},
            {Ns, _Anchor} = Identity,
            FetchFun =
                fun(_Peer, _Endpoint, RequestedNs, FromIndex, ToIndex) ->
                    case RequestedNs =:= Ns of
                        true -> quod_catchup:serve_blocks(
                                  Ns, LedgerRoot, FromIndex, ToIndex);
                        false -> {error, wrong_namespace}
                    end
                end,
            begin_worker(
              LocalPeer, Identity, TimeoutMs,
              {local_current_identity, LedgerRoot, Identity},
              FetchFun, From, S0);
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call(
  {pull_page, RequestRef, Peer, Endpoint, Ns, FromIndex, ToIndex}, From,
  S = #s{fetch_fun = undefined}) ->
    case maps:get(RequestRef, S#s.pending, undefined) of
        #request{identity = {Ns, _Anchor}} ->
            ReqId = make_ref(),
            Timer = erlang:send_after(
                      S#s.page_timeout_ms, self(), {pull_timeout, ReqId}),
            Chan = quod_catchup:channel(Ns),
            Frame = quod_catchup:encode_frame(
                      Ns, {blocks_req, ReqId, FromIndex, ToIndex}),
            ok = quod_quic:send_pinned(Peer, Endpoint, Chan, Frame),
            Pull = #pull{from = From, request_ref = RequestRef,
                         peer = Peer, timer = Timer},
            {noreply, S#s{pulls = (S#s.pulls)#{ReqId => Pull}}};
        _ ->
            {reply, {error, retry}, S}
    end;
handle_call({reserve_page, RequestRef, Bytes}, _From, S0)
  when is_integer(Bytes), Bytes >= 0 ->
    case reserve_page(RequestRef, Bytes, S0) of
        {ok, S1} -> {reply, ok, S1};
        {error, S1} -> {reply, {error, cache_full}, S1}
    end;
handle_call({set_cache_size, RequestRef, Bytes}, _From, S0)
  when is_integer(Bytes), Bytes >= 0 ->
    case set_cache_size(RequestRef, Bytes, S0) of
        {ok, S1} -> {reply, ok, S1};
        {error, S1} -> {reply, {error, cache_full}, S1}
    end;
handle_call({reset_cache, RequestRef}, _From, S0) ->
    case reset_cache_accounting(RequestRef, S0) of
        {ok, S1} -> {reply, ok, S1};
        error -> {reply, {error, retry}, S0}
    end;
handle_call(_Request, _From, S) ->
    {reply, {error, bad_request}, S}.

begin_verification(Peer, Endpoint, Ref, Phase, TimeoutMs, FetchFun,
                   Identity, From, S0) ->
    begin_worker(
      Peer, Identity, TimeoutMs,
      {exact, Peer, Endpoint, Ref, Phase}, FetchFun, From, S0).

begin_worker(Peer, Identity, TimeoutMs, Work, FetchFun, From, S0) ->
    case start_worker(Peer, Identity, TimeoutMs, Work, FetchFun, From, S0) of
        {ok, S1} -> {noreply, S1};
        {error, Reason, S1} -> {reply, {error, Reason}, S1}
    end.

start_worker(Peer, Identity, TimeoutMs, Work, FetchFun, From, S0) ->
    case admit_request(Peer, Identity, S0) of
        {ok, RequestRef, S1} ->
            Owner = self(),
            Root = S1#s.root,
            PageTimeout = S1#s.page_timeout_ms,
            Worker = spawn_opt(
                       fun() ->
                           verification_worker(
                             Owner, RequestRef, Work,
                             Root, FetchFun, PageTimeout, TimeoutMs)
                       end,
                       [{max_heap_size,
                         #{size => foreign_worker_heap_words(),
                           kill => true, error_logger => true}}]),
            MRef = erlang:monitor(process, Worker),
            Timer = erlang:send_after(
                      TimeoutMs, self(),
                      {verification_timeout, RequestRef}),
            Request = #request{from = From, peer = Peer,
                               identity = Identity, worker = Worker,
                               mref = MRef, timer = Timer},
            Pending1 = (S1#s.pending)#{RequestRef => Request},
            {ok, S1#s{pending = Pending1}};
        {error, Reason, S1} ->
            {error, Reason, S1}
    end.

handle_cast({observe_candidate, Identity, PeerKey, Endpoint}, S0) ->
    {noreply, remember_bootstrap_candidate(
                Identity, PeerKey, Endpoint, S0)};
handle_cast(_Message, S) ->
    {noreply, S}.

handle_info(
  {quod_message, {PeerIdentity, _Link}, Chan, Payload}, S) ->
    case quod_link:peer_key(PeerIdentity) of
        undefined -> {noreply, S};
        Peer -> {noreply, handle_catchup_frame(Peer, Chan, Payload, S)}
    end;
handle_info({foreign_worker_done, RequestRef, Result, Meta}, S0) ->
    case maps:get(RequestRef, S0#s.pending, undefined) of
        #request{timed_out = false} ->
            S1 = install_worker_meta(
                   RequestRef, Meta,
                   record_follow_progress(RequestRef, Meta, S0)),
            {noreply, finish_request(RequestRef, Result, S1)};
        #request{timed_out = true} ->
            {noreply, finish_request(RequestRef, {error, retry}, S0)};
        undefined ->
            {noreply, S0}
    end;
handle_info({verification_timeout, RequestRef}, S0) ->
    case maps:get(RequestRef, S0#s.pending, undefined) of
        #request{worker = Worker} = Request ->
            exit(Worker, kill),
            %% Keep this identity active until the monitor confirms that the
            %% cache worker is dead.  Releasing it here could admit a second
            %% writer against the same ledger/checkpoint between `exit/2` and
            %% the eventual DOWN message.
            Pending1 = (S0#s.pending)#{
                         RequestRef => Request#request{timed_out = true}},
            {noreply, S0#s{pending = Pending1}};
        undefined ->
            {noreply, S0}
    end;
handle_info({pull_timeout, ReqId}, S0) ->
    case maps:take(ReqId, S0#s.pulls) of
        {#pull{from = From}, Pulls1} ->
            gen_server:reply(From, {error, retry}),
            {noreply, S0#s{pulls = Pulls1}};
        error ->
            {noreply, S0}
    end;
handle_info({follow_refresh, Identity, Token}, S0) ->
    {noreply, begin_follow_refresh(Identity, Token, S0)};
handle_info(
  {foreign_projection_building, Identity, Generation, Height}, S0) ->
    {noreply, projection_building(Identity, Generation, Height, S0)};
handle_info(
  {foreign_projection_waiting, Identity, Generation, _Reason, Height}, S0) ->
    {noreply, projection_waiting(Identity, Generation, Height, S0)};
handle_info(
  {foreign_projection_ready, Identity, Generation, Result}, S0) ->
    {noreply, projection_ready(Identity, Generation, Result, S0)};
handle_info({'DOWN', MRef, process, Pid, Reason}, S0) ->
    case request_by_monitor(MRef, S0#s.pending) of
        {ok, RequestRef} ->
            {noreply, finish_request(RequestRef, {error, retry}, S0)};
        error ->
            case consumer_by_monitor(MRef, S0) of
                {ok, FollowRef} ->
                    {noreply, remove_follow_any(FollowRef, S0)};
                error ->
                    {noreply, projection_down(MRef, Pid, Reason, S0)}
            end
    end;
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, #s{channels = Channels, histories = Histories}) ->
    maps:foreach(
      fun(_Identity, #history{materializer = Materializer}) ->
              stop_materializer(Materializer)
      end, Histories),
    _ = [catch quod_reg:unsubscribe({channel, Chan})
         || Chan <- maps:keys(Channels)],
    ok.

%%%===================================================================
%%% Admission and owner accounting
%%%===================================================================

validate_reference_request(Ref, Phase, TimeoutMs) ->
    case validate_current_ref(Ref, TimeoutMs) of
        {ok, Identity} ->
            case valid_phase(Phase) of
                true -> {ok, Identity};
                false -> {error, bad_foreign_reference}
            end;
        {error, _} = Error ->
            Error
    end.

validate_route_request(
  <<_:256>>, Endpoint,
  {quod_dtx_ref, 2, Ns, <<_:256>> = Anchor, Slot,
   <<_:256>>, <<_:256>>, Proof} = Ref,
  Phase, TimeoutMs)
  when is_binary(Ns), byte_size(Ns) > 0,
       byte_size(Ns) =< ?DIRECTORY_MAX_NAMESPACE_BYTES,
       is_integer(Slot), Slot > 0,
       is_binary(Proof), byte_size(Proof) > 0,
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case quod_quic:valid_endpoint(Endpoint) andalso valid_phase(Phase)
         andalso quod_dtx:validate_certified_ref(Ref) of
        true -> {ok, {Ns, Anchor}};
        false -> {error, bad_foreign_reference}
    end;
validate_route_request(_Peer, _Endpoint, _Ref, _Phase, _TimeoutMs) ->
    {error, bad_foreign_reference}.

validate_local_request(
  LedgerRoot,
  {quod_dtx_ref, 2, Ns, <<_:256>> = Anchor, Slot,
   <<_:256>>, <<_:256>>, Proof} = Ref,
  Phase, TimeoutMs)
  when (is_list(LedgerRoot) orelse is_binary(LedgerRoot)),
       is_binary(Ns), byte_size(Ns) > 0,
       byte_size(Ns) =< ?DIRECTORY_MAX_NAMESPACE_BYTES,
       is_integer(Slot), Slot > 0,
       is_binary(Proof), byte_size(Proof) > 0,
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case valid_phase(Phase) andalso quod_dtx:validate_certified_ref(Ref) of
        true -> {ok, {Ns, Anchor}};
        false -> {error, bad_foreign_reference}
    end;
validate_local_request(_LedgerRoot, _Ref, _Phase, _TimeoutMs) ->
    {error, bad_foreign_reference}.

validate_current_request([_ | _] = Routes, Ref, TimeoutMs) ->
    case normalize_route_hints(Routes) of
        {ok, Routes} ->
            validate_current_ref(Ref, TimeoutMs);
        _ ->
            {error, bad_foreign_reference}
    end;
validate_current_request(_Routes, _Ref, _TimeoutMs) ->
    {error, bad_foreign_reference}.

validate_local_current_request(LedgerRoot, Ref, TimeoutMs) ->
    case validate_local_request(
           LedgerRoot, Ref, finalize, TimeoutMs) of
        {ok, Identity} -> {ok, Identity};
        {error, _} = Error -> Error
    end.

validate_current_identity_request([_ | _] = Routes, Identity, TimeoutMs) ->
    case normalize_route_hints(Routes) of
        {ok, Routes} ->
            validate_current_identity(Identity, TimeoutMs);
        _ ->
            {error, bad_foreign_reference}
    end;
validate_current_identity_request(_Routes, _Identity, _TimeoutMs) ->
    {error, bad_foreign_reference}.

validate_local_current_identity_request(
  LedgerRoot, Identity, TimeoutMs)
  when is_list(LedgerRoot); is_binary(LedgerRoot) ->
    validate_current_identity(Identity, TimeoutMs);
validate_local_current_identity_request(
  _LedgerRoot, _Identity, _TimeoutMs) ->
    {error, bad_foreign_reference}.

validate_current_identity(Identity, TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case valid_identity(Identity) of
        true -> ok;
        false -> {error, bad_foreign_reference}
    end;
validate_current_identity(_Identity, _TimeoutMs) ->
    {error, bad_foreign_reference}.

valid_identity({Ns, <<_:256>>})
  when is_binary(Ns), byte_size(Ns) > 0,
       byte_size(Ns) =< ?DIRECTORY_MAX_NAMESPACE_BYTES ->
    true;
valid_identity(_) ->
    false.

validate_current_ref(Ref, TimeoutMs) ->
    case Ref of
        {quod_dtx_ref, 2, Ns, <<_:256>> = Anchor, Slot,
         <<_:256>>, <<_:256>>, Proof}
          when is_binary(Ns), byte_size(Ns) > 0,
               byte_size(Ns) =< ?DIRECTORY_MAX_NAMESPACE_BYTES,
               is_integer(Slot), Slot > 0,
               is_binary(Proof), byte_size(Proof) > 0,
               is_integer(TimeoutMs), TimeoutMs > 0,
               TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
            case quod_dtx:validate_certified_ref(Ref) of
                true -> {ok, {Ns, Anchor}};
                false -> {error, bad_foreign_reference}
            end;
        _ ->
            {error, bad_foreign_reference}
    end.

normalize_route_hints(Routes) when is_list(Routes) ->
    normalize_route_hints(Routes, 0, []);
normalize_route_hints(_) ->
    error.

normalize_route_hints([], _Count, Acc) ->
    {ok, lists:usort(Acc)};
normalize_route_hints(
  [{<<_:256>> = Peer, Endpoint} | Rest], Count, Acc)
  when Count < ?MAX_VALIDATORS ->
    case quod_quic:valid_endpoint(Endpoint) of
        true -> normalize_route_hints(Rest, Count + 1,
                                      [{Peer, Endpoint} | Acc]);
        false -> error
    end;
normalize_route_hints(_, _Count, _Acc) ->
    error.

selected_route_hints(Identity = {Ns, Anchor}, Supplied, S) ->
    case directory_route_hints(Ns, Anchor) of
        {error, anchor_conflict} ->
            {error, anchor_conflict};
        {ok, Directory} ->
            {Projection, Bootstrap} =
                case maps:get(Identity, S#s.histories, undefined) of
                    #history{projection = P, bootstrap_hints = B} -> {P, B};
                    undefined -> {undefined, []}
                end,
            Discovery = lists:sublist(
                          stable_unique_routes(
                            Directory ++ Supplied ++ Bootstrap),
                          ?MAX_CURRENT_ROUTE_HINTS - ?MAX_VALIDATORS),
            Hints0 = case is_map(Projection) of
                         true -> current_route_hints(Discovery, Projection);
                         false -> Discovery
                     end,
            {ok, lists:sublist(Hints0, ?MAX_VALIDATORS)}
    end.

directory_route_hints(Ns, Anchor) ->
    case quod_directory:validator_routes(Ns, Anchor) of
        {ok, Rows} ->
            {ok,
             [{PeerKey, Endpoint}
              || #{node_key := <<_:256>> = PeerKey,
                   endpoint := Endpoint} <- Rows,
                 quod_quic:valid_endpoint(Endpoint)]};
        {error, anchor_conflict} ->
            {error, anchor_conflict};
        {error, unavailable} ->
            {ok, []}
    end.

remember_bootstrap_candidate(Identity, PeerKey, Endpoint, S0) ->
    case valid_identity(Identity) andalso
         is_binary(PeerKey) andalso byte_size(PeerKey) =:= 32 andalso
         quod_quic:valid_endpoint(Endpoint) andalso
         bootstrap_peer_admissible(
           Identity, PeerKey, S0#s.histories) of
        false ->
            S0#s{bootstrap_rejected = S0#s.bootstrap_rejected + 1};
        true ->
            case ensure_bootstrap_history(Identity, S0) of
                {ok, S1} ->
                    H0 = maps:get(Identity, S1#s.histories),
                    {Hints, Evicted} = put_bootstrap_hint(
                                         PeerKey, Endpoint,
                                         H0#history.bootstrap_hints),
                    H1 = H0#history{bootstrap_hints = Hints,
                                    last_used = quod_time:mono_ms()},
                    S2 = put_history(
                           Identity, H1,
                           S1#s{bootstrap_accepted =
                                    S1#s.bootstrap_accepted + 1,
                                bootstrap_evicted =
                                    S1#s.bootstrap_evicted + Evicted}),
                    schedule_follow(Identity, 0, S2);
                {error, S1} ->
                    S1#s{bootstrap_rejected =
                             S1#s.bootstrap_rejected + 1}
            end
    end.

bootstrap_peer_admissible(Identity, PeerKey, Histories) ->
    case maps:get(Identity, Histories, undefined) of
        #history{bootstrap_hints = Hints} ->
            lists:keymember(PeerKey, 1, Hints) orelse
                bootstrap_identity_count(PeerKey, Histories) <
                    ?MAX_BOOTSTRAP_IDENTITIES_PER_PEER;
        undefined ->
            bootstrap_identity_count(PeerKey, Histories) <
                ?MAX_BOOTSTRAP_IDENTITIES_PER_PEER
    end.

bootstrap_identity_count(PeerKey, Histories) ->
    maps:fold(
      fun(_Identity, #history{bootstrap_hints = Hints}, Count) ->
          case lists:keymember(PeerKey, 1, Hints) of
              true -> Count + 1;
              false -> Count
          end
      end, 0, Histories).

%% A transport hint must never evict verified history.  Candidate-only rows
%% consume the existing global history budget and are refused once it is full;
%% normal verified/follow work retains the existing LRU eviction policy.
ensure_bootstrap_history(Identity, S = #s{histories = Histories})
  when is_map_key(Identity, Histories) ->
    {ok, S};
ensure_bootstrap_history(Identity, S = #s{histories = Histories})
  when map_size(Histories) < ?QUOD_MAX_FOREIGN_HISTORIES ->
    ensure_history(Identity, S);
ensure_bootstrap_history(_Identity, S) ->
    {error, S}.

put_bootstrap_hint(PeerKey, Endpoint, Hints0) ->
    WithoutPeer = [{Peer, Ep} || {Peer, Ep} <- Hints0,
                                  Peer =/= PeerKey],
    Hints1 = [{PeerKey, Endpoint} | WithoutPeer],
    case length(Hints1) =< ?MAX_CURRENT_ROUTE_HINTS of
        true -> {Hints1, 0};
        false -> {lists:sublist(Hints1, ?MAX_CURRENT_ROUTE_HINTS), 1}
    end.

valid_phase('begin') -> true;
valid_phase(prepare) -> true;
valid_phase(decision) -> true;
valid_phase(finalize) -> true;
valid_phase(complete) -> true;
valid_phase(_) -> false.

admit_request(Peer, Identity, S0) ->
    PeerCount = maps:get(Peer, S0#s.peer_counts, 0),
    case map_size(S0#s.pending) < ?QUOD_MAX_FOREIGN_PENDING andalso
         PeerCount < ?QUOD_MAX_FOREIGN_PENDING_PER_PEER of
        false ->
            {error, busy, S0};
        true ->
            case ensure_history(Identity, S0) of
                {ok, S1} ->
                    History = maps:get(Identity, S1#s.histories),
                    case History#history.active of
                        none ->
                            Ref = make_ref(),
                            H1 = History#history{active = Ref,
                                                 last_used = quod_time:mono_ms()},
                            Counts1 = (S1#s.peer_counts)#{Peer => PeerCount + 1},
                            {ok, Ref,
                             S1#s{histories =
                                      (S1#s.histories)#{Identity => H1},
                                   peer_counts = Counts1}};
                        _ ->
                            {error, history_busy, S1}
                    end;
                {error, S1} ->
                    {error, cache_full, S1}
            end
    end.

ensure_history(Identity, S = #s{histories = Histories})
  when is_map_key(Identity, Histories) ->
    {ok, S};
ensure_history(Identity = {Ns, _Anchor}, S0) ->
    case make_history_room(S0) of
        {ok, S1} ->
            CacheNs = cache_namespace(Identity),
            H = #history{identity = Identity, cache_ns = CacheNs,
                         last_used = quod_time:mono_ms()},
            S2 = add_channel(Ns, S1),
            {ok, S2#s{histories = (S2#s.histories)#{Identity => H}}};
        {error, S1} ->
            {error, S1}
    end.

make_history_room(S) when map_size(S#s.histories) < ?QUOD_MAX_FOREIGN_HISTORIES ->
    {ok, S};
make_history_room(S) ->
    evict_one(S, none).

reserve_page(RequestRef, Bytes, S0) ->
    case request_identity(RequestRef, S0) of
        {ok, Identity} ->
            case make_byte_room(Bytes, Identity, S0) of
                {ok, S1} ->
                    H0 = maps:get(Identity, S1#s.histories),
                    H1 = H0#history{bytes = H0#history.bytes + Bytes},
                    {ok, S1#s{histories =
                                  (S1#s.histories)#{Identity => H1},
                               total_bytes = S1#s.total_bytes + Bytes}};
                {error, S1} -> {error, S1}
            end;
        error -> {error, S0}
    end.

set_cache_size(RequestRef, Bytes, S0) ->
    case request_identity(RequestRef, S0) of
        {ok, Identity} ->
            H0 = maps:get(Identity, S0#s.histories),
            case Bytes =< H0#history.bytes of
                true ->
                    H1 = H0#history{bytes = Bytes},
                    {ok, S0#s{histories =
                                  (S0#s.histories)#{Identity => H1},
                               total_bytes =
                                   S0#s.total_bytes -
                                       (H0#history.bytes - Bytes)}};
                false ->
                    Delta = Bytes - H0#history.bytes,
                    case make_byte_room(Delta, Identity, S0) of
                        {ok, S1} ->
                            H1 = H0#history{bytes = Bytes},
                            {ok, S1#s{histories =
                                         (S1#s.histories)#{Identity => H1},
                                      total_bytes = S1#s.total_bytes + Delta}};
                        {error, S1} -> {error, S1}
                    end
            end;
        error -> {error, S0}
    end.

make_byte_room(Bytes, _Identity, S)
  when Bytes > ?QUOD_MAX_FOREIGN_CACHE_BYTES ->
    {error, S};
make_byte_room(Bytes, _Identity, S)
  when S#s.total_bytes + Bytes =< ?QUOD_MAX_FOREIGN_CACHE_BYTES ->
    {ok, S};
make_byte_room(Bytes, Identity, S0) ->
    case evict_one(S0, Identity) of
        {ok, S1} -> make_byte_room(Bytes, Identity, S1);
        {error, S1} -> {error, S1}
    end.

evict_one(S = #s{histories = Histories}, ExceptIdentity) ->
    Candidates =
        [H || {Identity,
               H = #history{active = none, consumers = Consumers,
                            materializer = none}} <- maps:to_list(Histories),
              map_size(Consumers) =:= 0,
              Identity =/= ExceptIdentity],
    case Candidates of
        [] -> {error, S};
        _ ->
            [First | Tail] = Candidates,
            Victim = lists:foldl(
                       fun(H = #history{last_used = Used},
                           Best = #history{last_used = BestUsed}) ->
                               case Used < BestUsed of
                                   true -> H;
                                   false -> Best
                               end
                       end, First, Tail),
            evict_history(Victim#history.identity, S)
    end.

evict_history(Identity = {Ns, _}, S0) ->
    H = maps:get(Identity, S0#s.histories),
    _ = file:del_dir_r(cache_dir(S0#s.root, H#history.cache_ns)),
    Histories1 = maps:remove(Identity, S0#s.histories),
    S1 = S0#s{histories = Histories1,
              total_bytes = max(0, S0#s.total_bytes - H#history.bytes)},
    {ok, remove_channel(Ns, S1)}.

reset_cache_accounting(RequestRef, S0) ->
    case request_identity(RequestRef, S0) of
        {ok, Identity} ->
            H00 = maps:get(Identity, S0#s.histories),
            S1 = case H00#history.materializer of
                     none -> S0;
                     #materializer{} = M ->
                         discard_materializer(Identity, H00, M, S0)
                 end,
            H0 = maps:get(Identity, S1#s.histories),
            H1 = H0#history{height = 0, bytes = 0,
                            projection = undefined},
            {ok, S1#s{histories = (S1#s.histories)#{Identity => H1},
                      total_bytes = max(
                                      0, S1#s.total_bytes - H0#history.bytes)}};
        error -> error
    end.

request_identity(RequestRef, #s{pending = Pending}) ->
    case maps:get(RequestRef, Pending, undefined) of
        #request{identity = Identity} -> {ok, Identity};
        undefined -> error
    end.

request_by_monitor(MRef, Pending) ->
    case [Ref || {Ref, #request{mref = RefM}} <- maps:to_list(Pending),
                 RefM =:= MRef] of
        [Ref] -> {ok, Ref};
        [] -> error
    end.

finish_request(RequestRef, Reply, S0) ->
    case maps:take(RequestRef, S0#s.pending) of
        {#request{from = From, peer = Peer, identity = Identity,
                  mref = MRef, timer = Timer}, Pending1} ->
            _ = erlang:cancel_timer(Timer),
            _ = erlang:demonitor(MRef, [flush]),
            Count = maps:get(Peer, S0#s.peer_counts, 1),
            Counts1 = case Count of
                          1 -> maps:remove(Peer, S0#s.peer_counts);
                          _ -> (S0#s.peer_counts)#{Peer => Count - 1}
                      end,
            Histories1 =
                case maps:get(Identity, S0#s.histories, undefined) of
                    #history{} = H ->
                        (S0#s.histories)#{Identity =>
                                             H#history{active = none,
                                                       last_used =
                                                           quod_time:mono_ms()}};
                    undefined -> S0#s.histories
                end,
            S1 = S0#s{pending = Pending1, peer_counts = Counts1,
                      histories = Histories1},
            S2 = cancel_request_pulls(RequestRef, S1),
            case From of
                {follow, Identity, Token} ->
                    finish_follow_refresh(Identity, Token, Reply, S2);
                _ ->
                    gen_server:reply(From, Reply),
                    S2
            end;
        error ->
            S0
    end.

%%%===================================================================
%%% Continuous certified follow lifecycle
%%%===================================================================

add_follow(Identity, ConsumerPid, S0)
  when is_pid(ConsumerPid) ->
    case map_size(S0#s.follows) < ?QUOD_MAX_FOREIGN_FOLLOW_CONSUMERS of
        false ->
            {error, capacity, S0};
        true ->
            case ensure_history(Identity, S0) of
                {ok, S1} ->
                    H0 = maps:get(Identity, S1#s.histories),
                    case map_size(H0#history.consumers) <
                         ?DIRECTORY_MAX_NAMESPACES of
                        false ->
                            {error, capacity, S1};
                        true ->
                            FollowRef = make_ref(),
                            MRef = erlang:monitor(process, ConsumerPid),
                            Consumer = #consumer{pid = ConsumerPid, mref = MRef},
                            H1 = H0#history{
                                   consumers = (H0#history.consumers)#{
                                                 FollowRef => Consumer},
                                   projection_state = building,
                                   last_used = quod_time:mono_ms()},
                            S2 = S1#s{
                                   histories = (S1#s.histories)#{Identity => H1},
                                   follows = (S1#s.follows)#{FollowRef => Identity}},
                            S3 = notify_follow(
                                   FollowRef,
                                   {building, materialized_height(H1)}, S2),
                            {ok, FollowRef, schedule_follow(Identity, 0, S3)}
                    end;
                {error, S1} ->
                    {error, capacity, S1}
            end
    end.

acknowledge_follow(FollowRef, NoticeRef, ConsumerPid, S0) ->
    case follow_consumer(FollowRef, S0) of
        {ok, Identity, #consumer{pid = ConsumerPid,
                                outstanding = {NoticeRef, _Notice}} = C0,
         H0} ->
            C1 = C0#consumer{outstanding = none},
            H1 = put_consumer(FollowRef, C1, H0),
            S1 = put_history(Identity, H1, S0),
            case C1#consumer.pending of
                none -> S1;
                Pending ->
                    notify_follow(
                      FollowRef, Pending,
                      put_history(
                        Identity,
                        put_consumer(
                          FollowRef, C1#consumer{pending = none}, H1),
                        S1))
            end;
        _ ->
            S0
    end.

remove_follow(FollowRef, ConsumerPid, S0) ->
    case follow_consumer(FollowRef, S0) of
        {ok, _Identity, #consumer{pid = ConsumerPid}, _H} ->
            remove_follow_any(FollowRef, S0);
        _ ->
            S0
    end.

remove_follow_any(FollowRef, S0) ->
    case follow_consumer(FollowRef, S0) of
        {ok, Identity, #consumer{mref = MRef}, H0} ->
            _ = erlang:demonitor(MRef, [flush]),
            Consumers1 = maps:remove(FollowRef, H0#history.consumers),
            H1 = H0#history{consumers = Consumers1,
                            last_used = quod_time:mono_ms()},
            S1 = put_history(
                   Identity, H1,
                   S0#s{follows = maps:remove(FollowRef, S0#s.follows)}),
            case map_size(Consumers1) of
                0 -> stop_follow_target(Identity, S1);
                _ -> S1
            end;
        error ->
            S0
    end.

follow_consumer(FollowRef, S) ->
    case maps:get(FollowRef, S#s.follows, undefined) of
        undefined -> error;
        Identity ->
            case maps:get(Identity, S#s.histories, undefined) of
                #history{} = H ->
                    case maps:get(FollowRef, H#history.consumers, undefined) of
                        #consumer{} = C -> {ok, Identity, C, H};
                        undefined -> error
                    end;
                undefined -> error
            end
    end.

consumer_by_monitor(MRef, S) ->
    Matches =
        [FollowRef
         || {FollowRef, Identity} <- maps:to_list(S#s.follows),
            #history{} = H <- [maps:get(Identity, S#s.histories)],
            #consumer{mref = ConsumerMRef} <-
                [maps:get(FollowRef, H#history.consumers)],
            ConsumerMRef =:= MRef],
    case Matches of
        [FollowRef] -> {ok, FollowRef};
        [] -> error
    end.

put_consumer(FollowRef, Consumer, H) ->
    H#history{consumers = (H#history.consumers)#{FollowRef => Consumer}}.

put_history(Identity, H, S) ->
    S#s{histories = (S#s.histories)#{Identity => H}}.

notify_history(Identity, Notice, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{consumers = Consumers} ->
            lists:foldl(
              fun(FollowRef, Acc) -> notify_follow(FollowRef, Notice, Acc) end,
              S0, maps:keys(Consumers));
        undefined -> S0
    end.

notify_follow(FollowRef, Notice, S0) ->
    case follow_consumer(FollowRef, S0) of
        {ok, Identity, #consumer{outstanding = none, pid = Pid} = C0, H0} ->
            NoticeRef = make_ref(),
            Pid ! {quod_foreign_follow, FollowRef, NoticeRef, Identity, Notice},
            C1 = C0#consumer{outstanding = {NoticeRef, Notice}},
            put_history(Identity, put_consumer(FollowRef, C1, H0), S0);
        {ok, Identity, #consumer{pending = Pending0} = C0, H0} ->
            C1 = C0#consumer{pending = coalesce_notice(Pending0, Notice)},
            put_history(
              Identity, put_consumer(FollowRef, C1, H0),
              S0#s{follow_coalesced = S0#s.follow_coalesced + 1});
        error ->
            S0
    end.

coalesce_notice(none, Notice) -> Notice;
coalesce_notice(
  {advanced, _From0, _To0, _Projection0, _Fresh0, _Heads0},
  {advanced, _From, To, Projection, Freshness, _Heads}) ->
    {resnapshot, To, Projection, Freshness};
coalesce_notice(
  {resnapshot, _To0, _Projection0, _Fresh0},
  {advanced, _From, To, Projection, Freshness, _Heads}) ->
    {resnapshot, To, Projection, Freshness};
coalesce_notice(
  {advanced, _From0, _To0, _Projection0, _Fresh0, _Heads0},
  {resnapshot, To, Projection, Freshness}) ->
    {resnapshot, To, Projection, Freshness};
coalesce_notice(
  {resnapshot, _To0, _Projection0, _Fresh0},
  {resnapshot, To, Projection, Freshness}) ->
    {resnapshot, To, Projection, Freshness};
coalesce_notice(_Previous, Newest) ->
    Newest.

schedule_follow(Identity, Delay, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{consumers = Consumers} = H0 when map_size(Consumers) > 0 ->
            cancel_follow_timer(H0#history.follow_timer),
            Token = make_ref(),
            Timer = erlang:send_after(
                      max(0, Delay), self(), {follow_refresh, Identity, Token}),
            put_history(
              Identity,
              H0#history{follow_timer = Timer, follow_token = Token}, S0);
        _ ->
            S0
    end.

cancel_follow_timer(none) -> ok;
cancel_follow_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

begin_follow_refresh(Identity, Token, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{follow_token = Token, consumers = Consumers,
                 active = none} = H0 when map_size(Consumers) > 0 ->
            H1 = H0#history{follow_timer = none, follow_token = none},
            S1 = put_history(Identity, H1, S0),
            Timeout = follow_request_timeout(S1),
            case selected_route_hints(Identity, [], S1) of
                {error, anchor_conflict} ->
                    retry_follow(
                      Identity, anchor_conflict,
                      notify_history(
                        Identity,
                        {unreachable, anchor_conflict,
                         materialized_height(H1)}, S1));
                {ok, Routes} ->
                    case start_worker(
                           {follow, Identity}, Identity, Timeout,
                           {follow, Identity, Routes}, S1#s.fetch_fun,
                           {follow, Identity, Token}, S1) of
                        {ok, S2} ->
                            S2#s{follow_polls = S2#s.follow_polls + 1};
                        {error, cache_full, S2} ->
                            retry_follow(
                              Identity, capacity,
                              notify_history(
                                Identity,
                                {unreachable, capacity,
                                 materialized_height(H1)}, S2));
                        {error, _Busy, S2} ->
                            retry_follow(Identity, history_busy, S2)
                    end
            end;
        #history{follow_token = Token, consumers = Consumers} = H0
          when map_size(Consumers) > 0 ->
            H1 = H0#history{follow_timer = none, follow_token = none},
            retry_follow(Identity, history_busy,
                         put_history(Identity, H1, S0));
        _ ->
            S0
    end.

follow_request_timeout(S) ->
    min(?MAX_TIMER_MS - 1000, 2 * S#s.page_timeout_ms + 1000).

finish_follow_refresh(Identity, _Token, Reply, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{consumers = Consumers} when map_size(Consumers) =:= 0 ->
            S0;
        #history{} = H0 ->
            Now = quod_time:mono_ms(),
            {View, Hint, Reason, NormalDelay} =
                case Reply of
                    {ok, Evidence} when is_map(Evidence) ->
                        {maps:get(current_view, Evidence, confirmed),
                         maps:get(hinted_height, Evidence,
                                  maps:get(slot, Evidence, unknown)),
                         none, S0#s.follow_poll_ms};
                    {error, {unreachable, Why}} ->
                        {unconfirmed, H0#history.hinted_height, Why,
                         retry_delay(H0, S0)};
                    {error, _} ->
                        {unconfirmed, H0#history.hinted_height, unavailable,
                         retry_delay(H0, S0)}
                end,
            H1 = H0#history{last_probe_ms = Now, hinted_height = Hint,
                            current_view = View,
                            reachability =
                                case Reason of
                                    none -> reachable;
                                    _ -> {unreachable, Reason}
                                end,
                            retry_ms = case Reason of
                                           none -> S0#s.follow_retry_ms;
                                           _ -> next_retry(H0, S0)
                                       end},
            S1 = put_history(
                   Identity, H1,
                   case Reason of
                       none -> S0;
                       _ -> S0#s{follow_retries = S0#s.follow_retries + 1}
                   end),
            S2 = ensure_materializer_advanced(Identity, S1),
            S3 = case Reason of
                     none -> S2;
                     _ -> notify_history(
                            Identity,
                            {unreachable, Reason,
                             materialized_height(
                               maps:get(Identity, S2#s.histories))}, S2)
                 end,
            schedule_follow(Identity, NormalDelay, S3);
        undefined ->
            S0
    end.

retry_follow(Identity, Reason, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{} = H0 ->
            Delay = retry_delay(H0, S0),
            H1 = H0#history{retry_ms = next_retry(H0, S0),
                            reachability = {unreachable, Reason}},
            schedule_follow(
              Identity, Delay,
              put_history(
                Identity, H1,
                S0#s{follow_retries = S0#s.follow_retries + 1}));
        undefined -> S0
    end.

retry_delay(#history{retry_ms = Retry}, S) ->
    Span = max(1, Retry div 4),
    min(S#s.follow_max_retry_ms,
        Retry + erlang:phash2({self(), quod_time:mono_ms()}, Span)).

next_retry(#history{retry_ms = Retry}, S) ->
    min(S#s.follow_max_retry_ms, max(S#s.follow_retry_ms, Retry * 2)).

ensure_materializer_advanced(Identity, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{height = Height, projection = Projection,
                 materializer = Materializer,
                 consumers = Consumers} = H0
          when Height > 0, is_map(Projection), map_size(Consumers) > 0 ->
            case history_head(Projection) of
                {Height, <<_:256>>} = Head ->
                    case Materializer of
                        none ->
                            {Pid, MRef, Generation} =
                                quod_foreign_projection:start_monitor(
                                  self(), Identity, S0#s.root,
                                  H0#history.cache_ns),
                            M = #materializer{pid = Pid, mref = MRef,
                                              generation = Generation},
                            quod_foreign_projection:advance(
                              Pid, Generation, Height, Head),
                            put_history(
                              Identity,
                              H0#history{materializer = M,
                                         projection_state = building},
                              S0#s{projection_rebuilds =
                                       S0#s.projection_rebuilds + 1});
                        #materializer{pid = Pid, generation = Generation} ->
                            quod_foreign_projection:advance(
                              Pid, Generation, Height, Head),
                            S0
                    end;
                _ ->
                    S0
            end;
        _ ->
            S0
    end.

history_head(Projection) when is_map(Projection) ->
    maps:get(history_head, Projection, none).

projection_building(Identity, Generation, Height, S0) ->
    case materializer_matches(Identity, Generation, S0) of
        {ok, H0, _M} ->
            notify_history(
              Identity, {building, Height},
              put_history(
                Identity, H0#history{projection_state = building}, S0));
        error -> S0
    end.

projection_waiting(Identity, Generation, Height, S0) ->
    case materializer_matches(Identity, Generation, S0) of
        {ok, _H, _M} ->
            retry_follow(
              Identity, network_identity,
              notify_history(Identity, {building, Height}, S0));
        error -> S0
    end.

projection_ready(Identity, Generation,
                 #{from := From, height := Height,
                   projection_id := ProjectionId,
                   changed_heads := Heads0, resnapshot := Resnapshot0,
                   memory_bytes := MemoryBytes}, S0)
  when is_integer(From), is_integer(Height), Height >= From,
       is_binary(ProjectionId), byte_size(ProjectionId) =:= 32,
       is_list(Heads0), is_integer(MemoryBytes), MemoryBytes >= 0 ->
    case materializer_matches(Identity, Generation, S0) of
        {ok, H0, M0} ->
            Total = max(
                      0, S0#s.projection_bytes -
                             M0#materializer.memory_bytes + MemoryBytes),
            case Total =< S0#s.projection_max_bytes of
                true ->
                    M1 = M0#materializer{
                           height = Height, projection_id = ProjectionId,
                           memory_bytes = MemoryBytes},
                    LastAdvance = case Height > M0#materializer.height of
                                      true -> quod_time:mono_ms();
                                      false -> H0#history.last_advance_ms
                                  end,
                    H1 = H0#history{materializer = M1,
                                    last_advance_ms = LastAdvance,
                                    projection_state = ready},
                    S1 = put_history(
                           Identity, H1,
                           S0#s{projection_bytes = Total,
                                max_follow_lag = max(
                                                   S0#s.max_follow_lag,
                                                   follow_lag(H1, Height))}),
                    Freshness = follow_freshness(H1, Height),
                    {Resnapshot, Heads} = bounded_heads(
                                            Resnapshot0 orelse From =:= 0,
                                            Heads0),
                    Notice = case Resnapshot of
                                 true -> {resnapshot, Height, ProjectionId,
                                          Freshness};
                                 false -> {advanced, From, Height, ProjectionId,
                                           Freshness, Heads}
                             end,
                    notify_history(Identity, Notice, S1);
                false ->
                    S1 = discard_materializer(Identity, H0, M0, S0),
                    retry_follow(
                      Identity, capacity,
                      notify_history(
                        Identity, {unreachable, capacity, Height}, S1))
            end;
        error -> S0
    end;
projection_ready(_Identity, _Generation, _Result, S) ->
    S.

bounded_heads(true, _Heads) -> {true, []};
bounded_heads(false, Heads) ->
    case stable_bounded_heads(Heads, ?MAX_CHANGED_HEADS, #{}, []) of
        {ok, Unique} -> {false, Unique};
        overflow -> {true, []}
    end.

stable_bounded_heads([], _Left, _Seen, Acc) ->
    {ok, lists:reverse(Acc)};
stable_bounded_heads([Head | Rest], Left, Seen, Acc) ->
    case maps:is_key(Head, Seen) of
        true -> stable_bounded_heads(Rest, Left, Seen, Acc);
        false when Left > 0 ->
            stable_bounded_heads(
              Rest, Left - 1, Seen#{Head => true}, [Head | Acc]);
        false -> overflow
    end.

follow_freshness(H, Height) ->
    Hint = H#history.hinted_height,
    Lag = case Hint of
              N when is_integer(N), N >= Height -> N - Height;
              _ -> unknown
          end,
    #{last_probe_ms => H#history.last_probe_ms,
      last_advance_ms => H#history.last_advance_ms,
      hinted_height => Hint, lag => Lag,
      current_view => H#history.current_view}.

follow_lag(#history{hinted_height = Hint}, Height)
  when is_integer(Hint), Hint >= Height -> Hint - Height;
follow_lag(_H, _Height) -> 0.

materializer_matches(Identity, Generation, S) ->
    case maps:get(Identity, S#s.histories, undefined) of
        #history{materializer =
                     #materializer{generation = Generation} = M} = H ->
            {ok, H, M};
        _ -> error
    end.

projection_down(MRef, _Pid, _Reason, S0) ->
    Matches =
        [{Identity, H, M}
         || {Identity, H = #history{materializer = M}} <-
                maps:to_list(S0#s.histories),
            is_record(M, materializer), M#materializer.mref =:= MRef],
    case Matches of
        [{Identity, H0, M0}] ->
            S1 = discard_materializer(Identity, H0, M0, S0),
            retry_follow(
              Identity, materializer_down,
              notify_history(
                Identity, {building, materialized_height(H0)}, S1));
        [] -> S0
    end.

discard_materializer(Identity, H0, M0, S0) ->
    stop_materializer(M0),
    put_history(
      Identity,
      H0#history{materializer = none, projection_state = building},
      S0#s{projection_bytes = max(
                                  0, S0#s.projection_bytes -
                                         M0#materializer.memory_bytes)}).

materialized_height(#history{materializer = none}) -> 0;
materialized_height(#history{materializer = #materializer{height = Height}}) ->
    Height.

stop_follow_target(Identity, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{} = H0 ->
            cancel_follow_timer(H0#history.follow_timer),
            S1 = case H0#history.materializer of
                     none -> S0;
                     #materializer{} = M ->
                         discard_materializer(Identity, H0, M, S0)
                 end,
            H1 = maps:get(Identity, S1#s.histories),
            H2 = H1#history{follow_timer = none, follow_token = none,
                            retry_ms = S1#s.follow_retry_ms,
                            hinted_height = unknown,
                            current_view = unconfirmed,
                            projection_state = building,
                            reachability = unknown},
            S2 = put_history(Identity, H2, S1),
            cancel_active_follow(Identity, S2);
        undefined -> S0
    end.

cancel_active_follow(Identity, S0) ->
    Matches =
        [{Ref, Worker}
         || {Ref,
             #request{from = {follow, RequestIdentity, _}, worker = Worker}} <-
                maps:to_list(S0#s.pending),
            RequestIdentity =:= Identity],
    lists:foreach(fun({_Ref, Worker}) -> exit(Worker, kill) end, Matches),
    S0.

stop_materializer(none) -> ok;
stop_materializer(#materializer{pid = Pid, mref = MRef}) ->
    _ = erlang:demonitor(MRef, [flush]),
    quod_foreign_projection:stop(Pid).

cancel_request_pulls(RequestRef, S0) ->
    {Keep, Drop} = maps:fold(
                     fun(ReqId, Pull = #pull{request_ref = Ref}, {K, D}) ->
                             case Ref =:= RequestRef of
                                 true -> {K, [{ReqId, Pull} | D]};
                                 false -> {K#{ReqId => Pull}, D}
                             end
                     end, {#{}, []}, S0#s.pulls),
    _ = [begin
             _ = erlang:cancel_timer(Pull#pull.timer),
             gen_server:reply(Pull#pull.from, {error, retry})
         end || {_ReqId, Pull} <- Drop],
    S0#s{pulls = Keep}.

install_worker_meta(RequestRef, Meta, S0) when is_map(Meta) ->
    case request_identity(RequestRef, S0) of
        {ok, Identity} ->
            case maps:get(Identity, S0#s.histories, undefined) of
                #history{} = H0 ->
                    ActualBytes = maps:get(bytes, Meta, H0#history.bytes),
                    Projection = maps:get(
                                   projection, Meta,
                                   H0#history.projection),
                    Bootstrap = case is_map(Projection) of
                                    true -> [];
                                    false -> H0#history.bootstrap_hints
                                end,
                    H1 = H0#history{height = maps:get(height, Meta, H0#history.height),
                                    bytes = ActualBytes,
                                    projection = Projection,
                                    bootstrap_hints = Bootstrap},
                    Total1 = max(
                               0, S0#s.total_bytes - H0#history.bytes +
                                      ActualBytes),
                    S0#s{histories = (S0#s.histories)#{Identity => H1},
                         total_bytes = Total1};
                undefined -> S0
            end;
        error -> S0
    end;
install_worker_meta(_RequestRef, _Meta, S) -> S.

record_follow_progress(RequestRef, Meta, S0) when is_map(Meta) ->
    case maps:get(RequestRef, S0#s.pending, undefined) of
        #request{from = {follow, Identity, _Token}} ->
            case maps:get(Identity, S0#s.histories, undefined) of
                #history{height = OldHeight, bytes = OldBytes} ->
                    Height = maps:get(height, Meta, OldHeight),
                    Bytes = maps:get(bytes, Meta, OldBytes),
                    Entries = max(0, Height - OldHeight),
                    Pages = case Entries of
                                0 -> 0;
                                _ -> (Entries + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES - 1)
                                     div ?QUOD_MAX_FOREIGN_PAGE_ENTRIES
                            end,
                    S0#s{follow_pages = S0#s.follow_pages + Pages,
                         follow_entries = S0#s.follow_entries + Entries,
                         follow_bytes = S0#s.follow_bytes + max(0, Bytes - OldBytes)};
                undefined -> S0
            end;
        _ -> S0
    end;
record_follow_progress(_RequestRef, _Meta, S) -> S.

foreign_worker_heap_words() ->
    max(1, ?QUOD_SCOPE_WORKER_MAX_HEAP_BYTES div erlang:system_info(wordsize)).

%%%===================================================================
%%% Catch-up transport
%%%===================================================================

handle_catchup_frame(Peer, Chan, Payload, S0) ->
    case maps:get(Chan, S0#s.channels, undefined) of
        {Ns, _Count} ->
            case quod_catchup:decode_frame(Ns, Payload) of
                {ok, {blocks_resp, ReqId, Entries, Height}, InnerBytes}
                  when InnerBytes =< ?QUOD_TRANSPORT_MAX_FRAME_BYTES ->
                    reply_pull(Peer, ReqId, {ok, Entries, Height}, S0);
                {ok, {blocks_err, ReqId}, _InnerBytes} ->
                    reply_pull(Peer, ReqId, {error, retry}, S0);
                _ -> S0
            end;
        undefined -> S0
    end.

reply_pull(Peer, ReqId, Reply, S0) ->
    case maps:get(ReqId, S0#s.pulls, undefined) of
        #pull{peer = Peer, from = From, timer = Timer} ->
            _ = erlang:cancel_timer(Timer),
            gen_server:reply(From, Reply),
            S0#s{pulls = maps:remove(ReqId, S0#s.pulls)};
        _ ->
            S0
    end.

add_channel(Ns, S0) ->
    Chan = quod_catchup:channel(Ns),
    case maps:get(Chan, S0#s.channels, undefined) of
        undefined ->
            true = quod_reg:subscribe({channel, Chan}),
            S0#s{channels = (S0#s.channels)#{Chan => {Ns, 1}}};
        {Ns, Count} ->
            S0#s{channels = (S0#s.channels)#{Chan => {Ns, Count + 1}}}
    end.

remove_channel(Ns, S0) ->
    Chan = quod_catchup:channel(Ns),
    case maps:get(Chan, S0#s.channels, undefined) of
        {Ns, 1} ->
            _ = catch quod_reg:unsubscribe({channel, Chan}),
            S0#s{channels = maps:remove(Chan, S0#s.channels)};
        {Ns, Count} when Count > 1 ->
            S0#s{channels = (S0#s.channels)#{Chan => {Ns, Count - 1}}};
        _ -> S0
    end.

subscribe_histories(S0) ->
    lists:foldl(
      fun({Ns, _Anchor}, Acc) -> add_channel(Ns, Acc) end,
      S0, maps:keys(S0#s.histories)).

%%%===================================================================
%%% Verification worker
%%%===================================================================

verification_worker(
  Owner, RequestRef, Work, Root, FetchFun, PageTimeout, RequestTimeout) ->
    %% Probe children are linked so killing a timed-out verification also
    %% kills every in-flight route fetch. Expected transport exits are
    %% normalized where the dependency is called; an internal fault takes
    %% down this monitored worker and remains visible to the runtime.
    Result0 = verification_work(
                Work, Owner, RequestRef, Root, FetchFun, PageTimeout,
                RequestTimeout),
    {Result, Meta} = normalize_worker_result(Result0),
    Owner ! {foreign_worker_done, RequestRef, Result, Meta}.

verification_work(
  {exact, Peer, Endpoint, Ref, Phase}, Owner, RequestRef,
  Root, FetchFun, PageTimeout, _RequestTimeout) ->
    verify_cached(
      Owner, RequestRef, Peer, Endpoint, Ref, Phase, ref_identity(Ref),
      Root, FetchFun, PageTimeout, true, false);
verification_work(
  {exact_routes, Routes, Ref, Phase}, Owner, RequestRef,
  Root, FetchFun, PageTimeout, _RequestTimeout) ->
    verify_exact_routes(
      Routes, Owner, RequestRef, Ref, Phase, ref_identity(Ref),
      Root, FetchFun, PageTimeout, none, #{});
verification_work(
  {current, Routes, Ref}, Owner, RequestRef,
  Root, FetchFun, PageTimeout, RequestTimeout) ->
    verify_current_cached(
      Owner, RequestRef, Routes, Ref, Root, FetchFun, PageTimeout,
      RequestTimeout);
verification_work(
  {local_current, LedgerRoot, Ref}, Owner, RequestRef,
  Root, FetchFun, PageTimeout, _RequestTimeout) ->
    verify_local_current_cached(
      Owner, RequestRef, LedgerRoot, Ref, Root, FetchFun, PageTimeout);
verification_work(
  {current_identity, Routes, Identity}, Owner, RequestRef,
  Root, FetchFun, PageTimeout, RequestTimeout) ->
    certified_current_snapshot(
      Owner, RequestRef, Routes, Identity,
      Root, FetchFun, PageTimeout, RequestTimeout);
verification_work(
  {local_current_identity, LedgerRoot, Identity}, Owner, RequestRef,
  Root, FetchFun, PageTimeout, _RequestTimeout) ->
    verify_local_current_identity_cached(
      Owner, RequestRef, LedgerRoot, Identity,
      Root, FetchFun, PageTimeout);
verification_work(
  {follow, Identity, Routes}, Owner, RequestRef,
  Root, FetchFun, PageTimeout, RequestTimeout) ->
    follow_identity(
      Owner, RequestRef, Identity, Routes, Root, FetchFun,
      PageTimeout, RequestTimeout).

verify_exact_routes(
  [], _Owner, _RequestRef, _Ref, _Phase, _Identity,
  _Root, _FetchFun, _PageTimeout, none, Meta) ->
    {{error, retry}, Meta};
verify_exact_routes(
  [], _Owner, _RequestRef, _Ref, _Phase, _Identity,
  _Root, _FetchFun, _PageTimeout, definitive, Meta) ->
    {{error, invalid_foreign_reference}, Meta};
verify_exact_routes(
  [{Peer, Endpoint} | Rest], Owner, RequestRef, Ref, Phase, Identity,
  Root, FetchFun, PageTimeout, Prior, _Meta0) ->
    case verify_cached(
           Owner, RequestRef, Peer, Endpoint, Ref, Phase, Identity,
           Root, FetchFun, PageTimeout, true, false) of
        {{ok, _} = Result, Meta} ->
            {Result, Meta};
        {{error, Reason}, Meta}
          when Reason =:= phase_mismatch;
               Reason =:= invalid_foreign_reference ->
            verify_exact_routes(
              Rest, Owner, RequestRef, Ref, Phase, Identity,
              Root, FetchFun, PageTimeout, definitive, Meta);
        {{error, _}, Meta} ->
            verify_exact_routes(
              Rest, Owner, RequestRef, Ref, Phase, Identity,
              Root, FetchFun, PageTimeout, Prior, Meta)
    end.

normalize_worker_result({{ok, _} = Result, Meta}) when is_map(Meta) ->
    {Result, Meta};
normalize_worker_result({{error, _} = Result, Meta}) when is_map(Meta) ->
    {Result, Meta}.

follow_identity(Owner, RequestRef, Identity = {Ns, _Anchor}, Routes, Root,
                FetchFun, PageTimeout, RequestTimeout) ->
    case quod_simplex:history_source(Identity) of
        {ok, LedgerRoot} ->
            LocalPeer = {local, Identity},
            LocalFetch =
                fun(_Peer, _Endpoint, RequestedNs, FromIndex, ToIndex) ->
                    case RequestedNs =:= Ns of
                        true -> quod_catchup:serve_blocks(
                                  Ns, LedgerRoot, FromIndex, ToIndex);
                        false -> {error, wrong_namespace}
                    end
                end,
            follow_local_snapshot(
              Owner, RequestRef, LocalPeer, LedgerRoot, Identity,
              Root, LocalFetch, PageTimeout);
        {error, _} ->
            case Routes of
                [_ | _] ->
                    certified_current_snapshot(
                      Owner, RequestRef, Routes, Identity,
                      Root, FetchFun, PageTimeout, RequestTimeout);
                [] ->
                    {{error, {unreachable, unavailable}}, #{}}
            end
    end.

follow_local_snapshot(Owner, RequestRef, LocalPeer, LedgerRoot,
                      Identity = {Ns, Anchor}, Root, FetchFun, PageTimeout) ->
    case quod_ledger_store:open_ro(Ns, LedgerRoot) of
        {ok, Source} ->
            Tip = quod_ledger_store:last(Source),
            _ = quod_ledger_store:close(Source),
            case open_cache(Owner, RequestRef, Identity, Root, none) of
                {ok, Store0, Height0, Projection0, PhaseIndex, _} ->
                    Outcome =
                        try
                            case Tip > Height0 of
                                true ->
                                    Target = min(
                                               Tip,
                                               Height0 +
                                                   ?QUOD_MAX_FOREIGN_PAGE_ENTRIES),
                                    advance_snapshot_sources(
                                      [{LocalPeer, local}], Owner, RequestRef,
                                      Ns, Anchor, Identity, Store0, Height0,
                                      Projection0, PhaseIndex, Root, Target,
                                      FetchFun, PageTimeout);
                                false ->
                                    {ok, Height0, Projection0}
                            end
                        after
                            _ = quod_dtx_phase_index:close(PhaseIndex),
                            _ = quod_ledger_store:close(Store0)
                        end,
                    case Outcome of
                        {ok, Height1, Projection1} ->
                            View = case Height1 >= Tip of
                                       true -> confirmed;
                                       false -> unconfirmed
                                   end,
                            Evidence = (current_view_evidence(
                                          Identity, Height1, Projection1))#{
                                         hinted_height => Tip,
                                         current_view => View},
                            {{ok, Evidence},
                             #{height => Height1,
                               bytes => cache_persisted_bytes(
                                          Root, cache_namespace(Identity)),
                               projection => Projection1}};
                        {error, _} ->
                            {{error, retry},
                             #{height => Height0,
                               bytes => cache_persisted_bytes(
                                          Root, cache_namespace(Identity)),
                               projection => Projection0}}
                    end;
                {error, _} ->
                    {{error, retry}, #{}}
            end;
        _ ->
            {{error, {unreachable, unavailable}}, #{}}
    end.

verify_cached(Owner, RequestRef, Peer, Endpoint, Ref, Phase, Identity,
              Root, FetchFun, PageTimeout, RequirePeer, Retried) ->
    Slot = ref_slot(Ref),
    case open_cache(Owner, RequestRef, Identity, Root, Slot) of
        {ok, Store0, Height0, Projection0, PhaseIndex, SlotProjection0} ->
            Outcome = try
                          case fetch_to_height(
                                 Owner, RequestRef, Peer, Endpoint, Slot,
                                 Identity, Store0, Height0, Projection0,
                                 SlotProjection0, PhaseIndex, Root, FetchFun,
                                 PageTimeout) of
                              {ok, Store1, CacheHeight, CacheProjection,
                               EvidenceProjection} ->
                                  {verified,
                                   verify_reference_source(
                                     Peer,
                                     verify_exact_reference(
                                       Store1, Ref, Phase,
                                       EvidenceProjection),
                                     RequirePeer),
                                   CacheHeight, CacheProjection};
                              Other -> Other
                          end
            after
                _ = quod_dtx_phase_index:close(PhaseIndex),
                _ = quod_ledger_store:close(Store0)
            end,
            case Outcome of
                {verified, Result, VerifiedHeight, VerifiedProjection} ->
                    Bytes = cache_persisted_bytes(
                              Root, cache_namespace(Identity)),
                    {Result,
                     #{height => VerifiedHeight, bytes => Bytes,
                       projection => VerifiedProjection}};
                {error, cache_corrupt} ->
                    retry_corrupt_cache(
                      Owner, RequestRef, Peer, Endpoint, Ref, Phase,
                      Identity, Root, FetchFun, PageTimeout,
                      RequirePeer, Retried);
                {error, _} ->
                    {{error, retry},
                     #{height => Height0,
                       bytes => cache_persisted_bytes(
                                  Root, cache_namespace(Identity)),
                       projection => Projection0}}
            end;
        {error, cache_corrupt} ->
            retry_corrupt_cache(
              Owner, RequestRef, Peer, Endpoint, Ref, Phase, Identity,
              Root, FetchFun, PageTimeout, RequirePeer, Retried);
        {error, _} ->
            {{error, retry}, #{}}
    end.

retry_corrupt_cache(_Owner, _RequestRef, _Peer, _Endpoint, _Ref, _Phase,
                    _Identity, _Root, _FetchFun, _PageTimeout,
                    _RequirePeer, true) ->
    {{error, retry}, #{}};
retry_corrupt_cache(Owner, RequestRef, Peer, Endpoint, Ref, Phase,
                    Identity, Root, FetchFun, PageTimeout,
                    RequirePeer, false) ->
    case gen_server:call(Owner, {reset_cache, RequestRef}) of
        ok ->
            _ = file:del_dir_r(
                  cache_dir(Root, cache_namespace(Identity))),
            verify_cached(Owner, RequestRef, Peer, Endpoint, Ref, Phase,
                          Identity, Root, FetchFun, PageTimeout,
                          RequirePeer, true);
        {error, _} ->
            {{error, retry}, #{}}
    end.

verify_current_cached(
  Owner, RequestRef, Routes, Ref, Root, FetchFun, PageTimeout,
  RequestTimeout) ->
    Identity = ref_identity(Ref),
    case verify_current_reference(
           Routes, Owner, RequestRef, Ref, Identity,
           Root, FetchFun, PageTimeout) of
        {{ok, _FinalizeEvidence}, _Meta} ->
            certified_current_snapshot(
              Owner, RequestRef, Routes, Identity,
              Root, FetchFun, PageTimeout, RequestTimeout);
        {{error, _} = Error, Meta} ->
            {Error, Meta}
    end.

verify_current_reference(
  [], _Owner, _RequestRef, _Ref, _Identity,
  _Root, _FetchFun, _PageTimeout) ->
    {{error, retry}, #{}};
verify_current_reference(
  [{Peer, Endpoint} | Rest], Owner, RequestRef, Ref, Identity,
  Root, FetchFun, PageTimeout) ->
    case verify_cached(
           Owner, RequestRef, Peer, Endpoint, Ref, finalize, Identity,
           Root, FetchFun, PageTimeout, false, false) of
        {{ok, _} = Ok, Meta} ->
            {Ok, Meta};
        {{error, retry}, _Meta} ->
            verify_current_reference(
              Rest, Owner, RequestRef, Ref, Identity,
              Root, FetchFun, PageTimeout);
        Definitive ->
            Definitive
    end.

certified_current_snapshot(
  Owner, RequestRef, Routes, Identity = {Ns, Anchor},
  Root, FetchFun, PageTimeout, RequestTimeout) ->
    case open_cache(Owner, RequestRef, Identity, Root, none) of
        {ok, Store0, Height0, Projection0, PhaseIndex, _RefProjection} ->
            Outcome =
                try
                    Hints = current_route_hints(Routes, Projection0),
                    case advance_current_snapshot(
                           Owner, RequestRef, Hints, Identity, Store0,
                           Height0, Projection0, PhaseIndex, Root,
                           FetchFun, PageTimeout, RequestTimeout) of
                        {ok, Height1, Projection1} ->
                            ConfirmHints = current_route_hints(
                                             Routes, Projection1),
                            case current_view_confirmed(
                                   Owner, RequestRef, ConfirmHints, Ns,
                                   Anchor, Identity, Height1, Projection1,
                                   PhaseIndex,
                                   FetchFun, PageTimeout) of
                                true ->
                                    {ok, current_view_evidence(
                                           Identity, Height1, Projection1),
                                     Height1, Projection1};
                                false ->
                                    {unconfirmed, Height1, Projection1}
                            end;
                        {error, _} = Error ->
                            Error
                    end
                after
                    _ = quod_dtx_phase_index:close(PhaseIndex),
                    _ = quod_ledger_store:close(Store0)
                end,
            current_snapshot_result(Outcome, Root, Identity,
                                    Height0, Projection0);
        {error, _} ->
            {{error, retry}, #{}}
    end.

current_snapshot_result(
  {ok, Evidence, Height, Projection}, Root, Identity,
  _OldHeight, _OldProjection) ->
    {{ok, Evidence},
     #{height => Height,
       bytes => cache_persisted_bytes(Root, cache_namespace(Identity)),
       projection => Projection}};
current_snapshot_result(
  {unconfirmed, Height, Projection}, Root, Identity,
  _OldHeight, _OldProjection) ->
    {{error, retry},
     #{height => Height,
       bytes => cache_persisted_bytes(Root, cache_namespace(Identity)),
       projection => Projection}};
current_snapshot_result(
  {error, _}, Root, Identity, Height, Projection) ->
    {{error, retry},
     #{height => Height,
       bytes => cache_persisted_bytes(Root, cache_namespace(Identity)),
       projection => Projection}}.

verify_local_current_cached(
  Owner, RequestRef, LedgerRoot, Ref, Root, FetchFun, PageTimeout) ->
    Identity = {Ns, _Anchor} = ref_identity(Ref),
    case quod_ledger_store:open_ro(Ns, LedgerRoot) of
        {ok, Source} ->
            Height = quod_ledger_store:last(Source),
            _ = quod_ledger_store:close(Source),
            case Height >= ref_slot(Ref) of
                true ->
                    verify_local_current_height(
                      Owner, RequestRef, {finalize, Ref}, Identity, Height,
                      Root, FetchFun, PageTimeout);
                false ->
                    {{error, retry}, #{}}
            end;
        _ ->
            {{error, retry}, #{}}
    end.

verify_local_current_identity_cached(
  Owner, RequestRef, LedgerRoot,
  Identity = {Ns, _Anchor}, Root, FetchFun, PageTimeout) ->
    case quod_ledger_store:open_ro(Ns, LedgerRoot) of
        {ok, Source} ->
            Height = quod_ledger_store:last(Source),
            _ = quod_ledger_store:close(Source),
            case Height > 0 of
                true ->
                    verify_local_current_height(
                      Owner, RequestRef, none, Identity, Height,
                      Root, FetchFun, PageTimeout);
                false ->
                    {{error, retry}, #{}}
            end;
        _ ->
            {{error, retry}, #{}}
    end.

verify_local_current_height(
  Owner, RequestRef, RequiredReference, Identity, Height,
  Root, FetchFun, PageTimeout) ->
    LocalPeer = {local, Identity},
    case open_cache(Owner, RequestRef, Identity, Root, Height) of
        {ok, Store0, Height0, Projection0, PhaseIndex, HeightProjection0} ->
            Outcome =
                try
                    case fetch_to_height(
                           Owner, RequestRef, LocalPeer, local,
                           Height, Identity,
                           Store0, Height0, Projection0, HeightProjection0,
                           PhaseIndex, Root, FetchFun, PageTimeout) of
                        {ok, Store1, CacheHeight, CacheProjection,
                         CurrentProjection}
                          when CacheHeight >= Height ->
                            case verify_current_basis(
                                   Store1, RequiredReference,
                                   CurrentProjection) of
                                ok ->
                                    {ok, current_view_evidence(
                                           Identity, Height,
                                           CurrentProjection),
                                     CacheHeight, CacheProjection};
                                {error, _} = Error -> Error
                            end;
                        {ok, _Store1, _CacheHeight, _Projection,
                         _CurrentProjection} ->
                            {error, retry};
                        {error, _} = Error -> Error
                    end
                after
                    _ = quod_dtx_phase_index:close(PhaseIndex),
                    _ = quod_ledger_store:close(Store0)
                end,
            current_snapshot_result(Outcome, Root, Identity,
                                    Height0, Projection0);
        {error, _} ->
            {{error, retry}, #{}}
    end.

verify_current_basis(_Store, none, _CurrentProjection) ->
    ok;
verify_current_basis(Store, {Phase, Ref}, CurrentProjection) ->
    case verify_exact_reference(Store, Ref, Phase, CurrentProjection) of
        {ok, _Evidence} -> ok;
        {error, _} = Error -> Error
    end.

open_cache(Owner, RequestRef, Identity = {Ns, Anchor}, Root, TargetSlot) ->
    CacheNs = cache_namespace(Identity),
    Dir = cache_dir(Root, CacheNs),
    ok = cleanup_cache_temps(Dir),
    _ = quod_dtx_phase_index:cleanup(Root, CacheNs),
    case ensure_manifest(Owner, RequestRef, Root, Identity, CacheNs) of
        ok ->
            try quod_ledger_store:open(CacheNs, Root) of
                {ok, Store} ->
                    Height = quod_ledger_store:last(Store),
                    case load_checkpoint(Root, Identity, CacheNs, Height) of
                        {ok, CheckpointProjection} ->
                            case quod_dtx_phase_index:open(Root, CacheNs) of
                                {ok, PhaseIndex} ->
                                    Projection0 = quod_simplex:history_projection(
                                                    {Ns, Anchor}),
                                    case replay_cache(
                                           Store, Ns, Anchor, Height,
                                           Projection0, PhaseIndex,
                                           TargetSlot) of
                                        {ok, Projection, TargetProjection}
                                          when Projection =:=
                                                   CheckpointProjection ->
                                            {ok, Store, Height, Projection,
                                             PhaseIndex, TargetProjection};
                                        {ok, _Different, _TargetProjection} ->
                                            _ = quod_dtx_phase_index:close(
                                                  PhaseIndex),
                                            _ = quod_ledger_store:close(Store),
                                            {error, cache_corrupt};
                                        {error, retry} ->
                                            _ = quod_dtx_phase_index:close(
                                                  PhaseIndex),
                                            _ = quod_ledger_store:close(Store),
                                            {error, retry};
                                        {error, _} ->
                                            _ = quod_dtx_phase_index:close(
                                                  PhaseIndex),
                                            _ = quod_ledger_store:close(Store),
                                            {error, cache_corrupt}
                                    end;
                                {error, _} ->
                                    _ = quod_ledger_store:close(Store),
                                    {error, cache_io}
                            end;
                        new when Height =:= 0 ->
                            case quod_dtx_phase_index:open(Root, CacheNs) of
                                {ok, PhaseIndex} ->
                                    Projection = quod_simplex:history_projection(
                                                   {Ns, Anchor}),
                                    {ok, Store, 0, Projection, PhaseIndex,
                                     undefined};
                                {error, _} ->
                                    _ = quod_ledger_store:close(Store),
                                    {error, cache_io}
                            end;
                        _ ->
                            _ = quod_ledger_store:close(Store),
                            {error, cache_corrupt}
                    end
            catch _:_ ->
                {error, cache_corrupt}
            end;
        {error, _} ->
            {error, cache_corrupt}
    end.

replay_cache(_Store, _Ns, _Anchor, 0, Projection, _PhaseIndex,
             _TargetSlot) ->
    {ok, Projection, undefined};
replay_cache(Store, Ns, Anchor, Height, Projection0, PhaseIndex,
             TargetSlot) ->
    replay_cache(Store, Ns, Anchor, 1, Height, Projection0, PhaseIndex,
                 TargetSlot, undefined).

replay_cache(_Store, Ns, Anchor, From, Height, Projection, _PhaseIndex,
             TargetSlot, TargetProjection)
  when From > Height ->
    TargetOk = case TargetSlot of
                   none -> true;
                   _ -> TargetSlot > Height orelse
                            valid_projection(
                              TargetProjection, {Ns, Anchor})
               end,
    case valid_projection(Projection, {Ns, Anchor}) andalso TargetOk of
        true -> {ok, Projection, TargetProjection};
        false -> {error, cache_corrupt}
    end;
replay_cache(Store, Ns, Anchor, From, Height, Projection0, PhaseIndex,
             TargetSlot, TargetProjection0) ->
    WindowTo = min(Height, From + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES - 1),
    %% End one replay window exactly at the requested reference slot so the
    %% evidence projection is the post-slot state even when this durable cache
    %% has already advanced beyond it.
    To = case is_integer(TargetSlot) andalso
                  TargetSlot >= From andalso TargetSlot < WindowTo of
             true -> TargetSlot;
             false -> WindowTo
         end,
    try quod_ledger_store:read_range(Store, From, To) of
        {ok, Entries} ->
            case quod_catchup:page_stats(Entries) of
                {ok, Count, _Bytes} when Count =:= To - From + 1 ->
                    case quod_catchup:verify_forward(
                           Ns, Anchor, Projection0, From, Entries,
                           PhaseIndex) of
                        {ok, _Verified, Projection1, Delta} ->
                            case valid_projection(Projection1, {Ns, Anchor})
                                 andalso quod_dtx_phase_index:commit_delta(
                                           PhaseIndex, Delta) =:= ok of
                                true ->
                                    TargetProjection1 =
                                        case is_integer(TargetSlot) andalso
                                                  To =:= TargetSlot of
                                            true -> Projection1;
                                            false -> TargetProjection0
                                        end,
                                    replay_cache(
                                      Store, Ns, Anchor, To + 1, Height,
                                      Projection1, PhaseIndex, TargetSlot,
                                      TargetProjection1);
                                false -> {error, cache_corrupt}
                            end;
                        {error, {unavailable, network_identity, _Reason}} ->
                            {error, retry};
                        {error, _} -> {error, cache_corrupt}
                    end;
                _ -> {error, cache_corrupt}
            end
    catch _:_ ->
        {error, cache_corrupt}
    end.

fetch_to_height(Owner, RequestRef, Peer, Endpoint, Slot,
                Identity = {Ns, Anchor}, Store0, Height0, Projection0,
                SlotProjection0, PhaseIndex, Root, FetchFun, PageTimeout) ->
    case Height0 >= Slot of
        true when is_map(SlotProjection0) ->
            {ok, Store0, Height0, Projection0, SlotProjection0};
        true ->
            {error, cache_corrupt};
        false ->
            From = Height0 + 1,
            To = min(Slot, From + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES - 1),
            case fetch_page(Owner, RequestRef, Peer, Endpoint, Ns,
                            From, To, FetchFun, PageTimeout) of
                {ok, Entries, RemoteHeight} when is_integer(RemoteHeight),
                                                  RemoteHeight >= 0 ->
                    case prepare_verified_page(
                           Ns, Anchor, Identity, Projection0, PhaseIndex,
                           From, To, Entries, RemoteHeight) of
                        {ok, Prepared} ->
                            case persist_verified_page(
                                   Owner, RequestRef, Identity, Store0,
                                   Height0, PhaseIndex, Root, Prepared) of
                                {ok, Store1, Height1, Projection1} ->
                                    SlotProjection1 =
                                        case Height1 =:= Slot of
                                            true -> Projection1;
                                            false -> undefined
                                        end,
                                    fetch_to_height(
                                      Owner, RequestRef, Peer, Endpoint, Slot,
                                      Identity, Store1, Height1, Projection1,
                                      SlotProjection1, PhaseIndex, Root,
                                      FetchFun, PageTimeout);
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                _ ->
                    {error, retry}
            end
    end.

prepare_verified_page(
  Ns, Anchor, Identity, Projection0, PhaseIndex,
  From, To, Entries, RemoteHeight) ->
    case validate_page(Entries, From, To, RemoteHeight) of
        {ok, Count, EntryBytes} ->
            case quod_catchup:verify_forward(
                   Ns, Anchor, Projection0, From, Entries, PhaseIndex) of
                {ok, Verified, Projection1, Delta}
                  when length(Verified) =:= Count ->
                    case valid_projection(Projection1, Identity) of
                        true ->
                            {ok, #{verified => Verified,
                                   projection => Projection1,
                                   phase_delta => Delta,
                                   count => Count,
                                   stored_bytes => EntryBytes + 12 * Count}};
                        false ->
                            {error, invalid_history}
                    end;
                {error, {unavailable, network_identity, _Reason}} = Global ->
                    Global;
                {error, _} ->
                    {error, invalid_history}
            end;
        {error, _} ->
            {error, invalid_history}
    end.

persist_verified_page(
  Owner, RequestRef, Identity, Store0, Height0, PhaseIndex, Root,
  #{verified := Verified, projection := Projection1,
    phase_delta := Delta, count := Count, stored_bytes := StoredBytes}) ->
    %% The checkpoint replaces its predecessor after the append. Reserve its
    %% complete maximum before either durable allocation, then reconcile to
    %% the exact persisted bytes after the atomic rename.
    Reservation = StoredBytes + ?QUOD_MAX_FOREIGN_PAGE_BYTES,
    case gen_server:call(
           Owner, {reserve_page, RequestRef, Reservation}) of
        ok ->
            try quod_ledger_store:append(Store0, Verified) of
                {ok, Store1} ->
                    case quod_dtx_phase_index:commit_delta(PhaseIndex, Delta) of
                        ok ->
                            Height1 = Height0 + Count,
                            case write_checkpoint(
                                   Root, Identity, cache_namespace(Identity),
                                   Height1, Projection1) of
                                ok ->
                                    ActualBytes = cache_persisted_bytes(
                                                    Root,
                                                    cache_namespace(Identity)),
                                    case gen_server:call(
                                           Owner,
                                           {set_cache_size, RequestRef,
                                            ActualBytes}) of
                                        ok ->
                                            {ok, Store1, Height1, Projection1};
                                        {error, _} ->
                                            {error, cache_corrupt}
                                    end;
                                {error, _} ->
                                    {error, cache_corrupt}
                            end;
                        {error, _} ->
                            {error, cache_corrupt}
                    end
            catch _:_ ->
                {error, cache_corrupt}
            end;
        {error, _} ->
            {error, cache_full}
    end.

current_route_hints(Supplied, Projection) ->
    Certified = maps:to_list(
                  quod_simplex:history_validator_routes(Projection)),
    %% The replayed projection is certificate-verified; caller routes are
    %% discovery hints only. Once history names the key for an endpoint, a
    %% contradictory caller claim for that address has no authority and is
    %% discarded. Before slot 1 there is no certified route, so bootstrap uses
    %% ordered failover below instead of trusting or racing the hints.
    CertifiedEndpoints = maps:from_keys(
                           [Endpoint || {_Peer, Endpoint} <- Certified], true),
    Unshadowed = [Route || Route = {_Peer, Endpoint} <- Supplied,
                           not maps:is_key(Endpoint, CertifiedEndpoints)],
    %% Preserve discovery order.  Bootstrap deliberately walks sources in
    %% order, so sorting here would silently change which authenticated
    %% source is tried first (and made that choice depend on random keys).
    Hints = stable_unique_routes(Certified ++ Unshadowed),
    case length(Hints) =< ?MAX_CURRENT_ROUTE_HINTS of
        true -> Hints;
        false -> []
    end.

stable_unique_routes(Routes) ->
    {Unique, _Seen} =
        lists:foldl(
          fun({PeerKey, _Endpoint} = Route, {Acc, Seen}) ->
              case maps:is_key(PeerKey, Seen) of
                  true -> {Acc, Seen};
                  false -> {[Route | Acc], Seen#{PeerKey => true}}
              end
          end, {[], #{}}, Routes),
    lists:reverse(Unique).

advance_current_snapshot(
  Owner, RequestRef, Hints, Identity, Store0, Height0, Projection0,
  PhaseIndex, Root, FetchFun, PageTimeout, RequestTimeout) ->
    case maps:size(quod_simplex:history_validator_routes(Projection0)) of
        0 ->
            bootstrap_snapshot_sources(
              Hints, Owner, RequestRef, Identity, Store0, Height0,
              Projection0, PhaseIndex, Root, FetchFun,
              bootstrap_route_timeout(
                PageTimeout, RequestTimeout, length(Hints)),
              PageTimeout);
        _ ->
            {Ns, _Anchor} = Identity,
            Results = probe_pages(
                        Owner, RequestRef, Hints, Ns, Height0,
                        FetchFun, PageTimeout),
            advance_snapshot(
              Owner, RequestRef, Identity, Store0, Height0, Projection0,
              PhaseIndex, Root, Results, FetchFun, PageTimeout)
    end.

bootstrap_route_timeout(PageTimeout, RequestTimeout, RouteCount) ->
    %% Discovery gets at most half the request. The remaining half is reserved
    %% for downloading and verifying the selected history and corroborating
    %% its resulting committee view.
    PerRoute = erlang:max(1, RequestTimeout div (2 * erlang:max(1, RouteCount))),
    erlang:min(PageTimeout, PerRoute).

%% Before genesis is replayed every route is only a discovery hint. Trying
%% them concurrently lets contradictory credentials for one address contend
%% during first contact. Walk the bounded list instead: a source must deliver
%% a page that passes the ordinary certificate/history fold before it wins.
bootstrap_snapshot_sources(
  [], _Owner, _RequestRef, _Identity, _Store, _Height, _Projection,
  _PhaseIndex, _Root, _FetchFun, _BootstrapTimeout, _PageTimeout) ->
    {error, invalid_history};
bootstrap_snapshot_sources(
  [Source | Rest], Owner, RequestRef,
  Identity, Store0, Height0, Projection0, PhaseIndex,
  Root, FetchFun, BootstrapTimeout, PageTimeout) ->
    case bootstrap_snapshot_source(
           Source, Owner, RequestRef, Identity, Store0, Height0,
           Projection0, PhaseIndex, Root, FetchFun, BootstrapTimeout,
           PageTimeout) of
        {ok, _Height1, _Projection1} = Ok -> Ok;
        {error, {unavailable, network_identity, _}} = Global -> Global;
        {error, Reason} ->
            logger:debug(
              "foreign history bootstrap source failed identity=~p "
              "source=~p reason=~p",
              [Identity, Source, Reason]),
            bootstrap_snapshot_sources(
              Rest, Owner, RequestRef, Identity, Store0, Height0,
              Projection0, PhaseIndex, Root, FetchFun, BootstrapTimeout,
              PageTimeout)
    end.

bootstrap_snapshot_source(
  Source = {Peer, Endpoint}, Owner, RequestRef,
  Identity = {Ns, Anchor}, Store0, Height0, Projection0, PhaseIndex,
  Root, FetchFun, BootstrapTimeout, PageTimeout) ->
    ProbeTo = Height0 + 1,
    case fetch_page(
           Owner, RequestRef, Peer, Endpoint, Ns,
           Height0 + 1, ProbeTo, FetchFun, BootstrapTimeout) of
        {ok, Entries, RemoteHeight}
          when is_integer(RemoteHeight), RemoteHeight > Height0 ->
            case validate_page(
                   Entries, Height0 + 1, ProbeTo, RemoteHeight) of
                {ok, _Count, _Bytes} ->
                    Target = min(
                               RemoteHeight,
                               Height0 + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES),
                    case advance_snapshot_sources(
                           [Source], Owner, RequestRef, Ns, Anchor, Identity,
                           Store0, Height0, Projection0, PhaseIndex, Root,
                           Target, FetchFun, PageTimeout) of
                        Result -> Result
                    end;
                {error, Reason} ->
                    {error, {bootstrap_page, Reason}}
            end;
        {ok, _Entries, _RemoteHeight} ->
            {error, no_new_page};
        {error, Reason} ->
            {error, {bootstrap_fetch, Reason}}
    end.

probe_pages(Owner, RequestRef, Hints, Ns, Height, FetchFun, PageTimeout) ->
    %% Snapshot probes need only the first available certified candidate plus
    %% the responder's captured durable height. Keeping one entry per route
    %% prevents an N-validator fanout from retaining N near-900-KiB pages.
    To = Height + 1,
    parallel_probes(
      Hints,
      fun({Peer, Endpoint}) ->
          fetch_page(Owner, RequestRef, Peer, Endpoint, Ns,
                     Height + 1, To, FetchFun, PageTimeout)
      end,
      PageTimeout).

parallel_probes(Items, Probe, TimeoutMs) ->
    Parent = self(),
    Tag = make_ref(),
    Pending = lists:foldl(
                fun(Item, Acc) ->
                    {Pid, MRef} = spawn_opt(
                                    fun() ->
                                        Result = Probe(Item),
                                        Parent ! {foreign_probe, Tag, self(),
                                                  Item, Result}
                                    end, [link, monitor]),
                    Acc#{Pid => {MRef, Item}}
                end, #{}, Items),
    Deadline = quod_time:mono_ms() + TimeoutMs,
    collect_probes(Tag, Pending, Deadline, []).

collect_probes(_Tag, Pending, _Deadline, Acc)
  when map_size(Pending) =:= 0 ->
    lists:reverse(Acc);
collect_probes(Tag, Pending, Deadline, Acc) ->
    Wait = max(0, Deadline - quod_time:mono_ms()),
    receive
        {foreign_probe, Tag, Pid, Item, Result}
          when is_map_key(Pid, Pending) ->
            {{MRef, Item}, Pending1} = maps:take(Pid, Pending),
            _ = erlang:demonitor(MRef, [flush]),
            collect_probes(
              Tag, Pending1, Deadline, [{Item, Result} | Acc]);
        {'DOWN', MRef, process, Pid, _Reason}
          when is_map_key(Pid, Pending) ->
            case maps:get(Pid, Pending) of
                {MRef, _Item} ->
                    collect_probes(
                      Tag, maps:remove(Pid, Pending), Deadline, Acc);
                _ ->
                    collect_probes(Tag, Pending, Deadline, Acc)
            end
    after Wait ->
        stop_current_probes(Pending),
        lists:reverse(Acc)
    end.

stop_current_probes(Pending) ->
    maps:foreach(
      fun(Pid, {MRef, _Item}) ->
          _ = erlang:demonitor(MRef, [flush]),
          _ = unlink(Pid),
          exit(Pid, kill)
      end, Pending).

advance_snapshot(
  Owner, RequestRef, Identity = {Ns, Anchor}, Store0, Height0,
  Projection0, PhaseIndex, Root, Results, FetchFun, PageTimeout) ->
    ProbeTo = Height0 + 1,
    Candidates =
        [{RemoteHeight, Source}
         || {Source, {ok, Entries, RemoteHeight}} <- Results,
            is_integer(RemoteHeight), RemoteHeight > Height0,
            validate_page(Entries, Height0 + 1, ProbeTo, RemoteHeight)
                =/= {error, bad_page}],
    case Candidates of
        [] ->
            {ok, Height0, Projection0};
        _ ->
            Advertised = lists:max([H || {H, _Source} <- Candidates]),
            Target = min(
                       Advertised,
                       Height0 + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES),
            Sources = [Source
                       || {_H, Source} <- lists:reverse(
                                             lists:keysort(1, Candidates))],
            advance_snapshot_sources(
              Sources, Owner, RequestRef, Ns, Anchor, Identity,
              Store0, Height0, Projection0, PhaseIndex, Root, Target,
              FetchFun, PageTimeout)
    end.

advance_snapshot_sources(
  [], _Owner, _RequestRef, _Ns, _Anchor, _Identity,
  _Store, _Height, _Projection, _PhaseIndex, _Root, _Target,
  _FetchFun, _PageTimeout) ->
    {error, invalid_history};
advance_snapshot_sources(
  [{Peer, Endpoint} | Rest], Owner, RequestRef,
  Ns, Anchor, Identity, Store0, Height0, Projection0,
  PhaseIndex, Root, Target, FetchFun, PageTimeout) ->
    case fetch_page(
           Owner, RequestRef, Peer, Endpoint, Ns,
           Height0 + 1, Target, FetchFun, PageTimeout) of
        {ok, Entries, RemoteHeight}
          when is_list(Entries), is_integer(RemoteHeight), RemoteHeight >= 0 ->
            case prepare_verified_page(
                   Ns, Anchor, Identity, Projection0, PhaseIndex,
                   Height0 + 1, Target, Entries, RemoteHeight) of
                {ok, Prepared} ->
                    case persist_verified_page(
                           Owner, RequestRef, Identity, Store0, Height0,
                           PhaseIndex, Root, Prepared) of
                        {ok, _Store1, Height1, Projection1} ->
                            {ok, Height1, Projection1};
                        {error, _} = Error ->
                            Error
                    end;
                {error, invalid_history} ->
                    advance_snapshot_sources(
                      Rest, Owner, RequestRef, Ns, Anchor, Identity,
                      Store0, Height0, Projection0, PhaseIndex, Root,
                      Target, FetchFun, PageTimeout);
                {error, {unavailable, network_identity, _}} = Global ->
                    Global
            end;
        _ ->
            advance_snapshot_sources(
              Rest, Owner, RequestRef, Ns, Anchor, Identity,
              Store0, Height0, Projection0, PhaseIndex, Root,
              Target, FetchFun, PageTimeout)
    end.

current_view_confirmed(
  Owner, RequestRef, Hints, Ns, Anchor, Identity, Height, Projection,
  PhaseIndex,
  FetchFun, PageTimeout) ->
    Committee = quod_simplex:history_committee(Projection),
    case Committee of
        [] ->
            false;
        [_ | _] ->
            current_committee_confirmed(
              Committee, Owner, RequestRef, Hints, Ns, Anchor, Identity,
              Height, Projection, PhaseIndex, FetchFun, PageTimeout)
    end.

current_committee_confirmed(
  Committee, Owner, RequestRef, Hints, Ns, Anchor, Identity, Height,
  Projection, PhaseIndex, FetchFun, PageTimeout) ->
    ByPeer = route_hints_by_peer(Hints, Committee),
    Needed = quod_simplex:quorum(length(Committee)),
    Results = parallel_probes(
                maps:to_list(ByPeer),
                fun({Peer, Endpoints}) ->
                    probe_peer_endpoints(
                      Endpoints, Owner, RequestRef, Peer, Ns, Height,
                      FetchFun, PageTimeout)
                end,
                PageTimeout),
    Confirmed = lists:usort(
                  [Peer
                   || {{Peer, _Endpoints}, Responses} <- Results,
                      lists:member(Peer, Committee),
                      lists:any(
                        fun(Response) ->
                            tip_response_at_least(
                              Response, Ns, Anchor, Identity, Height,
                              Projection, PhaseIndex)
                        end,
                        Responses)]),
    length(Confirmed) >= Needed.

route_hints_by_peer(Hints, Committee) ->
    lists:foldl(
      fun({Peer, Endpoint}, Acc) ->
          case lists:member(Peer, Committee) of
              true ->
                  Acc#{Peer => lists:usort(
                                  [Endpoint | maps:get(Peer, Acc, [])])};
              false -> Acc
          end
      end, #{}, Hints).

probe_peer_endpoints(
  [], _Owner, _RequestRef, _Peer, _Ns, _Height,
  _FetchFun, _PageTimeout) ->
    [];
probe_peer_endpoints(
  [Endpoint | Rest], Owner, RequestRef, Peer, Ns, Height,
  FetchFun, PageTimeout) ->
    To = Height + 1,
    Result = fetch_page(
               Owner, RequestRef, Peer, Endpoint, Ns,
               Height + 1, To, FetchFun, PageTimeout),
    [Result | probe_peer_endpoints(
                Rest, Owner, RequestRef, Peer, Ns, Height,
                FetchFun, PageTimeout)].

tip_response_at_least(
  {ok, [], RemoteHeight}, _Ns, _Anchor, _Identity,
  Height, _Projection, _PhaseIndex) ->
    is_integer(RemoteHeight) andalso RemoteHeight >= Height;
tip_response_at_least(
  {ok, Entries, RemoteHeight}, Ns, Anchor, Identity,
  Height, Projection, PhaseIndex) when is_list(Entries) ->
    To = Height + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES,
    case prepare_verified_page(
           Ns, Anchor, Identity, Projection, PhaseIndex,
           Height + 1, To, Entries, RemoteHeight) of
        {ok, _Prepared} -> RemoteHeight >= Height;
        {error, _} -> false
    end;
tip_response_at_least(
  _Result, _Ns, _Anchor, _Identity, _Height, _Projection, _PhaseIndex) ->
    false.

current_view_evidence(Identity, Height, Projection) ->
    Dtx = maps:get(dtx, Projection),
    #{identity => Identity,
      slot => Height,
      generation => maps:get(generation, Dtx),
      committee => quod_simplex:history_committee(Projection),
      committee_id => maps:get(committee_id, Projection),
      routes => quod_simplex:history_validator_routes(Projection)}.

fetch_page(Owner, RequestRef, Peer, Endpoint, Ns, From, To, undefined,
           PageTimeout) ->
    try gen_server:call(
          Owner, {pull_page, RequestRef, Peer, Endpoint, Ns, From, To},
          PageTimeout + 1000)
    catch exit:_ -> {error, retry}
    end;
fetch_page(_Owner, _RequestRef, Peer, Endpoint, Ns, From, To, FetchFun,
           _PageTimeout) ->
    try FetchFun(Peer, Endpoint, Ns, From, To)
    catch exit:_ -> {error, retry}
    end.

validate_page(Entries, From, To, RemoteHeight) ->
    case quod_catchup:page_stats(Entries) of
        {ok, Count, Bytes} when Count > 0, Count =< To - From + 1 ->
            case page_indices(Entries, From, To) andalso
                 RemoteHeight >= From + Count - 1 of
                true -> {ok, Count, Bytes};
                false -> {error, bad_page}
            end;
        _ ->
            {error, bad_page}
    end.

page_indices([], _Next, _To) -> true;
page_indices([#entry{index = Next} | Rest], Next, To) when Next =< To ->
    page_indices(Rest, Next + 1, To);
page_indices(_, _Next, _To) -> false.

verify_exact_reference(Store, Ref, ExpectedPhase, Projection) ->
    Slot = ref_slot(Ref),
    case quod_ledger_store:read_at(Store, Slot) of
        {ok, #entry{data = Data} = Entry} ->
            case quod_ledger:classify(Data) of
                {ExpectedPhase, Control} ->
                    Identity = ref_identity(Ref),
                    case quod_dtx:certified_entry_ref(
                           Identity, Entry, Control) of
                        {ok, Ref} ->
                            DtxProjection = maps:get(dtx, Projection),
                            Generation = maps:get(generation, DtxProjection),
                            Committee = quod_simplex:history_committee(
                                          Projection),
                            Routes = quod_simplex:history_validator_routes(
                                       Projection),
                            {ok,
                             #{identity => Identity,
                               slot => Slot,
                               block_hash => ref_block_hash(Ref),
                               record_digest => ref_record_digest(Ref),
                               phase => ExpectedPhase,
                               generation => Generation,
                               control => Control,
                               committee => Committee,
                               committee_id => maps:get(
                                                 committee_id,
                                                 Projection),
                               routes => Routes}};
                        _ -> {error, invalid_foreign_reference}
                    end;
                {_OtherPhase, _Control} ->
                    {error, phase_mismatch};
                _ ->
                    {error, invalid_foreign_reference}
            end;
        not_found ->
            {error, retry}
    end.

verify_reference_source(Peer, {ok, #{committee := Committee}} = Result,
                        true) ->
    case verified_route_peer(Peer, Committee) of
        true -> Result;
        false ->
            %% This is a route failure, not evidence that the certified
            %% reference is false; callers may try another candidate.
            {error, retry}
    end;
verify_reference_source(_Peer, Result, _RequirePeer) ->
    Result.

verified_route_peer({local, _Identity}, _Committee) -> true;
verified_route_peer(Peer, Committee) -> lists:member(Peer, Committee).

%%%===================================================================
%%% Durable cache
%%%===================================================================

cache_namespace({Ns, Anchor}) ->
    crypto:hash(
      sha256,
      term_to_binary({quod_foreign_log, ?CACHE_VERSION, Ns, Anchor},
                     [deterministic])).

cache_dir(Root, CacheNs) ->
    quod_ledger_store:ns_dir(Root, CacheNs).

manifest_path(Root, CacheNs) ->
    filename:join(cache_dir(Root, CacheNs), ?MANIFEST).

checkpoint_path(Root, CacheNs) ->
    filename:join(cache_dir(Root, CacheNs), ?CHECKPOINT).

cache_log_bytes(Root, CacheNs) ->
    case file:read_file_info(filename:join(cache_dir(Root, CacheNs), ?LOG)) of
        {ok, Info} -> element(2, Info);
        {error, _} -> 0
    end.

cache_persisted_bytes(Root, CacheNs) ->
    Dir = cache_dir(Root, CacheNs),
    file_bytes(filename:join(Dir, ?LOG)) +
        file_bytes(filename:join(Dir, ?MANIFEST)) +
        file_bytes(filename:join(Dir, ?CHECKPOINT)).

file_bytes(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} -> element(2, Info);
        {error, _} -> 0
    end.

ensure_manifest(Owner, RequestRef, Root, {Ns, Anchor}, CacheNs) ->
    Path = manifest_path(Root, CacheNs),
    Expected = {quod_foreign_log_cache, ?CACHE_VERSION,
                Ns, Anchor, CacheNs},
    case read_small_term(Path) of
        {ok, Expected} -> ok;
        {error, enoent} ->
            case gen_server:call(
                   Owner,
                   {reserve_page, RequestRef, ?MANIFEST_RESERVE_BYTES}) of
                ok ->
                    atomic_write(
                      Path, term_to_binary(Expected, [deterministic]));
                {error, _} ->
                    {error, cache_full}
            end;
        _ ->
            {error, corrupt_manifest}
    end.

write_checkpoint(Root, {Ns, Anchor}, CacheNs, Height, Projection) ->
    Bytes = cache_log_bytes(Root, CacheNs),
    Term = {quod_foreign_log_checkpoint, ?CACHE_VERSION,
            Ns, Anchor, Height, Bytes, Projection},
    Blob = term_to_binary(Term, [deterministic]),
    case byte_size(Blob) =< ?QUOD_MAX_FOREIGN_PAGE_BYTES of
        true -> atomic_write(checkpoint_path(Root, CacheNs), Blob);
        false -> {error, checkpoint_too_large}
    end.

load_checkpoint(Root, Identity = {Ns, Anchor}, CacheNs, Height) ->
    Path = checkpoint_path(Root, CacheNs),
    case read_small_term(Path) of
        {ok, {quod_foreign_log_checkpoint, ?CACHE_VERSION,
              Ns, Anchor, Height, StoredBytes, Projection}}
          when is_integer(StoredBytes), StoredBytes >= 0 ->
            case StoredBytes =:= cache_log_bytes(Root, CacheNs) andalso
                 valid_projection(Projection, Identity) of
                true -> {ok, Projection};
                false -> {error, corrupt_checkpoint}
            end;
        {error, enoent} -> new;
        _ -> {error, corrupt_checkpoint}
    end.

read_small_term(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} when element(2, Info) =< ?QUOD_MAX_FOREIGN_PAGE_BYTES ->
            case file:read_file(Path) of
                {ok, Bin} ->
                    case quod_safe_term:decode(
                           Bin, ?QUOD_MAX_FOREIGN_PAGE_BYTES) of
                        {ok, Term} ->
                            case term_to_binary(Term, [deterministic]) =:= Bin of
                                true -> {ok, Term};
                                false -> {error, noncanonical}
                            end;
                        {error, _} -> {error, bad_term}
                    end;
                {error, Reason} -> {error, Reason}
            end;
        {ok, _} -> {error, too_large};
        {error, Reason} -> {error, Reason}
    end.

atomic_write(Path, Blob) ->
    ok = filelib:ensure_dir(Path),
    Token = integer_to_list(erlang:unique_integer([positive, monotonic])),
    Tmp = Path ++ ".new." ++ Token,
    case file:open(Tmp, [write, raw, binary, exclusive]) of
        {ok, Fd} ->
            Result =
                try
                    ok = file:write(Fd, Blob),
                    ok = file:datasync(Fd),
                    ok
                catch _:_ -> {error, write_failed}
                after _ = file:close(Fd)
                end,
            case Result of
                ok ->
                    case file:rename(Tmp, Path) of
                        ok -> sync_dir(filename:dirname(Path));
                        {error, _} = Error -> _ = file:delete(Tmp), Error
                    end;
                {error, _} = Error ->
                    _ = file:delete(Tmp),
                    Error
            end;
        {error, _} = Error -> Error
    end.

sync_dir(Dir) ->
    case file:open(Dir, [read, raw]) of
        {ok, Fd} ->
            Result = file:datasync(Fd),
            _ = file:close(Fd),
            case Result of
                ok -> ok;
                {error, eisdir} -> ok;
                Error -> Error
            end;
        {error, eisdir} -> ok;
        {error, Reason} -> {error, Reason}
    end.

load_histories(Root) ->
    case file:list_dir(Root) of
        {ok, Names} -> load_history_dirs(Root, Names, #{}, 0);
        {error, enoent} -> {#{}, 0};
        {error, _} -> {#{}, 0}
    end.

load_history_dirs(_Root, [], Histories, Total) ->
    {Histories, Total};
load_history_dirs(Root, [Name | Rest], Histories0, Total0) ->
    Dir = filename:join(Root, Name),
    case load_history_dir(Root, Dir) of
        {ok, H = #history{identity = Identity, bytes = Bytes}}
          when map_size(Histories0) < ?QUOD_MAX_FOREIGN_HISTORIES,
               Total0 + Bytes =< ?QUOD_MAX_FOREIGN_CACHE_BYTES ->
            load_history_dirs(
              Root, Rest, Histories0#{Identity => H}, Total0 + Bytes);
        {ok, _OverLimit} ->
            _ = remove_cache_path(Dir),
            load_history_dirs(Root, Rest, Histories0, Total0);
        error ->
            _ = remove_cache_path(Dir),
            load_history_dirs(Root, Rest, Histories0, Total0)
    end.

load_history_dir(Root, Dir) ->
    ok = cleanup_cache_temps(Dir),
    case read_small_term(filename:join(Dir, ?MANIFEST)) of
        {ok, {quod_foreign_log_cache, ?CACHE_VERSION,
              Ns, <<_:256>> = Anchor, <<_:256>> = CacheNs}}
          when is_binary(Ns), byte_size(Ns) > 0,
               byte_size(Ns) =< ?DIRECTORY_MAX_NAMESPACE_BYTES ->
            Identity = {Ns, Anchor},
            Bytes = cache_persisted_bytes(Root, CacheNs),
            case CacheNs =:= cache_namespace(Identity) andalso
                 cache_dir(Root, CacheNs) =:= Dir of
                true ->
                    case load_checkpoint(Root, Identity, CacheNs,
                                         checkpoint_height(Root, CacheNs)) of
                        {ok, Projection} ->
                            Height = checkpoint_height(Root, CacheNs),
                            {ok, #history{identity = Identity,
                                          cache_ns = CacheNs,
                                          height = Height, bytes = Bytes,
                                          projection = Projection,
                                          last_used = 0}};
                        _ -> error
                    end;
                false -> error
            end;
        _ -> error
    end.

cleanup_cache_temps(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            _ = [file:delete(filename:join(Dir, Name))
                 || Name <- Names, is_cache_temp(Name)],
            ok;
        {error, _} -> ok
    end.

is_cache_temp(Name) when is_list(Name) ->
    lists:prefix(?MANIFEST ++ ".new.", Name) orelse
        lists:prefix(?CHECKPOINT ++ ".new.", Name).

remove_cache_path(Path) ->
    case file:del_dir_r(Path) of
        ok -> ok;
        {error, enotdir} ->
            case file:delete(Path) of
                ok -> ok;
                {error, enoent} -> ok;
                {error, _} = Error -> Error
            end;
        {error, enoent} -> ok;
        {error, _} = Error -> Error
    end.

checkpoint_height(Root, CacheNs) ->
    case read_small_term(checkpoint_path(Root, CacheNs)) of
        {ok, {quod_foreign_log_checkpoint, ?CACHE_VERSION,
              _Ns, _Anchor, Height, _Bytes, _Projection}}
          when is_integer(Height), Height >= 0 -> Height;
        _ -> -1
    end.

%%%===================================================================
%%% Shared bounded-shape checks and ref accessors
%%%===================================================================

valid_projection(
  #{committee := Committee, validator_routes := Routes,
    committee_id := CommitteeId,
    admissions := Admissions, sequences := Sequences,
    dtx := Dtx, dtx_lanes := DtxLanes} = Projection,
  ExpectedIdentity)
  when is_map(Routes), is_map(Admissions), is_map(Sequences),
       is_map(DtxLanes),
       map_size(Routes) =< ?MAX_VALIDATORS,
       map_size(Admissions) =< ?MAX_VALIDATORS,
       map_size(Sequences) =< ?MAX_VALIDATORS,
       map_size(DtxLanes) =< ?MAX_VALIDATORS ->
    bounded_committee(Committee, 0) andalso
        valid_validator_routes(Routes, Committee) andalso
        (CommitteeId =:= undefined orelse
         (is_binary(CommitteeId) andalso byte_size(CommitteeId) =:= 32)) andalso
        valid_dtx_target(Dtx, ExpectedIdentity) andalso
        map_size(Projection) =:= 11;
valid_projection(_, _) -> false.

valid_validator_routes(Routes, Committee) ->
    maps:fold(
      fun(<<_:256>> = Key, Endpoint, Valid) ->
              Valid andalso lists:member(Key, Committee) andalso
                  quod_quic:valid_endpoint(Endpoint);
         (_Key, _Endpoint, _Valid) ->
              false
      end, true, Routes).

bounded_committee([], _Count) -> true;
bounded_committee([<<_:256>> | Rest], Count) when Count < ?MAX_VALIDATORS ->
    bounded_committee(Rest, Count + 1);
bounded_committee(_, _Count) -> false.

valid_dtx_target(
  #{target := Identity, generation := Generation}, Identity)
  when is_integer(Generation), Generation >= 0,
       Generation =< ?MAX_UINT64 -> true;
valid_dtx_target(_, _) -> false.

ref_identity(
  {quod_dtx_ref, 2, Ns, Anchor, _Slot, _BlockHash, _Digest, _Proof}) ->
    {Ns, Anchor};
ref_identity(_) -> invalid.

ref_slot({quod_dtx_ref, 2, _Ns, _Anchor, Slot, _BlockHash, _Digest, _Proof}) ->
    Slot.

ref_block_hash(
  {quod_dtx_ref, 2, _Ns, _Anchor, _Slot, BlockHash, _Digest, _Proof}) ->
    BlockHash.

ref_record_digest(
  {quod_dtx_ref, 2, _Ns, _Anchor, _Slot, _BlockHash, Digest, _Proof}) ->
    Digest.
