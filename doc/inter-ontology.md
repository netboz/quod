# Inter-ontology asks — the specification

**Status: NORMATIVE.** This document defines how ontologies name each other's things and ask
each other questions. It supersedes the cross-ontology prose inherited from the deprecated
bbsvx/onia attempts (`content-layer-design.md` §4/§5/§8 — those sections now defer here).
Plain language on purpose; the technical anchors are in the boxed notes and file references.

Decided by Yan, 2026-07-16 (plan `sorted-inventing-bee.md`), hardened by a devil's-advocate
review against the actual code. Implementation status: naming/parser, multi-ontology nodes,
co-hosted asks, cross-node asks, shared-snapshot worker execution, atom-safe transport, and
default link following are implemented. The network ontology directory contract is approved
and its first system/private slice is implemented (§10); transport-level stream
prioritization remains future work.

---

## 1. The two marks

quod content uses two operators, one meaning each:

| mark | meaning | where it appears | example |
|---|---|---|---|
| `:` | **belongs-to** — builds a name | inside facts and ontology names | `isa(my_animal, quod:animal)` |
| `::` | **ask** — run a question over there | as a rule step (goal position) | `user_xxx:door::open(X)` |

- `quod:animal` — *the name `animal`, over in the ontology `quod`*. It is **data**: store it,
  match it, pass it around; nothing happens until something needs what it points at.
- `animals::diet(dog, D)` — *ask the ontology `animals` to prove `diet(dog, D)`*. It is an
  **action**: it runs a question in another ontology and yields its answers here.

Why two marks: ontology names carry their owner (`user_xxx:door`, §2), so a lone `:` cannot
also mean "call" — in `user_xxx:door:open(X)` nobody can tell where the name ends and the
call begins. `::` marks the call boundary explicitly.

> **Technical note — parser binding (a build prerequisite).** Both operators parse today
> (`erlog_parse.erl:299-300`: `:` xfy 600, `::` xfx 600/599), but with these precedences
> `a:b::goal` groups as `a:(b::goal)` — the top functor is `:`, so a handler registered on
> `::` would never fire for owner-carrying names. The fork (SHA-pinned `netboz/erlog`) is
> adjusted so `::` binds looser than `:`: `a:b::goal` ⇒ `(a:b)::goal`. Verified safe: erlog's
> bundled libraries use no `:` operator, and existing quod content writes colon-names only as
> quoted atoms.

## 2. Names: ontology names carry their owner

Everyone will want a `door` ontology. So the name itself disambiguates and shows ownership:

- `user_xxx:door` — user_xxx's door ontology. Same idea as DNS subdomains or GitHub
  `user/repo`.
- `quod:root` — the system's root ontology. It already fits the pattern; it keeps its name.

**Resolution rule.** In a qualified name, the longest prefix that names a *known* ontology is
the ontology; whatever follows is the name inside it. A prefix that names no known ontology is
the loud `unknown_ontology` error (§8) — never a silent failure. ("Known" = hosted
locally or present in the live directory/direct-route index; §10.)

**Ownership enforcement is NOT in this milestone.** The rule "only user_xxx may create
`user_xxx:*`" is creation-time permission checking; it needs author-signed writes and the
ontology registry — both already-deferred work (`deferred.md` §1). This milestone fixes the
*naming convention and resolution* so no name ever has to change; the spec of record for
creation-authorization is the signing milestone.

**Parked:** deeper paths inside content terms (`thing:cat:max` as a data path). Nothing
forbids adding them later; they are not specified now.

### 2.1 One canonical shape for a name

Today the same ontology name exists in three written shapes that never match each other:
the structured term (`quod:root` unquoted — a `:`-term), the quoted atom (`'quod:root'`,
present twice in the shipped genesis facts), and the flat runtime id (the binary
`<<"quod:root">>` used by config, registry keys, and channel names). That is a bug factory.

The canonical rule:

- **At every boundary** (config, wire, registry, committed records), an ontology name is the
  **flat binary** — segments joined with `:`.
