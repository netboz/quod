# DTX latency and security-chain simplification plan

Status: Slice 0 is implemented, live-tested, and committed as `7b0d454`. The
closure review's safety correction is incorporated. Slice 0.5's inventory is
complete. Slice 0.6 is independently reviewed and committed as `c34f3c2`: the
browser contracts, shipped assets, stale documentation, owner-state metrics,
and Grafana panels are corrected without changing protocol behavior. Slice
0.7 is independently reviewed and committed as `b1045e0`. Slices 1 and 2 are
implemented and live on the nine-node hardware fleet in image
`0.7.95-no-scope-quotas`. The deployment was non-destructive: root and both
benchmark ledgers retained their anchors and heights. The endpoint caps,
normal apply polling, shared proof/attestation admission, claim-only origin
participant, blocking target-engine identity lookup, foreign-verification
population quotas, and router node/peer quotas are removed. Identical current
views coalesce at the one foreign-history owner even when caller deadline order
or route hints differ.

The final gates pass: full EUnit 1,352/0, `quod_ask_SUITE` 17/17, compile,
xref, dialyzer, and diff-check. Live signed remote reads complete 1,000/1,000
at concurrency 64: 117.33 proofs/s, p50 522 ms, p90 663 ms, p99 752 ms. At
concurrency 32 they complete 500/500 at 71.24/s, where the previous peer quota
completed only 48/500. A real target predicate completes 200/200 at concurrency
16, 31.58/s, p50 488 ms. All nine allocations have zero restarts and no live
warning/error/critical log entry after the tests.

Durable writes are still too slow for interactive use: 10/10 sequential remote
writes measured p50 2,643 ms and 0.38/s; 12/12 at concurrency four serialize at
0.37/s and p50 10,820 ms. The exact ledger timestamps show consensus commit is
only a few milliseconds. Aggregate hardware metrics over 22 writes attribute
about 17 ms per Begin, 462 ms per Prepare, 88 ms per Decision, 389 ms per
Finalize, and 350 ms per Complete. The catch-up servers themselves average
only about 1--3 ms per request. The remaining common-path cost is therefore not
consensus computation or disk serving: it is repeated orchestration and
certified-history/current-view verification around the five durable blocks,
plus the deliberate one-active-group queue at a source ontology. This is the
measured input for Slice 4, not a solved latency claim.
The Slice-4 architecture below passed adversarial plan review and was activated
by the coordinated clean re-found for 0.7.96. The transaction roles, shared
foreign-reference verification, one operation-recovery owner, effect hand-off,
Explorer rendering, fixed-stage metrics, and singleton-group deletion landed
together. Version 0.7.97 added bounded-page certified-cache replay. The 0.7.98
closure removes the last duplicate live-proof target submission: live callers
now wait on the same durable recovery owner used after restart, and identity
collection reports an impossible quorum immediately instead of waiting for its
silence deadline. Its local gates pass (EUnit 1,360/0, the ask and join Common
Test suites 22/22, xref, dialyzer, and diff-check). The hardware concurrency
benchmarks below remain the final release claim.

Version 0.7.99 retains each verified remote projection and DTX phase index
between checks instead of replaying a warm cache from genesis. A live
four-ontology write then proved the complete A -> B -> C -> D path correct:
34/34 signed groups committed the same operation in all four ledgers, with no
warning, error, or node restart. Performance is not yet acceptable. A warm
sequential run measured p50 3,475 ms and p99 3,635 ms. At concurrency four,
p50 was 16,113 ms and p99 17,200 ms. The source admission histogram recorded
72,114 ms of wait: 26 requests had no admission wait, while the concurrent
requests formed the expected one-active-group staircase. This is the measured
input for Slice 4.7 below; it is not a release performance claim.

The node-local policy work is deliberately gated on the existing physical-node
identity plan rather than inventing a temporary configuration authority.

The `0.7.103` working tree closes the last retained-control handoff gap found
by the hardware concurrency trace. Local and relayed controls enter the same
retained Simplex owner, one mailbox message coalesces controls already admitted
in that turn, and a busy leader retains rather than drops an authenticated
relay. DTX relays use the existing ordered QUIC FIFO and record their exact
volatile link-process placement in the retained row: unrelated progress cannot
enqueue duplicates, while link replacement or improved evidence re-drives the
same durable row once. No relay queue, polling timer, or second custody owner
was added. Coordinator waves now expose correlated OpenTelemetry parent/item
spans so the hardware run can separate actual endpoint work from parked time.
This paragraph is an implementation statement, not a performance claim; the
fresh `A -> B -> C -> D` measurements remain the release gate.

Decisions already fixed for review are: browser omission means the remaining
authenticated-session lifetime; authentication capacities start at 256/256;
foreign-history and catch-up active work start at 32 in their distinct owners;
arbitrary directory route/name/high-water population caps are removed rather
than renamed; a hosted set larger than 32 uses a coordinated bounded-record
format; and unrelated direct effects run in parallel conflict lanes through
the existing journal/namespace manager. The aggregate signed-custody policy is
node-wide and its minimal reservation owner is fixed below; its default remains
open. Also open are the proof/scope default 64, effect attempt
timeout/retry/heap values, and the four-active-directory-dial policy.

## 1. Objective

Reduce signed cross-ontology write latency without adding another executor,
ACL, verifier, transaction/custody owner, or recovery path. The minimal
node-wide byte accountant introduced below owns only aggregate reservation
tokens and policy projection; it stores no goal, transaction, queue, or
recovery state.

The fixed architectural rules are:

- Prolog remains the only application and authorization path.
- Every target keeps its ordinary `can_invoke/4`, OCC, plan, and consensus
  validation.
- A timeout is a final failure/recovery bound, never the normal way one process
  discovers that another process made progress.
- Local progress uses the existing Erlang process/message ownership. Remote
  progress uses the existing correlated QUIC channel.
- No success is reported from one untrusted node's observation.
- No fixed operational worker, correlation, queue, per-peer, or retry-count
  ceiling may reject an otherwise valid transaction. Existing ceilings on the
  end-to-end signed DTX path must be inventoried and either removed or moved to
  a named, dynamically owned policy that was explicitly approved. There is no
  hidden compiled default. Root's committed `effect_custody_capacity/1`
  policy, whose approved default is 64 and which supports `unlimited`, is the
  existing exception; it is not automatically the right owner for unrelated
  node-local or unauthenticated resources.
- A physical node is an ordinary `agent` instance of class `node`. The shared
  `quod:node` system ontology defines its class and policy vocabulary; it is
  not a table of physical nodes. Machine-specific memory/backpressure facts
  live beside the concrete instance in that node's dedicated ordinary
  ontology and key it by the local instance term. After slot 1, certified
  namespace/anchor plus that local term form the existing
  `agent_instance_ref/3`; their projection configures the existing Erlang
  resource owners. It adds no authorization path, policy service, or
  configuration shadow.
  This depends on Slices 2--3 of `doc/node-instance-identity-plan.md` and must
  not be approximated before that identity is live.
- Deterministic wire-size, term-shape, proof-depth, committee-size, and VM
  safety bounds are a different category. They remain only where every peer
  must enforce the same bound for safe decoding or consensus. This plan must
  name them explicitly; a derived per-operation maximum must not be reused as
  a global cap across concurrent operations.

## 2. Measured baseline and Slice 0

The first live signed `A -> B` write took about 1,616 ms. Four locally hosted
DTX phases were retained but not driven until the 300 ms maintenance tick.

Commit `7b0d454` makes local DTX endpoint admission call the existing
`keep_progress -> drive_retained_dtx` path immediately. It adds no protocol or
execution path.

Independent gates are green: focused Simplex 219/219, full EUnit 1341/1341,
`quod_ask_SUITE` 17/17, focused root-effect CT, compile, xref, dialyzer, and
diff-check. A live non-destructive deployment reduced the same class of write
to 692 ms. Every DTX control then reached proposal within 2--14 ms; the old
normal 300 ms wait was gone.

The remaining 692 ms contained roughly:

- 221 ms in seven actual consensus blocks; and
- 471 ms in proof, certificate/plan work, coordinator verification, apply,
  and the final reply.

The largest visible remaining interval was about 185 ms between target
Finalize and source Complete submission.

### 2.1 The `8` and `22` values

`8` was the value of `QUOD_DTX_ENDPOINT_MAX_WORKERS`. It was an arbitrary local
admission ceiling: the ninth valid endpoint request received `busy`. It was
neither a quorum rule nor a wire-format requirement. Slice 1 deletes it,
together with the public `max_workers` limit field and both population
admission checks. No replacement fixed default is introduced.

`22` is not a configured ceiling. It is calculated from the already-supported
64-validator committee: at most `floor((64 - 1) / 3) = 21` validators may be
faulty, so one source validator's applied-state check needs `f + 1 = 22`
distinct matching target-validator replies to guarantee that at least one came
from an honest validator.

That verifier does **not** ask one target node for 22 replies. The failure is
cross-committee contention: while source validators validate Complete, up to
64 of them independently probe the target committee, so one target validator
may receive up to 64 valid concurrent probes. The former cap of eight rejected
most of them. Yet the source needs 43 validators to finish their own 22-reply checks
and support Complete. A local arbitrary cap can therefore prevent a valid
protocol quorum from forming.

## 3. Current security chain

For a signed remote write, the checks are deliberately split by trust owner:

1. The gateway verifies the signed request before admitting work.
2. The agent ontology checks that the signing key is active.
3. At the first remote selector, the agent committee issues one proof-scoped
   identity certificate. Nested targets reuse that same certificate.
4. Each target verifies the certificate and runs its own `can_invoke/4`.
5. Each target seals its diff, OCC reads, effects, and authorization transcript.
6. The source commits Begin. Its validators independently recheck the current
   agent key and claim the stable operation id.
7. Each actual participant commits Prepare. Its validators independently
   recheck the target plan, target ACL transcript, and OCC state.
8. Source Decision fixes one commit or abort verdict.
9. Each participant Finalize durably applies or discards its prepared plan.
10. Source Complete is accepted only after source validators independently
    verify that every participant projected its Finalize. It publishes the
    transferable terminal outcome.

The repeated gateway/validator and proof/Prepare checks are not duplicate
authority: a gateway or proof worker may be faulty, so validators must not
trust its verdict. The identity-certificate quorum is not a ledger consensus
round.

## 4. Consensus-round audit

Today a foreign-only write with no source data dependency commits:

```text
Begin(A)
Prepare(A)       claim-only, empty source plan
Prepare(B)
Decision(A)
Finalize(A)      applies no source data
Finalize(B)
Complete(A)
```

### 4.1 Remove the claim-only source participant

The source `Prepare(A)` and `Finalize(A)` are redundant when A contributed no
diff, OCC read, or effect:

- Begin already validates the request and current agent key;
- Begin already durably claims the operation id;
- Begin already stores the result and creates the recoverable origin role; and
- the empty source Finalize publishes no data.

The resulting foreign-only chain is:

```text
Begin(A) -> Prepare(B) -> Decision(A) -> Finalize(B) -> Complete(A)
```

This is five consensus blocks instead of seven.

Implementation must split two concepts currently conflated by
`quod_dtx:participates/1`:

- the origin plan may exist only to carry signed-operation custody; and
- a DTX participant has real target material: a diff, OCC dependency, or
  effect.

The claim-only origin plan must not be deleted globally. A local signed
no-change operation still needs its ordinary, ACL-checked origin transaction.
Conversely, a remote no-op must never fall back to an A transaction that would
make A authorize B's predicate. B's authorization proof/read dependency must
make B the actual participant; absence of that material fails closed.

The manifest codec and phase reducer already accept one participant. The
remaining artificial minimum of two must be changed at all five exact seams:

1. coordinator Begin admission;
2. outcome construction (`participant_slots`);
3. public outcome decode (`valid_participant_slots`);
4. DTX endpoint public-status decode; and
5. `quod_client_result:valid_participant_slots/1`, shared by result
   normalization and canonical wire decode.

Each seam needs a non-vacuous one-participant test. Explorer rendering is not a
sixth validator. Activation requires a coordinated fleet restart, never a
mixed-version rolling change, because old binaries reject the new
one-participant terminal shape. It does **not** require a genesis re-found:
existing committed groups all have at least two participants and remain valid
under the widened decoder. No ledger purge belongs to this change.

If A has a real diff, OCC read, or effect, A remains a participant.

### 4.2 Keep the full group protocol only for genuinely distributed atomic work

Under the current contract these records are necessary when two or more
material/read-dependent ontologies must choose one atomic outcome:

- Begin freezes the exact operation and participant plans before any target
  locks.
- Prepare gives each target a durable ACL/OCC decision and lock.
- Decision prevents different participants from choosing different outcomes.
- Finalize orders publication/discard in each target ledger.
- Complete proves to any later reader that every participant applied the same
  decision, clears the origin role, and stores a transferable terminal result.

They are not evidence that a single material target needs a group. A singleton
has no second participant with which it can disagree, and its target's ordinary
transaction already provides the durable apply-or-reject outcome. Slice 4
therefore removes signed foreign singletons from this protocol while retaining
all five records for real groups.

Returning success for a real group at Decision could remove latency only by changing
`committed` to mean "chosen but perhaps not visible at the targets." That is a
different API and is not part of this plan.

### 4.3 Implemented source-participant fusion

When A contributes real material, Begin validates and prepares A's plan by
calling the exact Prepare policy/reducer; Decision applies or discards it by
calling the exact Finalize reducer. No source-local Prepare or Finalize control
is constructed, decoded, recovered, or committed. Remote participants retain
their ordinary Prepare/Finalize phases. This removes two source blocks without
removing or duplicating a check.

## 5. Remove normal polling after Finalize

The 185 ms tail is caused mainly by readiness discovery, not by useful work.
The coordinator asks whether each Finalize is applied; an early `not_found`
causes a 100 ms retry even though Prolog soon sends Simplex the exact existing
`{finalize_applied, GroupId, Slot, Generation}` message.

The safe change is:

1. Keep the existing correlated `{applied, ...}` endpoint request.
2. If its exact Finalize is locally committed but Prolog has not projected it,
   retain the request.
3. Wake it directly from the existing exact `finalize_applied` cast.
4. Run the same current-state read and produce the same endpoint response.
5. Keep the request deadline only for disconnect/failure cleanup.

No push event becomes evidence. The existing response verifier remains the
only verifier.

The former hard-coded inbound worker cap of eight was incompatible with the
cross-committee verification described in section 2.1. The implementation
keeps the existing endpoint worker as the single request owner instead of
adding a registry or waiter service. When the exact Finalize is committed but
not projected, that worker waits in `receive` for the existing
`finalize_applied` message. Simplex sends the message only to workers whose
request binds the exact group, certified reference slot, generation, and
verdict. The same worker, monitor, destination, and absolute request deadline
therefore own normal completion, caller death, link death, timeout, and
namespace termination. It then reruns the same current-state read and produces
the same response through the same verifier.

Finishing an endpoint request removes that endpoint row and detaches its
waiter only. It never removes a DTX control already signed and retained by
Simplex; that semantic custody continues recovery after caller or reply-link
death.

With that ownership exact, delete the fixed cap, public `max_workers` field,
population `busy` branches, tests, comments, and documentation. Do not replace
it with a configured *admission/refusal* default or another hidden constant.
Duplicate `{Peer, RequestId}` requests still correlate to their existing live
request; this is identity, not a population gate.

The outbound endpoint also has a per-hosted-ontology correlation ceiling derived
as `maximum participants * maximum validators`. That formula is the largest
request set for **one** operation, but using it as one cross-operation
admission cap in that ontology can still reject a second concurrent valid
operation. Remove that population
admission gate too. Keep the per-request protocol validation and the exact
correlation map; do not turn a single-operation shape bound into node policy.
The header above the constant correctly says the endpoint must retain one
worst-case operation's request set "without self-backpressure". The defect is
not that one-operation calculation; it is reusing the result across all
operations in one hosted ontology when another valid operation or endpoint use
overlaps.

### 5.1 Completed end-to-end capacity and deadline audit

Removing only the endpoint's `8` would repeat the original mistake at the next
module boundary. The completed audit traced one signed `A -> B` write from the
browser through proof routing, certified-history fetch, DTX custody,
coordinator, endpoint, and reply routing. It recorded every operational
population/deadline gate found with:

- its exact source and current value;
- what owns the protected resource;
- whether it is a consensus/wire/VM-safety bound or only local policy;
- the behavior when reached; and
- the planned removal or explicitly approved policy owner.

The inventory is complete for this path. Assignment is complete only when
every discovered item has a table row, a slice owner, and a non-vacuous test;
the formerly unowned effect worker is assigned below. No limit is deleted
before its resource has one exact owner and one cleanup path. Fixed operational
ceilings that can reject a valid signed DTX are removed only in the reviewed
slices below, or moved to an explicitly approved policy owner. Deterministic
byte, term, depth, committee, and VM-safety bounds remain.

#### Direct DTX and certified-history controls

