# Deferred work — central registry

A living list of **deliberately-postponed work and known gaps**, with enough context to pick each
up later. Cross-cutting and milestone-gated items live here; day-to-day TODOs stay in code as
`AI:` / `REVIEW(...)` markers.

When you close an item, delete it from this file. When you defer something during a review, add it.

---

## 1. Identity / signing milestone — the big gate

The next major milestone. Today `server_id() = {Host, Port}` (spoofable), `#transaction.author`/`sig`
are reserved but `sig = none`, and there are no commit certificates. Until nodes have keypairs and
messages/blocks are signed, several hostile-network defenses can only be **bounded, not closed**.

Gated on it:

- **Redirect authentication (join path).** A joiner acts on any `{redirect, X}` reply. Only a signed
  `#join_reply` bound to a proven leader key closes it. *Bounded now:* only a not-yet-committed
  member reacts, and `contacts` is capped (`?MAX_CONTACTS`). → `quod_ledger:handle_join_reply`.
- **Pubkey-possession gate before `can_join`.** An unauthenticated joiner still triggers a `can_join`
  proof. Require it to prove possession of its advertised `pubkey` first. *Bounded now:* concurrent
  proofs capped at `?MAX_ADMITTING`. → `quod_ledger:start_admission`.
- **`can_replicate` policy.** A full-copy read-replica holds *every* fact, so admitting one is a
  **confidentiality** decision for access-controlled ontologies. Root is public, so reusing
  `can_join` is fine today; add a `can_replicate` rule before replicating private ontologies.
  → `quod_ledger:admit_replica`.
- **Authenticated + rate-limited remote reads.** The `{prove, Ns}` endpoint accepts a link from any
  node (reads are open; content is gated per-clause by `can_read`). A hostile network can flood links
  and proofs. *Bounded now:* `?MAX_INFLIGHT` proofs, `?MAX_FRAME_BYTES` per frame. → `quod_prove`.
- **Signed blocks + per-block quorum certificate.** Required for the **P2 epidemic dissemination**
  (§4): a subscriber must verify a *relayed* change without trusting the relay. Re-tighten the
  non-`[safe]` decode for any block accepted from a relay.

## 2. Transport hardening (hostile-net)

- **Non-`[safe]` decode** (`quod_ledger:decode_record`, `quod_prove:inbound`). Any on-channel speaker
  can deliver arbitrary terms (atom-table growth). Deliberate so fact atoms decode; closed by
  signed/validated payloads (§1). Size-bounded: `quod_prove` caps frames at 1 MiB, `quod_ledger` at
  ~`?CHUNK_BYTES`.
- **Per-peer reassembly heap** (`quod_ledger` chunk reassembly). Spoofed peers each start an
  incomplete chunked message → up to N×64 MiB buffered. Needs a per-message timeout / a cap on
  concurrent reassemblies.
- **`quod_prove` large results.** A prove result > 1 MiB (`?MAX_FRAME_BYTES`) is dropped — no
  app-level chunking. Add chunking (like `quod_ledger`'s) if large read results are ever needed.
- **`quod_prove` outbox on `link_error`.** A buffered read is dropped and the caller times out (5 s)
  then can retry. Intended eventual behavior; an app-level retry/backoff in `remote/5` would fail
  faster.

## 3. Raft membership (M3 / M4 fast-follows)

- **`remove_member` / leader-removes-itself** (symmetric M4). **When it lands:** restart the join
  driver on loss of committed membership — a committed `{remove, Self}` would otherwise strand a node
  that already stopped asking (the join driver stops at committed-membership).
- **Snapshot / compaction / InstallSnapshot** (M3 heavy half). Only needed once history is trimmed;
  nothing compacts yet (`snap_idx = 0` always).
- **Ra-style round-based promotion.** quod promotes a learner once its `match_index` reaches a fixed
  target (its admission index); Ra (rabbitmq/ra) promotes only if a replication *round* completes
  within an election timeout — avoids promoting a node that will perpetually lag a busy committee.
  Fine for low-write ontologies; revisit at high write rates.
- **Brahms-candidate discovery for joiners.** Joiners use the operator seed list as the contact path;
  Brahms `view`/`sample`-based discovery is a later refinement.

## 4. Reader/subscriber arc — the path to "millions read root"

P1 (read-replicas + remote-read) is built. Plan: `~/.claude/plans/delightful-giggling-reddy.md`.

- **Identity / signing** (§1) — the gate for everything below (can't safely gossip unsigned blocks to
  untrusted nodes).
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
