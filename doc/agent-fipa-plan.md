# Quod agents and FIPA -- architecture and implementation plan

**Status:** revised architecture direction. The runtime/reaction substrate,
explicit committed events, generic agent identity, and durable DTX effects are
delivered; acknowledged delivery, the durable agent outbox, agent hosting, and
later FIPA work remain pending. `ontology-actor-architecture.md` is the
authority for actor identity, system-ontology bootstrap, key ownership, and
hosting. It corrects this document's former Agent Platform record model: every
durable agent is a classed instance in ontology state and its optional Erlang
process is a rebuildable projection.
The current tree uses the generic stable agent reference; the former
`{user, Key}` label is not a supported identity or compatibility path.

This plan defines how users, agents, actions, runtime state, events, directories,
and FIPA communication should fit Quod's ontology-first architecture.

It deliberately does not preserve BBSvx or Onia implementation compatibility.
Their code is reference material: useful semantics are retained, but machinery
that conflicts with Quod's simpler architecture is replaced.

The normative inter-ontology rules remain in `doc/inter-ontology.md`.
Client projection, GUI, physics, and editable voxel worlds are recorded
separately in `doc/client-world-direction.md`. That document is a performance
forcing function for this substrate, not part of this plan's implementation
scope.

## 1. Objective

In Quod, the Prolog knowledge base is the durable description of reality.
Successful mutating proofs stage a concrete diff, and consensus decides whether
that diff becomes truth.

Runtime processes and external systems are not additional sources of durable
truth. They either:

1. provide an observation to a proof;
2. project committed facts into local runtime state; or
3. receive an irreversible effect after a live commit.

The implementation must make those three roles explicit and enforce when each
role may run.

The system ontology vocabulary includes `quod:node`, `quod:agent`, and
`quod:human_user`, discovered from root's committed system catalogue.
`quod:agent` defines the generic actor vocabulary; `quod:human_user` defines
the human-specific subclass. A concrete agent is a local instance in an
ontology, identified externally by that ontology's exact identity plus the
local instance name. Its optional hosted Erlang process is a rebuildable
projection of committed facts.

## 2. Non-negotiable invariants

1. **No KB copies.** Proof and runtime workers receive shared MVCC snapshot
   handles, never copied ontology contents.
2. **No speculative side effects.** A predicate called by a normal proof may
   observe reality or stage writes, but may not perform irreversible external IO.
3. **Commit before reality.** Runtime projections and effects run only after the
   corresponding diff is committed and visible in the local KB.
4. **Replay does not emit effects.** Historical replay rebuilds facts only.
5. **Runtime state is reconstructible.** Every process, timer, route index, and
   mailbox registration derived from facts has a reconciliation path. A
   physical node's durable hosting and exact private-contact knowledge are the
   `hosts_ontology/4` and `knows_ontology_host/4` facts in its dedicated node
   actor ontology; its local manager and directory remain disposable
   projections of those facts.
6. **Ontology ownership is respected.** A foreign mutation is an action request
   executed by the target ontology, never a foreign ready-made diff.
7. **No global FIPA message ledger.** Communication is routed to the involved
   agents. Only state that an agent chooses to remember is committed.
8. **Ontology identity is universal.** Nodes, agents, users, services, and
   other actors are represented by classed instances in ontology state. Public
   keys, class facts, and policies are durable facts in the containing
   ontology; endpoints and private keys are not.
9. **The authenticated subject is end-to-end.** No caller may construct or
   shorten its own authority chain.
10. **Bounded work.** Proofs, reactions, projections, conversations, queues, and
    transport frames all have explicit resource bounds.
11. **One logical effect executor.** Every E effect names one durable logical
    executor. Only the node currently hosting that executor may schedule it.
    Receiver deduplication handles crash retries and the bounded overlap during
    a host-epoch transfer; it is not the normal defense against every replica
    emitting the same effect.
12. **Runtime declarations are privileged code.** `state_handler/4` and
    `react_on/3` facts are executable
    configuration. They may become active only when their provenance satisfies
    the ontology's runtime-declaration policy.

## 3. Lessons retained and rejected

### Retained

- BBSvx's prove-before-broadcast principle.
- The later Onia model: an Agent Platform is an ontology-level authority and a
  hosted agent is a supervised runtime instance.
- Onia's three-part subject authorization context, generalised in Quod to
  `subject(Agent, AgentChain, Capabilities)`.
- Onia's distinction between deterministic state, runtime projection, and
  external effect.
- Prolog definitions for communicative acts, protocols, lifecycle rules, and
  directory policies.
- Erlang external predicates as narrow adapters where Prolog cannot directly
  observe or affect the runtime.
- BBSvx/Onia's target-driven action idea, refined in Quod as
  `action(Transition, Prerequisites, DesiredState)`: `goal(DesiredState)` tries
  declared transitions transactionally.

### Rejected

- A separate Agent Platform record as the durable identity of an agent.
- Copying subscribed foreign facts into another KB.
- Replaying effects from transaction history.
- A generic effect dispatcher that can invoke any compiled predicate by functor.
- Fire-and-forget event workers without ownership or a durable delivery policy.
- Storing every FIPA envelope in one consensus-ordered global ontology.
- Consensus facts containing volatile socket addresses as if they were stable
  identities.

## 4. The execution model

Every operation belongs to one category.

### 4.1 D -- durable ontology state

D consists of:

- committed Prolog facts and rules;
- a proof's private assert/retract overlay;
- transaction goal, result, diff, read-check, author, and signature;
- durable agent lifecycle, ownership, conversation, inbox, and outbox facts.

D is changed only by a committed transaction.

### 4.2 P -- runtime projection

P consists of rebuildable local state:

- hosted-agent OTP processes;
- AID and namespace routing indexes;
- gproc registrations;
- timers derived from durable timer facts;
- active conversation and delivery indexes;
- DF/AMS search indexes;
- live endpoint and reachability caches.

P is updated incrementally after a live D apply and rebuilt in bulk after replay.
Projection handlers must be idempotent.

### 4.3 E -- external effect

E consists of irreversible or externally observable operations:

- sending an ACL message;
- writing to a socket;
- posting to an agent mailbox;
- calling an HTTP or device bridge;
- notifying a client;
- firing an expired timer.

E runs asynchronously after D and P complete for a live transaction. E never runs
from replay.

## 5. External predicate contract

External Erlang predicates are divided into four explicit classes.

| Class | May read runtime | May stage D | May mutate P | May perform E |
|---|---:|---:|---:|---:|
| `query` | yes | no | no | no |
| `staging` | yes | yes | no | no |
| `projection` | yes | no | yes | no |
| `reaction` | yes | no | no | yes |

A `reaction` bridge performs live post-commit E only from a `reaction`
continuation; it cannot stage D or mutate P. This class does not replace durable
effect custody. A `staging` predicate may prepare a bounded effect request as
part of the ordinary proof, and the node-wide effect journal performs that
request only after the controlling transaction commits and verifies the real
result. Authorization, proof, sealing, and consensus therefore remain on one
path.

