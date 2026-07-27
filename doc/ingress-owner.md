# Ingress ownership and signed-submission retargeting

Status: reviewed design; compatibility foundations staged  
Scope: transaction custody and relay; no change to Simplex ordering, voting, or proposer selection

## Why this change exists

The per-ontology 25 ms batch window is the correct current default, but it is
not the final ingress architecture. In the same-fleet N=8 fixed-work A/B,
1,920 writes at 25 ms still produced 405 public `slot_closed` retries. At 2 ms,
the same work produced 2,264 safe retries, 3.36 times as many blocks, and a
3.10 times worse p99 without improving throughput.

Today an exact target-slot closure is returned through Prolog and HTTP, which
causes the client to prove the goal again and Simplex to sign a new
transaction. The replacement retains one exact signed submission and moves
only its unsigned placement metadata to the next earliest usable proposer.

This is an ingress-lifecycle change. It must not create multiple concurrent
proposers, assign work several proposer turns ahead, or weaken the consensus
validation rules.

## Identities

Three identifiers have different jobs and must not be conflated:

- `TxId` is the client/explorer correlation handle carried in the transaction.
- `SubmissionId` identifies the exact signed submission. It is stable across
  every placement and is used to match a committed payload.
- `AttemptId` identifies one placement of that submission. It is a
  version/domain-separated digest of the namespace, `SubmissionId`, committee
  view identity, exact target slot, and target public key. The committee view
  identity includes the adoption revision/anchor as well as the validator set:
  hashing only the members would collide if the same set recurs later.

The authoritative committee identity is derived identically during live commit,
boot replay, and catch-up:

```erlang
sha256(term_to_binary(
  {quod_committee_view, 1, Ns, AdoptionSlot, AdoptionBlockHash,
   lists:sort(NewValidators)}, [deterministic]))
```

The current relay `ReqId` is the `SubmissionId`. Reusing it across target slots
is incorrect: inbound-flight and completed-result caches are keyed only by that
ID, while accepted/result frames do not echo a slot. A delayed or cached result
from an old slot could therefore affect a new placement, especially when
round-robin leadership returns to the same peer.

Version 2 relay messages bind every acknowledgement and result to both logical
and placement identity:

```erlang
{relay_submit_v2, SubmissionId, AttemptId, CommitteeId, TargetSlot,
                  Submission, TraceCarrier}
{relay_accepted_v2, SubmissionId, AttemptId, CommitteeId, TargetSlot}
{relay_result_v2, SubmissionId, AttemptId, CommitteeId, TargetSlot, Result}
```

The receiver derives `SubmissionId` from the bounded opaque submission envelope
and derives `AttemptId` from that ID plus the bounded outer placement fields. It
validates the exact committee view, verifies the author signature over the
still-opaque canonical bytes, and only then decodes and namespace/author-binds
the transaction. Attempt/result caches use `AttemptId`; commit matching uses
`SubmissionId`. During compatibility, all cache keys are protocol tagged
(`{v1, SubmissionId}` or `{v2, AttemptId}`), so a coincident 16-byte v1 and v2
identifier cannot alias.

## Safety invariants

1. **Sign once.** Retargeting never changes canonical transaction bytes,
   signature, `TxId`, `author_seq`, `read_check`, or submission timestamp.
2. **One active attempt.** An origin has at most one live placement for a
   `SubmissionId`. Destinations never forward or retarget it.
3. **Authoritative exclusion.** The origin retargets only after its own
   Simplex view finalizes the target slot without the `SubmissionId`. A peer
   rejection is a wake-up/catch-up hint, not proof that the slot is closed.
4. **Exact ownership.** Simplex remains authoritative for proposer identity,
   slot openness, committee state, sequence floors, membership barriers, and
   finality. It revalidates every ingress offer.
5. **Per-author order.** One FIFO lane preserves signed author sequence order.
   A later sequence cannot overtake an unresolved earlier sequence.
6. **Membership is global.** A pending or in-flight committee change remains a
   global ingress barrier. After adoption, routing uses the newly committed
   committee and stops if the author is no longer admitted.
7. **Local apply defines success.** Remote `committed` is only a hint. The
   caller succeeds after the local durable log and deterministic Prolog apply
   resolve the exact submission.
8. **Ambiguity stays visible.** Expiry or process loss while an attempt may
   still commit returns `outcome_unknown`; it is never converted to a safe
   retry.
