# Fable review addendum 4: live actor acceptance inside the prepared presentation action

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-12. Consultative only.
Earlier reports unchanged. Addendum 3's committed-facts substitute for actor
acceptance is withdrawn: the ticket, design and review request require
actual installed, capable, authorized actor acceptance at opening. This
addendum traces that requirement through the existing owners. Inputs: the
frozen `tree/`, `delta-02/src/quod_ontology.erl`, and, read live for the
routing question only, `priv/ontologies/node_execution.pl`,
`priv/ontologies/quod_node.pl`, and the exports of `src/quod_directory.erl`
and `src/quod_ask_router.erl`. No command, build or test was run.

## 1. Verified owner facts, actor side

A1. **One owner for live actor state.** The responder namespace's
`quod_runtime` on the hosting node holds the hosted binding (epoch, key,
reference), the process, pending requests, stopping flag and work
(`tree/src/quod_runtime.erl:2002-2008, 2164-2177`), the installed reaction
catalogue `reaction_index` (`:55, 1249, 1386`), and the capacity rule
`agent_work_capacity/2` against Erlang constants. The `quod_agent` process
itself answers no calls (`tree/src/quod_agent.erl:26`); only the runtime sends
it requests.

A2. **Existing entry points into that runtime from a proof.** Query-class
bridges `reconcile_agent_hosts/1` and `reconcile_agent_observers/1`
(`tree/src/predicates/quod_agent_predicates.erl:48-53`) go through
`request_resource/4` to `quod_runtime:reconcile_resource/5`
(`quod_runtime_predicates.erl:315-336`, `quod_runtime.erl:127-129`);
`agents/1`, `project_agents/3` and `effect_frontier/1` are plain calls.
`agent_request/6` is accepted only from the runtime's own event runner
(`quod_runtime.erl:376-391`). All of these are node-local gen_server calls
through `quod_reg:via({quod_runtime, Ns})`.

A3. **The selected host is committed state.** `agent_hosted/4` and
`agent_host/4` in the responder ontology name the exact node reference, epoch
and key (`tree/priv/ontologies/agent_instance.pl:6-9, 54-56`); the host's
runtime converges to those rows. A node's reference is
`agent_instance_ref(NodeNs, NodeAnchor, me)` in that node's own ontology
(`quod_node.pl:44-57`, `node_execution.pl:8-16`).

A4. **No existing "run this live step on node X" primitive.** Cross-node
reach from a proof is the anchored `::` scope, routed to a validator or host
of the namespace by the directory and router on availability
(`quod_directory:await_validator_target/3`, `directory_hosts/1`; router
identity routes over the committee). No export takes a caller-selected host
(verified at export level only). Every node-specific live step in the code is
either local by construction, as physics is (world and authority agent on one
node, `quod_runtime.erl:2047-2054`), or committed intent followed by the
owner's convergence, as hosting is (`hosts_ontology/4` asserted by
`request_ontology_hosting/5`, `node_execution.pl:36-55`, converged by
`reconcile_node_ontologies/1`). `enroll_node/1` even records whichever
executor served the scope as the host rather than choosing one
(`quod_node.pl:44-57`).

A5. **The responder scope cannot host the live check.** It carries the
question row, a material diff; a query-class bridge there is vetoed
(`tree/src/quod_dtx.erl:282-297`), correctly. The check must run in a scope
with no diff on the host node, exactly as the human check runs in the
receiver node's ontology scope.

## 2. Concrete callable path (proposed) and the one missing capability

Inside the single declared presentation action of the original signed execute:

1. **Committed selection.** The application proof fixes `Human`, `Form`,
   `Responder = agent_instance_ref(RNs, RA, Instance)` and reads
   `RNs::(current_ontology_identity(RNs, RA), agent_hosted(Instance, HostRef,
   Epoch, Key))`, an ordinary committed read in the responder scope. `HostRef`
   is `agent_instance_ref(HostNs, HostAnchor, me)`. No live value yet.
2. **Actor acceptance.** `HostNs::(current_ontology_identity(HostNs, HostAnchor),
   gui_actor_accepts(Responder, Epoch, Key, HandlerKey, Allowance))`, a
   query-class bridge in the host node's own ontology scope, calling the
   local `quod_runtime` for `RNs`. It succeeds only if
   `request_executor({agent, Instance, Epoch, Key}, S)` returns the live
   binding and it is not stopping, `reaction_index` holds the installed shared
   GUI clause under `HandlerKey`, and the Prolog-supplied `Allowance` is
   satisfied against the runtime's pending count and bytes. It returns
   nothing else; refusals are `fail_reason/2`: `actor_not_hosted_here`,
   `actor_stale`, `handler_not_installed`, `actor_busy`, and an infrastructure
   `actor_host_unavailable` when the runtime does not answer. The scope has no
   diff and no reads, so its recorded bridge seals `not_material`
   (`quod_dtx.erl:190-193`); the group never sees it.
3. **Human acceptance and effect staging** in the receiver node's ontology
   scope as in addendum 3 section 5, with the accepted actor identity from
   step 1 (committed epoch, key, host) in the immutable private payload. No
   liveness or capacity value exists to leak; the bridge returned none.
4. Either refusal is Prolog failure inside the proof, so alternatives,
   `transaction/1` and candidate rollback behave normally and nothing is
   staged beyond the savepoint.

This uses no new registry or queue: step 2 reads the runtime's existing
state and allocates nothing. Acceptance is instantaneous evidence; the later
submission re-checks hosting through the ordinary reaction path.

**The missing owner capability is host-pinned scope service.** Step 2 is only
meaningful if the `HostNs` scope is served by the host node itself. By A4 the
router may serve it from any validator of that namespace, where the bridge
would answer `actor_not_hosted_here`, which is a wrong-node condition, not
absence. The same holds for step 3's receiver node scope. What is needed,
concretely: for a scope whose target is a node's own ontology, the router
must select that node's route (the directory already carries host contacts
through `node_ontology_hosting_projection/2`, `node_execution.pl:64-68`), or
the bridge's `wrong_executor` refusal must drive one bounded re-route to the
owning node within the caller's deadline. This is a routing extension in the
existing router and directory, not a new broker. Until it exists, step 2
works only when the proof happens to be served on the host node, and the
requirement cannot be met in general.

Two smaller contracts follow from the trace:

- A narrow entry grant in the node ontology's shared behaviour for
  `gui_actor_accepts/5`, since `node_execution.pl:15-21` admits only the node
  itself and the hosting entries.
- The capacity `Allowance` is authored policy in the responder ontology and
  passed as an argument; the runtime's `?MAX_AGENT_PENDING` constants remain
  what they are today and are not relabelled.

## 3. Boundaries added by actor acceptance

| Boundary | State | Original caller |
| --- | --- | --- |
| Actor not hosted at committed epoch/key, stopping, handler missing, over allowance | nothing beyond savepoint | Prolog failure with reason |
| Host runtime unreachable or scope served on wrong node without re-route | nothing | Prolog failure `actor_host_unavailable` / `actor_not_hosted_here`, distinct from absence; with re-route, retried once within deadline |
| Actor dies after acceptance, before or after commit | question + HUD ref if committed | success if committed; submission later re-checks hosting; no retry at opening |

## 4. Unverified

Router route selection internals (`quod_ask_router.erl` body), whether any
existing route hint prefers the owning node, `reconcile_resource/5` semantics
beyond its call shape, and all test outcomes.
