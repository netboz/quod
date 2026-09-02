# Root-owned ontology creation refactor

**Status:** root-owned creation is implemented. The later generic-agent hard
break removes the transitional user-home convenience described in the delivery
history below; the current policy is the node-or-`ontology_creator_agent/1`
policy stated here and in `generic-agent-identity-plan.md`.

## 1. Decision

`create_ontology/3` belongs to `quod:root`.

Creation introduces a new ontology identity. Root is the network bootstrap,
system-catalogue, and network-wide creation-policy authority, so it is the
natural controlling ontology for that decision. The node which authors the
accepted root transaction remains the effect executor and initially hosts the
new ontology. Other nodes subsequently host that exact identity through the
existing `quod:node::join_ontology/3` action.

This changes neither the low-level hosting mechanism nor the meaning of
creation:

- the accepted action is an ordinary root proof and root transaction;
- the transaction contains the existing closed `create` direct effect;
- the one node-wide effect journal executes that effect after root applies it;
- the one namespace manager creates the local namespace; committed node-actor
  hosting facts separately own restart intent;
- the created ontology still owns its own independent genesis and ledger;
- root gains no per-ontology catalogue row, endpoint, route, or hosting table.

Creation policy and local hosting are therefore separate without becoming two
execution paths:

```text
quod:root create policy
        |
        v
ordinary action -> ordinary transaction -> existing direct effect
                                               |
                                               v
                                  local namespace manager

another host: quod:node join policy -> the same action/effect machinery
```

`can_invoke/4` remains the only entry ACL. Every genesis already contains the
generated trusted-host clause for a node-owned top-level proof with an empty
call chain. That clause is part of the same Prolog ACL, not a second Erlang
authorization path. Signed clients and inter-ontology calls carry a non-empty
engine-owned chain and therefore remain governed by root's authored
`can_invoke/4` clauses. After entry, root's ordinary
`can_create_ontology/3` action prerequisite decides which authenticated agent
may create which ontology and with which genesis options. No permission is
compiled into Erlang.

## 2. Prolog contract

Move the generic creation declaration from `quod_node.pl` to `quod_root.pl`:

```prolog
ontology_hosted(Name) :- ontology_join_state(Name, starting).
ontology_hosted(Name) :- ontology_join_state(Name, joining).
ontology_hosted(Name) :- ontology_join_state(Name, ready).

action('$quod_stage_ontology'(Handle,
                              create_ontology(Name, Options, Anchor),
                              ontology_hosted(Name)),
       [current_principal(Agent),
        can_create_ontology(Agent, Name, Options),
        ontology_join_state(Name, not_hosted)],
       ontology_hosted(Name)).
```

The root policy supports two authorities in one generic predicate:

- an admitted node may create an ontology;
- an exact stable agent reference named by `ontology_creator_agent/1` may
  create an ontology.

The agent rule is ordinary changeable Prolog policy, not another lifecycle
operation. `create_user_home/0`, `user_home_genesis/3`, `quod_user`, and their
browser workflow are deleted; initial agent facts use generic ontology genesis
and no `create_agent` or `create_human_user` API is introduced.

`quod_node.pl` retains only node-hosting policy such as
`join_ontology/3` and a future non-destructive leave operation. Its creation
action and `can_create_ontology/3` clause are deleted.

Root and node deliberately retain identical local `ontology_hosted/1` helper
clauses. They are not parallel lifecycle implementations: each controlling
ontology must prove its own desired state through the same local observation
bridge. Root uses the helper for create; node uses it inside
`ontology_joined/2` for join.

## 3. One implementation path

The shared governed bridge remains `quod_ontology_predicates`:

- `{create_ontology, 3}` is accepted only in `quod:root`;
- `{join_ontology, 3}` is accepted only in `quod:node`;
- both allocate one opaque proof-local request and enter the existing common
  `action/3` relation;
- only the existing private continuation reached after the declared
  prerequisites prepares and stages the effect.

