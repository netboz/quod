# Ontology actors and system bootstrap

**Status:** architectural principles, identity shape, and initial key-custody
model confirmed by Yan (2026-08-21). This document is the
authority for actor identity, system-ontology startup, agent hosting, and the
boundary between Prolog and Erlang. It changes no wire format or code by
itself. Existing `{user, Key}` signed-goal code is an as-built transitional
name, not the target identity model.

## 1. One durable model

Everything Quod names as an actor has its authoritative durable representation
in ontology state: a node, agent, human-facing user, service, avatar, world
component, or load generator. A concrete actor is a classed local instance in
an exact ontology history. That ontology contains its class facts, public
keys, policy, durable state, and relations to other ontologies.

An Erlang process is never a second owner of that truth. It is the rebuildable
runtime projection of one committed instance on one node. It may hold working
state, sockets, timers, and a non-secret vault key identifier, but never the
private key itself. It can be stopped and recreated from committed ontology
state.

There is no fixed global limit on the number of actor ontologies, system
ontologies, dormant ontologies, or certified histories. Per-request byte/work
bounds and operator- or ontology-declared backpressure remain valid safety
policy; they must not become a hard-coded population ceiling.

`agent` is the general class for an instance that can act. `node`,
`human_user`, `monkey_user`, and `fipa_agent` may be specialisations.
`human_user` is therefore unambiguously human-facing domain vocabulary; it is
not the generic name for every signer. The class model
uses Quod's existing Prolog convention—`isa(Subclass, Superclass)` and
`instance_of(Class, Instance)`—and is intended to align with the class,
individual, and subsumption concepts of the Web Ontology standards:

```prolog
isa(node, agent).
isa(human_user, agent).
isa(fipa_agent, agent).

instance_of(fipa_agent, local_agent_1).
agent_key(local_agent_1, PublicKey, active).
```

`AgentIdentity` is the stable reference to the concrete instance in the
ontology that contains it:

```prolog
agent_instance_ref(Namespace, GenesisAnchor, Instance)
```

`Namespace` and `GenesisAnchor` identify the exact ontology history;
`Instance` identifies the `agent` instance within it. The reference remains
stable when the agent changes host or rotates a signing key. It is not a magic
`self` atom, a public key, or an entry in a new global actor table. Web
Ontology interoperability maps this stable identity and the class vocabulary
to canonical identifiers; Erlang must not hard-code the class hierarchy.

The containing ontology stores the local `Instance`, not a reference containing
its own genesis anchor. A genesis cannot contain its own hash. Once slot 1 is
committed, callers combine the resulting exact ontology identity with that
local instance name to form `agent_instance_ref/3`. The same rule applies to
an instance added later by an ordinary transaction.

An agent reference identifies an instance; it grants no ownership or
permission. The creator is the ontology owner unless an explicit future
ownership-transfer policy says otherwise. The contained instances, their keys,
and the permissions granted by the ontology ACL remain separate. Creating an
ontology does not silently make every contained agent its owner, and adding
`instance_of/2` does not silently grant access.

Here, the creator is the authenticated agent whose authorized
`create_ontology/2` goal caused the lifecycle operation. It is not the node
that happened to execute the post-commit effect. The exact durable ownership
fact/ACL representation remains one of the reviewed choices in section 10.

Every identity in an ACL delegation chain uses this same
`agent_instance_ref/3` shape. A signing key and an ACL subject are deliberately
different: a signature proves which key submitted exact request bytes, while
the subject names the originating agent, delegation chain, and derived
capabilities. Validators accept the signature only when the key is active for
the claimed stable agent reference in the relevant committed view.

Those subclass facts belong to their defining ontologies: `quod:node` defines
`node`, `quod:human_user` defines `human_user`, and the FIPA vocabulary defines
`fipa_agent`. A future load-test ontology can define
`isa(monkey_user, agent)` without changing `quod:agent` or Erlang.

## 2. System ontology startup

`quod:root` is the sole bootstrap ontology pinned in a node's local
configuration. A node first starts or connects to root and catches it up. It
then proves the ordinary root predicate `system_ontology/2` to obtain exact
system ontology identities:

```prolog
system_ontology(Namespace, GenesisAnchor).
```

The ontology is created through the ordinary authorised lifecycle first. Its
exact genesis anchor is then registered in root by an ordinary root
transaction. Registration never creates an ontology or guesses an identity;
when no certified route for that anchor is currently available, a node waits
and retries asynchronously. Root itself is the configured bootstrap exception
and is not listed in the catalogue.

This extends the four-field mechanism implemented by Onia with the identity
anchor Quod requires. BBSvx had only `system_ontology/1` plus a hard-coded Erlang
catalogue; that split catalogue is the predecessor anti-pattern, not the model
to copy. A
joining node reads those facts from its synced root state and starts or
connects each described ontology. The shipped Prolog source and selected
external-predicate modules are founding inputs when an ontology is created;
they are not injected over a synced ledger. The generated genesis fact
`external_predicate_modules/1` pins each module name to the SHA-256 digest of
its shipped BEAM. Existing ontology
identity, directory, and QUIC mechanisms provide the contacts and verified
history; the root fact does not contain a socket endpoint.

The system family includes:

| ontology | responsibility |
|---|---|
| `quod:root` | configured bootstrap, system catalogue, network-wide control rules, and the bootstrap-safe node-wide effect-custody capacity; not itself a catalogue row |
| `quod:node` | node class, hosting policy, node actions, and node reality bridges |
| `quod:agent` | generic acting class, key vocabulary, and common agent rules |
| `quod:human_user` | `human_user` subclass and human profile/ownership vocabulary |

These are vocabulary and policy ontologies, not containers for every instance.
Each physical node has a node ontology containing an instance of the `node`
class. An independently managed agent will normally place its durable state
and instance in a dedicated ontology, but the model does not hard-code one
instance per ontology: ordinary `instance_of/2` facts may describe more than
one agent in a shared ontology when its policy chooses that granularity. The
exact namespace conventions are deliberately not frozen here. This preserves
the already-decided rule that millions of users do not become millions of rows
in one shared system ledger.

This deliberately differs from Onia's shared-system-ontology instance model.
Quod reuses Onia's root-driven bootstrap shape, but concrete agent instances
and their state live in ordinary instance ontologies rather than accumulating
in one shared agent or user ledger. Containment is not ownership: the
ontology's creator and ACL remain authoritative.

`quod:human_user` therefore has a narrow scope. It defines the `human_user`
subclass and human-specific rules. It is neither a registry of all humans nor
the identity checked by the generic signed-goal path. A new ontology may be
founded through the ordinary `create_ontology/2` lifecycle with local instance
facts in its genesis, for example:

```prolog
instance_of(human_user, local_human_1).
agent_key(local_human_1, PublicKey, active).
```

`quod:agent` supplies the shared superclass/key vocabulary. `quod:human_user`
supplies human-specific vocabulary and policies that an ordinary creation
policy may consult. The instance facts remain in the created ontology.

Quod has no core `create_agent` or `create_human_user` operation. Creating a
logical agent in an existing ontology is an ordinary transaction that asserts
the required class, key, ACL, and other policy facts. Giving that agent a new
ontology means passing the same facts as genesis input to the existing
`create_ontology/2` action. A domain ontology may define a convenience Prolog
action that constructs this fact set, but it must reuse those ordinary paths
and must not introduce another Erlang executor.

The two ordinary creation forms are therefore:

| case | operation | result |
|---|---|---|
| new containing ontology | call the existing `create_ontology/2` action with `instance_of/2`, `agent_key/3`, ACL, and domain facts in genesis | one normally founded ontology containing the new local agent instance |
| existing containing ontology | submit an ordinary authorized goal which asserts the required instance, key, ACL, and domain facts | one ordinary transaction in that ontology |

`instance_of(agent, Instance)` by itself records only class membership. It
does not make the instance an ontology owner, grant ACL rights, activate a
key, start an Erlang process, or create another ontology. Those outcomes need
their own explicit facts and ordinary policy. In particular, the creator's
ownership must be represented explicitly by the creation policy; it is not
inferred from whichever agent instances happen to be present in genesis.

