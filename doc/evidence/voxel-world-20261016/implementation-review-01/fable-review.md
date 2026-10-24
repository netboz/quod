**Verdict:** No blocking defect found in the numerical kernel, the patch and transaction seams, the signed delivery credit or the client verification path. Two confirmed defects sit in the physics owner's new terrain gating, and both should be fixed before the create/list/enter integration. One parks the entire simulation on an embedded body with no way to recover. The other lets any attached viewer drive far-away generation and then invalidate the world for every occupant. This review is not deployment approval. All paths below are relative to `_build/voxel-world-20261016/clean-gates-04/tree`. I ran no tests or builds.

## Confirmed defects

**1. An embedded or ambiguous non-fixed body parks the whole world in a demand-less coverage wait.** Severity high for the planned integration.

- `native/quod_physics/src/terrain.rs:177-207` `terrain_step_coverage` returns `Err(vec![])` when any non-fixed body's probe point is inside rock, when point classification is ambiguous, when `query::contact` errors, or when penetration exceeds the solver's allowed error at lines 199-201. That is the same error shape as missing coverage.
- `native/quod_physics/src/lib.rs:530` turns it into `Step::Coverage([])` before integration.
- `src/quod_physics.erl:544-545` maps it to `hold_terrain([],S)`. Line 562 makes `request_terrain([],S)` a no-op, so no demand is emitted. Lines 634-637 set phase `coverage`, cancel the step timer and notify `{unavailable,terrain_coverage}`.
- `src/quod_runtime.erl:703-715` sets `needs_reconciliation` and re-sends the unchanged selection. `src/quod_physics.erl:283` reinstalls it with zero changes, and line 454 `{_,_,coverage,0,_} -> Controlled` keeps the phase at coverage. Nothing steps again.
- The native test at `terrain.rs:281-293` documents exactly this `Coverage(vec![])` outcome for an intersecting body. No Erlang-level test covers what the owner does with it.

Scenario: `priv/ontologies/quod_physics.pl:108-123` admits a body at its authored `physics_admission` pose with format checks only, through `physics_checked_body` at line 635. The GUI presets in `priv/ontologies/voxel_world_gui.pl:5-13` and line 24 put the surface several metres above zero. An agent admitted at a lobby-style pose below that surface, a shape change through `physics_replace_body` that overlaps terrain, or a dynamic body that penetrates deeper than the solver tolerance freezes every occupant. No frames are delivered, inputs are not processed because `advance_inputs` only runs inside `do_step`, the status reads `terrain_coverage` although coverage is complete, and only a domain action that removes that body recovers the world.

Smallest correction through the existing owners: in native, return a distinct outcome for the embedded or ambiguous case, for example `Step::Occupied(Vec<u64>)` encoded as `{unavailable,{terrain_occupied,Ids}}`, and reserve `Coverage` for genuinely missing chunks. In `src/quod_physics.erl` treat `terrain_occupied` like the existing invalid-body refusal for that identity, not as a coverage wait. Before the integration, make the voxel world's admission policy place entities through the existing `physics_motion_query` place or landing bridge, which already consults `terrain_occupied` in `motion.rs`, so an underground pose is refused at commit. Targeted test: install a controlled body below the surface with complete coverage and assert that the owner names the body and keeps stepping, or that the admission is refused.

**2. The interest centre is unbounded, so a viewer can force far generation and invalidate the world for everyone.** Severity medium, security and robustness.

- `src/quod_client_view.erl:80-85` and `91-96` accept any canonical decimal centre on an attached view. Nothing binds it to the viewer's body or tracked eye.
- `src/quod_physics.erl:158-173` admits the interest when the sequence advances. `view_regions` at lines 593-609 checks only the chunk-count allowance.
- `src/quod_runtime.erl:2761-2797` samples and meshes every chunk in the requested box, bounded only by the chunk allowance, before `geometry_allowance` runs at line 2744. `src/quod_physics.erl:1075-1093` then fails with `coordinate_allowance` when the resident chunk corners do not fit one coordinate window. `src/quod_runtime.erl:281-296` blocks the world and invalidates it, and `src/quod_physics.erl:202-206` suspends every input and clears the viewer. If the far box fits the window alone but not together with the bodies, `src/quod_physics.erl:357-365` and 376 park the owner in `coordinate_wait` instead.