A `query` may call Erlang and bind its answer into the continuing Prolog goal
with `unify_prove_body`. If the completed goal stages no durable change or
effect request, it is a read and creates no ledger entry. Query predicates must
therefore be safe to repeat during backtracking or proof retry.

One narrow subtype is authority-releasing without changing durable truth. The
node-vault predicate that signs a typed canonical Quod request still uses the
same `query` execution path, but its module declaration and ordinary Prolog
policy must explicitly authorize that operation. It may not accept arbitrary
bytes or become a second permission path.

Examples:

- `peer_ready/1` is `query`.
- `admit/3` and `remove/1` are `staging`.
- `ensure_agent_started/2` is `projection`.
- a live notification or delivery-attempt bridge is `reaction`.
- a future `mts_send/2` action would use a `staging` bridge to prepare its
  post-commit send; the bridge would not send during the proof.

Each predicate declares:

- functor and arity;
- class;
- accepted binding modes;
- allowed execution contexts;
- timeout or synchronous cost expectation.

The former per-proof process-dictionary namespace values have been replaced by
one explicit execution context carried in Erlog's `#est.fs` flags. These flags
are created by the engine, survive the MVCC proof boundary, and are not
caller-supplied. Its five kinds are:

```text
proof(Namespace, Height, Subject)
verdict(Namespace, Height)
policy_verdict(Namespace, Height)
projection(Namespace, Height, HandlerId)
reaction(Namespace, Height)
```

Registration and invocation fail closed when a predicate is used in the wrong
context. Staging predicates are callable only from ordinary proofs; projection
predicates remain confined to projection apply; reaction predicates remain
confined to live post-commit reaction continuations.

> **As built.** The context is one `#qctx{kind, ns, height, subject,
> chain}` record (owned by `m:quod_predicates`), stored under a single
> `none`-valued `#est.fs` flag. `kind` is `proof | verdict |
> policy_verdict | projection | reaction`. The record also carries `chain` (the
> inter-ontology ask chain, which used to be a separate `$quod_ask_chain`
> value). `verdict` is a strictly local membership re-proof;
> `policy_verdict` is a strictly local policy re-proof with governed bridges
> disabled. `none`-valued means ontology content can neither set nor
> clear it (`set_prolog_flag/2` refuses a `none` flag), so it cannot be forged;
> content may still *read* it via `current_prolog_flag/2` (forge-resistant, not
> secret). Today's fields are fine to expose (`ns`/`height`/`kind`/`chain` are
> already visible to `can_read` policies), but the authenticated **subject** (§10)
> must be carried out-of-band — the `#lp{}` overlay pattern (as for
> `follow_disabled`), not this readable flag. All five kinds now have concrete
> constructors: normal proofs, membership verdicts, policy verdicts, runtime
> projections, and post-commit reactions. Lifecycle
> is no longer another context: signed and node-authored `execute` use the
> ordinary proof context, whose private request record already carries the
> authenticated principal. The
> four process-dictionary values (`$quod_ns`/`$quod_applied`/`$quod_ask_chain`/
> `$quod_in_verdict`) are removed, not retained as a second mechanism.

## 6. Actions

The framework action interface is:

```prolog
action(Transition, Prerequisites, DesiredState).
goal(DesiredState).
```

`DesiredState` is the observable state the caller wants; it is not an effect
that the framework asserts. `Transition` is either one callable goal or a
non-empty proper list of callable goals executed left to right.
`Prerequisites` is a proper list. Several declarations may reach the same
desired state.

`goal/1` first checks the desired state read-only. If it already holds, the goal
succeeds without running a transition. Otherwise it validates each complete
candidate before invoking it, then tries matching `action/3` clauses in Prolog
declaration order. Normal prerequisites are read-only state checks; explicit
`goal(State)` and `Ns::goal(State)` prerequisites may establish another state
recursively. The prerequisites, transition, and final exact desired-state check
run inside `transaction/1`.

`transaction/1` is semidet: it keeps the first complete inner solution and
does not expose inner alternatives to its caller. A failed candidate restores
every assertion, retraction, and abolish it staged before the next matching
action is tried. Total failure restores the transaction's entry state; an
Erlog error restores it before the same error propagates. A selected candidate
succeeds only after its desired state has been proved again.

The common clauses are loaded by `quod_committed_projection:new_est/0` into every ontology's
code baseline; they are not copied into genesis transactions. There is no
reverse-effect lookup, generic fact action, direct-call fallback, or
`assert_effect/1` compatibility path. Domain changes use explicit named
transitions.

Example:

```prolog
record_agent_display_name(Agent, Name) :-
    assertz(agent_display_name(Agent, Name)).

action(record_agent_display_name(Agent, Name),
       [may_manage_agent(Agent), valid_agent_display_name(Name)],
       agent_display_name(Agent, Name)).
```

The authenticated subject will be read by authorization prerequisites from
the engine-owned execution context; it is not a positional field of
`action/3`.

Most actions change durable reality and their runtime consequences are derived
from the committed diff by P and E handlers. Explicit node-local lifecycle
actions use the same desired-state declaration shape, for example
`ontology_hosted(Name)` and `ontology_joined(Name, GenesisHash)`, and run only
through the same ordinary action relation. Signed and node-authored `execute`
are the entries. The target's `can_invoke/4` and declared action prerequisites
run before the governed bridge reads or prepares input. The bridge stages a
closed effect; the ordinary transaction commits it, and the node-wide journal
performs it only after ordered apply. An already-true target returns success
without lifecycle IO. An unobservable completion is `outcome_unknown`.
Lifecycle IO is journal behavior, not the third argument of `action/3`, and no
volatile hosting fact is asserted into consensus.

## 7. Apply, replay, reconciliation, and events

The existing `{committed, Namespace}` publication occurs before
`quod_prolog` has applied the block. It remains suitable for dissemination and
observability, but it must not become the reaction source.

The former undifferentiated apply interface has been replaced with an explicit
origin:

```text
apply(Index, Batch, live)
apply(Index, Batch, replay)
```

The per-namespace sequence is:

### Live

1. Simplex finalizes and durably stores the block.
2. `quod_prolog` applies D and publishes the new MVCC snapshot.
3. `quod_prolog` sends an immutable `applied_live` envelope to
   `quod_runtime` and immediately continues applying later blocks.
4. `quod_runtime` runs the thin ordered P tier against the applied snapshot;
   handlers may enqueue heavy resource-specific projection jobs.
5. Once the ordered tier completes, matching E reactions are scheduled. Effects
   depending on a heavy resource wait on that resource's own revision barrier.

P never runs in the `quod_prolog` process and cannot stall consensus or D
application.

### Replay and catch-up re-entry

Replay is not only a boot phase. An established member can discover a gap and
enter in-process recovery while `quod_prolog` remains available for
stale-but-valid reads. Runtime mode is therefore a repeatable state machine:

```text
live -> replaying(RecoveryId) -> reconciling(RecoveryId) -> live
```

Initial boot follows the same state machine, starting in `replaying`.

1. Before the first recovery block is applied, `quod_prolog` observes the
   live→replay origin transition and announces `replay_started(RecoveryId,
   FromHeight)` on the namespace runtime channel. `quod_runtime` stops scheduling
   new E work for the namespace.
