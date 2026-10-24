## Fable validation of the world-library corrections (frozen04)

Reviewed exactly `/home/yan/src/quod/_build/world-library-20261016/clean-integration-04/tree`; `corrections.patch` matches the differences I read against the review-02 tree. Consultative only. I ran nothing; every receipt below is the parent's. Line numbers are frozen04 unless marked.

### Verdict

All six corrections do what the brief says, through existing owners, and each closes a finding I had confirmed. I found no new defect in the correction scope. Remaining items are minor risks and one documentation gap, listed separately. The parent's trust-boundary assessment is correct against the frozen sources, and the feature preserves the existing guarantees rather than claiming a new one.

### Disposition of every earlier finding

| Finding (review-02 report, supplement, consult) | Disposition in frozen04 |
| --- | --- |
| D1 Terrain tools form could not compile (negative literal) | Fixed. `priv/ontologies/lobby_worlds.pl:170-171` evaluates `Low is -1000000`; the real signed fixture reads the excavation schema, opens and cancels that form (`test/quod_gui_examples_tests.erl:73-75`). |
| D2 Override lockout, malformed case | Fixed at the seal. `src/quod_material_admission.erl:20-34` re-selects the policy over the final staged candidate when the diff touches any captured policy dependency; `src/quod_dtx.erl:195-210` refuses before sealing. Tests cover bad values, variables, unknown resources, duplicates, helper-predicate changes and atomic replacement (`test/quod_material_admission_tests.erl:43-83`). |
| D2 Override lockout, zero allowance | Not a defect. Zero is deliberate owner policy, documented at `priv/ontologies/material_policy.pl:5-6` and in `doc/multiwrite-architecture.md:87-93`, the same class as a denying entry clause. My earlier framing that it needed a repair path was wrong; no recovery budget belongs here. |
| D3 Library resolution swallowed outcomes | Fixed. `client/src/space-library.js:115-118` checks the result vector, surfaces endpoint errors and non-terminal replies, and leaves the journal row untouched; three new controller tests (`client/test/space-library.test.js:146-176`). |
| S1 Pending query coverage evicted (two physics failures) | Fixed, see inspection below. |
| S2 Read/read reservation invalidation (`four_disjoint_groups...`) | Fixed, see inspection below. |
| S3 Overlay fixture stale token | Fixed. `test/quod_overlay_tests.erl:47` expects `{present,0}`, the real common base's token. |
| R1 "Trust-model regression" from removing the 512 quota | Withdrawn in my consultation; confirmed again below against frozen04. No change required. |
| Stale `too_many_new_atoms` spec type | Fixed (`src/quod_dtx.erl:531-534`). |
| GuiForm catalogue rendering; spawn `-1` literal (review-01) | Fixed in review-02's tree; unchanged here. |
| Controller `work()` catch handler can reject unhandled | Still present (`client/src/space-library.js:77-83`); minor, see risks. |
| Appearance or scene change closes the open workspace | Unchanged behaviour; minor UX, see risks. |
| Initial chunk at a surface boundary | Unchanged; startup hint only, see risks. |
| History-page capacity exact to the byte | Unchanged; documented risk, test-checked. |
| View refusal composed as prose in the physics worker | Unchanged; minor. |
| Test gaps: excavation form through library policy; malformed and zero policy; resolution failures | Closed by the fixtures cited above. Validator-side admission tests are not applicable under the posture below. |

### Independent inspection of the corrections

**Pending input coverage.** `mechanical_terrain/1` (`src/quod_physics.erl:652-658`) unions the collider's current requirements with every pending input's retained `terrain` ranges, and both `view_window` and `emit_terrain` consume it (`:623-626`, `:660-661`), so the collider preparation step can no longer drop a query's target coverage. `hold_input_terrain/4` (`:686-688`) stores the ranges in the input row in canonical chunk coordinates (`canonical_terrain_ranges/2`, `:571-577`, offsets by the current origin), which is why rebasing needs no special handling: `install(Spec,S,rebase)` (`:350`) changes the origin, `refresh_terrain` recomputes the collider's own demand canonically (`:582-590`), and the retained row ranges stay valid. Retention ends exactly where it should: consumption removes the key (`:816`, and through `advance_discrete`), expiry removes it with result `expired` (`:806-810`), suspension removes it (`:724`, applied on invalidation at `:205` and on a changed binding or projection at `:438`), and viewer loss clears `pending` so the row stops contributing (`:1010-1020`). Expired discrete input now reports `expired` instead of the zero move's `clear` (`:790`, `:806-810`), and the parametrized test asserts both outcomes and the removed key (`test/quod_physics_tests.erl:2652-2697`). No timer, owner, queue or native call was added; the row gained one map key.

