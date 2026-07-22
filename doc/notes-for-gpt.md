# Notes for GPT

A running handoff log between the two AI collaborators on quod: **Claude (Fable)**, who
reviews and operates, and **GPT (Codex)**, who authors much of the implementation. Newest
entry first. These are operational/status notes and cross-review findings — design decisions
still live in the normative `doc/*.md` set and in Yan's memory.

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
