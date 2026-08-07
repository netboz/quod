-module(quod_prolog).
-moduledoc """
Per-namespace fact engine: owns the committed erlog knowledge base for one
ontology, serves `prove/3`, and applies committed blocks from `quod_simplex` in log
order. One `gen_server` per namespace.

- **Every proof runs in its own bounded WORKER process** — the engine never blocks
  on a proof (doc/inter-ontology.md §4.1). The worker gets a small shared-store snapshot
  handle, never the knowledge base. A wedged proof wedges only its worker, which is
  killed after its configured absolute lifetime; its private origin and selected-scope
  overlays die with their bounded workers.
- **Reads** run on a copy-on-write overlay (`m:quod_erlog_db_local_prove`) so the
  committed kb is never touched; the answer is bindings (stamped with the height the
  frozen view was taken at), returned to the caller.
- **Writes** (a proof that staged asserts/retracts) are handed back to the engine and
  become a `#transaction{}` submitted to `quod_simplex`; the caller is parked and
  replied to when the block applies (or reaped by a per-tx TTL if the verdict never
  arrives).
- **Lifecycle actions** accept only ground root `create_ontology/2` and
  `join_ontology/3` requests. One read-only anchored proof session validates the
  exact target-state declaration, authorizes before source reads, carries one
  opaque prepared descriptor through prerequisite selection, then re-authorizes,
  executes the typed request once, and verifies its desired state. Prolog
  backtracking never owns an external-operation descriptor.
- **`apply_block/4`** is the deterministic state machine `quod_simplex` drives on every
  member: re-check the read-set against the committed kb (OCC), then apply the diff
  or reject — identical verdict on every member. A **committee-changing** transaction
  (its diff asserts/retracts `peer_admitted`) is the exception: it applies
  **unconditionally**, skipping OCC, because it was already re-validated against the
  parent state before the vote (see `request_membership_verdict/5`) — this keeps the kb
  and `quod_simplex`'s validator-set projection in lockstep.

Proves are gated until an initial **rebuild** completes (`ready`), so a freshly
(re)started engine never answers from a half-built kb. The kb is built with the
erlog flag `unknown = fail`. The runtime projection contract is specified in
`doc/agent-fipa-plan.md` §7.
""".
-behaviour(gen_server).
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").

-export([start_link/2, prove/3, prove_ro/3, run_action/2,
         applied/1, apply_block/4, mark_ready/1, sync/1,
         attach_runtime/1, runtime_floor/2, runtime_detach/1,
         request_membership_verdict/5, stats/1, namespaces/0]).
-export([genesis_diff/1, read_terms/1, terms_to_diff/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export([prove_est/2, prove_est_read_only/2]).
%% prove against a raw #est{} handle (runtime + isolated policy reads)
-ifdef(TEST).
-export([membership_verdict/2,
         test_active_command_stack/1,
         test_scope_capacity_available/3,
         test_public_scope_reason/2,
         test_scope_timeout_reason/2,
         test_scope_command_budget_valid/3,
         test_target_scope_lifetime_ms/2,
         test_remote_timeout_correlation/3,
         test_scope_worker_failure/2,
         test_proof_down_reply/3]).
%% Pure verdict and scope-correlation seams driven directly by EUnit.
-endif.

%% The membership-verdict park budget: a verdict parked past the slot's Δ complaint-skip is moot, so this
%% is a short FIXED budget (default 2000 ms — on the order of the consensus Δ_timeout, `?DELTA_MS` ~1 s in
%% quod_simplex), deliberately NOT the 30 s write TTL. Reaping a stale parked verdict delivers `abstain`.
-define(DEFAULTS, #{node_id => undefined, transaction_ttl_ms => 30000,
                    validation_ttl_ms => 2000, max_proof_workers => 64,
                    max_scope_workers => 64, proof_timeout_ms => 60000,
                    scope_timeout_ms => 60000,
                    scope_step_timeout_ms => 30000}).
-define(ROOT_NS, <<"quod:root">>).

%% Busy/rebuilding replies are deliberately rate-limited: an authenticated peer can
%% still flood valid open frames, and rejecting them must not create unbounded work.
-define(MAX_SCOPE_REJECTS_PER_SECOND, 32).

-record(proof_worker, {pid         :: pid(),
                       kind        :: prove | prove_ro | action,
                       worker_mref :: reference(),
                       caller_mref :: reference(),
                       from        :: gen_server:from(),
                       timer       :: reference(),
                       token       :: reference(),
                       trace_ctx   :: quod_trace:context(),
                       height = 0  :: non_neg_integer()}).

%% One engine-owned top-level run. The engine chooses the proof id, frozen
%% height, and absolute local deadline before spawning the worker; the worker
%% then owns exactly one root session and proof context for the whole run.
-record(pinned_origin, {
          proof_id    :: <<_:256>>,
          scope_id    :: <<_:128>>,
          deadline_ms :: integer(),
          kind        :: prove | prove_ro | action,
          namespace   :: binary(),
          anchor      :: <<_:256>>,
          height      :: non_neg_integer(),
          context     :: quod_predicates:ctx(),
          session     :: quod_proof_session:session()
         }).

-record(scope_worker, {pid        :: pid(),
                       owner_mref :: reference(),
                       scope_key  :: term(),
                       height = 0 :: non_neg_integer(),
                       timer = undefined :: reference() | undefined,
                       token = undefined :: reference() | undefined,
                       lifetime_timer = undefined :: reference() | undefined,
                       lifetime_token = undefined :: reference() | undefined,
                       pending = false :: boolean(),
                       terminating = false :: boolean()}).

%% One target-owned remote scope.  All wire authority is fixed at scope_open:
%% the authenticated peer, exact request link, both anchored identities, mode,
%% proof/session ids, and the return link.  Goal payloads are decoded only after
%% this record's binding and command sequence have matched.
-record(remote_scope, {
          binding      :: quod_scope_wire:binding(),
          peer_key     :: <<_:256>>,
          request_link :: pid(),
          request_mref :: reference(),
          return_channel :: binary(),
          return_link = undefined :: undefined | pid(),
          return_mref = undefined :: undefined | reference(),
          open_ref     :: reference(),
          open_request_id :: <<_:128>>,
          %% Exact correlation of the last authenticated command accepted by
          %% this target.  Absolute expiry can happen while the scope is idle,
          %% when no ordinary request remains pending at the origin router.
          %% The terminal target-authored event reuses this id and the last
          %% accepted command sequence; there is no sentinel/legacy frame.
          last_request_id :: <<_:128>>,
          lifetime_timer = undefined :: undefined | reference(),
          lifetime_token = undefined :: undefined | reference(),
          handle = undefined :: undefined | quod_scope_session:handle(),
          worker_mref = undefined :: undefined | reference(),
          state = opening_return ::
                    opening_return | opening_session | active | closing,
          next_command_seq = 2 :: pos_integer(),
          next_event_seq = 1 :: pos_integer(),
          deadline_ms :: integer(),
          dirty = false :: boolean(),
          generation = 0 :: non_neg_integer(),
          pending = #{} :: map(),
          controllers = #{} :: map(),
          active_commands = [] :: [{<<_:128>>, pos_integer()}]
         }).

-record(s, {ns        :: binary(),
            self      :: node_id(),
            est       :: tuple(),                 %% committed erlog #est{} (unknown=fail)
            ready     = false :: boolean(),       %% true once the initial rebuild has run
            %% Runtime lifecycle for the post-apply event layer (doc/agent-fipa-plan.md §7): `live`
            %% normally; `{replaying, Id}` while catching up (boot rebuild or a runtime gap-fill), so
            %% replay applies suppress live events and the started/ready boundaries carry a correlating Id.
            runtime_mode = live :: live | {replaying, reference()},
            ttl       = 30000 :: pos_integer(),
            vttl      = 2000 :: pos_integer(),    %% membership-verdict park budget (ms)
            max_proof_workers = 64 :: pos_integer(),
            max_scope_workers = 64 :: pos_integer(),
            proof_timeout_ms = 60000 :: pos_integer(),
            scope_timeout_ms = 60000 :: pos_integer(),
            scope_step_timeout_ms = 30000 :: pos_integer(),
            applied   = 0  :: log_index(),
            %% the attached quod_runtime: {Pid, Monitor, Floor}. The floor joins oldest_snapshot/2
            %% so MVCC history >= floor survives for the runtime's queued work; DOWN clears it.
            runtime_pin = none :: none | {pid(), reference(), log_index()},
            %% tx_id => {From, Bindings, HeightRead, TimerRef,
            %%           AsyncRequestId | none, TransactionSpan, SubmittedMonoMs}
            parked    = #{} :: #{binary() => {gen_server:from(), [map()], log_index(),
                                               reference(), term(), quod_trace:span_ctx(),
                                               integer()}},
            requests  :: term(),                 %% gen_statem async-request collection, labelled by tx_id
            %% membership verdicts parked until the KB reaches the proposal's parent height (Slot-1),
            %% then delivered to ReplyTo as {membership_verdict, Tag, Verdict}. Keyed by the unique Tag.
            %% Tag => {Slot, Change, ReplyTo, TimerRef}
            validations = #{} :: #{term() => {log_index(), term(), pid(), reference()}},
            applies   = 0, rejects = 0, proves = 0, conflicts = 0,
            park_timeouts = 0 :: non_neg_integer(),     %% writes still unresolved at their caller deadline
            %% Ref => #proof_worker{}
            workers   = #{} :: map(),
            %% WorkerMon => #scope_worker{}.  Co-hosted and remote scopes share
            %% the same worker/session ownership and MVCC pin accounting.
            scope_workers = #{} :: map(),
            scope_owners = #{} :: map(),
            scope_pids = #{} :: map(),
            scope_sessions = #{} :: map(),
            remote_scopes = #{} :: map(),
            remote_open_refs = #{} :: map(),
            remote_request_mrefs = #{} :: map(),
            remote_return_mrefs = #{} :: map(),
            remote_internal_refs = #{} :: map(),
            remote_peer_counts = #{} :: map(),
            scope_open_rates = #{} :: map(),
            reject_window = 0 :: integer(),
            reject_count = 0 :: non_neg_integer()}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(binary(), map()) -> {ok, pid()} | {error, term()}.
start_link(Ns, Config) ->
    gen_server:start_link(quod_reg:via({quod_prolog, Ns}), ?MODULE, {Ns, Config}, []).

-doc "Prove `Goal` (emitted from `CallerNs`) against namespace `TargetNs`.".
-spec prove(binary(), term(), binary()) ->
        {ok, [map()], log_index()} | {error, term()} | fail | {fail, [term()]}.
prove(TargetNs, Goal, CallerNs) ->
    case quod_reg:where({quod_prolog, TargetNs}) of
        undefined -> {error, no_such_namespace};
        Pid -> try gen_server:call(
                     Pid, {prove, Goal, CallerNs, quod_trace:context()}, infinity)
               catch exit:_ -> fail end
    end.

-doc "Read-only prove: like `prove/3` but a write goal is refused (`{error, read_only}`).".
-spec prove_ro(binary(), term(), binary()) ->
        {ok, [map()], log_index()} | {error, term()} | fail | {fail, [term()]}.
prove_ro(TargetNs, Goal, CallerNs) ->
    case quod_reg:where({quod_prolog, TargetNs}) of
        undefined -> {error, no_such_namespace};
        Pid -> try gen_server:call(Pid, {prove_ro, Goal, CallerNs}, infinity)
               catch exit:_ -> fail end
    end.

-doc """
Authorize and execute one node-local ontology lifecycle action.

Only fully-ground `create_ontology/2` and `join_ontology/3` actions targeting
`quod:root` are accepted. A bounded worker validates the committed root
transition, authorizes the engine-owned node principal before preparing input,
selects the declaration's desired state or prerequisites read-only, and invokes
only the prepared typed helper. A worker loss is outcome-unknown because the
namespace manager may already have accepted the operation; inspect
`ontology_join_state/2` before retrying.
""".
-spec run_action(binary(), term()) ->
        {ok, [map()], log_index()} | {error, term()} | fail | {fail, [term()]}.
run_action(TargetNs, Action) ->
    case validate_action_request(TargetNs, Action) of
        {ok, Structural} ->
            case quod_reg:where({quod_prolog, TargetNs}) of
                undefined -> {error, no_such_namespace};
                Pid ->
                    try gen_server:call(
                          Pid, {run_action, Action, Structural}, infinity)
                    catch exit:_ -> {error, outcome_unknown}
                    end
            end;
        {error, Reason} ->
            {error, Reason};
        {fail, Reason} ->
            {fail, [Reason]}
    end.

validate_action_request(TargetNs, Action) ->
    case quod_ontology:validate_action(Action) of
        {ok, Structural} when TargetNs =:= ?ROOT_NS ->
            {ok, Structural};
        {ok, _Structural} ->
            {fail,
             quod_ontology_predicates:failure_reason(Action, root_only)};
        {error, invalid_action} ->
            {error, invalid_action};
        {error, Reason} when TargetNs =:= ?ROOT_NS ->
            {fail,
             quod_ontology_predicates:failure_reason(Action, Reason)};
        {error, _Reason} ->
            {fail,
             quod_ontology_predicates:failure_reason(Action, root_only)}
    end.

lifecycle_principal(NodeKey)
  when is_binary(NodeKey), byte_size(NodeKey) =:= 32 ->
    {ok, {node, NodeKey}};
lifecycle_principal(_InvalidEngineIdentity) ->
    error.

-doc "The committed log index this kb has applied (the freshness height for a read).".
-spec applied(binary()) -> log_index().
applied(Ns) ->
    case quod_reg:where({quod_prolog, Ns}) of
        undefined -> 0;
        _Pid      -> maps:get(applied, stats(Ns), 0)
    end.

-doc """
Apply a committed entry (called by `quod_simplex`, strictly in index order). This is an async
cast so durable consensus is not serialized behind proof execution in this process. Write
submission itself uses OTP asynchronous `gen_statem` requests, so the fact engine can continue
proving and consuming commits while append calls are outstanding. The OCC verdict is delivered
straight to the parked client here; a forward gap asks `quod_simplex` to re-drive.

`Origin` is `live` for a freshly-finalized commit and `replay` for a rebuild/catch-up re-drive.
It is decided by the `quod_simplex` path that obtained the block, never inferred here: a `live`
apply publishes the post-apply `applied_live` event (`doc/agent-fipa-plan.md` §7), a `replay` apply
rebuilds D only. Replay runs also emit `replay_started`/`replay_ready` lifecycle boundaries.
""".
-spec apply_block(binary(), pos_integer(), entry_data(), live | replay) -> ok.
apply_block(Ns, Index, Change, Origin) ->
    gen_server:cast(quod_reg:via({quod_prolog, Ns}), {apply_block, Index, Change, Origin}).

-doc "Signal that the initial rebuild is complete and proves may be served.".
-spec mark_ready(binary()) -> ok.
mark_ready(Ns) -> gen_server:cast(quod_reg:via({quod_prolog, Ns}), mark_ready).

-doc """
Attach the calling process as this namespace's runtime (`m:quod_runtime`, agent-fipa-plan §7/§8).

On success the caller is monitored and becomes the single pinned runtime: every LIVE block's
post-commit outcome flush sends it `{applied_live, Env, Est}` — `Est` being the committed
snapshot handle at the envelope's height — and its **floor** (initially the current applied
height, raised via `runtime_floor/2`) joins `oldest_snapshot/2`, so MVCC history at or above
the floor survives until the runtime is done with it. The pin is cleared by `DOWN`, so a dead
runtime can never block history pruning.

Refused (`{error, not_ready}`) while the KB is unready or replaying: a pin held across a long
rebuild would retain every fact version since the pin height (unbounded history growth), and
the runtime reconciles from a fresh snapshot at the ready edge anyway. Re-attaching — same or
a restarted runtime process — replaces the pin at the newest applied height.
""".
-spec attach_runtime(binary()) -> {ok, tuple(), log_index()} | {error, not_ready}.
attach_runtime(Ns) ->
    gen_server:call(quod_reg:via({quod_prolog, Ns}), {attach_runtime, self()}, infinity).

-doc """
Monotonically raise the attached runtime's snapshot floor to `Height` (its oldest still-needed
snapshot: pending ordered-tier work or queued heavy-job revision). Ignored unless cast by the
currently pinned runtime; lowering is impossible by construction.
""".
-spec runtime_floor(binary(), log_index()) -> ok.
runtime_floor(Ns, Height) ->
    gen_server:cast(quod_reg:via({quod_prolog, Ns}), {runtime_floor, self(), Height}).

-doc "Release this process's runtime snapshot pin after all of its snapshot readers stopped.".
-spec runtime_detach(binary()) -> ok.
runtime_detach(Ns) ->
    gen_server:cast(quod_reg:via({quod_prolog, Ns}), {runtime_detach, self()}).

-doc """
Synchronous no-op barrier: returns once every message already in this kb's queue — in
particular a burst of `apply_block/4` casts — has been consumed. `quod_simplex`'s streamed
replay calls this every few hundred casts so a long rebuild can't flood the mailbox with
the whole log (backpressure); the applies themselves must stay casts (see `apply_block/4`).
Deadlock-safe from the replay: it only runs while this kb is UNREADY, and an unready kb
refuses proves, so it can never be parked in an `append` back into `quod_simplex`.
""".
-spec sync(binary()) -> ok.
sync(Ns) -> gen_server:call(quod_reg:via({quod_prolog, Ns}), sync, 30000).

-doc """
Ask this kb to judge a committee-changing `Change` proposed for `Slot`, and deliver the verdict
ASYNCHRONOUSLY as `{membership_verdict, Tag, valid | {invalid, Reason} | abstain}` to `ReplyTo`.

A **cast** on purpose: membership validation can require Prolog work while the consensus statem
is handling the proposal. Neither process waits synchronously for the other; the verdict returns
as a correlated message.

The verdict is judged against the KB **as of the proposal's parent** (`Slot-1`), so every honest node
reaches the same verdict deterministically: if the kb is already there it is delivered now; if it is
behind, the request parks until `apply_block` reaches `Slot-1` (or a short fixed TTL — `validation_ttl_ms`,
on the order of Δ — reaps it to `abstain`); if the kb is already past the slot, the slot resolved without
us — `abstain`. Re-issuing the same `Tag` supersedes a still-parked request for it.
""".
-spec request_membership_verdict(binary(), term(), pos_integer(), pid(), term()) -> ok.
request_membership_verdict(Ns, Change, Slot, ReplyTo, Tag) ->
    gen_server:cast(quod_reg:via({quod_prolog, Ns}), {membership_verdict_req, Change, Slot, ReplyTo, Tag}).

stats(Ns) ->
    try gen_server:call(quod_reg:via({quod_prolog, Ns}), get_stats, 1000)
    catch exit:_ -> #{} end.

namespaces() -> gproc:select([{{{n, l, {quod_prolog, '$1'}}, '_', '_'}, [], ['$1']}]).

positive_limit(_Name, Value) when is_integer(Value), Value > 0 -> Value;
positive_limit(Name, Value) -> error({bad_config, {Name, Value}}).

%%%===================================================================
%%% gen_server
%%%===================================================================

