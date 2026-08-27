# Ontology subscriptions and certified event following

**Status:** the durable subscription catalogue and shared continuous certified
follow have been implemented and deployed since release 0.7.80. Local and
subscribed reactions and explicit events are implemented and deployed;
reliable push and hardware acceptance remain planned in
`event-reaction-refinement-plan.md`. Explicit events change
the transaction and DTX-plan grammar but add no new ledger record kind.

This document is the authority for the subscription relation and certified
foreign projection. `inter-ontology.md` remains authoritative for `::`, ACL,
OCC, DTX, and outcome recovery. `event-reaction-refinement-plan.md` is the
authority for turning newly applied operations into reactions.

## 1. One explicit ontology relationship

A subscription is one ordinary durable fact in the subscriber's ledger:

```prolog
subscribes(TargetNamespace, TargetAnchor).
```

It means that hosts of the subscriber maintain a certified local projection of
that exact target ontology. It does not name a predicate. It does not host or
join the target. It grants no permission. It does not change public `::`, and a
read never creates a subscription as a side effect.

The fact contains no endpoint, node key, route, process, queue, retry timer,
cursor, or event pattern. Removing it cancels the durable relationship.
Creating and removing it are ordinary authorized Prolog writes in the
subscriber ontology.

Ten thousand subscriptions are ten thousand queryable facts, not ten thousand
hidden relationships. Runtime resources remain shared and demand-driven; no
hard-coded ontology or subscription population limit is introduced.

Application ontologies may define ordinary convenience rules:

```prolog
subscribe(Target, Anchor) :-
    allowed_subscription(Target, Anchor),
    assertz(subscribes(Target, Anchor)).

unsubscribe(Target, Anchor) :-
    retract(subscribes(Target, Anchor)).
```

These are not special Erlang dispatch paths. The subscriber's normal
`can_invoke/4` policy decides who may call them.

## 2. Separate concepts

- **Subscription:** durable semantic interest owned by the subscriber.
- **Hosting:** `create_ontology`, `join_ontology`, and a future leave operation
  decide which nodes run an ontology.
- **Routing:** `quod_directory` and private seeds are disposable knowledge of
  how to reach current hosts.
- **Proof scope:** `::` opens a bounded call inside one proof. It needs no
  subscription and creates none.
- **Client view session:** transient authenticated state for one UI client,
  named `client_view_session` in `client-world-direction.md`; it is not an
  ontology subscription.

The A -> B -> C origin-controller and DTX rules are unchanged. A durable B -> C
subscription does not make B a proof controller during A's proof.

## 3. Existing owners, reused

The implementation has no second verifier, cache, directory, event bus, ACL,
proof controller, or transaction executor:

- `quod_runtime` reads the subscriber's exact `subscribes/2` facts and owns the
  subscriber-local follow references and P-before-E ordering;
- `quod_foreign_log` owns one node-wide certificate-verified history and one
  materialized projection per actively followed target identity;
- `quod_foreign_projection` folds only certified cached entries through
  `quod_committed_projection`, the same canonical state transition used by the
  local ontology;
- `quod_feed`, catch-up pages, and directory routes provide existing
  dissemination, verification input, and reachability.

Multiple subscriber ontologies on one node share the same target history and
projection. Each keeps its own monitored consumer reference. The final
`unfollow` removes the projection worker and closes the history's ledger,
phase-index handle, and channel. The disposable certified cache and closed
derived phase session may remain on disk. The running owner may retain its
bounded verified current projection; after owner restart the first use replays
and verifies the disk cache before reuse.

## 4. Authorization remains the ordinary ACL

Writing or removing `subscribes/2` is governed by the subscriber ontology's
normal `can_invoke/4` path.

When target cooperation is required for a follow, page push, or wake-up, the
target evaluates that request through its existing `can_invoke/4` machinery.
The authenticated host supplies the exact subscriber identity and certified
evidence that the subscription still exists. The target does not gain a new
ACL language and does not copy any permission or durable row into its ledger.
Authorization is checked on establishment, after re-establishment, and after a
committee change. Revocation stops future cooperation; it cannot erase history
already disclosed.

The first reaction implementation sends no `react_on/3` patterns to the target
and keeps no target-side pattern registry. The target authorizes the ontology
follow, not an Erlang reimplementation of individual predicate policy.
Publication filtering may be added later only as a measured optimization
expressed by target-side Prolog policy around the same certified history.

The current certified-ledger transport is not selective confidentiality. A peer
which may fetch a complete certified page sees that page. Per-fact confidential
disclosure would require a separate cryptographic format and trust review.

## 5. D, P, and E ownership

| Artifact | Class | Owner and lifetime |
|---|---|---|
| `subscribes/2` | D | Subscriber ledger |
| founding-authorized source-qualified `react_on/3` | D | Subscriber ledger |
| target facts | D | Target ledger only |
| routes/private seeds | P | Existing local directory |
| certified target history/cache | P | Node-wide `quod_foreign_log` |
| materialized foreign facts and MVCC state | P | Shared active target projection |
| consumer refs, retry state, freshness, revision | P | Runtime/foreign-log only |
| `state_handler/4` convergence | P | Existing ordered runtime tier |
| verified height/digest wake-up | E | Freshness hint, never authority |
| grounded `react_on/3` Handler | E | Live-only reaction tier after P |
| durable consequence of a reaction | D | New ordinary signed goal/transaction |

