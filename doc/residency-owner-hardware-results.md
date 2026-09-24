# Residency owner deployment and stopped warm pilot — 0.7.160

**2026-09-10: development evidence independently reviewed and accepted. The reviewed
owner cut is committed and deployed with preserved ledgers. The new c4 pilot
failed its original-response reliability gate. No absolute-latency or client
attribution gate is closed; no further implementation is authorized here.**

## 1. Exact cut, deployment and preserved state

- Behavioral/observation commit: `76045c4`.
- Separate version commit: `3b58f51`, 0.7.160. Both pushed to `claude/next`.
- Registry manifest:
  `sha256:28936b182055494e648da2ac8037e6412c392e34cc9b81d00e6f2412b35151b2`.
- Reviewed gates: EUnit 1972/0; ask/QUIC CT 26/26 each;
  `quod_simplex_SUITE` 12/12; N=4 `simplex_SUITE` 8/8; xref, Dialyzer,
  production release and diff-check clean. The image build also succeeded.
- Reviewed fingerprints matched before commit. Yan's five write-lanes files
  remain excluded, combined diff SHA256
  `f0de37bfd4b4cf504502c51f502e756a4c110150628b86a7046979fe603fec04`.

Deployment archive: `/tmp/quod-residency160-deploy-thpeIK/`. Its protected
`job.json`/`job-before.json` contain private templates: do not print, export or
commit them. Preparation proves only the three Quod task image fields changed;
templates, volumes, root anchor, sampler and owner flags were preserved.
Every old allocation stopped before replacement. No purge or re-found occurred.

The first preparation check correctly failed: eight allocations were running,
not the previous ten. Both cloud allocations had already failed their
`wait-for-peer` sibling's network setup: pulling the pause image could not
reach containerd. This was present before the Quod upgrade. The amended scratch
check captures those two failed allocations explicitly, rather than inventing
an empty namespace observation or claiming a healthy pre-deployment fleet.

All ten replacement allocations were running by 09:49:38 UTC, zero Nomad task
restarts. An early namespace-health snapshot failed during normal replay/
reconciliation and remains archived. The later `health-after-ready` snapshot
and exact retention comparison passed: all **40 home namespace rows**, their
heights, anchors, committee identities and applied floors were unchanged.
The benchmark source retained height 1212; target retained 445. The two cloud
allocations returned empty namespace lists after restart; their unavailable
pre-deployment state is not a demonstrated cloud-ledger retention baseline.
Cloud allocations remain outside the benchmark committees.

Zero Nomad restarts is **not** zero Erlang child crashes: a source Simplex
child later crashed during the pilot, recorded in section 5.

## 2. Workload and original-response numbers

New campaign: `/tmp/quod-residency160-campaign-VKE6Xe/`.
Old .158/.159 failures, signed requests and `BENCH_STOP` markers are unchanged.
The existing fixture/harness was reused, with only version/path/topology wording
adapted. A is `quod:trace155-source`, members 0/1/3/7; B is
`quod:trace155-target`, members 2/4/5/6. Both have N=4 committees, with disjoint
validator allocations **sharing three physical machines**. There is one source
gateway. Different concurrent workers use distinct predicate functors, not
merely different arguments to a shared functor.

Explicit unmeasured preparation called the ordinary current-view verifier once
per home node, for its opposite ontology. All eight calls passed; source-history
preparations took up to 26.797 seconds. Those are setup costs, not write samples.
The ordinary signed-read preflight passed in 62.531 ms total / 15.103 ms proof.
No failed cold read was retried or silently relabeled warm.

The warm boundary is narrower than an entirely warm node: it prepared the
opposite ontology, **not a second foreign-cache copy of a locally hosted
ontology**. Section 4 proves that unprepared same-host path actually executed.

Conserved A→B transfers, all original responses included:

| Run | Started/planned | Committed / pending | Mean ms | p50 ms | p90 ms | p99 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| c1 | 20/20 | 20 / 0 | 591.722196 | 589.494051 | 636.528284 | 663.117274 |
| c4, stopped | 14/20 | 10 / 4 | 23628.851969 | 24735.504914 | 30677.400280 | 30774.173935 |

The c4 **committed-only** subset is n=10: mean 20901.669412 ms, p50
18800.298186 ms, p99 24735.940170 ms. It must never replace the all-attempt
table. Six planned but unadmitted requests are not samples. The first four
concurrent requests each returned committed after approximately 24.736 s.

For comparison, the approved .159 pilot was c1 n20 mean 544.580217 ms /
p50 539.605801 ms / p99 594.550401 ms. The new serial pilot is slower, not
a demonstrated improvement. These are retained-history, separately labeled
pilots, not controlled repeat-run estimates of regression causality. The .159
c4 stopped after five admissions (one original committed, four pending), so
its different stopped population cannot support a clean speedup ratio.
The serial mean increase is approximately **8.7%**, unexplained and explicitly
carried into the next controlled campaign.

