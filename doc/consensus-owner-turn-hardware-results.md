# Owner-turn diagnostic capture — 0.7.157

Status: **independently reviewed; evidence approved, no performance closure**.
Claude recomputed the raw off measurements and cold/warm diagnostic and
confirmed the failed on capture's limitations. Tracing-off measurement
completed; tracing-on benchmark stopped at read-only preflight.
Quod and the diagnostic backend are restored. No performance gate closed.
The reviewed instrumentation was committed as `18948ed`, with separate version
bump `5c374c5`. Both commits were pushed. The image is
`192.168.1.11:5000/quod:0.7.157`, registry digest
`sha256:78f04612e6d9b34f991ad129bb7d6e70ad60f4519da0efe9650edd941df6ae42`.
No consensus behavior, timeout, quorum, reference validation, or result policy
was changed. The [diagnostic contract](consensus-owner-turn-tracing.md) still
governs interpretation.

## Preserved fixture and controls

The same `quod:trace155-source` and `quod:trace155-target` N=4 fixture is used.
Source hosts are home 0/1/3/7; target hosts are 2/4/5/6, with disjoint validator
keys but some shared physical machines. This is a retained-history diagnostic,
not a fresh matched-height performance experiment. All ten old allocations
were stopped before each coordinated replacement. No ledger was purged, route
injected, ontology re-founded, or uncertain operation resubmitted.

The first restart changed only the three image references. All 40 home
namespace rows retained exact anchors, heights, committees and node identities.
The tracing-off runs began at source 841 / target 259 and ended at
1138 / 389. All 200 new remote operations have exact anchored claim,
application and receipt bindings; all eight fixture replicas were then applied,
idle and drained. The two cloud allocations retain their pre-existing root
anchor mismatch and remain excluded from measured traffic.

Dynamic source/target owners have `detailed_consensus_metrics=false`, despite
the root content template having it enabled. That setting was not changed.
The tracing-on restart changes only the node-local owner-tracing flag and
root sampler from 0.05 to 1.0; this also changes sampling of other independent
roots, so an off/on latency difference is not isolated wrapper overhead.
Again all 40 rows were retained exactly. Sampling and dynamic-owner flags are
checked at the actual owners, not inferred from a root config template.

## Instrument-off results — all requests, milliseconds

| One-hop run | Committed / attempted | Mean | p50 | p99 | Maximum |
|---|---:|---:|---:|---:|---:|
| c1 | 100/100 | 382.97 | 378 | 476 | 522 |
| c4 | 100/100 | 1222.99 | 893 | 9632 | 9684 |

No failed request, outlier or uncertain result is excluded. No measured execute
request was retried. All 200 request traces and raw driver stdout/stderr are archived.
The c4 run has exactly four requests above 2,000 ms; every other request is
at most 1,109 ms. The four remain in every statistic. The previous 0.7.156
c1/c4 means were 373.21 / 843.89 ms; this tracing-off retained-height comparison
does not establish a causal regression from the default-disabled diagnostic.
The serial p50≤300 ms and c4 p99≤450 ms gates both still fail.

The same result analyzer used for 0.7.156 retains all 200 requests with exactly
paired endpoints and no clipped intervals. These are means of per-request
partitions, not subtraction of marginal quantiles:

| Operation-result partition, mean ms | c1 | c4 |
|---|---:|---:|
| Before claim evidence | 0.389 | 0.884 |
| Claim evidence | 3.106 | 14.585 |
| Evidence to target call | 1.828 | 2.925 |
| Target-application call | 173.671 | 362.907 |
| Post-target tail | 16.685 | 46.958 |
| **Total** | **195.679** | **428.259** |

The tail comprises pre-decode 11.506/15.165 ms, decode 3.535/4.682,
decode-to-send 0.050/0.061, source-owner delivery 1.530/26.909,
acceptance-to-reply-ready 0.012/0.012, and caller return 0.052/0.128.
Unrounded per-request sums agree to floating-point precision. Operation-result
means are another **2.27% / 5.66% higher** than 0.7.156; that remains visible
separately from the earlier +18.4% serial regression.

The paired target endpoint averages 115.369/210.659 ms. Its duration subtracted
from the same request's enclosing source call leaves **58.302/152.248 ms**,
up from 54.606/137.462 on 0.7.156. This is still unlocated time, not established
network latency. The c4 source-owner delivery mean rose 22.817→26.909 ms.
Raw per-request partitions and hashes are in
`/tmp/quod-result-analysis-157off.json`; the method and full tables are in
`/tmp/quod-result-analysis-157off.md`.