Scenario: a client sends an interest centre kilometres from its body while the authored view distance is a few hundred metres. The worker generates up to the chunk allowance there. The world becomes unavailable for all occupants until that viewer is cleared. The client reconnects on the `refresh` message and repeats. Honest clients also pay, because every interest change re-selects and rehashes the full resident set.

Smallest correction: in `handle_info({physics_view_interest,...})` refuse a centre that lies outside the viewer's authorized eye region, meaning farther than the tracking radius plus distance and prefetch from the controlled body's current frame pose whenever `view_consumers/1` is non-empty. In every case require `quod_physics_coordinates:local/3` to succeed for the box corners against the current origin. Answer that viewer alone through the existing `send_view_resource` and `clear_viewer` path at line 170, so the demand never reaches the runtime. Test: a far interest on `with_voxel_view` must yield a per-view `unavailable` and leave the runtime demand and `navigation_ready` unchanged.

## Plausible risks, verified non-findings and optional improvements

Plausible risks that need a targeted test:

- **Resting penetration can trip the pre-step gate and then hit defect 1.** `terrain.rs:199-201` rejects any contact deeper than the solver's allowed error, which is also the solver's own equilibrium target. The relevant Rapier 0.36 defaults are in the local registry copy of `integration_parameters.rs`. The single-ball native test passes 300 steps, but stacked or pushed bodies can exceed the tolerance transiently, and the step that would resolve the penetration is the one being refused. Test: drop a heavy box onto a resting box on terrain and push a dynamic body into terrain with a controlled body. Assert the owner never enters a demand-less coverage phase.

| Rapier 0.36 default | Value |
| --- | --- |
| allowed linear error | 5 mm |
| max corrective velocity | 3 m/s |
| max linear velocity | 400 m/s |

- **`view_regions/3` crashes the owner on a mis-authored terrain mark.** The `try` at `src/quod_physics.erl:594-609` catches only `throw`. A terrain mark whose `body_pose` names a non-terrain body makes line 596 raise a badmatch on the first interest. `terrain_snapshot/4` at lines 915-918 has the defensive `error:_` clause and this function should too. Marks are proof-derived, so this needs an authored composition error, but the outcome is a crash rather than `invalid_terrain_binding`.
- **Partial materialization is discarded on a budget miss.** `src/quod_runtime.erl:2777-2779` throws `deadline_exceeded` per chunk, and only installed artifacts are retained at lines 237-239, so the next attempt redoes all the work. With the 30 second reconcile budget this needs a window near the chunk allowance on a slow node, but then it loops. Test: a small budget override plus a window that cannot finish in time must refuse the window instead of regenerating forever.
- **The velocity cap sets a large per-body demand envelope.** `terrain.rs:131-132` adds the global maximum velocity times the timestep to every dynamic body's region. The native test at `terrain.rs:341` pins that as a five-by-five-by-five chunk cube at half-metre spacing. A handful of scattered free bodies can exhaust the authored chunk allowance and make the world unavailable through policy alone. This is a measurement item before any multi-body acceptance, not a correctness bug.

Verified and not findings, so nobody re-chases them:

