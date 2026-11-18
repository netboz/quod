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
candidates and assertion construction use the same internal savepoint machinery.

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

A retained signed view withdraws its projection during dependency recovery but
keeps its existing subscriptions and original deadline. It requests a fresh
signed read only after all retained dependencies are ready and any cancelled
opening worker has exited; recovery never reuses the withdrawn authorization.

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

[Class owners author these declarations.]{decided by="yan.guiborat" on="2026-11-08"}

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
[`Check` names a predicate at the declaring class owner receiving the original
`(Actor, Subject, Operation)`. Checks must be pure committed Prolog: they cannot
write or consult live services. The class tree, derived memberships and class ACL
declarations follow a qualified class into its owner, as `isa/2` does; those reads
enter the proof's dependencies. The class owner declares the class's ACL defaults
and compulsory requirements; the storing ontology declares per-instance ACL
facts. `can_invoke/4`, custody and committee verdicts cannot follow.]{decided by="yan.guiborat" on="2026-11-08"}
Missing or failing checks deny; attempted mutations or forbidden bridges raise
`invalid_committed_policy`. Actual owner fences retain their typed
pending/rebuilding errors.

The ordinary operation guard can read `current_ontology_identity/2` for the
built-in ontology self-membership. Strict local verdict contexts still refuse
that bridge; the operation guard does not change their admissible predicates.

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

[The assertion hook uses this guard for creation; offered GUI operations use it
at their own mutation boundary. An instance whose membership was asserted in the
current transaction is checked as `construction(Class, Id, Inputs)` by its class
policy, without staged instance overrides, until it commits. The assertion hook
supplies that context; callers cannot supply it to the public guard or forge it
with build inputs. Policy runs over committed state, requires absence of the new
identity there, follows the original class's ancestry and receives the original
inputs rather than staged slots. This permits atomic initial placement after the
assertion. The context follows the transaction through foreign calls and is
restored with rollback; existing instances use committed memberships.]{decided by="yan.guiborat" on="2026-11-08"}
The reserved grant-edit operation still requires a committed instance.
The authenticated-principal bridge is installed
once by the common runtime vocabulary. Terrain/helper and placement
checks retain their existing callers and protections. Authorized arbitrary source
rewrites remain outside the narrower operation contract. There is no generic
final-state validator. Packaged common rules do not rewrite founded ontologies;
activation requires the existing authorized compatible-artifact/source procedure.

## Creation inputs, defaults and inheritance

[The shared [construction rules](../priv/ontologies/construction.pl) initialize
slots when a bare `assert(instance_of(Class, Id))`, `asserta` or `assertz`
requests creation with an output variable. The existing assertion hook checks
committed class policy, allocates the ID, resolves inputs, and stages membership
and initial slots under the shared savepoint. Constructors do not build instances
or parts; a `constructor/3` body at a class owner refuses creation. Parts are
asserted like any other instance.]{decided by="yan.guiborat" on="2026-11-08"}
The hook does not call `goal/1` to test the newly staged membership: an
already-true state would skip slot initialization. Calling the input wrapper
alone creates nothing.

The ID is a full 26-byte Crockford ULID: 48-bit Unix milliseconds plus 80 bits
from `crypto:strong_rand_bytes/1`. Every creation draws independently; inherited
slot declarations initialize the same instance. A collision with a live direct
or derived membership refuses the attempt before slots can overwrite it. Normal
creation accepts no caller-chosen new ID. There is no counter or deleted-instance
catalogue. The exact reference is `entity_ref(Namespace, GenesisAnchor, Id)`; a
named output in the signed goal is retained by the ordinary selected-result
machinery.

