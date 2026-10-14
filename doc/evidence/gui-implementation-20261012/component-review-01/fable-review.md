# Fable review: GUI component slice and opening integration

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-12. Consultative only.
Basis: `review-request.md`, `tree/AGENTS.md`, every file listed in
`source-manifest.json`, read from the frozen `tree/`. No command, build, test,
browser or headset run was performed, and I did not recompute manifest hashes.
Every statement below is source inspection. Line numbers refer to `tree/`.
Nothing here is an approval, and no test result is claimed.

Three kinds of statement are kept apart throughout: **verified** (read in the
frozen tree, cited), **proposed** (my suggested change, not implemented) and
**unresolved** (needs Yan or a run to settle).

## 1. Summary

The component slice is sound in its core mechanics: owner resolution for both
spellings of a qualified class is one shared path, class selection is
ambiguity-preserving, the revision digest is variable-sensitive and excludes
editable initial values, and frozen values correctly participate in the
revision. The defects I found are concrete and local:

- **C1** backtracking into `gui_property_value(unit, …)` raises a type error
  on an atom unit, so several "must fail" paths produce errors instead.
- **C2** client-supplied text values that are not binaries raise type errors
  instead of refusing the submission.
- **C3** any client-controlled ground term of shape `A:B` (form, control,
  submitted value) is argument-followed into the ontology named `A`.
- **C4** the `$quod_isa_*` internals and `member_eq/2` lack `no_follow`, so a
  foreign-class closure walk issues several denied scoped asks per foreign
  class, and under a broad target grant returns unqualified names.
- **C5–C7** unknown attribute keys are silently dropped, the contract is
  declared twice, and per-component asks make schema and bind cost scale with
  component count.

On the opening contract: the frozen owners support the settled requirements
only through the physics-style owner-observation path, and that path is
hard-wired to physics in five places. Section 6 gives one executable sequence
with per-boundary results; section 7 names the smallest generalization it
needs and its invariants. The sequence returns success only after the
question/HUD transition is certified, never after a socket push.

## 2. Verified facts, component slice

F1. **Owner resolution.** `'$quod_owner_name'/3` splits `Ns:Tail` and walks
`'$quod_name_tail'/4` so `quod:gui:text_box` (parsed `quod:(gui:text_box)`)
and `(quod:gui):text_box` both yield owner term `quod:gui` and local
`text_box` (`priv/ontologies/common_predicates.pl:188-195`).
`ontology_name/2` flattens either grouping to `<<"quod:gui">>` without
creating atoms (`src/predicates/quod_common_primitives.erl:89-97`,
`src/quod_ontology_name.erl:17-35`), covered by
`test/quod_common_primitives_tests.erl:16-29` and the fixture's mixed
spellings (`test/fixtures/gui-components.pl:3-7`).

F2. **Generated followers.** Every interpreted user predicate with arity > 0
that is not declared `no_follow` gets one virtual last clause per argument
position; the clause fires only when that argument is a structured
`Prefix:Tail` with `Prefix` bound, and asks `Owner::Inner` with the stripped
local name (`src/quod_erlog_db_local_prove.erl:823-829, 850-906`). Compiled
procedures (`{code,_}`, built-ins) get no followers.

F3. **Class selection.** `most_specific_classes/3` keeps every incomparable
or equivalent candidate; `gui_component_schema/4` demands exactly one
(`common_predicates.pl:105-117`, `priv/ontologies/quod_gui.pl:53-58`), so a
component that is both a button and a slider fails the whole schema
(`test/quod_gui_components_tests.erl:94-96`).

F4. **Revision.** `variant_digest/2` canonicalizes variables by first
occurrence through `erlog_int:term_instance/2` before the canonical codec, so
renaming preserves and re-sharing changes the digest
(`quod_common_primitives.erl:78-85`, `quod_common_primitives_tests.erl:42-52`).
The revision input is `schema(1, ontology_ref(Ns, Anchor), Tree,
binding(Fields, Submit), Fixed, Context)` (`priv/ontologies/gui_instance.pl:33-34`);
editable initial values are excluded, frozen values included
(`gui_instance.pl:104-110`).

