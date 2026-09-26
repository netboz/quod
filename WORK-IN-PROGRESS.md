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

## 2026-09-25 — authorized temporary 128 KiB proof allowances

Yan explicitly requested increasing the blocking limits to at least 128 Ko for
now. This is a temporary exception to the resource-policy refactor priority.
Nested and top-level goals, scope transcripts and signed local-plan envelopes
now have 128 KiB component ceilings. Browser request limits match the server;
derived request and scope envelopes increase with their existing formulas.
The shared producer/decoder/validator constants remain coherent. Aggregate
transaction/block limits and other resource budgets are unchanged; a component
at its exact ceiling is still subject to enclosing-envelope overhead.

Focused verification: 165 Erlang tests and all 45 client tests passed. A new
regression then passed with the 48 DTX tests: a 32 KiB payload goes through real
proof execution, signing/sealing into a plan over 64 KiB, verification and exact
wire roundtrip. Existing boundary and boundary+1 checks pass at the new values.
No full suite was run. Evidence: `_build/proof-budget-128k-20260925/`.
Production line delta is +6/-6, net zero; no executor or protocol format added.
This source change is not deployed yet. Readiness and cloud route acceptance
remain open as recorded above; Prolog-governed budgets remain deferred work.

## 2026-09-25 — .238 deployed; 128 KiB allowances verified on hardware

Source d9f5596, rebuilt browser assets 8a06d32 and label-only e73c805 are pushed.
Production image `192.168.1.11:5000/quod:0.7.238-c4p1` is published and running
on all ten replacement allocations. All ten .237 tasks were confirmed dead
before .238 started; no ledgers, keys or operation journals were erased. All
eight historically pinned predicate BEAMs match .236/.237 byte for byte.

Before restart, the three still-running profile/lobby test ontologies created
by the earlier incomplete signup path received ordinary node hosting facts on
their existing founder. The newer test profile already had its hosting fact.
The post-recovery capture verifies all 134 original namespace replicas with
unchanged genesis anchors and committees and nonregressing history frontiers.
There are now 138 running replicas: cloud[1] also recovered the four newer
system ontologies. All ten nodes pass all four service checks. The first
45-second recovery wait expired on one source replica; its later successful
recovery and the initial evidence are both retained.

Every deployed node reports .238 and accepts a durable goal larger than the old
8 KiB allowance. A real signed request of 82,551 bytes committed through the
ordinary node-agent ingress and its exact test fact was removed and verified
absent. The initial probe had a harness syntax error before execution; cleanup
then encountered unsupported retractall/1 and was completed with retract/1.
Neither error caused an uncertain operation to be resubmitted. The new browser
bundle/login entry passes the smoke test at https://192.168.1.10:20526/.

Existing unresolved work: cloud[0] still lacks the four newer system routes;
initial signup/profile/lobby readiness and the Prolog resource-policy refactor
remain open. This release does not claim those issues fixed. No full test suite
was repeated. Evidence, image digest, retained failures and final checks:
`_build/proof-budget-128k-20260925/deployment-v1/`.


## 2026-09-25 — reproduced signed_target_unavailable during account setup

A fresh browser signup on .238 committed, then its profile read and lobby action
both received HTTP 503 signed_target_unavailable 27–31 ms later. The test key,
journal and trace are retained under `_build/signed-target-unavailable-20260925/browser-v1/`.
The founder also has a separate newly created profile without a lobby; whether
that is Yan's reported account has not yet been confirmed.

Ingress now uses the existing exact directory-route notification wait before
initial submission, bounded by the signed deadline. It rechecks local ownership
and preserves the original peer/principal when the new target starts locally.
No uncertain operation is retried. Local admission and hosted-route publication
now require Simplex's installed Prolog-ready acknowledgement. Its ready event
is identity/owner scoped, after the gate installation; stale notices are inert.
Production delta is +54/-20 (net +34) across four existing modules, with no new
owner, queue, executor or readiness timer.

Focused tests passed: 303 covering ingress, target, directory, hosting and
Simplex, then 19 covering the final manager adjustment and real lobby recovery.
Xref and production compile pass. No full suite repeated. Deployment and a
successful ordinary browser signup remain next; this is not acceptance yet.


## 2026-09-25 — .239 deployed; scene startup race isolated and corrected

Implementation 46ec9a0 and label f34d07d are pushed and .239 runs on all ten
replacement tasks. No ledger/key reset. The first capture was during recovery;
a later capture verifies all 144 prior namespace replicas with unchanged
identities/committees and nonregressing frontiers, 146 running and healthy.
Fresh browser signup and lobby provisioning now both commit, but the first
scene read still fails: bounded OTP trace sessions show an unknown target
before its local process/route starts. Their observer sessions self-destroyed.

A second capture at the failing call proves the namespace manager's existing
desired-hosting projection already has the exact lobby anchor. The resolver now
uses that published projection, waits on the existing exact directory event,
and rechecks local ownership before opening its normal scope. This replaces a
broader uncommitted experiment; no name-wide event or wait for unknown names
remains. No request-time repair, history rebuild or proof retry was added.

The browser now offers explicit Finish account setup for the selected saved
account if it has no lobby. It shares the existing provisioning action and
journal handoff implementation. Unknown enrollment operations block a fresh
submission; the action is never automatically retried. This covers accounts
left pending by .238's explicit pre-admission refusal without creating a new
profile or bypassing owner policy.

Final focused tests: 91 Erlang and 47 client tests pass, xref and production
compile pass. UI build passes. Production source delta +107/-41, net +66
across the resolver, published-projection accessor and browser recovery UI;
no new production module/process. Full logs, abandoned draft and failed browser
campaigns remain in `_build/signed-target-unavailable-20260925/`.
The second correction is not deployed or hardware-accepted yet.


## 2026-09-25 — first complete hardware signup; final anchor pin refinement

.240 source abde283, assets a0081a5 and label be0624e are pushed and deployed
on all ten replacement tasks. Hardware browser v5 passes ordinary signup,
lobby creation, first scene and reload, with no HTTP errors. Account and
journal are retained. An initial 45-second recovery observer expired on two
old source replicas; this evidence remains intact, separate from later audits.

Final inspection found a narrow identity-change window in the post-wait local
selection. Extracting the shared anchored local opener retains the selected
genesis anchor through scope admission instead of resolving the name again.
No additional production lines; 62 focused Ask/lobby tests, xref and production
compile pass. The final pin refinement still needs deployment and acceptance.


## 2026-09-25 — .241 accepted; signup creation policy review

.241 (9584e18) replaced all ten tasks with retained ledgers and identical pinned
predicate bridges. Both fresh browser signup/scene/reload and Finish account
setup for the explicitly refused .238 account pass. The retention audit after
recovery verifies all 152 prior replicas; the new lobby brings that capture to
153. The subsequent fresh signup also passes. Recovery observer expirations on
two old source replicas and CLI alarm exits remain preserved as failed probes.

Claude's consultative review identified unrestricted creation names. Verified
locally: the previous signup and lobby policies each admit a reserved test name
through ordinary signed goals. The new negative tests fail against each original
policy (with the dependent restart fixture then also failing); both logs remain
under `_build/signup-policy-20260925/`.

The correction belongs entirely in Prolog: derive the existing human namespace
spelling from the token, independently constrain delegated root creation, and
require the owner's exact pending personal lobby plus namespace confinement.
The requirement remains present until creation permission has been checked;
consumption, creation, hosting and receipt cleanup remain one transaction.
Existing profiles need the same clause update when activating the policy.
Admission pricing/capacity, multi-host user durability, bridge pinning granularity
and proof-worker capacity remain separate follow-ups; no new budget or consensus
change is introduced. Deployment and final verification are still pending.


## 2026-09-25 — creation policy correction deployed and accepted (.242)

Implementation 5948534 and release label 5057543 are pushed. The correction adds
38 production Prolog lines, with no Erlang/client/format changes. Fifty focused
lifecycle/lobby tests and production compilation pass; no full suite repeated.
Ordinary transactions installed the two policies and migrated all ten existing
profile clauses. Two historical profiles were checked against 54ca17a before
replacing the known template and recording their already-declared hosting node.
Signup was briefly closed during activation and is open again. No identity,
ledger, key or user-authored clause was discarded.

All ten .242 containers replaced the old tasks and pass all four service checks;
all eight historically pinned bridge BEAMs remain byte-identical to .236. Final
hardware audit verifies all 155 prior replicas with unchanged anchors/committees
and nonregressing frontiers, 158 current replicas healthy. Fresh browser signup,
lobby creation, first scene and reload pass; a migrated existing account also
opens its retained lobby and survives reload. The current founder browser origin
is `https://192.168.1.10:21628/`; keys remain browser-origin bound.

Two early retention captures and the 45-second readiness observer encountered
old source replicas still loading. The first fresh-browser harness also crashed
on an unhandled export-download timeout while signup was busy; its profile
committed and remains pending. Nothing was resubmitted or erased. The corrected
harness and a separately labelled identity passed. Failed evidence, operator
inventory corrections, exact activation and final results are retained under
`_build/signup-policy-20260925/`, particularly `FAILURES.md` and `RESULTS.json`.

Remaining follow-ups are admission cost/capacity in Prolog, replicated account
hosting, predicate-manifest granularity, shared exact-route selection and proof
worker occupancy measurements. They are not part of this policy correction.


## 2026-09-25 — exact local wake, XR action menu and startup identity (.243–.245)

**Correction after Yan's review:** the .244/.245 exact-selector extension
described below violates `distributed-proof-plan.md` §3: Prolog selection
names only the namespace. These results are historical test evidence, not
architecture acceptance. The extension is being removed; see the correction
entry below. Parentheses group ordinary Prolog goals and are valid.

.243 implementation 7932285 and release bb3ad81 are pushed. Signed ingress and
cross-ontology proof selection now share the directory owner's exact
validator-target wait: subscribe before snapshot, then wake on either the exact
local runtime identity becoming Prolog-ready or an exact validator route. The
wait retains the caller's absolute deadline and adds no polling, retry or repair
path. The Babylon scene uses the existing Prolog `lobby_menu/2` description for
both desktop buttons and an XR radial menu; opening the proof console reuses the
existing signed cursor and commit path.

A fresh .243 signup exposed a smaller race. Profile and lobby creation had
committed, but the first scene used a namespace-only `::` selector. Before the
hosting projection published that new namespace locally, Ask could not know
which exact ontology to await and returned `unknown_ontology`. .244 implementation
51a2ae9 carries the already-returned `ontology_ref(Name, Anchor)` in the ordinary
Prolog selector. Ask can therefore subscribe directly to the exact runtime and
route events before the namespace projection catches up. The inner
`current_ontology_identity/2` guard remains, and scope wire version 14 carries
the exact selector for nested proofs. Name-only selectors remain supported.

The first .244 browser acceptance found one duplicated interpretation: the Ask
executor understood the exact selector, while signed top-level authorization
still classified only plain names. It refused the exact form before execution
with `not_allowed(Profile)`. .245 implementation 9de85a5 moves selector
normalization into `quod_ontology_name`; authorization and execution now use the
same parser. This replaces the duplicate logic rather than adding a browser
exception. Release labels c9585e9 (.244) and 00ca32d (.245) are pushed.

Focused final verification covers 145 Erlang tests with zero failures, 48
client tests, UI build/lint, production compile and xref. No full suite was
repeated. .245 is running on all ten clean replacement allocations with retained
volumes and byte-identical historical predicate bridges. The stable post-restart
capture preserves all 170 pre-deployment namespace rows and reports 176 healthy
rows after three diagnostic signup/lobby pairs. Earlier captures during history
loading are retained as failures rather than overwritten.

Fresh .245 browser acceptance passes signup, atomic profile/lobby creation,
first scene, semantic console action and the focused Prolog console. In the
accepted run the first exact scene read took 2.2 seconds; its Tempo trace places
2.179 seconds in `quod.ask.route_wait`, followed by millisecond lobby and
presentation proofs. This is the intended event-driven wait for the committed
new lobby to become locally ready. Earlier 7.7-second successful startup and
stale acceptance-label failures (`Prove goal` versus `Prove a goal`, then
`Prove console` versus `Prolog console`) remain preserved. Evidence is under
`_build/scene-delay-20260925/`, especially `deployment-245/` and
`acceptance-245-v3/`.

The remaining product follow-ups are the previously deferred Prolog admission
cost/capacity policy and replicated account hosting. XR radial-menu behavior is
covered by adapter tests and the production bundle, but still needs a physical
headset check.

## 2026-09-25 — remove the unapproved exact-selector extension

The working tree reverses implementations 51a2ae9 and 9de85a5: browser goals
again use namespace-only `::`, Ask and signed-origin authorization use the
existing name grammar, and nested scope messages carry namespace-only targets
with the original scope wire version 13. No compatibility path is retained.
`ontology_ref/2` remains ordinary reference data; the existing
`current_ontology_identity/2` goal unifies against the selected proof scope's
identity. Neither is new selector syntax.