- **In content**, the structured `:`-term is the ONE written form. The two quoted-atom
  genesis facts are migrated. The engine bridge flattens a `:`-term to the flat binary when
  it leaves Prolog (asks, follows), and never goes the other way by minting atoms:
  **creating atoms from network-received names is forbidden** (atom-table exhaustion — the
  existing `binary_to_existing_atom` discipline applies).

## 3. Links: facts ARE the web between ontologies

An ordinary fact whose arguments name things in other ontologies — that is the whole
inter-ontology web. Nothing more:

```prolog
isa(my_animal, quod:animal).                    % my_animal is a kind of quod's animal
attached_to(my_stuff:door, my_world:my_house).  % ANY relation can cross, not just isa
```

- **A link is established when the fact commits — nothing else.** Proposed, agreed by the
  committee, applied on every replica (or present from the ontology's first block). No
  registration, no handshake; the pointed-at ontology doesn't know it is being pointed at.
- **A link is exercised at ask time** — when a question actually needs what it points at.

### 3.1 Every relation follows its links by default

No blessed list of "following" relations — `isa`, `have_attribute`, `attached_to`: all
uniform. The tag written in the term is the explicit crossing marker (ground rule 1), so
following it is never silent.

- **Local first, hop last.** A relation's own local facts and rules are always tried first;
  the hop across is the last resort. `isa(my_dog, animals:dog)` answers "is my_dog a dog?"
  from the local fact with zero trips; "what does my_dog eat?" finds nothing local and
  follows the link into `animals`.
- **The rewrite, precisely.** When the hop fires on a relation `R` whose argument at some
  position is the name `Ns:X`, the ask sent to `Ns` is the same relation with that argument's
  **matched prefix stripped**: `have_attribute(animals:dog, diet, D)` re-asks `animals` about
  `have_attribute(dog, diet, D)`. If several argument positions carry foreign names, each
  position hops (in argument order); duplicate answers are removed by identity.
- **Opting out:** a `no_follow(Relation/Arity)` fact turns following off for that relation —
  agreed content, so every replica behaves identically. The name still stores and matches
  fine, and a rule can always ask explicitly with `::`.

> **Technical note — followers are synthesized at read time, never stored.** A stored
> follower clause is mechanically broken: any later user assert lands after it (silently
> breaking local-first), it would pollute the per-predicate content fingerprints, and at
> genesis it would leak into the committed block as user content. Instead the proof overlay
> (`quod_erlog_db_local_prove`) synthesizes the follower as a virtual LAST clause while a
> relation is being resolved, tagged so `retract` and committee introspection never treat it as
> committed content, and consults
> `no_follow` *through the overlay* so the decision itself lands in the recorded read-set
> (a racing `no_follow` commit then conflicts honestly). Deterministic on every node by
> construction.

The pinned erlog implementation has no callback context for its built-in `clause/2` path, so
overlay introspection currently exposes these virtual clauses there. Hiding them requires a small
erlog hook/fork; execution, retraction, committee projection, and committed content do not treat
them as stored clauses.

## 4. The ask, start to finish

One ask = one frozen run on the target = one stream of answers back. Its worker waits only
between explicit demand messages, for at most the idle timeout; while deriving an answer it is
guarded by an engine-owned no-progress timer. An independent absolute lifetime bounds the
worker and its MVCC snapshot even while answers keep flowing. It dies with its ask, engine,
or either timeout.

1. **Open.** The asking side allocates a fresh **ask id**, subscribes to its answer channel,
   and sends the ask — target ontology, the goal, and the asking chain (§6) — on the
   target ontology's fixed ask channel.
2. **Freeze.** The target takes its committed facts **as of that instant** as the run's view.
   The committed KB exists once in a versioned ETS store. A worker receives only the table id
   and height; predicate lookup resolves the newest version at or below that height. No whole KB
   is copied into the worker, and answers can never be half-old, half-new. Old predicate
   versions are reclaimed against the oldest live worker snapshot.
3. **Permission.** Before running the goal, the target proves `can_read` for the asking
   chain and, on a remote hop, the TLS-authenticated node key (§6). Refusal =
   `not_allowed`, before any work.
4. **Stream.** The run produces answers by normal Prolog backtracking; **each answer is sent
   the moment it is found** — no batches, no waiting. The asking rule's choice point consumes
   them as they arrive; backtracking into the ask waits for the next answer. First answer =
   fastest possible, even when later answers are slow to derive.
5. **Complete.** When the answers run out, a sequenced **complete** marker closes the run.
   If the rule stops early instead — or the asking proof dies — the ask is cancelled and the
   target kills the run on the spot.

### 4.1 Where the work runs: one worker per proof

The ontology's engine process **never runs proofs**. Every proof — a served ask AND the
engine's own client proofs — runs in its **own small worker process** holding a shared-store
snapshot handle and private staging overlay. The engine stays free for commits and
coordination; a wedged ask wedges only its worker; cancel = kill the worker; two ontologies
asking each other simultaneously each block only their own workers, so nothing deadlocks.

Quick local proofs behave exactly as today (spawn, prove, reply — one extra process spawn).

> **Technical notes.**
> - *Why not "pause the engine between answers":* the engine is resumable only at answer
>   boundaries; a single answer's derivation is unbounded (`findall` runs sub-goals to
>   exhaustion inside one step), and an asking run blocks in a receive mid-derivation — so
>   in-engine slicing cannot deliver "never blocks". Workers can. (DA finding F1.)
> - *No KB copy:* the committed database callback is `quod_erlog_db_mvcc`. Interpreted
>   predicates live in one shared ETS table; the `#est{}` sent to a worker contains only a
>   table/height handle, flags, and hooks. A commit publishes only changed predicates.
> - *The per-proof read-set table* (a real ETS table today, `quod_erlog_db_local_prove.erl:56-61`)
>   is **owned by the worker**, so an abandoned client proof can never leak it. Served asks
>   do not allocate one: completion subscriptions are not implemented yet.
> - *The membership-vote re-proof keeps its own synchronous path*, and link-following is
>   **disabled** inside it: a committee vote must never make network hops mid-verdict.
> - Answer workers are monitored, not linked, by the ontology engine. A one-shot lifecycle
>   watcher gives directional ownership: engine death kills the worker, but an untrusted
>   transport or worker failure cannot propagate into the engine.

