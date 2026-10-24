## Fable validation report: terrain corrections, frozen scope `clean-fixes-03`

**Verdict.** Both report-02 findings are corrected in `clean-fixes-03/tree` by sound mechanisms, and both original defects stay closed. The face-based admission is a better design than the contact-pair exemption I proposed, and the `restore_pending` marker removes the empty-demand producer at its source. One confirmed defect remains in this snapshot: the shared installation path still resets a blocked owner to `active` while a restoration is pending, which the parent reproduced after the freeze and corrected in a later snapshot that I did not review. The clean-fixes-03 campaign was deliberately stopped, so it carries no Erlang gate evidence; its eunit receipt is a termination artifact, not a pass. Consultative validation only, not release approval. I ran no tests or builds. Paths are relative to `_build/voxel-world-20261016/clean-fixes-03/tree`.

### Snapshot identity

All 1198 manifest entries hash-match. Against `clean-fixes-02` only `src/quod_physics.erl`, `native/quod_physics/src/lib.rs`, `native/quod_physics/src/terrain.rs`, `test/quod_physics_tests.erl` and `doc/voxel-world.md` changed; the other three review documents are byte-identical and all four match `review-documents-03.json`. The live working tree has already moved past this snapshot in `src/quod_physics.erl` and the owner tests, and a `review-brief-04.md` plus a `clean-fixes-04` campaign exist. Everything below refers to the -03 tree unless stated.

### Disposition of the four findings

| Finding | Disposition in -03 |
| --- | --- |
| Original 1: embedded body parked the world in a demand-less coverage wait | Closed. `terrain.rs:220-249` reports `Occupied`/`Indeterminate`; `src/quod_physics.erl:374` blocks in place; `:216` makes identical selections no-ops; `:281-283` resumes on any changed selection. Unchanged since -01. |
| Original 2: unbounded interest centre forced far generation and invalidated the world | Closed. `view_window/2` at `:619-641` admits the combined window before any demand; per-view refusal at `:170`. Unchanged since -01. |
| Report-02 finding 1: whole-collider re-admission blocked on an ordinary dig in the same chunk | Corrected. Per-chunk `Admission` at `terrain.rs:7-43`, applied at `:234-240`. Verified by reading and by `focused-native-13` (edits in the same chunk at ticks 17 and 400 with 8.26 mm impact penetration, exit 0) and `focused-owner-09` (signed `voxel_edit` under a loaded stack, exit 0), both on the exact -03 sources. |
| Report-02 finding 2: empty coverage demand reset the mechanical demand | Corrected. `:391` now yields `restore_pending`; `:408-409` and `:447` retain `restoring` and emit nothing. Verified by reading and by `focused-owner-08` (exit 0), which covers identical, control-only and `advance` re-entry; its manifest records an earlier `terrain.rs` and test file, but the Erlang owner matches -03. |

### Remaining confirmed defect in this snapshot

**A pending restoration becomes falsely `active` when a coordinate-refused selection is followed by the original unchanged selection.** Found and reproduced by the parent (`focused-owner-10`, exit 1), present in -03.

- Sequence: restore waits for coverage, so `restoring` is set at `:420-422` and phase is `coverage`. A selection whose chunks cannot fit the window fails in `plan/7` and `:362` blocks the owner; `installed_geometry` keeps the earlier geometry. The original selection returns, `:281-283` installs it, `:390-391` yields `restore_pending`, and `:423` maps `{blocked,_}` to `active` before `:447` returns without stepping, notifying or scheduling.
- Result: status reports `active` and `navigation_ready` while no frame exists, no timer runs and the restore is still waiting. Demand is retained, so the chunks' arrival still recovers through the native path; calls such as `watch` and `body_state` answer `unavailable` because `current_projection` fails on the missing or stale frame, so no crash follows. The harm is a false readiness report and a world that idles in `active` without stepping until the next selection.
- Correction: derive the phase from `Waiting` before control installation, so any pending coverage or restoration is `coverage` and only a completed installation returns a blocked owner to `active`. The four-line hunk in the -04 snapshot does exactly that; I read only that hunk and its reproducing test, not the -04 tree.

### Verification of the two corrections and the lifecycle challenge

**Face-based admission.** `triangle_key` at `terrain.rs:21-24` canonicalises cyclic rotations only, so a reversed face is new; coordinates are exact chunk-local millimetres from `voxel/mod.rs:10-12`. `admission()` at `:26-43` keeps the last integrated `Shared` as baseline across repeated unintegrated replacements (`:29`) and treats a chunk that was itself unintegrated as `Whole` (`:28`), so an unintegrated version can never certify a later one. The comparison surface is built with the same `SharedShape::trimesh` constructor and the same local frame as the collider (`voxel/chunk.rs:72-75`), so `query::contact` at `:244` sees identical geometry conventions. Only successful integration clears the baselines (`lib.rs:562-566`).

