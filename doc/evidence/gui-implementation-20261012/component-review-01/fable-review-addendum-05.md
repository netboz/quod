# Fable review addendum 5: delta-03 corrective snapshot against the component findings

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-12. Consultative only.
Earlier reports unchanged. Basis: `delta-03/` diffed against `tree/` (twelve
files and manifest). No command, build or test was run; the parent's gate
results are not claimed.

## 1. Finding by finding

- **C1 fixed.** `gui_property_value(unit, …)` uses if-then-else
  (`delta-03/priv/ontologies/quod_gui.pl`).
- **C2 fixed.** New compiled `binary/1` type test
  (`delta-03/src/predicates/quod_common_primitives.erl`), used by `gui_text/1`
  and before `binary_codes/2` in `gui_value(text_box, …)`; tests submit `42`
  and `not_binary` and expect failure.
- **C3 fixed.** `gui_local_id/1` rejects top-level `_:_` for form, control
  and component ids; `no_follow/1` covers the slice's predicates in both
  files; the test proves a colon form, control and selection value fail with
  no dependency on the named namespace in the returned read evidence. The
  plan text records the rule.
- **C4 fixed for the GUI path.** `no_follow/1` added for all `$quod_isa_*`
  helpers, `most_specific_classes/3` and `member_eq/2`
  (`delta-03/priv/ontologies/common_predicates.pl`). The added first clause of
  `'$quod_isa_path'/3` makes a declared parent in the other grouping the
  requested endpoint, and the final `'$quod_name_normalize'/2` accepts a
  bound superclass in either grouping; `t_qualified_owner_grouping` now
  checks both. Still open and unchanged: an open `isa(Qualified, X)` query
  yields qualified answers from the path clause and unqualified ones from the
  `isa/2` position-1 follower (first report C4, question 2).
- **C5 resolved by decision.** One declaration `gui_attribute/4` now derives
  both `have_attribute/3` and `gui_property/3`. Refusing unknown keys was
  rejected because components carry application attributes; the plan says so.
  Accepted.
- **C6 fixed.** Frozen values are projected in `frozen` mode with strict
  `gui_value/3` at compile, so a required frozen empty text box fails the
  schema; test added.
- **C7 fixed.** One `gui_tree_schema/2` ask per compile, one
  `gui_initial_projection/3` per values or frozen projection, one
  `gui_valid_values/1` per bind. The 32-field test counts quod:gui scope opens
  (1 schema, 2 bind, 2 defaults) by tracing `quod_proof_session:open/6`.
  `once/1` around the per-field tree lookup and the `delete/3` selection
  removes the per-field choice points (addendum 2, H1 and H3).
- **C8 fixed.** `schema_only_reader/5` founds an ontology granting only
  `gui_schema/3` and `gui_values/3` to the owner and asserts `gui_bind/5` and
  `gui_definition/5` fail.
- **C9 closed.** Parent verified erlog `delete/3` is the inverse of `insert/3`;
  the lookup is now deterministic under `once/1`.
- **C10.** `'$quod_callable'/1` is reported in
  `src/predicates/quod_action_predicates.erl`, outside every packet I was
  given; still unverified by me.
- **C11 fixed.** `vocabulary_class/3` reuses `'$quod_owner_name'/3` and
  `ontology_name/2` with `no_follow/1`; the lobby test reads both groupings.
- **C12.** Unchanged note.

## 2. Checks on the new code

- `gui_tree_schema/2` moves the container rule into the vocabulary:
  `(member(Kind, [form, container]) -> true ; RawChildren = [])` fails a
  non-container with declared children. Correct.
- `gui_property/3` uses `once(isa(Kind, Class))`; reflexive and transitive
  both hold for `slider`/`range`, so `once/1` is what prevents duplicate
  contract rows. Correct. Contract order now follows `gui_attribute/4` clause
  order; the revision depends on it, which is fine since it is one
  declaration.
- `gui_initial_projection/3` fails on two declared initials, keeps `editing`
  relaxed and `frozen` strict. `gui_match_fixed/2` compares by `==`, and
  frozen fields are also validated in `gui_valid_values/1`. Consistent with
  the C6 decision.
- `gui_bind_fields/4` with `once/1`: a duplicate submitted field leaves a
  remainder and fails without exploring alternatives; test asserts it.
- The raw tree sent to `quod:gui` carries every component attribute,
  including application attributes. Ground data only; it is a note, not a
  defect.

## 3. Evidence gaps remaining from the first report

Parameterized form, shared variables, validation context, colon data,
type errors, readonly, schema-only grant and scope counts are now covered.
Still untested: more than one `gui_vocabulary/2` row; registration counts on
repeated reads (plan section 10 names them). Gate logs and true exits are the
parent's to attach.
