-module(quod_prolog).
-moduledoc """
Per-namespace fact engine: owns the committed erlog knowledge base for one
ontology, serves `prove/2`, and applies committed blocks from `quod_simplex` in log
order. One `gen_server` per namespace.

- **Every proof runs in its own bounded WORKER process** — the engine never blocks
  on a proof (doc/inter-ontology.md §4.1). The worker gets a small shared-store snapshot
  handle, never the knowledge base. A wedged proof wedges only its worker, which is
  killed after its configured absolute lifetime; its private origin and selected-scope
  overlays die with their bounded workers.
- **Reads** run on a copy-on-write overlay (`m:quod_erlog_db_local_prove`) so the
  committed kb is never touched; the answer is bindings (stamped with the height the
  frozen view was taken at), returned to the caller.
- **Explorer cursors** retain that exact bounded proof worker between answers.
  `next` resumes its continuation, `accept` seals the displayed answer through
  the ordinary submission path, and `stop` discards the staged proof. They do
  not re-run a goal to manufacture another answer.
- **Writes** seal the complete participating scope set before submission. One
  participant uses that target ontology's ordinary `#transaction{}` consensus
  path. Two or more participants use the atomic
  Begin/Prepare/Decision/Finalize/Complete protocol; no participant publishes its
  hidden diff before the certified decision and ordered Finalize apply. The caller
  is parked until the ordinary apply or group Complete is published. If its local
  wait expires first, it receives the corresponding anchored
  `outcome_unknown` reference and resolves that reference instead of re-proving.
- **Lifecycle actions** accept only ground root `create_ontology/2` and
  `join_ontology/3` requests. One read-only anchored proof session validates the
  exact target-state declaration, authorizes before source reads, carries one
  opaque prepared descriptor through prerequisite selection, then re-authorizes,
  executes the typed request once, and verifies its desired state. Prolog
  backtracking never owns an external-operation descriptor.
- **`apply_entry/3`** is the deterministic ordered state machine driven by
  `quod_simplex`. Content transactions re-check their read set (OCC) before apply;
  DTX Prepare retains a hidden plan, Finalize(commit) publishes it once, and
  Complete records the terminal group result. A **committee-changing** content
  transaction (its diff asserts/retracts `peer_admitted`) applies unconditionally
  because it was re-validated against the exact parent before voting (see
  `request_membership_verdict/5`), keeping the KB and validator projection in
  lockstep.

Proves are gated until an initial **rebuild** completes (`ready`), so a freshly
(re)started engine never answers from a half-built kb. The kb is built with the
erlog flag `unknown = fail`. The runtime projection contract is specified in
`doc/agent-fipa-plan.md` §7.
""".
-behaviour(gen_server).
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").

-export([start_link/2, prove/2, prove_ro/2, prove_as/3, execute/2, execute_as/3,
         open_cursor/4, cancel_cursor/3,
         run_action_as/3,
         submit_plan/4, outcome/1,
         local_outcome/2, outcome_snapshot/2, dtx_group_state/2,
         project_pending_begin/2,
         dtx_group_resolved/2,
         run_action/2,
         applied/1, apply_entry/3, mark_ready/1, sync/1,
         attach_runtime/1, runtime_floor/2, runtime_detach/1,
         request_membership_verdict/5, request_dtx_verdict/5,
         stats/1, namespaces/0]).
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
         test_scope_command_route/2,
         test_sealed_submit_transition/0,
         test_target_scope_lifetime_ms/2,
         test_remote_timeout_correlation/3,
         test_scope_worker_failure/2,
         test_proof_down_reply/3, test_proof_down_reply/4,
         test_finalize_pinned_result/1,
         test_terminal_result/1,
         test_not_ready_plan_submission/1,
         test_submit_outcome/1,
         test_release_absent_group_waiter/3,
         test_resolve_validation/4,
         test_await_public_proof/5]).
%% Pure verdict and scope-correlation seams driven directly by EUnit.
-endif.

%% The membership-verdict park budget: a verdict parked past the slot's Δ complaint-skip is moot, so this
%% is a short FIXED budget (default 2000 ms — on the order of the consensus Δ_timeout, `?DELTA_MS` ~1 s in
%% quod_simplex), deliberately NOT the 30 s write TTL. Reaping a stale parked verdict delivers `abstain`.
-define(DEFAULTS, #{node_id => undefined, transaction_ttl_ms => 30000,
                    validation_ttl_ms => 2000, max_proof_workers => 64,
                    max_scope_workers => 64, proof_timeout_ms => 60000,
                    scope_timeout_ms => 60000,
                    scope_step_timeout_ms => 30000,
                    outcome_backend => disk}).
-define(ROOT_NS, <<"quod:root">>).

%% Busy/rebuilding replies are deliberately rate-limited: an authenticated peer can
%% still flood valid open frames, and rejecting them must not create unbounded work.
-define(MAX_SCOPE_REJECTS_PER_SECOND, 32).

-record(proof_worker, {pid         :: pid(),
                       kind        :: prove | prove_ro | action | cursor,
                       worker_mref :: reference(),
                       caller_mref :: reference(),
                       from        :: gen_server:from() |
                                      {async, pid(), reference()},
                       timer       :: reference(),
                       token       :: reference(),
                       checkpoint = none :: none | term(),
                       height = 0  :: non_neg_integer()}).

%% One engine-owned, pre-signing Begin transfer.  The origin worker waits on
%% `from`, but the engine keeps serving its mailbox while Simplex validates the
%% immutable intent.  There is only one origin-active group per ontology, so a
%% second hand-off is refused rather than queued.
-record(dtx_handoff, {
          intent_id  :: reference(),
          request_id :: term(),
          worker_ref :: reference(),
          worker_pid :: pid(),
          from       :: gen_server:from(),
          group_ref  :: term()
         }).

%% After activation the proof worker may close every scope.  Only this compact
%% public waiter remains; recovery and consensus are owned by Simplex.
-record(group_waiter, {
          from        :: gen_server:from() | {async, pid(), reference()},
          caller_mref :: reference(),
          timer       :: reference(),
          group_ref   :: term()
         }).

