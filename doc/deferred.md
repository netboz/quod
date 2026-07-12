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

- **Signed blocks + relayed-commit verification.** Required for **P2 epidemic dissemination** (§4): a
  subscriber must verify a *relayed* block against its commit cert without trusting the relay. The cert
  machinery exists (`quod_simplex:verify_cert/2`); wiring it into the P2 feed and re-tightening the
  non-`[safe]` decode for relayed blocks is the remaining work.
- **Membership-path hardening.** Committee admission has since landed (committee = `peer_admitted` facts +
  `admit`/`remove` external predicates, membership rework Slice 1+2). The HARDENING is the deferred
  membership-safety work in §3: redirect authentication, a pubkey-possession gate before `can_join`, signed
  membership transactions, per-node `can_join` re-validation, and a `can_replicate` policy for private
  read-replicas. NOT carried forward from the deleted `quod_ledger` code.
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
  *other* transport crash still forces peers to re-dial in before this node can reach them. Fix when
  needed: give the ETS table an `heir`, or re-seed on `init` from a persisted/config source.
- **Cold-start address bootstrap.** A node can only dial a peer by pubkey once that peer's endpoint is in
  the resolver — populated *only* by inbound link headers (`quod_link:learn_hint`) today. So a node
  cannot initiate to a peer it has never heard from. Consensus co-founding survives because the
  leader broadcasts first (everyone learns it, then dials back); the `simplex_SUITE` CT papers over the
  gap with explicit `quod_quic:learn` pre-seeds. The homogeneous end-state (matches onbrater/onia): the
  committed `peer_admitted(NodeId,Host,Port,Pubkey)` fact IS the address book, seeded at join by an
  operator contact list. Lands with **Stage 3** membership; until then, watch it in the multi-node Nomad
  redeploy (a non-leader that must reach a peer it hasn't received from will stall).
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
- **Stream prioritization for signaling (RFC 9218) — deferred.** quod already gives each channel its own QUIC
  stream (`{log}` consensus, `{feed}` dissemination, `{catchup}`, Brahms), so loss-induced head-of-line
  blocking between them is already avoided. But all streams on one connection share ONE congestion window, so
  under heavy feed load consensus signaling contends for bandwidth. The `quic` lib supports
  `quic:set_stream_priority/4` (RFC 9218 urgency 0–7) but quod doesn't use it — mark `{log}`/`{catchup}`
  high-urgency and `{feed}` lower so votes preempt bulk dissemination under congestion. (Bandwidth is also
  partly isolated today by the accidental two-conns-per-peer split — consensus by pubkey, feed by address; the
  clean end-state is ONE connection per peer + prioritization.)

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
  (`quod_simplex:committee_from_log/1`), swapped in-process at commit (`adopt_committee/2`), and re-folded
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
    missing in the KB). A `valid` verdict emits the deferred support share; `invalid` latches `#s.invalid[Sl]`
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
- **Mid-flight committee-change / stale-cert hazard (code-review 2026-07-04, from the S1 cert-persistence
  slice).** Because the committee can change on ANY slot (a `peer_admitted` assert/retract) and shares are
  ingested un-gated by height, a node that is LAGGING across a committee-changing slot N can `form_cert`
  slot N+1's finalizing cert under the OLD (pre-change) committee's smaller quorum, then finalize N+1 with
  it. A catch-up joiner reconstructs the committee **as-of** N+1 (the NEW set) and would reject that block
  (too few sigs). S1 mitigates the *persisted* cert (`persisted_cert/4` re-minimises to the distinct valid
  sigs of `eng.validators` = the committee-as-of-slot, so a padded/relayed cert can't bake junk into the
  log and a caught-up node persists a correct minimal cert; a lagging node persists `none`). But the ROOT
  fix — never *finalize* a slot under a stale committee — is deferred: either re-verify `detect_commits`
  against the committee-as-of-slot before emitting `{committed}`, or **freeze the validator set per epoch**
  (the deferred epochs work) so a slot's voting set is unambiguous. Intersects the membership-safety gap
  above (unsigned, per-slot-mutable membership). Until it lands, catch-up trusts that finalized slots were
  finalized under the correct committee — safe in a trusted fleet, not Byzantine.
  **Seam in place (0.6.25, Slice D):** the "who votes / leads / disseminates now" reads route through a
  single function `quod_simplex:active_validators/1` — the **active voting set**, held distinct from the
  committee **facts** (`#s.validators`). Today it is the IDENTITY over the facts (epoch length 1); the
  epoch-freezing work adds an epoch snapshot field + boundary detection and rewrites `active_validators/1`
  to return the set frozen at the epoch's start, so a mid-epoch facts change stops moving the voting set —
  it does NOT have to re-find the read sites. This is a landing pad, not the fix.
