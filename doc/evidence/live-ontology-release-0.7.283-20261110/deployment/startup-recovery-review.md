# Startup recovery continuation — 2026-11-11

Worktree: `/home/yan/src/quod_worktrees/pearl-stone`, branch `worktree/pearl-stone`.
This continues [the startup refinement](startup-refactor-review.md). All preceding
changes and failed campaigns remain retained. No commit, server deployment,
refound, live edit or version change is authorized by this report.

## Checklist

- [x] Reproduce the navigation recovery defect deterministically.
- [x] Refactor the existing signed-view owner to retain recovery interest.
- [x] Check delayed and already-ready replacements, stale notifications, expiry,
  explicit close, concurrent renewals and opening-worker cancellation.
- [x] Pass the previously failing exported navigation journey.
- [x] Complete the clean sequential server and client gates on frozen inputs.
- [x] Install the qualified client locally; retain the final client's existing
  native XR qualification and verify the installed non-XR startup path.

## Cause and correction

The old dependency-process DOWN handler immediately requested a fresh signed
read and released every readiness subscription. If the new read arrived before
the replacement engine recovered, it failed and the view had no remaining notice
that could resume it. The deterministic regression holds the actual consensus
owner while replacing its engine; the old implementation sends `refresh /
dependency_owner_changed` before the replacement can reconstruct its projection.

`quod_client_view` now suspends that projection, keeps the existing subscriptions
and original timer, and follows the existing engine name across replacement.
Registration is followed by an asynchronous readiness snapshot. Replay and
foreign-follow notifications use the same suspension path. All retained
dependencies must be ready, their owners current, and a cancelled opening worker
actually exited before requesting a fresh signed read. A concurrent renewal
cannot discard that recovery interest. Expiry and explicit close release it.
The old answer and authorization are never reused. Stale owner/replay notices
are ignored. No request polling, recurring retry, new process, protocol code,
registry, domain path or resource limit was added.

Normal unchanged reads and renewals retain their existing behavior. The exported
navigation journey verifies no reader/history/native-install or file write/sync
work during unchanged actual signed renewals.

Clean campaign 03 exposed a separate existing source round-trip defect: the
readable clause formatter emitted a literal `\"` for byte 34, which its own
frozen parser accepted but Erlog's runtime source reader rejected. A deterministic
probe of all 256 byte values isolated byte 34. The existing formatter now emits
that delimiter byte through its existing hexadecimal escape, and a runtime-reader
interoperability assertion covers it. The focused formatter module is 23/23 and
the repeated 256-byte probe reports `failures=[]`. No parser, grammar, path or
compatibility branch was added.

## Retained attempts and true exits

All logs below are in this directory unless otherwise linked.

- `startup-recovery-repro01.log`: **1**, one test and one expected reproduced
  failure: `{unexpected_simulation_reply, <<"unavailable">>,
  #{<<"reason">> => <<"dependency_owner_changed">>, <<"type">> => <<"refresh">>}}`.
- `startup-recovery-focused01.log`: **1**, two passing recovery tests, one
  cancelled selector: `{no_such_function,{quod_prolog_tests,runtime_events_test_,0}}`.
  The selector was corrected to `runtime_event_test_` in the next labelled run.
- `startup-recovery-focused02.log`: **0**, eight tests, zero failures.
- `startup-recovery-focused03.log`: **1**, seven tests, three failures and two
  cancellations. The test's already-ready branch left its runtime subscription
  registered; the next fixture hit `gproc:reg` `badarg`, then follow-on fixtures
  reported `already_started` / `identity_mismatch`. The branch now releases its
  test subscription; no production assertion or deadline was weakened.
- `startup-recovery-focused04.log`: **0**, 15 tests, zero failures, including
  the retained foreign-consumer and opening-worker cancellation checks.
- `startup-recovery-focused05.log`: **0**, ten tests, zero failures after the
  final owner-current fence and test formatting/fixture completion.
- `startup-recovery-navigation01.log`: **1**, local fixture compile **0**,
  fixture process **1** before readiness: `{badmatch,{error,eperm}}` at its
  local HTTPS listener. This was the sandbox restriction; no client launched.
  Full server output remains `/tmp/pearl-client-24z03olp/server.log`.
- `startup-recovery-navigation02.log`: **0**, separately labelled run with
  local-socket permission; compile, exported client and fixture server all **0**.
  Original operation recovery, actual owner restart, current navigation,
  uncertainty barriers, native selection, and unchanged-renewal work checks pass.
  The final additional owner-current fence was not in this run's already-loaded
  beam; focused05 and the clean campaign qualify that final fence.
