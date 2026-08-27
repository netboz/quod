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
only a few milliseconds. The remaining common-path cost is the five durable
blocks plus repeated independent verification of the target's newly committed
Prepare and Finalize. This is the measured input for Slice 4, not a solved
latency claim.
The node-local policy work is deliberately gated on the existing physical-node
identity plan rather than inventing a temporary configuration authority.

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

### 4.2 Keep Begin, Decision, participant Finalize, and Complete

Under the current contract these records are not removable:

- Begin freezes the exact operation and participant plans before any target
  locks.
- Prepare gives each target a durable ACL/OCC decision and lock.
- Decision prevents different participants from choosing different outcomes.
- Finalize orders publication/discard in each target ledger.
- Complete proves to any later reader that every participant applied the same
  decision, clears the origin role, and stores a transferable terminal result.

Returning success at Decision could remove latency only by changing
`committed` to mean "chosen but perhaps not visible at the targets." That is a
different API and is not part of this plan.

### 4.3 Later option: fuse a real origin participant into origin phases

When A contributes real material, its committee currently runs separate local
Prepare and Finalize blocks even though Begin and Decision are committed by the
same committee in the same ledger. A later protocol revision may validate and
lock A's plan in Begin, then apply/discard it in Decision by reusing the same
Prepare/Finalize reducers.

This can remove two more local blocks without weakening a check, but it changes
the reducer and recovery format more deeply. It is deferred until the smaller
foreign-only change is measured and reviewed.

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
| retained semantic DTX controls / waiters in Simplex | 8 participants + 1 = 9 controls and 1 waiter per semantic digest, per hosted ontology | an unrelated valid control or second live waiter gets `busy`; any parked control also activates the consensus barrier, even when it is not proposal-ready | keep the existing Simplex custody owner; refactor one canonical DTX readiness predicate, digest registry, ready/blocked indexes, monitorable waiter ownership, byte accounting, and retire path; only then remove both population counts |
| removed `QUOD_MAX_FOREIGN_PENDING` / `_PER_PEER` | was 32 per node / 4 per peer | certified-history work could get `busy`; one already-active identity separately returned `history_busy` | retain the one cache writer per identity; share concurrent current-view requests for that identity even when their route hints differ, and retain exact monitored ownership/deadlines instead of a population refusal |
| `quod_catchup:MAX_INFLIGHT` | 32 read workers per hosted ontology | excess certified-history pulls are silently dropped, so a valid caller waits the full 8-second pull timeout | keep the wire unchanged; replace the counter with owned request rows and the same approved named active-work default 32; excess reads wait and start on worker completion, while expired/dead-link rows finish once and never disappear into the client timeout |
| outer Simplex coordinator-owner failure state | saturates at 16; retry 100 ms to 3.2 seconds | bounds only restart-backoff bookkeeping and never abandons durable recovery | keep recovery unbounded; represent only the actual backoff state and delete its unreachable 5-second constant |
| coordinator process retry | 100 ms to the configured 5 seconds | replans/retries one durable group; this 5-second maximum is reachable | keep as the coordinator's distinct recovery scheduler; do not conflate it with the outer Simplex owner |
| effect-journal active custody | Root policy default 64, dynamically settable or `unlimited` | a new effect-bearing DTX can be refused before custody | keep: this is the explicitly approved committed Prolog policy owner; document that `unlimited` still retains terminal rows and increases full-snapshot disk rewrite cost |
| effect execution | one journal worker per node plus one namespace-manager mutation worker/FIFO per node; no journal attempt deadline or heap kill; the manager's 15-second caller timeout does not cancel its worker | one wedged bridge blocks every later effect, then the namespace manager can move the same blockage downstream; the earliest repeatedly unavailable row can starve unrelated rows | keep journal custody/reconciliation, but make the existing namespace manager the sole per-namespace physical-mutation lane owner for journal effects, direct calls, and reconciliation; one manager finish path owns result/DOWN/deadline and different namespaces overlap |
| relay completed-result cache | 2,048 rows plus expiry | an authenticated redrive can lose its cached terminal reply by unrelated population trimming and repeat admission work | remove the count in Slice 0.10d; retain expiry and exact submission identity, and carry its bytes in the same node-wide reservation acquired before relay admission |

