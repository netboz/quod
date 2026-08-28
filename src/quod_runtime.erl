-module(quod_runtime).
-moduledoc """
Per-namespace runtime projection orchestrator — the P tier of `doc/agent-fipa-plan.md` §4.2/§7/§8.

D (the committed KB) is the truth; P is this node's *derived working state*, rebuilt from D by
**state handlers** declared as ordinary stored facts:

    state_handler(Id, WatchedPatterns, Needs, ConvergeGoal)

One recipe per handler: `ConvergeGoal` converges the handler's piece of P from the current
snapshot. The SAME goal runs everywhere, distinguished only by the appended scope argument:
`all` at reconcile, `{keys, ChangedHeads}` after a live change — where `ChangedHeads` are the
full head terms of the requested diff INCLUDING retracted heads (so "nothing in the snapshot
for key K ⇒ delete P[K]" is expressible). This is a conservative invalidation hint: a
requested no-op may cause a harmless reread. The reaction slice separately carries the
canonical reducer's `applied_ops`. A join-shaped handler whose keys don't align with the
changed heads may legitimately treat the hint as `all`. `Needs` is a list of
`current(OtherId)` terms ordering handlers after their prerequisites (the onia/bbsvx
action-pattern shape, hand-rolled); this slice restricts Needs to exactly those ground
`current/1` edges so the whole graph is validated statically at reconcile — a cycle or
missing dependency fails loudly up front, never mid-run.

The same reconciliation owns the local ontology-subscription catalogue. An
ordinary stored `subscribes(TargetNamespace, TargetAnchor)` fact contributes
one anchored target identity. A founding-authorized `react_on/3` whose Pattern
is source-qualified with `from(TargetNamespace, TargetAnchor, EventPattern)`
contributes one event interest for that identity. The first `react_on/3`
argument is instead the logical owner of the resulting effect; it is not an
agent type or an event-source selector. Any ontology-defined callable owner
term is valid when the event pattern binds all of its variables.

Each durable subscription now owns one local consumer reference into the
node-wide `quod_foreign_log` follower. Multiple hosted ontologies following
the same anchored target share its certified cache and one fact projection;
this runtime retains only building/ready/unreachable state and the correlated
projection revision. It starts no verifier, cache, or second worker pool.
Local and subscribed reactions are dispatched from the canonical reducer's
`applied_ops`. Candidate indexes narrow by outer event functor (and exact
source identity for subscribed events), but the actual match, executor
resolution, and bound Handler continuation cross into Prolog through
`erlog_int:unify_prove_body`; this runtime has no parallel unifier or binding
representation. Initial foreign attachment, rebuild and resnapshot establish
state only; only later contiguous certified advances enter the ordered tier.

## Who may declare a handler

Runtime declarations are executable — permission to write their facts must not
be enough to activate them. Until the
`can_declare_runtime` authorization lands, a declaration is **active only if its complete
GROUND term is identical to one in the ontology's founding (slot-1) block**. This
full-term founding match is currently the declaration-execution lock; ordinary
`can_invoke/4` still governs the write itself but does not grant code-execution
authority.
Consequences: later-written declarations are recorded but refused (counted, warned); a
*retracted* founding declaration (`G∖K`) is a loud, distinct unhealthy — the runtime never
runs handlers the KB no longer contains; a founding declaration containing a variable is
refused loudly (a nonground term cannot round-trip through the KB as the same term).

## The ordered tier (live events)

Each live block's transactions arrive as direct `{applied_live, Env, Est}` envelopes carrying
the block-final snapshot. They queue in height order (bounded; overflow collapses the queue
into one reconciliation) and drain in batches through the single killable runner. Per block,
the changed heads first select the watching state handlers via the functor index; those handlers
AND their transitive dependents are re-converged, in the global converge order — prerequisites
first regardless of Id term order — each with
its own watched subset of the changed heads as scope (`all` when a chained-in dependent
watches none of them). The same runner then preserves transaction and operation
order while matching canonical applied fact events against active local
`react_on/3` declarations. When the batch completes through height H,
`p_height = e_frontier = H` — the namespace-wide P-before-E barrier the effect
layer reads.

## Failure model

A founding configuration error (cycle / missing dependency / retracted or nonground
declaration / unreadable founding block) is a **permanent** unhealthy. An execution failure
(handler failed/staged D/budget kill, in either the tier or a reconcile) COLLAPSES pending
work into one reconciliation at the newest snapshot: kill the runner, drop the queue
(counted), clear P bookkeeping, re-attach, reconcile. Repeated consecutive execution
failures back off exponentially and, after 5, crash the server deliberately so the
supervisor path runs — the backoff spacing keeps that from ever tripping `quod_ns`'s
restart intensity. A ready edge arriving mid-reconcile is retried immediately after it —
including after a FAILED reconcile, where the newer edge is exactly the retry needed.

After the tier completes a batch, the floor is raised to the processed height (nothing
below is needed any more), so KB history never accumulates behind an idle pin. At a replay
edge the runtime kills and reaps every snapshot reader before detaching the Prolog pin;
history is then free to prune throughout the replay without invalidating an active reader.

Supervised LAST in `m:quod_ns`'s `rest_for_one` chain: any restart of `quod_prolog` (or a
later sibling) restarts this runtime, whose re-attach then re-pins against the fresh KB —
closing the one-way attach monitor — while a runtime crash restarts nothing else.

Settled observers use the same lifecycle: a verified contiguous feed block is a live event;
an anti-entropy gap is one replay interval followed by reconciliation. Validators and
observers therefore maintain current P without reconstructing best-effort effects from gaps.
""".

-behaviour(gen_server).

-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").

-export([start_link/2, stats/1, effect_frontier/1,
         enqueue_heavy/4, revision/2, await_revision/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_continue/2, handle_info/2,
         terminate/2]).
-ifdef(TEST).
%% the pure planning + handler-selection core — driven directly by eunit
-export([plan_handlers/2, founding_heads/1, with_scope/2, event_plan/4,
         test_read_founding/2, plan_runtime_catalog/2, alpha_normalize/1,
         test_run_events/6]).
-endif.

-define(RECONCILE_BUDGET_MS, 30000).
-define(EVENT_BUDGET_MS, 1000).
-define(EVENT_BUDGET_CAP_MS, 60000).      %% ceiling on a whole batch's runner budget
-define(HEAVY_BUDGET_MS, 30000).
-define(MAX_EXEC_FAILURES, 5).            %% then crash deliberately: the supervisor path runs
-define(DEFAULT_MAX_QUEUED_EVENTS, 1024). %% >= 4 max-size blocks of per-tx envelopes
-define(DEFAULT_MAX_HEAVY_WORKERS, 8).    %% global concurrent resource-worker cap
-define(DEFAULT_MAX_HEAVY_PENDING, 1024). %% distinct queued resources, coalescing included
-define(DEFAULT_MAX_HEAVY_JOB_BYTES, 65536).

%% raw declaration fields — UNVALIDATED wire/KB terms until validate/2 has passed them
-record(handler, {id :: term(),
                  watch :: term(),
                  needs :: term(),
                  goal :: term()}).

-record(s, {ns :: binary(),
            config :: map(),
            mode = booting :: booting | {replaying, term()} | {reconciling, term()}
                            | live | {unhealthy, term()},
            est = undefined :: tuple() | undefined,   %% attached snapshot handle
            height = 0 :: non_neg_integer(),          %% its height (the reconcile floor)
            handlers = #{} :: #{term() => #handler{}},
            order = [] :: [term()],                   %% converge order (deps first)
            index = #{} :: #{tuple() => [term()]},    %% changed-head functor => state-handler ids
            dependents = #{} :: #{term() => [term()]},%% Id => ids that Need it (reverse edges)
            %% Cached slot-1 declarations. Reactions retain exact compiled
            %% clauses because their intentional variables require
            %% alpha-normalized full-clause authority checks.
            founding = unknown :: unknown | {ok, map()},
            subscriptions = [] :: [{binary(), binary()}],
            reactions = [] :: [tuple()],
            reaction_index = #{} :: #{tuple() => [tuple()]},
            source_interests = #{} ::
                #{{binary(), binary()} => #{tuple() => [tuple()]}},
            %% One local consumer reference per exact durable subscription.
            %% Verification, cache and materialized P remain shared node-wide.
            source_views = #{} :: #{{binary(), binary()} => map()},
            %% One message-driven attachment queue. It yields after every
            %% local owner call and is repopulated only by catalogue change or
            %% the foreign owner's gproc registration edge: no timer, batch
            %% cap, or retry ladder.
            source_attach_queue = [] :: [{binary(), binary()}],
            source_attach_token = none :: none | reference(),
            source_attempts = 0 :: non_neg_integer(),
            foreign_log_monitor = none :: none | reference(),
            %% ONE killable runner at a time — a reconcile or an ordered-tier event batch
            runner = none :: none | {reconcile | events, pid(), reference(), reference(),
                                     reference()},
            pending_edge = none :: none | term(),     %% a ready edge that arrived mid-reconcile
            last_recovery = undefined :: term(),      %% dedup: reconcile once per edge id
            %% The one ordered tier carries local apply envelopes and subscribed
            %% certified advances in arrival order. Local entries converge P
            %% before dispatch; remote entries enter the same reaction helper.
            queue = [] :: [tuple()],                  %% REVERSED work items
            queue_len = 0 :: non_neg_integer(),
            %% Follow acknowledgements owned by the current event runner. They
            %% are released on success, collapse, replay, or termination, so a
            %% dead handler can never wedge the shared follower.
            event_acks = [] :: [{reference(), reference()}],
            p_height = 0 :: non_neg_integer(),        %% ordered tier completed through here
            e_frontier = 0 :: non_neg_integer(),      %% the P-before-E barrier (Slice 3 E reads)
            exec_failures = 0 :: non_neg_integer(),   %% consecutive execution failures (backoff)
            reconciles = 0 :: non_neg_integer(),
            reconcile_failures = 0 :: non_neg_integer(),
            collapses = 0 :: non_neg_integer(),       %% queue overflows + execution collapses
            dropped_events = 0 :: non_neg_integer(),
            rejected_dynamic = 0 :: non_neg_integer(),
            rejected_subscriptions = 0 :: non_neg_integer(),
            events_seen = 0 :: non_neg_integer(),     %% direct applied_live received
            reaction_candidates = 0 :: non_neg_integer(),
            reaction_matches = 0 :: non_neg_integer(),
            reactions_executed = 0 :: non_neg_integer(),
            reaction_inert = 0 :: non_neg_integer(),
            reaction_failures = 0 :: non_neg_integer(),
            %% heavy-worker framework (§8): queue-fed per-resource workers OUTSIDE the
            %% ordered pipeline. One COALESCED pending slot per resource (jobs are
            %% full-rebuild-idempotent in this slice, so a newer job supersedes a queued one);
            %% workers run against the NEWEST attached snapshot (converging to at-least-Rev),
            %% so only RUNNING workers pin history (at their captured est height).
            heavy_pending = #{} :: #{term() => {non_neg_integer(), term()}},  %% Res => {Rev, Job}
            heavy_order = [] :: [term()],                    %% FIFO distinct-resource order
            heavy_running = #{} :: #{term() => {pid(), reference(), reference(),
                                                reference(), non_neg_integer(), non_neg_integer()}},
                                   %% Res => {Pid, MRef, TRef, JobRef, Rev, EstHeight}
            revisions = #{} :: #{term() => non_neg_integer()},   %% Res => installed rev
            blocked_revisions = #{} :: #{term() => non_neg_integer()},
            waiters = #{} :: #{reference() => {gen_server:from(), term(), non_neg_integer(),
                                               reference()}},    %% WRef => {From,Res,Rev,TRef}
            superseded = 0 :: non_neg_integer(),
            heavy_rejected = 0 :: non_neg_integer(),
            heavy_failures = 0 :: non_neg_integer()}).   %% heavy jobs that failed (isolated)

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(binary(), map()) -> {ok, pid()} | {error, term()}.
start_link(Ns, Config) ->
    gen_server:start_link(quod_reg:via({quod_runtime, Ns}), ?MODULE, {Ns, Config}, []).

-doc "Operational counters + mode for `m:quod_metrics` and tests.".
-spec stats(binary()) -> map().
stats(Ns) ->
    try gen_server:call(quod_reg:via({quod_runtime, Ns}), get_stats, 1000)
    catch _:_ -> #{} end.

