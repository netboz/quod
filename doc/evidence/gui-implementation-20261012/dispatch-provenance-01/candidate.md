# Original completion dispatch through existing reactions

Source-only consultation under Yan's requested Claude verification. Read frozen
AGENTS.md and the recovery-contract-02 candidate/independent assessment. Do not
run commands/tests or edit production. Write fable-review.md here.

The exact unsigned completion bytes will be retained by the accepted-answer
transaction; the pure shared codec is now implemented. Recovery only observes
that request, never dispatches it. This candidate closes the live-event side,
not certified expiry or remote presentation.

## Concrete provenance gap

The current diff_to_events/1 maps an actual assert of Fact and an explicit
trigger_event(assert(Fact)) to the same public event. Event-pattern unification
must stay that way. Thus matching assert(gui_question(...submitted...)) alone
cannot prove that this is the original state transition. Question ACLs reduce
exposure but are not a general provenance contract.

Replace that lossy conversion in the same reducer with occurrences containing
both the public event and its original applied operation. Carry the operation
as private reaction metadata through the existing local/remote dispatch. A
reaction-only committed_assertion(Fact) unifies only with an actual asserted
fact operation (assert/asserta with true body), never an explicit event, snapshot,
owner observation or an invented payload. Public react_on unification and ordering
remain unchanged. No new process, journal or event dispatch lane. Remote
publications already retain AppliedOps and pass only verified live deltas;
initial snapshots and rebuilds do not produce occurrences.

Shared GUI reaction matches the newly asserted submitted row, checks me against
the row's exact responsible actor, committed_assertion of that same row, and
requires the row and retained bytes still current in the committed snapshot.
The one shared behavior declaration is installed once, not generated per widget.
The ordinary gui_submit transition retracts awaiting and asserts submitted once;
duplicate submissions cannot repeat that assertion. An authorized ontology owner
can deliberately rewrite its state/policy, but a forged explicit event is not
permission to redispatch. Recovery work has no dispatch alternative.

## Exact bytes through the existing actor

A reaction metadata request selects retained bytes rather than regenerating the
consequence. It is not a second executor. Extend the current actor request mode
with exact retained intent. Decode/validate the bytes against its current binding
(namespace, anchor, instance, active key), execute mode and exact bound goal.
Reuse the normal governed node-signed read of sign_agent_request, then normal
ingress. The stored bytes fix operation id and signed expiry; timeout reports
that decoded original operation reference. The queue/worker's own earlier deadline
may stop work but never changes those bytes. Signing refusal/unsent expiry does
not authorize retry; observation recovery eventually classifies only certified
outcomes. Key rotation cannot rewrite or newly sign under a different key.

Do not generalize physics signed_store or introduce a separate custody write.
The live event is best effort; a crash before dispatch can strand the inert
intent until definite source expiry. A crash after dispatch keeps the same
unknown request. Agent-work passes and fresh incarnations are observation-only.

## Review questions

Challenge at-most-once dispatch under actual runtime batching, local duplicate
publications, foreign follow notifications, replay/resnapshot and host changes.
Does a concrete existing owner already provide this provenance without the
proposed extension? Can the existing runtime deliver the same original actual
assertion twice after it may already have dispatched? Identify such a counterexample
rather than appealing to duplicate_operation as permission to re-prove.
If it can, this candidate is insufficient and needs the existing owner corrected
before enabling automatic completion; no shadow dedup inventory is proposed.

This does not enable dispatch yet. The certified expiry/read-dependency contract
and remote acceptance contract remain separate correctness gates.
