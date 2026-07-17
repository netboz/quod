# Deferred work — central registry

A living list of **deliberately-postponed work and known gaps**, with enough context to pick each
up later. Cross-cutting and milestone-gated items live here; day-to-day TODOs stay in code as
`AI:` / `REVIEW(...)` markers.

When you close an item, delete it from this file. When you defer something during a review, add it.

---

## 1. Identity / signing — mostly landed (DispersedSimplex milestone)

Node keypairs (`node_id` = Ed25519 **pubkey**, A.3), Ed25519 `sign/2` + `verify/3`, mutual TLS bound to
the pubkey (A.4), and the per-block **commit certificate** (a bag of ⅔ signatures — `quod_simplex`'s pure
core) have landed with the DispersedSimplex milestone (consensus plan + `doc/simplex_extended.pdf`).
`#transaction.author` carries the submitter's pubkey; `#transaction.sig` is still `none`
(transaction-author signing rides Stage 2). Remaining, gated:

- **Transaction-author signatures.** Blocks and relayed entries already carry quorum finality proofs;
  `#transaction.sig` is still `none`. Signing the canonical transaction is required before safe
  follower-to-leader forwarding and before membership can be opened beyond the trusted fleet.
- **Membership-path hardening.** Committee admission has since landed (committee = `peer_admitted` facts +
  `admit`/`remove` external predicates, membership rework Slice 1+2). The HARDENING is the deferred
  membership-safety work in §3: a pubkey-possession gate before `can_join`, signed membership
  transactions, epoch-frozen voting sets, and a `can_replicate` policy for private read-replicas.
  Per-node `can_join` re-validation is already live.
- **Authenticated + rate-limited remote reads.** The `{prove, Ns}` endpoint accepts a link from any node
  (reads are open; content is gated per-clause by `can_read`). *Bounded now:* `?MAX_INFLIGHT` proofs,
  `?MAX_FRAME_BYTES` per frame. → `quod_prove`.

## 2. Transport hardening (hostile-net)

- **Mutual TLS is opportunistic at the lib level, but quod now binds it.** `verify => true` only
  *requests* a client cert (an empty cert still completes the handshake, `peer_cert = undefined`).
  **Closed in A.3:** `quod_conn:bind_ok/2` rejects an inbound connection whose link-header pubkey is a
  real 32-byte key but whose `quic:peercert/1` is missing or mismatched — so an unauthenticated /
  impersonating peer can't speak on a pubkey identity. *Still open:* the bind is skipped for non-pubkey
  (no-identity/test) ids, so it only bites once a node has a real keypair (the production path).
- **PEM-fallback badmatch on a missing cert file** (`quod_quic:identity_certkey/0` →
  `load_cert`/`load_key`). When the identity env (`identity_cert`/`identity_key`) is absent, the
  fallback does `{ok, Pem} = file:read_file(certfile)`, which **badmatches if the file is missing**
  and crashes the transport's `init/1` at boot. Pre-existing (the old code loaded the PEM
  unconditionally) and now *less* reachable; make it a clean fail-fast error once the legacy/test
  PEM path is retired (the production boot always sets the identity env via `quod_app:apply_identity`).
- **Non-`[safe]` decode** (`quod_prove:inbound`; and the DispersedSimplex `{log, Ns}` transport once it
  lands in Stage 2). Any on-channel speaker can deliver arbitrary terms (atom-table growth). Deliberate
  so fact atoms decode; closed by signed/validated payloads (§1). Size-bounded: `quod_prove` caps frames
  at 1 MiB.