**Reservation modes.** `reservation_keys/2` (`src/quod_selection_basis.erl:49-67`) emits read and write keys. In `dependencies` mode a plan depends on `{reservation,write,F}` for everything it reads or writes and on `{reservation,read,F}` for what it writes; in `changes` mode a prepared vote publishes `{reservation,read,F}` for its reads and `{reservation,write,F}` for its writes. Readers therefore depend only on writers, writers on both, which is exactly `descriptors_conflict/2` in `quod_atomic`. One producer (`src/quod_committed_projection.erl:463`) and one consumer (`src/quod_atomic_admission.erl:199`); no stale two-tuple key shape remains anywhere in `src` or `test`. The new test compares `affected/2` against the real reservation readiness for every ordered pair, including a policy-override writer (`test/quod_atomic_projection_tests.erl:919-944`).

**Sealing of policy-changing diffs.** `validate_update/4` runs only when the staged diff touches a captured policy dependency, applies the diff to the committed state and re-selects with reads disabled (`src/quod_material_admission.erl:20-34`, `:36-48`). The candidate apply is private: MVCC writes accumulate in the handle's `pending` map and reach the shared table only at `commit/3` (`src/quod_erlog_db_mvcc.erl:7-9`, `:56-74`), so concurrent sealers cannot see each other's candidates and no OCC token is captured on an unpublished state. Admission of the write itself still uses the committed limits (`src/quod_dtx.erl:196-209`), so a candidate cannot grant its own allowance; the staged self-grant test now covers an atomic replacement (`test/quod_material_admission_tests.erl:43-51`).

**Trust boundary.** Checked against frozen04: `src/quod_relay.erl:4-7` documents the trusted-committee atom posture and `:28` decodes the consensus inner term with unrestricted `binary_to_term/1`; `doc/outdated/distributed-proof-plan.md:1026-1031` pins verification to author, transcript, OCC tokens, shape, encoding limits and phase rules under a trusted-validator execution boundary. The parent's independent notes state the same and I agree. The feature keeps that boundary: policy admission is proposer-side, honest nodes stay consistent through the sealed policy reads and OCC, encoding bounds and VM headroom still apply at every decode, and nothing claims a consensus-level resource sandbox. My consultation's cross-lane check remains a separate committee-hardening decision with its own untraced leader-ingress obligation; it is not required for this scope and I do not recommend it here.

### Remaining risks and limitations, none blocking

- `validate_update` validates the `plan` kind only (`src/quod_dtx.erl:198-200`). A root plan that leaves the `founding` rows malformed is not refused; creation then fails with `invalid_material_policy` until root repairs it through its intact plan lane. Recoverable, so a gap in coverage rather than a lockout.
- `client/src/space-library.js:77-83`: if `pendingSignedOperations` itself rejects inside the catch handler, the controller promise rejects unhandled. Robustness only.
- Appearance and scene changes retire the space and close the open panel (`ui/src/World.tsx`); question drafts survive. Behaviour change accepted by the parent, noted for the record.
- Initial chunk selection at an exact surface boundary picks the chunk above the ground (`priv/ontologies/lobby_worlds.pl:164-165`); mechanical demand repairs it. Startup hint only.
- History-page capacity derivation has zero margin by construction; checked by the maximal two-block test, unchanged here.
- Documentation: the recommended sentence stating that material admission is proposer-side under the trusted-validator boundary is not in `doc/multiwrite-architecture.md` (only the policy-update paragraph at `:87-93` and the reservation paragraph at `:104-107` were added). Without it the next reader will re-raise the same question I did.
- Evidence state at my last read: full04 native tests 57 and 57, clippy, client tests 217, UI build and lint passed; EUnit was still running with 3,289 passing cases logged and no failure marker; no `PASSED.json`, CT, xref, Dialyzer or release yet. Campaign 02 ended with 4 failures and 4,067 passes; campaign 03 was stopped at the native gate. The browser record `desktop-local-04` passed desktop creation, walking, return and reentry for a meadow and a fine highlands world with zero pending writes, but its source predates these corrections and it is not VR validation.

No implementation or deployment approval is requested and none is given.
