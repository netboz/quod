# Identity / signing milestone — kickoff brief

> **Superseded (2026-07-02).** This milestone was **absorbed into the DispersedSimplex consensus
> milestone** — Ed25519 signing is exactly what Simplex votes/certs need. Node keypairs
> (`node_id` = pubkey), `sign/2`/`verify/3`, mutual TLS, and the commit-cert core have since landed; see
> `doc/simplex_extended.pdf` and the `quod_simplex` / `quod_identity` module docs. Kept for context.

> Paste the **Kickoff prompt** below into a fresh chat to start this milestone. Everything under it
> is the brief that prompt points at. Work happens in **plan mode** first — Yan reviews and comments
> the design before any code is written.

---

## Kickoff prompt (paste this)

```
Start the identity / signing milestone for quod. Work in PLAN MODE: explore the code read-only and
present a plan via ExitPlanMode for my approval/comments BEFORE writing any code — I want to review
the design first.

Read these before planning:
  - doc/identity-milestone-kickoff.md   (the full brief — motivation, scope, decisions, done-criteria)
  - doc/deferred.md  §1 + §2            (the identity gate + transport-hardening items it closes)
  - CLAUDE.md and the memory index      (conventions, versioning rule, no-backcompat, no-timeouts)

The brief lists the open architectural decisions I most want to weigh in on (node_id = pubkey vs
address; QUIC mutual-TLS as the identity proof; id→address resolution; what gets signed; key
provisioning in the Nomad deploy; staging). Bring me a plan that takes a clear position on each,
with the trade-offs, so I can comment.
```

---

## Why now — the motivation (don't lose this)

We pivoted to identity **because of a concrete deploy blocker**, not as abstract hardening:

A node's identity is its address, `server_id() = {Host, Port}`. When a node moves hosts (a Nomad
reschedule, `distinct_hosts` reshuffle, or host failure) its IP changes → its id changes → it falls
out of its **own** durable committee config. That already broke the founder when climbing past the
first deploy. And running 5 → 7 → N nodes on only 3–4 physical hosts means **multiple nodes per
host**, which address-based identity handles only by fragile pinning.

So the milestone's first job is to **decouple identity from address**: a node keeps a stable,
host-independent identity wherever it runs; the address becomes a mere routing hint that can change
freely. That unblocks scaling the live deploy to 5/7/N. The security half (signed messages, commit
certificates) is the same milestone because it's the same keypair — and it closes the hostile-net
gaps that are currently only *bounded* (see deferred.md §1).

This is the named "big gate": the reader/subscriber arc (P2 epidemic dissemination → P3 the millions
tier) cannot proceed without it, because a subscriber must verify a **relayed** commit without
trusting the relay.

## Definition of done

1. **Host-independent identity.** A node has a keypair. `node_id` derives from the **pubkey**, not
   `{Host, Port}`. Membership config (the durable Raft log) records the stable id; the address is a
   resolvable hint, not the identity.
2. **Deploy scales.** A node survives a host move with its id intact; multiple nodes per host are
   trivially distinct (no static-port-one-per-host limit, no host pinning). Demonstrated: founder +
   joiner + replica stable across a redeploy, then grow to 5, then 7 nodes.
3. **The deferred.md §1 security items close** (or are deliberately staged):
   - redirect authentication on the join path (signed `#join_reply` bound to a proven leader key);
   - pubkey-possession gate **before** `can_join` runs;
   - signed blocks + per-block **quorum certificate** + a verify API (the prerequisite for P2);
   - authenticated remote reads on the `{prove, Ns}` endpoint;
   - re-tighten the non-`[safe]` decode for anything accepted from a relay (deferred.md §2).
4. **Green + clean.** Existing suites unaffected (`quod_ledger_tests`, `join_SUITE`,
   `raft_safety_SUITE`, `replica_SUITE`, `quic_SUITE`); a new identity/signing suite; `xref` clean;
   no new `dialyzer`.

Staging is an open decision (see below) — a clean split is **(a) identity + addressing** (unblocks
the deploy, ship + scale) then **(b) signing + certificates** (closes the security gaps).

## Current state — accurate pointers

- `server_id() :: {inet:hostname(), inet:port_number()}` — `include/quod_ledger.hrl:11`. Used as the
  key for `conns`, `outbox`, `rx`, `next_index`, `match_index`, `votes`, `voted_for`, `leader_id`,
  every `member_op()`, and the vote/append records throughout `src/quod_ledger.erl`.
- Reserved-but-unused identity surface already in the records: `pubkey()` type + `pubkey = none` in
  `#join_request` (`include/quod_ledger.hrl:78`); `#transaction.author` (= node id today) + `sig`
  reserved with `sig = none`. No commit certificates exist.
