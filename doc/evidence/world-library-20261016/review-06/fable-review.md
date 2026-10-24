## Fable final disposition: world library, admission refactor and corrections (frozen06)

Reviewed exactly `/home/yan/src/quod/_build/world-library-20261016/clean-integration-06/tree`. By directory comparison it differs from frozen05 only in `src/quod_physics.erl`, `test/quod_physics_tests.erl` and `doc/voxel-world.md`, as `since-05.json` records, so all frozen04 and frozen05 references for other files carry over unchanged. Consultative only; I ran nothing. Unqualified line numbers below are frozen06.

### Verdict

The final correction closes the second orphaned-coverage case through the same owner as the first, and I find no remaining confirmed defect in the feature scope. The two cancellation entries, viewer removal and installation-driven consumer change, now reach one `recheck_coverage`, the native refresh gives it both an actual coverage check and a current frame, and the identical-selection path stays a no-op. Remaining items are optional robustness risks and evidence limits, listed separately.

### Inspection of the final correction

**Installed dependency changes.** `installed_frame` computes `ConsumersChanged` from a changed navigation guard, changed agent controls or a changed input map (`src/quod_physics.erl:450`) and, only when the installation also changed no colliders and no insertion waits, routes to `recheck_coverage` (`:460`) ahead of the clause that otherwise preserves the wait (`:461`). The input map differs exactly when a row was suspended or re-expected by the new projection (`:434-446`), which is what source invalidation produces after `:202-206` suspends every input and clears the viewer. The `falling` rewrite cannot create a spurious difference on an identical selection because its only new term is gated on `Changes > 0`.

**Refreshed sleeping frames.** `recheck_coverage` sets `active` and calls `step_native(S, true)` (`:1017-1025`), so the native step receives `refresh = true`. Rust folds that into `world.changed` (`native/quod_physics/src/lib.rs:732-738`); `active()` is true whenever `changed` is set (`:518-524`), so `step()` cannot return the sleeping sentinel. It runs the step-region and coordinate checks, the terrain coverage check, the pipeline, and ends in a full `sample()` (`:526-569`). `publish/2` builds the frame from the installed spec's fence and structure, so the published projection is the current one. This is precisely what the failed first correction lacked: its sentinel path kept the old frame, and `body_state` answered `{error,unavailable}` because `current_projection` compared structure 2 against expected 3 (`terrain-source-cancel-fix-01/run.log:57-61`; handler at `:91-99`).

**Insertion and source guards, guard ordering.** `recheck_coverage` acts only with `restoring` empty and `navigation_current` true (`:1020-1024`), otherwise it returns the state untouched. The guard it consults is the newly installed one, because `installed_guard` and `spec` are set on the controlled state before the clause runs (`:447-449`), and `installed_frame` itself is only reached through `advance`, which already requires a current source. Unfinished restoration is also stopped earlier by the `restore_pending` and `{coverage,Ranges}` clauses (`:452-453`).

**False readiness and input expiry.** `active` is set synchronously immediately before the native call; if coverage is still missing the step returns the terrain-coverage refusal and `hold_terrain` restores `coverage` (`:550-551`, `:681-684`), and `notify(installed, _)` is a no-op in that phase (`:1040`). Nothing publishes `installed` without a successful step under a current source (`:1041-1042`). The recheck calls `step_native`, not `do_step`, so pending inputs are neither advanced nor expired by it; their original expiry stands until the ordinary scheduled step.

**Unchanged selection and repeated cost.** An identical selection yields zero collider changes and, with inputs, controls and guard unchanged, `ConsumersChanged` false, so the owner takes the existing no-op or frame-delivery clauses (`:461-470`) without any native work; the runtime already re-sends identical specs only under a reconciliation flag (`src/quod_runtime.erl:3240-3252`, unchanged). The refresh step therefore runs once per real consumer or guard change.

**Stale or duplicate unwatch.** Unchanged from frozen05: the unwatch and `DOWN` clauses match only the current viewer and monitor (`:193-196`), everything else falls to the catch-all (`:270`), and `clear_viewer` demonitors with flush.

**Tests and contract.** The query-gap test now carries applied, expired, disconnected and source-changed cases; the two cancelled cases assert the body's original position through `body_state` against the installed projection and a successful fresh watch (`test/quod_physics_tests.erl:2652-2719`, especially `:2685-2687` and `:2694-2706`). The unavailable restoration and body-coverage cases remain (`:5562-5602`). `doc/voxel-world.md:241-245` states the consumer-or-guard recheck and the refreshed sample.

### Disposition of every earlier finding

