# Network ontology directory — implementation contract

**Status: implemented first slice.** This contract describes the system-host
directory and private direct routes. It does not change consensus or the ledger.

## 1. Purpose

An ontology name must be routable even when it is not co-hosted on every node.
The directory answers a deliberately narrow question:

```prolog
directory_host(Ontology, GenesisAnchor, NodeKey, Host, Port).
```

It returns anchored nodes that may *currently* serve `Ontology`. It does not grant
access, decide membership, store ontology data, or order a transaction.

This supports three intended modes:

| mode | how it is reached | visible through global lookup? |
|---|---|---:|
| system | root-authorised, live directory advertisement | yes |
| discoverable (later) | the ontology authorises its own hosts | yes |
| private | an explicit direct seed held by its caller/parent | no |

For example, a character's `body` ontology can hold a direct route to its
private `arm` ontology.  The arm is not published merely because it exists.
Large ontologies do not enlarge this directory: a million facts or users may
be served by three hosts, producing at most three live route records.

## 2. Decided boundaries

1. **Routes are live network-observed soft state, never D.** Endpoint
   addresses, reachability and expiry are rebuildable local runtime state.
   They are not committed facts, leases, consensus transactions, or a
   D-derived `quod_runtime` state-handler projection.
2. **The directory is exposed to Prolog through an external predicate.** The
   bootstrap entrypoint is `quod:root`, but its answers come directly from an
   Erlang index.  No normal proof may make a blocking call to a directory
   server. Root's ordinary committed `system_ontology/2` facts are the sole
   source for the other system namespaces a node starts or connects at startup;
   the existing directory, private-seed, and QUIC mechanisms then locate and
   verify those ontologies. A root fact is a description, not a route or
   endpoint. See `ontology-actor-architecture.md`.
3. **The `::` scope resolver uses the same local Erlang index.** It does not
   make a Prolog selection merely to learn where to send that selection. This
   avoids a resolution loop and keeps scope opening bounded.
4. **A route is an authenticated routing hint, not write authority.** A
   caller still uses mutual TLS and the target's `can_read` policy, but those
   only identify the answering node and protect its data from the reader. They
   do **not** prove that an answer is truthful for the named ontology. In this
   first slice, read-answer integrity rests on the operator's exact allowlist
   of trusted system hosts. Every receiver independently verifies the original
   host's node-key signature and revalidates its exact allowlist — the same
   trust boundary as today's operator-configured contacts. At connection open,
   the peer's mutual-TLS node key must equal the route's expected `NodeKey`.
   A stale route can produce `{ontology_unreachable, Namespace}`; it cannot
   grant write permission or change a committee.
5. **No compatibility layer.** Signed system routes learned through
   root-derived control peers, plus local direct routes, are the only inputs to
   remote resolution. Static directory bootstrap addresses were removed
   outright: `directory.bootstraps` is invalid configuration, with no
   fallback parser or secondary resolver. Namespace `seeds` used to join
   consensus are a separate mechanism and are unchanged.
6. **No atom creation from directory input.** Namespace IDs, node IDs and
   addresses are bounded binaries at every directory/wire boundary.

These boundaries follow the existing `peer_ready/1` pattern: an external
predicate reads a public ETS index directly because a proof worker must not
round-trip into the process that owns its live state.

## 3. First slice: system directory plus private direct seeds

The first implementation deliberately includes only the two modes we need
now:

- **system namespaces**: root-controlled host authorisation plus live
  advertisements;
- **private namespaces**: local, explicit direct seeds; they are never
  advertised or returned by `directory_host/5`.

Self-advertised actor ontologies are a later slice. They need the
ontology-owned authorisation and revocation model in section 10; they are not
silently treated as system namespaces.

The first slice also makes no claim of per-agent hidden discovery. Quod does
not yet carry an authenticated agent subject through a proof. System entries
are intentionally network-visible; private entries stay private by never
entering the shared directory at all.  A later subject-aware directory policy
can restrict discoverable entries without pretending that it exists today.

