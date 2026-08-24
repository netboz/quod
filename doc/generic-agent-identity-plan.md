# Generic ontology-backed agent identity

**Status:** implemented and deployed in 0.7.86 after the coordinated clean
re-found. The identity and certificate cleanup described here passed the
complete gate set before activation. `ontology-actor-architecture.md` remains authoritative
for the actor model; this document owns the request, identity-certificate, and
durable-operation contracts.

## 1. Fixed model

An agent is an instance stored in an ontology and named by the ground term:

```prolog
agent_instance_ref(Namespace, GenesisAnchor, Instance)
```

The canonical durable representation is one byte encoding of that complete
term. Erlang carries it as:

```erlang
{agent, AgentReferenceBlob}
```

The signed request names the containing ontology, instance, and signing key.
That ontology proves only:

```prolog
agent_key(Instance, PublicKey, active)
```

This establishes which agent signed. It grants no permission. Whenever a
predicate runs, the ontology containing that predicate applies its existing:

```prolog
can_invoke(Goal, AgentRef, CallChain, TargetNamespace)
```

There is no `{user, Key}` alias, global agent registry, second ACL, second
executor, or agent-specific transaction path.

## 2. One execution and authorization path

Every signed request enters the agent's containing ontology. Another ontology
is reached only through the existing `::` selector.

For a local goal in A:

1. A verifies the client signature;
2. A proves the key is active for the named agent;
3. A applies A's normal `can_invoke/4` rule; and
4. the existing proof, OCC, transaction, effect, and outcome paths continue.

For a direct selector `A -> B::Goal`:

1. A verifies the signature and active key;
2. A does **not** decide whether B's predicate is allowed;
3. B verifies the proof-scoped identity certificate; and
4. B applies B's normal `can_invoke/4` rule to `Goal` and the accumulated call
   chain.

For `A -> B -> C -> D`, the same identity certificate is forwarded unchanged.
Each target verifies it and applies its own ACL. No target calls back to A or
rebuilds A's Prolog facts merely to open the scope.

This separation is deliberate:

- active-key proof answers **who signed?**;
- the target's `can_invoke/4` answers **may this agent run this predicate
  here?**

The active-key proof is read-only and does not enter the target plan's OCC read
set. Target ACL reads retain the existing transcript and OCC behavior.

## 3. Signed request and stable identity

The request domain is `quod.agent.goal.v1`. Its signed fields are:

```text
network_identity
signing_public_key
operation_id
agent_namespace
agent_genesis_anchor
agent_instance_text
mode
parser_version
not_after_ms
goal_text
```

`agent_instance_text` is one dot-terminated, ground Prolog term parsed by the
same signed parser version as `goal_text`. Variables, multiple terms, trailing
input, oversized values, and non-ground values are rejected before
materialization. The canonical blob is validated independently of the atoms
already present in a VM.

The operation key is:

```erlang
{AgentReferenceBlob, OperationId}
```

It belongs to the stable agent, not to its current signing key. Key rotation
therefore cannot make the same operation appear new. The public operation
reference remains anchored in the agent ontology because that ledger owns the
operation claim and safe recovery after an uncertain response.

The browser session proves temporary possession of a signing key. One key may
serve multiple agents, so each request still selects the exact agent
reference. Browser and non-browser callers use the same request codec and
ingress.

## 4. Proof-scoped identity certificate

A remote target must not trust one node's claim that a key is active. At the
first remote selector, the existing node-wide `quod_ask_router` collects one
certificate from a quorum of the agent ontology's current validators.

Each validator receives a typed request, independently verifies the client
signature, checks that the exact active-key fact exists in its committed
snapshot, constructs the fixed statement, and signs that statement. There is
no API that signs caller-supplied bytes.

The statement binds:

```text
identity-certificate domain and version
network identity
exact anchored agent-ontology identity
ProofId
signed-request digest
canonical AgentReferenceBlob
signing public key
current committee_id
certificate expiry bounded by request and proof deadlines
active
```

It intentionally contains no `can_invoke/4` verdict. Permission belongs to
the target ontology and cannot be certified by the caller ontology.