- `startup-recovery-server01`: clean-default **0**, clean-test **0**, EUnit
  **0** (4,357 tests, zero failures). The user interruption terminated the
  runner during CT; CT has no child exit and xref/Dialyzer did not run. Its
  partial CT log is retained and is not counted as a passing gate. Campaign 02
  starts from a new frozen scope and does not overwrite or resume campaign 01.
- `startup-recovery-server02`: clean-default **0**, clean-test **0**, EUnit
  **0** (4,357 tests), CT **0** (150 tests), xref **0**, Dialyzer **1**.
  Dialyzer reported one unmatched `cancel_timer/1` return at
  `quod_client_view.erl:750`. The return is now explicitly ignored; campaign
  03 freezes and validates that changed source. No previous gate is promoted
  across this source edit.
- `startup-recovery-server03`: clean-default **0**, clean-test **0**, EUnit
  **1** (4,357 tests, one failure). `generic_hinged_signed_view_recovery_test_`
  failed while Erlog reparsed a generated genesis-anchor byte 34 from readable
  predicate source: `{erlog_parse,{expected,')'}}`. CT, xref and Dialyzer did
  not run because the runner was terminated with that failed scope. The retained
  fixture is `/tmp/quod_hosted_FF4B88CCD24FD449`; no unchanged rerun was made.
- `startup-recovery-server04`: clean-default **0**, clean-test **0**, EUnit
  **0** (4,357 tests), CT **0** (150 tests), xref **0**, Dialyzer **0**.
  The 1,077 frozen inputs were unchanged. Compiler warnings are retained. EUnit's
  occupied-listener and deliberately monitored process error reports are asserted
  negative-path tests, not unexpected child failures.
- `startup-recovery-client01`: all 14 sequential entries exited **0**:
  JavaScript, clean core and Godot builds, core checks, export, package contents,
  icons, controller input, workspace, fresh and saved startup, GUI, spaces,
  navigation and encrypted local backup. The 1,077 frozen inputs were unchanged.
  The controller entry retains the two already-documented Godot headless popup
  disconnect diagnostics; its assertions and true child exit are 0, and the
  source-run controller check has no such diagnostics.
- `startup-recovery-install01.json`: the qualified export replaced the local
  Steam installation with **0** installer exit after 226 exported files were
  hash-verified. The prior installation is retained at
  `/home/yan/Games/quod-before-startup-recovery-20261111`. Steam's existing
  shortcut target resolves through its retained symlink to the installed engine.
- Installed smoke 01 exited **0** and passed all six startup assertions, but is
  not called clean: the sandbox blocked Godot's normal log directory and emitted
  `Failed to open 'user://logs/godot2026-11-11T16.46.58.log'` and
  `Failed to open log file for writing: user://logs/godot.log`. Its disposable
  result is `startup-recovery-installed-smoke01-result.json`.
- Separately labelled installed smoke 02 ran with normal log access, exited
  **0**, emitted no error, and passed the same six packaged-icon, fresh-key and
  authentication-transition assertions. Its disposable result is
  `startup-recovery-installed-smoke02-result.json`; the user's saved identity
  was not opened.

## Scope and normative documentation

This continuation changes the signed-view owner by **+56 / −9 = +47 lines** and
the existing clause formatter by **+2 / −1 = +1 line**. Combined with the
preceding startup refinement's **+44**, the task is **+92 net production lines**,
excluding tests, docs, evidence, assets and earlier unrelated uncommitted fixes.
Growth retains and retires the existing dependency handles correctly across
process replacement and an overlapping renewal, while making the existing
source formatter interoperable with its runtime reader; the premature reopen
and invalid delimiter paths are replaced, not retained beside the corrections.

Exactly two normative sentences were added to `doc/proofs.md`:

1. “A retained signed view withdraws its projection during dependency recovery
   but keeps its existing subscriptions and original deadline.”
2. “It requests a fresh signed read only after all retained dependencies are
   ready and any cancelled opening worker has exited; recovery never reuses the
   withdrawn authorization.”

No other normative document changed in this continuation. Every README sentence
changed in the preceding client refinement remains listed verbatim in
[the prior report](startup-refactor-review.md#every-normative-documentation-sentence-changed)
and its [exact patch](startup-refactor-doc-sentences.patch).

The server corrections are local source until a separately authorized release.
Installing the client does not apply them to the fleet. The local Steam client
is installed and its non-XR startup path is clean. The exact client had already
passed three native XR cycles with fresh tracked stereo frames before these
server-only corrections, but those checks cannot establish what the user sees
through the headset or physical wand input when the runtime exposes no active
controller profile.