The first agent on a newly founded network is not a special runtime case. Its
class, key, ownership, and ACL facts are founding input in an ontology genesis,
just as root and the system ontologies have reviewed founding input. Once
authenticated agents exist, the ordinary creation policy decides which of them
may found further ontologies. This avoids both a circular “agent required to
create the first agent” rule and a permanently open registration bypass.

Creation permission is likewise ordinary policy. An ACL may allow only one
specific existing `agent_instance_ref/3` to invoke `create_ontology/2`; that
agent may be a FIPA agent which first conducts an arbitrarily rich approval
workflow. The action prerequisites may inspect committed approval facts,
creation counts, or other ontology-defined policy and may be changed through
ordinary authorised transactions. This is not a special delegation protocol.

`instance_of(Class, Instance)` has no hidden runtime effect. It states class
membership. An ontology may define a derived `active_agent/1` rule from class,
active key, and any other required facts. A separate committed hosting fact,
such as `agent_hosted_on/3`, controls whether an Erlang agent process should
run. A browser-controlled `human_user` instance may need no Erlang process at
all.

Synchronising a system ontology does not merge its facts into every other KB.
Instance ontologies refer to its canonical class identities and consult its
rules through the ordinary ontology-selection mechanism. Any future Web
Ontology `imports` convenience must compile to that same explicit dependency;
it may not create hidden global facts or a second inter-ontology evaluator.

The descriptions are normal committed root facts, not a hard-coded list
duplicated in Erlang configuration. Root is the only bootstrap exception;
normal ontology routing remains the existing directory/QUIC mechanism. A
system ontology is synchronised like any other ontology. Its special status is
only that root lists it and every node starts or connects it before enabling
the projections that depend on its rules. Adding or removing a system ontology
is consequently a normal authorised root transaction followed by runtime
reconciliation.

Quod consumes only this `/2` catalogue. The shipped root starts from static
bootstrap configuration and is not a catalogue row. Root stores no source
path, Erlang module, option, or socket address; live routes remain directory
P-state. A node that lacks a module or whose local BEAM does not match the
genesis digest keeps that ontology not-ready while healthy catalogue rows
continue normally.

Catalogue reads and potentially slow child reconciliation run outside the
namespace manager's mailbox. The manager remains the one desired-state owner
and one serialized mutation lane changes namespace supervisors: direct local
lifecycle calls and catalogue reconciliation use the same worker lane instead
of racing or blocking the manager. Unavailable rows retry with exponential
backoff; exact already-materialized identities are reused without rescanning
their ledgers. Identical root facts deduplicate. A malformed fact is logged and
skipped, while conflicting anchors park only that namespace and retain its last
exact materialized identity until root resolves the conflict.

## 3. Prolog is the authority; Erlang is the bridge

Prolog rules and actions describe the desired durable state. Governed Erlang
external predicates are the narrow interface to the actual node, network, and
runtime. Each ontology-specific external predicate belongs to the ontology
whose immutable genesis names and hashes its shipped Erlang module. For the
first implementation, only system ontologies are founded with such modules.
Ordinary ontologies use Prolog plus the explicit common execution primitives;
this restriction can be reconsidered only through a reviewed extension.

When a node starts or follows an ontology, the canonical committed projection
reads the module manifest from certified slot 1 and installs those exact
modules before applying genesis. Live validators, restart replay, catch-up,
and foreign projections all use that same reducer and manifest.
The Erlang code that performs this loading and checks invocation context is
shared because the mechanics are identical; it owns no predicate catalogue and
grants no authority. There is no application-global list that silently
installs every reality bridge into every ontology:

Each named module carries the explicit `quod_predicate_module/0` marker and
implements the same loader contract already used by Quod and Onia:

```erlang
load(ErlogState) -> NewErlogState.
```

The shared loader verifies the local BEAM digest before loading code, calls
`Module:load/1`, and installs the returned state only in that ontology. It retains
Quod's existing invocation-context and predicate-class checks. It must not copy
BBSvx's `external_predicates/0` triples, its silent load-failure handling, or
its later workaround that loads physics, voxel, and agent runtime modules into
every ontology. A missing, malformed, unshipped, or failing module prevents
that ontology from becoming ready.

