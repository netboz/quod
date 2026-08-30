# Inter-ontology asks — the specification

**Status: NORMATIVE.** This document defines how ontologies name each other's things and ask
each other questions. It supersedes the cross-ontology prose inherited from the deprecated
bbsvx/onia attempts (`content-layer-design.md` §4/§5/§8 — those sections now defer here).
Plain language on purpose; the technical anchors are in the boxed notes and file references.

Decided by Yan, 2026-07-16 (plan `sorted-inventing-bee.md`), hardened by a devil's-advocate
review against the actual code. Implementation status: naming/parser, multi-ontology nodes,
default link following, recursive reusable proof scopes, cross-scope transactions, the
hard-break scope transport, the source-claimed remote-singleton path, and atomic
multi-participant durable submission are implemented. The network ontology directory contract and its
system/private route slices are also implemented (§10). This is the current
protocol specification, not a record of one deployment. Release activation and
hardware gates belong to the release procedure; any future incompatible format
still requires its own coordinated clean re-found. Transport-level stream
prioritization remains future work.

There is one execution model for self, co-hosted, and remote selection. Location changes only
how commands reach the selected ontology's proof scope; the deleted per-invocation ask
protocol has no decoder, alias, or compatibility mode.

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

**Ownership enforcement is NOT in this milestone.** The target actor model
defines the ontology creator as its owner; contained agent instances do not
become owners merely through `instance_of/2`. Enforcing "only agent X may
create `X:*`" is creation-time agent permission checking. Node-authored signed
writes are already live, but authenticated origin-agent identity and the
ontology-owned creation policy are separate work (`deferred.md` §1). This
milestone fixes the *naming convention and resolution* so no name ever has to
change.

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
isa(my_animal, quod:animal).                   % my_animal is a kind of quod's animal
made_of(my_stuff:door, materials:oak).         % ANY relation can cross, not just isa
```

- **A link is established when the fact commits — nothing else.** Proposed, agreed by the
  committee, applied on every replica (or present from the ontology's first block). No
  registration, no handshake; the pointed-at ontology doesn't know it is being pointed at.
- **A link is exercised at ask time** — when a question actually needs what it points at.

### 3.1 Every relation follows its links by default

No blessed list of "following" relations — `isa`, `have_attribute`, `made_of`: all
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
> breaking local-first), it would pollute the per-predicate OCC read-set tokens, and at
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

Every engine-owned top-level proof has one generated `ProofId`, one absolute deadline, one
anchored origin identity, and one origin-owned proof session. The first selection of another
ontology opens one scope for its exact `{Namespace, GenesisAnchor}` identity. Every later or
re-entrant selection of that identity reuses the same frozen committed base and private staged
view, whether the scope is local, co-hosted, or remote.

1. **Resolve and pin.** A co-hosted target is pinned to its live genesis anchor. A remote
   target comes from the directory; the transport pins both the advertised endpoint and the
   authenticated node key. Conflicting anchors fail before any goal runs. A provisional private
   seed performs only the bounded identity exchange described in §10, then becomes an ordinary
   pinned route.
2. **Register and open.** The origin registers the bounded scope before execution. The target
   freezes its committed KB height and opens one shared proof session. The committed KB remains
   a versioned ETS store; a scope holds only its table/height handle and overlay, never a copy of
   the whole ontology.
3. **Authorize.** Before each invocation, the target proves its own `can_invoke/4` policy,
   receiving the origin-built call chain and the engine-owned principal in one call. A remote
   scope is also bound to the exact mutually authenticated peer and request link, so another
   node cannot command it. Founding injects a bodyless host-entry default so an ontology can
   always answer its own host; a refusal is ordinary logical failure carrying a bounded
   `not_allowed(Ns)` reason, not an error. See `distributed-proof-plan.md` for the full
   contract; there is no compatibility policy beside it.
4. **Invoke on demand.** The selected goal runs through the same `quod_proof_session` API in
   every location. One explicit demand produces at most one solution. Backtracking into `::`
   requests the next solution; cuts or caller cleanup cancel the retained continuation.
5. **Return state as well as answers.** Each solution, completion, typed error, and savepoint
   acknowledgement reports the target scope's current dirty bit and generation. This lets
   repeated and re-entrant calls observe the same staged target state and lets `transaction/1`
   restore assertions, retractions, abolishes, and assertion order across all touched scopes.
6. **Finish once.** Exhaustion carries the target's bounded failure-reason stack. The immediate
   caller merges it before its `::` goal fails, so ordinary Prolog alternatives may inspect and
   recover. Infrastructure or authorization failures are typed errors, poison the whole
   pre-commit proof, and are never retried as another proof after the target may have executed.
   A writing proof seals every touched scope. Read-only scopes contribute f+1 snapshot
   certificates and no consensus records. A certificate proves the exact sealed
   snapshot when that reader's committee signs it; that reader may change later.
   One writer uses that target's ordinary consensus path. For a signed foreign write,
   the agent ontology first commits a batchable
   operation claim, the target commits the ordinary application, and the agent ontology records
   the completion asynchronously; the caller returns with the target's anchored outcome
   reference. Two or more writers enter one atomic
   Begin/Prepare/Decision/Finalize/Complete group, retaining their read-only dependencies as
   participants for now, and return its anchored group reference if the
   caller can no longer wait. The caller resolves either reference instead of re-proving.

### 4.1 Where the work runs: one worker per ontology scope

The ontology's engine process **never runs proofs or waits for them**. A top-level proof has an
origin worker; each selected ontology has one reusable scope worker holding a shared-store
snapshot handle, one private staged view, and bounded invocation continuations. The namespace
engine owns admission, monitors, timers, and MVCC pin accounting. It stays free for commits and
coordination while a selected goal derives.

Quick local proofs behave exactly as today (spawn, prove, reply — one extra process spawn).

> **Technical notes.**
> - *Why not "pause the engine between answers":* the engine is resumable only at answer
>   boundaries; a single answer's derivation is unbounded (`findall` runs sub-goals to
>   exhaustion inside one step), and an asking run blocks in a receive mid-derivation — so
>   in-engine slicing cannot deliver "never blocks". Workers can. (DA finding F1.)
> - *No KB copy:* the committed database callback is `quod_erlog_db_mvcc`. Interpreted
>   predicates live in one shared ETS table; the `#est{}` sent to a worker contains only a
>   table/height handle, flags, and hooks. A commit publishes only changed predicates.
> - *The per-scope read-set table* (a real ETS table today, `quod_erlog_db_local_prove.erl`)
>   is **owned by the worker**, so an abandoned proof can never leak it.
> - *The membership-vote re-proof keeps its own synchronous path*, and link-following is
>   **disabled** inside it: a committee vote must never make network hops mid-verdict.
> - Scope workers are monitored, not linked, by the ontology engine. Engine or authenticated
>   request-link death kills the owned scope, but an untrusted transport or worker failure cannot
>   propagate into the engine.
> - Every scope worker has the same 64 MiB heap ceiling and absolute proof deadline. A separate
>   active-step timer bounds one deriving command; receiving more commands never renews either
>   deadline.

