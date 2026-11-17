# SteamVR handoff diagnosis268

The new observation locates the immediate admission stop at the runtime's
`xrWaitFrame.shouldRender=false`. The frame loop continues and the primary
stereo viewport remains enabled. No demonstrated production client defect or
correction resulted. Why SteamVR withholds visibility remains unresolved;
current headset presence was not observed. This was diagnosis, not a human
opportunity, and it did not reach READY.

The single fresh invocation observed, over the original30-second admission
interval:

- 1682 FramePreDraw and1682 FramePostDraw notifications, with1682 positive
 increasing native predicted display times; zero zero-time or regression samples.
- OpenXR initialized/running/primary, `quod_inputs` active, `UseXR=true`, two
 stereo views, terminal update mode `Always` and size1852×2056. No disabled,
 mono or non-primary samples. The desktop container was intentionally hidden.
- `CanRender=false` in all1682 samples; state remained `Synchronized`.
 Head tracking was High, both controller profiles were none/untracked, and
 presence support was false, reported as unknown rather than assumed present.
- Signed world accepted, mapping available, authentication unexpired with
 867682ms remaining. Minimum fresh key/account/starting-space setup only;
 no Library, Enter, Leave, Preview, Save or human task.

The initial and final managed observation ran on thread1. The counter records
existing rendering-signal observations, not direct native call counts. In the
pinned engine, predicted time is read from the frame state populated by successful
`xrWaitFrame`; `CanRender` requires instance/session/running and its `shouldRender`
flag. Those bindings establish continuing successful wait-frame progress and
runtime refusal to render in this invocation. `xrBeginFrame`/`xrEndFrame` calls
and submitted layer counts were not directly counted. Native source submits
zero layers when rendering is refused; that source trace is distinct from a
measured submission count. The OpenXR contract distinguishes synchronization
from visible presentation. See the
[Khronos specification](https://registry.khronos.org/OpenXR/specs/1.0-khr/html/xrspec.html#session-lifecycle).

The responsible path remains Main's offered Start action -> OpenXRInput.Start
-> ScenePanel.PresentXR -> native primary-interface frame loop. Focus/tracking,
neutral, capture, authorization and expiry guards were unchanged. Pinned
RendererViewport explicitly admits a hidden XR viewport when its interface,
update mode and dimensions permit it. No mono, visibility or focus workaround
is justified by this evidence.

Saved263 and267 runtime records both show OpenXR scene admission and successful
Vive binding loading.263 entered standby, then left standby before its positive
Focused/stereo/controller observation.267 entered standby and did not leave
until disconnect. The new268 interval likewise logs standby while the
observed frame pump progresses. SteamVR compositor aggregate presents are
retained as its own statistics, not relabelled Quod XR layer submissions.

A separate concrete startup failure is present in267 and268: the SteamVR-spawned
vrmonitor aborts because it cannot load Qt platform `wayland;xcb`; only `xcb`
is listed. The named inherited current environment has
`QT_QPA_PLATFORM=wayland;xcb`.263 lacks that stderr failure. No intervention
tested whether this causes the standby/admission behavior. The next bounded
runtime question is whether that helper startup fault affects admission, while
obtaining contemporaneous presence evidence. A per-application Qt environment
correction or additional presence observation needs its own concrete authorized
scope; no setting, runtime process or product change was made here. A generic
restart or identical launch would not answer this question.

Root's compound-counter and240.387-second human-to267 timing reports were fully
read and incorporated. The earlier dashboard confirmation does not establish
presence during267's later gate. Yan was explicitly free to remove the headset
during268; its lack of visibility is not evidence of a broken worn-headset path.
The current presence extension is not active, so its fallback value was not
treated as a sensor reading.263's positive observation and pending1 profile,
all264–267 failures and the earlier human rejection remain literal.

The source-only diagnostic build has five phase exits0 and outer0, same98
production inputs,99 supplied. Only
[VrDiagnostic268.cs](../../doc/evidence/godot-steamvr-handoff-20261101/VrDiagnostic268.cs)
and removable ExportChecks dispatch differ. All production additions/removals
are0. The existing corrected supervision/live/fixture owners were copied
unchanged and their prior regression was reused. Current14 server resources,
qualified world-name object, saved drivers and fixture outputs are recorded.
No engine/runtime/core release rebuild, package refresh or old payload audit.

Both fresh owned processes are closed and must never be targeted again:

- Client PTY7862/PID3838713/start20500541/executable2050:4874372,
 address0x55f62bc57570: client1/wrapper1 at native-admission failure, both EOF,
 no reader or retirement failure. The observation completed; admission failed.
- Fixture PTY8581: one normal stop after client closure, child0/wrapper0,
 both EOF, no reader errors.

Original admission30/preparation180/participant1800/normal-close60/outer2100 and
authentic expiry were preserved. No participant interval began, host input,
focus request, replay, forced exit, second invocation or uncertain resubmission.
User-owned SteamVR was only observed read-only. SteamVR's own ordinary binding
creation is visible in its log; no agent command changed its configuration.

[result268.json](../../doc/evidence/godot-steamvr-handoff-20261101/result268.json)
SHA `dc71190abbd1de101ba31df76f741144d08c94dfd97086e298d88efea2049983`
binds25 small current receipts, source excerpts and bounded saved-log selections.
Raw evidence stays in private Data under `steamvr268-diagnostic01` and
`steamvr268-saved-evidence01`; parent directories0700/raw0600. No immutable seal
or broad verification campaign. Current full worker batches were read at launch
and closure boundaries; list-only is not consumption. Tracker radar reported no
matching item; no new item or blocked body write was attempted. The sole session
is ca84d4f8, actual Astra, effective backend effort unexposed. HEAD and empty
index remain as accepted; user source, old profiles and packages are preserved.
