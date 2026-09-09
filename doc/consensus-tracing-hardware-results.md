# Consensus diagnostic hardware capture — 0.7.156

Status: measured development evidence, independently reviewed and approved.
The diagnostic cut `ed17698` and separate version bump `ed64677` were
independently reviewed before commit and deployment. No protocol or
performance fix was introduced. The original 1,625 ms trigger and absolute
latency gates remain open.

## Deployment and fixture

Image `192.168.1.11:5000/quod:0.7.156`, digest
`sha256:e39b3dbc53f569c403ddcd764a1e8bde89b0dc573febfd44262a61d43741cc83`.
All ten old allocations were confirmed terminal before the replacement job
was submitted. The live job was cloned with exactly three image-reference
changes; sampler, resource, batch, OTLP and ledger settings were preserved.
All 40 hosted namespace/anchor pairs on the eight home nodes survived,
with no height regression. No purge, re-found, route injection or resubmission.

The existing `quod:trace155-source` and `quod:trace155-target` incarnations
were reused: source committee node indexes 0/1/3/7, target 2/4/5/6. Their
validator keys are disjoint, but allocations share three physical machines.
Gateway 0 does not host the target. The two cloud allocations remain excluded:
Nomad-loopback checks confirm running 0.7.156 tasks with zero restarts but no
hosted namespaces and retained `genesis_anchor_mismatch` root failures. This
is not a claim of ten healthy committee members. An unsuccessful direct cloud
Explorer read is archived separately; no cloud repair or measured traffic
was attempted.

This is a **retained-history diagnostic run**, not a fresh matched-height
performance comparison. Initial heights were source 426, target 130. After
two successful smoke writes and local controls, the one-hop c1 run grew
source 554→756 / target 131→231; c4 grew source 756→841 / target 231→259.
The 0.7.155 fresh-fixture baseline is retained separately; no causal speedup
is inferred from differences in this tracing-only deployment.

## Results — all requests, milliseconds

Measured window: 2026-09-09 16:45:10.859–16:46:23.553 UTC.
Each row contains 100 unique request IDs and trace IDs; no failures/outliers
excluded, no retries. Smoke results are excluded from latency rows but included
in durable receipt accounting.

| Path | Committed / attempted | Mean | p50 | p99 | Maximum |
|---|---:|---:|---:|---:|---:|
| Local c1 | 100/100 | 55.90 | 55 | 65 | 67 |
| Local c4 | 100/100 | 78.49 | 79 | 97 | 108 |
| One-hop c1 | 100/100 | 373.21 | 371 | 422 | 433 |
| One-hop c4 | 100/100 | 843.89 | 857 | 1167 | 1218 |

0.7.155 one-hop mean/p50/p99 was 381.50/365/498 at c1 and
874.46/870/1180 at c4. Serial median is slightly worse, not an improvement
claim. The serial p50≤300 and c4 p99≤450 ms gates both still fail.
10,000-entry behavior is not measured.

The eight measured allocations had zero restarts and zero warning/error
findings during the matrix. Eleven earlier startup warnings are archived;
the first discovery attempt also found one metrics service not yet healthy
and submitted no writes. The second read-only discovery succeeded. Final
source/target heights and applied floors agree across their four validators;
pending/work/custody gauges are zero. All **201 new remote operations** have
exact anchored claim/application/receipt bindings. Retained totals are
402 unique claims, 402 unique applications and 402 unique receipts; zero DTX
control rows. Physical occurrences are different: the new 201 receipts appear
260 times, with 59 second occurrences in later blocks. Target applications
are not duplicated. These valid repeated receipts are preserved, not excluded.

## Request and result attribution

All 200 one-hop traces were fetched sequentially. Zero `index_scan` spans.
Per-request local interval unions are computed before averaging: request
coverage is **99.5885% c1 / 99.5618% c4**, with residual means 1.516/3.675 ms.
Foreign verification-worker coverage is **99.1334% / 99.7484%** (99/24 shared
workers). These are *span-interval coverage*, not proof that every nested
function or scheduler wait has an exclusive attribution. Client root spans
average 368.381/838.764 ms versus driver totals 373.21/843.89 ms; driver/HTTP
boundary time is not silently added to the server trace's coverage claim.

