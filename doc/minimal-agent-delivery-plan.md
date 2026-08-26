# Minimal durable agent delivery — Slices 3 and 4

**Status:** historical delivery-slice detail. The durable multi-ontology
transaction prerequisite and `action/3` foundation remain relevant, but its
former model of agents as records owned by an Agent Platform is superseded by
`ontology-actor-architecture.md`. No agent-delivery component is implemented
or deployed under the corrected model.

> **Do not implement the legacy identity and hosting examples below.** In
> particular, AP-owned `agent_owner_node/2`, a global user registry, and agents
> without an authoritative containing ontology are retired. The message-state, D/P/E ordering,
> idempotence, and failure analysis remain reference material and must be
> rewritten around anchored agent instances and committed host epochs before the
> delivery slice resumes.
>
> The later per-namespace `quod_outbox` scanner, dirty-bit, and generation-
> handoff design is also retired. The normative design in
> `agent-fipa-plan.md` §9 keeps the committed outbox fact as sole custody and
> uses one founding `state_handler/4` for both live changes and recovery to feed
> the hosted agent's one rebuildable delivery scheduler. It needs no duplicate
> `react_on/3` delivery wake. Do not implement section 5 below.

The lifecycle-only authorization and action runner cited in historical
sections have been retired. Current work follows
`ontology-lifecycle-single-path-plan.md`: one normal `can_invoke/4` boundary,
ordinary Prolog action prerequisites, and the existing durable effect journal.

## 1. Why this is next

`doc/agent-fipa-plan.md` is the normative base specification. It requires Quod to
finish reactions and reliable effects (Slice 3), then prove them with two real
hosted agents (Slice 4), before agent delegation and the full `subject/3`
authority chain.

That order is also required by `doc/ontology-lifecycle-authorization-plan.md`:
an agent subject may not be enabled until Quod has a real wielded agent,
receiving-side `accepts_wielding/2`, an immutable non-empty agent chain,
authoritative capability derivation, authenticated replay-protected command
ingress, exact subject propagation through `::`, and validator-side transaction
authorization.

That lifecycle requirement is stricter than the broad sequencing currently in
`agent-fipa-plan.md`, which lists agent subjects in Slice 5 but complete
wielding in Slice 6. Before subject work begins, those sections must be aligned:
the next subject milestone must include the minimum real wielding,
`accepts_wielding/2`, and capability derivation needed to make its subject
truthful. It must not enable a subject first and repair it one slice later.

The earlier signed-client generation introduced a signature-bound `{user, Key}`
base principal. The deployed generation replaces it atomically with the stable
agent reference defined by `generic-agent-identity-plan.md`. This milestone
still introduces no empty agent chain or
caller-supplied capabilities. Nodes, agents, human users, and services have
classed instances in exact containing ontologies; endpoints and private keys
are not ontology facts.

The milestone combines Slices 3 and 4 in one reviewed vertical plan, while
implementing them in their normative order. The Slice-3 substrate is immediately
consumed by the Slice-4 two-agent path; no unused generic effect framework is
left behind.

### 1.1 Sources and precedence used for this plan

The Quod specifications were reread first and are normative, in particular
`agent-fipa-plan.md`, `ontology-lifecycle-authorization-plan.md`,
`inter-ontology.md`, `transaction-signatures.md`, `content-layer.md`, and the
relevant identity/deferred notes. The current `quod_runtime`, `quod_prolog`,
`quod_ns`, overlay, proof-scope, wire, transport, schema, and Nomad paths were checked
against those documents rather than inferred from memory.

Onia and BBSVX documentation/code are secondary pattern references only. This
plan keeps their useful D/P/E split, action/goal discipline, immutable ground
work descriptors, stable IDs, ownership gating, bounded retries, and
`react_on/3` shape. It does not copy BBSVX replay/fire-and-forget effects or
Onia's incomplete caller-supplied authority, authentication, and cross-ontology
subject propagation. Where wording conflicts, this document follows Quod.
The means--ends shape was also cross-checked against Bratko's Prolog planner
(goal, candidate action, preconditions, then action) and Poole--Mackworth's
state/action/precondition planning model; these are conceptual checks, not code
dependencies: <https://djvu.online/file/1aOUJssWgu45e> and
<https://www.cs.ubc.ca/~poole/aibook/html1e/ArtInt_201.html>.

Section 3.1 records the correction implemented in Quod's action
executor. `action/3` describes a transition, its prerequisites, and the desired
state. A transition may assert that state directly, as several reference
actions do, but the runner must not assume that this is the only way to reach
it. The correction was reviewed and its implementation updates
`agent-fipa-plan.md` and every dependent Quod document in the same isolated
delta.

This is a deliberate correction of Quod's executor under Yan's stated contract,
not a dismissal of the BBSVX/Onia action pattern. Their common executors use an
automatic assert/retract implementation for the third argument, while their
wider action catalog demonstrates varied named/external transitions and desired
states. They are evidence for the surrounding means--ends vocabulary; Quod
implements the general transition-to-state relation rather than copying one
executor verbatim.

## 2. User-visible result

One Agent Platform ontology contains two fixed test agents on distinct owners.
A normal Prolog action in that ontology can stage:

```prolog
outbox(MessageId,
       agent(Sender),
       agent(Receiver),
       Payload,
       pending).
```

After the transaction commits:

1. every replica stores the same outbox fact;
2. only the node that currently owns `Sender` attempts delivery;
3. the receiver side of that same AP commits the durable inbox receipt before
   acknowledging it;
4. the sender replaces the pending outbox with its delivered status through
   another ordinary Prolog transaction;
5. the receiving agent processes the committed inbox item once, independently
   of sender availability.

Crashing the sender, receiver, runtime, agent process, or current host node at any
point may cause another transmission, but it must not cause another logical
receiver action. A pending durable message is recovered from committed facts,
not from replaying historical reactions.

The first slice is deliberately **same-AP only**: both agents belong to this AP
ontology and every host serves the same committed AP view. It does not carry an
unused target-namespace field or pretend that cross-AP routing is already
designed. A later real cross-AP milestone may make a clean breaking change to
the destination term.

The same concrete agent path also exercises one bounded best-effort
notification and one acknowledged volatile delivery. It does not expose an
abstract plugin or callback API.

## 3. Durable Prolog truth

The AP ontology owns the application state and policy. The minimum vocabulary
is:

```prolog
agent_owner_node(Agent, NodeKey).

outbox(MessageId, Executor, Destination, Payload, pending).
outbox(MessageId, Executor, Destination, Payload, delivered).
outbox(MessageId, Executor, Destination, Payload, failed(Reason)).
outbox(MessageId, Executor, Destination, Payload, cancelled).

inbox(MessageId, Receiver, Source, Payload, pending).
inbox(MessageId, Receiver, Source, Payload, done).
inbox(MessageId, Receiver, Source, Payload, failed(Reason)).
inbox(MessageId, Receiver, Source, Payload, cancelled).
message_processed(MessageId, Receiver, Source, Payload).
```

The exact send, receive, consume, and complete operations are declared through
the corrected `action(Transition, Prerequisites, DesiredState)` /
`goal(DesiredState)` pattern below. Their real transition predicates use
ordinary Prolog assertions and retractions in one proof overlay, so each
multi-fact transition is one normal consensus transaction. Erlang does not
mutate an ontology table directly.

### 3.1 Correct `action/3` once, before delivery

`doc/distributed-proof-plan.md` is the normative prerequisite for this section.
It corrects both the action relation and the `::` execution model before agent
delivery begins. The removed Quod common code treated argument three as an
effect to assert and argument one as only a label. The corrected relation is:

```prolog
action(Transition, Prerequisites, DesiredState).
```

`goal(DesiredState)` first proves the desired state and cuts if it is already
true. Otherwise it enumerates every matching action clause in Prolog order. One
candidate consists of its ordered prerequisites, its single/list transition,
and its final desired-state check, all inside `transaction/1`. Candidate
failure restores assertions, retractions, and abolishes in every selected
ontology, preserves the bounded failure reasons, and allows the next action
clause reaching the same state to run. Candidate success adopts its staged
state. No declaration-selection cut prevents valid alternatives.

