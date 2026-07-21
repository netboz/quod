-module(quod_runtime).
-moduledoc """
Per-namespace runtime projection orchestrator — the P tier of `doc/agent-fipa-plan.md` §4.2/§7/§8.

D (the committed KB) is the truth; P is this node's *derived working state*, rebuilt from D by
**handlers** declared as ordinary stored facts:

    state_handler(Id, WatchedPatterns, Needs, ConvergeGoal)

One recipe per handler: `ConvergeGoal` converges the handler's piece of P from the current
snapshot. The SAME goal runs everywhere, distinguished only by the appended scope argument:
`all` at reconcile, `{keys, ChangedHeads}` after a live change — where `ChangedHeads` are the
full head terms of the block's diff INCLUDING retracted heads (so "nothing in the snapshot
for key K ⇒ delete P[K]" is expressible), and a join-shaped handler whose keys don't align
with the changed heads may legitimately treat the hint as `all`. `Needs` is a list of
`current(OtherId)` terms ordering handlers after their prerequisites (the onia/bbsvx
action-pattern shape, hand-rolled); this slice restricts Needs to exactly those ground
`current/1` edges so the whole graph is validated statically at reconcile — a cycle or
missing dependency fails loudly up front, never mid-run.

## Who may declare a handler

Handlers are executable — writing the fact must not be enough to activate it. Until the
`can_declare_runtime` authorization lands, a declaration is **active only if its complete
GROUND term is byte-identical to one in the ontology's founding (slot-1) block**. This
full-term founding match is currently the *sole* lock (quod has no write ACL yet — the
intended end state is founding-only *system* ontologies whose ACL is read-only).
Consequences: later-written declarations are recorded but refused (counted, warned); a
*retracted* founding declaration (`G∖K`) is a loud, distinct unhealthy — the runtime never
runs handlers the KB no longer contains; a founding declaration containing a variable is
refused loudly (a nonground term cannot round-trip the KB byte-identically).

## The ordered tier (live events)

Each live block's transactions arrive as direct `{applied_live, Env, Est}` envelopes carrying
the block-final snapshot. They queue in height order (bounded; overflow collapses the queue
into one reconciliation) and drain in batches through the single killable runner. Per event:
the changed heads select the watching handlers via the functor index; those handlers AND
their transitive dependents are re-converged, in the global converge order — prerequisites
first regardless of Id term order — each with
its own watched subset of the changed heads as scope (`all` when a chained-in dependent
watches none of them). When the batch completes through height H, `p_height = e_frontier = H`
— the namespace-wide P-before-E barrier the effect layer will read.

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
below is needed any more), so KB history never accumulates behind an idle pin;
`quod_prolog` itself suspends the pin while a replay run is open.

Supervised LAST in `m:quod_ns`'s `rest_for_one` chain: any restart of `quod_prolog` (or a
later sibling) restarts this runtime, whose re-attach then re-pins against the fresh KB —
closing the one-way attach monitor — while a runtime crash restarts nothing else.

## Known Slice-2/3 limitation (observers)

A non-committee observer ingests every block as a replay, so its KB never publishes a ready
edge after boot: the observer's runtime stays at its boot-time P (`mode=replaying`) until
agents-on-observers work lands. Its KB does not leak history — the pin is suspended for the
whole run — but its handlers are stale by design for now.
""".

-behaviour(gen_server).

-include("quod_ledger.hrl").

-export([start_link/2, stats/1, enqueue_heavy/4, revision/2, await_revision/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_continue/2, handle_info/2,
         terminate/2]).
-ifdef(TEST).
%% the pure planning + event-matching core — driven directly by eunit
-export([plan_handlers/2, founding_heads/1, with_scope/2, event_plan/4]).
-endif.

