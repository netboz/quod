# Quod agents and FIPA -- architecture and implementation plan

**Status:** APPROVED (Yan, 2026-07-17). Slices 1 and 2 are delivered; Slice 3
and later remain pending. The corrected target-driven action/transaction
prerequisite landed in Quod 0.7.58.

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

The first system ontology vocabulary will be:

- `quod:user`: user identities and authentication policy;
- `quod:agent`: agent classes, ownership, lifecycle, AIDs, wielding, AMS, and DF
  vocabulary.

Agent instances are not themselves ontologies. An agent is a durable instance in
an Agent Platform ontology plus, while hosted, a rebuildable Erlang process.

## 2. Non-negotiable invariants

1. **No KB copies.** Proof and runtime workers receive shared MVCC snapshot
   handles, never copied ontology contents.
2. **No speculative side effects.** A predicate called by a normal proof may
   observe reality or stage writes, but may not perform irreversible external IO.
3. **Commit before reality.** Runtime projections and effects run only after the
   corresponding diff is committed and visible in the local KB.
4. **Replay does not emit effects.** Historical replay rebuilds facts only.
5. **Runtime state is reconstructible.** Every process, timer, route index, and
   mailbox registration derived from facts has a reconciliation path.
6. **Ontology ownership is respected.** A foreign mutation is an action request
   executed by the target ontology, never a foreign ready-made diff.
7. **No global FIPA message ledger.** Communication is routed to the involved
   agents. Only state that an agent chooses to remember is committed.
8. **Identity domains remain separate.** Node keys, users, agents, ontologies,
   and transport addresses are different types.
9. **The authenticated subject is end-to-end.** No caller may construct or
   shorten its own authority chain.
10. **Bounded work.** Proofs, reactions, projections, conversations, queues, and
    transport frames all have explicit resource bounds.
11. **One logical effect executor.** Every E effect names one durable logical
    executor. Only the node currently hosting that executor may schedule it.
    Receiver deduplication handles crash retries and the bounded overlap during
    an ownership transfer; it is not the normal defense against every replica
    emitting the same effect.
12. **Runtime declarations are privileged code.** `state_handler`,
    `state_handler_depends_on`, and `react_on` facts are executable
    configuration. They may become active only when their provenance satisfies
    the ontology's runtime-declaration policy.

## 3. Lessons retained and rejected

### Retained

- BBSvx's prove-before-broadcast principle.
- The later Onia model: an Agent Platform is an ontology-level authority and a
  hosted agent is a supervised runtime instance.
- Onia's `subject(User, AgentChain, Capabilities)` authorization context.
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

- The early "agent is an ontology" model.
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
| `effect` | yes | no | no | yes |

Examples:

- `peer_ready/1` is `query`.
- `admit/3` and `remove/1` are `staging`.
- `ensure_agent_started/2` is `projection`.
- `mts_send/2` is `effect`.

Each predicate declares:

- functor and arity;
- class;
- accepted binding modes;
- allowed execution contexts;
- timeout or synchronous cost expectation.

The former per-proof process-dictionary namespace values have been replaced by
one explicit execution context carried in Erlog's `#est.fs` flags. These flags
are created by the engine, survive the MVCC proof boundary, and are not
caller-supplied. The context per kind is:

```text
proof(Namespace, Height, Subject)
projection(Namespace, Height, HandlerId)
effect(Namespace, Height, TransactionId, EffectId, Subject)
```

Registration and invocation fail closed when a predicate is used in the wrong
context. Effect predicates are never callable from ordinary ontology proofs.

