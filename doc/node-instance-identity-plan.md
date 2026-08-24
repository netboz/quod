# Physical node instances and durable node references — plan

**Status:** planning only; no code or format change is implemented by this
document. `ontology-actor-architecture.md` remains authoritative for the actor
model, `inter-ontology.md` for `::`, `ontology-subscription-plan.md` for
subscriptions, and the directory documents for live route discovery.

## 1. Problem and decision

Quod currently has two node-related concepts:

- one shared `quod:node` system ontology containing the `node` class, node
  policy, and governed Erlang bridges; and
- one Ed25519 keypair per running Quod node, used as its TLS, directory,
  transaction, and consensus identity.

The current code does not yet give each physical node the durable actor
representation required by `ontology-actor-architecture.md`. A node can be
named by its public key, but it cannot yet be named as a stable classed
instance in an exact ontology history.

The decided target is:

1. `quod:node` remains the one shared class/policy ontology. It contains no
   global table of physical node instances.
2. Each physical Quod node has one dedicated ordinary ontology containing the
   concrete `node` instance which represents it.
3. That instance is named everywhere through the existing generic actor
   shape:

   ```prolog
   agent_instance_ref(NodeNamespace, NodeGenesisAnchor, NodeInstance)
   ```

4. Node policy facts name this stable reference. They do not use an IP address,
   port, process identifier, Nomad allocation identifier, or current host name
   as the node's durable identity.
5. The existing node public key remains the cryptographic identity of TLS and
   consensus traffic. The node ontology binds that public key to its stable
   node instance through the same `agent_key/3` vocabulary used by every
   acting agent.
6. Consensus ordering, quorum rules, Brahms, `::`, subscriptions, and the
   directory keep their existing owners and semantics. This work must not add
   a node-specific proof path, ACL, route store, or executor.

The first implementation uses the node's existing Ed25519 public key as the
initial active `agent_key/3` value. This reuses one secret without conflating
its two roles: the key proves possession; the anchored instance reference is
the durable actor identity. A later key rotation changes the active key, not
the instance reference or ontology identity.

## 2. Exact terminology

| term | exact meaning | owner |
|---|---|---|
| node class | the `node` vocabulary and rules | shared `quod:node` system ontology |
| node instance | one concrete logical actor which represents a Quod node | that node's dedicated ontology |
| node reference | exact `agent_instance_ref/3` of the node instance | derived from certified ontology identity plus local instance term |
| node key | current Ed25519 public key used by the physical Quod runtime | public binding in the node ontology; private seed outside every ledger |
| committee member | a node key admitted by one ontology's `peer_admitted/4` facts | that ontology's ledger and existing consensus projection |
| node contact | volatile `{NodeKey, Endpoint}` observation | existing `quod_quic` contact cache |
| ontology route | volatile association between an exact ontology identity and a current host/contact | existing `quod_directory` |
| ontology subscription | durable semantic interest in another exact ontology | subscriber ontology's `subscribes/2` fact |

The words *node*, *host*, *member*, *contact*, and *route* are not
interchangeable. One physical node may host many ontologies. One ontology may
have many hosts. An ontology may call or subscribe to another ontology without
joining its committee or hosting its ledger.

## 3. Node ontology content

A node ontology is created through the existing root-owned
`create_ontology/2` action. It is an ordinary ontology, not a new lifecycle
kind and not automatically a system ontology. Its genesis contains at least:

```prolog
instance_of(node, NodeInstance).
agent_key(NodeInstance, NodePublicKey, active).
```

It also contains the explicit ACL and any domain facts selected by the
creation policy. The generic creator-provenance rule remains unchanged: the
creator is the authenticated actor which authorized `create_ontology/2`, not
the machine that happened to execute the post-commit creation effect. The node
instance does not automatically become ontology owner merely because it is
contained there.

`instance_of(node, NodeInstance)` alone grants nothing. It does not:

- activate a key;
- admit the key to any committee;
- grant an ACL right;
- make the ontology public;
- start a runtime process; or
- establish a network route.