- **QUIC already does TLS** with a single **shared static** cert/key —
  `priv/certs/cert.pem` / `key.pem`, loaded in `src/quod_quic.erl:64-67` (`load_cert/load_key`).
  This is the clean hook: a **per-node keypair → self-signed cert → mutual TLS** authenticates the
  peer's pubkey at the transport layer, so "I'm talking to pubkey X" comes for free and the address
  is just where X happens to be.
- The dial path: `quod_ledger` keys outbound links by `server_id` (`conns`/`outbox`); the actual
  connect goes through `src/quod_link.erl` → `src/quod_conn.erl` → `src/quod_quic.erl` to an
  address. Today id *is* the address, so there's no resolution step — the milestone introduces one.
- Gossip carries `{ip, port}` as NodeId and does **not** verify identity —
  `src/quod_brahms.erl:55-57` ("the gossip layer does not yet verify identity").
- Join path entry points to re-secure: `dispatch_join_request/4`, `handle_join_reply`,
  `start_admission` in `src/quod_ledger.erl` (deferred.md §1 names each).

## Open architectural decisions — take a position, I'll comment

1. **`node_id` = pubkey (or a hash of it)?** And the **address** becomes a separate, dynamic hint.
   How is id→address resolved when we need to dial a peer we only know by id? Options to weigh:
   address hints carried alongside ids in membership/gossip; a resolution cache populated from
   inbound authenticated connections; Consul/seed lookup. (Membership must stay address-free so a
   move doesn't rewrite the log.)
2. **QUIC mutual-TLS as the identity proof.** Make each node's keypair its TLS identity so the
   handshake authenticates the peer pubkey (replacing the shared static cert). Recommended — it
   gives authenticated transport with no extra protocol — but confirm it fits `quod_quic`/`quicer`.
3. **What gets signed, and at what layer?** Per-`#transaction` author signature? Per committed
   **block / AppendEntries** quorum certificate (the P2 prerequisite)? Both? Define the verify API
   and where it runs (apply path vs relay-accept path).
4. **Key management / provisioning in the deploy.** Where do node keypairs come from on the Nomad
   cluster — generated on first boot and persisted to the per-node CSI volume, or provisioned via
   config/secret? This directly shapes `deploy/quod.nomad` and the volume layout.
5. **Staging.** One milestone in two shippable phases (identity+addressing, then signing) vs all at
   once. The deploy-scaling payoff lands at the end of phase (a).
6. **Membership trust.** Today `can_join` is default-open on root. With real identities, does
   admission still trust the operator seed/`can_join`, or does possession-of-pubkey + `can_join`
   together gate it (deferred.md §1)? Keep peer = validator ≠ user (no global peer/user directory) —
   see the `quod-state-and-next` memory.

## Constraints (must honor)

- **Greenfield — NO backward compat.** Change `server_id`'s type, wire formats, records, the TLS
  cert scheme, and volumes freely. Wipe the CSI volumes for a clean re-found. No migration machinery.
- **Versioning rule.** Every commit bumps **only the patch (last) digit** of the version (the deploy
  image tag in `deploy/quod.nomad` + the docker build tag). Never touch major/minor — Yan owns those.
  HEAD is `0.6.2`.
- **Threat model: hostile network.** This milestone is what lets several defenses move from *bounded*
  to *closed*.
- **Plan mode first.** No code until Yan approves the plan; present it via `ExitPlanMode`. He may
  take minutes to reply — **do not** use wakeups/short timeouts to chase him.
- **Conventions.** OTP 27+ `-moduledoc`/`-doc` Markdown (not EDoc `@doc`); real Markdown, public API
  only — see CLAUDE.md.

## Read order

`doc/deferred.md` (§1 + §2) → `include/quod_ledger.hrl` → `src/quod_ledger.erl` (server_id usage,
`dispatch_join_request`, `handle_join_reply`, `start_admission`, the `conns`/dial path) →
`src/quod_quic.erl` (TLS cert load) → `src/quod_link.erl` + `src/quod_conn.erl` →
`src/quod_brahms.erl` (gossip NodeId) → `deploy/quod.nomad` + `deploy/volumes/*.hcl` →
`~/.claude/plans/delightful-giggling-reddy.md` (the reader arc this gate unblocks) → `CLAUDE.md` +
the memory index.

## Verification (end state)

```
rebar3 eunit
rebar3 ct --suite test/identity_SUITE      # new: keypair id, mutual-TLS auth, signed-block verify
rebar3 ct --suite test/join_SUITE          # join/promote unaffected by the id change
rebar3 ct --suite test/raft_safety_SUITE
rebar3 ct --suite test/replica_SUITE
rebar3 xref && rebar3 dialyzer
```
Then the deploy-scaling proof: a node survives a host move with its id intact, and the cluster grows
to 5 then 7 nodes with multiple nodes per host.
