Phase 0 code is implemented; validation remains blocked. The plan’s three Phase 0 deliverables are checked, but the phase checkbox remains unchecked. Phase 1 and Phase 2 have not started. Use Astra High before Phase 1, after Yan’s go.

Work stayed in `worktree/pearl-stone`, HEAD `7e6809e46ea290a53ffff910a53e0386d75b966f`, version 0.7.282. No commit, version bump, deployment, live edit or refound was performed. Yan clarified eventual refounding without backward compatibility and chose Godot-only Phase 0 scope; the existing browser adapters remain unchanged.

The placement sentence matches the implemented −Z pose. All 36 GUI icon facts declare measured transfer and pixel allowances (100,690 total bytes; 16,384 pixels each). The Godot form and menu decoders share image decoding. Main passes each transfer allowance to Transport.Icon and reuses the existing image header reader to enforce pixels before decode. Cached textures retain verified costs and enforce each appearance’s allowance. The shared menu_icon/2 replaces both forwarders. The old fixed 1 MiB icon allowance is gone.

The second clean campaign ran the gates sequentially on the corrected fixture order. Every command, timestamp, true child exit and full log path is in [results.jsonl](results.jsonl).

- Default and test clean steps: exit 0 each, [default](gates-02-clean-default.log), [test](gates-02-clean-test.log).
- EUnit: exit 1, 4,326 tests / two failures, [gates-02-eunit.log](gates-02-eunit.log).
- CT: exit 0, all 150 tests passed, [gates-02-ct.log](gates-02-ct.log).
- Xref: exit 0, [gates-02-xref.log](gates-02-xref.log).
- Dialyzer: exit 1, 46 warnings across 14 unchanged Erlang source files, [gates-02-dialyzer.log](gates-02-dialyzer.log). Every warning is also retained in [dialyzer-summary.json](dialyzer-summary.json) and [dialyzer-warnings.raw](dialyzer-warnings.raw).
- Clean Godot core: exit 0, 358 checks, [client-core.log](client-core.log).
- Clean Godot build/import: exit 0, no ERROR diagnostics, [client-godot-build.log](client-godot-build.log).
- Actual Godot icon consumer: exit 0, nine checks, [client-godot-icons.log](client-godot-icons.log). Transfer, pixels and digest refusals are checked; three unchanged repeats retain the exact texture with no further HTTP call, smaller cached allowances refuse without fetching, and a changed digest fetches and installs its own texture.
- Existing JavaScript client unit tests: exit 0, 295 tests, [client-unit-baseline.log](client-unit-baseline.log). These do not establish interoperability with the new GUI image shape.
- Native: exit 0, 56 tests, [native.log](native.log), from campaign 01. No native source changed afterward, so it was not rerun.

The unresolved EUnit failures are:

- `quod_evidence_resolver_tests:persisted_cache_replays_at_startup_not_on_later_requests_test`: `?assertEqual(1, calls(T, quod_ledger_store, open_ro_snapshot, 1))`, expected 1 / got 2. The single-case diagnostic, with unchanged test assertions and deadlines, passed with exactly one measured request snapshot call. Its redacted PID/caller trace also observed a separate earlier `quod_foreign_projection:materialize_turn/1` snapshot read. Startup overlap is a hypothesis, not an established cause of the full-suite failure. The full-suite failure remains unresolved. [resolver-probe-02.log](resolver-probe-02.log).
- `quod_lifecycle_single_path_tests:m1a_seven_foundations_test_`: `{https_client_failed,1}` with `Error: expected asset/2`. The stack runs from `marks.js:readImageAsset` through `world.js:readGuiView` / `gui-operation.js:readOperations` to `godot-m1a.acceptance.mjs:offered`. This is the browser image-shape rejection retained under Yan’s Godot-only choice; no assertion or adapter was changed to hide it.

Dialyzer’s 46 warnings include `Expression produces a value of type 'ok' | {'error','frame_unrepresentable'}, but this value is unmatched`, and impossible old `too_large` / `busy` patterns. Counts by unchanged source file: ask_router 9, client_goal 3, client_goal_endpoint 2, client_goal_parser 3, client_goal_router 1, directory_control 2, dtx_phase_index 2, effect_journal 1, feed 3, foreign_log 3, prolog 3, scope_session 1, scope_wire 4, simplex 9. Phase 0 has no diff in src or include. No warning was suppressed or fixed outside this scope; no passing baseline is claimed.

