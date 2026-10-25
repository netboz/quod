# S1.6 ordinary placement — Claude Fable review

Consultative read-only review explicitly requested by Yan. Scope:
[tsk_01M5Q1YXC2AQK9YP4GRXM4FYBV](nimbalyst://tsk_01M5Q1YXC2AQK9YP4GRXM4FYBV).
Review session: `99c17125-a174-43ca-846c-c0871f18dcda` (Claude Fable).
The reviewer inspected code and evidence; it made no edits and ran no tests.
The parent independently checked the findings and performed validation.

## Parent disposition

1. **Physical cleanup after reclassification: confirmed and corrected.**
   The generalized hook dispatch wrongly used only the destination's current
   class. Two deterministic tests reproduced skipped cleanup after conversion
   to an ordinary space and blocked withdrawal after removal of space membership.
   Withdrawal now uses the existing physical owner's live binding to recognize
   the cleanup obligation even after reclassification. No new participation
   state, registry or executor was added. A missing hook refuses the transaction
   and leaves both owners intact. Successful withdrawal removes admission,
   body definition and source delegation, retains revision protection and permits
   later physical readmission. Both real-owner cases pass.
2. **Shared no-I/O helper coverage: exercised, with an existing failure retained.**
   All seven additional caller modules were run: 161 checks passed and one HTTPS
   source-editor acceptance check failed before reaching its no-I/O section.
   Bounded diagnostic tracing identified the existing 64 MiB proof-worker heap
   limit. An isolated reproduction using the starting revision's Prolog,
   fixtures and client code, with independently compiled baseline test modules,
   fails identically at `ontology-acl.acceptance.mjs:175`. The unchanged Erlang
   production beams and dependencies were reused. This is not caused by the
   tightened tracing or S1.6. Its loopback-sandbox failure and subsequent
   authorized reproduction have separately retained logs and true exits.
   The failing whole-source edit and its later tracing section are not claimed
   as verified. Changing proof budgets/source-editor policy would exceed the
   explicit S1.6-only scope; no constant, deadline or assertion was weakened.
3. **Creation and near-agent pose: retained as later integration work.**
   S1.6 places existing committed instances. S1.7 must compose creation consent
   using committed class policy and choose its pose owner. These dependencies
   are documented in the spaces contract; no S1.7 implementation or ticket edit
   was made. S1.3's shared guard is unchanged.
4. **Optional cleanup: completed.** Stale display/placement terminology was
   corrected in the relevant world/lobby docs. A duplicate operation-completion
   wait, an unused test export and redundant membership check in the pose helper
   were removed. The real view still enumerates governed display/placement
   membership, and removal is tested through that owner.
5. **Ontology self-instance authorization: unchanged known limitation.**
   S1.3's strictly local committed policy boundary remains in place. No new
   special case or foreign-policy lookup was added.

All 18 focused correction checks passed. The final corrected-tree 22-module run
completed **647 tests: 646 passed, one baseline source-editor failure** in 573.728
seconds (exit 1). **Production xref passed without warnings** (exit 0). No test
was skipped. S1.6 acceptance checks all pass; the repository gate is not all green. See
[verification and retained runs](/tmp/quod-s1.6-verification.md).
The original reviewed tree and patch remain intact; the correction is frozen
separately in `/tmp/quod-s1.6-regression-05-tree.json` and its matching directory.
Production delta after correction: **+68/−58, net +10 lines**, in five existing
Prolog files, including the physics comment correction. No Erlang production
code was added. Yan authorized the commit and completion. S1.6 is committed as `1f759530` and
completed; the stage and plan remain incomplete.

## Original review

The report below describes the pre-correction frozen tree. Its open-status notes
are historical; the parent disposition above records their current outcome.

## S1.6 review: ordinary nonphysical placement

Read-only review of the frozen tree, reproduced in full for archiving. I did not run builds or tests. The eleven files in the working tree match the regression-03 hashes byte for byte, and the production delta is exactly the claimed +64/-56, net +8, across the four Prolog files. `git diff --check` is clean. The parent's regression-04 and xref logs record exit 0, which I read but did not reproduce.

Two items needed action before commit. The rest are later-scope dependencies, optional cleanups, and confirmations. Status notes from the follow-up exchange are included at the end of each affected finding.

### Findings, highest priority first

**1. Withdrawal consequences are now keyed on the destination's current class, not on what was admitted. Confirmed regression, low to medium severity, untested.**

- `space_change_physics/3` at [space.pl:140](/home/yan/src/quod/priv/ontologies/space.pl:140) skips the physical hook when the destination is not currently a physical space. The base code at base space.pl:133-135 ran the hook on every admission and every withdrawal.
- Failure scenario: an entity is physically placed in W, so W holds a live body binding and the entity's owner holds a `physics_definition_delegate` row. W is then reclassified from `physical_space` to `space` by source edit. That is the exact transition the existing world-retirement test performs at [quod_physics_tests.erl:1909](/home/yan/src/quod/test/quod_physics_tests.erl:1909). A later `space_withdraw` reaches `space_release_placement`, the class test fails, the hook is skipped, and only `space_placement` is retracted. The body definition at W and the delegate at the source survive.
- Consequence: every later physical admission of that entity anywhere is refused at [quod_physics.pl:96](/home/yan/src/quod/priv/ontologies/quod_physics.pl:96), because a delegate already exists. The withdrawal hook at quod_physics.pl:124-132 never required enablement, so the base code would have released both rows here. Re-enabling W later would also resolve a live body against a mismatched source assignment.
- Second sub-case: if W loses its `space` membership entirely, line 141 fails with no reason, withdrawal becomes impossible, and the entity is stuck placed because any other placement reports `space_already_placed`.
- Reachability requires source-rewriting authority, which the plan excludes from the domain guarantee. But the ticket asks to preserve physical consequence checks, and the existing test suite treats this reclassification as a supported transition. No test withdraws after reclassifying; only two tests retract physical-space membership and neither withdraws afterwards. Decide explicitly: fix, or record it as an accepted limitation.
- Fix direction without duplicating owners: withdrawal should release whatever was admitted regardless of current class. Either run the hook on `withdrawn` whenever the destination still holds a live binding for that subject, a relation `space_view.pl` already reads, or restore the unconditional hook and have compositions supply the ordinary no-op as the doc previously required. Do not add a try-and-ignore path.
- Status: open. The parent is independently checking this scenario.

**2. The tightened shared no-I/O helper constrains tests the final gate did not run. Validation gap, must close before commit.**

- [quod_lobby_tests.erl:880](/home/yan/src/quod/test/quod_lobby_tests.erl:880) adds seven traced functions to `assert_read_has_no_io/1`: ledger `read_at/3`, DETS insert and sync, MVCC creation, projection apply, and two ledger folds.
- The helper has thirteen caller modules. Regression-04 ran fifteen modules and covered six of them: space, class permissions, constructors, lifecycle, GUI examples, and the defining lobby module. Not covered: `quod_outcome_tests` (two sites), `quod_gui_components_tests` (five), `quod_commit_validation_tests`, `quod_gui_question_tests`, `quod_ontology_acl_acceptance_tests`, `quod_agent_hosting_tests` and `quod_runtime_tests`.
- The newly traced functions are called by exactly the owners those modules exercise: `quod_outcome` and `quod_dtx_phase_index` write DETS, and `quod_foreign_log` calls ledger `read_at/3`. S1.5's gate ran 26 modules; this one ran 15 and substituted `quod_outcome_result_tests` for `quod_outcome_tests`.
- Required: run those seven modules on the frozen tree and retain the log. A failure there most likely means the tightening is wrong for an established read, not that the S1.6 placement code is wrong. Triage it as such before changing either.
- Status: the parent is running the seven-module caller-01 gate and diagnosing its one failure. Resolution is the parent's.

**3. S1.7 cannot compose creation and placement atomically through `space_place/3` as written. Later scope, flag now.**

- `space_authorized/4` classifies the subject on live state at [space.pl:9](/home/yan/src/quod/priv/ontologies/space.pl:9), but the committed guard enumerates classes on the pinned committed base at [common_predicates.pl:97](/home/yan/src/quod/priv/ontologies/common_predicates.pl:97) and requires a nonempty list at line 89.
- Scenario: a constructor asserts a new instance and calls `space_place` in the same transaction. The live membership check at space.pl:77 passes, the committed class list is empty, and placement fails with plain denial. Every create-with-placement would fail, indistinguishable from a real policy denial, which contradicts the intent of S1.7's "denied explicit placement rolls back creation" check.
- Not an S1.6 defect, since this ticket places existing instances only. S1.7 must choose a shape, for example class-subject consent for creation-time placement, consistent with S1.3's rule that creation checks committed class policy. A one-line comment at space.pl:9 noting the live versus committed split would prevent surprise. Carry this into the S1.7 ticket.

**4. Ordinary placement has no destination-owned pose. Later scope, S1.7 dependency.**

- The placed appearance uses the source's own scene transform at [space_view.pl:27](/home/yan/src/quod/priv/ontologies/space_view.pl:27), so the instance sits at the same local coordinates in every space that depicts it. The doc states this. `space_placement/3` deliberately carries no pose.
- Near-agent placement in S1.7 needs a pose owner. Decide it there rather than widening the placement fact casually. Carry this into the S1.7 ticket.

**5. Optional cleanups.**

- Stale vocabulary in same-scope docs: [doc/world.md:17](/home/yan/src/quod/doc/world.md:17) still says "organizational containment", and [doc/lobby-redesign.md:49](/home/yan/src/quod/doc/lobby-redesign.md:49) still pairs "decorative organizational membership" with "physical admission". S1.6 renamed these to display references and placement.
- [quod_space_tests.erl:361](/home/yan/src/quod/test/quod_space_tests.erl:361) calls `complete/1` immediately after `committed/2`, which already completes at line 189.
- The new export of `simulation_state/1` at [quod_physics_tests.erl:5](/home/yan/src/quod/test/quod_physics_tests.erl:5) is used only inside its own module.
- The `once(space_contains(...))` guard at space_view.pl:27 is redundant for the enumerating caller, whose subjects already come from `space_contains/2`. It is defensible only because the new pose test calls the predicate directly.

**6. Known limitation, not S1.6.** Ontology self-instance subjects raise `invalid_committed_policy` instead of denying, so displaying an `ontology_ref` in a space errors until the D6 integration. This is the documented S1.3 boundary and needs no S1.6 change.

### What I confirmed against the code

- Both owners still consent inside one atomic transaction, including across ontologies. Revision fencing, stale-withdrawal refusal, competing destinations and participant-entry refusal are unchanged apart from the rename. The competing-admission and distinct-owner tests are now parameterized over the ordinary destination as well as the physical one, and a same-ontology ordinary placement test exists.
- The lobby callbacks at [lobby_instance.pl:53](/home/yan/src/quod/priv/ontologies/lobby_instance.pl:53) are strictly local. They use no scope hop and no identity bridge, and they bind the other reference to the local ontology by unification instead. The explicit class list is correct for the personal-lobby composition: `agent`, `lobby_floor`, `lobby_roof` and `prolog_console` have no local ancestry edges there, so a `thing` default would never have applied. That matches the regression-02 note. The strict committed context refuses scope hops as invalid policy, and no foreign-qualified ancestor exists in the composed lobby sources, so the guard cannot error on these subjects.
- `lobby_admission/4` is one definition feeding both the permission checks and the physics projection. No ownership duplication was introduced, and `space_assignment_state/3` has a single owner.
- The pose rule keeps the no-fallback property: a physical placement with a missing, duplicate or stale body binding fails rather than degrading to a transform, and that is now tested directly.
- Display references are independent of storage and ownership, colocated display plus placement yields one appearance through the view's dedup, and removing either reference leaves the instance and its assignment intact. Renewal tracing covers history, projection, MVCC, DETS and file work through the shared helper, and physics and voxel allocation through the nested physics helper, so the verification document's tracing claim is accurate.
- Committed-policy behaviour is covered on both sides: deny and allow overrides, staged grants that cannot authorize the same write, inherited requirements that overrides cannot waive, and post-proof policy changes that conflict at either owner.
- No retired vocabulary remains in production or test code. The only hits are the pinned evidence trees under `doc/evidence`, which must stay as they are.

### Review limitations

I inspected code, patch, fixtures and the parent's logs only. Test results are the parent's evidence, not mine. I did not inspect client or browser code. The regression-03 log was dominated by physics traces, so module coverage came from the regression-04 exit record. I did not evaluate the plan or ticket edits beyond checking that the second S1.6 acceptance box remains open pending the gate. No files were edited and no further investigation was performed for this reproduction.
