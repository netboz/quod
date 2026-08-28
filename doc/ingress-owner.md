# Ingress ownership and signed-submission retargeting

Status: Stage 1 and the first Stage 2 pure-state extraction slice are committed
Scope: transaction custody and relay; no change to Simplex ordering, voting, or proposer selection

## Why this change exists

The per-ontology 25 ms batch window is the correct current default, but it is
not the final ingress architecture. In the same-fleet N=8 fixed-work A/B,
1,920 writes at 25 ms still produced 405 public `slot_closed` retries. At 2 ms,
the same work produced 2,264 safe retries, 3.36 times as many blocks, and a
3.10 times worse p99 without improving throughput.

Before this milestone, an exact target-slot closure was returned through Prolog
and HTTP, causing the client to prove the goal again and Simplex to sign a new
transaction. The implemented replacement retains one exact signed submission
and moves only its placement metadata to the next earliest usable proposer.

This is an ingress-lifecycle change. It must not create multiple concurrent
proposers, assign work several proposer turns ahead, or weaken the consensus
validation rules.

## Identities

Three identifiers have different jobs and must not be conflated:

- `TxId` is the client/explorer correlation handle carried in the transaction.
- `SubmissionId` identifies the exact signed submission. It is stable across
  every placement and is used to match a committed payload.
- `AttemptId` identifies one placement of that submission. It is a
  domain-separated digest of the namespace, `SubmissionId`, committee
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

The definitive relay protocol binds every acknowledgement and result to both
logical and placement identity:

```erlang
{relay_submit, SubmissionId, AttemptId, CommitteeId, TargetSlot,
               Submission, TraceCarrier}
{relay_accepted, SubmissionId, AttemptId, CommitteeId, TargetSlot}
{relay_result, SubmissionId, AttemptId, CommitteeId, TargetSlot, Result}
```

The receiver derives `SubmissionId` from the bounded opaque submission envelope
and derives `AttemptId` from that ID plus the bounded outer placement fields. It
validates the exact committee view, verifies the author signature over the
still-opaque canonical bytes, and only then decodes and namespace/author-binds
the transaction. Attempt/result caches use `AttemptId`; commit matching uses
`SubmissionId`. Each inflight/cache value also retains the complete
peer/identity/view/slot reference and is write-once: a same-key,
different-context collision fails closed.

Current committee-view equality gates only the first admission of an attempt.
An exact inflight duplicate or cached result admitted under an older view is
still answered from its stored context after membership advances. Likewise, an
origin matches a late response against the stored attempt, not its current
committee view.

Relay transport capability is narrower than cache lifetime. A current
committee peer or a peer named by an exact live pending/inflight attempt may
use the ingress channel; a removed peer with no live attempt is rejected before
signature verification, cache access, or a ledger read. Its origin-side durable
log remains the authority for resolving retained custody, so no stateless
former-member query is needed.

Every relay submit, accepted acknowledgement, and result uses the deterministic
authenticated channel `term_to_binary({ingress, Ns}, [deterministic])`.
Consensus proposals, shares, certificates, block requests, and readiness use
only `{log, Ns}`. Neither channel accepts the other channel's envelope; there is
no fallback relay path on the consensus channel.

## Safety invariants

1. **Sign once.** Retargeting never changes canonical transaction bytes,
   signature, `TxId`, `author_seq`, `read_check`, or submission timestamp.
2. **One active attempt.** An origin has at most one live placement for a
   `SubmissionId`. Destinations never forward or retarget it.
3. **Authoritative exclusion.** The origin retargets only after its own
   Simplex view finalizes the target slot without the `SubmissionId`. A peer
   rejection is a wake-up/catch-up hint, not proof that the slot is closed.
4. **Exact ownership.** Simplex remains authoritative for proposer identity,
   slot openness, committee state, sequence floors, consensus barriers
   (membership and DTX controls), and finality. It revalidates every ingress
   offer.
5. **Per-author order.** One FIFO lane preserves signed author sequence order.
   A later sequence cannot overtake an unresolved earlier sequence.
6. **Membership is global.** A pending or in-flight committee change remains a
   global ingress barrier. After adoption, routing uses the newly committed
   committee. If the custody author is no longer admitted, the already-issued
   signed submission remains ambiguous until its original deadline; it is
   neither redirected nor mislabeled as malformed.
7. **Local apply defines success.** Remote `committed` is only a hint. The
   caller succeeds after the local durable log and deterministic Prolog apply
   resolve the exact submission.
8. **Ambiguity stays visible.** Expiry or process loss while an attempt may
   still commit returns `outcome_unknown`; it is never converted to a safe
   retry.
