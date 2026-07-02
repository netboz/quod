# M2 content-layer — code review findings

> **Historical record.** Dated findings from the **M2** review of the *Raft* ordering layer
> (`quod_ledger` — elections + replication), since replaced by the **DispersedSimplex** consensus
> (`quod_simplex`). Kept as-is; module/protocol names below refer to the retired Raft implementation.

Max-effort adversarial multi-agent review (2026-06-27) of the **M2** ordering layer
(per-namespace Raft committee over loopback QUIC: election + replication, driving
committed blocks into `quod_prolog`). 11 candidates → **8 confirmed** (3 rejected).
Status key: **[FIXED]** addressed this session · **[DOC]** recorded with a concrete fix,
out of M2's testable fault model.

All four `raft_safety_SUITE` multi-node tests, 18 `quod_ledger_tests`, and the full 96-test
eunit suite pass after these fixes.

## Real bugs (live in M2)

1. **[FIXED] `quod_ledger.erl` — chunked AppendEntries unconditionally dropped → replication
   stall.** `frames/2` chunks only when the encoded record exceeds `?CHUNK_BYTES` (64 KiB),
   but the receiver drops any reassembled non-snapshot message over `?MAX_RAFT_BYTES`
   (same 64 KiB) — so *every* chunked AE was discarded, never acked, and the leader
   re-sent the same oversized batch forever. Reachable because `log_from/3` batched by
   entry **count** (`max_batch=256`), so a catch-up or a stream of fact-bearing blocks
   could exceed 64 KiB. → batch AEs by encoded **bytes** (`?AE_BATCH_BYTES`, `take_under_bytes/2`)
   so an AE is always a single frame; the chunk path is reserved for M3 snapshots.

2. **[FIXED] `quod_conn.erl` / `quod_ledger.erl` — dead-but-dialable member → unbounded outbox.**
   A connection that never comes up (`quic:connect` timeout/closed) discarded its queued
   `{open_link, …}`, so the waiter got neither `link_up` nor `link_error`; `quod_ledger`'s
   per-peer outbox then grew every 150 ms heartbeat forever (OOM) against an offline
   member. → `quod_conn:start_outbound` now drains queued opens and replies `link_error`
   on every connect-failure path; `send_raft` **coalesces** the outbox to the latest
   message per peer (each Raft RPC carries full current state, so newer supersedes older).

3. **[FIXED] `quod_ledger.erl` — multi-voter restart marked `quod_prolog` ready over an empty
   kb.** On restart `commit_index` resets to `snap_idx` and is only re-learned from the
   first AppendEntries/election; the old rebuild handler marked ready immediately, so a
   restarted multi-voter member briefly served `fail`/stale answers for durably-committed
   facts (1-voter was accidentally safe). → readiness is now gated on `caught_up/1`
   (applied up to a *re-learned* commit point), and `mark_ready` rides the same FIFO cast
   channel as `apply_block`, so it always lands after the applies. Enabled by #4.

