Retargeting to clean-fixes-04: I'll verify its manifest and document hashes, confirm the only deltas from -03 are the phase derivation and its test, re-derive the owner line numbers, and read the -04 receipts as they stand.

Nothing further is needed: the -04 manifest verifies, the only deltas from -03 are the four-line phase derivation and its test, the native modules are byte-identical to the ones I already reviewed, and the -04 receipts are read as they stand. Final report follows.

## Fable validation report: terrain corrections, final frozen scope `clean-fixes-04`

**Verdict.** No confirmed defect remains in `clean-fixes-04/tree` within the reviewed scope. Both original defects stay closed, both report-02 findings are corrected by sound mechanisms, and the false-readiness defect the parent reproduced after the -03 freeze is corrected by a phase derivation that I verified case by case. The remaining items are narrow, untested risks and optional refinements, listed below with the evidence that bounds them. The -04 campaign has native, client and UI receipts only; eunit is running and no `PASSED.json` or `STOP.json` exists. Consultative validation, not release approval. I ran no tests or builds. Paths are relative to `_build/voxel-world-20261016/clean-fixes-04/tree`.

### Snapshot identity

All 1198 entries of `clean-fixes-04/source-manifest.json` hash-match the tree; the four review documents match `review-documents-04.json` and are byte-identical to the -03 copies. Against -03 only `src/quod_physics.erl` (the phase hunk at `:423-427`) and `test/quod_physics_tests.erl` (`:5503-5509`) differ; `fixes-04.patch` lists the six production and test files plus two docs against `clean-gates-04`, and `production-line-delta-04.json` reports +97 production lines. The live working tree equals the frozen tree for every reviewed file at the time of reading.

### Disposition of all findings

| Finding | Disposition in -04 |
| --- | --- |
| Original 1: embedded body parked the world in a demand-less coverage wait | Closed. Native `Occupied`/`Indeterminate` at `native/quod_physics/src/terrain.rs:220-249`; owner blocks in place at `src/quod_physics.erl:374`; identical selections are no-ops at `:216`; any changed selection resumes through `:281-283`; recovery test at `test/quod_physics_tests.erl:5346`. |
| Original 2: unbounded viewer interest forced far generation and invalidated the world | Closed. `view_window/2` at `:623-645` admits the combined window before any demand; per-view refusal at `:170`; tests at `:5302` and `:5319`. |
| Report-02 finding 1: whole-collider re-admission blocked on a dig elsewhere in the chunk | Corrected. Per-chunk `Admission` at `terrain.rs:7-43` and `:234-240`; evidence `focused-native-13` (8.26 mm impact penetration with same-chunk edits at ticks 17 and 400, exit 0) and `focused-owner-09` (signed `voxel_edit` under a loaded stack, exit 0); native sources identical to -04. |
| Report-02 finding 2: empty coverage demand reset the mechanical demand | Corrected. `:391` yields `restore_pending`; `:408-409` and `:451` retain the restoration and demand without notifying; test `:5473-5527`. |
| Post-freeze readiness defect: blocked owner reset to `active` while a restore was pending | Corrected. `:423-427` derives the phase from `Waiting`; test sequence `:5503-5509`; `focused-owner-11` (exit 0, 2 tests) ran on sources identical to -04 for all four changed files. |

### Verification of the phase derivation

`:423-427` maps `{Waiting, Phase}` as follows, and I traced each row to its consumer at `:450-470`:

- `{none, {blocked,_}}` to `active`: a completed installation after a refusal, then `:460` steps when nothing changed or `:465-470` steps after changes.
- `{none, Phase}` keeps the phase: `coverage` with zero changes stays waiting at `:459`; `coverage` with changes becomes `active` at `:466`; `active` is unchanged.
- Anything pending to `coverage`: `restore_pending` returns at `:451` with no notify, no demand and no timer; `{coverage,Ranges}` reaches `hold_terrain` at `:452`, which re-asserts the phase and the demand.

The reproducing sequence, restore waiting, far chunk refused at `:362`, original selection restored, now ends in `coverage` with `navigation_ready` false, because the refusal never changed `installed_geometry` and `:391` routes the unchanged selection to `restore_pending`. `restoration_inputs` at `:367-372` keeps the original insertion row ahead of any changed or removed source checkpoint, which the test proves with the 18 m insertion surviving both variants. I found no other path into `installed_frame` with a pending wait and a non-coverage phase: `rebase` and `step_envelope` modes require `active`, and `restoring` is non-empty only after `:452` or `:451` has set `coverage`.

### Verification of the two earlier corrections, unchanged since -03