Negative controls now reject the removed selector in Ask, signed-origin
classification and nested scope transport. Existing lobby controls retain
the expected-identity guard, privacy and restart obligations. Focused validation
passes: 144 Erlang tests, 48 client tests, production compile and xref. Logs
are retained under `_build/selector-removal-20260925/`. Production source and
browser assets match .243 again (apart from the unchanged release label);
the source delta is +22/-73, net -51 lines, excluding generated assets.
This correction has not been deployed. The last recorded fleet release
remains .245.

The saved .243 trace establishes an immediate `unknown_ontology` before any
readiness wait. It does not establish whether a local Simplex process already
existed at that instant. Its immutable genesis-anchor accessor is a candidate
source for namespace resolution during startup, not a verified complete fix.
Trace the actual creation/hosting installation order before changing that
boundary. Removing the unsupported selector does not itself fix the race.

## 2026-09-25 — selector removal deployed (.246), signup acceptance still failing

Yan explicitly requested deployment of the removal. Source 0066b95 and label
977e2e7 are pushed. All ten .245 tasks were stopped and replaced with .246;
volumes were retained and all eight historically pinned predicate BEAMs were
verified unchanged. All four service checks pass on all ten replacements.
The first completed retention capture is healthy and preserves all 176 prior
replicas, their anchors and committees. No ledger or account was erased.

Hardware browser acceptance using an encrypted export of an existing account
passes login, its retained lobby and reload on the configured signup host.
The current URL is `https://192.168.1.10:25783/`. Browser storage-state JSON
alone did not restore the earlier test identity; that failed harness attempt
is retained and is not a server-acceptance result.

Fresh-signup acceptance does not pass. On the configured signup host,
creation/provisioning returned successfully, then the first scene read failed
in 23 ms with `proof_unavailable`; trace 37a0b7619f09383e548b8dec75280bdf
records `unknown_ontology` in the proof. Two separately labelled node-0
gateway campaigns instead waited for the new profile route; the fully
observed attempt returned HTTP 503 at the existing 30-second request deadline.
No request deadline was extended. A subsequent signup-host diagnostic returned
HTTP 202 pending, trace 9fd23fcc74c55c1642a26e44277f990e. Its uncertain write
was not resubmitted. Browser states, journals and traces remain in the evidence
directory. A bounded local selector trace was stopped; it captured no target
lookup that establishes Simplex's presence at the original failure instant.

Some initial relx recovery observers exited 142 (`Alarm clock`); their logs
remain separate from the later healthy retention capture. The final capture
still preserves all 176 prior rows (180 current rows), but fails its idle
assertion: the eight local root replicas report height/applied 164 and
`awaiting_commit` after the pending signup. This is outstanding work, not a
successful final health gate or evidence of data loss. Do not silently rerun
the uncertain signup. Resolve its original outcome and inspect root progress
before another acceptance campaign or deployment.

All evidence: `_build/selector-removal-20260925/`, particularly
`deployment-246/`, `existing-key-246/`, `acceptance-246-signup-host/`,
`acceptance-246-stable/` and `acceptance-246-probed/`. The unsupported selector
is removed from the running fleet; namespace-readiness/discovery remains
unresolved and requires an architectural correction through existing owners.


## 2026-09-25 — consultative review verified; startup correction isolated

Claude's review was checked against the implementation, not adopted as orders.
The narrow namespace lookup correction now consults the existing Simplex
identity when its Prolog child has not registered, then uses the existing
exact-identity readiness wait. It removes the redundant origin_scope_admitted
wrapper. Production delta +12/-12; no new owner or selector syntax. Both
startup variants and the existing lobby/privacy/recovery controls pass:
63 focused tests, zero failures, plus production compile. Shutdown explicitly
checks that no stale Simplex genesis row survives. This code is not deployed.

The earlier pre-start gap remains: a signed multi-ontology creation can commit
before either its creation effect or hosting projection runs. A retained
lifecycle reproduction proves it. Reading committed node hosting policy is
preferred to the discarded broad projection-wait draft, but its bounded,
anchored proof and application-progress contract still needs completion.
The plain prove_ro/2 API is not sufficient as-is: it supplies neither the
outer deadline nor an expected anchor. applied_live alone also misses replay;
existing owner-scoped projection_advanced notices must be considered. Bind
the exact local NodeRef, distinguish absence from unavailability, and replace
superseded lookup machinery rather than accumulating fallback paths.

Read-only captures from all eight validators now confirm root's slot-165
split with independently checked signatures: nodes 0/3/4 latched commit,
nodes 1/2/5/6/7 complaint; all share pools show 8 support / 3 commit /
5 complaint. Root remains at committed/applied 164. The captured latches are
read from live journal handles, not from a new disk-journal parser. No votes,
accounts, ledgers or pending operations were changed. The original signup
remains unresolved; this is an actual acceptance blocker.

Two review corrections: directory control already resynchronizes on link
installation; the finality plan's proposed QSJ4/V6 labels are obsolete
(current QSJ5/V7). Current directory stats and retained logs were captured,
but do not establish the cause of the earlier remote routing failure.
No consensus format change or network re-found is included in this correction.

Evidence and the complete verification:
`_build/namespace-readiness-20260925/claude-verification/VERIFIED-REVIEW.md`.
The oversized first forensic capture's truncated output is retained separately
from the successfully decoded bounded capture; no silent rerun or erased
failure. Fleet remains .246 with existing data retained.


## 2026-09-25 — consensus correction resumed

Yan authorized the coherent consensus correction and its necessary performance
work. After discussion, portable snapshots/compaction are deferred: retain full
certified history and existing recovery. Snapshots would restore the same
irreversible split, not repair it. No old votes, ledgers or accounts are changed.

`doc/finality-round-recovery-plan.md` §0 reconciles the historical prerequisite
list with current source. Phase 1A owner/scanning work already shipped; the
later settled AM3 contract and its implementation already authenticate exact
applied/rejected results. The older proposed block-receipt format is not an
additional prerequisite. Both atomic Vote/Resolve/Complete and independent
execution exist. Current journal/store formats are QSJ5/V7; proposed cut labels
are QSJ6/V8. The atomic source cut, review and full release gates remain needed.

The real pre-cut engine, timeout/vote handlers and disk signing journals now
reproduce N=8, quorum=6, 8 support / 3 commit / 5 complaint at slot165. All eight
journals recover the same final latches. Even granting a notarized child166,
only three can commit it; proposal167 is blocked. This starts at the admitted
block seam, not a full QUIC/DTX deployment, and does not establish what caused
the original hardware timeouts. The diagnostic is a retained negative control,
not a passing recovery test for the future implementation.

Evidence: `_build/finality-resume-20260925/finality_split_probe.erl`,
`split-run-1.log`, and `run-1/result.term` (journals retained alongside).
The baseline result-authority check ran 21 existing focused tests against the
available test build: 13 certificate/vector checks, four coordinator lifecycle
checks and four fresh-result cases, including a deliberately false transport
label. All passed; no full gate or current-tree rebuild is claimed. Production
source delta at this checkpoint is zero. Fleet remains .246, original signup
unresolved, and d8deff1's narrow startup correction is still not deployed.

### 2026-09-25 — F1 source cut in progress (not a release candidate)

Yan accepted consensus-first/full-history scope and authorized continued work
while away. Branch `feature/simplex-finality` starts at `d8deff1`; planning-only
commit `de1de00` records the reconciliation. The old .246 fleet and its pending
signup are untouched. No code commit, push, deployment or re-found has occurred.

The working tree is deliberately an **incomplete atomic source cut**. Old
runtime/API consumers and old fixtures have not all been migrated; do not run
or deploy this tree as a candidate. Isolated compilation/test overrides live in
`_build/finality-resume-20260925/codec-ebin`, separate from the old test build.
Current implemented seams:

- Canonical block2/entry2 separates material height from era/view; genesis has
  fixed view zero, empty carriers cannot construct material entries, and one
  compact head-QC descriptor replaces immediate-child proof encoding.
- Signature domain3 and QSJ6 journal keys bind era/view. Same-view final votes
  remain mutually exclusive across restart. Journal retirement now requires
  archived protocol floors/sealed eras, not material height.
- Pure engine permits descendant finality and complaint-driven view progress
  without synthetic ledger skips. N=8 persisted 3/5 split and N=4 stacked split
  regressions pass at the admitted-block seam; this is not full runtime or
  hardware acceptance. Terminal membership refuses material descendants.
- A measured whole-certificate-pool scan was replaced with dependency-specific
  parent/complaint wakeups. The same 128/256/512/1024-view probe changed from
  293071/1109285/4259780/16647337 reductions to
  37034/72243/138851/286386. Elapsed time at 1024 views changed from 454307 to
  386135 microseconds on this run; cryptography dominates, and this is not a
  claim about fleet throughput.
- V8 store prototype has complete proof/material append groups, one datasync,
  proof cursors and sparse material seeking. Complete orphan proofs are trimmed
  with an unfinished group; completed referenced corruption fails loudly.
  Read-only recovery never truncates. Sequential reads preserve their buffer.
- The existing catch-up module now owns a streamed exact-parent finality cursor,
  including the parent carrier path between material entries, terminal-M shape,
  timestamps and contiguous material claims. Groups sharing a head verify in
  one backward pass. The history projection derives the next era from M rather
  than from its selected witness head. Foreign projection format is version6.

Focused evidence retained in `_build/finality-resume-20260925/`:
`codec-first.log` (6), `signature-journal-first.log` (7),
`engine-dependencies-first.log` (7), `store-buffer-and-crash.log` (8),
`finality-group-first.log` (8). These are **36 distinct focused checks** across
successive trees, not a clean gate suite on the final tree. The store checks
include every byte truncation of a sample group and a witness exceeding one
network page. Shared deterministic protocol fixtures are in existing `quod_ct`.
Compilation failures `engine-compile-first.log` (accidentally removed helper,
restored unchanged) and `finality-cursor-compile-first.log` (misplaced export
attribute, corrected) are retained. No failure was silently overwritten.

Remaining integration is substantial: owner era/view lifecycle and proposal
admission, asynchronous validation barriers and autonomous empty recovery
proposals; complete proof custody before journal release; new-era installation;
streamed transport/forward-history consumers and group staging; DTX ref3 and
verified-selected-witness matching; removal of old skip/grace/depth-one paths,
old comments and superseded tests. Existing AM3 outcome authority stays intact.
The final release review, sequential gates, isolated hardware campaign and
coordinated activation have not begun. The code must not be committed as a
completed consensus repair merely because the foundation checks pass.

### F1 continuation — archive recovery and shared semantic verification

The current focused checkpoint is `archive-foundation-first.log`: **48 checks
passed on one captured working tree**, with selection and patch/SHA256 beside
it under `_build/finality-resume-20260925/`. All changed Erlang modules and test
modules compiled with `-DTEST` without warnings in
`archive-foundation-compile-first.log`. Earlier 41/44/46/47-check checkpoint
logs remain intact. These are isolated foundation checks, not a full build,
release gates, live owner acceptance or permission to deploy this partial cut.

Additional implementation and evidence:

- DTX ref3 now treats its compact head as a preferred witness, not a second
  immutable identity. Exact claims are matched against the history owner's
  already verified selected entry. The caller-supplied-entry verifier was
  removed; local application evidence uses one captured indexed read. The
  regression counts one read and rejects altered immutable claims.
- Archive spans can extend an already durable parent span without copying it.
  A complete-group recovery fold streams each selected proof once. The shared
  `quod_catchup:verify_forward_group/5` combines that finality cursor with the
  existing semantic/index preview; hosted and foreign startup both use it.
  The superseded direct-entry phase reducer was removed. Its eleven test
  fixture callers now use the same common `quod_ct` group-verification helper;
  their old-format fixtures still require migration before full-suite claims.
- Hosted startup separately restores the last material root and the highest
  complete archived protocol head. The real storage/journal recovery seam
  resumes after view19 at material height2; a terminal membership entry starts
  the next era at virtual view0 instead. Only journal eras actually certified
  by this archive can be sealed. Unknown/future-era votes survive. Both cases
  are recovered twice.
- A bad later certificate leaves even earlier vote latches intact. A valid
  proof of an exact historical entry whose head also contains unarchived
  material is usable for that claim, but refused as complete validator
  recovery custody. Neither condition retires journal decisions.
- Carriers inherit their exact parent's timestamp. Live tree admission,
  pruning/root restoration and streamed history enforce the same rule.
- Runtime vote construction now binds the engine's era. Startup projects only
  that era's journal latches into volatile rounds. Eligible body restoration
  uses direct journal lookups; the full-body-map export is test-only. Wiring
  restoration to live view-progress edges is still pending with the owner cut.