4. **[FIXED] `quod_ledger.erl` / `quod_prolog.erl` — synchronous `append`↔`apply_block` deadlock.**
   `quod_prolog:submit_write` calls `quod_ledger:append` synchronously while `quod_ledger`'s
   apply loop calls back into `quod_prolog:apply_block` synchronously — a call cycle. M1
   dodged it for the leader's *own* write (reply the commit-ack before applying), but the
   `rebuild` handler and any 2nd concurrent writer close the cycle into a mutual block
   (self-heals only at the 5 s `append` timeout). → **`apply_block` is now an async cast**:
   `quod_ledger` never blocks on `quod_prolog`, so it always stays free to service `append`.
   The OCC verdict goes straight to the parked client; a forward gap asks `quod_ledger` to
   re-drive. (Also what makes #3's readiness gating deadlock-free.)

## Robustness — production-hardening beyond M2's loopback fault model

5. **[DOC] `quod_ledger.erl` — a silently half-open cached link is never recovered.** If a
   follower's host crashes or a one-way partition forms such that the QUIC connection
   stops delivering *without* emitting a close (so no `DOWN`), the leader keeps sending
   into the dead link; its 150 ms heartbeats keep the connection "active", so QUIC's idle
   timeout never fires either. **Not reachable on loopback** (a killed node closes cleanly
   → `DOWN` → re-dial, which `leader_failover` exercises). **Fix when hardened:** leader
   tracks heartbeats-since-last-reply per peer (a follower replies to *every* AE), and on a
   threshold tears down the whole connection (a re-introduced `quod_quic:drop_conn`, killing
   the `quod_conn` so the next send dials a fresh one) — now safe because the symmetric
   client-only transport no longer produces the phantom that made an earlier attempt churn.
   Deferred only because it cannot be validated in M2's loopback setup, not because it's hard.

## Lower-severity / latent — fixed opportunistically

6. **[FIXED] `quod_ledger.erl:apply_committed` — badmatch if `I ≤ snap_idx`.** `entry_at/2`
   holds only the live tail (`snap_idx+1..`); a `{behind,A}` resync (now: a post-rebuild
   reset) could leave `last_applied < snap_idx`, making the next `entry_at` return `false`
   → badmatch outside the apply try/catch. Unreachable in M2 (`snap_idx=0`), live once M3
   snapshots land. → start the loop at `max(last_applied, snap_idx)+1`.

7. **[FIXED] `quod_ledger.erl:reassemble` — duplicate chunk `Seq` double-counted bytes.** A
   retransmitted chunk overwrites in `got` (size unchanged) but was added to `bytes` twice,
   able to spuriously trip the reassembly cap. → count a part's bytes only on first sight of
   its `Seq`. (The chunk path is now AE-free per #1, so this is snapshot-only/M3, but cheap.)

8. **[FIXED] `quod_ledger_store.erl:scan_log` — silent truncation past mid-log corruption.**
   `scan_log` trimmed (deleted) the file at the first bad-CRC/discontinuous frame, treating
   it as a torn tail. But a crash can only damage the *final* frame, so a corrupt frame
   **followed by a valid one** is mid-log bit-rot — trimming it silently discarded
   durably-committed entries (and could let the node re-append divergent indices peers
   already hold). → `trim_or_fail/7` peeks past the bad frame: a valid `?MAGIC` following ⇒
   **fail-stop** (`{log_corruption, …}` — recover from peers); nothing following ⇒ torn tail,
   trim as before. Covered by `t_interior_corruption_fail_stops` / `t_torn_tail_bad_crc_trims`.

## Second pass — max-effort `/code-review` (10 angles, 2026-06-27)

A separate 10-angle line-by-line review (50 raw → 38 deduped → 15 verified) over the same diff,
including the fix code above. All addressed except two non-bugs:

- **[FIXED] `quod_ledger.erl:send_raft` — duplicate `link_up` closed the LIVE link (HIGH).** send_raft
  re-called `open_link` on every send to a not-yet-connected peer (no in-flight guard); each dial added a
  waiter in quod_conn, which then notified all waiters with the SAME LinkPid — the duplicate `link_up`
  fell into the "already linked" branch and `quod_link:close`d the just-adopted live link (self-DOWN →
  drop → re-dial → stall). → dial only when `not maps:is_key(M, Outbox)` (no open already in flight).
- **[FIXED] chunk path (MEDIUM) — inbound guard `?CHUNK_BYTES + 64` dropped a full chunk frame** (the
  envelope + Ns + ref overflow it); a single oversized `#transaction` can chunk in M2. → guard `+ 1024`, and a
  REASSEMBLED message routes under `?MAX_SNAPSHOT_BYTES` (not the single-frame `?MAX_RAFT_BYTES`).
- **[FIXED] `reassemble` badkey crash (LOW)** — an out-of-range `Seq`/`Total` from a corrupt peer made the
  completion path `maps:get` a missing key and crash the statem. → reject out-of-range `Seq`/`Total` up front.
- **[FIXED] efficiency — `advance_commit` re-derived the committee O(N)×log per AE reply** (hoist
  peers/quorum once); **`apply_committed` did a registry lookup per entry** (hoist once); **`last_log_index/term`
  were `lists:last` (O(n)) on every hot-path call** → cached tail (`last_idx`/`last_term`, refreshed via
  `with_log/2` at every log mutation), and `log_from` fast-paths the caught-up/heartbeat case to O(1).
- **[FIXED] `quod_conn` — dead `{conn, Peer}` registration** (leftover after removing connection adoption;
  nothing reads it, a mutual-dial pair clashed silently) → removed `reg_conn`.
- **[FIXED] `submit_write` — `{error, busy}` backpressure double-wrapped to `{error, {error, busy}}`** →
  handled as a clean retry signal; `append/2` spec now lists `{error, busy}`.
- **[FIXED] `trim_or_fail` trusted the corrupt frame's length** for the next-frame peek (#8 follow-up) → now
  scans the tail for the magic, so a corrupt length can't make the interior-corruption check miss.
- **[NOTE] `link_error` drops the outbox with no immediate re-dial** — by design: Raft tolerates the loss
  (next heartbeat/election re-sends; with the send_raft fix the cleared outbox re-dials on the next send).
- **[NOTE] `encode/1`+`decode/1` mirror quod_brahms's** — left as-is: trivial `term_to_binary` wrappers, and
  quod_ledger's codec has diverged (`decode_record` without `[safe]`); a shared module would over-abstract two one-liners.

## Rejected (verified false alarms)

- **`next_index[Peer]` regression on a reordered AE reply** — not reachable: `match_index`
  in a reply is monotone (`prev_log_index + length(entries)`), and the in-order per-peer
  `quod_link` channel can't reorder; self-healing even if it could.
- **5 s statem freeze from `apply_block` during a "deadlock window"** — refuted: the
  commit-ack is replied before the apply loop runs (now moot anyway: `apply_block` is async).
- **`fail_pending_above` on a follower** — dead code, not a bug: a follower never holds
  `pending` (only a leader parks client appends).