Every validator of an ontology must run the same declared module set and
release. Otherwise validators could derive different verdicts from identical
ledger state, which is a consensus-safety failure rather than a boot-time
convenience issue.

This is an explicit genesis-format break: a slot-1 transaction without the
canonical manifest is invalid. A module digest is immutable for that ontology
identity. Upgrades therefore keep the old versioned BEAM available for existing
ontologies and use a new module name/digest in a newly founded ontology when
behavior changes. Removing or replacing the pinned BEAM makes that ontology
not-ready; there is no compatibility fallback. A network whose existing root
predates the manifest requires the separately reviewed clean re-found or an
explicit migration format before deployment; changing root's own pinned module
set later has the same requirement.

This makes a pinned module append-only release history. A defect—including a
security defect—in that exact module cannot be patched in place for an existing
ontology identity: the correction requires a new versioned module, a newly
founded ontology, and an explicit state migration/succession. Releases must
therefore retain every historical BEAM still pinned by an ontology the network
expects to serve; deleting one deliberately makes that ontology unavailable.

| class | role |
|---|---|
| `query` | call Erlang to inspect or compute from live reality, then bind returned Prolog values; stage no durable change. A declared authority-releasing query, such as signing one canonical Quod request, uses this same path but requires the ordinary Prolog policy gate and a narrowly typed bridge |
| `staging` | stage ordinary durable facts in the current proof |
| `projection` | reconcile local runtime state from committed facts |
| `effect` | perform an irreversible real-world operation only after commit |

An external Erlang call does not by itself create a transaction. A read goal
may call one or more `query` predicates, receive bound values through Erlog's
`unify_prove_body`, and return without producing any ledger entry. Such a
predicate must be safe under proof retry and backtracking. A ledger entry is
created only when the normal goal path commits a durable diff or a durable
effect request.

Trusted internal Erlang functions may implement mechanics, but they may not be
a public or policy-bearing alternative to the Prolog route. Every ontology
predicate module declares its functors, classes, binding modes, permitted
contexts, and failure meanings. The ontology creator selects audited modules;
the immutable genesis decides which exact code belongs to that ontology
incarnation. Root decides only which already-founded ontology incarnations are
system ontologies.

The ordinary action pattern is unchanged:

```prolog
action(Transition, Prerequisites, DesiredState).
goal(DesiredState).
```

For example, `quod:node` defines the policy and actions by which a node starts
or stops an agent runtime, and its named Erlang predicate module implements the
actual local process operation. The durable fact says which node should host
the agent. After that fact commits, the existing runtime/reaction machinery
calls the `quod:node` bridge on the selected node. If the process later dies,
the committed fact still says that it should run, so reconciliation can start
it again. The same separation applies to creating, joining, leaving, and
stopping hosted ontologies.

In plain terms, Prolog first records **what must be true**; Erlang then makes
the machine match that truth. A proof may decide and commit
`agent_hosted_on(A, N, Epoch)`. Only after that commit may the external
`start_agent` predicate start A's process on N. If N restarts, it reads the
committed fact and starts A again. A failed or abandoned proof never starts A.
This is one ordered path, not a Prolog path plus an Erlang management path.

```prolog
action(assign_agent_host(Agent, Node, Epoch),
       [eligible_host(Agent, Node), next_host_epoch(Agent, Epoch)],
       agent_hosted_on(Agent, Node, Epoch)).
```

The precise policy predicates are domain content. The common action relation, proof,
transaction, consensus, and runtime scheduler are reused.

### 3.1 Durable and runtime classification

The actor model adds no hidden state category:

| artifact | class | consequence |
|---|---|---|
| `instance_of/2`, `agent_key/3`, ACL, explicit ownership, and agent domain state | D | ordinary committed ontology facts |
| `agent_hosted_on/3` and its host epoch | D | ordinary committed desired state |
| `system_ontology/2` | D | ordinary committed root catalogue fact |
| live Erlang agent process, sockets, timers, and reconstructed working set | P | rebuildable from committed state; never authoritative |
| local encrypted private key | outside the ontology D/P/E model | secret provider state; never committed, published, subscribed, or logged |
| starting/stopping a process or hosted ontology after authorization | E | happens only after the governing durable action commits |
| signing one canonical request | authority-releasing query | no ledger record and no durable mutation; ordinary policy still authorizes it |