### 4.2 How answers ride the wire

quod's transport rules (deliberate, bug-history-backed): a node never replies backwards on a
stream the peer opened, and a node only receives on channel names it subscribed. So an ask is
**two legs**:

- **Leg 1 (the ask):** on the target ontology's fixed, pre-subscribed ask channel — carrying
  the ask id. Its control envelope is safe-decoded and malformed metadata is rejected at the
  boundary. Prolog terms use the bounded `quod_wire_term` codec; atom names cross as binaries
  and never allocate atoms in the receiving VM.
- **Leg 2 (the answers):** the target opens its **own outbound link** named by that ask id —
  which the asker subscribed before sending — and streams answers there.

Cancellation uses an ask-specific control frame on the shared request channel: the asker leaves
that reusable channel open, while the target routes the cancel by ask id and kills the matching
run's worker. The owner watcher sends the same frame if the asking proof worker dies. The target's
answer link dying is already a monitored event on the asker. After **complete**, each side closes
its per-ask leg; a finished ask leaves no per-ask worker, registration, or answer buffer behind.

> **Technical notes.**
> - **Backpressure is explicit for asks.** Managed ask links retry
>   `flow_control_blocked`/`send_queue_full` until their bounded send timeout and fail
>   loudly if the local QUIC connection never accepts the frame. Gossip and feed traffic
>   retain their deliberately fire-and-forget delivery. An answer is sent only after its
>   corresponding `next` request, so demand-driven asks keep at most one answer in flight;
>   the target engine collapses duplicate demands into one bounded pending bit. Sequence
>   numbers still detect transport gaps as `broken_stream`.
> - **Authenticated is not trusted.** Every envelope is decoded with safe ETF, compressed ETF
>   is refused, and goals, answers, and errors use the bounded symbol codec. A target-local atom
>   unknown to the asker becomes `{'$quod_symbol', <<"name">>}`. It can unify and round-trip,
>   but cannot exhaust the asker's atom table.
> - **Every answer carries a sequence number.** Any residual gap at the asker is the loud
>   `broken_stream` error — a lost answer can never masquerade as a complete result.
> - **Ask streams never starve votes:** when wired, ask channels get lower stream priority
>   than consensus `{log, Ns}` (the unused RFC 9218 knob — `deferred.md` §2).
> - Co-hosted asks (target ontology on the same node) skip the wire entirely: same handler,
>   worker-to-worker message stream, same semantics.