- **Per-peer reassembly heap** (chunk reassembly on the consensus `{log, Ns}` channel — reintroduced with
  the Stage-2 transport). Spoofed peers each start an incomplete chunked message → unbounded buffering.
  Needs a per-message timeout / a cap on concurrent reassemblies. (The removed Raft transport had this
  gap; carry the fix into `quod_simplex`'s Stage-2 wire.)
- **`quod_prove` large results.** A prove result > 1 MiB (`?MAX_FRAME_BYTES`) is dropped — no app-level
  chunking. Add chunking if large read results are ever needed.
- **`quod_prove` outbox on `link_error`.** A buffered read is dropped and the caller times out (5 s)
  then can retry. Intended eventual behavior; an app-level retry/backoff in `remote/5` would fail
  faster.
- **Resolver cache dies with the transport.** `?ADDR_CACHE` (pubkey→endpoint hints) is owned by the
  `quod_quic` gen_server with **no `heir`**; a transport crash (it is `permanent` under `one_for_one`)
  destroys every learned hint and `init` re-seeds nothing (the old `addr_hints` seed hook was removed as
  dead). Harmless today — the pubkey/address confusion that used to crash the transport is fixed
  (`is_endpoint/1` guards `learn`+`resolve`, and a keyed node fails fast without `node_addr`) — but any
  *other* transport crash still forces peers to re-dial in before this node can reach them. **The Slice-D
  admit-fact hints (`learn_addresses`) are re-learned only on NEW commits**, so after a transport crash a
  quiescent committee's member↔member hints stay lost until the next membership commit (or an inbound
  header). Cold recovery also heals enough hints from the Brahms/seed endpoint pool before its
  identity-bound tip quorum, but a completely isolated node still cannot recover. Also (Slice D, DA#1):
  `learn`/`learn_if_absent` NEVER create the table (only `init` does), so a hint written from the consensus statem can't end up owning a table that
  dies with a namespace teardown; a write before the table exists is a fail-closed no-op. Fix when needed:
  give the ETS table an `heir`, or re-seed on `init` from a persisted/config source.
- **Cold-start address bootstrap — LANDED as a dial HINT (Slice D), deliberately not an address book.** A
  node dials a peer by pubkey via the resolver, populated by inbound link headers (`quod_link:learn_hint`)
  AND now by the committed `peer_admitted` fact's address: `quod_simplex:learn_addresses` learns each
  admit's `{Pk,{Host,Port}}` at the live commit (`adopt_committee`, OVERWRITE — the fact just passed
  quorum-many readiness verdicts, it's fresh) and on catch-up replay (`apply_catchup_window`,
  learn-if-absent — a historical address must fill a void, never clobber a live header hint). This closes
  the never-met-member hop (at 2→3, member J1 dials brand-new J2 whose address it learned only by folding
  J2's admit out of the log) — `growth_SUITE` proves 1→4 growth with ZERO resolver pre-seeding. It is a
  HINT, not an address book: `peer_admitted` addresses ROT on dynamic Nomad host ports (see member address
  refresh below), and rot-recovery stays Consul seeds + inbound headers + Brahms. The co-founder scaffold
  still pre-seeds (`bootstrap/2` never learns, since genesis addresses are the co-founders' own config) —
  so `simplex_SUITE`'s pre-seeds remain correct, not papering over a gap.
- **~~`quod_catchup`/`quod_feed` transport duplicates `quod_prove`~~ — DONE (transport `send` verb).**
  The copy-pasted per-endpoint `send`/`conns`/`outbox`/`link_up`/`link_error`/`DOWN` skeleton is GONE:
  the transport now exposes **`quod_quic:send/3`** (fire-and-forget send to a target on a channel), backed
  by a per-channel frame buffer in `quod_conn` (dial on demand, buffer until the link is up, flush, reuse —
  the connection owns the link lifecycle). `quod_prove`, `quod_catchup`, and `quod_feed` each dropped their
  link bookkeeping and just call `send/3`; peer-random selection reuses `quod_brahms:take_random/2` (promoted
  to public). Endpoints that must monitor the link themselves (Brahms, consensus) keep `open_link/2`.
- **Restarted-peer feed lag (~1–3 min) — DIAGNOSED; self-heals, fast-drop deferred.**
  A peer that restarts — even at the SAME address (a Nomad task restart keeps the port) — is not delivered to
  for ~1–3 min (reproduced: the reconnected node sits at its pre-restart slot while the founder climbs, then
  snaps forward). Root cause, verified against the vendored `quic` 1.6.5: `quod_quic:ensure_conn/3` reuses a
  cached conn while its process is `is_process_alive`, and that process only exits on the transport `{closed}`;
  but the idle timeout NEVER fires because this `quic` resets `last_activity` on every **send** (contra RFC 9000
  §10.1, `quic_connection.erl:3550`) and quod's Brahms (~5 s) + feed keep sending into the dead conn. So the
  stale outbound lingers until Brahms `mark_dead` (~50 s: `conn_idle_rounds 8` + `probe_rounds 2`) stops the
  sends and the idle timer finally drains (~30 s) — i.e. it DOES self-heal in ~80 s, just slowly. The
  **consensus** side is already robust independently: `quod_simplex` now sweeps a dial that never resolved
  (neither `link_up` nor `link_error`) after a fixed ~15 s so the tick re-dials — no stuck-dial partition. **REJECTED** as the fast-drop for the feed: keepalive (resets `last_activity`, keeps
  the dead conn alive forever); stable `reset_secret` (a no-op in this lib — the peer never caches a reset
  token: empty `peer_cid_pool`, `NEW_CONNECTION_ID` never issued proactively, seq-0 reset-token TP unencoded);
  and a `quod_brahms:mark_dead/2` → `quod_quic:drop_peer/1` hook that force-kills the cached conn (patched the
  transport to paper over the missing consensus backstop — wrong altitude, and force-killing a mid-handshake
  dial reintroduced the stuck-dial partition; the dialing sweep above is the right fix). **RESOLVED
  (0.6.20):** exactly this was done. quod now builds against a SHA-pinned fork `netboz/erlang_quic` (from
  tag 1.6.5, benoitc kept as `upstream`, branch `idle-timer-rfc9000-10.1`) that fixes the RFC 9000 §10.1
  bug — the idle timer was refreshed on our own **sends** (`last_activity` bumped per send), so a
  black-holed peer we kept sending to never timed out — plus a keep-alive re-arm fix (it busy-looped once
  `last_activity` froze) and a lowered keep-alive floor (5000→250 ms). quod sets `node.idle_timeout_ms=2000`
  / `node.keepalive_ms=500` (config, both ends — no RFC min-negotiation in this build) via one
  `quod_quic:liveness_opts/0` → **~2.5 s** dead-peer detection (was ~80 s). Verified live: 20- and 30-node
  fleets under mass churn (batch + mass-departure of up to 15) + ~15 tx/s; `unverified`=0 throughout.
- **quic fork follow-ups (netboz/erlang_quic) — deferred, non-blocking.** (a) a **process-level black-hole
  integration test** in the fork (only the pure `send_activity/4` truth-table + the clamp are unit-tested);
  (b) two RFC §10.1 upstream nits — make the idle-timeout close **silent** (§10.1 forbids a CONNECTION_CLOSE
  frame) and floor idle at `max(configured, 3×PTO)` in `set_idle_timer`; (c) a **catch-all** clause in
  `calculate_keep_alive_interval/2` so a non-integer `keep_alive_interval` can't `case_clause`-crash init;
  (d) consider **upstreaming** the §10.1 fix to benoitc. **Rejected (don't revisit):** a loss/PTO-based
  DisconnectTimeout — it false-closes a *live* peer when only the return/ACK path drops.
- **Stream prioritization for signaling (RFC 9218) — PROMOTED to the agent/runtime substrate plan.** quod
  already gives each channel its own QUIC stream, so loss-induced head-of-line blocking is avoided, and
  `quod_quic` now converges channels onto one connection per peer. All those streams still share one congestion
  window, so feed, ACL, and future client traffic can contend with consensus. The pinned `quic` fork supports
  `quic:set_stream_priority/4` (urgency 0–7); Slice 3 must define channel priority classes and prove under load
  that lower-priority producers cannot starve `{log}` consensus signaling. Future RFC 9221 datagrams share the
  same congestion window and pacing even though they do not head-of-line block streams, so they also require
  explicit byte-rate caps and mixed-traffic tests.

## 3. Consensus + membership (DispersedSimplex stages)

The Raft ordering layer (`quod_ledger`) has been **replaced** by a hand-rolled DispersedSimplex BFT
(`quod_simplex`) — consensus plan + `doc/simplex_extended.pdf`. The Raft-specific deferrals that lived
here (Ra-style round-based promotion, `InstallSnapshot`, `remove_member`, Brahms-candidate join
discovery) are **retired with the Raft code**; the equivalent capabilities are re-planned as Simplex
stages, not carried forward:

- **Multi-validator BFT** — **DONE** (Stage 2b+2c): real ⅔ support/commit/**complaint** certs, the
  `Δ_timeout` complaint timer, the `may_commit`/`may_complain` guards, **round-robin leader rotation**,
  and complaint-cert **skip** (a `noop` slot), over the `{log, Ns}` transport.
- **Committee = `peer_admitted` facts + admit/remove — DONE** (membership rework, Slice 1+2): the committee
  is the set of `peer_admitted/4` facts, derived deterministically from the committed log
  (`quod_simplex:log_projection/2`), swapped in-process at commit (`adopt_committee/2`), and re-folded
  on restart — no config-fold, no member-op vocabulary (`voters/2`, `member_op()`, `kind=config` deleted).
  `quod_committee_predicates` provides the `admit(Pubkey,Host,Port)` / `remove(Pubkey)` external Erlang
  predicates (**prove-before-broadcast**: gate `can_join`, stage the assert/retract; the normal write path
  commits it — no sync-call from the predicate). Genesis asserts each founder's `peer_admitted`.
- **Membership SAFETY — per-node re-validation + shrink floor: parts (a)+(c) LANDED (0.6.22–0.6.24,
  Slices A–C); part (b) signatures still open.** The gate is now at **propose/support time** on EVERY
  validator (the BFT-native seam), not the honest submitter alone:
  - **(a) per-node re-validation — DONE.** Every validator re-judges a committee-changing proposal against
    its OWN kb before support-signing (`quod_prolog:request_membership_verdict/5`, an async cast pinned to
    the proposal's parent height `Slot-1` so honest nodes reach the same verdict): an assert re-proves
    `can_join` (rejecting a `can_join` that stages writes, or a pubkey already admitted); a retract requires
    the exact `peer_admitted` clause present (`quod_diff:has_clause/4`) — which closes the fabricated-address
    **validator-ejection** (a wrong-`Host`/`Port` retract that would drop a member from `#s.validators` while
    missing in the KB). A `valid` verdict emits the deferred support share; `invalid` latches `#round.invalid`
    (barred from endorsing at any phase, `membership_rejects` counted) — so an unauthorized change never
    collects an honest support quorum and is complaint-skipped. **NOT re-validated at apply**: a committed
    membership tx applies **unconditionally** in the KB (`is_membership_change` → skip OCC), keeping the KB
    and the validator-set projection in **lockstep** (this replaced the old apply-time-drop idea, which would
    fork a cert-trusting catch-up joiner). Proven on the 4-node loopback-QUIC committee (`simplex_SUITE`
    `byzantine_retract_rejected` / `byzantine_admit_rejected`: a crafted proposal from the real leader is
    refused support, the slot skips, the committee is unchanged, the namespace still commits).
  - **(c) never-empty floor — DONE (crash-safe, stepwise).** `quod_simplex:membership_change_ok/2` (the pure
    shape gate, Slice A) enforces: a committee-touching tx is EXACTLY ONE well-formed `peer_admitted` op
    (`Id =:= Pk`, binary) and must not empty the committee — at BOTH the leader (`handle_append`) and every
    validator (`valid_proposal`). Kills the raw `retract`-everyone wedge, mass packing/shrinking in one block,
    op-smuggling, and the `Id≠Pk` address-poison op. The floor is **stepwise never-empty** (4→3→2→1 legal, one
    quorum-endorsed member per block); the **hard `3f+1` Byzantine-tolerance floor stays OPEN** — it needs a
    network-target-`f` concept, and with today's liveness-only `can_join` (`peer_ready` — any live,
    caught-up node passes) + `sig=none` a still-admitted member can walk the committee down one endorsed
    step at a time.
  - **(b) transaction signatures — STILL OPEN (Phase B).** Writes are unsigned (`sig=none`), so the verdict
    checks WHAT changes, not WHO authorized it: with a liveness-only `can_join` (the `peer_ready` gate
    checks the candidate is alive and caught up, not that anyone *authorized* it), committee **packing**
    (admitting nodes the policy would allow) and authorized-but-unwanted **shrink** are not yet closed —
    that needs the write-gate = membership signature trick from onbrater. Until (b) lands, membership is Byzantine-safe
    against *malformed / policy-violating / KB-inconsistent* changes but not against a **forged author**.
- **Mid-flight committee-change / stale-cert hazard (code-review 2026-07-04) — CLOSED for finalization
  (Slice E, 0.6.34); ROOT epoch fix still deferred.** Because the committee can change on ANY slot (a
  `peer_admitted` assert/retract) and shares are ingested un-gated by height, a node LAGGING across a
  committee-changing slot N can `form_cert` slot N+1's finalizing cert under the OLD (pre-change)
  committee's smaller quorum. A catch-up joiner reconstructs the committee **as-of** N+1 (the NEW set) and
  would reject that block (too few sigs). S1 minimised the *persisted* cert (`persisted_cert/4` re-minimises
  to the distinct valid sigs of `eng.validators`; a lagging node computes `none`). **Slice E closes the
  finalization**: `commit_block`/`skip_block` now REFUSE to finalize when `persisted_cert` returns `none`
  (sub-quorum under the committee-as-of-slot) — `weak_cert_wait`/`eng_evict_final` evict the stale cert +
  un-mark the slot, so the node waits for a genuine cert (re-formed under the current set once enough shares
  arrive, or delivered by trustless catch-up) rather than locally finalizing a slot the honest network may
  never commit. So a laggard no longer forks. **Still deferred (the ROOT epoch fix):** freezing the
  validator set per epoch so a slot's voting set is unambiguous end-to-end (Slice E is the finalize-time
  backstop; epochs would make the hazard unreachable at formation time and let a slot notarize under a
  known-frozen set). Intersects the membership-safety gap above (unsigned, per-slot-mutable membership).
  **Seam in place (0.6.25):** the "who votes / leads / disseminates now" reads route through a
  single function `quod_simplex:active_validators/1` — the **active voting set**, held distinct from the
  committee **facts** (`#s.validators`). Today it is the IDENTITY over the facts (epoch length 1); the
  epoch-freezing work adds an epoch snapshot field + boundary detection and rewrites `active_validators/1`
  to return the set frozen at the epoch's start, so a mid-epoch facts change stops moving the voting set —
  it does NOT have to re-find the read sites. This is a landing pad, not the fix.
- **Join cold-start + trustless catch-up** — **DONE (Stage 3 / Simplex 4, S1–S5a):** the machinery
  (`quod_catchup`: persist each block's finalizing cert, an off-consensus catch-up server, the inductive
  forward-verifier, and the driver loop) plus the `mode=join` wiring in `quod_simplex`. A `mode=join` node
  boots UNFOUNDED (empty log ⇒ `validators=[]`, `slot=0`), and a monitored worker drives `catch_up/3` from
  a sampled bootstrap contact, then reconciles a member against every available current-committee source:
  pull a window → `verify_forward` each cert against the committee it reconstructs → hand
  the verified window back to the statem (`sink_catchup`) to append + **replay into the KB as it lands** →
  advance, until caught up. The genesis (slot 1, `cert=none`) is anchored against the out-of-band-pinned
  `genesis_hash` (config), never TOFU'd; `quod_simplex:genesis_hash/1` exposes a founder's anchor. A
  caught-up joiner is a **read-only observer** — not in its own `validators`, so `is_participant/1` drops
  live consensus traffic and refuses appends (`not_in_charge`). Covered by `join_SUITE` (found N=1 → commit
  a fact → a `mode=join` node catches up over loopback QUIC → proves the fact from its OWN KB, stays a
  non-member). **Resume + hardening (from the S5a review, all landed; re-homed by the Slices 3+4 refactor):** a
  `mode=join` node re-enters catch-up on EVERY boot (empty OR partial log) via the unified `start_sync_worker`,
  which RESUMES from the persisted height (`slot+1`, committee-as-of-that-slot) — so a crash/redeploy
  mid-catch-up never re-appends its on-disk prefix (the store's `assert_contiguous` would throw) nor treats a
  partial log as complete (`maybe_mark_ready` stays gated on recovery reaching `ready`). `catch_up/5` is the resume entry
  (skips the genesis anchor past slot 1). `is_participant/1` is now FACTS-ONLY, so a window that folds the
  joiner's OWN pubkey does flip it to a participant — but the explicit recovery enum remains `unconfirmed` /
  `pulling` until distinct current-committee observations at the exact final height, together with self, form
  a certificate quorum. Only `ready` grants `may_vote`/`may_lead`. A raw `{ok,0}` from an empty/stale contact
  is merely one observation and cannot satisfy that quorum. Committee-targeted catch-up replies are also bound
  to the authenticated peer queried. A cold node with too few `pubkey -> endpoint` resolver hints first
  performs up to three bounded rounds of one-entry direct endpoint pulls; authenticated QUIC headers teach
  the missing hints, then the same identity-bound quorum probe is retried. Those warm-up replies are never
  ingested, so they cannot bypass verified catch-up. `valid_cfg` fail-fasts a bad
  `mode` or a `join` without a `genesis_hash` anchor (no silent zombie). Covered by `join_SUITE`'s
  full-namespace-restart resume case. **Still deferred from here:**
  - **~~Admission to voter (S5b)~~ — DONE (multi-validator milestone, Slices A–E, 0.6.30–0.6.34).** A
    caught-up joiner IS promoted to a voting member: an existing member proves `admit`, the `peer_admitted`
    commits, the joiner sees its own fact arrive over the feed and self-promotes (`maybe_promote`). Slice B
    added the growth-liveness redrive (the 1→2 promotion race), Slice C the `peer_ready` readiness gate
    (never admit a dead/lagging node into a quorum=all committee), Slice D the fresh-admission dial hint
    (a member can reach a brand-new member via the committed address — growth past 2 needs no manual
    mesh-seed), Slice E the weak-cert finalize guard (a laggard never locally finalizes a slot the honest
    network may not commit). Proven zero-pre-seed 1→4 in `growth_SUITE`. Live rollout rides Slice F.
  - **~~HOCON `genesis_hash` plumbing~~ — DONE** (the schema field + `quod_app` passthrough landed; a
    production `mode=join` node supplies the anchor via config — the Nomad job renders it, see
    `deploy/quod.nomad`).
  - **The co-founder scaffold STAYS** (decided 2026-07-05): the `committee` config + `simplex_SUITE`
    co-founding is the ONLY way to stand up the 4-node BFT **failover** committee in a test, and join can't
    replace that (a live namespace grows 1→N via sequential admits — `growth_SUITE` — but the failover CT
    needs an instant N=4). Keep it.
  - **Read-replica (stay-synced) tier** — a caught-up (`ready`, non-`syncing`) non-member already TRACKS
    the head off the feed: it drops the consensus `{log,Ns}` traffic (not a voter), but `quod_feed` carries it forward —
    eager-push when it has a Brahms overlay, and (since the readiness gate) digest→verified-pull off the
    committee members even without one. What is unbuilt is a durable replica **tier** with its own policy:
    a `can_replicate` admission gate, retention, and snapshot bootstrap — the reader-arc work (§4).
  - **Member address refresh (Slice D residual).** The committed log holds exactly ONE address per member —
    its original admit — because `already_admitted` (the one-fact-per-pubkey verdict, `quod_prolog`) blocks
    a re-assert, so there is no path to refresh a member's logged `peer_admitted` address. On dynamic Nomad
    host ports (which change on every reschedule/rolling update) that address ROTS; refresh today = `remove`
    + re-`admit` (two quorum operations). The Slice-D dial hint is fresh only at the admission moment;
    afterward rot-recovery is Consul-rendered seeds + inbound headers + Brahms (the live-evidence
    `learn`-overwrite channel), never the log. **Consider static Nomad ports for committee members** so the
    logged address stays valid. Sub-residual: a cold replay of a `remove`+re-`add` of the same pubkey across
    DIFFERENT catch-up windows keeps the FIRST address (learn-if-absent skips the later re-add) — healed by
    the header-overwrite path on first live contact; harmless (a wrong hint is at worst a failed dial, mTLS
    binds every connection to the expected pubkey).
- **Multi-founder genesis is not enforced byte-identical.** Each co-founder builds its slot-1 genesis from
  its OWN config, with no parent-hash chain to catch a mismatch (slot 1 is self-committed; consensus starts
  at slot 2). Mismatched co-founder addresses → divergent `peer_admitted` addresses per KB (the
  pubkey-committee stays consistent, so consensus is unaffected). `simplex_SUITE` passes matching
  `{Pk,Host,Port}` so genesis is identical; a real multi-founder deploy must too, or add a genesis-hash
  cross-check. Also: **`can_join` must stay side-effect-free** — the proof overlay captures every staged
  assert into the membership diff, so a `can_join` clause that asserts/retracts would ride ops into the
  committed membership transaction network-wide.
- **Pending-transaction forwarding remains deferred.** Failover is now evidence-gated and self-healing:
  `f+1` peer complaints are amplified, complaint/support/commit shares are periodically re-driven, the
  approved frontier advances on notarization, and a successor commit implicitly finalizes its parent.
  What is still missing is forwarding a follower's rejected local `#transaction{}` to the actual slot
  leader. That needs transaction-author signatures first; without them, forwarding would let an
  intermediary invent client intent. Until then the client follows the leader hint and retries.
- **Vote-latch persistence across restart (Phase B — a blocker before OPEN membership).** The per-slot
  vote latches (`#round.supporting`/`commit`/`complaint`) that enforce the one-share-per-slot safety rule
  live in RAM, so a validator that CRASHES and restarts mid-slot loses them and could re-sign a
  different block/complaint for the same slot — an equivocation. Bounded today: at `N ≤ 4` a SINGLE
  crash-equivocator can't fork (its two shares still need a quorum that overlaps an honest party), but TWO
  simultaneous crash-equivocators can. Safe enough for the trusted fleet (crash-restart is rare and the CSI
  volume + catch-up re-syncs a restarted node past its in-flight slot before it votes again), but it MUST be
  closed before open/Byzantine membership: persist the latches (or a per-slot "already-voted" marker)
  alongside the durable log so a restart refuses to re-sign a slot it already signed. Intersects tx signing
  (Phase B) and the epoch work.
- **~~Member multi-slot gap-fill / founder-stall corner~~ — DONE (clean-separation refactor, Slices 3+4,
  0.6.38–0.6.39).** A committee member that fell several slots behind the head could stall: it relied on the
  per-message redrive (Slice B) + dial-tick retransmit to refill, but had no member-side *bulk* catch-up, and
  the boot-time `join` enum conflated boot-mode / sync-state / participation so a fallen-behind voter couldn't
  re-enter catch-up in-process. **Empirically reproduced under sustained load (0.6.36 load+chaos, live qengho
  fleet):** a churned validator's catch-up finished at the head *as of that instant*, the other members
  committed further meanwhile, and it re-promoted a few slots behind then stalled in the former
  `join=done` state —
  `kp_3c2dd6bf` stuck ~5 min at slot 419, `kp_c1740be7` at 1254, each recovering only on a *further* restart.
  **Fixed** by deleting the `join` enum for three single-owner concerns — boot `mode` (config, read once),
  one recovery enum (`unconfirmed | {pulling,Pid} | ready`) plus `sync_arm` pacing (driving BOTH
  boot-sync from base 0 and runtime member gap-fill from slot+1), and facts-only `is_participant`. A behind
  member now recovers IN-PROCESS on the same trustless path a joiner uses; all runtime share construction
  routes through `may_vote = is_participant ∧ caught_up`, so it neither leads nor signs while it pulls.
  Slice 3 shipped the fix on the enum-intact diff and the live
  loadtest confirmed recovery (over-f churn, no ghost); Slice 4 was the atomic enum cutover. Plan:
  `~/.claude/plans/serene-churning-pike.md`. Remaining tail: the bounded ahead-buffer (Slice 5) closes the
  moving-*tail* residual (buffer verified ahead blocks, pull the holes) and the vote-flood cap (Slice 6).
- **Snapshot / compaction** — later; nothing compacts yet (apply-and-forget keeps the KB projection, the
  store keeps the full block archive). **When it lands it must preserve the committee:** the validator set is
  now re-derived by folding `peer_admitted` asserts/retracts over the FULL committed log
  (`quod_simplex:log_projection/2`), so a snapshot that truncates the log must carry the `peer_admitted`
  facts as of the snapshot height (or a committee checkpoint) — otherwise the re-fold drops members.
  (The Raft-shaped snapshot stub — `read_snapshot`/`write_snapshot`/`install_snapshot` + `snap_cfg` —
  has been **removed** from `quod_ledger_store` along with the rest of the Raft term/vote/truncate
  machinery; compaction will be built fresh and **committee-aware**, since the Raft `snap_cfg`
  `[node_id()]` shape was wrong for the `peer_admitted`-derived committee anyway.) Note: the store
  now deliberately hard-codes **base index 1** (a log starting higher is treated as corruption — the
  earlier half-support was an untested trap), so compaction must introduce its base marker and the
  committee checkpoint TOGETHER, plus consumers that read from `first` instead of 1. No non-voting
  tier exists yet.

**From the 2a/2b/2c reviews — landed:**

- **Contiguous commit-apply** — **DONE** (2b): `commit_buf`/`drain_commits` buffer out-of-order
  finalizations and apply strictly in slot order (generalized in 2c to also carry skips), so the store's
  contiguity check never sees a gap.
- **Proposal window + batching** — **DONE**: explicit `#batch{}`, `#local_proposal{}`, and per-slot
  `#round{}` state replace the old `proposing`/`pending` field cluster. A short bounded micro-batch shares
  one block, certificate exchange, and fsync across up to 256 ordered transactions. The approved frontier
  may open one successor over an uncommitted parent, while the durable frontier still drains in order.
- **Stale collecting-batch on a competing notarization — `function_clause` crash (Byzantine/duplicate-leader
  only; found in the 2026-07-16 hardening DA review).** `collect_append/4`'s second clause
  (`src/quod_simplex.erl`) pattern-requires the in-flight `#s.collecting` batch's slot to equal the next
  proposable slot `Next = approved+1`. `approve_block/2` advances `approved` on ANY notarization but does not
  clear or reconcile a batch we are still collecting for that same slot. So if a COMPETING block for our
  collecting slot `V` notarizes (only possible if some other node proposed `V` too — a duplicate/Byzantine
  leader, since `leader/2` is deterministic and honest nodes propose a slot exactly once), `approved` jumps
  to `V`, `Next` becomes `V+1`, and the next client append lands with `collecting.slot = V =/= Next = V+1`:
  neither `collect_append` clause matches and the statem process crashes (its supervisor restarts it, which
  re-reads the durable log — so it self-heals, but a crash-loop is possible if the condition persists). The
  skip path is already safe (the 2026-07-16 fix nacks + clears the collecting batch on `finalize`); the gap
  is specifically the notarize-a-competitor path. Fix when membership opens beyond the trusted fleet: in
  `approve_block` (or `collect_append`) reconcile a stale collecting batch whose slot the approved frontier
  has passed — nack its parked callers `{error, skipped}` (reuse `nack_collecting/1`) and drop it, or add a
  catch-all `collect_append` clause that does the same. Low priority on the trusted fleet (needs a Byzantine
  or double-leader), but a correctness cliff before OPEN membership. Intersects [[vote-latch persistence]]
  and the epoch/duplicate-leader work.
- **`may_commit/2` guard** — **DONE** (2c): gated at the commit-share emit; each round's complaint/commit
  latches make the two finalization paths mutually exclusive.
- **Loopback CT** — **DONE**: `simplex_SUITE` is a real 4-node OS-peer QUIC committee (commit, redirect,
  and `leader_failover` = kill-leader → complaint-skip → rotated-leader-commit).
- **Implicit predecessor commit** (spec §2.3.3) — **DONE for the depth-one runtime pipeline.** A child
  commit finalizes its immediate approved parent. The parent entry persists a self-contained proof
  (`#implicit_cert{support,parent-child link,child commit}`), and catch-up verifies it independently.
  Committee-changing blocks remain explicit-finality barriers.

## 4. Reader/subscriber arc — the path to "millions read root"

P1 (read-replicas + remote-read) is built. Plan: `~/.claude/plans/delightful-giggling-reddy.md`.

- **Relayed-block verification** — **DONE:** feed and catch-up verify explicit and implicit finality proofs
  against the committee reconstructed at each slot before accepting an entry. The remaining hostile-input
  refinement is split cert/hash verification before decoding arbitrary payload atoms (below).
- **P2 — epidemic dissemination — BUILT** (`quod_feed`, 0.6.14): push-pull gossip + anti-entropy over
  the per-namespace Brahms overlay, every block QC-verified per hop before re-push; commit seam
  (`quod_simplex` publishes `{committed, Slot, Entry}` on `{committed, Ns}`, live path only); validated
  on a 7-node Nomad fleet (cold-start catch-up + live feed-follow + a 100-tx burst, zero errors). Open
  refinements:
  - **Out-of-order handling — reorder buffer (not drop-and-re-pull).** `quod_feed` currently DROPS a
    gossiped block ahead of `H+1` (`classify → gap → dropped`) and re-fetches it later via anti-entropy
    pull — wasteful: it re-downloads a block it already received (the 100-tx burst showed `dropped`
    83–97 per node, then a bulk re-pull). **Consensus already does the right thing** — `commit_buf` /
    `drain_commits` buffer out-of-order finalizations and apply in slot order (§3, DONE) — and the feed
    should mirror it: a **bounded, verify-on-drain reorder buffer** (stash the ahead-block RAW; when the
    missing prefix arrives, `verify_forward` the now-contiguous run and drain, applying in slot order).
    Must be **bounded + verified-only-on-drain**: a gossiped ahead-block can't be cert-verified until the
    committee-as-of-its-slot is known (needs the prefix), so a Byzantine peer must not be able to flood
    the buffer with fake high-slot blocks. This replaces the current drop-then-re-pull for gap blocks;
    anti-entropy stays as the backstop for genuinely-missing prefixes.
  - **Split cert/hash/payload verify-before-decode frame** (§1/§2) — decode the `[safe]` cert+hash,
    verify against the committee, and only then decode the (non-`[safe]`) payload — so attacker atoms
    are never interned for an unverified relayed block. Pull windows still bulk-decode.
  - **IHAVE lazy advertisement** — a per-block "I have slot S" hint so a peer that missed the eager push
    pulls it before the next anti-entropy round (a push-latency tweak; anti-entropy already covers it).
  - **Adaptive push fanout (scale with network size).** `?PUSH_FANOUT` is a fixed 4, but for reliable
    epidemic spread the fanout only needs to grow like `ln(N)`. At the current 7-node fleet that means
    each block is delivered ~3–4× and dropped as `duplicate` (benign but wasteful — see the
    `quod_feed_dropped{reason=duplicate}` metric); at thousands of nodes a fixed 4 could be too thin.
    Derive it from an actual membership protocol's count — `fanout ≈ clamp(k·ln(n), lo, hi)` — part of
    the parked "adaptive sizing" bucket (with the Brahms view/sample sizes). Use the new signed
    `estimated_n` population metric only after its error and churn response are measured at scale.
    Watch `feed_dropped{reason=duplicate}` vs `ingested` to tune `k`.
- **P3 — bounded-cache subscribers (the millions tier).** Predicate cache (warmup = root schema +
  system-ontology registry) + consume the P2 feed + invalidate touched predicates on *live* commit
  (never replay) + lazy-refetch via remote-prove (P1) on miss.
- **P4 — per-predicate read-set routing** ("read-set is subscription") + cache GC (refcount + 60 s
  debounce, onia §10). The `quod_diff` functor-hash read-set already produces the per-predicate keys.

## 5. Parked (deliberately — don't reopen without a reason)

- **Adaptive view sizing** — deferred until the live-population estimate has been exercised under much
  larger churn. Brahms exposes `estimated_n`: a bounded cardinality sketch over owner-signed,
  expiring stable identities. It estimates the total live overlay component without copying a KB or a
  full membership list, but it is still an operational estimate and does not yet drive protocol sizing.
- **Partition heal** — a hard network split does not auto-recover (seeds read once at boot). Fix when
  needed: periodic re-seed from Consul.
- **Rolling-deploy ACK compat** — new-vs-old nodes churn during a rolling upgrade (the link ACK is a
  wire change). Non-issue in dev (redeploy all at once).

## 6. Per-ontology memory density (multi-tenant scaling)

Measured 2026-07-09 on a live founder under ~15 tx/s (one namespace, `quod:root`): per-node **BEAM base
~27–50 MB** (code/atoms/ETS — amortized across ALL namespaces) + **shared transport ~0.1 MB** (one
`quod_quic` for all). Per-ONTOLOGY: brahms/feed/catchup are **negligible** (~30–50 KB each); the KB
(`quod_prolog`) is the namespace's actual data (a test artifact here: 15.5 MB of 38k junk `assertz`
facts). The consensus ENGINE window is bounded — `finalize/2` prunes the engine window (`eng_prune`)
AND the per-slot support/commit/complaint sign-latches (the old "unbounded #d.log" is a retired
Raft-era concern) — but the store handle inside `#s` was not; see below.

- **~~Profile + trim the per-ontology `quod_simplex` footprint~~ — RESOLVED (diagnosed + fixed;
  live-fleet re-measure rides the next deploy).** The "~6.5 MB post-GC, bounded" reading was wrong on
  both counts: the fat was `quod_ledger_store`'s in-RAM **per-slot index** (`#store.idx`,
  `index => {Offset, PayloadLen}`, measured **~54 B/slot**) held inside `#s.store` on the simplex
  heap — it grew **with height, without bound** (6.5 MB ≈ ~120k slots, i.e. a couple of hours at
  ~15 tx/s; ~54 MB per million slots, PER NAMESPACE). Fix: the index is now **sparse checkpoints**
  (one 8-byte offset per 256 entries in a flat binary — ~32 KB per MILLION slots); a read seeks the
  nearest checkpoint, hops frame headers, then STREAMS frames through one chunked cursor
  (`next_frame/2`, 256 KiB preads, zero-copy payload slices) — every consumer (KB replay, boot
  re-fold, catch-up windows) reads sequentially, so the per-slot map bought nothing. `load/1`, which
  materialized the FULL decoded log at boot for the committee re-fold, is replaced by a streaming
  `quod_ledger_store:fold/5` shared by the boot re-fold and the KB replay, and the replay drains
  quod_prolog every 256 casts (`quod_prolog:sync/1` barrier) so a big rebuild can't re-materialize
  the log in the KB's mailbox either. A max-effort review of the slice then hardened the trust
  properties: the log is contiguous **from index 1** (a wrong-index head frame — the old First=0
  sentinel hole — is now corruption, never silently indexed), every streamed frame is CRC- AND
  index-verified (`{corrupt_entry, ...}` instead of ever returning a wrong block), `fold` past the
  tail is a loud `{fold_beyond_tail, ...}` (a store/state height mismatch can't silently skip KB
  replay), a pread I/O error at open fail-stops instead of truncating committed entries, a corrupt
  frame length can't drive a giant allocation (`?MAX_FRAME_BYTES` cap), and a catch-up window that
  fails AFTER its durable append crashes fail-loud instead of reverting to a stale handle (no
  re-append splice). Verified: 181 eunit + 23 CT green, dialyzer clean; a real N=1 founder pumped to
  slot 20 001 measures **5.9 KB post-GC** (whole `#s` 2.0 KB, store handle 808 B), identical after a
  restart-from-disk re-fold — the per-ontology consensus footprint is now height-independent
  (~1 MB at that height before, and growing).

## 7. Content / ontology authoring

- **Shared ACL prelude for authored ontologies.** Every genesis `.pl` (quod_root, animals, pets)
  hand-copies the two load-bearing governance clauses — the default-open `can_read/3` and the
  `can_join/3` admission gate (`:- peer_ready(Pk)`). N-way copies of safety-critical clauses drift:
  a Phase-B tightening of `can_join` applied only to root would leave co-hosted ontologies admitting
  on divergent gates, and an author who simply omits `can_join` gets a silently fail-closed committee
  that can never grow past its founder. Fix when the ontology count grows: a shared prelude the
  founder prepends at genesis (or an include directive in `quod_prolog:genesis_diff/1`) so the
  default gates have ONE home. Until then: copy the clauses deliberately and review them together.
