# Consensus and result-return diagnosis after Phase 1B

Status: diagnostic implementation and independent consensus-area review
complete; approved for commit and preserved-ledger deployment. Both gate
runs passed EUnit 1867/0, ask/QUIC CT 26/26, Simplex CT 12/12, xref,
Dialyzer and diff-check. Hardware reproduction is still owed.
Base: `49f3759`, Quod 0.7.155, branch `claude/next`. Yan authorized adding
the necessary traces. Claude approved the [hardware evidence](phase-1b-hardware-results.md),
not a behavior change. Consensus/DTX changes retain review-before-commit.

## 1. Questions and retained evidence

The serial 1,625 ms request is trace
`3a1e1799809547cfae3b6a64a35ba7f1`. Invocation took 93.290 ms, including
84.964 ms in `foreign.current`; source claim took 1,315.713 ms. Of that,
1,287.653 ms was between proposal and committed reply for source slot 289.
The block combines a previous operation's already-committed, valid duplicate
receipt with the new claim. This is a dependency to investigate, not proof
that the duplicate caused the stall. Whole-run watchdog/redrive counters
cannot locate the triggering event in this slot.

The missing slot-level spans came from choosing an unsampled first waiter's
context. The candidates remain delayed foreign-reference verification,
abstention without a subsequent wake, delivery loss, and waiting for the
parent's applied state. The retained evidence cannot select one.

Separately, the c4 `quod.prolog.operation_result` mean grew from 364.642 ms
on 0.7.152 to 418.656 ms on 0.7.155: **+14.81%**. It is not hidden by the
overall improvement. Its target-application subspan is not another DTX group;
these one-hop requests have zero DTX controls. Neither the total recovery
span nor a background receipt after the client reply belongs wholesale in
client critical-path arithmetic.

A further read-only re-analysis uses ordered timestamps on the same source
allocation, with exactly one result/evidence/application span per request and
matching worker-parent IDs. Across all 100 requests in each run:

| Disjoint result interval, mean ms | c1 | c4 |
|---|---:|---:|
| Result wait start to claim-evidence start | 0.365 | 0.765 |
| Claim evidence | 2.896 | 14.534 |
| Claim evidence end to target-application start | 1.775 | 2.722 |
| Target-application call | 141.245 | 359.896 |
| Target-application return to result-wait end | 15.116 | 40.738 |
| **Operation-result total** | **161.396** | **418.656** |

Every unrounded per-request sum equals its result interval; no cross-node
clock subtraction or marginal-percentile arithmetic is used. The last row
before the total remains a **location**, not a proven decoder or mailbox
cause. The target-application call includes routing, transport, target commit
and response handling, not just execution. Reproducer and per-trace hashes:
`/tmp/quod-operation-result-tracing-Dj3Cuu/operation-result-tail.mjs` and
`operation-result-tail.json` (new analysis of the old captures, not a new run).

The same c4 decomposition on the accepted 0.7.152 raw traces locates the
regression within those intervals:

| Result interval, mean ms | 0.7.152 c4 | 0.7.155 c4 | Change |
|---|---:|---:|---:|
| Before claim evidence | 0.849 | 0.765 | −0.084 |
| Claim evidence | 40.099 | 14.534 | −25.565 |
| Claim to target application | 2.734 | 2.722 | −0.012 |
| Target-application call | 294.182 | 359.896 | **+65.714** |
| After target application | 26.778 | 40.738 | **+13.960** |
| **Operation-result total** | **364.642** | **418.656** | **+54.014** |

All 100 requests per run are included; c4 needs no clipping. The corresponding
c1 comparison is 163.294→161.396 ms. Two 0.7.152 c1 evidence spans start
0.066085/0.127231 ms before the result wait; their intersections with the wait
interval are used, not negative segments or omitted requests. Baseline
manifests are `/tmp/quod-a1a4-152/onehop-c1-n100/attribution-all.json` and
`/tmp/quod-a1a4-152/onehop-c4-n100/attribution-all.json`. The larger positive
change is **inside the target-application call**, not only the final handoff.
This does not distinguish a regression in service time from changed queueing
under a now-faster proof path; that requires the next capture.
Reproducer: `/tmp/quod-operation-result-tracing-Dj3Cuu/operation-result-comparison.mjs`;
full 400-request comparison: `operation-result-comparison.json` alongside it,
SHA-256 `b363c2c719aa9aac18eaa7e1faa51b60b49b74a89b3fa66fc1815f3439e8bad8`.

Evidence is preserved under `/tmp/quod-phase1b-155-p5yRUw/`, especially
`OUTLIER-1625.md`, `benchmark/outlier-analysis.json`, the two one-hop runs'
raw `traces/`, and `benchmark/aggregate-owner-summary.json`. The frozen archive
is `/tmp/quod-phase1b-0.7.155-evidence.tar.gz`, SHA-256
`5f869ba5c129bd8099672d883ae568ea18094b31bc8fcd79f1d8c6df19a8587b`.

## 2. One existing tracing and execution path

1. Extract the existing committed-apply parent selection into
   `quod_trace:shared_context/1`. Both apply and block work choose the first
   recording participant and link the other distinct valid contexts. When
   none records, preserve sampling; do not manufacture a sampled root.
   Contexts remain transient, never signed or stored in canonical bytes.