2. `quod_prolog` applies each recovered block as D with origin `replay`.
   Per-block P and E do not run.
3. Once verified recovery reaches a corroborated ready edge, Simplex casts
   `mark_ready` after all replay apply casts; `quod_prolog` then announces
   `replay_ready(RecoveryId, ReadyHeight)`. This also closes a quiet recovery.
4. `quod_runtime` reconciles all P once from the newest applied MVCC snapshot.
5. Live envelopes that arrive during reconciliation wait in a bounded ordered
   queue. After reconciliation they run through P then E in height order. If the
   queue fills before reconciliation completes, the queued envelopes are
   discarded and one fresh reconciliation runs at the newest applied snapshot —
   the same collapse rule the unhealthy-projection path uses (section 8). Durable
   effects are recovered from the outbox either way; only best-effort reactions
   from the collapsed window are lost, and they are counted.
6. The namespace returns to `live`. A later gap repeats the same transition.

Recovery IDs make stale or duplicated boundary messages harmless. No API caller
may label an apply `live` merely because `quod_prolog` is already marked ready;
the origin comes from the Simplex path that obtained the block. A runtime crash
also returns through reconciliation before E resumes.

Durable outbox facts learned during replay are recovered by reconciliation.
Best-effort effects from replayed history remain deliberately absent.

> **As built (Slices 1–2).** The apply origin is `live | replay`: Simplex tags local
> commits and a settled observer's contiguous feed block `live`; rebuild, member recovery,
> and observer anti-entropy gaps are `replay`. `quod_prolog` owns the
> `live | {replaying, RecoveryId}` state machine, **mints the RecoveryId itself**
> on the live→replay edge, and publishes all three messages
> (`replay_started` / `replay_ready` / `applied_live`) on the `{runtime, Ns}`
> property. Simplex does not mint IDs, but it explicitly casts `mark_ready` after a
> recovery or complete feed pull; because it also sends the apply casts, mailbox order
> guarantees the ready edge cannot overtake the final replay block. `quod_runtime`
> consumes these boundaries and reconciles once per interval.

### Live apply publication

One live-applied material transaction currently produces this compact runtime
publication:

```text
#{ns, height, tx_id, subject, diff, applied_ops, effects}
```

`diff` is the signed requested operation list. The canonical committed
projection separately computes ordered `applied_ops`, excluding identical
assertions and absent retractions while preserving every explicit event
occurrence. The runtime publication carries that existing result and converts
each applied operation to one event; it does not treat requested no-ops as
changes and does not add a second event envelope. `effects` contains only the already-validated bounded
descriptors from that transaction; effect-only transactions therefore cross
the same ordered runtime boundary with `diff = []`. An ordinary transaction
keeps goal and result in the ledger for detail readers. A DTX group publication
also carries `proof_id`, `origin`, `goal`, `result`, and `plan_digest`, because
the group reducer already has that canonical proof context.

> **As built (Slice 1 plus DTX-group extension).** The ordinary envelope is a
> map carrying exactly the displayed fields, published as
> `{applied_live, Env}` on `{runtime, Ns}`. A map (rather than a fixed `/7`
> record) so Slice 5 can add subject-chain fields without reshaping. It is emitted
> once per material transaction on a **live** commit, including a direct-effect
> transaction with an empty D diff. An
> OCC-rejected transaction publishes `{rejected_live, #{ns, height, tx_id,
> subject, effects}}` with no diff. A live DTX group publication adds the
> proof fields listed above and carries its
> authenticated principal, including `{agent, CanonicalBytes}` after the agent-
> identity format break. Ordinary single-ontology applied and rejected
> publications still carry `subject = undefined`; that is the current
> observability shape, not a missing agent identity or authorization path.

### Shared substrate consumers

The post-apply origin and event contract is useful independently of agents:

- deferred reader arc P3 can invalidate bounded predicate caches only from
  `applied_live`, never replay;
- The ontology-subscription plan routes canonical certified foreign-projection
  changes through the same ordered handler tier, then through this plan's one
  `react_on/3` reaction owner. The subscriber matches its own source-qualified
  `react_on/3` declarations locally; the first implementation does not install
  those patterns at the target. Proof-local read sets remain OCC dependencies
  and are not notification registrations.

These consumers reuse the origin boundary and handler indexing from Slices 1--2
without depending on hosted agents, FIPA, or client/world work.

## 8. Projection handlers

Projection declarations are facts:

```prolog
state_handler(Id, WatchedPatterns, Needs, ConvergeGoal).
```

There is one recipe per handler and no separate dependency fact. The same
`ConvergeGoal` runs everywhere with a scope argument appended (declared arity N
is invoked at N+1 — this erlog has no `call/2`): `all` at reconcile,
`{keys, ChangedHeads}` after a live change, where the heads are full terms
INCLUDING retracted heads, a narrowing hint only — a join-shaped handler may
treat it as `all`. This replaces the OnDiff/Reconcile pair (one recipe cannot
drift from itself; idempotency is structural). Ordering is the onia/bbsvx
action-pattern shape: `Needs` is a list carried IN the declaration, restricted
in this slice to ground `current(OtherId)` terms so the whole graph validates
statically at reconcile; matched handlers and their transitive dependents run
in the global converge order (Kahn, Id-term-order tiebreak — deterministic per
node). Arbitrary condition goals in Needs are deferred: under `unknown => fail`
a typo'd condition is indistinguishable from a false one, and data-dependent
conditions would activate different handler sets on nodes reconciling at
different heights.

Rules:

- handler IDs are globally qualified names;
- dependencies are topologically sorted deterministically;
- an unknown dependency or cycle prevents the namespace from becoming ready;
- live incremental handlers execute in `quod_runtime`, in order, before E
  publication for that event;
- reconciliation uses the same ordering;
- handlers receive a frozen MVCC snapshot at the applied height;
- the ordered handler tier may update small indexes and enqueue idempotent work,
  but may not perform network IO, large scans, mesh/collider construction,
  simulation steps, asset work, or other unbounded computation;
- heavy P runs in supervised queue-fed resource workers outside the ordered
  namespace pipeline. Workers preserve per-resource order, coalesce superseded
  jobs where semantics allow, and publish dependent output only after installing
  the requested resource revision;
- every handler and worker has a hard time budget and is instrumented;
- runtime input and worker counts are bounded;
- distinct pending heavy resources and encoded job size are bounded; overflow is
  rejected loudly, and resources are scheduled in FIFO order;
- an ordered-handler timeout or failure stops E publication and collapses pending
  P work into one reconciliation at the newest applied snapshot; repeated failures
  mark the namespace runtime unhealthy;
- a heavy-worker failure is isolated from the ordered tier, but blocks that
  resource's revision until a later full rebuild succeeds;
- after successful reconciliation, durable effects are recovered from their
  outbox; best-effort reactions skipped during the unhealthy interval are
  counted and deliberately not reconstructed;
- a projection failure is never silently absorbed.

The namespace-wide P-before-E barrier covers the thin ordered tier. It does not
wait for unrelated heavy resource work. An effect that depends on a heavy
projection is released by that resource worker's own revision barrier, not by
blocking every later event in the namespace. This distinction is part of
`quod_runtime`'s initial API, even before any world worker exists.

