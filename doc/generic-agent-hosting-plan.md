# Generic agent hosting — completion plan

This milestone is generic hosting. Committed events and reactions connect
ontology-defined agents; FIPA ontologies supply their conversation policies.
Keep three work steps and the existing implementation/review boundaries:
hosting foundation, then automatic failover. The foundation alone does not
complete the automatic-failover milestone.

## Outcome

Two ontology-defined agents run on their assigned nodes, exchange committed
events through the existing reaction framework, execute authorized ordinary
goals, and automatically resume on another eligible node when their host shuts
down or fails. Their durable identities and state remain in their ontologies.
No operator reassignment is required for this failover. A local process restart
or a manually requested move alone does not satisfy the milestone.

Completion requires the multi-node acceptance below. Focused observation,
custody and activation controls do not establish that a replicated agent
survives the loss of its real execution host and validator.

## 1. Complete the Prolog hosting and authority contract

Use the ordinary ontology creation/ownership path to establish instances and
their ACL. Complete the production policy around the existing terms:

```prolog
agent_instance_ref(Namespace, GenesisAnchor, Instance).
agent_host(Instance, NodeRef, Epoch, PublicKey).
agent_key(Instance, PublicKey, active).
agent_key(Instance, OldPublicKey, revoked).
can_assign_agent_host(Principal, Instance, OldNode, OldEpoch, NodeRef, PublicKey).
can_request_agent_signature(NodeRef, Instance, TypedRequest).
eligible_agent_host(Instance, NodeRef).
```

The reference above is constructed from the containing ontology's identity;
its own genesis does not contain its own anchor. Class membership, creator
ownership, invocation rights and hosting authority remain separate.

`eligible_agent_host/2` is the Prolog policy relation for candidate
nodes. Rules may derive candidates and preferences from authorized node,
placement and capacity facts; no Erlang host allowlist determines placement.
The policy also authorizes surviving node/platform principals to request
failover, so recovery does not depend on the failed agent's unavailable key.

The destination generates stable local custody outside the proof. Its ordinary
signed report can publish the candidate key, establish the recovery round,
record the observation and install the assignment in one transaction when
the policy prerequisites hold. Every host-epoch advance rotates to an unused key
and revokes the previous one, including same-node reassignment. Private keys
stay in the destination vault. Retain the signed v1 request format.

Failover proposals name the expected old assignment/epoch. Concurrent proposals
compete through the existing transaction and consensus path; only the committed
winner may activate its new incarnation. A losing or uncertain proposal never
silently rebases itself into another host move. Failure suspicion triggers a
proposal, but does not itself confer ownership or durable proof of node death.

Resolve the exact use of `quod:node` / `quod:agent` policy and host-capacity
admission before activation. Ordinary authorized Prolog policy updates use the
existing system histories. A required change to locked founding declarations
or a pinned predicate manifest requires a reviewed succession; no silent
mutation of founding authority or re-founding. Record the chosen route before
making the corresponding production changes. Freeze shared external-predicate
contracts before founding production agent ontologies: changing a pinned module
in the second commit can otherwise require another succession. The two commits
need not have an intervening deployment or ontology founding.

### Ontology-driven recovery

Erlang reports lifecycle observations; Prolog decides the response. A bounded
worker submits an ordinary signed `report_agent_observation/7` composition to the exact
containing ontology, under an explicitly authorized observer node principal.
The runtime must not inject an applied event, mutate the KB directly or wait
on network submission in its mailbox. Use the existing ingress and commit path.

Current recovery terms:

```prolog
% One current report per authorized observer and assignment, not an event log.
agent_recovery_round(Instance, OldNode, Epoch, RoundId).
agent_candidate_key(Instance, OldNode, Epoch, Destination, PublicKey).
agent_recovery_observer(Instance, Observer).
agent_recovery_threshold(Instance, RequiredCount).
agent_host_rank(Instance, Destination, Rank).
agent_failure_report(Instance, OldNode, Epoch, RoundId, Observer,
                     observation(Sequence, ObservationId, SignedExpiry), Kind).
% Emitted by the reporting action using trigger_event/1; never asserted.
agent_failure_observed(Instance, OldNode, Epoch, RoundId, Observer,
                       observation(Sequence, ObservationId, SignedExpiry), Kind).
```