- Engine committees are immutable per era. Repeated signer filtering at
  certificate formation/lookup was removed; ingress remains the authenticated
  trust boundary. This simplification is not a new fleet-performance claim.

Next integration remains the live owner: one authoritative view/parent from
its engine, material admission distinct from carrier progress, grouped live
append/apply and protocol custody retirement, era replacement and ingress
placement. Streamed network acquisition/staging and old fixture/API cleanup
remain unfinished. In particular, `approved`, old material/view comparisons,
skip/grace/depth-one paths and legacy append callers still exist in the owner;
the tree is deliberately NOT runnable as the completed repair. The .246 fleet,
original unresolved signup, and deployment boundary remain unchanged.

### F1 continuation — live grouped finality, views and carrier owner

Current focused checkpoint: `carrier-owner-first.log`, **80 checks passed** on
one captured source patch/SHA256, with the exact selection beside it under
`_build/finality-resume-20260925/`. The changed Simplex source/tests compiled
with `-DTEST` without warnings in `carrier-owner-compile-first.log`. This is
not the full suite, a normal-profile build, a runnable completed network cut,
or hardware/release acceptance. Fleet .246 and the uncertain signup remain
untouched. No implementation commit, push, deployment or re-found occurred.

Completed since the 48-check foundation checkpoint:

- Live owner archives a complete selected proof/material group before index
  publication, journal retirement or ordered Prolog apply. Real store/journal,
  publication and apply seams cover long empty suffixes, proof-span extension,
  terminal-M era replacement and a real read-only-descriptor append failure.
  Failed append exposes no material progress and retires no votes.
- Complete-tree ancestry caches material counts/latest material references.
  Parent height and author floors skip empty suffixes; content and DTX verdict
  requests now carry the material position while correlating the protocol view.
- Engine view edges own fresh commit intent. A late notarization after a
  complaint-driven advance cannot invent it. Removed complaint amplification,
  cross-view camp selection, synthetic skip appends, duplicate finalization
  buffers' writers, weak-certificate waiting, and live committee mutation.
- Relay placement and unsigned attempt identity bind era/view; transport frames
  are sx3 / sx_relay2. Signed transaction format remains version15. Destination
  results are hints only; local verified material history still owns custody
  inclusion/exclusion. Removed the redundant historical relay-result lookup.
- Timeout tracks exact era/view with no quorum-grace extension. Duplicate
  evidence, phase changes, link readiness and stale-era timeouts cannot renew
  the same view's deadline. The obsolete quorum-rearm fixture was removed;
  the replacement checks no-renewal, local readiness and stale-era behavior.
- Shared proposal admission checks exact complete parents, every skipped-view
  complaint certificate and terminal-M/timestamp rules. Author sequence checks
  use the candidate's actual parent, not the locally preferred parent. The
  existing material overlap bound no longer limits empty consensus progress.
- One local proposal publication helper now serves content, DTX and empty
  carriers. After existing material queues drain, entering-view/readiness edges
  can select one empty carrier for unfinished material. No idle carrier stream,
  new timer, second executor or synthetic Prolog transaction was added.

Intermediate checkpoints and failures remain intact. `era-wire-first.log`
failed one obsolete shape-only DTX reference fixture at reserved genesis height1;
`quod_ct` now uses material height2 with the canonical compact descriptor.
`era-wire-fixture-corrected.log` passed six relay checks; later combined 76/77/78/
79/80 checkpoints passed. Compilation failures `live-group-compile-first.log`
(obsolete test export) and `live-owner-compile-first/second.log` (stale stats
helper) were corrected, not overwritten. Watchdog/admission intermediate
compiles recorded unused-helper/variable warnings; the 80-check compile is clean.

Still unfinished: remove residual approved/material-view assumptions, obsolete
record fields, diagnostics/docs and fixtures; finish catch-up/foreign network
proof streaming and complete-group staging through existing workers/owners;
serve archived protocol bodies through captured proofs, not view-as-height
lookup; audit recovery custody exclusion and readiness transitions; retain AM3
verification and useful healthy material overlap. The existing numeric material
window has only been separated from protocol progress, not assigned a new
Prolog resource policy. No new resource ceiling was introduced. Review that
existing policy ownership as part of the complete candidate.

Source/header delta at this checkpoint versus `de1de00`: +2047/-2291, net -244 lines;
tests and handoff text excluded. This removes substantial old owner machinery,
but the whole-cut deletion/fixture audit and required release gates are pending.

### F1 continuation — custody and provisional DTX validation

`dtx-preview-first.log` passes **84 focused checks** on its captured patch and
SHA256, with a clean changed-module TEST compile. Earlier 81- and 82-check
receipts remain intact. The normal-profile Simplex/metrics/Explorer compile
and UI TypeScript check passed at the 81-check tree; they do not cover later
custody/DTX edits. No full suite, release gate or hardware acceptance yet.

- Removed residual approved/commit-buffer/skip state and migrated diagnostics
  and Explorer labels to distinguish consensus view from material height.
- View advance retires an obsolete placement, retaining the same signed
  request, operation, sequence and absolute deadline. Only certified material
  history resolves its outcome. A notarized but uncommitted author sequence
  holds custody instead of reporting a stale request. The actual owner test
  covers silent-leader replacement with no ledger append or premature reply.
  This implements the already approved plan §4.5; ingress docs now agree.
- DTX preview uses a private provisional reference through the same transition
  reducer. Removed the fake certificate marker; provisional references cannot
  enter certified replay or restored projections. A delayed valid verdict may
  install a needed certified ancestor after its view advances, but may never
  produce a fresh vote in that old view. Both seams have focused regressions.

Next: streamed history transfer through the existing reader/link/fetch owners,
complete-group staging and recovery installation, then obsolete fixture/API
cleanup. The candidate remains incomplete and uncommitted. The .246 fleet and
original uncertain signup remain untouched.

### F1 continuation — paged proof transport foundation and owner lifecycle

`transfer-client-first.log`: **9 additional focused tests passed**, clean
changed-module TEST compile. These were a separate selection from the prior
84 checks, not a combined full-suite result. Frozen patches, hashes and exact
selections remain under `_build/finality-resume-20260925/`.

- The archive's retained transfer cursor sends material descriptors followed
  by the selected proof, finishing a partially requested group and stopping at
  the receiver's previous material hash. Long proof traversal uses sequential
  reads across pages, including reused/extended archive spans.
- Existing catch-up paging can batch multiple groups. A group verifier keeps
  one finality cursor across pages, stages validated proof frames in an unnamed
  temporary file and returns a projection/index delta only after completion.
  Staging reuses the archive frame codec; it grants no finality authority.
  The standard file process permits the append owner to consume the source
  while its fetch worker awaits acknowledgement. Worker kill closes it.
  The existing work owner still must record/remove the staging path to cover
  interruption between exclusive creation and unlink; that integration remains.
- Replaced the link grammar with version-3 history requests/pages and opaque
  continuation tokens. Local disk offsets never cross this grammar. One server
  reader, captured source and original deadline span the whole material range.
  Stale/wrong-link tokens cannot take over it. Idle expiry kills the reader.
- Hosted page consumption now runs in its calling worker, retaining exact
  page custody through acknowledgement. A dead consumer cancels its binding;
  callbacks cannot acknowledge another caller's page.

Retained failures: `archive-transfer-first.log` used a fixture whose proof bytes
were below the intended 900 KiB boundary; the corrected 8000-carrier fixture
crosses it. `proof-stage-first.log` timed out because its test looked for a
file-process link; OTP monitors the opener instead. Corrected test observes
that monitor and real descriptor death. `transfer-server-first.log` passed the
two new lifecycle tests but hit a stale `/tmp` fixture from an earlier aborted
VM in another test. Test directories now use random names across VM runs;
`transfer-client-first.log` passes all nine checks. No failed log was replaced.

**Integration is still incomplete:** production recovery/feed and foreign fetch
drivers still expect the old entry-only pull/result forms and must be replaced
with the new page/group consumer, staging ownership and complete-group sink.
The new public hosted pull takes query/contact/original deadline/consumer;
old callers are intentionally not retained behind a compatibility shim.
Do not run this partial cut on the fleet. No implementation commit, deployment,
ledger purge or original uncertain-request resubmission occurred.

### F1 continuation — recovery group installation

`recovery-groups-io-corrected-first.log`: **95 focused checks passed together**.
The captured selection combines the earlier 84, nine transport/staging checks,
and two new recovery-owner cases. Changed modules compile cleanly with TEST;
this remains below the completed-cut release boundary.

- The common range consumer threads installed context across multiple groups
  in one page. A later invalid group returns the last successfully committed
  context; it cannot throw away a foreign writer's updated handle. Temporary
  proof bytes are reset only after each append acknowledgement.
- The hosted catch-up driver now consumes query/continuation pages and complete
  groups under each original range deadline. Recovery allocates/owns its stage
  path before worker launch and removes it on completion/DOWN/termination.
- The Simplex recovery sink appends proof plus material together, advances its
  archived protocol head/floors before journal reconciliation, and restores the
  engine from that head or the new terminal-M root. It rejects incomplete
  material custody and stale windows. Real read-only append failure preserves
  the owner and journal; replay emits a certified-height wake and replay apply,
  never live committed-entry events. Ordinary and membership cases pass.
- Recovery now uses live commit's exact submission/operation/DTX resolution.
  Removed duplicate catch-up custody/relay/effect-retirement code and its
  view-versus-height comparisons. Remaining placement exclusion uses the
  archived protocol position or terminal-M seal; retained custody is re-placed
  without inventing a request outcome. Volatile relay hints reset with their
  owner generation.
- Source proof traversal reads only the canonical block parent; it no longer
  decodes/authenticates application transactions simply to forward their bytes.

Retained failures: `recovery-groups-compile-first.log` found a test export for
the removed custody implementation; the dormant-custody fixture now calls the
shared recovery resolution seam. The next run passed 93 checks and failed two
new fixtures which expected bare `ebadf`; the existing append boundary returns
`{badmatch,{error,ebadf}}`. Only those expectations changed; the 95-check run
then passed. No assertion about append safety or publication was weakened.

Source/header delta versus `de1de00`: +2953/-2840, net +113 lines. The added
streaming, staging and continuation lifecycle is a missing capability for long
proofs. Retirement of the obsolete foreign/feed entry-only paths is pending.
The foreign fetcher and feed still require migration; archived protocol-body
serving and the broader obsolete fixture/API audit remain unfinished. Do not
deploy this partial tree or claim completed hardware acceptance.

### Finality continuation: foreign proof groups (2026-09-25, 102 checks)

The same uncommitted coherent cut now routes foreign exact/current/follow
acquisition through the shared streamed range consumer. One verifier cursor
survives continuation pages and route failure. Complete groups append their
proof plus material before phase-index/checkpoint publication; a later bad group
or failed page-credit acknowledgement returns the latest committed cursor.
Post-mutation failures still invalidate the cursor and enter the existing
explicit reconstruction lifecycle. No caller-time prefix rebuild was added.

- The foreign page owner retains its original deadline/monitor/credit through
  consumption and accepts the new continuation query. Discovery only nominates
  a source; incomplete discovery ranges release their link. Current-view quorum
  confirmation verifies returned groups through the shared verifier and refuses
  an empty response behind the already-certified prefix.
- The existing request owns temporary staging names before workers open them.
  Normal release, request retirement and the existing exclusive-writer startup
  cleanup cover those names. The file is unlinked before proof bytes are written.
- Local follows borrow one captured source descriptor and retain the transfer
  cursor, with the same range verifier and source-incarnation checks. This path
  still needs its updated lifecycle fixtures exercised.
- Removed foreign isolated entry-hint import, entry-only page validation and
  page persistence. A reference fixes the immutable claim; missing selected
  ancestry is acquired through the existing history service.
- Group byte reservation uses the archive's physical framing calculation.
  Groups currently sync separately. Measure multi-group history acquisition
  before claiming recovery throughput: fewer network round trips alone are not
  a disk-throughput measurement.

Evidence: `_build/finality-resume-20260925/foreign-stream-refusal-deadline-corrected-*`
freezes source patch/hash, selection, clean TEST compilation and **102 passing
focused checks**, including the previous 95, hosted transfer driver, actual
foreign client credit/server integration, an 8,000-carrier proof, bad suffix,
post-consumption acknowledgement failure, restart, current-view confirmation
and a behind-source refusal. No full release gates or hardware campaign yet.
Retained failures: `foreign-stream-first-compile.log` caught a function-boundary
edit error; `foreign-stream-syntax-corrected-tests.log` caught stale arity-5
adapter configuration; `foreign-stream-integrated-tests.log` passed 101 checks
before its new refusal fixture exceeded EUnit's five seconds while correctly
waiting on its own twenty-second caller deadline. That fixture now supplies a
500 ms deadline; production deadlines were unchanged.

