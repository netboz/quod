# Notes for GPT

A running handoff log between the two AI collaborators on quod: **Claude (Fable)**, who
reviews and operates, and **GPT (Codex)**, who authors much of the implementation. Newest
entry first. These are operational/status notes and cross-review findings — design decisions
still live in the normative `doc/*.md` set and in Yan's memory.

---

## 2026-07-28 — first Stage-2 ingress extraction slice reviewed and committed

The pure routing snapshot, placement planner, bounded parked queue, accounting,
and drain fingerprints now live in `quod_ingress_state`; `quod_simplex`
executes effects and remains authoritative for ordering, voting, finality,
custody, and relay ownership. Shared batch limits moved to one header. This is
a coherent extraction boundary, not the complete Stage 2 process split.

The same pass removed several measured hot-path costs: same-author parked
bursts no longer rescan the queue quadratically; internal drain stability
compares routing state rather than queue depth; validator tuple/set
canonicalization is reused; duplicate transaction IDs validate in O(n);
membership and author-sequence classification have one source of truth; the
approved-parent sequence floor reuses the batch cache; and action assembly
uses one reverse accumulator without concatenation.

The implementation landed in `adef79d`; release `0.7.46` carries it. Claude's
read-only review found no blocker or should-fix and declared the slice safe to
commit. Exact-tree gates were EUnit 509/509, focused ingress/Simplex EUnit
171/171, Common Test 47/47, production compile clean, Dialyzer clean, xref
clean, and `git diff --check` clean.

## 2026-07-28 — definitive ingress relay stream reviewed and committed

All relay submits, accepted acknowledgements, and results now use the
deterministic `{ingress, Ns}` QUIC stream. `{log, Ns}` accepts consensus
envelopes only, `{ingress, Ns}` accepts the bounded relay grammar only, and
there is no cross-channel fallback. The streams share the existing per-peer
QUIC connection and congestion window, but an ordered-send timeout resets only
the relay stream. It can no longer discard proposals, shares, certificates, or
readiness on the consensus stream. Send-drop telemetry classifies only exact
deterministic channel identities as `log` or `ingress`; all non-Simplex or
malformed identities retain visibility under one bounded `other` label.

Relay link-up reconstructs the complete retained author prefix. Recovery and
link-generation replacement close only affected inbound relay streams, leaving
consensus generations and readiness intact. Live inbound replacement is
nonblocking: the superseded process stays monitor-tombstoned until `DOWN`, so
its queued frames cannot reclaim the current generation. Synchronous close
waits exist only after the statem has entered `terminate/3`. Relay still runs
inside `quod_simplex`: both channel subscriptions feed the same statem mailbox.
The later Stage-3 owner extraction, not this transport split, removes relay
work from that serial process. The Stage-3 durable
incarnation/author-sequence lease also remains required for an untrappable
process or VM kill.

Ingress capability is bounded to current committee peers and exact live
pending/inflight peers. Removed sources do not receive a stateless durable
lookup path; their origin-side durable prefix resolves retained custody. The
sole `custody_ready` index stays O(1) on unrelated mailbox events, and whole
lane retirement rebuilds it once in a single bounded pass. Duplicate same-pid
`link_up` notifications are idempotent on both consensus and relay channels.
A temporary placement refusal restores the exact ready key and seals the
current drain pass instead of retrying forever in one callback. View, lane,
author-floor, and relay-pending-count changes wake a later retry. The relay
peer allowlist is built directly as a map union over committee, pending, and
inflight ownership: no concatenated peer lists or sort.

Claude's final re-review found one reachable lifecycle mislabel: after the
origin was removed from the committee, retained custody was released as
`bad_change`. Both current-capability and current-view rejection now preserve
the already-issued signed submission until its original deadline; there is no
redirect, retry, or malformed-workload counter, and the public result remains
`outcome_unknown`. The adjacent deep-recovery wake now includes the O(1)
presence bit for `Tree[Approved]`. Committee pruning and recovery invalidation
also have end-to-end tests proving nonblocking retirement, stale-generation
rejection, and monitor-`DOWN` tombstone cleanup.

This is one channel contract, with no configuration switch or alternate wire
path. The implementation landed in `3442f70`; release `0.7.45` carries it.
Exact-tree gates are green: EUnit
494/494, Common Test 47/47, Dialyzer clean, xref clean, script syntax clean,
dashboard JSON valid, and `git diff --check` clean. Focused evidence includes
real QUIC same-connection reset isolation, a self-contained four-validator
commit with every tracked ingress direction down, nonblocking stale-generation
replacement, both membership-change directions, and bounded refusal/wake
tests. Claude's final read-only review found no blocker, should-fix, or test
gap and declared the tree safe to commit.

## 2026-07-27 — retained custody implemented

Ordinary content writes now enter bounded origin custody immediately after
signing. Slot exclusion retires only the placement: after the origin durably
applies the finalized prefix and adopts any committee change, it places the
same signed submission at the next earliest usable proposer. The caller sees
neither a slot-closure retry nor a newly signed transaction. Membership changes
remain the deliberately terminal re-proof class.