The report action authenticates Observer from current_principal/1, checks its
reporting grant and exact current assignment, bounds and deduplicates its report,
and atomically updates the report fact and emits the event. Observation identity
includes the relevant owner incarnation; raw Erlang PIDs are not portable durable
identities. Reports describe observations, not proof that a remote machine died.
A local monitored child exit, deliberate withdrawal and sustained remote-host
suspicion are different kinds. Intentional shutdown during reassignment must not
trigger another move. A vanished node cannot report its own loss: survivors do.

The ordinary signed reporting proof runs the shared convergence rule after
recording its observation. When the threshold and prepared destination exist,
reporting and reassignment commit in one transaction. The event describes that
committed transition; it does not own a separate takeover submission. Runtime
hosting continues to follow the committed assignment projection.

If a prerequisite is missing, the report remains current state. The ordinary
action supplying that prerequisite must invoke the same convergence rule in
its own transaction. A state_handler may project obligations on startup/rebuild,
but cannot perform a signed proof or commit assignment itself. Any work it
identifies must enter through the existing signed ingress under an explicit
surviving-principal grant. A missing outcome never permits resubmitting an
uncertain operation.

Keep only bounded current reports from authorized observers; clear obsolete
reports atomically on reassignment or explicit resolution. There is no
accumulating asserted event history, message outbox or historical reaction
replay. An observation or signed request lost before durable admission is not
reconstructed. A later independent physical observation can supply a fresh
report and the same stable candidate key. An unknown outcome never supplies
that trigger. After admission, the existing transaction coordination lifecycle
owns its durable obligations.

Takeover policy evaluates committed authenticated reports, eligibility, expected
assignment and candidate ranking in ordinary Prolog. Validators verify those
facts through existing transaction machinery; they need not query live health
while voting. This replaces the proposed extension of the membership-specific
live-observation exception and preserves actor architecture §6.

Report expiry is derived from the reporting request's authenticated signed
expiry. A takeover request must expire no later than every report it relies on;
ordinary admission enforces that bound. Already-admitted operations retain their
existing semantics. The optional recovery policy supplies explicit observer
membership, a distinct-observer threshold, ranked prepared candidates and
reachable-threshold resolution. An eligible destination must also be an
authorized observer to prepare and publish custody automatically through its
own report; eligibility alone grants no reporting or invocation rights.
A threshold of signed reports
is not the same guarantee as each consensus validator independently observing
failure. It proves who reported what; false reports remain possible according
to the observer trust model. Do not silently equate the two. Prefer an explicit
Prolog observer/threshold policy over a new validator guard.

Do not use negated peer_ready/1 as a failure report: it measures follower
readiness, includes missing local knowledge and lag, and healthy committee
members can remain silent. Reuse connection/lifecycle owners for observation;
define sustained suspicion separately from absence of observation. No new
consensus algorithm or actor-specific transaction is needed for this design.

Physical observation is shared per host; durable reporting and reassignment
remain per instance. A round covering A instances and T observers can therefore
require A × T signed reporting transactions through the existing node workers.
This milestone accepts that bound without claiming a recovery latency at large
instance counts. Measure queue residence, proof cost and time to the last
takeover before committing to a deployment's recovery-time objective.

## 2. Finish the shared runtime and reaction integration

`quod_runtime` remains the sole lifecycle owner. Its founding Prolog handler
derives which instances run locally. Children start, stop or change incarnation
when that committed projection changes, and reconstruct from it after restart.
Use existing scoped gproc notices, monitors and the ordered projection tier.
Consume changed-head scopes in Prolog to reconcile affected instances, including
explicit withdrawals; reserve full snapshots for boot/rebuild/identity changes.
Monitored asynchronous teardown preserves projection-before-effects and
replacement fencing while the runtime remains responsive.