Each outcome requires its existing explicit fact, policy, or runtime
mechanism. The exact local `NodeInstance` term and namespace naming convention
are creation-policy inputs; Erlang must not derive authorization from a
hard-coded class-instance name. The node stores the complete certified node
reference as a local bootstrap pointer after creation. That pointer is not
authority: boot accepts it only when the exact ontology history proves the
instance and active-key binding.

The pointer exists only to find the node's own ontology before that ontology
can state the rest of the node's desired hosting policy. It is not a general
namespace restart-intent store. On restart the normal namespace lifecycle
resumes that exact anchored node ontology and the identity projection
revalidates the pointer. A missing, conflicting, or wrong-anchor pointer leaves
actor identity unavailable; it never silently creates or selects another
instance. Once the node ontology is live, ordinary hosting facts are reconciled
through `state_handler/4` as specified by
`event-reaction-refinement-plan.md`.

The node ontology may be replicated on other nodes for durability. Hosting its
ledger does not grant possession of the represented node's private key and
does not permit another host to impersonate it.

## 4. What may be a durable node-related fact

Durable facts may name a node reference when the node itself is part of the
meaning. Examples include:

```prolog
agent_hosted_on(AgentRef, NodeRef, HostEpoch).
```

and future explicit ontology-hosting or administrative policies. The
predicate and its owning ontology must express one precise domain relation.
There is no generic `connection_node/1`, `attach_route/1`, or
`known_endpoint/2` fact in this plan.

Normal inter-ontology behavior remains ontology-based:

- `A::GoalInB` names B. The origin resolves one current B host through the
  existing directory and opens one proof scope. A does not join B's Brahms
  network.
- `subscribes(B, BAnchor)` names B. On every physical node which currently
  hosts A, the node-wide foreign-history owner follows B once and multiplexes
  A's local consumers over that certified follow. It resolves current B hosts
  through the directory; no durable node contact or target-side pattern
  registry is created.
- Every A host reconstructs its own certified B projection. Exactly one host
  selected by the grounded `react_on/3` executor may perform the live effect.
  A durable consequence is submitted as an ordinary transaction to A and is
  then replicated by A's consensus.

Therefore neither `::` nor a subscription needs a durable physical-node
contact fact. Their durable arguments identify the target ontology; their
current addresses remain runtime state.

If a future use case genuinely needs a persistent private node relationship,
its fact must name a `NodeRef` and state the relationship's purpose—for example
an operator-selected host assignment. A runtime projection may then resolve
the node's current key/contact and reconcile a live connection. The fact never
contains the endpoint and cannot make an unknown node reachable by itself: the
first authenticated contact must still come from the existing directory,
configured bootstrap contact, or explicit private seed mechanism.

## 5. Existing `peer_admitted/4` and endpoints

This plan does not change the current committee record:

```prolog
peer_admitted(NodeKey, Host, Port, NodeKey).
```

The fourth argument remains the key from which every current committee and
quorum is derived. The committed host and port are existing admission-time
contact/recovery data used by the current history projection. They are not the
node actor identity and must not be reused as a general durable directory.
The live directory and authenticated transport observations remain the source
of current reachability.

Replacing the first argument with a node reference, or removing the host and
port, would change membership validation and cold-recovery assumptions. That
work is excluded until the generic agent-identity evidence and an address-free
cold-recovery proof exist. It must be reviewed as one membership-format change,
not smuggled into node-ontology creation.

Consequently the first node-instance slice changes no consensus record,
committee projection, vote, certificate, or quorum calculation.

## 6. Enrollment and restart

### 6.1 First node of a new network

1. The node creates or loads its existing `node.key` and founds root through
   the existing one-time bootstrap procedure.
2. Once root is ready and the founding node is admitted, the node submits one
   ordinary root `create_ontology/2` goal containing its node instance, active
   public-key binding, and explicit ACL.
3. The existing lifecycle action commits one root effect record and creates
   the node ontology on the effect executor.
4. After the new ontology exposes its certified anchor, the node persists its
   exact node reference in the existing desired-state row and verifies the
   committed instance/key binding.
5. Only then is the generic actor identity available to higher-level node
   actions. Root bootstrap and consensus can continue to use their existing
   node-key identity until the separately reviewed generic-agent principal
   format replaces it atomically.

