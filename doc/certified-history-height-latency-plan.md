# Certified-history height-latency correction plan

**Status: H1 instrumentation and attribution are complete on Quod 0.7.151.
The 95%-of-mean-increase gate is met. The former phase-index H2 hypothesis is
rejected by measurement; the next work is Performance Roadmap Phase 1A, after
review. This document authorizes no implementation.**

The permanent measurements and trace ids are in
[write-latency-anatomy.md](write-latency-anatomy.md). Sequencing and gates are
in [performance-roadmap.md](performance-roadmap.md). This file retains the
height-latency problem, measurement contract, and conclusions so discarded
hypotheses do not return.

## 1. Problem

A warm signed one-hop write becomes slower as the source and target ledgers
grow. This is a base-path defect, not limited to atomic multi-ontology DTX.
Normal execution must be independent of total ledger length.

Earlier evidence showed about 149 ms around height 80 and about 400 ms around
height 7,000, reset by re-found. The first request after restart near height
7,000 took 34.6 seconds; that cold-start/compaction problem remains separate.

## 2. Invariants

1. The ledger is durable authority; indexes, materialized state, foreign
projections, and future snapshots are derived and reconstructible.
2. `quod_simplex` remains the sole local consensus/ledger owner.
   `quod_foreign_log` remains the sole foreign certified-history/current-view
   owner, and `quod_catchup` the sole page grammar/verifier.
3. Hot reads and writes use current indexed state or immutable owner snapshots.
   They do not replay or rescan history.
4. A height wake is a freshness signal, never evidence. New foreign material
   is verified through the existing certified-history path.
5. Progress is message-driven. No polling, retry-delay ladder, keepalive loop,
   second cache, verifier, owner, ACL, or hard capacity/history limit.
6. Uncertain writes are not resubmitted automatically.
7. Optimizations preserve exact byte identity, committee-era checks, OCC,
   authorization, and durable result semantics.
8. An immutable ledger session is a byte/index capability, not a new proof
   MVCC base or transaction savepoint. Existing proofs retain their base,
   bindings, continuation and current overlay across ordinary appends and
   backtracking; explicit `transaction/1` controls staged rollback and never
   forgets influencing reads. See Roadmap §3.5 for the binding semantic tests.

## 3. Completed H1 measurement

The 0.7.151 clean N=4 fixture submitted 100 requests in each of local c1,
local c4, one-hop c1, and one-hop c4. All 400 committed with no failed,
pending, or uncertain result.

| path | concurrency | mean ms | p50 ms | p99 ms |
|---|---:|---:|---:|---:|
| local | 1 | 55.75 | 56 | 61 |
| local | 4 | 81.76 | 78 | 168 |
| one-hop | 1 | 1,152.32 | 1,156 | 2,052 |
| one-hop | 4 | 3,704.56 | 3,723 | 4,834 |

Four representative serial traces at request positions 1, 25, 50, and 75 are
99.65%, 99.86%, 99.90%, and 99.92% attributed using non-overlapping source
intervals. This closes H1's 95% gate.

The continuing slope is two full evidence-ledger opens per request:

- source claim scan: 88.455 ms at 134 entries, 684.626 ms at 301 entries;
- target application scan: 6.863 ms at 6 entries, 261.473 ms at 97 entries;
- source scan slope 8.122 ms/request, R2 0.9955;
- target scan slope 3.483 ms/request, R2 0.9986;
- after request 25, the scans explain effectively all continuing latency
  growth.

Framing costs only 0.17--3.26 ms. Canonical decode and cryptographic validation
consume effectively the whole scan. The evidence does not blame disk bandwidth
or consensus.

Archives: `/tmp/quod-trace-151-clean/HANDOFF.md` and
`/tmp/quod-h1-145.vPDphR/` for the separately labeled retained baseline.

## 4. Resolved hypotheses

### 4.1 DTX phase index — not the owner

The original DETS suspicion came from bulk dirty inserts, not a settled table
plus one row. The corrected diagnostic measured dirty suspend at roughly
0.169 ms for 80 rows and 0.237 ms for 10,000; resume measured 0.215/0.255 ms.
The request traces independently place the linear cost in ledger index scans.
The proposed phase-index backend replacement is retired. Do not revive it
unless new post-cut evidence names that owner again.

Archive: `/tmp/quod-h1-phase-discriminator-XO3RT9/report.md`.

### 4.2 Foreign current view — already suffix-based

`quod_foreign_log` already resumes its certified cache and verifies only the
new suffix. In the 0.7.151 traces, ledger resume is about 0.5 ms; suffix fetch,
verification, persistence, and tip confirmation form the 304--330 ms plateau.
It is not a full-height scan and does not own the continuing slope.

Each remote write advances the source with a claim and receipt, so the target
performs this suffix work again at the next scope authentication even when
agent key and committee era are unchanged. The proposed Phase-1B shortcut of
validating only the named historical committee is unsafe: retired members can
use retained keys to sign a new request with a fresh expiry, because the
statement carries no non-backdateable proof that issuance occurred while that
committee was current. Latest-head/current-committee verification remains the
authority until a separately reviewed cryptographic design closes that attack.

### 4.3 Consensus — healthy for this diagnosis

