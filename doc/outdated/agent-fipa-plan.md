# Quod agents and FIPA -- architecture and implementation plan

**Status:** the internal Request conversation and guarded pending continuation
are implemented through existing transactions. The working tree now uses editable
ordinary `react_on/2` goals and direct committed resource selection in place of
founding-only reactions and state handlers. Frozen integration validation is
recorded in `WORK-IN-PROGRESS.md`; stored-policy activation remains open. Reaction ownership and privileged calling contexts follow
`event-reaction-refinement-plan.md`. AMS/DF services and
external FIPA interoperability remain later work.
`ontology-actor-architecture.md` is the
authority for actor identity, system-ontology bootstrap, key ownership, and
hosting. It corrects this document's former Agent Platform record model: every
durable agent is a classed instance in ontology state and its optional Erlang
process is a rebuildable projection.
The current tree uses the generic stable agent reference; the former
`{user, Key}` label is not a supported identity or compatibility path.

This plan defines how users, agents, actions, runtime state, events, directories,
and FIPA communication should fit Quod's ontology-first architecture.

It deliberately does not preserve BBSvx or Onia implementation compatibility.
Their code is reference material: useful semantics are retained, but machinery
that conflicts with Quod's simpler architecture is replaced.

The normative inter-ontology rules remain in `doc/inter-ontology.md`.
Client projection, GUI, physics, and editable voxel worlds are recorded
separately in `doc/client-world-direction.md`. That document is a performance
forcing function for this substrate, not part of this plan's implementation
scope.

### Current internal FIPA contract

Within Quod, FIPA defines Prolog actions, authorization and conversation rules
over the existing multi-ontology transactions, recovery and reactions. Related
state changes and receiver consequences commit in the same transaction. A
request may atomically record A waiting and B pending; B's later decision may
atomically establish its domain goal and record completion at both agents.
There is no intermediate message queue, delivery acknowledgement or additional
reliable-messaging subsystem. Committed events participate in the normal diff
and Prolog pattern unification without becoming asserted message history.

Internal communication has no outbox/scheduler prerequisite. External FIPA
transport is deferred. Completed state and admitted transactions recover
through the existing ontology/transaction owners; automatically continuing a
pending decision must also respect uncertain-operation identity and custody.
Restoring state does not replay historical reactions.

## 1. Objective

In Quod, the Prolog knowledge base is the durable description of reality.
Successful mutating proofs stage a concrete diff, and consensus decides whether
that diff becomes truth.

Runtime processes and external systems are not additional sources of durable
truth. They either:

1. provide an observation to a proof;
2. project committed facts into local runtime state; or
3. receive an irreversible effect after a live commit.

The implementation must make those three roles explicit and enforce when each
role may run.

The system ontology vocabulary includes `quod:node`, `quod:agent`, and
`quod:human_user`, discovered from root's committed system catalogue.
`quod:agent` defines the generic actor vocabulary; `quod:human_user` defines
the human-specific subclass. A concrete agent is a local instance in an
ontology, identified externally by that ontology's exact identity plus the
local instance name. Its optional hosted Erlang process is a rebuildable
projection of committed facts.

## 2. Non-negotiable invariants

1. **No KB copies.** Proof and runtime workers receive shared MVCC snapshot
   handles, never copied ontology contents.
2. **No speculative side effects.** A predicate called by a normal proof may
   observe reality or stage writes, but may not perform irreversible external IO.
3. **Commit before reality.** Runtime projections and effects run only after the
   corresponding diff is committed and visible in the local KB.
4. **Replay does not emit effects.** Historical replay rebuilds facts only.
5. **Runtime state is reconstructible.** Every process, timer, route index, and
   mailbox registration derived from facts has a reconciliation path. A
   physical node's durable hosting and exact private-contact knowledge are the
   `hosts_ontology/4` and `knows_ontology_host/4` facts in its dedicated node
   actor ontology; its local manager and directory remain disposable
   projections of those facts.
6. **Ontology ownership is respected.** A foreign mutation is an action request
   executed by the target ontology, never a foreign ready-made diff.
7. **No global FIPA message ledger.** Communication is routed to the involved
   agents. Only state that an agent chooses to remember is committed.
8. **Ontology identity is universal.** Nodes, agents, users, services, and
   other actors are represented by classed instances in ontology state. Public
   keys, class facts, and policies are durable facts in the containing
   ontology; endpoints and private keys are not.
