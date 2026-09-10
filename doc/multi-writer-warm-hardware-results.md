# Warm multi-writer pilot — 0.7.159

**2026-09-10: measured development evidence, independently reviewed and accepted.
Serial conserved transfers passed; the concurrent pilot failed and stopped.
No further execute requests were submitted after the in-flight client calls returned.
This does not close any reliability, absolute-latency or attribution gate.**

## 1. Deployment and measurement boundary

The reviewed classifier correction is commit `4a97474`, with separate version
commit `af79612` (0.7.159). The reviewed gates were EUnit 1944/0, ask and QUIC
CT 26/26 each, Simplex CT 12/12, xref, Dialyzer and diff-check clean. The final
local gate archive also contains a successful production release build. No
additional production change was made for this campaign.

The image was pushed with manifest digest
`sha256:0d578122db88a58a82e9ff8af02ddcf08bcab03a51b48a5f4b6f12504bf525fa`.
Coordinated replacement preserved the volumes and configuration. All ten
allocations ran 0.7.159 with zero task restarts; the before/after comparison
preserved all 40 namespace identities, heights and committees. Source height
1138 and target height 389 were retained. No ledger was purged.

Deployment evidence: `/tmp/quod-warm-159-deploy-pGtrug/`, particularly
`retention-check.json` (SHA256
`87b20214ba391f869369cd35ec80c8ae107ca47ebff77290ff4f8f6ad358ba28`).

Yan's instruction to continue authorized work is the fresh go for this separate
warm campaign. The failed 0.7.158 cold read and its `BENCH_STOP` were not
modified, retried or averaged into warm latency. Eight one-time **unmeasured**
preparation calls used the existing `route_hints/2` and `current/3` verifier,
serially, with the existing 30-second API budget. All succeeded. They took
8.35–28.15 seconds including CLI observation, still exposing the cold-start
problem. They neither imported trusted snapshots nor inserted routes.
The subsequent ordinary signed-read preflight succeeded: 67.20 ms including
authentication, 14.94 ms for the proof call. These are setup, not write samples.

Campaign: `/tmp/quod-warm159-campaign-EszhsT/`. Warm calls, signed preflight,
seed operations, driver stdout/stderr, exact signed requests and stop markers
are retained there. Both seeds per pilot were once-only ordinary writes,
verified by exact initial-state reads before measured work.

## 2. Fixture and workload

- A is `quod:trace155-source`; B is `quod:trace155-target`.
- A committee allocations: 0/1/3/7; B: 2/4/5/6. Each has four validators.
- One source gateway; concurrency means simultaneous signed goals, not four
  gateways. Each goal debits A and credits B atomically using current L3.
- Each worker has its own balance/debit/credit **predicate functors**, avoiding
  accidental conflicts from different arguments of one shared predicate.
- Each transfer has an exactly-once marker on both sides; reads verify
  singleton balances, conservation and exact marker multiplicity.
- All goals end in a dot. No `independent/1` or L2 implementation is present.

**Topology qualification:** committees have disjoint allocation/validator
memberships, not disjoint physical hosts. The eight allocations share three
Nomad machines (`192.168.1.10`–`.12`). A occupies `.10/.11`; B occupies
`.10/.11/.12`. The scratch harness's “physically disjoint” assertion message
overstates its actual check, which compares member indices. The executed
harness is preserved; this report corrects that wording. This is not evidence
of four-independent-host fault tolerance or an isolated-machine throughput
ceiling.

## 3. Actual numbers, including failed requests

Nearest-rank percentiles, milliseconds; means use every admitted request's
observed time to its original client reply. Later recovery does not change a
latency or convert a pending client reply into a successful sample.

| Conserved A→B | Started / planned | Original committed / pending | Mean | p50 | p90 | p99 / maximum |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Serial c1 | 20 / 20 | 20 / 0 | 544.580 | 539.606 | 593.034 | 594.550 |
| Concurrent c4, stopped | 5 / 20 | 1 / 4 | 28,986.507 | 30,099.143 | 31,019.453 | 31,019.453 |

The c1 committed-only statistics are identical. At c4, the **single** committed
client sample is 23,612.057 ms; presenting it alone would discard four failures.
The c4 sample is a stopped pilot, not a completed 20-request distribution or a
release-grade tail estimate. Its fifth admission is request 8: worker 3 admitted
its next striped request after request 4 succeeded, before the other workers'
uncertainty stopped new admissions. The unattempted fifteen are not samples.

Raw: `pilot-transfer-c1/` and `pilot-transfer-c4/`, each with
`results.tsv`, `all-results.json`, `statistics.json`, `requests/` and `run.log`.
Independent recomputation in `/tmp/quod-warm-159-evidence-Repuz5/` matches both
tables exactly. There are 20/5 unique request IDs and trace IDs respectively.

The semantically independent-facts pilots and all n100 runs **did not start**.
They would still use L3, with T=2 including the source; no L2 or flat-T claim
could have followed from them. The whole campaign now carries `BENCH_STOP`.