The source keeps one ordered author prefix outside the generic consensus
outbox. Link-up and redrive reconstruct that full prefix in author-sequence
order. Ordered link sends either enter their dedicated relay stream in mailbox
order or reset it, so a later sequence cannot pass a locally dropped
predecessor. Recovery resets only affected relay generations, removes
future-slot result cache entries, and rejects queued frames from retired link
processes. Graceful Simplex termination closes tracked links; an untrappable
process/VM kill still requires the Stage-3 durable incarnation/sequence lease
and is never reported as safely retryable.

A full test-tree audit removed false-green assumptions from the loopback suites.
Dead-leader submissions must now survive the complaint skip and all return
success. Ordinary-write polling retries only `rebuilding` and confirmed OCC
conflict; `skipped`, `retry`, `not_leader`, overload, and ambiguity fail the
test. The over-f suite also captures the interrupted caller and permits only
success or typed `outcome_unknown`. Membership, observer, Byzantine proposal,
destination-hint, and manually constructed non-custodied cleanup assertions
remain intentionally distinct. The obsolete `slot_closed` retry metric label
was removed; membership re-proof is reported as `membership_skipped`.

The retained-custody baseline gates were EUnit 475/475, Common Test 45/45,
Dialyzer clean, and xref clean. The later relay-stream delta is recorded in the
newer entry above.

## 2026-07-27 — attempt-scoped relay safety foundation

The relay now has one definitive wire contract, binding every attempt to its
`SubmissionId`, `AttemptId`, `CommitteeId`, exact target slot, and target
validator. Retired short forms and protocol-selection configuration were
removed. Remote replies are hints only: inclusion, exclusion, catch-up, and
reseating resolve callers exclusively from the origin's durable log.

Destinations reconstruct completed attempts from the exact durable target slot,
including after restart or demotion. The authenticated peer must equal the
signed author, and the opaque signature is verified before any result-cache
prune/lookup, inflight lookup, durable read, reply, or cache insertion. Invalid
signatures leave the original state unchanged. Canonical decoding remains
behind current membership/view/target gates for safe new admission.

Committee identity binds the adoption slot, exact adoption-block hash, and
sorted validator set. The lexicographically first founding key is now the sole
slot-1 writer; it records a fresh random `consensus_incarnation/1` fact and the
other founding members join its pinned anchor. Thus a wipe + re-found creates a
new consensus domain, while recurring validator sets at later adoption slots
retain distinct committee identities.

Independent review found consensus ordering, voting, quorum, certificates, and
proposer selection untouched. Post-review gates are green: EUnit 472/472,
relay-path Common Test 16/16, Dialyzer, and xref; the complete 45-case Common
Test suite was green immediately before the final ordering fix. This release is
the safety/recovery prerequisite for retained-custody retargeting; it does not
yet eliminate public redirects. Retained custody is the unconditional next
behavior.

## 2026-07-27 — same-fleet 25 ms vs 2 ms batch-window A/B

Codex reran the fixed-work benchmark against the same aged N=8 local-compute
committee, changing only `batch_window_ms` through a one-at-a-time Nomad rollout.
Each leg offered 1,920 logical writes as six waves of 40 concurrent requests to
each of eight validators, used a fresh predicate, and committed every operation
with zero `202 outcome_unknown` responses or failures.

At 25 ms, 1,920 writes needed 2,325 HTTP attempts (405 safe retries) and 140
blocks, or 13.7 transactions per block. End-to-end latency was
p50/p90/p95/p99/max 194/377/448/562/670 ms and the makespan rate was
73.94 successful responses/s. At 2 ms, the same work needed 4,184 attempts
(2,264 safe retries) and 470 blocks, or 4.1 transactions per block. Latency
rose to 363/1,147/1,404/1,740/2,012 ms while makespan throughput was effectively
flat at 72.74 responses/s. The shorter window therefore created 3.36x as many
blocks, 5.59x as many retries, and a 3.10x p99 without buying throughput.

The test began at height 19,163, so both legs used the same fleet lineage and
nearby ledger age; this removes the fresh-N=8 versus aged-N=9 caveat from the
earlier load-test comparison. After the A/B, the cluster was rolled back to
25 ms and independently verified 8/8 healthy, converged at height 19,773, with
all eight exported batch-window gauges equal to 25.

The result strengthens the next milestone: retain and retarget one signed
transaction inside a single per-namespace ingress owner when its exact target
slot closes. Do not lower the batch window, fan one operation to multiple
proposers, or assign work to a future proposer turn; those alternatives either
amplify slot chasing or manufacture empty skipped slots.

## 2026-07-26 — exact-slot relay and batching window live A/B complete

Claude's read-only review found no safety/liveness blocker. Its hot-path finding was
valid: `relay_lane/2` copied up to 2,048 pending entries on route-key checks. It now reads
one map iterator entry without allocating the values list. Route-key reuse removes a
second hot computation, its maintenance contract is explicit, and a non-vacuous test
forces the drain's second pass after the first pass seals a block. Grafana's old
misroute wording was corrected. The live cloud allocation also verified TCP reachability
to Tempo at `192.168.1.11:4318`.

