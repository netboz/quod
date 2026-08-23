# Events, reactions, and restart reconstruction — plan

**Status:** Slice 0 document/comment alignment, Slice 1 local assert/retract
reactions, and Slice 2 subscribed assert/retract reactions are complete in the
working tree. Slices 3--5 remain planning only. The implemented slices change
runtime behavior but do not change the ledger or wire format and are not
deployed.

This plan refines the event sections of `agent-fipa-plan.md`,
`minimal-agent-delivery-plan.md`, and `ontology-subscription-plan.md`.
`inter-ontology.md` remains authoritative for `::`, ACL, OCC, DTX, and outcome
recovery.

The design is deliberately small. BBS/BBSvx already established the useful
core:

```text
committed transaction
    -> the existing reducer reports the operations it actually applied
    -> convert each applied operation to an event
    -> unify the event with react_on clauses
    -> call each matching handler with the resulting bindings
```

Quod keeps that model and adds only the correctness it already requires:
certified remote history, no historical reaction replay, and deterministic
restart reconstruction.

## 1. What Quod already has

Quod already publishes one `applied_live` message after applying a committed
transaction. `quod_committed_projection` already reports both the requested
`diff` and the ordered `applied_ops` returned by
`quod_diff:apply_ops_report/2`. `quod_runtime` already receives the live
publication and runs its local state-convergence tier. The current publication
still exposes the requested diff; Slice 1 carries the already-computed
`applied_ops` across that boundary as well, rather than deriving them again.

Quod also:

- stores and validates founding `react_on/3` declarations;
- follows subscribed ontologies through certified `quod_foreign_log` history;
- materializes their published facts locally; and
- distinguishes live application from replay.

Slices 1 and 2 provide the short connection between those pieces: turn each
newly applied operation into an event, unify it with `react_on/3`, and call the
bound handler. Remote certified history obtains the same `applied_ops` from the
same committed-state reducer and enters the same function after its
reaction-free baseline.

## 2. One event list: the applied operations

There is no second event envelope or event store. The event source is the
transaction's ordered `applied_ops`: the subset of its signed diff which the
existing canonical reducer says actually changed the published projection.
This distinction is load-bearing. Asserting a fact already present, or
retracting an absent fact, is a committed no-op and must not manufacture a
change notification.

One shared, process-free `diff_to_events(AppliedOps)` function performs the
only conversion:

| applied operation | reaction event |
|---|---|
| assert plain fact `Fact` | `assert(Fact)` |
| retract plain fact `Fact` | `retract(Fact)` |
| `{event, Term}` | `Term` |

`asserta` and `assertz` both become `assert`. Rule changes are not silently
presented as plain-fact events. The reducer preserves transaction order while
omitting no-ops. Reaction code consumes that result; it does not inspect the
final snapshot or implement another reducer.

Rejected transactions, aborted DTX groups, genesis replay, and consensus
control records produce no reaction event. A committed DTX participant exposes
its diff exactly once when `Finalize(commit)` publishes that participant's
facts.

### Explicit events

The existing BBSvx idea is retained:

```prolog
trigger_event(Term)
```

During a proof, this staging-class external predicate, owned by the shared
`quod_transaction_predicates` module, dereferences `Term`, requires it to be
ground and valid on the normal bounded wire, and appends `{event, Term}` to the
same staged diff. It does not call a handler immediately. The canonical
`quod_diff` reducer reports every valid explicit event as applied while making
no fact mutation, so recurring identical explicit events are not deduplicated.

If the transaction commits, the event is signed, audited, delivered to
subscribers with that diff, and dispatched in its exact position. If the
transaction fails or is rejected, it disappears with the rest of the staged
diff. A transaction containing only `{event, Term}` is material and therefore
still enters the ledger.

Adding the `{event, Term}` diff operation changes the canonical transaction,
validation, DTX, and history formats. It belongs to a separately reviewed
format-break slice followed by a coordinated clean re-found. Existing
assert/retract reactions can be completed before it.

## 3. One `react_on` dispatcher

The declaration stays:

```prolog
react_on(Executor, Pattern, Handler).
```

`Executor` owns the resulting work. It is not the event source and it is not
restricted to one class. Variables shared by `Pattern`, `Executor`, and
`Handler` receive the values produced by the event match.

Local patterns match an event directly:

```prolog
react_on(agent(Agent),
         assert(task_ready(Agent, Task)),
         notify_agent(Agent, Task)).

react_on(node(Node),
         alarm(Service, Reason),
         notify_operator(Node, Service, Reason)).
```

A remote source is represented only by the existing exact wrapper:

```prolog
react_on(agent(Agent),
         from(SourceNamespace, SourceAnchor,
              assert(task_ready(Agent, Task))),
         notify_agent(Agent, Task)).
```

