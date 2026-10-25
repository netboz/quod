# S1.5 assertion construction integration — Claude Fable review

Consultative code review requested by Yan (2026-10-25). Scope is S1.5 only
([tsk_01M5Q1YXC2AWGSJT9CJ86R13W8](nimbalyst://tsk_01M5Q1YXC2AWGSJT9CJ86R13W8)).
No code, test, plan or tracker edit; read-only inspection, with no builds or
tests run or claimed. The parent session checks these findings against the code.

**Parent follow-through:** F1/F2 and the dead-handler cleanup are resolved.
Final sequential gates passed **907 EUnit tests** and **production xref**;
see the parent disposition below for changes and retained optional suggestions.

## What was reviewed

- Frozen tracked diff `/tmp/quod-s1.5-review.patch` against base
  `ebf7248eee25bbc84e85bac54139cd795d6bcf3e`.
- Frozen tree `/tmp/quod-s1.5-regression-02-tree/` with manifest
  `/tmp/quod-s1.5-regression-02-tree.json`: 23 files, all SHA-256 hashes
  recomputed and matching. The untracked
  `test/quod_assertion_construction_tests.erl` is in that tree.
- Read-only dependencies in the working tree: pinned erlog `erlog_int.erl`
  (hook dispatch, `initial_goal`, `assertz_clause`, checkpoint depth),
  `quod_diff.erl` apply/dedup, `quod_simplex.erl` genesis construction and
  validation, `quod_ontology.erl` initial-term compilation,
  `quod_committed_projection.erl` common loading, `common_predicates.pl`
  guard, `quod_prolog.pl` source editor, `quod_predicates.erl` base modules.
- AGENTS.md, `doc/multiwrite-architecture.md`, archived rulings §5 and §13,
  frozen `doc/proofs.md`, the complete space plan, the S1.5 ticket body, the
  S1.3 and S1.4 evidence files.

## Limits

- The regression log `/tmp/quod-s1.5-regression-02.log` was read once,
  read-only. At that moment it ended with `904 tests, 13 failures`. The parent
  has not triaged them; I classify them below from the log text only.
- The working tree has moved beyond the frozen manifest. Six test files are
  modified in `git status` but absent from the manifest:
  `quod_gui_components_tests`, `quod_gui_examples_tests`,
  `quod_gui_question_tests`, `quod_lifecycle_single_path_tests`,
  `quod_lobby_tests`, `quod_voxel_world_tests`. Their working-tree diffs
  replace bare `{assertz, {instance_of, Class, ChosenId}}` with
  `quod_ct:source_assertion/1`. I reviewed the frozen tree, not those edits.
- Production delta counted from the frozen diff over `src/` and
  `priv/ontologies/`: +98/−34, net +64 (the parent reported +95/−34, net +61;
  the difference is counting method, not substance).

## Verdict

The hook, savepoint composition, ULID allocation, collision refusal,
reclassification rule and source/loading boundary are implemented as the
plan and ticket specify, and the rollback semantics match the settled
rulings. One production change outside the construction path is a blocker
before commit: founding compilation now stores clauses in a different
canonical form, which the genesis golden test already detects. The rest
are optional corrections and coverage notes.

## Findings, most severe first

### F1 — Blocker: founding compilation changed the canonical clause form

**Where:** frozen `src/quod_prolog.erl:7597-7609` (`terms_to_diff/1`).

**What changed:** the old path proved `{assertz, T}` per term. Erlog's
`prove_goal/2` runs `initial_goal/1` first, which renumbers every named
variable to `{0}`, `{1}`, … and `{'_'}` to fresh integers before the clause is
stored. The new path calls `erlog_int:assertz_clause/2` directly, which stores
the head exactly as parsed, so variables stay atom-named (`{'Goal'}`).

**Evidence:**
- `erlog_int.erl:211-219` (`prove_goal/2` calls `initial_goal`) and
  `erlog_int.erl:1194-1203` (`assertz_clause/2` stores `Head` as given).
- `quod_diff.erl:261-268`: `valid_variable/1` accepts both atom symbols and
  integers, so the new form passes validation instead of failing loudly.
- Regression failure 13, `prepared_genesis_native_format_golden_test`: the
  genesis anchor for an empty `genesis_diff` moved from `<<157,246,…>>` to
  `<<218,4,…>>`. The only genesis content with variables is the generated
  host-entry policy `can_invoke(Goal, Principal, [], Namespace)` compiled by
  `terms_to_diff` (`quod_simplex.erl:3790-3798`). This is inference from code
  plus the observed anchor change; I did not execute anything.

**Affected invariants:**
- Ticket: "founding compilation … restore decided facts without
  regenerating". Founding output is no longer byte-stable across the change;
  every new founding (personal lobbies, node ontologies, signups via
  `terms([...])`) produces different genesis bytes than the same source did
  before. Existing history is unaffected because replay never recompiles.
- Live and founded clauses of identical source now have two canonical
  representations. `quod_diff:apply_op` deduplicates by exact head/body
  equality (`quod_diff.erl:326-334`), so a live re-assertion of a founded
  clause that contains variables is no longer a no-op after apply.
- `quod_ontology:compile_initial_terms/1` (`quod_ontology.erl:866-873`) still
  catches `{genesis_failed, {assert, Term, _}}`, which `terms_to_diff` can no
  longer throw; a malformed term now surfaces as an erlog throw caught by the
  generic branch. The specific branch is dead code (AGENTS: remove or make
  reachable in the same scope).

**Minimal correction using the existing owner:** keep founding on the exact
pre-S1.5 compilation path and only suppress the construction hook, mirroring
the strict read-only overlay which already strips hooks
(`quod_erlog_db_local_prove.erl:504-519`): wrap `W0` with
`assert_hooks = #{}` and prove `{assertz, T}` as before. This restores
byte-identical genesis output, keeps the `{genesis_failed, {assert, …}}`
error shape, and still satisfies "founding never runs constructors". The
alternative is `erlog_int:term_instance(T, 0)` before `assertz_clause`, which
reproduces `initial_goal`'s numbering for parsed source but is a second
numbering site. The golden test is the arbiter; do not update its anchor.

### F2 — Deployment-gated: derived terrain/sky membership over existing data

**Where:** frozen `priv/ontologies/voxel_world.pl:10` and
`priv/ontologies/lobby_worlds.pl:78`, with the removed assertions in
`lobby_worlds.pl:90-96` and `voxel_world.pl:44-48`.

**What it does:** `instance_of(voxel_world, W) :- voxel_world_owner(W, _)` and
`instance_of(sky_sphere, world_sky(W)) :- lobby_terrain_world(W)` replace the
bare membership assertions. For the current creation route this is
equivalent: `gui_question_policy(world_creation, Human, _)` requires
`lobby_owner(Human)` (`lobby_worlds.pl:50-51`), so every created world is a
`lobby_terrain_world` and gets its sky.

**Two consequences to decide explicitly:**
1. Any ontology whose committed history already holds stored
   `instance_of(voxel_world, W)` facts (live lobbies founded before this
   change) now yields each world twice through `instance_of(voxel_world, W)`.
   `world_library_count/1` (`lobby_worlds.pl:105`) counts
   `lobby_terrain_world/1` solutions, so the allowance check double-counts and
   can refuse creation early. This is a semantic break on live data, not a
   format break; it needs the deployment authority AGENTS.md requires, or a
   one-time source edit retracting the stored facts. Evidence: code reading.
2. Sky membership is now coupled to `lobby_owner/1`, while the sky's
   `attribute(world_sky(W), …)` facts are still asserted unconditionally.
   Retracting or changing the lobby owner later silently removes the sky
   and its derived atmosphere GUI (`lobby_atmosphere.pl:4-11`) but leaves the
   attributes. Previously membership was a stored fact independent of
   ownership. If the intent is "sky exists for every terrain world", derive
   it from `instance_of(voxel_world, W)` or `voxel_world_owner/2`, not from
   the lobby-owner projection. Stage-3 terrain integration owns the final
   scheme; the ticket only asks S1.5 not to run constructors here.

### F3 — Observation: the creation guard is not an authorization boundary on `instance_of/2` writes

**Where:** frozen `priv/ontologies/construction.pl:6-23` and
`src/predicates/quod_common_primitives.erl:124-134`.

Three spellings reach the hook. Only the unbound-identity branch runs
`operation_authorized/2` and constructors. The ground branch adds a
classification to an existing identity with no guard and no constructors.
The explicit-clause branch inserts directly. Both unguarded branches are
reachable by any principal whose `can_invoke/4` admits assert goals, and the
raw clause form `assertz((instance_of(C, <<"chosen">>) :- true))` creates a
caller-chosen identity with no checks.

This matches the written contract (`doc/proofs.md` "Membership source and
recovery": authorized source rewrites are outside the operation contract and
do not promise constructor validity) and the plan's "let it break" ruling. It
is not a defect. It does mean the S1.3 creation guard protects construction,
not membership writes; production ontologies must keep raw `assertz` goals
out of ordinary `can_invoke` grants for U/A, as they do today. No change
proposed; stating it so nobody reads the hook as an ACL.

### F4 — Low: bare failures without a reason in the hook rule

**Where:** frozen `priv/ontologies/construction.pl:6-19` and
`src/predicates/quod_common_primitives.erl:139-153`.

- Unbound `Class`: `term_variables(Class, [])` fails plainly.
- Nonground compound `Instance` (for example `world_sky(W)` with `W` unbound):
  the ground branch's `term_variables(Instance, [])` fails plainly.
- Missing proof identity (verdict re-proofs, bare engines):
  `'$quod_instance_id'/1` fails plainly, so a creation that passed
  authorization fails with only diagnostic boundaries.

`doc/proofs.md` classifies these as contract errors (`instantiation_error`)
or reasoned failures; `'$quod_draw'/3` documents the same plain failure for
missing proof identity, so this follows precedent. Optional: raise
`instantiation_error` for the first two and `fail_with_reason` for the third.

### F5 — Low cleanup: writable-overlay check by hook presence

**Where:** frozen `src/predicates/quod_common_primitives.erl:141-143`.

`instance_id_1` tests `maps:is_key({instance_of, 2}, Hooks)` as a proxy for
"not a strict read-only overlay". The overlay owner already holds that truth
(`#lp.read_only`, `enter_read_only/1`). The proxy only matters for a direct
user call of `'$quod_instance_id'/1`, which allocates nothing persistent. Use
the owner's state or drop the check.

### F6 — Optional coverage

The new test module covers the acceptance checks well, including
exception-state resumption and no-generation on restart. Not covered:

- A completed construction inside `transaction/1` followed by later
  backtracking inside the same transaction (verifies the checkpoint depth is
  decremented, not cleared, by the construction's `commit_1`; erlog's
  `leave_choicepoint_checkpoints` at `erlog_int.erl:192-194` decrements, so I
  expect this to pass).
- `asserta` spelling placing the membership clause first and the attribute
  writes after it, read back in order.
- Reclassifying a derived-only identity (for example a `voxel_world` known
  only through `voxel_world_owner/2`).
- Creation inside a remote (not co-hosted) foreign scope; the outcome test
  exercises the co-hosted foreign lane only.
- `quod_ct:diff_for/1` now routes through `terms_to_diff`; after F1 is
  settled, one assertion that a fixture fact compiled by founding equals the
  same fact asserted live would pin the single canonical form.

## Lifecycle distinction versus source-authoring contracts

The distinction holds against the actual source owners:

- The guarded editor emits `assertz((Head :- Body))` for every clause and
  normalizes facts to `(Head :- true)` (`quod_prolog.pl:206-234`), so
  replacement and reordering of surviving memberships take the clause branch
  and never construct. The new `membership_source_reorder_and_replacement_never_construct_test`
  covers this path.
- `'$quod_retract_exact'` and `'$quod_predicate_source'` compare up to
  variable renaming, so the round-trip check is unaffected by the hook.
- The membership clause written by construction is stored exactly as a plain
  fact: `assertz_clause(H, Db)` is `assertz_clause(H, true, Db)`, so the diff
  op and the printed source are identical to any other fact.
- Common loading compiles directly into the base engine; founding compiles
  directly into the overlay (subject to F1); commit apply and projection
  rebuild use `quod_diff:apply_op` without hooks. The outcome test traces
  zero allocator and draw calls across owner restart.
- Rules with variables remain rules (`instance_of(car, X)` stays a clause).

## Backtracking and savepoints

The construction savepoint is the same `quod_proof_savepoint:run/4` used by
action candidates, with the caller's write intent inherited. Failure,
caught error and failed alternatives roll back facts, events, effects,
bindings and build-plan inputs together; a successful construction releases
its boundary and later ordinary backtracking retains the staged material.
This is exactly the §5 pin-3 ruling and the action precedent; `doc/proofs.md`
now states it for construction and points callers to an enclosing
`transaction/1` or action. No change to proof semantics is proposed. Nested
savepoints compose: `take_sentinel` consumes only the matching reference and
the erlog checkpoint depth is decremented rather than reset.

## Regression log classification (not triage)

| Failure | Observed | Classification |
| --- | --- | --- |
| 11 `quod_voxel_world_tests`, 12 `quod_lifecycle_single_path_tests` | `creation_requires_output_variable` on bare ground `assertz(instance_of(...))` | Intended refusal; fixture migration to the clause form, already present in the working tree outside the manifest |
| 13 `prepared_genesis_native_format_golden_test` | Anchor changed | Production canonical change, F1 |
| 1-10 GUI components, questions, examples, lobby | `await_commit` function_clause or badmatch on a non-committed result | Signed goals containing bare `assertz(instance_of(Class, ChosenId))` no longer commit; the working-tree diffs of those files migrate exactly these sites. Not confirmed per test |

## Preserved decisions

S1.1 to S1.4 code and evidence are untouched by the frozen diff except the
S1.3 fixture rename of its construction probe and the `current_principal`
registration consolidation into `quod_runtime_predicates`, which is loaded
for every ontology (`quod_predicates.erl:111-115`); the module-order test now
also covers the empty module list. Plan edits are status lines only. No
second executor, reaction constructor or final-state validator was added.
Domain policy, collision refusal and dispatch stay in Prolog; the Erlang hook
only enters the savepoint and allocates the ULID.

## Addendum after the parent's post-freeze report

The parent reported two things while this review was being written, and I
checked the current working tree read-only:

- **F1 is addressed.** `terms_to_diff` now applies
  `erlog_int:term_instance(Term, 0)` before `assertz_clause/2`
  (`src/quod_prolog.erl:7603-7606`). For parsed source this reproduces
  `initial_goal`'s numbering: named variables in order of first appearance,
  `{'_'}` fresh; parsed terms carry no integer variables, which is the only
  case where the two walkers differ. The parent reports the original golden
  anchor now passes unchanged, which is the arbiter I asked for. I did not run
  it.
- **Remaining cleanup from F1:** `quod_ontology:compile_initial_terms/1`
  (`quod_ontology.erl:866-873`) still catches
  `{genesis_failed, {assert, Term, _}}`, which `terms_to_diff` no longer
  throws. That clause is dead; the generic branch now handles erlog throws.
  Optional, same scope.
- **Regression classification confirmed by the parent:** 12 fixture failures
  were bare chosen-ID membership assertions, migrated to
  `quod_ct:source_assertion/1`; the 13th was F1. The parent reports
  regression-03 (125 tests) and regression-04 (779 tests) exit 0 with xref
  clean over a 27-file manifest `/tmp/quod-s1.5-regression-03-tree.json`
  that adds the six test files missing from the frozen one. Not verified here.

F2 (derived terrain/sky membership over existing committed data and the
`lobby_owner` coupling), F3, F4, F5 and F6 are unchanged by the post-freeze
edits and still stand as written.

## Parent disposition (S1.5 implementation session)

F1 and F2 are addressed. Founding uses the existing `term_instance/2` before
clause insertion; the original genesis golden passes unchanged. The dead
`genesis_failed` catch is removed. Terrain/sky memberships remain the existing
stored facts, emitted as explicit clauses by the existing governed actions.
Both new derived rules are removed, so there is no duplicate membership or
lobby-owner coupling, no representation migration and no deployment performed.

F3 remains the confirmed source-authority contract. F4's optional diagnostic
changes are not required for correctness and retain the existing semidet/proof
failure conventions. F5's check is retained: strict read-only entry owns removal
of construction hooks, and the capability check prevents direct ID allocation
in read-only preflight without adding a new overlay API or mutable flag.

F6 coverage now includes transaction-internal backtracking after completed
construction, asserta order, derived-only classification and founded/live clause
compilation equivalence. Non-co-hosted network CT remains unrun. Final sequential
gates passed 907 tests (94 + 813), production xref and `git diff --check`.
All 28 source/test/contract hashes match the passing snapshot. The complete
parent evidence is in
[the verification report](/tmp/quod-s1.5-verification.md).

Evidence clarification: the review used read-only shell inspection and hash
checks, but ran no builds/tests. The pre-freeze production delta was +95/−34;
the +3 lines for variable normalization made it +98/−34 before review fixes.
After these corrections the actual production delta is +96/−36, net +60.
The original review is preserved at `/tmp/quod-s1.5-claude-review-original.md`.
