# Ontology subscriptions and certified event following — plan

**Status:** Slices 1 (vocabulary and local reconciliation) and 2 (shared
continuous certified follow) are reviewed, committed, and deployed through
release 0.7.80. Slice 2's mixed-DTX plus 64-follow hardware acceptance run is
still pending. Slices 3--6 remain planning only. Neither implemented slice changes a ledger,
transaction, certificate, DTX, genesis, or wire format.

This document is the authority for long-lived ontology-to-ontology
subscriptions. `inter-ontology.md` remains the authority for proved `::`
scopes and distributed transactions. A subscription does not change those
semantics.

Actor identity and hosting are governed by
`ontology-actor-architecture.md`: an agent is a classed instance in an exact
containing ontology and its optional Erlang process is a rebuildable
projection. An Agent Platform is another ontology that may coordinate
subscriptions; it is not a substitute identity or mandatory container for its
agents.

The design deliberately reuses the three owners already closest to the work:

- `quod_feed` is the hosted target's per-namespace dissemination endpoint;
- `quod_foreign_log` is the node-wide certified foreign-history verifier and
  cache;
- `quod_runtime` owns rebuildable projections and the existing P-before-E
  `state_handler` tier.

There is no second verifier, event bus, ACL, proof controller, directory, or
transaction executor.

## 1. Purpose

An ontology may declare a durable relationship with another ontology. For
example, a body ontology can subscribe to an arm, an arm to a hand, or an Agent
Platform to an avatar.

The declaration survives restart because it is one ordinary fact in the
subscriber's ledger. The relationship keeps the exact target identity
discoverable and continuously followed. It does not name a predicate and it
does not grant access to one.

Event interest is a separate, existing Prolog concept. Source-qualified
`react_on/3` declarations say which target changes matter and what the
subscriber does after receiving them. The subscriber compiles its requested
interests; the target authorizes them and installs a temporary delivery filter,
so it need not send events that no rule in the subscriber wants. The target's
ordinary `can_invoke/4` policy remains the only authority over which patterns
may be registered or delivered.

Subscriptions are explicit. Reading a foreign fact is not a subscription and
has no lasting notification side effect. The normal OCC read set remains only
the proof's dependency record.

### 1.1 Existing pieces and reference lessons

Quod already has the local `applied_live` boundary, the ordered
`state_handler/4` P tier, `quod_feed`, certified one-shot
`quod_foreign_log`, directory/private-seed resolution, and ordinary
`can_invoke/4` scope authorization. Slice 1 recognizes exact ordinary
`subscribes/2` facts and founding-authorized source-qualified `react_on/3`
facts during the existing runtime reconciliation. Slice 2 follows the exact
anchored ontology into local certified P. It does **not** yet register remote
event interests, deliver events, or execute
`react_on/3`. Those are later roadmap slices, not hidden as-built claims.

BBSvx validates the useful conceptual split: `subscribed_to(SourceNs)` names
an ontology relationship, while its historical
`react_on(SourceNs, Pattern, Handler)` selects and handles source events.
BBSvx's argument order differs from Quod's
`react_on(Executor, Pattern, EffectGoal)`: Quod keeps the source inside
`Pattern` and reserves the first argument for the unique logical effect owner.
Its separate `subscribe_event/1` action only stores
an otherwise unused fact and is deliberately not carried forward. Onia's later
D/P/E model also keeps `state_handler` convergence separate from live-only
`react_on` effects and identifies reactions over `fipa_envelope/6` as the future
FIPA handler path. Quod reuses these semantics through its existing owners; it
does not port their runtime machinery.

## 2. Fixed boundaries

### 2.1 One durable fact, owned by the subscriber

The conceptual relation is:

```prolog
subscribes(TargetNamespace, TargetAnchor).
```

These two fields are load-bearing:

- `TargetNamespace` and `TargetAnchor` name one immutable ontology identity.

The fact contains no host, port, node key, QUIC channel, retry timer, event
pattern, or other route/delivery data. Removing the exact fact cancels the
durable relationship. Creating or removing it is an ordinary authorized Prolog
write and therefore produces an ordinary transaction in the subscriber's
ledger.

No matching durable row is written to the target. Ten thousand distinct
subscriptions are ten thousand visible, queryable facts rather than ten
thousand invisible consequences of previous reads. Runtime work must still be
shared and demand-driven; ten thousand facts must not imply ten thousand
processes or connections.

An ontology may expose convenience rules such as:

```prolog
subscribe(Target, Anchor) :-
    allowed_subscription(Target, Anchor),
    assertz(subscribes(Target, Anchor)).

unsubscribe(Target, Anchor) :-
    retract(subscribes(Target, Anchor)).
```

These are ordinary ontology rules, not special Erlang goal dispatch. The
subscriber's normal `can_invoke/4` policy decides who may execute them.
They are illustrative application rules, not dormant vocabulary to install in
a system ontology before an ontology actually needs them.

### 2.2 Subscription, hosting, routing, and proof scopes are separate

- Root-owned `create_ontology` introduces an identity and makes the transaction
  author its first host. Node-owned `join_ontology` adds a host for an existing
  identity. A future non-destructive `leave_ontology` belongs to the hosting
  lifecycle family.
- The directory and private seeds describe current reachability. Routes are
  local P-state and may expire or change without a transaction.
- A subscription records durable semantic interest. It neither hosts the
  target nor grants access to it.
- `::` opens a bounded proof scope. Public `::` needs no subscription, and a
  subscription is not kept as a proof scope.

The current origin-controller invariant is unchanged: for A -> B -> C within
one top-level proof, A owns the scope selection and DTX coordination. A
subscription from B to C creates a separate host-to-host following relation; it
does not let B become a second proof controller and does not alter how A opens
C during that proof.

### 2.3 One authorization path

The target's existing `can_invoke/4` policy authorizes runtime registration.
The registration request is evaluated on a current committed target snapshot
with:

- the authenticated requesting host principal;
- the exact anchored subscriber-ontology identity;
- certified evidence that the requested `subscribes/2` fact is currently
  present in that subscriber ontology;
- the bounded event-interest patterns derived from the subscriber's active
  source-qualified `react_on/3` declarations;
- the ordinary engine-owned call chain;
- the exact target identity.

The requesting host cannot establish authority merely by claiming it hosts the
subscriber ontology. It supplies a certified subscriber-ledger position and
subscription binding. It also supplies certified current bindings for the
active `react_on/3` declarations from which its requested patterns were
compiled; a host cannot invent a broader interest list. The target verifies
that evidence through the same node-wide `quod_foreign_log` owner and accepts
the request only from a current eligible host of that subscriber identity. The
authenticated node remains the existing `{node, Key}` principal; the subscriber
ontology and requested event pattern are bounded arguments/chain context for
`can_invoke/4`, not a new principal type.

