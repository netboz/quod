# Signed-read dependency implementation evidence

The reviewed plan extends existing proof scopes and the signed result/socket owners. It does not change OCC, ledger provenance, control authority or atomic-write protocols. Review receipts below identify each frozen scope; review is not acceptance of the complete ticket.

`view-dependency-core-01` failed 13 of 251 tests. Five savepoint fixtures accidentally expected four values from the unchanged public scope lookup rather than changing only the internal opener; four direct scope-open fixtures still expected the old two-value reply. Their premature exits left scope workers alive and caused four later capacity/cleanup failures. Updated those fixtures to the new opener contract and restored the public lookup assertions. Added a real engine advance before exact co-hosted scope reuse and a real signed-read test for success, logical failure, failed alternatives and refused writes.

`view-dependency-core-02` passed all 252 tests with a true child exit 0 and unchanged tracked inputs. It covers proof context, savepoints, DTX, result codec, router, atomic-origin, Prolog and co-hosted ask owners. This is not remote installed-collider evidence or signed personal-lobby acceptance.

The implementation retains exact scope opening heights, carries them in signed read results including failure, validates and renders the bounded canonical envelope, and has the existing simulation socket follow all returned dependencies before taking snapshots. Typed normal-view selections and remote collider installation remain separate outstanding stages of this ticket.

`view-dependency-socket-01` failed 5/158 tests: four read/control assertion updates were incomplete, and the lifecycle test had not consumed the newly required refresh after restoring a denied view's grant. The latter confirms the intended retained negative subscription. Corrected the assertions by operation type and explicitly consumed that grant refresh. `view-dependency-socket-02` passed all 158 tests, exit 0, inputs unchanged. This includes a committed rendering-policy change that withdraws the signed view, retains its negative subscription, and wakes it on restoration. It is a co-hosted policy dependency test, not remote collider installation evidence.

## Implementation review and corrections

[Implementation review 01](view-dependency-implementation-review-01/fable-review.md)
identified lost dependency envelopes on result errors and synchronous engine
snapshots in the socket. Corrections retain validated dependencies when bounding
an inner result and use one asynchronous snapshot per local owner after all
subscriptions have been registered. The production-engine test holds the stats
reply while the socket continues processing inspection and expiry. It releases
the owner explicitly; no sleep is used as delivery evidence.

[Implementation review 02](view-dependency-implementation-review-02/fable-review.md)
accepted those corrections in its frozen scope, including the single-snapshot
linearization point, and found no blocking defect. Its additional findings were
checked against the current owners. Subsequent changes reject a mismatched local
anchor, use the existing asynchronous foreign follow/unfollow requests, remove
the redundant runtime notice and unreachable stats-reply clause, and enforce the
existing directory namespace-length bound. Pending foreign registration survives
view cancellation just long enough to release the eventual server-issued follow
reference. A new open waits for that cleanup instead of accumulating registrations.
These subsequent changes have local validation but still await Claude review.

Pending unreachable foreign state waits for existing owner notices or the
original signed expiry. It is not treated as an authorization refusal. Typed
ordinary-view states remain outstanding. Review obligations not yet covered
include an absent local engine re-registering, lower/higher snapshot heights at
attachment, and foreign-owner replacement during registration.

## Later validation and retained failures

- `view-dependency-remote-01`: three real remote Common Test cases passed,
  covering signed read/execute/cursor, fresh nested symbols and transaction
  savepoints with exact opening-height dependencies.
- `view-dependency-review-fixes-01`: 2/280 failures. A signup-status fixture
  still expected a bare signed-read reply; its premature exit left a profile
  that affected the next shared-fixture assertion. Corrected the reply assertion.
  `view-dependency-lifecycle-02` passed all 57 affected lifecycle tests.
- `view-dependency-final-review-fixes-01`: 3/170 failures. Two exposed a
  namespace-length guard accidentally placed in the unrelated group-outcome
  validator; the guard was moved to dependency validation. The new cancellation
  fixture incorrectly assumed its next mailbox message was the follow response;
  it now processes messages through the actual socket handler until the response.
- `view-dependency-final-review-fixes-02`: compilation failed because that test
  correction reused an unsafe variable across a try boundary. Renamed the local
  variable. `view-dependency-final-review-fixes-03` passed all 39 result-codec and
  foreign-lifecycle tests.
- [Final socket run](view-dependency-final-socket-01-exit.json): all 170 physics,
  foreign-lifecycle and client-result tests passed, true child exit 0, tracked
  inputs unchanged. This includes cancellation while the real foreign owner is
  suspended and verifies that the late registration leaves no follow consumer.

Each campaign retains its complete log, child exit and source hashes. Failed
campaigns were not overwritten. These passing counts overlap and are not a
single full-suite result.

## Pending review and acceptance

`ordinary-view-plan-review-01` and `ordinary-view-plan-review-02` both exited 1
with Claude's session-limit response, resetting at midnight Europe/Paris. Neither
produced a review. Yan independently confirmed the account limit on the website.
The revised [ordinary-view plan](ordinary-view-plan.md) uses the existing generic
space classification and physics policy; it has no lobby-specific physics path.
Its plan review and review of the latest dependency corrections remain pending.

Yan subsequently requested an independent Codex review instead of waiting for
Claude. The [review and disposition](self-review-01/review.md) supersede that
immediate pause. It fixes HTTP uint64 dependency precision and local recovery
readiness, including exact engine/run notices and name registration before
replay completion. The failed reproductions remain; the 314-test correction
campaign and two final focused restart checks passed with true exit 0 and stable
tracked inputs. The revised ordinary-view plan remains an implementation plan.

No remote committed collider-to-install propagation, generic physical admission
transition, ordinary desktop control integration, or current signed personal-world
identity/history acceptance is established by this stage. QUD.27 remains open.
