# Work handoff — 22 September 2026

This is a working handoff, not a protocol or presentation specification.
Repository `AGENTS.md` and the approved architecture remain the engineering
rules. In particular, Yan explicitly said on 22 September that `present` is
**not normative**. Do not turn the presentation prototype into a requirement.

**Historical status — 2026-09-24.** This file is the chronological record of
the work through release 0.7.236. Later dated sections supersede earlier
"active" and "next" wording. Current architecture lives in the named design
documents; this handoff records the measurements, reviews and release evidence
that led to it.

## Active: receiver-side repeated authentication

The approved scope decodes each distinct signed transaction once per bounded
page, keyed by exact envelope bytes and symbol mode. It is not a persistent
cache, consensus verdict, permission, or current-view confirmation. Existing
revocation, historical committee, finality and deadline checks remain separate.

Recovered original design and review:

- `_build/receiver-resume-20260922/recovered/DESIGN.md`
- `_build/receiver-resume-20260922/recovered/CLAUDE-RECEIVER-RULING.md`

These were recovered from the saved review transcript after the old `/tmp`
freeze disappeared. They are NOT a newly verified copy of that old 89-file
manifest. The old model's reported results remain historical; its source and
receipts have not been recovered or rerun.

Current progress:

- Read-only recapture recovered the original 14 retained entries under the
  original source anchor, using the original seven trace page boundaries.
- Freshly compiled unchanged decoders reproduced **530** signature checks.
- The local refactor measures **218** checks, with identical output bytes.
  The older two-entry fixture likewise measures **104 → 56**.
- The page fold moved from catch-up into the existing ledger decoder; recursive
  evidence shares the transaction decoder's opaque call-local context. The old
  fold/private arities were replaced, not retained as another implementation.
- Targeted decoder, artifact, catch-up and historical-verifier tests: **137/0**,
  with 14 permanent receiver tests and the native-constructor inventory control.
  Initial diagnostic/fixture failures are retained in
  `_build/receiver-resume-20260922/FAILURES.md` with subsequent full local logs.
- Seven in-memory deliberate-bug controls are detected at their intended tests:
  no reuse, omitted symbol mode, omitted envelope bytes, skipped author check,
  skipped enclosing-reference binding, request revalidation and entry finality.
  Fresh-VM symbol/atom, real-page, unique/repeated/maximum-byte resource and
  old-code exit-17 controls are complete. Counts and limits are frozen.
- Production delta: **+61 lines** (+158/-97) across three modules. This pays for
  explicit context threading and API documentation; no new module/process/cache.

The final integrated tree passed all **17 clean sequential gates**, EUnit
**2802/0**, and is committed as `c01d46e`; `.219` label-only bump is `6cc3a7c`.
Publication/deployment is authorized for this overnight session; no independent
Claude implementation review is claimed. Freeze:
`_build/receiver-resume-20260922/release/freeze-v1/MANIFEST.json`
(SHA-256 `8189b60b31bfea314326829b21976684ea0097d139bc89d5b36a94f8bc98f605`).
GitHub readback is verified at `6cc3a7c`. The `.219-c4p1` image digest is
`sha256:563d02facd866cbd5df21f8c4cc347e0ab7f612440e7969c3b5ac36259fb9c58`.
Post-swap retention is exact for all 76 rows and ten identities. The first
post-start snapshot caught temporary unapplied state; the second was fully
healthy. Measurements are now complete: 384 requests in the first matrix and
96 multiwrites in a separately labeled, lower-overhead repeat, all successful.
See `_build/deploy219-tLXbt5/REPORT.md` and `LATENCY-REPORT.json` for every cell,
cohort, tail, trace exclusion and retained failure. No matched baseline means
the full latency difference cannot be credited to this patch.

## Separate: ontologies and integration fixtures

- `quod:names`: deterministic naming vocabulary and predicates.
- `quod:licence`: licence facts and policy rules; useful deterministic test
  data, not a statement that the rules constitute verified legal advice.
- `quod:measure`: units and dimensions, also useful as ordinary proof data.

Use names/licences for optional ordinary, co-hosted and remote proof smoke
tests. They do not replace signed-history, malformed-envelope, authority and
expiry regressions for the receiver change. Their already-deployed implementation,
tests and UI assets were preserved in the separately gated `.218` checkpoint
`9898a72`, with label `0531c00`; present/lens remain explicitly experimental.

## Separate, non-normative: presentation brainstorming

`quod_present.pl`, `quod_lens.pl` and the client `lens`, `marks`, `scene` and
Prolog-text reader files are an experimental implementation, not an adopted
architecture. Leave them untouched while finishing the receiver scope.

Questions for that later discussion, not decisions:

- The prototype's depicted entities use namespaces without exact genesis
  anchors. How will it preserve exact identity across re-founding?
- It currently parses textual proof replies, including a documented workaround
  for binary/key rendering. Decide the structured reply boundary independently
  of the drawing vocabulary.
- A refresh replaces the entire rendered mark set; it is not incremental
  owner-scoped subscription delivery yet.
- Decide the ontology/policy versus client-renderer boundary before treating
  the drawing schema or lens interface as stable.

## Publication boundary

Read-only Nomad inspection found all ten desired allocations running `.218`,
with 76 namespace rows (the two cloud observers also host the five new
ontologies). The earlier 66-row estimate was a root-only cloud assumption;
the failed precheck is retained, not relabeled. All 70 public image files
matched the checkpoint.
The receiver's three production modules were unchanged from `.214` before this
pass. Publication includes the already-deployed local `.215`–`.217` ancestors,
the `.218` checkpoint and `.219` receiver commits. Unrelated dirty documents,
trace fixtures, AGENTS/CLAUDE and Tempo settings are not included.

The coordinated .219 swap completed at 00:40 UTC, job version 178, preserving
all volumes. Both subsequent diagnostic sampling windows are now closed;
normal sampling was restored after each observer cleanup.
Deployment receipts and live progress belong under `_build/deploy219-tLXbt5/`;
inspect those before attempting an action again.
The first campaign (`witness/`) stopped before measured admission: Nomad exec
returned exit 0 before a diagnostic observer's ACK file existed. Its original
late ACK was recovered and that exact observer was stopped/released. Two setup
writes committed; zero measured requests. Its BENCH_STOP is permanent.
`EXEC-TRANSPORT-CONTROL.json` reproduces output truncation in 1/20 pure Nomad
commands (56,320/65,536 bytes, exit 17); direct attached Docker exec over verified
SSH passed 20/20. This proves output loss, not the precise startup-race cause.
The fresh campaign is `campaign-b-IBWsHk/`, using the same per-allocation
serialized diagnostic controller and hash-checked files. All 15 offline suites
pass unsandboxed; no production change, new timeout, observer owner or retry.
The live matrix launched once at 01:04 UTC and passed 96/96 with six complete
observer teardowns and exact state audits. Basic tests in that root stopped
before any network request because of an erroneous deployment-root == campaign
root assertion. The shared readiness gate already checks both identities and
hashes; a new basic-only root removed that redundant assertion and has its own
control. All prior STOPs remain. `basic-c-D5rEtR/` then passed 288/288, including
all six write multiplicity oracles. First combined matrix: **384/384**, no 503s
or uncertain writes. Both failed setup campaigns admitted zero measured work.

Normal sampler restoration completed at 01:09 UTC (same .219 image). One cloud
observer took longer to regain contacts for the five newer ontologies; its first
post-restore snapshot was retained as unhealthy. Service progress later reached
10/10; `basic-c-D5rEtR/health-restored-v2` is fully healthy with exact 76/76
retention versus the actual pre-restore state. No wipe or cache retirement.

The first matrix's trace evidence is incomplete: Tempo logs prove its
10,000-live-trace limit was exceeded **during** the measurement. Recorded
sampled/recording roots cannot be called idle merely because their exports are
missing. All raw failures, O exclusions and unchanged denominators remain.
Current-view page decoding is smaller, but caller freshness and target delivery
still dominate independent c4; atomic outliers remain partly unattributed.

