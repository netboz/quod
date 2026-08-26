# Uniform distributed Prolog proofs and atomic ontology writes

**Status:** architecture reviewed and implemented. Step 1's local `action/3`
and `transaction/1` foundation landed in
Quod 0.7.58. Step 2's shared proof context and recursive co-hosted scopes landed
in Quod 0.7.60. Step 3's hard-break shared scope transport landed in Quod
0.7.61. Step 4 now includes both the one-participant fast path and the complete
Begin/Prepare/Decision/Finalize/Complete multi-ontology path, durable recovery,
certified-current outcome/application corroboration, and the indexed anchored
outcome contract. Step 6 is the recurring release/hardware acceptance
procedure, not unfinished transaction semantics. Any later incompatible format
still requires its own clean re-found and the current release gates.

This plan is the prerequisite correction for the action work in
`minimal-agent-delivery-plan.md`. It is deliberately complete: it does not ship
a read-only `::`, a single-writer restriction, independent partial commits, or
another compatibility path.

### Existing implementation: reuse the mechanism, remove the semantic split

The current inter-ontology implementation is not discarded wholesale. It
already has the expensive infrastructure that a uniform proof needs:

- `quod_erlog_db_mvcc` provides the pinned committed view;
- `quod_erlog_db_local_prove` provides the private write overlay and OCC read
  set;
- `quod_ask` already implements `::` selection, co-hosted/remote routing,
  demand-driven backtracking, safe term encoding, and the immediate-caller
  failure-reason boundary;
- `quod_ask_router`, QUIC identity pinning, worker monitors, timeouts, and
  cancellation provide the transport pieces; Step 3 adds the explicit router
  admission bounds below;
- the normal `quod_prolog` path already builds the unsigned transaction and
  waits for ordered apply with the `outcome_unknown` contract;
  `quod_simplex:sign_local_change/2` reserves the author sequence and signs it.

The original mistake was narrower and directly visible in the old code:
ordinary local proofs used the one-shot `quod_prolog:run_proof_est_annotated`,
while selected ontologies used a second resumable loop in
`quod_ask:answer_init` / `answer_loop` / `step` / `drive`. That second loop
dropped the read set and rejected every overlay change. Steps 2 and 3 replace
both with one reusable resumable scope runner combining the old continuation
mechanics with the normal overlay setup, annotation, error mapping, and cleanup.
Ordinary local and selected proofs delegate to it; `prove_est/2` remains only a
thin synchronous wrapper for runtime projection calls. The separate answer
interpreter is deleted rather than preserved as a third proof engine.

Across machines there must still be a worker process on the machine hosting the
selected ontology. “The same proof process” therefore means the same worker
implementation, state machine, overlay semantics, limits, and failure behavior;
only its location and transport differ.

## 1. Contract

`::` is only an ontology selector.

```prolog
local_predicate(X)
other_ontology::remote_predicate(X)
```

have the same Prolog call semantics. The second form changes the ontology that
owns and executes the predicate; it does not change whether the predicate may
read, assert, retract, fail, produce another solution, use a cut, or call a
third ontology.

“Same” means the existing Quod semantics exactly. During a proof, the private
overlay preserves Erlog assertion order and backtracking behavior. Durable
facts continue to use Quod's documented content-identity commit model (an
identical committed clause is not a second durable fact). This milestone does
not silently replace that project-wide fact model while fixing `::`.

One top-level proof may therefore execute:

```text
A -> B -> C
```

and finish with staged changes in A, B, and C. If the outermost proof succeeds,
all selected changes commit. If it fails before durable coordination starts,
none commit. Once durable coordination starts, the outcome is one atomic commit
or one atomic abort; an uncertain caller receives the exact outcome handle
(`{transaction, TargetNs, TargetAnchor, TxId}` for any one-ledger fast path,
including a sole foreign target;
`{group, OriginNs, OriginAnchor, Coordinator, CoordinatorAdmission, GroupId}`
for a multi-ledger proof) and queries that handle instead of re-running the proof.
The namespace and genesis anchor remain explicit because an opaque `TxId`
cannot route itself, and the caller must pin the exact founding whose durable
answer may live on another ontology.

The implementation is physically distributed because each ontology owns its
KB and consensus log. Semantically it is one recursive Prolog execution.

## 2. Calls, failures, cuts, and backtracking

### 2.1 Failure stays local until the caller exhausts

For A -> B -> C:

1. C failure is returned only to B, with C's bounded failure-reason stack.
2. B merges those reasons into its proof state and performs ordinary Prolog
   backtracking. B may try another clause, inspect `get_fail_reasons/1`, recover,
   and use a cut normally.
3. If B eventually succeeds, A receives B's solution; C's failed attempt is not
   independently reported to A.
4. Only if B exhausts does B fail to A. The returned stack may then contain the
   nested C reasons and B's enclosing predicate frames.
5. The same rule applies recursively up to the top-level caller.

Failure reasons remain proof-local, bounded, and atom-safe while Prolog is
still searching. Only the canonical terminal reason stack of a certified group
abort is copied into `Decision(abort)`; intermediate failed alternatives and
recovered reasons never enter a ledger. `fail_with_reason/1` and the automatic
failing-predicate frames are the single diagnostic mechanism on local,
co-hosted, and remote paths.

### 2.2 Preserve Erlog semantics; do not invent remote semantics

Ordinary Quod overlays retain Erlog's existing database behavior: assertions
and retractions survive ordinary backtracking. Only an explicit
`transaction/1` enables database checkpoints at choice points. A remote
completion therefore
returns its resulting scope state even when the remote goal has no solution.
For example, the remote form behaves like the local form:

```prolog
(B::(assertz(x), fail) ; B::x)
```

The second branch sees `x`. The pinned Erlog fork adds an opt-in checkpoint
hook to choice points for `transaction/1`; outside that mode its execution is
the same single cons operation as before.

A cut only selects Prolog alternatives. It neither commits a ledger nor creates
a distributed-commit boundary. Durable submission begins only after the
outermost proof has selected a complete solution.

### 2.3 `transaction/1` is the explicit rollback boundary

Register one compiled `transaction/1` predicate in every Quod ontology. It uses
Erlog's existing continuation/fail machinery and Quod's immutable-overlay
representation, plus one boundary choice point and the checkpoint/restore APIs
specified in section 4.1. There is no existing transactional nested-prove API
to pretend to reuse. The pinned Erlog fork therefore exposes an explicit,
nestable choice-point-checkpoint mode; ordinary proofs never enter it.

`transaction(Goal)` is semidet: it searches for the first complete solution,
commits that selected staged state, and exposes no inner redo to its caller. It
enters `Goal` through fresh `call/1` and `once/1` cut barriers. A cut inside
`Goal` may prune alternatives created inside that transaction call but cannot
prune caller alternatives outside it; a caller cut has only its normal effect
on caller alternatives. Do not append the raw inner goal directly to the
caller continuation.

Its savepoint contains:

- the current ontology's exact overlay state, including assertion order,
  retractions, and abolishes;
- from step 3 onward, the distributed proof context's exact per-scope
  savepoint generation. The 0.7.58 local foundation checkpoints only its
  initiating ontology; it is not the complete cross-ontology transaction
  contract by itself.

Before Erlog tries an alternative, the choice point restores the overlay that
existed when that alternative was created. On the first complete solution, the
selected state is adopted and the inner alternatives are cut. On logical
exhaustion, every local and foreign change made inside is restored and the
accumulated failure reasons remain available. On an Erlog error, state is
restored and the same error is rethrown. Across `::`, that bounded error is
returned to the immediate parent scope through the same atom-safe Prolog-term
codec as solutions and failure reasons, then raised there with the same local
semantics. An Erlog exception is not converted into logical failure or an
infrastructure poison; if user code does not handle it, it propagates one caller
boundary at a time. Nested transactions compose.

Read dependencies are deliberately **not** rolled back. A read in a failed
transactional branch may be the reason the surrounding proof selected another
branch and wrote a result. Every scope therefore unions its OCC read set for the
whole top-level proof, while only assertions/retractions/abolishes are restored.
This reuses the current monotonic read-set behavior instead of trying to make
the ETS read set transactional.

Thus assertions and retractions roll back symmetrically:

```prolog
transaction((A::step_a, B::step_b, C::step_c))
```

retains all three scope states on success and restores all three on failure.
External irreversible IO is not a legal transition inside this predicate; it
continues to run only after durable D-state commit through the existing D/P/E
boundary.

## 3. Correct `action/3`

The common relation is:

```prolog
action(Transition, Prerequisites, DesiredState).
```

The third argument is the state the caller wants. In a simple action that state
may also be the fact its transition asserts, but that is one implementation of
the pattern rather than a rule for the runner. More than one action clause may
reach the same desired state, and transitions may reach it in different ways.

`goal(DesiredState)` works as follows:

1. require `DesiredState` to be a non-variable callable term, then prove it; if
   already true, cut and succeed without a transition;
2. otherwise enumerate matching `action(Transition, Prerequisites,
   DesiredState)` clauses in Prolog order;
3. inside one `transaction/1`, prove the prerequisites in order, run the
   transition, then prove `DesiredState` again;
4. if that candidate fails, its assertions and retractions in every touched
   ontology are restored and the next matching action clause may be tried;
5. succeed only with the state of the selected candidate whose postcondition
   proved true.

Both DesiredState checks and ordinary prerequisites run through one internal
state-check helper backed by the existing strict read-only overlay against the
current staged view; the first attempted assert/retract/abolish fails loudly,
even if a later operation would cancel its net diff. This is identical for
local and `::`-selected predicates. It is a mode of the shared proof worker,
not a second policy evaluator.

Prerequisites are a finite proper list. The common Prolog runner distinguishes
their shapes explicitly: `goal(State)` and `Ns::goal(State)` run normally and
may achieve that state recursively inside the candidate's surrounding
`transaction/1`; every other callable term is passed to the internal read-only
state-check helper. `Transition` is either one non-variable callable goal or a
non-empty proper list of such goals, executed in order and allowed to stage D
writes. Invalid shapes fail before any candidate goal runs. This removes the
apparent contradiction between “prerequisites are checks” and an explicitly
requested recursive `goal/1` prerequisite.

Keep term-identity cycle detection. Remove the current forward action-name
interpretation, reverse effect lookup, `assert_effect/1`, generic
`assert_fact`/`remove_fact` actions, `reverse_goal_allowed/1`, literal-`true`
lifecycle declarations, and their stale tests and comments. There is no
compatibility wrapper.

Ontology create/join operations use the same `execute` proof and `action/3`
relation as every other durable goal. Their staging bridge prepares one typed
effect in the proof overlay; it never performs IO during the proof. The
root transaction controls creation and the node transaction controls join.
The effect request is committed through the normal one-participant transaction
or, when the same proof has another material ontology, through the same
Begin/Prepare/Decision/Finalize/Complete group as the other plans. The one
node-wide journal owns custody in both cases, invokes the typed helper only
after the local commit is applied, then verifies the real desired state. This
is the D/P/E boundary made explicit, not a second executor or a claim that
external IO is rollback-capable.

## 4. One proof context, one scope per ontology

The existing local `quod_prolog` proof worker and selected-ontology scope
session now use one proof-scope runner. The duplicated `quod_ask` answer loop
and its separate remote read-only policy have been removed. The same runner
owns the frozen view, overlay, Erlog state,
failure reasons, alternatives, and limits for an origin scope or a selected
remote scope. Separate local/remote admission quotas remain a DoS boundary, not
a semantic distinction. The ordinary top-level proof path calls this same
resumable runner; there is no parallel first-solution interpreter.

`quod_proof_scope` is only the extracted worker-loop library run by the process
that existing `quod_prolog` already spawns and monitors. It is not a new OTP
service, supervisor, registry, coordinator process, or overlay owner. The
origin proof worker owns coordination for exactly its existing lifetime. The
new architecture is the cross-ledger atomic commit below, not another remote
proof framework.

`quod_ask` becomes the compiled `::` predicate plus co-hosted/QUIC transport for
that worker. Keep its caller-side `drive_stream`, compiled choice point,
variable grafting, and failure-reason merge: those already give `::` ordinary
Prolog backtracking and cut behavior. Remove only the target-side
`start_answer`, `answer_init`, `answer_loop`, `step`, and `drive` proof engine;
scope open/invoke/resume now address the shared worker. The hard-break wire
delta removes the old `quod_ask_open`, `quod_ask_next`, and `quod_ask_cancel`
frames and their decoders rather than retaining two session protocols.

Every top-level proof receives a cryptographically random 32-byte `ProofId`.
Its origin proof worker owns one small context for the whole run:

```text
origin ontology identity and origin scope
subject and ontology call chain
absolute proof budget
selected scopes: ontology identity -> origin-bound scope session
active logical invocation stack and transaction savepoint generations
```

An ontology identity is exactly `{Namespace, GenesisAnchor}`. The Prolog syntax
continues to name only `Namespace`; resolution must yield exactly one pinned
32-byte genesis anchor or fail with `anchor_conflict`.

The first call into B finds no B entry and opens one B-owned scope worker on a
current B validator. That worker contains a pinned committed MVCC height, a
private Quod overlay, its read set, and its invocation continuations. A later
call to B finds the existing handle and resumes that exact worker, so it sees B
writes staged by earlier B calls.

The map does **not** travel as a transferable bearer capability. When B reaches
`C::Goal`, B sends a correlated nested-selection request to the origin worker.
The origin looks up or opens C, proxies C's answers back only to the suspended B
invocation, and records the updated C state in its one map. Evolve
`quod_ask_router` into the one bounded correlation and cleanup router for scope
frames and nested-selection proxying; it does not interpret Prolog or own an
overlay. It gains explicit global/per-owner/per-peer admission caps and an
owner-monitor-to-`ProofId`/scope set. Delete the separate `watch_owner` /
`stop_owner` cancellation owner rather than retaining two cleanup registries.
All target sessions are opened from and bound to the authenticated origin node,
so B never receives a C credential it could replay or use with a shortened call
chain.

The logical failure path remains C -> B -> A even though the origin physically
proxies the bytes: the proxy never merges C diagnostics into A. B alone merges
them into B's Erlog state and either recovers or eventually returns its own
completion to A. If A or another later branch selects C, the origin reuses the
same C session rather than opening another snapshot.

Scope workers are depth-first and re-entrant, never concurrent writers. While a
scope is suspended in `::`, its selector wait loop continues servicing a nested
invocation plus correlated checkpoint, restore, and cancel control messages for
that same scope. A transaction's initiating scope restores its own current
`#est`/overlay directly; the origin restores the other touched scopes and
returns their revisions, avoiding a self-call to the waiting initiator.
Therefore A -> B -> C -> B has ordinary recursive
behavior rather than deadlocking. Re-entry uses B's current overlay; when an
older continuation resumes, its saved bindings and choice points are retained
but its database reference is replaced with B's then-current overlay. The old
`circular_ask` rejection is removed. The existing depth/lifetime limits remain
resource bounds, not a special circular-call semantics.

Local, co-hosted, and remote selection share this one handler. Location changes
only transport. This selector authority belongs to engine-owned anchored
content proofs. Raw verdict, projection, and committed-policy adapters remain
local deterministic boundaries and cannot manufacture origin authority from
the content-readable execution context.

### 4.1 Scope sessions and continuations

Every solution and every logical completion carries the solution or bounded
failure reasons plus its invocation id and answer sequence. The target keeps
the exact overlay and Erlog continuation; it does not send a caller-owned diff
or a serialized interpreter through the network.

The target stores the opaque session state server-side, bound to format version,
`ProofId`, `{Namespace, GenesisAnchor}`, origin and target node keys, session id,
base height, current overlay revision, and expiry. Each invocation separately
carries the origin-constructed semantic call chain and current authenticated
subject; a scope may legitimately be reached through several different chains.
The origin assigns one strictly increasing command sequence per remote scope
and one unique bounded request id per command. The target advances its expected
sequence when it accepts a command, before that command executes. At most one
demand for a particular invocation is outstanding, but another invocation may
run re-entrantly while the first is suspended in `::`; replies echo request id
and accepted command sequence and may therefore arrive out of command order.
The target assigns a separate event sequence in actual outbound-send order,
while every invocation retains its own answer sequence. Duplicate, stale,
skipped, cross-proof, and cross-node live-scope commands are protocol errors and
never execute Prolog.
QUIC stream delivery and `send_reliable/3` do not create an accepted-frame
redrive path, and link loss poisons the volatile proof, so step 3 adds no reply
replay cache. Durable DTX record idempotency in section 9 is a separate step-4
mechanism. Scope command sequence, request correlation, target event sequence,
invocation answer sequence, and scope overlay revision remain distinct.
An old invocation continuation is not rejected merely because the scope overlay
advanced: invocation answer sequence and scope overlay revision are separate.

Every remote `opened`, solution, completion, bounded Erlog error, typed error,
and savepoint checkpoint/restore/release acknowledgement carries the target
scope's authoritative current boolean dirty state and overlay revision inside
the authenticated envelope. Dirty is the current effective state, not an
ever-dirty latch: restoring a write-empty revision may legitimately change it
from true to false. The origin applies dirty updates only in authenticated
target-event order before delivering the correlated event. A missing,
malformed, stale, or inconsistently bound dirty value is a protocol error that
poisons the proof; the step-3 final foreign-dirty gate never guesses that a
remote scope is clean.

Each scope has one current overlay plus bounded invocation continuations. When
an older `::` choice point requests another answer after a later invocation
changed the same ontology, the scope keeps that choice point's bindings and
continuation but runs it against the scope's current overlay. This matches local
Erlog: choice points restore bindings, not database writes.

Add small exact APIs to `quod_erlog_db_local_prove` for checkpointing and
replacing the immutable local overlay record. They do not copy the committed
KB. A checkpoint shares the one monotonic read-set ETS table, so restoring an
overlay restores writes and assertion order but never forgets a dependency.
The existing `committed_state/1` is not misused for this purpose—it deliberately
drops staged state and remains for isolated committed-view policy proofs.
Likewise, action state checks temporarily enable `read_only` on the **same**
overlay/read-set and disable mutation hooks, then restore the flag; they do not
wrap an overlay inside another overlay or create a second dependency set.

`transaction/1` checkpoints its current local overlay whether it begins in the
origin or in a selected scope, then asks the origin-owned controller to open one
correlated savepoint id. On the first use of another scope under that id, the
origin sends that scope a lazy-checkpoint command; a newly opened scope records
a write-empty pre-entry overlay over its pinned base. The initiating scope
restores its own `#est{}` and is excluded from the controller-driven restore;
the controller restores every other touched scope's saved overlay revision. A
scope first opened in the failed branch remains pinned and registered until the
top-level proof ends, with its writes restored, because its monotonic read
dependencies can still influence the surrounding proof. Success keeps each
current overlay state.

One scope worker executes only one derivation at a time, but re-entry means
multiple invocation requests may be outstanding and their replies need not
follow request order. The origin dispatcher correlates them independently. A
re-entrant descendant may change an ancestor while its older invocation is
suspended; on resumption the saved continuation receives that scope's current
overlay reference. Savepoint commands therefore use explicit revisions and
never assume a waiting ancestor is frozen. Savepoints retained solely by a
cut-away continuation are reaped with the proof, so distributed savepoint
cleanup needs no additional cut hook beyond step 1's opt-in Erlog choice-point
checkpoint support.

