# World-library integration status

Current checkpoint: 2026-10-17, the first usable milestone is deployed as
0.7.273. All twelve release gates, the full deployed desktop journey and both
eight-node fleet checks passed. The implementation remains uncommitted.
[Final acceptance and limits](deployment-273/acceptance.md) identify the exact
image, source, review, browser evidence and authorized candidate-data reset.

Implemented: owned-world library through the existing GUI; shared world
creation controls; saved names drawn from the naming ontology when blank;
independent world pilots and authorities; exact-space entry and return;
shared signing, operation journal, transactions and recovery. Creation and
exploration remain the focus. Flying-lobby transfer, cubic terrain and visual
texture blending remain later milestones.

The composed lobby now founds through the existing lifecycle after Yan's
authorized shared material-admission refactor. Limits are Prolog policy over
the committed proof state, with ordinary OCC dependencies. The shared
encoding capacity fits the existing transport and history carriers. No
transaction splitting or compatibility path was added.

Validation:
- Full clean-integration-02 stopped after EUnit: 4,067 passes and four
  failures. Its logs and [causal triage](clean-integration-02/triage.md) remain.
- The pending terrain coverage, reader reservation and stale fixture failures
  are corrected; focused owner regressions pass without weakened assertions.
- [Fable's full report](review-02/fable-review.md) and
  [supplement](review-02/fable-supplement.md) are saved. Form and operation
  feedback defects are corrected. Policy-changing plans now reject malformed
  final policies while preserving deliberate zero allowances.
- [Desktop acceptance](browser-acceptance-06/summary.json) passed generated-name
  meadow and fine highlands creation, physical walking, return, saved-world
  reentry and walking after reentry, with zero pending writes and page errors.
  This was an isolated fixture before the final form/controller/policy fixes;
  it is not deployed acceptance or physical VR validation.
- Clean-integration-03 was explicitly stopped after native tests when the
  review arrived. Clean-integration-04 passed all 4,076 EUnit tests, then
  honored its explicit stop. Native debug/release tests, 217 client tests,
  UI build and lint also passed. It did not run the remaining release gates.
- A further [disconnect diagnostic](terrain-disconnect-diagnostic-02/triage.md)
  reproduced a cancelled query leaving its world paused. The live correction
  passed eight focused cases, including real missing body coverage and pending
  restoration remaining unavailable. Fable's complete [frozen05 report](review-05/fable-review.md)
  is saved with its evidence limits.
- The related [source-cancellation diagnostic](terrain-source-cancel-diagnostic-01/triage.md)
  exposed the same wait during canonical invalidation, plus a stale sleeping
  frame in the first correction. The shared coverage recheck now handles
  installed dependency changes and refreshes the authoritative frame. All
  nine focused cases pass. Campaign 05 passed all 4,079 EUnit tests and stopped
  explicitly. [Campaign 06](review-06/brief.md) freezes the final correction for
  all gates and a narrow Fable check. Its [independent assessment](review-06/independent-notes.md)
  records the shared recovery, unchanged-operation behavior and actual line
  delta. This historical freeze did not yet have a full release pass.
- Fable's complete [final frozen06 report](review-06/fable-review.md) finds no
  remaining confirmed defect. Its conclusions have been checked independently;
  optional risks and evidence cutoffs remain in the saved report. Final native,
  client and UI gates pass; all 4,080 EUnit tests pass. Common Test found two
  [stale catalogue-count assertions](clean-integration-06/triage.md): the old
  total excluded the new 144 world names. The recovery fixture now compares
  with the founded catalogue; production is unchanged. The campaign retains
  its failures. All nine focused naming cases and xref/Dialyzer preflight pass.
- [Final freeze07](review-07/assessment.md) differs from Fable's production
  review only in that test fixture. All 1,212 manifest entries are verified;
  all twelve [final gates](clean-integration-07/PASSED.json) pass: native debug
  and release 57 each, client 217, EUnit 4,080, Common Test 148, plus clippy,
  UI build/lint, xref, Dialyzer and production release. No new production review
  is claimed for the test-only correction, and no failed campaign was resumed.

Fable's [final admission consultation](review-02/admission-consult-final.md)
withdraws the trust-regression characterization after checking the pre-existing
committee decode and trusted-execution contract. The broader hardening topic
is [recorded separately](deferred-committee-hardening.md).

The [overnight authority](overnight-authority.md) permits deployment and a
necessary candidate-ledger reset. Prepared deployment scripts guard the exact
candidate job and preserve the main job and ingress. They require complete
gates and independent review assessment, then verify the packaged image,
replacement fleet and a new account's real browser journey before removing
old candidate volumes. The first deployment passed its eight-node fleet check,
but browser acceptance exposed a founding-recipe omission: `quod:gui` lacked
its native presentation module. The failed attempt and signed diagnosis are
retained. The [corrected deployment recipe](deployment-02-review-brief.md)
adds and verifies the immutable module profile without changing the tested
application image. The separately labelled replacement campaign passed. A
subsequent harness timeout was isolated to input-event synchronization;
[the triage](deployed-reentry-triage.md) preserves the failure and correction.
The final browser journey passes with unchanged movement assertions, zero
pending operations and no page errors. All 16 exact retired candidate volumes
were removed only after browser and fleet acceptance. Main and ingress stayed
unchanged. Fable's extra recipe consultation hit its provider quota; the
[independent recipe assessment](deployment-02-independent-assessment.md) records
that limit without claiming another Fable review.

[Naming provenance](naming-provenance.md) confirms deferred book imports.
The new landscape pool is original Quod vocabulary using the existing naming
engine; it does not claim to complete those book imports.
