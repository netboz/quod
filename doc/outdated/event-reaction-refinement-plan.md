# Events, reactions, and recovery

Status: implemented in the working tree. Stored-policy migration and coordinated
activation remain deployment prerequisites. The contracts below replace the
unsafe physical-node reaction dispatch and reaction-driven resource restoration.
Validation evidence is recorded in `WORK-IN-PROGRESS.md`.
Existing installations need explicit updates of their stored declarations;
changing a source file does not rewrite an ontology's history.

`inter-ontology.md` governs proof, authorization, transactions and recovery.
`ontology-actor-architecture.md` governs identity and hosting.
`prolog-editing-plan.md` records the live-code-editing contract.

## 1. One reaction concept

A reaction is an ordinary Prolog goal owned by an agent:

```prolog
react_on(assert(task_ready(Agent, Task)), handle_task(Task)) :-
    me(agent_instance_ref(_, _, Agent)),
    instance_of(ConcreteClass, Agent),
    isa(ConcreteClass, task_worker).
```

The head's two arguments are the event pattern and goal. The clause body
selects the owning agent and conditions. `me/1` observes the current owned
actor during matching; during the submitted goal it observes the authenticated
principal. An event's author never becomes the reaction's principal.
Class eligibility uses ordinary Prolog relations, including transitive `isa/2`.
Each originating clause executes at most once per event and owned agent even
when its guard has several successful inheritance paths. Different clauses may
all match. Stored clause order is retained; term sorting is not execution order.

The existing runtime matches a pattern through Erlog unification on its
committed view. Shared variables bind the goal. Matching and eligibility are
read-only and grant no proof authority. The resulting goal enters that actor's
existing request queue, normal proof and `can_invoke/4` checks. It may stage
ordinary writes, use actions and commit across ontologies through existing
transactions. There is no special submission predicate or second executor.
A failed guard prepares no key and submits no request.

Ordinary reactions receive current hosted-agent bindings for their exact
containing ontology, independently of event origin. No eligible agent means
no submitted goal; several eligible agents may each react. They share that
ontology's editable program, not isolated per-agent code. The catalogue reads
locally authored `react_on/2` clauses; class eligibility does not automatically
enumerate remote inherited reaction declarations.

Only the current local host owns an ordinary agent's queue. Its epoch, active
key and exact ontology reference are rechecked before signing. The logical node
receives a binding only in its own behavior scope, from the existing verified
node pointer and signer; it needs no artificial `agent_host/4` row. Neither
local readiness nor host observations grant node authority to another ontology's
catalogue. Neither dispatch path selects a physical-node audience or automatically
executes a foreign reaction as the logical node. Bootstrap restores typed resources
through their existing owners as described below, without arbitrary goals.

## 2. Events come from canonical application

The source is the reducer's ordered `applied_ops`, not a requested diff or an
announcement that consensus has committed something not yet applied.

| Applied operation | Public event |
| --- | --- |
| Append a plain fact (`assert`) | `assert(Fact)` |
| Prepend a plain fact (`asserta`) | `assert(Fact)` |
| Remove a plain fact | `retract(Fact)` |
| Explicit `{event, Term}` | `Term` |

An already-present assertion or absent retraction changes nothing and emits
no fact event. Rule changes are not disguised as plain-fact assertions.
The runtime receives their changed heads for current-state recovery and their
catalog changes from the same canonical application.

`trigger_event(Term)` stages a ground occurrence in the normal diff without
asserting a message fact. Explicit identical occurrences are not deduplicated.
The shared validation owner rejects reserved `assert/1`, `retract/1` and
`from/3` wrappers as explicit payloads. A user-authored term also cannot become
an owner-authenticated runtime notice merely by resembling one.

The overlay is a final-state differ. It preserves clause ordering through
explicit prepend operations, removes cancelled staged writes, then appends
explicit events in `trigger_event/1` call order. It does not claim to preserve
the chronology of every intermediate `assert` and `retract` call. There is one
signed operation list and one canonical reducer, not another event log.
Rejected or aborted transactions emit nothing. DTX participants publish their
consequence once through ordinary final application.

