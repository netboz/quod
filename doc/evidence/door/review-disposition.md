# Door implementation review disposition

Claude Fable performed the user-requested read-only
[implementation review](implementation-review-fable.md) and validated the
[dependency repair](outcome-dependency-review-fable.md) before implementation.
It did not edit, build or test. The parent independently traced the findings,
implemented the corrections and ran the checks recorded in the evidence index.

## Observation delivery and recovery

- B1/B2: stale, held and certainly-unsent results re-evaluate the current
  selection, including selection-before-result. Replacement expiry resamples
  even while rejected original custody remains. Changed samples with custody
  re-resolve the exact original before replacement. The simulator matrix covers
  both delivery orders with and without retained custody.
- Policy budget changes are part of the observation basis, as are authority,
  run and structure. A certainly-unsent sample invalidated by a reduced budget
  therefore wakes/resamples. Resolution work records the current selection
  under which it was issued, rather than reconstructing an obsolete sample's
  basis. Both delivery orders and custody cases pass; the single-case negative
  control fails with `required_observation_lost` (one failure, no cancellation).
- B3: actor admission expiry is a certainly-unsent expiry; reaction guard,
  stale-executor and unmatched outcomes have distinct non-submitted states.
  Production tests cover a full runtime cursor and an observation actually
  admitted behind 15 actor jobs. Both obtain a later native step and finish.
- B4: an edit after custody storage but before the finish proof can produce no
  ordered original transaction. Exact resolution remains pending, as required.
  The production regression proves that authorized cancellation and a new close
  recover this case, and that the old signed sample cannot finish the new close.
  No elapsed-time rejection, original-request resubmission or deadline extension
  is introduced.
- Unavailable state retains an explicit reconciliation latch even after sleeping
  or another status update. Per-door state remains inspectable on the retained
  simulator. Existing scoped outcome notices wake exact saved operations;
  explicit reconciliation handles a failed read when no later notice is due.
  There is no recurring retry timer. The lost-latch negative control fails.
- Worker death or a normalized `proof_unavailable` cannot prove no custody write.
  These remain visibly uncertain rather than being classified as safe to repeat.
  The follow-up review's suggested broad reclassification is not safe at the
  existing public normalization boundary and was not applied.
- Restart now covers both a late original commit and a late original rejection;
  the latter retains custody until exact resolution permits fresh sampling.
- The native test now drives a braked leaf after it has slept and its obstacle
  moves. Another hinge remains independent. Restoration installs its stopped
  angle without replaying reaction events.

## Durable dependency contract

The original outcome bridge did not capture a read dependency; its initial
`committed_snapshot` declaration was removed, and the competing-edit test then
failed closed. The user authorized the shared repair after consultation.

The replacement is the common `committed_operation_outcome/3` bridge. It freezes
positive terminal evidence from the existing retained outcome index and captures
it monotonically in the existing read set before unification. The signed plan,
transaction codec, ordinary apply, atomic prepare, remote application and
read-only certification all carry/check the dependency. Existing predicate-only
canonical bytes are preserved. No class/name exemption or live native query is
used in a durable proof.

Pending, missing, future and infrastructure-unavailable evidence raises a typed
error, including under negation. A swallowed error retains the existing live
bridge marker and cannot authorize a nonempty diff. Successful failed
alternatives, negation and cuts retain the terminal dependency. Snapshot height
checks include Complete publication for groups. All immutable evidence fields
are rechecked; mismatch is an OCC conflict, while storage failure propagates as
an outcome error and cannot become a certified refusal.

Read extraction and descriptor construction now classify both read kinds.
Immutable terminal evidence needs no mutable reservation but remains signed,
counted and validated. Membership diffs refuse these reads; identity attestations
without an outcome context fail closed. In-owner verdict/reaction calls are
rejected before any owner call. The extraction negative control fails.

## Scope and limits

The profile is a vertical revolute cuboid hinge. Any active non-frame collider
contact is an obstruction, including a floor/stop. Prolog validates the bounded
angle rather than accepting an out-of-profile native pose. This does not claim
a generic joint, physical collision filtering policy, moving client control,
or impact-event replay implementation.

