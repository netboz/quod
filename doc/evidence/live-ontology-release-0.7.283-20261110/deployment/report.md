# 0.7.283 live refound evidence

This is operational evidence for `worktree/pearl-stone` at
`1972b3b696b56699c8f887a697fbee9d866fd431`. The release used the existing
root `create_ontology/3` action, ordinary source and ontology registration,
and one signed multi-ontology transaction for the user's ontology registration
and hosting fact. No founding operator was run or changed.

The prior root anchor was
`687A7420941B2176710EB956F528BCC0F7D421BA7ADCE419F5AC0312ABB07574`.
The new root anchor is
`C21E011BC94C7B69AD56A4227BED085EF2FA7C536458A5457C410256C1FD3F5E`.
The 0.7.283 image build and push exited 0; the pushed manifest digest is
`sha256:79b28bc21d2ac16584f10374e767b5be552c543e49e2df2b8728e258bc873d28`.
See [build](image-build.log) and [push](image-push.log).

The isolated rehearsal founded and registered all six system ontologies,
checked all 36 GUI assets, submitted the exact user's ontology registration
once (`committed`), and recovered the catalogue and hosting fact after restart.
Its logs are in [rehearsal](rehearsal/). The first final-catalogue query
failed semantically because it asked the root instead of the node actor's
storing ontology for the hosting fact, although the command exited 0.
That output remains in [the failed read](rehearsal/final-catalogue.log);
[the corrected read](rehearsal/final-catalogue-corrected.log) and
[restart read](rehearsal/after-restart-catalogue.log) both report six
registrations, height 17 and the hosting fact. The disposable rehearsal
container was removed, exit 0 ([log](rehearsal-container-cleanup.log)).

The old Nomad job stopped with command exit 0. Exactly eight recorded compute
host volumes were deleted and recreated on their recorded hosts; all sixteen
commands exited 0 ([delete](volume-delete-0.log),
[create](volume-create-0.log); the numbered logs cover 0–7). The separate
guarded cloud cleanup task removed only the old `0` and `1` ledger directories
and exited 0 ([task log](cloud-cleanup-task.log)). The original volume listing
contained Nomad's extra empty CSI array and was not valid single-document JSON;
it remains in `before-volumes.json`, with the parsed inventory in
[before-volumes-corrected.json](before-volumes-corrected.json).

The bootstrap and full-join job runs each exited 0. Both preceding `nomad job
plan` commands exited 1 for an applicable diff, and the scheduler placed the
jobs. Founding logs are in [founding](founding/): six create/ready/register
operations succeeded, node enrollment succeeded, the GUI assets check returned
`ok`, and the original signed user's ontology registration was submitted once
and returned `committed` ([operation](founding/user-register-original.raw),
[result](founding/user-register-submit.log)). The final readback reports six
registrations, height 17 and the user's ontology hosting fact
([readback](founding/final-catalogue.log)).

Seven joined compute observers were checked ready and admitted once each by
the existing root action. Every submit returned `admitted`; committee readbacks
rose to eight ([numbered admission logs](admit-7-committee.log)). The final
[Nomad snapshot](final-job-health.json) is `successful`, with 8/8 compute and
2/2 cloud allocations healthy. Each of the ten [node summaries](node-0-summary.json)
(numbered 0–9) was read with child exit 0. The aggregate assertion exited 0:
all ten have the new root anchor, seven system namespaces including root,
height 58 applied at height 58, committee size eight, and `syncing=false`;
eight are validators and two cloud nodes are observers.

The earlier clean sequential gates are in the
[post-phase report](../../ontology-references-phase2-20261110/postphase-report.md):
EUnit 0 (4,353), CT 0 (150), Dialyzer 0, xref 0, and all client gates 0.
No production source or normative documentation sentence changed in the
initial refound; its production line delta is 0. The plan checklist is already
fully checked. The release evidence remains local and uncommitted at Yan's
request.

Yan asked that the logs remain local and uncommitted. The first read-only client
export comparison exited 1: all 191 frozen hashes matched, but `dist` contained
35 extra files. Diagnosis found 30 private journey files under `dist/_build`
and five normal export sidecars. The corrected comparison excluded only the
private journey directory; it exited 0 with 196 export files, all 191 frozen
hashes matching and exactly the five expected sidecars.

