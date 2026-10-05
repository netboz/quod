# Obstructed-door transition evidence

Implementation is uncommitted. Claude Fable validated the dependency design
before implementation; the parent independently checked and addressed the
review findings. See the [review disposition](review-disposition.md),
[implementation review](implementation-review-fable.md),
[repair plan](outcome-dependency-plan.md) and
[repair validation](outcome-dependency-review-fable.md).

## Acceptance coverage

The [physical interaction tests](../../../test/quod_physics_tests.erl) exercise
an authorized shared-class materialization, local desired-state installation,
ordinary close action, authenticated bounded observation and atomic consequence
through the retained simulator, runtime matcher, hosted actor and Prolog owner.
They cover blocked/closed results, duplicate and delayed signed requests,
competing edits, both observation/selection orders, policy-budget changes,
full runtime queues, admitted actor-queue expiry, restart with original commit
or rejection, exact outcome resolution, and explicit cancellation of unknown
pre-ordering outcomes. Repeated unchanged work is traced for native recreation,
ledger folding/opening, file writes/sync and DETS insert/sync.

The shared suites cover canonical read-set compatibility, extraction and
sealing, failed alternatives/negation/cut, unavailable-evidence sealing refusal,
read-only certification, ordinary apply, forged terminal evidence, group
Complete publication, and identity/context refusal without an outcome context.
Native tests cover independent hinges, braking, stopped-angle restoration,
retained installation and driving a sleeping leaf after moving its obstacle.

## Frozen validation

Clean campaign **09** passed every gate on the same frozen tree:

- Native tests: **2 passed**; Clippy with warnings denied: passed.
- Full EUnit: **3,751 tests, zero failures**.
- Common Test: **145/145 passed**.
- xref, Dialyzer and production release packaging: passed.

Base commit: `fbad63f2707d2ebfd6df48f9825e1d5a395eca4b`.

The clean gates run sequentially, retaining full logs and actual child exits.
`source-manifest.json` identifies the exact changed tracked files tested.
`validation-logs.tar.gz` retains all prior failed/interrupted campaigns,
focused checks, probes, scripts, negative controls and final gate logs.
`common-test-reports.tar.gz` contains the final full Common Test reports.
`SHA256SUMS` covers this evidence bundle.

## Failure triage and negative controls

- Campaign 01 was blocked by sandbox UDP permissions. Subsequent network tests
  used approved local-network access. No sandbox-failed run is counted as pass.
- Campaign 02 and the earlier supplementary campaign retain explicit stop
  markers. An interrupted zero exit without an EUnit completion summary is
  not counted as a passing test run.
- Campaigns 03–05 cancelled the aggregate names round-trip test. Campaign 06
  cancelled the seven-proof draw aggregate. Baseline/modified per-query and
  fixed-proof probes show matching work and cost. The fixtures now retain all
  original assertions with the unchanged default deadline per independent case;
  the cross-proof variability assertion remains. Details and exact measurements
  are in the review disposition.
- Campaign 07 passed EUnit, Common Test and xref, then stopped at one Dialyzer
  opaque-index API warning. The corrected public type contracts passed a
  separately logged Dialyzer check before the fresh campaign 08.
- Campaign 08 stopped in an unchanged child-VM startup (1,089 completed,
  zero assertion failures, six cancellations). The unchanged test passed three
  baseline and three modified focused probes. The transient stall was not
  reproduced or assigned a proven cause; code and deadlines stayed unchanged.
  Campaign 09 is a separate clean run on the same source.
- The untouched HEAD baseline passed 3,650 EUnit tests. It and the failed clean
  campaign 05 each logged a catalogue-query timeout; that log alone does not
  distinguish this change. No production deadline or assertion was weakened.
- Removing the extraction fix fails the read-set assertion; removing the
  reconciliation latch fails `reconciliation_lost_after_sleep`; removing budget
  dependency tracking fails `required_observation_lost` (single-case control:
  one failure, zero skipped/cancelled). Earlier negative controls retain the
  replacement-expiry, generic-observation-consumption and capacity-wake failures.
- The first budget matrix negative run has 12 intended failures and two
  cancellations at its outer EUnit timeout. Its internal wait limits remain
  unchanged; explicit outer timeout wrappers now allow those errors to report.
  The separately labeled single-case control establishes the intended failure.

## Scope and delta

Production delta, excluding embedded native tests: **+1,125 / −112 = +1,013
lines**. The growth implements the hinge/collider profile, door actions and
observation lifecycle, plus the shared exact-outcome dependency that the
existing proof contract required. It adds no process, broker, persistent store,
private physics outbox, readiness polling loop or sealing exemption.

Unknown originals that never entered ordering remain fenced until authorized
cancellation; timeout is not rejection. Any active non-frame collider contact
counts as obstruction in this profile. Independent operation result vectors and
generic joints are outside this terminal-read/door profile.

The new read kind requires compatible validators and the normal founded-module
deployment procedure. No commit, deployment, migration, history rewrite or
client motion/control implementation was requested or performed.
