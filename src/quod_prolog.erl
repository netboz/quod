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
  hidden diff before the certified decision and ordered apply. A participating
  source applies through Begin/Decision; remote participants use Prepare/Finalize.
  The caller is parked until the ordinary apply or the group reaches its certified
  pre-Complete terminal boundary. Complete remains mandatory recovery bookkeeping
  and may finish asynchronously. If the local wait expires first, the caller receives
  the corresponding anchored
  `outcome_unknown` reference and resolves that reference instead of re-proving.
- **Lifecycle actions** are ordinary writable Prolog goals. The normal
  `can_invoke/4` gate and shared `action/3` relation prove policy and desired
  state; a governed staging continuation may then add one typed direct effect
  to the same rollback-safe plan. The existing effect journal executes it only
  after ordered apply.
- **`apply_entry/3`** is the deterministic ordered state machine driven by
  `quod_simplex`. Content transactions re-check their read set (OCC) before apply;
  source Begin retains its hidden plan and source Decision publishes it once;
  remote Prepare retains a hidden plan and Finalize(commit) publishes it once.
  Complete records the durable terminal group result. A **committee-changing** content
  transaction (its diff asserts/retracts `peer_admitted`) applies unconditionally
  because it was re-validated against the exact parent before voting (see
  `request_content_verdict/6`), keeping the KB and validator projection in
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

-export([start_link/2, prove/2, prove_ro/2,
         execute/2, execute_signed/3,
         open_cursor/5, cancel_cursor/3,
         submit_plan/4, submit_role/4, outcome/1,
         local_outcome/2, outcome_snapshot/2, dtx_group_state/2,
         validate_read_plan/3,
         effect_resolution/4,
         project_pending_begins/2,
         dtx_group_resolved/2, dtx_group_terminal/3,
         applied/1, apply_entry/3, mark_ready/1, sync/1,
         attach_runtime/1, runtime_floor/2, runtime_detach/1,
         request_agent_attestation/4,
         request_content_verdict/6, request_dtx_verdict/6,
         stats/1, namespaces/0]).
