# Server gates on the unified master (2026-11-17)

Run after the two lines of work were merged and 139 evidence folders removed.
Tree: master at `3d740b6c`. No file under `src`, `test`, `priv`, `include`,
`native` or `rebar.*` differs from `b37b3426` (0.7.295), whose own gates were
green on 2026-11-17 (eunit 4370/0).

| Step | Run 02 |
| --- | --- |
| clean | exit 0 |
| eunit | **exit 1: 4253 tests, 0 failures, 3 cancelled** |
| ct | exit 0, all 150 tests passed |
| xref | exit 0 |
| dialyzer | exit 0 |

Run 01 was killed ten minutes into eunit when the session that launched it
stopped; see `server-01-stop.md`. It is not a result.

## The eunit failure

`quod_rendering_tests:complete_scenes_and_authored_resources_test/0` reached
eunit's five-second limit. The timeout cancelled the rest of its module and
the modules eunit ran after it, which is why 4253 tests ran, not 4370.

- It reproduces with the module alone (`triage-01-rendering-module.log`:
  25 tests, 0 failures, 3 cancelled).
- Called directly, outside eunit's limit, the test passes, three times, in
  4.29 s, 4.41 s and 4.44 s. The machine was busy at the time: load average 8
  to 11 on 8 cores, a game and SteamVR running.
- At the timeout the proof was inside `erlog_int:freeze_failure_term/1`, which
  copies the term of a failed goal for its failure reason. The test proves a
  scene of 600 marks and then one that must fail.

So the test is not broken by the merge: it needs about 4.4 s of a 5 s limit
and fails when the machine is busy. Nothing was changed and the gates were not
run again. Open: whether the cost of the failure reason for a large failed
goal is acceptable, or the test's margin.

## After the tools moved

`quod_source_release.erl` moved to `scripts/release/` and
`test/quod_gui_menu_tests.erl` reads it there: that module alone passes
(`triage-02-menu-module.log`: 10 tests, 0 failures). The full gates were not
run again after this one-line change.