There is no root-specific preparer, effect type, transaction branch, journal,
executor, or namespace-manager call. The existing `create` prepared descriptor
and the existing `local_durable/ontology_lifecycle/create` effect are reused
unchanged.

Moving the controlling ontology is already supported by the generic effect
path: the effect executor is the transaction author, while the authenticated
agent remains the effect actor. The journal derives the controlling ontology
from the anchored transaction reference. None of those rules is specific to
`quod:node`.

## 4. Exact keep / refactor / delete map

### Keep unchanged

- the common Prolog `action/3` selection and prerequisite machinery;
- `quod_ontology_predicates:lifecycle_request_predicate/3` and its one private
  staging continuation;
- generic `create` and `join` validation, preparation, canonical encoding, and
  execution in `quod_ontology`;
- `quod_effect`'s existing lifecycle descriptor and validation;
- proof-session prepared-effect custody;
- the transaction seal, submission, and outcome path;
- the one `quod_effect_journal` owner;
- `quod_namespace_manager` creation, joining, restart intent, and collision
  handling;
- the generic signed-agent request and root `ontology_creator_agent/1` policy;

### Refactor in place

- move the generic create action and creation policy from `quod_node.pl` to
  `quod_root.pl`;
- change the bridge ownership matrix from node/create + node/join +
  root/create-user-home to root/create + node/join;
- replace the temporary key-derived creator rule with the stable exact
  `ontology_creator_agent/1` grant;
- update tests so creation commits in the root ledger while the resulting
  ontology is hosted only on the executor node;
- update current architecture and operator documentation to distinguish root
  creation authority from node hosting authority.

### Delete as a unit

- the external `{create_user_home, 0}` staging-predicate registration;
- `supported_action(quod:root, create_user_home)`;
- the `user_home` member of the private lifecycle-request kind;
- `quod_ontology` validation and preparation clauses for the bare
  `create_user_home` action;
- special error/failure mapping clauses for that action;
- the entire `quod_user` module and key-derived home helpers;
- the create action and `can_create_ontology/3` policy in `quod_node.pl`;
- tests, comments, and current documentation which describe generic creation
  as owned by `quod:node` or describe user-home creation as a separate
  lifecycle case.

No forwarding compatibility clause remains. A generic create submitted to
`quod:node` is rejected as the wrong controlling ontology; a generic create
submitted to root follows the sole creation path.

## 5. Security and failure behaviour

The refactor preserves these boundaries:

1. Every request enters root through the normal proof ingress and
   `can_invoke/4`. The existing generated trusted-host clause admits a
   node-owned empty-chain proof; signed clients and inter-ontology calls have a
   non-empty chain and must match root's authored clauses.
2. `can_create_ontology/3` is proved in that same root proof before source is
   read or an effect is staged.
3. The public action must be ground and structurally valid.
4. Failed prerequisites and backtracking discard the opaque request, prepared
   descriptor, and effect with the normal proof overlay.
5. Validators verify the same closed effect and transaction evidence as
   before; they do not execute or reinterpret the creation goal.
6. The effect executes only on its exact node-key executor after ordered root
   apply. A different node never adopts it.
7. An uncertain result returns the existing anchored transaction outcome and
   is never automatically retried.

Root policy can later delegate creation to exact stable
`agent_instance_ref/3` principals or add dynamic prerequisites using ordinary
Prolog. That changes policy facts and rules, not Erlang dispatch.

The shipped authored root `can_invoke/4` clause is transitionally open to
non-host callers. This is distinct from the generated trusted-host clause,
which remains deliberately narrow to node-owned empty-chain proofs.
Consequently an actor permitted to write arbitrary root clauses can first weaken
`can_create_ontology/3` and then create an ontology. This is not introduced by
the ownership move, but moving network-wide creation policy to root makes the
existing trust assumption especially visible. Root's authored invocation
policy must be tightened before any deployment in which arbitrary
authenticated actors are not trusted to alter root policy.

## 6. Formats and deployment

There is no consensus, transaction, DTX, effect, prepared-descriptor, ledger,
wire, signature, or journal format change. The existing public `create` effect
bytes retain their meaning; only the ontology whose ordinary transaction
records the effect changes from node to root.

