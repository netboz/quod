# Phase 1 report

Phase 1 implementation and the agreed Godot qualification are complete. The full
EUnit gate remains failed solely on the browser driver excluded by Yan. Phase 2
has not started. Nothing has been committed, version-bumped, deployed, refounded
or live-edited. Work stops at this phase boundary for Yan's go.

Branch: `worktree/pearl-stone`; base `7e6809e46ea290a53ffff910a53e0386d75b966f`,
version 0.7.282. The phase baseline is [before.patch](before.patch).

## Delivered behavior

- Shared classes, slots, forms, recipes and behavior live at their class owners.
  Signup writes the user's ontology as terms: facts, ACL clauses, reactions and
  the existing local hosting derivations.
- Qualified assertion initializes slots through the shared hook. Committed
  operation guards follow class owners, retain precise reads and reject staged
  authorization changes. Constructor bodies and class-built parts are removed.
- Existing scope and runtime owners carry the committed read restriction and
  precise foreign reads. Retained consumers react to relevant changes without
  rebuilding state on unchanged reads.
- Godot retains exact class-owner references and the selected storing ontology
  through menus, forms, execution and drafts. Large exact failure outcomes stay
  selectable and scrollable. The export excludes its own output directory.

## Clean sequential gates

Both server profiles were cleaned before server campaign 03. Client campaign 03
cleaned its projects and rebuilt the export. All child exits are recorded in
[results.jsonl](results.jsonl); logs are complete.

| Gate | Child exit | Full log |
| --- | ---: | --- |
| gates-03-clean-default | 0 | [gates-03-clean-default.log](gates-03-clean-default.log) |
| gates-03-clean-test | 0 | [gates-03-clean-test.log](gates-03-clean-test.log) |
| gates-03-eunit | 1 | [gates-03-eunit.log](gates-03-eunit.log) |
| gates-03-ct | 0 | [gates-03-ct.log](gates-03-ct.log) |
| gates-03-xref | 0 | [gates-03-xref.log](gates-03-xref.log) |
| gates-03-dialyzer | 0 | [gates-03-dialyzer.log](gates-03-dialyzer.log) |
| client-final-03-javascript | 0 | [client-final-03-javascript.log](client-final-03-javascript.log) |
| client-final-03-core-clean | 0 | [client-final-03-core-clean.log](client-final-03-core-clean.log) |
| client-final-03-godot-clean | 0 | [client-final-03-godot-clean.log](client-final-03-godot-clean.log) |
| client-final-03-core | 0 | [client-final-03-core.log](client-final-03-core.log) |
| client-final-03-godot-build | 0 | [client-final-03-godot-build.log](client-final-03-godot-build.log) |
| client-final-03-package-content | 0 | [client-final-03-package-content.log](client-final-03-package-content.log) |
| client-final-03-godot-icons | 0 | [client-final-03-godot-icons.log](client-final-03-godot-icons.log) |
| client-final-03-gui | 0 | [client-final-03-gui.log](client-final-03-gui.log) |
| client-final-03-spaces | 0 | [client-final-03-spaces.log](client-final-03-spaces.log) |
| client-final-03-navigation | 0 | [client-final-03-navigation.log](client-final-03-navigation.log) |
| client-final-03-local-backup | 0 | [client-final-03-local-backup.log](client-final-03-local-backup.log) |

EUnit ran 4,349 tests with one failure. CT passed all 150 tests. JavaScript passed
295 tests; C# core passed 358 checks. Exported GUI/controller, space, navigation
and backup journeys passed, including clean shutdown and actual native input.
The package-content check reports `EXPORT_OUTPUT_DIRECTORY_PRESENT=false`.

The remaining EUnit output is:

```text
quod_lifecycle_single_path_tests: m1a_seven_foundations_test_
{https_client_failed,1}
GoalFailure: The query returned no answer.
client/test/godot-m1a.acceptance.mjs:53:16
4349 tests, 1 failures
```

The unchanged browser driver still calls the former local setup query. It now
fails before reaching the image-shape rejection retained from Phase 0. This is
an excluded compatibility failure, not a clean EUnit result. Its full output is
[gates-03-eunit-failures.txt](gates-03-eunit-failures.txt).

