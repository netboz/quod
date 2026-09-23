# Generic agent hosting — completion plan

Reviewed completion plan. This replaces the earlier choice between generic
hosting and implementing a first FIPA conversation: this milestone is generic
hosting. Keep three work steps, with two implementation/review boundaries:
the hosting foundation, then automatic failover. Each implementation commit
has its separate version bump; both may ship in one deployment. The foundation
alone does not complete the automatic-failover milestone.

## Outcome

Two ontology-defined agents run on their assigned nodes, exchange committed
events through the existing reaction framework, execute authorized ordinary
goals, and automatically resume on another eligible node when their host shuts
down or fails. Their durable identities and state remain in their ontologies.
No operator reassignment is required for this failover. A local process restart
or a manually requested move alone does not satisfy the milestone.

The current foundation is uncommitted and undeployed. Recovery implementation
and verification receipts are in `_build/agent-recovery-20260923/`; these are
not full release acceptance. Production remains .227. Preserve all user/Claude
changes.
Automatic cross-node failover and full node-loss state restoration are not yet
implemented or demonstrated by those focused tests.

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

`eligible_agent_host/2` is the proposed Prolog policy relation for candidate
nodes. Rules may derive candidates and preferences from authorized node,
placement and capacity facts; no Erlang host allowlist determines placement.
The policy also authorizes surviving node/platform principals to request
failover, so recovery does not depend on the failed agent's unavailable key.

Finish governed destination-key provisioning and the assignment action: the
destination generates local custody, then one ordinary commit installs the
assignment and active key. Every host-epoch advance rotates to an unused key
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
worker submits an ordinary signed `report_agent_failure` action to the exact
containing ontology, under an explicitly authorized observer node principal.
The runtime must not inject an applied event, mutate the KB directly or wait
on network submission in its mailbox. Use the existing ingress and commit path.

Reporting terms (implemented primitives; detection and automatic takeover remain unfinished):

```prolog
% One current report per authorized observer and assignment, not an event log.
agent_recovery_round(Instance, OldNode, Epoch, RoundId).
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
replay. Reporting before its first commit still needs operation-outcome
handling; the durable fact cannot cover that earlier gap.

Takeover policy evaluates committed authenticated reports, eligibility, expected
assignment and candidate ranking in ordinary Prolog. Validators verify those
facts through existing transaction machinery; they need not query live health
while voting. This replaces the proposed extension of the membership-specific
live-observation exception and preserves actor architecture §6.

Report expiry is derived from the reporting request's authenticated signed
expiry. A takeover request must expire no later than every report it relies on;
ordinary admission enforces that bound. Already-admitted operations retain their
existing semantics. The remaining policy contract must specify trusted observers,
withdrawal, the threshold of distinct observers for remote suspicion, and recovery
when the selected executor also fails. Yan approved the single-transaction reporting
and reassignment refinement; implement and verify it as described in
`_build/agent-recovery-20260923/RECOVERY-TRANSACTION-DECISION.md`. A threshold of signed reports
is not the same guarantee as each consensus validator independently observing
failure. It proves who reported what; false reports remain possible according
to the observer trust model. Do not silently equate the two. Prefer an explicit
Prolog observer/threshold policy over a new validator guard.

Do not use negated peer_ready/1 as a failure report: it measures follower
readiness, includes missing local knowledge and lag, and healthy committee
members can remain silent. Reuse connection/lifecycle owners for observation;
define sustained suspicion separately from absence of observation. No new
consensus algorithm or actor-specific transaction is needed for this design.

## 2. Finish the shared runtime and reaction integration

`quod_runtime` remains the sole lifecycle owner. Its founding Prolog handler
derives which instances run locally. Children start, stop or change incarnation
when that committed projection changes, and reconstruct from it after restart.
Use existing scoped gproc notices, monitors and the ordered projection tier.
Consume changed-head scopes in Prolog to reconcile affected instances, including
explicit withdrawals; reserve full snapshots for boot/rebuild/identity changes.
Replace the current indefinite synchronous child stop with monitored asynchronous
teardown, preserving projection-before-effects and replacement fencing.

Connect existing process/node/link observations to the governed reporting action
and ontology-driven recovery above on surviving eligible nodes. Reuse the current owner and
asynchronous notification mechanisms; define graceful shutdown and abrupt-loss
handling explicitly. A surviving authorized node principal submits placement
requests through shared signed ingress; neither an absent agent nor a projection
handler can use the reaction-only submit_agent_goal path. Keep bounded proposal
workers under the existing lifecycle owner. Protocol failure detection is permitted; readiness polling
and a new independent election/consensus service are not introduced.

Rank candidates deterministically through Prolog policy over committed facts.
Give the preferred candidate the first proposal opportunity, with bounded
failure-driven fallback for other candidates. Define per-agent and per-node
proposal bounds, and a minimum interval between successful automatic moves.
The cooldown needs enforceable clock/epoch semantics; a caller's local timestamp
is not durable authority. Cancel obsolete candidates when an assignment changes.
Do not automatically move the agent back when its former host returns. No
uncertain proposal is resubmitted; a later attempt requires a definitive outcome
and fresh policy evaluation. Expose the existing exact-operation resolver to
local authenticated callers and specify how recovery retains or reconstructs
placement request identity after proposer death. A missing outcome remains
pending; the direct-effect journal is not an arbitrary-goal retry store.
Timing for failure detection/fallback is distinct
from readiness polling.

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

Close the remaining bounds, cancellation, deadline, unavailable-custody and
incarnation-race checks. Bound queued bytes and aggregate admitted work, not
only requests per agent. Preserve a monotonic caller deadline alongside signed
wall-clock expiry. Carry already validated canonical goal text through the
existing queue instead of formatting twice; retain authority proofs and ingress
verification. Allow local vault custody independently of its HTTPS provider.
Make governed key provisioning stable across retries/backtracking of the same
proposal. Keep one authoritative implementation. Remove
superseded candidate code and reconcile the documentation with this scope,
preserving user-owned edits and pinned prefixes.

## 3. Prove the complete lifecycle, then release

Use real signed entry and production policy, rather than broad fixture grants,
for multi-node acceptance with two eligible execution hosts and sufficient
surviving ontology replicas/validators:

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
- Commit a failure report, interrupt its reaction before dispatch, and restart
  the runtime: state convergence must recover the same obligation. Check duplicate,
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
inbox/outbox, polling loop or legacy outbox scanner in this plan. It introduces
no approval rounds beyond the two implementation review boundaries; after
completion of the stated reporting and takeover policy contract, proceed under existing authority
and release gates. Detailed source findings are recorded in
`_build/agent-vertical-v1/GENERIC-HOSTING-ARCHITECTURE-REVIEW.md`.

Detection and recovery policy detail: `_build/agent-vertical-v1/RECOVERY-DETECTION-REFINEMENT.md` (proposal; report freshness and exact operation binding still require concrete contracts).
