I'll re-target to clean-fixes-02: read the new brief and patch, verify the snapshot hashes, check the receipts that exist right now, and re-derive every line reference against the -02 tree.

## Fable validation report: terrain review fixes, final snapshot `clean-fixes-02`

**Verdict.** Both confirmed defects from `implementation-review-01` are closed in `clean-fixes-02/tree` as specified: native reports `Occupied(Body,Terrain)` and `Indeterminate(Body)` instead of an empty coverage demand, the Erlang owner blocks in place and recovers on a governed correction, and visual interest is admitted against one coherent numerical window before any generation. Two scope-critical gaps remain. One is in the selective admission lifecycle and was already in `clean-fixes-01`. The other is new in this snapshot: the removed empty-demand clause was not dead code, because an Erlang-side producer of an empty coverage demand still exists. The eunit gate now has a real passing receipt on this exact tree; ct is still running and xref, dialyzer and release have not started. This is consultative source validation, not release approval. I ran no tests or builds. Paths are relative to `_build/voxel-world-20261016/clean-fixes-02/tree` unless stated.

### Snapshot identity

All 1198 entries of `clean-fixes-02/source-manifest.json` hash-match the tree, the four review documents match `review-documents-02.json` and are byte-identical to the -01 copies, and the live working tree now equals the frozen tree for every reviewed file. Against `clean-gates-04` exactly the six expected files differ. Against `clean-fixes-01` only `src/quod_physics.erl` and `test/quod_physics_tests.erl` differ, by the three announced edits: the merged resume clause at `src/quod_physics.erl:281-283`, the removed `request_terrain([],S)` clause before `:561`, and the renamed diagnostic at `test/quod_physics_tests.erl:3560`. The merged guard is semantically identical to the three clauses it replaces.

### Confirmed defects

**1. A re-installed chunk collider re-admits retained dynamic bodies at the solver's 5 mm tolerance, so a dig in the chunk under an impacting or loaded body parks the world.** Severity medium to high for the lobby. Mechanism certain, trigger window unmeasured.

- `native/quod_physics/src/terrain.rs:57` puts every new chunk collider into `terrain_admission`; `:202` then runs the contact check for every non-fixed body whose AABB meets that collider, at the body's current solver pose; `:208` refuses when `dist < -allowed_linear_error()`.
- Rapier 0.36 defaults from the registry copy of `integration_parameters.rs:417-423`: allowed linear error 5 mm, prediction 20 mm, max corrective velocity 3 m/s; `contact_with_coulomb_friction.rs:422-427` applies no slop deadzone, so penetration is corrected continuously but not bounded per step.
- The preserved run `review-fixes-01/focused-native-02/run.log` proves the magnitude: at tick 17 the lower box centre was at y 1.14799 with the surface at y 0.75, a 2 mm centre-line depth, and the every-step guard in `focused-native-02/terrain.rs:194-209` still returned `Occupied(1,0)`. A tilted corner therefore exceeded 5 mm during an ordinary landing.
- Any subtractive dig replaces its chunk's collider: a new density vector fails `collision_eq` at `native/quod_physics/src/voxel/chunk.rs:107-111`, and `terrain.rs:47-60` inserts a new collider. Paint and halo-only changes keep the collider.
- Once blocked nothing resolves the transient. The step never integrates, the body stays frozen at its deepest pose, identical selections are no-ops by design at `src/quod_physics.erl:216`, and another dig in that chunk is checked against the same frozen pose. Recovery needs a governed body edit that re-inserts the body.
- The regression at `terrain.rs:333-340` adds the new chunk at x 12 m while both boxes sit at x 2 m with 0.4 m half extents, so no AABB intersects and the chunk-side branch of `:202` is never exercised. `new_terrain_checks_a_retained_body_before_integration` at `:354-373` uses a kinematic ball with no solver penetration.

