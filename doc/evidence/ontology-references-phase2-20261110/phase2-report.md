# Phase 2 boundary report

Phase 2 implements signed icon bytes in `quod:gui`. Work is based on
`4f5057c20f0743180f4c62e43668839a201c1945` in `worktree/pearl-stone`,
at version 0.7.282. No Phase 2 commit, version bump, deployment, refound,
live edit or client installation has been performed.

## Behavior and production seams

- All 36 icons retain their exact 100,690 payload bytes as ordinary `gui_asset/3` facts. The public query admits signed reads; no static icon directory or HTTP icon consumer remains.
- The existing signed session fetches a digest and MIME, verifies SHA-256 and the authored byte allowance. The existing Godot consumer checks pixel allowance before decoding and retains its verified texture by digest.
- The shared structured-text editor displays complete source and binding lines without wrapping. The unchanged source journey now verifies the complete enlarged GUI source, renewal without another cursor, revocation, exact reopening and actual updates. No temporary tracing or test override remains.
- Signed server tests fetch all 36 payloads twice without storage I/O, refuse mutation by the public reader, and refuse a wrong MIME. The existing socket test changes an icon through one transaction and receives the existing refresh notification and changed projection.
- The actual Godot icon consumer test checks byte/pixel/digest refusal, the signed endpoint and request signature, unchanged cache reuse and a changed digest. The full exported journeys run against the real local signed backend.
- The existing operator module has a `terms/3` step. Its test verifies that dry run performs no write, missing root source authority refuses the write, and authorized execution inserts the exact binary. Normal ACL, transaction and material admission remain in force.

## Actual gates

Full commands, timestamps, true child exits and log paths are retained in [results.jsonl](results.jsonl). Server gates started from clean default/test builds and ran sequentially. Client campaign 01 stopped on its retained GUI failure; clean client campaign 02 verifies the correction. The [scope comparison](client-final-02-scope-comparison.json) identifies only the client FormPanel setting changed after the server gates.

| Gate | Child exit | Full log |
| --- | ---: | --- |
| gates-01-clean-default | 0 | [gates-01-clean-default.log](gates-01-clean-default.log) |
| gates-01-clean-test | 0 | [gates-01-clean-test.log](gates-01-clean-test.log) |
| gates-01-eunit | 1 | [gates-01-eunit.log](gates-01-eunit.log) |
| gates-01-ct | 0 | [gates-01-ct.log](gates-01-ct.log) |
| gates-01-xref | 0 | [gates-01-xref.log](gates-01-xref.log) |
| gates-01-dialyzer | 0 | [gates-01-dialyzer.log](gates-01-dialyzer.log) |
| client-final-02-javascript | 0 | [client-final-02-javascript.log](client-final-02-javascript.log) |
| client-final-02-core-clean | 0 | [client-final-02-core-clean.log](client-final-02-core-clean.log) |
| client-final-02-godot-clean | 0 | [client-final-02-godot-clean.log](client-final-02-godot-clean.log) |
| client-final-02-core | 0 | [client-final-02-core.log](client-final-02-core.log) |
| client-final-02-godot-build | 0 | [client-final-02-godot-build.log](client-final-02-godot-build.log) |
| client-final-02-package-content | 0 | [client-final-02-package-content.log](client-final-02-package-content.log) |
| client-final-02-godot-icons | 0 | [client-final-02-godot-icons.log](client-final-02-godot-icons.log) |
| client-final-02-gui | 0 | [client-final-02-gui.log](client-final-02-gui.log) |
| client-final-02-spaces | 0 | [client-final-02-spaces.log](client-final-02-spaces.log) |
| client-final-02-navigation | 0 | [client-final-02-navigation.log](client-final-02-navigation.log) |
| client-final-02-local-backup | 0 | [client-final-02-local-backup.log](client-final-02-local-backup.log) |

