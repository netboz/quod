# Plan review: native binary64 after the triangle-edge freeze

**Verdict: GO, with the corrections below.** This approves the plan only. It does not approve implementation or release.

I reviewed this on Opus 5.5 under your Fable fallback authorization. I used no tools, so I did not run the stop notifier.

## Is binary64 the smallest sound response?

Yes. I have no f32 alternative to offer.

- **Where the error comes from.** The owner is Parry's GJK. Its tolerance is `eps_rel = sqrt(10·eps)`, scaled by support magnitude. That tolerance controls both the convergence test and the touching classification.
  - In f32, `eps_rel` is about 1.1e-3. Worst-case direction error on a curved feature is roughly `sqrt(2·eps_rel)`, about 0.05 rad. That matches the 0.069 rad your oracle found.
  - The triangles themselves span several metres, so recentring the frame would not shrink the supports.
- **Why there is no f32 fix.**
  - Tightening `eps_rel` in f32 runs into roundoff. It would be a guessed tolerance change.
  - An exact capsule–triangle routine would be a second geometry query.
  - Subdividing triangles would change authored geometry.
- **Why f64 is acceptable.** Rapier3d-f64 and Parry3d-f64 are the same upstream source with `Real = f64`. That is a single engine, not a fork. It should also shrink the code, since the casts go away.

## Necessary corrections

### 1. Step 4: drop the quotient/remainder helper

- **The problem with the helper.** `Q + R/1000` rounds twice. Erlang's `X/1000` rounds once for |X| < 2^53. So the helper is not bit-identical for ordinary values, and that contradicts "its normal working geometry is unchanged".
- **The simpler fix.** The real encoding constraint is that Erlang's integer-to-float conversion stays finite. Set the milli and micro envelope to `|X| ≤ physics_native_scalar_limit` (the largest finite double, written as an integer).
  - Then the existing `X/1000` is total and unchanged.
  - Delete `Limit is Max * 1000`. No new conversion concept is needed.
  - Density and motor scalars keep the direct check.
- **Tests.** Test the exact boundary and boundary+1 through the real Erlang conversion. Keep these separate from the coordinate-policy refusals.

### 2. Deployment: name the delivery authority for `quod_physics.pl`

State whether the envelope rule reaches the existing personal world in one of two ways:

- **(a) Shared startup base.** All validators then switch together, which your cold single-cohort deploy covers.
- **(b) Installed ontology content.** Changing the file does nothing to the existing world. That world keeps the narrower binary32 envelope, which is safe; widening it needs an ordinary authorized edit.

Also confirm that no existing founding manifest pins a digest of that file.

### 3. Deployment: restoring existing checkpoints is an explicit acceptance item

Committed `rest_v1` poses and hinge angles were measured under f32. Under f64, zero-displacement recovery recomputes contact distances.

- If a restore fails, the failure must be visible. The exit is an authorized body edit, never a silent fallback to the baseline.
- Record each checkpointed body's restore result in the restored-state evidence.

### 4. Deployment: state the rollback behavior

Rolling back to candidate262 is safe for persisted state. The one exception: a value authored above the f32 range during the candidate's lifetime would make the f32 native refuse installation, visibly. Say this.

### 5. Step 3 bias: state the rationale honestly

- **What the bias is.** It is a slide-loop *liveness* constant. Correctness still comes from casting every collider and checking final occupancy.
- **Measured margin.** About 4.7e-8 against roughly 1e-10 normal disagreement, so about 470×.
- **What it is not.** It is not a bound on worst-case GJK error. In f64 that worst case is around `sqrt(2·eps_rel)` ≈ 3e-4 rad on curved features.
- **Required measurement.** Re-measure repeated-contact normal spread at the deployed world's actual `CoordinateMm` allowance, in both offset frames.

### 6. Re-trace and vendor integrity under f64

- **Trace.** The exit/refinement counts, including the zero contact-`None` result, were measured on f32. Rerun them on the f64 build and report the counts.
- **Vendor integrity (now required, not optional).**
  - The published parry3d-f64 0.31.1 `gjk.rs`, before patching, must be byte-identical to the f32 crate's, so the reviewed patch is the same patch.
  - The vendor tree must equal the published crate plus that patch.
  - `cargo tree` must show no `parry3d` or `rapier3d` (f32) anywhere.
  - Re-verify that the `solver-bounds-checks` feature exists.
  - Run a fresh RustSec check against the new package names.

### 7. Representation cleanup: drop only the cast-induced checks

Remove cast-only tests such as `(x as Real).is_finite()`. Keep the semantic checks: positive, finite, nonzero step, and mass > 0.

### 8. Step 6: record the memory cost per allowance unit

f64 roughly doubles the bytes per vertex, triangle, BVH node and body.

- Report bytes per allowance unit at the deployed policy limits.
- Redo the measurements behind the in-process audit: four 64-body worlds, dense overlap and destructor timing.
- Update the "keep in-process" section of `physics-native.md` from these measurements, not from the old ones.

## Assessed sound as proposed

- **No refound.** Ledger values are integers and physics is runtime-only. Recovery through activation custody starts a fresh run.
- **One precision, no switch.** Rapier, the vendored Parry and the docs are replaced in one scope. The binary32 statements in `physics-native.md` must all go.
- **Minimal patch.** It keeps only stagnation and iteration exhaustion, with no convergence hunk or precheck.
- **Caller audit.** CCD's sweep and nonlinear routes do not reach `directional_distance`. Rerun the audit against the f64 sources.
- **Oracle.** It must be an analytic face/edge oracle, plus vertex cases. The new oracle should also cover what the existing face-only normal test missed.
- **Policy is unchanged.** Budgets, counts and assertions are unchanged. Every failed probe is preserved, and XR and doors stay as separate tickets.