Prerequisites are a finite proper list of callable state checks and, like the
initial/final desired-state checks, run through Quod's existing strict read-only
overlay against the current staged view. Recursive state achievement is written
explicitly as `goal(State)` and may transition inside the surrounding
transaction; `Ns::goal(State)` does the same in the selected ontology. Every
other cross-ontology prerequisite uses the same read-only state-check context
under `Ns::Goal`. `Transition` is one non-variable callable predicate or a
non-empty proper list of them and may stage D writes. Invalid shapes fail before
invocation. Keep term-identity cycle detection.

`transaction/1` is a Quod compiled predicate over the existing immutable
overlay and, once distributed scopes land, their shared proof context. It is
semidet: it searches alternatives until the first complete solution, adopts
that state, and exposes no inner redo. The pinned Erlog fork supplies an
explicit checkpoint mode so each alternative restores the staged database it
was created from; ordinary proofs never enter that mode. On total failure or
error it restores local and foreign assertions, retractions, and abolishes;
failure reasons remain available. A cut has only normal Prolog scope and never
commits a ledger. Only outermost proof success starts the atomic commit
described by `distributed-proof-plan.md`.

Framework-owned transitions are named predicates. Their bodies may use
`assertz/1` and `retract/1`; failed candidates are rolled back by
`transaction/1`, and `goal/1` never infers or asserts a desired state. Remove
the old catch-all `assert_fact/1` and
`remove_fact/1` actions entirely: under target-driven semantics they cannot
soundly distinguish an exact stored fact from a fact proved by a rule, and no
current production caller needs them. Ontology code defines an explicit named
transition for each domain change. Deliberate administrative rule/fact edits
continue to use Quod's existing direct `assertz`/`retract` transaction path.
There is no compatibility wrapper.

Ontology lifecycle uses the same action and proof path as every
other durable goal. The public staging predicate first validates only the
ground action's structure and registers one opaque proof-local request. The
shared `action/3` relation then applies the normal `can_invoke/4` entry policy
and the controlling ontology's prerequisites: root for create, node for join.
Only the internal continuation for
that exact request reads or compiles mutable source input, builds one immutable
descriptor, and stages one direct effect in the proof overlay.

This preserves the existing decision-before-filesystem-IO boundary: an
undeclared or unauthorized request cannot make Quod read an attacker-selected
path or disclose its parse/timing result. Full compilation still precedes the
desired-state check, so malformed Prolog cannot become idempotent success.

Fresh founding injects the bodyless host-entry
`can_invoke(_, _, [], _)` beside the generated incarnation and committee facts,
so an author need not repeat it and cannot create an ontology that rejects its
own host. Author-supplied `can_invoke/4` clauses govern remote and
cross-ontology callers. `quod_simplex:genesis_tx/4` validates the combined
generated-plus-authored diff before append, and
`valid_history_entry/4 -> valid_genesis_transaction/2` applies the same
assertion-only/policy-present invariant on restart and catch-up. A resume does
not require newly supplied, ignored terms to repeat genesis policy.

That invariant is not genesis-only. The distributed-proof prerequisite rejects
an ordinary or distributed diff touching `{can_invoke,4}` when its final
post-diff state would contain no such clause. Atomic replacement remains valid;
removal-only fails as `policy_self_seal_forbidden`. The check reuses the
immutable candidate state already built for apply/Prepare and creates neither a
second Prolog policy proof nor an operator repair bypass.

Compilation is not repeated at namespace start. The prepared create descriptor
carries the compiled `InitialDiff`, not a source path or a term list. Its
deterministic encoding must be at most 192 KiB; one shared
`MAX_GENESIS_INITIAL_DIFF_BYTES` constant in `quod_ingress_limits.hrl` is used
by runtime preparation, config validation, and the genesis builder. Runtime
creation rejects a larger diff as
`ontology_creation_failed(initial_content_too_large)` before manager or storage
mutation. The complete generated genesis transaction remains subject to the
existing exact 256 KiB block limit. The fresh config carries
`genesis_diff => InitialDiff`, mutually exclusive with
`genesis_file`. `quod_simplex:genesis_tx/4` compiles only its
generated incarnation/committee facts, combines those assertions with
`InitialDiff` in one linear assembly (no repeated `++`), validates the final
genesis diff, and appends it. Boot files compile once inside the same genesis
builder; runtime input is compiled before entering it. Resume may discard its
once-compiled, ignored replacement diff after confirming the existing V3
ledger.

The original ground action remains the term matched by root's creation or
node's join declaration and policy. The descriptor carries canonical namespace/options plus the already-read
and compiled `InitialDiff` for create, or the raw 32-byte anchor plus normalized
seeds for join. Factor the structural and full preparation functions out of
`quod_ontology`'s current private option/hash/seed handling. The trusted public
create/join API calls preparation and the corresponding prepared executor in
sequence. The ordinary action path inserts declaration and prerequisite checks
between structural and full preparation and passes the same descriptor to the
post-commit journal. Both entry paths reuse the same validation and neither
reads nor compiles mutable input twice. The low-level same-VM API manages
hosting only; every public Prolog request obeys `can_invoke/4` and the declared
action prerequisites.

After full preparation, one read-only action preparer enumerates the exact requested transition's
declarations in Prolog order, binds one declaration and its ground desired state
once, checks that state, and otherwise proves that same declaration's
prerequisites. It reports `already` or `execute`; it never re-resolves an
existential declaration in Erlang. `action_declared/4` loses its literal-`true`
rule and remains only the exact-declaration/not-declared classifier, or is
removed if the preparer can preserve the same public failure distinction
without it.

Authorization happens once through the ordinary proof entry and the selected
action prerequisites; target-first idempotence never bypasses it. If the
desired state already holds, no effect is staged. Otherwise the proof commits
the exact prepared effect in the controlling ontology transaction. The one
node-wide journal invokes only the typed create/join helper after commit and
verifies the real desired state. A failed real-state check after the helper ran
is `outcome_unknown`, because local state may already have changed. No generic
external transition dispatcher is introduced.

If a concurrent start or stop wins after the read-only prerequisite and the
manager returns `{already_configured, Namespace}`, retain the existing bounded
mapping: create fails with `ontology_creation_failed(already_hosted)` and join
with `ontology_join_failed(already_hosted)`. It is a definite race result, not
`outcome_unknown`, and the runner neither waits nor retries the lifecycle IO.

Lifecycle desired states do not let idempotence hide incompatible input. Input
validation always precedes the target check. Creation retains its documented
resume behavior: valid new `Options` are ignored only when the namespace already
has a live ledger, and that result is explicitly `resumed`. Join additionally
proves that the live namespace's anchor equals the requested `GenesisHash`;
seeds remain non-authoritative route hints. Creation is declared in
`quod:root`; join is declared in `quod:node`. They use the same explicit helper
shape:

```prolog
ontology_hosted(Name) :- ontology_join_state(Name, starting).
ontology_hosted(Name) :- ontology_join_state(Name, joining).
ontology_hosted(Name) :- ontology_join_state(Name, ready).

action('$quod_stage_ontology'(Handle,
                              create_ontology(Name, Options),
                              ontology_hosted(Name)),
       [current_principal(Agent),
        can_create_ontology(Agent, Name, Options),
        ontology_join_state(Name, not_hosted)],
       ontology_hosted(Name)).
```

The node declaration is:

```prolog
ontology_hosted(Name) :- ontology_join_state(Name, starting).
ontology_hosted(Name) :- ontology_join_state(Name, joining).
ontology_hosted(Name) :- ontology_join_state(Name, ready).

ontology_joined(Name, GenesisHash) :-
    ontology_hosted(Name),
    ontology_genesis_anchor(Name, GenesisHash).

action('$quod_stage_ontology'(Handle,
                              join_ontology(Name, GenesisHash, Seeds),
                              ontology_joined(Name, GenesisHash)),
       [current_principal(Agent),
        can_join_ontology(Agent, Name, GenesisHash, Seeds),
        ontology_join_state(Name, not_hosted)],
       ontology_joined(Name, GenesisHash)).
```