9. **The authenticated principal is end-to-end.** A foreign ontology call
   retains the actor. Only the engine constructs the ontology call path;
   content cannot substitute authority. `subject/3` remains future work.
10. **Bounded work.** Proofs, reactions, projections, conversations, queues, and
    transport frames all have explicit resource bounds.
11. **One logical effect executor.** Every E effect names one durable logical
    executor. Only the node currently hosting that executor may schedule it.
    Receiver deduplication handles crash retries and the bounded overlap during
    a host-epoch transfer; it is not the normal defense against every replica
    emitting the same effect.
12. **One authorization model.** Reactions are ordinary editable Prolog code.
    Existing `can_invoke/4`, signed identity and transaction checks govern their
    modification and execution. There is no founding lock or extra runtime-code
    permission layer.

## 3. Lessons retained and rejected

### Retained

- BBSvx's prove-before-broadcast principle.
- The later Onia model: an Agent Platform is an ontology-level authority and a
  hosted agent is a supervised runtime instance.
- Onia's three-part subject authorization context as a possible later design
  for `subject(Agent, AgentChain, Capabilities)`, not the implemented ACL input.
- Onia's distinction between deterministic state, runtime projection, and
  external effect.
- Prolog definitions for communicative acts, protocols, lifecycle rules, and
  directory policies.
- Erlang external predicates as narrow adapters where Prolog cannot directly
  observe or affect the runtime.
- BBSvx/Onia's target-driven action idea, refined in Quod as
  `action(Transition, Prerequisites, DesiredState)`: `goal(DesiredState)` tries
  declared transitions transactionally.

### Rejected

- A separate Agent Platform record as the durable identity of an agent.
- Copying subscribed foreign facts into another KB.
- Replaying effects from transaction history.
- A generic effect dispatcher that can invoke any compiled predicate by functor.
- Fire-and-forget event workers without ownership or a durable delivery policy.
- Storing every FIPA envelope in one consensus-ordered global ontology.
- Consensus facts containing volatile socket addresses as if they were stable
  identities.

## 4. The execution model

Every operation belongs to one category.

### 4.1 D -- durable ontology state

D consists of:

- committed Prolog facts and rules;
- a proof's private assert/retract overlay;
- transaction goal, result, diff, read-check, author, and signature;
- durable agent lifecycle, ownership, conversation and pending-work facts.

D is changed only by a committed transaction.

### 4.2 P -- runtime projection

P consists of rebuildable local state:

- hosted-agent OTP processes;
- AID and namespace routing indexes;
- gproc registrations;
- timers derived from durable timer facts;
- active conversation and delivery indexes;
- DF/AMS search indexes;
- live endpoint and reachability caches.

P is updated incrementally after a live D apply and rebuilt in bulk after replay.
Projection handlers must be idempotent.

### 4.3 E -- external effect

E consists of irreversible or externally observable operations:

- sending an ACL message;
- writing to a socket;
- posting to an agent mailbox;
- calling an HTTP or device bridge;
- notifying a client;
- firing an expired timer.

E follows the controlling commit and its actual resource prerequisites.
Processing canonical runtime input is not proof that every reaction or resource
has completed. Historical replay does not execute old E occurrences.

## 5. External predicate contract

Prolog owns policy, actions and domain state. Erlang predicates expose existing
runtime services through the ontology's declared modules. The common registry
retains these execution classes:

| Class | Purpose |
| --- | --- |
| `query` | Observe permitted state or engine-owned request metadata. |
| `staging` | Stage ordinary durable changes in a proof. |
| `reaction` | Match-local runtime metadata, unavailable to an ordinary proof. |

The `reaction` execution context is only the read-only eligibility phase. It
cannot stage a transaction, submit a goal or prepare a key. The bound reaction
goal then executes in the ordinary `proof` context under its real owner.
Membership `verdict` and `policy_verdict` retain their existing restricted
contexts. The retired `projection` context and predicate class have no successor
permission layer.

One engine-owned context carries namespace, height and anchored call chain.
Authenticated principal and request custody remain in their existing private
proof/session ownership, not caller-supplied flags. Metadata classification
still distinguishes proof-bound inputs from live observations. Native resource
commands accept a scope and ask the existing owner to select committed desired
state; they accept neither speculative rows nor arbitrary callbacks.