## 4. Runtime design

### 4.1 One live directory service and index

The supervised application-level `quod_directory` service owns bounded,
protected ETS route, high-water and known-name indexes. The owner is the only
writer; proof and selected-scope workers read the indexes directly.

Conceptual record:

```text
{Ontology, NodeKey} => #{
    genesis_anchor := 32-byte hash | undefined,
    role           := validator | observer | undefined,
    endpoint       := {Host, Port},
    scope          := system | direct,
    expiry         := MonotonicMs,
    status         := provisional | confirmed
}
```

`Ontology`, `GenesisAnchor`, and `NodeKey` are binaries. Every system descriptor
`{Ontology, GenesisAnchor, validator | observer}` and the endpoint are covered
by the original author's signature. Direct seeds remain unanchored until their
separate authenticated identity exchange. At direct ingress a system endpoint
must also equal the endpoint in the authenticated link header; after
relay/resync it remains a hint until a TLS connection pinned to the signed
`NodeKey` succeeds. The advertised role is a routing hint, never authority.

On restart the owner recreates configured direct seeds. The system-route table
begins empty; once namespace startup is complete, the control process signs and
installs the allowlisted part of the live hosted set. It obtains the current
directory-control keys from the already-running root ontology, opens pinned
links to their last authenticated, self-advertised endpoints, and refills peer
records through announcement and resync. Nothing is persisted for route records: this is
rebuildable network-observed soft state by design. The separate, tiny per-node
`Epoch` counter in section 5 persists only to make a sender's announcements
replay-safe across its own restart.

The internal service API is:

```text
resolve(Ontology)                 -> unknown | {known, [Route]}
add_direct_seed(Ontology, Addr)   -> provisional route
confirm_direct_seed(Ontology, Addr, Peer, GenesisAnchor, Role)
                                      -> route is usable
install_record(Peer, Addr, HostedDescriptors, Epoch, Sequence)
                                      -> {ok, ReceiverExpiry} | {error, Reason}
install_records([Record])             -> one position-aligned result per
                                         record in one bounded writer turn
expire(Now)
```

`resolve/1` returns a bounded, deterministic preference order and never
performs network I/O. A failed attempt tries the next candidate. A route is
confirmed only after the authenticated identity exchange has atomically pinned
the target node key, exact ontology genesis anchor, and advertised role. A
confirmed direct seed cannot change any of those fields in place;
an address supplied by an operator is a seed, not proof that it serves that
ontology.

### 4.2 Prolog interface

Register `directory_host/5` as a `query`-class compiled predicate through the
existing `quod_predicates` dispatcher.  It is available only while proving in
the `quod:root` namespace.

Accepted mode in the first slice:

```prolog
directory_host(+Ontology, ?GenesisAnchor, ?NodeKey, ?Host, ?Port).
```

`Ontology` must be a ground ontology-name term (`quod:agent`, a flat binary at
an Erlang boundary, etc.), flattened by the existing atom-safe name bridge to
the canonical binary index key.  We intentionally reject an unbound ontology
name: enumerating every known namespace is unbounded and would disclose the
catalogue.  The handler reads the ETS index, unifies one route with the goal,
and installs an Erlog compiled choice point to produce further routes on
backtracking.  It uses the same shape as Erlog's compiled `member/2`/`append/3`
predicates; it does not call `gen_server`.

There is no staging or effect predicate in this slice.  Publishing and seeding
are control-plane operations, not ordinary ontology proofs: they change P or
open sockets and therefore cannot be smuggled into a normal proof.

### 4.3 Route selection for `::`

The remote scope path uses one resolver:

```text
1. target is co-hosted locally                  -> existing co-hosted scope path
2. confirmed local direct seed for target       -> open a target scope at that route
3. provisional local direct seed for target     -> one scoped TOFU attempt
4. confirmed system-directory routes for target -> try routes in order
5. target has never been known                   -> unknown_ontology
6. target is known but no live route succeeds    -> ontology_unreachable
```

