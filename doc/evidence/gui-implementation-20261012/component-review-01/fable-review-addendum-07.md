# Fable review addendum 7: remote actor feasibility inside one receiver-presentation preparation

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-12. Consultative only.
Earlier reports unchanged. Withdrawn from addendum 6 section 4: the second,
actor-side prepared effect. The parent is right on both counts: when receiver
and host coincide there is one node-ontology scope and at most one effect,
and an actor "activation" has no consequence because the shared handler is
already installed for all question work; a no-op effect would only disguise
a liveness observation. Sources: the live files cited in addendum 6 plus
`tree/src/quod_runtime.erl` and `tree/src/predicates/quod_runtime_predicates.erl`.
No command, build or test was run.

## 1. The seam

The only place actor feasibility can be consumed without becoming either a
discarded query or a shadow registry is the receiver node's staging
continuation, the Erlang predicate that prepares the presentation effect in
the receiver node's own ontology scope (addendum 3, section 5, contract 1).
Lifecycle shows the pattern: `prepare_and_stage_action/6` performs native
reads, maps refusals to reasoned failure, and bakes the result into the
immutable payload before `put_prepared_effect/5`
(`quod_ontology_predicates.erl:124-185`). For presentation, "native reads"
are two acceptances: the local view owner and the actor's host runtime.

Both are performed by the continuation itself, not by application Prolog,
so no liveness value is ever a Prolog term. The payload records only the
committed actor identity (instance, epoch, key, host) as accepted, next to
the view incarnation. Refusal is `fail_reason/2`. Post-apply obligation
remains the human surface only; nothing actor-side is activated or
registered.

## 2. Existing facility for the cross-node part

When the actor host is the receiver node, the continuation reads the local
`quod_runtime` for the responder namespace directly: `request_executor/2`
(hosted binding, epoch, key, not stopping), the installed `reaction_index`,
and `agent_work_capacity/2` (`quod_runtime.erl:2002-2008, 55, 2164-2177`).
No transport is involved and one effect results.

When the host is another node, the continuation runs inside a scope worker
that already has an authenticated path to the origin: the nested invocation
relay `proof_nested_open` (`quod_ask.erl:929-941`, `quod_prolog.erl:3571-3587`),
which the origin serves by opening or reusing a scope and streaming answers
back. With `at/2`, that scope can be the host node's own ontology served by
the host. So the existing owner request facility is **a nested scope
invocation issued by the preparing continuation**, carrying one goal into the
host node ontology, answered by a query-class bridge there that reads the
host's local runtime for the responder namespace and returns success or a
typed refusal. It is authenticated by the existing scope binding, authorized
by the host node ontology's `can_invoke/4` with the ordinary chain, bounded by
the caller's deadline, and leaves no record except the continuation's
payload. No broker, no opaque capability, no registry.

The nearest existing bridge is `reconcile_agent_hosts/1`, which asks the
runtime to converge hosting for `agent(Instance)` through
`request_resource/4` (`quod_agent_predicates.erl:48-53`,
`quod_runtime_predicates.erl:315-336`). It is not sufficient: it targets the
current scope's own namespace, not the responder's, and it reports
convergence of hosting rows, not the installed handler or capacity.

## 3. Exact missing capability, and why `at/2` alone does not provide it

`at/2` gives host-pinned scope service. It does not give:

1. **A host-side feasibility read.** One query-class bridge in the node
   ontology, say `actor_feasible(ResponderRef, Instance, Epoch, Key,
   HandlerKey, Allowance)`, and one runtime call behind it that checks the
   three facts above for a *named* namespace and returns `ok` or
   `{error, actor_stale | handler_not_installed | actor_busy}`. The runtime
   has the state but no read for it; `agents/1` exposes process references,
   not the handler or capacity check.
2. **Consumption inside preparation.** The staging continuation must issue
   that nested invocation itself and treat only `ok` as preparation success,
   so the answer never exists as an application-visible term. No existing
   Erlang bridge issues a nested `::`; the mechanism exists
   (`nested_open/7` runs in the same worker process) but no predicate uses it
   from Erlang today.
3. **Refusal classes.** `pinned_host_unavailable` from `at/2` and
   `actor_host_unavailable` from the bridge must stay infrastructure
   refusals; `actor_stale`, `handler_not_installed` and `actor_busy` are the
   authoritative absence or incapacity that the requirement maps to Prolog
   failure. Only the host's own runtime may produce the latter.

With those three, the receiver-presentation preparation is one legitimate
prepared external action whose feasibility covered both participants, with
no actor effect, no per-question handler state and no liveness fact.

## 4. Unverified

That a staging predicate may safely call the nested-open path from Erlang
while the erlog proof state is suspended (reentrancy into `quod_ask`
internals from a compiled predicate); the host node ontology grant shape;
all test outcomes.
