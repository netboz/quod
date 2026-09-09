# Phase 1B hardware results — 0.7.155

Measured 2026-09-09 after all three implementation cuts passed review. Cut 1
is `e4ad3e1` (0.7.153 bump `43bd48c`), Cut 2 is `8ca87e8` (0.7.154 bump
`dd98f53`), and Cut 3 is `ecb7861`; the separate 0.7.155 bump is `49f3759`.
The baseline remains the independently reviewed
[0.7.152 Phase 1A measurement](phase-1a-hardware-results.md).

**Result, independently reviewed and approved by Claude:** all 400 measured writes
committed, with no failed, pending, uncertain or slow request excluded.
One-hop mean decreased **29.89% at c1 / 43.89% at c4**. Request-level and
worker-level attribution each exceed 95% on both complete one-hop runs.
The absolute gates **still fail**: c1 p50 **365 ms > 300 ms** and c4 p99
**1180 ms > 450 ms**. Behavior through 10,000 entries is **not measured**.
These are development measurements, not release-safety closure or authority
for another implementation change.

The review leaves two diagnostic findings open: the c4
`quod.prolog.operation_result` mean regressed **14.81%**, and the serial
1,625 ms request lacks the slot-level tracing needed to distinguish its four
candidate triggers. Neither is explained away by the overall improvement.
The next trace-only cut is described in
[the diagnosis handoff](consensus-result-tracing.md); consensus-area changes
remain subject to review before commit and deployment.

## 1. Deployment and matched fixture

- Image: `192.168.1.11:5000/quod:0.7.155`; registry digest
  `sha256:651178442315ec10244abf0ed921203685b0f77769538a912604fdcc8f17ad0d`.
- All old home and cloud allocations stopped before the coordinated restart.
  The live Nomad job changed only its three Quod image references. Anchored
  ledgers, node identities, vote journals and both old fixtures were retained;
  no purge, re-found or persistence-format migration occurred.
- The fleet remains eight home allocations plus two cloud allocations. Both
  cloud roots were already incompatible before 0.7.152; they remain preserved,
  excluded from the benchmark, and are not counted as healthy replicas.
- Fresh `quod:trace155-source` uses home indexes `[0,1,3,7]`; fresh
  `quod:trace155-target` uses `[2,4,5,6]`. Each committee is N=4, with disjoint
  node keys sharing three physical machines. Source gateway 0 does not host
  the target. Ordinary root creation, hosting, observer synchronization and
  readiness-gated admission established the fixture; there was no route or
  protocol shortcut.
- The browser signing implementation, encrypted development key, agent
  `trace_agent(clean).`, assertion goal, one gateway and run order match the
  control. Goals and agent-instance text retain their final dot. Two committed
  smoke writes precede, but are not included in, the 400 measured requests.
- **Matched shape, not identical history:** initial source height is 4 here
  versus 5 in 0.7.152, whose setup included a rejected admission record. Both
  targets initially have height 4. First-three source preflight heights are
  7/107/132 here versus 8/108/133 before; both targets are at height 5 before
  the measured one-hop run. Later batching/receipt heights also differ. Older
  fixtures remain resident, so the total background state is not identical.
- Resources, 25 ms batch window, four-scheduler VM settings and 5% background
  sampling remain unchanged. Measured requests are explicitly sampled. The
  corrected persistent OTLP receiver is `.10:4318`; no runtime exporter
  workaround or tracing restart was needed for this matrix.

## 2. Latency — every request, milliseconds

Nearest-rank percentiles; each row contains 100 requests. All-request and
successful-only statistics coincide because every measured request committed.

| Path | Concurrency | 0.7.152 mean / p50 / p99 | 0.7.155 mean / p50 / p99 |
|---|---:|---:|---:|
| Local | 1 | 55.79 / 55 / 80 | 54.47 / 54 / 63 |
| Local | 4 | 78.59 / 78 / 89 | 75.32 / 74 / 93 |
| One-hop | 1 | 544.16 / 544 / 665 | 381.50 / 365 / 498 |
| One-hop | 4 | 1558.56 / 1609 / 1797 | 874.46 / 870 / 1180 |

Serial one-hop maximum is **1625 ms**, not its 498 ms p99: nearest-rank p99
for n=100 is the 99th observation. The c4 maximum is **1232 ms**. Neither was
trimmed or replaced. Local c4 p99 increased from 89 to 93 ms; this single pair
does not establish a general tail-latency improvement.

### Within-run growth and scope

Requests are ordered by start time and numeric sequence, never completion.

| Path | 0.7.152 first / last 25 mean | 0.7.155 first / last 25 mean |
|---|---:|---:|
| One-hop c1 | 523.32 / 548.40 | 354.64 / 452.00 |
| One-hop c4 | 1407.64 / 1592.92 | 798.20 / 877.00 |