### 8.1 Declaration authority

Handler and reaction facts are executable content: they can create processes,
consume resources, and ultimately cause external IO. Ordinary write permission
is not sufficient to activate them.

The policy predicate is:

```prolog
can_declare_runtime(Subject, Kind, Declaration).
```

The planned kinds are `state_handler` and `reaction`. The separate
`handler_dependency` declaration was retired when dependencies moved into the
`Needs` field of `state_handler/4`.

Every ontology uses its own slot-1 block as the declaration-execution lock; the
ontology need not be a system ontology. A `state_handler/4` activates only when
its complete ground term occurs in that founding block and remains present in
current D. A founding handler which is nonground or has been retracted makes
the runtime distinctly and loudly unhealthy. `react_on/3` intentionally permits
pattern variables, so its founding and current clauses are alpha-normalized and
fully validated instead; a missing or invalid founding reaction is likewise a
distinct loud failure. Later-written declarations remain inert, refused, and
counted even when their ordinary write passed `can_invoke/4`.

Generic transaction-author identity now exists, but a future dynamic
`can_declare_runtime/3` policy has not replaced this founding lock. External
predicate functors referenced by an active declaration must be provided by an
audited module named and hash-pinned by that ontology's immutable genesis, and
that module must be shipped in the release. Root names only the ontology
identity. Ontology content cannot load arbitrary Erlang modules; there is no
application-global predicate catalogue.

The first handlers will own:

- hosted-agent processes;
- agent timers;
- AMS/DF indexes;
- MTS delivery routes.

## 9. Reactions and reliable effects

`react_on(Executor, Pattern, Handler)` is durable ontology content, but its body is
an E rule and therefore runs only for live events.

`Executor` is the logical owner of the effect, not the source or class of the
event, and it is not agent-specific. `agent(A)` is the common FIPA case;
`service(S)`, `node(NodeKey)`, or another ontology-defined single-owner term
uses the same mechanism. Local and remote event sources remain part of
`Pattern`.

Reaction input is the ordered `applied_ops` already produced by the canonical
committed-state reducer. Reaction matching is Prolog work. `quod_runtime` may
index candidates by source and event functor, but the actual match and continuation use
`erlog_int:unify_prove_body`, which installs the pattern's variable bindings
before executor resolution and Handler continuation. There is no Erlang-side
matcher or parallel binding representation.

The Handler is ordinary trusted Prolog. It runs in the single
`reaction` context: query and reaction-class external predicates are allowed;
staging and projection predicates are refused. Observable Erlang bridges are
registered through the existing ontology predicate-module mechanism with
class `reaction`; there is no typed callback catalogue or second dispatcher.

### Logical agent versus live Erlang process

An agent is a durable classed instance and state in D. Its Erlang process is
only the current live P incarnation on the node selected by committed
ownership/residency facts. The process owns bounded mailbox draining, timers,
conversation progress, and effects; it keeps no private knowledge base and can
be killed, restarted, or moved without changing the agent's identity. Any
durable change it requests still enters as an ordinary signed goal through the
same Prolog, `can_invoke/4`, OCC/DTX, consensus, and outcome path.

Events are not broadcast blindly to every agent process in an ontology. The
ontology receives an event once; its committed `react_on/3` clauses are matched
centrally through `erlog_int:unify_prove_body`. Each successful match grounds
an `Executor`, such as `agent(Bob)`. Runtime then proves that this node is the
unique current host and delivers only that grounded reaction to Bob's live
process. A rule may intentionally produce several agent executors, but that
fan-out is explicit, bounded, and observable. Agent processes never implement
a second matcher or receive every raw event merely because they belong to the
ontology.

Only active locally hosted agents have processes. Dormant, historical, or
remotely owned agent facts allocate no Erlang process here. The existing
runtime reconciliation is the sole process start/stop owner; a later agent
slice may split a supervisor only when the concrete hosted-agent workload
requires it, not as advance scaffolding.

`Executor` may contain variables bound by `Pattern`, for example:

```prolog
react_on(agent(Agent),
         assert(task_ready(Agent, Task)),
         notify_agent(Agent, Task)).
```

Before scheduling the goal, `quod_runtime` resolves the executor against the
event's committed snapshot. The reaction runs only when that resolution names
this node as the unique current host. No owner or multiple owners is a
fail-closed runtime-integrity error; it never falls back to execution on every
replica.

Four delivery choices are required. They differ independently in whether the
occurrence itself is committed and whether delivery is acknowledged/recovered:

| Choice | Occurrence in D | Delivery acknowledgement/recovery |
|---|---:|---:|
| best-effort reaction | no dedicated record | no |
| acknowledged volatile delivery | no custody record | bounded live retry and dedup only |
| `trigger_event/1` | one ordered committed occurrence | no |
| durable outbox | pending until separately committed completion | yes, across crash and host move |

### Best-effort reactions

Suitable for telemetry and replaceable or expiring updates. They are bounded,
asynchronous, and may be lost if the node dies after commit but before
execution.

### Acknowledged volatile delivery

Suitable for ordinary live ACL traffic when the conversation protocol can retry
or reconstruct the message. It uses bounded transport acknowledgement, retry,
and receiver deduplication, but does not create an outbox fact for every frame.
A sender-process crash may lose an in-flight message; the protocol's durable
conversation state decides whether and how to reconstruct it.

### Committed signal without delivery confirmation

`trigger_event(Term)` stages one signed, ordered, auditable occurrence in the
ordinary transaction operation list. It costs one consensus commit and changes
no fact. Local and subscribed ontologies may react to it only when they observe
that commit live: replay proves that the occurrence existed but never reruns its
handler. Use it when the signal itself must be committed but missing one live
notification is acceptable. It is not delivery confirmation and must not be
described as guaranteed delivery.

### Durable outbox delivery

Reserved for low-rate control-plane or external actions whose loss across a
sender crash would violate semantics and which cannot be reconstructed safely
from current D. The action stages an outbox fact as part of D:

```prolog
outbox(MessageId, Executor, Destination, Payload, pending).
```

`Executor` is normally `agent(AgentId)`. System effects may explicitly use
`node(NodeId)` or another ontology-defined single-owner identity; there is no
implicit `all` executor.

The outbox fact is the sole durable custody. One founding `state_handler/4`
watches pending-outbox and host-assignment facts and projects the complete
current local obligation set after a live change, restart, replay, or host move.
It is both the live and recovery path: the assertion's changed head already
selects it in the same ordered runtime batch, so delivery needs no duplicate
`react_on/3` wake rule. Applications may independently react to outbox state for
their own notifications, but that is not the delivery scheduler. The handler
feeds one rebuildable scheduler keyed by a stable `DeliveryId`; neither side
owns a second queue of durable truth or independently scans a ledger.

For the first agent vertical, the hosted-agent process (or a small supervised
child extracted only if the concrete retry loop needs it) owns the volatile
timers, in-flight sends, acknowledgements, and backoff. There is no separate
per-namespace `quod_outbox` process. The handler's projection bridge installs
or withdraws revision-tagged desired local work but performs no IO. The
scheduler sends only after the existing P-before-E frontier reaches that
revision. Before every send, it checks the newest local committed view for both
the exact pending tuple and one current host epoch selecting this node. No
owner, multiple owners, a remote owner, or a stale epoch sends nothing and
leaves the fact pending.

