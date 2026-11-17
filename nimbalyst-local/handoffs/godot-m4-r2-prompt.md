/planning-implement QUO-65

Checkpoint M4-R2: repair the usable XR environment, exercise actual XR/Vive
behavior, and continue causal shutdown work. Resume ONLY existing worker
ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f, whose actual launcher is
openai-codex:gpt-6.1-sol / effortLevel=max. Verify the launch receipt/session;
prompt text cannot switch a model. Effective backend effort remains unexposed.

Yan has explicitly renewed the instruction to work on the outstanding points,
after challenging the coordinator's blanket stop. The previous coordinator
stop decision and R1's inventory-only runtime restriction/three-attempt limit
are superseded for this scoped continuation. Keep doing independent authorized
work when another subtask is blocked; do not stop the entire workflow merely
because physical participation is unavailable or a small repetition count is
exhausted. Preserve actual failures and full acceptance boundaries. Stop for a
demonstrated need beyond Sol/max or a concrete safety/authority blocker that
cannot be avoided while making useful progress. Do not ask routine permission.

Read AGENTS.md first. Work only in /home/yan/src/quod_worktrees/pearl-stone,
branch worktree/pearl-stone, HEAD293cf6115c0a6b18315eccdbb42cbca396f443d3,
parentf716ddf5e578df957a5b18421a0727a32c634f87; original base
f6c29fe925e666dd68ee7fa68c0e03f5d03391a2 is provenance, never a reset target.
Verify Git status/index and preserve all current uncommitted M4, generated
.agents, coordination and user changes. No main edit/import, branch/worktree
change, parallel writer, Claude review or model switch. Coordinator
ed9cd520-b2a4-4607-a8f5-ff99d08f3e46 retains serial acceptance/commit/launch ownership.

Use planning-implement with SHARED TRACKER bookkeeping: read full current
QUO-60/65, work_radar and link your existing session; no new item/frontmatter
plan/synthetic fm:plan. Parent stable ID plan_1793104481306_y8rhic; QUO-65
tsk_01M5YNM08XZDSB9AERHSBMCPYZ. Resolve repository links in this worktree.
The parent and M4 bodies remain unchanged by current own-UUID reads. Metadata
is QUO65 in-review80, parent67. Body/description/checklist publication retries
remain BLOCKED by automatic approval review: never retry/bypass those. Only
necessary fresh metadata-only actions, with exact nested results inspected.

Explicit-project caller, using YOUR UUID for attribution:

```sh
env -u LD_LIBRARY_PATH -u LD_PRELOAD node /home/yan/src/quod/nimbalyst-local/tools/tracker-call.mjs /home/yan/src/quod ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f work_radar '{"issueKey":"QUO-65"}'
env -u LD_LIBRARY_PATH -u LD_PRELOAD node /home/yan/src/quod/nimbalyst-local/tools/tracker-call.mjs /home/yan/src/quod ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f tracker_get '{"id":"QUO-65"}'
env -u LD_LIBRARY_PATH -u LD_PRELOAD node /home/yan/src/quod/nimbalyst-local/tools/tracker-call.mjs /home/yan/src/quod ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f tracker_get '{"id":"QUO-60"}'
env -u LD_LIBRARY_PATH -u LD_PRELOAD node /home/yan/src/quod/nimbalyst-local/tools/tracker-call.mjs /home/yan/src/quod ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f tracker_link_session '{"trackerId":"QUO-65"}'
```

Use require_escalated when the sandbox cannot see the app/loopback. No app
rebuild/restart, database or persisted-token workaround. If an approval review
rejects an action, retain the exact rejection; do not disguise/repeat it through
another route. Continue unaffected safe work.

## Verified prerequisites and new causal lead

Read godot-m4-result.md, godot-m4-coordinator-verification.md,
godot-m4-r1-result.md and godot-m4-r1-coordinator-verification.md under
nimbalyst-local/handoffs, with their separate evidence directories. R1 made no
production/test/spec correction. All candidate09 source and prior failures are
unchanged. All151 artifacts and23690 source paths/content/links/modes, full
worker materialization, complete untracked payload, diagnostic inputs/outputs
and true receipts were independently checked. No server suite was rerun.