Thus a repeated valid create request uses explicit resume semantics, while a
repeated join returns immediately only for the requested anchor. The existing
public state predicate still distinguishes `starting`, `joining`, and `ready`
for polling. Mirrored `ontology_hosted/1` rules in root and node observe the
same node-local state; they do not duplicate execution. `ontology_hosted/1` is
intentionally the creation target: startup
`mode=create|join` is not a durable ontology property, and a founder is normally
restarted later in join mode, so inventing `ontology_created/1` would encode
deployment history rather than desired state. A valid prior join may therefore
satisfy “this ontology is hosted,” after create input has still been validated.

`ontology_genesis_anchor/2` is a read-only, `quod:node`-only adapter. It normalizes the
public 64-hex or raw representation and compares raw 32-byte anchors. It reads
the live `quod_simplex:genesis_hash/1` when available and the serialized
manager desired config while `starting`, so exact repeated joins do not fail
during startup. It adds no state store.

Inventory and rewrite every action previously added by this project: remove
both generic common actions; rewrite the two root lifecycle actions and their
live committed root clauses, the `make_marker` and `blocked_action` test
declarations, every
planned AP transition below; and every test/extractor. The source audit covers
`priv/ontologies/common_predicates.pl`, `priv/ontologies/quod_root.pl`,
`src/quod_prolog.erl`, `src/quod_ontology.erl`,
`src/predicates/quod_ontology_predicates.erl`,
`test/quod_ontology_tests.erl`, and `test/join_SUITE.erl`. The documentation
audit covers `agent-fipa-plan.md`, `ontology-creation-plan.md`,
`ontology-creation-input-plan.md`, `ontology-join-plan.md`,
`ontology-lifecycle-authorization-plan.md`, `client-world-direction.md`, and
this plan; a final repository-wide search must find no stale action/effect
contract.
Remove `assert_effect/1`, effect-based forward/reverse resolution,
`reverse_goal_allowed/1`, literal-`true` lifecycle declarations, and any helper
made unreachable by the correction. The pinned Erlog dependency advances once
to the reviewed commit containing the opt-in choice-point checkpoint hooks; no
second interpreter or compatibility path is retained.

The existing creation test is rewritten concretely, not merely renamed:

```prolog
make_marker(Value) :- assertz(made(Value)).
action(make_marker(reverse), [allowed(reverse)], made(reverse)).

record_common_fact(Value) :- assertz(common_fact(Value)).
action(record_common_fact(asserted), [], common_fact(asserted)).

record_blocked_action :- assertz(blocked_action).
action(record_blocked_action,
       [fail_with_reason(blocked_by_policy)],
       blocked_action).
```

It continues to call `goal(made(reverse))`, `goal(common_fact(asserted))`, and
`goal(blocked_action)`; the first two prove real transitions and the third
retains the expected failure stack without using `true` as a fake state.

A focused regression suite pins target-first idempotence, two different
transitions reaching the same state, prerequisite selection, single and list
transitions, declaration order, post-transition verification, cycle detection,
explicit domain transitions, failure-reason stacking, and both lifecycle
transitions.

The distributed-proof prerequisite deliberately breaks the ledger, signature,
directory, and root common-predicate contracts. Its release is therefore
re-founded from the corrected `quod_root.pl`; the old literal-`true`
declarations are never migrated in place and no old-binary choreography or
compatibility branch remains. This later agent-delivery slice starts only on
that freshly founded contract and does not itself change consensus formats.

Rules enforce these invariants:

- `MessageId` is a ground 32-byte binary supplied by the initiating action.
  It is part of the eventual signed action envelope in Slice 5; this slice does
  not invent another identifier later during delivery.
- Reusing a `MessageId` with different source, destination, or payload is an
  immutable terminal conflict.
- Receiving the same message again succeeds idempotently but stages no second
  inbox item and runs no second agent action.
- Outbox completion is idempotent and replaces the exact pending record with
  its delivered record only after a receiver acknowledgement.
- Durable delivered/failed/cancelled source records and receiver receipts are
  retained. Durable effects are explicitly the low-rate class, and retaining
  them is the only safe first-slice rule across an arbitrarily long outage. They
  live in the AP ontology, not in root. No unsafe TTL deletion is added. A later
  compaction protocol may remove receipts only when it can prove that no owner
  can resend them.
- Acknowledged volatile messages instead have a finite retry deadline. Their
  in-memory dedup entries live at least through that deadline and are bounded;
  sender-process loss is allowed by that delivery class.

The AP genesis also contains one immutable, validated
`delivery_limits(MaxHostedAgents, MaxOutboxNamespace, MaxPerExecutor,
MaxInboxNamespace, MaxPerReceiver, MaxPayloadBytes, MaxVolatileAgeMs)` fact.
`MaxPayloadBytes` is the canonical encoded payload size and may be lower than,
but never exceed, the shared 4 KiB agent-payload ceiling. The distributed-proof
prerequisite's 8 KiB nested/top-level goal envelope and 24 KiB local-plan cap
therefore accommodate one maximum payload plus its action, identity, and routing
metadata. The 64 KiB proof-answer cap is a different resource and is not reused
as the message limit. Bulk media/data is stored in its ontology and referenced
by identity/hash rather than embedded in a lifecycle proof.
Ownership transitions prove the hosted-agent cap before adding a new owner, and
runtime refuses to materialize more than that committed bound even if malformed
raw writes bypass the normal action. A pure query-class
`agent_host_capacity_available(Agent)` bounded-counts distinct agents in
`agent_owner_node/2` to `MaxHostedAgents + 1`; moving an already-owned agent
does not consume another slot. It reads both `delivery_limits/7` and
`agent_owner_node/2` through the proof view, so both enter `read_check` and two
concurrent last-slot assignments cannot both apply. Missing, duplicate, or
invalid limits, conflicting owners, and overflow fail closed before mutation.

If a raw direct write still creates overflow or conflicting owners, the next
pinned P fold detects it before building another map entry. A conflicting owner
stops and freezes that affected agent; global overflow or invalid limits stops
and freezes every hosted agent for the namespace. No quarantined worker handles
mail or external effects. Runtime retains only bounded diagnostics, starts no
additional agent, and reconciles deterministically after a normal repair. It
does not retain a history-dependent worker subset, choose an arbitrary subset
as ontology truth, or grow another index.

The ordinary durable source action must
prove a pure query-class
`outbox_capacity_available(Executor)` before it asserts a pending outbox. That
predicate counts the current proof view only up to each limit plus one,
including already staged changes, and fails closed if
the limits are absent, duplicated, nonground, or invalid. The predicate reads
through the normal Erlog DB path so `delivery_limits/7` and `outbox/5` enter
Quod's `read_check`. At apply, existing OCC rejects/retries a candidate whose
observed heads changed, so concurrent candidates that both saw the last free
slot cannot both commit. The pending population can never
first exceed the cap and only later be noticed by a runtime queue. This is not a
node-local counter or a second policy store. The three initiating AP actions
also validate the ground message id, payload encoding size, and (for volatile
delivery) `MaxAgeMs` against this same founding fact before committing their
event.

Receiver admission similarly proves
`inbox_capacity_available(Receiver)` against both inbox caps and reads
`inbox/5` through the overlay into the transaction read-set. A full receiver
returns the retryable `busy` acknowledgement and stages nothing. Sender
completion cannot therefore hide an unbounded slow-receiver backlog: the
consensus-visible inbox cap remains enforced independently of the source
outbox cap.

“Immutable” uses the existing founding-content execution gate, not a claimed
write ACL that Quod does not yet have: the one slot-1 term must still be present
and byte-equivalent after canonical decoding. A later direct alteration or
duplicate cannot become an executable limit; it enters the scoped delivery
quarantine described below until repaired.

The normal Prolog action vocabulary owns every durable transition:

- receiver admission asserts one exact pending `inbox/5`; an exact existing
  pending/done receipt returns a duplicate acknowledgement, while a
  failed/cancelled receipt returns its fixed terminal outcome;
- successful sender completion atomically retracts the exact pending outbox and
  asserts the delivered form;
- a well-formed immutable terminal rejection atomically replaces pending with
  `failed(ClosedReason)`;
- the AP's one test consume action atomically retracts the exact pending inbox,
  asserts its done form, and asserts
  `message_processed(MessageId, Receiver, Source, Payload)` as the test's domain
  change;
- definitive consume failure atomically replaces pending with
  `failed(action_failed)`;
