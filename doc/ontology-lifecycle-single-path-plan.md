# Single-path ontology lifecycle refactor

**Status:** implemented and source-gated. This document is the authoritative
lifecycle architecture. It
replaces the lifecycle-only proof and authorization machinery described in the
older creation, join, lifecycle-authorization, and durable-effect documents.

## 1. Objective

Creating or joining an ontology must be an ordinary authenticated Prolog goal:

```text
signed or node-authored goal
        -> normal can_invoke/4 check
        -> normal action/3 declaration and prerequisites
        -> governed Erlang staging predicate
        -> ordinary sealed transaction
        -> existing durable effect journal
        -> local operation after ordered apply
```

There is no lifecycle ACL, lifecycle proof engine, lifecycle principal, or
second action evaluator beside that path. Prolog decides whether the goal may
run and whether its declared prerequisites hold. Erlang only supplies
engine-owned observations, prepares a closed effect, and performs that effect
after the transaction commits.

This refactor changes no ledger, transaction, consensus, DTX, effect, directory,
or outcome format. It removes duplicated orchestration around the existing
formats.

The implementation adds one general action rule needed by any durable external
effect: a rollback-safe staged effect carries the exact desired state it
promises. The common postcondition check may recognize that promise during the
proof; after commit, the existing effect journal still checks the real external
state before reporting success. This is not lifecycle-specific and creates no
second state store.

The journal itself is one node-wide owner supervised by `quod_sup`. Its private
file is stored beside the node's other durable state, while each public effect
remains in the ledger of the ontology that controlled the action.

The journal's concurrent custody capacity is also Prolog-owned policy, not a
compiled ceiling. Root defaults to 64, may commit one override assertion
or use `set_effect_custody_capacity/1`, and may select any non-negative integer
or `unlimited`. Root is deliberately the owner because it is the one ontology
every node starts before any system ontology can be created; putting the rule
in `quod:node` would make creation of `quod:node` depend on policy that did not
exist yet. Root's founding state handler projects the value into the same
journal before outward effects; Simplex and the signing journal do not
maintain a second effect-specific count.

## 2. Removed duplication

The prior implementation grew a separate lifecycle corridor around the
ordinary proof machinery. This refactor removed the corridor as a unit; it
left no forwarding wrapper or compatibility clause.

### 2.1 Authorization duplication

Delete:

- the Prolog prerequisite `authorized_ontology_lifecycle/1`;
- its governed predicate registration and handler;
- `authorize_lifecycle/5`, `policy_goal/2`, and the lifecycle verdict state;
- both direct `lifecycle_authorized/2` checks in `quod_prolog`;
- the isolated read-only authorization sub-proof;
- tests and comments which describe the visible prerequisite plus hidden
  mandatory recheck as defence in depth.

The deletion also removes one future identity migration site: the isolated
helper currently accepts only the transitional `{node, Key}` and `{user, Key}`
principal shapes, while the ordinary proof context is already the authority
the stable agent format will replace.

`can_invoke/4` remains the one entry ACL. Domain conditions such as
`can_create_ontology/3` and `can_join_ontology/4` remain ordinary declared
prerequisites, not a second ACL. They execute in the same proof and may use the
normal `::` selector subject to the scope and transaction rules below.

### 2.2 Principal duplication

Delete the private overlay fields and APIs named `lifecycle_principal` and the
code that copies a principal into them only for an `action` worker.

Delete the corridor-only `lifecycle_principal/1`,
`valid_user_lifecycle_principal/1`, and `lifecycle_request_principal/2`
functions in `quod_prolog` as well. They derive and validate a second principal
copy which the ordinary proof boundary already supplies.

Add one governed query bridge:

```prolog
current_principal(Principal)
```

Its Erlang handler reads the already authenticated principal from
`quod_proof_context` and binds `Principal` with `unify_prove_body`. The caller
cannot choose or replace the value. Node-authored goals already obtain the
engine signer's node principal at the normal proof boundary; signed goals carry
their verified principal through that same context. The later agent format
replaces the transitional principal term once, without changing this predicate
or the lifecycle flow.

Node state needed by policy stays behind ordinary query bridges such as
`ontology_join_state/2` and `ontology_genesis_anchor/2`. A new local observation
gets another small query predicate in the owning system ontology; it does not
justify another proof mode.

### 2.3 Worker and ingress duplication

Delete:

- `quod_prolog:run_action/2` (the completed caller sweep found no surviving
  production owner);