The review's pre-existing "8–31 second" timeout account mixed the public synchronous
`quod_simplex:append/2` helper with the normal asynchronous Prolog write path. The actual
caller deadline is 30 seconds there, but the underlying ambiguity is real: a deadline
cannot cancel a transaction that may already be proposed. Both APIs now report an
anchored `{outcome_unknown, {transaction, Ns, GenesisAnchor, TxId}}` instead of a
false failure; HTTP returns `202 pending`, and
automatic test retry is restricted to explicit `409`/`503` responses that say the write
did not apply. A transport failure or timeout is unknown and is never resubmitted. The
load-test HTTP deadline now derives from the deployed, configurable
`transaction_ttl_ms` rather
than assuming 30 seconds. Durable transparent retry still requires a stable client
operation id and persistent lookup, tracked in `doc/deferred.md`.

The exact-seat deployment below improved throughput but still produced about 8,000
redirects and a 2.5-second p99 because sender and receiver frontiers selected different
moving leaders. A rank-sharded stable-custodian replacement was implemented, then rejected
before deployment: the four-node suite showed that assigning a request to a later proposer
manufactures empty skipped slots before that proposer gets its turn.

The replacement keeps the earliest usable slot and makes it explicit in the definitive relay
frame: `{relay_submit, SubmissionId, AttemptId, CommitteeId, TargetSlot, Submission, Trace}`.
A receiver accepts only a slot it proposes, parks only until that exact slot, and never
recomputes a redirect from its own frontier. Later local sequences reuse an open relay lane;
origin-local finality resolves matching requests and safely releases the rest so the queue can
move to the new frontier. Accepted acknowledgements still suppress the 300 ms resend loop.

Lane creation now enforces the single-target/single-slot invariant consumed by the O(1)
route check, and a direct Prolog test proves that a late commit after `outcome_unknown`
applies normally without replying to the reaped caller. Focused `quod_simplex_tests` are
green (120/0), `quod_relay_tests` are green (2/0), and all seven four-node
`simplex_SUITE` scenarios pass. Full local gates are also green: EUnit 445/0, Common Test
45/45, Dialyzer, and xref. The Nomad OTLP endpoint was already parameterized and is
reachable from the cloud allocation; no endpoint change was needed.

The fixed-work live comparison is now complete. Against the same 960 offered operations,
the exact-slot version committed 443 first attempts at p50/p99 40/142 ms; its parent
committed 137 at 118/237 ms while most misses waited about 30 seconds. The rewrite is a
clear improvement. A second controlled run isolated the remaining tail: with the old 2 ms
batch window, 720 committed operations needed 1,349 HTTP attempts and every operation over
1.5 seconds had been proved/submitted six or seven times. Changing only the window to
25 ms reduced that to 840 attempts and p50/p95/p99/max to about
151/298/337/385 ms (from 224/593/1546/1911 ms). The implementation now makes this a
bounded per-ontology setting, exports batch-size/wait and retry-cause metrics, and adds
matching Grafana panels. The next architecture milestone is still to retain and retarget
one signed transaction internally after a slot closes, eliminating client re-proving.

---

## 2026-07-26 — exact-seat ingress A/B: more throughput, redirect tail remains

Branch `codex/ingress-simplification` replaced speculative pre-positioning with one
compute-then-execute router, exact first-usable-seat routing, accepted relay
acknowledgements (300 ms retry before receipt, 5 s result recovery afterward), a
work-conserving per-author drain, retryable redirect exhaustion, and opt-in detailed
consensus probes. Local gates were green before deployment (EUnit 439, CT 45, Dialyzer,
xref).

The live N=9 no-churn saturation run stayed functionally clean in both modes: all nodes
reconverged, with no bad append, queue overflow/expiry, unverified block, transport drop,
restart, or allocation failure. Detailed probes ON: +914 blocks, transaction
p50/p90/p99 about 0.62/1.78/2.44s, append mailbox p99 about 612, round approve/commit p99
about 263/82ms, roughly 6,300 redirects and 1,465 relay redrives in the two-minute query
window. Probes OFF: +1,124 blocks, transaction p50/p90/p99 about
0.44/1.91/2.46s, round p99 about 125/46ms, roughly 8,000 redirects and 2,073 redrives.
The probes cost useful throughput and stay off by default, but they are not the
2.5-second tail.

A successful sampled trace gives the safe, single-clock decomposition: Prolog proof
13ms; submitting node's append/relay span 1.23s; wrong target's rejection handler 0.16ms;
correct leader's queue/propose/final reply 191ms (154 changes in that block). Raw
timestamps across nodes are not used as latency arithmetic. Result: moving-leader chase
and its shared consensus mailbox remain the next architecture problem. Preserve the
single router/order/security contracts if ingress is extracted. This closed-loop run
correctly refuted fsync, signature checks, and a lower fixed Delta, but its conclusion
about batching was later superseded by the fixed-work experiment in the newest entry.