The transport owns certified contacts and physical observation episodes shared
by all instances watching a host. Grace followed by an actual pinned connection
timeout may support suspicion, including without a preceding healthy connection.
Missing routes, identity rejection and local errors remain unknown. Runtime
restart can reuse the transport's retained contact; transport restart requires
an active certified contact again. Neither condition grants assignment authority.
The host must publish at least one discoverable ontology hosting row in its
certified advertisement; agents and private ontologies alone supply no contact.
A surviving authorized node principal submits reporting and placement
requests through shared signed ingress; neither an absent agent nor a projection
handler can use the reaction-only submit_agent_goal path. Keep bounded proposal
workers under the existing lifecycle owner. Protocol failure detection is permitted; readiness polling
and a new independent election/consensus service are not introduced.

**Placement timing decision.** Under Yan's delegated architecture judgment,
the earlier preferred-first waiting window and minimum move interval are
deferred to domain/deployment policy; they are not acceptance requirements for
generic hosting. Convergence deterministically ranks prepared eligible
destinations whose own current authorized report supports this recovery round
and the request's expiry. Every move must prove fresh report support for the
exact old assignment, and a returning host does not cause automatic failback.
This permits another reporting destination to make progress without waiting
for a preferred destination that has not supplied current evidence.

This policy does not guarantee that a recently reporting candidate remains live
until activation or impose a minimum wall-clock interval between moves. A hard
cooldown or preferred-first time window needs an enforceable clock/epoch
contract, not a local timer that grants assignment authority. Signed report
expiry may be shortened to overlap other reports, so subtracting the report
lifetime does not recover its observation time. No new durable clock is added
solely for those optional placement policies.

Assignment changes clear obsolete candidates. Returning hosts do not trigger
automatic failback. The existing exact-operation resolver is available to local
authenticated callers; missing outcomes remain pending. A new physical episode
can authorize a different report about the still-current assignment, without
replaying or renewing the earlier request. The direct-effect journal is not an
arbitrary-goal retry store. Failure-detection timers measure new physical
episodes; they do not poll readiness or operation outcomes.

Eligible destinations must already host the exact containing ontology identity;
pre-position its replicas through existing hosts_ontology/4 placement and the
node hosting projection. Reuse namespace_manager and its readiness notifications;
do not add an agent replica inventory or state-restoration path. Cold join
is not part of automatic takeover in this milestone. Before activation, the
replacement obtains the certified committed state through existing catch-up. It
reconstructs its disposable process from that state, preserving the same agent
reference. It waits on installed-state notifications if the ontology is not
ready. The deployment must retain ontology availability and commit quorum after
the execution host fails; merely naming another eligible node is insufficient.

Publication remains `trigger_event(Term)`. Subscription remains anchored
`subscribes/2`; `react_on/3` performs Prolog unification, executor selection and
normal handler control flow. The selected hosted incarnation submits ordinary
signed goals through the existing authorization/commit/outcome path. Release
work only after the relevant projection batch succeeds.

Keep the current bounded queues and original monotonic deadline alongside signed
wall-clock expiry. A physical-host occurrence carries captured instance bindings;
the existing ordered runtime work admits them as executor capacity becomes free,
without creating one queued reaction per instance at observation time. Each
instance still requires its own authorized ontology consequence. Runtime queue
and child caps are per ontology. The shared node-ontology proof owner supplies
the node's aggregate active-proof admission limit without a new scheduler or
inventory. Its limits do not bound all pre-proof work or queued bytes across
every runtime on a physical node; retain that distinction in capacity and load
claims.
Observation admission similarly preserves existing subscriptions and publishes
capacity refusals after successful projection. Runtime limits default to 4,096
instances and 1 MiB of watch rows; the transport's configurable contact limit
defaults to 4,096 physical peers. Actual capacity release wakes the existing
owner/handler rather than starting a polling loop or retaining refused desired
state.