## New mixed-block tail: verification before the source claim commits

Measured c4 window: 2026-09-09 18:02:28.332–18:02:59.117 UTC.

| Request suffix | Driver ms | Source-claim ms | Operation-result ms | Trace ID |
|---|---:|---:|---:|---|
| 14 | 9684 | 8737.837 | 482.142 | `d5bff89896994d2ea8a03e9a7d1c9075` |
| 15 | 9632 | 8741.277 | 504.043 | `a72b2e42cdf64b629009bbd20c6f2ae3` |
| 16 | 9602 | 8737.917 | 503.957 | `f62ebd6f7d98499dbe54efeebdceeeb7` |
| 17 | 9175 | 8502.226 | 458.085 | `20688e5d39454f8c8423deb4f0f25f37` |

Full request prefix: `q1788976948331_2925193_`.
Source proposer home1, allocation `e25648ed-8172-b0b6-e8aa-fa2199151375`,
slot **1059**, block
`ee22e2df73617a9d7ffb5489cdb2afa44bbd3a92d96483a6918ab6ece3e8fb2e`:

- The physical ledger block contains **three remote claims and one remote
  completion receipt**. This genuinely reproduces the mixed-block shape;
  it does not prove the same cause as the old 1,625 ms outlier.
  A separate physical-occurrence audit finds this receipt only at slot 1059,
  unlike the repeated receipt at old slots 288/289. The older duplicate is
  the audit's positive control. A duplicate-only optimization therefore cannot
  be presumed to address this new case.
- Queue-to-append is 8,709.296 ms. Three watchdog/redrive events for this slot
  remain in the request traces. The parent append span reports 64 dropped
  events (32 retained), so those are observed events, not an exhaustive count.
- First foreign-validation worker: **6,001.673 ms**, ending in `abstain`.
  A **963.428 ms** gap follows, then another worker runs **1,684.596 ms** and
  returns `valid`. These are worker wall durations, not CPU measurements.
- Those worker spans have no immediate child spans in the fetched request
  traces. The exact-reference path lacks the current-view path's trace-context
  propagation, so the internal fetch/queue/verification split is not established.
  The existing 6,000 ms caller budget is consistent with the first duration;
  the actual error mapped to `abstain` was not emitted, so a specific timeout
  producer is not proven from the trace alone.

Source inspection explains a possible duration mechanism, not its observed
trigger: `quod_simplex:verify_remote_dtx_reference_routes/6` gives each
`quod_foreign_log:verify_reference/5` caller 6,000 ms. That owner's caller
timer expires independently of shared work, while the public call's outer
bound is 7,000 ms. Queued callers also consume their budget. Active exact
verification can survive caller expiry; its sequential page work has an
8,000 ms default per-page budget, and exact routing does not use the supplied
whole-work timeout. A later identical caller can join the surviving work.
Exact references do not require a current-view confirmation round. When
Simplex receives `abstain`, it clears validation without rejecting the block;
a later proposal redrive can enter validation again. The specific queue,
route, page, caller-expiry and wake ordering needs correlated owner evidence
before changing any of those lifetimes. No timeout adjustment or duplicate
receipt bypass is part of this diagnostic.

There were zero home allocation restarts and zero warning/error findings in
the measured context window, independently checked in Nomad logs and Loki.
Whole-run source watchdog counters increased by eight on each source member;
home1 redrives increased by eight. These counters cover the entire run and
must not be substituted for the slot-bound events above. Absence of logs does
not prove the absence of scheduler, queue or transport delay.

All 200 primary request traces were retrieved. Twenty-nine additional linked
trace lookups returned one trace and 28 HTTP 404 responses, preserved in the
manifest. Primary trace completeness is not complete linked-trace closure.

## Tracing-on capture and interpretation

The short c1 attempt **failed its signed remote read-only preflight** with
`proof_unavailable`. No measured execute request was submitted, no results TSV
was produced, and c4 was not started. Driver output, exit status and the
`BENCH_STOP` sentinel are retained; the failed attempt is not silently retried.
The existing driver's read-only preflight retry loop is distinct from measured
write scheduling, which was never reached. This is not a tracing-on latency
sample or a successful paired control. The diagnostic configuration was then
restored to off with the original 0.05 root sampler, same image and preserved
ledgers. All 40 namespace rows again match exactly. Runtime owner flags and
the actual installed SDK sampler (not just its static application default)
confirm tracing off and parent-based 0.05 root sampling on all eight home
nodes. Quod job version 19 has all ten tasks running 0.7.157 with zero task
restarts; the two cloud exclusions are unchanged.