## 3. Live declaration changes

`react_on/2` and subscription declarations are ordinary editable Prolog code.
There is no founding comparison, per-declaration authority database or
`can_declare_runtime` permission. Existing invocation and write authority govern
the editing goal before its changes can take effect.

For transaction T:

1. Match its events with the declaration catalog installed before T.
2. Install T's catalog change for subsequent transactions.
3. Process T+1 using that catalog, including when both are in the same block.

The canonical apply path supplies transaction boundaries and catalog changes.
Unchanged transactions do not rebuild the catalog or read history. A removed
reaction cannot match later events, but removal does not cancel already matched
or submitted work. Adding a reaction and emitting an event in the same
transaction does not retroactively activate the new reaction for that event.

Matching a notification does not acquire a historical proof snapshot. The
queued goal executes on its ordinary current snapshot, with the usual read-set
conflict checks. Matched values are carried forward; the surrounding world may
have changed. There is no global execution order across independent actors or
ontologies.

## 4. Restore resources through existing owners

Replaying history restores ontology state; it does not rerun old occurrences.
Initial attachment, owner restart and relevant committed changes drive the same
existing typed resource worker. It evaluates fixed committed Prolog selectors
directly, without selecting an editable goal to execute as the physical node.
Starting an agent cannot require that agent to be running already.

| Governing scope | Current Prolog selector | Existing owner |
| --- | --- | --- |
| Exact containing ontology | `agent_hosting_projection/4` | Runtime's hosted agents |
| Exact containing ontology | `agent_observation_projection/4` | Host observer |
| Installed node's exact ontology | `node_ontology_hosting_projection/2` | Node actor, namespace manager and directory |
| Configured root identity | `effect_custody_capacity/1` | Effect journal |
| Hosted agent's exact containing ontology | `agent_work_goal/5` | Existing work cursor and that agent's signed queue |

Selection uses the existing restricted `policy_verdict` context over a committed
snapshot. It cannot write, sign, call foreign ontologies or perform runtime I/O.
Installation validates governing identity and resource scope; selecting rows never
grants access to another resource owner. Placement, eligibility and budgets remain
Prolog policy. An absent optional selector is inactive, with its absence retained
as a dependency. A successful empty inventory may remove resources within its
scope. Failure of a required selector remains visible, never an installed empty
inventory or proof of readiness. No eligible work is a normal idle result;
invalid or ambiguous custody capacity is an error. Root-owned capacity can be
restored before the logical node exists.

`agent_work_goal/5` may return a goal because it enters the selected agent's own
signed queue. At agent installation and relevant invalidation, the existing work
owner evaluates this generic selector, including when it or its opt-in policy
is absent. FIPA needs no Erlang-specific discovery or second inventory. Retain
its finite cursor and snapshot of earlier custody references; new attempts must
not replenish their own recovery wait set.

Readiness comes from actual installation, owner reattachment, custody changes
or queue capacity. Notices identify exact scope and owner incarnation. Preserve
subscription/snapshot ordering, cancellation and absolute deadlines; stale or
duplicate notices are harmless. Coalesce current-state invalidations in the
existing ordered work without replaying events or resubmitting uncertain goals.

### 4.1 Retain observed dependencies

`quod_observation:capture/3` supplies the shared observation collector used by
`quod_selection_basis` and `quod_resource_basis`. The latter classifies local
resource dependencies separately from consensus selection; consensus semantics
remain unchanged. Each resource consumer retains
only compact dependencies for its actual lifetime, not a copied KB or evaluator.
Local invalidation metadata remains distinct from transaction read tokens.

For `agent_work_goal/5`, retain the union of dependencies from every selection in
the current finite work pass, including its terminal idle selection. A later
cursor step must not discard a helper read by an earlier step. Check this whole
basis before admitting a selection. Retire it only when a new pass or agent
incarnation starts; completion, capacity and custody notifications continue the
same pass. The new pass captures its own basis, so obsolete helpers no longer
wake the agent once that pass becomes idle.

