Verdict: GO for the scope and constraints, BLOCKED on the mechanism as written. The dominant-component ulp nudge is not safe outside identity frames. A simpler equivalent exists.

**What the trace actually shows**

- The first projection leaves a residual of about -5e-10, which is the non-unit normal plus rounding. The second lands at -1.5e-14, which is below one ulp of the y component, so the subtraction can no longer change the vector. That is a true fixed point, and dividing by the squared normal length does nothing about it.
- The cast treats a time-zero contact as blocking only when the travel strictly approaches it, so the fix must leave the travel representably separating in the frame parry evaluates, not in ours.

**Why the proposed nudge fails**

- One ulp of the dominant component is ~6e-14 here. Parry recomputes its dot in the body's local frame after rotating travel and normal by f32 quaternions. For a yawed agent or a posed mesh, that rounding is ~1e-9 for this travel, five orders above the nudge. The repro passes only because both poses are identity. Production agents yaw, so the stall would survive the fix.
- Picking a "stable dominant component" is a new concept with no error analysis behind it, and the scale of one ulp varies with which component dominates.

**Simpler robust equivalent**

After the existing projection, add a separation along the normal scaled to the format's rounding:

```rust
travel -= normal*travel.dot(normal).min(0.0);
travel += normal*(16.0*f32::EPSILON*travel.length());
```

- The factor comes from the error budget, not tuning: two quaternion rotations of ~4 ulp each plus the dot product of ~3 ulp, so 16 dominates in every frame. It is relative to the travel, so it is not a fixed distance epsilon and does not change the tolerance or skin.
- It moves the body outward by ~1e-8 per contact, physically nothing, and the final occupancy check stays.
- The squared-length division becomes redundant and should be dropped. Net change is one line and zero new concepts.
- It also fixes head-on contacts, where the current code burns all iterations and every per-collider check on a rounding-level residual. In a dense scene that can return Exhausted.

**Required tests, in order**

1. Control before coding: at the exact repro pose, cast the unmodified binary with the projected travel plus a strictly separating y component. Expect no time-zero contact. If this fails, the premise is wrong and the fix is misdirected.
2. The repro as given, through `apply`, asserting progress and no penetration by querying the final contact distance directly, not only the occupied check.
3. The same mesh with the body yawed and with the mesh under a non-identity pose, plus sloped planes. This is the case the ulp nudge cannot pass and the repro does not cover.
4. Head-on wall and two-normal corner: assert convergence in two or three cast rounds via the returned check count, and a non-penetrating endpoint.
5. Long walk: at least two thousand apply and step cycles circling the annulus under gravity. Assert the height stays within one skin of the start and the answer is never Occupied or Exhausted. The GJK normal noise of ~1e-5 radians can sink the body a few hundred nanometres per step. If it drifts, report it as a separate finding rather than widening this scope.
6. Existing thin wall, hole, rim, and budget tests unchanged.

Drop the trace prints from the committed test. Pin the invariant in a comment above the projection so the parry dependency is explicit.

The stop notification script could not be invoked because no tool access is enabled in this session.