Tempo was OOM-killed (exit 137) at **18:18:23.306 UTC** and restarted at
**18:18:39.583**. Its received-span counter reset. This happened **after** the
preflight failed and is not established as that failure's cause. It invalidates
an uninterrupted loss-free export claim. Quod itself had zero measured task
restarts: all eight home nodes remained applied/idle at unchanged source
1138 / target 389. Captured application RSS was 131–174 MiB against 1,024 MiB
limits; instantaneous CPU readings are not an attribution of the earlier wait.
Failure-window Loki contained only informational entries, with no typed
`proof_unavailable` cause. Absence of that log is not a diagnosis.

A corrected, limit-bounded search recovered **all 3,763 expected owner-root
IDs**, with exact sequence coverage on the four captured incarnations
(946/938/939/940 roots). That is not full trace retrieval: the first full GET
returned one 13-span trace, then ten transport failures stopped the downloader,
leaving 3,752 IDs unattempted. Failed searches/downloads are retained. Tempo
subsequently was OOM-killed again at 18:23:37.359, restarted at 18:23:53.258,
and died after a further OOM at 18:24:28.132.
No owner occupancy table or exclusive function attribution can be claimed from
one full trace. Root-ID coverage is not silently reported as child coverage.

The boundaries report `multi_time_warp` with equal sampled offsets, not
`no_time_warp`. That does not demonstrate a clock jump. The strict scratch
analyzer nevertheless declines whole-window clock calibration in this mode;
its refused output is retained, not used as a timing conclusion. Driver exit
status is 2; the enclosing stop-on-failure wrapper exits 1.

### Backend recovery, separate from Quod performance

