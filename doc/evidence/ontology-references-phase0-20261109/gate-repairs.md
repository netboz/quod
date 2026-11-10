Phase 0 gate repairs, authorized by Yan's “Repair gate blockers” answer on 2026-11-09. The [initial Phase 0 report](report.md), tree and failures remain unchanged as historical evidence. This scope repairs the resolver measurement and the 46 Dialyzer warnings; browser adapters remain unchanged. No commit, version bump, deployment, live edit or refound is authorized or performed. Phase 1 has not started; switch to Astra High before Phase 1.

The resolver failure is reproduced causally in [repair-schedule-probe.log](repair-schedule-probe.log): exit 1, expected one snapshot read, observed two. A removable scheduling probe holds the old projection worker during setup, then resumes it in the new request's measurement while retaining the original test body, assertions and absolute deadlines. Its redacted trace identifies the two reads:

```
HELD_OLD_PROJECTION pid=<0.127.0> owner=<0.107.0>
RESUMED_OLD_PROJECTION pid=<0.127.0> held_request=<0.137.0>
SNAPSHOT_CALL pid=<0.127.0> caller={quod_foreign_projection,materialize_turn,1}
SNAPSHOT_CALL pid=<0.137.0> caller={quod_foreign_log,with_snapshot_store,3}
ASSERTED_SNAPSHOT_CALLS test=<0.87.0> pids=[<0.127.0>,<0.137.0>]
```

The legacy trace inherited by the old projection survived the old owner's stop. Re-enabling global call patterns for the restarted owner therefore admitted that old worker's later read into the new measurement. The test now uses a private OTP trace session. Ending a measurement disables its processes and inheritance, waits for trace delivery, drains its messages and destroys its session before starting the restarted owner's session. Every startup and request assertion remains unchanged; the restarted owner, its descendants and the new caller remain measured. No production resolver change was needed.

The identical scheduling probe after the test refactoring exits 0, still observes both physical reads and measures only the new request: `ASSERTED_SNAPSHOT_CALLS test=<0.87.0> pids=[<0.137.0>]`. [repair-schedule-probe-02.log](repair-schedule-probe-02.log). The complete resolver module passes 39 tests, exit 0. [repair-resolver-eunit.log](repair-resolver-eunit.log). This is a controlled scheduling reproduction of the measurement defect; the original uninstrumented full-suite failure did not retain PID attribution.

The Dialyzer repair removes unreachable refusal arms left by the already-installed material policy. The owning implementations were read, not just their inferred types: durable goal encoding returns bad_term; the signed request/parser no longer impose the removed payload quotas; foreign-read encoding and decoding return bad_foreign_reads; plan encoding is infallible for an admitted plan; atomic reservation returns invalid_dtx_intent rather than busy; append rejection callers produce bad_change or stale_seq. Actual framing constraints, committed policy enforcement and current refusal paths remain. Lexer token insertion and phase-history staging now return their pure results internally instead of carrying impossible error alternatives. The endpoint's obsolete result_too_large wire error is removed; complete-envelope refusal remains.

Ordered send had a real lifecycle defect: caller-side representability refusal could leave a live link on which successors could pass. The existing link owner now prepares an ordered payload and routes refusal through its existing ordered_send_failed path, which resets the stream, discards queued successors and notifies owners through their link monitors. send_ordered remains nonblocking and now returns ok for queueing; every production caller was checked, and none handled its previous error result. Best-effort send and reliable send retain their explicit representability errors. No transport capacity, deadline or retry policy changes. Directory resync retains its existing best-effort behavior with explicit discarded send results. The protocol-evidence loop uses foreach instead of building an unused list.

The regression uses the real link process and the existing fake QUIC connection boundary. Four GiB of shared iodata cannot fit the existing 32-bit frame and is refused before frame allocation. The link dies with `{ordered_send_failed,frame_unrepresentable}`, its successor never reaches QUIC, and the connection stays alive. This replaces the ordered-send portion of the old synchronous-refusal fixture; best-effort and reliable refusal checks remain. The focused seven-module run passes 149 tests, exit 0. [repair-focused-eunit-02.log](repair-focused-eunit-02.log). Dialyzer exits 0 with no warnings. [repair-dialyzer.log](repair-dialyzer.log).

