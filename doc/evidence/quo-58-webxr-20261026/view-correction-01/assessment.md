# Unrestricted tracked viewing

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

The exact production delta is **22 added / 131 removed / net −109 lines** across
13 files, including declarations and the lobby recipe. This corrects the
intermediate progress message's arithmetic. See [per-file counts](production-delta.json).
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
is blocked; no corrected image has been built or deployed. The source fix and
focused regressions are complete, but they are not a full release qualification.

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
