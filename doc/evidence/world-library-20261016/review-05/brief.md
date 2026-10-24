# Fable final validation: viewer removal during terrain coverage

Read AGENTS.md. Yan requested Fable review and authorized overnight completion
and deployment. Read-only: no commands, tests, builds, edits, memory writes or
delegation. This is consultative, not deployment approval. Return a complete
final disposition of the feature's previous findings and this final correction,
with remaining confirmed defects and risks separate, precise frozen references
and evidence limitations.

Review exactly `/home/yan/src/quod/_build/world-library-20261016/clean-integration-05/tree`.
Its 1,212-entry source manifest hash-matches. `since-04.patch` is the narrow
delta against your correction-review scope. `corrections.patch` retains the
complete delta against review-02 for context. Do not silently retarget to live.

Only four files changed since 04: the physics owner, its tests, the terrain
contract and the shared write architecture's recommended trust-boundary line.

The new real-owner disconnect case exposed a coverage wait with no pending
work after cancelling a reposition query. Diagnostic 01 asserts after real
runtime reconciliation; diagnostic 02 additionally waits for installed-state
notifications and times out with no remaining runtime work. Full causal
triage is `terrain-disconnect-diagnostic-02/triage.md`.

The correction shares input cancellation, including removal of retained query
coverage. Explicit unwatch and viewer death use one removal transition. Once
that consumer has gone, the existing native step decides whether body coverage
allows resumption. An unfinished restoration or invalid navigation source
keeps its wait. Internal clearing during installation does not reenter native
stepping. No new process, queue, timer, deadline or retry on an unchanged
selection was added. Inspect phase publication, cancellation, source guards,
pending insertion, and harmless stale/duplicate unwatch messages.

`terrain-disconnect-fix-02` passes eight focused cases: applied, expired and
disconnected query; removing a viewer during unfinished restoration and during
actual missing body coverage, both remaining unavailable until installation;
the two original pending-checkpoint cases; and large-coordinate motion/rebase.

Clean-integration-04 finished its EUnit gate with all 4,076 tests passing and
then honored the explicit stop request. Its STOP is not a failed child test
and is not a full release pass. Clean-integration-05 is a new complete clean
sequential campaign; inspect current receipts, never infer a pass.

The full bounded admission consultation and corrected trust assessment are
durable under review-02. Broader committee ingress hardening is recorded as a
separate future decision. The implementation preserves the existing trusted
execution boundary and intentionally permits valid zero allowances. No new
consensus allocation guarantee is claimed.

The isolated browser journey passed creation, walking, return and reentry,
before the last fixes; final deployed acceptance remains pending. Deployment
scripts require the exact final manifest, complete gates and independently
checked review findings. No remote mutation has occurred.
