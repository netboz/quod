# Independent implementation disposition

Opus5.5 returned GO for implementation with three corrections before commit.
It reviewed the narrowed code packet; it did not run tests or approve deployment.
The exact payload, output, actual model and true child exit are retained.

- R1 (renewal comment): rejected after checking the actual owner and tests.
  `createSimulation` keeps controls/frames live during early unchanged renewal.
  `client/test/simulation.test.js` tests this directly, and
  `client/test/controlled-navigation.test.js` proves held travel and authored camera
  calibration survive renewal. The removed sentence falsely said renewal pauses
  input; restoring it would contradict the already committed fix and signed262-02
  evidence. This is stale-comment cleanup in the same movement ticket, not a new
  client behavior change.
- R2 (vendor comments): applied. The comments now distinguish contact refinement
  below1e-4 TOI from later conservative candidates, and describe the raw-ray
  projected-point retry only at zero TOI. No production arithmetic changed.
- R3 (oracle scope): applied option(b). The analytic velocity-margin assertion is
  limited to within-skin starts, where time-zero refinement is independent of cast
  direction. Later vertical casts only measure slide-normal quality. The sampled
  assertion is not universal at arbitrarily tangent directions. The oracle itself
  uses identity-frame horizontal triangles; the behavioral matrix covers rotated
  and offset frames. Within-skin0.0003 bound and all original behavior/query-budget
  assertions remain unchanged.

The native documentation now explicitly names the upstream contact-refinement
None risk and conservative tangential blocking. The observed zero-None counts
are bounded measurements, not a universal certified-miss proof. The suggestion
that endpoint occupancy alone makes every upstream miss safe is not adopted.
No second geometry query, numeric tolerance change or policy increase is added.

The optional zero-TOI witness micro-optimization was left out: it does not change
behavior and is unnecessary for this correction. Vendored integrity is rechecked
against the published archive and minimal diff at the final gate. Pre-existing
i64 checkpoint saturation remains outside this change and within the measured
1000m deployment policy. No real body checkpoint is silently substituted.

Gate04 stopped at EUnit (3,884 tests / two failures), after native debug/release
34/34, clippy and client/UI checks passed. Its complete output and STOP are retained.
Both failures concerned test synchronization: retirement before the runtime's DOWN
handler, and Prolog replay readiness before runtime reconciliation. The tests now
observe actual owner message processing and take synchronous snapshots, preserving
the original assertions. Retirement is deliberately delayed to exercise that race.
The focused six tests pass. Final gate05 includes these test corrections and the
review changes: all eleven gates passed, including 3,884 EUnit tests and146 Common
Test cases. The ticket remains open until deployment and matching real signed
desktop acceptance.
