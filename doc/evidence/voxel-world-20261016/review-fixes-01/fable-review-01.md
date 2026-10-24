## Fable validation report: terrain review fixes (frozen `clean-fixes-01`)

**Verdict.** Both confirmed defects from `implementation-review-01` are closed in the frozen tree as specified. Native now reports `Occupied(Body,Terrain)` and `Indeterminate(Body)` instead of an empty coverage demand, the Erlang owner blocks in place and recovers on a governed correction, and visual interest is admitted against one coherent numerical window before any generation. I found one scope-critical gap in the new selective admission lifecycle, one behavioural regression in the live tree that the parent's triage labels as a cleanup, and a gate run that stopped before any Erlang gate produced a receipt. This is consultative source validation, not release approval. I ran no tests or builds. All paths are relative to `_build/voxel-world-20261016/clean-fixes-01/tree` unless stated.

### Confirmed defects

**1. A re-installed chunk collider re-admits retained dynamic bodies at the solver's 5 mm tolerance, so a dig in the chunk under an impacting or loaded body parks the world.** Severity medium to high for the lobby; mechanism certain, trigger window not measured.

- `native/quod_physics/src/terrain.rs:57` puts every new chunk collider into `terrain_admission`; `:202` then runs the contact check for every non-fixed body whose AABB meets that collider, at the body's current solver pose; `:208` refuses when `dist < -allowed_linear_error()`.
- Rapier 0.36 defaults, read from the registry copy of `integration_parameters.rs:417-423`: allowed linear error 5 mm, prediction 20 mm, max corrective velocity 3 m/s. `contact_with_coulomb_friction.rs:422-427` applies no slop deadzone, so the solver corrects penetration continuously but does not bound it per step.
- The preserved failure `review-fixes-01/focused-native-02/run.log` proves the magnitude: at tick 17 the lower box centre was at y 1.14799 with the surface at y 0.75, so its centre line was 2 mm deep, and the check still returned `Occupied(1,0)`. That means a tilted corner exceeded 5 mm during an ordinary landing. That run used the every-step guard in `focused-native-02/terrain.rs:194-209`, the same contact test.
- Any dig in a chunk replaces its collider: `src/quod_voxel.erl`'s prepare path produces a new density vector, `native/quod_physics/src/voxel/chunk.rs:107-111` `collision_eq` fails, `terrain.rs:47-60` inserts a new collider. Paint and halo-only changes keep the collider; subtractive digs within the same 4 m chunk do not.
- Once blocked, nothing resolves the transient. The step never integrates, the body stays frozen at its deepest pose, identical selections are no-ops by design at `src/quod_physics.erl:216`, and a further dig in that chunk produces a new collider against the same frozen pose. Recovery needs a governed body edit that re-inserts the body.
- The regression at `terrain.rs:333-340` adds the new chunk at x 12 m while both boxes sit at x 2 m with 0.4 m half extents, so no AABB intersects and the chunk-side branch of `:202` is never exercised. `new_terrain_checks_a_retained_body_before_integration` at `:354-373` uses a kinematic ball, which has no solver penetration.

Scenario: a chair lands or sits under a heavier object in chunk K; a player digs anywhere else in K; the next step blocks with `terrain_occupied(Chair,Terrain)` and every occupant freezes until an authorized `physics_move_body`.