Deployment cleanup found alongside the test: release metadata and Nomad's default still
said 0.7.24 while relx/image was 0.7.41, and the cloud allocation could not resolve
`tempo-otlp.service.consul`. The worktree aligns application/Nomad versions and makes the
OTLP endpoint an explicit routable Nomad variable; those edits are not in the measured
0.7.41 image yet. On 2026-07-26 the running `quod-cloud` allocation directly verified
TCP reachability to the default `192.168.1.11:4318` endpoint.

---

## 2026-07-24 (final) — ROOT CAUSE: Ceph RBD fsync 40-106ms x 3-5 mandatory syncs/round

`dd oflag=dsync` on the production CSI volume, in-container: **p50 40ms / p90 64 / max
106ms per 4KB sync**. Every vote journal-datasyncs before its signature leaves (the
0.7.24 no-equivocation journal); every commit fsyncs the ledger. That is the whole
~300-600ms round and the ~900ms lone write. All local repros ran on NVMe/tmpfs — the
storage backend was the single unreplicated production ingredient. Probe lineage:
0.7.34 event/mailbox/share-lag histograms (broadcast-bearing handlers slow, queues pile
behind them) -> 0.7.35 step timers (support 148ms + persist 134ms p50, all else µs) ->
quota/otel/signing refuted by direct test -> dd. The first Tempo trace had shown
86/237/122ms sync spans; they were wrongly dismissed against the journal-sync histogram,
whose mass turns out to be deduped no-op record calls, not real syncs. Fix directions
(Yan to choose; Architect+DA before implementation): ledger to local disk (chain is
replicated; catch-up covers loss), vote-journal sync batching (1/slot) or local-disk
with fenced reschedules, and/or Ceph-side tuning. Fleet runs 0.7.35 with all probes
live and healthy.

---

## 2026-07-24 (later) — frame-loss diagnosis REFUTED by the 0.7.30 drop counter; state of truth

The probe (commits `468ac74`+`bfb162b`, 0.7.30 deployed, identical load, PASS):
**`quod_link_send_drops_total` = 0** over the whole run. No frames are discarded at the
QUIC send gate. The transport-reliability milestone proposed below is CANCELLED.

Two further artifacts in my own analysis, corrected for the record:
- The "committed-frontier spread 14-18 slots" was a SCRAPE-STALENESS artifact: Prometheus
  scrapes every 15s; at ~1.4 blocks/s that alone fabricates apparent spreads up to ~21
  slots with random per-target phase — including the "smooth gradient". Cross-node gauge
  comparisons at one instant are INVALID at this scrape cadence. (Same-snapshot
  differences remain valid: committed−applied = 0 per node stands.)
- "~100 watchdog fires / ~130 skips per 4min" summed per-node counters for CLUSTER-WIDE
  events → 10× inflated. Real: ~13 skips/~400 slots (3%), ~1 progress timeout per node
  per 24s. Proposal share is uniform (9.2-10.4%). Consensus machinery looks HEALTHY.

**What is solid now (all single-clock or counter-rate):** honest e2e p50 1.34s / p99
4.9s; ~1.4 blocks/s under the burst load; leader-side span queued→commit ≈ 550-740ms
per block (single-node span duration, trustworthy); zero transport drops; apply instant;
fair rotation; few skips. **The open question is now sharply posed: why does one
propose→commit round take ~550ms on a ~1ms LAN when every component measured so far
(fsync ~50µs, sig verify ~25µs, transport clean) accounts for single-digit ms?** A
burst of 40 txs drains at ~4.8 txs/block, so at ~550ms/block the median burst tx waits
~1.3s — the p50 is fully explained by the round time; nothing else is missing. Next
probe (pending Yan): single-node round-phase histograms on the leader (propose→approved,
approved→committed) to localize the ~550ms, before ANY design work. Candidate suspects
once localized: timer-paced steps (TICK 300ms), QUIC-lib internals (ack-delay, pacing,
congestion window), readiness gating, scheduler latency. Lesson standing: measure, then
conclude — three artifacts (clock-skew metric, scrape-staleness spread, per-node counter
summing) each produced a confident wrong diagnosis.

---

## 2026-07-24 — [DIAGNOSIS REFUTED by 0.7.30 — see entry above] frame loss on live links (honest metric, 0.7.29)

**The old latency metric was broken** — `BlockTs − submitted_at` compared the proposer's
wall clock (ratcheted to the fleet max) against the author's; every prior number (225 /
460 / 437 ms) was clock-skew arithmetic. 0.7.29 (commits `6d91650` + `3aee2ae`, deployed)
measures at the SUBMITTING node on one monotonic clock, submit → committed-and-applied
locally, one sample per write.

**Honest baseline (identical load, PASS, +407 slots): p50 1338ms, p90 2320, p99 4900.**
The real client experience is ~4-10× worse than any prior figure suggested.

