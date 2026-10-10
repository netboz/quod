Verified the remaining details: Babylon's forced parent recompute recurses to all ancestors, erlog's `sort/2` deduplicates, and the native sampler refuses any world with more rows than the poses allowance. I have what I need to write the review.

## Verdict

The mixed-scene stage is internally coherent and the three layers agree on the binding rules. I found no correctness defect in the pose writer, the exact body/revision binding, or the parent handling. I found two Medium policy/ownership issues, one Medium forward-coherence gap, and some low items. Outstanding QUD.27 work is not approved here.

## Defects and concerns

**1. Medium: the physics view no longer bounds the scene by any Prolog policy, and it re-implements a weaker copy of the rendering schema.**
`physics_view_bodies` checks distinct ids, parent order and integer transforms at `tree/priv/ontologies/quod_physics.pl:236-248`. Those are a subset of `well_formed_scene` at `tree/priv/ontologies/quod_rendering.pl:298-316`, without the scene count limit (512), offset/turn bounds, id/label bounds or material schema. The old `length(Marks) =< MaxPoses` guard was removed, so decorative mark count is now limited only by the reply byte limit at `tree/src/quod_client_simulation.erl:220-223`, which is an encoding constraint, not a budget. The repo already has one owner for this: `model/2` proves `well_formed_scene` through the rendering vocabulary (`priv/ontologies/quod_modelling.pl:22-23`). The view should require the same proof and add only the body-binding checks.

**2. Medium: the corrected MaxPoses check is vacuous against a running world.**
The native sampler fails with `pose_allowance` whenever installed rows exceed the poses allowance (`native/quod_physics/src/lib.rs:462-463`), and the same `limits` tuple is passed through at `tree/src/quod_physics.erl:649`. Every projected body must be a `physics_body` row (`quod_physics.pl:251`, and the controlled body via `physics_agent_configuration`), so distinct projected bodies are always ≤ rows ≤ MaxPoses while the world is live. The check at `quod_physics.pl:234` can therefore only fail when the world itself fails, exactly what server-02 showed. Either delete it and the `physics_required_allowances` call it exists for, or give the view its own policy budget. Keeping a redundant check is the duplicate-validation pattern AGENTS forbids.

**3. Medium (forward coherence): ordinary recipe-built scenes still cannot contain body-driven marks.**
`model_transform/2` emits only `transform` and `relative(_, transform)` (`priv/ontologies/quod_modelling.pl:49-52`). The fixture sidesteps this by hand-authoring `mark/7` terms (`tree/test/quod_physics_tests.erl:953-960`). The stage goal says ordinary scenes contain body marks. Either the modelling vocabulary gains `body_pose` and `relative(_, body_pose)` clauses, or the plan should state that physics views author marks directly. Not a defect in this patch, but a decision the next stage needs.

**4. Low: duplicate schema comment.** `tree/priv/ontologies/quod_rendering.pl:37-39` lists `body_pose` twice.

**5. Low: `attachment_pose/1`** (`quod_rendering.pl:214-215`) could be one guard on `placed/1`; two clauses are fine but not fewer lines.

## Verified correct

- **Parent-frame conversion.** Local = World × Parent⁻¹ in Babylon's row-vector convention (`tree/client/src/scene.js:90-94`). Babylon's `computeWorldMatrix(true)` recurses into all ancestors (`client/node_modules/@babylonjs/core/Meshes/transformNode.pure.js:1000-1003`), so body → decoration → body chains are not stale. Marks are painted parent-first (`scene.js:69-70`), so a body parent's pose lands before its body child reads it.
- **One writer.** `paintMarks` never touches a body-driven node's transform (`scene.js:46-52`); only `paintBodyPoses` does. Hidden poses hide attached decoration through ancestor enablement.
- **Exact binding agrees across layers.** Anchored `depicts/3` required for body marks in Prolog (`quod_physics.pl:249-251`), Erlang (`quod_client_simulation.erl:158-160`) and client (`simulation.js:53-55`). Exact set equality on projection and on every frame (`simulation.js:65-66, 74`). Delivered poses filtered to bound bodies plus controlled (`quod_client_simulation.erl:204-206`).
- **Distinct counting.** erlog `sort/2` is `lists:usort` (`_build/default/lib/erlog/src/erlog_lib_lists.erl:268`).
- **Nested `relative` rejected** in schema, view and client. Dangling parent rejected in all three.
- **Server-01 failure** matches the stated cause: the proof failed on mark count before the socket could observe the failed owner.

## Evidence limits

- Server evidence is one generator plus one module, not the standing clean sequential gates. No dialyzer/xref in this record.
- No Prolog-level test that `physics_client_view` refuses a dangling parent, a `body_pose` mark with `depicts_nothing`, a non-integer transform, or counts two marks on one body once. The rendering test covers only `well_formed_scene`, which this path does not call.
- No client test for a body-under-body chain or for a body mark whose parent changes between refreshes.
- `world-scene.js:214-226` still has two callers replacing the shared `painted` map (`paint` and `simulation`). This stage does not change that; it remains the normal-view-entry risk flagged in `world.md`.
- Not covered: remote collider subscription, negative-selection dependency tracking, physical admission/withdrawal, normal-view entry, any signed live-lobby acceptance.