Foreign facts are not inserted into the subscriber's own Prolog D and cannot
be sealed as if the subscriber owned them. A future explicit query bridge may
read the exact certified foreign projection together with its height; it never
silently replaces `::`.

## 6. Implemented continuous certified follow

`quod_foreign_log:follow/1`, `ack/2`, and `unfollow/1` extend the existing
foreign-history owner. One exact `{Namespace, GenesisAnchor}` identity is
verified and materialized once per node regardless of how many local consumers
follow it.

The follower:

1. resolves current hosts through the existing directory/private-seed path;
2. obtains the existing bounded certified catch-up pages;
3. verifies certificates, contiguous history, and committee changes through
   the existing verifier;
4. persists the certified history once;
5. folds it through `quod_committed_projection` in page-sized turns;
6. publishes a correlated building, ready, or unreachable notice to each
   consumer; and
7. requires acknowledgement so a slow consumer receives one coalesced newest
   state rather than an unbounded queue.

The projection reducer returns the actual ordered `applied_ops` and
`changed_heads`. It preserves OCC rejection, duplicate suppression, membership,
effects-as-D-only, noop, Prepare, Finalize, abort, and Complete semantics. A DTX
participant's hidden changes appear once, at `Finalize(commit)`. The
materializer itself executes neither effects nor reactions. It supplies newly
certified live `applied_ops` to the subscriber runtime; the runtime owns the
one shared reaction dispatcher.

The runtime-visible state is:

```text
unreachable(Reason, LastCertifiedHeight)
building(LastCertifiedHeight)
ready(CertifiedHeight, ProjectionId, Freshness)
```

`ProjectionId` names rebuildable local P at that exact certified height, not a
public proof handle. Freshness observations and hinted heights are diagnostic;
only certificate-verified history changes the projection.

There is no numeric ceiling on known identities, retained certified caches,
follow consumers, or materialized projections. A dormant identity consumes no
worker or decoded projection. Per-page byte and term bounds protect individual
inputs without limiting ontology population.

## 7. Implemented and deployed reaction delivery

Reaction delivery is the four-line pipeline in
`event-reaction-refinement-plan.md`:

```text
certified committed target entry
    -> canonical reducer returns ordered applied_ops
    -> wrap each event as from(TargetNamespace, TargetAnchor, Event)
    -> unify with subscriber react_on/3 and continue the bound Handler
```

The initial attachment, restart, cache rebuild, anti-entropy repair, and
resnapshot establish only a current P baseline and fire no historical
reactions. Once that baseline is live, newly certified contiguous entries may
produce best-effort reactions. Local and remote events use the same
`diff_to_events(AppliedOps)` helper and the same
`erlog_int:unify_prove_body` boundary. There is no remote matcher.

The subscriber's own `react_on/3` declarations select relevant events locally.
Candidate indexing by source and outer functor is an optimization only. The
actual match, variable binding, executor resolution, and Handler continuation
remain Prolog work. An ontology subscribes to an ontology; predicates do not
subscribe to predicates.

All physical hosts of subscriber A can reconstruct the same certified B
projection. Only the one host selected by the grounded Executor may perform an
observable reaction. An unresolvable or multiply resolved Executor is inert,
counted, and never falls back to every replica.

## 8. State convergence is not event replay

`state_handler/4` answers what rebuildable local state must exist now. It runs
after live D and after restart/replay, using the current snapshot. `react_on/3`
answers what to do because a new live occurrence happened. It never replays
historical E.

For example, a durable hosting fact may make one state handler start or stop a
local ontology process both on live change and after node restart. A separate
`react_on` rule is neither needed nor sufficient for that reconstruction.

The P tier finishes before E. Reaction Handlers run in the planned read-only
`reaction` context and cannot directly stage D. A durable response is a new
ordinary signed goal through `can_invoke/4`, proof, OCC/DTX, consensus, and
outcome recovery.

## 9. Direct, chained, and circular subscriptions

Subscriptions do not automatically forward events. If A subscribes to B and B
subscribes to C, a C change may make B react. A observes something only when B
then commits its own distinct fact change or explicit event.

Circular subscriptions are valid relationships and inert by themselves.
Application cycles terminate through ordinary committed cause/handled facts
and operation identity, not a hidden hop counter or Erlang firewall.

This supports component graphs such as Finger -> Hand -> Arm -> Body -> Avatar
-> World/AP while keeping each semantic boundary explicit. A leaf does not
broadcast raw detail automatically to every ancestor.

## 10. Failure and replay contract

