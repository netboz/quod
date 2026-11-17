# Consensus and certified history

Each ontology runs its own DispersedSimplex committee in `quod_simplex`.
Committee membership comes from committed `peer_admitted` facts. The exact
genesis anchor separates incarnations of the same namespace. No endpoint,
directory record or remote peer chooses this identity for the local owner.

## Signature domain and finality

The immutable consensus domain is
`SHA-256("quod/simplex/domain" || 0x00 || 0x03 || uint32_be(byte_size(Ns)) || Ns || GenesisHash)`.
The node signs support, commit and complaint shares over the domain, era,
share kind, protocol view and block hash. A vote decision is synced by
`quod_signing_journal` before its signature leaves the node. The committee
authorized at the relevant historical slot verifies each certificate;
current membership cannot substitute for that committee.

A support quorum notarizes a block only with its exact parent and required
skipped-view evidence. Commit and complaint decisions exclude each other in
the same view. A complete descendant commit certificate finalizes its
material ancestors along the verified parent chain. Protocol views are not
material ledger heights. Empty recovery carriers add no Prolog entry or
reaction. A membership transaction is the old era's last material block;
the new era starts from its derived virtual root.

Every non-genesis transaction is namespace-bound and signed by its author.
Validators verify it before voting; replay and catch-up verify it again.

## Ownership and recovery

`quod_simplex` is the sole local ledger writer. It installs a verified history
delta before publishing the corresponding state. `quod_catchup` serves bounded
pages from an immutable captured view; the receiver verifies ancestry,
historical committee and transaction signatures before its owner installs
new material. `quod_feed` disseminates live entries and wakes the same
catch-up path for gaps. Replay restores state and does not create a live event.

For an identity hosted locally, the hosted history owner supplies evidence.
For another exact identity, node-wide `quod_foreign_log` retains certified
progress and any demanded material prefix. Sparse exact evidence cannot prove
absence. Published verified views may be borrowed; ordinary requests neither
rebuild nor reverify the old prefix. Recovery or diagnosed corruption has an
explicit owner lifecycle. Network I/O stays outside state-owner mailboxes.

The current code is in `src/quod_simplex.erl`, `src/quod_signing_journal.erl`,
`src/quod_catchup.erl`, `src/quod_feed.erl`, and `src/quod_foreign_log.erl`.
The [archived signature contract](outdated/consensus-signatures.md) records
exact wire bytes; the [archived Simplex specification](outdated/simplex_extended.pdf)
records the ordering protocol. The [old Raft build spec](outdated/ordering-layer-spec.md)
is superseded.