`window-d-GKrZOb/` was a fresh same-image, sampler-only window,
with full ordinary sampling and **owner-turn tracing disabled**. This removes
the diagnostic high-cardinality source rather than changing production or
raising Tempo's limit. Its controller launched once at 01:21 UTC, completed a
fresh 96-request matrix then restored normal sampling. The initial startup
health snapshot was incomplete, so no campaign was admitted at that point.
After real readiness, only the unperformed steps continued: 96/96 successful
requests, exact audits and observer cleanup, restoration at 01:26 UTC. The final
76-row retention and health checks pass; all ten actual SDK samplers are back
to parentbased_traceidratio/0.05. Tempo discarded no additional spans in this
repeat; all 432 externally counted attempt roots were retrieved. This does not
waive the O analyzer's partial-stage chronology or full attribution gate.

**Next diagnosis, not an implemented fix:** independent c4 averages 494 ms in
the cleaner repeat, with 106 ms remote current-view acquisition and 207 ms
target delivery. Atomic c1 has a 3.49-second tail: every source driver pauses
about 3.27 seconds between short waves while target slot 1222 awaits evidence.
The target has fast successful parent validations, but its exact proposal and
durability boundaries are not recorded under ordinary tracing. The preceding
slot explicitly waited 1.35 seconds in consensus. Neither a lost wake nor
slow consensus is yet established as the cause at slot 1222. Use the bounded
block lifecycle/hash to join durability to follower publication; do not enable
every owner turn again or add retries. `ATOMIC-RESIDUAL.json` records exact IDs.

The suspicion that reconstruction repeats signature checks was separately
refuted: verifying the 50 top-level decoded transactions from the seven real
pages performed zero additional signature checks. Do not broaden the signing
receipt or remove freshness/finality checks to optimize a repetition that isn't
there. Current-view verification still needs an actual-operation profile.
Never overwrite a fresh-label output or clear any STOP/BENCH_STOP. Implementation
and frozen gate evidence are under `_build/receiver-resume-20260922/`.

Measurement freeze: `_build/deploy219-tLXbt5/freeze-witness-239oG9/`.
Manifest SHA-256 `4af176fd17fd7faccef3515ad0cc14a92cfbbb2989ec260f7389a50cd326cb84`;
13,183 files passed an independent second hash pass after copying. Its
`REVIEW-HANDOFF.md` gives the retrospective review entry points. This is a
**private local** snapshot (Nomad templates must not be published). Normal
operation is restored; no diagnostic observer or sampling window remains owed.

## Active next refinement — subscription demand (22 September)

Do not stop at this checkpoint. Yan explicitly requested another implemented,
gated, deployed and measured optimization round. Main/GitHub and all ten fleet
nodes are now `.220`, healthy after the completed preserved-data deployment.
Scratch diagnosis: `_build/atomic-boundary-kP2EZT/`; isolated implementation
workspace: `_build/follow-demand-NhfIr0/`.

Sixteen fresh serial atomic requests all committed, eight bounded native
Simplex trace sessions closed with zero omissions or owner deaths. The prior
3.3-second stall did not recur; mean 592 ms, max 1,079 ms. The run's final
guard exited 1 because it hashed unordered Nomad JSON; `GUARD-TRIAGE.json`
retains the failure and proves structural configuration/identity preservation.
No sampling/config changes. All older STOPs and raw evidence remain.

Concrete new causal lead: `quod_dtx_coordinator:attach_follow/2` requests the
same materialized Prolog projection as runtime fact consumers. Every new group
therefore starts a projection replay from zero after its preceding consumer
unfollows. Native current/exact workers correctly report zero cache replay,
but these separate projection workers repeatedly decode the retained ledger.
Serving metrics exposed 21–37 CPU/wall seconds of full range materialization
per source node during the brief run. Quiet reads of the same entries take
under 3.4 ms, raw transport reads under 2.1 ms. CPU contention, not sparse
index growth, is the supported lead.

Implemented: explicit follow demand (certified progress versus materialized
facts) within the SAME owner, registration, verification and credit lifecycle;
coordinators need the former, runtime/directory projection consumers the
latter. No second owner/cache, no authority/freshness shortcut, no polling.
Prove zero materializer starts for coordinator demand, preserved projection
behavior for real fact consumers, mixed-consumer removal and exact wake
ordering before gates/deploy. A separate QUIC ACK-delay accounting suspicion
is parked: not shown causal and must not distract this scope.

Publication: `b4de0dbbf4a7cee9b136086509b0339efe965a22` implementation,
`d3c6fe4ec29d0607a90e3508e4e479c610def9be` label-only .220, both pushed and
read back from GitHub. Final clean gates-v2 17/17, EUnit 2809/0; seven controls
all matched. Freeze `_build/follow-demand-NhfIr0/freeze-v1/MANIFEST.json`, SHA
`9bcad6c18b4f589096bb3a846b5c469d72d1cbfc14476480daba52c702b478c5`.
Self-review caught a late facts subscriber receiving an incremental first
notice; fail-before retained, first-baseline lifecycle fixed and fully regated.
Net +37 production lines; no process/cache/queue/timer or format change.

Deployment: `_build/deploy220-SlJp3Z/`, exact retention of all 76 namespace rows
and ten identities; no wipe, cache retirement or sampling change. Post-witness
health is green, no error-level logs, standing cloud advertisements remain.
Four fresh 16-request cells all passed (64/64, zero 503s/resubmissions, both-side
audits). Atomic c1 mean 184.75 ms (previous same-shape diagnosis 592.48); atomic
c4 563.25 ms with two 2.39-second tails; independent c1/c4 313.23/503.32 ms.
Report: `_build/follow-demand-NhfIr0/REPORT-220.md`. No broad gate retired.

Continue investigating the atomic c4 tail: exact target vote was already
durable roughly two seconds before its phase discovery returned. Not slow
consensus or selected-entry reading. Scratch diagnostic module and local
privacy/lifecycle controls: `_build/endpoint-wait-GgNDbc/`. Fresh once-only
16-request atomic c4 capture `_build/follow-witness-y6jxSY/` completed its writes
and audits but FAILED diagnostic completeness (four collectors hit their own
heap cap). Failure/STOP retained. The scratch collector now retains encoded
rows instead of a second large JSON tree: old beam fails its 10,000-event
control; corrected beam passes under the same cap. All eight native sessions
were independently verified gone, production owners alive.

Fresh captures `_build/follow-witness-AETqek/` and `...-IHMWij/` both have all
eight complete native captures and 16/16 commits. The latter directly proves
the seconds-long phase wait: a live authenticated endpoint returns not_ready,
then the SAME request dials its retired historical port, never opens a link,
and waits 0.9–2.0 seconds before the normal next-peer walk can proceed.
`ENDPOINT-ANALYSIS.json` preserves exact IDs/ports/reasons. IHMWij also has three
11.4-second tails with long source submission waits: separately open, not
claimed fixed by the address-selection refinement.

Active next scope: `_build/endpoint-semantics-Ov3GJw/tree`, exact .220 base.
Any correlated application answer finishes address selection; peer readiness
belongs to the existing peer walk/wave, not an old-address retry. Transport
failure/malformed response still tries alternatives under the same deadline.
Dead response-ranking code removed; no authority/protocol/owner change.
Six new production-callback regression cases fail on unchanged .220 and pass
on the candidate; unavailable still cannot become authoritative absence.
Early manual harness include/path failures are retained, not counted as controls.
Proceed through full clean gates, freeze, one scope commit + label, deploy,
fresh same-shape witness. Main unrelated changes stay untouched.

.220 deployment/four-cell evidence is privately frozen (1,770 files, verified):
`_build/follow-demand-NhfIr0/hardware-freeze-rmqYVP/MANIFEST.json`, SHA
`42e32765e403579f58bc7efe9233649ce3e56ba76d149cf2599a15f4b767dc47`.
Do not publish private Nomad templates from that local archive.

