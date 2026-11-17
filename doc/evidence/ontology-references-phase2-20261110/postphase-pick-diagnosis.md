# Native pick timing diagnosis

The unchanged clean campaign 01 fails at `PickSpace` in `m3-entered`.
The first instrumented full navigation journey passes (exit 0); it does not
establish a correction. The second instrumented journey reproduces the timeout
(exit 1), with its disposable server exiting 0.

At injection, world acceptance is true but the camera is still at
`(0, 0.07405374, -51.285454)`. The projected point is `(587.11224, 387.34653)`
and the actual camera ray returns no subject. At timeout, the camera is at
`(1.5169268, -1.2802627, 6.7673435)`; the same occurrence projects to
`(529.61316, 425.9295)` and its ray returns the exact intended leaf. The native
scene rectangle and viewport remain 1200 by 800. The recursive contents and
independent matrix checks passed before the click in both runs.

`ScenePanel.RequestFraming` queues `FrameScene` and `MountCamera` on the native
deferred-call queue, after native label shaping. `PickSpace` awaited
`SceneTree.ProcessFrame`, which can resume before that deferred callback.
Its input could therefore use the previous camera while the new marks already
exist. The original mouse selection correctly refuses that ray.

The test helper now awaits a callback behind the already queued framing work
on the same native queue, with asynchronous continuation after processing. The
actual native click, exact-subject assertion and five-second selection wait are
unchanged. There is no input retry, extra frame loop, sleep, camera override,
production readiness path or deadline change. Temporary observations are removed.
Focused and clean client verification must establish the final result separately.

Full observations: `postphase-pick-diagnostic-01-journey/m3-entered.log` and
`postphase-pick-diagnostic-02-journey/m3-entered.log`. The temporary test diff is
`postphase-pick-diagnostic.patch`. Diagnostic build 01 exits 1 on incorrect C#
interpolation escaping; build 02 exits 0 after that diagnostic-only correction.
