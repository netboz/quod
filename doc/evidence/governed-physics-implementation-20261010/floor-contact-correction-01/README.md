# Contact correction diagnostics

The unchanged native solver reproduces all three occupied-floor pauses from the
80-second signed desktop recording. The preceding investigation and its failed
runs are retained in [investigation 01](../floor-occupancy-investigation-01/README.md).

These additional labelled campaigns use the real native crate in isolated copies:

- Regression 01 stops at a test compilation error: the translation accessor
  returns a vector by value, so dereferencing it was invalid. No test ran.
- Regression 02 corrects that test expression: 24 of 26 tests pass. Two old
  assertions counted queries as a proxy for slide iterations; each new contact
  query is now charged as well. Their original failing results are retained.
- Repeated 01 passes 8,736 movement steps over unrotated and transformed
  surfaces, checking horizontal progress and geometric nonpenetration each time.
- Obligations 01 replaces the query-count proxies with the same actual iteration
  bounds: fewer than eight surface slides and no more than two head-on contacts.
  No pose or collision assertion is removed. An exact allowance test verifies
  that N queries succeeds and N−1 exhausts without a usable pose. All 27 tests pass.
- Obligations release 01 passes the same 27 tests in the optimized native build.
- Clean 01 removes diagnostic printing and rejects nonfinite manifold distances
  and approach speeds. The three captured regressions also explicitly assert
  positive initial clearance and nonnegative final clearance. All 27 tests pass.

The correction uses all nearby contact manifolds in the existing linear sweep,
including every nearby face of a composite shape. It does not exclude a collider
merely because one face is separating. Same-mesh walls/corners, full separation,
rotated frames and the authored hole are checked. No geometry, Prolog allowance,
penetration tolerance, nonlinear sweep or final occupancy rule was relaxed.

[Receipts](receipts.json) retain true child exits and input hashes. The
[complete archive](diagnostics.tar.gz) includes sources, runners, logs and the
assertion-obligation explanation; [file hashes](diagnostic-files.json) identify
its contents. These are native diagnostics, not deployed desktop acceptance.
The implementation review and full release campaign are recorded separately.