- A viewer whose controlled body revision went stale cannot reach `terrain_requirements`. `reconcile_controller` at `src/quod_physics.erl:481-485` clears it through `current_control` before `step_native` and `refresh_terrain`, and watch does the same check at line 74.
- A sleeping body does not float after its support is dug away. Rapier 0.36 wakes every body in contact with a removed collider on the next pipeline step, in the registry copy of `narrow_phase/pair_management.rs` lines 89-98, and the owner always steps after a positive change count.
- Rejected operations do not mutate native state. `lib.rs:183-230` validates origin, budgets and terrain alignment before any mutation, `Prepared::new` never touches the previous artifact, and edits reach native only through committed selections.
- Rollback, stale revisions and patch closure hold. `priv/ontologies/voxel_world.pl:148-157` fences the world revision and every brush-owner patch revision inside one transaction, validates consumers before replacing the body, and `quod_voxel.erl:76` refuses non-canonical records. Empty patches keep their revision at lines 164-165.
- Delivery credit fencing holds. Frame acks bind tick and origin sequence at `src/quod_physics.erl:174-176`, resource acks bind token and delivery kind at lines 177-192, no frame is sent while a resource is outstanding, and the client acks only when `live()` after verification and render in `client/src/simulation.js:167-248`.
- Retained identity holds. Equal input digests reuse the handle without sampling at `quod_voxel.erl:221-225`. Paint-only changes share the collision `Arc` and keep the collider through `chunk.rs:50-62`, the `TerrainChunk` equality in `geometry.rs`, and `terrain.rs:47-50`. Rebasing re-keys colliders without recreation at `origin.rs:52-59`.
- Determinism and bounds hold where I checked. Coordinates hash with sign and full magnitude at `quod_voxel.erl:397-399`, quantized values are odd and nonzero, crossings stay strictly interior, the MC33 interior products fit signed 64 bits as stated at `mc33.rs:36`, and payload coordinates fit 32 bits because both sides enforce the spacing bound.

Optional improvements:

- The halo is sampled and hashed but never consumed. `chunk.rs:47-49` reads only the interior nine-cubed sites, while `quod_voxel.erl:134-135` samples eleven cubed and lines 146-158 hash halo sites. A neighbour's edge-ring edit re-prepares a chunk whose output cannot change, and every chunk costs almost twice the needed sampling. If flat normals stay the profile, hash and sample only the consumed sites; otherwise document the reservation.
- Renewal re-sends a manifest and briefly blocks movement. A new watch drops `terrain_source` at `src/quod_physics.erl:81-84`, and the client discards its interest on every projection at `simulation.js:155` and 163-164. Each half-life renewal therefore costs two manifest round trips plus a window where `command()` at line 115 refuses input. Keeping `terrain_source` across same-socket renewals when regions and sent demand are unchanged removes both.
- `voxel_validate_chunks` re-samples and re-meshes consumers inside the dig proof, and the worker repeats that work on selection. Acceptable now, worth noting for repeated-operation cost.

## Scope of inspection and remaining uncertainty

I read in full: `src/quod_voxel.erl`, `src/quod_physics_coordinates.erl`, `src/quod_resource_basis.erl`, `src/predicates/quod_physics_predicates.erl`, the three voxel ontologies, the native `terrain.rs`, `origin.rs`, `voxel/mod.rs`, `voxel/chunk.rs` and `voxel/mc33.rs`, and the client `signed-view.js`, `simulation.js` and `voxel-profile.js`. I read every patch hunk for `quod_physics.erl`, `quod_runtime.erl`, `quod_client_view.erl`, `quod_common_primitives.erl`, `quod_physics_native.erl`, the shared physics, rendering, modelling and material ontologies, and the native `lib.rs`, `motion.rs` and `geometry.rs`, plus the unchanged owner seams those hunks depend on. I read the terrain parts of `render-resources.js`, `scene.js` and `marks.js`, the voxel test names, and the specific owner tests cited above. The two third-party facts come from the Rapier 0.36 sources in the local cargo registry.

Not re-derived: the MC33 case table and the case selection in `mc33.rs` beyond its fixture and seam tests, `ui/src/World.tsx`, the preview script, and Dialyzer-level typing. The pass counts in the request are the parent's reported evidence, not mine.
