# Narrow final recipe validation

The COMPLETE review-04 production/recipe report plus harness assessment is saved
in fable-review.md with its full receipt. Production and frozen04/clean05 remain
byte-identical; no further production review is requested. Read AGENTS.md and
inspect only the recipe delta and harness corrections below. Read-only, no
commands/tests/builds/edits/memory/delegation. Return one complete concise report
for this scope, including unresolved findings and evidence limitations.

The original reviewed `_build/terrain-presentation-20261017/deployment-274`
remains unchanged and unexecuted. The corrected recipe is the separate
`_build/terrain-presentation-20261017/deployment-274-rolling`, listed in
rolling-scripts.json; rolling-recipe.patch compares it to the original.

- Replace stop/start with one ordinary rolling image update from v95/index869134
  to v96. Existing MaxParallel1, health checks, volume sources, task counts,
  origin, identity, provider and catalogue remain. Removed maintenance code.
  Client view attaches the local physics owner via quod_reg at
  src/quod_client_view.erl:458-480, so the changed terrain wire is local to the
  web endpoint and its colocated physics process. Peer protocols and durable
  formats are unchanged. Reload remains necessary for existing old browser code.
- A read-only Nomad plan confirmed one initial DestructiveUpdate (MaxParallel1)
  and no cloud-group update. The first probe expected8 and its assertion failed;
  the saved plan shows1, no warnings, no placement failure, same modify index.
  This is a plan, not a submission. The mutation guard now requires precisely1;
  final fleet acceptance still requires all8 allocations on274, job version96.
- The owner goal now reads the new palette explicitly from the pinned lobby
  vocabulary, independent of same-transaction visibility of the private clause
  replacement. Same exact old-default guards and one atomic transaction remain.
- Shared execution checks the live material_eidolons prerequisite before any
  write; verify reads the palette and compares all three edited predicates with
  the exact after-source through existing canonical source primitives. Only
  then does it emit verified:true. The own-account harness refuses to run until
  that verified result exists, enforcing shared-before-owner order.
- The owner harness adds signed post-state assertions for Highland's textured
  material1, world sky instance, personal sky brightness1000, the derived member
  rule, and exactly one sky mark in Distant Heights. The ordinary retract of our
  fixture's direct member remains in the same transaction. Terrain definitions
  must remain identical and the journal must have no pending operation.
- The deployed walk harness requires an explicit world, refuses any local bundle
  override, records URL/world/creation and previewTree:null, requires nonempty
  content, rejects console/socket/unavailable errors and pose gaps >=2000ms.
  Its other assertions remain: >8m excursion, >=4 interests/content messages,
  >100 rendered frames, zero fully hidden terrain frames, one sky, ready textures.

Parent independent assessment of two remaining observations:

- Distant Heights actually is textured: appearance-fixture-05/result.json reports
  its committed appearance change, and appearance-preview-01/failure.png shows the
  grass/sky after its old-wire timeout. The reported default-world premise was
  stale, but explicit world selection removes any ambiguity regardless. Final
  acceptance will use a newly created world through the normal signed GUI.
- Plain guarded assertz of the derived membership has the same current clause
  representation as the compiler's assertz of that clause. The source primitive
  canonicalizes independent clause variables. It appends one rule while preserving
  the user's existing predicate prefix. No second source owner or compatibility
  branch is introduced. The post-state clause check verifies its semantics.

All recipes are still unexecuted, the image is not built, and clean05 is still
running. Do not report a deployment or acceptance pass. The separate version
label and final twelve-gate pass remain hard build prerequisites.
