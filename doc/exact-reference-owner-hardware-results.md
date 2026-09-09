# Exact-reference owner cut: deployment and cold-read capture — 0.7.158

Status: **development evidence independently reviewed and accepted;
diagnostic classifier implementation review closed (2026-09-10)**. The reviewed
owner cut is committed as `f415644`, with separate 0.7.158 bump `5e3ab21`;
both are pushed to `origin/claude/next`. All ten allocations were redeployed
with preserved ledgers. The first sampled read exceeded the existing client
deadline; the benchmark stopped before any write. No warm-write, multi-writer,
slot-1059 recovery or performance-gate closure is claimed.

## 1. Deployment and retention

Image `192.168.1.11:5000/quod:0.7.158`, registry digest
`sha256:7d0621e495b40ccf5c6e476e04eec1c5d86d8179fd902d5921053311d575c31a`.
The live Nomad job was cloned; exactly three image references changed. An
inverse comparison pinned every other field unchanged, including volumes,
anchors, templates, root sampling and owner tracing. The live Tempo override
was not changed. All ten old allocations became terminal at 22:21:34.957 UTC
on 2026-09-09 before replacements were started. No ledger was purged.

Archive: `/tmp/quod-owner-158-deploy-PYgaE7/`. Raw live job snapshots there are
private deployment material, not review attachments: they contain templates.
Review the image-only plan, build/push logs and sanitized retention reports.

The first post-deploy snapshot (22:22:38–46 UTC) failed readiness: three source
replicas were not yet listed, another exposed a height-zero placeholder, older
source histories were still replaying, and actor runtimes were not all healthy.
This artifact remains at `health-after/manifest.json`; it was not overwritten
or described as ledger loss. Genuine Consul health changes subsequently showed
all eight home nodes ready at 22:26:17.165 UTC. A separately labeled snapshot
at 22:26:34–39 UTC and `retention-check-health-recovered.json` prove:

- ten 0.7.158 tasks, zero task restarts;
- all 40 retained namespace rows match their pre-deploy anchors, committed /
  applied / approved heights, committee IDs and membership exactly;
- unchanged node identities; all home runtimes healthy/applied/idle;
- source `quod:trace155-source` at 1138, target `quod:trace155-target` at 389;
- source committee home 0/1/3/7 and target 2/4/5/6 remain disjoint N=4;
- the two cloud satellites retain their pre-existing empty-namespace exclusion.

No intervention drove that recovery. Nomad running alone was insufficient
readiness; the failed first snapshot remains part of the deployment result.

## 2. One cold read, not a write benchmark

Capture: `/tmp/quod-owner-158-capture-ZxTRrO/`.
The only signed proof submitted was:

```prolog
'quod:trace155-target' :: (true).
```

It used the existing browser client and agent, mode `read`, one attempt,
sampled trace `73b687d4ca647f9f735be54385b72e26`. Authentication succeeded
in 47.955 ms. The proof HTTP call received no reply before the unchanged
35-second total network safeguard; total observed time was **35006.143 ms**
(proof wait **34958.153 ms**), 22:28:12.123–22:28:47.129 UTC.

The browser's transport error says the outcome is unknown. This was a **read**,
not an uncertain write: zero execute submissions, zero benchmark seeds and
zero measured writes. `cold-read1.json`, stdout and `BENCH_STOP` retain the
failure. Neither the proof nor any signed execute was retried; no deadline,
sampler, owner configuration or protocol parameter was adjusted.

## 3. The previously uncovered cold time is now located

The one full trace GET succeeded, retaining 202 spans (112995 bytes; SHA256
`ebe959ff4f011c6a9e753bd37ce801202aa97bf607f3cbe88ddea4e2bab7381e`).
The two observed current-view workers both completed with `ok`, installed
their verified results and reported owner replies. They are **current-view**
jobs, not exact-reference jobs: this probe does not exercise slot-1059's path.

All durations below are each worker's local elapsed spans, in milliseconds.
Nested rows are not added together; these are two individual observations,
not percentiles or a population estimate.

