# Clean integration 02 triage

The frozen campaign is retained. Its source is unchanged; corrections below
are in the live tree for a separately labelled campaign. The full EUnit run
finished with 4 failures and 4,067 passes (exit 1); later gates did not run.

## Pending query coverage lifetime

Two existing owner tests fail: `voxel_query_gap_preserves_registered_input_and_its_expiry_test_`
and `voxel_large_origin_rebases_pending_motion_without_restart_test_`.
The first reports a clear result at the original position; the second fails
its return to the earlier absolute position. This is a production defect,
not an assertion to relax. `terrain-query-gap-diagnostic-02` reproduces it
alone and records the complete frame: origin zero, tick 739, body still at
2 m and clear feedback for an input that requested 18 m. Diagnostic 01 never
ran a test because its EUnit selector syntax was invalid; its crash dump is
retained.

The collider preparation step refreshes mechanical demand from current
poses before the pending collision query runs. It drops the query's target
coverage and races the following step. The faster sparse selection exposes
this repeated eviction until the original input expires. The existing input
row now retains its canonical query coverage until consumption/cancellation;
ordinary demand combines the current bodies, pending inputs and viewer.
No additional owner, queue, retry, native API or deadline is introduced.
Expired discrete input now reports `expired` instead of the result of its
substituted zero movement.

`terrain-pending-coverage-fix-01` passes the two unchanged regressions.
`terrain-pending-coverage-fix-02` additionally checks actual expiry without
movement, eye demand and pending checkpoint insertion. Both original
registration and expiry assertions remain. Temporary frame logging is removed.

## Shared reader reservations

`four_disjoint_groups_select_once_across_real_vote_publications_test` fails
because newly recorded material-policy reads are common to all plans, and
the old reservation notification keys collapse readers and writers. A read
reservation then unnecessarily invalidates other readers' cached selections.

Selection dependencies and published changes now distinguish reservation
modes, using the existing conflict descriptor. Readers depend on writers;
writers depend on both. The shared owner, authenticated material and actual
conflict rules are unchanged. `reservation-modes-fix-01` passes the 96 existing
selection/admission/retained-vote tests. Fix-02 adds a new check but its fixture
authorizes only the first goal and correctly refuses the other two. Fix-03
corrects that fixture and passes all 97 tests, including comparison against
real read/read and read/write reservation decisions.

Neither these focused receipts nor the browser checks constitute a full
release pass. A new frozen campaign and Fable validation of the corrections
remain required.

## Published base token

The fourth failure is `overlay_apply_roundtrip_test`. Its fixture now uses
the real common projection base, which already defines `no_follow/1` at
height zero. The exact dependency expectation is therefore `{present,0}`,
not `never_present`. Only that stale expectation changed; the dependency
obligation remains. `overlay-base-token-01` passes all 21 overlay tests.
