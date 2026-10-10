Review complete. Verdict first, then findings and limits.

## Verdict: the corrected geometry slice is correct for its stated scope

The coordinate-reason leak is closed with no new regression and no missed caller. Paths and lines refer to the frozen tree under `implementation-review-03/tree`.

**Shared check is silent again.** `physics_coordinate/2` at `priv/ontologies/quod_physics.pl:408-409` only tests the binary32 envelope and the policy range. Every caller is an input, query or recovery path and none records a reason:

- motion query inputs through `physics_query_vector/2` at lines 60-61, used at 51, 53, 55
- push impulse at 185, teleport and reposition at 200-202, drive speed and turn at 206-207
- rest-sample position at 637 and quaternion components at 638-639

**Body reasons are isolated.** `coordinate_allowance(Limit)` is emitted only by `physics_body_coordinate/2` at lines 412-414, reached only through `physics_body_vector/2` at 410-411, `physics_valid_pose/2` at 368-372, `physics_dimension/2` at 386 and `physics_valid_vertices/2` at 392-393. Those are reachable only from `physics_valid_body/6` at 359-364, which has exactly one caller, `physics_checked_body/6` at 365-367, which has exactly three action callers: add-door at 343-344, move-body at 517, move-door at 539-540. No Erlang file in the tree names any of these predicates. The bridges at `src/predicates/quod_physics_predicates.erl:52-54` and `137-140` prove the projection goal as a plain prefix and attach no reason of their own when it fails, so a silent Prolog failure stays silent on the wire.

**Refusal classes are right.** A non-integer or out-of-envelope body value fails the outer `physics_milli_integer` guard at line 413 silently and surfaces only as `invalid_physics_body(Id)` from line 367. An in-envelope but out-of-policy value adds `coordinate_allowance(Limit)` as well. Rotation components at line 372 stay envelope-only, matching Yan's earlier ruling. Inputs beyond speed, turn, impulse or travel are class 1 as `doc/proofs.md:53-58` requires.

**Backtracking introduces no stray reason.** The three `physics_valid_shape` clauses at 373-378 have disjoint heads for `parts` and `surface`, and the solid clause fails without a reason for non-solid shapes, so no branch records a reason and then succeeds through a sibling clause. The only pre-existing reason-then-succeed possibility is several door definitions for one source at line 340 in add-door, which this patch does not touch and which the proof contract already handles by reporting reasons only on a failed result.

**Tests exercise the exact leaked path.** Fixture policy is speed 2000 and turn 1600 at `test/quod_physics_tests.erl:244-245`, push 5000 at line 319, travel 2000 at line 335 and coordinate 1000000 at line 342. The probes at lines 253-259 and 338-341 use 2001, 1601, 5001 and 2001, which exceed policy only, so a leak would reproduce. The filter on two-tuples tagged `coordinate_allowance` cannot be satisfied by goal breadcrumbs. The body-edit assertion at line 85 still demands the explicit allowance reason. Both exit records show child exit 0 and source hashes equal to the manifest, and the four corrected files match the request's description.

## Remaining findings

- **Low, nit.** `physics_body_coordinate/2` at `quod_physics.pl:413-414` checks the envelope twice, once directly and again inside `physics_coordinate/2`. The outer guard is load-bearing because it separates malformed encoding from policy refusal, so if anyone simplifies this, the inner repeat is the one to drop, never the outer.
- **Low, test labelling.** The third row at `test/quod_physics_tests.erl:75` places a part at 1000001 mm, which is a policy-range refusal, not a numeric-envelope one. It records both reasons and the assertion only checks the body reason, so it passes, but it does not belong under the "numeric" heading.
- **Low, residual and unchanged from the prior review.** Raw administrative rows with bignum density or motor scalars still crash `projection/2` at `src/quod_physics.erl:617-623`, and rotations up to the binary32 maximum remain accepted by choice.

## Limits of this validation

All evidence is local EUnit fixtures with explicitly founded identities. The unattributed datasync remains unexplained. The caller-attribution trace at `test/quod_physics_tests.erl:1053-1056` and `1126-1131` is in place but did not fire in these runs, so nothing new is known. Nothing here establishes remote propagation, a capability epoch, ordinary-view integration, admission or withdrawal through space policy, a signed current-lobby baseline or live desktop collision. The capability plan findings from the previous review remain open in full. This verdict accepts the shared body schema and its refusal contract, and nothing beyond it.
