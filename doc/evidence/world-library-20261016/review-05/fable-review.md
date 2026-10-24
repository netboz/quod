## Fable final disposition: world library with admission refactor and corrections (frozen05)

Reviewed exactly `/home/yan/src/quod/_build/world-library-20261016/clean-integration-05/tree`. I confirmed by directory comparison that it differs from frozen04 only in `src/quod_physics.erl`, `test/quod_physics_tests.erl`, `doc/multiwrite-architecture.md` and `doc/voxel-world.md`, as `since-04.json` records, so every frozen04 reference below still holds. Consultative only; I ran nothing. Line numbers are frozen05.

### Verdict

The narrow correction fixes the reproduced cancellation defect through the existing owner and leaves no confirmed defect in the feature scope that I can find. Every earlier finding is disposed below; what remains are minor risks and evidence limits. The trust-boundary sentence I asked for is now in the shared write architecture, which closes my documentation note.

### Inspection of the final correction

- **One cancellation transition.** `cancel_input/2` removes the retained query coverage and clears pending with a result (`src/quod_physics.erl:725`); `suspend_input` delegates to it (`:724`), and `clear_viewer` cancels the viewer's input as `disconnected` through it (`:1030`). Explicit unwatch and viewer death both enter `remove_viewer` (`:193-196`), so there is exactly one removal path.
- **Recheck once, native decides.** `remove_viewer` (`:1014-1023`) only acts when the owner is in `coverage`, has no unfinished insertion (`restoring` empty) and its navigation source is still current (`navigation_current`, `:1004-1005`). It then sets `active` and runs the ordinary `step_native` once. The native step is the authority: a sample or sleeping sentinel resumes stepping through the existing scheduler; `{unavailable,{terrain_coverage,_}}` re-enters `hold_terrain` and re-emits demand (`:537-563`, `:681-684`); coordinate or other unavailability blocks as before. No timer, queue, process, deadline or unchanged-selection retry was added.
- **Phase publication is correct in both outcomes.** `notify(installed, S)` is a no-op while the phase is `coverage` or blocked and publishes only under a current navigation source (`:1039-1043`), so a recheck that falls back into a wait publishes nothing false, and a recheck that resumes publishes `installed`, which also clears the runtime's reconciliation flag through the existing status path.
- **Source and insertion guards.** An invalidated source returns the cleared state unchanged; an unfinished restoration keeps its wait; actual missing body coverage holds again after the step. The new owner test covers the last two (`test/quod_physics_tests.erl:5556-5596`), and the disconnected case of the query-gap test checks resumption, the cancelled row without coverage, and a fresh watch succeeding (`:2652-2713`).
- **Internal clearing does not reenter stepping.** The five internal `clear_viewer` sites (`:170`, `:206`, `:489`, `:884`, `:916`) still call `clear_viewer`, not `remove_viewer`.
- **Stale or duplicate unwatch is harmless.** The unwatch and `DOWN` clauses match only the current viewer and monitor; anything else falls to the catch-all (`:270`). `clear_viewer` demonitors with flush (`:1026`).
- **Docs.** `doc/voxel-world.md:241-244` states the cancellation recheck; `doc/multiwrite-architecture.md:99-102` now states that admission is proposer-side under the trusted validator execution boundary and claims no new sandbox.

### Disposition of every earlier finding

