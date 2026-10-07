# Node enrollment implementation evidence

This records local verification before the first implementation commit and
rollout. No live state was changed during these campaigns. Subsequent commits,
authorized retained policy activation and fleet results are recorded in
[deployment.md](deployment.md).

The tracked production delta is +687/-89 lines (net +598); tests are +706/-67
(net +639). Growth adds the Prolog enrollment recipe and allocation policy,
durable two-phase request custody in the existing pointer, notification-driven
startup in the existing manager, and coherent advertisement authority. The
manual Erlang founding recipe was removed; there is no additional service or
workflow process. Tracked compact documentation adds 14 lines, with the new
contract and these evidence/review records reported separately.

## Frozen scopes

- `tree-01.json`: initial implementation reviewed by Fable, before its three
  requested fixes. Gate campaign 01 stopped on the first failing gate.
- `tree-02.json`: implementation, tests and compact contracts after those fixes
  and retained-policy coverage. Review/evidence records are excluded so results
  can be recorded without changing the tested scope.
- `tree-03.json`: intermediate scope including the authentication owner's readiness
  event, manager subscription/incarnation check, removal of the superseded
  application startup cast, and the clarified unknown-custody contract.
- `tree-04.json`: final scope with both auth/router owner-ready notices and the
  distinct full-application startup barrier restored. No authority or custody
  rule changed in these last readiness edits.

Hashes and full logs are retained in
`/tmp/quod-node-enrollment-20261006`. Each gate campaign writes `results.json`
with its actual child exits and durations, stopping on a nonzero exit. Commands
run sequentially with `ERL_FLAGS='+S 4:4'`. Loopback Common Test execution uses
the explicitly approved sandbox escalation; the original sandbox refusal is
retained in `remote-enrollment-01.log`.

## Review disposition

Fable's reports are consultative. The parent independently inspected the
executor binding, Prolog grants, signed ingress boundaries, outcome ownership,
pointer custody and directory authority. The initial review's expiry-based
retry suggestion was rejected and retracted. Its later suggestion to delete a
pending request after observing no allocation was also rejected: absence never
proves that custody cannot later commit. Refounding is not permission to replay
an uncertain operation against its original history.

The tree-01 findings were addressed by removing the unused `node_vocabulary/2`
founding fact, recording an explicit allowlist of definite pre-execution
refusals, and consuming installed terminal negative outcomes of the exact
winning operation claim. Generic errors, missing claims, selected refused
attempts and effect-journal errors remain unresolved. Enrollment is atomic;
activation is an ordinary single-ontology write, so independent mixed outcome
vectors do not authorize a replacement request.

The reviewed catalogue boundary is intentional: withdrawal ends shared system
authority, but an independent ordinary discoverable hosting fact can retain a
route to that exact history. A conflicting anchor under a still-catalogued
namespace is rejected. Target ACL and membership checks remain mandatory.

Fable's delta review found all three fixes safely resolved and no new
authority; it remains conditional on the clean gates. Its contract wording
correction is included in tree-03: unknown pre-admission custody has no defined
retry or retirement procedure while the original operation remains unknown.

The parent's subsequent lifecycle review found that an authentication-service
restart did not wake a waiting enrollment manager. The existing auth owner now
publishes its installed readiness, and the manager subscribes before its
snapshot and checks the sender's current process identity. Fable reviewed this
delta as safe. Its nonblocking unsubscribe cleanup suggestion was applied before
tree-03. A subsequent startup-order check showed that auth precedes the goal
router in the supervisor, so the application-wide startup barrier is distinct
and was restored in tree-04. A router-only restart now emits its own equivalent
owner-ready notice as well. Fable's final review confirmed all three startup
cases; these notices add no process, polling or timer and leave uncertainty
handling unchanged.

## Local acceptance evidence

- Automatic founder enrollment, verified binding, ordinary self-hosting,
  manager restart and changed endpoint preserve the exact pointer. An unchanged
  repeat spawns no enrollment worker, commits nothing and leaves pointer file
  metadata unchanged.
- Signed creation through different source and root executor peers records the
  actual custodian atomically. A fresh applicant joins its identity as an
  observer, self-hosts through the existing custodian, and performs a signed
  read while remaining a root observer (`remote-enrollment-11.log`).
- Crash custody tests retain requests before send, after commit/lost response,
  and after allocation. Before-send uncertainty remains visibly unresolved;
  no automatic resend is performed. Definite failed-proof and admission
  refusals can recover through the real owner.
- Retained policy installation uses a signed administrator transaction through
  `system_prolog_edit`, installs the template, existing founder allocation,
  ordinary hosting delegation and root delegation atomically, restarts the
  class subtree, and checks the unchanged anchor and founder pointer.
- Pointer corruption, wrong key/anchor/instance and altered signed goals fail
  closed. Directory coverage includes real signed certified receiver checks,
  non-control node system publication, exact ordinary hosting, private-route
  preservation, inactive keys, invalid catalogue anchors, bootstrap withdrawal
  and retained-identity loss of readiness. The existing forged-role test still
  requires target authority.

These fixtures are not a live retained-fleet migration. Initial identity
committee control and write availability remain with the creation executor;
enrollment grants no committee seat. Unknown pre-admission custody can remain
unresolved indefinitely under the selected strict rule.

## Runs and failure triage

