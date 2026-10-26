# Unrestricted tracked viewing

**All twelve release gates passed** on the frozen correction. The verified image
is deployed on eight healthy nodes, and the real HTTPS bundle matches. Fresh
Vive entry, stereo rendering, exit and re-entry worked. Yan confirms the
head-view correction but reports controller runaway/flicker; overall physical
acceptance remains incomplete.

Yan rejected the fixed head-movement bubble and its blackout after the real
demo. He did not request that restriction. This correction removes it outright.

## Cause and correction

The restored production projection in
[desktop-diagnosis-03](desktop-diagnosis-03/02-authoritative-clearance.json)
contains `tracking(view_only,500)` and clearance `0.498` metres. The old client
compared the tracked eyes against that allowance and enabled an opaque Layer.
The 2 mm difference comes from the existing native query skin. This establishes
the configured restriction in the deployed account. Native pose drift and the
earlier renderer timeout remain separate, unresolved observations.

The correction deletes the full head-clearance path: the Layer/texture, mask
callback, displacement comparison and radius field; the frame clearance field;
the server/native sensory query; and extra mechanical terrain demand for that
query. `view_only` is the single supported local-view mapping. Head translation
does not drive or reposition the controlled body. Entry calibration and stereo
eye parenting remain; no automatic recentering or replacement head limit exists.

QUO-58's explicit XR lifecycle/dependencies and QUO-59's controller descriptions,
adapter and packaged appearance remain intact. Existing controlled-body travel,
placement and landing checks remain. Visual terrain interest still follows the
camera through the existing signed view stream. No security policy changes.

The exact production delta is **22 added / 119 removed / net −97 lines** across
13 files, including declarations and the lobby recipe. The previous source-file count
of −109 included 12 lines from the retired embedded native test; those are now
reported separately. See [per-file counts](production-delta.json).
The initial source hashes match HEAD for the diagnosed files. Unrelated dirty
server/test changes are preserved and excluded from the correction commit;
their exact patch is included in the release freeze because it is present in
the tested build. No new session, worktree, agent or Claude review was launched.

## Verification

[Focused receipts](focused-01/physics.exit.json) record 238 passing production
physics/control tests, 289 passing client tests, 56 passing native tests and the
navigation regression. After that focused run, the stereo regression additionally
checks lost tracking/recovery; the frozen full client gate includes that change.

The [rendered browser fixture](browser-movement-01.json) passed with the actual
world owner and Babylon. It checks head translation at 0.1, 0.606, 1 and −2 metres,
no full-view Layer, no automatic recenter, and no body command caused by head
translation. The XR boundary is simulated: this does not establish hardware,
normal browser permissions, production HTTPS/CSP or real stereo presentation.
The separate navigation test checks both eye transforms and their 64 mm
separation. Its exit/re-entry and unchanged-renewal checks preserve calibration.

The obsolete native sensory-clearance test is retired with the feature. Its
body-isolation obligation is covered by the head-motion command regression;
controlled-body collision/query-budget coverage remains in the native suite.
The replaced eye-terrain test now checks three real-owner view renewals add no
head-collision terrain demand and perform no physics I/O. Existing tests retain
mechanical terrain support and signed visual-interest streaming coverage.

[Second release qualification](release-gates-02/results.json) runs all twelve gates
sequentially against a fresh immutable source copy. Full logs and true child
exits are retained; a failure stops the sequence. The tested source is HEAD
`5c1a90e604131aaa29adfb18ea176f5af8433eae` plus the recorded working patch,
not a clean HEAD-only build. The first sequence stopped at EUnit after 4,039 passing tests when an unchanged
source-edit test exceeded its five-second default timeout. Both isolated source-
edit module comparisons passed; see the [retained triage](timeout-triage-01/assessment.md).
The second complete sequence also stopped at the same test after 4,039 passing
tests. Both sequences remain failed; their logs and STOP markers remain.
No CT, xref, Dialyzer or release packaging followed these failures. Deployment
was blocked at that point; no corrected image had been built or deployed. The
source fix and focused regressions alone were not a full release qualification.

The [subsequent diagnosis](timeout-triage-14/assessment.md) reduced the timeout
to a small test prefix and measured excess GC from retained fixture snapshots.
Two test lifecycle owners now release only their own observations after their
senders stop. Regressions fail before cleanup and pass afterward; the reduced
sequence passes 157 tests with the editor case at 0.600 seconds. Production
compiler code, assertions and deadlines are unchanged. A separately frozen
[third qualification](release-gates-03/freeze.json) cleared the editor case in
1.153 seconds and completed EUnit with 4,243 passing tests and one assertion
failure. `authorization_and_lookup_failures_never_fall_back_test_` received
`request_not_submitted, agent_unavailable` before its expected authorization
refusal. The sequence stopped there; later gates did not run. A bounded
[readiness diagnostic](readiness-triage-01/repeated.intent.json) reproduces the
failure in fresh fixtures: the actor is alive and idle, but its runtime has an
event runner active when the immediate request arrives. The [causal regression](readiness-triage-04/assessment.md) identifies that late
work as the group Complete record. The test helper mistook a terminal local
operation claim for completed group publication. Its correction waits for the
group through the existing subscription and original absolute deadline;
production semantics do not change. The subsequent gate 04 below supplies the
required full frozen qualification.