This table is descriptive, not a new executor. All durable rows use the
existing proof and transaction path; runtime reconciliation uses the existing
projection/effect machinery.

### 3.2 Existing bridge inventory and target ownership

`quod_predicates` now owns only common loading, engine-local registration, and
invocation checks. There is no application-global ownership list. Predicate
modules register their own bridges, and each system ontology receives only the
modules pinned by its certified genesis:

| current functors | current class | direction |
|---|---|---|
| `peer_ready/1`, `admit/3`, `remove/1` | query/staging | common membership primitives registered in every ontology; policy still decides whether they may be invoked |
| `directory_host/5`, `directory_control_peer/1` | `query` | `quod:root` or a later directory system ontology; one owner only |
| `ontology_join_state/2`, `ontology_genesis_anchor/2` | `query` | move with lifecycle ownership to the `quod:node` predicate module; node policy reuses these local observations rather than duplicating them |
| `current_principal/1`, `create_ontology/2`, `join_ontology/3` | query plus ordinary action/staging | move to `quod:node`; the principal query binds existing proof authority, while create/join reuse the normal action path and the one prepared-effect journal because they change what a node hosts |
| `effect_custody_capacity/1`, `set_effect_custody_capacity/1`, internal capacity projection | ordinary D plus one founding `projection` bridge | root is the sole policy owner because it starts before any other system ontology; default 64 or one committed override (including `unlimited`) is projected through the existing state-handler tier into the one node-wide journal |
| current user-home helpers | mixed action/query | remove as a generic identity path; initialise class/key/ACL facts through ordinary transactions or the existing generic `create_ontology/2` genesis input; add no agent-specific executor |
| `projection_noop/1`, `enqueue_projection/2` | `projection` | common runtime machinery registered in every ontology |

`ask`, `transaction`, `goal`, and the common action relation are Prolog execution
primitives, not reality bridges, and do not move into this registry. Internal
same-VM Erlang functions remain implementation details beneath a governed
bridge; they are not separately exposed as authority-bearing APIs.

`peer_ready/1` is an availability observation used while an ontology re-proves
its own `can_join` policy. It checks recent authenticated feed state and
bounded height lag; it grants no permission, proves no honesty, and writes no
ledger entry. It is therefore a common membership primitive, not a reality
predicate owned only by `quod:node`.

## 4. Acting and signing

An acting agent has a public key in its containing ontology and a private key
outside the ledger. It is never committed, logged, copied through an ontology
subscription, or embedded in a route.

Key custody depends on the runtime:

- a browser-controlled agent keeps an encrypted private-key bundle in the
  browser, a user-selected USB file/device, or a client-side vault provider;
- an autonomous agent uses the vault on its current host node;
- a later HSM or threshold signer replaces the node vault's secret backend,
  not the agent identity, signed-goal protocol, or authorization path.

### 4.1 The node vault

Each Quod node runs one supervised Erlang vault service inside the application.
The initial service generates agent keys, encrypts them at rest on that node,
signs one exact canonical Quod request, rotates or deletes local key material,
and exposes bounded health and non-secret audit information. Private keys are
never returned to an agent process and never enter an ontology, block, log,
metric, route, subscription, or crash report.

The vault has a configurable internal HTTPS Cowboy endpoint, separate from the
public browser-client listener and protected by mutual TLS. The endpoint is an
implementation boundary so the local encrypted store can later be replaced by
an HSM or managed vault. It is not a second permission system: mutual TLS only
identifies the Quod node using the service, while the ordinary Prolog policy
path remains the sole authority that decides whether an agent may request the
operation. The listener must not expose a public or unrestricted signing API.

The bridge accepts only a typed canonical Quod request, never arbitrary bytes.
The signed domain binds the network identity, target namespace and genesis
anchor, stable `agent_instance_ref/3`, active public key, committed host epoch,
operation identifier, nonce, goal, and every other field already required by
the canonical signed-goal format. A signature released for one network,
ontology, agent, host epoch, or operation therefore cannot be replayed as a
different request. The external predicate receives engine-owned context,
checks the ordinary Prolog policy, calls the local vault, and binds the
signature through `unify_prove_body`.

