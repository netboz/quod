# Ontology lifecycle and routing

Governed creation accepts ordered `source_file(Path, Sha256)` options as well
as the existing source forms. Policy approves the complete descriptor; ordinary
preparation reads each file once, verifies the exact 32-byte SHA-256 hash, and
compiles those same bytes. A mismatch refuses preparation with
`source_hash_mismatch(Index)` and creates no ontology. The prepared genesis
remains the recovery input; applying or recovering it does not reopen a source
file. This lets an authored recipe pin packaged components without carrying
their complete buffers through every cross-owner proof answer. Paths and hashes
grant no creation, source-read or module authority.

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
An enrolled node signs its complete eligible public set with its verified
node identity. Root's pinned anchor and committed system catalogue authorize
exact system descriptors; ordinary descriptors require the author's exact
committed `hosts_ontology/4` fact with `discoverable` visibility. Neither
system publication nor ordinary publication grants target ACL rights or
committee membership. Before a node identity is available, only a root
control peer may publish the bootstrap/system set. On identity activation it
publishes an empty bootstrap generation and moves those descriptors into its
node-authored generation; lost withdrawals remain bounded by the old lease.

An authenticated directory resync subscribes its incoming stream before taking
the cached snapshot. Current root control peers relay later verified generations
and withdrawals to those consumers. Stream death removes the subscription;
loss of the local root control role retires its downstream interests. Delivery
does not grant the consumer relay authority. Lease ticks renew publications,
not resync requests. A restarted directory owner resets its peer-opened streams
so their sources reconnect and subscribe to the new incarnation.

Current-tip confirmation treats the local physical key as one answerer when
it belongs to the certified committee. Its evidence comes from the existing
owner's immutable committed archive through the shared proof verifier. Local
hosting alone cannot supply a quorum, and the original deadline still applies.

Discoverability is the host's publication choice, not evidence of consent by
the target's owner. A private hosting fact is excluded from public generations,
but global confidentiality across independently authorized hosts requires an
explicit target publication policy.
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