`quod_runtime` may use the source and outer event functor to avoid considering
unrelated clauses. The actual match must use `erlog_int:unify_prove_body`.
That one operation installs the variable bindings and continues the selected
handler. Erlang must not implement another matcher, wildcard syntax, binding
map, or typed callback catalogue.

The handler is ordinary trusted Prolog code. Erlang external predicates remain
the governed bridge to local processes and the outside world. Slice 1 adds one
`reaction` execution context and one `reaction` external-predicate class to the
existing `quod_predicates` dispatcher; there is no second registry. The exact
matrix is:

| external-predicate class | reaction context |
|---|---|
| `query` | allowed |
| `reaction` | allowed |
| `staging` | refused |
| `projection` | refused |

Reaction-class bridges are refused in proof, verdict, policy-verdict, and
projection contexts, so they cannot perform outward work before commit. The
reaction runs on a read-only frame, and any Prolog body which nevertheless
stages D fails loudly. If it needs a new durable change, the resolved acting
agent submits an ordinary signed goal through the existing `can_invoke/4`,
proof, OCC/DTX, consensus, and outcome path.

Until generic agent signing exists, there is no node-only substitute for that
durable-goal path.

## 4. Exact local order

For one newly committed block:

1. `quod_prolog` applies the facts and publishes the block-final snapshot.
2. `quod_runtime` brings rebuildable local state up to date through the
   existing `state_handler/4` goals.
3. For each applied transaction in commit order, `diff_to_events` receives its
   canonical ordered `applied_ops` and returns the corresponding events.
4. The single reaction dispatcher unifies each event with active
   `react_on/3` clauses and calls the bound handlers.
5. Executor resolution allows only the unique current owner host to perform
   the observable work.

Local derived state is therefore current before a reaction can inspect it.
`quod_prolog` does not wait for reaction handlers and consensus receives no new
callback.

## 5. Why restart reconstruction is separate

`react_on` responds to a new occurrence. It cannot by itself restore a process
after restart because the fact requesting that process may have been committed
days earlier.

The existing declaration remains narrowly responsible for this job:

```prolog
state_handler(Id, WatchedPatterns, Needs, ConvergeGoal).
```

The same `ConvergeGoal` receives changed keys after a live transaction and
`all` after replay or restart. It reads current committed truth and makes the
local process/index/timer state agree with it. It does not match application
events or send application notifications.

For ontology hosting, for example, a node ontology may contain:

```prolog
hosts_ontology(NodeRef, Namespace, Anchor).
```

One state handler watches this fact. Its one convergence goal ensures the
ontology is running when the fact exists and stopped when it does not. The same
goal handles the live assertion, live retraction, and node restart. This can
replace a separate durable namespace-manager restart-intent store; it does not
require a duplicate `react_on` rule.

Thus there are two ordered phases, but no duplicated job:

- state convergence answers **what must be running now?**;
- `react_on` answers **what should happen because this new event occurred?**

## 6. Subscribed ontologies use the same dispatcher

An ontology subscribes to an ontology, not to a predicate:

```prolog
subscribes(TargetNamespace, TargetAnchor).
```

Each physical node hosting subscriber A follows target B through the existing
shared `quod_foreign_log` verifier and materializer. On first attachment,
restart, cache rebuild, or gap repair, it reconstructs B's current certified
projection but fires no historical reactions.

After that baseline is ready, every newly certified contiguous B transaction
is folded by the existing canonical materializer. Its ordered `applied_ops`
enter the same `diff_to_events` function. The same reaction dispatcher receives
each event as
`from(BNamespace, BAnchor, Event)`.

There is no special remote matcher and no trusted raw push. A B host may wake
the follower or send an existing certified page, but A accepts the diff only
after the normal history verification. All A hosts can therefore reconstruct
the same certified view. Executor resolution ensures that only the current
logical owner performs each observable reaction.

The first implementation sends/follows the published certified diff and lets
A's `react_on` clauses select relevant events. It adds no durable
predicate-level subscription and no target-side pattern registry. If measured
traffic later justifies filtering, a B-side Prolog publication/filter rule may
reduce what B sends, but it must remain an optimization around the same
certified history and subscriber-side match.

## 7. Chaining and cycles

Subscriptions do not forward events automatically. If C changes, B may react
to C. A sees a new B event only if B then commits its own fact or explicit
event and A subscribes to B.

This makes Finger -> Hand -> Arm -> Body -> Avatar explicit at every semantic
step. Circular subscriptions are allowed and are inert by themselves. If
application reactions create a transaction cycle, their event/cause id and
ordinary handled facts must terminate that application cycle.

## 8. Replay and reliability

