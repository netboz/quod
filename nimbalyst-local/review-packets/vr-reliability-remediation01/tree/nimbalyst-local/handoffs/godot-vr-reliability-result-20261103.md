# Offline VR supervision result — QUO-66

The removable launcher reports readiness and pre-admission failure accurately.
Companion04's original
preparation 180/authentic-expiry/participant 1800/normal-close 60/outer 2100
supervision, one-close paths and uncertain-write fences passed offline checks.
No product policy or production source changed. No XR, fixture, headset,
SteamVR, host input or human test was launched.

Session `24781f1a-c144-44b4-8f2a-83074305649c`, branch
`worktree/pearl-stone`, HEAD `293cf6115c0a6b18315eccdbb42cbca396f443d3`.
The available system identity is GPT-6-based Codex; the exact backend variant
and effort are not exposed to this session. The coordinator and previous
implementation session were idle before editing; QUO-66/65 radar returned
no recent activity. Read AGENTS, multiwrite architecture, retirement250,
the failed visual02 receipt, and QUO-60/65/66. Linked this session to
[QUO-66](nimbalyst://QUO-66); broader M5 acceptance remains unchecked.

## Demonstrated defect and correction

Finite synthetic events in the actual Python loop reproduced INTERACTION_READY
after authentic expiry, after a blocker in the same batch, and without visual
admission. Baseline02 also reproduces the missing rendering-only report.
These are injected schedules, not observations from visual02. The blocker and
READY-without-VISUAL schedules are defensive cases that companion04 cannot
normally emit; readiness delivered at an authentic cutoff is reachable.

[live.py](../../doc/evidence/godot-vr-visual-readiness-20261102/live.py) now
reports the first stereo frame as RENDERING_ONLY, with both readiness claims
false. It reports INTERACTION_READY only during the admitted, unstopped
participant interval. Repeated/rejected visual markers are identified as
observations that did not start an interval. Raw child records remain intact.
This does not duplicate or replace the C# readiness predicate or grant input.

The original visual02 remains BLOCKED_CLOSED: 236 stereo frames, SteamVR
Visible, never Focused, no supported controller profiles. Rendering evidence
is present; visual admission, interaction readiness and headset pixels are
unestablished. Yan's later SteamVR crash still has no established cause.

## Original verification and retained failures

[offline03 receipt](../../doc/evidence/godot-vr-reliability-20261103/offline03/result.json)
and [outer receipt](../../doc/evidence/godot-vr-reliability-20261103/offline-wrapper03/result.json)
record all five build/check child exits 0 and outer 0, elapsed 4.367820943s.
There are 114 assertions/cases across the following finite checks:

- 34 checks of the exact FrameObservation source; Visible rendering cannot
  substitute for Focused/head/world/receiver/unexpired visual admission.
- 12 cases executing the extracted, byte-identical companion04 admission
  block with synthetic stdin, application-close and rendering-event seams.
  Finish/stop/blank/EOF before, after and coincident with visual readiness
  each call close once, retire the reader and remove the subscription.
- 33 unchanged Supervision checks: absolute preparation/participant/expiry,
  no renewal or interval restart, stale/late markers and uncertain begin.
- 27 unchanged OwnedCommands checks using seven real harmless pipe children:
  exact incarnation/mapping refusal, late begin, original bounds, one delivered
  finish, actual child 0 and both EOF for each child.
- 8 Python tests: six execute the live event-loop AST with synthetic OS events,
  one drives Supervision directly for uncertain finish, and one executes the
  extracted wait helper for the same absolute 60-second close deadline.
  The original six loop tests did not cover VISUAL_READY at exactly 180 seconds.

Companion04 manifest SHA256 is
`16d2c211c6687494bcf188f249c88ba054c1bcd8b97b685e56c936b46cc0cef7`.
All 98 live inputs and 100 supplied saved sources matched; four managed export
files matched the manifest. Its five saved build phases were 0. The entire 196
file native export was not re-audited and the application was not run.
Compilation used the existing hash-verified offline dependency archives.

All unsuccessful attempts are retained under the new evidence root:
baseline01 exit 1 (three reproduced failures, missing reporting assertion and
one missing test identity stub); baseline02 exit 1 (four cleanly reproduced
reporting failures after fixing the stub); offline01 exit 1 (qualifier expected
closure281 in the owner directory rather than the staged evidence input);
offline02 build/outer 1 (empty offline feed lacked the SDK's AspNetCore reference).
Those setup defects were corrected in the new qualifier. No application or
human run was retried. live-final01 exit 0 preceded the complete offline03 pass.

## Scope and remaining limits

At the original checkpoint, only one inherited file changed: live.py, +8/-2
physical lines (net+6). Production delta 0. The original check_live.py 155,
AdmissionChecks.cs 94 and qualify.py 118 lines exercise the existing loop,
C# block and pipe owner without starting the application. The post-review delta
and current checks are recorded below; test growth is not a production reduction.
The pre-existing tracked binary diff remains byte-identical. Of 95 inherited
evidence paths checked, all 94 other paths remain byte-identical, including
the failed visual02 receipt, manifests and old qualification claims.

The original exact path list and hashes are in
[changed-files.json](../../doc/evidence/godot-vr-reliability-20261103/changed-files.json);
source before-copies, full logs, generated checks and receipts are retained.
The original snapshot `/tmp/quod-vr-reliability-24781f1a-20261103-01` and
offline03 stage `/tmp/quod-vr-reliability-jpc_8a2z` no longer exist. Their
archive/reconstruction and compiled outputs cannot now be inspected. Original
receipts retain their historical claims and stale paths unchanged. The surviving
[review packet manifest](../review-packets/vr-reliability-claude01/manifest.json),
SHA256 `9c738b4fdb4cb9683eff6d5cecfbdad31fc9724f54aa045b24124657df404bf8`,
anchors 102 preserved files, including all 88 original saved content hashes;
it does not recover the lost archive or original DLL.

## Review corrections — 2026-11-03

The requested Fable review found no new correctness defect in the initial
reporting change. Its missing boundary test exposed a pre-existing failure
classification defect: a VISUAL_READY at the absolute preparation cutoff (or
earlier authentic expiry) stopped the owner but bypassed the quiet-timeout
failure assignment. With a synthetic successful child/EOF, the wrapper could
therefore report success. Quiet expiry was also mislabeled as preparation timeout.

The loop now classifies those pre-admission stops after either exit path using
the actual owner reason. No owner, readiness predicate, close/write behavior or
deadline changed. Rejected visual/interaction rows are asserted field by field,
including a reachable visual marker exactly at started+180 and quiet/event
expiry at the same deadline. The wrapper exit expression is exercised with
explicitly synthetic exit/EOF inputs, not a native teardown claim.

[Review baseline01](../../doc/evidence/godot-vr-reliability-20261103/review-fixes01/baseline01/result.json)
retains child/wrapper1 and four assertion failures: two missing classifications
and two old labels (one merely updates the expected preparation wording).
Its exact launcher/test sources are preserved. Focused live-final01 passes0.
[Review offline01](../../doc/evidence/godot-vr-reliability-20261103/review-fixes01/offline01/result.json)
and [wrapper01](../../doc/evidence/godot-vr-reliability-20261103/review-fixes01/offline-wrapper01/result.json)
pass all five child exits0 and wrapper0, elapsed5.299574896s. Counts are
34 frame checks +12 admission cases +33 supervision checks +27 pipe checks
+10 Python tests =116 mixed checks/cases/tests. Of the ten Python tests, eight
exercise the loop (expiry uses two subcases), one the owner directly and one
the wait helper. Seven real harmless children exit0 with both streams at EOF.

The qualifier now stages under the workspace's ignored _build directory and
executes its five saved compiled artifacts from the persistent evidence tree.
All twelve admission case directories are retained and indexed; this run wrote
four visual-ready.json files. The hashes of the DLL, supporting outputs and case
files are in the receipt. The old DLL remains lost; this is a separately labeled
new build. The qualifier disables ASP.NET certificate generation and the first-run
banner, drops the obsolete first-run switch, and records these settings. Its new
build log contains no certificate-installation message. This is not a general
claim that the earlier run made no writes outside its stage.

Exactly four existing files changed after review: live.py (+2/-1),
check_live.py (+49/-5), qualify.py (+15/-4), and this handoff. Current source
line counts are173/199/129 respectively; AdmissionChecks.cs remains94 unchanged.
Total launcher delta against the original inherited file is+10/-3 (net+7).
Production delta remains0. The new test growth covers the demonstrated boundary
failure and returned fields; qualifier growth retains executable evidence.
The new exact path/hash list and persistent reconstruction receipt accompany
[review-fixes01 result](../../doc/evidence/godot-vr-reliability-20261103/review-fixes01/result.json).
No old failed evidence or frozen review packet was overwritten.

The BLOCKER handling remains: the inherited earlier companion emits that marker
and the shared owner still has callers; companion04 alone does not establish dead
code. The pre-existing pycache is user-owned and untouched. Remaining coverage
limits are native concurrent render callbacks, parent stdin/compositor branches
and the simultaneous case's winning branch. No native/hardware result follows
from the synthetic closes or wrapper decision.

No native close/noEOF failure was reproduced, so these results do not resolve
intermittent Godot shutdown, retained native pipe writers, SteamVR focus,
controller availability, the later crash, headset visibility or usability.
No fixture was started or stopped; the existing literal fixture-stop contract
was not changed. The old run cards and prepared-card hashes describe their
original sources; no refreshed human-launch card or new launch is authorized.
No release gate, build/export of Godot, package mutation, deployment, commit,
unrequested consultation or inventory capability change occurred.

Tracker metadata/local progress saved, but the tool explicitly reported
collaborative body publication failure. This handoff retains the completed
checkpoint and evidence; shared-body visibility is not claimed. No duplicate
ticket was created and no broader acceptance was closed.