Lifecycle checks, all by reading:

- Dig elsewhere in the chunk: new faces lie away from the body, contact distance positive, step proceeds. Measured in `focused-native-13`.
- New rock intersecting an existing pair: faces above the old surface are new; the negative test at `terrain.rs:404-418` asserts `Occupied(1,0)` with the centre still in air.
- Repeated unintegrated edits and an authored pose change against unchanged terrain: `:436-451`.
- Origin shift: `origin.rs:52-59` moves each `Installed` with its `admission`; the baseline and comparison surface are chunk-local, and the collider pose at `:242` follows the shift.
- Chunk evicted and re-admitted, or newly resident: no `previous`, so `Whole`; conservative, and such a chunk cannot sit under a resting body because the mechanical envelope keeps those resident.
- Air or solid replacement without a collider: `collider` is `None` at `:232`, the interior check at `:220-224` still runs.
- Body replacement, removal, hinge pose change, controlled motion, rest restore: unchanged from -02 (`lib.rs:241`, `:408`, `:505`, `:288-310`; `motion.rs:130-151`) and still correct.

**`restore_pending`.** `restoration_inputs` at `:367-372` prefers the retained row for an already inserted identity, so a changed or removed source checkpoint cannot reposition it; the test at `test/quod_physics_tests.erl:5507-5518` proves the original 18 m insertion survives both. The branch at `:447` runs `install_controls` and `reconcile_controller` first, which is right for control-only selections. No path emits an empty demand any more: the native producers were already explicit, and `:391` no longer reaches `hold_terrain`.

### Risks and test gaps

- Dig at the contact of an impacting body. New rim or wall faces lie inside the old solid, so a body with transient penetration deeper than the surface displacement plus 5 mm is still refused by `:245`, then frozen at that depth. Narrow window, severe outcome, untested: the `focused-native-13` edits are away from the boxes. Test: dig centred under the lower box's edge at tick 16 to 18 and assert `Step::Sample`.
- `install_terrain` can now fail at `:85` after `:77` removed the chunk map and earlier iterations inserted colliders. Unreachable in practice because the trimesh builder only fails on empty faces, which `:38` guards, and the Erlang owner retires on any install error.
- Stacked-rest magnitude: `focused-native-13` measured 0.07 mm at rest under a 100x load, which settles the rest-state question I left open in report 02.
- Carried over and unchanged in -03, still open review questions as the brief states: the admission-to-install race near twice the window limit; blocked status invisible to the attached client; stale `terrain_mechanical` after a terrain body is removed, surfacing as `invalid_terrain_binding`; pending teleport targets excluded from `view_window`.

### Optional improvements

- Make a pure dig provably harmless by comparing against the baseline: refuse a `Changed` surface only when the body penetrates the new faces deeper than it penetrates `baseline.shape` at the same pose. New rock still fails that test; faces inside former rock never do. This removes the impact-window risk above without touching any tolerance.
- The `restoring` rebuild at `:420-422` and the `Waiting` match at `:446` are now three-valued; a small record or named atom set would make `restore_pending` versus `{coverage,Ranges}` versus `none` self-documenting.

### Gate and receipt status at the time of reading

| Campaign and gate | Receipt |
| --- | --- |
| clean-fixes-02, all twelve gates | exit 0, `PASSED.json` present; predates both corrections |
| clean-fixes-03 native-clean, native-tests (57), native-release-tests, native-clippy, client-tests, ui-build, ui-lint | exit 0, sources unchanged |
| clean-fixes-03 eunit | exit 0 in 68 s, but `triage.json` records SIGTERM and the 206-line log has no completion summary; not a pass |
| clean-fixes-03 ct | exit -9, `STOP.json`; deliberately stopped as superseded |
| clean-fixes-04 | native, client and UI gates exit 0; eunit log open, no `PASSED.json` or `STOP.json` |

Only `focused-native-13` and `focused-owner-09` ran on sources identical to -03 for all four changed files. `focused-owner-08` and the other owner runs used an earlier `terrain.rs`, which does not affect their Erlang assertions. `focused-native-07`, `-12`, `focused-owner-04` and `-06` are retained failures with triage, and the -06 failure was a fixture identity assumption, not production.

### Scope and limitations

I read in full the -03 `terrain.rs` production part, the `lib.rs` install and step paths, `origin.rs`, the chunk preparation and mesh types, the -03 Erlang owner install, installed_frame, demand and window paths, both new owner tests and the coverage-wait test, the -02 to -03 diffs, the brief, every focused receipt, log and triage for this round, and the -03 campaign receipts and triage. I read the -04 brief, the -04 owner hunk and the reproducing test sequence only to state the correction for the remaining defect; the -04 tree is outside this report's scope and its campaign is incomplete. I did not re-derive the MC33 case behaviour behind "new faces inside former rock", which rests on digs only raising density; a future additive brush would make the baseline-relative comparison above necessary rather than optional.
