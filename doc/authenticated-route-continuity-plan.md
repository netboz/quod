# Authenticated route continuity and DTX recovery — plan

**Status:** implemented in the working tree; source review and the hardware
acceptance run remain before the next subscription slice.

This plan closes the remaining hardware acceptance gap for ontology-subscription
Slice 2 before subscription Slice 3 begins. It does not change subscription
semantics, Prolog authorization, proof scopes, ledger records, or the DTX state
machine.

The failure that motivated it is precise: an origin ontology could reach two
private participant ontologies, seal their plans, and begin a durable group.
One participant then received its Prepare but could not verify the certified
Begin because it had no independently configured route back to the private
origin. Adding reverse private seeds manually was diagnostic only and is not an
acceptable product contract. A later route also failed to wake the already
retained candidate, exposing a second, generic validation-retry defect.

## 1. Place in the existing roadmap

The work stays in this order:

1. Ontology-subscription Slices 1 and 2 remain unchanged: durable vocabulary,
   local reconciliation, and one continuous certified follower are already
   implemented.
2. This plan is a **Slice-2 acceptance closure**, not a new subscription
   feature. It repairs private reachability shared by DTX, certified following,
   and later subscription registration.
3. The mixed 64-follow plus three-participant DTX hardware gate is rerun.
4. Only after that gate and review pass does subscription Slice 3 add target
   registration and event authorization.
5. Subscription Slices 4–6 then continue as already specified: projection and
   reactions, reliable push/backpressure, and hardware performance evaluation.

No reaction, agent, event-filter, Plumtree, physics, or rendering work is added
to this closure.

## 2. Invariants that must not change

### 2.1 Proof and transaction semantics

- `::` still opens one origin-controlled proof scope.
- Scope authorization still uses the target ontology's existing
  `can_invoke/4` path.
- The origin still seals immutable plans before starting DTX.
- A sealed group still returns internal `group_pending`, parks the caller on
  the public GroupRef, and closes every proof scope.
- DTX recovery remains independent of the proof worker and browser connection.
- No goal is re-proved after an uncertain outcome.

Closing a proof scope is intentional. Keeping it alive until Complete would
make durable recovery depend on a disposable proof process and would prevent a
different current origin validator from taking over after a crash.

### 2.2 Authentication and authority

There are three separate facts, and the implementation must not merge them:

1. **Transport identity:** mutual TLS proves which node key owns a live link.
2. **Reachability hint:** an endpoint says where that key may be dialled. It is
   volatile and may be wrong or stale.
3. **Ontology authority:** only certified ledger history proves that a node is
   a validator for one exact `{Namespace, GenesisAnchor}`.

A live authenticated node may update only the contact hint for its own key. It
cannot thereby claim an ontology, validator role, committee membership, or
permission. `quod_foreign_log` remains the sole verifier of anchored foreign
history. DTX reference-chain checks remain in `quod_dtx`. Prolog ACL decisions
remain in the existing proof path. No route or endpoint enters an ACL decision.

### 2.3 One owner per concern

- `quod_quic` remains the one node-key-to-endpoint contact cache.
- `quod_directory` remains the one ontology route directory.
- `quod_foreign_log` remains the one certified foreign-history verifier/cache.
- `quod_simplex` remains the DTX consensus and candidate owner.

Do not add a route process, DTX-only verifier, proof-scope verifier, reverse-seed
registry, or second foreign-history cache.

## 3. Concepts and terminology

The implementation and documentation will use these names consistently:

- **node contact** — volatile `{NodeKey, Endpoint}` learned from an
  authenticated connection or configured seed;
- **ontology route** — a directory row associating an exact ontology identity,
  node key, endpoint, and advertised role;
- **certified route** — an ontology route derived from verified committed
  history;
- **bootstrap candidate** — an untrusted node contact which may be asked for
  an ontology's history but grants no authority;
- **proof scope** — temporary Prolog execution/overlay session;
- **DTX recovery channel** — bounded request/reply transport used after proof
  scopes close.

The word `route` without qualification should be avoided in new APIs because it
currently hides these distinct meanings.

## 4. Implemented architecture

### 4.1 Reuse the existing authenticated return contact