Registrations expire unless renewed against a fresh certified subscriber
position at which the exact subscription and reaction facts still exist. A
retraction therefore stops renewal even if the subscriber crashes before
sending an explicit unregister. The target retains only this verified
registration in P; it does not copy the subscription or reactions into its
ledger.

The implementation must factor or call the existing local authorization
helper used by scope admission. It must not copy `can_invoke/4` interpretation
into the feed or subscription codec.

Authorization is checked when a registration is established, whenever it is
re-established after failure/replay, and after a certified target committee
change. A subscriber committee change also invalidates the old host binding and
requires fresh evidence. A previous grant is not a durable capability.
Revocation stops future delivery; it cannot make a peer forget information it
was already allowed to receive.

### 2.4 Event interest and reaction are one declaration

Quod already reserves this durable reaction shape:

```prolog
react_on(Executor, Pattern, EffectGoal).
```

`Executor` is not the event source and is not restricted to agents. It is an
ontology-defined logical owner such as `agent(A)`, `service(S)`, or
`node(NodeKey)`, used later to select the one host allowed to run the live
effect. Its variables must be bound by `Pattern`; a bare anonymous executor
cannot select one host and is invalid. The remote source remains the anchored
identity inside `from/3`. A local event has no `from/3` wrapper.

The ontology-subscription extension keeps `/3` and makes a remote event source
part of `Pattern`. One illustrative shape is:

```prolog
react_on(agent(Agent),
         from(TargetNamespace, TargetAnchor, assert(FactPattern)),
         EffectGoal).
```

The exact bounded source wrapper is frozen with the reaction slice; it does not
create `react_on/4` or another event-handler predicate.

A `react_on/3` fact is active only if it passes the declaration-authority rule
in `agent-fipa-plan.md` section 8.1. Until validator-side
`can_declare_runtime(Subject, reaction, Declaration)` authorization lands,
only declarations pinned in a trusted system ontology's founding genesis are
active; dynamically committed declarations remain inert. Ordinary permission
to write a fact is deliberately not permission to execute runtime content.

This one declaration serves both ends:

1. the subscriber compiles the union of its active source-qualified patterns
   and registers that interest with the target;
2. the target authorizes each pattern through its existing `can_invoke/4`
   path and keeps a rebuildable pattern index;
3. the target sends only committed events matching at least one accepted
   pattern;
4. the subscriber matches the received event against its own `react_on/3`
   declarations again, binds variables, resolves the executor, and schedules
   the live effect.

The source-side match saves bandwidth. The subscriber-side match remains the
semantic authority for choosing a reaction. There is no durable
`filter_events` row at the target and no second list of patterns to drift from
`react_on/3`.

Both matches cross the Erlang/Prolog boundary through
`erlog_int:unify_prove_body`. Erlang may validate the envelope and narrow the
candidate set by anchored source and functor, but it must not compare Prolog
terms itself or implement a second variable-binding algorithm. The target uses
`unify_prove_body` to decide whether an accepted interest matches the concrete
event. The subscriber uses it again to continue the selected `react_on/3` body
with the event's variable bindings installed. This is the same interpreter
interface used by Erlog built-ins when an external value becomes part of the
current proof.

Later reaction envelopes may expose additional trusted context, such as a
certified source identity or committed height, through explicit bounded pattern
terms. Erlang supplies the concrete term to the same `unify_prove_body` call so
the ordinary Prolog state receives the bindings. Quod does not create magic
variable names or a second binding map, and volatile endpoints never become
semantic event data.

For an `assert(FactPattern)` or `retract(FactPattern)` interest, the target
checks the underlying `FactPattern` through the same `can_invoke/4` path used
when that subscriber queries the predicate normally. The assert/retract tag
selects the event kind; it does not request permission to write the target.
This is not a new ACL or an event-specific policy table. Erlang validates
shapes and calls the existing authorization path; it does not interpret policy
or run arbitrary Prolog once per subscriber per event.

That existing authorization verdict is existential and discards any bindings
made while proving policy. For example, if policy can prove access to
`foo(bob)` by binding the variable in `foo(X)`, the accepted interest remains
the original broad `foo(X)` and all matching `foo/1` events may be delivered.
This is identical to current query authorization, not a new narrowing rule.
Policy authors must express any required restriction as a verdict on the
whole requested pattern; the subscription layer must not silently add binding
semantics that ordinary queries do not have.

`state_handler/4` remains distinct: it converges rebuildable P before any live
reaction. `react_on/3` is the E rule that runs afterward. Future FIPA
performatives use the same reaction path, for example by matching a committed
`fipa_envelope/6` assertion addressed to the hosted agent.

External predicates or runtime calls are bridges only. They may register or
cancel runtime interest, announce a newer source height, and read a local
certified snapshot. They do not authorize a caller, execute a client goal, or
manufacture facts.

### 2.5 Event filtering is not yet selective ledger confidentiality

The current catch-up server returns complete certified ledger entries to an
authenticated peer that can reach its namespace channel. `quod_foreign_log`
uses those pages today for DTX verification; there is no per-fact Merkle proof,
encrypted field scheme, or redacted block certificate.

Therefore source-side pattern filtering can control automatic event delivery
and save bandwidth, but it must not claim that an unselected fact is
cryptographically hidden from a peer that can already pull the target's raw
ledger. This is a pre-existing ledger-read boundary, not authority granted by
`subscribes/2`.

The initial facility is consequently scoped to targets whose certified ledger
is readable by their authenticated route peers. Selective confidential
delivery needs a separate reviewed design—such as committed projection
roots with inclusion proofs or encrypted content—and may require a format
change. It must not be approximated by trusting one target response or by
filtering a full ledger after disclosing it.

## 3. D/P/E classification

| Artifact | Class | Owner and lifetime |
|---|---|---|
| `subscribes/2` | D | Subscriber ledger; created/removed by ordinary transactions |
| source-qualified `react_on/3` | D | Subscriber ledger; the one durable event-interest and reaction declaration |
| target facts matched by an accepted event interest | D | Target ledger; never copied into subscriber D |
| current routes and private seeds | P | Existing node directory; local and rebuildable |
| compiled accepted event-pattern index | P | Target runtime; rebuilt from registrations and reauthorized |
| certified subscription-presence evidence | P | Target verification/cache; refreshed on registration renewal |
| active host-to-host registrations | P | Target feed and subscriber runtime; rebuilt by re-registration |
| certified foreign history/cache | P | Existing node-wide `quod_foreign_log`; disposable local cache |
| subscribed foreign fact projection | P | Subscriber host; rebuilt from certified target history and accepted interests |
| subscription cursor, epoch, queue, and dedup state | P | Runtime only |
| height/digest wake-up | E | Live freshness hint; never evidence |
| interest-triggered certified-page transport | E | Reliable ordered input to the existing certified follower; it changes P only after verification |
| `state_handler/4` convergence | P | Existing ordered runtime tier; completes before E |
| grounded `react_on/3` body | E | Existing planned live-reaction tier after P is current |
| durable change requested by a reaction | D | A new ordinary signed goal/transaction, never an event side effect |
| client cue or simulation frame | E | Existing lossy client/world path; outside ontology following |