A normal query binds results through Erlog unification. If the complete proof
stages no write or effect, it creates no ledger entry. Irreversible effects
still require existing prepared effect custody where applicable; ordinary
reactions are not permission to send external I/O speculatively. The typed vault
signing bridge still proves ordinary Prolog authorization before releasing a
signature and never signs arbitrary caller bytes.

Declared module names select implementations from the coordinated installed
release. Founding digests are provenance, not lifetime BEAM locks. The cold
activation contract in `ontology-actor-architecture.md` applies; there is no
unrestricted module loader or automatic mixed-release negotiation.

## 6. Actions

The framework action interface is:

```prolog
action(Transition, Prerequisites, DesiredState).
goal(DesiredState).
```

`DesiredState` is the observable state the caller wants; it is not an effect
that the framework asserts. `Transition` is either one callable goal or a
non-empty proper list of callable goals executed left to right.
`Prerequisites` is a proper list. Several declarations may reach the same
desired state.

`goal/1` first checks the desired state read-only. If it already holds, the goal
succeeds without running a transition. Otherwise it validates each complete
candidate before invoking it, then tries matching `action/3` clauses in Prolog
declaration order. Normal prerequisites are read-only state checks; explicit
`goal(State)` and `Ns::goal(State)` prerequisites may establish another state
recursively. The prerequisites, transition, and final exact desired-state check
run inside the evaluator's internal proof savepoint, not public `transaction/1`.
It inherits ordinary/atomic/independent intent; `independent(goal(State))` uses
this same evaluator and rollback machinery.

The candidate savepoint is semidet: it keeps the first complete inner solution and
does not expose inner alternatives to its caller. A failed candidate restores
every assertion, retraction, and abolish it staged before the next matching
action is tried. Total failure restores the candidate's entry state; an
Erlog error restores it before the same error propagates. A selected candidate
succeeds only after its desired state has been proved again.

The common clauses are loaded by `quod_committed_projection:new_est/0` into every ontology's
code baseline; they are not copied into genesis transactions. There is no
reverse-effect lookup, generic fact action, direct-call fallback, or
`assert_effect/1` compatibility path. Domain changes use explicit named
transitions.

Example:

```prolog
record_agent_display_name(Agent, Name) :-
    assertz(agent_display_name(Agent, Name)).

action(record_agent_display_name(Agent, Name),
       [may_manage_agent(Agent), valid_agent_display_name(Name)],
       agent_display_name(Agent, Name)).
```

The authenticated principal is read by authorization prerequisites from
the engine-owned execution context; it is not a positional field of
`action/3`.

Most actions change durable reality and their runtime consequences are derived
from the committed diff by P and E handlers. Explicit node-local lifecycle
actions use the same desired-state declaration shape, for example
`ontology_hosted(Name)` and `ontology_joined(Name, GenesisHash)`, and run only
through the same ordinary action relation. Signed and node-authored `execute`
are the entries. The target's `can_invoke/4` and declared action prerequisites
run before the governed bridge reads or prepares input. The bridge stages a
closed effect; the ordinary transaction commits it, and the node-wide journal
performs it only after ordered apply. An already-true target returns success
without lifecycle IO. An unobservable completion is `outcome_unknown`.
Lifecycle IO is journal behavior, not the third argument of `action/3`, and no
volatile hosting fact is asserted into consensus.

## 7. Apply, replay, reconciliation, and events

Simplex finality and Prolog application remain separate boundaries. Reactions
consume the immutable canonical application result, never the earlier
`committed` announcement. `applied_ops` contains the ordered changes actually
applied; no-op assertions/retractions manufacture no notifications.
`trigger_event/1` adds an occurrence to that same diff without asserting a
message fact. Durable prepends preserve clause order while both prepend and
append facts publish `assert(Fact)`.

Live transaction T matches the declaration catalog installed before T. Its
catalog changes govern T+1, including in the same block. Application exports
those boundaries; ordinary requests do not scan history or reconstruct old
catalogs. The queued reaction goal uses its normal current proof snapshot and
conflict checks, not a promised historical view of the event-time ontology.

The existing repeatable recovery transition remains:

```text
live -> replaying(RecoveryId) -> current-state reconciliation -> live
```