-export([genesis_diff/1, read_terms/1, terms_to_diff/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export([prove_est/2]).
%% Prove against a raw #est{} handle for the runtime projection.
-ifdef(TEST).
-export([open_cursor/4,
         test_active_command_stack/1,
         test_scope_capacity_available/3,
         test_public_scope_reason/2,
         test_scope_timeout_reason/2,
         test_scope_command_budget_valid/3,
         test_scope_command_route/2,
         test_read_certificate_scope_reply/2,
         test_certify_reads_pending_reason/2,
         test_sealed_submit_transition/0,
         test_target_scope_lifetime_ms/2,
         test_remote_timeout_correlation/3,
         test_scope_worker_failure/2,
         test_scope_authentication_reason/7,
         test_proof_down_reply/3, test_proof_down_reply/4,
         test_finalize_pinned_result/1,
         test_terminal_result/1,
         test_not_ready_plan_submission/1,
         test_submit_outcome/1,
         test_release_absent_group_waiter/3,
         test_resolve_validation/4,
         test_signed_origin_policy_goal/2,
         test_dtx_handoff_state/3,
         test_handle_response_info/2,
         test_cancel_dtx_handoff/2,
         test_activate_dtx_handoff/4,
         test_fill_dtx_activation_capacity/1,
         test_dtx_handoff_summary/1,
         test_active_operation/3,
         test_inflight_public_reply/1,
         test_await_public_proof/5,
         test_route_plans/3,
         test_agent_identity_reads_current/2,
         test_install_read_certificate_barrier/0,
         test_await_read_certificate_barrier/1,
         test_release_read_certificate_barrier/0]).
%% Pure verdict and scope-correlation seams driven directly by EUnit.
-endif.

%% The parent-content validation park budget: a verdict parked past the slot's Δ complaint-skip is moot, so this
%% is a short FIXED budget (default 2000 ms — on the order of the consensus Δ_timeout, `?DELTA_MS` ~1 s in
%% quod_simplex), deliberately NOT the 30 s write TTL. Reaping a stale parked verdict delivers `abstain`.
-define(DEFAULTS, #{node_id => undefined, transaction_ttl_ms => 30000,
                    validation_ttl_ms => 2000, max_proof_workers => 64,
                    max_scope_workers => 64, proof_timeout_ms => 60000,
                    scope_timeout_ms => 60000,
                    scope_step_timeout_ms => 30000,
                    outcome_backend => disk}).
-define(ROOT_NS, <<"quod:root">>).

%% One proof-owned, pre-signing Begin transfer. The original client caller
%% remains in #proof_worker.from; registration_from is the proof worker parked
%% while Simplex serializes this exact immutable intent.
-record(dtx_handoff, {
          intent_id  :: reference(),
          registration_from = none :: none | gen_server:from(),
          group_ref  :: term(),
          state = registering :: registering | dormant
         }).

-record(proof_worker, {pid         :: pid(),
                       kind        :: prove | prove_ro | cursor,
                       worker_mref :: reference(),
                       caller_mref :: reference(),
                       from        :: gen_server:from() |
                                      {async, pid(), reference()},
                       timer       :: reference(),
                       token       :: reference(),
                       deadline_ms :: integer(),
                       started_native :: integer(),
                       %% A signed operation is guarded by this worker until
                       %% its durable outcome takes over.  This is deliberately
                       %% part of the existing worker owner, not another
                       %% in-flight operation registry.
                       operation = none :: none | {term(), binary(), term()},
                       handoff = none :: none | #dtx_handoff{},
                       checkpoint = none :: none | term(),
                       height = 0  :: non_neg_integer()}).

%% After activation the proof worker may close every scope.  Only this compact
%% public waiter remains; recovery and consensus are owned by Simplex.
-record(group_waiter, {
          from        :: gen_server:from() | {async, pid(), reference()},
          caller_mref :: reference(),
          timer       :: reference(),
          group_ref   :: term(),
          started_native :: integer(),
          %% The live caller's exact solution map. The durable outcome keeps
          %% canonical binary-name pairs for replay/public resolution, but a
          %% live completion must preserve the same result shape as ordinary
          %% one-ontology submission.
          bindings    :: map()
         }).

%% One immutable description of how a public proof entered the engine. Keep
%% these attributes together so future authentication fields do not grow every
%% cast and worker function arity again.
-record(proof_request, {
          trace_ctx       :: term(),
          principal = undefined :: term(),
          expected_anchor = any :: any | <<_:256>>,
          request_evidence = none :: none | quod_client_goal:evidence(),
          started_native = undefined :: undefined | integer()
         }).

%% One engine-owned top-level run. The engine chooses the proof id, frozen
%% height, and absolute local deadline before spawning the worker; the worker
%% then owns exactly one root session and proof context for the whole run.
-record(pinned_origin, {
          engine      :: pid(),
          worker_ref  :: reference(),
          proof_id    :: <<_:256>>,
          started_native :: integer(),
          scope_id    :: <<_:128>>,
          deadline_ms :: integer(),
          kind        :: prove | prove_ro | cursor,
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

-record(parked_write, {
          waiters = [] :: [{term(), [map()]}],
          height :: log_index(),
          timer :: reference(),
          request_id = none :: term(),
          span_ctx :: quod_trace:span_ctx(),
          started :: integer()
         }).

%% One target-owned remote scope.  All wire authority is fixed at scope_open:
%% the authenticated peer, exact request link, both anchored identities, mode,
%% proof/session ids, and the return link.  Goal payloads are decoded only after
%% this record's binding and command sequence have matched.
-record(remote_scope, {
          binding      :: quod_scope_wire:binding(),
          request_binding = none :: quod_client_goal:request_binding(),
          request_auth = none :: none | quod_client_goal:request_auth(),
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

-record(agent_attester, {
          pid :: pid(),
          timer :: reference(),
          reply_to :: pid(),
          tag :: term()
         }).

%% Authentication may need a certified view of the origin ontology.  That is
%% network/disk work and must never run in this ontology owner's mailbox.
%% Keep only correlation here; the worker runs the same authentication
%% function used by co-hosted scopes and the owner rechecks admission after it
%% completes.
-record(scope_authenticator, {
          pid :: pid(),
          timer :: reference(),
          peer_key :: <<_:256>>,
          endpoint :: term(),
          request_link :: pid(),
          binding :: quod_scope_wire:binding(),
          request_id :: <<_:128>>,
          deadline_ms :: integer(),
          mode :: read_only | read_write,
          anchor :: <<_:256>>,
          origin_identity :: {binary(), <<_:256>>}
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
            %% A committed signed record can arrive while this node cannot
            %% resolve the root-network anchor. The ledger remains the sole
            %% queue: stop serving proofs, retain no entry bytes here, and ask
            %% Simplex to replay once the shared dependency is available.
            apply_dependency = none ::
                none | {network_identity, reference()},
            %% A locally unavailable genesis-pinned predicate module is an
            %% installation problem, not corrupt ledger history.  Keep the
            %% engine alive but closed until a software restart can replay the
            %% same certified genesis with the exact required BEAM available.
            projection_failure = none :: none | term(),
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
            %% One semantic transaction owns one consensus submission and may
            %% retain several exactly-correlated endpoint callers.
            parked    = #{} :: #{binary() => #parked_write{}},
            outcomes :: quod_outcome:index(),
            requests  :: term(),                 %% gen_statem async-request collection, labelled by tx_id
            %% Consensus verdicts parked until the KB reaches the proposal's
            %% parent height (Slot-1).  Membership and DTX control waves share this
            %% one height/correlation/timer mechanism; only their pure
            %% validator and reply tag differ.
            %% Tag => {Slot, {membership, Change} |
            %%                 {dtx, Controls, BlockTimestamp},
            %%         ReplyTo, TimerRef}
            validations = #{} :: map(),
            applies   = 0, rejects = 0, proves = 0, conflicts = 0,
            park_timeouts = 0 :: non_neg_integer(),     %% writes still unresolved at their caller deadline
            %% Ref => #proof_worker{}
            workers   = #{} :: map(),
            agent_attesters = #{} :: #{reference() => #agent_attester{}},
            %% A sealed writer no longer reads its frozen proof snapshot while
            %% consensus resolves the submission. Keep its caller/monitor
            %% ownership here without charging a derivation slot or pinning
            %% MVCC history.
            waiting_workers = #{} :: map(),
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
            remote_authenticators = #{} :: #{reference() => #scope_authenticator{}},
            remote_auth_bindings = #{} :: #{quod_scope_wire:binding() => reference()}}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(binary(), map()) -> {ok, pid()} | {error, term()}.
start_link(Ns, Config) ->
    gen_server:start_link(quod_reg:via({quod_prolog, Ns}), ?MODULE, {Ns, Config}, []).

-doc "Request one bounded local agent-identity attestation.".
-spec request_agent_attestation(binary(), term(), pid(), term()) -> ok.
request_agent_attestation(Ns, Request, ReplyTo, Tag)
  when is_binary(Ns), is_pid(ReplyTo) ->
    gen_server:cast(
      quod_reg:via({quod_prolog, Ns}),
      {agent_attestation, Request, ReplyTo, Tag}).

-ifdef(TEST).
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
    case quod_reg:where({quod_prolog, TargetNs}) of
        undefined -> {error, no_such_namespace};
        Engine ->
            CallRef = make_ref(),
            Request = proof_request(
                        quod_trace:context(), undefined, any, none),
            gen_server:cast(
              Engine,
              {public_cursor, Owner, CallRef, CursorId, Goal, Request}),
            {ok, Engine, CallRef}
    end;
open_cursor(_TargetNs, _Goal, _Owner, _CursorId) ->
    {error, bad_request}.
-endif.

-doc "Open the existing cursor proof under one already-verified signed request.".
-spec open_cursor(quod_client_goal:evidence(), term(),
                  {agent, binary()}, pid(), <<_:256>>) ->
          {ok, pid(), reference()} | {error, term()}.
open_cursor(
  #{request := #{agent_namespace := TargetNs,
                 agent_genesis_anchor := Anchor,
                 mode := cursor}} = Evidence,
  Goal, {agent, AgentRef} = Principal, Owner, <<_:256>> = CursorId)
  when is_binary(TargetNs), is_pid(Owner) ->
    true = is_binary(AgentRef),
    case signed_engine(TargetNs, Anchor) of
        {ok, Engine} ->
            CallRef = make_ref(),
            Request = proof_request(
                        quod_trace:context(), Principal, Anchor,
                        Evidence),
            gen_server:cast(
              Engine,
              {public_cursor, Owner, CallRef, CursorId, Goal, Request}),
            {ok, Engine, CallRef};
        {error, _} = Error -> Error
    end;
open_cursor(_Evidence, _Goal, _Principal, _Owner, _CursorId) ->
    {error, invalid_signed_goal}.

-doc "Cancel an Explorer cursor by its exact engine/call ownership.".
-spec cancel_cursor(pid(), pid(), reference()) -> ok.
cancel_cursor(Engine, Owner, CallRef)
  when is_pid(Engine), is_pid(Owner), is_reference(CallRef) ->
    gen_server:cast(Engine, {cancel_public_cursor, Owner, CallRef}),
    ok.

-doc """
Prove `Goal` against namespace `TargetNs`.

This is a trusted in-VM operator/test API, not a browser or Explorer route.

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

This is a trusted in-VM operator/test API. Browser and Explorer goals enter
through the verified signed-request functions below.

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
    case quod_reg:where({quod_prolog, TargetNs}) of
        undefined -> {error, no_such_namespace};
        Engine ->
            public_proof(
              Engine, TargetNs, execute, Goal, quod_trace:context())
    end.

-doc "Execute one already-verified signed request through the ordinary proof boundary.".
-spec execute_signed(quod_client_goal:evidence(), term(), {agent, binary()}) ->
          {ok, [map()], log_index() |
               {transaction, binary(), binary(), binary()} | map()} |
          {error, term()} | fail | {fail, [term()]}.
execute_signed(
  #{request := #{agent_namespace := TargetNs,
                 agent_genesis_anchor := Anchor,
                 mode := Mode}} = Evidence,
  Goal, {agent, AgentRef} = Principal)
  when is_binary(TargetNs),
       is_binary(AgentRef),
       (Mode =:= read orelse Mode =:= execute) ->
    case signed_engine(TargetNs, Anchor) of
        {ok, Engine} ->
            case Mode of
                read ->
                    public_proof(
                      Engine, TargetNs, prove_ro, Goal,
                      quod_trace:context(), Principal, Anchor, Evidence);
                execute ->
                    public_proof(
                      Engine, TargetNs, execute, Goal,
                      quod_trace:context(), Principal, Anchor, Evidence)
            end;
        {error, _} = Error -> Error
    end;
execute_signed(_Evidence, _Goal, _Principal) ->
    {error, invalid_signed_goal}.

signed_engine(TargetNs, <<_:256>> = Anchor) ->
    case quod_reg:where({quod_prolog, TargetNs}) of
        undefined -> {error, no_such_namespace};
        Engine ->
            case quod_simplex:genesis_hash(TargetNs) of
                Anchor -> {ok, Engine};
                _ -> {error, wrong_genesis_anchor}
            end
    end;
signed_engine(_TargetNs, _Anchor) ->
    {error, wrong_genesis_anchor}.

-doc """
Trusted in-VM read-only prove: like `prove/2` but a write goal is refused
(`{error, read_only}`). This is not a browser or Explorer route.
""".
-spec prove_ro(binary(), term()) ->
        {ok, [map()], log_index()} | {error, term()} | fail | {fail, [term()]}.
prove_ro(TargetNs, Goal) ->
    case quod_reg:where({quod_prolog, TargetNs}) of
        undefined -> {error, no_such_namespace};
        Pid -> public_proof(Pid, TargetNs, prove_ro, Goal, otel_ctx:new())
    end.

public_proof(Engine, Ns, Kind, Goal, TraceCtx) ->
    public_proof(Engine, Ns, Kind, Goal, TraceCtx, undefined).

public_proof(Engine, Ns, Kind, Goal, TraceCtx, Principal) ->
    public_proof(Engine, Ns, Kind, Goal, TraceCtx, Principal, any).

public_proof(Engine, Ns, Kind, Goal, TraceCtx, Principal, ExpectedAnchor) ->
    public_proof(
      Engine, Ns, Kind, Goal, TraceCtx, Principal, ExpectedAnchor, none).

public_proof(Engine, Ns, Kind, Goal, TraceCtx, Principal, ExpectedAnchor,
             RequestEvidence) ->
    CallRef = make_ref(),
    MRef = monitor(process, Engine),
    Request = proof_request(
                TraceCtx, Principal, ExpectedAnchor, RequestEvidence),
    gen_server:cast(
      Engine, {public_proof, self(), CallRef, Kind, Goal, Request}),
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
                             {submit_plan, Plan, GoalBlob, ResultBlob, none, [],
                              [Bindings], quod_trace:context()}, infinity)
                       catch exit:_ ->
                           {error, {outcome_unknown,
                                    quod_transaction:plan_outcome_ref(
                                      Plan, GoalBlob, ResultBlob, none)}}
                       end
            end;
        {error, _} = Error ->
            Error
    end.

-doc "Submit one canonical non-application role through ordinary target custody.".
-spec submit_role(binary(), #transaction{}, [map()], pos_integer()) ->
          {ok, [map()], log_index(), binary()} | {error, term()}.
submit_role(TargetNs, Change = #transaction{}, ReplyBindings, TimeoutMs)
  when is_binary(TargetNs), byte_size(TargetNs) > 0,
       is_list(ReplyBindings), is_integer(TimeoutMs), TimeoutMs > 0 ->
    case quod_reg:where({quod_prolog, TargetNs}) of
        undefined -> {error, {ontology_unreachable, TargetNs}};
        Pid ->
            try gen_server:call(
                  Pid,
                  {submit_role, Change, ReplyBindings,
                   quod_trace:context()}, TimeoutMs)
            catch
                exit:_ ->
                    role_submission_unknown(
                      TargetNs, Change#transaction.tx_id)
            end
    end;
submit_role(_TargetNs, _Change, _ReplyBindings, _TimeoutMs) ->
    {error, bad_transaction_role}.

role_submission_unknown(TargetNs, TxId) ->
    case quod_simplex:genesis_hash(TargetNs) of
        <<_:256>> = Anchor ->
            {error, {outcome_unknown,
                     {transaction, TargetNs, Anchor, TxId}}};
        _ ->
            {error, {ontology_unreachable, TargetNs}}
    end.

-doc "Resolve one anchored transaction or distributed-group outcome without re-proving.".
-spec outcome({transaction, binary(), binary(), binary()} |
              {group, binary(), binary(), binary(), binary(), binary()} |
              {operation, binary(), binary(), binary(), binary()}) ->
          {ok, map()} | {error, term()}.
outcome({transaction, Ns, <<_:256>>, <<_:256>>} = Ref)
  when is_binary(Ns), byte_size(Ns) > 0 ->
    public_outcome(Ns, Ref);
outcome({group, Ns, <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>} = Ref)
  when is_binary(Ns), byte_size(Ns) > 0 ->
    public_outcome(Ns, Ref);
outcome({operation, Ns, <<_:256>>, AgentRef, <<_:256>>} = Ref)
  when is_binary(Ns), byte_size(Ns) > 0 ->
    case quod_agent_ref:valid_principal({agent, AgentRef}) of
        true -> public_outcome(Ns, Ref);
        false -> {error, bad_outcome_ref}
    end;
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
  {transaction, _Ns, <<_:256>>, <<_:256>>} = Ref,
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

-doc "Validate a sealed read-only plan against this ontology's committed head.".
-spec validate_read_plan(binary(), quod_dtx:plan(), pos_integer()) ->
          {ok, non_neg_integer()} | {error, term()}.
validate_read_plan(Ns, Plan, TimeoutMs)
  when is_binary(Ns), byte_size(Ns) > 0,
       is_integer(TimeoutMs), TimeoutMs > 0 ->
    %% The endpoint worker owns this deadline. Passing its remaining time
    %% prevents a queued engine call from outliving the authenticated request.
    try gen_server:call(
          quod_reg:via({quod_prolog, Ns}),
          {validate_read_plan, Plan}, TimeoutMs)
    catch exit:_ -> {error, not_ready}
    end;
validate_read_plan(_Ns, _Plan, _TimeoutMs) ->
    {error, invalid_request}.

-doc "Resolve one target-local group-effect binding from applied projections.".
-spec effect_resolution(
        {binary(), <<_:256>>},
        {group, binary(), <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>},
        <<_:256>>, <<_:256>>) ->
          {ok, pending | {released, pos_integer()} | {retired, term()}} |
          {error, term()}.
effect_resolution(
  {TargetNs, <<_:256>> = TargetAnchor},
  {group, OriginNs, <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>> = GroupId}
    = GroupRef,
  <<_:256>> = PlanDigest, <<_:256>> = ManifestDigest)
  when is_binary(TargetNs), byte_size(TargetNs) > 0,
       is_binary(OriginNs), byte_size(OriginNs) > 0 ->
    case quod_ontology:genesis_anchor(TargetNs) of
        {ok, TargetAnchor} ->
            effect_resolution_state(
              TargetNs, GroupRef, PlanDigest, ManifestDigest,
              dtx_group_state(TargetNs, GroupId));
        {ok, _WrongAnchor} ->
            {ok, {retired, wrong_genesis_anchor}};
        {error, Reason} ->
            {error, Reason}
    end;
effect_resolution(_Target, _GroupRef, _PlanDigest, _ManifestDigest) ->
    {error, invalid_group_effect_ref}.

effect_resolution_state(
  TargetNs, GroupRef, PlanDigest, ManifestDigest,
  {ok, #{applied :=
           #{verdict := commit, slot := Slot,
             group_ref := GroupRef, plan_digest := PlanDigest,
             manifest_digest := ManifestDigest}}}) ->
    case quod_runtime:effect_frontier(TargetNs) of
        {ok, Frontier} when Frontier >= Slot -> {ok, {released, Slot}};
        _ -> {ok, pending}
    end;
effect_resolution_state(
  _TargetNs, GroupRef, PlanDigest, ManifestDigest,
  {ok, #{applied :=
           #{verdict := abort,
             group_ref := GroupRef, plan_digest := PlanDigest,
             manifest_digest := ManifestDigest}}}) ->
    {ok, {retired, aborted}};
effect_resolution_state(
  _TargetNs, _GroupRef, _PlanDigest, _ManifestDigest,
  {ok, #{applied := Applied}})
  when Applied =/= none ->
    {ok, {retired, effect_journal_conflict}};
effect_resolution_state(
  _TargetNs, GroupRef, _PlanDigest, _ManifestDigest,
  {ok, #{history := none, applied := none}}) ->
    effect_origin_resolution(GroupRef);
effect_resolution_state(
  _TargetNs, _GroupRef, _PlanDigest, _ManifestDigest,
  {ok, #{history := History, applied := none}})
  when is_map(History) ->
    {ok, pending};
effect_resolution_state(
  _TargetNs, _GroupRef, _PlanDigest, _ManifestDigest, {error, Reason}) ->
    {error, Reason};
effect_resolution_state(
  _TargetNs, _GroupRef, _PlanDigest, _ManifestDigest, _Malformed) ->
    {error, outcome_index_unavailable}.

effect_origin_resolution(GroupRef) ->
    case outcome(GroupRef) of
        {ok, #{status := pending}} -> {ok, pending};
        {ok, #{status := committed}} -> {ok, pending};
        {ok, #{status := aborted}} -> {ok, {retired, aborted}};
        {ok, #{status := rejected, reason := Reason}} ->
            {ok, {retired, Reason}};
        {error, not_found} -> {ok, {retired, not_found}};
        {error, Reason} -> {error, Reason}
    end.

-doc "Atomically project every pending Begin from the signing journal before the engine becomes ready.".
-spec project_pending_begins(binary(), [map()]) -> ok.
project_pending_begins(Ns, PendingBegins)
  when is_binary(Ns), is_list(PendingBegins) ->
    gen_server:cast(
      quod_reg:via({quod_prolog, Ns}),
      {project_pending_begins, PendingBegins}).

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

-doc "Resolve one live group waiter from the certified pre-Complete boundary.".
-spec dtx_group_terminal(binary(), term(), map()) -> ok.
dtx_group_terminal(
  Ns,
  {group, Ns, <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>} = GroupRef,
  Terminal) when is_binary(Ns), is_map(Terminal) ->
    gen_server:cast(
      quod_reg:via({quod_prolog, Ns}),
      {dtx_group_terminal, GroupRef, Terminal});
dtx_group_terminal(_Ns, _GroupRef, _Terminal) ->
    ok.

proof_request(TraceCtx, Principal, ExpectedAnchor, RequestEvidence) ->
    #proof_request{trace_ctx = TraceCtx,
                   principal = Principal,
                   expected_anchor = ExpectedAnchor,
                   request_evidence = RequestEvidence}.

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
apply publishes the post-apply `applied_live` runtime publication (`doc/agent-fipa-plan.md` §7), a `replay` apply
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
Ask this kb to validate one content batch against the parent of `Slot`, and
deliver the verdict asynchronously as
`{content_verdict, Tag, valid | {invalid, Reason} | abstain}` to `ReplyTo`.

A **cast** on purpose: content validation can require Prolog work while the consensus statem
is handling the proposal. Neither process waits synchronously for the other; the verdict returns
as a correlated message.

The verdict is judged against the KB **as of the proposal's parent** (`Slot-1`), so every honest node
reaches the same verdict deterministically: if the kb is already there it is delivered now; if it is
behind, the request parks until `apply_entry` reaches `Slot-1` (or a short fixed TTL — `validation_ttl_ms`,
on the order of Δ — reaps it to `abstain`); if the kb is already past the slot, the slot resolved without
us — `abstain`. Re-issuing the same `Tag` supersedes a still-parked request for it.
""".
-spec request_content_verdict(binary(), [#transaction{}], non_neg_integer(),
                              pos_integer(), pid(), term()) -> ok.
request_content_verdict(Ns, Transactions, BlockTimestamp, Slot, ReplyTo, Tag) ->
    gen_server:cast(
      quod_reg:via({quod_prolog, Ns}),
      {content_verdict_req, Transactions, BlockTimestamp,
       Slot, ReplyTo, Tag}).

-doc """
Look up every control's exact group history for one canonical phase wave at
the proposal parent and, for Prepare, also validate every plan against that
same parent KB. The reply is `{dtx_verdict, Tag, EnginePid, AppliedFloor,
{valid, Histories} | {invalid, Reason} | abstain}` where `Histories` is keyed
by GroupId.
""".
-spec request_dtx_verdict(binary(), [quod_dtx:control()], non_neg_integer(),
                          pos_integer(), pid(), term()) -> ok.
request_dtx_verdict(Ns, Controls, BlockTimestamp, Slot, ReplyTo, Tag)
  when is_binary(Ns), is_list(Controls), Controls =/= [],
       is_integer(Slot), Slot > 0, is_pid(ReplyTo) ->
    gen_server:cast(
      quod_reg:via({quod_prolog, Ns}),
      {dtx_verdict_req, Controls, BlockTimestamp, Slot, ReplyTo, Tag}).

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
    S = #s{ns = Ns, self = Self, signer = Signer,
           est = quod_committed_projection:new_est(),
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
  {submit_plan, Plan, GoalBlob, ResultBlob, RequestAuth,
   ForeignReads, ReplyBindings, TraceCtx}, From, S) ->
    accept_plan_submission(
      From, Plan, GoalBlob, ResultBlob, RequestAuth,
      ForeignReads, ReplyBindings, TraceCtx, S);
handle_call(
  {submit_role, Change, ReplyBindings, TraceCtx}, From, S) ->
    accept_role_submission(
      From, Change, ReplyBindings, TraceCtx, S);
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
handle_call({validate_read_plan, _Plan}, _From,
            S = #s{ready = false}) ->
    {reply, {error, not_ready}, S};
handle_call({validate_read_plan, Plan}, _From,
            S = #s{ns = Ns, applied = Applied, est = Est,
                   outcomes = Outcomes, signer = Signer}) ->
    Reply =
        case quod_simplex:genesis_hash(Ns) of
            <<_:256>> = Anchor ->
                Context = quod_commit_validation:new(
                            {Ns, Anchor}, Applied, Est, Outcomes, Signer),
                case quod_commit_validation:read_only_plan(Plan, Context) of
                    ok -> {ok, Applied};
                    {error, Reason} -> {error, Reason}
                end;
            undefined ->
                {error, not_ready}
        end,
    {reply, Reply, S};
%% The worker has already sealed every participant and built one immutable
%% semantic Begin. Registration is asynchronous to Simplex and correlated by
%% this exact proof worker, so other proofs and the engine mailbox keep moving.
handle_call({reserve_dtx_begin, Ref, Begin, GroupRef}, From = {Pid, _Tag},
            S) ->
    register_dtx_handoff(Ref, Pid, From, Begin, GroupRef, S);
handle_call({activate_dtx_begin, Ref, GroupRef}, From = {Pid, _Tag}, S) ->
    activate_dtx_handoff(Ref, Pid, From, GroupRef, S);
handle_call({cancel_dtx_begin, Ref, GroupRef}, _From = {Pid, _Tag}, S) ->
    cancel_registered_dtx_handoff(Ref, Pid, GroupRef, S);
handle_call(get_stats, _From, S) ->
    #est{db = #db{ref = StoreRef}} = S#s.est,
    {reply, #{applied   => S#s.applied,  applies => S#s.applies,
              rejects   => S#s.rejects,  proves  => S#s.proves,
              conflicts => S#s.conflicts,
              parked    => map_size(S#s.parked),        %% in-flight writes awaiting commit (liveness gauge)
              park_timeouts => S#s.park_timeouts,       %% final outcome unknown when caller deadline elapsed
              proof_workers => map_size(S#s.workers),
              proof_waiters => map_size(S#s.waiting_workers),
              group_waiters => map_size(S#s.group_waiters),
              scope_workers => map_size(S#s.scope_workers),
              remote_scopes => map_size(S#s.remote_scopes),
              kb_memory_words => quod_erlog_db_mvcc:memory_words(StoreRef),
              kb_history_predicates => quod_erlog_db_mvcc:history_predicates(StoreRef)}, S};

handle_call(sync, _From, S) -> {reply, ok, S};   %% replay backpressure barrier (sync/1)

%% One co-hosted scope session per origin proof and pinned ontology identity.
%% The origin pid is derived from `From`; it is never accepted from the payload.
handle_call(
  {scope_open, _ScopeId, _ProofId, _Anchor, _ReadOnly, _DeadlineMs,
   _OriginIdentity, _Principal, _Authentication}, _From,
  S = #s{ready = false, ns = Ns}) ->
    {reply, {error, {ontology_rebuilding, Ns}}, S};
handle_call(
  {scope_open, ScopeId, ProofId, Anchor, ReadOnly, DeadlineMs,
   OriginIdentity, Principal, Authentication}, From,
  S = #s{self = OriginKey})
  when is_binary(ScopeId), byte_size(ScopeId) =:= 16,
       is_binary(ProofId), byte_size(ProofId) =:= 32,
       is_binary(Anchor), byte_size(Anchor) =:= 32,
       is_boolean(ReadOnly), is_integer(DeadlineMs) ->
    Origin = element(1, From),
    Mode = case ReadOnly of true -> read_only; false -> read_write end,
    case scope_admission_reason(Mode, Anchor, S) of
        ok ->
            case quod_scope_wire:authentication_digest(Authentication) of
                {ok, AuthenticationDigest} ->
                    case scope_authentication_reason(
                           Authentication, OriginKey, OriginIdentity,
                           Principal, AuthenticationDigest, ProofId,
                           max(0, DeadlineMs - quod_time:mono_ms()),
                           S#s.ns, none) of
                        {ok, RequestContext} ->
                            open_scope_session(
                              Origin, ScopeId, ProofId, Anchor, ReadOnly,
                              DeadlineMs, Principal, RequestContext, S);
                        {error, Reason} ->
                            {reply, {error, Reason}, S}
                    end;
                {error, Reason} ->
                    {reply, {error, Reason}, S}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, S}
    end;
handle_call(
  {scope_open, _ScopeId, _ProofId, _Anchor, _ReadOnly, _DeadlineMs,
   _OriginIdentity, _Principal, _Authentication}, _From, S) ->
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
handle_call(
  {agent_attester_complete, MRef, Result}, {Worker, _Tag},
  S = #s{agent_attesters = Attesters})
  when is_reference(MRef), is_pid(Worker) ->
    case maps:get(MRef, Attesters, undefined) of
        #agent_attester{pid = Worker} ->
            {handled, S1} = finish_agent_attester_result(MRef, Result, S),
            {reply, ok, S1};
        _ ->
            {reply, {error, stale}, S}
    end;
handle_call(
  {scope_authenticator_complete, MRef, Result}, {Worker, _Tag},
  S = #s{remote_authenticators = Authenticators})
  when is_reference(MRef), is_pid(Worker) ->
    case maps:get(MRef, Authenticators, undefined) of
        #scope_authenticator{pid = Worker} = Authenticator ->
            {reply, ok,
             finish_scope_authenticator(MRef, Result, Authenticator, S)};
        _ ->
            {reply, {error, stale}, S}
    end;
handle_call(
  {sign_agent_identity, ReadCheck, Evidence, ProofId,
   CommitteeId, NotAfter},
  {Worker, _Tag},
  S = #s{est = Est,
         signer = Signer = #{pubkey := <<_:256>> = Self}, ns = Ns})
  when is_pid(Worker) ->
    Reply = case {quod_simplex:identity_view(Ns),
                  agent_identity_reads_current(ReadCheck, Est)} of
                {{ok, #{committee_id := CommitteeId, self := Self}}, true} ->
                    case quod_agent_identity:statement(
                           Evidence, ProofId, CommitteeId, NotAfter) of
                        {ok, Statement} ->
                            case quod_agent_identity:sign(Statement, Signer) of
                                {ok, {_Self, Signature}} ->
                                    {ok, Self, Statement, Signature};
                                {error, _} -> {error, retry}
                            end;
                        {error, _} -> {error, invalid_request}
                    end;
                _ -> {error, retry}
            end,
    {reply, Reply, S};
handle_call(
  {sign_agent_identity, _ReadCheck, _Evidence, _ProofId,
   _CommitteeId, _NotAfter}, _From, S) ->
    {reply, {error, retry}, S};
handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.

%% Public proofs use an explicit call reference and monitor the exact engine.
%% This makes an engine exit distinguishable before/after a durable checkpoint
%% without blocking the engine in an opaque gen_server call.
handle_cast(
  {public_cursor, Owner, CallRef, CursorId, _Goal, #proof_request{}}, S)
  when is_pid(Owner), is_reference(CallRef),
       (not is_binary(CursorId) orelse byte_size(CursorId) =/= 32) ->
    reply_client({async, Owner, CallRef}, {error, bad_request}),
    {noreply, S};
handle_cast({public_cursor, Owner, CallRef, <<_:256>> = CursorId, Goal,
             #proof_request{} = Request}, S)
  when is_pid(Owner), is_reference(CallRef) ->
    admit_public_cursor(
      Owner, CallRef, CursorId, Goal, Request, S);
handle_cast({cancel_public_cursor, Owner, CallRef}, S = #s{workers = Workers})
  when is_pid(Owner), is_reference(CallRef) ->
    case find_cursor_worker(Owner, CallRef, Workers) of
        {ok, Pid} -> kill_worker(Pid);
        error -> ok
    end,
    {noreply, S};
handle_cast({public_proof, Caller, CallRef, Kind, _Goal,
             #proof_request{}},
            S = #s{ready = false})
  when is_pid(Caller), is_reference(CallRef),
       (Kind =:= prove orelse Kind =:= prove_ro orelse Kind =:= execute) ->
    reply_client({async, Caller, CallRef}, {error, rebuilding}),
    {noreply, S};
handle_cast({public_proof, Caller, CallRef, Kind, Goal,
             #proof_request{principal = Principal,
                            request_evidence = RequestEvidence} = Request}, S)
  when is_pid(Caller), is_reference(CallRef),
       (Kind =:= prove orelse Kind =:= prove_ro orelse Kind =:= execute) ->
    case valid_proof_auth(Principal, RequestEvidence) of
        true ->
            admit_public_request(
              Kind, Goal, {async, Caller, CallRef}, Request, S);
        false ->
            reply_client({async, Caller, CallRef}, {error, invalid_agent_principal}),
            {noreply, S}
    end;
handle_cast({project_pending_begins, PendingBegins},
            S = #s{outcomes = Outcomes0}) ->
    case quod_outcome:project_pending_begins(Outcomes0, PendingBegins) of
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
handle_cast({dtx_group_terminal, GroupRef, Terminal}, S) ->
    {noreply, release_group_waiter_terminal(GroupRef, Terminal, S)};
handle_cast({apply_entry, #entry{}, _Origin},
            S = #s{apply_dependency = {network_identity, _}}) ->
    %% Simplex owns the durable history and will replay it from the current
    %% applied floor. Do not grow a second in-memory entry queue here.
    {noreply, S};
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
handle_cast(mark_ready,
            S = #s{apply_dependency = {network_identity, _}}) ->
    {noreply, S};
handle_cast(mark_ready, S = #s{projection_failure = Reason})
  when Reason =/= none ->
    {noreply, S};
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
%% One shared content-verdict request: validate ordinary authorization and any
%% membership change against Slot-1, delivering now or parking until the KB catches up.
handle_cast(
  {content_verdict_req, Transactions, BlockTimestamp,
   Slot, ReplyTo, Tag}, S) ->
    {noreply,
     request_validation(
       {content, Transactions, BlockTimestamp}, Slot, ReplyTo, Tag, S)};
handle_cast(
  {dtx_verdict_req, Controls, BlockTimestamp, Slot, ReplyTo, Tag}, S) ->
    {noreply,
     request_validation(
       {dtx, Controls, BlockTimestamp}, Slot, ReplyTo, Tag, S)};
handle_cast(
  {agent_attestation, Request, ReplyTo, Tag},
  S = #s{ready = true})
  when is_pid(ReplyTo) ->
    {noreply, spawn_agent_attester(Request, ReplyTo, Tag, S)};
handle_cast({agent_attestation, _Request, ReplyTo, Tag}, S)
  when is_pid(ReplyTo) ->
    ReplyTo ! {quod_agent_attestation, Tag, {error, retry}},
    {noreply, S};
handle_cast(_Msg, S)       -> {noreply, S}.

%% Emit readiness from the handled edge, not from the caller that queued it.
%% Simplex also pins this process and height before opening its protected gate.
acknowledge_ready(S = #s{ns = Ns, applied = Height}) ->
    {Unresolved, Outcomes1} =
        quod_outcome:unresolved_operations(S#s.outcomes),
    ok = quod_simplex:prolog_ready(
           Ns, self(), Height, Unresolved),
    {noreply, S#s{outcomes = Outcomes1}}.

%% A proof worker finished (normal: it already replied / handed off) or crashed
%% (abnormal: the caller still waits — reply the distinct error here). MUST come
%% before the check_response fallback clause.
handle_info(Info = {'DOWN', MRef, process, _Pid, Reason}, S) ->
    case finish_scope_authenticator_down(MRef, S) of
        {handled, S1} -> {noreply, S1};
        unhandled ->
            case finish_agent_attester(MRef, Reason, S) of
                {handled, S1} -> {noreply, S1};
                unhandled ->
                    case handle_worker_down(MRef, Reason, S) of
                        unhandled -> handle_response_info(Info, S);
                        Reply     -> Reply
                    end
            end
    end;
handle_info({scope_authenticator_timeout, MRef},
            S = #s{remote_authenticators = Authenticators}) ->
    case maps:get(MRef, Authenticators, undefined) of
        #scope_authenticator{pid = Pid} -> exit(Pid, kill);
        undefined -> ok
    end,
    {noreply, S};
handle_info({agent_attester_timeout, MRef}, S) ->
    case maps:get(MRef, S#s.agent_attesters, undefined) of
        #agent_attester{pid = Pid} -> exit(Pid, kill);
        undefined -> ok
    end,
    {noreply, S};
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
        {#parked_write{waiters = Waiters, request_id = ReqId,
                       span_ctx = SpanCtx}, P1} ->
            Ref = {transaction, Ns, target_anchor(Ns), Tx},
            Outcome = {error, {outcome_unknown, Ref}},
            quod_trace:finish_span(SpanCtx, Outcome),
            reply_parked_waiters(Waiters, Outcome),
            {noreply, S#s{parked = P1,
                          requests = abandon_request(ReqId, S#s.requests),
                          park_timeouts = S#s.park_timeouts + 1}};
        error -> {noreply, S}
    end;
handle_info({group_wait_timeout, GroupId}, S = #s{group_waiters = Waiters}) ->
    HandoffStarted = erlang:monotonic_time(),
    case maps:take(GroupId, Waiters) of
        {#group_waiter{from = From, caller_mref = CallerMRef,
                       group_ref = GroupRef,
                       started_native = StartedNative}, Waiters1} ->
            demonitor(CallerMRef, [flush]),
            quod_metrics:observe_dtx_group_stage(
              S#s.ns, end_to_end, uncertain,
              erlang:monotonic_time() - StartedNative),
            reply_client(From, {error, {outcome_unknown, GroupRef}}),
            quod_metrics:observe_dtx_group_stage(
              S#s.ns, result_handoff, uncertain,
              erlang:monotonic_time() - HandoffStarted),
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
handle_info(
  {gproc, registered, Monitor, _Name},
  S = #s{apply_dependency = {network_identity, Monitor}}) ->
    {noreply, resume_apply_dependency(S)};
handle_info(
  {gproc, unreg, Monitor, _Name},
  S = #s{apply_dependency = {network_identity, Monitor}}) ->
    %% A missing root owner is precisely the state being waited for.  Keep the
    %% follow monitor: its next registration edge wakes this engine directly.
    {noreply, S};
%% `send_request/2` gives us a non-blocking gen_statem call without a helper process per
%% transaction. Responses are matched through the opaque request-id collection and labelled
%% with their tx id. A successful append still resolves through ordered `apply_entry`; only a
%% definite consensus rejection releases the parked client here.
handle_info(Info, S) ->
    handle_response_info(Info, S).

open_scope_session(Origin, ScopeId, ProofId, Anchor, ReadOnly, DeadlineMs,
                   Principal, RequestContext,
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
                                   DeadlineMs, Principal, RequestContext,
                                   drop_scope_worker(WorkerMRef, S))
                    end
            end;
        error ->
            open_new_scope_session(
              Origin, ScopeId, ProofId, Anchor, ReadOnly, DeadlineMs,
              Principal, RequestContext, S)
    end.

spawn_agent_attester(Request, ReplyTo, Tag,
                     S = #s{ns = Ns, est = Est, applied = Applied,
                            proof_timeout_ms = Timeout,
                            agent_attesters = Attesters}) ->
    case quod_simplex:acquire_proof_access(Ns) of
        {ok, Access} ->
            Engine = self(),
            Deadline = quod_time:mono_ms() + Timeout,
            {Pid, MRef} = spawn_monitor(
                            fun() ->
                                receive
                                    {agent_attester_start, WorkerRef} ->
                                        Result = run_agent_attester(
                                                   Engine, Ns, Est, Applied,
                                                   Access, Request, Timeout),
                                        _ = gen_server:call(
                                              Engine,
                                              {agent_attester_complete,
                                               WorkerRef, Result},
                                              infinity)
                                end
                            end),
            Timer = erlang:send_after(
                      max(1, Deadline - quod_time:mono_ms()), self(),
                      {agent_attester_timeout, MRef}),
            Pid ! {agent_attester_start, MRef},
            S#s{agent_attesters = Attesters#{
                  MRef => #agent_attester{pid = Pid, timer = Timer,
                                          reply_to = ReplyTo, tag = Tag}}};
        {error, _} ->
            ReplyTo ! {quod_agent_attestation, Tag, {error, retry}},
            S
    end.

run_agent_attester(
  Engine, Ns, Est, Applied, Access,
  {agent_identity_request, _RequestId, <<_:256>> = ProofId,
   RequestBytes, <<_:512>> = Signature, ProposedNotAfter},
  ProofTimeout)
  when is_binary(RequestBytes), is_integer(ProposedNotAfter),
       ProposedNotAfter >= 0 ->
    Now = quod_time:now_ms(),
    case {quod_ontology:network_identity(), quod_simplex:genesis_hash(Ns)} of
        {{ok, Network}, <<_:256>> = Anchor} ->
            case quod_client_goal:verify_for(
                   RequestBytes, Signature, Network, {Ns, Anchor}, Now) of
                {ok, Evidence = #{agent_ref_blob := AgentRef,
                                  request := #{signing_public_key := SigningKey,
                                               not_after_ms := RequestNotAfter}}}
                  when ProposedNotAfter > Now,
                       ProposedNotAfter =< RequestNotAfter,
                       ProposedNotAfter =< Now + ProofTimeout ->
                    attest_authenticated_agent(
                      Engine, Ns, Est, Applied, Access,
                      Evidence, ProofId, ProposedNotAfter,
                      AgentRef, SigningKey);
                {error, expired} -> {error, retry};
                _ -> {error, invalid_request}
            end;
        _ -> {error, retry}
    end;
run_agent_attester(_Engine, _Ns, _Est, _Applied, _Access,
                   _Request, _ProofTimeout) ->
    {error, invalid_request}.

attest_authenticated_agent(
  Engine, Ns, Est, Applied, Access,
  Evidence, ProofId, NotAfter, AgentRef, SigningKey) ->
    Session = quod_proof_session:start(
                Est, #{read_set => false, read_only => true,
                       access_guard => Access,
                       scope_id => crypto:strong_rand_bytes(16)}),
    Principal = {agent, AgentRef},
    Result = try quod_ask:authenticate_agent(
                   Principal, SigningKey,
                   {Ns, quod_simplex:genesis_hash(Ns)}, Applied, Session) of
                 {true, ReadCheck} ->
                     case quod_simplex:identity_view(Ns) of
                         {ok, #{committee_id := CommitteeId}} ->
                             try gen_server:call(
                                   Engine,
                                   {sign_agent_identity, ReadCheck,
                                    Evidence, ProofId, CommitteeId, NotAfter})
                             catch exit:_ -> {error, retry}
                             end;
                         _ -> {error, retry}
                     end;
                 false -> {error, denied}
             after
                 quod_proof_session:stop(Session)
             end,
    Result.

%% Agent attestation is invalidated only by a fact it actually consulted.
%% Source claims and other unrelated commits may advance the ontology while
%% the read-only proof runs; rejecting those commits by height made identity
%% collection fail spuriously under concurrent signed work. The ordinary MVCC
%% read tokens already express the required freshness boundary.
agent_identity_reads_current(
  ReadCheck,
  #est{db = #db{mod = quod_erlog_db_mvcc, ref = Ref}}) ->
    maps:is_key({agent_key, 3}, ReadCheck) andalso
        quod_diff:valid_read_check(ReadCheck) andalso
        quod_diff:validate(ReadCheck, Ref) =:= ok;
agent_identity_reads_current(_ReadCheck, _Est) ->
    false.

-ifdef(TEST).
test_agent_identity_reads_current(ReadCheck, Est) ->
    agent_identity_reads_current(ReadCheck, Est).
-endif.

finish_agent_attester(MRef, _Reason,
                      S = #s{agent_attesters = Attesters}) ->
    case maps:take(MRef, Attesters) of
        {#agent_attester{timer = Timer, reply_to = ReplyTo, tag = Tag}, Rest} ->
            _ = erlang:cancel_timer(Timer, [{async, true}, {info, false}]),
            ReplyTo ! {quod_agent_attestation, Tag, {error, retry}},
            {handled, S#s{agent_attesters = Rest}};
        error -> unhandled
    end.

finish_agent_attester_result(
  MRef, Result, S = #s{agent_attesters = Attesters}) ->
    case maps:take(MRef, Attesters) of
        {#agent_attester{timer = Timer, reply_to = ReplyTo, tag = Tag}, Rest} ->
            _ = erlang:cancel_timer(Timer, [{async, true}, {info, false}]),
            demonitor(MRef, [flush]),
            ReplyTo ! {quod_agent_attestation, Tag, Result},
            {handled, S#s{agent_attesters = Rest}};
        error -> unhandled
    end.

open_new_scope_session(Origin, ScopeId, ProofId, Anchor, ReadOnly, DeadlineMs,
                       Principal, RequestContext,
                       S = #s{ns = Ns}) ->
    case scope_capacity_available(S) of
        false ->
            {reply, {error, {ontology_busy, Ns}}, S};
        true ->
            start_new_scope_session(
              Origin, ScopeId, ProofId, Anchor, ReadOnly, DeadlineMs,
              Principal, RequestContext, S)
    end.

start_new_scope_session(Origin, ScopeId, ProofId, Anchor, ReadOnly, DeadlineMs,
                        Principal,
                        #{request_binding := RequestBinding},
                        S = #s{ns = Ns, est = Est, applied = Height,
                               scope_sessions = Sessions}) ->
    case quod_dtx:valid_principal(Principal) of
        true ->
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
                                       request_binding => RequestBinding,
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
        false ->
            {reply, {error, {protocol_error, session_binding}}, S}
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
    case {maps:find(Binding, Remote), Operation} of
        {error, {scope_open, Authentication}} ->
            handle_remote_scope_open(
              PeerKey, Endpoint, RequestLink, Binding, Authentication,
              CommandSeq, RequestId, RemainingMs, S);
        {error, _OtherOperation} ->
            reject_unknown_scope(
              PeerKey, Endpoint, Binding, CommandSeq, RequestId, S);
        {{ok, Scope}, _} ->
            handle_bound_scope_command(
              PeerKey, RequestLink, Binding, CommandSeq,
              RequestId, RemainingMs, Operation, Scope, S)
    end.

handle_remote_scope_open(
  PeerKey, Endpoint, RequestLink,
  Binding = {scope_binding, OriginKey, TargetKey, ProofId, _ScopeId,
             OriginIdentity, {Ns, Anchor}, Mode,
             Principal, AuthenticationDigest},
  Authentication,
  CommandSeq, RequestId, RemainingMs,
  S = #s{ns = Ns, self = TargetKey}) ->
    case PeerKey =:= OriginKey andalso
         CommandSeq =:= 1 andalso RemainingMs > 0 andalso
         quod_quic:valid_endpoint(Endpoint) of
        false ->
            S;
        true ->
            begin_remote_scope_authentication(
              PeerKey, Endpoint, RequestLink, Binding, Authentication,
              OriginKey, OriginIdentity, Principal, AuthenticationDigest,
              ProofId, RequestId, RemainingMs, Mode, Anchor, S)
    end;
handle_remote_scope_open(
  _PeerKey, _Endpoint, _RequestLink, _Binding, _Authentication,
  _CommandSeq, _RequestId, _RemainingMs, S) ->
    S.

begin_remote_scope_authentication(
  PeerKey, Endpoint, RequestLink, Binding, Authentication,
  OriginKey, OriginIdentity, Principal, AuthenticationDigest,
  ProofId, RequestId, RemainingMs, Mode, Anchor,
  S = #s{ns = Ns, remote_authenticators = Authenticators,
         remote_auth_bindings = Bindings}) ->
    case maps:is_key(Binding, Bindings) of
        true ->
            %% The authenticated command stream may retransmit its open while
            %% the certified origin view is being fetched.  The first request
            %% already owns the eventual exactly-correlated reply.
            S;
        false ->
            Engine = self(),
            Deadline = quod_time:mono_ms() + RemainingMs,
            {Pid, MRef} = spawn_monitor(
                            fun() ->
                                receive
                                    {scope_authenticator_start, WorkerRef} ->
                                        Result = scope_authentication_reason(
                                                   Authentication, OriginKey,
                                                   OriginIdentity, Principal,
                                                   AuthenticationDigest,
                                                   ProofId, RemainingMs, Ns,
                                                   {PeerKey, Endpoint}),
                                        _ = gen_server:call(
                                              Engine,
                                              {scope_authenticator_complete,
                                               WorkerRef, Result},
                                              infinity)
                                end
                            end),
            Timer = erlang:send_after(
                      RemainingMs, self(),
                      {scope_authenticator_timeout, MRef}),
            Authenticator = #scope_authenticator{
                              pid = Pid, timer = Timer,
                              peer_key = PeerKey, endpoint = Endpoint,
                              request_link = RequestLink,
                              binding = Binding, request_id = RequestId,
                              deadline_ms = Deadline, mode = Mode,
                              anchor = Anchor,
                              origin_identity = OriginIdentity},
            Pid ! {scope_authenticator_start, MRef},
            S#s{remote_authenticators =
                    Authenticators#{MRef => Authenticator},
                remote_auth_bindings = Bindings#{Binding => MRef}}
    end.

finish_scope_authenticator(
  MRef, Result,
  #scope_authenticator{
     timer = Timer, peer_key = PeerKey, endpoint = Endpoint,
     request_link = RequestLink, binding = Binding,
     request_id = RequestId, deadline_ms = Deadline,
     mode = Mode, anchor = Anchor,
     origin_identity = OriginIdentity}, S0) ->
    _ = erlang:cancel_timer(Timer, [{async, true}, {info, false}]),
    demonitor(MRef, [flush]),
    S1 = drop_scope_authenticator(MRef, Binding, S0),
    RemainingMs = Deadline - quod_time:mono_ms(),
    case {Result, RemainingMs > 0} of
        {{ok, RequestContext}, true} ->
            %% Only a certified, authorized origin becomes reusable route
            %% state. Failed authentication used the contact request-locally
            %% and leaves no remembered address or fabricated identity.
            observe_scope_origin_candidate(
              OriginIdentity, {target_namespace(Binding), Anchor},
              {PeerKey, Endpoint}),
            open_authenticated_remote_scope(
              PeerKey, Endpoint, RequestLink, Binding,
              RequestContext, RequestId, RemainingMs,
              Mode, Anchor, S1);
        {{error, Reason}, _} ->
            reject_scope_open(
              PeerKey, Endpoint, Binding, RequestId, Reason, S1);
        {_, false} ->
            reject_scope_open(
              PeerKey, Endpoint, Binding, RequestId,
              {scope_expired, target_namespace(Binding)}, S1)
    end.

finish_scope_authenticator_down(
  MRef, S = #s{remote_authenticators = Authenticators}) ->
    case maps:get(MRef, Authenticators, undefined) of
        #scope_authenticator{
           timer = Timer, binding = Binding, peer_key = PeerKey,
           endpoint = Endpoint, request_id = RequestId} ->
            _ = erlang:cancel_timer(
                  Timer, [{async, true}, {info, false}]),
            S1 = drop_scope_authenticator(MRef, Binding, S),
            {handled,
             reject_scope_open(
               PeerKey, Endpoint, Binding, RequestId,
               signed_scope_unavailable, S1)};
        undefined ->
            unhandled
    end.

drop_scope_authenticator(
  MRef, Binding,
  S = #s{remote_authenticators = Authenticators,
         remote_auth_bindings = Bindings}) ->
    S#s{remote_authenticators = maps:remove(MRef, Authenticators),
        remote_auth_bindings = maps:remove(Binding, Bindings)}.

observe_scope_origin_candidate(OriginIdentity, TargetIdentity, Contact)
  when OriginIdentity =/= TargetIdentity ->
    quod_foreign_log:observe_candidate(OriginIdentity, Contact);
observe_scope_origin_candidate(_OriginIdentity, _TargetIdentity, _Contact) ->
    ok.

open_authenticated_remote_scope(
  PeerKey, Endpoint, RequestLink, Binding, RequestContext,
  RequestId, RemainingMs, Mode, Anchor, S) ->
    case remote_open_reason(Mode, Anchor, PeerKey, S) of
        ok ->
            begin_remote_scope_open(
              PeerKey, Endpoint, RequestLink, Binding, RequestContext,
              RequestId, RemainingMs, S);
        {error, Reason} ->
            reject_scope_open(
              PeerKey, Endpoint, Binding, RequestId, Reason, S)
    end.

scope_authentication_reason(
  node, OriginKey, _OriginIdentity, {node, OriginKey},
  AuthenticationDigest, _ProofId, _RemainingMs, _S, _Contact) ->
    case quod_scope_wire:authentication_digest(node) of
        {ok, AuthenticationDigest} ->
            {ok, #{request_binding => none, request_auth => none}};
        _ -> {error, {protocol_error, request_binding}}
    end;
scope_authentication_reason(
  {signed_goal, _RequestBytes, _Signature, _Certificate} = Authentication,
  _OriginKey, OriginIdentity, Principal = {agent, _}, AuthenticationDigest,
  ProofId, RemainingMs, Ns, Contact) ->
    scope_authentication_reason(
      Authentication, _OriginKey, OriginIdentity, Principal,
      AuthenticationDigest, ProofId, RemainingMs, Ns, Contact,
      fun local_or_foreign_agent_view/5);
scope_authentication_reason(
  _Authentication, _OriginKey, _OriginIdentity, _Principal,
  _AuthenticationDigest, _ProofId, _RemainingMs, _Ns, _Contact) ->
    {error, {protocol_error, request_binding}}.

scope_authentication_reason(
  {signed_goal, RequestBytes, Signature, Certificate} = Authentication,
  _OriginKey, OriginIdentity, Principal = {agent, _}, AuthenticationDigest,
  ProofId, RemainingMs, Ns, Contact, ViewFun) ->
    case quod_scope_wire:authentication_digest(Authentication) of
        {ok, AuthenticationDigest} ->
            verify_scope_authentication(
              RequestBytes, Signature, Certificate,
              OriginIdentity, Principal, ProofId, RemainingMs, Ns,
              Contact, ViewFun);
        _ ->
            {error, {protocol_error, request_binding}}
    end.

verify_scope_authentication(
  RequestBytes, Signature, Certificate,
  OriginIdentity, Principal, ProofId, RemainingMs, Ns,
  Contact, ViewFun) ->
    case quod_ontology:network_identity() of
        {ok, Network} ->
            case quod_client_goal:verify_for(
                   RequestBytes, Signature, Network, OriginIdentity,
                   quod_time:now_ms()) of
                {ok, Evidence = #{agent_ref_blob := AgentRef}}
                  when Principal =:= {agent, AgentRef} ->
                    case verify_scope_agent_identity(
                           Certificate, Evidence, ProofId,
                           OriginIdentity, RemainingMs, Contact, ViewFun) of
                        ok ->
                            {ok, #{request_binding =>
                                       quod_client_goal:request_binding(Evidence),
                                   request_auth =>
                                       quod_client_goal:request_auth(Evidence)}};
                        {error, _} ->
                            {error, signed_scope_unavailable}
                    end;
                {error, expired} ->
                    {error, {scope_expired, Ns}};
                _ ->
                    {error, {protocol_error, request_binding}}
            end;
        _ ->
            {error, scope_network_identity_unavailable(Ns)}
    end.

verify_scope_agent_identity(
  Certificate, Evidence, ProofId, OriginIdentity = {OriginNs, _Anchor},
  RemainingMs, Contact, ViewFun)
  when is_integer(RemainingMs), RemainingMs > 0 ->
    case ViewFun(
           OriginNs, OriginIdentity, Certificate, Contact, RemainingMs) of
        {ok, View} ->
            quod_agent_identity:verify(
              Certificate, Evidence, ProofId, View, quod_time:now_ms());
        {error, _} -> {error, retry}
    end;
verify_scope_agent_identity(
  _Certificate, _Evidence, _ProofId, _OriginIdentity, _RemainingMs,
  _Contact, _ViewFun) ->
    {error, retry}.

local_or_foreign_agent_view(
  OriginNs, OriginIdentity, Certificate, Contact, RemainingMs) ->
    case quod_simplex:identity_view(OriginNs) of
        {ok, #{identity := OriginIdentity} = View} -> {ok, View};
        _ ->
            quod_foreign_log:current(
              quod_agent_identity:route_hints(Certificate),
              OriginIdentity, Contact, RemainingMs)
    end.

scope_network_identity_unavailable(Ns) when is_binary(Ns) ->
    {network_identity_unavailable, Ns}.

-ifdef(TEST).
test_scope_authentication_reason(
  Authentication, OriginKey, OriginIdentity, Principal,
  AuthenticationDigest, ProofId, ViewResult) ->
    scope_authentication_reason(
      Authentication, OriginKey, OriginIdentity, Principal,
      AuthenticationDigest, ProofId, 1000,
      <<"quod:test-target">>, none,
      fun(_OriginNs, _Identity, _Certificate, _Contact, _RemainingMs) ->
          ViewResult
      end).
-endif.

remote_open_reason(Mode, Anchor, _PeerKey, S = #s{ns = Ns}) ->
    case scope_admission_reason(Mode, Anchor, S) of
        ok ->
            case scope_capacity_available(S) of
                false -> {error, {ontology_busy, Ns}};
                true -> ok
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

begin_remote_scope_open(PeerKey, Endpoint, RequestLink, Binding,
                        #{request_binding := RequestBinding,
                          request_auth := RequestAuth},
                        RequestId, RemainingMs,
                        S = #s{scope_timeout_ms = ScopeTimeout,
                               remote_scopes = Remote,
                               remote_open_refs = OpenRefs,
                               remote_request_mrefs = RequestRefs}) ->
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
               binding = Binding, request_binding = RequestBinding,
               request_auth = RequestAuth,
               peer_key = PeerKey,
               request_link = RequestLink, request_mref = RequestMRef,
               return_channel = ReturnChannel, open_ref = OpenRef,
               open_request_id = RequestId,
               last_request_id = RequestId,
               lifetime_timer = Timer, lifetime_token = Token,
               deadline_ms = Deadline},
    S#s{remote_scopes = Remote#{Binding => Scope},
        remote_open_refs = OpenRefs#{OpenRef => Binding},
        remote_request_mrefs = RequestRefs#{RequestMRef => Binding}}.

reject_unknown_scope(
  PeerKey, Endpoint,
  Binding = {scope_binding, PeerKey, TargetKey, _ProofId, _ScopeId,
             _OriginIdentity, {Ns, _Anchor}, _Mode,
             _Principal, _AuthenticationDigest},
  CommandSeq, RequestId, S = #s{ns = Ns, self = TargetKey})
  when CommandSeq >= 1 ->
    reject_scope_open(
      PeerKey, Endpoint, Binding, RequestId,
      {protocol_error, session_binding}, S);
reject_unknown_scope(_PeerKey, _Endpoint, _Binding, _CommandSeq,
                     _RequestId, S) ->
    S.

reject_scope_open(PeerKey, Endpoint, Binding, RequestId, Reason, S) ->
    send_scope_rejection(PeerKey, Endpoint, Binding, RequestId, Reason),
    S.

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
   _OriginIdentity, {_Ns, Anchor}, Mode,
   _Principal, _AuthenticationDigest}, S) ->
    scope_admission_reason(Mode, Anchor, S).

execute_remote_scope_command(
  Binding, {scope_open, _Authentication}, RequestId, CommandSeq, S) ->
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
scope_command_route(active, certify_reads) -> error;
scope_command_route(active, {bind_group_effects, _, _}) -> error;
scope_command_route(active, {bind_operation_effect, _}) -> error;
scope_command_route(active, {submit_plan, _, _, _, _, _}) -> error;
scope_command_route(active, _Operation) -> active;
scope_command_route(sealed, scope_close) -> sealed;
scope_command_route(sealed, {scope_attest, _ManifestBlob}) -> sealed;
scope_command_route(sealed, certify_reads) -> sealed;
scope_command_route(sealed, {bind_group_effects, _, _}) -> sealed;
scope_command_route(sealed, {bind_operation_effect, _}) -> sealed;
scope_command_route(sealed, {submit_plan, _, _, _, _, _}) -> sealed;
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
  certify_reads, RequestId, CommandSeq, Binding,
  #remote_scope{
     handle = {quod_scope_session, Pid, _SessionScopeId,
               SessionProofId, SessionRef, _Ns, _Anchor},
     pending = Pending}, S) ->
    case certify_reads_pending_reason(
           Pending, target_namespace(Binding)) of
        {error, Reason} ->
            poison_remote_scope(
              Binding, RequestId, CommandSeq, Reason, S);
        ok ->
            InternalRef = make_ref(),
            Pid ! {scope_certify_reads, self(), SessionProofId, SessionRef,
                   InternalRef},
            add_remote_pending(
              Binding, InternalRef,
              {certify_reads, RequestId, CommandSeq}, S)
    end;
execute_sealed_scope_command(
  {bind_group_effects, GroupRef, PlanDigest},
  RequestId, CommandSeq, Binding,
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
            Pid ! {scope_bind_group_effects, self(), SessionProofId,
                   SessionRef, InternalRef, GroupRef, PlanDigest},
            add_remote_pending(
              Binding, InternalRef,
              {bind_group_effects, RequestId, CommandSeq}, S)
    end;
execute_sealed_scope_command(
  {bind_operation_effect, SubmissionBlob},
  RequestId, CommandSeq, Binding,
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
            Pid ! {scope_bind_operation_effect, self(), SessionProofId,
                   SessionRef, InternalRef, SubmissionBlob},
            add_remote_pending(
              Binding, InternalRef,
              {bind_operation_effect, RequestId, CommandSeq}, S)
    end;
execute_sealed_scope_command(
  {submit_plan, _, _, _, _, _} = Operation,
  RequestId, CommandSeq, Binding, Scope, S) ->
    %% An ordinary single-target plan is handed to the target consensus
    %% engine exactly once. Move out of `sealed` before the
    %% asynchronous hand-off so a duplicate cannot start a second submission.
    S1 = update_remote_scope(
           Binding,
           fun(CurrentScope) ->
                   CurrentScope#remote_scope{state = submitting}
           end, S),
    execute_remote_plan_submission(
      Operation, RequestId, CommandSeq, Binding, Scope, S1).

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
            case decode_scope_goal(GoalBlob) of
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
  {submit_plan, _, _, _, _, _}, RequestId, CommandSeq, Binding, _Scope, S) ->
    poison_remote_scope(
      Binding, RequestId, CommandSeq,
      {protocol_error, unexpected_scope_command}, S);
execute_active_scope_command(
  scope_seal, RequestId, CommandSeq,
  Binding = {scope_binding, _OriginKey, _TargetKey, _ProofId, _ScopeId,
             OriginIdentity, _TargetIdentity, _Mode,
             _Principal, _AuthenticationDigest},
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
  {submit_plan, PlanBlob, GoalBlob, ResultBlob, ForeignReadsBlob,
   TraceCarrier},
  RequestId, CommandSeq,
  Binding = {scope_binding, _OriginKey, _TargetKey, ProofId, _ScopeId,
             OriginIdentity, TargetIdentity, Mode,
             Principal, _AuthenticationDigest},
  #remote_scope{request_binding = RequestBinding,
                request_auth = RequestAuth},
  S) ->
    From = {remote_submit, Binding, RequestId, CommandSeq},
    case {Mode =:= read_write andalso decode_submit_plan(PlanBlob),
          quod_scope_wire:decode_payload(foreign_reads, ForeignReadsBlob)} of
        {{ok, Plan}, {ok, ForeignReads}} ->
            %% The wire submission must be the authenticated scope's own plan:
            %% same proof, same origin. A plan borrowed from another proof or
            %% origin is refused before any consensus interaction.
            case quod_dtx:proof_id(Plan) =:= ProofId andalso
                 quod_dtx:origin(Plan) =:= OriginIdentity andalso
                 quod_dtx:target(Plan) =:= TargetIdentity andalso
                 quod_dtx:principal(Plan) =:= Principal andalso
                 quod_dtx:request_binding(Plan) =:= RequestBinding of
                true ->
                    case accept_plan_submission(
                           From, Plan, GoalBlob, ResultBlob, RequestAuth,
                           ForeignReads, [], quod_trace:extract(TraceCarrier),
                           S) of
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
        {false, _} ->
            finish_remote_submit(From, {error, bad_plan}, S);
        {{error, _Reason}, _} ->
            finish_remote_submit(From, {error, bad_plan}, S);
        {_, {error, _Reason}} ->
            finish_remote_submit(From, {error, bad_plan}, S)
    end.

%% Intermediate relays keep scope-goal symbols opaque.  The selected ontology's
%% shared admission helper materializes only that invocation's callable
%% positions before its ordinary Prolog authorization and execution.
decode_scope_goal(GoalBlob) ->
    quod_scope_wire:decode_payload(goal, GoalBlob).

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
             _OriginIdentity, {Ns, _Anchor}, _Mode,
             _Principal, _AuthenticationDigest},
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
  Binding = {scope_binding, _OriginKey, _TargetKey, ProofId, ScopeId,
             _OriginIdentity, {Ns, Anchor}, Mode,
             Principal, _AuthenticationDigest},
  ReturnLink,
  Scope = #remote_scope{request_mref = RequestMRef,
                        request_binding = RequestBinding,
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
                               principal => Principal,
                               request_binding => RequestBinding,
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
  {certify_reads, RequestId, CommandSeq},
  {reads_certified, Result}, S) ->
    case read_certificate_scope_reply(
           Result, target_namespace(Binding)) of
        {event, Operation} ->
            emit_scope_event(
              Binding, RequestId, CommandSeq, Operation, S);
        {error, Reason} ->
            poison_remote_scope(Binding, RequestId, CommandSeq, Reason, S)
    end;
handle_bound_scope_reply(
  Binding, _Scope,
  {bind_group_effects, RequestId, CommandSeq},
  {group_effects_bound, ok}, S) ->
    emit_scope_event(
      Binding, RequestId, CommandSeq, group_effects_bound, S);
handle_bound_scope_reply(
  Binding, _Scope,
  {bind_group_effects, RequestId, CommandSeq},
  {group_effects_bound, {error, Reason}}, S) ->
    poison_remote_scope(
      Binding, RequestId, CommandSeq,
      public_scope_reason(Reason, target_namespace(Binding)), S);
handle_bound_scope_reply(
  Binding, _Scope,
  {bind_operation_effect, RequestId, CommandSeq},
  {operation_effect_bound, {ok, EffectId}}, S) ->
    emit_scope_event(
      Binding, RequestId, CommandSeq,
      {operation_effect_bound, EffectId}, S);
handle_bound_scope_reply(
  Binding, _Scope,
  {bind_operation_effect, RequestId, CommandSeq},
  {operation_effect_bound, {error, Reason}}, S) ->
    poison_remote_scope(
      Binding, RequestId, CommandSeq,
      public_scope_reason(Reason, target_namespace(Binding)), S);
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

certify_reads_pending_reason(Pending, Ns) ->
    case map_size(Pending) < ?QUOD_MAX_ROUTER_PENDING_PER_SCOPE of
        true -> ok;
        false -> {error, {proof_limit_exceeded, Ns}}
    end.

read_certificate_scope_reply({ok, Certificate}, _Ns) ->
    case quod_scope_wire:encode_payload(read_certificate, Certificate) of
        {ok, Blob} -> {event, {reads_certified, Blob}};
        {error, Reason} -> {error, Reason}
    end;
read_certificate_scope_reply({error, Reason}, Ns) ->
    {error, public_scope_reason(Reason, Ns)};
read_certificate_scope_reply(_Malformed, _Ns) ->
    {error, {protocol_error, proof_engine}}.

public_scope_candidate({erlog, _}, _Ns) -> {protocol_error, proof_engine};
public_scope_candidate(unknown_invocation, _Ns) ->
    {protocol_error, unexpected_scope_command};
public_scope_candidate(invocation_active, _Ns) ->
    {protocol_error, unexpected_scope_command};
public_scope_candidate(already_open, _Ns) ->
    {protocol_error, unexpected_scope_command};
public_scope_candidate(busy, Ns) -> {ontology_busy, Ns};
public_scope_candidate(unavailable, Ns) -> {ontology_unreachable, Ns};
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

test_read_certificate_scope_reply(Result, Ns) ->
    read_certificate_scope_reply(Result, Ns).

test_certify_reads_pending_reason(PendingCount, Ns)
  when is_integer(PendingCount), PendingCount >= 0 ->
    Pending = maps:from_keys(lists:seq(1, PendingCount), true),
    certify_reads_pending_reason(Pending, Ns).

test_route_plans(Plans, OriginIdentity, SignedRequest) ->
    route_plans(Plans, OriginIdentity, SignedRequest).

test_sealed_submit_transition() ->
    {ok, AuthenticationDigest} =
        quod_scope_wire:authentication_digest(node),
    Binding =
        {scope_binding, <<1:256>>, <<2:256>>, <<3:256>>, <<4:128>>,
         {<<"quod:origin">>, <<5:256>>},
         {<<"quod:target">>, <<6:256>>}, read_write,
         {node, <<1:256>>}, AuthenticationDigest},
    {ok, ForeignReadsBlob} = quod_scope_wire:encode_payload(foreign_reads, []),
    Operation = {submit_plan, <<"not-a-plan">>, <<>>, <<>>,
                 ForeignReadsBlob, []},
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
                  _OriginIdentity, {Ns, _Anchor}, _Mode,
                  _Principal, _AuthenticationDigest}) -> Ns.

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
   _OriginIdentity, _TargetIdentity, _Mode,
   _Principal, _AuthenticationDigest},
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
                  _OriginIdentity, _TargetIdentity, _Mode,
                  _Principal, _AuthenticationDigest}) -> ProofId.

binding_scope_id({scope_binding, _OriginKey, _TargetKey, _ProofId, ScopeId,
                  _OriginIdentity, _TargetIdentity, _Mode,
                  _Principal, _AuthenticationDigest}) -> ScopeId.

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
         remote_internal_refs = InternalRefs}) ->
    case maps:take(Binding, Remote) of
        {#remote_scope{request_mref = RequestMRef,
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
            S#s{remote_scopes = Remote1,
                remote_open_refs = maps:remove(OpenRef, OpenRefs),
                remote_request_mrefs = maps:remove(
                                         RequestMRef, RequestRefs),
                remote_return_mrefs = case ReturnMRef of
                    undefined -> ReturnRefs;
                    _ -> maps:remove(ReturnMRef, ReturnRefs)
                end,
                remote_internal_refs = InternalRefs1};
        error -> S
    end.

handle_response_info(Info, S = #s{requests = Requests}) ->
    case gen_statem:check_response(Info, Requests, true) of
        {{reply, Result}, {append, Tx}, Requests1} ->
            {noreply, append_result(Tx, Result, S#s{requests = Requests1})};
        {{error, _Reason}, {append, Tx}, Requests1} ->
            %% The server may have committed immediately before exiting. Keep the caller
            %% parked so replay/apply can still provide the unambiguous result.
            {noreply, request_completed(Tx, S#s{requests = Requests1})};
        {{reply, Result}, {dtx_handoff, Ref}, Requests1} ->
            handle_dtx_handoff_reply(
              Ref, Result, S#s{requests = Requests1});
        {{error, _Reason}, {dtx_handoff, Ref}, Requests1} ->
            reject_dtx_handoff(
              Ref, {error, {ontology_unavailable, S#s.ns}}, false,
              S#s{requests = Requests1});
        no_reply ->
            {noreply, S};
        no_request ->
            {noreply, S}
    end.

register_dtx_handoff(
  Ref, Pid, From, Begin, GroupRef,
  S = #s{ns = Ns, workers = Workers, requests = Requests}) ->
    Checks =
        {maps:get(Ref, Workers, undefined),
         quod_dtx:begin_group_ref(Begin)},
    case Checks of
        {#proof_worker{pid = Pid, handoff = none,
                       deadline_ms = DeadlineMs} = Worker,
         {ok, GroupRef}} ->
            IntentId = make_ref(),
            case quod_simplex:register_dtx_begin(
                   Ns, self(), IntentId, Begin, GroupRef, DeadlineMs) of
                {ok, RequestId} ->
                    Handoff = #dtx_handoff{
                                 intent_id = IntentId,
                                 registration_from = From,
                                 group_ref = GroupRef},
                    Requests1 = gen_statem:reqids_add(
                                  RequestId, {dtx_handoff, Ref}, Requests),
                    {noreply,
                     S#s{workers = Workers#{
                           Ref => Worker#proof_worker{handoff = Handoff}},
                         requests = Requests1}};
                {error, _} = Error ->
                    {reply, Error, S}
            end;
        {#proof_worker{pid = Pid, handoff = none}, error} ->
            {reply, {error, invalid_begin}, S};
        _ ->
            {reply, {error, cancelled}, S}
    end.

handle_dtx_handoff_reply(Ref, {accepted, IntentId},
                         S = #s{ns = Ns, workers = Workers}) ->
    case maps:get(Ref, Workers, undefined) of
        #proof_worker{
           handoff = #dtx_handoff{
                        intent_id = IntentId, registration_from = From,
                        state = registering} = Handoff} = Worker ->
            gen_server:reply(From, ok),
            {noreply,
             S#s{workers = Workers#{
                   Ref => Worker#proof_worker{
                            handoff = Handoff#dtx_handoff{
                                        registration_from = none,
                                        state = dormant}}}}};
        #proof_worker{handoff = #dtx_handoff{}} ->
            reject_dtx_handoff(
              Ref, {error, {protocol_error, dtx_handoff}}, true, S);
        _ ->
            ok = quod_simplex:cancel_dtx_begin(Ns, self(), IntentId),
            {noreply, S}
    end;
handle_dtx_handoff_reply(Ref, {error, Reason}, S) ->
    reject_dtx_handoff(Ref, {error, Reason}, false, S);
handle_dtx_handoff_reply(Ref, _Other, S) ->
    reject_dtx_handoff(
      Ref, {error, {protocol_error, dtx_handoff}}, true, S).

reject_dtx_handoff(Ref, Error, CancelSimplex,
                   S = #s{ns = Ns, workers = Workers}) ->
    case maps:get(Ref, Workers, undefined) of
        #proof_worker{
           handoff = #dtx_handoff{
                        intent_id = IntentId,
                        registration_from = RegistrationFrom}} = Worker ->
            _ = case CancelSimplex of
                    true -> quod_simplex:cancel_dtx_begin(
                              Ns, self(), IntentId);
                    false -> ok
                end,
            _ = case RegistrationFrom of
                    none -> ok;
                    _ -> gen_server:reply(RegistrationFrom, Error)
                end,
            {noreply,
             S#s{workers = Workers#{
                   Ref => Worker#proof_worker{handoff = none}}}};
        _ ->
            {noreply, S}
    end.

activate_dtx_handoff(
  Ref, Pid, _From, GroupRef,
  S = #s{ns = Ns, workers = Workers, waiting_workers = Waiting,
         group_waiters = GroupWaiters, max_proof_workers = Max}) ->
    case maps:get(Ref, Workers, undefined) of
        #proof_worker{
           pid = Pid, timer = KillRef,
           handoff = #dtx_handoff{
                        state = dormant, group_ref = GroupRef,
                        intent_id = IntentId}} = Worker
          when map_size(Waiting) < Max,
               map_size(GroupWaiters) < Max ->
            _ = erlang:cancel_timer(KillRef),
            Worker1 = Worker#proof_worker{
                        checkpoint = GroupRef, handoff = none},
            checkpoint_client(Worker#proof_worker.from, GroupRef),
            ok = quod_simplex:activate_dtx_begin(Ns, self(), IntentId),
            {reply, ok,
             S#s{workers = maps:remove(Ref, Workers),
                 waiting_workers = Waiting#{Ref => Worker1}}};
        #proof_worker{
           pid = Pid,
           handoff = #dtx_handoff{
                        state = dormant, group_ref = GroupRef,
                        intent_id = IntentId}} = Worker ->
            ok = quod_simplex:cancel_dtx_begin(Ns, self(), IntentId),
            {reply, {error, cancelled},
             S#s{workers = Workers#{
                   Ref => Worker#proof_worker{handoff = none}}}};
        _ ->
            {reply, {error, cancelled}, S}
    end.

cancel_registered_dtx_handoff(
  Ref, Pid, GroupRef,
  S = #s{ns = Ns, workers = Workers}) ->
    case maps:get(Ref, Workers, undefined) of
        #proof_worker{
           pid = Pid,
           handoff = #dtx_handoff{
                        state = dormant, group_ref = GroupRef,
                        intent_id = IntentId}} = Worker ->
            ok = quod_simplex:cancel_dtx_begin(Ns, self(), IntentId),
            {reply, ok,
             S#s{workers = Workers#{
                   Ref => Worker#proof_worker{handoff = none}}}};
        _ ->
            {reply, {error, cancelled}, S}
    end.

cancel_dtx_handoff(Ref,
                   S = #s{ns = Ns, workers = Workers,
                          requests = Requests}) ->
    case maps:get(Ref, Workers, undefined) of
        #proof_worker{
           handoff = #dtx_handoff{
                        intent_id = IntentId,
                        registration_from = RegistrationFrom}} = Worker ->
            Requests1 = abandon_request_label(
                          {dtx_handoff, Ref}, Requests),
            ok = quod_simplex:cancel_dtx_begin(Ns, self(), IntentId),
            _ = case RegistrationFrom of
                    none -> ok;
                    _ -> gen_server:reply(
                           RegistrationFrom, {error, cancelled})
                end,
            S#s{workers = Workers#{
                  Ref => Worker#proof_worker{handoff = none}},
                requests = Requests1};
        _ -> S
    end.

terminate(_Reason, #s{ns = Ns, workers = W,
                      waiting_workers = Waiting,
                      agent_attesters = AgentAttesters,
                      remote_authenticators = ScopeAuthenticators,
                      scope_workers = ScopeWorkers,
                      apply_dependency = ApplyDependency,
                      outcomes = Outcomes}) ->
    maps:foreach(fun(_Ref, #proof_worker{pid = Pid}) -> kill_worker(Pid) end, W),
    maps:foreach(
      fun(_Ref, #proof_worker{pid = Pid}) -> kill_worker(Pid) end,
      Waiting),
    maps:foreach(
      fun(_Ref, #agent_attester{pid = Pid}) -> kill_worker(Pid) end,
      AgentAttesters),
    maps:foreach(
      fun(_Ref, #scope_authenticator{pid = Pid}) -> kill_worker(Pid) end,
      ScopeAuthenticators),
    maps:foreach(
      fun(_WM, #scope_worker{pid = Pid}) -> kill_worker(Pid) end,
      ScopeWorkers),
    _ = try quod_reg:unsubscribe(
              {channel, quod_scope_wire:request_channel(Ns)})
        catch _:_ -> ok end,
    ok = clear_apply_dependency_monitor(ApplyDependency),
    ok = quod_outcome:close(Outcomes),
    ok.

clear_apply_dependency_monitor({network_identity, Monitor}) ->
    quod_reg:demonitor_name(
      {quod_simplex, quod_ontology:root_ns()}, Monitor);
clear_apply_dependency_monitor(none) ->
    ok.

%%%===================================================================
%%% proof execution (worker-per-proof; copy-on-write overlay)
%%%===================================================================

admit_public_cursor(Owner, CallRef, _CursorId, _Goal, _Request,
                    S = #s{ready = false}) ->
    reply_client({async, Owner, CallRef}, {error, rebuilding}),
    {noreply, S};
admit_public_cursor(Owner, CallRef, _CursorId, _Goal, _Request,
                    S = #s{workers = Workers,
                           max_proof_workers = Max})
  when map_size(Workers) >= Max ->
    reply_client({async, Owner, CallRef}, {error, busy}),
    {noreply, S};
admit_public_cursor(
  Owner, CallRef, CursorId, Goal,
  #proof_request{principal = Principal,
                 request_evidence = RequestEvidence} = Request, S) ->
    case valid_proof_auth(Principal, RequestEvidence) of
        true ->
            {noreply,
             spawn_proof(
               cursor, {Owner, CallRef, CursorId, Goal},
               {async, Owner, CallRef}, Request, S)};
        false ->
            reply_client(
              {async, Owner, CallRef}, {error, invalid_agent_principal}),
            {noreply, S}
    end.

admit_public_request(execute, Goal, From, Request, S) ->
    admit_public_proof(prove, Goal, From, Request, S);
admit_public_request(Kind, Goal, From, Request, S)
  when Kind =:= prove; Kind =:= prove_ro ->
    admit_public_proof(Kind, Goal, From, Request, S).

%% Capacity and operation identity are checked by the one engine owner before
%% a proof starts.  A matching live worker is not a durable claim, but starting
%% the same signed operation twice would create two independent proofs for one
%% request. The duplicate therefore gets the existing pre-custody `busy`
%% refusal; only work that reached durable custody may be outcome-unknown.
%% Distinct operations still proceed independently to Simplex admission.
admit_public_proof(Kind, Goal, From, Request,
                   S = #s{workers = Workers,
                          max_proof_workers = Max}) ->
    case proof_operation_gate(Request, S) of
        {new, S1} when map_size(Workers) < Max ->
            {noreply, spawn_proof(Kind, Goal, From, Request, S1)};
        {new, S1} ->
            reply_client(From, {error, busy}),
            {noreply, S1};
        {in_flight, S1} ->
            reply_client(From, {error, busy}),
            {noreply, S1};
        {{alias, OperationRef}, S1} ->
            reply_client(From, {error, {outcome_unknown, OperationRef}}),
            {noreply, S1};
        {conflict, S1} ->
            reply_client(From, {error, operation_conflict}),
            {noreply, S1};
        {{unknown, OperationRef}, S1} ->
            reply_client(From, {error, {outcome_unknown, OperationRef}}),
            {noreply, S1}
    end.

proof_operation_gate(Request, S) ->
    case proof_request_operation(Request) of
        none -> {new, S};
        Operation ->
            case active_operation(Operation, S) of
                none -> applied_operation(Operation, S);
                active -> {in_flight, S};
                conflict -> {conflict, S}
            end
    end.

%% The worker maps are the complete ownership record while a proof is live or
%% waiting for a durable group outcome.  Once the worker leaves them, the
%% normal durable outcome index below is again the sole authority.
active_operation({Key, Digest, OperationRef},
                 #s{workers = Workers, waiting_workers = Waiting}) ->
    case find_active_operation(Key, Digest, OperationRef, Workers) of
        none -> find_active_operation(Key, Digest, OperationRef, Waiting);
        Found -> Found
    end.

find_active_operation(Key, Digest, OperationRef, Workers) ->
    maps:fold(
      fun(_Ref, #proof_worker{operation = {Key0, Digest0, OperationRef0}},
          Found)
            when Key0 =:= Key ->
              case Found of
                  conflict -> conflict;
                  active -> Found;
                  none when Digest0 =:= Digest,
                            OperationRef0 =:= OperationRef ->
                      active;
                  none -> conflict
              end;
         (_Ref, _Worker, Found) ->
              Found
      end, none, Workers).

proof_request_operation(
  #proof_request{
     request_evidence =
       #{request := #{mode := execute,
                      operation_id := OperationId},
         agent_ref_blob := AgentRef,
         request_digest := Digest,
         operation_ref := OperationRef}})
  when is_binary(AgentRef),
       is_binary(OperationId), byte_size(OperationId) =:= 32,
       is_binary(Digest), byte_size(Digest) =:= 32 ->
    {{AgentRef, OperationId}, Digest, OperationRef};
proof_request_operation(_Request) ->
    none.

applied_operation(
  {_Key, Digest, OperationRef}, S = #s{outcomes = Outcomes0}) ->
    case quod_outcome:lookup_ref(Outcomes0, OperationRef) of
        {{ok, #{status := claimed, request_digest := Digest}}, Outcomes1} ->
            {{alias, OperationRef}, S#s{outcomes = Outcomes1}};
        {{ok, #{status := claimed}}, Outcomes1} ->
            {conflict, S#s{outcomes = Outcomes1}};
        {not_found, Outcomes1} ->
            {new, S#s{outcomes = Outcomes1}};
        {wrong_anchor, Outcomes1} ->
            {{unknown, OperationRef}, S#s{outcomes = Outcomes1}};
        {{error, _Reason}, Outcomes1} ->
            {{unknown, OperationRef}, S#s{outcomes = Outcomes1}}
    end.

%% Spawn one worker for this proof. The worker gets a small table/height snapshot handle,
%% never the committed KB contents, plus the height stamped on the public reply.
%% The engine only tracks the monitor + a kill timer; it never runs the proof.
spawn_proof(Kind, Goal, From, #proof_request{} = Request,
            S = #s{ns = Ns, est = Est, applied = Applied,
                   signer = Signer,
                   proof_timeout_ms = ProofTimeout}) ->
    Engine = self(),
    Ref = make_ref(),
    ProofId = crypto:strong_rand_bytes(32),
    StartedNative = erlang:monotonic_time(),
    Request1 = Request#proof_request{started_native = StartedNative},
    Deadline = quod_time:mono_ms() + ProofTimeout,
    {Pid, MRef} = spawn_opt(fun() ->
        proof_worker(Engine, Ref, ProofId, Deadline, Kind, Goal,
                     Ns, Est, Applied, Request1, Signer)
    end, [monitor]),
    CallerMRef = monitor(process, proof_client_pid(From)),
    Token = make_ref(),
    KillDelay = max(1, Deadline - quod_time:mono_ms()),
    KillRef = erlang:send_after(KillDelay, Engine, {proof_kill, Ref, Token}),
    Worker = #proof_worker{pid = Pid, kind = Kind,
                           worker_mref = MRef, caller_mref = CallerMRef,
                           from = From, timer = KillRef, token = Token,
                           deadline_ms = Deadline,
                           started_native = StartedNative,
                           operation = proof_request_operation(Request1),
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
             Applied, #proof_request{trace_ctx = TraceCtx} = Request,
             Signer) ->
    _ = quod_process:kill_when_owner_dies(Engine, self()),
    Ctx = worker_context(Kind, Ns, Applied),
    Result = quod_trace:with_span(
               TraceCtx, <<"quod.prolog.prove">>, internal,
               #{'quod.namespace' => Ns, 'quod.kb.height' => Applied,
                 'quod.proof.mode' => atom_to_binary(Kind, utf8),
                 'quod.proof.id' => quod_trace:tx_id(ProofId)},
               fun(SpanCtx) ->
                   R = run_worker(
                         Engine, Ref, Kind, ProofId, Deadline, Goal, Request,
                         Ns, Applied,
                         quod_predicates:set_context(Est, Ctx), Signer),
                   _ = quod_trace:result(SpanCtx, R),
                   R
               end),
    gen_server:cast(Engine, {proof_result, Ref, Result}).

worker_context(_ProofKind, Ns, Applied) ->
    %% Authenticated authority stays in private quod_proof_context state; the
    %% readable predicate context deliberately carries no duplicate subject.
    quod_predicates:proof_context(Ns, Applied, undefined).

run_worker(Engine, Ref, cursor, ProofId, Deadline,
           {Owner, CallRef, CursorId, Goal}, #proof_request{} = Request,
           Ns, Applied, Est, Signer) ->
    run_cursor_origin(
      Engine, Ref, ProofId, Deadline, Owner, CallRef, CursorId, Goal,
      Request, Ns, Applied, Est, Signer);
run_worker(Engine, Ref, Kind, ProofId, Deadline, Goal,
           #proof_request{} = Request, Ns, Applied, Est, Signer) ->
    run_origin_proof(
      Engine, Ref, Kind, ProofId, Deadline, Goal, Request,
      Ns, Applied, Est, Signer).

run_origin_proof(
  Engine, Ref, Kind, ProofId, Deadline, Goal,
  #proof_request{expected_anchor = ExpectedAnchor} = Request,
  Ns, Applied, Est, Signer) ->
    case quod_simplex:genesis_hash(Ns) of
        <<_:256>> = Anchor
          when ExpectedAnchor =:= any; ExpectedAnchor =:= Anchor ->
            run_pinned_origin(
              Engine, Ref, Kind, ProofId, Deadline, Ns, Applied,
              Anchor, Request, Est, Signer,
              fun(Origin) -> run_pinned_goal(Origin, Goal) end);
        <<_:256>> when is_binary(ExpectedAnchor) ->
            {error, wrong_genesis_anchor};
        undefined when is_binary(ExpectedAnchor) ->
            {error, wrong_genesis_anchor};
        undefined when ExpectedAnchor =:= any, Signer =:= none ->
            %% Isolated unit/runtime engines have no consensus identity and
            %% therefore cannot own foreign scopes. The same proof pipeline
            %% still runs under its private sentinel identity, including
            %% authorization, sealing, snapshot release and submission.
            Anchor = <<0:256>>,
            run_pinned_origin(
              Engine, Ref, Kind, ProofId, Deadline, Ns, Applied,
              Anchor, Request, Est, Signer,
              fun(Origin) -> run_pinned_goal(Origin, Goal) end);
        undefined ->
            %% A keyed engine is a network participant. It must never seal a
            %% sentinel-anchored plan during the short ready/genesis gap.
            {error, rebuilding}
    end.

run_cursor_origin(Engine, Ref, ProofId, Deadline, Owner, CallRef, CursorId,
                  Goal,
                  #proof_request{expected_anchor = ExpectedAnchor} = Request,
                  Ns, Applied, Est, Signer) ->
    case quod_simplex:genesis_hash(Ns) of
        <<_:256>> = Anchor
          when ExpectedAnchor =:= any; ExpectedAnchor =:= Anchor ->
            run_pinned_origin(
              Engine, Ref, cursor, ProofId, Deadline, Ns, Applied,
              Anchor, Request, Est, Signer,
              fun(Origin) ->
                  run_cursor_goal(
                    Owner, CallRef, CursorId, Goal, Origin)
              end);
        <<_:256>> when is_binary(ExpectedAnchor) ->
            {error, wrong_genesis_anchor};
        undefined when is_binary(ExpectedAnchor) ->
            {error, wrong_genesis_anchor};
        undefined when ExpectedAnchor =:= any, Signer =:= none ->
            run_pinned_origin(
              Engine, Ref, cursor, ProofId, Deadline, Ns, Applied,
              <<0:256>>, Request, Est, Signer,
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

run_pinned_origin(
  Engine, Ref, Kind, ProofId, Deadline, Ns, Applied, Anchor,
  #proof_request{principal = Principal,
                 request_evidence = RequestEvidence,
                 started_native = StartedNative}, Est, Signer, RunFun) ->
    ReadOnly = Kind =:= prove_ro,
    OriginIdentity = {Ns, Anchor},
    AuthPrincipal = case Principal of
                        undefined -> proof_principal(Signer);
                        _ -> Principal
                    end,
    OriginHandle = quod_proof_context:start(
                     ProofId, ReadOnly, OriginIdentity, Deadline,
                     AuthPrincipal, RequestEvidence),
    OverlayOpts = #{read_set => true,
                    read_only => ReadOnly,
                    signer => Signer,
                    proof_context => {origin, OriginHandle}},
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
                    proof_id = ProofId, started_native = StartedNative,
                    scope_id = ScopeId,
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

%% A signed request first authenticates its active key. Policy is then checked
%% only by the ontology whose predicate actually runs: a direct `A -> B::Goal`
%% does not ask A to authorize B's predicate, while B still executes its normal
%% `can_invoke/4` path. Local goals (including `A::Goal`) are authorized by A.
run_pinned_goal(#pinned_origin{kind = Kind} = Origin, Goal) ->
    Verdict = authorization_verdict(Origin, Goal),
    run_authorized_pinned_goal(Kind, Origin, Goal, Verdict).

%% Keep the requested goal intact for the authorization transcript. The proof
%% session derives the bounded denial goal only for execution.
authorization_verdict(
  #pinned_origin{namespace = Ns, anchor = Anchor,
                 height = Height, session = Session}, Goal) ->
    Principal = quod_proof_context:principal(),
    Identity = {Ns, Anchor},
    Authorized =
        case quod_proof_context:request_evidence() of
            #{request := #{signing_public_key := SigningKey},
              agent_ref_blob := AgentRef}
              when Principal =:= {agent, AgentRef} ->
                signed_origin_authorized(
                  Principal, SigningKey, Goal, Identity, Height, Session);
            none ->
                quod_ask:authorize_scope(
                  Principal, Goal, authorization_chain(Principal, Identity),
                  Identity, Height, Session);
            _ -> false
        end,
    case Authorized of
        true -> allowed;
        false ->
            logger:warning(
              "quod_prolog[~s]: can_invoke refused a top-level goal at "
              "pinned height ~p", [Ns, Height]),
            denied
    end.

signed_origin_authorized(
  Principal, SigningKey, Goal, {Ns, _Anchor} = Identity, Height, Session) ->
    case quod_ask:authenticate_agent(
           Principal, SigningKey, Identity, Height, Session) of
        {true, _AgentKeyReads} ->
            case signed_origin_policy_goal(Ns, Goal) of
                remote_selector -> true;
                {local, PolicyGoal} ->
                    quod_ask:authorize_scope(
                      Principal, PolicyGoal, [Identity], Identity,
                      Height, Session);
                invalid -> false
            end;
        false -> false
    end.

signed_origin_policy_goal(Ns, {'::', TargetTerm, Inner}) ->
    %% Ingress has already materialized the origin-owned route selector while
    %% preserving the foreign inner goal opaquely. Policy only classifies the
    %% resulting route; it does not repeat wire materialization.
    case quod_ontology_name:flatten(TargetTerm) of
        Ns -> {local, Inner};
        Target when is_binary(Target) -> remote_selector;
        error -> invalid
    end;
signed_origin_policy_goal(_Ns, Goal) ->
    {local, Goal}.

-ifdef(TEST).
test_signed_origin_policy_goal(Ns, Goal) -> signed_origin_policy_goal(Ns, Goal).
-endif.

authorization_chain(_Principal, _Identity) -> [].

proof_principal(#{pubkey := <<_:256>> = Pubkey}) -> {node, Pubkey};
proof_principal(none) -> anonymous.

valid_proof_auth(undefined, none) -> true;
valid_proof_auth(anonymous, none) -> true;
valid_proof_auth({node, <<_:256>>}, none) -> true;
valid_proof_auth(
  {agent, AgentRef},
  #{agent_ref_blob := AgentRef,
    request_bytes := Bytes, request_digest := <<_:256>>,
    signature := <<_:512>>, variables := Variables}) ->
    is_binary(Bytes) andalso is_list(Variables);
valid_proof_auth(_Principal, _RequestEvidence) -> false.

run_authorized_pinned_goal(Kind, Origin, Goal, Verdict) ->
    Result = normalize_read_only_result(
               Kind, run_origin_invocation(Origin, Goal, Verdict)),
    finish_pinned_proof(Kind, Origin, Goal, Result).

%% A successful writable proof seals every scope while all sessions are still
%% open, then routes the immutable participant set once. Only write/effect
%% plans consume consensus slots; read-only dependencies become certificates
%% for the ordinary single-writer path. Two or more writers retain the atomic
%% group unchanged.
%% Read-only proof kinds and failed proofs pass through; failed proofs close
%% without sealing.
finish_pinned_proof(prove, Origin, Goal, {ok, Bindings, _Diff, ReadSet}) ->
    SealStarted = erlang:monotonic_time(),
    case quod_proof_context:seal_plans() of
        {ok, Plans} ->
            submit_sealed_plans(
              Origin, Goal, Bindings, ReadSet, Plans, SealStarted);
        {error, _} = Error ->
            Error
    end;
finish_pinned_proof(_Kind, _Origin, _Goal, Result) ->
    Result.

submit_sealed_plans(Origin, Goal, Bindings, ReadSet, Plans, SealStarted) ->
    OriginIdentity = quod_proof_context:origin_identity(),
    Route = route_plans(
              Plans, OriginIdentity,
              quod_proof_context:request_auth() =/= none),
    RemoteClaim = case Route of
                      {remote_claim, _, _} -> true;
                      _ -> false
                  end,
    ok = observe_remote_seal(
           Origin, RemoteClaim, SealStarted),
    case Route of
        read ->
            {ok, Bindings, [], ReadSet};
        {single, Target, ReadRows} ->
            with_certified_read_dependencies(
              ReadRows,
              fun(ForeignReads) ->
                  submit_single_plan(
                    Origin, Target, maps:get(Target, Plans), Goal, Bindings,
                    ForeignReads)
              end);
        {remote_claim, Target, ReadRows} ->
            with_certified_read_dependencies(
              ReadRows,
              fun(ForeignReads) ->
                  submit_remote_claim(
                    Origin, Target, maps:get(Target, Plans), Goal, Bindings,
                    ForeignReads)
              end);
        {group, Participants} ->
            submit_group(
              Origin, Goal, Bindings, Plans, Participants)
    end.

%% Pure lane choice: consensus ownership is determined only by the sealed
%% plans, never by where their sessions happen to be hosted.
route_plans(Plans, OriginIdentity, SignedRequest) ->
    Rows = lists:sort(maps:to_list(Plans)),
    Writers = [{Identity, Plan} || {Identity, Plan} <- Rows,
                                    quod_dtx:writes(Plan)],
    Readers = [{Identity, Plan} || {Identity, Plan} <- Rows,
                                    quod_dtx:reads_only(Plan)],
    case Writers of
        [] ->
            read;
        [{Target, _Plan}] when SignedRequest, Target =/= OriginIdentity ->
            {remote_claim, Target, Readers};
        [{Target, _Plan}] ->
            {single, Target, Readers};
        [_ | _] ->
            %% L3 is unchanged: only writers and their OCC readers consume
            %% Prepare/Finalize slots. A pure signed-origin claim is already
            %% represented by Begin and is not a participant of its own.
            {group, lists:sort(
                      [Identity || {Identity, _Plan} <- Writers ++ Readers])}
    end.

with_certified_read_dependencies(ReadRows, Fun) ->
    ok = read_certificate_test_barrier(),
    case certify_read_plans(ReadRows) of
        {ok, ForeignReads} -> Fun(ForeignReads);
        {error, _} = Error -> Error
    end.

%% The stale-read CT case must move a reader's head after sealing but before
%% certification. This test-only rendezvous is message-driven and one-shot;
%% production has no branch, delay, or progress-polling mechanism here.
-ifdef(TEST).
read_certificate_test_barrier() ->
    case application:get_env(quod, read_certificate_test_barrier) of
        {ok, {hold, Observer}} when is_pid(Observer) ->
            Ref = make_ref(),
            Observer ! {read_certificate_test_barrier, self(), Ref},
            receive
                {read_certificate_test_barrier, Ref, continue} -> ok
            end,
            ok = application:unset_env(
                   quod, read_certificate_test_barrier);
        _ -> ok
    end.

test_install_read_certificate_barrier() ->
    Observer = spawn(fun() -> read_certificate_barrier_observer(waiting, []) end),
    application:set_env(
      quod, read_certificate_test_barrier, {hold, Observer}).

test_await_read_certificate_barrier(TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs > 0 ->
    case application:get_env(quod, read_certificate_test_barrier) of
        {ok, {hold, Observer}} when is_pid(Observer) ->
            CallRef = make_ref(),
            Observer ! {await_read_certificate_barrier, self(), CallRef},
            receive
                {read_certificate_barrier_ready, CallRef} -> ok
            after TimeoutMs -> not_ready
            end;
        _ -> not_ready
    end.

test_release_read_certificate_barrier() ->
    case application:get_env(quod, read_certificate_test_barrier) of
        {ok, {hold, Observer}} when is_pid(Observer) ->
            CallRef = make_ref(),
            Observer ! {release_read_certificate_barrier, self(), CallRef},
            receive
                {read_certificate_barrier_released, CallRef} -> ok
            after 3000 -> not_ready
            end;
        _ -> not_ready
    end.

read_certificate_barrier_observer(waiting, Waiters) ->
    receive
        {read_certificate_test_barrier, Pid, Ref}
          when is_pid(Pid), is_reference(Ref) ->
            lists:foreach(
              fun({Waiter, CallRef}) ->
                  Waiter ! {read_certificate_barrier_ready, CallRef}
              end, Waiters),
            read_certificate_barrier_observer({ready, Pid, Ref}, []);
        {await_read_certificate_barrier, Waiter, CallRef} ->
            read_certificate_barrier_observer(
              waiting, [{Waiter, CallRef} | Waiters])
    end;
read_certificate_barrier_observer({ready, Pid, Ref} = Ready, _Waiters) ->
    receive
        {await_read_certificate_barrier, Waiter, CallRef} ->
            Waiter ! {read_certificate_barrier_ready, CallRef},
            read_certificate_barrier_observer(Ready, []);
        {release_read_certificate_barrier, Releaser, CallRef} ->
            Pid ! {read_certificate_test_barrier, Ref, continue},
            Releaser ! {read_certificate_barrier_released, CallRef}
    end.
-else.
read_certificate_test_barrier() -> ok.
-endif.

certify_read_plans([]) ->
    {ok, []};
certify_read_plans(Rows) ->
    Started = erlang:monotonic_time(),
    Result =
        case read_certification_rows(Rows, []) of
            {ok, CertificationRows} ->
                case quod_scope_session:certify_reads_many(
                       [{Handle, Plan}
                        || {_Identity, Plan, Handle} <- CertificationRows]) of
                    {ok, Certificates} -> {ok, lists:sort(Certificates)};
                    {error, _} = Error -> Error
                end;
            {error, _} = Error -> Error
        end,
    ok = observe_read_certification(Result, Started),
    Result.

observe_read_certification(Result, Started) ->
    case quod_proof_context:origin_identity() of
        {Ns, <<_:256>>} ->
            quod_metrics:observe_remote_operation_stage(
              Ns, read_certification,
              read_certification_metric_result(Result),
              erlang:monotonic_time() - Started);
        _ -> ok
    end.

read_certification_metric_result({ok, _}) -> ok;
read_certification_metric_result({error, conflict_retry}) -> rejected;
read_certification_metric_result(
  {error, read_certificate_unavailable}) -> uncertain;
read_certification_metric_result({error, _}) -> failed.

read_certification_rows([], RevRows) ->
    {ok, lists:reverse(RevRows)};
read_certification_rows([{Identity, Plan} | Rest], RevRows) ->
    case quod_proof_context:scope_handle(Identity) of
        {ok, Handle} ->
            read_certification_rows(
              Rest, [{Identity, Plan, Handle} | RevRows]);
        error ->
            {error, {protocol_error, session_binding}}
    end.

observe_remote_seal(
  #pinned_origin{namespace = Ns}, true, SealStarted) ->
    quod_metrics:observe_remote_operation_stage(
      Ns, proof_seal, ok, erlang:monotonic_time() - SealStarted);
observe_remote_seal(_Origin, false, _SealStarted) -> ok.

submit_remote_claim(
  #pinned_origin{namespace = OriginNs, anchor = OriginAnchor,
                 proof_id = ProofId} = Origin,
  Target, Plan, Goal, Bindings, ForeignReads) ->
    RequestAuth = quod_proof_context:request_auth(),
    RequestBinding = quod_proof_context:request_binding(),
    case {encode_proof_submission(Goal, Bindings),
          quod_simplex:dtx_binding(OriginNs),
          quod_proof_context:scope_handle(Target),
          quod_dtx:encode(Plan)} of
        {{ok, GoalBlob, ResultBlob},
         {ok, {OriginNs, OriginAnchor, _Coordinator, _Admission}
                = Coordinator},
         {ok, Handle}, {ok, PlanBlob}} ->
            ManifestInput =
                #{proof_id => ProofId,
                  coordinator => Coordinator,
                  nonce => crypto:strong_rand_bytes(32),
                  principal => quod_dtx:principal(Plan),
                  goal => GoalBlob, result => ResultBlob,
                  request_binding => RequestBinding,
                  participants => [{Target, quod_dtx:digest(Plan)}]},
            submit_signed_foreign_manifest(
              Origin, Target, Plan, PlanBlob, Handle,
              ManifestInput, RequestAuth, ForeignReads,
              Bindings);
        {{error, _} = Error, _, _, _} -> Error;
        {_, {error, _} = Error, _, _} -> Error;
        {_, _, error, _} -> {error, {protocol_error, session_binding}};
        {_, _, _, {error, _} = Error} -> Error;
        _ -> {error, {protocol_error, remote_claim}}
    end.

submit_signed_foreign_manifest(
  #pinned_origin{namespace = OriginNs, anchor = OriginAnchor} = Origin,
  Target, Plan, PlanBlob, Handle, ManifestInput, RequestAuth,
  ForeignReads, Bindings) ->
    case quod_dtx:new_manifest(ManifestInput) of
        {ok, Manifest} ->
            case quod_scope_session:attest_plan(Handle, Plan, Manifest) of
                {ok, Attestation} ->
                    Bundle = {Target, quod_dtx:digest(Plan),
                              PlanBlob, Attestation},
                    try quod_transaction:remote_claim(
                          {OriginNs, OriginAnchor}, Manifest,
                          Bundle, RequestAuth, ForeignReads) of
                        Claim ->
                            submit_signed_foreign_claim(
                              Origin, Target, Plan, Handle,
                              Claim, Bindings)
                    catch _:_ ->
                        {error, {protocol_error, remote_claim}}
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

submit_signed_foreign_claim(
  Origin, Target, Plan, Handle, Claim, Bindings) ->
    case quod_dtx:effects_count(Plan) of
        0 ->
            submit_unbound_foreign_claim(
              Origin, Target, Claim, Bindings);
        1 ->
            submit_effect_foreign_claim(
              Origin, Target, Plan, Handle, Claim, Bindings);
        _ ->
            {error, invalid_direct_effect}
    end.

submit_unbound_foreign_claim(
  #pinned_origin{namespace = OriginNs} = Origin,
  _Target, Claim = #transaction{tx_id = ClaimTxId}, Bindings) ->
    case quod_transaction:request_claim(Claim) of
        {ok, #{operation_ref := OperationRef}} ->
            ok = checkpoint_and_release_origin_snapshot(Origin, OperationRef),
            Started = erlang:monotonic_time(),
            Submission = quod_prolog:submit_role(
                           OriginNs, Claim, [],
                           max(1, quod_proof_context:remaining_ms())),
            ok = quod_metrics:observe_remote_operation_stage(
                   OriginNs, source_claim,
                   remote_submission_metric_result(Submission),
                   erlang:monotonic_time() - Started),
            case Submission of
                {ok, _Ignored, _ClaimSlot, ClaimTxId} ->
                    await_recovered_foreign_application(
                      OriginNs, ClaimTxId, OperationRef, Bindings);
                {error, _} = Error -> Error
            end;
        _ ->
            {error, {protocol_error, remote_claim}}
    end.

submit_effect_foreign_claim(
  #pinned_origin{namespace = OriginNs} = Origin,
  _Target, _Plan, Handle,
  Claim = #transaction{role = {remote_claim, _, _, _TargetTxId}},
  Bindings) ->
    case {quod_transaction:request_claim(Claim),
          quod_simplex:dtx_binding(OriginNs)} of
        {{ok, #{operation_ref := OperationRef}},
         {ok, {OriginNs, _OriginAnchor, Signer,
               <<_:256>> = Admission}}} ->
            CustodyClaim = Claim#transaction{
                             author = Signer,
                             submitted_at = quod_time:now_ms()},
            case quod_simplex:register_transaction_custody(
                   OriginNs, Admission, CustodyClaim) of
                {ok, Submission} ->
                    bind_and_activate_effect_claim(
                      Origin, Handle, Submission, CustodyClaim,
                      OperationRef, Bindings);
                {error, _} = Error -> Error
            end;
        _ ->
            {error, {protocol_error, remote_claim}}
    end.

bind_and_activate_effect_claim(
  #pinned_origin{namespace = OriginNs} = Origin,
  Handle, Submission, #transaction{tx_id = ClaimTxId},
  OperationRef, Bindings) ->
    case quod_scope_session:bind_operation_effect(
           Handle, Submission,
           max(1, quod_proof_context:remaining_ms())) of
        {ok, _EffectId} ->
            case checkpoint_and_release_origin_snapshot(
                   Origin, OperationRef) of
                ok ->
                    Started = erlang:monotonic_time(),
                    Activation = quod_simplex:activate_transaction_custody(
                                   OriginNs, ClaimTxId),
                    ok = quod_metrics:observe_remote_operation_stage(
                           OriginNs, source_claim,
                           remote_activation_metric_result(Activation),
                           erlang:monotonic_time() - Started),
                    case Activation of
                        {ok, _ClaimSlot} ->
                            %% The dormant custody registration began before
                            %% target effect binding; activation is the source
                            %% claim stage for the effect-bearing variant.  Its
                            %% one recovery owner performs the target submit.
                            await_recovered_foreign_application(
                              OriginNs, ClaimTxId,
                              OperationRef, Bindings);
                        {error, Reason} ->
                            logger:warning(
                              "quod[~ts]: claimed application did not finish: ~p",
                              [OriginNs, Reason]),
                            {error, {outcome_unknown, OperationRef}}
                    end;
                {error, _} ->
                    cancel_dormant_effect_claim(
                      OriginNs, ClaimTxId, OperationRef)
            end;
        {error, _} ->
            %% The bind reply may have been lost after the target fsynced its
            %% private row. Keep C dormant and let the one exact cancellation
            %% owner settle both journals; absence is never guessed here.
            cancel_dormant_effect_claim(
              OriginNs, ClaimTxId, OperationRef)
    end.

cancel_dormant_effect_claim(OriginNs, ClaimTxId, OperationRef) ->
    case quod_simplex:start_transaction_custody_cancellation(
           OriginNs, ClaimTxId) of
        ok -> ok;
        {error, Reason} ->
            logger:error(
              "quod[~ts]: dormant operation cancellation did not start: ~p",
              [OriginNs, Reason])
    end,
    {error, {outcome_unknown, OperationRef}}.

await_recovered_foreign_application(
  OriginNs, ClaimTxId, OperationRef, Bindings) ->
    case quod_simplex:await_operation_result(
           OriginNs, OperationRef,
           max(1, quod_proof_context:remaining_ms())) of
        {committed,
         {transaction, _TargetNs, <<_:256>>, <<_:256>>} = TargetRef} ->
            {committed, Bindings, TargetRef};
        {{rejected, Reason},
         {transaction, _TargetNs, <<_:256>>, <<_:256>>}}
          when is_atom(Reason) ->
            {error, Reason};
        {error, {outcome_unknown, OperationRef}} = Error ->
            Error;
        Other ->
            logger:warning(
              "quod[~ts]: recovery owner returned an invalid result for claim ~p: ~p",
              [OriginNs, ClaimTxId, Other]),
            {error, {outcome_unknown, OperationRef}}
    end.

remote_submission_metric_result({ok, _, _, _}) -> ok;
remote_submission_metric_result({error, {outcome_unknown, _}}) -> uncertain;
remote_submission_metric_result({error, _}) -> failed.

remote_activation_metric_result({ok, _}) -> ok;
remote_activation_metric_result({error, _}) -> uncertain.

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

submit_single_plan(Origin, Target, Plan, Goal, Bindings, ForeignReads) ->
    case encode_proof_submission(Goal, Bindings) of
        {ok, GoalBlob, ResultBlob} ->
            case quod_dtx:effects_count(Plan) of
                0 ->
                    submit_single_ordinary_plan(
                      Origin, Target, Plan, Goal, Bindings,
                      GoalBlob, ResultBlob, ForeignReads);
                1 ->
                    submit_single_effect_plan(
                      Origin, Target, Plan, Bindings,
                      GoalBlob, ResultBlob, ForeignReads);
                _ ->
                    {error, invalid_direct_effect}
            end;
        {error, _} = Error ->
            Error
    end.

submit_single_ordinary_plan(
  #pinned_origin{namespace = Ns, anchor = Anchor} = Origin,
  Target, Plan, Goal, Bindings,
  GoalBlob, ResultBlob, ForeignReads) ->
    RequestAuth = quod_proof_context:request_auth(),
    OutcomeRef = quod_transaction:plan_outcome_ref(
                   Plan, GoalBlob, ResultBlob, RequestAuth),
    case checkpoint_and_release_origin_snapshot(Origin, OutcomeRef) of
                ok ->
                    Result = submit_single_plan_at_target(
                               Target, Plan, Goal, Bindings,
                               GoalBlob, ResultBlob, RequestAuth,
                               ForeignReads),
                    case Result of
                        {ok, _B, Index, _TxId} ->
                            Handle = committed_plan_handle(
                                       RequestAuth, Target, {Ns, Anchor},
                                       Index, OutcomeRef),
                            {committed, Bindings, Handle};
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
    end.

%% The trusted in-VM API historically reports a same-ontology commit as its
%% local height. A signed client write instead needs the anchored transaction
%% reference: a bare integer is indistinguishable from a read result at the
%% shared result boundary and cannot be resolved after uncertainty.
committed_plan_handle(none, Identity, Identity, Index, _OutcomeRef) -> Index;
committed_plan_handle(_RequestAuth, _Target, _Origin, _Index, OutcomeRef) ->
    OutcomeRef.

submit_single_effect_plan(
  #pinned_origin{namespace = Ns, anchor = Anchor,
                 session = Session} = Origin,
  {Ns, Anchor} = Target, Plan, Bindings, GoalBlob, ResultBlob,
  ForeignReads) ->
    RequestAuth = quod_proof_context:request_auth(),
    case quod_dtx:material(Plan) of
        {ok, #{effects := [Effect]} = Material} ->
            Change0 = quod_transaction:from_plan(
                        Plan, Material#{foreign_reads => ForeignReads},
                        GoalBlob, ResultBlob, RequestAuth),
            Change = Change0#transaction{
                       author = quod_dtx:signer(Plan),
                       submitted_at = quod_time:now_ms()},
            OutcomeRef = {transaction, Ns, Anchor,
                          Change#transaction.tx_id},
            case quod_proof_session:prepared_effect(Session, Effect) of
                {ok, {Action, Desired, Effect, Prepared}} ->
                    with_effect_journal_preparation(
                      Action, Desired, Effect, Prepared,
                      fun() ->
                          commit_and_await_effect(
                            Origin, Target, Plan, Change, Effect,
                            GoalBlob, ResultBlob, Bindings,
                            RequestAuth, OutcomeRef)
                      end);
                error ->
                    {error, missing_effect_preparation}
            end;
        _ ->
            {error, invalid_direct_effect}
    end;
submit_single_effect_plan(_Origin, _Target, _Plan, _Bindings,
                          _GoalBlob, _ResultBlob, _ForeignReads) ->
    {error, effect_executor_not_local}.

with_effect_journal_preparation(Action, Desired, Effect, Prepared, Fun) ->
    case quod_effect_journal:reserve(self()) of
        {ok, Reservation} ->
            try
                case quod_effect_journal:stage(
                       Reservation, Action, Desired, Effect, Prepared) of
                    ok -> Fun();
                    {error, _} = Error -> Error
                end
            after
                ok = quod_effect_journal:release_reservation(Reservation)
            end;
        {error, busy} -> {error, busy};
        {error, _} -> {error, effect_journal_unavailable}
    end.

commit_and_await_effect(
  #pinned_origin{namespace = Ns, anchor = Anchor} = Origin,
  Target, Plan, Change, Effect, GoalBlob, ResultBlob, Bindings,
  RequestAuth, OutcomeRef) ->
    case checkpoint_bound_effect(Origin, Effect, Change, OutcomeRef) of
        ok ->
            case submit_bound_effect_plan(
                   Target, Plan, Change, GoalBlob, ResultBlob, Bindings) of
                {ok, _B, Index, _TxId} ->
                    case quod_effect_journal:await(
                           quod_effect:effect_id(Effect),
                           max(1, quod_proof_context:remaining_ms())) of
                        ok ->
                            Handle = committed_plan_handle(
                                       RequestAuth, Target, {Ns, Anchor},
                                       Index, OutcomeRef),
                            {committed, Bindings, Handle};
                        {error, outcome_unknown} ->
                            {error, {outcome_unknown, OutcomeRef}};
                        {error, Reason} -> {error, Reason}
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

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
  GoalBlob, ResultBlob, RequestAuth, ForeignReads) ->
    case quod_proof_context:scope_handle(Target) of
        {ok, {remote_scope, _, _, _, _} = Handle} ->
            %% The remote facade canonical-encodes the same immutable values;
            %% OutcomeRef above is therefore the exact target transaction.
            submit_remote_plan(
              Handle, Plan, Goal, Bindings, ForeignReads);
        {ok, {local_scope, _, TargetNs, TargetAnchor, _, _}} ->
            submit_plan_encoded(
              TargetNs, Plan, GoalBlob, ResultBlob, RequestAuth,
              ForeignReads, Bindings);
        {ok, {quod_scope_session, _, _, _, _,
              TargetNs, TargetAnchor}} ->
            submit_plan_encoded(
              TargetNs, Plan, GoalBlob, ResultBlob, RequestAuth,
              ForeignReads, Bindings);
        _ ->
            {error, {ontology_unreachable, TargetNs}}
    end.

submit_plan_encoded(
  TargetNs, Plan, GoalBlob, ResultBlob, RequestAuth,
  ForeignReads, Bindings) ->
    case quod_reg:where({quod_prolog, TargetNs}) of
        undefined -> {error, {ontology_unreachable, TargetNs}};
        Pid ->
            try gen_server:call(
                  Pid,
                  {submit_plan, Plan, GoalBlob, ResultBlob, RequestAuth,
                   ForeignReads, [Bindings], quod_trace:context()}, infinity)
            catch exit:_ ->
                {error,
                 {outcome_unknown,
                  quod_transaction:plan_outcome_ref(
                    Plan, GoalBlob, ResultBlob, RequestAuth)}}
            end
    end.

submit_group(
  #pinned_origin{engine = Engine, worker_ref = WorkerRef,
                 proof_id = ProofId, namespace = Ns,
                 anchor = Anchor, started_native = StartedNative},
  Goal, Bindings, Plans, Participants) ->
    RequestAuth = quod_proof_context:request_auth(),
    RequestBinding = quod_proof_context:request_binding(),
    case encode_proof_submission(Goal, Bindings) of
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
                          request_binding => RequestBinding,
                          participants => ParticipantRows},
                    build_and_register_group(
                      Engine, WorkerRef, ManifestInput,
                      Plans, ParticipantRows, Bindings,
                      RequestAuth, Ns, StartedNative);
                {ok, _WrongBinding} ->
                    {error, {protocol_error, coordinator_binding}};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

encode_proof_submission(Goal, Bindings) ->
    case quod_proof_context:durable_bindings(Bindings) of
        {ok, DurableBindings} ->
            quod_transaction:encode_durable_submission(
              Goal, DurableBindings);
        {error, _} = Error ->
            Error
    end.

build_and_register_group(
  Engine, WorkerRef, ManifestInput, Plans, ParticipantRows, Bindings,
  RequestAuth, Ns, StartedNative) ->
    case quod_dtx:new_manifest(ManifestInput) of
        {ok, Manifest} ->
            case attest_group_plans(
                   ParticipantRows, Plans, Manifest, []) of
                {ok, Bundles} ->
                    case quod_dtx:new_begin(Manifest, RequestAuth, Bundles) of
                        {ok, Begin} ->
                            case quod_dtx:begin_group_ref(Begin) of
                                {ok, GroupRef} ->
                                    trace_dtx_group(GroupRef),
                                    %% Everything through the immutable Begin
                                    %% is now sealed. Admission starts inside
                                    %% the following call, so these two timing
                                    %% owners neither leave a gap nor overlap.
                                    quod_metrics:observe_dtx_group_stage(
                                      Ns, proof_seal, ok,
                                      erlang:monotonic_time() -
                                        StartedNative),
                                    admit_group(
                                      Engine, WorkerRef, Begin, GroupRef,
                                      Plans, Bindings, Ns);
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

admit_group(Engine, WorkerRef, Begin, GroupRef, Plans, Bindings, Ns) ->
    StartedNative = erlang:monotonic_time(),
    Result =
        case gen_server:call(
               Engine,
               {reserve_dtx_begin, WorkerRef, Begin, GroupRef}, infinity) of
            ok ->
                finish_reserved_group(
                  Engine, WorkerRef, GroupRef, Plans, Bindings);
            {error, _} = Error -> Error
        end,
    quod_metrics:observe_dtx_group_stage(
      Ns, admission, admission_result(Result),
      erlang:monotonic_time() - StartedNative),
    Result.

admission_result({group_pending, _Bindings, _GroupRef}) -> ok;
admission_result({error, _}) -> failed.

trace_dtx_group(
  {group, _Ns, _Anchor, _Coordinator, _Admission, <<_:256>> = GroupId}) ->
    _ = quod_trace:add_event(
          quod_trace:context(), <<"dtx.group_reserved">>,
          #{'quod.dtx.group_id' => quod_trace:tx_id(GroupId)}),
    ok.

finish_reserved_group(Engine, WorkerRef, GroupRef, Plans, Bindings) ->
    case bind_group_effect_plans(Plans, GroupRef) of
        ok ->
            case gen_server:call(
                   Engine,
                   {activate_dtx_begin, WorkerRef, GroupRef}, infinity) of
                ok -> {group_pending, Bindings, GroupRef};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            _ = gen_server:call(
                  Engine,
                  {cancel_dtx_begin, WorkerRef, GroupRef}, infinity),
            Error
    end.

bind_group_effect_plans(Plans, GroupRef) ->
    Rows =
        [{Identity, quod_dtx:digest(Plan), Handle}
         || {Identity, Plan} <- maps:to_list(Plans),
            quod_dtx:effects_count(Plan) > 0,
            {ok, Handle} <- [quod_proof_context:scope_handle(Identity)]],
    Expected = length(
                 [ok || {_Identity, Plan} <- maps:to_list(Plans),
                        quod_dtx:effects_count(Plan) > 0]),
    case length(Rows) =:= Expected of
        false ->
            {error, {protocol_error, session_binding}};
        true ->
            bind_group_effect_rows(Rows, GroupRef)
    end.

bind_group_effect_rows([], _GroupRef) ->
    ok;
bind_group_effect_rows(Rows, GroupRef) ->
    RemainingMs = quod_proof_context:remaining_ms(),
    case RemainingMs > 0 of
        false ->
            {error, {proof_limit_exceeded,
                     element(1, quod_proof_context:origin_identity())}};
        true ->
            BindRows = [{Handle, PlanDigest}
                        || {_Identity, PlanDigest, Handle} <- Rows],
            quod_scope_session:bind_group_effects(
              BindRows, GroupRef, RemainingMs)
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
submit_remote_plan(Handle, Plan, Goal, Bindings, ForeignReads) ->
    case quod_scope_session:submit_plan(
           Handle, Plan, Goal, Bindings, ForeignReads) of
        {ok, Slot, TxId} -> {ok, [Bindings], Slot, TxId};
        {error, _} = Error -> Error
    end.

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

%% Every worker result is terminal now: a write proof commits (or fails)
%% inside the worker through submit_plan/4 before it reports, so the engine's
%% one reply path only shapes results — it never re-enters submission.
finish_proof(Ref, {group_pending, Bindings, GroupRef}, S)
  when is_map(Bindings) ->
    retain_group_waiter(Ref, GroupRef, Bindings, S);
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
  Bindings,
  S = #s{waiting_workers = Waiting, group_waiters = GroupWaiters,
         max_proof_workers = Max, ttl = Ttl}) ->
    case {maps:take(Ref, Waiting), maps:is_key(GroupId, GroupWaiters)} of
        {{#proof_worker{checkpoint = GroupRef,
                        worker_mref = WorkerMRef,
                        caller_mref = CallerMRef,
                        from = From, timer = ProofTimer} = Worker,
          Waiting1}, false}
          when map_size(GroupWaiters) < Max ->
            _ = erlang:cancel_timer(ProofTimer),
            demonitor(WorkerMRef, [flush]),
            Timer = erlang:send_after(Ttl, self(),
                                      {group_wait_timeout, GroupId}),
            Waiter = #group_waiter{
                from = From, caller_mref = CallerMRef,
                timer = Timer, group_ref = GroupRef,
                started_native = Worker#proof_worker.started_native,
                bindings = Bindings},
            S1 = S#s{waiting_workers = Waiting1,
                     group_waiters = GroupWaiters#{GroupId => Waiter}},
            %% The certified pre-Complete terminal notification may have crossed
            %% this worker's scope-cleanup/result message. Re-read the projection
            %% now so that ordering
            %% cannot strand a waiter until its deadline.
            release_group_waiter(GroupRef, S1);
        {{Worker, Waiting1}, _} ->
            HandoffStarted = erlang:monotonic_time(),
            {_Reply, _Height} = proof_worker_reply(Worker),
            quod_metrics:observe_dtx_group_stage(
              S#s.ns, end_to_end, uncertain,
              erlang:monotonic_time() -
                Worker#proof_worker.started_native),
            reply_client(Worker#proof_worker.from,
                         {error, {outcome_unknown, GroupRef}}),
            quod_metrics:observe_dtx_group_stage(
              S#s.ns, result_handoff, uncertain,
              erlang:monotonic_time() - HandoffStarted),
            S#s{waiting_workers = Waiting1};
        {error, _} ->
            S
    end;
retain_group_waiter(Ref, _BadRef, _Bindings, S) ->
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
used by `m:quod_runtime`; a foreign `::` returns
`{error, {ask_requires_anchored_proof, Namespace}}`, while an exact self-selection stays
in place. Runtime handlers set a semantic context via `quod_predicates:set_context/2` and
treat a non-empty `StagedChanges` as a projection violation. The caller must hold a snapshot
guarantee for the est (a proof-worker height entry or the runtime floor pin), or reads can
race history pruning.
""".
-spec prove_est(term(), tuple()) ->
          {ok, [map()] | map(), list(), map()} | fail | {error, term()}.
prove_est(Goal, Est) -> run_proof_est(Goal, Est).

run_proof_est(Goal, Est) ->
    case quod_proof_session:run_first(
           Goal, Est, #{read_set => true}) of
        {fail, _Reasons} -> fail;
        Result -> Result
    end.

%% Validate one sealed plan against this engine's own identity and turn it
%% into the signed ordinary transaction envelope. Sealing is target-side, so
%% every plan this engine legitimately receives was witnessed by THIS node —
%% a plan witnessed by anyone else (or a forged unsigned one on a keyed node)
%% is rejected before any consensus interaction.
accept_plan_submission(
  _From, _Plan, _GoalBlob, _ResultBlob, _RequestAuth,
  _ForeignReads, _ReplyBindings, _TraceCtx,
  S = #s{ready = false, ns = Ns}) ->
    {reply, {error, {ontology_rebuilding, Ns}}, S};
accept_plan_submission(
  From, Plan, GoalBlob, ResultBlob, RequestAuth,
  ForeignReads, ReplyBindings, TraceCtx, S) ->
    case valid_plan_submission(Plan, GoalBlob, ResultBlob, S) of
        {ok, #{effects := []} = Material} ->
            submit_plan_envelope(
              From, Plan, Material, GoalBlob, ReplyBindings, ResultBlob,
              RequestAuth, ForeignReads, TraceCtx, S);
        {ok, _EffectBearingMaterial} ->
            %% Direct effects require the checkpointed exact-transaction
            %% handoff. The ordinary plan API must not create a second path.
            {reply, {error, effect_requires_bound_handoff}, S};
        {error, Reason} ->
            outcome_admission_error(Reason, S)
    end.

accept_role_submission(_From, _Change, _ReplyBindings, _TraceCtx,
                       S = #s{ready = false, ns = Ns}) ->
    {reply, {error, {ontology_rebuilding, Ns}}, S};
accept_role_submission(
  From, Change0 = #transaction{author = none, author_seq = 0, sig = none},
  ReplyBindings, TraceCtx,
  S = #s{ns = Ns, self = Self, outcomes = Outcomes0, parked = Parked}) ->
    Target = {Ns, target_anchor(Ns)},
    Change = Change0#transaction{author = Self,
                                 submitted_at = quod_time:now_ms()},
    case quod_transaction:valid_id(Target, Change) andalso
         quod_transaction:role(Change) =/= application of
        true ->
            Ref = {transaction, Ns, target_anchor(Ns),
                   Change#transaction.tx_id},
            admit_bound_plan(
              From, Change, ReplyBindings, Change#transaction.diff,
              TraceCtx, Ref, Outcomes0, Parked, S);
        false ->
            {reply, {error, bad_transaction_role}, S}
    end;
accept_role_submission(_From, _Change, _ReplyBindings, _TraceCtx, S) ->
    {reply, {error, bad_transaction_role}, S}.

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
                          Plan,
                          Material#{foreign_reads =>
                                      Change#transaction.foreign_reads},
                          GoalBlob, ResultBlob,
                          Change#transaction.request_auth),
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
            {noreply, add_parked_waiter(
                        Tx, From, ReplyBindings,
                        S#s{outcomes = Outcomes1})};
        {pending, Outcomes1} ->
            park_existing_plan(
              From, Change, ReplyBindings, [], TraceCtx,
              S#s{outcomes = Outcomes1});
        {new, Outcomes1} ->
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
                 #parked_write{waiters = [{From, ReplyBindings}],
                               height = S#s.applied, timer = TRef,
                               request_id = none, span_ctx = SpanCtx,
                               started = T0}},
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
                               ignored, ignored, ignored, ignored, none,
                               [], [], otel_ctx:new(),
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
        quod_effect:validate_plan(Plan, Material) orelse
            throw(invalid_direct_effect),
        {ok, _Goal} = quod_durable_term:decode_goal(GoalBlob),
        {ok, _DurableResult} = quod_durable_term:decode_result(ResultBlob),
        {ok, Material}
    catch
        error:{badmatch, {error, Reason}} -> {error, Reason};
        throw:Reason -> {error, Reason};
        _:_ -> {error, bad_plan}
    end.

self_witnessed(none, Self) ->
    not (is_binary(Self) andalso byte_size(Self) =:= 32);
self_witnessed(<<_:256>> = Signer, Signer) ->
    true;
self_witnessed(_Signer, _Self) ->
    false.

submit_plan_envelope(From, Plan, Material, GoalBlob, ReplyBindings, ResultBlob,
                     RequestAuth, ForeignReads, TraceCtx,
                     S = #s{ns = Ns, outcomes = Outcomes0,
                            parked = Parked}) ->
    Anchor = target_anchor(Ns),
    Change0 = quod_transaction:from_plan(
                Plan, Material#{foreign_reads => ForeignReads},
                GoalBlob, ResultBlob, RequestAuth),
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
            {noreply, add_parked_waiter(
                        Tx, From, ReplyBindings,
                        S#s{outcomes = Outcomes1})};
        {pending, Outcomes1} ->
            park_existing_plan(
              From, Change, ReplyBindings, Diff, TraceCtx,
              S#s{outcomes = Outcomes1});
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

test_dtx_handoff_state(Ns, WorkerSpecs, RequestSpecs) ->
    Workers = maps:from_list(
                [begin
                     Worker = #proof_worker{
                                 pid = WorkerPid, kind = prove,
                                 from = {self(), make_ref()},
                                 worker_mref = make_ref(),
                                 caller_mref = make_ref(),
                                 timer = make_ref(), token = make_ref(),
                                 deadline_ms = quod_time:mono_ms() + 5000,
                                 handoff = #dtx_handoff{
                                              intent_id = IntentId,
                                              registration_from =
                                                  RegistrationFrom,
                                              group_ref = GroupRef,
                                              state = HandoffState}},
                     {Ref, Worker}
                 end
                 || {Ref, WorkerPid, IntentId, RegistrationFrom,
                     GroupRef, HandoffState} <- WorkerSpecs]),
    Requests = lists:foldl(
                 fun({RequestId, Ref}, Acc) ->
                         gen_statem:reqids_add(
                           RequestId, {dtx_handoff, Ref}, Acc)
                 end, gen_statem:reqids_new(), RequestSpecs),
    #s{ns = Ns, workers = Workers, requests = Requests}.

test_handle_response_info(Info, S) ->
    handle_response_info(Info, S).

test_cancel_dtx_handoff(Ref, S) ->
    cancel_dtx_handoff(Ref, S).

test_activate_dtx_handoff(Ref, Pid, GroupRef, S) ->
    activate_dtx_handoff(Ref, Pid, none, GroupRef, S).

test_fill_dtx_activation_capacity(S) ->
    S#s{max_proof_workers = 1, waiting_workers = #{full => occupied}}.

test_dtx_handoff_summary(#s{workers = Workers, requests = Requests}) ->
    Handoffs = maps:fold(
                 fun(Ref,
                     #proof_worker{
                        handoff = #dtx_handoff{
                                     intent_id = IntentId,
                                     registration_from = RegistrationFrom,
                                     state = State}}, Acc) ->
                         Acc#{Ref =>
                                  #{intent_id => IntentId,
                                    registration_pending =>
                                        RegistrationFrom =/= none,
                                    state => State}};
                    (_Ref, #proof_worker{handoff = none}, Acc) -> Acc
                 end, #{}, Workers),
    #{handoffs => Handoffs,
      request_labels =>
          lists:sort(
            [Label || {_RequestId, Label} <-
                          gen_statem:reqids_to_list(Requests)])}.

test_active_operation(Operation, WorkerOperations, WaitingOperations) ->
    Workers = worker_operations(WorkerOperations),
    Waiting = worker_operations(WaitingOperations),
    active_operation(Operation, #s{workers = Workers,
                                   waiting_workers = Waiting}).

test_inflight_public_reply(
  {{AgentRef, OperationId} = Key, Digest, OperationRef})
  when is_binary(AgentRef), is_binary(OperationId), is_binary(Digest) ->
    Evidence = #{request => #{mode => execute, operation_id => OperationId},
                 agent_ref_blob => AgentRef,
                 request_digest => Digest,
                 operation_ref => OperationRef},
    Request = #proof_request{request_evidence = Evidence},
    Worker = #proof_worker{
               pid = self(), operation = {Key, Digest, OperationRef}},
    CallRef = make_ref(),
    {noreply, _} = admit_public_proof(
                     prove, true, {async, self(), CallRef}, Request,
                     #s{workers = #{make_ref() => Worker},
                        max_proof_workers = 1}),
    receive
        {quod_proof_reply, _Engine, CallRef, Reply} -> Reply
    after 0 ->
        error(no_inflight_reply)
    end.

worker_operations(Operations) ->
    maps:from_list(
      [{make_ref(), #proof_worker{pid = self(), operation = Operation}}
       || Operation <- Operations]).
-endif.

park_existing_plan(From, Change, ReplyBindings, Diff, TraceCtx,
                   S = #s{ns = Ns}) ->
    Tx = Change#transaction.tx_id,
    {_TransactionCtx, SpanCtx} = quod_trace:start_span(
                                   TraceCtx, <<"quod.transaction">>, internal,
                                   #{'quod.namespace' => Ns,
                                     'quod.tx.id' => quod_trace:tx_id(Tx),
                                     'quod.kb.read_height' => S#s.applied,
                                     'quod.diff.operations' => length(Diff)}),
    TRef = erlang:send_after(S#s.ttl, self(), {park_timeout, Tx}),
    Row = #parked_write{waiters = [{From, ReplyBindings}],
                        height = S#s.applied, timer = TRef,
                        span_ctx = SpanCtx, started = quod_time:mono_ms()},
    {noreply, S#s{parked = (S#s.parked)#{Tx => Row}}}.

add_parked_waiter(Tx, From, ReplyBindings, S = #s{parked = Parked}) ->
    case maps:get(Tx, Parked) of
        Row = #parked_write{waiters = Waiters} ->
            S#s{parked = Parked#{Tx =>
                    Row#parked_write{
                      waiters = [{From, ReplyBindings} | Waiters]}}}
    end.

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
            Requests1 = gen_statem:reqids_add(
                          ReqId, {append, Tx}, S#s.requests),
            TRef = erlang:send_after(S#s.ttl, self(), {park_timeout, Tx}),
            %% T0 anchors the tx-latency histogram: same node, same monotonic clock
            %% as the observation in release/4 — never a cross-node wall-clock delta.
            T0 = quod_time:mono_ms(),
            S1 = S#s{parked = (S#s.parked)#{Tx =>
                       #parked_write{
                         waiters = [{From, ReplyBindings}],
                         height = S#s.applied, timer = TRef,
                         request_id = ReqId, span_ctx = SpanCtx,
                         started = T0}},
                     requests = Requests1},
            {noreply, S1}
    catch
        error:badarg ->
            quod_trace:finish_span(SpanCtx, {error, consensus_unavailable}),
            {reply, {error, consensus_unavailable},
             discard_unsubmitted(Tx, S)}
    end.

%% The outer wire decoder has only bounded the four opaque blobs. Decode the
%% plan after scope authentication because its proof/origin identity is needed
%% for this command; accept_plan_submission remains the shared local/remote
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

reply_parked_waiters(Waiters, Reply) ->
    lists:foreach(fun({From, _Bindings}) -> reply_parked(From, Reply) end,
                  Waiters).

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
        Row = #parked_write{} ->
            S#s{parked = Parked#{Tx =>
                   Row#parked_write{request_id = none}}};
        undefined ->
            S
    end.

mark_consensus_reply(Tx, Slot, S = #s{parked = Parked}) ->
    case maps:get(Tx, Parked, undefined) of
        #parked_write{span_ctx = SpanCtx} ->
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
%% Caller completions and outcome events are buffered through the fold. The
%% canonical reducer flushes the outcome index and publishes the MVCC version
%% before returning them. A successful API reply can therefore be followed
%% immediately by a terminal outcome lookup or a read of the committed state.
%% All envelopes in a block share that block-final snapshot.
apply_step(#entry{index = Index} = Entry, Origin, S0) ->
    Projection0 = committed_projection(S0),
    Floor = oldest_snapshot(Index, S0),
    case quod_committed_projection:apply_entry(Entry, Floor, Projection0) of
        {ok, Projection1, Result} ->
            finish_projection_result(
              Result, Index, Origin,
              install_committed_projection(Projection1, S0));
        {wait, network_identity, Reason, Projection1} ->
            wait_for_apply_dependency(
              Reason, install_committed_projection(Projection1, S0));
        {error, {outcome_index, Reason}} ->
            outcome_index_failure(Reason);
        {error, {predicate_modules_unavailable, Reason}} ->
            predicate_modules_unavailable(Reason, S0);
        {error, Reason} ->
            error(Reason)
    end.

committed_projection(
  #s{ns = Ns, applied = Applied, est = Est,
     outcomes = Outcomes, signer = Signer}) ->
    quod_committed_projection:new(
      {Ns, target_anchor(Ns)}, Applied, Est, Outcomes, Signer).

install_committed_projection(Projection, S) ->
    S#s{applied = quod_committed_projection:applied(Projection),
        est = quod_committed_projection:est(Projection),
        outcomes = quod_committed_projection:outcomes(Projection),
        projection_failure = none}.

predicate_modules_unavailable(
  Reason, S = #s{ns = Ns, projection_failure = Previous}) ->
    case Previous =:= Reason of
        true -> ok;
        false ->
            logger:error(
              "quod_prolog[~s]: genesis predicate modules unavailable: ~0p",
              [Ns, Reason])
    end,
    S#s{ready = false,
        projection_failure = Reason}.

finish_projection_result(
  #{kind := content, transactions := Results, stats := Stats},
  Index, Origin, S0) ->
    S1 = add_projection_stats(Stats, S0),
    complete_transactions(
      [content_post_apply(Result, Index, Origin, S1) || Result <- Results],
      S1);
finish_projection_result(
  #{kind := dtx_batch, items := Items, stats := Stats},
  Index, Origin, S0) when is_list(Items), Items =/= [] ->
    S1 = add_projection_stats(Stats, S0),
    S2 = lists:foldl(
           fun(#{control := Control, group_id := GroupId,
                 publication := Publication, applied_ops := AppliedOps,
                 deferred_ack := DeferredAck}, Acc0) ->
                   Acc1 = publish_dtx_outcome(
                            Publication, AppliedOps, Index, Origin, Acc0),
                   Acc2 = finish_dtx_apply(
                            DeferredAck, Control, Origin, Acc1),
                   maybe_release_completed_group(Control, GroupId, Acc2)
           end, S1, Items),
    %% The journal remains the single custody owner. The complete canonical
    %% wave wakes reconciliation once after every per-control transition has
    %% been published and acknowledged.
    quod_effect_journal:reconcile(),
    S2;
finish_projection_result(#{kind := noop}, _Index, _Origin, S) ->
    S;
finish_projection_result(
  #{kind := unexpected, payload := Payload}, Index, _Origin,
  S = #s{ns = Ns}) ->
    logger:warning(
      "quod_prolog[~s]: skipping unexpected committed payload at ~p: ~0p",
      [Ns, Index, Payload]),
    S;
finish_projection_result(#{kind := already_applied}, _Index, _Origin, S) ->
    S.

content_post_apply(
  #{status := applied, change := Change, height := Height,
    applied_ops := AppliedOps},
  Index, Origin, S) ->
    #transaction{tx_id = Tx} = Change,
    notify_operation_projection(S#s.ns, Height, Change),
    {outcome_applied(Change, AppliedOps, Index, Origin, S),
     {committed, Tx, Height}};
content_post_apply(
  #{status := rejected, change := Change, reason := Reason,
    height := Height}, Index, Origin, S) ->
    #transaction{tx_id = Tx} = Change,
    notify_operation_projection(S#s.ns, Height, Change),
    {outcome_rejected(Change, Index, Origin, S),
     {rejected, Tx, Reason, Height}};
content_post_apply(
  #{status := duplicate_committed, change := #transaction{tx_id = Tx},
    height := Height}, _Index, _Origin, _S) ->
    {none, {committed, Tx, Height}};
content_post_apply(
  #{status := duplicate_rejected, change := #transaction{tx_id = Tx},
    reason := Reason}, _Index, _Origin, _S) ->
    {none, {rejected, Tx, Reason}}.

notify_operation_projection(
  Ns, Height, #transaction{role = {remote_claim, _, _, _}} = Change) ->
    quod_simplex:operation_projection(Ns, Height, Change);
notify_operation_projection(
  Ns, Height, #transaction{role = {remote_complete, _, _, _}} = Change) ->
    quod_simplex:operation_projection(Ns, Height, Change);
notify_operation_projection(_Ns, _Height, #transaction{}) ->
    ok.

add_projection_stats(
  #{applies := Applies, rejects := Rejects, conflicts := Conflicts},
  S = #s{applies = A0, rejects = R0, conflicts = C0}) ->
    S#s{applies = A0 + Applies, rejects = R0 + Rejects,
        conflicts = C0 + Conflicts}.

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

%% The coordinator reaches this boundary only after every participant's
%% Finalize is certified applied.  Complete is still appended by that same
%% coordinator, but it is recovery bookkeeping rather than a reason to keep a
%% live caller parked.  The exact GroupRef and waiter map make duplicate
%% notices (including one after a coordinator restart) harmless.
release_group_waiter_terminal(
  {group, _Ns, _Anchor, _Coordinator, _Admission, <<_:256>> = GroupId}
    = GroupRef,
  #{verdict := Verdict, reasons := Reasons,
    decision_slot := DecisionSlot, participant_slots := ParticipantSlots}
    = Terminal,
  S = #s{group_waiters = Waiters})
  when map_size(Terminal) =:= 4,
       (Verdict =:= commit orelse Verdict =:= abort),
       is_integer(DecisionSlot), DecisionSlot > 0 ->
    case {maps:get(GroupId, Waiters, undefined),
          valid_terminal_participant_slots(ParticipantSlots),
          valid_terminal_reasons(Verdict, Reasons)} of
        {#group_waiter{group_ref = GroupRef,
                       bindings = LiveBindings} = Waiter,
         true, true} ->
            Result =
                case Verdict of
                    commit ->
                        {ok, [LiveBindings],
                         #{ref => GroupRef, height => DecisionSlot,
                           participant_slots => ParticipantSlots}};
                    abort ->
                        {fail, Reasons}
                end,
            finish_group_waiter(
              GroupId, Waiter, Result, erlang:monotonic_time(), S);
        _ ->
            S
    end;
release_group_waiter_terminal(_GroupRef, _Terminal, S) ->
    S.

valid_terminal_participant_slots(Slots) ->
    valid_terminal_participant_slots(Slots, none, 0).

valid_terminal_participant_slots([], _Previous, Count) -> Count >= 2;
valid_terminal_participant_slots(
  [{{Ns, <<_:256>>} = Identity, Slot, Generation} | Rest], Previous, Count)
  when (Previous =:= none orelse Previous < Identity),
       is_binary(Ns), byte_size(Ns) > 0,
       is_integer(Slot), Slot > 0,
       is_integer(Generation), Generation >= 0 ->
    valid_terminal_participant_slots(Rest, Identity, Count + 1);
valid_terminal_participant_slots(_Malformed, _Previous, _Count) -> false.

valid_terminal_reasons(commit, none) -> true;
valid_terminal_reasons(abort, [_ | _] = Reasons) ->
    case quod_wire_term:encode_failure_reasons(Reasons) of
        {ok, _} -> true;
        {error, _} -> false
    end;
valid_terminal_reasons(_Verdict, _Reasons) -> false.

release_group_waiter(
  GroupRef, S) ->
    release_group_waiter(GroupRef, erlang:monotonic_time(), S).

release_group_waiter(
  {group, _Ns, _Anchor, _Coordinator, _Admission, <<_:256>> = GroupId}
    = GroupRef,
  HandoffStarted,
  S = #s{group_waiters = Waiters, outcomes = Outcomes0}) ->
    case maps:get(GroupId, Waiters, undefined) of
        #group_waiter{group_ref = GroupRef,
                      bindings = LiveBindings} = Waiter ->
            case quod_outcome:lookup_ref(Outcomes0, GroupRef) of
                {{ok, Stored}, Outcomes1} ->
                    case quod_outcome:public(Stored) of
                        {ok, #{status := committed,
                               height := Height,
                               bindings := _DurableBindings,
                               participant_slots := Slots}} ->
                            finish_group_waiter(
                              GroupId, Waiter,
                              {ok, [LiveBindings],
                               #{ref => GroupRef, height => Height,
                                 participant_slots => Slots}},
                              HandoffStarted,
                              S#s{outcomes = Outcomes1});
                        {ok, #{status := aborted, reasons := Reasons}} ->
                            finish_group_waiter(
                              GroupId, Waiter, {fail, Reasons},
                              HandoffStarted,
                              S#s{outcomes = Outcomes1});
                        {ok, #{status := pending}} ->
                            S#s{outcomes = Outcomes1};
                        {error, Reason} ->
                            error({outcome_index_unavailable, Reason})
                    end;
                {not_found, Outcomes1} ->
                    resolve_absent_group_waiter(
                      GroupId, GroupRef, Waiter,
                      HandoffStarted,
                      S#s{outcomes = Outcomes1});
                {wrong_anchor, _Outcomes1} ->
                    error({outcome_index_unavailable, wrong_anchor});
                {{error, Reason}, _Outcomes1} ->
                    error({outcome_index_unavailable, Reason})
            end;
        _ ->
            S
    end;
release_group_waiter(_BadRef, _HandoffStarted, S) ->
    S.

resolve_absent_group_waiter(
  GroupId, GroupRef, Waiter, HandoffStarted,
  S = #s{ns = Ns, applied = AppliedFloor}) ->
    case quod_simplex:dtx_group_barrier(Ns, GroupRef, AppliedFloor) of
        {ok, pending} ->
            S;
        {ok, not_found} ->
            finish_group_waiter(
              GroupId, Waiter, {error, not_found}, HandoffStarted, S);
        {ok, {rejected, coordinator_retired}} ->
            finish_group_waiter(
              GroupId, Waiter, {error, coordinator_retired},
              HandoffStarted, S);
        {error, _UnavailableOrUnknown} ->
            S
    end.

finish_group_waiter(
  GroupId,
  #group_waiter{from = From, caller_mref = CallerMRef, timer = Timer,
                started_native = StartedNative},
  Result, HandoffStarted, S = #s{group_waiters = Waiters}) ->
    _ = erlang:cancel_timer(Timer),
    demonitor(CallerMRef, [flush]),
    ResultLabel = dtx_waiter_result(Result),
    quod_metrics:observe_dtx_group_stage(
      S#s.ns, end_to_end, ResultLabel,
      erlang:monotonic_time() - StartedNative),
    reply_client(From, Result),
    quod_metrics:observe_dtx_group_stage(
      S#s.ns, result_handoff, ResultLabel,
      erlang:monotonic_time() - HandoffStarted),
    S#s{group_waiters = maps:remove(GroupId, Waiters)}.

dtx_waiter_result({ok, _Solutions, _Handle}) -> ok;
dtx_waiter_result({error, _}) -> failed;
dtx_waiter_result({fail, _}) -> rejected.

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
                group_ref = GroupRef,
                started_native = erlang:monotonic_time(), bindings = #{}},
    S0 = #s{ns = Ns, outcomes = Outcomes,
            applied = quod_outcome:applied_floor(Outcomes),
            group_waiters = #{GroupId => Waiter}},
    S1 = release_group_waiter(GroupRef, S0),
    {CallRef, map_size(S1#s.group_waiters)}.
-endif.

finish_dtx_apply(none, _Control, _Origin, S) ->
    S;
finish_dtx_apply(
  {finalize_applied, GroupId, Slot, Generation}, _Control, _Origin,
  S = #s{ns = Ns}) ->
    ok = quod_simplex:finalize_applied(Ns, GroupId, Slot, Generation),
    S.

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

%%%===================================================================
%%% post-apply runtime publication layer (doc/agent-fipa-plan.md §7)
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
%% reaction/runtime source (it fires before this kb has applied).
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

%% One publication per ordinary material committed transaction on a LIVE commit
%% only — never replay. The requested diff remains a conservative state-handler
%% invalidation hint; reactions consume only the canonical reducer's applied_ops.
%% Direct effects and identifiers share the same envelope; goal/result remain
%% canonical ledger blobs decoded lazily only by a detail reader. Genesis is not
%% a reaction occurrence.
outcome_applied(#transaction{plan_digest = none}, _AppliedOps,
                _Index, _Origin, _S) -> none;
outcome_applied(#transaction{role = Role}, _AppliedOps,
                _Index, _Origin, _S)
  when element(1, Role) =:= remote_claim;
       element(1, Role) =:= remote_complete ->
    none;
outcome_applied(#transaction{tx_id = Tx, diff = Diff, effects = Effects},
                AppliedOps, Index, live, #s{ns = Ns}) ->
    {applied, #{ns => Ns, height => Index, tx_id => Tx, subject => undefined,
                diff => Diff, applied_ops => AppliedOps,
                effects => Effects}};
outcome_applied(_Change, _AppliedOps, _Index, replay, _S) -> none.

%% One event per committed-but-OCC-rejected transaction, on a LIVE commit only. Mirrors
%% `outcome_applied` so every live tx in a block yields exactly one outcome event (applied or
%% rejected); D is unchanged, so the envelope carries no diff/result.
outcome_rejected(#transaction{role = Role}, _Index, _Origin, _S)
  when element(1, Role) =:= remote_claim;
       element(1, Role) =:= remote_complete ->
    none;
outcome_rejected(#transaction{tx_id = Tx, effects = Effects},
                 Index, live, #s{ns = Ns}) ->
    {rejected, #{ns => Ns, height => Index, tx_id => Tx,
                 subject => undefined, effects => Effects}};
outcome_rejected(_Change, _Index, replay, _S) -> none.

%% Complete each transaction in block order after the block snapshot is
%% published. The caller is released first; event consumers then see the same
%% already-committed state.
complete_transactions([], S) -> S;
complete_transactions([{Publication, Completion} | Rest], S0) ->
    S1 = complete_transaction(Completion, S0),
    complete_transactions(Rest, publish_outcome(Publication, S1)).

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
publish_dtx_outcome(none, _AppliedOps, _Index, _Origin, S) ->
    S;
publish_dtx_outcome(
  {group_applied, _GroupId, _Context, [], []}, _AppliedOps,
  _Index, _Origin, S) ->
    S;
publish_dtx_outcome(
  {group_applied, GroupId,
   #{proof_id := ProofId, origin := ProofOrigin,
     principal := Principal, goal := Goal, result := Result,
     plan_digest := PlanDigest}, Diff, DirectEffects},
  AppliedOps, Index, live, S = #s{ns = Ns}) ->
    Env = #{ns => Ns, height => Index, tx_id => {group, GroupId},
            proof_id => ProofId, origin => ProofOrigin,
            subject => Principal, goal => Goal, result => Result,
            plan_digest => PlanDigest, diff => Diff,
            applied_ops => AppliedOps, effects => DirectEffects},
    publish_outcome({applied, Env}, S);
publish_dtx_outcome({group_applied, _, _, _, _}, _AppliedOps,
                    _Index, replay, S) ->
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
        {#parked_write{waiters = Waiters, height = H, timer = TRef,
                       request_id = ReqId, span_ctx = SpanCtx,
                       started = T0}, P1} ->
            _ = erlang:cancel_timer(TRef),
            _ = case Outcome of
                    {ok, {applied, _}} ->
                        quod_metrics:observe_tx_latency(Ns, quod_time:mono_ms() - T0);
                    _ ->
                        ok
                end,
            _ = set_final_trace_attributes(SpanCtx, Outcome),
            quod_trace:finish_span(SpanCtx, Outcome),
            lists:foreach(
              fun({From, B}) -> ReplyFun(From, B, H) end, Waiters),
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

abandon_request_label(Label, Requests) ->
    lists:foldl(
      fun({ReqId, Label0}, Acc) when Label0 =:= Label ->
              %% Cancellation owns this alias before Simplex is told to drop
              %% the intent. Consume an already-arrived reply or deactivate a
              %% future one, exactly as ordinary parked-request cleanup does.
              _ = catch gen_statem:receive_response(ReqId, 0),
              Acc;
         ({ReqId, Label0}, Acc) ->
              gen_statem:reqids_add(ReqId, Label0, Acc)
      end, gen_statem:reqids_new(), gen_statem:reqids_to_list(Requests)).

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

validation_position({dtx, _Controls, _BlockTimestamp}, Parent,
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

validation_verdict({content, Transactions, BlockTimestamp}, S) ->
    content_validation_verdict(Transactions, BlockTimestamp, S);
validation_verdict({dtx, Controls, BlockTimestamp}, S) ->
    dtx_validation_verdict(Controls, BlockTimestamp, check, S).

content_validation_verdict(Transactions, BlockTimestamp, S) ->
    commit_validation_result(
      quod_commit_validation:content(
        Transactions, BlockTimestamp, check,
        commit_validation_context(S)), S).

dtx_validation_verdict(Controls, BlockTimestamp, OperationMode, S)
  when is_list(Controls), Controls =/= [] ->
    case quod_dtx:canonical_control_wave(Controls) of
        true ->
            commit_validation_result(
              dtx_validation_wave(
                Controls, BlockTimestamp, OperationMode,
                commit_validation_context(S), #{}), S);
        false ->
            {{invalid, malformed_control}, S}
    end;
dtx_validation_verdict(_Malformed, _BlockTimestamp, _OperationMode, S) ->
    {{invalid, malformed_control}, S}.

dtx_validation_wave([], _BlockTimestamp, _OperationMode, Context, Histories) ->
    {ok, {valid, Histories}, Context};
dtx_validation_wave([Control | Rest], BlockTimestamp, OperationMode,
                    Context0, Histories0) ->
    case quod_commit_validation:dtx(
           Control, BlockTimestamp, OperationMode, Context0) of
        {ok, {valid, History}, Context1} ->
            GroupId = quod_dtx:group_id(Control),
            dtx_validation_wave(
              Rest, BlockTimestamp, OperationMode, Context1,
              Histories0#{GroupId => History});
        {ok, Verdict, Context1} ->
            {ok, Verdict, Context1};
        {outcome_error, _Reason} = Error ->
            Error
    end.

commit_validation_context(
  #s{ns = Ns, applied = Applied, est = Est,
     outcomes = Outcomes, signer = Signer}) ->
    quod_commit_validation:new(
      {Ns, target_anchor(Ns)}, Applied, Est, Outcomes, Signer).

commit_validation_result({ok, Verdict, Context}, S) ->
    {Verdict,
     S#s{outcomes = quod_commit_validation:outcomes(Context)}};
commit_validation_result({outcome_error, Reason}, _S) ->
    %% Projection corruption/unavailability is never an ordinary invalid
    %% proposal: fail the owner so replay can rebuild the authoritative index.
    outcome_index_failure(Reason).

wait_for_apply_dependency(Reason, S = #s{apply_dependency = none}) ->
    logger:warning(
      "committed record is waiting for root network identity: ~0p",
      [Reason]),
    wait_for_network_identity(
      begin_dependency_replay(S#s{ready = false}));
wait_for_apply_dependency(_Reason, S) ->
    S.

begin_dependency_replay(
  S = #s{runtime_mode = live, ns = Ns, applied = Applied}) ->
    Id = make_ref(),
    publish_runtime(Ns, {replay_started, Id, Applied}),
    %% The runtime owns detaching its old MVCC pin after it has stopped every
    %% reader, exactly as for an ordinary catch-up replay.
    S#s{runtime_mode = {replaying, Id}};
begin_dependency_replay(S) ->
    S.

wait_for_network_identity(S) ->
    case quod_ontology:network_identity() of
        {ok, <<_:256>>} ->
            request_dependency_replay(S);
        {error, _} ->
            Monitor = quod_reg:monitor_name(
                        {quod_simplex, quod_ontology:root_ns()}, follow),
            S#s{apply_dependency = {network_identity, Monitor}}
    end.

resume_apply_dependency(
  S = #s{apply_dependency = {network_identity, Monitor}}) ->
    case quod_ontology:network_identity() of
        {ok, <<_:256>>} ->
            ok = quod_reg:demonitor_name(
                   {quod_simplex, quod_ontology:root_ns()}, Monitor),
            request_dependency_replay(S#s{apply_dependency = none});
        {error, _} ->
            S
    end.

request_dependency_replay(S = #s{ns = Ns}) ->
    %% `rebuild/1` is an asynchronous cast.  The ledger remains the only queue;
    %% this process retains no committed entry while waiting or replaying.
    ok = quod_simplex:rebuild(Ns),
    S#s{apply_dependency = none}.

%% Async delivery to the requesting statem (or a test pid) — a plain message so
%% the statem consumes it as an `info` event and a test can receive it directly.
deliver_validation({content, _Transactions, _BlockTimestamp},
                   ReplyTo, Tag, Verdict, _S) ->
    ReplyTo ! {content_verdict, Tag, Verdict},
    ok;
deliver_validation({dtx, _Controls, _BlockTimestamp}, ReplyTo, Tag, Verdict,
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
    Base = quod_committed_projection:new_est(),
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
    quod_committed_projection:read_terms(File).
