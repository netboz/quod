# Uniform distributed Prolog proofs and atomic ontology writes

**Status:** architecture reviewed; implementation in progress. Step 1's local
`action/3` and `transaction/1` foundation landed in Quod 0.7.58. Distributed
steps 2-6 are not implemented or deployed.

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
  cancellation provide the transport pieces, although router admission still
  needs the explicit bounds below;
- the normal `quod_prolog` path already builds the unsigned transaction and
  waits for ordered apply with the `outcome_unknown` contract;
  `quod_simplex:sign_local_change/2` reserves the author sequence and signs it.

The mistake is narrower and directly visible in the code: ordinary local
proofs use the one-shot `quod_prolog:run_proof_est_annotated`, while selected
ontologies use a second, resumable proof loop in `quod_ask:answer_init` /
`answer_loop` / `step` / `drive`. That second loop deliberately drops the read
set and rejects any overlay change as `foreign_write_unsupported`. Build one
reusable resumable scope runner from the latter's continuation/backtracking
mechanics and the former's overlay setup, annotation, error mapping, and
cleanup. Ordinary local and selected proofs both delegate to it;
`prove_est*` remains only a thin synchronous wrapper for runtime/verdict calls.
Then delete the separate answer interpreter and write-rejection branches. Do
not add a third proof engine.

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
including a sole foreign target; `{group, OriginNs, OriginAnchor, GroupId}` for
a multi-ledger proof) and queries that handle instead of re-running the proof.
The namespace and genesis anchor are part of the handle because `TxId` is not a
global consensus identity and the durable answer may live on another ontology.

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

Failure reasons remain proof-local, bounded, atom-safe, and never enter the
ledger. `fail_with_reason/1` and the automatic failing-predicate frames are the
single diagnostic mechanism on local, co-hosted, and remote paths.

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
- eventually, the distributed proof context's exact per-scope savepoint
  generation.

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

Node-local create/join operations remain typed external lifecycle operations:
their declarations use the same argument meaning, but ordinary `goal/1` and
`transaction/1` reject E-class predicates. The dedicated `run_action` entry is
restricted to the existing typed create/join allowlist: it checks DesiredState,
selects the exact requested Transition declaration, proves its prerequisites
and policy read-only, calls the typed Erlang helper once, then checks
DesiredState again. Once IO starts it is never backtracked into another action
clause. This is the existing D/P/E boundary made explicit, not a generic effect
dispatcher or a claim that external IO is rollback-capable.

## 4. One proof context, one scope per ontology

Factor the existing local `quod_prolog` proof worker and remote
`quod_ask` answer worker into one proof-scope worker. Today those paths duplicate
the proof loop and the remote copy adds the read-only policy. After this change,
the same worker implementation owns the frozen view, overlay, Erlog state,
failure reasons, alternatives, and limits for an origin scope or a selected
remote scope. Separate local/remote admission quotas remain a DoS boundary, not
a semantic distinction. The ordinary top-level proof path also calls this same
resumable runner; `run_proof_est_annotated` no longer remains as a parallel
first-solution interpreter.

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
only transport.

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
Sequence checks reject duplicate, skipped, cross-proof, and cross-node commands.
An old invocation continuation is not rejected merely because the scope overlay
advanced: invocation answer sequence and scope overlay revision are separate.

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

`transaction/1` checkpoints its current local overlay and asks the origin-owned
context to open one correlated savepoint id. On the first use of another scope
under that id, the origin sends that scope a serialized lazy-checkpoint command;
a newly opened scope records an empty/pre-entry overlay. Rollback restores every
touched scope's saved overlay revision. A scope first opened in the failed
branch remains pinned and registered until the top-level proof ends, with its
writes restored, because its monotonic read dependencies can still influence
the surrounding proof. Success keeps each current overlay state.

Re-entrant ancestor invocations are serialized by the same origin dispatcher
and may change an ancestor while it is suspended. On resumption the saved
continuation receives that scope's current overlay reference. Savepoint commands
therefore use explicit revisions and never assume a waiting ancestor is frozen.
Savepoints retained solely by a cut-away continuation are reaped with the proof,
so distributed savepoint cleanup needs no additional cut hook beyond step 1's
opt-in Erlog choice-point checkpoint support.

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
the whole execution transcript. A denial runs none of the requested goal and is
a fatal typed authorization error, not a logical predicate failure that can
backtrack into another branch.

Today's `can_read/3` runs once for **every** authenticated peer/ontology subject
in the incoming chain and requires all calls to succeed. `can_invoke/4` instead
receives the canonical whole chain once. A restrictive migrated policy must
therefore inspect/quantify every `CallChain` member itself; `Principal` replaces
the authenticated peer argument but does not silently preserve the old
per-member conjunction. Shipped policies are rewritten and tested explicitly;
there is no compatibility loader.