All **294 original Tempo files / 313,165,344 bytes** were copied out through
Nomad's read-only file API, each size-checked and SHA256-verified, before the
recovery change. The backup includes 249 block files and 45 WAL files. No
ledger or trace file was deleted. The live Tempo job used allocation-local
nonsticky/nonmigrating storage; its automatically rescheduled replacement
must not be assumed to contain the old trace data. The archive remains at
`/tmp/quod-owner-157-tempo-preserve-aN4ckW/`, manifest SHA256
`a643db41fc0b9d599e35528a4bb0456cd0b13d2e142d53a3ca2038652b62094f`.
The supported backup API is documented in
[Nomad's client API](https://developer.hashicorp.com/nomad/api-docs/client#read-file).

After that backup, the **existing** Tempo job was restored at its original
`.10:3200/4318` addresses, same image `grafana/tempo:2.6.1`, CPU and storage
configuration, with memory reservation/limit 768→2,048 MiB and placement
pinned to the original endpoint node. That host had 13.60 GB available RAM
at the preflight observation. `/ready` and `/metrics` returned 200 at 18:37 UTC;
new allocation `8a893721-fba4-e942-6cde-6afecfd65d1c` had zero restarts.
This is diagnostic-service recovery, not a Quod performance adjustment or
evidence that 100% owner tracing is now sustainable. Original trace data is
archived separately, not claimed rehydrated into the fresh live backend.
The current live resource/placement override differs from `deploy/tempo.nomad`;
it is recorded here rather than smuggled into the reviewed Quod cut.

### Separate restored-state cold/warm read checks

After backend recovery, two separately authorized **read-only health probes**
were issued, each once with the same 35-second absolute network budget. They
are not benchmark samples, do not retry an execute request, and did not clear
`BENCH_STOP`. Both used the existing browser client and remote `true.` goal.

The first probe authenticated successfully in 44.085 ms, then received no
proof HTTP response before its absolute deadline (35,006.019 ms including
authentication). The shared client classified the lack of response as unknown;
this is **not an uncertain write**. Its single subsequent Tempo snapshot
(`508001fcbb29423fb1a4ec1d7a133a06`) contains two eventually successful,
causally successive foreign-current checks:

| Cold read stage | Local elapsed ms | Verified suffix |
|---|---:|---:|
| Source verifies target committee | 9704.204 | 389 entries |
| Target authenticates source scope | 27369.304 | 1138 entries |
| **Sum of successive local durations** | **37073.508** | |

That is a sum of durations on each stage's own clock, not cross-machine
timestamp subtraction. Their call order is also pinned in the existing ask
and scope code. Both workers report retained height zero and outcome `ok`.
Identity-certificate collection is only **3.750 ms**. These are cold opens of
the node-wide **foreign cache**, not renewed full opens of the hosted source
ledger or a regression of Phase 1A's live-view invariant.

The corresponding worker walls are 9703.074 / 27367.833 ms. Their observed
direct-child unions cover only 1669.654 / 4508.431 ms, leaving **8033.420 /
22859.402 ms** without exclusive child-span attribution. The cache ledger-open
spans take 1662.815 / 4502.514 ms, including index decode 1654.702 / 4483.325.
The large phase-open-to-first-page gaps match the source's cold replay location,
but replay has a metric rather than a dedicated child span here. Do not turn
that structural localization into exclusive timed replay or CPU claims.
This cold control does not meet a 95% fine-grained function-attribution gate.

The successive stages already exceed the 35-second client budget. Their trace
does not contain a completed top-level request or server closed reason, so it
does not establish the earlier tracing-on `proof_unavailable` cause. It does
show a concrete cold-history delay with owner tracing **off**, rather than a
permanent lost wake or an identity-collector stall.

After both cold workers completed, the distinct warm probe succeeded with
HTTP 200, `result: ok`: **11.015 ms proof**, **56.212 ms authentication plus
proof**. It is one functional health check, not p50/p99 or a write result.
Its trace ID is `d4cfa8092bc848889aea4c23605d8a5f`; no further probe was issued.
Cold evidence: `/tmp/quod-restored-read-once-nL6AP1/TRACE-REPORT.md` and
`trace-elapsed-unions.json`; warm evidence:
`/tmp/quod-restored-warm-read-once-NVGRQm/REPORT.md`.

The SDK's batch processor can drop unexported spans without a per-leaf count.
Consecutive owner roots can establish interior root continuity, but cannot
alone prove every child was exported. Until child completeness is established,
report observed occupancy and explicit unknown time, not exclusive substep
attribution or inferred idleness.

## Evidence and open work

Raw driver, traces, ledger pages and scratch analyzers:
`/tmp/quod-owner-157-J7mLZz/benchmark/`. Particularly:
`off-tail-analysis.json`, `diagnostic-timeline.json`, `receipt-off-audit.json`,
`receipt-off-source-pages.json`, and `off-request-links/manifest.json`.
The failed on attempt is `owner-on-c1-n20/`; its exact driver artifacts
finalized at 18:17:06.793 UTC. `gates/on-c1-before.json` and
`gates/on-c1-after-failed.json` bound the owner sequence inventory in
`owner-failed-freeze-corrected/manifest.json`; the incomplete full retrieval
is `owner-failed-traces/manifest.json`.
Independent log/counter evidence:
`/tmp/quod-owner-157-offc4-health-WByI3w/REPORT.md`.
Retention proofs:
`/tmp/quod-owner-157-afteroff-Vze7Q5/retention-check.json` and
`/tmp/quod-owner-157-afteron-lYUbcA/retention-check.json`.
Final restored-state evidence:
`/tmp/quod-owner-157-restored-health-bqHBKX/retention-check.json`,
`runtime-off-proof.json`, and `installed-sampler-proof.json` in the same
directory. Failure-window health is in
`/tmp/quod-owner-157-onfailure-health-8LGlwR/HANDOFF.md`.
Private deployment snapshots are not review artifacts: they contain the live
job configuration and must not be published with the diagnostic evidence.

Keep the previous **+18.4% serial operation-result regression** and
**137.462 ms c4 source/endpoint duration gap** visible; this new claim-stage
tail does not explain either away. No 10,000-entry result is claimed.
The next architecture-reviewed work is the
[exact-reference lifecycle/trace contract](exact-reference-lifecycle-tracing-contract.md),
at the existing foreign-log owner. Its diagnostics and specified behavioral
refactors are approved as one cut, with the wake/custody proof conditions and
review-before-commit gate still binding. A new exclusion protocol would need
its own review. The
proposal-context carrier, duplicate-receipt verification contract,
result-authentication contract, Q4, finality, L2 and compaction retain their
separate gates. No fix or tuning is authorized by this measurement.