- `public_action`, its cast messages, and its ready/not-ready clauses;
- the `action` proof-worker kind and `effect_context` special case;
- `admit_public_action`, `lifecycle_request_principal`, and the registry-based
  top-level detour through `quod_predicates:action_transition/2`;
- `run_lifecycle_origin`, `run_authorized_lifecycle_action`, and the remaining
  lifecycle-only worker pipeline.

Delete `validate_action_request/2` and its lifecycle-only
`{ok | error | fail, ...}` classification at ingress. Structural validation
moves into the staging bridge reached through the ordinary proof; no
pre-classification fork remains in `quod_prolog`.

Trusted same-VM callers use the existing `quod_prolog:execute/2`; clients use
the existing signed `execute` ingress. Both submit the same Prolog goal and
therefore receive the same `can_invoke/4`, proof, scope, sealing, transaction,
and outcome behaviour.

The completed caller sweep found no non-lifecycle owner for the
`action_transition` predicate role, so it is removed. A staging bridge is a
normal `staging` predicate; the old role is not retained as a one-operation
label.

The same sweep currently shows no non-lifecycle registered `effect`-class
predicate and no other caller of `effect_context/2`. If that remains true at
implementation time, remove the unused context kind, constructor, dispatch
matrix rows, tests, and comments too. A future reaction/effect slice can add
the mechanism it actually needs; it is not a reason to retain today's
lifecycle corridor. Do not touch `policy_verdict`, which is independently used
by scope authorization.

### 2.4 Action-selection duplication

Delete `prepare_lifecycle_action/3`, `prepare_lifecycle_candidate/3`, and
`check_prerequisites/1` from `common_predicates.pl`.

Its deletion intentionally removes the only lifecycle-only strict read-only
prerequisite walker. The shared `satisfy_prerequisites` semantics—including
recursive `goal/1` and `::`—become authoritative. If a prerequisite must be a
read-only policy query, the ontology author expresses that policy; Erlang does
not silently substitute a weaker walker.

Keep the existing private `quod_action_predicates` mechanics unchanged and
factor exact-transition execution and desired-state execution over the same
small Prolog action-candidate helpers in `common_predicates.pl`:

- validate one committed `action(Transition, Prerequisites, DesiredState)`;
- check its desired state through the existing read-only state helper;
- when the state is absent, prove its prerequisites in declaration order,
  invoke its transition inside the existing rollback-safe transaction frame,
  and verify the desired state;
- retain normal failure reasons and backtracking.

The public lifecycle predicate prebinds only its proof-local handle with
`erlog_int:unify_prove_body` and enters this common relation; it does not
reproduce prerequisite walking in Erlang. The same public predicate is used
whether invoked at top level, from another predicate, or through `::`.

The bridge must not stage an effect merely because its functor was called. It
first creates one proof-local opaque handle containing only the structurally
validated request, then continues into the common action relation. Only the
internal continuation reached after the declared prerequisites may prepare and
stage the effect. The continuation accepts only the exact proof-local handle,
so calling an internal functor cannot bypass the action declaration or policy.
No caller-provided module/function name is dispatched.

The committed action's transition is that internal continuation, not the
public bridge functor; otherwise action execution would recurse into the bridge.
The public functor allocates the handle and asks the common relation to select
the exact declaration. The continuation consumes the handle and stages the
effect. This non-recursion rule is part of the security contract, not an
implementation naming detail.

The implemented ordering is deliberately strict: no journal reservation and
no source read occurs until the normal declared prerequisites have succeeded.
Preparation then lives only in rollback-safe proof custody; the journal is
reserved after sealing and before checkpoint/submission.

Target-already-true behaviour must be stated and tested once in the common
relation. The implemented rule is the existing target-driven rule: after
normal `can_invoke/4` entry and structural argument validation, an already-true
desired state succeeds without proving transition prerequisites, reading
creation source, or staging an effect. This removes the lifecycle-only
prepare-before-state and reauthorization exceptions. If review finds that
byte-for-byte input validation or domain prerequisites are required for a
no-op, solve it for the common action relation rather than restoring a
lifecycle runner.

### 2.5 Effect-state duplication

Keep:

- `quod_effect` and the transaction's rollback-safe `effects` list;
- `quod_effect_journal` reservation, transaction binding, recovery, and
  post-apply execution;
- `quod_ontology:prepare_action` and `execute_prepared`, factored as the one
  low-level lifecycle implementation;
- `quod_namespace_manager` as the one local hosting owner.

Remove the overlay's singular `lifecycle_effect` field and
`set_lifecycle_effect`/`lifecycle_effect` APIs. They duplicate the existing
rollback-safe effects list and exist only to feed the separate runner.