%% One engine-owned top-level run. The engine chooses the proof id, frozen
%% height, and absolute local deadline before spawning the worker; the worker
%% then owns exactly one root session and proof context for the whole run.
-record(pinned_origin, {
          engine      :: pid(),
          worker_ref  :: reference(),
          proof_id    :: <<_:256>>,
          scope_id    :: <<_:128>>,
          deadline_ms :: integer(),
          kind        :: prove | prove_ro | action | cursor,
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
                    opening_return | opening_session | active | sealed |
                    submitting | submitted | closing,
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
            signer = none :: quod_identity:signer() | none,
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
            outcomes :: quod_outcome:index(),
            requests  :: term(),                 %% gen_statem async-request collection, labelled by tx_id
            %% Consensus verdicts parked until the KB reaches the proposal's
            %% parent height (Slot-1).  Membership and DTX Prepare share this
            %% one height/correlation/timer mechanism; only their pure
            %% validator and reply tag differ.
            %% Tag => {Slot, {membership, Change} | {dtx, Control},
            %%         ReplyTo, TimerRef}
            validations = #{} :: map(),
            applies   = 0, rejects = 0, proves = 0, conflicts = 0,
            park_timeouts = 0 :: non_neg_integer(),     %% writes still unresolved at their caller deadline
            %% Ref => #proof_worker{}
            workers   = #{} :: map(),
            %% A sealed writer no longer reads its frozen proof snapshot while
            %% consensus resolves the submission. Keep its caller/monitor
            %% ownership here without charging a derivation slot or pinning
            %% MVCC history.
            waiting_workers = #{} :: map(),
            dtx_handoff = none :: none | #dtx_handoff{},
            group_waiters = #{} :: map(),
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

-doc """
Open one bounded, resumable top-level proof owned by `Owner`.

The returned call reference is private coordination between the Explorer cursor
owner and this engine.  Solutions are delivered one at a time without
re-proving; the cursor owner must explicitly request `next`, `accept`, or
`stop`.  The ordinary engine proof deadline remains the absolute cursor
lifetime.
""".
-spec open_cursor(binary(), term(), pid(), <<_:256>>) ->
          {ok, pid(), reference()} | {error, term()}.
open_cursor(TargetNs, Goal, Owner, <<_:256>> = CursorId)
  when is_binary(TargetNs), is_pid(Owner) ->
    case quod_predicates:action_transition(Goal) of
        true -> {error, non_backtrackable_action};
        false ->
            case quod_reg:where({quod_prolog, TargetNs}) of
                undefined -> {error, no_such_namespace};
                Engine ->
                    CallRef = make_ref(),
                    gen_server:cast(
                      Engine,
                      {public_cursor, Owner, CallRef, CursorId, Goal,
                       quod_trace:context()}),
                    {ok, Engine, CallRef}
            end
    end;
open_cursor(_TargetNs, _Goal, _Owner, _CursorId) ->
    {error, bad_request}.

-doc "Cancel an Explorer cursor by its exact engine/call ownership.".
-spec cancel_cursor(pid(), pid(), reference()) -> ok.
cancel_cursor(Engine, Owner, CallRef)
  when is_pid(Engine), is_pid(Owner), is_reference(CallRef) ->
    gen_server:cast(Engine, {cancel_public_cursor, Owner, CallRef}),
    ok.

-doc """
Prove `Goal` against namespace `TargetNs`.

A successful write proof commits before returning: the third element of the
result names where — the applied log index for a write into `TargetNs`
itself, or `{transaction, Ns, Anchor, TxId}` when the proof's sole material
scope was a foreign ontology and its sealed plan committed there.  A
multi-ontology commit returns a map containing its anchored group reference,
Complete height, and exact per-ontology Finalize slots.
""".
-spec prove(binary(), term()) ->
        {ok, [map()],
         log_index() | {transaction, binary(), binary(), binary()} | map()} |
        {error, term()} | fail | {fail, [term()]}.
prove(TargetNs, Goal) ->
    case quod_reg:where({quod_prolog, TargetNs}) of
        undefined -> {error, no_such_namespace};
        Pid -> public_proof(
                 Pid, TargetNs, prove, Goal, quod_trace:context())
    end.

-doc """
Execute one top-level Quod term.

Ordinary terms use the normal proof path. A lifecycle term uses the same
declared `action/3` proof and governed Erlang predicates as every other
action, then performs its one node-local effect only after that proof has
succeeded. This keeps the console and future typed clients on one execution
model instead of making ontology creation a separate product API.
""".
-spec execute(binary(), term()) ->
          {ok, [map()],
           log_index() | {transaction, binary(), binary(), binary()} | map()} |
          {error, term()} | fail | {fail, [term()]}.
execute(TargetNs, Goal) ->
    case lifecycle_action_term(Goal) of
        true -> run_action(TargetNs, Goal);
        false -> prove(TargetNs, Goal)
    end.

-doc """
Execute one server-constructed top-level term under an authenticated user.

This is the user-principal counterpart of `execute/2`. It deliberately accepts
only terms constructed by a typed ingress codec; it is not a way to give a
browser a general Prolog evaluator.
""".
-spec execute_as(binary(), term(), {user, <<_:256>>}) ->
          {ok, [map()],
           log_index() | {transaction, binary(), binary(), binary()} | map()} |
          {error, term()} | fail | {fail, [term()]}.
execute_as(TargetNs, Goal, {user, <<_:256>>} = Principal) ->
    case lifecycle_action_term(Goal) of
        true -> run_action_as(TargetNs, Goal, Principal);
        false -> prove_as(TargetNs, Goal, Principal)
    end;
execute_as(_TargetNs, _Goal, _Principal) ->
    {error, invalid_user_principal}.

%% These are the typed lifecycle action constructors registered by
%% `quod_ontology:validate_action/1`. They must enter the action executor even
%% when malformed, so callers receive its bounded validation failure rather
%% than silently proving an unrelated ordinary predicate.
lifecycle_action_term(Goal) -> quod_predicates:action_transition(Goal).

-doc "Read-only prove: like `prove/2` but a write goal is refused (`{error, read_only}`).".
-spec prove_ro(binary(), term()) ->
        {ok, [map()], log_index()} | {error, term()} | fail | {fail, [term()]}.
prove_ro(TargetNs, Goal) ->
    case quod_reg:where({quod_prolog, TargetNs}) of
        undefined -> {error, no_such_namespace};
        Pid -> public_proof(Pid, TargetNs, prove_ro, Goal, otel_ctx:new())
    end.

-doc """
Run a server-owned goal under one already-authenticated user principal.

This is an in-VM boundary for the typed client-command ingress; it is not an
HTTP endpoint and must never receive a browser-provided Prolog goal.
""".
-spec prove_as(binary(), term(), {user, <<_:256>>}) ->
          {ok, [map()], log_index() | {transaction, binary(), binary(), binary()} | map()} |
          {error, term()} | fail | {fail, [term()]}.
prove_as(TargetNs, Goal, {user, <<_:256>>} = Principal) ->
    case quod_reg:where({quod_prolog, TargetNs}) of
        undefined -> {error, no_such_namespace};
        Pid -> public_proof(
                 Pid, TargetNs, prove, Goal, quod_trace:context(), Principal)
    end;
prove_as(_TargetNs, _Goal, _Principal) ->
    {error, invalid_user_principal}.

public_proof(Engine, Ns, Kind, Goal, TraceCtx) ->
    public_proof(Engine, Ns, Kind, Goal, TraceCtx, undefined).

public_proof(Engine, Ns, Kind, Goal, TraceCtx, Principal) ->
    CallRef = make_ref(),
    MRef = monitor(process, Engine),
    gen_server:cast(
      Engine, {public_proof, self(), CallRef, Kind, Goal, TraceCtx, Principal}),
    try await_public_proof(Engine, MRef, CallRef, Ns, none)
    after demonitor(MRef, [flush])
    end.

await_public_proof(Engine, MRef, CallRef, Ns, Checkpoint) ->
    receive
        {quod_proof_checkpoint, Engine, CallRef, Ref} ->
            await_public_proof(Engine, MRef, CallRef, Ns, Ref);
        {quod_proof_reply, Engine, CallRef, Reply} ->
            Reply;
        {'DOWN', MRef, process, Engine, _Reason} ->
            case Checkpoint of
                none -> {error, {ontology_unavailable, Ns}};
                Ref -> {error, {outcome_unknown, Ref}}
            end
    end.

-ifdef(TEST).
test_await_public_proof(Engine, MRef, CallRef, Ns, Checkpoint) ->
    await_public_proof(Engine, MRef, CallRef, Ns, Checkpoint).
-endif.

-doc """
Submit one sealed local plan (`m:quod_dtx`) to its target validator engine.

The plan must have been sealed by THIS node — sealing is target-side, so
whichever engine legitimately receives a plan received one its own node
witnessed. The engine validates that invariant plus the plan's target
identity, builds the signed ordinary transaction envelope from the plan's
exact diff, read tokens, origin, proof id, and digest, and parks the caller
through the existing consensus/apply path. Both an ordinary local write and a
sole-foreign material scope go through this one primitive.
""".
-spec submit_plan(binary(), quod_dtx:plan(), term(), map()) ->
        {ok, [map()], log_index(), binary()} | {error, term()}.
submit_plan(TargetNs, Plan, Goal, Bindings) when is_map(Bindings) ->
    case quod_transaction:encode_durable_submission(Goal, Bindings) of
        {ok, GoalBlob, ResultBlob} ->
            case quod_reg:where({quod_prolog, TargetNs}) of
                undefined -> {error, {ontology_unreachable, TargetNs}};
                Pid -> try gen_server:call(
                             Pid,
                             {submit_plan, Plan, GoalBlob, ResultBlob,
                              [Bindings], quod_trace:context()}, infinity)
                       catch exit:_ ->
                           {error, {outcome_unknown,
                                    quod_transaction:plan_outcome_ref(
                                      Plan, GoalBlob, ResultBlob)}}
                       end
            end;
        {error, _} = Error ->
            Error
    end.

-doc "Resolve one anchored transaction or distributed-group outcome without re-proving.".
-spec outcome({transaction, binary(), binary(), binary()} |
              {group, binary(), binary(), binary(), binary(), binary()}) ->
          {ok, map()} | {error, term()}.
outcome({transaction, Ns, <<_:256>>, <<_:256>>} = Ref)
  when is_binary(Ns), byte_size(Ns) > 0 ->
    public_outcome(Ns, Ref);
outcome({group, Ns, <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>} = Ref)
  when is_binary(Ns), byte_size(Ns) > 0 ->
    public_outcome(Ns, Ref);
outcome(_Ref) ->
    {error, bad_outcome_ref}.

public_outcome(Ns, Ref) ->
    case quod_reg:where({quod_prolog, Ns}) of
        undefined -> quod_simplex:dtx_outcome_lookup(Ref, 5000);
        _Pid -> local_outcome(Ns, Ref)
    end.

-doc "Read one co-hosted public outcome without performing remote fallback.".
-spec local_outcome(binary(), term()) -> {ok, map()} | {error, term()}.
local_outcome(Ns, Ref) when is_binary(Ns), byte_size(Ns) > 0 ->
    case quod_reg:where({quod_prolog, Ns}) of
        undefined ->
            {error, {ontology_unreachable, Ns}};
        Pid ->
            Reply =
                try gen_server:call(Pid, {outcome, Ref}, 5000)
                catch exit:_ -> {error, {outcome_unknown, Ref}}
                end,
            resolve_public_group_absence(Ns, Ref, Reply)
    end;
local_outcome(_Ns, _Ref) ->
    {error, bad_outcome_ref}.

resolve_public_group_absence(
  Ns,
  {group, Ns, <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>} = Ref,
  {error, {group_not_found, AppliedFloor}})
  when is_integer(AppliedFloor), AppliedFloor >= 0 ->
    case quod_simplex:dtx_group_barrier(Ns, Ref, AppliedFloor) of
        {ok, pending} ->
            {ok, #{status => pending, phase => pending_begin, ref => Ref}};
        {ok, not_found} ->
            {error, not_found};
        {ok, {rejected, coordinator_retired}} ->
            {ok, #{status => rejected, reason => coordinator_retired,
                   ref => Ref}};
        {error, _} = Error ->
            Error
    end;
resolve_public_group_absence(_Ns, _Ref, Reply) ->
    Reply.

outcome_not_found(
  {group, _Ns, <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>},
  AppliedFloor) ->
    {error, {group_not_found, AppliedFloor}};
outcome_not_found(
  {transaction, <<"quod:root">>, <<_:256>>, <<_:256>>} = Ref,
  _AppliedFloor) ->
    case quod_effect_journal:status_ref(Ref) of
        {ok, #{state := retired, result := Reason}} ->
            {ok, #{status => rejected, reason => Reason, ref => Ref}};
        {ok, #{state := operator_error, result := Reason}} ->
            {ok, #{status => rejected,
                   reason => {operator_error, Reason}, ref => Ref}};
        _ ->
            {error, not_found}
    end;
outcome_not_found(_Ref, _AppliedFloor) ->
    {error, not_found}.

-doc "Read one locally-applied outcome and its atomic publication floor.".
-spec outcome_snapshot(binary(), term()) ->
          {ok, #{applied_floor := non_neg_integer(),
                 outcome := not_found | map()}} |
          {error, term()}.
outcome_snapshot(Ns, Ref) when is_binary(Ns), byte_size(Ns) > 0 ->
    try gen_server:call(
          quod_reg:via({quod_prolog, Ns}), {outcome_snapshot, Ref}, 1000)
    catch exit:_ -> {error, {ontology_unavailable, Ns}}
    end;
outcome_snapshot(_Ns, _Ref) ->
    {error, bad_outcome_ref}.

-doc "Read exact bounded local DTX history, applied row, and publication floor.".
-spec dtx_group_state(binary(), <<_:256>>) ->
          {ok, map()} | {error, term()}.
dtx_group_state(Ns, <<_:256>> = GroupId) when is_binary(Ns) ->
    try gen_server:call(
          quod_reg:via({quod_prolog, Ns}),
          {dtx_group_state, GroupId}, 1000)
    catch exit:_ -> {error, {ontology_unavailable, Ns}}
    end;
dtx_group_state(_Ns, _GroupId) ->
    {error, invalid_group_id}.

-doc "Project the signing journal's exact pending Begin before the engine becomes ready.".
-spec project_pending_begin(binary(), none | map()) -> ok.
project_pending_begin(Ns, Pending) when is_binary(Ns) ->
    gen_server:cast(
      quod_reg:via({quod_prolog, Ns}), {project_pending_begin, Pending}).

-doc "Recheck a local group waiter after an authoritative Simplex resolution edge.".
-spec dtx_group_resolved(binary(), term()) -> ok.
dtx_group_resolved(Ns,
                    {group, Ns, <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>}
                      = GroupRef)
  when is_binary(Ns) ->
    gen_server:cast(
      quod_reg:via({quod_prolog, Ns}), {dtx_group_resolved, GroupRef});
dtx_group_resolved(_Ns, _GroupRef) ->
    ok.

-doc """
Authorize and commit one node-local ontology lifecycle action.

Only fully-ground `create_ontology/2` and `join_ontology/3` actions targeting
`quod:root` are accepted. A bounded worker validates the committed root
transition, authorizes the engine-owned node principal before preparing input,
selects the declaration's desired state or prerequisites read-only, and records
one typed effect in the ordinary root transaction path.  The effect journal
invokes the prepared helper only after ordered apply. A worker loss is
outcome-unknown because the transaction or namespace-manager operation may
already have been accepted; inspect the returned outcome reference before any
retry.
""".
-spec run_action(binary(), term()) ->
        {ok, [map()], log_index()} | {error, term()} | fail | {fail, [term()]}.
run_action(TargetNs, Action) ->
    case validate_action_request(TargetNs, Action) of
        {ok, Structural} ->
            case quod_reg:where({quod_prolog, TargetNs}) of
                undefined -> {error, no_such_namespace};
                Pid ->
                    public_action(
                      Pid, TargetNs, Action, Structural, node)
            end;
        {error, Reason} ->
            {error, Reason};
        {fail, Reason} ->
            {fail, [Reason]}
    end.

-doc "Run one server-constructed root lifecycle action under an authenticated user.".
-spec run_action_as(binary(), term(), {user, <<_:256>>}) ->
        {ok, [map()], log_index()} | {error, term()} | fail | {fail, [term()]}.
run_action_as(TargetNs, Action, {user, <<_:256>>} = Principal) ->
    case validate_action_request(TargetNs, Action) of
        {ok, Structural} ->
            case quod_reg:where({quod_prolog, TargetNs}) of
                undefined -> {error, no_such_namespace};
                Pid ->
                    public_action(
                      Pid, TargetNs, Action, Structural, Principal)
            end;
        {error, Reason} -> {error, Reason};
        {fail, Reason} -> {fail, [Reason]}
    end;
run_action_as(_TargetNs, _Action, _Principal) ->
    {error, invalid_user_principal}.

public_action(Engine, Ns, Action, Structural, Principal) ->
    CallRef = make_ref(),
    MRef = monitor(process, Engine),
    gen_server:cast(
      Engine,
      {public_action, self(), CallRef, Action, Structural, Principal}),
    try await_public_proof(Engine, MRef, CallRef, Ns, none)
    after demonitor(MRef, [flush])
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

valid_user_lifecycle_principal({user, <<_:256>>}) -> true;
valid_user_lifecycle_principal(_) -> false.

lifecycle_request_principal(node, Self) ->
    case lifecycle_principal(Self) of
        {ok, Principal} -> {ok, Principal};
        error -> {error, not_authorized}
    end;
lifecycle_request_principal(Principal, _Self) ->
    case valid_user_lifecycle_principal(Principal) of
        true -> {ok, Principal};
        false -> {error, invalid_user_principal}
    end.

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
-spec apply_entry(binary(), #entry{}, live | replay) -> ok.
apply_entry(Ns, #entry{} = Entry, Origin) ->
    gen_server:cast(quod_reg:via({quod_prolog, Ns}), {apply_entry, Entry, Origin}).

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
particular a burst of `apply_entry/3` casts — has been consumed. `quod_simplex`'s streamed
replay calls this every few hundred casts so a long rebuild can't flood the mailbox with
the whole log (backpressure); the applies themselves must stay casts (see `apply_entry/3`).
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
behind, the request parks until `apply_entry` reaches `Slot-1` (or a short fixed TTL — `validation_ttl_ms`,
on the order of Δ — reaps it to `abstain`); if the kb is already past the slot, the slot resolved without
us — `abstain`. Re-issuing the same `Tag` supersedes a still-parked request for it.
""".
-spec request_membership_verdict(binary(), term(), pos_integer(), pid(), term()) -> ok.
request_membership_verdict(Ns, Change, Slot, ReplyTo, Tag) ->
    gen_server:cast(quod_reg:via({quod_prolog, Ns}), {membership_verdict_req, Change, Slot, ReplyTo, Tag}).

-doc """
Look up one DTX control's exact group history at the proposal parent and, for
Prepare, also validate its plan against that parent KB.  The reply is
`{dtx_verdict, Tag, EnginePid, AppliedFloor,
  {valid, History} | {invalid, Reason} | abstain}`.
""".
-spec request_dtx_verdict(binary(), quod_dtx:control(), pos_integer(), pid(), term()) -> ok.
request_dtx_verdict(Ns, Control, Slot, ReplyTo, Tag)
  when is_binary(Ns), is_integer(Slot), Slot > 0, is_pid(ReplyTo) ->
    gen_server:cast(
      quod_reg:via({quod_prolog, Ns}),
      {dtx_verdict_req, Control, Slot, ReplyTo, Tag}).

stats(Ns) ->
    try gen_server:call(quod_reg:via({quod_prolog, Ns}), get_stats, 1000)
    catch exit:_ -> #{} end.

namespaces() -> gproc:select([{{{n, l, {quod_prolog, '$1'}}, '_', '_'}, [], ['$1']}]).

positive_limit(_Name, Value) when is_integer(Value), Value > 0 -> Value;
positive_limit(Name, Value) -> error({bad_config, {Name, Value}}).

%% One ontology engine owns one node witness. Tests may inject it in the
%% namespace config; production inherits the process-wide node identity.
configured_signer(Self, Cfg) ->
    Candidate =
        case maps:get(identity, Cfg, undefined) of
            undefined ->
                case {application:get_env(quod, node_pubkey),
                      application:get_env(quod, identity_key)} of
                    {{ok, <<_:256>> = Pubkey}, {ok, Key}} ->
                        #{pubkey => Pubkey, key => Key};
                    {undefined, undefined} ->
                        none;
                    {{ok, _Pubkey}, undefined} ->
                        error({bad_config, identity_key_missing});
                    {undefined, {ok, _MissingKey}} ->
                        error({bad_config, node_pubkey_missing});
                    _ ->
                        error({bad_config, invalid_identity})
                end;
            Identity ->
                Identity
        end,
    case Candidate of
        #{pubkey := <<_:256>> = Self, key := _SignerKey} = Signer -> Signer;
        none when not is_binary(Self); byte_size(Self) =/= 32 -> none;
        none -> error({bad_config, identity_key_missing});
        %% Never degrade a keyed node to unsigned operation: every plan it
        %% seals would later be refused by its own target engine, hiding the
        %% configuration fault behind data-dependent bad_plan failures.
        _ -> error({bad_config, identity_mismatch})
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init({Ns, Config}) ->
    Cfg  = maps:merge(?DEFAULTS, Config),
    Self = maps:get(node_id, Cfg),
    Signer = configured_signer(Self, Cfg),
    MaxProofWorkers = positive_limit(max_proof_workers, maps:get(max_proof_workers, Cfg)),
    MaxScopeWorkers = positive_limit(
                        max_scope_workers,
                        maps:get(max_scope_workers, Cfg)),
    case engine_anchor(Ns, Signer, Cfg) of
        {ok, Anchor} ->
            case quod_outcome:open(Ns, Anchor, Cfg) of
                {ok, Outcomes} ->
                    init_opened(
                      Ns, Cfg, Self, Signer, MaxProofWorkers,
                      MaxScopeWorkers, Outcomes);
                {error, Reason} ->
                    {stop, {outcome_index_unavailable, Reason}}
            end;
        {error, Reason} ->
            {stop, Reason}
    end.

engine_anchor(Ns, Signer, Cfg) ->
    case quod_simplex:genesis_hash(Ns) of
        <<_:256>> = Anchor -> {ok, Anchor};
        undefined -> engine_anchor_without_genesis(Signer, Cfg)
    end.

engine_anchor_without_genesis(none, #{outcome_backend := memory}) ->
    {ok, <<0:256>>};
engine_anchor_without_genesis(_Signer, _Cfg) ->
    {error, genesis_unavailable}.

init_opened(Ns, Cfg, Self, Signer, MaxProofWorkers, MaxScopeWorkers,
            Outcomes) ->
    S = #s{ns = Ns, self = Self, signer = Signer, est = build_kb(),
           outcomes = Outcomes,
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

%% A worker calls this exactly once after every participating plan is sealed
%% and before it can block on submission. From this point it must never read
%% its frozen Erlog state again. The move releases both the derivation budget
%% and the MVCC floor while retaining one bounded owner for the eventual reply.
handle_call({checkpoint_and_release_proof_snapshot, Ref, OutcomeRef},
            {Pid, _Tag},
            S = #s{workers = Workers, waiting_workers = Waiting,
                   max_proof_workers = Max}) ->
    case maps:get(Ref, Workers, undefined) of
        #proof_worker{pid = Pid, timer = KillRef} = Worker
          when map_size(Waiting) < Max ->
            %% The derivation budget ends here. Consensus may legitimately
            %% resolve after it; killing the owner now would turn an unknown
            %% outcome into a false definite failure and make retries unsafe.
            _ = erlang:cancel_timer(KillRef),
            checkpoint_client(Worker#proof_worker.from, OutcomeRef),
            {reply, ok,
             S#s{workers = maps:remove(Ref, Workers),
                 waiting_workers = Waiting#{
                   Ref => Worker#proof_worker{
                            checkpoint = OutcomeRef}}}};
        #proof_worker{pid = Pid} ->
            {reply, {error, busy}, S};
        _ ->
            {reply, {error, cancelled}, S}
    end;
handle_call(
  {checkpoint_bound_effect, Ref, Effect, Change, OutcomeRef},
  {Pid, _Tag},
  S = #s{workers = Workers, waiting_workers = Waiting,
         max_proof_workers = Max}) ->
    case maps:get(Ref, Workers, undefined) of
        #proof_worker{pid = Pid, timer = KillRef} = Worker
          when map_size(Waiting) < Max ->
            case quod_effect_journal:bind_transaction(
                   Effect, Change, OutcomeRef) of
                ok ->
                    _ = erlang:cancel_timer(KillRef),
                    checkpoint_client(Worker#proof_worker.from, OutcomeRef),
                    S1 = S#s{workers = maps:remove(Ref, Workers),
                              waiting_workers = Waiting#{
                                Ref => Worker#proof_worker{
                                         checkpoint = OutcomeRef}}},
                    EffectId = quod_effect:effect_id(Effect),
                    case quod_effect_journal:activate(EffectId) of
                        ok ->
                            {reply, ok, S1};
                        {error, _Reason} ->
                            %% The exact recovery reference is already in the
                            %% caller's mailbox. Activation may have reached
                            %% disk, so a weaker error must never invite retry.
                            {reply,
                             {error, {outcome_unknown, OutcomeRef}}, S1}
                    end;
                {error, Reason} ->
                    {reply, {error, Reason}, S}
            end;
        #proof_worker{pid = Pid} ->
            {reply, {error, busy}, S};
        _ ->
            {reply, {error, cancelled}, S}
    end;
%% One sealed local plan becomes one signed ordinary transaction. The caller
%% (a proof worker, local or serving a co-hosted foreign scope; or this
%% engine itself on behalf of an authenticated remote submission) parks until
%% the committed outcome resolves at apply.
handle_call(
  {submit_plan, Plan, GoalBlob, ResultBlob, ReplyBindings, TraceCtx}, From, S) ->
    accept_plan_submission(
      From, Plan, GoalBlob, ResultBlob, ReplyBindings, TraceCtx, S);
handle_call(
  {submit_bound_effect_plan, Plan, Change, GoalBlob, ResultBlob,
   ReplyBindings, TraceCtx}, From, S) ->
    accept_bound_effect_submission(
      From, Plan, Change, GoalBlob, ResultBlob,
      ReplyBindings, TraceCtx, S);
handle_call({outcome, _Ref}, _From, S = #s{ready = false, ns = Ns}) ->
    {reply, {error, {ontology_rebuilding, Ns}}, S};
handle_call({outcome, Ref}, _From, S = #s{outcomes = Outcomes0}) ->
    case quod_outcome:lookup_ref(Outcomes0, Ref) of
        {{ok, Stored}, Outcomes1} ->
            Reply = quod_outcome:public(Stored),
            {reply, Reply, S#s{outcomes = Outcomes1}};
        {wrong_anchor, Outcomes1} ->
            {reply, {error, wrong_genesis_anchor},
             S#s{outcomes = Outcomes1}};
        {not_found, Outcomes1} ->
            Reply = outcome_not_found(Ref, S#s.applied),
            {reply, Reply, S#s{outcomes = Outcomes1}};
        {{error, Reason}, Outcomes1} ->
            {stop, {outcome_index_unavailable, Reason},
             {error, outcome_index_unavailable},
             S#s{outcomes = Outcomes1}}
    end;
handle_call({outcome_snapshot, _Ref}, _From,
            S = #s{ready = false, ns = Ns}) ->
    {reply, {error, {ontology_rebuilding, Ns}}, S};
handle_call({outcome_snapshot, Ref}, _From,
            S = #s{outcomes = Outcomes0}) ->
    case quod_outcome:lookup_ref(Outcomes0, Ref) of
        {{ok, Stored}, Outcomes1} ->
            Reply = case quod_outcome:public(Stored) of
                        {ok, Public} ->
                            {ok, #{applied_floor =>
                                       quod_outcome:applied_floor(Outcomes1),
                                   outcome => Public}};
                        {error, _} = Error -> Error
                    end,
            {reply, Reply, S#s{outcomes = Outcomes1}};
        {wrong_anchor, Outcomes1} ->
            {reply, {error, wrong_genesis_anchor},
             S#s{outcomes = Outcomes1}};
        {not_found, Outcomes1} ->
            {reply,
             {ok, #{applied_floor =>
                         quod_outcome:applied_floor(Outcomes1),
                     outcome => not_found}},
             S#s{outcomes = Outcomes1}};
        {{error, Reason}, Outcomes1} ->
            {stop, {outcome_index_unavailable, Reason},
             {error, outcome_index_unavailable},
             S#s{outcomes = Outcomes1}}
    end;
handle_call({dtx_group_state, _GroupId}, _From,
            S = #s{ready = false, ns = Ns}) ->
    {reply, {error, {ontology_rebuilding, Ns}}, S};
handle_call({dtx_group_state, GroupId}, _From,
            S = #s{outcomes = Outcomes0}) ->
    {Reply, Outcomes1} = local_dtx_group_state(GroupId, Outcomes0),
    {reply, Reply, S#s{outcomes = Outcomes1}};
%% The worker has already sealed every participant and built one immutable
%% semantic Begin.  Registration is asynchronous to Simplex; this engine owns
%% the sole in-flight correlation and does not block its mailbox.
handle_call({register_dtx_begin, Ref, Begin, GroupRef}, From = {Pid, _Tag},
            S) ->
    register_dtx_handoff(Ref, Pid, From, Begin, GroupRef, S);
handle_call(get_stats, _From, S) ->
    #est{db = #db{ref = StoreRef}} = S#s.est,
    {reply, #{applied   => S#s.applied,  applies => S#s.applies,
              rejects   => S#s.rejects,  proves  => S#s.proves,
              conflicts => S#s.conflicts,
              parked    => map_size(S#s.parked),        %% in-flight writes awaiting commit (liveness gauge)
              park_timeouts => S#s.park_timeouts,       %% final outcome unknown when caller deadline elapsed
              proof_workers => map_size(S#s.workers),
              proof_waiters => map_size(S#s.waiting_workers),
              dtx_handoff => S#s.dtx_handoff =/= none,
              group_waiters => map_size(S#s.group_waiters),
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

%% Public proofs use an explicit call reference and monitor the exact engine.
%% This makes an engine exit distinguishable before/after a durable checkpoint
%% without blocking the engine in an opaque gen_server call.
handle_cast({public_cursor, Owner, CallRef, CursorId, _Goal, _TraceCtx}, S)
  when is_pid(Owner), is_reference(CallRef),
       (not is_binary(CursorId) orelse byte_size(CursorId) =/= 32) ->
    reply_client({async, Owner, CallRef}, {error, bad_request}),
    {noreply, S};
handle_cast({public_cursor, Owner, CallRef, <<_:256>>, _Goal, _TraceCtx},
            S = #s{ready = false})
  when is_pid(Owner), is_reference(CallRef) ->
    reply_client({async, Owner, CallRef}, {error, rebuilding}),
    {noreply, S};
handle_cast({public_cursor, Owner, CallRef, <<_:256>>, _Goal, _TraceCtx},
            S = #s{workers = Workers, max_proof_workers = Max})
  when is_pid(Owner), is_reference(CallRef), map_size(Workers) >= Max ->
    reply_client({async, Owner, CallRef}, {error, busy}),
    {noreply, S};
handle_cast({public_cursor, Owner, CallRef, <<_:256>> = CursorId, Goal,
             TraceCtx}, S)
  when is_pid(Owner), is_reference(CallRef) ->
    {noreply,
     spawn_proof(
       cursor, {Owner, CallRef, CursorId, Goal},
       {async, Owner, CallRef}, TraceCtx, undefined, S)};
handle_cast({cancel_public_cursor, Owner, CallRef}, S = #s{workers = Workers})
  when is_pid(Owner), is_reference(CallRef) ->
    case find_cursor_worker(Owner, CallRef, Workers) of
        {ok, Pid} -> kill_worker(Pid);
        error -> ok
    end,
    {noreply, S};
handle_cast({public_proof, Caller, CallRef, Kind, _Goal, _TraceCtx, _Principal},
            S = #s{ready = false})
  when is_pid(Caller), is_reference(CallRef),
       (Kind =:= prove orelse Kind =:= prove_ro) ->
    reply_client({async, Caller, CallRef}, {error, rebuilding}),
    {noreply, S};
handle_cast({public_proof, Caller, CallRef, Kind, _Goal, _TraceCtx, _Principal},
            S = #s{workers = Workers, max_proof_workers = Max})
  when is_pid(Caller), is_reference(CallRef),
       (Kind =:= prove orelse Kind =:= prove_ro),
       map_size(Workers) >= Max ->
    reply_client({async, Caller, CallRef}, {error, busy}),
    {noreply, S};
handle_cast({public_proof, Caller, CallRef, Kind, Goal, TraceCtx, Principal}, S)
  when is_pid(Caller), is_reference(CallRef),
       (Kind =:= prove orelse Kind =:= prove_ro) ->
    case valid_public_proof_principal(Principal) of
        true ->
            {noreply,
             spawn_proof(
               Kind, Goal, {async, Caller, CallRef}, TraceCtx, Principal, S)};
        false ->
            reply_client({async, Caller, CallRef}, {error, invalid_user_principal}),
            {noreply, S}
    end;
%% Lifecycle actions use the same explicit monitor/checkpoint protocol as
%% public proofs.  That is what preserves the exact transaction reference if
%% the root engine restarts after accepting the effect.  `node` is only a
%% request marker: the actual key is derived from this engine's signer.
handle_cast({public_action, Caller, CallRef, _Action, _Structural, _Principal},
            S = #s{ready = false})
  when is_pid(Caller), is_reference(CallRef) ->
    reply_client({async, Caller, CallRef}, {error, rebuilding}),
    {noreply, S};
handle_cast({public_action, Caller, CallRef, _Action, _Structural, _Principal},
            S = #s{workers = Workers, max_proof_workers = Max})
  when is_pid(Caller), is_reference(CallRef), map_size(Workers) >= Max ->
    reply_client({async, Caller, CallRef}, {error, busy}),
    {noreply, S};
handle_cast({public_action, Caller, CallRef, Action, Structural, Requested},
            S = #s{self = Self})
  when is_pid(Caller), is_reference(CallRef) ->
    From = {async, Caller, CallRef},
    case lifecycle_request_principal(Requested, Self) of
        {ok, Principal} ->
            {noreply,
             spawn_proof(action, {Action, Structural}, From,
                         otel_ctx:new(), Principal, S)};
        {error, invalid_user_principal} ->
            reply_client(From, {error, invalid_user_principal}),
            {noreply, S};
        {error, not_authorized} ->
            reply_client(
              From,
              {fail,
               [quod_ontology_predicates:failure_reason(
                  Action, not_authorized)]}),
            {noreply, S}
    end;
handle_cast({project_pending_begin, Pending}, S = #s{outcomes = Outcomes0}) ->
    case quod_outcome:project_pending_begin(Outcomes0, Pending) of
        {ok, Outcomes1} ->
            case quod_outcome:flush(Outcomes1) of
                {ok, Outcomes2} -> {noreply, S#s{outcomes = Outcomes2}};
                {error, Reason} ->
                    {stop, {outcome_index_unavailable, Reason}, S}
            end;
        {error, Reason} ->
            {stop, {outcome_index_unavailable, Reason}, S}
    end;
handle_cast({dtx_group_resolved, GroupRef}, S) ->
    {noreply, release_group_waiter(GroupRef, S)};
handle_cast({apply_entry, #entry{} = Entry, Origin}, S0) ->
    S1 = apply_committed(Entry, Origin, S0),
    %% Drive the replay lifecycle from whether the apply ACTUALLY advanced the committed height, not
    %% from the raw origin: an already-applied no-op (`Index =< applied`) or a forward gap
    %% (`Index > applied+1`, which bails to rebuild) must never emit a false boundary.
    {noreply, note_origin(Origin, S1#s.applied > S0#s.applied, S0#s.applied, S1)};
%% Workers report through the engine so exactly one process owns reply and lifecycle state.
handle_cast({proof_result, Ref, Result}, S) ->
    {noreply, finish_proof(Ref, Result, S)};
%% mark_ready closes any replay interval before serving proves or resuming steady-state handling.
%% Simplex emits it after boot, member recovery, and observer anti-entropy; the first later live
%% apply can also close a replay interval, handled in note_origin/4.
handle_cast(mark_ready, S = #s{runtime_mode = {replaying, Id}, ns = Ns, applied = H}) ->
    publish_runtime(Ns, {replay_ready, Id, H}),
    acknowledge_ready(S#s{ready = true, runtime_mode = live});
%% Quiet-boot ready edge (agent-fipa-plan §7 as-built): a fresh/empty-log boot never opens a
%% replay run, so without this clause the FIRST ready transition would be unobservable and a
%% waiting runtime would hang. Guarded on the actual false→true edge — rebuild handshakes
%% re-cast mark_ready, and an unguarded `boot` edge (a constant, not a RecoveryId) would cost
%% the runtime a spurious full reconciliation each time.
handle_cast(mark_ready, S = #s{ready = false, ns = Ns, applied = H}) ->
    publish_runtime(Ns, {replay_ready, boot, H}),
    acknowledge_ready(S#s{ready = true});
handle_cast(mark_ready, S) -> acknowledge_ready(S);
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
    {noreply,
     request_validation(
       {membership, Change}, Slot, ReplyTo, Tag, S)};
handle_cast({dtx_verdict_req, Control, Slot, ReplyTo, Tag}, S) ->
    {noreply,
     request_validation(
       {dtx, Control}, Slot, ReplyTo, Tag, S)};
handle_cast(_Msg, S)       -> {noreply, S}.

%% Emit readiness from the handled edge, not from the caller that queued it.
%% Simplex also pins this process and height before opening its protected gate.
acknowledge_ready(S = #s{ns = Ns, applied = Height}) ->
    ok = quod_simplex:prolog_ready(Ns, self(), Height),
    {noreply, S}.

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
handle_info({proof_kill, Ref, Token}, S) ->
    %% Released workers are only waiting for consensus and no longer consume
    %% a derivation slot. A queued pre-release timer is therefore inert.
    case maps:find(Ref, S#s.workers) of
        {ok, #proof_worker{pid = Pid, token = Token}} -> kill_worker(Pid);
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
%% this ontology. The fixed envelope is decoded once here; submit payload blobs
%% remain opaque until exact binding, sequence, readiness and quota checks pass.
handle_info({quod_message, {{PeerKey, Endpoint}, RequestLink}, Channel, Payload},
            S = #s{ns = Ns}) ->
    case Channel =:= quod_scope_wire:request_channel(Ns) of
        true ->
            case handle_scope_frame(
                   PeerKey, Endpoint, RequestLink, Payload, S) of
                {stop, Reason, S1} -> {stop, Reason, S1};
                S1 -> {noreply, S1}
            end;
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
%% A parked remote submission resolved (apply, reject, or TTL): emit its
%% bounded outcome on the owning scope's return path.
handle_info({remote_submit_reply,
             {remote_submit, _Binding, _RequestId, _CommandSeq} = From,
             Reply}, S) ->
    {noreply, finish_remote_submit(From, Reply, S)};
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
handle_info({park_timeout, Tx}, S = #s{ns = Ns, parked = P}) ->
    case maps:take(Tx, P) of
        {{From, _B, _H, _TRef, ReqId, SpanCtx, _T0}, P1} ->
            Ref = {transaction, Ns, target_anchor(Ns), Tx},
            Outcome = {error, {outcome_unknown, Ref}},
            quod_trace:finish_span(SpanCtx, Outcome),
            reply_parked(From, Outcome),
            {noreply, S#s{parked = P1,
                          requests = abandon_request(ReqId, S#s.requests),
                          park_timeouts = S#s.park_timeouts + 1}};
        error -> {noreply, S}
    end;
handle_info({group_wait_timeout, GroupId}, S = #s{group_waiters = Waiters}) ->
    case maps:take(GroupId, Waiters) of
        {#group_waiter{from = From, caller_mref = CallerMRef,
                       group_ref = GroupRef}, Waiters1} ->
            demonitor(CallerMRef, [flush]),
            reply_client(From, {error, {outcome_unknown, GroupRef}}),
            {noreply,
             S#s{group_waiters = Waiters1,
                 park_timeouts = S#s.park_timeouts + 1}};
        error ->
            {noreply, S}
    end;
%% A parked consensus verdict whose parent height never arrived in time (the KB
%% is too far behind, or the slot was skipped before we caught up): reap it and
%% deliver `abstain` so the voter stops waiting.
handle_info({validation_timeout, Tag}, S = #s{validations = V}) ->
    case maps:take(Tag, V) of
        {{_Slot, Request, ReplyTo, _TRef}, V1} ->
            deliver_validation(Request, ReplyTo, Tag, abstain, S),
            {noreply, S#s{validations = V1}};
        error -> {noreply, S}
    end;
%% `send_request/2` gives us a non-blocking gen_statem call without a helper process per
%% transaction. Responses are matched through the opaque request-id collection and labelled
%% with their tx id. A successful append still resolves through ordered `apply_entry`; only a
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
    case local_node_principal(S) of
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
                                       signer => S#s.signer,
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

local_node_principal(#s{self = <<_:256>> = Principal}) -> {ok, Principal};
local_node_principal(#s{}) -> error.

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
    case quod_token_bucket:charge(
           Key, Now, ?QUOD_SCOPE_OPEN_RATE_PER_SECOND,
           ?QUOD_SCOPE_OPEN_RATE_BURST, ?QUOD_TOKEN_BUCKET_MAX_BUCKETS,
           ?QUOD_TOKEN_BUCKET_IDLE_MS, Rates0) of
        {ok, Rates} -> {ok, S#s{scope_open_rates = Rates}};
        {error, Rates} -> {error, S#s{scope_open_rates = Rates}}
    end.

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
        {ok, #remote_scope{state = State} = Scope} ->
            execute_routed_scope_command(
              scope_command_route(State, Operation), Operation,
              RequestId, CommandSeq, Binding, Scope, S);
        _ ->
            poison_remote_scope(
              Binding, RequestId, CommandSeq,
              {protocol_error, unexpected_scope_command}, S)
    end.

execute_routed_scope_command(
  active, Operation, RequestId, CommandSeq, Binding, Scope, S) ->
    execute_active_scope_command(
      Operation, RequestId, CommandSeq, Binding, Scope, S);
execute_routed_scope_command(
  sealed, Operation, RequestId, CommandSeq, Binding, Scope, S) ->
    execute_sealed_scope_command(
      Operation, RequestId, CommandSeq, Binding, Scope, S);
execute_routed_scope_command(
  error, _Operation, RequestId, CommandSeq, Binding, _Scope, S) ->
    %% Opening and sealed scopes have deliberately disjoint command sets.
    poison_remote_scope(
      Binding, RequestId, CommandSeq,
      {protocol_error, unexpected_scope_command}, S).

scope_command_route(active, {scope_attest, _ManifestBlob}) -> error;
scope_command_route(active, {submit_plan, _, _, _, _}) -> error;
scope_command_route(active, _Operation) -> active;
scope_command_route(sealed, scope_close) -> sealed;
scope_command_route(sealed, {scope_attest, _ManifestBlob}) -> sealed;
scope_command_route(sealed, {submit_plan, _, _, _, _}) -> sealed;
scope_command_route(submitting, scope_close) -> sealed;
scope_command_route(submitted, scope_close) -> sealed;
scope_command_route(_State, _Operation) -> error.

execute_sealed_scope_command(
  scope_close, RequestId, CommandSeq, Binding, _Scope, S) ->
    close_remote_scope(Binding, RequestId, CommandSeq, S);
execute_sealed_scope_command(
  {scope_attest, ManifestBlob}, RequestId, CommandSeq, Binding,
  #remote_scope{
     handle = {quod_scope_session, Pid, _SessionScopeId,
               SessionProofId, SessionRef, _Ns, _Anchor},
     pending = Pending}, S) ->
    case map_size(Pending) < ?QUOD_MAX_ROUTER_PENDING_PER_SCOPE of
        false ->
            poison_remote_scope(
              Binding, RequestId, CommandSeq,
              {proof_limit_exceeded, target_namespace(Binding)}, S);
        true ->
            case quod_scope_wire:decode_payload(manifest, ManifestBlob) of
                {ok, Manifest} ->
                    InternalRef = make_ref(),
                    Pid ! {scope_attest, self(), SessionProofId, SessionRef,
                           InternalRef, Manifest},
                    add_remote_pending(
                      Binding, InternalRef,
                      {scope_attest, RequestId, CommandSeq}, S);
                {error, Reason} ->
                    poison_remote_scope(
                      Binding, RequestId, CommandSeq, Reason, S)
            end
    end;
execute_sealed_scope_command(
  {submit_plan, _, _, _, _} = Operation,
  RequestId, CommandSeq, Binding, _Scope, S) ->
    %% The existing one-participant path hands its already-sealed plan to the
    %% target consensus engine exactly once. Move out of `sealed` before the
    %% asynchronous hand-off so a duplicate cannot start a second submission.
    S1 = update_remote_scope(
           Binding,
           fun(Scope) -> Scope#remote_scope{state = submitting} end, S),
    execute_remote_plan_submission(
      Operation, RequestId, CommandSeq, Binding, S1).

execute_active_scope_command(
  scope_close, RequestId, CommandSeq, Binding, _Scope, S) ->
    %% Closing is cancellation, not another proof step.  It must not queue a
    %% state probe behind a currently-running derivation: that would make an
    %% abandoned non-terminating goal keep its worker and MVCC pin until the
    %% lifetime timer.  The last published generation is sufficient for the
    %% terminal acknowledgement; then the common drop path stops the worker
    %% and retains ownership until its monitored DOWN releases the pin.
    close_remote_scope(Binding, RequestId, CommandSeq, S);
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
            case decode_target_scope_goal(GoalBlob) of
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
execute_active_scope_command(
  {submit_plan, _, _, _, _}, RequestId, CommandSeq, Binding, _Scope, S) ->
    poison_remote_scope(
      Binding, RequestId, CommandSeq,
      {protocol_error, unexpected_scope_command}, S);
execute_active_scope_command(
  scope_seal, RequestId, CommandSeq,
  Binding = {scope_binding, _OriginKey, _TargetKey, _ProofId, _ScopeId,
             OriginIdentity, _TargetIdentity, _Mode},
  #remote_scope{
     handle = {quod_scope_session, Pid, _SessionScopeId,
               SessionProofId, SessionRef, _Ns, _Anchor},
     pending = Pending}, S) ->
    case map_size(Pending) < ?QUOD_MAX_ROUTER_PENDING_PER_SCOPE of
        false ->
            poison_remote_scope(
              Binding, RequestId, CommandSeq,
              {proof_limit_exceeded, target_namespace(Binding)}, S);
        true ->
            InternalRef = make_ref(),
            Pid ! {scope_seal, self(), SessionProofId, SessionRef,
                   InternalRef, OriginIdentity},
            add_remote_pending(
              Binding, InternalRef, {scope_seal, RequestId, CommandSeq}, S)
    end;
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

close_remote_scope(Binding, RequestId, CommandSeq, S) ->
    S1 = emit_scope_event(
           Binding, RequestId, CommandSeq, scope_closed, S),
    drop_remote_scope(Binding, S1).

execute_remote_plan_submission(
  {submit_plan, PlanBlob, GoalBlob, ResultBlob, TraceCarrier},
  RequestId, CommandSeq,
  Binding = {scope_binding, _OriginKey, _TargetKey, ProofId, _ScopeId,
             OriginIdentity, _TargetIdentity, Mode},
  S) ->
    From = {remote_submit, Binding, RequestId, CommandSeq},
    case Mode =:= read_write andalso decode_submit_plan(PlanBlob) of
        {ok, Plan} ->
            %% The wire submission must be the authenticated scope's own plan:
            %% same proof, same origin. A plan borrowed from another proof or
            %% origin is refused before any consensus interaction.
            case quod_dtx:proof_id(Plan) =:= ProofId andalso
                 quod_dtx:origin(Plan) =:= OriginIdentity of
                true ->
                    case accept_plan_submission(
                           From, Plan, GoalBlob, ResultBlob, [],
                           quod_trace:extract(TraceCarrier), S) of
                        {noreply, S1} -> S1;
                        {reply, Reply, S1} ->
                            finish_remote_submit(From, Reply, S1);
                        {stop, Reason, Reply, S1} ->
                            %% Preserve the remote caller's definite/unknown
                            %% result, then fail-stop this ontology before it
                            %% can accept another command with a broken index.
                            {stop, Reason,
                             finish_remote_submit(From, Reply, S1)}
                    end;
                false ->
                    finish_remote_submit(From, {error, bad_plan}, S)
            end;
        false ->
            finish_remote_submit(From, {error, bad_plan}, S);
        {error, _Reason} ->
            finish_remote_submit(From, {error, bad_plan}, S)
    end.

%% Scope-goal symbols remain opaque through intermediate origin relays. The
%% target owns execution and makes the single bounded, authenticated
%% atom-allocation decision before its scope worker receives the goal.
decode_target_scope_goal(GoalBlob) ->
    case quod_scope_wire:decode_payload(goal, GoalBlob) of
        {ok, Goal0} ->
            case quod_wire_term:materialize_goal_symbols(Goal0) of
                {ok, Goal} -> {ok, Goal};
                {error, _} -> {error, {protocol_error, bad_payload}}
            end;
        {error, _} = Error -> Error
    end.

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
                               signer => S#s.signer,
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
  {scope_seal, RequestId, CommandSeq},
  {sealed, {ok, Plan}}, S) ->
    case quod_scope_wire:encode_payload(plan, Plan) of
        {ok, Blob} ->
            S1 = update_remote_scope(
                   Binding,
                   fun(Scope) -> Scope#remote_scope{state = sealed} end, S),
            emit_scope_event(
              Binding, RequestId, CommandSeq, {plan_sealed, Blob}, S1);
        {error, Reason} ->
            poison_remote_scope(Binding, RequestId, CommandSeq, Reason, S)
    end;
handle_bound_scope_reply(
  Binding, _Scope,
  {scope_seal, RequestId, CommandSeq},
  {sealed, not_material}, S) ->
    S1 = update_remote_scope(
           Binding,
           fun(Scope) -> Scope#remote_scope{state = sealed} end, S),
    emit_scope_event(Binding, RequestId, CommandSeq, plan_not_material, S1);
handle_bound_scope_reply(
  Binding, _Scope,
  {scope_seal, RequestId, CommandSeq},
  {sealed, {error, Reason}}, S) ->
    %% A refused seal fails the origin's finalize; the scope is finished
    %% either way, so the poison-and-drop path is the honest terminal state.
    poison_remote_scope(Binding, RequestId, CommandSeq, Reason, S);
handle_bound_scope_reply(
  Binding, _Scope,
  {scope_attest, RequestId, CommandSeq},
  {attested, {ok, Attestation}}, S) ->
    case quod_scope_wire:encode_payload(attestation, Attestation) of
        {ok, Blob} ->
            emit_scope_event(
              Binding, RequestId, CommandSeq, {plan_attested, Blob}, S);
        {error, Reason} ->
            poison_remote_scope(Binding, RequestId, CommandSeq, Reason, S)
    end;
handle_bound_scope_reply(
  Binding, _Scope,
  {scope_attest, RequestId, CommandSeq},
  {attested, {error, Reason}}, S) ->
    poison_remote_scope(Binding, RequestId, CommandSeq, Reason, S);
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

test_scope_command_route(State, Operation) ->
    scope_command_route(State, Operation).

test_sealed_submit_transition() ->
    Binding =
        {scope_binding, <<1:256>>, <<2:256>>, <<3:256>>, <<4:128>>,
         {<<"quod:origin">>, <<5:256>>},
         {<<"quod:target">>, <<6:256>>}, read_write},
    Operation = {submit_plan, <<"not-a-plan">>, <<>>, <<>>, []},
    Scope = #remote_scope{binding = Binding, state = sealed},
    S0 = #s{remote_scopes = #{Binding => Scope}},
    S1 = execute_sealed_scope_command(
           Operation, <<7:128>>, 2, Binding, Scope, S0),
    #remote_scope{state = State} = maps:get(Binding, S1#s.remote_scopes),
    {State, scope_command_route(State, Operation)}.

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

test_proof_down_reply(Kind, Reason, Ns, Checkpoint) ->
    proof_down_reply(Kind, Reason, Ns, Checkpoint).
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

handle_response_info(Info, S) ->
    case handle_dtx_handoff_response(Info, S) of
        no_reply -> handle_append_response_info(Info, S);
        Reply -> Reply
    end.

handle_append_response_info(Info, S = #s{requests = Requests}) ->
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

register_dtx_handoff(
  Ref, Pid, From, Begin, GroupRef,
  S = #s{ns = Ns, workers = Workers, dtx_handoff = none}) ->
    Checks =
        {maps:get(Ref, Workers, undefined),
         quod_dtx:begin_group_ref(Begin)},
    case Checks of
        {#proof_worker{pid = Pid}, {ok, GroupRef}} ->
            IntentId = make_ref(),
            case quod_simplex:register_dtx_begin(
                   Ns, self(), IntentId, Begin, GroupRef) of
                {ok, RequestId} ->
                    Handoff = #dtx_handoff{
                                 intent_id = IntentId,
                                 request_id = RequestId,
                                 worker_ref = Ref,
                                 worker_pid = Pid,
                                 from = From,
                                 group_ref = GroupRef},
                    {noreply, S#s{dtx_handoff = Handoff}};
                {error, _} = Error ->
                    {reply, Error, S}
            end;
        {#proof_worker{pid = Pid}, error} ->
            {reply, {error, invalid_begin}, S};
        _ ->
            {reply, {error, cancelled}, S}
    end;
register_dtx_handoff(_Ref, _Pid, _From, _Begin, _GroupRef, S) ->
    {reply, {error, busy}, S}.

handle_dtx_handoff_response(_Info, #s{dtx_handoff = none}) ->
    no_reply;
handle_dtx_handoff_response(
  Info,
  S = #s{dtx_handoff =
           #dtx_handoff{request_id = RequestId} = Handoff}) ->
    case gen_statem:check_response(Info, RequestId) of
        {reply, {accepted, IntentId}} ->
            accepted_dtx_handoff(IntentId, Handoff, S);
        {reply, {error, Reason}} ->
            rejected_dtx_handoff({error, Reason}, Handoff, S);
        {reply, _Other} ->
            rejected_dtx_handoff(
              {error, {protocol_error, dtx_handoff}}, Handoff, S);
        {error, _Reason} ->
            rejected_dtx_handoff(
              {error, {ontology_unavailable, S#s.ns}}, Handoff, S);
        no_reply ->
            no_reply
    end.

accepted_dtx_handoff(
  IntentId,
  #dtx_handoff{intent_id = IntentId, worker_ref = Ref,
               worker_pid = Pid, from = From,
               group_ref = GroupRef},
  S = #s{ns = Ns, workers = Workers, waiting_workers = Waiting,
         group_waiters = GroupWaiters, max_proof_workers = Max}) ->
    case maps:get(Ref, Workers, undefined) of
        #proof_worker{pid = Pid, timer = KillRef} = Worker
          when map_size(Waiting) < Max,
               map_size(GroupWaiters) < Max ->
            _ = erlang:cancel_timer(KillRef),
            Worker1 = Worker#proof_worker{checkpoint = GroupRef},
            S1 = S#s{
                   workers = maps:remove(Ref, Workers),
                   waiting_workers = Waiting#{Ref => Worker1},
                   dtx_handoff = none},
            %% Register was acknowledged.  Checkpoint and activation are sent
            %% by this exact engine in that order before the worker may close
            %% the participant scopes.
            checkpoint_client(Worker#proof_worker.from, GroupRef),
            ok = quod_simplex:activate_dtx_begin(Ns, self(), IntentId),
            gen_server:reply(From, ok),
            {noreply, S1};
        _ ->
            ok = quod_simplex:cancel_dtx_begin(Ns, self(), IntentId),
            gen_server:reply(From, {error, cancelled}),
            {noreply, S#s{dtx_handoff = none}}
    end;
accepted_dtx_handoff(_WrongIntentId, Handoff, S) ->
    rejected_dtx_handoff(
      {error, {protocol_error, dtx_handoff}}, Handoff, S).

rejected_dtx_handoff(
  Error,
  #dtx_handoff{intent_id = IntentId, from = From},
  S = #s{ns = Ns}) ->
    ok = quod_simplex:cancel_dtx_begin(Ns, self(), IntentId),
    gen_server:reply(From, Error),
    {noreply, S#s{dtx_handoff = none}}.

cancel_dtx_handoff(
  Ref,
  S = #s{ns = Ns,
         dtx_handoff = #dtx_handoff{
                           worker_ref = Ref, intent_id = IntentId,
                           from = From}}) ->
    ok = quod_simplex:cancel_dtx_begin(Ns, self(), IntentId),
    gen_server:reply(From, {error, cancelled}),
    S#s{dtx_handoff = none};
cancel_dtx_handoff(_Ref, S) ->
    S.

terminate(_Reason, #s{ns = Ns, workers = W,
                      waiting_workers = Waiting,
                      scope_workers = ScopeWorkers,
                      outcomes = Outcomes}) ->
    maps:foreach(fun(_Ref, #proof_worker{pid = Pid}) -> kill_worker(Pid) end, W),
    maps:foreach(
      fun(_Ref, #proof_worker{pid = Pid}) -> kill_worker(Pid) end,
      Waiting),
    maps:foreach(
      fun(_WM, #scope_worker{pid = Pid}) -> kill_worker(Pid) end,
      ScopeWorkers),
    _ = try quod_reg:unsubscribe(
              {channel, quod_scope_wire:request_channel(Ns)})
        catch _:_ -> ok end,
    ok = quod_outcome:close(Outcomes),
    ok.

%%%===================================================================
%%% proof execution (worker-per-proof; copy-on-write overlay)
%%%===================================================================

%% Spawn one worker for this proof. The worker gets a small table/height snapshot handle,
%% never the committed KB contents, plus the height stamped on the public reply.
%% The engine only tracks the monitor + a kill timer; it never runs the proof.
spawn_proof(Kind, Goal, From, TraceCtx, Principal,
            S = #s{ns = Ns, est = Est, applied = Applied,
                   signer = Signer,
                   proof_timeout_ms = ProofTimeout}) ->
    Engine = self(),
    Ref = make_ref(),
    ProofId = crypto:strong_rand_bytes(32),
    Deadline = quod_time:mono_ms() + ProofTimeout,
    {Pid, MRef} = spawn_opt(fun() ->
        proof_worker(Engine, Ref, ProofId, Deadline, Kind, Goal,
                     Ns, Est, Applied, TraceCtx, Principal, Signer)
    end, [monitor]),
    CallerMRef = monitor(process, proof_client_pid(From)),
    Token = make_ref(),
    KillDelay = max(1, Deadline - quod_time:mono_ms()),
    KillRef = erlang:send_after(KillDelay, Engine, {proof_kill, Ref, Token}),
    Worker = #proof_worker{pid = Pid, kind = Kind,
                           worker_mref = MRef, caller_mref = CallerMRef,
                           from = From, timer = KillRef, token = Token,
                           height = Applied},
    S#s{workers = (S#s.workers)#{Ref =>
          Worker},
        proves  = S#s.proves + 1}.

bump_proves(S) -> S#s{proves = S#s.proves + 1}.

%% Runs in the worker process. Sets the run's execution context on the frozen `#est{}`
%% (`m:quod_predicates` — the namespace, applied height, and call chain the external predicates
%% read), proves against that view, and reports one correlated result to the engine. The
%% origin-scope read-set ETS table is created here, so an abandoned/killed run can never leak it.
proof_worker(Engine, Ref, ProofId, Deadline, Kind, Goal, Ns, Est,
             Applied, TraceCtx, Principal, Signer) ->
    _ = quod_process:kill_when_owner_dies(Engine, self()),
    Ctx = worker_context(Kind, Ns, Applied),
    Result = quod_trace:with_span(
               TraceCtx, <<"quod.prolog.prove">>, internal,
               #{'quod.namespace' => Ns, 'quod.kb.height' => Applied,
                 'quod.proof.mode' => atom_to_binary(Kind, utf8)},
               fun(SpanCtx) ->
                   R = run_worker(
                         Engine, Ref, Kind, ProofId, Deadline, Goal, Principal,
                         Ns, Applied,
                         quod_predicates:set_context(Est, Ctx), Signer),
                   _ = quod_trace:result(SpanCtx, R),
                   R
               end),
    gen_server:cast(Engine, {proof_result, Ref, Result}).

worker_context(action, Ns, Applied) ->
    quod_predicates:effect_context(Ns, Applied);
worker_context(_ProofKind, Ns, Applied) ->
    %% Subject remains none until signed subjects land.
    quod_predicates:proof_context(Ns, Applied, undefined).

run_worker(Engine, Ref, action, ProofId, Deadline, {Action, Structural}, Principal,
           Ns, Applied, Est, Signer) ->
    run_lifecycle_origin(
      Engine, Ref, ProofId, Deadline, Action, Structural, Principal, Ns,
      Applied, Est, Signer);
run_worker(Engine, Ref, cursor, ProofId, Deadline,
           {Owner, CallRef, CursorId, Goal}, Principal,
           Ns, Applied, Est, Signer) ->
    run_cursor_origin(
      Engine, Ref, ProofId, Deadline, Owner, CallRef, CursorId, Goal,
      Principal, Ns, Applied, Est, Signer);
run_worker(Engine, Ref, Kind, ProofId, Deadline, Goal, Principal, Ns, Applied, Est,
           Signer) ->
    run_origin_proof(
      Engine, Ref, Kind, ProofId, Deadline, Goal, Principal, Ns, Applied, Est, Signer).

run_origin_proof(Engine, Ref, Kind, ProofId, Deadline, Goal, Principal, Ns, Applied, Est,
                 Signer) ->
    case quod_simplex:genesis_hash(Ns) of
        <<_:256>> = Anchor ->
            run_pinned_origin(
              Engine, Ref, Kind, ProofId, Deadline, Principal, Ns, Applied,
              Anchor, Est, Signer,
              fun(Origin) -> run_pinned_goal(Origin, Goal) end);
        undefined when Signer =:= none ->
            %% Isolated unit/runtime engines have no consensus identity and
            %% therefore cannot own foreign scopes. The same proof pipeline
            %% still runs under its private sentinel identity, including
            %% authorization, sealing, snapshot release and submission.
            Anchor = <<0:256>>,
            run_pinned_origin(
              Engine, Ref, Kind, ProofId, Deadline, Principal, Ns, Applied,
              Anchor, Est, Signer,
              fun(Origin) -> run_pinned_goal(Origin, Goal) end);
        undefined ->
            %% A keyed engine is a network participant. It must never seal a
            %% sentinel-anchored plan during the short ready/genesis gap.
            {error, rebuilding}
    end.

run_cursor_origin(Engine, Ref, ProofId, Deadline, Owner, CallRef, CursorId,
                  Goal, Principal, Ns, Applied, Est, Signer) ->
    case quod_simplex:genesis_hash(Ns) of
        <<_:256>> = Anchor ->
            run_pinned_origin(
              Engine, Ref, cursor, ProofId, Deadline, Principal, Ns, Applied,
              Anchor, Est, Signer,
              fun(Origin) ->
                  run_cursor_goal(
                    Owner, CallRef, CursorId, Goal, Origin)
              end);
        undefined when Signer =:= none ->
            run_pinned_origin(
              Engine, Ref, cursor, ProofId, Deadline, Principal, Ns, Applied,
              <<0:256>>, Est, Signer,
              fun(Origin) ->
                  run_cursor_goal(
                    Owner, CallRef, CursorId, Goal, Origin)
              end);
        undefined ->
            {error, rebuilding}
    end.

%% An anchored engine's immutable identity, or the zero sentinel for an
%% isolated unit/runtime engine that never founded — such an engine never
%% shares plans or transactions across nodes, so the sentinel binds nothing.
target_anchor(Ns) ->
    case quod_simplex:genesis_hash(Ns) of
        <<_:256>> = Anchor -> Anchor;
        undefined -> <<0:256>>
    end.

run_lifecycle_origin(Engine, Ref, ProofId, Deadline, Action, Structural, Principal,
                     Ns, Applied, Est, Signer) ->
    case quod_simplex:genesis_hash(Ns) of
        <<_:256>> = Anchor ->
            run_pinned_origin(
              Engine, Ref, action, ProofId, Deadline, Principal, Ns, Applied,
              Anchor, Est, Signer,
              fun(Origin) ->
                  run_lifecycle_action(Action, Structural, Origin)
              end);
        undefined ->
            %% A ready production engine always has its immutable genesis
            %% anchor. A test-only bare engine cannot safely mint distributed
            %% selector authority for a lifecycle effect.
            {error, rebuilding}
    end.

run_pinned_origin(Engine, Ref, Kind, ProofId, Deadline, Principal, Ns, Applied,
                  Anchor, Est, Signer, RunFun) ->
    %% Lifecycle actions are ordinary writable proofs whose only permitted
    %% material is one typed direct effect.  Keeping the proof context
    %% read-only here would silently discard that effect at sealing time.
    ReadOnly = Kind =:= prove_ro,
    OriginIdentity = {Ns, Anchor},
    AuthPrincipal = case Principal of
                        undefined -> proof_principal(Signer);
                        _ -> Principal
                    end,
    OriginHandle = quod_proof_context:start(
                     ProofId, ReadOnly, OriginIdentity, Deadline,
                     AuthPrincipal),
    OverlayOpts0 = #{read_set => true,
                     read_only => ReadOnly,
                     signer => Signer,
                     proof_context => {origin, OriginHandle}},
    %% A client-authenticated proof principal authorizes the proof itself.
    %% Only lifecycle actions carry their actor through the overlay's separate
    %% lifecycle-principal channel.
    OverlayOpts = case Kind =:= action andalso Principal =/= undefined of
                      true -> OverlayOpts0#{lifecycle_principal => Principal};
                      false -> OverlayOpts0
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
                    engine = Engine, worker_ref = Ref,
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
    Mode = finalization_mode(Result),
    case quod_proof_context:finalize(Mode) of
        ok -> Result;
        %% A failed/error proof has no submission to protect and abort never
        %% seals. Scope-close failure cannot turn logical failure into a
        %% different public result; remote private state expires discarded.
        {error, _Reason} when Mode =:= abort -> Result;
        %% Durable hand-off precedes scope cleanup. Once an ordinary commit or
        %% an activated group exists, a later close/fence failure is only a
        %% cleanup failure: replacing the handle would invite an unsafe retry.
        {error, _Reason}
          when element(1, Result) =:= committed;
               element(1, Result) =:= group_pending -> Result;
        {error, Reason} -> {error, Reason}
    end.

finalization_mode({ok, _, _, _}) -> commit;
finalization_mode({committed, _, _}) -> commit;
finalization_mode({group_pending, _, _}) -> commit;
finalization_mode(_Result) -> abort.

-ifdef(TEST).
test_finalize_pinned_result(Result) -> finalize_pinned_result(Result).
-endif.

%% `::` is only a selector, so an ontology's own policy must gate a TOP-LEVEL
%% entry exactly as it gates a co-hosted or remote one — otherwise a restrictive
%% policy would be bypassed simply by proving the goal locally. A node's own
%% top-level proof uses the empty chain admitted by the founding host-entry
%% clause. A browser user is not that host: give it a non-empty, engine-owned
%% chain so its user-specific `can_invoke/4` policy is actually consulted.
%% This does not override an ontology that explicitly grants users access —
%% notably the shipped root ontology is deliberately open by its own policy.
run_pinned_goal(#pinned_origin{kind = Kind} = Origin, Goal) ->
    Verdict = authorization_verdict(Origin, Goal),
    run_authorized_pinned_goal(Kind, Origin, Goal, Verdict).

%% Keep the requested goal intact for the authorization transcript. The proof
%% session derives the bounded denial goal only for execution.
authorization_verdict(
  #pinned_origin{namespace = Ns, anchor = Anchor,
                 height = Height, session = Session}, Goal) ->
    Principal = quod_proof_context:principal(),
    case quod_ask:authorize_scope(
           Principal, Goal, authorization_chain(Principal, {Ns, Anchor}), {Ns, Anchor},
           Height, Session) of
        true -> allowed;
        false ->
            logger:warning(
              "quod_prolog[~s]: can_invoke refused a top-level goal at "
              "pinned height ~p", [Ns, Height]),
            denied
    end.

authorization_chain({user, <<_:256>>}, Identity) -> [Identity];
authorization_chain(_Principal, _Identity) -> [].

proof_principal(#{pubkey := <<_:256>> = Pubkey}) -> {node, Pubkey};
proof_principal(none) -> anonymous.

valid_public_proof_principal(undefined) -> true;
valid_public_proof_principal({user, <<_:256>>}) -> true;
valid_public_proof_principal(_) -> false.

run_authorized_pinned_goal(Kind, Origin, Goal, Verdict) ->
    Result = normalize_read_only_result(
               Kind, run_origin_invocation(Origin, Goal, Verdict)),
    finish_pinned_proof(Kind, Origin, Goal, Result).

%% A successful writable proof seals every scope while all sessions are still
%% open, then routes the immutable participant set once: zero material plans is
%% a read, one plan uses that target's ordinary consensus path, and two or more
%% use one atomic group. A participant contributed writes or OCC reads.
%% Read-only proof kinds and failed proofs pass through; failed proofs close
%% without sealing.
finish_pinned_proof(prove, Origin, Goal, {ok, Bindings, _Diff, ReadSet}) ->
    case quod_proof_context:seal_plans() of
        {ok, Plans} ->
            submit_sealed_plans(Origin, Goal, Bindings, ReadSet, Plans);
        {error, _} = Error ->
            Error
    end;
finish_pinned_proof(_Kind, _Origin, _Goal, Result) ->
    Result.

submit_sealed_plans(Origin, Goal, Bindings, ReadSet, Plans) ->
    Participants = lists:sort(
                     [Identity || {Identity, Plan} <- maps:to_list(Plans),
                                  quod_dtx:participates(Plan)]),
    EffectParticipants =
        [Identity || {Identity, Plan} <- maps:to_list(Plans),
                     quod_dtx:effects_count(Plan) > 0],
    case {Participants, EffectParticipants} of
        {[], _} ->
            %% Nothing staged anywhere: the ordinary read result. Sealed
            %% read-only plans stay in the context for the group protocol.
            {ok, Bindings, [], ReadSet};
        {[Target], []} ->
            submit_single_plan(
              Origin, Target, maps:get(Target, Plans), Goal, Bindings);
        {[Target], [_]} ->
            submit_single_plan(
              Origin, Target, maps:get(Target, Plans), Goal, Bindings);
        {_Many, [_ | _]} ->
            {error, effect_requires_single_participant};
        {Participants, []} ->
            submit_group(
              Origin, Goal, Bindings, Plans, Participants)
    end.

checkpoint_and_release_origin_snapshot(
  #pinned_origin{engine = Engine, worker_ref = WorkerRef}, OutcomeRef) ->
    gen_server:call(
      Engine,
      {checkpoint_and_release_proof_snapshot, WorkerRef, OutcomeRef},
      infinity).

checkpoint_bound_effect(
  #pinned_origin{engine = Engine, worker_ref = WorkerRef},
  Effect, Change, OutcomeRef) ->
    gen_server:call(
      Engine,
      {checkpoint_bound_effect, WorkerRef, Effect, Change, OutcomeRef},
      infinity).

submit_single_plan(Origin, Target, Plan, Goal, Bindings) ->
    case quod_transaction:encode_durable_submission(Goal, Bindings) of
        {ok, GoalBlob, ResultBlob} ->
            case quod_dtx:effects_count(Plan) of
                0 ->
                    submit_single_ordinary_plan(
                      Origin, Target, Plan, Goal, Bindings,
                      GoalBlob, ResultBlob);
                1 ->
                    submit_single_effect_plan(
                      Origin, Target, Plan, Bindings,
                      GoalBlob, ResultBlob);
                _ ->
                    {error, invalid_direct_effect}
            end;
        {error, _} = Error ->
            Error
    end.

submit_single_ordinary_plan(
  #pinned_origin{namespace = Ns, anchor = Anchor} = Origin,
  {TargetNs, TargetAnchor} = Target, Plan, Goal, Bindings,
  GoalBlob, ResultBlob) ->
    OutcomeRef = quod_transaction:plan_outcome_ref(
                   Plan, GoalBlob, ResultBlob),
    case checkpoint_and_release_origin_snapshot(Origin, OutcomeRef) of
                ok ->
                    Result = submit_single_plan_at_target(
                               Target, Plan, Goal, Bindings,
                               GoalBlob, ResultBlob),
                    case {Result, Target} of
                        {{ok, _B, Index, _TxId}, {Ns, Anchor}} ->
                            {committed, Bindings, Index};
                        {{ok, _B, _Index, TxId}, _Foreign} ->
                            {committed, Bindings,
                             {transaction, TargetNs, TargetAnchor, TxId}};
                        {{error, _} = Error, _} ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
    end.

submit_single_effect_plan(
  #pinned_origin{namespace = Ns, anchor = Anchor} = Origin,
  {Ns, Anchor} = Target, Plan, Bindings, GoalBlob, ResultBlob) ->
    case quod_dtx:material(Plan) of
        {ok, #{effects := [Effect]} = Material} ->
            Change0 = quod_transaction:from_plan(
                        Plan, Material, GoalBlob, ResultBlob),
            Change = Change0#transaction{
                       author = quod_dtx:signer(Plan),
                       submitted_at = quod_time:now_ms()},
            OutcomeRef = {transaction, Ns, Anchor,
                          Change#transaction.tx_id},
            case checkpoint_bound_effect(
                   Origin, Effect, Change, OutcomeRef) of
                ok ->
                    case submit_bound_effect_plan(
                           Target, Plan, Change,
                           GoalBlob, ResultBlob, Bindings) of
                        {ok, _B, Index, _TxId} ->
                            {committed, Bindings,
                             {effect_commit, Index, OutcomeRef}};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        _ ->
            {error, invalid_direct_effect}
    end;
submit_single_effect_plan(_Origin, _Target, _Plan, _Bindings,
                          _GoalBlob, _ResultBlob) ->
    {error, effect_executor_not_local}.

submit_bound_effect_plan(
  {TargetNs, TargetAnchor}, Plan, Change, GoalBlob, ResultBlob, Bindings) ->
    case quod_proof_context:scope_handle({TargetNs, TargetAnchor}) of
        {ok, {local_scope, _, TargetNs, TargetAnchor, _, _}} ->
            submit_bound_effect_plan_encoded(
              TargetNs, Plan, Change, GoalBlob, ResultBlob, Bindings);
        {ok, {quod_scope_session, _, _, _, _, TargetNs, TargetAnchor}} ->
            submit_bound_effect_plan_encoded(
              TargetNs, Plan, Change, GoalBlob, ResultBlob, Bindings);
        _ ->
            {error, effect_executor_not_local}
    end.

submit_bound_effect_plan_encoded(
  TargetNs, Plan, Change, GoalBlob, ResultBlob, Bindings) ->
    case quod_reg:where({quod_prolog, TargetNs}) of
        undefined -> {error, {ontology_unreachable, TargetNs}};
        Pid ->
            try gen_server:call(
                  Pid,
                  {submit_bound_effect_plan, Plan, Change,
                   GoalBlob, ResultBlob, [Bindings], quod_trace:context()},
                  infinity)
            catch exit:_ ->
                {error, {outcome_unknown,
                         {transaction, TargetNs,
                          element(2, quod_dtx:target(Plan)),
                          Change#transaction.tx_id}}}
            end
    end.

submit_single_plan_at_target(
  {TargetNs, TargetAnchor} = Target, Plan, Goal, Bindings,
  GoalBlob, ResultBlob) ->
    case quod_proof_context:scope_handle(Target) of
        {ok, {remote_scope, _, _, _, _} = Handle} ->
            %% The remote facade canonical-encodes the same immutable values;
            %% OutcomeRef above is therefore the exact target transaction.
            submit_remote_plan(Handle, Plan, Goal, Bindings);
        {ok, {local_scope, _, TargetNs, TargetAnchor, _, _}} ->
            submit_plan_encoded(
              TargetNs, Plan, GoalBlob, ResultBlob, Bindings);
        {ok, {quod_scope_session, _, _, _, _,
              TargetNs, TargetAnchor}} ->
            submit_plan_encoded(
              TargetNs, Plan, GoalBlob, ResultBlob, Bindings);
        _ ->
            {error, {ontology_unreachable, TargetNs}}
    end.

submit_plan_encoded(TargetNs, Plan, GoalBlob, ResultBlob, Bindings) ->
    case quod_reg:where({quod_prolog, TargetNs}) of
        undefined -> {error, {ontology_unreachable, TargetNs}};
        Pid ->
            try gen_server:call(
                  Pid,
                  {submit_plan, Plan, GoalBlob, ResultBlob,
                   [Bindings], quod_trace:context()}, infinity)
            catch exit:_ ->
                {error,
                 {outcome_unknown,
                  quod_transaction:plan_outcome_ref(
                    Plan, GoalBlob, ResultBlob)}}
            end
    end.

submit_group(
  #pinned_origin{engine = Engine, worker_ref = WorkerRef,
                 proof_id = ProofId, namespace = Ns,
                 anchor = Anchor},
  Goal, Bindings, Plans, Participants) ->
    case quod_transaction:encode_durable_submission(Goal, Bindings) of
        {ok, GoalBlob, ResultBlob} ->
            case quod_simplex:dtx_binding(Ns) of
                {ok, {Ns, Anchor, _Coordinator, _Admission} = Coordinator} ->
                    Principal = quod_dtx:principal(
                                  maps:get(hd(Participants), Plans)),
                    ParticipantRows =
                        [{Identity,
                          quod_dtx:digest(maps:get(Identity, Plans))}
                         || Identity <- Participants],
                    ManifestInput =
                        #{proof_id => ProofId,
                          coordinator => Coordinator,
                          nonce => crypto:strong_rand_bytes(32),
                          principal => Principal,
                          goal => GoalBlob,
                          result => ResultBlob,
                          participants => ParticipantRows},
                    build_and_register_group(
                      Engine, WorkerRef, ManifestInput,
                      Plans, ParticipantRows, Bindings);
                {ok, _WrongBinding} ->
                    {error, {protocol_error, coordinator_binding}};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

build_and_register_group(
  Engine, WorkerRef, ManifestInput, Plans, ParticipantRows, Bindings) ->
    case quod_dtx:new_manifest(ManifestInput) of
        {ok, Manifest} ->
            case attest_group_plans(
                   ParticipantRows, Plans, Manifest, []) of
                {ok, Bundles} ->
                    case quod_dtx:new_begin(Manifest, Bundles) of
                        {ok, Begin} ->
                            case quod_dtx:begin_group_ref(Begin) of
                                {ok, GroupRef} ->
                                    case gen_server:call(
                                           Engine,
                                           {register_dtx_begin, WorkerRef,
                                            Begin, GroupRef}, infinity) of
                                        ok ->
                                            {group_pending, Bindings, GroupRef};
                                        {error, _} = Error -> Error
                                    end;
                                error ->
                                    {error, invalid_begin}
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

attest_group_plans([], _Plans, _Manifest, RevBundles) ->
    {ok, lists:reverse(RevBundles)};
attest_group_plans(
  [{Identity, PlanDigest} | Rest], Plans, Manifest, RevBundles) ->
    Plan = maps:get(Identity, Plans),
    case {quod_proof_context:scope_handle(Identity), quod_dtx:encode(Plan)} of
        {{ok, Handle}, {ok, PlanBlob}} ->
            case quod_scope_session:attest_plan(Handle, Plan, Manifest) of
                {ok, Attestation} ->
                    Bundle = {Identity, PlanDigest, PlanBlob, Attestation},
                    attest_group_plans(
                      Rest, Plans, Manifest, [Bundle | RevBundles]);
                {error, _} = Error -> Error
            end;
        {error, _} -> {error, {protocol_error, session_binding}};
        {_, {error, _} = Error} -> Error
    end.

%% The remote target committed under its own authorship; only the bounded
%% outcome crosses back through the still-open scope session.
submit_remote_plan(Handle, Plan, Goal, Bindings) ->
    case quod_scope_session:submit_plan(Handle, Plan, Goal, Bindings) of
        {ok, Slot, TxId} -> {ok, [Bindings], Slot, TxId};
        {error, _} = Error -> Error
    end.

run_origin_invocation(Origin, Goal) ->
    run_origin_invocation(Origin, Goal, allowed).

run_cursor_goal(
  Owner, CallRef, CursorId, Goal,
  #pinned_origin{scope_id = ScopeId, session = Session,
                 context = Context, height = Height} = Origin) ->
    Verdict = authorization_verdict(Origin, Goal),
    InvocationId = crypto:strong_rand_bytes(16),
    Actor = {ScopeId, InvocationId},
    Selection = quod_transaction_scope:empty_selection(),
    case quod_proof_context:register_invocation(Actor, Selection) of
        ok ->
            CursorResult =
                try
                    case quod_proof_session:open(
                           Session, InvocationId, Goal, Verdict,
                           Context, Selection) of
                        ok ->
                            cursor_step(
                              Owner, CallRef, CursorId, open, InvocationId,
                              Session, Height);
                        {error, Reason} ->
                            {error, Reason}
                    end
                after
                    try quod_proof_session:cancel(Session, InvocationId)
                    after quod_proof_context:unregister_invocation(Actor)
                    end
                end,
            case CursorResult of
                {accept, Bindings} ->
                    finish_pinned_proof(
                      prove, Origin, Goal,
                      {ok, Bindings,
                       quod_proof_session:local_changes(Session),
                       quod_proof_session:read_set(Session)});
                Other -> Other
            end;
        {error, Reason} ->
            {error, Reason}
    end.

cursor_step(Owner, CallRef, CursorId, CommandRef, InvocationId,
            Session, Height) ->
    case quod_proof_session:next(Session, InvocationId) of
        {solution, _Solution} ->
            case quod_proof_session:bindings(Session, InvocationId) of
                {ok, Bindings} ->
                    Owner ! {quod_cursor_solution, self(), CallRef, CursorId,
                             CommandRef, Bindings, Height},
                    cursor_wait(
                      Owner, CallRef, CursorId, InvocationId,
                      Session, Height);
                {error, Reason} ->
                    {error, Reason}
            end;
        {complete, Reasons} ->
            {fail, Reasons};
        {error, Reason} ->
            {error, Reason}
    end.

cursor_wait(Owner, CallRef, CursorId, InvocationId, Session, Height) ->
    Remaining = quod_proof_context:remaining_ms(),
    receive
        {quod_cursor_command, Owner, CallRef, CursorId,
         CommandRef, next} ->
            cursor_step(
              Owner, CallRef, CursorId, CommandRef, InvocationId,
              Session, Height);
        {quod_cursor_command, Owner, CallRef, CursorId,
         _CommandRef, accept} ->
            case quod_proof_session:bindings(Session, InvocationId) of
                {ok, Bindings} -> {accept, Bindings};
                {error, Reason} -> {error, Reason}
            end;
        {quod_cursor_command, Owner, CallRef, CursorId,
         _CommandRef, stop} ->
            cursor_stopped
    after Remaining ->
        {error, {proof_limit_exceeded,
                 element(1, quod_proof_context:origin_identity())}}
    end.

run_origin_invocation(
  #pinned_origin{scope_id = ScopeId,
                 session = Session, context = Context}, Goal, Verdict) ->
    InvocationId = crypto:strong_rand_bytes(16),
    Actor = {ScopeId, InvocationId},
    Selection = quod_transaction_scope:empty_selection(),
    case quod_proof_context:register_invocation(Actor, Selection) of
        ok ->
            try quod_proof_session:open_first(
                  Session, InvocationId, Goal, Verdict, Context, Selection)
            after
                try
                    ok = quod_proof_session:cancel(Session, InvocationId)
                after
                    quod_proof_context:unregister_invocation(Actor)
                end
            end;
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
            case quod_effect_journal:reserve(self()) of
                {ok, Reservation} ->
                    try
                        case quod_ontology:prepare_action(Structural) of
                            {ok, Prepared} ->
                                Goal =
                                    {prepare_lifecycle_action, Action,
                                     {'DesiredState'}, {'Mode'}},
                                Selection = run_origin_invocation(Origin, Goal),
                                complete_lifecycle_action(
                                  Action, Prepared, Reservation,
                                  Origin, Selection);
                            {error, Reason} ->
                                {fail,
                                 [quod_ontology_predicates:lifecycle_error(
                                    Action, Reason)]}
                        end
                    after
                        ok = quod_effect_journal:release_reservation(
                               Reservation)
                    end;
                {error, busy} ->
                    {error, busy};
                {error, _} ->
                    {error, lifecycle_journal_unavailable}
            end;
        {error, Reason} ->
            {fail, [Reason]}
    end.

complete_lifecycle_action(Action, Prepared, Reservation, Origin,
                          {ok, Bindings, [], _ReadSet})
  when is_map(Bindings) ->
    case {maps:find('DesiredState', Bindings), maps:find('Mode', Bindings)} of
        {{ok, DesiredState}, {ok, Mode}}
          when Mode =:= already; Mode =:= execute ->
            finish_lifecycle_action(
              Action, Prepared, Reservation, Origin, DesiredState, Mode);
        _ ->
            {error, action_declaration_failed}
    end;
complete_lifecycle_action(_Action, _Prepared, _Reservation, _Origin,
                          {ok, _Bindings, _Diff, _ReadSet}) ->
    {error, lifecycle_staged_write};
complete_lifecycle_action(_Action, _Prepared, _Reservation, _Origin,
                          {error, {erlog,
                                   {permission_error, modify,
                                    static_procedure, _Predicate}}}) ->
    {error, lifecycle_staged_write};
complete_lifecycle_action(_Action, _Prepared, _Reservation, _Origin, Result) ->
    Result.

finish_lifecycle_action(Action, Prepared, Reservation,
                        Origin, DesiredState, Mode) ->
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
                    stage_commit_and_execute_lifecycle(
                      Action, Prepared, Reservation,
                      Origin, DesiredState)
            end
    end.

stage_commit_and_execute_lifecycle(
  Action, Prepared, Reservation,
  #pinned_origin{session = Session} = Origin, DesiredState) ->
    Principal = quod_proof_context:principal(),
    case quod_proof_session:signer(Session) of
        #{pubkey := <<_:256>> = Executor} ->
            case quod_ontology:prepared_effect(
                   Action, Prepared, Executor, Principal) of
                {ok, Effect} ->
                    case quod_effect_journal:stage(
                           Reservation, Action, DesiredState,
                           Effect, Prepared) of
                        ok ->
                            ok = quod_proof_session:set_lifecycle_effect(
                                   Session, Effect),
                            stage_lifecycle_transition(
                              Action, Effect, Origin, Session);
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {fail, [quod_ontology_predicates:lifecycle_error(
                              Action, Reason)]}
            end;
        none ->
            {error, rebuilding}
    end.

stage_lifecycle_transition(Action, Effect, Origin, Session) ->
    case run_origin_invocation(Origin, Action) of
                        {ok, Bindings, [], ReadSet} = Staged ->
                            case quod_proof_session:effects(Session) of
                                [Effect] ->
                                    Submitted = finish_pinned_proof(
                                                  prove, Origin, Action,
                                                  Staged),
                                    complete_committed_lifecycle(
                                      Effect, Submitted,
                                      Bindings, ReadSet);
                                _ ->
                                    {error, lifecycle_effect_not_staged}
                            end;
                        {ok, _Bindings, _Diff, _ReadSet} ->
                            {error, lifecycle_staged_write};
        Other ->
            Other
    end.

complete_committed_lifecycle(
  Effect, {committed, _Bindings,
           {effect_commit, Height, OutcomeRef}},
    _Bindings0, _ReadSet) ->
    case quod_effect_journal:await(
           quod_effect:effect_id(Effect),
           max(1, quod_proof_context:remaining_ms())) of
        ok -> {committed, #{}, Height};
        {error, outcome_unknown} ->
            {error, {outcome_unknown, OutcomeRef}};
        {error, Reason} ->
            {error, Reason}
    end;
complete_committed_lifecycle(
  _Effect, Other, _Bindings, _ReadSet) ->
    Other.

lifecycle_success() -> {ok, #{}, [], #{}}.

%% Every worker result is terminal now: a write proof commits (or fails)
%% inside the worker through submit_plan/4 before it reports, so the engine's
%% one reply path only shapes results — it never re-enters submission.
finish_proof(Ref, {group_pending, _Bindings, GroupRef}, S) ->
    retain_group_waiter(Ref, GroupRef, S);
finish_proof(Ref, Result, S) ->
    case take_proof_worker(Ref, S) of
        error -> S;
        {{From, Applied}, S1} ->
            case Result of
                {fail, []} -> reply_client(From, fail), S1;
                {fail, Reasons} -> reply_client(From, {fail, Reasons}), S1;
                {error, _} = E -> reply_client(From, E), S1;
                {ok, Bindings, [], _ReadSet} ->
                    reply_client(From, {ok, [Bindings], Applied}), S1;
                {committed, Bindings, Handle} ->
                    reply_client(From, {ok, [Bindings], Handle}), S1;
                cursor_stopped ->
                    reply_client(From, {ok, stopped}), S1;
                _Other ->
                    reply_client(
                      From, {error, {protocol_error, proof_engine}}), S1
            end
    end.

retain_group_waiter(
  Ref,
  {group, _Ns, _Anchor, _Coordinator, _Admission, <<_:256>> = GroupId}
    = GroupRef,
  S = #s{waiting_workers = Waiting, group_waiters = GroupWaiters,
         max_proof_workers = Max, ttl = Ttl}) ->
    case {maps:take(Ref, Waiting), maps:is_key(GroupId, GroupWaiters)} of
        {{#proof_worker{checkpoint = GroupRef,
                        worker_mref = WorkerMRef,
                        caller_mref = CallerMRef,
                        from = From, timer = ProofTimer}, Waiting1}, false}
          when map_size(GroupWaiters) < Max ->
            _ = erlang:cancel_timer(ProofTimer),
            demonitor(WorkerMRef, [flush]),
            Timer = erlang:send_after(Ttl, self(),
                                      {group_wait_timeout, GroupId}),
            Waiter = #group_waiter{
                        from = From, caller_mref = CallerMRef,
                        timer = Timer, group_ref = GroupRef},
            S1 = S#s{waiting_workers = Waiting1,
                     group_waiters = GroupWaiters#{GroupId => Waiter}},
            %% Complete may have crossed this worker's scope-cleanup/result
            %% message. Re-read the flushed projection now so that ordering
            %% cannot strand a waiter until its deadline.
            release_group_waiter(GroupRef, S1);
        {{Worker, Waiting1}, _} ->
            {_Reply, _Height} = proof_worker_reply(Worker),
            reply_client(Worker#proof_worker.from,
                         {error, {outcome_unknown, GroupRef}}),
            S#s{waiting_workers = Waiting1};
        {error, _} ->
            S
    end;
retain_group_waiter(Ref, _BadRef, S) ->
    case take_proof_worker(Ref, S) of
        {{From, _Applied}, S1} ->
            reply_client(From, {error, {protocol_error, dtx_waiter}}),
            S1;
        error -> S
    end.

take_proof_worker(Ref, S = #s{workers = W, waiting_workers = Waiting}) ->
    case maps:take(Ref, W) of
        {Worker, W1} ->
            {proof_worker_reply(Worker),
             S#s{workers = W1}};
        error ->
            case maps:take(Ref, Waiting) of
                {Worker, Waiting1} ->
                    {proof_worker_reply(Worker),
                     S#s{waiting_workers = Waiting1}};
                error -> error
            end
    end.

proof_worker_reply(
  #proof_worker{worker_mref = WorkerMRef, caller_mref = CallerMRef,
                from = From, timer = TimerRef, height = Applied}) ->
    _ = erlang:cancel_timer(TimerRef),
    demonitor(WorkerMRef, [flush]),
    demonitor(CallerMRef, [flush]),
    {From, Applied}.

proof_client_pid({async, Pid, _CallRef}) when is_pid(Pid) -> Pid.

reply_client({async, Caller, CallRef}, Reply) ->
    Caller ! {quod_proof_reply, self(), CallRef, Reply},
    ok;
reply_client(From, Reply) ->
    gen_server:reply(From, Reply).

checkpoint_client({async, Caller, CallRef}, Ref) ->
    Caller ! {quod_proof_checkpoint, self(), CallRef, Ref},
    ok;
checkpoint_client(_InternalCaller, _Ref) ->
    ok.

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

handle_proof_down(MRef, Reason, S) ->
    case find_proof_monitor(MRef, S#s.workers) of
        false -> handle_waiting_proof_down(MRef, Reason, S);
        Found -> finish_proof_down(Found, Reason, S)
    end.

handle_waiting_proof_down(MRef, Reason, S) ->
    case find_proof_monitor(MRef, S#s.waiting_workers) of
        false -> handle_group_waiter_down(MRef, S);
        Found -> finish_proof_down(Found, Reason, S)
    end.

handle_group_waiter_down(MRef, S = #s{group_waiters = Waiters}) ->
    case maps:fold(
           fun(GroupId, #group_waiter{caller_mref = CallerMRef}, Acc) ->
                   case Acc of
                       none when CallerMRef =:= MRef -> GroupId;
                       _ -> Acc
                   end
           end, none, Waiters) of
        none ->
            unhandled;
        GroupId ->
            {#group_waiter{timer = Timer}, Waiters1} =
                maps:take(GroupId, Waiters),
            _ = erlang:cancel_timer(Timer),
            {noreply, S#s{group_waiters = Waiters1}}
    end.

finish_proof_down(Found, Reason, S) ->
    case Found of
        {worker, Ref, From, Kind, Checkpoint} ->
            S0 = cancel_dtx_handoff(Ref, S),
            case take_proof_worker(Ref, S0) of
                {{_From, _Height}, S1} ->
                    Reply = proof_down_reply(
                              Kind, Reason, S#s.ns, Checkpoint),
                    reply_client(From, Reply),
                    {noreply, S1};
                error -> {noreply, S0}
            end;
        {caller, Ref, Pid} ->
            kill_worker(Pid),
            S0 = cancel_dtx_handoff(Ref, S),
            case take_proof_worker(Ref, S0) of
                {{_From, _Height}, S1} -> {noreply, S1};
                error -> {noreply, S0}
            end;
        false -> unhandled
    end.

find_proof_monitor(MRef, W) ->
    maps:fold(
      fun(Ref, #proof_worker{pid = Pid, kind = Kind,
                             worker_mref = WorkerMRef,
                             caller_mref = CallerMRef, from = From,
                             checkpoint = Checkpoint}, Acc) ->
          case Acc of
              false when WorkerMRef =:= MRef ->
                  {worker, Ref, From, Kind, Checkpoint};
              false when CallerMRef =:= MRef -> {caller, Ref, Pid};
              _ -> Acc
          end
      end, false, W).

find_cursor_worker(Owner, CallRef, Workers) ->
    maps:fold(
      fun(_Ref,
          #proof_worker{pid = Pid, kind = cursor,
                        from = {async, Owner0, CallRef0}}, Acc) ->
              case Acc of
                  error when Owner0 =:= Owner, CallRef0 =:= CallRef ->
                      {ok, Pid};
                  _ -> Acc
              end;
         (_Ref, #proof_worker{}, Acc) -> Acc
      end, error, Workers).

proof_down_reply(_Kind, _Reason, _Ns, Checkpoint)
  when Checkpoint =/= none ->
    {error, {outcome_unknown, Checkpoint}};
proof_down_reply(Kind, Reason, Ns, none) ->
    proof_down_reply(Kind, Reason, Ns).

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

%% Validate one sealed plan against this engine's own identity and turn it
%% into the signed ordinary transaction envelope. Sealing is target-side, so
%% every plan this engine legitimately receives was witnessed by THIS node —
%% a plan witnessed by anyone else (or a forged unsigned one on a keyed node)
%% is rejected before any consensus interaction.
accept_plan_submission(
  _From, _Plan, _GoalBlob, _ResultBlob, _ReplyBindings, _TraceCtx,
  S = #s{ready = false, ns = Ns}) ->
    {reply, {error, {ontology_rebuilding, Ns}}, S};
accept_plan_submission(
  From, Plan, GoalBlob, ResultBlob, ReplyBindings, TraceCtx, S) ->
    case valid_plan_submission(Plan, GoalBlob, ResultBlob, S) of
        {ok, #{effects := []} = Material} ->
            submit_plan_envelope(
              From, Plan, Material, GoalBlob, ReplyBindings, ResultBlob,
              TraceCtx, S);
        {ok, _EffectBearingMaterial} ->
            %% Direct effects require the checkpointed exact-transaction
            %% handoff. The ordinary plan API must not create a second path.
            {reply, {error, effect_requires_bound_handoff}, S};
        {error, Reason} ->
            outcome_admission_error(Reason, S)
    end.

accept_bound_effect_submission(
  _From, _Plan, _Change, _GoalBlob, _ResultBlob,
  _ReplyBindings, _TraceCtx, S = #s{ready = false, ns = Ns}) ->
    {reply, {error, {ontology_rebuilding, Ns}}, S};
accept_bound_effect_submission(
  From, Plan, Change, GoalBlob, ResultBlob,
  ReplyBindings, TraceCtx, S = #s{ns = Ns, outcomes = Outcomes0,
                                  parked = Parked}) ->
    case valid_plan_submission(Plan, GoalBlob, ResultBlob, S) of
        {ok, Material} ->
            Expected0 = quod_transaction:from_plan(
                          Plan, Material, GoalBlob, ResultBlob),
            Expected = Expected0#transaction{
                         author = S#s.self,
                         submitted_at = Change#transaction.submitted_at},
            case Change =:= Expected andalso
                 Change#transaction.author_seq =:= 0 andalso
                 Change#transaction.sig =:= none andalso
                 quod_transaction:valid_id(
                   {Ns, target_anchor(Ns)}, Change) of
                true ->
                    Ref = {transaction, Ns, target_anchor(Ns),
                           Change#transaction.tx_id},
                    admit_bound_effect_plan(
                      From, Change, ReplyBindings, TraceCtx,
                      Ref, Outcomes0, Parked, S);
                false ->
                    {reply, {error, invalid_direct_effect_transaction}, S}
            end;
        {error, Reason} ->
            outcome_admission_error(Reason, S)
    end.

admit_bound_effect_plan(From, Change, ReplyBindings, TraceCtx, Ref,
                        Outcomes0, Parked, S) ->
    Tx = Change#transaction.tx_id,
    case quod_outcome:admit(Outcomes0, Change) of
        {{terminal, Stored}, Outcomes1} ->
            {reply, terminal_submission_reply(Stored, ReplyBindings),
             S#s{outcomes = Outcomes1}};
        {pending, Outcomes1} when is_map_key(Tx, Parked) ->
            {reply, {error, {outcome_unknown, Ref}},
             S#s{outcomes = Outcomes1}};
        {Status, Outcomes1} when Status =:= pending; Status =:= new ->
            handoff_and_park_effect(
              From, Change, ReplyBindings, TraceCtx,
              S#s{outcomes = Outcomes1});
        {error, Reason} ->
            outcome_index_error(Reason, Ref, S)
    end.

handoff_and_park_effect(
  From, #transaction{effects = [Effect]} = Change,
  ReplyBindings, TraceCtx, S) ->
    EffectId = quod_effect:effect_id(Effect),
    case quod_effect_journal:handoff(EffectId) of
        ok ->
            park_handed_off_effect(
              From, Change, ReplyBindings, TraceCtx, S);
        {error, Reason}
          when Reason =:= busy; Reason =:= outcome_unknown;
               Reason =:= unavailable ->
            %% Custody may already be durable.  Keep the exact outcome parked
            %% and let journal reconciliation repeat only this hand-off.
            quod_effect_journal:reconcile(),
            park_handed_off_effect(
              From, Change, ReplyBindings, TraceCtx, S);
        {error, Reason} ->
            quod_effect_journal:retire([Effect], Reason),
            {reply, {error, Reason},
             discard_unsubmitted(Change#transaction.tx_id, S)}
    end.

park_handed_off_effect(
  From, Change, ReplyBindings, TraceCtx, S = #s{ns = Ns}) ->
    Tx = Change#transaction.tx_id,
    {TransactionCtx, SpanCtx} = quod_trace:start_span(
                                  TraceCtx, <<"quod.transaction">>, internal,
                                  #{'quod.namespace' => Ns,
                                    'quod.tx.id' => quod_trace:tx_id(Tx),
                                    'quod.kb.read_height' => S#s.applied,
                                    'quod.diff.operations' => 0}),
    _ = quod_trace:add_event(
          TransactionCtx, <<"transaction.handed_off">>, #{}),
    TRef = erlang:send_after(S#s.ttl, self(), {park_timeout, Tx}),
    T0 = quod_time:mono_ms(),
    Parked1 = (S#s.parked)#{Tx =>
                 {From, ReplyBindings, S#s.applied, TRef, none,
                  SpanCtx, T0}},
    {noreply, S#s{parked = Parked1}}.

outcome_admission_error(Reason, S) ->
    {reply, {error, Reason}, S}.

outcome_index_error(Reason, Ref, S) ->
    %% The index can no longer prove whether this semantic transaction was
    %% admitted earlier. Stop and return its stable reference; a definite
    %% rejection would make a non-idempotent retry unsafe.
    {stop, {outcome_index_unavailable, Reason},
     {error, {outcome_unknown, Ref}}, S}.

-ifdef(TEST).
test_not_ready_plan_submission(Ns) ->
    {reply, Reply, _State} = accept_plan_submission(
                               ignored, ignored, ignored, ignored, [],
                               otel_ctx:new(),
                               #s{ready = false, ns = Ns}),
    Reply.
-endif.

valid_plan_submission(Plan, GoalBlob, ResultBlob, S = #s{ns = Ns}) ->
    try
        quod_dtx:target(Plan) =:= {Ns, target_anchor(Ns)}
            orelse throw(bad_plan),
        quod_dtx:verify(Plan) orelse throw(bad_plan),
        self_witnessed(quod_dtx:signer(Plan), S#s.self)
            orelse throw(bad_plan),
        quod_dtx:base_height(Plan) =< S#s.applied orelse throw(bad_plan),
        {ok, Material} = quod_dtx:material(Plan),
        valid_direct_plan_effects(Plan, Material) orelse
            throw(invalid_direct_effect),
        {ok, _Goal} = quod_durable_term:decode_goal(GoalBlob),
        {ok, _DurableResult} = quod_durable_term:decode_result(ResultBlob),
        {ok, Material}
    catch
        error:{badmatch, {error, Reason}} -> {error, Reason};
        throw:Reason -> {error, Reason};
        _:_ -> {error, bad_plan}
    end.

valid_direct_plan_effects(Plan, #{effects := Effects}) ->
    case Effects of
        [] -> true;
        [Effect] ->
            quod_effect:validate(Effect) andalso
                quod_effect:executor(Effect) =:= quod_dtx:signer(Plan) andalso
                quod_effect:actor(Effect) =:= quod_dtx:principal(Plan) andalso
                quod_dtx:diff_ops(Plan) =:= 0;
        _ -> false
    end.

self_witnessed(none, Self) ->
    not (is_binary(Self) andalso byte_size(Self) =:= 32);
self_witnessed(<<_:256>> = Signer, Signer) ->
    true;
self_witnessed(_Signer, _Self) ->
    false.

submit_plan_envelope(From, Plan, Material, GoalBlob, ReplyBindings, ResultBlob,
                     TraceCtx,
                     S = #s{ns = Ns, outcomes = Outcomes0,
                            parked = Parked}) ->
    Anchor = target_anchor(Ns),
    Change0 = quod_transaction:from_plan(
                Plan, Material, GoalBlob, ResultBlob),
    Change = Change0#transaction{author = S#s.self,
                                 submitted_at = quod_time:now_ms()},
    Tx = Change#transaction.tx_id,
    Diff = Change#transaction.diff,
    Ref = {transaction, Ns, Anchor, Tx},
    admit_bound_plan(From, Change, ReplyBindings, Diff, TraceCtx,
                     Ref, Outcomes0, Parked, S).

admit_bound_plan(From, Change, ReplyBindings, Diff, TraceCtx, Ref,
                 Outcomes0, Parked, S) ->
    Tx = Change#transaction.tx_id,
    case quod_outcome:admit(Outcomes0, Change) of
        {{terminal, Stored}, Outcomes1} ->
            {reply, terminal_submission_reply(Stored, ReplyBindings),
             S#s{outcomes = Outcomes1}};
        {pending, Outcomes1} when is_map_key(Tx, Parked) ->
            {reply, {error, {outcome_unknown, Ref}},
             S#s{outcomes = Outcomes1}};
        {pending, Outcomes1} ->
            submit_new_plan(
              From, Change, ReplyBindings, Diff,
              TraceCtx, S#s{outcomes = Outcomes1});
        {new, Outcomes1} ->
            submit_new_plan(
              From, Change, ReplyBindings, Diff,
              TraceCtx, S#s{outcomes = Outcomes1});
        {error, Reason} ->
            outcome_index_error(Reason, Ref, S)
    end.

terminal_submission_reply(
  Stored, ReplyBindings) ->
    case terminal_result(Stored) of
        {committed, Slot, Tx} -> {ok, ReplyBindings, Slot, Tx};
        {rejected, Reason} -> {error, Reason};
        error -> {error, outcome_index_corrupt}
    end.

terminal_result(#{status := {committed, Slot}, tx_id := <<_:256>> = Tx})
  when is_integer(Slot), Slot > 0 ->
    {committed, Slot, Tx};
terminal_result(#{status := {rejected, Reason, Slot}})
  when is_atom(Reason), is_integer(Slot), Slot > 0 ->
    {rejected, Reason};
terminal_result(_Stored) ->
    error.

-ifdef(TEST).
test_terminal_result(Stored) -> terminal_result(Stored).
-endif.

submit_new_plan(From, Change, ReplyBindings, Diff, TraceCtx,
                S = #s{ns = Ns}) ->
    Tx = Change#transaction.tx_id,
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
                       {From, ReplyBindings, S#s.applied, TRef, ReqId,
                        SpanCtx, T0}},
                     requests = Requests1},
            {noreply, S1}
    catch
        error:badarg ->
            quod_trace:finish_span(SpanCtx, {error, consensus_unavailable}),
            {reply, {error, consensus_unavailable},
             discard_unsubmitted(Tx, S)}
    end.

%% The outer wire decoder has only bounded the three opaque blobs. Decode the
%% plan after scope authentication because its proof/origin identity is needed
%% for this command; accept_plan_submission/6 remains the shared local/remote
%% trust boundary that canonical-decodes goal and result before consensus.
decode_submit_plan(PlanBlob) ->
    quod_scope_wire:decode_plan_payload(PlanBlob).

%% Terminal for one wire submission: fold the internal parked outcome into the
%% closed `plan_submitted` vocabulary and emit it on the scope's return path.
finish_remote_submit({remote_submit, Binding, RequestId, CommandSeq},
                     Reply, S) ->
    S1 = update_remote_scope(
           Binding,
           fun(Scope) -> Scope#remote_scope{state = submitted} end, S),
    emit_scope_event(
      Binding, RequestId, CommandSeq,
      {plan_submitted, submit_outcome(Reply)}, S1).

submit_outcome({ok, _Bindings, Index, TxId}) -> {committed, Index, TxId};
submit_outcome({error, conflict_retry}) -> {rejected, conflict_retry};
submit_outcome({error, policy_self_seal_forbidden}) ->
    {rejected, policy_self_seal_forbidden};
submit_outcome({error, retry}) -> {rejected, retry};
submit_outcome({error, busy}) -> {rejected, retry};
submit_outcome({error, {ontology_rebuilding, _Ns}}) -> {rejected, retry};
submit_outcome({error, {not_leader, _Hint}}) -> {rejected, retry};
submit_outcome({error, {outcome_unknown, Ref}}) -> {outcome_unknown, Ref};
submit_outcome({error, consensus_unavailable}) ->
    {rejected, consensus_unavailable};
submit_outcome({error, _Reason}) -> {rejected, bad_plan}.

-ifdef(TEST).
test_submit_outcome(Reply) -> submit_outcome(Reply).
-endif.

%% Reply to whoever parked a submission: a gen_server caller directly, or an
%% authenticated remote origin through its scope's return path. The release
%% funs run inside this engine, so the wire form re-enters through the
%% mailbox and is emitted with the engine's own scope state.
reply_parked({remote_submit, _Binding, _RequestId, _CommandSeq} = From,
             Reply) ->
    self() ! {remote_submit_reply, From, Reply},
    ok;
reply_parked(From, Reply) ->
    gen_server:reply(From, Reply).

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
    %% An unknown consensus response is not proof of exclusion. Keep the
    %% durable pending row and let the ordinary deadline return its anchored
    %% outcome reference instead of inviting an unsafe retry.
    logger:warning("unknown consensus append reply for ~p: ~0p", [Tx, Other]),
    request_completed(Tx, S).

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

%% Apply one committed entry, then — in a shared tail across every
%% applied-advancing path — resolve membership or Prepare verdicts parked for
%% the parent height just reached.  A content commit, DTX phase, or noop must
%% all release the same bounded validation lifecycle.
apply_committed(#entry{} = Entry, Origin, S) ->
    resolve_validations(apply_step(Entry, Origin, S)).

%% Each clause returns the new #s{}. Index is the committed entry's log index; entries
%% arrive in order on the (FIFO) cast channel from quod_simplex. `Origin` (live|replay) reaches
%% apply_transaction, which yields the caller completion and any live outcome
%% event. Both are delivered only after the block snapshot is durable and visible.
%%
%% Already applied (e.g. a rebuild re-drive): idempotent no-op.
apply_step(#entry{index = Index}, _Origin, S = #s{applied = A}) when Index =< A ->
    S;
%% Forward gap: quod_simplex is ahead of us (we restarted, or missed a cast). Don't apply out
%% of order — ask quod_simplex to re-drive from the snapshot so we receive a contiguous run.
apply_step(#entry{index = Index}, _Origin, S = #s{ns = Ns, applied = A}) when Index > A + 1 ->
    _ = try quod_simplex:rebuild(Ns) catch _:_ -> ok end,
    S;
%% Index == applied+1. Every committed entry kind is enumerated here. A recognized
%% kind without a deterministic apply implementation fails loudly; it is never
%% confused with `noop`, the one kind that legitimately applies no data change.
%%
%% Caller completions and outcome events are buffered through the fold and
%% delivered only after `publish_snapshot` commits the outcome index and MVCC
%% version. A successful API reply can therefore be followed immediately by a
%% terminal outcome lookup or a read of the committed state. All envelopes in
%% a block share that block-final snapshot.
apply_step(#entry{index = Index, data = Data} = Entry, Origin, S) ->
    case quod_ledger:classify(Data) of
        {content, Transactions} ->
            {S1, RevPostApply} =
                lists:foldl(
                  fun(T, {Acc, PostApply}) ->
                      {Acc1, Item} = apply_transaction(T, Index, Origin, Acc),
                      {Acc1, [Item | PostApply]}
                  end, {S, []}, Transactions),
            complete_transactions(
              lists:reverse(RevPostApply), publish_snapshot(Index, S1));
        {'begin', Control} ->
            apply_dtx_entry(Control, Entry, Origin, S);
        {prepare, Control} ->
            apply_dtx_entry(Control, Entry, Origin, S);
        {decision, Control} ->
            apply_dtx_entry(Control, Entry, Origin, S);
        {finalize, Control} ->
            apply_dtx_entry(Control, Entry, Origin, S);
        {complete, Control} ->
            apply_dtx_entry(Control, Entry, Origin, S);
        noop ->
            publish_snapshot(Index, S);
        invalid ->
            skip_unexpected(Index, Data, S)
    end.

%% Apply one certified DTX record through the same pure reducer used by
%% consensus history.  Prepare validates but does not publish its hidden plan;
%% Finalize(commit) is the only phase that changes D.  The outcome projection
%% is flushed with the ordered floor before MVCC publication, and only then is
%% Simplex allowed to reopen the proof fence.
apply_dtx_entry(Control, #entry{index = Index} = Entry, Origin,
                S0 = #s{ns = Ns, outcomes = Outcomes0}) ->
    Binding = {Ns, target_anchor(Ns)},
    true = quod_dtx:verify_control(Binding, Control),
    {ok, CertifiedRef} = quod_dtx:certified_entry_ref(
                           Binding, Entry, Control),
    GroupId = quod_dtx:group_id(Control),
    {History0, Outcomes1} = dtx_group_history(Outcomes0, GroupId),
    Projection0 = maps:get(projection, quod_outcome:dtx_state(Outcomes1)),
    {ok, History1, Projection1, Effects} =
        quod_dtx:reduce(Control, CertifiedRef, History0, Projection0),
    {S1, Event} = apply_dtx_effects(
                    Effects, Index, S0#s{outcomes = Outcomes1}),
    {ok, Outcomes2, DeferredAck} = quod_outcome:apply_dtx(
                                      S1#s.outcomes, Index, Control,
                                      History1, Projection1, Effects),
    S2 = publish_snapshot(Index, S1#s{outcomes = Outcomes2}),
    S3 = publish_dtx_outcome(Event, Index, Origin, S2),
    S4 = finish_dtx_apply(DeferredAck, Control, Origin, S3),
    maybe_release_completed_group(Control, GroupId, S4).

dtx_group_history(Outcomes, GroupId) ->
    case quod_outcome:group_history(Outcomes, GroupId) of
        {History, Outcomes1} when is_map(History) -> {History, Outcomes1};
        {error, Reason} -> outcome_index_failure(Reason)
    end.

local_dtx_group_state(GroupId, Outcomes0) ->
    Dtx = quod_outcome:dtx_state(Outcomes0),
    Generation = maps:get(generation, maps:get(projection, Dtx)),
    AppliedFloor = quod_outcome:applied_floor(Outcomes0),
    case quod_outcome:lookup_group(Outcomes0, GroupId) of
        {{ok, Row}, Outcomes1} ->
            Reply =
                {ok,
                 #{history => maps:get(history, Row),
                   applied => maps:get(applied, Row),
                   applied_floor => AppliedFloor,
                   generation => Generation}},
            {Reply, Outcomes1};
        {not_found, Outcomes1} ->
            {{ok, #{history => none, applied => none,
                    applied_floor => AppliedFloor,
                    generation => Generation}}, Outcomes1};
        {{error, Reason}, Outcomes1} ->
            {{error, Reason}, Outcomes1}
    end.

%% Complete is already present in the flushed outcome projection here.  Resolve
%% the origin caller directly in this ordered apply turn; the external
%% notification seam is reserved for resolution edges Prolog cannot observe.
maybe_release_completed_group(Control, GroupId, S) ->
    case quod_dtx:control_kind(Control) of
        complete -> release_group_waiter_by_id(GroupId, S);
        _ -> S
    end.

release_group_waiter_by_id(GroupId, S = #s{group_waiters = Waiters}) ->
    case maps:get(GroupId, Waiters, undefined) of
        #group_waiter{group_ref = GroupRef} ->
            release_group_waiter(GroupRef, S);
        undefined ->
            S
    end.

release_group_waiter(
  {group, _Ns, _Anchor, _Coordinator, _Admission, <<_:256>> = GroupId}
    = GroupRef,
  S = #s{group_waiters = Waiters, outcomes = Outcomes0}) ->
    case maps:get(GroupId, Waiters, undefined) of
        #group_waiter{group_ref = GroupRef} = Waiter ->
            case quod_outcome:lookup_ref(Outcomes0, GroupRef) of
                {{ok, Stored}, Outcomes1} ->
                    case quod_outcome:public(Stored) of
                        {ok, #{status := committed,
                               height := Height,
                               bindings := Bindings,
                               participant_slots := Slots}} ->
                            finish_group_waiter(
                              GroupId, Waiter,
                              {ok, [Bindings],
                               #{ref => GroupRef, height => Height,
                                 participant_slots => Slots}},
                              S#s{outcomes = Outcomes1});
                        {ok, #{status := aborted, reasons := Reasons}} ->
                            finish_group_waiter(
                              GroupId, Waiter, {fail, Reasons},
                              S#s{outcomes = Outcomes1});
                        {ok, #{status := pending}} ->
                            S#s{outcomes = Outcomes1};
                        {error, Reason} ->
                            error({outcome_index_unavailable, Reason})
                    end;
                {not_found, Outcomes1} ->
                    resolve_absent_group_waiter(
                      GroupId, GroupRef, Waiter,
                      S#s{outcomes = Outcomes1});
                {wrong_anchor, _Outcomes1} ->
                    error({outcome_index_unavailable, wrong_anchor});
                {{error, Reason}, _Outcomes1} ->
                    error({outcome_index_unavailable, Reason})
            end;
        _ ->
            S
    end;
release_group_waiter(_BadRef, S) ->
    S.

resolve_absent_group_waiter(
  GroupId, GroupRef, Waiter,
  S = #s{ns = Ns, applied = AppliedFloor}) ->
    case quod_simplex:dtx_group_barrier(Ns, GroupRef, AppliedFloor) of
        {ok, pending} ->
            S;
        {ok, not_found} ->
            finish_group_waiter(
              GroupId, Waiter, {error, not_found}, S);
        {ok, {rejected, coordinator_retired}} ->
            finish_group_waiter(
              GroupId, Waiter, {error, coordinator_retired}, S);
        {error, _UnavailableOrUnknown} ->
            S
    end.

finish_group_waiter(
  GroupId,
  #group_waiter{from = From, caller_mref = CallerMRef, timer = Timer},
  Result, S = #s{group_waiters = Waiters}) ->
    _ = erlang:cancel_timer(Timer),
    demonitor(CallerMRef, [flush]),
    reply_client(From, Result),
    S#s{group_waiters = maps:remove(GroupId, Waiters)}.

-ifdef(TEST).
test_release_absent_group_waiter(
  Ns,
  {group, Ns, _Anchor, _Coordinator, _Admission, <<_:256>> = GroupId}
    = GroupRef,
  Outcomes) ->
    CallRef = make_ref(),
    CallerMRef = erlang:monitor(process, self()),
    Timer = erlang:send_after(60000, self(),
                              {group_wait_timeout, GroupId}),
    Waiter = #group_waiter{
                from = {async, self(), CallRef},
                caller_mref = CallerMRef, timer = Timer,
                group_ref = GroupRef},
    S0 = #s{ns = Ns, outcomes = Outcomes,
            applied = quod_outcome:applied_floor(Outcomes),
            group_waiters = #{GroupId => Waiter}},
    S1 = release_group_waiter(GroupRef, S0),
    {CallRef, map_size(S1#s.group_waiters)}.
-endif.

apply_dtx_effects([], _Index, S) ->
    {S, none};
apply_dtx_effects(
  [{prepared, _GroupId, _Ref, Manifest, PlanDigest, PlanBlob, _Generation}],
  Index, S) ->
    case validate_prepared_plan(Manifest, PlanDigest, PlanBlob, S) of
        ok -> {S, none};
        {error, Reason} -> error({invalid_committed_dtx_prepare, Index, Reason})
    end;
apply_dtx_effects(
  [{apply_prepared, GroupId, Manifest, PlanDigest, PlanBlob,
    _Ref, _Generation}], Index, S) ->
    case decode_prepared_material(Manifest, PlanDigest, PlanBlob, S) of
        {ok, Context, #{diff := Diff}} ->
            {ok, Est1} = quod_diff:apply_ops(S#s.est, Diff),
            {S#s{est = Est1, applies = S#s.applies + 1},
             {group_applied, GroupId, Context, Diff}};
        {error, Reason} ->
            error({invalid_committed_dtx_finalize, Index, Reason})
    end;
apply_dtx_effects(
  [{discard_prepared, _GroupId, _Manifest, _PlanDigest, _PlanBlob,
    _Ref, _Generation}], _Index, S) ->
    {S, none};
apply_dtx_effects(
  [{origin_started, _GroupId, _Ref}], _Index, S) ->
    {S, none};
apply_dtx_effects(
  [{decided, _GroupId, _Verdict, _Ref}], _Index, S) ->
    {S, none};
apply_dtx_effects(
  [{direct_applied_abort, _GroupId, _Ref, _Generation}], _Index, S) ->
    {S, none};
apply_dtx_effects(
  [{completed, _GroupId, commit, _Ref}], _Index, S) ->
    {S, none};
apply_dtx_effects(
  [{completed, _GroupId, abort, _Ref, _Reasons}], _Index, S) ->
    {S, none}.

decode_authenticated_target_plan(PlanBlob, #s{ns = Ns}) ->
    case quod_dtx:decode(PlanBlob) of
        {ok, Plan} ->
            case quod_dtx:target(Plan) =:= {Ns, target_anchor(Ns)} andalso
                 quod_dtx:verify(Plan) of
                true -> {ok, Plan};
                false -> {error, bad_plan_binding}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

decode_prepared_material(Manifest, PlanDigest, PlanBlob, S) ->
    case decode_prepared_plan(Manifest, PlanDigest, PlanBlob, S) of
        {ok, Plan, Context} ->
            case quod_dtx:material(Plan) of
                {ok, Material} -> {ok, Context, Material};
                {error, Reason} -> {error, Reason}
            end;
        {error, _} = Error ->
            Error
    end.

decode_prepared_plan(Manifest, PlanDigest, PlanBlob, S) ->
    case decode_authenticated_target_plan(PlanBlob, S) of
        {ok, Plan} ->
            case {quod_dtx:digest(Plan) =:= PlanDigest,
                  quod_dtx:event_context(Manifest, Plan)} of
                {true, {ok, Context}} -> {ok, Plan, Context};
                _ -> {error, bad_manifest_binding}
            end;
        {error, _} = Error ->
            Error
    end.

validate_prepared_plan(Manifest, PlanDigest, PlanBlob,
                       S = #s{applied = Parent, est = Est}) ->
    %% Authenticate the outer plan and its current target author before the
    %% owner materializer is allowed to allocate any ontology symbols.
    case decode_prepared_plan(Manifest, PlanDigest, PlanBlob, S) of
        {ok, Plan, _Context} ->
            validate_prepared_plan_header(Plan, Parent, Est, S);
        {error, Reason} ->
            {error, Reason}
    end.

validate_prepared_plan_header(Plan, Parent, Est, S) ->
    case prepared_signer_admitted(quod_dtx:signer(Plan), S) of
        false ->
            {error, signer_not_admitted};
        true ->
            case {quod_dtx:participates(Plan),
                  quod_dtx:base_height(Plan) =< Parent} of
                {false, _} -> {error, not_material};
                {_, false} -> {error, future_base_height};
                {true, true} -> validate_prepared_plan_material(Plan, Est, S)
            end
    end.

validate_prepared_plan_material(Plan, Est, S) ->
    case quod_dtx:material(Plan) of
        {ok, #{diff := Diff, read_check := ReadCheck,
               transcript := Transcript}} ->
            validate_prepared_material(
              Plan, Diff, ReadCheck, Transcript, Est, S);
        {error, Reason} ->
            {error, Reason}
    end.

validate_prepared_material(Plan, Diff, ReadCheck, Transcript, Est, S) ->
    case quod_diff:valid_ops(Diff) andalso
         quod_diff:valid_read_check(ReadCheck) of
        false ->
            {error, malformed_plan_material};
        true ->
            validate_prepared_occ(
              Plan, Diff, ReadCheck, Transcript, Est, S)
    end.

validate_prepared_occ(Plan, Diff, ReadCheck, Transcript, Est, S) ->
    case quod_diff:validate(ReadCheck, mvcc_ref(Est)) of
        {conflict, _Functor} ->
            {error, conflict_retry};
        ok ->
            case validate_prepared_membership(Diff, S) of
                {error, _} = Error -> Error;
                ok ->
                    validate_prepared_candidate(
                      Plan, Diff, Transcript, Est, S)
            end
    end.

validate_prepared_candidate(Plan, Diff, Transcript, Est, S) ->
    case quod_diff:apply_ops_preserving_policy(Est, Diff) of
        {error, _} = Error ->
            Error;
        {ok, _DiscardedCandidate} ->
            validate_plan_transcript(Plan, Transcript, S)
    end.

mvcc_ref(#est{db = #db{mod = quod_erlog_db_mvcc, ref = Ref}}) -> Ref.

prepared_signer_admitted(
  none, #s{signer = none, ns = Ns}) ->
    target_anchor(Ns) =:= <<0:256>>;
prepared_signer_admitted(
  <<_:256>> = Signer, #s{est = Est}) ->
    lists:member(Signer, quod_committee_predicates:admitted_pubkeys(Est));
prepared_signer_admitted(_Signer, _S) ->
    false.

validate_plan_transcript(
  Plan, Transcript, #s{applied = ParentHeight, est = ParentEst}) ->
    quod_ask:validate_authorization_transcript(
      quod_dtx:target(Plan), quod_dtx:origin(Plan),
      quod_dtx:principal(Plan), ParentHeight, Transcript, ParentEst).

validate_prepared_membership(Diff, S) ->
    case diff_touches_membership(Diff) of
        false -> ok;
        true ->
            Validators = quod_committee_predicates:admitted_pubkeys(S#s.est),
            case quod_simplex:membership_diff_acceptable(Diff, Validators)
                 andalso exact_membership_parent(Diff, S#s.est) of
                true -> ok;
                false -> {error, invalid_membership}
            end
    end.

exact_membership_parent(
  [{assert, {{peer_admitted, _Id, _Host, _Port, Pubkey}, _Body}}], Est) ->
    not lists:member(
          Pubkey, quod_committee_predicates:admitted_pubkeys(Est));
exact_membership_parent(
  [{retract, {Head, Body}}],
  #est{db = #db{mod = Mod, ref = Ref}}) ->
    quod_diff:has_clause(Mod, Ref, Head, Body);
exact_membership_parent(_Diff, _Est) ->
    false.

diff_touches_membership(Diff) ->
    lists:any(
      fun({_Kind, {{peer_admitted, _, _, _, _}, _Body}}) -> true;
         (_) -> false
      end, Diff).

finish_dtx_apply(none, _Control, _Origin, S) ->
    S;
finish_dtx_apply(
  {finalize_applied, GroupId, Slot, Generation}, _Control, _Origin,
  S = #s{ns = Ns}) ->
    ok = quod_simplex:finalize_applied(Ns, GroupId, Slot, Generation),
    S.

apply_transaction(#transaction{plan_digest = none} = Change,
                  Index, Origin, S) ->
    apply_new_transaction(Change, Index, Origin, new, S);
apply_transaction(#transaction{} = Change, Index, Origin,
                  S = #s{outcomes = Outcomes0}) ->
    case quod_outcome:classify(Outcomes0, Change) of
        {new, Candidate, Outcomes1} ->
            apply_new_transaction(
              Change, Index, Origin, {new, Candidate},
              S#s{outcomes = Outcomes1});
        {pending, Candidate, Outcomes1} ->
            apply_new_transaction(
              Change, Index, Origin, {pending, Candidate},
              S#s{outcomes = Outcomes1});
        {terminal, Stored, Outcomes1} ->
            apply_known_transaction(
              Change, Index, Origin, Stored,
              S#s{outcomes = Outcomes1});
        {error, Reason} ->
            outcome_index_failure(Reason)
    end.

%% The outcome index survives an engine restart; the MVCC projection does not.
%% Re-apply the transaction at its recorded terminal slot to rebuild that fresh
%% projection, but skip any later duplicate occurrence of the same semantic tx.
apply_known_transaction(Change, Index, Origin,
                        #{status := Status} = Stored, S) ->
    case terminal_slot(Status) of
        Index ->
            apply_new_transaction(
              Change, Index, Origin, {terminal, Stored}, S);
        Slot when Slot < Index -> apply_duplicate_transaction(Change, Stored, S);
        _FutureSlot -> error({outcome_index_conflict, terminal_slot_order})
    end.

terminal_slot({committed, Slot}) -> Slot;
terminal_slot({rejected, _Reason, Slot}) -> Slot;
terminal_slot(_Status) -> error({outcome_index_conflict, bad_status}).

apply_new_transaction(#transaction{tx_id = Tx, diff = Diff} = Change,
                      Index, Origin, Prior, S) ->
    %% A committee-changing transaction applies UNCONDITIONALLY — skip the OCC read-check. It was
    %% re-validated against the parent state before the vote (`membership_verdict/2`), so OCC is
    %% redundant here AND is the source of a real divergence: the Simplex
    %% history projection folds the
    %% validator set unconditionally at commit, so an OCC-skipped membership diff would leave the KB fact
    %% behind the validator set. Applying it here keeps the two projections in lockstep. (On a single
    %% `peer_admitted` op — Slice A guarantees exactly one — apply is idempotent: an already-present
    %% assert dedups, an absent retract is a no-op.) Content txs keep OCC.
    case is_membership_change(Change) of
        true ->
            {ok, Est1} = quod_diff:apply_ops(S#s.est, Diff),
            S0 = record_terminal(Change, Index, committed, Prior,
                                 S#s{est = Est1,
                                     applies = S#s.applies + 1}),
            {S0, {outcome_applied(Change, Index, Origin, S0),
                  {committed, Tx, Index}}};
        false ->
            apply_content(Change, Index, Origin, Prior, S)
    end.

apply_duplicate_transaction(#transaction{tx_id = Tx}, Stored, S) ->
    case terminal_result(Stored) of
        {committed, Slot, Tx} ->
            {S, {none, {committed, Tx, Slot}}};
        {rejected, Reason} ->
            {S, {none, {rejected, Tx, Reason}}};
        _ ->
            error(outcome_index_corrupt)
    end.

skip_unexpected(Index, Other, S = #s{ns = Ns}) ->
    logger:warning("quod_prolog[~s]: skipping unexpected committed payload at ~p: ~0p", [Ns, Index, Other]),
    publish_snapshot(Index, S).

publish_snapshot(Index, S = #s{est = #est{db = #db{mod = quod_erlog_db_mvcc,
                                                     ref = Ref0} = Db} = Est,
                                outcomes = Outcomes0}) ->
    %% Every ledger entry advances the outcome projection's ordered floor,
    %% including content and noops. DTX terminal visibility therefore cannot
    %% jump across an unrecorded ordinary prefix. All rows accumulated by this
    %% block and that floor become one DETS insert; on failure the process stops
    %% before publishing the MVCC height and replay rebuilds both projections.
    OutcomesStaged = require_outcome_index(
                       quod_outcome:advance_applied(Outcomes0, Index)),
    Outcomes1 = require_outcome_index(quod_outcome:flush(OutcomesStaged)),
    Floor = oldest_snapshot(Index, S),
    Ref1 = quod_erlog_db_mvcc:commit(Ref0, Index, Floor),
    S#s{est = Est#est{db = Db#db{ref = Ref1}},
        outcomes = Outcomes1, applied = Index}.

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

%% A normal content transaction: OCC re-check the read-set, build the candidate
%% state, then enforce invariants before publishing it.
apply_content(#transaction{tx_id = Tx, diff = Diff, read_check = RC} = Change,
              Index, Origin, Prior, S) ->
    #est{db = #db{mod = quod_erlog_db_mvcc, ref = R}} = S#s.est,
    case quod_diff:validate(RC, R) of
        ok ->
            case quod_diff:apply_ops_preserving_policy(S#s.est, Diff) of
                {ok, Est1} ->
                    S0 = record_terminal(Change, Index, committed, Prior,
                                         S#s{est = Est1,
                                             applies = S#s.applies + 1}),
                    {S0, {outcome_applied(Change, Index, Origin, S0),
                          {committed, Tx, Index}}};
                {error, policy_self_seal_forbidden} ->
                    reject_content(Change, Index, Origin, Prior,
                                   policy_self_seal_forbidden, S)
            end;
        {conflict, _F} ->
            reject_content(Change, Index, Origin, Prior, conflict_retry,
                           S#s{conflicts = S#s.conflicts + 1})
    end.

%% A deterministic apply-time rejection leaves D unchanged but still records
%% the exact typed reason for the submitting proof (including a foreign caller)
%% and the durable outcome index. Replay is silent at the event layer only.
reject_content(#transaction{tx_id = Tx} = Change, Index, Origin, Prior,
               Reason, S) ->
    S0 = record_terminal(Change, Index, {rejected, Reason}, Prior,
                         S#s{rejects = S#s.rejects + 1}),
    {S0, {outcome_rejected(Change, Index, Origin, S0),
          {rejected, Tx, Reason, Index}}}.

record_terminal(#transaction{plan_digest = none}, _Index, _Verdict, _Prior, S) ->
    S;
record_terminal(_Change, Index, Verdict, Prior,
                S = #s{outcomes = Outcomes0}) ->
    case quod_outcome:terminal(
           Outcomes0, Index, Verdict, Prior) of
        {_NewOrDuplicate, _Stored, Outcomes1} ->
            S#s{outcomes = Outcomes1};
        {error, Reason} ->
            outcome_index_failure(Reason)
    end.

%% A committee-changing tx = its diff asserts/retracts `peer_admitted` (a PURE fold in quod_simplex —
%% no process message, so no append<->apply deadlock).
is_membership_change(Change) -> quod_simplex:committee_delta(Change) =/= {[], []}.

%%%===================================================================
%%% post-apply event layer (doc/agent-fipa-plan.md §7)
%%%===================================================================
%%
%% The `{runtime, Ns}` property carries these messages for the explorer (`m:quod_explorer_ws`) and any
%% observer: `{applied_live, Env}` (one per live-applied material transaction, including an
%% effect-only transaction with an empty D diff), `{rejected_live,
%% Env}` (one per live transaction that committed but was OCC-rejected at apply), and the
%% `{replay_started, Id, From}` / `{replay_ready, Id, Height}` boundaries of a replay run (`Id` is
%% `boot` for the quiet-boot ready edge). The ATTACHED runtime (`attach_runtime/1`) additionally
%% receives each applied envelope as a direct `{applied_live, Env, Est}` carrying the post-commit
%% snapshot handle — see publish_outcome/2 for why the handle is never broadcast. The pre-apply
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

%% One event per ordinary material committed transaction on a LIVE commit only
%% — never replay. The runtime consumes the concrete diff, validated direct
%% effects, and identifiers; goal/result remain canonical ledger blobs and are
%% decoded lazily only by a detail reader. Genesis is not an agent event.
outcome_applied(#transaction{plan_digest = none}, _Index, _Origin, _S) -> none;
outcome_applied(#transaction{tx_id = Tx, diff = Diff, effects = Effects},
                Index, live, #s{ns = Ns}) ->
    {applied, #{ns => Ns, height => Index, tx_id => Tx, subject => undefined,
                diff => Diff, effects => Effects}};
outcome_applied(_Change, _Index, replay, _S) -> none.

%% One event per committed-but-OCC-rejected transaction, on a LIVE commit only. Mirrors
%% `outcome_applied` so every live tx in a block yields exactly one outcome event (applied or
%% rejected); D is unchanged, so the envelope carries no diff/result.
outcome_rejected(#transaction{tx_id = Tx, effects = Effects},
                 Index, live, #s{ns = Ns}) ->
    {rejected, #{ns => Ns, height => Index, tx_id => Tx,
                 subject => undefined, effects => Effects}};
outcome_rejected(_Change, _Index, replay, _S) -> none.

%% Complete each transaction in block order after the block snapshot is
%% published. The caller is released first; event consumers then see the same
%% already-committed state.
complete_transactions([], S) -> S;
complete_transactions([{Event, Completion} | Rest], S0) ->
    S1 = complete_transaction(Completion, S0),
    complete_transactions(Rest, publish_outcome(Event, S1)).

complete_transaction({committed, Tx, Slot}, S) ->
    release(Tx, {ok, {applied, Slot}},
            fun(From, Bindings, _ReadHeight) ->
                reply_parked(From, {ok, Bindings, Slot, Tx})
            end, S);
complete_transaction({rejected, Tx, Reason, Slot}, S) ->
    release(Tx, {error, {Reason, Slot}},
            fun(From, _Bindings, _ReadHeight) ->
                reply_parked(From, {error, Reason})
            end, S);
complete_transaction({rejected, Tx, Reason}, S) ->
    release(Tx, {error, Reason},
            fun(From, _Bindings, _ReadHeight) ->
                reply_parked(From, {error, Reason})
            end, S).

%% The `{runtime, Ns}` property carries state-free envelopes. The committed
%% snapshot handle rides only the direct send to the pinned runtime; exposing
%% it to unpinned subscribers would let reads race MVCC history pruning.
publish_outcome(none, S) -> S;
publish_outcome({applied, Env}, S = #s{ns = Ns, est = Est, runtime_pin = Pin}) ->
    publish_runtime(Ns, {applied_live, Env}),
    _ = case Pin of
            {Pid, _MRef, _F} -> Pid ! {applied_live, Env, Est};
            none             -> ok
        end,
    S;
publish_outcome({rejected, Env}, S = #s{ns = Ns}) ->
    publish_runtime(Ns, {rejected_live, Env}),
    _ = case maps:get(effects, Env, []) of
            [] -> ok;
            Effects ->
                quod_effect_journal:retire(Effects, conflict_retry)
        end,
    S.

%% A distributed commit publishes exactly the same post-snapshot runtime
%% signal as an ordinary write, with the durable GroupId as its identity.
%% Replay, aborts, duplicate controls, and empty participant diffs are silent;
%% the runtime reconciles replay from the committed snapshot boundary.
publish_dtx_outcome(none, _Index, _Origin, S) ->
    S;
publish_dtx_outcome(
  {group_applied, _GroupId, _Context, []}, _Index, _Origin, S) ->
    S;
publish_dtx_outcome(
  {group_applied, GroupId,
   #{proof_id := ProofId, origin := ProofOrigin,
     principal := Principal, goal := Goal, result := Result,
     plan_digest := PlanDigest}, Diff},
  Index, live, S = #s{ns = Ns}) ->
    Env = #{ns => Ns, height => Index, tx_id => {group, GroupId},
            proof_id => ProofId, origin => ProofOrigin,
            subject => Principal, goal => Goal, result => Result,
            plan_digest => PlanDigest, diff => Diff},
    publish_outcome({applied, Env}, S);
publish_dtx_outcome({group_applied, _, _, _}, _Index, replay, S) ->
    S.

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
            S#s{parked = P1,
                requests = abandon_request(ReqId, S#s.requests)};
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
            fun(From, _Bindings, _Height) -> reply_parked(From, Reply) end,
            discard_unsubmitted(Tx, S)).

discard_unsubmitted(Tx, S = #s{outcomes = Outcomes0}) ->
    S#s{outcomes = require_outcome_index(
                       quod_outcome:discard_unsubmitted(Outcomes0, Tx))}.

require_outcome_index({ok, Outcomes}) -> Outcomes;
require_outcome_index({error, Reason}) -> outcome_index_failure(Reason).

-spec outcome_index_failure(term()) -> no_return().
outcome_index_failure({outcome_index_io, _} = Reason) ->
    error({outcome_index_unavailable, Reason});
outcome_index_failure(Reason) ->
    error({outcome_index_conflict, Reason}).

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

%% A re-issued Tag (a re-proposed slot after a view change) supersedes any
%% request still parked under it.  This one mechanism serves every
%% parent-state consensus verdict; adding a DTX phase does not add another
%% timer/map lifecycle.
request_validation(Request, Slot, ReplyTo, Tag, S0) ->
    do_request_validation(
      Request, Slot, ReplyTo, Tag, supersede_validation(Tag, S0)).

%% Judge at height `Slot-1`: answer now if the exact parent state is published,
%% park while the KB (or, for DTX, its durable outcome floor) is behind, and
%% abstain if the slot has already resolved without us.
do_request_validation(Request, Slot, ReplyTo, Tag,
                      S = #s{validations = V, vttl = Vttl}) ->
    case validation_position(Request, Slot - 1, S) of
        ready ->
            {Verdict, S1} = validation_verdict(Request, S),
            deliver_validation(Request, ReplyTo, Tag, Verdict, S1),
            S1;
        wait ->
            TRef = erlang:send_after(Vttl, self(), {validation_timeout, Tag}),
            S#s{validations = V#{Tag => {Slot, Request, ReplyTo, TRef}}};
        stale ->
            deliver_validation(Request, ReplyTo, Tag, abstain, S),
            S
    end.

validation_position({dtx, _Control}, Parent,
                    #s{applied = Parent, outcomes = Outcomes}) ->
    case quod_outcome:applied_floor(Outcomes) >= Parent of
        true -> ready;
        false -> wait
    end;
validation_position(_Request, Parent, #s{applied = Parent}) ->
    ready;
validation_position(_Request, Parent, #s{applied = Applied})
  when Applied < Parent ->
    wait;
validation_position(_Request, _Parent, _S) ->
    stale.

supersede_validation(Tag, S = #s{validations = V}) ->
    case maps:take(Tag, V) of
        {{_Slot, _Request, _ReplyTo, OldTRef}, V1} ->
            _ = erlang:cancel_timer(OldTRef),
            S#s{validations = V1};
        error ->
            S
    end.

%% Reconsider every parked verdict after an apply.  `validation_position/3` is
%% the single readiness rule: DTX additionally waits for the outcome index's
%% durably-published floor, so reaching the KB height alone must not release it.
resolve_validations(S = #s{validations = V}) ->
    lists:foldl(
      fun({Tag, {Slot, Request, ReplyTo, TRef}}, Acc) ->
              case validation_position(Request, Slot - 1, Acc) of
                  ready ->
                      _ = erlang:cancel_timer(TRef),
                      {Verdict, Acc1} = validation_verdict(Request, Acc),
                      deliver_validation(
                        Request, ReplyTo, Tag, Verdict, Acc1),
                      Acc1#s{
                        validations = maps:remove(
                                        Tag, Acc1#s.validations)};
                  wait ->
                      Acc;
                  stale ->
                      _ = erlang:cancel_timer(TRef),
                      deliver_validation(
                        Request, ReplyTo, Tag, abstain, Acc),
                      Acc#s{
                        validations = maps:remove(Tag, Acc#s.validations)}
              end
      end, S, maps:to_list(V)).

-ifdef(TEST).
test_resolve_validation(Request, Slot, Applied, Outcomes) ->
    Tag = make_ref(),
    S1 = resolve_validations(
           #s{applied = Applied, outcomes = Outcomes,
              validations =
                #{Tag => {Slot, Request, self(), make_ref()}}}),
    maps:is_key(Tag, S1#s.validations).
-endif.

validation_verdict({membership, Change}, S) ->
    {membership_verdict(Change, S), S};
validation_verdict({dtx, Control}, S) ->
    dtx_validation_verdict(Control, S).

dtx_validation_verdict(Control, S = #s{outcomes = Outcomes0}) ->
    case safe_dtx_group_id(Control) of
        {ok, GroupId} ->
        case quod_outcome:group_history(Outcomes0, GroupId) of
            {History, Outcomes1} when is_map(History) ->
                S1 = S#s{outcomes = Outcomes1},
                {dtx_policy_verdict(Control, History, S1), S1};
            {error, Reason} ->
                outcome_index_failure(Reason)
        end;
        error ->
            {{invalid, malformed_control}, S}
    end.

safe_dtx_group_id(Control) ->
    try quod_dtx:group_id(Control) of
        <<_:256>> = GroupId -> {ok, GroupId};
        _ -> error
    catch
        error:function_clause -> error;
        error:{badmatch, _} -> error
    end.

dtx_policy_verdict(Control, History, S) ->
    case quod_dtx:control_kind(Control) of
        prepare ->
            case quod_dtx:prepare_payload(Control) of
                {ok, Manifest, PlanDigest, PlanBlob} ->
                    case validate_prepared_plan(
                           Manifest, PlanDigest, PlanBlob, S) of
                        ok -> {valid, History};
                        %% Keep deterministic Prepare failures as a real
                        %% reason stack.  Simplex adds the target marker before
                        %% the bounded wire encoding; the coordinator can then
                        %% preserve the complete stack in Decision(abort).
                        {error, Reason} -> {invalid, [Reason]}
                    end;
                error ->
                    {invalid, malformed_control}
            end;
        'begin' -> {valid, History};
        decision -> {valid, History};
        finalize -> {valid, History};
        complete -> {valid, History}
    end.

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
membership_verdict(#transaction{diff = Diff}, S) ->
    membership_diff_verdict(Diff, S);
membership_verdict(_Change, _S) ->
    {invalid, malformed}.

membership_diff_verdict(
  [{assert, {{peer_admitted, Pk, H, P, Pk}, _B}}],
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
membership_diff_verdict(
  [{retract, {{peer_admitted, _Id, _H, _P, _Pk}, _B} = Clause}],
  #s{est = #est{db = #db{mod = M, ref = R}}}) ->
    {ClauseHead, ClauseBody} = Clause,
    case quod_diff:has_clause(M, R, ClauseHead, ClauseBody) of
        true  -> valid;
        false -> {invalid, no_such_member}
    end;
membership_diff_verdict(_Diff, _S) ->
    {invalid, malformed}.   %% Slice A's gate makes this unreachable in production; kept total for tests/robustness

%% Async delivery to the requesting statem (or a test pid) — a plain message so
%% the statem consumes it as an `info` event and a test can receive it directly.
deliver_validation({membership, _Change}, ReplyTo, Tag, Verdict, _S) ->
    ReplyTo ! {membership_verdict, Tag, Verdict},
    ok;
deliver_validation({dtx, _Control}, ReplyTo, Tag, Verdict,
                   #s{outcomes = Outcomes}) ->
    ReplyTo ! {dtx_verdict, Tag, self(),
               quod_outcome:applied_floor(Outcomes), Verdict},
    ok.

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
    %% Admit diagnostics against the exact atom-safe representation used by
    %% ontology scope replies and durable abort Decisions. Anything retained
    %% here is therefore guaranteed to cross either boundary unchanged; an
    %% excess is represented at creation by fail_reasons_truncated.
    EstReasonBounded = erlog_int:set_failure_reason_policy(
                         {quod_wire_term, valid_failure_reason_stack}, Est0),
    %% unknown predicate => fail (not error): a goal over an undefined predicate just
    %% has no solution, rather than crashing.
    {succeed, Est1} = erlog_int:prove_goal(
                        {set_prolog_flag, unknown, fail}, EstReasonBounded),
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