No transport-header change is required. Every current QUIC link header already
carries the sender's `{NodeKey, AdvertisedEndpoint}`. The endpoint comes from
the operator-configured `node_addr`, not the remote UDP source port or local
bind port. A keyed node without that address fails boot.

The receiver validates the endpoint shape and binds `NodeKey` to the mutual-TLS
certificate before acknowledging the link, publishing its payload, or learning
anything. The endpoint is therefore an authenticated statement by that key,
but remains reachability data rather than ontology authority. A malicious peer
can make itself unreachable by advertising a dead endpoint; it cannot poison
another key or gain an ontology role.

`learn`/`no_learn` already controls the existing node-contact cache separately
from ontology-route promotion. DTX uses a pinned `no_learn` connection, so the
complete authenticated `{NodeKey, AdvertisedEndpoint}` must be passed directly
from DTX ingress to the foreign-log source selector rather than globally cached
as a side effect. This is an internal plumbing correction, not transport work.

The existing `quod_quic` address cache has neither capacity eviction nor
expiry. This closure does not widen or depend on it: new identity associations
live under `quod_foreign_log`'s volatile route-hint state. The address
cache's trusted-fleet posture remains separate deferred transport hardening and
must not be described as already bounded.

### 4.2 One bootstrap-candidate seam in `quod_foreign_log`

`quod_foreign_log` retains volatile bootstrap candidates for an exact ontology
identity. When its decoded verified history hibernates, these small transport
hints remain separate P state; no endpoint is written to the durable cache.
On the next use, the owner combines them with the lazily reopened certified
history through the same route-selection function.

A candidate is `{NodeKey, Endpoint}` from an authenticated link or existing
route source. It is never treated as a validator route merely because it is
present in the hint store.

Candidate sources are:

- current certified directory routes;
- confirmed private seeds;
- the authenticated source of a scope or DTX request whose control names that
  exact identity;
- committee routes learned while folding certified history.

An authenticated source/identity association is only a hint. `quod_foreign_log`
must fetch and verify the exact anchor, contiguous certified history, committee
transitions, and requested reference before returning evidence. Once a
committee is certified, selection is keyed by its members: a member's
first-party live contact is tried first and its certified historical endpoint
is retained as the fallback. Caller-supplied third-party hints never displace a
certified endpoint. Each key remains one probe and one vote; its fallback is a
sequential resend of the same request id under the same deadline. Before
genesis is certified, the bounded discovery-ordered bootstrap walk remains in
use. At the existing hint cap, eviction removes the oldest non-committee
contact first, so contact churn cannot silently discard a current member's
only live endpoint. Transport failure never becomes an invalid-ledger
conclusion.

This is an extension of source selection around the existing verifier, not a
new verification path. Both foreground DTX checks and continuous subscription
following consume it.

### 4.3 Deliver the hint to every validator that must vote

One target proposer knowing the origin contact is insufficient: every honest
target validator must independently verify a foreign reference before voting.

Therefore DTX submission is refactored as one bounded semantic submission to
the target's current validator set:

- the coordinator attempts the same canonical control against the current
  target routes under one deadline;
- each reached validator learns the authenticated submitting node's return
  contact and records it as a bootstrap candidate for the referenced origin;
- identical semantic submissions remain coalesced by the existing digest and
  waiter machinery;
- success still means a certified target phase, not merely that one endpoint
  queued bytes;
- unavailable or Byzantine endpoints cannot turn uncertainty into refusal.

This is not one transaction per validator and does not create multiple DTX
records. It is bounded delivery of the same semantic record so a quorum can
perform the same independent validation. The existing endpoint-correlation cap
must remain derived from maximum participants times maximum validators.

The implementation delivers that contact without changing the ledger shape:
the coordinator starts one bounded concurrent delivery to each selected target
validator, DTX ingress retains the authenticated advertised endpoint, and each
reached validator records it only as a foreign-log bootstrap candidate. The
leader's endpoint-free consensus block remains unchanged.

Bounded semantic submit fan-out follows the same resource model as Complete
validation, which probes every current validator for
every participant under one shared deadline; the existing correlation cap is
derived from maximum participants times maximum validators for that reason.
Do not put endpoints in the ledger, consensus block, or DTX control body.

Fan-out widens how many validators see an authenticated request but does not
change its exposure class: every endpoint retains the same peer rate bucket,
worker cap, shape checks, semantic coalescing, and consensus validation.