Other direct post-Begin controls are retained and named rather than mistaken
for node-wide admission quotas:

| Control | Value | Classification/decision |
|---|---:|---|
| Simplex signature worker | 2 seconds | per-attempt failure bound; keep, instrument, and wake progress by message |
| validator foreign DTX verification | 6 seconds | per-validation attempt bound; keep under durable recovery and measure |
| retained-control relay retry | 300 ms | failure retry only; local admission already wakes immediately after Slice 0 |
| generic consensus maintenance tick / Delta | 300 ms / default 1 second, application-configurable | fallback liveness, never normal DTX readiness discovery |
| maximum quorum rearms / pipeline depth | 3 / 1 | consensus-state shape, not transaction-population policy |
| per-peer consensus outbox / dial timeout | 1,024 / 15 seconds | transport liveness/backpressure; not a DTX phase owner and requires a separate transport review before change |
| current-view route candidates | at most 64 validator keys, at most 2 endpoints each | bounded candidate shape for one committee view; keep with the 64-validator protocol bound |
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
| Simplex ordinary signed custody | 2,048 rows / 8 blocks = 2 MiB per hosted ontology process | a node-signed submission whose certified outcome is still unknown gets `busy` at either threshold | once signed, retain the exact row in the existing Simplex custody owner until certified inclusion/exclusion during that owner lifetime and never drop it because of a count. Reserve through the node-wide `quod_ingress_budget` before retention. Ordinary restart semantics remain `outcome_unknown`; 2 MiB is temporary code, not approved architecture |
| Simplex relay pending | 2,048 rows per hosted ontology process | forwarded pre-Begin submission gets `busy` or waits | remove the separate count; retain one exact relay row only while its custody row needs placement, wake it on link/view/progress events, and use the same pre-sign byte owner rather than a second queue or policy |
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
admission ceilings; 512 KiB result and 528 KiB result envelope; 128 KiB scope envelope;
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

Progress messages must wake work immediately on both sides; timers remain
failure or cleanup bounds. The outer Simplex coordinator-owner failure state
does not terminate recovery: its exponential delay reaches 3.2 seconds and
can never reach its declared 5-second maximum, so that owner's stale maximum
and redundant count state are removed. The coordinator process has its own
retry scheduler whose configured 5-second maximum is reachable and remains.

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

## 6. Keep the Complete preflight, but share and parallelize it

The coordinator checks participant application before submitting Complete;
then every source validator checks again before voting.

Only the validator check is security authority. The coordinator check is still
useful as a liveness preflight: without it, an unready Complete can enter the
origin consensus slot, repeatedly abstain, and delay unrelated origin work.
Therefore it is not deleted in the first optimization.

Refactor it instead:

- use the existing `quod_dtx_current_view:verify_applied_many/3` once for all
  targets rather than the coordinator's one-target-at-a-time path;
- wake each target request from actual apply progress as described above;
- keep validator `verify_complete_applied -> verify_applied_many` unchanged;
  and
- document that the first check protects availability while the second grants
  authority.

The coordinator observation and validator verification deliberately do not
share a cached verdict: they have different trust owners. They must, however,
call the **same** verifier implementation. Once the coordinator is migrated,
delete the singular production `verify_applied/4` path if it has no remaining
consumer.

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

The first remote target may need to fill the existing certified foreign-history
cache to verify the certificate issuer's committee. Later calls reuse that
owner. This is not a consensus round. Do not add a second identity cache or
accept a self-authenticating committee claim merely to save a pull. Measure it
before considering a compact portable committee proof.

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
  `observation_started_at`, relay retry time, exact envelope bytes, placement,
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
  exactly one pending Begin body/envelope, never this registry or later phase
  rows. Startup inserts that recovered Begin through the same registry helper;
  coordinator/replay state and authenticated remote retry reconstruct later
  phases through normal submission. No volatile row is falsely described as
  crash-durable.

#### One readiness decision