F5. **Result classes.** An Erlog error from a read is normalized as
`{error, _}`, distinct from `{fail, Reasons}` and `fail`
(`src/quod_prolog.erl:5564-5572`; the same three classes are enumerated in
`src/quod_agent.erl:276-284`). `quod_lobby_tests:read/2` maps only the
`failed` outcome to `{fail, _}` (`test/quod_lobby_tests.erl:1307-1316`).
`binary_codes/2` raises `type_error(binary, …)` for a bound non-binary first
argument and `instantiation_error` when both arguments are unbound
(`quod_common_primitives.erl:293-318`).

F6. **Trace assertion.** `assert_read_has_no_io/1` traces projection
construction, history views, ledger reads and file writes/syncs
(`quod_lobby_tests.erl:720-741`). It does not count scope opens, ACL
evaluations or dependency records.

## 3. Component findings, prioritized

### C1. Backtracking into `unit` raises instead of failing (High)

`gui_property_value(unit, Text) :- atom(Text); gui_text(Text).`
(`quod_gui.pl:81`) leaves a choice point after `atom(degrees)` succeeds. The
second branch calls `gui_text/1`, which is `binary_codes(Text, _)`
(`quod_gui.pl:94`), and by F5 that raises `type_error(binary, degrees)`.

The choice point is reachable: `gui_compile/5` builds the whole component
tree first (`gui_instance.pl:18`) and only then checks the control, the
field set, variable binding and callability (`:20-29`). Any failure there
backtracks into the per-component vocabulary asks (`:45-46`), and the ask
for the fixture's `angle` component (`attribute(angle, unit, degrees)`,
`gui-components.pl:22`) resumes at the `unit` disjunction. The
unbound-continuation case at `quod_gui_components_tests.erl:97-101` takes
exactly this path, so by code reading I expect an error result there rather
than `{fail, _}`. The same applies to any authored form whose last
components carry an atom unit and whose binding declaration is wrong.

**Unresolved:** the parent reports an earlier 97-test pass. If that run
included this assertion and reported `{fail, _}`, the parent should find out
why, because by F5 an error cannot match it. Either way the predicate is
wrong as written.

**Proposed:** `gui_property_value(unit, Text) :- (atom(Text) -> true ;
gui_text(Text)).` and make `gui_text/1` a non-raising type test (fail on
atoms, numbers, compounds before calling `binary_codes/2`). Add a test that
compiles a form with an atom unit and a deliberately failing binding, and
asserts `{fail, _}`.

### C2. Mistyped submitted values raise instead of refusing (High)

`gui_value(text_box, Properties, Value) :- binary_codes(Value, Bytes), …`
(`quod_gui.pl:104-105`). `Value` arrives from `gui_bind/5`, that is from the
client. A submitted `field(name, 42)` or `field(name, foo)` raises
`type_error` inside the `quod:gui` scope. Plan section 4 requires that
"non-ground or mistyped values refuse the whole submission"; an error is a
different result class for the client (proofs.md, "Clients"), and it
terminates the proof instead of letting a later alternative run. The same
construction affects authored `label`/`help` atoms (`quod_gui.pl:79-80`),
which is less serious because authoring errors should be loud.

**Proposed:** type-test before validating in every `gui_value/3` clause
(`integer/1` is already first for sliders), and keep `gui_value/3` purely
failing for client data. Add a test submitting an integer and an atom for
the text box and expecting `{fail, _}`.

### C3. Client-controlled `A:B` terms are argument-followed (High)

By F2, every ground argument of shape `A:B` reaching an interpreted
predicate is routed to ontology `A` once the authored clauses are exhausted.
The slice guards only groundness (`gui_instance.pl:14, 37, 71, 115`). The
reachable positions:

- `Form` in `gui_schema/3`, `gui_values/3`, `gui_bind/5`: a read of
  `gui_schema(other:app:settings, R, T)` makes the local ontology look up
  `gui_form/3`, `gui_children/2`, `attribute/3`, `instance_of/2` and
  `gui_initial/3` in `other:app` through followers, compile that foreign
  form under the local vocabulary, and `gui_bind/5` returns the foreign
  `gui_form/3` continuation term.