### 4.4 Keep same-link replies, but do not make correctness depend on link life

Every request reply continues on the authenticated link that carried the
request. This avoids needless reverse dials for a response.

Foreign-history page pulls after the initial reply use the authenticated return
contact and the existing catch-up/foreign-log protocol. Do not tunnel a second
history protocol through the DTX codec. The physical QUIC connection may be
pooled and reused, but correctness must tolerate it closing immediately:
recovery redials by key and advertised contact, then re-verifies history.

Proof-scope closure must not erase the node contact. It removes only the proof
overlay/session. The new bootstrap association is bounded by the existing
foreign-log hint policy; certified ontology-route expiry remains owned by the
directory. The older global QUIC address-cache lifetime is unchanged and is not
silently reclassified as bounded by this work.

### 4.5 One generic candidate-validation lifecycle

The observed retained-candidate stall is fixed by making asynchronous validation a
total state transition:

- `valid` proceeds through the existing support path;
- deterministic malformed/certified-invalid evidence rejects;
- unavailable evidence returns `abstain`, clears the exact worker/monitor and
  validation latch, and leaves the immutable candidate eligible for redrive;
- worker `DOWN`, timeout, and stale result all converge on the same cleanup
  function;
- stale results are correlated by slot, block hash, parent token, worker PID,
  and monitor generation and cannot affect a replacement candidate.

After `abstain`, one generic local re-eligibility step on the **existing
consensus tick** retries without depending on another peer. When the retained
head candidate is still current and its validation fields are idle, the tick
re-enters the existing `support_or_validate/3` path. It does not inspect
why the previous attempt abstained and is not triggered specially by a route.

A later route/contact therefore becomes visible on the next ordinary tick, and
the same immutable candidate can commit without being re-signed, semantically
resubmitted, or re-proved. The validation guard still permits at most one
worker for the candidate.

## 5. End-to-end flow

For an origin A writing atomically to private participants B and C:

1. A resolves B and C using public directory data or its local private seeds.
2. Mutual TLS authenticates every contacted node. Each side may retain the
   other's advertised node contact as P; the new identity association used by
   this flow is retained only under the foreign-log hint cap.
3. The ordinary `::` scopes run `can_invoke/4`, execute Prolog, and seal signed
   plans.
4. A registers/activates Begin, returns internal `group_pending`, parks the
   caller by GroupRef, and closes the proof scopes.
5. The recovery coordinator submits canonical Prepare controls to the current
   validators of B and C. Each target validator associates the authenticated
   source key only as a bootstrap candidate for A.
6. Each validator independently asks the existing foreign-log verifier to prove
   the exact certified Begin. Directory routes are preferred; bootstrap node
   contacts only solve reachability.
7. Normal target consensus certifies Prepare. Decision, Finalize, applied proof,
   and Complete continue through the existing DTX state machine.
8. The caller is released only by the existing ordered Complete/outcome path.

No open proof scope, original browser, original proof worker, or manually
configured reverse seed is required after step 4.

## 6. Format impact

- **Ledger, transaction, certificate, plan, DTX control, and GroupRef:** no
  format change.
- **Prolog facts and ACL predicates:** no change.
- **Subscription declarations/follow notices:** no change.
- **QUIC link header:** no change; it already carries the authenticated return
  contact.
- **DTX endpoint request:** no format or semantic change; ingress retains the
  transport-owned contact beside the decoded request only as P.
- **Consensus block/payload:** no endpoint or route metadata, and no format
  change.

## 7. D/P/E classification

| Artifact | Class | Reason |
|---|---|---|
| DTX controls and certified history | D | Existing durable protocol, unchanged |
| Private seed configuration | operator input to P | Local bootstrap configuration, never consensus truth |
| Authenticated node contact | P | Existing volatile trusted-fleet reachability hint |
| Bootstrap candidate association | P | Untrusted, rebuildable source-selection hint under the existing foreign-log cap |
| Certified ontology routes/materialized foreign facts | P derived from D | Rebuilt only through the existing verifier |
| Validation retry timer/latch | P | Bounded process lifecycle state |
| Reactions/events | none in this closure | Subscription Slice 3 has not started |

## 8. Failure and security matrix

