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

A single writer uses its ordinary transaction; a signed foreign-only writer
also retains a source claim under the existing operation lifecycle. The
[multiwrite contract](multiwrite-architecture.md) covers these routes, several
writers and explicit independent intent. An expired caller
may receive `outcome_unknown` with an anchored operation reference. Resolution
observes installed and certified evidence; it does not re-prove the goal or
resubmit an uncertain write.

Signed operation resolution returns the original selected named bindings for
ordinary transactions (including foreign-only writes) and atomic groups. Anonymous variables and internal
proof variables are excluded by the same signed-name projection as the initial
reply. The compact outcome index retains the ordinary transaction's identity
and terminal slot; the lookup worker reads and verifies that exact transaction
through the existing retained history index. A completed target vector recovers
the same sealed result from its exact source claim, or from the claim embedded
in a certified remote receipt after checking every target. All routes share the
durable result decoder and preserve the original target verdicts.
Certification still consumes the compact applied-status snapshot. No result
archive, ledger-prefix scan or proof rerun is introduced. Repeated unchanged
lookups perform no storage writes or syncs.

Results survive outcome-owner restart and later deletion of the created
instance while the original history remains retained. Missing or unavailable
transaction evidence leaves the signed operation unresolved, even when a compact
committed classification exists. The original request digest, scope, genesis
anchor and signing-key/session checks still apply; lookup grants no execution
authority. Remote outcome replies require the selected bindings on ordinary
committed results, under the existing current-committee corroboration. Older
status-only replies do not satisfy that result contract; validators serving
these replies need compatible code. No persisted format or history changes.

`current_request_operation(Operation)` exposes the original authenticated
`operation(SourceNamespace, SourceAnchor, AgentBytes, OperationId)` reference.
It is the same reference in the origin and every foreign scope; it does not
allocate another request. `AgentBytes` is the canonical signed agent reference,
not a new GUI identifier. The accessor is proof-bound, so it can supply a
correlation key in an ordinary write without consulting live state. Signed read,
execute, cursor and control proofs expose their own reference. An unsigned proof
fails this query. Reaction matching, membership verdict re-proofs and validator
policy contexts cannot invent an operation reference; a reaction's later signed
proof has its own request identity. The reference alone grants no permission and
is not evidence that its operation committed.

`current_signed_request(Bytes)` succeeds only when canonical retained request
bytes match the original signed request already verified for this proof. It uses
the same authenticated digest in the origin and every foreign scope, without a
second signature check or a live observation. It fails for an unsigned proof or
different bytes, even if they describe the same actor and goal. Reaction matching
and validator policy contexts cannot use it. A domain can require this check
before consuming retained work, preventing a fresh request from substituting for
the exact intent it accepted.

`agent_request_bytes(Intent, Bytes)` is a pure conversion of the existing
`agent_goal_v1(Network, AgentReference, InstanceText, PublicKey, OperationId,
Expiry, Mode, Parser, GoalText)` term to and from the canonical signed-request bytes.
The instance text must describe the same exact agent reference. This operation
can retain future intent in an ordinary transaction; it accesses no key,
clock or live owner and grants no authority. `sign_agent_request/2` uses the
same conversion, then independently requires its existing read-only scope,
committed hosting/key policy and governed vault. Constructing or retaining
bytes neither submits them nor permits replay after an uncertain outcome.

`signed_agent_request(Bytes, Signature, Intent)` verifies the exact request's
cryptographic signature and performs that same conversion. It allocates no new
identity atoms. This pure predicate supplies authenticated data, including in
committed-policy proofs; it does not authorize the signing key, hosting, goal,
network or expiry. Those checks remain in the ordinary Prolog and ingress rules.

## Class and instance operation permissions

`operation_authorized(Subject, Operation)` is the shared Prolog guard for a
class creation or an existing instance operation. `Subject` is `class(Class)`
or `instance(LocalId)` in the executing ontology; `Operation` is a ground term
containing the exact proposed parameters. Creation uses `create(BuildPlan)`.
The guard gets the authenticated actor from the proof, checks the pinned
committed policy read-only and retains every consulted predicate in the normal
OCC read set, including absent grants and failed checks. A staged ownership,
class, requirement or grant edit cannot authorize itself or the next operation
in that proof. Concurrent changes to those dependencies conflict normally.

Classes author these local declarations:

```prolog
class_requirement(document, edit, document_edit_requirement).
class_permission(document, edit, check(document_editor)).
class_permission(public_document, edit, allow).

document_edit_requirement(_Actor, instance(Document), edit(Value)) :-
    attribute(Document, maximum, Maximum), integer(Value), Value < Maximum.
document_editor(Actor, instance(Document), _Operation) :-
    attribute(Document, owner, Actor).

edit_document(Document, Value) :-
    operation_authorized(instance(Document), edit(Value)),
    assertz(document_value(Document, Value)).
```