| Source/control | Value | Behavior today | Decision |
|---|---:|---|---|
| removed `QUOD_DTX_ENDPOINT_MAX_WORKERS` | was 8 per hosted ontology | the ninth applied-state/current-view request got `busy`; Complete validation could prevent its own quorum | Slice 1 keeps the existing per-request worker owner and deletes the population cap, every population `busy` branch, and the public field |
| removed `QUOD_DTX_ENDPOINT_MAX_CORRELATIONS` | was 8 participants x 64 validators = 512 per hosted ontology | a second valid operation in that ontology could get `busy` after one worst-case operation occupied the map | Slice 1 keeps the exact correlation map and caller deadline and deletes only the cross-operation population gate |
| retained semantic DTX controls / waiters in Simplex | no compiled population count; canonical hard-batch bytes remain bounded | the existing owner retains ready/blocked controls and exact waiters by semantic digest | keep the one Simplex custody owner, canonical readiness/indexes, monitored waiter ownership, byte accounting, and one retire path |
| removed `QUOD_MAX_FOREIGN_PENDING` / `_PER_PEER` | was 32 per node / 4 per peer | certified-history work could get `busy`; one already-active identity separately returned `history_busy` | retain the one cache writer per identity; share concurrent current-view requests for that identity even when their route hints differ, and retain exact monitored ownership/deadlines instead of a population refusal |
| `quod_catchup:MAX_INFLIGHT` | 32 read workers per hosted ontology | excess certified-history pulls are silently dropped, so a valid caller waits the full 8-second pull timeout | keep the wire unchanged; replace the counter with owned request rows and the same approved named active-work default 32; excess reads wait and start on worker completion, while expired/dead-link rows finish once and never disappear into the client timeout |
| removed outer Simplex coordinator backoff | was a 16-count, 100 ms--3.2 second state checked by unrelated mailbox turns and the 300 ms consensus tick | delayed recovery and hid deterministic coordinator faults behind repeated restarts | the exact monitored DOWN now reconciles durable recovery immediately; impossible start/bootstrap state fails loudly, and no timer/count/status remains |
| removed coordinator progress retry | was 100 ms to a configured 5 seconds | rediscovered target/history progress by elapsed time | exact endpoint, certified-follow, directory-route, local-commit, and owner-registration messages now wake the parked coordinator; only request/wave silence deadlines remain |
| effect-journal active custody | Root policy default 64, dynamically settable or `unlimited` | a new effect-bearing DTX can be refused before custody | keep: this is the explicitly approved committed Prolog policy owner; document that `unlimited` still retains terminal rows and increases full-snapshot disk rewrite cost |
| effect execution | one journal worker per node plus one namespace-manager mutation worker/FIFO per node; no journal attempt deadline or heap kill; the manager's 15-second caller timeout does not cancel its worker | one wedged bridge blocks every later effect, then the namespace manager can move the same blockage downstream; the earliest repeatedly unavailable row can starve unrelated rows | keep journal custody/reconciliation, but make the existing namespace manager the sole per-namespace physical-mutation lane owner for journal effects, direct calls, and reconciliation; one manager finish path owns result/DOWN/deadline and different namespaces overlap |
| relay completed-result cache | 2,048 rows plus expiry | an authenticated redrive can lose its cached terminal reply by unrelated population trimming and repeat admission work | remove the count in Slice 0.10d; retain expiry and exact submission identity, and carry its bytes in the same node-wide reservation acquired before relay admission |

Other direct post-Begin controls are retained and named rather than mistaken
for node-wide admission quotas:

| Control | Value | Classification/decision |
|---|---:|---|
| Simplex signature worker | 2 seconds | per-attempt failure bound; keep, instrument, and wake progress by message |
| validator foreign DTX verification | 6 seconds | per-validation attempt bound; keep under durable recovery and measure |
| retained-control relay progress | link-up, leader/slot/committee, and exact ownership events | send once on reliable QUIC; the individual caller deadline is the final failure safeguard, never a timed normal-progress resend |
| generic consensus maintenance tick / Delta | 300 ms / default 1 second, application-configurable | fallback liveness, never normal DTX readiness discovery |
| maximum quorum rearms / pipeline depth | 3 / 1 | consensus-state shape, not transaction-population policy |
| per-peer consensus outbox / dial timeout | 1,024 / 15 seconds | transport liveness/backpressure; not a DTX phase owner and requires a separate transport review before change |
| current-view route candidates / applied-certificate probe endpoints | at most 64 validator keys and 2 current endpoints each / the shared key-resolver endpoint, those current candidates, and the exact Finalize-era fallback are deduplicated | the committee bound limits probe keys; transport authenticates the expected key, while endpoint hints affect reachability only and cannot add a signer or vote |
| recovery evidence / history | `2*N+3` = 19 at `N=8` / 5 entries | one-group recovery shape; keep and test at the maximum participant count |
| DTX endpoint request id | 128 bits | correlation/wire shape; keep |

These values do not reject a second operation merely because another valid
operation exists. They are nevertheless part of the completed timing audit so
future work cannot accidentally turn a fallback timer into the normal path.

The foreign-log has no cap on retained ontology identities, certified disk
histories, follows, or materialized projections. That is intentional and must
remain true. Its page bounds (256 entries, 900 KiB) and the 64 MiB verifier
heap kill are per-work-item safety bounds, not cache-population limits.

The outcome index's 4,096-row memory cache is also not an admission limit:
evicted outcomes remain in DETS and are loaded from disk. It affects speed,
not correctness or accepted population, so this latency plan does not remove
it.

#### Pre-Begin and adjacent controls

| Source/control | Value | Behavior today | Decision |
|---|---:|---|---|
| browser-generated request lifetime | hidden 30 seconds | every browser goal expires after 30 seconds even if the session lives longer | remove the hidden policy from the low-level signer; its caller supplies the signed expiry, clipped only by session expiry; the approved visible browser default is the remaining authenticated-session lifetime, with an optional shorter caller choice |
| browser agent namespace | 128 bytes | the browser rejects a server-valid 129--255-byte namespace | use the shared protocol value of 255 bytes and rebuild the client assets |
| browser unresolved-operation row | Base64 request at most 12,000 characters | the server's 16,819-byte request admission ceiling requires a 22,426-character unpadded Base64url admission ceiling, so some server-admissible requests cannot currently be journaled before a durable write | derive validation from the same request-format admission bound; do not add a row-count cap |
| browser live cursor map | no population cap; abandoned rows live until tab close | an expired/abandoned cursor can retain a tab-local request row | bind cleanup to signed expiry, terminal cursor reply, explicit stop, or tab lifetime; do not add a population cap |
| client router correlations / cursor routes | two independent maps, each capped at 256 per node | a valid signed request or cursor route can get `busy` | add reverse monitor/worker indexes only where current cleanup scans, then delete both population checks; do not replace the removed per-forwarder check with an unused counter |
| client inbound workers / per forwarder | 64 per node / 8 per authenticated forwarder | valid signed traffic is refused | existing worker-pid/DOWN ownership is already O(1); delete both admission checks and the O(n) per-forwarder count, retaining no counter unless a separately approved metric/policy consumes it |
| proof workers / scope workers / agent attesters | configurable; current compiled/deploy default 64 / 64 per hosted ontology; attesters consume proof capacity | proof/cursor returns `busy`, scope returns `ontology_busy`, and attestation returns `retry` | retain the present 64 while measuring it; moving it into node-instance policy is proposed but the default is not yet approved by Yan. It is not a memory reservation or acceptable per-goal usage. Instrument aggregate and per-goal memory; ordinary work approaching a 64 MiB emergency worker kill is a defect to fix. `unlimited` requires a separately reviewed aggregate-memory and MVCC-history owner |
| origin scope router total / per owner / per peer | node-wide and peer-wide quotas deleted; 8 per owner remains | valid concurrent proofs no longer compete for arbitrary router slots | implemented: exact monitored ownership already existed; retain 8 only because it is the signed proof-shape bound |
| target remote scopes per peer | deleted | valid authenticated scopes are no longer rejected by source concentration | implemented: the configured derivation-worker policy remains the explicit aggregate memory admission owner; the redundant peer counter and error path are gone |
| pending commands per scope | 64 | a 65th command in one scope is rejected | retain: it is derived from the per-proof invocation shape, not node-wide concurrency |
| inbound identity attestations | no population quota | every request has explicit request/link/attester ownership and final-deadline cleanup | implemented without adding another pool or counter |
| unsigned ingress queue | 512 rows / 64 per author / 2 blocks (512 KiB) / 7-second lifetime per hosted ontology | valid unsigned work is parked in FIFO order, then gets `busy` at a count/byte threshold or when the independent ingress timer expires | keep this existing pre-sign owner rather than add a queue, but delete arbitrary row/per-author counts with the custody slice; one reviewed byte owner and the signed pre-Begin deadline must govern admission/waiting, so moving pressure here cannot merely move the hard rejection |
| Simplex ordinary signed custody | no compiled row or aggregate-byte refusal threshold; depth/bytes remain observable per hosted ontology process | a signed submission remains owned until certified completion or its existing terminal deadline | retain the exact row in the existing Simplex custody owner; a later node-wide policy may govern pre-sign admission but cannot drop accepted signed custody |
| Simplex relay pending | no compiled population threshold | one exact relay row remains while its custody row needs placement | wake it on link/view/ownership events; no second queue, timed resend, or policy path |
| authentication challenge/session tables | 256 / 256 per node | new unauthenticated challenge or login can be refused | approved as named node-instance policies with defaults 256/256 and an explicit `unlimited` value; retain TTL cleanup and table ownership, with no hidden product quota or per-agent rate limit |
| directory hosted names per signed node record | 32 | a node cannot advertise a larger hosted set in one record | remove the semantic ontology-count limit in one coordinated directory format revision; stream/page a complete signed generation through existing bounded QUIC frames so transport bytes remain safely decodable without limiting how many ontologies a node may host |
| directory retained routes per ontology / route rows, known namespaces, and signer high-water rows | 8 / 2,048 per node | a new signed record or direct seed is refused with `namespace_full`/`directory_full`, potentially leaving that ontology unreachable; existing rows are not evicted by capacity admission | delete all count admissions, fields, and refusal branches with no replacement ontology/route count; keep the one `quod_directory` ETS projection, authenticated leases, expiry, exact identity, freshness, and memory/count metrics. Higher-level ontology discovery will feed this same projection later |
| directory resync sessions | 2,048 concurrent peer sessions per node | a valid resync can be refused when unrelated sessions occupy the map | remove the count with no replacement product limit; retain one correlated session per authenticated peer, 30-second expiry, exact replacement/cleanup, bounded pages, and usage metrics |

#### Routing and ontology discovery ownership

FIPA is a comparison here, not the routing owner. Its **Ontology Agent (OA)**
is an ACL-facing semantic service over explicit ontologies: it supports public
ontology discovery/access, semantic queries or updates, relationships/shared
ontology selection, and optional translation. It advertises that agent service
and its supported ontologies through a DF. It is not a live multi-validator
host-route table. The 1998 FIPA00006 revision is obsolete; the later
FIPA00086 revision remains Experimental and never became a FIPA Standard.
Quod claims conformance to neither:

- [FIPA Ontology Service (FIPA00086)](https://www.fipa.org/specs/fipa00086/index.html)
- [obsolete FIPA 98 Ontology Service](https://www.fipa.org/specs/fipa00006/OC00006A.html)
- [FIPA Agent Management](https://www.fipa.org/specs/fipa00023/)
- [FIPA Abstract Architecture](https://www.fipa.org/specs/fipa00001/)

The current FIPA Agent Management specification keeps these responsibilities
separate: the optional DF is agent/service yellow pages, the mandatory AMS is
agent white pages and AP lifecycle authority, and the MTS transports agent
messages. None is a general ontology-host route table. Quod therefore retains
the working term **Quod ontology-route resolver** for exact ontology identity
to verified-current-host resolution. A future Quod agent may expose an
OA-like semantic/discovery service and advertise it through the DF, but it is a
client/front end of that route resolver. It never owns or certifies live routes;
calling it `fipa-oa` would require the separate FIPA00086 ACL contract.

FIPA's abstract directory-service is useful lower-level precedent: agents may
publish/search directory entries containing transport descriptions, while a
transport description learned privately may be used without publication. In
Quod the analogous low-level function already exists as `quod_directory` plus
authenticated QUIC links. Its entries describe current ontology hosts rather
than FIPA AIDs, so this is an architectural comparison, not a conformance
claim and not a reason to add another directory.

Quod keeps these responsibilities non-overlapping:

| Information | Class and authority | Runtime owner |
|---|---|---|
| exact system ontology identities | D facts `system_ontology/2` in root | the namespace manager treats each row as desired exact identity; it can start/synchronise it only after the ordinary route mechanism supplies a verified host |
| public name to exact anchored ontology identity | ordinary D facts and rules in the future Quod public-discovery service; never an endpoint | that future service returns the anchored identity and may return provisional first-contact hints; it never returns or certifies a live route |
| eligibility to host an ontology | the target ontology's ordinary D lifecycle policy and ACL | existing lifecycle actions/effects; the resolver neither grants nor replaces this authority |
| permission to publish a directory advertisement today | exact namespace-to-node-key deployment allowlist in `quod_directory_auth` | `quod_directory_control`; this existing bootstrap authority is not the target ontology's hosting ACL and must not be silently described as one |
| current host endpoint, reachability, lease and freshness | P only | the existing `quod_directory` ETS indexes plus the existing QUIC link pool |
| private first contact | scoped P bootstrap input | a provisional direct seed in that same directory until authenticated identity confirmation; never durable authority or a second resolver |

The target architecture is that every node keeps root and every root-listed
system ontology synchronised from startup. “Keep connected” means preserving
their existing namespace runtime and its ordinary consensus/feed connections,
not inventing one special socket or bypassing route verification. A
`system_ontology/2` row names desired identity only: it neither proves which
node hosts the ontology nor authorizes an advertisement.

The current tree does not yet realise that target automatically. It learns a
system ontology's first route only when the existing exact deployment
allowlist admits a signed system advertisement or when an operator supplies a
private first contact. The shipped deployment currently enables shared
publication for root explicitly; reading `system_ontology/2` cannot manufacture
the missing route. Slice 0.10f closes this bootstrap gap through the same
directory and QUIC path. Until that slice lands, the deployment allowlist
remains the honest advertisement authority; it must later be replaced in one
coordinated change, never run beside a second Prolog-derived authority.

System ontologies bypass only future public-name discovery: root already
provides their exact anchored identities. They still use `quod_directory` to
verify and select current hosts, and use the ordinary namespace, consensus,
feed, and link owners once joined. They do not depend on a DF, AMS, OA, or a
second resolver.

For every other ontology, callers continue to name the ontology, never a
physical node. Higher-level discovery/registration belongs to the future Quod
public-discovery service planned separately in `doc/agent-fipa-plan.md`. It may
supply an anchored identity and provisional contact hints. Those hints enter
the existing directory and become usable only after the directory's normal
identity, host, freshness, and link verification; they are not authoritative
routes. `::`, subscriptions, certified following and DTX continue to read the
one directory projection directly. A cache miss may later trigger
asynchronous public discovery and wake the same existing request owner, but a
proof never calls a second route store or performs a recursive Prolog route
lookup.

This latency plan does not implement that future public-discovery service and
must not delete or narrow today's system signed-announcement/private-contact
mechanisms before their replacement exists. It only removes arbitrary
population limits and gives the current directory format enough room to
represent the hosts already supported by Quod.

The current direct-seed API is retained only as the primitive for a private
invitation or first contact. This latency work does not turn it into durable
network policy. Today a configured seed is rebuilt on restart, a dynamically
added seed is volatile, provisional/confirmed rows have no expiry, and a
conflicting confirmed identity is not replaced; there is no removal API.
Explicit policy-driven lifetime/removal/replacement belongs to the future
private-discovery slice, and no new `remove_direct_seed` contract is claimed
here. Endpoints never enter ontology facts, subscriptions, or public-discovery
durable facts.

Removing the 32-name record limit is part of this same ownership correction.
One authenticated hosted-set generation may span as many bounded frames/pages
as required. Each signed manifest/chunk is bound to the signer node key,
endpoint, epoch, sequence, generation digest, and position. The control owner
keeps at most one current incomplete generation per signer identity by
superseding an older incomplete attempt; that is correlation state, not a
network population limit. Missing, stale, duplicate, reordered, or
wrong-digest chunks never advance signer high-water, renew the old route
lease, or replace the live generation.

Only after canonical ordering, uniqueness, completeness, signatures, and the
full digest verify does `quod_directory` stage the new rows and flip one active
generation marker. Readers filter on that marker, so they see either the old
complete generation or the new complete generation, never their union. Old
rows may be reclaimed after the flip. `quod_directory_control` retains and
relays only completed manifests/chunks for resync; incomplete staging is
discarded on expiry or restart and is never advertised as current. There is no
ontology-count or page-count product ceiling. Byte/frame/decode bounds and
correlated page ownership remain because they protect one untrusted input,
not because they limit the network.

#### Physical-node resource policy

The shared `quod:node` ontology defines the vocabulary and the reusable Prolog
rule which validates a resource/value pair; it does not store one fleet-wide
value pretending to be machine-local policy. Each enrolled physical node
stores ordinary D facts in its own dedicated ontology, keyed by its local
stable instance term, for example:

```prolog
node_resource_policy(
    NodeInstance,
    Resource,
    Value
).
```

`Value` is a non-negative integer or the explicit atom `unlimited` only for a
resource whose owner supports that meaning. The node accepts a projection only
when the fact comes from its certified ontology and names the exact local
instance. The projection combines that instance with the certified namespace
and post-genesis anchor to form the node's exact `agent_instance_ref/3`; genesis
never tries to contain its own not-yet-known hash.

The node ontology does not inherit `quod:node` rules. Its immutable genesis
therefore contains one founding `state_handler/4` declaration and the
hash-pinned governed projection bridge manifest. A normal policy-changing
action in that ontology uses the ordinary `::`/DTX proof path to call the
shared `quod:node` validation rule, then stages and commits the local D-fact
diff through the normal transaction path. No E effect changes D.
The founding handler later reads only the already committed local facts and
calls the one projection bridge; runtime convergence never performs a foreign
`::` call. The bridge defensively validates the ground term shape and certified
execution context, then sends the value to the existing resource owner. It
does not decide ACL or policy and is not a second validator or dispatcher.

Each existing Erlang owner consumes only its own projected value. There is no
node-public-key fallback, app-environment shadow, generic policy service, or
second ACL. The handler and bridge are part of the reviewed node-ontology
genesis template; dynamically asserting another handler never activates it.

Node-ontology genesis carries the approved initial facts. A normal signed
transaction under that ontology's ordinary ACL changes them. Reducing a value
never evicts an existing session, row, or worker; it only prevents new work
from starting until usage falls. Raising it or selecting `unlimited` wakes
already-owned waiting work. Missing, conflicting, or malformed policy makes
the affected new admission/execution surface explicitly unavailable and logs
the reason; it never silently selects a compiled fallback. Existing accepted
durable work remains in custody.

One bootstrap dependency must be resolved before this policy controls effect
execution: creating the first node ontology is itself a root lifecycle effect.
The implementation must not disable that effect while waiting for policy from
the ontology it is creating. Slice 0.10a therefore includes a separately
reviewed durable bootstrap policy in root genesis for only the resources
needed before the exact node ontology is available, explicitly including the
node-wide ingress-byte policy and effect-attempt policy. When the certified local
node projection becomes ready, one explicit handoff atomically replaces that
bootstrap value for the resource; the two sources never compete and loss of
the node projection does not silently fall back. Exact bootstrap values remain
open decisions with the custody/effect values in Slices 0.10d--e.

The approved initial facts in this plan are:

- `client_auth_challenges = 256` per node, dynamically changeable or
  `unlimited`;
- `client_auth_sessions = 256` per node, dynamically changeable or
  `unlimited`;
- `foreign_history_workers = 32` active writers per node, with additional
  owned claims waiting in `quod_foreign_log`; and
- `catchup_read_workers_per_ontology = 32`, with additional authenticated
  request rows waiting in that ontology's existing catch-up owner.

Those two history values deliberately remain separate policies and pools even
though both initially equal 32. Authentication retains TTL/pruning and typed
capacity errors; these are memory policies, not rate limits or per-agent
quotas. The proof/scope-worker value 64 remains a measured proposal pending
Yan's approval. The aggregate signed-custody byte default (but not its fixed
node-wide scope/accountant), directory dial scheduling policy, and effect
attempt timeout/retry/heap values also need reviewed decisions below.

This projection depends on the real physical-node enrollment and binding in
Slices 2--3 of `doc/node-instance-identity-plan.md`. Policy-dependent activation
waits for that work; no temporary facts keyed only by a node public key are
allowed. The contract/client fixes, retained-control refactor, cap-removal-only
directory work, and deadline plumbing do not need that prerequisite. Worker
policy activation for certified history, authentication, custody, and effects
does.

The directory audit also found a 30-second route lifetime, 128 records per
resync page, and 2,048 resync sessions. The first two are liveness/per-message
work bounds and remain. The session count is a population refusal and is
removed in Slice 0.10c only after the existing authenticated-peer correlation,
expiry, replacement, and cleanup path is pinned by tests.

Cold-route and optional-effect work adds these adjacent timing/resource owners:

- directory control schedules four concurrent dials through an existing FIFO,
  retries after 1 second, gives a dial 11 seconds and root-peer proof 5 seconds,
  renews after 10 seconds, rejects more than 128 configured root contacts,
  throttles resync initiation for 5 seconds, and expires a resync session after
  30 seconds. Slice 0.10c removes the contact/session count refusals and assigns
  the dial scheduler's remaining policy decision;
- `quod_foreign_log:route_hints/2` has a separate 1-second owner call, while
  verification waits the requested worker timeout plus 1 second of outer
  cleanup grace; and
- effect-journal calls use 5 seconds, `await` clips even `infinity` to 60
  seconds and then returns `outcome_unknown`, and reconciliation retries from 1
  to 30 seconds forever. The journal releases one effect worker at a time; that
  worker currently has no deadline or heap kill, so one wedged bridge can stall
  later effects without losing custody.

These controls stay visible in the route/effect policy closure slice. The
latency benchmark may separately report warm-route/no-effect results, but the
plan may not call the whole browser-to-terminal path closed while omitting the
cold-route or effect-bearing variants.

The audit separately classified the explicit protocol-shape constants: 64
validators, eight proof scopes/DTX participants, proof depth eight, 256 KiB
blocks, the 1 MiB transport frame, and the bounded signed-request, result,
scope, DTX, term, token, symbol, diff, read-set, and effect encodings. They are
not node-wide concurrency quotas and are retained by this latency work. Their
bounded encoding/consensus/VM roles are real even when an exact numeric choice
may be historical; changing one requires a coordinated protocol review rather
than a local tuning patch.

For exact retained boundary values, the shared headers/code remain the single
source of truth. The audited client/wire safety set currently includes: 4 KiB
authentication JSON; 16,819-byte raw signed-request and 23,452-byte HTTP JSON
admission ceilings; 512 KiB result and 528 KiB result envelope; a scope envelope derived from the largest exact signed operation submission plus bounded scope metadata (currently 271,488 bytes);
20,000 decoded term nodes, depth 64, and 1,024-byte symbols; at most 64 new
symbols per authenticated material payload, 16,384 cumulative client-created
atoms per VM lifetime, and 100,000 atoms of VM headroom. Challenge lifetime is
60 seconds, session lifetime 10 minutes, pruning 30 seconds, and auth calls 5
seconds. Optional client rate policy remains off by default. These are
decode/VM/security bounds or lifetimes, not per-agent product quotas.

The named per-operation shape bounds are:

- `QUOD_MAX_INVOCATIONS_PER_SCOPE = 64`;
- `QUOD_MAX_ROUTER_PENDING_PER_SCOPE = 64`, derived from the invocation bound;
- `QUOD_MAX_PROXIES_PER_PROOF = 8 * 64 = 512`;
- `QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF = 1024`; and
- `QUOD_MAX_ANSWERS_PER_INVOCATION = 10000`.

They bound one proof/scope/invocation's encoded shape or correlated runtime
work rather than node-wide concurrency; not all five are signed fields.
`QUOD_MAX_PROXIES_PER_PROOF` uses the same multiplication pattern as the
endpoint correlation constant, but its scope is correctly one proof. The
audit therefore keeps these values in this work and records any future change
as a protocol/VM-safety review, not a capacity shortcut.

The named per-worker VM-safety bound is
`QUOD_SCOPE_WORKER_MAX_HEAP_BYTES = 64 MiB`. It hard-kills one runaway scope
worker and is also reused by foreign-log verification workers. It does not cap
aggregate node memory or replace the configurable proof/scope-worker policy.
Current-view participant/quorum probe children have no equivalent heap option;
removing their global endpoint gates therefore requires an aggregate
probe-memory owner or measured proof that their bounded state is sufficient.
Any policy change must account together for all of these processes and the
MVCC history pinned by active proofs.

#### Deadline ownership found by the audit

There are exactly two intended **transaction** lifetime owners, separated by
durable Begin. Challenge and session lifetimes precede a signed transaction
and remain independently owned by authentication; only signed-goal
admission/materialization calls consume the signed request budget.

- **Before Begin:** the signed request's absolute expiry owns proof, remote
  scopes, identity probes, and attestations. Today the browser's hidden 30
  seconds, client-router 60 seconds, Prolog proof/scope 60 seconds, scope-step
  and identity/attestation 30 seconds, and several 5-second internal calls
  compete with it: some shorten the request, while others can outlive an
  earlier signed expiry. The refactor must thread one remaining budget through
  router validation/wait, proof kill timer, scope lifetime/step timer,
  identity probe, inbound attestation, and internal auth/router calls. A named
  proof-memory safety policy may refuse an excessively long reservation, but
  it may not silently change the signed request's meaning.
- **After Begin:** client/session expiry never cancels accepted recovery. The
  durable coordinator owns retries until a terminal result. Each current
  attempt currently uses a 5-second command timeout; endpoint/current-view
  workers cap one attempt at 30 seconds; certified-history pages use 8 seconds;
  and current-view cleanup reserves 1 second for mailbox cleanup. These are
  per-attempt failure/cleanup bounds, not an operation deadline.

Progress messages wake work immediately on both sides; timers remain failure
or cleanup bounds. The outer Simplex owner has no backoff status, counter, or
time comparison: the exact monitored DOWN reconciles from durable state in the
same mailbox turn. The coordinator has no progress retry scheduler either;
temporary endpoint/history unavailability stays inside its exact parked work
and resumes from owner notifications. Impossible start or certified-Begin
bootstrap state fails loudly instead of entering an endless delayed loop.

#### Correctness and documentation drift found during the audit

Before protocol optimization, one small closure slice must:

- align the browser's namespace and operation-journal validation with the
  shared server format and rebuild its assets;
- keep the pure request encoder's existing explicit absolute-expiry input, but
  leave the exported signer contract unchanged until Slice 0.11 removes every
  competing shorter server deadline in the same deployment;
- correct `doc/client-authentication-plan.md`, which still claims a 64-row
  browser journal although the implementation intentionally retains all
  unresolved operations;
- remove obsolete registration/typed-command text from `config/quod.conf` and
  the obsolete registration wording in `quod_rate`;
- correct `doc/network-directory-plan.md` claims that local route limits are
  deployment-configurable and that the 5-second resync throttle is an
  announcement rate;
- remove the nonexistent authenticated-DTX `16 requests/second, burst 32` and
  stale self-throttling claims from `doc/distributed-proof-plan.md`; and
- correct `doc/durable-lifecycle-effects-plan.md`, which claims a total journal
  byte ceiling that the implementation does not have.

These are fixes to existing contracts and documentation, not new execution or
authorization paths.

## 6. Keep the Complete preflight, then carry its certificate

The coordinator checks participant application before submitting Complete.
For each prepared remote Finalize, it freezes the committee certified by that
exact Finalize and collects `f + 1` signatures over one exact applied
statement. The resulting certificate is carried with the Complete proposal in
the existing ephemeral validation sidecar, outside the semantic block hash.

The coordinator collection is still a liveness preflight: without it, an
unready Complete can enter the origin consensus slot, repeatedly abstain, and
delay unrelated origin work. Authority remains local to every source
validator: each verifies the sidecar certificate against the exact certified
Finalize evidence before voting. Validators never trust the coordinator's
verdict and never start another target fan-out.

The one path is therefore:

- use one coordinator-side applied-certificate collector for all prepared
  remote targets;
- wake each target request from actual apply progress as described above;
- retain the resulting portable certificates in the coordinator's volatile
  recovery snapshot;
- attach them to the existing proposal-validation sidecar when submitting the
  deterministic Complete v3 record; and
- make every source validator verify those signatures and bindings locally,
  with no target network request in validation.

Certificate construction and local verification share one statement format
and one signature-verification owner. The certificate binds the network,
target identity, exact Finalize-era committee id, group, Finalize reference,
group generation, and verdict. `FinalizeRef` already fixes the slot whose
durable applied floor was crossed, so no moving `AppliedFloor` value is copied
into the statement. A later committee change cannot invalidate this historical
evidence.

Complete itself remains
`{quod_dtx_complete, 3, GroupId, DecisionRef, FinalizeRows}`. The particular
`f + 1` responders depend on arrival order and therefore must never affect the
record digest or block hash. Replay and catch-up validate the committed
Complete and its origin QC without the ephemeral sidecar.

Deleting the preflight is allowed only after proving that an unready retained
Complete cannot monopolize origin consensus.

An unready Complete would consume proposal attempts on re-drive, occupy the
consensus barrier, and use one of the nine retained-control slots. These are
related but distinct failures: the preflight prevents unready Complete from
entering retained consensus work; refactoring/removing the nine-row cap stops
unrelated valid controls receiving `busy`. Keep both fixes independently.

## 7. Parallel work that is independent

The coordinator is an Erlang process but currently executes one blocking
planner command, waits, then replans.

The planner must state dependency explicitly:

- Prepare commands remain canonical and sequential. Parallel lock acquisition
  would reintroduce cross-group deadlocks.
- After certified Decision, participant Finalizes are independent and run
  concurrently.
- Applied preflight checks are independent and use the existing concurrent
  verifier.
- Only the coordinator parent validates replies and merges certified evidence;
  workers own no protocol state.

Do not mix proof sealing/attestation scheduling into this slice: it was not the
measured bottleneck and would require a second gather abstraction outside the
DTX planner. Profile it later before planning it.

## 8. Security checks that remain

| Check | Keep? | Reason |
|---|---:|---|
| gateway request signature | yes | rejects bad work before proof allocation |
| source active-key proof | yes | identifies the agent |
| proof-scoped identity certificate | yes | lets every remote target verify identity without trusting one source node |
| target `can_invoke/4` | yes | only the target decides permission |
| Begin validator key/operation check | yes | the gateway/proof worker is not trusted by consensus |
| Prepare validator ACL/OCC replay | yes | the plan witness is not trusted by consensus |
| phase certified-reference verification | yes | one endpoint reply cannot invent a committed phase |
| claim-only source Prepare/Finalize | no | Begin already owns the claim; the plan changes no source state |
| coordinator applied preflight | initially yes | availability gate, not authority |
| Complete validator applied check | yes | Byzantine-safe terminal proof |

The coordinator may need to fill the existing certified foreign-history cache
to obtain a target's exact Finalize evidence. Later calls reuse that owner.
This is not a consensus round. Source validators receive that exact evidence
through the same proposal sidecar and verify it through `quod_foreign_log`;
they do not add a second history cache or contact the target again.

## 9. Slices

### Slice 0 -- immediate local progress (complete)

- retained the tested `keep_progress` change;
- pinned it with the direct state-machine regression; and
- committed it independently as `7b0d454` after review.

### Slice 0.5 -- capacity and deadline ownership audit (complete)

- traced the browser-to-terminal path and completed section 5.1's tables;
- separated protocol/VM-safety bounds from local population policy;
- recorded the recommendation to retain proof/scope-worker default 64 and the
  64 MiB per-scope/foreign-worker kill because active proofs consume memory
  and pin MVCC history, while leaving that default pending Yan's approval;
- found the catch-up server's silent 32-worker drop, the foreign-log's
  `32/4` plus `history_busy`, and the browser/server validation mismatches;
- preserved separate pre-Begin and post-Begin lifetime owners; and
- scheduled every operational-cap removal only after exact ownership and
  cleanup, rather than applying isolated constant changes.

### Slice 0.6 -- contract correction and closed-label observability (complete)

- define one shared JavaScript protocol-limit owner used by agent references,
  request encoding, and the operation journal; fix the namespace and maximum
  journal-row contracts without duplicating `255`, `16819`, or `22426`;
- keep the pure internal request encoder's absolute expiry explicit. Only the
  shared-limit owner, encoder plumbing, and internal fixtures may land here;
  no exported high-level API accepts an optional expiry yet. Add/export the
  caller override and session-lifetime omission only in an atomic deployment
  with Slice 0.11, when every shorter server-side truncation and
  `REQUEST_TTL_MS = 30000` are deleted. Until then neither library consumers
  nor the UI can request a lifetime the server does not honor. The atomic
  activation allows an earlier caller value and clips a later one once at
  session expiry in one tested seam;
- rebuild/test both consumers of shared client code (`client` to
  `priv/client`, UI to `priv/explorer`) and byte-compare both shipped asset
  trees with clean builds;
- correct every stale document/config/comment listed in section 5.1;
- reuse existing proof/scope-worker and consensus-custody gauges; add only
  missing peak, duration, and owner-state signals for retained controls,
  endpoint requests, catch-up reads, and client/scope routing. The existing
  foreign-history owner exposes its current verification, page-pull, cached
  history, and byte state here. Its exact owner-lifetime peaks and request
  durations land with Slice 0.8's canonical caller rows, where the timestamps
  and retirement result already belong; do not create temporary shadow state,
  a metrics-owned lifecycle, or fake zero-valued peaks in this slice. Terminal
  counters and durations describe rows explicitly retired by a live owner;
  process restart resets that volatile owner and never invents a terminal
  result. For `quod_client_goal_router` outbound/inbound rows, `completed`
  means that the worker returned normally after replying; it is not a claim
  that the remote goal or transaction succeeded. Those outcomes remain owned
  by the existing goal/transaction result paths; and
- use only bounded labels such as component, state, phase, and result. An
  established local hosted-ontology label remains allowed in existing metric
  families; arbitrary target ontology, peer, agent, goal, request id,
  executor, and failure payload never become labels.

This slice intentionally corrects client contract behavior, but changes no
server consensus, proof, ACL, verifier, recovery, or work-admission behavior.
"Closed-label" limits metric vocabulary only; it imposes no new workload
limit.

### Slice 0.7 -- one retained-control owner

This slice changes local custody and scheduling only. It changes no ledger,
wire, control, certificate, signing-journal, ACL, reducer, or verifier format,
needs no genesis re-found, and introduces no process, store, queue service, or
second authority.

#### State and ownership

- Keep semantic DTX custody inside the existing Simplex process. Replace its
  loose `dtx_submissions` map with one private `#retained_dtx{}` sub-state,
  still owned and mutated only by that process. The sub-state contains the
  canonical digest-to-row map, ready and blocked `gb_sets`, an endpoint-worker
  pid-to-digest reverse index, and the current exact envelope-byte total. It is
  a bundled invariant, not a new runtime owner.
- Keep one row per canonical semantic record digest. The row retains the
  current signed control/envelope, GroupId, scheduling `inserted_at`, metrics
  `observation_started_at`, exact envelope bytes, placement,
  and a set of live endpoint-worker waiters. A duplicate semantic request
  attaches its distinct live worker to that row; it never signs or stores a
  second envelope.
- Order both placement indexes by `{inserted_at, Digest}`. Ready selection is
  `gb_sets:smallest/1`, so unrelated map population no longer causes a full
  sort. A blocked row keeps its original order when it becomes ready. A real
  re-sign retains `observation_started_at` but deliberately receives the new
  scheduling `inserted_at`, preserving the behavior pinned in Slice 0.6.
- Keep the registry volatile and rebuildable. The signing journal remains the
  subordinate anti-equivocation owner: it durably stores sequence floors and
  per-GroupId pending Begin bodies/envelopes, never this registry or later phase
  rows. Startup inserts each recovered Begin through the same registry helper;
  coordinator/replay state and authenticated remote retry reconstruct later
  phases through normal submission. No volatile row is falsely described as
  crash-durable.

#### Historical readiness decision (superseded by §4.7.7)

The bullets in this subsection record the original singleton implementation
and are non-normative. The implemented contract is the multi-group projection,
exact conflict index, apply-fence map, and wait-die readiness in §4.7.7.

- Replace the boolean `quod_dtx:proposal_allowed/2` scheduler hint with one
  pure `proposal_readiness/2` result. Its phase table was derived from the
  then-existing singleton projection. The certified reducer remains final
  authority; readiness only decides retention and proposal scheduling.
- Preserve the existing certified direct-abort exception through that same
  phase table. Do not add a Simplex special case for it. A generated test
  crosses every DTX phase with every reachable local protocol/gate shape and
  compares the result with the reducer before and after the exact apply
  acknowledgement: every `ready` row must be reducer-admissible, and the
  deliberate local `{blocked, apply}` hold is pinned separately so scheduler
  and apply semantics cannot drift or be mistaken for identical authorities.
- Compare the same fixtures in the reverse direction too: every transition
  the reducer can accept must be `ready` or an explicitly enumerated local
  apply hold, never `stale`. In particular, a same-group Prepare or Complete
  waiting behind earlier local apply work is `{blocked, apply}`, while a
  same-group Decision remains ready because its reducer admission does not
  depend on that fence. A dual-role Finalize becomes ready only after its
  source Decision is committed.
- Let one Simplex `retention_disposition/3` add the then-existing replay-owned
  completed-group exclusion to that result. A completed group is stale;
  otherwise a future role-acquisition Begin/Prepare may be retained as
  blocked. Decision, ordinary Finalize, and Complete for an unrelated group
  remain stale rather than occupying custody forever. This is the only broader
  retention rule and contains no duplicate phase table.
- Use `proposal_readiness/2` in ready selection, the record-specific DTX
  consensus barrier, and the already-existing relayed-leader delivery path.
  Delete every production call to the old boolean helper rather than retain a
  forwarding wrapper.
- Reclassify retained rows once when a pure readiness fingerprint changes,
  before `drive_retained_dtx` in the existing `keep_progress` tail. The
  fingerprint included the committed DTX projection and completed-group cursor; this one
  seam covers committed projection changes, exact `finalize_applied`, replay,
  and recovery. Initial insertion and re-sign use the same placement helper.
  Do not scatter event-specific reclassification branches through callbacks.

Historically, `{blocked, apply}` meant that the local committed projection had
pending material apply work preventing this phase from being driven until the
exact apply acknowledgement. It did not describe a
Complete whose *remote* participant preflight has not passed; that remains the
existing verifier path in section 6.

`stale` is terminal for this Simplex copy: use it when the exact record is not
proposable now or after the exact local pending-apply acknowledgement. Every
such local apply condition must be represented by a `{blocked, _}` result so
custody is preserved rather than refused. Other protocol progress wakes from
the authenticated relay's exact link, leader, slot, committee, or ownership
events rather than duplicating cross-node custody in this registry.

#### One mutation and finish path

- Route new retention, duplicate attachment, restored pending Begin,
  re-signing, placement changes, waiter detachment, committed resolution,
  deterministic refusal, and explicit live-owner admission/binding retirement
  through registry helpers that update the row, its one placement index,
  waiter reverse index, and byte total atomically in the Simplex turn. Process
  shutdown still emits no synthetic terminal result, as Slice 0.6 specifies.
- Retire by semantic digest through one idempotent take function. It removes
  the row and its exact placement key, removes every reverse waiter entry,
  decrements bytes once, emits the existing closed-label terminal metric once,
  and releases each still-live endpoint worker once. A later worker `DOWN`,
  timeout, duplicate commit, or stale reply then finds no ownership and is
  inert.
- Delete the unused exported `submit_dtx/3` wrapper and its raw
  `{submit_dtx, Record}` gen_statem call clause if the final pre-edit sweep
  still finds no production consumer. All real local and remote submissions
  already use `dtx_endpoint_local/4` (including the ephemeral validation
  sidecar) or the authenticated DTX endpoint. This
  leaves one waiter shape—monitored endpoint worker pids—and avoids preserving
  an unmonitorable compatibility path merely to support the new registry.
- Detach a dead/timed-out endpoint worker in O(1) through the reverse index.
  Do not scan every retained row and do not remove the semantic row merely
  because it temporarily has no observer; durable DTX recovery continues.
- Derive current/peak retained, ready, blocked, waiter, and envelope-byte
  values from this same sub-state. Add only `ready` and `blocked` to the
  existing closed owner-state vocabulary; add no metric family or unbounded
  label, and preserve `ready + blocked = retained` as a tested invariant.

#### Barrier and deletions

- The ordinary consensus barrier remains the OR of the authoritative durable
  DTX lock, an in-flight barrier block, active DTX validation, and a non-empty
  *ready* index. A parked future row alone is not a barrier. Do not weaken the
  durable lock merely because no local row is currently ready.
- The record-specific DTX barrier uses the same canonical readiness result, so
  a same-group ready Decision/Finalize can pass its legitimate durable lock
  while a stale or locally apply-blocked record cannot.
- After the tests below pass, delete only the two retained-control refusals:
  the `?QUOD_MAX_DTX_PARTICIPANTS + 1` registry-population guard and the
  one-waiter `add_dtx_waiter` `busy` branch. Also delete the whole-map oldest
  sort, waiter list scan, any-row retained barrier, old direct-map mutations,
  obsolete test seams, comments, and documentation. Do **not** delete the DTX
  endpoint worker/correlation `busy` responses in this slice; their distinct
  ownership refactor and removal belong to Slice 1.

#### Non-vacuous proof

1. More than nine distinct valid future Prepare controls are retained without
   `busy`; exactly the proposal-ready row advances, and each blocked row becomes
   ready in deterministic original order as prior groups retire.
2. Two live requests for one semantic digest share one envelope and both
   receive the same certified result. One caller death removes only its waiter;
   the row and other waiter remain. A later duplicate `DOWN` or commit cannot
   double-reply or corrupt bytes/indexes.
3. An older blocked row never hides a younger ready row. Opening the exact
   projection/fence moves it between indexes without re-signing. Re-signing
   changes scheduling time but preserves the Slice-0.6 observation epoch and
   adjusts the byte total by the exact new-envelope delta. A Decision observed
   under both the post-Prepare `pending` fence and a valid `pending_apply`
   window is never stale. `acknowledge_finalize` changing only the fence must
   trigger fingerprint reclassification.
4. A blocked-only registry does not block ordinary content. Ready work, the
   durable protocol lock, an in-flight barrier block, and active DTX validation
   each independently still do. The direct-abort exception is exercised under
   an unrelated lock through the canonical readiness function.
5. Every row-retirement cause—commit, deterministic refusal,
   stale/not-in-charge, re-envelope failure, and explicit live-owner
   abandonment—leaves no stale row, order key, reverse waiter, or byte count
   and emits at most one terminal observation. Independent caller detachment
   removes only its reverse waiter and preserves the semantic row and bytes.
6. Restart recovery rebuilds the journal-pending Begin through the normal
   insertion helper; coordinator/replay and remote retry then reconstruct a
   mixture of ready and blocked later rows. The barrier reflects only ready
   work, the journal retains every exact per-GroupId pending Begin, sequence floors
   do not regress, and no envelope or waiter is duplicated.
7. Existing DTX endpoint, coordinator, recovery, replay, signed remote
   lifecycle CT, and chained-write behavior remain green. A hardware run
   overlaps two DTX groups on one target, restarts that target while one row is
   ready and another logically blocked, and proves both reach one terminal
   outcome with no `busy`, warning/error, stale owner row, or ledger fork.

Required gates: focused `quod_dtx` and `quod_simplex` EUnit, full EUnit, the
signed remote lifecycle and chained-write CT cases, compile, xref, dialyzer,
`git diff --check`, metric/dashboard validation, and a dead/stale-code sweep.

### Slice 0.8 -- certified-history ownership

- extend the existing foreign-log owner with caller rows carrying an exact
  canonical work key, caller monitor, absolute deadline, requested reference,
  phase/current-view contract, and result contract;
- keep exactly one active certified-cache writer per ontology identity; its
  shared cache advancement may serve multiple rows, but different claims are
  always evaluated separately by the existing verifier;
- schedule waiting distinct identities inside that same owner on worker
  completion/progress, with no second verifier, cache, or worker-pool owner;
- build on the catch-up server inflight rows already keyed by `OwnerRef` since
  Slice 0.6; extend each row with authenticated peer, reply link, request id,
  exact range, monitored worker/link, and a server attempt deadline derived
  from the existing shared pull timeout with reply grace. Exact duplicate
  ranges may share only the read result, not reply ownership;
- start queued catch-up reads from worker completion, send a correlated error
  before the client timeout when an attempt cannot run, and remove expired or
  link-dead rows through one finish path--never leave an abandoned 8-second
  client request queued; and
- use the two approved node-instance policies: 32 active foreign-history
  writers node-wide and 32 active catch-up readers per hosted ontology, both
  dynamically changeable or `unlimited`; additional exactly-owned rows wait
  and wake on progress rather than reject or disappear; remove foreign
  `32/4`, `history_busy`, and catch-up silent-drop admission behavior; and
- verify that more than 32 concurrent valid pulls and more than four from one
  authenticated peer make progress without an 8-second timeout being their
  normal scheduler.

The ownership/queue refactor may be implemented and tested first while the
current constants still own admission. Removing those constants and deploying
the 32/32 projected policies is one atomic activation with Slice 0.10a, after
physical-node identity Slices 2--3. There is no intermediate release with an
app-env shadow, a temporary compiled fallback, or unconfigured history and
catch-up owners.

### Slice 0.9 -- pre-Begin router ownership

- add only the reverse indexes needed by real scans: client correlation
  monitor/worker to request id, route-link monitor to route, and ask-router
  identity-collector monitor to owner/request;
- reuse existing worker-pid, link, owner, and per-proof indexes; do not add a
  per-forwarder counter or a replacement queue owner merely to delete a cap;
- remove the client router's two independent 256 gates, inbound 64/8 gates,
  scope router node-wide 512 and peer 16 gates, separate inbound-attestation
  512 gate, and target remote-peer 16 gate after exact cleanup tests
  (**implemented in the current working tree**);
- retain the per-proof owner count 8 and per-scope pending count 64 because
  they are protocol-shape bounds, deleting peer counters when peer policy is
  removed;
- keep the current proof/scope-worker memory policy unchanged until Yan
  explicitly approves its named default, and retain all per-proof shape
  bounds; and
- expire abandoned browser `cursorOperations` rows with their signed request
  or tab owner instead of adding a row-count cap.

### Slice 0.10a -- physical-node policy projection and approved policies

- wait for the physical-node enrollment and exact local
  `agent_instance_ref/3` binding in `doc/node-instance-identity-plan.md` Slices
  2--3; never substitute a raw node key or shared `quod:node` row;
- define the reusable resource/value validation rule in shared `quod:node`;
  store `node_resource_policy(NodeInstance, Resource, Value)` only in that
  instance's dedicated ontology, never a self-anchor in genesis;
- make policy updates ordinary signed node-ontology actions whose prerequisite
  calls the shared validation rule through the existing `::`/DTX path;
- include one immutable founding `state_handler/4` and one hash-pinned governed
  projection bridge in the reviewed node-ontology genesis template. Runtime
  projection is local and self-contained: certified namespace/anchor plus the
  local instance form the exact reference, and the bridge shape-checks then
  updates only the existing resource owner;
- define and test one durable root-genesis bootstrap policy for resources needed
  before the first node ontology exists, including ingress bytes and effect
  attempts, plus one atomic handoff to the exact node projection. Never run
  both sources, silently fall back, or use app env;
- activate the approved authentication defaults 256/256, foreign-history
  active-writer default 32, and catch-up-reader default 32 per hosted ontology,
  each dynamically changeable and supporting `unlimited`;
- preserve auth TTL/pruning and existing rows when a value is lowered; wake
  waiting history/catch-up rows when a value rises; and
- make missing, duplicate, malformed, wrong-anchor, or wrong-node projection
  fail loudly and leave only the affected new work unavailable, with no app
  config shadow or compiled fallback.

Genesis creation, replay, handler reconciliation, bridge-manifest pinning,
exact-instance binding, bootstrap handoff, node-ontology loss, and restart all
require non-vacuous tests. This sub-slice is implemented with, or immediately
after, node-identity Slices 2--3; no policy-dependent admission is deployed in
between.

The proof/scope default 64 is not activated through this predicate until Yan
approves it. Custody byte policy, directory-control dial scheduling, and effect
attempt bounds remain separate decisions below.

### Slice 0.10b -- directory population and signed-generation closure

- keep `quod_directory` and its ETS tables as the only verified live-route
  owner read by `::`, subscriptions, certified following, and DTX;
- delete the 8-route-per-ontology and 2,048 route/known-namespace/high-water
  population fields, macros, admission checks, and
  `namespace_full`/`directory_full` capacity branches with no replacement
  ontology or route count;
- retain route authentication, exact anchored identity, signed incarnation and
  sequence freshness, lease expiry, stale-generation removal, and usage/age
  metrics;
- replace the one complete-set record capped at 32 hosted descriptors with one
  coordinated new record version carrying a complete signed generation across
  bounded records/pages. Every manifest/chunk binds the node key, endpoint,
  epoch, sequence, generation digest, and position;
- let `quod_directory_control` own one superseding incomplete generation per
  signer and completed manifest/chunk relay state, while `quod_directory`
  remains the only query index. Incomplete, stale, tampered, or expired input
  never advances high-water, renews a live lease, or enters resync output;
- verify signatures, identity, canonical ordering/completeness, uniqueness,
  and the full-set digest without preallocating from a claimed count; then
  stage rows in `quod_directory` and flip one active-generation marker which
  every reader filters. Reclaim the old rows after the flip so no reader can
  observe a mixed generation;
- discard incomplete staging on restart. Rebuild this node's complete
  generation from live namespaces and repopulate remote complete generations
  through the existing resync owner;
- impose no ontology-count or page-count product ceiling and never preallocate
  from an untrusted claimed count; retain bounded frame/record decoding and
  exact session/deadline ownership; and
- reject the old record version after a coordinated fleet restart rather than
  keep a dual decoder. This P-state format change requires no ledger purge or
  genesis re-found; and
- update `quod_directory`/control/auth moduledocs, record comments, metrics,
  configuration schema, and tests in the same change; no stale claim that the
  route population or hosted set is “bounded” may survive.

This slice does not implement future Quod public discovery and does not
narrow current non-system discovery. It removes low-level population limits
from the route mechanism that both current discovery and that future service
will use.

### Slice 0.10c -- directory-control liveness ownership

- keep the 30-second route lease and 128-record resync page as liveness and
  per-message work bounds, not total ontology or peer limits;
- remove the fixed 128-root-contact configuration count while retaining exact
  endpoint validation and deduplication;
- remove the 2,048 concurrent-resync-session refusal: the existing control
  process owns at most one correlated session per authenticated peer, expires
  it after 30 seconds, and finishes/replaces it through one path;
- review the current four-active-dial scheduler separately from admission: its
  existing FIFO does not reject work, but the compiled value must either become
  an approved node-instance scheduling policy or be deleted in favor of the
  existing QUIC owner's pressure mechanism; and
- keep retries and completion event-driven; timers only detect failed dials or
  abandoned resyncs.

The active-dial choice remains open for Claude/Yan review. It does not block
the route-store cap removal in Slice 0.10b.

### Slice 0.10d -- ingress and signed-custody byte ownership

- keep unsigned waiting in the existing `quod_ingress_state`; do not add a
  second pre-sign queue or a second custody owner;
- add one minimal node-wide `quod_ingress_budget` accountant, not a transaction
  store: it owns only atomic byte reservations, owner monitors, the projected
  policy value, and aggregate metrics. Each per-ontology Simplex process is
  the sole owner of its request, custody, and relay-result rows;
  `quod_ingress_state` and the relay-result map are pure substates of it;
- delete ingress row/per-author counts and Simplex custody/relay counts of
  2,048 only after exact waiter, byte, signed-row, relay-placement, deadline,
  and DOWN ownership share one finish/wakeup path;
- once bytes are signed, retain the exact custody row until certified
  inclusion/exclusion during normal owner lifetime regardless of population
  pressure; never evict, re-prove, or automatically resubmit it;
- make the existing crash boundary explicit instead of promising persistence
  that does not exist: ordinary Simplex ingress/custody rows are volatile. A
  namespace-process crash releases its monitored byte reservations and returns
  or later resolves `outcome_unknown`; the browser's pre-send unresolved
  operation remains the recovery source. This slice does not extend the DTX
  signing journal or claim that ordinary signed rows survive restart;
- reserve bytes atomically before an ingress owner retains the exact request,
  and carry the same correlated reservation through signing, custody, and
  relay placement. Refusal, cancellation, or caller detachment may release it
  only before signing. After signing, caller/client detachment never releases
  custody bytes. Certified terminal completion releases the reservation only
  when no terminal result remains retained; otherwise it atomically
  transfers/resizes the token to the relay-result cache, which releases it on
  expiry/removal. Owner DOWN releases only when the corresponding volatile row
  or cache entry was lost. Recovered durable work reacquires its exact bytes
  before new admission and cannot be refused by the current policy;
- delete `quod_relay`'s 2,048 completed-result population trim. Acquire the
  same byte reservation before relay admission and retain the exact terminal
  result until its existing expiry, so duplicate redrive gets the same answer
  rather than repeating work;
- if the accountant alone restarts, close new admission, reproject its exact
  policy, enumerate live Simplex pids through the existing gproc-backed
  `quod_simplex:namespaces()` registry, and ask each once to re-register all of
  its ingress, custody, and relay-result sub-reservation ids and byte sizes.
  `quod_ingress_state` and the relay-result map remain pure sub-state of that
  Simplex owner; no separate owner registry/process is introduced. Duplicate
  registration is idempotent; Simplex/accountant restart races finish through
  pid/monitor identity. Reopen only after every enumerated live Simplex replied
  or went DOWN. Never infer zero usage from an empty fresh ETS table.
  Finite policy may apply transport backpressure or a typed pre-sign refusal;
  it never drops accepted signed custody; and
- benchmark request sizes, stalled throughput, and multi-ontology
  multiplication. The approved policy scope is one physical node, not one
  allowance multiplied by every hosted ontology. The current 2 MiB per
  ontology is temporary and is not the approved answer; the exact node-wide
  default remains a benchmark/review decision and may be `unlimited`.

This slice cannot activate until that byte default and finite-pressure response
have been approved.
Its waiting lifetime also lands with Slice 0.11; otherwise the existing
7-second ingress expiry would simply move the rejection earlier.

### Slice 0.10e -- direct-effect execution isolation

- keep one `quod_effect_journal`, one durable rows snapshot, the existing
  P-before-E release, and the existing desired-state/postcondition verifier;
- keep the journal as custody/reconciliation owner only. A released row is
  idempotently registered with the existing `quod_namespace_manager` under its
  effect id, target namespace, exact prepared descriptor, remaining attempt
  deadline, and durable ordering token; the journal adds no lane queue,
  execution worker, retry scheduler, or second mutation state machine;
- make `quod_namespace_manager` the sole physical-mutation lane owner. Its
  conflict key is the target namespace (equivalently the current effect class
  `{ontology_lifecycle, TargetNamespace}`); namespace, not anchor, is the
  resource because two incarnations of the same local namespace still
  conflict;
- replace the manager's global mutation worker/FIFO with volatile per-namespace
  lanes shared by journal effects, direct lifecycle calls, and reconciliation.
  Different namespaces run in parallel; one namespace has one active physical
  mutation and one finish path;
- keep a retrying or uncertain journal effect at its manager lane's head so a
  later same-namespace effect cannot overtake it. Retry count is unbounded;
  event-driven progress and the one approved per-lane backoff wake it. Every
  attempt first reuses today's desired-state check so successful external IO
  whose reply was lost is not repeated;
- route result, worker DOWN, deadline, stale/late reply, caller death, and
  shutdown through the manager's one idempotent `finish_attempt`. Queued caller
  death removes only that direct waiter; death after a mutation starts detaches
  observation and cannot declare the external outcome absent;
- let the journal mark `applied` or `operator_error` only from the manager's
  correlated terminal result. On either process restart the journal rebuilds
  released rows from its durable snapshot and re-registers them idempotently;
  the manager rebuilds no custody, only its volatile lanes. Stale tokens and
  old results are inert;
- preserve source-ledger release order with the row's existing durable
  height/effect identity. Effects from independent controlling ontologies have
  no meaningful global ledger order; use a documented stable tie-break only
  to rebuild one local target lane, never claim cross-ontology causality; and
- refactor the downstream child-start seam too. A per-namespace worker is not
  sufficient if synchronous `supervisor:start_child` still runs a slow child
  initialization inside one shared dynamic supervisor. Keep the same
  `quod_ns_sup` and namespace child owners, but make their start callback
  return after lightweight config/identity setup; existing ledger restore,
  replay, catch-up, and runtime owners continue heavy initialization
  asynchronously behind the existing rebuilding/ready gates. Test that
  wedging namespace A's restore cannot prevent namespace B from starting.

Future effect handlers must provide a deterministic conflict key plus their
existing idempotency/postcondition contract before entering this runner. P
release stays ordered per controlling ontology, but ledger heights are not
globally comparable: this promises serialization per conflict key, not a total
external order across ontologies, and DTX Complete still does not wait for E.

Attempt timeout, retry minimum/maximum, and heap safety are ordinary facts in
the physical node's dedicated ontology, authored through the validation path
in Slice 0.10a and projected into the namespace manager which owns attempts.
There is no worker-count or retry-count cap. Exact founding and bootstrap
values, and whether a given field permits `unlimited`, remain pending review;
until configured, custody remains safe but new E execution is visibly
unavailable. One absolute attempt deadline is enforced by the manager; the
journal does not stack another timer. The existing independent manager
15-second call timeout is deleted from this path.

The public journal helper's generic 5-second clip and `await/2`'s 60-second
clip are not attempt policies. Replace the generic helper with API-specific
ownership: pre-Begin reserve/stage/bind calls use the signed remaining budget;
post-Begin handoff/reconcile calls use their named attempt/recovery bound; and
capacity/status/stats use a caller-supplied observation bound. `await/2` uses
the caller's exact observation budget and may detach without changing custody.
Slice 0.11 threads those values and deletes both silent clips. Tests cross the
old 5- and 60-second boundaries at their correct seams.

### Slice 0.10f -- system-ontology first-route closure

This slice closes only system bootstrap; it is not general public discovery.

- keep `system_ontology(Name, Anchor)` as the root-owned desired exact identity
  and nothing more. It grants neither hosting nor directory publication;
- retain root's configured genesis/contact as the irreducible network
  bootstrap. Once root is live, accept a signed advertisement for a listed
  system identity only as a provisional first-contact hint in the existing
  directory owner, never immediately as an authoritative route;
- over that authenticated QUIC contact, use the existing certified-history
  verifier to prove the advertised anchor and that the advertising key is a
  current validator of the exact system ontology. Only then promote the
  descriptor into the same active `quod_directory` generation/index consumed
  by the namespace manager. A false or stale hint changes no route;
- use the resulting ordinary route to materialize the existing exact join
  config and let the namespace manager, consensus, feed, and link owners do
  their current work. No special system-ontology supervisor, socket, route
  table, or proof path is added;
- initially publish only verifiable validator contacts for this bootstrap.
  Observer advertisement needs a separately specified durable eligibility
  proof and must not be inferred from “this process happens to host it”;
- after a root-listed system identity can bootstrap this way, reject and
  delete deployment-allowlist authority for that system namespace in the same
  coordinated activation. Keep root's irreducible bootstrap contacts and keep
  ordinary non-system allowlist entries until Agent-FIPA Slice 8 replaces
  their discovery path. Never accept both authorities for one system
  namespace; and
- treat an identity with no verifiable current host as explicitly unavailable
  and retry on root catalogue, control-link, directory, or committee progress;
  timers only detect abandoned contact attempts.

Tests cover first startup with root only, later root catalogue change, false
anchor, non-member signer, stale committee epoch, restart with no remote P
cache, all advertised hosts temporarily down, and automatic recovery when one
valid host returns. This slice bypasses the future public-name service because
the root row already supplies exact identity, but it exercises the same
directory/QUIC/certified-history path every other exact identity uses.

No “no hard-coded operational limit” or release-complete claim is allowed
until Slices 0.10a--f have closed every approved owner, field, refusal/drop
branch, metric, test, comment, and document. Open policy decisions remain
explicit blockers only for their own sub-slice.

### Slice 0.11 -- one pre-Begin transaction deadline

- keep the already-signed absolute `not_after` as the only transaction
  lifetime owner before Begin; authentication challenge/session TTLs remain
  separate because no signed transaction exists yet;
- derive one monotonic remaining budget at ingress and thread it through
  client-router validation/wait, proof kill timer, scope lifetime and step,
  identity probe, inbound attestation, and signed-goal auth/router internal
  calls;
- delete the ingress queue's independent 7-second expiry and the independent
  60-second, 30-second, and 5-second truncations at those seams rather than
  wrapping them with compatibility fallbacks;
- retain only named per-step delivery grace inside the same remaining budget;
  no internal call may outlive it; and
- preserve the Begin boundary: once accepted durably, expiry detaches the
  client observation but never cancels coordinator/replay recovery.

### Slice 1 -- event-driven apply readiness

- retain each exact applied request in its existing endpoint worker until its
  committed Finalize is projected;
- wake only that matching worker from `finalize_applied`;
- remove the fixed endpoint worker and global-correlation admission gates,
  their public limit fields, tests, comments, and dead `busy` branches;
- separate small identity attesters from the proof-worker admission count;
- after an accepted remote phase, request an immediate refresh from the
  existing certified foreign-log follow and resume on its ordinary
  acknowledged progress notice instead of polling with 100/200/400 ms waits;
- coalesce identical concurrent current-identity checks at the existing
  certified-history owner, so simultaneous remote scopes share one verified
  result instead of receiving `history_busy` and retrying;
- preserve timeout/disconnect cleanup and the existing verifier; and
- use one concurrent coordinator preflight.

Before removing the gates, measure one and two simultaneous maximum-committee
request sets and record endpoint/probe process count, total and peak heap,
mailbox depth, scheduler/CPU cost, latency, and exact cleanup after completion,
deadline, and caller DOWN. If bounded per-request state is safe at both loads,
delete the gates without a replacement population policy. If it is not safe,
park exact owned rows in this same endpoint registry and schedule active work
with one approved node-instance policy; never restore a refusal cap or add a
second queue. Deploy and pass this resource gate plus the maximum-committee
concurrent acceptance test before changing the participant format. Otherwise
a one-participant release would still carry the known eight-worker quorum
defect.

### Slice 2 -- one real participant

- require review acceptance of Slices 0.5--0.11 and the deployed Slice 1
  maximum-committee gate before changing the protocol;
- separate operation custody from participant material;
- remove claim-only origin rows from foreign DTX manifests;
- accept one participant through the five named validation seams, replay, and
  recovery;
- preserve actual origin participation;
- fail closed on a remote signed execution with no target authorization
  material; and
- update all contradictory docs/comments in the same change.

### Slice 3 -- independent waves

- make planner dependency (`ordered` versus `independent`) explicit;
- execute all post-Decision Finalizes concurrently;
- collect/validate results only in the parent coordinator; and
- do not special-case Finalize concurrency outside the planner-owned
  dependency model.

### Slice 4 -- restore the ordinary singleton path

Slice 4 must meet a real interactive-write gate without weakening the existing
protocol: a warm signed foreign-only write, with its real agent signature,
identity check, target `can_invoke/4`, consensus, durable apply, and resolvable
outcome, must complete with p99 below 500 ms. The primary concurrent gate is
four writes from the same agent ontology to the same target, matching the live
failure that measured about 11 seconds. Concurrency 1, 2, 4, and 8 must all be
reported. Cold first contact is reported separately because transferring and
verifying missing history cannot honestly have a history-size-independent
latency promise.

#### Slice 4.0 -- architecture conclusion

The five-phase foreign-singleton path is not merely an implementation that
needs faster evidence. It is the wrong protocol class. The normative
`inter-ontology.md` contract already says one material target uses that
target's ordinary transaction path; only two or more material/read-dependent
targets require DTX. Signed-client operation recovery later overrode that rule
by forcing every signed foreign write through DTX so the agent ontology could
claim the operation first. That preserved exactly-once recovery, but coupled an
operation journal requirement to distributed atomic commit.

The guarantees must be separated:

1. the agent ontology A remains the sole durable owner of
   `{AgentReference, OperationId}`;
2. the actual target B remains the sole owner of its ACL, OCC decision, data
   change, and transaction outcome;
3. A must claim the exact B transaction before B may expose the change;
4. after that claim, any current A recovery owner may safely submit the same B
   transaction without re-proving the goal;
5. a later durable receipt in A stops recovery and makes replay proportional to
   unresolved work rather than all historical operations; and
6. two or more material/read-dependent ontologies still use the existing DTX
   atomic protocol.

The selected singleton path is therefore:

```text
proof and seal
    -> batchable operation claim in A
    -> ordinary batchable transaction in B
    -> asynchronous batchable completion receipt in A
```

The client returns after B's durable applied-or-rejected outcome. It does not
wait for the bookkeeping receipt: the stable operation reference in A already
resolves to B's deterministic transaction reference. The receipt is still
required so restart/replay redrives only unresolved claims.

| Artifact | D/P/E meaning |
|---|---|
| A `remote_claim` | D ledger metadata; P operation index becomes unresolved; no ontology fact or event |
| B `application` | D ordinary transaction; P applies facts or records rejection; existing applied operations/effects produce E normally |
| A `remote_complete` | D ledger metadata; P operation index becomes terminal; no ontology fact or event |

The claim and receipt never appear as asserted Prolog facts and do not enlarge
A's knowledge base. They remain visible as ledger records in Explorer.

At concurrency four, the four A claims may share one ordinary content block
and the four B transactions may share one ordinary content block. They no
longer become four serialized groups. No parallel-active-group exception and no
predicate-specific fast path is introduced.

#### Slice 4.1 -- one batchable transaction family

Do not add a separate consensus queue or a second ledger executor. Extend the
existing canonical transaction record with one explicit role and its bounded
role data:

- `application`: today's ordinary Prolog transaction;
- `remote_claim`: source metadata, with no ontology-fact or event mutation; and
- `remote_complete`: source terminal metadata, with no ontology-fact or event
  mutation.

All three use the same author signature, admission generation, sequence lane,
micro-batch, consensus, ordered projection, replay, catch-up, outcome index,
and Explorer classification. The two metadata roles never execute a goal or
invent an ACL. They are the batchable equivalents of the operation-claim and
terminal-custody parts currently embedded in DTX Begin and Complete.

`remote_claim` stores exactly:

- the unchanged signed request and stable operation identity owned by A;
- the proof/result binding;
- the one exact target identity B;
- B's signed sealed plan and target authorization transcript; and
- the deterministic B transaction reference.

A validators use the existing signed-request/active-key verifier and operation
projection transition. They do not run B's ACL. B's target transaction uses the
existing prepared-plan validator, target `can_invoke/4`, OCC reducer, and
ordinary transaction outcome. A malformed signature, claim binding, plan, or
foreign certificate makes a candidate invalid; a well-formed claimed
operation whose B policy/OCC state changed commits one ordinary rejected
outcome with the existing bounded failure-reason vocabulary. Thus a durable A
claim can never become an unresolvable promise merely because B changed after
the proof.

Refactor the pure target evaluator once to return one of
`apply(Material) | reject(FailureReasons) | invalid(ProtocolReason)`. Candidate
support and ordered projection call that same function at the same parent.
`invalid` is reserved for forged/malformed/unverifiable records and receives no
ledger position; `reject` is the durable result of a valid claimed operation
that B's ordinary policy or OCC state refuses. Local application transactions
keep their current admission semantics. There is no second ACL and no
check-versus-apply copy.

The discriminator is exact: failure of the author signature, C/T binding,
claim certificate, canonical decoding, or immutable record shape is `invalid`;
an authentic correctly bound claim whose existing authorization transcript
re-proof, current target policy, or OCC check fails is `reject` with the
existing bounded reasons. No caller maps these classes a second time.

`remote_complete` binds the operation identity, exact B transaction reference,
and B's certified applied-or-rejected result. It changes only A's existing
operation/outcome projection from unresolved to terminal. Duplicate exact
receipts are idempotent; a different target, result, or request digest is a
consensus-invalid conflict.

This is a coordinated format break. Change transaction construction, canonical
bytes, safe decode, ledger classification, Simplex batch validation,
commit-validation, projection, Explorer rendering, fixtures, and docs together.
Do not retain an old transaction decoder, forwarding shim, or dormant DTX
singleton branch. Activation uses the already-planned clean re-found.

#### Slice 4.2 -- remove the certificate/identity cycle without weakening it

The B transaction identity must be known before A's claim commits, while the
certificate proving that claim exists only afterwards. Resolve this without a
hash cycle:

1. Derive A's claim transaction id `C` from the stable operation/request plus
   B's exact target identity, sealed plan/material, goal/result, and target
   transcript. `C` does not include a later block certificate or a redundant B
   transaction id.
2. Derive B's semantic transaction id `T` from its ordinary application fields
   plus the stable source reference `{transaction, A, AAnchor, C}`.
3. Store and re-check the derived `T` in A's claim. The public operation row
   maps to `{transaction, B, BAnchor, T}`.
4. Once C commits, carry its exact certified entry as acceleration evidence.
   The certificate proves the already-fixed C; it changes neither C nor T.

Every B validator verifies that the certified A claim contains the same
operation, request digest, target identity, plan digest, and predicted B
transaction reference. It then runs the one existing target plan/transcript/OCC
validator. The stable C reference is part of B's semantic transaction; the
certificate bytes themselves are evidence and may not alter its id. A second
valid proof of the same C therefore converges on T, while evidence for any
other claim cannot authorize T. Replay can resolve C by its anchored
transaction reference even if the live sidecar is gone.

Use the existing `quod_foreign_log` plus `quod_catchup:verify_forward` owner for
the claim and completion references. Generalize Simplex's current DTX foreign
reference seam so content transactions and DTX controls feed the same required
reference extractor, asynchronous verifier, cache, and deterministic
commit-validation context. Do not copy DTX's verifier into the transaction
module.

The successful source submission carries the exact certified claim entry to
the B admission node as an acceleration sidecar. That node offers it to its one
foreign verifier. The other B validators do not trust or depend on that
admission node: when the transaction reaches them through ordinary consensus,
each advances its own shared per-node foreign cache to C. Claims sharing one A
content block therefore cost one contiguous A-block advance per B validator,
amortized across every claim in that block, rather than one history transfer
per transaction. Slice 4.5 measures the per-validator foreign-advance time and
sidecar hit rate; the plan does not claim that an endpoint sidecar is somehow
broadcast to the whole committee.

A contiguous cached parent makes validation local; a missing prefix or cold
cache falls back to the existing certified-history follow. Invalid sidecars
merely lose the acceleration and never become evidence. Cache advancement
wakes exact waiters by message; deadlines remain failure safeguards, never
progress polling.

#### Slice 4.3 -- one durable recovery owner

Refactor the existing DTX origin recovery owner into the ontology's durable
operation recovery owner; do not add a singleton dispatcher beside it. It owns
two pure transition families:

- an unresolved singleton claim submits or resolves its exact B transaction,
  then proposes the exact completion receipt; and
- a real multi-target Begin continues through the existing Prepare, Decision,
  Finalize, and Complete transitions.

Live handoff and restart/replay enter the same owner with the same durable
record. The owner never re-proves, changes the participant set, allocates a new
operation id, or invents a new transaction. Multiple A validators may race to
submit the same semantic B transaction; B's existing transaction id and
outcome projection converge them on one result.

Duplicate-T admission is part of that contract, not an error shortcut. The
existing custody/outcome admission seam returns the stored terminal outcome
when T already committed or rejected, correlates with the existing pending T
when it is still in custody, and accepts one new T only when absent. Different
validator-author envelopes for the same canonical semantic T converge there;
different semantic material claiming the same T is invalid. A recovery
resubmission never creates another ledger result and never reports `duplicate`
as the operation outcome.

Normal progress is event-driven: claim apply, route availability, verified
foreign-cache advancement, target apply, and completion apply send correlated
messages to the owner. A timer only bounds a silent peer or dead connection.
There is no periodic outcome polling and no compiled worker/count limit added
by this slice. Pending work remains durable rather than one Erlang process or
one retained heap per historical claim.

The operation owner also follows the registered name of the one node-wide
foreign-history verifier. If that verifier restarts, the unregister message
invalidates the old follow reference and the replacement-registration message
reattaches the exact target immediately. The operation adds no verifier,
restart timer, or polling loop.

Remote direct effects use this same singleton path and the existing DTX
handoff ordering. The source first registers the exact C claim in its durable
Simplex custody as dormant. The source custody owner monitors the proof worker
only across this dormant handoff. The target has already reserved the exact
private preparation before exposing its signed plan attestation; binding may
only consume that reservation under the exact signed source submission. After
the target binding acknowledges, the source activates that exact dormant C for
consensus and clears the proof-owner monitor. There is therefore no target
journal row whose source operation exists only in a dead proof worker.

The signed `not_after_ms` is not used as a false absence proof: it limits the
claim block timestamp, but a valid already-proposed claim could commit later.
An abandoned effect row retires only through the exact source dormant-intent
cancel/terminal transition, never because a wall timer guessed that C cannot
exist. Explicit failure and proof-owner death enter the same idempotent source
custody transition and start one cancellation coordinator. Cancellation sends
the exact signed C submission, not an unsigned token. At the target, bind and
cancel race through the one existing journal reservation: cancel-first removes
the reservation so a late bind fails; bind-first persists the row so cancel
retires it. Source restart reconstructs the same cancellation from the dormant
signed row. B's ordinary transaction alone releases the effect for execution
or retires it on rejection.

Refactor the current DTX-only dormant-effect binding to this common durable
operation handoff and delete the group-only duplicate. If the existing custody
owner cannot prove register-before-bind, exact cancel, crash recovery, and
at-most-once release, implementation stops for review; silently keeping
effect-bearing singletons on DTX is not an accepted leftover.

#### Slice 4.4 -- planner rule and deletion map

The proof, scope, and sealing pipeline stays unchanged. Once sealed, one rule
selects the protocol from actual dependencies:

| Sealed result | Durable path |
|---|---|
| no participating plan | read result, no ledger record |
| one plan, target is signed origin | ordinary target transaction |
| one plan, foreign signed origin | remote claim -> ordinary target transaction -> async receipt |
| one plan, unsigned trusted in-VM origin | existing ordinary target transaction |
| two or more material/read-dependent plans | existing DTX group |

Keep: `quod_transaction` canonical application transaction, target
`can_invoke/4`, `quod_commit_validation` as the pure check/apply authority,
ordinary Simplex batching, `quod_foreign_log`/`quod_catchup`, the operation
reference and browser journal, the outcome projection, and the multi-target DTX
reducer.

Refactor: transaction roles and request evidence, foreign-reference validation,
the origin recovery owner, target plan validation, and effect-journal binding.
Each refactor has one exported owner and one check/apply implementation.

Exact module ownership for implementation review:

| Owner | Keep/refactor/delete |
|---|---|
| `quod_prolog` | keep proof/scope/seal; replace only the post-seal singleton dispatch and record construction |
| `quod_transaction` + `quod_ledger.hrl` | own the three canonical roles, semantic id normalization, signed bytes, and safe decode |
| `quod_ledger` + `quod_simplex` | keep one content micro-batch/consensus lane; generalize its item validation and one foreign-reference wait |
| `quod_commit_validation` | remain the sole pure check/apply authority; reuse prepared-plan and transcript validation for remote application |
| `quod_committed_projection` + `quod_outcome` | apply D/P/E only for application; project claim/receipt metadata and the one operation state machine |
| `quod_foreign_log` + `quod_catchup` | remain the sole certified foreign-history verifier/cache for content and DTX references |
| `quod_dtx_recovery` / `quod_dtx_coordinator` | extract/rename one durable-operation owner; keep group transitions, add singleton transitions, delete singleton group use |
| `quod_effect_journal` | generalize dormant custody from a group-only binding to the stable operation/target-transaction binding |
| `quod_client_goal` / `quod_client_result` | keep request and operation reference; remove the singleton `group_outcome`/one-slot result shape and resolve claim -> B transaction -> receipt after the hard break |
| Explorer server/UI | render claim, target application/rejection, and receipt; remove the misleading singleton group presentation |

Delete: `signed_foreign_singleton/1`; the rule forcing one foreign signed plan
into `submit_group`; one-participant DTX admission/result compatibility added
only for that rule; singleton Begin/Prepare/Decision/Finalize/Complete fixtures;
the one-active-group admission wait from the singleton metrics/docs; and every
accepted-then-refetch helper superseded by carried certified evidence. DTX's
one-participant decoder is narrowed back to two actual participants unless a
separately identified non-client protocol use proves it is still required.

In the same closure pass, update `inter-ontology.md`,
`signed-client-goals-plan.md`, `generic-agent-identity-plan.md`,
`distributed-proof-plan.md`, `durable-lifecycle-effects-plan.md`, client/auth
plans, README/operator guidance, Explorer help, comments, metrics text, and
fixtures. The final sweep must find no statement that a signed foreign
singleton is a group, no active one-participant group decoder, and no old
five-phase latency claim. Historical release notes may retain the old behavior
only when explicitly labelled historical.
The browser operation journal is updated in the same cut: unresolved entries
continue to store the signed request and A operation reference, but result
normalization follows the foreign B transaction outcome and never expects a
one-participant group result.

#### Slice 4.5 -- measurements and stop rule

Before implementation, finish the missing fixed-stage spans so one operation
separates gateway verification, active-key certificate, proof/scopes/seal,
source claim consensus/apply, claim verification at B, target
consensus/apply, response flush, and asynchronous completion. Labels are only
fixed `stage`, `phase`, and `result`; arbitrary identities, targets, operation
ids, goals, and reasons never become labels.

After each implementation sub-slice, run warm concurrency 1, 2, 4, and 8
against one source/target, the same work spread over source ontologies, a
remote read control, an A->B->C->D read/write, and a real remote direct effect.
Report end-to-end and stage p50/p90/p99, throughput, admission wait, foreign
cache work, admission-side sidecar hit rate, per-validator vote-time foreign
advance time, process/mailbox/heap/scheduler data, every ledger outcome, and
all warning/error/critical logs. A silently ignored sidecar must fail the
performance evidence even when correctness falls back successfully. The
release gate is zero lost/duplicate writes,
warm same-source concurrency-four p99 below 500 ms, no material mailbox or
worker growth after quiescence, and every completion eventually durable.

Only after the singleton gate passes should measurements decide whether the
remaining real multi-target DTX needs carried-entry or post-Finalize-certificate
optimization. Those are DTX refinements, not the singleton architecture.

#### Slice 4.6 -- implementation order

Implement as one reviewed release arc, not independent production features:

1. pin the stage metrics and pure C/T derivation fixtures;
2. add the canonical transaction roles, shared pure evaluator, and operation
   projection transitions with no public cutover yet;
3. generalize the existing foreign-reference verifier and recovery owner;
4. cut the planner, target submission, outcome resolver, and browser result to
   the new singleton path in one hard change;
5. generalize effect custody, update Explorer/assets/docs, and delete every old
   singleton-group seam; then run the complete stale-path sweep; and
6. pass all local/distributed/crash/performance gates, commit, clean re-found,
   and repeat the live gates before making a latency claim.

No intermediate commit is deployable merely because it compiles. Public signed
write ingress remains on the old release until steps 1--5 are complete and the
closure review finds one active path.

#### Slice 4.7 -- optimize genuine groups without changing their semantics

The full pipeline review does not assume the singleton cutover solves
A -> B -> C -> D or any goal with two or more material/read-dependent
ontologies. The live trace found seven distinct costs. They must be removed at
their owners rather than hidden by shorter timeouts or a movement-specific
route.

##### 4.7.1 Measured pre-optimization bottleneck map

This table records the hardware baseline that motivated the slice. Every
owner-side correction in its last column is implemented in the current working
tree; it is no longer a list of current causes. Final local gates, review, and
hardware acceptance remain before deployment.

| Rank | Pre-optimization cause | Evidence | Implemented owner-side correction |
|---|---|---|---|
| 1 | One source group remains active through Complete; later groups wait in one FIFO | concurrency-four p50 16.113 s, p99 17.200 s; 72.114 s aggregate admission wait | batch non-conflicting groups through the existing ledger/consensus owner; do not run uncoordinated parallel groups |
| 2 | `quod_dtx_coordinator` executes the planner's participant commands one at a time | the planner returns every missing Prepare/Finalize/applied command, but `drive/1` runs only the head; after one progress result it discards the tail and replans | execute one same-phase participant wave concurrently and merge verified results in canonical target order |
| 3 | an accepted phase returns a reference, then the caller separately reads certified history to recover the entry it just caused | source/target consensus averages tens of milliseconds while end-to-end sequential latency is seconds and grows with followed history | carry the exact committed entry as untrusted acceleration material into the one `quod_foreign_log` verifier |
| 4 | applied verification is repeated by the coordinator and then by every source validator | validators repeat the target quorum fan-out after the coordinator already established application | collect one signed target post-apply certificate per prepared Finalize wave, carry it in the existing ephemeral proposal-validation sidecar, and let source validators verify it locally |
| 5 | temporary `busy`, `not_ready`, absent evidence, or unavailable route enters 100--5,000 ms retry ladders | `schedule_retry/1` remains in the common group coordinator and the foreign follower has refresh backoff | park the exact correlated request at its existing owner and wake it from admission, apply, cache, directory, or link messages; timers only end silent/dead operations |
| 6 | a new target may know only the source ontology's historical endpoint, and a cold long-history check is tied to one caller deadline | reproduced with a long-lived source after a dynamic port change; a warm target succeeded while a new target returned `signed_scope_unavailable` | use the already authenticated incoming node contact as a reachability hint and make certified catch-up an owner-lived resumable job |
| 7 | when the source ontology is also a participant, its own committee commits separate Prepare and Finalize blocks in addition to Begin and Decision | the live source ledger contains Begin, Prepare, Decision, Finalize, Complete for every chain | validate/lock the source plan in Begin and apply/discard it in Decision through the same pure reducers |

Identity attestation, signature verification, catch-up serving, and consensus
computation are not selected for speculative rewrites. In the same run,
identity work was negligible, catch-up serving was a few milliseconds, source
consensus averaged about 85 ms per round, and commit application about 4 ms.
Those measurements remain regression baselines.

The concurrency-one target has no hidden phase overlap: Begin, the parallel
Prepare wave, Decision, and the parallel Finalize wave remain four sequential
consensus stages. The provisional warm p99 budget is therefore explicit:

| Critical-path stage | p99 budget |
|---|---:|
| proof, remote scopes, seal | 45 ms |
| fused Begin consensus and apply | 90 ms |
| slowest target Prepare consensus and carried-evidence verification | 90 ms |
| fused Decision consensus and source apply | 90 ms |
| slowest target Finalize consensus, apply, and applied certificate | 110 ms |
| result handoff | 10 ms |
| unallocated tail margin | 65 ms |
| **total** | **500 ms** |

Evidence ingestion may overlap proposal validation, and applied-certificate
collection may overlap Finalize apply; no other pipelining is assumed. Slice
4.7.8's first measurement must replace these provisional numbers with observed
p99 values. If any row or their sum misses the budget, the 500 ms claim is
false and that exact owner must be optimized before batching can receive
credit.

##### 4.7.2 One correlated participant wave

Keep `quod_dtx_recovery:next/2` as the only phase planner. Refactor its consumer
so all independent commands returned for the same phase start before any is
awaited:

1. submit every missing Prepare concurrently;
2. verify every returned Prepare through `quod_foreign_log` concurrently;
3. sort the verified results by exact target identity and apply them to the
   coordinator snapshot through the existing `put_*` functions;
4. submit the one Decision only after the complete Prepare wave resolves;
5. repeat the same shape for Finalize and post-apply evidence; and
6. re-plan once after a wave, not after every target.

This changes orchestration, not transaction semantics. Every target still
runs its ordinary ACL/OCC check and its own consensus. A refusal still aborts
the whole group. Crossed, duplicate, late, or wrong-target replies remain
correlated to one command and cannot enter the canonical merge. Use monitored
Erlang workers or asynchronous QUIC requests owned by this coordinator; do not
create a second durable coordinator or a polling process.

##### 4.7.3 Deliver evidence once; verify it once per node

An accepted endpoint response may include the exact committed entry and its
existing finality material beside the certified reference. The bytes are only
a speed hint. `quod_foreign_log` remains the sole verifier and either advances
its exact anchored projection with them or falls back to ordinary certified
follow. No endpoint response becomes authority by itself.

The coordinator's source proposal must make the same acceleration material
available to source validators. Add one ephemeral proposal-evidence attachment
that is outside the semantic block hash, bound to the exact referenced entry,
and discarded after validation. Every validator imports it through
`quod_foreign_log`; every validator still verifies signatures, history
continuity, committee state, namespace anchor, record digest, and phase
binding independently. There is no second verifier and no committee member
trusts the coordinator's verdict.

The target side uses the same chain; it is not allowed to fall back to a hidden
per-validator fan-out. The coordinator's endpoint request carries the exact
Begin or Decision entry. The existing retained-control relay forwards that
attachment with the control. The target leader keeps it when building the
Prepare or Finalize proposal, and the proposal transport presents the same
ephemeral attachment to every target validator. Each validator independently
imports it through `quod_foreign_log`. A validator that receives no attachment,
or receives well-formed but wrong bytes, ignores the hint and uses ordinary
certified follow; the block is rejected only if the authoritative verification
fails, never merely because the optional hint is bad.

After a prepared remote target applies Finalize, the coordinator collects
signed applied replies once from `f + 1` members of the committee certified by
that exact Finalize. The resulting certificate binds network, target identity,
Finalize-era committee id, group, Finalize reference, generation, and verdict.
The reference's slot is the applied-through floor; there is no separate moving
floor field. The certificate travels in the existing ephemeral
proposal-validation sidecar, never in the deterministic Complete v3 body or
block hash. Source validators verify it locally against the already-certified
Finalize evidence instead of starting target fan-outs. Replay and catch-up need
only the committed Complete QC and never require the sidecar.

The source-fused participant needs no certificate: its Decision is also its
Finalize and source apply readiness is local to the origin consensus owner. A
remote direct abort with no Prepare is a durable no-op and its Finalize QC is
sufficient. Remote commit and prepared-abort Finalizes each require exactly one
applied certificate.

##### 4.7.4 Remove polling from normal progress

**Foreign-follow status (current working tree, pending review):** the
per-identity poll and retry-backoff timers are deleted. First attachment,
explicit refresh, exact directory availability, and authenticated feed
block/digest frames wake one coalesced certified-follow job. A feed frame is
never evidence: its safe namespace envelope is recognized only as a freshness
signal, then the existing foreign-history verifier fetches and validates the
anchored history. The same feed channel now carries one volatile, correlated
height-wake registration per source node and current certified target
validator. Registration replies include the current height, later commits
send an acknowledged wake, and link loss or committee replacement rebuilds the
row from the existing route view. The control contains no fact or authority;
it only closes the missed-edge race for the ordinary certified follower.
Worker/page deadlines remain only as silence safeguards. The runtime's
separate subscription retry sweep and its configuration are also deleted: one
existing gproc name-follow monitor wakes all parked attachments when the
shared owner registers, and an uncapped mailbox queue yields once per
attachment. The group coordinator and its outer Simplex owner now use the
same rule: exact progress/DOWN/registration messages wake work, with no
ordinary retry timer or tick-driven backoff state.

Classify every current `retry` edge before changing it:

- target admission or apply pending: retain the exact request in the target
  Simplex and reply when its existing commit/apply message arrives;
- certified history behind: attach the coordinator as a consumer of the
  existing foreign follow and wake it on the exact advance;
- directory or authenticated link unavailable: subscribe through
  `quod_reg:subscribe({directory_route, Identity})`; the existing
  `quod_directory` owner publishes an identity-scoped route-available event on
  that property after its ordinary projection changes, while the existing
  transport-name/link monitors cover link replacement;
- owner or peer silent: retain one final deadline that returns uncertainty or
  unavailability without resubmitting an uncertain write; and
- malformed or contradictory evidence: fail immediately and permanently.

Delete `retry_initial_ms`, `retry_max_ms`, the coordinator retry timer, normal
follow refresh backoff, and every comment/test that describes timer expiry as
progress discovery. The directory property is a notification seam on the one
existing directory owner, not a second directory or retained route registry.
Subscribe/unsubscribe follows the coordinator monitor lifecycle. Do not replace
the removed timers with shorter intervals or move polling behind the property.

##### 4.7.5 Make first contact and cold history converge

**Implementation status:** implemented in the current full optimization tree,
without a new route or verifier; final review and hardware acceptance remain.
Authenticated scope and DTX ingress keep the
source contact in their existing request/work owner and supply it only to the
ordinary authorization or foreign-reference verification attempt. Decode-only
scope, claim, Prepare, and Finalize material stores nothing; a contact may
enter the existing volatile route-hint state only after the corresponding
check succeeds. `quod_foreign_log` keeps sole ownership of source selection,
certified pages, phase-index deltas, and the current projection. Individual
callers have independent wait deadlines; timing out no
longer cancels active or queued history work. A current-view job advances to
its captured remote height through certified page checkpoints, and identical
later callers attach to that job. Continuous subscription following retains
its existing bounded 256-entry target per turn; byte-bounded transport may use
several shorter pages to reach that target.

Transport authentication already proves the current hosting node key before
agent authorization. Supply that observed endpoint directly to the one
`quod_foreign_log` verification job as its freshest first-party contact. Do not
store the claimed identity or contact before authorization: a failed request
must leave neither behind. The contact grants no ACL right and certifies no
history; it only tells the existing verifier where to ask. The anchored
genesis, signed history, current committee, agent instance, and active key must
still verify normally. After success the existing volatile contact mechanism
may retain it for later work. A forged or stale contact can only fail to fetch.

Separate a caller's wait from the certified catch-up job. One foreign-history
owner per ontology continues page-by-page after an individual scope request
times out or disconnects. Each verified page and its phase-index delta are
checkpointed before the next page. A later caller joins the same job or resumes
from that prefix; it never replays a growing prefix from genesis merely because
the previous caller left. Page/link deadlines remain failure safeguards, not
the scheduler for the next page.

##### 4.7.6 Fuse a real source participant

Implement the already-deferred section 4.3 refactor:

- Begin validates the source plan through the exact current Prepare policy/OCC
  reducer and installs its lock;
- Decision applies or discards that source plan through the exact current
  Finalize reducer; and
- remote participants retain ordinary Prepare and Finalize records.

Delete source-local Prepare/Finalize construction, decoding, recovery, and
tests that exist only for this redundant shape. Do not copy their checks into
Begin/Decision. Extract and call the same pure reducer so proposal validation,
apply, replay, and catch-up cannot diverge. The logical atomic protocol remains
Begin -> Prepare -> Decision -> Finalize -> Complete, but a source that is also
a participant no longer pays two extra source blocks.

This changes the scheduler/reducer phase table deliberately. Update
`proposal_readiness/2` so the source Begin row owns Prepare's lock/readiness
requirements and the source Decision row owns Finalize's apply requirements.
Extend the existing reducer-gate matrix tests in the same change and delete the
source-only Prepare/Finalize rows and fixtures. Proposal readiness, preview,
apply, replay, and catch-up must all accept and reject the same fused
transitions.

Once all participant Finalizes are certified applied, the client-visible
outcome is safe: every material ontology exposes the chosen result. Complete
remains mandatory durable recovery bookkeeping, but its append may finish
asynchronously through the existing owner, like the singleton
`remote_complete`. A disconnect cannot cause a retry or a second group.

##### 4.7.7 Implemented conflict-safe group waves

The hard break replaced top-level `{dtx, Blob}` with
`{batch, [{dtx, Blob}, ...]}`. A control wave is non-empty, contains one phase,
uses the signed author-lane order, and rejects duplicate lane/sequence pairs.
The one decoder and one pure reducer own this rule for proposal, validation,
apply, replay, and catch-up.

The DTX projection is exactly
`#{target, groups, conflicts, apply_fences, generation}`. Sealed material plans
carry an atom-safe descriptor derived once from exact read functor keys,
assert/retract head functors, and the closed typed effect-custody target.
Events do not conflict. Materialization recomputes the descriptor and requires
exact equality; malformed or unknown effects reject rather than entering an
opaque fallback path.

Prepare does not advance the global proof epoch. Each committed applied plan
advances it once, including an event-only plan, while only actual assert/retract
fact mutations create a blocking per-GroupId apply row. Abort/discard changes
neither. Exact acknowledgement removes a remote participant row. For a
source-fused Decision it opens the row but retains the exact nonblocking
slot/generation marker until Complete consumes it; this makes live apply and
certified replay use the same reducer state. Neither transition changes the
global epoch.

Independent groups share same-phase Begin, Prepare, Decision, Finalize, and
Complete blocks. Overlapping RW, WR, WW, or custody keys use deterministic
GroupId wait-die: one group waits and the other is refused, so concurrent
Prepare waves cannot create a distributed lock cycle. Each group retains its
own references, outcomes, recovery, and Explorer rows. There is no compiled
group-count limit; the canonical block-byte bound ends a wave naturally.

This is one generalized consensus input path, not a second group protocol.
Crash recovery remains per durable group and reconstructs the groups, conflict
index, and exact apply fences from the ledger. Source Begin reuses the Prepare
reducer and source Decision reuses the Finalize reducer; remote Prepare and
Finalize are unchanged. Recovery therefore emits no source-local
Prepare/Finalize command and emits remote phase commands as waves.

The existing retained-control registry, rather than a second batch queue,
selects the maximal non-conflicting ready prefix that fits the block-byte
bound. Selected controls leave through the same completion, relay, DOWN, and
recovery functions as every other retained control.

Admission schedules one self-message rather than driving the first row inside
its caller's state-machine turn. Every already-admitted control ahead of that
message can therefore enter the same legal wave without a batching timer. A
remote leader verifies and re-signs the semantic controls into this same
registry even while another proposal is active; it no longer drops the relay.
The sender's retained row marks the exact ordered-link pid after placement, so
ordinary mailbox traffic cannot duplicate the frame. Link replacement makes
the marker stale naturally, and an improved validation sidecar explicitly
clears it. The retained row remains the only reconstructable owner throughout.

All consumers use the multi-group projection directly: `valid_projection/1`,
`origin_recoveries/1`, `proposal_readiness/2`, the transition/batch reducer,
history/checkpoint projection, proof access, retention, restart restoration,
catch-up preview, stats, fixtures, and Explorer classification. No singular
field, decoder, compatibility branch, or fake single-group view remains.

##### 4.7.8 Implementation slices and stop gates

Implementation status (working tree, not committed or deployed): slices 1--6
are implemented together. Final local gates, closure review, clean re-found,
and hardware benchmarks remain; this section makes no final performance claim.
`quod_dtx_group_stage_seconds` measures proof/seal, dormant admission,
coordinator phase waves, endpoint wait, phase verification, coordinator
mailbox, result handoff, and end-to-end time.
`quod_foreign_history_stage_seconds` measures the node-wide certified-history
queue, exact/current/follow work, cache open/replay, and page fetch. Both use
closed stage/result vocabularies; the existing GroupId and ProofId correlate
traces but never become Prometheus labels. Existing consensus round and named
apply-step histograms remain the consensus timing owner rather than being
duplicated. The dashboard exposes the two histograms. The hardware fixture and
95% accounting gate remain outstanding until the complete optimization tree is
reviewed and deployed. `proof_seal`, `admission`, the coordinator phase waves,
and `result_handoff` are non-overlapping group segments. `coordinator_total`
and `end_to_end` are enclosing totals and must not be summed with those
segments. Endpoint, verification, mailbox, foreign-history, and
consensus measurements are nested diagnostics. The segments need not yet tile
the end-to-end total: activation-cast scheduling before coordinator start and
the certified pre-Complete terminal notification waking the caller after the
coordinator finishes remain explicit residuals for the 95% hardware gate.
`result_handoff` begins when that waiter-resolution turn reaches the engine and
includes outcome lookup, result shaping, and reply delivery; it is not merely
the final message-send cost.
Each coordinator wave also owns one `quod.dtx.wave` OpenTelemetry span and one
child `quod.dtx.wave.item` span per participant operation. Only the closed
stage and numeric item index are attributes; group/target/goal data is neither
a metric label nor durable/wire state. Spawned workers receive the captured
parent trace context explicitly, so their work remains correlated without
depending on an Erlang process dictionary being inherited.
Earlier slice-local gates are historical evidence only; the final combined
tree must publish fresh gate counts after this cleanup.

1. **Observability only.** Add one correlation id across proof/seal, dormant
   admission, every group wave, evidence verification, applied certification,
   and client result. Export bounded phase/result metrics; never label by
   arbitrary target, agent, group, or goal. Include coordinator mailbox wait,
   foreign-cache queue/replay/fetch time, endpoint wait, and consensus proposal,
   finality, and apply time. Re-run the exact hardware fixture before behavior
   changes. Do not begin the protocol refactor until the non-overlapping stages
   account for at least 95% of end-to-end wall time. Compute that gate from
   per-request stage sums, or equivalently from means over the same completed
   request population; marginal p50/p99 values from different requests must
   never be added. Any unexplained remainder is a bottleneck to trace, not an
   acceptable `other` bucket.
2. **Liveness correctness.** Give the pre-authorization verifier its
   authenticated current contact without storing an unapproved identity; only
   successful authorization may retain the contact. Make cold catch-up
   owner-lived and resumable. Prove a stale-port, cold 1,000+ entry source
   eventually verifies without manual route injection.
3. **Wave execution and evidence reuse.** Parallelize participant commands,
   carry accepted entries through both source proposals and retained-control
   target relays, collect prepared-target certificates once at the coordinator,
   carry them in the same ephemeral validation
   sidecar, verify them locally at source validators, and delete both
   accepted-then-refetch duplication and validator target fan-out.
4. **Message-driven progress.** Replace every normal retry timer with exact
   owner notifications, add the identity-scoped `quod_directory` property on
   the existing owner, then delete the retry configuration and stale tests.
5. **Source fusion and asynchronous Complete.** Reuse the existing reducers,
   update the proposal-readiness/reducer matrix, remove source-local
   Prepare/Finalize, and move Complete outside the visible result's critical
   path.
6. **Conflict-safe DTX batching.** Generalize the one ledger batch/projection,
   extend the retained-control registry's ready selection, replace every
   singular projection consumer, delete the singleton control format, and
   activate only after adversarial review plus a coordinated clean re-found.
7. **Hardware acceptance.** Test fresh and warm A -> B -> C -> D at concurrency
   1, 2, 4, 8, and 32; repeat after history growth, restart, endpoint change,
   and committee change while monitoring logs and all process/mailbox counts.

After slices 3--5, warm concurrency-one A -> B -> C -> D must reach p99 below
500 ms before batching is credited with any result. After slice 6, same-source
concurrency-four must remain below 500 ms p99 for non-conflicting chains rather
than forming a queue staircase. Concurrency 8 and 32 are reported honestly and
must show bounded admission wait, stable throughput, no lost/duplicate outcome,
and no residual worker/mailbox growth. One-target p99 must not regress above
500 ms.

Correctness gates include conflicting read/write groups, target refusal,
uncertain replies, duplicate and crossed responses, crash after every phase,
replay/catch-up, stale endpoint, key rotation, committee change between
Finalize and Complete, malformed evidence attachments, and a slow or Byzantine
participant. Exact same operation ids must appear in every participant ledger,
and every accepted group must reach one terminal outcome.

The non-vacuous additions are: a Byzantine proposer attaches well-formed but
wrong evidence and validators fall back to certified follow; two groups with
overlapping OCC read/write tokens serialize while a disjoint pair batches; a
second caller joins a resumable catch-up between two pages and both observe the
same advancing prefix; and every fused Begin/Decision transition is exercised
in the existing proposal-readiness/reducer matrix, including apply-blocked,
stale, replay, and crash cases.

#### Rejected architectures and shortcuts

- **Make B own the operation claim:** loses the stable A operation lookup when
  the proof discovers B only after the request was signed, and cannot represent
  two possible participant sets under one operation id.
- **Keep five phases and only carry evidence faster:** removes repeated fetches
  but cannot remove the one-active-group queue; it cannot meet concurrent
  same-source latency unless each complete group becomes unrealistically tiny.
- **Allow uncoordinated parallel active groups:** mutating unrelated state from
  several coordinators without one exact conflict reducer breaks OCC and
  creates overlapping recovery state. Only the canonical,
  conflict-checked batch projection in section 4.7.7 may admit overlap.
- **Create a special movement/write endpoint:** duplicates the executor and ACL
  and is forbidden.
- **Have the client submit directly after proof:** a lost gateway response still
  leaves no authoritative A claim, and two gateways can discover different
  target sets for the same operation.
- **Reuse an identity certificate across requests:** its statement binds one
  request digest and ProofId; reuse after a key change would authorize a new
  request with old evidence.
- **Reduce `N-f` identity attestation to `f+1`:** two `f+1` sets may intersect
  only in Byzantine members and certify conflicting current keys.
- **Add fixed worker/count limits as a latency fix:** it replaces queueing with
  refusal. Any future resource policy belongs to the node ontology and a
  separately reviewed byte/work owner, not this protocol.

## 10. Required adversarial and performance tests

- A signed foreign singleton produces one `remote_claim` in A, one ordinary
  target transaction in B, and one asynchronous `remote_complete` in A. It
  produces no Begin, Prepare, Decision, Finalize, Complete, target-side
  operation claim, or invented A authorization transcript.
- Four concurrent claims from one A and their four ordinary B transactions are
  eligible for their respective existing micro-batches and never enter the
  multi-ontology group-control path. Every operation retains its own request digest,
  target transaction id, ACL/OCC result, failure reasons, and public operation
  reference.
- The predicted B transaction id is identical before and after attaching its A
  claim certificate. Duplicate valid evidence, a different certificate
  encoding for the exact claim, and submissions authored by different current
  B validators converge on that id. A wrong operation, request digest, target,
  plan, transcript, or predicted transaction reference is rejected before
  application.
- Lost connection/reply and process/node death before claim commit, after claim
  commit, during B submission, after B apply/reject, and before/after receipt
  commit recover to the same operation outcome without re-proof or mutation of
  the target transaction. Only pre-claim work may be abandoned.
- Key rotation before the A claim rejects the request. Rotation after the
  certified claim neither cancels nor re-authorizes it; B validates the
  accepted claim and still applies its current target ACL/OCC rules.
- A B policy change, stale target-plan signer, immutable-policy violation, and
  OCC conflict after the A claim each produce one durable bounded rejected B
  outcome and an A receipt. Framework failures populate the existing failure
  reasons; no claimed operation remains permanently unresolvable.
- Exact duplicate operation id/digest returns the first B outcome; the same id
  with another digest is invalid in proposal preview, vote validation, ordered
  apply, replay, and catch-up. A claim racing an existing local operation is
  arbitrated by the one origin operation projection.
- Replay with thousands of terminal operations schedules none of them. It
  schedules exactly the claims without a valid completion receipt. A duplicate
  exact receipt is idempotent; a conflicting receipt cannot change a terminal
  operation.
- A foreign singleton direct effect uses the same claim/ordinary-target/receipt
  path. Crash at every prepare, claim, transaction, apply, and journal-release
  seam yields at most one external effect, one target outcome, and one receipt;
  abandoned pre-claim staging is retired. Kill the proof before source dormant
  registration (no target row), after source dormant registration, after target
  binding, during exact cancel, and after claim activation; each leaves either
  one recoverable C or one certified cancellation, never a timer-retired claim
  that can later commit. No DTX-only effect binding remains.
- A genuine two-target write still runs Begin, both Prepares, one Decision,
  both Finalizes, and Complete atomically. A one-target group is rejected by
  every active decoder/admission seam after the hard break.
- A local signed no-change operation retains its ACL-checked operation claim.
- A remote no-op is authorized by B and never by an invented A transcript.
- A valid carried A claim or B result advances the existing foreign cache
  exactly once and satisfies the exact reference without a network pull. A
  duplicate is idempotent. A malformed entry, wrong identity/anchor/slot/hash,
  wrong role, invalid certificate, non-contiguous parent, or omitted
  membership-changing predecessor never supplies evidence; the ordinary
  certified pull either fills the gap or returns the existing retry result.
- Live and recovery submissions use the same carried-entry ingestion seam.
  Killing the recovery owner, one receiving validator, or the reply link at every
  handoff leaves no sidecar owner or waiter behind and recovery converges from
  the durable records without trusting transient evidence.
- Timeout, caller death, link death, and namespace restart reclaim parked
  requests through the same finish function; every secondary index is empty.
- A maximum supported committee can obtain its required distinct replies; no
  eight-worker deadlock remains, and two concurrent maximum request sets do
  not collide on one hosted ontology's cross-operation correlation ceiling.
- Warm hardware runs report concurrency 1, 2, 4, and 8 against one source and
  target, the same load spread across source ontologies, and A->B->C->D reads
  and writes. The release gate is zero failed writes, warm same-source
  concurrency-four p99 below 500 ms, correct ledgers/outcomes after quiescence,
  zero unexpected restart or warning/error/critical log, and no leaked owner
  row, worker, monitor, or material mailbox growth. Every asynchronous receipt
  must be durable before the run is called quiescent. Cold-history latency and
  bytes are reported separately rather than mixed into the warm percentile.
- More than 32 simultaneous certified-history pulls, more than four requests
  from one authenticated peer, and overlapping different phase/reference
  claims for the same ontology identity make progress through the one
  foreign-log/catch-up ownership path. Shared cache advancement occurs once,
  every claim is evaluated separately, dead/expired callers leave no row, and
  no work is silently dropped into the 8-second timeout. Separate tests pin
  the approved foreign-log 32 node-wide and catch-up 32-per-ontology defaults,
  finite updates, `unlimited`, restart/reprojection, and wake-without-rejection.
- Two enrolled nodes with different dedicated node ontologies project only the
  policy bound to their own exact `agent_instance_ref/3`. Shared `quod:node`
  facts, a raw node key, wrong namespace/anchor/instance, duplicates, malformed
  values, and stale certified state cannot configure an owner. Restart rebuilds
  the same projection; lowering a value does not kill already active work.
- Retained controls that are blocked on an exact same-group apply fence do not
  activate a namespace-global consensus barrier. The canonical readiness
  function treats that same-group Complete as blocked, while broader retention
  rule still admits a legal future role-acquisition control. Ready controls
  stay ordered, byte-accounted, and are retired from
  every index once after commit, supersession, or proof that current durable
  state makes them obsolete. Caller timeout/link death reclaims only that
  waiter; it never discards accepted durable recovery work.
- Restart Simplex with a mixed ready/blocked retained population. Rebuild exact
  ready/blocked/digest/waiter indexes and the correct barrier state from
  coordinator/replay state; the signing journal contains exactly one pending
  Begin and no envelope, waiter, or byte reservation is duplicated.
- A request using a 255-byte agent namespace plus maximum 8 KiB instance and
  goal fields round-trips through browser encoding, unresolved-operation
  journaling, submission, and outcome lookup. A separate boundary assertion
  accepts the exact 22,426-character unpadded Base64url admission ceiling
  derived from 16,819 bytes and rejects one character more. The test also pins
  journal-before-send, omission defaulting to the exact session expiry, and an
  explicit earlier caller expiry. A later value is clipped once at session
  expiry.
- A pre-Begin request valid beyond the old 30/60-second boundaries is not
  failed by a shorter internal timer. A shorter signed expiry terminates
  proof, scope, identity, and internal admission work at the same boundary;
  fake-clock/timer tests prove no internal call outlives its remaining budget.
  The same expiry observed after durable Begin detaches the client only and
  recovery still reaches one terminal result.
- Proof and scope worker admission remains at the current 64 until its
  node-instance default is explicitly approved. Tests pin aggregate/per-goal
  memory, the frozen MVCC floor, and the 64 MiB emergency heap kill; any later
  finite or `unlimited` policy activation gets its own non-vacuous tests.
- Client routing admits 257 simultaneous outbound correlations and,
  independently, 257 cursor routes; expiry/DOWN removes every reverse index.
  It also admits 65 inbound workers and 9 from one authenticated forwarder
  without leaving a per-forwarder counter/path.
- Scope routing admits 513 entries across valid proof owners and 17 scopes to
  one target peer, while one proof still rejects its ninth scope. A separate
  513th inbound identity attestation receives a correlated result/cleanup
  instead of silent drop; collector, target-link, owner, and timer death empty
  every index exactly once. Seventeen target scopes from one authenticated
  peer remain subject only to the current total scope-worker policy (64 until
  its node-instance default is approved). A
  deterministic state/API seam may cross 513 where spawning that many live
  processes would make the test itself unsafe, but it must fail under the old
  `<512` guard.
- More than eight verified routes for one ontology and more than 2,048 route,
  known-namespace, and signer-high-water rows are admitted without any
  population refusal. Authentication, identity, freshness, replacement,
  direct-seed confirmation, and expiry still work through the same directory
  owner. A future policy-driven direct-seed removal contract is explicitly out
  of this slice and has no vacuous test here.
- A node advertises more than 32 hosted descriptors across a complete signed
  generation. The receiver installs it only after all bounded records/pages
  verify; missing, duplicate, reordered, stale-epoch, wrong-digest, and
  wrong-version input is rejected while the prior generation remains live.
  None of those failures advances high-water or renews the old lease. Readers
  see only the active-generation marker, never old/new union; expiry/restart
  discards incomplete state, while completed manifest/chunks relay through
  resync. The old format is rejected after coordinated activation, and no
  claimed count causes allocation or becomes a product ceiling.
- More than 128 root contacts pass exact validation/deduplication without a
  compiled count refusal. More than 2,048 authenticated peers can own bounded
  resync sessions which expire/replace cleanly. If the four-active-dial
  scheduler becomes policy, finite/update/unlimited behavior is tested; if it
  is deleted, queued contacts still progress through the one QUIC owner.
- Ordinary signed custody and relay cross their former 2,048-row thresholds
  without `busy`, population trimming, loss, or duplicate submission during
  owner lifetime. Unsigned waiting crosses the former 512-total/64-author
  counts and is governed only by the node-wide byte accountant and signed
  deadline. A Simplex crash releases every monitored reservation once and
  surfaces `outcome_unknown`; the browser unresolved record remains and no
  automatic resubmit occurs. Relay completed-result caching crosses 2,048,
  expires normally, and answers a duplicate without repeating admission.
  Completion transfers/resizes rather than drops the cache reservation;
  post-sign observer detachment does not release it. An accountant-only crash
  closes admission, rebuilds exact live and recovered reservations without
  double counting across Simplex/accountant races, then reopens with no lost
  bytes and no invented ingress/relay process owner.
  Tests must fail under each deleted old guard; they must not call 2 MiB an
  approved default.
- Authentication projects exact local-node facts with defaults 256/256 and
  tests a smaller finite value, `unlimited`, zero/disabled admission,
  update/restart, lowering without evicting live rows, and missing/conflicting/
  malformed/wrong-anchor facts failing loudly. TTL/pruning remains and no
  per-agent rate or population quota appears. The node genesis contains the
  only active founding handler and pinned bridge; a dynamically asserted
  handler stays inert. First-founder ingress/effect bootstrap, later
  enrollment, atomic bootstrap-to-node handoff, replay, bridge crash,
  node-ontology loss, and recovery never select two policy sources or an
  app-env fallback.
- A released effect that never returns in namespace A cannot stop an effect in
  namespace B reaching `applied`. Two effects for A never overlap, including
  different anchors for the same namespace. Repeated retry, worker DOWN, and
  deadline in A neither tight-loop nor starve B; every manager
  monitor/timer/lane index drains through its one finish path, while the
  journal owns no lane index.
- Pause A after its external lifecycle mutation but before the journal writes
  terminal state, let B finish, then restart the journal and separately the
  namespace manager/application. Volatile lane indexes rebuild from durable
  released rows re-registered by the journal; A's satisfied desired state
  prevents duplicate IO, B remains terminal, other lanes resume, and stale
  old-worker replies are inert.
- Direct lifecycle calls, journal effects, and reconciliation for one namespace
  share the same namespace-manager lane while different namespaces overlap.
  Caller death, timeout, worker DOWN, and restart empty every manager index
  exactly once; a stress run observes parallelism above one globally and one
  at most per lane, with no identity/payload metric labels.
- Existing current gauges return to zero after completion, DOWN, timeout, and
  restart; peak reset semantics and fixed histogram buckets are documented,
  and a registry scrape proves no identity-derived metric labels.
- The capacity audit has no unexplained numeric operational gate and no stale
  macro, public limit field, `busy` branch, test, comment, or document remains
  after an approved cap is removed.
- A Byzantine responder cannot make Complete valid, and an unready Complete
  cannot starve ordinary origin traffic.
- Multi-target Prepares, Finalizes, and applied checks each overlap within one
  correlated wave; their verified results enter the coordinator snapshot in
  canonical target order.
- After Slice 4's hard break, every active DTX validation seam rejects a
  one-participant group; the same signed foreign operation succeeds only
  through the batchable claim/ordinary-target/receipt path. Genuine groups
  still reject zero, malformed, duplicate, or over-limit participant sets.
- Live one-target and A->B->C->D benchmarks report phase counts and latency,
  while all node logs remain free of warnings/errors/crashes.

### Verification gates for every implementing slice

Every server slice must pass `rebar3 compile`, full EUnit, xref, dialyzer,
`git diff --check`, its focused unit suites, and the relevant distributed
Common Test gates (including `quod_ask_SUITE` and signed remote DTX coverage
when those seams change). Threshold regressions must be non-vacuous: each test
must demonstrably fail on the deleted guard/path rather than merely assert a
successful small case. Run a stale macro/error/config/comment/doc sweep for
every removed semantic.

Every slice touching shared browser code must additionally pass client tests
and build, UI typecheck, lint, tests, and build, then compare both
`priv/client` and `priv/explorer` asset trees byte-for-byte with clean builds.
Every deployed slice must run its stated live concurrency/latency scenario and
inspect all allocation logs and metrics for warnings, errors, crashes, leaked
rows, and gauges that fail to return to zero.

Documentation closure includes every file listed in section 5.1, especially
`doc/distributed-proof-plan.md`: remove its stale `512/8 cannot
self-throttle` claim and its nonexistent authenticated-DTX `16 requests/s,
burst 32` claim, and split its conflated “foreign-history 32” row into
foreign-log exact monitored verification work (no population quota) and
catch-up server workers (32 per hosted ontology today). Sweep code, tests, metrics,
configuration, comments, generated client assets, and all architecture
documents for removed fields and semantics.

Deployment closure states explicitly: Slice 0 was behavior-compatible; Slice
1's endpoint fix and Slice 2's historical one-participant widening were already
deployed and measured. Slice 4 replaces that temporary singleton group shape,
changes the canonical transaction/ledger format, and activates only through the
coordinated clean re-found already required by the agent-identity release. It
has no rolling mixed-version decoder and no ledger migration path. No final
release/no-hard-limit claim is made until Slices 0.10a--f are closed.
The separately classified consensus `MAX_OUTBOX = 1024` remains a transport
review item and prevents any broader claim that *all* operational limits in
Quod have been resolved; this DTX plan neither silently removes nor ignores it.

## 11. Expected result

For the common signed foreign-only write, Slice 4 replaces five serialized DTX
blocks with two latency-critical ordinary batchable blocks: A's durable claim
and B's normal transaction. A's completion receipt is also batchable and runs
asynchronously after the client-visible target outcome. Same-source operations
can therefore share blocks instead of waiting for earlier groups to finish.
The explicit hardware gate is warm p99 below 500 ms at concurrency four from
one source to one target, with the concurrency curve and every stage shown
alongside it. No result may be inferred from consensus microbenchmarks or from
load spread across different source ontologies.

For genuine groups, the protocol remains atomic. Each node coalesces phase
verification through its one foreign-history owner; the coordinator reuses the
exact entry it received, and source proposal evidence gives every validator
the same independently verified acceleration opportunity. Complete verifies
one reviewed post-apply certificate rather than launching a fresh fan-out per
source validator. A source participant reuses Begin/Decision instead of adding
local Prepare/Finalize blocks. Non-conflicting groups share the same canonical
consensus batches; conflicting groups remain ordered. The independent warm
A -> B -> C -> D gates are p99 below 500 ms at concurrency one before batching
is credited, then p99 below 500 ms at same-source concurrency four after the
conflict-safe batch projection lands.

Most importantly, the faster path restores the architecture rather than adding
a fast lane: one Prolog proof, one target ACL, one plan/check-and-apply family,
one ordinary transaction batcher, one certified-history verifier, one durable
operation recovery owner, and one terminal outcome. DTX remains exactly where
distributed atomic agreement is actually required.
