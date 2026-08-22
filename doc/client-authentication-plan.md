# Client authentication and key custody

**Status:** deterministic key authentication, node-bound Ed25519
challenge-response, short-lived node-local sessions, signed goals and cursors,
signed multi-ontology scopes, unresolved-operation persistence, the
constrained user-home foundation, and any-node signed-goal forwarding are
implemented in the working tree. The combined hard protocol break is not yet
committed or deployed; its review and release gates remain as specified in
`doc/signed-client-goals-plan.md`.

> **Terminology correction.** The implemented request format calls its signer
> `{user, Key}`.  That word is a temporary protocol label, not a claim that a
> signer is human.  `ontology-actor-architecture.md` is the authority for the
> replacement: every durable actor is represented by an ontology instance;
> `agent` is the general acting class;
> `human_user` is the human-specific subclass. The format change must be one
> hard break, with no second authentication or ACL path.

## Goal

A key-holding client uses an Ed25519 key to authenticate to a Quod node and
receives a session bound to that current implementation identity. The client may submit an ordinary
bounded Prolog goal; its signature, rather than a server-owned request
catalogue, binds the exact intent. A later agent milestone may extend that base
user into an immutable delegated subject after wielding is implemented; the
current client does not fabricate an agent chain or capabilities.

The current home-creation flow is a narrow transitional convenience. In the
target actor model `human_user` is simply a subclass of `agent`. A concrete
local instance and its active public keys are ordinary facts in an ontology;
independently managed instances will normally use a dedicated ontology, but
the protocol does not impose one instance per ontology. World, agent, and
avatar access remain governed by their normal ontology policies; creating an
ontology or asserting class membership grants no authority by itself.

## Key custody

In the implemented browser protocol, the authentication credential is a
32-byte Ed25519 public key. In the target actor model, the stable identity is
an `agent_instance_ref/3`; one or more active public keys are facts beside its
local instance in the containing ontology. A private key is never sent to Quod
or stored in an ontology.

The client implements a key-provider interface:

```text
publicKey() -> Ed25519 public key
sign(canonical bytes) -> Ed25519 signature
exportEncrypted(passphrase) -> portable encrypted bundle
importEncrypted(bundle, passphrase) -> provider
```

The first providers are:

1. **Local browser provider.** Stores an encrypted portable bundle in browser
   storage. It replaces BBSVX's plaintext `localStorage` record. The first
   implementation uses PBKDF2-SHA-256 (600,000 iterations) and AES-256-GCM,
   with a random 16-byte salt, random 12-byte nonce, and versioned associated
   data. The passphrase and plaintext key remain only in browser memory while
   the user is unlocking or using it. A private key may later be kept
   non-extractable when browser support permits, but export then requires a
   separately imported/exportable provider.
2. **USB-file provider.** The initial client can export and import that same
   encrypted bundle through a user-selected file. A plain USB stick is
   encrypted portable storage, not an automatically trusted hardware signer.
3. **Remote client-vault provider.** Later synchronizes only the encrypted bundle
   through an OAuth/WebDAV/object-store adapter. The vault receives neither the
   private key nor the passphrase.
4. **Hardware signer provider.** Later delegates `sign/1` to a genuine hardware
   key. It is distinct from USB-file storage.

Those providers cover a human-controlled browser agent. An autonomous agent
uses the node-local vault on its current committed host. Moving it stages a
new key in the destination vault and commits host/key rotation; it never copies
the old private key. The vault and later HSM/threshold backends are specified
in `ontology-actor-architecture.md` and reuse the same canonical signing
operation. They are not a second signed-goal protocol.

The bundle format, KDF parameters, authenticated encryption, recovery UX, and
browser support matrix are security-sensitive versioned work. The initial
implementation must use a reviewed password KDF and authenticated encryption;
it must not silently fall back to plaintext browser storage.

## User-home creation (as built)

The client creates its key locally, authenticates it, and signs the ordinary
argument-free Prolog goal `create_user_home.` against the exact `quod:root`
identity. The goal uses the same canonical signed request, operation ID, proof,
ACL, lifecycle effect, and durable outcome path as every other local signed
write. There is no registration-only protocol or executor.

There is no global ontology containing every user. In the current format, a key
deterministically names one home namespace:

```text
user:<sha256("quod-user-id-v1:" || Ed25519PublicKey) as lower-case hex>
```

The initial home contains only the exact, fixed facts derived from that key:

```prolog
user(UserId).
user_key(UserId, PublicKey, active).
user_home(UserId, Namespace).
user_home_version(1).
```

These `user/1` and `user_key/3` terms document the deployed transitional
format. The actor migration replaces them with the shared class convention and
generic key vocabulary in an ordinary ontology:

```prolog
instance_of(human_user, local_human_1).
agent_key(local_human_1, PublicKey, active).
```

The external identity is formed only after the ontology's genesis anchor is
known:

```prolog
agent_instance_ref(Namespace, GenesisAnchor, local_human_1)
```

`quod:human_user` defines that subclass and related profile vocabulary; it does
not hold every instance or provide a special creation executor. The target
model removes `create_user_home` rather than renaming it: initial class, key,
and ACL facts use the existing generic `create_ontology/2` genesis input, while
later facts use ordinary transactions. Class membership has no hidden runtime
effect.

Who may create an ontology containing a `human_user` instance is ordinary,
changeable Prolog policy. Its ACL may name one exact existing agent—possibly a
FIPA agent—and action prerequisites may require committed approvals, counts,
or any other domain rule. No hard-coded open-registration rule and no special
delegation protocol is part of the target identity model.

The lifecycle predicate derives the namespace and these facts from the
engine-owned signed user principal; it never accepts client-selected namespace
text or Prolog source. Reusing a key therefore resolves the same home. Display
names remain optional profile data inside that home and do not participate in
identity or routing.

The home also contains one fixed ACL rule, supplied by Quod rather than the
browser. It grants `can_invoke/4` only to that home's active `user_key`:

```prolog
can_invoke(_, user(Key), _, _) :- user_key(_, Key, active).
```

This is source because Prolog variables must remain variables. Genesis data
facts deliberately do not preserve variables; they materialize an unbound
slot as the literal value `unbound`.

Open home creation is deliberately narrow: it proves possession of the key,
not trust, citizenship, ownership of an avatar, or any privileged capability.
The shared signed-goal rate limits and anti-abuse controls are ingress policy,
not durable identity facts. They are deliberately operational and replaceable;
they do not become user data or a network-wide identity registry.

User homes are sparse: dormant homes are durable data, not permanently running
committees. Their placement and replication policy is separate from identity
and is introduced only when the user-home runtime is needed.

## Authentication and session

The protocol is challenge-response, not a bearer token created from a public
key:

```text
1. client -> auth_challenge_v1(PublicKey, ClientNonce)
2. node   -> ChallengeId, ServerNonce, Expiry, NodeKey, NetworkIdentity
3. client -> auth_complete_v1(ChallengeId, Signature)
4. node   -> opaque session handle bound to UserId and exact key
```

The signed canonical challenge is a fixed binary layout—not an Erlang-only
encoding—so browser Web Crypto signs exactly the same bytes. It binds protocol
version, network identity, receiving node key, challenge id, both nonces, and
expiry. A challenge is single-use, bounded, and held only in node-local
expiring session state. A signature cannot be replayed to another node,
network, or later challenge.

The session handle is opaque, secure, and short-lived. It is transport-bound
where the browser mechanism permits it; it is never an ontology fact and is
not itself authorization. The client later requests a wieldable agent. The
node proves ownership and `accepts_wielding/2`, then pins:

```prolog
subject(HumanAgentRef, [WieldedAgentRef], Capabilities)
```

Both identities are
`agent_instance_ref(Namespace, GenesisAnchor, Instance)` terms. The session
signature identifies the submitting key; this subject separately represents
the human origin, delegation chain, and receiver-derived capabilities.

Changing wielded agent creates a new immutable session subject rather than
mutating a subject beneath an in-flight request.

## Implemented user-home request

After login, the dedicated client listener accepts the same request as any
other signed local execution:

```text
POST /api/goals/execute
{ session_id, request, signature }
```

The signed request contains `create_user_home.`, targets the exact root anchor,
and is bound to the session key. The proof engine derives every other
value—user namespace, fixed facts, fixed ACL source, and lifecycle effect. The
client cannot choose the home name or genesis.