Correction without raising a tolerance: when `install_terrain` replaces a chunk collider in place, collect the body colliders that already have narrow-phase pairs with the old collider (`NarrowPhase::contact_pairs_with`) before `terrain.rs:66` removes it, and exempt exactly those pairs from the new collider's admission check. Those are the "unchanged contact pairs" that `doc/voxel-world.md:276-279` says stay under the solver; bodies with no prior contact keep the full check. Regressions: re-install chunk `(0,0,0)` in the stack test with a field that differs only away from the boxes, once at tick 16 to 18 and once after tick 400 under the 100x upper box, asserting `Step::Sample`; and an owner-level `voxel_edit` dig in the chunk under a loaded resting chair.

**2. Removing `request_terrain([],S)` was not a dead-code cleanup: `install_frame` still produces an empty coverage demand, and the owner now resets its mechanical demand when it receives one.** Severity medium, narrow production trigger, direct regression of "unchanged or duplicate demand starts no work".

- `src/quod_physics.erl:390-391` returns `{ok,{restore_coverage,0,[]}}` whenever geometry and origin are unchanged while `restoring` is non-empty; `:408-409` and `:445` turn that into `hold_terrain([],Controlled)`; `:662-665` now unconditionally calls `request_terrain([],…)`; `:561-562` sets `terrain_mechanical` to `[]`; `:642-656` then emits a demand containing only the visual regions, or an empty one with no viewer, because the `_` branch at `:648` no longer carries the restore's required ranges.
- The brief's caller audit covers native producers (`terrain.rs:144-155`, `:172-178`, `lib.rs:274`), which are indeed explicit now. It does not cover this Erlang-internal producer, so the sentence "an empty missing-coverage demand is no longer a valid result" is false for `:391`.
- Reachable path in production: a restore returns `Coverage` at `:399`, so the owner waits with `restoring` set at `:418-420` and a demand emitted; an observation already in flight returns `busy`, `observation_result` notifies `observation_capacity`, `src/quod_runtime.erl:707-713` sets `capacity_wait`, `:3280-3284` sends `advance`, `handle_info(advance,…)` at `:226` installs the unchanged spec, and `:391` fires. The same happens for any direct identical re-selection, which is exactly the pattern `test/quod_physics_tests.erl:3584` uses, though that test waits on a step coverage with `restoring` empty and so takes `:392` instead.
- Consequence: the runtime evicts every mechanical chunk, including those under unrelated bodies, the next selection removes their colliders, the restore reports coverage again, the full set is regenerated from scratch because the evicted artifacts are gone from `voxel_resources`, and every body waits through a second coverage round. I traced no permanent loop, but verified work is thrown away and the whole world pauses twice.

Correction: keep `hold_terrain` from touching the mechanical demand when it has nothing to add, for example `hold_terrain([],S) -> notify({unavailable,terrain_coverage},pause_steps(S#s{phase = coverage}))`, or make `:391` return a distinct waiting marker that `installed_frame` handles without `request_terrain`. Regression: a restore waiting for coverage, then an `advance` wake or an identical re-selection, must leave `terrain_sent` unchanged and send no `physics_terrain_demand`; the existing test at `:3564-3598` should gain a restore-driven variant.

### Verified non-findings for the admission lifecycle

- Origin shifts never re-admit: `origin.rs:38-74` retains handles, `lib.rs:203` skips unchanged non-terrain rows, and `terrain.rs:47-49` matches shifted chunk origins.
- Body removal and replacement clean the set at `lib.rs:233` and `:503-506`; changed hinge poses are admitted at `:409` and unchanged hinges skipped at `:377`.
- Rest restore has its own full-collider check at `lib.rs:288-310`; restored bodies are freshly inserted and therefore already admitted.
- Controlled motion through `motion.rs:130-151` is not re-admitted, which is right because the sweeps bound penetration by the authored tolerance.
- Pending coverage, frame refusal and obstruction keep the set because `lib.rs:563-564` clears only after a successful integration.
- An identical selection does no install, generation or I/O (`src/quod_physics.erl:216`); the runtime cannot loop because `send_physics_selection` at `src/quod_runtime.erl:3275-3278` clears the flag and a blocked owner stays silent.
- Window admission at `src/quod_physics.erl:616-638` matches what `plan/7` later computes: box corners equal the extremes of the chunk set that `priv/ontologies/voxel_world.pl:207-215` materializes from the same regions, and `body_points/5` at `src/quod_physics_coordinates.erl:93-104` is equivalent to the old inline logic. Observer rebasing at arbitrary absolute coordinates stays possible; an incoherent request is refused per view through `src/quod_client_view.erl:580-586` while the shared selection remains valid.
- `Indeterminate` from `chunk.rs:117-146` is practically unreachable because all eight corner rays are tried; the docs at `doc/voxel-world.md:270-285`, `:323-331` and `doc/physics-native.md:157-162` match the code; no stale `coordinate` phase reference remains.

