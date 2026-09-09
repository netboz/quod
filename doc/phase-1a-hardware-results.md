# Phase 1A hardware results — 0.7.152

Measured 2026-09-09, after the completed A1–A4 review. Behavioral commit
`45678f5`; separate version commit `d51503a`. Both are pushed to `claude/next`.
No Phase 1B, Q4, finality, result-authentication, L2 or compaction change was made.

**Result:** all 400 measured writes committed; no failed, pending or uncertain
write was excluded. Live evidence scans are gone in all 200 one-hop traces.
The within-run linear latency growth seen on 0.7.151 is no longer visible in
this sample. The absolute latency gate is **not met**: serial one-hop p50 is
544 ms, above 300 ms. Behavior at 10,000 entries is **not measured** here.
This is development evidence, not closure of the separate release-safety gates.

## 1. Deployment and fixture

- Image: `192.168.1.11:5000/quod:0.7.152`; registry digest
  `sha256:53791a6dc06e455fb9763d88a0d78552a443b52ffeed928c9abfb990f3e2023b`.
- The catch-up wire cut was deployed with all old allocations stopped first.
  Ledgers, root anchor, node identities and the previous fixture were retained;
  no purge or re-found was performed.
- The job has eight home allocations and two cloud allocations. The benchmark
  uses only the eight home nodes, on three physical machines. Source committee
  `[0,1,3,7]` and target committee `[2,4,5,6]` are N=4 with disjoint node keys,
  but share those physical machines. The gateway does not host the target.
- Fresh namespaces `quod:trace152-source` and `quod:trace152-target` were created
  by the ordinary root action; hosting facts, observer synchronization and
  ordinary readiness-gated admission established the committees. No route
  injection, hand-listed namespace or protocol shortcut was used.
- The same browser signing implementation, agent-instance shape, encrypted
  development key, assertion goal, one gateway and run order as the 0.7.151
  control were used. Every textual goal/instance carries its terminating dot.
  The first three source preflight heights match exactly: 8, 108 and 133.
- Resources and job settings initially differed only in the image. This is a
  matched fixture shape, not identical background state: 0.7.152 also retains
  the old fixture. Trace export was corrected to the current Tempo receiver
  `.10:4318` before measurement, with the same 5% background sampler and
  explicitly sampled measured requests. A subsequent same-version coordinated
  restart persists that endpoint correction; measured allocation manifests
  are kept separate from the replacement deployment.

All benchmark requests were sent once. Two earlier smoke writes also committed
(local 68 ms, one-hop 244 ms), separately from the 400-request statistics.

## 2. Latency — all requests, milliseconds

Nearest-rank percentiles. Each row is 100 requests. Successful-only statistics
equal the all-request statistics because there were no failures.

| Path | Concurrency | 0.7.151 mean / p50 / p99 | 0.7.152 mean / p50 / p99 |
|---|---:|---:|---:|
| Local | 1 | 55.75 / 56 / 61 | 55.79 / 55 / 80 |
| Local | 4 | 81.76 / 78 / 168 | 78.59 / 78 / 89 |
| One-hop | 1 | 1152.32 / 1156 / 2052 | 544.16 / 544 / 665 |
| One-hop | 4 | 3704.56 / 3723 / 4834 | 1558.56 / 1609 / 1797 |

One-hop mean decreased 52.78% at c1 and 57.93% at c4. Local median performance
is effectively unchanged; the serial local p99 rose from 61 to 80 ms in this
single pair of runs, so no claim about improved local tail latency is made.

### Within-run growth

Requests are sorted by start time and numeric sequence, not completion order.

| Path | 0.7.151 first / last 25 mean | 0.7.152 first / last 25 mean |
|---|---:|---:|
| One-hop c1 | 715.48 / 1595.64 | 523.32 / 548.40 |
| One-hop c4 | 3029.92 / 4334.28 | 1407.64 / 1592.92 |

Across all 100 serial requests, the latency-vs-request-position regression is
11.595 ms/request, R²=0.8910 before, versus 0.253 ms/request, R²=0.0187 after.
Excluding the first 25, the new slope is -0.156 ms/request, R²=0.00493. These
are like-for-like raw-request regressions, not the old four-trace regression.

During the new one-hop c1 run source height grows 133→337 and target 5→105;
c4 then grows them 337→422 and 105→131. The observed disappearance of the
strong linear slope does not establish flat behavior through 10,000 entries.

## 3. Complete per-request trace attribution

All 100 traces from **each** one-hop run were fetched sequentially after the
workload. Direct children of the source proof do not overlap; their interval
union was checked rather than assuming that nested spans can be added.
The table contains means of those per-request non-overlapping segments.

| Segment, ms | c1 | c4 |
|---|---:|---:|
| Client time outside server request span | 5.779 | 6.897 |
| Server time outside source proof | 10.640 | 11.320 |
| Invocation | 289.904 | 1057.354 |
| Source claim | 70.346 | 109.886 |
| Operation result | 163.294 | 364.642 |
| Other named direct proof children | 2.886 | 6.932 |
| Unattributed proof residual | 1.312 | 1.529 |
| **Client total** | **544.160** | **1558.560** |

Using unrounded measurements (shown rounded here): c1 server mean 538.381 − named server segments 537.069 =
1.312 ms residual, **0.244%**; c4 1551.663 − 1550.134 = 1.529 ms residual,
**0.099%**. The ≥95%-of-means attribution gate is met on all 200 traces, at
**99.756% / 99.901%**. Client-outside-server time is measured separately and
is not silently called consensus or proof work.