### 4.2 How answers ride the wire

Quod's QUIC streams are directional: a target does not reply backwards on the stream opened by
the origin. A remote scope therefore uses a fixed request channel for target commands and a
target-opened authenticated return channel for events. These are the two transport directions
of one scope session, not the deleted per-invocation ask/answer protocol.

The hard-break scope envelope binds the authenticated origin and target keys, both anchored
ontology identities, `ProofId`, scope id, mode, remaining absolute budget, canonical call chain,
and opaque invocation/request ids. Commands have one strictly increasing scope sequence. Events
have a separate send-order sequence; each invocation has its own answer sequence. This separation
allows B to suspend while B→C→B runs and lets correlated replies arrive in a different order
without executing a command twice.

The origin router is only a bounded correlation and cleanup registry. It records the pending
scope before open, promotes it after the authenticated `opened` event, routes correlated events,
and removes all of a proof's scopes on completion or owner death. Prolog state, overlays, and
continuations remain exclusively in target scope workers. The target binds its scope to the exact
request link; either request-link or return-link death poisons the volatile proof and reclaims the
scope.

> **Technical notes.**
> - **Backpressure is explicit.** Managed scope links retry
>   `flow_control_blocked`/`send_queue_full` only within the remaining proof budget and fail
>   loudly if the local QUIC connection never accepts the frame. Gossip and feed traffic retain
>   their deliberately fire-and-forget delivery. One demand permits at most one answer.
> - **Authenticated is not trusted.** Every envelope is decoded with safe ETF, compressed ETF
>   is refused, and goals, answers, errors, and failure reasons use the bounded
>   `quod_wire_term` codec. A target-local atom unknown to the origin becomes
>   `{'$quod_symbol', <<"name">>}`; it can unify and round-trip but cannot exhaust the origin's
>   atom table. Goal bytes remain opaque through every relay. After identity, anchor, rate, and
>   quota checks, only the authenticated target materializes its bounded callable symbol set immediately
>   before authorization and execution. Erlog accepts that opaque-headed term only as data nested
>   in a governed external call such as `Target::Goal`; it remains invalid as an executable Prolog
>   goal until the selected target has materialized it.
> - A duplicate, stale, skipped, cross-proof, or cross-node command is a typed protocol error.
>   It poisons the scope; there is no accepted-command redrive or compatibility decoder.
> - Co-hosted selections skip QUIC and the node router, but call the same scope-session command
>   boundary and keep identical continuation, transaction, and error semantics.
> - Scope traffic must eventually receive lower transport priority than consensus `{log, Ns}`
>   (the unused RFC 9218 knob — `deferred.md` §2).