The resolver calls `quod_directory:resolve/1` directly.  It does not invoke
`quod:root::directory_host/5` while opening a scope; the latter is the Prolog
view of the same local index.

System route `{NodeKey, Endpoint}` uses a dedicated pinned transport operation:

```text
Ref = quod_quic:open_link_pinned(NodeKey, Endpoint, Channel)
```

This operation dials `Endpoint` directly, without calling `resolve/1` or
`learn/2` and without reading or mutating the shared `NodeKey => Endpoint`
cache. Before it opens a usable link, it verifies that the remote TLS
certificate's Ed25519 key is exactly `NodeKey`. An outbound stream receives a
header ACK, not a second remote identity header; it is protected by that pinned
TLS connection. Any peer-opened stream on the connection still has its claimed
header key checked against both the TLS certificate and the expected
`NodeKey`. Connection reuse is keyed by the pair `{pinned, NodeKey, Endpoint}`,
never by a bare endpoint or by `NodeKey` alone. A certificate/header mismatch
fails this candidate and advances to the next route. This is a scoped
transport primitive, not a change to the existing by-endpoint seed dial or
by-pubkey cache dial. Its `link_up` / `link_error` result carries `Ref`, so a
late completion from a timed-out endpoint cannot be mistaken for a later
candidate using the same node key and channel.

The isolation must hold through the complete link stack. The pinned/no-learn
policy is threaded from `quod_quic` through `quod_conn` into `quod_link`;
the opener carries that policy in its authenticated stream header, and the
connection owner first binds the header key to the TLS certificate, then
either learns the ordinary hint or suppresses it. The inbound link holds its
ACK and all coalesced payload bytes behind that bind, so a rejected header
cannot reach a channel subscriber. Receiving `no_learn` also
makes reverse streams on that isolated connection carry `no_learn`; the
separately opened return link uses the same policy. Existing non-directory
links retain their current post-authentication auto-learn behaviour. A
successful pinned handshake is therefore no more able to overwrite the shared
cache than a failed one, and a mismatched ordinary header cannot transiently
poison another key before its connection is closed.

A confirmed direct seed intentionally shadows a shared system route for the
same name. This is local-administrator authority: it is useful for private
composition and explicit overrides, and must not surprise an operator.

### 4.4 Root-derived control peers

Directory-control discovery is a local query over the already-running root
ontology:

```prolog
directory_control_peer(?NodeKey).
```

The external predicate projects the distinct exact 32-byte keys from the
proof snapshot's committed `peer_admitted/4` facts. It is available only in a
`quod:root` execution context and stages no write or network effect. The
control process calls it through a monitored, timed local read-only proof, so
a root proof that is booting, rebuilding or delayed cannot block directory
renewal or message handling. A failed proof retains the last successful peer
set; a successful proof, including an empty result, replaces it exactly.

The predicate returns identities, not addresses. The control process has two
ways to reach them:

1. it first tries the root ontology's existing `content.seeds` as anonymous
   contact endpoints, using an isolated identity-discovery connection;
2. it also tries any current `NodeKey => Endpoint` transport observation with
   `open_link_pinned/3`.

A contact is promoted only after TLS and the link header agree on its Ed25519
key and that exact key is present in the latest successful root proof. Only
then does control publish the authenticated `Key => contact endpoint`
observation to the ordinary transport cache and retain the link. Thus a full
dynamic-port rollover can recover from the root contacts even when every
cached committed endpoint is stale. Contacts are address hints, never control
authority; the root predicate remains the sole authority.

This path does not call `directory_host/5`, `::`, or any directory route, so
there is no bootstrap cycle and no static directory-bootstrap configuration.

## 5. System advertisements and authority

The directory control plane has a dedicated, bounded transport message, not a
ledger entry and not a content-layer feed block:

