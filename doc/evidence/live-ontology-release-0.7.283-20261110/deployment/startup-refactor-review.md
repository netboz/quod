# Godot startup refinement — continuation boundary, 2026-11-11

Worktree: `/home/yan/src/quod_worktrees/pearl-stone`, branch `worktree/pearl-stone`.
Nothing committed or installed. No fleet, ledger, refound or version change.
The user's saved Quod identity was not opened by any probe: each used an explicit
new `/tmp` profile. Existing user-owned changes were preserved.

## Implemented and staged

- [x] Failed and cancelled controller-model transfers expose a visible notice and an explicit retry. Unchanged source notices do not retry; successful sources retain their verified resources.
- [x] Controller artwork is outside network-session cleanup; application shutdown still awaits its lifetime.
- [x] Backup import/export replaces the sign-in controls in the existing shared card. Paths and passphrases use its spatial keyboard, with an explicit Close action.
- [x] Focus loss revokes text input immediately. The shared GUI retains keyboard geometry through the pointer release that changed focus, preventing lost clicks.
- [x] The shared initial surface renders before identity storage is opened. Headless operation has no rendered-frame wait. The fixed 1200 ms boot-splash minimum was removed.
- [x] Initial space loading retains visible progress, using existing navigation, view and scene state. Confirmed unplaced locations complete startup without requiring a scene.
- [x] Prepare a complete direct-engine installation at `/tmp/quod-startup-refactor-stage-20261111`. Its 226 export files hash-match the qualified export. Existing Steam artwork and last-run log are preserved in the stage. The stage has the tracked `quod` entry and actual `quod.x86_64` engine, without the local `quod.bin`/sleep wrapper.
- [ ] Resolve the navigation recovery failure below, then qualify the final tree.
- [ ] Switch the local Steam installation after its gates pass. The currently installed client is unchanged; its polling/sleep launcher therefore remains installed.

The exact final code/document inputs are in
[startup-refactor-client02-inputs.json](startup-refactor-client02-inputs.json).
Their hashes were checked unchanged after all runs. The before-task snapshot is
`/tmp/quod-startup-refactor-before-20261111`; it includes the preceding uncommitted
fixes, so the delta below excludes that earlier work.

## Verification and failures

Clean sequential campaign 02:
[startup-refactor-client02-results.jsonl](startup-refactor-client02-results.jsonl).
JavaScript, core clean, Godot clean, core tests, export, package content, icons,
controller input, workspace, startup-new, startup-saved, GUI journey and spaces
journey all exited **0**. Navigation exited **1**. The campaign stopped there;
it did not run its final backup entry. The independent encrypted-backup gate then
exited **0**: [receipt](startup-refactor-backup01-process.json),
[full log](startup-refactor-backup01.log).
EUnit, CT, Dialyzer and xref were **not rerun**: no Erlang source was changed.
This is not a clean release result.

All earlier failures remain intact:

- The initial build command exited **0**; `/tmp/quod-startup-refactor-build-01.log`
  contains a NuGet vulnerability-query warning and Godot editor socket errors
  under sandbox restrictions. The clean campaigns used the approved local-socket
  environment. Existing compiler warnings, including native tracker deprecation
  and the nullable warning, remain in the full build logs.
- Development probe 01 build exited **0**; controller probe timed out, wrapper
  exit **124**, with only the Godot banner. The rendered-frame signal never
  arrives in headless mode. Fixed by waiting only when a display renders.
  [Log](startup-refactor-dev01-controller.log).
- Development probe 02 build/controller exited **0**; workspace exited **1** at
  `the existing spatial keyboard can edit a backup path`. The test now waits for
  the keyboard's actual visibility notification rather than inspecting before
  its deferred update. [Log](startup-refactor-dev02-workspace.log).
- Development probe 03 build exited **0**; workspace exited **1** with native
  pointer timeout on `backup-close`. Its click reached `backup-path` after focus
  loss shrank the keyboard/surface during the press. Fixed in the shared keyboard
  owner, without weakening the native click assertion.
  [Log](startup-refactor-dev03-workspace.log).
- Development probe 04 build/workspace exited **0**.
  [Results](startup-refactor-dev04-results.jsonl).
- Clean campaign 01 navigation exited **1**: `No qualification progress within
  the test watchdog`, after reconnect and the deliberate storing-ontology owner
  restart. [Log](startup-refactor-client01-navigation.log).
- An intermediate diagnostic log parser exited **1** with `JSONDecodeError:
  Extra data`; its prefix length was corrected before extracting the trace.
- Clean campaign 02 navigation also exited **1**. The managed failure is
  `System.TimeoutException` in `SpaceNavigation`, NavigationChecks.cs:95, waiting
  for the space after `m2_restart`. The local fixture itself shut down with **0**.
  [Log](startup-refactor-client02-navigation.log),
  [fixture receipt](../../ontology-references-phase2-20261110/startup-refactor-client02-navigation-journey-result.json).

## Navigation blocker and model boundary

The before-task client was built in isolation at
`/tmp/quod-startup-baseline-20261111/godot/dist/quod.x86_64`; its build and full
navigation comparison exited **0**. Its source was copied from the exact current
worktree and overlaid with the preserved before-task files. No master checkout
was used. [Comparison log](startup-refactor-baseline01-navigation.log).
One passing baseline comparison does not establish that the new tree is harmless
or that the failure is pre-existing.

