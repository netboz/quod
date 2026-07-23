# Notes for GPT

A running handoff log between the two AI collaborators on quod: **Claude (Fable)**, who
reviews and operates, and **GPT (Codex)**, who authors much of the implementation. Newest
entry first. These are operational/status notes and cross-review findings — design decisions
still live in the normative `doc/*.md` set and in Yan's memory.

---

## 2026-07-23 — ingress v2: pre-position at the FUTURE leader (measurement falsified v1's routing)

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
through the FIFO when the queue is live (narrows the dual-target seq race; the residue is
`stale_seq`, now counted as `r_stale`/`append_stale`, NEVER `r_bad` — that mis-bucketing
is what failed the 0.7.27 loadtest with 57 false "malformed" appends). `park_ingress` arms
head demand constructively (the pre-positioned park is the one cause with no head evidence
of its own). New gauge `ingress_prepositioned`; `ingress_forwarded` is now a MISROUTE
signal (≈0 steady-state expected). The deferred compute-then-execute router refactor was
done FIRST: one pure `route/4` decision (park/collect/relay/redirect/reject), previewed by
the drain and executed by `execute/7` — `drain_dispatchable`'s hand-mirror and the drain's
no-progress backstop are gone by construction. `{relay,_,_}` is unconstructible for
relayed origin (holder→holder forwarding stays illegal). No wire change: the receiver
decides from its own state, so old and new nodes interoperate during rolling upgrade
(old nodes simply redirect what they would now park — the chase, not an error).

**Leader tenure explicitly NOT taken**: `(Slot div K) rem N` keeps a dead leader for up to
K complaint rounds and touches everything that reads `leader/2`; pre-positioning gets the
batching win with rotation-as-failover intact. Accepted residue (measured next): a small
straggler tail (boundary flights), modest r_stale, bounded origin-bounce under sustained
overload (budget 3; r_busy/overflow stays THE overload alarm).

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

**Rolling-upgrade caveat.** Old nodes drop `{error, stale_seq}` relay results (their
`valid_result` rejects the atom), degrading that race to a ~30s timeout-retry during the
mixed-fleet window — deploy fleet-wide promptly, same class as 0.7.20's readiness frames.

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

**Mixed-fleet wire note (now moot, keep for future rolls).** A 0.7.20 node withholds complaint
signing until a quorum of peers also speak the new `{readiness, Height, Ready}` frame; old nodes
drop the unknown frame. So during a partial roll, upgraded nodes pause complaints until enough of
the committee is upgraded — commits are unaffected. Deploy the readiness change fleet-wide in one
pass (as was done here).

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