## Transport

The client endpoint is served over TLS, and this is a functional requirement
rather than only a confidentiality one: a browser exposes Web Crypto solely in a
secure context, so on a plaintext non-loopback origin the client cannot
generate, unlock, or sign with a key at all.

Without a configured certificate a node serves a self-signed P-256 certificate
kept beside its identity key and renewed automatically. The node's own Ed25519
identity certificate cannot be reused: browsers do not support Ed25519 in the
certificate path. That certificate authenticates nothing and is not asked to —
user authentication is the Ed25519 challenge-response below, which is unaffected
by who signed the transport. It exists to unlock the secure-context APIs and to
keep the session handle off the wire in the clear.

## Current boundaries

These boundaries are explicit so downstream work does not invent a second
identity or routing path.

**Top-level user authorization has a canonical chain shape.** A user goal
enters its target directly rather than through another ontology. Its policy
therefore sees a one-element chain containing that target's anchored identity;
the durable authorization transcript records the target twice: once as the
target and once as this non-host entry. This is intentional: it prevents the
invisible empty-chain host permission from matching, and lets every validator
re-prove the identical policy decision. ACL authors should treat this as a
direct browser entry, not as the target calling itself.

**A user principal survives every scope boundary unchanged.** Local, co-hosted,
remote, and nested scopes carry the exact signed request and `{user, Key}`
principal. Each target verifies the evidence before running its existing
`can_invoke/4` policy, and every participant plan binds the same request digest.
No target substitutes the hosting node identity and no second ACL exists.

**Ingress may enter through any client node.** The HTTP node verifies the
browser session and signed request, then either invokes a co-hosted exact
target or forwards the unchanged request bytes and signature to one pinned
validator for that namespace and genesis anchor. The target independently
verifies the signature, network, target identity, deadline, and authenticated
forwarding node before entering the same proof and `can_invoke/4` path as a
local request. Browser session identifiers and addresses are never forwarded.
Scope transport inside an admitted proof continues to carry the same signed
user and request evidence.

**User-home creation is rate-limited but not capped.** A node bounds signed
goals per user and peer, not homes in total, and each new key may found a durable
ontology. Any market-specific bound belongs in the root policy rather than in a
special ingress limiter, consistent with treating business restrictions as
predicates rather than hard-coded runtime rules.

## Signed goal ingress

A session alone is insufficient for a durable write. Each client goal carries
a stable operation id and a user signature over its exact bounded goal text,
execution mode, target namespace and genesis anchor, user key, and network
identity. The receiving node verifies it, rechecks session validity, derives
the engine-owned subject, and enters the existing proof path with the exact
goal. It does not map the request through a hard-coded predicate catalogue.

The sealed plan binds that subject and signed request digest. An ordinary
transaction carries the complete signed request; a distributed transaction
carries it once in the certified origin Begin while participant records bind
its digest. The existing node signature continues to attest consensus
authorship; it does not replace the user's signature. `outcome_unknown` is
resolved by its exact anchored operation or transaction outcome reference,
never by submitting the goal request again.

Before Execute or cursor Accept, the browser stores the exact signed request in
a bounded 64-row IndexedDB journal. A reload queries only
`POST /api/goals/outcomes` with those original bytes. Definite outcomes remove
rows; pending or unavailable outcomes retain them. Nothing is evicted to make
room. Without durable browser storage, login and reads continue to work but
durable submission is disabled before any write request is sent.

Client code may construct a goal from any interaction or received event, or a
person may enter one directly. Every case uses this same ingress.
The full contract, cross-ontology propagation, idempotency rules, and staged
implementation are specified in `doc/signed-client-goals-plan.md`.

## Explicit exclusions from the first slice

- no password sent to Quod;
- no plaintext private key in `localStorage`;
- no plaintext private key in an exported key file;
- no unsigned, unbounded, or server-substituted client goal;
- no bearer session copied into durable facts;
- no automatic discovery or execution of code from an agent's containing
  ontology;
- no remote browser-vault provider until the encrypted client bundle format and
  recovery story are implemented and tested. This exclusion is separate from
  the node-local autonomous-agent vault in
  `ontology-actor-architecture.md`.