```text
directory_announce(SignedRecord)

SignedRecord = {
    NodeKey, Endpoint,
    [{Namespace, GenesisAnchor, validator | observer}],
    Epoch, Sequence, Signature
}
```

It travels over authenticated links to the current root control peers obtained
from `directory_control_peer/1`. `Signature` is the node key's Ed25519
signature over the canonical encoding of every preceding field. At direct
ingress, the transport header's authenticated `NodeKey` and self-advertised
endpoint must exactly match the signed `NodeKey` and `Endpoint`. The key is
certificate-bound; the address remains the author's routing claim and is
availability-only because later use is key-pinned. At fanout/resync,
receivers verify that same original signature; relays cannot alter the
endpoint, hosted descriptors, epoch, or sequence, and cannot invent a
high-water mark for another host. Namespace-only signed payloads are rejected;
there is no compatibility decoder.

For the first slice, authorisation is deployment configuration owned by the
platform operator:

```text
exact system namespace -> allowed node public keys
```

An announcement is installed only when its authenticated node key is allowed
for that exact namespace. Prefix matching is deliberately forbidden in this
slice: permission for `quod:agent` never implies permission for `quod:root`.
The operator can therefore choose exactly which nodes answer system queries.
Renewal is periodic; expiry removes a crashed or departed host without any
durable write.

`Epoch` is a non-negative per-node counter persisted beside the node identity
and incremented before the node begins a new directory-serving lifetime.
`Sequence` increases for every advertisement and renewal in that epoch. A
receiver keeps the largest `{Epoch, Sequence}` seen for each `NodeKey` and
accepts only a strictly newer pair. The key is node-wide because each signed
record is that node's complete current namespace set: this also prevents an old
record from resurrecting a namespace removed by a newer record. An identical
or older frame does not extend expiry. Expiry is derived from the receiver's
monotonic clock only after acceptance. This makes duplicate/replayed frames
harmless for the lifetime of the receiver and survives a sender restart. A
receiver restart rebuilds its soft state from its local signed record and from
records received or resynced over exact authenticated root control links,
never from a persisted route table or a public reader.

The `{Epoch, Sequence}` high-water marks are retained separately from live
route records and survive route expiry for the lifetime of the directory
service, under the same bounded key budget. Thus an expired route is not
transiently resurrected by a late duplicate. A service restart discards all
soft indexes; only the local author, an authenticated direct author, or a
current root control peer may refill them. A compromised authorised relay can
replay an older still-valid signature before a current record arrives, but the
resulting route remains pinned to the allowlisted author's TLS key and can
therefore cause only temporary route unavailability, not false read identity
or write authority. Removing that availability-only replay window would require signed
validity time or durable receiver high-water and is deliberately outside this
soft-state slice.

Initial validated limits (deployment-configurable only within these safe
maxima) are:

| item | initial limit |
|---|---:|
| encoded announce payload | 16 KiB |
| namespaces in one announcement | 32 |
| routes retained per namespace | 8 |
| total route-table entries, including direct seeds | 2,048 |
| accepted announce/renewal rate per node key | 1 per 5 s |
| renewal interval / route TTL | 10 s / 30 s |
| resync snapshot page | 128 route records |

Oversized bytes are rejected before decoding; decoded cardinality/rate limits
are validated before any route-table mutation. A full table rejects new
lower-preference records rather than silently evicting a live route. A host
coalesces its current served namespace set into the next permitted renewal
rather than sending an unbounded stream of changes.

The local signed set is derived from namespaces actually running under
`quod_ns_sup`, intersected with this node's exact system allowlist. Desired
namespace configurations are retained by `quod_namespace_manager`, which
reconstructs both content and Brahms children if either dynamic supervisor is
replaced. Private
local namespaces do not consume the 32-name public-announcement budget. A
successful namespace start or stop notifies the control process; each accepted
update replaces the complete previous set, and an empty signed set is an
authenticated withdrawal. Periodic renewal re-reads the registry, so a lost
notification self-heals. A control-child restart also re-reads it under a new
epoch. Full application startup provides an explicit completion barrier, so
recovery cannot publish an empty or partially started set from an earlier
in-VM run. If the namespace supervisor is unavailable, the node skips renewal
and lets its remote routes expire rather than renewing stale claims.