No matching `can_invoke/4` clause means deny. A fresh ontology must contain at
least one explicit fact or rule whose clause head is `can_invoke/4`; omission is
invalid genesis, not a private ontology. A private ontology supplies a
restrictive rule. Common predicates never inject a default, while shipped root,
examples, and test ontologies that are intentionally open carry an explicit
default-open clause in their own source.

Use one pure compiled-diff invariant, not duplicated term scanning. On a fresh
runtime create, validate it after source aggregation/compilation and before
`start_new_content/2`; omission returns
`{error, missing_can_invoke_policy}`, which the Prolog adapter exposes as
`ontology_creation_failed(missing_can_invoke_policy)`. A resume still validates
the newly supplied source syntax but does not require its ignored terms to
repeat the already-committed policy. One shared pure validator is called by
`quod_simplex:genesis_tx/4` before slot-1 append for file, in-memory,
direct-manager, and boot founding paths, and by
`valid_history_entry/4 -> valid_genesis_transaction/2` during restart/catch-up.
It requires a V3 assertion-only genesis diff containing an asserted
`{can_invoke,4}` head, so an assert-then-retract or hand-built policy-less
genesis cannot enter through either path. V1/V2 stay rejected by the hard
break.

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
loaded beside the new rule. Normal same-VM proof and lifecycle entry does not
bypass `can_invoke`; trusted lifecycle APIs may create/join hosting state but
are not a raw-content repair path. Arbitrary host VM control remains outside the
authorization boundary, but no supported operator policy override is added.

This does not claim to complete the separate user/agent authorization
milestone. It preserves the current trusted-administrative-fleet boundary
documented in `content-layer.md`: the target's current validator owns the scope,
seals its own plan, and authors its own ledger records. A caller never supplies
or signs a target ontology's diff. When authenticated
`subject(User, AgentChain, Capabilities)` lands, it replaces the explicit node
principal at this same policy seam without changing distributed proof
semantics. The still-unauthenticated public prove endpoint remains an existing
deployment boundary and is not falsely presented as fixed here.

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
the origin node's existing return router under `ProofId`, before executing the
first goal. That router is only a bounded ownership/cleanup registry; it holds
no Prolog or overlay state. Therefore a B crash after opening C but before
returning C's handle cannot orphan C or hide it from root-proof cleanup.
The current router maps are not yet bounded merely because entries are
monitored; this delta adds the table's explicit global/per-owner/per-peer
admission caps and rejects before monitor/map insertion.
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

The router also keeps a per-authenticated-peer/per-ontology scope-open token
bucket and the engine keeps the existing bounded rejection-emission bucket.
The hard-break open frame carries the nested goal as a separately length-bounded
encoded binary, so fixed outer-frame/session/peer validation can extract only
metadata and `byte_size(GoalBlob)` without decoding the Prolog term. Rate and
admission checks then run before `quod_wire_term` decodes that blob, worker
spawn, monitor creation, or session-map insertion. The token-bucket table is
itself capped globally, retains only fixed-size
`{PeerKey, OntologyIdentity}` keys, expires idle entries, and fails closed when
full. An over-limit request receives the fixed `ontology_rate_limited` result
while reply budget remains; excess replies are dropped without spawning work.

Starting limits are concrete and schema-validated:

| resource | limit |
|---|---:|
| active invocation depth | 8 |
| distinct ontology scopes per proof | 8 |
| commit participants | 8 |
| active proof scopes per ontology | existing configurable 64 |
| active scopes from one authenticated peer | 16 |
| scope-open attempts per authenticated peer/ontology | 32/s, burst 32 |
| scope rejection replies per ontology | existing 32/s |
| scope-open rate buckets / idle expiry | 1,024 global / 60 s |
| one proof-scope worker heap | 64 MiB, converted once to VM heap words |
| origin-router entries global / per proof owner / per peer | 512 / 8 / 16 |
| inactive invocation continuations per scope | 64 |
| nested transaction savepoints per proof | 32 |
| answers per invocation | existing 10,000 |
| complete proof / idle scope lifetime | existing configurable 60,000 ms |
| one actively deriving step | existing configurable 30,000 ms |
| one transport frame | existing 1 MiB |
| one encoded nested goal / one answer | 8 KiB / 64 KiB |
| one session command/reply envelope | 128 KiB |
| one failure reason / complete reason stack / boundaries | existing 4 KiB / 32 KiB / 256 |
| one scope invocation transcript | 12 KiB |
| one signed local-plan envelope | 24 KiB |
| top-level goal bytes / durable selected-result bytes | 8 KiB / 16 KiB |
| complete Begin manifest, plans, goal and result | 224 KiB |
| one Begin/Prepare/Decision/Finalize record and singleton block | existing 256 KiB |
| diff operations or read-set functors in one local plan | 1,024 each, also subject to the 24 KiB plan cap |
| unresolved distributed groups per ontology | 1 (namespace-exclusive first slice) |
| terminal group entries retained in memory | 4,096 |
| concurrent foreign-history pulls / entries per page / response bytes | existing 32 / 256 / 900 KiB |
| pending foreign verifications global / per authenticated peer | 32 / 4 |
| cached foreign ontology histories / total cache bytes | 64 / 128 MiB |
| validators in one committee | 64 |