-define(RECONCILE_BUDGET_MS, 30000).
-define(EVENT_BUDGET_MS, 1000).
-define(EVENT_BUDGET_CAP_MS, 60000).      %% ceiling on a whole batch's runner budget
-define(HEAVY_BUDGET_MS, 30000).
-define(MAX_EXEC_FAILURES, 5).            %% then crash deliberately: the supervisor path runs
-define(DEFAULT_MAX_QUEUED_EVENTS, 1024). %% >= 4 max-size blocks of per-tx envelopes
-define(DEFAULT_MAX_HEAVY_WORKERS, 8).    %% global concurrent resource-worker cap

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
            index = #{} :: #{tuple() => [term()]},    %% Functor => [HandlerId] (event matching)
            dependents = #{} :: #{term() => [term()]},%% Id => ids that Need it (reverse edges)
            founding = unknown :: unknown | {ok, [tuple()]},  %% cached slot-1 heads
            %% ONE killable runner at a time — a reconcile or an ordered-tier event batch
            runner = none :: none | {reconcile | events, pid(), reference(), reference(),
                                     reference()},
            pending_edge = none :: none | term(),     %% a ready edge that arrived mid-reconcile
            last_recovery = undefined :: term(),      %% dedup: reconcile once per edge id
            %% the ordered tier: live envelopes queued in arrival (= height) order, drained in
            %% batches. (Dependent invalidation is by watch-match + the static dependents graph,
            %% recomputed per event — no separate marker bookkeeping is needed or kept.)
            queue = [] :: [{map(), tuple()}],         %% REVERSED accumulation of {Env, Est}
            queue_len = 0 :: non_neg_integer(),
            p_height = 0 :: non_neg_integer(),        %% ordered tier completed through here
            e_frontier = 0 :: non_neg_integer(),      %% the P-before-E barrier (Slice 3 E reads)
            exec_failures = 0 :: non_neg_integer(),   %% consecutive execution failures (backoff)
            reconciles = 0 :: non_neg_integer(),
            reconcile_failures = 0 :: non_neg_integer(),
            collapses = 0 :: non_neg_integer(),       %% queue overflows + execution collapses
            dropped_events = 0 :: non_neg_integer(),
            rejected_dynamic = 0 :: non_neg_integer(),
            events_seen = 0 :: non_neg_integer(),     %% direct applied_live received
            %% heavy-worker framework (§8): queue-fed per-resource workers OUTSIDE the
            %% ordered pipeline. One COALESCED pending slot per resource (jobs are
            %% full-rebuild-idempotent in this slice, so a newer job supersedes a queued one);
            %% workers run against the NEWEST attached snapshot (converging to at-least-Rev),
            %% so only RUNNING workers pin history (at their captured est height).
            heavy_pending = #{} :: #{term() => {non_neg_integer(), term()}},  %% Res => {Rev, Job}
            heavy_running = #{} :: #{term() => {pid(), reference(), reference(),
                                                non_neg_integer(), non_neg_integer()}},
                                   %% Res => {Pid, MRef, TRef, Rev, EstHeight}
            revisions = #{} :: #{term() => non_neg_integer()},   %% Res => installed rev
            waiters = #{} :: #{reference() => {gen_server:from(), term(), non_neg_integer(),
                                               reference()}},    %% WRef => {From,Res,Rev,TRef}
            superseded = 0 :: non_neg_integer(),
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