Every node maintains best-effort pinned links to all currently resolvable
remote keys returned by `directory_control_peer/1`; self remains in the
authority set but is not dialled. A host sends its current signed record over
those links. A receiver forwards an accepted third-party record to each active
root control link except the signed author and authenticated immediate source,
only while its own key is a current control peer. Nodes that are not current
control peers send their own record and consume resync, but do not relay
third-party records.

Every receiving node — direct ingress, fanout, or resync — independently
verifies the original signature and checks every carried
`{Namespace, NodeKey}` against its own exact allowlist before mutating any
table. It does not trust a relay's earlier validation. A relayed announcement
is accepted only when the authenticated source key is in the receiver's
current root-derived control-peer set. Root membership grants relay authority,
not authority to author or alter a record. A relay therefore cannot introduce
a non-allowlisted answerer, alter an allowlisted route, or poison that route's
high-water mark; it can only delay, drop, or replay a valid record.

If any namespace in a signed record is not allowed for its `NodeKey`, that
receiver rejects the entire record rather than accepting a partial subset.

Snapshot read access is deliberately separate from advertisement authority.
Any mutually authenticated node may resync these intentionally discoverable
system routes; being able to read a record does not allow that node to publish
one or feed a captured snapshot back into another reader. A receiver ingests a
snapshot page only when its source key, link process and monitor identify the
exact current outbound control link tracked for that peer; a stale or unrelated
link is rejected. Idle-session pruning, bounded pages and bounded records
constrain the public read path. Private direct seeds never enter a snapshot.

The initial implementation is simple bounded fanout plus periodic
renewal/resync, not a new consensus or general gossip subsystem. The
directory tick refreshes the committed root peer set, reconciles currently
known self-advertised endpoints and resyncs every active control link. Pinned opens are
bounded and independent, so an unresolved or stale peer does not prevent
attempts to other peers. Endpoint replacement installs the new exact link
before retiring the old one, and stale open results or process-down messages
cannot remove a newer generation.

Directory messages are advisory.  Loss or temporary disagreement between two
directory views may delay a route or cause `{ontology_unreachable, Namespace}`,
but cannot change agreed state or authorisation at the target.

## 6. Private direct seeds

Direct seeding provides the private-ontology case without a public
registration:

```text
add_direct_seed(PrivateOntology, {Host, Port})
```

This is an authenticated local administration/control-plane operation.  It
creates a provisional local route only; it sends no announcement and appears
in no directory answer.  Its first successful target-channel exchange binds
the route to the peer key that actually served the named ontology. A failed
or mismatched attempt leaves the seed provisional and unavailable. Subsequent use is a pinned
dial to that bound key; only this first confirmation is necessarily
endpoint-only under the local administrator's trust.

That first directory-seed exchange uses the same scoped no-learn link policy
without an expected key: it accepts the mutually authenticated certificate and
matching header key as its TOFU result, records that key only in the private
directory route, and does not publish it into the shared transport address
cache. Pinned and seed-confirmation links share one internal policy mechanism;
they are not duplicate link implementations.

The parent or caller that needs a private ontology currently owns its seed
configuration. Changing a private host is therefore a local control operation;
no global directory change is required.

The planned ontology-subscription facility may cause a subscriber host to keep
following a private target, but it does not make the route durable. The
subscriber ledger records only the target's anchored identity; event interests
remain the subscriber's existing source-qualified `react_on/3` declarations.
An already-configured direct seed supplies runtime
reachability, and the normal authenticated confirmation pins the current host.
Without a reconstructible route the subscription remains durable but inactive.
Endpoints and node routes are never copied into `subscribes/2`. See
`ontology-subscription-plan.md`.