Recovery restores committed state without rerunning historical occurrences.
The owning process publishes a scoped readiness observation when its current
view is installed. Existing typed owners select committed resources from current
assignments and pending domain work, retaining actual policy dependencies.
Runtime owner loss, reader cancellation,
replay boundaries and collapsed best-effort input use this same lifecycle.
Stale recovery IDs and owner incarnations cannot reopen an old view.

Remote subscriptions use the existing certified foreign materializer and
`from(Namespace, Anchor, Event)` wrapper. Each subscriber's initial baseline is
state-only. Later certified live changes use the same reaction matcher.
Subscription/snapshot ordering, cancellation and caller deadlines remain with
the existing owners; no publisher-side callback registry is added.

`event-reaction-refinement-plan.md` specifies the authoritative live ordering,
trusted notice vocabulary, frontier meaning, overflow recovery and verification
obligations. It replaces the former namespace-wide P-before-E promise: actual
resource readiness belongs to the resource owner, while canonical input may
continue independently.

## 8. Runtime resources

There is one behavior declaration, `react_on(Pattern, Goal) :- Eligibility`.
No `state_handler/4`, handler dependency graph or generic heavy-work scheduler
is retained. The existing owner selects each concrete resource directly on
dependency/lifecycle changes. The fixed selector runs under restricted committed
policy before installation; a failed transaction's staged facts are never
projected. No physical-node reaction or arbitrary goal is needed for restoration.

The retained duties are hosted-agent start/stop, remote-host observation,
ontology hosting and contacts, effect-custody capacity, and guarded pending
agent work. Their actual owners remain `quod_runtime`, the host observer,
node actor/namespace manager/directory, effect journal and existing hosted-agent
queue. An Erlang module need not introduce another process.

A readiness observation wakes only affected work. Existing queue capacity and
custody installation drive progress without polling. Repeated unchanged
reconciliation reuses owner-held state and performs no history fold, writes or
syncs. Meaningful owner failure is reported; an unrelated later event does not
certify that a failed resource was installed.

### 8.1 Declaration authority

Existing ontology invocation/write policy governs changes to reactions,
helpers, actions and policy itself. Admission checks the policy before the
submitted edit; the edit cannot first grant itself permission. There is no
founding comparison or `can_declare_runtime` layer. Malformed active code is
reported and can be repaired through ordinary authorized editing.

An already running match or admitted transaction keeps its original custody
and cancellation rules. Removing its declaration prevents later matching;
it does not invent permission to cancel committed or uncertain work.

## 9. Reactions and durable consequences

A reaction's pattern is unified with an event for an existing owned agent.
Its eligibility clause may use `me/1`, `instance_of/2` and transitive `isa/2`.
The resulting bound goal enters the agent's existing ordinary signed queue;
normal ACL, action, multi-ontology transaction and outcome rules apply. The
originating clause executes once per event/agent even when inheritance has
several paths. Distinct clauses may all apply in stored order.

```prolog
react_on(assert(task_ready(Agent, Task)), handle_task(Task)) :-
    me(agent_instance_ref(_, _, Agent)),
    instance_of(Class, Agent),
    isa(Class, task_worker).
```

The durable agent is its classed ontology instance; its Erlang process is a
rebuildable current-host incarnation with no private knowledge base. Host epoch
and active-key checks fence new signed work. Typed resource owners handle node
bootstrap directly. The logical node receives an actor binding only in its own
exact ontology. For recovery, the affected ontology supplies typed data and
the node's trusted handler authenticates it through `recovery_observation/1`
before constructing a permitted report for its existing signed queue. Neither
an editable foreign reaction nor a lookalike public event supplies node authority.

Live notifications may be lost across a crash. Required work is represented
by ordinary domain facts or existing transaction/effect custody, not a second
message queue. For example, one transaction can record A waiting and B pending;
B's decision atomically records its consequence and both agents' completion.
Both agents recover that committed state after restart.

`fipa-pending-continuation-plan.md` specifies the explicit guarded continuation
policy, including its approved narrow exception for an unknown earlier domain
attempt. It must not become a generic retry of uncertain requests. An admitted
transaction retains its existing recovery owner and immutable signed identity.

`trigger_event/1` is a committed signal, not delivery confirmation. External
FIPA transport, volatile acknowledgements and irreversible external sends need
their own demonstrated integration requirements later. This plan does not
prescribe an outbox or extra reliable-delivery subsystem for internal agents.