The signed navigation journey repeats unchanged renewals through the real owner:
[work measurements](client-final-03-navigation-journey/recursive-scene.png.work.json)
record no reader/history/native-install or file write/sync work. Controller
renewals reuse their verified resources. Actual changes, revocation, rollback,
wrong anchors, lost replies and recovery are exercised by the same journeys.

## Frozen evidence

Server campaign 03 preserved all 1,512 input hashes. The final client campaign
preserved all 1,515 hashes. After the server run, only the client export exclusion
and test orchestration/evidence changed; server inputs did not change. See
[scope comparison](final-scope-comparison-03.json),
[server inputs](gates-03-inputs-after.json),
[client inputs](client-final-03-inputs-after.json),
[candidate patch](client-final-03-candidate.patch) and
[local built artifact hashes](final-built-artifacts.json).

Earlier failed campaigns remain intact. Server campaign 01 had 51 EUnit failures,
one CT failure and eight Dialyzer warnings. Campaign 02 reduced EUnit to the
excluded browser failure plus a stale source-discovery assertion, with CT, xref
and Dialyzer passing. The corrected assertion verifies public discovery while
still refusing private source views and unauthorized writes; its focused run
and final full suite pass that test.

Client campaign 01 passed its behavior gates, but export inspection found old
local test profiles included from the output directory. Probe 01 was terminated
(child −15; wrapper 241) because the release executable did not run the inspection
script. Pinned-editor probe 02 reproduced the unwanted directory (exit 1).
The export exclusion fixes it without deleting local files. Client campaign 02
passed through GUI, then stopped before the space client launched: its random
network identifier began with a dash, causing `argument --network: expected one
argument` (driver 2, campaign gate 1). The harness now uses `--network=value`.
Campaign 03 is separately labelled and passes every client gate. All preceding
fixture failures and diagnostics remain in the result index and logs.

## Measured production delta

Phase 1: **+2,717 / −2,358 = +359 lines**. Cumulative since HEAD, including Phase 0:
**+2,867 / −2,540 = +327 lines**. The measurement includes `src`, `priv`, production
Godot C# and the export preset; tests, docs and evidence are excluded. Baseline
reconstruction applies `before.patch` to HEAD. Per-file counts are retained in
[final-production-delta.json](final-production-delta.json).

The Prolog consolidation removes 86 net lines. Existing Erlang owners gain 423
net lines to propagate committed-only guards, collect precise reads and retain
source readiness/invalidation correctly; Godot gains 22 net lines. The export
preset changes one line with no net growth. No new production process or
registry is introduced. The measured total is growth, not a claimed reduction.

## Every changed documentation sentence

[Documentation review 02](documentation-review-02.md) contains every removed and
added sentence with context; [the exact patch](documentation-review-02.patch)
is verified against the Phase 1 baseline by
[gates-02-documentation-check.json](gates-02-documentation-check.json). These
nine documents have not changed since that verification:

- [proofs.md](../../proofs.md)
- [runtime-and-agents.md](../../runtime-and-agents.md)
- [spaces.md](../../spaces.md)
- [godot-foundation-contract.md](../../godot-foundation-contract.md)
- [gui-examples.md](../../gui-examples.md)
- [gui-implementation-plan.md](../../gui-implementation-plan.md)
- [player-movement-plan.md](../../player-movement-plan.md)
- [lifecycle-and-routing.md](../../lifecycle-and-routing.md)
- [physics-native.md](../../physics-native.md)

The [plan's checklist and validation notes](../../../nimbalyst-local/plans/accounts-by-reference.md)
track the work separately; [final-plan.md](final-plan.md) preserves this boundary.
The in-scope tests/docs item is checked. The Phase 1 box remains unchecked because
the full EUnit gate is not clean. Newly
written release/evidence documents are retained in full, including this report
and [cold-release-preparation.md](cold-release-preparation.md).

## Cold coordinated release

[The preparation](cold-release-preparation.md) uses the existing source compiler,
one atomic multi-ontology transaction, exact baselines, readback and outcome
resolution. It includes removed definitions and installed dependent callers.
No fleet-specific baseline, signed activation request or successful activation
is claimed. The future patch-only version bump remains separate. Deployment,
refounding and live edits still require Yan's explicit go.
