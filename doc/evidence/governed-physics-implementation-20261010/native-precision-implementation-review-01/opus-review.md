# Verdict: **GO** for implementation, with 3 required corrections before commit

This is review only, not release approval. I looked only at the packet: no tools, no tree, no gates. None of the corrections changes production numerics.

## Required corrections

**R1. Out-of-scope diff.** `client/src/controlled-navigation.js` deletes the comment "A view renewal pauses input but does not recenter a human's headset." That has nothing to do with binary64. The behaviour it describes still holds, because the remaining line says only a changed run, binding, body or mount resets calibration. Revert it or move it to its own scope.

**R2. The vendored GJK comments overclaim.** Two comments promise more than the code does:
- The header says the dispatcher "refines the contact and approach direction at a zero TOI." It only refines when TOI < `1.0e-4`. An exhausted candidate at `niter == 100` with `ltoi > 0` skips refinement. It returns a conservative lower bound with the last separating-plane normal (`ldir`). Suggested text: *"Shape casts keep an impact candidate when convergence is uncertain. The dispatcher refines TOIs below 1e-4 by contact query; a larger candidate is a conservative lower bound with the last separating-plane normal."*
- The loop comment says "ray casts try the projected point once more." That is true only when `ltoi == 0`. When `ltoi > 0`, both modes return after the witness refinement, exactly as upstream does. Say that.

**R3. The oracle's claim is broader than what the test checks.**

The replacement is right in kind. The real obligation is that the dispatcher must not misclassify approach versus separation, and for within-skin cases the test checks exactly that:
- A start inside the skin gives TOI 0. The dispatcher then refines by `contact_support_map_support_map`, which does not depend on velocity.
- So the normal from the vertical cast is the same normal that `normal_vel >= 0.0` would classify for every diagonal travel.
- `|n−e|·|t| < |e·t|` is a sufficient condition for sign agreement, by Cauchy-Schwarz. The extra `assert_eq` on sign is redundant but harmless.
- Dropping Root02's "every edge approaches" assumption is correct.

Two gaps remain.

1. **Outside-skin edge and vertex samples (gap 0.002–0.0025).** These hits have TOI ≥ 1e-4, so the normal comes from the GJK `ldir` of a vertical cast.
   - A diagonal cast reaches a different impact point and TOI, and follows a different GJK path. Its normal is not the one being tested.
   - Normals at these TOIs are never sign-classified anyway; they only feed the slide projection.
   - Fix it one of two ways:
     - (a) Cast with each of the 12 actual travel vectors, and compare against the analytic normal at *that* cast's impact, including the horizontal shift `t·toi`.
     - (b) Restrict the margin assertion to `true_gap <= 0.002`. Report the outside-skin maximum (0.001850) only as slide-quality evidence.
   - Face samples are unaffected, since their normal is up regardless of travel.
2. **Coverage limits to state in the evidence.**
   - The margin property holds on this sampled set only. It cannot hold universally: at grazing travel where `|e·t|` is at or below the normal error, any nonzero error can flip the sign.
   - The consequence is bounded. Each step can drift into the skin by at most error × |t| (about 2.4e-5 m at 8 m/s), and the final `occupied` check catches it. That is a liveness risk, not a safety one.
   - The oracle covers only identity-frame horizontal triangles. Rotated frames are covered only by the movement matrix.

## Confirmed from the packet

- **Bias value:** `sqrt(eps_tol())` = sqrt(10·f64::EPSILON) ≈ 4.7e-8, which matches the stated value.
  - It is enough for a repeated contact on the same triangle. After a TOI-0 hit the pose does not change, so the refined normal is deterministic, and the bias only has to beat projection rounding.
  - It does not prevent ping-pong between triangles. Iterations, the check budget and the endpoint check bound that. "Liveness tolerance" is the right wording.
- **Patch boundaries:**
  - `cast_local_ray` passes `false`, so ray semantics are unchanged.
  - Both the converged branch and the `dimension == DIM` separation branch are untouched.
  - Returning early on stagnation at `ltoi == 0`, instead of upstream's last projected-point clip, is the correct choice. That clip can report a miss without proof, because the plane through `proj` does not bound the CSO.
- **CCD path:** Rapier CCD and Quod's rotating casts use `cast_shapes_nonlinear`, which uses conservative advancement rather than `minkowski_ray_cast`. Translational trimesh casts reach `directional_distance` per triangle, so the patch is actually exercised.
- **Prolog envelope:**
  - `((1 bsl 53)-1) bsl 971` is exactly DBL_MAX.
  - Integer-to-float conversion is monotonic, so every |X| ≤ Max converts to a finite float.
  - `Max + 2^971 = 2^1024`, so the `badarith` test does exercise real overflow.
- **Quarantine test:** with a box 1e308 × 1e-150 × 1e-150, mass stays finite (~8e8) but angular inertia overflows. So the test reaches quarantine through the intended path, not through an install refusal.
- **Matrix size:** 5 × 2 × 13 × 46 × 4 = 23,920 cases, which matches the stated count.
- **Cargo and bench:** `default-features = false` still keeps `dim3`, `f64`, `std` and `solver-bounds-checks`. The `{ok,Answer}` fix in the bench is correct.

## Non-blocking notes

1. **Upstream-identical patch.** When `ltoi == 0`, the patch now computes `result()` and then discards it. You could keep the upstream `if last_chance && ltoi > 0.0 {…}` block byte-identical and add a separate `if last_chance && conservative { return Some((0.0, ldir)); }` ahead of it. That makes the diff smaller and easier to audit.
2. **Zero-TOI acceptance and false blocks.** At zero TOI the dispatcher accepts an approach without checking `contact.dist` against `target_distance`. For `Land` with skin 0 and exactly tangential travel, numerical noise decides the sign, so a false `Blocked` is possible. That is conservative and the matrix shows none, but it should be listed as a residual risk.
3. **Refinement returning `None`.** If the contact refinement hits `closest_points` iteration exhaustion, the `?` turns a conservative candidate back into a miss. You already acknowledge this. Make sure `doc/physics-native.md` names it explicitly.
4. **Vendor drift.** The vendor audit is a one-time check. A small gate that verifies the archive checksum, applies the patch, diffs against `vendor/parry3d-f64` and checks the LICENSE would keep the tree and `parry3d-f64.patch` from drifting apart.
5. **Pre-existing saturation.** The `as i64` saturation in `rest_sample` and `hinge_samples` was not introduced here and is safe under the 1000 m policy. It is out of scope.
