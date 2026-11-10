# Phase 1 shared engine implementation and presentation stop

This is an intermediate report, not the Phase 1 completion gate. The tree is
`worktree/pearl-stone`, based on 0.7.282. Nothing has been committed, bumped,
deployed, refounded or edited live.

## Implemented

The corrected `isa/2` traversal preserves the class owner from a qualified
starting class. Class requirements and check-based grants execute at their
declaring class owner. Equal callback names at different owners retain distinct
identities; per-instance checks remain local.

The assertion hook's original class and inputs now remain in the existing
transaction overlay revision. Its checkpoint restores this context with the
membership and slots; re-entry retains it. The public guard requires the
membership still to exist and checks the new instance against committed class
policy without staged instance overrides. Changing slots or opening another
input wrapper cannot replace the original inputs.

The existing transaction selection now carries read-write, staged read-only or
committed-read mode in its fifth field, replacing the earlier intermediate
boolean. No compatibility format is retained. Scope wire version remains 15
within this uncommitted change. Foreign preflight reads staged declarations;
foreign guard reads use committed policy. Both reject mutations.

Class initialization follows parents, parent order and slot declarations at the
owner. Type checks and selected computed defaults run there. Slots remain in
the storing ontology. Constructor bodies refuse during preflight; body execution,
part input handling and the part-input helper are removed. Caller-authored
assertions create parts under the existing transaction/action savepoints.

The first Phase 1 implementation checkbox is ticked. Domain owner moves and
normative documentation remain incomplete. In particular, the old space body
and its callers have not yet been migrated; the current tree is not release-ready.

## Verification

Full commands, timestamps, true child exits and absolute logs are in
[results.jsonl](results.jsonl). Earlier failed runs and stop reports are retained.

- [guard-inheritance-02.log](guard-inheritance-02.log): exit 0, 83 tests.
- [guard-callbacks-01.log](guard-callbacks-01.log): exit 0, 83 tests.
- [creation-context-01.log](creation-context-01.log): exit 0, 94 tests.
- [foreign-read-only-01.log](foreign-read-only-01.log): exit 0, 172 tests.
- [declaration-init-01.log](declaration-init-01.log): exit 1, 61 tests,
  nine failures in the rewritten invalid-order fixture. Its assertion expected
  an empty diff although fixture setup had staged the invalid declaration:

  ```text
  expected: []
  got: [{retract,{{constructor_order,amphibious,[car,boat]},{[],false}}}]
  61 tests, 9 failures
  ```

  The correction compares the preflight exit diff with its entry diff, proving
  that refusal adds no writes while retaining the fixture's prior changes.
  The failure was reported before the explicitly labelled rerun.
- [declaration-init-02.log](declaration-init-02.log): exit 0, 61 tests.
- [qualified-init-01.log](qualified-init-01.log): exit 0, 62 tests.
- [assertion-init-01.log](assertion-init-01.log): exit 0, 100 tests.

Signed cases exercise distinct class and storing ontologies, inherited defaults,
owner-only validators and providers, storing-ontology spoof predicates, original
creation inputs through re-entry, staged ACL denial remaining invisible until
commit, malformed owner order, foreign body refusal, foreign mutation refusal
and repeated unchanged preflight reads without storage I/O.

Obsolete constructor-body success tests now exercise the corresponding valid
obligations through declarations or caller-authored goals: topological ordering,
explicit independent parts, scope input restoration, failures/errors restoring
membership, slots, events, effects and bindings, and alternative/action/transaction
rollback. Body refusal has explicit coverage. No obsolete executor is retained.

No full clean Phase 1 EUnit, CT, Dialyzer, xref or client campaign has run.
Those gates have no Phase 1 exit codes yet. Focused EUnit passes are not reported
as full gates. `git diff --check` exits 0. The later production edits after the
last focused run only synchronize module documentation.

## Presentation gap requiring Yan's direction

The plan requires moving the space `entity_scene/3` rule out of the shared
file into `quod:space`, with only facts, ACL and the specified reaction/hosting
clauses in the user's ontology. The current ordinary reader does not select the
class owner for this relation:

1. `common_predicates.pl`, `client_eidolon/3`, selects an anchored recipe using
   `entity_eidolons/4` and class inheritance.
2. For playing/edition it calls local
   `entity_scene(Entity, Purpose, appearance(_, _, Context, Layout, _))` before
   invoking that recipe. `Entity` is the storing ontology's unqualified ID.
3. Generic following in `quod_erlog_db_local_prove:add_followers/3` follows
   structured qualified arguments. It does not resolve an instance's class to
   select an owner for a local ID.
4. `client_eidolon_scene/6` also directly invokes the currently shared
   `space_exposure_projection/4`. The ordinary contents projection's
   `space_scene_parts/8` reads each source's local `entity_scene/3` as well.

After the planned move, these callers would lose the space appearance rule.
The existing class-selected recipe path must carry enough ownership and exact
subject context to obtain class-owned scene behavior while reading slots from
the storing ontology. The class owner and recipe owner cannot simply be assumed
identical: the repository explicitly permits a separate recipe ontology.

No owner-move or presentation-dispatch code has been written. This finding is
source inspection, not a claimed failing runtime reproduction. Yan's instruction
requires stopping before introducing a missing shared behavior. The proposed
scope is a refactoring of the existing class-selected presentation callers and
their owner context, preserving authored instance scene rows and selected recipe
identity. It must not add a second renderer, a space-specific client reference,
a pasted forwarding clause, or a separate registry/process.

## Measured production delta

[shared-engine-delta.json](shared-engine-delta.json) records per-file physical
lines against a reconstructed pre-Phase-1 tree using the saved `before.patch`:
**+227 / -110, net +117** for Phase 1 so far. Cumulative uncommitted production
delta against HEAD is **+385 / -300, net +85**. Tests, documentation, plan and
evidence are excluded. This intermediate growth implements shared scope modes,
transaction-lifetime construction context and owner-qualified initialization;
the planned domain moves and obsolete-rule removals are still outstanding.

## Documentation changes since the previous stop

No normative Markdown specification sentence has changed in Phase 1. The plan
has its first Phase 1 implementation checkbox, timestamp/progress and the
implementation status paragraph updated; this report and the pending-blocker
note are evidence/status text. The previous inheritance stop report remains
unchanged as historical evidence.

New or replaced module documentation sentences, in addition to those already
listed in [guard-stage.md](guard-stage.md):

- “Retain the assertion hook's original class and inputs in this transaction revision.”
- “`'$quod_committed_check'(+Goal)` — a boolean read-only policy check over pinned committed views, including foreign class owners.”
- “Reads remain in the proof's dependencies even on denial; it never exports bindings or consults staged policy.”
- “The shared Prolog operation guard binds the authenticated actor before calling it.”
- “Custody and verdict re-proofs remain strictly local.”
- “`'$quod_construction'(+Id, -Class, -Inputs)` observes the original assertion context in the current transaction revision, including after scope re-entry.”
- “The operation guard checks that class's committed policy for work on its new identity.”
- The context-kind enumeration now includes “`operation_guard` (committed read-only policy with following and proof-bound or committed-snapshot queries)”.

The old committed-check description said it was strictly local and reused
custody's evaluator. The old construction description limited the context to
an active assertion scope. Comments beside the changed implementations and
fixtures now describe their present invariants.

Read-only searches additionally returned `No such file or directory (os error 2)`
for `priv/ontologies/physics*.pl` and `priv/ontologies/gui_operations.pl`.
These are search errors, not test or gate results. The actual physical owner
is `priv/ontologies/quod_physics.pl`.
