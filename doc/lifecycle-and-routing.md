# Ontology lifecycle and routing

`quod:root` is the one ontology pinned in node configuration. When it is
ready, `quod_system_ontology` proves the committed `system_ontology/2`
catalogue and returns exact `{Namespace, GenesisAnchor}` identities.
`quod_namespace_manager` merges that catalogue with committed local
node-actor hosting facts, then starts or joins the desired content and
Brahms children. It restores those children after a dynamic supervisor
restart. A local start request is admission, not a new source of durable
hosting policy.

## Creation and ownership

Ontology creation is an ordinary authorized Prolog action. The source
ontology checks policy, stages the desired transition and, where needed,
uses the existing atomic multi-ontology transaction. A direct lifecycle
effect runs through the existing journal only after ordered apply. Genesis
is bound to its exact source inputs and anchor; a joiner verifies its pin
before participating. The node that executes the effect does not thereby
become the creator or owner. Agent identity, creator provenance, hosting
permission and validator membership are distinct facts and decisions.

The physical node actor has one local bootstrap pointer beside its node key
so the manager can resume that same anchored history. After bootstrap,
committed root and node-actor state governs the desired process set. A
process, cached address or founding source filename is never independent
authorization for a system ontology or host assignment.

## Routes and local notifications

`quod_directory` owns replaceable indexes of live routes learned from signed
node-actor generations and committed private contacts. Addresses are hints;
the exact ontology anchor and authenticated peer key bind the request.
`quod_quic` owns the server and connection pools, while `quod_conn` and
`quod_link` own authenticated framed streams. Consensus traffic receives
priority over bulk transfer. A route change cannot replace a proof,
historical committee or finality certificate.

Owners publish meaningful installed-state changes through `quod_reg`/gproc
or send directly to a known recipient. Consumers subscribe before taking a
snapshot, bind notices to the owner incarnation and wake only affected
work. An unavailable owner or missing route is not repaired inside an
ordinary proof request by recreating state or polling. The caller's
absolute deadline continues through any readiness wait.

Current entry points are `src/quod_namespace_manager.erl`,
`src/quod_system_ontology.erl`, `src/quod_directory.erl`,
`src/quod_quic.erl`, and `src/quod_reg.erl`. The archived
[actor architecture](outdated/ontology-actor-architecture.md) and
[lifecycle plan](outdated/ontology-lifecycle-single-path-plan.md)
record detailed decisions.
