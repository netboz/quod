**Verdict: GO** for commit of this exact tree, after the standing clean sequential repository gates. No blocking correctness defect. The triage of the two relaxed assertions is justified, with one correction to its stated cause below. QUD.27 stays open.

## The numerical fix

- **The added line is correct and frame-independent.** The pre-fix stall is a true f32 fixed point: a residual below half an ulp of the travel's normal component can never be removed by the projection. The nudge adds a separating component proportional to the travel, so it is representable in every frame and scale.
- **The constant is adequate and the mechanism self-corrects.** In the trace, the nudge adds about 6e-8 against a worst-case frame mismatch of a few ulp of the travel. If some adversarial frame ever exceeded it, the next projection removes nothing and the nudge compounds to 32, 48 and so on epsilon per iteration. A persistent stall is therefore structurally impossible. The cost is at most one or two extra casts, never the previous eight.
- **Correction to the plan review's head-on claim.** In the pure head-on case the nudge is scaled by the post-projection travel, which is about 1e-7 of the original, so it contributes almost nothing. Head-on convergence comes from the projection itself: a sub-unit normal leaves a residual that shrinks geometrically to zero. The passing head-on test confirms convergence in two casts. The fix is still right; the credit is misattributed.
- **Acute creases remain unimproved**, as before the fix. Two normals meeting at less than ninety degrees alternate projections for more than eight iterations. The loop then exits with a safe clipped pose. Pre-existing, out of scope.
- **Debug and release agree.** Rust does not reorder or contract float operations, so the debug-profile native evidence transfers to the release NIF.

## Tests and triage

The relaxed bounds are justified, and the tests still catch the failure they prevent: the pre-fix solver would spend ten checks and make no x progress, so both the check-count and progress assertions fail without the line.

The extra casts and the height excursions share one cause the packet does not name. A flat face cannot tilt a contact normal; only an edge or vertex feature can. The swept cast is hitting the shared edges of coplanar triangles in the annulus, which deflects the projected travel upward. This is the standard internal-edge artefact of shape casts against triangle meshes.

| Diagnostic | Height | Delta from 0.752 |
|---|---|---|
| wall slide, identity frame | 0.76198 | +10.0 mm |
| wall slide, rolled frame | 0.76074 | +8.7 mm |
| 2048-step walk, max | 0.75406 | +2.1 mm |
| 2048-step walk, min | 0.75111 | -0.9 mm |

A ten millimetre rise over a quarter-metre slide will be visible as a hop at sixty hertz. Record it as its own finding, with the candidate remedy being parry's trimesh flags for internal edges, evaluated in a separate scope. The walk's dip inside the skin by under a millimetre is not explained by this packet either. Neither is introduced by the fix. The fix does make them reachable where the floor previously stalled.

## Validation gaps before commit

- The control test's modified travel vector is not in the packet, only its passing log line. Keep the control source in the evidence directory.
- No tests cover a yawed head-on contact or a floor that is sloped relative to the travel rather than rotated as a whole frame. Non-blocking; the rotated-frame case exercises the rounding path that mattered.
- The packet's source hash cannot be checked here. Confirm the committed motion.rs matches the verification hash before labelling.
- Repository gates have not run. Run them sequentially with true exits and confirm the release NIF rebuilt from the new source.

Production delta: one arithmetic line and two comment lines added, ninety-six test lines. No concept added.

The stop notification script could not be invoked because tools are disabled in this session.
