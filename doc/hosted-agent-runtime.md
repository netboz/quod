# Hosted agents and ontology events

Committed events belong to the ontology substrate, hosted execution to the
agent substrate, and conversation state to FIPA or other domain ontologies.
Hosted execution and automatic recovery reuse ordinary ontology actions,
reactions, node execution and transaction coordination.

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
64 KiB of encoded terms per request, and 1 MiB across that ontology runtime's
hosted request queues. These are not physical-node-wide queue limits.
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
Capacity refusal preserves existing children and publishes an explicit refused
binding with the installed projection. The runtime retains no second desired
inventory. Actual slot release wakes the same projection handler to reconsider
committed assignments. The child cap defaults to 1,024 per ontology runtime;
the node executor does not consume a hosted-agent slot.
Set this cap with `node.runtime_max_hosted_agents` in HOCON (0–1,024).

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

The generic contract covers reconstruction of processes and resumption of new
work from committed state. It does not promise delivery of events missed during
downtime or recovery of unfinished conversations. Multi-node acceptance must
also establish surviving ontology availability and commit quorum; assigning
another host is insufficient when that ontology's only validator has failed.

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
The composition requires a ground observation: the producer reads the current
report sequence and binds the new sequence and its exact signed request expiry.
A mismatched sequence fails the whole transaction; it cannot silently rebase.
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

`agent_failure_support/6` requires a request expiry no later than the report's
signed expiry. Report creation derives expiry from authenticated request
metadata through `current_request_expiry/1`; it cannot be extended by a goal
argument. This metadata follows the already-authenticated local/foreign scope
path without a new wire format or live-query exemption. Existing admission and
already-admitted-operation semantics remain unchanged. The optional
`agent_recovery_policy.pl` combines observer projection, transport observations,
signed reports, explicit threshold policy and assignment convergence. Reports
alone do not grant takeover: the assignment action proves the same observer
threshold and exact prepared-key policy as convergence.

The recovery composition reports and reassigns in one signed
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

For automatic preparation, an eligible destination must also be an authorized
recovery observer. On a new negative physical observation, its Prolog reaction
chooses whether custody preparation is needed. The resulting signed
`report_agent_observation_with_custody/8` first installs the candidate key, then
records the report and converges. It does not converge between preparation and
reporting. An explicit `unavailable(Reason)` result records only the report,
which can support another candidate. This branch belongs to Prolog policy;
the worker supplies no hidden fallback or second submission.

`agent_recovery_candidate(Principal, Instance, OldNode, OldEpoch, Round,
Destination, Rank)` supplies domain policy: eligibility, distinct authorized
observer threshold, and deterministic ranking. The substrate intersects it with
prepared unused keys and retains the ordinary `can_assign_agent_host/6` grant.
An empty candidate set leaves the report current. A selected assignment that
fails causes the signed proof to fail, with no partial commit. Neither wrapper
is a second action evaluator; both compose the existing `goal/1` relation.

The optional policy also requires a destination's own current authorized report
to support this round and request expiry; an old prepared-key promise alone
does not make it selectable. Ranking orders the prepared eligible destinations
with that evidence. A recently reporting destination can still fail before
activation, so the policy does not guarantee future host health.
An already published candidate assumes preserved, usable vault custody. Its
fresh physical report is signed by the node and does not recheck that candidate's
vault key. If the vault becomes unavailable after publication, physical host
observation alone does not establish that loss or guarantee another takeover.

The completion plan explicitly defers its earlier preferred-first waiting
window and minimum move interval to domain/deployment policy under Yan's
delegated architecture judgment. Generic hosting uses exact-epoch report support,
deterministic ranking among currently reporting candidates and no automatic
failback. It adds no durable clock or local timer as placement authority.

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

## Explicit node execution

A founding reaction may select `node(NodeKey)` and call
`submit_node_goal(Mode, Goal, AbsoluteExpiry)`. This explicit execution role
uses the same bounded queue, child lifecycle and request worker as hosted
agent execution. The runtime captures the containing ontology's exact founding
identity and the installed node principal/key; a changed node binding retires
the old executor. An agent-selected reaction cannot substitute node authority.

The signed request enters the node ontology as
`node_authorized_goal(SourceNamespace, SourceAnchor, Goal)`. The ordinary
Prolog rule in `priv/ontologies/node_execution.pl` proves
`can_execute_for(SourceNamespace, SourceAnchor, Goal)` there, then executes
the foreign goal with an exact source-identity guard. Grant, guard and
consequence share one transaction. The source ontology's ordinary entry ACL
also applies. No grant is supplied by hosting or by loading this rule.