Signing creates no ledger entry because it changes no durable truth, but it is
an **authority-releasing query**, not an unrestricted ordinary query: its result permits
an agent to act. Ed25519 signing is retry-safe. Bounded operational audit stays
outside the ledger; any durable audit statement must be an explicit ordinary
goal and transaction, never a hidden side effect of signing.

An agent signs one normal goal request. Validators verify the signature,
bind the key to the claimed instance in its containing ontology, and run the ordinary
`can_invoke/4`, proof, transaction, multi-ontology transaction, and outcome
paths.  The signing layer must not classify goals or create an agent-only ACL.

The ACL remains a triplet, generalised without changing its role:
`subject(Agent, AgentChain, Capabilities)`. `Agent` is the originating
`agent_instance_ref/3`, and every member of `AgentChain` has that same stable
reference shape. The referenced instance may
be a `human_user`, `monkey_user`, FIPA agent, or autonomous service. The
request signer and ACL subject answer different questions. The signer
identifies the key that submitted the bytes; the triplet carries the origin
agent, immutable delegation chain, and receiver-derived current capabilities.
Wielding/delegation constructs that triplet. An agent key alone does not
create, shorten, or replace it.

The current signed request calls this principal `{user, Key}`. That is an
implemented protocol label, not permission to silently treat every signer as a
human.  The actor migration must replace it everywhere at once with a single
agent-bound representation; it must not retain a compatibility alias or a
second signed-goal route.

## 5. Hosting, restart, and migration

The code does not yet provide cross-node agent-process failover. That is the
missing feature—not a consensus problem. The durable assignment will include a
monotonically advancing host epoch. A runtime projection starts only when its
local node is the committed current host. On a node failure, an authorised
`quod:node` action selects another host and commits the newer assignment. The
new host reconstructs the process from the containing ontology. A returning old
host observes the newer epoch and stops.

Moving an agent never copies its private key. The destination node first asks
its local vault to generate a staged key. One ordinary coordinated transaction
then commits the newer host epoch and the new active public key while revoking
the old key. Only after that commit does the destination start the agent
process. Validators reject the old key from that committed view onward, and a
returning old host also observes the newer epoch and stops. The host epoch
fences the runtime while key rotation fences its authority cryptographically;
the existing receiver-side operation/effect identifiers still deduplicate the
short crash-overlap window.

A staged key that never commits is inert local garbage: no validator recognizes
it, and the destination vault may collect it after a bounded local retention
period. The first implementation keeps staged keys only in the destination
vault; a destination failure simply requires generating another candidate key.
If the transaction commits but the destination cannot start, the committed
assignment remains visible, the agent cannot act, and reconciliation retries.
Recovery never silently restores the old key or compensates the committed
facts. An authorized agent submits another explicit host-assignment action if
policy decides to move again.

Who may request reassignment is ordinary ontology policy—for example the
agent itself, an Agent Platform, or an operator agent. How quickly it does so
is deployment policy, not a hard-coded protocol timeout. BBSvx's epochless
`reown_to_self` failover is explicitly not reused: a returning old host could
otherwise resume stale authority.

## 6. What does and does not change

This direction does **not** alter consensus: no new consensus algorithm,
quorum rule, block phase, or special actor transaction is introduced. An
actor's state, class, hosting assignment, and action result are ordinary
ontology facts and use ordinary single-ontology or DTX commit paths.

It does require work above consensus:

1. catalogue the existing external predicates and eliminate direct management
   paths that duplicate their governed Prolog route;
2. make root's committed system catalogue drive `quod:node`, `quod:agent`, and
   `quod:human_user` startup;
3. migrate the signed-goal principal from the temporary user-key label to
   `agent_instance_ref/3` plus its active key binding, in one reviewed format
   break;
4. move agent durable state from an Agent Platform record to the exact
   ontology containing each agent instance; policy may use a dedicated
   ontology or deliberately place several instances in one, while Agent
   Platforms coordinate them as ordinary ontologies;
