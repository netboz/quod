# Read-only Claude Fable rotation-boundary advice

Session ca58432f-ea5c-4d98-aeeb-c92a8e6a120b. Approved source payload; no writes, builds or tests. Advice is consultative and checked against the actual native transform and coordinate owners.

Checking the native transform order and every rotation consumer before answering.

Checked the native boundary and every rotation consumer. Short answer: your approach satisfies the contract, and there is no correctness reason to move the native pose format to quaternions.

**What the native actually does.** `geometry::transform` ([geometry.rs:64](/home/yan/src/quod_worktrees/pearl-stone/native/quod_physics/src/geometry.rs:64)) builds `q = Rz(r.z) · Ry(r.y) · Rx(r.x)` from f64 radians, so XYZ is applied about fixed axes in that order. That order has a unique, closed-form inverse for any rotation: from the matrix of the composed quaternion, `pitch = asin(clamp(−m20))`, `roll = atan2(m21, m22)`, `yaw = atan2(m10, m00)`, with pitch in [−π/2, π/2]. Native then rebuilds the same quaternion up to f64 epsilon. That is a representation round trip at the adapter boundary, not Euler arithmetic, which is what the contract's "do not add Euler angles" forbids (contract lines 290 to 293: compose matrices, one conversion at the boundary, established order).

**Gimbal treatment.** Decompose from matrix entries, not quaternion components, so `q` and `−q` give identical angles. When `|m20| ≥ 1 − ε`, fix `roll = 0`, `pitch = ±π/2`, `yaw = atan2(−m01, m11)`. That is deterministic and reconstructs the same orientation. Document the branch in `canonical_pose`.

**Determinism matters more than precision.** Native compares the whole `(V3,V3)` row for the unchanged and stale-revision checks ([lib.rs:201](/home/yan/src/quod_worktrees/pearl-stone/native/quod_physics/src/lib.rs:201)). Decomposed floats are a pure function of integer inputs on one node, so repeats compare equal. Keep the chain digest in the Prolog binding over the integer terms, never over the floats.

**Position.** Round the composed position to an integer mm anchor and carry only the sub-mm residual as the float offset. `origin/4` and `body_points` ([quod_physics_coordinates.erl:93](/home/yan/src/quod_worktrees/pearl-stone/src/quod_physics_coordinates.erl:93)) then keep their integer window maths unchanged, and rebasing stays exact for the anchor. Do not anchor at the root frame origin with a large float offset, or the window selection sees the wrong point. The `{world_mm, P, R}` shape is matched at [quod_physics.erl:529](/home/yan/src/quod_worktrees/pearl-stone/src/quod_physics.erl:529), :1099 and in `plan/7` (:72 to :80). Either fold the residual into `local_position` or extend the tuple at those sites only.

**Units in the chain.** Space edges are integer degrees (`space_transform`, gui `turn` 0 to 359) while the leaf pose is integer milliradians. Tag them in the descriptor, for example `edge(transform/6)` versus `pose/2`, and convert each in the composer. Do not infer by magnitude.

**Seams that keep Euler and need no change.** `Query::Place` ([motion.rs:168](/home/yan/src/quod_worktrees/pearl-stone/native/quod_physics/src/motion.rs:168)) and `reposition` are control inputs in the one domain world's frame, already integer mrad. `Travel` rotation is an angular displacement vector, not Euler. Compound part transforms are body-local. Hinge frames use quaternions internally (:388). Rest restore already accepts XYZW quaternions (:263) and samples emit them. The viewpoint mount is body-local. None of these see the composed chain.

**One concrete limit to refuse.** Terrain bodies assume an axis-aligned integer lattice in the local frame ([lib.rs:211](/home/yan/src/quod_worktrees/pearl-stone/native/quod_physics/src/lib.rs:211) validates chunks against the pose; `regions/1` uses raw chunk origins). A `voxel_field_v1` or `voxel_resident_v1` body under a non-identity or non-integer chain cannot be composed this way. Refuse terrain in exposed children for M3a with a named reason rather than rotating a lattice.

**Why not quaternions natively.** It would change the `Body` tuple, `Query::Place`, compound parts and the Rust tests for zero gain: orientation error from the round trip is around 1e-16, far below the integer mm authoring grid. Keep the native format; put the one composer in `canonical_pose`.