## 5. Completion and future subscriptions

An invocation's **complete** event carries its answer sequence, the target scope's current
dirty/generation state, and the bounded diagnostic stack. It closes only that invocation; the
scope remains reusable until the top-level proof ends. Failure reasons are bounded to 32 KiB,
atom-safe encoded like other Prolog values, and strictly validated by the immediate caller.
They remain proof-local while Prolog searches. Only the canonical terminal stack of a certified
group abort is persisted, once, in `Decision(abort)`; intermediate or recovered reasons never
enter consensus or the ledger.

A group's durable public outcome is terminal only after origin `Complete`;
Decision or Finalize alone remains pending there. The original live caller may
already have received the certified pre-Complete result after every required
participant application. Remote `outcome(Ref)` freezes one certified current view and accepts a status only from
`f + 1` identical current-validator snapshots bound to that view and a minimum applied slot. An
ordinary reference stays outcome-unknown even when that quorum reports absence. For a group,
quorum absence may proceed only to the exact admission-bound coordinator barrier; it proves
`pending_begin`, `coordinator_retired`, or definite pre-handoff absence. Any stale view, lagging
publication floor, unavailable coordinator, or insufficient agreement remains outcome-unknown.

There is no per-invocation subscription residue. In particular, an OCC read-set
is never a notification subscription.

The separate "keep following this ontology" facility is specified by
`ontology-subscription-plan.md`: one explicit durable `subscribes/2` fact in
the subscriber's ledger establishes the ontology relationship. Its hosting
runtime now maintains a shared certificate-verified local foreign projection
through the existing `quod_foreign_log` cache and verifier. The event path
converts the canonical reducer's newly applied operations and matches
source-qualified `react_on/3` locally in the subscriber. The first
implementation installs no target-side pattern registry. The target stores no
duplicate durable row, and routes remain local directory P-state.

That facility does not alter this document's scope invariant. For a nested A ->
B -> C proof, origin A still owns route selection, scope custody, and DTX
coordination. A subscription is not a retained proof scope, and public `::`
continues to work without one.

## 6. The chain: recursion, depth, permission

Every selection carries the **chain** — the anchored ontologies already involved in producing it.

- **Recursion is allowed.** A→B→A is treated like recursive local Prolog and re-enters A's
  existing proof scope. The absolute proof lifetime and depth cap bound unproductive recursion.