## 4. Correctness and the five concurrent requests

The serial audit resolved all 20 exact signed operations through the existing
public outcome path: terminal, committed, binding checks passed. Both numeric
and multiplicity oracles passed. Source advanced 1141→1201, target 390→430.

| c4 request suffix | Original result | Observed ms | Recorded uncertainty producer / cause | First read-only outcome check |
| --- | --- | ---: | --- | --- |
| 1 | HTTP 202 `pending`, group `c5c552…cd5ae` | 30,196.552 | `target_execute / engine_result` | committed, Complete at A1211 |
| 2 | HTTP 202 `pending`, group `198dff…7b6cb` | 30,099.143 | `target_execute / engine_result` | committed, Complete at A1212 |
| 3 | HTTP 202 `pending`, group `41214e…bfe2c` | 31,019.453 | `target_execute / engine_result` | committed, Complete at A1212 |
| 4 | HTTP 200 `ok`, group `363a7c…f09d` | 23,612.057 | none | committed, Complete at A1207 |
| 8 | HTTP 202 `pending`, no group in reply | 30,005.330 | `gateway_execute_transport / response_timeout` | pending, nonterminal |

All four warning lines were emitted at source gateway allocation 0. Exact
terms, IDs, timestamps and sanitized Loki records are archived in
`health-transfer-c4-failure/` beneath the deployment directory. These producer
labels locate the **client-result boundary**, not the exclusive cause of delay.
There was no conflict refusal: calling these expected wait-die aborts would be
unsupported.

The first outcome audit was at 23:59:00 UTC on September 9. It performed only
read-only resolution with the preserved signed bytes, never execute. It did
not claim full drain or run an expected-final-state oracle with unresolved
requests. Separate observational reads at 00:04:45 UTC on September 10 found
each A balance `[4]`, each B balance `[1]`, one marker per request 1–4 on each
side and no request-8 marker. Total observed balance remained 20. These reads
do **not** turn request 8's absence into a durable rejection or permission to
resubmit it. A final read-only outcome snapshot at 00:12:07 UTC, after the
captured proof had terminated, still reported request 8 nonterminal. The other
four remained committed. Neither snapshot changes the original client results.

The later fleet snapshot was healthy: source A1212 and target B445 agreed
across their committees, no restarts, all namespace projections applied/idle.
Committed block inspection shows group 4 followed by a three-group Begin at
A1208. B434–B442 are **nine complaint-certified noops**, not duplicate
applications; the three later Prepares are in B443. Their Finalizes and
Completes exist. Block timestamps are producer timestamps, not measured
commit-observation spans, and are not substituted for stage latency.

## 5. What the traces prove, and what they cannot see

Finite retrieval only: three c1 requests (first/p50/worst), all five attempted
c4 requests and one setup trace. No search, root inventory, retry, automatic
link expansion or owner-turn enablement. Tempo remained healthy: final ready
HTTP 200, RSS about 314.5 MB, no refused/discarded spans in its whole-process
counters. Those counters are not benchmark-scoped completeness evidence.

First-four c4 proofs take 35.8–87.6 ms, but the group/result wait has **no
phase-level trace decomposition**. Source tracing is lost before group
coordinator creation: `quod_dtx_coordinator:start_monitor/5` starts a new process
without inheriting context, unlike `start_operation_monitor/4`; the upstream
reservation/activation messages also carry none. Thus no exact-reference jobs
or group phases occur in these request traces. Their absence means missing
observation, not zero work.

Request 8, trace `76ae88de5163331cfb004fe8c0f48e56`, is more informative:

| Same-target-allocation observation | ms |
| --- | ---: |
| `foreign.current` | 47,062.812 |
| owner caller residence | 47,062.577 |
| queued | 47,056.210 |
| verification worker after selection | 5.961 |

The worker starts from resident/disk height 1208 and performs no replay, cold
open or new-entry advance. The queue has no predecessor job ID/link. It cannot
distinguish an earlier active/retiring worker, earlier custody park, earlier
queued work or owner scheduling. Do not call this a custody defect or resurrect
the deleted singleton-group-queue diagnosis.

The gateway ends at about 30 seconds; a later proof span reports
`scope_expired`. Source uses different budgets: browser signed-request TTL is
30 seconds, router ceiling 60 seconds reduced by remaining signed lifetime,
and proof-engine default 60 seconds with its remaining budget passed to remote
authentication/current-view verification. The actual wire remaining budget was
not traced. A 47-second foreign success does not prove violation of its own
absolute caller deadline or successful delivery to the original client.

The unchanged expected-count auditor remains strict: canceled probe/page
parents are missing in the setup/c1 samples. The c4 structural inventory passes
but cannot identify an unlinked predecessor. No >=95% **client-level** or
whole-campaign attribution is claimed. Detailed notes and immutable raw trace
manifests: `/tmp/quod-warm-159-evidence-Repuz5/PILOT-TRACE-SUMMARY.md` and
`REQUEST8-LIFECYCLE.md`.

