# Consensus signature domain

This document is the normative contract for DispersedSimplex votes and
certificates in quod.

## Domain

Every namespace process derives one immutable 32-byte domain from trusted local
state:

```text
SHA-256(
  "quod/simplex/domain" || 0x00 || 0x03 ||
  uint32_be(byte_size(Namespace)) || Namespace ||
  GenesisHash
)
```

`GenesisHash` is exactly 32 bytes and is the hash of the canonical slot-1 block.
A founder derives it from its durable slot 1. A fresh joiner uses its configured
pin; a resumed joiner must find that the pin equals its local slot-1 hash before
it restores votes or participates. The domain is never accepted from a peer.

The namespace prevents cross-ontology replay. The genesis hash prevents replay
between fresh incarnations of the same namespace. The lexicographically-smallest
key in the configured founding set is the only node permitted to create slot 1.
It generates a fresh 32-byte nonce and records it both in the versioned genesis
transaction id and as the queryable ontology fact
`consensus_incarnation(Nonce)`. Every other founding member uses `mode=join`
with the resulting `GenesisHash`. Reusing all operator inputs on an empty ledger
therefore produces a different anchor and consensus domain; restarting the same
ledger preserves both.

The genesis transaction id is exactly:

```text
"quod/genesis" || 0x00 || 0x01 ||
uint32_be(byte_size(Namespace)) || Namespace ||
IncarnationNonce
```

The old nonce-less id is invalid. There is no independent multi-creator path
and no compatibility reader.

## Signed bytes

A support, commit, or complaint share signs:

```text
"quod/simplex/share" || 0x00 || 0x03 ||
Domain || Era || KindTag || uint64_be(View) || BlockHash
```

`Domain` and `Era` are each 32 bytes. `View` is a positive protocol position
within that era; it is not a material ledger height. `KindTag` is `S`, `C`, or
`X`. `BlockHash` is exactly 32 bytes for support and commit and empty for
complaint. Certificates contain `{Signer, Signature}` pairs, checked against
the locally derived domain and the committee authorized for the named era.

Support is exclusive per era/view. Commit and complaint exclude each other
within the same era/view; a decision in an earlier view does not prohibit a
later view's decision. Notarization authorizes advancement and a commit vote;
a complaint certificate authorizes advancement without adding a ledger entry.
A descendant's commit certificate finalizes an ancestor only through its full,
verified parent chain. A certificate alone never authorizes an invented parent.

The same domain and ancestry rules govern live consensus, journal restoration,
forward catch-up and foreign-history verification. A received feed entry is a
progress notice; installation obtains its complete proof through shared catch-up.

## Material history and membership

Genesis occupies material height 1 with protocol position `{genesis, 0}`, no
parent and timestamp zero. Later canonical blocks bind their era, view and exact
parent `{Era, View, Hash}`. Empty protocol carriers inherit the parent timestamp
and produce no material entry, Prolog application, reaction or outcome. A real
transaction with an empty diff remains material.

A membership block M is the old era's last material block. Its old-era
children and descendants must be empty carriers. Once M is certified, the new
committee starts at a virtual root `{NewEra, 0, MHash}`. M's original bytes and
hash remain unchanged; different valid old-era finality witnesses derive the
same new root. Historical signatures are checked with their historical
committee, including the old committee certifying M.

The live engine retains the unfinished protocol suffix and the journal retains
unretired signing decisions and supported bodies. There is no fixed two-view
horizon or carrier-count cap. Complete proof-plus-material archive custody
permits retirement; material height alone does not. This archive uses the
existing ledger store and retained indexes, with no separate carrier database.
Ordinary evidence requests use captured views and verified deltas, not history
reconstruction. Portable snapshots and compaction remain deferred.

## Breaking format

The coherent finality cut uses one format throughout:

- canonical block and material entry terms are version 2;
- consensus frames use `sx3`; retained ingress uses `sx_relay2`;
- ledger archive frames use V8 magic `0x915106B1`, storing streamed proof parts
  and their material entries as complete durable groups;
- consensus signature domains and shares are version 3;
- signing journals use QSJ6 and bind decisions to era/view;
- exact material references use `refs3`; retained foreign checkpoints use
  version 6;
- signed transaction envelopes remain version 15, committee-view identities
  remain version 2 and signed directory generations remain version 1.

Superseded formats are explicitly rejected; there is no migration or fallback
reader. Incomplete archive tails and complete corrupt records retain their
separate recovery rules. Journal records are synced before signatures can leave
the node. Selected ancestry and its material group are synced before publication,
outcomes or signing-state retirement.

Deployment requires coordinated stop and re-founding under the release contract
in [the finality plan](finality-round-recovery-plan.md). First validate the full
candidate on an isolated new network and retain the old network's unresolved
operations and evidence. Never submit an uncertain old operation on a new
identity. Both `ledger_dir` and `data_dir` need replacement when they differ;
the current Nomad layout co-locates them in the host volume mounted at
`/quod/data`. That container mount is not the host filesystem path. Compute
volumes and cloud allocation subdirectories belong to the same activation scope.