The same constants are used by schema, producer, decoder, validator, replay,
and tests; there are no duplicated magic values. A potentially writable goal is
charged to its transcript/plan budget before it runs, so a valid invocation
cannot succeed and only then discover that its own goal was intrinsically
unsealable.

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
This deliberately simple pre-Begin rule avoids retaining descendant C writes
when B disappears before A acknowledges B's result. `send_reliable` queue
acceptance is never treated as proof-state acceptance, and there is no hidden
automatic retry or re-proof.

Authorization denial is likewise fatal for that `ProofId`, rather than a
backtrackable predicate failure. Otherwise `(DeniedGoal ; AllowedGoal)` and its
timing/failure stack would become a policy-probing primitive, and writes staged
before a nested denial could survive into another alternative.

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
| `{fail, Reasons}` | ordinary logical exhaustion; includes bounded nested reasons |
| `{error, {erlog, SafeError}}` | bounded Erlog exception, re-raised at the immediate caller with local/co-hosted/remote parity |
| `{error, {not_allowed, Target}}` | target `can_invoke/4` denied before running the goal; the proof is poisoned |
| `{error, {bad_name, Term}}` | ontology selector is invalid |
| `{error, {unknown_ontology, Ns}}` | directory has never learned the ontology |
| `{error, {anchor_conflict, Ns}}` | routes disagree on genesis identity |
| `{error, {ontology_unreachable, Ns}}` | no pinned current-validator route succeeds |
| `{error, {ontology_busy, Ns}}` | target admission quota is full |
| `{error, {ontology_rate_limited, Ns}}` | authenticated scope-open rate exceeded before execution |
| `{error, {ontology_rebuilding, Ns}}` | target is not ready to open a scope |
| `{error, {proof_limit_exceeded, Ns}}` | active derivation exceeded its budget |
| `{error, {scope_expired, Ns}}` | the bounded session expired while idle |
| `{error, {proof_depth_exceeded, Max}}` | active cross-scope invocation depth is exhausted |
| `{error, {scope_limit_exceeded, Max}}` | distinct-scope limit is exhausted |
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
{absent, LastMutationSlot} | static`. The store retains a tombstone version, so
absent -> present -> absent is still a conflict. Prepare requires exact equality
at its parent. This is a deliberate transaction-format break and a conservative
conflict is acceptable if a functor changed and later returned to identical
content.

Ordinary batches remain safe with slot-granular versions: producer and validator
split/reject a batch when a later transaction's read set intersects an earlier
transaction's write set. Such a transaction is proposed in the next block and
checks the published parent version. Multiple blind writes may remain ordered in
one batch. A singleton Prepare already has no same-block predecessor.

Every hard-break ordinary transaction, control record, and local-plan signature
binds the exact `{Namespace, GenesisAnchor, ConsensusIncarnation, CommitteeId}`
at authoring. Ordinary transactions and ledger control records use the normal
author sequence; its high-water is keyed to that committee identity and retains
at most the capped current committee's 64 authors. A local plan is a witness
inside Begin, not a second ledger submission: its distinct signature domain
binds `ProofId` and the complete coordination manifest digest and consumes no
ordinary author sequence. Replay validates historical blocks while folding
their historical committee, then discards the old live sequence map at
adoption. Re-admitting the same key under a later committee id cannot replay its
older-domain transactions or plan witnesses. Admission rejects a 65th validator
before Prolog/consensus mutation, bounding certificates and foreign projections.

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
transcript contains, in execution order, every accepted invocation's id,
semantic call chain, authenticated principal/subject representation, and goal
bytes; each accepted answer contributes its sequence and solution digest, while
logical exhaustion contributes only a fixed completion tag. Failure-reason
payloads remain volatile and never enter a plan or ledger. The final overlay
revision accompanies the ordered event transcript. The
signed plan and Begin carry these bounded bytes, not only a digest, so every
participant validator can deterministically re-prove `can_invoke/4`. The target
signature binds the transcript bytes and digest, `ProofId`, origin identity,
base, read check, and diff. For a distributed proof the final signature also
binds the complete manifest digest described below. Session expiry remains
volatile and is not part of a consensus validity decision. No fictional user
subject is encoded while the engine context still has no authenticated user;
the current target-validator/node principal is explicit.

All scopes whose reads influenced a writing proof participate, including a
scope with an empty local diff. Otherwise a premise in B could change while A
and C commit. If every diff is empty, the proof returns directly from its pinned
views and creates no ledger entry or ordinary OCC pass, matching today's local
frozen-read semantics. It still resolves the accumulated DTX visibility
fence: every normal selected scope must remain certified-current at return; an
unresolved namespace lock or stale DTX generation returns
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
Extract one target-owned `quod_prolog:submit_plan/2` primitive from
`submit_write/8`. It validates the sealed local plan, builds the unsigned
ordinary envelope, submits it from the target engine, and owns the parked/result
state until apply. Both an ordinary local proof and a sole-foreign material
scope call that primitive. Delete the old caller-engine `submit_write/8` shape
and its `CallerNs =:= Ns` guard so no second foreign submission path or proxy-
authored transaction survives.

For a distributed proof, the origin first reserves and persists its exact next
Begin author sequence plus a fresh 32-byte coordination nonce. It then builds
the canonical manifest from the sorted unsigned local-plan body digests,
the exact origin record identity
`{OriginNs, OriginAnchor, OriginIncarnation, OriginCommitteeId, OriginAuthor,
OriginAuthorSeq}`, the coordination nonce, bounded canonical top-level
goal/result bytes and digests, explicit principal/subject form and `ProofId`.
Every target signs its
own complete plan body **and that full manifest digest**. Finally the origin
signs and submits Begin using the reserved sequence. An abandoned reservation
may leave a harmless sequence gap but is never reused. This separate ordering
means an origin that is also a participant does not make its own plan stale by
signing Begin. Persisting the result bytes lets `outcome(OutcomeRef)` recover the
exact selected bindings after caller death; re-proving remains forbidden.

## 7. Atomic multi-ontology commit

Independent appends are forbidden: one ontology could apply while another
detects an OCC conflict. Use the existing per-ontology Simplex logs in an
origin-led BFT two-phase protocol. The origin is only the durable coordinator;
it has no privileged Prolog semantics.

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
```

