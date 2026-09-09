# Write latency anatomy

**Status: measured on the N=4 development fleet through Quod 0.7.151. The
request-level attribution gate is closed. This document is the single owner of
the measured write-path anatomy and performance evidence.**

This document replaces the temporary `single-write-trace-attribution.md` plan.
The tracing hierarchy it described is implemented and diagnostic only: it does
not alter authorization, consensus, durability, deadlines, or results.

## 1. Measurement rules

- Include every request, including failures and pending outcomes.
- Attribute one request with non-overlapping source-clock intervals. Target
  spans explain a source wait; they are not added again.
- Use sums and means. Marginal percentiles cannot be added or subtracted.
- At least 95% of the increase in mean latency must be assigned before choosing
  an optimization.
- Traces prove a request path; driver TSVs prove the population.

## 2. Healthy local-write floor

The clean 0.7.151 N=4 fixture committed all 200 local writes:

| concurrency | n | mean ms | p50 ms | p99 ms |
|---:|---:|---:|---:|---:|
| 1 | 100 | 55.75 | 56 | 61 |
| 4 | 100 | 81.76 | 78 | 168 |

A representative local write spends about 1--2 ms in HTTP handling, 4 ms
proving, 10 ms in admission/checkpoint work, and 56--64 ms in N=4 consensus.
The round includes crash-durable support and commit votes and one ledger
`datasync`; observed examples include about 12.5 ms and 1.5 ms vote sync and
16.6 ms ledger sync.

| work | class | consequence |
|---|---|---|
| proof, ACL, request binding | current contract | never bypass |
| N=4 quorum communication | current protocol | not the measured seconds |
| vote-journal and ledger sync | durability | Phase 1 preserves it |
| batch window | configuration | visible inside consensus, not the height slope |

The local path is the measured floor, not a declaration that the current
protocol is physically optimal.

## 3. Retained-ledger symptom

After the completion-lifecycle correction in 0.7.145, uncertainty disappeared:
100/100 one-hop c1, 100/100 one-hop c4, and 100/100 L1 c1 committed. Their
all-request means were 4,088.90 ms, 6,794.27 ms, and 5,702.81 ms. Retained
trace `7192b9e0076837ab83fa90a51792a898` has a 4,116.19 ms proof but only a
72.20 ms source transaction. Consensus does not own those seconds.

Evidence: `/tmp/quod-h1-145.vPDphR/`. This is a pre-cut baseline and cannot be
compared directly with a future post-re-found protocol.

## 4. Controlled clean-ledger result

The clean 0.7.151 N=4 run completed all 400 requests with no failure, pending,
uncertainty, or Quod task restart:

| path | concurrency | n | mean ms | p50 ms | p90 ms | p95 ms | p99 ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| local | 1 | 100 | 55.75 | 56 | 59 | 60 | 61 |
| local | 4 | 100 | 81.76 | 78 | 87 | 90 | 168 |
| one-hop | 1 | 100 | 1,152.32 | 1,156 | 1,558 | 1,658 | 2,052 |
| one-hop | 4 | 100 | 3,704.56 | 3,723 | 4,409 | 4,542 | 4,834 |

The serial one-hop path grew during its own run:

| request | total | invocation | `foreign.current` | source claim | operation result | claim scan | application scan | residual |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 358.632 | 11.721 | 0.379 | 71.354 | 264.359 | 88.455 | 6.863 | 1.241 |
| 25 | 836.451 | 314.602 | 304.508 | 67.218 | 446.750 | 246.016 | 85.096 | 1.195 |
| 50 | 1,150.066 | 335.889 | 329.244 | 77.930 | 722.967 | 462.310 | 181.588 | 1.132 |
| 75 | 1,439.393 | 337.313 | 330.179 | 67.134 | 1,029.790 | 684.626 | 261.473 | 1.180 |

These non-overlapping source intervals explain 99.65%, 99.86%, 99.90%, and
99.92% respectively. The attribution gate is met.

### 4.1 Linear scan evidence

| request | ontology | entries | bytes | scan ms | framing us | decode us |
|---:|---|---:|---:|---:|---:|---:|
| 1 | source | 134 | 410,673 | 88.455 | 874 | 87,509 |
| 1 | target | 6 | 19,083 | 6.863 | 172 | 6,653 |
| 25 | source | 184 | 715,529 | 246.016 | 1,603 | 244,319 |
| 25 | target | 32 | 181,111 | 85.096 | 438 | 84,614 |
| 50 | source | 240 | 1,063,846 | 462.310 | 2,596 | 459,594 |
| 50 | target | 70 | 418,117 | 181.588 | 942 | 180,586 |
| 75 | source | 301 | 1,451,770 | 684.626 | 3,258 | 681,230 |
| 75 | target | 97 | 586,648 | 261.473 | 1,501 | 259,897 |