EUnit exits 1 with 4,353 tests and one failure: `{https_client_failed,1}` from the excluded browser driver’s old local setup query (`GoalFailure: The query returned no answer.`). The full EUnit gate is not clean. Its complete failure section is retained in [gates-01-eunit-failures.txt](gates-01-eunit-failures.txt). The browser adapters remain outside Yan’s agreed scope; no assertion or gate was skipped or weakened.

CT passes all 150 cases, JavaScript passes 295 tests, and C# core passes 360 checks. The exported navigation repeat records `calls: []` across reader/history/native-install and file write/sync probes in [its work trace](client-final-02-navigation-journey/recursive-scene.png.work.json).

## Failed focused attempts retained

- `focused-core-01`, exit 1: CS0136, a test local named `asset` conflicted with another local. Renamed it; `focused-core-02` passes 360 checks.
- `focused-server-01`, exit 1: missing closing brace in the migrated test query, corrected before running it again.
- `focused-server-02`, exit 1: generated mixed binary escaping was rejected by the file lexer and its stream error terminated parsing. `binary-parser-probe-01` reproduces rejection and accepts the existing all-hex spelling. The facts use that spelling; no parser change was made.
- `focused-server-03` and `04`, exit 1 each: the live-view test searched for the instance pie’s `create_here` icon while opening the class creation menu. It now targets that menu’s `create_finite` icon and uses the canonical value spelling. `focused-server-05` passes all eight tests.
- `focused-godot-build-01`, exit 1: ambiguous `Json` in test code; qualified `Quod.Client.Json`.
- `focused-godot-build-02`, exit 1: after compilation and packaging, the sandbox denied the local TCP listener (`ERR_CANT_CREATE`). The separately labelled run 03 uses the local-network permission and exits 0.
- `focused-godot-icons-01`, exit 0: all actual consumer checks pass.
- Client campaign 01 GUI, source-ui-trace-01 and proxy-stack-02 each exit 1 at the retained watchdog after complete source assembly. No test deadline changed. The actual native editor wrapping at its early layout caused the stall; the controlled wrap-disabled real journey passes with all source obligations intact. [Complete diagnosis](source-editor-diagnosis.md).
- The standalone normal-width and narrow-width control probes all exit 0; they did not reproduce the full layout failure. Proxy-stack-01 exits 1 before its journey on `ModuleNotFoundError: desktop_input`; its corrected wrapper preserves the original watchdog. The captured proxy stacks show no blocked bookkeeping lock. Source-native-stack-01 exits 1 because its target process had already ended. These failed diagnostic setups are retained without being counted as successful verification.
- The read-only status counter exited 1 once with `SyntaxError: unmatched ')'`; its corrected read-only command exited 0. [Record](status-probe-01.txt).

Every failed full log remains beside this report. No failed evidence was overwritten.

## Measured delta and documentation

Production source: **+65 / −9 = +56 lines**. Of those, 40 added lines hold the 36 binary facts and their declarations/comments; the signed client changes add 16 net lines, and the shared editor setting replaces one line without net growth. The **36 removed static PNGs total 100,690 bytes**; the same payload is represented by the facts. The existing operator tooling changes **+13 / −1 = +12 lines**, measured separately against its preserved pre-edit copy. Tests and evidence are excluded. [Per-file measurement](production-delta-final.json), [tooling patch](source-release-tooling.patch).

Every changed normative sentence is listed in [documentation-review.md](documentation-review.md), with its exact [patch](documentation-review.patch). Only [gui-examples.md](../../gui-examples.md) changed. The plan checklist and workflow evidence are maintained separately; final rulings §1 and §8 are unchanged.

All **1083 frozen input hashes** remain unchanged through the final client run. [Final before inputs](client-final-02-inputs-before.json), [after inputs](final-inputs-after.json), [built artifacts](final-built-artifacts.json), [candidate patch](client-final-02-candidate.patch). Server campaign 01 remains frozen by its original manifests and candidate patch; only the documented client setting differs.

[Release preparation](release-preparation.md) is prepared only. Phase 1’s cold coordinated activation remains required. Work stops at the Phase 2 boundary for Yan’s go.