| Stage | Target history verified on source home 0 | Source history verified on target-side validator |
|---|---:|---:|
| Entire worker | 9896.350 | 26355.317 |
| Cache open, including reconstruction | 9889.557 | 26348.408 |
| Ledger open | 1732.941 | 4440.874 |
| Of ledger open: index-scan decode | 1724.964 | 4421.958 |
| Replay of cached certified history | 8155.532 | 21906.723 |
| Checkpoint comparison | 0.031 | 0.030 |
| Initial probe collection | 3.885 | 3.517 |
| Current-tip confirmation | 1.946 | 2.251 |
| Phase suspend | 0.195 | 0.329 |
| Starting resident height | 0 | 0 |
| Disk entries replayed / final height | 389 / 389 | 1138 / 1138 |
| Newly verified network/local/hint entries | 0 / 0 / 0 | 0 / 0 / 0 |

Both workers cold-opened once, with zero resume failures. This is reconstruction
of retained disk history, not transfer of a new history suffix or waiting for
a missing quorum. Zero new entries does not mean zero network traffic: tip
probes still occurred. Parentage and the source call sequence identify the
target-history check before remote scope authentication checks the source's
history. Do not subtract timestamps across allocations to invent precise gaps.

The workers together contain **36251.667 ms** of work: **30062.254 ms replay**
and **6173.815 ms ledger-open**, excluding their enclosing wrappers. The new
instrument locates the cold cost at these existing owners. It does not yet
decompose replay into exclusive per-function CPU, signature, decoding and
storage work; no particular lower-level algorithm is identified as the fix.
`phase_suspend` is not the large term in this sample.

Replay averaged 20.965 / 19.250 ms per retained entry in these two histories.
Together with the full-prefix cold-replay path, this supports retained-history
growth as the cold-start problem; two observations do not establish a general
latency law across different history shapes. A verified projection checkpoint
is a future architecture question, not implemented or authorized by this result.

Owner queue stages were only 0.010 / 0.012 ms; API-to-residence admission
was 1.311 / 0.970 ms. This sample does not attribute the seconds to owner
queueing. The index scans are at the permitted cold foreign-cache recovery
owner, not evidence that warm per-request hosted-ledger scans have returned.

Observed local stage unions cover 99.9950% and 99.9979% of their respective
workers (weighted 99.9971%; residuals 0.490 / 0.558 ms). This is a **worker-local
observed-time partition**, not a complete client-level attribution gate.
The following coverage defects prevent a whole-request completeness claim.

## 4. Measurement gaps and a diagnostic classification defect

- The enclosing client/proof/remote-ask/endpoint roots are absent from the
  retained trace. Successful worker/current-owner replies do not prove that
  the full read completed or delivered a result after client disconnection.
- Fifteen of sixteen probe-worker spans exported; one page-fetch parent is
  absent while all sixteen page admissions and sixteen unique completed
  terminals are retained. Cancellation is consistent with the missing child,
  not proof of its exact scheduler history. The expected-count auditor fails
  rather than pretending the missing parent did no work.
- **Twenty normal helper returns are mislabeled failed/unclassified.** Sixteen
  page-wait returns are normal `decode_page` turns; two initial probe
  collections return lists and two ledger suspensions return maps. The shared
  `foreign_stage_result/1` and reason table omit those normal shapes. This is
  diagnostic metadata, not twenty failed operations. Correct it at that shared
  observation seam with stage-appropriate regressions, not by changing the
  verifier result grammar or suppressing the auditor.
- No exact-reference job, new mixed claim/receipt block, warm-write comparison,
  10k test or source-owner ON/OFF comparison was obtained.

Tempo was ready before/after the sequential read-only retrieval, with no trace
GET failure. Collection health is not evidence that every application span
exported; both missing parents and unclassified labels remain explicit.
The source's later numeric stats had zero pending/queued/pull work; this rules
out still-parked work there at that observation, not every possible remote wait.

The complete stage table, source references and coverage inventory are in
`/tmp/quod-owner-158-capture-ZxTRrO/COLD-READ1-HANDOFF.md`, with exact values
in `cold-read1-summary.json` alongside it. These are offline analyses of the
same single trace retrieval, not additional proof attempts.

## 5. Next gate, without quietly resuming a failed benchmark

Claude accepted deployment/retention and the cold-read evidence on 2026-09-10.
The diagnostic classifier micro-cut's implementation review is closed and
approved for commit; it changes observation only, not this hardware outcome.
Keep `BENCH_STOP` and the original failed proof intact. Do not tune a timer,
retry the proof until warm, or claim that this sample fixes the old outlier.
The later warm workload baseline must be explicitly distinguished from this
failed cold-start gate; no warming workaround is part of the implementation.