`quod_root.pl` and `quod_node.pl` are genesis sources. Updating them does not
rewrite a running fleet's committed root and node ontologies. This change adds
no compatibility declarations or second live migration path. Activation
therefore requires a coordinated clean re-found from the new genesis sources.
A rolling binary deployment against the old ledgers must not be claimed to
activate the new ownership.

An already prepared `create_user_home` journal row does not require draining
or migration. Its private prepared descriptor is already the generic `create`
descriptor, and recovery decodes but does not redispatch the stored public
action term before executing that descriptor. The old action name therefore
remains digest-bound audit data while the existing create effect resumes
unchanged. This property is pinned by a recovery regression below.

A rolling binary deployment alone must not be claimed to activate the new
ownership. No runtime source fallback or compatibility policy is added.

## 7. Required tests

1. A node-authored `create_ontology/3` against root commits one root
   transaction, contains one existing create effect, and starts the new
   ontology on that executor node.
2. The same goal against `quod:node` fails and stages no effect.
3. `join_ontology/3` still succeeds only through `quod:node` and is unchanged
   after the creation move.
4. With root's authored open clause removed and the generated trusted-host
   clause retained, a signed browser request is denied by `can_invoke/4`
   before preparation; the test must not mistake the host default for the
   authored public policy.
5. Root `can_create_ontology/3` denial prevents source reading, transaction
   submission, journal reservation, and namespace creation.
6. A node principal admitted by root may create; a non-admitted node may not.
7. An exact `ontology_creator_agent/1` grant admits the stable agent reference
   through the generic root action and no special agent action/effect shape.
8. An ungranted agent cannot create; Root's normal ACL also protects mutation
   of creator-policy facts.
9. Repeating an already-satisfied creation remains the common action no-op and
   commits no second transaction.
10. Backtracking and a failed alternative leave no prepared descriptor,
    journal row, namespace, or transaction.
11. Accepted-effect uncertainty remains resolvable through the exact root
    transaction reference without resubmission.
12. Effect-journal restart and application restart resume creation on the
    exact executor node; another root validator does not execute it.
13. Root catch-up/replay validates the creation transaction without a
    node-specific exception.
14. A signed agent uses the generic `quod:root::create_ontology/3` goal and the
    same root action/effect path as a node-authored creation.
15. A source/client/test grep finds no `create_user_home`, `quod_user`, special
    registration path, or current claim that `quod:node` owns creation.
16. A durable journal fixture staged by the old action name
    `create_user_home` but carrying a generic prepared-create descriptor
    recovers and executes once under the new binary without redispatching that
    name.

Run production compile, full EUnit, focused lifecycle/effect/client suites,
xref, Dialyzer, client build and tests, and `git diff --check`. A fresh-root
hardware test must then create one ontology, inspect the root effect
transaction in Explorer, restart the executor, verify automatic reopening,
join the exact ontology from another node, and verify no duplicate genesis or
effect execution.

## 8. Documentation closure

Implementation updates, at minimum:

- `ontology-creation-plan.md` and `ontology-creation-input-plan.md`;
- `ontology-join-plan.md` where it groups create and join under node;
- `durable-lifecycle-effects-plan.md`;
- `ontology-lifecycle-single-path-plan.md` and the retired authorization
  summary;
- `ontology-actor-architecture.md`;
- `signed-client-goals-plan.md`, `client-authentication-plan.md`, and
  `client-world-direction.md` for the temporary convenience predicate;
- `ontology-subscription-plan.md`, `minimal-agent-delivery-plan.md`, and
  `agent-fipa-plan.md` where they assign lifecycle ownership;
- module documentation and comments in `quod_ontology`,
  `quod_ontology_predicates`, `quod_user`, and the two shipped system
  ontologies.

Historical descriptions remain only when clearly labelled historical. The
final current-contract sweep must find one root-owned create action, one
node-owned join action, one generic Erlang staging/continuation path, and no
special user-home lifecycle case.