This is a deliberate ledger and signature-format break. There is no old-format
decoder or migration path.

Make the break fail-fast at storage and every wire/signature boundary: bump the
ledger frame magic to V3 and explicitly reject V1/V2 before replay; bump the
ordinary transaction, Simplex payload/vote, directory record, scope-session,
and DTX control domains; reject every older tag rather than trying to decode it.
The release requires a fresh genesis and the documented `/quod/data` wipe. No
dual decoder, migration scanner, or compatibility flag remains.

### 7.1 Begin

The origin ontology commits one singleton barrier containing the exact manifest
and all target-signed local plan envelopes needed for recovery. This prevents a
coordinator from changing participants or plans after any participant prepares.
`GroupId` is the domain-separated SHA-256 hash of the canonical **unsigned**
Begin body; signatures are an outer envelope and never make the identity
self-referential. The body includes `ProofId`, the reserved origin
author/sequence, coordination nonce, complete manifest, every manifest-bound
target signature, and bounded goal/result. A target plan cannot move
to a different manifest or coordination identity: changing the origin record
identity or nonce changes the digest every target must sign. Replaying the exact
Begin yields the same `GroupId` and is idempotent. Origin author-sequence
high-water rejects a different Begin at the reserved identity, so no unbounded
used-plan-id index is introduced.
Once Begin commits, recovery is governed by durable group state and the
certified origin Decision, never a volatile session clock.

### 7.2 Prepare

Participants prepare in canonical ontology order. Each participant committee:

1. independently verifies the committed Begin witness from the origin's pinned
   genesis;
2. checks that its complete local plan matches the manifest;
3. validates the target signature, target author membership, every transcript
   `can_invoke/4` decision, structure, limits, membership rules, and local OCC
   read set against the exact parent state;
4. verifies that the ontology has no unresolved distributed group and acquires
   its one namespace-wide DTX lock;
5. commits a singleton Prepare containing the complete local plan and Begin
   reference;
6. atomically projects the durable namespace lock from that committed Prepare and keeps
   the diff hidden and unapplied.

A control barrier first seals the current ordinary batch and forbids a
pipelined child over an uncommitted Prepare. After Prepare is committed, the
namespace lock must be projected into both Simplex admission and `quod_prolog`
and acknowledged before the next proposal is allowed. Until unlock, **all**
ordinary content and membership payloads are refused/parked; only matching DTX
control records proceed. The same gate is enforced in append collection,
retained custody/relay re-drive, proposal validation, committed replay, and
catch-up, so no ingress route or Byzantine proposal can bypass it.

Every scope open, overlay read/mutation, and final return checks the current
namespace lock/generation even when its snapshot predates Prepare. Prepare
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
  every manifest participant;
- `abort` is always safe while no Decision exists; a prepare refusal or caller
  cancellation is only a request to the origin committee, never a claimed
  outcome. No wall-clock or ledger-time deadline competes with a valid commit;
  the first origin-consensus Decision wins.