## 10. Agents, users, and authorization

`agent` is the generic acting class. `human_user` is its human-specific
subclass, not a name for every public-key holder. `quod:agent` and
`quod:human_user` provide shared class rules; they are not global registries
that replace an actor's authoritative containing ontology.

Each acting instance records its class and active public key in its containing
ontology. Its stable identity is
`agent_instance_ref(Namespace, GenesisAnchor, Instance)`. Genesis stores the
local `Instance`, because an ontology cannot contain its own not-yet-known
anchor; the external reference is formed after slot 1 exists. The private key
stays outside the ledger: a browser-controlled instance uses its client key
provider, while an autonomous instance uses the node-local vault on its
committed host. Moving an agent rotates to a key staged in the destination
vault; it never transports the old secret. A signed request therefore proves
possession of an active key bound to the instance; the ordinary target
`can_invoke/4` policy decides what that agent may do.

`quod:human_user` defines the human-specific subclass and related profile
vocabulary. It does not contain a row for every human, define a second
authentication authority, or own a special creation executor. A new ontology
may include local facts such as
`instance_of(human_user, local_human_1)` and
`agent_key(local_human_1, PublicKey, active)` in its ordinary genesis; an
existing ontology may add the same facts through an ordinary transaction.
There is no core `create_agent` or `create_human_user` predicate.

The creator, contained instance, signing key, ACL permissions, and runtime host
are separate. An agent reference grants none of them implicitly. Ordinary
creation policy may authorize only a specific existing agent to call
`create_ontology/3`; that caller may be a FIPA agent whose conversation and
approval facts satisfy changeable Prolog prerequisites. This is ordinary ACL
and action policy, not a separate delegation feature.

The deployed transport authenticates a stable agent reference and its
active signing key in one format, without a second ACL or legacy signed route.
That identity proof does not replace or redefine the target ACL decision.

The current ACL is `can_invoke(Goal, Principal, OntologyCallChain, Target)` with
one authenticated actor and the active ontology namespace path. The engine
retains anchored scope identities internally. Direct-context node privileges
use this existing path; they do not require agent-to-agent delegation evidence.

The following `subject/3` vocabulary and examples are a **deferred proposal**,
not implemented proof fields, a settled ACL shape or transport guarantees.
Authentication, propagation and capability semantics require a separate design
before use. Neither current Quod nor its internal Request conversation depends
on this representation:

```prolog
subject(Agent, AgentChain, Capabilities)
```

- `Agent` is the originating `agent_instance_ref/3` on whose behalf the chain began;
  it may belong to any `agent` subclass;
- `AgentChain` is the non-empty delegation chain, current agent first, and
  every member is also an `agent_instance_ref/3`; and
- `Capabilities` are derived for the current agent by the receiver and replace
  the previous agent's capabilities.

In that proposed model, the signing credential and ACL subject are orthogonal.
The existing signature proves
that an active key bound to the claimed agent instance signed the exact
request. `subject/3` states on whose behalf, through which agents, and with
which current capabilities it acts. Wielding and agent-to-agent delegation
construct the triplet; merely possessing an `agent_key/3` never fabricates
one.

Examples:

```prolog
%% H and A are agent_instance_ref/3 terms. Human agent H wields avatar A.
subject(H, [A], AvatarCapabilities).

%% A delegates to B; B is now the current invoker.
subject(H, [B, A], BCapabilities).

%% Autonomous or load-test agent M acts directly.
subject(M, [M], MCapabilities).
```

The proposed agent-to-agent hop would require:

- the receiving agent is prepended to the chain;
- the receiving agent's capabilities replace the caller's capabilities;
- the authenticated origin and complete chain are transport-bound;
- every ontology in a cross-ontology call checks the same immutable chain.

Any future signed delegation format would need to bind its subject evidence.
This proposal does not change Quod's current canonical signed request format.

The proposal intends capability replacement as attenuation. Its chain would
preserve who delegated to whom, while the capability set
answers what the current receiving agent itself may do. A caller cannot lend its
capabilities to a weaker receiving agent. Policies that care about an ancestor
express that explicitly against the immutable chain.

## 11. Agents and Agent Platforms

### `quod:agent`

`quod:agent` defines only the common acting vocabulary:

```prolog
isa(agent, thing).
agent_key(LocalInstance, PublicKey, Status).
agent_platform(AgentRef, PlatformNamespace).
agent_hosted_on(AgentRef, NodeRef, Epoch).
agent_display_name(AgentRef, Name).
has_capability(AgentRef, Capability).
accepts_wielding(AgentRef, Subject).
```

Each specialised system ontology owns its own subclass statement:
`quod:node` defines `isa(node, agent)`, `quod:human_user` defines
`isa(human_user, agent)`, and the FIPA vocabulary defines
`isa(fipa_agent, agent)` and `isa(agent_platform, agent)`. An application or
load-test ontology may similarly define `isa(monkey_user, agent)` without an
Erlang or generic-vocabulary change.

Concrete actors use the existing class-first instance convention, for example
`instance_of(fipa_agent, local_agent_1)`; `isa/2` above is only class
inheritance. The external `agent_instance_ref/3` combines that local name with
the containing ontology's exact identity.

The actual instance facts live in an ordinary ontology. Independently managed
agents will normally use a dedicated ontology, while policy may deliberately
place several instances in one ontology. An Agent Platform is another ontology
that may coordinate, discover, or authorize work; containment alone does not
make it the instance's ACL authority.

The hosted process is P-state:

- it exists only on the current committed host node;
- it obtains durable state from its containing ontology;
- its in-process state is a cache or working set;
- restart and migration reconstruct it from D;
- stopping the process does not delete the agent.

No volatile endpoint is stored as part of the agent's identity.

## 12. FIPA mapping

Quod initially implements a practical FIPA profile, not the full formal mental
attitude calculus.

### AID

```prolog
aid(Name, Addresses, Resolvers, UserDefined).
```

- `Name` is the existing canonical `agent_instance_ref/3` byte representation,
  rendered on a FIPA text wire as `quod-agent-` followed by its unpadded
  base64url encoding. Decoding recovers those exact bytes; there is no AID
  registry or identity-mapping table.
- `Addresses` are ordered current transport addresses derived from P-state at
  lookup/send time.
- `Resolvers` identify the current Agent Platform/AMS resolvers and their
  current P-state routes. Agent migration may change `Addresses`, `Resolvers`,
  and `agent_platform/2`; it never changes `Name`.
- AIDs compare by the decoded canonical agent-reference bytes. A display name
  is `agent_display_name/2` application data, never identity.

The complete `aid/4` term is a wire/runtime value, not a committed fact. Only
stable identity, stable resolver names, and policy-approved user properties may
be D. Volatile addresses never enter consensus and are refreshed whenever an
AID is constructed. This identity is globally unique within one Quod network.
If future FIPA federation crosses distinct root network identities, the same
deterministic wire name also binds `NetworkIdentity`; that extension must not
introduce a registry, alias, or second agent identity.

### ACL envelope

```prolog
acl(
    Performative,
    Sender,
    Receivers,
    Content,
    acl_meta(Language, Ontology, Protocol, ConversationId,
             ReplyWith, InReplyTo, ReplyBy)
).
```

The first supported performatives are:

- `request`;
- `agree`;
- `refuse`;
- `failure`;
- `inform`;
- `not_understood`;
- `cancel`.

Every protocol message is checked against a Prolog conversation rule before it
is accepted. Conversation IDs are globally unique and non-empty.

### Mapping to Quod

- `request(DesiredState)` asks the receiver to establish
  `goal(DesiredState)` in its owning ontology under the authenticated subject
  context.
- `query_if(Goal)` uses a bounded target proof and returns an `inform`.
- `query_ref(Goal)` streams target answers into one or more `inform` messages.
- A FIPA `subscribe(Goal)` performative is application-level protocol state. It
  may establish or reuse the explicit durable subscriber-owned ontology
  relation and a source-qualified `react_on/2` interest described by
  `ontology-subscription-plan.md`; it is not itself a second transport
  subscription and is never inferred from query completion or a proof read
  set.
- `cancel` retracts the corresponding reaction/protocol commitment and removes
  the ontology relation only when no other local consumer still needs it, all
  through ordinary authorized transactions.

The future Erlang MTS transports addressed FIPA ACL envelopes between agents
within or across APs and enforces transport bounds. It does not discover
agents, services, ontologies, or hosts, and it never replaces QUIC,
`quod_directory`, or `::`. Prolog owns message meaning, authorization, and
protocol transitions.

## 13. Three discovery responsibilities