| Interval/span, mean ms | c1 | c4 |
|---|---:|---:|
| Invocation | 97.365 | 274.479 |
| Source claim | 64.830 | 111.812 |
| Operation result | 191.334 | 405.327 |
| `foreign.current` (inside invocation; not additive) | 89.446 | 263.430 |

The operation-result stage was 161.396/418.656 ms on 0.7.155. Its serial
value is now **18.4% higher**, while c4 is 3.2% lower; the serial regression
remains visible despite a slightly lower overall mean.

The new result spans/events give complete disjoint partitions for all 200
requests, entirely on the source allocation's clock:

| Operation-result partition, mean ms | c1 | c4 |
|---|---:|---:|
| Before claim evidence | 0.385 | 0.892 |
| Claim evidence | 3.063 | 14.733 |
| Claim evidence to target call | 1.734 | 2.957 |
| Target-application call | 169.721 | 344.356 |
| Target return to evidence-decode start | 10.750 | 14.677 |
| Evidence decode | 3.279 | 4.633 |
| Decode to result send | 0.049 | 0.072 |
| Result sent to source-owner acceptance | 2.286 | **22.817** |
| Acceptance to reply-ready | 0.012 | 0.012 |
| Reply-ready to caller return | 0.055 | 0.178 |
| **Total** | **191.334** | **405.327** |

Rounded rows can differ from the total; every raw per-request partition sums
exactly. The former unexplained post-target tail is now 16.430/42.390 ms.
About half the c4 tail is delivery/scheduling at the existing source Simplex
owner, **not** outcome-index lookup (0.073 ms c4) or caller wakeup (0.178 ms).

The target endpoint's own duration is 115.115/206.894 ms: admission-to-evidence
100.979/139.749, evidence `read_at` 8.376/58.613, remaining endpoint work
5.759/8.532. Subtracting paired durations from the enclosing source call leaves
54.606/137.462 ms outside that endpoint span. This is a duration comparison,
not cross-node timestamp subtraction; its location is still unproven. Do not
name that remainder network latency or target execution without evidence.

## Two concrete slow cases and the remaining boundary

### Source block 786: after local support, not local parent validation

The slowest c4 request, 1,218 ms, is
`q1788972362334_2846940_37`, trace `e3fb5a132a984963a3a3b5c1f233b556`.
Its invocation/source-claim/result spans are 354.696/395.808/451.040 ms.
Source block 786's shared events are parented to another request in that same
batch, trace `81aba1ee1e0b4a129609a7d44a45c785`; all captured traces must be
searched before declaring a linked span absent.

Proposer allocation `5f2fbf2e-2c6f-34df-0810-0377419e2da2`, block hash
`5fc92f32ed4be5635a2a05ce418a3b982484c9759f405e7ba1dd81ee3a51532b`:

| Event, proposer clock | ms from first queued item |
|---|---:|
| Proposal recorded | 44.271 |
| Parent verdict valid | 46.922 |
| Own support durably signed | 55.295 |
| Notarization threshold reached | 344.075 |
| Finality received | 349.797 |
| Last batched append reply | 365.308 |

The long interval is **288.780 ms after the proposer durably supported**.
Its parent computation took 2.216 ms; there was no parent park/abstention,
watchdog or proposal redrive. Across the 125 fully covered source proposals
(100 c1, 25 c4), proposal-to-valid is at most 2.650 ms; this post-support wait
is the largest, with the next-largest 31.958 ms.

This excludes the proposer's own pre-support validation as the explanation
for *this interval*. It does **not** prove the process was idle: remote
validator delay, transport delivery and the proposer's own scheduling/mailbox
delay remain indistinguishable. Raw share-arrival events do not identify
distinct authenticated signers. No quorum inference is made by counting them.

### Result delivery: a 112.582 ms source-owner wait