The subscriber's P may expose a source-qualified local view such as:

```text
{SubscriptionKey, TargetIdentity, CertifiedHeight, ProjectedFacts}
```

It is not inserted into the subscriber's Prolog database and cannot be sealed
as if the subscriber owned those facts. A query bridge may read it explicitly
as foreign projected state. That bridge is a visibly distinct operation which
returns its exact `CertifiedHeight`; it is never consulted implicitly and can
never satisfy a `::` goal or substitute for an ordinary proof scope.

## 4. One certified following path

### 4.1 `quod_foreign_log` becomes continuous, not duplicated

`quod_foreign_log` already:

- pins `{Namespace, GenesisAnchor}`;
- pulls the catch-up page format over key-pinned routes;
- verifies certificates and committee transitions;
- folds history through the canonical history transition;
- keeps one lazy verified cache per foreign identity; dormant caches retain no
  decoded history, worker, or materialized projection in memory;
- derives a certified current view.

Subscription following extends that owner with long-lived interests and
height advancement. It must not add another history store or verifier.

One target identity is followed once per node. Multiple hosted subscriber
ontologies and event-interest patterns share its verified history, current
committee view, route hints, and pull worker. Interest-specific projections are
derived after certification. There is no process or QUIC connection per
durable fact.

The canonical D transition needed to materialize selected facts must be shared
with normal rebuild/apply code. If the current apply reducer is not reusable,
it is factored into one pure transition called by both paths; a second foreign
fact applier is forbidden.

### 4.2 Push feeds the one certified follower

A source push can announce a target identity, certified-view identifier,
height, and head digest. That wake-up is not authoritative by itself. If the
source pushes entry material, it uses the existing certified catch-up page
format—entries and their certificates—rather than a new candidate-delta
format. The page is handed directly to `quod_foreign_log` as push-fed
anti-entropy and becomes usable only after the same canonical verification and
ordered fold as a pulled page.

The subscriber advances only after `quod_foreign_log` has verified the
corresponding certified entries and folded them in exact order. A forged,
duplicated, stale, missing, or reordered push can at worst delay a refresh or
cause a redundant bounded pull.

`quod_feed` already emits authenticated height digests and uses eager push plus
certified anti-entropy. The implementation should factor and reuse its digest,
gap, and wake-up concepts where their identity contract matches. A subscription
does not pretend to be a target Simplex observer, ingest blocks into a second
ledger, or bypass `quod_foreign_log`.

The existing `{committed, Ns}` feed signal occurs before target Prolog/runtime
apply and is therefore too early to be a subscription event. It may wake
history verification, but a target pushes the corresponding certified page to
an interested subscriber only after the target's existing `applied_live` ->
P-handler barrier has completed. This preserves the rule that subscribers
never observe a half-applied target.

### 4.3 Target delivery ownership

`quod_feed` is already the hosted namespace's live dissemination owner and
observes committed entries. It is therefore the default owner for:

- the bounded table of active authorized registrations;
- coalesced newest-height wake-ups;
- certified catch-up pages pushed after a matching post-apply event;
- registration expiry and cleanup;
- source-side backpressure metrics.

For subscription delivery, `quod_runtime` hands the feed one already-ordered,
post-apply event descriptor after its P tier completes. The feed matches it
against the compiled accepted-interest index; it does not re-run
`react_on/3`, invoke handlers, or derive a second diff from the raw committed
block. Its existing commit-time block dissemination remains unchanged and
separately serves hosted followers.

Authorization work runs in a bounded monitored worker against the local target
engine. It does not block the feed server or consensus. The registration table
contains no durable truth; after a target-host restart, subscribers register
again.

Each node-wide target follower keeps one active transport registration with
one current target validator and multiplexes all compatible local logical
subscriptions over it. It does not register redundantly with every target
host. On failure, expiry, or committee change it certifies the current view and
selects one replacement host; source revision and registration epoch make late
messages from the old host harmless.

No new node-wide event-bus process is introduced. A small pure wire codec or
projection helper is acceptable; it owns no policy, cache, retry loop, or
network state.

## 5. Subscriber runtime and reactions

The subscriber's `quod_runtime` reconciles `subscribes/2` facts after boot,
replay, or a live subscription change. It asks the shared foreign-log owner to
follow each exact target identity, groups compatible local consumers, and
maintains source-qualified P rows. Separately, it compiles active
source-qualified `react_on/3` patterns into one bounded interest set per target
registration.

When a certified projection advances, it presents the affected source and
changed heads to the existing ordered handler tier, conceptually:

```text
{subscription_change,
 SubscriptionKey, TargetIdentity, FromHeight, ToHeight, ChangedHeads}
```

`state_handler/4` remains the only P-convergence scheduler. Subscription
changes must not create a second dependency graph, worker pool, or P-before-E
barrier. The handler scope distinguishes local D heads from foreign projected
heads so an equal Prolog term cannot be mistaken for locally owned state.

After P is current, the existing planned `react_on/3` machinery matches the
source-qualified live event locally and schedules the grounded E body. This
second match is deliberate: the target-side index is a bandwidth optimization,
while the subscriber's own committed rule decides which handler actually
runs. The match and continuation use `erlog_int:unify_prove_body`; an Erlang
term-equality shortcut would lose Prolog bindings and is forbidden.
`react_once` may later be expressed through the same reaction owner; it
must not create another transport registration path.

An already-live subscriber that repairs a delivery gap may collapse several
certified target entries into one newest projection change for P. It must not
pretend that this reconstruction is the missing historical E stream. A
subscriber that is booting or replaying only reconciles the current P snapshot
and schedules no historical reactions. Thus loss recovery restores current
state without turning restart into event replay.

A state handler may update rebuildable P. A `react_on/3` effect cannot stage D
directly merely because an event arrived. If durable truth must change, an
authorized agent or executor submits an ordinary signed goal. That goal follows
normal `can_invoke/4`, proof, OCC, DTX, outcome, and retry rules.

This rule permits useful cycles without event amplification. For example, Arm
may subscribe to Finger while Finger subscribes to Arm. Their respective
`react_on/3` rules select FingerPose and ArmFrame changes. Each side updates its
own projection and reacts only to its selected source-qualified events. It
never re-emits the input envelope unchanged and never turns delivery itself
into a write.

Every derived event identifies its immediate source and a stable root cause,
without carrying an ever-growing chain. Receiver deduplication uses the source
identity plus source revision/projection identity. Since forwarding is not
automatic, a hop counter is not the mechanism that makes cycles safe.

