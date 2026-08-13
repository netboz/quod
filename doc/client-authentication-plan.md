# Client authentication and key custody

**Status:** first implementation slice landed locally: deterministic user
identity, node-bound Ed25519 challenge-response, short-lived node-local
sessions, and constrained user-home foundation. Typed world commands remain to
be added.

## Goal

A person uses an Ed25519 user key to authenticate to any Quod node, chooses an
agent they are allowed to wield, and receives a session whose immutable subject
is carried into every later typed client command. The browser never sends a
general Prolog goal.

New user registration is open initially: a fresh key may create its own user
home ontology. World, agent, and avatar access remain governed by their normal
ontology policies; registration grants no world authority.

## Key custody

The canonical public identity is a 32-byte Ed25519 public key. A private key
is never sent to Quod and no server-side vault is required.

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
3. **Remote-vault provider.** Later synchronizes only the encrypted bundle
   through an OAuth/WebDAV/object-store adapter. The vault receives neither the
   private key nor the passphrase.
4. **Hardware signer provider.** Later delegates `sign/1` to a genuine hardware
   key. It is distinct from USB-file storage.

The bundle format, KDF parameters, authenticated encryption, recovery UX, and
browser support matrix are security-sensitive versioned work. The initial
implementation must use a reviewed password KDF and authenticated encryption;
it must not silently fall back to plaintext browser storage.

## Registration

The client creates a key locally and submits a typed registration request:

```text
register_user_v1(PublicKey, ClientNonce, Signature)
```

`Signature` covers a domain-separated canonical request containing the
network identity, public key, and nonce. A node
verifies it before it begins the constrained user-home foundation operation.

There is no global ontology containing every user. `quod:user` is the shared
model and founding policy; a key deterministically names one home namespace:

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

The registration boundary derives the namespace and these facts itself; it
never accepts client-selected namespace text or Prolog source. Reusing a key
therefore resolves the same home. Display names remain optional profile data
inside that home and do not participate in identity or routing.

The home also contains one fixed ACL rule, supplied by Quod rather than the
browser. It grants `can_invoke/4` only to that home's active `user_key`:

```prolog
can_invoke(_, user(Key), _, _) :- user_key(_, Key, active).
```

This is source because Prolog variables must remain variables. Genesis data
facts deliberately do not preserve variables; they materialize an unbound
slot as the literal value `unbound`.

Open registration is deliberately narrow: it proves possession of the key,
not trust, citizenship, ownership of an avatar, or any privileged capability.
Rate limits and anti-abuse controls are ingress policy, not durable identity
facts. The initial node-local boundary admits at most 64 registration attempts
per minute, at most four from one peer address, and keeps at most 256 peer
counters. These limits are deliberately operational and replaceable; they do
not become user data or a network-wide identity registry.

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
subject(UserId, [AgentId], Capabilities)
```

Changing wielded agent creates a new immutable session subject rather than
mutating a subject beneath an in-flight request.

## Implemented registration endpoint

The dedicated client listener accepts only:

```text
POST /api/user/register
{ session_id, client_nonce, signature }
```

`session_id` must name a currently valid node-local challenge session.
`signature` covers the fixed registration bytes for that session key, the
pinned root genesis identity, and `client_nonce`. The server derives every
other value—user namespace, fixed facts, fixed ACL source, and root lifecycle
action. It therefore cannot create a client-selected ontology or execute a
client-supplied goal.

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

## Known gaps

Three properties are specified above but not yet enforced. They are recorded
here so that nothing downstream mistakes the current state for the finished one.

**A plan carries a user principal that no user signed.** Durable plans admit a
`{user, PublicKey}` principal, and every validator re-proves `can_invoke` as
that claimed user — but a plan is signed only by the sealing node's key. Nothing
binds the claimed user to a user signature, so an admitted validator can assert
authority it never saw. The typed-command ingress below is what closes this: it
binds the user's signature and command digest into the transaction. Until then,
user authority is only as strong as the node that sealed it. The blast radius
today is small — the sole user-principal action is founding one's own home,
whose shape root policy pins exactly — but no new user-principal action should
be added ahead of that binding.

**Top-level user authorization has a canonical chain shape.** A user command
enters its target directly rather than through another ontology. Its policy
therefore sees a one-element chain containing that target's anchored identity;
the durable authorization transcript records the target twice: once as the
target and once as this non-host entry. This is intentional: it prevents the
invisible empty-chain host permission from matching, and lets every validator
re-prove the identical policy decision. ACL authors should treat this as a
direct browser entry, not as the target calling itself.

**A user principal does not survive a scope boundary.** An invocation that
reaches another ontology through a scope session is authorized as the hosting
node, not as the user, and plans sealed on both sides of such a boundary carry
different principals — which the begin-record check rejects. So a user-principal
proof spanning more than one ontology cannot commit today. Single-namespace
registration is unaffected. Carrying the principal across the boundary is a
prerequisite for the first multi-ontology user command.

**Registration is rate-limited but not capped.** A node bounds registrations per
minute and per peer, not in total, and each one founds a durable ontology. Keys
are free, so sustained low-rate registration grows without limit. The bound
belongs in policy rather than in the ingress limiter — an admission predicate
the root ontology proves — consistent with treating business restrictions as
predicates rather than hard-coded runtime rules.

## Typed command ingress

A session alone is insufficient for a durable write. Each state-changing
client command carries a stable command id and a user signature over its
canonical typed payload, current session subject, target namespace, and
anti-replay nonce. The receiving node verifies it, rechecks session validity,
derives the engine-owned subject, and only then maps a bounded menu or GUI
event identifier to a server-owned desired state.

The eventual transaction plan binds that subject and signed command digest.
The existing node signature continues to attest consensus authorship; it does
not replace the user's signature. `outcome_unknown` is resolved by its exact
anchored outcome reference, never by submitting the command again.

## Explicit exclusions from the first slice

- no password sent to Quod;
- no plaintext private key in `localStorage`;
- no plaintext private key in an exported key file;
- no client-supplied Prolog goal;
- no bearer session copied into durable facts;
- no automatic discovery or execution of code from a user ontology;
- no vault provider until the encrypted bundle format and recovery story are
  implemented and tested.