## 5. Completion and future subscriptions

The **complete** marker carries only its sequence number. Earlier drafts also carried a frozen
version and target read fingerprint, but no implemented component consumed them. Keeping that
dead contract allocated an ETS read-set per served ask and allowed the final frame to grow past
the transport limit. The future "tell me when it changes" milestone will add a bounded,
purpose-built subscription record when there is a consumer for it.

## 6. The chain: circles, depth, permission

Every ask carries the **chain** — the list of ontologies already involved in producing it.

- **No circles.** If the target is already in the chain, the ask is refused: `circular_ask`.
  An endless A→B→A loop would compute nothing and quietly burn both sides.
- **Bounded depth.** A chain longer than the cap (§9) is refused: `too_deep`.
- **Self-ask exception.** `A::x` written inside A itself is answered in place — no
  round-trip, no chain growth.
- **Permission uses the whole chain and authenticated peer.** The target proves `can_read`
  for **every** ontology in the chain. On a remote hop it also proves the same policy for
  the Ed25519 node key bound to the request connection by mutual TLS. The caller may describe
  an ontology path, but cannot omit its real transport identity to launder a read through an
  allowed name. The `can_read` policy is ordinary agreed content in the target ontology; the
  shipped default remains open.

> **Technical notes.** The chain travels in the engine run's flag store (it survives run
> suspension and cannot be forged by content — the flag-setting builtins are whitelisted,
> `erlog_int.erl:789-795`). On a committed write produced by an ask-capable proof, the
> recorded asking-ontology field stays the existing single name = the **chain head**, so the
> consensus validator's shape check (`quod_simplex.erl:1755-1757`) is untouched.

## 7. Freshness

The target answers from one frozen view. A commit landing mid-stream neither upgrades nor
invalidates that stream. An explicit minimum-version request is deferred: log heights belong to
individual ontologies and are not comparable without a target-specific version contract. The wire
therefore carries no unused freshness field, and completion does not claim a version (§5).

## 8. Errors — the complete catalog

Every failure a rule author can see is **distinct and loud**. Silence is never an answer;
a partial result never looks complete.

| error | when |
|---|---|
| `unknown_ontology` | the name's prefix matches no known ontology |
| `bad_name` | the name/ask term is malformed |
| `unreachable` | the target ontology is known but no node serving it can be reached |
| `not_allowed` | the target's `can_read` refused an asking ontology or the authenticated peer |
| `circular_ask` | the target is already in the asking chain |
| `too_deep` | the chain exceeds the depth cap |
| `too_many_answers` | the run passed the total-answer cap — "narrow your question" |
| `answer_too_big` | one answer exceeds the frame limit — refused **on the sender** |
| `broken_stream` | a sequence gap, the target's link died, or the target crashed mid-run |
| `no_progress` | the absolute proof lifetime or an answer-step timeout expired |
| `foreign_write_unsupported` | an asked goal tries to change the target ontology |

> **Technical note — typed proof errors.** The old runner collapsed thrown erlog errors into
> `prove_failed`. The worker runner now catches both erlog throw shapes explicitly, so the
> taxonomy above reaches the rule author. Client calls wait for the proof worker's
> absolute completion budget; streamed progress does not extend it. An abandoned,
> slow-drip, or genuinely wedged proof receives `no_progress`.