## 07:07 UTC — .221 published/deployed; follow custody refinement underway

.221 implementation `167b05e3ffef188c6966ed7b6a8127d0081abdf1`, separate label
`e76f66a5795a5e2107a75de6d78a3e8a12ef7579`, both GitHub-readback verified.
Frozen 17/17 gates, EUnit 2815/0:
`_build/endpoint-semantics-Ov3GJw/freeze-v1/MANIFEST.json` SHA
`148d5c3e3aa5f37105c28fd3ed77a5188103903b45fda7ec8dbd622c78733ded`.
Registry digest `sha256:0d55d684ee755569e20c0e7ed7d07a0c1f82a98bdb8d12c6ed8a30d615753a19`;
coordinated image-only swap, exact 76 rows/ten identities preserved, healthy.
No wipe/cache retirement/config or sampler change. Deployment receipts:
`_build/deploy221-Knqt8p/`. One service-check invocation missed its output
label and stopped before checking anything; retained, corrected, no resubmit.

64/64 requests/audits pass, no 503/resubmission. Means/max milliseconds:
atomic c1 188.4/287.0 (`follow-witness-HVA0R0`), atomic c4 389.8/467.1
(`follow-witness-wFg8FA`), independent c1 293.0/348.1 (`follow-witness-DWYRg4`),
independent c4 486.8/703.3 (`follow-witness-75M2bc`). Ordinary config, native
finite worker/endpoint observation, all eight collectors closed each run.
No phase-query old-address retry remains in the witnessed path. Applied-vote
collection has a separate endpoint loop and still made a few short obsolete
address attempts; audit/consolidation remains queued, not falsely claimed fixed.

Active isolated next tree: `_build/follow-custody-VQIJBd/tree` (exact .221).
Last-follow withdrawal kills a custody holder, forcing derived reconstruction;
the real signed-history reproduction proves it (killed/one custody loss/zero
corruptions). Candidate withdraws future demand, permits the already-owned
finite handoff, retains pre-acquisition cancellation and original expiry, and
joins reattached demand to the same job. Net −3 production lines; 183 focused
tests green, three permanent cases and three deliberate-bug controls. Full
gates next; keep all failure logs and the migrated blocked-worker fixture's
unchanged unregister assertions. Do not touch unrelated user files.

## 07:24 UTC — .222 published; preserved-data deployment underway

Full exact-tree gates 17/17, EUnit 2818/0, all eight CT suites, xref,
Dialyzer, both releases, UI and both diffs. No full-gate rerun or flake.
Implementation `52e363370fe2747904d49ba9076e154f49557d15`, separate label
`ae1caec5f2d5c2b08c022655db6b1dc6e6b14ab4`, GitHub readback verified.
Freeze `_build/follow-custody-VQIJBd/freeze-v1/MANIFEST.json`, SHA
`be09cf5cc5ea6fec506bf979894d97f6daaada0431dbb5508ee37b8a0c41e22c`.
Deployment `_build/deploy222-Kbs156/`: image build/upload underway; exact
76-row/ten-identity prestop snapshot healthy. No fleet mutation yet.
Fresh four-cell witness prepared in `_build/custody-window-1ltQoi/`;
native observer is updated for the replaced callback and cleanup/redaction
control passes. Its first compile omitted an include path, failed before
arming anything, and is disclosed in COMPILE-TRIAGE.md.

.221 hardware archive verified: 1,684 files,
`_build/endpoint-semantics-Ov3GJw/hardware-freeze-UDKMFO/MANIFEST.json`, SHA
`0f498c158ee351edf78f8811afae05b1ed47b63d5e931d53d14fb6124446098f`.
Private Nomad templates stay local. New readonly decomposition at
`_build/latency-next-2qPAbt/DECOMPOSITION.json`: independent c4 source proof
has 136.9 ms invocation/authentication, 74.0 ms claim, 219.6 ms target result,
11.9 ms other proof; 44.4 ms outside proof is not a network measurement.
Shared-resource/non-overlap checks pin that partition. Receiver verification
and target result dominate; the four short applied-collector address retries
alone cannot explain it. No new optimization is claimed from this diagnosis.

## 07:50 UTC — .222 complete; deterministic page/address refinement

.222 is published and healthy on all ten nodes. Image-only swap, 76 namespace
rows/ten identities preserved exactly before workload; no wipe/config change.
The first post-start health read caught real startup recovery, retained and
resolved by observed progress before testing. Full report and private verified
hardware archive: `_build/custody-window-1ltQoi/REPORT-222.md`,
`hardware-freeze-RsLC5Y/MANIFEST.json` SHA
`defd6078436b0f27247b9e2313c1c2d0d221630434f7e3a6e5a2a66244f7973b`.
64/64 commits/audits, zero 503/custody loss/corruption. Means atomic c1/c4
183.49/1032.30 ms; independent c1/c4 296.99/438.35 ms. Do NOT claim an overall
latency win: four atomic tails reached 2.3–2.5 s. Native capture pins 1991 ms
of queued exact-reader residence behind one follow's failed 2001 ms page fetch;
original contact/reason was not captured. Separate route probe rov btr (actual
directory `follow-witness-rovbtr`) completes 16/16, all 239 fetches succeed;
does not close the original failure. Its range attributes were accidentally
omitted by the observer whitelist; no range-based claim is supported there.

Active isolated tree `_build/page-peer-WOn6aa/tree`, exact .222. Real signed
four-member current-view fixture proves the suffix downloader redials the same
peer's old address after an empty/invalid page; probes already group by peer.
Reuse that existing helper for downloads, preserving peer order/transport
fallback/all crypto and freshness checks. Baseline-v2 fails two exact-call
assertions and passes transport fallback; candidate passes all three. First
test version compared an in-memory projection with its checkpoint without
removing the deliberately omitted committee-view field; fixture failure kept.
Broad controls/full gates still pending. Main production tree remains .222.

## 08:20 UTC — .223 gated, frozen and published; deployment pending

Exact three-file scope published as `1c274354b0b639eae0aa3c3ff5019ca20b45c44b`,
label-only `.223` as `733c072c90935be5ad734def7a633c75c8e16205`; GitHub readback
verified. Freeze `_build/page-peer-WOn6aa/freeze-v1/MANIFEST.json` SHA
`226099ec62c4dc05c84a829e142a52c73ec9f801fdf01ed9ef28e36aa25b01a5` (105 files).
17/17 clean sequential gates, EUnit 2822/0, all eight CT suites, static checks,
both releases, UI and diffs. No full-gate rerun or flake; original/index/user-work
pins held throughout. Four permanent regressions, unchanged-source 3 fail/1
pass, two intentional bugs caught. Production delta +3 comment lines, no net
added executable lines, no new export/owner/cache/queue/format.

The real transport regression needed its current-view subscription established
before feed delivery; initial fixture mistakes are retained in DIAGNOSIS.md.
The final test runs actual page-owner grants/decoder and verifies next-peer
selection. All earlier authority/deadline/custody/fallback tests survive.
The label patch's first apply used an incorrect context and made no changes;
corrected against the actual two version lines before the label commit.

Deployment `_build/deploy223-g7Z8rp/`: image-only job prepared and inverse-
checked; image build/upload and pre-stop snapshots underway, no fleet mutation
yet. Fleet .222 live readback at 08:13:58 UTC: ten running, all explorer checks
passing, zero restarts. Next fresh four-cell witness prepared at
`_build/page-window-7GMgLG/`; finite observer records page peer/port/range,
counts/heights and typed error causes, privacy/lifecycle controls passed.
Preserve every STOP and previous capture. Page result routing is proven locally;
the original .222 two-second fetch's contact remains unattributed.

Yan is awake and asked for a status report; supplied the overnight summary and
latest mixed latency table, explicitly not claiming atomic tails solved.
He did not revoke ongoing deployment/testing authority.

## Morning follow-up — .223 deployed, measured, traces available