- **Bounded depth.** A chain longer than the cap (§9) is refused as
  `{proof_depth_exceeded, 8}`.
- **Self-ask exception.** `A::x` written inside A itself is answered in place — no
  round-trip, no chain growth.
- **The origin constructs the chain.** Content cannot replace it. Every entry carries the
  ontology's immutable anchor internally, and a remote request is additionally bound to the
  Ed25519 node key proved by mutual TLS. The `can_invoke/4` policy is ordinary agreed content in
  the target ontology, consuming the whole chain and the engine-owned principal at this boundary;
  a future authenticated subject lands at the same seam.

> **Technical note.** `ProofId`, origin controller authority, authenticated principal, and
> scope handles live in private worker/process state and never enter content-readable Erlog
> flags. The semantic chain is copied into the proof context for policy and following, but only
> the engine/router may construct or extend it.

## 7. Freshness

The target scope keeps one pinned committed base plus the proof's staged view. A commit landing
mid-proof neither upgrades nor invalidates it. An explicit minimum-version request is deferred: log heights belong to
individual ontologies and are not comparable without a target-specific version contract. The wire
therefore carries no unused freshness field, and completion does not claim a version (§5).

## 8. Errors — the complete catalog

Every failure is **distinct and loud**. Silence is never an answer and a partial result never
looks complete. The final distributed-proof catalog is normative in
`distributed-proof-plan.md` §5. The current implementation exposes these exact classes:

| result | when |
|---|---|
| `{fail, Reasons}` | ordinary Prolog exhaustion, including bounded reasons returned by the immediate target |
| `{error, {erlog, SafeError}}` | the target raised a bounded Erlog exception |
| `{error, {bad_name, Term}}` | the selector name is malformed |
| `{error, {unknown_ontology, Ns}}` | the directory has never learned the ontology |
| `{error, {ask_requires_anchored_proof, Ns}}` | a raw internal snapshot attempted `::` without engine-owned origin authority |
| `{error, {anchor_conflict, Ns}}` | eligible routes disagree on genesis identity |
| `{error, {ontology_unreachable, Ns}}` | no exact pinned route can open the scope |
| `{error, {ontology_busy, Ns}}` | the target's bounded scope-worker capacity is full |
| `{error, {ontology_rebuilding, Ns}}` | the target is not ready to freeze a scope |
| `{error, {network_identity_unavailable, Ns}}` | the target is ready, but cannot yet obtain the root identity needed to verify a signed scope request |
| `{error, {ontology_unavailable, Ns}}` | a local engine died before any durable-submission checkpoint |
| `{fail, [{not_allowed, Ns} \| _]}` | the target's `can_invoke/4` policy refused; ordinary logical failure with a bounded reason, not an error |
| `{error, {proof_limit_exceeded, Ns}}` | the selected worker exceeded a generated-state or heap bound |
| `{error, {scope_expired, Ns}}` | the bounded target scope expired while idle |
| `{error, {proof_depth_exceeded, Max}}` | active nested selection depth is exhausted |
| `{error, {scope_limit_exceeded, Max}}` | one proof has exhausted its distinct-scope shape bound |
| `{error, {savepoint_limit_exceeded, Max}}` | distributed transaction generations are exhausted before mutation |
| `{error, {too_many_answers, Ns}}` | one invocation exceeded its answer cap |
| `{error, {too_large, Kind}}` | a named goal, answer, reason, error, or envelope size cap failed |
| `{error, read_only}` | a strict `prove_ro` tree attempted its first mutation |
| `{error, {protocol_error, Kind}}` | authenticated identity/session/sequence/payload validation failed |
| `{error, {outcome_unknown, Ref}}` | an ordinary or group durable checkpoint exists but its terminal consensus outcome is not yet locally known; resolve `Ref` instead of re-proving |
| `{error, coordinator_retired}` | a group could not begin because its exact coordinator admission retired first |