Declare the usual `isa/2` edges and `instance_of/2` memberships as well. Every
applicable class's `class_requirement(Class, OperationName, Check)` is compulsory;
`Check` names a local predicate receiving `(Actor, Subject, Operation)`. Checks
must be pure committed Prolog: they cannot write, consult live services or open
foreign scopes. Derived memberships and the entire ancestry consulted by the
guard follow the same rule: a foreign-qualified parent is refused, not partially
evaluated. Compose class policy into its target ontology, as for other local
authorization. Missing or failing checks deny; attempted mutations or forbidden
bridges raise `invalid_committed_policy`. Actual owner fences retain their typed
pending/rebuilding errors.

The built-in ontology self-membership uses `current_ontology_identity/2`, which
the strict policy context refuses. Consequently this guard does not yet support
`instance(ontology_ref(Namespace, Anchor))`; ontology-operation integration must
supply committed membership without weakening that boundary. Ordinary ontology
membership queries and cross-ontology class queries keep their existing behavior.

`class_permission(Class, OperationName, Grant)` supplies a default: `allow`,
`deny`, or `check(Predicate)` with the same three callback arguments. The most
specific applicable declarations win. Equivalent cyclic classes and unrelated
parents remain alternatives; differing grants deny unless a subclass or instance
resolves them. Identical grants agree. Constructor order and source order have
no precedence. Missing, malformed or nonground grants deny access.

`instance_permission(LocalId, OperationName, Grant)` replaces defaults for that
instance only. `set_instance_permission(LocalId, OperationName, Grant)` changes
it; `inherit` removes the override, while `deny` explicitly withdraws access.
Only the unique `attribute(LocalId, owner, Actor)` or an authored
`permission_administrator(LocalId, Actor)` grant authorizes the edit. An owner's
acting agent needs an explicit administrator rule/grant; ownership is not an
implicit delegation. Administrator policy receives the ground instance and actor;
it need not enumerate administrators. A wildcard administrator rule explicitly
authorizes every matching actor. This differs from a data-valued default/override
whose grant must be ground. The reserved `set_permission(Name, Grant)` operation
requires an instance subject, passes all applicable compulsory requirements and
cannot be delegated through a class default or instance override. Editing a grant
never removes requirements on its later use.

Place the guard inside the operation before mutations, so offered operations,
`goal/1` actions and directly submitted goals reach the same check. Calling a
policy query with a supplied actor is only inspection, never execution authority.
Discovery may call the public guard with complete inputs; it performs no operation
and grants no authority to a later submission. Incomplete inputs fail without
binding choices. Actual execution checks the exact actor, target and parameters
again. Ontology `can_invoke/4` admission remains a separate prerequisite.

This supplies the policy seam for constructor and GUI integration; it installs
neither constructor hooks nor a menu executor. Terrain/helper and placement
checks retain their existing callers and protections. Authorized arbitrary source
rewrites remain outside the narrower operation contract. There is no generic
final-state validator. Packaged common rules do not rewrite founded ontologies;
activation requires the existing authorized compatible-artifact/source procedure.

## Constructor inputs, defaults and inheritance

The shared [construction rules](../priv/ontologies/construction.pl) use
`constructor(Class, Instance, BuildPlan)` for every class. Classes author their
own bodies and required parts. These rules are internal building blocks: live
`instance_of/2` assertion dispatch, generated IDs, authorization integration and
whole-attempt rollback remain S1.5. No public creation executor or assertion hook
is installed by S1.4. Calling the input wrapper alone does not create anything.

`with_build_plan(Inputs, Goal)` supplies temporary inputs during `Goal`. Inputs
are a ground list of `attribute(Key, Value)` and `part(Role, PartInputs)` entries;
keys and roles are atoms, unique within their respective categories. Nested
wrappers replace the current inputs, restore the enclosing scope on exit and
preserve ordinary Prolog alternatives and cut. Inputs are private proof bindings,
never stored facts, authority or a second knowledge base. They do not implicitly
cross ontology calls. Each constructor body receives its original BuildPlan,
while the ambient inputs are empty: nested parts receive only what their owning
class explicitly passes through a new wrapper. `build_plan_part/3` selects one
role's overrides, returning `[]` when absent. Classes declare supported override
roles with `have_part(Class, Role)`; preflight accepts roles declared anywhere in
the constructor ancestry and refuses unknown roles before bodies run. Each part's
own preflight validates its nested inputs. The declaration does not create a part:
class code still constructs its required parts and explicitly passes overrides;
the caller does not repeat the internal tree.

