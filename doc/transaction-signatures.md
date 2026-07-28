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

The relay frame keeps routing outside the signed transaction bytes:

```erlang
{relay_submit, SubmissionId, AttemptId, CommitteeId, TargetSlot,
               SubmitEnvelope, TraceCarrier}
{relay_accepted, SubmissionId, AttemptId, CommitteeId, TargetSlot}
{relay_result, SubmissionId, AttemptId, CommitteeId, TargetSlot, Result}
```

`SubmissionId` identifies the exact signed envelope. `AttemptId` binds that
submission to the namespace, committee identity, target slot, and target
validator. `TargetSlot` is a positive 64-bit placement value; changing any
placement field creates a different attempt without changing the authenticated
transaction content.

The receiving proposer:

1. enforces the frame and canonical-byte limits;
2. safely decodes the outer envelope, which contains only known atoms and
   binaries;
3. verifies `Signature` over the still-opaque canonical bytes;
4. only then decodes the canonical transaction;
5. requires its namespace and author to match the trusted outer context;
6. re-encodes it and requires byte-for-byte equality.

This prevents unauthenticated content from creating atoms before signature
verification and rejects non-canonical encodings. The authenticated transport
peer must equal `Author`. First admission also requires that author and the
declared target belong to the declared current committee view. Exact duplicate,
cached, and durable-recovery lookups retain their originally admitted metadata,
so a later committee transition cannot change an old attempt's meaning. The
inter-ontology ask symbol codec is never used for transaction relay.

Every relay submit, accepted acknowledgement, and result uses the dedicated
deterministic `term_to_binary({ingress, Ns}, [deterministic])` channel.
Consensus uses `{log, Ns}` exclusively. The receiver rejects a relay envelope
on the consensus channel and a consensus envelope on the ingress channel;
there is no fallback path.

The two channels are separate authenticated QUIC streams on the same per-peer
connection. They still share that connection's congestion window, but a bounded
ordered-send failure resets only the ingress stream and cannot tear down the
consensus stream. The sender retains every pending submission and reconstructs
the complete author-ordered prefix when the ingress stream reconnects.

The sender computes the first slot the submission can still enter and includes
that exact target slot in the relay frame. The receiver verifies that it is the
deterministic proposer for the declared slot. It may collect the request or
park it until that slot opens, but it never derives a replacement destination
from its own frontier.

While an unresolved target slot remains usable, later submissions from the
same author reuse that destination and slot. If the slot finalizes, matching
submissions resolve successfully. An excluded ordinary submission remains in
origin custody and becomes eligible for a new placement only after the origin
has durably applied the whole finalized prefix and adopted any committee
change. Queued later sequences remain behind it. Membership-changing
submissions keep their terminal skip/re-proof rule. This preserves signed
sequence order without exposing slot closure as an ordinary caller retry.

Once a destination holds the request, it sends `relay_accepted`. Before that
acknowledgement the author retransmits the exact request every 300 ms to recover
a lost or reset ingress stream. After acknowledgement it probes only every 5
seconds to recover a lost result hint, avoiding request amplification during a
slow commit. Attempt IDs remain in the receiver's inflight set, so both kinds of
retransmit are idempotent. Destinations cache completed results for 30 seconds.
After restart, a destination with the durable target slot—including a former
proposer now serving as an observer—can reconstruct inclusion or proven
exclusion for a current committee source. A removed source with no exact live
attempt is rejected before signature verification, cache access, or a ledger
read; its own durable prefix resolves the retained caller.

Destination results are authenticated hints, not finality evidence. The author
resolves its pending relay only from its own durable log: inclusion succeeds,
while target-slot finalization without an ordinary submission retires that
attempt and places the exact retained signed bytes at the next usable proposer.
A local caller deadline cannot cancel a transaction that may already be
proposed: it returns `{error, {outcome_unknown, TxId}}`. That transaction id
must be inspected in the ledger/explorer; automatically re-proving a
non-idempotent goal is unsafe.

During an in-flight membership barrier every arrival parks unconditionally:
the post-adoption schedule is unknowable. A membership change waiting for the
approved parent to commit is also a global queue barrier; ordinary writes may
not continually pass it and starve the committee transition. Other queue
blocking is per-author, so capacity pressure from one author does not prevent
another author's transaction from filling an open batch. Relay lifetime is
anchored at the submission's original arrival, so time parked at any hop counts
against the same budget. Its one-second cleanup margin outlives the Prolog caller
deadline only to absorb a racing relay result hint; it does not turn an unknown
caller outcome into a safe retry.
A locally confirmed submission whose signed sequence falls below the approved
floor resolves `{error, stale_seq}` and requires a new proof/signature; it is
counted apart from malformed input. The same label from a destination is only
a hint and cannot release origin custody. Normal operation prevents this race:
retained submissions and their unresolved relay attempts form one ordered
source lane, so a later sequence cannot overtake an earlier one.

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