The staging predicate prepares the exact descriptor once, builds the public
effect, stages that effect in the ordinary overlay, and retains its private
prepared payload in proof-local custody keyed by the effect identity. At proof
handoff, the active effect list selects the exact prepared row to reserve in
the existing effect journal before submission. Prepared rows from abandoned
alternatives die with the worker and are never executable. No second durable
store or lifecycle queue is added.

Move the final `quod_effect_journal:await` and signed/unsigned outcome-handle
shaping into the existing generic single-effect submission branch. Rename or
delete `complete_committed_lifecycle` and `committed_lifecycle_handle`; this
wait is a property of any accepted direct effect, not of a lifecycle worker.
The public create/join call therefore continues to return only after the
post-apply effect reaches a definite result, or with its exact uncertain
outcome reference.

The current protocol still admits at most one `local_durable` direct effect in
one single-participant transaction. That is a format rule already enforced by
the normal sealer and validators, not a reason for a special proof path.

The effect journal now derives the controlling ontology identity from the
stored transaction reference for validation, admission lookup, handoff, and
desired-state proof. It remains one node-local owner; there is no root/node
case split or second effect journal. Its private snapshot was hard-broken for
this refactor; consensus and ledger formats did not change.

The same derived namespace and anchor are passed into
`quod_effect:validate_transaction/4`, so validation and execution use one
identity rather than a root-specific exception.

### 2.6 Deployment is a clean re-found, not a rolling upgrade

This working-tree refactor must not be rolled onto an existing network. The
existing root ledger does not contain the new root-owned custody policy or the
current system-ontology catalogue, so a mixed or rolling deployment would
start the node-wide journal unconfigured and lifecycle goals would remain
unavailable.

The private journal also moved from the former root-scoped path
`<data-dir>/<encoded-quod:root>/direct_effects.qej` (snapshot version 1) to the
node-wide path `<data-dir>/direct_effects.qej` (snapshot version 3). The new
owner does not scan, migrate, or silently adopt the old file. A superseded
snapshot found at the new path fails loudly with its version.

The release procedure is therefore one coordinated clean re-found:

1. prove that no lifecycle effect is still in flight;
2. stop the complete fleet;
3. archive or remove both old and new private journal files as part of the
   whole data reset;
4. with empty replacement volumes and no genesis hash, found root from the
   current source using `bootstrap=true` exactly once; record its new genesis
   anchor, then expand the fleet in normal join mode with that anchor pinned;
5. never use `bootstrap=true` against an existing anchored fleet, and verify
   that the new root projects a configured custody capacity before accepting a
   lifecycle goal.

There is deliberately no compatibility reader, background migration, or
temporary fallback path.

## 3. Prolog ownership

Lifecycle policy has two explicit owners while execution stays one path.
`quod:root` governs creation because it introduces a new ontology identity;
`quod:node` governs join because it changes what one node hosts. The node that
authors an accepted root creation transaction still executes the existing
direct effect and initially hosts the new ontology. Root gains no hosting
catalogue or route table.

The intended shape is illustrative; exact internal continuation names are
implementation details:

In `quod:root`:

```prolog
action(create_ontology(Name, Options),
       [current_principal(Agent),
        can_create_ontology(Agent, Name, Options)],
       ontology_hosted(Name)).
```

In `quod:node`:

```prolog
action(join_ontology(Name, Anchor, Seeds),
       [current_principal(Agent),
        can_join_ontology(Agent, Name, Anchor, Seeds)],
       ontology_joined(Name, Anchor)).
```

The public functors remain ordinary goals. The common action relation and the
governed staging bridge ensure that direct invocation cannot skip the
prerequisites. `ontology_join_state/2` remains a local observation; the
namespace manager remains the final collision check. No durable hosting row or
endpoint is added to root.

`create_user_home` and the `quod_user` terminology are transitional, not a
third lifecycle case. The current root rule derives fixed arguments from the
authenticated principal and invokes generic `create_ontology/2`; there is no
special Erlang staging registration, descriptor, or effect. The stable-agent
format later removes that convenience rather than renaming it. An agent
ontology—including one containing a `human_user` instance—is created with the
same generic goal and ordinary genesis facts.

## 4. Creator provenance

When the principal format has become the stable
`agent_instance_ref(Namespace, Anchor, Instance)`, generic creation injects:

```prolog
ontology_creator(agent_instance_ref(CreatorNs, CreatorAnchor,
                                     CreatorInstance)).
```