### Risks and test gaps

- Admission-to-install race: bodies moving after `view_window` passes can make `plan/7` fail at `:362`, blocking with `coordinate_allowance`; needs a span near twice the limit; recovery through a new interest, disconnect or view expiry.
- Blocked status is invisible to the attached client: `src/quod_client_view.erl:626-635` ignores every status except `installed` and `{failed,_}`, so frames stop silently until expiry.
- `view_regions` maps every `error` to `invalid_terrain_binding` at `:611`, which also masks a stale `terrain_mechanical` after a terrain body is removed (`:576-578` leaves it untouched).
- The window check ignores pending teleport targets and the velocity envelope that `reframe` and native coverage include; negligible at kilometre limits, visible with metre-scale test limits.
- The stacked test's final assertion `y > 1.1` tolerates up to 50 mm of resting penetration, so it cannot bound the rest-state magnitude relevant to defect 1.

### Gate and receipt status at the time of reading

| Campaign and gate | Receipt |
| --- | --- |
| clean-fixes-01 eunit | exit 1, `STOP.json`, `triage.json`: sandbox loopback bind `eperm` in `quod_agent_vault_tests`, 49 tests, 0 assertion failures, 6 cancelled |
| clean-fixes-02 native-clean, native-tests (57), native-release-tests, native-clippy | exit 0, sources unchanged |
| clean-fixes-02 client-tests, ui-build, ui-lint | exit 0, sources unchanged |
| clean-fixes-02 eunit | exit 0, 751 s, sources unchanged, log reports 4056 tests, 0 failures |
| clean-fixes-02 ct | running, `ct.log` only, no receipt |
| clean-fixes-02 xref, dialyzer, release | not started |

The eunit receipt supersedes the focused runs, none of whose manifests match the -02 Erlang source. Its pass does not exercise either defect above: no test re-installs a chunk under a penetrating body, and the only identical re-selection test (`:3564-3598`) waits on step coverage with `restoring` empty.

### Optional improvements

- Surface `{blocked,Reason}` to the viewer as a per-view `unavailable` reply naming the body.
- The native `terrain_unavailable` atom names both a step outcome and a view resource message; one deserves a distinct name.
- `production-line-delta-02.json` reports +51 production lines; I did not recount but the growth matches the three explained additions.

### Scope and limitations

I read in full the frozen `src/quod_physics.erl`, `src/quod_physics_coordinates.erl`, the production part of `lib.rs`, `terrain.rs`, `origin.rs`, the terrain parts of `motion.rs`, `chunk.rs` classification and equality, the runtime demand, materialization, status, invalidation and selection seams, the client view interest and resource paths, both current docs, `AGENTS.md` and `doc/multiwrite-architecture.md`, `fixes-02.patch`, both briefs, all receipts and triage files, and the -01 to -02 diff. Third-party facts come from the local registry copy of Rapier 0.36. I did not derive the resting penetration of a loaded stack numerically; defect 1's rest-state trigger is inferred from the solver model and the impact evidence, which is why the measuring regression is required. Defect 2's production trigger rests on the `advance` wake path; I found no runtime-originated identical re-selection that can arrive before the demanded chunks, so its frequency is low, but the producer at `:391` and the new reset at `:662-665` are certain.