-doc """
Queue heavy work for `Resource` at requested revision `Rev` (the enqueueing event's height).
Called by the `enqueue_projection/2` bridge from a handler's converge run — fire-and-forget:
the runtime coalesces (a newer job supersedes a queued one) and bounds the workers.
""".
-spec enqueue_heavy(binary(), term(), non_neg_integer(), term()) -> ok.
enqueue_heavy(Ns, Resource, Rev, Job) ->
    gen_server:cast(quod_reg:via({quod_runtime, Ns}), {heavy_enqueue, Resource, Rev, Job}).

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
              p_height => S#s.p_height, e_frontier => S#s.e_frontier,
              queue_len => S#s.queue_len,
              reconciles => S#s.reconciles,
              reconcile_failures => S#s.reconcile_failures,
              collapses => S#s.collapses,
              dropped_events => S#s.dropped_events,
              rejected_dynamic => S#s.rejected_dynamic,
              events_seen => S#s.events_seen,
              heavy_pending => map_size(S#s.heavy_pending),
              heavy_running => map_size(S#s.heavy_running),
              heavy_superseded => S#s.superseded,
              heavy_failures => S#s.heavy_failures,
              waiters => map_size(S#s.waiters)}, S};
handle_call({revision, Resource}, _From, S) ->
    {reply, maps:get(Resource, S#s.revisions, 0), S};
handle_call({await_revision, Resource, Rev, TimeoutMs}, From, S) ->
    case maps:get(Resource, S#s.revisions, 0) >= Rev of
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
handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.

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
%% A handler enqueued heavy work (enqueue_projection/2 → enqueue_heavy/4). Coalesce: a newer
%% job for the same resource supersedes a QUEUED one — never a running one (per-resource
%% order holds: the running job finishes, then the newest queued job starts).
handle_cast({heavy_enqueue, Resource, Rev, Job}, S) ->
    Superseded = case maps:is_key(Resource, S#s.heavy_pending) of
                     true  -> S#s.superseded + 1;
                     false -> S#s.superseded
                 end,
    S1 = S#s{heavy_pending = (S#s.heavy_pending)#{Resource => {Rev, Job}},
             superseded = Superseded},
    {noreply, pump_heavy(S1)};
handle_cast({heavy_done, Resource, Ref, Outcome}, S) ->
    case maps:get(Resource, S#s.heavy_running, undefined) of
        {_Pid, MRef, TRef, Ref, Rev, _EstH} ->
            _ = erlang:cancel_timer(TRef),
            erlang:demonitor(MRef, [flush]),
            S1 = S#s{heavy_running = maps:remove(Resource, S#s.heavy_running)},
            case Outcome of
                ok ->
                    NewRev = max(maps:get(Resource, S1#s.revisions, 0), Rev),
                    S2 = release_waiters(Resource, NewRev,
                                         S1#s{revisions = (S1#s.revisions)#{Resource =>
                                                                            NewRev}}),
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
    {noreply, attach_and_reconcile(boot, S)};
handle_info({replay_ready, boot, _H}, S) ->
    {noreply, S};
handle_info({replay_ready, Id, _H}, S = #s{last_recovery = Id}) ->
    {noreply, S};
handle_info({replay_ready, Id, _H}, S = #s{runner = {_, _, _, _, _}}) ->
    {noreply, S#s{pending_edge = Id}};
handle_info({replay_ready, Id, _H}, S) ->
    {noreply, attach_and_reconcile(Id, S)};
handle_info({replay_started, Id, _From}, S = #s{runner = none}) ->
    %% queued envelopes' state is covered by the coming reconcile snapshot
    {noreply, drop_queue(S#s{mode = {replaying, Id}})};
handle_info({replay_started, Id, _From}, S) ->
    %% let the in-flight runner finish (its P is idempotent and pre-gap); freeze the frontier
    %% by mode, drop what hasn't started
    {noreply, drop_queue(S#s{mode = {replaying, Id}})};
%% The direct post-commit envelope (est-carrying): the ordered tier's input. Enqueue in
%% arrival (= height) order; overflow collapses to one reconciliation at the newest snapshot.
handle_info({applied_live, Env, Est}, S0 = #s{mode = live}) ->
    S = S0#s{events_seen = S0#s.events_seen + 1},
    case S#s.queue_len >= max_queued_events(S) of
        true ->
            {noreply, overflow_collapse(S)};
        false ->
            S1 = S#s{queue = [{Env, Est} | S#s.queue], queue_len = S#s.queue_len + 1},
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
            {noreply, S1#s{queue = [{Env, Est} | S1#s.queue],
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
    _ = kill_runner(S), ok.

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
        {FoundingCache, G} =
            case Cached of
                {ok, Gc} -> {keep, Gc};
                unknown  ->
                    case read_founding(Ns, Config) of
                        {ok, Gr}     -> {{cache, Gr}, Gr};
                        no_log       -> {keep, []};
                        {error, R0}  -> throw({founding_read_failed, R0})
                    end
            end,
        Stored = case stored_declarations(Est) of
                     {ok, K}         -> K;
                     {error, R1}     -> throw({discovery_failed, R1})
                 end,
        case plan_handlers(G, Stored) of
            {ok, Plan = #{handlers := Hs, order := Order}} ->
                lists:foreach(fun(Id) ->
                                      #handler{goal = Goal} = maps:get(Id, Hs),
                                      converge(Ns, Est, H, Id, Goal, all)
                              end, Order),
                {ok, FoundingCache, Plan};
            {error, R2} ->
                throw(R2)
        end
    catch throw:R -> {error, R}
    end.

reconcile_finished({ok, FoundingCache, #{handlers := Hs, order := Order, index := Index,
                                         dependents := Dependents,
                                         rejected_dynamic := Rej}},
                   S0 = #s{ns = Ns, height = H}) ->
    Rej =:= 0 orelse
        logger:warning("quod_runtime[~s]: ~b non-founding state_handler declaration(s) "
                       "refused (no can_declare_runtime authorization yet)", [Ns, Rej]),
    S1 = S0#s{handlers = Hs, order = Order, index = Index, dependents = Dependents,
              founding = case FoundingCache of
                             {cache, G} -> {ok, G};
                             keep       -> S0#s.founding
                         end,
              p_height = H, e_frontier = H,
              rejected_dynamic = S0#s.rejected_dynamic + Rej,
              reconciles = S0#s.reconciles + 1,
              exec_failures = 0},
    case S1#s.pending_edge of
        none -> maybe_run_events(drop_stale_queue(pump_heavy(S1#s{mode = live})));
        Id   -> attach_and_reconcile(Id, S1#s{pending_edge = none})
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
            attach_and_reconcile(Id, S1#s{pending_edge = none})
    end.

%% Founding configuration errors are permanent (only new founding content or a code fix can
%% change them); execution failures are transient and go through collapse + backoff.
config_error({missing_founding, _})     -> true;
config_error({nonground_founding, _})   -> true;
config_error({duplicate_handler_id, _}) -> true;
config_error({invalid_declaration, _})  -> true;
config_error({missing_dependency, _, _})-> true;
config_error({handler_cycle, _})        -> true;
config_error({founding_read_failed, _}) -> true;
config_error(_)                         -> false.

unhealthy(Reason, S = #s{ns = Ns}) ->
    %% PERMANENT (config) unhealthy — no revision can install any more. QUIESCE fully: kill the
    %% tier runner AND every heavy worker + clear their pending (kill_runner), so nothing keeps
    %% installing revisions or pinning snapshots in a terminally-dead runtime, then fail waiters.
    logger:error("quod_runtime[~s]: unhealthy: ~0p", [Ns, Reason]),
    S1 = kill_runner(S),
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

maybe_run_events(S = #s{mode = live, runner = none, queue = Q, handlers = Hs})
  when Q =/= [] ->
    %% coalesce the queue into ONE unit per block height: every tx in a block shares the block's
    %% final snapshot, so a handler need converge once per block over the UNION of its changed
    %% heads, not once per tx (O(txs/block) redundant proofs otherwise).
    Blocks = coalesce_blocks(lists:reverse(Q)),
    case map_size(Hs) of
        0 ->
            %% no handlers: the tier is trivially complete through the batch tip
            {Tip, TipEst} = batch_tip(Blocks),
            S1 = S#s{queue = [], queue_len = 0, est = TipEst, height = Tip,
                     p_height = Tip, e_frontier = Tip},
            floor_raise(pump_heavy(S1));
        _ ->
            %% budget = one per-event allowance per block, CAPPED — a wedged goal in a huge
            %% batch must not hold the single runner (and the KB floor) for minutes; the cap's
            %% kill collapses to a reconcile, which rebuilds correctly.
            Per = application:get_env(quod, runtime_event_budget_ms, ?EVENT_BUDGET_MS),
            Cap = application:get_env(quod, runtime_event_budget_cap_ms, ?EVENT_BUDGET_CAP_MS),
            Budget = min(length(Blocks) * Per, Cap),
            #s{ns = Ns, order = Order, index = Index, dependents = Deps,
               handlers = Handlers} = S,
            spawn_runner(events, Budget,
                         fun() -> run_events(Ns, Blocks, Handlers, Order, Index, Deps) end,
                         S#s{queue = [], queue_len = 0})
    end;
maybe_run_events(S) ->
    S.

%% [{Env,Est}] (ascending height) => [{Height, Est, UnionedHeads}] one per block, Est/height
%% = the block-final snapshot shared by that block's txs, heads = union of every tx's diff.
coalesce_blocks(Batch) ->
    Folded =
        lists:foldl(
          fun({Env, Est}, Acc) ->
                  H = maps:get(height, Env, 0),
                  Heads = changed_heads(Env),
                  case Acc of
                      [{H, _E0, H0} | Rest] -> [{H, Est, H0 ++ Heads} | Rest];  %% same block
                      _                     -> [{H, Est, Heads} | Acc]
                  end
          end, [], Batch),
    lists:reverse([{H, Est, lists:usort(Heads)} || {H, Est, Heads} <- Folded]).

batch_tip(Blocks) ->
    {Tip, Est, _Heads} = lists:last(Blocks),
    {Tip, Est}.

%% Runner body (event batch): per BLOCK, run the invalidated handlers in converge order, each
%% with its watched subset of the block's changed heads as scope. Returns {ok,Tip,Est}|{error,R}.
run_events(Ns, Blocks, Handlers, Order, Index, Deps) ->
    try
        {Tip, TipEst} =
            lists:foldl(
              fun({H, Est, Heads}, _Prev) ->
                      {Run, Scopes} = event_plan(Heads, Index, Order, Deps),
                      lists:foreach(
                        fun(Id) ->
                                #handler{goal = Goal} = maps:get(Id, Handlers),
                                converge(Ns, Est, H, Id, Goal, maps:get(Id, Scopes))
                        end, Run),
                      {H, Est}
              end, {0, undefined}, Blocks),
        {ok, Tip, TipEst}
    catch throw:R -> {error, R}
    end.

%% The full dereferenced head terms of the envelope's diff — INCLUDING retracted heads, so
%% per-key convergence can observe removals (nothing in the snapshot for key K ⇒ delete P[K]).
changed_heads(Env) ->
    [Head || {_Op, {Head, _Body}} <- maps:get(diff, Env, [])].

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

events_finished({ok, Tip, TipEst}, S = #s{mode = live}) ->
    %% advance est/height to the batch tip so heavy workers (started here) and the floor track
    %% the head; p_height/e_frontier are the P-before-E barrier
    S1 = S#s{est = TipEst, height = Tip,
             p_height = max(S#s.p_height, Tip),
             e_frontier = max(S#s.e_frontier, Tip),
             exec_failures = 0},
    next_after_runner(floor_raise(pump_heavy(S1)));
events_finished({ok, _Tip, _TipEst}, S) ->
    %% a replay opened mid-batch: the pin is suspended (quod_prolog cleared it on replay_open),
    %% so this batch's est is now unpinned — DO NOT keep it or pump against it. Freeze the
    %% frontier; the coming reconcile re-attaches a fresh pinned snapshot and rebuilds.
    next_after_runner(S#s{exec_failures = 0});
events_finished({error, Reason}, S) ->
    execution_failure({event_tier_failed, Reason}, S).

%% After any runner completes: a parked ready edge wins; otherwise drain what queued.
next_after_runner(S = #s{pending_edge = none}) ->
    maybe_run_events(S);
next_after_runner(S = #s{pending_edge = Id}) ->
    attach_and_reconcile(Id, S#s{pending_edge = none}).

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
    S = case S0#s.runner of
            none -> S0;
            {_Kind, Pid, MRef, _Ref, TRef} ->
                _ = erlang:cancel_timer(TRef),
                erlang:demonitor(MRef, [flush]),
                exit(Pid, kill),
                S0#s{runner = none}
        end,
    maps:foreach(fun(_Res, {P, M, T, _R, _Rev, _EH}) ->
                         _ = erlang:cancel_timer(T),
                         erlang:demonitor(M, [flush]),
                         exit(P, kill)
                 end, Running),
    S#s{heavy_running = #{}, heavy_pending = #{}}.

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
                  heavy_pending = Pending, heavy_running = Running})
  when map_size(Pending) > 0, Est =/= undefined ->
    Cap = max_heavy_workers(S),
    Startable = [Res || Res := _ <- Pending, not is_map_key(Res, Running)],
    lists:foldl(fun(Res, Acc) ->
                        case map_size(Acc#s.heavy_running) < Cap of
                            true  -> start_heavy(Res, Acc);
                            false -> Acc
                        end
                end, S, lists:sort(Startable));
pump_heavy(S) -> S.   %% booting/reconciling/replaying/unhealthy, or a tier runner is active

%% A heavy job failed or its worker died — ISOLATED from the ordered tier (the plan's guarantee
%% that a slow/failing heavy worker cannot delay namespace events). Drop the resource's pending
%% job (the handler re-enqueues on its next matching event, so this cannot tight-loop), lift the
%% floor now its snapshot is released, and keep the tier running. Waiters are left to their
%% timeout; a later successful job for the resource releases them.
heavy_failed(Resource, Reason, S = #s{ns = Ns}) ->
    logger:warning("quod_runtime[~s]: heavy job for ~0p failed (~0p) — dropped; the namespace "
                   "tier is unaffected", [Ns, Resource, Reason]),
    S1 = S#s{heavy_pending = maps:remove(Resource, S#s.heavy_pending),
             heavy_failures = S#s.heavy_failures + 1},
    floor_raise(pump_heavy(S1)).

start_heavy(Resource, S = #s{ns = Ns, est = Est, height = EstH}) ->
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
    S#s{heavy_pending = Pending,
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

release_waiters(Resource, Rev, S = #s{waiters = Waiters}) ->
    Released = [WRef || WRef := {_From, Res, WRev, _TRef} <- Waiters,
                        Res =:= Resource, WRev =< Rev],
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

handle_info_rest(_Info, S) -> {noreply, S}.

drop_queue(S = #s{queue_len = 0}) -> S;
drop_queue(S) ->
    S#s{queue = [], queue_len = 0,
        dropped_events = S#s.dropped_events + S#s.queue_len}.

%% After a reconcile at height H: envelopes at or below H are already IN the snapshot.
drop_stale_queue(S = #s{height = H, queue = Q}) ->
    Kept = [E || {Env, _} = E <- lists:reverse(Q), maps:get(height, Env, 0) > H],
    Dropped = S#s.queue_len - length(Kept),
    S#s{queue = lists:reverse(Kept), queue_len = length(Kept),
        dropped_events = S#s.dropped_events + Dropped}.

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
    case quod_ledger_store:open_ro(Ns, quod_ledger_store:data_dir(Config)) of
        {ok, Store} ->
            try quod_ledger_store:read_at(Store, 1) of
                {ok, #entry{data = {batch, Txs}}} -> {ok, founding_heads(Txs)};
                {ok, #entry{}}                    -> {ok, []};   %% a noop slot 1
                not_found                         -> no_log
            after quod_ledger_store:close(Store)
            end;
        {error, no_log} ->
            no_log;
        {error, Reason} ->
            {error, Reason}
    end.

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

%%%===================================================================
%%% the founding gate + validation + ordering (pure)
%%%===================================================================

%% plan_handlers(FoundingHeads, StoredHeads) -> {ok, Plan} | {error, Reason}.
%% Active = stored ∩ founding by FULL-TERM equality (name-only matching would let any writer
%% swap a founding handler's body under the same id — the C2 backdoor). Stored-but-not-founding
%% is refused + counted (healthy). Founding-but-not-stored (a retracted founding declaration)
%% is a distinct loud config error, as is a NONGROUND founding declaration — findall renames
%% variables, so a nonground term can never match itself and would misreport as retracted.
plan_handlers(Founding, Stored) ->
    case [D || D <- Founding, erlog:vars_in(D) =/= []] of
        []        -> plan_ground(Founding, Stored);
        Nonground -> {error, {nonground_founding, Nonground}}
    end.

plan_ground(Founding, Stored) ->
    FSet     = maps:from_keys(Founding, true),
    SSet     = maps:from_keys(Stored, true),
    Active   = [D || D <- Stored, is_map_key(D, FSet)],
    Rejected = length(Stored) - length(Active),
    case [D || D <- Founding, not is_map_key(D, SSet)] of
        []      -> validate(Active, Rejected);
        Missing -> {error, {missing_founding, Missing}}
    end.

validate(Decls, Rejected) ->
    Hs = [#handler{id = I, watch = W, needs = N, goal = G}
          || {state_handler, I, W, N, G} <- Decls],
    Ids = [H#handler.id || H <- Hs],
    case Ids -- lists:usort(Ids) of
        []  ->
            case first_invalid(Hs, Ids) of
                none            -> order(Hs, Rejected);
                {error, Reason} -> {error, Reason}
            end;
        Dup -> {error, {duplicate_handler_id, lists:usort(Dup)}}
    end.

first_invalid([], _Ids) -> none;
first_invalid([#handler{id = Id, watch = W, needs = N, goal = G} | Rest], Ids) ->
    case valid_watch(W) andalso is_list(N) andalso valid_goal(G) of
        false -> {error, {invalid_declaration, Id}};
        true  ->
            case [X || X <- N, not valid_need(X, Ids)] of
                []  -> first_invalid(Rest, Ids);
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
valid_goal(G) ->
    case functor_of(G) of
        {F, A} when is_atom(F) ->
            case quod_predicates:class({F, A + 1}) of
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