| Edge | Required result |
|---|---|
| Advertised endpoint is malformed | Reject before cache insertion |
| TLS key and header key disagree | Close connection; learn nothing |
| Peer advertises a dead endpoint | Retry/rotate; peer gains no authority |
| Peer claims to host the wrong ontology | Foreign-log anchor/history verification fails; no route promotion |
| Directory has an anchor conflict | Fail the whole identity lookup as today |
| Proof scope closes | Overlay is discarded; scope teardown does not mutate transport contacts or foreign-log hints |
| Request link dies after submission | Redial by authenticated key/contact; never re-prove the goal |
| Candidate arrives before a usable source | Abstain and remain revalidatable |
| Source appears later | Redrive the same immutable candidate |
| Origin coordinator crashes after Begin | Another current origin validator recovers and advertises its own authenticated contact |
| Target validator restarts | Volatile hints vanish; coordinator redrive or certified directory state reconstructs them |
| Foreign-log/cache restarts | Rebuild through the same certified history path |
| Byzantine first endpoint | Ignore malformed/uncorrelated reply and continue bounded candidates |
| All sources unavailable post-Begin | Keep recovering; caller retains `outcome_unknown`/GroupRef and must not retry the goal |

## 9. Performance and bounds

- No process per learned contact and no new unbounded route list.
- Deduplicate bootstrap candidates by node key and exact ontology identity
  under the existing foreign-log hint cap. One node key may occupy at most the
  existing directory namespace bound, so it cannot fill the global history
  budget by claiming arbitrary identities.
- Reuse the DTX participant cap, validator cap, correlation cap, and request
  deadlines. Foreign histories themselves have no numeric cap. The pre-existing uncapped QUIC
  address cache is neither expanded nor treated as the new association owner.
- Prefer an already-live authenticated connection, but never wait indefinitely
  for it.
- Coalesce simultaneous verification of the same identity/reference in
  `quod_foreign_log`; do not make each DTX voter build a second local cache.
- Submit fan-out is bounded by the current target committee and performed
  asynchronously under one deadline.
- No sleeping worker or `wait_until`; retry and route-arrival wake-up use
  messages/timers.

Metrics reuse current transport, directory, foreign-log, and DTX gauges and add
only the missing distinctions needed to diagnose this contract:

- bootstrap candidates active/evicted/rejected;
- DTX validation abstain and normal-path redrive;
- submit fan-out attempts, acceptance, refusal, uncertainty, and unavailability.

The existing foreign-runtime dashboard panel shows these gauges and fixed-label
rates. No ontology identity or peer-selected value becomes a metric label.

## 10. Implementation slices

### A — freeze evidence and pin the existing transport contract (implemented)

- Preserve the failing private A→B/C fixture and the exact retained-candidate
  state as a regression.
- Pin the existing `{NodeKey, AdvertisedEndpoint}` header shape, endpoint
  validation, TLS binding-before-delivery, and `no_learn` behavior in focused
  tests. Do not change its version.
- Record explicitly that the global QUIC address cache is trusted-fleet soft
  state without expiry/capacity eviction; do not claim otherwise or expand it
  in this closure.
- Freeze target-wide bounded semantic submit fan-out as required behavior.

### B — central source-selection refactor (implemented)

- Use one bootstrap-candidate API in `quod_foreign_log`.
- Retain candidates in the existing capped current-route-hint/history state; no candidate
  map beside it.
- Exact verification and continuous following project from the same source
  selector.
- Keep `quod_directory:validator_routes/2` strict and certified; do not weaken
  its result type to include guesses.
- All three route-selection/merge sites use that selector:
  the consensus reference-validation walk in `quod_simplex`, the follow lane in
  `quod_foreign_log`, and applied/recovery routing in the coordinator. The old
  caller-local merge helpers are deleted rather than retained for compatibility.

### C — DTX ingress and validation lifecycle (implemented)

- Preserve `Addr` from the authenticated
  `{{PeerKey, Addr}, InLink}` DTX ingress event. Pass `{PeerKey, Addr}` plus the
  exact referenced origin identity to the generic foreign-log candidate seam.
  The endpoint remains transport metadata and never enters the decoded control.
- Deliver the same semantic submission to the bounded current target validator
  set so every voter can receive a usable source hint.