Capture reads across success, empty answers, failure, negation and backtracking,
including helper definitions, absent predicates, explicit `current_predicate/1`
and `predicate_property/2`, and predicate enumeration. MVCC already emits a
`predicate_registry` observation; reuse that support and invalidate membership
on relevant additions/removals. Do not pass a registry marker through the
predicate/arity-only transaction read-set filter or change internal type checks
into transaction reads. Initial precision is at predicate granularity.

Unknown native observations require sound classification or conservative
invalidation, never silent omission. Classify ordinary pure operations so the
normal selector path does not become an unconditional rebuild on every unrelated
commit. Resource selection captures execution errors as explicit outcomes inside
the collection boundary, preserving their diagnostic meaning and reads through
cleanup. A failed selection never installs an empty inventory.

If a persistent resource worker dies without returning, or its queued deadline
expires before selection, retain a conservative parent dependency. The next
committed change can select current policy; the full consumer selection replaces
that fence with its reported basis and restores selective invalidation. For work,
replacement waits for a new pass, preserving earlier steps' dependencies. Captured
policy failures and exceptions keep their observed dependencies. This neither
retries on a timer nor preserves an
occurrence-bound recovery or custody request for replay.

Account for commits occurring during selection before publishing an answer as
current. Track committed height advances independently of changed predicates,
both in queued input before installation and after input processing. A rejected
transaction or control-only block can advance height without changing facts.
Such advances invalidate context-dependent or conservatively classified consumers;
precise predicate-only consumers remain asleep. Duplicate heights do not create
an advance. Relevant changes wake the affected consumer; unchanged notices do not
repeat selection, installation, history reads or disk writes. Owner-incarnation
changes use the same restoration path and invalidate obsolete in-flight results.

### 4.2 The affected ontology supplies recovery data

The existing worker in affected ontology S evaluates `agent_recovery_data/10`
from `agent_recovery_policy.pl` in the restricted context. This is the one Prolog
calculation of report sequence, expiry and preparation need. Reaction guards
cannot query another ontology; they do not perform that selection in N's scope.

The temporary result describes the full target `agent_instance_ref/3`, expected
assignment, expected/current recovery round, report sequence, expiry and whether
custody preparation is needed. It contains no executable goal. Authenticated
inputs include the observer, target identity, original host/epoch, observation
identity and kind, producer incarnation, observation time and validity bound.
The runtime binds the answer to that owned observation; editable selector code
cannot replace those inputs, widen validity or retarget preparation. Pass verified
inputs explicitly; do not reintroduce live bridges into the restricted selector.

Capture the existing request-timeout allowance before selection and bound it by
observation validity. Retain both signed wall-clock expiry and the original
absolute monotonic deadline through selection, delivery, node matching, queueing,
preparation and signing. Policy may narrow either allowance; recomputing remaining
wall-clock time can only shorten the monotonic bound, never renew it. Report
expiry and signed request expiry must be identical, as `report_agent_failure`
requires. An expired or superseded selection is not silently rebased onto another
assignment, sequence or round. It cannot authorize another attempt at an unknown
operation; a fresh observation retains the existing recovery rules.

Deliver the validated data to logical node N's own behavior scope through existing
owner messages as `observed(agent_recovery_ready(...))`. Its trusted handler
calls `recovery_observation/1` to unify that data with the runtime's private,
authenticated observation metadata. An identical public event term lacks that
metadata and cannot activate the recovery handler. `me/1` alone does not prove
the event's source. The handler constructs `report_agent_observation/7`
or `report_agent_observation_with_custody/8` and uses the existing signed queue and
`node_authorized_goal/3`. Use `prepare_agent_and_converge/5` only for an explicit
preparation workflow. The runtime submits N's selected local goal unchanged;
only trusted Prolog constructs the wrapper around a permitted foreign operation.

The private handoff carries compact producer/contact evidence, not another copy
of the batch's instance bindings. Before each recovery reaction candidate, the
node runtime rechecks the current source-runtime owner, transport incarnation,
directory-contact owner/generation, exact installed node reference and both time
bounds. These are local owner checks, not a new proof or network query. Valid
receipts received during this node-runtime incarnation's first attachment remain
in its existing bounded queue until the committed baseline is available, then
undergo the same checks. Restart/replay never restores an old receipt.