- explicit policy requests submit the corresponding
  `goal(outbox_state(..., pending | cancelled))` or
  `goal(inbox_state(..., pending | cancelled))`; `retry_*` and `cancel_*` are
  the selected exact transitions, not forward action names. They are the only
  recovery/cancellation transitions.

The AP source uses integrity-aware desired-state predicates rather than raw
fact presence. Each helper proves the exact tuple, one compatible status/owner
for its stable id, valid immutable limits, and no conflicting record. For
example, `outbox_state/5` fails if pending and delivered rows coexist, if one id
names different content, or if limits are invalid. Target-first idempotence
therefore cannot hide corruption; malformed raw writes enter quarantine.

The core desired states and real transition predicates are:

| Desired state | Alternative transition predicate(s) |
|---|---|
| `agent_owned_by(Agent, NodeKey)` | `assign_agent_owner(Agent, NodeKey)` when unowned; `move_agent_owner(Agent, OldKey, NodeKey)` from an existing owner |
| `notice_state(Id, Receiver, Payload)` | `record_agent_notice(Id, Receiver, Payload)` |
| `volatile_state(Id, Sender, Receiver, Payload, MaxAgeMs)` | `record_agent_volatile(Id, Sender, Receiver, Payload, MaxAgeMs)` |
| `outbox_state(Id, agent(Sender), agent(Receiver), Payload, pending)` | `record_outbox(Id, Sender, Receiver, Payload)` for a new id; `retry_outbox(Id, Sender, Receiver, Payload)` from one retryable failed row |
| `inbox_state(Id, Receiver, agent(Sender), Payload, pending)` | `record_inbox(Id, Receiver, Sender, Payload)` for a new id; `retry_inbox(Id, Receiver, Sender, Payload)` from one retryable failed row |
| `outbox_state(Id, agent(Sender), agent(Receiver), Payload, delivered)` | `complete_outbox(Id, Sender, Receiver, Payload)` from exact pending |
| `outbox_state(Id, agent(Sender), agent(Receiver), Payload, failed(Reason))` | `fail_outbox(Id, Sender, Receiver, Payload, Reason)` from exact pending |
| `outbox_state(Id, agent(Sender), agent(Receiver), Payload, cancelled)` | `cancel_outbox(Id, Sender, Receiver, Payload)` from exact pending/failed |
| `inbox_state(Id, Receiver, Source, Payload, failed(action_failed))` | `fail_inbox(Id, Receiver, Source, Payload, action_failed)` from exact pending |
| `inbox_state(Id, Receiver, Source, Payload, cancelled)` | `cancel_inbox(Id, Receiver, Source, Payload)` from exact pending/failed |
| `processed_inbox(Id, Receiver, Source, Payload)` | `[mark_inbox_done(Id, Receiver, Source, Payload), record_message_processed(Id, Receiver, Source, Payload)]`; the target proves exact inbox `done` and the domain fact |

This deliberately demonstrates both properties of the corrected pattern:
several action clauses may reach the same owner/outbox/inbox state, and one
action may need an ordered list of transition predicates. The transition predicates contain
the actual `assertz`/`retract` operations; every fallible policy and exact-old-
state check precedes them. Target-first `goal/1` makes retries idempotent without
an extra empty action clause. Because the desired-state helpers encode the
whole valid state, a mismatch fails instead of being hidden. No payload is
called as a goal.

An outbox `cancelled` desired state means “stop future source retries”; it cannot
revoke an inbox already committed before a lost acknowledgement. An inbox
`cancelled` desired state affects only a still-pending receiver receipt, and
neither transition pretends to undo a completed domain change. Full FIPA
cancellation semantics remain a later protocol.

Closed reasons are a small fixed atom set such as `malformed_record`,
`oversized_payload`, `id_conflict`, and `action_failed`; arbitrary peer text is
never committed. Route loss, link failure, ownership/policy changes, temporary
unavailability, and `outcome_unknown` are mutable conditions and remain
retryable rather than being mislabeled terminal. A raw malformed fact committed
through the direct Prolog write path is never sent or silently
rewritten by Erlang. `quod_outbox` quarantines the affected MessageId, or the
namespace's delivery tier when a global limits record is invalid, while normal
proofs and P reconciliation remain available. Every relevant changed-head event
and explicit delivery reconciliation revalidates current D and clears the
quarantine automatically only after the bad/conflicting record is repaired.
The bounded reason and age are observable; this does not enter
`quod_runtime`'s existing permanent handler-unhealthy mode.

The common baseline adds only the executor resolution rules shared by runtime
consumers:

```prolog
executor_owner_node(node(NodeKey), NodeKey).
executor_owner_node(agent(Agent), NodeKey) :-
    agent_owner_node(Agent, NodeKey).
```

An executor must resolve to exactly one 32-byte node key in the same committed
snapshot. Zero or multiple answers are an integrity failure and produce no
external effect. Ownership remains ontology truth; there is no second Erlang
ownership registry.

`quod:human_user` in this historical milestone contains only the minimal common
vocabulary required by its former Slice-4 specification. It contains no human
records, keys, login path, or active authorization. Those arrive together in
the corrected actor plan.
Agent identity is the canonical `agent_instance_ref/3` byte representation,
independent of its current Agent Platform. The FIPA AID text form is fixed by
`agent-fipa-plan.md` §12; this historical slice defines no competing encoding.

## 4. Reactions: extend the existing P-to-E boundary

After the distributed-proof prerequisite, `quod_prolog` emits one
`applied_live` envelope per live-applied material transaction with canonical commit identity
`{transaction, TxId} | {group, GroupId}`. `quod_runtime` consumes those
envelopes, including effect-only transactions whose D diff is empty, runs P
from the block-final snapshot, and owns the reserved
`e_frontier`. No consensus, ingress, ledger, or apply-process callback is added.

### 4.1 Trusted declarations

The declaration remains the approved form:

```prolog
react_on(Executor, Pattern, Handler).
```

Despite this plan's agent examples, `Executor` is a generic logical effect
owner, not an event source or agent class. Other ontologies may use
`service(S)`, `node(NodeKey)`, or another callable term with exactly one owner;
source selection remains inside the local or source-qualified `Pattern`.

For this slice `Pattern` is one `assert(FactPattern)` or
`retract(FactPattern)`. Variables may connect the pattern to `Executor` and
`Handler`, as in the approved example. It matches only plain-fact operations
(clause body `true`) and uses Erlog unification against each operation in the
canonical reducer's ordered `applied_ops`. Identical assertions and absent
retractions are no-ops and produce no reaction. Rule changes do not
accidentally look like fact events. Matching is not a scan of the later KB and
it does not collapse several commit identities into one reaction.

The exact interpreter seam is `erlog_int:unify_prove_body`: runtime indexing
may reduce the candidate declarations, but matching the concrete event and
continuing the reaction with its bindings is one Prolog operation. Do not add
an Erlang term-equality shortcut or another unifier.

Reaction declarations use the same founding-only authority as
`state_handler/4`, adapted for their intentional variables:

- only a `react_on/3` fact asserted by slot 1 and still present may execute;
- founding and stored clauses are alpha-normalized by variable first occurrence
  before full-clause comparison; changing executor, pattern, goal, or body does
  not pass the gate merely because variables were renamed;
- duplicate copies of the same alpha-normalized declaration collapse to one
  active declaration;
- every variable used by `Executor` or `Handler` must occur in `Pattern`, and
  both terms must be ground after a concrete match;
- a later declaration is refused and counted;
- a retracted or malformed founding declaration makes the runtime unhealthy;
- only a fact body (`true`) is accepted.

`Handler` is ordinary trusted Prolog, continued with the bindings installed
by `erlog_int:unify_prove_body`. It runs in the shared `reaction` context.
Query-class and reaction-class external predicates are allowed there; staging
and projection predicates are refused, and any staged D is a loud failure.
Observable Erlang functions such as notification or outbox wake-up bridges are
registered by the ontology's existing predicate module with class `reaction`.
There is no closed typed-effect term catalogue, MFA callback, broad global
effect registry, or second dispatcher.

Illustrative declarations remain ordinary Prolog:

```prolog
react_on(agent(Receiver),
         assert(agent_notice(Id, Receiver, Payload)),
         notify_agent(Id, Receiver, Payload)).

react_on(agent(Sender),
         assert(agent_volatile(Id, Sender, Receiver, Payload, MaxAgeMs)),
         send_volatile(Id, Sender, Receiver, Payload, MaxAgeMs)).

react_on(agent(Sender),
         assert(outbox(Id, agent(Sender), agent(Receiver), Payload, pending)),
         schedule_outbox(Id, agent(Sender), agent(Receiver), Payload)).

react_on(agent(Receiver),
         assert(inbox(Id, Receiver, Source, Payload, pending)),
         wake_agent(Receiver, Id)).
```

`agent_notice/3` and `agent_volatile/5` are ordinary facts in the test AP, not
new system framework. Its founding actions assert them to exercise the two
non-durable classes. Historical occurrences remain D, but replay never turns
them back into E; later application rules may retract them normally.

`notify_agent/3` is local best-effort delivery on the receiver's owner. It puts
one bounded message in that hosted agent's live mailbox, never opens a network
stream, never retries, never acknowledges, and counts a drop if the process or
queue is unavailable.

`send_volatile/5` is acknowledged volatile delivery from the sender owner to
the receiver owner. Admission derives a local monotonic deadline from the
bounded `MaxAgeMs`; it retries the same `Id` until that deadline or the fixed
attempt cap, whichever comes first. Sender/runtime death loses the work by
design. The receiver keeps a bounded in-memory `Id => {content_digest,
expiry}` map for at least `MaxAgeMs` plus the configured transport margin,
delivers an exact duplicate once, and acknowledges duplicates without a second
mailbox delivery. No outbox or inbox fact is created for this class.

`schedule_outbox/4` is the fast edge for durable sender work. Independently of
that bounded edge queue, every live `outbox/5` changed head sets one
level-triggered **namespace durable-outbox dirty bit** before P/E admission.
The bit clears only after a current pinned fold and generation handoff prove all
pending intents installed and no newer dirty generation exists. Queue overflow
or P failure may drop/delay the edge, never the obligation.

`wake_agent/2` is likewise only an edge notification for durable inbox work:
before any bounded queue admission, runtime also marks that hosted agent in a
bounded level-triggered dirty set.
The worker clears the bit only after a bounded current-D fold proves that no
pending inbox item remains; if work remains it reschedules itself. Dropping the
edge because a queue is full can therefore delay but never strand committed
inbox work. Runtime/agent restart reconstructs the same dirty obligation from
D.

### 4.2 Commit ordering

The runtime coalesces all changed heads at one applied height so P converges
once against the final snapshot. Keep that optimization, but retain the
original envelopes and canonical commit identities in apply order:

```text
block final snapshot
    -> union changed heads and finish all required P handlers
    -> match and freeze E descriptors for commit unit 1, 2, ...
    -> advance the E scheduling frontier
```

No external IO runs in the ordered P runner. It selects candidate declarations,
checks founding authority, unifies each applied operation through
`unify_prove_body`, and resolves the unique executor. It then schedules one
bounded reaction worker with the exact committed snapshot, source, declaration,
event, and installed bindings. That worker continues the ordinary Prolog
Handler in the `reaction` context and releases the snapshot pin when it exits.
No unbounded callback, raw process reference, or second effect descriptor
language crosses the boundary.

Declarations are indexed by source and outer event functor rather than scanned
for every operation. Both declarations and `applied_ops` use one canonical
order. Deterministic commit and operation ordinals are assigned after the
canonical reducer has omitted fact no-ops; explicit event occurrences remain
distinct. The live-only `ReactionId` is a
domain-separated hash of namespace, **block height**, canonical commit identity,
commit ordinal, operation ordinal, alpha-normalized declaration, exact matched
operation, bound executor, and bound Handler. It is therefore unique for
both ordinary and distributed applies, even when transaction-local IDs recur at
a later height, while distinct matching operations remain distinct. Hash inputs
use one canonical deterministic term encoding; no process-local term ordering
or PID/reference enters either ID.

Durable work has a separate restart-reconstructible `DeliveryId`: a
domain-separated hash of `{Namespace, MessageId, Executor, Destination,
Payload}` from the exact pending outbox fact's canonical deterministic wire
encoding. Both the live descriptor and
reconciliation derive it from those committed fields. Retries and ownership
transfer therefore retain the same durable identity without needing historical
transaction/declaration metadata. `MessageId` remains the protocol-visible
dedup key; `DeliveryId` is the local scheduler identity.

While touching this code, replace the current per-block `H0 ++ Heads`
accumulation with a linear ordered-set union. It can become quadratic in the
number of transactions in a block and the extra event metadata would amplify
it; the ordered representation also makes the planning order explicit.

### 4.3 Execution

Only the unique local owner found by the pinned ordered phase admits a live
descriptor. After the P frontier and snapshot floor advance, E calls the exact
internal handler selected by the closed typed registry. It runs no Erlog proof,
holds no snapshot, and performs no IO speculatively. This is the same
proof/decision-before-IO separation already used by the lifecycle action
runner, not a new effect context.

Immediately before a network send, the delivery worker rechecks both unique
ownership **and the exact pending outbox tuple** against the newest committed D
snapshot. This prevents a descriptor derived before a later operation in the
same block retracted, completed, or changed that record from sending stale
work. A stale old owner and a new owner may still overlap while their replicas
observe an ownership transaction at different times; the stable message id and
receiver deduplication are the correctness mechanism.

Acknowledged-volatile work similarly rechecks the exact current
`agent_volatile/5` fact before its first send and every retry. If a later
transaction in the same block already retracted it, planning suppresses the
send; if it disappears later, retries stop. These newest-D checks are bounded
requests through runtime's pinned snapshot API, not a long-lived outbox reader.
Best-effort notices remain true transaction events and intentionally do not gain
this stateful retry rule.

Replay never constructs E descriptors. Reconciliation reconstructs only exact
pending durable outbox/inbox obligations from current D; it does not reconstruct
best-effort or acknowledged-volatile history.

P failure prevents E release. Queue overflow drops and counts best-effort work,
but never drops durable outbox state: the latter remains pending in D and its
level-triggered dirty bit forces a fresh bounded fold as soon as the tier can
make progress, without requiring a crash or replay.

## 5. `quod_outbox`: one concrete delivery owner

Add one new per-namespace process, `quod_outbox`, after `quod_runtime` in
`quod_ns`'s `rest_for_one` order. A Prolog or runtime restart therefore also
restarts delivery; an outbox-only crash leaves consensus, the KB, and runtime
alive and reconstructs its queue from D.

It owns only rebuildable state:

- bounded ready and delayed queues;
- a bounded number of in-flight deliveries;
- retry deadlines and exponential backoff with jitter;
- acknowledged-volatile dedup entries;
- delivery counters and oldest-pending age.

It does not own a copied KB, a second durable journal, agent identity, or
policy. Its narrow internal interface is enqueue a frozen live descriptor,
reconcile pending D records, deliver/acknowledge, and expose stats. There is no
plugin API.

Restart reconciliation enumerates live `outbox/5` pending facts from the frozen
MVCC snapshot through a bounded predicate-clause fold. It must not use an
unbounded Prolog `findall/3`. The fold returns at most the configured cap plus
an overflow indication; exceeding the cap makes delivery unhealthy/backpressured
rather than silently omitting durable work; it uses the repairable scoped
delivery quarantine from section 3, not runtime's permanent handler-unhealthy
mode. This narrow bounded fold is added to `quod_prolog` as the reusable
snapshot API for later P consumers.

`quod_outbox` does not attach its own MVCC reader. On start it asks
`quod_runtime` for reconciliation; runtime performs the bounded fold while its
existing snapshot is pinned and hands over ground descriptors only. The
handoff is generation- and height-tagged and serialized by runtime:

1. runtime freezes the exact pending set at height `H` and starts generation
   `G`;
2. it installs that snapshot before forwarding any queued live durable
   descriptor above `H`;
3. outbox atomically replaces its rebuildable queue, acknowledges `{G,H}`, and
   ignores every stale-generation message;
4. only after that acknowledgement does runtime release live descriptors above
   `H` in commit order.