Every origin validator independently verifies the referenced foreign history
before voting. Origin ledger order and BFT quorum intersection prevent commit
and abort decisions for the same group from both becoming valid.

### 7.4 Finalize

Each participant independently verifies the origin Decision witness and commits
one matching singleton Finalize:

- commit durably records the already prepared outcome and the certified origin
  Decision witness needed to reproduce it from this participant's own ledger;
- abort discards the hidden diff and unlocks the unchanged state.

OCC is not repeated at Finalize: Prepare validated it and the namespace lock
prevented intervening changes. Once this participant's Finalize(commit) is
committed, one `quod_prolog` mailbox turn applies the hidden diff, publishes the
MVCC version, advances the namespace DTX generation, marks
`finalize_applied_slot`, and removes the lock. A Finalize QC proves only
`finalize_committed_slot`; success still requires an authenticated applied
acknowledgment from every participant. No off-ledger all-Finalize certificate
set controls local visibility: the certified Decision already proves that every
Prepare exists, and Prepare + Decision + this local Finalize are sufficient for
deterministic replay without foreign network access.

Participants may finish that final mailbox turn at different instants. A
finished participant can serve new state, while every unfinished participant
is still namespace-locked and returns `transaction_pending`; any old scope also
fails its generation fence. Consequently one normal distributed proof sees all
old, all new, or a typed retry, never a new/old mixture. Explicit observer-backed
`prove_ro` retains Quod's documented stale-read semantics and is not presented
as a certified-current distributed snapshot.

Initial decision/finalize messages may follow the A -> B -> C call tree, as the
proof did. Correctness and recovery use the flat certified manifest, so an
unavailable intermediate cannot strand its children permanently.

The caller reports success only after every participant Finalize is committed
and applied, returning bindings plus per-ontology slots. A committed Decision
followed by incomplete notification is `outcome_unknown`, never failure.

## 8. Foreign finality verification

Directory routes remain routing hints. They never prove that another ontology
prepared or decided.

Break the directory record cleanly so every hosted namespace carries its
32-byte genesis anchor. System authorization is exact over
`{Namespace, GenesisAnchor, NodeKey}`. A private direct seed is configured as
`{Namespace, GenesisAnchor, Endpoint}`. Two valid routes claiming different
anchors for one namespace cause `anchor_conflict`; neither is selected. A route
update cannot change an already pinned direct-seed anchor. The namespace->anchor
pin/conflict high-water survives route expiry and service restart; switching a
namespace to another genesis requires an explicit operator reset and cannot
happen because stale routes aged out.

Replace the namespace-only public projection with
`directory_host(Namespace, GenesisAnchor, NodeKey, Host, Port)`; remove the old
`/4` form. For a writable scope, the resolver verifies the anchored ontology's
current committee projection and accepts only a route whose `NodeKey` is a
current validator at the pinned base/committee id. A directory entry remains
only an endpoint hint. Observer routes may serve explicit `prove_ro`, but are
skipped for a potentially writable proof; exhaustion returns
`ontology_unreachable`. A membership change invalidates the session or causes
Prepare to abort under the namespace membership lock.

Add one bounded, read-only foreign-ledger verifier/cache. It reuses the existing
catch-up page format, server bounds, and certificate-validation core, but not
`quod_catchup:pull/4`: that client assumes a local per-namespace process and its
pending map is not the required bounded foreign-history owner. For a foreign witness
it:

1. starts from the exact pinned genesis;
2. pulls bounded pages through the existing catch-up service;
3. reuses `quod_catchup`/`quod_simplex` certificate verification;
4. threads the same committee, committee-id, author-sequence, timestamp, and
   distributed-group phase projection checked by local boot;
5. accepts only the referenced exact slot, block hash, and record digest.

Foreign verification runs asynchronously before a validator votes, like the
existing membership-verdict path; no network call occurs inside a pure verdict.
Unavailable history causes abstain/retry, never acceptance. A verified
`{Namespace, GenesisAnchor}` projection is cached and persisted atomically; a
missing or corrupt cache restarts from anchored slot 1. Cache eviction affects
performance only, not correctness.

The verifier owns one globally/per-peer bounded pending map; it rejects before
spawning or allocating when the table limits are reached. Fix the shared
catch-up page byte cap so an individually oversized first entry is rejected
rather than retained above the 900 KiB response limit. The 64-validator cap and
committee-scoped author sequence projection keep certificates/history folds
inside the declared bounds.

After a local committee commits a control record, local replay and catch-up
verify that local record and its local finality certificate exactly as they do
ordinary committed history. They do not need the foreign network during boot:
the local quorum certificate attests that the live validators completed the
foreign check before voting.

## 9. Durable state and recovery