Source/header delta against `de1de00`: **+3231 / -3163, net +68** at this checkpoint
(tests/docs excluded). Observer/feed integration and certified-block serving
still need completion, as do obsolete format/API fixture migration and the
completed-cut gates/review. Do not deploy this partial tree. Fleet .246 and its
uncertain original request remain untouched; no implementation commit/push.

### Finality continuation: observers, archive handoff and material consumers

The observer feed now acquires proof groups through its existing single pull
worker and the shared verifier. Simplex is still the sole writer. Consecutive
live receipts select live application only for those material heights; old
history remains replay even inside the same archived group. Only acknowledged
live material is relayed onward. Stage paths are owned before worker creation;
worker exit alone cannot self-trigger a retry. The real sink origin/ownership
checks and entire feed unit module pass. A full observer-worker network case
and updated local-follow lifecycle fixtures remain outstanding.

A pruned-body request now receives the owner's archived CommitQC through the
existing certificate frame, leading a lagging peer to ordinary certified-history
recovery. The owner no longer treats a protocol view as a material read offset.
Tests cover live/recovery installation, ordinary/membership histories, zero
ledger reads in that reply, and certificate retention after cold restoration.

Removed the obsolete entry-only catch-up APIs (`verify_forward`, `verify_entry`,
`serve_blocks`, page decoding/stats) and ledger page decoder. Their remaining
production consumers were already migrated. Test fixture wrappers now use the
shared finality verifier; other old test modules still require migration.
Material consumers no longer accept/publish a synthetic skipped-row kind.
Protocol carriers never reach Prolog application, metrics or Explorer history.
The old implicit-certificate record remains only until its last fixtures move.

Evidence under `_build/finality-resume-20260925/`:
- `archived-handoff-fixtures-corrected-*`: **134 checks passed** together.
- `material-envelope-corrected-*`: **161 checks passed**, including complete
  ledger and artifact modules (the selection repeats its six initial codec
  checks). Independent V2-envelope/V8-group byte comparisons replace the old
  V7 golden contract; old vectors remain in git history. Constructor, hostile
  byte ingress, opaque-symbol, sidecar and no-repeated-decode obligations stay.
- `store-scan-observability-restored-*`: **54 checks passed**, the complete
  storage and artifact modules. Storage fixtures now use complete groups and
  test V1–V7 refusal, sparse checkpoints, immutable views, explicit writer
  resumption, torn groups, valid footers behind corruption and trace structure.

The expanded artifact boundary test found a real envelope allowance mismatch:
V2 adds three 32-byte ETF binaries and one tuple header. Accounted for that
**113-byte representation overhead**, retaining the existing 256 KiB payload
budget. The boundary test uses maximum 64-bit views/time and verifies one-byte
payload overflow refusal. This is not a policy/resource-budget increase.
The old storage suite caught missing scan timing attributes; restored framing
and decode aggregates and added proof-block count in the same startup cursor,
without per-frame spans or another mutable owner.

Retained failures: `archived-handoff-first` had stale compiled fixtures calling
removed APIs plus a reply fixture consuming an earlier case's mailbox message;
recompiled callers and isolated the response link. `material-consumers-first`
passed 144 checks, found the envelope bug and a corruption fixture accidentally
invalidating its outer group header. The fixed header preserves the intended
entry-decoder refusal test. `store-fixtures-first` caught an illegal assertion
pattern; `store-fixtures-compile-corrected` passed 53 checks and exposed the
missing timing attributes. All logs remain intact; no silent reruns.

Source/header delta versus `de1de00`: **+3440 / -3628, net -188 lines** (tests/docs
excluded). No full release gates, completed-cut consensus review or hardware
acceptance yet. The partial source remains uncommitted. Fleet .246 and its
original uncertain request remain untouched; no deployment/purge/resubmission.

### Finality continuation: Prolog projection and full catch-up endpoint checks

`material-projection-fixtures-corrected-*`: **58 passing checks**, complete
`quod_committed_projection_tests` and `quod_prolog_tests`. Shared bare-applier
fixtures now construct the current material artifact; they explicitly claim
no finality authority. Replaced synthetic skipped-row advancement with real
empty-diff transactions or duplicate material. Still verified: same-block OCC,
deduplication, quiet live/replay floor wakes, parked-parent validation and
tracing, one-time reactions, effect-only work, policy preservation and manifest
refusal. The first run passed 51 and retained seven fixture failures: old
constructor/noop calls and DTX references incorrectly naming genesis height.
No production rule was relaxed to pass them.

`catchup-fixtures-proof-corrected-*`: **39 passing checks**, the entire catch-up
endpoint module. The old byte-only transport fixtures now exercise the current
canonical stream/credit grammar. The source archive has complete signed groups;
request operations remain separate from continuation tokens. All source/link/
endpoint death, expired admission, FIFO credit, retained-link, late-open and
40-reader lifetime controls pass. Range byte/count bounds and noncanonical /
wrong-namespace / opaque-symbol input checks remain. Obsolete `serve_blocks`
and page-decoder fixtures now use retained transfer cursors and direct artifact
decoding. Four-grammar coverage is in the existing current-wire test rather
than a parallel legacy grammar test.

Retained `catchup-fixtures-first` failures: incomplete fixture proofs stopped
three server cases plus range serving; an unscoped transport assertion consumed
a previous endpoint's release notice. The source now contains its actual
ancestry and assertions are scoped to their endpoint. The production proof
requirement and lifecycle checks stayed intact. Full gates/hardware acceptance
remain pending; no deployment or implementation commit occurred.


### Finality continuation: exact claims, operation endpoints and atomic application

All dirty production modules compiled without TEST and the UI type check passed
(`material-integration-normal-*`). Removed the feed's unused `classify/2`; its
ordering obligations now run through actual receipt handling, including cold
start and stale/duplicate heights. `observer-classifier-fixture-corrected-*`
passes the full 24-check feed module. The first classifier fixture attempted to
reuse a deliberately invalidated snapshot; supplying the new capture fixed it.

Complete focused modules now passing:
- `dtx-reference-fixtures-first-*`: **50 DTX checks**. Canonical references use
  material heights and compact heads. Independent valid quorum subsets prove
  the same immutable claim; a preferred head remains only a hint.
- `atomic-transaction-outcome-fixtures-corrected-*`: **109 checks** across
  atomic controls, transaction codecs and outcome reduction/publication.
- `operation-history-reference-controls-*`: **27 checks** across outcome
  endpoints and admission cleanup. The shared operation fixture has explicit
  linked blocks and archived proof groups. Covered uncertain outcomes,
  redelivery, restart, original deadlines, owner loss and historical result
  authority. Wrong target and wrong hash remain separate typed refusals.
- `entry-selection-stream-fixtures-first-*`: **12 checks**. The current
  archive stream replaces the old entry-only transport fixture. Sender payload
  authentication stays zero; selected application checks stay **7 versus 56**
  for a full eight-item batch. Tampered unselected bytes change the exact claim;
  corrupted selected proof signatures and streamed proof payloads are refused.
  CRC/index/truncation, captured-prefix bounds and sidecar decode counts remain.
- `atomic-projection-contiguous-publication-*`: **73 checks**, the complete
  atomic projection module. Vote/Resolve/Complete references follow genesis;
  publication remains contiguous. Owner fixtures explicitly supply their
  protocol parent/time instead of the retired slot-based timestamp fallback.
  The test-only blocked-parent constructor no longer changes material height
  from a protocol view. Real parent-apply wakes, journal reopening, no duplicate
  signing/selection, exact application acknowledgements and tombstones pass.

A counted transport control exposed repeated sender authentication of the
preceding material entry: three groups caused **three signature checks** merely
to obtain their cutoff hashes. Reused the store's opaque CRC/index reader and a
structural codec hash accessor; the selected receiver still authenticates the
full payload and ancestry. `transfer-opaque-previous-material-*` passes **109
checks** across catch-up, ledger, store and artifacts with sender count **zero**.
The corrected baseline failure is retained as
`transfer-previous-material-auth-owned-baseline-*`. The first baseline fixture
incorrectly opened a raw descriptor outside the profiler's worker; that failed
before measuring production and is retained separately.

Other retained failures are fixture migrations, not waived checks:
`atomic-transaction-fixtures-first` (64 pass, four old shared head placeholders),
`operation-history-fixtures-first` (25 pass, retired test state/API),
`operation-history-fixtures-corrected` (26 pass, wrong expected identity error),
`atomic-projection-material-fixtures-first` (56 pass, old height/root fixtures),
`atomic-projection-material-heights` (69 pass, four missing genesis publication
steps). No production validity rule was relaxed for these fixtures.

These are focused receipts at their individually frozen trees, not a full gate
or completed-cut acceptance. Remaining legacy consensus/history/foreign-reader
fixtures, actual observer-worker and local-follow integration, full sequential
gates, consensus review and hardware performance/fault acceptance are pending.
The .246 fleet and original uncertain request remain untouched. No
implementation commit, push, deployment, ledger purge or request resubmission.


### Finality continuation: receiver authentication and lifecycle integration

`history-view-proof-fixtures-first-*` passes all **13** view checks with real
linked material and shared archived proofs. Captured-prefix bounds, sparse
lookup and owner/deadline lifetimes remain covered without prefix scans.

A counted receiver regression was reproduced and fixed: the new transfer loop
had lost the existing exact-envelope decode context. The receiver now threads
that context through entries and proofs within one bounded page, then discards
it. It does not retain authority or decoded payloads across pages. The retained
`transfer-page-decode-reuse-baseline-*` failure measured two authentications
where one was required. `transfer-page-decode-reuse-*` passes **110** checks;
`receiver-page-context-restored-*` passes **76** catch-up/decoder/metrics checks.
The actual complete-group receiver pays two payload checks plus one head-QC
check for a two-transaction group. Committee, admission, freshness, exact claim
and full ancestry checks remain independent of this byte cache.

Additional complete focused modules:
- `runtime-material-founding-*`: **90** checks (89 runtime plus the counted
  complete-group control), including real reactions, unification and restart.
- `foreign-materializer-session-resigned-*`: **2** checks. A captured source
  remains bounded across append; incremental materialization never scans the
  path again. The first run retained one fixture failure: changing a signed
  template without clearing its cached bytes. The fixture now resigns it.
- `suffix-material-current-custody-*`: **7** checks. Actual page receipt shares
  authentication with proof bytes, including nested signed claims/applications/
  completions. Altered content, wrong admission, invalid finality, stale request
  context and duplicate custody remain checked. The first run retained five
  passes and two fixture failures (old native certificate wire and an absent
  installed material head).
- `endpoint-material-hint-fixtures-*`: **22** DTX endpoint checks. Invalid
  proof signatures can cross bounded untrusted hint transport; that gives no
  finality authority. Current reference grammar, exact response correlation,
  wrapped foreign symbols and malformed-sidecar refusal pass.
- `lifecycle-material-history-full-*`: **48** checks, including normal creation,
  open signup, personal lobbies, create-and-host, dynamic restart and prepared
  effect journal recovery. The golden genesis/prepared vector changed with
  block-v2; the prior vector mismatch is retained as
  `lifecycle-current-genesis-vector-*`. The local prepared journal's schema and
  exclusion of runtime cache fields are unchanged.

`remaining-tests-compile-inventory` compiles every test module without warnings.
This does not prove their retired runtime API calls are migrated; the larger
consensus/history/foreign-reader modules still need behavioral migration and
verification. Production src/include delta is **+3484/-3644, net -160** at this
checkpoint, including TEST-only seams. Full clean gates, completed-cut review,
observer-worker integration and hardware acceptance remain open. No fleet or
uncertain-operation changes.


### Finality continuation: observer worker, cold join and atomic recovery

The complete Simplex module inventory was deliberately retained as a failed
partial run: `simplex-complete-module-inventory-*` passed 47, failed 12 legacy
fixtures and then cancelled at an old five-argument foreign fetch fixture.
This is not a full module receipt. Migrated crypto/order/pruning controls plus
all current-era controls pass **55** in `simplex-current-era-crypto-pruning-*`.
The preceding run passed 54 and retained the old integer pruning-root failure.

`observer-worker-owned-stage-cleanup-*` passes **66** catch-up/feed checks. A
new integration starts the real feed process, its actual pull worker and the
actual Simplex state machine. Only the remote page endpoint is a controlled
byte source. It verifies a shared group's live/replay origins, append before
credit completion, the actual staged path and feed processing of worker
retirement. It does not claim QUIC hardware evidence; the separate current-wire
endpoint tests cover that seam.

`consensus-trace-explicit-owner-roots-*` passes all **13** tracing checks,
including actual foreign-history workers and expiry of a queued successful
result under its original six-second deadline. The first run retained six
passes and seven fixture failures: missing protocol root, initial readiness
advertisement in the comparison baseline, and passing a store handle to the
configuration-only directory helper. No tracing/authority rule was relaxed.

