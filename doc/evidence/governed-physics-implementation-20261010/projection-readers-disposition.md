# Retained projection reads: independent review

This is a completed local prerequisite for the remote collider work, not remote
collider installation or full task acceptance. Yan authorized Codex to review
independently while Claude/Fable was quota-blocked. No Claude review of this
stage is claimed. No deployment, live ledger write or refound occurred.

## Existing owner and replacement

Directory validation already calls `quod_foreign_log:projection_clauses/3`.
The previous subscription trace incorrectly described it as unused. Its public
caller remains; no compatibility branch was introduced.

The foreign-log owner verifies the actual caller against the retained follow,
instead of accepting a consumer PID supplied in the request body. The existing
materializer grants a shared committed MVCC handle identified by source,
height, projection ID and materializer generation. Evaluation runs in the
consumer's bounded worker, outside the materializer receive loop. No facts KB,
executor or propagation owner is added.

The materializer monitors each reader and includes its height in the existing
MVCC pruning floor. Normal return, exceptions and actual reader death release
the pin. Advancing a source retains versions still needed by a live reader;
release itself performs no ledger write, sync, history replay or rebuild. The
next real commit performs normal pruning. Building and stale generations fail
explicitly. Owner death during a clause read returns unavailable. The snapshot
handle supplies no Prolog principal, invocation grant or physics delegation.

The original absolute deadline reaches snapshot acquisition and result return.
The existing one-second maximum handle-lookup wait also remains. Late replies
use a deactivated alias, and cancellation/release messages address the same
materializer. A deadline never prunes versions underneath a still-live reader;
the existing bounded consumer must terminate its worker on expiry.

`quod_foreign_projection:clauses/4` and its receive-loop message path were removed.
The remaining `read/4` and pure `clauses/2` serve the production directory caller.
All known callers and exports were checked. No unused compatibility export was
kept for older tests.

## Verification and retained failures

- `projection-readers-01`: 216 tests, one failure. The new test expected source
  syntax for an interpreted fact instead of its compiled empty-body form. The
  assertion was corrected to the actual clause representation.
- `projection-readers-02`: six tests reported, three failures and one cancelled.
  The unchanged-work measurement mistakenly included an earlier cleanup trace.
  The cleanup barrier now consumes both call and return evidence. A normal test
  was also passed to EUnit's generator option; later runs use module selection.
- `projection-readers-03`: 30 tests passed. Completion, exception and reader-death
  paths retain an old value through a real committed source update, then release
  its version on the next real update. Stale/expired reads refuse evaluation.
- `projection-readers-04`: 218 tests, one failure. Removing the old clause API
  exposed one remaining genesis-manifest test caller. That caller was migrated;
  the obsolete API was not restored.
- `projection-readers-05`: 218 tests passed, including all foreign-log,
  materializer and directory-control tests and owner death during clause access.
- `projection-readers-06`: final 30 materializer/directory tests passed after
  restoring the original handle-lookup sub-deadline during independent review.

Every campaign records its true child exit and unchanged tracked input hashes.
Failure-injection diagnostics remain in the logs. Counts overlap.

Each completion/exception/death case performs 20 unchanged reads and traces both
reader and materializer. No canonical apply, MVCC commit, source-store open,
file write/pwrite, sync or datasync occurs in that measured interval. Real source
changes before it are separately applied and asserted. These measurements cover
retained projection reads only; they do not measure native geometry rebuilds or
prove the required remote physics update.

This prerequisite adds 51 production lines net across two existing owner files.
The accumulated authored production diff is +917/-359, net +558 across 29 files;
generated browser assets are separate. Growth supplies the missing concurrent
snapshot lifetime while removing the former clause-message implementation.

## Remaining work

The runtime still needs owner-issued access from its retained source follow to
its exact bounded resource worker, fixed source-owned Prolog definition selection,
observed source dependencies and source fences at selection and installation.
Authenticated source readiness, advance, recovery and removal notices must
invalidate those dependencies independently of best-effort reactions.

Live body bindings and source edits must compose with existing space admission,
exclusive assignment and withdrawal. Source geometry and receiver body/structure
revision, checkpoint and activity consequences must commit in one existing
atomic transaction. Remote installed-collider measurements, full lifecycle and
concurrency checks, coordinated release and actual signed desktop acceptance
remain outstanding. The task stays in progress.
