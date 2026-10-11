**Verdict: non-blocker. The plan is correct and minimal; proceed.**

**Evidence confirmed.** The rejection trace in the summary JSON ends at `physics_coordinate(-0.0, 2000) physics_milli_integer(-0.0) integer(-0.0)`. That is exactly the frozen rule at `tree/priv/ontologies/quod_physics.pl:636`, and it is the right rule. The Prolog contract is integer millimetres and must stay that way.

**Causal chain confirmed in frozen code.** In `render()` of `tree/client/src/controlled-navigation.js:133-143`, backward S gives forward = -1. The grounded branch sets direction.y to literal 0, so scaling by -1 yields -0. With the default right-handed look along -Z, right.y is computed as `dz*0 - dx*0` = -0, and -0 + -0 stays -0 through scale and truncation. `driveInput` then calls `number(Math.trunc(-0))`, and `renderNumber` at `tree/client/src/prolog-term.js:92` deliberately spells that as `-0.0`. With a viewpoint mount of rotation(0,0,0) as in the live configuration, this reproduces the live term `vector(0,-0.0,2000)` byte for byte.

**Fix is sound.** `Math.trunc(value*1000) + 0` maps -0 to +0 under IEEE rounding and leaves every nonzero result untouched. It also covers the second way -0 arises, truncation of small negatives such as -0.4. The push guard `Number.isSafeInteger` is unaffected. The quantizer is the correct owner: its contract is "produce an integer milli-unit", so emitting a float -0 is its defect. The generic renderer must keep `-0.0` for code round-trips, as the existing test at `tree/client/test/prolog-term.test.js:160-163` requires. One shared helper replacing three copies matches the single-owner rule.

Consultative notes, none blocking:

- **The red test already exists outside the frozen scope.** The live repo has `client/test/locomotion.test.js` with the exact negative-zero and sub-milli cases for all three quantizers. The live `locomotion.js` is still unchanged, so it is red as required. Fold it into the frozen scope and record its failing run before the fix.
- **Keyboard-seam test geometry.** The existing fixture uses a 1571 yaw mount. With that mount the -0 may land on a different component or vanish, so use a rotation(0,0,0) mount for the S-key case to reproduce the live term, and confirm red on the frozen tree first. Assert on the signed spelling from `goalText` or `renderTerm`, since that is what the server parses.
- **Finite guard.** All three quantizers duplicate the finite check. The helper could own it too, but only if the three distinct error messages are not load-bearing for existing tests. Optional.
- **snapInput** is not a quantizer and needs no change. Callers pass ±1, and Prolog rejects a zero angle regardless.
- **Deployment claims** about an image-only update with no refound cannot be verified from the frozen tree. They are consistent with a client-only change that touches no ontology or wire format. Keep the label bump as its own commit per the standing rule.
