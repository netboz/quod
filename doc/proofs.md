# Prolog proofs and foreign scopes

`quod_prolog` owns one committed knowledge base per ontology. Bounded proof
workers borrow MVCC snapshot handles and stage facts, events, effects and
read dependencies privately. The state owner does not block on a proof or
network I/O. Prolog rules, including `can_invoke/4`, `action/3` and `goal/1`,
remain the domain authority; Erlang predicates supply governed observations
and runtime operations.

`:` builds an owner-qualified name as data, such as `quod:animal`;
`::` explicitly asks another ontology to prove a goal. At config and wire
boundaries an ontology name is a flat binary; Prolog uses the structured
name. Unknown ontology prefixes fail explicitly, and received names never
create Erlang atoms. The ontology's policy decides who may invoke a goal;
demo ontologies deliberately grant broad access with a `can_invoke/4` clause.

## Scope and selection

`Namespace::Goal` enters a scope for the target ontology. Co-hosted and
remote targets use the same proof semantics. The authenticated principal and
call path cross the scope boundary; the target applies its own ACL. A scope
is bound to an exact target identity and a frozen committed base. Re-entrant
calls share that scope's staged view. Backtracking and cut select Prolog
alternatives, not ledger commits. Ordinary failed branches can retain staged
events; `transaction/1` provides the explicit rollback boundary. Action
candidates use the same internal savepoint machinery.

The selected successful proof seals one plan per participating scope. Each
plan carries its own diff, exact read checks, invocation transcript and
request/principal binding. A scope cannot seal a material write based on a
non-replayable live observation. Nodes exchange sealed plans, references and
verified deltas, never a copy of another ontology's Prolog database.

## Admission and results

`quod_client_goal_ingress` accepts the exact signed request. The target
checks the request's network, ontology, active agent key and normal Prolog
authorization. A foreign read uses certified evidence and its own target
scope. At commit, the owning validators check the staged read dependencies
against the committed parent. An absent or unavailable route is not an ACL
grant, a proved absence or a write outcome.

A single writer uses its ordinary transaction. The [multiwrite contract](multiwrite-architecture.md)
covers several writers and explicit independent intent. An expired caller
may receive `outcome_unknown` with an anchored operation reference. Resolution
observes installed and certified evidence; it does not re-prove the goal or
resubmit an uncertain write.

Implementation entry points are `src/quod_prolog.erl`,
`src/quod_proof_session.erl`, `src/predicates/quod_ask.erl`,
`src/quod_ask_router.erl`, and `src/quod_client_goal_ingress.erl`. Detailed
historical semantics remain in [inter-ontology asks](outdated/inter-ontology.md)
and the [distributed proof record](outdated/distributed-proof-plan.md).
