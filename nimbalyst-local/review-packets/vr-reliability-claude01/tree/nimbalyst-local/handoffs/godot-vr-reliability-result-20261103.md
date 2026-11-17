# Offline VR supervision result — QUO-66

Only the removable launcher's reporting changed. Companion04's original
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

The actual Python event loop printed INTERACTION_READY even when its
supervisor had already stopped for authentic expiry or a blocker in the
same event batch, and even without visual admission. Baseline02 reproduces
those three failures and the missing explicit rendering-only report.

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

## Verification and retained failures

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
- 8 checks executing the actual live event-loop/wait AST with synthetic OS
  events: rendering through 30 seconds to the original 180 cutoff, separate
  visual/interaction milestones, late readiness rejection, uncertain finish
  never retried, and repeated close waits retaining the same 60 deadline.

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

Only one inherited file changed: live.py, +8/-2 physical lines (net+6).
Production delta 0. New check_live.py 155, AdmissionChecks.cs 94 and qualify.py 118
lines exercise the existing loop, C# block and pipe owner without starting the
application; test scaffolding growth is not a production reduction.
The pre-existing tracked binary diff remains byte-identical. Of 95 inherited
evidence paths checked, all 94 other paths remain byte-identical, including
the failed visual02 receipt, manifests and old qualification claims.

The complete exact path list and hashes are in
[changed-files.json](../../doc/evidence/godot-vr-reliability-20261103/changed-files.json);
source before-copies, full logs, generated checks and receipts are retained.
The separate snapshot is `/tmp/quod-vr-reliability-24781f1a-20261103-01`;
its source archive is verified by reconstruction and byte comparison.

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