Boot, recovery replay, foreign cache reconstruction, and resnapshot update D
and P but execute no old `react_on` handlers. Only transactions observed after
the live baseline produce best-effort reactions.

A crash after commit but before a best-effort handler runs may lose that
reaction. Work which must survive uses existing durable custody:

- a committed effect descriptor and the effect journal;
- outbox/inbox facts; or
- a signed goal with a stable operation reference.

`react_on` may wake such work quickly; it is never its only durable record.

## 9. Authorization remains singular

No event ACL is added:

- A's ordinary `can_invoke/4` controls writing/removing its `subscribes/2`;
- B's ordinary `can_invoke/4` controls whether A may establish/renew delivery;
- declaration authority controls which stored `react_on/3` and
  `state_handler/4` clauses execute;
- committed facts resolve the unique Executor owner; and
- every durable consequence goes through the ordinary signed-goal ACL.

The existing founding-only declaration gate remains until the reviewed
`can_declare_runtime` policy lands. There is no exception for node, agent,
subscription, or lifecycle handlers.

## 10. Exact keep, refactor, and delete map

### Keep

- `applied_live` and the `live | replay` distinction;
- `quod_diff:apply_ops_report/2` and the committed projection's `applied_ops`
  as the sole change/event source;
- `quod_runtime` as the one P-then-reaction owner;
- the one-goal `state_handler/4` live/restart convergence contract;
- `react_on(Executor, Pattern, Handler)`;
- `erlog_int:unify_prove_body` as the only matcher and binding boundary;
- `quod_foreign_log` as the only certified foreign-history owner;
- `quod_feed`, certified catch-up pages, `subscribes/2`, directory routing,
  `can_invoke/4`, effect journal, signed goals, OCC, DTX, consensus, and
  outcome recovery.

### Refactor

- add one shared `diff_to_events` helper used by local and foreign dispatch;
- carry the existing projection result's `applied_ops` through `applied_live`
  instead of reapplying or inspecting the raw diff in the runtime;
- extend the existing runtime worker from state convergence to ordered
  state-convergence-then-reaction dispatch;
- execute the bound Handler as a Prolog continuation instead of translating it
  to a closed Erlang effect type;
- expose newly certified foreign diffs from the existing follower while
  keeping initial/rebuild/resnapshot notices reaction-free;
- later make node and agent hosting facts converge through state handlers and
  remove duplicate restart-intent authority.

### Delete or never add

- a second event envelope or event store;
- a separate transaction `events` field;
- raw event broadcast to every agent process;
- a second event bus, ACL, matcher, unifier, executor, verifier, or cache;
- a typed Erlang reaction callback catalogue;
- historical reaction replay;
- a special node lifecycle reaction path;
- routes, endpoints, or queues in durable subscription facts;
- forwarding shims for deleted lifecycle/reaction paths.

## 11. Performance rules

- Candidate indexing uses only source and outer functor; Prolog performs the
  match.
- State convergence remains once per block; reactions preserve transaction and
  operation order.
- Network and cache work stays asynchronous and message-driven. No sleep,
  `wait_until`, or synchronous remote call runs in `quod_runtime`.
- A configurable bounded live queue may drop best-effort reactions and
  resnapshot P under overload. It cannot lose effect-journal or outbox custody.
- There is no hard-coded limit on the number of ontologies or subscriptions.
  Inactive identities keep only disposable certified cache; decoded state and
  workers exist only while used.
- Per-message validation and operator-configured resource budgets protect a
  node without changing ontology semantics.

Metrics and dashboard panels land with their owning implementation: event
batches, candidate/match/handler counts, handler failures, best-effort drops,
resnapshots, state-convergence latency, reaction latency, and certified-source
lag. The hosted namespace uses Quod's existing per-namespace label; arbitrary
target identities, executor values, event terms, and failure payloads never
become metric labels.

## 12. Reviewable implementation slices

### Slice 0 — align documents

**Status: complete in the working tree.**

- Make the simple applied-ops -> unify -> handler pipeline identical in the agent,
  subscription, content-layer, and node-hosting documents.
- Remove the planned typed reaction-effect catalogue and target-side pattern
  registry.
- Correct every statement implying that Quod needs another event envelope or
  another state reducer.
- Change no runtime behavior; source comments may be corrected with the docs.

### Slice 1 — local assert/retract reactions

**Status: complete in the working tree; compile, xref, Dialyzer, focused EUnit,
and full EUnit are green. Not deployed.**

- Add the shared `diff_to_events` helper for existing fact operations and feed
  it the `applied_ops` already returned by `quod_committed_projection`.
- Complete `react_on/3` indexing, `unify_prove_body`, executor resolution,
  reaction context, and asynchronous handler execution in `quod_runtime`.
