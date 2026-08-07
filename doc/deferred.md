# Deferred work — central registry

A living list of **deliberately-postponed work and known gaps**, with enough context to pick each
up later. Cross-cutting and milestone-gated items live here; day-to-day TODOs stay in code as
`AI:` / `REVIEW(...)` markers.

When you close an item, delete it from this file. When you defer something during a review, add it.

---

## 1. Identity / signing — mostly landed (DispersedSimplex milestone)

Node keypairs (`node_id` = Ed25519 **pubkey**, A.3), Ed25519 `sign/2` + `verify/3`, mutual TLS bound to
the pubkey (A.4), and the per-block **commit certificate** (a bag of ⅔ signatures — `quod_simplex`'s pure
core), namespace-bound transaction-author signatures, and authenticated
follower-to-leader relay have landed. `#transaction.author` carries the
submitter's pubkey and every non-genesis `#transaction.sig` is verified before
vote, rebuild, and catch-up. Remaining, gated:

- **Membership-path hardening.** Committee admission has since landed (committee = `peer_admitted` facts +
  `admit`/`remove` external predicates, membership rework Slice 1+2). The HARDENING is the deferred
  membership-safety work in §3: an author-aware authorization policy,
  epoch-frozen voting sets, and a `can_replicate` policy for private
  read-replicas. Per-node `can_join` re-validation and signed membership
  transactions are already live.
- **Remote reads use ontology asks.** The unused `{prove, Ns}` endpoint was
  removed: it trusted a caller-supplied ontology name and duplicated the
  authenticated `::` path. Remote reads now have one API, whose answering side
  checks `can_read` against both the ontology chain and the TLS-authenticated
  peer key.

## 2. Transport hardening (hostile-net)

- **Mutual TLS is opportunistic at the library level, but quod binds it.**
  `quod_conn:bind_ok/2` rejects every inbound header without an exact 32-byte
  key and matching peer certificate. Ordinary outbound dials by public key
  also pin that expected certificate key; directory routes use the stricter
  isolated key+endpoint pool. Bare endpoint contacts have no key to pin and
  remain address-routed until a higher layer performs identity discovery.
- **Non-`[safe]` decode** (the DispersedSimplex `{log, Ns}` transport).
  Any on-channel speaker can deliver arbitrary terms (atom-table growth).
  Deliberate so fact atoms decode; close it with signed/validated payloads (§1).