Face-based admission: `triangle_key` at `terrain.rs:21-24` canonicalises cyclic rotations only, so reversed faces count as new; coordinates are exact chunk-local millimetres (`voxel/mod.rs:10-12`). `admission()` at `:26-43` keeps the last integrated chunk as baseline across repeated unintegrated replacements (`:29`) and treats an unintegrated chunk as `Whole` (`:28`). The comparison surface uses the same `SharedShape::trimesh` constructor and local frame as the collider (`voxel/chunk.rs:72-75`), so `query::contact` at `:244` compares like with like. Only successful integration clears baselines (`lib.rs:562-566`). Origin shifts move each `Installed` with its admission (`origin.rs:52-59`) and the pose at `:242` follows the shift. New bodies and authored pose changes still check the whole surface (`lib.rs:241`, `:408`); removal cleans the set (`:505`); evicted or newly resident chunks are `Whole`, which is conservative. The negative test at `terrain.rs:404-418` proves new rock intersecting an existing contact is refused with the centre still in air, and `:436-451` covers repeated unintegrated edits and a body-only pose change.

`restore_pending`: no producer of an empty coverage demand remains; native producers at `terrain.rs:175-209` and `lib.rs:272-280` are explicit, and the Erlang producer is replaced at `:391`.

### Risks and test gaps

- Dig at the contact of an impacting body: new rim or wall faces lie inside the old solid, so a body with transient penetration deeper than the surface displacement plus 5 mm is still refused at `terrain.rs:245` and then frozen at that depth. The `focused-native-13` edits sit away from the boxes. Test: dig centred under the lower box's edge at tick 16 to 18 and assert `Step::Sample`.
- A blocked owner that silently becomes `coverage` through `:451` leaves the runtime's last status at `{unavailable,coordinate_allowance}` until the next notification. Harmless for the runtime, which treats all `unavailable` statuses alike, but the recorded reason is stale.
- `install_terrain` can fail at `terrain.rs:85` after `:77` removed the chunk map; unreachable because `:38` guards the only failing input, and the owner retires on any install error.
- Carried over, unchanged and still open as review questions: the admission-to-install race near twice the window limit (`:362`), blocked status invisible to the attached client (`src/quod_client_view.erl:626-635`), stale `terrain_mechanical` after a terrain body is removed (`:583-585`), and pending teleport targets excluded from `view_window`.
- The native stack fixture settles side by side; loaded support is proven by the owner fixture at `:5465-5471`, not by the native one.

### Optional improvements

- Make a pure dig provably harmless: refuse a `Changed` surface only when the body penetrates the new faces deeper than it penetrates `baseline.shape` at the same pose. New rock still fails; faces inside former rock never do. This closes the impact-window risk without touching a tolerance and becomes necessary if an additive brush is ever authored.
- Notify `{unavailable,terrain_coverage}` when `:451` moves a blocked owner back to `coverage`, so the runtime's recorded reason matches the state.
- `Waiting` is now three-valued across `:390-412`, `:420-427` and `:450-452`; a named atom set would make the branches self-documenting.

### Gate and receipt status at the time of reading

| Campaign and gate | Receipt |
| --- | --- |
| clean-fixes-02, all twelve gates | exit 0, `PASSED.json`; predates all three corrections |
| clean-fixes-03 | deliberately stopped; eunit exit 0 is a SIGTERM artifact with no completion summary per its `triage.json`; ct exit -9, `STOP.json` |
| clean-fixes-04 native-clean, native-tests (57 passed), native-release-tests, native-clippy, client-tests, ui-build, ui-lint | exit 0, sources unchanged |
| clean-fixes-04 eunit | running, log open, no summary |
| clean-fixes-04 ct, xref, dialyzer, release | not started; no `PASSED.json` or `STOP.json` |

Focused evidence on exact -04 sources: `focused-owner-11` matches all four changed files. `focused-owner-09` and `focused-native-13` match the native files but predate the phase hunk, which does not touch the dig or stacking paths they exercise. `focused-owner-10` is the retained failure that reproduces the readiness defect.

### Scope and limitations

I read in full the -04 owner install, installed_frame, demand, window and step-outcome paths, the native terrain production code, the `lib.rs` install and step paths, `origin.rs`, the chunk preparation and mesh types, the five owner tests cited above, the -03 to -04 diffs, the fourth brief, every focused receipt, log and triage for rounds -03 and -04, and the -02, -03 and -04 campaign receipts. Rapier facts come from the local registry copy of 0.36. I did not re-derive the MC33 behaviour behind "new faces lie inside former rock", which rests on digs only raising density. The eunit, ct, xref, dialyzer and release gates for this exact tree have no receipts yet, and nothing above infers their outcome.