Infrastructure and authorization errors poison the volatile proof instead of becoming logical
failure. A target-authored logical failure alone participates in normal Prolog backtracking.
Internal scope/savepoint/controller faults are not public result classes; the authenticated
boundary normalizes invariant violations to `{error, {protocol_error, Kind}}`.
Progress messages do not renew the absolute deadline, and no timeout or link loss triggers an
automatic retry after the target may have executed.

## 9. Limits (starting values — one table, tuned with real usage)

| limit | value | on breach |
|---|---|---|
| active nested invocation depth | 8 | `{proof_depth_exceeded, 8}` |
| distinct ontology scopes per proof | 8 | `{scope_limit_exceeded, 8}` |
| retained invocations per scope | 64 | bounded refusal before allocation |
| answers per invocation | 10 000 | `{too_many_answers, Ns}` |
| encoded nested goal / answer | 8 KiB / 64 KiB | `{too_large, goal}` or `{too_large, answer}` |
| scope envelope / outer transport frame | derived 500,864 bytes / 1 MiB | `{too_large, scope_envelope}` or frame rejection |
| complete reasons / one reason | 32 KiB / 4 KiB | bounded truncation |
| retained distributed savepoint generations | 1 024 per proof | `{savepoint_limit_exceeded, 1024}` |
| one scope worker heap | 64 MiB | `{proof_limit_exceeded, Ns}` |
| scope lifetime / active command | 60 s / 30 s by default, configurable | typed timeout and scope cleanup |
| concurrent scope workers per ontology | 64 by default, configurable | `{ontology_busy, Ns}` |
| origin router scopes per proof owner | 8 | proof-shape refusal before registration |

Remote scopes have exact link, request, proof-owner, monitor, and deadline
ownership. There is no separate node-wide or authenticated-peer population
quota; the ontology's configured derivation-worker policy remains the explicit
aggregate memory admission owner.

`include/quod_proof_limits.hrl` is the one source for shared producer/decoder/test constants;
schema owns the three configurable worker/deadline values. The larger aggregate transcript,
plan, and future durable-record limits remain in `distributed-proof-plan.md` §4.2.

## 10. Network ontology directory — implemented first slice

The directory resolves a ground ontology name to a bounded set of live routes. It is exposed
inside `quod:root` as the read-only external predicate:

```prolog
directory_host(+Ontology, ?GenesisAnchor, ?NodeKey, ?Host, ?Port).
```

Its answers come directly from a local Erlang ETS index using Erlog compiled-predicate
backtracking. Endpoint churn is network-observed soft state: it is never committed ontology
content, a lease transaction, a consensus input, or a `quod_runtime` state-handler projection.
The `::` resolver reads that same index directly rather than recursively asking Prolog how to
route a Prolog ask.

The first slice has two explicit route sources:

- root-authorised system hosts publish signed, expiring advertisements;
- private ontologies are reached through local direct seeds and are never published.

Directory-control authority is not configured as static addresses. The
root-context-only external predicate
`directory_control_peer(?NodeKey)` projects their identities from committed
`quod:root` `peer_admitted/4` facts. To recover moving endpoints, the control
process first treats the root ontology's existing `content.seeds` as anonymous
contacts: it authenticates the contacted TLS/header key, accepts it only if
that key is in the root proof, then records the live endpoint and continues on
a key-pinned control link. Existing authenticated transport observations are
also tried directly. This local root proof does not use `directory_host/5` or
`::`, so discovery has no directory cycle, and the contact address never
becomes authority by itself.

A node derives its public advertisement from system namespaces that are
actually running locally. Every signed hosted descriptor carries the
namespace's immutable 32-byte genesis anchor and current
`validator | observer` routing hint. Namespace start/stop replaces the complete
signed set; an empty set withdraws it. Periodic reconciliation repairs missed
notifications, while any number of private local ontologies remain outside the
32-name public-advertisement limit.

Every receiver independently verifies an advertisement's original Ed25519 node signature,
restart-safe epoch/sequence freshness, exact namespace allowlist and bounds. System routes dial
the advertised endpoint through a scoped transport operation pinned to the signed node key.
Pinned and identity-discovery links suppress the ordinary link-header address-cache
learning through their whole `quod_quic` → `quod_conn` → `quod_link` path, so directory
addresses cannot contaminate consensus/feed dialing. Ordinary links retain auto-learning.