Request 44, trace `204e2d4a87fe4e089d802b28cde78d98`, waited 112.582 ms
between result send and source-owner acceptance. On the same allocation,
prior request 42's receipt proposal at slot 793 overlaps the wait, including
a 9.972 ms support journal sync at its end. The earlier part is still
unattributed to a particular function. `batch.wait_ms=116` and an incomplete
set of exported batch-queue events prohibit an exact batch-construction
subtraction; no timer or CPU cause is inferred from that overlap.

### The original outlier remains unproven

No 1,625 ms serial request recurred. The physical ledger scan, keyed by
`{height, tx_id}` rather than transaction ID alone, finds **59 repeated new
receipts but zero mixed claim/receipt blocks**. Block 786 has four claims and
no receipt. Ordinary requests did overlap autonomous recovery, but the old
mixed duplicate-receipt precondition was not reproduced. No
`foreign_validation` spans occur in these captured claim proposals; do not
claim that candidate was exercised on hardware.

Analysis correction: an initial independent scan reused the receipt-binding
audit's transaction-ID deduplication and incorrectly reported zero repeated
receipts. That statement was also made in an intermediate user update and
then corrected. The physical-occurrence audit supersedes it; raw pages and
the superseded analysis are retained. Unique durable-result bindings were
unaffected. The corrected scan still finds zero mixed blocks; its positive
control identifies the old source slot 289 as a receipt repeated from 288
alongside a new claim. This distinguishes a real negative result from an
analyzer that cannot recognize the original condition.

## Next boundaries, not implementation approval

1. Keep the old outlier open. A future capture needs its actual mixed-block
   condition; do not manufacture duplicate writes or declare a fix from absence.
2. The slow covered block motivates distinguishing proposer scheduling from
   remote support delay. The existing capture has reached that boundary; it
   has not proven a peer/network cause or an idle proposer. Any transient
   proposal-context extension still needs its focused authenticated-surface
   contract and consensus-area review first.
3. Result delivery is located at the shared owner. Profile/trace its actual
   occupied turns before changing that owner or a timeout. The pre-decode
   interval includes `quod_dtx_endpoint:correlates/2`; source inspection proves
   repeated evidence decoding through `valid_pair` and
   `application_response_matches`, but not its exclusive elapsed cost.
   Any removal must preserve the existing request/result authentication at
   one seam. No duplicate-receipt verification bypass is authorized.
4. No finality, Q4, L2, compaction or result-authentication contract change
   follows from these measurements. No production changes during capture.

## Evidence and reproducibility

Primary archive directory: `/tmp/quod-consensus-156-YfnvgZ/`.
`benchmark/README.md` records the reused harness and exact commands.
Relevant raw-bound artifacts:

- `benchmark/matrix-summary.json` and every run's `results.tsv`,
  `stdout.txt`, `stderr.txt`, `run.json` and `after.json`;
- both one-hop `traces/`, `trace-manifest-all.json`, `attribution-all.json`;
- `benchmark/aggregate-stages.json`, `worker-attribution.json`,
  `diagnostic-timeline.json`, `independent-slot-diagnosis.json` and its
  read-only reproducer `verify-slot-diagnosis.mjs`;
- `benchmark/receipt-audit.json`, retained raw receipt pages,
  `benchmark/independent-audit/REPORT.json` and `receipt-occurrences.json`
  in that audit directory (unique-result counts versus physical occurrences);
- `benchmark/health/`, `retention-check.json`, deployment/image logs.

Fine result analysis and 0.7.155 re-analysis:
`/tmp/quod-result-analysis-156-B7HZWN/REPORT.md`, `analyze.mjs`,
`results156-r2.json` and `baseline155-r2.json` (hashes in the report).
The prior evidence remains `/tmp/quod-phase1b-155-p5yRUw/` and
`/tmp/quod-a1a4-152/`; no old trace or failed attempt was overwritten.
Offline harness/analysis guards passed 5/0 + 12/0; diagnostic analyzer 3/0.
Independent raw TSV/receipt and slot/result analyses corroborate the numbers.
Credentials remain outside evidence directories and are not archived.
Yan's write-lanes document/SVG fingerprint remains
`f0de37bfd4b4cf504502c51f502e756a4c110150628b86a7046979fe603fec04`.