Only at final seal does each target validator sign its own immutable local plan.
The origin never submits a caller-fabricated B or C diff.

Potentially writable scopes use current validators, not observers. Route
selection skips an observer and tries the next pinned route. This includes the
top-level origin: a request received by an observer either redirects/opens the
origin shared scope on a current validator before proving, or is explicitly
`prove_ro`; an observer never proves a diff and hands it to a validator. Explicit
`prove_ro` propagates a private read-only mode through every nested call and each
target rejects the first mutation attempt.

Replace the misleading remote-only `can_read/3` admission rule with one
target-owned `can_invoke(Goal, Principal, CallChain, TargetNs)` rule; there is no
compatibility alias. For the current milestone `Principal` is the real
engine-owned `node(OriginKey)`, derived from the authenticated origin control
link and kept in private worker/overlay state—not accepted from Prolog and not
pretended to be a user. The origin constructs the call chain from its active
invocation stack, so an intermediate cannot omit itself. The target proves the
rule for **every** scope entry—top-level, self, co-hosted, or remote—and every
participant committee re-proves the bounded
transcript in a deterministic verdict context before Prepare. Policy reads join
the local plan's OCC dependencies; mutation or live query bridges fail closed.
Both checks use a strict read-only frame over the target scope's pinned
**committed base**, never staged writes. A proof therefore cannot stage an
authorization grant and consume it in the same transaction; the grant must
commit first. This keeps Prepare re-validation deterministic without replaying
the whole execution transcript.

A denial runs none of the requested goal and is an ordinary logical failure
carrying a bounded `not_allowed(TargetNs)` reason through the standard
`fail_with_reason/1` mechanism, so a caller may inspect it with
`get_fail_reasons/1` and take another branch. The security property does not
depend on that choice: the denied goal never runs, so the target discloses
nothing and mutates nothing, and only the caller's own control flow continues.
Because a proof's diff may therefore depend on a *negative* decision, the
authorization transcript records refused invocations beside accepted ones, and
every participant committee re-proves a refusal as false against the same
pinned committed base — the check is symmetric, so Prepare stays deterministic.

The retired `can_read/3` ran once for **every** authenticated peer/ontology
subject in the incoming chain and required all calls to succeed. `can_invoke/4` instead
receives the canonical whole chain once. A restrictive migrated policy must
therefore inspect/quantify every `CallChain` member itself; `Principal` replaces
the authenticated peer argument but does not silently preserve the old
per-member conjunction. Shipped policies are rewritten and tested explicitly;
there is no compatibility loader.

No matching `can_invoke/4` clause means deny — with one exception every ontology
is born with. `can_invoke/4` gates *every* scope entry, including a proof
entered on this node with no caller ahead of it (an empty call chain). That
entry is always the host's own top-level proof — a wire or co-hosted invocation
always carries its origin in the chain, and the target rejects an empty chain
from the wire — so founding injects one bodyless host-entry default,
`can_invoke(_Goal, _Principal, [], _Ns)`, into every genesis diff, exactly as it
injects `consensus_incarnation` and `peer_admitted`. It reads no committed
state, so it cannot hit a not-yet-applied-policy race, and because founding
injects it rather than the author, an author can never omit it and lock the host
out of its own ontology. Remote and
cross-ontology callers (a non-empty chain) match nothing by default and stay
fail-closed until author clauses admit them. A private ontology therefore needs
no author clause at all — it is host-answerable and otherwise closed — while a
shipped ontology intended to be publicly readable carries an explicit
default-open `can_invoke(_,_,_,_)` clause in its own source. This is the current
trusted-host starting point; a later milestone may express host self-trust more
precisely than empty-chain matching.

Because the host-entry default is always injected, a valid genesis always
carries an asserted `{can_invoke,4}` head. The genesis validator keeps that as a
defense-in-depth check against a hand-built policy-less or non-assertion genesis
that bypasses `genesis_tx`: one shared pure invariant over the
assertion-only genesis diff, called by `quod_simplex:genesis_tx/4` before slot-1 append
for file, in-memory, direct-manager, and boot founding paths, and by
`valid_history_entry/4 -> valid_genesis_transaction/2` during restart/catch-up,
so an assert-then-retract or hand-built policy-less genesis cannot enter through
either path. Runtime create no longer rejects a policy-less author diff — the
default makes one unnecessary — and a resume keeps its existing ignored-options
contract. Every superseded ledger format stays rejected by the hard break.

The prepared `InitialDiff` has a separate concrete bound: at most 192 KiB in
deterministic encoding. Runtime preparation, config validation, and the genesis
builder share `MAX_GENESIS_INITIAL_DIFF_BYTES` from
`quod_ingress_limits.hrl`; boundary+1 returns
`ontology_creation_failed(initial_content_too_large)` before runtime manager or
storage mutation. The complete generated genesis transaction remains subject
to the existing exact 256 KiB block ceiling.

The policy-presence invariant continues after genesis. A content diff that does
not touch `{can_invoke,4}` takes no extra path. If it does, the ordinary apply
path first builds its existing immutable post-diff state and requires that state
to retain at least one interpreted `can_invoke/4` clause before publishing it;
otherwise the transaction is deterministically rejected as
`policy_self_seal_forbidden`. This examines the final state, so one transaction
may atomically replace its last policy clause. A distributed participant makes
the same pure check against its pinned parent during Prepare, before recording
the hidden plan; its namespace lock then preserves the result through Finalize.
Replay/catch-up takes the same ordinary or distributed apply path. Retractions
produced by `abolish/1` need no exception. The check is a small `quod_diff`
helper over the already-built immutable state, not a Prolog proof or operator
bypass.

The old `can_read/3` clauses are removed in the same hard break rather than
loaded beside the new rule. Same-VM and signed create/join requests are ordinary
`execute` goals: both pass through `can_invoke/4`, the declared Prolog action,
sealing, and the transaction/effect path. The raw manager helpers are private
execution machinery (and TEST-only convenience wrappers), not a supported
authorization or content-repair API. Arbitrary host VM control remains outside
the authorization boundary, but no operator policy override is added.

Generic agent authorization now enters this same distributed-proof boundary
without changing its semantics. The target's current validator still owns the
scope, seals its own plan, and authors its own ledger records; a caller never
supplies or signs a target ontology's diff.
`subject(Agent, AgentChain, Capabilities)` carries stable
`agent_instance_ref(Namespace, GenesisAnchor, Instance)` values, while the
request signature separately proves the submitting active key. The former
unauthenticated public prove endpoint is deleted; the Explorer console uses the
ordinary authenticated signed-goal path.

The public proof API becomes `quod_prolog:prove(Namespace, Goal)`; origin
ontology and node principal are derived from the actual origin scope/engine.
Delete the caller-supplied `CallerNs` argument rather than repurposing it as
authority. Nested entry is possible only through the compiled `::` selector and
authenticated session messages.

`ProofId`, the origin controller handle, authenticated principal, and session
authority live in the private shared worker/`#lp{}` state. They never enter the
content-readable `#est.fs` context; only harmless namespace, height, and semantic
call-chain data remain visible to ontology clauses.

### 4.2 Cleanup and bounds

The origin-owned context records every opened scope monotonically for semantic
reuse even when a transaction savepoint restores an older overlay revision. In
addition, every scope open registers its handle immediately with
the origin node's bounded scope router under `ProofId`, before executing the
first goal. That router is only a bounded ownership/cleanup registry; it holds
no Prolog or overlay state. Therefore a B crash after opening C but before
returning C's handle cannot orphan C or hide it from root-proof cleanup.
The router maps have explicit global/per-owner/per-peer admission caps and
reject before monitor/map insertion; monitoring alone is not treated as a
bound.
Normal completion, failure, cancellation, owner death, or deadline closes all
touched scopes.
Monitors perform immediate cleanup; the bounded scope lifetime is the crash
fallback. Snapshot pruning includes all live scope base heights.

The transport-frame and command-envelope byte ceilings are enforced before the
bounded outer frame is decoded. That decoder extracts fixed session/origin
metadata, the bounded call chain, and the still-opaque goal binary. Chain depth,
scopes per proof, active scopes per validator/peer, session identity, origin
context, and rate/admission limits are then checked before the Prolog goal is
decoded, a worker is spawned, or a monitor/map entry is created. Answers per
call, result/read-set/diff sizes, and proof lifetime are enforced as the scope
runs. Generated Prolog terms necessarily exist before their encoded size is
known, so the shared scope worker also has a hard heap cap. After each accepted
answer, mutation, read dependency, and transcript event, one incremental
canonical-byte account checks the answer/diff/read/transcript/local-plan
budgets before retaining it. The implementation uses the existing transport
frame ceiling as the hard outer bound and defines smaller protocol-specific
constants in one shared limits header.

The hard-break open frame carries the nested goal as a separately length-bounded
encoded binary, so fixed outer-frame/session/peer validation can extract only
metadata and `byte_size(GoalBlob)` without decoding the Prolog term. Admission
checks then run before `quod_wire_term` decodes that blob, worker spawn,
monitor creation, or session-map insertion.

Current bounds are concrete and validated at their owning configuration or
codec seam:

| resource | limit |
|---|---:|
| active invocation depth | 8 |
| distinct ontology scopes per proof | 8 |
| commit participants | 8 |
| active proof scopes per ontology | existing configurable 64 |
| active scopes from one authenticated peer | 16 |
| one proof-scope worker heap | 64 MiB, converted once to VM heap words |
| origin-router entries global / per proof owner / per peer | 512 / 8 / 16 |
| inactive invocation continuations per scope | 64 |
| retained activated distributed savepoint generations per proof | 1,024 |
| materialized foreign-scope checkpoints | at most 1,024 per scope / 8,192 per proof, derived from the generation and scope limits |
| answers per invocation | existing 10,000 |
| complete proof / idle scope lifetime | existing configurable 60,000 ms |
| one actively deriving step | existing configurable 30,000 ms |
| one transport frame | existing 1 MiB |
| one encoded nested goal / one answer | 8 KiB / 64 KiB |
| one session command/reply envelope | 128 KiB |
| one failure reason / complete reason stack / retained entries / diagnostic choice-point boundaries | existing 4 KiB / 32 KiB / 256 / 256 |
| one scope invocation transcript | 12 KiB |
| one signed local-plan envelope | 24 KiB |
| top-level goal bytes / durable selected-result bytes | 8 KiB / 16 KiB |
| complete Begin manifest, plans, goal and result | 224 KiB |
| one Complete target/finalize-reference set | 224 KiB |
| one Begin/Prepare/Decision/Finalize/Complete record and singleton block | existing 256 KiB |
| diff operations or read-set functors in one local plan | 1,024 each, also subject to the 24 KiB plan cap |
| ledger-active distributed groups per ontology | 1 (namespace-exclusive first slice) |
| volatile pre-Begin registrations waiting per local ontology/validator | existing configurable proof-worker capacity and deadline; no separate handoff quota |
| accepted dormant Begin intent per local ontology/validator | 1 |
| terminal group entries retained in memory | 4,096 |
| pending foreign-log verifications global / per authenticated peer | 32 / 4 |
| catch-up read workers per hosted ontology / entries per page / response bytes | 32 / 256 / 900 KiB |
| pending exact group-phase lookups per ontology | 2, one per depth-one live pipeline slot |
| outgoing DTX endpoint correlations / inbound endpoint workers per ontology | 512 (`8 participants * 64 validators`) / 8 |
| cached foreign ontology histories / total cache bytes | no protocol population ceiling; dormant disk caches reopen lazily and operator storage monitoring remains operational policy |
| validators in one committee | 64 |

The same constants are used by schema, producer, decoder, validator, replay,
and tests; there are no duplicated magic values. A potentially writable goal is
charged to its transcript/plan budget before it runs, so a valid invocation
cannot succeed and only then discover that its own goal was intrinsically
unsealable. Several proof-owned registrations may wait before signing, but only
one may become the accepted dormant intent. That accepted intent, its activated
successor, and its journaled envelope are one lifecycle and are never counted
as three entries. The maximum eight-row canonical Complete body plus its generic
DTX author envelope must encode at or below the 256 KiB singleton-block ceiling;
the 224 KiB body cap leaves the fixed envelope margin, and boundary/boundary+1
tests pin that inequality. Every transaction-entry and transaction-mode choice-point
generation that has crossed an ontology boundary counts against the 1,024
retained-generation limit. An all-local transaction keeps only Erlog's existing
immutable local checkpoint token and consumes no distributed-generation slot.
On the first foreign selection, the currently reachable transaction tokens are
activated before the selected goal executes; later transaction-mode choice
points activate as they are created. A selected scope materializes at most one
immutable revision reference for a generation; it never copies a KB.
Generation release removes all of its per-scope references, while a cut-away
generation may remain until transaction/proof cleanup and is therefore still
counted. Activation or first materialization that would exceed the derived
bound fails before changing any scope.

## 5. Timeout and error meanings

The current single `no_progress` result is replaced with phase-specific results.
Before durable Begin, all outcomes are definite because no ledger write exists:

- a normal predicate failure carries its failure-reason stack;
- a target scope that explicitly reaches its execution budget aborts the
  top-level proof with `proof_limit_exceeded(Target)`;
- a transport loss aborts it with `ontology_unreachable(Target)` rather than
  claiming the target's predicate timed out;
- an idle scope expiry aborts it with `scope_expired(Target)`;
- malformed/tampered state returns a typed protocol error and invalidates the
  proof.

Logical predicate failure alone participates in ordinary Prolog backtracking
and one-boundary-at-a-time failure-reason propagation. Infrastructure loss is
not converted into logical `fail`: the origin poisons the `ProofId`, closes all
scopes, discards every volatile overlay, and returns the typed definite error.
Before that cleanup, an errored invocation advances a scope only with state
actually returned by Erlog. An error carrying no interpreter state keeps the
last published revision; it must never reinstall an older pre-step revision
over nested work. This retention is deterministic cleanup state, not recovery:
the poisoned proof still commits nothing.
This deliberately simple pre-Begin rule avoids retaining descendant C writes
when B disappears before A acknowledges B's result. `send_reliable` queue
acceptance is never treated as proof-state acceptance, and there is no hidden
automatic retry or re-proof.

The public wrappers apply that distinction to local engine loss too. They use
a call-correlated receive loop monitoring the exact engine; no engine exit is
collapsed into logical failure. `prove_ro`, which cannot hand off a durable write, returns the typed
definite `{error, {ontology_unavailable, Ns}}` if its engine dies. The two
durable paths deliberately order their checkpoints differently:

- An ordinary one-participant proof computes its exact `OutcomeRef` before
  enqueueing its submission and sends that call-correlated checkpoint to the
  wrapper **strictly before** `gen_statem:send_request/2` hands work to Simplex.
  It does not add a synchronous acceptance round trip to the hot write path.
  An engine death after this conservative checkpoint is
  `{error, {outcome_unknown, OutcomeRef}}`, even if the submission was never
  handled; `outcome/1` later resolves that harmless uncertainty definitively.
- A group sends its `GroupRef` checkpoint only after the acknowledged inactive
  hand-off described in §12.2 item 3 and before `activate`; before that
  acknowledgement no group work can sign or commit.

An engine exit after either checkpoint returns `{error, {outcome_unknown, Ref}}`;
an exit before its applicable checkpoint returns
`{error, {ontology_unavailable, Ns}}`. Thus a normal logical failure remains
`fail`/`{fail, Reasons}`, while no engine death can claim that a potentially
durable proof was a logical negative.

Authorization denial is deliberately **not** in that infrastructure class: it is
ordinary logical failure with a bounded reason, and `(DeniedGoal ; AllowedGoal)`
runs `AllowedGoal`. Making it fatal would not be a security boundary — the
denied goal runs either way, so nothing is disclosed or mutated. Making it fatal
would also make denial semantics inconsistent with the engine's own
failure-reason model. An author who wants a denial to be terminal writes an
ordinary cut or lets the failure propagate.

The target engine observes when its shared proof-scope worker starts and
finishes a derivation. It uses that signal to distinguish an execution-budget
kill from an idle requester. Transport failure remains distinct because no
target-authored timeout frame arrived.

After durable Begin, a caller deadline cannot turn the group into a logical
failure: some prepare or decision may already be committed. It returns
`{outcome_unknown, OutcomeRef}` and recovery continues. Automatic re-proving is
forbidden.

The public catalog is exhaustive; old catch-all `no_progress`, `broken_stream`,
and `foreign_write_unsupported` results disappear:

| result | meaning |
|---|---|
| `{fail, Reasons}` | ordinary logical exhaustion; includes bounded nested reasons, and a `not_allowed(TargetNs)` reason when `can_invoke/4` refused an invocation |
| `{error, {erlog, SafeError}}` | bounded Erlog exception, re-raised at the immediate caller with local/co-hosted/remote parity |
| `{error, {bad_name, Term}}` | ontology selector is invalid |
| `{error, {unknown_ontology, Ns}}` | directory has never learned the ontology |
| `{error, {ask_requires_anchored_proof, Ns}}` | a raw internal proof attempted `::` without private engine-derived origin authority |
| `{error, {anchor_conflict, Ns}}` | routes disagree on genesis identity |
| `{error, {ontology_unreachable, Ns}}` | no pinned current-validator route succeeds |
| `{error, {ontology_busy, Ns}}` | target admission quota is full |
| `{error, {ontology_rebuilding, Ns}}` | target is not ready to open a scope |
| `{error, {network_identity_unavailable, Ns}}` | target is ready, but cannot yet obtain the root identity needed to verify a signed scope request |
| `{error, {ontology_unavailable, Ns}}` | the selected local engine died before any durable-submission checkpoint |
| `{error, {proof_limit_exceeded, Ns}}` | active derivation exceeded its budget |
| `{error, {scope_expired, Ns}}` | the bounded session expired while idle |
| `{error, {proof_depth_exceeded, Max}}` | active cross-scope invocation depth is exhausted |
| `{error, {scope_limit_exceeded, Max}}` | distinct-scope limit is exhausted |
| `{error, {savepoint_limit_exceeded, Max}}` | retained distributed savepoint generations are exhausted before allocation or materialization |
| `{error, {too_many_answers, Ns}}` | one invocation exceeded its answer cap |
| `{error, {too_large, Kind}}` | named wire cap failed before decode, or generated-state cap failed before retention |
| `{error, read_only}` | an explicit `prove_ro` tree attempted its first mutation |
| `{error, {non_transactional_dependency, Predicate}}` | live P input influenced a would-be D write |
| `{error, {transaction_pending, GroupId}}` | a lock or visibility frontier is unresolved |
| `{error, {protocol_error, Kind}}` | authenticated frame/session/sequence/domain validation failed |
| `{error, consensus_unavailable}` | durable submission could not start |
| `{error, {outcome_unknown, OutcomeRef}}` | durable submission started but caller cannot yet know the outcome; the reference binds its authoritative namespace and genesis anchor |

Atom-safe decoders map unrecognized remote detail to one of these fixed tags;
they never intern peer-supplied atoms or return arbitrary remote terms. The
bounded `SafeError` payload uses `quod_wire_term`; an unencodable or oversized
exception becomes the fixed `erlog_error_truncated` detail. A worker killed by
its configured heap ceiling is monitored and maps to
`proof_limit_exceeded(Target)`, which poisons and cleans the pre-Begin proof.

## 6. Seal the selected proof