Failures and non-qualifying diagnostics are retained:

- Initial focused run: exit 1, 149 tests / one failure, `no_credit_wire`. The new generic-channel link requires stream priority 6; the fake connection accepted only catch-up priority 1. The fixture now accepts both documented shapes. No deadline or production check changed. [repair-focused-eunit.log](repair-focused-eunit.log).
- Initial passive resolver-module probe: exit 0, 39 passed, did not reproduce the race. [repair-resolver-probe.log](repair-resolver-probe.log).
- Application-target diagnostic omitted the standalone resolver module. It was explicitly interrupted with SIGTERM rather than running more unrelated tests. The VM's actual exit was 0; this is an interrupted partial run, not a pass. Its output contains `SIGTERM received - shutting down`. [repair-resolver-suite-probe.log](repair-resolver-suite-probe.log).
- Direct-directory diagnostic passed the resolver case, then had harness failures including `{common_predicates_failed,{read_file,"_build/test/lib/quod/priv/ontologies/common_predicates.pl",enoent}}`, `{genesis_failed,{read_file,"test/fixtures/constructors.pl",enoent}}` and cascading `already_started` / `terminating` errors. Its relative code paths did not preserve the normal rebar harness behavior across fixture working-directory changes. It was explicitly interrupted with SIGTERM. Actual VM exit 0 is not a pass; all its output remains. [repair-resolver-directory-probe.log](repair-resolver-directory-probe.log).
- The controlled scheduling reproduction intentionally fails the original assertion with expected 1 / value 2, exit 1; the same schedule passes after measurement isolation. No uninstrumented passing run is used to erase the original failure.

All probe code is evidence-only. The final clean gates use the normal rebar commands with no probe attached. Full commands, timestamps, actual exits and absolute log paths remain in [results.jsonl](results.jsonl). Clean campaign 03 ran sequentially after both profiles were cleaned; its inputs are frozen in [repair-inputs-before.json](repair-inputs-before.json).

Measured production delta against HEAD: 158 additions / 190 removals, net −32 physical lines. The original GUI changes were +86 / −82, net +4; the authorized Erlang gate repairs add 72 / remove 108, net −36. Tests, documentation and evidence are excluded. The reduced wrappers and unreachable cases account for the reduction; formatting is not compressed to manufacture it. [repair-production-numstat.txt](repair-production-numstat.txt).

Implementation documentation changed in this session:

- [doc/spaces.md](../../spaces.md): old sentence “A successful `unplaced` result creates an unplaced space; `placed(Destination, Transform)` places it one metre along that frame's X axis from A.”
- Replacement: “A successful `unplaced` result creates an unplaced space; `placed(Destination, Transform)` places it in front of A along that frame's −Z axis: 2 m from A's position plus half the new space's depth, so its near wall opens at arm's reach plus a step (Yan, 2026-11-07); an infinite space uses half-depth zero.”
- [src/quod_link.erl](../../../src/quod_link.erl) adds this API documentation sentence: “An unrepresentable payload takes the same terminal link-failure path before allocating its frame; the caller observes the failure through its link monitor.”
- No other implementation-document prose changed. Code specs, private helper signatures, tests and evidence changed as described above. No feature inventory file was found; the gate repairs add no separate domain capability.

Clean campaign 03 final results:

- Default clean: exit 0, [gates-03-clean-default.log](gates-03-clean-default.log).
- Test-profile clean: exit 0, [gates-03-clean-test.log](gates-03-clean-test.log).
- EUnit: exit 1, 4,368 tests / one failure, [gates-03-eunit.log](gates-03-eunit.log).
- CT: exit 0, all 150 tests passed, [gates-03-ct.log](gates-03-ct.log).
- Xref: exit 0, [gates-03-xref.log](gates-03-xref.log).
- Dialyzer: exit 0, no warnings, [gates-03-dialyzer.log](gates-03-dialyzer.log).
- Overall campaign runner: exit 1, `CAMPAIGN_03_RESULT [('eunit', 1)]`.