- `Control` in `gui_bind/5`: `gui_tree_component(Tree, x:y, button, _, _)`
  ends in a follower that ships the whole `Tree` to ontology `x`
  (`gui_instance.pl:65-67, 117`).
- Submitted `Value` for a selection: `member(option(a:b, _), Options)` fails
  locally, then the follower on `gui_value/3` asks `a::gui_value(selection,
  Properties, b)` from inside the `quod:gui` scope (`quod_gui.pl:108-113`).

Authority is not bypassed (the target applies its own ACL and the principal
crosses unchanged), but each case is an unintended foreign ask under the
caller's principal, records a dependency on an attacker-named namespace in
the signed read's evidence, and costs a scope invocation. Plan section 2
allows parameterized forms such as `settings(Object)`, so `atom/1` is too
strict for `Form`.

**Proposed:** one shape rule, applied in `gui_compile/5`,
`gui_component_tree/5`, `gui_field_declarations/4` and `gui_bind/5`:
`Form`, component ids and `Control` must be ground and must not be `_:_`
at the top level; submitted values must satisfy the kind's type test before
any lookup. Additionally declare `no_follow/1` for the slice's own
predicates in `gui_instance.pl` (`gui_schema/3`, `gui_values/3`,
`gui_bind/5`, `gui_definition/5`, `gui_compile/5`, `gui_component_tree/5`,
`gui_tree_component/5`, `gui_field_declarations/4`, `gui_initial_field/4`,
`gui_fixed_values/4`, `gui_bind_fields/4`, `gui_tree_active/2`,
`gui_variables_bound/2`) and in `quod_gui.pl` (`gui_component_schema/4`,
`gui_properties/3`, `gui_property_value/2`, `gui_value/3`,
`gui_initial_value/3`, `gui_default_value/3`, `gui_options/2`). These are
never meaningfully foreign-routed. The shared relations `attribute/3`,
`instance_of/2`, `gui_form/3`, `gui_children/2`, `gui_initial/3` stay
followable, which is why the shape guard is still required. Add a test for a
`_:_` form, control and selection value, each expecting `{fail, _}` with no
dependency on the named namespace in the returned read evidence.

### C4. `$quod_isa_*` internals and `member_eq/2` are followable (Medium)