When the outermost proof finds its selected solution, it closes further
backtracking and seals every selected scope. The current validator running each
scope produces one signed immutable local plan, which the rest of that
ontology's committee later validates rather than re-executing the proof:

```text
{OntologyIdentity, BaseHeight, Diff, ReadCheck,
 ProofId, OriginIdentity, InvocationTranscript, EnginePrincipal}
```

`ReadCheck` no longer uses collision-prone `phash2` content values. Reuse the
MVCC store's exact per-functor mutation version and encode each dependency as
`Functor => never_present | {present, LastMutationSlot} |
{absent, LastMutationSlot} | static`. `absent` means the last mutation left no
clauses to serve — a retraction that emptied the predicate (the ordinary diff
path, since `op()` has no abolish) or an abolish tombstone — so
absent -> present -> absent is still a conflict. Prepare requires exact
equality at its parent. This is a deliberate transaction-format break and a
conservative conflict is acceptable if a functor changed and later returned to
identical content (including a transaction whose operations on a functor net
to nothing — it still stages and versions that functor).

Ordinary batches remain safe with slot-granular versions because validation
runs at each transaction's exact block position: the apply-time re-check reads
the store handle that already carries the earlier same-block staged writes, and
a functor with a staged write reports the `staged` token, which equals no
capturable token. A transaction whose read set names a functor written earlier
in its own block is therefore rejected deterministically on every node — its
signed read dependency is stale by construction and would be rejected against
the next published parent anyway, so no batch splitting or payload-order rule
exists and producers batch freely. Multiple blind writes may remain ordered in
one batch, and a transaction may read what it writes itself (its own writes
stage only after its validation). A singleton Prepare already has no same-block
predecessor.

Every hard-break signature binds the identity needed for its own lifetime.
An ordinary transaction binds
`{Namespace, GenesisAnchor, AuthorAdmission}`: the anchor transitively binds the
founding incarnation, while `AuthorAdmission` identifies this author's one
continuous membership generation. An unrelated committee change therefore does
not invalidate retained custody, but remove/re-admit gives that key a new domain
and makes every earlier signature unverifiable. Its sequence high-water is kept
only for current members and resets safely under the new admission id. Live
commit, restart replay, feed ingest, and catch-up all use the same bounded
history projection for committee, admission ids, sequences, and timestamp.
The later distributed control records use their own admission-scoped DTX
author-sequence high-water, separate from ordinary content. Their certified
references and QCs bind the exact committee that finalized each record, where
quorum composition is load-bearing; the outer author envelope does not freeze
an unrelated committee view before submission. An ordinary content commit
therefore cannot stale a pending Begin merely by advancing the content
author-sequence high-water. Ordinary domain writes may still make a
participant's OCC check refuse at Prepare. A local plan
is a witness inside Begin, not a second ledger submission: its distinct
signature domain binds `ProofId` and its complete plan contents, and consumes no
ordinary author sequence. A separate target attestation later binds that plan's
digest to the complete coordination manifest. The shared 64-validator cap is
already enforced at founding, live membership, local replay/catch-up, and
certificate admission. The foreign-history verifier must reuse that same bound.

Compiled predicates that read live node-local P state cannot silently influence
a durable distributed write because they have no consensus-replayable MVCC
version. The shared worker records their use. In this slice, sealing a proof
with any material diff fails with
`non_transactional_dependency(Predicate)` unless that predicate supplies an
explicit deterministic dependency token and Prepare validator. Existing typed
lifecycle E operations remain outside the D transaction and keep their
dedicated post-commit path. Pure read proofs may continue using query bridges.

One scope may be reached through several paths, so it cannot carry one
`CallChain` or one goal/result pair. Its bounded canonical authorization
transcript contains, in execution order, every invocation's id, semantic call
chain, authenticated principal/subject representation, original requested goal
bytes, and explicit `allowed | denied` verdict. Each accepted answer contributes
its sequence and solution digest, while logical exhaustion contributes only a
fixed completion tag. Invocation-level failure-reason payloads remain volatile
and never enter a plan. Only the canonical final group-abort stack is persisted,
once, in `Decision(abort)`; it is not part of an invocation transcript. The final
overlay revision accompanies the ordered event transcript. The
signed plan and Begin carry these bounded bytes, not only a digest, so every
participant validator can deterministically re-prove `can_invoke/4`. The target
signature binds the transcript bytes and digest, `ProofId`, origin identity,
base, read check, and diff. For a distributed proof, a distinct target
attestation binds `{TargetIdentity, PlanDigest, ManifestDigest}` without
changing or duplicating the signed-plan format. Session expiry remains volatile
and is not part of a consensus validity decision. No fictional agent subject is
encoded while the engine context still has no authenticated agent; the current
target-validator/node principal is explicit.

As built in this Step-4 slice (`quod_dtx`), with the same binding properties:

- Each accepted answer folds `(Seq, H(answer))` into one **chained
  per-invocation digest**, so a transcript entry is O(1) per answer while
  still binding every answer's exact content and order; the entry carries
  `{InvocationId, Chain, RequestedGoalBytes, Verdict, AnswerCount,
  ChainedDigest, Tag}` with `Verdict ∈ allowed | denied` and
  `Tag ∈ active | complete | error | cancelled`; only the first terminal tag
  sticks. Per-answer transcript growth would have bounded answer streaming
  inside writing proofs at a few hundred answers.
- A refused invocation records the original requested goal with verdict
  `denied`, while execution substitutes
  `fail_with_reason(not_allowed(TargetNs))`. The requested goal therefore never
  executes, but every participant can re-prove the exact decision whose result
  changed the caller's control flow against the absorbed policy read set.
- The plan envelope is `{quod_plan, Core, Signer, Signature}` under the current
  witness domain `quod.dtx.plan` V6; `Core`'s
  diff/read-check/transcript values are
  nested deterministic ETF binaries, so the origin verifies the signature and
  outer shape without ever allocating another ontology's atoms.
- `peer_ready/1` is exempt from the live-bridge gate only when the exact diff
  is the singleton `peer_admitted/4` membership change that every validator
  re-proves. A content write that consulted `peer_ready/1` remains tainted,
  like every other query-class bridge.
- A successful writing proof seals before submission, while all scopes are
  still open. `quod_proof_context:finalize(commit)` reuses that sealed set and
  closes the scopes; failed or errored proofs use `finalize(abort)`, which
  closes without sealing. For a successful proof in which at least one scope
  staged a write, every scope
  with a diff **or** a non-empty read set then seals (`plan_not_material`
  otherwise). A plan sealed over the wire must verify under the authenticated
  target key. Only isolated unkeyed test engines may seal an unsigned
  zero-anchor plan; a keyed engine without its live genesis anchor refuses the
  proof as rebuilding.

All scopes whose reads influenced a writing proof participate, including a
scope with an empty local diff. Otherwise a premise in B could change while A
and C commit. If every diff is empty, the proof returns directly from its pinned
views and creates no ledger entry or ordinary OCC pass, matching today's local
frozen-read semantics. It still resolves the accumulated DTX visibility
fence: every normal selected scope must remain certified-current at return; a
pending proof fence or stale DTX generation returns
`transaction_pending(GroupId)` instead of a mixed result. Explicit `prove_ro`
keeps its separately documented stale-snapshot behavior.

An all-read proof may still pin different ordinary committed heights in A and
B; it is not advertised as one global historical instant. The certified-current
fence only prevents crossing an unresolved distributed commit. This preserves
the project's existing read-skew contract instead of adding a global read
consensus protocol to the write milestone.

When exactly one ontology has a diff or influencing read dependency, its target
validator submits the sealed plan through the existing one-ontology transaction
path—even when it is foreign to the proof origin. The hard-break ordinary
transaction envelope is generalized to bind the target ontology/anchor,
`ProofId`, origin identity, bounded top-level goal/result, plan/transcript
digest, and the target's normal author sequence/signature. The target still authors its own
ledger entry, and `outcome(OutcomeRef)` can recover the exact result. Two or more
material/read-dependent ontologies use the protocol below. There is no separate
Prolog API or behavioral mode.

This reuses the one-ledger mechanics, not today's private function unchanged.
Extract one target-owned `quod_prolog:submit_plan/4` primitive from
`submit_write/8`. It validates the sealed local plan, builds the unsigned
ordinary envelope, submits it from the target engine, and owns the parked/result
state until apply. Both an ordinary local proof and a sole-foreign material
scope call that primitive. Delete the old caller-engine `submit_write/8` shape
and its `CallerNs =:= Ns` guard so no second foreign submission path or proxy-
authored transaction survives.

As built:

- The ordinary transaction signature binds
  `{Ns, GenesisAnchor, AuthorAdmission}`. The anchor is the
  slot-1 block hash and cryptographically covers the per-founding random
  `consensus_incarnation` fact committed inside that block, so the incarnation
  is bound transitively — two foundings can never share an anchor. That is
  the load-bearing closure: exact height tokens can validate by coincidence
  across a wipe/re-found, and the anchor makes every old signature
  unverifiable. `AuthorAdmission` changes only when this author is removed and
  later admitted again. It closes re-admission replay without invalidating
  retained custody when somebody else's membership changes. The complete
  committee id is deliberately absent from author envelopes. For DTX controls,
  the committed record's certified reference binds the exact committee that
  voted at that ledger position.
- The envelope carries `origin` (the proof-origin identity, replacing
  `caller_ns`), `proof_id`, and `plan_digest` — the SHA-256 of the sealed
  plan's canonical unsigned bytes — as record fields; `none` only on the
  unsigned genesis, and committed non-genesis history requires their
  presence. Durable goal and result are bounded canonical atom-safe blobs; the
  decoded result is a strict, sorted `[{VarNameBinary, Term}]` list, so duplicate
  variable names and topology-dependent atom allocation are impossible.
- The public API is `prove(Ns, Goal)`; the caller-namespace argument is
  gone. `submit_plan/4` (plan, bounded goal, bindings) is the one
  submission primitive; the engine accepts only a plan its OWN node
  witnessed for its OWN `{Ns, Anchor}` at a base at-or-below its applied
  head. A read-only proof with no writes returns directly and seals no plan.
  An admitted signed execute/Accept seals its origin plan even when the
  requested mutation is already present, so the existing transaction/DTX
  record can carry its durable operation claim with an empty diff. For a
  writing proof, single-participant routing counts every plan whose signed
  diff is non-empty, whose signed read set is non-empty, which carries one
  direct effect, or which carries that origin operation claim. A direct effect
  and a diff may not coexist in the same plan; separate participant plans may
  contain either. It submits the
  sole participant's plan engine-direct
  (local/co-hosted) or over the scope's
  `submit_plan` frame (remote — outcome only crosses back:
  `{committed, Slot, TxId} | {rejected, Reason} |
  {outcome_unknown, OutcomeRef}` from a closed vocabulary),
  and returns `{ok, [Bindings], {transaction, Ns, Anchor, TxId}}` for a
  foreign commit. Two or more participants build one canonical manifest and
  target-signed attestation set, then enter the durable group protocol; the
  caller remains parked until Complete publishes the terminal result or gets
  an `outcome_unknown(GroupRef)` recovery handle. Read-only
  participants are never discarded or committed unprotected. Isolated unit
  engines (no consensus identity) use the zero-anchor sentinel and never share
  plans across nodes. After sealing and before a potentially blocking submit,
  the origin worker leaves the derivation pool: consensus waiters are bounded
  separately and no longer pin the MVCC snapshot floor or consume a proof
  slot.

For a distributed proof, the origin first creates a fresh 32-byte coordination
nonce. It then builds
the canonical target-identity-ordered manifest rows, each carrying its unsigned
local-plan body digest,
the exact origin identity and continuous coordinator admission
`{OriginNs, OriginAnchor, OriginAuthor, OriginAuthorAdmission}`, the coordination
nonce, bounded canonical top-level goal/result bytes and digests, explicit
principal/subject form and `ProofId`.
Every target verifies its unchanged signed plan and returns the separate
manifest attestation over
`{TargetIdentity, PlanDigest, ManifestDigest}`. Only after every attestation is
fixed does Simplex allocate the coordinator's next DTX sequence, sign the outer
Begin envelope, persist its exact bytes, and submit it. `GroupId`, like the
existing semantic `TxId`, excludes that outer author/sequence/signature
envelope, so any later valid envelope for the same semantic body keeps one
group identity. This
ordering means an origin that is also a participant does not make its own plan
stale by signing Begin. Persisting the result bytes lets
`outcome(OutcomeRef)` recover the exact selected bindings after caller death;
re-proving remains forbidden.

## 7. Atomic multi-ontology commit

Independent appends are forbidden: one ontology could apply while another
detects an OCC conflict. Use the existing per-ontology Simplex logs in one
origin-coordinated BFT commit protocol. The origin is only the durable
coordinator; it has no privileged Prolog semantics.

As in current one-ontology writes, committees do not re-execute an arbitrary
Prolog derivation: they deterministically verify the target author, transcript
authorization, exact OCC tokens, shape, limits, and phase rules. The protocol
therefore provides Byzantine-safe ordering/atomicity under the documented
trusted-validator execution boundary; it does not falsely claim Byzantine-
correct semantic execution by a malicious target validator.

All control records are explicit tagged record types, not magic goals or
optional fields grafted onto ordinary content transactions:

```text
Begin
Prepare
Decision(commit | abort)
Finalize(commit | abort)
Complete
```

Each ontology has one ledger-active group slot keyed by `GroupId`, with
independent origin and participant role bits. One shared role transition rule
governs every phase: Begin requires an empty slot and installs the origin role;
Prepare either installs the participant role in an empty slot or adds it to an
existing origin role for the **same** group; Decision and Complete require that
same group's origin role; and a prepared Finalize requires and releases that
same group's participant role. A different group can never overwrite or join
the slot. Its local ingress parks and a proposal against that parent is invalid.
A certified direct no-Prepare Finalize(abort) is the sole non-role transition:
it writes only the exact terminal tombstone described in §7.4 and neither reads
nor occupies the active slot. This rule permits an ontology to coordinate and
participate in one group without permitting two active groups.

This is a deliberate ledger and signature-format break. There is no old-format
decoder or migration path.

Make the break fail-fast at storage and every changed wire/signature boundary.
The already-landed single-participant slice is ledger V3; the shared tagged
block payload specified in §12.2 therefore advances the ledger frame to V4 and
explicitly rejects V1/V2/V3 before replay. The renamed signing journal starts under its own
new magic and explicitly rejects every recognized superseded vote-journal
format. The scope-session version advances for manifest attestation, and the
new DTX control/endpoint domains start at their own first versions. Unchanged
ordinary transaction, directory, and consensus-share encodings are not bumped
gratuitously: the new genesis anchor and changed block hash already make old
QCs inapplicable. Every superseded magic and version stays named at its decoder
so an old artefact is rejected as an identifiable format at its exact offset,
never mistaken for corruption or a trimmable tail.
The release requires a fresh genesis and the documented `/quod/data` wipe. No
dual decoder, migration scanner, or compatibility flag remains.

One committed slot's `data` is an explicit tagged union enumerated in exactly
one place, `quod_ledger:classify/1`. Consumers that react per variant —
committee projection, content and DTX author-sequence high-waters, endpoint
learning, the apply fold — dispatch on its result and enumerate every kind without a catch-all, so
the control records below are introduced there once and fail loudly at any site
that has not yet decided what they mean. A kind the running release does not
recognize classifies as `invalid`, which untrusted catch-up and replay input
tolerates; it is never silently folded as content or as the inert skip.

### 7.1 Begin

The origin ontology commits one singleton barrier containing the exact manifest
and all target-signed local plan envelopes needed for recovery. This prevents a
coordinator from changing participants or plans after any participant prepares.
`GroupId` is the domain-separated SHA-256 hash of the canonical semantic Begin
body; author, DTX sequence, submission timestamp, and outer signature are not
part of that identity, matching the existing semantic-`TxId` pattern. The body
includes `ProofId`, origin identity, coordinator admission, coordination nonce,
complete manifest, every manifest-bound target attestation, and bounded
goal/result. A target plan cannot move to a different manifest or coordination
identity: changing the coordinator admission or nonce changes the digest every
target must sign. Replaying the exact envelope or safely re-enveloping the same
body yields the same `GroupId` and is idempotent. The admission-scoped DTX
author-sequence high-water still rejects envelope replay/equivocation without
an unbounded used-plan-id index. For Begin, the outer author and admission must
equal the coordinator generation inside the semantic body; only later phases
may be redriven by another current validator.
Once Begin commits, recovery is governed by durable group state and the
certified origin Decision, never a volatile session clock.

### 7.2 Prepare

Participants prepare in canonical ontology order. Each participant committee:

1. independently verifies the committed Begin witness from the origin's pinned
   genesis;
2. checks that its complete local plan matches the manifest;
3. validates the target plan signature and manifest attestation, target author
   membership, every transcript `can_invoke/4` decision, structure, limits,
   membership rules, and local OCC read set against the exact parent state;
4. applies the shared role rule above against the parent, verifies that the one
   proof fence is open, then holds only the transient proposal barrier needed to
   prevent a pipelined ordinary child before this Prepare is decided; a
   validator-local pending Begin hand-off is independent and does not fail this
   check;
5. commits a singleton Prepare containing the complete local plan and Begin
   reference;
6. atomically projects the durable namespace lock and proof-generation fence
   in Simplex from that committed Prepare, and keeps the diff hidden and
   unapplied.

A transient control barrier first seals the current ordinary batch and forbids
a pipelined child over an uncommitted Prepare; it is not durable lock state. At
Prepare commit, Simplex's own history reducer makes the namespace lock and its
protected-ETS proof fence
effective before it handles another ingress item or proposal; it does not
synchronously call or drain `quod_prolog`. The committed apply cast reaches
Prolog in ledger order. A DTX verdict that needs the Prolog parent parks exactly
like today's membership verdict until that parent is applied.
Until Finalize commits, the consensus-admission lock refuses/parks **all**
ordinary content and membership payloads. DTX admission is phase-aware rather
than a blanket bypass: a same-group Decision may proceed while an origin is
also a locked participant, and only that prepared participant's matching
Finalize releases the lock; Complete becomes eligible only after Finalize has
reopened admission. The same gate is enforced in append collection,
retained custody/relay re-drive, proposal validation, committed replay, and
catch-up, so no ingress route or Byzantine proposal can bypass it.
The sole additional admissible control is a certified direct no-Prepare
Finalize(abort) for another group: as specified in §7.4 it is an immediately
applied metadata tombstone and touches no D state, hidden plan, active role,
proof fence, or generation.

At Finalize commit, durable history reopens consensus admission, but the
shared proof fence remains `transaction_pending(GroupId)` until Prolog has
applied/published that Finalize and sends an asynchronous applied
acknowledgment. Simplex handles that acknowledgment as an ordinary event; it
never waits for the Prolog mailbox. Later committed-entry casts remain FIFO, so
consensus can progress without exposing the pre-Finalize Prolog snapshot to a
new proof.

Every scope open, overlay read/mutation, and final return checks the current
proof-fence state and generation even when its snapshot predates Prepare. Prepare
invalidates every older scope for that ontology. A locked or stale access
returns the typed definite `transaction_pending(GroupId)` immediately and
poisons that pre-Begin proof; there is no hidden mailbox wait or ambiguous
timeout. A caller may explicitly start a new proof later. This first slice
deliberately gives up disjoint-functor concurrency for a small, auditable atomic
contract; per-functor locks are not implemented or left as a half-path.
They are only a possible measured future concurrency optimization, not deferred
correctness or functionality.

