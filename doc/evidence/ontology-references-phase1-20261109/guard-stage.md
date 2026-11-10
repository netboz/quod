# Phase 1 guard work and inheritance stop

Work remains on `worktree/pearl-stone`, 0.7.282, without a commit, version bump,
deployment, refound or live edit. This is an intermediate correctness stop,
not the Phase 1 completion boundary. All Phase 1 checklist items remain open.

Yan approved the scope in [guard-frame-blocker.md](guard-frame-blocker.md) through
the interactive choice **Refactor existing scope owners** on 2026-11-09.
The initial blocker report is retained as the record of that earlier stop.

## Implemented engine portion

The operation guard now retains the existing proof/session authority and read
set while selecting the pinned committed view. Its overlay retains staged
domain work, which remains invisible to guard reads. Publication and re-entry
preserve each receiving frame's restrictions. Custody still uses the strict
local authorization evaluator.

The existing transaction selection carries a committed-read boolean through
local and remote invocations. Scope wire version 15 rejects prior versions;
there is no compatibility route. Governed guard queries admit proof-bound and
committed-snapshot dependencies and refuse live observations and staging.
The two `no_follow` declarations on class ACL data are removed.

Signed tests cover foreign class defaults, staged foreign ACL changes remaining
invisible, re-entry through the class owner to committed storing-ontology facts,
preservation of staged domain work in both ontologies, foreign mutation/live-query
refusal, and repeated unchanged reads without storage I/O. Existing overlay,
savepoint, scope-wire, router and scope-target tests are included in the focused
run. Network execution still needs the applicable CT coverage at the phase gate.

## Retained runs

All commands, times, child exits and absolute log paths are in
[results.jsonl](results.jsonl). The runner refuses to overwrite any log.

- [guard-compile-01.log](guard-compile-01.log): exit 0.
- [guard-focused-01.log](guard-focused-01.log): exit 1, 79 tests, one failure.
  `committed_read/1` raised `function_clause` for an existing test's plain
  committed state. That state has no active guard; the query now returns false
  for it, consistently with the existing write-intent accessor. No assertion
  was removed.
- [guard-focused-02.log](guard-focused-02.log): exit 1, 79 tests, one failure.
  The newly added negative test tried `catch/3`, which is not installed in this
  runtime. Its failure stack ended in `nonvar(unbound)` before the guarded
  operation. The test now checks the signed endpoint's error and verifies that
  the foreign mutation did not commit.
- [guard-focused-03.log](guard-focused-03.log): exit 0, 127 tests, zero failures.
- [guard-inheritance-01.log](guard-inheritance-01.log): exit 1, 17 tests, one
  failure. This later test addition exposes the open blocker below. The current
  tree therefore does not have a passing focused suite.

No full clean EUnit, CT, Dialyzer, xref or client campaign has run for Phase 1.
Phase 0 results remain historical evidence, not validation of these engine edits.

## Code/plan mismatch: qualified ancestry

The plan's §2.1 assumes `isa/2` already follows a qualified class to its owner
while preserving the ancestry's identity. The existing implementation handles
an owner-qualified parent reached from a local class through
`'$quod_isa_path'/3`, but a directly qualified starting class reaches the generic
argument follower. That follower strips the input owner and returns unqualified
parent names. Class ACL lookup then searches the storing ontology for those
parent names instead of their class owner.

The signed test uses `guard-owner:letter`, whose class owner declares
`isa(letter, document)` and `class_permission(document, edit, allow)`.
The storing ontology contains only its instance and invocation ACL. A direct
`guard-owner:document` instance is admitted; the inherited case fails:

```text
quod_class_permissions_tests:signed_foreign_guard/0
expected: {ok, [#{}], _}
got: {fail, [... operation_authorized(instance(inherited), edit(3)) ...]}
17 tests, 1 failures
exit_code: 1
```

Relevant owners are `priv/ontologies/common_predicates.pl` (`isa/2`,
`'$quod_transitive_isa'/2`, `'$quod_isa_path'/3`) and the generic argument
following in `src/quod_erlog_db_local_prove.erl`. The latter deliberately does
not reinterpret output values as class identities.

Proposed correction: make the existing shared class traversal use its current
owner-following and name-qualification logic for a qualified starting class as
well. Keep generic predicate following unchanged. Preserve local denial,
multiple inheritance, cycles, deduplication and most-specific selection; add no
special path in the operation guard. This implements the plan's decided class
identity semantics rather than changing them. Work stopped before writing that
correction under Yan's explicit code/plan-conflict instruction.

## Measured delta and documentation

[guard-stage-delta.json](guard-stage-delta.json) records a physical-line diff
against the saved pre-Phase-1 tree: **+92 / -33, net +59 production lines**.
The cumulative uncommitted production delta against HEAD is **+250 / -223,
net +27**. Tests, plan, reports and evidence are excluded. This temporary growth
implements the approved missing scope restriction; the ontology moves and
superseded-rule removals have not landed yet.

The pre-phase tracked inputs and patch are retained in
[before-inputs.json](before-inputs.json) and [before.patch](before.patch).
The former hashes 44,065 tracked files, including tracked evidence.

No normative Markdown documentation has changed in Phase 1 yet. The plan has
its status/timestamp updates, the guard-frame approval note and the following
new stop note:

> **Phase 1 inheritance blocker:** the approved guard-frame refactor passes its
> 127-test focused run, but a new signed inheritance case fails: direct qualified
> ancestry loses the class owner and misses its parent’s ACL default. The shared
> `isa/2` traversal needs correction before the guard can meet §2.1. Implementation
> is paused before that correction; see the guard-stage report.

New API documentation sentences in production code so far:

- “Use this session's pinned committed view without replacing its staged revision or read set.”
- “Retain the authenticated proof's identity and chain while forbidding live observations and staging.”
- “Evaluate the operation guard on committed views through the existing signed proof scopes.”
- “Evaluate strictly local policy on the committed base and retain its OCC dependencies.”

The previous evaluator sentence was “Evaluate local policy on the pinned
committed base and retain its OCC dependencies.” Comments beside changed code
describe the new invariants. The module-level descriptions and normative docs
still need synchronization as part of the unfinished Phase 1 documentation item.

Read-only searches also encountered nonexistent guessed filenames, each with
`No such file or directory (os error 2)`: `quod_actions.erl`, `quod_action*`,
`quod_erlog_db_local_prove_tests.erl`, `quod_proof_worker.erl`,
`quod_instance_creation_tests.erl`, `test/fixtures/pets.pl`, and
`test/fixtures/animals.pl`. Searches across existing source paths resolved the
needed owners. No such search was a test or a passing gate.