Re-verifying bounded custody signatures during a changed selection preserves
identity validation; repeated unchanged work retains the simulator and outcome
index. The cost regression traces ledger folding/opening, native construction,
file writes/sync and DETS insert/sync through the real owner. The shared duplicate
operation fix is covered by the exact signed door replay and shared operation
regressions in the full suites.

The immutable read-set extension requires compatible validators and the normal
founded-module deployment procedure. No commit, deployment or migration was
requested or performed.

## Names test gate triage

Campaigns 03, 04 and 05 cancelled the existing aggregate names round-trip test
at EUnit's default five-second timeout. Campaign 05 completed 3,388 tests with
zero assertion failures and three cancellations; later gates did not run.
An untouched HEAD full EUnit run passed 3,650 tests. Both that passing baseline
and campaign 05 logged one `system_catalogue_query_timeout`, so this log alone
is not evidence of a new door regression.

A separate unchanged-work probe measured all 24 round trips through the same
engine and naming ontology. Baseline: 2,851,457 microseconds total, 136,201
maximum, 331,216,124 reductions. Modified: 2,813,933 total, 134,414 maximum,
330,765,502 reductions. Earlier whole-test baseline/modified repeats also
matched at approximately 2.9–3.2 seconds. There is no measured per-query cost
increase from this change. The cancelled stack was in the existing bounded
failure-diagnostic validation during computation, not a mailbox/network wait.

The fixture now follows the adjacent ordinal tests: one shared committed source
and an independent wrapped proof per round trip. All 24 original cases and
assertions remain, each with the unchanged default five-second test deadline.
The isolated names suite passes all 419 tests. No production deadline, assertion,
resource cap or failure-diagnostic guarantee was changed. Campaign 06 was
separately labeled; no failed campaign was resumed or replaced.

Campaign 06 passed the regrouped round trips but cancelled the existing
seven-proof `saltless_draw_test` aggregate at the same five-second boundary
(3,416 tests, zero assertion failures, three cancellations). Its intended stop
after EUnit was already recorded because the budget dependency fix was pending;
EUnit's actual failure, not the stop marker, ended the campaign.

A fixed-seven-proof draw probe measured baseline 2,912,606 microseconds and
321,347,471 reductions, versus modified 2,869,280 microseconds and 321,051,659
reductions. The draw fixture now gives each proof ID its original full set of
assertions and default deadline. A separate check over those same IDs retains
cross-proof variability, and each full result is additionally compared with
that check's draw pair. The outside-proof refusal remains separately asserted.
No assertion was removed. The final focused set passed 721 tests: 427 names
cases and 294 physics/shared-proof cases. Campaign 07 freezes the resulting
source tree and runs every clean gate sequentially.

## Type-contract gate triage

Campaign 07 passed all 3,751 EUnit tests, all 145 Common Test cases and xref.
Dialyzer then reported one opaque-index contract warning at the new
`operation_dependency/3` owner call; release packaging did not run. The two
new public index helpers now declare their index argument/result contracts,
matching the existing outcome API. This is a type declaration correction;
no runtime behavior or warning suppression changed. Campaign 07 remains a
failed campaign, and the corrected tree is validated separately as 08.

## Peer startup gate triage

Campaign 08 stopped at the unchanged foreign-log material-route test while
`peer:start/1` awaited a child VM boot, before that test called the production
route case. It completed 1,089 tests with zero assertion failures and six
cancellations. Process inspection after exit found no surviving Erlang VMs.
The original test with its unchanged default EUnit deadline passed three times
on both the untouched baseline (0.452–0.503 seconds) and modified build
(0.582–0.841 seconds). The startup stall was not reproduced; these probes do
not establish its underlying cause. No code or timeout was changed for it.
Campaign 09 is a separately labeled full clean run on the same frozen source;
campaign 08 and its diagnostic probes remain in the evidence archive.