There is no participant-local timeout abort. Only the origin's certified
decision can resolve a prepared participant.

### 7.3 Decision

The origin commits exactly one Decision. The first Decision in origin ledger
order is final:

- `commit` only when the record carries a valid committed Prepare reference for
  every manifest participant, and carries no failure reason;
- `abort` is always safe while no Decision exists and carries the non-empty
  bounded terminal group-abort reason stack selected by the origin committee.
  A deterministic Prepare refusal supplies that request and stack; overload,
  transport loss, caller departure, and timeout never masquerade as a refusal
  or claimed outcome. Intermediate Prolog failures that were recovered do not
  enter the record. No wall-clock or ledger-time deadline competes with a valid
  commit; the first origin-consensus Decision wins.

The abort stack uses the existing atom-safe Prolog wire alphabet and the Erlog
limits (4 KiB per reason, 32 KiB total, 256 retained entries). A separate
256-bound caps diagnostic choice points; it is not the reason-entry counter.
Quod installs the canonical wire validator as Erlog's failure-stack admission
policy, so explicit reasons, automatic predicate frames, and stacks merged
from another ontology are bounded when they enter proof state rather than
failing later at the scope wire or Decision boundary. Its canonical bytes are
part of the Decision digest and therefore of every certified Decision
reference. A reasonless abort, a reason-bearing commit, or a non-canonical
stack is invalid.

Every origin validator independently verifies the referenced foreign history
before voting. Origin ledger order and BFT quorum intersection prevent commit
and abort decisions for the same group from both becoming valid.

### 7.4 Finalize

Each manifest participant independently verifies the origin Decision witness
and commits one matching singleton Finalize:

- commit requires the matching Prepare and durably records the prepared outcome
  plus the certified origin Decision witness needed to reproduce it from this
  participant's own ledger;
- abort accepts either a matching Prepare or no local Prepare. The former
  records that the hidden plan must be discarded; the latter records a no-op
  terminal tombstone. Both require the certified matching Decision(abort), and
  the tombstone makes every later Prepare for that group a phase reversal.
  Thus a participant whose refusal caused the abort can still finalize without
  inventing a separate `not_prepared` status. A racing Prepare is resolved only
  by that participant's ledger order: Prepare first is later discarded;
  Finalize(abort) first installs the tombstone and the later Prepare is invalid.

A prepared participant's Finalize ends its consensus-admission lock at commit;
its hidden plan is applied or discarded later in Prolog's ordered mailbox turn
while the proof fence remains closed. A direct no-Prepare Finalize(abort) has no
hidden plan or D-state work: its certified commit is itself the deterministic
`applied_abort` no-op status, binds the unchanged parent `AppliedGeneration`,
leaves the proof fence unchanged, and creates no active participant role. It is
therefore admissible through an unrelated group's active lock or closed fence.
This metadata-only rule prevents
crossed aborts from deadlocking without allowing any content or prepared plan to
bypass the lock. Simplex still sends its normal ordered outcome-projection cast
to Prolog, but neither waits for it nor makes the no-op status depend on it.

OCC is not repeated at Finalize: Prepare validated it and the namespace lock
prevented intervening changes. The committed Finalize deterministically fixes
the namespace DTX generation in ledger history (advancing it for commit and
retaining it for abort) before any later consensus transition is validated.
One `quod_prolog` mailbox turn then applies or discards the hidden diff,
publishes the MVCC snapshot at that already-fixed generation, marks
`finalize_applied_slot`, and sends Simplex an acknowledgment bound to the exact
`{GroupId, FinalizeSlot, Generation}`. The acknowledgment only opens the proof
fence; it never changes consensus-derived generation. A duplicate or stale
acknowledgment is inert. Finalize(abort) uses the same exact acknowledgment
after discarding a prepared hidden plan and publishing its local
`applied_abort` status without changing D. For that
prepared path, a Finalize QC proves only `finalize_committed_slot`; for the
direct no-op path, the QC also proves `applied_abort`. A terminal group still
requires an exact applied status from every manifest participant and a
committed origin Complete. No off-ledger all-Finalize certificate set controls
local visibility:
for commit the certified Decision proves that every Prepare exists, while for
abort the local Finalize itself fixes prepared-discard versus no-op. Prepare
when present, Decision, and this local Finalize are sufficient for deterministic
participant replay without foreign network access.

Participants may finish that final mailbox turn at different instants. A
finished participant can serve new state. A prepared participant with no
committed Finalize is still consensus-locked; one with a committed but unapplied
Finalize admits later consensus records but remains proof-fenced and returns
`transaction_pending`. Any old scope also fails its generation fence.
Consequently one normal distributed proof sees all old, all new, or a typed
retry, never a new/old mixture. Explicit observer-backed `prove_ro` retains
Quod's documented stale-read semantics and is not presented as a
certified-current distributed snapshot.

Initial decision/finalize messages may follow the A -> B -> C call tree, as the
proof did. Correctness and recovery use the flat certified manifest, so an
unavailable intermediate cannot strand its children permanently.

### 7.5 Complete

After every manifest participant's matching Finalize is committed and its exact
apply/discard acknowledgment or certified direct-no-op status is available, a
current origin validator submits one singleton Complete to the origin ledger. Its canonical
body contains `GroupId`, the certified Decision reference, and the
target-identity-ordered list of each participant's Finalize reference and
`AppliedGeneration` (the proof-fence generation after that Finalize, not an
author sequence). The reference already fixes the slot. Complete
contains no responder-dependent route or signature
choice.

Before voting, every origin validator independently verifies those Finalize
certificates. A direct-no-op certificate supplies its applied status directly.
For a prepared participant, the validator derives
`f = floor((N - 1) / 3)` from one certified current target committee view of
size `N`, then requires identical canonical status replies over identity-pinned
DTX links from exactly `f + 1` distinct current target NodeKeys. The shared
64-validator cap is enforced at every current committee/history/certificate
entrance; under that cap `f + 1 <= 22`. Duplicate keys and view
mismatches are rejected before a body is retained. That set contains at least
one honest target validator, so an all-Byzantine false application claim is
insufficient. A committee-view change restarts the check. The fixed reply body is correlated to
`{TargetIdentity, TargetCommitteeId, GroupId, FinalizeRef,
AppliedGeneration, AppliedVerdict}`; mTLS link identity authenticates the
responder, and no new portable signature format is introduced. These bounded
asynchronous checks use the same
nonblocking foreign-validation worker boundary as Prepare and Decision. The
origin Complete QC is then transferable evidence that an origin quorum
performed every live check. Replay and catch-up validate the canonical Complete
body and its local origin QC; they do not re-run foreign certificate or status
checks. Applied generation is derived deterministically from the target's
committed ordered history, never from acknowledgment timing, so honest replicas
return the same value. A participant that
already applied its prepared Finalize re-serves the same canonical status
after restart.

Complete is the only `decided_* -> completed_*` consensus transition. Its commit
clears the origin's ledger-active role, so a later Begin is valid identically
live and on replay. Decision or Finalize alone never releases that origin role.
The ordered Complete apply cast then makes the owning origin engine persist and
flush the compact terminal outcome at `CompleteSlot`; only after that flush does
it release a local caller waiter or serve a terminal outcome. An earlier
certificate is parked by slot, and an engine deadline or crash remains
`outcome_unknown`. Replay rebuilds and flushes that row before the ontology
becomes ready. The Decision reference determines commit versus abort and the
exact abort reason stack. Complete carries neither a duplicate verdict nor
duplicate reasons. Exact duplicate Complete records are
idempotent; a changed reference set or applied generation is rejected. Any
current origin validator may reconstruct and redrive the same semantic Complete
after restart.

The caller returns either terminal group result only after Complete commits and
the origin engine flushes that ordered terminal projection, returning bindings
plus per-ontology slots on commit. From Decision commit until that local flush,
the result is `outcome_unknown`, never a terminal result. Consensus may admit a
later origin group as soon as Complete commits; public outcome visibility does
not control that ledger transition.

## 8. Foreign finality verification

Directory routes remain routing hints. They never prove that another ontology
prepared, finalized, or applied a group phase.

Break the directory record cleanly so every hosted namespace carries its
32-byte genesis anchor. System authorization is exact over
`{Namespace, GenesisAnchor, NodeKey}`. A provisional private direct seed keeps
the existing explicit `{Namespace, Endpoint}` TOFU boundary; its first
authenticated non-executing identity exchange confirms and pins both `NodeKey` and
`GenesisAnchor`, after which neither may change in place. Two eligible system
routes claiming different anchors for one namespace cause `anchor_conflict`;
neither is selected. A confirmed direct seed keeps its documented local
override precedence. The namespace->anchor pin/conflict high-water survives
route expiry and service restart; switching a namespace to another genesis
requires an explicit operator reset and cannot happen because stale routes aged
out.

Replace the namespace-only public projection with
`directory_host(Namespace, GenesisAnchor, NodeKey, Host, Port)`; remove the old
`/4` form. During step 3, the advertised validator/observer role is only a route
hint: the target authoritatively rechecks that its own key is a current, ready
validator before admitting a potentially writable scope, and the origin tries
the next pinned route on an observer rejection. Step 4's foreign-ledger
verifier then lets the resolver independently verify the anchored ontology's
current committee projection and accept only a route whose `NodeKey` is a
current validator at the pinned base/committee id. A directory entry remains
only an endpoint hint in both steps. Observer routes may serve explicit
`prove_ro`, but are skipped for a potentially writable proof; exhaustion
returns `ontology_unreachable`. A membership change invalidates the session or
causes Prepare to abort under the namespace membership lock.

One node-wide, read-only foreign-ledger verifier/cache reuses the existing
catch-up page format, server bounds, and certificate-validation core, but not
`quod_catchup:pull/4`: that client assumes a local per-namespace process and its
pending map is not the required foreign-history owner. Dormant verified histories
remain on disk and are reopened only when needed. For a foreign witness
it:

1. starts from the exact pinned genesis;
2. pulls bounded pages through the existing catch-up service;
3. reuses `quod_catchup`/`quod_simplex` certificate verification;
4. threads the same committee, committee-id, admission-scoped content and DTX
   sequence high-waters, timestamp, and distributed-group phase
   projection checked by local boot;
5. accepts only the referenced exact slot, block hash, and record digest.

Foreign verification runs asynchronously before a validator votes, like the
existing membership-verdict path; no network call occurs inside a pure verdict.
Unavailable history causes abstain/retry, never acceptance. A verified
`{Namespace, GenesisAnchor}` projection is cached and persisted atomically; a
missing or corrupt cache restarts from anchored slot 1. Cache eviction affects
performance only, not correctness.

The verifier owns one globally/per-peer bounded pending map; it rejects before
spawning or allocating when the table limits are reached. Keep catch-up's
progress-preserving first-entry rule. Before the distributed payload lands, a
shared bound test must prove that the largest valid entry fits below the 900 KiB
response budget. With the shared 64-validator cap, two `?MAX_BLOCK_BYTES =
256 KiB` bounded payloads plus two 64-signer certificates at a conservative
96 bytes per signer use `2 * 262,144 + 2 * 64 * 96 = 536,576` bytes before
fixed framing, leaving 385,024 bytes below the 921,600-byte budget. The test
encodes the real worst-case entry and asserts the complete frame stays below
the budget; this arithmetic is a visible design check, not a substitute for it.
The 64-validator cap and the separately bounded content/DTX author-sequence
projections keep certificates/history folds inside the declared bounds. If that
inequality ever stops holding, the payload bounds must be reduced or a complete
chunking protocol designed; a valid first entry must not be rejected into a
permanent catch-up stall.

After a local committee commits a control record, local replay and catch-up
verify that local record and its local finality certificate exactly as they do
ordinary committed history. They do not need the foreign network during boot:
the local quorum certificate attests that the live validators completed the
foreign check before voting.

## 9. Durable state and recovery

`quod_outcome` is the per-namespace disk-backed outcome index, owned as library
state by the existing namespace `quod_prolog` process rather than a new service.
The current ordinary slice stores pending submissions and terminal outcomes on
disk as compact `{ref, tx_id, plan_digest, status}` rows, keeps only a true
4,096-entry compact terminal LRU in memory, and is populated by the same
live/replay apply path. It does not duplicate goal, result, diff or read-set
bytes. The ledger remains authoritative: exact replay duplicates are idempotent
and contradictory content is rejected instead of being overwritten. The
canonical transaction id hashes the target identity and complete semantic write,
so an exact redrive keeps one outcome while any changed content necessarily
receives a different id. The explorer's old bounded 5,000-slot backward scan is
deleted; its detail path reads the compact outcome height without entering the
ontology engine, then reads exactly that one ledger block for transaction detail.

The multi-participant implementation extends this same index with one journal-derived
validator-local pending-Begin reference and one independent ledger-rooted
active-group slot. The latter records the Prolog-side projection of phase,
manifest digest, local plan, locks, record slots, certified group records, and
bounded authenticated applied statuses; Simplex and its protected ETS row own
the live gates. Both fields may coexist, and the pending body/envelope remains
only in the signing journal. No second live, durable, or authoritative outcome
service/index is added.

The 4,096-row memory LRU is only an optimization. The disk-backed exact group
row remains the authority for every old-phase/phase-reversal check. On the live
path, Simplex first rejects malformed or uncertified input cheaply, then sends a
bounded, coalesced
`{lookup_group_phase, AnchoredGroupKey, ParentHistoryToken}` request to the
owning Prolog engine without waiting in the consensus state machine. The token
contains at least the parent slot and committed/approved parent hash.
Because Simplex is also the sender of committed apply casts, Erlang mailbox FIFO
orders the lookup after every outcome update through the token's parent slot.
The reply is bound to its request reference, candidate block hash, and exact
engine pid, and carries the engine's applied/index floor. Outcome reset/reopen
is initialization-only; any later index failure stops the owner, so the pid is
also the index generation and no second counter is added. The reply is accepted
only while those identities and the exact parent/history token remain current
**and** the floor is at least the parent slot; otherwise validation parks or
restarts. A forward-gap apply that did not advance the index therefore cannot
turn an unknown old group into `not_found`.

There is no general pending-lookup map. One request attaches to the existing
validation latch for each of the two live pipeline slots, derived from
`quod_simplex`'s current `?PIPELINE_DEPTH = 1` through `live_pipeline_slot/2`;
exact redrives
coalesce. Verdict, slot/parent retirement, Prolog `DOWN`, and timeout remove the
latch entry. Engine down/rebuilding, an index error, a below-parent floor, or
request pressure parks/abstains and never means `not_found`.

Startup replay and catch-up cannot depend on the later Prolog owner. Boot replay
populates one ephemeral DETS phase set during its already-required slot-1 fold,
before the statem serves. A later catch-up session creates and backfills that set
from slot 1 **lazily**, only when its first DTX record needs exact old-group
history; a content-only repair never rescans the ledger. Once created, the set
extends across every later page rather than rebuilding per window. Each set has
a session-unique table name/path and uses the same canonical row validator. The
existing monitored catch-up worker owns the scan and DETS work, so the live
Simplex event loop never performs it. It uses `{auto_save, infinity}`, consults
the set before each DTX transition, then closes and removes it in `after`.
Namespace startup removes only abandoned files under the exact DTX-phase scratch
prefix. The set has bounded memory, performs no datasync, is never reused or
repaired after a crash, and contains no authority beyond the ledger being
validated. It is scratch space, not a second live, durable, or authoritative
index or service. This makes an ancient
re-enveloped Prepare after a no-op abort tombstone fail identically live, after
cache eviction, on restart, and during catch-up.

One public `outcome(OutcomeRef)` API covers both forms. The reference is either
`{transaction, Namespace, GenesisAnchor, TxId}` or
`{group, OriginNamespace, OriginAnchor, Coordinator,
CoordinatorAdmission, GroupId}`. It pins both the authoritative origin ledger
and, for the pre-Begin interval, the exact coordinator node whose local signing
journal can answer. It never assumes ids are globally unique or local.

Remote lookup first freezes one certificate-verified current origin view and
asks its distinct current validator keys through identity-pinned routes. Every
request binds that view's `CommitteeId` and minimum certified slot; a responder
answers only when its current CommitteeId matches, it is still a current
validator, and its Prolog publication floor exactly equals its Simplex slot at
or above that minimum. A public status requires `f + 1` identical replies, so a
Byzantine first responder cannot decide it. View rotation, a lagging outcome
projection, malformed disagreement, or insufficient replies yield
`outcome_unknown(OutcomeRef)`.

For groups only, `f + 1` identical `not_found` snapshots start a second exact
coordinator barrier. If the certified current view excludes `Coordinator`, the
bound admission is already retired. Otherwise the resolver dials that exact
key and sends the full admission-bound GroupRef under the same CommitteeId and
minimum slot. That barrier alone may return `pending_begin`,
`coordinator_retired`, or definitive pre-handoff `not_found`; another validator
cannot answer it. An ordinary transaction's quorum `not_found` remains
`outcome_unknown` because it has no equivalent durable exclusion barrier.

A ready exact coordinator returns `pending(pending_begin)` when serialized
Simplex state has the hand-off queued, running, or recovered from the journal.
It returns `{error, not_found}` only when the barrier proves no earlier engine
handoff remains and both journal and certified origin history lack the group;
because no signed envelope is exposed before journal sync, that absence proves
the crash preceded durable hand-off and retry is safe.
Once Begin or retirement commits, the origin ledger is authoritative for that
ordering and the local pending row is irrelevant. A group otherwise resolves to
`pending(Phase) | {committed, Bindings, ParticipantSlots} |
{aborted, Reasons} | {rejected, Reason}`; an ordinary transaction resolves
through the same index and existing exact-submission pending state. A committed
Decision is still `pending(finalizing_commit | finalizing_abort)`: neither it
nor a set of Finalize QCs proves that every participant has applied or discarded
its hidden plan.

Certified ledger state establishes every public group phase. `{committed, ...}`
and `{aborted, ...}` require a certified origin Complete, whose live voters
verified an exact applied status for every manifest participant. A direct
no-Prepare abort status is certified by its Finalize QC. For a prepared
participant, each origin voter obtains identical canonical replies over pinned
links from the `f + 1` distinct validators derived from one certified current
target committee view in §7.5, bound to the Finalize slot and applied
generation. An unavailable, rebuilding, view-changing, or not-yet-applied
participant keeps the result pending and the
public caller receives `outcome_unknown(OutcomeRef)`. A reset origin projection
reconstructs either the terminal Complete directly or the decided active group
whose recovery must reacquire those bounded status sets and submit it. It never
infers application from Decision or Finalize alone.

The certified Complete fixes the logical terminal phase, but the Prolog-owned
API serves it only after its ordered outcome-index floor includes that Complete
slot and the compact row is flushed. Before then, or while that projection is
rebuilding, lookup is outcome-unknown. This publication delay never keeps the
consensus active slot occupied.

Begin wins if it precedes coordinator retirement in origin ledger order;
otherwise that committed retirement alone proves
`{rejected, coordinator_retired}`. No rejection row or unbounded used-id set is
stored: after rebuild, lookup first checks the group index, then derives this
answer from the reference's coordinator admission and the current committed
admission projection. For a syntactically valid but never-issued reference,
that retirement result is a definitive **impossibility classification**—the
bound coordinator generation can no longer commit its Begin—not evidence that
such a Begin was once issued. The ordinary engine API returns the compact
classification; the explorer enriches terminal detail from the exact persisted
transaction at that height, including its bounded bindings—never a re-proof.
The group result uses the same anchored lookup model; it does not make the
ordinary index duplicate ledger payloads.

