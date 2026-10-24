# S1.4 Claude review — generic constructor inputs, inheritance, defaults and names

Reviewer: Claude Fable 5.1, 2026-10-24. Consultative; the parent validates every finding against code and architecture. Ticket `tsk_01M5Q1YXC2V8G59WR1KA7E8NND` (local body authoritative). Scope reviewed: `/tmp/quod-s1.4-review.patch` only. All nine files in `/tmp/quod-s1.4-final-tree.json` match the working tree by SHA-256 (checked 2026-10-24). Work radar for the ticket shows one lane (Yan), no concurrent activity. I ran no tests or builds; test outcomes are taken from `/tmp/quod-s1.4-verification.md`.

**Verdict: no blocker.** The constructor rules implement the confirmed D4/D10 behaviour on existing seams (direct `isa/2` declarations, `'$quod_stricter_class'`, `have_attribute/3,4`, the read-only state check, Erlog bindings and choicepoints, the proof continuation boundary). Superseded GUI validators are removed rather than kept beside their replacement. S1.1–S1.3 production files are untouched by the patch. Every finding below is optional cleanup or coverage; none changes a confirmed decision, and none asks for a temporary creation executor.

Production delta reproduced from `git diff --numstat` plus the new file: quod_gui.pl +24/−23, quod_common_primitives.erl +63/−2, quod_committed_projection.erl +1/−1, construction.pl +178 → **+266/−26, net +240**, as reported.

## What I verified by inspection

- **Inputs are bindings, not state.** `'$quod_with_build_plan'` stores the plan under a tuple-keyed Erlog binding ([src/predicates/quod_common_primitives.erl:155](/home/yan/src/quod/src/predicates/quod_common_primitives.erl:155)). Every `#cp` restores `bs`, so any backtrack to a choicepoint older than the scope restores the outer inputs without extra code. The Boundary cp captures the pre-scope `bs`; the Redo cp captures the in-scope `bs`, so redo resumes inside the scope with the right inputs and the second return restores again. A cut after the scope removes Redo/Boundary (erlog `cut/5` sweeps compiled cps, [erlog_int.erl:698](/home/yan/src/quod/_build/default/lib/erlog/src/erlog_int.erl:698)); that is harmless because inputs were already restored at return. A cut inside `Goal` is behind `call/1`'s barrier ([erlog_int.erl:415](/home/yan/src/quod/_build/default/lib/erlog/src/erlog_int.erl:415)).
- **Error restoration.** `quod_proof_continuation:prove/3` tags caller errors with the invocation ref, so a scope's handler only restores inputs for errors raised inside its own `Goal`; nested scopes compose inner-first, ending at the outermost `Previous`. Matches the two exception tests.
- **Preflight is really read-only and exports bindings.** `'$quod_state_check'` enters a read-only frame that clears assert/retract hooks ([src/quod_erlog_db_local_prove.erl:502](/home/yan/src/quod/src/quod_erlog_db_local_prove.erl:502)) and yields with the inner `bs` intact ([src/predicates/quod_action_predicates.erl:103](/home/yan/src/quod/src/predicates/quod_action_predicates.erl:103)), so `Order`/`Attributes` escape while a mutating provider raises. `leave_read_only` touches only db fields, so `fail_reasons` recorded by `fail_with_reason` inside the frame survive to the caller.
- **Undefined optional predicates fail, not error.** The projection sets `unknown = fail` ([src/quod_committed_projection.erl:60](/home/yan/src/quod/src/quod_committed_projection.erl:60)) and `clause/2` on an undefined procedure fails ([erlog_int.erl:768](/home/yan/src/quod/_build/default/lib/erlog/src/erlog_int.erl:768)). An ontology with no `constructor_order/2`, no `have_attribute/4` or no `constructor/3` clause at all therefore works, although no test exercises that case (see coverage).
- **Ancestry, cycles, order.** `'$quod_constructor_graph'` checks the path before the seen-set, so a cycle is detected on the first exploration of any class in it; the topological sort rejects residual contradictions as `constructor_order_cycle`. I traced the diamond (`thing, vehicle, car, boat, amphibious`) and the interleaving fixture (`y, x, first, second, joined`) by hand; both match the tests and the plan's rule 2.
- **Defaults.** Supplied wins; otherwise `'$quod_attribute_default'` drops owners superseded by a stricter owner and requires one unique remaining default. `'$quod_stricter_class'` on a parentless class fails (reflexive `isa` needs an edge), so a standalone default is retained — the diagnostic-01 fix is correct by inspection. Default values are type-checked against **all** declared types, so a type-only refinement cannot be bypassed by an inherited default.
- **Names.** `name` is declared for every bound class by one common rule; the class's own `default`/`default_from` decides the value; a provider runs once, only when nothing was supplied; `draw/5` refuses unsupported pools. The stored fact is read afterwards, so catalogue or default changes do not rewrite instances (tests `names_are_stored_mutable_and_nonunique_test`, `signed_owner`).
- **GUI retirement.** Key-by-key `gui_property_value` clauses and `gui_boolean/1` are gone with all callers; the only remaining `gui_boolean` text is under `doc/evidence/.../tree/` snapshots, which are frozen evidence, not live code. `once((gui_attribute(_, Key, Type, _), attribute_value(Type, Value)))` reproduces the old key-based acceptance exactly, including `image = none` for buttons versus assets for images. GUI selection (`gui_property/3`) and Eidolon selection are unchanged.
- **Regression barrier.** Custody is the per-generation signed `physics_activate` request ([priv/ontologies/quod_physics.pl:557](/home/yan/src/quod/priv/ontologies/quod_physics.pl:557), [src/quod_physics.erl:286](/home/yan/src/quod/src/quod_physics.erl:286)), so awaiting that operation's terminal publication is the right barrier for each restarted world's activation commit. The loop keeps the per-world `Pid ≠ NewPid` and status assertions for all three worlds, adds a custody-shape match and signature verification, and leaves the global no-I/O assertion unchanged. Nothing was weakened. The shared 15 s deadline across three worlds is stricter than before.

