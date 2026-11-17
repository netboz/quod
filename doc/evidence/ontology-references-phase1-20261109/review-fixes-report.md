# Phase 1 review corrections

Yan authorized these repairs after the [Claude Opus review](opus-review.md). The review was read-only; the corrections below were independently checked and reproduced before repair. Work remains in `worktree/pearl-stone` at version 0.7.282. Phase 2 is untouched. No commit, version bump, deployment, refound or live edit has occurred.

## Corrections and verification

- Ordinary signed reads retain each exact namespace, anchor and pinned height, including failed alternatives, without fetching per-predicate versions. The existing committed read mode still gathers precise reads for runtime invalidation. The signed scope test traces `quod_scope_session:read_set/1` and requires zero calls across initial and unchanged repeated ordinary reads. The remote CT case checks both ordinary read results and actual precise remote selector reads. Existing runtime and client tests retain real-update and unchanged-I/O checks.
- The existing worker teardown clears its pending reply. Node identity withdrawal retires actors while retaining a live worker's reply until their DOWN notifications complete it. The regression holds an actual hosted actor during retirement, withdraws the identity and verifies the resource worker completes normally without its timeout.
- The class owner's key-preparation action again checks the current assignment. A broad storing ACL cannot make that action publish a candidate for a stale epoch or wrong host. Native custody still checks the storing ACL locally, as decided. Current-assignment preparation remains successful.
- The missing-space refusal test verifies absent membership and unchanged state with no allocated world. It then repeats under enabled physics and proves that restoring membership permits the identical placement action, preventing an unrelated refusal from satisfying the test.
- The multiwrite wire paragraph describes v16, the read-mode field and read-set exchange, and rejection of v15 and older.

## Real gates

Clean server campaign 04 ran sequentially, followed by the clean client build and journeys. Full child exits, command lines and timestamps remain in [results.jsonl](results.jsonl).

| Gate | Child exit | Full log |
| --- | ---: | --- |
| gates-04-clean-default | 0 | [gates-04-clean-default.log](gates-04-clean-default.log) |
| gates-04-clean-test | 0 | [gates-04-clean-test.log](gates-04-clean-test.log) |
| gates-04-eunit | 1 | [gates-04-eunit.log](gates-04-eunit.log) |
| gates-04-ct | 0 | [gates-04-ct.log](gates-04-ct.log) |
| gates-04-xref | 0 | [gates-04-xref.log](gates-04-xref.log) |
| gates-04-dialyzer | 0 | [gates-04-dialyzer.log](gates-04-dialyzer.log) |
| client-final-04-javascript | 0 | [client-final-04-javascript.log](client-final-04-javascript.log) |
| client-final-04-core-clean | 0 | [client-final-04-core-clean.log](client-final-04-core-clean.log) |
| client-final-04-godot-clean | 0 | [client-final-04-godot-clean.log](client-final-04-godot-clean.log) |
| client-final-04-core | 0 | [client-final-04-core.log](client-final-04-core.log) |
| client-final-04-godot-build | 0 | [client-final-04-godot-build.log](client-final-04-godot-build.log) |
| client-final-04-package-content | 0 | [client-final-04-package-content.log](client-final-04-package-content.log) |
| client-final-04-godot-icons | 0 | [client-final-04-godot-icons.log](client-final-04-godot-icons.log) |
| client-final-04-gui | 0 | [client-final-04-gui.log](client-final-04-gui.log) |
| client-final-04-spaces | 0 | [client-final-04-spaces.log](client-final-04-spaces.log) |
| client-final-04-navigation | 0 | [client-final-04-navigation.log](client-final-04-navigation.log) |
| client-final-04-local-backup | 0 | [client-final-04-local-backup.log](client-final-04-local-backup.log) |

EUnit ran 4,351 tests with one failure: the browser lifecycle driver explicitly excluded by Yan still calls the obsolete local setup query. Its output is `GoalFailure: The query returned no answer.`, at `client/test/godot-m1a.acceptance.mjs:53:16`. [Full failure output](gates-04-eunit-failures.txt). This is not a clean EUnit result. CT passed all 150 tests; xref and Dialyzer passed. JavaScript passed 295 tests and core passed 358 checks. Exported GUI/controller, spaces, navigation and backup journeys passed; the package excludes its own output directory.

All 1,517 input hashes remained unchanged from the clean server start through the final client run: [before](review-gates-04-inputs-before.json), [after](review-gates-04-inputs-after.json), [candidate patch](review-gates-04-candidate.patch), [built artifact hashes](review-fixes-built-artifacts.json).

## Retained failed attempts

- [Regression baseline](review-regressions-before-01.log): exit 1, 46 tests, three failures. The ordinary read carried unwanted predicate details; the broad ACL allowed a stale candidate; identity withdrawal caused `retirement_reply_lost_on_withdrawal`.
- [Focused after 01](review-regressions-after-01.log): exit 1, 77 tests, two new-test errors: incorrect internal diff expectation and a positive physics control whose fixture was still disabled.
- [Focused after 02](review-regressions-after-02.log): exit 1, 77 tests, one test assertion expected the wrapper removed by its `brief` helper; actual placement committed.
- [Focused after 03](review-regressions-after-03.log): exit 0, 78 tests. Repeated ordinary reads were then added to the same trace assertion and exercised by the full suite.
- [Remote read 01](review-remote-read-01.log): exit 1 before the test; sandbox denied the peer listener (`Protocol 'inet_tcp': register/listen error: eperm`). [Peer output](review-remote-read-01-peer-boot.html). [Remote read 02](review-remote-read-02.log) ran with local peer access and passed, exit 0.
- [Initial measurement](review-measurement-01.txt): exit 1 because an unused text decoding step encountered a binary asset. Removing that step allowed git's binary-safe line measurement; no production file changed for it.

## Measured production delta

Review corrections: **+12 / −7 = +5 lines** across four production files. Phase 1: **+2,725 / −2,361 = +364 lines**. Cumulative since HEAD, including Phase 0: **+2,875 / −2,543 = +332 lines**. [Per-file measurement](review-fixes-production-delta.json). Scope remains src, priv, production Godot C# and the export preset. Tests, docs and evidence are excluded. Growth is the existing read-mode selection and restored assignment prerequisite; no new process, registry, production path or limit.

## Every changed documentation sentence

[Documentation review 03](documentation-review-03.md) and [its exact patch](documentation-review-03.patch) contain every changed normative sentence and context across all ten documents since the Phase 1 baseline. The nine prior document changes remain identical. [The review-correction-only patch](review-fixes-documentation.patch) contains every change in this correction pass: only the wire paragraph in `doc/multiwrite-architecture.md`.

The [plan](../../../nimbalyst-local/plans/accounts-by-reference.md) retains its final rulings, prior failures and phase stop. Its review-correction checklist item and validation note record this work. The complete EUnit gate remains failed, so Phase 1's parent box remains unchecked.

[Cold coordinated release preparation](cold-release-preparation.md) remains prepared, not executed. Work stops at the Phase 1 boundary for Yan's go.