**Decomposition (measured, not guessed):**
- committed−applied gap during load = **0 slots on all 10 nodes** → the KB/apply layer is
  instant; NOT the bottleneck.
- committed-frontier spread during load = **14-18 slots** → nodes learn commits LATE.
- blocks/s ≈ 1.4 on a ~1ms LAN where a commit round should take ~10ms; progress_timeouts
  ≈ 100/4min = the Δ=1000ms watchdog constantly recovering something.

**Diagnosis: consensus frames DROP on live links under load** — `quod_link`'s plain send
deliberately ignores `quic:send_data` flow-control returns (frames drop silently on a LIVE
link; documented, accepted). Under burst load every recovery is timer-paced: Δ=1000ms
proposal/vote redrive, 300ms relay retransmit, 500ms block-request retry. The block
cadence and the frontier spread are paced by RECOVERY TIMERS, not by the network. This is
the SAME deferred.md item the DA flagged during the ingress review ("Link backpressure
signalling") — it is not a nice-to-have, it IS the latency floor. It also explains why
pre-positioning misses (frontier spread ≫ horizon 2) and why the busiest hosts (corin:
registry+Tempo+3 allocs) lag most: a busy BEAM reads sockets slowly → flow-control
pressure → more drops.

**Direction (Yan to approve): transport reliability BEFORE any more consensus-layer work.**
The link already has an unused bounded in-link retry (`send_until_accepted` in
quod_link's `send_reliable`); consensus/relay frames need either that or backpressure
signalling to the sender. Gossip-mempool (CometBFT-style tx flooding — researched, right
long-term shape) fixes routing hops (~ms), NOT the seconds; it moves to second place.
Sequence: fix frame loss → re-measure honest baseline → THEN judge mempool/tenure/pipeline
against a floor that reflects the network instead of the timers.

---

## 2026-07-23 — future-leader pre-positioning experiment

> **Historical, superseded 2026-07-26.** This section records the deployed 0.7.28
> experiment and its measurements; it no longer describes current ingress behavior.
> `?INGRESS_HORIZON` and the pre-positioning metric were removed on
> `codex/ingress-simplification`. See `doc/transaction-signatures.md` for the
> normative exact-seat routing and relay-acknowledgement flow.

**Why.** The live A/B of the park-queue ingress (0.7.27 vs 0.7.25, identical load) met its
stated goal — busy 2061→0 — but REGRESSED the point: p50 225→460ms, p99 896→2497ms,
blocks/s 1.8→0.98, 3243 forwards (~3 hops/tx; traces show park→drain→relay→redirect
loops over 2.6s). Root cause: all routing targeted the leader of the CURRENTLY open slot —
a target that moves every slot — so txs chased the rotation while leaders opened their
slots with empty queues. The fleet was rolled back to 0.7.25 pending this fix.

**What changed (design Architect+DA-reviewed, 2× approve-with-changes, before impl).**
`leader/2` is a pure function of the slot, so the author now computes the FIRST slot a
change can still enter (`Floor = approved+1`, or `Floor+1` once Floor's proposal is
visible) and relays ONCE to that slot's leader — pre-positioning during the current slot's
consensus. The receiver parks anything within `?INGRESS_HORIZON = 2` slots of its turn and
proposes it the moment its slot opens; only a genuine misroute redirects (concrete
forward hint, never `none`; a useless hint is rescued at the origin by a recomputed seat,
or `skipped` if the origin now leads). Membership barrier ⇒ unconditional park (post-
adoption schedule unknowable). TTL 5s→7s (re-derived: H slots where one may burn a full
Δ×(1+rearms) complaint cycle, still under the 8s caller timeout). Local egress serializes
through the FIFO when the queue is live (narrows the multi-target seq race; the residue is
`stale_seq`, now counted as `r_stale`/`append_stale`, NEVER `r_bad` — that mis-bucketing
is what failed the 0.7.27 loadtest with 57 false "malformed" appends). `park_ingress` arms
head demand constructively (the pre-positioned park is the one cause with no head evidence
of its own). New gauge `ingress_prepositioned`; `ingress_forwarded` is now a MISROUTE
signal (≈0 steady-state expected). The deferred compute-then-execute router refactor was
done FIRST: one pure `route/4` decision (park/collect/relay/redirect/reject), previewed by
the drain and executed by `execute/7` — `drain_dispatchable`'s hand-mirror and the drain's
no-progress backstop are gone by construction. Holder-to-holder forwarding stays illegal.
This historical design was later replaced by the definitive attempt-scoped relay contract.

**Leader tenure explicitly NOT taken**: `(Slot div K) rem N` keeps a dead leader for up to
K complaint rounds and touches everything that reads `leader/2`; pre-positioning gets the
batching win with rotation-as-failover intact. Accepted residue (measured next): a small
straggler tail (boundary flights), modest r_stale, bounded origin-bounce under sustained
overload (budget 3; r_busy/overflow stays THE overload alarm).

**LIVE MEASUREMENT (0.7.28, deployed, identical load — PARTIAL WIN, root cause found).**
loadtest PASS restored (append_bad 0 — the stale-bucket fix worked). busy 0, overflow 0,
expired 0. blocks/s recovered 0.98→1.44-1.8, throughput 86 tx/s, forwarded down
3243→2207. Median trace = ONE hop (pre-positioning works when frontiers align). BUT p50
437ms (0.7.25's 225 was a measurement artifact — it timed only the lucky retry after 55%
busy; 0.7.28 times first-submit-to-commit honestly) and prepositioned landed only 459 vs
~5000 bounces (redirect 2830 + forwarded 2207). ROOT CAUSE: the `approved` frontier
spreads **~18 slots across the fleet under load** (smooth gradient, lag 0..18, not a couple
of laggards) while `?INGRESS_HORIZON = 2`. An origin targets `leader(its_approved+1)`, but
its `approved` lags the true frontier by up to 18, so the target lands outside the
receiver's horizon → redirect → bounce. Pre-positioning is sound but fights a SYMPTOM; the
disease is block-commit propagation lag (the ~18-slot gradient = the real latency floor,
~1 block interval per tx). Next lever is the frontier spread / block cadence (#3 tenure,
#5 deeper pipeline), which would ALSO make the horizon-2 pre-positioning land — the levers
compound. 0.7.28 is a net improvement over both 0.7.25 and 0.7.27 and is safe to keep
deployed; it does NOT by itself restore a sub-250ms honest p50.

---

## 2026-07-23 — event-driven consensus ingress (park, don't reject); awaiting live measurement

**Why.** The 0.7.25 tracing measurement showed the write path pacing itself on its own
rejection-retry loop: 55% of burst appends rejected `busy`, retries quantized by the 300ms
relay retransmit, leadership rotating away between attempts — 3.1-tx blocks at p50 225ms
while fsync/crypto cost microseconds.

**What changed (design Architect+DA-reviewed before implementation).** Appends that cannot
enter a block RIGHT NOW park in a bounded FIFO ingress queue (512 items / 512 KiB / 64 per
author / 5s TTL) and drain event-driven from `keep_progress` the moment the pipeline opens —
into the next batch (multi-item drains seal immediately: block N+1 carries what arrived
during block N) or forwarded once to the rotated leader. Origin-park keeps an item home when
the current slot's proposal is already visible (1 hop instead of the 3-hop bounce — a
relayed submission is only accepted from its author, so holder→holder forwarding is
illegal). `busy` now means ONLY queue overflow or TTL expiry — an alertable signal (dashboard
panel 115 + 4 new `ingress_*` gauges). New retryable `{error, stale_seq}` for writes that
lose a multi-hop routing race (quod_prolog maps it to `{error, retry}`); redirect budget 1→3;
relay deadlines anchored at ORIGINAL arrival so park time counts against the caller's 30s
envelope; the 300ms retransmit stays (quod_link's send is fire-and-forget under flow
control — see the new deferred.md link-backpressure item — so it remains the loss recovery).

**Regression found by the new burst CT and fixed.** A leader latched into a final-vote camp
for its own in-flight slot stopped redriving the proposal; with the lossy link send the lost
frame was never re-sent and a burst wedged with zero support votes. The Δ path now always
redrives after the camp decision (`latched_leader_still_redrives_proposal_test` pins it).

**Gates green** (eunit 415, CT 45 incl. `burst_commits_without_busy` asserting ZERO busy
under a 40-wide burst, dialyzer, xref). Self-review only past the design stage — the
independent review agents died on a spend cap; findings applied: relayed-path oversize gate,
invariant-test coverage for all four park causes, size-accounting unified
(`signed_size`/`item_bytes`), stale comments and a dead TEST export removed. Uncommitted;
next = commit + 0.7.26 + the before/after load measurement.

---

## 2026-07-22 — 0.7.24 load/chaos validation and harness accounting repair

**Full campaign.** A 600-second public-HTTP load run started at slot 6183 and settled every one of the
ten nodes at slot 6722 (+539 blocks). It exercised follower-to-leader relay, bursts of 20 submissions per
validator, five single-validator restarts, and one four-validator (>f) restart wave. There were no
unverified drops, failed/lost allocations, membership rejects, weak-cert waits, lingering recovery, or
validator lag after settlement. The four-node wave returned before the 15-second monitor could observe a
flat height, so it is correctly recorded as an *unobserved* over-f event rather than a duplicate proof of
the controlled outage test above.

**Harness correction.** That first campaign initially printed FAIL solely because `task_restarts` included
the nine restarts deliberately requested by the churn driver. `scripts/loadtest.sh` now counts planned
allocation restarts and fails only when Nomad reports an additional, unplanned task restart; it still flags
failed/lost allocations. A 75-second restart smoke test passed with `2 new (2 planned, 0 unplanned)` task
restarts, full reconvergence at 6830, and no safety-counter movement.

**Append-rejection monitoring.** `append_bad` is now baselined per allocation and tracked through process
resets, so the well-formed load workload fails if it creates a new malformed/disallowed append. A final
45-second no-churn smoke test passed at slot 6930 (+100 blocks), with `append bad (new): 0`, zero
unverified drops, zero restarts, and all ten validators at the head. Existing `busy` and `redirect`
counters are expected under concurrent all-validator ingress: the former is bounded pipeline backpressure,
the latter is normal leader routing/relay.

---

## 2026-07-22 — 0.7.24 deployed and mixed-camp recovery validated live

**What shipped.** `5960464` "Harden consensus recovery finality" followed by `bdb2066` "Bump release to
0.7.24". Built and pushed `192.168.1.11:5000/quod:0.7.24`
(`sha256:a96c0d68c5fea7b8bae89a00bb8bf60a93233dd2900af50231a3830d67bcb67e`). The checked Nomad plan
changed only the container image from `0.7.23` to `0.7.24`; it used the live pinned anchor
`0bc99fb4b6bc30b318d14257bdf7c3ee469dd4b213b783ee49de0850f3889719`, so it remained join mode and did
not alter CSI volumes. Deployment `dbb0dde4`, Job Version 40, completed with all 8 compute and 2 cloud
allocations healthy.

**Preserved wedge resolved.** Immediately after the rolling restart, every validator converged from the
preserved mixed-camp state to slot/approved/committed `6181`; no live final-vote latch or missing-certified
block remained.

**Controlled `>f` validation: PASS.** `scripts/overf-recovery-test.sh` began at H=6181, kept the H+1
leader up, SIGKILLed four compute validators (6 live < quorum 7), and submitted `overf_probe(734030)`.
The survivors held the head and paused complaints as intended (`quorum_pauses` peak 22). After recovery the
interrupted slot committed at 6182 with zero new skips; `overf_probe(734030)` was present. A fresh
`overf_continue(1734030)` transaction then committed, and all ten nodes settled at slot 6183 with
`syncing=0`, `prolog_ready=true`, no complaint latch, no missing certified block, and no weak-cert wait.
A post-roll sweep of every allocation's recent logs found no warning, error, or critical records.

---

## 2026-07-22 — slot 6180 mixed-camp recovery rewrite reviewed; live validation pending

The later live outage disproved the narrow 0.7.20 conclusion below. Two over-f restart waves left slot
6180 notarized with fewer than quorum validators eligible for commit and fewer than quorum latched for
complaint; readiness was 100%, but readiness did not describe final-vote eligibility. Restart also erased
RAM-only vote latches, allowing honest nodes to sign complaint before the crash and commit afterward.

The current branch rewrites that boundary around three invariants: every first support, commit, or complaint
vote is journaled and synced before network visibility; one final-vote decision table covers both live
pipeline slots and makes an unlatched validator follow `f+1` visible peer complaints even after
notarization; and a node with a support certificate but no block rotates one point-to-point request at a
time through certificate signers and then other committee members, verifying any response before ingestion.
Live proposals and recovered blocks also share one timestamp and payload admission predicate after their
distinct position/certificate checks. Full proposals and KB state are not copied to disk.

Claude's read-only review found the load-bearing safety argument sound and no commit blocker. Its useful
cleanup findings were folded in rather than deferred: the split final-vote sites became the decision table
above, child-slot complaint evidence no longer waits for the parent, and tests now use the real vote journal
for both final camps plus a complete amplified-complaint -> skip -> next-slot-commit path. The controlled
outage script now treats either commit or evidence-driven skip as a valid interrupted-slot outcome and
requires a fresh transaction afterward to prove liveness. The final local gate is green: 401 EUnit tests,
all 44 Common Test cases (including the real four-node QUIC suite), Dialyzer, xref, and the production
release build. The remaining honest boundary is an already-formed mutually hidden final-vote split, which
needs a real view-change protocol, plus total loss of every in-flight block holder after a commit camp has
formed. The Nomad fleet has deliberately not been changed yet; live validation is the next milestone after
commit.

**Pre-deploy forensic snapshot (2026-07-22).** A read-only `quod_simplex:stats/1` call on the four
preserved slot-6180 stayers confirmed the mixed camp before any restart erased it. All four reported
`slot=6179`, `approved=6181`, `progress_slot=6180`, `progress_phase_code=3`,
`progress_quorum_ready=1`, and `syncing=0`. Allocations `bc3ead12` and `22ccb8c9` reported
`head_complaint_signed=1`; `3e3413d6` and `9ee16eb2` reported `head_complaint_signed=0`. Thus the cluster
was fully connected and ready while honest validators remained durably divided over the unfinished head,
exactly matching the recovery rewrite's diagnosis. The deployed build did not yet export the new per-camp
vote-count gauges, so this direct process snapshot is the surviving pre-roll evidence.

---

## 2026-07-19 — 0.7.20 deployed (recovery readiness gate) + chaos test

**What shipped.** `79cb1e7` "Bind Simplex recovery to voting readiness" — reviewed by Claude
and found **safe to commit + deploy**. Then the owed release bump landed as `22ad569`
"Bump release to 0.7.20" (only the three version files: `rebar.config`, `src/quod.app.src`,
`deploy/quod.nomad`; `scripts/loadtest.sh` + untracked `assets/`/palette PDF left out of scope).

**Deploy status.** Built `quod:0.7.20`, pushed to `192.168.1.11:5000`, rolled out with
`nomad job plan` (confirmed *only* the image tag changed) then a check-indexed
`nomad job run`. **Job Version 36, deployment successful**, all 8 `quod-node` + 2 `quod-cloud`
healthy. The new `quod_consensus_progress_quorum_ready` metric is present and the old
`quod_consensus_progress_quorum_connected` is gone — positive proof 0.7.20 is the running code.

**The 0.7.20 bump commit is done.** GPT's earlier attempt reported it "not authorized / not
landed"; it is now committed cleanly as `22ad569` and deployed. No further version action owed.

**⚠ Genesis anchor correction.** The live anchor is
`0bc99fb4b6bc30b318d14257bdf7c3ee469dd4b213b783ee49de0850f3889719` — **NOT** the older
`F246DA06…7ACF` that several notes/memories carried. The 0.7.17 signature/block-format change
re-founded the fleet with the new anchor. For any join deploy, read it live rather than trusting
a doc:

```
nomad alloc fs <quod-node-alloc> quod/local/quod.conf | grep genesis
```

A wrong/empty `-var genesis_hash` fails fast (by design), so this bites a deploy immediately.

**Chaos test: PASS, with one honest caveat.** `scripts/loadtest.sh OVERF=1 DURATION=600` against
the live fleet (SCALE=0). qengho is a **test cluster**, so the deliberate validator kills are
in-scope. Result at N=10, f=3:

- reconverged: **yes** — all 10 settled at slot 3741, lag 0
- ledger advanced: **+3028** (floor 150)
- unverified drops (safety): **0** throughout
- failed/lost allocs: **0**; validators at head: **10/10**; committee stable at **10**
- weak_cert_waits: **0**; worst height spread during chaos: 35

**Caveat — the genuine over-f (4-node) stall never fired.** Every time the driver rolled an
over-f event it *deferred*, because the committee was mid-catch-up under the heavy write load
("committee not fully caught up … deferring"). So this run validated safety + under-f churn
recovery + heavy-load liveness, but did **not** exercise live the specific
over-f → stall → recover → commit path that `79cb1e7` fixes. That path is green in CT
(`over_fault_restart_recovers`) and eunit, but to prove it **live**, run a controlled manual >f
outage against a *quiescent, caught-up* committee (take 4 validators down with a pending write,
bring them back, confirm the retained slot **commits** rather than complaint-skipping as slot 713
did pre-fix). The loadtest's own over-f can't reliably force this — it self-defers under load.

**Controlled >f outage validator (`scripts/overf-recovery-test.sh`) — RAN, VERDICT PASS ✅.** New sibling to
`loadtest.sh` that reproduces the slot-713 incident on a *quiescent, caught-up* committee (what the loadtest
can't force — it self-defers over-f under load). Keeps the H+1 leader up, SIGKILLs f+1 compute validators
(6<7 quorum), submits one write via `POST /api/prove` INTO the outage, watches `quod_consensus_quorum_pauses`
climb while the slot holds, then asserts the retained slot **commits with `quod_consensus_skips` flat**.
Live run 2026-07-19 @ H=3742: pause precondition **observed (peak quorum_pauses=16)**, **net skips=0**,
retained slot **committed at 3743**, fact present → **PASS**. This is the exact incident reproduced and
confirmed fixed by 79cb1e7. Two gotchas baked into the script (learned the hard way): (1) SIGKILL the
victims, not graceful `nomad alloc restart` (which drains slowly, leaving them up + voting); (2) submit the
write only AFTER all victims are confirmed down (STEP 1b), else it commits at full quorum before the outage
opens and the run is inconclusive. Rerun: `NOMAD_ADDR=http://192.168.1.10:4646 bash scripts/overf-recovery-test.sh`.

**Current script contract (2026-07-22).** The paragraph above records the historical 0.7.20 run. With
durable final-vote latches, a recovered interrupted slot may now correctly commit or correctly skip,
depending on which evidence camp formed before the outage. The script no longer treats the skip counter as
a failure signal: it identifies the outcome, then requires a second fresh write to commit after
reconvergence. That continuation is the decisive liveness assertion.

**Deploy mechanics reminders.**
- Bump `image_tag` to force a redeploy — Nomad dedupes an unchanged tag string (re-pushing a fixed
  image under the same tag does nothing).
- Routine upgrade is non-destructive: `nomad job plan` should show *only* the image tag changing;
  never pass `-var bootstrap=true` on an anchored fleet.
- `/metrics` is the Nomad health check — a metric that crashes at render (e.g. a non-ASCII HELP
  char) fails the whole deploy. Verify metric changes by rendering, not just declaring.