The source's receipt cursor has a one-shot timer at the retained deadline.
Consumption, destination-owner death or reset releases its monitor and timer;
expiry releases only that unsent-evidence cursor. It neither retries a report nor
cancels an admitted request or changes an uncertain operation's recovery owner.
Stale receipts and timer messages cannot release a different cursor.

The final transaction rechecks S's assignment, permissions, report sequence and
expiry; report, candidate publication and convergence stay one transition.
Thresholds, candidate ranking, epoch advancement and old-key revocation retain
their existing Prolog actions. A failure observation is evidence for policy, not
proof of physical death; recovery requires surviving ontology availability and
commit quorum.

### 4.3 Generic reaction metadata belongs to the runtime bridge

`current_request_expiry/1`, `limit_reaction_expiry/1`, `prepare_agent_custody/3`
and `recovery_observation/1` belong to the existing universal
`quod_runtime_predicates` bridge, with no duplicate agent-module registrations.
`current_request_expiry/1` exposes authenticated proof metadata outside matching;
the other three require reaction context. Hidden variables retain ordinary
cut/backtracking behavior. `recovery_observation/1` authenticates the complete
selected event against its private metadata; it does not accept a caller's
assertion that an observation is genuine.

`prepare_agent_custody(TargetRef, OldEpoch, Result)` takes the full anchored
reference, not an instance inferred from the matching ontology. Validate it
against the owned observation and current logical-node binding. Matching only
describes preparation; it neither prepares custody nor releases a signature.
The existing node worker validates custody eligibility in the restricted
committed-policy context with explicit inputs, then invokes the existing vault
under the original deadline. Keep current-node checks, stable preparation and
the ordinary final transaction's assignment checks. A read-only proof alone is
not a sufficient restriction for eligibility: governed queries may sign.

Signing, active-key checks and vault operations retain their existing owners
and governed bridges. Moving only generic metadata avoids adding an agent module
to the node's immutable founding manifest. Verify registry loading and replay
with the existing manifest during the coordinated release; do not retain duplicate
registrations or a fallback to source-derived target identity.

### 4.4 Node privileges require a direct calling context

N keeps one authenticated principal throughout its proof. `S::Goal` changes the
ontology, not the actor. Restrict privileges granted specifically to N using the
existing `can_invoke(Goal, Principal, CallChain, TargetNamespace)` policy.

| Call | Required policy |
| --- | --- |
| N's own handler in its ontology O_N | Permit its authorized operations with direct context `[O_N]`. |
| N calls a recovery operation in S | N constructs the request; `can_execute_for/3`, S's entry policy and action prerequisites authorize it. |
| N calls privileged target T directly | Require T's explicit grant to N's exact anchored identity and direct context `[O_N]`. |
| S calls O_N or T while acting as N | Do not grant node privileges through `[S, O_N]`. |
| S calls intermediary C, then T | Do not grant node privileges through `[C, S, O_N]`. |
| S returns a term | Treat it as data, never arbitrary code to execute after returning. |

N's handlers, operation-construction helpers and their editors are trusted.
The initial policy permits no privileged foreign-helper exception. The active
path is not permanent provenance and ACLs do not guard every local helper.
Namespace-only path entries cannot establish trusted code incarnations; exact
principal/target checks remain required, and an anchor does not freeze editable
code. Inherited/shared definitions executed with privileges need the same editor
trust; no copied ontologies or new class-authorization lattice are introduced.

Restrict every successful alternative, not just one blanket clause:

- Node self permission, `host_ontology/4` entry and self-hosting permission,
  plus `request_ontology_hosting/5` entry and both policy branches.
- Root physical-node and administrator grants, public `create_ontology/3` entry,
  and physical-node, creator-agent and delegated `can_create_ontology/3` rules.
- Signature-release permission and any other target granting N privileges.
  Preserve exact signing scope, current assignment/key and explicit grants.

