# Review: governed native movement correction (frozen candidate)

**Verdict: NO-GO.** There is one code change to revert and two evidence gaps. The core correction is right: stagnation at λ=0 is now conservative, the witness guard is in place, the iteration cap is conservative, and ray casts are untouched. The Land clarification is acceptable.

This review ran on Opus 5.5 under your Fable fallback authorization. No tools were used, so I did not run the notifier. Code review only; release and desktop acceptance remain separate.

## Blockers

### 1. The convergence hunk turns a certified miss into a hit

Location: `vendor/parry3d.patch` hunk `@@ -820,12 +824,8 @@`, the bound-convergence branch of `minkowski_ray_cast`.

**Why the original `None` was certified:**
- The branch is reached only when:
  - `max_bound > eps_tol`, and
  - `min_bound ≈ max_bound > 0`, meaning the origin is outside the CSO behind a support plane, and
  - this iteration neither advanced (`dir·ray < 0, t > 0`) nor declared a miss.
- Together these mean `dir·ray ≥ -1.2e-7`: the ray does not approach the separating plane.
- That is a separating certificate for the ray. It only weakens inside the `relative_eq` band, which needs at least ~10 m of travel even at the smallest admissible gap.
- So the new comment "Convergence of the bounds supplies no separating halfspace" is wrong.

**What the change does:**
- **At λ>0** (ray advanced, then grazes past an edge or corner, or runs parallel to a face beyond skin):
  - A TOI ≥ 1e-4 skips refinement.
  - It returns `ldir` as the contact normal. `ldir` is the last lower-bound plane, roughly opposite the travel.
  - The slide in `motion.rs` then removes almost all travel, which is a false head-on stop.
- **At λ=0:** separated tangent pairs are pushed into the approach sign test. Examples are a parallel diagonal wall, or trimesh/rotated shapes that pass the broad phase.

**Required:**
- Trace 03 showed only stagnation at λ=0, and the plan said not to stack fixes. Revert this hunk.
- Keep the stagnation change and the `niter == 100` change.
- If a test fails after the revert, that is another exit firing; bring its trace.

### 2. The λ=0 decider still has uncertified "miss" exits, and exit-kind evidence is missing

**Where the gap is:**
- `shape_cast_support_map_support_map.rs:42` calls `contact_support_map_support_map(.., Real::MAX)?`.
- That call returns `None` in two uncertified cases:
  - `closest_points` hits its iteration cap and returns `NoIntersection(Vector::X)`, surfacing at `contact_support_map_support_map.rs:26`;
  - EPA fails, surfacing at `:72`.
- Either case turns a zero-TOI candidate into a miss without a certificate. The invariant "miss only with a separating certificate" is therefore not closed.

**Evidence still missing:**
- Plan step 4 asked for the GJK exit kind per case. The evidence only reports aggregate counts.

**Required:**
- Add bounded, removable tracing of (GJK exit, refinement outcome).
- Run it over the gap sweep, the three stall poses and the reciprocal walk, and report counts per exit.
- If contact-`None` fires, fix it at that site by returning a conservative hit; do not fix it in Quod.
- If it never fires, document it as a residual covered by the occupancy refusal.

### 3. Decider accuracy is not measured against the margin at the policy envelope

**What your own probe shows:**
- On the captured triangle (subshape 2), the same GJK/contact family reported −1.5 mm with a normal tilted 0.062 rad, for a body 2.28 mm clear.
- The cause: GJK's touching tolerance scales with support magnitude, about `eps_rel × 9 m ≈ 1 cm` at these coordinates.
- This is the tool that now decides approach at TOI 0.

**Why the margin matters:**
- The test travel descends at `atan(2.725/33.3) = 0.082 rad`, leaving a 0.02 rad margin over that error.
- The descent angle falls below the error in two cases:
  - grounded travel faster than about 2.7 m/s;
  - free-mode horizontal travel.
- Then a "separating" verdict lets the full travel penetrate, the final occupancy check refuses, and you get the original freeze.

**The existing test does not catch this:**
- `normal1.y > 0.99` in `target_distance_cast_finds_captured_triangle` allows 0.14 rad, so it does not guard the case.

**Required:**
- Rerun the gap sweep at the deployed policy's maximum speed, and in free mode if that mode is enabled.
- Record the decider's normal error.
- Tighten the assertion to the measured value plus margin.
- If it fails, stop for a decision; the fix belongs in the refinement owner.
- My plan review endorsed this branch as the single decider without asking for this measurement. Your probe shows it was needed.

### 4. Caller audit for the patched public function

- `gjk::directional_distance` is public, so the semantics change applies to every caller.
- List the reachable callers in the vendored Parry and in Rapier 0.36.0, such as `QueryPipeline::cast_shape`, the character controller and CCD.
- Confirm that the door and chair dynamics do not reach it.

## Assessed sound

- **λ=0 stagnation and witness guard:** returning `Some(0)` is correct. The `ltoi > 0` guard stops a zero-time candidate from advancing into penetration.
- **Iteration cap:** the conservative return is right.
- **Ray casts:** `cast_local_ray` passes `false`, so its semantics are unchanged.
- **Frames:**
  - Inside the cast, `normal2` is local to shape 2 in both the GJK branch and the refinement branch. `other.position().rotation * hit.normal2` is therefore correct.
  - My earlier "don't rotate" warning applied to top-level `query::contact`. The rotated-frame tests agree.
- **Multi-face and compound:** composite traversal covers each triangle and each part. The corner, compound and seam/vertex positions exercise this.
- **Land with target_distance 0: accepted as stated.**
  - It is a feasibility check, not a stopping margin.
  - It is consistent with the occupancy tolerance.
  - It keeps the sign-noise decider off the path except at real contact.
  - The doc states the change.
  - Residual: the descent still uses skin. A clear target within skin of a wall makes that wall a TOI-0 tangent candidate. At an equal TOI of 0, the `id < old` tie-break in `Space::cast` can pick the wall over the floor, giving `NoSupport`. This fails closed and is liveness only.
- **Policy:** numeric, budget and accounting policy is unchanged. Land path bounds are loosened by 0, so it may charge slightly fewer checks under the same accounting.
- **Oracle:** `intersection_test` errs toward reporting intersection, so it gives no false "clear". The replacement is sound.
- **No smaller sound fix exists:**
  - A git-fork patch is the same thing plus a network dependency.
  - `cast_shapes_nonlinear` has no target distance and uses the same contact family.
  - A Quod-side check is the rejected precheck.
  - The path patch is the right vehicle.

## Optional

- **Vendor integrity:** `Cargo.lock` no longer carries the checksum. Add a native-gate step that verifies the vendor tree against `parry3d-source.json`: every file except `gjk.rs` should match the published crate, and `gjk.rs` should equal the published file plus the patch.
- **Independent oracle:** for identity flat-floor cases, add an analytic check (capsule centre y − 0.75 ≥ −tolerance) that does not depend on Parry.
- **Land coverage:**
  - The Land path sweep only uses +x; add other directions.
  - Add a test for a clear target within skin of a wall.
- **Evidence labels:** the candidate04 log shows `review_skin_boundary_and_land_sweep`, which is not the frozen test name. Results for the frozen tree must come from the gate run currently in progress.