## Findings by severity

No high or medium findings.

### 1. Low (optional) — unknown part roles are silently dropped, unlike unknown attribute keys

- [priv/ontologies/construction.pl:22](/home/yan/src/quod/priv/ontologies/construction.pl:22) `build_plan_part/3` returns `[]` for an absent role; [construction.pl:40](/home/yan/src/quod/priv/ontologies/construction.pl:40) rejects unknown attribute keys but has no role check (no role metadata exists).
- Trigger: `with_build_plan([part(left_eyes, [attribute(name, <<"L">>)])], ...)` on a `head`. Creation succeeds with the default eye name. For attributes the same typo fails.
- Impact: a dropped override behaves like a default fallback, which the plan forbids for attribute values. It is documented in proofs.md ("class code defines supported roles"), so this is a known trade-off, not a defect.
- Minimal correction, if wanted: make role consumption explicit in the same metadata style, for example `have_part(Class, Role)` declared next to `have_attribute`, and check supplied roles against `Order` in `'$quod_constructor_description'` as keys are checked today. About +6 lines. Otherwise leave as documented.

### 2. Low (optional) — some refusals are plain failures or carry imprecise reasons

- `missing_initial_attribute` has no key ([construction.pl:117](/home/yan/src/quod/priv/ontologies/construction.pl:117)); `invalid_initial_attribute(Key)` ([construction.pl:102](/home/yan/src/quod/priv/ontologies/construction.pl:102)) is also raised when an **inherited default** violates a descendant's narrowed type although nothing was supplied; unknown supplied keys ([construction.pl:40](/home/yan/src/quod/priv/ontologies/construction.pl:40)), malformed input lists and an unsupported naming pool fail without an explicit reason.
- Impact: acceptance says conflicts and invalid inputs "fail clearly". The reasoned cases (`constructor_cycle`, `constructor_order(Class)`, `constructor_order_cycle`, `conflicting_attribute_defaults`, `constructor_requires_local_class`) are clear; these few are not. Erlog's automatic predicate-failure reasons may partly cover them; I did not check what text reaches a client.
- Minimal correction: pass `Key` into `'$quod_default_value'` and use `missing_initial_attribute(Key)` / `invalid_default_attribute(Key)`; `fail_with_reason(unknown_initial_attribute(Key))` at line 40; `fail_with_reason(invalid_build_inputs)` in `with_build_plan/2`. About +4/−2 lines.