Do not merge these responsibilities.

### Quod ontology-route resolver

Maps only an exact ontology identity (namespace plus genesis anchor) to
currently verified hosts. A separate future Prolog-owned public-discovery
service may map a public name to that anchored identity and decide
discoverability; it does not become part of the route store. The target
ontology's ordinary lifecycle policy alone authorizes hosting. Endpoints,
contacts, leases, and freshness are P-state projected into the sole
`quod_directory` owner from signed fact-backed generations and local private
contacts derived through authenticated node-actor routes. It is not an AID resolver, and neither
a registration nor a contact hint makes a route authoritative.

This is a Quod role, not the FIPA Ontology Agent. The
[obsolete FIPA00006](https://www.fipa.org/specs/fipa00006/OC00006A.html) and
later [Experimental FIPA00086](https://www.fipa.org/specs/fipa00086/index.html)
Ontology Service revisions describe an OA for
ACL-facing public-ontology access, semantic queries/updates, comparison,
shared-ontology selection, and optional translation; neither standardises
Quod's namespace-to-current-host routing. A future Quod agent may expose an
OA-like semantic/discovery service and advertise it through the DF. It remains
a client/front end of the Quod route resolver and never owns or certifies live
routes. Calling it `fipa-oa` would require the separate FIPA00086 ACL contract,
which this plan does not claim.

### AMS -- white pages

Each Agent Platform is itself an ontology and projects the mandatory AMS role
from the [FIPA Agent Management Standard](https://www.fipa.org/specs/fipa00023/).
It supervises AP access, AID registration/search, agent residency and
lifecycle, and the AP description. AMS AID addresses are not Quod ontology
routes. A managed agent keeps its authoritative class, key, and state in the
ontology named by its `agent_instance_ref/3`; an AP record is not a substitute
identity.

### DF -- yellow pages

The optional DF stores agent descriptions and service advertisements. The
following is Quod's planned durable representation, not FIPA's literal wire
schema:

```prolog
service(AgentId, ServiceId, Type, Ontologies, Protocols, Languages, Lease).
```

It supports register, deregister, modify, and bounded search. Multiple DFs may
exist and federate; federation carries a globally unique search ID, maximum
depth, maximum results, and visited set.

The durable `Lease` is an absolute expiry (or a deterministic durable start
plus duration). The P index filters expired advertisements against current time
when it is rebuilt or queried. Expiry alone creates no pruning transaction;
renewal, deregistration, or an application retention policy changes D through
an ordinary authorized transaction.

DF registration advertises a capability; it does not guarantee that an agent
really provides it or will accept a particular request. The DF never becomes an
ontology route table; finding a discovery service through the DF and resolving
an ontology through that service remain two separate operations.

## 14. Performance architecture

1. All proof and handler contexts use MVCC snapshot handles.
2. Hot AMS, DF, AID, route, and handler indexes are P-state ETS tables rebuilt
   from ontology facts.
3. A live commit performs no network IO or P work on the Simplex or Prolog
   process.
4. The ordered `quod_runtime` tier performs only bounded index updates and
   enqueue operations. Heavy P runs in independent bounded resource workers.
5. E workers are supervised; one conflict lane serializes one affected
   resource while independent lanes run concurrently. Per-attempt timeout/heap
   safety comes from named physical-node policy, not a hidden worker-count cap.
6. Each transport pool connection uses channel priority classes. Consensus
   signaling is highest urgency; catch-up/control are bounded separately; feed,
   ACL, and future client state cannot consume consensus's priority under
   congestion. This requires the pinned QUIC fork's RFC 9218 stream priority
   support before those lower-priority producers are deployed.
7. Direct `::` queries remain the fast path; ACL is not inserted around every
   local proof.
8. Conversation retention has explicit domain pruning rules.
9. Reaction and resource selection is scoped to relevant event/changed heads;
   an unrelated update must not wake all pending work.
10. Metrics must expose queue depth, handler latency, reconciliation duration,
    retries, deduplication, dropped best-effort effects, and oldest pending
    durable effect.
11. Future QUIC datagrams avoid stream head-of-line blocking but share the
    connection's congestion window and pacing. Their byte rate and queues must
    be capped and load-tested against consensus latency before activation.
12. Transaction throughput, batching delay, and post-apply overhead are
    application-visible budgets for actions, not only consensus benchmarks.
    Every slice reports p50/p95/p99 commit latency and sustained transaction rate.

## 15. Proposed module boundaries

Do not scaffold the end state. The delivered substrate added two cohesive
modules and narrowed one existing owner:

- `quod_prolog` (existing, narrowed): D proof and committed projection only.
- `quod_runtime` (added): ordered post-apply P orchestration, reconciliation,
  and the one reaction dispatcher.
- `quod_predicates` (added): predicate registration metadata and context
  enforcement.

Internal FIPA reuses existing multi-ontology transactions. Pending continuation
uses one existing hosted-agent work cursor and queue, selected by Prolog and
woken by actual custody/resource changes. No per-namespace outbox scanner,
duplicate executor or durable copy of pending work belongs here.

Later slices introduce responsibilities for hosted-agent supervision, subjects,
MTS routing, AMS/DF indexes, and ontology resolution. Their ownership boundaries
remain explicit, but they may share a module while small. A named module is
created only when its slice lands and the code has a real API to hold.

The per-namespace supervision order is:

```text
simplex -> prolog -> catchup -> feed -> runtime
```

`runtime` is last. It depends on the committed KB and endpoints, while no
earlier child depends on its rebuildable P/E state. Its own crash therefore
restarts no consensus, KB, catch-up, or feed process; any earlier restart does
restart and reconcile it against the fresh KB.

## 16. Remaining implementation sequence

1. Complete the ordinary-reaction integration and focused lifecycle tests from
   `prolog-editing-plan.md`: live code changes, actual owner authority, recovery,
   host changes, cancellation and unchanged-operation cost. Remove the replaced
   handler/submission APIs and their obsolete fixtures.
2. Freeze the integrated tree and run the standing sequential release gates.
   Update stored system/domain reaction definitions through governed transactions
   at the coordinated release boundary. A code-only deploy cannot convert their
   old declarations; do not hide that requirement with a compatibility executor.
3. Continue internal FIPA with local AMS/DF ontology actions, selected profile
   requirements and representative conversations on this same substrate.
4. Add external interoperability only after selecting a real wire transport and
   counterpart. It must not redefine internal ontology transaction semantics.

Execution contexts, durable effects, generic identity, hosting and the internal
Request conversation already have concrete owners. This sequence extends those
owners for demonstrated missing capabilities rather than scaffolding parallel
platform machinery.

## 17. Documentation replaced by this plan

The replacement is already in force for delivered reaction work:

- `doc/content-layer-design.md` is a historical architecture record. Its
  section 14 is an as-built overview only; normative reaction semantics live in
  `doc/event-reaction-refinement-plan.md`, while explicit ontology following is
  governed by `doc/ontology-subscription-plan.md`;
- Onia/BBSvx D/P/E and action references are no longer treated as implementation
  specifications;
- `doc/client-world-direction.md` remains a non-normative consumer and
  performance-constraint document until its prerequisites land;
- `doc/deferred.md` entries are removed as their slices land;
- each public predicate and metric documents its user-visible meaning and
  execution context.

## 18. Decisions needed before later FIPA slices

These do not block the current internal Request conversation:

AID identity is no longer an open design choice. Its semantic `Name` is the
canonical agent-reference bytes and its text encoding is fixed in §12; an Agent
Platform appears only in resolver/residency data.

1. Whether and how to introduce `subject/3` for wielding and delegation,
   including authenticated evidence and capability vocabulary. Only the stable
   `agent_instance_ref/3` identity is fixed; the current ACL retains one principal.
2. Whether durable ACL inbox facts are retained indefinitely, retained by
   conversation policy, or compacted after an acknowledgement horizon.

## 19. Current checkpoints

Generic hosted-agent identity, epoch/key fencing, committed assignment,
authenticated failure reporting, policy-selected takeover and restart/partition
acceptance preceded this refactor. The current ordinary-reaction replacement
must preserve those guarantees; earlier deployment evidence alone does not
validate the replacement.

The internal Request conversation already commits related sender/receiver
state through existing multi-ontology transactions. Its guarded continuation
uses current pending domain facts and existing custody. The next checkpoints
are the completed ordinary-reaction lifecycle gates and the universal editing
eidolon, followed by AMS/DF and additional FIPA conversations. External transport
is separate work. None calls for an Erlang outbox, private knowledge base or
second executor.