Phase transitions are monotonic and idempotent:

```text
submission:        none -> pending_begin -> begun | rejected_coordinator_retired
origin commit:     none -> begun -> decided_commit -> completed_commit
origin abort:      none -> begun -> decided_abort  -> completed_abort
participant commit: none -> prepared -> finalized_commit -> applied_commit
participant abort (prepared):   none -> prepared -> finalized_abort -> applied_abort
participant abort (unprepared): none -> applied_abort (at Finalize commit)
```

The two `completed_*` states are reached only by the matching committed origin
Complete record after its voters verify the complete manifest's applied-status
evidence. These are consensus-history states; the Prolog outcome projection may
lag until its ordered Complete apply and flush, during which public lookup stays
outcome-unknown.

Exact duplicate signed frames return the existing witness. A different digest,
phase reversal, second decision, a `GroupId` claimed for a different semantic
Begin body, Finalize(commit) without the matching Prepare, Finalize(abort)
without its certified Decision, or Complete without the exact canonical
Finalize set is rejected before state or lock mutation.

Idempotency is keyed semantically as
`{GroupId, OntologyIdentity, Phase}`, independently of the validator that
redrives it. For Prepare, Decision, Finalize, and Complete, equivalent envelopes
from different current recovery signers may compete through normal consensus;
Begin is the stated exception whose envelope author must be its semantic
coordinator.
The first valid committed envelope wins. After commit, its semantic record digest is canonical:
an equivalent outer envelope is an idempotent no-op, while a different semantic
digest is rejected. The certified block reference still identifies the exact
winning envelope. Each control record has its own explicit
author/DTX-sequence/signature fields and domain, so “any current validator may
redrive” never means reusing another validator's signature or sequence.

Recovery rules are complete:

- before the semantic Begin body and an exact outer envelope are journaled,
  caller/worker death closes volatile scopes and leaves no durable coordination
  state;
- a journaled Begin with no committed semantic Begin is retried byte-for-byte
  while its outer DTX sequence remains above the committed high-water. If a
  later same-author DTX record makes that envelope stale, Simplex allocates a
  fresh sequence, signs the **same** semantic body, and datasyncs the replacement
  before exposing it. The `GroupId`, target attestations, and result remain
  unchanged; recovery never re-proves. Origin ledger order resolves the only
  terminal race: a matching `GroupId` and semantic body first starts the group,
  whichever equivalent envelope won; coordinator-admission retirement first
  proves `{rejected, coordinator_retired}` and retires the pending hand-off.
  Every consumed but uncommitted DTX sequence is a harmless gap;
- Begin without Decision is redriven by any current origin validator: obtain
  participant status, continue canonical prepares, then decide commit or abort;
- Prepare without Finalize restores its hidden plan and locks during replay,
  fetches the origin decision, and finalizes accordingly;
- Decision redrives every missing participant Finalize and then the canonical
  origin Complete after every exact applied status is available;
- a prepared committed Finalize without its matching `applied_commit` or
  `applied_abort` has already reopened consensus admission but retains the proof
  fence, verifies its ledger-carried Decision witness, then performs the one
  mailbox apply/publish or discard transition, sends the exact applied
  acknowledgment, and can serve the canonical applied-status reply. A direct
  no-Prepare Finalize(abort) is already an applied no-op at commit and only
  reprojects its compact row asynchronously;
- all-Prepare plus no Decision can only become an origin-certified commit or
  abort according to the next ordered Decision; nobody infers an outcome from a
  timeout;
- a partition may hold prepared predicates unavailable until the origin quorum
  recovers. It cannot expose a partial result or permit a local unilateral
  abort.

The liveness claim is exactly Simplex's existing fault model: at most `f`
Byzantine/crashed members in each `3f+1` committee, eventual synchrony, durable
disks, and at least one surviving holder of every certified block needed for
recovery. That committee-wide claim starts when Begin commits. Before Begin,
the pending semantic body and latest exact envelope have only the coordinator's
journal-backed local custody. This reuses ordinary ingress routing/relay and the
persist-before-exposure principle, not content custody's TTL, retirement, or
strict ordering lifecycle: process/node restart with the same disk recovers it.
Permanent loss of that coordinator disk is outside the stated pre-Begin
liveness guarantee: an envelope already disseminated may still commit and enter
committee-wide recovery; otherwise it remains unresolved until the coordinator
recovers or its admission is durably retired. Atomic safety is preserved in
either case. A temporary or permanent loss beyond the consensus bound may leave
a prepared group safely blocked; this plan does not promise recovery that the
underlying consensus cannot provide.

The live post-Finalize mailbox application exposes the canonical reducer's
ordered `applied_ops` once. Reactions later derive only from those operations.
Begin, Prepare, Decision, Complete, a
merely committed Finalize, abort, replay, and duplicate completion evidence
generate no domain reaction.

The current live envelope is
`{applied_live, Ns, Height, {group, GroupId}, ProofId, OriginIdentity,
PrincipalOrSubject, TopGoal, TopResult, LocalPlanDigest, Diff}`. The bounded
goal/result are the same canonical values persisted by Begin, not a re-proof or
digest-only substitute. It is emitted in that ontology's committed Finalize
order after D and its MVCC publication are applied. The reaction slice carries
the already-computed `applied_ops` beside the signed requested `Diff`, without
another reducer or event envelope. `quod_runtime` then completes P before E;
empty `applied_ops` emits no domain reaction. The caller's top-level result still waits for the certified
origin Complete after all participant applied statuses. Replay reconstructs
D/P/group state but emits no E, matching the
existing runtime contract. Ordinary one-ontology transactions keep the
analogous `{transaction, TxId}` identity under the hard-break event union.

## 10. Code boundaries

Keep the change factored rather than adding phase exceptions throughout
`quod_simplex`:

- `quod_erlog_db_local_prove`: exact overlay checkpoint/replace,
  savepoint/restore, read-only-frame, and OCC-token APIs only; it remains a
  database adapter and does not learn distributed lock policy;
- `quod_diff`: expose the tiny pure assertion-only/asserted-functor checks reused
  by runtime creation and V4 genesis validation, plus the post-diff interpreted-
  functor presence check used by ordinary apply and distributed Prepare; no
  policy module or duplicate term scanner;
- `quod_proof_scope`: the one shared origin/selected proof worker, invocation
  continuations, consensus-lock/proof-fence/generation checks against Simplex's
  protected projection, overlay generations, sealing, limits, and cleanup;
- `quod_scope_wire`: the sole bounded request/response scope-frame codec and
  direction-aware safe decode boundary;
- `quod_ask`: only the compiled `::` predicate, caller-side choice-point
  streaming, variable grafting/failure merge, and calls into the scope
  wire/router boundary; its separate answer proof loop, old ask decoders, and
  `watch_owner`/`stop_owner` cleanup path are removed;
- `quod_ask_router`: become the sole bounded scope-frame correlation/proxy and
  cleanup registry, with a monotonic `ProofId` touched-scope ownership set;
- `quod_prolog`: admit the shared workers, retain bounded scope sessions and
  MVCC pins, own the per-namespace `quod_outcome` state, expose the one
  target-owned `submit_plan/4` plus the public anchored `outcome/1`, and hand
  sealed plans to commit coordination; its public `prove/2` receive loop and
  engine forward exactly one correlated recovery checkpoint so a namespace-
  subtree restart cannot erase the caller's handle: an ordinary `OutcomeRef`
  strictly before its asynchronous Simplex submission, or a `GroupRef` after
  the group register acknowledgment and before activation;
- `quod_ontology`: require the compiled policy only on a genuinely fresh create
  and map omission to the bounded lifecycle failure; its prepared descriptor
  passes the already-compiled `InitialDiff` to namespace start, rejects its
  deterministic encoding above the shared 192 KiB limit before manager/storage
  mutation, while resume keeps its existing ignored-options contract;
- `quod_transaction`: keep canonical ordinary transaction encoding/signing
  input only;
- `quod_dtx`: own the distinct Begin/Prepare/Decision/Finalize/Complete domains and
  encodings, manifest hashing, pure phase validation, lock projection,
  coordinator/participant recovery commands, and finalize application; it uses
  the one live `quod_outcome` state and creates no second durable or
  authoritative group-status index;
- `quod_outcome`: implement the unified ordinary/group disk index, ledger
  rebuild fold, bounded local-pending/active/terminal views, and exact outcome
  and group-phase lookup, plus the ephemeral replay/catch-up phase-set backend;
  it has no process separate from the owning namespace engine and its memory LRU
  never decides phase validity;
- `quod_signing_journal`: the hard-break replacement for `quod_vote_journal`,
  and the one local signing authority for consensus votes, DTX sequence floors,
  and each pending semantic Begin body plus its latest signed envelope;
  expose separate empty-ledger initialization, recovery with no ledger-derived
  mutation, and post-fold reconciliation APIs; compaction preserves every unresolved item and
  no wrapper or old module remains;
- `quod_ledger_store`: use V4 frame magic, reject V1/V2/V3 explicitly, and provide
  the ordered replay stream from which `quod_outcome` rebuilds;
- `quod_ledger`: own `classify/1`, the single enumeration of committed
  entry-data kinds that every per-variant consumer dispatches on;
- `quod_foreign_log`: lazy anchored foreign-history verification and cache;
- `quod_simplex`: accept the explicit record union, singleton control barriers,
  asynchronous validation hooks, the one FIFO register/activate admission owner
  with exactly one accepted dormant Begin intent
  and local status barrier, mutually exclusive bounded `genesis_diff` input for
  prepared runtime creation, linear generated/source diff assembly, and the V4
  assertion-only/policy-present genesis invariant, with no other protocol policy
  beyond validation results;
- `quod_directory`: exact anchor-carrying routes and conflict rejection;
- explorer/feed/runtime: group records and Finalize-only domain-apply events.

Reuse the scope router, QUIC identity pinning, safe term codec, scope
backpressure, worker monitors, overlays, OCC validation plumbing, exact-slot ingress,
retained relay submission, Simplex certificates, catch-up paging, and
`outcome_unknown` contract.

Delete, rather than retain:

- `foreign_write_unsupported` and its error allowlists;
- the `CallerNs =:= TargetNs` write gate and caller-supplied `CallerNs` API field;
- served-ask `read_set => false`;
- target-side `start_answer*`, `answer_init`, `answer_loop`, `step`, and `drive`;
- `quod_proof_scope:run_first/3` once its engine-owned and raw-snapshot callers
  both use `quod_proof_session:run_first/3`;
- old `quod_ask_open`/`quod_ask_next`/`quod_ask_cancel` frames and decoders,
  `watch_owner`/`stop_owner`, superseded ask step timers/messages, and the old
  `#ask_worker`/id/caller maps after their state moves into the shared scope and
  sole router;
- tests/comments claiming every foreign call is read-only; retain and extend
  explicit `prove_ro` propagation/mutation-rejection coverage;
- obsolete action/effect helpers and declarations named in section 3;
- any old wire/ledger decoder made unreachable by the hard break.

## 11. Documentation update in the implementation delta

Documentation is part of the change, not follow-up work:

- `inter-ontology.md`: redefine `::` as an ontology selector; document recursive
  failure handling, scopes, writes, bounds, errors, and atomic commit;
- `content-layer.md`: make owner-executed cross-ontology writes and atomic
  publication settled architecture;
- `content-layer-design.md`: retain the file's historical label, add this
  normative pointer, and correct its later “current behavior” banners that
  still claim no server cursor/savepoint/scope session;
- `transaction-signatures.md` and `consensus-signatures.md`: specify every new
  phase domain, identity, sequence, genesis, and wipe rule;
- `network-directory-plan.md`: add exact genesis anchors and writable-validator
  route selection;
- `agent-fipa-plan.md` and `minimal-agent-delivery-plan.md`: use the corrected
  action relation, distributed applied event, uniform proof, and post-hard-break
  re-found baseline;
- `deferred.md`: correct the actual stale remote-read, TxId-only outcome, ask
  API, and transport-priority entries; retain the truthful user-auth limitation
  rather than deleting a nonexistent atomic-write bullet;
- `failure-reasons-plan.md`, the ontology creation/join/input/lifecycle plans,
  `network-directory-root-control-plan.md`, `ingress-owner.md`, and
  `client-world-direction.md`: replace obsolete served-ask/action/record/outcome
  contracts or label historical text explicitly;
- `README.md`, `ui/README.md`, explorer/API/UI, config/Nomad examples, source
  moduledocs, metrics/traces/Grafana, examples, and load scripts: remove every
  stale read-only, one-ledger, old event, or no-wipe assumption. Keep a clearly
  named `prove_ro` benchmark and add the chained-write harness.

A repository-wide search for the old action/effect contract,
`foreign_write_unsupported`, “writes stay home,” “cross-ontology reads only,”
the old remote `can_read/3` gate, caller-supplied `CallerNs`, blanket
`circular_ask`, “answer worker,” old ledger magic/domains/events, and
incompatible `::` descriptions must be empty except explicitly labelled
historical quotations.

## 12. Implementation order

The work was reviewed in internal deltas, but no partial semantic mode was
deployed. Steps 1-5 are implemented; Step 6 is the recurring
deployment/release gate:

1. **Implemented.** Correct `action/3` and add semidet `transaction/1` with local
   assertion/retraction/abolish, alternative, cut, nested-transaction, error,
   and failure-reason tests;
2. **Implemented.** Add the shared proof-scope worker and proof context, recursive co-hosted
   scopes, repeated-target
   state, and A -> B -> C tests;
3. **Implemented.** Extend the same path over QUIC, including validator routing, bounds,
   timeouts, session/origin-binding tamper tests, and zero-leak cleanup;
4. **Implemented.** Land explicit distributed records, the phase-aware
   namespace-exclusive lock, the
   ledger-rebuilt outcome index, anchored foreign verifier,
   Begin/Prepare/Decision/Finalize/Complete, and recovery;
5. **Implemented.** Remove the old paths and update all normative documentation;
6. **Release acceptance.** Compile, xref, Dialyzer, full EUnit, full Common
   Test, UI lint/build, shell syntax, diff check, and stale-text audit. For an
   incompatible generation, clean re-found before activation; then run the
   failure/crash matrix and chained-ontology load test on the target hardware.

The repository contains one hard-break implementation, not a feature flag or
compatibility mode. Each release is deployment-ready only after its Step 6
environment gates prove the complete contract.

### 12.1 Step 3 internal-delta contract

Step 3 is a transport substitution, not a temporary remote-proof mode. It first
completes the shared scope semantics that the transport must carry, then
replaces the old QUIC ask protocol outright:

1. **Complete cross-scope savepoints first.** `transaction/1` may begin in the
   origin or in any selected scope. Its initiating scope checkpoints its own
   `#est{}` and asks the origin-owned controller to allocate a bounded
   transaction generation, using the same immediate-parent/origin routing
   discipline as nested selection. Every Erlog choice point created while that
   transaction's checkpoint mode is active obtains a correlated distributed
   savepoint generation through the private scope checkpoint hook; this is what
   restores foreign writes before a second alternative, not merely on total
   transaction failure. Each other already-open selected scope is checkpointed
   lazily on first use under that generation; a scope first opened inside it
   records its write-empty pre-entry revision over its pinned committed base.
   Commit releases the generations, while choice-point redo, failure, or Erlog
   error restores assertions, retractions, abolishes, and assertion order in
   every touched scope. The initiating scope is excluded from the
   controller-driven restore because the existing Erlog/DB callback restores
   its own `#est{}` directly. Read sets remain monotonic. This is new generic
   private checkpoint-hook/controller wiring around the current local
   `choicepoint_checkpoint/1`, not an existing distributed feature or a new
   Erlog semantic. It is implemented and tested for co-hosted scopes before the
   same checkpoint/restore/release commands cross QUIC; no Erlog database copy
   or second transaction engine is added. Transaction-entry and
   transaction-mode choice-point generations share the section 4.2 bound of
   1,024 retained generations per proof. Each scope can materialize at most one
   immutable revision reference per generation, so the existing eight-scope
   limit derives a hard ceiling of 8,192 materialized references per proof.
   Local-only checkpoint tokens do not enter the controller or consume this
   distributed bound. The first foreign selection activates the currently
   reachable tokens before the foreign goal executes; subsequent
   transaction-mode choice points activate at creation. The controller checks
   both activation and materialization before mutation; exceeding either
   returns `{error, {savepoint_limit_exceeded, 1024}}`, poisons the pre-Begin
   proof, and leaves every scope at its prior revision. No unbounded or full-KB
   snapshot is hidden behind the hook.
2. **Give every engine-owned proof the same anchored context, not every raw
   snapshot.** Normal `prove`/`prove_ro`/`execute` workers use
   one factored pinned-origin helper with their engine-generated `ProofId`,
   bounded deadline, root `quod_proof_session`, and `quod_proof_context`.
   Action declarations and prerequisites run as ordinary invocations in that
   anchored proof, so repeated foreign prerequisites reuse their scopes.
   Raw `prove_est/2` remains a strictly one-ontology internal snapshot adapter
   and delegates through `quod_proof_session:run_first`, not a parallel
   interpreter. Runtime projection/heavy jobs do not acquire distributed
   origin authority merely because their
   content-readable `#est.fs` context contains a namespace. Attempting a foreign
   `::` without the private engine-derived anchored metadata fails before
   resolution or dialing as `{ask_requires_anchored_proof, Namespace}`. A
   self-selection remains ordinary local execution. Membership-verdict proofs
   retain their earlier, stricter `ask_in_membership_verdict` refusal. There is
   no context-less transport fallback and no second `::` implementation after
   the legacy answer loop is deleted. Cross-ontology projection/effect
   execution is not part of the D-proof selector and remains forbidden. An
   action receives no exceptional selector authority: its prerequisites have
   exactly the authority of the ordinary proof containing them.
3. **Use one hard-break scope wire.** A fixed-version, safe-ETF envelope carries
   scope open/close, invocation open/next/cancel, nested-selection requests and
   replies, and savepoint checkpoint/restore/release. It binds the authenticated origin key,
   target key, `ProofId`, both anchored ontology identities, opaque binary
   session/invocation/request ids, read-only mode, scope command sequence,
   target event sequence, invocation answer sequence, remaining absolute
   budget, canonical call chain, current monotonic overlay-generation integer,
   and the
   target-computed dirty boolean on every state-bearing reply. The wire never
   carries the target's internal overlay revision, ETS handle, or Erlog state;
   savepoints cross only as opaque bounded ids and are resolved to retained
   revisions inside the target scope. Goal, answer,
   Erlog-error, and failure-reason
   terms use `quod_wire_term`; a goal remains an opaque bounded binary until
   envelope, identity, anchor, rate, and quota checks pass. A missing or invalid
   dirty field fails closed. Pids, references, interpreter state, overlays, and
   diffs never cross the wire. Live-scope duplicates are rejected; no replay
   cache or accepted-command redrive path is introduced.
4. **Register before execution.** The origin router records a bounded pending
   open before sending it. The target opens the shared `quod_scope_session`,
   returns `opened`, and waits for the first explicit demand. Only after the
   router atomically promotes the pending open to the `ProofId`'s monotonic
   touched-scope set may an invocation run. Repeated selection of the same
   `{Namespace, GenesisAnchor}` reuses that session. Nested B -> C selection is
   correlated through the origin controller; B never receives a transferable C
   capability.