M4 boundary:
/home/yan/.cache/quod-m4-artifacts/quod-godot-m4-handoff-ca84d4f8-20261029-01
snapshot a06f1f934754d3d210e1b74c5685c2c523b1507bfc1a8af2ce9fc7ce4aec5349.
R1 boundary:
/home/yan/.cache/quod-m4-r1-artifacts/quod-godot-m4-r1-handoff-ca84d4f8-20261029-01
snapshot 5a09fda58101a38d362c5e50cd9bcd4f827dcca74295abaa3b1f521c95379fcc.
Same binary HEAD patch:
8d759963b1100714e6f1301175324168bab40bdb3125a02f8b5604cefeab4370.
Preserve frozen evidence/handoffs/snapshots; new work gets R2 labels and a new
boundary. All earlier three prompt/report rows are completed; no pending writer.

Coordinator read-only diagnosis now establishes:

- /usr/bin/monado-service belongs to monado-git25.1.0.r381.gf4dc0ec36-1,
  built/installed2026-04-07. readelf confirms six required OpenCV.so.413 objects.
- Installed opencv5.0.0-12 supplies different.so.500 libraries. Pacman history
  shows the OpenCV4.13→5.0 upgrade2026-07-27; the installed Monado remained the
  April build. The missing ABI is real, not a Godot/controller acceptance result.
- The earlier native-xr.py forces /usr/share/openxr/1/openxr_monado.json and
  /usr/bin/monado-service. Coordinator's current process has no XR_RUNTIME_JSON;
  ~/.config/openxr/1/active_runtime.json and /etc/xdg/openxr/1/active_runtime.json
  do not exist. Inspect actual loader selection and available Envision/SteamVR/
  Monado profiles rather than assuming that forced system binary is the only
  intended runtime. Do not change the user's global selection.
- Top-level readable pacman cache contains only OpenCV5 archives. Recursive
  rg met protected download directories and exited2; no OpenCV4 archive was
  found. This is not proof that every cache/profile lacks a usable runtime.
- USB discovery included the original Vive/lighthouse and two Watchman dongles;
  no native stereo/tracking/physical pass was established.

## Work in this serial checkpoint

1. **Make a compatible private runtime usable.** Trace the actual loader/service
   paths and dependency ownership. Reuse an existing compatible user runtime
   if present; otherwise acquire/build a pinned compatible runtime/dependency
   bundle in a task-specific workspace/cache. Scoped private runtime/library
   builds and per-process environment/config are authorized. Use trusted primary
   sources and exact hashes/signatures/provenance, inspecting current official
   documentation when fetching or choosing versions. Diagnose ABI compatibility
   and required tracking backends as a whole. Merely reaching a loader-success
   line is not XR readiness. Do not symlink incompatible.so.500 names to.so.413,
   downgrade/upgrade global OS packages, overwrite system libraries, alter global
   runtime/display/session configuration or interrupt an unrelated running app.
   Use private sockets/state and owned process lifetimes; never kill a user's
   existing runtime to make a fixture pass. Test fixture observations may need
   their real owned runtime directory while the compositor connection stays valid.

2. **Run real XR qualification after readiness.** First qualify actual runtime
   creation/session start/stop with the pinned export, then automate all possible
   observations on the available Vive/two wands: real runtime devices/profiles,
   pose validity, stereo targets/frames, action delivery and disconnect/focus/
   reentry/lifecycle/resource teardown. Recheck the retained QUO-27
   XR_ERROR_SESSION_NOT_STOPPING, spatial-discovery and interaction-profile RID
   obligations on this replacement; do not claim them fixed from exit0 alone.
   Keep injected/simulator, real-runtime, actual hardware and human-observed
   pixels/comfort results separate. No Quest qualification. If a case genuinely
   needs Yan to wear/press/observe hardware, get the application ready first,
   specify the exact short action through a supported interactive tool and keep
   independent work progressing. Do not ask for blanket permission to continue.