All ten nodes are now .223, image digest
`sha256:62372724713592699717926e0c761ac2324d18d33b3bf3d4006a9c5d61692c59`.
`_build/deploy223-g7Z8rp/` records the image-only guarded swap, 76 exact
pre/post namespace rows and ten identities, green post-workload runtime and
all services. No wipe/cache retirement/configuration change; no observer left
armed. Available logs: zero structured errors, 109 standing/startup warnings.

Four fresh 16-request cells at `_build/page-window-7GMgLG/`: 64/64 commit,
zero 503/resubmission. Atomic c1/c4 means 189.77/381.07 ms; independent c1/c4
304.02/566.45 ms. Atomic tails absent, independent c4 slower than .222, so
no general speedup or broad gate retirement. Original .222 two-second page
failure's address/error remains unproven. All 797 completed observed page
fetches succeed, no same-peer redial after page; two unterminated captured
calls remain explicit exclusions from completion claims.

All 64 request traces retrieved. .223 independent c4 partitions 566.45 ms into
124.03 invocation (113.34 remote-current nested), 90.25 source claim, 311.22
result wait, 15.03 other proof, 25.91 outside. Same-resource target-branch
join splits result wait into 248.88 application delivery/wait, 3.07 decode,
29.70 exact verification, 20.38 vote collection, 9.19 other intervals. Do not
call the 249 ms LAN latency: next join is target receive/admission -> exact
proposal/durable/reply, using existing native and Tempo evidence before any
instrumentation or behavior change. Five separate applied-vote address
fallbacks are short (8–18 ms); not proven client savings.

REPORT-223.md, MEASUREMENTS.json, DECOMPOSITION.json, TARGET-DECOMPOSITION.json
and all raw evidence frozen at `hardware-freeze-wzbrMp/MANIFEST.json`:
1074 files, SHA `ca969ca56acf45fb1e0968918719a336a174a6f84c5fc7bbe6abe2dcccdf9dd4`.
Private archive includes deployment templates; never publish it wholesale.
No independent Claude review claimed. Net production .218->.223 is +81 lines;
the reduction pass remains owed. Naming and experimental presentation work
preserved, no new normative interpretation. No active child tool sessions.

## Claude retrospective received and independently checked

Read `_build/CLAUDE-218-223-RETRO.md` fully. It approves all six scopes;
its independent gate table remains pending at this check. Verified the new
recommendation directly in all three transport implementations and recomputed
src/include debt: +888 since .201 (+81 since the .218 checkpoint).
Notes/required controls: `_build/223-retro-verification.md`.
The shared-address-walk simplification must preserve distinct verification,
bootstrap, tip-confirmation and private-cancellation contracts, not equate
transport success with valid evidence. .223 stays deployed; no new production
changes from this review check. Independent c4's 249 ms remote-application
bucket and 113 ms current-view bucket remain the measured optimization targets.

## .224 completed — architectural diagnosis replaces further optimization edits

Published implementation `2d42ee58e75d5fbe273f759c756a87c333ecf5a3`, label
`d84d0db9fa32d4ec7bbaf629b5e713b9ecbb2e17`, GitHub readback verified. One pure
peer-address walker replaces recursion; collector correlated non-evidence no
longer triggers another address of the same peer. Tip confirmation, bootstrap,
uncertainty and all verification authority retained. Seven files, -21 production
lines, debt +867 from .201. 25 new tests; 18/18 control outcomes; 17/17 clean
sequential gates, EUnit 2847/0. No full-suite flake. Freeze-v1 manifest SHA
`9dc25af4744b49cb73256a8e50904be87f58eead0d9c270a0e86849fdb3b31df`.

Fleet .224, image digest
`sha256:508b59ac5a247b181fad786216c371ed4ea6193322bedb58b42844b4caf787d7`.
Built from published archive. Exact 76 rows/ten identities retained, no wipe,
cache retirement or config change. First post-start home3 runtime check was
not healthy; retained. Later check and post-workload check healthy without
correction/restart; all ten nodes zero restarts. Available structured logs:
zero errors, 108 standing/startup warnings. All native sessions removed.

64/64 primary requests committed; atomic c1/c4 means 212.70/620.70 ms;
independent c1/c4 296.00/443.80 ms. **Not an overall improvement**: atomic c4
was 381.07 on .223. First four average 1156.77, remaining twelve 442.01;
do not discard first four or call warm-up proven. Independent same operation
counts before/after and no semantic redials in either witness prevent assigning
its faster result to .224. 874 completed successful page fetches, two unfinished
at capture cut; no custody/corruption. All64 requested traces retrieved; no
independent attempt denominator. Historical STOPs intact, no resubmission.

Yan challenged the seam-by-seam optimization process. Main agent acknowledged
the missing causal performance proof, stopped new optimization edits, and
reviewed full ownership/reply dependencies. Review and detailed evidence:
`_build/peer-walk-T6TXnJ/ARCHITECTURAL-PERFORMANCE-REVIEW.md`, `REPORT-224.md`,
`MEASUREMENTS.json`, source/target decomposition and slot-join outputs.
Slow atomic batch has 76-entry source suffix advancement (3490–3565) on target
replicas, not genesis replay. Why that prefix was missing and its complete
request ancestry are not proven. Independent endpoint calls join work owned
under other traces; missing transaction children are not idleness. .224 native
slot join safely failed absent same-node calibration, with true exit/log kept.

Next: deterministic mixed-lane/cached-prefix reproduction and exact application
ID/slot ownership join before selecting any production fix. Test replacement
against both lanes and covered/missing prefixes; no new owner/cache/poll or
weakened certificate. This review is diagnosis only, no next candidate exists.

Hardware/review evidence frozen locally (contains private deploy templates):
`_build/peer-walk-T6TXnJ/hardware-freeze-mj2nxU/MANIFEST.json`, 1162 files,
SHA `6a9bbb1f06bbff5ea1de0306b362ee83fb36f77d7f05856bacc7ecae9a488a40`.
Never publish wholesale. Original implementation freeze untouched. Claude's
.218–.223 review now has its independent all-green gate table; no Claude .224
review claimed. Protected files unchanged, pinned prefix verified. No active
tool session. User's architectural concern remains a requirement on next work,
not grounds to invent a rollback or unverified broad rewrite.

## 2026-09-22 — .224 causal rollback/cleanup investigation

Diagnosis only; no production edit, new release, goal submission or fleet reset.
Report: `_build/causal224-BJrWzL/REPORT.md`. Frozen manifest: 222 files,
SHA `babb19e7827c6228c89d37241a9f54ce27780683321785937ab08758d05ccbb6`.
Contains private raw ledger envelopes; do not upload wholesale.

The formerly missing ancestry is now joined: target block1732 validates source
Vote3565; replicas4/5/6 last fetched through3489 in the preceding atomic cell,
then neither independent cell fetched source pages there. They acquire exactly
3490–3565 (76 entries, 2.413MB), taking647–779ms. Replica2 validates in28ms then
waits758ms for finality. Owner delivery overhead after acquisition <1.6ms,
queue-to-worker <0.2ms: not a lost wake for this block. Per-replica acquisition
partition: page fetch (including decode)421–502ms, verification202–256ms,
append12–27ms, checkpoint5–6ms. No historical cross-host clock subtraction.

Controlled old/new test:16 isolated ABBA runs, identical signed missing76-entry
fixture, one/four callers. Both .223/.224 fetch once, covered reads fetch zero,
wrong-phase refusal preserved. One-voter fixture transport supplies decoded
artifacts: not a full mixed-lane consensus or wire-cost reproduction. Real-page
profile separately captures363 signature checks, all distinct within each page;
decode median84.546ms alone,174.101ms at four callers on local two-scheduler VM.
The .219 dedup is working; these local timings do not assign hardware wait time.

Keep .224: no evidence that reverting removes this dependency. Do not call all
regression questions closed: last12 atomic mean442.01 vs386.75ms remains an
unequal-state comparison, and page wait/decode/completion split is not captured
for this historical validator. Request13 lacks an applied stage edge; preserve
its denominator and named exclusion. Independent improvement is not credited to
the cleanup either. Next useful diagnosis is the bounded page substage split on
the same missing-prefix input, not another broad campaign or speculative patch.