`submit_node_prepared_goal(Instance, OldEpoch, Result, GoalTemplate,
AbsoluteExpiry)` is a reaction-class bridge for destination custody. It requires
exactly one distinct unbound variable in the template, identical to `Result`.
The source ontology supplies the full anchored instance reference. The selected
node worker checks that source binding, prepares its vault slot under the same
absolute deadline, and uses Erlog term binding to replace `Result` with
`prepared(PublicKey)` or `unavailable(Reason)`. It signs and submits the resulting
ground goal once through the same queue and ingress as `submit_node_goal/3`.
Preparation neither runs inside a query/proof nor blocks the reaction runner.

Node requests from all runtimes enter the installed node ontology, whose existing
proof owner limits active proofs and post-proof waiters separately (default 64
each). This reuses shared admission; it does not bound aggregate pre-proof
vault/signing work or all runtime queues across the physical node.

## Local lifecycle observations

An unexpected monitored hosted-child exit queues the transient term
`observed(agent_process_down(AgentReference, Epoch, PublicKey, ObservationId))`
in the existing ordered reaction fold. The reference/key/epoch identify the
exited incarnation; the random portable observation ID contains no PID or
exception payload. Intentional retirement, replay and runtime teardown do not
report an unexpected exit. A normal hosting reconciliation still reconstructs
the local process from committed state.

`react_on/3` unifies the observation just as it matches other terms. The term
is not an applied diff and is not asserted. A durable response still requires
an explicitly authorized signed goal through the ordinary worker. Observations
are volatile; reset discards those from the previous incarnation. New inputs
arriving during reconciliation use the same bounded queue and wait for its
projection barrier. They are not a recovery log.
Remote host-loss observation is separate from local child failure.

## Stable custody preparation

`quod_agent_vault:prepare(AgentReferenceBlob, ExpectedOldEpoch, Deadline)` durably reserves
one random destination key for that exact reference and epoch. Repeating local
preparation, including after restart, returns the same key. Advancing the slot
retains earlier custody; an older epoch cannot replace the current slot.
`Deadline` is the caller's original monotonic deadline. Expired queued work
does not begin preparation; a write already in progress may finish persisting
custody, but no later signed request is issued after that deadline. The two-argument
local API supplies a five-second preparation budget for explicit callers.

The preparation slot and the public-key lookup name are hard links to one
encrypted record. Publication flushes both file and directory metadata, and
propagates storage failures. Explicit preparation repairs a slot whose public
alias was interrupted; ordinary signing does not perform hidden repair. The
encrypted record binds network, full agent reference, public key and epoch.
This local stability is a key-custody promise, not a signed-operation journal.
It cannot recover an exact unadmitted request lost with its sender. A later
independent physical observation may reuse the same key in its new report;
the previous operation's uncertain outcome never triggers another submission.

## Physical-host observation

The optional `agent_recovery_policy.pl` founding handler projects observer
watches from committed local host, key, round and observer facts. Changed-head
scopes select affected instances. Custom policy derived from other facts must
include those support heads in its founding handler. The runtime owns the
subscriptions; `quod_agent_observer` has no process, evaluator or work queue.
Two instances watching the same physical host share the transport's probe.

A new watcher must acquire an active, exact-author directory contact. The
contact comes from that actor's nonempty validated advertisement, regardless
of which public ontologies it lists; its own ontology may remain private.
An empty generation withdraws the contact as well as its public routes. Probes use
the existing key-pinned connection pool and open no application stream. A
completed connection timeout to that certified endpoint may support suspicion
without a preceding healthy connection. An arbitrary replica route, address
hint, missing startup connection or unavailable directory does not establish
failure. Suspicion remains an observation subject to Prolog policy and consensus.

A host may remain alive while an observer cannot reach its certified endpoint.
Reassignment therefore requires the configured threshold of distinct authorized
observers and an available commit quorum. A host's incorrect self-published
endpoint can still cause sufficient observers to suspect it even when other
consensus links work. Endpoint publication and observer placement are deployment
policy; a timeout alone never authorizes an assignment change.

Routing leases and established monitoring relationships have distinct lifetimes.
The transport retains an acquired immutable contact reference while the
directory owner and author's high-water
generation remain current. Route-lease expiry prevents new routing/monitor
acquisition; it does not by itself erase an existing monitoring relationship
or become failure evidence. A newer generation, explicit withdrawal or directory
owner replacement fences the retained contact. Runtime replacement can reuse
that transport-owned contact and request fresh evidence. Transport replacement
requires acquiring an active certified contact again; if its lease has expired,
missing routing remains unknown. Deployments must retain enough eligible
observers and contact authority to meet their report threshold.
Administrative reporting or reassignment requires explicit ordinary Prolog
grants; it provides an operator recovery path when that threshold cannot be met,
without making absent routing into failure evidence.

An empty authenticated connection set requires a one-second grace followed by a
completed pinned timeout before it can yield `suspected_unreachable`. Local
errors, rejected identities, stale contact references and exhausted caller
budgets remain unknown. While an acquired watched contact remains unresolved,
one transport-owned thirty-second timer obtains a new physical observation,
including after an inconclusive attempt. It does
not inspect any signed-operation outcome and never retries a write. Each completed
probe has a fresh portable episode ID and completion timestamp, shared across
interested instances. A genuinely new assignment/round dependency can request
fresh evidence sooner; simultaneous requests share the pending probe.