| Edge | Required result |
|---|---|
| subscriber fact commits | Runtime creates/retains one exact follow consumer |
| subscription is retracted | Runtime removes that consumer; shared target remains for other consumers |
| subscriber node restarts | D rebuilds; reconciliation reattaches and rebuilds P; no old E |
| target advances while subscriber is down | Certified catch-up rebuilds current P; no historical E |
| target committee changes | Accept only certified transition and current routes; re-check the ordinary ACL if a cooperative push/wake-up is active |
| target route disappears | Keep D and last certified P, mark unreachable, retry asynchronously |
| wrong anchor/forged page/outsider/stale committee | Do not advance P or E |
| projection worker dies | Drop its generation and rebuild from certified cache |
| foreign-log owner dies | Consumers reattach; no old projection is trusted |
| slow consumer | Keep newest correlated state; require resnapshot; no unbounded queue |
| replay or cache wipe | Rebuild D/P only; zero historical reactions |

## 11. Transport and performance

Pulling remains bounded, asynchronous certified anti-entropy. An optional push
uses the existing certified page format or a height/digest wake-up; a raw push
is never authority. Reliable ordered streams carry pages and control. Existing
lossy datagrams remain only for client/world cues and frames.

There is no process or connection per subscription fact. One active target has
one shared verification/materialization owner, a coalesced refresh, and one
current generation. Long rebuilds yield between existing page-sized turns so
foreground DTX verification is not starved. Runtime network work stays outside
the ordered P handler.

Metrics use bounded labels and cover active follows/consumers, building and
unreachable targets, certified pages/entries/bytes, retries, coalescing,
rebuilds, source lag, reaction candidates/matches/failures, drops, and
resnapshots. Namespace and event values are not labels. Default retry and queue
budgets are operator-configurable; no semantic population ceiling is added.

## 12. Format impact and implementation order

The implemented subscription fact and continuous follow changed no durable or
wire format. Local assert/retract reactions also need no format change.

The `{event, Term}` operation added by `trigger_event/1` changes the
canonical transaction grammar and every exhaustive diff consumer. That one
hard break is coordinated with the agent-identity re-found; old decoders and
compatibility paths are deleted together.

1. **Implemented:** exact `subscribes/2` catalogue and founding-authorized
   source-qualified `react_on/3` catalogue in `quod_runtime`.
2. **Implemented:** shared continuous certified follow and canonical foreign
   materialization in `quod_foreign_log`/`quod_foreign_projection`.
3. **Implemented and deployed:** local applied-op reactions through the
   one runtime and Prolog matcher.
4. **Implemented and deployed:** subscribed applied-op reactions through
   the same dispatcher;
   first attach/rebuild remains reaction-free.
5. **Partly implemented:** pull-follow acknowledgement, coalescing, and
   reaction-free resnapshot use the same follow lifecycle. Reliable page push
   remains a later freshness optimization.
6. **Implemented and deployed:** `trigger_event/1` and its coordinated format
   break were activated by the clean re-found.
7. **Planned:** hardware fan-out, churn, recovery, and chained-load acceptance.

Each planned slice receives adversarial review and deletes any path it replaces
before the next slice.

## 13. Required acceptance tests

1. Adding/removing `subscribes/2` is an ordinary ledger transaction and changes
   no target ledger.
2. Two local subscriber ontologies share one target history/projection; removing
   one consumer leaves the other live.
3. No read or `::` call creates a subscription, follow, or runtime declaration.
4. Public and confirmed-private routes reach the same exact-anchor verifier.
5. OCC rejection, duplicate transaction, noop, effect-only transaction, and
   DTX Finalize materialize exactly as local apply at every height.
6. Wrong anchor, forged certificate, missing/reordered entry, outsider, and
   stale committee route advance neither P nor E.
7. Restart, replay, cache wipe, corruption, projection crash, and resnapshot
   rebuild identical current P and execute zero old reactions.
8. A local and subscribed occurrence produce identical matches and bindings
   apart from the explicit `from/3` wrapper.
9. Identical assertions and absent retractions produce no event; recurring
   explicit events each do.
10. A dynamically asserted non-founding `react_on/3` never executes.
11. An unresolvable/ambiguous Executor performs nothing and is counted.
12. When target cooperation is added for push/wake-up, it is authorized through
    the existing `can_invoke/4` path; denial retains no unauthorized delivery
    state.
13. Slow consumers coalesce and resnapshot without unbounded mailbox, timer,
    worker, or retry growth.
14. Direct, chained, circular, private-target, committee-change, and 10,000-fact
    workloads preserve consensus/DTX latency within measured release budgets.

## 14. Explicit non-goals

- subscription by reading;
- predicate-to-predicate subscriptions;
- routes or endpoints in durable facts;
- hosting or joining a target as a consequence of subscribing;
- changing `::`, scope ownership, DTX, or outcome recovery;
- target-side `react_on` pattern registration in the first implementation;
- another matcher, verifier, cache, directory, ACL, event bus, or executor;
- historical reaction replay;
- automatic event forwarding through subscription chains;
- pretending full-ledger access is selective confidentiality; or
- Plumtree before direct fan-out is measured as the actual bottleneck.