There is no `create_node`, `register_node`, or hidden Erlang creation API. An
enrollment tool may assemble and submit the generic Prolog goal, but the server
processes it through the same root action/effect path as every ontology
creation.

### 6.2 Additional node

1. The new runtime creates or loads its node key and joins root as an observer
   through existing configuration and transport.
2. Existing root membership policy admits that key through the unchanged
   `admit/3` path.
3. The admitted node submits the same ordinary root `create_ontology/2` goal
   for its node ontology. Policy may instead authorize another agent to submit
   it; creation and containment do not imply ownership.
4. The node retains and verifies the resulting exact reference through the
   existing desired-state store.
5. Any additional hosting of that exact node ontology uses the existing
   `quod:node::join_ontology/3` action.

The brief interval between root admission and node-ontology readiness is
explicit. During it, the process may participate under the existing transport
key but cannot claim the new stable actor reference. Node-level actor actions
fail closed until the certified node ontology is ready. Reconciliation retries
the ordinary creation/outcome workflow; it never invents another ontology or
reissues a write whose outcome is uncertain.

### 6.3 Restart, movement, and loss

| situation | required behavior |
|---|---|
| process restart with data volume | reload the same node key; resume the exact desired node ontology; verify the same instance/key binding before actor actions |
| endpoint or Nomad allocation changes | update only transport/directory state; no ontology fact changes |
| node ontology temporarily unreachable | consensus transport may continue under its current key; stable actor actions remain unavailable until certified identity state returns |
| node ontology hosted elsewhere | those hosts may serve certified identity state but cannot sign as the node without its private key |
| node key file lost | do not manufacture continuity; restore the authorized secret backup or enroll a new physical-node identity |
| active node key rotates | keep the same node reference; update `agent_key/3` through the generic key-rotation design and update affected committee membership through its separately reviewed safe transition |
| physical node is retired | ordinary policy revokes its actor key/hosting assignments and existing committee policy removes its transport key; history remains queryable |

## 7. Relationship to generic agent identity

`node` is an `agent` subclass. It must consume the generic agent-identity and
signed-goal work; it must not create a node-specific request format.

The internal `{node, NodeKey}` principal remains transitional bootstrap code.
Signed actor requests now carry one stable `agent_instance_ref/3` plus independently verifiable evidence
that the signing key is active in that exact containing ontology. A node actor
uses that same format. Its `node` class may affect Prolog policy, but it does
not affect signature verification, proof routing, transaction construction, or
consensus.

The node-instance slice may create and verify its ontology before replacing
the internal bootstrap principal, but it must not expose a parallel
node-reference principal. Activation
of node-instance authority waits for the common agent path.

## 8. D/P/E ownership

| artifact | class | exact owner |
|---|---|---|
| `instance_of(node, Instance)` | D | node ontology ledger |
| `agent_key(Instance, PublicKey, Status)` | D | node ontology ledger |
| node ACL, provenance, capabilities, and domain policy | D | node ontology ledger |
| committee `peer_admitted/4` | D | each committee ontology's existing ledger |
| `system_ontology/2` | D | root; lists shared system ontologies only, never per-node instance ontologies |
| exact local node-reference bootstrap pointer | P/configuration | minimal local boot configuration; accepted only after certified validation |
| endpoint, QUIC link, route, lease, expiry, and retry state | P | existing `quod_quic`, `quod_directory`, and namespace runtime owners |
| private node seed | secret provider state | existing node data directory/vault; never an ontology fact |
| create/join lifecycle operation | E | existing post-commit effect journal and namespace lifecycle |
| hosting start/stop convergence | P/E boundary | one `state_handler/4` reads committed node-ontology hosting facts and calls governed bridges |

No node-instance datum is copied into a second Erlang authority table. Erlang
may cache the verified reference and current key for execution, but the exact
ontology history remains authoritative.

## 9. Implementation slices

### Slice 1 — generic actor identity prerequisite

- Review and implement the request/evidence design in
  `generic-agent-identity-plan.md`.
- Replace transitional user-only identity through one signed-format break.
- Reuse one active-key verifier for browser, autonomous, FIPA, and node agents.
- Add no node-specific signer, ACL, proof entrypoint, or transaction verifier.

### Slice 2 — node ontology creation and local binding