Full .224 production diff/runtime callers audited; old per-peer recursion gone,
no uncommitted production attempts to remove. Scratch variants/failures remain
evidence, not shipped paths. Source/header diff empty. All76 captured entry and
11 causal trace input hashes reverified. Closing Nomad checks:8 witness-bound
allocations running with0 restarts (not a new full application-health campaign).
Failed direct captures (CLI integer-array expansion), parser missing-edge errors
and profiler module-load failure retained and explained. No active tool session
or production candidate from this diagnosis.

## 2026-09-22 — requested solution plan, no implementation

Yan requested a regression-conscious plan reusing components and gproc.
Draft: `doc/history-demand-performance-plan.md` (255 lines), SHA-256
`bc58d40bcf68d4d16c9752aa32d17e4ec9e27714a1499df2b3750eba966f46b6`.
Read the settled history/coordination architecture and complete residency
contract; checked current owner, follow, feed, publication and recovery seams.

Sequence: bounded same-input page wait/decode/verification attribution; select
one demonstrated shared-pipeline reduction; consider earlier progress demand
only if tied to an existing real operation lifetime and useful overlap is
measured. Do not change passive current-view watches to perpetual downloads.
Participant recovery starts only after deadline, so no imaginary existing
participant coordinator may be reused early; the optional demand-lifetime
table is an explicit design checkpoint, not a new prefetch/recovery engine.

Both lane transitions, covered/missing prefixes, replica work counts, deadlines,
custody loss, bad evidence, current freshness, reads and idle resource use are
required regression controls. No cost-shifting speedup or same-page signature
dedup claim (363 inputs are already distinct). Replace superseded mechanisms
in the same scope; retain failed evidence. No source, index, protected spec,
fleet or release change. New-doc whitespace check produced no diagnostics;
`git diff --no-index --check` exits1 for new-file difference, not a test failure.

## 2026-09-22 — requested plan self-review

Review: `_build/history-plan-review-gyoEOl/REVIEW.md`; original saved there as
`PLAN-v1.md`. Revised plan SHA-256:
`af1d14d5d67ad7002bf4d12aef855cb2994b35c86b7aa4e6bec46addc76f799b`.
Not an independent Claude approval. Two concrete draft problems corrected:
progress follows chase future tips rather than stop at an operation's required
height; refused references must not forbid publishing sound acquired history.
Covered-prefix and coalescing/resource controls also narrowed to their actual
contracts. Step A ready; B requires a measured cause and replacement/deletion
map; C deferred until bounded lifetime/overlap is demonstrated without another
engine. No source, test, index, protected-spec or fleet changes; no full gates
for this documentation-only review.

## 2026-09-22 — history-pipeline implementation in progress

Work directory: `_build/history-pipeline-fWQfgS`. Exact retained-page profile
and full prior manifest verified. Decode has 363 checks; finality-only profiling
retains 234 checks on 76 entries (committee inferred for profiling ONLY, not
historical membership proof). Full page transport partition remains open.

Yan raised notification side effects. Deterministic owner/gproc tests exposed
covered-height re-fetches in four event paths; generic digests already filter.
The candidate shares one freshness/notification transition. First v1 suppressed
necessary same-height reconnection and failed an existing test: retained in
notices-existing-v1. v2 preserves new-registration availability through existing
registration state; duplicates/lower heights do not start a new follow job.
No new owner, state field, queue or timer. All 170 history-owner tests pass;
full gates and deliberate-bug controls pending. No deployment or latency claim.

Notification scope complete: 17/17 clean sequential gates (EUnit 2852/0),
11 matched control steps, frozen in `freeze-notices-v1`, committed as
`14cf3239` with separate .225 label `f6c08127`. Not yet deployed.

Separate measured block-validation scope: canonical payload encoded twice by
valid_block_view plus payload-size checking. Reuse the existing bounded
constructor, delete the duplicate encoder and size pass. Scratch ABBA on the
same 76 retained entries: 658→329 transaction encodes, 234→231 signature calls,
with the identical set of 231 signature inputs; all bytes unchanged. This is
finality-stage profiling only, not historical-authority proof or fleet latency.
306 focused ledger/catchup/consensus tests pass. Full gates next. No new cache,
receipt, owner, queue, polling or format. The initial focused runner named a
nonexistent module; retained and triaged separately from production failures.

## 2026-09-22 — .225/.226 published and measured

Both scopes are on GitHub through `45e3e130` and fleet .226. Block scope
`9f1947d7` passed 17/17 clean gates (2854 EUnit cases); its exact freeze is
`_build/history-pipeline-fWQfgS/freeze-block-v1`. Combined production delta −10.
Report: `_build/history-pipeline-fWQfgS/REPORT-226.md`.
Deployment: `_build/deploy226-LJNFId`; 76 rows / 10 identities retained.
Initial startup health snapshot failed during reconstruction, preserved;
second snapshot passed before any witness writes. Post-witness fleet healthy.
64/64 multiwrites committed. Means: atomic c1/c4 192/571 ms; independent
c1/c4 302/436 ms. No errors in captured logs; 81 known-category warnings.
No matched A/B or broad performance-gate claim. Cold atomic target slot1808
is joined by hash/validator PID: replicas4/5/6 need 74 real source entries,
532/930/643 ms exact acquisition; owner overhead under1.1 ms. Node5's valid
worker result lacks owner/durable boundaries, explicitly excluded. First
atomic cohort remains in headline. Wider performance acceptance and bounded
earlier-demand design remain open; no new production changes queued silently.

## 2026-09-22 — performance pass closed; agent work next

Yan requested triage of the two remaining findings, not another speculative
optimization. Closure: `_build/history-pipeline-fWQfgS/PERFORMANCE-PASS-CLOSURE.md`.
No demonstrated safety/availability blocker: keep .226 unchanged. Record
PERF-SOURCE-SUFFIX-226 (on-demand history gap / bounded acquisition work) and
PERF-REPLICA-DRIVERS-226 (redundant committee drivers, latency effect unproven)
for future measured scopes. Timers for failure detection are not forbidden;
readiness polling is. gproc is not remote partition detection.

Claude's code approval is read; its independent gate table is still pending
in `_build/CLAUDE-224-226-RETRO.md`. Existing exact-tree gates and 64/64 witness
remain the release evidence, not a broad performance acceptance. Combined
.224-.226 production delta verified as -31. No production/test/index/fleet
change this turn. Next is the current agent-plan implementation inventory and
durable-delivery/hosting prerequisites, not legacy per-namespace outbox code or
committee-wide agent sends. Preserve Yan's dirty agent and protected documents.


## 2026-09-24 — generic hosting deployed through .234

Core hosted-agent execution, event/reaction exchange and automatic relocation are
implemented. GitHub `claude/next`: implementation `f5467071`, separate .234 label
`f7c11177`; all ten Nomad nodes verified on `0.7.234`. Eight pinned predicate
BEAMs remain byte-identical to .233. Existing ledgers, node identities and vaults
were retained. Final capture: original 76 anchored replicas/committees plus eight
agent replicas, all 84 healthy/applied, queues empty and source views ready.

Hardware witness: two agents exchange events without accumulating sender request
facts; receiver-runtime restart succeeds; physical host suspension leads to
ontology-policy relocation A→C at epoch2, new key/old-key revocation, restored
state and new work while A remains suspended. Same-disk A restart and old-key
rejection pass. All four answers survive the .234 full-fleet restart. The same
real-QUIC CT witness additionally covers graceful and abrupt VM termination.
No claim of physical power-cut or full partition/live-stale-process coverage.