Add one `quod_outcome` rebuildable per-namespace disk-backed outcome index for
ordinary transactions and distributed groups, owned as state by the existing
namespace `quod_prolog` process rather than a new service. It keeps only active
groups and a bounded terminal LRU in memory. Quod has no transaction index
today: the explorer's
bounded 5,000-slot backward scan is not an outcome contract and is replaced,
not described as reusable infrastructure. Ledger replay populates the index
with ordinary transaction id/slot/result entries and the exact group phase,
manifest digest, local plan, locks, record slots, bounded top-level goal/result
envelope, and certified outcome. The ledger remains the source of truth;
corruption or disagreement fails boot rather than guessing.

One public `outcome(OutcomeRef)` API covers both forms. The reference is either
`{transaction, Namespace, GenesisAnchor, TxId}` or
`{group, OriginNamespace, OriginAnchor, GroupId}`. It therefore routes to and
pins the ledger that owns the authoritative result instead of assuming ids are
globally unique or local. A group resolves to
`pending(Phase) | {committed, Bindings, ParticipantSlots} |
{aborted, Reason}`; an ordinary transaction resolves through the same index and
the existing exact-submission pending state. A terminal result comes only from
certified ledger state and returns the exact persisted bounded bindings—never a
re-proof. Explorer and the HTTP status endpoint are thin views of this same API,
not separate scans or caches.

Phase transitions are monotonic and idempotent:

```text
origin:      none -> begun -> decided_commit | decided_abort
participant: none -> prepared -> finalized_commit -> applied_commit
                             -> finalized_abort
```

Exact duplicate signed frames return the existing witness. A different digest,
phase reversal, second decision, reused Begin identity, or finalize without the
matching Prepare is rejected before state or lock mutation.

Idempotency is keyed semantically as
`{GroupId, OntologyIdentity, Phase}`, independently of the validator that
redrives it. Before a phase commits, equivalent envelopes from different
current recovery signers may compete through normal consensus; the first valid
committed envelope wins. After commit, its exact record digest is canonical and
all different envelopes are rejected. Each control record has its own explicit
author/sequence/signature fields and domain, so “any current validator may
redrive” never means reusing another validator's signature or sequence.

Recovery rules are complete:

- before Begin, caller/worker death closes volatile scopes and nothing durable
  exists;
- Begin without Decision is redriven by any current origin validator: obtain
  participant status, continue canonical prepares, then decide commit or abort;
- Prepare without Finalize restores its hidden plan and locks during replay,
  fetches the origin decision, and finalizes accordingly;
- Decision redrives every missing participant Finalize;
- committed Finalize without `applied_commit` retains the namespace lock,
  verifies its ledger-carried Decision witness, then performs the one mailbox
  apply/publish/unlock transition and returns the applied witness;
- all-Prepare plus no Decision can only become an origin-certified commit or
  abort according to the next ordered Decision; nobody infers an outcome from a
  timeout;
- a partition may hold prepared predicates unavailable until the origin quorum
  recovers. It cannot expose a partial result or permit a local unilateral
  abort.

The liveness claim is exactly Simplex's existing fault model: at most `f`
Byzantine/crashed members in each `3f+1` committee, eventual synchrony, durable
disks, and at least one surviving holder of every certified block needed for
recovery. A temporary or permanent loss beyond that bound may leave a prepared
group safely blocked; this plan does not promise recovery that the underlying
consensus cannot provide.

Reactions and runtime events fire once for the live post-Finalize mailbox
application that actually changes D. Begin, Prepare, Decision, a merely
committed Finalize, abort, replay, and duplicate completion evidence generate no
domain reaction.

The exact live envelope is
`{applied_live, Ns, Height, {group, GroupId}, ProofId, OriginIdentity,
PrincipalOrSubject, TopGoal, TopResult, LocalPlanDigest, Diff}`. The bounded
goal/result are the same canonical values persisted by Begin, not a re-proof or
digest-only substitute. It is emitted in that ontology's committed Finalize
order after D and its MVCC publication are applied. `quod_runtime` then
completes P before scheduling any E reaction; an empty local diff emits no
domain reaction. The caller's top-level success still waits for all participant
Finalizes. Replay reconstructs D/P/group state but emits no E, matching the
existing runtime contract. Ordinary one-ontology transactions keep the
analogous `{transaction, TxId}` identity under the hard-break event union.

## 10. Code boundaries

Keep the change factored rather than adding phase exceptions throughout
`quod_simplex`:

- `quod_erlog_db_local_prove`: exact overlay checkpoint/replace,
  savepoint/restore, read-only-frame, and OCC-token APIs only; it remains a
  database adapter and does not learn distributed lock policy;
- `quod_diff`: expose the tiny pure assertion-only/asserted-functor checks reused
  by runtime creation and V3 genesis validation, plus the post-diff interpreted-
  functor presence check used by ordinary apply and distributed Prepare; no
  policy module or duplicate term scanner;
