# Transaction-author signatures

**Status:** implemented 2026-07-18; fresh-ledger deployment pending.

This milestone un-defers transaction-author Ed25519 signatures and
follower-to-leader transaction relay. It does not itself authorize new writers.
Existing unsigned non-genesis history is deliberately incompatible; deployment
requires a clean ledger/CSI restart.

## Invariants

1. Every non-genesis transaction is signed by its `author`.
2. The signature binds the transaction to the validator's own target namespace.
3. Every committed transaction field except `sig` is covered.
4. Signing happens at the local Simplex ingress, which already owns the private
   node key. Prolog never receives the private key.
5. Every receiving validator verifies every transaction before voting for its
   block. The proposing node trusts signatures it just created itself and relay
   signatures already verified over opaque bytes before decode.
6. One invalid transaction rejects the whole proposed block.
7. Live voting, local rebuild, and peer catch-up enforce the same current
   signature rule. A commit certificate proves finality; it does not prove that
   its signers ran the current transaction-validation rules.
8. Only the explicitly anchored slot-1 genesis transaction may be unsigned.
9. A signature authenticates an author; it does not authorize that author.
   Until user/agent capability policy lands, transaction ingress and relay
   remain restricted to currently admitted validator authors.
10. Every author has a signed, monotonically increasing `author_seq`.
    Validators reject a sequence at or below that author's approved history,
    including an uncommitted approved parent. Gaps are legal; reuse is not.

## Canonical bytes

`quod_transaction` owns the only transaction signature format:

```erlang
term_to_binary(
  {quod_transaction, 2,
   TargetNs, TxId, CallerNs, Goal, Result,
   Diff, ReadCheck, Author, AuthorSeq, SubmittedAt},
  [deterministic]).
```

The domain tag and format version prevent cross-protocol reuse and permit an
explicit future format transition. `TargetNs` comes from the validating
committee's context, never from a transaction claim. Deterministic ETF gives
maps such as `ReadCheck` a canonical key order.

`Goal` and `Result` are covered because they are part of the committed audit
record shown by the Explorer. `sig` is the sole excluded field.

## Signing and validation

`quod_prolog` continues to submit an unsigned transaction with
`author = NodePubkey`. The local `quod_simplex` process:

1. requires `author` to equal its own public key and `sig` to be `none`;
2. assigns the next local `author_seq`;
3. signs the canonical bytes using its already-owned identity key;
4. stamps the signature before size accounting, batching, or relay.

Structural validation remains independent of namespace context. It requires a
32-byte author, a 64-byte signature, bounded canonical fields, a valid read
check, and a valid diff. Namespace-aware acceptance additionally requires
`caller_ns =:= TargetNs` and verifies the signature using `TargetNs`.

An exact block hash that was already accepted for the active slot may reuse its
previous validation result when redriven. A different block is always checked.

## Exact replay protection

`tx_id` remains a client-facing correlation id. Replay safety comes from
`author_seq`, not from a time-limited transaction-id cache. Each consensus
process keeps only the greatest committed sequence per author and reconstructs
that projection while streaming the durable ledger at boot.

For a live proposal, the comparison floor includes the committed projection and
the approved parent block when consensus is pipelined. A block may contain
several transactions by one author, but each sequence must be distinct and
strictly above that floor. This prevents the same signed submission from
committing again at any later slot without retaining every historical
transaction id. Rejected submissions may leave gaps and never block progress.

## Genesis and historical validation

Genesis is constructed locally and trusted through the explicitly pinned slot-1
block hash. Its transaction remains `sig = none`. No normal proposal, later log
entry, or generic structural branch accepts an unsigned transaction.

Local rebuild verifies transaction signatures and author-sequence monotonicity
before applying stored entries. Peer catch-up verifies finality evidence before
performing the current transaction-rule recheck, preventing uncertified blocks
from forcing a batch of Ed25519 operations.
These checks intentionally reject a pre-signature ledger even if its old commit
certificates are cryptographically valid.

## Relay wire

Relay carries the exact signed bytes rather than a decoded transaction inside a
safe, namespace-scoped correlation envelope:

```erlang
{submit, Author, Signature, CanonicalTransactionBytes}
```

The receiving leader:

1. enforces the frame and canonical-byte limits;
2. safely decodes the outer envelope, which contains only known atoms and
   binaries;
3. verifies `Signature` over the still-opaque canonical bytes;
4. only then decodes the canonical transaction;
5. requires its namespace and author to match the trusted outer context;
6. re-encodes it and requires byte-for-byte equality.

This prevents unauthenticated content from creating atoms before signature
verification and rejects non-canonical encodings. The authenticated transport
peer must equal `Author`, and that author must be in the current committee.
The inter-ontology ask symbol codec is never used for transaction relay.

Relay uses the existing authenticated `{log, Ns}` links, and it targets the
rotation instead of chasing it: the leader schedule is a pure function of the
slot, so the author computes the first slot its submission can still enter and
sends it ONCE to that slot's leader — pre-positioning it there while the current
slot's consensus is in flight. The receiver PARKS anything arriving at most two
slots ahead of its own turn in its bounded ingress queue and proposes it the
moment its slot opens, answering when consensus decides — the terminal
`relay_result` is the follower's notification, so the follower's
exact-request-id retransmit is a lost-frame backstop only (the link send is
deliberately fire-and-forget under flow-control pressure, so the retransmit
cadence stays tight until links carry backpressure signalling; parked request
ids stay in the receiver's inflight set, so retransmits are idempotent).
Leaders bound in-flight requests and cache completed results for 30 seconds,
and a follower independently resolves its pending relay only when the exact
signed submission commits. Only a genuine misroute — the schedule moved past
the holder — redirects the request back through its author with a concrete
forward-looking hint, up to three hops; a useless hint (a recovering target
answers `none`) is replaced at the origin by a locally recomputed seat, and
`skipped` (retryable) is returned if that seat is the origin itself. During a
membership barrier every arrival parks unconditionally: the post-adoption
schedule is unknowable, so hints minted against the old committee would only
burn the redirect budget. Relay lifetime matches the Prolog parked-proof
lifetime, anchored at the submission's ORIGINAL arrival, so time parked at any
hop counts against the same deadline. A submission whose signed sequence falls
below the committed floor because it lost a routing race resolves
`{error, stale_seq}` — retryable by contract (the origin re-proves and
re-signs), counted apart from malformed input; it is never a terminal
rejection. An author whose burst straddles a target flip can sign consecutive
sequences toward two slots and lose the earlier race — the accepted, retryable
residue of routing without a per-author ordering gate.

## Verification

Tests cover deterministic encoding, map insertion order, mutation of every
signed field, namespace binding, malformed keys/signatures, unsigned live
transactions, mixed valid/invalid batches, genesis-only exemption, restart
rebuild, peer catch-up, the relay envelope round trip, transparent four-node
follower relay, signed Byzantine membership proposals, and leader failure.

Benchmarks measure signing and proposal validation for 1, 64, and 256
transactions, including p50/p95 latency and scheduler impact. Metrics expose
invalid-signature rejection counts and a validation-duration histogram, with
matching Grafana panels and user-facing help text.

## Delivery

Signatures, relay, Explorer authentication details, Prometheus metrics, and
Grafana panels are implemented together. Full tests and benchmarks precede the
commit. Deployment then purges Quod CSI volumes and starts once from fresh
genesis; there is no unsigned-history compatibility mode.