Final actual Fable review approved the exact correction after Codex reproduced
and fixed two membership-boundary evidence defects: separate the old block
certifiers from post-slot read authority, and carry both eras in a bounded
published-prefix handoff. .234 production delta +8; combined .231–.234 delta
from .230 +26. Required pre-publication gates all pass: EUnit 2990/0, 129 cases
in 11 CT suites, xref, Dialyzer, both release profiles, UI build/lint, diff checks.
The superseded interrupted batch and failed measurements remain intact.

Post-deployment agent readback passes on A/B/C/D. The first general health capture
caught history reconstruction and failed; a diagnostic read established completed
replay, then the separately labelled final capture passed. Final captured logs:
55 known warnings, no error-level records; cloud observer advertisement-author
warnings remain pre-existing. No uncertain signed request was resubmitted.

Closure and remaining boundaries:
`_build/agent-overnight-20260924/OVERNIGHT-CLOSURE.md`,
`_build/agent-overnight-20260924/ACCEPTANCE-COVERAGE.md`, and hash-bound
`_build/agent-overnight-20260924/EVIDENCE.json`.
Broader hardware failure matrix and repeat-failover deployment policy remain
before declaring every plan acceptance item closed; FIPA conversation ontologies
are subsequent product work. Missed live events are not automatically replayed.
Existing sampled agent traces are retained, not a throughput/latency benchmark;
unrelated performance questions remain deferred. User/Claude changes preserved;
this entry only appends to the existing continuity file.


## 2026-09-24 partition / stale-process checking

Evidence: `_build/agent-partition-20260924/CLOSURE.md` and `HARDWARE-PLAN.md`.
Fleet remains .234; no network fault, deployment, signed fleet write or purge
was performed. Pre-existing user changes preserved.

Added same-VM SIGSTOP/SIGCONT return to the existing four-real-QUIC failover
suite. Its original graceful-loss case exposed report-renewal contention:
production reducer replay reproduced eight conflict_retry rejections and no
epoch advance at the 90-second deadline. Fable consultation independently
confirmed this; its suggestion to cap total conflicts at observers-minus-one
was rejected as too strong. Failed runs and exact replay evidence retained.

Final local fix: five Prolog lines skip redundant unexpired same-kind reports
after the existing sequence/custody checks. Changed kind, expiry and missing
custody retain the submission path. Final focused checks: 31 EUnit tests and
all three failover CT cases pass on unchanged frozen sources; no full release
gate or final implementation review has run. Actual model used for the design
consultation: claude-fable-5-1. Changes remain uncommitted and undeployed.

Own changed files: priv/ontologies/agent_recovery_policy.pl,
doc/hosted-agent-runtime.md, test/quod_agent_actions_tests.erl,
test/quod_agent_failover_SUITE.erl, and new
test/quod_agent_failover_SUITE_data/suspend_peer.py. Production +5, docs +8,
tests +146 net lines. The test controller requires Linux pidfds and Python 3.

Next: complete the applicable review/release work for this policy correction,
then assemble the separately labelled hardware fixture and namespace-scoped UDP
fault controller described in HARDWARE-PLAN.md. Existing instantiated policies
need ordinary signed Prolog updates; changing the file alone is insufficient.
The old campaign's recovery grants are pinned to A/epoch1, while its sender is
now C/epoch2. Do not silently reuse/reset it. Namespace nft syntax preflight
passed, no rules installed. QUIC uses ephemeral ports too. Residual unavailable-
custody contention and the broader failure matrix are explicitly not closed.


## 2026-09-24 — .235 hardware partition acceptance, outcome recovery follow-up

Committed/pushed implementation `4594de42` and separate .235 label `281a52e`.
All ten Nomad nodes are deployed with ledgers, identities and vaults retained.
Full frozen release gates and Fable review passed. See
`_build/agent-partition-release-20260924/CLOSURE.md` and its bound receipts.

Hardware 1+3 passed: A stayed alive but isolated, C hosted epoch 2 and did
work, the old key was refused during isolation, and same-VM healing retired
the stale child without failback. The 13.839 seconds is the fault window,
not failover latency. No-quorum assignment safety also passed: all four kept
A at epoch 1. Explicit heals and a separately labelled corrected post-heal
binding/message check passed. Two harness failures are retained: a swallowed
collection request and an invalid ledger-height/runtime-revision barrier.
No network faults remain; temporary modules are removed. Final health passes
on ten nodes and 108 replicas, with empty measured queues and ready views and
services. Logs have zero errors and 556 warnings. Persistent directory
renewals and 24 reconciled system runner-kill warnings are not claimed fixed.

Two original observer reports remain pending after healing, one in each
no-quorum campaign; two others committed. Preserve all IDs. Do not clear
pending rows or replace uncertain requests with fresh goals. Yan wants
architectural fixes if needed. Follow-up directory:
`_build/agent-outcome-recovery-20260924/`. It contains frozen .235 sources,
a read-only Fable consultation and a focused red test,
`expired_custody_exact_claim_redelivery_test`, under `repro/`. The real claim
endpoint and Prolog pending admission do not reacquire submission ownership
after the ambiguous custody-expiry response. This fixture holds the consensus
owner interface; it is not yet a real-QUIC correction witness.

Critical existing authority: `doc/multiwrite-architecture.md`,
R4-UNCERTAIN-CLAIM-DELIVERY-01, permits byte-identical durable claim redelivery
on genuine progress with the same operation/application identity. Verify the
target author-sequence/signature/custody lifecycle; do not guess, add retry
timers or introduce another executor. Fable advice remains consultative.
No follow-up production change is committed yet.

All 22 user/Claude files were hash-preserved before this append. Preserve the
original prefix and all other dirty files.

Fable consultation completed (exit 0, claude-fable-5-1, frozen sources unchanged).
Diagnosis confirmed, patch sketch requires corrections around resumed-attempt
refusal versus earlier in-flight commit, caller deadlines and source/target
signatures. Clean detached implementation worktree exists at
`_build/agent-outcome-recovery-20260924/work`; no production edits yet.
Astra High is recommended for this architectural correction. Detailed evidence
and next-step constraints: `_build/agent-outcome-recovery-20260924/HANDOFF.md`.


## 2026-09-24 — pending claim delivery correction in progress

Yan confirmed the model switch and asked to continue. Implementation is isolated
in `_build/agent-outcome-recovery-20260924/work` at base `281a52e`; nothing from
this follow-up is committed, pushed or deployed yet. Main user/Claude files and
the original WIP prefix remain hash-preserved (`USER-PRESERVATION.json`).

The existing Prolog admission now distinguishes durable pending outcomes from
live append ownership, only resuming ordinary applications of committed claims.
Append correlation retains new/pending admission knowledge, so a refused resumed
attempt cannot erase an earlier uncertain result. Simplex coalesces a live exact
application before signing, preserving its envelope and deadline. Shared parking
removes repeated setup. No new owner, timer, executor, durable format or goal.
Actual production delta is approximately +41 lines, plus test-only access and
expanded regression coverage; measure the final delta after review.

All 371 focused endpoint/Prolog/Simplex/outcome tests passed (`focused-v4`), then
23 endpoint tests passed with an exact timer-preservation assertion (`focused-v5`).
Real-QUIC test fixture failures are retained and triaged. The no-quorum/heal case
also passes on .235: old proposals can still complete, so it is only a late-commit
safety control. The stronger all-target-namespace restart case fails on .235 at
the original operation's completion deadline (`quic-baseline-v2`); the patched
positive controls are running under `quic-v5`. All ledgers are retained and the
source claim owner stays alive. No signed goal or source claim is replaced.

Fable (`claude-fable-5-1`, verified actual init model) is reviewing the frozen
five-file implementation under `implementation-review/`. Its response is
consultative and must be independently checked. Full frozen release gates and
actual fleet follow-up remain before publication/deployment. Production fleet
stays .235, with no new fleet fault or purge. See `IMPLEMENTATION.md` for details.


## 2026-09-24 — .236 durable claim recovery deployed and verified

