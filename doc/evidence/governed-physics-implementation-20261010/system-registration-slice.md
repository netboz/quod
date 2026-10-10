# Shared system physics registration

This is local implementation evidence for part of QUD.27, which remains open.
There was no deployment, live ontology mutation, refound or commit.

## Implementation

`quod_predicates:load/1` now registers physics alongside the existing common
committee and runtime bridges. All committed projection owners use that base.
Registration grants no permission and allocates no simulation. Prolog still
selects physical worlds, enabled state, authority, gravity, resource limits,
read permissions and control. Optional physics module entries were removed
from the hosting, space and failure-test fixtures; they use the common path.

The new production-owner cases use distinct `physics-policy-earth` and
`physics-policy-moon` ontologies. Gravity comes from ordinary
`attribute(room, gravity, Value)` facts through a derived allowance rule.
Signed body reads respect each world's Prolog permission. A committed gravity
edit replaces the native run while retaining its anchored world identity.
An initially disabled world allocates nothing. The canonical projection test
applies the same genesis to two fresh bases without adding physics to its manifest.
That is a deterministic materialization check, not full owner recovery. Existing
live-owner restart/replay tests are included in the broader regression run.
These fixtures do not establish the actual personal-lobby baseline.

## Compatibility cleanup

Yan reiterated that backward compatibility is not required. No compatibility
branch, loader, capability epoch, predicate renaming or alternate physics owner
was added to production. The old-manifest-only test case and compatibility-only
release instructions were removed. The removed `external_predicate_selection`
and `reconcile_modules` experiment has no production or test occurrence.

The collision investigation was unnecessary for this task's contract. Its
failed diagnostic and logs remain historical evidence; its source is archived
as `system-collision-diagnostic-01.erl.txt`, outside executable source/test
paths. It is not a required gate or active test. `system-collision-diagnostic-01`
failed because the standalone VM lacked the test helper path; `-02` demonstrated
the hypothetical name conflict. Neither requires preserving old definitions.
The task's actual personal-lobby identity/history requirement remains separate.

## Measured failure and correction

`system-worlds-01`: 138 tests, two failures in the strict unchanged-work check.
`system-completion-diagnostic-01`: nine cases, one failure. The next bounded
diagnostic (`-02`) had two failures and identified `remote_complete` writes at
`host-test-node`. In the capsule failure, its certified target transaction is
byte-for-byte the collider move already reported committed at `host-test-agent`.
This is the existing source receipt following target finality, not a geometry
rebuild from an unchanged check. Both target and source durability remain intact.

The test now observes the exact original operation's installed source receipt
before starting the unchanged-check measurement. It subscribes to the existing
runtime projection notice before reading the retained outcome, pins the owner,
uses an absolute deadline and waits only on newer projection notices. It neither
resubmits the write nor replays history. The global zero-I/O assertion is retained
and additionally watches ledger append. Temporary verbose diagnostics were removed.

`system-completion-fixed-01`: nine cases, zero failures.
`system-worlds-02`: 228 tests, zero failures across committed projection,
predicate failure, physics, control, space, runtime and agent hosting owners.
All measured source hashes stayed unchanged. `system-registration-cleanup-01`
then verifies the reduced projection test after removing the compatibility case.

The older unattributed `owners-geometry-02` sync is still not independently
identified by these later diagnostics. No claim of real remote unchanged-work
acceptance follows from these fixtures. All failed logs and stop markers remain.

## Outstanding feature work

Live referenced collider selection and invalidation must extend the existing
subscription and retained projection owners. Admission/withdrawal binding,
ordinary-view dependencies and authored pose/camera preservation remain to be
implemented and verified. The real signed current personal-lobby baseline and
desktop collision acceptance have not been obtained. Deployment remains with
the existing release authority and a single server writer.