## 6. Direct, chained, and circular topology

Subscriptions are direct:

```text
Finger -> Hand -> Arm -> Body -> Avatar -> World/AP
```

If Hand subscribes to Finger, Finger sends only events matching Hand's accepted
source-qualified interests. Body does not automatically receive those raw
Finger events. Hand may commit a distinct Hand state change; its own subscribers
can then receive a separately matched Hand event.

This gives each boundary a clear semantic owner and prevents a leaf component
from broadcasting irrelevant detail to every ancestor. An AP ontology
subscribes to each avatar and declares the avatar event patterns it needs; it
does not register for every finger and collider event.

Circular subscriptions are allowed if both registrations independently pass
the target policies. Cycle detection is not used to reject them. Safety comes
from explicit source-qualified interests, distinct derived facts,
changed-value coalescing, duplicate suppression, and the no-event-writes rule.

## 7. Naming discipline

This facility is an **ontology subscription**. Its durable relation is
`subscribes/2`, and its runtime identity is an `OntologySubscriptionKey`.

The browser/client concept formerly illustrated as:

```prolog
view_subscription(AgentId, Source, ViewType).
```

is renamed in the client/world design to:

```prolog
client_view_session(AgentId, Source, ViewType).
```

A client view session is authenticated, local P-state selecting what one
connected client sees. It is not a durable ontology relation. Client state
snapshots/deltas may consume an ontology projection, but their session ID,
visibility window, reconnect cursor, and queue belong only to the client path.

## 8. Transport and dissemination protocol choice

### 8.1 First implementation

Certified catch-up pages, registration control, and height/digest wake-ups use
reliable ordered QUIC streams. The target pushes a page only after an accepted
event interest matches, but that page remains the existing complete certified
format rather than a redacted event format. Gaps are detected by source height
and recovered through the certified foreign-log follow. A stream's reliability
is useful for latency but never replaces certification.

The existing RFC 9221 lossy datagram path remains limited to client/world cues
and simulation frames. It is not used for certified subscription pages.

All subscription traffic uses a lower transport priority than `{log, Ns}`
consensus traffic. Mixed-load tests must prove that subscriber fan-out cannot
starve votes, catch-up, or durable apply.

### 8.2 Plumtree

Do not add a Plumtree service in the first slice. Quod already has a
push/anti-entropy feed and a certified foreign-history follower. Sparse
subscriptions are cheaper as multiplexed host-to-host registrations.

If measured target fan-out later makes direct wake-up distribution the
bottleneck, eager/lazy tree repair may be introduced behind the same feed wire
and registration contract. It remains an internal delivery optimization:

- subscription facts and authorization stay unchanged;
- `quod_foreign_log` remains the certainty path;
- no new membership, identity, directory, or event semantics appear;
- all receivers still recover gaps from certified history.

Protocol choice follows measurements; the ontology API does not expose
`plumtree`, `route`, `fanout`, or transport topology.

## 9. Backpressure and capacity

The initial workload assumptions are explicit hypotheses to benchmark, not
user quotas:

- private component edges normally have one to four interested subscriber
  hosts;
- a world/AP may follow tens or hundreds of avatar ontologies;
- a popular system ontology may have thousands of subscriber hosts and is
  the workload that could justify tree-shaped dissemination;
- ontology projection events occur at committed-transaction rate, not physics
  tick rate;
- one committed transaction produces at most one coalesced notification per
  matching registration, never one wire message per matching reaction rule or
  changed fact.

Payloads reuse existing hard safety ceilings. Certified pushed or pulled
catch-up material is paged under the existing roughly 900 KiB foreign-page
cap, and every outer frame remains below the existing 1 MiB transport cap; an
initial view is never encoded as one unbounded term. The expected ordinary
wake-up is only identity/view/height/digest metadata. Slice 1 must freeze a
stricter registration and wake-up envelope bound only after measuring real
event shapes; malformed or oversized input is rejected before decoding.

State is shared at the largest safe key:

- one verified history/current view per target identity per node;
- one compiled selector per distinct accepted source-qualified event pattern;
- one multiplexed transport connection per existing QUIC pool key;
- one bounded registration row per active logical subscription;
- one newest-height wake-up per target/registration while congested.

Queues are bounded. When a subscriber falls behind, the source discards
superseded pushed pages, keeps only the newest observed height, and marks the
registration `snapshot_required`. The subscriber reconstructs from its
certified cache and pulls the missing certified suffix. It never asks the
target to retain an unbounded private delta history.

This is the same semantic rule as client state delivery: slow consumer ->
resnapshot. Capacity refusal is explicit and retryable. Safety ceilings are
configuration/resource bounds, not silent default quotas per user or
ontology.

A durable ontology may contain 10,000 subscription facts. Acceptance must
measure separately:

- reconciliation time and memory for 10,000 facts;
- number of distinct target identities and route lookups;
- active versus unreachable targets;
- selector sharing;
- aggregate incoming event rate;
- target registrations and fan-out;
- disk cost of shared certified history caches.

Ten thousand facts are expected to be sustainable. Ten thousand simultaneous
high-rate remote targets are a different workload and must not be assumed
free.

## 10. Failure, replay, and membership behavior

| Situation | Required behavior |
|---|---|
| subscriber fact commits | Runtime reconciles it, resolves the exact target, authorizes registration, and begins certified following |
| subscription fact is retracted | Runtime unregisters and removes the active P view; a target may deliver only until the bounded registration lease expires, and nothing survives the next renewal check; the shared follow stops when no local consumer remains |
| subscriber node restarts | D rebuilds; runtime reconciliation recreates registrations and P from the shared certified cache/history |
| subscriber cache is wiped | Rebuild from target genesis/certified checkpoint and history; pushed state is never accepted as a shortcut |
| subscriber ontology enters replay | Stop E scheduling; fold local D; reconcile subscriptions and their P views at ready; do not replay old E |
| target node restarts | Active registration disappears; subscriber resolves/re-registers and resumes from its certified height |
| target is replaying/rebuilding | Registration is unavailable; subscriber retains D intent, marks P stale, and retries after readiness |
| target committee changes | Freeze and verify the new current view, discard removed-host registrations, re-check `can_invoke/4`, and resume on current hosts |
| subscriber committee changes | Expire the old requesting-host binding; verify current subscriber evidence/host eligibility before renewal |
| target ACL or subscriber `react_on/3` interests change | Recompile the one interest set; reauthorize registrations; stop refused patterns and resnapshot P when required |
| wake-up/pushed page is lost | Digest/height observation or periodic follow discovers the gap; foreign-log pull repairs it |
| wake-up is duplicated/reordered | Stable identity/height/epoch makes it a no-op or a bounded refresh hint |
| forged or outsider push | Ignore; no P change occurs without certified history |
| slow subscriber | Coalesce to newest height, discard queued pushed pages, resnapshot from certified state |
| source becomes unreachable | Keep durable subscription; mark projection stale/unavailable; never invent current state |
| target anchor differs | Fail closed as identity conflict; never retarget the durable subscription by namespace alone |
| ACL is revoked | Stop future delivery after re-check; do not claim already disclosed data was erased |
| private target has a valid local direct seed | Resolve and register without publishing the target globally |
| private target has no reconstructible route | Subscription remains durable but inactive/unreachable; never persist an endpoint into D |