The outbox waits for this handshake before sending. This preserves the
one-runtime-pin contract, prevents a snapshot handle from outliving its floor,
and closes the snapshot/live gap. Snapshot and live admission use the same
`DeliveryId`, so overlap is idempotent.

Runtime monitors the exact outbox PID and gives each handoff a finite timeout.
If that PID dies or fails to acknowledge, runtime abandons `G`, retains only
the one durable-dirty bit (not an unbounded list of later descriptors), and
recomputes a fresh current snapshot for generation `G+1` after the supervised
replacement appears. A late ack or message from `G`/the old PID is ignored.
Further durable live heads coalesce into the dirty bit until the fresh handoff
completes; best-effort/volatile queues retain their own stated bounds.

Retries distinguish:

- temporary route, link, owner, timeout, or `outcome_unknown` failures: retain
  the same id and retry;
- immutable well-formed failures such as oversized content or an exact
  conflicting id: submit the ordinary
  `goal(outbox_state(..., failed(ClosedReason)))` and stop automatic delivery
  only after its selected transition commits;
- a forbidden peer, changed owner/policy, unavailable proof, or any other
  mutable authority result: retain pending and retry with bounded backoff;
- an ambiguous local completion transaction: re-read D before deciding whether
  to retry it.

The receiving path commits `inbox(..., pending)` before acknowledging. If that
admission returns `outcome_unknown`, it rereads the exact inbox receipt: present
means acknowledge, absent/unavailable means `busy` and lets the same id retry.
It never guesses success from a timeout. The hosted agent turns the receipt into
`inbox(..., done)` in the same transaction as its
one domain action. A duplicate pending or done receipt is acknowledged without
repeating that action. The acknowledgement means "durably in the target
mailbox," not "the target domain action has finished." Sender completion is a
separate idempotent transaction, matching the approved two source-side commits.
If inbox consumption definitively fails, that failed proof commits nothing;
the worker then submits the exact
`goal(inbox_state(Id, Receiver, Source, Payload, failed(action_failed)))`.
Only after that target-state transaction is known committed does it continue.
If execution returns an infrastructure error or
`outcome_unknown`, the worker rereads D,
uses capped exponential backoff, and does not spin; that one item remains
pending and is surfaced by age/health metrics, while other items and agents may
continue because this slice promises no conversation ordering.
Only explicit retry/cancel target-state requests move a failed receipt again.

For a same-AP agent-to-agent message, target inbox admission is a third
consensus transaction and later inbox consumption is a fourth when it changes
domain state; the load test reports each rather than calling the whole exchange
a two-commit path.

## 6. Minimal hosted agents

The first consumer is one AP ontology with two fixed test agents whose
`agent_owner_node/2` facts are committed once during setup. The two owners are
different nodes so the acceptance path cannot accidentally become local.
`quod_runtime` reconciles one tiny hosted-agent process only on each agent's
unique current host node. The process:

- is P, not D;
- keeps no private copy of the ontology;
- drains committed inbox facts whenever its level-triggered dirty obligation is
  set, in bounded batches, and clears that obligation only after current D
  proves there is no pending item;
- serializes work for that agent;
- calls only the AP's fixed desired state
  `goal(processed_inbox(Id, Receiver, Source, Payload))` through the normal
  transaction path; that target proves both exact inbox `done` and the domain
  fact, while payload data is never treated as an arbitrary goal;
- can be killed and reconstructed without losing or duplicating work.

The AP's founding content declares one ordinary `state_handler/4` watching
`agent_owner_node/2` and invoking a typed `reconcile_agents` projection
predicate. That keeps process start/stop in P and guarantees it completes before
the same block's inbox/outbox reactions enter E. It reuses the existing handler
ordering and provenance checks rather than adding an ownership event shortcut.

Keep this first process monitored by the existing runtime machinery while its
contract is this small. Do not add an AMS, DF, generic agent supervisor tree,
mailbox framework, or FIPA protocol merely to host two test agents. Split a
module only if the concrete implementation cannot remain clear inside the
runtime/outbox boundary.

Each worker dies with its owning runtime, and runtime keeps only
`AgentId => {Pid, Monitor}` plus bounded restart backoff. A worker `DOWN`
rechecks that one agent's current committed owner before restarting it; it never
blindly resurrects a process from stale P state.

An ownership change is an ordinary AP transaction. Runtime stops the old local
process and starts the new one from D. Pending outbox and inbox work then
reconciles under the new owner. The dirty set is one bit per locally hosted
agent, bounded by the separately capped hosted-agent population; it cannot grow
with mailbox depth.

Agent workers never attach an MVCC reader or query an unpinned snapshot. During
runtime reconciliation, the existing pinned worker performs a bounded fold of
`inbox/5` and seeds the local dirty-agent set. While
live, a dirty worker requests its next bounded ground batch from runtime;
runtime reads it through its current pinned snapshot and tags it with the
runtime generation/height. The worker reports completion, and runtime clears
the bit only after another pinned fold proves no pending receipt. Stale worker
generations are ignored. This is the same single-snapshot-owner rule as outbox,
not a second read path.

## 7. Wire and transport

Use one dedicated channel for the shared AP namespace. Delivery and acknowledgement
frames have one current fixed shape. They are size-checked before decoding,
decoded with `quod_safe_term`, and carry Prolog values only through
`quod_wire_term`. Unknown tags and shapes are rejected. There is no old reader,
dual stack, negotiation, or compatibility path.

The complete network vocabulary for this slice is:

```text
{agent_durable, MessageId, Sender, Receiver, WirePayload}
{agent_durable_ack, MessageId, accepted | duplicate |
                                   busy | {rejected, ClosedReason}}
{agent_volatile, MessageId, Sender, Receiver, WirePayload, MaxAgeMs}
{agent_volatile_ack, MessageId, accepted | duplicate |
                                  busy | {rejected, ClosedReason}}
```

The channel identity `{agent_delivery, Namespace}` supplies the AP namespace;
it is not duplicated inside each frame. `ClosedReason` uses the fixed atoms
defined by the D transition rules. `busy` and transport loss are retryable.
Best-effort `notify_agent/3` is local to the owner replica and has no wire or
acknowledgement.

The authenticated QUIC peer is a node key, never a user or agent. The trusted-
fleet Slice-4 receiver requires an admitted node and validates the destination
namespace, message id, sizes, executor ownership, and exact duplicate content
before invoking Prolog. The later subject milestone will additionally bind the
immutable user and agent subject; this slice does not put an optional or fake
subject field on the wire.

Concretely, before accepting a new durable delivery the receiver side proves
from the shared AP's committed view that the exact pending outbox exists and
that the authenticated peer is its unique executor owner. Before the sender
side commits completion, it proves that the exact receiver inbox exists and
that the acknowledging peer is the receiver agent's unique owner. A failed or unavailable
check is retryable and performs no mutation. Volatile delivery applies the same
peer/owner check to the exact committed `agent_volatile/5` event, then uses only
the bounded in-memory receipt. The first product test uses one AP ontology
replicated on both nodes, so these are local committed reads. Cross-AP directory
routing is deliberately absent.

Replies use the same two-leg connection rule as distributed proof scopes: a
request channel keyed by ontology and a separately opened return channel keyed
by the authenticated origin node. They never assume that a response may be
sent backward on a peer-opened stream.

### 7.1 One stream-priority table

Set RFC 9218 priority immediately after each outbound stream opens, before its
header or payload is sent. One pure `quod_quic:channel_policy/1` function owns
the table; its input is the existing encoded channel binary. It bounded-safe-
decodes only the known canonical terms (`binary_to_term(..., [safe])`) and
classifies every malformed/unknown binary as application traffic. `quod_conn`
uses the result at stream open and transport metrics use its fixed class label,
so the two cannot drift and no utility module is added:

Brahms is the sole remaining raw-namespace channel, which cannot be classified
exactly without treating every unknown raw binary as control traffic. Replace
it once with the deterministic `{brahms, Ns}` channel identity on both ends.
There is no listener for the retired raw shape. All priority decisions can then
match exact canonical channel identities and unknown application channels stay
low priority.