- Replace the boolean `quod_dtx:proposal_allowed/2` scheduler hint with one
  pure `proposal_readiness/2` result: `ready`, `{blocked, active_group}` or
  `{blocked, apply}`, or `stale`. Its phase table is derived from the existing
  reducer transitions and covers the active group, `consensus_lock`, and the
  phase-specific `proof_fence` rules. The certified reducer remains final
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
- Let one Simplex `retention_disposition/3` add only the replay-owned
  `dtx_last_group` exclusion to that result. A completed group is stale;
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
  fingerprint is the committed DTX projection plus `dtx_last_group`; this one
  seam covers committed projection changes, exact `finalize_applied`, replay,
  and recovery. Initial insertion and re-sign use the same placement helper.
  Do not scatter event-specific reclassification branches through callbacks.

Here, `{blocked, apply}` means the local committed projection has the exact
`proof_fence = {pending_apply, ...}` that prevents this phase from being driven
until the existing `finalize_applied` acknowledgement. It does not describe a
Complete whose *remote* participant preflight has not passed; that remains the
existing verifier path in section 6.

`stale` is terminal for this Simplex copy: use it when the exact record is not
proposable now or after the exact local pending-apply acknowledgement. Every
such local apply condition must be represented by a `{blocked, _}` result so
custody is preserved rather than refused. Other protocol progress is redriven
from the origin-owned authenticated relay retry, rather than duplicating
cross-node custody in this registry.

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
  already use `dtx_endpoint_local/3` or the authenticated DTX endpoint. This
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
   work, the journal still contains exactly one pending Begin, sequence floors
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

### Slice 4 -- measure before deeper protocol work

- profile a one-target write and A->B->C->D read/write goals;
- measure identity certificate, scope execution, sealing, attestation, each
  consensus phase, apply wait, Complete verification, and response flush;
- add only bounded labels (`phase`, `result`), never identities, goals, or
  payloads; and
- add/update Explorer/operations dashboard panels for every new stable metric,
  after metric names and buckets survive the implementation reviews; and
- decide from evidence whether origin-phase fusion is worth its format change.

## 10. Required adversarial and performance tests

- A foreign-only write produces exactly Begin/target Prepare/Decision/target
  Finalize/Complete; A has no Prepare or Finalize.
- Lost replies at every phase recover to the same operation outcome without
  resubmission.
- Key rotation after Begin does not cancel accepted recovery; a stale key
  before Begin is rejected.
- Target ACL denial and OCC conflict happen before target Prepare commits.
- One-participant commit, abort-before-Prepare, abort-after-Prepare, replay,
  coordinator crash, and Prolog restart converge.
- A local signed no-change operation retains its ACL-checked operation claim.
- A remote no-op is authorized by B and never by an invented A transcript.
- Wrong/malformed applied wakeups are inert; exact wakeup answers once.
- Timeout, caller death, link death, and namespace restart reclaim parked
  requests through the same finish function; every secondary index is empty.
- A maximum supported committee can obtain its required distinct replies; no
  eight-worker deadlock remains, and two concurrent maximum request sets do
  not collide on one hosted ontology's cross-operation correlation ceiling.
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
- Retained controls that are blocked on apply do not activate the consensus
  barrier. The canonical readiness function treats a local
  `proof_fence={pending_apply,...}` as blocked, while the broader retention
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
- Multi-target Finalizes overlap in time while Prepares remain ordered.
- All five one-participant validation seams accept one and still reject zero,
  malformed, duplicate, or over-limit participant sets.
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

Deployment closure states explicitly: Slice 0 is behavior-compatible and may
roll independently. Slice 1's endpoint fix must be deployed and pass the live
maximum-committee gate before Slice 2. The one-participant Slice 2 then needs
one coordinated restart of the fleet but no re-found and no ledger deletion.
No final release/no-hard-limit claim is made until Slices 0.10a--f are closed.
The separately classified consensus `MAX_OUTBOX = 1024` remains a transport
review item and prevents any broader claim that *all* operational limits in
Quod have been resolved; this DTX plan neither silently removes nor ignores it.

## 11. Expected result

For the common signed foreign-only write, the plan removes two of seven
consensus blocks and the normal 100 ms apply-retry step. It also removes
serial work across independent targets. The measured 692 ms result should fall
materially, but the implementation must report actual hardware numbers rather
than promise a synthetic threshold.

Most importantly, the faster path remains the existing path: one Prolog proof,
one target ACL, one plan/verifier family, one DTX reducer, one recovery owner,
and one terminal outcome.