5. implement host assignment/failover through `quod:node` actions and the
   existing `state_handler` projection tier;
6. implement the node-local vault and rotation-based host migration; later HSM
   or threshold backends retain the same narrow provider boundary;
7. align class and identity vocabulary with the selected Web Ontology
   representation without embedding domain class logic in Erlang.

## 7. Current-state honesty

The codebase now has the engine-local predicate registry and root-driven system
ontology bootstrap described above. It creates no ontology from a catalogue
row: an ontology is founded normally, its exact anchor is committed in root,
and every node then joins or resumes that exact history through the existing
namespace manager and directory. It does **not** yet have the anchored
agent-instance identity, generic agent signing principal, or agent
key-migration custody described here. Root currently carries node admission facts
and the signed protocol still uses `{user, Key}`. These are transitional
implementation facts, not a second architectural model.

## 8. Required acceptance tests

Before implementation is declared complete, tests must show:

1. a fresh node trusts only root configuration, reads `system_ontology/2` from
   verified root history, and starts or connects every listed system ontology;
2. an unlisted ontology never gains system status, and a route to the wrong
   anchored history never reaches ready;
3. a node-management action is authorised by `quod:node` policy, commits its
   fact, and only then changes local hosting;
4. an agent process starts from its containing ontology, restarts from committed state,
   and does not replay completed effects;
5. a committed host move starts only the new epoch; an old host cannot keep
   acting after it returns;
6. an agent-signed local and multi-ontology goal follows the exact ordinary
   ACL/proof/transaction path; a key not bound to the claimed agent fails on
   every validator;
7. user and FIPA class facts alter only domain policy, never the signing or
   consensus path;
8. private keys never appear in facts, transaction blobs, logs, route state,
   subscription data, metrics, or crash reports;
9. the vault refuses arbitrary bytes, cross-network replay, the wrong
   `agent_instance_ref/3`, a stale host epoch, and a revoked key;
10. a staged key is unusable before commit, a committed move invalidates the
    old key even if the destination is down, and retry never copies or restores
    the old secret;
11. an unavailable or mutually unauthenticated vault cannot be used as a
    fallback signing route and leaves the agent visibly unable to act;
12. validators and foreign followers load the exact genesis-declared predicate
    modules or keep that ontology not-ready; one unavailable catalogue row
    does not block healthy system ontologies;
13. generic ontology creation can found an ontology containing class, key,
    explicit creator ownership, and ACL facts without an agent-specific
    lifecycle operation; the resulting `agent_instance_ref/3` uses the actual
    certified genesis anchor;
14. an existing ontology can add another agent instance through one ordinary
    authorized transaction, and class membership alone grants no ownership,
    ACL right, key authority, or runtime process;
15. creation policy can admit one exact FIPA agent and reject another, and an
    ordinary authorized policy change can change the prerequisites without an
    Erlang or protocol change; and
16. the selected signed-goal entry model validates an active key through one
    common path for local, remote, and multi-ontology goals, with revoked,
    foreign, and substituted instance references rejected.

## 9. Reviewable implementation order

1. **External-predicate cleanup and system bootstrap—implemented in the current
   working tree.** Predicate modules own registration, the exact target engine
   owns action classification, root facts are the single post-bootstrap system
   source, and the application-global catalogue is deleted. The three shipped
   system sources are founding inputs; deployment must create them normally and
   then commit their exact anchors in root.
2. **Agent identity and signing.** Define the stable agent identity/key binding,
   remove the special user-home creation path in favour of ordinary facts and
   generic ontology genesis, and replace `{user, Key}`/`user_goal_v1`
   everywhere in one reviewed format break. Browser and machine actors keep
   using the same signed-goal endpoint.
3. **Node vault.** Add the one supervised local vault, narrow authority-query
   bridge, encrypted local store, internal mutually authenticated HTTPS
   provider boundary, canonical request binding, and negative security tests.
4. **Hosting and migration.** Add `quod:node` actions, committed host fencing,
   `state_handler` reconciliation, and move-by-rotation through destination
   vaults.
5. **FIPA specialisation.** Resume message, AMS, DF, delegation, and
   subscription slices with FIPA agents as ordinary `agent` subclasses stored
   in their exact containing ontologies.