- Focused directory runs: 31, 44 and 45 tests passed as coverage expanded.
- `lifecycle-focused-01`: newborn read preceded effect readiness; corrected to
  subscribe and snapshot the existing proof-ready owner. `-02`: 49/0.
- `enrollment-focused-02`: test syntax compilation error, fixed. `-03`: 50/0;
  `-04`: 65/0. `-05`: teardown stopped root while the manager still queried it,
  then leaked fixture owners caused three setup failures. Teardown order was
  corrected; `-06` and `-07`: 69/0.
- Remote runs 02–04 diagnosed a fixture module-manifest omission, then exposed
  a real opaque-wire-symbol compilation defect in ontology founding. The
  production fix uses the existing bounded materializer after authorization
  and before reserved-head validation. Run 05 committed correctly but asserted
  the wrong not-hosted error; run 06 passed. Runs 07–10 corrected the extended
  applicant fixture's supervisor reference and retained bootstrap/storage
  configuration. Run 11 passed the full automatic applicant path.
- `focused-integrated-01`: 115/0, before tree-01's last readiness refinements.
- `gates-01`: both cleans passed; full EUnit 3760/0, exit 0. Ask suite 41 passed,
  1 failed, exit 1: the new fixture installed epoch 1 after an earlier recovery
  case installed epoch 3. The receiver correctly rejected it. The fixture now
  advances its synthetic author's existing high-water epoch. Later gates did
  not run in this campaign.
- `focused-integrated-02`: 116 passed, 1 failed: a new unit fixture encoded a
  binary key with legacy parser version 1. Corrected to the current signed
  request format. `focused-integrated-03`: 117/0, exit 0.
- `retained-policy-01`: signed update succeeded, but explicit stop/start raced
  catalogue ownership (`already_configured`); two later failures were fixture
  fallout. Replaced with a monitored permanent-subtree restart.
- `retained-policy-02`: retained upgrade/restart passed; a later test detected
  the temporary catalogue row left behind. Cleanup now preserves an ordinary
  explicit hosting intention and restores the catalogue.
- `retained-policy-03`: 55/0, exit 0, including the restart monitor barrier.

The focused logs' crash reports are attributed to these existing negative
fixtures: five invalid prepared-genesis variants in
`malformed_present_prepared_genesis_fails_closed`, missing node identity in
`failed_admission_rolls_back`, root-unavailable startup during
`dynamic_hosting_survives_content_tree_restart`, deliberate wrong-anchor
replacement in `wrong_anchor_child_stops_then_exact_material_restarts`, and
the explicit killed-worker and injected-timeout cases in
`catalogue_worker_failures_are_terminal_owner_failures`. The last timeout is
an asserted owner-failure test, not a successful run hiding teardown failure.
The retained-policy test additionally kills its class subtree deliberately and
waits for both old supervisor and old engine termination before checking replay.

- `gates-02`: cleans, EUnit 3762/0, Ask 42/0, QUIC 37/0, single-node consensus
  12/0, four-node consensus, join, agent failover, read-set, feed and growth all
  exited 0. The campaign deliberately stopped after growth with driver exit 75
  and its `STOP_AFTER_CURRENT` marker preserved to address auth readiness.
  Remaining gates were not executed in that campaign.
- `auth-readiness-01`: default sandbox refused the HTTP fixture's loopback bind
  (`eperm`). Its interrupted setup left auth running and caused cascading
  `already_started` and fixture-state failures: 99 tests, 19 failures, 1 cancelled,
  exit 1. No failed result was treated as passing.
- `auth-readiness-02`: the same scope with approved loopback access passed
  106/0, exit 0. Coverage includes each auth incarnation's readiness notice and
  enrollment from an existing manager when auth returns, without a caller cast.

- `gates-03`: both cleans and full EUnit 3764/0 passed, exit 0. Driver deliberately
  stopped after EUnit with exit 75 and the stop marker retained to restore the
  full startup barrier and add the router readiness edge together.
- `owner-readiness-01`: auth/router/lifecycle tests 93/0, exit 0.

## Final campaign 04

Completed on 2026-10-07 (Europe/Paris). All 20 sequential gates and the campaign
driver exited 0. The 24 implementation, test and contract hashes still match
[tree-04.json](tree-04.json). Commands, child exits, durations and full-log
checksums are archived in [gates-04-results.json](gates-04-results.json); full
logs remain in `/tmp/quod-node-enrollment-20261006/gates-04`. Total gate time
was 1,366 seconds. Both clean gates preceded the tests.

- Full EUnit: 3,765 tests, zero failures.
- Common Test: 146 cases across all thirteen suites, all passed: signed queries
  42, QUIC 37, single-node consensus 12, four-node consensus 9, join 5, agent
  failover 5, read-set 3, feed 2, growth 9, namespaces 3, names 9, peer capacity
  6, and peer observation 4.
- xref and Dialyzer passed.
- Production release `quod-0.7.249` assembled successfully with the existing
  version label; no version bump or deployment was performed.
- Whitespace validation passed. Final scope hashes were checked again after
  the campaign; only these evidence records were added or updated afterward.

At the end of this pre-commit campaign, implementation and independently
checked Fable review were complete, while the commit and live rollout had not
yet occurred. The subsequent authorized policy update and completed fleet
rollouts are recorded in [deployment.md](deployment.md). The documented strict
uncertainty and initial-custodian restrictions remain.
