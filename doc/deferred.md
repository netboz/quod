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
- **Membership SAFETY — Byzantine committee-packing (the #1 open membership gap).** Admission is currently
  safe only under **trusted/honest submitters**: `can_join` is proved ONLY on the submitting node (peers
  apply the committed `peer_admitted` diff via OCC without re-proving `can_join`), transaction writes are
  **unsigned** (`sig=none`), and `acceptable_change(#transaction{})` accepts any membership tx. So a
  Byzantine/stale submitter can commit an unauthorized `peer_admitted` — packing the committee past the `f`
  bound, admitting a node `can_join` would reject, or shifting `quorum/1`. Fix (three parts): (a) **re-prove
  `can_join` on every node** at proposal-validation / apply, dropping a committee-changing block that fails
  locally; (b) **Phase-B transaction signatures** so only an admitted signer's membership tx is accepted
  (the write-gate = membership trick from onbrater); (c) a **BFT fault-tolerance floor guard** on committee
  SHRINK, enforced at the apply/propose gate on **every node** (not just in the `remove_1` predicate) — it
  must refuse to drop below `3f+1` viability. **Note (code-review 2026-07-04):** the current empty-committee
  floor lives ONLY inside the `remove_1` predicate, so a **raw `retract(peer_admitted(...))` transaction, or
  a single tx retracting every member, bypasses it** and empties the validator set; `leader/2 []` then keeps
  the statem from crashing but the namespace **wedges** unrecoverably. `acceptable_change(#transaction{})`
  accepting any membership tx is the same gap. The real floor is the per-node re-validation of (a) — the
  predicate guard is honest-path-only. (`remove`'s retract-by-pattern already keeps the KB and the validator
  set in lockstep, and the predicate floor now counts distinct pubkeys.) Until this lands, membership is
  **crash-fault-only**.
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
- **Join cold-start + trustless catch-up** — Stage 3: `mode=join` (a node joins knowing only a **contact
  address**, deleting the co-founder scaffold — the `committee` config + `simplex_SUITE` co-founding
  setup), and a joiner that pulls blocks via Brahms sampling and **verifies each block's commit cert**
  (never trusts the server). Genesis trust anchor delivered out-of-band in config (founding keys / genesis
  hash), never TOFU'd. A joiner must special-case slot 1 (`cert=none` — verify against the pinned anchor,
  never `verify_cert(none,_)`). Absorbs the old `remove_member` / join-driver / candidate-discovery
  concerns; a non-voting **replica** tier is a further slice (no learner/replica tier exists today).
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
  (`quod_ledger_store`'s `snap_cfg`/`read_snapshot` are unused today — `read_snapshot` returns `none`, so
  the full log always re-folds.) No non-voting tier exists anymore.

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
- **P2 — epidemic dissemination.** Push-pull gossip + anti-entropy over the per-namespace Brahms
  overlay (Replicas/Subscribers join it); every block carries + is verified against its quorum
  certificate before re-push. Scales the change feed past the leader-star.
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
