# XR desktop-focus correction — software result

The chosen runtime-focus behavior is implemented. Desktop focus-out cancels the
current XR pointer, menu and travel work; it no longer keeps controller input or
models paused. Neutral is still required before another gesture. Window
visibility, native Focused/running, head/source tracking, signed mapping/profile,
world/context and retirement gates remain.

The user decision is the real desktop response1793386451990, `runtime_focus`.
AGENTS, the current native/controller contract and multiwrite architecture were
read before the change. Fable's complete118 report and parent dispositions were
read; its broader visibility-removal recommendation was not implemented.

## Exact source scope

- Production: Main+1/-2 and OpenXRInput+6/-7, total2files+7/-9.
  `applicationFocused`, `Focus(bool)` and the focus-in call are removed.
  Main's focus-out calls `DesktopFocusLost`; it retains ordinary desktop GUI and
  scene input cancellation. The same `Advance` owner now takes explicit session
  focus/API-running/head-tracking predicates from `_Process`. There is no second
  input policy/state machine, forced model visibility, focus command or fallback.
- Tests: ControllerChecks, ControllerLiveChecks and PhysicsChecks+54/-17.
  The latter two only bind the existing injected calls to the explicit predicates.
- Existing input README+7/-2 documents the approved behavior and retained gates.
- SpaceChecks is byte-for-byte restored after a failed test-placement candidate.
  All92 current supplied inputs exactly match selected final01.

Core189, server1432, engine02310d and Monado59be are unchanged. No engine/server
build, core/server recount, old API read, native runtime, physical case, HDMI
action, human question or external review was performed.

## Actual qualification

The new baseline assertion was run against unchanged pre-correction product code
in `xr-focus-baseline-controller02`. It failed client/wrapper1 exactly at model
continuation after desktop focus loss. Eight prior obligations passed, including
immediate native GUI capture cancellation without activation. Both real streams
reached EOF; no reader error, watchdog or stack capture occurred.

Selected clean source-only export `xr-focus-final01` has92 supplied inputs,
196 exports and five build/restore/export commands0, with full logs. No compiled
application input was copied. Product source has no diagnostic override or phase
tracing. SDK10.0.112/runtime10.0.12, eight pinned dependency archives and private
engine02310d are bound by the manifest.

Manifest SHA: `7ef7be0674e284ed7adf85462915975fe1a8c2bd4a122ec833a68f079e784ec3`.
DLL SHA: `2f08c1ab20a8df7667a7b8f95dfea904511f6ffe7f5b4fd4dade212c23813523`.
PCK SHA: `47a3cd3e5c886bb13b465533393fb2f994fc8fcd9217bfd344e006ee85842a7e`.

Sequential headed software results on that export:

- Controller67PASS, client/driver/wrapper0, two child and two wrapper EOF streams.
  Real XRServer trackers, Router, native GUI, imported model/resource and scene
  owners are used. Focus-out cancellation, cancelled-release/no replay, neutral
  new selection/menu/travel, native focus/API-running/head withholding, visibility,
  mapping/profile/current-pose loss, monotonic-frame fences and repeat cost are
  covered. Native predicates are injected into the same production `Advance`
  seam; this is not a native API or hardware integration claim.
- Presentation15PASS: five `Check` entries plus ten `Probe` entries; actual shaded
  renderer rasters, unchanged materials/resources and aspect/resize seams.
- Scene15PASS: real geometry, raster, exact picking and withdrawal seams.
- Controller lifecycle:2acquisitions/2releases,2instances/2released,1decode/1texture,
  zero final leases/templates/subscriptions/sources/appearances/captures. Ordinary
  application exit/EOF occurred. No native teardown acceptance is inferred.

An additional ordinary desktop menu check is **FAILED/inconclusive**. First,
the exact cursor guard refused a point requested at2218,612 but observed2218,576,
before clicking; client-9/wrapper1/EOF flagsfalse are retained. A separately built
final02 moved only the test pointer probe higher. Its next menu run instead lost
the exact owned focus during the third native key delivery, before that probe;
client-9/wrapper1/EOF flagsfalse are retained. Initiator/cause is unproven. The
probe change was reverted, no guard was weakened, and there is no further retry.
Final02 is retained and is not the selected source/export. The two failures do
not erase the passing controller/native-GUI obligations or establish a product
cause. Broad software acceptance is not claimed.

All pre-stage helper-import/custody failures, the expected baseline failure and
the metadata-only binding01 count error are preserved with separate labels and
dispositions. Corrected binding02 is0 and does not replay tests or builds.

## Custody and remaining limits

Evidence is `doc/evidence/godot-m4-xr-focus-20261030/`. New stages, cold outputs,
private profiles, stdout/stderr and original source copies are under the private
Data task root. Pre-execution helpers and true exits are retained. Unchanged
objects use authenticated strict-stat custody. New source/export objects are
sealed additively against root104 and the preserved14/15/16 small boundaries.
Changed inherited files are separately copied before real binary delta apply;
new and changed tar contents, exact paths, types, links and full modes are
materialized and checked. There is no new full inherited-tree reconstruction,
3GB copy or old API read. Parent independent qualification remains separate.

Old PhysicalChecks/cue sources and exports remain immutable historical evidence;
their diagnostic partial reads the removed `applicationFocused` field and is not
represented as a current composition. No new diagnostic payload was built.
Any future physical run needs separately coordinated current source binding and
affected diagnostic qualification before launch.

Case16 remains the actual human **FAILED “No controllers”** result, look time and
cause unknown. All its old owners are closed. This software result does not
retrospectively change it. Startup complaint, physical visibility/gestures/comfort,
the cold-head failure and both original desktop stalls remain open. No full M4,
commit, push, M5 or distribution/publication approval is claimed.