9. **Retargetable is narrow.** Locally confirmed `bad_change`, `stale_seq`,
   authorization loss, and OCC conflict are not retargeted. They require
   terminal handling or a new proof. The same label received from a peer is
   only a hint until the origin independently confirms it.
10. **Bounds do not reset.** Queue, byte, per-author, and lifetime limits are
    anchored at the original arrival. Retargeting cannot extend them.

Unsigned queue expiry may remain retryable `busy`, because no signed submission
exists yet. Once custody is created, expiry is ambiguous and uses the original
`outcome_unknown` identity.

With an honest quorum, an attempted slot eventually either contains the
submission or finalizes without it. The origin then advances the same signed
submission to the earliest usable seat. A lying or silent target cannot wedge
this loop because local finality, not its reply, drives progress.

## Final ownership split

The final target is one `quod_ingress` process per namespace owning the complete
ingress contract:

- unsigned local requests and signing;
- sequence allocation and the per-author FIFO;
- exact signed-submission custody and original deadlines;
- inbound signature verification and relay deduplication;
- placement attempts, acknowledgements, redrives, and results;
- bounded pending/completed caches;
- membership barriers and batch collection;
- internal retargeting after authoritative slot exclusion.

`quod_simplex` keeps:

- the durable ledger and vote journal;
- active committee/frontier/barrier truth;
- exact-slot offer revalidation;
- proposal ordering, batching acceptance, voting, certificates, and finality;
- ordered slot-finalization notifications to ingress.

Relay v2 uses a separate authenticated `{ingress, Ns}` transport channel.
Consensus proposals, shares, and certificates remain on `{log, Ns}`. This
removes relay submits, duplicates, acknowledgements, and results from the
serial consensus mailbox instead of merely forwarding them through it.

Ingress and Simplex must share an explicit incarnation contract. Every route
view carries a fresh Simplex incarnation token and monotonic version. After a
Simplex restart, ingress pauses new placement; a fresh route view alone is not
enough. Every attempt accepted under the previous incarnation remains
ambiguous until local catch-up/finality classifies its exact target slot.

A candidate supervision layout puts ingress before the ordering/projection
subtree under `rest_for_one`, so an ingress crash also restarts local consensus.
That deliberately trades availability for a single local custody incarnation,
but it does not erase an old remote attempt. It also cannot promise that an
in-flight HTTP caller receives a typed `outcome_unknown`: the call may terminate
with a transport/process failure. The only safe guarantee is that this
ambiguity is never advertised as retryable. Before extraction, this layout must
be fault-injected and compared with a shared-incarnation alternative; untrusted
relay frame decoding must remain isolated so malformed input cannot routinely
bounce the consensus subtree.

This milestone does not add a pending-submission WAL. Durable reconnect still
requires a stable client operation ID and committed/pending lookup.

Author-sequence reuse across an ingress restart is a hard gate before process
extraction. The preferred bounded mechanism is a small durable high-water
lease, atomically persisted and synced per `{namespace, identity}` before any
sequence from it is signed. Gaps are already legal, so a restart can discard
the unused suffix without reusing a sequence that an old remote attempt may
still commit.

## Staged delivery

### Stage 1 — relay-v2 compatibility foundation

- Add stable `SubmissionId`, committee-view identity, and slot-bound
  `AttemptId`.
- Decode and serve relay v1 and v2 with bounded, attempt-scoped v2 caches.
- Add separate `relay_protocol = v1 | v2` and `ingress_retarget` gates, both
  defaulting to the old behavior. Reject `ingress_retarget = true` unless
  `relay_protocol = v2`.
- Match every v2 acknowledgement/result against peer, `SubmissionId`,
  `AttemptId`, committee identity, and exact slot.
- Deploy the compatible binary fleet-wide while continuing to emit v1 and
  keeping retained custody disabled.

This stage changes no placement, ordering, or caller semantics.

### Stage 2 — activate v2, then retained custody in the current Simplex owner

After every validator is known to decode v2, switch emission to v2 while
retargeting remains disabled. Once v1 attempts have drained and v2 operation is
observed:

- Retain locally signed submissions, caller, per-author position, and original
  deadline in one custody record.
- Make collecting batches, local proposals, and outbound relays reference that
  record rather than independently owning the caller.