Implementation `956994d208eee878df2c6d70128b8fe1c9aeae07`, separate release label
`9a9d321e3c4d73d371b782b0ef33e0543a136f44`, pushed to `claude/next`.
All ten Nomad nodes run `0.7.236`; ledgers retained, no purge. Image uses the
production profile, with the historical `-c4p1` tag suffix; eight pinned predicate
BEAMs match .235 exactly.

The correction resumes the existing deterministic target application when its
append owner ended, preserves pending uncertainty on refusal, reuses live custody
and its deadline, and joins a known commit until ordered apply. Fable's concrete
commit-before-apply race was reproduced and fixed. Equivalent valid finality
certificates reuse the same custody through the existing immutable-reference
comparison. All parking, including effect handoff, uses one helper. Net production
growth is 40 lines; no new process, owner, retry timer, source submission or format.
Fable's final source review has no blockers; Codex verified its findings and the
source-claim versus target-author-envelope distinction independently.

All 21 clean sequential gates passed: 2,996 EUnit + 132 CT tests, xref, Dialyzer,
production/diagnostic builds, UI build/lint and diff checks. The new race control
failed before the fix; the all-target-owner restart case fails on .235 and passes
on the corrected implementation. Original failed fixture runs and the intentionally
stopped first release campaign remain intact.

Hardware: the exact two previously stranded operations now have terminal source
receipts and rejected target outcomes (`conflict_retry`, heights 23 and 19), because
their old reads were superseded. They were not replaced or re-proved. The other two
recorded operations remain committed at height 11. Each of all four original target
applications appears exactly once in its target ledger. This proves uncertainty
resolved; it does not claim the obsolete updates were successfully applied.

The first strict fleet snapshot failed during startup replay and is retained with
STOP.json. Read-only diagnosis showed history progressing to the original 4075
frontier and the temporarily missing namespace appearing without intervention.
A separately labelled unchanged strict capture then passed all 108 retained replicas:
identities/committees/catalogues preserved, healthy runtimes, ready source views,
empty queues and caught-up histories. An additional census across 32 agent replicas
found exactly eight live agent instances, with current Prolog host/epoch/key bindings
and no duplicates. Its first harness query incorrectly treated agent_hosted/4 as an
enumerator; that failed evidence and diagnosis remain, and the corrected query first
enumerates agent_host/4 as production does.

Final captured logs have zero error-level records and 89 warning records: 49 known
directory-author-unavailable, 36 startup no-contact, two startup node-policy projection
timeouts and two associated reconciliation warnings. Final healthy runtime/catalogue
checks show those startup projections recovered; no claim that the existing directory
warning issue is fixed. Fable's optional expired-caller commit/apply-gap optimization
remains deferred; no duplicate target ledger item was observed in this acceptance.

Evidence and closure: `_build/agent-outcome-release-20260924-v2/CLOSURE.md` and
`FINAL-EVIDENCE.json`. All 21 other protected user/Claude files are byte-identical;
this WIP file was append-only. No active fleet fault or further release blocker.
Sol High is sufficient for the current follow-up; flag any new architectural issue.

## 2026-09-24 — repository cleanup and system-ontology confirmation

The naming and licence ontology sources and their tests were already tracked.
The retained 0.7.236 health evidence confirms exact root catalogue entries for
`quod:names` (`ac1293...`) and `quod:licence` (`da579e...`), and all ten nodes
host both anchored histories. `quod:lens`, `quod:measure`, and `quod:present`
are registered and hosted the same way. No static Erlang catalogue was added:
the committed root `system_ontology/2` rows remain the only post-bootstrap
authority for system status.

## 2026-09-25 — initial personal lobby, model toolkit and shared console

The feature branch now implements a private lobby projection with one classed
Prolog-console device. Pure Prolog recipes compile boxes, planes, spheres,
cylinders and transform groups; helpers align bounding-box faces and describe
integer-permille PBR surfaces. The client reconciles parent-relative occurrences
without recreating unchanged meshes/materials. Interactive subjects retain exact
ontology anchors; signed result bindings now preserve full bytes, while signed
request spelling remains unchanged.

The world and Explorer share one React build, signing session and proof console;
the duplicate standalone client shell/build/assets are removed. Ontology-derived
menu/form descriptors open the focused console. Closing it retains draft and
live proof; switching actor/session/target retires that console. Goal entry accepts
an omitted full stop and trailing comments through the shared source helper.

Focused evidence includes actual signed reads across five isolated ontology
owners, wrong-anchor and other-actor rejection, and restoration of the same lobby
from its ledger. Browser acceptance on a real isolated HTTPS node covers 3D ray
selection, projected menu/form, bindings, Next/Stop, discarded staged writes,
explicit committed writes, retained draft/live cursor, two representations,
operation without WebGL and same-namespace actor-switch cursor cleanup. Earlier
failed runs remain recorded, including the missing Babylon ray-picking import
that the browser test found. The renderer regression now checks a real ray hit.

Source contract and remaining work: `doc/client-world-direction.md` section 11.8.
This is not automatic lobby provisioning, an ontology editor or completed VR
interaction. The new ontology files are founding inputs, not already activated
system ontologies. Textures/assets/bones/particles, subscribed projections,
round-touchpad menus and a headset workspace remain follow-ups. The edition
recipe is currently a structure view, not a model-editing tool. The historical
`quod:present` namespace has not been renamed. Existing Explorer remote-target
anchor enforcement is not expanded by this work; the focused console uses the
selected actor's exact signed origin.

Validation, frozen-tree review and publication evidence are retained under
`_build/lobby-toolkit-20260925/` and its `release-v1/` campaign. No Claude review
was initiated. This work uses isolated test ledgers; the production fleet remains
.236, with no purge or fleet rollout for these unprovisioned lobby sources.


### Lobby checkpoint validation and provisioning simplification

All 23 clean sequential gates passed on the frozen executable tree: 3,021 EUnit,
132 CT and 39 client tests, xref, Dialyzer, production/diagnostic releases, UI
build/lint and diff checks. Clean UI output reproduced the frozen asset bytes.
Two additional current suites also passed (namespace admission: 3; naming: 9),
for 144 CT cases overall. Browser acceptance and the 16 focused lobby/presentation
checks are retained separately. No production source changed during validation.

A separately labelled integration experiment also passed: a source pending fact
can be consumed and replaced by the prepared exact lobby reference in the same
ordinary atomic group that stages root's creation effect. Root stays effect-only.
A second invocation after known completion fails before another creation. The
preferred provisioning direction in section 11.3 now uses that existing path,
removing the proposed creation-then-link handoff. Unknown-admission recovery,
executor grants and permanent loss of local effect custody still require work;
the experiment does not authorize uncertain-effect resubmission. Its first
compiler invocation failed because erlc takes one -pa path per option; that log
is retained alongside the corrected compile and successful execution.

The final architecture/closure documentation is a reviewed docs-only addition to
the gated tree, recorded in `release-v1/FINAL-FREEZE.json`; executable sources,
tests and assets are unchanged. Production source delta is +878/-604, net +274
lines, after removing the duplicate standalone client shell. Browser preview
processes are stopped; no active test fault or fleet change remains.


## 2026-09-25 — open signup, personal-lobby creation and view errors

Normal Create account uses a scoped key-bound applicant in `quod:signup`, then
ordinary signed profile/lobby actions. Root delegates complete creation options
to anchored Prolog policies and restricts administrative writes. The profile's
pending requirement, exact lobby reference and creation effect share one atomic
transition; that transition also consumes the temporary signup receipt.
Encrypted account exports retain the exact profile reference. Recovery resolves
original signed operations and exposes their already-durable named bindings;
the browser journal atomically advances between the two actions.

This is browser-led provisioning, not autonomous offline convergence. Uncertain
lifecycle writes are not resubmitted. Section 11.9 of client-world-direction
records the implementation and its remaining boundaries.

Missing licence/lens catalogue entries disable that menu option with a reason.
Renderer startup errors are exposed, and the console remains usable without
WebGL. Lobby materials now use terracotta, green, ivory and amber independently
of the interface palette; Yan accepted them provisionally.