The new c1 terminal-outcome and conservation/multiplicity oracles all passed.
The c4 runner stopped new admissions on uncertainty and allowed only its
already-inflight calls to finish, ending at **09:56:40.752 UTC**. Both its
per-run STOP and the campaign BENCH_STOP remain. Independent-facts pilots and
all n100 runs **did not start**. No `independent/1`/L2 performance is measured.

All raw TSV/full JSON pairs were independently recomputed with unique request
and trace IDs, exact full-precision statistics and TSV rounding checks:
`/tmp/quod-residency160-outcomes-1M7K4T/statistics-recomputed.json`.

## 3. Pending replies versus durable recovery

Original pending request suffixes: **9, 11, 14, 16**, observed respectively at
30209.427603, 30126.231631, 30774.173935 and 30677.400280 ms. Each HTTP 202
carried the exact group/operation binding. These are neither ordinary Prolog
failure nor a demonstrated conflict abort.

The first post-stop audit failed before any outcome query because source
replica 3 was syncing. Its stderr and partial audit directory remain. A later
finite **outcomes-only** audit used the original signed bytes at the existing
public outcomes endpoint; no execute or Prolog goal was submitted. At
**09:59:44 UTC all 14 original operations were terminal committed**, with
exact request-digest and operation-ID bindings. Private evidence:
`/tmp/quod-residency160-outcomes-1M7K4T/outcomes.json`.

This proves observed durable recovery, not successful original delivery. It
does not change any original category/latency or substitute for the unrun c4
numeric state oracles. The old .159 request 8 was separately queried after
deployment and still reported pending; no resubmission was made.

## 4. What the new traces establish, and what they do not

All 34 exact request trace IDs were retrieved sequentially, without broad
search or recursive link traversal. The c1/c4 manifests resolve every recorded
outgoing predecessor link when combined. Full derivation and identifiers:
`/tmp/quod-residency160-campaign-VKE6Xe/TRACE-FIRST-PASS.md`.

### 4.1 Same-host history enters the foreign verifier

c1 request 2, trace **`11febad717590e0c4d278d9fd2f44660`**, contains a
41,298.440165 ms exact worker on source node 0, job
`1de507d6da92f2183aa9ebe9daf90b4c`. It verifies **A's own Decision at 1220**:

| Worker segment | ms |
| --- | ---: |
| Complete worker | 41298.440165 |
| Cache open, including the following two nested segments | 37205.295907 |
| Certified replay, 1210 retained entries | 30839.485514 |
| Ledger open | 6359.108669 |
| Index scan, inside ledger open | 6358.919807 |

Resident start is 0, disk height 1210, final verified height 1220: one cold
open, zero resume failures and ten newly verified network entries. The
opposite-ontology preparation on node 0 warmed B, not A. **This does not prove
the new cursor discarded warmed B**, nor does it remove the cold O(history)
hardening item. Shared exact work survives the original caller's deadline.

The recorded worker ran 09:54:54.160–09:55:35.458 UTC. Its cache-open/replay
finished around 09:55:31.366. c4 requests 5–7 link to its **post-replay fetch
tail** (0.535–0.577 s), then wait about 4.114 s behind callerless unrecorded
job `cc368b089534a64bef908a99f0be9e57`, followed by 0.309–0.351 s behind
`83e74e6a1600732d443cae4064dabefc`. Their three markers each match the producer's
expected count. Both later predecessor trace contexts are explicitly absent;
job IDs are not fabricated trace IDs.

The first four c4 requests finish before that recorded worker ends and have
no corresponding recorded blocker. **Replay overlaps their 24.7 s latency;
it is not established as its exclusive mechanism.**

Source explains a reachable inefficiency: coordinator `endpoint_sources/2`
promotes the remote reply source, and `phase_evidence_sources/7` /
`verify_phase_raw/6` choose local versus foreign verification from that reply
source, even for a locally hosted target. Each remote arm invokes the same
foreign verifier without using the selected peer's endpoints. In contrast,
Simplex's existing `verify_remote_dtx_reference/5` already prefers its exact
owned history view when available. An evidence-source selection contract can
reuse that distinction; this report authorizes no shortcut or implementation.

### 4.2 Slow attempts also exist without replay

Trace `5207c07218c89a585edfc188a8db69ec`: Begin1291 resumes1287, zero replay,
four verified new entries, 4025.253279 ms total with two roughly 2-second
unsuccessful source attempts. Trace `cda9c3118e8359b1550f416db8a68884`:
Begin1301 resumes1298, zero replay, three verified entries, 6041.807225 ms
with three such waits; the original 5000 ms caller expires first. A
`wire_error` terminal is captured. These are not grounds for timer retuning,
a retry loop, or claiming all c4 cost is replay.

### 4.3 Client attribution still fails

No `quod.dtx.coordinate` parent exported in these 34 traces, although new
wave/endpoint children are present. The coordinator's process-lifetime span
can lose its normal cleanup when Simplex retires/replaces that child with
external `exit(Pid, shutdown)`. That is a source-proven possible lifecycle;
the capture does not prove every missing parent's individual death sequence.

Conservative per-request local interval partitions, then means (ms):

- c1: 591.722196 = proof-owner 52.371747 + concrete client stages 0.793851
  + unlocated source-root remainder 529.957725 + driver/root boundary 8.598872.