9. **Retargetable is narrow.** Pre-custody `bad_change`, locally confirmed
   `stale_seq`, and OCC conflict are not retargeted. After custody exists, a
   changed capability or authorization view cannot prove that the exact prior
   attempt failed; it remains ambiguous. Any label received from a peer is only
   a hint until the origin independently confirms the outcome.
10. **Bounds do not reset.** Queue, byte, per-author, and lifetime limits are
    anchored at the original arrival. Retargeting cannot extend them.
11. **Transport roles are disjoint.** Ordered relay delivery may reset only its
    `{ingress, Ns}` stream. It cannot tear down the `{log, Ns}` consensus
    stream or retire that stream's readiness generation. Replacing a live
    inbound generation never waits in the namespace statem: the old stream is
    closed asynchronously and remains monitor-tombstoned until `DOWN`, so a
    queued old-generation frame cannot reclaim ownership.

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
- consensus barriers (membership and DTX controls) and batch collection;
- internal retargeting after authoritative slot exclusion.

`quod_simplex` keeps:

- the durable ledger and vote journal;
- active committee/frontier/barrier truth;
- exact-slot offer revalidation;
- proposal ordering, batching acceptance, voting, certificates, and finality;
- ordered slot-finalization notifications to ingress.

The transport split is already definitive: relay submits, acknowledgements,
and results use their own authenticated `{ingress, Ns}` QUIC stream, while
consensus remains on `{log, Ns}`. Both streams currently share the same
per-peer QUIC connection and congestion window, but resetting an ordered relay
stream cannot reset or discard the peer's consensus stream.

This stream split does not yet remove relay work from the serial Simplex
mailbox. The same `quod_simplex` process subscribes to both channels and owns
both state machines. Moving relay decoding and custody out of that mailbox is
the Stage 3 process extraction below.

Ingress and Simplex must share an explicit incarnation contract. Every route
view carries a fresh Simplex incarnation token and monotonic revision. After a
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

### Stage 1 — definitive attempt relay and retained custody

- Use the single attempt-scoped relay contract.
- Add stable `SubmissionId`, committee-view identity, and slot-bound
  `AttemptId`, with bounded write-once attempt caches.
- Match every acknowledgement/result against peer, `SubmissionId`,
  `AttemptId`, committee identity, and exact slot.
- Retain and internally retarget ordinary content writes unconditionally. This
  is the only protocol behavior.
- Export `committee_id`. The fixed-work preflight requires the whole committee
  to report the same identity before offering a write.
- Retain locally signed submissions, caller, per-author position, and original
  deadline in one custody record.
- Make collecting batches, local proposals, and outbound relays reference that
  record rather than independently owning the caller.
- Resolve custody by `SubmissionId` on every locally committed payload.
- On local finalization without inclusion, mark the same signed submission
  eligible for reconsideration. `finalize/2` currently runs before
  `adopt_history/2`, so it must not route there: revalidation and drain occur
  only after committee adoption, the committed sequence floor update, and
  completion of the current `drain_commits/1` contiguous durable prefix.
- Recheck every excluded member of a partially included author cohort against
  the new author-sequence floor before requeueing it.
- Choose the next earliest usable seat from the post-commit committee view.
- Treat an early target rejection as a hint and wait for local finality before
  retargeting. Remote `bad_change`, `stale_seq`, and even `{ok, Slot}` are result
  hints; local durable inclusion/exclusion and local revalidation resolve the
  caller.
- Keep source relay submissions solely in the retained-attempt map, not the
  generic consensus outbox. Link-up reconstructs the complete prefix once in
  author-sequence order; no timer polls or resends live work.
- Carry every submit, accepted acknowledgement, and result only on the
  deterministic `{ingress, Ns}` channel. `{log, Ns}` is consensus-only and has
  no relay fallback.
- An ordered relay send retries local QUIC backpressure in link-mailbox order.
  If it cannot enter the stream within the bound, it resets that stream so no
  queued suffix can pass the missing prefix. The dedicated relay stream keeps
  that reset independent of the peer's consensus stream.
- Recovery invalidates future-slot result cache entries and resets only inbound
  streams whose discarded relay state requires a full-prefix replay. Queued
  frames from the dead generation fail the live-generation gate.
- Export internal retarget count and hop histograms.

This removes public retry amplification while changing only one process's state
model. It provides a testable semantic boundary before process extraction. The
first behavioral slice retains ordinary content writes only;
committee-changing transactions are deliberately non-custodied and retain a
terminal skip/re-proof rule until membership-verdict skip loops have a
separately reviewed rule.