The internal `'$quod_constructor_plan'(Class, Instance, Inputs, Order, Attributes)`
requires a bound identity and performs read-only preflight through the existing
state-check machinery. It validates the full constructor order and resolves all
initial attributes before writes or bodies. It reuses `isa/2` declarations,
most-specific selection and `have_attribute(Class, Key, Type[, Default])`.
Class definitions and constructors are composed locally, like shared permission
policy; a foreign-qualified parent is refused rather than silently skipped.
Ordinary cross-ontology ancestry queries retain their existing behavior.

A supplied value wins over class defaults. Otherwise most-specific default
providers win over inherited providers; equal unrelated defaults agree, while
conflicting defaults require a caller or subclass choice. `required` and an
unrelated parent's `default(Value)` also conflict: neither silently wins.
A type-only declaration
does not erase an inherited default. Supplied values must satisfy **all**
applicable type declarations; an invalid supplied value never falls back.
Unknown supplied attributes and duplicate entries fail. A three-argument
attribute declaration is optional; the fourth argument can be `required`,
`default(Value)` or `default_from(Provider)`. The latter calls
`Provider(Instance, Value)` once, only after selection. Providers and unary type
checks run read-only. `attribute_value(Type, Value)` checks ground data using
ordinary unary Prolog predicates, with `term` accepting any ground value.
Type names must be atoms naming executable unary checks visible in the owning
ontology. Descriptive metadata such as `quantity(Unit)` or an undefined `degrees`
is not an executable validator; classes using it must supply validation when
adopting construction. Such supplied/default values fail validation, not fall
back to an unchecked value. Refusals identify unknown attributes/parts, missing
required keys, invalid resolved values and failed default providers. Malformed
input lists report `invalid_build_inputs`.
GUI property validation uses these same declared types; GUI-specific selection
and field constraints retain their existing behavior.

```prolog
isa(chair, thing).
have_attribute(chair, name, binary, default(<<"Chair">>)).
have_attribute(chair, legs, positive_integer, default(4)).
constructor(chair, Chair, _Inputs) :- attribute(Chair, legs, _).

isa(place, thing).
have_attribute(place, name, binary, default_from(place_name)).
place_name(Instance, Name) :-
    quod:names::draw(<<"landscape">>, <<"world">>, <<"neutral">>, Instance, Name).
```

Shared metadata declares the standard binary `name` attribute for every class,
including classes without parents. Public `have_attribute/3` reflection therefore
reports `name/binary` for any bound class term; it is not evidence that the term
has an authored class declaration or membership. Classes choose their own
ordinary or computed default; no universal personal-name draw is installed.
A supplied name bypasses the computed provider. A selected naming pool must
support the requested kind; absence fails instead of drawing another kind.
Resolved values are stored once by `'$quod_initial_attribute_writes'/2`, then
read normally by every constructor and view. Changing defaults does not rewrite
instances. Names are mutable and nonunique; renaming changes neither identity
nor other instance facts. Terrain's `display_name` migration remains stage 3.

`constructor_order(Class, Parents)` lists every direct parent exactly once.
Zero or one parent needs no declaration; multiple parents require one ground
proper list. Duplicate, missing or extra parents, multiple declarations,
inheritance cycles and contradictory order constraints fail before bodies run.
The order combines all ancestor-before-descendant and declared parent constraints;
a stable topological traversal uses the authored branch order for independent
choices. Shared ancestors run once per attempt, on the same instance as their
descendants. Constructor order never chooses attribute defaults or permissions.

`'$quod_run_constructors'/3` invokes that prepared order. Declaration inspection
is separate from execution: absent own code succeeds without skipping parents;
declared code that fails, including an explicitly called required part, fails
the construction. These helpers do not supply savepoints or commit intent.
The assertion lifecycle must compose them with S1.3's committed guard and the
existing proof savepoint. Tests compose the seams with bound fixture identities
and existing transactions; they do not claim ULID allocation or live assertion,
loading, recovery or caught-failure integration. No final-state validator is added.

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

The default signed browser request and whole-proof lifetime are five minutes,
bounded by the current login session and any shorter configured owner deadline.
A preview retains its private proof snapshot; Next and Save do not renew its
absolute deadline or lock the ontology. Expiry before durable write handoff
returns `fail` with `proof_timeout(Namespace)` through the same reason codec.
An idle cursor keeps only this terminal reply, bound to its exact owner, for
at most the configured login-session lifetime; consuming it releases the reply.
The routed browser owner likewise releases the transport lease on idle expiry.
An Accept already in flight retains its actual result or `outcome_unknown`;
expiry never turns an uncertain write into a definite failure or resubmits it.

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