Yan then authorized a local Steam installation. The existing Steam shortcut
targets a symlink to `~/Games/quod`. A staged copy retained the user's launch
script and Steam artwork and replaced the engine, package and complete managed
data directory with the verified export. Staged byte comparisons and the
headless engine-version check each exited 0. The guarded same-filesystem switch
exited 0; the previous installation remains at `~/Games/quod-before-283` for
rollback. Post-switch byte comparisons, shortcut-target check and version check
each exited 0. No Steam upload or remote publication occurred. A headless
smoke launch through the installed Steam shortcut with a disposable profile
exited 0 without reported errors ([result](steam-smoke-01-result.json),
[log](steam-smoke-01.log)); its generated installed run log was cleared after
the retained copy was checked. The complete post-release signed GUI readback
and live client interaction probes have not
been claimed from these fleet summaries; the clean signed local tests and
rehearsal are distinct evidence.

## Local VR startup follow-up

Yan's SteamVR-lobby launch reached a 3D sign-in screen. Its retained run log in
the previous local installation shows SteamVR's OpenXR runtime initialized,
followed by repeated `No viewport was marked with use_xr` lines. The existing
client started its XR viewport only after successful sign-in, which the
refounded fleet had not yet allowed. The client now starts that same XR owner
at launch when it is available, including before sign-in; it uses the existing
3D presentation when XR is unavailable. The sign-in gate and the now-unused
`vrLeft` field were removed. No new execution path or process was added.

The first export build exited 1 at the sandbox's `ERR_CANT_CREATE` local socket
error after compilation ([full log](vr-startup-export-01.log)). A separately
labelled export with local-network access exited 0
([full log](vr-startup-export-02.log)). The subsequent clean sequential client
campaign has eleven true child exits of 0, including JavaScript, clean core and
Godot builds, core checks, export, package contents, signed icons, exported GUI,
spaces, navigation and local backup
([results and full log paths](vr-startup-client-01-results.jsonl)). No server
source changed, so the earlier server gates remain the server evidence.

The exact new README sentences are: "OpenXR is enabled at start; when a supported
runtime and headset initialize, the client opens in VR before sign-in."
"Otherwise it continues in 3D." "**F9** enters VR while the client is focused;
after sign-in, **This device ▸ Enter VR** does too." "**F9**, **Escape** (once
nothing else is open) or **This device ▸ Return to 3D** leaves it." The
unchanged outcome sentence was only reflowed. Production source delta is
`+3 / -5 = -2` lines in `client/godot/Main.cs`; the README is excluded.

The verified export replaced the local Steam target through a guarded
same-filesystem switch. The pre-fix 0.7.283 installation and Yan's manual run
log remain at `~/Games/quod-before-vr-startup`; the older pre-0.7.283
installation remains at `~/Games/quod-before-283`. Post-switch byte, shortcut,
launcher and artwork checks exited 0. A headless launch through the installed
Steam shortcut with a disposable profile exited 0 with no reported errors
([result](vr-startup-steam-smoke-01-result.json),
[log](vr-startup-steam-smoke-01.log)). Its generated installed run log was
cleared after a matching copy was retained. Physical headset rendering has not
been observed in this follow-up; SteamVR was stopped during installation.
The source change awaits Yan's commit go; the local logs remain uncommitted at
his request.