Pre-deployment review found that earlier FIPA work changed the pinned agent
predicate module. Its deployed source is restored exactly; the two continuation
bridges now live in the explicit `quod_agent_work_predicates` extension, with no
new process or scheduler. The old presentation ontology has no bridge imports;
new lobbies will pin a freshly founded `quod:present:models` vocabulary. Existing
presentation/licence/lens histories are retained. System activation was rehearsed
through ordinary lifecycle actions and atomic root-policy replacement.

Focused release verification: 45 client tests, 202 Erlang tests, xref, UI
build/lint and production release. Browser checks cover two separate accounts,
reload, encrypted export/import and operation without WebGL. The full core suites
were not rerun, per Yan's explicit instruction; unchanged runtime/consensus work
was already gated at 4f8b7c8. Source review and exact logs are under
`_build/lobby-provisioning-20260925/release-v1/`; harness failures are retained
and diagnosed there. Production-source delta: +575/-124, net +451,
for enrollment/recovery and explicit immutable bridge separation. No duplicate
executor, polling loop or parallel domain store was added.

The pre-rollout cluster capture is healthy with 108 retained namespace replicas.
Image publication, exact pinned-BEAM comparison, activation and hardware browser
acceptance are the remaining release steps at this checkpoint.


## 2026-09-25 — .237 clean container rollout; hardware acceptance incomplete

Implementation 54ca17a and release label fa13360 are pushed on
`feature/fipa-request-transactions`. Image `0.7.237-c4p1` uses the production
profile and preserves all eight historically pinned predicate BEAMs exactly.
All ten .236 allocations were stopped before ten .237 replacements started.
After cold replay, all 108 previous replicas retained their anchors, committees
and history frontiers; initial premature captures are retained as failures.

Yan requested no obsolete presentation left active. The former planned
`quod:present:models` was therefore not created. The old `quod:present` catalogue
and founder-hosting entries were retired through Prolog transactions. After
all ten replicas stopped, only that ontology's validated height-one directories
were archived beside their original locations. Current `quod:present`, GUI,
lobby and signup were founded and registered; unrelated histories are retained.
Eight home nodes serve them. Both cloud nodes have the current root catalogue
but remain waiting for four new routes; this is not a completed fleet activation.

Hardware browser acceptance failed. One signup reached its newly created
profile before readiness and lobby execution returned `ontology_rebuilding`.
A subsequent independent signup completed both creation actions, but its first
scene read returned `proof_unavailable`; a later read of the same lobby returns
the scene. Neither failure was hidden or counted as a pass.

Inspection also found that profile/lobby creation does not commit node-actor
`hosts_ontology/4` declarations. Existing creation effects are not durable
hosting authority. Correct the domain composition using the existing node
hosting projection, and trace/wait on existing readiness notifications rather
than introducing sleeps, polling or uncertain-operation retries. No production
fix has been made for these issues; Yan explicitly requested no ugly workaround.
Release acceptance remains incomplete. Evidence and the exact stop state:
`_build/lobby-provisioning-20260925/release-v1/deployment/ACCEPTANCE-STOP.md`,
`hardware-browser-v1/` and `hardware-browser-v2/`.


## 2026-09-25 — ordinary Prolog hosting convenience action

Added `host_ontology(NodeRef, Namespace, Anchor, Visibility)` to the existing
node ontology source. It records `hosts_ontology/4` through an ordinary action,
without duplicate facts or implicit anchor/visibility replacement. Delegation
uses node-owned `can_host_ontology/5` policy through the existing entry ACL;
raw assertions remain administrative. Creation and hosting compose in one
signed transaction and use the unchanged namespace manager for recovery.

Moved generated node ACL/hosting-handler Prolog out of Erlang strings and into
`node_execution.pl`; founding now supplies `node_ontology/1` with the existing
instance/key facts. No predicate import, runtime declaration meaning, executor,
queue or runtime storage changed. Production delta is +49/-23, net +26 lines.
The actor architecture documents invocation, permissions and installation.

Focused tests: 61 passed, plus xref. The initial failed attempt and its diagnosis
are retained under `_build/prolog-hosting-20260925/REVIEW.md`. Tests cover signed
atomic creation/hosting, delegated permission/revocation, duplicate prevention,
conflicts, rollback and recovery with cleared in-memory desired state. No full
suite or browser campaign repeated.

This generic action has not been installed into the deployed node ontologies.
Automatic signup still needs an explicit host-selection rule and its node-owned
delegation; it is not inferred from the browser endpoint. The .237 browser and
cloud-discovery acceptance failures recorded above remain unresolved.


## 2026-09-25 — signup and lobby creation include durable hosting

Signup now chooses its host through explicit `signup_host/1` Prolog policy.
The selected node delegates to the exact signup ontology through
`ontology_hosting_policy/2`. Its ordinary `request_ontology_hosting/5` binds the
requester at entry and proves foreign policy inside the transaction, then calls
the shared `host_ontology/4`. Admission remains strictly local.

Profile creation and lobby creation each commit their exact discoverable hosting
fact with the existing domain transition. Enrollment permission ends when the
lobby transaction consumes the receipt. The profile's existing entry ACL was
also corrected to be re-provable without an external predicate; exact signed
identity validation and owner checks remain in the existing boundaries.

Focused verification: 61 tests passed and xref passed. Negative checks cover
unrelated hosting, principal substitution, receipt revocation and full rollback
when hosting is denied. The real content-tree restart test clears in-memory
hosting/storage maps and restores both signup profiles and their lobbies from
committed hosting facts. No Erlang production change or pinned module change.
Production delta +43/-2, net +41 lines. Evidence and earlier failed attempts are
retained in `_build/signup-hosting-20260925/REVIEW.md`.

Cluster activation remains next. A fresh read-only inspection confirms both
cloud nodes still await the four current system routes. Initial-read readiness
also remains distinct from durable hosting and needs acceptance verification.

## 2026-09-25 — hosting activation; resource-budget correction takes priority

Implementation d2ee3eb is committed and pushed. The generic hosting clauses were
installed through ordinary transactions in all eight existing home node actors.
Both cloud nodes currently have no active node-actor principal. Signup policy and
its profile template were updated on the founder without deleting histories.
The selected host is quod:arch203-node-6; both cloud system-route gaps persist.

The initial bulk signup-policy update was rejected before execution with
`{too_large,transcript}`. The node's policy delegation had already committed as
a separate preceding operation. Signup was subsequently disabled, updated in
bounded ordinary transactions, and re-enabled at height 16. Evidence is under
`_build/signup-hosting-20260925/deployment-v1/`; no uncertain write was retried.

Hardware browser v1 then committed a new profile and its hosting declaration,
but immediate profile read/provisioning requests returned signed_target_unavailable.
The account export and IndexedDB journal were preserved in that campaign. This
is a failed acceptance, not a release pass. An unverified readiness patch was
saved as `_build/signup-hosting-20260925/readiness-unverified.patch` and removed
from the working tree when Yan redirected priority to resource limits.

Yan explicitly reiterated that hardcoded resource limits are unacceptable. The
standing engineering rule is now recorded in AGENTS.md. Do not work around this
by splitting domain work or just raising constants. A read-only measurement of
the rejected bulk update found 15,927 canonical goal bytes: the first failed
check was actually the 8 KiB nested-goal bound in charge_transcript, which reports
the same error as the separate 12 KiB transcript bound. The earlier explanation
naming only the transcript bound was corrected. A 24 KiB plan bound and other
linked codec/validation limits also exist. These are explicitly prescribed by
the old distributed-proof-plan section 4.2, which conflicts with Yan's reiterated
rule and needs a coordinated revision, not an isolated constant change.

Next priority: define and implement authoritative Prolog resource budgets across
admission, sealing, validation and transport, keeping historical verification
independent of current mutable quotas and preserving pinned bridge identities.
Do not change only the producer: decoder/validator/replay acceptance must remain
coherent. Runtime readiness and final fleet/browser acceptance remain open.
No resource-limit code change has yet been made.
