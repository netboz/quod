# Release timeout: retained fixture observations

The unrestricted-view correction is committed as `de1e9af4`. Both original
release qualifications remain failed. The third qualification is justified by
the test-lifecycle correction below, not by an unchanged retry.

## Diagnosis

The instrumented full sequence reproduced the same cancellation after 4,039
passing tests. Its editor input was exactly the same 21,008 bytes and SHA-256
as the isolated run. Compiler/target bindings and variable counters also matched.
The full runner carried 2,013 messages from previous fixtures. This was evidence
of retained state, not sufficient proof that message count caused the timeout.

Separate reductions eliminated the retained catch-up dictionary and the large
agent-tracing mailbox as sufficient causes. A nine-module prefix reproduced the
timeout after only 149 passing tests. Its two halves passed separately. All
commands, exits, failures and phase observations remain in triage-02 through
triage-13; none is a release qualification.

GC tracing measured 6,376,042 retained binary bytes before the combined case.
During that diagnostic case it recorded 182 major collections versus 12 in the
isolated control, and 1.544 seconds in GC versus 0.337 seconds. Instrumentation
changed the observed timing: this particular traced run passed in 2.303 seconds,
while the untraced reduced sequence timed out. These measurements identify the
memory cost; they are not a claimed repeat of identical wall-clock timing.

The endpoint fixture stopped its owner but left `endpoint_result` and
`history_capture` snapshots in the shared EUnit runner. The hosted-ontology
fixture also left a full `committed` entry for its stopped `host-test-agent`
namespace. The endpoint-only cleanup passed its new regressions but did **not**
resolve the reduced timeout; that failed attempt remains in triage-12.

## Correction and checks

Two existing test lifecycle owners now dispose their own observations after
their senders have stopped:

- Endpoint teardown removes only result/history observations carrying its exact
  stopped owner PID.
- Hosted-ontology teardown removes commit/head observations only for its two
  stopped namespaces.

No production module, Prolog compiler, deadline, assertion, GC setting or
execution order changes. There is no general mailbox flush. New regressions
exercise real endpoint work and real ontology commits, verify observations
actually exist before teardown, repeat the fixtures, and preserve unrelated
owners' messages. Endpoint cleanup is also checked through an exception.

The first endpoint regression used `committed` where the existing vote helper
expects `applied`; those two failed diagnostic runs are retained and explained
in triage-12. After correcting that new assertion, both endpoint cases fail
with `retained_endpoint_snapshot` before cleanup and pass afterward. The host
regression likewise fails with `retained_fixture_commit` before cleanup and
passes afterward.

With both cleanups, the formerly failing reduced sequence passes all 157 tests.
The source-edit case takes **0.600 seconds**, with its original five-second
deadline. Its two compiler calls consume about 39.3 and 39.2 million reductions,
consistent with the isolated control rather than the extra GC work of the
failing sequence.

Only these two test files differ from the second failed release's build inputs.
The original user-owned patch remains exactly
`38f36875692d0044db4d5d86796c55ecc3f65f72423e167bbd6d292d3355ef04`.
The cleanup and three real-owner regressions add 74 test lines and remove one;
the committed head-view production delta is net **−97 lines**, excluding the retired embedded test.

The fresh twelve-gate run is [release-gates-03](../release-gates-03/freeze.json),
frozen at `de1e9af4` plus its recorded working patch. It must pass in full before
image packaging or rollout. Earlier STOP markers and all failed physical
evidence remain. No additional ledger reset or live ontology update is planned.
