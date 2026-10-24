# Fable validation of world-library corrections

Read AGENTS.md and the current frozen architecture, physics, terrain and GUI
contracts. Yan requested Fable review and authorized completion and deployment.
Read-only: no commands, tests, builds, edits, memory writes or delegation.
Return a complete final report with precise frozen references, disposition of
all earlier findings, remaining confirmed defects, distinct risks and evidence
limitations. This is consultative validation, not deployment approval.

Review exactly `/home/yan/src/quod/_build/world-library-20261016/clean-integration-04/tree`.
The adjacent source manifest hash-matches it. `corrections.patch` compares it
against review-02's exact tree; the complete earlier report and supplement
are durably saved under review-02. Do not silently retarget to live changes.

Corrections needing independent inspection:

- Existing pending physics input retains its query coverage through collider
  preparation, until consumption or cancellation. Expired discrete movement
  reports expiry instead of a clear zero move. No deadline extension, timer,
  owner, native API or queue was introduced. Check rebasing and suspension.
- Reservation dependencies and changes distinguish readers and writers using
  the existing descriptor and conflict model. Shared readers retain their
  cached selection; overlapping writers invalidate it. No shadow inventory.
- Library terrain tools evaluate the negative lower bound. The real signed
  library fixture now opens and cancels that actual form.
- Library resolution checks the outcome vector, preserves the original
  journal identity on endpoint/nonterminal/callback failure, and reports why.
- Sealing checks policy-changing diffs through the selected policy's captured
  dependencies, using the same strict read-only selector over the final
  staged candidate without attempting OCC capture on an unpublished state.
  Malformed, missing, ambiguous and unknown-resource plan policies are
  refused. Committed policy still owns the proposal's allowance. Zero remains
  valid deliberate owner policy, with no invented repair budget or bypass.
- The overlay fixture expects the real common base's `{present,0}` token.
  The impossible `too_many_new_atoms` material-result type is removed.

Evidence: clean-integration-02 finished with 4 failures and 4,067 passes;
its triage, logs and STOP remain. Clean-integration-03 was explicitly stopped
after native tests when your original review arrived; it is not a pass.
Focused correction receipts are terrain-pending-coverage-fix-01/-02,
reservation-modes-fix-03 (97), overlay-base-token-01 (21),
review-functional-fixes-01 (real library), library-resolution-01 (11), and
material-policy-update-01 (10). Read their actual logs/receipts as needed.

Browser desktop-local-04 passed real signed GUI creation of a generated-name
meadow and named fine highlands, physical walking in both, return/reentry and
walking after reentry, with zero pending writes. Its source was the live tree
before your form/controller/policy corrections. It is not final deployed
acceptance or physical VR validation. Evidence is under
`_build/world-library-20261016/desktop-local-04`.

The fresh full clean sequential 04 campaign runs independently; do not infer
completion from its presence. Release/build/deployment require all gates and
independent assessment of your findings. No live reset has occurred.

The complete bounded admission consultation is saved in
`review-02/admission-consult.md`. The parent traced the pre-existing unrestricted
committee ETF decode and pinned trusted-execution contract. This feature keeps
that trust boundary; it does not claim a new consensus-level resource sandbox.
The consultation's proposed cross-lane check changes consensus refusals and
lane-1 accounting and leaves a leader-ingress obligation untraced. Those are
broader changes than adding a local guard at one materializer. Assess whether
the frozen feature preserves the actual existing guarantees; distinguish that
question from recommending a broader future committee-hardening project.
