# Network directory

**Status: fact-backed directory implemented through automatic-route-recovery Slice 4; fleet activation is gated on Slice 6.**

## Purpose and ownership

`quod_directory` is one node-local, derived route index. It answers where an
ontology may currently be reached. It is not consensus state, an ACL, an
ontology catalogue, or a service directory. If the process restarts, every row
is reconstructed from signed generations and committed private-contact facts.

Ontologies name other ontologies. They do not store physical endpoints for
ordinary `::` calls. The directory resolves current hosts, and the target's
normal identity and `can_invoke/4` checks still decide whether the call is valid.

## Durable authority

Hosting truth is ordinary committed Prolog data:

- root's `system_ontology(Namespace, Anchor)` catalogue identifies system ontologies;
- a node actor's `hosts_ontology(NodeRef, Namespace, Anchor, discoverable)` authorizes that exact node actor to publish a public route;
- `hosts_ontology(..., private)` keeps local restart intent but is not advertised;
- `knows_ontology_host(NodeRef, Namespace, Anchor, HostNodeRef)` gives only the owning node a private contact. It is never published.

The namespace manager merges root, system, and node-actor projections with
root/system precedence and exact-anchor conflict checks. Only ready local
namespaces enter its hosting snapshot. Configuration supplies root recovery
contacts and node identity only; it contains no ordinary namespace allowlist or
private route insertion API.

## One public wire

Each advertising node signs a complete, sorted generation containing the
author, node key, endpoint, epoch, generation number, page number, final-page
marker, and hosted descriptors. Pages have a byte bound. The number of pages
and hosted ontologies has no fixed limit. A receiver verifies every page,
assembles the complete generation, then atomically replaces that author's prior
rows. Missing, conflicting, stale, or interrupted pages expose nothing.

There is one generation/resynchronization family. The old record, snapshot,
direct-seed, confirmation, and TOFU wire paths do not exist.

## Verification

Signatures bind every field. Root-bootstrap generations are accepted only from
a current root control peer and may contain root plus exact current
system-catalogue rows. A node-actor generation is checked against the existing
certified foreign projection of its ontology: its advertised key must be its
active `agent_key/3`, and every discoverable row must match an exact committed
`hosts_ontology/4` fact. This reuses `quod_foreign_log`; there is no directory
verifier or cache beside it.

Directory rows provide reachability, never authority or quorum weight. Opening
a scope still verifies the target identity and role through the normal target
history path. A plain remote read may use only a certified current validator
route; it remains a single-host answer, not a quorum-certified result.

## Private resolution

A private contact stores the exact `HostNodeRef`, not an endpoint. The local
directory resolves that host actor's current discoverable self-route and derives
the target contact. Moving or restarting the host therefore changes no durable
private fact. If the host actor has no route, work parks on the exact route
property and resumes when the generation arrives.

## Liveness and recovery

Root starts from its existing bootstrap contract. Root facts recover system
ontologies; their ready rows are published. The local node-actor pointer then
recovers the node ontology, whose committed facts recover ordinary hosted
ontologies and public/private route projections. Consumers with no route wait
on exact gproc properties and are woken by directory installation. Deadlines
bound failed operations but do not discover progress.

Leases and signed epochs prevent stale endpoints from living forever. Renewal
is a liveness safeguard. High-water state prevents an older generation from
resurrecting withdrawn rows during the directory process lifetime.

## Acceptance

The coordinated Slice-6 re-found must prove automatic recovery without an
operator namespace list, dynamic creation and withdrawal, host movement,
private omission, paged generations beyond former population limits, complete
restart, subscriptions, and an initially route-empty A -> B -> C -> D call.
Mixed old/new directory wires are unsupported.
