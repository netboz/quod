# Opening through the existing atomic effect mechanism

Candidate under source review; not implemented or a claim of approval.

The useful existing example is `human_user_instance.pl:provision_lobby/1`:
application linking facts and root's prepared creation effect belong to one
ordinary atomic transaction. `quod_dtx:seal_admissible/4` requires the
effect-owning scope to have an empty diff. It does not prohibit material
changes in the other scopes of that same atomic group.

The GUI can potentially use this pattern to avoid the second signed material
request and its custody handoff altogether. The human and responsible agent
accept preparation; one original signed operation then commits the question,
its HUD reference, and the prepared presentation effect.

## Proposed executable sequence

1. The original signed **execute** request R calls `gui_open(Form, Question)`
   in the application's anchored scope. Existing browser operation-journal or
   hosted-agent request handling retains the original request/outcome evidence
   under its existing guarantees. No control-mode request or child material
   operation is introduced.
2. Shared Prolog behavior compiles the form, resolves the authenticated human,
   authorized responsible actor and exact receiver node scope, and proves the
   ordinary application, responder and human entry policies. These remain
   committed-snapshot/Prolog checks. A connection string cannot grant authority.
3. Question identity comes from the original authenticated request identity,
   with source/form context as needed. Exposing it requires a replayable
   request-context accessor, audited against validator contexts. Do not use a
   counter, a fresh child operation, or form-level uniqueness.
4. Inside the ordinary `transaction/1` boundary, call the governed presentation
   action in the selected receiver node's anchored ontology. Like
   `join_ontology`, this is an external action owned by that node's existing
   resource owners. Its declared `action/3` prerequisites and opaque
   proof-local handle precede native preparation. It must obtain actual
   authenticated receiver acceptance of the supported descriptor and actual
   acceptance by the selected installed/authorized agent incarnation.
5. Absence, unsupported controls, authoritative refusal or capacity refusal
   fails that preparation and the original proof. Unknown routing/owner
   reachability remains an infrastructure error. Preparation is bounded by the
   original absolute deadline; it never waits for the human to edit or answer.
6. Successful preparation stages one closed presentation effect, with immutable
   private preparation, in the receiver-node scope. That scope has no ordinary
   diff. The normal proof stages the authoritative awaiting question in the
   responsible agent ontology and its exact HUD reference in the human ontology.
   Those two rows, any related caller consequence, and the effect commit in
   **the same original atomic group**.
7. Existing scope effect binding, journal custody, source/role admission and
   Vote/Resolve/Complete own the outcome. The effect executor's private journal
   binds the preparation before dispatch. There is no GUI custody-store
   transaction, second operation R2, callback proof, receipt ledger or outbox.
8. Return success only for certified applied creation after the actual
   preparation acceptance. The shared question is now discoverable; editing
   starts later in the existing client controller with a local draft. A lost
   result after dispatch remains unknown under R's original operation identity.
9. Ordered apply releases the presentation effect through the existing journal
   worker. It updates/notifies the existing authenticated view owner by exact
   Question identity. Reconnection discovers the authoritative HUD reference;
   neither recovery nor duplicate notification creates another question.

## Failure and recovery boundaries

| Boundary | Required result and state |
| --- | --- |
| Human/agent absent or refuses before preparation succeeds | Prolog failure; no committed question or HUD reference. |
| Descriptor preparation times out or receiver owner is unreachable | Infrastructure/refusal result as appropriate to evidence; never an invented authoritative absence. No material operation has been submitted at this point. |
| Proof or action rolls back after preparation | Existing savepoint/abort cleanup retires unbound preparation. No shared question survives. |
| Original operation is dispatched and its reply is lost | Unknown with the original operation identity. Resolve that exact request; no fresh-operation retry. |
| Atomic group refuses | No question/HUD transition; existing effect retirement applies. |
| Receiver or actor disappears after actual acceptance | An eventual committed question remains pending under the agreed lifecycle. Opening never guaranteed continued connectivity during editing. Committed assignment/key changes still participate in ordinary OCC/authorization. |
| Effect worker/node restarts after commit | Existing journal recovers its bound immutable preparation. Notifications are idempotent by Question; shared question discovery owns the pending interaction. |

## Concrete extensions that still require specification

- The effect catalogue currently admits only ontology lifecycle create/join.
  Add a closed presentation operation; do not add arbitrary executable goals
  or turn the journal into an agent outbox. Extract lifecycle-specific payload
  encoding and execution from the existing journal into the closed handler
  dispatch while preserving its single custody/recovery implementation.
- `execute_row/1`, `desired_state/3` and `desired_target_state/1` currently
  assume a durable hosted ontology and matching genesis anchor. Those tests
  cannot stand in for GUI completion. Specify presentation's idempotent
  post-commit release, including disconnected receivers, without a second
  mutable completion catalogue or waiting indefinitely for reconnection.
- `run_declared_action/2` currently selects the ontology-lifecycle private
  transition. Extend the shared declared-action/handle mechanism consistently;
  do not write a second action evaluator or bypass candidate rollback.
- Receiver scope must be derived from authenticated connection context or
  authorized human/question state. Generalize the existing client view owner
  and its exact connection incarnation. A miss on an arbitrary node is not
  global human absence. Name the existing transport/scoping path for remote
  receiver preparation rather than introducing a GUI broker.
- Agent acceptance must prove the installed actor, applicable handler,
  governing key and relevant policy at preparation. Use the existing runtime,
  governed actor and request queue; define death/deadline handling. Queue
  capacities remain Prolog policy, not newly relabelled encoding constraints.
- The actual preparation and release messages, public descriptor fields,
  private prepared payload, expiry/cleanup obligations and validator checks
  need concrete contracts and production-seam tests. No current API already
  provides this whole operation.

This proposal leaves the live-observation/material-diff veto unchanged.
It is valid only if actual acceptance is legitimate preparation of an external
presentation effect under the existing effect contract, not a live truth
assertion hidden behind the staging classification. Fable and the parent are
checking that distinction against the preparation, validation, atomic binding
and recovery code before any corresponding production changes.