| Finding | Disposition |
| --- | --- |
| Review-01: spawn candidate passed `-1` as unary minus | Fixed in review-02 (`priv/ontologies/lobby_worlds.pl:115-117`). |
| Review-01: desktop form could not render the catalogue selection | Fixed in review-02 (`ui/src/GuiForm.tsx:119`, `:164`). |
| Review-02 D1: terrain tools form failed to compile | Fixed in 04 (`lobby_worlds.pl:170-171`); fixture opens and cancels the form (`test/quod_gui_examples_tests.erl:73-75`). |
| Review-02 D2: malformed material override locks an ontology out | Fixed in 04 at the seal (`src/quod_material_admission.erl:20-34`, `src/quod_dtx.erl:195-210`; tests `test/quod_material_admission_tests.erl:43-83`). |
| Review-02 D2: zero allowance | Not a defect; deliberate owner policy (`priv/ontologies/material_policy.pl:5-6`, `doc/multiwrite-architecture.md:87-93`). My repair-path suggestion is withdrawn. |
| Review-02 D3: library resolution swallowed outcomes | Fixed in 04 (`client/src/space-library.js:115-118`; tests `client/test/space-library.test.js:146-176`). |
| Supplement S1: pending query coverage evicted | Fixed in 04 (`src/quod_physics.erl:652-658`, `:686-688`, expiry result `:806-810`). |
| Supplement S2: read/read reservation invalidation | Fixed in 04 (`src/quod_selection_basis.erl:26-28`, `:49-67`; test `test/quod_atomic_projection_tests.erl:919-944`). |
| Supplement S3: overlay fixture token | Fixed in 04 (`test/quod_overlay_tests.erl:47`). |
| Review-02 R1: "trust-model regression" from the removed 512 quota | Withdrawn in the consultation and re-confirmed (`src/quod_relay.erl:4-7`, `:28`; `doc/outdated/distributed-proof-plan.md:1026-1031`). Committee ingress hardening remains a separate future decision. |
| Review-02: stale `too_many_new_atoms` spec | Fixed in 04 (`src/quod_dtx.erl:531-534`). |
| Review-02: proposer-side admission undocumented | Closed in 05 (`doc/multiwrite-architecture.md:99-102`). |
| Review-04 supplement: coverage wait after unwatch | Fixed in 05, now through the shared `recheck_coverage` (`:1017-1025`). |
| Review-05 supplement: coverage wait after source invalidation | Fixed in 06 (`:450`, `:460`) with the native refresh; verified above. |
| Test gaps raised along the way | Closed by the fixtures cited in this table. |

### Remaining confirmed defects

None found in the frozen06 feature scope.

### Optional risks, distinct from defects

- **Journal storage error handling.** If `pendingSignedOperations` rejects inside the library controller's catch handler (`client/src/space-library.js:77-83`), the controller promise rejects unhandled and the status text is not refreshed. Robustness only; no write is affected.
- `validate_update` checks the `plan` kind only (`src/quod_dtx.erl:198-200`); a root plan leaving `founding` rows malformed is refused later at creation, and root's intact plan lane can repair it.
- Appearance and scene changes retire the space and close the open panel (`ui/src/World.tsx`); question drafts survive in their controllers.
- Initial chunk selection at an exact surface boundary picks the chunk above the ground (`lobby_worlds.pl:164-165`); mechanical demand repairs it.
- History-page capacity is exact to the byte by construction (`include/quod_ingress_limits.hrl:16-20`), covered by the maximal two-block test.
- View refusals are composed as prose in the physics worker; structured terms would localize better.
- A world resumed by the recheck with no viewer steps until the existing scheduler sleeps it; pre-existing behaviour.

### Evidence and its limits

- Full campaign 05: EUnit passed all 4,079 tests, source unchanged, then the runner honored the explicit stop; not a release pass.
- Full campaign 06 at my last read: native tests 57 passed; native release tests were running; no clippy, client, UI, EUnit, CT, xref, Dialyzer or release receipts yet, and no `PASSED.json`. Do not infer a pass.
- Focused receipts are the parent's: `terrain-source-cancel-fix-02` nine cases passed; `terrain-source-cancel-fix-01` failed and is retained as the publication-defect evidence; the diagnostic's triage records the causal chain.
- The isolated desktop browser journey passed creation, walking, return and reentry on a tree before the 04 to 06 corrections; it was headless and included no VR.
- Existing live ontologies still need explicit source composition and the authorized ledger reset; no remote mutation has occurred. Deployment remains conditional on the complete gates and the parent's independent check of these findings. No implementation or deployment approval is requested and none is given.