| Exact decoded channel | Urgency | Incremental |
|---|---:|---:|
| consensus `{log, Ns}` | 0 | false |
| catch-up `{catchup, Ns}` | 1 | true |
| ingress `{ingress, Ns}` | 2 | false |
| directory `quod_directory_control` | 2 | false |
| Brahms `{brahms, Ns}` | 2 | false |
| feed `{feed, Ns}` | 4 | true |
| proof scope `{quod_scope, Ns}` / return `{quod_scope_return, NodeKey}` | 4 | true |
| agent `{agent_delivery, Ns}` | 6 | true |
| unknown application channel | 6 | true |

Lower urgency numbers are scheduled first. Existing connection reuse and
ordinary link learning remain unchanged; this is one call to the pinned fork's
existing `quic:set_stream_priority/4`, not a second transport path.
Failure to assign the selected priority fails that stream open; it is not
silently sent at the library default.

RFC priority controls QUIC scheduling, not arbitrary producer CPU or mailbox
growth. Agent delivery therefore also has a bounded byte/frame rate before it
calls the transport. The mixed-traffic gate must exercise both an already-open
stream and connection/stream churn; the feature does not ship on the assumption
that the RFC call alone proves non-starvation.

## 8. Founding and restart topology

This slice must survive a full application/node restart, not only a supervisor
restart. Dynamic `create_ontology`/`join_ontology` intent is deliberately reset
at application boot, and those public actions correctly reject every `quod:*`
system namespace. Do not weaken either rule.

Add exactly three genesis sources under `priv/ontologies/`:

- `quod_human_user.pl` for `quod:human_user`;
- `quod_agent.pl` for `quod:agent`;
- `agent_delivery_ap.pl` for the same-AP test ontology.

Their immutable source terms are fixed before implementation review:

```prolog
%% quod_human_user.pl: only the explicit founding invocation policy in Slice 4.
can_invoke(_Goal, node(NodeKey), _CallChain, _Ns) :-
    peer_admitted(NodeKey, _, _, NodeKey).

%% quod_agent.pl: the same explicit policy plus the specified type seed.
can_invoke(_Goal, node(NodeKey), _CallChain, _Ns) :-
    peer_admitted(NodeKey, _, _, NodeKey).
isa(agent, thing).
isa(agent_platform, agent).
```

No user records, AMS, identity schema, or placeholder application policy is
added. The explicit node policy is real founding authorization: only a current
committee member may invoke these system ontologies in this pre-subject slice.
The AP genesis carries the same member-only `can_invoke/4` rule and exactly one
`delivery_limits(256, 1024, 256, 1024, 256, 4096, 30000)` fact,
`state_handler(agent_hosts, [agent_owner_node/2], [], reconcile_agents)`, the
four `react_on/3` declarations in section 4.1, and the transition/desired-state
actions named in section 3 (notice, volatile send, durable send, ownership
assignment/move, inbox admission, delivery completion, consume transition,
fail, retry, and cancel).
Claude reviews the final `.pl` text before it is ever founded. The two
`agent_owner_node/2` facts are committed later through a normal AP action once
the selected node keys are known; no deployment template manufactures Prolog
identity facts.

Root's registry is updated deliberately, not left stale. A normal transaction
on the existing root asserts exactly:

```prolog
system_ontology(quod:human_user, HumanUserAnchor).
system_ontology(quod:agent, AgentAnchor).
```

These terms are never baked into `quod_root.pl`: their anchors exist only after
the ontologies have been created normally. A fresh deployment creates them
through the ordinary lifecycle and then commits the exact rows through a normal
root transaction. The test AP is not a system ontology and is not registered
there. No root re-found or compatibility path is required.

Root's committed system catalogue now supplies the two system ontologies to the
existing namespace manager; Nomad does not render a second permanent content
list for them. Deployment first creates and registers them once. The test AP
remains an ordinary explicitly hosted test ontology:

1. keep the existing root block in anchored `join` mode and keep all existing
   `/quod/data` contents;
2. create `quod:human_user` and `quod:agent` once through the normal root
   lifecycle and capture their exact anchors;
3. commit the two `system_ontology/2` rows in root; their already-certified
   geneses, not root, pin their source-derived facts and predicate modules;
4. let every node's existing namespace manager resume a local copy or join the
   exact anchored histories through the normal directory; no Nomad content
   block or second bootstrap owner is added;
5. create the test AP as an ordinary ontology, host it on the selected test
   nodes through the normal lifecycle, admit its committee, and then commit its
   two agent ownership facts.

The new ledgers use normal namespace subdirectories under the existing
per-allocation `/quod/data` host volume. This slice performs no root wipe,
re-found, compatibility reader, or special system-ontology creation exception.
A full application or node restart rebuilds the system set from root and
resumes the exact local histories. Directory policy still decides which nodes
may advertise and serve each ontology; the root catalogue contains no endpoint.

## 9. Explicit bounds and observability

Consensus-visible admission/message limits come from the one immutable AP
`delivery_limits/7` fact and are validated identically by every replica.
Node-local concurrency, queue, timeout, and byte-rate defaults are
schema-validated. They may be tightened after the first load test without
changing logical acceptance. The implementation defines finite limits for:

- founding reactions and matches per canonical commit identity;
- encoded effect descriptor and message payload bytes;
- pending/in-flight work per namespace and per agent;
- simultaneous E workers;
- acknowledged-volatile retry count, deadline, and dedup entries;
- durable retry backoff and work performed per reconciliation pass;
- agent actions drained per wake-up.

Durable delivery has no attempt-count drop: a retryable item stays in D until
completion. Bounds limit concurrent work and retry rate, not correctness.

Metrics and Grafana expose reaction matches/runs/failures/skips, owner-resolution
failures, best-effort drops, volatile retries/dedup, durable pending/in-flight/
retry/completion counts, oldest pending age, queue saturation, agent process
count, and stream priority class. Logs identify namespace and stable message id
without logging arbitrary payloads.

## 10. Implementation order

These steps start only after every step and release gate in
`distributed-proof-plan.md` has passed, its hard-break release has been
re-founded and deployed, and the corrected `action/3` is the live baseline.
This slice verifies that baseline; it does not implement the action refactor a
second time or change the pinned Erlog fork.

1. Extend `quod_runtime`'s existing pure planning section with founding reaction
   validation/indexing, applied-operation matching, canonical IDs, and executor
   resolution. The existing block P runner calls it while pinned and then
   performs bounded E admission. Following Quod's module
   boundary spec, do not create a reaction module before measured complexity or
   a concrete cohesion problem justifies that split.
2. Add the one `reaction` predicate class/context row and the concrete
   ontology-owned reaction bridges through the existing predicate-module
   dispatcher. Add the single channel-priority classifier/call and focused
   transport tests before new traffic shares connections.
3. Add `quod_outbox`: first the concrete acknowledged-volatile wire/retry/dedup
   path, then the bounded snapshot fact fold, generation handoff, durable
   admission/terminal actions, durable receiver receipts, retry, and
   completion. The runtime remains the sole snapshot owner.
4. Add the fixed consume worker behind `quod_runtime`'s bounded
   owner/monitor/dirty map, plus the three genesis sources, and connect
   hosted-agent reconciliation to delivery. Split a worker module only if the
   concrete loop cannot remain clear there; do not scaffold an agent framework.
5. Add the explicit Nomad content blocks. Commit the two reviewed registry facts
   through a normal transaction on the already-corrected root, then deploy,
   perform the three-ontology founder/anchor/join sequence without another root
   wipe, and prove full application/node restart.
6. Add metrics, Grafana panels, the focused crash/ownership CT suite, and the
   mixed-priority load harness.
7. Remove superseded helpers and stale comments in every touched path. Update
   the as-built notes in `agent-fipa-plan.md`, the stale lifecycle deployment
   status, and `inter-ontology.md`'s obsolete statement that creation
   authorization merely waits for transaction signing.

The only planned new long-lived component is the concrete `quod_outbox`
process. Before adding a special case elsewhere, reread the whole related path
and factor a shared invariant into its existing owner. Do not leave obsolete
function clauses, registrations, wire tags, tests, or comments behind, and do
not retain a compatibility branch.

No implementation commit, release bump, deployment, or ledger wipe happens
until the corresponding code delta is reviewed and Yan explicitly authorizes
it.

## 11. Non-vacuous acceptance tests