- **Join cold-start + trustless catch-up** — **DONE (Stage 3 / Simplex 4, S1–S5a):** the machinery
  (`quod_catchup`: persist each block's finalizing cert, an off-consensus catch-up server, the inductive
  forward-verifier, and the driver loop) plus the `mode=join` wiring in `quod_simplex`. A `mode=join` node
  boots UNFOUNDED (empty log ⇒ `validators=[]`, `slot=0`), and a monitored worker drives `catch_up/3` from
  its seed contacts: pull a window → `verify_forward` each cert against the committee it reconstructs → hand
  the verified window back to the statem (`sink_catchup`) to append + **replay into the KB as it lands** →
  advance, until caught up. The genesis (slot 1, `cert=none`) is anchored against the out-of-band-pinned
  `genesis_hash` (config), never TOFU'd; `quod_simplex:genesis_hash/1` exposes a founder's anchor. A
  caught-up joiner is a **read-only observer** — not in its own `validators`, so `is_participant/2` drops
  live consensus traffic and refuses appends (`not_in_charge`). Covered by `join_SUITE` (found N=1 → commit
  a fact → a `mode=join` node catches up over loopback QUIC → proves the fact from its OWN KB, stays a
  non-member). **Resume + hardening (from the S5a review, all landed):** a `mode=join` node re-enters catch-up
  on EVERY boot (empty OR partial log), and `start_join_worker` RESUMES from the persisted height (`slot+1`,
  committee-as-of-that-slot) — so a crash/redeploy mid-catch-up never re-appends its on-disk prefix (the store's
  `assert_contiguous` would throw) nor treats a partial log as complete (`maybe_mark_ready` stays gated until
  `join=done`). `catch_up/5` is the resume entry (skips the genesis anchor past slot 1). `is_participant/1`
  requires `join ∈ {none,done}` so a window that folds the joiner's OWN pubkey can't flip it live over a stale
  engine. `{ok,0}` from an empty/lying contact is a retry, not a false "done". `valid_cfg` fail-fasts a bad
  `mode` or a `join` without a `genesis_hash` anchor (no silent zombie). Covered by `join_SUITE`'s
  full-namespace-restart resume case. **Still deferred from here:**
  - **Admission to voter (S5b)** — a caught-up joiner becoming a committee **member** (an existing member
    proves `admit`, the `peer_admitted` commits, the joiner sees itself in `validators` and starts voting).
    Today catch-up ends at a read-only node; nothing promotes it.
  - **HOCON `genesis_hash` plumbing** — the anchor reaches `quod_simplex` via the ns Config, but
    `quod_schema:fields(content)` has no `genesis_hash` key and `quod_app:build_ns_config` doesn't forward one,
    so a PRODUCTION `mode=join` node has no way to supply the anchor yet. Guarded (not silent): `valid_cfg`
    now fail-fasts such a node at boot. No production joiner exists yet (the Nomad job is N=1), so add the
    schema field + passthrough when the multi-node deploy lands (rides S5b / the N=1→join deploy work).
  - **The co-founder scaffold STAYS** (decided 2026-07-05, reversing the plan's "delete it"): the `committee`
    config + `simplex_SUITE` co-founding is the ONLY way to stand up the 4-node BFT **failover** committee,
    and join can't replace that until it can co-found N≥4 via sequential admissions. Revisit after S5b.
  - **Read-replica (stay-synced) tier** — a caught-up `join=done` non-member already TRACKS the head off
    the feed: it drops the consensus `{log,Ns}` traffic (not a voter), but `quod_feed` carries it forward —
    eager-push when it has a Brahms overlay, and (since the readiness gate) digest→verified-pull off the
    committee members even without one. What is unbuilt is a durable replica **tier** with its own policy:
    a `can_replicate` admission gate, retention, and snapshot bootstrap — the reader-arc work (§4).
  - **Brahms-sampled contacts** — catch-up pulls from the static `seed_peers` contact list, not a Brahms
    sample; sampling + multi-contact failover is a hardening slice.
- **Multi-founder genesis is not enforced byte-identical.** Each co-founder builds its slot-1 genesis from
  its OWN config, with no parent-hash chain to catch a mismatch (slot 1 is self-committed; consensus starts
  at slot 2). Mismatched co-founder addresses → divergent `peer_admitted` addresses per KB (the
  pubkey-committee stays consistent, so consensus is unaffected). `simplex_SUITE` passes matching
  `{Pk,Host,Port}` so genesis is identical; a real multi-founder deploy must too, or add a genesis-hash
  cross-check. Also: **`can_join` must stay side-effect-free** — the proof overlay captures every staged
  assert into the membership diff, so a `can_join` clause that asserts/retracts would ride ops into the
  committed membership transaction network-wide.
- **Failover liveness in the client-driven model (Stage 2c follow-ups).** quod has no timed/empty slots
  (a slot exists only on a client `append`), so a complaint is *evidence-gated*: a node arms its Δ timer
  only when it proposes a slot, supports a proposal, or gets a local write it can't lead. Consequences,
  deferred: (a) **f+1 complaint amplification** — a node should join a complaint after seeing `f+1`
  distinct complaint shares (guarantees ≥1 honest complainer), so a client that reaches only `f+1` nodes
  (not a full quorum) still triggers a skip; today the client must reach ≥ quorum live nodes. (b)
  **pending-tx forwarding** — a follower that can't reach the dead leader broadcasts the pending
  `#transaction` (`{pending,Slot,Change}`) so every live node gets first-party evidence from ONE
  submission (can't skip an honest-live-leader slot); intersects tx authenticity (`sig=none` today), so
  parked with Stage-3 signing. (c) **complaint retransmit** — the Δ timer re-arms while a slot stays
  stuck (retransmits our complaint), but per-*message* retransmit for lost support/commit shares is still
  send-once + the dial tick (§2 hardening).
- **Notarized-but-orphaned slot can deadlock (Stage 2c gap — the head advances on the COMMIT cert, not on
  notarization).** A validator that commit-signs slot `V` can never complain it (`may_complain` uses
  `commit_signed`), so if `V` gets a bare-quorum *support* cert (notarized) but then the leader dies before
  a *commit* cert forms, the notarizers are barred from complaining and the non-notarizers are too few to
  reach a `⅔` complaint cert → `V` can neither commit nor skip, and the head never advances (no recovery
  even after synchrony resumes — the latches clear only in `finalize`). 2c's failover survives a leader that
  dies *before* notarizing (the `leader_failover` CT case), but NOT one that dies *after* a bare-quorum
  notarization (needs a second slow/absent follower, so it's a >f / asynchrony corner, but permanent).
  Textbook Simplex avoids this by advancing the view on **notarization** and treating finalization (the
  commit cert) as the deeper guarantee. The real fix is to **decouple head-advance from the commit cert**
  (advance on the support/notarization cert; keep the commit cert as the relayed-finality proof) — a Stage-4
  protocol change; until then a mid-round leader crash on a bare quorum can wedge a namespace. The
  `leader_failover` CT does not cover it (killing the leader *before* it proposes is not the trigger).
- **Snapshot / compaction** — later; nothing compacts yet (apply-and-forget keeps the KB projection, the
  store keeps the full block archive). **When it lands it must preserve the committee:** the validator set is
  now re-derived by folding `peer_admitted` asserts/retracts over the FULL committed log
  (`quod_simplex:committee_from_log/1`), so a snapshot that truncates the log must carry the `peer_admitted`
  facts as of the snapshot height (or a committee checkpoint) — otherwise the re-fold drops members.
  (The Raft-shaped snapshot stub — `read_snapshot`/`write_snapshot`/`install_snapshot` + `snap_cfg` —
  has been **removed** from `quod_ledger_store` along with the rest of the Raft term/vote/truncate
  machinery; compaction will be built fresh and **committee-aware**, since the Raft `snap_cfg`
  `[node_id()]` shape was wrong for the `peer_admitted`-derived committee anyway.) Note: the store
  now deliberately hard-codes **base index 1** (a log starting higher is treated as corruption — the
  earlier half-support was an untested trap), so compaction must introduce its base marker and the
  committee checkpoint TOGETHER, plus consumers that read from `first` instead of 1. No non-voting
  tier exists yet.

**From the 2a/2b/2c reviews — mostly landed; two remain open:**

- **Contiguous commit-apply** — **DONE** (2b): `commit_buf`/`drain_commits` buffer out-of-order
  finalizations and apply strictly in slot order (generalized in 2c to also carry skips), so the store's
  contiguity check never sees a gap.
- **Proposed-slot latch** — **DONE** (the non-pipelined `#s.proposing` latch: a second concurrent append
  gets `{error,busy}`, so a slot is never double-proposed and no parked `From` is overwritten). What's
  left is only **pipelining** (>1 slot in flight, next slot from the in-flight tip) — a Stage-4 throughput
  optimization, not a safety gap.
- **`may_commit/2` guard** — **DONE** (2c): gated at the commit-share emit; `complained`/`commit_signed`
  latches make commit-vs-complaint mutually exclusive per slot.
- **Loopback CT** — **DONE**: `simplex_SUITE` is a real 4-node OS-peer QUIC committee (commit, redirect,
  and `leader_failover` = kill-leader → complaint-skip → rotated-leader-commit).
- **Implicit predecessor commit** (spec §2.3.3) — STILL OPEN: committing a block implicitly commits its
  whole predecessor prefix; needed once the pipeline lands (a slot can commit via a successor's commit
  cert). Today each slot commits only via its own commit cert (`detect_commits`).

## 4. Reader/subscriber arc — the path to "millions read root"

P1 (read-replicas + remote-read) is built. Plan: `~/.claude/plans/delightful-giggling-reddy.md`.

- **Relayed-block verification** (§1) — the remaining gate below: safely gossiping blocks to untrusted
  nodes needs each relayed block verified against its commit cert (the signing itself has landed).
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
    Derive it from the network-size estimate quod already computes — `fanout ≈ clamp(k·ln(n̂), lo, hi)`
    off the Brahms KMV `estimated_n` — part of the parked "adaptive sizing" bucket (with the Brahms
    view/sample sizes). Watch `feed_dropped{reason=duplicate}` vs `ingested` to tune `k`.
- **P3 — bounded-cache subscribers (the millions tier).** Predicate cache (warmup = root schema +
  system-ontology registry) + consume the P2 feed + invalidate touched predicates on *live* commit
  (never replay) + lazy-refetch via remote-prove (P1) on miss.
- **P4 — per-predicate read-set routing** ("read-set is subscription") + cache GC (refcount + 60 s
  debounce, onia §10). The `quod_diff` functor-hash read-set already produces the per-predicate keys.

## 5. Parked (deliberately — don't reopen without a reason)

- **Adaptive view sizing** — SHELVED. The KMV `n̂` self-under-sizes at scale; the correct path (if ever
  needed at hundreds+ nodes) is a churn-hardened push-sum counter, not the KMV. `view_size = 16` fixed.
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
