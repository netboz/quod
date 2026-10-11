# Independent resolution of the renewal implementation review

Claude Fable reviewed packet
`129e01fb1433bf5da4de013d526791d3c586d6e5445194b66e551efb888feec9`
and returned GO with no correctness blocker. The child exited zero using
`claude-fable-5-1`, with tools disabled and the packet unchanged. This approves
the implementation by inspection; it does not establish release or desktop
acceptance.

The review confirms exact request scope, retained local and foreign dependencies,
fresh local snapshots, original expiry enforcement, atomic native registration
replacement, delivery credit, monotonic command sequence and preservation of
pending discrete operations. The native call's unknown outcome closes the socket
so its monitor releases any late registration.

Follow-ups made after that reviewed snapshot:

- Removed the unused server `view` field on inactive selections.
- Reported expired authorization accurately when it expires before attachment,
  rather than reporting a changed owner. Candidate failure remains fail-closed;
  no new retry or candidate-error protocol was added.
- Added a different real signed session to the ordinary view test. Its previous
  timer and dependency/native monitors must be retired.
- Added a real native watch-call timeout. The socket must send close 1011 and
  terminate. After the delayed call finishes, its existing socket monitor must
  release the late registration; a new caller must acquire the viewer normally.
  The test socket now terminates on the production close frame.
- Corrected two foreign-lifecycle fixtures discovered by the full release gate.
  They submitted empty request bytes while expecting the pending-cleanup reply.
  They now encode the exact valid anchored view goal. All late-reference and
  owner-death assertions remain, with an additional assertion that no opening
  worker is allocated before cleanup. There is no compatibility branch in the
  production endpoint to retain the malformed-request precedence.

The literal signed `expires` value remains alongside the derived timer in the
same socket. An absolute wall-clock deadline must be checked before and after a
blocking local call, independently of delivery of its timer message. This is
one owner holding the signed bound and its alarm, not two authorization owners.

Changed dependencies deliberately invalidate and obtain a fresh signed read.
The plan resolution's ordinary invalidation/read path includes this extra read;
it does not install a proof against an obsolete retained dependency set. No
durable transition is split or repaired after commit.

Fable's suggested frequency of stale drive refusals is not measured evidence.
The existing definite-refusal path remains visible and the existing navigation
sender can sample again; the desktop recording must establish its actual cost.
Likewise, compilation alone cannot establish the absence of external Erlang
callers: all source/test callers were searched, and xref is a separate gate.

The specific certified-advance-during-candidate interleaving remains an advisory
coverage gap. The existing progress handler is unchanged; tests cover actual
revocation during a pending proof, exact remote retention, cancellation and stale
completion. No new coverage of that specific interleaving is claimed.

The follow-up targeted run passed 189 tests across physics, control and foreign
lifecycle. Client source and tests retain their 134-test passing result. The
production change totals 140 inserted and 70 removed lines: the net 70 lines
retain the live view while one bounded candidate is proved and installed. They
add no second executor, registration API compatibility path or domain policy.

The follow-up Fable invocation exited one before invoking a model: the CLI
reported that usage credits were exhausted. Its packet, receipt and stop marker
are retained under `renewal-implementation-review-02`; it is not a review pass.
The main implementation GO remains valid for its frozen snapshot. The small
follow-up has independent review and targeted tests, without a Fable verdict.

The first clean gate
run remains stopped with 3883 tests and two fixture failures; its successor is a
new frozen campaign. Full clean gates and a coordinated real desktop renewal
recording remain distinct requirements. The latter uses the deployed candidate;
implementation approval is not main-network promotion or tracker completion.

## Opus fallback and final independent disposition

After Yan explicitly authorized latest Opus as the fallback, Claude Opus 5.5
reviewed the narrow follow-up and returned GO with no blockers. The isolated
Claude CLI 2.1.296 exited zero; the receipt confirms `claude-opus-5-5`, tools
disabled and unchanged packet
`db8f7663f797f4fd02f64365d7af7d1e629b417b9f8259adb40b16b43f9003d5`.
The failed Fable attempt remains retained and is not counted as a pass.

The reviewer confirmed that the corrected fixtures preserve their cleanup
assertions without an error-precedence compatibility branch, that removing the
inactive view field is safe, and that the unknown-attachment timeout test
observes actual processing and socket death. Independent checks of the comments:

- The different-session test directly asserts timer and monitor replacement;
  it does not directly count subscriptions. The packet's broader wording about
  that particular test was imprecise. Separate lifecycle tests cover subscription
  cleanup and retention.
- Keep the check immediately before a native attachment: pure decoding and
  registry lookup still consume wall-clock time after the earlier projection
  check. The post-call check bounds a call that crosses expiry. This preserves
  the existing absolute-deadline rule; the review's assertion that the earlier
  check makes the pre-call branch effectively unreachable is not a timing proof.
- Keep the literal signed wall-clock expiry. A timer read can detect elapsed
  monotonic time before its message is handled, so independence from message
  delivery alone is not the distinction. The literal bound retains the same
  time basis as the signed candidate authorization.
- Old authorization expiry can still produce refresh or unavailable depending
  on whether the timer or an explicit deadline check is handled first. Both
  release server custody; the browser's reconnect behavior differs. Do not
  claim those client outcomes are equivalent or change that behavior silently
  as part of this renewal fix. The desktop recording remains required.
- The timeout gate accepts both fresh and replacing watch calls. Its scenario
  uses renewal, but the test does not independently pin Previous as a reference.
  It proves unknown-attachment cleanup; the retained registration and input tests
  separately pin replacement behavior. Socket-level definite view_busy and
  unavailable replies during a renewal remain advisory coverage gaps. No new
  coverage of those specific interleavings is claimed.
- Changed dependency sets intentionally use durable_gap and the ordinary fresh
  read. Neither review's suggestion about stale-drive refusal frequency is
  measured evidence; the referenced lastDrive state is not in simulation.js.

The second full clean campaign passed 3884 EUnit tests and 146 Common Test cases,
then stopped at Dialyzer's unmatched timer-cancellation-list return warning.
The only production change after the Opus packet is an explicit `_ =` discard
of that list. Its exact one-line diff is retained with the review, and independent
comparison verifies identical cancellation calls and order. No warning was
suppressed. The separately frozen 262-03 campaign verifies the corrected tree.
Release packaging, deployment and the real desktop recording remain separate
from either reviewer's GO.

Campaign 262-03 subsequently passed all eleven clean sequential gates with true
child exit zero and unchanged inputs: native debug/release and Clippy, 134 client
tests, UI build/lint, 3884 EUnit tests, 146 Common Test cases, xref, Dialyzer and
production release packaging. Its frozen inputs, complete logs and browser output
hashes are retained under release-262-gates-03.
