# Hosted agents and ontology events

This describes the agent implementation in the working tree. Deployment and
unfinished conversation recovery are not yet accepted. Yan's approved
separation puts committed events in the ontology substrate, hosted execution
in the agent substrate, and conversation state in FIPA or other domain
ontologies. The earlier universal inbox/outbox/retirement proposal is superseded.

## Publication and reactions

`trigger_event(Term)` adds an event operation to a committed diff. It does not
assert `Term` into the ontology's fact set. The committed history retains the
occurrence, subject to the history's retention rules.

A subscriber declares the exact source identity at founding:

```prolog
subscribes(SourceNamespace, SourceAnchor).
react_on(agent(receiver),
         from(SourceNamespace, SourceAnchor, request(Id)),
         submit_agent_goal(receiver, execute, record_reply(Id), 5000)).
```

`SourceNamespace` and `SourceAnchor` above stand for fixed values in the actual
declaration. `Id` is a variable: the existing reaction matcher unifies the
event with the pattern and passes that binding into the handler. Handlers run
through normal Prolog `call/1`, including its control and cut semantics.

The reaction frame cannot stage facts. `submit_agent_goal/4` queues a bounded
request for the selected hosted incarnation. That process obtains a governed
signature and enters the ordinary signed-goal ingress. The consequence becomes
durable only when its ordinary ontology transaction commits. A queue admission
or a reaction match is not a committed acknowledgement.

The timeout is converted to an absolute deadline when the runtime admits the
request. Work waiting in the queue does not receive a fresh deadline. The
runtime admits at most sixteen outstanding requests per hosted process, at most
64 KiB of encoded terms per request, and 1 MiB across its hosted request queues.
Queued and active requests share that accounting. Completion and child death
release it once, using the exact agent identity and owner incarnation.

The original monotonic deadline also bounds signing and execution. Expiry before
a worker starts is a definite refusal. Expiry of a running execute request kills
and joins that worker and reports an unknown outcome with its operation reference;
it does not assert that a submitted write failed or authorize resubmission.

## Ownership and custody

The containing ontology owns `agent_host(Instance, NodeRef, Epoch, PublicKey)`
and `agent_key(Instance, PublicKey, Status)`. The rules in
`priv/ontologies/agent_instance.pl` require one host row and one active key.
Initial assignment installs epoch one. Every subsequent assignment increments
the epoch, activates a previously unused key, and revokes the old key, including
assignment back to the same node. The containing ontology supplies assignment
policy, signing grants and an entry ACL; the shared rules grant none implicitly.

One founding state handler derives the local hosting projection. Ordinary
changes carry only the affected instance keys; startup and identity changes use
full reconciliation. Nonground changed heads also require a full projection. Its
`local_node_agent/1` observation selects this node's installed identity; that
observation is not committed authorization evidence. The runtime independently
filters locality and bounds the number of local children. It remembers the
projection's owning handler so child failure and identity changes can rerun the
same handler and its dependents without encoding domain fact names in Erlang.

`quod_runtime` owns the children. Replacing a binding stops the old child and
its request worker before installing the replacement. Teardown is asynchronous:
the runtime keeps processing its mailbox while the projection runner waits for
the exact old child to terminate. A later projection replaces pending successor
intent; it does not create an overlapping local incarnation. A successful ordered
batch releases queued requests only after its installed projection frontier.
Failed batches, replay and runtime replacement discard unreleased work.
Children monitor their runtime; each request worker belongs to its child.

Children contain no private Prolog state or private signing key. The node vault
holds encrypted custody. A signed read under the hosting node's agent identity
re-proves the current assignment, key and explicit signing grant in the agent's
containing ontology. The returned signature covers the unchanged canonical v1
request. There is no fallback that signs the agent's request as the node.

## Restart boundary and FIPA

Restart reconstructs hosted processes from committed assignment state. It does
not replay historical reactions or reconstruct their volatile request queues.
The implementation never automatically resubmits an uncertain signed write.

FIPA ontologies must define the durable state needed by their conversations:
the outstanding protocol obligation, evidence of completion, and the handling
of an uncertain operation. A stored obligation need not be a permanent copy of
every sent payload. Completed-state retention and cleanup belong to that
protocol. The generic event log alone does not establish those guarantees.

The current integration tests prove event exchange between two hosted agents,
preservation of completed domain state across runtime restart, fresh work after
restart, local withdrawal on a host move, and refusal of an old signature after
key rotation. They do not yet prove recovery of an unfinished conversation,
delivery of events missed during downtime, or a two-machine host transfer.

## Recovery reporting primitives

The transport owner exposes authenticated peer-connection snapshots and scoped
change notices through `quod_quic:peer_connections/2` and the gproc property
`{peer_connections, NodeKey}`. Subscribe before requesting a snapshot and monitor
the exact transport owner. Revisions are comparable only within that owner's
incarnation. Stream closure does not withdraw a live connection; losing one
connection does not imply losing all contact with its peer. An empty snapshot
is unknown connectivity, not a committed death certificate. Address-only outbound
connections are absent from the node-key index. An empty or shrinking set may
trigger a confirmation probe; it is not itself evidence of failure.

The shared Prolog rules support an explicitly authorized recovery round and
one current report per observer within that round:

```prolog
agent_recovery_round(Instance, OldHost, Epoch, RoundId).
agent_failure_report(Instance, OldHost, Epoch, RoundId, Observer,
                     observation(Sequence, ObservationId, SignedExpiry), Kind).
```

`can_report_agent_failure/4` is supplied by the containing ontology. Its
`begin` permission admits round creation; report-kind permissions separately
control process-down, suspected-unreachable, reachable and withdrawal reports.
The authenticated principal supplies Observer. Sequence starts at one and
advances by exactly one; late reports cannot overwrite newer observations.
Reports are ordinary action consequences reached through `goal/1`, subject to
normal entry authorization. The reporting transition emits
`agent_failure_observed/7` via `trigger_event/1`, without asserting the event.
Assignment changes remove obsolete rounds and reports in the same transaction.

`quod_node_actor:signed_goal/4` constructs an ordinary request for the installed
node principal using the existing identity signer. The caller retains the
operation id and expiry. Hosted-agent signature requests reuse this helper.
`quod_client_goal_ingress:resolve_operation/2` exposes the same outcome resolver
to local callers, including after signed expiry. Missing outcomes remain pending;
resolution grants no permission to resubmit a write.
Resolution is local and does not forward to a node holding the claim. It shares
the ordinary signing-key and peer admission budgets; rate-limit and availability
errors must remain distinguishable from a pending outcome.

These are primitives, not completed automatic failover. Observer projection,
grace/confirmation detection, governed report submission, observer/threshold policy,
recovery convergence, destination provisioning and automatic reassignment are
not wired together yet. `agent_failure_support/6` requires a request expiry no later than the report's
signed expiry. Report creation derives expiry from authenticated request
metadata through `current_request_expiry/1`; it cannot be extended by a goal
argument. This metadata follows the already-authenticated local/foreign scope
path without a new wire format or live-query exemption. Existing admission and
already-admitted-operation semantics remain unchanged. The report threshold
and takeover action are still policy work; reports alone do not grant takeover.

The approved recovery composition will report and reassign in one signed
transaction when its prerequisites exist. The reporting event then describes
that transaction; it must not submit a second takeover. A state handler can
project committed state and identify outstanding work, but cannot commit a
takeover itself. `current_request_expiry/1` requires verified signed-request
context and is unavailable to unsigned projection work. It is also forbidden
in a `policy_verdict` context. Recovery authorization and convergence belong
in ordinary action proofs. A later action supplying a missing prerequisite
must run the same convergence rule within its own transaction.

## Recovery actions and convergence

Host moves use `goal(agent_assignment(Instance, OldNode, OldEpoch, NewNode,
NewEpoch, PublicKey))`. The old host and epoch must already be ground. The
shared assignment action rotates the key and clears obsolete recovery and
candidate state; the planner cannot infer an old assignment for a stale move.
Initial hosting continues to use `goal(agent_hosted(Instance, Node, 1, Key))`.

Prepared public custody is represented by
`agent_candidate_key(Instance, OldNode, OldEpoch, Destination, PublicKey)`.
The destination's signed principal and the containing ontology's
`can_prepare_agent_key/4` grant authorize installation. Private custody remains
in the vault. `prepare_agent_and_converge/5` installs that state and calls the
same convergence rule used by `report_agent_and_converge/6`.

`agent_recovery_candidate(Principal, Instance, OldNode, OldEpoch, Round,
Destination, Rank)` supplies domain policy: eligibility, distinct authorized
observer threshold, and deterministic ranking. The substrate intersects it with
prepared unused keys and retains the ordinary `can_assign_agent_host/6` grant.
An empty candidate set leaves the report current. A selected assignment that
fails causes the signed proof to fail, with no partial commit. Neither wrapper
is a second action evaluator; both compose the existing `goal/1` relation.

`goal(agent_recovery_resolved(Instance, Node, Epoch, Round))` closes an exact
round under `can_resolve_agent_recovery/5`. That policy decides whether current
reachable/withdrawn reports suffice and how vanished observers are handled.
Round IDs must be fresh for distinct detection episodes. Reports are current
state, and their events are never asserted into the fact set.

Local vault custody requires `agent_vault.enabled = true`, a private directory
and a separate unlock file. The HTTPS provider is independently opt-in through
`agent_vault.provider_enabled = true`; only that provider requires the configured
TLS credentials and allowed peer keys.

The assignment grant receives `(Principal, Instance, OldNode, OldEpoch,
Destination, PublicKey)`; initialization uses `OldNode = none, OldEpoch = 0`.
Automatic observer/destination grants must enforce the report threshold and
bind the exact prepared key in this grant itself. Restricting only the
convergence helper is insufficient: ordinary assignment goals use the same
public action. Administrative manual-move authority remains explicit policy.
Convergence always uses the calling principal, including the destination when
key preparation triggers it. A reporting-only principal can record an
observation without gaining assignment authority.

A committed candidate-key fact is a durable custody promise. Its private key
must remain available while the candidate fact or an active assignment refers
to it. Resolving a false-alarm round preserves preparation for the same host
epoch; it clears reports, not that custody promise. Local collection of merely
unpublished staged keys cannot delete a committed candidate. Candidate facts
are cleared on assignment change, and private custody cleanup remains governed.

A founding recovery policy must also define resolution for false alarms and
vanished observers. Without a resolution grant the substrate cannot close the
round. Fresh authorized reports may still converge within that current round;
absence of a resolution rule does not itself invalidate their threshold proof.