- Validation cleanup/redrive is one total transition.
- The existing consensus tick re-enters the normal validation path for one
  still-current retained candidate whose validation state is idle.
- Remove obsolete/manual reverse-route workarounds and duplicate retry clauses.

### D — scope and subscription reuse (implemented)

- Authenticated origin contacts learned during scope open feed the same
  generic node-contact/candidate machinery where useful.
- Subscription followers automatically benefit from the same source
  selector.
- Do not change `::`, follow notices, runtime reactions, or subscription facts.

### E — gates and documentation (source gates complete; hardware pending)

- Focused transport, directory, foreign-log, Simplex, DTX, scope, and follow
  tests.
- Compile, full EUnit, CT, xref, Dialyzer, and diff check.
- Rerun the mixed 64-follow plus three-/four-ontology read/write DTX hardware
  test with no reverse seeds.
- Monitor warnings/errors and report proof latency, DTX phase latency, follow
  lag, route churn, verification retries, and resource bounds.
- Keep `inter-ontology.md`, `distributed-proof-plan.md`, and
  `ontology-subscription-plan.md` synchronized with the implemented selector,
  fan-out, and validation lifecycle.

Compile, full EUnit, the focused inter-ontology CT, xref, Dialyzer, and the
formatting check are green in the working tree. The mixed 64-follow hardware
run below remains pending and is not replaced by these source-level results.

## 11. Non-vacuous acceptance tests

1. A knows private B and C; B/C have no configured route to A. A three-party
   write commits and every target publishes exactly once.
2. The same test with multi-validator B/C proves every voting validator can
   verify A independently.
3. Close all proof scopes immediately after Begin handoff; DTX still completes.
4. Kill the original proof worker/browser after GroupRef checkpoint; recovery
   completes without re-proving.
5. Kill the origin coordinator after certified Begin; a different current
   origin validator completes the group.
6. Deliver a candidate before its authenticated source hint. It abstains,
   clears its validation latch, then commits after the hint arrives without a
   new semantic submission.
7. Wrong anchor, wrong key, forged return contact, outsider history, and stale
   committee evidence never advance validation.
8. A bad first route cannot prevent an honest later route from succeeding.
9. Restart target and foreign-log owners after dropping P state; durable DTX
   redrive reconstructs reachability and completes.
10. Two followers and a DTX verification for the same identity share one
    certified history/cache and bounded advancement lane.
11. Route/contact churn does not grow maps, workers, timers, correlations, or
    mailboxes beyond existing derived limits.
12. Hardware: 64 active follows plus a three-/four-ontology mixed read/write
    chain, private reachability, one origin crash after Begin, zero manual
    reverse routes, full reconvergence, and no warning/error residue.
13. The hardware report records DTX endpoint rate refusals separately from
    timeouts and Byzantine/malformed replies; bounded fan-out must not be
    misdiagnosed as random flakiness.

## 12. Explicitly rejected approaches

- keeping proof scopes open until Complete;
- requiring operators to configure reverse private seeds;
- putting endpoints or routes into DTX controls, blocks, or ontology facts;
- trusting a TLS peer's ontology claim without certified history;
- accepting one validator's verification on behalf of other voters;
- adding a DTX-specific history verifier or tunnelling a second history codec
  through the DTX endpoint;
- weakening `validator_routes/2` so unverified hints look certified;
- retrying by re-proving the user's goal;
- adding route-specific exception clauses instead of fixing the generic
  validation lifecycle.

## 13. Adversarial review checklist

The implementation review must answer these with code evidence:

1. Does semantic submit fan-out preserve endpoint correlation, uncertainty,
   and waiter coalescing without turning partial endpoint availability into a
   false refusal?
2. Does the foreign-log route-hint extension avoid a fourth
   selection path while retaining its current caps and exact-anchor checks?
3. Does the abstain/redrive transition cover every worker result,
   timeout, `DOWN`, stale result, and route-arrival edge without a second retry
   state machine?
4. Does any change duplicate `quod_directory`, `quod_catchup`, proof
   scopes, or the subscription follower?
5. Is the one-tick re-entry bounded to one current idle candidate and prevented
   from spawning duplicate validation workers?
6. Is every change internal P plumbing with no ledger, DTX, consensus,
   link-header, or endpoint-codec format change?