Nested diagnostic spans below explain their containing stages; **do not add
them to the table above**:

- `foreign.current`: 281.837 ms/request at c1; 1045.506 ms at c4. There is one
  such span per measured request. This remains the largest measured owner.
  Shared foreign verification work produces 99 worker spans at c1 and 24 at
  c4; counts across linked/shared workers are not one worker per request.
- Exactly 200 `evidence.ledger_open` spans in each run (two per write): mean
  **0.131 / 0.120 ms per open**, with **zero `ledger.index_scan` spans**.
  Successful claim evidence and target application spans provide the positive
  control: these are real remote writes, not absent/untraced work.
- Evidence `read_at`: 6.954 / 43.615 ms per request, including both reads.
  The higher c4 cost is reported, not attributed to a new hypothesis here.
- Phase-index suspend is 0.111 / 0.026 ms per request in the linked traces;
  it does not explain the remaining hundreds of milliseconds. Resume remains
  separately named. No H2/backend decision is inferred from these figures.

The evidence-open refactor has its measured effect. It does not implement or
authorize the separate `foreign.current` optimization; that design still
requires its own review. Neither a 120 ms promise nor the c4 absolute gate is
claimed from removing only the scans.

## 4. Health and disclosed incidents

During the four runs, all eight home nodes had zero Nomad restarts, healthy
runtime gauges, no warning/error/supervisor/export-failure log records, and
zero discarded Tempo spans. Afterward source/target were synchronized at
422/131. Existing consensus, DTX, endpoint and proof-worker queue gauges were
zero. These gauges are not substituted for a nonexistent unresolved-operation
row gauge; durable receipt verification is recorded in the artifact handoff.

After the tracing-configuration restart, the existing Explorer history APIs
verified **201/201** one-hop operations (smoke plus 200 measured writes): each
has the matching source claim, target application and source `remote_complete`,
including operation-ID, request-digest and target-transaction bindings.
There are zero DTX control rows in either fixture. Source 422 and target 131
were recovered unchanged. No write was resubmitted to obtain these receipts.
`receipt-audit.json` and the raw paginated histories retain that check.
All eight home nodes recovered; the corrected OTLP address is present in both
Nomad templates and runtime environments, and traces from replacement
allocations prove export survives restart.

The following happened **outside** the measured write matrix and remain visible:

1. An initial retained-fixture signed-read preflight returned
   `proof_unavailable`. Trace export was unavailable then; aggregate counters
   cannot identify the exact refusal. A later read succeeded unchanged in
   11.176 ms through an actual remote host. This proves current functionality,
   not that the original cold-path failure was diagnosed or fixed. No execute
   request was sent by that failed preflight.
2. One fresh membership admission returned definite `{error,retry}`. The
   ledger proves no candidate admission committed (a membership-rejection
   skip did). After readiness on every current validator was observed, a new,
   separately journaled ordinary admission succeeded. The original action and
   stop record are retained; this was not resubmission of an uncertain write.
3. Four hosting-time runtime worker-cancellation warnings converged before
   the benchmark; they are not omitted by the clean measured-window claim.
4. Both cloud allocations already retained an incompatible old root before
   deployment and host no ontologies. Old allocation logs prove this predates
   0.7.152. Their ledgers were not purged, and the report does not claim ten
   healthy nodes. They do not participate in the N=4 benchmark.

No result-authentication release-safety claim follows from successful request
responses. That contract, Q4's quiet-source limitation, finality, L2 and
compaction retain their explicit independent gates.

## 5. Reproduction and evidence

- Baseline: `/tmp/quod-trace-151-clean/HANDOFF.md` and its four raw TSVs.
- This run: `/tmp/quod-a1a4-152/`; `matrix-summary.json`, each run's
  `results.tsv`, `all-result-stats.json`, `stdout.txt`, `stderr.txt`, metrics
  snapshots, `run.json`, `preflight.tsv` and before/after state snapshots.
- Original measured topology: `discovery.json`, `state-initial.json`;
  replacement deployment topology is deliberately a separate file.
- Full one-hop traces: `onehop-{c1,c4}-n100/traces/`, matching
  `trace-manifest-all.json`, and `attribution-all.json`. The sequential capture
  and interval-union analysis scripts are beside the fixture harness.
- Representative serial traces: request 1 `9003f29b9bb44254b4d65ad3d005b550`,
  request 25 `745ca7b4aef548b69aafc0ef6080711b`, request 50
  `6d3c476b84234684bff9db7a4ad4fd52`, request 75
  `3d54ec45ef1740f0b443f4f8366df427`, request 100
  `ef2bf8b7966a4cdb9ea777bc2cd3d083`.
- Health: `/tmp/quod-a1a4-152-health/MATRIX-HEALTH.md` and `matrix-complete/`.
  Deployment job/allocation manifests and image build/push logs are retained
  under `/tmp/quod-a1a4-152-*`.

The reviewed source gates remain EUnit 1799/0, ask CT 26/26, QUIC CT 26/26,
xref/dialyzer/diff-check clean on the fingerprint-matched cut. No production
implementation was added during deployment or measurement. The only worktree
changes excluded from this work remain Yan's write-lanes document/SVG edits.