Yan's subsequent physical headset attempt on 2026-11-10 failed. The installed
client's `~/Games/quod/last-run.log` again records repeated `No viewport was
marked with use_xr` lines. SteamVR's `vrcompositor-linux.txt` records a fatal
Vulkan `UNKNOWN_ERROR` at 19:24:00; the kernel journal records a same-second
`RenderThread` segfault inside `libnvidia-glcore.so.615.71.09`, and
`vrmonitor.txt` reports SteamVR error `-203` at 19:24:01. The previous 19:09
attempt had the same compositor fatal, driver segfault and `-203`. Both
compositor crashes followed Quod connecting to SteamVR. The available logs do
not establish whether Quod triggered the driver/compositor fault, or whether
the missing XR viewport preceded or followed that fault. The headset was black
with a red light by Yan's observation. The client is not qualified for headset
use, and the earlier headless green gates cannot establish that it works.

On 2026-11-10 at 19:49, a separately labelled local diagnostic started
SteamVR without asking Yan to launch the client. The installed client was run
with a disposable profile and forced OpenXR; the bounded probe exited 124
after its 20-second timeout, with no compositor crash or missing-viewport
warning ([log](vr-diagnosis-01-runtime-probe.log)). The existing native OpenXR
qualification then exited 1, retaining its failed assertion and output
([log](vr-diagnosis-01-openxr-qualification.log),
[cycle result](vr-diagnosis-01-cycle1.json)). It observed 90 fresh stereo
frames and a two-view XR viewport, but the runtime was Synchronized,
`can_render=false`, and draw calls were 0. SteamVR was intermittently Ready
and Standby and still showed the headset and base stations as searching. Thus
this run confirms XR activation with the installed client but does not qualify
active-headset rendering or resolve the earlier compositor crash. SteamVR was
shut down after the diagnostic. No production source was changed in this
diagnostic campaign.

At 19:55 Yan made the headset available. The first active-headset native
OpenXR qualification exited 1 ([log](vr-diagnosis-02-active-openxr-failed.log),
[cycle result](vr-diagnosis-02-active-cycle1.json)): OpenXR supplied 90 fresh
frames, 90 high-confidence tracked head frames, two views and `can_render=true`,
but Quod drew no scene geometry while the session was Visible without input
focus. The workspace panel was only placed by the focused-input path. The
presentation owner now places it when the head is tracked and the session is
running and visible; input still requires focus. The injected workspace
qualification now checks unfocused placement and absence of travel dispatch.
No new execution path or process was added. The Godot documentation says an
Always-update SubViewport can render despite a hidden parent, so the earlier
inference that the hidden container itself was broken was withdrawn.

The rebuilt export exited 0 ([log](vr-focus-fix-export-01.log)). Its existing
native OpenXR qualification exited 0 with a real, unsimulated headset: all
three stereo cycles passed with 90 fresh/high-confidence head frames and one
scene draw call per cycle, and SteamVR's compositor did not crash
([log](vr-focus-fix-openxr-01.log),
[result](vr-focus-fix-openxr-01-result.json)). The first targeted headless
workspace run exited 1 because its model fixture was passed as a relative path
([log](vr-focus-fix-workspace-01.log)); the separately labelled run with the
absolute path exited 0, including the new unfocused-placement assertion
([log](vr-focus-fix-workspace-02.log)). All eleven subsequent clean sequential
client gates exited 0 ([true exits and log paths](vr-focus-client-01-results.jsonl)).

The first local Steam staging verifier exited 1 before switching because it
mistook generated journey output under `dist/_build` for package content
([log](vr-focus-install-01.log)). The corrected package-only verifier exited
0 and switched the tested export into `~/Games/quod`, preserving its prior
installation at `~/Games/quod-before-vr-focus`
([log](vr-focus-install-02.log)). The Steam shortcut still resolves to
`~/Games/quod`, its launcher bytes are unchanged, and the installed managed
assembly matches the tested export. Yan asked to continue later before the
installed-launcher active-headset check. No physical display observation has
been made, so that final verification remains pending. SteamVR was shut down
after the diagnostic session. Production delta for this follow-up is
`+3/-5=-2` in `Main.cs` and `+5/-3=+2` in `OpenXRInput.cs`, net zero lines;
the workspace assertion is test-only. No source or evidence log was committed.

## Steam shortcut and startup icon follow-up

Yan reported another SteamVR critical error but could not identify its timing.
The last recorded compositor fatal is still the 19:24:00 Vulkan
`UNKNOWN_ERROR`; the later report has no corresponding new fatal in the
available compositor log. The two observed fatals occurred after a Steam
shortcut launch, whereas the rebuilt client's native active-headset
qualification passed outside that shortcut. This difference suggested checking
the existing shortcut's VR classification; it does not establish the crash's
cause. The existing Quod shortcut had `OpenVR=0`. It was changed to `OpenVR=1`
without changing its target, and its icon was pointed at the identical artwork
in `~/Games/quod/steam/icon.png` rather than the old source-tree path. No new
shortcut or registry was created. The generated SteamVR manifest refreshed its
`image_path` to the installed icon when Quod was launched through Steam.

The installed Steam shortcut was then launched once with a disposable profile.
SteamVR identified `~/Games/quod/quod.bin` as the existing
`steam.app.3208097213` OpenXR scene. Its compositor remained running for the
84.7-second scene session and logged no new fatal; the client log contains no
missing-XR-viewport warning ([Steam launch and runtime logs](vr-steam-shortcut-01-result.json)).
The headset entered standby during the run, so this does not verify active-HMD
display or eliminate the earlier compositor crash. The initial OpenXR loader
attempt in the installed run log failed before a subsequent instance succeeded;
that sequence is retained in the log. The disposable test process was ended
deliberately, not counted as a normal-exit gate. Steam's `-shutdown` command
returned 0 while Steam and SteamVR remained active; ending the test's SteamVR
monitor with `SIGTERM` returned 0, after which they exited. The temporary
profile argument was then removed atomically; verification exited 0 with the
installed icon, `OpenVR=1`, empty launch options and no test process. Steam was
restarted. Yan's saved identity was not used.

The existing desktop and VR login card already use the bundled Quod icon.
The workspace test now asserts that the first visible, tracked XR workspace
contains that icon before sign-in or input focus. The targeted Godot build and
workspace run both exited 0 ([build](vr-icon-build-01.log),
[workspace run](vr-icon-workspace-01.log)). This is a test-only addition; the
production source delta remains `+8/-8=0` across `Main.cs` and
`OpenXRInput.cs`. No normative documentation sentence changed in this
follow-up. The active-HMD Steam shortcut launch remains unverified.

Yan's next headset attempt did not reach Quod. SteamVR started at 22:28:42,
and Steam itself exited at 22:29:08; its server then logged `Lost master process
2053581 for an unknown reason. Quitting all immediately.` No Quod launch,
new compositor fatal, kernel GPU fault or coredump appears in this interval.
The Vive USB disconnect at 22:29:31 followed SteamVR's exit by 23 seconds,
so it did not initiate that shutdown. The prior Steam process had been started
inside a diagnostic tool session that was no longer available for inspection;
whether that session caused Steam's exit is unproven. The failed attempt's logs
remain in [the baseline result](vr-steam-baseline-failure-01-result.json).

Steam was restarted in a detached session whose launcher has parent PID 1.
A separate SteamVR-only launch exited 0 from its command, with no Quod launch;
Steam, the SteamVR server, monitor and compositor were all still running 42
seconds after monitor startup, beyond the prior 22-second shutdown point.
The headset was in standby, so this establishes process liveness only, not
physical display stability. No source or normative documentation changed.

## Saved-identity VR startup failure

Yan's later SteamVR-lobby launch on 2026-11-10 showed black in the headset and
no Quod logo. Its installed run log emitted 1,503 `No viewport was marked with
use_xr` warnings; SteamVR's compositor dumped and restarted at 22:37:23
([retained failure logs](vr-saved-startup-failed-01-result.json)). The client
started XR in `Main._Ready`, then its automatic saved-key sign-in called
`Connect`, whose `CloseSession` stopped XR. That immediate stop explains the
missing viewport and black Quod view. The earlier empty-profile VR
qualification did not exercise this path. The available evidence does not
establish whether Quod also caused the compositor dump.

`CloseSession` now retires signed session work without stopping local XR
presentation; `CloseApplication` stops XR explicitly. The native qualification
asserts that XR survives session cleanup. The build and export exited 0
([build](vr-session-lifetime-build-01.log),
[export](vr-session-lifetime-export-01.log)); all eleven clean sequential client
gates exited 0 ([true exits and logs](vr-session-lifetime-client-01-results.jsonl)).
The standalone native OpenXR qualification exited 0 with an empty disposable
profile ([log](vr-session-lifetime-openxr-01.log)). A disposable profile with a
saved key was then created, and its native OpenXR qualification also exited 0
([seed](vr-saved-startup-seed-01.log),
[saved-profile run](vr-saved-startup-openxr-01.log)).

The tested export was switched into the existing local Steam installation;
the prior installation remains at `~/Games/quod-before-vr-session-lifetime`.
The Steam shortcut still resolves to that installation. The first installed
launcher diagnostic omitted Godot's `--` separator, so it did not use the
disposable profile or qualification mode; it was deliberately terminated
(`SIGTERM`, exit -15) after 52 seconds, and its log is retained
([failed diagnostic](vr-session-lifetime-installed-launcher-01.log)). Yan's
default saved identity file kept its 2026-11-07 modification time. The
corrected installed-launcher invocation used the saved disposable profile and
exited 0 ([exit](vr-session-lifetime-installed-launcher-02-exit.json),
[result](vr-session-lifetime-installed-launcher-02-result.json),
[log](vr-session-lifetime-installed-launcher-02.log)): XR remained active
through cleanup, all three cycles received 90 fresh tracked stereo frames and
drew the scene. The headset was in standby (`high=0`), so this does not prove
the logo appeared in the physical display or rule out a future compositor
failure. The installed shortcut's earlier 84.7-second runtime test remains
separate evidence; this saved-profile check used its installed launcher
directly. Its installed run has no missing-XR-viewport warning, compared with
1,503 in Yan's failed run; SteamVR's compositor remained running without a new
recorded fatal after the qualification.

Production delta for this uncommitted follow-up is `+5/-7=-2` lines in
`Main.cs` and `+5/-3=+2` in `OpenXRInput.cs`, net zero lines against HEAD.
The two new native assertions are test-only. No normative documentation
sentence changed in this saved-identity fix; the earlier README changes are
quoted above. The local logs remain uncommitted at Yan's request.

## VR controls on the opening form

On 2026-11-11 Yan confirmed that the installed client showed the Quod icon and
opening sign-in form in the headset, but neither green SteamVR Vive wand appeared
there. SteamVR's server log shows both wand devices and Quod's Vive binding.
The opening form had no signed controller projection: `Main` installed a
mapping only from `controller_preferences_view` after setup, while the existing
controller owner refuses both model appearance and clicks when mapping is
absent. This is why a tracked wand could not operate the form needed to reach
those settings.

The existing controller owner now starts with a local Vive mapping containing
only the native GUI trigger-selection gesture and the existing digest-verified
Vive model. The model's exact bytes are bundled in the export and checked by
the same `StaticGlb` and `RenderModels` owner used for signed appearances.
Signed settings replace the startup mapping; withdrawal while signed in still
disables controllers, and disconnect restores the local sign-in mapping.
Tracked grip models remain visible when input focus is absent; a missing aim
pose still cancels clicks, and a missing grip pose hides that wand. Startup
controls cannot dispatch menu, travel or ontology actions. No new process or
controller executor was added.

Focused build, injected controller and workspace runs exit 0
([build](vr-signin-controls-targeted-02-build.log),
[controller](vr-signin-controls-targeted-02-controller.log),
[workspace](vr-signin-controls-targeted-02-workspace.log)). The exported
controller run exits 0 and checks both the packaged model's digest and native
form capture ([log](vr-signin-controls-client-01-controller-input.log)).
The final clean sequential client campaign has 13 true child exits of 0:
JavaScript, clean core and Godot builds, core, export, package contents, icons,
exported controller input, exported workspace, signed GUI, spaces, navigation
and local backup ([results and full logs](vr-signin-controls-client-01-results.jsonl)).
No server source changed: the earlier EUnit 0 (4,353), CT 0 (150), xref 0 and
Dialyzer 0 remain the server gate evidence
([postphase report](../../ontology-references-phase2-20261110/postphase-report.md)).

Failed attempts are retained: controller run 01 exited 1 at an obsolete
focus-hides-model assertion ([output](vr-signin-controls-controller-01.log));
run 02 exited 1 because the source runner reused the prior compiled assembly
([output](vr-signin-controls-controller-02.log)); targeted build 01 exited 1
at `CS1061` while the grip-tracking refactor still used an interface key
([output](vr-signin-controls-targeted-01-build.log)); export 01 exited 1 at the
sandbox local-socket `ERR_CANT_CREATE`
([output](vr-signin-controls-export-01.log)). The separately labelled export
02 exited 0 with local-socket access
([output](vr-signin-controls-export-02.log)). The exported injected-controller
gate logs two Godot headless popup-signal disconnect diagnostics during its
existing popup test; its assertions and child exit are 0, and the source-run
controller check has no such diagnostics. They are not evidence of a physical
headset image.

The exact new or changed README sentences are: "Before signed settings arrive,
the bundled Vive model and a local trigger selection let either wand use the
native sign-in and setup controls; menu and travel gestures remain unavailable."
"The signed controller projection then replaces those startup controls with
its descriptions, roles, bindings and appearance admission." "**Tools ▸
Connected controllers** offers session-only source choices; saved preferences
still use ordinary offered forms." "XR input requires a running, Focused OpenXR
session, current head/controller tracking and the visible desktop window;
before sign-in, it can select only native GUI controls." "Tracked controller
models remain visible without input focus while the XR session is running and
the desktop window is visible." No other normative documentation sentence
changed in this follow-up.

Against HEAD, production source changed by `+8/-0` lines in `Core/Controllers.cs`,
`+8/-7` in `Main.cs` and `+11/-7` in `OpenXRInput.cs`, net `+13` lines; the export
preset changes one line in place. The bundled, digest-matched existing model is
1,114,152 bytes. All 196 export files hash-match the guarded local Steam stage
([stage result](vr-signin-controls-stage-01.json)). Yan's old Quod process is
still running, so the staged build has not yet replaced `~/Games/quod` and no
physical wand observation of this new build is claimed. No source, asset or
evidence log was committed.

The staged build was subsequently installed at `~/Games/quod` after closing
the old Quod window through its normal window-close request. The prior
installation is retained at `~/Games/quod-before-vr-signin-20261111`. The
switch exited 0 and the engine, pack, managed assembly, launcher and Steam
shortcut target hash-verified ([switch result](vr-signin-controls-install-01.json)).
The stage had copied `last-run.log` before the old process exited, so the
switch result correctly records `last_run_preserved: false`. I then restored
the complete final user log from the retained installation and verified its
hash and contents against the installed copy
([correction result](vr-signin-controls-install-log-correction-01.json)).

The first installed native OpenXR qualification exited 1
([output](vr-signin-controls-installed-openxr-01.log),
[exit](vr-signin-controls-installed-openxr-01-exit.json),
[cycle result](vr-signin-controls-installed-openxr-01-result.json.cycle1.json)).
SteamVR reported `Synchronized` with `can_render=false`: the qualification
recorded 90 fresh tracked head frames and two stereo views, but zero scene
draws and no wand poses. Its assertion that the hidden desktop container
keeps rendering failed. This does not establish a controller or rendering
failure with an active headset; it also does not establish physical success.
The qualification used a disposable profile and restored the user's final
`last-run.log` afterward. A headset-active native check remains outstanding.
No source, asset or evidence log was committed.

Yan then wore the headset with both wands on. The separately labeled
installed check 02 exited 0 and recorded three `Focused`, renderable cycles,
with both Vive sources supplying high-confidence aim and grip poses. Its
launcher redirected the detailed output to `last-run.log`, leaving the
separate stdout log empty. This is a logging defect in that evidence capture,
not a failed application assertion
([exit](vr-signin-controls-installed-openxr-02-exit.json),
[result](vr-signin-controls-installed-openxr-02-result.json)). The user's
normal launch log was restored.

I repeated the native check under the new label 03 and retained the actual
launcher log before restoring the user's log
([full output](vr-signin-controls-installed-openxr-03.log),
[exit](vr-signin-controls-installed-openxr-03-exit.json),
[result](vr-signin-controls-installed-openxr-03-result.json)). Exit 0 and
`M4_XR_PASS` cover three native cycles. Each was `Focused`, `can_render=true`,
with stereo scene draws (2, 3 and 15); both Vive sources had high-confidence
aim and grip poses for 88–90 of 90 frames per cycle. The startup mapping
recognized both as `htc_vive_controller`, acquired the bundled template and
created two model instances per cycle. All six instances were released at
the end of their cycles. The native run had 23 passing assertions. Godot
emitted a spatial-discovery signal-disconnect diagnostic and one OpenXR
interaction-profile RID leak diagnostic at process exit; the native run still
exited 0. These diagnostics were retained and do not claim a headset-pixel
inspection or a physical trigger press. The source and exported injected
controller checks cover native GUI trigger capture and the startup mapping.
No further source or normative documentation sentence changed; the production
line delta remains net `+13` against HEAD. No source, asset or evidence log
was committed.

## VR sign-in server change and Options

Yan reported that the saved identity could not sign in after the server change,
the `Details` control could not be clicked in VR, and the key error was unclear.
A read-only comparison found that the configured server was reachable and its
current public TLS key differed from the one saved for that address. The
user's private key was not read or changed. The existing pin check correctly
stopped sign-in; the UI put its explicit trust choice under a vague, flat
`Details` link and disabled every button while a connection was busy.

The sign-in card now puts a 48px-minimum, non-flat **Options** button near its
top, keeps that local toggle enabled during connection, and reveals the
existing trust action as **Trust this server**. The changed-server message
distinguishes the server from the user's key and says exactly where to go;
the post-choice message says what signing in will accept. Trust remains an
explicit local choice. The existing card now uses Godot's native vertical
scroll owner so larger text or a smaller window does not strand controls.
The shared button-sizing owner preserves a caller's larger minimum. These
choices follow Meta's [button guidance](https://developers.meta.com/vr/design/buttons_bp/)
for specific labels, visible feedback and sufficiently large targets, its
[ray guidance](https://developers.meta.com/vr/design/raycasting_usage/) for
indirect controller selection, and Godot's
[ScrollContainer behavior](https://docs.godotengine.org/en/stable/classes/class_scrollcontainer.html).

The initial targeted export/build passed. Targeted workspace 01 exited 1 at
the new Options target assertion ([output](vr-server-trust-targeted-01-workspace.log));
the sizing callback had reset its requested minimum. Export 02 exited 0,
but workspace 02 exited 1 at the same assertion, recording `min=(131, 44)`
despite an on-screen `340×56` rectangle
([output](vr-server-trust-targeted-02-workspace.log)). After preserving the
caller's actual minimum, export 03 and workspace 03 exited 0
([output](vr-server-trust-targeted-03-workspace.log)). Export 04 and an offline
new-key startup exited 0
([startup output](vr-server-trust-targeted-04-startup-new.log)). An attempted
scratch-key changed-server run against the reachable server was rejected by
automatic approval review because it might authenticate or create server-side
state. No such run or server mutation occurred.

The offline native recovery check was extended instead. Export 05 exited 0;
workspace 05 exited 1 because the sign-in card had no scroll owner and its
`Create my key` target was below the smaller desktop viewport after leaving
VR ([output](vr-server-trust-targeted-05-workspace.log): target centre `y=864`
in an 800px window). After the scroll fix, export 06 and workspace 06 exited
0 ([output](vr-server-trust-targeted-06-workspace.log)). That run pressed the
actual Options and trust controls with native pointer events, seeded only a
disposable local profile with an obsolete server match, and verified that the
choice removed that match while keeping the same saved key and enabled Sign in.

Clean sequential client campaign 01 stopped at the icon gate: JavaScript,
core clean, Godot clean, core, export and package-content exited 0; icons
exited 1 with `System.ArgumentException: Basepath argument is not fully
qualified` because the campaign invoked a source-project icon check through
the exported executable
([results and logs](vr-server-trust-client-01-results.jsonl),
[failure output](vr-server-trust-client-01-icons.log)). Campaign 02 used its
existing source runner and all 15 true child exits were 0: JavaScript,
both clean steps, core, export, package contents, icons, controller input,
workspace, new-key startup, saved-key startup, local GUI, spaces, navigation
and local backup ([results and full logs](vr-server-trust-client-02-results.jsonl)).
The exact installed binary also passed an offline native workspace check with
a disposable profile, exit 0
([output](vr-server-trust-installed-workspace-01.log),
[exit](vr-server-trust-installed-workspace-01-exit.json)). No server source
changed; the earlier EUnit 0 (4,353), CT 0 (150), xref 0 and Dialyzer 0
evidence remains [here](../../ontology-references-phase2-20261110/postphase-report.md).

Against HEAD the production C# source is now net `+19` lines: the previous
VR startup fix was net `+13`, so this sign-in refinement added net `+6`.
`Main.cs` is `+30/-23`; `SpatialGui.cs` replaces one line in place.
The exact README sentences changed in this refinement are:
"Server, public identity, storage details and encrypted backup controls
remain inspectable in **Options** near the top of the sign-in card."
"If the server's identity changes, sign-in stops and explains that the
user's key is unchanged; **Trust this server** is an explicit choice in
**Options** before signing in again."
"The XR workspace uses the same controls and drafts in a reflowing 1200×800
surface, with connection and identity options behind a visible control near
the top of the sign-in card."
"That control stays available during connection; its server-trust action
remains an explicit choice."
"Verbose identity/controller references and retired setup controls remain
in **Options**; the working form keeps the primary surface."
"The sign-in card scrolls vertically when enlarged text or a smaller window
would otherwise hide its controls."
No other normative documentation sentence changed in this refinement.

The 196 export files hash-matched the new Steam stage
([stage](vr-server-trust-stage-01.json)). The first switch command stopped
before any rename with `Quod is running; local switch stopped`: it found the
running `quod.bin` engine that an earlier launcher-only process check missed.
The verified Quod window accepted `WM_DELETE_WINDOW` and its process exited
normally ([close result](vr-server-trust-close-01.json)). The staged log was
then refreshed from the final user log; it had grown from 571 to 868 bytes
([refresh](vr-server-trust-stage-log-refresh-01.json)). A second switch
command stopped before any rename when `ps` returned exit 1 for no matching
process and the script treated it as an error. The corrected, separately
labeled switch 02 exited 0 and hash-verified the installed engine, pack and
managed assembly while retaining the launcher, Steam artwork and final user
log ([install](vr-server-trust-install-02.json)). The previous installation
is retained at `~/Games/quod-before-server-trust-20261111`; Steam's existing
shortcut resolves to `~/Games/quod/quod.x86_64`. The user's saved identity
and remembered server match were not edited. No source, asset or evidence log
was committed.

## SteamVR compositor overflow after sign-in

Yan's 00:59 Steam-lobby launch reached the sign-in form, then the HMD went
black. The installed Quod process remained alive, while SteamVR's compositor
aborted at 00:59:35 with `Vulkan transfer ring buffer overflow; transfer size
2315040!`; the same assertion and size occurred at 22:37:23 before this
sign-in refinement ([retained excerpts](vr-compositor-overflow-01-crash-excerpts.log)).
The [Valve SteamVR Linux issue](https://github.com/ValveSoftware/SteamVR-for-Linux/issues/1006)
records this exact assertion and size on SteamVR 2.19.2, including runs with no
game; a reporter traced a floor-mesh upload path inside SteamVR. That matching cause
is supported by the logs, but the local logs alone do not identify the
compositor's internal upload caller.

I copied the original local `steamvr.vrsettings` byte-for-byte to
`steamvr.vrsettings.before-quod-overflow-20261111`, then set the existing
dashboard's `enableLTCReflections` to `false`, following the issue's reported
workaround. The failed Quod process and SteamVR monitor exited; SteamVR
restarted and retained the setting. With an empty disposable profile, the
installed Quod engine remained running for all 180 one-second samples, and
the same compositor PID survived for the entire 185.38-second probe
([result](vr-compositor-overflow-01-result.json),
[client output](vr-compositor-overflow-01-installed.log)). The probe ended
Quod deliberately with SIGTERM (`-15`); that is not a normal application exit.
The user's saved identity and original installed `last-run.log` were unchanged.
No headset image was observed for this probe, so it does not verify physical display or
exclude a later SteamVR crash. No Quod source or normative documentation changed;
no client or server gate was rerun, and no commit or fleet action occurred.

## Steam UI error before a Quod launch

Yan's next screenshot showed Steam's `Shared SteamUI` content error reading
`AddMinimumCompositionStateRequest`. Steam's `webhelper_js.txt` recorded that
exception six times at 13:28 and 13:29, alongside twelve `ConfigContext
without a provider` errors ([retained excerpts](steam-ui-error-01-excerpts.log)).
SteamVR started at 13:27, but neither Steam nor SteamVR recorded a Quod launch
in this session. The compositor stayed running and shut down gracefully when
SteamVR was closed at 13:31; the earlier Vulkan assertion did not recur.

The Steam client shutdown request exited 0; the subsequent process check
exited 1 because no Steam process remained. The detached Steam restart and
SteamVR launch each exited 0. After more than a minute, Steam, SteamVR's
server, compositor and monitor were running; the exact JavaScript error counts
had not increased. This verifies a fresh Steam UI startup, not the particular
interaction that first triggered the error or an HMD image. The local
`enableLTCReflections=false` setting remained in place. No Quod source,
installed client, saved identity or normative documentation changed, no gates
were rerun, and no commit or fleet action occurred.
