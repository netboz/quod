# Phase 1 presentation implementation and resource-selection stop

This is an intermediate stop, not Phase 1 completion. The branch remains
`worktree/pearl-stone`, based on 0.7.282. No commit, version bump, deployment,
refound or live edit has run. The earlier stop reports remain historical evidence.

## Approved presentation change

Yan approved the presentation refactoring described in [shared-engine.md](shared-engine.md).
The existing client reader now checks authored instance scene answers first,
then obtains inherited scene answers from the class owners, carrying the exact
storing subject. Each distinct class owner is queried once per selection;
more-specific classes take precedence. Recipe selection retains its separate
anchored owner. The ordinary contents reader uses the same scene reader.

The signed fixture uses distinct storing, class, ancestor-class and recipe
ontologies. It checks inherited selection, storing slots, committed slot changes,
an authored hidden override, class-owner ACL withdrawal and repeated unchanged
reads without storage I/O.

## Verification and retained failures

Full commands, timestamps, true child exits and absolute log paths are in
[results.jsonl](results.jsonl).

- [owner-scene-01.log](owner-scene-01.log): exit 1, four tests, one failure.
- [owner-scene-diagnostic-02.log](owner-scene-diagnostic-02.log): exit 1,
  three tests, one failure. Naming the assertions isolated the ACL withdrawal:

  ```text
  Failure/Error: ?assertMatch({ fail , _ }, RevokedRead)
  expected: = { fail , _ }
  got: {ok, [#{<<"V0">> => {eidolon_scene, ...}}], 10}
  3 tests, 1 failures
  ```

  This excerpt abbreviates the returned scene; the complete output is retained
  in both logs. The fixture's unifying retract removed the injected empty-chain
  host grant instead of the authored broad grant. The correction uses the
  existing exact-retraction predicate to remove the intended clause. The hidden
  override already passed. Both failures were reported before rerunning.
- [owner-scene-03.log](owner-scene-03.log): exit 0, four tests, zero failures.
- [presentation-whitespace-01.log](presentation-whitespace-01.log):
  `git diff --check`, exit 0.

No full clean Phase 1 EUnit, CT, Dialyzer, xref or client gates have run, so
there are no Phase 1 full-gate exit codes. Phase 0's retained browser failure
remains recorded in its report. Focused tests do not replace the clean gates.

## Code/plan conflict before moving the space rules

The plan moves `space_instance/2`, `space_assignment/3`, validators and recipes
to the class owner. Its final decisions retain only the two hosting derivations
locally because resource selection forbids scope calls. Existing physical
resource selection has additional dependencies on those space rules:

1. `src/quod_runtime.erl:select_resource_description/5` selects
   `physics_projection/2` in the local `policy_verdict` context.
   `quod_physics.pl:physics_projection/2` calls `physics_enabled/2`, which
   calls `space_instance(W,physical_space)`. This is the shared eligibility
   check, also used by hosting suspension; class membership alone grants
   no physical resources.
2. `quod_runtime:physics_source_selection/6` evaluates
   `physics_definition_projection/5` against an existing retained verified
   source using `resource_selection`. That projection calls
   `space_assignment/3`; a frame export additionally calls `space_instance/2`,
   `space_transform/1` and class-selected `entity_eidolons/4`.
3. The frame export currently requires its `space_contents` recipe to belong
   to the storing ontology. Moving the recipe to `quod:space` changes that
   identity too; a local identity substitution would not supply the missing
   class and recipe reads.

`doc/runtime-and-agents.md` explicitly forbids scope calls during resource
selection. `src/quod_predicates.erl:allowed_dependency/3` enforces that rule;
the stricter `policy_verdict` context admits no governed queries. The existing
retained source reader supplies one source snapshot, not an ordinary
authenticated proof that can follow its classes to another owner.

Replacing the ordinary callers with foreign calls would therefore make these
resource selectors unable to establish their required checks. Reading the
assignment fact directly could address that one dependency, but does not
resolve class ancestry and recipe selection. Keeping copied space rules,
discarding those checks or permitting scope calls here would contradict the
stated plan or specification; none has been implemented.

This finding is source inspection, not a claimed failing runtime reproduction.
No space-owner move or resource-selector change has been written. Yan's explicit
instruction to stop on a code/plan conflict applies before proceeding.

## Measured production delta

[presentation-delta.json](presentation-delta.json) measures physical production
lines against the pre-Phase-1 tree reconstructed from HEAD and `before.patch`:
Phase 1 so far **+250 / -112, net +138**. Cumulative uncommitted production
changes against HEAD are **+408 / -302, net +106**. Tests, documentation, plan
and evidence are excluded. The latest presentation change adds 23 lines and
removes two relative to the preceding intermediate implementation. The planned
domain moves and obsolete-rule removals remain outstanding.

## Documentation sentences changed in this increment

No normative Markdown specification sentence changed. The following source
comment sentences were added above the presentation reader:

- “Authored instance scenes override inherited class behavior.”
- “Each class owner is read once with the exact storing subject; the selected recipe may belong to another ontology.”
- “Conflicting inherited answers remain visible.”

The test adds: “Revoking class-owner access must not select the ancestor's scene.”
The plan's status text now records the approved presentation implementation,
the focused pass and this resource-selection stop; checklist completion remains
5 of 17 implementation items. No additional implementation item is claimed done.

Read-only searches also reported missing guessed paths
`test/quod_gui_eidolon_tests.erl`, `src/quod_system_ontologies.erl`,
`src/quod_lobby.erl` and `priv/ontologies/acl.pl`. These are search errors,
not test results; subsequent inspection used the existing files.