The in-process slice resets and waits for every tracked relay stream during a
graceful Simplex termination, and reseat resets the affected inbound
generations. An untrappable process/VM kill can bypass that callback and remains
an incarnation-bound ambiguity until Stage 3; it must never be surfaced as a
retryable exclusion. The durable author-sequence lease below is still required
before custody moves into a separately supervised process.

### Stage 2 — isolate pure ingress state

- Move custody/routing transitions into a pure ingress state module without
  changing process ownership.
- Add a cached canonical Simplex route view keyed by a complete source token.

### Stage 3 — sequence durability and process extraction

- Land the durable, synced author-sequence high-water lease.
- Move the pure state into `quod_ingress`.
- Add incarnation-aware restart classification and fault-inject the selected
  supervision layout.

### Stage 4 — sealed-batch interface

- Send one sealed, revalidated batch offer to Simplex rather than one statem
  event per incoming transaction.

Cached status/committee/stats reads are a useful independent mailbox reduction,
but they are not the redirect fix. Consensus sharding is deferred until ingress
traffic has been removed and the remaining statem mailbox is remeasured.

## API that should emerge

There should be one write path, not an old item API beside a new batch API.
The current `quod_simplex:append/2` remains internal only until the process
split is ready; it is then replaced outright.

The application-facing owner is:

```erlang
quod_ingress:submit(Ns, UnsignedTransaction) ->
    {ok, Slot}
  | {error, retry, busy | stale_seq}
  | {error, rejected, bad_change | skipped}
  | {error, not_in_charge, Node | unavailable}
  | {error, outcome_unknown, SubmissionId}.
```

`quod_prolog` is the sole production caller. HTTP maps these typed outcomes to
responses; it does not reinterpret remote relay hints as caller results.
`outcome_unknown` is resolved by the exact signed-submission identity. The
committed-ledger/Explorer lookup must expose that identity before this API
replaces the current call path. A pending-status API must wait for a durable
ingress index; an in-memory answer would be unsafe across restart.

Simplex publishes two ordered inputs to ingress:

```erlang
quod_ingress:route_view(
  Ns, Incarnation, Revision,
  #{capability := accept | hold | reject,
    committee_id := CommitteeId,
    validators := Validators,
    committed := Committed,
    approved := Approved,
    proposal_slot := blocked | {open, Slot, Proposer},
    consensus_barrier := boolean(),
    approved_author_seqs := error | {ok, map()}}).

quod_ingress:finalized(
  Ns, Incarnation, Slot, CommitteeId, IncludedSubmissionIds).
```

The route view answers where work may go; the finalization stream is the only
authority that resolves inclusion or exclusion. Ingress ignores a view from an
older incarnation and pauses placement across an incarnation change until
catch-up supplies a current view.

Ingress sends Simplex one ordering command:

```erlang
quod_simplex:offer_batch(
  Ns, Incarnation, CommitteeId, ExactSlot, SignedSubmissions).
```

The offer is sealed: Simplex either accepts that exact batch for that exact
slot or rejects the whole offer. There is no per-item ordering alternative.
Simplex still revalidates namespace, author, signature, sequence floor,
committee barrier, count, and byte bounds before proposing.

Metrics follow ownership. Ingress reports queue, custody, relay, retarget, and
submission-latency metrics. Simplex reports proposal, vote, round, batch, and
finality metrics. The old metric names are deleted when ownership moves.

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
- nonblocking live consensus and relay generation replacement while the old
  process ignores close, including a queued frame from that retired process;
- a real ingress ordered-send failure resetting only that stream;
- a real four-validator commit with every tracked ingress direction down;
- future-slot result-cache invalidation and full-prefix replay after reseat;
- original deadline and caller `outcome_unknown`;
- both admit and remove membership changes bypassing retained custody;
- event-driven retained-custody wake-up for malformed committee view, exact
  duplicate attempt, and lane conflict, with no compiled custody or relay
  population threshold;
- fail-closed rejection of non-definitive relay shapes;
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
- no increase in skips, progress timeouts, round p99, or exact relay duplicates;
- retarget-hop p99 at most two and lifetime bounded by original arrival.

The channel split is complete, but relay frames still enter the same
`quod_simplex` statem through its separate subscription. After Stage 3 process
extraction, no relay frame may enter the consensus statem. Its mailbox p99
should fall by at least 80 percent under the burst workload, with no node
reaching the former approximately 1,000-message bucket.
Only if a subsequent 2x offered-load test still leaves consensus mailbox p99
above 100 while round latency degrades should per-slot consensus sharding be
reconsidered.