Correction through the existing owner, without raising any tolerance: when `install_terrain` replaces a chunk collider in place, collect the body colliders that already have narrow-phase contact pairs with the old collider (Rapier's `NarrowPhase::contact_pairs_with`) before `terrain.rs:66` removes it, and exempt exactly those pairs from the new collider's admission check. Those are the "unchanged contact pairs" the contract at `doc/voxel-world.md:276-279` says stay under the solver. Bodies with no prior contact with that chunk keep the full check, which preserves the retained-body case the parent wanted. Required regressions: re-install chunk `(0,0,0)` in the stack test with a field that differs only far from the boxes, once at tick 16 to 18 and once after tick 400 under the 100x upper box, asserting `Step::Sample`; and an owner-level `voxel_edit` dig in the same chunk as a loaded resting chair.

**2. The live tree removed `request_terrain([],S) -> S`, which is reachable, so the triage's "obsolete no-op" claim is wrong.** Not in the frozen scope, but the parent intends to carry it forward.

- Frozen `src/quod_physics.erl:392-393` returns `{ok,{restore_coverage,0,[]}}` for an unchanged-geometry selection while `restoring` is non-empty; `:410-411` and `:447` turn that into `hold_terrain([],S)`, and `:563` makes it a no-op so the previously emitted demand stays stable.
- That path fires when the runtime re-sends an identical selection after a `{unavailable,terrain_coverage}` status: `src/quod_runtime.erl:709-713` sets `needs_reconciliation`, and `:3243-3247` re-sends on a run where materialization failed and the world was kept (`:292-296`).
- The live `src/quod_physics.erl` (diffed against frozen) drops the clause. `canonical_terrain_ranges([],S)` then sets `terrain_mechanical` to `[]`, `emit_terrain` sends a demand containing only visual regions or nothing, and the runtime evicts the chunks the pending restore needs. With a slow or failing materialization this churns indefinitely: regenerate smaller set, restore reports coverage, re-demand, fail, keep, identical re-send, drop again.

Correction: keep the no-op or make `hold_terrain` skip `request_terrain` when `Ranges =:= []`, and add a regression where a restore waits for coverage and an identical or control-only re-selection must leave `terrain_sent` unchanged. The live tree needs its own frozen gate run; it is not covered by any receipt.

### Verified non-findings for the admission lifecycle

- Origin shifts never re-admit: `origin.rs:38-74` retains handles, and `lib.rs:203` skips unchanged non-terrain rows while `terrain.rs:47-49` matches shifted chunk origins.
- Body removal and replacement clean the set at `lib.rs:233` and `:503-506`; new hinge poses are admitted at `:409`; unchanged hinges are skipped at `:377`.
- Rest restore has its own full-collider check at `lib.rs:288-310`, and restored bodies are freshly inserted so they are already admitted.
- Controlled motion via `motion.rs:130-151` is not re-admitted, which is correct because the sweeps bound penetration by the authored tolerance.
- Pending coverage keeps the set intact because `lib.rs:564` clears only after a successful integration.
- Identical selection does no install, generation or I/O (`quod_physics.erl:216`), and the runtime cannot loop because `send_physics_selection` at `quod_runtime.erl:3275-3278` clears the flag and the blocked owner stays silent.
- The window admission at `quod_physics.erl:619-640` matches what `plan/7` will later compute: chunk-box corners equal the extremes of the chunk set that `voxel_world.pl:207-215` materializes from the same regions, and `body_points/5` at `quod_physics_coordinates.erl:93-104` is byte-equivalent to the old inline logic. Observer rebasing at arbitrary absolute coordinates remains possible; an incoherent request is refused per view through `quod_client_view.erl:580-586` and the shared world keeps its selection.
- Error propagation from `terrain.rs:144-155` and `:172-178` replaces the old empty requests; `Indeterminate` from `chunk.rs:117-146` is practically unreachable because all eight corner rays are tried.
- No stale `coordinate` phase references remain in production; docs at `doc/voxel-world.md:270-285`, `:323-331` and `doc/physics-native.md:157-162` match the code.

### Risks and test gaps

- Admission-to-install race: bodies that move after `view_window` passes can make the later `plan/7` fail at `quod_physics.erl:364`, blocking with `coordinate_allowance`. Needs a span near twice the limit. Recovery comes from a new interest, a disconnect or view expiry, so the outage is bounded but unexplained to the viewer.
- Blocked status is invisible to the attached client: `quod_client_view.erl:626-635` ignores every status except `installed` and `{failed,_}`, so frames stop silently until expiry.
- `view_regions` now maps every `error` to `invalid_terrain_binding` at `quod_physics.erl:614`, which also masks a stale `terrain_mechanical` after a terrain body is removed (`refresh_terrain` `:580` leaves it untouched).
- The window check ignores pending teleport targets and the velocity envelope that `reframe` and native coverage include. Negligible at kilometre limits, visible with metre-scale test limits.

### Gate and receipt status

| Gate in clean-fixes-01 | Receipt |
| --- | --- |
| native-clean, native-tests (57), native-release-tests, native-clippy | exit 0, sources unchanged |
| client-tests, ui-build, ui-lint | exit 0 |
| eunit | exit 1, `STOP.json`; `triage.json`: sandbox `ranch_ssl` listener `eperm`, 49 tests, 0 failures, 6 cancelled |
| ct, xref, dialyzer, release | not run, no receipt |

Of the focused receipts, only `focused-owner-03` (3 tests) matches the frozen tree for all six changed files. `focused-native-04` and `focused-owner-02` match native and tests but record an earlier `quod_physics.erl`; `focused-owner-01` (224 tests) and `focused-native-03` ran on earlier `terrain.rs`, `quod_physics.erl` and test sources. The "224 EUnit tests passed" figure is therefore not evidence for the frozen tree.

### Optional improvements

- Surface `{blocked,Reason}` to the viewer as a per-view `unavailable` reply naming the body.
- Rename the frozen test atom `coordinate_wait_restarted_world` at `test/quod_physics_tests.erl:3560` (already done live).
- The native `terrain_unavailable` atom now names both a step outcome and a view resource message; one of them deserves a distinct name.

### Scope and limitations

I verified all 1198 frozen manifest hashes, the four review document hashes, that exactly the six expected files differ from `clean-gates-04`, and that `fixes.patch` matches the frozen content. I read in full the frozen `quod_physics.erl`, `quod_physics_coordinates.erl`, `lib.rs` production part, `terrain.rs`, `origin.rs`, the terrain parts of `motion.rs`, `chunk.rs` classification and equality, the runtime demand, materialization, status and selection seams, the client view interest and resource paths, both current docs, `AGENTS.md` and `doc/multiwrite-architecture.md`. Third-party facts come from the local registry copy of Rapier 0.36. I did not re-derive the resting penetration of a loaded stack numerically; defect 1's rest-state trigger is inferred from the solver model and the impact evidence, which is why the regression above must measure it. The live working tree differs from the frozen tree in `src/quod_physics.erl` and `test/quod_physics_tests.erl`; everything above refers to the frozen tree except defect 2.