### 3. Low (optional) — the scoped-control skeleton duplicates the state-check one

- `with_build_plan_2` / `build_plan_return_1` / `build_plan_redo` / `build_plan_failed` / `build_plan_step` ([quod_common_primitives.erl:120](/home/yan/src/quod/src/predicates/quod_common_primitives.erl:120)) mirror `state_check_1` / `state_check_yield_1` / `state_check_redo` / `state_check_failed` / `run_read_only` ([quod_action_predicates.erl:66](/home/yan/src/quod/src/predicates/quod_action_predicates.erl:66)): Boundary cp, yield goal, Redo cp, continuation `run`/`prove`.
- One real difference: the build plan embeds the whole `#build_scope{}` (including the caller's continuation list) in the yield goal, and Erlog's general `prove_goal` dereferences the goal on every return ([erlog_int.erl:558](/home/yan/src/quod/_build/default/lib/erlog/src/erlog_int.erl:558)), so each scope exit walks the entire remaining continuation. The state check passes only the `Ref` and recovers its scope from the labelled cp via `take_boundary`. Correct today (the tests cover success, failure, redo, cut and errors), but it is a second copy of the same control algorithm and costs O(|Next|) per exit.
- Minimal correction: label the Boundary with `{?MODULE, Ref}`, pass only `Ref` in the yield goal, and share `take_boundary` (or extract one `quod_proof_scope`-style helper used by both). Roughly −15 lines across the two modules. Cleanup, not a defect.

### 4. Low (optional) — the universal `name` declaration changes public attribute reflection

- [construction.pl:4](/home/yan/src/quod/priv/ontologies/construction.pl:4) `have_attribute(Class, name, binary) :- nonvar(Class).` is loaded into every projection. Six system ontologies export `have_attribute/3` as a public query (`environment_query`, `lens_query`, `material_query`, `measure_query`, `rendering_query`, `licence_query`), so `quod:measure::have_attribute(unit, K, T)` now also answers `name/binary`, and any bound non-class term is reported as having a `name`.
- Reachability: I found no Erlang, client or UI consumer of `have_attribute/3` (only an explorer rendering test), and no Prolog rule body reads it. Cosmetic today; worth knowing before an inspection Eidolon enumerates attributes. Restricting to `'$quod_known_class'` would break the standalone-class case the diagnostic fixed, so I do not recommend that. Accept, or document in proofs.md.

### 5. Low (limitation to document) — type descriptors must be unary local predicates

- `attribute_value/2` ([construction.pl:130](/home/yan/src/quod/priv/ontologies/construction.pl:130)) requires `atom(Type)` and calls `Type(Value)`. Existing declarations use compound or undefined type names: `quantity(Unit)` ([quod_material.pl:66](/home/yan/src/quod/priv/ontologies/quod_material.pl:66)), `list` ([quod_measure.pl:281](/home/yan/src/quod/priv/ontologies/quod_measure.pl:281)), `millimetres`/`degrees`/`permille` ([quod_environment.pl:19](/home/yan/src/quod/priv/ontologies/quod_environment.pl:19)); only `colour/1` exists as a unary predicate. Under `unknown = fail`, supplying any value for those keys fails as `invalid_initial_attribute`.
- Not reachable in S1.4 (no live creation; none of those classes is constructed) and the right owners are S1.7 and stage 3. A one-sentence rule in the proofs.md section ("a type name is a unary predicate visible in the owning ontology") would prevent surprise.

### 6. Coverage gaps (optional, none blocking)

- The cross-ontology provider form shown in proofs.md (`quod:names::draw(...)`) inside the read-only preflight is untested; the test draws from a locally loaded `quod_names.pl` inside `session_prove`. `::` is a read and `::draw` already works in lobby world creation, so I expect it to work; S1.7 will exercise it for real.
- An ontology with zero `constructor/3`, `constructor_order/2` or `have_attribute/4` clauses is safe by inspection (`unknown = fail`, `clause/2` fails) but untested; every fixture carries all three.
- `required` on one unrelated parent and `default(V)` on another is reported as `conflicting_attribute_defaults`; defensible, but undocumented and untested.
- Multi-clause constructor bodies leaving choicepoints, and failure after a sibling's writes, belong to S1.5's savepoint integration as the ticket states.

## Preservation checks

- S1.1–S1.3 production code is outside the patch; `operation_authorized/2`, `'$quod_committed_check'`, outcome and ingress modules are unchanged. The S1.3 local-composition rule is matched by `constructor_requires_local_class`.
- GUI: `gui_property/3` most-specific selection, `gui_initial_value`, `gui_value` and Eidolon selection unchanged; label type tightened from `binary` to `nonempty_binary` reproduces the old `Text \= <<"">>` check and has no external type consumer.
- Terrain `display_name` (two sites) untouched, as stage 3 owns it.
- No new process, executor, queue, knowledge base or transaction lane. No compatibility fork: the old validators are deleted, not retained.
- The plan and tracker edits are user-owned bookkeeping and were read for context only.

## Limitations

- No tests, builds, xref or Dialyzer were run by me; counts (685 tests, 38 constructor tests, xref pass) are the verification note's claims. I did not re-read the retained logs.
- I did not reproduce the world-library intermittent failure; the verification note itself says the trace does not conclusively attribute the original writer. My assessment is that the added barrier is correct and strictly stronger, based on the custody and activation code.
- I did not verify `quod_erlog_db_local_prove:authored_state/1`'s exclusion of common clauses for the new `have_attribute/3` rule; existing common rules such as the `isa/2` closure already coexist with authored `isa/2` facts through the same path, so I expect source listing and guarded edits to be unaffected.
- I did not check the erlog pin hash or run the clean gates; the parent's frozen manifest is the evidence of record.

## Reviewed manifest

| File | SHA-256 (prefix) | Status |
| --- | --- | --- |
| priv/ontologies/construction.pl | 3c3887a2b3b0dea9 | new, matches |
| priv/ontologies/quod_gui.pl | f936c4e430ff3f73 | matches |
| src/predicates/quod_common_primitives.erl | ba45bf461b3e3e0f | matches |
| src/quod_committed_projection.erl | 55cebb7a58a61fd9 | matches |
| test/fixtures/constructors.pl | 125f6236576d04e3 | new, matches |
| test/quod_constructor_tests.erl | 770cb3dc75e733be | new, matches |
| test/quod_gui_examples_tests.erl | 76169b56a2156e69 | matches |
| test/quod_gui_question_tests.erl | 82a3c3fe18872984 | matches |
| doc/proofs.md | f6a1e9879df8e067 | matches |

Unchanged code inspected for reasoning: `priv/ontologies/common_predicates.pl` (isa closure, stricter class, owner name, goal/state-check use, `member_eq`), `src/predicates/quod_action_predicates.erl` (state check), `src/quod_proof_continuation.erl`, `src/quod_erlog_db_local_prove.erl` (read-only frames, staged state), `_build/default/lib/erlog/src/erlog_int.erl` and `.hrl` (fail, cut, call, clause, unknown flag, dereference, records), `priv/ontologies/quod_physics.pl` and `src/quod_physics.erl` (custody), `priv/ontologies/quod_names.pl` (draw), `priv/ontologies/animals.pl`, the `have_attribute` declarations across system ontologies, and `test/quod_gui_examples_tests.erl` around the recovery section.


## Parent validation and disposition

The parent checked the findings against the frozen source and existing architecture.
The review identifies no demonstrated blocker in the scoped S1.4 contract. No
production or test changes were made during this review, and all nine files still
match the manifest used for the 685-test passing run and production xref.

- Unknown part roles are not consumed: class bodies explicitly select supported
  overrides. This is distinct from supplying an invalid value for a declared
  attribute. A new part-declaration schema is an optional design change, not an
  automatic correction required by this review.
- The missing-key diagnostic and plain failures are real opportunities for clearer
  errors. `invalid_initial_attribute(Key)` already describes both supplied values
  and resolved defaults; it is not inherently a mislabel for an invalid default.
- The scope-control resemblance and dereferencing of the embedded continuation
  are confirmed by inspection. Extraction and its claimed line savings have not
  been implemented or measured; state checks also manage read-only database frames.
  No performance regression was demonstrated by this review.
- Universal name metadata is intentional and already documented at
  [doc/proofs.md:260](/home/yan/src/quod/doc/proofs.md:260). The unary type-validator
  contract is also already documented at
  [doc/proofs.md:244](/home/yan/src/quod/doc/proofs.md:244). Existing descriptive
  metadata such as `quantity(Unit)` is not automatically an executable validator.
  That limitation is reachable by calling the internal planner directly, even
  without S1.5's live hook; absence of a hook is not itself a reason to dismiss it.
  Classes using those descriptors need appropriate executable validation when
  adopting construction. This review does not claim universal support for legacy
  type descriptors or assign all such adoption work to S1.7.
- The additional coverage suggestions are retained as suggestions. No new test
  result is claimed here. Existing read-only preflight, scope, default, diamond,
  signed-owner and recovery-barrier evidence remains in the verification report.

S1.4 remains in review and uncommitted; stage 1 and the plan remain open. S1.5
and stage 3 boundaries are unchanged. No new ticket or review round was started.


## Optional findings follow-through (25 October)

Yan requested implementation of the optional findings after the review. This
section supersedes the earlier disposition where it said no changes were made;
the original review and its frozen evidence remain historical records.

1. **Unknown part roles:** `have_part(Class, Role)` declares supported overrides.
   Shared Prolog preflight checks supplied roles against the constructor ancestry
   and reports `unknown_initial_part(Role)` before bodies run. Class bodies still
   own construction and explicitly pass nested inputs. Tests cover typos, inherited
   roles and nested overrides checked against the child's own declarations.
2. **Refusal reasons:** malformed inputs, unknown attribute keys, missing required
   keys and failed default providers now have explicit reasons. Invalid supplied
   and default values keep the accurate `invalid_initial_attribute(Key)` reason.
   Tests assert the actual retained failure reasons, including unsupported pools.
3. **Scope reuse and continuation cost:** scope returns now carry only a native
   reference, not the record containing the caller continuation. Boundary lookup
   moved into the existing `quod_proof_continuation` module and is shared with
   read-only state checks; the old private lookup was removed. Distinct lifecycle
   adapters remain because read-only checks suspend/re-enter database frames while
   build inputs use logical bindings. They already share exception control. No
   new executor or generic lifecycle framework was added. Scope-exit dereference
   no longer traverses the caller continuation; no latency speedup is claimed.
   Existing cut/redo/error tests and a new interleaved read-check/binding test
   validate behavior.
4. **Public name reflection:** preserved as the confirmed universal name behavior.
   Documentation now explicitly says reflection is not class-membership evidence;
   tests cover standalone and arbitrary bound terms and unbound enumeration.
5. **Type descriptors:** documented the executable unary-validator requirement
   and the limitation of compound/undefined descriptive metadata. Tests refuse
   `quantity(metres)` and an undefined `degrees` validator and exercise an authored
   unary validator. No unchecked fallback, descriptor-specific engine or terrain
   migration was introduced.
6. **Coverage:** added completely absent optional predicates, required/default
   conflict with caller/subclass resolution, and a real `quod:names::draw/5`
   provider through the signed owner and read-only constructor preflight. The
   existing stored-name and unchanged-read checks still run. Whole-attempt rollback
   and multi-clause constructor/savepoint integration remain S1.5.

Follow-up verification is recorded in
[optional findings verification](/tmp/quod-s1.4-optional-verification.md).
These corrections were independently checked by Codex; no additional Claude
review was requested or run. Production delta for this follow-up is **+39/−28,
net +11 lines**; total S1.4 production delta is **+291/−40, net +251 lines**.
The growth supplies role validation and refusal details; shared boundary lookup
replaces the previous private implementation.

Final correction gates: **704 EUnit tests passed** (including **45 constructor
tests**) and **production xref passed**, both exit 0. No xref findings; compilation
reported only existing float signed-zero warnings in unchanged physics code.
`git diff --check` passed and the 11-file correction manifest is unchanged.
Earlier failed fixture runs and their corrections are retained in the linked
verification report. S1.4 is in review and uncommitted; the stage and plan remain
open.


## Commit closure

Yan approved committing S1.4 and closing its ticket after the correction gates.
This commit includes the implementation, tests, contract, review disposition and
S1.4 completion record. The earlier in-review statements describe their recorded
verification points. Stage 1 and the plan remain open at 42%; S1.5 is unstarted.
