# GUI implementation handoff

QUD.25 remains in progress. No deployment, commit, full release gate or headset
acceptance has occurred. Preserve unrelated/user-owned changes, especially
`doc/README.md`, native-client files, physics tools and other plans/evidence.

## Implemented and verified

- Ontology class name grouping, reusable component classes, inherited property
  contracts, composition, schema revisions, initial values and field bindings.
  `gui_instance.pl` is shared founding/source composition behavior, not a
  second ontology engine. Its continuation constructor does not execute a
  submitted client goal.
- The signed test fixture composes the behavior in a lobby and an independent
  nonphysical instrument application. It verifies ACL boundaries, malformed
  forms, stale revisions, disabled/read-only fields, shared variables,
  parameterized instances and 32-field forms. Repeated unchanged operations
  do not reread history, rebuild projections or write/sync storage; vocabulary
  calls are 1 for schema and 2 for binding/defaults.
- Existing proof/source workspaces now emit the same component tree. The
  single decoder replaces flat descriptors. Existing controllers remain
  responsible for proof cursors and source editing.
- Babylon workspace controls include composed rows/columns, text, buttons,
  selections, sliders, rotary knobs, direct numeric entry/stepping and local
  feedback. Background opacity is adjustable; text/control surfaces are opaque.
  A bounded action scroll keeps a large action set and keyboard reachable.

Evidence: foundation `foundation-validation/reviewed-receipt-01.json` has
114 passing tests on its frozen source. The later impacted backend gate has
17 passing tests, the client runner has 15 passing test files, and UI build
and actual MCP browser assertions pass. See the exact final renderer hashes,
commands, exits and logs in `foundation-validation/renderer-receipt-03.json`.
Receipt 01 missed an uncaught DOM pointer-event error. The final audit
reproduced it, fixed focus retirement before schema disposal, and added
global error/rejection capture to the fixture; the corrected run has no
browser errors. Focus also retires on input disabling and panel disposal.
The failed audit remains separately labelled and retained.
The browser test covers actual canvas picking and rotary release outside the
plane; it is not a headset test. A screenshot is retained at
`../../../.nimbalyst/transcript-images/gui-common-controls-final-1791842044483.png`.
Production delta for this slice is +850/-91 (net +759), including two new
production files, excluding user-owned changes and evidence.

The explicitly requested Fable reviews are saved in `component-review-01`
and `renderer-review-01`, with separate independent assessments. Advice was
checked against code, and rejected recommendations are explained. The Fable
child session is `bbee0021-8d80-4a82-b38c-0e903669f1f1`; it is idle after the
final renderer addendum. Do not initiate unrelated Claude reviews.

## Correctness gate before runtime implementation

The following are not implemented: `gui_open`, a generic authenticated GUI
receiver, question/HUD state, automatic submission reactions, question work
recovery, cancellation, duplicate/unknown question-operation handling, live
application demos or the general desktop DOM adapter.

Keep the settled requirement: opening fails in Prolog when the intended human
or actual installed authorized responsible agent is absent/refuses. No proof
waits for editing. Do not replace this with committed presence facts, a
post-commit refusal or a second signed opening operation.

The selected candidate uses one existing atomic transaction: material question
and HUD rows plus one legitimate prepared presentation effect in a diff-free
receiver scope. Native preparation accepts the actual client descriptor and
checks the selected runtime's installed handler; ordered release activates
that exact provisional view. Lost incarnations expire terminally; the shared
HUD reference owns later discovery. No separate actor activation, GUI outbox
or per-question native registration is permitted. See
`opening-effect-candidate.md` and plan section 5.

The remaining contract must name and verify these concrete extensions before
dependent runtime code is changed:

1. Bind the intended authenticated human to the exact connection incarnation.
   The HTTP key session is not a connected receiver, and ingress's local
   session owner is not carried as authenticated proof context to foreign
   scopes. The existing signed WebSocket implementation is
   `quod_client_simulation`, currently physics-specific. Generalize its
   lifecycle for nonphysical views; do not add a parallel GUI view service.
2. Native preparation must run on the selected receiver/actor host. Existing
   `::` chooses a validator, not a nominated node. The reviewed candidate
   `at(NodeKey, Namespace)::Goal` preserves one scope per anchored identity,
   checks exact authenticated signer/target binding and rejects conflicting
   pins, including self-scope shortcuts. It requires a scope-wire change;
   no such production change exists yet. A node's own ontology is not assumed
   to make that node a validator without checking installed membership.
3. Complete provisional acknowledgement, deadline, cancellation and immutable
   private payload contracts through the existing declared-action handles
   and effect journal. Its current closed operations are create/join only.
   Actor feasibility belongs inside presentation preparation, without
   inventing a no-op actor effect or a second actor queue.
4. Preserve the original opening's signed identity and exact custody before
   dispatch, for hosted agents as well as browsers. Current foreign scope
   metadata includes the request digest and expiry, not the full operation
   reference accessor proposed by the plan. No request counter or fresh-ID
   retry may stand in for that binding.

Do not mark the tracker done or imply the reviewed component slice has
established any of these unimplemented lifecycle guarantees.