-doc "Return the ordered P-before-E frontier used to release direct effects.".
-spec effect_frontier(binary()) -> {ok, non_neg_integer()} | {error, unavailable}.
effect_frontier(Ns) when is_binary(Ns), byte_size(Ns) > 0 ->
    case quod_reg:where({quod_runtime, Ns}) of
        undefined -> {error, unavailable};
        Pid ->
            try gen_server:call(Pid, effect_frontier, 1000)
            catch exit:_ -> {error, unavailable}
            end
    end;
effect_frontier(_Ns) ->
    {error, unavailable}.

-doc """
Queue heavy work for `Resource` at requested revision `Rev` (the enqueueing event's height).
Called synchronously by the `enqueue_projection/2` bridge so queue/size backpressure is loud:
the runtime coalesces a newer job for one resource, bounds distinct pending resources, and
bounds the encoded job size before retaining it.
""".
-spec enqueue_heavy(binary(), term(), non_neg_integer(), term()) ->
          ok | {error, overloaded | oversized | unavailable}.
enqueue_heavy(Ns, Resource, Rev, Job) ->
    try gen_server:call(quod_reg:via({quod_runtime, Ns}),
                        {heavy_enqueue, Resource, Rev, Job}, 5000)
    catch exit:_ -> {error, unavailable} end.

-doc "The installed revision for `Resource` (0 before any job completed).".
-spec revision(binary(), term()) -> non_neg_integer().
revision(Ns, Resource) ->
    try gen_server:call(quod_reg:via({quod_runtime, Ns}), {revision, Resource}, 1000)
    catch _:_ -> 0 end.

-doc """
Block until `Resource`'s installed revision reaches `Rev` — the per-resource release gate a
heavy-dependent effect uses instead of the namespace-wide P-before-E frontier. Returns
`{error, unhealthy}` when the runtime is permanently unhealthy (the revision can no longer
install), `{error, timeout}` after `TimeoutMs`.
""".
-spec await_revision(binary(), term(), non_neg_integer(), pos_integer()) ->
          ok | {error, timeout | unhealthy}.
