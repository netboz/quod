# Ontology lifecycle authorization

**Status:** the node-local authorization foundation is committed and deployed
in 0.7.57. The target-driven action correction, prepared-genesis seam, and
transaction checkpoint support landed in Quod 0.7.58.

## 1. Goal

This slice stops treating `create_ontology` and `join_ontology` as unrestricted
local effects, without inventing a temporary user-identity model.

It also enforces Quod's existing "no speculative side effects" invariant: a
lifecycle action proof must succeed and prove that it staged no durable write **before**
any lifecycle filesystem, supervisor, or network operation starts.

This plan separates two real authority domains:

- a node may decide what it hosts on that node;
- a user or agent may later request an operation under the authenticated Prolog
  subject `subject(User, AgentChain, Capabilities)`.

Node keys, users, agents, ontology names, and endpoints remain distinct. A node
key is never encoded as a fake `User` or fake agent in `subject/3`.

## 2. Pre-change facts that motivated the design

This section records the removed architecture. It is historical context, not a
description of the implementation below.

1. `POST /api/prove` is not an authenticated user boundary. It accepts only
   `{ns, goal}` and calls `quod_prolog:prove/3`.
2. A write produced by that proof is authored and signed by the serving
   validator node. Its `#transaction.author` authenticates the node, not the
   HTTP caller.
3. Normal proof and effect contexts carried `subject = undefined`.
4. `quod_prolog:effect/2` performed no transaction and therefore received no
   protection from transaction-author signatures.
5. The root lifecycle actions had no authorization prerequisite.
6. An action prerequisite alone would not have been a security boundary: a
   caller in an effect context could invoke `create_ontology_effect/2` or
   `join_ontology_effect/3` directly, including through `goal/1`'s direct
   `call/1` fallback.