- Add a pure node-genesis builder which returns ordinary
  `create_ontology/2` options; it does not call lifecycle APIs.
- Submit those options through the existing root action.
- Store one exact local bootstrap pointer with the ground instance term needed
  to find and verify the node ontology; do not turn it into general hosting
  authority or add a new store/process.
- Reconcile and validate the exact node ontology after restart.
- Keep `quod:node` as class/policy only and keep per-node identities out of
  `system_ontology/2`.

### Slice 3 — node actor activation

- Bind the generic actor principal to the verified node instance and active
  key.
- Move higher-level node actions from the transitional key-only principal to
  the generic actor principal in one change.
- Keep transport, committee, and consensus signatures keyed exactly as today.
- Delete the superseded principal clauses, tests, comments, and docs; retain no
  compatibility alias.

### Slice 4 — measured node policies

- Express agent hosting, ontology hosting, or explicit private-node relations
  as ordinary Prolog facts only when their concrete use cases require them.
- Reconcile them through the existing `state_handler` and effect owners.
- Extend existing directory discovery for any newly discoverable ontology
  class; do not add a node route service.
- Add metrics only for implemented reconciliation work, failures, and stale
  identity state. Do not add speculative panels or population ceilings.

Each slice closes its stale names, tests, comments, metrics, and documentation
before the next slice starts.

## 10. Required tests

1. Generic creation produces one ordinary ontology containing the exact node
   instance, active public-key fact, explicit ACL, and generated creator
   provenance; no node-specific lifecycle record exists.
2. The resulting reference uses the certified genesis anchor and supplied
   local instance term; a wrong anchor, wrong class, wrong instance, or wrong
   key fails closed.
3. Restart resumes the exact bootstrapped node ontology and reconstructs the same
   reference without creating another ontology or resubmitting an uncertain
   creation.
4. Static bootstrap configuration cannot silently replace a different node
   identity; exact identical configuration remains idempotent.
5. Hosting the node ontology on another physical node exposes certified facts
   but cannot produce a signature for the represented node.
6. Changing only endpoint or allocation leaves the node reference and every
   node-ontology fact unchanged.
7. Loss of the node ontology disables actor-level node operations without
   changing current consensus membership or accepting key-only actor claims.
8. A generic signed request succeeds for a verified node instance through the
   same path as another agent subclass; substituted instance, ontology,
   anchor, or active key is rejected by every validator.
9. `::` behavior remains unchanged and creates no subscription, node fact, or
   committee membership.
10. Every physical host of a subscribed ontology independently follows the
    certified target history; only the grounded executor host performs E, and
    any durable reaction result goes through the subscriber's ordinary
    consensus.
11. `peer_admitted/4`, validator projection, quorum calculation, directory
    owner, and QUIC contact cache remain unchanged in the first node-instance
    slice.
12. Private keys and current endpoints never appear in node ontology facts,
    subscription facts, actor references, transaction payloads, metrics, or
    logs.

## 11. Explicit exclusions

This plan does not:

- make `::` require a subscription;
- make a subscription join or host the target ontology;
- store current endpoints as ontology facts;
- add a global node-instance registry to root or `quod:node`;
- list per-node identity ontologies as system ontologies;
- change `peer_admitted/4` or consensus in the first node-instance slice;
- infer ownership, ACL rights, hosting, or process activation from
  `instance_of/2`;
- implement node-key rotation or committee-key replacement as a hidden part of
  ontology creation; or
- add another directory, foreign-history cache, proof path, ACL evaluator,
  lifecycle executor, or desired-state store.

## 12. Documentation closure

When implementation lands, update together:

- `ontology-actor-architecture.md` current-state and implementation-order
  sections;
- `README.md` actor identity and next-step status;
- lifecycle and agent plans which still describe `{node, Key}` as the final
  actor identity;
- directory documents only where a node reference is consumed by policy,
  without changing their endpoint/P-state contract; and
- operator enrollment/recovery instructions, including the distinction
  between restoring a node key and enrolling a new node identity.

No document may describe a node ontology as a system catalogue row, a network
endpoint as durable truth, or one subscriber host as the projection owner for
all replicas of the subscriber ontology.