into the new ontology's generated genesis facts. The creator is the agent that
authorized the goal, not the node executing the effect and not every agent
contained in the new ontology. Creation does not grant ownership implicitly;
the initial ACL may derive permissions from the creator fact.

The new ontology's certified genesis is the authority for this fact. Do not ask
foreign validators to trust or reconstruct a private effect-journal row. The
public effect continues to bind the exact resulting genesis anchor. This must
be implemented only once the stable agent reference is carried by the normal
proof evidence; do not commit a temporary `{user, Key}` creator format.

## 5. Cross-ontology policy: an explicit current limitation

Removing the local-only verdict lets an action prerequisite execute `::`
through the ordinary scope machinery. It does **not** by itself make a
cross-ontology lifecycle effect committable.

Today a foreign committed read creates another material plan, while direct
effects are deliberately excluded from DTX groups. A creation or join proof
which combines a local direct effect with a foreign material scope therefore
ends at the existing bounded `effect_requires_single_participant` result.

The recommended first implementation does not change consensus:

1. an external/FIPA approval workflow commits the approval as an ordinary fact
   in `quod:node`;
2. the later create/join goal reads that local fact in its normal prerequisites;
3. the effect remains a one-participant transaction.

If atomic dependence on a live foreign read is required, that is a separate
DTX direct-effect design covering custody, abort, Complete, and executor
failure. It must not be hidden inside this refactor or described as already
supported.

The no-op granularity is exact: join's desired state includes the expected
genesis anchor, so a different-anchor join is not already satisfied. Create's
desired state is name-only, so an already-hosted same-name create succeeds
without comparing options. That matches today's observable result; the
namespace manager remains the configuration-collision authority.

## 6. Agent-origin routing dependency

The final signed architecture starts a request in the ontology containing the
agent instance and reaches `quod:node` with the normal `::` selector. That
retains one proof controller and one ACL path.

Before enabling that format, the remote node ontology must independently
verify the origin ontology's certified active-key authorization. It must reuse
the existing authenticated scope/plan evidence; it must not trust a single
origin node, follow every agent ontology continuously, or add a target-specific
key lookup. This security work is shared by every remote signed goal and is not
a lifecycle exception.

## 7. Exact cleanup map

Implementation is incomplete until the following sweep is empty outside
explicit historical release notes:

```text
authorized_ontology_lifecycle
authorize_lifecycle
lifecycle_authorized
lifecycle_principal
lifecycle_effect
prepare_lifecycle_action
prepare_lifecycle_candidate
public_action
admit_public_action
run_lifecycle_origin
run_authorized_lifecycle_action
action_transition
effect_context used only for lifecycle
effect predicate class if it has no remaining registered owner
validate_action_request
valid_user_lifecycle_principal
lifecycle_request_principal
```

The reviewed module map is:

| Module | Keep | Refactor | Delete |
|---|---|---|---|
| `quod_prolog` | execute/signed ingress, pinned origin, sealer, final reply | move direct-effect await and result shaping into generic effect submission | `run_action`, public-action messages, action admission/worker/origin, lifecycle runner and principal helpers, structural ingress fork |
| `quod_erlog_db_local_prove` | effects list, staging, read dependencies, read-only frames | none | lifecycle principal and singular lifecycle-effect fields/APIs |
| `quod_predicates` | registration, dispatch, ordinary contexts | remove action role and, if ownerless, effect class/context | no compatibility rows |
| `quod_ontology_predicates` | lifecycle failure mapping that remains meaningful | create is root-owned and join is node-owned; add `current_principal/1` | hidden authorization predicate/helper, policy-goal mapping, duplicate owner guards; special user-home staging rows |
| `common_predicates.pl` | `goal`, shared prerequisite/transition/action helpers | add the small exact `run_declared_action` relation over those helpers | all three lifecycle-only preparation relations |
| `quod_action_predicates` | all four current private mechanics | none beyond loading/ownership changes | none |
| `quod_effect` / `quod_effect_journal` | descriptor validation, reservation, recovery, post-apply execution, await | derive controlling namespace from transaction reference at every seam | root literals and root-assuming comments |
| `quod_proof_session` | effects and signer APIs | none | singular lifecycle-effect passthrough |
| `quod_ontology` / `quod_namespace_manager` | preparation, prepared execution, one hosting owner | comments and generic caller wording | lifecycle-runner references |
| `quod_root.pl` / `quod_node.pl` | root bootstrap/catalogue and creation policy; node hosting policy | root owns create and node owns join while both reuse the common action/effect machinery | special user-home lifecycle action and duplicate ownership declarations |