Root creation needs its contextual check at admission: `can_create_ontology/3`
does not receive the path, and public entry must not bypass the restriction.
Keep independently authorized public, non-node hosting and signup requests.
Distinguish physical `node(Key)` grants from logical node references; deleting
the unsafe reaction path does not require indiscriminate changes to bootstrap
or consensus policy.

Retain `node_authorized_goal/3` and its in-proof `can_execute_for/3` plus exact
source guard. It is not a sandbox around the permitted foreign implementation.
The node's own handler chooses the request; a foreign-only top-level signed goal
does not automatically consult the origin ACL. ACL bodies stay local and pure,
with existing committed dependencies and admission reproof.

## 5. Progress and resource readiness are distinct

The existing `effect_frontier/1` reports that canonical input has been processed
and its reaction work scheduled. It does not certify that every resource or
ordinary reaction goal has finished. The effect journal's create/join recovery
uses this existing input-progress boundary and its own committed postconditions
and prepared custody.

Waiting for every node reaction to finish before advancing that frontier would
deadlock: a reaction can commit a create/join action which itself waits for the
journal to pass the new frontier. Consumers that need an installed hosted agent,
contact projection or pending-work prerequisite wait for that actual owner's
notification instead. A later unrelated event cannot certify a failed resource
as installed. No shared state owner blocks on network I/O.

## 6. Subscriptions and reliability

Certified remote application uses the same event conversion, under the existing
`from(SourceNamespace, SourceAnchor, Event)` wrapper. The first materialized
baseline restores state without replaying occurrences. Later verified live
changes enter the subscriber's own current reaction catalog; publisher-side
callbacks or copied reaction knowledge bases are unnecessary.

Live reactions are notifications, not a durable event queue. Work that must
survive a crash is represented by domain facts or existing transaction/effect
custody. Internal FIPA state and receiver consequences use existing atomic
transactions. `fipa-pending-continuation-plan.md` defines the narrow authorized
policy for continuing a guarded pending conversation; it is not permission to
resubmit arbitrary unknown operations. External FIPA transport remains separate.

## 7. Verification and cost

Required checks cover live addition/change/removal, same-block activation,
clause order, inherited eligibility without duplicate firing, actual actor ACLs,
failed transactions, owner death, replay boundaries and host/key changes.
Readiness tests synchronize on real owner installation and cancellation, not
sleeps or sent-message traces. Unknown writes retain their exact outcome path.

Repeated unchanged reads/reconciliation must perform no history fold, projection
rebuild, ledger writes or syncs. Runtime input, active queues and existing worker
budgets remain governed by current resource policy. New language or editor work
does not authorize arbitrary queue ceilings, extended deadlines or weaker
consensus checks. Release evidence belongs in the work handoff and issue #9;
these invariants describe the correction target rather than a run diary.

## 8. Implementation and deployment sequence

1. Correct reaction ownership and the recovery-data contract in `quod_runtime`,
   `quod_runtime_predicates`, `quod_agent` and the existing Prolog policies.
   Promote the retained physical-node reproduction into a regression; cover both
   dispatch paths, zero/multiple actors, foreign helpers, callbacks, third targets,
   intermediary paths and every alternative hosting/creation grant. Verify normal
   direct node operations, non-node signup and hosted-agent signing still work.
2. Reuse dependency collection and direct typed restoration through the existing
   owners. Test absent, empty, failed and reflective selections; exception reads;
   policy changes during selection; root before node; owner restart; exact anchors
   and equal instance names in different ontologies. Bind recovery data to the
   authentic observation and test expiry equality across selection and queueing.
3. Integrate failover and finite FIPA continuation, then remove superseded physical
   dispatch branches, restoration reactions, manual head lists and registrations.
   Retain their still-valid tests on the replacement path. Measure unchanged
   repetitions through real owners for history reads, installation and disk I/O;
   verify actual updates and stale epoch/key rejection. Run focused tests first,
   then the required clean sequential gates on a frozen resulting tree.

