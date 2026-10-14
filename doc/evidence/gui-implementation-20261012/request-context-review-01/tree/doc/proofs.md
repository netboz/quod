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

Signed reads return the exact namespace, genesis anchor and pinned height of
every scope opened by the proof, including scopes visited by failed alternatives
or denied invocations. This retained evidence travels with the read outcome;
logical failure does not erase it. An error can carry only partial dependencies
and cannot establish a retained negative selection. The canonical result bounds
and validates the dependency list alongside the ordinary answer/failure payload.
The HTTP dependency heights are decimal strings, preserving exact uint64 values
in browser clients. These whole-ontology dependencies support view invalidation;
they do not replace per-predicate transaction read checks or certify native
installation.

A single writer uses its ordinary transaction. The [multiwrite contract](multiwrite-architecture.md)
covers several writers and explicit independent intent. An expired caller
may receive `outcome_unknown` with an anchored operation reference. Resolution
observes installed and certified evidence; it does not re-prove the goal or
resubmit an uncertain write.

`current_request_operation(Operation)` exposes the original authenticated
`operation(SourceNamespace, SourceAnchor, AgentBytes, OperationId)` reference.
It is the same reference in the origin and every foreign scope; it does not
allocate another request. `AgentBytes` is the canonical signed agent reference,
not a new GUI identifier. The accessor is proof-bound, so it can supply a
correlation key in an ordinary write without consulting live state. An unsigned
proof fails this query. Reaction matching and validator policy contexts cannot
invent an operation reference; a reaction's later signed proof has its own
request identity. The reference alone grants no permission and is not evidence
that its operation committed.

## Failure, reasoned failure and error

Every refusal a proof can produce belongs to exactly one of three classes.

1. **No solution.** The goal is false under the committed state and the
   principal's policy. This is ordinary Prolog failure and adds no explicit
   refusal reason.
   Examples: no `can_view_physics/2` fact, an input vector outside the policy
   speed, a sequence the policy does not accept. Content is allowed to be
   false; nothing is wrong.

2. **Reasoned failure.** The goal is refused by a condition the caller can act
   on, and the proof must say which one. Record it with `fail_with_reason/1`
   from Prolog or `quod_predicates:fail_reason/2` from Erlang. The proof still
   fails, backtracking still works, and the reasons reach the caller as
   `result: fail` with `reasons`. This class covers:
   - conflicts between the request and current state: a checkpoint already
     waiting, custody not yet replaceable, an expected epoch or revision that
     no longer matches, an exclusive binding held by another principal;
   - missing or ambiguous authored configuration: no rest policy, no
     allowances, more than one definition where a singleton is required;
   - runtime unavailability of a governed owner that the caller may retry
     later: no installed physics world for the selected run, a read-only
     owner query that refused or timed out, a transient already staged in
     this proof.

3. **Error.** The request or the engine violated a contract. Throw an
   `erlog_error`. Argument errors use the ISO forms the engine already
   provides: `instantiation_error/1` for an unbound argument the bridge needs,
   `type_error/3` for the wrong type, `domain_error/3` for a value outside the
   domain, including a policy predicate that returned a frame, lease or limit
   of the wrong shape. Context errors use `{context_violation, ...}`: a
   staging predicate reached from a read or execute request, a transient
   staged in a proof that is not read-only or whose write intent is not
   ordinary. The existing public allowlist filters detailed argument and
   context errors; their detail stays server-side. This does not expand that
   allowlist or rename its public error codes.

A bare `erlog_int:fail(St)` in an external predicate is correct only for
class 1 and for the documented no-managed-context case. Every other bare fail
is a defect: it hides a reason the caller needed, or hides an error as a
false goal.

### Reason terms

An explicit refusal reason is one ground term with the shape `{What, Detail}` or a bare atom,
portable under `quod_wire_term` (atoms, integers, binaries, lists, tuples;
no pids, references, funs or maps), and at most
`?ERLOG_MAX_FAILURE_REASON_BYTES` canonical bytes. `What` is a lower-case
atom naming the refused operation or resource in domain words. `Detail` is
the smallest term that lets the caller act: an identifier, an expected value,
or a sub-reason atom. Do not put internal state, process names, stack traces
or raw Erlang error terms in a reason. Record one explicit reason per refusal.
The engine also retains failed predicate calls as diagnostic boundaries;
these describe the path and do not replace the explicit refusal reason.

### Owner replies

An Erlang owner answering a governed bridge returns `ok` or
`{error, Reason}` with the same discipline: one atom or `{What, Detail}` per
actionable refusal condition. Timeouts and dead owners are reported as such
rather than folded into a domain refusal.
The bridge converts a definite `{error, Reason}` refusal into a reasoned
failure or an error by the rules above. A physics body or frame sample may
bind `unavailable` when the installed owner answers that the requested sample
is absent; a missing owner or failed call is a separate refusal.

A transient release timeout or owner exit does not establish a refusal: the
owner may already have admitted the action. Preserve it as an uncertain error,
never a certain failure, and do not resubmit the action. This differs from a
read-only query timeout, which cannot have applied an action.

### Clients

A client branches on the result class, not on "not ok". `ok` is accepted.
`fail` keeps the current view and shows the reasons, because the server
state is unchanged and certain. An error result, a transport failure or a
timeout is uncertain: suspend, do not replay, refresh.

Implementation entry points are `src/quod_prolog.erl`,
`src/quod_proof_session.erl`, `src/predicates/quod_ask.erl`,
`src/quod_ask_router.erl`, and `src/quod_client_goal_ingress.erl`. Detailed
historical semantics remain in [inter-ontology asks](outdated/inter-ontology.md)
and the [distributed proof record](outdated/distributed-proof-plan.md).
