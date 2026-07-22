# Content Layer Design — Proved Scopes over QUIC

**Status:** historical design notes; the core content and consensus layers are implemented.
**Date:** 2026-06-25.
**Scope:** the reasoning that led to quod's ontology/content layer. For current behavior,
read `content-layer.md`, `simplex_extended.pdf`, the module documentation, and `deferred.md`.

> **Update (2026-07-02):** the consensus choice recorded below (§6, §12, §13 — "hand-roll a lean
> **Raft**") has since been **superseded**. quod's ordering layer is now a hand-rolled **DispersedSimplex**
> BFT (`quod_simplex`, which replaced the removed `quod_ledger`) — see the consensus plan and
> `doc/simplex_extended.pdf`. The per-namespace committee / block-list / apply framing here still holds;
> read "Raft" as "DispersedSimplex" and `quod_ledger` as `quod_simplex`. §13's own "Make the agreement
> stronger later — same interface" is exactly the move that landed.

This is a thinking document, not a spec. It records the decisions we reached and
the questions still open. Inspiration is taken from onia (Architecture-H),
`bbsvx`, and `onbrater`, but deliberately **simpler and broker-free**.

> **New here? Read `content-layer.md` first** — a plain-language overview of the
> whole design. This document is the detailed decisions, trade-offs, and caveats
> behind it.

> **Historical reading note.** Several sections intentionally retain rejected alternatives and the
> original build sequence. They explain decisions; they are not a status report or implementation spec.

---

## 0. The one idea everything hangs on

**Everything is a *staged proved scope*.**

When the network proves a goal, it runs the goal optimistically against a
staging overlay. The goal returns its **bindings** (the solution — the variable
values) up to the calling ontology, and leaves behind two things:

- **read-set** — the facts (and the ontologies) the proof *looked at*.
- **write-set** — the facts the proof *changed*.

(Backtracking yields the *next* bindings on demand; the read-set and write-set
keep growing across solutions — see §5 *Backtracking*.)

That pair — the closure of everything the proof touched — is the **proved
scope**. It is the unit the network re-checks and agrees on. Relations,
cross-ontology calls, conflict detection, notification, and consensus are all
*views over the proved scope*, not separate subsystems.

The agreed pillars:

1. **Proved scope is the central primitive.** (§2)
2. **The inter-ontology graph is the central standing structure** — produced by
   proved scopes, consumed for routing and notification. (§3)
3. **`::` is explicit**, one operator with two positions. (§4)
4. **Commit is uniform _within an ontology_**: a scope commits iff *its owning*
   transaction commits. Cross-ontology atomicity is **opt-in, not default** (§5).
5. **Every fact write is an ordered transaction in its own namespace's log** —
   per-namespace ordering, never one global chain; cross-ontology atomicity is
   opt-in over just the touched set. (§6)
6. **No broker.** Facts and scope dialogs ride reliable QUIC streams; physics
   rides QUIC datagrams. (§7)

---

## 1. The core reframe — content is two things, not one

Content is **durable structural facts** *and* **dynamic state (physics)**. They
want opposite transports and opposite guarantees, so they must not share a path.

| | Durable structural facts | Dynamic state (physics) |
|---|---|---|
| Examples | `isa`, `instance_of`, `have_attribute`, ACL, admission | positions, velocities, anything ticking |
| Change rate | rare | constant |
| Loss tolerance | none (must converge) | high (next tick fixes it) |
| onia treats it as | committed kb (**D**) | in-memory derived state (**P**), *never* in the log |
| Transport | reliable, ordered (QUIC stream) | lossy, fast (QUIC datagram) |

onia already keeps physics **out** of the durable log. So "physics spread across
all ontologies" is not a fact-store problem — it is a separate fast lane (§7).

> *Caveat (review):* "change rate: rare" is true for *schema* facts (`isa`,
> attribute definitions) but **false** for *instance / gameplay state* ("who
> holds the sword", "is the door open") — those change fast *and* must be agreed,
> so they pay full ordering latency (§6) and can't ride the lossy physics lane.
> There is no "fast *and* agreed" lane yet. See §12.

### What bbsvx already learned about physics

bbsvx has a working physics layer; its lessons shape ours:

- **Owner / ghost authority.** Each `physical_space` has exactly **one authority
  node** (the node that created it — sticky, anti-hijack). The authority
  simulates full bodies in a real engine (Rapier); every other node holds
  read-only **ghosts** (kinematic, positions set from broadcasts); static bodies
  are owned everywhere. *No rollback* — the authority is correct by definition,
  ghosts converge. Forces/impulses/joints apply only on the authority: a node
  can't shove an entity it doesn't own.
- **Lossy fast broadcast, not ordered.** State spreads via Plumtree eager-push
  (~1–5 ms), **not** EPTO total order (~85 ms). Deliberately lossy: the authority
  broadcasts *all* owned states at ~30 Hz, batched with collisions, deduped by
  source+timestamp; an old batch is overwritten within ~33 ms, so dropping it is
  free. This validates our datagram fast-lane (§7).
- **Reads off the critical path.** Position/velocity reads hit an **ETS handle to
  the engine** directly (`body_position/2` …), never a gen_server call — a
  latency fix worth copying.
- **Tick is authority-local, unsynchronised.** 30 Hz on the authority; ghosts
  passively receive. No cross-node tick sync → temporary divergence is accepted
  (convergence over consistency).

Pain points they hit, and the fixes — all worth pre-empting:

| Problem | Fix |
|---|---|
| Physics process tied to a 5 s-watchdogged worker, died with it | dedicated persistent supervisor, decoupled lifetime (#233) |
| Brutal-kill left stale ETS blocking world re-create | self-heal: clear stale entry at init |
| Delayed tick → huge Δt → bodies tunnel through thin colliders | clamp Δt ≤ 100 ms |
| Runaway bodies drift to infinity, burn CPU | hard position bound (±1000 m), cull |
| Broadcast bounce-back reprocessed | record own batch source+ts, drop dups |

**The cross-ontology wrinkle for *us*:** a moving entity has a single authority,
so cross-ontology physics (a force from space A on a body owned by space B) can't
be a local write — it must be a request to B's authority. That is exactly a `::`
call into B (§4) and it must respect B's ownership. So physics is a fast *lane*,
but cross-ontology physics interactions still route through the proved scope.
(Open question in §11.)

---

## 2. The central primitive — the staged proved scope

### Why you can't classify a goal up front

In Prolog you cannot know, before running a goal, whether proving it will
`assert`/`retract` somewhere in its derivation — and once it crosses ontologies
you cannot know *which* ontologies it will touch either. Both are discovered only
by running it. So routing by a predicted "read vs write" type is impossible.

### So decide *after* execution (optimistic concurrency control)

Run the goal against a staging overlay, let it touch whatever it touches, and
capture its read-set and write-set. The classification falls out of running it:

- **wrote nothing** → it was a read → validate the read-set by attestation →
  done, fast (§6).
- **wrote something** → it is a transaction → append it to the namespace's
  ordered log (§5, §6).

### Staging is prototyped (port from bbsvx)

erlog's DB interface is a behaviour; the DB handle is threaded through `#est{}`,
so a proof can run against a swapped-in backend. bbsvx already builds the
staging layers on top of this (see §8). Per-proof copy-on-write + commit/drop is
**prototyped** there — a pattern to port. *Caveat (review):* §8 itself lists
semantics bbsvx left open, so "port" includes resolving those (§12).

External side effects (sending a message, a physics push — onia's **E**
category) cannot be rolled back, so they must be **deferred until after commit**.
onia already does this.

### What a fact is (and what the read/write-set hold)

- **A fact** is a Prolog clause `{Head, Body}` (`Body` empty for a plain fact).
  Its **identity is its content** — `{Head, Body}` only. Asserting the same
  content twice dedups; retract is by content. (bbsvx confirms: dedup/conflict
  hashing strips everything but `Head`+`Body`.)
- **Per-fact metadata = a pointer to the log transaction that asserted it.** That
  transaction already carries who emitted it (caller namespace), when, the order
  (log index), and the signature — so we do *not* copy bbsvx's namespace
  **provenance chain** into the fact. bbsvx needed that chain only because it had
  no per-namespace ordered log and forwarded facts through subscription
  federation; we have the log, which gives per-fact provenance for free. (Add the
  chain back only if we ever cache foreign facts.)
- **write-set** = the `differ`'s ordered op-log of asserts/retracts (each tied to
  the committing transaction).
- **read-set** = the `differ`'s per-functor content hashes — what the proof
  looked at, for conflict-check and notification. *Caveat (review):* this is
  **per-predicate** (a whole functor hashed as one), **not per-fact** — so two
  writes to *different* facts of the same predicate falsely conflict, and one
  fact change notifies *every* reader of that predicate. Per-fact granularity is
  a decision owed (§12).

### Reads: a goal emitted from a caller ontology

A goal is never free-floating — it carries the **caller namespace** (the emitting
ontology), the way onia carries its `subject`. So the read API is just:

```
prove(TargetNs, Goal, CallerNs) -> bindings
```

A read **is** a proved scope with an empty write-set: proved against the local
converged log, with **bindings returned to the caller** (not auto-asserted into
it). `CallerNs` is first-class even in MVP — it is what the read-set→notification
index (§3) and `::` ACL key on. The agent/client machinery (wielding, sessions)
is onia's L3 concern; quod only exposes `prove`. **Cross-namespace reads see the
target's latest committed state, recording the log height read** (§3) — no
snapshots to retain. *Caveat (review):* reading two namespaces (B then C) can
**mix moments** — B may move between the reads — so a cross-namespace read is
**not** a consistent snapshot across ontologies (read skew). Tolerated for MVP;
flagged in §12.

---

## 3. The inter-ontology graph

### Relations and `::` calls are the same thing at different sizes

- A **relation** like `isa(cat, animal)` that crosses a boundary is *a fact
  proven across that boundary* — a tiny proved scope (read one thing, write
  nothing).
- A **`::` call** is *the same move, bigger* — prove a whole goal across the
  boundary.

Same mechanism, different size. There is no separate "relation network" and
"cross-ontology call" feature — there is one primitive.

### The graph emerges; we index it

The graph's **arcs are proved scopes**; its **labels are the relation
functors**. We do not author it as a separate map — proving *populates* it (via
cross-ontology reads), and we maintain it as an **index/cache** for two
purposes:

- **Routing (pull):** to send a `::` call, look up which node hosts the target
  (see *Finding the target node* below).
- **Notification (push):** the **read-set is the subscription**. When a fact
  changes, the nodes to notify are exactly the proved scopes that *read* it. You
  never declare a subscription — reading B's fact *is* subscribing to it. The
  relation label gives differentiated routing. (This is the "notify others
  quickly when something happens to an ontology" requirement — *caveat (review):*
  today it fires **per predicate**, not per fact, see §2/§12.)

Because relations can be *derived* (proven by rules, not just stored), the graph
is a **runtime trace we cache**, not a static authored structure. Same "run it to
find the scope" principle as §2.

### Finding the target node

The graph gives you the target *namespace*; you still need a *node* that hosts
it. Three cases:

1. **You're a member of the target namespace** → you already hold its Brahms
   membership, and the nodes in that view *are* the nodes hosting it. Pick one (a
   write/scope contacts one; a read picks f+1 for attestation, §6). *Caveat
   (review):* being in the Brahms view ≠ hosting the fact log — membership and the
   replica set aren't necessarily the same, so this needs defining (§12).
2. **You're not a member** → you need a directory: namespace → some hosting
   nodes. The clean, dog-fooding answer is that **the directory is itself an
   ontology** — a well-known root namespace every node joins, carrying low-rate
   `hosts(Ns, Node)` facts merged as a CRDT (last-writer-wins, periodically
   republished), read from a hot ETS cache. This is exactly bbsvx's
   `bbsvx_contact_service` (namespace → {host,port}, gossiped ~60 s, LWW). Routing
   is then just another proved scope over the root ontology.
3. **Cold / unknown** → ask any peer "who hosts Ns?" and let it answer from its
   directory; once you reach one hosting node you learn the target's Brahms view
   and refresh from there.

So: **Brahms view when you're in the namespace; a CRDT contact-ontology when
you're not.** No new mechanism — the directory is content like everything else.
*Caveat (review):* the LWW directory is the one **AP/lossy** piece (concurrent
host registrations can be dropped), and "routing is just a proved scope" hides a
cold-start bootstrap cycle (case 3 is the real entry point). See §12.

### Two layers, two lifetimes — it is *not* QUIC-connections-between-ontologies

| Layer | What it is | Lifetime |
|---|---|---|
| **Logical edge** | a relation fact (qualified name) | **durable** — replicated with the ontology, lives as long as the fact |
| **Physical traversal** | a QUIC stream that walks the edge | **ephemeral** — one scope-prove (the "dialog room"; dies when the prover leaves) |

An ontology is *not* a node — it is hosted by a **set** of nodes. To walk edge
A→B, a node holding A opens a **per-proof stream** (`quod_link`) on the
**already-standing per-peer connection** (`quod_conn`, kept alive by Brahms) to a
node holding B. Connections are between nodes and reused; the graph itself is
content, not wires. This stream replaces bbsvx's WebSocket `scope_ws`.

---

## 4. The `::` operator

> **Update (2026-07-16): superseded by `doc/inter-ontology.md` (normative).** The operator
> story changed: there are now TWO marks — `:` builds *names* (`isa(my_dog, animals:dog)`,
> ontology names carry their owner: `user_xxx:door`) and `::` marks *asks*
> (`animals::diet(dog, D)`). Link-following is **default-on for every relation** with a
> `no_follow` opt-out (no fixed set of link-following predicates), followers are synthesized
> at read time (never stored), and the hop strips the matched prefix. Read this section as
> history: its one-operator/two-positions framing and its fixed link-follower set are
> superseded.

### Explicit, not implicit

Default: the next fact/goal is **local** to the current ontology. `::` is the
**only** way to reach another ontology. This avoids needing a global
"who owns this predicate" directory and the name-clash problems implicit routing
would have.

### One operator `Ns::Term`, two positions

- **Goal position** — `..., animals::diet(dog, D), ...` → "prove this goal in
  `animals`." Qualifies the **predicate**. (This is bbsvx today.)
- **Argument position** — `isa(my_dog, animals::dog)` → "`dog` lives in
  `animals`; references to it resolve there on demand." Qualifies the **name**.
  This is what turns cross-ontology edges into **first-class data** (the graph
  of §3).

### Name-position reduces to goal-position

Argument-position `::` is a *convention on top of* goal-position: a small fixed
set of **link-following predicates** (`isa`, `instance_of`, `have_attribute`, …)
notice a `::`-tagged argument and re-issue themselves as a goal-position call into
that ontology. **One mechanism**, not two; both bottom out in the staged proved
scope.

### When a foreign name triggers a trip

The rule: **a foreign-tagged name causes a cross-ontology trip only when one of
the link-following predicates has it as its *subject* and actually runs.** Storing
the fact, unifying it, passing it around — all stay local and free. It is one
clause per relation:

```prolog
have_attribute(Ns::Class, Attr, Val) :- Ns::have_attribute(Class, Attr, Val).
isa(Ns::Class, Super)                :- Ns::isa(Class, Super).
```

Properties:

- **Lazy** — the hop happens only when that rule runs (when the foreign property
  is actually needed), never when the name merely appears.
- **Cheap** — no global "where does this live?" check on every term; only these
  few predicates look, and only at their subject.
- **Self-limiting** — if the fetched thing itself points to a third ontology, the
  same predicate hops again, walking the trail; the existing `::` depth-limit +
  cycle guard caps it.
- **Splits the example right** — `isa(my_dog, animals::dog)` answers "is my_dog a
  dog?" from the local fact (no hop), but "what does my_dog eat?" goes through
  `have_attribute`, meets `animals::dog` as subject, and hops.

Which predicates are link-followers is itself the "differentiated routing by
relation" of §3: each relation decides how (and whether) it follows.

### Phasing

Build **goal-position first** (simple, already working in bbsvx). Add
**argument-position** (the link-following clauses above) when the relation graph
needs first-class edges. Same operator, not a fork.

---

## 5. Commit semantics

**Uniform rule (one line):**

> A scope commits **if and only if** the transaction that opened it commits.

- **self** is the degenerate case: the scope's DB *is* your own, so writes are
  visible to you immediately and commit with you. (bbsvx special-cased self only
  to dodge a `gen_statem:call`-to-self deadlock — an implementation detail, not a
  semantic difference, so nothing principled to preserve.)
- **local / remote**: the foreign write is the *owner's* transaction — see
  *Foreign writes* below.

### Foreign writes: the owner executes — ACL forces this

Concrete case: a rule in **GAME** moves a sword from a chest into a player's bag,
which lives in **INVENTORY** — a different ontology, on different nodes.

GAME can't splice that fact into INVENTORY directly, because **INVENTORY owns its
own access control and its own write-side logic** (who may write, plus the
effects, defaults, and derivations a write triggers — onia's `effect/4`,
inherited `have_attribute`, …). Authorising *and* running that logic is
INVENTORY's job, so a foreign write is necessarily **a request the owner executes
through its own rules** ("INVENTORY, add this sword"), not a ready-made diff. ACL
is the visible reason; the general one is that the owner's write path is its own
program. (bbsvx already works this way: `::` runs the goal on the *target's*
actor, in the target's overlay, under the target's ACL.)

This collapses the earlier "two ways" — there is really **one write mechanism:
the owner executes.** What stays open is only **commit-coupling**:

- **Independent:** each ontology commits its own writes separately. GAME commits
  "removed from chest"; INVENTORY commits "added to bag." Simple, but a crash/
  timeout between the two **loses or duplicates the sword**. Fine only for genuinely
  independent effects.
- **Coupled:** several owner-executed writes wrapped in one all-or-nothing step —
  a real distributed commit across *only* the touched ontologies (2PC, or BFT for
  the untrusted slice). No out-of-step window; needs the coordination protocol.

> *Caveat (review):* the doc originally made **independent the default** and called
> coupled "rare." That is backwards — the sword move *is* the conserve-a-resource
> case (transfers, trades, crafting), which is the **common** case and needs
> coupled. And "healed by compensation" has **no general construction** for
> effect-bearing Prolog writes (a write fires rules/effects others may have acted
> on). **Decision owed (§12):** default to coupled for conserved resources; define
> the coupling protocol (the MVP avoids it only by forbidding foreign writes).

**MVP:** allow only **own-ontology writes + cross-ontology reads**. Reads commit
nothing on the target, so there is no cross-node commit to build yet — the whole
problem is deferred until foreign writes are actually needed.

### Backtracking

> **Update (2026-07-16): the cursor model below is REJECTED — bbsvx/onia heritage.** Yan
> declared those attempts deprecated; their session/cursor machinery (cursor held on the
> answering side, InvocationId, `next`/`close` dialogs) is exactly the leak/DoS surface the
> caveat below feared, and bbsvx's commit history confirms it. The replacement
> (`doc/inter-ontology.md` §4): answers are **streamed** — the target runs the goal in a
> per-ask worker against a frozen view and sends each answer as it is found; the asker's
> choice point consumes them as they arrive; cancel = the ask's stream closing kills the
> worker. **Nothing is ever parked on the answering side**, so the cursor-lifecycle problem
> (§12 #9) is dissolved, not solved. The paragraphs below are history.

A `::` call is not one-shot — the caller can backtrack into it for the next
solution. The mechanism (bbsvx and onia §16 agree):

- The **cursor lives on the answering side** — the choice points (`#erlog{}`
  state) stay on the target, addressed by a unique **InvocationId** per `::` call.
- The caller drives it with **`next`** (onia's dialog room: `prove` / `next` /
  `close`). Each `next` advances that cursor and returns the **next bindings**
  (the binding-return of §0). When the caller's engine backtracks into the `::`
  choice point it sends a `next`; `close` (or the stream dying) ends it.

> *Caveat (review):* an open cursor holds the **full interpreter state** on the
> answering node until `close`/stream-death. Without per-caller caps + an idle
> timeout that is a memory-leak / DoS surface — cursor lifecycle is a decision
> owed (§12). *(Dissolved by the streamed design above.)*

**Backtracking and staged writes — we stay ISO Prolog-compliant.** Verified in
erlog: the choice point (`#cp{}`) captures bindings + variable counter but **not
the db**, so backtracking does *not* undo `assert`/`retract` — they persist,
exactly as standard Prolog (and bbsvx/onia) already behave. We adopt that as-is:
**no savepoints, no db-rewind machinery** — the db behaviour module stays simple.

The only consequence (a write from an abandoned search branch persists in the
diff) is standard Prolog and is the rule author's concern, handled the usual way:
**writes are effects applied *after* the solution is found, not interleaved with
the search** (onia's effect model). Then backtracking only ever rewinds bindings —
which erlog does natively — and there is nothing to undo. Savepoints stay in the
back pocket only if we ever want true tentative-write-and-backtrack, which the MVP
does not. (One ISO fine-print to confirm is erlog's *logical update view*
conformance — whether an assert is visible to a call already iterating the same
predicate — but that's an erlog detail, not a quod design decision.)

---

## 6. Consensus — where, and how much

### Reframing "must be Byzantine at the transaction level"

Agreed on the *goal* (trustworthy results in an untrusted network); disagreed
that the *mechanism* is "everything through one global blockchain." The mechanism
matches the operation:

| Operation | Mechanism | Speed |
|---|---|---|
| **Any fact write** | append to the **owning namespace's ordered log** (single sequencer to start, hardening to consensus) | log/block time |
| Goal results (reads) | **quorum attestation** (f+1 matching signed answers), or recompute locally | one round-trip |
| Cross-ontology atomic (rare) | coordinate the touched namespaces' logs (2PC / BFT) | slow, opt-in |
| Physics | datagram, last-writer-wins, no log | best-effort |

The key move: **every fact write is an ordered transaction within its
namespace.** Each ontology is its own per-namespace ordered log of diffs; every
node applies the same diffs in the same order, so retraction, deletion, and
"is this absent?" are all well-defined **with no CRDT machinery** — the log order
*is* the tie-break. The proved-scope's read-set is validated *at the write's log
position* (did anything it read change since it ran? — if so, abort/retry), which
gives serializability **within a namespace**. *Caveat (review):* it does **not**
compose across namespaces (a proof reading B then C can mix moments — read skew),
and because the read-set is **per-predicate** (§2) conflicts are detected per
predicate, not per fact. There is also no contention story (backoff, retry cap)
for hot facts. See §12.

This works because the rate is right:

- The facts that change **fast** (who holds the sword, is the door open) are
  exactly the ones nodes **must agree on** — they need ordering anyway; a CRDT's
  "fast path" would be unsafe for them.
- The facts that are **cheap/monotonic** (schema: `isa`, attribute definitions)
  change **rarely**, so ordering them costs nothing.
- The genuinely high-frequency stuff — physics — is already on the separate lossy
  datagram lane (§7), off the log entirely.

So there is no fact class that wants a CRDT fast-path, and we **drop CRDT for the
fact store**. (CRDT/LWW is still fine for *soft routing state* like the contact
directory of §3 — that is not the fact store.)

> *Caveat (review):* two honest consequences. **(1)** The middle bullet's "fast
> facts need ordering anyway" means those facts pay full ordering latency and we
> have no "fast *and* agreed" lane — the "ordering is free" framing only holds for
> the genuinely-rare schema facts. **(2)** Dropping CRDT is a **CAP choice**: an
> ordered log is **CP**, so under a network partition the side that can't reach
> the sequencer/quorum **cannot write** (and may not read latest) — that namespace
> is unavailable there. Stated, not hidden. The monotonic schema subset is a
> legitimate AP/CRDT candidate worth reconsidering (§12).

### What ordering buys, and how heavy it must be

A per-namespace total order = **arbitration of conflicting writes** + a clean,
replayable, auditable history — which is why bbsvx (EPTO) and onia (Tendermint)
both built on an ordered log, and why Prolog *needs* it: `retract` +
negation-as-failure make order carry meaning, so a CRDT (which converges to *a*
set, not the intended derivation) is the wrong substrate.

How heavy the orderer is varies **per namespace**:

- **Single sequencer per namespace** — simplest; fine for a dev / single-operator
  cluster.
- **Consensus (Tendermint or lighter)** — when operators distrust each other, for
  the security-critical namespaces. Byzantine.

> *Caveat (review) — this is the doc's biggest gap.* The single sequencer is a
> **single point of failure and crash-fault-only**: it can equivocate, censor, or
> halt the namespace — the exact faults Brahms exists to resist. It is also
> **undesigned**: *which* node sequences, how it's chosen, how it fails over, how
> non-sequencer nodes replicate and apply in order, and where the log is persisted
> are all unspecified. And "harden to consensus later" is a **commit-path rewrite,
> not a config knob** (single-sequencer needs no agreement, view-change, or
> quorum-certificates; BFT needs all of them). **Designing this is the next task
> (§12).**

---

## 7. Transports — no broker

Everything rides the existing QUIC mesh (`quod_quic` / `quod_conn` /
`quod_link`); nothing reintroduces a broker (vs onbrater's in-VM ejabberd/MQTT,
which also brought a GPL cliff).

- **Facts / scope dialogs** → reliable, ordered **QUIC streams** (`quod_link`).
  A scope dialog is one stream per prove invocation; the closed stream *is* the
  "requester left, cancel" signal that MQTT needed a session hook for.
  *(Update 2026-07-16: the per-ask-stream idea survives, but the mechanics are
  TWO legs, not one bidirectional stream — quod's transport never replies
  backwards on a peer-opened stream. The normative wire shape is
  `doc/inter-ontology.md` §4.2.)*
- **Physics / dynamic state** → **QUIC datagrams** (`send_dgram`, already noted
  in the QUIC-optimizations memo). Unreliable, last-writer-wins, no log. This is
  the "UDP" instinct — placed on the dynamic half, where loss is fine.

The earlier "MQTT vs UDP" question resolves to: **neither** — reliable QUIC
streams for facts/scope, QUIC datagrams for physics, both over the same
connection.

---

## 8. Machinery to port from bbsvx

> **Update (2026-07-16): bbsvx and onia are DEPRECATED attempts — nothing is "ported" from
> them conceptually.** The overlay/differ layers listed below were already rebuilt as quod's
> own (`quod_erlog_db_local_prove`, `quod_diff`). The `pred_cross_ontology_call` row is
> superseded by `doc/inter-ontology.md` (streamed asks, no scope sessions, no federated read
> path); at most its caller-side choice-point mechanics serve as a low-level reference.

The staged-proved-scope model already exists in prototype in bbsvx, in layers
over erlog's DB behaviour:

| Module | Role |
|---|---|
| `bbsvx_erlog_db_local_prove` | shadow overlay; asserts/retracts staged per functor, never touch the real ETS; `get_local_changes/1` = the write-set; drop = rollback |
| `bbsvx_erlog_db_differ` | records every write as a diff op + a content hash per functor read = read-set / MVCC conflict detection |
| `bbsvx_erlog_db_federated` | cross-ontology reads (subscriptions): reads merge across ontologies, writes stay local |
| `bbsvx_actor_ontology` `scope_prove` / `scope_commit` / `scope_drop` | the cross-ontology transactional wrapper: prove in an isolated overlay, commit the diff as one transaction or drop it |
| `bbsvx_common_predicates` `pred_cross_ontology_call` | the `::` handler: self / local / remote resolution, backtracking via compiled choice points, chain-depth limit + circular-call detection, caller identity propagated for ACL |

~~**Port, don't reinvent**~~ — *superseded (2026-07-16): per the banner above, nothing
is ported from bbsvx; the overlay/differ layers were rebuilt as quod's own and the `::`
handler is specified fresh in `doc/inter-ontology.md`. The tensions bbsvx left open
(read-only comment vs writes-via-scope; self/local/remote semantics; explicit `::` vs
the implicit `federated` read path) are all resolved there.*

---

## 9. Boundary to onia

Decision: **quod-native API first**, not a strict clone of onia's L1 boundary.
Later, expose an adapter matching `onbrater_host:prove/2,3` + `submit_event/2` +
`{onbrater_event, Ns, ...}` so onia plugs in as a git dep behind its narrow
boundary (onia §11/§15).

One known leak: onia's `Index` (a deterministic *cluster-wide* order on events)
assumes the ordering layer (§6). Until that exists, a local per-node monotonic
index is fine for a dev/single-operator cluster — flag it, don't pretend it's
cluster-wide.

**Identity stance.** *Updated 2026-07-14:* a node's `node_id`
is now its **Ed25519 pubkey** (the address is a routing hint), and connections are bound
to that key via **mutual TLS**. Simplex votes and quorum certificates are Ed25519-signed
and verified. *Updated 2026-07-18:* every non-genesis transaction also carries a
namespace-bound author signature, verified by receiving validators before
voting and by every node during rebuild and catch-up;
followers relay those exact signed bytes to the current leader. Still unfinished:
the authorization policy that consumes authenticated authors. ACL-enforced
foreign writes (§5) and open membership remain gated on that policy; the
trusted-fleet boundary still applies to who may request a write.

---

## 10. Original proposed phasing (historical)

This sequence predates the running content engine and DispersedSimplex implementation.
Current gaps and priorities live in `deferred.md`.

1. **Single-node content engine** — wire erlog per namespace (fills the
   `quod_prolog` TODO in `quod_sup.erl`); staged proved-scope proving (port
   `local_prove` + `differ`); a **per-namespace ordered log** (single sequencer to
   start) so every node applies the same diffs in the same order; local
   goal-position `::`. *Caveat (review):* as scoped this exercises **no
   distribution** (remote `::` is Phase 2), runs single-operator with signing
   stubbed (§9), and its hardest dependency — the ordered log itself — is
   **undesigned** (§6/§12) and must be designed before this ships. The genuinely
   distributed, useful-to-onia milestone is the *end of Phase 2*, not Phase 1.
   (The ordered log is now **sketched in §13** — per-namespace DispersedSimplex.)
2. **Inter-ontology graph** — index cross-ontology reads; read-set-driven
   notification; remote `::` over QUIC streams (replace `scope_ws`);
   argument-position `::` (the link-following clauses of §4).
3. **Physics lane** — QUIC datagram broadcast for dynamic state, LWW, no log.
4. **Hardening** — per-namespace sequencer → consensus (Tendermint or lighter)
   where trust demands; quorum attestation for reads; cross-ontology atomic
   coupling for the rare cases that need it.

---

## 11. Open questions

**Settled this session** (folded into §2/§4/§5/§6):

- **Fact representation + read-set/write-set** — content-identity facts + a
  pointer to the asserting log transaction; write-set = op-log, read-set =
  per-functor content hashes (§2).
- **`::` argument-position** — link-following predicates; trip only when one has
  the foreign name as its subject (§4).
- **Reads** — `prove(TargetNs, Goal, CallerNs) → bindings`; a read is a
  proved scope with an empty write-set (§2).
- **Backtracking over staged writes** — stay ISO Prolog-compliant (asserts
  persist on backtrack, as erlog/bbsvx/onia already do); no savepoints, db module
  stays simple; speculative writes handled by the effects-after discipline (§5).
- **Cross-namespace read consistency** — read the target's latest commit, record
  the height; no snapshots (§2/§3).
- **Consensus model** — per-namespace ordered log; CRDT dropped for the fact
  store (§6).

**Still open — all deferrable past the MVP:**

- **Cross-node coupled commit** — the rare atomic case: 2PC vs small consensus
  over the touched ontologies, coordinator-failure handling, crash vs Byzantine.
  *Phase 4.*
- **Attestation quorum** — f+1 vs 2f+1; can the relation label set the policy per
  edge? *Phase 4.*
- **Physics** — adopt owner/ghost authority (§1); how a cross-ontology force
  reaches the owner without per-tick commit latency; authority handoff. *Phase 3.*
- **onia boundary convergence** — when to add the `onbrater_host` adapter. *When
  onia needs it.*

---

## 12. Open issues from the design review

A devil's-advocate + architect review surfaced these. None breaks the core model;
all are real gaps or decisions owed before building. Roughly in priority order.

1. **The ordering layer is undesigned — the big one.** §6 names a "single
   sequencer per namespace" but gives no design: *which* node sequences, how it is
   chosen, how it fails over, how non-sequencer nodes replicate and apply in
   order, where the log is persisted. A single sequencer is also a **single point
   of failure, crash-fault-only** (it can equivocate/censor/halt — the faults
   Brahms exists to resist), and "harden to consensus later" is a commit-path
   rewrite, not a knob. **Sketched in §13** (one committee per namespace,
   1-voter→N, protocol pluggable behind a stable log API).

2. **Read-set is per-predicate, not per-fact.** The ported `differ` hashes a whole
   functor's clauses, so conflicts *and* notifications fire per predicate. Decide:
   build per-fact granularity, or accept and document per-predicate (false
   conflicts + notification fan-out).

3. **Cross-ontology atomicity default.** The sword move is the lost/duplicated-item
   hazard; "independent commit by default" is unsafe for conserved resources
   (transfers/trades/crafting) — the common case, not rare. "Compensation" has no
   general construction for effect-bearing writes. Decide: **coupled by default**
   for conserved resources; define the coupling protocol (deferred to Phase 4, but
   the motivating example needs it).

4. **Identity and signing landed; authorization remains.** `node_id` is the
   node's Ed25519 **pubkey**, connections are bound to it via mutual TLS,
   transactions carry namespace-bound author signatures, and blocks carry quorum
   certificates. ACL-enforced foreign writes (§5) still need an author-aware
   capability policy; authentication alone does not grant write permission.

5. **No "fast *and* agreed" lane.** Instance/gameplay facts are high-rate *and*
   need agreement, so they pay full ordering latency and can't use the lossy
   physics lane. Decide: add a fast-but-agreed mechanism (per-key single-owner
   serialization), or scope quod's log to structural facts only.

6. **Durable history vs. stateless deploy.** *Decided (§13):* keep the **full block
   list durably on disk** so the history is permanent and browsable (a ledger) — a
   deliberate exception to "no disk," for the history only. Current facts aren't
   saved separately (they replay from the block list). Cold boot = reload own
   history and/or catch up from the committee. Trimming old history is opt-in,
   later.

7. **CAP stance is implicit.** Ordered logs are CP — under partition the side that
   can't reach the sequencer/quorum is unavailable for that namespace. State it
   per fact class; reconsider keeping CRDT for the monotonic schema subset.

8. **Membership ≠ replica set.** Being in a namespace's Brahms view doesn't mean
   you host its log. The replica set (and the `f` in "f+1 attestation") needs its
   own definition.

9. **Cursor resource bounds.** ~~Open `::` dialogs hold full interpreter state on the
   answering node; need per-caller caps + idle timeout~~ — **DISSOLVED (2026-07-16)**: the
   streamed-ask design holds no server-side cursor at all (`doc/inter-ontology.md` §4).
   What remains is the per-proof hop budget for link-following fan-out — specified there
   (chain depth cap + per-position hops).

10. **erlog engine concurrency model.** Likely one gen_server per namespace
    serializing commit/apply, with read-only proofs on copy-on-write overlays —
    state it; getting it wrong is a rewrite.

11. **Cross-namespace read-set validation seam.** Connect "record the read height"
    (§2) to the notification index (§3) and commit-time validation (§6) into one
    explicit path — this is where cross-ontology serializability actually lives.

12. **Contention management.** OCC needs backoff + retry cap + a fallback to
    pessimistic single-owner for hot keys, or hot facts livelock under load.

---

## 13. The committee and the history — how an ontology is ordered and stored

**Status: proposed, not finalized.** This is the design for §12 #1 (and it settles
#6 and #8). Prior art: one small agreement group per shard (TiKV, CockroachDB call
it *multi-committee*), and the BFT quorum-certificate recipe quod adopted —
**DispersedSimplex** (`doc/simplex_extended.pdf`).

### One committee per ontology

Each ontology is run by a small **committee** — say 3 or 5 machines — that holds it
and agrees on every change. ("Committee" is the plain name; in consensus terms it's
the validator set / agreement group.)

- One member is **in charge** at a time. It takes incoming changes, bundles them
  into the next **block**, and sends that block to the others. A block becomes
  official once **more than half** the committee has written it down.
- If the one in charge dies or goes silent, the others **pick a new one among
  themselves** in a second or two. Automatic — no human, no config edit.
- The committee is the authority for *changing* the ontology. *Reading* it is a
  separate, much cheaper thing (see below).

The smallest committee is **one machine** — just "one machine in charge," the
simple dev setup. Grow the same committee to 3 or 5 and it survives some of them
dying: **same code, more members.** So "simple now" and "robust later" are one
thing, dialled by committee size.

### Who's on the committee is stored in the ontology itself

> **Implemented (multi-validator milestone, 0.6.30–0.6.34).** This design is now live: the committee is
> the set of `peer_admitted` facts; a machine is admitted by proving `can_join` (the shipped root
> ontology gates it on `peer_ready`, a read-only external predicate that checks the candidate is alive
> and caught up); a caught-up observer that sees its own `peer_admitted` fact commit self-promotes to a
> voting member; a member reaches a brand-new member via the committed address; and a laggard never
> locally finalizes a slot the honest network may not commit (the weak-cert guard). Growth 1→N is proven
> zero-pre-seed in `growth_SUITE`. See `doc/deferred.md` §3 and the `m:quod_simplex` module docs.

Committee membership is **facts in the ontology** (as in bbsvx/onia), and a machine
that wants to join is admitted by **proving a join-predicate** the ontology
defines. Keep two kinds of change apart:

- **Who's in charge** changes by itself, only when the current one fails — not on a
  timer.
- **Who's on the committee** changes only *on purpose* — a machine joins (passing
  the join-predicate) or leaves/is removed — and every such change is **itself a
  recorded block**. So unlike Brahms (which constantly reshuffles its loose crowd),
  the committee is deliberately **stable**; that stability is what lets it keep an
  exact record. The first block names the starting committee; everything after is
  just more blocks — no chicken-and-egg.

*Rotation is optional.* If you want the committee to rotate so the same 3 machines
don't hold an ontology forever (fairness, spreading load), that's a policy on top —
e.g. onbrater's: every so many blocks, recompute the committee from the peer facts.
Start stable; add rotation later if wanted.

### Brahms vs the committee

Two different jobs, stacked. **Brahms = the crowd**: background gossip that keeps
every machine *roughly* aware of who's around — big, loose, always shifting; it
**finds** machines but doesn't order changes or hold the ontology. **The committee
= the small group** that actually holds one ontology and agrees on its changes.
Brahms finds candidates; the committee is the small subset that actually runs the
ontology, joined by a deliberate, recorded step. Being in the crowd ≠ being on the
committee.

### The history is the block list — kept in full, and browsable

Two separate things:

- **The current facts** — the ontology as it is now (what `prove` reads): the live
  Prolog database each member holds.
- **The history** — the ordered **block list**, every change ever made. The current
  facts are just this history replayed from the start.

**Decision: keep the full history, permanently, and browsable** (a ledger you can
page through on a web page). So the block list is **saved durably** (to disk on the
committee members) — a deliberate exception to quod's "no disk" goal, but only for
the history. The current facts need no separate saving: they rebuild from the block
list. **Rule: save the block list; derive everything else from it.** A web page
reads the history straight off any committee member. *Trimming old history* (keep
only a recent snapshot + changes since, to bound size) is an **option we add
later** — default is keep everything.

**Who holds it — first cut: only the committee.** Each committee member keeps the
full block list; read-copies hold current facts only, not the history. *Later
(opt-in):* a `local_history(Node)` predicate in the ontology adds extra
history-holders ("archive" nodes) beyond the committee — **committee members always
store it; the predicate only adds more.** Being a predicate, it can be a rule
(`local_history(N) :- has_big_disk(N)`). It expresses intent a node honors (usually
self-declared — a remote ontology can't force your disk; gate who may assert it by
ACL), and when a node becomes an archive it back-fills the past history once from a
committee member. Not in the first version.

### Reads don't go through the committee

The committee is the authority for **changing** an ontology. **Reading** it —
calling a predicate to look something up — changes nothing and does **not** need the
committee. A read only needs *a copy of the current facts*, and copies can be
everywhere. This is the answer to "won't a popular ontology like `root` funnel
everything through 3 nodes?":

- Other machines hold a **read-only copy** of `root` and answer reads locally — the
  3 committee members are not in the path.
- Better, `root`'s hot predicates (`isa`, `have_attribute`, class definitions) are
  **schema that barely changes**, so a caller keeps its **own copy** and is pinged
  only on the rare change. In steady state `root::isa(...)` is a **local lookup,
  zero network hops.**

Three tiers for a read: (1) your own cached copy — rarely-changing things like
schema, no hops; (2) a read-copy near you — one hop; (3) the committee — only for a
read that must be the guaranteed-latest value (rare). The committee's only real
load is **edits**, and a `root`-type ontology is barely ever edited.

**When the committee _is_ a limit:** only if an ontology gets many *edits* (not
reads) — edits to one ontology are handled one at a time by its committee. Fix:
**split an edit-heavy ontology into smaller ones**, each with its own committee →
more edit capacity in parallel. (That's why we have one committee per ontology, not
one global one.)

This read path is the "read-set is the subscription" idea (§3) doing double duty (a
copy + notify-on-change). Honest caveats: caching *foreign* facts brings back the
per-fact "where did this come from" tracking we deferred in §2; a cached copy can be
a beat behind (fine for schema; go to the committee for guaranteed-latest); and the
per-predicate notification granularity of §12 #2 applies (a `root` change pings
every holder — fine because `root` rarely changes).

### How a change commits (the edit interface)

Above the committee sits one small interface; *how* the committee agrees lives
behind it, so the agreement can be made stronger later without touching anything
above:

```
append(Ns, Change)               -> {ok, BlockIndex} | {error, not_in_charge, Hint}
% the committee then hands each official change, in order, to every member:
apply(BlockIndex, Change, Facts) -> Facts'        % deterministic
```

- A **change** is a committed transaction: its signed author and `author_seq`,
  caller namespace, audit goal/result, diff, and OCC read check. The sequence is
  exact replay protection; the diff is the asserts/retracts to apply.
- **append** is how a write-transaction commits (§5): the one in charge orders it,
  copies it to the others, and it counts once a quorum finalizes it. A validator
  that is not the current leader signs its local transaction and transparently
  relays the exact canonical bytes to the leader; `not_in_charge` remains the
  bounded failure result when no live leader can be reached.
- **apply** runs on every member in the same order: **re-check what the proof relied
  on is still true; if so apply the diff; if not, reject it** (the caller retries).
  That is §6's "validate the read-set at the change's position," located precisely.
  Same changes, same order ⇒ identical facts on every member.

**We record the diff, not the goal.** Members apply a concrete list of
asserts/retracts; they do **not** re-run the Prolog (re-running isn't guaranteed
identical across machines). Only the one in charge runs the proof.

### How it plugs into the existing modules

```
quod_sup
├── quod_quic                    (transport — unchanged)
├── quod_brahms_sup → quod_brahms per Ns   (discovery / the crowd — unchanged)
└── quod_ns_sup     → per-ontology subtree                       ← NEW
        ├── quod_simplex   (Ns)   committee member: order + agree on blocks
        └── quod_prolog (Ns)   the facts: apply blocks, answer proves
```

- Committee messages (who's in charge, catch-up, new blocks) ride `quod_link`
  streams on their **own channel `{log, Ns}`**, kept separate from Brahms's gossip
  so the two don't get stuck behind each other.
- **Brahms finds candidates; the committee list (in the ontology) is the
  authoritative one** (§12 #8).
- New `quod_reg` names: `{quod_simplex, Ns}`, `{quod_prolog, Ns}`.
- A member that restarts reloads its own on-disk history and/or **catches up from
  the others**. Losing one member is fine — that's the point of having several.

### The agreement recipe — same interface, crash- or Byzantine-fault

The committee runs **DispersedSimplex** BFT (`m:quod_simplex`, `doc/simplex_extended.pdf`): a `⅔`
quorum of Ed25519 signatures per block, so it survives members that *lie*, not merely *crash* —
Byzantine safety was built in from the start (the earlier plan to "run Raft first, add BFT later" was
superseded). The `apply` side and everything above the `append`/`apply` interface are unchanged
regardless of the recipe, so the ordering layer can still be swapped per ontology without disturbing
the rest.

The runtime distinguishes the proposal frontier from the durable frontier. A per-node head-progress
state watches exactly `committed+1` through `awaiting_proposal`, `awaiting_notarization`, and
`awaiting_commit`; it is cleared only by commit, complaint-certified skip, or a verified catch-up
re-seat. Demand for the depth-one successor is retained separately while its parent is the durable
head, then becomes `awaiting_proposal` as soon as the parent finalizes. A recovering validator that retained
a valid, unnotarized proposal processes it through the normal support or membership-verdict path before
complaining. A notarized complete-tree block instead re-enters the common final-vote decision when voting
returns, because the original notarization event was one-shot. Complaint timeouts are withheld while fewer
than a certificate quorum have reported `ready` at or beyond the local committed height on their current
authenticated inbound consensus streams. The report is refreshed once per second, expires after three
seconds, and is discarded with its exact stream generation; opening a replacement socket while still
recovering cannot inherit the previous process's readiness. The first three readiness restorations for one
unchanged phase grant a fresh Delta; later flaps leave the existing deadline intact.
Before notarization, an already-supporting follower uses the first such timeout to re-echo its support and
waits one final Delta before complaining. This lets the leader's retained proposal reach a recovered voter;
the one-shot latch prevents the grace from becoming an unbounded liveness delay.

Every first support, commit, or complaint decision is appended to the namespace's bounded vote journal and
synced before its signature can be sent. A restart reloads those exact decisions, so it cannot switch blocks
or switch between commit and skip. One decision table covers both live pipeline slots: for an unlatched
round, `f+1` visible peer complaints select skip; otherwise a notarized block selects commit, while only the
head watchdog or an invalid-membership verdict may originate a complaint without amplified evidence.
Complaint amplification remains active after notarization. A validator missing a support-certified block
rotates one point-to-point request at a time through certificate signers and then other committee members.
Normal proposals and recovered blocks use one shared timestamp/payload admission predicate after their
distinct position and certificate checks, so recovery cannot accept content that live voting would reject.
Full proposals are not persisted and non-leaders do not flood them.
A verified final certificate beyond the local approved frontier immediately revokes voting capability. If
the finalized block itself never arrived, the ordinary durable-log recovery path fetches and verifies that
entry; the node does not remain "ready" one block behind.

The leader still redrives its retained proposal through the bounded outbox. Committee transitions close
obsolete inbound and outbound consensus links, discard readiness reports, and remove queued frames and
pending dials, so transport state cannot outlive the validator set that authorized it. These mechanisms
recover the observed mixed-camp and proposer-loss outages after a temporary `>f` crash wave. The protocol's
Byzantine safety assumption remains at most `f` faulty validators; journaled latches preserve honest votes
across restarts but do not enlarge that adversary bound. Liveness is still conditional if opposing final
votes become hidden simultaneously before either camp's `f+1` evidence is visible, or if every holder of a
notarized block disappears after enough validators have commit-latched it. Those cases require a later
view-change/availability protocol rather than more timeout exceptions.

### Still open

- **Hand-roll vs `ra` — _decided: hand-rolled_** — but the hand-rolled recipe is a lean
  **DispersedSimplex** BFT over `quod_link` streams (channel `{log, Ns}`), not Raft, with no Erlang
  distribution (matching how Brahms was built). `ra` and the Raft paper were early references only.
- **Read freshness** — stale-copy-OK (default) vs go-to-committee for the
  guaranteed-latest value.
- **Read-copies** — who holds a read-only copy of a popular ontology, and how
  they're kept current (the §3 notify path).
- **One `quod_prolog` per ontology** serialises edits; read-only proofs run on
  cheap copies alongside.
- **Trimming history** — opt-in, later.
- Cross-ontology all-or-nothing edits stay a layer *above* this (§12 #3), Phase 4.

---

## 14. The event system — how a committed change notifies what reacts

**Status: design for Phase 2** (Phase 1 handles only the narrow case at the end).
Drawn from onia §14 (the D/P/E model) and §15 (the live-vs-replay split); bbsvx
implements a looser version we improve on.

### Three layers: the fact change, the derived views, the reactions

Every committed change runs in three layers, in order:

- **The fact change (D)** — the assert/retract into the kb. *This is what the
  ordering layer already applies (§13).*
- **Derived views (P)** — in-memory state computed from the facts: indexes, the
  "who-read-what" subscription table, (later) a scene graph. Rebuilt
  **synchronously, right after D**, so that by the time anyone is notified the
  derived views are already consistent.
- **Reactions (E)** — the outward/reactive stuff: `react_on` rules firing,
  messages sent, client/3D updates pushed. Runs **after commit, and only on a
  live commit.**

Order: commit → apply the diff (D) → refresh derived views (P) → fire reactions
(E). D+P are synchronous and finished before anyone is notified; E is the async,
outward part.

### The one rule that matters: replay must not re-fire reactions

When a node **replays** committed history — catching up, restarting, a fresh
committee member — it runs **only D** (rebuild the facts). It must **not** re-fire
E: no re-sent messages, no re-pushed updates, no re-run `react_on`. Otherwise a
node that falls behind and catches up would double-fire every side effect. (onia
enforces this by delivering replay on a separate channel reactors don't listen to;
**bbsvx gets this wrong** — it re-runs effects on replay and leans on idempotency,
the wart we avoid.)

The ordering layer already draws this line: the **live** apply path fires
reactions; the **replay** path (`ordering-layer-spec.md` §4.6) runs D only.
Phase 2's notification hooks onto the live apply path, never replay.

### `react_on` and effects are facts

A reaction is declared as content — `react_on(Pattern, Goal)` (stored as an
`event_handler` fact); an operation's effects as `effect/4` facts. Fits the
"config is facts + predicates" spine. The discipline that keeps replay safe:
**effect bodies may only touch the kb; the outward stuff lives in the reaction (E)
handlers fired on live delivery.**

### This is how §3's "read-set is the subscription" actually works

"Notify the proved scopes that read a changed fact" *is* the E layer: after a live
commit, match the changed facts against the read-sets / `react_on` patterns and
fire the matching reactions. So §3's notification isn't a separate subsystem — it's
event delivery on the live apply path. (Caveat: today's read-set is per-predicate,
§12 #2, so notifications fire per predicate, not per fact.)

### One change → one notification; and a loop guard

A single change that cascades into many diffs fires reactions **once, at the end**
(one notification envelope), not per-op. And a reaction triggered by a notification
must not freely write back and re-trigger — bbsvx uses a "firewall" (a
subscription-triggered handler can't itself write) to stop amplification loops;
we'll need the same.

### Phasing

- **Phase 1 (already in the build spec):** the only reactions are a *write's own
  deferred effects* — they fire **once, on the submitting node, at commit** (parked
  by `tx_id`), never on other members, never on replay (at-most-once). The narrow,
  safe case; the spec implements it.
- **Phase 2:** generalize to **reactors** — `react_on` rules, the
  read-set→notification index, cross-ontology notification — all on the live apply
  path, with the loop guard. Out of scope for the first build.
