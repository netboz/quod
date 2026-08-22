# Ontology lifecycle authorization — retired design

**Status:** historical record only. The design that gave ontology lifecycle
its own authorization proof, worker, and execution entry was removed. The
implemented contract is normative in
[`ontology-lifecycle-single-path-plan.md`](ontology-lifecycle-single-path-plan.md);
agent identity is defined by
[`ontology-actor-architecture.md`](ontology-actor-architecture.md).

## Why this design was retired

The former design treated create/join as exceptional operations around the
Prolog engine. It introduced a lifecycle-only runner, a separate policy proof,
and private state that duplicated guarantees already provided by an ordinary
proof and transaction. That made policy harder to reason about and prevented
normal `::` prerequisites from using the existing scope machinery.

Those components were deleted rather than retained as compatibility code.
The historical names `run_action`, `public_action`,
`authorized_ontology_lifecycle`, and `lifecycle_transition` must not be used by
new code or documentation.

## Current contract

1. Public creation is an ordinary `execute` goal in `quod:root`; public join
   is an ordinary `execute` goal in `quod:node`. The transitional
   `create_user_home` term is only a root Prolog convenience which derives the
   fixed home arguments and calls generic `create_ontology/2`.
2. The normal top-level `can_invoke/4` check is the only entry ACL. The
   action's declared Prolog prerequisites express its remaining policy and may
   use normal local or `::` proof calls.
3. `quod_ontology_predicates` validates the public term, records one opaque
   proof-local request, and enters the shared `action/3` relation in
   `common_predicates.pl`. It does not prove policy itself.
4. Only the matching private continuation reached through that relation may
   prepare the create/join descriptor and stage its direct effect. Failed or
   backtracked branches discard their staged request and effect with the rest
   of the proof overlay.
5. A successful proof seals one ordinary transaction in the controlling
   ontology's ledger. The transaction has the normal authenticated principal,
   read set, outcome reference, and—when required—DTX path. No lifecycle
   transaction or signature format exists beside it.
6. Ordered apply releases the effect through the one node-wide durable effect
   journal. The journal waits for the runtime projection to cover the commit,
   executes the frozen prepared descriptor, verifies the declared desired
   state, and resumes or retires the row after restart using the same outcome
   and projection authorities.
7. The low-level `quod_ontology` create/join/prepared APIs are trusted same-VM
   implementation seams. Public production code does not call them directly;
   raw create/join wrappers are TEST-only.

The node principal, a signed client principal, and the future
`agent_instance_ref/3` subject are authenticated inputs to the same proof
path. A key is not an ontology instance by itself, and no caller may supply a
trusted subject tuple without the ingress and ontology evidence required by
the actor architecture.

## Verification obligations

The maintained tests must cover normal create and join, signed remote
lifecycle use, policy denial before preparation, branch rollback, stable
outcomes after uncertainty, journal restart, catch-up settlement, namespace
restart, and exact-anchor join recovery. Root test fixtures must use
`quod_app:build_ns_config/1` so they exercise the same immutable predicate
manifest as production instead of reconstructing root configuration by hand.

`priv/ontologies/quod_root.pl` and `quod_node.pl` are genesis inputs. Updating
their source does not mutate an existing ledger; deployment follows the
project's normal reviewed migration or clean-foundation decision and never
adds a second runtime policy path.
