# Runtime, events and agents

Committed ontology state is durable truth (**D**). The runtime installs
rebuildable local projections (**P**) before live events, reactions and
governed effects (**E**) act on them. Replay reconstructs D and P without
re-emitting old reactions. The direct-effect journal independently recovers
committed work whose private custody is still pending.

## Reactions and resources

`trigger_event/1` places an occurrence in a committed diff; it does not
assert that term as a permanent fact. Editable `react_on/2` clauses match
applied events with normal Prolog unification. Eligibility is read-only.
The selected goal enters the matching hosted actor's bounded queue and then
the ordinary signed-goal path. A match or queue admission is not a committed
acknowledgement. The reaction's consequence becomes durable only when its
own transaction commits.

`use_agent_request(Bytes)` in an ordinary hosted actor's reaction guard selects
an already retained canonical execute request. Its actor and ground goal must
match that reaction's selected actor and goal. The guard's metadata follows normal
backtracking; it neither signs nor submits while matching. The existing actor
queue, governed signer and ingress handle it. A changed key refuses the request;
the actor never regenerates its operation id, key, goal or signed expiry. Local
queue and guard deadlines may be shorter, but cannot extend the stored deadline.
A worker timeout reports the retained operation reference.

This selection is unavailable in proof, resource-recovery and private physics
observation contexts. It grants no retry permission: domain rules must select it
only from a live occurrence that permits dispatch, and recovery must observe the
retained operation rather than replay that occurrence. Restoring facts does not
rerun their assertion reactions. The signature-free outcome query in the
[multiwrite contract](multiwrite-architecture.md) provides certified terminal or
expiry dependencies for subsequent ordinary ontology transitions.

`quod_runtime` owns the installed reaction catalogue, subscriptions and
desired local resources for one ontology. Resource selectors read its
retained committed snapshot. Recovery reconciles current state without
replaying historical occurrences. Installed-state notifications are scoped
to the affected identity and owner incarnation; consumers subscribe before
reading a snapshot and retain the original caller deadline. Stale or
duplicate notices confer no authority.

For subscribed sources, the retained verified height also bounds live event
delivery. Duplicate or overlapping notices contribute only occurrences above
that height. A same-height readiness refresh may restore a usable source view,
but does not replay its old reactions, including after an occurrence was dropped
by backpressure.

Governed external predicates are classified as query, staging or reaction
operations. Their execution context distinguishes normal proofs, validator
policy checks and read-only reaction matching; an invalid context fails
closed. A live observation cannot silently become a replayable proof input.

Direct external effects have a public descriptor in the controlling ledger.
The node-wide `quod_effect_journal` holds the private preparation and releases
it after ordered apply. It is neither an agent outbox nor a second policy
store. Unchanged state checks do not require new journal writes.

## Identity and hosting

An agent is a classed instance in one exact ontology history. Its stable
reference is `agent_instance_ref(Namespace, GenesisAnchor, Instance)`;
active keys, grants, desired host and domain state are committed facts.
`quod_agent` is a disposable process owned by that ontology's runtime. It
holds bounded transient requests and uses governed signing. Key custody
belongs to `quod_agent_vault`, not to the actor process. Host recovery and
pending work converge from committed ontology facts and exact operation
references; neither needs a private Prolog KB or a message ledger.

`prepare_agent_key_custody(AgentRef, OldHost, OldEpoch, Destination, Key)`
prepares a public key through an ordinary signed read in the agent's exact
containing ontology. The destination must be the executing node's anchored
agent. The pure Prolog policy
`can_prepare_agent_key(Caller, Instance, OldHost, OldEpoch, Destination)`
authorizes preparation against that session's committed snapshot. Staged
permissions and external calls inside the policy cannot grant access.

First preparation uses `none, 0` and requires no existing host or key rows.
Recovery uses the exact positive prior assignment. Both reuse one encrypted
vault slot: repeating an unchanged request returns the same key without disk
writes or syncs, including after restart. Real changes retain directory
durability; an interrupted mutation must be synchronized before success.
Preparation neither assigns a host nor activates a key. Initial assignment
still uses the existing authorized action and can commit atomically with its
domain configuration. A lost assignment race may leave inert encrypted custody;
it grants no authority and is not automatically deleted during an uncertain
operation.

The bundled internal FIPA Request rules in `priv/ontologies/fipa_request.pl`
use two ordinary atomic transitions: the initiator's waiting state and
receiver's pending state commit together; later the receiver's domain goal
and both completion states commit together. Events may wake a hosted actor,
but historical replay does not replay the conversation. The opt-in pending
continuation uses the same runtime queue and existing work owner. AMS/DF,
external ACL transport and a complete FIPA platform remain future work.

Sources: `src/quod_runtime.erl`, `src/quod_agent.erl`,
`src/quod_agent_vault.erl`, `src/quod_effect_journal.erl`, and the FIPA
ontology above. The archived [actor design](outdated/ontology-actor-architecture.md),
[hosted runtime contract](outdated/hosted-agent-runtime.md), and
[FIPA plan](outdated/agent-fipa-plan.md) retain detailed decisions.