Each outstanding observer request retains its absolute deadline. Expiry clears
the request without reporting failure or issuing another attempt. A later owner
or projection edge can progress it. Positive confirmation uses the same pinned
request lifecycle; unrelated peers' revision changes cannot
produce another report for an unchanged connection set.

The transport also owns retirement of accepted wire connections. Its existing
application-owner monitor retains the exact wire reference and closes it
asynchronously on retirement, so transport keepalives cannot preserve an orphaned
application connection after its owner dies.

The transient `observed/1` wrapper is reserved to this owner-input tier. A
committed `trigger_event(observed(...))` payload cannot invoke its privileged
local handler. The normal reaction matcher still performs all unification and
executor selection after the source distinction is enforced.

One physical occurrence captures the affected instances' old epochs and rounds.
The runtime retains that bounded immutable batch in its existing ordered work,
admitting one instance through the normal matcher as node-executor capacity is
available. Committed state changes continue to run while this work waits.
Admission rechecks the contact owner/generation and observation expiry. Newer
physical evidence replaces unsent evidence and preserves the remaining instances'
turn. This reduces wake/queue fan-out; it does not combine distinct instances'
authorized durable transactions. For A affected instances and T reporting
observers, one observation round can require A × T signed reporting transactions,
with eligible reassignment included in those transactions. Each runtime's node
worker processes one request at a time. Sharing a physical probe therefore does
not promise constant-time recovery as the instance count grows; capacity and
time to the last recovered instance require measurement for each deployment.

Runtime observation admission defaults to
4,096 instances and 1 MiB of encoded watch rows, configurable through
`runtime_max_agent_observations` and `runtime_max_agent_observation_bytes`.
Both are positive integers in the HOCON `node` block.
Existing subscriptions take precedence over additions; a refused replacement
still withdraws its superseded host/epoch. Refusal and installed-status notices
share the successful hosting-projection publication boundary. A real capacity
release wakes the same Prolog handler, without retaining refused desired rows.

Transport contact admission defaults to 4,096 physical peers, configurable by
`peer_observation_limit`. Tracked route interest is installed before acquiring
the contact, protecting it before physical-observation subscription completes.
Capacity-blocked acquisition subscribes before requesting and wakes when the
transport observes released interest; unrelated observer work stays asleep.
Contact admission failure remains unknown health.
The positive `node.peer_observation_limit` and all three runtime capacity keys
are validated at application startup, before identity or worker startup. The
configuration-free application path validates the same application-env values
against the same schema. Runtime capacities remain per ontology; the transport
limit is shared across the node.

The reaction supplies a ground `report_agent_observation/7`, or its custody
continuation that the worker grounds before signing, with expected
round `none` or `current(Round)`. Establishing the first round, recording the
report and any eligible reassignment share one signed transaction. A competing
round never silently adopts the old observation; its projection needs new
physical evidence. The report's expiry is bounded by the physical completion
time plus sixty seconds and by a live authorized supporting subset when one is
available. Expired or unauthorized reports do not veto renewal. The ordinary
signed proof rechecks sequence, exact assignment, grants and report support.

These subscriptions and observations are volatile. A lost reaction is not
replayed. Later independent physical observations can produce different signed
reports; an uncertain request itself is never the trigger for another operation.
Before durable admission, sender failure can lose that exact report. Once an
ordinary source claim has committed, the existing coordinator owns its completion
obligation. Progress still requires the source node ontology's availability,
as well as the agent ontology's; surviving agent replicas alone do not preserve
a source quorum lost with the reporting node. Other observers can independently
contribute genuinely new reports under their own authority.
Neither local operation-index absence nor signed expiry proves an
uncertain operation was never admitted. There is no private replay journal or
renewed deadline. Complete multi-node failover acceptance remains required by
the generic-hosting completion plan; timing-based placement preferences are a
separate domain policy.

## Request timing

The existing optional OpenTelemetry exporter records one worker request span,
with child spans for custody preparation, governed signing and submission through
ordinary ingress. A monotonic enqueue timestamp measures local waiting for
projection release and earlier requests. It does not measure the reaction queue
before request admission. Tracing changes neither the signed request nor its
deadline, outcome resolution or retry behavior.

Attributes use closed executor, mode and outcome classes plus durations. Goals,
payloads, identities, keys, signatures and storage paths are excluded. Pending
and unknown outcomes are distinguished from committed work. Shared ingress spans
remain children of the corresponding worker stage; no separate trace owner is
introduced. Exporting uses the existing asynchronous SDK processor.

Workers killed before finishing and requests that never start do not supply
completed worker timings. Sampling or export loss also leaves missing coverage;
completed-span latency alone is not a failure-rate or delivery measure.
