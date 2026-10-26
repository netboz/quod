# Atomic fixture completion race

Release gates 03 passed the formerly timing-out editor test in 1.153 seconds,
then ended EUnit with 4,243 passes and one failure. The first refused creation
following a successful atomic placement received `request_not_submitted,
agent_unavailable`. The STOP and full logs remain; later gates did not run.

## Cause

Twenty fresh fixtures reproduced seven failures. The exact actor was alive,
not stopping and had zero pending requests; admission saw an active events
runner at runtime height/frontier 7. A second bounded run identified that work
as a snapshot-only advance. Record-kind tracing shows the initial placement's
three DTX blocks at heights 6, 7 and 8. That heavier trace changed timing and
all ten instrumented cases passed; it is not contrary evidence or qualification.

The source explains the ordering: `quod_outcome:operation_candidate/4` marks
an operation referring to its local atomic group terminal when claimed. This
is receipt state, not evidence that the group has published Complete. The
existing fixture helper read only that operation row. `signed/2` therefore
could start its next readiness check after Resolve and before the asynchronous
Complete block. Complete advances the runtime snapshot, racing the next
attempt-now request. The architecture explicitly permits Complete after client
result delivery; production semantics do not need changing.

## Minimal correction

Extend the existing `quod_ct:await_operation_complete/3` fixture helper: if the
operation references an atomic group, wait for that group's indexed committed
or aborted outcome before returning the original operation row. Reuse the same
subscription, pinned Prolog owner, monitor and absolute deadline. Pending reads
wait for projection notifications. No sleeps, polling, request resubmission,
new executor, longer deadline or production change.

The real-owner regression uses signed placement through the existing personal
agent and the existing TEST-only coordinator terminal-phase barrier. It proves
the operation row is terminal while the group is pending, observes the helper
actually wait, releases the held coordinator, checks the group's committed
publication, and submits the independent refusal once. This prevents a passing
result from merely depending on the scheduler's timing.

The first original-helper run fails specifically with
`completed_before_group_complete`. The first corrected-helper observation
missed its trace because the module was not loaded; the final regression loads
it and asserts trace registration. That failure remains in `after.log`.
A subsequent copy-back comparison exposed stale compiled diagnostic beams:
preserved old timestamps did not force rebar recompilation. See
[cache triage](cache-triage.md); the affected runs are excluded, not relabeled.
Final explicitly rebuilt comparisons and uninstrumented focused validation are
recorded separately before integration and another frozen release sequence.

## Final verified result

The final uninstrumented before case (`before-v3`) fails at
`completed_before_group_complete`. After removing only the stale generated
helper beam, `focused-v3` passes all **34 tests**: six shared-helper tests, eight
space-creation tests including the held-coordinator regression, and twenty fresh
instances of the formerly intermittent case. The executed helper beam contains
`group_completion`; the runtime beam contains no diagnostic probe, and all
three restored probe source files match production exactly. See
[verified receipt](verified-rebuilt.json). Only the corrected helper and its
real-owner regression are integrated into the shared workspace.

The two additional test files add 62 lines and remove one (net +61). Together
with the earlier two fixture cleanup corrections, post-commit test changes add
136 lines and remove two (net +134). This growth supplies the scoped cleanup,
completion wait and real-owner regressions; production remains unchanged from
the committed head-view correction, whose production delta is net −97 lines, excluding the retired embedded test.