1. `goal(State)` returns immediately when State is already true. When false, it
   tries every matching action clause by shared desired state; prerequisite
   failure selects another clause, and both a single transition predicate and a
   finite proper ordered transition list can reach and then re-prove the state.
   The full transition shape is rejected before prerequisites and explicit
   `goal(...)` prerequisites retain the visited chain.
2. A candidate that asserts or retracts and then fails its transition or final
   desired-state check is restored across every touched ontology; the next
   matching action may succeed without seeing the abandoned writes. If every
   candidate fails, the outer proof fails with its bounded reason stack and no
   durable write. Cycle detection, explicit fact transitions, and both
   lifecycle transitions retain their specified
   behavior after the root declaration rewrite. A raw desired tuple plus a
   conflicting same-id/owner tuple fails
   its integrity-aware target rather than returning idempotent success. The
   lifecycle tests prove invalid create input still fails when already hosted,
   an unauthorized `already` request is denied, exact repeated join succeeds
   during `starting`, a wrong anchor fails, an unauthorized source path is never
   read, and an authorized source file is read and compiled exactly once. The
   captured `InitialDiff` reaches genesis byte-for-byte; no raw terms/file are
   re-read or recompiled by namespace start. The 192 KiB compiled-diff boundary
   succeeds and boundary+1 returns
   `ontology_creation_failed(initial_content_too_large)` before desired-state,
   filesystem, or ledger mutation. A
   ledger-copy cutover fixture verifies alpha-normalized root replacement and
   exact rollback with no mixed declaration set. Fresh creation without an
   asserted `can_invoke/4` policy fails before manager/storage mutation; a
   restrictive policy succeeds, resume need not repeat it in ignored terms,
   and direct-manager/V3 replay cannot bypass the invariant. A later ordinary
   or distributed change cannot remove the final policy clause; atomic policy
   replacement succeeds, while removal-only returns
   `policy_self_seal_forbidden` without publishing any participant's domain
   change. A concurrent
   stopping/start race preserves the bounded existing `already_hosted` failure
   mapping for both lifecycle actions and performs no automatic IO retry.
3. Two transactions in one block retain distinct reaction metadata and order,
   while their P heads are coalesced once through the linear ordered union. A
   distributed apply carries `{group, GroupId}` and cannot collide with an
   ordinary `{transaction, TxId}` containing the same binary id.
4. A live matching applied operation schedules one Handler; replay, catch-up,
   boot rebuild, and reconciliation schedule no historical best-effort or
   volatile effect. An identical assertion and absent retraction schedule none.
5. A P failure, malformed/unbound declaration, refused reaction bridge, staged
   D, zero owner, or multiple owners performs no E. Reaction workers retain
   only their exact bounded snapshot pin and release it on success, failure,
   timeout, or cancellation.
6. A dynamic look-alike `react_on/3` declaration cannot execute; changing any
   field of the founding declaration does not pass the full-term gate.
7. Indexed matching produces the same canonical order as a reference fold over
   `applied_ops`, and produces different reaction IDs for recurring explicit
   events, transaction-local IDs at different heights, and group commit
   identities.
8. A best-effort notice is delivered once on the receiver owner; forcing the
   bounded queue full drops and counts it with no retry, acknowledgement, wire,
   or later replay.
9. Acknowledged volatile delivery retries the same id, deduplicates at the
   receiver, stops at both deadline and attempt cap, leaves no inbox/outbox fact,
   and may be lost on sender death. Retracting its exact source fact before the
   block-final plan or a later retry suppresses further sends.
10. Hosted-agent ownership, source outbox, and receiver inbox admission each
    succeed at cap-1 and cap, reject cap+1, and cannot overshoot their global or
    per-owner caps under concurrent submissions because stale `read_check`s
    conflict at apply. An ownership move consumes no new hosted slot. Raw
    owner overflow/conflict starts no extra process, stops affected/all existing
    work as scoped above, keeps runtime state bounded, quarantines projection,
    and repairs without restart.
11. Live reaction and reconciliation derive byte-identical `DeliveryId` values
    for the same outbox before and after runtime/node restart.
12. Dropping the sole `schedule_outbox` edge without restarting anything still
    installs and delivers the pending outbox through the durable dirty bit.
13. Killing the sender after the outbox commit but before delivery recovers the
    pending item after restart.
14. Killing the receiver after inbox commit but before acknowledgement causes a
    resend but one receiver action.
15. Killing the sender after acknowledgement but before completion causes a
    resend but one receiver action and one eventual completion.
16. Moving source ownership while pending may transmit from both owners, but the
    receiver commits one logical action and the new owner completes it.
17. An outbox asserted then retracted/completed later in the same block produces
    no send because the worker revalidates the exact current tuple.
18. A duplicate id with different content reaches a durable fixed failure and
    is not retried automatically; an exact duplicate is acknowledged without
    another action; a changed owner/policy remains pending and retryable.
19. Raw malformed, conflicting, and oversized `outbox/5`/`inbox/5` facts are
    injected through direct writes: delivery quarantines them, sends and
    mutates nothing automatically, then a normal repair clears quarantine and
    resumes valid work without restarting runtime.
20. A slowed reconciliation at height `H` followed by live commits above `H`
    installs exactly one generation, then releases work in order; stale
    generation messages cannot overwrite or duplicate it.
21. Killing or stalling outbox before its `{G,H}` acknowledgement retains only
    the durable dirty bit, starts a fresh generation on replacement, ignores the
    old acknowledgement, and does not grow runtime state with later commits.
22. Dropping the sole `wake_agent` edge without restarting any process still
    drains the durable pending inbox to `done` through the level-triggered bit
    and runtime-owned pinned fold.
23. A definitive consume failure commits `failed(action_failed)` without a
    loop; an injected `outcome_unknown` rereads D and backs off while another
    item/agent continues; explicit retry/cancel transitions are idempotent.
24. A hosted agent exists only on its unique owner, reconstructs after process,
    runtime, and node restart, and holds no copied KB.
25. Oversized input is rejected before decode; malformed/unknown frames,
    unauthorised peers, and wrong namespaces perform no Prolog call.
26. A successful stream of every class receives the exact configured priority;
    successful and failed Brahms opens use only `{brahms, Ns}` and no raw legacy
    channel remains; saturating agent/feed traffic cannot starve consensus. An
    injected priority-assignment failure sends no header or payload, closes the
    stream, and leaves no transport owner or retry loop.
27. The three ontologies are founded once with the two system singletons and
    four-node AP exactly as configured. Root's existing ledger/genesis prefix is
    unchanged except for the reviewed normal declaration/registry transactions;
    a full application plus owner-node restart resumes the assigned content
    blocks without dynamic recreation.
28. Transition lists, queues, dirty sets, matching, workers, frames, committed
    pending state, snapshot folds, and retry rate remain bounded under hostile
    inputs and loops. A canonical 4 KiB payload plus bounded action metadata
    fits the 8 KiB proof-goal envelope and 24 KiB local plan; payload and whole
    goal fail independently at boundary+1.
29. The durable path (two source commits, target inbox admission, and any later
    target consumption transaction), best-effort path, and acknowledged-
    volatile path are load-tested and reported separately, including
    transaction rate and p50/p95/p99 commit latency, block progression, retry
    volume, dedup hits, actual messages per block, and incremental idle
    namespace cost.

Focused tests run while implementing. Before any commit, run compile, xref,
Dialyzer, full EUnit, full CT, and `git diff --check`, then have Claude review
the exact uncommitted tree.

## 12. Deliberate non-goals

- changes to the existing client login and signed base-user ingress;
- `subject/3`, capabilities, delegation, wielding, or agent-subject
  authorization;
- public FIPA ACL envelopes, AMS, DF, AID routing, federation, or subscriptions;
- dynamic runtime declarations;
- a generic effect dispatcher, callback/plugin framework, or copied KB;
- further changes to consensus ordering, ingress custody, transaction
  signatures, or the ledger format after the distributed-proof prerequisite;
- a compatibility reader, optional fake subject, alternate execution path, or
  migration layer.

After this milestone passes restart, ownership-churn, and mixed-traffic tests,
the next reviewed agent milestone replaces the transitional base-user signer
label and constructs immutable agent subjects together with the minimum real
wielding, receiving-side validation, and capability derivation required by the
stricter lifecycle specification.