5. **Keep one worker and one router.** `quod_scope_session` gains a small
   transport-neutral controller/sink boundary; its proof session, overlay,
   continuations, re-entrant dispatcher, and local behavior remain single
   implementations. `quod_ask_router` becomes the sole bounded network-frame
   correlation and cleanup registry and owns no Prolog state. The namespace
   engine remains the authenticated ingress adapter and owner of the target
   worker monitor, MVCC pin, derivation timer, and lifetime timer. No new OTP
   service, coordinator, or second session registry is introduced.
6. **Make routing exact before opening a scope.** The directory signed record is
   hard-broken from a namespace list to bounded hosted descriptors carrying
   `{Namespace, GenesisAnchor, validator | observer}`. A provisional direct
   seed first performs one bounded, authenticated, non-executing identity
   exchange on the namespace channel; no proof worker, scope, monitor, or
   session entry is created. That exchange confirms and pins both the node key
   and returned anchor, after which the ordinary fully anchored scope-open wire
   is used. Eligible system
   routes for one namespace under different anchors yield `anchor_conflict`
   before a dial. A confirmed direct seed remains the operator's explicit
   override, establishes the locally selected identity, and shadows system
   routes as specified by `network-directory-plan.md`; its pinned anchor can
   never change in place.
   Writable selection treats the advertised role only as a hint and the target
   rechecks that its local key is a current, ready validator before admitting
   the scope; an observer is skipped/rejected and the next pinned route is
   tried. Explicit `prove_ro` may select an observer and propagates strict
   read-only mode through every descendant scope.
7. **Fail and clean up as one proof.** Once a target might have executed, link
   loss, a malformed sequence, target death, or a scope timeout poisons the
   pre-Begin `ProofId`; it is never retried or re-proved elsewhere. Owner death
   closes every pending and accepted session. A remote target cannot monitor an
   origin process, so its namespace engine binds the session to the exact
   authenticated request-link/connection generation and monitors that local
   link process; link `DOWN` immediately kills and removes the session. The
   monitored outbound return link does the same from the other direction. Each
   origin proof worker also monitors the router generation. Router `DOWN`
   poisons the proof; the proof context's already-monotonic opaque scope handles
   let its normal `after` cleanup send one direct close on each retained request
   link without creating a second registry, and a restarted router never adopts
   old sessions. If owner and router die together or a close cannot cross a
   partition, request-link death or the absolute target lifetime reaps the
   session. Idle and absolute scope lifetimes are bounded crash fallbacks, not
   authority renewal. Cleanup is idempotently correlated
   by `ProofId`, session id, link generation, monitor, and timer token, and
   releases continuations, read-set ETS tables, workers, MVCC pins, monitors,
   timers, router entries, and pending replies. The limits in section 4.2 are
   enforced before goal decode, worker spawn, monitor creation, or map
   insertion, including the worker heap limit.
8. **Delete the superseded network path in this delta.** Remove the old
   `quod_ask_open`/`quod_ask_next`/`quod_ask_cancel` frames and decoders,
   per-invocation remote streams, target `start_answer*`/`answer_*` proof loop,
   `watch_owner`/`stop_owner`, AskId-only router entries, and their worker-map
   branches, tests, metrics text, and comments. There is no dual decoder or
   compatibility mode. The Step 4 completion below removed the remaining old
   ledger/API/domain and documentation contracts, not a second ask protocol.

That intermediate `foreign_dirty() -> foreign_write_unsupported` gate was
removed when target sealing and the durable one-ledger submission path landed;
remote writes are no longer volatile state that a successful proof could lose.
The intermediate `can_read/3` policy was likewise removed when `can_invoke/4`
landed; there is no compatibility alias. Step 3's scope transport shipped in
0.7.61 and remains the transport base for Step 4. The status header above is
the authoritative record: the durable implementation is complete in the
repository, while Step 6 remains the release procedure for each incompatible
generation.

Its focused gate proves, non-vacuously: co-hosted and remote cross-scope
transaction rollback for assertions, retractions, abolishes, nested
transactions, errors, and selected success, including a transaction initiated
inside B that selects and rolls back C, and a scope first opened inside the
transaction returning to its write-empty pinned-base revision; a read performed
by a remotely rolled-back branch remains in that scope's monotonic OCC set, and
a foreign write made by the first failed alternative is absent before the
second alternative runs;
remote repeated-B state and
A -> B -> C -> B reuse exactly one session per ontology; local/co-hosted/remote
solutions, reasons, Erlog errors, cuts, redo, failed-write retention, and
read-only rejection agree; anchored lifecycle prerequisites use and reuse the
shared session path, while raw local `prove_est` retains its exact
bindings/diff/read-set contract and foreign `::` from raw runtime/projection,
policy, or isolated state returns the exact typed refusal without a dial or
target worker, while self-selection remains local;
verdict `::` retains its stronger error; re-entrant commands for two invocations
may be outstanding and complete out of request order with exact request/event
correlation, while a duplicate injected while its original is suspended, or
any stale/divergent/skipped command, poisons the proof without a second
derivation or mutation; every bound is tested at its
limit and at limit + 1, including proof that rejected opens never decode the
goal or allocate a worker/monitor/map entry; wrong TLS key, identity, anchor,
mode, `ProofId`, session, invocation, or sequence cannot command a captured
scope; anchor conflict performs no dial and observer-first routing reaches a
validator; request-link drop alone reaps the remote target session without a
remote process monitor; and origin, answer-link, router, target-worker, and
engine death plus idle and active-step timeout all leave zero sessions, workers,
pins, read-set tables, monitors, timers, and router entries. A remote dirty
proof must demonstrate its volatile state reuse, carry a valid target-bound
dirty field on every state-bearing reply/acknowledgement, update true to false
after rollback in target-event order, return the retained feature-gate error,
and leave every committed ontology unchanged; missing or malformed dirty state
poisons the proof.

### 12.2 Step 4 completion: implementation contract

This atomic multi-ontology slice replaces the former temporary group-refusal
branch: proving, backtracking, savepoints, scope
reuse, failure reasons, and the one-participant fast path remain single shared
implementations. Every item below is implemented as one hard-break group path;
Step 6 decides release activation, not whether a second semantic mode is kept.

1. **Use one tagged block/ledger payload.** Hard-break `#block.payload` and
   `#entry.data` onto the same representation:

   ```text
   {batch, [#transaction{}]}
   {dtx, CanonicalControlBlob}
   noop                              % committed entry only
   ```

   `quod_ledger:classify/1` remains the sole decoder/enumerator and returns
   `content`, `begin`, `prepare`, `decision`, `finalize`, `complete`, `noop`, or
   `invalid`.
   Remove the raw-list-to-`{batch, ...}` conversion and its obsolete helpers;
   do not retain an alias. Ordinary batches and singleton DTX barriers share
   block hashing, voting, persistence, catch-up, and replay. Batch collection
   remains content-specific; a control record is always a singleton barrier.
   Every per-kind consumer enumerates the six valid kinds plus `noop` and
   `invalid`, with no catch-all. This changes every block hash, QC, and implicit
   parent reconstruction; it is a consensus-format break that lands only with
   the planned wipe/re-found, never as behavior-neutral cleanup.
   `quod_ledger:payload/1` may deliberately keep collapsing `noop` and
   `invalid` to `error` for its content-only callers.

2. **Keep the protocol pure in `quod_dtx`.** Add five distinct fixed-shape,
   domain-separated canonical records -- Begin, Prepare, Decision, Finalize,
   Complete -- rather than one map with optional phase fields. The ledger carries their
   bounded canonical binary inside one generic DTX author envelope, so nested
   plan/goal/result terms remain opaque outside their owning decoder. The
   semantic record digest excludes the outer author/admission/sequence/signature
   fields, while the certified block hash and QC still fix the exact committed
   envelope. `quod_dtx` owns total encode/decode, record digest, `GroupId`,
   manifest digest, target plan attestation, certified
   reference validation, and one pure monotonic phase reducer. A certified
   reference fixes `{Namespace, GenesisAnchor, Slot, BlockHash, RecordDigest,
   FinalityProof}`. `GroupId` hashes the unsigned Begin body; the origin's outer
   signature is not self-referential. Existing signed local plans are reused
   unchanged. A separate target attestation signs exactly
   `{TargetIdentity, PlanDigest, ManifestDigest}`; there is no second plan
   format. One exact target-identity ordering governs both the manifest rows and
   the Begin participant bundles containing the signed plan, plan digest, and
   attestation; duplicate identities and non-canonical wire order are rejected.
   Given the same origin/coordinator generation and nonce, semantically
   identical groups therefore produce byte-identical semantic Begin bodies and
   `GroupId`s; changing only the outer author envelope cannot mint a second
   group. All limits come from the shared limits header and are checked before
   nested decode or crypto work.

   Complete reuses that target-identity order for its fixed list of
   `{TargetIdentity, FinalizeRef, AppliedGeneration}` rows. These are
   deterministic protocol values, not copies of whichever validator answered a
   live status query. There is exactly one target-ordered row for every Begin
   manifest identity, with no duplicate, missing, or additional target. Each
   Finalize reference must match the GroupId, target identity, and Decision
   verdict; each status is bound to the slot already fixed by that reference.
   Before signing or voting Complete, each origin validator independently
   checks every certified Finalize reference and, for each prepared participant,
   matching canonical replies from `f + 1` distinct NodeKeys, where `f` is
   derived from that target's certified current committee view as in §7.5, over
   identity-pinned links. The response bodies
   use the fixed correlation from §7.5; responder identities are transient
   verification input and are not copied into Complete. Replay and catch-up
   validate only the
   canonical Complete body and origin Complete QC; that local QC is the
   transferable evidence that live voters completed the foreign checks.

3. **Transfer hand-off ownership before closing proof scopes.** Refactor the
   former `quod_vote_journal` into `quod_signing_journal`: one hard-break file/library,
   with no old module or wrapper, that retains both consensus vote latches and
   the local DTX sequence floor and each pending semantic Begin body with its
   latest exact envelope, protected by the same persist-before-exposure rule.
   Simplex remains its sole opener and writer.
   DTX controls have a distinct sequence lane keyed locally by
   `{AuthorAdmission, Author}`, separate from ordinary transactions. One
   Simplex already owns exactly one namespace, so `OntologyIdentity` is not
   redundantly part of this in-memory/journal map key; it remains in the signed
   record where cross-namespace identity is required. Refactor the existing
   content-only `quod_simplex:advance_transaction_sequence/3` into the one
   lane-aware allocator used by both content and DTX validation/allocation;
   do not copy its floor/duplicate logic into a parallel DTX helper. Their
   author envelope binds that continuous admission; the eventual QC binds the
   committee that actually commits the record. The shared signed-record
   interface selects the lane explicitly, and replay projects separate content
   and DTX high-waters. Every DTX phase allocation advances and datasyncs this
   local signing high-water before its signed envelope is exposed. Begin
   additionally retains its semantic body and latest exact envelope because
   only its bound coordinator generation may author it.

   No DTX sequence is held during the attestation round trip. Each still-live
   sealed scope verifies its plan digest, then latches the first
   `ManifestDigest` it attests: an exact retry returns the cached signature and
   a different digest is rejected. Invoke/savepoint commands cannot alter a
   sealed scope; only attestation, the existing exactly-once terminal
   `submit_plan` hand-off for a one-participant proof, and close remain. Once
   all attestations fix the semantic Begin body, the origin worker hands that
   bounded immutable body and its already-computable group reference to its
   owning Prolog engine. The
   engine starts one two-message **volatile intent** hand-off while continuing
   to serve its mailbox:

   1. it sends the complete body/reference to its already-running local Simplex;
      Simplex validates the shape, bounds, identity, and current coordinator
      admission, stores one bounded inactive intent tied to that exact engine,
      monitors it, and acknowledges acceptance without allocating a sequence or
      signing;
   2. only after that acknowledgment, the engine sends the call-correlated
      `GroupRef` checkpoint to the public `prove/2` wrapper, then sends `activate`
      to Simplex, and finally acknowledges the origin worker so it can close the
      scopes. A caller that has already died merely makes that checkpoint send a
      no-op; activation and durable recovery proceed independently of the caller.

   This ordering is load-bearing. The checkpoint precedes any later engine
   `DOWN` at the wrapper, and `activate` precedes that same engine's monitored
   `DOWN` at Simplex. An unactivated intent is dropped on engine death and can
   never sign; an activated intent is wholly owned by Simplex and survives a
   Prolog-only restart. The engine never waits synchronously for disk, consensus,
   or Prolog work, and the checkpoint exposes no signed envelope.
   Caller/worker cancellation that wins before the acceptance acknowledgment
   marks the bounded engine handshake cancelled; when the acknowledgment arrives
   the engine sends `cancel`, never checkpoint/activate. Register, acknowledge,
   cancel, and activate are correlated and idempotent, so no abandoned inactive
   intent or timer remains.

   Activation schedules one serialized Simplex event that first rechecks the
   bound coordinator admission against current committed state, then allocates
   the next DTX sequence, constructs the outer envelope, signs it, appends and
   datasyncs the semantic body, latest exact envelope, `GroupId`, and coordinator
   admission in `quod_signing_journal`, and places that submission into its
   journal-backed DTX ingress slot before exposing it. If retirement committed
   after register but before activation, the event signs/exposes nothing and the
   checkpointed reference resolves through certified `coordinator_retired`. The
   slot feeds the generic
   routing/relay/placement machinery but is not inserted into content custody's
   expiring or strict-order queue. Duplicate register/activate messages are
   idempotent by `{GroupId, SemanticBody}` and the exact engine-bound intent.

   The DTX lane remains available. While the pending envelope's sequence is
   still above committed DTX history, recovery reuses its exact bytes. If
   another same-author DTX control commits first and advances the high-water
   past that envelope, the same Simplex operation allocates a fresh sequence,
   signs the unchanged semantic body, datasyncs the replacement envelope, and
   swaps the local retained-ingress entry before re-drive. A copy already sent
   to a peer may still race, but either valid envelope has the same `GroupId` and
   semantic record; the first committed one wins and the other is an idempotent
   duplicate or stale envelope. Re-enveloping never reopens a scope, requests a
   new attestation, changes the result, or re-proves. An approved but
   uncommitted/volatile floor never triggers re-signing; recovery waits until
   that record commits or the approved branch resolves.

   A Simplex crash before journal sync exposed no signature and loses the
   volatile intent; `quod_ns` uses `rest_for_one` with `quod_simplex` before
   `quod_prolog`, so it also kills the old engine and every scope, and no old
   sender can later resurrect it. A crash after datasync recovers solely
   from the reopened signing journal. A Prolog-only crash either drops its
   unactivated intent or leaves an activated intent owned by the still-running
   Simplex. Therefore a ready exact coordinator may return pre-sync
   `{error, not_found}` only after a synchronous Simplex status barrier. The
   barrier returns pending for an accepted intent or journal row;
   timeout/restart returns outcome-unknown, never absence.

   The public `prove/2` receive loop replaces today's opaque blocking call for
   every potentially durable proof, not only groups: on a normal reply it
   discards its correlated ordinary `OutcomeRef` or `GroupRef` checkpoint. The
   ordinary checkpoint is sent strictly before its asynchronous Simplex request;
   the group checkpoint remains after register acknowledgment and before
   activation. This intentional asymmetry avoids both a hot-path synchronous
   acceptance round trip and a definite error for an ordinary request already in
   Simplex's mailbox. If the engine exits after either checkpoint, the wrapper
   returns `{error, {outcome_unknown, Ref}}`, never `fail`. An exit before its
   applicable checkpoint returns `{error, {ontology_unavailable, Ns}}`;
   `prove_ro` always takes that latter path because it cannot submit durable
   work. Once certified-current `f + 1` outcome snapshots establish group
   absence, `outcome/1` may use this exact coordinator's Simplex barrier plus
   journal/ledger state to return the definitive pre-sync
   `{error, not_found}` described in §9. No new process or service is
   introduced.

   After the engine accepts the hand-off, the origin releases its snapshot and
   closes every proof scope; after a namespace restart, supervision has already
   done so. Simplex now owns the complete canonical body, so consensus/recovery
   pins no proof worker, MVCC snapshot, continuation, or remote scope. Once
   journaled, an uncertain network
   submission returns the full group reference. Origin ledger order resolves a
   coordinator-removal race: a committed Begin with the same `GroupId` and
   semantic body first starts normal group recovery; retirement of its bound
   author admission first proves `{rejected, coordinator_retired}` and permits
   the pending journal row to be removed.
   DTX sequences are strictly increasing, not contiguous, so any consumed
   rejected envelope leaves a harmless gap. The in-memory and journal
   high-water projections retain only current author admissions plus the one
   pending Begin; after a retirement-first rejection, the obsolete lane is
   dropped because an admission id derived from its original slot/block cannot
   recur.

   Compaction unconditionally re-emits every DTX sequence high-water plus the
   semantic body and latest envelope for every pending Begin. Committed history
   may retire that row only after a matching semantic Begin is durable,
   regardless of which equivalent outer envelope won, or after its coordinator
   admission is durably retired first. Every mutating append uses one O(1)
   `maybe_compact` check, so repeated state changes compact even when no ledger
   slot advances. The shared frame bound covers the maximum signed Begin
   submission plus the fixed journal wrapper, and is tested at boundary and
   boundary+1. At most one pending Begin exists per local ontology's Simplex and
   signing journal; this is not a committee-wide or ontology-wide uniqueness
   claim.