All earlier failed measurements remain retained:

- Initial core fixture: exit 1, `System.FormatException: Expected binary text.` The new menu label was an atom. Corrected to binary; focused and clean core checks pass. [failed](focused-client.log), [focused correction](focused-client-02.log).
- Initial Godot build: exit 1, `CS0104: 'HttpClient' is an ambiguous reference between 'Godot.HttpClient' and 'System.Net.Http.HttpClient'`. The test now uses the explicit alias. [focused-godot-build.log](focused-godot-build.log).
- First focused Erlang run: exit 1, 12 tests / one failure. The required-image check still matched asset/2; it now matches image/2 and still refuses none for a required image. [focused-eunit.log](focused-eunit.log).
- Second focused Godot build: wrapper/compiler exit 0, but editor import emitted `SocketException (13): Permission denied`. That run is diagnostic-bearing evidence, not a clean import. The later clean build/import had loopback access and no ERROR diagnostics. [focused-godot-build-02.log](focused-godot-build-02.log).
- Campaign 01 EUnit: exit 1, 4,326 tests / two failures. One was the same browser case. The other was the component no-I/O assertion: `?assertEqual([], Calls)` observed background `file:write`, `file:sync`, `dets:sync`, outcome mutation and projection application. My new mutation regression had preceded the unchanged-read measurement. I moved it afterward; five focused component tests pass, and campaign 02 no longer has that failure. No I/O assertion was weakened. [eunit.log](eunit.log), [focused-components-03.log](focused-components-03.log).
- First resolver diagnostic: exit 1 before exercising the case because its temporary code-path prefix made OTP resolve Quod’s priv directory under the probe folder (`common_predicates.pl: enoent`). Corrected the harness directory name; the second probe passed without changing production or test sources. [resolver-probe.log](resolver-probe.log).
- The first desktop notification attempt was denied by the sandbox (`Could not connect: Operation not permitted`); the explicit desktop-access retry exited 0.

Production delta against HEAD: 86 additions / 82 removals, net +4 physical lines in four existing Godot production files and four Prolog files. Tests, docs and evidence are excluded. The growth carries authored resource metadata, shared validation and cached-cost admission while removing duplicate decoders and forwarders. No production module, process, registry, execution path or resource cap was added. [production-numstat.txt](production-numstat.txt).

Campaign 02 froze 1,208 server/JavaScript inputs; the clean Godot campaign froze 210 inputs. [final-input-checks.json](final-input-checks.json) confirms neither set changed during its campaign. [final-artifacts.json](final-artifacts.json) identifies 1,195 compiled artifacts, including test beams. The first failed tree and both failed campaigns remain separate: [campaign 01 patch](implementation.patch), [campaign 02 patch](implementation-02.patch), [final patch](final-implementation.patch). New test files and the plan are retained under final-inputs. No feature inventory file was found; no inventory update was made.

Every implementation-document sentence changed:

- In [doc/spaces.md](../../spaces.md), replaced: “A successful `unplaced` result creates an unplaced space; `placed(Destination, Transform)` places it one metre along that frame's X axis from A.”
- With: “A successful `unplaced` result creates an unplaced space; `placed(Destination, Transform)` places it in front of A along that frame's −Z axis: 2 m from A's position plus half the new space's depth, so its near wall opens at arm's reach plus a step (Yan, 2026-11-07); an infinite space uses half-depth zero.”
- No other implementation doc was edited. The [plan](../../../nimbalyst-local/plans/accounts-by-reference.md) records status/start/update/progress and its three delivered checklist items. Its settled rulings are unchanged. These are its added activation/scope sentences:
- “Activation clarification from Yan in this session (2026-11-09): backward compatibility is unnecessary; the ledgers will be refounded.”
- “Implementation therefore proceeds for that eventual activation.”
- “Running a refound, deployment or live edit still requires Yan’s explicit go.”
- “Scope clarification from Yan in this session (2026-11-09): Phase 0 stays focused on Godot; the existing browser adapters remain unchanged.”
- “Their rejection of the new GUI image shape, including the signed HTTPS lifecycle test failure, is retained in the Phase 0 report.”
- Current plan status note: “Phase 0 validation blocked: the full-suite evidence-resolver snapshot-count assertion and 46 Dialyzer warnings remain unresolved; full gate exits and logs are in the Phase 0 report.”