Two actual cold-join regressions were then reproduced before correction:
- `cold-join-empty-material-baseline-*`: ordinary startup reconciliation
  assumed the configured anchor already had an installed material head.
- `cold-genesis-owned-recovery-baseline-*`: the first verified genesis group
  could not establish custody from the joiner's identical configured root.

The existing owner now keeps payload/membership admission closed while its
material head is absent; its empty pipeline statistic is zero. Genesis can
establish custody from no prior root (startup fold) or from exactly its configured
root (cold join), never from a different or advanced root. The real bootstrap
coordinator test downloads genesis and corroborates its tip, while proof access
stays closed pending Prolog application. `cold-join-genesis-custody-established-*`
passes **136** related checks. No alternate recovery owner or invented material
entry was introduced.

`phase-index-current-reference-fixtures-*` passes all **23** index checks. The
first run passed 22 and retained one old foreign-reference placeholder failure.
Shared founding/Vote/Resolve fixtures now contain linked material and signed
current-era heads. `atomic-inclusion-archived-view-custody-*` passes all **19**
exact-inclusion/recovery checks. A real empty-diff action replaces the former
complaint ledger row when advancing history during an in-flight application
acknowledgement. Captured, concurrent and later acknowledgements stay local;
late delivery cannot create new custody. The first run passed ten and retained
nine fixtures still passing material height to journal reconciliation instead
of archived era/view floors.

Current production src/include delta: **+3502/-3643, net -141**, including
TEST-only seams. The additional 19 net lines since the prior checkpoint express
the previously missing empty-history lifecycle. Larger consensus/foreign-reader
fixture migration, normal-profile recompile, full clean sequential gates,
completed-cut consensus review and hardware acceptance remain open. No commit,
push, fleet mutation, purge or uncertain-operation resubmission occurred.

### Finality continuation: retained results and source selection

Yan reconfirmed that backward compatibility is unnecessary. The unused native
implicit-certificate record and its old fixtures have been removed. Their
still-valid direct/ancestor, wrong-link/root, terminal membership and streamed
ancestry obligations are covered by the current catch-up tests; cross-domain
refusal is covered by the current Simplex crypto tests. Recognizing an old file
header to refuse it before tail repair is format rejection, not a decoder or
compatibility execution path.

Further retained receipts under `_build/finality-resume-20260925/`:
- `retained-vote-material-publication-*`: **3** checks.
- `retained-renewal-era-material-selection-corrected-*`: **7** checks. The first
  selection-file parse failure is retained; it ran no tests.
- `replay-completion-debug-record-layout-*`: **16** checks. The prior run passed
  12 and failed four fixtures because their record introspection needed debug
  information in two override beams, not because replay semantics changed.
- `phase-writer-durable-group-failures-*`: **49** combined checks, including
  four actual owner-sink append/index/publication failure controls.
- `retired-implicit-schema-removed-*`: **99** combined checks, including the
  current maximum-material-plus-compact-witness transfer envelope boundary.
- `foreign-basic-material-reference-v3-*`: **6** checks.
- `foreign-local-lifetime-current-fetch-*`: **15** checks, including actual
  local follow capture, source death, historical committee lookup and restart.

Migrating the transport/tracing controls exposed three actual regressions:
page-delivery spans lost their fetch parent; retained consumption failures were
misclassified; and exact reads reread the freshly downloaded entry from disk.
The current page-consume span covers the actual interleaved decode, verification
and durable group installation. It preserves failure reasons without exporting
payloads. Exact requests retain only their selected immutable result from the
verified group, after append/index/checkpoint succeeds. No retained entry cache
or new owner was added. `foreign-selected-reuse-trace-gates-*` passes **44**
checks, and `foreign-exact-all-delivery-controls-*` passes all **6** direct,
routed, paginated, hint, wrong-phase and wrong-digest controls. Published later
reads still use the durable store exactly once.

`foreign-shared-group-and-confirmations-*` passes **33** checks. A new real
foreign-owner case requests the first material entry in a shared descendant
proof group; the whole group commits and survives restart. Long streamed proofs,
committed-prefix survival after a bad suffix or failed page acknowledgement,
source-behind refusal and confirmation cancellation/deadlines also pass.

Source-selection controls reproduced another integration regression: an empty
answer could end advancement instead of moving to another peer, and a rejected
page could trigger a redundant address of the same peer. `fetch_range` now uses
the existing `quod_peer_route:walk/5`: only pre-consumption transport failure
selects another address. Receipt fixes the source and absolute deadline for its
continuations. The peer walk retains committed progress and selects another
peer for insufficient/invalid history. The extra advancement endpoint loop and
duplicated confirmation endpoint loop are removed. The baseline failure and
an intermediate missed confirmation caller are retained. The four controls pass
in `foreign-suffix-shared-endpoint-walk-*`.

`foreign-current-retained-owner-controls-*` then passes **110** focused checks
at the corrected source tree, including all the transport/tracing/recovery
controls above and moving current views, feed freshness, retained phase sessions,
checkpoint mismatch and explicit corruption reconstruction. These receipts
include overlaps; their counts must not be added as unique coverage. Earlier
migration failures (old fixture arities/shapes, stale tracing targets, two
compile errors and accidentally renamed gate messages) remain alongside the
successful labeled runs. No assertions were weakened to accept those failures.

The earlier `cold-join-normal-production-*` normal-profile compile succeeded
without warnings. A fresh normal compile after these foreign-reader corrections
is still pending. Full consensus/history fixture migration, clean sequential
release gates, completed-cut review and isolated hardware acceptance remain
open. This is still an uncommitted, incomplete implementation, not a release
candidate. Fleet .246 and uncertain operations remain untouched.

The foreign-reader migration is now complete at the module boundary:
`foreign-complete-and-artifact-boundaries-*` passes **194** checks across the
entire foreign-log, entry-selection and artifact-boundary modules. Intermediate
receipts include **13** published-prefix controls, **3** hint/large-archive
controls, **141** foreign-owner controls, **8** historical committee controls,
and **25** remaining delivery controls; these overlap the complete receipt.

The first larger inventory retained 108 passes, three fixture failures and a
cancelled old-arity fetch. Those failures were a genesis-height placeholder for
an ordinary reference, missing debug info for a fixture inspecting record
layout, and retired synthetic skip entries. Two subsequent historical-fixture
failures concerned missing gproc setup and a retired bulk verifier call. The
remaining-delivery inventory retained 21 passes/four failures: fixture DTX
folding without its index, the retired preferred-certificate authority premise,
and a changed adapter exception boundary. No production checks were removed.

The reference-authority control now tests both directions: a preferred head
cannot replace independently verified archive custody, and an actual selected
proof with an invalid signature or the wrong historical committee is refused.
The old duplicate stale/malformed/uncertified current-view test was removed;
all three obligations remain exercised through current framed delivery in
`current_view_rejects_stale_malformed_and_uncertified_pages_test`. Callback
faults retire the worker visibly because consumption may already own committed
progress; blanket exception-to-retry conversion would lose that custody. Real
transport failure/retry remains covered at the credited owner boundary.

The unused `quod_ledger:materialize_hint/1` export/function is removed after
checking all callers. Its former selection-versus-full-authentication control
now invokes the existing full decoder, which still rejects tampering in an
unselected item. The source AST guard enumerates only current construction and
append sites, while retaining its negative controls against hidden constructors,
forged decoding contexts and duplicate decoding. No legacy implementation was
added to satisfy fixtures.

`foreign-source-selection-normal-*` compiled all changed production modules
without warnings before the final deletion of `materialize_hint/1`; the latter
has passed the TEST compile and full related module checks, with its normal
compile still due. Remaining work is the larger consensus/catch-up fixture
migration and the release/review/hardware boundary already recorded above.
No commit, push or fleet mutation occurred.

`catchup-complete-captured-height-control-*` passes all **77** checks in both
catch-up modules. Fixtures now use the shared proof-group verifier and sink,
canonical parent-bound blocks and current credited pull messages. Successful
groups remain committed when a later group on the same page fails. The real
writer tests preserve historical committee lookup and captured-view bounds;
owner death cancels an outstanding recovery worker. The counted 8/64/257
content and DTX suffix controls each verify one new entry with zero old-prefix
reads or reverifications (`catchup-retained-index-current-proof-groups-*`,
52 overlapping checks). Obsolete synthetic skip/implicit-certificate fixtures
are removed; current era/carrier and shared-ancestor proof controls cover their
still-valid timestamp and finality obligations.

Retained migration failures include two fixtures attempting to construct
invalid checked artifacts (now tested at wire import), an obsolete pull tuple,
and one transport fixture reporting different heights inside and outside its
consumer callback. The latter larger run passed 76/77 before the fixture was
corrected. No production assertion was relaxed. A fresh full Simplex inventory
(`simplex-complete-after-catchup-migration-*`) passed 49, failed 11 old fixtures,
then cancelled on an old-arity foreign-fetch fixture. Its log remains intact;
the larger consensus fixture migration is still open.

The current normal-profile production tree compiled with `-Werror` in
`catchup-migration-normal-production-*` (zero warnings). Subsequent source
edits only remove the obsolete TEST-only `eng_with_certs/2` and update the
structural parent fixture to use the engine's existing ancestry calculation.
All callers of the removed helper were migrated; no runtime compatibility
wrapper was introduced. Current src/include delta is +3527/-3673, net -146;
this includes TEST-only helpers and is not a final release delta.

Further focused receipts:
- `simplex-projection-current-material-*`: **8** committee/history/endpoint
  checks; historical membership now uses canonical contiguous material rows.
- `simplex-endpoint-certified-history-*`: **51** endpoint, retained-custody,
  coordinator, history-read and read-attestation checks. The actual writer
  catch-up test verifies and appends a signed DTX group after a real genesis,
  then checks exact durable entry/reference publication. Read attestations
  select real signed material history and preserve the admitted read height.
- `simplex-recovery-material-admission-*`: **47** checks: 12 recovery gates,
  the complete 15-check DTX admission-material module and the complete 20-check
  agent-attestation readiness module. Recovery evidence enters as real signed
  certificates; material height is explicitly distinct from protocol view.
  A preview reference is explicitly refused by the certified reducer; the
  equivalence control binds it to a canonical reference before comparing all
  reducer outputs. Counted no-repeat-work controls remain intact.
- `simplex-child-vm-exact-code-path-*`: **6** checks: canonical block bytes in
  two fresh VMs, malformed nested-map rejection, catch-up wake semantics, and
  the three cached atomic-parent selection controls. Child VMs now use the
  caller's exact code-path ordering and assert canonical bytes/hash, preventing
  stale baseline beams or equal failed calls from satisfying the comparison.

Intermediate failed receipts remain: the endpoint inventory progressed from
27/51 to 38/51 to 47/51 before all 51 passed; the recovery/admission inventory
passed 41/47 before its six retired fixture inputs were migrated. A child-VM
path assertion first compared absolute and relative names of the same file;
paths are now normalized. No such inventory is a full release gate, and their
counts overlap. The larger remaining Simplex/DTX/restart suite migration,
completed-cut review and hardware acceptance still remain. No commit, push,
fleet mutation, ledger purge or uncertain-operation resubmission occurred.

`simplex-migrated-consensus-boundaries-*` passes **136** checks together in
ordinary EUnit order: the migrated leading Simplex cases plus its engine and
membership tail. The six callback fixtures that use their own PID as a fake
transport now drain their ignored outbound frames, fixing the cross-case
mailbox contamination seen in the initial full inventory.

The former mutable-committee weak-certificate tests are replaced by explicit
era controls: certified old-era material retains its old quorum authority;
new-era blocks require the new committee's quorum; neither an old-era share
from a retained member nor a removed member's fresh share contributes. The
former skip-row test now checks one complaint progress edge, one certificate
broadcast, no material rows and duplicate idempotence. These seven controls
passed separately in `simplex-engine-era-membership-*`; four additional real
owner/route-history controls passed in `simplex-engine-owner-material-routes-*`.
The real content-only catch-up control restores routes from a two-validator
signed proof group through the existing writer and historical projection.
The prior tail inventory's 17 passes/11 retired-input failures remains saved.
The middle owner scheduling/relay/restart fixtures are still pending; this is
not a claim that the complete Simplex module or release suite has passed.

Further owner migration receipts (2026-09-26; source still uncommitted):
- `simplex-recovery-owned-notarization-*`: **18** checks. Readiness resumes
  commit intent recorded by this owner on a notarization edge; a planted tree
  row cannot invent that intent. Content/membership and below/above former
  complaint-amplification thresholds are covered. Real journal restart checks
  retain both final-vote choices and the exact supported body.