- `quod_proof_scope`: the one shared origin/selected proof worker, invocation
  continuations, namespace-lock/generation fencing against the engine's
  committed projection, overlay generations, sealing, limits, and cleanup;
- `quod_ask`: only the compiled `::` predicate, caller-side choice-point
  streaming, variable grafting/failure merge, scope wire codec, and transport
  calls into the router; remove its separate answer proof loop, old ask wire
  decoders, and `watch_owner`/`stop_owner` cleanup path;
- `quod_ask_router`: become the sole bounded scope-frame correlation/proxy and
  cleanup registry, with a monotonic `ProofId` touched-scope ownership set;
- `quod_prolog`: admit the shared workers, retain bounded scope sessions and
  MVCC pins, own the per-namespace `quod_outcome` state, expose the one
  target-owned `submit_plan/2` plus the public anchored `outcome/1`, and hand
  sealed plans to commit coordination;
- `quod_ontology`: require the compiled policy only on a genuinely fresh create
  and map omission to the bounded lifecycle failure; its prepared descriptor
  passes the already-compiled `InitialDiff` to namespace start, rejects its
  deterministic encoding above the shared 192 KiB limit before manager/storage
  mutation, while resume keeps its existing ignored-options contract;
- `quod_transaction`: keep canonical ordinary transaction encoding/signing
  input only;
- `quod_dtx`: own the distinct Begin/Prepare/Decision/Finalize domains and
  encodings, manifest hashing, pure phase validation, lock projection,
  coordinator/participant recovery commands, and finalize application; it uses
  the one `quod_outcome` state and creates no second group-status index;
- `quod_outcome`: implement the unified ordinary/group disk index, ledger
  rebuild fold, bounded active/terminal views, and exact outcome lookup; it has
  no process separate from the owning namespace engine;
- `quod_ledger_store`: use V3 frame magic, reject V1/V2 explicitly, and provide
  the ordered replay stream from which `quod_outcome` rebuilds;
- `quod_foreign_log`: bounded anchored foreign-history verification and cache;
- `quod_simplex`: accept the explicit record union, singleton control barriers,
  asynchronous validation hooks, mutually exclusive bounded `genesis_diff`
  input for prepared runtime creation, linear generated/source diff assembly,
  and the V3 assertion-only/policy-present genesis invariant, with no other
  protocol policy beyond validation results;
- `quod_directory`: exact anchor-carrying routes and conflict rejection;
- explorer/feed/runtime: group records and Finalize-only applied events.

Reuse the current ask router, QUIC identity pinning, safe term codec, answer
backpressure, worker monitors, overlays, OCC validation plumbing, exact-slot ingress,
retained relay submission, Simplex certificates, catch-up paging, and
`outcome_unknown` contract.

Delete, rather than retain:

- `foreign_write_unsupported` and its error allowlists;
- the `CallerNs =:= TargetNs` write gate and caller-supplied `CallerNs` API field;
- served-ask `read_set => false`;
- target-side `start_answer*`, `answer_init`, `answer_loop`, `step`, and `drive`;
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

The work may be reviewed in internal deltas, but no partial semantic mode is
deployed:

1. correct `action/3` and add semidet `transaction/1` with local
   assertion/retraction/abolish, alternative, cut, nested-transaction, error,
   and failure-reason tests;
2. add the shared proof-scope worker and proof context, recursive co-hosted
   scopes, repeated-target
   state, and A -> B -> C tests;
3. extend the same path over QUIC, including validator routing, bounds,
   timeouts, session/origin-binding tamper tests, and zero-leak cleanup;
4. land explicit distributed records, the namespace-exclusive lock, the
   ledger-rebuilt outcome index, anchored foreign verifier,
   Begin/Prepare/Decision/Finalize, and recovery;
5. remove the old paths and update all normative documentation;
6. run every focused and full gate, re-found because of the deliberate format
   break, deploy, execute the failure/crash matrix, then load-test chained
   ontology writes.

Each internal delta must compile and have its focused tests, but the feature is
enabled only when step 6 proves the complete contract.

## 13. Acceptance tests

At minimum:

1. Three genuinely distinct committees/nodes: A writes, calls B which writes
   and calls C which retracts; one proof returns only after all three
   Finalize certificates and applied acknowledgements.
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
   prepared peer finalizes abort and no ontology exposes a diff. Once any
   Prepare lock is committed, even a disjoint ordinary change returns
   `transaction_pending` until the group resolves.
9. A read-only participant whose premise controls another ontology's write is
   included and conflicts correctly.
10. An abort Decision leaves both namespaces old. Under a commit Decision,
    pause after B's Finalize is committed and applied while C remains locked:
    B serves new state, but any normal proof that also selects C returns
    `transaction_pending` and can never succeed with B-new/C-old. C's own
    committed Finalize then applies/unlocks C; all applied acknowledgements let
    the caller return both new.