An authenticated scope or DTX request may still provide a useful return
contact for the requester's own anchored ontology. Mutual transport
authentication provides `{NodeKey, Endpoint}` only to the exact scope or DTX
work item which received it, so a cold certified-history check can use the
contact which carried that request. Decode-only scope, claim, Prepare, or
Finalize material never creates a foreign-history or route-hint row. Only
after the ordinary scope authorization or DTX foreign-reference verification
succeeds may the receiver retain the contact in `quod_foreign_log`'s existing
volatile route-hint state. A failed check stores neither the claimed identity
nor its address. The contact remains only a place to ask.
It grants no role or permission: exact reference verification and subscription
following still replay certified history before using an answer. Public `::`
target selection remains the directory's job; this contact continuity exists
for post-scope DTX recovery and certified following, not as a second scope
resolver.

A route does not certify a read answer. In the first slice, answer integrity rests on the
operator's exact allowlist of trusted system hosts. Self-managed discoverable ontologies are
deferred until both advertisement authority and answer authority are designed (for example,
committee-only answering or certified answers). User-specific hidden discovery also waits for
authenticated proof subjects; private unlisted routes need neither feature.

The implementation contract, bounds, failure semantics and acceptance tests are in
`network-directory-plan.md`.

### Remote-proof load test

`scripts/signed-goal-loadtest.sh` is the one signed benchmark driver. Without
`--target-ns` it measures a goal in its signed source ontology; with
`--target-ns` it measures the remote `::` path. A remote run requires that the
target namespace is *not* co-hosted by its source endpoint, so a success
exercises directory resolution, the key-pinned dial, and streamed answers
rather than the local fast path. It needs an already-configured two-ontology
fleet:

```sh
scripts/signed-goal-loadtest.sh \
  --source-endpoints https://source-host:14569 \
  --source-explorer-endpoints http://source-host:14568 \
  --source-ns quod:bench_source --target-ns quod:bench_target \
  --agent-anchor <64-hex-character-source-anchor> \
  --agent-instance 'human_user(benchmark).' \
  --key-bundle /secure/path/benchmark-agent-key.json \
  --key-passphrase-env QUOD_BENCHMARK_KEY_PASSPHRASE \
  --goal 'benchmark_echo(ok)' --requests 2000 --concurrency 64
```

The source ontology must already contain the named agent instance, its active
public key, and the applicable `can_invoke/4` rules. The driver imports that
agent's encrypted browser-key export using the named environment variable; it
never creates a random identity or bypasses the normal signed-goal path.

Read goals are the simplest benchmark. Durable-write goals are also valid when
the target fixture supplies one. Put `__QUOD_REQUEST_ID__` in such a goal to
give every attempt a distinct operation id; the driver never retries an
uncertain write.

Concurrent durable requests use that exact same signed path. Foreign
single-target claims and target applications use the ordinary content batch,
so independent requests may share one source block and one target block.
Only real multi-target groups wait before Begin signing when a conflicting
group owns one of the same source keys; they are not sent through a
benchmark-only executor and are not re-proved. Non-conflicting groups share
canonical same-phase waves through the one consensus owner. A promoted plan
whose OCC reads became stale aborts normally and consumes its operation id; an
intentional application retry must use a newly signed id.

`scripts/loadtest.sh` can run this remote workload alongside its normal local
writers and churn. It is opt-in because the main driver cannot guess a safe
remote topology or application predicate. When enabled, its result is part of
the main PASS/FAIL verdict:

```sh
scripts/loadtest.sh --duration 300 --inter-ontology 1 \
  --inter-source-endpoints https://source-host:14569 \
  --inter-source-explorer-endpoints http://source-host:14568 \
  --inter-source-ns quod:bench_source \
  --inter-target-ns quod:bench_target \
  --inter-agent-anchor <64-hex-character-source-anchor> \
  --inter-agent-instance 'human_user(benchmark).' \
  --inter-key-bundle /secure/path/benchmark-agent-key.json \
  --inter-key-passphrase-env QUOD_BENCHMARK_KEY_PASSPHRASE \
  --inter-goal 'benchmark_echo(ok)' \
  --inter-requests 2000 --inter-concurrency 64
```