Registration epochs belong to the authenticated target-host/session generation.
Late messages from an older epoch cannot advance a current subscription. Source
heights are meaningful only inside the exact anchored target identity.

## 11. Format impact

This document and its initial non-confidential projection plan change no
format.

The planned durable subscription and `react_on/3` rows are ordinary Prolog
facts in ordinary transactions. They require no ledger, block, certificate,
transaction, DTX, or genesis format change and therefore no network
re-founding.

The runtime protocol is new and versioned from its first byte; there is no old
subscription decoder or compatibility mode to retain. If continuous following
requires different local `quod_foreign_log` cache metadata, the disposable
cache version is bumped and rebuilt. Historical ledger bytes remain untouched.

Selective cryptographic disclosure is explicitly outside this no-format-break
claim and cannot be declared implemented until its own format/trust review is
complete.

## 12. Reviewable implementation slices

### Slice 1 — vocabulary and local reconciliation

**Status: IMPLEMENTED.** `quod_runtime` derives both
catalogues from its frozen committed snapshot. A small read-only helper in
`quod_diff` enumerates exact interpreted clauses, so a rule-derived answer
cannot become runtime configuration. Founding reaction clauses are compared
after alpha-normalizing their intentional Prolog variables. The live
`applied_live` path refreshes the same catalogue when either declaration
functor changes; restart and replay use the existing reconciliation path.
There is no route, follower, registration, event matcher, executor, or new
state owner in this slice.

- Freeze the bounded `subscribes/2` shape and the source-qualified Pattern
  extension of the existing `react_on/3` declaration.
- Apply the one declaration-authority contract: founding-genesis-only
  reactions until `can_declare_runtime(..., reaction, ...)` is validator
  authorized; dynamically written but unauthorized declarations remain inert.
- Prove subscription create/remove are ordinary transactions.
- Compile target subscriptions and reaction interests during existing runtime
  reconciliation.
- Add no network behavior yet.

### Slice 2 — shared continuous certified follow

**Status: IMPLEMENTED IN THE WORKING TREE.** This slice makes
the Slice-1 catalogue operational only as a local certified follower. It does
not register an event pattern at the target, push a source event, execute a
handler/reaction, or change `::`. Those remain Slices 3--5.

#### Slice-2 outcome

After `quod_runtime` reconciles its ordinary `subscribes/2` facts, each exact
target identity has one of three visible P states:

```text
unreachable(Reason, LastCertifiedHeight)
building(LastCertifiedHeight)
ready(CertifiedHeight, ProjectionId, Freshness)
```

`ready` means the projection is a valid certified prefix, not that every live
host has proved there is no newer slot. A separate current-view corroboration
can establish zero lag; temporary staleness is reported rather than hidden.
`Freshness` is explicit local P:

```text
#{last_probe_ms, last_advance_ms,
  hinted_height => unknown | Height,
  lag => unknown | NonNegativeInteger,
  current_view => confirmed | unconfirmed}
```

The times are receiver-local monotonic observations. A remote height and the
derived lag are diagnostics only; neither is certification. `current_view` may
be `confirmed` only after the existing full current-committee corroboration.

`ProjectionId` names a node-local, rebuildable materialization of the target's
published facts at that exact certified height. It is not a target outcome
reference, is never written to D, and is not a public proof handle. Slice 2
does not yet expose a Prolog query bridge over it; that prevents a temporary
internal representation from becoming a second `::` API before Slice 4 defines
the source-qualified read contract.

The runtime stores only `{TargetIdentity, FollowRef, State}`. The node-wide
foreign-log owner keeps the shared materialization. Two local ontologies which
subscribe to the same target receive distinct consumer references but point at
the same certified history and projection. Removing the final local consumer
stops polling and discards the local materialization; the existing
disposable certified-history cache may remain.

#### One public follow lifecycle

The implementation adds one asynchronous lifecycle to `quod_foreign_log`:

```erlang
follow(TargetIdentity) -> {ok, FollowRef} |
                          {error, invalid_identity | capacity | unavailable}.
ack(FollowRef, NoticeRef) -> ok.
unfollow(FollowRef) -> ok.
```

The caller is the consumer: `follow/1` monitors the calling process, so no PID
or owner identity is accepted as caller-supplied data. It allocates no network
or disk work in the `gen_server` call. Results arrive as correlated messages:

```erlang
{quod_foreign_follow, FollowRef, NoticeRef, TargetIdentity,
 {building, LastCertifiedHeight}}
{quod_foreign_follow, FollowRef, NoticeRef, TargetIdentity,
 {advanced, FromHeight, ToHeight, ProjectionId, Freshness, ChangedHeads}}
{quod_foreign_follow, FollowRef, NoticeRef, TargetIdentity,
 {resnapshot, ToHeight, ProjectionId, Freshness}}
{quod_foreign_follow, FollowRef, NoticeRef, TargetIdentity,
 {unreachable, Reason, LastCertifiedHeight}}
```

There is at most one unacknowledged notice per consumer. The runtime installs
the correlated state and calls `ack/2`. While that notice is outstanding, a
second projection advance collapses directly to `resnapshot` rather than
retaining a growing delta union or fabricating a partial delta. This
acknowledges only local P delivery; it has no network, authorization, or
transaction meaning.

`ChangedHeads` is the bounded, stable-deduplicated set of heads whose **actual
published state** changed, including retracted heads. It is derived after the
canonical apply verdict, not copied blindly from the ledger transaction. The
target identity in the same message supplies source qualification; the
subscriber runtime must retain it beside every head. Initial construction and
gap repair may coalesce many entries into one `advanced` notification. Such a
notification may update P but is never historical E and schedules no
`react_on/3` in this slice.

`unfollow/1`, consumer `DOWN`, runtime replay, and runtime termination all use
the same removal function. Late messages are ignored by exact `FollowRef`.
Late acknowledgements are ignored by exact `{FollowRef, NoticeRef}`.
Reconciliation computes the set difference between old and new catalogue
identities; it does not stop/recreate unchanged follows.

#### One target, one short advancement lane

The existing `#history{}` row carries this state; there is no second cache or
registered service. Long-lived consumer interest is separate from
`#history.active`: the latter continues to mean one short cache/verification
operation. A follow therefore never owns the active slot while idle.