Across requests 1/25/50/75, total latency grows 14.377 ms/request
(R2 0.9821), the source scan 8.122 ms/request (R2 0.9955), and the target scan
3.483 ms/request (R2 0.9986). After request 25, the scans explain effectively
all continuing slope. Decode and cryptographic verification, not file framing,
dominate them.

## 5. Proven owner and correction

On the measured 0.7.151 baseline, `quod_simplex` already owned an open verified
ledger and sparse index, exposed through `ledger_read_snapshot/1`, and
`quod_ledger_store` offered `open_ro_snapshot/1`. Yet
`operation_claim_evidence_at/5` and `transaction_evidence_at/5` reopened the
hosted ledger with `open_ro/2`, rebuilding and validating the full index for
every remote write. Phase 1A replaces the separate source/snapshot accessors
with one deadline-bound `history_view/3` and both evidence scans with bounded snapshot reads;
these measurements are pre-change evidence, not optimized results.

Both evidence APIs first resolve the live `quod_simplex` owner. A stopped or
non-hosted full-scan fallback at these sites is therefore not recovery: no
owner exists to serve the operation. Phase 1A must consume that owner's
immutable snapshot and exact sparse-index lookup. If the owner cannot issue a
snapshot, return existing `not_ready` and let the existing message-driven
operation lifecycle wake progress. Delete the live full-scan path rather than
preserving a second slow path.

This adds no cache, verifier, owner, poll, timer, cap, or format change.

### 5.1 The same defect elsewhere

A production-wide source audit of the pre-cut tree found that the measured
functions were not the only callers treating a ledger path as a live read
capability. The following is the diagnosis that Phase 1A replaces, not the
remaining-open inventory of the implementation candidate:

- catch-up serving has a snapshot fast path but falls back to a complete
  `open_ro` scan when the live Simplex owner is not ready;
- co-hosted foreign following opens the local ledger merely to read its tip;
- the subscribed foreign projection worker reopens and scans its verified
  cache on every projection page;
- cold foreign-cache replay opens the cache once, then mistakenly calls the
  path-based page server which reopens and rescans it again for every page;
- Explorer rebuilds the index for each block/transaction HTTP request, even
  while a live owner already holds it (explicit stopped-ledger inspection is a
  separate cold mode, not a live fallback);
- runtime founding discovery rebuilds the index to read slot 1.

The cache replay case is worse than a repeated constant tax. The foreign-log
owner opens its cache once, but each replay page calls the path-based catch-up
server. Because the internal cache namespace has no Simplex owner, that server
falls through to `open_ro`, rescans the complete cache, reads one bounded page,
and closes it. Replaying `p` pages therefore rebuilds progressively the same
index `p` times: quadratic work in history size rather than one cold scan plus
one linear semantic replay.

The catch-up audit also found a separate consistency defect: after 32 server
workers, a valid request is silently discarded and its caller learns that only
when the request deadline expires. It did not cause the measured serial slope,
but it is the same wrong ownership style—time substitutes for an explicit
result. Phase 1A deletes the fixed cap/drop branch and keeps the request's
existing byte/frame bounds.

These are the same ownership error even when they were not exercised by the
benchmark. Phase 1A replaces all of them with immutable sessions captured by
the existing live owner. It also opens the catch-up phase-index backfill from a
snapshot, although that recovery path must still semantically fold its prefix
until certified recovery snapshots exist.

Three full opens are legitimate today because no live indexed owner exists
yet: ontology startup discovering an existing ledger, Simplex restoring its
state, and the first open/rebuild of a foreign-history cache. Each may rebuild
the index once and must then reuse that handle/session throughout its semantic
replay. They are named cold-recovery debt, not allowed fallbacks from a live
request. The compaction phase replaces their full replay with authenticated
snapshot plus suffix.

This inventory comes from every production call to `quod_ledger_store:open/2`
or `open_ro/2`, followed through its callers. The remaining direct `read_at`,
`read_range`, and `fold` sites already consume an owned handle and do not
reconstruct an index per request. Outcome and phase DETS indexes likewise stay
open under their existing owners; replacing them would not address this
measured defect.

