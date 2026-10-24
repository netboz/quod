# Retained work verification — 24 October 2026

Yan requested review and commits for the work left outside the completed S1.2
commits. This scope retains the existing voxel terrain, physics coverage,
world-library UI and Prolog material-admission implementation. It also rebuilds
the packaged explorer from the current integrated source. Review fixes isolate
a trace measurement, correct a canonical signing fixture,
and make the notification branch return explicit. No runtime behavior was
changed, and no deployment or data reset occurred.

## Verification

The [combined receipts](verification.json) identify each exact frozen scope and
true child exit. Native debug and release tests passed (57 each), clippy passed,
234 client tests passed, and UI build/lint passed. All 4,109 EUnit tests passed
in [clean-03](clean-03/results.json). All 148 Common Test cases and xref passed in [clean-04](clean-04/results.json).
All 62 personal-agent, custody and hosting EUnit tests, xref, full Dialyzer and
production release assembly passed on the final [clean-05](clean-05/PASSED.json) tree.

Clean-04 differs from clean-03 only in one formatter call in a CT-only fixture;
production, native/browser sources and EUnit case implementations are unchanged.
The changed suite has no EUnit cases or callers from other test modules. The
[scope comparison](clean-04/comparison.json) records this boundary. Earlier gates
are not relabeled as fresh runs on another tree. Clean-05 adds only an explicit
`ok` after the unchanged notification send; its prior return value was discarded.
The affected agent suites and final static/release checks cover that correction.
UI lint exits zero with its
existing warnings; compiler warnings remain visible in the full logs.

## Failures and corrections

- [Clean-01](clean-01/triage.md) stopped because the sandbox denied a localhost
  TLS listener. Its EUnit run was cancelled, not passed.
- [Clean-02](clean-02/triage.md) ended with 4,108 EUnit passes and one failure:
  an unrelated trace left by a prior test was mistaken for history decoding.
  A private tracer and delivery barrier isolate the measurement. The retained
  [red reproduction](trace-red/test.log), [green checks](trace-green/test.log)
  and full clean-03 run verify both old-message isolation and detection of real
  decoding through the production predicate.
- [Clean-03](clean-03/triage.md) passed EUnit, then ended with 145 Common Test
  passes and three failover failures. Exact Prolog signing grants used the old
  formatter without a terminating period. The fixture now uses the signer's
  existing canonical clause formatter. The three allowed work values, authority
  checks, deadlines and recovery assertions are unchanged. All 148 cases passed
  afterward.

- [Clean-04](clean-04/triage.md) passed all 148 Common Test cases and xref,
  then Dialyzer rejected an unmatched mixed return value in agent notification.
  The send branch now returns `ok` like the other branch. Final focused tests
  and Dialyzer verify the correction; no warning suppression was added.

[The review corrections](review-corrections.diff) are included with the integrated
feature. Original failures, stop markers and historical review/deployment
records remain intact. Historical statements that source was uncommitted or
that a release was deployed describe those earlier snapshots.

## Scope and limitations

The retained source comparison and [shared integration delta](shared-integration.diff)
separate the earlier terrain implementation from the already completed S1.1
and S1.2 changes. Domain state, policy and authorization remain in Prolog;
existing transaction, recovery, runtime, physics and view owners are reused.
The obsolete explorer bundle is replaced; its prior directory is preserved
locally at `/tmp/quod-retained-work-original-explorer`.

The [production delta](production-line-delta.json) is +4,435/-548, net **+3,887**
lines against the pre-integration `d281e03` baseline. It excludes separate tests, embedded Rust test
modules, Erlang TEST branches, generated bundles, tools, docs and assets. The
[whole source-file count](source-file-line-delta.json), including embedded tests,
is net +4,395. Growth belongs to the retained terrain kernel, residency/coverage,
world-library functionality and shared policy admission, plus one line making
the existing notification return explicit.

The historical fresh-creation GUI lifecycle failure remains open; passing
terrain movement/reentry does not establish full fresh-creation acceptance.
Physical VR, fuller biome authoring and terrain-specific distributed measurements
remain outside the verified archived milestone. No deployment or source
installation was performed during this work.

Archived plans preserve their original incomplete progress. S1.2 remains
complete; stage 1 and the overall space plan remain open, and no later ticket
was started. Authored design/archive files and 1,646 historical evidence files
are retained. The [55 editor-local files](local-editor-files.json) are left
untracked: generated skills, transcript screenshots and the voice preference
note. Their contents are untouched.
