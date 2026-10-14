# Shared question completion integration contract

Next implementation scope, not a claim of delivered behavior. Read AGENTS.md,
the current proof/multiwrite contracts, recovery-contract-02 assessment and the
expiry-read/current-request/retained-request evidence. No new GUI executor,
queue, authority source or unknown-write resubmission.

The human's existing gui_submit transaction validates current schema/policy and
replaces awaiting with one submitted question state containing exact canonical
unsigned completion bytes. Derive the operation id from the anchored question
reference and authenticated submission. Use the responsible actor's unique active
key, fixed authored completion allowance added to the submitting request's signed
expiry, and gui_complete(Q) as the only completion goal. Construct text using the
existing pure program-source formatter and bytes using agent_request_bytes/2.
Obtain root identity through its ordinary authorized scope, not a live native
query. There is no separate custody-store operation.

The shared question ontology matches the actual local assertion of that submitted
row. Its guard checks the same current row and matching hosted actor, then selects
use_agent_request(Bytes). This is the sole automatic dispatch occurrence. Reserved
assert wrappers cannot be forged by trigger_event; the existing event owner handles
source duplicates and recovery never replays old assertions. The ordinary queue
and governed signer retain the original bytes and expiry. Changed keys refuse;
worker timeout reports the exact retained operation. No generic gui_submitted
trigger event grants dispatch authority.

gui_complete and its consumption boundary require current_signed_request(Bytes).
The source obtains accepted fields and invokes its authored bound continuation as
before. Source domain writes, question consumption and HUD removal remain one
ordinary atomic transaction. A fresh request with the same actor/goal is refused.
Question/status projections hide execution bytes; portable visible submitted fields
retain the existing schema. No per-widget handler or signing code is authored by
applications.

The assigned human can cancel awaiting state as before. Submitted state can retire
only with committed_operation_outcome(Bytes, Status) proving rejected, aborted or
expired, captured in that same ordinary transaction. Unknown, a missing row or
wall time does not permit retirement. Positive completion normally already removed
the question/HUD in its atomic transition. Explicit client status reads can inspect
the original outcome without signing/redispatching it; failures remain locked.

Automatic recovery must stay observation-only. Before adding any work selector,
resolve its exact progress invalidation through existing owners: current resource
selectors run in pure policy-verdict contexts, and ordinary fact dependencies do
not describe an unclaimed request crossing certified expiry. Do not call the
outcome bridge from a forbidden policy context, poll readiness, rely on accidental
parent invalidation, or automatically issue repeated retirement writes with new
identities after unknown results. Existing projection_advanced includes request
keys and can carry certified-time changes; any extension must preserve snapshot/
subscription ordering and wake only affected work. This remains an integration
question, not authority to add a shadow work inventory.

Production evidence must replace the old manual-completion fixture carefully.
Each retained intent is dispatched at most once. A callback-induced proof failure
is not a certified negative outcome allowing an automatic replacement. Test source
and multi-scope rollback by distinct seeded questions and failures inside their
exact authored continuation, not by wrapping gui_complete in a different signed
goal (which must now fail the exact-request check). Preserve concurrent submit/
cancel, stale revision, foreign principal/source, forged events and duplicate
response coverage. Original live opening and headset acceptance remain separate.
