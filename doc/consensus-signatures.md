# Consensus signature domain

This document is the normative contract for DispersedSimplex votes and
certificates in quod.

## Domain

Every namespace process derives one immutable 32-byte domain from trusted local
state:

```text
SHA-256(
  "quod/simplex/domain" || 0x00 || 0x01 ||
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
"quod/simplex/share" || 0x00 || 0x01 ||
Domain ||
KindTag ||
uint64_be(Slot) ||
BlockHash
```

`KindTag` is `S`, `C`, or `X`. `BlockHash` is exactly 32 bytes for support and
commit and empty for complaint. Certificates carry the existing set of
`{Signer, Signature}` pairs; verification always supplies the locally derived
domain and the committee valid for that slot.

The same domain is used by live consensus, vote redrive, certified-block
recovery, forward catch-up (including implicit parent proofs), and feed
verification.

## Live-state bounds

For durable base `H`, the volatile engine accepts blocks and shares only for
`H+1` and `H+2`. The second slot is required by the depth-one pipeline. Far
support certificates are dropped. A valid far commit or complaint certificate
is reduced to one highest-slot scalar recovery hint; its signatures and object
are not retained. The hint is cleared when the base catches up, the engine is
reseated, or the committee changes.

Within the two live slots, the engine retains at most:

- one block per slot; a later quorum-supported block may replace an
  unnotarized first copy;
- one verified block hash per `{kind, slot, signer}`, so a Byzantine signer
  cannot create unbounded share buckets.

Catch-up and durable replay do not use the live two-slot horizon. They verify
arbitrarily long contiguous windows and then reseat the engine at the recovered
head.

## Breaking format

This contract has no compatibility path:

- consensus frames use the `sx2` envelope; the old `sx` envelope is rejected;
- ledger frames use the V3 magic and explicitly reject V1 and V2 — each as its
  own identifiable format at its exact offset — instead of treating either as a
  torn tail;
- the consensus share domain is version 2, so no share, certificate or journal
  entry signed under the V2-ledger domain verifies here;
- committee-view identities are version 2;
- vote journals use QVJ3 records
  `{quod_vote, 2, Domain, Kind, Slot, BlockHash}` and reject QVJ1, QVJ2, or a
  different domain — a journal binds the share domain, so an older one must
  never be restored as equivocation history for a chain that no longer exists;
- signed directory records and bodies are version 2.

Deployment is stop, wipe, and re-found—not a rolling upgrade. Both `ledger_dir`
and `data_dir` must be wiped when they differ; the current Nomad layout
co-locates them on the same host volume mounted inside each allocation at
`/quod/data`. That mount point is not the host filesystem path: delete or wipe
the corresponding Nomad host volume, including cloud allocation subdirectories
when cloud satellites have run.