The sole EUnit failure is `quod_lifecycle_single_path_tests:-m1a_seven_foundations_test_/0-fun-13-/0`: `{https_client_failed,1}` with `Error: expected asset/2` at `marks.js:readImageAsset`, through `world.js:readGuiView` / `gui-operation.js:readOperations` to `godot-m1a.acceptance.mjs:offered`. This is the browser rejection retained under Yan's Godot-only choice. It was not skipped, suppressed or changed to pass. The full suite no longer reports the resolver discrepancy. Phase 0's implementation items are delivered, but its parent checkbox remains unchecked and plan status is blocked because full EUnit is not clean. Phase 1 still requires Yan's go and the switch to Astra High; no release action is authorized.

Earlier clean client gates are retained rather than repeated: core exit 0 / 358 checks [client-core.log](client-core.log); Godot build/import exit 0 with no ERROR diagnostics [client-godot-build.log](client-godot-build.log); actual Godot icon consumer exit 0 / nine checks [client-godot-icons.log](client-godot-icons.log); JavaScript unit tests exit 0 / 295 tests [client-unit-baseline.log](client-unit-baseline.log). Their compiled inputs have not changed during the gate repairs. The native result remains exit 0 / 56 tests [native.log](native.log); no native source changed. These client unit results do not imply browser interoperability with the new image shape.

All 1,381 frozen inputs are unchanged after the clean campaign: [repair-input-checks.json](repair-input-checks.json). Actual commands, times, exits and absolute log paths are also collected in [repair-final-results.json](repair-final-results.json). Compiled beam hashes are in [repair-final-artifacts.json](repair-final-artifacts.json), and the final tracked implementation diff is [repair-final-implementation.patch](repair-final-implementation.patch). New Godot fixture files remain identified by the input hashes and the earlier final-inputs snapshot. HEAD remains `7e6809e46ea290a53ffff910a53e0386d75b966f`, branch `worktree/pearl-stone`, version 0.7.282. No commit, staging or label change occurred.

Every final added plan sentence is quoted below. The authorized repair checklist item is also quoted; four of 17 checklist boxes are checked (24%), and all settled rulings remain unchanged.

> Yan-authorized gate repairs: isolate resolver trace measurements, remove unreachable refusal arms, and retire the link on an unrepresentable ordered frame.


> Activation clarification from Yan in this session (2026-11-09): backward
> compatibility is unnecessary; the ledgers will be refounded. Implementation
> therefore proceeds for that eventual activation. Running a refound, deployment
> or live edit still requires Yan’s explicit go.
>
> Scope clarification from Yan in this session (2026-11-09): Phase 0 stays
> focused on Godot; the existing browser adapters remain unchanged. Their
> rejection of the new GUI image shape, including the signed HTTPS lifecycle
> test failure, is retained in the
> [Phase 0 report](report.md).
>
> Scope clarification from Yan in this session (2026-11-09): repair the gate
> blockers before Phase 1. Investigate the resolver discrepancy and repair
> confirmed defects behind it and the Dialyzer warnings through existing owners;
> the browser adapters remain outside this scope.
>
> **Phase 0 validation blocked only by the retained browser rejection:** clean
> campaign 03 EUnit exits 1 (4,368 tests, one failure: `expected asset/2`); CT,
> xref and Dialyzer exit 0. The resolver measurement defect and all 46 Dialyzer
> warnings are repaired. Phase 0's implementation items, including Yan's
> authorized gate repairs, are checked; the phase remains unchecked because the
> full EUnit gate is not clean. Full exits, causal evidence, production delta
> and changed documentation sentences are in the
> [gate repair report](gate-repairs.md).