The all-request serial OLS slope is 0.959 ms/request, R²=0.0443; c4 is
1.027 ms/request, R²=0.0570. The serial maximum remains in the last-25 mean
and regression. These short runs neither prove flat cost at scale nor meet
the 10,000-entry gate. Source/target heights progress 132/5→334/105 during
c1, then 334/105→426/130 during c4.

## 3. Complete request and worker attribution

All 100 traces from each one-hop run were fetched sequentially after the
workload. Source proofs are pinned by namespace, ancestry and the client
allocation, independently of trace-batch ordering. Their direct-child local
interval unions have zero overlap in these traces. The following segments
are non-overlapping per-request means; nested diagnostics are not added.

| Request segment, mean ms | c1 | c4 |
|---|---:|---:|
| Driver time outside server request | 4.106 | 5.575 |
| Server time outside source proof | 6.225 | 35.835 |
| Invocation | 129.497 | 307.451 |
| Source claim | 75.753 | 98.165 |
| Operation result | 161.396 | 418.656 |
| Other named direct proof children | 3.076 | 6.988 |
| Unattributed proof residual | 1.446 | 1.791 |
| **Driver total** | **381.500** | **874.460** |

Using unrounded values, server means are 377.394 / 868.885 ms; subtracting
their proof residuals gives request attribution **99.6168% / 99.7939%**.
The inherited `client_ms` JSON field names that server request span, not the
driver's outer latency; the aggregate report makes the distinction explicit.

`foreign.current` occurs once per request and averages **121.103 / 296.152 ms**,
down **57.03% / 71.67%** from 281.837 / 1045.506 ms. It is nested in invocation.
Operation result is now the largest direct source-proof stage; its c4 mean
**increased 14.81%**, from 364.642 to 418.656 ms. This cost is not hidden by
the improvement elsewhere. All 200 traces contain **zero ledger index scans**;
real claim-evidence and target-application spans supply positive controls.

There are **99 / 24 observed unique verification workers**, not 100 per run:
concurrent callers share work. Worker means are **121.936 / 372.544 ms** and
local clipped-union residuals **0.799 / 0.913 ms**. Their independent coverage
gate passes at **99.3444% / 99.7550%**, with zero analyzer issues. Coverage is
a ratio of elapsed means, not an average of per-worker percentages.

| Worker direct stage, mean local union ms per observed worker | c1 | c4 |
|---|---:|---:|
| Initial/suffix page fetches | 61.290 | 216.103 |
| Final confirmation | 29.794 | 79.531 |
| Page verification | 19.312 | 63.493 |
| Ledger append | 8.215 | 9.125 |

The old confirmation means were 83.750 / 275.093 ms; verification was
46.564 / 236.180 ms and append 18.213 / 63.488 ms. Changes to the three cuts
were measured together; these comparisons do not isolate each cut's saving.
Old page-fetch intervals were not separately instrumented: the old residual
cannot be equated with a pure network or identically measured page-stage cost.

Nested page diagnostics observe 887 / 216 spans: mean page wait is
11.199 / 35.259 ms and decode 11.038 / 32.165 ms. Page wait includes acquisition,
transport, owner work and scheduling. Parallel pages overlap; page stages and
confirmation probes must not be added to their containing worker intervals.
Canceled probes may not finish/export. No cross-node clock subtraction or
marginal-percentile subtraction is used.

## 4. The 1625 ms request — what is known and why is still unresolved

Serial request 79, trace `3a1e1799809547cfae3b6a64a35ba7f1`, committed once.
Its full trace and [outlier analysis](/tmp/quod-phase1b-155-p5yRUw/benchmark/outlier-analysis.json)
are retained. Source claim owns 1315.713 ms, including a 1306.971 ms consensus
append and a source-local proposed→commit-reply interval of 1287.653 ms.
`foreign.current` is 84.964 ms; the two evidence opens are approximately
0.117 / 0.111 ms. These measurements locate the long wait, not its cause.

The durable history shows block 289 contains a duplicate receipt for request
78 alongside request 79's new claim. The receipt is already recorded in block
288; this is valid validator-recovery overlap, not client resubmission. The
shared validator still checks that receipt's foreign reference before the
outcome index recognizes the replay. This is a real dependency in the block,
not proof that it caused this occurrence.

Across the c1 run the proposer records exactly one approval above one second
and one proposal redrive; all four source watchdog counters increase 0→1.
The proposer's final commit-phase samples all remain ≤25 ms. This points to
support/approval recovery rather than a long final commit, but these are
whole-run counters, not a per-slot record of the late message or verdict.