## 9. Limits (starting values — one table, tuned with real usage)

| limit | value | on breach |
|---|---|---|
| answers per ask | 10 000 | `too_many_answers` |
| one answer's size | 1 MiB (existing frame limit) | `answer_too_big` (sender-side) |
| chain depth | 8 | `too_deep` |
| client proof lifetime | 60 s absolute (configurable) | `no_progress` |
| served ask lifetime | 60 s absolute (configurable) | worker and snapshot are killed |
| answer-step no-progress timeout | 30 s (configurable) | worker is killed |
| concurrent asks served per ontology | 64 (configurable) | asker waits/retries |
| concurrent client proofs per ontology | 64 (configurable) | `busy` |
| rejected remote opens sent per ontology | 32/s | excess rejection replies are dropped |

## 10. Network ontology directory — implemented first slice

The directory resolves a ground ontology name to a bounded set of live routes. It is exposed
inside `quod:root` as the read-only external predicate:

```prolog
directory_host(+Ontology, ?NodeKey, ?Host, ?Port).
```

Its answers come directly from a local Erlang ETS index using Erlog compiled-predicate
backtracking. Endpoint churn is network-observed soft state: it is never committed ontology
content, a lease transaction, a consensus input, or a `quod_runtime` state-handler projection.
The `::` resolver reads that same index directly rather than recursively asking Prolog how to
route a Prolog ask.

The first slice has two explicit route sources:

- root-authorised system hosts publish signed, expiring advertisements;
- private ontologies are reached through local direct seeds and are never published.

A node derives its public advertisement from system namespaces that are
actually running locally. Namespace start/stop replaces the complete signed
set; an empty set withdraws it. Periodic reconciliation repairs missed
notifications, while any number of private local ontologies remain outside the
32-name public-advertisement limit.

Every receiver independently verifies an advertisement's original Ed25519 node signature,
restart-safe epoch/sequence freshness, exact namespace allowlist and bounds. System routes dial
the advertised endpoint through a scoped transport operation pinned to the signed node key.
Pinned and private-seed-confirmation links suppress the ordinary link-header address-cache
learning through their whole `quod_quic` → `quod_conn` → `quod_link` path, so directory
addresses cannot contaminate consensus/feed dialing. Ordinary links retain auto-learning.

A route does not certify a read answer. In the first slice, answer integrity rests on the
operator's exact allowlist of trusted system hosts. Self-managed discoverable ontologies are
deferred until both advertisement authority and answer authority are designed (for example,
committee-only answering or certified answers). User-specific hidden discovery also waits for
authenticated proof subjects; private unlisted routes need neither feature.

The implementation contract, bounds, failure semantics and acceptance tests are in
`network-directory-plan.md`.

## 11. Non-goals — deliberately NOT in this milestone

- **Changing another ontology's facts.** Writes stay home-only (`foreign_write_unsupported`
  stays). Cross-ontology writes need author-signed transactions first (the signing
  milestone), then the owner-executes model in `content-layer.md` §5.
- **The notification system** ("tell me when what I read changes"). Later milestone; §5
  explains why its storage is not prebuilt as dead per-ask state.
- **Notification precision finer than per-predicate.** Known, accepted coarseness.
- **Ontology-creation authorization** (`user_xxx:*` ownership enforcement). Arrives with
  signing; the naming convention lands now (§2).
- **Deeper name paths** (`thing:cat:max` as data). Parked.

## 12. What this changes for consensus: nothing

Cross-ontology asks happen while a question **runs**, on the node running it
(prove-before-broadcast). What the committee agrees on is the finished list of changes; apply
never re-asks anything, and answers a proof consumed are baked into its proposed diff. This
layer adds **zero** moving parts to ordering, voting, catch-up, or the feed. Two guard rails
make it stay that way: the membership-vote re-proof is synchronous with following disabled
(§4.1), and the committed record keeps its existing shape (§6).