- Add the one `reaction` predicate class and its exact context matrix to the
  existing predicate dispatcher.
- Until generic agent hosting exists, resolve only executors which the local
  committed ontology proves belong to this node, together with the node's own
  identity. Unresolvable or ambiguous executors are inert and counted; no
  node-only fallback is allowed.
- Preserve state-before-reaction and exact order.
- Delete replaced dormant typed-dispatch code/documentation.
- No format change.

### Slice 2 — subscribed reactions

**Status: complete in the working tree; production compile, xref, Dialyzer,
focused EUnit, and full EUnit are green. Not deployed.**

- Expose the canonical materializer's newly certified contiguous `applied_ops`
  from the existing foreign follower.
- Treat first attachment/rebuild/resnapshot as a reaction-free baseline.
- Dispatch later remote events through the exact Slice-1 helper with the
  `from/3` source wrapper.
- Add no target-side registration or authorization path: pull following uses
  only already reachable certified history. Any later cooperative push or
  wake-up must enter through the target's existing ACL and may add no second
  registration authority.

`ontology-subscription-plan.md` retains the implemented subscription catalogue
and certified-follow contract and points its remaining reaction work here.

### Slice 3 — `trigger_event/1`

- Add `{event, Term}` to the canonical diff operation grammar.
- Extend `quod_diff:valid_op/1`, `apply_op`, its indexes/helpers, and every
  exhaustive consumer; explicit events are always reported in `applied_ops`
  while mutating no facts.
- Thread it through proof differ, plan sealing, transaction signing,
  validation, relay, apply, DTX, history, Explorer rendering, and subscribed
  delivery.
- Apply makes no fact mutation but reports the occurrence as applied;
  `diff_to_events` returns `Term`.
- Require a ground bounded term and preserve order.
- Make event-only transactions material.
- Hard-break the format once, delete old decoders, and coordinate the clean
  re-found with the agent-identity format break in
  `node-instance-identity-plan.md`; do not schedule two re-founds.

### Slice 4 — hosting projections

- Represent desired ontology/agent hosting as ordinary facts in the owning
  node ontology.
- Use one state convergence goal for live changes and restart restoration.
- Refactor existing lifecycle effects and namespace desired-state persistence
  onto that owner; delete obsolete stores, callbacks, comments, and tests.
- Do not change root creation, consensus, directory routing, or signed goals.
- Treat `node-instance-identity-plan.md` as the gate for the exact identity,
  ownership, and hosting fact shapes.

### Slice 5 — load and recovery acceptance

- Test local, remote, chained, circular, DTX, restart, cache wipe, slow
  subscriber, executor movement, and uncertainty cases.
- Run mixed consensus + subscription + signed-agent load with three- and
  four-ontology chains while monitoring errors, warnings, memory, drops, and
  latency.
- Set operator defaults from measurements and introduce no semantic population
  limit.

Each slice receives adversarial review before the next begins.

## 13. Required tests

1. `assert(task_ready(bob, t1))` binds variables in Executor and Handler through
   `unify_prove_body` and calls the handler once.
2. Assert, retract, and explicit events preserve their exact applied order.
   An identical assertion and an absent retraction produce no reaction;
   recurring identical explicit events each produce one reaction.
3. Multiple transactions in one block converge state once but dispatch every
   event in commit order.
4. Replay, restart, cache rebuild, and resnapshot restore state and call zero
   historical handlers.
5. A hosting fact starts locally, restart restores it, and retraction stops it
   through the same convergence goal.
6. Every A host verifies the same B diff; only the unique executor host
   performs observable work.
7. Wrong anchor, forged page, outsider, missing entry, and stale committee data
   dispatch nothing.
8. A subscribed diff and the same local diff produce identical Prolog matches
   and bindings apart from the explicit `from/3` source wrapper.
9. DTX publishes each participant diff once at committed Finalize.
10. `trigger_event/1` rejects variables, oversized terms, bad wire terms,
    rejected transactions, and old format versions.
11. An event-only transaction is signed, committed, visible in Explorer, and
    remotely verifiable.
12. A reaction cannot stage D or bypass the signed-goal ACL.
13. A dynamically asserted non-founding `react_on/3` remains inert at actual
    execution, not only during catalogue planning.
14. An unresolvable or ambiguous Executor performs no observable work and is
    counted.
15. Circular subscriptions alone emit nothing; application event cycles stop
    through committed cause/handled facts.
16. Queue overload affects only best-effort reactions, resnapshots state, and
    leaves durable effect/outbox work recoverable.
17. Compile, xref, Dialyzer, full EUnit, focused CT, UI builds, diff check, and
    the hardware load matrix pass at their owning slices.