init({Ns, Config}) ->
    Cfg  = maps:merge(?DEFAULTS, Config),
    MaxProofWorkers = positive_limit(max_proof_workers, maps:get(max_proof_workers, Cfg)),
    MaxScopeWorkers = positive_limit(
                        max_scope_workers,
                        maps:get(max_scope_workers, Cfg)),
    S = #s{ns = Ns, self = maps:get(node_id, Cfg), est = build_kb(),
           requests = gen_statem:reqids_new(),
           ttl = maps:get(transaction_ttl_ms, Cfg),
           vttl = maps:get(validation_ttl_ms, Cfg),
           max_proof_workers = MaxProofWorkers,
           max_scope_workers = MaxScopeWorkers,
           proof_timeout_ms = positive_limit(proof_timeout_ms,
                                             maps:get(proof_timeout_ms, Cfg)),
           scope_timeout_ms = positive_limit(
                                scope_timeout_ms,
                                maps:get(scope_timeout_ms, Cfg)),
           scope_step_timeout_ms = positive_limit(
                                     scope_step_timeout_ms,
                                     maps:get(scope_step_timeout_ms, Cfg)),
           ready = false},
    true = quod_reg:subscribe(
             {channel, quod_scope_wire:request_channel(Ns)}),
    %% Ask quod_simplex (already up under the per-ns sub-sup) to replay committed blocks
    %% into this fresh kb; it casts mark_ready when the kb is caught up. Async, so
    %% init does not block on a callback.
    case quod_reg:where({quod_simplex, Ns}) of
        undefined -> ok;
        _Pid      -> catch quod_simplex:rebuild(Ns)
    end,
    {ok, S}.