- `simplex-owner-watch-current-*`: **16** scheduling checks. Material admission
  uses actual notarized parents; peer demand starts the current view's watchdog
  without extending its deadline. Future/foreign/invalid complaint evidence
  cannot wake the wrong work. Placement readiness checks current material
  height, freshness and the exact authenticated inbound generation.
- `simplex-owner-material-history-group-*`: **14** custody/admission checks.
  Recovery verifies and appends a real signed effect transaction through the
  group sink, retires its pending signature, then reopens the journal to prove
  that retirement is durable. Its preceding run passed 13/14 because the
  fixture expected the old two-element return from the current history helper.
- `simplex-ingress-journal-authority-*`: **54** overlapping checks covering
  ingress batching, material-window reopening, transport separation, live stale
  process rejection, protocol progress, real split schedules and vote custody.
  The two unused exported `may_commit/2` and `may_complain/2` implementations
  are removed after checking all source/test callers. The real signing journal
  now tests both conflicting-vote orders across restart, same-vote redrive,
  another view and another era. It is the sole vote-choice authority.

Obsolete cross-slot exclusion, complaint amplification/grace and synthetic
skip-row tests are removed. Their valid obligations are covered by the current
N=8/stacked-split schedules, view watchdog, raw-collection retirement on both
notarization and complaint progress, current-era complaint quorum-subset
controls, the live/recovery archive-group tests, and journal restart controls.
A complaint advances protocol position without producing a material result.
Different genuine quorum subsets advance to the same position. The retired
`run_schedule`/`guarded_vote` model and now-unused dispatch fixture are removed.

Additional retained migration inventories: owner progress first passed 13/52,
then custody-era inputs 9/19; ingress first passed 1/68, then 20/68 after
replacing removed equal-height/frontier fields with explicit installed heads.
The later transport selections passed 14/16 and 30/31 before the remaining
old quorum-watchdog/cache assumptions were updated. The 49-check admission
selection passed 48 before its isolated recovery case started its required
local gproc application. The next 54-check run passed 53: the older journal
conflict test still constructed retired DTX references; it is replaced by
canonical era/view bodies and the real durable journal as described above.
All failed receipts remain in `_build/finality-resume-20260925/`.

Remaining older ingress/relay/restart and other module fixtures still need
migration. No complete Simplex module or release gate is claimed. The latest
production removal still needs a fresh normal-profile compile; TEST compile
and the focused receipts pass. No commit, push, deployment, ledger purge or
uncertain-operation resubmission occurred.

Further current-protocol receipts (2026-09-26): the complete Simplex module
passes **271** checks together in `simplex-complete-current-protocol-20260926b`.
The preceding run passed 270/271: a recovery fixture left its expected inbound
routing reply in the shared test mailbox. It now asserts that exact reply;
the following stale-connection check remains unchanged. The preceding isolated
custody selection passed **38** checks. These counts overlap.

Recovery of simultaneous inbound/outbound work now verifies and appends one
real, quorum-signed history group. Protocol views 1/2 resolve at material
heights 2/3, exact signed custody settles once, and volatile reply hints clear.
The last `new_entry`/synthetic-noop Simplex fixture is removed. The obsolete
preinstalled `approved` scalar/body-gap fixture is retired: current delayed
ancestry, certified-gap recovery and retained-readiness wake controls cover
its still-valid obligations. Old local-exclusion fixtures now use actual
complaint/notarization progress for placement; archived protocol-prefix cleanup
still owns terminal membership exclusion. Signature, author order, original
deadline, link-generation and no-public-retry assertions remain.

Removed the unused material-height argument through recovery re-seating and
reply/cache invalidation, including all callers; decisions use the installed
archived protocol position. Current production Simplex compiles normally with
`-Werror`, zero warnings (`simplex-recovery-args-normal-20260926`). Prior focused
receipts also passed: `simplex-custody-view-readiness-*` (5),
`simplex-relay-restart-placement-hints-*` (7; counted zero destination ledger
reads), and `simplex-queue-current-boundaries-*` (5).

The complete signing-journal module passes **48** checks in
`signing-journal-material-reference-20260926a`: QSJ6 era/view keys, recovery,
compaction, both final-vote orders, retained DTX custody, exact transaction
activation, corruption and explicit old-format refusal. Its first migration
run passed 35/48; one shared shape-only reference incorrectly used genesis
material height 1 for a non-genesis control. It now uses height 2 and a current
finality head. The prior malformed tuple match in the new relay fixture and a
TEST compile guard error are retained as failed receipts too.

The DTX parent-progress and remaining downstream fixtures, complete release
gates, completed-cut review and isolated hardware acceptance remain open.
No implementation commit, push, deployment, ledger purge or uncertain-operation
resubmission occurred. The source is still one uncommitted, unreleased cut.

The complete DTX parent-progress module now passes **68** checks in
`dtx-parent-current-complete-20260926b`. Fixtures use real notarized parents,
exact era/view/hash references, grouped recovery and archived finality replies.
They distinguish protocol view from material height, including a new era at
view 1 over material height 3. Stale-parent verdicts, old-era refusal, validation
expiry and zero history reads for archived proof handoff remain checked.
The preceding migration runs passed 57, 61, 65 and 67 of 68; all receipts remain.
No additional runtime change was needed. Remaining integration/release and
hardware gates are still open; no implementation commit or deployment occurred.

Further complete module receipts: evidence resolver **28**
(`evidence-current-range-verifier-20260926c`), foreign residency **15**
(`residency-current-partial-group-20260926b`), and Explorer **48**
(`explorer-current-artifacts-20260926a`). Tests use the current streamed groups
and compact reference heads. Resident evidence keeps exact immutable claims and
historical committees; malformed references fail before owner work, while an
unused preferred witness cannot invalidate independently verified history.
Streaming progress survives a source disconnect; post-mutation persistence
faults preserve the first complete physical group but invalidate service custody.
The resolver's two earlier 26/28 runs traced retired batch/transfer functions;
positive controls now observe `range_accept/5`. Residency first passed 14/15:
the partial-page fixture selected no bytes by incorrectly using a one-element
chain for height 2. It now uses the same real range adapter as other fixtures.
No runtime change was needed. Explorer no longer manufactures no-op rows and
checks height-only notification suppression and current canonical material.
All failure receipts remain; release gates and hardware acceptance remain open.

Live Simplex Common Test passes **12/12** (`simplex-live-ct-20260926b`).
The prior 11/12 run correctly rejected unsigned history but exposed a generic
badmatch. Startup now propagates the shared verifier's exact failure reason;
its rejection test expects `invalid_transaction` with the material height.
The old bad-certificate unit expectation is migrated to that same explicit error.

The integrated EUnit inventory (`integrated-eunit-inventory-20260926a`) is
**failed**, reporting 2,644 tests, 201 failures and five cancellations; it is not
a release gate. Most grouped failures are remaining old reference, block,
callback and wire fixtures in DTX coordination, read certificates, transport,
foreign custody and lifecycle tests. The full log and extracted failures are
retained. Other findings: an obsolete store magic assertion, rebar's private
escript paths in the fresh-VM codec test, an unscoped proof-ready mailbox check,
and a hosting test parsing an expanded multi-clause policy as one goal. These
are being corrected; no full integrated pass or hardware result is claimed.
A focused migration run first passed 222 checks before an obsolete malformed
reference killed a helper. Its next run passed 331/334; the three remaining
failures were absent debug info in a private test beam and trace assertions
still identifying the protocol parent by material height. No additional runtime
algorithm change was needed. Implementation remains uncommitted and undeployed.

Further migration receipts (2026-09-26): the 334-check downstream selection
reached 332 passes; the remaining two trace fixtures still requested protocol
view 2 after proposing view 1. The corrected group-trace module passes together
with coordinator evidence, foreign lifecycle/custody and resolve endpoints:
**99/99**, `remaining-evidence-current-20260926a`. Real signed evidence, custody
failure controls and waiter delivery assertions remain. No runtime change.
The five isolated broad-run regressions now pass in
`final-fixture-controls-20260926b`: fresh-VM canonical bytes, exact ready ACK,
explicit startup certificate failure, current store/journal magic and ordinary
signed installation of the node delegation rule. The preceding run passed 4/5:
source-file variables needed the existing signed parser's canonical numbering.
No release pass, implementation commit or deployment is claimed yet.

The next integrated inventory (`integrated-eunit-inventory-20260926b`) completed
on its unchanged tree: **3,086 tests, two failures, two cancellations** (3,082
passing markers). The two failures were an old QSJ5 expectation and a readiness
assertion still accepting unrelated anchored identities. The cancellation was
a direct invalid-membership test requiring the removed complaint-to-ledger-row
transition. It now checks no premature exclusion, unchanged committee/height,
and waiter retirement only after distinct later certified work. This does not
claim autonomous terminal rejection of an invalid request without later work.
Full Simplex + operation-format + end-to-end modules pass **280/280** in
`integration-controls-20260926a`, including restart/rebuild and unchanged signer
checks. No production algorithm changed. Multi-node fixtures now choose leaders
by protocol view and retain the material-height assertions; over-f checks observe
real timeout votes instead of the removed quorum-grace policy. Their live QUIC
runs are next. `scripts/overf-recovery-test.sh` still encodes the old grace/skip
contract and must not be used as new-format acceptance without replacement.

Live multi-node receipts: `simplex-quic-current-20260926a` **8/8**, including
>f outage/restart without changing old final votes; `join-quic-current-20260926a`
**5/5**, including cold join, restart and observer-to-validator promotion.
Growth run a passed 5/9: its rotation check assumed one protocol view per write.
The revised check counts actual proposals from every validator (including empty
carriers), exact material heights and no timeout increase. Run b passed 7/9,
then exposed a real failure: dead-member removal reported outcome_unknown;
the final dependent case could not run. No unknown write was resubmitted.

`membership-leader-loss-baseline-20260926a` reproduced the failure independently:
three live voters advance views while the removal origin retains no custody and
never retargets. `membership-shared-custody-20260926a` passes that same real QUIC
case after removing membership's old non-custodied exception. The old exception
in `ingress-owner.md` conflicts with complaint-only view advancement; the explicit
amendment is now in the finality plan §4.5 and remains subject to completed-cut
review. Membership uses identical retained bytes/signature/author sequence and
original deadlines; singleton/parent/Prolog validation remains. No new owner,
queue, message type, re-proof or public uncertain-operation resubmission.

The relay path is consequently one retained-envelope implementation; its old
optional-custody branches and duplicate expiry/retirement pass are removed.
Source/include delta is currently **+3634/-3983, net -349** (before final comment
edits). Full Simplex + format + E2E run `membership-shared-owner-20260926b`
passed 279/280: the invalid-membership test still counted exactly one validation,
although the same retained request is rechecked at each new parent/view. It now
requires an actual refusal and unchanged committee/ledger/custody. The first
attempt had a test syntax error, retained. The old requirement for terminal
`skipped` after displacement is superseded: exact inclusion and original-deadline
completion are covered for both admit/remove in the shared owner test; invalid
membership remains unauthorized and cannot emit a public retry. A new complete
EUnit pass, growth/removal acceptance, release gates, review and hardware campaign
remain open. No implementation commit, push, deployment or purge occurred.

Growth/removal now passes **9/9** (`growth-quic-shared-membership-20260926c`),
including dead-member removal through shared custody. Normal compile and the
updated Explorer bundle build pass. The next complete EUnit run
`integrated-eunit-finality-20260926c` is **failed: 3,084 passed, one failed,
zero skipped** (349.2 s, exact tree unchanged). The sole failure is FIPA
unstarted-request restart: resumed work returned outcome_unknown instead of
the test's required committed result. Preserve this failure and diagnose it;
no request is resubmitted and no release pass is claimed. Added bounded test
failure diagnostics retaining the actual owner and operation outcome.

Retired `scripts/overf-recovery-test.sh`: it depended on removed grace/skip
semantics and an obsolete unsigned API, and incorrectly recommended repeating
an uncertain write. Local outage/restart obligations now use
`simplex_SUITE:over_fault_restart_recovers`; isolated hardware acceptance is
still required and is not replaced by that local test. Corrected the remaining
membership re-proof wording in transaction-signatures.md and stale journal/
Simplex comments. No production algorithm change in this follow-up.

Further retained validation (2026-09-26): the complete hosting module passes
36/36; the original FIPA restart case passes in 20 and then 200 separately
created fixtures. This does not establish why integrated run c returned an
unknown outcome; that finding remains open, with bounded failure diagnostics.
Integrated diagnostic run d passes the FIPA case but still **fails overall:
3,084 passed / one failure / zero skips**, 439.24 s, exact tree unchanged. Its
suffix-verification cost check counted one background signature verification.
OTP tprof documents call_count as VM-wide. A deterministic new test starts an
unrelated verifier during measurement: the old helper fails 2 versus 1; scoped
call_time counts (unchanged exact cost assertions) pass all **8/8** suffix tests.
Receipts: `suffix-counter-background-baseline-20260926a` (negative control),
`suffix-counter-process-scope-20260926b` (pass). No production verification or
deadline is relaxed.