Each slice must close its old names, routes, comments, tests, metrics, and docs
before the next starts. None creates a new proof, ACL, transaction, consensus,
directory, or runtime-projection path.

The current `peer_ready/1` availability policy uses compile-time freshness and
height-window values (`15 s` and `256` slots). Those are existing operational
defaults, not security guarantees or population limits. Before this bootstrap
work is released they must become explicit validated configuration, or be
deliberately retained through a separately reviewed policy decision; they must
not remain accidental magic numbers.

The concrete capability vocabulary carried by `subject/3` remains a later
delegation/FIPA design decision. It does not block the bootstrap, identity, or
vault slices because those slices preserve the existing ACL evaluator and do
not manufacture capabilities.

## 10. Reviewed decisions and remaining proof obligation

### 10.1 Signed goals originate in the agent's containing ontology

Every signed request enters the exact ontology containing the claimed agent
instance. Another target is expressed through the existing `Target::Goal`
selector. Direct signed entry into an arbitrary target is removed in the
agent-format break; it is not retained as a compatibility route. This makes
the containing ontology the one proof controller and the one place that checks
the active `agent_key/3` fact.

That local check alone is not enough authority for another ontology. A remote
target must not trust one origin node's claim that the key is active. Before
implementation, the existing scope authentication/plan evidence must be
refactored to carry one independently verifiable origin authorization from the
containing ontology, usable by local, remote, cursor, read, transaction, and
DTX paths. It must reuse the same origin proof/certificate evidence and must
not make every target invent a separate key lookup or continuously follow
every possible agent ontology. This transferable proof is the one remaining
security design obligation for the format break.

### 10.2 Creator provenance is an immutable generated genesis fact

The new ontology contains exactly one reserved generated fact:

```prolog
ontology_creator(agent_instance_ref(CreatorNs, CreatorAnchor, CreatorInstance)).
```

It records immutable provenance. Initial ACL policy may derive the creator's
ownership from it; a future ownership-transfer vocabulary does not rewrite who
originally created the ontology. User-supplied genesis cannot assert, retract,
or define this reserved head. The generic creation preparer receives the
engine-owned authenticated principal and injects the fact beside the other
generated genesis facts. No contained agent becomes creator implicitly.

The public lifecycle record already binds an authenticated actor to the new
ontology identity, while the private prepared journal binds the exact genesis
bytes. The implementation must make the creator/anchor relation independently
checkable from certified public data; the local prepared digest alone is not a
claim a foreign validator can re-derive. The exact public binding and genesis
validation seam must be settled in the implementation plan before code lands.

### 10.3 Lifecycle uses the ordinary proof and action path

`can_invoke/4` is the one entry ACL. `can_create_ontology/3` and
`can_join_ontology/4` are ordinary action prerequisites which express changing
domain conditions; they are not a lifecycle ACL and do not run in an isolated
verdict. The authenticated principal is exposed to those prerequisites only by
a governed `current_principal/1` query which binds the value already carried by
the proof context.

Create and join therefore use the normal proof, selector, action, sealing,
transaction, outcome, and durable-effect machinery. Erlang bridges expose
node-local observations and stage a closed effect only after the declared
Prolog prerequisites succeed. The former hidden lifecycle authorization proof,
dedicated action worker, private lifecycle-principal field, lifecycle-only
action selector, and duplicate checks have been removed together. The
implemented refactor and deletion map are in
`ontology-lifecycle-single-path-plan.md`.

An ordinary prerequisite may use `::`, but the current transaction protocol
still forbids direct effects in a multi-participant DTX group. Therefore a live
foreign read plus creation currently ends as
`effect_requires_single_participant`; removing the local verdict must not be
misrepresented as removing that protocol rule. The simple first workflow is
for a FIPA or other external approval process to commit an approval fact in
`quod:node`, then let the later creation action read it locally. Atomic foreign
approval plus a local effect would require a separately reviewed DTX-effect
design.

The common target-first action rule also defines idempotence: an already-hosted
same-name create is a no-op without comparing its unused options, while join's
desired state includes the genesis anchor and therefore never treats a
different-anchor host as the requested result.