> **As built (Slice 1).** The context is one `#qctx{kind, ns, height, subject,
> chain}` record (owned by `m:quod_predicates`), stored under a single
> `none`-valued `#est.fs` flag. `kind` is `proof | verdict | projection | effect`
> — the unified record replaces the separate `proof(…)`/`projection(…)`/`effect(…)`
> tuples above, and adds `chain` (the inter-ontology ask chain, which used to be a
> separate `$quod_ask_chain` value) and a `verdict` kind (a strictly-local
> membership re-proof). `none`-valued means ontology content can neither set nor
> clear it (`set_prolog_flag/2` refuses a `none` flag), so it cannot be forged;
> content may still *read* it via `current_prolog_flag/2` (forge-resistant, not
> secret). Today's fields are fine to expose (`ns`/`height`/`kind`/`chain` are
> already visible to `can_read` policies), but the authenticated **subject** (§10)
> must be carried out-of-band — the `#lp{}`-overlay pattern (as for
> `follow_disabled`), not this readable flag. All four kinds now have concrete
> constructors: normal proofs and membership verdicts, runtime projections, and
> the dedicated snapshot-pinned `quod_prolog:run_action/2` lifecycle path. That
> path derives its node principal in the engine and carries it privately in the
> overlay; ordinary `goal/1` proofs cannot execute lifecycle IO. The
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

The common clauses are loaded by `quod_prolog:build_kb/0` into every ontology's
code baseline; they are not copied into genesis transactions. There is no
reverse-effect lookup, generic fact action, direct-call fallback, or
`assert_effect/1` compatibility path. Domain changes use explicit named
transitions.

Example:

```prolog
record_agent_name(Agent, Name) :-
    assertz(agent_name(Agent, Name)).

action(record_agent_name(Agent, Name),
       [may_manage_agent(Agent), valid_agent_name(Name)],
       agent_name(Agent, Name)).
```

The authenticated subject will be read by authorization prerequisites from
the engine-owned execution context; it is not a positional field of
`action/3`.

Most actions change durable reality and their runtime consequences are derived
from the committed diff by P and E handlers. Explicit node-local lifecycle
actions use the same desired-state declaration shape, for example
`ontology_hosted(Name)` and `ontology_joined(Name, GenesisHash)`, but run only
through the typed `quod_prolog:run_action/2` boundary.

That runner validates the exact ground declaration and authorizes its private
engine-owned principal before reading caller-selected source input. It prepares
the input once, selects the desired state and prerequisites in a read-only
view, and re-authorizes. An already-true target returns success without
lifecycle IO. Otherwise the runner calls the typed create/join helper exactly
once and verifies the exact desired state afterward. Once external IO starts it
is never backtracked; an unobservable completion is `outcome_unknown`.
Lifecycle IO is runner behavior, not the third argument of `action/3`, and no
volatile hosting fact is asserted into consensus.

## 7. Apply, replay, reconciliation, and events

The existing `{committed, Namespace}` publication occurs before
`quod_prolog` has applied the block. It remains suitable for dissemination and
observability, but it must not become the agent event source.

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

### Event envelope

One live-applied material transaction produces this compact event envelope:

```text
#{ns, height, tx_id, subject, diff, effects}
```

Handlers see the committed diff as one transaction, not a stream of independent
operations. `effects` contains only the already-validated bounded descriptors
from that transaction; effect-only transactions therefore cross the same
ordered runtime boundary with `diff = []`. Goal and result remain canonical
ledger blobs and are decoded only by detail readers, not copied into every
runtime event.

> **As built (Slice 1).** The envelope is a map carrying exactly those fields,
> published as
> `{applied_live, Env}` on `{runtime, Ns}`. A map (rather than a fixed `/7`
> record) so Slice 5 can add subject-chain fields without reshaping. It is emitted
> once per material transaction on a **live** commit, including a direct-effect
> transaction with an empty D diff. An
> OCC-rejected transaction publishes `{rejected_live, #{ns, height, tx_id,
> subject, effects}}` with no diff. `subject` is `undefined` until signed subjects land
> (section 10).

### Shared substrate consumers

The post-apply origin and event contract is useful independently of agents:

- deferred reader arc P3 can invalidate bounded predicate caches only from
  `applied_live`, never replay;
- P4 can route read-set notifications from the same transaction-scoped event.

These consumers reuse the origin boundary and handler indexing from Slices 1--2
without depending on hosted agents, FIPA, or client/world work.

## 8. Projection handlers

Projection declarations are facts:

```prolog
state_handler(Id, WatchedPatterns, OnDiffGoal, ReconcileGoal).
state_handler_depends_on(After, Before).
```

> **As built (Slice 2, Yan-amended).** ONE recipe per handler, and no separate dependency
> facts:
>
> ```prolog
> state_handler(Id, WatchedPatterns, Needs, ConvergeGoal).
> ```
>
> The same `ConvergeGoal` runs everywhere with a scope argument appended (declared arity N
> is invoked at N+1 — this erlog has no `call/2`): `all` at reconcile, `{keys, ChangedHeads}`
> after a live change, where the heads are full terms INCLUDING retracted heads, a narrowing
> hint only — a join-shaped handler may treat it as `all`. This replaces the OnDiff/Reconcile
> pair (one recipe cannot drift from itself; idempotency is structural). Ordering is the
> onia/bbsvx action-pattern shape: `Needs` is a list carried IN the declaration, restricted
> in this slice to ground `current(OtherId)` terms so the whole graph validates statically
> at reconcile; matched handlers and their transitive dependents run in the global converge
> order (Kahn, Id-term-order tiebreak — deterministic per node). Arbitrary condition goals
> in Needs are deferred: under `unknown => fail` a typo'd condition is indistinguishable
> from a false one, and data-dependent conditions would activate different handler sets on
> nodes reconciling at different heights.

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

`Kind` is `state_handler`, `handler_dependency`, or `reaction`.

Transaction-author signatures now exist, but validator-side authorization does
not. Until it does, only declarations included in a trusted system ontology's
pinned genesis may be activated. Dynamic declarations remain rejected, even if
an authenticated trusted node could technically commit the fact.

After signing lands, validators authorize a declaration before committing it.
The runtime also verifies the committed provenance before activation as a
defense-in-depth check. External predicate functors referenced by a declaration
must already exist in the release's typed predicate registry; ontology content
cannot load arbitrary Erlang modules.

The first handlers will own:

- hosted-agent processes;
- agent timers;
- AMS/DF indexes;
- MTS delivery routes.

## 9. Reactions and reliable effects

`react_on(Executor, Pattern, Goal)` is durable ontology content, but its body is
an E rule and therefore runs only for live events.

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

Three delivery classes are required:

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

### Durable effects

Reserved for low-rate control-plane or external actions whose loss across a
sender crash would violate semantics and which cannot be reconstructed safely
from current D. The action stages an outbox fact as part of D:

```prolog
outbox(MessageId, Executor, Destination, Payload, pending).
```

`Executor` is normally `agent(AgentId)`. System effects may explicitly use
`node(NodeId)` or another ontology-defined single-owner identity; there is no
implicit `all` executor.

Every replica stores the outbox fact, but only the node currently hosting the
logical executor schedules delivery. If ownership moves, the new owner
reconciles pending entries and continues delivery. Completion is recorded by a
separate transaction. Receivers deduplicate by `MessageId`.

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

## 10. Users and authorization

### `quod:user`

The system ontology defines:

```prolog
user(UserId).
user_key(UserId, PublicKey, Status).
user_home(UserId, Namespace).
can_authenticate(UserId, PublicKey).
can_manage_user(Subject, UserId).
```

It contains identity and routing information, not arbitrary private profile
data. Private data belongs in user-owned ontologies.

### Authentication

1. The transport challenges an Ed25519 user key.
2. `quod:user` resolves it to `UserId`.
3. The user selects an agent to wield.
4. The hosting AP proves `accepts_wielding/2`.
5. The resulting subject is pinned to the session.

The base subject is:

```prolog
subject(UserId, [AgentId], Capabilities)
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

The system ontology defines:

```prolog
isa(agent, thing).
isa(agent_platform, agent).
agent_owner(AgentId, UserId).
agent_platform(AgentId, PlatformNamespace).
agent_state(AgentId, State).
agent_owner_node(AgentId, NodeId).
agent_name(AgentId, Name).
has_capability(AgentId, Capability).
accepts_wielding(AgentId, Subject).
```

The actual instance facts live in the AP ontology that manages the agent.
`quod:agent` owns the common vocabulary and rules.

The hosted process is P-state:

- it exists only on the current owner node;
- it obtains durable state from the AP ontology;
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

- `Name` is globally stable.
- `Addresses` are ordered current transport addresses derived from P-state at
  lookup/send time.
- `Resolvers` are constructed from stable AMS resolver names plus their current
  P-state routes.
- AIDs compare by `Name`.

The complete `aid/4` term is a wire/runtime value, not a committed fact. Only
stable identity, stable resolver names, and policy-approved user properties may
be D. Volatile addresses never enter consensus and are refreshed whenever an
AID is constructed.

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
- `subscribe(Goal)` will use durable subscription state and completion/read-set
  tracking when that facility is implemented.
- `cancel` retracts the corresponding durable commitment or subscription.

The Erlang MTS routes envelopes and enforces transport bounds. Prolog owns their
meaning, authorization, and protocol transitions.

## 13. Three directories

Do not merge these responsibilities.

### Ontology resolver

Maps an ontology namespace to stable registration information and live hosting
routes. Durable data includes namespace owner, genesis anchor, and resolver.
Reachability and current endpoints are P-state learned from authenticated links,
Brahms, and signed announcements.

### AMS -- white pages

Each Agent Platform has one logical AMS authority represented by rules and facts
in its AP ontology. It manages AIDs, lifecycle, residency, and AP description.

### DF -- yellow pages

The DF manages service descriptions:

```prolog
service(AgentId, ServiceId, Type, Ontologies, Protocols, Languages, Lease).
```

It supports register, deregister, modify, and bounded search. Federation carries
a globally unique search ID, maximum depth, maximum results, and visited set.

DF registration advertises a capability; it does not guarantee that an agent
will accept a particular request.

## 14. Performance architecture

1. All proof and handler contexts use MVCC snapshot handles.
2. Hot AMS, DF, AID, route, and handler indexes are P-state ETS tables rebuilt
   from ontology facts.
3. A live commit performs no network IO or P work on the Simplex or Prolog
   process.
4. The ordered `quod_runtime` tier performs only bounded index updates and
   enqueue operations. Heavy P runs in independent bounded resource workers.
5. E workers are supervised and concurrency-limited per namespace and agent.
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

Do not scaffold the end state. Slices 1--4 need only three new modules plus one
narrowed existing one:

- `quod_prolog` (existing, narrowed): D proof and committed projection only.
- `quod_runtime` (existing): ordered post-apply P orchestration and reconciliation.
- `quod_outbox` (future): durable effect delivery and deduplication.
- `quod_predicates` (existing): predicate registration metadata and context
  enforcement.

Reaction matching and scheduling may begin inside `quod_runtime`; split it only
when measured complexity or contention justifies a separate module.

Later slices introduce responsibilities for hosted-agent supervision, subjects,
MTS routing, AMS/DF indexes, and ontology resolution. Their ownership boundaries
remain explicit, but they may share a module while small. A named module is
created only when its slice lands and the code has a real API to hold.

The per-namespace supervision order becomes:

```text
simplex -> prolog -> runtime -> prove/catchup/feed endpoints
```

`runtime` depends on the committed KB and can be restarted/reconciled without
restarting consensus or rebuilding the KB.

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
> action-pattern Needs (the §8 as-built note above); §8.1's provenance check is a FULL-TERM
> match against the founding (slot-1) block — currently the sole lock, since no write ACL
> exists yet — with retracted/nonground founding declarations a distinct loud unhealthy and
> dynamic declarations refused+counted. The whole discovery+plan+converge pipeline runs in a
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

- Implement transaction-scoped event matching.
- Add bounded best-effort reactions.
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
- Add metrics and Grafana panels.

Acceptance:

- history replay sends nothing;
- a crash between commit and delivery is recovered;
- an ownership transfer may overlap sends but receiver deduplication preserves
  one logical effect;
- duplicate delivery does not duplicate the receiver's action;
- load tests price the two-commit durable path separately from acknowledged
  volatile delivery and show lower-priority traffic cannot starve consensus;
- loops and worker exhaustion are bounded.

### Slice 4 -- minimal agent vertical slice

This is the proof of the architecture and remains trusted-fleet-only.

- Add minimal genesis content for `quod:user` and `quod:agent`.
- Add one AP ontology with statically declared agent owners.
- Reconcile one hosted-agent process on only its owner node.
- Execute one target-driven `goal(DesiredState)` whose selected transition
  changes AP facts.
- Deliver one durable outbox message between two agents.
- Restart the runtime, agent process, and owner node during delivery.

This slice deliberately has no FIPA ACL encoding, AMS search, DF, user login,
dynamic handler declaration, or directory federation.

Acceptance:

- every replica commits the same outbox fact but only the owner sends it;
- owner failover resumes a pending delivery;
- receiver deduplication makes a crash retry harmless;
- restarting runtime reconstructs the agent without replaying completed E;
- the action and delivery path uses no copied KB.

### Slice 5 -- signed users and subjects

- Build user/subject authorization on the implemented transaction signatures.
- Add `quod:user`.
- Implement authentication and immutable subjects.
- Test whole-chain authorization and laundering attempts.

Acceptance:

- a node cannot forge a user or remove a delegation hop;
- signature replay and subject substitution fail;
- private user facts are not exposed by directory queries.

### Slice 6 -- complete agent lifecycle and local AMS

- Complete `quod:agent` beyond the Slice 4 minimum.
- Add AP lifecycle and migration actions.
- Implement AID construction and AMS operations.
- Implement wielding.

Acceptance:

- killing an agent process reconstructs it from facts;
- moving ownership starts exactly one owner process;
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

### Slice 8 -- ontology directory and local DF

- Replace ad hoc namespace contact resolution with the ontology resolver.
- Implement indexed local DF operations and leases.

Acceptance:

- an unknown node can resolve an ontology without already hosting it;
- stale endpoints do not alter durable identity;
- local service registration and bounded search survive restart.

### Deferred FIPA extensions

- Add query-if and query-ref over the existing ask engine.
- Add subscribe/cancel after completion subscriptions exist.
- Add bounded DF federation only when more than one real AP directory needs it.
- Add broker/recruit/contract-net only when required by a real application.

## 17. Documentation replaced by this plan

Once approved and implemented:

- `doc/content-layer-design.md` section 14 becomes historical and points here;
- Onia/BBSvx D/P/E and action references are no longer treated as implementation
  specifications;
- `doc/client-world-direction.md` remains a non-normative consumer and
  performance-constraint document until its prerequisites land;
- `doc/deferred.md` entries are removed as their slices land;
- each public predicate and metric documents its user-visible meaning and
  execution context.

## 18. Decisions needed before Slice 5

These do not block Slices 1--4:

1. Whether one `quod:user` committee holds every `user_key/3`, or whether it
   stores only user-home pointers and delegates key ownership to sharded
   user-authority ontologies. The recommended initial implementation is one
   sparse registry, with private data elsewhere.
2. The canonical globally unique AID name format. The recommended form is a
   stable agent ID qualified by its home AP, not by its current node.
3. Whether durable ACL inbox facts are retained indefinitely, retained by
   conversation policy, or compacted after an acknowledgement horizon.

## 19. First implementation checkpoints

Do not begin with FIPA message syntax.

The substrate checkpoint is Slices 1--3: prove that Quod can repeatedly
transition between live and catch-up apply, rebuild runtime state without KB
copies, and deliver a durable effect without loss or replay duplication. The
same checkpoint unlocks deferred reader-cache invalidation and read-set
notification routing.

The product checkpoint is Slice 4: two statically configured agents, one action,
one owner-gated durable message, and recovery under process and owner failure.

Only after both checkpoints survive restart, repeated catch-up, churn, and load
testing do signing, complete lifecycle, FIPA syntax, directories, and federation
begin. Client/world work remains a separate consumer of the same runtime
architecture and does not gate these slices.