The desktop diagnosis's first two attempts failed before useful measurement;
the third initially had a diagnostic JavaScript separator error. Each attempt,
triage and corrected observer is retained separately. All owned diagnosis and
offscreen browser processes are closed. No headset runtime or display was
started for this correction.

## Deployment and physical boundary

Rebuilding does not change existing ontology contents. The existing demo lobby
still contains the removed `tracking(view_only,500)` format and must not be
represented as compatible with the new client. A newly founded lobby loads
`lobby_instance.pl` through the existing governed `lobby_options/3` creation
path, freezing `view_only` into its genesis. Existing lobby contents remain
unchanged. Verify the installed source-file references and exact signed control
before choosing a new demo account; a new account need not imply a ledger reset.
Yan has rejected in-place ontology updates. No new data deletion is performed
or implicitly authorized by this correction.

After passing release gates, build and verify an immutable image and exact
packaged sources/assets before rollout. Later physical acceptance must use that
built HTTPS app with normal permissions and the qualified Vive setup. Preserve
display/trust state, wait for Yan before entry, keep the session interactive,
record stereo frames, changing head poses and both controllers, and check
leaning/standing, exit/re-entry and Yan's visible-output observations. Stop only
owned processes. Native readiness belongs to QUO-38; GUI physical acceptance to
QUO-24. No physical pass is claimed for this source correction yet.

The final rebuilt, uninstrumented readiness check passes all 34 tests, including
twenty fresh repetitions. The prior helper fails the deterministic held-Complete
regression. Only `test/quod_ct.erl` and `test/quod_space_creation_tests.erl` change
from gate 03. The fourth separately frozen twelve-gate sequence passed with
these corrections; all earlier failures remain. No production change, deadline
increase, operation resubmission, ontology update or further reset was made.

## Completed release qualification

[Gate 04](release-gates-04/PASSED.json) passed all twelve checks sequentially:
56 native debug tests, 56 native release tests, Clippy, 289 client tests, UI build
and lint, 4,245 EUnit tests, 149 CT tests, xref, Dialyzer and release packaging
(the native clean step also passed). Every gate reports unchanged frozen source.
The original source-edit case passes in 0.868 seconds; the space-creation case
passes in 3.654 seconds; the held-Complete regression passes in 0.495 seconds.
The old failures and STOP markers remain. Completed public logs redact only
generated test private keys, with private originals and hash receipts retained.
Full CT detail logs remain in the frozen tree with a public hash manifest.

[Compared with the deployed demo](deployed-source-delta.json), production differs
only in the thirteen head-view correction files. Dependencies, controller source
and packaged controller assets are unchanged. Other changed build inputs are
eight test files. The original user-owned working patch is still exactly
`38f36875692d0044db4d5d86796c55ecc3f65f72423e167bbd6d292d3355ef04`.

## Verified deployment

Commit `79ad2cb4cef33056794fb6887a8bca18affc68de` records the release-fixture
corrections and qualification evidence after head-view correction `de1e9af4`.
The [verified image](verified-image.json) is pinned to digest
`sha256:69881b0ee6c9a7676d4477f9ed9f53f344aed5e8bef8ba5515e3eed8facf1ca9`.
Its provenance is the frozen gate-04 tree, including the preserved working
patch; the image does not claim a clean HEAD build. Internal release 0.7.275
preserves installed absolute ontology source paths.

The image-only rollout reached job version 111 with eight healthy allocations
and zero task restarts. [Read-only fleet verification](fleet-after-rollout.json)
confirms the retained root and 18 system ontology anchors on every node, the
expected catalogue, unchanged protected jobs and the existing demo02 volumes.
No further reset or in-place ontology update occurred.

[HTTPS verification](https-verified.json) validates the exact public certificate
with normal hostname checking. The world HTML and all 195 served assets match
the frozen build, and [security headers](served-bundle.json) match the existing
strict policy. The fresh physical campaign uses an ordinary new account/lobby
to receive the corrected founding source; old lobbies remain unchanged.

## Fresh physical observation

After Yan confirmed HDMI reconnection, green controllers and readiness, the
ordinary browser permission flow reached a real immersive session. It recorded
9,452 stereo/tracked frames before Quod's Exit VR control ended it once. Closing
an open controller-settings panel allowed a fresh native entry. Yan confirmed
that the lobby stays visible during head movement and both controllers are
visible, then reported a right controller flying away and general flicker.

The [controller diagnosis](vive-live-01/controller-stability.md) preserves these
observations and proves that excessive right-controller displacement already
exists in native WebXR poses. Native tracking investigation belongs to
[QUO-38](nimbalyst://QUO-38); GUI acceptance remains with
[QUO-24](nimbalyst://QUO-24). Yan then confirmed both controllers were held in
view with green LEDs and requested stopping. The re-entry session reached
11,263 tracked stereo frames out of 12,791 callbacks. The remaining callbacks
did not establish tracked stereo and have not been attributed to a cause.
[Final cleanup](vive-live-01/result.json) restored desktop geometry, prior
headset display state and certificate trust, with no unexpected child exits.