The source-audited multi-writer harness is prepared, offline only, at
`/tmp/quod-multiwriter-baseline-KIhwM2/HANDOFF.md` (seven pure tests pass):
conserved A→B transfer and T=2 independent facts on **current atomic L3**,
using the existing committees. T includes source A; no `independent/1`, L2 or
flat-target-count property is implemented or claimed. It retains exact signed
requests, all failures, Complete-derived outcomes and per-target balance /
multiplicity oracles, and honors the capture stop. No pilot was run.

The benchmark-first direction remains: measure current multi-writer cost with
real state oracles before refreshing L2 slices 6–8 or attributing an L3 barrier.
There is no single-active-group queue to delete. Dated product-direction
amendments remain subsequent work. Result authentication, Q4, duplicate receipt
verification, finality, compaction and the existing absolute latency gates
remain open independently of this owner cut's source-review approval.

## 6. Diagnostic-only follow-up

The micro-cut normalizes only the observation at the existing shared stage
boundary: `page_wait`'s six-element `decode_page` reply, `probe_collection`'s
result list and `ledger_suspend`'s metadata containing `cache_session` but no
live `cache_store`. Other stages do not accept those shapes. The opaque session
is not decoded or authenticated again. Both metric and SDK classification use
this same adapter and the existing closed result/reason vocabulary; the helper
returns, exceptions, verifier, custody, deadlines and expected-count auditor
are unchanged. A list containing refused probes is successful collection,
not proof of a quorum; threshold `false` stays rejected.

Seven new SDK tests cover these normal/malformed/wrong-stage cases, unchanged
failure vocabulary, real all/threshold collectors and exact trace correlation.
Three existing live page/cache tests now assert successful stage classification.
On the old production logic with only a TEST export added, the final focused
tests fail eight cases at `expected status=ok, actual status=error`; after the
fix all 18 pass. Raw logs and the pre-fix source are in
`/tmp/quod-foreign-classifier-hTwqZ0/`. At that local-gate checkpoint no commit,
version bump, deployment or new proof had occurred for this micro-cut.

The first clean EUnit run (`/tmp/quod-foreign-classifier-gates-ib7tI0/`)
reported 1939 passed / four failed, all in the new name-only span selectors.
The SDK exporter sees application-wide background work; those fixtures now
use a unique parent and exact trace-ID selection, with a deterministic
unrelated-first same-name regression. Production stayed byte-identical. The
final fail-before control (`fail-before-final-r3.log`) loads the archived old
owner against the final test beam in a separate VM. Earlier harness attempts
lacked its test-beam path and application assets; both are retained as setup
failures, not classifier evidence. The successful control reaches all eighteen
tests and its eight failures are precisely the expected status mismatches.

Final gates, from a fresh `_build/test` after archiving the previous build,
unsandboxed and sequential with `ERL_FLAGS='+S 4:4'`:

| Gate | Result | Exit |
|---|---|---:|
| EUnit (`-v`) | 1944/0 | 0 |
| `quod_ask_SUITE` | 26/26 | 0 |
| `quod_quic_SUITE` | 26/26 | 0 |
| `quod_simplex_SUITE` | 12/12 | 0 |
| xref | clean | 0 |
| Dialyzer | clean | 0 |
| Production release | built locally | 0 |
| `git diff --check` | clean | 0 |

Archive `/tmp/quod-foreign-classifier-final-J4q5tC/` contains `run.sh`, all logs
and `exits.tsv` (2026-09-09 23:01:54–23:07:58 UTC). Production SHA256 stayed
`f14464f6fffa6ede8048ac472495efebce5e66ba4c350d3bb16bb2d8dd921207`;
final test SHA256 is
`9604d7275ab91090e88c4627b94045979853e25065937b6175a19722e71559f6`.
Only documentation/result recording changed after the sequence, followed by
another diff-check. Claude subsequently reproduced EUnit 1944/0, Ask/QUIC
26/26, Simplex 12/12, xref, Dialyzer and diff-check, verified the source/test
fingerprints and fail-before control, and closed implementation review as
SAFE TO COMMIT. The release build above remains a locally reported gate.
This diagnostic-only approval is not new hardware evidence or authorization
to resume the stopped cold campaign; the warm-labeled baseline retains its
separate fresh-go boundary.