4. **Extend the one outcome projection, not the number of services.** Bump the
   rebuildable `quod_outcome` format with two distinct bounded fields: one
   journal-derived local pending-Begin reference and one ledger-rooted active
   group slot per ontology. They may coexist: this validator may have handed off
   G1 while the ontology ledger is already resolving another validator's G2.
   The pending field is only a rebuildable lookup/recovery projection; the
   semantic body and latest exact envelope remain solely in
   `quod_signing_journal`. The active slot stores role flags plus independent
   monotonic origin and participant subphases, manifest digest, the exact local
   hidden plan while prepared, certified record references, and participant
   applied slots. This is required because the origin ontology may also be a
   manifest participant: its one reducer must accept Begin -> local Prepare ->
   Decision -> local Finalize without overwriting either side's recovery state.
   Role acquisition is one total helper: Begin requires an empty active slot;
   Prepare requires an empty slot or the same GroupId's origin-only slot; every
   later role-bearing phase must match that GroupId. A different group never
   overwrites or shares the slot. Direct no-Prepare abort tombstones bypass role
   acquisition because they are terminal metadata rows, not active groups.

   Replay of a Begin with the pending reference's `GroupId` and semantic body
   clears that pending projection and records its authoritative ledger slot even
   if another equivalent outer envelope won. A Begin for another group changes
   only the ledger-rooted active slot and leaves the independent local hand-off
   intact. Role release is ledger-deterministic. A participant role occupies the
   slot from Prepare through Finalize commit; Finalize then moves its remaining
   ordered apply/discard work into the already-separate proof fence, so later
   consensus may progress while proofs stay closed. A direct no-Prepare
   Finalize(abort) writes only its compact tombstone and never acquires a lock.
   An origin role remains active from Begin through Decision and is released
   only by committed Complete. If the origin is also a participant, local
   Finalize ends only its participant subrole and Complete ends the origin
   subrole. Thus every validator and replay accepts the next group at the same
   ledger transition; a local acknowledgment never changes consensus validity.
   Decision alone retains the origin slot and its one recovery worker. A reset
   projection folds Complete when present, or recreates the decided active group
   whose recovery reacquires applied statuses and redrives Complete. This admits
   the next origin group without accumulating unresolved Finalize workers.
   Terminal rows retain compact slots/status, and exact bindings are read from
   the Begin at its recorded slot. Exact duplicates are idempotent; changed
   digests, a second decision or Complete, phase reversal, or a second
   **ledger-active** group fail before mutation.
   Ordinary transaction rows and the 4,096-entry compact cache remain the same
   path. Restart ordering changes deliberately. For an existing V4 ledger, the
   opened store exposes its structurally valid tail and Simplex independently
   reconstructs and validates the slot-1 anchor. It then calls a recovery-only
   `quod_signing_journal:recover/3`: scan and domain-check the journal and recover
   vote latches, DTX local-allocation floors, and the pending Begin, but never use
   the raw ledger tail to prune, retire, or compact a complete journal record.
   Repairing the journal's own torn final frame is the only permitted pre-fold
   mutation. This deliberately replaces the former `quod_vote_journal:open/4`
   behavior that both derives `New = not filelib:is_file(Path)` and prunes or
   compacts from the raw committed height before a validated fold. In particular,
   a missing journal beside a nonempty ledger must fail closed for existing vote
   latches as well as DTX state; boot must never silently create it and forget
   prior anti-equivocation decisions.

   Simplex seeds the recovered pending state into the history accumulator and
   folds committed history once in ledger order, with no journal mutation. The
   consensus committed DTX floor starts from genesis and advances only from that
   validated ledger fold; history is never checked against the journal's
   potentially higher local-allocation floor. The same fold resolves matching
   Begin versus coordinator retirement against the seeded hand-off. Only after
   the complete fold succeeds may `quod_signing_journal:reconcile/2`
   prune/retire/compact against its validated result. A failed ledger fold thus
   leaves every complete anti-equivocation record intact. After reconciliation,
   the next allocation is
   `max(LocalAllocatedFloor, CommittedFloor) + 1`. This is a hard API split, not
   an `open` mode or a raw-height parameter: `recover/3` never creates a missing
   journal, and the empty-ledger path alone calls a separate exclusive
   `initialize/3`. At ledger height zero, that initializer is also the sole API
   allowed to replace a structurally valid zero-record journal; any complete
   signing record makes replacement illegal.

   Fresh creation has one explicit ordering. Build the complete genesis entry
   and its anchor in memory, then `initialize/3` exclusively publishes an empty
   signing journal whose header is bound to that anchor: validate that any named
   journal has zero complete records, write a replacement temporary file,
   datasync it, atomically rename it over the absent or zero-record file, then
   sync the directory **before** appending and syncing genesis. A crash before
   rename leaves only a stale temporary file, which the height-zero initializer
   removes; it never exposes a partial named header. A crash after rename but
   before genesis leaves a valid zero-record journal. Because genesis contains a
   fresh random consensus incarnation, restart may compute a different anchor;
   replacing that zero-record journal is safe because it proves that no vote or
   DTX signature was exposed. A journal containing any complete signing record
   is never replaced: it remains bound to its recorded anchor and may only
   accompany catch-up of that same founding.
   With a nonempty ledger, a missing journal or an anchor/domain mismatch always
   fails closed. This makes a crash on either side of the genesis append
   distinguishable without a migration file or reset exception.
   An empty joiner performs the same journal-before-first-ledger-write ordering
   using its configured genesis anchor before catch-up stores slot 1. At ledger
   height zero, a missing or zero-record journal is initialized for that exact
   configured anchor. Any complete signing record forbids re-founding and keeps
   the journal while refetching only its bound founding.
   On startup,
   Simplex supplies the recovered pending-Begin projection through the ordered
   rebuild handoff;
   `quod_outcome` never opens or writes that file. After Begin, ledger replay is
   authoritative. Losing a rebuildable outcome file can therefore lose neither
   a signed Begin nor its consumed DTX sequence, and there is still only one
   anti-equivocation authority.

5. **Project both gates from one committed-history reducer.** The same pure
   `quod_dtx` reducer advances both Simplex history state and the Prolog/outcome
   projection. Prepare first validates the target plan, transcript policy,
   policy self-seal invariant, membership, exact OCC tokens, foreign Begin
   witness, the shared same-GroupId role transition, and an open proof fence
   against its parent. Only then may
   its singleton block commit and make the plan hidden plus the namespace lock
   durable. An old-group transition is decided through §9's generic exact phase
   lookup; cache absence is never interpreted as group absence. Its reply is
   usable only from the exact engine pid after its index's applied floor reaches
   the candidate parent. Simplex blocks every ordinary ingress/proposal route
   while locked. Its one `quod_dtx:proposal_readiness/2` rule admits the same
   group's Decision when the ontology also owns the origin role and admits the
   prepared participant's matching Finalize; Complete is admitted only after
   Finalize has reopened the lock. The reducer classifies a
   certified direct no-Prepare Finalize(abort) as an already-applied metadata
   no-op, so it is independent of every group lock and changes none of these
   gates. Extend Simplex's existing
   per-namespace protected ETS genesis projection with one
   consensus-lock/proof-fence/generation row. `quod_simplex:init/1` inserts
   `{anchor, GenesisHash}` and an initial **closed** proof-gate row in one ETS
   insert before it returns or exposes readiness. The lock-free accessor treats
   a missing table, a missing/malformed row, or an owner restart as
   fenced-closed; absence never means open. Proof sessions use that same
   lock-free cross-process table pattern as `quod_simplex:genesis_hash/1`, but
   not its current fail-open missing-row interpretation, and no second table or
   table-name atom is created.
   The local overlay adapter receives only a generic access guard, not DTX
   policy, and checks one cheap token containing proof-fence state plus
   generation once per overlay operation, not once per functor; final
   answer/seal re-reads it as the correctness-critical check. A
   pending fence or changed generation reports the retained GroupId as
   `transaction_pending(GroupId)` and discards that old proof. The normal live
   finalization and DTX paths never call `quod_prolog:sync/1`; the existing
   streamed rebuild/catch-up barrier remains only as bounded mailbox
   backpressure. Prepare blocks ordinary consensus admission and proof access
   immediately from Simplex's own reducer, while Prolog
   consumes Prepare, Finalize, and every later transaction cast in FIFO ledger
   order. Finalize deterministically fixes the DTX generation and reopens
   consensus admission, but its proof fence stays closed until Prolog
   asynchronously acknowledges that the hidden diff and MVCC snapshot are
   published at that generation. That acknowledgment carries the exact
   `{GroupId, FinalizeSlot, Generation}`; Simplex opens the fence only when all
   three match its current state, so an old mailbox message cannot unlock a new
   group. It does not advance generation. Simplex, as the protected table's
   sole writer, applies the accepted
   acknowledgment to ETS; it never holds the consensus state machine on a
   mailbox drain. Missing/restarting Prolog keeps the proof fence closed and
   delays new proofs; a proposal whose deterministic verdict needs an unapplied
   Prolog parent still parks through the existing asynchronous membership-style
   mechanism. Replay reconstructs the fence closed and releases it only after
   the replayed head is applied; it emits no live event.

6. **Use one generic signed submission path.** Refactor Simplex's locally
   authored ingress around a small signed-record interface (target binding,
   semantic id, author admission, author, sequence lane, sequence, exact bytes,
   class) implemented by ordinary transactions and DTX controls. It owns
   sequence allocation, signing, semantic duplicate identity, exact-envelope
   recovery, leader routing, relay verification, proposal sizing, and the
   definite/unknown outcome boundary once. Content retains batching, expiring
   retained custody, and its strict same-author ordering. DTX uses the signing
   journal's non-expiring pending slot instead: a control needed to recover a
   ledger-active group may pass this validator's unrelated pending Begin. If
   that later same-author control commits and stales the Begin envelope, the
   journal refreshes only its outer sequence/signature as specified above. DTX
   records are idempotently redriven from their durable phase, remain singleton
   barriers, and never enter a content batch. Do not add five phase-specific
   append/relay stacks or duplicate the existing consensus engine.

7. **Verify foreign finality through one owner.** Use the
   `quod_foreign_log` verifier/cache, which reuses the existing catch-up page and
   certificate-fold code. It is the only new long-lived service. It keys state
   by exact `{Namespace, GenesisAnchor}`, opens dormant verified caches lazily,
   and verifies
   the referenced slot, block hash, record digest, committee and phase. The
   shared 64-validator cap is already enforced at genesis, live membership
   admission/proposal validation, restart replay, local catch-up, and
   certificate shape admission before signer-list traversal or cryptography.
   Before changing
   `quod_catchup:cap_bytes/2`, pin
   the concrete bound from §8: two 256 KiB payloads plus two 64-signer
   certificates at 96 bytes each are 536,576 bytes before framing, below the
   900 KiB response budget; a real worst-case encoded-entry test must include
   framing and remain below that budget.
   Under that invariant the keep-first branch is progress-preserving and the
   stale "needs chunking (deferred)" comment is removed; do not add an
   unreachable rejection/chunking protocol. A missing route/history is
   retry/abstain, never acceptance. Exact-reference checks, current-view
   checks, and continuous follows all select sources through this same owner:
   certified directory/history routes plus bounded authenticated bootstrap
   contacts. Selection is keyed by certified committee member, with at most one
   first-party live endpoint and one certified historical fallback per key.
   Fallback reuses the same request id, worker, and deadline, so it cannot
   amplify quorum weight or correlation capacity. A contact proves only how to
   reach its TLS key; replayed history still proves ontology authority. Local boot does not
   contact foreign peers: the local control-record QC proves that live voters
   completed the foreign check. Do not add a second history codec or verifier.

8. **Keep recovery transport separate from proof scopes.** Proof scopes close
   after Begin construction, so durable coordination uses one fixed, bounded,
   identity-pinned DTX request/reply channel. A small
   `quod_dtx_endpoint` library, embedded in the existing namespace engine,
   owns only framed admission and request-correlation helpers; it adds no
   process and owns no durable phase state. The namespace engine owns
   authenticated-peer checks, rate/correlation accounting, and monitored
   workers using the library's shared limits.
   Submission of one canonical DTX control is delivered concurrently, under
   one deadline, to the bounded selected target-validator set. This is one
   semantic record, not one transaction per validator; existing digest
   coalescing and waiter ownership remain authoritative. Each reached voter can
   retain the authenticated submitter contact long enough to verify the exact
   foreign phase after proof scopes close. A temporary verification abstention
   releases its one validation worker/monitor, and the consensus tick re-enters
   the ordinary validation path for the same current immutable candidate.
   The same channel serves the bounded transaction/group outcome query. It
   first corroborates a view-bound outcome snapshot from `f + 1` distinct keys
   in one certified current committee; only a subsequent group-only pre-Begin
   barrier is accepted from the connection pinned to the reference's exact
   `Coordinator`. No bare endpoint or different member can answer that
   local-journal question.
   Endpoint version 1 uses the one bidirectional deterministic-ETF channel
   `{quod_dtx, Namespace}` and outer frame
   `{quod_dtx_endpoint, 1, Namespace, InnerBinary}`. `RequestId` is exactly 16
   bytes. The fixed inner request algebra is:

   ```text
   {submit, RequestId, RecordBlob}
   {phase, RequestId, GroupId, Kind}
   {outcome, RequestId, OutcomeRef, CommitteeId, MinimumCertifiedSlot}
   {outcome_barrier, RequestId, GroupRef, CommitteeId,
                     MinimumCertifiedSlot}
   {applied, RequestId, GroupId, FinalizeRef, Generation, Verdict}
   ```

   `RecordBlob` is the exact output of the bounded canonical
   `quod_dtx:encode_record/1` semantic-record codec and endpoint admission uses
   only `quod_dtx:decode_record/1`; the target engine then applies target/history
   validation and authors/signs it. `Kind` is one of Begin, Prepare,
   Decision, Finalize, or Complete, and `Verdict` is commit or abort. Replies
   use only:

   ```text
   {accepted, RequestId, SemanticDigest, CertifiedRef}
   {refused, RequestId, TargetIdentity, SemanticDigest, Generation,
             ReasonsBlob}
   {phase, RequestId, Generation,
           not_found | pending | {committed, CertifiedRef}}
   {outcome, RequestId, TargetIdentity, CommitteeId, AppliedFloor,
             not_found | PublicOutcomeStatus}
   {outcome_barrier, RequestId, TargetIdentity, CommitteeId, AppliedFloor,
                     not_found | pending_begin | coordinator_retired}
   {applied, RequestId, TargetIdentity, CommitteeId, GroupId,
             FinalizeRef, Generation, Verdict}
   {error, RequestId, busy | not_ready | not_found | invalid_request}
   ```

   An accepted submit carries the exact certified reference that committed the
   semantic record. The consumer binds its digest to `SemanticDigest` and
   verifies that reference directly; it never re-queries a potentially lagging
   local outcome projection before advancing recovery.

   `Generation` is the target's current unsigned 64-bit DTX generation. For a
   certified Prepare it is taken from the verified post-Prepare projection; on
   an unprepared target it is an availability hint that target validators
   enforce when admitting a direct-abort Finalize. A `refused` reply is only a
   deterministic semantic rejection of the exact submitted Prepare named by
   `SemanticDigest`; overload, rebuilding, absence, timeout, and a skipped
   proposal are never refusals. `ReasonsBlob` is the canonical output of
   `quod_wire_term:encode_failure_reasons/1`, already containing the complete
   target-contextualized stack that must appear in Decision(abort): its first
   entry is `{prepare_refused, {ontology, TargetNs, TargetAnchor}}` and at least
   one following entry carries the actual deterministic rejection reason. The consumer
   checks `TargetIdentity` against the authenticated namespace route and checks
   the semantic digest and generation against the exact request/recovery
   snapshot. The codec bounds and
   safe-decodes both ETF layers, rejects non-canonical
   bytes and every other shape/version, and performs no identity or semantic
   phase decision. The consuming engine accepts a reply only from the expected
   authenticated peer and additionally matches its exact request fields. One
   envelope is at most the DTX-control bound plus 4 KiB and remains below the
   transport frame cap. The current per-ontology correlation cap is
   `8 participants * 64 validators = 512`, shared by every overlapping
   operation; it can therefore refuse a second valid operation even though it
   accommodates one worst-case request set. The target also admits only eight
   inbound endpoint workers, so a ninth applied-state/current-view request gets
   `busy` and Complete validation can prevent its own quorum. There is no
   authenticated-DTX requests-per-second or burst limiter. These operational
   caps are scheduled for removal in `dtx-latency-optimization-plan.md`; they
   are not wire-safety bounds.
   The process-free `quod_dtx_recovery:next/2` planner takes the exact canonical
   Begin plus bounded, target-ordered verified phase evidence, target
   generations, corroborated applied-status bodies, and at most one definite
   refusal represented exactly as
   `{TargetIdentity, SemanticDigest, Generation, ReasonsBlob}`. It rejects a
   refusal for a non-participant, a different Prepare digest or generation, an
   already-certified Prepare, or a malformed/empty/non-canonical stack, and
   copies the decoded stack unchanged into Decision(abort). It returns only
   bounded target-ordered `submit`, `phase`, or
   `applied` commands, or the certified Complete reference. Every invocation
   reconstructs its phase from those inputs; the module retains no retry or
   coordinator state. Phase evidence is the existing
   `{TargetIdentity, Control, CertifiedRef}` triple returned after foreign-log
   verification, not a second durable record format.
   The namespace engine remains the owner of `quod_outcome`, and one monitored
   worker per active group runs the pure `quod_dtx` recovery commands. The
   worker:

   - submits/recovers Begin at the origin;
   - prepares participants in canonical identity order;
   - commits abort on a definite refusal, or commit only with every certified
     Prepare;
   - sends the certified Decision to every participant and waits for each exact
     applied status: the Finalize QC for a direct no-op abort, or the matching
     authenticated reply set for a prepared participant;
   - submits the canonical Complete to the origin and waits for its certificate.

   A participant that already applied or discarded its Finalize re-serves the
   same canonical status after worker or origin restart. Receipt of the final
   required status makes Complete eligible but changes no consensus state.
   Committed Complete advances the origin consensus state to
   `completed_commit` or `completed_abort`, clears the one active slot, and ends
   the consensus recovery worker. Its ordered apply cast then persists and
   flushes the Prolog-owned compact terminal projection before releasing any
   local caller waiter. Until Complete commits, Decision and Finalize
   certificates remain `pending(finalizing_*)` and no second group is admitted
   at the origin; after commit but before the projection flush, lookup remains
   outcome-unknown rather than falsely terminal.

   Unavailability or a caller deadline after Begin never becomes logical
   failure: it returns `outcome_unknown({group, ...})` and recovery continues.
   Replay restarts the same worker from the projected phase. Prepared
   participants never use a local timeout to abort. After Begin, any current
   validator may redrive an equivalent Prepare, Decision, Finalize, or Complete
   with its own DTX sequence/signature; semantic phase identity, not signer
   identity, makes duplicates harmless. The coordinator's signing journal is the sole
   local restart and re-signing authority for a pending Begin: exact bytes are
   retried while admissible, or the same semantic body is re-enveloped after its
   DTX sequence becomes stale. Peers may still relay an already-disseminated
   exact signed envelope; whichever equivalent envelope commits first is the
   same semantic group.

9. **Finalize visibility in one mailbox turn.** A prepared Finalize commit ends
   the consensus-admission lock while the proof fence remains closed.
   `Finalize(abort)` discards the hidden plan and records abort without changing
   D. `Finalize(commit)` applies the already-validated hidden diff, commits the
   MVCC snapshot and local applied-status projection row, and emits the one live
   group event. It does not repeat OCC. That ordered Prolog turn sends the exact
   applied acknowledgment; Simplex validates it and opens the proof fence. The
   participant consensus role was already released by the committed Finalize;
   the acknowledgment only completes its local visibility. A direct no-Prepare
   Finalize(abort) is instead an applied metadata tombstone at consensus commit:
   it has no lock, fence, hidden plan, mailbox dependency, or domain event, and
   its ordinary Prolog cast only updates the compact projection. The last
   manifest applied status lets origin validators propose and validate Complete.
   Committed Complete releases the origin role; its ordered Prolog apply flushes
   the terminal row and only then reports commit or abort, returning the
   persisted bindings and per-ontology slots on commit. A dual-role ontology
   follows both ledger transitions. `outcome/1`, explorer, feed, metrics, and
   runtime enumerate group state; Prepare and Complete are never displayed or
   emitted as applied domain changes.