The node-wide `quod_effect_journal` is deliberately separate. It owns private
prepared custody for local ontology-lifecycle effects before and after their
controlling commit. An agent outbox is replicated application D whose custody
moves with its executor. Copying an outbox row into that journal would create
two custody owners and break clean host migration; only low-level utilities may
be shared.

Every replica stores the outbox fact, but only the node currently hosting the
logical executor schedules delivery. If ownership moves, the new owner
reconciles pending entries and continues delivery. Completion is recorded by a
separate ordinary signed transaction. Receivers deduplicate by `MessageId`.
An uncertain completion outcome is resolved by rereading the exact current D
state, never by blindly resubmitting. Temporary route, link, or authority
unavailability retains the same pending message and retries without an
attempt-count drop.

This is a transactional-outbox model: it avoids both BBSvx's duplicate replay
and an at-most-once window that silently loses essential messages.

The cost is explicit: normally one consensus commit stages the effect and a
second commit records completion. Durable effects are therefore expected to be
low-rate. Completion may be batched or piggybacked on a later protocol-state
transaction when semantics permit, but durability must not be silently weakened.
High-volume conversations use acknowledged volatile delivery plus explicit
protocol state, not an automatic two-commit outbox entry per message.

Two legitimate duplicate windows remain. A sender can crash after delivery but
before committing completion, and an ownership-move block can be applied at
different times on the old and new owner so both briefly schedule the same
pending effect. Stable `MessageId` receiver deduplication is the correctness
mechanism for both. It does not excuse every committee replica sending effects.

Timers follow the same ownership rule. A durable timer belongs to one agent or
other logical executor; only its current host arms and fires the BEAM timer.

Client and world effects consume this ownership and delivery machinery but do
not define it. Their directional design lives in
`doc/client-world-direction.md`.

## 10. Agents, users, and authorization

`agent` is the generic acting class. `human_user` is its human-specific
subclass, not a name for every public-key holder. `quod:agent` and
`quod:human_user` provide shared class rules; they are not global registries
that replace an actor's authoritative containing ontology.

Each acting instance records its class and active public key in its containing
ontology. Its stable identity is
`agent_instance_ref(Namespace, GenesisAnchor, Instance)`. Genesis stores the
local `Instance`, because an ontology cannot contain its own not-yet-known
anchor; the external reference is formed after slot 1 exists. The private key
stays outside the ledger: a browser-controlled instance uses its client key
provider, while an autonomous instance uses the node-local vault on its
committed host. Moving an agent rotates to a key staged in the destination
vault; it never transports the old secret. A signed request therefore proves
possession of an active key bound to the instance; the ordinary target
`can_invoke/4` policy decides what that agent may do.

`quod:human_user` defines the human-specific subclass and related profile
vocabulary. It does not contain a row for every human, define a second
authentication authority, or own a special creation executor. A new ontology
may include local facts such as
`instance_of(human_user, local_human_1)` and
`agent_key(local_human_1, PublicKey, active)` in its ordinary genesis; an
existing ontology may add the same facts through an ordinary transaction.
There is no core `create_agent` or `create_human_user` predicate.

The creator, contained instance, signing key, ACL permissions, and runtime host
are separate. An agent reference grants none of them implicitly. Ordinary
creation policy may authorize only a specific existing agent to call
`create_ontology/3`; that caller may be a FIPA agent whose conversation and
approval facts satisfy changeable Prolog prerequisites. This is ordinary ACL
and action policy, not a separate delegation feature.

The deployed transport authenticates a stable agent reference and its
active signing key in one format, without a second ACL or legacy signed route.
That identity proof does not replace or redefine the target ACL decision.

The ACL term remains exactly:

```prolog
subject(Agent, AgentChain, Capabilities)
```

- `Agent` is the originating `agent_instance_ref/3` on whose behalf the chain began;
  it may belong to any `agent` subclass;
- `AgentChain` is the non-empty delegation chain, current agent first, and
  every member is also an `agent_instance_ref/3`; and
- `Capabilities` are derived for the current agent by the receiver and replace
  the previous agent's capabilities.

The signing credential and ACL subject are orthogonal. The signature proves
that an active key bound to the claimed agent instance signed the exact
request. `subject/3` states on whose behalf, through which agents, and with
which current capabilities it acts. Wielding and agent-to-agent delegation
construct the triplet; merely possessing an `agent_key/3` never fabricates
one.

Examples:

```prolog
%% H and A are agent_instance_ref/3 terms. Human agent H wields avatar A.
subject(H, [A], AvatarCapabilities).

%% A delegates to B; B is now the current invoker.
subject(H, [B, A], BCapabilities).

%% Autonomous or load-test agent M acts directly.
subject(M, [M], MCapabilities).
```

At an agent-to-agent hop:

- the receiving agent is prepended to the chain;
- the receiving agent's capabilities replace the caller's capabilities;
- the authenticated origin and complete chain are transport-bound;
- every ontology in a cross-ontology call checks the same immutable chain.

Transaction-author signatures must bind at least the target namespace, action or
goal, subject, nonce, and submitted transaction content.

Capability replacement is intentional attenuation, not an implementation
accident. The chain preserves who delegated to whom, while the capability set
answers what the current receiving agent itself may do. A caller cannot lend its
capabilities to a weaker receiving agent. Policies that care about an ancestor
express that explicitly against the immutable chain.

## 11. Agents and Agent Platforms

### `quod:agent`

`quod:agent` defines only the common acting vocabulary:

```prolog
isa(agent, thing).
agent_key(LocalInstance, PublicKey, Status).
agent_platform(AgentRef, PlatformNamespace).
agent_hosted_on(AgentRef, NodeRef, Epoch).
agent_display_name(AgentRef, Name).
has_capability(AgentRef, Capability).
accepts_wielding(AgentRef, Subject).
```

Each specialised system ontology owns its own subclass statement:
`quod:node` defines `isa(node, agent)`, `quod:human_user` defines
`isa(human_user, agent)`, and the FIPA vocabulary defines
`isa(fipa_agent, agent)` and `isa(agent_platform, agent)`. An application or
load-test ontology may similarly define `isa(monkey_user, agent)` without an
Erlang or generic-vocabulary change.

Concrete actors use the existing class-first instance convention, for example
`instance_of(fipa_agent, local_agent_1)`; `isa/2` above is only class
inheritance. The external `agent_instance_ref/3` combines that local name with
the containing ontology's exact identity.

The actual instance facts live in an ordinary ontology. Independently managed
agents will normally use a dedicated ontology, while policy may deliberately
place several instances in one ontology. An Agent Platform is another ontology
that may coordinate, discover, or authorize work; containment alone does not
make it the instance's ACL authority.

The hosted process is P-state:

- it exists only on the current committed host node;
- it obtains durable state from its containing ontology;
- its in-process state is a cache or working set;
- restart and migration reconstruct it from D;
- stopping the process does not delete the agent.