The critical journal/ledger subspans are missing in this measured version:
`trace_context_for_slot/2`
uses only the batch's first waiter context, here the autonomous receipt rather
than the sampled request. Tempo's slot-289 signing-span search is empty.
We therefore cannot distinguish delayed reference verification, abstention
followed by redrive, parent-state waiting, or transport loss. No index-scan
span in the retained request trace does not rule out untraced history work
inside receipt validation. **The containing approval stall is localized;
its initiating cause is not established.**

The [full investigation](/tmp/quod-phase1b-155-p5yRUw/OUTLIER-1625.md)
records source references, events, counters and the coverage hole. The next
focused diagnosis needs the existing block/validation owner's context and
verdict, support and watchdog edges—not a shorter timer, a receipt-validation
bypass or a new owner. Any consensus-facing change retains review-before-commit.

## 5. Health, retention and durable receipts

During the four-run matrix, all eight home tasks had zero Nomad restarts,
runtime health 1, no warning/error/supervisor/export-failure log records and
zero discarded Tempo spans. Eleven startup/setup warnings precede the matrix:
three no-download-contact warnings and eight worker-cancellation/reconciliation
warnings. They converged before measurement and remain in the complete logs.
The older 0.7.152 pre-stop logs also retain their separately disclosed transient
exporter failures; a clean measured window is not a clean-lifetime claim.

Afterward source/target are synchronized at **426/130**. Existing consensus,
DTX, endpoint and proof-worker queues are zero. No unresolved-operation row
gauge exists, so those gauges are not used as a receipt substitute.

The first durable-history audit verified **201/201** one-hop operation chains
(smoke plus 200 measured writes), each with its source claim, target application
and source completion, and zero DTX control rows. This does not claim there
are no duplicate valid metadata rows. Checks bind operation IDs,
request digests, target transaction IDs, the exact application→source-claim
transaction reference, both namespace/anchor pairs and matching agent refs.
No operation was resubmitted to obtain a receipt. This audit used the measured
allocation generation; it is not an additional post-restart recovery test.

## 6. Offline analysis corrections and evidence

The scratch analyzers were corrected before the final aggregate analysis:
source-proof selection no longer depends on batch order or picks a target
proof; direct-child unions exclude other allocations; receipt checks include
the full anchored claim link; incomplete runs retain raw attempt counts,
failure latencies and timestamps even when companion metadata is absent;
worker manifests reject duplicate request/trace IDs and incomplete sets.

Twelve analysis tests and five driver tests pass, with twelve script syntax
checks. Negative controls cover target-first batches, clock-offset children,
wrong claim/anchor bindings, duplicate manifests and partial runs. Compatibility
controls reproduce all **200** old trace residuals, **201** old receipt bindings
and all **four** accepted 0.7.152 latency/growth rows without changing that archive.
`PREPARATION.json` fingerprints the frozen scripts and browser modules. The
initial fingerprint generator failed with a syntax error; its transcript is
preserved as `PREPARATION.initial-failure.txt`. An intermediate fingerprint with
missing child-test output counts is retained as `PREPARATION.pre-freeze.json`;
the final record requires explicit non-vacuous 12/5 passing counts.

Evidence root: `/tmp/quod-phase1b-155-p5yRUw/`:

- Build/push logs, image-only job diff, stopped-allocation proof, deployment
  manifests, `pre-deploy-health/` and `retention-check.jsonl`.
- `benchmark/`: discovery, fixture/action journals, state snapshots, per-run
  raw TSV/statistics/metadata/preflight/metrics and complete trace manifests.
- `aggregate-owner-summary.json`, `AGGREGATE-ATTRIBUTION.md`,
  `worker-attribution.json`, both `attribution-all.json` files and input hashes.
- `receipt-audit.json`, raw paginated histories, `outlier-analysis.json`, and
  `health/{post-deploy,matrix-before,matrix-after}/` complete logs and scrapes.
- Portable archive target: `/tmp/quod-phase1b-0.7.155-evidence.tar.gz`; archive
  creation and its checksum are recorded separately at handoff.

The stop command's CLI exited 1 while monitoring the previously failed
deployment. Independent allocation reads proved all ten captured old tasks
terminal before the new job was submitted; this is not hidden as a clean
stop-monitor exit or treated as a failure to stop the fleet.

The reviewed source gates remain EUnit **1850/0**, ask CT **26/26**, QUIC CT
**26/26**, xref/Dialyzer/diff-check clean on the reviewed cut; these are prior
implementation gates, not new runs during measurement. No production change
was added while deploying or measuring. Yan's five write-lanes files remain
excluded. Independent hardware review is closed; absolute latency, 10,000-entry,
Q4, result authentication, finality, L2 and compaction retain their own gates.