The node worker prepares custody under the original deadline, binds the sole
result variable and submits one ground ordinary signed goal. Prolog explicitly
chooses whether unavailable custody permits a report without preparation.
Local vault custody is independent of its HTTPS provider. Preparation is stable
for the exact agent reference and old epoch, including after vault restart;
this stability is not durable custody of an unadmitted signed request.
An already published candidate relies on its promised vault custody remaining
usable. A fresh node-signed physical report does not recheck that key or provide
vault-health evidence; loss of custody after publication is outside the
physical-host recovery guarantee.
Keep one authoritative implementation. Remove
superseded candidate code and reconcile the documentation with this scope,
preserving user-owned edits and pinned prefixes.

## 3. Prove the complete lifecycle, then release

Use real signed entry and production policy, rather than broad fixture grants.
A four-node committee for each agent ontology retains a three-member commit
quorum after one execution host fails. Put three authorized observers on the
other nodes, use a two-report threshold, and make at least two survivors eligible
destinations. Candidates must already host the exact anchored ontology and
have their own node principal, vault and narrowly scoped execution grant.
Automatic preparation must be exercised without manually prepublishing keys.
Reporting enters through each observer's node ontology, which owns the source
claim. To prove claim recovery after losing that physical reporting node, its
node ontology must also retain replicas and commit quorum; restarting only a
runtime while that quorum remains available proves a narrower failure case.
State the observer fault assumption separately from the consensus fault model:
two reports out of three contain an honest report only with at most one faulty
observer.

- Create and host two agents in separate ontologies.
- Exchange a committed event; demonstrate variable binding and an authorized
  committed consequence, without accumulating sent-message facts.
- Restart an agent, its runtime and a host node; recover the correct incarnation
  from committed state and exchange a fresh event afterward.
- Commit recognizable agent state, then shut down its execution node. Without
  an operator action, observe a committed reassignment, automatic startup on an
  eligible survivor, the same agent identity and restored ontology state.
  Repeat with abrupt node loss, then exchange another event successfully.
- Move an agent to the other node with a new epoch/key; return the old host and
  prove it cannot admit new work using stale authority. Already-admitted
  operations retain the existing protocol's semantics.
- Race eligible replacements and exercise a partition/old-host return. Verify
  that only the winning assignment supplies current authority. Check that an
  ineligible node cannot take over and that absent quorum cannot grant ownership.
- Interrupt reporting before admission and restart the runtime: later physical
  evidence must permit progress without replaying the interrupted operation.
  Interrupt after a durable claim and verify ordinary coordinator recovery.
  A committed report with missing prerequisites must converge when a later
  authorized prerequisite action runs. Check duplicate,
  stale and forged reports, intentional child teardown, observer disagreement,
  and loss of the selected recovery executor. Unknown health must not count as
  confirmed suspicion.
- Exercise withdrawal, ambiguous assignment, unauthorized actions, absent
  custody, queue limits, expiry and failure before projection release.

Run the standing clean sequential gates in an isolated build, retain all logs,
obtain the required frozen Claude review, and report the actual code delta.
Then commit, make the separate version bump, publish and deploy using Yan's
existing authority, with preserved-data and post-deployment checks. The
previously recorded transport acceptance needed before enabling added agent
traffic remains a release check. Unrelated deferred performance work stays
deferred unless a concrete blocker appears.

## Boundary of this milestone

Restart recovery includes automatic cross-node failover, reconstruction of the
host process from the agent's committed ontology state, and resumption of new
work. Volatile process memory is not the source of agent state. An event's
occurrence is committed, but live delivery is not recovered: unreleased queued
reaction work is discarded on failover, and already-submitted work may have an
uncertain outcome. Historical reactions are not replayed and uncertain
writes are not automatically resubmitted. FIPA performatives, conversation
state and recovery of unfinished conversations remain later ontology work.

There is no new messaging protocol, private KB, second evaluator, generic
inbox/outbox, polling loop or legacy outbox scanner in this plan. Proceed under
existing authority and release gates; implementation and acceptance evidence
belongs in the corresponding handoff, not this contract.