`no_follow/1` covers only the five name helpers
(`common_predicates.pl:182-186`). `'$quod_isa_path'/3`,
`'$quod_transitive_isa'/2`, `'$quod_direct_isa'/2`, `'$quod_known_class'/1`,
`'$quod_stricter_class'/2`, `most_specific_classes/3` and `member_eq/2` all
receive followers. Consequences for the fixture's `isa(fine_level,
quod:gui:slider)`:

- `'$quod_isa_path'(quod:gui:slider, S, Seen)` runs its three authored
  clauses (`:154-166`), then its follower asks
  `quod:gui::'$quod_isa_path'(slider, S, Seen)`.
- Inside clause 1, `\+ member_eq(QualifiedSuperclass, Seen)` (`:158`) is
  evaluated once per remote answer with a qualified first argument;
  `member_eq/2` (`:292-296`) exhausts and its follower asks
  `quod:gui::member_eq(input, Seen)`, and likewise for `gui_component`,
  `thing` and `slider`.

Against `quod:gui` these asks are denied (`quod_gui.pl:10-16` admits only
`isa/2` among them), so the visible effect is about five denied scoped asks
per foreign class per closure walk, each with ACL evaluation and a recorded
dependency, on a path the schema test runs for every local subclass. Against
an ontology with a broad grant (`priv/ontologies/lobby_instance.pl:4`) the
follower of `'$quod_isa_path'/3` returns the owner's **unqualified** local
names (`input`, not `quod:gui:input`), so `isa(fine_level, input)` becomes
provable in the caller. The slice is protected today only by the vocabulary's
narrow ACL, which is the wrong seam for this.

Related shared-semantics inconsistency, not GUI-specific: an open query
`isa(quod:gui:slider, X)` yields the reflexive qualified answer from
`isa/2` clause 1 and unqualified `input`, `gui_component`, `thing` from the
`isa/2` position-1 follower, while the transitive path qualifies every
answer (`:157`). `device_classes/2` in `lobby_instance.pl:51-59` would see
that mix for a foreign-qualified direct class.

**Proposed:** add `no_follow/1` for the seven predicates above. Decide and
document one qualification rule for open `isa/2` queries from a qualified
class, and cover it in `quod_ask_tests` next to `t_qualified_owner_grouping`.
Count scoped asks in the components test (see C7).

### C5. Unknown attribute keys are silently ignored; contract declared twice (Medium)

`gui_properties/3` iterates the contract and never looks at attributes whose
key is not in it (`quod_gui.pl:71-77`). `attribute(name, requried, true)`
compiles silently with `required = false`. This contradicts the slice's own
posture that ambiguity fails as a whole (`quod_gui_components_tests.erl:76-78`).

`have_attribute/3` (`quod_gui.pl:36-43`) and `gui_property/3`
(`quod_gui.pl:60-69`) describe the same contract and already disagree:
`unit`, `max_length` and `layout` exist only in the second. No file in
`src/` or `test/` consumes `have_attribute/3` for `quod:gui`; only
`quod_rendering.pl` declares its own. Two declarations of one truth is the
duplication AGENTS.md forbids.

**Proposed:** after `gui_properties/3`, require every attribute key to be a
contract key for that kind (fail otherwise), and derive `have_attribute/3`
from `gui_property/3` or delete it. Test an unknown key.

### C6. A frozen required empty text box compiles but can never be submitted (Low)

`gui_fixed_values/4` validates frozen values with `gui_initial_field/4`,
which relaxes `required` (`gui_instance.pl:104-110, 116-118`), while
`gui_bind_fields/4` validates the echoed frozen value with strict
`gui_value/3` before the frozen comparison (`gui_instance.pl:124-129`). A
readonly or disabled required text box with empty initial value therefore
yields a valid schema and revision but every submission fails.

**Proposed:** pick one rule. Either reject such a form at compile time or
validate frozen fields with `gui_initial_value/3` in `gui_bind_fields/4`.

### C7. Ask count scales with component and field count (Medium, performance)

Per schema read: one anchored vocabulary ask per component
(`gui_instance.pl:45-46`), one closure walk per local subclass (plus the C4
overhead), one ask per frozen field for the default and one for validation
(`gui_instance.pl:97-100`). `gui_values/3` and `gui_bind/5` recompile the
whole schema and add one ask per field (`gui_instance.pl:83, 116, 126`).
For an N-component form with M fields a bind is roughly N + 2M scoped
invocations before the continuation is returned. The comment at
`gui_instance.pl:54-56` acknowledges the per-ancestor cost but not the
per-component one. The trace assertion (F6) cannot see this.

**Proposed:** one vocabulary ask per form, passing the list of
`(Id, Classes, Attributes)` and receiving `(Id, Kind, Properties)` rows; one
ask for all field validations in `gui_bind/5`. Extend the test to count scope
invocations (or `quod_ask` openings) per read and assert a form-independent
bound.

### C8. `gui_bind/5` and `gui_definition/5` are readable wherever the grant is broad (Medium, authority note)

`quod_gui.pl:35` says a schema never contains an application continuation.
That is true of `gui_schema/3` only. `gui_definition/5` and `gui_bind/5` are
ordinary predicates; the lobby's owner grant (`lobby_instance.pl:4`) and the
test's blanket grant (`quod_gui_components_tests.erl:18`) expose them, and
the test reads the continuation as the owner (`:49-50`). For the owner this
is fine. Plan section 6 says the application grants "descriptor/validation
reads" to humans and "the declared continuation" to the responder; the slice
should state, and test, that `gui_bind/5`/`gui_definition/5` must not be
admitted to client principals. No negative test exists for a principal with
a schema-only grant.

### C9. `delete/3` semantics are load-bearing and unverifiable here (Low)

`gui_bind_fields/4` (`gui_instance.pl:123`) and `gui_initial_value/3`
(`quod_gui.pl:117`) rely on `delete/3` removing one unifying element,
binding the pattern and failing when none exists. The missing-field and
duplicate-field assertions (`quod_gui_components_tests.erl:51-57`) pass only
under that reading; under SWI's non-binding delete-all the missing-field
case would reach `binary_codes/2` with both arguments unbound and raise. The
erlog library is outside the frozen tree, so I could not verify which
definition is installed. A local two-line `gui_take_field/4` would remove the
dependency on a library semantic the file does not state.

### C10. `'$quod_callable'/1` is not in the frozen tree (Low)

`gui_instance.pl:29` and `common_predicates.pl:227` call it; no file in
`tree/src` defines it. Its contract (whether it rejects `::`, `transaction/1`
or control constructs in a continuation) is therefore unverified by this
review. Plan section 4 ("submissions cannot supply arbitrary goals") rests on
`gui_bind/5` returning only the authored continuation, which holds
regardless, but the callability rule for continuations should be named in
the slice's documentation.

### C11. A second owner-grouping helper remains (Low, cleanup)

`vocabulary_class/3` (`lobby_instance.pl:58-59`) groups by matching a
binary-prefixed `Namespace:Class`, a shape the parser never produces for
`quod:lobby:prolog_console`, so it effectively passes unqualified names only.
The new shared resolution (`'$quod_owner_name'/3` + `ontology_name/2`) is the
one path the plan asks for. Migrate `device_classes/2` to it or record why
not, in the same scope.

### C12. Unanchored closure walk, anchored schema ask (Note)

`gui_compile/5` checks the vocabulary anchor (`gui_instance.pl:16, 45`), but
the class closure reached through `'$quod_isa_path'/3` clause 1 asks
`Ns::isa/2` without an anchor (`common_predicates.pl:155-156`). A wrong
anchor fails the schema ask, so the result cannot mix hierarchies; the cost
is that a foreign-anchored walk is performed before the failure. The
accepted P1-4 disposition already notes this clause.

## 4. Evidence gaps for this slice

- The final expanded run (empty required defaults, disabled-value revision)
  is reported as in progress; no gate log, true exit or line delta is in
  this folder. The review request itself says not to claim tests, and I do
  not.
- No test for the parameterized form the plan requires (`settings(Object)`),
  for shared-variable equality between fields, for `gui_validation_context/2`,
  for more than one `gui_vocabulary/2` row, for an unknown attribute key, for
  a `_:_` form/control/value, or for a schema-only grant.
- No ask-count or registration-count evidence for repeated unchanged reads;
  the plan's section 10 lists that as required.
- The components test asserts the same revision for lobby and independent
  ontologies by structure, not by value, which is correct (different
  `ontology_ref` anchors would differ); worth a comment so a future reader
  does not "fix" it.

## 5. Verified facts, opening integration

I1. **Control lane.** A `control` request runs a read-only proof
(`src/quod_prolog.erl:506-528`). After finalization the one staged transient
is released; `ok` keeps the answer, a definite `{error, R}` becomes
`{fail, [R]}`, `{unknown, R}` becomes `{error, R}`
(`quod_prolog.erl:4425-4436`). The only valid transient today is a physics
input to a local pid (`src/quod_effect.erl:22-35`). No durable write can
occur in this lane.

I2. **Sealing veto.** Events are staged into the proof's local changes
(`src/predicates/quod_transaction_predicates.erl:41-57`,
`src/quod_erlog_db_local_prove.erl:9`), so an event-only diff is a nonempty
diff. Any nonempty diff with a recorded live bridge fails
`{non_transactional_dependency, F}`, and direct effects are admitted only with
an empty diff (`src/quod_dtx.erl:280-297`; `seal_bound_reads/5` at `:244-255`
additionally forbids outcome reads in membership diffs). Direct effects are
closed `ontology_lifecycle create|join` descriptors whose executor must be the
plan signer (`quod_effect.erl:39-42, 95-103`). The effect journal therefore
cannot carry a question or a request; it is lifecycle custody only
(`src/quod_effect_journal.erl:2-18`).

I3. **Observations.** A committed `observed(_)` event in a diff is dropped
before matching (`src/quod_runtime.erl:1409-1414`). Owned notices enter only
from runtime intake: a physics owner's `physics_observation` message, checked
against the runtime's own installed world spec, token, epoch, validity window
and live mode (`quod_runtime.erl:609-620, 3205-3220`), host observations and
resource notices. `physics_observation/1`, `prepare_signed_request/3` and the
reaction result bridge all require physics metadata
(`src/predicates/quod_physics_predicates.erl:223-226`,
`src/predicates/quod_runtime_predicates.erl:186-195, 294-302`); the audience
for a physics notice is exactly the world's authority agent
(`quod_runtime.erl:2047-2054`). `recovery_observation/1` is node-recovery
only (`quod_runtime_predicates.erl:151-158`). Reaction matching is read-only
and grants no authority (`:215-259`).

I4. **Agent custody.** A `{custodied, B, S, T}` request signs the material
goal, commits the custody transaction `T` with the signed bytes bound, and
only then submits those exact bytes; a failed custody is
`request_not_submitted`, an uncertain one `custody_unresolved`
(`src/quod_agent.erl:204-218`). Worker death or deadline on an execute-class
request reports `{outcome_unknown, OperationRef}` for the material
operation (`quod_agent.erl:120-131`). Results are delivered to the owner and
published on `{agent, Ref}` (`:88-93`); the runtime relays a physics job's
result to the waiting physics owner (`quod_runtime.erl:684-690`). The
physics precedent is `react_on(observed(Sample), …)` with
`prepare_signed_request/3`, a custody transaction that stores the request row,
and a finishing transaction gated by `current_signed_request/2`
(`priv/ontologies/quod_hinged.pl:73-102`;
`quod_physics_predicates.erl:198-208`). `quod_agent` request modes are read,
execute, custodied, resolve and node-delegated; there is no control mode
(`quod_agent.erl:133-136`).

I5. **Outcome lookup.** Resolution needs the exact signed bytes and
signature; a missing claim is `operation_pending`, explicitly "never
permission to create a fresh operation"
(`src/quod_client_goal_ingress.erl:178-199, 266-269`). The browser journals an
execute before posting it and resolves on reload
(`client/src/signed-client.js:154-168`, `client/src/operation-journal.js:10-12`);
control commands are never journaled (`signed-client.js:54`).

I6. **Authenticated view owner.** `quod_client_simulation` is one WebSocket
process per connection, opened by an exact anchored `client_world_view/4`
signed read verified through ordinary ingress; it retains the human's source
namespace and anchor, the instance and the request scope
(`src/quod_client_simulation.erl:44-93, 111-128`). It registers nothing per
human and holds no form state. Control ingress refuses a non-local target
instead of forwarding (`quod_client_goal_ingress.erl:329-330`).

I7. **Human ontology grants.** Non-owners may invoke only `isa/2` and the
public source queries (`priv/ontologies/quod_human_user.pl:10-11`); the human
itself may invoke anything in its own namespace
(`priv/ontologies/human_user_instance.pl:6-7`). The internal FIPA request shows
the two-ontology atomic transition shape through `::`
(`priv/ontologies/fipa_request.pl:13-24`).

I8. **Reaction audience and capacity.** `agent_request/6` is accepted only
from the runtime's own event runner, resolves the executor against the hosted
incarnation's epoch and key (`quod_runtime.erl:376-391, 2002-2023`) and
refuses with `busy` at the pending count/byte budgets (`:2164-2177`), which
remain Erlang constants.

## 6. One executable opening sequence (proposed)

This is the only sequence I found that satisfies all settled requirements
with the owners above. It needs the generalization in section 7; nothing in it
exists yet, and I claim no part of it as supported today.

Two flavours share the first half. A **presentation** (human opens a form on
their own object) completes at the receiver install. A **question**
(agent-originated, durable) completes only at the certified creation.

**R0, original request.** A signed `control` goal in the application
ontology, e.g. `App::(current_ontology_identity(App, A), gui_present(Form,
Opening))`, signed by the human's browser (presentation) or by the
responsible agent through governed signing (question; needs the control mode
of I4/section 7, E4). The read-only proof compiles `gui_schema/3`, resolves
`gui_recipient/2` and `gui_responder/2` from committed policy, derives
`Opening` from R0's own operation reference (plan section 6, replayable
accessor E6), checks the responder's hosting from committed `agent_hosted/4`
rows, and stages one transient `gui_opening(ReceiverPid, Expected, Offer,
Expiry)` through a staging-class predicate that looks up the local receiver
registered for the selected human and scope. No registered receiver on the
selected scope: reasoned failure `{no_connected_human, Human}`. Scope not
local: `{receiver_route_unsupported, Scope}`, distinct from absence.

**Acceptance point.** `finalize_request_result/3` releases the transient to
the receiver with R0's deadline (I1). The receiver verifies the exact human,
connection incarnation and supported component version against its own
verified open evidence (I6). Presentation: it installs the draft and replies
`ok`; R0 succeeds. Question: it does **not** reply yet.

**Exact material operation.** The receiver sends one owned observation
`gui_opening_accepted(Opening, Human, Incarnation, FormRef, Revision,
Expiry)` to the responder ontology's runtime (section 7, E1). The runtime
matches `react_on(observed(gui_opening_accepted(…)), …)` for the selected
responder only, in a read-only snapshot, and the clause calls
`prepare_signed_request(Bytes, Signature, gui_store_question_request(Opening,
Bytes, Signature))` (E2). The agent then:

1. commits the custody transaction, a single-writer execute in the responder
   ontology that asserts `gui_question_request(Opening, Bytes, Signature)`;
2. submits the custodied bytes: the material operation is the execute
   `Responder::(current_ontology_identity(R, RA), gui_create_question(Opening,
   FormRef, Revision, Human, Bytes, Signature))`, gated by
   `current_signed_request(Bytes, Signature)`, which in one atomic group
   retracts the custody row, asserts the awaiting question row, and calls
   `Human::(current_ontology_identity(H, HA), gui_link_question(Opening,
   ResponderRef))` under the new narrow grant (E5). Creation refuses a
   repeat `Opening`.

**Durable custody before dispatch.** Step 1 precedes step 2 (I4). The custody
row holds the exact bytes needed by outcome lookup (I5).

**Result relay.** The runtime relays the agent's result to the receiver
(generalized `agent_owned_result`, E1). The receiver pushes the descriptor
frame only after a certified commit, then replies `ok`. R0 succeeds. A
definite refusal before step 1 replies `{error, Reason}`; R0 fails with that
reason. Anything uncertain replies `{unknown, Reason}` carrying the operation
reference when known; R0 errors.

### Boundary table, question flavour

| Loss | Durable state | Original caller result |
| --- | --- | --- |
| Caller dies before admission | none | nothing was signed; nothing to resolve |
| No receiver on selected local scope | none | `fail`, `{no_connected_human, Human}` |
| Receiver scope on another node | none | `fail`, `{receiver_route_unsupported, Scope}` |
| Receiver refuses (wrong human, incarnation, version) | none | `fail`, receiver reason |
| Receiver dies before emitting the observation | none | `error`, `owner_unavailable` (uncertain by I1; conservative) |
| Responder not hosted / stale epoch / `busy` | none | `fail`, runtime reason relayed |
| Reaction unmatched or guard failed | none | `fail`, `unmatched` |
| Agent dies or deadline during custody tx | custody row maybe present | `error`, `custody_unresolved`; responder work pass reads its own custody rows, no fresh operation |
| Custody committed, submit lost / consensus unknown | custody row present | `error`, `{outcome_unknown, OperationRef}`; resolved by `committed_operation_outcome/3` over the stored bytes |
| Creation certified rejected | custody row present | `fail`, `{question_creation_rejected, OperationRef}`; custody row is visible unresolved work, cleaned by an explicit responder action |
| Creation certified committed, receiver dies before replying | question + HUD ref | `error`, `owner_unavailable`; human discovers via HUD reference, agent via question row keyed by `Opening` |
| Creation committed, human disconnects afterwards | question + HUD ref | `ok` already returned; acceptance promised no connectivity |
| Caller dies after creation, before reply | question + HUD ref | caller's absence is harmless: discovery by `Opening` on both sides |

A custody row with a certified rejected creation is not hidden as a failed
open: the reason carries the reference, and the row stays as unresolved work
until the responder's explicit domain action resolves it. No boundary
creates a second operation identity; the identity of a question is `Opening`,
fixed by R0.

## 7. Smallest missing capability and its invariants (proposed)

E1. **Owner-authenticated observation intake generalized from physics.**
One notice kind `{owned_observation, Metadata}` with
`owner, incarnation, ref, authority, event, expiry, deadline`, admitted by
the runtime only when the owner is the process currently registered under
`{client_view, Human, Incarnation}` (registration performed by the view
process after its verified signed open, I6), the authority is a hosted agent
with matching epoch and key, and the validity window and live mode hold,
mirroring `physics_observation_current/2`. The audience is exactly that
authority (as `audience_bindings({physics, _}, S)` does). The reply map
`physics_requests` becomes owner-generic. Invariants: a notice from a pid
that is not the registered owner is dropped with an error reply; an expired
or stale notice never matches; the queue cap applies.

E2. **Metadata gating generalized.** `prepare_signed_request/3`,
`reaction_result_2/3` and an `owner_observation/1` query accept any owner
metadata, not only `physics`. Invariant unchanged: the template's two holes
remain proof variables, a generic `observed(_)` clause cannot consume an owned
request, and a match with owner metadata but no `signed_store` preparation
fails (`quod_runtime_predicates.erl:299-301`).

E3. **Transient kind for a view receiver.** `valid_transient/1` and
`release_transient/2` accept `{gui_opening, Pid, Expected, Offer, Expiry}`
for a local registered receiver, with the same `ok | {error, R} |
{unknown, R}` contract and the same context rules (read-only proof only).
The receiver's handling must be synchronous to the caller's deadline and
must not reply `ok` for a question before the certified commit.

E4. **Agent control mode.** `quod_agent` request modes and
`agent_work_goal/5` dispatch gain `control` with timeout result
`{error, {outcome_unknown, OperationRef}}` class semantics, because a released
transient may have been admitted (proofs.md, owner replies). Already noted by
the plan; still unimplemented in the tree.

E5. **Narrow human grant.** `human_user_instance.pl` admits
`gui_link_question/2` and `gui_unlink_question/2` for a principal equal to the
selected responder of that exact `Opening`, nothing else. Invariant: the
grant is checked against committed facts in the human's own ontology inside
the same atomic group as the creation.

E6. **Replayable operation-reference accessor** for the signed request of a
control proof, so `Opening` is derived from R0, not minted.

Recovery invariant for all of the above: the custody row's bytes are the only
resolution evidence; the responder's existing work pass may read
`committed_operation_outcome/3` over them, may submit the stored bytes again
only through the existing custody path (same bytes, same identity), and never
signs a replacement. Whether the existing agent-work custody recovery
(`quod_runtime.erl:596-607`) already re-dispatches a stored custodied request
after an agent restart is **unverified** here and must be checked before
relying on it.

## 8. Unresolved questions for Yan or the parent

1. C1: what did the completed run report for the unbound-continuation
   assertion, and does any seam map a scoped Erlog error to `failed`?
2. Open `isa/2` queries from a qualified class: qualified, unqualified, or
   both answers (C4)?
3. Should an unknown attribute key fail the schema (C5)?
4. Frozen required empty fields: reject at compile or relax at bind (C6)?
5. Is generalizing the physics observation intake (E1–E3) acceptable as the
   one owner path for opening, or do you prefer a different owner? The
   alternative I examined, letting the human's browser sign the creation
   after an offer frame, needs a browser-to-socket report of the journaled
   operation, which is the receipt protocol the request forbids, so I did
   not propose it.
6. Receiver-scope policy for multiple tabs: which committed fact selects the
   incarnation?

## 9. Unverified by this review

- erlog's `delete/3` and `;`/choice-point semantics (library outside the
  tree); C1 and C9 reason from them.
- `'$quod_callable'/1` behaviour (not in the tree).
- Whether remote-scope Erlog errors always surface as `{error, _}` to the
  origin for streamed asks; I relied on `quod_prolog.erl:3732-3735`.
- Agent-work custody recovery after restart (`quod_runtime.erl:596-607`).
- Any test outcome, gate log or line delta; none was run or read here.