## 7. What remains unchanged

- `peer_admitted` and the consensus committee stay as they are. A directory
  host is not necessarily a validator, and an acting agent instance is not
  thereby a node committee member.
- Consensus, voting, batching, ingress, block format, catch-up and ledger
  storage are untouched.
- The target's normal ask authentication, `can_read`, bounded worker lifetime,
  chain/depth checks and wire-term atom safety remain the final guards.
- Data ontologies have no special treatment.  A content hash, object manifest,
  replica policy or media streaming protocol belongs to the data/storage layer,
  not this route index.

## 8. User-visible flows

### A. Controlled system ontology

1. The operator adds node `K` to the configured allowlist for
   `quod:agent` and deploys it with the already-running root ontology.
2. `K` starts serving `quod:agent` and renews its authenticated directory
   advertisement.
3. Each node derives directory-control identities from committed root
   membership and uses its live transport observations to reach them; no
   directory bootstrap address is configured. Nodes learn the live route. A
   proof using
   `quod:agent::some_goal(...)` opens an ask directly to `K` (or another
   eligible route), without static contacts for that target.
4. Removing `K` from the allowlist or allowing its renewal to expire makes it
   disappear from new lookups.  Existing asks retain their normal independent
   lifecycle.

### B. Private component ontology

1. `body`'s host is configured with a direct seed for `character_42:arm`.
2. The arm never announces itself to the shared directory.
3. `body` selects the arm through its confirmed direct route. A global
   `directory_host(character_42:arm, ...)` query produces no answer.
4. Moving the arm means supplying the current body host with a new seed; no
   platform-wide route transaction occurs. A separate durable subscription
   fact may express that body follows arm state, but contains no seed address.

### C. Stale or hostile information

1. A route expires or a target is down: the resolver tries another candidate;
   if none work, `::` reports `{ontology_unreachable, Namespace}`.
2. An unknown namespace with no direct or directory route reports
   `unknown_ontology`.
3. A node claiming an unapproved system namespace, another node's key, or a
   different endpoint is ignored before it enters the table.
4. Even an accepted route cannot bypass mutual TLS or the target's
   `can_read` rule.

## 9. Tests and acceptance criteria

The implementation must include focused tests for these observable contracts:

1. `directory_host/5` accepts a ground namespace, yields each eligible anchored
   route once through normal Prolog backtracking, and rejects an unbound/bad
   name. The removed `/4` form is not registered.
2. `directory_host/5` and `resolve/1` still succeed while the directory owner
   process is deliberately blocked, proving that the read path does not wait
   on it; both fail closed when its ETS table is gone.
3. A valid system advertisement appears; renewal extends it; expiry removes
   it; an older/equal `{Epoch, Sequence}` update cannot resurrect a
   newer/expired record, including after a sender restart or after the live
   route has expired. The advertised set follows the live namespace registry:
   start adds a system namespace, stop or a missed-notification renewal replaces
   the complete set, an empty set withdraws it, private namespaces do not
   consume the public cap, and control/directory-owner restart reconstructs
   current state rather than a stale set.
4. A peer cannot advertise another node key or a payload endpoint different
   from its authenticated link endpoint. A bad/tampered node-key signature is
   rejected identically at direct ingress, fanout and resync.
5. A non-allowlisted node cannot advertise a system namespace. A key
   allowlisted for namespace `A` also cannot advertise namespace `B`; these
   checks hold identically for direct ingress, fanout and resync, and a
   mixed `A`/`B` signed record is rejected as a whole, without installing `A`.
   A public reader cannot relay a captured announcement or inject a captured
   snapshot; snapshot ingestion requires the exact current outbound root
   control link.
6. A direct seed is local-only, becomes confirmed only after a successful
   target identity exchange pins its node key, genesis anchor, and role, cannot
   be repinned in place, and never appears through `directory_host/5`.