2. Use that selection for ledger sync, vote-journal sync and the existing
   content foreign-verification worker. Block-attributed work requires the
   exact slot **and block hash**; complaints and skips remain slot-only.
   No extra block hashing, entry decoding or verification is introduced to
   obtain trace metadata.
3. Mark existing consensus transitions: well-shaped share received (explicitly
   **not** a signature/weight verdict), notarization, finality received,
   durable append, durable vote, foreign verdict, parent verdict, validation
   worker death, watchdog firing, and actual proposal redrive. Observe the
   existing decisions; do not add a timer, wake or re-drive.
4. Carry context through the existing Prolog parent-verdict cast and parked
   row. Events mark send, receive, park, resume, stale, supersession and
   expiration. A child span covers only synchronous validation computation.
   The original TTL, exact reply correlation and lifecycle remain unchanged;
   tracing does not own a parked span, cancellation map or deadline.
5. In the existing operation recovery worker, distinguish local-outcome read
   and returned-evidence decoding from target application. Worker start and
   result notification delimit scheduling and handoff. The short
   `quod.operation.result_notify` span ends before background receipt work;
   events solely on the enclosing recovery span would be insufficient,
   since that enclosing span was absent from 75/100 c1 and 25/100 c4 archived
   traces. At Simplex, mark wait
   send/receive, recovery spawn, exactly bound target-result acceptance and
   readiness to reply. The latter is emitted before releasing the caller,
   which may immediately end its span; it is not an acknowledgement. A
   duplicate or mismatched worker result must not emit a
   second accepted-delivery event.
   The source's `quod.operation.result_delivery` is also a short independent
   span: the owner retains the claim transaction's context, whose span ends
   before that claim's caller is released. Tests cover both live and already-
   ended parent contexts, so delivery does not rely on extending a finished
   claim span or introducing another waiter-context map.

Only namespace, existing numeric state, closed classification strings and
hex block/operation IDs are recorded. No raw principal, goal, key, payload or
failure term is added. Use existing SDK export/sampling configuration.

## 3. Coverage boundary and next capture

The existing proposal wire carries no request trace context. This change
does **not** claim a connected distributed span on every remote validator.
It closes the mixed-batch proposer hole and follows that owner's spawned
verifier and asynchronous local parent check. An uninstrumented remote
validator's silence still cannot be classified as delivery loss versus
remote verification merely from the proposer's missing shares. If the next
capture localizes the delay there, report that boundary before extending
transient transport tracing; do not infer the cause from a watchdog count.

This diagnosis is for ordinary content/claim/receipt blocks, not DTX group
controls (the measured one-hop fixture contains none). The shared Prolog
facades are both tested, but the production DTX caller's three-element
parent tag and foreign-worker context are unchanged; this is not a claim of
new end-to-end DTX-control trace coverage.

After review, capture ordinary requests overlapping autonomous receipts on
the preserved N=4 fixture, at c1 and c4, without resubmission or deadline
tuning. Correlate namespace, slot and block hash. Keep every failure and
outlier in the statistics. Compute non-overlapping per-request intervals and
means, clipping recovery to the client interval; never subtract marginal
quantiles or sum overlapping worker spans. Distinguish local validation from
waiting for peers, and actual signature/quorum verdicts from raw arrival.

The existing 0.7.155 measurements remain the baseline. No improved latency or
proven outlier trigger is claimed by instrumentation alone. No duplicate-
receipt verification bypass is included: that requires a separately reviewed
immutable-claim/byte-identity and authentication contract. Finality, Q4, L2,
compaction and result-authentication work retain their existing gates.

## 4. Tests and gates

Tests must demonstrate recording-parent selection for an unsampled receipt
followed by a sampled claim; exact-hash isolation; exactly-once business
callbacks; a real spawned verifier with valid and invalid evidence; parent
park/resume/stale/expiry/supersession with unchanged replies; and result
handoff events only after the existing binding gate. SDK spans, events and
links are inspected directly, not mocked into existence.

Final sequential gates: clean-build EUnit, ask CT, QUIC CT, Simplex CT, xref,
dialyzer and `git diff --check`. Record actual counts and development failures
in the review handoff. Do not commit or deploy this diagnostic cut before
the consensus-area review is green. Yan's write-lanes document/SVG edits
remain excluded.

Local results, 2026-09-09: focused **405/0**; clean-build sequential EUnit
**1867/0**, ask CT **26/26**, QUIC CT **26/26**, Simplex CT **12/12**, xref,
dialyzer and diff-check all exit 0. Logs:
`/tmp/quod-consensus-tracing-gates-xXc2Nv/final/`.

Development history remains visible in the parent directory: an incorrect
SDK event-field name during focused compilation; three initial test-only
assertion errors (SDK link maps versus stored records, nested EUnit macro
capture); and the first full run **1865/1**, where an unchanged proof test
selected differently traced spans by name alone. An exact-trace selector and
real-SDK ambiguity/missing-child regression now pin that fixture without
loosening its ancestry assertions. The original interfering producer is not
identified by the old log. The later source-result test covers an already-
ended claim parent explicitly. No protocol tuning was used to pass a test.