## 6. Cold replay reappeared in the concurrent-run window

Archived Prometheus samples—not absence of spans—show extra replay work.
All eight `cache_replay` counts remain flat between the last pre-c1 samples
and the last pre-c4 samples. Subsequently five nodes each complete two more
replays. The other three source nodes' counts remain flat in that window.

| Allocation | Extra replay completions | Added replay seconds | Added ledger-open seconds |
| --- | ---: | ---: | ---: |
| home 0 | 2 | 54.630 | 16.218 |
| home 2 | 2 | 45.696 | 9.857 |
| home 4 | 2 | 37.740 | 7.809 |
| home 5 | 2 | 45.902 | 9.754 |
| home 6 | 2 | 55.514 | 11.712 |

These are per-node cumulative-counter differences across **actual scrape
boundaries**, not per-request stage sums. On home 6: the 23:57:28.191 sample
has 8 replays / 21.784647420 seconds; 23:58:13.191 has 9 / 50.064875963;
23:58:58.191 has 10 / 77.298747621. The new replay durations are therefore
28.280 and 27.234 seconds. Later home-0 totals show two additional completions;
they are not silently included in this bounded-window table.

The shared stage metrics have no identity or job labels; the table cannot
establish which predecessor blocked request 8. Full stage counts/sums and
raw timestamped samples are in deployment evidence
`health-transfer-c4-failure/raw-metrics-once/`. Concurrent coordinator work on
multiple validators overlaps; summing those stages is not wall-time attribution.

The measured 0.7.159 source exposes a plausible amplifier at one owner: a failed exact-reference
attempt in `verify_cached` closes its ledger handle and phase session;
`verify_exact_routes` passes `Resident=none` to the next candidate. The next
attempt can cold-open/replay the same prefix while retaining the one identity
worker slot. That is source-established possible behavior, **not yet proof of
this hardware trigger**.

A source-identical synthetic probe now reproduces that amplifier through the
public `current` → `verify_reference` APIs. Its stronger fixture retains a
genuinely certified Prepare at slot 2, then requests Finalize at slot 3:

| Warm exact-reference case | New full opens | Replayed entries | Phase file | Verdict |
| --- | ---: | ---: | --- | --- |
| healthy first route | 0 | 0 | unchanged | valid Finalize |
| retryable first route, then healthy route | 1 | 2 | replaced | same valid Finalize |

Both fetch only the requested suffix; the failed route returns the existing
typed `retry`. Real Erlang call tracing (with delivery barriers) and real SDK
counters agree. The four probe cases include the weaker genesis-prefix control
as well as the non-genesis case. They pass on unchanged production code because
they characterize the existing defect, not an implemented correction.
Artifacts: `/tmp/quod-exact-route-replay-probe-DIys3I/`, `run-4.log` (exit 0),
the scratch probe and isolated seeded caches. The existing test fixture module
was compiled with extra exports only into `/tmp`; repository source/tests were
not changed. This proves the mechanism, still not the preceding hardware job
or exclusive explanation of c4. The subsequent approved contract preserves
verified state across failed attempts without weakening validation or custody;
its implementation has not yet been deployed or measured.

One separate metric defect in this measured version also prevents an fsync claim: signing-journal
vote-sync observations pre-convert native duration to seconds before passing
it to a seconds-inferred Prometheus histogram. Counts are nonzero but exported
sums are zero. This is not zero fsync time. The other group/foreign helpers
observe native durations. The metric correction needs its own regression;
no production change was slipped into this measurement campaign.

## 7. Next boundary

1. Preserve this failed warm run, signed operations and all ledgers. Do not
   rerun c4, start the independent-facts pilot, or expand to n100 around it.
2. The seeded-prefix probe and success-first control now reproduce failed-route
   replay amplification on unchanged source. Preserve them as the implementation
   regression basis. Do not name it the exclusive hardware cause without
   predecessor/job evidence.
3. The [existing-owner contract](foreign-history-failure-residency-contract.md)
   was approved on 2026-09-10: cache/session lifetime independent of request
   success; L3 context through existing admission/coordinator owners; queued
   caller/predecessor links and budget observation. The completed implementation
   returns for review with local gates before any new deployment. No new owner,
   cache, verifier, poll, cap or timer tuning.
4. Review before any consensus/DTX-facing implementation commit. Then measure
   again only under the corresponding gate; retain the failed pilot alongside
   any later run.

The dated common-multi-writer direction is recorded in the roadmap and world
direction. It opens an L2 slices **6–8 contract refresh**, not implementation or
an unsubstantiated latency promise. Result authentication, Q4, duplicate-receipt
validation, finality, compaction/cold checkpoints, 10k-height behavior and the
absolute gates remain open. In particular, no “1.8-second current L3” figure or
N-times-singleton-lock explanation is supported by this campaign.