%% Proves are refused until the rebuild has caught the kb up (never a half-built read).
%% A ready engine SPAWNS a worker per proof and returns immediately — the engine never
%% blocks on a proof (doc/inter-ontology.md §4.1); the worker reports its result back
%% to this engine, which owns the single reply path to the caller.
handle_call({prove, _G, _C, _TraceCtx}, _From, S = #s{ready = false}) ->
    {reply, {error, rebuilding}, S};
handle_call({prove, _Goal, _CallerNs, _TraceCtx}, _From,
            S = #s{workers = Workers, max_proof_workers = Max})
  when map_size(Workers) >= Max ->
    {reply, {error, busy}, S};
handle_call({prove, Goal, CallerNs, TraceCtx}, From, S) ->
    {noreply, spawn_proof(prove, Goal, CallerNs, From, TraceCtx, S)};
%% Read-only prove for trusted local subsystems: identical to a read, but a goal
%% that stages a write is refused instead of submitted. Reads carry the
%% committed height of the frozen view and are gated on readiness like prove.
handle_call({prove_ro, _G, _C}, _From, S = #s{ready = false}) ->
    {reply, {error, rebuilding}, S};
handle_call({prove_ro, _Goal, _CallerNs}, _From,
            S = #s{workers = Workers, max_proof_workers = Max})
  when map_size(Workers) >= Max ->
    {reply, {error, busy}, S};
handle_call({prove_ro, Goal, CallerNs}, From, S) ->
    {noreply, spawn_proof(prove_ro, Goal, CallerNs, From, otel_ctx:new(), S)};
%% Lifecycle actions share the proof-worker budget and readiness gate. The
%% node principal is derived here from engine state, never from the request.
handle_call({run_action, _Action, _Structural}, _From,
            S = #s{ready = false}) ->
    {reply, {error, rebuilding}, S};
handle_call({run_action, _Action, _Structural}, _From,
            S = #s{workers = Workers, max_proof_workers = Max})
  when map_size(Workers) >= Max ->
    {reply, {error, busy}, S};
handle_call({run_action, Action, Structural}, From,
            S = #s{ns = Ns, self = Self}) ->
    case lifecycle_principal(Self) of
        {ok, Principal} ->
            {noreply,
             spawn_proof(action, {Action, Structural}, Ns, From,
                         otel_ctx:new(),
                         Principal, S)};
        error ->
            {reply,
             {fail,
              [quod_ontology_predicates:failure_reason(
                 Action, not_authorized)]},
             S}
    end;

handle_call(get_stats, _From, S) ->
    #est{db = #db{ref = StoreRef}} = S#s.est,
    {reply, #{applied   => S#s.applied,  applies => S#s.applies,
              rejects   => S#s.rejects,  proves  => S#s.proves,
              conflicts => S#s.conflicts,
              parked    => map_size(S#s.parked),        %% in-flight writes awaiting commit (liveness gauge)
              park_timeouts => S#s.park_timeouts,       %% final outcome unknown when caller deadline elapsed
              proof_workers => map_size(S#s.workers),
              scope_workers => map_size(S#s.scope_workers),
              remote_scopes => map_size(S#s.remote_scopes),
              kb_memory_words => quod_erlog_db_mvcc:memory_words(StoreRef),
              kb_history_predicates => quod_erlog_db_mvcc:history_predicates(StoreRef)}, S};

handle_call(sync, _From, S) -> {reply, ok, S};   %% replay backpressure barrier (sync/1)

%% One co-hosted scope session per origin proof and pinned ontology identity.
%% The origin pid is derived from `From`; it is never accepted from the payload.
handle_call({scope_open, _ScopeId, _ProofId, _Anchor, _ReadOnly, _DeadlineMs}, _From,
            S = #s{ready = false, ns = Ns}) ->
    {reply, {error, {ontology_rebuilding, Ns}}, S};
handle_call({scope_open, ScopeId, ProofId, Anchor, ReadOnly, DeadlineMs}, From, S)
  when is_binary(ScopeId), byte_size(ScopeId) =:= 16,
       is_binary(ProofId), byte_size(ProofId) =:= 32,
       is_binary(Anchor), byte_size(Anchor) =:= 32,
       is_boolean(ReadOnly), is_integer(DeadlineMs) ->
    Origin = element(1, From),
    Mode = case ReadOnly of true -> read_only; false -> read_write end,
    case scope_admission_reason(Mode, Anchor, S) of
        ok ->
            open_scope_session(
              Origin, ScopeId, ProofId, Anchor, ReadOnly, DeadlineMs, S);
        {error, Reason} ->
            {reply, {error, Reason}, S}
    end;
handle_call({scope_open, _ScopeId, _ProofId, _Anchor, _ReadOnly, _DeadlineMs},
            _From, S) ->
    {reply, {error, bad_request}, S};

%% Runtime attach (attach_runtime/1). Ready+live only — see the API doc for why a pin must
%% never span a rebuild. Replacing an existing pin demonitors it first (a restarted runtime
%% re-attaches before its predecessor's DOWN is processed).
handle_call({attach_runtime, Pid}, _From,
            S = #s{ready = true, runtime_mode = live, est = Est, applied = A}) ->
    S1 = clear_runtime_pin(S),
    MRef = erlang:monitor(process, Pid),
    {reply, {ok, Est, A}, S1#s{runtime_pin = {Pid, MRef, A}}};
handle_call({attach_runtime, _Pid}, _From, S) ->
    {reply, {error, not_ready}, S};
handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.

handle_cast({apply_block, Index, Change, Origin}, S0) ->
    S1 = apply_committed(Index, Change, Origin, S0),
    %% Drive the replay lifecycle from whether the apply ACTUALLY advanced the committed height, not
    %% from the raw origin: an already-applied no-op (`Index =< applied`) or a forward gap
    %% (`Index > applied+1`, which bails to rebuild) must never emit a false boundary.
    {noreply, note_origin(Origin, S1#s.applied > S0#s.applied, S0#s.applied, S1)};
%% Workers report through the engine so exactly one process owns reply and lifecycle state.
handle_cast({proof_result, Ref, Kind, Goal, CallerNs, Result}, S) ->
    {noreply, finish_proof(Ref, Kind, Goal, CallerNs, Result, S)};
%% mark_ready closes any replay interval before serving proves or resuming steady-state handling.
%% Simplex emits it after boot, member recovery, and observer anti-entropy; the first later live
%% apply can also close a replay interval, handled in note_origin/4.
handle_cast(mark_ready, S = #s{runtime_mode = {replaying, Id}, ns = Ns, applied = H}) ->
    publish_runtime(Ns, {replay_ready, Id, H}),
    {noreply, S#s{ready = true, runtime_mode = live}};
%% Quiet-boot ready edge (agent-fipa-plan §7 as-built): a fresh/empty-log boot never opens a
%% replay run, so without this clause the FIRST ready transition would be unobservable and a
%% waiting runtime would hang. Guarded on the actual false→true edge — rebuild handshakes
%% re-cast mark_ready, and an unguarded `boot` edge (a constant, not a RecoveryId) would cost
%% the runtime a spurious full reconciliation each time.
handle_cast(mark_ready, S = #s{ready = false, ns = Ns, applied = H}) ->
    publish_runtime(Ns, {replay_ready, boot, H}),
    {noreply, S#s{ready = true}};
handle_cast(mark_ready, S) -> {noreply, S};
%% Monotone floor raise from the attached runtime (runtime_floor/2); a stale or foreign
%% caller's cast is ignored, and lowering is impossible by construction.
handle_cast({runtime_floor, Pid, H}, S = #s{runtime_pin = {Pid, MRef, F}}) when H > F ->
    {noreply, S#s{runtime_pin = {Pid, MRef, H}}};
handle_cast({runtime_floor, _Pid, _H}, S) -> {noreply, S};
%% Replay detachment is accepted only from the attached runtime. The runtime sends this after
%% every runner that could still read the pinned snapshot is confirmed dead; until then the pin
%% deliberately survives replay commits, preventing MVCC GC from invalidating an active read.
handle_cast({runtime_detach, Pid}, S = #s{runtime_pin = {Pid, _MRef, _F}}) ->
    {noreply, clear_runtime_pin(S)};
handle_cast({runtime_detach, _Pid}, S) -> {noreply, S};
%% A membership-verdict request (request_membership_verdict/5): judge it against the KB at the
%% proposal's parent height (Slot-1), delivering now or parking until the kb catches up.
handle_cast({membership_verdict_req, Change, Slot, ReplyTo, Tag}, S) ->
    {noreply, request_verdict(Change, Slot, ReplyTo, Tag, S)};
handle_cast(_Msg, S)       -> {noreply, S}.

%% A proof worker finished (normal: it already replied / handed off) or crashed
%% (abnormal: the caller still waits — reply the distinct error here). MUST come
%% before the check_response fallback clause.
handle_info(Info = {'DOWN', MRef, process, _Pid, Reason}, S) ->
    case handle_worker_down(MRef, Reason, S) of
        unhandled -> handle_response_info(Info, S);
        Reply     -> Reply
    end;
%% A proof outlived its kill budget: end it. The DOWN above returns the
%% proof-kind-specific timeout result.
handle_info({proof_kill, Ref, Token}, S = #s{workers = W}) ->
    case W of
        #{Ref := #proof_worker{pid = Pid, token = Token}} -> kill_worker(Pid);
        _ -> ok
    end,
    {noreply, S};
%% Scope derivation is guarded outside the worker so cancellation and the
%% target-owned execution budget remain preemptive even while Erlog is inside
%% an unbounded goal.
handle_info({scope_step_started, Pid}, S = #s{scope_pids = Pids}) ->
    case maps:get(Pid, Pids, undefined) of
        WorkerMRef when is_reference(WorkerMRef) ->
            {noreply, arm_scope_step(WorkerMRef, S)};
        _ -> {noreply, S}
    end;
handle_info({scope_step_finished, Pid}, S = #s{scope_pids = Pids}) ->
    case maps:get(Pid, Pids, undefined) of
        WorkerMRef when is_reference(WorkerMRef) ->
            {noreply, disarm_scope_step(WorkerMRef, S)};
        _ -> {noreply, S}
    end;
handle_info({scope_step_kill, WorkerMRef, Token},
            S = #s{scope_workers = Workers}) ->
    case maps:get(WorkerMRef, Workers, undefined) of
        #scope_worker{token = Token} ->
            {noreply, expire_scope_worker(active, WorkerMRef, S)};
        _ -> {noreply, S}
    end;
handle_info({scope_lifetime_kill, WorkerMRef, Token},
            S = #s{scope_workers = Workers}) ->
    case maps:get(WorkerMRef, Workers, undefined) of
        #scope_worker{lifetime_token = Token} ->
            {noreply, expire_scope_worker(idle, WorkerMRef, S)};
        _ -> {noreply, S}
    end;
%% One authenticated, fixed-version command stream owns every remote scope for
%% this ontology.  The envelope is decoded once here; the goal remains opaque
%% until exact binding, link, sequence, readiness, rate and quota checks pass.
handle_info({quod_message, {{PeerKey, Endpoint}, RequestLink}, Channel, Payload},
            S = #s{ns = Ns}) ->
    case Channel =:= quod_scope_wire:request_channel(Ns) of
        true ->
            {noreply,
             handle_scope_frame(
               PeerKey, Endpoint, RequestLink, Payload, S)};
        false -> handle_response_info(
                   {quod_message,
                    {{PeerKey, Endpoint}, RequestLink}, Channel, Payload},
                   S)
    end;
handle_info({link_up, OpenRef, PeerKey, ReturnChannel, ReturnLink}, S) ->
    {noreply,
     handle_scope_return_link(
       OpenRef, PeerKey, ReturnChannel, ReturnLink, S)};
handle_info({link_error, OpenRef, PeerKey, ReturnChannel}, S) ->
    {noreply,
     handle_scope_return_error(OpenRef, PeerKey, ReturnChannel, S)};
handle_info({remote_scope_expire, Binding, Token}, S) ->
    {noreply, expire_remote_scope(Binding, Token, S)};
handle_info({scope_reply, ScopePid, ProofId, SessionRef, InternalRef, Reply}, S) ->
    {noreply,
     handle_remote_scope_reply(
       ScopePid, ProofId, SessionRef, InternalRef, Reply, S)};
handle_info(Message = {proof_nested_open, _, _, _, _, _, _, _, _}, S) ->
    {noreply, handle_remote_controller_request(Message, S)};
handle_info(Message = {proof_nested_next, _, _, _, _, _, _, _}, S) ->
    {noreply, handle_remote_controller_request(Message, S)};
handle_info(Message = {proof_nested_cancel, _, _, _, _, _}, S) ->
    {noreply, handle_remote_controller_request(Message, S)};
handle_info(Message = {proof_tx_request, _, _, _, _, _, _}, S) ->
    {noreply, handle_remote_controller_request(Message, S)};
%% A parked write whose verdict never arrived (leader change / lost block): stop
%% retaining its caller, but do NOT claim failure. Consensus cannot cancel a change
%% that may already be proposed; it can still finalize after this local deadline.
%% Return its explorer handle so clients can inspect the eventual outcome without
%% resubmitting a possibly non-idempotent operation.
handle_info({park_timeout, Tx}, S = #s{parked = P}) ->
    case maps:take(Tx, P) of
        {{From, _B, _H, _TRef, ReqId, SpanCtx, _T0}, P1} ->
            Outcome = {error, {outcome_unknown, Tx}},
            quod_trace:finish_span(SpanCtx, Outcome),
            gen_server:reply(From, Outcome),
            {noreply, S#s{parked = P1, requests = abandon_request(ReqId, S#s.requests),
                          park_timeouts = S#s.park_timeouts + 1}};
        error -> {noreply, S}
    end;
%% A parked membership verdict whose parent height never arrived in time (the kb is too far behind, or
%% the slot was skipped before we caught up): reap it and deliver `abstain` so the voter stops waiting.
handle_info({validation_timeout, Tag}, S = #s{validations = V}) ->
    case maps:take(Tag, V) of
        {{_Slot, _Change, ReplyTo, _TRef}, V1} ->
            deliver_verdict(ReplyTo, Tag, abstain),
            {noreply, S#s{validations = V1}};
        error -> {noreply, S}
    end;
%% `send_request/2` gives us a non-blocking gen_statem call without a helper process per
%% transaction. Responses are matched through the opaque request-id collection and labelled
%% with their tx id. A successful append still resolves through ordered `apply_block`; only a
%% definite consensus rejection releases the parked client here.
handle_info(Info, S) ->
    handle_response_info(Info, S).

open_scope_session(Origin, ScopeId, ProofId, Anchor, ReadOnly, DeadlineMs,
                   S = #s{scope_sessions = Sessions}) ->
    Key = {Origin, ProofId, ScopeId},
    case maps:find(Key, Sessions) of
        {ok, {Handle, WorkerMRef, ExistingReadOnly}} ->
            case quod_scope_session:identity(Handle) of
                {Ns, ExistingAnchor} when ExistingAnchor =/= Anchor ->
                    {reply, {error, {anchor_conflict, Ns}}, S};
                {_Ns, Anchor} when ExistingReadOnly =/= ReadOnly ->
                    {reply, {error, scope_mode_conflict}, S};
                {_Ns, Anchor} ->
                    case is_process_alive(quod_scope_session:pid(Handle)) of
                        true -> {reply, {ok, Handle}, S};
                        false -> open_new_scope_session(
                                   Origin, ScopeId, ProofId, Anchor, ReadOnly,
                                   DeadlineMs,
                                   drop_scope_worker(WorkerMRef, S))
                    end
            end;
        error ->
            open_new_scope_session(
              Origin, ScopeId, ProofId, Anchor, ReadOnly, DeadlineMs, S)
    end.

open_new_scope_session(Origin, ScopeId, ProofId, Anchor, ReadOnly, DeadlineMs,
                       S = #s{ns = Ns}) ->
    case scope_capacity_available(S) of
        false ->
            {reply, {error, {ontology_busy, Ns}}, S};
        true ->
            start_new_scope_session(
              Origin, ScopeId, ProofId, Anchor, ReadOnly, DeadlineMs, S)
    end.

start_new_scope_session(Origin, ScopeId, ProofId, Anchor, ReadOnly, DeadlineMs,
                        S = #s{ns = Ns, est = Est, applied = Height,
                               scope_sessions = Sessions}) ->
    case local_node_principal() of
        {ok, Principal} ->
            Now = quod_time:mono_ms(),
            ScopeLifetime = target_scope_lifetime_ms(
                              max(0, DeadlineMs - Now),
                              S#s.scope_timeout_ms),
            ScopeDeadline = Now + ScopeLifetime,
            {Handle, WorkerMRef} = quod_scope_session:start(
                                     ScopeId, ProofId, Origin,
                                     Ns, Anchor, Height,
                                     Est, self(),
                                     #{read_only => ReadOnly,
                                       principal => Principal,
                                       deadline_ms => ScopeDeadline}),
            Pid = quod_scope_session:pid(Handle),
            OwnerMRef = monitor(process, Origin),
            Key = {Origin, ProofId, ScopeId},
            Worker = new_scope_worker(
                       Pid, WorkerMRef, OwnerMRef, Key, Height,
                       ScopeLifetime),
            {reply, {ok, Handle},
             bump_proves(
               S#s{scope_workers =
                       (S#s.scope_workers)#{WorkerMRef => Worker},
                   scope_owners =
                       (S#s.scope_owners)#{OwnerMRef => WorkerMRef},
                   scope_pids = (S#s.scope_pids)#{Pid => WorkerMRef},
                   scope_sessions = Sessions#{
                     Key => {Handle, WorkerMRef, ReadOnly}}})};
        error ->
            {reply, {error, {protocol_error, session_binding}}, S}
    end.

local_node_principal() ->
    case application:get_env(quod, node_pubkey) of
        {ok, <<_:256>> = Principal} -> {ok, Principal};
        _ -> error
    end.

%% ------------------------------------------------------------------
%% Authenticated remote scope ingress (hard-break scope wire)
%% ------------------------------------------------------------------

handle_scope_frame(PeerKey, Endpoint, RequestLink, Payload, S)
  when is_binary(PeerKey), is_pid(RequestLink) ->
    case quod_scope_wire:decode_request(Payload) of
        {ok, Probe = {scope_identity_probe, _, _, _}} ->
            handle_scope_identity_probe(PeerKey, Endpoint, Probe, S);
        {ok, Command = {scope_command, _, _, _, _, _}} ->
            handle_scope_command(
              PeerKey, Endpoint, RequestLink, Command, S);
        {error, _Reason} ->
            %% An undecodable frame has no authenticated session binding to
            %% which a reply could safely be correlated.
            S
    end;
handle_scope_frame(_PeerKey, _Endpoint, _RequestLink, _Payload, S) ->
    S.

handle_scope_identity_probe(
  PeerKey, Endpoint,
  {scope_identity_probe, RequestId, PeerKey, Ns},
  S = #s{ns = Ns, self = TargetKey, ready = true, est = Est})
  when is_binary(TargetKey), byte_size(TargetKey) =:= 32 ->
    case {quod_quic:valid_endpoint(Endpoint),
          quod_simplex:genesis_hash(Ns)} of
        {true, <<_:256>> = Anchor} ->
            Role = case lists:member(
                          TargetKey,
                          quod_committee_predicates:admitted_pubkeys(Est)) of
                       true -> validator;
                       false -> observer
                   end,
            Response = {scope_identity_response, RequestId, TargetKey,
                        {Ns, Anchor}, Role},
            case quod_scope_wire:encode_identity_response(Response) of
                {ok, Encoded} ->
                    %% Discovery is a bounded authenticated exchange only: no
                    %% scope, proof worker, session, timer or monitor exists.
                    quod_quic:send_pinned(
                      PeerKey, Endpoint,
                      quod_scope_wire:return_channel(PeerKey), Encoded),
                    S;
                {error, _} -> S
            end;
        _ -> S
    end;
handle_scope_identity_probe(_PeerKey, _Endpoint, _Probe, S) ->
    S.

handle_scope_command(
  PeerKey, Endpoint, RequestLink,
  {scope_command, Binding, CommandSeq, RequestId, RemainingMs, Operation},
  S = #s{remote_scopes = Remote}) ->
    case maps:find(Binding, Remote) of
        error when Operation =:= scope_open ->
            handle_remote_scope_open(
              PeerKey, Endpoint, RequestLink, Binding,
              CommandSeq, RequestId, RemainingMs, S);
        error ->
            reject_unknown_scope(
              PeerKey, Endpoint, Binding, CommandSeq, RequestId, S);
        {ok, Scope} ->
            handle_bound_scope_command(
              PeerKey, RequestLink, Binding, CommandSeq,
              RequestId, RemainingMs, Operation, Scope, S)
    end.

handle_remote_scope_open(
  PeerKey, Endpoint, RequestLink,
  Binding = {scope_binding, OriginKey, TargetKey, _ProofId, _ScopeId,
             _OriginIdentity, {Ns, Anchor}, Mode},
  CommandSeq, RequestId, RemainingMs,
  S = #s{ns = Ns, self = TargetKey}) ->
    case PeerKey =:= OriginKey andalso
         CommandSeq =:= 1 andalso RemainingMs > 0 andalso
         quod_quic:valid_endpoint(Endpoint) of
        false ->
            S;
        true ->
            case remote_open_reason(Mode, Anchor, PeerKey, S) of
                ok ->
                    case charge_scope_open(PeerKey, {Ns, Anchor}, S) of
                        {ok, S1} ->
                            begin_remote_scope_open(
                              PeerKey, Endpoint, RequestLink, Binding,
                              RequestId, RemainingMs, S1);
                        {error, S1} ->
                            reject_scope_open(
                              PeerKey, Endpoint, Binding, RequestId,
                              {ontology_rate_limited, Ns}, S1)
                    end;
                {error, Reason} ->
                    reject_scope_open(
                      PeerKey, Endpoint, Binding, RequestId, Reason, S)
            end
    end;
handle_remote_scope_open(
  _PeerKey, _Endpoint, _RequestLink, _Binding,
  _CommandSeq, _RequestId, _RemainingMs, S) ->
    S.

remote_open_reason(Mode, Anchor, PeerKey,
                   S = #s{ns = Ns,
                          remote_peer_counts = PeerCounts}) ->
    case scope_admission_reason(Mode, Anchor, S) of
        ok ->
            case {scope_capacity_available(S),
                  maps:get(PeerKey, PeerCounts, 0) <
                      ?QUOD_MAX_ROUTER_SCOPES_PER_PEER} of
                {false, _} -> {error, {ontology_busy, Ns}};
                {_, false} ->
                    {error,
                     {scope_limit_exceeded,
                      ?QUOD_MAX_ROUTER_SCOPES_PER_PEER}};
                {true, true} -> ok
            end;
        {error, _} = Error -> Error
    end.

scope_capacity_available(
  #s{max_scope_workers = Max, scope_workers = Workers,
     remote_scopes = Remote}) ->
    scope_capacity_available(
      Max, map_size(Workers), pending_remote_scope_count(Remote)).

scope_capacity_available(Max, Active, Pending) ->
    Active + Pending < Max.

pending_remote_scope_count(Remote) ->
    maps:fold(
      fun(_Binding, #remote_scope{worker_mref = undefined}, Count) ->
              Count + 1;
         (_Binding, _Scope, Count) ->
              Count
      end, 0, Remote).

scope_admission_reason(_Mode, Anchor, #s{ns = Ns})
  when not is_binary(Anchor); byte_size(Anchor) =/= 32 ->
    {error, {anchor_conflict, Ns}};
scope_admission_reason(Mode, Anchor,
                       #s{ns = Ns, ready = Ready, self = Self, est = Est,
                          applied = Applied}) ->
    case quod_simplex:genesis_hash(Ns) of
        Anchor when not Ready -> {error, {ontology_rebuilding, Ns}};
        Anchor when Mode =:= read_only -> ok;
        Anchor when Mode =:= read_write ->
            case lists:member(
                   Self,
                   quod_committee_predicates:admitted_pubkeys(Est)) of
                true -> ok;
                false ->
                    %% The peer-visible error is deliberately the same as a
                    %% policy refusal. Say here which of the two it was, or a
                    %% stale route hint is indistinguishable from a denial.
                    logger:warning(
                      "quod_prolog[~s]: refused a writable scope — this node "
                      "is not an admitted validator of it (applied=~p)",
                      [Ns, Applied]),
                    {error, {not_allowed, Ns}}
            end;
        <<_:256>> -> {error, {anchor_conflict, Ns}};
        undefined -> {error, {ontology_rebuilding, Ns}}
    end.

charge_scope_open(PeerKey, Identity,
                  S = #s{scope_open_rates = Rates0}) ->
    Now = quod_time:mono_ms(),
    Key = {PeerKey, Identity},
    Rates = maybe_prune_scope_open_rates(Now, Rates0),
    case maps:find(Key, Rates) of
        {ok, {Tokens0, LastRefill, _LastSeen}} ->
            Capacity = ?QUOD_SCOPE_OPEN_RATE_BURST * 1000,
            Tokens = min(
                       Capacity,
                       Tokens0 +
                           max(0, Now - LastRefill) *
                               ?QUOD_SCOPE_OPEN_RATE_PER_SECOND),
            case Tokens >= 1000 of
                true ->
                    {ok,
                     S#s{scope_open_rates = Rates#{
                       Key => {Tokens - 1000, Now, Now}}}};
                false ->
                    {error,
                     S#s{scope_open_rates = Rates#{
                       Key => {Tokens, Now, Now}}}}
            end;
        error when map_size(Rates) >= ?QUOD_SCOPE_OPEN_MAX_BUCKETS ->
            {error, S#s{scope_open_rates = Rates}};
        error ->
            Tokens = (?QUOD_SCOPE_OPEN_RATE_BURST - 1) * 1000,
            {ok, S#s{scope_open_rates = Rates#{Key => {Tokens, Now, Now}}}}
    end.

maybe_prune_scope_open_rates(Now, Rates)
  when map_size(Rates) >= ?QUOD_SCOPE_OPEN_MAX_BUCKETS ->
    maps:filter(
      fun(_Key, {_Tokens, _LastRefill, LastSeen}) ->
          Now - LastSeen < ?QUOD_SCOPE_OPEN_BUCKET_IDLE_MS
      end, Rates);
maybe_prune_scope_open_rates(_Now, Rates) ->
    Rates.

begin_remote_scope_open(PeerKey, Endpoint, RequestLink, Binding,
                        RequestId, RemainingMs,
                        S = #s{scope_timeout_ms = ScopeTimeout,
                               remote_scopes = Remote,
                               remote_open_refs = OpenRefs,
                               remote_request_mrefs = RequestRefs,
                               remote_peer_counts = PeerCounts}) ->
    ReturnChannel = quod_scope_wire:return_channel(PeerKey),
    OpenRef = quod_quic:open_link_pinned(
                PeerKey, Endpoint, ReturnChannel),
    RequestMRef = monitor(process, RequestLink),
    Lifetime = target_scope_lifetime_ms(RemainingMs, ScopeTimeout),
    Deadline = quod_time:mono_ms() + Lifetime,
    Token = make_ref(),
    Timer = erlang:send_after(
              Lifetime, self(), {remote_scope_expire, Binding, Token}),
    Scope = #remote_scope{
               binding = Binding, peer_key = PeerKey,
               request_link = RequestLink, request_mref = RequestMRef,
               return_channel = ReturnChannel, open_ref = OpenRef,
               open_request_id = RequestId,
               last_request_id = RequestId,
               lifetime_timer = Timer, lifetime_token = Token,
               deadline_ms = Deadline},
    S#s{remote_scopes = Remote#{Binding => Scope},
        remote_open_refs = OpenRefs#{OpenRef => Binding},
        remote_request_mrefs = RequestRefs#{RequestMRef => Binding},
        remote_peer_counts = PeerCounts#{
          PeerKey => maps:get(PeerKey, PeerCounts, 0) + 1}}.

reject_unknown_scope(
  PeerKey, Endpoint,
  Binding = {scope_binding, PeerKey, TargetKey, _ProofId, _ScopeId,
             _OriginIdentity, {Ns, _Anchor}, _Mode},
  CommandSeq, RequestId, S = #s{ns = Ns, self = TargetKey})
  when CommandSeq >= 1 ->
    reject_scope_open(
      PeerKey, Endpoint, Binding, RequestId,
      {protocol_error, session_binding}, S);
reject_unknown_scope(_PeerKey, _Endpoint, _Binding, _CommandSeq,
                     _RequestId, S) ->
    S.

reject_scope_open(PeerKey, Endpoint, Binding, RequestId, Reason,
                  S = #s{reject_window = Window, reject_count = Count}) ->
    Now = quod_time:mono_ms(),
    case Window =:= 0 orelse Now - Window >= 1000 of
        true ->
            send_scope_rejection(
              PeerKey, Endpoint, Binding, RequestId, Reason),
            S#s{reject_window = Now, reject_count = 1};
        false when Count < ?MAX_SCOPE_REJECTS_PER_SECOND ->
            send_scope_rejection(
              PeerKey, Endpoint, Binding, RequestId, Reason),
            S#s{reject_count = Count + 1};
        false ->
            S
    end.

send_scope_rejection(PeerKey, Endpoint, Binding, RequestId, Reason) ->
    Event = {scope_event, Binding, 1, RequestId, 1, 0, false,
             {scope_error, Reason}},
    case quod_scope_wire:encode_event(Event) of
        {ok, Encoded} ->
            quod_quic:send_pinned(
              PeerKey, Endpoint,
              quod_scope_wire:return_channel(PeerKey), Encoded);
        {error, _} ->
            ok
    end.

handle_bound_scope_command(
  PeerKey, RequestLink, Binding, CommandSeq, RequestId, RemainingMs,
  Operation,
  Scope = #remote_scope{peer_key = PeerKey,
                        request_link = RequestLink,
                        next_command_seq = CommandSeq,
                        deadline_ms = Deadline}, S) ->
    case {scope_command_budget_valid(Operation, RemainingMs, Deadline),
          binding_admission_reason(Binding, S)} of
        {true, ok} ->
            Scope1 = accept_scope_command(
                       Operation, RequestId, CommandSeq, Scope),
            execute_remote_scope_command(
              Binding, Operation, RequestId, CommandSeq,
              put_remote_scope(Scope1, S));
        {false, _} ->
            poison_remote_scope(
              Binding, RequestId, CommandSeq,
              {scope_expired, target_namespace(Binding)}, S);
        {true, {error, Reason}} ->
            poison_remote_scope(
              Binding, RequestId, CommandSeq, Reason, S)
    end;
handle_bound_scope_command(
  PeerKey, RequestLink, Binding, _CommandSeq, RequestId, _RemainingMs,
  _Operation,
  #remote_scope{peer_key = PeerKey, request_link = RequestLink,
                next_command_seq = Expected}, S) ->
    poison_remote_scope(
      Binding, RequestId, max(1, Expected - 1),
      {protocol_error, command_sequence}, S);
handle_bound_scope_command(_PeerKey, _RequestLink, _Binding, _CommandSeq,
                           _RequestId, _RemainingMs, _Operation, _Scope, S) ->
    %% A frame on another authenticated link/key cannot revoke the real
    %% origin's live scope.
    S.

%% Cleanup is an authenticated, sequence-bound command, not proof execution.
%% It must remain usable after the origin's execution budget reaches zero so a
%% completed/abandoned proof can release the target scope immediately instead
%% of waiting for the lifetime fallback.
scope_command_budget_valid(scope_close, _RemainingMs, _Deadline) -> true;
scope_command_budget_valid(_Operation, RemainingMs, Deadline) ->
    RemainingMs > 0 andalso quod_time:mono_ms() < Deadline.

target_scope_lifetime_ms(RemainingMs, LocalLimitMs) ->
    Budget = min(max(0, RemainingMs), LocalLimitMs),
    ReplyGrace = min(?QUOD_SCOPE_TIMEOUT_REPLY_GRACE_MS, Budget div 2),
    max(1, Budget - ReplyGrace).

accept_scope_command(scope_close, RequestId, CommandSeq,
                     Scope = #remote_scope{lifetime_timer = Timer}) ->
    %% An exact close owns cleanup once accepted.  Retire the absolute timer
    %% token now so an already-queued expiry cannot race cleanup and
    %% convert successful cleanup into a proof failure.
    cancel_scope_timer(Timer),
    Scope#remote_scope{next_command_seq = CommandSeq + 1,
                       last_request_id = RequestId,
                       lifetime_timer = undefined,
                       lifetime_token = undefined};
accept_scope_command(_Operation, RequestId, CommandSeq, Scope) ->
    Scope#remote_scope{next_command_seq = CommandSeq + 1,
                       last_request_id = RequestId}.

binding_admission_reason(
  {scope_binding, _OriginKey, _TargetKey, _ProofId, _ScopeId,
   _OriginIdentity, {_Ns, Anchor}, Mode}, S) ->
    scope_admission_reason(Mode, Anchor, S).

execute_remote_scope_command(Binding, scope_open, RequestId, CommandSeq, S) ->
    poison_remote_scope(
      Binding, RequestId, CommandSeq,
      {protocol_error, unexpected_scope_command}, S);
execute_remote_scope_command(Binding, Operation, RequestId, CommandSeq,
                             S = #s{remote_scopes = Remote}) ->
    case maps:find(Binding, Remote) of
        {ok, #remote_scope{state = active} = Scope} ->
            execute_active_scope_command(
              Operation, RequestId, CommandSeq, Binding, Scope, S);
        _ ->
            %% The command was accepted against an opening session only if it
            %% violated the explicit opened-before-demand boundary.
            poison_remote_scope(
              Binding, RequestId, CommandSeq,
              {protocol_error, unexpected_scope_command}, S)
    end.

execute_active_scope_command(
  scope_close, RequestId, CommandSeq, Binding, _Scope, S) ->
    %% Closing is cancellation, not another proof step.  It must not queue a
    %% state probe behind a currently-running derivation: that would make an
    %% abandoned non-terminating goal keep its worker and MVCC pin until the
    %% lifetime timer.  The last published generation is sufficient for the
    %% terminal acknowledgement; then the common drop path stops the worker
    %% and retains ownership until its monitored DOWN releases the pin.
    S1 = emit_scope_event(
           Binding, RequestId, CommandSeq, scope_closed, S),
    drop_remote_scope(Binding, S1);
execute_active_scope_command(
  {invoke_open, InvocationId, Selection, Chain, GoalBlob},
  RequestId, CommandSeq, Binding,
  #remote_scope{handle = Handle, pending = Pending}, S) ->
    case map_size(Pending) < ?QUOD_MAX_ROUTER_PENDING_PER_SCOPE of
        false ->
            emit_invocation_error(
              Binding, RequestId, CommandSeq, InvocationId, 1,
              {proof_limit_exceeded, target_namespace(Binding)}, S);
        true ->
            case quod_scope_wire:decode_payload(goal, GoalBlob) of
                {ok, Goal} ->
                    {ok, InternalRef} = quod_scope_session:invoke_open(
                                          Handle, InvocationId,
                                          Goal, Chain, Selection),
                    add_remote_pending(
                      Binding, InternalRef,
                      {invoke_open, RequestId, CommandSeq, InvocationId}, S);
                {error, Reason} ->
                    poison_remote_invocation(
                      Binding, RequestId, CommandSeq, InvocationId, 1,
                      Reason, S)
            end
    end;
execute_active_scope_command(
  {invoke_next, InvocationId, ExpectedAnswerSeq},
  RequestId, CommandSeq, Binding,
  #remote_scope{handle = Handle, pending = Pending,
                active_commands = Active}, S) ->
    case {map_size(Pending) < ?QUOD_MAX_ROUTER_PENDING_PER_SCOPE,
          length(Active) < ?QUOD_MAX_ACTIVE_PROOF_DEPTH} of
        {false, _} ->
            emit_invocation_error(
              Binding, RequestId, CommandSeq, InvocationId,
              ExpectedAnswerSeq,
              {proof_limit_exceeded, target_namespace(Binding)}, S);
        {_, false} ->
            emit_invocation_error(
              Binding, RequestId, CommandSeq, InvocationId,
              ExpectedAnswerSeq,
              {proof_depth_exceeded, ?QUOD_MAX_ACTIVE_PROOF_DEPTH}, S);
        {true, true} ->
            {ok, InternalRef} = quod_scope_session:invoke_next(
                                  Handle, InvocationId,
                                  ExpectedAnswerSeq),
            S1 = add_remote_pending(
                   Binding, InternalRef,
                   {invoke_next, RequestId, CommandSeq,
                    InvocationId, ExpectedAnswerSeq}, S),
            update_remote_scope(
              Binding,
              fun(R) ->
                  R#remote_scope{
                    active_commands =
                        active_stack_push(
                          {RequestId, CommandSeq}, Active)}
              end, S1)
    end;
execute_active_scope_command(
  {invoke_cancel, InvocationId}, _RequestId, _CommandSeq, _Binding,
  #remote_scope{handle = Handle}, S) ->
    _ = quod_scope_session:invoke_cancel(Handle, InvocationId),
    S;
execute_active_scope_command(
  {materialize, ControllerId, _ActorInvocationId, _Lineage, BatchIds},
  RequestId, CommandSeq, Binding, Scope, S) ->
    queue_scope_control(
      Binding, checkpoint, BatchIds,
      {materialized, RequestId, CommandSeq, ControllerId, BatchIds},
      Scope, S);
execute_active_scope_command(
  {batch_restore, BatchIds}, RequestId, CommandSeq, Binding, Scope, S) ->
    queue_scope_control(
      Binding, restore, BatchIds,
      {batch_restored, RequestId, CommandSeq, BatchIds}, Scope, S);
execute_active_scope_command(
  {batch_release, BatchIds}, RequestId, CommandSeq, Binding, Scope, S) ->
    queue_scope_control(
      Binding, release, BatchIds,
      {batch_released, RequestId, CommandSeq, BatchIds}, Scope, S);
execute_active_scope_command(Operation, _RequestId, _CommandSeq, Binding,
                             _Scope, S)
  when element(1, Operation) =:= nested_opened;
       element(1, Operation) =:= nested_solution;
       element(1, Operation) =:= nested_complete;
       element(1, Operation) =:= nested_erlog_error;
       element(1, Operation) =:= nested_error;
       element(1, Operation) =:= tx_activated;
       element(1, Operation) =:= tx_finished;
       element(1, Operation) =:= savepoint_allocated;
       element(1, Operation) =:= savepoint_restored;
       element(1, Operation) =:= controller_error ->
    deliver_remote_controller_reply(Binding, Operation, S);
execute_active_scope_command(_Operation, RequestId, CommandSeq, Binding,
                             _Scope, S) ->
    poison_remote_scope(
      Binding, RequestId, CommandSeq,
      {protocol_error, unexpected_scope_command}, S).

queue_scope_state_probe(Binding, Purpose,
                        Scope = #remote_scope{pending = Pending}, S) ->
    case map_size(Pending) < ?QUOD_MAX_ROUTER_PENDING_PER_SCOPE of
        false ->
            poison_remote_scope(
              Binding, purpose_request_id(Purpose),
              purpose_command_seq(Purpose),
              {proof_limit_exceeded, target_namespace(Binding)}, S);
        true ->
            InternalRef = make_ref(),
            send_scope_control(Scope, InternalRef, checkpoint, []),
            add_remote_pending(
              Binding, InternalRef, {state_probe, Purpose}, S)
    end.

queue_scope_control(Binding, Operation, BatchIds, Purpose,
                    Scope = #remote_scope{pending = Pending}, S) ->
    case map_size(Pending) < ?QUOD_MAX_ROUTER_PENDING_PER_SCOPE of
        false ->
            poison_remote_scope(
              Binding, purpose_request_id(Purpose),
              purpose_command_seq(Purpose),
              {proof_limit_exceeded, target_namespace(Binding)}, S);
        true ->
            InternalRef = make_ref(),
            send_scope_control(Scope, InternalRef, Operation, BatchIds),
            add_remote_pending(
              Binding, InternalRef,
              {scope_control, Purpose, Operation, BatchIds}, S)
    end.

send_scope_control(
  #remote_scope{
     handle = {quod_scope_session, Pid, _ScopeId, ProofId,
               SessionRef, _Ns, _Anchor}},
  InternalRef, Operation, BatchIds) ->
    Pid ! {scope_savepoint, self(), ProofId, SessionRef,
           InternalRef, Operation, BatchIds},
    ok.

purpose_request_id({scope_opened, RequestId, _CommandSeq, _Height}) -> RequestId;
purpose_request_id({materialized, RequestId, _CommandSeq, _Controller, _Ids}) ->
    RequestId;
purpose_request_id({batch_restored, RequestId, _CommandSeq, _Ids}) -> RequestId;
purpose_request_id({batch_released, RequestId, _CommandSeq, _Ids}) -> RequestId;
purpose_request_id({controller, RequestId, _CommandSeq, _Controller, _Event}) ->
    RequestId.

purpose_command_seq({scope_opened, _RequestId, CommandSeq, _Height}) -> CommandSeq;
purpose_command_seq({materialized, _RequestId, CommandSeq, _Controller, _Ids}) ->
    CommandSeq;
purpose_command_seq({batch_restored, _RequestId, CommandSeq, _Ids}) -> CommandSeq;
purpose_command_seq({batch_released, _RequestId, CommandSeq, _Ids}) -> CommandSeq;
purpose_command_seq({controller, _RequestId, CommandSeq, _Controller, _Event}) ->
    CommandSeq.

handle_scope_return_link(OpenRef, PeerKey, ReturnChannel, ReturnLink,
                         S = #s{remote_open_refs = OpenRefs,
                                remote_scopes = Remote})
  when is_pid(ReturnLink) ->
    case maps:find(OpenRef, OpenRefs) of
        {ok, Binding} ->
            case maps:find(Binding, Remote) of
                {ok,
                 Scope = #remote_scope{
                   peer_key = PeerKey, return_channel = ReturnChannel,
                   state = opening_return}} ->
                    start_remote_scope_session(
                      Binding, ReturnLink, Scope,
                      S#s{remote_open_refs = maps:remove(OpenRef, OpenRefs)});
                _ ->
                    S#s{remote_open_refs = maps:remove(OpenRef, OpenRefs)}
            end;
        error ->
            S
    end;
handle_scope_return_link(_OpenRef, _PeerKey, _ReturnChannel, _ReturnLink, S) ->
    S.

handle_scope_return_error(OpenRef, PeerKey, ReturnChannel,
                          S = #s{remote_open_refs = OpenRefs,
                                 remote_scopes = Remote}) ->
    case maps:find(OpenRef, OpenRefs) of
        {ok, Binding} ->
            case maps:find(Binding, Remote) of
                {ok, #remote_scope{peer_key = PeerKey,
                                   return_channel = ReturnChannel}} ->
                    drop_remote_scope(Binding, S);
                _ ->
                    S#s{remote_open_refs = maps:remove(OpenRef, OpenRefs)}
            end;
        error ->
            S
    end.

start_remote_scope_session(
  Binding = {scope_binding, _OriginKey, _TargetKey, _ProofId, _ScopeId,
             _OriginIdentity, {Ns, _Anchor}, _Mode},
  ReturnLink,
  Scope,
  S = #s{scope_workers = Workers, max_scope_workers = Max}) ->
    case {binding_admission_reason(Binding, S),
          map_size(Workers) < Max} of
        {ok, true} ->
            start_admitted_remote_scope_session(
              Binding, ReturnLink, Scope, S);
        {{error, Reason}, _} ->
            reject_return_link_open(Scope, ReturnLink, Reason, S);
        {ok, false} ->
            reject_return_link_open(
              Scope, ReturnLink, {ontology_busy, Ns}, S)
    end.

start_admitted_remote_scope_session(
  Binding = {scope_binding, OriginKey, _TargetKey, ProofId, ScopeId,
             _OriginIdentity, {Ns, Anchor}, Mode},
  ReturnLink,
  Scope = #remote_scope{request_mref = RequestMRef,
                        open_request_id = OpenRequestId},
  S = #s{est = Est, applied = Height,
         scope_workers = Workers, scope_pids = Pids,
         remote_return_mrefs = ReturnRefs}) ->
    ReadOnly = Mode =:= read_only,
    ReturnMRef = monitor(process, ReturnLink),
    {Handle, WorkerMRef} = quod_scope_session:start(
                             ScopeId, ProofId, self(), Ns, Anchor, Height,
                             Est, self(),
                             #{read_only => ReadOnly,
                               principal => OriginKey,
                               deadline_ms => Scope#remote_scope.deadline_ms}),
    Pid = quod_scope_session:pid(Handle),
    Key = {remote, Binding},
    Worker = new_scope_worker(
               Pid, WorkerMRef, RequestMRef, Key, Height,
               none),
    Scope1 = Scope#remote_scope{
               return_link = ReturnLink, return_mref = ReturnMRef,
               handle = Handle, worker_mref = WorkerMRef,
               state = opening_session},
    S1 = put_remote_scope(
           Scope1,
           S#s{scope_workers = Workers#{WorkerMRef => Worker},
               scope_pids = Pids#{Pid => WorkerMRef},
               remote_return_mrefs = ReturnRefs#{ReturnMRef => Binding}}),
    %% Probe inside the session worker so even the opening event carries the
    %% target-owned generation/dirty pair rather than guessed constants.
    queue_scope_state_probe(
      Binding, {scope_opened, OpenRequestId, 1, Height},
      Scope1, S1#s{proves = S1#s.proves + 1}).

reject_return_link_open(
  #remote_scope{binding = Binding, open_request_id = RequestId},
  ReturnLink, Reason, S) ->
    Event = {scope_event, Binding, 1, RequestId, 1, 0, false,
             {scope_error,
              public_scope_reason(Reason, target_namespace(Binding))}},
    case quod_scope_wire:encode_event(Event) of
        {ok, Encoded} -> quod_link:send_ordered(ReturnLink, Encoded);
        {error, _} -> ok
    end,
    drop_remote_record(Binding, S).

expire_remote_scope(Binding, Token, S = #s{remote_scopes = Remote}) ->
    case maps:find(Binding, Remote) of
        {ok, #remote_scope{lifetime_token = Token}} ->
            expire_remote_scope_with_reason(
              Binding, {scope_expired, target_namespace(Binding)}, S);
        _ ->
            S
    end.

add_remote_pending(Binding, InternalRef, Entry,
                   S = #s{remote_scopes = Remote,
                          remote_internal_refs = InternalRefs}) ->
    Scope = maps:get(Binding, Remote),
    Pending = Scope#remote_scope.pending,
    Scope1 = Scope#remote_scope{pending = Pending#{InternalRef => Entry}},
    S#s{remote_scopes = Remote#{Binding => Scope1},
        remote_internal_refs = InternalRefs#{InternalRef => Binding}}.

take_remote_pending(InternalRef,
                    S = #s{remote_internal_refs = InternalRefs,
                           remote_scopes = Remote}) ->
    case maps:take(InternalRef, InternalRefs) of
        {Binding, InternalRefs1} ->
            case maps:find(Binding, Remote) of
                {ok, Scope} ->
                    case maps:take(InternalRef, Scope#remote_scope.pending) of
                        {Entry, Pending1} ->
                            Scope1 = Scope#remote_scope{pending = Pending1},
                            {ok, Binding, Scope1, Entry,
                             S#s{remote_internal_refs = InternalRefs1,
                                 remote_scopes = Remote#{Binding => Scope1}}};
                        error ->
                            error
                    end;
                error ->
                    error
            end;
        error ->
            error
    end.

handle_remote_scope_reply(ScopePid, ProofId, SessionRef, InternalRef, Reply, S) ->
    case take_remote_pending(InternalRef, S) of
        {ok, Binding, Scope, Entry, S1} ->
            case scope_reply_bound(
                   ScopePid, ProofId, SessionRef, Scope) of
                true -> handle_bound_scope_reply(
                          Binding, Scope, Entry, Reply, S1);
                false -> poison_remote_scope(
                           Binding, random_request_id(), 1,
                           {protocol_error, session_binding}, S1)
            end;
        error ->
            S
    end.

scope_reply_bound(
  ScopePid, ProofId, SessionRef,
  #remote_scope{
     handle = {quod_scope_session, ScopePid, _ScopeId, ProofId,
               SessionRef, _Ns, _Anchor}}) -> true;
scope_reply_bound(_ScopePid, _ProofId, _SessionRef, _Scope) -> false.

handle_bound_scope_reply(
  Binding, _Scope,
  {state_probe, Purpose},
  {savepoint, checkpoint, [], {ok, Dirty, Generation}}, S) ->
    S1 = update_remote_state(Binding, Dirty, Generation, S),
    finish_state_probe(Binding, Purpose, S1);
handle_bound_scope_reply(Binding, _Scope,
                         {state_probe, Purpose}, _Reply, S) ->
    poison_remote_scope(
      Binding, purpose_request_id(Purpose), purpose_command_seq(Purpose),
      {protocol_error, proof_engine}, S);
handle_bound_scope_reply(
  Binding, _Scope,
  {invoke_open, RequestId, CommandSeq, InvocationId},
  {opened, InvocationId}, S) ->
    emit_scope_event(
      Binding, RequestId, CommandSeq,
      {invocation_opened, InvocationId}, S);
handle_bound_scope_reply(
  Binding, _Scope,
  {invoke_open, RequestId, CommandSeq, InvocationId},
  {error, Reason}, S) ->
    emit_invocation_error(
      Binding, RequestId, CommandSeq, InvocationId, 1, Reason, S);
handle_bound_scope_reply(
  Binding, _Scope,
  {invoke_open, RequestId, CommandSeq, InvocationId},
  _Reply, S) ->
    poison_remote_invocation(
      Binding, RequestId, CommandSeq, InvocationId, 1,
      {protocol_error, request_binding}, S);
handle_bound_scope_reply(
  Binding, Scope,
  {invoke_next, RequestId, CommandSeq, InvocationId, ExpectedSeq},
  Reply, S) ->
    queue_scope_state_probe(
      Binding,
      {invoke_result, RequestId, CommandSeq,
       InvocationId, ExpectedSeq, Reply}, Scope, S);
handle_bound_scope_reply(
  Binding, _Scope,
  {scope_control, Purpose, Operation, BatchIds},
  {savepoint, Operation, BatchIds, {ok, Dirty, Generation}}, S) ->
    S1 = update_remote_state(Binding, Dirty, Generation, S),
    finish_scope_control(Binding, Purpose, S1);
handle_bound_scope_reply(
  Binding, _Scope,
  {scope_control, Purpose, _Operation, _BatchIds}, _Reply, S) ->
    poison_remote_scope(
      Binding, purpose_request_id(Purpose), purpose_command_seq(Purpose),
      {protocol_error, proof_engine}, S).

finish_state_probe(Binding,
                   {scope_opened, RequestId, CommandSeq, Height}, S) ->
    S1 = update_remote_scope(
           Binding,
           fun(Scope) -> Scope#remote_scope{state = active} end, S),
    emit_scope_event(
      Binding, RequestId, CommandSeq, {scope_opened, Height}, S1);
finish_state_probe(
  Binding,
  {invoke_result, RequestId, CommandSeq,
   InvocationId, ExpectedSeq, Reply}, S) ->
    S1 = emit_invocation_result(
           Binding, RequestId, CommandSeq,
           InvocationId, ExpectedSeq, Reply, S),
    pop_active_command(Binding, {RequestId, CommandSeq}, S1);
finish_state_probe(Binding,
                   {controller, RequestId, CommandSeq,
                    _ControllerId, EventOperation}, S) ->
    emit_scope_event(Binding, RequestId, CommandSeq, EventOperation, S).

finish_scope_control(Binding,
                     {materialized, RequestId, CommandSeq,
                      ControllerId, BatchIds}, S) ->
    emit_scope_event(
      Binding, RequestId, CommandSeq,
      {materialized, ControllerId, BatchIds}, S);
finish_scope_control(Binding,
                     {batch_restored, RequestId, CommandSeq, BatchIds}, S) ->
    emit_scope_event(
      Binding, RequestId, CommandSeq, {batch_restored, BatchIds}, S);
finish_scope_control(Binding,
                     {batch_released, RequestId, CommandSeq, BatchIds}, S) ->
    emit_scope_event(
      Binding, RequestId, CommandSeq, {batch_released, BatchIds}, S).

emit_invocation_result(Binding, RequestId, CommandSeq,
                       InvocationId, ExpectedSeq,
                       {solution, ExpectedSeq, Solution, _Dirty}, S) ->
    emit_payload_event(
      answer, Solution,
      fun(Blob) -> {solution, InvocationId, ExpectedSeq, Blob} end,
      Binding, RequestId, CommandSeq,
      InvocationId, ExpectedSeq, S);
emit_invocation_result(Binding, RequestId, CommandSeq,
                       InvocationId, ExpectedSeq,
                       {complete, ExpectedSeq, Reasons, _Dirty}, S) ->
    emit_payload_event(
      failure_reasons, Reasons,
      fun(Blob) -> {complete, InvocationId, ExpectedSeq, Blob} end,
      Binding, RequestId, CommandSeq,
      InvocationId, ExpectedSeq, S);
emit_invocation_result(Binding, RequestId, CommandSeq,
                       InvocationId, ExpectedSeq,
                       {error, {erlog, Error}, _Dirty}, S) ->
    emit_payload_event(
      erlog_error, Error,
      fun(Blob) -> {erlog_error, InvocationId, ExpectedSeq, Blob} end,
      Binding, RequestId, CommandSeq,
      InvocationId, ExpectedSeq, S);
emit_invocation_result(Binding, RequestId, CommandSeq,
                       InvocationId, ExpectedSeq,
                       {error, Reason, _Dirty}, S) ->
    emit_invocation_error(
      Binding, RequestId, CommandSeq, InvocationId, ExpectedSeq, Reason, S);
emit_invocation_result(Binding, RequestId, CommandSeq,
                       InvocationId, ExpectedSeq, _Reply, S) ->
    poison_remote_invocation(
      Binding, RequestId, CommandSeq, InvocationId, ExpectedSeq,
      {protocol_error, request_binding}, S).

emit_payload_event(Kind, Term, BuildOperation,
                   Binding, RequestId, CommandSeq,
                   InvocationId, ExpectedSeq, S) ->
    case quod_scope_wire:encode_payload(Kind, Term) of
        {ok, Blob} ->
            emit_scope_event(
              Binding, RequestId, CommandSeq, BuildOperation(Blob), S);
        {error, Reason} ->
            emit_invocation_error(
              Binding, RequestId, CommandSeq,
              InvocationId, ExpectedSeq, Reason, S)
    end.

emit_invocation_error(Binding, RequestId, CommandSeq,
                      InvocationId, AnswerSeq, Reason, S) ->
    emit_scope_event(
      Binding, RequestId, CommandSeq,
      {invocation_error, InvocationId, AnswerSeq,
       public_scope_reason(Reason, target_namespace(Binding))}, S).

poison_remote_invocation(Binding, RequestId, CommandSeq,
                         InvocationId, AnswerSeq, Reason, S) ->
    S1 = emit_invocation_error(
           Binding, RequestId, CommandSeq,
           InvocationId, AnswerSeq, Reason, S),
    drop_remote_scope(Binding, S1).

poison_remote_scope(Binding, RequestId, CommandSeq, Reason, S) ->
    S1 = emit_scope_event(
           Binding, RequestId, max(1, CommandSeq),
           {scope_error,
            public_scope_reason(Reason, target_namespace(Binding))}, S),
    drop_remote_scope(Binding, S1).

emit_scope_event(Binding, RequestId, AcceptedCommandSeq, Operation,
                 S = #s{remote_scopes = Remote}) ->
    case maps:find(Binding, Remote) of
        {ok,
         Scope = #remote_scope{return_link = ReturnLink,
                               next_event_seq = EventSeq,
                               generation = Generation,
                               dirty = Dirty}}
          when is_pid(ReturnLink) ->
            Event = {scope_event, Binding, EventSeq, RequestId,
                     AcceptedCommandSeq, Generation, Dirty, Operation},
            case quod_scope_wire:encode_event(Event) of
                {ok, Encoded} ->
                    %% Ordered send is non-blocking for the namespace engine;
                    %% a local send failure resets the link, whose DOWN reaps
                    %% every exact session bound to it.
                    quod_link:send_ordered(ReturnLink, Encoded),
                    put_remote_scope(
                      Scope#remote_scope{next_event_seq = EventSeq + 1}, S);
                {error, _} ->
                    drop_remote_scope(Binding, S)
            end;
        _ ->
            S
    end.

public_scope_reason(Reason, Ns) ->
    Candidate = public_scope_candidate(Reason, Ns),
    quod_scope_wire:normalize_public_error(Candidate, Ns).

public_scope_candidate({erlog, _}, _Ns) -> {protocol_error, proof_engine};
public_scope_candidate(unknown_invocation, _Ns) ->
    {protocol_error, unexpected_scope_command};
public_scope_candidate(invocation_active, _Ns) ->
    {protocol_error, unexpected_scope_command};
public_scope_candidate(already_open, _Ns) ->
    {protocol_error, unexpected_scope_command};
public_scope_candidate(not_allowed, Ns) -> {not_allowed, Ns};
public_scope_candidate(too_many_answers, Ns) -> {too_many_answers, Ns};
public_scope_candidate(Reason, _Ns)
  when Reason =:= bad_request; Reason =:= unknown_lineage;
       Reason =:= unknown_savepoint;
       Reason =:= active_child_transaction;
       Reason =:= transaction_scope_mismatch;
       Reason =:= broken_transaction_controller ->
    {protocol_error, request_binding};
public_scope_candidate(Reason, _Ns) -> Reason.

update_remote_state(Binding, Dirty, Generation, S) ->
    update_remote_scope(
      Binding,
      fun(Scope) -> Scope#remote_scope{
                        dirty = Dirty, generation = Generation}
      end, S).

put_remote_scope(Scope = #remote_scope{binding = Binding},
                 S = #s{remote_scopes = Remote}) ->
    S#s{remote_scopes = Remote#{Binding => Scope}}.

update_remote_scope(Binding, Fun, S = #s{remote_scopes = Remote}) ->
    case maps:find(Binding, Remote) of
        {ok, Scope} -> put_remote_scope(Fun(Scope), S);
        error -> S
    end.

pop_active_command(Binding, Command,
                   S = #s{remote_scopes = Remote}) ->
    case maps:find(Binding, Remote) of
        {ok, Scope = #remote_scope{active_commands = Active}} ->
            case active_stack_pop(Command, Active) of
                {ok, Rest} ->
                    put_remote_scope(
                      Scope#remote_scope{active_commands = Rest}, S);
                error ->
                    drop_remote_scope(Binding, S)
            end;
        error ->
            S
    end.

active_stack_push(Command, Active) -> [Command | Active].

active_stack_pop(Command, [Command | Rest]) -> {ok, Rest};
active_stack_pop(_Command, _Active) -> error.

active_stack_top([Command | _]) -> {ok, Command};
active_stack_top([]) -> error.

-ifdef(TEST).
test_active_command_stack(Operations) ->
    test_active_command_stack(Operations, [], []).

test_active_command_stack([{push, Command} | Rest], Stack, Observed) ->
    test_active_command_stack(
      Rest, active_stack_push(Command, Stack), Observed);
test_active_command_stack([{pop, Command} | Rest], Stack, Observed) ->
    case active_stack_pop(Command, Stack) of
        {ok, Stack1} ->
            test_active_command_stack(Rest, Stack1, Observed);
        error -> error
    end;
test_active_command_stack([top | Rest], Stack, Observed) ->
    case active_stack_top(Stack) of
        {ok, Command} ->
            test_active_command_stack(Rest, Stack, [Command | Observed]);
        error -> error
    end;
test_active_command_stack([], Stack, Observed) ->
    {ok, lists:reverse(Observed), Stack};
test_active_command_stack(_Bad, _Stack, _Observed) -> error.

test_scope_capacity_available(Max, Active, Pending) ->
    scope_capacity_available(Max, Active, Pending).

test_public_scope_reason(Reason, Ns) ->
    public_scope_reason(Reason, Ns).

test_scope_timeout_reason(Phase, Ns) ->
    scope_timeout_reason(Phase, Ns).

test_scope_command_budget_valid(Operation, RemainingMs, Deadline) ->
    scope_command_budget_valid(Operation, RemainingMs, Deadline).

test_target_scope_lifetime_ms(RemainingMs, LocalLimitMs) ->
    target_scope_lifetime_ms(RemainingMs, LocalLimitMs).

test_remote_timeout_correlation(LastRequestId, NextCommandSeq,
                                ActiveCommands) ->
    remote_timeout_correlation(
      #remote_scope{last_request_id = LastRequestId,
                    next_command_seq = NextCommandSeq,
                    active_commands = ActiveCommands}).

test_scope_worker_failure(Reason, Ns) ->
    scope_worker_failure(Reason, Ns).

test_proof_down_reply(Kind, Reason, Ns) ->
    proof_down_reply(Kind, Reason, Ns).
-endif.

target_namespace({scope_binding, _OriginKey, _TargetKey, _ProofId, _ScopeId,
                  _OriginIdentity, {Ns, _Anchor}, _Mode}) -> Ns.

random_request_id() ->
    crypto:strong_rand_bytes(?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS div 8).

handle_remote_controller_request(Message, S = #s{scope_pids = Pids,
                                                  scope_workers = Workers,
                                                  remote_scopes = Remote}) ->
    From = element(3, Message),
    ProofId = element(2, Message),
    case maps:find(From, Pids) of
        {ok, WorkerMRef} ->
            case maps:find(WorkerMRef, Workers) of
                {ok, #scope_worker{scope_key = {remote, Binding}}} ->
                    case maps:find(Binding, Remote) of
                        {ok, Scope} ->
                            case remote_controller_bound(
                                   ProofId, From, Binding, Scope) of
                                true ->
                                    translate_remote_controller_request(
                                      Message, Binding, Scope, S);
                                false ->
                                    drop_remote_scope(Binding, S)
                            end;
                        error -> S
                    end;
                _ -> S
            end;
        error -> S
    end.

remote_controller_bound(
  ProofId, From,
  {scope_binding, _OriginKey, _TargetKey, ProofId, ScopeId,
   _OriginIdentity, _TargetIdentity, _Mode},
  #remote_scope{
     handle = {quod_scope_session, From, ScopeId, ProofId,
               _SessionRef, _Ns, _Anchor},
     active_commands = [{_RequestId, _CommandSeq} | _]}) -> true;
remote_controller_bound(_ProofId, _From, _Binding, _Scope) -> false.

translate_remote_controller_request(
  {proof_nested_open, _ProofId, From, InternalRequestRef,
   _Actor, _Selection, TargetNs, Goal, Chain},
  Binding, Scope, S) ->
    case quod_scope_wire:encode_payload(goal, Goal) of
        {ok, GoalBlob} ->
            ControllerId = new_controller_id(Scope),
            Controllers = (Scope#remote_scope.controllers)#{
              ControllerId =>
                  {nested_open, From, InternalRequestRef}},
            Scope1 = Scope#remote_scope{controllers = Controllers},
            queue_controller_event(
              Binding, ControllerId,
              {nested_open, ControllerId, TargetNs, Chain, GoalBlob},
              Scope1, put_remote_scope(Scope1, S));
        {error, Reason} ->
            From ! {proof_nested_reply, binding_proof_id(Binding),
                    InternalRequestRef, {error, Reason}},
            S
    end;
translate_remote_controller_request(
  {proof_nested_next, _ProofId, From, InternalRequestRef,
   _Actor, _Selection, ProxyId, ExpectedSeq},
  Binding, Scope, S) ->
    ControllerId = new_controller_id(Scope),
    Controllers = (Scope#remote_scope.controllers)#{
      ControllerId =>
          {nested_next, From, InternalRequestRef, ProxyId, ExpectedSeq}},
    Scope1 = Scope#remote_scope{controllers = Controllers},
    queue_controller_event(
      Binding, ControllerId,
      {nested_next, ControllerId, ProxyId, ExpectedSeq},
      Scope1, put_remote_scope(Scope1, S));
translate_remote_controller_request(
  {proof_nested_cancel, _ProofId, _From, _Actor, _Selection, ProxyId},
  Binding, Scope, S) ->
    ControllerId = new_controller_id(Scope),
    emit_controller_event_now(
      Binding, {nested_cancel, ControllerId, ProxyId}, S);
translate_remote_controller_request(
  {proof_tx_request, _ProofId, From, ScopeId, InvocationId,
   InternalRequestRef, Operation},
  Binding, Scope, S) ->
    case ScopeId =:= binding_scope_id(Binding) of
        false -> drop_remote_scope(Binding, S);
        true ->
            ControllerId = new_controller_id(Scope),
            case tx_controller_event(
                   ControllerId, InvocationId, Operation) of
                {ok, EventOperation, ExpectedReply} ->
                    Controllers = (Scope#remote_scope.controllers)#{
                      ControllerId =>
                          {tx, From, InvocationId,
                           InternalRequestRef, ExpectedReply}},
                    Scope1 = Scope#remote_scope{controllers = Controllers},
                    queue_controller_event(
                      Binding, ControllerId, EventOperation,
                      Scope1, put_remote_scope(Scope1, S));
                error ->
                    From ! {proof_tx_reply, binding_proof_id(Binding),
                            InvocationId, InternalRequestRef,
                            {error, bad_request}},
                    S
            end
    end.

queue_controller_event(Binding, ControllerId, EventOperation,
                       Scope = #remote_scope{active_commands = Active}, S) ->
    case active_stack_top(Active) of
        {ok, {RequestId, CommandSeq}} ->
            queue_scope_state_probe(
              Binding,
              {controller, RequestId, CommandSeq,
               ControllerId, EventOperation},
              Scope, S);
        error ->
            drop_remote_scope(Binding, S)
    end.

emit_controller_event_now(
  Binding, EventOperation,
  S = #s{remote_scopes = Remote}) ->
    case maps:find(Binding, Remote) of
        {ok, #remote_scope{active_commands = Active}} ->
            case active_stack_top(Active) of
                {ok, {RequestId, CommandSeq}} ->
                    emit_scope_event(
                      Binding, RequestId, CommandSeq, EventOperation, S);
                error -> drop_remote_scope(Binding, S)
            end;
        _ ->
            drop_remote_scope(Binding, S)
    end.

tx_controller_event(ControllerId, InvocationId,
                    {activate, ParentLineage, FrameIds}) ->
    {ok,
     {tx_activate, ControllerId, InvocationId, ParentLineage, FrameIds},
     tx_activated};
tx_controller_event(ControllerId, InvocationId, {allocate, Lineage}) ->
    {ok,
     {savepoint_allocate, ControllerId, InvocationId, Lineage},
     savepoint_allocated};
tx_controller_event(ControllerId, InvocationId,
                    {restore, Lineage, BatchIds}) ->
    {ok,
     {savepoint_restore, ControllerId, InvocationId, Lineage, BatchIds},
     savepoint_restored};
tx_controller_event(ControllerId, InvocationId,
                    {finish, Lineage, TxId}) ->
    {ok,
     {tx_finish, ControllerId, InvocationId, Lineage, TxId, finish},
     tx_finished};
tx_controller_event(ControllerId, InvocationId,
                    {discard, Lineage, TxId}) ->
    {ok,
     {tx_finish, ControllerId, InvocationId, Lineage, TxId, discard},
     tx_finished};
tx_controller_event(_ControllerId, _InvocationId, _Operation) -> error.

deliver_remote_controller_reply(Binding, Operation,
                                S = #s{remote_scopes = Remote}) ->
    ControllerId = element(2, Operation),
    case maps:find(Binding, Remote) of
        {ok, Scope} ->
            case maps:take(ControllerId, Scope#remote_scope.controllers) of
                {Controller, Controllers1} ->
                    Scope1 = Scope#remote_scope{controllers = Controllers1},
                    S1 = put_remote_scope(Scope1, S),
                    case controller_reply(Controller, Operation, Binding) of
                        {ok, Pid, ReplyMessage} ->
                            Pid ! ReplyMessage,
                            S1;
                        {error, _} ->
                            drop_remote_scope(Binding, S1)
                    end;
                error ->
                    drop_remote_scope(Binding, S)
            end;
        error -> S
    end.

controller_reply(
  {nested_open, Pid, RequestRef},
  {nested_opened, _ControllerId, ProxyId}, Binding) ->
    {ok, Pid,
     {proof_nested_reply, binding_proof_id(Binding), RequestRef,
      {opened, ProxyId}}};
controller_reply(
  {nested_next, Pid, RequestRef, ProxyId, ExpectedSeq},
  {nested_solution, _ControllerId, ProxyId, ExpectedSeq, Blob}, Binding) ->
    decoded_nested_reply(
      answer, Blob, Pid, Binding, RequestRef,
      fun(Solution) -> {solution, ExpectedSeq, Solution} end);
controller_reply(
  {nested_next, Pid, RequestRef, ProxyId, ExpectedSeq},
  {nested_complete, _ControllerId, ProxyId, ExpectedSeq, Blob}, Binding) ->
    decoded_nested_reply(
      failure_reasons, Blob, Pid, Binding, RequestRef,
      fun(Reasons) -> {complete, ExpectedSeq, Reasons} end);
controller_reply(
  {nested_next, Pid, RequestRef, ProxyId, ExpectedSeq},
  {nested_erlog_error, _ControllerId, ProxyId, ExpectedSeq, Blob}, Binding) ->
    decoded_nested_reply(
      erlog_error, Blob, Pid, Binding, RequestRef,
      fun(Error) -> {error, {erlog, Error}} end);
controller_reply(
  {nested_open, Pid, RequestRef},
  {nested_error, _ControllerId, Reason}, Binding) ->
    nested_error_reply(Pid, Binding, RequestRef, Reason);
controller_reply(
  {nested_next, Pid, RequestRef, _ProxyId, _ExpectedSeq},
  {nested_error, _ControllerId, Reason}, Binding) ->
    nested_error_reply(Pid, Binding, RequestRef, Reason);
controller_reply(
  {tx, Pid, InvocationId, RequestRef, tx_activated},
  {tx_activated, _ControllerId, FinalLineage, Activated}, Binding) ->
    tx_reply(Pid, Binding, InvocationId, RequestRef,
             {ok, FinalLineage, Activated});
controller_reply(
  {tx, Pid, InvocationId, RequestRef, tx_finished},
  {tx_finished, _ControllerId, ParentLineage}, Binding) ->
    tx_reply(Pid, Binding, InvocationId, RequestRef,
             {ok, ParentLineage});
controller_reply(
  {tx, Pid, InvocationId, RequestRef, savepoint_allocated},
  {savepoint_allocated, _ControllerId, BatchId}, Binding) ->
    tx_reply(Pid, Binding, InvocationId, RequestRef, {ok, BatchId});
controller_reply(
  {tx, Pid, InvocationId, RequestRef, savepoint_restored},
  {savepoint_restored, _ControllerId, _BatchIds}, Binding) ->
    tx_reply(Pid, Binding, InvocationId, RequestRef, ok);
controller_reply(
  {tx, Pid, InvocationId, RequestRef, _Expected},
  {controller_error, _ControllerId, Reason}, Binding) ->
    tx_reply(Pid, Binding, InvocationId, RequestRef, {error, Reason});
controller_reply(_Controller, _Operation, _Binding) ->
    {error, bad_reply}.

decoded_nested_reply(Kind, Blob, Pid, Binding, RequestRef, BuildReply) ->
    case quod_scope_wire:decode_payload(Kind, Blob) of
        {ok, Term} ->
            {ok, Pid,
             {proof_nested_reply, binding_proof_id(Binding), RequestRef,
              BuildReply(Term)}};
        {error, _} ->
            {error, bad_payload}
    end.

nested_error_reply(Pid, Binding, RequestRef, Reason) ->
    {ok, Pid,
     {proof_nested_reply, binding_proof_id(Binding), RequestRef,
      {error, Reason}}}.

tx_reply(Pid, Binding, InvocationId, RequestRef, Reply) ->
    {ok, Pid,
     {proof_tx_reply, binding_proof_id(Binding), InvocationId,
      RequestRef, Reply}}.

new_controller_id(#remote_scope{controllers = Controllers}) ->
    new_controller_id_from(Controllers).

new_controller_id_from(Controllers) ->
    ControllerId = random_request_id(),
    case maps:is_key(ControllerId, Controllers) of
        true -> new_controller_id_from(Controllers);
        false -> ControllerId
    end.

binding_proof_id({scope_binding, _OriginKey, _TargetKey, ProofId, _ScopeId,
                  _OriginIdentity, _TargetIdentity, _Mode}) -> ProofId.

binding_scope_id({scope_binding, _OriginKey, _TargetKey, _ProofId, ScopeId,
                  _OriginIdentity, _TargetIdentity, _Mode}) -> ScopeId.

drop_remote_scope(Binding, S = #s{remote_scopes = Remote}) ->
    case maps:find(Binding, Remote) of
        {ok, #remote_scope{worker_mref = WorkerMRef}}
          when is_reference(WorkerMRef) ->
            kill_scope_worker(WorkerMRef, S);
        {ok, _Scope} ->
            drop_remote_record(Binding, S);
        error -> S
    end.

drop_remote_record(
  Binding,
  S = #s{remote_scopes = Remote,
         remote_open_refs = OpenRefs,
         remote_request_mrefs = RequestRefs,
         remote_return_mrefs = ReturnRefs,
         remote_internal_refs = InternalRefs,
         remote_peer_counts = PeerCounts}) ->
    case maps:take(Binding, Remote) of
        {#remote_scope{peer_key = PeerKey,
                       request_mref = RequestMRef,
                       return_mref = ReturnMRef,
                       open_ref = OpenRef,
                       lifetime_timer = LifetimeTimer,
                       pending = Pending}, Remote1} ->
            cancel_scope_timer(LifetimeTimer),
            demonitor(RequestMRef, [flush]),
            case ReturnMRef of
                undefined -> ok;
                _ -> demonitor(ReturnMRef, [flush])
            end,
            InternalRefs1 = lists:foldl(
                              fun maps:remove/2, InternalRefs,
                              maps:keys(Pending)),
            Count = maps:get(PeerKey, PeerCounts, 1),
            PeerCounts1 = case Count =< 1 of
                              true -> maps:remove(PeerKey, PeerCounts);
                              false -> PeerCounts#{PeerKey => Count - 1}
                          end,
            S#s{remote_scopes = Remote1,
                remote_open_refs = maps:remove(OpenRef, OpenRefs),
                remote_request_mrefs = maps:remove(
                                         RequestMRef, RequestRefs),
                remote_return_mrefs = case ReturnMRef of
                    undefined -> ReturnRefs;
                    _ -> maps:remove(ReturnMRef, ReturnRefs)
                end,
                remote_internal_refs = InternalRefs1,
                remote_peer_counts = PeerCounts1};
        error -> S
    end.

handle_response_info(Info, S = #s{requests = Requests}) ->
    case gen_statem:check_response(Info, Requests, true) of
        {{reply, Result}, Tx, Requests1} ->
            {noreply, append_result(Tx, Result, S#s{requests = Requests1})};
        {{error, _Reason}, Tx, Requests1} ->
            %% The server may have committed immediately before exiting. Keep the caller
            %% parked so replay/apply can still provide the unambiguous result.
            {noreply, request_completed(Tx, S#s{requests = Requests1})};
        no_reply ->
            {noreply, S};
        no_request ->
            {noreply, S}
    end.

terminate(_Reason, #s{ns = Ns, workers = W, scope_workers = ScopeWorkers}) ->
    maps:foreach(fun(_Ref, #proof_worker{pid = Pid}) -> kill_worker(Pid) end, W),
    maps:foreach(
      fun(_WM, #scope_worker{pid = Pid}) -> kill_worker(Pid) end,
      ScopeWorkers),
    _ = try quod_reg:unsubscribe(
              {channel, quod_scope_wire:request_channel(Ns)})
        catch _:_ -> ok end,
    ok.

%%%===================================================================
%%% proof execution (worker-per-proof; copy-on-write overlay)
%%%===================================================================

%% Spawn one worker for this proof. The worker gets a small table/height snapshot handle,
%% never the committed KB contents, plus the height stamped on the public reply.
%% The engine only tracks the monitor + a kill timer; it never runs the proof.
spawn_proof(Kind, Goal, CallerNs, From, TraceCtx,
            S) ->
    spawn_proof(Kind, Goal, CallerNs, From, TraceCtx, undefined, S).

spawn_proof(Kind, Goal, CallerNs, From, TraceCtx, Principal,
            S = #s{ns = Ns, est = Est, applied = Applied,
                   proof_timeout_ms = ProofTimeout}) ->
    Engine = self(),
    Ref = make_ref(),
    ProofId = crypto:strong_rand_bytes(32),
    Deadline = quod_time:mono_ms() + ProofTimeout,
    {Pid, MRef} = spawn_opt(fun() ->
        proof_worker(Engine, Ref, ProofId, Deadline, Kind, Goal, CallerNs,
                     Ns, Est, Applied, TraceCtx, Principal)
    end, [monitor]),
    CallerMRef = monitor(process, element(1, From)),
    Token = make_ref(),
    KillDelay = max(1, Deadline - quod_time:mono_ms()),
    KillRef = erlang:send_after(KillDelay, Engine, {proof_kill, Ref, Token}),
    Worker = #proof_worker{pid = Pid, kind = Kind,
                           worker_mref = MRef, caller_mref = CallerMRef,
                           from = From, timer = KillRef, token = Token,
                           trace_ctx = TraceCtx,
                           height = Applied},
    S#s{workers = (S#s.workers)#{Ref =>
          Worker},
        proves  = S#s.proves + 1}.

bump_proves(S) -> S#s{proves = S#s.proves + 1}.

%% Runs in the worker process. Sets the run's execution context on the frozen `#est{}`
%% (`m:quod_predicates` — the namespace, applied height, and call chain the external predicates
%% read), proves against that view, and reports one correlated result to the engine. The
%% origin-scope read-set ETS table is created here, so an abandoned/killed run can never leak it.
proof_worker(Engine, Ref, ProofId, Deadline, Kind, Goal, CallerNs, Ns, Est,
             Applied, TraceCtx, Principal) ->
    _ = quod_process:kill_when_owner_dies(Engine, self()),
    Ctx = worker_context(Kind, Ns, Applied),
    Result = quod_trace:with_span(
               TraceCtx, <<"quod.prolog.prove">>, internal,
               #{'quod.namespace' => Ns, 'quod.kb.height' => Applied,
                 'quod.proof.mode' => atom_to_binary(Kind, utf8)},
               fun(SpanCtx) ->
                   R = run_worker(
                         Kind, ProofId, Deadline, Goal, Principal, Ns, Applied,
                         quod_predicates:set_context(Est, Ctx)),
                   _ = quod_trace:result(SpanCtx, R),
                   R
               end),
    gen_server:cast(Engine, {proof_result, Ref, Kind, Goal, CallerNs, Result}).

worker_context(action, Ns, Applied) ->
    quod_predicates:effect_context(Ns, Applied);
worker_context(_ProofKind, Ns, Applied) ->
    %% Subject remains none until signed subjects land.
    quod_predicates:proof_context(Ns, Applied, undefined).

run_worker(action, ProofId, Deadline, {Action, Structural}, Principal,
           Ns, Applied, Est) ->
    run_lifecycle_origin(
      ProofId, Deadline, Action, Structural, Principal, Ns, Applied, Est);
run_worker(Kind, ProofId, Deadline, Goal, _Principal, Ns, Applied, Est) ->
    run_origin_proof(Kind, ProofId, Deadline, Goal, Ns, Applied, Est).

run_origin_proof(Kind, ProofId, Deadline, Goal, Ns, Applied, Est) ->
    case quod_simplex:genesis_hash(Ns) of
        <<_:256>> = Anchor ->
            run_pinned_origin(
              Kind, ProofId, Deadline, undefined, Ns, Applied, Anchor, Est,
              fun(Origin) -> run_pinned_goal(Origin, Goal) end);
        undefined ->
            %% Isolated unit/runtime engines have no consensus identity and
            %% therefore cannot own foreign scopes. Their local proof contract
            %% remains the same shared-session interpreter.
            normalize_read_only_result(
              Kind,
              quod_proof_session:run_first(
                Goal, Est, #{read_set => true,
                             read_only => Kind =:= prove_ro}))
    end.

run_lifecycle_origin(ProofId, Deadline, Action, Structural, Principal,
                     Ns, Applied, Est) ->
    case quod_simplex:genesis_hash(Ns) of
        <<_:256>> = Anchor ->
            run_pinned_origin(
              action, ProofId, Deadline, Principal, Ns, Applied, Anchor, Est,
              fun(Origin) ->
                  run_lifecycle_action(Action, Structural, Origin)
              end);
        undefined ->
            %% A ready production engine always has its immutable genesis
            %% anchor. A test-only bare engine cannot safely mint distributed
            %% selector authority for a lifecycle effect.
            {error, rebuilding}
    end.

run_pinned_origin(Kind, ProofId, Deadline, Principal, Ns, Applied, Anchor,
                  Est, RunFun) ->
    ReadOnly = Kind =:= prove_ro orelse Kind =:= action,
    OriginIdentity = {Ns, Anchor},
    OriginHandle = quod_proof_context:start(
                     ProofId, ReadOnly, OriginIdentity, Deadline),
    OverlayOpts0 = #{read_set => true,
                     read_only => ReadOnly,
                     proof_context => {origin, OriginHandle}},
    OverlayOpts = case Principal of
                      undefined -> OverlayOpts0;
                      _ -> OverlayOpts0#{lifecycle_principal => Principal}
                  end,
    Context = quod_predicates:with_chain(
                quod_predicates:context(Est), [OriginIdentity]),
    try
        {ok, ScopeId,
         {local_scope, ScopeId, Ns, Anchor, Applied, Session}} =
            quod_proof_context:get_or_open_scope(
              OriginIdentity,
              fun(NewScopeId) ->
                  NewSession = quod_proof_session:start(
                                 Est, OverlayOpts#{scope_id => NewScopeId}),
                  {ok, self(),
                   {local_scope, NewScopeId, Ns, Anchor,
                    Applied, NewSession}}
              end),
        Origin = #pinned_origin{
                    proof_id = ProofId, scope_id = ScopeId,
                    deadline_ms = Deadline, kind = Kind,
                    namespace = Ns, anchor = Anchor, height = Applied,
                    context = Context, session = Session},
        try finalize_pinned_result(RunFun(Origin))
        after quod_proof_session:stop(Session)
        end
    after
        quod_proof_context:stop(
          fun close_origin_scope/1,
          fun({_Owner, Invocation}) -> quod_ask:close_stream(Invocation) end)
    end.

finalize_pinned_result(Result) ->
    case quod_proof_context:finalize() of
        ok -> Result;
        {error, Reason} -> {error, Reason}
    end.

run_pinned_goal(#pinned_origin{kind = Kind} = Origin, Goal) ->
    Result = normalize_read_only_result(
               Kind, run_origin_invocation(Origin, Goal)),
    case {Result, quod_proof_context:foreign_dirty()} of
        {{ok, _Bindings, _Diff, _ReadSet}, true} ->
            {error, foreign_write_unsupported};
        _ ->
            Result
    end.

run_origin_invocation(
  #pinned_origin{scope_id = ScopeId,
                 session = Session, context = Context}, Goal) ->
    InvocationId = crypto:strong_rand_bytes(16),
    Actor = {ScopeId, InvocationId},
    Selection = quod_transaction_scope:empty_selection(),
    case quod_proof_context:register_invocation(Actor, Selection) of
        ok ->
            try
                case quod_proof_session:open(
                       Session, InvocationId, Goal, Context, Selection) of
                    ok -> origin_first_result(Session, InvocationId);
                    {error, Reason} -> {error, Reason}
                end
            after
                quod_proof_session:cancel(Session, InvocationId),
                quod_proof_context:unregister_invocation(Actor)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

origin_first_result(Session, InvocationId) ->
    case quod_proof_session:next(Session, InvocationId) of
        {solution, _Solution} ->
            {ok, Bindings} = quod_proof_session:bindings(Session, InvocationId),
            {ok, Bindings,
             quod_proof_session:local_changes(Session),
             quod_proof_session:read_set(Session)};
        {complete, Reasons} ->
            {fail, Reasons};
        {error, Reason} ->
            {error, Reason}
    end.

normalize_read_only_result(
  prove_ro,
  {error, {erlog,
           {permission_error, modify, static_procedure, _Predicate}}}) ->
    {error, read_only};
normalize_read_only_result(_Kind, Result) ->
    Result.

close_origin_scope(
  {local_scope, _ScopeId, _Ns, _Anchor, _Height, _Session}) -> ok;
close_origin_scope(Scope) -> quod_scope_session:close(Scope).

run_lifecycle_action(Action, Structural, Origin) ->
    case lifecycle_action_declared(Action, Origin) of
        true ->
            prepare_lifecycle_input(Action, Structural, Origin);
        false ->
            {fail,
             [quod_ontology_predicates:failure_reason(
                Action, action_not_declared)]};
        {error, _Reason} ->
            {error, action_declaration_failed}
    end.

lifecycle_action_declared(Action, Origin) ->
    Goal =
        {',',
         {action, Action, {'Prerequisites'}, {'DesiredState'}},
         {'$quod_action_shape', Action,
          {'Prerequisites'}, {'DesiredState'}}},
    case run_origin_invocation(Origin, Goal) of
        {ok, _Bindings, [], _ReadSet} -> true;
        {fail, _Reasons} -> false;
        {error, _} = Error -> Error
    end.

lifecycle_authorized(Action, Origin) ->
    case run_origin_invocation(
           Origin, {authorized_ontology_lifecycle, Action}) of
        {ok, _Bindings, [], _ReadSet} ->
            ok;
        _ ->
            {error,
             quod_ontology_predicates:failure_reason(
               Action, not_authorized)}
    end.

prepare_lifecycle_input(Action, Structural, Origin) ->
    case lifecycle_authorized(Action, Origin) of
        ok ->
            case quod_ontology:prepare_action(Structural) of
                {ok, Prepared} ->
                    Goal =
                        {prepare_lifecycle_action, Action,
                         {'DesiredState'}, {'Mode'}},
                    Selection = run_origin_invocation(Origin, Goal),
                    complete_lifecycle_action(
                      Action, Prepared, Origin, Selection);
                {error, Reason} ->
                    {fail,
                     [quod_ontology_predicates:lifecycle_error(
                        Action, Reason)]}
            end;
        {error, Reason} ->
            {fail, [Reason]}
    end.

complete_lifecycle_action(Action, Prepared, Origin,
                          {ok, Bindings, [], _ReadSet})
  when is_map(Bindings) ->
    case {maps:find('DesiredState', Bindings), maps:find('Mode', Bindings)} of
        {{ok, DesiredState}, {ok, Mode}}
          when Mode =:= already; Mode =:= execute ->
            finish_lifecycle_action(
              Action, Prepared, Origin, DesiredState, Mode);
        _ ->
            {error, action_declaration_failed}
    end;
complete_lifecycle_action(_Action, _Prepared, _Origin,
                          {ok, _Bindings, _Diff, _ReadSet}) ->
    {error, lifecycle_staged_write};
complete_lifecycle_action(_Action, _Prepared, _Origin,
                          {error, {erlog,
                                   {permission_error, modify,
                                    static_procedure, _Predicate}}}) ->
    {error, lifecycle_staged_write};
complete_lifecycle_action(_Action, _Prepared, _Origin, Result) ->
    Result.

finish_lifecycle_action(Action, Prepared, Origin, DesiredState, Mode) ->
    case quod_predicates:is_ground(DesiredState) of
        false ->
            {error, action_declaration_failed};
        true ->
            case lifecycle_authorized(Action, Origin) of
                {error, Reason} ->
                    {fail, [Reason]};
                ok when Mode =:= already ->
                    lifecycle_success();
                ok ->
                    case quod_ontology_predicates:execute_prepared(
                           Action, Prepared) of
                        ok -> verify_lifecycle_state(DesiredState, Origin);
                        {error, outcome_unknown} -> {error, outcome_unknown};
                        {error, Reason} -> {fail, [Reason]}
                    end
            end
    end.

verify_lifecycle_state(DesiredState, Origin) ->
    case run_origin_invocation(Origin, DesiredState) of
        {ok, _Bindings, [], _ReadSet} -> lifecycle_success();
        _ -> {error, outcome_unknown}
    end.

lifecycle_success() -> {ok, #{}, [], #{}}.

finish_proof(Ref, Kind, Goal, CallerNs, Result, S) ->
    case take_proof_worker(Ref, S) of
        error -> S;
        {{From, Applied, TraceCtx}, S1} ->
            case {Kind, Result} of
                {_, {fail, []}} -> gen_server:reply(From, fail), S1;
                {_, {fail, Reasons}} -> gen_server:reply(From, {fail, Reasons}), S1;
                {_, {error, _} = E} -> gen_server:reply(From, E), S1;
                {_, {ok, Bindings, [], _ReadSet}} ->
                    gen_server:reply(From, {ok, [Bindings], Applied}), S1;
                {prove, {ok, Bindings, Diff, RS}} ->
                    case submit_write(From, Goal, Bindings, Diff, RS, CallerNs,
                                      TraceCtx, S1) of
                        {noreply, S2} -> S2;
                        {reply, Reply, S2} -> gen_server:reply(From, Reply), S2
                    end
            end
    end.

take_proof_worker(Ref, S = #s{workers = W}) ->
    case maps:take(Ref, W) of
        {#proof_worker{worker_mref = WorkerMRef, caller_mref = CallerMRef,
                       from = From, timer = TimerRef, trace_ctx = TraceCtx,
                       height = Applied}, W1} ->
            _ = erlang:cancel_timer(TimerRef),
            demonitor(WorkerMRef, [flush]),
            demonitor(CallerMRef, [flush]),
            {{From, Applied, TraceCtx}, S#s{workers = W1}};
        error -> error
    end.

%% The attached runtime died: clear its pin so history pruning resumes at the next commit.
%% (Its monitor already fired — no demonitor needed.)
handle_worker_down(MRef, _Reason, S = #s{runtime_pin = {_Pid, MRef, _F}}) ->
    {noreply, S#s{runtime_pin = none}};
handle_worker_down(MRef, Reason,
                   S = #s{scope_workers = Workers,
                          scope_owners = Owners,
                          remote_request_mrefs = RequestRefs,
                          remote_return_mrefs = ReturnRefs}) ->
    case maps:find(MRef, Workers) of
        {ok, Worker} ->
            {noreply, handle_scope_worker_down(MRef, Reason, Worker, S)};
        error ->
            case maps:get(MRef, RequestRefs, undefined) of
                Binding when is_tuple(Binding) ->
                    {noreply, drop_remote_scope(Binding, S)};
                undefined ->
                    case maps:get(MRef, ReturnRefs, undefined) of
                        ReturnBinding when is_tuple(ReturnBinding) ->
                            {noreply, drop_remote_scope(ReturnBinding, S)};
                        undefined ->
                            handle_scope_owner_down(
                              MRef, Reason, Owners, S)
                    end
            end
    end.

handle_scope_worker_down(MRef, _Reason,
                         #scope_worker{terminating = true}, S) ->
    drop_scope_worker(MRef, S);
handle_scope_worker_down(
  MRef, Reason, #scope_worker{scope_key = {remote, Binding}},
  S = #s{remote_scopes = Remote}) ->
    case maps:find(Binding, Remote) of
        {ok, Scope} ->
            {RequestId, CommandSeq} = remote_timeout_correlation(Scope),
            PublicReason = scope_worker_failure(
                             Reason, target_namespace(Binding)),
            S1 = emit_scope_event(
                   Binding, RequestId, CommandSeq,
                   {scope_error, PublicReason}, S),
            drop_scope_worker(MRef, S1);
        error ->
            drop_scope_worker(MRef, S)
    end;
handle_scope_worker_down(MRef, _Reason, #scope_worker{}, S) ->
    %% A co-hosted caller monitors this worker directly and receives its exact
    %% typed exit reason; the engine only owns resource cleanup here.
    drop_scope_worker(MRef, S).

scope_worker_failure({scope_error, Reason}, Ns) ->
    public_scope_reason(Reason, Ns);
scope_worker_failure(killed, Ns) ->
    {proof_limit_exceeded, Ns};
scope_worker_failure(_Reason, _Ns) ->
    {protocol_error, proof_engine}.

handle_scope_owner_down(MRef, Reason, Owners, S) ->
    case maps:get(MRef, Owners, undefined) of
                WorkerMRef when is_reference(WorkerMRef) ->
                    {noreply, kill_scope_worker(WorkerMRef, S)};
                _ -> handle_proof_down(MRef, Reason, S)
    end.

handle_proof_down(MRef, Reason, S = #s{workers = W}) ->
    case find_proof_monitor(MRef, W) of
        {worker, Ref, From, Kind} ->
            case take_proof_worker(Ref, S) of
                {{_From, _Height, _TraceCtx}, S1} ->
                    Reply = proof_down_reply(Kind, Reason, S#s.ns),
                    gen_server:reply(From, Reply),
                    {noreply, S1};
                error -> {noreply, S}
            end;
        {caller, Ref, Pid} ->
            kill_worker(Pid),
            case take_proof_worker(Ref, S) of
                {{_From, _Height, _TraceCtx}, S1} -> {noreply, S1};
                error -> {noreply, S}
            end;
        false -> unhandled
    end.

find_proof_monitor(MRef, W) ->
    maps:fold(
      fun(Ref, #proof_worker{pid = Pid, kind = Kind,
                             worker_mref = WorkerMRef,
                             caller_mref = CallerMRef, from = From}, Acc) ->
          case Acc of
              false when WorkerMRef =:= MRef -> {worker, Ref, From, Kind};
              false when CallerMRef =:= MRef -> {caller, Ref, Pid};
              _ -> Acc
          end
      end, false, W).

proof_down_reply(action, _Reason, _Ns) ->
    {error, outcome_unknown};
proof_down_reply(_Kind, killed, Ns) ->
    {error, {proof_limit_exceeded, Ns}};
proof_down_reply(_Kind, _Reason, _Ns) ->
    {error, {protocol_error, proof_worker_crash}}.

arm_scope_step(WorkerMRef, S = #s{scope_workers = Workers,
                                   scope_step_timeout_ms = StepTimeout}) ->
    case maps:get(WorkerMRef, Workers, undefined) of
        #scope_worker{pending = false, terminating = false} = Worker ->
            Token = make_ref(),
            Timer = erlang:send_after(StepTimeout, self(),
                                      {scope_step_kill, WorkerMRef, Token}),
            S#s{scope_workers = Workers#{WorkerMRef =>
                Worker#scope_worker{pending = true, timer = Timer,
                                    token = Token}}};
        _ -> S
    end.

disarm_scope_step(WorkerMRef, S0 = #s{scope_workers = Workers}) ->
    case maps:get(WorkerMRef, Workers, undefined) of
        #scope_worker{timer = Timer} = Worker ->
            cancel_scope_timer(Timer),
            Worker1 = Worker#scope_worker{
                        pending = false, timer = undefined,
                        token = undefined},
            S0#s{scope_workers = Workers#{WorkerMRef => Worker1}};
        _ -> S0
    end.

%% Timeout ownership stays at the target engine.  Active derivations and idle
%% lifetime expiry are deliberately different public failures; neither is
%% inferred from an origin-side receive timeout.  Remote scopes publish the
%% authenticated terminal event before their worker, timers, monitors and MVCC
%% pin are removed.  Co-hosted scopes carry the same typed reason in the worker
%% exit signal, which their direct caller monitor observes.
expire_scope_worker(Phase, WorkerMRef,
                    S = #s{ns = Ns, scope_workers = Workers,
                           scope_sessions = Sessions}) ->
    Reason = scope_timeout_reason(Phase, Ns),
    case maps:get(WorkerMRef, Workers, undefined) of
        #scope_worker{scope_key = {remote, Binding}} ->
            expire_remote_scope_with_reason(Binding, Reason, S);
        #scope_worker{pid = Pid, scope_key = ScopeKey} ->
            notify_cohost_scope_timeout(
              ScopeKey, Reason, Sessions),
            exit_scope_worker(Pid, Reason),
            mark_scope_worker_terminating(WorkerMRef, S);
        undefined ->
            S
    end.

scope_timeout_reason(active, Ns) -> {proof_limit_exceeded, Ns};
scope_timeout_reason(idle, Ns) -> {scope_expired, Ns}.

notify_cohost_scope_timeout(
  {Origin, _ProofId, _ScopeId} = ScopeKey, Reason, Sessions)
  when is_pid(Origin) ->
    case maps:find(ScopeKey, Sessions) of
        {ok, {Handle, _WorkerMRef, _ReadOnly}} ->
            Origin ! {quod_scope_down, Handle, {scope_error, Reason}},
            ok;
        error ->
            ok
    end;
notify_cohost_scope_timeout(_ScopeKey, _Reason, _Sessions) ->
    ok.

expire_remote_scope_with_reason(
  Binding, Reason, S = #s{remote_scopes = Remote}) ->
    case maps:find(Binding, Remote) of
        {ok, Scope = #remote_scope{worker_mref = WorkerMRef}}
          when is_reference(WorkerMRef) ->
            {RequestId, CommandSeq} = remote_timeout_correlation(Scope),
            S1 = emit_scope_event(
                   Binding, RequestId, CommandSeq,
                   {scope_error,
                    public_scope_reason(
                      Reason, target_namespace(Binding))}, S),
            case maps:get(WorkerMRef, S1#s.scope_workers, undefined) of
                #scope_worker{pid = Pid, terminating = false} ->
                    exit_scope_worker(Pid, Reason),
                    mark_scope_worker_terminating(WorkerMRef, S1);
                #scope_worker{} ->
                    S1;
                undefined ->
                    drop_remote_record(Binding, S1)
            end;
        {ok, _OpeningScope} ->
            %% No admitted proof worker exists yet, hence there is no MVCC pin
            %% to retain and no authenticated return link on which to publish
            %% a target event. Cleanup is immediate.
            drop_remote_record(Binding, S);
        error ->
            S
    end.

remote_timeout_correlation(
  #remote_scope{active_commands = [Current | _]}) ->
    Current;
remote_timeout_correlation(
  #remote_scope{last_request_id = RequestId,
                next_command_seq = NextCommandSeq}) ->
    {RequestId, max(1, NextCommandSeq - 1)}.

exit_scope_worker(Pid, Reason) ->
    unlink(Pid),
    exit(Pid, {scope_error, Reason}).

kill_scope_worker(WorkerMRef, S = #s{scope_workers = Workers}) ->
    case maps:get(WorkerMRef, Workers, undefined) of
        #scope_worker{pid = Pid, terminating = false} ->
            kill_worker(Pid),
            mark_scope_worker_terminating(WorkerMRef, S);
        #scope_worker{} ->
            S;
        _ -> S
    end.

mark_scope_worker_terminating(
  WorkerMRef,
  S = #s{scope_workers = Workers, scope_sessions = ScopeSessions}) ->
    case maps:get(WorkerMRef, Workers, undefined) of
        #scope_worker{scope_key = ScopeKey,
                      timer = Timer,
                      lifetime_timer = LifetimeTimer} = Worker ->
            cancel_scope_timer(Timer),
            cancel_scope_timer(LifetimeTimer),
            Worker1 = Worker#scope_worker{
                        timer = undefined, token = undefined,
                        lifetime_timer = undefined,
                        lifetime_token = undefined,
                        terminating = true},
            S1 = S#s{
                   scope_workers = Workers#{WorkerMRef => Worker1},
                   scope_sessions = maps:remove(
                                      ScopeKey, ScopeSessions)},
            case ScopeKey of
                {remote, Binding} -> retire_remote_scope_timer(Binding, S1);
                _ -> S1
            end;
        undefined ->
            S
    end.

retire_remote_scope_timer(Binding, S = #s{remote_scopes = Remote}) ->
    case maps:find(Binding, Remote) of
        {ok, Scope = #remote_scope{lifetime_timer = Timer}} ->
            cancel_scope_timer(Timer),
            put_remote_scope(
              Scope#remote_scope{
                lifetime_timer = undefined,
                lifetime_token = undefined,
                state = closing}, S);
        error ->
            S
    end.

drop_scope_worker(WorkerMRef,
                  S = #s{scope_workers = Workers,
                         scope_owners = Owners,
                         scope_pids = Pids,
                         scope_sessions = ScopeSessions}) ->
    case maps:take(WorkerMRef, Workers) of
        {#scope_worker{pid = Pid, owner_mref = OwnerMRef,
                       scope_key = ScopeKey,
                       timer = Timer,
                       lifetime_timer = LifetimeTimer}, Workers1} ->
            cancel_scope_timer(Timer),
            cancel_scope_timer(LifetimeTimer),
            demonitor(WorkerMRef, [flush]),
            demonitor(OwnerMRef, [flush]),
            S1 = S#s{scope_workers = Workers1,
                     scope_owners = maps:remove(OwnerMRef, Owners),
                     scope_pids = maps:remove(Pid, Pids),
                     scope_sessions = maps:remove(
                                        ScopeKey, ScopeSessions)},
            case ScopeKey of
                {remote, Binding} -> drop_remote_record(Binding, S1);
                _ -> S1
            end;
        error -> S
    end.

cancel_scope_timer(undefined) -> ok;
cancel_scope_timer(Timer) -> _ = erlang:cancel_timer(Timer), ok.

new_scope_worker(Pid, _WorkerMRef, OwnerMRef, ScopeKey, Height, none) ->
    #scope_worker{pid = Pid, owner_mref = OwnerMRef,
                  scope_key = ScopeKey, height = Height};
new_scope_worker(Pid, WorkerMRef, OwnerMRef, ScopeKey, Height,
                 LifetimeMs) ->
    Token = make_ref(),
    Timer = erlang:send_after(
              LifetimeMs, self(),
              {scope_lifetime_kill, WorkerMRef, Token}),
    #scope_worker{pid = Pid, owner_mref = OwnerMRef,
                  scope_key = ScopeKey, height = Height,
                  lifetime_timer = Timer, lifetime_token = Token}.

kill_worker(Pid) ->
    unlink(Pid),
    exit(Pid, kill).

-doc """
Prove `Goal` against a raw committed `#est{}` handle, in the calling process, through the
local-prove overlay (staged writes never touch the shared KB table). Returns
`{ok, Bindings, StagedChanges, ReadSet} | fail | {error, _}`. This is a strictly local adapter
used by `m:quod_runtime` and committed policy subproofs; a foreign `::` returns
`{error, {ask_requires_anchored_proof, Namespace}}`, while an exact self-selection stays
in place. Runtime handlers set a semantic context via `quod_predicates:set_context/2` and
treat a non-empty `StagedChanges` as a projection violation. The caller must hold a snapshot
guarantee for the est (a proof-worker height entry or the runtime floor pin), or reads can
race history pruning.
""".
-spec prove_est(term(), tuple()) ->
          {ok, [map()] | map(), list(), map()} | fail | {error, term()}.
prove_est(Goal, Est) -> run_proof_est(Goal, Est).

-doc "Prove against a raw committed state while rejecting every database mutation.".
-spec prove_est_read_only(term(), tuple()) ->
          {ok, [map()] | map(), list(), map()} | fail | {error, term()}.
prove_est_read_only(Goal, Est) ->
    run_proof_est(Goal, Est, #{read_only => true}).

run_proof_est(Goal, Est) ->
    run_proof_est(Goal, Est, #{}).

run_proof_est(Goal, Est, OverlayOpts) ->
    case run_proof_est_annotated(Goal, Est, OverlayOpts) of
        {fail, _Reasons} -> fail;
        Result -> Result
    end.

run_proof_est_annotated(Goal, Est, OverlayOpts) ->
    quod_proof_session:run_first(
      Goal, Est, OverlayOpts#{read_set => true}).

%% Only own-namespace writes. Submit with OTP's asynchronous gen_statem request API,
%% then park the caller until ordered apply (or a definite consensus rejection). This
%% keeps the KB free to prove and apply while consensus runs, without spawning one
%% blocked helper process for every write.
submit_write(From, Goal, Bindings, Diff, ReadSet, CallerNs, TraceCtx,
             S = #s{ns = Ns}) when CallerNs =:= Ns ->
    Tx     = tx_id(S#s.self),
    Change = #transaction{tx_id = Tx, caller_ns = CallerNs, goal = Goal, result = Bindings, diff = Diff,
                     read_check = ReadSet, author = S#s.self,
                     submitted_at = quod_time:now_ms(), sig = none},
    {TransactionCtx, SpanCtx} = quod_trace:start_span(
                                  TraceCtx, <<"quod.transaction">>, internal,
                                  #{'quod.namespace' => Ns,
                                    'quod.tx.id' => quod_trace:tx_id(Tx),
                                    'quod.kb.read_height' => S#s.applied,
                                    'quod.diff.operations' => length(Diff)}),
    _ = quod_trace:add_event(TransactionCtx, <<"transaction.proved">>, #{}),
    try gen_statem:send_request(
          quod_reg:via({quod_simplex, Ns}), {append, Change, TransactionCtx}) of
        ReqId ->
            Requests1 = gen_statem:reqids_add(ReqId, Tx, S#s.requests),
            TRef = erlang:send_after(S#s.ttl, self(), {park_timeout, Tx}),
            %% T0 anchors the tx-latency histogram: same node, same monotonic clock
            %% as the observation in release/4 — never a cross-node wall-clock delta.
            T0 = quod_time:mono_ms(),
            S1 = S#s{parked = (S#s.parked)#{Tx =>
                       {From, [Bindings], S#s.applied, TRef, ReqId, SpanCtx, T0}},
                     requests = Requests1},
            {noreply, S1}
    catch
        error:badarg ->
            quod_trace:finish_span(SpanCtx, {error, consensus_unavailable}),
            {reply, {error, consensus_unavailable}, S}
    end;
submit_write(_From, _Goal, _B, _D, _R, _CallerNs, _TraceCtx, S) ->
    {reply, {error, foreign_write_unsupported}, S}.

append_result(Tx, {ok, Slot}, S) ->
    request_completed(Tx, mark_consensus_reply(Tx, Slot, S));
append_result(Tx, {error, not_in_charge, unavailable}, S) ->
    request_completed(Tx, S);   %% ambiguous: ordered apply may still resolve it; the TTL reports unknown
append_result(Tx, {error, not_in_charge, Hint}, S) ->
    reject_parked(Tx, {error, {not_leader, Hint}}, request_completed(Tx, S));
%% Ordinary signed content is retained inside Simplex across exclusion. Only
%% the deliberately non-custodied membership path reaches this terminal
%% skip/re-proof response.
append_result(Tx, {error, skipped}, S = #s{ns = Ns}) ->
    quod_metrics:count_tx_retry(Ns, membership_skipped),
    reject_parked(Tx, {error, retry}, request_completed(Tx, S));
%% A locally confirmed author sequence was superseded. The content is fine:
%% re-prove and sign with a fresh sequence, so surface it retryably.
append_result(Tx, {error, stale_seq}, S = #s{ns = Ns}) ->
    quod_metrics:count_tx_retry(Ns, stale_sequence),
    reject_parked(Tx, {error, retry}, request_completed(Tx, S));
append_result(Tx, {error, Reason}, S) ->
    reject_parked(Tx, {error, Reason}, request_completed(Tx, S));
append_result(Tx, Other, S) ->
    reject_parked(Tx, {error, {consensus_reply, Other}}, request_completed(Tx, S)).

request_completed(Tx, S = #s{parked = Parked}) ->
    case maps:get(Tx, Parked, undefined) of
        {From, Bindings, Height, TRef, _ReqId, SpanCtx, T0} ->
            S#s{parked = Parked#{Tx =>
                   {From, Bindings, Height, TRef, none, SpanCtx, T0}}};
        undefined ->
            S
    end.

mark_consensus_reply(Tx, Slot, S = #s{parked = Parked}) ->
    case maps:get(Tx, Parked, undefined) of
        {_From, _Bindings, _Height, _TRef, _ReqId, SpanCtx, _T0} ->
            _ = quod_trace:set_attributes(SpanCtx, #{'quod.consensus.slot' => Slot}),
            S;
        undefined ->
            S
    end.

%%%===================================================================
%%% apply (deterministic; identical on every member)
%%%===================================================================

%% Apply one committed entry, then — in a SHARED tail across every applied-advancing path — resolve any
%% membership verdict parked for the parent height we just reached. Whether the applied step commits a
%% tx, skips a `noop`, or logs an unexpected payload, a validation whose parent is that slot must be
%% answered (and never leak), so `resolve_validations/1` runs once here, keyed on the new `applied`.
%% Each verdict's `can_join` re-proof reads the parent height from the verdict execution context that
%% `membership_verdict/2` builds from `S#s.applied` (see `m:quod_predicates`).
apply_committed(Index, Change, Origin, S) ->
    resolve_validations(apply_step(Index, Change, Origin, S)).

%% Each clause returns the new #s{}. Index is the committed entry's log index; entries
%% arrive in order on the (FIFO) cast channel from quod_simplex. `Origin` (live|replay) reaches
%% apply_transaction, which yields a post-apply outcome event only for a LIVE-applied tx —
%% buffered through the block fold, published post-commit by flush_outcomes/2.
%%
%% Already applied (e.g. a rebuild re-drive): idempotent no-op.
apply_step(Index, _Change, _Origin, S = #s{applied = A}) when Index =< A ->
    S;
%% Forward gap: quod_simplex is ahead of us (we restarted, or missed a cast). Don't apply out
%% of order — ask quod_simplex to re-drive from the snapshot so we receive a contiguous run.
apply_step(Index, _Change, _Origin, S = #s{ns = Ns, applied = A}) when Index > A + 1 ->
    _ = try quod_simplex:rebuild(Ns) catch _:_ -> ok end,
    S;
%% Index == applied+1. Every committed entry kind is enumerated here: a kind this
%% node cannot apply advances the cursor instead of restart-looping on old/corrupt
%% data, but it is never confused with a kind that legitimately applies nothing.
%%
%% Outcome events are BUFFERED through the fold and flushed only after `publish_snapshot`
%% commits the block's MVCC version: an event consumer (the runtime) must observe the tx's
%% effects as committed state, and the snapshot handle sent with `applied_live` is only valid
%% at the block height once the commit ran. All of a block's envelopes therefore share the
%% block-final snapshot (plan §8: "frozen MVCC snapshot at the applied height" — the height is
%% the block's).
apply_step(Index, Data, Origin, S) ->
    case quod_ledger:classify(Data) of
        {content, Transactions} ->
            {S1, RevEvents} =
                lists:foldl(fun(T, {Acc, Evs}) ->
                                    {Acc1, Ev} = apply_transaction(T, Index, Origin, Acc),
                                    {Acc1, [Ev | Evs]}
                            end, {S, []}, Transactions),
            flush_outcomes(lists:reverse(RevEvents), publish_snapshot(Index, S1));
        noop ->
            publish_snapshot(Index, S);
        invalid ->
            skip_unexpected(Index, Data, S)
    end.

apply_transaction(#transaction{tx_id = Tx, diff = Diff} = Change, Index, Origin, S) ->
    %% A committee-changing transaction applies UNCONDITIONALLY — skip the OCC read-check. It was
    %% re-validated against the parent state before the vote (`membership_verdict/2`), so OCC is
    %% redundant here AND is the source of a real divergence: `quod_simplex:adopt_committee` folds the
    %% validator set unconditionally at commit, so an OCC-skipped membership diff would leave the KB fact
    %% behind the validator set. Applying it here keeps the two projections in lockstep. (On a single
    %% `peer_admitted` op — Slice A guarantees exactly one — apply is idempotent: an already-present
    %% assert dedups, an absent retract is a no-op.) Content txs keep OCC.
    case is_membership_change(Change) of
        true ->
            {ok, Est1} = quod_diff:apply_ops(S#s.est, Diff),
            S1 = release(Tx, {ok, {applied, Index}},
                         fun(From, B, _ReadHeight) ->
                             gen_server:reply(From, {ok, B, Index})
                         end,
                         S#s{est = Est1, applies = S#s.applies + 1}),
            {S1, outcome_applied(Change, Index, Origin, S1)};
        false ->
            apply_content(Change, Index, Origin, S)
    end.

skip_unexpected(Index, Other, S = #s{ns = Ns}) ->
    logger:warning("quod_prolog[~s]: skipping unexpected committed payload at ~p: ~0p", [Ns, Index, Other]),
    publish_snapshot(Index, S).

publish_snapshot(Index, S = #s{est = #est{db = #db{mod = quod_erlog_db_mvcc,
                                                     ref = Ref0} = Db} = Est}) ->
    Floor = oldest_snapshot(Index, S),
    Ref1 = quod_erlog_db_mvcc:commit(Ref0, Index, Floor),
    S#s{est = Est#est{db = Db#db{ref = Ref1}}, applied = Index}.

oldest_snapshot(Current, #s{workers = Workers,
                            scope_workers = ScopeWorkers,
                            runtime_pin = Pin}) ->
    ProofFloor = maps:fold(
                   fun(_Ref, #proof_worker{height = Height}, Floor) ->
                       min(Height, Floor)
                   end, Current, Workers),
    ScopeFloor = maps:fold(
                   fun(_Ref, #scope_worker{height = Height}, Floor) ->
                       min(Height, Floor)
                   end, ProofFloor, ScopeWorkers),
    case Pin of
        {_Pid, _MRef, PinFloor} -> min(PinFloor, ScopeFloor);
        none -> ScopeFloor
    end.

%% A normal content transaction: OCC re-check the read-set, then apply the diff or reject.
apply_content(#transaction{tx_id = Tx, diff = Diff, read_check = RC} = Change, Index, Origin, S) ->
    #est{db = #db{mod = quod_erlog_db_mvcc, ref = R}} = S#s.est,
    case quod_diff:validate(RC, R) of
        ok ->
            {ok, Est1} = quod_diff:apply_ops(S#s.est, Diff),
            S1 = release(Tx, {ok, {applied, Index}},
                         fun(From, B, _ReadHeight) ->
                             gen_server:reply(From, {ok, B, Index})
                         end,
                         S#s{est = Est1, applies = S#s.applies + 1}),
            {S1, outcome_applied(Change, Index, Origin, S1)};
        {conflict, _F} ->
            %% OCC-rejected: D is unchanged, but the transaction WAS committed (it is in the block),
            %% so a live apply still announces the outcome — `rejected_live` — so an observer distinguishes
            %% "committed and applied" from "committed but rejected at apply" without inferring it from a
            %% later commit. Replay stays silent (rebuild only). Its cross-node consistency is the same as
            %% the OCC verdict itself: deterministic on every member.
            S1 = release(Tx, {error, {conflict_retry, Index}},
                         fun(From, _B, _H) -> gen_server:reply(From, {error, conflict_retry}) end,
                         S#s{rejects = S#s.rejects + 1, conflicts = S#s.conflicts + 1}),
            {S1, outcome_rejected(Change, Index, Origin, S1)}
    end.

%% A committee-changing tx = its diff asserts/retracts `peer_admitted` (a PURE fold in quod_simplex —
%% no process message, so no append<->apply deadlock).
is_membership_change(Change) -> quod_simplex:committee_delta(Change) =/= {[], []}.

%%%===================================================================
%%% post-apply event layer (doc/agent-fipa-plan.md §7)
%%%===================================================================
%%
%% The `{runtime, Ns}` property carries these messages for the explorer (`m:quod_explorer_ws`) and any
%% observer: `{applied_live, Env}` (one per live-applied transaction that changed D), `{rejected_live,
%% Env}` (one per live transaction that committed but was OCC-rejected at apply), and the
%% `{replay_started, Id, From}` / `{replay_ready, Id, Height}` boundaries of a replay run (`Id` is
%% `boot` for the quiet-boot ready edge). The ATTACHED runtime (`attach_runtime/1`) additionally
%% receives each applied envelope as a direct `{applied_live, Env, Est}` carrying the post-commit
%% snapshot handle — see flush_outcomes/2 for why the handle is never broadcast. The pre-apply
%% `{committed, Ns}` publication (quod_simplex → feed/metrics) is untouched and is deliberately NOT the
%% agent event source (it fires before this kb has applied).
%%
%% CONSUMER CONTRACT for the attached runtime (`m:quod_runtime`, Slice 2) — the seam creates these
%% obligations, verified by review; honour them there:
%%   1. `applied_live` arrives on BOTH channels (2-tuple on the property for the explorer/observers,
%%      3-tuple direct with the snapshot). A runtime that also subscribes for the boundaries must act on
%%      the 3-tuple ONLY and ignore the property's 2-tuple `applied_live`/`rejected_live` — else it
%%      double-processes every tx.
%%   2. On the replay→live resume, the resuming live block's direct `applied_live` is delivered just
%%      BEFORE its `{replay_ready, Id, _}` boundary (the boundary is published after apply_committed
%%      returns). Gate on the boundary: reconcile at `replay_ready` captures that block from the fresh
%%      snapshot, so never treat a pre-ready `applied_live` as live.
%%   3. A replay-start notification does NOT immediately clear the floor pin: the runtime first
%%      kills and reaps every old-snapshot reader, then calls runtime_detach/1. This prevents MVCC
%%      pruning from racing a projection while still releasing history during a long replay.
%%   4. The pin is one-way monitored (this kb watches the runtime, not vice-versa). A kb restart voids
%%      the carried `Est` with no back-signal, so the runtime MUST be supervised `rest_for_one` AFTER
%%      `quod_prolog` — a kb crash then restarts the runtime, which re-attaches on the fresh ready edge.

%% Track the live/replay lifecycle, emitting the replay boundaries ONLY when the apply `Advanced` the
%% committed height — so an already-applied no-op or a forward-gap cast never emits a false boundary.
%% `Before` is the pre-apply height: the height a replay run opened from (`replay_started`), or the
%% height replay reached before the resuming live block (`replay_ready`). A replay run (boot rebuild or a
%% runtime gap-fill) opens on the first advancing `replay` apply and closes on its ready edge — the first
%% advancing `live` apply, or `mark_ready` at boot. The correlating `Id` lets a consumer ignore a stale
%% boundary from a superseded run. Simplex explicitly casts `mark_ready` after every completed
%% recovery, so a quiet head closes the interval without waiting for another live block.
note_origin(_Origin, false, _Before, S) -> S;   %% apply did not advance ⇒ no lifecycle change
note_origin(replay, true, Before, S = #s{runtime_mode = live, ns = Ns}) ->
    Id = make_ref(),
    publish_runtime(Ns, {replay_started, Id, Before}),
    %% Keep the pin until quod_runtime has killed and reaped every reader of its old snapshot.
    %% It then calls runtime_detach/1; the next replay commit can prune released history. An
    %% eager clear here races the runtime's event/heavy workers and invalidates their MVCC view.
    S#s{runtime_mode = {replaying, Id}};
note_origin(live, true, Before, S = #s{runtime_mode = {replaying, Id}, ns = Ns}) ->
    publish_runtime(Ns, {replay_ready, Id, Before}),
    S#s{runtime_mode = live};
note_origin(_Origin, true, _Before, S) -> S.   %% replay while already replaying, or live while already live

%% One event per committed transaction that actually changed D, on a LIVE commit only — never replay
%% (content-layer-design §14 live-vs-replay). `Subject` is `undefined` until signed subjects (§10).
%% Built during the block fold, PUBLISHED by flush_outcomes/2 after the MVCC commit.
outcome_applied(#transaction{tx_id = Tx, goal = G, result = Res, diff = Diff}, Index, live, #s{ns = Ns}) ->
    {applied, #{ns => Ns, height => Index, tx_id => Tx, subject => undefined,
                goal => G, result => Res, diff => Diff}};
outcome_applied(_Change, _Index, replay, _S) -> none.

%% One event per committed-but-OCC-rejected transaction, on a LIVE commit only. Mirrors
%% `outcome_applied` so every live tx in a block yields exactly one outcome event (applied or
%% rejected); D is unchanged, so the envelope carries no diff/result.
outcome_rejected(#transaction{tx_id = Tx, goal = G}, Index, live, #s{ns = Ns}) ->
    {rejected, #{ns => Ns, height => Index, tx_id => Tx, subject => undefined, goal => G}};
outcome_rejected(_Change, _Index, replay, _S) -> none.

%% Publish the block's buffered outcomes in fold order, post-commit. The `{runtime, Ns}`
%% property carries the est-FREE envelopes (explorer + any observer); the committed snapshot
%% handle rides ONLY the direct send to the pinned runtime — a live read capability over the
%% KB table must not be broadcast to unpinned subscribers, whose reads could otherwise race
%% history pruning.
flush_outcomes([], S) -> S;
flush_outcomes([none | Rest], S) -> flush_outcomes(Rest, S);
flush_outcomes([{applied, Env} | Rest], S = #s{ns = Ns, est = Est, runtime_pin = Pin}) ->
    publish_runtime(Ns, {applied_live, Env}),
    _ = case Pin of
            {Pid, _MRef, _F} -> Pid ! {applied_live, Env, Est};
            none             -> ok
        end,
    flush_outcomes(Rest, S);
flush_outcomes([{rejected, Env} | Rest], S = #s{ns = Ns}) ->
    publish_runtime(Ns, {rejected_live, Env}),
    flush_outcomes(Rest, S).

publish_runtime(Ns, Msg) -> _ = quod_reg:publish({runtime, Ns}, Msg), ok.

%% Drop the runtime pin and its monitor (on re-attach or DOWN). The demonitor flush purges any
%% already-queued DOWN so a stale one can't later clear a freshly-installed pin.
clear_runtime_pin(S = #s{runtime_pin = {_Pid, MRef, _F}}) ->
    erlang:demonitor(MRef, [flush]),
    S#s{runtime_pin = none};
clear_runtime_pin(S) -> S.

%% Deliver the verdict to a parked caller (only on the submitting node) and cancel
%% its TTL. ReplyFun :: (From, Bindings, Height) -> _. A successful outcome is THE
%% end-to-end latency sample: submit (T0) to committed-and-applied-here, one node,
%% one monotonic clock — the only latency this system reports, because any metric
%% derived from block timestamps compares two machines' wall clocks.
release(Tx, Outcome, ReplyFun, S = #s{ns = Ns, parked = P}) ->
    case maps:take(Tx, P) of
        {{From, B, H, TRef, ReqId, SpanCtx, T0}, P1} ->
            _ = erlang:cancel_timer(TRef),
            _ = case Outcome of
                    {ok, {applied, _}} ->
                        quod_metrics:observe_tx_latency(Ns, quod_time:mono_ms() - T0);
                    _ ->
                        ok
                end,
            _ = set_final_trace_attributes(SpanCtx, Outcome),
            quod_trace:finish_span(SpanCtx, Outcome),
            ReplyFun(From, B, H),
            S#s{parked = P1, requests = abandon_request(ReqId, S#s.requests)};
        error -> S
    end.

set_final_trace_attributes(SpanCtx, {ok, {applied, Height}}) ->
    quod_trace:set_attributes(SpanCtx, #{'quod.kb.applied_height' => Height});
set_final_trace_attributes(SpanCtx, {error, {_Reason, Height}}) ->
    quod_trace:set_attributes(SpanCtx, #{'quod.kb.applied_height' => Height});
set_final_trace_attributes(_SpanCtx, _Outcome) ->
    false.

reject_parked(Tx, Reply, S) ->
    release(Tx, Reply,
            fun(From, _Bindings, _Height) -> gen_server:reply(From, Reply) end, S).

abandon_request(none, Requests) ->
    Requests;
abandon_request(ReqId, Requests) ->
    %% A zero-time receive consumes an already-arrived reply or deactivates the alias so
    %% a future reply cannot become an unmatched mailbox message.
    _ = catch gen_statem:receive_response(ReqId, 0),
    drop_request(ReqId, Requests).

drop_request(ReqId, Requests) ->
    lists:foldl(
      fun({ReqId0, Label}, Acc) when ReqId0 =/= ReqId ->
              gen_statem:reqids_add(ReqId0, Label, Acc);
         ({_ReqId0, _Label}, Acc) ->
              Acc
      end, gen_statem:reqids_new(), gen_statem:reqids_to_list(Requests)).

%%%===================================================================
%%% membership verdict (the Prolog-side re-check of a committee change)
%%%===================================================================
%%
%% A validator re-judges a proposed committee change against ITS OWN kb before voting, so a committee
%% is a projection of the `peer_admitted` FACTS on every node — never something a single submitter can
%% forge. The verdict is pinned to the proposal's PARENT height (`Slot-1`): the same past kb state on
%% every honest node ⇒ the same verdict, so honest votes never split. Delivered asynchronously (a cast
%% back), because a synchronous call here would deadlock the append<->apply cycle.

%% A re-issued Tag (a re-proposed slot after a view change) SUPERSEDES any request still parked under it:
%% drop the stale entry and cancel its timer first, so an orphaned timer can never fire against the new
%% request and reap it to a premature abstain. The superseded request's `ReplyTo` hears back via the fresh
%% verdict for the same Tag.
request_verdict(Change, Slot, ReplyTo, Tag, S0) ->
    do_request_verdict(Change, Slot, ReplyTo, Tag, supersede_validation(Tag, S0)).

%% Judge `Change` at height `Slot-1`: answer now if the kb is exactly there, park if it is behind, or
%% abstain if it is already past the slot (which resolved without us — slots are never reused).
do_request_verdict(Change, Slot, ReplyTo, Tag, S = #s{applied = A}) when A =:= Slot - 1 ->
    deliver_verdict(ReplyTo, Tag, membership_verdict(Change, S)), S;
do_request_verdict(Change, Slot, ReplyTo, Tag, S = #s{applied = A, validations = V, vttl = Vttl})
  when A < Slot - 1 ->
    TRef = erlang:send_after(Vttl, self(), {validation_timeout, Tag}),
    S#s{validations = V#{Tag => {Slot, Change, ReplyTo, TRef}}};
do_request_verdict(_Change, _Slot, ReplyTo, Tag, S) ->   %% applied > Slot-1: too late, the slot is decided
    deliver_verdict(ReplyTo, Tag, abstain), S.

supersede_validation(Tag, S = #s{validations = V}) ->
    case maps:take(Tag, V) of
        {{_Slot, _Change, _ReplyTo, OldTRef}, V1} -> _ = erlang:cancel_timer(OldTRef), S#s{validations = V1};
        error                                     -> S
    end.

%% Once the kb reaches a slot, answer every verdict parked for that slot's children (parent == applied).
%% Judged against the just-advanced `est` (state exactly at the parent height). Cancels each timer.
resolve_validations(S = #s{applied = A, validations = V}) ->
    Ready = [{Tag, Rec} || {Tag, {Slot, _, _, _} = Rec} <- maps:to_list(V), Slot =:= A + 1],
    lists:foldl(
      fun({Tag, {_Slot, Change, ReplyTo, TRef}}, Acc) ->
              _ = erlang:cancel_timer(TRef),
              deliver_verdict(ReplyTo, Tag, membership_verdict(Change, Acc)),
              Acc#s{validations = maps:remove(Tag, Acc#s.validations)}
      end, S, Ready).

%% The verdict for the single guaranteed-shape `peer_admitted` op (Slice A's gate ensures exactly one),
%% judged against `S#s.est` (the parent-height kb):
%% - assert: reject a pubkey already admitted (the one-fact-per-pubkey invariant that keeps the KB + the
%%   validator set in lockstep on retract); else re-prove the SAME `can_join` goal `admit_3` staged. A
%%   `can_join` that stages writes is rejected — it must be side-effect-free, or the overlay would ride
%%   its ops into the committed diff network-wide. NB the KB state is pinned to the parent height, but a
%%   `can_join` rule may also read REALITY through a read-only external predicate (`peer_ready`), and
%%   there honest validators MAY split (each judges from its own liveness observations). Intentional and
%%   fail-closed: a support shortfall Δ-skips the slot and the submitter retries — the admit commits only
%%   once quorum-many validators independently observed the candidate ready.
%% - retract: valid only if that exact `peer_admitted` clause is present — a fabricated-address retract
%%   matches nothing, so it can never eject a validator from the set while missing in the KB.
-spec membership_verdict(term(), #s{}) -> valid | {invalid, term()}.
membership_verdict(#transaction{diff = [{assert, {{peer_admitted, Pk, H, P, Pk}, _B}}]},
                   #s{ns = Ns, applied = Applied, est = Est}) ->
    case lists:member(Pk, quod_committee_predicates:admitted_pubkeys(Est)) of
        true  -> {invalid, already_admitted};
        false -> %% The re-proof runs INLINE in the engine, pinned to the parent height (`Applied`) and
                 %% carrying a VERDICT execution context (`m:quod_predicates`). That context disables
                 %% cross-ontology asks (a committee vote must never make network hops mid-verdict,
                 %% doc/inter-ontology.md §11) and read-time link following, and supplies the height the
                 %% `peer_ready` gate reads — all deterministically, without any process-dictionary state.
                 VerdictEst = quod_predicates:set_context(Est, quod_predicates:verdict_context(Ns, Applied)),
                 case run_proof_est({can_join, Ns, [H, P], Pk}, VerdictEst) of
                     {ok, _, [], _}    -> valid;
                     {ok, _, _Diff, _} -> {invalid, can_join_side_effects};
                     fail              -> {invalid, can_join};
                     {error, _}        -> {invalid, can_join}
                 end
    end;
membership_verdict(#transaction{diff = [{retract, {{peer_admitted, _Id, _H, _P, _Pk}, _B} = Clause}]},
                   #s{est = #est{db = #db{mod = M, ref = R}}}) ->
    {ClauseHead, ClauseBody} = Clause,
    case quod_diff:has_clause(M, R, ClauseHead, ClauseBody) of
        true  -> valid;
        false -> {invalid, no_such_member}
    end;
membership_verdict(_Change, _S) ->
    {invalid, malformed}.   %% Slice A's gate makes this unreachable in production; kept total for tests/robustness

%% Async delivery to the requesting statem (or a test pid) — a plain message so the statem consumes it
%% as an `info` event and a test just `receive`s the bare tuple.
deliver_verdict(ReplyTo, Tag, Verdict) -> ReplyTo ! {membership_verdict, Tag, Verdict}, ok.

%%%===================================================================
%%% kb construction
%%%===================================================================

-doc """
Build the genesis write-set from a `.pl` file — `terms_to_diff(read_terms(File))`.

Used at create only: the founder reads the root `.pl`, and `quod_simplex` prepends the
generated `consensus_incarnation/1` fact and founding committee's
`peer_admitted/4` facts, compiling them into one genesis transaction at slot 1.
A missing/unparseable file throws `{genesis_failed, _}`,
which `quod_simplex:init/1` turns into `{stop, _}` (fail-fast — a node with no root is
useless).
""".
-spec genesis_diff(file:filename()) -> [op()].
genesis_diff(File) -> terms_to_diff(read_terms(File)).

-doc """
Compile a list of Prolog terms (facts or rules) into a write-set of `op()`.

Turns each term into a write-set `op()` in the SAME compiled form the live write path
produces — so it commits and replays through the normal apply path. erlog's `assertz`
compiles the body (`well_form_body`, yielding `{Body, HasCut}`); we capture the result
with the `m:quod_erlog_db_local_prove` overlay, exactly as `run_proof/2` does for a live
write. Hand-building `{Head, true}` would store a malformed clause and crash on the first
prove — the body must be the compiled form, not raw `true`. Used to build the genesis
transaction (incarnation + committee facts + root content).
""".
-spec terms_to_diff([term()]) -> [op()].
terms_to_diff(Terms) ->
    Base = build_kb(),
    W0 = quod_erlog_db_local_prove:wrap_state(Base, #{read_set => false}),
    try
        WN = lists:foldl(
               fun(T, W) ->
                   case erlog_int:prove_goal({assertz, T}, W) of
                       {succeed, W1} -> W1;
                       Other         -> throw({genesis_failed, {assert, T, Other}})
                   end
               end, W0, Terms),
        quod_erlog_db_local_prove:get_local_changes((WN#est.db)#db.ref)
    after
        quod_erlog_db_local_prove:cleanup_read_set(W0),
        #est{db = #db{ref = Ref}} = Base,
        quod_erlog_db_mvcc:delete(Ref)
    end.

-doc "Parse a `.pl` file into a list of Prolog terms; a missing/unparseable file throws `{genesis_failed, _}`.".
-spec read_terms(file:filename()) -> [term()].
read_terms(File) ->
    Res = try erlog_io:read_file(File) catch C0:E0 -> {caught, C0, E0} end,
    case Res of
        {ok, Terms}     -> Terms;
        {error, Reason} -> throw({genesis_failed, {read_file, File, Reason}});
        {caught, C, E}  -> throw({genesis_failed, {parse, File, {C, E}}})
    end.

build_kb() ->
    %% erlog:new/2 loads bips + lists + dcg; #est{} is element 3 of #erlog{vs, est}.
    %% The MVCC database keeps the full KB once in an unnamed ETS table. Proof workers
    %% receive only its table/height handle; interpreted predicate versions give each
    %% worker a stable frozen view while commits continue.
    {ok, Erl} = erlog:new(quod_erlog_db_mvcc, null),
    Est0 = element(3, Erl),
    %% unknown predicate => fail (not error): a goal over an undefined predicate just
    %% has no solution, rather than crashing.
    {succeed, Est1} = erlog_int:prove_goal({set_prolog_flag, unknown, fail}, Est0),
    %% Register every static Erlang predicate BEFORE loading the shared interpreted
    %% clauses. A collision in common_predicates.pl then fails as an attempted
    %% modification of a static procedure instead of shadowing a governed boundary.
    Est2 = quod_predicates:load(Est1),
    Est3 = quod_ask:load(Est2),
    Est4 = quod_transaction_predicates:load(Est3),
    Est5 = quod_action_predicates:load(Est4),
    %% Publish the loaded common predicates as the height-0 base: every handle
    %% a proof wraps is then a PUBLISHED snapshot even before the first block,
    %% which read-set capture requires (tokens for the base read {present, 0}).
    #est{db = #db{ref = Ref0} = Db} = Est6 = load_common_predicates(Est5),
    Est6#est{db = Db#db{ref = quod_erlog_db_mvcc:publish_base(Ref0)}}.

load_common_predicates(#est{db = Db0} = Est) ->
    File = filename:join(code:priv_dir(quod),
                         "ontologies/common_predicates.pl"),
    Terms =
        try read_terms(File)
        catch
            throw:{genesis_failed, ReadReason} ->
                throw({common_predicates_failed, ReadReason})
        end,
    try
        Db1 = lists:foldl(fun erlog_int:assertz_clause/2, Db0, Terms),
        Est#est{db = Db1}
    catch
        Class:LoadReason ->
            throw({common_predicates_failed, {Class, LoadReason}})
    end.

tx_id(Self) -> <<(erlang:phash2(Self)):32, (erlang:unique_integer([positive])):64>>.
