# Native floor slide correction

The actual signed desktop view on 0.7.260 accepted a +X drive but stopped on the
flat annulus floor at `(2.68794584, 0.75199085, 0.36940792)`, before reaching the
roof. The source world, body and authored collider were preserved. The
[desktop record](desktop-260-02/README.md) distinguishes that failure from the
successful governed rescue and console contact.

## Cause and change

The [exact native reproduction](floor-slide-reproduction-01/) reaches a
zero-time contact. Projecting travel along the measured normal leaves a small
negative dot product in f32. At approximately −1.492e−14, another projection is
bitwise unchanged. The same contact therefore consumes all eight authored slide
iterations without advancing the body. This is a numerical defect in the common
native solver; no world-specific behavior is needed.

The shared slide operation now adds `normal * (16 * f32::EPSILON * travel.length())`
after its existing projection. This covers arithmetic and pose-frame roundoff
at the displacement scale. Every subsequent cast still checks every collider,
including the one just contacted. Geometry, policy budgets, identity, custody,
authorization and the ordinary Prolog control path are unchanged. No compatibility
branch, alternate controller or collider exclusion was added.

Production delta: three added lines (one arithmetic statement and two explanatory
comments). Four native regression tests add 96 lines. They cover the exact pose,
transformed capsule/mesh frames, floor and wall/corner in one surface, 2,048
successive moves with direct nonpenetration checks, and the measured non-unit
normal on a head-on approach. All 18 prior tests remain, for 22 passing native
tests. This establishes the tested cases, not a universal guarantee of slide
progress or a fixed cost for every shape.

## Review and failed experiments

[Fable plan review](floor-slide-plan-review-01/fable-review.md) rejected the first
proposed dominant-component correction for rotated frames and recommended this
smaller correction. That discarded mechanism was tested only in scratch crates.
[Fable implementation review](floor-slide-implementation-review-01/fable-review.md)
returned GO subject to the clean sequential release checks. Both true child exits
were zero; frozen packets and hash receipts are retained.

Three test-only normal literal spellings were shortened after the implementation
packet was frozen to satisfy Clippy. Their f32 bit patterns are unchanged
(`37bb4289`, `3f7fffff`, `b80c71e7`). The reviewed production bytes and assertions
are unchanged. The release campaign tests the exact final spellings.

The review's universal progress wording and fixed extra-query estimate go beyond
the evidence. Its debug/release equivalence claim was not backed by a separate
release-profile test at review time. Internal triangle edges are a possible cause
of the observed floor height variation, not an established diagnosis. Prior
unmodified desktop frames already show height variation; this patch does not
claim to repair it.

The initial candidate checks of at most six total queries and at most 2 mm
instantaneous height variation failed and are retained. Diagnostics show correct
stops with 5–7 total queries, and the long walk ends within one authored skin of
its starting height without penetration. Final tests assert these mechanical
obligations and that the eight-iteration slide loop is not exhausted. The
unmodified separating-motion control source and successful run are archived.

Release gate 01 ran a stale scratch executable from a shared Cargo target cache,
proven by a test name absent from the frozen source and no package compilation.
Gate 02 invalidated this package cache, passed all 22 native tests, then stopped
at Clippy's three test-literal warnings. Both failures and their corrections are
retained. Gate 03 passed native, Clippy, client and UI checks, then stopped at two
EUnit failures. The [test diagnosis](release-261-test-diagnostics/README.md)
identifies a leaked unrelated E2E owner causing the disk-write failure and
preserves the separate cancellation failure as unexplained. Two confirmed
fixture leaks now use the same OTP shutdown helper; cancellation diagnostics
retain the original assertion and deadline. All 170 focused tests pass.

Gate 04 passed all 22 native tests in both debug and release profiles, with
Clippy, client and UI checks also passed. It was then explicitly interrupted
after Fable identified an unbounded call in the test cleanup helper. The final
helper removes that redundant enumeration and uses bounded OTP shutdown
directly; all 16 affected fixture tests pass. The separately frozen
[gate 05](release-261-gates-05/README.md) passed all eleven sequential checks:
22 native tests in each build profile, Clippy, 126 client tests, UI build/lint,
3,880 EUnit tests, 146 Common Test cases, xref, Dialyzer and release packaging.
Every child and the runner exited zero, with unchanged frozen sources. The final
[test implementation review](release-261-test-implementation-review-02/disposition.md)
has no outstanding blocker. Test/helper changes add a net 125 lines, including
the native regressions, a real non-parent shutdown regression and failure
diagnostics; the superseded local cleanup implementations are removed.

The native correction is not yet deployed and desktop roof/opening acceptance
remains open. Separate hardware XR and durable closed-door consequences are not
claimed here.
