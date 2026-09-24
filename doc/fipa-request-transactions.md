# Internal Request conversations

This is the first implementation of the transaction composition selected for
FIPA within Quod. It is not a complete FIPA platform or wire protocol. The
source is `priv/ontologies/fipa_request.pl`, composed into an agent's founding
ontology alongside `agent_instance.pl`. It changes no signed-request format,
transaction coordinator, runtime queue or system ontology.

## State and authority

The containing ontology owns:

```prolog
fipa_conversation(Instance, Id, initiator, Peer, Action, waiting).
fipa_conversation(Instance, Id, participant, Peer, Action, pending).
```

Completion replaces `waiting` or `pending` with `done`. These facts describe the
current conversation, not copies of its messages. `Id` is a caller-supplied
32-byte conversation identifier; callers must generate globally unique values.
`Peer` is an exact `agent_instance_ref(Namespace, GenesisAnchor, Instance)`.
Both peers retain their own role; neither owns another copy of the other's
domain state.

The ontology supplies three things explicitly:

- Entry authorization through the existing `can_invoke/4`, granting only the
  intended public operations. Loading these predicates grants nothing.
- `fipa_request_allowed(Instance, Sender, Action)`, controlling which requests
  this instance may receive.
- `fipa_request_goal(Instance, Action, DesiredState)`, mapping supported domain
  actions to a ground desired state established by ordinary `goal/1`.

The receiver's entry ACL must match the guarded conjunction emitted by these
rules: `(current_ontology_identity(Namespace, Anchor),
fipa_receive_request(Instance, Id, Action))`, and the corresponding conjunction
for `fipa_receive_done/3`. A grant for the bare receive predicate does not grant
the enclosing conjunction. Restrict those entries to the intended peers.

For example, a reservation ontology may map `reserve(Object)` to its existing
reservation state and use its normal `action/3` declarations to establish it.
Incoming message content is never directly passed to `call/1` or treated as an
arbitrary executable goal.

The ordinary goal semantics apply: an already-established desired state counts
as success, and multiple domain mappings are tried in clause order, including
after an unsuccessful transaction rolls back. The participant's `done` row
retains completion evidence and rejects reuse of that conversation identifier
under a new signed operation; it is not an asserted copy of a sent message.

## Request and completion

`fipa_request(Instance, Id, Receiver, Action)` requires the authenticated
principal to be that local instance. In one public `transaction/1`, it records
the initiator's waiting state and uses `::` to call the receiver's
`fipa_receive_request/3`. The receiver checks its request policy, records pending
state and stages `fipa_request_received(Instance, Id, Sender, Action)` as an event.
The selector includes an exact genesis-identity check inside the target scope.

A founding reaction can use the existing unification and hosted submission:

```prolog
react_on(agent(receiver),
         fipa_request_received(receiver, Id, Sender, Action),
         submit_agent_goal(receiver, execute,
                           fipa_fulfil_request(receiver, Id), 5000)).
```

`fipa_fulfil_request/2` requires the participant's own authenticated principal.
It maps the pending action to its domain goal. One atomic transaction establishes
that goal, completes the participant state and calls the initiator's
`fipa_receive_done/3`. The initiator checks the authenticated peer and exact
pending action, records completion and emits
`fipa_request_completed(Instance, Id, Peer, Action)`.

The completion represents the Request protocol's inform-done case. The event
terms are internal notifications, not a complete ACL envelope or an SL0 encoding.
Full message validation/representation and additional Request outcomes remain
separate work. A rejected proof is not automatically a FIPA refusal or failure.

The two transactions correspond to two agents' decisions. There is no separate
outbox insertion, reply-delivery transaction or delivery acknowledgement. If the
initiator refuses the completion, the participant's staged domain action rolls
back with the transaction. The receiver's permission is not bypassed to force
completion. Duplicate conversation initiation is rejected; repeating an admitted
signed operation remains governed by the existing transaction identity/outcome
rules.

## Restart boundaries

Completed conversation state is restored through ordinary ontology recovery.
Events are committed occurrences but are not asserted facts and are not replayed
as new reactions. An in-progress durable transaction belongs to Quod's existing
transaction recovery. Different machines need not apply its decision at the
same wall-clock instant.

Autonomous continuation of a pending request that has not entered durable
transaction custody is not implemented by this file. The existing hosted queue
is volatile, and startup projection handlers cannot invoke reaction-only
submission predicates. Restoring `pending` alone does not prove that no request
was submitted. Integration must preserve the exact operation and uncertain
outcome rules before enabling automatic continuation. An explicit continuation
in the test is safe because a barrier proves the previous worker never submitted.

The focused integration tests use real hosted signing, two ontology ledgers,
ordinary ACLs, foreign proofs, actions, atomic commit and restart from the same
anchored history. They distinguish completed-state recovery from that unfinished
continuation requirement. They do not establish remote hardware acceptance.

## Remaining profile work

AP/AMS policy, complete ACL/content representation, refusal/agreement/failure,
cancellation, result-bearing responses, retention, pending-step continuation
and external interoperability are not supplied here. No automatic pruning is
introduced; retention must respect domain rules and existing operation replay
protection. Existing historical generic-outbox prerequisites in the broader
agent plan require alignment with this transaction-based design before release.