- c4: 23628.851969 = proof-owner 177.661902 + concrete client stages 1.361075
  + unlocated source-root remainder 23437.542210 + driver/root boundary 12.286782.

This strict partition attributes only **8.9849% / 0.7576%** respectively;
it is a lower bound, not a claim all observed orphan children did no work.
It never silently credits time outside `prove` or subtracts clocks across
allocations. Proof-owner duration is not exclusive function CPU.

Combined worker-local coverage is **99.9430%**, but cannot replace the client
gate. The unchanged exact auditor retains 32 issues: 15 missing cancelled
probe exports, 15 associated missing page parents, and two unclassified actual
wire-error spans. All 56 captured blocker residence counts pass. A missing
normal parent is not repaired by changing the expected-count auditor.

Metrics independently record two completed replays between the c4-inflight
09:55:23 sample and the after-stop 09:57:46 sample: home0 +30.839524 s and
home3 +30.253432 s. This window includes autonomous work and has no job labels;
do not sum these replica seconds as client wall time. Corresponding aggregate
phase-resume/suspend increases are only 0.759887 / 0.194067 seconds.
Raw metrics, bounded logs and the corrected timestamp label are in
`health-evidence-ht2S3d/` under the campaign. Its directory called
`measured-c1-inflight` was actually captured during c4; the amendment preserves
the original name and raw bytes.

## 5. Separate correctness failure: retained signing refresh

Home3's source Simplex terminated at **09:56:37.907400 UTC** with
`error:stale_retained_dtx`. The retained stack is:
`retained_placement → install_dtx_submission → refresh_dtx_submission →
reconcile_signing_state_journal → commit_block → drain_commits/apply_events`.
The supervision reports follow at 09:56:39.098598/39.131153. Exact protected
logs: `health-evidence-ht2S3d/logs-after-stop/loki-window-raw.json`.

The first two pending replies occurred at 09:56:22, **before this crash**.
The crash is a real correctness finding, but cannot retroactively explain
those earlier expiries. Zero Nomad restarts must not hide it. Refresh currently
re-envelopes an own-author retained control when its sequence floor advances;
installation rejects a record that the current committed projection already
classifies stale. The subsequent
[unchanged-source regression](retained-dtx-renewal-ordering-contract.md)
now reproduces this order with valid alternative Prepare proofs and a real
synced journal, including the extra durable sequence floor before failure.
Its phase/group identifiers are synthetic, not recovered fleet identifiers.
The correction remains contract-review-gated. Do not
catch/ignore the invariant error or automatically resubmit the old control.
The existing `reclassify_retained_row/2` already handles stale retirement;
the renewal arm bypasses that classification after adopting a new projection.
The next correctness contract should order semantic classification before
sequence renewal, preserving the existing waiter and journal obligations.
The formatter truncated the crash state before retained records/slot fields,
so the particular offending phase, GroupId and sequence values remain unknown.

Comparison with the archived .159 source finds the failing placement/signing/
refresh/commit logic unchanged; the cut only adds a context copy after the
failing installation. This is a pre-existing branch exposed during the new
run, not proof the cut introduced the defect. At 10:05:54 UTC, a one-shot
check finds the same allocation/zero Nomad restarts and a responding source
Simplex at committed/applied/approved height 1304, idle and not syncing.
However, `quod_runtime_healthy` for that namespace is still **0**. Neither
eventual outcomes nor a responding consensus process prove full runtime
health recovery. No additional workload was admitted.
One subsequent public `quod_runtime:stats/1` observation identifies the state
behind that metric: mode `replaying`, runtime height/p_height/e_frontier 1302,
founding ready, no active runner or queued work, zero reconcile failures and
collapses, while the applied consensus/Prolog prefix is 1304. This is a
remaining replay-readiness discrepancy, not an identified permanent-error
reason; the missing or ignored progress edge has not been established.

## 6. Next review boundary

Keep the fleet and ledgers preserved, with no further benchmark admissions.
Independent evidence review is closed; no performance or reliability gate
closed with it. C's [diagnosis and proposed ordering](retained-dtx-renewal-ordering-contract.md)
preceded the [A+B contracts](dtx-evidence-and-observation-contract.md), which
are now drafted for architecture review before implementation. B concerns
the coordinator root only; canceled-probe child coverage remains an explicit
gap, not an implicitly approved wider tracing change. Prefer the
existing immutable owner view and verifier, not another cache or decoder;
separate actual endpoint delivery from route-neutral evidence verification.
Carry one original absolute budget through any capture/verification refactor.
No proposed behavior may weaken exact bytes, anchored incarnation, committee
era, phase or finality checks.

No c4 cause is declared exclusive below the 95% client gate. The absolute
gates, old slot1059/outlier, old .159 request8, result authentication, Q4,
duplicate-receipt contract, finality, L2, compaction/cold start and 10k-entry
measurement remain independently open. The cut's local review is not undone
by an unproven hardware regression claim, and failed hardware acceptance is
not converted into success by the eventual committed outcomes.