- **Per-peer reassembly heap** (chunk reassembly on the consensus `{log, Ns}` channel — reintroduced with
  the Stage-2 transport). Spoofed peers each start an incomplete chunked message → unbounded buffering.
  Needs a per-message timeout / a cap on concurrent reassemblies. (The removed Raft transport had this
  gap; carry the fix into `quod_simplex`'s Stage-2 wire.)
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
  node dials a peer by pubkey via the resolver, populated after authenticated
  inbound link headers (`quod_conn:maybe_learn_remote/2`)
  AND now by the committed `peer_admitted` fact's address: `quod_simplex:learn_addresses` learns each
  admit's `{Pk,{Host,Port}}` at the live commit (`adopt_committee`, OVERWRITE — the fact just passed
  quorum-many readiness verdicts, it's fresh) and on catch-up replay (`apply_catchup_window`,
  learn-if-absent — a historical address must fill a void, never clobber a live header hint). This closes
  the never-met-member hop (at 2→3, member J1 dials brand-new J2 whose address it learned only by folding
  J2's admit out of the log) — `growth_SUITE` proves 1→4 growth with ZERO resolver pre-seeding. It is a
  HINT, not an address book: `peer_admitted` addresses ROT on dynamic Nomad host ports (see member address
  refresh below), and rot-recovery stays Consul seeds + inbound headers + Brahms. The N=4 founding CT
  still pre-seeds its isolated loopback resolver so the sole creator can reach the three pinned joiners;
  this is transport setup, not a second genesis path.
- **~~Catch-up/feed duplicated transport link bookkeeping~~ — DONE (`send` verb).**
  The copy-pasted per-endpoint `send`/`conns`/`outbox`/`link_up`/`link_error`/`DOWN` skeleton is GONE:
  the transport now exposes **`quod_quic:send/3`** (fire-and-forget send to a target on a channel), backed
  by a per-channel frame buffer in `quod_conn` (dial on demand, buffer until the link is up, flush, reuse —
  the connection owns the link lifecycle). `quod_catchup` and `quod_feed` dropped their
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
  gives each channel its own QUIC stream. Relay submit/accepted/result frames now use only the deterministic
  `{ingress, Ns}` stream, while `{log, Ns}` is consensus-only; an ordered relay reset therefore cannot tear
  down the consensus stream. Channels sharing a `quod_quic` pool key converge
  on one connection, while ordinary, pinned and identity-discovery pool keys
  can create separate connections to the same peer. Traffic sharing a
  connection also shares its congestion window, so relay, feed, ACL, and
  future client traffic can still contend with consensus. The pinned `quic` fork supports
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
  oldest-head progress watchdog (redrive/complain across proposal, notarization, and commit),
  the `may_commit`/`may_complain` guards, **round-robin leader rotation**, and complaint-cert **skip**
  (a `noop` slot), over the `{log, Ns}` transport.
- **Committee = `peer_admitted` facts + admit/remove — DONE** (membership rework, Slice 1+2): the committee
  is the set of `peer_admitted/4` facts, derived deterministically from the committed log
  (`quod_simplex:log_projection/2`), swapped in-process at commit (`adopt_committee/2`), and re-folded
  on restart — no config-fold, no member-op vocabulary (`voters/2`, `member_op()`, `kind=config` deleted).
  `quod_committee_predicates` provides the `admit(Pubkey,Host,Port)` / `remove(Pubkey)` external Erlang
  predicates (**prove-before-broadcast**: gate `can_join`, stage the assert/retract; the normal write path
  commits it — no sync-call from the predicate). Genesis asserts each founder's `peer_admitted`.
- **Membership SAFETY — per-node re-validation, signed authors, and shrink floor
  LANDED; author-aware authorization remains.** The gate is now at
  **propose/support time** on EVERY
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
    network-target-`f` concept. With today's liveness-only `can_join`
    (`peer_ready` — any live, caught-up node passes), a signed, still-admitted
    member can walk the committee down one endorsed step at a time.
  - **(b) transaction signatures — DONE (2026-07-18); authorization remains.**
    Signatures now prove WHO authored a membership transaction and prevent a
    relay from inventing or altering it. They do not answer whether that author
    MAY admit or remove a node. The liveness-only `can_join` policy still permits
    committee packing and authorized-but-unwanted shrink; close that with an
    explicit author-aware capability rule inspired by onbrater's write gate.
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
  boots UNFOUNDED (empty log ⇒ `validators=[]`, `slot=0`), and a monitored worker drives `catch_up/4` from
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
  partial log as complete (`maybe_mark_ready` stays gated on recovery reaching `ready`). `catch_up/6` is the resume entry
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
    commits, the joiner sees its own fact arrive over the feed and self-promotes
    (`catchup_membership_transition`). Slice B
    added the growth-liveness redrive (the 1→2 promotion race), Slice C the `peer_ready` readiness gate
    (never admit a dead/lagging node into a quorum=all committee), Slice D the fresh-admission dial hint
    (a member can reach a brand-new member via the committed address — growth past 2 needs no manual
    mesh-seed), Slice E the weak-cert finalize guard (a laggard never locally finalizes a slot the honest
    network may not commit). Proven zero-pre-seed 1→4 in `growth_SUITE`. Live rollout rides Slice F.
  - **~~HOCON `genesis_hash` plumbing~~ — DONE** (the schema field + `quod_app` passthrough landed; a
    production `mode=join` node supplies the anchor via config — the Nomad job renders it, see
    `deploy/quod.nomad`).
  - **Instant N-member founding stays; independent creators are gone.** The `committee` config lets one
    canonical creator place the complete N=4 validator set in slot 1. `simplex_SUITE` then starts the
    other three validators through ordinary pinned join, so failover is testable immediately without
    allowing several nodes to invent competing slot-1 blocks. Live 1→N growth remains covered separately
    by `growth_SUITE`.
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
- **~~Independent multi-founder genesis~~ — REMOVED.** Exactly the lexicographically-smallest founding
  pubkey may run fresh `mode=create`; it generates a 32-byte incarnation, records it in the versioned
  genesis transaction id and the queryable `consensus_incarnation/1` fact, and commits the complete
  founding committee. Every other founding member joins that pinned anchor. A byte-identical wipe +
  re-found therefore gets a distinct consensus domain, while restart reuses the durable incarnation.
  There is no nonce-less reader or compatibility branch. Also: **`can_join` must stay side-effect-free** —
  the proof overlay captures every staged
  assert into the membership diff, so a `can_join` clause that asserts/retracts would ride ops into the
  committed membership transaction network-wide.
- **~~Vote-latch persistence across restart~~ — DONE (2026-07-22).** `quod_vote_journal` now owns one
  bounded `votes.0001` file per namespace. The only constructor for a new runtime share first appends a
  CRC-framed `{support|commit|complaint, Slot, BlockHash}` decision and calls `datasync`; only then may the
  signature enter the engine or transport. Boot reloads live decisions before recovery can vote, exact
  repeats are idempotent, and conflicting support hashes or final votes fail-stop. Finalization removes the
  slot from memory; at 1 MiB the remaining live decisions are rewritten and atomically renamed. No block,
  proposal, transaction, or KB data is copied. The restart tests exercise both complaint and commit through
  record → close → reopen → opposing evidence. The sync latency is exported as
  `quod_consensus_vote_journal_sync_seconds`, so its real finality cost is visible rather than assumed.
  Recovery trims only an incomplete final frame. A complete checksum/magic failure fail-stops even at EOF,
  deliberately stricter than the committed ledger's torn-append policy: a vote may already be visible to
  peers once its sync returns, so a complete record can never be discarded as though it were unacknowledged.
  The two stores share a frame shape but not a recovery contract; extracting only the header codec would not
  remove their load-bearing policy difference.
  Diskless reconstruction was rejected because peer echoes can prove that a vote happened but never prove
  that no unseen vote happened.
- **Finality view change + in-flight block availability (post-journal residual).** The current evidence rule
  directs an unlatched validator to skip when it sees `f+1` peer complaints and otherwise to commit a
  notarized block. One decision table owns notarization, ready recovery, complaint ingestion, and timeout
  triggers for both slots in the depth-one pipeline. This resolves the live slot-6180 shape once evidence is
  exchanged, but a sub-Delta photo finish can still put
  at least `f+1` validators on each final-vote side before either side sees the other's threshold. Durable
  latches correctly prevent switching, so resolving that already-formed split requires an explicit
  view/epoch recovery protocol, not another exception in the timeout FSM. Separately, certified-block
  anti-entropy reconstructs an in-flight block from any surviving holder; if every holder disappears after
  enough validators have commit-latched the block, no node can safely recreate its payload. A later
  availability layer (DispersedSimplex dispersal/erasure fragments or durable proposal storage) must close
  that bound. Do not claim unconditional liveness for arbitrary `>f` crash schedules until both are solved.
- **Runtime (P tier, agents Slice 2) — remaining follow-ups.** (1) *Validator-side
  declaration authorization*: `can_declare_runtime/3` is still conceptual — activation is gated
  solely by the full-term founding-block match in `quod_runtime`; the committee judging a
  declaration before commit (and lifting the founding-only restriction) lands with the
  authorization work after signing-based authz exists. (2) *Conditional Needs*:
  `state_handler` Needs are restricted to
  ground `current/1` edges; arbitrary condition goals return only with explicit skip-vs-error
  semantics and per-node re-arming (silent-fail + height-divergence hazards, DA2 C-B).
  (3) *Erlang heavy-job kinds + non-coalescable jobs*: heavy jobs are Prolog goals against the
  newest snapshot, always coalescable; per-worker declarations arrive with the first real
  worker (world/mesh, client-world-direction.md). (4) *Founding read cost*: `open_ro` rescans
  the whole log to read slot 1 (re-paid per KB restart); bound it store-side (checkpointed
  first-entry read) when compaction lands.
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
- **`may_commit/2` guard** — **DONE** (2c): gated at the commit-share emit; each round's complaint/commit
  latches make the two finalization paths mutually exclusive.
- **Oldest-head and mixed-camp recovery — DONE (2026-07-22).** The approval-frontier
  `active_slot` latch was deleted. An explicit `head_progress` state now watches `committed+1` through
  proposal, notarization, and final commit, so support certification cannot silently cancel finality
  recovery. A member that retained an unnotarized proposal while `unconfirmed` processes it through normal
  support or membership validation before complaining. Complaint signing pauses while fewer than a
  certificate quorum have a live
  authenticated inbound consensus stream and a fresh, stream-generation-bound report that they are caught
  up to the local committed height. Reports refresh every second and expire after three, so a restarted
  process's socket cannot count before its recovery FSM grants voting capability. Three readiness-restoration
  rearms are allowed per unchanged phase, after which flaps cannot extend the deadline. On the first
  pre-notarization timeout after quorum returns, an already-supporting follower re-echoes its support once
  before complaint becomes eligible.

  Final-vote recovery is one evidence-driven path for both live pipeline slots. `f+1` verified peer
  complaints cause an eligible unlatched validator to complaint-sign even after notarization; at most `f`
  complaints leave a quorum-sized commit side. The same decision table runs on live notarization, the ready
  edge, complaint ingestion, and timeout triggers. All first votes pass through the durable journal above;
  periodic redrive reconstructs only those recorded shares.
  A support certificate without its block starts bounded point-to-point recovery, rotating across certificate
  signers and then committee members. Any holder may answer, but the receiver verifies the certificate,
  block hash, parent, timestamp, payload, and local final-vote compatibility before ingestion. This replaces
  proposer-only availability without broadcasting full blocks every tick.
  A final certificate beyond the approved frontier revokes voting immediately and sends even a one-block
  gap through the existing verified durable-log recovery path.

  Retained leader proposals still use the bounded outbox. Committed committee changes close obsolete
  consensus links and discard their readiness, queued frames, pending dials, and block requests. Also
  closed the stale collecting-batch crash: a competing
  notarization nacks and removes the obsolete collection before advancing `approved`.
- **Loopback CT** — **DONE**: `simplex_SUITE` is a real 4-node OS-peer QUIC committee (commit, redirect,
  `leader_failover` = kill-leader → complaint-skip → rotated-leader-commit, and
  `over_fault_restart_recovers` = commit durable history → stop 2/4 → hold past Delta with both survivors
  withholding complaints → restart from disk → interrupted + subsequent writes commit without a
  namespace-wide restart).
- **Implicit predecessor commit** (spec §2.3.3) — **DONE for the depth-one runtime pipeline.** A child
  commit finalizes its immediate approved parent. The parent entry persists a self-contained proof
  (`#implicit_cert{support,parent-child link,child commit}`), and catch-up verifies it independently.
  Committee-changing blocks remain explicit-finality barriers.

### Latency tail under burst load — bigger refactors (post storage-fix, 2026-07-24)

**UPDATE 2026-07-25 — a controlled saturation test confirmed mailbox overload and throughput
collapse; it did not isolate the single mailbox as the sole root cause.**
Test: `OVERF=0` + all churn off, `BURST_PROB=100 BURST_SIZE=60 TICK=2` (~480 concurrent submits
sustained) on the N=9 fleet at the new 1024 MiB cap. Findings: (1) offering MORE load made the
fleet LESS productive — block rate dropped 5.7→1.3 slots/s and blocks went near-empty (tx/block
1.3→0.2), i.e. the flooded leader keeps proposing on schedule but can't pack the queued txs.
(2) The `quod_consensus_event_qlen` p99 split cleanly and BIMODALLY per node: 4 nodes stayed
shallow (~32–50 queued) while 5 flooded to the ~1000 top bucket. Since commit latency is
submitter-measured, txs through a shallow node commit <100ms while txs through a flooded node
take 2s+ — that is the visible bimodal tail. (3) The ROUNDS stayed fast throughout
(`round_approve`/`round_commit` p99 ≤100ms), so the seconds are spent before the measured round,
while the current leader receives followers' relay traffic and consensus evidence in one
`gen_statem` mailbox. The 300ms relay retransmit, speculative placement misses, synchronous
diagnostic probes, and queue head-of-line behavior all amplified that mailbox load; the test
did not attribute a percentage to each contributor. It was not a local network-only effect:
the Hetzner satellite and local compute nodes both flooded.
The fleet degrades GRACEFULLY (loadtest PASS, 9/9, 0 restarts, no OOM, snaps back the instant
load stops) but has NO headroom above ~moderate concurrency until this lands. Highest-leverage
fixes are reducing ingress amplification and measuring again before deciding whether a front
process is justified. See [[quod-nomad-deploy]] for the run details and the memory-cap fix
that preceded this (512→1024 MiB, an OOM, not this ceiling).

Context: the Ceph→local-disk storage migration removed the dominant cost (fsync 40-137ms →
~3ms; commit p50 929→40ms, p99 4900→~210ms). What remains is a **transient tail**: under
40-tx bursts the commit p99 occasionally spikes to ~1-2s, then self-heals. Measured root
cause (0.7.34/35 probes): a burst amplifies into a message storm that momentarily backs up
the SINGLE per-namespace consensus `gen_statem` mailbox (seen hit ~1000), which delays a
head slot's proposal/votes past Δ, so the slot **skips** (Δ-timeout), and every tx batched
in it waits the full Δ then retries. KB is small (4MB, GC not a factor) and steady event
rate is low (~11/node/s), so this is a burst-amplification + serial-process problem, not
saturation. The easy Δ-shrink lever is applied separately (see below); these are the deeper
fixes:

- **Ingress simplification — explicit exact-slot relay implemented and live-tested.** The
  park-queue (0.7.27) + pre-position-at-future-leader (0.7.28) machinery was built to cope
  with SLOW (Ceph-era) consensus, where the depth-1 pipeline couldn't keep up and appends
  piled into `busy` rejections. With ~40ms commits the pipeline keeps up, but the routing
  still runs and each miss is extra messages (relay → redirect → re-relay). The first replacement
  routed to one exact first-usable seat, acknowledged accepted relays to demote the retry cadence,
  and drains ordinary capacity-blocked work per author. Membership remains a global barrier so
  continuous writes cannot starve a committee transition. A routing-state key prevents the
  work-conserving drain from scanning the whole queue after unrelated mailbox events. Redirect
  budget exhaustion was retryable.

  The 2026-07-26 N=9 live A/B used the same no-churn workload in both runs: six bursts of
  60 concurrent submissions to every validator, 75 seconds active. With detailed event probes
  enabled the fleet advanced 914 blocks, transaction p50/p90/p99 were approximately
  0.62/1.78/2.44 seconds, append-mailbox p99 reached about 612, and the two-minute metric
  window contained approximately 6,300 redirects, 1,465 relay redrives, and 498 duplicate
  relay deliveries. With probes disabled it advanced 1,124 blocks (+23%), transaction
  p50 improved to about 0.44 seconds, and approve/commit p99 improved to about 125/46 ms,
  but transaction p90/p99 remained about 1.91/2.46 seconds. Redirects remained dominant
  (about 8,000 in the comparison window); no busy, malformed, overflow, expiry, unverified,
  transport-drop, crash, or restart signal moved. The exact-seat/ack rewrite therefore
  improves useful work and graceful recovery, but does not remove the tail.

  A sampled successful trace spent 1.23 seconds in the submitting node's append/relay span.
  The wrong target rejected it in 0.16 ms of its own CPU time; after the redirect, the final
  leader queued, proposed a 154-change block, and replied in 191 ms. Prolog proving took
  13 ms. Cross-machine timestamps cannot safely divide the remaining delay into wire time
  versus mailbox wait, but the single-clock spans locate it before the final leader's
  consensus round. This ruled out disk, signatures, and the final vote round, but the
  closed-loop workload could not yet distinguish mailbox delay from requests repeatedly
  missing the very short batching window; the fixed-work experiment below did.

  A rank-sharded stable-custodian successor was implemented and then rejected before
  deployment: the four-node integration test showed that assigning a request several
  proposer turns ahead manufactures empty complaint-skipped slots before the custodian can
  commit it. That trades mailbox distribution for worse latency and throughput and is not
  an acceptable consensus schedule.

  The definitive replacement keeps the earliest-usable-slot rule but makes each placement
  unambiguous on the wire:
  `{relay_submit, SubmissionId, AttemptId, CommitteeId, TargetSlot, Submission, Trace}`.
  Acknowledgement and result frames echo the same four placement fields. The receiver verifies
  it proposes `TargetSlot`, parks only under that exact committee view, and never invents a
  redirect from its own frontier. While that slot remains usable, later local sequences reuse
  the same lane. Origin-local finality resolves inclusion or exclusion; an excluded ordinary
  write retains its exact signed submission and moves internally to the next earliest usable
  seat. Receipt acknowledgement still demotes the 300 ms lost-send loop to a 5-second result
  probe. Relay creation enforces the single-target/single-slot lane invariant consumed by the
  O(1) route check.

  A fixed-work live comparison on 2026-07-26 then separated this routing change from
  the closed-loop load generator. For the same 960 offered operations, the exact-slot
  version committed 443 first attempts with p50/p99 40/142 ms; its parent committed
  only 137 first attempts, with p50/p99 118/237 ms, while most misses waited about
  30 seconds. The rewrite is therefore an improvement, not the source of the remaining
  tail.

  The fixed-work benchmark also identified that tail precisely. At the old 2 ms batch
  window, 720 successful operations required 1,349 HTTP attempts; every retry was an
  explicit slot-closed response, and every operation above 1.5 seconds had been proved
  and submitted six or seven times. The consensus round itself remained fast. Raising
  only the collection window to 25 ms reduced the same workload to 840 attempts,
  reduced proposed blocks from 115 to 53, and changed p50/p95/p99/max from about
  224/593/1546/1911 ms to 151/298/337/385 ms. A light 48-operation control added about
  21 ms to the median (44 to 65 ms) while removing all eight retries. The production
  default is therefore now a per-ontology 25 ms window, with batch-size, collection-wait,
  and caller-retry metrics. This is a measured batching correction, not the final
  architecture. The retained-custody milestone now unconditionally retargets
  the same signed transaction after a slot closes instead of asking the client
  to run Prolog again. There is one protocol behavior.

  A same-fleet A/B on 2026-07-27 removed the earlier fleet-age caveat. On the
  same aged N=8 committee, 1,920 fixed writes at 25 ms used 140 blocks and 405
  safe retries, with p50/p99 194/562 ms and 73.94 successful responses/s. At
  2 ms they used 470 blocks and 2,264 retries, with p50/p99 363/1,740 ms and
  72.74 responses/s. Thus 2 ms caused 3.36x the blocks, 5.59x the retries, and
  3.10x the p99 for no throughput gain. The fleet was restored to 25 ms after
  the comparison. This directly supports signed-transaction retention and
  internal retargeting; another fixed-window adjustment is not the next lever.
  The reviewed identities, safety invariants, quiesced protocol cutover, restart
  boundaries, and staged extraction are specified in
  [the ingress-owner contract](ingress-owner.md).

- **Consensus-process burst resilience (the serial mailbox).** All consensus for a
  namespace runs through one `gen_statem`; a 40-tx burst + its vote/cert fan-out can
  momentarily exceed its drain rate (mailbox → ~1000), stalling the head. Options, cheapest
  first: (a) shed/off-load non-consensus work handled inline — `get_stats`/`get_committee`
  are synchronous calls that block the statem; serve them from a cached projection updated
  on commit instead. (b) Coalesce redundant inbound (dedupe repeated share/redrive frames
  before they queue). (c) Split the hot path — a front `gen_server` that validates/dedupes
  frames and forwards only state-advancing events to the statem. (d) Full: shard consensus
  work per pipeline slot. (a)+(b) are medium effort and low risk; (c)/(d) are real
  architecture changes.

  The dedicated `{ingress, Ns}` stream is now separate from `{log, Ns}`, but both
  subscriptions still feed the same `quod_simplex` process, so the channel split
  alone does not reduce its serial mailbox. The next split is process ownership.
  Keep detailed probes off by default. Extract the complete ingress contract
  together: local unsigned submissions, authenticated relay envelopes,
  per-author sequence order, accepted acknowledgements, result hints, and
  committee-change barriers must have one owner. The extraction is deliberately
  staged after the definitive attempt relay and retained-custody semantics; see
  [the ingress-owner contract](ingress-owner.md).

- **Adaptive Δ instead of a fixed constant.** Δ is a single compile-time constant. It looks
  25× the *steady* round time (~40ms), so lowering it is tempting — but a lower FIXED Δ was
  TESTED (500ms, 2026-07-24) and was strictly WORSE: skips 4.4→12.4/node, p90/p99 blew from
  90/232ms to 10s. Under a 40-tx burst the single-statem mailbox backs up and a *healthy*
  round transiently exceeds 500ms, so Δ=500 spuriously skips it and the skip→retry feeds the
  storm. The lesson: Δ must cover the burst-tail round time, not the steady one, so a fixed
  low value is unsafe. The right fix is ADAPTIVE: track a rolling p99 of the actual
  propose→notarize time (the `quod_consensus_round_*_ms` histograms already emit it) and set
  Δ = k × that with floor/ceiling, so it's tight when calm and patient under a burst. Note
  this only makes skips cost the minimum SAFE amount — it does not remove the skips; the
  burst-amplification fixes above are what reduce their frequency. Reverted to Δ=1000ms.

- **Durable client idempotency for automatic write retry.** A transaction that has entered
  consensus cannot be cancelled when a local caller deadline expires. The current API now
  reports `{outcome_unknown, TxId}` and exposes that id through the explorer instead of
  falsely claiming failure; built-in test/load clients do not retry that outcome or a
  transport failure with no authoritative response. They retry only explicit responses
  that guarantee the operation did not apply. Fully automatic retry of non-idempotent goals
  still needs a client-supplied stable operation id plus a durable committed/pending lookup,
  so a reconnect can resume the same submission instead of proving and signing a new
  transaction. Do not implement this as a timeout tweak or an unbounded in-memory dedup set.

- **Two proof-visible reads bypass OCC capture (pre-token gap, found in the 0.7.62 review).**
  `current_predicate/1` (via the overlay's `get_interpreted_functors/1`) and
  `predicate_property/2` (via `get_procedure_type/2`, whose capture skip was deliberate for
  write-only checks) record no read-set entry, so a proof that branches on a predicate's
  existence/type commits with no dependency on it — a concurrent create/abolish of that
  predicate then validates as fresh on every node. Pre-existing under the phash2 scheme,
  unchanged by the exact-version tokens; producer and validator are symmetrically blind, so
  it is a capture gap, not a divergence risk. Fix by recording an existence-level dependency
  at both call sites (the enumeration result depends on every functor's presence, so the
  cheap sound version records the queried functor only for `predicate_property/2` and needs a
  considered design for the enumeration case). Decide with Yan before changing semantics.

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
- **P3 — bounded-cache subscribers (the millions tier).** Predicate cache
  (warmup = root schema + system-ontology registry) + consume the P2 feed +
  invalidate touched predicates on *live* commit (never replay) + lazy refetch
  through the authenticated ontology-ask API on miss.
- **P4 — per-predicate read-set routing** ("read-set is subscription") + cache GC (refcount + 60 s
  debounce, onia §10). The mutation-version read-set (`quod_erlog_db_mvcc:version_token/2`) already
  produces the per-predicate keys.

- **Link backpressure signalling (still useful; relay amplification mitigated).** `quod_link`'s plain
  `{send, Payload}` deliberately ignores `quic:send_data` returns (`{flow_control_blocked,_}`,
  `send_queue_full`) so transient pressure never tears a link down — the accepted cost is that frames
  can DROP SILENTLY on a live link under load. Each layer owns its own recovery today: the Δ redrive
  for consensus evidence and exact-request retransmit for relay. Relay now keeps the 300ms cadence only
  until the destination returns `relay_accepted`; it then uses a 5s result-hint recovery probe. This
  bounds amplification without assuming the original send succeeded. The link should still either
  signal backpressure to its holder (a `{link_backpressure,...}` message) or run a
  bounded in-link retry for consensus/relay frames (`send_reliable`'s `send_until_accepted` already
  exists in the link process — unused by consensus). Found during the event-driven-ingress review
  (DA, 2026-07-23); acknowledgement mitigation added 2026-07-26.

## 5. Parked (deliberately — don't reopen without a reason)

- **Adaptive view sizing** — deferred until the live-population estimate has been exercised under much
  larger churn. Brahms exposes `estimated_n`: a bounded cardinality sketch over owner-signed,
  expiring stable identities. It estimates the total live overlay component without copying a KB or a
  full membership list, but it is still an operational estimate and does not yet drive protocol sizing.
- **Partition heal** — a hard network split does not auto-recover (seeds read once at boot). Fix when
  needed: periodic re-seed from Consul.
- **Quiesced relay cutovers** — stop new writes, drain custody and attempt caches, replace the committee,
  verify the code-defined capability on every member, and only then resume writes.

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