Review every match in `src/`, `priv/`, `test/`, and active architecture docs.
Delete obsolete tests; do not rename them around new internals. Rewrite tests
to assert the public behaviour through `execute`/signed execute and the normal
action path. Remove stale comments saying lifecycle uses an isolated verdict,
a private lifecycle principal, a dedicated runner, two authorization checks,
or root-only permanent ownership.

Because predicate modules are pinned per ontology, the bridge dispatcher can
enforce the exact root-create/node-join matrix without a second policy engine.
Do not duplicate these owner checks in preparation or effect execution.

The documentation sweep explicitly includes `ontology-creation-plan.md`,
`ontology-creation-input-plan.md`, `ontology-join-plan.md`,
`ontology-lifecycle-authorization-plan.md`,
`durable-lifecycle-effects-plan.md`, `agent-fipa-plan.md`,
`minimal-agent-delivery-plan.md`, `distributed-proof-plan.md`, the signed-
client plans, root/node ontology comments, and every affected Erlang
moduledoc. Historical release notes may name removed symbols only when they
are clearly labelled historical; active contracts may not.

Sweep metric names and label values too. No bridge-use or lifecycle counter
may retain a deleted predicate class, action role, or corridor label.

The final caller sweep must also remove unused exports and dead lifecycle-only
error atoms such as `action_declaration_failed`, `lifecycle_staged_write`, and
`lifecycle_effect_not_staged` if the ordinary path can no longer produce them.
Keep `invalid_user_principal` while the transitional signed-user format still
uses it, and keep bounded public creation/join failures that remain meaningful;
do not preserve compatibility aliases.

## 8. Required tests

1. Node-authored and signed create goals target root, enter its normal
   `can_invoke/4` path, and use the same action relation.
2. A denied `can_invoke/4` or failed `can_create_ontology/3` performs no source
   read, journal reservation, manager call, or ledger write.
3. `current_principal/1` binds the engine-owned value and cannot be forged by a
   goal, variable binding, staged fact, or nested call.
4. Directly calling every internal staging continuation without its exact
   proof-local handle fails and stages no effect.
5. Backtracking or a failed postcondition removes the active effect; abandoned
   prepared data is not journaled and dies with the worker.
6. A successful action has one effect in the normal sealed plan, one journal
   row, one transaction/outcome, and one post-apply manager operation.
7. Crash, replay, catch-up, rejection, and outcome-unknown behaviour remains
   that of the existing effect journal. Outcome-based recovery must wait for
   the controlling runtime's existing P-before-E frontier just like live
   ordered apply; committed ledger status alone never releases external IO. A
   journal row bound before checkpoint activation remains owned by the calling
   Prolog engine and is retired if that owner dies, so it can neither leak nor
   become executable.
8. `run_action/2`, `public_action`, the `action` worker kind, the private
   lifecycle overlay fields, and the lifecycle action relations have no code or
   test caller after deletion.
9. An ordinary `::` prerequisite follows the normal scope protocol and reaches
   the documented `effect_requires_single_participant` boundary; no hidden
   local-only denial remains.
10. A prior committed local approval fact permits the same action without any
    DTX or alternate authorization path.
11. The generated creator fact is exact and certified by the new genesis once
    stable agent references land; caller-supplied duplicates or reserved heads
    are rejected.
12. Root system discovery and `quod:node` startup remain ordinary system-
    ontology behaviour; root creation ownership adds no Nomad or Erlang
    catalogue.
13. Create no-op is name-only, while join no-op is bound to the exact anchor;
    both follow the one common state-first action rule.
14. The default, an asserted override, the setter, `unlimited`, journal restart,
    and capacity refusal all converge through the one committed root-policy
    projection; no fixed 64-row check remains in journal, signer, or Simplex.

## 9. Delivery order

1. **Complete.** Review this architecture and settle the no-op input-validation
   rule and the current cross-ontology limitation.
2. **Complete.** In one atomic implementation change, refactor the common action relation and
   proof-local prepared-effect custody, assign creation to root and join to
   node, and delete the complete old lifecycle corridor.
   The replacement and the old path must never coexist as compatibility routes.
3. **Complete.** Update every active architecture document and module comment
   from the final code, then run stale-symbol and dead-export sweeps.
4. **In progress.** Run compile, focused tests, full EUnit, CT, xref, Dialyzer,
   and diff check.
5. Only after the separate stable-agent evidence slice, add generated creator
   provenance and enable agent-origin remote lifecycle calls.

No deployment, ledger reset, format change, or consensus change belongs to
this planning step.