[`with_build_plan(Inputs, Goal)` supplies a ground list of `attribute(Key, Value)`
entries during `Goal`; keys are unique atoms. Nested wrappers replace the inputs,
restore the enclosing scope on exit and preserve ordinary alternatives and cut.
Inputs are private proof bindings, never stored facts or authority, and do not
implicitly cross ontology calls. Part inputs and `have_part/2` declarations are
removed. A goal that creates several instances supplies each instance's slots
through its own wrapper.]{decided by="yan.guiborat" on="2026-11-08"}

[The internal `'$quod_constructor_plan'(Class, Instance, Inputs, Order, Attributes)`
requires a bound identity and performs read-only preflight through the existing
state-check machinery. It validates the inheritance order and resolves all
initial slots before writing. Class declarations follow a qualified class into
its owner, including parents, `constructor_order/2`, slot declarations, selected
default providers and type checks. It reuses `isa/2`, most-specific selection and
`have_attribute(Class, Key, Type[, Default])`.]{decided by="yan.guiborat" on="2026-11-08"}

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
back to an unchecked value. Refusals identify unknown attributes, missing
required keys, invalid resolved values and failed default providers. Malformed
input lists report `invalid_build_inputs`.
GUI property validation uses these same declared types; GUI-specific selection
and field constraints retain their existing behavior.

```prolog
isa(chair, thing).
class_permission(chair, create, allow).
have_attribute(chair, name, binary, default(<<"Chair">>)).
have_attribute(chair, legs, positive_integer, default(4)).

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
read normally by operations and views. Changing defaults does not rewrite
instances. Names are mutable and nonunique; renaming changes neither identity
nor other instance facts. Terrain's `display_name` migration remains stage 3.

`constructor_order(Class, Parents)` lists every direct parent exactly once.
Zero or one parent needs no declaration; multiple parents require one ground
proper list. Duplicate, missing or extra parents, multiple declarations,
inheritance cycles and contradictory order constraints fail before slot writes.
The order combines all ancestor-before-descendant and declared parent constraints;
a stable topological traversal uses the authored branch order for independent
choices. Shared ancestors are selected once per attempt, for the same instance as their
descendants. Constructor order never chooses attribute defaults or permissions.

[The assertion savepoint selects the first complete initialization answer.
Failed alternatives and caught errors restore membership, slots, events,
effects, creation context and bindings together; read dependencies remain
monotonic. Commit intent is inherited. Successful creation releases its own
boundary before the caller continues. Use an enclosing `transaction/1` or action
when later caller failure or backtracking must also discard the completed
creation.]{decided by="yan.guiborat" on="2026-11-08"}
Cuts and ordinary staging keep their existing meanings. There is no generic
final-state validator.

## Membership source and recovery

Membership queries and derived memberships create nothing. A bare ground
assertion can repeat or add a classification to an existing identity without
initializing slots; it refuses a new caller-selected identity. This is not
live specialization and does not initialize the additional class's defaults.

An explicit clause, including `instance_of(Class, Id) :- true`, authors source
instead of requesting creation. It stores its variables as clause variables.
The guarded source editor already emits this form, so replacing/reordering a
suffix preserves surviving identities and attributes without a temporary identity
registry. Its exact source round-trip check remains unchanged. Authorized source
addition/removal edits facts as written; it does not promise initialized slots
or prevent deliberate identity reuse by an author with broad source authority.
Strict read-only overlays still reject both facts and explicit clauses.

Founding compilation and common loading compile clauses directly. Commit apply,
restart and projection rebuild restore decided facts and results through the
existing materializer. Validators consume the sealed IDs/names and existing
read dependencies; they do not initialize slots again or draw replacement identities. Historical
reactions are not replayed. Ontology founding remains its own governed lifecycle,
outside ordinary instance construction. Existing terrain actions store their
decided terrain/sky memberships as explicit clauses. Their governed construction
and identity scheme remain with the terrain integration stage.

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
no pids, references, funs or maps). No size limit applies to a reason or to
the list of reasons: a fixed limit would make the result of a proof depend on
it (Yan, 2026-11-03 and 2026-11-18). `What` is a lower-case
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