For one target:

1. select an exact anchored source through the shared foreign-log
   selector, preferring an exact read-ready local ledger through one generalized
   local-history-source helper;
2. run one catch-up page through the existing codec, certificate verifier,
   phase index, append, and atomic checkpoint path;
3. apply that verified page to the shared fact materialization;
4. publish one coalesced advance and yield the lane before scheduling another
   page.

The generic local-history-source helper is a refactor of the readiness,
identity, and ledger-root checks currently hidden behind the DTX-only local
evidence source. DTX and subscription callers project their narrower answers
from that helper; no subscription-only local-ledger exception is added.

Remote source selection uses `quod_foreign_log`'s one selector. It
combines exact-anchor directory/private-seed rows, already certified history
routes, and volatile contacts learned from authenticated scope or DTX peers.
All are discovery hints only. Every accepted entry still requires its
certificate and exact ordered history transition. Route failure or a
non-advancing host rotates to another current candidate; an anchor conflict
fails the whole refresh. Certified committee/route transitions learned while
folding take precedence over bootstrap contacts naturally.

Until Slice 5 adds authorized push wake-ups, a configurable timer requests the
next page. Success at an unchanged head uses the normal poll interval; failure
uses capped exponential backoff plus jitter. A newly learned route or consumer
causes one immediate refresh. All waiting is `send_after` plus messages—no
`wait_until`, sleeping worker, synchronous network call in `quod_runtime`, or
busy loop. The exact default cadence is an operator setting chosen and pinned
by the load gate, not a semantic constant.

A target refused only because the active-history or projection-memory capacity
is full remains an explicit inactive P row and retries on the same bounded
timer cadence as an unreachable target. It does not wait forever for an
unrelated catalogue edit, and it does not spin or evict an active target.

Foreground DTX/reference verification and continuous follow share the same
per-history serialization and global request/cache accounting. A follow page
is deliberately one bounded turn; it cannot retain the lane indefinitely or
starve an exact DTX check. Conversely, a busy exact check merely coalesces one
follow refresh requirement rather than creating a retry queue.

#### One canonical committed-state transition

Certified history alone is insufficient to copy a transaction's raw `diff`:
ordinary OCC may reject at apply, duplicate transaction IDs must not apply
twice, and a DTX publishes its hidden diff only at Finalize(commit). Therefore
Slice 2 first extracts the deterministic committed-state transition currently
embedded in `quod_prolog` into one process-free module,
`quod_committed_projection`.

The extracted reducer owns no process, route, worker, or policy. Given the
target identity, parent fact state, outcome projection, certified entry, and
already-verified DTX effects, it:

- calls the existing `quod_commit_validation` and `quod_diff` functions;
- preserves the exact membership, OCC-rejection, duplicate-operation,
  duplicate-transaction, policy-self-seal, Prepare, Finalize, and noop rules;
- returns the new fact/outcome state plus actual applied operations and changed
  heads;
- emits no runtime message, client reply, effect, or Simplex acknowledgement.

The foreign materializer builds the same common-predicate base and uses the
existing bounded, rebuildable `quod_outcome` DETS backend for
duplicate/operation/DTX state; it does not invent a lighter outcome rule or an
unbounded per-target map. Each worker gets a private disposable directory, so
overlapping worker shutdown/rebuild generations never share mutable derived
state. Its database backend is exactly
`quod_erlog_db_mvcc`, and every certified entry commits at its ledger height as
live apply does. The per-functor MVCC version heights are part of the
deterministic materialized state: without them a later OCC read-check could
produce a different verdict. Its deterministic `ProjectionId` is derived from
the exact target identity, certified height, and certified history head, which
bind that complete deterministic MVCC state; rebuilding the same prefix must
yield the same identifier and version tokens.

`quod_prolog` is refactored to call this reducer and retains scheduling,
waiters, outcome/event publication, MVCC pinning, and the Finalize
acknowledgement. It also retains every `quod_effect_journal` reservation,
handoff, activation, retirement, and reconciliation operation. A foreign
materializer applies an effect-bearing transaction's D diff but never touches
effect custody or executes the effect. The foreign materializer calls the same
reducer after `quod_catchup:verify_forward` and retains only P. This ordering
is mandatory: extract with parity tests first, then add the follower. A copied
subset of `apply_transaction`, a raw-diff shortcut, or another DTX materializer
is a release blocker.

The materialized fact state is owned by one bounded internal projection worker
per **actively followed target**, not per `subscribes/2` fact or per reaction.
It is monitored by `quod_foreign_log`, has no registered name or independent
cache, and waits idle for messages between short advancement turns. This small
worker owns its Erlog ETS table; if it dies, the foreign-log owner discards the
generation and rebuilds it from the already-certified cache. Thus it is an
implementation resource, not a second authority.

Initial materialization replays the certified cache in the same page-sized
turns and publishes nothing until it reaches one internally consistent height.
New pages are verified once, persisted once, and applied once. The materialized
facts are not added to the foreign-cache checkpoint in this slice: after a node
restart they are rebuilt lazily from certified cached entries. Consequently
the existing cache version and every ledger/wire byte remain unchanged.

#### Resource behaviour, backpressure, and runtime integration

There is no numeric ceiling on foreign identities, retained verified caches,
follow consumers, or materialized foreign projections. A dormant identity is
only verified cache on disk; it is opened lazily when a proof or follow needs
it and released again when the last active user leaves. The existing per-page
wire-format checks validate one received page before it reaches the verifier or
disk. They do not limit how many ontologies a node may know or follow.

One target keeps at most one coalesced refresh request and one current
projection generation. A slow runtime receives only the newest correlated
state through the one-notice/ack lifecycle; intermediate notifications
collapse to a resnapshot requirement. It
never creates an unbounded page, delta, timer, or mailbox-owned retry list.
MVCC projection memory is measured after every page. The outcome side keeps its
own disposable local cache. A durable catalogue may name any number of remote
ontologies; only identities with an active proof or follow have decoded state
or a worker on the node.

`quod_runtime` adds only a source-view map and exact follow reconciliation. It
does not acquire a second worker pool or dependency graph. It records advances,
staleness, and heights, but does not yet hand foreign heads to
`state_handler/4` or run `react_on/3`; Slice 4 connects those states to the one
existing ordered tier.

#### Slice-2 failure and replay contract