7. The `#qctx{}` flag is readable by Prolog. An authenticated authority must
   not be placed raw in it. Quod already identifies the private proof overlay
   (`quod_erlog_db_local_prove`'s `#lp{}`) as the correct out-of-band seam.

Consequently, merely adding `subject(User, Chain, Caps)` as an API argument
would let a caller claim its own authority. That is explicitly forbidden.

## 3. Implemented node-local authority

The implemented slice is intentionally small. It authorizes a currently
admitted root validator to create or join an ontology **on itself**. This is host/operator
authority, not user ownership.

It is also not presented as hostile-network user authorization: the current
prove endpoint can still cause node-authored writes, and there is deliberately
no remote lifecycle-effect endpoint. The full subject milestone in section 4
is what closes user-command and validator-side write authorization.

### 3.1 Engine-owned principal

`quod_prolog:run_action/2` replaces the generic public effect entry. It accepts
one high-level action term,
invokes the exact target-state lifecycle preparer, and derives the principal
from its own `#s.self`:

```prolog
node(NodePublicKey)
```

The value is never accepted from the API or from Prolog. It is copied into a
private field of the per-proof `#lp{}` overlay. Normal proofs, verdicts,
projections, and unauthenticated runs carry no lifecycle principal. A malformed
or non-32-byte engine identity fails closed instead of becoming an authority.

There is no compatibility wrapper accepting an arbitrary effect goal. Before
removal that entry had no production caller outside lifecycle tests, and its
arbitrary goal was exactly what made the direct-adapter bypass possible.

For this slice the API accepts only `quod:root` plus the exact
`create_ontology/2` and `join_ontology/3` top-level shapes. Shape validation is
an early boundary check, not authorization; the committed Prolog action and
policy still decide whether the request may run.

The complete action term must also be ground at this entry boundary, using the
existing Erlog-aware `quod_predicates:is_ground/1` check. An unbound creation or
join argument returns that operation's existing `invalid_arguments` reason
before a worker starts. Phase 1 and the typed executor therefore receive the
same immutable, ground engine request; Prolog binding cannot change what is
eventually executed.

One narrow accessor lets governed predicates read that private value. There is
no second process-dictionary or `#qctx` mechanism.

### 3.2 Prolog owns the policy

Root defines the policy predicates:

```prolog
can_create_ontology(node(NodeKey), _Name, _Options) :-
    peer_admitted(NodeKey, _, _, NodeKey).

can_join_ontology(node(NodeKey), _Name, _GenesisHash, _Seeds) :-
    peer_admitted(NodeKey, _, _, NodeKey).
```

The first slice therefore permits a current root validator and rejects an
observer, removed validator, or run with no engine principal. It stores no fact
per created ontology, so creating millions of ontologies does not grow root for
that reason.

The root actions become:

```prolog
ontology_hosted(Name) :- ontology_join_state(Name, starting).
ontology_hosted(Name) :- ontology_join_state(Name, joining).
ontology_hosted(Name) :- ontology_join_state(Name, ready).

ontology_joined(Name, GenesisHash) :-
    ontology_hosted(Name),
    ontology_genesis_anchor(Name, GenesisHash).

action(create_ontology(Name, Options),
       [authorized_ontology_lifecycle(create_ontology(Name, Options)),
        ontology_join_state(Name, not_hosted)],
       ontology_hosted(Name)).

action(join_ontology(Name, GenesisHash, Seeds),
       [authorized_ontology_lifecycle(
            join_ontology(Name, GenesisHash, Seeds)),
        ontology_join_state(Name, not_hosted)],
       ontology_joined(Name, GenesisHash)).
```

`authorized_ontology_lifecycle/1` is a thin governed Erlang predicate. It reads
the engine-owned principal, then proves the corresponding ordinary Prolog
policy against the proof's captured **committed root snapshot**. A denial uses
the existing failure-reason mechanism:

- `ontology_creation_failed(not_authorized)`;
- `ontology_join_failed(not_authorized)`.

The external predicate observes the private principal; the permission rule
itself remains Prolog data and can later gain `subject/3` clauses without
changing the lifecycle APIs.

`authorized_ontology_lifecycle/1` is registered as an `effect`-class predicate even
though its handler only checks policy and performs no IO. `run_action/2` keeps
the existing effect worker context, so the predicate is available only in the
action pipeline. Calling it from an ordinary proof fails loudly with the
existing `context_violation`; the post-proof executor invokes the shared Erlang
authorization helper directly rather than going back through governed dispatch.

The authorization predicate receives the complete requested action rather
than only `{Operation, Name}`. Policy can therefore inspect creation inputs,
the expected genesis anchor, and seed endpoints without another API change.

The authorization helper does not prove policy through the caller's mutable
overlay. It creates an isolated sub-proof over that overlay's captured
committed `out_db`, passes the ground principal and action arguments to
`can_create_ontology/3` or `can_join_ontology/4`, and accepts only a success
with an empty diff. The existing overlay gains one factored read-only mode for
this use: its assert, retract, and abolish callbacks fail closed, including an
assert-then-retract attempt whose final diff would otherwise be empty. This is
not a second policy engine.

The sub-proof uses the existing verdict context. Cross-ontology `::` asks and
read-time followers are disabled, and staging-, projection-, and effect-class
predicates are unavailable. Existing query-class predicates remain callable
and may read live node-local state (for example `peer_ready/1`,
`directory_host/5`, `directory_control_peer/1`, and
`ontology_join_state/2`); those observations are not part of `out_db`. The
first-slice lifecycle rules deliberately use only committed
`peer_admitted/4`, so their authorization result is snapshot-only. A future
root policy that deliberately uses a query bridge also deliberately accepts
that local, time-varying input. A policy error, mutation attempt, missing
clause, or forbidden context transition denies authorization.

### 3.3 Dedicated prepared action runner

Lifecycle IO cannot run speculatively inside ordinary `goal/1`, so the public
target-driven action model uses one narrow typed runner for create and join.
It introduces no generic dispatcher or compatibility path.

The pipeline is:

1. `run_action(TargetNs, Action)` accepts only a ground root
   `create_ontology/2` or `join_ontology/3` term and performs structural
   validation without reading a source path;
2. the bounded worker verifies that the captured root declares that exact
   transition with a valid, non-`true` desired state;
3. the engine-owned principal is authorized before any caller-selected source
   is read, so an undeclared or unauthorized request cannot expose file parse
   results or timing;
4. `quod_ontology:prepare_action/1` reads and compiles creation input exactly
   once, or normalizes join input, into one opaque descriptor without manager
   or ledger mutation. Full input validation deliberately precedes the desired
   state check, so invalid input cannot become idempotent success;
5. `prepare_lifecycle_action/3` selects that exact declaration in the normal
   staged proof overlay. It returns `already` when its desired state is true,
   otherwise checks the same declaration's ordered prerequisites and returns
   `execute`. Any staged write remains visible in the operation log and the
   runner rejects the completed proof unless its diff is empty; the separate
   authorization sub-proof remains strict read-only;
6. the runner re-authorizes the private principal for either result. `already`
   returns without lifecycle IO; `execute` stages the closed lifecycle effect,
   seals one ordinary root transaction with an empty root diff, checkpoints
   its exact transaction reference, and waits for consensus;
7. ordered root apply releases the effect only after the runtime projection
   reaches that height. The journal then calls the frozen
   `quod_ontology:execute_prepared/1` payload and verifies the selected desired
   state. Recovery checks that desired state before repeating any local call;
8. a failed or missing declaration retains its bounded Prolog reasons, any
   attempted preparation write returns `lifecycle_staged_write`, a worker loss
   after its transaction checkpoint is `outcome_unknown`, and a journal-known
   rejection or postcondition failure is returned as a definite error.

The visible `authorized_ontology_lifecycle/1` prerequisite and the direct
checks all use the same factored authorization helper. The direct preflight
prevents source reads when a declaration accidentally omits its visible gate.
All policy proofs are strict read-only views and their committed dependencies
enter the transaction's OCC read set. There is no post-commit policy re-proof:
an applied effect is the local obligation recorded by that accepted
transaction. Execution runs outside the namespace engine.

The obsolete inline-IO creation/join registrations and handlers are removed.
`quod_ontology_predicates` only maps prepared-helper results to bounded public
reasons; it never rereads source input or dynamically dispatches a module and
function.

The low-level ontology APIs remain trusted same-VM APIs. Their documentation
states that they do not authenticate a remote caller and must not be exposed
directly. Local RPC/eval/code access is therefore part of the trusted node
operator boundary; Quod cannot distinguish multiple same-VM callers.

### 3.4 Snapshot and revocation semantics

The first-slice authorization policy is evaluated at the committed root height
captured when the action worker starts because it uses only
`peer_admitted/4`. If removal commits just afterward, that already-running
lifecycle operation may finish. This is the same frozen-view rule as an ordinary proof and
avoids a second, racy live-state mechanism. A later policy that opts into one
of the permitted local query bridges also opts into that bridge's live-local
observation semantics.

A later request sees the removal and is denied. Strict cancellation of an
already-running filesystem/start operation is not part of this slice.

Killing or timing out an action worker may not cancel a manager call already
accepted by another process. Quod therefore reports every action-worker loss
conservatively as outcome unknown rather than adding phase-tracking state; the
caller polls `ontology_join_state/2` using the ontology name before deciding
whether to retry. A manager-call exit after dispatch is propagated with the
same ambiguity contract.

## 4. The real user/agent subject milestone

Onia and Quod define the authorization subject as exactly:

```prolog
subject(User, AgentChain, Capabilities)
```

- `User` is the authenticated user identity;
- `AgentChain` is a proper, non-empty list, with the current invoker first and
  its ancestors after it;
- `Capabilities` are those of the current agent. They are derived by the
  receiving platform and replace the previous agent's capabilities; callers do
  not supply or forward them as trusted data.

This subject cannot safely land as a cosmetic extension of the node-local
slice. Before a `subject/3` clause is enabled, the following must exist:

1. Ed25519 user authentication and replay protection at command ingress;
2. user-key resolution and status/revocation policy;
3. a real wielded agent and receiving-side `accepts_wielding/2` validation;
4. immutable construction of every agent-chain hop;
5. capability derivation from the current agent's authoritative ontology;
6. a signature domain binding at least the target namespace, exact target host
   node for a node-local lifecycle effect, requested action/goal, complete
   subject, nonce, and command payload;
7. private overlay carriage of the verified subject, never the readable
   `#qctx` flag;
8. end-to-end propagation through `::` without allowing an intermediate node
   to shorten or replace the chain;
9. for writes, subject-bound transaction provenance and validator-side
   authorization. The existing node-author signature remains a separate
   executor/relay identity and is not relabelled as the user signature.

Every subject transformation at an agent hop must be authenticated by the
receiving platform: prepend the receiving agent, replace capabilities from its
authoritative facts, and bind the resulting subject to the invocation. An
intermediate node may neither delete an ancestor nor retain the previous
agent's capabilities.

Putting this provenance into `#transaction{}` changes the one canonical
transaction signature schema/version and the ledger format. Quod will make the
hard change once and re-found; it will not retain a subject-less reader or dual
signature path.

`{source_file, Path}` remains node/operator-only even after user subjects land:
a remote user must provide source bytes or an uploaded content handle, never a
path to the host's local filesystem. Because policy already receives the full
creation action, a future `subject/3` clause can enforce that distinction by
inspecting `Options`; it needs no lifecycle API change.

Once those invariants land, root may add ordinary clauses such as:

```prolog
can_create_ontology(subject(User, Chain, Caps), Name, Options) :-
    may_create_ontology(User, Chain, Caps, Name, Options).

can_join_ontology(subject(User, Chain, Caps), Name, GenesisHash, Seeds) :-
    may_request_hosting(User, Chain, Caps, Name, GenesisHash, Seeds).
```

The root action functors and low-level `quod_ontology` APIs remain stable. The
full milestone adds a new authenticated command/session ingress contract that
feeds a verified `subject/3` into the same action runner; generic
`run_action/2` cannot manufacture a user subject. The authority value stored in
the private overlay is then either the tagged node principal or the verified
`subject/3` term, and Prolog policy decides which form is acceptable.

This later milestone needs its own reviewed plan because it establishes the
user/agent trust boundary across ingress, transactions, and cross-ontology
calls. It must not be approximated by accepting a caller-provided tuple now.

## 5. Implemented files in the node-local slice

- `src/quod_erlog_db_local_prove.erl`
  - private principal field and narrow accessor;
  - one read-only overlay option that rejects every policy mutation attempt,
    including a net-empty assert/retract pair;
  - a committed-view accessor used to build an isolated policy sub-proof,
    never exposing the caller's staged overlay;
- `src/quod_prolog.erl`
  - the high-level `run_action/2` pipeline is the sole lifecycle entry;
  - it derives the node principal only for that action run;
  - it carries one opaque prepared descriptor through declaration, policy,
    mode selection, typed effect staging, transaction checkpoint, and outcome;
- `src/quod_predicates.erl`
  - registers the governed authorization predicate;
  - contains no inline-IO lifecycle predicate registrations;
- `priv/ontologies/common_predicates.pl`
  - implements the shared target-driven action relation and the exact,
    read-only lifecycle selection entry used only by `run_action/2`;
- `src/predicates/quod_ontology_predicates.erl`
  - contains one factored, isolated committed-snapshot policy check used by
    the visible prerequisite and direct lifecycle gates;
  - contains no obsolete inline-IO predicate handlers;
- `src/quod_ontology.erl`
  - retains the two trusted low-level APIs and factors structural validation,
    one-time preparation, and prepared execution without duplicating create and
    join paths;
- `src/quod_namespace_manager.erl`
  - owns start, genesis-anchor validation, desired-state admission, and
    explorer data-directory publication in that order;
  - validates normal/reconciled content before publishing and batches the
    reconciliation projection update;
- `src/quod_app.erl`
  - no longer publishes content paths before the manager validates a start;
- `priv/ontologies/quod_root.pl`
  - contains the policy rules and first-prerequisite authorization gates;
- related lifecycle, overlay, and join tests;
- `doc/ontology-creation-plan.md`, `doc/ontology-join-plan.md`,
  `doc/agent-fipa-plan.md`, and module comments are aligned with the dedicated
  action boundary and private node principal.

No unrelated identity framework is added in this slice.

## 6. Non-vacuous acceptance tests

1. An admitted root founder creates an ontology and begins a join successfully.
2. A root observer or removed member receives the exact bounded
   `not_authorized` failure and causes no desired-map, child, ledger-directory,
   or seed-state mutation.
3. The removed low-level effect functors have no compiled compatibility path;
   supplying one as the action or through ordinary `goal/1` performs no IO.
4. The action runner never reaches an ordinary `goal/1` transition, rejects a
   malformed declaration or literal-`true` desired state, and executes nothing
   when a declared prerequisite fails.
5. A committed root action with its visible authorization prerequisite removed
   still cannot bypass the executor's mandatory authorization check.
6. A fake self `peer_admitted/4` staged in any logical branch cannot authorize
   the action, even if the goal later retracts it so the final diff is empty.
7. Any staged write in lifecycle preparation causes
   `lifecycle_staged_write` and no lifecycle IO. Inside the authorization
   sub-proof, even an assert followed by its matching retract is rejected by
   the read-only overlay and performs no lifecycle IO.
8. A failing/backtracked logical branch causes no IO; execution depends only on
   success of the complete high-level action proof, never on overlay residue.
9. The principal is absent from `current_prolog_flag/2` enumeration and cannot
   be created, replaced, or cleared by ontology content.
10. An ordinary proof remains anonymous and cannot execute a lifecycle action.
11. Authorization runs before caller-selected source reads and before any
    manager mutation; the final desired-state query remains read-only.
12. Removal visible in a later committed root snapshot denies the next request.
13. A fully ground action is required before the worker starts; an unbound
    name, option, hash, or seed returns the exact operation-specific
    `invalid_arguments` reason and executes nothing.
14. A root snapshot with no matching valid target-state lifecycle declaration
    returns the exact operation-specific `action_not_declared` reason.
15. A worker killed while a deliberately slowed namespace-manager call is in
    progress reports outcome unknown; polling state distinguishes
    ready/joining from not hosted.
16. Reconciliation republishes an already-running desired namespace only after
    validating its genesis anchor.
17. Existing create/join validation and failure-reason tests remain green.

The validation sequence is focused EUnit followed by compile, xref, Dialyzer,
full EUnit, and CT before commit.

## 7. Deployment

`priv/ontologies/quod_root.pl` is genesis input, not a live configuration file.
The current deployed root ledger will not learn these rules from a new image.
Because Quod has no compatibility or migration requirement, validate the slice
on a freshly founded network rather than adding a dual policy path.

Do not commit, bump, deploy, or wipe the fleet until the implementation has been
reviewed and Yan explicitly asks for those actions.

## 8. Explicit non-goals of the node-local slice

- no fake or caller-supplied `subject/3`;
- no user registry, login/session, agent wielding, or capability framework;
- no explorer lifecycle endpoint;
- no per-ontology ownership/manifest facts in root;
- no payment, quota, atom-economics, or automatic directory publication;
- no alternate open path or backward-compatibility path;
- no consensus, ordering, join protocol, or ledger-format change.