For a remote durable-write fixture, use for example
`--inter-mode execute --inter-goal 'dtx_chain(__QUOD_REQUEST_ID__)'`. The
driver uses the supplied agent's encrypted browser-key export and the same
challenge and signed-goal request code as the browser. A development
self-signed certificate requires the explicit `--insecure-tls` /
`--inter-insecure-tls 1` flag. The configured number of operations must fit
inside the selected chaos window; an unfinished remote workload fails the run
rather than continuing after the local workload ends.

The Nomad job exposes an opt-in two-host demo topology. It is disabled by
default and leaves quod:root unchanged. Before enabling it, obtain the
selected existing allocations' persistent keys from their `/api/summary`
(`.node.pubkey`). Set `directory_node_keys` and the exact
`directory_public_namespaces` entries for the source and target, then enable
`cross_ontology_enabled` with distinct source and target allocation indexes.
The existing root ledger supplies the control peer keys through
`directory_control_peer/1`; pinned control links disseminate the hosts' current
endpoints after a port rollover. There is no `directory_bootstraps` option or
compatibility fallback. After the rolling deployment, pass the source
allocation explorer endpoint to the script above. The two single-host demo
ontologies are a directory/ask benchmark, not a second consensus benchmark.

For any existing ontology, add one exact `directory_public_namespaces` entry:
its namespace and the public keys of hosts allowed to advertise it. The target
host publishes its own current endpoint through the existing directory-control
links, so dynamic p2p-port changes do not leave a configured stale address.
This writes neither ledger facts nor ACLs. Removing that entry and redeploying
removes the directory route.

## 11. Non-goals — deliberately NOT in this milestone

- **Ontology-subscription event delivery.** The local vocabulary, runtime
  catalogue, shared certified following, and local/remote reaction execution
  are implemented. Explicit events are implemented in the current working
  tree; hardware acceptance remains in `event-reaction-refinement-plan.md`.
  Section 5 explains why none of it is inferred from dead per-ask state.
- **The source-qualified `react_on/3` pattern grammar.** It is frozen and
  locally validated in `ontology-subscription-plan.md` Slice 1, not inferred
  from OCC granularity. Source-side publication filtering is deferred until
  certified follow fan-out is measured.
- **Ontology-creation authorization** (`X:*` ownership enforcement). Node
  signing is already live; authenticated origin-agent identity and the
  ontology-owned policy remain separate (§2).
- **Deeper name paths** (`thing:cat:max` as data). Parked.

## 12. What this changes for consensus

Cross-ontology asks still happen while a question **runs**, on the node running it
(prove-before-broadcast); apply never re-asks anything. A read-only proof creates no ledger
record. One signed foreign writer commits a metadata claim in the agent
ontology, then an ordinary target-authored application, followed by an
asynchronous metadata completion in the agent ontology. Read-only dependencies
provide f+1 certificates for their exact sealed snapshots and write no control
records. The certificate proves its reader's state when signed, not a lock on
that reader; a later reader change is valid. Two or more writers use explicit
DTX control barriers in their existing per-ontology Simplex logs; their
read-only dependencies remain in that
atomic group for now. Validators verify sealed plans, authorization transcripts,
OCC tokens, certified foreign references, and phase rules; they do not re-run the arbitrary
derivation.

Prepare installs the phase-aware ordinary-content admission lock and proof fence. The same
group's Decision and prepared Finalize may progress as their roles permit, while a direct
no-Prepare abort remains an independent metadata tombstone. Finalize reopens consensus
admission but the proof fence stays closed until the ordered Prolog apply/discard is published;
origin Complete then publishes the one terminal group outcome. Catch-up and replay fold these
same records and gates. Membership-vote re-proof remains synchronous with following disabled
(§4.1).