await_revision(Ns, Resource, Rev, TimeoutMs) ->
    try gen_server:call(quod_reg:via({quod_runtime, Ns}),
                        {await_revision, Resource, Rev, TimeoutMs}, infinity)
    catch exit:_ -> {error, unhealthy} end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init({Ns, Config}) ->
    %% Subscribe BEFORE the (deferred) attach attempt: any ready edge published after the
    %% attach answer lands in our mailbox, so the boot race has no window.
    true = quod_reg:subscribe({runtime, Ns}),
    {ok, #s{ns = Ns, config = Config}, {continue, try_attach}}.

%% The restart-while-ready case: a runtime-only restart sees no ready edge (the KB is already
%% live), so probe once here. `infinity` deliberately — a bounded call into a replay-flooded
%% KB would time out and crash-loop the supervisor tail (the DA-H5 hazard); the KB answers
%% `not_ready` cheaply once the call is served, and the ready edge does the rest.
handle_continue(try_attach, S = #s{mode = booting}) ->
    case safe_attach(S#s.ns) of
        {ok, Est, H}       -> {noreply, start_reconcile(boot, Est, H, S)};
        {error, not_ready} -> {noreply, S}
    end;
handle_continue(try_attach, S) ->
    {noreply, S}.

handle_call(get_stats, _From, S) ->
    {reply, #{mode => mode_tag(S#s.mode), height => S#s.height,
              handlers_active => map_size(S#s.handlers),
              subscriptions_active => length(S#s.subscriptions),
              reactions_active => length(S#s.reactions),
              source_targets_active => map_size(S#s.source_interests),
              source_interests_active =>
                  lists:sum(
                    [lists:sum([length(Is) || Is <- maps:values(Index)])
                     || Index <- maps:values(S#s.source_interests)]),
              source_views_active => map_size(S#s.source_views),
              source_views_ready => source_state_count(ready, S#s.source_views),
              source_views_building => source_state_count(building, S#s.source_views),
              source_views_unreachable =>
                  source_state_count(unreachable, S#s.source_views),
              source_attach_queued => length(S#s.source_attach_queue),
              source_attempts => S#s.source_attempts,
              p_height => S#s.p_height, e_frontier => S#s.e_frontier,
              queue_len => S#s.queue_len,
              reconciles => S#s.reconciles,
              reconcile_failures => S#s.reconcile_failures,
              collapses => S#s.collapses,
              dropped_events => S#s.dropped_events,
              rejected_dynamic => S#s.rejected_dynamic,
              rejected_subscriptions => S#s.rejected_subscriptions,
              events_seen => S#s.events_seen,
              reaction_candidates => S#s.reaction_candidates,
              reaction_matches => S#s.reaction_matches,
              reactions_executed => S#s.reactions_executed,
              reaction_inert => S#s.reaction_inert,
              reaction_failures => S#s.reaction_failures,
              heavy_pending => map_size(S#s.heavy_pending),
              heavy_running => map_size(S#s.heavy_running),
              heavy_superseded => S#s.superseded,
              heavy_rejected => S#s.heavy_rejected,
              heavy_failures => S#s.heavy_failures,
              waiters => map_size(S#s.waiters)}, S};
handle_call(effect_frontier, _From, S) ->
    {reply, {ok, S#s.e_frontier}, S};
handle_call({revision, Resource}, _From, S) ->
    {reply, effective_revision(Resource, S), S};
handle_call({await_revision, Resource, Rev, TimeoutMs}, From, S) ->
    case effective_revision(Resource, S) >= Rev of
        true  -> {reply, ok, S};
        false ->
            case S#s.mode of
                {unhealthy, R} ->
                    case config_error(R) of
                        %% permanent: the revision can never install
                        true  -> {reply, {error, unhealthy}, S};
                        %% transient collapse/backoff: the retry reconcile re-enqueues
                        false -> {noreply, park_waiter(From, Resource, Rev, TimeoutMs, S)}
                    end;
                _ ->
                    {noreply, park_waiter(From, Resource, Rev, TimeoutMs, S)}
            end
    end;
handle_call({heavy_enqueue, Resource, Rev, Job}, From, S = #s{mode = live}) ->
    handle_heavy_enqueue(Resource, Rev, Job, From, S);
handle_call({heavy_enqueue, Resource, Rev, Job}, From,
            S = #s{mode = {reconciling, _Id}}) ->
    handle_heavy_enqueue(Resource, Rev, Job, From, S);
handle_call({heavy_enqueue, _Resource, _Rev, _Job}, _From, S) ->
    {reply, {error, unavailable}, S};
handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.

handle_heavy_enqueue(Resource, Rev, Job, _From, S) ->
    case validate_heavy_enqueue(Resource, Job, S) of
        ok ->
            case queue_heavy(Resource, Rev, Job, S) of
                {ok, S1} -> {reply, ok, pump_heavy(S1)};
                full -> {reply, {error, overloaded},
                         S#s{heavy_rejected = S#s.heavy_rejected + 1}}
            end;
        oversized ->
            {reply, {error, oversized}, S#s{heavy_rejected = S#s.heavy_rejected + 1}}
    end.

handle_cast({runner_done, Ref, Outcome}, S = #s{runner = {Kind, _Pid, MRef, Ref, TRef}}) ->
    _ = erlang:cancel_timer(TRef),
    erlang:demonitor(MRef, [flush]),
    S1 = S#s{runner = none},
    case Kind of
        reconcile -> {noreply, reconcile_finished(Outcome, S1)};
        events    -> {noreply, events_finished(Outcome, S1)}
    end;
handle_cast({runner_done, _StaleRef, _Outcome}, S) ->
    {noreply, S};
handle_cast({heavy_done, Resource, Ref, Outcome}, S) ->
    case maps:get(Resource, S#s.heavy_running, undefined) of
        {_Pid, MRef, TRef, Ref, _Rev, EstH} ->
            _ = erlang:cancel_timer(TRef),
            erlang:demonitor(MRef, [flush]),
            S1 = S#s{heavy_running = maps:remove(Resource, S#s.heavy_running)},
            case Outcome of
                ok ->
                    %% A full-rebuild job reads EstH, so its installed output is current through
                    %% that captured height, not merely through the older trigger revision.
                    NewRev = max(maps:get(Resource, S1#s.revisions, 0), EstH),
                    Blocked1 = clear_blocked(Resource, NewRev, S1#s.blocked_revisions),
                    S2 = release_ready_waiters(
                           S1#s{revisions = (S1#s.revisions)#{Resource => NewRev},
                                blocked_revisions = Blocked1}),
                    %% floor may lift now that this worker's snapshot is released
                    {noreply, floor_raise(pump_heavy(S2))};
                {error, Reason} ->
                    {noreply, heavy_failed(Resource, Reason, S1)}
            end;
        _ ->
            {noreply, S}   %% stale report from a killed/superseded worker
    end;
handle_cast(_Msg, S) -> {noreply, S}.

%% A ready edge: the KB finished a rebuild (Id = RecoveryId, or `boot` for the quiet first
%% ready transition). Reconcile exactly once per edge; a `boot` edge counts only while booting.
handle_info({replay_ready, boot, _H}, S = #s{mode = booting}) ->
    {noreply, replace_snapshot_and_reconcile(boot, S)};
handle_info({replay_ready, boot, _H}, S) ->
    {noreply, S};
handle_info({replay_ready, Id, _H}, S = #s{last_recovery = Id}) ->
    {noreply, S};
handle_info({replay_ready, Id, _H}, S = #s{runner = {_, _, _, _, _}}) ->
    {noreply, S#s{pending_edge = Id}};
handle_info({replay_ready, Id, _H}, S) ->
    {noreply, replace_snapshot_and_reconcile(Id, S)};
handle_info({replay_started, Id, _From}, S = #s{mode = {replaying, Id}}) ->
    {noreply, S};
handle_info({replay_started, Id, _From}, S) ->
    %% Stop every old-snapshot reader. Keep their monitors until DOWN and only then tell
    %% quod_prolog to release the MVCC pin; queued state is covered by the ready reconciliation.
    {noreply, begin_replay(Id, S)};
handle_info(
  {quod_foreign_follow, FollowRef, NoticeRef, Identity, Notice}, S0) ->
    {noreply, handle_source_notice(
                FollowRef, NoticeRef, Identity, Notice, S0)};
handle_info({source_follow_attach, Token},
            S0 = #s{source_attach_token = Token}) ->
    {noreply,
     run_source_attach(S0#s{source_attach_token = none})};
handle_info({source_follow_attach, _StaleToken}, S) ->
    {noreply, S};
handle_info(
  {gproc, registered, MRef, _Name},
  S = #s{foreign_log_monitor = MRef}) ->
    {noreply, queue_waiting_source_views(S)};
handle_info(
  {gproc, unreg, MRef, _Name},
  S = #s{foreign_log_monitor = MRef}) ->
    {noreply, foreign_log_down(S)};
%% The direct post-commit envelope (est-carrying): the ordered tier's input. Enqueue in
%% arrival (= height) order; overflow collapses to one reconciliation at the newest snapshot.
handle_info({applied_live, Env, Est}, S0 = #s{mode = live}) ->
    S = S0#s{events_seen = S0#s.events_seen + 1},
    case S#s.queue_len >= max_queued_events(S) of
        true ->
            {noreply, overflow_collapse(S)};
        false ->
            S1 = S#s{queue = [{local, Env, Est} | S#s.queue],
                      queue_len = S#s.queue_len + 1},
            {noreply, maybe_run_events(S1)}
    end;
handle_info({applied_live, Env, Est}, S = #s{mode = {reconciling, _}}) ->
    %% committed after the reconcile snapshot was taken: drain (or drop as stale) afterwards.
    %% Overflow: the dropped events' state is NOT in the running reconcile's snapshot, so a
    %% follow-up reconciliation must be queued — unless a real ready edge is already parked
    %% (it reconciles at an even newer snapshot, superseding ours).
    S1 = S#s{events_seen = S#s.events_seen + 1},
    case S1#s.queue_len >= max_queued_events(S1) of
        true ->
            Pending = case S1#s.pending_edge of
                          none -> {collapse, make_ref()};
                          Id   -> Id
                      end,
            {noreply, drop_queue(S1#s{pending_edge = Pending,
                                      collapses = S1#s.collapses + 1})};
        false ->
            {noreply, S1#s{queue = [{local, Env, Est} | S1#s.queue],
                           queue_len = S1#s.queue_len + 1}}
    end;
handle_info({applied_live, _Env, _Est}, S) ->
    %% booting/replaying/unhealthy: the next reconcile rebuilds from a newer snapshot anyway
    {noreply, S#s{events_seen = S#s.events_seen + 1,
                  dropped_events = S#s.dropped_events + 1}};
%% Property copies (est-free applied/rejected): the explorer's feed, not ours — the direct
%% 3-tuple above is our only event channel (the double-delivery contract).
handle_info({applied_live, _Env}, S) -> {noreply, S};
handle_info({rejected_live, _Env}, S) -> {noreply, S};
handle_info({'DOWN', MRef, process, Pid, Reason},
            S = #s{runner = {Kind, Pid, MRef, _Ref, TRef}}) ->
    %% runner died without reporting (crash or budget kill)
    _ = erlang:cancel_timer(TRef),
    S1 = S#s{runner = none},
    case Kind of
        reconcile -> {noreply, reconcile_finished({error, {runner_down, Reason}}, S1)};
        events    -> {noreply, events_finished({error, {runner_down, Reason}}, S1)}
    end;
handle_info({runner_kill, Ref}, S = #s{runner = {_Kind, Pid, _MRef, Ref, _TRef}}) ->
    exit(Pid, kill),   %% the DOWN above reports the failure
    {noreply, S};
%% a heavy worker died without reporting (crash or budget kill)
handle_info({'DOWN', MRef, process, Pid, Reason}, S = #s{heavy_running = Running})
        when map_size(Running) > 0 ->
    case [{Res, T} || {Res, {P, M, _, _, _, _} = T} <- maps:to_list(Running),
                      P =:= Pid, M =:= MRef] of
        [{Resource, {_P, _M, TRef, _Ref, _Rev, _EstH}}] ->
            _ = erlang:cancel_timer(TRef),
            S1 = S#s{heavy_running = maps:remove(Resource, Running)},
            {noreply, heavy_failed(Resource, {worker_down, Reason}, S1)};
        [] ->
            handle_info_rest({'DOWN', MRef, process, Pid, Reason}, S)
    end;
handle_info({heavy_kill, Resource, Ref}, S) ->
    case maps:get(Resource, S#s.heavy_running, undefined) of
        {Pid, _M, _T, Ref, _Rev, _EstH} -> exit(Pid, kill);   %% the DOWN reports it
        _                               -> ok
    end,
    {noreply, S};
handle_info({waiter_timeout, WRef}, S = #s{waiters = Waiters}) ->
    case maps:take(WRef, Waiters) of
        {{From, _Res, _Rev, _TRef}, Rest} ->
            gen_server:reply(From, {error, timeout}),
            {noreply, S#s{waiters = Rest}};
        error ->
            {noreply, S}
    end;
handle_info({collapse_retry, Ref}, S = #s{last_recovery = {collapse, Ref}}) ->
    {noreply, attach_and_reconcile({collapse, make_ref()}, S)};
handle_info(_Info, S) -> {noreply, S}.

%% A dying server must not orphan its workers: unmonitored+unbudgeted (the kill timers die
%% with us), an orphan executing a looping goal would burn a scheduler unbounded while its
%% snapshot pin is released out from under it.
terminate(_Reason, S) ->
    _ = stop_source_views(kill_runner(S)), ok.

%%%===================================================================
%%% reconciliation
%%%===================================================================

attach_and_reconcile(Id, S) ->
    case safe_attach(S#s.ns) of
        {ok, Est, H} ->
            start_reconcile(Id, Est, H, S);
        {error, not_ready} ->
            %% raced a new rebuild — we are again awaiting a ready edge, and its arrival
            %% (clauses above) will retry; reflect that instead of a stale mode
            S#s{mode = booting}
    end.

%% A ready edge replaces the snapshot generation. Quiesce every reader first,
%% including heavy workers: replay_started normally does this earlier, but the
%% ready boundary is independently safe if a start notification was delayed or
%% lost. Awaiting every DOWN before attach prevents the new MVCC pin from
%% invalidating an old worker's view.
replace_snapshot_and_reconcile(Id, S) ->
    attach_and_reconcile(
      Id, (kill_runner(S))#s{pending_edge = none}).

%% attach_runtime is a call into a sibling that may be crashing/restarting right now; that
%% is indistinguishable from "not ready" for our purposes, and crashing here would burn
%% supervisor restart intensity for nothing (rest_for_one restarts us with the KB anyway).
safe_attach(Ns) ->
    try quod_prolog:attach_runtime(Ns)
    catch exit:_ -> {error, not_ready}
    end.

%% The WHOLE pipeline — founding read, snapshot findall, gate, validation, converge runs —
%% executes in the killable runner: everything after the attach is bounded by the budget, so
%% writer-controlled declaration volume can never stall this server. Queued envelopes are
%% NOT dropped here: those above the snapshot height still carry fresh state (drained after).
start_reconcile(Id, Est, H, S0 = #s{ns = Ns, config = Config, founding = Cached}) ->
    S = S0#s{est = Est, height = H, last_recovery = Id, pending_edge = none,
             mode = {reconciling, Id}},
    Budget = application:get_env(quod, runtime_reconcile_budget_ms, ?RECONCILE_BUDGET_MS),
    spawn_runner(reconcile, Budget,
                 fun() -> run_reconcile(Ns, Config, Cached, Est, H) end, S).

spawn_runner(Kind, Budget, Fun, S) ->
    Server = self(),
    Ref = make_ref(),
    {Pid, MRef} = spawn_monitor(fun() ->
                                        gen_server:cast(Server, {runner_done, Ref, Fun()})
                                end),
    TRef = erlang:send_after(Budget, self(), {runner_kill, Ref}),
    S#s{runner = {Kind, Pid, MRef, Ref, TRef}}.

%% Runner body (reconcile). Returns {ok, FoundingCache, Plan} | {error, Reason}.
run_reconcile(Ns, Config, Cached, Est, H) ->
    try
        {FoundingCache, Founding} =
            case Cached of
                {ok, Fc} -> {keep, Fc};
                unknown  ->
                    case read_founding(Ns, Config) of
                        {ok, Fr}     -> {{cache, Fr}, Fr};
                        no_log       -> {keep, empty_founding()};
                        {error, R0}  -> throw({founding_read_failed, R0})
                    end
            end,
        Stored = case stored_declarations(Est) of
                     {ok, K}         -> K;
                     {error, R1}     -> throw({discovery_failed, R1})
                 end,
        StoredCatalog = case stored_runtime_catalog(Est) of
                            {ok, C}         -> C;
                            {error, R2}     -> throw({discovery_failed, R2})
                        end,
        case plan_runtime(Est, Founding, Stored, StoredCatalog) of
            {ok, Plan = #{handlers := Hs, order := Order}} ->
                lists:foreach(fun(Id) ->
                                      #handler{goal = Goal} = maps:get(Id, Hs),
                                      converge(Ns, Est, H, Id, Goal, all)
                              end, Order),
                {ok, FoundingCache, Plan};
            {error, R3} ->
                throw(R3)
        end
    catch throw:R -> {error, R}
    end.

reconcile_finished({ok, FoundingCache,
                    Plan = #{handlers := Hs, order := Order, index := Index,
                             dependents := Dependents}},
                    S0 = #s{height = H}) ->
    Base = S0#s{handlers = Hs, order = Order, index = Index, dependents = Dependents,
                founding = case FoundingCache of
                               {cache, F} -> {ok, F};
                               keep       -> S0#s.founding
                           end,
                p_height = H, e_frontier = H,
                reconciles = S0#s.reconciles + 1,
                exec_failures = 0},
    S1 = install_catalog_update(Plan, Base),
    _ = reconcile_direct_effects(),
    case S1#s.pending_edge of
        none -> maybe_run_events(drop_stale_queue(
                                   pump_heavy(release_ready_waiters(S1#s{mode = live}))));
        Id   -> replace_snapshot_and_reconcile(Id, S1)
    end;
reconcile_finished({error, Reason}, S0 = #s{ns = Ns}) ->
    S1 = S0#s{reconcile_failures = S0#s.reconcile_failures + 1},
    case S1#s.pending_edge of
        none ->
            case config_error(Reason) of
                true  -> unhealthy(Reason, S1);
                false -> execution_failure({reconcile_failed, Reason}, S1)
            end;
        Id ->
            %% a newer ready edge arrived mid-run: its fresh state is the retry we would
            %% otherwise wait for — use it now instead of parking unhealthy
            logger:warning("quod_runtime[~s]: reconcile failed (~0p); retrying with the "
                           "newer ready edge", [Ns, Reason]),
            replace_snapshot_and_reconcile(Id, S1)
    end.

reconcile_direct_effects() ->
    quod_effect_journal:reconcile().

%% Founding configuration errors are permanent (only new founding content or a code fix can
%% change them); execution failures are transient and go through collapse + backoff.
config_error({missing_founding, _})     -> true;
config_error({nonground_founding, _})   -> true;
config_error({duplicate_handler_id, _}) -> true;
config_error({invalid_declaration, _})  -> true;
config_error({invalid_founding_reaction, _}) -> true;
config_error({missing_founding_reaction, _}) -> true;
config_error(invalid_runtime_catalog) -> true;
config_error({missing_dependency, _, _})-> true;
config_error({handler_cycle, _})        -> true;
config_error({founding_read_failed, _}) -> true;
config_error(_)                         -> false.

unhealthy(Reason, S = #s{ns = Ns}) ->
    %% PERMANENT (config) unhealthy — no revision can install any more. QUIESCE fully: kill the
    %% tier runner AND every heavy worker + clear their pending (kill_runner), so nothing keeps
    %% installing revisions or pinning snapshots in a terminally-dead runtime, then fail waiters.
    logger:error("quod_runtime[~s]: unhealthy: ~0p", [Ns, Reason]),
    S1 = stop_source_views(kill_runner(S)),
    fail_waiters(drop_queue(S1#s{mode = {unhealthy, Reason}})).

park_waiter(From, Resource, Rev, TimeoutMs, S) ->
    WRef = make_ref(),
    TRef = erlang:send_after(TimeoutMs, self(), {waiter_timeout, WRef}),
    S#s{waiters = (S#s.waiters)#{WRef => {From, Resource, Rev, TRef}}}.

mode_tag(M) when is_atom(M) -> M;
mode_tag(M)                 -> element(1, M).

%%%===================================================================
%%% the ordered tier — live event batches
%%%===================================================================

maybe_run_events(
  S = #s{mode = live, runner = none, queue = Q, handlers = Hs,
         reaction_index = ReactionIndex})
  when Q =/= [] ->
    %% One runner drains both local and certified-remote occurrences. Adjacent
    %% local transactions at one block height still share one convergence;
    %% remote notices retain their per-target certified order.
    Items = lists:reverse(Q),
    Work = coalesce_work_items(Items),
    RefreshCatalog = catalog_changed(Work),
    HasRemote = lists:any(fun is_remote_work/1, Work),
    case {map_size(Hs), map_size(ReactionIndex), RefreshCatalog, HasRemote} of
        {0, 0, false, false} ->
            %% no handlers: the tier is trivially complete through the batch tip
            {Tip, TipEst} = work_tip(Work, S#s.height, S#s.est),
            Effects = work_effects(Work),
            S1 = S#s{queue = [], queue_len = 0, est = TipEst, height = Tip,
                     p_height = Tip, e_frontier = Tip},
            release_direct_effects(Effects),
            floor_raise(pump_heavy(release_ready_waiters(S1)));
        _ ->
            %% budget = one per-event allowance per block, CAPPED — a wedged goal in a huge
            %% batch must not hold the single runner (and the KB floor) for minutes; the cap's
            %% kill collapses to a reconcile, which rebuilds correctly.
            Per = application:get_env(quod, runtime_event_budget_ms, ?EVENT_BUDGET_MS),
            Cap = application:get_env(quod, runtime_event_budget_cap_ms, ?EVENT_BUDGET_CAP_MS),
            Budget = min(max(1, length(Work)) * Per, Cap),
            #s{ns = Ns, config = Config, order = Order, index = Index,
               dependents = Deps, handlers = Handlers,
               reaction_index = Reactions, source_interests = SourceInterests,
               subscriptions = Subscriptions, founding = FoundingCache} = S,
            Founding = case FoundingCache of
                           {ok, F} -> F;
                           unknown -> empty_founding()
                       end,
            Self = maps:get(node_id, Config),
            Acks = event_ack_refs(Items),
            spawn_runner(
              events, Budget,
              fun() -> run_events(
                         Ns, Work, Handlers, Order, Index, Deps,
                         Reactions, SourceInterests,
                         maps:from_keys(Subscriptions, true),
                         Self, Founding, S#s.height, S#s.est)
              end,
              S#s{queue = [], queue_len = 0, event_acks = Acks})
    end;
maybe_run_events(S) ->
    S.

%% One local block retains two deliberately different views of its transactions:
%% requested heads are unioned for state invalidation, while canonical applied
%% operations remain in exact transaction/operation order for reactions.
coalesce_work_items(Batch) ->
    Folded =
        lists:foldl(
          fun({local, Env, Est}, Acc) ->
                  H = maps:get(height, Env, 0),
                  Heads = changed_heads(Env),
                  Events = quod_runtime_predicates:diff_to_events(
                             maps:get(applied_ops, Env, [])),
                  Effects = maps:get(effects, Env, []),
                  case Acc of
                      [{local, H, _E0, H0, O0, E0} | Rest] ->
                          [{local, H, Est, H0 ++ Heads, O0 ++ Events,
                            E0 ++ Effects} | Rest];
                      _ -> [{local, H, Est, Heads, Events, Effects} | Acc]
                  end
             ;({remote, _FollowRef, _NoticeRef, _Identity, _Publications} = Item,
               Acc) ->
                  [Item | Acc]
          end, [], Batch),
    lists:reverse(
      [case Item of
           {local, H, Est, Heads, Events, Effects} ->
               {local, H, Est, lists:usort(Heads), Events, Effects};
           {remote, _, _, _, _} -> Item
       end || Item <- Folded]).

is_remote_work({remote, _, _, _, _}) -> true;
is_remote_work(_) -> false.

work_tip(Work, Height0, Est0) ->
    lists:foldl(
      fun({local, Height, Est, _Heads, _Events, _Effects}, _Acc) ->
              {Height, Est};
         ({remote, _, _, _, _}, Acc) ->
              Acc
      end, {Height0, Est0}, Work).

work_effects(Work) ->
    [{Height, Effects}
     || {local, Height, _Est, _Heads, _Events, Effects} <- Work,
        Effects =/= []].

event_ack_refs(Items) ->
    [{FollowRef, NoticeRef}
     || {remote, FollowRef, NoticeRef, _Identity, _Publications} <- Items].

%% Runner body (event batch): per BLOCK, validate any catalogue change, run the
%% invalidated handlers in converge order, then dispatch canonical reactions.
%% A removed founding reaction is therefore refused before it can run from the
%% same block's other applied operations.
run_events(Ns, Work, Handlers, Order, Index, Deps,
           Reactions, SourceInterests, Subscriptions,
           Self, Founding, Height0, Est0) ->
    try
        {Tip, TipEst, ReactionStats, _FinalReactionIndex,
         _FinalSourceInterests, _FinalSubscriptions, CatalogUpdate} =
            lists:foldl(
              fun({local, H, Est, Heads, Events, _Effects},
                  {_PrevH, _PrevEst, Stats0, Reactions0, Sources0,
                   Subscriptions0, Catalog0}) ->
                      {Reactions1, Sources1, Subscriptions1, Catalog1} =
                          refresh_runtime_catalog(
                            Heads, Est, Founding, Reactions0, Sources0,
                            Subscriptions0, Catalog0),
                      {Run, Scopes} = event_plan(Heads, Index, Order, Deps),
                      lists:foreach(
                        fun(Id) ->
                                #handler{goal = Goal} = maps:get(Id, Handlers),
                                converge(Ns, Est, H, Id, Goal, maps:get(Id, Scopes))
                        end, Run),
                      Stats1 = dispatch_local_reactions(
                                 Ns, H, Est, Self, Events, Reactions1, Stats0),
                      {H, Est, Stats1, Reactions1, Sources1,
                       Subscriptions1, Catalog1};
                 ({remote, _FollowRef, _NoticeRef, Identity, Publications},
                  {H, Est, Stats0, Reactions0, Sources0,
                   Subscriptions0, Catalog0}) ->
                      Stats1 =
                          case maps:is_key(Identity, Subscriptions0) of
                              true ->
                                  dispatch_remote_reactions(
                                    Ns, H, Est, Self, Identity, Publications,
                                    Sources0, Stats0);
                              false ->
                                  reaction_stat(dropped, Stats0)
                          end,
                      {H, Est, Stats1, Reactions0, Sources0,
                       Subscriptions0, Catalog0}
              end,
              {Height0, Est0, empty_reaction_stats(), Reactions,
               SourceInterests, Subscriptions, keep}, Work),
        {ok, Tip, TipEst, work_effects(Work), CatalogUpdate,
         ReactionStats}
    catch throw:R -> {error, R}
    end.

-ifdef(TEST).
%% Drive the real ordered fold without a gen_server race. This is deliberately
%% narrower than run_events/13: tests supply the already-derived catalogue and
%% cannot invent an alternative dispatch path.
test_run_events(Work, Plan, Self, FoundingReactions, Height0, Est0) ->
    run_events(
      <<"runtime:test">>, Work, #{}, [], #{}, #{},
      maps:get(reaction_index, Plan), maps:get(source_interests, Plan),
      maps:from_keys(maps:get(subscriptions, Plan), true), Self,
      #{handlers => [], reactions => FoundingReactions}, Height0, Est0).
-endif.

refresh_runtime_catalog(Heads, Est, Founding, ReactionIndex, SourceInterests,
                        Subscriptions, CatalogUpdate) ->
    case lists:any(fun catalog_head/1, Heads) of
        false ->
            {ReactionIndex, SourceInterests, Subscriptions, CatalogUpdate};
        true ->
            case stored_runtime_catalog(Est) of
                {ok, StoredCatalog} ->
                    case plan_runtime_catalog(
                           maps:get(reactions, Founding, []), StoredCatalog) of
                        {ok, Plan} ->
                            {maps:get(reaction_index, Plan),
                             maps:get(source_interests, Plan),
                             maps:from_keys(
                               maps:get(subscriptions, Plan), true),
                             Plan};
                        {error, Reason} ->
                            throw(Reason)
                    end;
                {error, Reason} ->
                    throw({discovery_failed, Reason})
            end
    end.

empty_reaction_stats() ->
    #{candidates => 0, matches => 0, executed => 0,
      inert => 0, failures => 0, dropped => 0}.

dispatch_local_reactions(_Ns, _Height, _Est, _Self, [], _Index, Stats) ->
    Stats;
dispatch_local_reactions(Ns, Height, Est, Self, [Event | Rest], Index, Stats0) ->
    Candidates = maps:get(functor_key(Event), Index, []),
    Stats1 = dispatch_reaction_candidates(
               Ns, Height, Est, Self, Event, Candidates, Stats0),
    dispatch_local_reactions(Ns, Height, Est, Self, Rest, Index, Stats1).

dispatch_remote_reactions(_Ns, _Height, _Est, _Self, _Identity, [],
                          _SourceInterests, Stats) ->
    Stats;
dispatch_remote_reactions(Ns, Height, Est, Self, Identity,
                          [{_SourceHeight, AppliedOps} | Rest],
                          SourceInterests, Stats0) ->
    Index = maps:get(Identity, SourceInterests, #{}),
    Stats1 = lists:foldl(
               fun(Event, Acc) ->
                       Candidates = maps:get(functor_key(Event), Index, []),
                       dispatch_reaction_candidates(
                         Ns, Height, Est, Self,
                         source_event(Identity, Event), Candidates, Acc)
               end, Stats0,
               quod_runtime_predicates:diff_to_events(AppliedOps)),
    dispatch_remote_reactions(
      Ns, Height, Est, Self, Identity, Rest, SourceInterests, Stats1).

source_event({TargetNs, Anchor}, Event) ->
    {from, TargetNs, Anchor, Event}.

%% Local and subscribed occurrences enter this one continuation. Erlang only
%% narrows the candidate list; unification, executor ownership and Handler
%% execution remain the single Prolog path in quod_runtime_predicates.
dispatch_reaction_candidates(Ns, Height, Est, Self, Event, Candidates, Stats0) ->
    lists:foldl(
      fun(Reaction, Acc0) ->
              Acc1 = reaction_stat(candidates, Acc0),
              Started = erlang:monotonic_time(microsecond),
              Result = quod_runtime_predicates:run_reaction(
                         Ns, Height, Self, Reaction, Event, Est),
              Elapsed = erlang:monotonic_time(microsecond) - Started,
              ok = quod_metrics:observe_runtime_reaction(Ns, Result, Elapsed),
              case Result of
                  unmatched -> Acc1;
                  executed ->
                      reaction_stat(executed, reaction_stat(matches, Acc1));
                  {inert, _Reason} ->
                      reaction_stat(inert, reaction_stat(matches, Acc1));
                  {failed, _Reason} ->
                      reaction_stat(failures, reaction_stat(matches, Acc1))
              end
      end, Stats0, Candidates).

reaction_stat(Key, Stats) ->
    maps:update_with(Key, fun(N) -> N + 1 end, 1, Stats).

catalog_changed(Work) ->
    lists:any(
      fun({local, _H, _Est, Heads, _Events, _Effects}) ->
              lists:any(fun catalog_head/1, Heads);
         ({remote, _, _, _, _}) ->
              false
      end, Work).

catalog_head({subscribes, _, _}) -> true;
catalog_head({react_on, _, _, _}) -> true;
catalog_head(_) -> false.

%% The full dereferenced head terms of the envelope's diff — INCLUDING retracted heads, so
%% per-key convergence can observe removals (nothing in the snapshot for key K ⇒ delete P[K]).
changed_heads(Env) ->
    [Head || {Kind, {Head, _Body}} <- maps:get(diff, Env, []),
             Kind =:= assert orelse Kind =:= retract].

release_direct_effects(HeightEffects) ->
    lists:foreach(
      fun({Height, Effects}) ->
          ok = quod_effect_journal:release_applied(Height, Effects)
      end, HeightEffects),
    ok.

%% Pure: which handlers must run for these changed heads, in what order, with what scope.
%% Matched handlers AND their transitive dependents run (a dependent whose watch didn't fire
%% still reads its prerequisite's P output, so its piece must be re-converged); order is the
%% GLOBAL converge order filtered to the run set — prerequisites first regardless of Id term
%% order. Scope per handler: its own watched subset of the heads, else `all` (a chained-in
%% dependent or a join-shaped handler treats the hint as no narrowing).
event_plan(Heads, Index, Order, Dependents) ->
    Matched = lists:usort(
                lists:append([maps:get(functor_key(H), Index, []) || H <- Heads])),
    Run0 = transitive_closure(Matched, Dependents),
    Run = [Id || Id <- Order, lists:member(Id, Run0)],
    Scopes = maps:from_list(
               [{Id, scope_for(Id, Heads, Index)} || Id <- Run]),
    {Run, Scopes}.

functor_key(Head) when is_atom(Head)  -> {Head, 0};
functor_key(Head) when is_tuple(Head) -> {element(1, Head), tuple_size(Head) - 1}.

transitive_closure(Ids, Dependents) ->
    close(Ids, sets:from_list(Ids), Dependents).

close([], Seen, _Dependents) -> sets:to_list(Seen);
close([Id | Rest], Seen, Dependents) ->
    New = [D || D <- maps:get(Id, Dependents, []), not sets:is_element(D, Seen)],
    close(New ++ Rest,
          lists:foldl(fun sets:add_element/2, Seen, New),
          Dependents).

scope_for(Id, Heads, Index) ->
    Watched = [H || H <- Heads, lists:member(Id, maps:get(functor_key(H), Index, []))],
    case Watched of
        [] -> all;
        _  -> {keys, Watched}
    end.

events_finished(
  {ok, Tip, TipEst, Effects, CatalogUpdate, ReactionStats},
  S0 = #s{mode = live}) ->
    %% advance est/height to the batch tip so heavy workers (started here) and the floor track
    %% the head; p_height/e_frontier are the P-before-E barrier
    S = install_catalog_update(CatalogUpdate, S0),
    S1 = S#s{est = TipEst, height = Tip,
             p_height = max(S#s.p_height, Tip),
             e_frontier = max(S#s.e_frontier, Tip),
             exec_failures = 0,
             reaction_candidates =
                 S#s.reaction_candidates + maps:get(candidates, ReactionStats),
             reaction_matches =
                 S#s.reaction_matches + maps:get(matches, ReactionStats),
             reactions_executed =
                 S#s.reactions_executed + maps:get(executed, ReactionStats),
             reaction_inert =
                 S#s.reaction_inert + maps:get(inert, ReactionStats),
             reaction_failures =
                 S#s.reaction_failures + maps:get(failures, ReactionStats),
             dropped_events =
                 S#s.dropped_events + maps:get(dropped, ReactionStats)},
    release_direct_effects(Effects),
    S2 = release_event_acks(S1),
    next_after_runner(floor_raise(pump_heavy(release_ready_waiters(S2))));
events_finished({error, Reason}, S) ->
    execution_failure({event_tier_failed, Reason}, S).

install_catalog_update(keep, S) ->
    S;
install_catalog_update(
  #{subscriptions := Subscriptions, reactions := Reactions,
    reaction_index := ReactionIndex,
    source_interests := SourceInterests, rejected_dynamic := RejectedDynamic,
    rejected_subscriptions := RejectedSubscriptions},
  S = #s{ns = Ns}) ->
    RejectedDynamic =:= 0 orelse
        logger:warning("quod_runtime[~s]: ~b non-founding runtime declaration(s) "
                       "refused (no can_declare_runtime authorization yet)",
                       [Ns, RejectedDynamic]),
    RejectedSubscriptions =:= 0 orelse
        logger:warning("quod_runtime[~s]: ~b malformed subscribes/2 clause(s) ignored",
                       [Ns, RejectedSubscriptions]),
    S1 = S#s{subscriptions = Subscriptions, reactions = Reactions,
             reaction_index = ReactionIndex,
             source_interests = SourceInterests,
             rejected_dynamic = S#s.rejected_dynamic + RejectedDynamic,
             rejected_subscriptions =
                 S#s.rejected_subscriptions + RejectedSubscriptions},
    reconcile_source_views(Subscriptions, S1).

%%%===================================================================
%%% Shared certified source follows and subscribed reaction delivery
%%%===================================================================

reconcile_source_views(Subscriptions, S0) ->
    Desired = maps:from_keys(Subscriptions, true),
    Removed = [Identity || Identity <- maps:keys(S0#s.source_views),
                           not maps:is_key(Identity, Desired)],
    S1 = lists:foldl(fun stop_source_view/2, S0, Removed),
    S2 = lists:foldl(
           fun(Identity, Acc) ->
                   case maps:is_key(Identity, Acc#s.source_views) of
                       true -> Acc;
                       false -> enqueue_source_follow(Identity, Acc)
                   end
           end, S1, Subscriptions),
    %% Attachment yields through one self-message per identity, so a large
    %% catalogue never blocks this runtime turn. A missing owner is parked and
    %% woken by its one gproc name-follow monitor, never by a retry timer.
    drive_source_attach(
      maybe_release_foreign_log_monitor(
        ensure_foreign_log_monitor(S2))).

enqueue_source_follow(Identity, S0) ->
    Height = case maps:get(Identity, S0#s.source_views, undefined) of
                 #{state := State} -> source_last_height(State);
                 undefined -> 0
             end,
    queue_source_identities(
      [Identity],
      put_source_view(
        Identity,
        #{follow_ref => none, state => {building, Height}, attempt => 0}, S0)).

attach_source_follow(Identity, S0) ->
    Height = source_view_height(Identity, S0),
    {Attempt, S1} = next_source_attempt(S0),
    case quod_foreign_log:follow(Identity) of
        {ok, FollowRef} ->
            put_source_view(
              Identity,
              #{follow_ref => FollowRef, state => {building, Height},
                attempt => Attempt}, S1);
        {error, Reason} ->
            mark_source_unreachable(Identity, Reason, Height, Attempt, S1)
    end.

source_view_height(Identity, #s{source_views = Views}) ->
    case maps:get(Identity, Views, undefined) of
        #{state := State} -> source_last_height(State);
        undefined -> 0
    end.

put_source_view(Identity, Row, S) ->
    S#s{source_views = (S#s.source_views)#{Identity => Row}}.

next_source_attempt(S = #s{source_attempts = Attempts}) ->
    {Attempts + 1, S#s{source_attempts = Attempts + 1}}.

mark_source_unreachable(Identity, Reason, Height, Attempt, S0) ->
    put_source_view(
      Identity,
      #{follow_ref => none, state => {unreachable, Reason, Height},
        attempt => Attempt}, S0).

ensure_foreign_log_monitor(S = #s{source_views = Views})
  when map_size(Views) =:= 0 ->
    clear_foreign_log_monitor(S);
ensure_foreign_log_monitor(S = #s{foreign_log_monitor = MRef})
  when is_reference(MRef) ->
    S;
ensure_foreign_log_monitor(S) ->
    MRef = quod_reg:monitor_name({foreign_log, node}, follow),
    S#s{foreign_log_monitor = MRef}.

clear_foreign_log_monitor(S = #s{foreign_log_monitor = none}) -> S;
clear_foreign_log_monitor(
  S = #s{foreign_log_monitor = MRef}) ->
    ok = quod_reg:demonitor_name({foreign_log, node}, MRef),
    S#s{foreign_log_monitor = none}.

handle_source_notice(FollowRef, NoticeRef, Identity, Notice, S0) ->
    case maps:get(Identity, S0#s.source_views, undefined) of
        #{follow_ref := FollowRef} = Row0 ->
            case source_notice_state(Notice) of
                {ok, State, Publications} ->
                    Row1 = Row0#{state => State},
                    S1 = S0#s{source_views =
                                  (S0#s.source_views)#{Identity => Row1}},
                    enqueue_source_publications(
                      FollowRef, NoticeRef, Identity, Publications, S1);
                error ->
                    erlang:error({invalid_source_follow_notice, Notice})
            end;
        _ ->
            S0
    end.

source_notice_state({building, Height})
  when is_integer(Height), Height >= 0 ->
    {ok, {building, Height}, []};
source_notice_state({unreachable, Reason, Height})
  when is_integer(Height), Height >= 0 ->
    {ok, {unreachable, Reason, Height}, []};
source_notice_state(
  {advanced, From, To, <<_:256>> = ProjectionId, Freshness, Heads,
   Publications})
  when is_integer(From), is_integer(To), To >= From,
       is_map(Freshness), is_list(Heads), is_list(Publications) ->
    case valid_source_publications(Publications, From, To) of
        true ->
            {ok, {ready, To, ProjectionId, Freshness,
                  #{from => From, changed_heads => Heads,
                    resnapshot => false}}, Publications};
        false ->
            error
    end;
source_notice_state(
  {resnapshot, To, <<_:256>> = ProjectionId, Freshness})
  when is_integer(To), To >= 0, is_map(Freshness) ->
    {ok, {ready, To, ProjectionId, Freshness,
          #{from => 0, changed_heads => [], resnapshot => true}}, []};
source_notice_state(_) ->
    error.

valid_source_publications(Publications, From, To) ->
    valid_source_publications(Publications, From, From, To).

valid_source_publications([], _From, _Previous, _To) -> true;
valid_source_publications([{Height, AppliedOps} | Rest], From, Previous, To)
  when is_integer(Height), Height > From, Height >= Previous, Height =< To,
       AppliedOps =/= [] ->
    quod_diff:valid_ops(AppliedOps)
        andalso valid_source_publications(Rest, From, Height, To);
valid_source_publications(_Malformed, _From, _Previous, _To) -> false.

enqueue_source_publications(FollowRef, NoticeRef, Identity, Publications, S0) ->
    case source_publications_relevant(Identity, Publications,
                                      S0#s.source_interests) of
        false ->
            ack_source_notice(FollowRef, NoticeRef, S0);
        true ->
            enqueue_relevant_source_publications(
              FollowRef, NoticeRef, Identity, Publications, S0)
    end.

enqueue_relevant_source_publications(FollowRef, NoticeRef, Identity,
                                     Publications, S0) ->
    case event_mode(S0#s.mode) of
        true ->
            case S0#s.queue_len < max_queued_events(S0) of
                true ->
                    Item = {remote, FollowRef, NoticeRef, Identity, Publications},
                    S1 = S0#s{queue = [Item | S0#s.queue],
                              queue_len = S0#s.queue_len + 1},
                    maybe_run_events(S1);
                false ->
                    %% The certified projection is already current. Reactions
                    %% are best-effort, so overload drops only this occurrence
                    %% and releases the follower to coalesce later advances.
                    ack_source_notice(
                      FollowRef, NoticeRef,
                      S0#s{dropped_events = S0#s.dropped_events + 1})
            end;
        false ->
            %% Boot/replay/unhealthy never replay historical E. Source views
            %% are normally absent in those modes; this handles a late notice
            %% from a superseded follow.
            ack_source_notice(
              FollowRef, NoticeRef,
              S0#s{dropped_events = S0#s.dropped_events + 1})
    end.

event_mode(live) -> true;
event_mode({reconciling, _}) -> true;
event_mode(_) -> false.

source_publications_relevant(Identity, Publications, SourceInterests) ->
    case maps:get(Identity, SourceInterests, undefined) of
        undefined -> false;
        Index ->
            lists:any(
              fun({_Height, AppliedOps}) ->
                      lists:any(
                        fun(Event) -> maps:is_key(functor_key(Event), Index) end,
                        quod_runtime_predicates:diff_to_events(AppliedOps))
              end, Publications)
    end.

ack_source_notice(FollowRef, NoticeRef, S) ->
    ok = quod_foreign_log:ack(FollowRef, NoticeRef),
    S.

%% Catalogue and owner-registration edges populate this queue. One identity is
%% attempted per mailbox turn, preserving responsiveness without a compiled
%% batch limit. Failed rows stay parked until a real owner replacement or a
%% later catalogue reconciliation supplies another edge.
queue_source_identities(Identities, S0) ->
    Existing = maps:from_keys(S0#s.source_attach_queue, true),
    Added = [Identity
             || Identity <- Identities,
                maps:is_key(Identity, S0#s.source_views),
                not maps:is_key(Identity, Existing),
                source_needs_attach(Identity, S0)],
    drive_source_attach(
      S0#s{source_attach_queue = S0#s.source_attach_queue ++ Added}).

queue_waiting_source_views(S) ->
    Waiting = [Identity
               || {Identity, Row} <- maps:to_list(S#s.source_views),
                  maps:get(follow_ref, Row, none) =:= none],
    queue_source_identities(lists:sort(Waiting), S).

source_needs_attach(Identity, #s{source_views = Views}) ->
    case maps:get(Identity, Views, undefined) of
        #{follow_ref := none} -> true;
        _ -> false
    end.

drive_source_attach(S = #s{source_attach_queue = [],
                           source_attach_token = none}) ->
    S;
drive_source_attach(S = #s{source_attach_token = Token})
  when is_reference(Token) ->
    S;
drive_source_attach(S) ->
    Token = make_ref(),
    self() ! {source_follow_attach, Token},
    S#s{source_attach_token = Token}.

run_source_attach(S0 = #s{source_attach_queue = [Identity | Rest]}) ->
    S1 = S0#s{source_attach_queue = Rest},
    S2 = case source_needs_attach(Identity, S1) of
             true -> attach_source_follow(Identity, S1);
             false -> S1
         end,
    drive_source_attach(S2);
run_source_attach(S) ->
    S.

stop_source_view(Identity, S0) ->
    S1 = drop_source_queue(Identity, S0),
    case maps:take(Identity, S1#s.source_views) of
        {Row, Views1} ->
            case maps:get(follow_ref, Row, none) of
                FollowRef when is_reference(FollowRef) ->
                    ok = quod_foreign_log:unfollow(FollowRef);
                none -> ok
            end,
            S1#s{source_views = Views1,
                 source_attach_queue =
                     lists:delete(Identity, S1#s.source_attach_queue)};
        error ->
            S1
    end.

stop_source_views(S0) ->
    S1 = lists:foldl(
           fun stop_source_view/2, S0, maps:keys(S0#s.source_views)),
    clear_foreign_log_monitor(
      S1#s{source_attach_queue = [], source_attach_token = none}).

maybe_release_foreign_log_monitor(S = #s{source_views = Views}) ->
    case map_size(Views) of
        0 -> clear_foreign_log_monitor(
               S#s{source_attach_queue = [], source_attach_token = none});
        _ -> S
    end.

foreign_log_down(S0) ->
    %% Every reference died with the owner. The gproc `follow` monitor remains
    %% armed and its exact `registered` edge will repopulate the attachment
    %% queue when the replacement owner is addressable.
    S1 = S0#s{source_attach_queue = [], source_attach_token = none},
    maps:fold(
      fun(Identity, Row, Acc0) ->
              Height = source_last_height(maps:get(state, Row)),
              put_source_view(
                Identity,
                #{follow_ref => none,
                  state => {unreachable, unavailable, Height},
                  attempt => maps:get(attempt, Row, 0)}, Acc0)
      end, S1, S1#s.source_views).

source_last_height({building, Height}) -> Height;
source_last_height({unreachable, _Reason, Height}) -> Height;
source_last_height({ready, Height, _ProjectionId, _Freshness, _Delta}) -> Height;
source_last_height(_) -> 0.

source_state_count(Status, Views) ->
    length([ok || Row <- maps:values(Views),
                  source_state_tag(maps:get(state, Row)) =:= Status]).

source_state_tag({ready, _, _, _, _}) -> ready;
source_state_tag({building, _}) -> building;
source_state_tag({unreachable, _, _}) -> unreachable.

%% After any runner completes: a parked ready edge wins; otherwise drain what queued.
next_after_runner(S = #s{pending_edge = none}) ->
    maybe_run_events(S);
next_after_runner(S = #s{pending_edge = Id}) ->
    replace_snapshot_and_reconcile(Id, S).

%% Execution failure: collapse pending work into ONE reconciliation at the newest snapshot.
%% Collapse ORDERING matters [DA M7]: any in-flight runner is killed first (its stale writes
%% must not land after the clear), then the queue drops and P bookkeeping clears, THEN the
%% fresh reconcile attaches. Consecutive failures back off exponentially; after
%% ?MAX_EXEC_FAILURES the server crashes deliberately so the supervisor path runs (the
%% backoff spacing keeps that far outside quod_ns's restart-intensity window).
execution_failure(Reason, S0 = #s{ns = Ns}) ->
    N = S0#s.exec_failures + 1,
    S1 = kill_runner(S0),
    S = drop_queue(S1#s{exec_failures = N,
                        collapses = S0#s.collapses + 1}),
    if
        N > ?MAX_EXEC_FAILURES ->
            logger:error("quod_runtime[~s]: ~b consecutive execution failures — giving up "
                         "to the supervisor: ~0p", [Ns, N, Reason]),
            exit({runtime_giving_up, Reason});
        N =:= 1 ->
            logger:warning("quod_runtime[~s]: execution failure (~0p) — collapsing to one "
                           "reconciliation", [Ns, Reason]),
            attach_and_reconcile({collapse, make_ref()}, S);
        true ->
            Delay = 1000 bsl (N - 1),
            logger:warning("quod_runtime[~s]: execution failure #~b (~0p) — retrying "
                           "reconciliation in ~b ms", [Ns, N, Reason, Delay]),
            Ref = make_ref(),
            _ = erlang:send_after(Delay, self(), {collapse_retry, Ref}),
            S#s{mode = {unhealthy, Reason}, last_recovery = {collapse, Ref}}
    end.

kill_runner(S0 = #s{heavy_running = Running}) ->
    %% collapse kills EVERY in-flight worker — tier runner AND heavy workers [DA M7]: their
    %% stale writes must not land after the clear, and the reconcile's converge goals
    %% re-enqueue heavy jobs, so revision barriers still resolve.
    RunnerWorkers = case S0#s.runner of
                        none -> [];
                        {_Kind, Pid, MRef, _Ref, TRef} ->
                            _ = erlang:cancel_timer(TRef),
                            [{Pid, MRef}]
                    end,
    HeavyWorkers = maps:fold(
                     fun(_Res, {P, M, T, _R, _Rev, _EH}, Acc) ->
                             _ = erlang:cancel_timer(T),
                             [{P, M} | Acc]
                     end, [], Running),
    Workers = RunnerWorkers ++ HeavyWorkers,
    lists:foreach(fun({Pid, _MRef}) -> exit(Pid, kill) end, Workers),
    %% `exit(Pid, kill)` and a later Prolog pin detach/replace target different processes;
    %% there is no cross-recipient signal ordering. Wait for every DOWN here so no worker can
    %% still read the old snapshot when the pin moves. This runs only on replay/failure/stop.
    await_worker_downs(maps:from_list([{MRef, true} || {_Pid, MRef} <- Workers])),
    release_event_acks(
      S0#s{runner = none, heavy_running = #{}, heavy_pending = #{}, heavy_order = []}).

await_worker_downs(Pending) when map_size(Pending) =:= 0 -> ok;
await_worker_downs(Pending) ->
    receive
        {'DOWN', MRef, process, _Pid, _Reason} when is_map_key(MRef, Pending) ->
            await_worker_downs(maps:remove(MRef, Pending))
    end.

begin_replay(Id, S0) ->
    S1 = kill_runner(stop_source_views(S0)),
    %% All readers are now dead, so releasing the base pin cannot invalidate a proof. The
    %% cast precedes any later re-attach call from this process by Erlang signal ordering.
    ok = quod_prolog:runtime_detach(S1#s.ns),
    drop_queue(S1#s{mode = {replaying, Id}, pending_edge = none}).

%% Queue overflow is BACKPRESSURE, not a fault: collapse to a reconciliation (kill the runner,
%% drop the queue, rebuild from the newest snapshot) but do NOT touch `exec_failures` and log at
%% notice — otherwise a load spike looks identical to a handler crash in the logs/metrics and
%% could (over enough distinct spikes) approach the deliberate-crash valve. Counted in
%% `collapses` so sustained overload is still visible.
overflow_collapse(S0 = #s{ns = Ns}) ->
    logger:notice("quod_runtime[~s]: event queue overflow — collapsing to one reconciliation "
                  "(backpressure, not a fault)", [Ns]),
    S1 = kill_runner(S0),
    S = drop_queue(S1#s{collapses = S1#s.collapses + 1}),
    attach_and_reconcile({collapse, make_ref()}, S).

%%%===================================================================
%%% heavy-worker framework (§8 — framework only, no product worker yet)
%%%===================================================================

%% Start queued jobs up to the global cap, one per resource. Started ONLY when the tier is
%% idle (`mode = live, runner = none`): the server's `est`/`height` are the batch/reconcile
%% tip exactly then, so a job — whose requested `Rev` is its enqueueing event's height —
%% always runs against a snapshot AT OR NEWER than `Rev` (during a running batch, `est` still
%% lags at the pre-batch height, which would converge the wrong snapshot and install a bogus
%% revision). A job's captured snapshot is pinned by `floor_raise` while it runs.
pump_heavy(S = #s{mode = live, runner = none, est = Est,
                  heavy_pending = Pending, heavy_order = Order,
                  heavy_running = Running})
  when map_size(Pending) > 0, Est =/= undefined ->
    Cap = max_heavy_workers(S),
    Startable = [Res || Res <- Order, not is_map_key(Res, Running)],
    lists:foldl(fun(Res, Acc) ->
                        case map_size(Acc#s.heavy_running) < Cap of
                            true  -> start_heavy(Res, Acc);
                            false -> Acc
                        end
                end, S, Startable);
pump_heavy(S) -> S.   %% booting/reconciling/replaying/unhealthy, or a tier runner is active

%% A heavy job failed or its worker died — ISOLATED from the ordered tier (the plan's guarantee
%% that a slow/failing heavy worker cannot delay namespace events). Drop the resource's pending
%% job (the handler re-enqueues on its next matching event, so this cannot tight-loop), mark its
%% revision blocked, lift the floor, and keep the tier running. The frontier cannot release that
%% resource's waiters until a later successful full rebuild clears the blocked revision.
heavy_failed(Resource, Reason, S = #s{ns = Ns}) ->
    logger:warning("quod_runtime[~s]: heavy job for ~0p failed (~0p) — dropped; the namespace "
                   "tier is unaffected", [Ns, Resource, Reason]),
    FailedRev = S#s.height,
    Blocked = maps:update_with(Resource, fun(Old) -> max(Old, FailedRev) end,
                               FailedRev, S#s.blocked_revisions),
    S1 = S#s{heavy_pending = maps:remove(Resource, S#s.heavy_pending),
             heavy_order = lists:delete(Resource, S#s.heavy_order),
             blocked_revisions = Blocked,
             heavy_failures = S#s.heavy_failures + 1},
    floor_raise(pump_heavy(S1)).

start_heavy(Resource, S = #s{ns = Ns, est = Est, height = EstH,
                              heavy_order = Order}) ->
    {{Rev, Job}, Pending} = maps:take(Resource, S#s.heavy_pending),
    Server = self(),
    Ref = make_ref(),
    Budget = application:get_env(quod, runtime_heavy_budget_ms, ?HEAVY_BUDGET_MS),
    {Pid, MRef} =
        spawn_monitor(
          fun() ->
                  Outcome = try heavy_job(Ns, Est, EstH, Resource, Rev, Job)
                            catch throw:R -> {error, R}
                            end,
                  gen_server:cast(Server, {heavy_done, Resource, Ref, Outcome})
          end),
    TRef = erlang:send_after(Budget, self(), {heavy_kill, Resource, Ref}),
    S#s{heavy_pending = Pending, heavy_order = lists:delete(Resource, Order),
        heavy_running = (S#s.heavy_running)#{Resource => {Pid, MRef, TRef, Ref, Rev, EstH}}}.

%% The job is a complete Prolog goal (no scope appended), proved under a projection context
%% identifying the resource; like a handler, it may not stage D.
heavy_job(Ns, Est, EstH, Resource, _Rev, Job) ->
    Ctx = quod_predicates:projection_context(Ns, EstH, {heavy, Resource}),
    case quod_prolog:prove_est(Job, quod_predicates:set_context(Est, Ctx)) of
        {ok, _B, [], _RS}     -> ok;
        {ok, _B, Staged, _RS} -> throw({job_staged_d, Resource, Staged});
        fail                  -> throw({job_failed, Resource});
        {error, Reason}       -> throw({job_error, Resource, Reason})
    end.

release_ready_waiters(S = #s{waiters = Waiters}) ->
    Released = [WRef || WRef := {_From, Res, WRev, _TRef} <- Waiters,
                        effective_revision(Res, S) >= WRev],
    lists:foldl(fun(WRef, Acc) ->
                        {{From, _Res, _WRev, TRef}, Rest} = maps:take(WRef, Acc#s.waiters),
                        _ = erlang:cancel_timer(TRef),
                        gen_server:reply(From, ok),
                        Acc#s{waiters = Rest}
                end, S, Released).

%% Permanent unhealthy: no revision can install any more — fail every waiter now.
fail_waiters(S = #s{waiters = Waiters}) ->
    maps:foreach(fun(_WRef, {From, _Res, _Rev, TRef}) ->
                         _ = erlang:cancel_timer(TRef),
                         gen_server:reply(From, {error, unhealthy})
                 end, Waiters),
    S#s{waiters = #{}}.

max_heavy_workers(#s{config = Config}) ->
    maps:get(runtime_max_heavy_workers, Config,
             application:get_env(quod, runtime_max_heavy_workers,
                                 ?DEFAULT_MAX_HEAVY_WORKERS)).

max_heavy_pending(#s{config = Config}) ->
    maps:get(runtime_max_heavy_pending, Config,
             application:get_env(quod, runtime_max_heavy_pending,
                                 ?DEFAULT_MAX_HEAVY_PENDING)).

max_heavy_job_bytes(#s{config = Config}) ->
    maps:get(runtime_max_heavy_job_bytes, Config,
             application:get_env(quod, runtime_max_heavy_job_bytes,
                                 ?DEFAULT_MAX_HEAVY_JOB_BYTES)).

validate_heavy_enqueue(Resource, Job, S) ->
    try byte_size(term_to_binary({Resource, Job}, [deterministic])) =< max_heavy_job_bytes(S) of
        true  -> ok;
        false -> oversized
    catch _:_ -> oversized
    end.

queue_heavy(Resource, Rev, Job, S = #s{heavy_pending = Pending}) ->
    case maps:is_key(Resource, Pending) of
        true ->
            {ok, S#s{heavy_pending = Pending#{Resource => {Rev, Job}},
                     superseded = S#s.superseded + 1}};
        false ->
            case map_size(Pending) < max_heavy_pending(S) of
                true ->
                    {ok, S#s{heavy_pending = Pending#{Resource => {Rev, Job}},
                             heavy_order = S#s.heavy_order ++ [Resource]}};
                false ->
                    full
            end
    end.

%% A resource is current through the namespace frontier when no job for it is outstanding.
%% A failed job blocks that inference until a later full-rebuild job succeeds at/after it.
effective_revision(Resource, S) ->
    Installed = maps:get(Resource, S#s.revisions, 0),
    Outstanding = maps:is_key(Resource, S#s.heavy_pending)
                  orelse maps:is_key(Resource, S#s.heavy_running),
    Blocked = maps:get(Resource, S#s.blocked_revisions, none),
    case Outstanding orelse Blocked =/= none of
        true  -> Installed;
        false -> max(Installed, S#s.e_frontier)
    end.

clear_blocked(Resource, NewRev, Blocked) ->
    case maps:get(Resource, Blocked, none) of
        Rev when is_integer(Rev), Rev =< NewRev -> maps:remove(Resource, Blocked);
        _ -> Blocked
    end.

handle_info_rest(_Info, S) -> {noreply, S}.

drop_queue(S = #s{queue_len = 0}) -> S;
drop_queue(S) ->
    release_queue_acks(S#s.queue),
    S#s{queue = [], queue_len = 0,
        dropped_events = S#s.dropped_events + S#s.queue_len}.

%% After a reconcile at height H: envelopes at or below H are already IN the snapshot.
drop_stale_queue(S = #s{height = H, queue = Q}) ->
    {Kept0, Dropped0} =
        lists:partition(
          fun({local, Env, _Est}) -> maps:get(height, Env, 0) > H;
             ({remote, _, _, _, _}) -> true
          end, Q),
    Dropped = length(Dropped0),
    S#s{queue = Kept0, queue_len = length(Kept0),
        dropped_events = S#s.dropped_events + Dropped}.

drop_source_queue(Identity, S = #s{queue = Q}) ->
    {Dropped, Kept} =
        lists:partition(
          fun({remote, _, _, Source, _}) -> Source =:= Identity;
             (_) -> false
          end, Q),
    release_queue_acks(Dropped),
    N = length(Dropped),
    S#s{queue = Kept, queue_len = S#s.queue_len - N,
        dropped_events = S#s.dropped_events + N}.

release_queue_acks(Items) ->
    lists:foreach(
      fun({remote, FollowRef, NoticeRef, _Identity, _Publications}) ->
              ok = quod_foreign_log:ack(FollowRef, NoticeRef);
         (_) -> ok
      end, Items),
    ok.

release_event_acks(S = #s{event_acks = Acks}) ->
    lists:foreach(
      fun({FollowRef, NoticeRef}) ->
              ok = quod_foreign_log:ack(FollowRef, NoticeRef)
      end, Acks),
    S#s{event_acks = []}.

%% Raise the KB history floor to the oldest snapshot still READ by anything we own: the
%% freshest processed height, held down by any RUNNING heavy worker's captured est height.
%% The cast is monotone server-side, so a stale/duplicate raise is harmless.
floor_raise(S = #s{height = 0}) -> S;
floor_raise(S = #s{ns = Ns, height = H, heavy_running = Running}) ->
    Target = lists:min([H | [EstH || {_P, _M, _T, _R, _Rev, EstH}
                                         <- maps:values(Running)]]),
    ok = quod_prolog:runtime_floor(Ns, Target),
    S.

max_queued_events(#s{config = Config}) ->
    maps:get(runtime_max_queued_events, Config,
             application:get_env(quod, runtime_max_queued_events,
                                 ?DEFAULT_MAX_QUEUED_EVENTS)).

%%%===================================================================
%%% one handler converge (shared by reconcile + the tier)
%%%===================================================================

%% Scope `all` or {keys, Heads}, under a projection context on the frozen snapshot.
%% A non-empty staged overlay is a violation: a projection may not write D.
converge(Ns, Est, H, Id, Goal, Scope) ->
    Ctx = quod_predicates:projection_context(Ns, H, Id),
    case quod_prolog:prove_est(with_scope(Goal, Scope),
                               quod_predicates:set_context(Est, Ctx)) of
        {ok, _Bindings, [], _ReadSet}     -> ok;
        {ok, _Bindings, Staged, _ReadSet} -> throw({handler_staged_d, Id, Staged});
        fail                              -> throw({handler_failed, Id});
        {error, Reason}                   -> throw({handler_error, Id, Reason})
    end.

%%%===================================================================
%%% discovery — the founding set (slot 1) and the stored set (snapshot)
%%%===================================================================

%% {ok, Heads} (cacheable) | no_log (retry later, UNCACHED) | {error, Reason} (unhealthy).
%% no_log covers both a missing file AND an empty/slot-1-less log: quod_simplex creates the
%% log file eagerly at init, so an empty read is the same "not founded yet" case as enoent —
%% caching it would silently disable this node's handlers forever once slot 1 arrives.
read_founding(Ns, Config) ->
    case quod_ledger_store:open_ro(Ns, quod_ledger_store:ledger_dir(Config)) of
        {ok, Store} ->
            try quod_ledger_store:read_at(Store, 1) of
                {ok, #entry{data = Data}} -> founding_payload(Data);
                not_found -> no_log
            after quod_ledger_store:close(Store)
            end;
        {error, no_log} ->
            no_log;
        {error, Reason} ->
            {error, Reason}
    end.

%% Slot 1 defines the ontology's founding truth and is necessarily one content
%% batch. A DTX control, skip, or malformed value at genesis is corruption, not
%% an empty set of declarations.
founding_payload(Data) ->
    case quod_ledger:classify(Data) of
        {content, Txs} -> {ok, founding_runtime(Txs)};
        {controls, _Controls} -> {error, invalid_genesis_payload};
        noop -> {error, invalid_genesis_payload};
        invalid -> {error, invalid_genesis_payload}
    end.

-ifdef(TEST).
test_read_founding(Ns, Config) -> read_founding(Ns, Config).
-endif.

empty_founding() -> #{handlers => [], reactions => []}.

founding_runtime(Txs) ->
    #{handlers => founding_heads(Txs),
      reactions => founding_clauses(Txs, {react_on, 3})}.

founding_clauses(Txs, Functor) ->
    [Clause || #transaction{diff = Diff} <- Txs,
               {assert, {Head, _Body} = Clause} <- Diff,
               erlog_int:functor(Head) =:= Functor].

%% The state_handler heads asserted by the founding block's transactions (full terms).
founding_heads(Txs) ->
    [Head || #transaction{diff = Diff} <- Txs,
             {assert, {Head, _Body}} <- Diff,
             is_declaration(Head)].

is_declaration(Head) ->
    is_tuple(Head) andalso tuple_size(Head) =:= 5
        andalso element(1, Head) =:= state_handler.

%% Every state_handler/4 solution in the snapshot, as full declaration terms.
stored_declarations(Est) ->
    Tpl  = {d, {'I'}, {'W'}, {'N'}, {'G'}},
    Goal = {findall, Tpl, {state_handler, {'I'}, {'W'}, {'N'}, {'G'}}, {'L'}},
    case quod_prolog:prove_est(Goal, Est) of
        {ok, Bindings, _Staged, _ReadSet} ->
            L = maps:get('L', Bindings, []),
            {ok, [{state_handler, I, W, N, G} || {d, I, W, N, G} <- L]};
        fail            -> {ok, []};
        {error, Reason} -> {error, Reason}
    end.

%% Exact clauses, not proved solutions. A rule which happens to derive a
%% subscribes/2 or react_on/3 answer is application logic, not a runtime
%% declaration, and must not silently become one.
stored_runtime_catalog(Est) ->
    case {quod_diff:interpreted_clauses(Est, {subscribes, 2}),
          quod_diff:interpreted_clauses(Est, {react_on, 3})} of
        {{ok, Subscriptions}, {ok, Reactions}} ->
            {ok, #{subscriptions => Subscriptions, reactions => Reactions}};
        {{error, Reason}, _} ->
            {error, {{subscribes, 2}, Reason}};
        {_, {error, Reason}} ->
            {error, {{react_on, 3}, Reason}}
    end.

plan_runtime(Est, Founding, StoredHandlers, StoredCatalog) ->
    case plan_handlers(Est, maps:get(handlers, Founding, []), StoredHandlers) of
        {ok, HandlerPlan} ->
            case plan_runtime_catalog(
                   maps:get(reactions, Founding, []), StoredCatalog) of
                {ok, CatalogPlan} ->
                    Rejected = maps:get(rejected_dynamic, HandlerPlan)
                               + maps:get(rejected_dynamic, CatalogPlan),
                    {ok, (maps:merge(HandlerPlan, CatalogPlan))#{
                           rejected_dynamic => Rejected}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

%%%===================================================================
%%% subscription/reaction catalogue + the founding gate (pure)
%%%===================================================================

%% A deterministic catalogue derived from one committed snapshot. It owns no
%% process, route, verifier, delivery state, or event matcher. Alpha
%% normalization establishes declaration identity only; live matching and the
%% Handler continuation belong to the ordered tier and
%% erlog_int:unify_prove_body.
plan_runtime_catalog(FoundingReactions, StoredCatalog)
  when is_list(FoundingReactions), is_map(StoredCatalog) ->
    case plan_reactions(FoundingReactions,
                        maps:get(reactions, StoredCatalog, [])) of
        {ok, Reactions, SourceInterests, RejectedDynamic} ->
            {Subscriptions, RejectedSubscriptions} =
                plan_subscriptions(maps:get(subscriptions, StoredCatalog, [])),
            {ok, #{subscriptions => Subscriptions,
                   reactions => Reactions,
                   reaction_index => local_reaction_index(Reactions),
                   source_interests => SourceInterests,
                   rejected_dynamic => RejectedDynamic,
                   rejected_subscriptions => RejectedSubscriptions}};
        {error, _} = Error ->
            Error
    end;
plan_runtime_catalog(_FoundingReactions, _StoredCatalog) ->
    {error, invalid_runtime_catalog}.

plan_subscriptions(Clauses) when is_list(Clauses) ->
    {Targets, Rejected} =
        lists:foldl(
          fun(Clause, {Accepted, Refused}) ->
                  case valid_subscription_clause(Clause) of
                      {ok, Target} -> {Accepted#{Target => true}, Refused};
                      ignore       -> {Accepted, Refused};
                      error        -> {Accepted, Refused + 1}
                  end
          end, {#{}, 0}, Clauses),
    {lists:sort(maps:keys(Targets)), Rejected};
plan_subscriptions(_Malformed) ->
    {[], 1}.

valid_subscription_clause(
  {{subscribes, Ns, <<_:256>> = Anchor} = Head, {[], false}}) ->
    case quod_directory_auth:valid_namespace(Ns)
         andalso bounded_term(Head) of
        true  -> {ok, {Ns, Anchor}};
        false -> error
    end;
valid_subscription_clause(
  {{subscribes, _Ns, _Anchor}, {Goals, _HasCut}})
  when is_list(Goals), Goals =/= [] ->
    %% An ordinary rule that can prove subscribes/2 is application logic, not
    %% a runtime declaration and not malformed configuration.
    ignore;
valid_subscription_clause(_) ->
    error.

plan_reactions(Founding, Stored) when is_list(Founding), is_list(Stored) ->
    case canonical_founding_reactions(Founding, #{}) of
        {ok, FoundingByKey} ->
            {StoredByKey, InvalidStored} = canonical_stored_reactions(Stored, #{}, 0),
            Missing = lists:sort(
                        [Key || Key <- maps:keys(FoundingByKey),
                                not is_map_key(Key, StoredByKey)]),
            case Missing of
                [] ->
                    Dynamic = [Key || Key <- maps:keys(StoredByKey),
                                      not is_map_key(Key, FoundingByKey)],
                    Active = lists:sort([maps:get(Key, FoundingByKey)
                                         || Key <- maps:keys(FoundingByKey)]),
                    {ok, Active, source_interest_index(Active),
                     length(Dynamic) + InvalidStored};
                _ ->
                    {error, {missing_founding_reaction, Missing}}
            end;
        {error, _} = Error ->
            Error
    end;
plan_reactions(_Founding, _Stored) ->
    {error, invalid_runtime_catalog}.

canonical_founding_reactions([Clause | Rest], Acc) ->
    Canonical = alpha_normalize(Clause),
    case valid_reaction_clause(Canonical) of
        {ok, _Source} ->
            canonical_founding_reactions(Rest, Acc#{Canonical => reaction_head(Canonical)});
        error ->
            {error, {invalid_founding_reaction, Canonical}}
    end;
canonical_founding_reactions([], Acc) ->
    {ok, Acc}.

canonical_stored_reactions([Clause | Rest], Acc, Invalid) ->
    Canonical = alpha_normalize(Clause),
    case valid_reaction_clause(Canonical) of
        {ok, _Source} ->
            canonical_stored_reactions(Rest, Acc#{Canonical => true}, Invalid);
        error ->
            case inert_reaction_rule(Canonical) of
                true  -> canonical_stored_reactions(Rest, Acc, Invalid);
                false -> canonical_stored_reactions(Rest, Acc, Invalid + 1)
            end
    end;
canonical_stored_reactions([], Acc, Invalid) ->
    {Acc, Invalid}.

inert_reaction_rule(
  {{react_on, _Executor, _Pattern, _Handler}, {Goals, _HasCut}})
  when is_list(Goals), Goals =/= [] ->
    true;
inert_reaction_rule(_) ->
    false.

reaction_head({Head, _Body}) -> Head.

valid_reaction_clause(
  {{react_on, Executor, Pattern, Handler} = Head, {[], false}}) ->
    case {reaction_pattern(Pattern), valid_callable(Executor),
          valid_callable(Handler), bounded_term(Head)} of
        {{ok, Source, EventPattern}, true, true, true} ->
            PatternVars = variable_set(EventPattern),
            UsedVars = maps:merge(variable_set(Executor), variable_set(Handler)),
            case lists:all(fun(V) -> is_map_key(V, PatternVars) end,
                           maps:keys(UsedVars)) of
                true  -> {ok, Source};
                false -> error
            end;
        _ ->
            error
    end;
valid_reaction_clause(_) ->
    error.

reaction_pattern({from, Ns, <<_:256>> = Anchor, EventPattern}) ->
    case quod_directory_auth:valid_namespace(Ns)
         andalso valid_event_pattern(EventPattern) of
        true  -> {ok, {remote, {Ns, Anchor}}, EventPattern};
        false -> error
    end;
reaction_pattern(EventPattern) ->
    case valid_event_pattern(EventPattern) of
        true  -> {ok, local, EventPattern};
        false -> error
    end.

valid_event_pattern({Kind, FactPattern}) when Kind =:= assert; Kind =:= retract ->
    valid_callable(FactPattern) andalso bounded_term(FactPattern);
valid_event_pattern(EventPattern) ->
    quod_diff:valid_event_pattern(EventPattern).

valid_callable(Term) when is_atom(Term) -> true;
valid_callable(Term) when is_tuple(Term), tuple_size(Term) >= 2 ->
    is_atom(element(1, Term));
valid_callable(_) -> false.

bounded_term(Term) ->
    case quod_wire_term:encode(Term) of
        {ok, _} -> true;
        {error, bad_term} -> false
    end.

source_interest_index(Reactions) ->
    Reversed =
        lists:foldl(
          fun({react_on, _Executor,
              {from, Ns, <<_:256>> = Anchor, EventPattern}, _Handler} = Reaction,
              Index) ->
                  Target = {Ns, Anchor},
                  Key = functor_key(EventPattern),
                  TargetIndex = maps:get(Target, Index, #{}),
                  Updated = maps:update_with(
                              Key, fun(Existing) -> [Reaction | Existing] end,
                              [Reaction], TargetIndex),
                  Index#{Target => Updated};
             (_LocalReaction, Index) ->
                  Index
          end, #{}, Reactions),
    maps:map(
      fun(_Target, TargetIndex) ->
              maps:map(
                fun(_Key, Candidates) -> lists:reverse(Candidates) end,
                TargetIndex)
      end, Reversed).

local_reaction_index(Reactions) ->
    Reversed =
        lists:foldl(
          fun({react_on, _Executor, {from, _, _, _}, _Handler}, Index) ->
                  Index;
             ({react_on, _Executor, EventPattern, _Handler} = Reaction, Index) ->
                  Key = functor_key(EventPattern),
                  maps:update_with(Key, fun(Existing) -> [Reaction | Existing] end,
                                   [Reaction], Index)
          end, #{}, Reactions),
    maps:map(fun(_Key, Candidates) -> lists:reverse(Candidates) end, Reversed).

%% Alpha-normalize Erlog variables by first occurrence. Stored clauses use
%% one-tuples (`{0}`, `{1}`, ...); founding and snapshot reads may allocate
%% different ids for the same declaration, so process-local ids can never be
%% authority. Anonymous `_` is treated as a fresh variable at every occurrence.
alpha_normalize(Term) ->
    {Normalized, _Vars, _Next} = alpha_normalize(Term, #{}, 0),
    Normalized.

alpha_normalize({Var}, Vars, Next) ->
    case Var of
        '_' -> {{Next}, Vars, Next + 1};
        _ ->
            case maps:find(Var, Vars) of
                {ok, Canonical} -> {{Canonical}, Vars, Next};
                error -> {{Next}, Vars#{Var => Next}, Next + 1}
            end
    end;
alpha_normalize(Term, Vars, Next) when is_tuple(Term) ->
    {Items, Vars1, Next1} = alpha_list(tuple_to_list(Term), Vars, Next),
    {list_to_tuple(Items), Vars1, Next1};
alpha_normalize([Head | Tail], Vars, Next) ->
    {Head1, Vars1, Next1} = alpha_normalize(Head, Vars, Next),
    {Tail1, Vars2, Next2} = alpha_normalize(Tail, Vars1, Next1),
    {[Head1 | Tail1], Vars2, Next2};
alpha_normalize(Term, Vars, Next) ->
    {Term, Vars, Next}.

alpha_list([Item | Rest], Vars, Next) ->
    {Item1, Vars1, Next1} = alpha_normalize(Item, Vars, Next),
    {Rest1, Vars2, Next2} = alpha_list(Rest, Vars1, Next1),
    {[Item1 | Rest1], Vars2, Next2};
alpha_list([], Vars, Next) ->
    {[], Vars, Next}.

variable_set(Term) -> variable_set(Term, #{}).

variable_set({Var}, Acc) -> Acc#{Var => true};
variable_set(Term, Acc) when is_tuple(Term) ->
    lists:foldl(fun variable_set/2, Acc, tuple_to_list(Term));
variable_set([Head | Tail], Acc) ->
    variable_set(Tail, variable_set(Head, Acc));
variable_set(_Term, Acc) -> Acc.

%%%===================================================================
%%% handler validation and ordering (pure)
%%%===================================================================

%% plan_handlers(FoundingHeads, StoredHeads) -> {ok, Plan} | {error, Reason}.
%% Active = stored ∩ founding by FULL-TERM equality (name-only matching would let any writer
%% swap a founding handler's body under the same id — the C2 backdoor). Stored-but-not-founding
%% is refused + counted (healthy). Founding-but-not-stored (a retracted founding declaration)
%% is a distinct loud config error, as is a NONGROUND founding declaration — findall renames
%% variables, so a nonground term can never match itself and would misreport as retracted.
-ifdef(TEST).
plan_handlers(Founding, Stored) ->
    Est = quod_committed_projection:new_est(),
    try plan_handlers(Est, Founding, Stored)
    after
        #est{db = #db{ref = Ref}} = Est,
        quod_erlog_db_mvcc:delete(Ref)
    end.
-endif.

plan_handlers(Est, Founding, Stored) ->
    case [D || D <- Founding, erlog:vars_in(D) =/= []] of
        []        -> plan_ground(Est, Founding, Stored);
        Nonground -> {error, {nonground_founding, Nonground}}
    end.

plan_ground(Est, Founding, Stored) ->
    FSet     = maps:from_keys(Founding, true),
    SSet     = maps:from_keys(Stored, true),
    Active   = [D || D <- Stored, is_map_key(D, FSet)],
    Rejected = length(Stored) - length(Active),
    case [D || D <- Founding, not is_map_key(D, SSet)] of
        []      -> validate(Est, Active, Rejected);
        Missing -> {error, {missing_founding, Missing}}
    end.

validate(Est, Decls, Rejected) ->
    Hs = [#handler{id = I, watch = W, needs = N, goal = G}
          || {state_handler, I, W, N, G} <- Decls],
    Ids = [H#handler.id || H <- Hs],
    case Ids -- lists:usort(Ids) of
        []  ->
            case first_invalid(Est, Hs, Ids) of
                none            -> order(Hs, Rejected);
                {error, Reason} -> {error, Reason}
            end;
        Dup -> {error, {duplicate_handler_id, lists:usort(Dup)}}
    end.

first_invalid(_Est, [], _Ids) -> none;
first_invalid(Est, [#handler{id = Id, watch = W, needs = N, goal = G} | Rest], Ids) ->
    case valid_watch(W) andalso is_list(N) andalso valid_goal(Est, G) of
        false -> {error, {invalid_declaration, Id}};
        true  ->
            case [X || X <- N, not valid_need(X, Ids)] of
                []  -> first_invalid(Est, Rest, Ids);
                Bad -> {error, {missing_dependency, Id, Bad}}
            end
    end.

%% Watch = a list of F/A functor indicators (the erlog term {'/', F, A}).
valid_watch(W) when is_list(W) ->
    lists:all(fun({'/', F, A}) -> is_atom(F) andalso is_integer(A) andalso A >= 0;
                 (_)           -> false
              end, W);
valid_watch(_) -> false.

%% Slice-2 Needs: ground current(Id) over DECLARED handlers only. Arbitrary condition goals
%% are deliberately refused — under the KB's silent-fail semantics a typo'd condition is
%% indistinguishable from a false one, and data-dependent conditions would diverge across
%% nodes reconciling at different heights.
valid_need({current, Id}, Ids) -> lists:member(Id, Ids);
valid_need(_, _Ids)            -> false.

%% The ConvergeGoal is invoked with the scope argument APPENDED (declared arity N runs as
%% N+1 — this erlog has no call/2). If the invoked functor is governed, its class must be
%% projection/query; the dynamic class matrix stays the real fail-closed boundary.
valid_goal(Est, G) ->
    case functor_of(G) of
        {F, A} when is_atom(F) ->
            case quod_predicates:class(Est, {F, A + 1}) of
                undefined  -> true;         %% ordinary content predicate
                projection -> true;
                query      -> true;
                _          -> false         %% staging/effect can never be a projection goal
            end;
        _ -> false
    end.

functor_of(G) when is_atom(G)                            -> {G, 0};
functor_of(G) when is_tuple(G), is_atom(element(1, G)),
                   tuple_size(G) > 1                     -> {element(1, G), tuple_size(G) - 1};
functor_of(_)                                            -> error.

%% Append the scope argument to a ConvergeGoal term (atom or compound).
with_scope(G, Scope) when is_atom(G) -> {G, Scope};
with_scope(G, Scope)                 -> erlang:append_element(G, Scope).

%% Kahn over the current/1 edges, ready set kept sorted by Id term order — the converge
%% sequence is identical on every node. Any leftover = a cycle. Deps are usort'ed: a
%% duplicated Need entry is harmless authoring noise, not a second edge (lists:delete
%% removes one occurrence, so an un-usort'ed duplicate would masquerade as a cycle).
order(Hs, Rejected) ->
    ById = maps:from_list([{H#handler.id, H} || H <- Hs]),
    Deps = #{H#handler.id => lists:usort([Id || {current, Id} <- H#handler.needs])
             || H <- Hs},
    case kahn(Deps, []) of
        {ok, Order} ->
            {ok, #{handlers => ById, order => Order,
                   index => watch_index(Hs), dependents => reverse_edges(Deps),
                   rejected_dynamic => Rejected}};
        {error, Cyclic} ->
            {error, {handler_cycle, Cyclic}}
    end.

kahn(Deps, Acc) when map_size(Deps) =:= 0 -> {ok, lists:reverse(Acc)};
kahn(Deps, Acc) ->
    case lists:sort([Id || Id := Ds <- Deps, Ds =:= []]) of
        [] -> {error, lists:sort(maps:keys(Deps))};
        [Next | _] ->
            Deps1 = maps:map(fun(_Id, Ds) -> lists:delete(Next, Ds) end,
                             maps:remove(Next, Deps)),
            kahn(Deps1, [Next | Acc])
    end.

%% Id => the ids that Need it (the tier's dependent-invalidation walk).
reverse_edges(Deps) ->
    maps:fold(fun(Id, Ds, Acc) ->
                      lists:foldl(fun(D, A) ->
                                          maps:update_with(D, fun(L) -> [Id | L] end,
                                                           [Id], A)
                                  end, Acc, Ds)
              end, #{}, Deps).

%% Functor => [HandlerId] over the watch patterns (the tier's event-matching index; list
%% order is irrelevant — matching unions the hits and runs them in converge order).
watch_index(Hs) ->
    lists:foldl(
      fun(#handler{id = Id, watch = W}, Index) ->
              lists:foldl(
                fun({'/', F, A}, Ix) ->
                        maps:update_with({F, A}, fun(L) -> [Id | L] end, [Id], Ix)
                end, Index, W)
      end, #{}, Hs).