No volatile endpoint is stored as part of the agent's identity.

## 12. FIPA mapping

Quod initially implements a practical FIPA profile, not the full formal mental
attitude calculus.

### AID

```prolog
aid(Name, Addresses, Resolvers, UserDefined).
```

- `Name` is the existing canonical `agent_instance_ref/3` byte representation,
  rendered on a FIPA text wire as `quod-agent-` followed by its unpadded
  base64url encoding. Decoding recovers those exact bytes; there is no AID
  registry or identity-mapping table.
- `Addresses` are ordered current transport addresses derived from P-state at
  lookup/send time.
- `Resolvers` identify the current Agent Platform/AMS resolvers and their
  current P-state routes. Agent migration may change `Addresses`, `Resolvers`,
  and `agent_platform/2`; it never changes `Name`.
- AIDs compare by the decoded canonical agent-reference bytes. A display name
  is `agent_display_name/2` application data, never identity.

The complete `aid/4` term is a wire/runtime value, not a committed fact. Only
stable identity, stable resolver names, and policy-approved user properties may
be D. Volatile addresses never enter consensus and are refreshed whenever an
AID is constructed. This identity is globally unique within one Quod network.
If future FIPA federation crosses distinct root network identities, the same
deterministic wire name also binds `NetworkIdentity`; that extension must not
introduce a registry, alias, or second agent identity.

### ACL envelope

```prolog
acl(
    Performative,
    Sender,
    Receivers,
    Content,
    acl_meta(Language, Ontology, Protocol, ConversationId,
             ReplyWith, InReplyTo, ReplyBy)
).
```

The first supported performatives are:

- `request`;
- `agree`;
- `refuse`;
- `failure`;
- `inform`;
- `not_understood`;
- `cancel`.

Every protocol message is checked against a Prolog conversation rule before it
is accepted. Conversation IDs are globally unique and non-empty.

### Mapping to Quod

- `request(DesiredState)` asks the receiver to establish
  `goal(DesiredState)` in its owning ontology under the authenticated subject
  context.
- `query_if(Goal)` uses a bounded target proof and returns an `inform`.
- `query_ref(Goal)` streams target answers into one or more `inform` messages.
- A FIPA `subscribe(Goal)` performative is application-level protocol state. It
  may establish or reuse the explicit durable subscriber-owned ontology
  relation and a source-qualified `react_on/3` interest described by
  `ontology-subscription-plan.md`; it is not itself a second transport
  subscription and is never inferred from query completion or a proof read
  set.
- `cancel` retracts the corresponding reaction/protocol commitment and removes
  the ontology relation only when no other local consumer still needs it, all
  through ordinary authorized transactions.

The future Erlang MTS transports addressed FIPA ACL envelopes between agents
within or across APs and enforces transport bounds. It does not discover
agents, services, ontologies, or hosts, and it never replaces QUIC,
`quod_directory`, or `::`. Prolog owns message meaning, authorization, and
protocol transitions.

## 13. Three discovery responsibilities

Do not merge these responsibilities.

### Quod ontology-route resolver

Maps only an exact ontology identity (namespace plus genesis anchor) to
currently verified hosts. A separate future Prolog-owned public-discovery
service may map a public name to that anchored identity and decide
discoverability; it does not become part of the route store. The target
ontology's ordinary lifecycle policy alone authorizes hosting. Endpoints,
contacts, leases, and freshness are P-state projected into the sole
`quod_directory` owner from signed fact-backed generations and local private
contacts derived through authenticated node-actor routes. It is not an AID resolver, and neither
a registration nor a contact hint makes a route authoritative.