11. Kill the origin and each participant before Begin, after Begin, after each
    Prepare, after Decision, and after one Finalize. Recovery reaches exactly
    one outcome, exact once, and releases every lock under the stated `<= f`,
    eventual-synchrony, durable-disk, surviving-holder fault model.
12. Partition after Prepare and after Decision. The former stays safely
    unavailable until a decision; the latter returns
    `outcome_unknown(OutcomeRef)`
    and eventually finalizes commit without re-proving.
13. Tamper each session id, `ProofId`/origin binding, invocation sequence, plan, manifest,
    subject/chain, namespace, anchor, phase,
    record digest, author sequence, block, and certificate. Use an observer, a
    wrong TLS key, and a removed old committee. Every case fails before voting
    or lock mutation. Reuse otherwise valid target plan/signatures under a
    second origin author sequence or coordination nonce; manifest validation
    rejects both before lock mutation.
14. Two valid routes advertise one namespace under different anchors; resolution
    returns `anchor_conflict`, opens no scope, and changes no route high-water.
    A direct seed cannot change its pinned anchor.
15. Duplicate and reordered frames are idempotent; commit/abort reversal,
    finalize without Prepare, and GroupId reuse are rejected.
16. Restart and fresh catch-up reconstruct exact active namespace locks, hidden plans,
    facts, committee projection, group status, and terminal index. Replay emits
    no reactions; live post-Finalize apply emits one.
17. Membership-changing distributed plans preserve the old-committee validation
    boundary and change membership only on commit Finalize.
18. Every wire/admission size/count limit rejects before decode, spawn, or map
    insertion; incrementally generated state rejects before ledger mutation or
    lock acquisition and remains under the worker heap cap. Cancellation leaves
    no worker, session, pin, ETS table, router entry, or timer.
19. Explorer groups every physical record under one `GroupId`, never labels
    Prepare as applied, and shows pending/committed/aborted/outcome-unknown
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
    remote entry. Denial runs none of Goal and poisons the proof; an invented
    chain/principal and the removed `CallerNs` API cannot bypass it. A migrated
    restrictive policy explicitly checks every chain member and denies if any
    one is unauthorized; `(Denied ; Allowed)` never executes `Allowed`.
24. A sole foreign material scope uses one target-authored ordinary transaction,
    returns `{transaction, TargetNs, TargetAnchor, TxId}`, and recovers exact
    bindings through `outcome(OutcomeRef)` after caller death. Two material
    scopes return `{group, OriginNs, OriginAnchor, GroupId}` and exact persisted
    bindings through the same API.
25. OCC detects absent -> present -> absent through its tombstone version; a
    batch whose later read intersects an earlier write is split/rejected, while
    blind writes remain ordered.
26. V1/V2 ledger magic and every old transaction/directory/session/control
    domain fail explicitly before replay/decode; only a fresh V3 genesis starts.
    V3 genesis validation rejects policy omission, any non-assert operation,
    and assert-then-retract attempts.
27. While Prepare is locked, direct append, batch collection, retained custody,
    relay re-drive, proposal validation, replay, and catch-up all refuse ordinary
    content; no ingress path commits a bypass.
28. A target mutates its volatile overlay and then loses transport before its
    parent accepts a result. The whole pre-Begin `ProofId` is poisoned and every
    scope/overlay/session/router entry is reclaimed.
29. Variable, non-callable, improper-list, and empty-list action shapes—including
    invalid `DesiredState`—fail before any candidate goal or transition runs.
30. Router, verifier, committee, frame, answer, incremental diff/read/transcript,
    plan, worker-heap, and aggregate group caps are exercised at boundary and
    boundary+1; an exponentially generated Prolog term dies as
    `proof_limit_exceeded`, and an individually oversized first catch-up entry
    is never emitted above the page byte cap. Scope-open flooding is capped per
    authenticated peer/ontology before goal decode or worker allocation, and
    rejection replies remain globally bounded. Rotating more than 1,024 valid
    peer/ontology keys cannot grow the token-bucket table; full admission fails
    closed and idle expiry reclaims entries. An over-rate frame's bounded
    `GoalBlob` is never decoded as a Prolog term.
31. Two namespaces deliberately reuse the same `TxId`; their anchored
    `OutcomeRef`s resolve independently. A committed result older than the old
    explorer's 5,000-slot scan budget still resolves after restart from the
    rebuilt outcome index, including a sole-foreign result reached through a
    pinned route.
32. Fresh runtime creation without a staged `can_invoke/4` clause returns
    `ontology_creation_failed(missing_can_invoke_policy)` with no desired entry,
    namespace directory, or ledger. An explicit restrictive rule creates a
    private ontology successfully. Resume accepts valid replacement options
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