The certificate is carried in the existing signed-goal scope authentication,
covered by the scope authentication digest, cached only in the existing router
owner row for that proof, and forwarded unchanged through nested scopes. It is
not reusable across ProofIds.

Targets certify the issuer's current committee through the existing
`quod_foreign_log` history owner, then verify the bounded distinct-member
signature set. Route hints in the certificate are connection candidates only;
TLS keys and certified membership establish authority. No endpoint enters a
durable fact, and no second committee verifier or foreign-state cache exists.

A committee change, unavailable quorum, stale view, expired certificate, or
unavailable origin history returns retryable `signed_scope_unavailable`. A bad
signature, binding, principal, request digest, or malformed certificate fails
closed.

For remote reads, a certificate issued just before a key rotation may remain
usable only until its short proof-bounded expiry. For writes, A's current
parent validation of the active key occurs before durable Begin/transaction
acceptance.

## 5. Durable writes and recovery

### 5.1 Local ordinary write

An ordinary signed transaction exists only when its target is the agent
ontology itself. It carries:

- the complete signed request;
- the target's normal authorization transcript; and
- the stable operation claim.

Validators independently verify the request and active key, re-prove the
target ACL transcript against the exact parent, and apply the existing OCC and
operation-claim rules.

### 5.2 Remote or multi-ontology write

A signed write with material outside A uses the existing group protocol, even
when there is only one foreign material participant. The DTX Begin committed
in A carries the complete signed request and stable operation claim. It no
longer carries an A-side authorization transcript for a direct remote
selector.

A's Begin validators verify:

- request signature and exact agent identity;
- current active key; and
- stable operation claim.

Each participant's Prepare keeps its existing target-owned authorization
transcript. Participant validators re-prove that target's `can_invoke/4`
against its exact parent. They can do so from the certified Begin and sealed
plan without contacting A.

Once an ordinary transaction or DTX Begin is durably accepted, later key
rotation does not cancel recovery. The accepted operation finishes or exposes
its anchored outcome; it is never re-proved or automatically resubmitted.

A remains an operation participant even if the direct remote selector creates
no material change in A. This is not duplicate authorization: it is the one
durable custody record needed to answer whether the signed operation was
accepted after a lost response.

Generic DTX support for arbitrary durable effects remains a separate protocol
issue. `create_ontology` happens to execute in Root, so Root owns that
predicate's change and lifecycle effect. Other predicates continue to execute
and stage effects in the ontologies that define them; they do not route through
Root.

## 6. Enrollment and actor terminology

There is no core `create_agent` or `create_human_user` predicate. An authorized
application creates an ontology or writes ordinary facts such as:

```prolog
instance_of(human_user, Alice),
agent_key(Alice, PublicKey, active).
```

The ontology's ACL decides which exact agent references may act in it. An
agent is not automatically the owner of the ontology containing it.

Root's `create_ontology` policy uses ordinary Prolog facts such as
`ontology_creator_agent/1`; registrars or later FIPA agents can own higher-level
enrollment policy without an Erlang registration service. The deprecated
key-derived user-home module, endpoint, predicate, and UI workflow are deleted.

Internal `{node, NodeKey}` principals remain a separate bootstrap role until
the node-instance plan is implemented. This is not a compatibility alias for
external agents.

## 7. Format break

The working tree uses one incompatible generation:

| owner | active format |
|---|---|
| browser session challenge | `quod.agent.challenge.v1` |
| signed request | `quod.agent.goal.v1` / `agent_goal_v1` |
| transaction bytes | V10 |
| semantic transaction id | V6 |
| DTX plan | V7 |
| DTX manifest | V3 |
| DTX control family | V3 |
| scope wire/auth | V5 |
| direct effect descriptor | V2 |
| identity certificate | `quod.agent.identity.v1` |

The client-goal endpoint and DTX endpoint still carry their opaque payloads in
their existing outer versions. Directory records, foreign-cache entries,
Simplex shares, and genesis transactions are unchanged.

There is no old-format decoder or forwarding shim. Activation requires the
already-planned coordinated clean re-found. `bootstrap=true` is used exactly
once to found that new empty network and never against an anchored fleet.