Sequential gate a stopped after remote-scope CT: 40/41. A creation test queried
its namespace before observing the asynchronous effect's completion. Its
existing applied-effect check now precedes the first proof; the focused real
remote-effect case passes (`remote-effect-order-20260926b`). Remaining suites
will run under a separately labelled gate b; neither failed campaign is resumed
or erased. Retired obsolete outage script, reviewed custody/archive call paths
and rebuilt Explorer assets. Read-only Nomad inspection confirms .246 remains
the running application image. No implementation commit, push, deployment or
purge occurred.

Continuation on 2026-09-26: sequential CT inventories passed remote scopes
41/41, Simplex 12/12, fault/restart Simplex 9/9, join 5/5, feed, read-set,
peer-observation and peer-capacity. QUIC's sole obsolete request_page/6 fixture
now uses the current request_page/5 grammar; its focused case passes. Growth c
failed in application startup before running tests (peer call's existing five
second timeout); failure-only stack capture added, growth d passes 9/9. This
is retained as an unexplained startup observation, not a runtime fix. Dialyzer
inventory's nine obsolete-branch/type warnings were corrected after inspecting
callers; cleanup b passes. Xref passes after removing the dead test-only
transaction_submission wrapper. All failed campaigns remain intact.

The full failover suite exposed a concrete liveness defect: four target
replicas restarted and became ready at the same material height, but the source
coordinator remained parked. No new ledger entry meant no progress notice.
`target-restart-recovery-diagnostic-20260926a` independently reproduces it;
source and all four target states are retained. The existing foreign-history
owner now consumes the existing installed proof-ready notification and
reconfirms through its ordinary follower. Notices bind the anchored identity,
current Simplex/Prolog processes and a monotone local generation, so stale or
duplicate notices do no work and same-process rebuilds can wake dependants.
No timer, new owner, additional signing authority or client resubmission.

`target-restart-local-ready-20260926b` passes with the initial correction;
`target-restart-ready-generation-20260926c` passes on the hardened tree (57.71 s,
tree unchanged). The original durable operation completed after target restart
without repeating its signed request. `local-ready-incarnations-20260926b`
passes 34 focused tests including same-height recovery, stale owners/anchors,
duplicates, same-process rebuild generations, directory/ingress and lobby.
Run a failed in the test selection expression before tests ran; preserved.

A fresh clean candidate will now run the complete sequential release checks.
The prior clean-v1 snapshot was never run and predates this readiness fix; it
is not release evidence. The earlier intermittent FIPA deadline failure is
not yet causally attributed to this fix. No implementation commit, image push,
fleet deployment or ledger purge has occurred; .246 and its original uncertain
signup remain preserved pending isolated new-format acceptance.

Clean-v2 stopped at EUnit: **3,086 passed / 1 failed / 0 skipped**, 500.71 s,
source manifest unchanged. The FIPA pending-request restart reproduced with
retained fixture `/tmp/quod_hosted_31CC263A3FBB0570`. Its old resolve-evidence
request had selected foreign routing during the receiver's supervisor gap,
then occupied the existing writer while the fixture had no network transport.
The fixture manually owned supervisors but retained only root in the desired
hosting projection. Production keeps the exact hosting declaration across child
restart. Negative control `fipa-hosting-declaration-negative-20260926a` proves
the mismatch deterministically: stopped receiver returns `not_hosted`, where
this restart scenario requires `not_ready`. The existing production history
view test already pins this distinction.

The fixture now retains each manually hosted namespace's exact anchor in its
existing desired-state fixture, restored by the existing with_host cleanup.
The restart case asserts the no-foreign-fallback state during the stopped gap.
No production route, timeout or outcome assertion was changed for this finding.
`fipa-hosting-declaration-positive-20260926b` passes **77/77** hosting, history-view
and evidence-resolver tests. An atomic operation's terminal receipt may still
name a pending group; the diagnostic comment now states that explicitly.

Corrected current consensus-signatures and content-layer documentation, and
marked finality's deferred entry as implemented under validation rather than
claiming its acceptance closed. Remaining source edits since clean-v2 are
comments/documentation only; the executable fixture correction requires a
separately labelled clean-v3 gate. Current src/include delta is +3707/-4043,
net -336 lines. Isolated candidate/baseline Nomad templates are prepared and
validated, with separate services, seed discovery and volume families. Read-only
inspection confirms .246-c4p1 still runs. No images or cluster state changed.

Clean-v3 passed all **3,087 EUnit tests**, remote scopes41/41, QUIC37/37 and
Simplex12/12, then stopped at fault/restart CT8/9. In over_fault_restart_recovers,
the interrupted write recovered but a new once-submitted write returned unknown.
Offline read-only inspection confirms all four ledgers stop at material height3;
three journals retain empty views4/5 and complaints6..9 while the fourth lacks
those bodies despite the same installed height. The original failed tree and
data remain intact. Diagnostic case a and eight b repeats pass; suite-context c2
reproduces a stall before the first write recovers (c1 passes). Failure-only
owner snapshots cover both stages; d1..d4 pass. Those passes alone are not fixes.

Found a deterministic liveness defect in the same recovery seam: the body-request
selector suppresses any request at/below a known finalizer. But a newer empty
finalizer may have no material entry or selected archive proof at that height.
A real-signature test receives support and commit certificates without that
empty body: negative b fails with zero requests instead of one. Negative a
failed fixture setup before that assertion (gproc missing); both retained.

The existing body-request path now remains eligible within the live protocol
window even after a commit certificate. Its ordinary exact hash, parent and
payload checks restore the engine; no ledger entry, new signer, transport,
executor or client resubmission. Shared missing-body selection also owns the
metric. Positive c passes, including voting restored at unchanged material
height and no archive store. Regression d passes **362/362** consensus/journal/
store tests. Real fault suites e1/e2 both pass **9/9** (66.77/52.63s, frozen trees
unchanged). The retained original failure has no live-owner snapshot, so the
journal correspondence is supporting evidence, not a recovered execution trace.
Clean-v4 will verify the full combined tree. Source/include delta is now
+3716/-4055, net -339. No commit, image publication, cluster mutation or purge.

Clean-v4 stopped at EUnit:3087passed/1failed/0skipped,473.62s, manifest unchanged.
The failure is parent-progress's obsolete expectation that a commit certificate
erases an exact pending body request. The deterministic empty-body regression
shows why that inference is invalid. Updated the test to require the same body
request to remain while retaining its original single-worker, pinned-view,
no-material-advance and no-voting-authority assertions. The explicit request
expiry replaces the fixture's absolute0 sentinel. Parent-progress plus the new
empty-body case pass **69/69** (`finalized-empty-body-owner-20260926f`). This is
a fixture-expectation correction only; production source is unchanged since
clean-v4. Clean-v5 is the next complete sequential release campaign. All failed
runs retained, with no deployment, publication, commit or purge yet.

Clean-v5 passed all3088 EUnit tests, Ask41/41, QUIC37/37 and Simplex12/12,
then fault/restart8/9: the interrupted write recovered, but the immediately
following write returned {not_leader,none}. Captured owner snapshots establish
that its chosen node had material height3 and Prolog ready, yet was still
recovering protocol view5 while the others had view6. Its redirect counter
was1, with no queued or custodied request. A deterministic negative reproduces
the same local-entry rejection during unconfirmed recovery.

The existing ingress queue now holds structurally valid unsigned local work
through temporary recovery and history re-seat. Original arrival/deadline and
proof remain unchanged; drain revalidates before signing. It grants no voting,
proof or application permission and adds no owner/retry. Relayed placements
still clear at re-seat, with their original source custody unchanged. The
positive regression proves no signing while unready, exact queue retention,
one readiness-driven drain and one resulting custody record. The old test
that expected unsigned recovery rejection is replaced by this obligation;
far-finalizer testing now expects parking and still asserts no voting.
Negative a fails as expected; positive b passes. Focused c has285pass/1obsolete
redirect assertion; corrected d passes361/361 (ingress, consensus, Prolog,
metrics). Real QUIC fault/restart e passes9/9 in63.79s, frozen tree unchanged.
Removed the superseded Prolog membership-skip retry clause and metric label;
all locally signed membership now uses custody. Source/include+3739/-4086,
net-347. Clean-v6 will validate the resulting complete tree.

Separately founded an isolated .246 baseline network, with new job/service/
volume identities. Initial Nomad health preceded founder replacement; the
controller now checks current job version. No original exec reached the VM.
After two successful root admissions, the old binary returned {error,retry}
on admission3. Baseline setup is stopped with the original reply and eight
read-only inspections preserved; no request is repeated, no workload run,
and no performance claim follows. Production job quod, old uncertain signup,
all production volumes and image tags remain untouched. No implementation
commit or candidate publication yet.

## 2026-09-26 — finality validation continuation

Clean-v6 passed all3088 EUnit tests, Ask41, QUIC37, Simplex12, fault/restart9,
join, growth9, feed2, readset3, peer observation and capacity. Agent failover
stopped4/5: its immediate prove_ro after applied-height synchronization raced
an actual rebuild. The fixture now uses its existing event-driven await_goal
under the same total30s allowance and requires height at least the committed
height. The claim-delivery consequence assertion uses that same correction.
Focused validator-host-loss c passes1/1 (47.86s). Attempt a overlapped the
finishing v6 suite and was interrupted: its zero shutdown exit is NOT a pass.
Attempt b caught an overstrict fixture equality (a map-pattern match allows
named variables); corrected map/height/goal assertions pass c. All failures,
stop markers and fixtures remain. No production readiness change for this.
Remaining inventory (namespace/names CT, xref, Dialyzer, prod/diagnostic builds,
UI build/lint and diff checks) passed sequentially on unchanged source.

Isolated .246 baseline v1 stopped at old membership retry (no resubmission).
v2 exposed an invalid benchmark guard causing expected predicate-read OCC
conflicts. Its failed writes/receipts are preserved; v3 uses ordinary blind
append of unique IDs. V3 completed three c1/c4/c16 local/remote write repeats
without write failure. Its aggregate readback crossed the existing16KiB result
budget at449facts; read-only diagnostic proved too_large/result (16584bytes).
Replaced the acceptance oracle with existing signed cursors, not a larger
budget or split domain transactions. Original readback failure remains, with
separate successful exact-ID/no-duplicate reconciliation. Follow-on-a ran only
new stages; its first atomic c4 batch stopped after2commits/3explicit conflicts.
Those results are not a successful atomic-performance baseline.

That oracle independently reproduced an existing forwarded-cursor defect on
.246: open succeeds, first Next returns404. The router's short-lived opening
worker owned the network stream; its exit closed the stream and cursor.
A deterministic negative confirms that owner mismatch. The existing router
now acquires existing explicit pinned-link leases asynchronously, forwards
correlated acquisition notices to its workers, and retains a cursor's lease
in its existing route until termination/expiry/loss. Noncursor completion
releases its own exact lease; transport monitors already release on router
death. No second cursor/executor/table or protocol format change. Regression
checks open/Next/Stop, failed open, ordinary completion, session/peer/link
binding and uncertainty:53/53 pass. Initial regression c consumed an earlier
fixture's unscoped diagnostic notice; d/e scope those notices by exact link,
with all evidence preserved. Source/include delta +3789/-4101, net-312.

Clean-v7 will validate the complete source, including the cursor ownership
correction. Production remains .246-c4p1, with old signup evidence and all
production data untouched. No implementation commit or candidate image yet.

Clean-v7: all25 sequential commands exited successfully, including3089 EUnit,
Ask41, QUIC37, Simplex12, fault/restart9, growth9 and agent failover5. The final
whole-tree freeze check correctly failed: UI rebuild inside the nested clean
checkout auto-detected extra Tailwind source files and replaced four generated
assets/entrypoints. No Erlang, test, client or UI application source changed.
The original failed final receipt and generated output are retained. Explicit
Tailwind source registration now restricts utility discovery to ui/src; the
main-tree rebuild reproduces the previously committed/generated assets exactly.
This is a CSS build-input correction only. A separately frozen packaging pass
will verify clean UI reproducibility and both releases, inheriting the25 v7
command results only for scopes whose exact source hashes remain unchanged.
No full backend rerun is needed for that CSS directive. Hardware baseline v3
and its separately labelled follow-on/serial/observed campaigns are retained;
all baseline containers are now stopped with their volumes intact so candidate
measurements run without their competing background load. Production untouched.

## 2026-09-26 — first finality hardware candidate and retained failure

Packaging-v2 passed clean UI reproducibility and both release builds, with
explicit byte-identical backend/client/application inheritance from all25
successful clean-v7 commands. Original v7 freeze failure and packaging-v1 setup
failure remain retained. Independent completed-cut review bound manifest
034a7334eed01a574238d5777e14b24e613894e89beae5d3ce581c7a1f4f5412.
Committed/pushed bf29c1b, published immutable finality-bf29c1b-v1, and founded
isolated8-node candidate. Production quod remains .246-c4p1 untouched.