| Edge | Required result |
|---|---|
| runtime/consumer dies | Monitor removes only its reference; shared target follows for remaining consumers |
| last consumer disappears | Cancel timer/work, delete materialized P, retain only evictable certified cache |
| foreign-log owner restarts | No consumer or projection is trusted; runtimes re-reconcile and rebuild from certified cache |
| projection worker dies | Drop its generation, report building/stale, rebuild through the same cache replay |
| cache corrupt or checkpoint disagrees | Existing one-time delete/rebuild rule; never salvage projected facts independently |
| route disappears | Keep durable subscription and last certified height; mark unreachable and retry directory resolution |
| capacity is temporarily full | Keep an explicit inactive row and retry on the bounded unreachable cadence; never spin or evict an active follow |
| target committee changes | Accept only certified transition, replace route hints, continue one ordered history |
| duplicate/stale/reordered page | Existing verifier rejects/no-ops it; no projection notification |
| root network identity is temporarily unavailable while applying signed material | Keep the last certified/materialized height, report building, and retry; never classify the entry invalid or crash-loop the worker |
| subscriber replay begins | Remove follow refs before releasing the local runtime snapshot; ready reconciliation recreates current P without E |
| target advances while subscriber is down | Rebuild/catch up to current certified state; emit one current P advance and no historical reaction |

#### Slice-2 tests and gates

1. Before extraction, freeze a scripted ledger and its current Prolog
   per-height fact/outcome digests as golden fixtures. After extraction, drive
   that ledger through both the local `quod_prolog` caller and foreign
   materializer: genesis, ordinary apply, OCC reject, duplicate, membership,
   effect-only, noop, Prepare/Finalize(commit), abort, and Complete must match
   the golden fixtures and each other **at every height**. The old apply code is
   then deleted; it is never retained as a test-only compatibility path.
2. Two runtimes following one identity create one history/materializer and two
   monitored consumer refs; removing either one does not interrupt the other.
3. A 257-entry advance yields page-sized work and allows a foreground exact
   reference verification between follow turns.
4. Raw diffs from OCC-rejected and duplicate transactions never enter the
   projected facts; a prepared DTX diff appears exactly once at Finalize.
   The OCC case includes a read-check which conflicts only because of an older
   per-functor MVCC mutation height.
5. Cache wipe, cache corruption, foreign-log restart, projection-worker crash,
   and runtime restart rebuild the identical ProjectionId/fact state from
   certified history.
6. Wrong anchor, directory anchor conflict, outsider route, forged cert,
   missing/reordered entry, and stale committee route never advance P.
7. Public and confirmed-private routes reach the same exact-anchor path; local
   co-hosting uses the generalized local source without a network self-dial.
8. Removing a subscription during an in-flight page produces no late accepted
   state for the removed `FollowRef`.
9. Poll/retry timers coalesce; a prolonged outage retains O(targets) state and
   produces no worker/timer/mailbox growth or synchronous runtime stall.
10. Capacity tests fill histories, consumers, encoded cache, and projection
    memory independently and prove typed refusal with existing consumers
    unaffected.
11. Runtime restart/replay restores current P only; no `state_handler` or
    `react_on` is invoked in this slice.
12. An effect-bearing transaction materializes its D diff with an instrumented
    assertion that no `quod_effect_journal` API was called.
13. Root network identity unavailable midway through materialization reports
    building/retry; restoring it reaches the same ProjectionId and MVCC tokens
    as uninterrupted replay.
14. Compile, xref, Dialyzer, full EUnit, focused CT, diff check, and a mixed DTX
    plus 64-follow load run are green before Slice 3 begins. The load result
    records aggregate poll requests/second, pages/second, bytes/second, DTX
    latency change, and consensus latency change at the proposed default poll
    cadence. The default is accepted only with that fleet-wide multiplier
    measured; a one-target result cannot set it.

Metrics introduced with the owner (and added to the dashboard in this slice)
are node-wide active follows, consumers, projection workers/memory, building,
unreachable and capacity-limited targets, verified follow pages/entries/bytes,
poll requests/pages/bytes, coalesced refreshes, retries, rebuilds, and maximum
certified lag. Labels must remain bounded; arbitrary target namespaces are not
Prometheus labels. Existing per-subscriber runtime metrics add
ready/building/unreachable source counts.

Working-tree verification at implementation handoff is recorded with the
review rather than weakening the acceptance list above. Compile, xref,
Dialyzer, full EUnit, the focused inter-ontology CT, and formatting checks are
green. The mixed-DTX plus 64-follow hardware run remains an acceptance gate
before Slice 3 starts. Deployment of Slices 1--2 does not replace that
acceptance result.

### Slice 3 — registration and event authorization

- Extend the target `quod_feed` with bounded runtime registrations and
  coalesced wake-ups.
- Reuse one local `can_invoke/4` authorization helper.
- Compile the accepted union of subscriber `react_on/3` patterns once; keep no
  second durable filter list at the target.
- Index candidates in Erlang, then perform the concrete event-pattern match
  through `erlog_int:unify_prove_body`; add no Erlang-side unifier.
- Support public directory routes and already-configured private direct seeds.
- Leave `::` and scope-session routing unchanged.

### Slice 4 — runtime projection and reaction integration

- Feed source-qualified subscription changes into the existing
  `state_handler` order and worker boundary.
- Reuse replay/reconcile/collapse behavior and the P-before-E barrier.
- Match accepted live events through the one existing planned `react_on/3`
  reaction owner after P is current, using `erlog_int:unify_prove_body` so the
  grounded executor and effect receive the exact Prolog bindings.
- Enforce that E cannot directly stage D.
- Cover chained and circular derived projections.

### Slice 5 — reliable page push, backpressure, and resnapshot

- Add versioned reliable registration/wake-up envelopes and push only the
  existing certified catch-up page format as entry material.
- Share feed digest/gap helpers where contracts match.
- Coalesce slow subscribers and resnapshot through certified follow.
- Add transport priority and metrics.

### Slice 6 — hardware performance decision

- Run sparse, high-fan-out, cyclic, churn, and 10,000-fact workloads.
- Measure consensus interference, commit-to-projection latency, recovery,
  memory, disk, and bytes.
- Consider an eager/lazy tree only if direct registered fan-out is the measured
  bottleneck. No ontology or authorization API changes in that optimization.

Each slice requires a separate adversarial review before implementation moves
to the next one. Dormant compatibility paths are not kept between slices.

## 13. Acceptance and adversarial tests

### Semantics and ownership

1. A read of C from B leaves no durable or runtime subscription after the proof
   closes.
2. An authorized `subscribe` goal commits exactly one fact in B; C receives no
   durable write.
3. Removing the fact commits in B and removes the rebuilt registration/P view.
4. The subscription fact accepts exactly an anchored target identity; added
   endpoints, node keys, channels, options, and malformed identities are
   rejected.
5. Public `::` works identically with no subscription; existing origin-owned
   A -> B -> C scope tests remain byte-for-byte authoritative.

### Authority and certification

6. Unauthorized registration fails through the real target `can_invoke/4`
   path and allocates no retained registration.