Use the existing reaction, runtime, selection-basis, hosting, custody, node-actor
and failover suites. Preserve consensus observation behavior with its current
controls, and retain failed-run evidence and user-owned work.

Do not implement the actor document's future `subject/3` delegation model or
change reaction timing as part of this correction. Ordinary calls retain one
principal; FIPA acceptance and
conversation rules remain Prolog policy above generic Quod. Preserve the approved
guarded continuation exception and normal admission/revocation semantics.

### Stored-policy migration and cold activation

The source templates are founding inputs. Existing histories keep their stored
program until ordinary authorized editing transactions replace selected clauses.
Prepare a migration for each exact namespace and genesis anchor, including
customized definitions and any installed grants absent from the bundled sources.
This inventory is a review checklist, not permission to edit a live ledger:

| Governing identity | Definitions to compare and update |
| --- | --- |
| Each affected containing ontology | `agent_hosting_projection/4` and its scope helpers; `agent_observation_projection/4`; `agent_recovery_data/10` and report-selection helpers. Retain assignment, key, report, candidate and action-policy facts. |
| Each installed logical node's exact ontology | Direct-context `can_invoke/4` alternatives and `node_hosting_context/3`; `node_ontology_hosting_projection/2`; the authenticated recovery `react_on/2` clause and `node_recovery_goal/9`; narrowly scoped `can_execute_for/3`. Retain `node_authorized_goal/3`, node identity, keys, hosting and contact facts. |
| Configured root identity | `can_invoke/4`, `root_public_goal/1`, `root_creation_context/3` and `root_direct_context/3`; retain capacity policy and ordinary creation prerequisites. Check every physical-node, administrator, creator and delegated alternative. |
| Opted-in agent ontologies | The FIPA clause of `agent_work_goal/5` and its existing finite continuation helpers. Preserve other domains' clauses, opt-in facts, conversations and pending-operation references. |
| Other privileged targets | Every installed grant to the exact logical node principal, including signing entries. Apply the direct-context restriction to elevated grants while preserving independently authorized non-node callers. |

Remove only identified obsolete restoration declarations: the five old
`state_handler/4` duties, or their physical-node `react_on/2` replacements;
their dedicated `can_invoke/4` grants; manual notice/head-list helpers; and the
foreign host-observation reaction/goal constructor replaced by recovery data.
These predicates can contain unrelated user clauses. Never abolish all
`react_on/2`, `can_invoke/4`, `state_handler/4` or `agent_work_goal/5` clauses to
replace one component. Compare the complete ordered before/after definition,
replace only the approved clauses through the shared exact-edit path, and retain
unrelated clauses and their order. A baseline conflict requires a newly inspected
plan, not an overwrite or a blind retry.

Activation order is:

1. Inspect and prepare exact-baseline edits under each ontology's existing edit
   authority. Rehearse against retained histories and existing native manifests;
   source templates and a successful fresh genesis do not verify an upgrade.
2. Stop public ingress and quiesce admitted work where practical. Use the
   coordinated cold release in `ontology-actor-architecture.md`: stop every old
   validator, proof engine and runtime consumer before any new artifact joins.
   Retain all ledgers, anchors, keys and uncertain operation identities.
3. Restart on the same supported artifact and verify replay and universal bridge
   registration, including `recovery_observation/1`, against existing manifests.
   Keep ordinary traffic closed. Before enabling automatic recovery for a target,
   commit its direct-context grants and the node's trusted handler; install the
   affected ontology's typed selectors and recovery data in the same authorized
   maintenance sequence. Remove each superseded declaration with its replacement.
4. Read back the ordered definitions through normal proofs, verify intended
   resources and refusal controls, and resolve each migration's actual outcome.
   Related edits use one existing atomic transaction where required, including
   across ontologies. Resolve an unknown write by its original reference; never
   resubmit it. Reopen traffic only after the applicable release and retained-state
   acceptance checks pass.

No live migration is automatic. There is no wipe, re-founding, manifest rewrite,
rolling mixed-runtime interval or new migration executor. If a new native module
is actually required, its reviewed succession route must be settled separately.