- Resolve custody by `SubmissionId` on every locally committed payload.
- On local finalization without inclusion, mark the same signed submission
  eligible for reconsideration. `finalize/2` currently runs before
  `adopt_committee/2`, so it must not route there: revalidation and drain occur
  only after committee adoption, the committed sequence floor update, and
  completion of the current `drain_commits/1` contiguous durable prefix.
- Recheck every excluded member of a partially included author cohort against
  the new author-sequence floor before requeueing it.
- Choose the next earliest usable seat from the post-commit committee view.
- Treat an early target rejection as a hint and wait for local finality before
  retargeting. Remote `bad_change`, `stale_seq`, and even `{ok, Slot}` are result
  hints; local durable inclusion/exclusion and local revalidation resolve the
  caller.
- Export internal retarget count and hop histograms.

This removes public retry amplification while changing only one process's state
model. It provides a testable semantic boundary before process and transport
extraction. The first behavioral slice retains ordinary content writes only;
committee-changing transactions preserve the old terminal skip/re-proof
contract until membership-verdict skip loops have a separately reviewed rule.

There is no timeout-based downgrade from v2 to v1. A timeout is ambiguous and
must not create a second protocol attempt for the same placement.

Rollback is also staged: disable retargeting, let every retained custody record
resolve or expire, switch emission back to v1, and drain outstanding v2
attempts plus the result-cache TTL before installing a binary that cannot
decode v2.

### Stage 3 — isolate pure ingress state

- Move custody/routing transitions into a pure ingress state module without
  changing process ownership.
- Add a cached, versioned Simplex route view.

### Stage 4 — sequence durability and process extraction

- Land the durable, synced author-sequence high-water lease.
- Move the pure state into `quod_ingress`.
- Add incarnation-aware restart classification and fault-inject the selected
  supervision layout.

### Stage 5 — migrate the transport channel

- Make old and new binaries dual-subscribe to `{log, Ns}` and `{ingress, Ns}`.
- Activate v2 relay emission on `{ingress, Ns}` only after fleet compatibility.
- Drain old-channel relay attempts and caches before dropping the old
  subscription.

This is a separate rolling protocol change from process extraction.

### Stage 6 — sealed-batch interface

- Send one sealed, revalidated batch offer to Simplex rather than one statem
  event per incoming transaction.

Cached status/committee/stats reads are a useful independent mailbox reduction,
but they are not the redirect fix. Consensus sharding is deferred until ingress
traffic has been removed and the remaining statem mailbox is remeasured.

## Verification

Correctness tests must cover:

- unchanged signed bytes across multiple target slots;
- identical committee identity from live adoption, boot replay, and catch-up,
  plus a distinct identity when the same validator set is adopted later;
- delayed old-slot acknowledgement/result after retarget;
- leadership returning to the same peer within the result-cache TTL;
- duplicate delivery of the same attempt;
- partial inclusion of a per-author cohort;
- a target lying, racing, or remaining silent;
- membership adoption and author removal;
- Simplex restart before offer, after offer, and after durable commit but before
  ingress notification;
- destination restart before and after accepted acknowledgement;
- original deadline and caller `outcome_unknown`;
- v1/v2 mixed-binary and mixed-feature matrices;
- one ledger occurrence of each retained signed submission in the honest
  ingress workload;
- no overtaking across blocks in an honest per-author ingress lane.

Global `TxId` uniqueness is not currently a consensus invariant: replay
protection is based on signed author sequence and submission identity.
Likewise, consensus currently accepts distinct above-floor sequences in either
order within one batch. Stronger global assertions require a separate
validation-rule change.

The fixed-work acceptance run remains 1,920 writes at 25 ms:

- 1,920 commits, zero unknown outcomes, zero failures;
- tries per operation at most 1.02, target 1.00;
- no public slot-closed retries; internal retargets are measured separately;
- p99 no worse than 562 ms, target below 450 ms;
- no increase in skips, progress timeouts, round p99, or relay redrives;
- retarget-hop p99 at most two and lifetime bounded by original arrival.

After process/channel extraction, no relay frame may enter the consensus
statem. Its mailbox p99 should fall by at least 80 percent under the burst
workload, with no node reaching the former approximately 1,000-message bucket.
Only if a subsequent 2x offered-load test still leaves consensus mailbox p99
above 100 while round latency degrades should per-slot consensus sharding be
reconsidered.