This is a Quod role, not the FIPA Ontology Agent. The
[obsolete FIPA00006](https://www.fipa.org/specs/fipa00006/OC00006A.html) and
later [Experimental FIPA00086](https://www.fipa.org/specs/fipa00086/index.html)
Ontology Service revisions describe an OA for
ACL-facing public-ontology access, semantic queries/updates, comparison,
shared-ontology selection, and optional translation; neither standardises
Quod's namespace-to-current-host routing. A future Quod agent may expose an
OA-like semantic/discovery service and advertise it through the DF. It remains
a client/front end of the Quod route resolver and never owns or certifies live
routes. Calling it `fipa-oa` would require the separate FIPA00086 ACL contract,
which this plan does not claim.

### AMS -- white pages

Each Agent Platform is itself an ontology and projects the mandatory AMS role
from the [FIPA Agent Management Standard](https://www.fipa.org/specs/fipa00023/).
It supervises AP access, AID registration/search, agent residency and
lifecycle, and the AP description. AMS AID addresses are not Quod ontology
routes. A managed agent keeps its authoritative class, key, and state in the
ontology named by its `agent_instance_ref/3`; an AP record is not a substitute
identity.

### DF -- yellow pages

The optional DF stores agent descriptions and service advertisements. The
following is Quod's planned durable representation, not FIPA's literal wire
schema:

```prolog
service(AgentId, ServiceId, Type, Ontologies, Protocols, Languages, Lease).
```

It supports register, deregister, modify, and bounded search. Multiple DFs may
exist and federate; federation carries a globally unique search ID, maximum
depth, maximum results, and visited set.

The durable `Lease` is an absolute expiry (or a deterministic durable start
plus duration). The P index filters expired advertisements against current time
when it is rebuilt or queried. Expiry alone creates no pruning transaction;
renewal, deregistration, or an application retention policy changes D through
an ordinary authorized transaction.

DF registration advertises a capability; it does not guarantee that an agent
really provides it or will accept a particular request. The DF never becomes an
ontology route table; finding a discovery service through the DF and resolving
an ontology through that service remain two separate operations.

## 14. Performance architecture

1. All proof and handler contexts use MVCC snapshot handles.
2. Hot AMS, DF, AID, route, and handler indexes are P-state ETS tables rebuilt
   from ontology facts.
3. A live commit performs no network IO or P work on the Simplex or Prolog
   process.
4. The ordered `quod_runtime` tier performs only bounded index updates and
   enqueue operations. Heavy P runs in independent bounded resource workers.
5. E workers are supervised; one conflict lane serializes one affected
   resource while independent lanes run concurrently. Per-attempt timeout/heap
   safety comes from named physical-node policy, not a hidden worker-count cap.
6. Each transport pool connection uses channel priority classes. Consensus
   signaling is highest urgency; catch-up/control are bounded separately; feed,
   ACL, and future client state cannot consume consensus's priority under
   congestion. This requires the pinned QUIC fork's RFC 9218 stream priority
   support before those lower-priority producers are deployed.
7. Direct `::` queries remain the fast path; ACL is not inserted around every
   local proof.
8. Conversation and outbox retention have explicit pruning rules.
9. Handler matching is indexed by changed functor rather than scanning every
   handler for every transaction.
10. Metrics must expose queue depth, handler latency, reconciliation duration,
    retries, deduplication, dropped best-effort effects, and oldest pending
    durable effect.
11. Future QUIC datagrams avoid stream head-of-line blocking but share the
    connection's congestion window and pacing. Their byte rate and queues must
    be capped and load-tested against consensus latency before activation.
12. Transaction throughput, batching delay, and post-apply overhead are
    application-visible budgets for actions, not only consensus benchmarks.
    Every slice reports p50/p95/p99 commit latency and sustained transaction rate.

## 15. Proposed module boundaries

Do not scaffold the end state. The delivered substrate added two cohesive
modules and narrowed one existing owner:

- `quod_prolog` (existing, narrowed): D proof and committed projection only.
- `quod_runtime` (added): ordered post-apply P orchestration, reconciliation,
  and the one reaction dispatcher.
- `quod_predicates` (added): predicate registration metadata and context
  enforcement.

The first durable-agent delivery must reuse this substrate: one founding
`state_handler/4` feeds the hosted agent's volatile delivery scheduler on both
live changes and reconciliation, while the outbox fact remains sole custody.
Do not add a duplicate `react_on/3` delivery wake or a
per-namespace `quod_outbox` scanner/process. Extract a small delivery worker
module only if the concrete retry/ack loop makes the hosted-agent process
unclear; it may own volatile attempts, never D, policy, or another queue of
durable truth.

Later slices introduce responsibilities for hosted-agent supervision, subjects,
MTS routing, AMS/DF indexes, and ontology resolution. Their ownership boundaries
remain explicit, but they may share a module while small. A named module is
created only when its slice lands and the code has a real API to hold.

The per-namespace supervision order is:

```text
simplex -> prolog -> catchup -> feed -> runtime
```

`runtime` is last. It depends on the committed KB and endpoints, while no
earlier child depends on its rebuildable P/E state. Its own crash therefore
restarts no consensus, KB, catch-up, or feed process; any earlier restart does
restart and reconcile it against the fresh KB.

## 16. Rewrite sequence

### Slice 1 -- execution contexts and apply origin

**Status: DELIVERED (0.7.15).** The typed-predicate substrate, the `#est.fs`
context migration, `apply_entry/3` with a complete certified entry and `live | replay`, the `applied_live` event,
and the `replay_started`/`replay_ready` boundaries are built and green (285 eunit,
25 CT, dialyzer + xref clean). The "reconciles P exactly once" and "cannot resume
E early" acceptance items are substrate-only until `quod_runtime` (Slice 2)
consumes the boundaries; throughput was validated by the consensus CT suites
passing unchanged, not by a dedicated benchmark. See the "As built" notes in
sections 5 and 7.

- Introduce explicit predicate metadata and execution contexts.
- Replace the payload-only apply call with the live/replay-aware full-entry contract.
- Add explicit recovery-start and ready-edge boundaries for initial rebuild and
  every in-process catch-up transition.
- Add a post-D applied event.
- Keep the existing pre-apply committed publication only for feed/metrics until
  its consumers are migrated.

Acceptance:

- a proof cannot invoke an E predicate;
- replay cannot publish a live event;
- a live event observes the newly committed facts;
- a ready member can transition live -> replaying -> reconciling -> live without
  restarting Prolog, and every ready edge reconciles P exactly once;
- stale/duplicated recovery boundary messages cannot resume E early;
- throughput regression is measured and remains negligible.

### Slice 2 -- runtime and reconciliation

- Add `quod_runtime`.
- Implement state-handler discovery, indexing, dependency ordering, and bulk
  reconciliation.
- Move any existing runtime projection behavior behind handlers.

Acceptance:

- restarting runtime reconstructs P without replaying the KB;
- handler cycles and missing dependencies fail loudly;
- the thin ordered P tier is complete before general E sees an event;
- a deliberately slow heavy P worker cannot delay later namespace events, and
  its dependent output is not published before its resource revision installs.

> **As built (Slice 2 — DELIVERED, all four acceptance bullets test-pinned).** `m:quod_runtime`
> per namespace, LAST in `quod_ns`'s rest_for_one chain; one-recipe handlers with the
> action-pattern Needs (the §8 note above); §8.1's provenance check is a FULL-TERM
> match against the founding (slot-1) block — the declaration-execution lock,
> distinct from the ordinary `can_invoke/4` write ACL — with retracted or
> nonground founding `state_handler/4` declarations a distinct loud unhealthy,
> founding reactions separately alpha-normalized and validated, and dynamic
> declarations refused+counted. The whole discovery+plan+converge pipeline runs in a
> killable budgeted runner (never in the server); execution failures collapse pending work
> into one reconciliation with exponential backoff (crash to the supervisor after 5); the
> runtime raises its MVCC floor as the tier completes; at replay it reaps every reader before
> detaching the pin, so neither stale reads nor replay-long history retention are possible.
> The heavy framework ships as API shape + machinery (enqueue_projection/2 bridge, bounded
> FIFO per-resource queues, worker cap, encoded-size cap, revision barrier via await_revision/4);
> jobs are Prolog goals against the newest snapshot, Erlang job kinds arrive with the first
> real worker. A resource with no work advances with the ordered frontier; a failed job blocks
> that inference until a later successful rebuild. Settled observers process contiguous feed
> blocks live and reconcile once after an anti-entropy gap. "Move existing projection behavior
> behind handlers" was vacuous (grep-verified: none existed).

### Slice 3 -- reactions and outbox

**Status: PARTIALLY DELIVERED.** Ordered local and certified-subscribed
`applied_ops` matching, bounded best-effort reactions, and `trigger_event/1`
are committed and deployed through Slices 1--3 of
`event-reaction-refinement-plan.md`. Reaction counters, latency histograms, and
their Grafana rate/latency panels are live. The remaining work is acknowledged
volatile delivery, the durable agent outbox, and RFC 9218 stream priorities.

- **Delivered:** ordered applied-operation matching through the one dispatcher
  in `event-reaction-refinement-plan.md`.
- **Delivered:** bounded best-effort reactions and `trigger_event/1`.
- Add acknowledged volatile delivery for normal conversation traffic.
- Add durable outbox delivery, completion, retry, and receiver deduplication.
- **Transport work item — RFC 9218 stream priority classes.** Connection
  consolidation is already done: consensus, feed, catch-up, and Brahms all key
  their peer connection by `NodeId` (pubkey), so every steady-state channel to a
  member shares one outbound connection (a cold-start bootstrap seed keys by
  endpoint, transiently, until the pubkey is learned). The remaining, deliberate
  "two connections per pair" is one *per direction* — each node stays the client
  for its own outbound streams (the proven client-initiated QUIC stream path); that
  stays. Because all those streams share one congestion window, feed, ACL, and
  future client traffic can contend with consensus, so before ACL shares
  connections, assign RFC 9218 priorities (`{log}`/`{catchup}` high urgency; feed,
  ACL, and future client state lower) via the pinned fork's `set_stream_priority/4`,
  with a load test proving lower-priority producers cannot starve `{log}`.

Acceptance:

- history replay sends nothing;
- a crash between commit and delivery is recovered;
- a host-epoch transfer may overlap sends but receiver deduplication preserves
  one logical effect;
- duplicate delivery does not duplicate the receiver's action;
- load tests price the two-commit durable path separately from acknowledged
  volatile delivery and show lower-priority traffic cannot starve consensus;
- loops and worker exhaustion are bounded.

### Slice 4 -- minimal agent vertical slice

This is the proof of the architecture and remains trusted-fleet-only.

It starts only after three prerequisites exist: durable outbox delivery from
Slice 3; stable `NodeRef` creation and activation from Slices 2--3 of
`node-instance-identity-plan.md`; and the node-vault canonical signing bridge
from `ontology-actor-architecture.md` §4.1. A hosted autonomous agent needs the
vault to sign its ordinary completion and consequence transactions. A raw node
key, embedded test key, or node-authority shortcut is not an acceptable
temporary host identity or signer.

The hosting projection itself is product work in Slice 4 of
`event-reaction-refinement-plan.md`: one founding `state_handler/4` consumes
committed host facts and starts/stops the local process. This vertical consumes
that owner; it does not add another hosting manager.

- Consume the root-catalogued `quod:node`, `quod:agent`, and
  `quod:human_user` system-ontology vocabulary.
- Create two agent ontologies, each with its own committed state and public
  key binding.
- Reconcile one hosted-agent process only on each agent's committed host epoch.
- Execute one target-driven `goal(DesiredState)` whose selected transition
  changes an agent's own facts.
- Deliver one durable outbox message between two agents.
- Restart the runtime, agent process, and host node during delivery.

This slice deliberately has no FIPA ACL encoding, AMS search, DF, agent
delegation, dynamic handler declaration, or directory federation. Browser
login and the generic signed-agent principal are supplied by the separate
signed-client architecture. `human_user` is one specialisation of the
`agent` class.

Acceptance:

- every replica commits the same outbox fact but only the current host sends it;
- host failover resumes a pending delivery from the agent's containing ontology;
- receiver deduplication makes a crash retry harmless;
- restarting runtime reconstructs the agent without replaying completed E;
- the action and delivery path uses no copied KB.

### Slice 5 -- agent subjects and delegation

**Status: PARTIALLY DELIVERED.** The transitional signed base-user label has
been replaced and deployed as the generic agent-bound identity defined in
`ontology-actor-architecture.md`; no compatibility principal remains.

- Extend that generic identity into immutable delegated subjects.
- Add delegation, capabilities, and receiving-side subject validation without
  replacing the existing signed-goal or `can_invoke/4` paths.
- Test whole-chain authorization and laundering attempts.

Acceptance:

- a node cannot forge an origin agent or remove a delegation hop;
- signature replay and subject substitution fail;
- private origin-agent facts are not exposed by directory queries.

### Slice 6 -- complete agent lifecycle and local AMS

- Complete `quod:agent` beyond the Slice 4 minimum.
- Add `quod:node`-governed host assignment and migration policy above the one
  hosting projection owned by `event-reaction-refinement-plan.md` Slice 4,
  using the stable physical-node references from
  `node-instance-identity-plan.md`. Do not implement another hosting owner.
- Implement AID construction and AMS operations.
- Implement wielding.

Acceptance:

- killing an agent process reconstructs it from facts;
- moving the committed host epoch starts exactly one current process;
- an unauthorized user cannot wield or manage an agent;
- AID identity remains stable when endpoints change.

Client/world validation milestones are kept separately in
`doc/client-world-direction.md`; they are not prerequisites for the next slice.

### Slice 7 -- minimal FIPA request protocol

- Implement ACL encoding, validation, MTS routing, and conversation state.
- Implement request/agree/refuse/failure/inform/not-understood/cancel.
- Map requests to target-owned `goal(DesiredState)`.

Acceptance:

- local, co-hosted, and remote conversations have identical semantics;
- malformed or out-of-sequence messages fail loudly;
- restart resumes durable conversations without replaying completed messages;
- load tests show that ACL traffic cannot starve consensus.

### Slice 8 -- public ontology discovery and independent local DF

- Implement the approved Prolog-owned public-name-to-exact-identity discovery
  service above the existing route resolver. Do not put public-name policy in
  `quod_directory`, and do not add another live-route owner.
- Feed contact hints into existing identity/host verification; neither a public
  discovery result nor DF/AMS/MTS/OA output is an authoritative route.
- Independently implement indexed local DF agent/service operations and leases.

Acceptance:

- an unknown node can resolve an ontology without already hosting it;
- a public name resolves first to an anchored identity and then independently
  to a verified current route;
- stale endpoints do not alter durable identity;
- DF, AMS, MTS, or OA-like output alone never becomes an ontology route;
- local service registration and bounded search survive restart.

### Deferred FIPA extensions

- Add query-if and query-ref over the existing ask engine.
- Add subscribe/cancel after the explicit certified ontology-subscription
  slices in `ontology-subscription-plan.md` exist.
- Add bounded DF federation only when more than one real AP directory needs it.
- Add broker/recruit/contract-net only when required by a real application.

## 17. Documentation replaced by this plan

The replacement is already in force for delivered reaction work:

- `doc/content-layer-design.md` is a historical architecture record. Its
  section 14 is an as-built overview only; normative reaction semantics live in
  `doc/event-reaction-refinement-plan.md`, while explicit ontology following is
  governed by `doc/ontology-subscription-plan.md`;
- Onia/BBSvx D/P/E and action references are no longer treated as implementation
  specifications;
- `doc/client-world-direction.md` remains a non-normative consumer and
  performance-constraint document until its prerequisites land;
- `doc/deferred.md` entries are removed as their slices land;
- each public predicate and metric documents its user-visible meaning and
  execution context.

## 18. Decisions needed before later FIPA slices

These do not block the remaining Slice-4 vertical:

AID identity is no longer an open design choice. Its semantic `Name` is the
canonical agent-reference bytes and its text encoding is fixed in §12; an Agent
Platform appears only in resolver/residency data.

1. The concrete capability vocabulary carried by `subject/3` for wielding and
   delegation. The ACL shape and `agent_instance_ref/3` identities are already
   fixed.
2. Whether durable ACL inbox facts are retained indefinitely, retained by
   conversation policy, or compacted after an acknowledgement horizon.

## 19. First implementation checkpoints

Do not begin with FIPA message syntax.

The core substrate checkpoint has passed: Quod repeatedly separates live from
catch-up apply, rebuilds runtime state without KB copies, dispatches local and
certified-subscribed reactions from canonical `applied_ops`, commits explicit
`trigger_event/1` occurrences, and releases durable DTX group effects through
one journal. This does not claim that all Slice-3 messaging is complete:
acknowledged volatile delivery and the agent durable outbox remain open.

Exactly three prerequisites remain before the Slice-4 hosted-agent vertical can
start: durable outbox delivery; node-instance Slices 2--3, which provide the
stable active `NodeRef`; and the node-vault canonical signing bridge required by
an autonomous hosted agent. Hosting projection is part of the vertical itself,
through the sole owner in `event-reaction-refinement-plan.md` Slice 4.

The product checkpoint remains open. It is Slice 4: two statically configured
agent ontologies, one action, one host-fenced durable message, and recovery
under process and host failure.

Generic agent signing is already deployed. Complete lifecycle, FIPA syntax,
directories, and federation begin only after the product checkpoint survives
restart, repeated catch-up, churn, and load testing. Client/world work remains
a separate consumer of the same runtime architecture and does not gate these
slices.