## 6. Separate `foreign.current` plateau

The 304--330 ms plateau is not a full replay. Traces show the foreign ledger
session resuming in about 0.5 ms, followed by suffix fetch, verification,
persistence, and certified-tip confirmation. The current path is already
O(suffix).

Each one-hop request advances the source ontology with a claim and later a
receipt. On the next scope open, the target verifies the source agent against
the newest certified source view, fetching the new suffix even when the
agent's key and committee era did not change. Merely promising “O(suffix)”
does not improve this.

The proposed Phase 1B historical-era shortcut failed adversarial review. The
statement binds its signing key, request, expiry and committee id, but does not
prove that the signatures were made while that committee was current. A fully
retired committee retaining old keys can sign a new request after replacement
and choose a fresh `not_after`; finding that committee in certified history
would wrongly accept it. An expiry is not a non-backdateable issuance anchor.

Current-head/current-committee verification therefore remains mandatory. A
future reduction of this plateau requires current-era endorsement,
forward-secure era keys, or an equivalently non-backdateable certified issuance
event. It is a separate cryptographic design, not part of the ledger-open fix.

## 7. Honest targets

Subtracting the two non-overlapping scans from the same request gives the
following counterfactual. These are neither new measurements nor percentile
estimates; all other work is held unchanged:

| request | total minus its claim and application scans, ms |
|---:|---:|
| 1 | 263.314 |
| 25 | 505.339 |
| 50 | 506.168 |
| 75 | 493.294 |

The earlier 263 ms estimate used only request 1, whose `foreign.current` cost
was 0.379 ms. Later requests pay 304–330 ms there. With that verification
retained, eliminating only the two scans does not substantiate a warm p50 of
300 ms. The wider owner refactor may remove additional serving work, but its
benefit must be measured; it cannot be assumed in the target. The current
one-hop path also commits a source claim and target application sequentially.

- Phase 1A: no live evidence `index_scan`, flat work versus height, provisional
  c1 p50 target at most 300 ms. This target is currently unsubstantiated by
  scan removal alone; keep it explicitly open rather than declaring it met or
  relaxing it to the counterfactual above.
- Phase 1B: no implementation or 450 ms claim until the retired-committee
  backdating attack has a reviewed cryptographic answer.
- A 60--120 ms one-hop result requires a named one-round protocol design; local
  ledger reuse alone cannot promise it.

Targets are gates, not guarantees. Contradictory traces change the plan before
more code is added.

## 8. Evidence and caveats

Clean archive: `/tmp/quod-trace-151-clean/HANDOFF.md`. Trace ids:

- request 1: `97bffa9e4a264f04a49538e2987c8ddb`
- request 25: `9604426ab6b549e88e61d694cfebb562`
- request 50: `0b48fe37adfb4bcfb7364eae0e862665`
- request 75: `28fce46e93f74f36b5b1f1fb11b01b80`

The request TSVs and exported traces are authoritative. This invocation's
`.prom` URLs omitted `/metrics`, so those files contain the exporter landing
page and support no claim. Tempo OOM-restarted under 16 concurrent large trace
queries; later evidence was fetched serially. Quod did not restart.

## 9. Separate correctness finding

The trace audit reproduced an unresolved live-result authentication mismatch.
Application-response correlation accepts the same inclusion evidence with a
committed or rejected status; inclusion alone does not authenticate the OCC
outcome. Terminal recovery already uses the current-view outcome verifier, but
the live response does not yet have the same authority. Reproduction:
`/tmp/quod-result-auth-audit.Z63tSQ/quod_result_auth_audit_tests.erl`.

This correctness/security issue belongs at the shared result authority. It
must be reviewed and closed before the one-hop result contract is declared
complete. The preferred permanent direction is a certified block commitment to
each included transaction's deterministic applied/rejected outcome, verified
by the same committed-projection reducer. That makes the existing block
certificate authenticate both inclusion and status, like a blockchain receipt
commitment, without adding an outcome certificate or verifier. It should be
bundled with the finality format cut only after the proposal contract explains
how validators deterministically compute and verify ordered outcomes from the
exact parent, including same-block OCC, while preserving or explicitly
replacing pipelining. Until then, only the existing quorum current-view outcome
lookup can authenticate the status; a one-peer endpoint field cannot. Tracing
neither causes nor repairs it.