## 8. Keep / refactor / delete map

| area | keep or refactor | delete |
|---|---|---|
| request/client | one parser, codec, signature check, session, and operation journal | all `user_goal_v1`, direct-target, and user-home assumptions |
| proof/ACL | active-key check plus the existing target `authorize_scope` path | A-side ACL check for a direct remote selector; any second ACL |
| router/wire | one proof-owner row and existing signed-goal authentication arm | separate carrier, permanent certificate owner, per-hop collection |
| committee/history | `quod_foreign_log` and shared `quod_quorum` | second verifier, foreign Prolog materialization for identity |
| transaction/DTX | ordinary target transcript; Begin request plus operation claim; participant transcripts | Begin origin-authorization field and old tuple shape |
| enrollment | ordinary facts, Root action/effect path, existing ACL | `quod_user`, specialized home creation, registration service |
| UI/Explorer | stable agent-reference fields and signing-key fingerprint | user-id/key-as-actor fields and stale generated bundles |

All comments, metrics text, tests, architecture documents, and generated
assets are part of the same hard break. Historical text may retain old names
only when explicitly labelled historical.

## 9. Failure and race rules

| situation | required result |
|---|---|
| invalid request/signature/instance | deterministic refusal before execution |
| key inactive in exact agent ontology | deterministic refusal; no claim or remote scope |
| A ACL refuses a local goal | ordinary local `can_invoke/4` refusal |
| A ACL has no rule for direct `B::Goal` | irrelevant; B alone authorizes B's predicate |
| B ACL refuses | ordinary target `can_invoke/4` refusal |
| identity quorum or current view unavailable | retryable signed-scope unavailability |
| certificate malformed, wrongly bound, or signed by insufficient members | fail closed before target execution |
| key changes before A's durable acceptance | current-parent validation refuses |
| key changes after durable acceptance | existing recovery continues to one outcome |
| gateway/target crashes after uncertain submission | exact operation/group reference resolves; no re-proof |
| nested target has no pre-existing route to A | bounded certificate hints feed the same certified verifier |
| browser key exists without an agent reference | login may succeed; no signed goal can be formed |

## 10. Required closure tests

Before activation, tests must prove:

1. exact ground `agent_instance_ref/3` encoding, parser-version agreement, and
   symbol-bound behavior;
2. active-key success, inactive-key refusal, shared-key distinct agents, and
   key rotation preserving operation identity;
3. local A goal uses A key plus A ACL;
4. direct `A -> B::Goal` succeeds without an A permission rule and is refused
   when B's ACL refuses;
5. `A -> B -> C -> D` collects one identity certificate, forwards it unchanged,
   and applies each target's normal ACL and call chain;
6. fewer than quorum, duplicate/outsider signatures, wrong network, ProofId,
   request digest, agent reference, key, committee, domain, or expiry fail;
7. no API signs caller-selected bytes and no malformed list causes unbounded
   cryptographic work;
8. ordinary local write and signed foreign-singleton/multi-participant groups
   keep one stable operation claim and publish each target once;
9. DTX Begin recovery survives key rotation and participant Prepare validation
   does not contact A;
10. browser and Erlang request bytes agree, Explorer renders the new identity,
    and no `{user, Key}`, `quod_user`, old domain, decoder, or forwarding shim
    remains;
11. local signed work performs zero certificate collection; a deep remote call
    performs one quorum fan-out under the one proof deadline; and
12. no request is automatically re-proved after an uncertain outcome.

Gates are production/test compile, focused tests, full EUnit, relevant CT,
xref, Dialyzer, client/UI tests and builds, generated-asset equality, stale
symbol sweep, and `git diff --check`. Deployment additionally requires the
clean re-found and real remote read/cursor/write/DTX recovery checks.

## 11. Non-goals

- no vault implementation or key-rotation UI;
- no new agent-creation predicate;
- no automatic ownership from containment or class membership;
- no membership or committee format change;
- no hosting projection, agent-process failover, subscription, or reaction
  semantic change;
- no Web Ontology import engine; and
- no public-key-to-agent global index.
