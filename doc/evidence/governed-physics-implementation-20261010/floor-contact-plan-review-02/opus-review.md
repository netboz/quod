*Note: this review ran on Opus 5.5. AGENTS.md asks for Fable on requested consultations.*

## Verdict

**NO-GO for step 2**, the collider-level contact-first check in `Space::cast`.

**GO** for steps 1, 3 and 5. Step 4 is a GO with the additions listed at the end.

The correction I recommend is a scoped fix in Parry's support-map shape cast, carried through the existing native dependency owner. `motion.rs` stays unchanged.

## What the captured logs already show

I derived these from your logs. The true gap is the capsule centre y minus 0.75, because the floor lies exactly at y = 0.

| case | true gap | `contact` error | target-0 TOI stops short by | depth inside skin |
|---|---|---|---|---|
| 1 | 1.7003 mm | +2.4 µm | 0.41 mm | 0.30 mm |
| 2 | 1.9208 mm | +16 µm | 0.25 mm | 0.08 mm |
| 3 | 1.7101 mm | +72 µm | 0.10 mm | 0.29 mm |

- **The cast is imprecise on this surface.**
  - Target-0 impact normals on a perfectly flat floor tilt by up to 7.2e-4 rad.
  - The cast's demonstrated error on these ~7 m sliver triangles is 0.1–0.4 mm.
  - The failing depths inside skin (0.08–0.30 mm) are the same order.
- **The `None` comes from GJK, not from traversal or the penetration flag.**
  - Target 0 finds the floor through the same composite traversal, so traversal is not the problem.
  - With `stop_at_penetration = true`, the small-TOI branch can only return `None` through its contact query, and that query works here.
  - So the `None` is produced by the per-triangle rounded GJK at λ = 0, before Parry's own `< 1e-4` branch.
  - That branch already implements exactly what step 2 proposes: contact query, then an approach test.
- **Hypothesis to pin:**
  - `minkowski_ray_cast` stops at λ = 0 on stagnation or the iteration limit, with no separating certificate, and reports a miss.
  - The same stagnation after the ray has advanced returns a conservative hit.
  - That asymmetry, uncertainty reported as "miss", is the defect.

## Blockers for step 2

1. **It only sees the nearest face.**
   - `query::contact` on a TriMesh or compound returns the single minimum-distance part.
   - A second face within skin still goes through the defective cast. Examples: a crease, a seam or shared vertex between coplanar triangles, a compound part on another face.
   - All three captured failures are single-triangle interiors (subshapes 2, 3, 2), so they cannot detect this.
2. **It duplicates an existing owner.**
   - Parry's small-TOI branch already says: within target and approaching gives TOI 0 with contact geometry; separating gives `None`.
   - Step 2 re-implements that one level up, with less coverage.
3. **It moves the failure band rather than removing it.**
   - `dist < skin` is decided by a query that overestimates the gap by up to 72 µm here.
   - Starts just inside skin can read as outside. Starts just outside skin may stall before the rounded cast's first advance.
   - Both cases keep the defect, and nothing in the plan measures them.
4. **`Land` also uses `Space::cast`, for both its path and its descent, and the plan does not cover it.**
   - The same defect likely causes spurious `no_support` for teleport targets at resting height.
   - Any reliable within-skin detection also changes path outcomes from a resting pose. A horizontal path would be classified by a floor normal tilted ~1e-4 rad, so `Blocked(floor)` becomes possible.
   - This has to be measured and decided now, not discovered later.

## Your direct question

- **Rotated frames:** fine, as long as `contact.normal2` is used exactly as returned (it is already world space). Do not apply `other.position().rotation` to it; that rotation belongs to the cast's local `normal2`.
- **Rotation sweeps (`turn ≠ 0`):** untouched, so preserved but not improved. This path uses target 0 and conservative advancement.
- **Multi-face and compound bodies:** not preserved within skin. Contact-first masks the defect for the nearest face of each collider and leaves it live everywhere else.

## Smallest sound integration

Fix the defect inside Parry, which already owns within-target semantics. Its composite traversal already applies them per triangle and per part.

- **Invariant:** a target-distance support-map cast reports a miss only with a separating certificate.
  - Uncertified exits (λ = 0 stagnation, iteration limit) return the conservative current λ, including 0, and never a miss.
  - At λ = 0, the existing small-TOI branch then decides approach versus separation.
- **Scope:** limit it to the shape-cast path (`directional_distance` → `cast_shapes_support_map_support_map`). Convex ray-cast semantics stay unchanged.
- **What this gives:**
  - per-triangle and per-part coverage;
  - correct frames via `pos12`;
  - one normal source and no threshold;
  - fail-closed behaviour on uncertainty;
  - no change to quod charges, budgets or policy;
  - endpoint refusal left intact.
- **Do not also add a contact-before-GJK reorder.** It brings back blocker 3.
- **Delivery through the existing owner:**
  - First check upstream Parry after 0.31.1 for a release that fixes this path.
  - Otherwise, apply one `[patch.crates-io]` over the verified 0.31.1 source (SHA256 `7b626edc…`) with a minimal diff.
  - Add a Parry-level unit test using the capsule and the actual sliver triangle.
  - Re-run the RustSec check and update the audit paragraph in `doc/physics-native.md`.
  - Report it upstream, and remove the patch once upstream ships the fix.
- **If instrumentation shows a different exit firing,** re-plan from that exit; do not stack fixes.
- **If the dependency route is rejected,** contact-first is still not acceptable as written. Per-part coverage would mean re-implementing Parry's composite traversal or its dispatch table, so that is a stop-for-decision point, not a fallback.

## Additions to step 4

- **Gap sweep:**
  - Cover skin − 0.5 mm to skin + 0.5 mm, at several lateral positions on several triangles, including seams and vertices.
  - Use the captured grazing travel, in identity and rotated frames.
  - Record the GJK exit kind for each case with bounded, removable tracing.
- **Two faces within skin:**
  - a crease, tested with each face as the nearest;
  - a coplanar seam and a shared vertex;
  - compound parts resting on different faces.
- **`Land`:**
  - descent from a within-skin target finds support;
  - a path from rest along the floor has an explicitly stated expected result;
  - a wall still blocks the path.
- **Rotation then translation:** a `turn ≠ 0` step that ends deep inside skin, followed by linear steps.
- **Cost:** checks per step in steady state, measured before and after the fix.
