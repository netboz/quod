# Terrain review fixes — exact scope for Fable

Yan explicitly authorized the two confirmed fixes, refactoring/dead-code removal without backwards compatibility, and Claude validation. No commit, deployment or live data edits are authorized by this review.

Read the frozen `AGENTS.md`, `doc/multiwrite-architecture.md`, `doc/voxel-world.md` and `doc/physics-native.md` first. Review only `_build/voxel-world-20261016/clean-fixes-02/tree`, with source manifest in `doc/evidence/voxel-world-20261016/clean-fixes-02/source-manifest.json`. The documents were copied from current source and separately hashed in this directory's `review-documents-02.json`; they are part of this review scope. There should be no live-tree ambiguity.

The baseline is `clean-gates-04/tree`; the previous complete Fable report and independently checked assessment are in `implementation-review-01`. Read the assessment's qualifications: the old coverage wait could recover after a domain edit; the far interest defect was availability, not unauthorized terrain disclosure; observer views need not have a controlled body; a fixed current-origin clamp would prohibit legitimate rebasing.

`fixes-02.patch` captures the exact delta against that baseline (five production modules, tests and two current docs). `production-line-delta-02.json` reports **+51 production lines**: shared coordinate extraction is neutral; explicit native obstruction outcomes, selective geometry admission and pre-generation numerical-window admission account for the growth. No second owner/executor/queue was added. The old coordinate-only phase and empty coverage failure returns are replaced, without a compatibility branch. Historical evidence is intentionally retained.

## Behavior to challenge

- Native missing coverage carries actual requirements; known solid/intersection and ambiguity carry body/reason. Erlang blocks safely, retains the native incarnation and resumes on a governed correction. Identical selection performs no native install/generation/I/O.
- New colliders and authored hinge-pose changes mark existing native geometry for terrain admission. Changed terrain checks retained bodies. Unchanged pairs remain under the solver; interior-point checks still run every active step. The initial hard penetration guard reproducibly stopped an ordinary stack at tick 17; failed runs are preserved in `focused-native-01` and `focused-native-02`. No epsilon was raised to make it pass. Evaluate this admission/integration distinction carefully, including terrain edits, origin shifts, pending coverage, rest restore, body removal/replacement, controlled motion and changed hinges.
- Visual demand is checked against current retained/checkpoint body poses, the union with mechanical ranges, all terrain lattice alignments, the existing coordinate allowance and native shift envelope before generation. This affects observer and controlled views alike; no distance cap or requirement for an observer body was added. Invalid requests use the existing per-view resource refusal; the shared world remains valid. Malformed signed terrain bindings are refused instead of crashing the owner.
- This is numerical-window admission, not a claim that all meshing/allocation failures can be predicted without generation. Prolog continues to own resource limits. Review whether either confirmed defect remains reachable, and distinguish scope-critical defects from unrelated optional optimizations or unverified hypotheses.

## Verification evidence

- `focused-native-03`: full 56 native tests passed (before the last added terrain-edit regression).
- `focused-native-04`: eight terrain tests passed; now includes the additional changed-terrain/retained-body test. Stack also exercises an unrelated residency change and a bounded push.
- `focused-owner-01`: 224 physics/coordinate EUnit tests passed, including original far-view regression and body/terrain corrective recovery.
- `focused-owner-02`: three tests passed for permitted observer rebase and both obstruction recoveries with malformed-binding refusal.
- `focused-owner-03`: three tests passed on final production source for permitted observer rebase, far-view refusal and huge absolute-coordinate controlled movement.
- Full clean sequential gates run in `clean-fixes-02`. Read actual receipts/status; they may still be running when you begin. Do not imply gates passed unless a corresponding receipt exists. The parent will finish/triage them. No tests or builds should be run by this read-only reviewer.

Return one complete final report: verdict, confirmed defects with frozen file/line references and causal scenario/correction, risks/test gaps, optional improvements, inspection scope/limitations. This is consultative source validation, not release approval. Do not send a second summary that replaces the report. Do not modify any files or run commands/tests/builds.

## Final cleanup and gate triage

This final snapshot differs from clean-fixes-01 only by removing the now-unreachable request_terrain([],S) no-op, merging the identical active/coverage/blocked resume clauses, and renaming the obsolete coordinate_wait test diagnostic. Caller audit follows missing-coverage producers through native step, restore and motion queries; invalid conversions now carry explicit errors, so an empty missing-coverage demand is no longer a valid result. No guarantees or tests were removed.

The first campaign stopped with EUnit exit 1 because Ranch could not bind its localhost test listener (EPERM); see clean-fixes-01/triage.json and eunit.log. It recorded 49 tests, no assertion failures, six cancelled. Final clean-fixes-02 has the required loopback permission verified in a standalone bind probe. Its actual receipts remain authoritative; it is not complete merely because the previous run's failure was environmental.
