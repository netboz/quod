# Exact completion intent and certified expiry candidate

Yan renewed implementation and Claude verification on 2026-10-13. Read AGENTS.md,
current architecture/proof/multiwrite specs and integration-review-01/assessment.md.
This is a new candidate, not an approved production contract. Review source only;
no commands/tests or production edits. Save fable-review.md in this packet.

## Avoid the recursive custody-store operation

The accepted-answer transition already creates durable work. Have that same
transaction retain the complete canonical **unsigned completion request bytes**:
network, exact actor ontology/anchor/instance, committed signing key, operation
identifier derived from the unique original submission reference, fixed expiry,
parser version and the shared gui_complete(Q) goal. Construction is a pure
codec operation over authenticated and committed data. The expiry is fixed from
the submission's authenticated deadline plus authored completion allowance; it
is the later agent operation's deadline, never an extension of the human write.
The shared GUI rules hide this from form authors. No separate custody-store write.

The ordinary live reaction asks the existing hosted agent/signing owner to sign
these exact bytes, under current normal signing policy, and submits through the
existing ingress. The runtime must not regenerate id, deadline, goal or key.
A reaction rechecks that this exact committed request is still the pending work.
Recovery does not replay that live event. It uses existing agent-work selection
to observe this exact operation, never to dispatch a fresh attempt. A crash before
dispatch may therefore end with a definite expired request rather than a save.
A crash after dispatch observes the original claim/outcome. No silent automatic
retry is promised. Host/key changes do not change the retained request bytes.

Signatures grant execution authority; result observation under an authorized
ordinary proof need not require the caller to retain/recreate the old private
key or signature. A common exact-request outcome read could decode the retained
canonical bytes, bind their agent/id/digest/deadline and inspect the same index.
It grants no signing or invocation right. Signature-free *observation* must be
assessed against the containing ontology's ordinary ACL and existing outcome
visibility. This must replace any superseded common API, not add a GUI lookup.

The unresolved read of an unclaimed operation must not be called a refusal.
The second part below is necessary to retire a never-dispatched request safely.
Without it, this candidate preserves identity but lacks a completion/failure path.

## Narrow certified expiry theorem

An exact request with expiry E can be classified expired only from a contiguous,
fully applied, certified source prefix ending at H with certified block time
T > E, plus absence of the request's winning claim in that source index through H.
No wall clock, current key revocation, local pending miss or elapsed budget is
sufficient. Presence of any matching winning claim takes precedence, including
pending groups or outcomes awaiting Complete publication.

Code trace to challenge:
- ordinary content passes quod_transaction:validate_request at the certified
  block timestamp and installs its operation claim in the same ordered apply;
- independent dispatch first requires the same source claim;
- atomic commit requires a positive source Vote; that Vote installs the operation
  claim at its source slot and cannot first be admitted after the fixed deadline;
- later Resolve/Complete may occur after E, but their earlier source claim remains;
- timestamps cannot decrease along the certified source history;
- unsigned source-journal duty or remote prepared roles without a positive source
  Vote cannot later create a positive source Vote after T > E.

Thus an in-flight historical source positive either is in the certified prefix
(and its claim must be found), or conflicts with its finality. It cannot be a
valid future descendant. This is stronger than integration-review-01's rejected
expiry shortcut and does not retire an already-prepared source group.

An executable implementation must carry a canonical read dependency containing
the exact original request bytes and a certified applied boundary. Validators
independently decode the bytes, check their exact network/source identity and
expiry, and validate index absence plus certified prefix time. A bare caller
supplied expiry/digest pair is insufficient. Existing ordinary/atomic/read-only
validation must all check it. Snapshot/index readiness, replay, retained future
rows and publication floors must be handled explicitly. Repeated unchanged
reads must use retained owner state, not replay history or write indexes.
No timer or new consensus record merely to advance time: if source certified
time has not advanced far enough, the result remains unknown.

## Retirement and scope

Committed completion consumes the question as now. An authenticated human may
retire or replace a submitted interaction only after a certified terminal negative
for its retained exact request; the related HUD/question transition remains one
ordinary atomic transaction. No blanket actor cancellation, no fresh-ID retry
while unknown, and no second pending-work inventory. Automatic retry after a
terminal failure is deliberately not inferred from the ticket; ordinary explicit
user action can start a new interaction once the original is definitely terminal.

Please identify concrete counterexamples, especially a source admission lane
that could commit after this absence boundary, signature-free read authority,
live reaction duplication, request-size/policy ownership, and whether the
proposed failure recovery fulfills the agreed lifecycle without an extra queue.
Separate required fixes from optional improvements. This packet does not solve
remote live opening; do not weaken its settled absent-human/agent behavior.