Candidate passed actual forwarded cursor open/Next/Stop, isolated local/remote
writes, all3 repeats of64 local/remote writes at c1/c4/c16, and3 certified-read
runs, with exact fact-set/no-duplicate readback. Remote means improved but p99
still misses450ms; local throughput is mixed. No performance acceptance claimed.
Atomic c4 stopped after4 pending/uncertain original operations. None resubmitted.
Bounded archive inspection found both first votes promptly, source Resolve at
+165ms, but target Resolve only about87s later; finally1group committed and3
aborted. Two refused-source operations still report pending via original-operation
lookup despite group Complete records. This remains an explicit investigation,
not silently reclassified as a passing cohort.

Idle traffic then grew, node2 was OOM-killed and its restart failed once.
Nomad task events, memory/mailbox summaries, outcomes, ledger tails and all
original request journals are retained under hardware-candidate-v1. A separate
C/D diagnostic failed during trace setup because that task was down: no new
C/D goal was submitted, and started observers were cleaned up. The isolated
candidate is now stopped with all8volumes retained; production untouched.

Deterministic negative proves finalized empty proposals retain volatile local
work and incorrectly keep the watchdog active after useful work is complete.
Reuse proposal/custody-placement cleanup for zero-material finality, separately
from archive/journal-prefix retirement. No row, signing permission, deadline or
fresh request is introduced; exact proof/journal custody remains. Negative-v1
was a rebar CLI selection mistake; negative-v2 fails the intended idle assertion.
Positive-v1 passes; focused consensus/ingress/journal/DTX-owner345/345 pass.
Real fault/restart and new release checks are next. The atomic delay and hardware
resource failure are not yet claimed causally resolved by this correction.

The first correction also passes the real4-node QUIC fault/restart suite9/9.
Clean-v8 freezes this small lifecycle correction and repeats the required
sequential release gates before another consensus commit/candidate publication.

Clean-v8 passed all25 sequential checks, including3090 EUnit, real fault/restart,
agent failover, xref, Dialyzer, both releases and reproducible UI. Independent
review bound manifest1c81ba46fea1f09b2664819e748df0531972b4112f043715b36a0afcf1f071ea;
committed/pushed cb6436a and deployed immutable finality-cb6436a-v2 to a fresh
isolated8-node candidate. Production .246-c4p1 remains untouched.

Candidate-v2 passed forwarded cursors, both isolated writes, all3x64 ordinary
local/remote c1/c4/c16 runs and3certified-read runs, with exact readback. Remote
latency regressed against both prior runs; this is not performance acceptance.
The first atomic c4 diagnostic again returned4pending originals around30s.
No original was resubmitted. Source decisions were recorded within1s; target
Resolve/Complete followed around90s. Original-operation read-only lookup finds
1commit/1abort;2refused-source requests still lack permanent operation claims,
as explicitly required by the current prepared-source-only claim contract.
The original replies retain their group IDs. Do not fix that boundary by letting
arbitrary refused votes reserve request identities. All4groups have terminal
ledger records. Candidate-v2 is stopped with its8volumes and all evidence retained.

The empty-finality cleanup is independently confirmed:32hosted instances show
zero view/proposal/timeout changes and idle/no-demand state across the15s
observation; sampled large mailboxes are empty and no task OOM is observed.
Atomic failure therefore has a separate cause. Its event metrics record1854
checkpoint writes consuming48.09s summed across nodes in the first30s, versus
7.41s for1856ledger appends. The previous path checkpointed fetched pages; the
new archive path moved that work inside every group. Page-fetch timing includes
consumption, so it must not be mislabeled network time. The actual cold-history
stall is not solved or causally exhausted by these aggregate durations alone.

Restore checkpointing at the existing bounded range/publication boundary.
Keep group proof verification, append datasync, phase-index deltas and accounting;
checkpoint every advanced returned prefix, including transport-error prefixes,
and invalidate on checkpoint failure. No new writer, format, timer or allowance.
Negative regression sees2checkpoints for one range; positive passes the retained
failure/partial-prefix suite16/16. Extend counts across2/64/257-entry fixtures.
Focused-v1 named a nonexistent old test module and ran no tests; retained setup
failure. Focused-v2 uses the actual foreign-history/catch-up modules. Hardware
confirmation and release review/checks remain pending for this second correction.

## 2026-09-26 — coherent correction after the hardware review

Yan authorized fixing the verified review findings together. Exact foreign
claims and progress now share indexed genesis/era succession and selected-entry
proof verification; only facts projections acquire the complete material
archive. Projection acquisition uses that same current-tip verifier. Canonical
blocks sign their material height (block3, V9 archive, QSJ7 journal, cache7).
No legacy decoder or second owner is introduced. Material ranges copy complete
groups and perform one sync, index installation, checkpoint and accounting
handoff. Explicit startup verifies and retains complete groups beyond a saved
checkpoint. Healthy notarization no longer creates a carrier; recovery carriers
require complaint-driven progress. Finalized protocol views leave periodic
redrive while retaining signing/proof custody, and existing readiness links
recover missing QCs at unchanged material height.

Known distributed group references can be retained by the browser and observed
through the existing signed outcome endpoint, after checking the archived
source Vote against the original signed request. This does not create a
prepared operation claim or authorize resubmission. Loss of both the Execute
reply's group reference and any prepared claim remains explicitly uncertain.

Focused production-seam tests cover sparse membership authority, long proof
streams, range durability, startup suffix retention, owner death and persistence
failure. The old full-prefix test fixtures are being migrated to explicit facts
demand where their obligation is archive custody. A real shared-call deadline
regression was found and fixed: expiring one caller must not shorten the page
budget of work another caller still owns. All18 page-credit/owner cases pass,
as do the associated tracing checks. Failed runs and frozen sources remain
under `_build/finality-resume-20260925/`. Completed-cut release gates, independent
review and new isolated hardware measurements are still required. No new
commit, image or production deployment yet; production .246-c4p1 and all original
uncertain operations remain preserved.

The remaining foreign-history fixtures now use actual sparse proofs or explicit
projection demand as appropriate. Routing tests found and corrected committee
contact protection still consulting material state instead of verified authority.
Timing attribution retained its90% assertion: a redacted trace identified cold
caller setup and owner admission outside the previously counted intervals.
Those intervals now have explicit metrics; the existing ledger-sync stage is
also registered, and obsolete nomination/confirmation branches were removed.
All41 focused metrics/tracing cases pass. The browser bundle was regenerated.
Clean-v10 freezes this complete tree for the required sequential release gates.
Independent authority/storage review memos and all failed runs remain retained.

Clean-v10 stopped at EUnit with3107passes/11failures; no later gate ran.
The failures exposed remaining test contracts: old archive/journal magic and
genesis vectors, sparse-proof fixtures still expecting a material-prefix walk,
the changed phase/current-view shape, the artifact boundary inventory, and a
router statistics assertion racing worker cleanup. Corrections retain the
original safety assertions and observe actual cleanup delivery. The artifact
inventory now also guards the batch append boundary. Focused corrected cases
pass; a new exact freeze is required before release. Production remains unchanged.

Clean-v11 passed3117 EUnit cases and exposed one intermittent test-ordering
failure: the corruption fixture read its deliberately injected height before
the owner diagnosed it. Both affected tests now await actual projection refusal,
the held initializer and its installed result, checking that reconstruction is
counted exactly once. Both focused cases pass; production bytes are unchanged.
Clean-v12 will repeat the release gates on this corrected frozen test contract.

Clean-v12 passed all 25 sequential gates: 3118 EUnit and 145 Common Test cases,
client tests, xref, Dialyzer, both release profiles and reproducible UI checks.
The reviewed 721-file manifest is
`0e2dc6b69489ed9fd1f12c96c9f257db4c155a75ce64027b37e9882df2e6fe7f`.
Commit `993dc30` is pushed and its immutable prod candidate image is published.

Matched isolated hardware runs each verified 1401 healthy requests. The first
cold atomic pair after 1000 source writes fell from 5,181 ms to 333 ms; this is one
matched sample, not a stable percentile. Candidate cursor, retained-volume VM
restart, system catalog, paused-proposer recovery, membership removal and
re-admission, and two normal browser signup/console/reload flows passed.
The final contention diagnostic retained its failed workload exit: 5 submissions,
2 commits and 3 explicit pre-claim conflict refusals, with exact consequence
readback and no resubmission. That run did not exercise a refused-source
GroupRef outcome. All original failed harness and measurement runs remain.

F2 performance approval remains open. Remote c4 p99 improved from 1,038 to 766 ms but
misses 450 ms; local c4 had four clustered 766–921 ms tails. A separately labelled
128-request diagnostic passed exact readback, with local p99 260ms and remote
p99 858ms. It does not replace the original measurements. All 64 remote traces
attribute mean 556 ms HTTP time to identity 20 ms, scope opening 118 ms, source
claim 127 ms, result wait 236 ms and 55 ms around admission/sealing/return. A shared
418 ms page-acquisition wait explains the three slowest scope openings; the
trace does not split its source/storage/transport components. No material
prefix replay occurred. The original local tail also coincides with two slow
journal syncs, but its requests were unsampled, so causal attribution is incomplete.

The current-tip verifier unnecessarily fetches a preferred source before
starting committee confirmation and then fetches that source again. Its
replacement keeps one concurrent collection of verified exact-tip responses,
preserving committee authority, distinct-member quorum, higher-tip handling,
deadline and cancellation. This source refinement is in progress and requires
its own tests and review before commit; the passed `993dc30` evidence is unchanged.
Production .246 remains untouched. Old volumes and the original uncertain
signup are retained, with a protected archive under
`_build/finality-resume-20260925/old-network-archive-v1/`. Prepared .247 build
and clean activation scripts have not run.

The concurrent collector refinement now passes 227 focused tests: 187 foreign
proof/lifecycle cases, 19 tracing cases and 21 metrics cases, with production
and test compilation under warnings-as-errors. Evidence is
`_build/finality-resume-20260925/collector-full-focused-v2/`; the runner asserts
the loaded modules' exact paths and records their hashes. Earlier failed runs
are retained. Five old fixtures depended on serial fetching; correcting them
also exposed a real moving-feed regression in the first collector revision.
The corrected collector retains both the verified basis and the required
height, checks installed progress before completing a probe quorum, and keeps
the same job as the tip advances. Feed observations grant no proof authority;
unchanged observations cannot start repeated requests. The original absolute
deadline reaches the owner unchanged.

Review also found that an older malformed-page test never consumed its intended
payload. It now verifies a valid sparse proof first and asserts actual consumer
rejection of stale, malformed, uncertified, dishonest-height and truncated
responses. A focused runner initially loaded the wrong test beam; those results
were invalidated and replaced by explicit-path runs, preserving the originals.
The final production delta is 158 added and 83 removed lines in the existing
foreign owner, net +75. The removed serial discovery/confirmation path is gone;
the extra lines track concrete query dependencies and preserve progress during
concurrent collection. No production module, process, protocol format or cache
was added. Clean-v13 is the next release boundary for this exact source.

Clean-v13 stopped at EUnit with 3,125 passes and two failures; its frozen tree,
logs and exit are retained. Production remains byte-identical to the reviewed
collector. Both failures concerned old fixtures. The single-member residency
fixture could no longer refuse confirmation after its first valid reply; a
four-member version now proves genuine quorum failure, preserves material H1
and certified H2 separately, then confirms H2 from three ordered feeds without
fetching. All 21 residency tests pass.

The network-dependency fixture failed in its simulated sender before the
receiver consumed a proof. Its obligation belongs to material validation;
certified point evidence uses the accepted admission-trust contract in §0.
The corrected fixture prebuilds the remote bytes, checks current evidence with
no local network identity, and checks that actual material consumption refuses
that dependency without trying another source or installing the signed entry.
The fresh test VM now explicitly loads the same beams as its parent: a parent
load alone did not reorder the child's inherited search path. Clean-v14 will
bind these corrected tests and the unchanged production source. The renamed
material-dependency test passes in its fresh VM with explicit parent/child beam
binding; both fixture corrections have independent review.

Clean-v14 stopped at 3,126 passes and one tracing-test failure. A controlled
comparison found only independently sampled readiness timestamps differed;
two untraced callbacks reproduce the same difference. The test now checks each
timestamp against its own callback interval before comparing all remaining
state and actions, preserving the tracing assertions. All 13 consensus tracing
tests pass; no production code changed. The original failure and causal evidence
remain in `clean-v14-trace-triage-v1`. Clean-v15 binds the corrected fixture for
the release gates; deployment still requires isolated hardware acceptance.