10. **Release the one implementation.** The complete coordinator has replaced
    the old multi-participant refusal. Obsolete payload conversion,
    first-response outcome lookup, and superseded helpers/tests/comments are
    deleted; there is no compatibility decoder, migration, feature flag,
    independent-append fallback, or deferred recovery case. Run the complete
    gates, format
    wipe/re-found, crash matrix, three-ontology functional test, and chained
    write load test before deployment. Focused crash tests include: an ordinary
    commit during manifest attestation before the DTX sequence is allocated;
    journal compaction and reopen with a pending semantic Begin, its latest
    exact envelope, and the consumed DTX floor; a reset outcome index recovering
    that Begin from the journal; a later same-author DTX commit making the
    pending envelope stale, proving recovery journals a fresh envelope for the
    unchanged semantic body, attestations, and `GroupId`; a locally pending G1
    coexisting with another validator's ledger-active G2; Prolog and Simplex
    crashes before intent acknowledgment, after intent acknowledgment but before
    the caller checkpoint, after the checkpoint but before activation, after
    activation but before journal sync, and immediately after datasync. These
    prove that an unactivated intent never signs, an activated intent survives a
    Prolog-only crash, a pre-sync Simplex crash becomes exact-coordinator
   `not_found`, and a post-sync crash re-drives from the journal while the
   outside `prove/2` caller retains `outcome_unknown(GroupRef)`. Kill the engine
   for an ordinary one-participant durable submission after its `OutcomeRef`
   recovery checkpoint **and after the asynchronous request enters Simplex's
   mailbox but before its reply**, and prove the public caller receives
   `outcome_unknown(OutcomeRef)`, not `fail` or `ontology_unavailable`; kill a
   `prove_ro` engine and prove it returns typed
   `ontology_unavailable`, not `fail`. Crash `quod_simplex` under `quod_ns` and
   pin the `rest_for_one` child order (`quod_simplex` before `quod_prolog`) by
   proving the old engine and scopes are stopped before its replacement can
   serve. Coordinator retirement between register acknowledgment and activation signs nothing and
    resolves that checkpoint through the ledger; both
    ledger orderings of Begin versus coordinator-admission retirement, including
    restart; a compaction-sized signing journal followed by a structurally valid
    but semantically invalid ledger tail proving failed boot leaves every
    complete journal record unchanged; and a deliberately deep or restarting
    Prolog mailbox proving live consensus remains non-blocking while Prepare
    still excludes ordinary content and after Finalize has reopened admission
    but not yet been applied.
    Fresh-founder crash points cover after the empty anchor-bound journal and
    directory sync but before genesis append, and after genesis sync but before
    normal startup reconciliation. The first restart computes a new random
    incarnation/anchor and atomically replaces the structurally valid zero-record
    journal; injecting one complete signing record makes the same replacement
    fail closed.
    A stale or mismatched Finalize acknowledgment must not reopen the proof
    fence.

## 13. Acceptance tests

At minimum:

1. Three genuinely distinct committees/nodes: A writes, calls B which writes
   and calls C which retracts; one proof returns only after all three exact
   applied statuses, the origin Complete certificate, and the ordered origin
   terminal-row flush.
2. C failure is visible first only inside B. B recovery succeeds and A receives
   success; unrecovered B failure reaches A with the nested bounded reasons.
3. Repeated `B::assertz(x), B::x` reads staged state and yields one B plan.
4. A remote goal that writes then logically fails returns its updated scope;
   ordinary fallback sees the write, matching local Erlog.
5. `transaction/1` rolls back assertions, retractions, and abolishes across
   A/B/C; success retains the first complete solution; nested transactions and
   alternative search select the correct branch state; cuts have only normal
   Prolog meaning. A failed transactional
   branch that reads B before an outer alternative writes A retains B's OCC
   dependency and aborts if B changes. A cut inside `transaction/1` prunes only
   its inner alternatives, while a caller cut affects only caller alternatives.
6. Two action clauses target the same state. The first mutates then fails its
   postcondition; it is fully restored and the second succeeds.
7. Local, co-hosted, and remote execution produce identical solutions, failure
   stacks, bounded Erlog exceptions at the immediate caller, scope plans, and
   final facts.
8. A conflicting write before Prepare makes that participant refuse; every
   manifest participant finalizes abort, prepared peers discard their hidden
   plan, and unprepared peers commit the certified no-op tombstone. No ontology
   exposes a diff. Race one late Prepare against that tombstone in both ledger
   orders: Prepare-first is discarded, while tombstone-first rejects Prepare as
   a phase reversal. Cross A-origin/B-origin aborts while both ontologies hold an
   unrelated active lock: each direct no-Prepare tombstone commits as a metadata
   no-op, changes only its own tombstone, and leaves the other group's lock,
   fence, generation, active role, and D state byte-for-byte unchanged; both
   groups reach Complete rather than deadlocking. Separately, hold G1 after a prepared Finalize has released
   its role/lock but before its apply acknowledgment opens the fence; a direct
   no-Prepare abort for G2 still commits immediately, waits for no acknowledgment,
   and leaves G1's fence and generation byte-for-byte unchanged live and on
   replay, with the same canonical G2 Complete row in both paths. Then deliver
   G1's acknowledgment normally. Once any
   Prepare lock is committed, consensus ingress refuses even a disjoint ordinary
   change until a prepared Finalize commits, while proofs return
   `transaction_pending` until the exact applied acknowledgment opens its fence.
9. A read-only participant whose premise controls another ontology's write is
   included and conflicts correctly.
10. An abort Decision leaves both namespaces old. Under a commit Decision,
    pause after B's Finalize is committed, applied, and acknowledged, then after
    C's Finalize is committed but before C applies it. B serves new state and C
    may continue consensus, but C remains proof-fenced: any normal proof that
    also selects C returns `transaction_pending` and can never succeed with
    B-new/C-old. C's ordered apply and exact acknowledgment then open its proof
    fence; all exact applied-status evidence makes Complete eligible. A
    Decision alone, and every Finalize QC with one prepared application status
    missing, remain `pending(finalizing_*)` and keep the origin active slot
    occupied. Even the full status set changes no consensus state: G2 remains
    rejected until the canonical Complete commits. That commit releases the slot
    and consensus recovery worker and admits G2 identically live and on replay.
    Before the ordered Complete apply flushes the outcome row, lookup and the
    original caller still receive outcome-unknown; the flush then publishes the
    one terminal result. Abort follows the same completion rule.
    On one ontology, Begin(G1) followed by Prepare(G1) sets both role bits in the
    same slot; while G1 remains active, Begin(G2) and Prepare(G2) are rejected
    without overwriting either role, and G2 becomes admissible only after G1
    Complete releases the origin role. In the symmetric participant-G1/origin-G2
    case, Begin(G2) is rejected until local Finalize releases G1's participant
    role; it may then occupy the empty slot, while any Prepare still obeys the
    independently closed proof fence.
11. Before Begin commits, kill/restart the coordinator process and node with the
    same disk after journal datasync; the signing journal recovers the same
    semantic Begin and either the exact still-admissible envelope or a freshly
    journaled envelope with the same `GroupId`. A crash before journal sync
    leaves no durable group. From committed Begin onward, kill the origin and
    each participant after Begin, after each Prepare, after Decision, after one
    Finalize, after the last applied status but before Complete, and after
    Complete. Committee-wide recovery reaches exactly one outcome, exactly
    once, and releases every consensus-admission lock and proof fence under the
    stated `<= f`, eventual-synchrony, durable-disk, surviving-holder fault
    model.
12. Partition after Prepare and after Decision. The former stays safely
    unavailable until a decision; the latter returns
    `outcome_unknown(OutcomeRef)`
    and eventually commits Complete without re-proving.
13. Tamper each session id, `ProofId`/origin binding, invocation sequence, plan,
    manifest, subject/chain, namespace, anchor, phase, record digest, DTX author
    sequence, block, and certificate. Use an observer, a wrong TLS key, and a
    removed old committee. Every case fails before voting or lock mutation. The
    same coordinator re-enveloping the same semantic Begin after a committed
    same-author DTX control overtakes its old sequence retains its `GroupId` and
    cannot create a second group; reusing target attestations under a different
    coordinator admission or coordination nonce is rejected before lock
    mutation.
14. Two valid eligible system routes advertise one namespace under different
    anchors; resolution returns `anchor_conflict`, opens no scope, and changes
    no route high-water. A confirmed direct seed keeps its documented local
    override precedence and cannot change its pinned anchor.
15. Any duplicate, stale, or skipped live scope command is rejected without
    executing twice. Separately, an exact duplicate signed durable DTX record
    returns its existing witness or no-ops idempotently; a different digest,
    commit/abort reversal, Finalize(commit) without Prepare, and a claimed
    `GroupId` paired with a different semantic body are rejected. A direct
    Finalize(abort) requires the certified matching Decision, writes one no-op
    tombstone, and makes every later Prepare a phase reversal. Duplicate or
    changed Complete evidence is checked with the same strictness. With a fixed coordinator
    generation and nonce, permuting the same
    participant inputs builds byte-identical target-ordered manifest/Begin
    bodies; duplicate identities or a non-canonical participant bundle on the
    wire are rejected. A sealed scope's first manifest attestation is cached;
    exact retry returns the same bytes and a second digest is rejected.
16. Restart and fresh catch-up reconstruct exact active consensus-admission
    locks, the independent proof fence and generation, hidden plans, facts,
    committee projection, group status, and terminal index. For commit and a
    prepared abort, a committed-but-unapplied Finalize has admission open and
    the proof fence closed until the exact ordered apply/discard acknowledgment.
    A direct no-Prepare abort is applied at Finalize commit. Replay
    emits no reactions; live post-Finalize apply exposes its applied operations
    once. With a local pending
    G1 and ledger-active G2 both populated, outcome-index reset and restart
    reconstruct both independent fields without blocking G2 recovery or losing
    G1's journal hand-off. When the origin is itself a participant, replay of
    Begin -> local Prepare -> Decision -> local Finalize preserves both its
    origin and participant subphases and resumes the correct next command. A
    participant crash after applying Finalize but before delivering its
    acknowledgment re-serves the same exact applied status after restart. The
    origin neither serves a terminal result at the last status nor retains the
    active slot after Complete commits. Kill the engine after that QC but before
    its Complete apply: the caller gets outcome-unknown, replay flushes the row
    before ready, and later lookup is terminal. Fresh replay of G1 Decision
    followed by Complete and G2 Begin accepts both in order; deleting Complete
    makes that same G2 history invalid. After more than 4,096 other terminal rows evict an abort tombstone
    from memory, a fresh-envelope Prepare for that old group is still rejected
    by the exact disk row; restart and catch-up reject the same ordering from the
    ephemeral phase fold. A delayed live phase-lookup reply whose parent token
    changed is ignored and revalidated; a rebuilding or unavailable Prolog
    owner parks only that DTX verdict while ordinary consensus continues. A
    deliberately injected forward-gap apply leaves the outcome floor below the
    requested parent: the reply cannot become `not_found`, the verdict parks,
    and filling the gap resumes the exact lookup.
17. Membership-changing distributed plans preserve the old-committee validation
    boundary and change membership only on commit Finalize.
18. Every wire/admission size/count limit rejects before decode, spawn, or map
    insertion; incrementally generated state rejects before ledger mutation or
    lock acquisition and remains under the worker heap cap. Cancellation before
    intent acceptance/activation leaves no intent, worker, session, pin, ETS
    table, router entry, or timer; if activation won first, cancellation returns
    the group outcome reference instead of dropping owned work.
19. Explorer groups every physical record under one `GroupId`, never labels
    Prepare or Complete as a domain application, and shows Decision-without-
    Complete as pending rather than committed/aborted. It derives either
    terminal label only from Complete and shows rejected/outcome-unknown
    accurately.
20. Chained-write load testing reports logical proofs/s, physical records/s per
    ontology, blocks, conflicts, redirects, recovery counts, and end-to-end
    p50/p95/p99 without hiding the additional consensus work.
21. A -> B -> C -> B re-enters the suspended B scope, including inside a nested
    `transaction/1`, without `circular_ask`, deadlock, lost checkpoint, or a
    second B overlay.
22. After one B answer, a later invocation mutates B; redoing the older B choice
    point keeps its bindings/continuation but sees B's current overlay. Cuts
    inside and immediately after `B::Goal` match self/co-hosted/remote behavior.
23. `can_invoke/4` allows/denies identically for top-level, self, co-hosted, and
    remote entry. Denial runs none of Goal and fails logically with a bounded
    `not_allowed(TargetNs)` reason readable by `get_fail_reasons/1`, so
    `(Denied ; Allowed)` executes `Allowed` while the denied target is left
    unread and unmutated; an invented chain/principal and the removed
    `CallerNs` API cannot bypass it. A migrated restrictive policy explicitly
    checks every chain member and denies if any one is unauthorized. A refusal
    that changed the proof's control flow appears in the sealed transcript and
    re-proves as false at the pinned base.
24. A sole foreign material scope uses one target-authored ordinary transaction,
    returns `{transaction, TargetNs, TargetAnchor, TxId}`, and recovers exact
    bindings through `outcome(OutcomeRef)` after caller death. Two material
    scopes return
    `{group, OriginNs, OriginAnchor, Coordinator, CoordinatorAdmission, GroupId}`
    and exact persisted bindings through the same API. If coordinator retirement
    commits before Begin, the same reference resolves the definitive
    `coordinator_retired` classification; if Begin commits first, it resolves
    the normal group regardless of the later retirement. One Byzantine or old-
    view outcome reply never decides any status. Lookup first requires `f + 1`
    identical current-view snapshots bound to the same CommitteeId and minimum
    applied slot. Their ordinary-transaction `not_found` remains outcome-unknown.
    Their group `not_found` then resolves only through coordinator absence in
    the certified current committee or the exact ready coordinator's serialized
    barrier after journal/ledger rebuild; coordinator unavailability or a stale
    publication floor remains outcome-unknown.
25. OCC detects absent -> present -> absent through its tombstone version; a
    transaction whose read set names a functor written earlier in the same
    block is rejected at its exact apply position on every node, while blind
    writes remain ordered and a self read-modify-write applies.
26. V1/V2/V3 ledger magic, every recognized superseded vote-journal magic, the old
    scope-session version, and every superseded DTX control/endpoint domain fail
    explicitly before replay/decode, at the exact offset and without mutating
    the file; the new signing-journal magic opens, and only a fresh V4 genesis
    starts. Unchanged ordinary transaction,
    directory, and consensus-share domains are not gratuitously renumbered. An
    entry-data kind the release does not recognize classifies as invalid rather
    than as content or the inert skip. V4 genesis validation rejects policy
    omission, any non-assert operation, and assert-then-retract attempts. With a
    compaction-sized valid signing journal and a structurally valid but
    semantically invalid ledger tail, boot fails without pruning, compacting, or
    changing any complete journal record. Repairing the ledger then recovers the
    original vote and DTX anti-equivocation state before reconciliation. A
    founder crash with an empty ledger and a valid zero-record journal atomically
    replaces it for the newly computed random genesis anchor and retries genesis;
    any complete signing record forbids replacement or re-founding. A nonempty
    ledger with a missing or
    mismatched signing journal always fails before serving or signing and never
    creates a replacement: the test seeds a live vote latch before deleting the
    journal, so it pins the existing vote-safety case as well as DTX. Kill a catch-up
    worker with its phase scratch open, start a replacement session before the
    old process exits, and prove their unique DETS names cannot collide; the
    replacement closes then removes its own file, and namespace restart removes
    only the abandoned exact-prefix file. On a large ledger, a one-slot
    content-only repair opens no phase scratch and performs no slot-1 rescan;
    the first later DTX transition triggers one lazy backfill, after which all
    pages extend the same session set.
27. While Prepare is locked, direct append, batch collection, retained custody,
    relay re-drive, proposal validation, replay, and catch-up all refuse ordinary
    content; no ingress path commits a bypass. After a prepared Finalize commits,
    ordinary consensus may progress but new proofs still return
    `transaction_pending` until the exact applied acknowledgment opens the
    fence; duplicate, stale, or wrong-group acknowledgments cannot open it. A
    new Prepare also parks while that fence is closed even though the earlier
    participant role ended at Finalize; after the exact acknowledgment it
    proceeds without overwriting the one fence row. Direct no-Prepare abort
    tombstones remain independent metadata no-ops as tested above.
28. A target mutates its volatile overlay and then loses transport before its
    parent accepts a result. The whole pre-Begin `ProofId` is poisoned and every
    scope/overlay/session/router entry is reclaimed.
29. Variable, non-callable, improper-list, and empty-list action shapes—including
    invalid `DesiredState`—fail before any candidate goal or transition runs.
30. Router, verifier, committee, frame, answer, incremental diff/read/transcript,
    plan, worker-heap, Begin, Complete, and aggregate group caps are exercised at
    boundary and boundary+1; an exponentially generated Prolog term dies as
    `proof_limit_exceeded`. A 64-validator committee succeeds, while member 65
    is rejected at genesis, live admission/proposal validation, replay, local
    catch-up, foreign projection, and certificate admission before signer-list
    traversal or cryptography. A worst-case valid implicit catch-up entry with
    two maximum payloads and two 64-validator certificates is proven below the
    page byte cap. The keep-first rule still advances catch-up and its response
    remains below the transport frame cap. Scope admission follows the normal
    worker lifecycle; it has no separate traffic-rate gate or token-bucket
    state. At most two exact group-phase
    lookups exist for one ontology, attached to the two live pipeline latches;
    competing exact redrives coalesce and verdict, parent retirement, timeout,
    and Prolog death each reclaim the entry. For a 64-validator target, Complete
    retains exactly 22 identical canonical status bodies from distinct pinned
    NodeKeys; a duplicate key or committee-view change is rejected before body
    retention, and the replies never enlarge the Complete ledger body. An
    over-rate frame's bounded
    `GoalBlob` is never decoded as a Prolog term.
31. The same semantic plan content bound to two namespace/anchor identities
    receives two different canonical `TxId`s, and an outcome reference routes
    only to its exact target founding. A committed result older than the old
    explorer's 5,000-slot scan budget still resolves after restart from the
    rebuilt outcome index, including a sole-foreign result reached through a
    pinned route.
32. Fresh runtime creation without an author `can_invoke/4` clause succeeds:
    founding injects the bodyless host-entry default, so the host can query its
    own new ontology while remote callers stay fail-closed. An explicit
    restrictive rule founds and *serves* — the host's own readiness proof is
    admitted while the rule governs remote callers. A hand-built policy-less or
    non-assertion genesis that bypasses `genesis_tx` is still rejected on
    replay/catch-up as invalid genesis. Resume accepts valid replacement options
    without requiring their ignored terms to repeat the committed policy, and
    no normal same-VM prove/eval path bypasses it. An instrumented source proves
    runtime creation reads/compiles once and hands the exact `InitialDiff` to
    genesis construction without a second compilation. The 192 KiB compiled
    diff boundary succeeds; boundary+1 returns
    `ontology_creation_failed(initial_content_too_large)` before desired-state,
    filesystem, or ledger mutation, and the complete genesis still cannot
    exceed the existing 256 KiB block ceiling.
33. A transaction that retracts or abolishes the last `can_invoke/4` clause is
    rejected as `policy_self_seal_forbidden` and leaves the committed state
    unchanged. One transaction may retract the last old clause and assert its
    replacement because the final post-diff state remains authorized. The same
    cases pass identically through ordinary live apply, restart/catch-up replay,
    and distributed Prepare/Finalize; the affected participant refuses a
    distributed removal-only plan, any earlier canonical participant finalizes
    abort, and no participant exposes its hidden diff.

Release gates are compile, xref, Dialyzer, full EUnit, full CT, shell syntax,
`git diff --check`, stale-text audit, a fresh-ledger deployment, the crash
matrix, and the chained-write load test. Commit and version bump remain separate,
and nothing is pushed without Yan's instruction.