The external test proxy recorded only view-event type, connection, time, kind
and reason; no production tracing or protocol behavior was changed. Its wrapper
is `/tmp/quod_navigation_probe.py`; the copied proxy is
`/tmp/quod-startup-navigation-trace.py`.

For the failing navigation connection, the server emitted
`refresh / dependency_owner_changed`, then `unavailable /
view_not_authorized_or_ready` **30.692 ms** later, with no replacement navigation
projection. In the successful baseline, the corresponding restart refresh was
followed by a navigation projection **107.831 ms** later. These intervals were
computed from the recorded monotonic timestamps, not manually estimated.
Other signed views recovered in the failing run.

Relevant existing owners: `src/quod_client_view.erl` (`refresh`, `release`,
`open_result`, dependency recovery notifications), `client/godot/Core/SignedView.cs`
(`Handle`, `Discard`, `Open`), and Main's navigation withdrawal/space suspension.
Main's UI changes may alter timing; causal responsibility is not yet established.
Do not conceal this with sleeps, polling, repeated opens, relaxed tests or longer
deadlines. This is the requested handoff to **Astra High** for the readiness and
invalidation ordering question. No server code has been written.

## Native SteamVR evidence

- Native probe 01 exited **0**, with three cycles of 90 fresh tracked stereo
  frames each and rendered draw calls. It verified XR before sign-in, network
  session cleanup retaining XR, re-entry and normal application exit.
  [Receipt](startup-refactor-native01-process.json),
  [observations](startup-refactor-native01-result.json).
- Native probe 02 exceeded its 45-second watchdog and was killed, true child exit
  **-9** (wrapper **1**). Its log records SteamVR `vrmonitor` failing to load Qt
  platform `wayland;xcb`, while listing only `xcb` as available.
  [Receipt](startup-refactor-native02-process.json),
  [full output](startup-refactor-native02.log).
- Steam and SteamVR had inherited Nimbalyst's `QT_QPA_PLATFORM=wayland;xcb` and
  `/tmp/.mount_Nimbal.../usr/lib` library paths. The idle Steam shutdown exited
  **0**, its original PID exited, and detached restart exited **0** with those
  editor-injected variables removed. No persistent settings file was edited.
  [Receipt](startup-refactor-steam-environment01-result.json).
- Separately labelled native probe 03, using that clean environment, exited **0**
  in 7.73 seconds and passed the same three cycles.
  [Receipt](startup-refactor-native03-process.json),
  [observations](startup-refactor-native03-result.json).

Native probes 01 and 03 both retain these engine teardown diagnostics despite
exit 0: nonexistent `spatial_discovery_recommended` disconnect on
`OpenXRSpatialEntityExtension`, and one leaked `OpenXRAPI::InteractionProfile`
RID. Probe 03 also reports SteamVR's missing `vivetools-bv` helper. These were not
silently discarded. Runtime assertions passing is not a clean diagnostic result.
The earlier commentary describing probe 01 shutdown as clean overstated it.

The runtime supplied head tracking, but controller interaction profiles were
`/interaction_profiles/none`; physical wand input/models were not qualified.
Injected production XRServer/native-GUI tests passed. No headset pixels were
observed by the agent, and no saved-profile live authentication was attempted.

## Measured production delta

This refinement adds **45 C# production lines net** and removes **one project
configuration line**, for **+44** overall. Main is +29, OpenXRInput +13,
SpatialKeyboard +3, project.godot -1. Counts exclude tests, docs, evidence, assets
and the earlier uncommitted fixes. [Measured scope](startup-refactor-scope-02.json).
Growth supplies explicit model failure/retry feedback, an owned first-frame
startup task and accessible shared backup controls. The native modal path and
artwork wait in network cleanup were removed; no process, registry, domain path,
resource cap or recurring readiness timer was introduced.

## Every normative documentation sentence changed

Only `client/godot/README.md` changed for this refinement. The exact before/after
hunks are retained in [startup-refactor-doc-sentences.patch](startup-refactor-doc-sentences.patch).

Replaced: “The Quod logo appears on the opening screen.” With:

- “The shared opening surface renders the Quod logo before opening local identity storage.”
- “The launcher starts the engine directly, without process polling or fixed startup waits.”
- “The sign-in card remains visible while the initial space is being opened; an accepted space or a confirmed unplaced location completes that transition.”

Replaced: “Signing in after mapping withdrawal, and backup/import through the
separate modal window, remain desktop actions.” With:

- “Network-session cleanup does not wait for controller artwork.”
- “Encrypted backup import/export uses the same sign-in card and native text controls on desktop and in VR; Close returns to the retained sign-in controls.”

Added:

- “Controller model loading and failure appear on the sign-in card; **Retry controller models** explicitly retries failed appearances.”
- “Unchanged source notices do not retry failed transfers, and successful appearances continue to reuse their verified bytes and template.”
- “Focus loss revokes text input immediately; a pointer press in progress retains the keyboard geometry until its release.”

Replaced: “Main's separate backup-file/passphrase window remains desktop-only.”
With: “Backup paths and passphrases use this same keyboard and native editor ownership.”

The launcher sentence describes the tracked/staged entry; the old local Steam
wrapper remains until installation is authorized by a passing final scope.
Other sentences adjacent to these edits were retained. This handoff records
operational evidence rather than changing a normative architecture document.

The initial desktop stop notification exited **1** with `Could not connect:
Operation not permitted` inside the sandbox. The separately approved desktop
notification attempt exited **0**.