7. A node that merely claims to host B cannot register B's subscription. The
   target requires certified presence of the exact B fact and current host
   eligibility.
8. Changing `can_invoke/4`, the target committee, or the subscriber committee
   forces re-registration and a fresh policy/evidence verdict.
9. One source host, an observer, an outsider, or a stale committee member cannot
   fabricate a projected fact.
10. Wrong anchor, committee view, registration epoch, height, digest, pattern,
    or subscriber identity is rejected.
11. A pushed catch-up page alters P only after its certified log suffix
    verifies and folds through the one foreign-log path.
12. A target accepts an event pattern only through the existing `can_invoke/4`
    path; no feed-local or reaction-local ACL can override that verdict.
13. Removing or changing A's `react_on/3` declaration updates B's rebuildable
    filter and stops the old pattern without writing anything durable at B.
14. B sends no event that matches none of A's accepted interests; A still
    performs the final local match before executing a reaction.

### Replay and recovery

15. Wiping the subscriber's local foreign cache and restarting reconstructs the
    same projection from certified history.
16. Subscriber replay runs no old E; ready reconciliation produces one current
    P snapshot and only later live changes schedule reactions.
17. Source replay emits no historical wake-ups/reactions; subscribers discover
    the current height and resnapshot.
18. Lost, duplicated, reordered, and delayed notifications converge to the same
    certified projection.
19. A target committee rotation while following drops old registrations,
    certifies the new view, reauthorizes, and neither skips nor accepts a
    cross-view pushed page.

### Capacity and abuse

20. Registration floods, many patterns, oversized payloads, and slow consumers
    remain within configured memory/worker/queue bounds and cannot delay
    consensus processing.
21. Queue overflow retains only a newest-height resnapshot requirement; no
    unbounded pushed-page list or retry storm remains.
22. Multiple local subscriptions to the same target share one certified history
    and follow worker.
23. Ten thousand durable facts reconcile without ten thousand processes or
    sockets; measured time/memory are recorded.
24. Event load shares QUIC without raising consensus latency beyond the reviewed
    acceptance budget.

### Topology and private reachability

25. B follows a private C through an existing confirmed direct seed; C never
    appears in the public directory.
26. After route loss, the durable subscription remains but reports stale or
    unreachable until normal directory recovery succeeds.
27. B -> C and C -> B subscriptions update distinct source-qualified P values
    without echo, automatic D writes, or unbounded cause state.
28. Finger -> Hand -> Arm -> Body produces one distinct derived update per changed
    boundary, not a raw automatic broadcast to every ancestor.
29. Multiple avatars in one AP register only the avatar event patterns the AP
    needs; component events do not fan out merely because the AP follows the
    avatar.
30. A committed `fipa_envelope/6` event reaches only matching addressed-agent
    reactions, and replay never redelivers the performative.

### Declaration, policy, lease, and owner closure

31. A dynamically asserted `react_on/3` fact registers nothing and executes
    nothing until the exact declaration passes the one
    `can_declare_runtime(..., reaction, ...)` authority gate; a permitted
    declaration activates through that same path.
32. If target policy proves access to `foo(bob)` by binding `X` while checking
    `foo(X)`, registration accepts the original broad `foo(X)` and all
    instances are delivered. This pins the documented existential,
    bindings-discarded behavior of normal query authorization.
33. An attacker may validly found and host an ontology containing
    `subscribes(Target, Anchor)`; that true evidence grants nothing by itself,
    and target `can_invoke/4` alone decides whether registration succeeds.
34. After subscription retraction, delivery may continue only within the
    bounded registration lease and no delivery survives the next renewal
    check.
35. Existing hosted-follower block dissemination remains byte-for-byte
    unchanged while event registrations are active on the same `quod_feed`;
    semantic delivery uses only the added post-apply handoff.
36. A variable-bearing accepted interest matches at the target through
    `erlog_int:unify_prove_body`, and the subscriber repeats that match through
    the same interface before continuing the reaction. The executor and effect
    observe the resulting bindings; a non-match runs no continuation. An
    Erlang equality test or home-grown binding map cannot satisfy this test.

## 14. Observability and performance report

Metrics must distinguish:

- durable subscription facts and active registrations;
- durable source-qualified reaction interests and accepted target-side pattern
  indexes;
- shared target follows and local consumers per follow;
- authorization success/refusal/revalidation per event pattern;
- certified target height, projected height, and lag;
- wake-ups and certified pushed pages received/dropped/coalesced;
- foreign pulls, verified bytes, cache bytes, cache rebuilds, and corruption;
- resnapshot causes and duration;
- state-handler queue/collapse/reconcile and live-reaction outcomes;
- private route unavailable and anchor/committee conflicts;
- event traffic bytes and consensus latency while it is active.

The performance report for Slice 6 must include at least:

- sparse subscriptions across many targets;
- one target with many subscribers;
- 10,000 low-rate subscriptions in one ontology;
- circular and depth-four component graphs;
- source/subscriber restarts and committee churn;
- slow and disconnected subscribers;
- mixed subscription traffic, DTX writes, catch-up, client snapshots, cues, and
  simulation datagrams.

Protocol topology is selected only after these measurements.

## 15. Explicit non-goals

- Subscribing does not join or host an ontology.
- It does not alter `::`, scope sessions, OCC, DTX, or consensus.
- It is not permission and does not bypass `can_invoke/4`.
- It does not create a global catalogue of private ontologies.
- It does not claim selective confidentiality from a peer that can already
  access the target's full catch-up ledger.
- It does not persist routes or endpoints.
- It does not copy foreign facts into subscriber D.
- It does not automatically forward events transitively.
- It does not add a durable target-side event filter or duplicate
  `react_on/3` as another subscription predicate.
- It does not allow event handlers to write durable facts directly.
- It does not replace client view sessions, FIPA conversations, or world
  simulation frames.
- It does not introduce Plumtree before fan-out measurements justify it.
- It does not reopen the chosen Rapier/owner-ghost physics design or make
  committed interpolation the authoritative physics state.

## 16. Documentation changes in this planning revision

This planning revision also:

- corrects `content-layer.md` sections 4 and 12 to require explicit durable
  subscription;
- retires every semantic "read-set is subscription" claim in
  `content-layer-design.md` while retaining read tokens for OCC;
- makes `inter-ontology.md` section 5 point here while retaining authority for
  proof-scope completion and the no-residue rule;
- states in both directory plans that a subscription may drive private
  following but never stores a route;
- relates future FIPA `subscribe/cancel` protocol state to this durable
  ontology relation plus the same source-qualified `react_on/3` interests,
  without making a second transport subscription;
- renames the client/session-only `view_subscription` example to
  `client_view_session`;
- replaces the deferred read-set notification task with the slices in this
  plan; and
- corrects the superseded ordering design's notification references so it
  cannot be mistaken for the current subscription contract.