3. **Continue causal desktop shutdown diagnosis.** Original gui-final03-backup-
   import and NORMAL Main.CloseApplication physics-final06 remain failed; the
   latter passed39 assertions then client-9/wrapper1/server0. R1's four passing
   attempts and60 phase observations do not locate their cause. These desktop
   failures did not start native OpenXR: do not attribute them to Monado's ABI.
   Review the complete application AND harness shutdown chain, owned task and
   transport cancellation, main-thread continuation/engine teardown, output/EOF/
   watcher ownership, resource lifetimes and causal interleavings. Use concrete
   hypotheses and controlled real seams to discriminate them, not an indefinite
   repeat of the same happy path. Preserve bounded removable phase/managed/native
   thread diagnostics on the actual offending owned process before termination.
   Keep original deadlines/watchdogs, argument-free restricted stacks and private
   data protections. Remove observation from final production after retaining its
   source. Fix only a demonstrated responsible-owner gap through shared callers;
   no forced-success quit, abandoned work, polling/retry workaround or new exit
   path. Later passes never erase either historical failure. Report precise
   attribution limits if an external cause is proved only for a new trigger.

An unavailable subcase does not stop the other tasks. Read
nimbalyst-local/handoffs/godot-m5-readiness.md for independent packaging
preparation. You may add exact dependency/caller/package observations to your
R2 handoff, but do not start M5 implementation/retirement/cutover or credit it.
The coordinator is preparing that existing ticket read-only while you remain
the only implementation writer.

## Verification, preservation and handoff

Read relevant specs and doc/multiwrite-architecture.md before semantic changes.
Retain Prolog authority, seven foundations, explicit storage/U-A separation,
existing atomic actions/reactions/recovery, signing/custody/uncertainty, selected
native physics leases/sequence/incarnation/deadline, one input/GUI/resource owner,
neutral rearm/cancellation and zero work on unchanged renewals. No old Quod Rust
core/GDExtension, second executor/KB/simulation, silent fallback, deadline/cap
increase or uncertain-write resubmission. Preserve optional domains and all
still-valid coverage; explain actual production/test/spec/runtime-tool deltas.

Reuse the exact pinned Godot4.7.2/.NET SDK10.0.112/runtime10.0.12/BC2.7.0 toolchain
and package archives. All1432 unchanged server inputs reuse accepted M3b
native56/EUnit4266/CT149/xref/Dialyzer/release; do not repeat unchanged suites.
Changed inputs invalidate their affected acceptance and need real causal checks,
source-only build/export and affected clean sequential gates/journeys. Keep
runtime/system prerequisites distinct from product inputs. The R1 diagnostic
export includes tracing and must not become the distributable production export.

Use doc/evidence/godot-m4-r2-20261029 (or actual date) and
nimbalyst-local/handoffs/godot-m4-r2-result.md. Preserve full commands, sanitized
logs/true exits/completion, failed/unrun cases, actual engine/runtime/device
identity and package/source manifests. Freeze exact base/binary patch/full
untracked contents plus necessary diagnostic/runtime/dependency/output bytes
and independently reconstruct/check paths/content/links/modes. Reuse unchanged
immutable artifacts safely; no general cleanup/compression or snapshot rewrites.
Available storage was about39.8GiB; /tmp is small. No private keys/stores/raw
secret-bearing diagnostics in public snapshots. Keep original unknown operations.

Before freeze, read the full findings batch using consume_session_inbox only if
available; otherwise full list-only inspection with honest non-consumption.
Return one complete checkpoint result via automatic completion notification.
The coordinator verifies and uses developer_git_commit_proposal under Yan's
standing authority; do not commit/push/deploy, start another writer/reviewer,
rebuild/restart Nimbalyst or close full M4/parent/contributing tickets yourself.
The exact M0 network boundary remains for later M5; no current network mutation.
Follow AGENTS.md's stop notification rule.

For context, call get_session_summary with
sessionId=ed9cd520-b2a4-4607-a8f5-ff99d08f3e46.