Local N=4 writes complete around 56 ms serial. Source claim spans remain about
67--78 ms in the representative remote traces. Consensus matters to the final
floor but does not cause the history-proportional seconds.

## 5. Phase 1A correction boundary

`operation_claim_evidence_at/5` and `transaction_evidence_at/5` call
`quod_ledger_store:open_ro/2`, rebuilding the ledger index. Their public entry
points already locate and call the live `quod_simplex` owner. Other live local
history callers receive only its ledger path even though the code already has
the richer `local_reference_source` map used by local DTX verification.

Consolidate these paths under the wider live-ledger rule in
[performance-roadmap.md](performance-roadmap.md) §3: in one Simplex owner turn,
validate the requested identity/readiness and return one immutable ledger
snapshot with its matching verified projection. Make the evidence readers,
local read certification, local outcome lookup, catch-up serving, co-hosted
following, runtime founding and Explorer consume that same owner view. The
foreign-log owner similarly passes its retained cache session to its existing
projection worker instead of letting each page reopen the cache path.

Coalesce a foreign target's height/head/session as one view and retain its
verified contiguous prefix. Distinguish owner/worker incarnation from target
height: superseded publications cannot establish the current view, but an
ordinary append does not invalidate an admitted read or restart a proof.
Runtime owner readiness is transient; verified malformed founding remains a
permanent error.

Current evidence opens the snapshot through `open_ro_snapshot/1` and performs
exact `read_at/2`. Older committee-era verification retains the one historical
verifier because it needs the semantic state at that slot, but it uses the same
snapshot as its byte source instead of reopening the path. Delete path-only
live-source alternatives from `quod_dtx_current_view`, `quod_foreign_log`, and
the catch-up serving fallback once callers converge.

There is no stopped/non-hosted fallback at a live seam: without the registered
owner, evidence, network serving, and runtime cannot be current. Owner absence
or snapshot refusal returns existing `not_ready`; the current event-driven
lifecycle owns wake/recovery. Retaining `open_ro/2` there would preserve a dead
slow path and two ways to read the same live authority. Named cold owner
recovery may reconstruct an index, and Explorer may retain one explicit
stopped-ledger inspection mode; it may never enter that mode merely because a
live owner snapshot failed.

Review must verify:

- one atomic local-source capture and zero full index scan in every live local
  evidence/current-view path;
- byte-identical evidence and unchanged typed failures;
- immutable snapshot bounds under later append and changed-file refusal;
- the current append-only/no-file-replacement premise is explicit, and the
  future compaction contract invalidates old sessions across segment swaps;
- no stale result after owner death;
- resource closure on every path;
- unchanged local/co-hosted/remote backtracking, transaction savepoints,
  action prerequisites/postconditions, read dependencies, `fail_reasons`,
  sealing and cancellation, as specified in Roadmap §3.5;
- deletion of path-only local-source clauses and superseded helpers/comments/tests;
- zero index scan in catch-up serving, co-hosted following, subscribed foreign
  projection, runtime founding, and Explorer request paths;
- a closed inventory in which every remaining `open_ro` production caller is
  a named cold boot/gap-recovery owner or explicit offline inspection;
- no poll, retry timer, arbitrary cap, unbounded worker spawn/queue, cache,
  verifier, or compatibility branch; catch-up pressure stays at an existing
  link/owner and every admitted request gets a terminal answer. Roadmap A2's
  pressure contract must cover legitimate shared-link overlap and its exact
  completion wake; a busy refusal alone does not provide that wake.

## 6. Acceptance

Tests prove structural independence from history; hardware proves time. Unit
tests use no latency threshold.

Run the same N=4 topology at low height and at least 10,000 entries:

- one-hop c1/c4, at least 100 requests each;
- no excluded request, uncertainty, resubmission, route injection, or restart;
- traces show snapshot open plus exact sparse-index read and no evidence
  `index_scan`;
- evidence operations and decoded bytes are independent of height;
- provisional Phase-1A c1 p50 at most 300 ms.

Do not promise 120 ms from Phase 1A. Subtracting scans from request 1 leaves
263.314 ms, but requests 25/50/75 leave 505.339/506.168/493.294 ms because they
also perform current-committee verification. These per-request counterfactuals
are not a new p50, and do not substantiate the 300 ms target; report that gate
as open if the broader refactor does not reach it. The current path still makes
two sequential consensus commits. The rejected historical-era shortcut owns
no target; further reductions require a safe identity-freshness design and,
separately, a reviewed one-round protocol.

## 7. Cold start and compaction

Warm snapshot reuse does not solve restart replay. Future compaction separates
current materialized state, certified state snapshots, and optional archive
history while preserving one ledger protocol and one truth. See Performance
Roadmap Phase 4. No prefix can be deleted before snapshot, exact-reference,
committee-era, DTX-custody, and archive-availability obligations are proved.

## 8. Separate work

- live-result authentication mismatch in the anatomy §9;
- finality F1--F3 and coordinated re-found;
- cold-start/compaction;
- L2 write lanes;
- the roadmap's small-debt list.

None belongs inside the evidence-snapshot refactor. Post-finality measurements
use newly grown fixtures and a separately labeled baseline.