| Finding | Disposition |
| --- | --- |
| Review-01: spawn candidate passed `-1` as unary minus | Fixed in review-02 (`priv/ontologies/lobby_worlds.pl:115-117`). |
| Review-01: desktop form could not render the catalogue selection | Fixed in review-02 (`ui/src/GuiForm.tsx:119`, `:164`). |
| Review-02 D1: terrain tools form failed to compile (`-1000000` literal) | Fixed in 04 (`lobby_worlds.pl:170-171`); real fixture opens and cancels the form (`test/quod_gui_examples_tests.erl:73-75`). |
| Review-02 D2: malformed material override locks an ontology out | Fixed in 04 at the seal (`src/quod_material_admission.erl:20-34`, `src/quod_dtx.erl:195-210`), tests at `test/quod_material_admission_tests.erl:43-83`. |
| Review-02 D2: zero allowance | Not a defect: deliberate owner policy, documented (`priv/ontologies/material_policy.pl:5-6`, `doc/multiwrite-architecture.md:87-93`). My repair-path suggestion is withdrawn. |
| Review-02 D3: library resolution swallowed outcomes | Fixed in 04 (`client/src/space-library.js:115-118`; tests `client/test/space-library.test.js:146-176`). |
| Supplement S1: pending query coverage evicted | Fixed in 04 (`mechanical_terrain`, `:652-658`; `hold_input_terrain`, `:686-688`; expiry result `:806-810`). |
| Supplement S2: read/read reservation invalidation | Fixed in 04 (`src/quod_selection_basis.erl:26-28`, `:49-67`; pairwise test `test/quod_atomic_projection_tests.erl:919-944`). |
| Supplement S3: overlay fixture token | Fixed in 04 (`test/quod_overlay_tests.erl:47`). |
| Review-02 R1: "trust-model regression" from removing the 512 quota | Withdrawn in the consultation; re-confirmed against `src/quod_relay.erl:4-7`, `:28` and `doc/outdated/distributed-proof-plan.md:1026-1031`. Committee ingress hardening is recorded as a separate future decision. |
| Review-02: stale `too_many_new_atoms` spec | Fixed in 04 (`src/quod_dtx.erl:531-534`). |
| Review-02: documentation of proposer-side admission | Closed in 05 (`doc/multiwrite-architecture.md:99-102`). |
| Review-04 supplement: coverage wait after unwatch | Fixed in 05 as inspected above. |
| Test gaps: library form through lobby policy; malformed and zero policy; resolution failures; cancellation both ways | Closed by the fixtures cited above. |

### Remaining risks, none a confirmed defect

- **Journal storage errors in the library controller.** If `pendingSignedOperations` itself rejects inside the catch handler (`client/src/space-library.js:77-83`), the controller promise rejects unhandled and the status is not updated. Robustness only; writes are not affected.
- `validate_update` validates the `plan` kind only (`src/quod_dtx.erl:198-200`); a root plan that leaves the `founding` rows malformed is refused later at creation, and root's intact plan lane can repair it. Coverage gap, not a lockout.
- Appearance and scene changes retire the space and close the open panel (`ui/src/World.tsx`); drafts survive in their controllers.
- Initial chunk selection at an exact surface boundary picks the chunk above the ground (`lobby_worlds.pl:164-165`); mechanical demand repairs it.
- History-page capacity is exact to the byte by construction (`include/quod_ingress_limits.hrl:16-20`); covered by the maximal two-block test.
- View refusals are composed as prose in the physics worker (`src/quod_physics.erl` terrain snapshot); structured terms would localize better.
- After a viewer-less recheck the owner steps until the existing scheduler sleeps it; this is pre-existing behaviour for worlds without viewers, noted for completeness.

### Evidence and its limits

- Full campaign 04: EUnit passed all 4,076 tests and honored the explicit stop; its stop is not a failed test and not a release pass.
- Full campaign 05 at my last read: native debug and release tests 57 and 57, clippy, client tests 217, UI build and lint passed; EUnit had just started; no `eunit.json`, `PASSED.json` or `STOP.json`. CT, xref, Dialyzer and release have not run. Do not infer a pass.
- Focused receipts are the parent's: `terrain-disconnect-fix-02` eight cases, `terrain-disconnect-fix-01` six, plus the 04 receipts cited in the earlier report.
- The browser journey `desktop-local-04` passed creation, walking, return and reentry, but on a tree before the 04 and 05 corrections, headless, with no VR.
- Existing live ontologies still need explicit source composition and the authorized ledger reset; no remote mutation has occurred. Deployment requires the complete gates and the parent's independent check of these findings. No implementation or deployment approval is requested and none is given.
