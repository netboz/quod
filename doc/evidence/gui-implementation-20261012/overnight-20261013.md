# Overnight GUI continuation, 2026-10-13

Separate continuation of resume-20261013.md; earlier stop markers and failed
evidence are preserved. QUD.25 is still in progress, uncommitted and undeployed.
No actual headset acceptance occurred. The scheduled 03:30 Paris continuation
ran; Fable became available and completed the requested savepoint review.

## Implemented

- Existing proof-context savepoint batches reuse one unmaterialized batch for
  the exact authorized actor and lineage. Local overlay snapshots remain
  independent; foreign materialization prevents reuse. No cap increase or
  transaction split. Real signed four-field validation and 1200-choice foreign
  rollback reproductions now pass, with cut/reentry/lineage cases retained.
- Shared Prolog question transitions: validated signed submission, assigned
  actor completion, awaiting-only cancellation, exact source binding and atomic
  domain/question/HUD cleanup. Events are occurrences, not permanent answer
  facts. Concurrent submit/submit and submit/cancel commit exactly one winner.
  Failed callbacks and failure after all three scopes changed restore all state.
- Authenticated HUD reference discovery and human-only question-state reads.
  Wrong human/responder/source anchor and forged helper chains fail through
  actual production seams. Unchanged repeated views perform no history/projection
  rebuild or file I/O. Accepted fields stay only in the question's current row.
- Common desktop controls consume the same workspace model as Babylon: text,
  semantic selections, buttons, sliders, rotary display with range/step/direct
  entry, composed forms, local opacity and opaque readable controls. Read-only
  text stays focusable. Pure numeric/text presentation checks are shared.

The question tests explicitly seed accepted rows. They do not claim real
opening, installed-agent acceptance or automatic recovery. The desktop adapter
has a live DOM fixture but is not wired to a live question workspace.

## Verification and review

The final nine-module backend gate passed 168 tests, zero failures, true exit0
in 254.132s. The remote signed savepoint case passed after correcting a fixture
parenthesis; the original failure and three separately passing remote action
cases remain recorded. Client gate 02 passes 15 test files; UI build 02 exits0.
Actual MCP desktop runs at 1000x900 and 390x844 each pass 16 checks with no browser
errors. Spatial shared assertions pass. No native-keyboard arrow or headset
result is claimed. Normal/narrow screenshots were visually inspected.

Exact hashes, commands, evidence and production growth (+379/-19, net+360
relative to the listed preceding reviewed sources) are recorded in
foundation-validation/overnight-receipt-01.json and its linked receipts.
Growth implements the shared lifecycle and desktop adapter; no second engine
or queue was added. Evidence/test/documentation lines are excluded from that
production count.

Fable reviewed the savepoint candidate and implementation, question transitions
and view follow-up, and desktop adapter and accessibility follow-up. Independent
assessments are in their separate packets. Fable ran no tests. Its question R1
about permanent submitted-work retirement remains unresolved: blanket deletion
would not establish that an uncertain earlier completion cannot still commit.

Failed evidence remains: before-fix savepoint regressions; remote fixture syntax;
question fixture binding-name error; initial desktop render synchronization and
headless animation-frame issues; and the spatial outside-release assumption.
For the latter, tracing showed the intended drag reached 20, then release at (5,5)
still hit the panel at the new aspect ratio and changed the value. The corrected
fixture asserts its release ray misses the mesh and preserves all value checks.

Build 01 generated output under priv/explorer. Only those generated paths were
archived in /tmp/quod-gui-build-output-01.tar.gz and restored to the tracked
baseline; build 02 writes to /tmp. Preserve all unrelated native/physics/user
files. No commit or deployment was requested or performed.

## Remaining integration

The hosted-agent work cursor is transient and intentionally allows a fresh
pass after dependency/incarnation changes. FIPA opts into new attempts despite
unknown outcomes; GUI does not. Its current Simplex snapshot covers prior atomic
custody, not every original signed request before dispatch. The existing
physics-specific custodied mode also has a distinct custody-store operation
whose uncertain outcome must not be hidden. Automatic GUI rules remain disabled.

Live opening still needs authenticated receiver/connection selection and real
client plus installed-agent acceptance through the existing prepared-effect
owners. A validator route is not a receiver-host route; a node instance can be
hosted elsewhere or only observed locally. No route-pin assumption was implemented.
No absent-human/agent failure was weakened into offline acceptance.

The remaining architecture trace and completed consultation are isolated in
integration-review-01. The independent assessment accepts the identified gaps
but rejects elapsed-time retry permission and the underspecified observer-query
presentation path. A certified negative-expiry verdict would need a complete
source-admission/index theorem, not an absent local lookup. The correctness gate
therefore remains open; no dependent runtime changes were made.
After those contracts: wire automatic authorized handling and the existing
view/controller owners, complete live lobby and independent-application demos,
then perform actual HTC Vive/browser input, legibility, reach and comfort checks.
Do not mark the tracker done until all acceptance is established.

At the pause, all test/build exits were collected and final receipt hashes
matched the live source. The owned Vite server was stopped; the browser tool
reported no remaining sessions. Fable is idle with no further requested work.
The integration assessment is the current correctness blocker, not provider
quota. The standing desktop stop notifier returned exit0.