7. Scope routing has the exact local → direct → system order, tries another
   candidate after a transport failure, and distinguishes `unknown_ontology`
   from `ontology_unreachable`.
8. A private ontology cannot be discovered through the shared directory but
   can be reached by its direct seed.
9. All directory/wire decoding is bounded and uses binaries without minting
   atoms; payload, per-announce, per-namespace, table, rate and resync-page
   bounds are each enforced.
10. A relayed endpoint for an allowlisted node is usable only when its
    mutual-TLS identity equals the carried `NodeKey`; a mismatch is discarded
    and cannot yield an answer. In particular, a route `{K, E}` answered by a
    different valid-cert node `K'` is rejected, the resolver advances to its
    next candidate, and the shared address cache is unchanged.
11. With the shared cache preloaded as `K => E0`, a successful pinned
    connection to `{K, E}` whose link header advertises another address leaves
    `K => E0` byte-for-byte unchanged. Private-seed TOFU likewise records its
    learned key only in the directory table. Existing ordinary links still
    auto-learn as before.
12. Directory churn produces no transaction, block, membership change, or
    consensus action.
13. `directory_control_peer/1` is registered as a query predicate, succeeds
    only in a root execution context, and enumerates the distinct exact
    32-byte keys from committed `peer_admitted/4` facts through normal Prolog
    backtracking. A real local `prove_ro/2` call must distinguish a legitimate
    successful-empty result from an absent or failed predicate.
14. Root proof work does not block the control process. A failed, timed-out or
    stale proof retains the last successful peer set; the next successful
    result replaces it exactly. Control opens and process-down handling are
    matched to their exact current endpoint, open reference, link process and
    monitor, so stale generations cannot replace or remove a newer link.
15. After a live committed admission has demonstrably seeded `K => E_old` in
    the shared address cache, an ordinary authenticated root link from the
    same persistent key at `E_new` overwrites it. Directory control then opens
    a pinned link and converges at `E_new` without a directory configuration
    change or a test-only cache write.

Focused EUnit/CT covers the resolver, external predicate and control-plane
codec. Release validation also includes the normal full gate.

## 10. Explicitly deferred follow-up

Self-managed discoverable ontologies require a different authority source:
their own agreed policy must say which keys may advertise hosts, and the
directory must validate a signed/revocable proof of that policy.  That is a
security-sensitive distributed protocol, not a small extension of the system
allowlist.  It includes key rotation, revocation, initial-discovery trust and
bounded proof validation. It must also define **read-answer authority**:
either a verifiable committee/threshold signature over each answer (and its
relevant snapshot), or a rule that only appropriate committee members may
serve reads. An ontology-authorised host alone is not enough: without this, it
can fabricate answers. This protocol should be designed separately before
implementation.

Likewise, user-specific hidden discovery waits for the authenticated-subject
work already identified in `doc/agent-fipa-plan.md`; it must not be faked with
an unauthenticated Prolog argument.

## 11. Implementation map

- `quod_directory`: bounded ETS state, deterministic direct reads, configured
  direct-seed reconstruction, expiry and per-node freshness.
- `quod_directory_auth` / `quod_directory_limits.hrl`: shared exact
  authorisation and namespace bounds.
- `quod_directory_record`: canonical Ed25519 signed record codec.
- `quod_directory_control` / `quod_namespace_manager` / `quod_ns_sup`: live
  hosted-set reconciliation, root-contact endpoint recovery, signed
  withdrawal, asynchronous root-peer discovery, pinned control links,
  authorised fanout and bounded resync.
- `quod_directory_predicates`: root-only `directory_host/5` and
  `directory_control_peer/1`, both with normal Erlog backtracking.
- `quod_safe_term`: bounded, atom-safe, compression-free external-term decode
  for directory, proof-scope, and transport-header inputs.
- `quod_quic` / `quod_conn` / `quod_link`: pinned and identity-discovery
  no-learn transport policy.
- `quod_ask`: local → direct → system resolution and pinned scope request/return links.
