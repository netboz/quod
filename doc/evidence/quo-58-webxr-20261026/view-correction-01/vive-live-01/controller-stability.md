# Controller stability observation

Yan reports: “It is not bad. I saw once my right controller flyng away from me.
More generally controllers movement is flickering a little”. This qualifies
his earlier confirmation that the lobby stays visible during head movement and
both controller models are visible. Controller stability is not accepted.

The real app exited its first immersive session after 9,452 stereo/tracked
frames, with one native end call and an end event. An open controller settings
panel intercepted the first attempted re-entry click. The native request count
remained one. Closing the panel through its existing Close control allowed a
new entry, reaching the presenting state in 451 ms. The new session recorded
377 stereo/tracked frames at the next saved observation. At final capture,
re-entry had reached 12,791 callbacks, of which 11,263 contained tracked stereo
poses. The other 1,528 callbacks did not establish tracked stereo; their cause
was not isolated. No application error or CSP violation was recorded.

## Verified upstream pose fault

[Same-frame distances](controller-distance-summary.json), calculated from the
native WebXR grip and head poses in the same reference space, reach 28.73 metres
for the right controller before exit and 103.15 metres after re-entry. The first
session's left controller stays within 0.98 metres of the headset in the retained
samples. The common reference-space transform cancels in these distances.
These values are observed before Babylon or Quod positions the model. The
right-controller runaway therefore already exists at the browser XR boundary.
This does not identify which native component originated the bad pose.

The retained first-session window also has 22 missing left grip poses and two
missing right grip poses out of 120 sampled frames. These are sparse samples,
not a measurement of per-frame flicker. Quod's existing controller scene hides
the model when its native grip pose is absent. That behavior can expose tracking
loss as flicker; it does not prove that every visible instability has this cause.
Babylon copies the native grip pose into its owned grip mesh; Quod parents the
governed model to that mesh. No second controller pose/model path was found.

## Bounded diagnostic and its limits

[A separate diagnostic](pose-diagnostic.js) observes the application's existing
native getPose calls for 360 frames, without adding a frame loop or replacing
returned poses. [Its receipt](pose-diagnostic.json) confirms restoration of the
original native method. All 360 left poses were null; all 360 right poses were
non-null and reported `emulatedPosition: false`, despite positions hundreds of
metres away. Yan subsequently confirmed both controllers were held in view of
the base stations with green LEDs and requested stopping the demo. That is a
human setup observation, not a measurement of the driver's optical confidence.

The diagnostic records the first grip request per source per frame. The earlier
sparse observer and Babylon may use different reference objects. Consequently,
the step magnitudes in [its numerical summary](pose-diagnostic-summary.json)
must **not** be interpreted as frame-to-frame tracking jumps: they mix reference
spaces. A later jitter capture must retain reference identity or compare
same-frame grip-to-head poses. Its callback intervals include instrumentation
and are not a rendering performance qualification. The verified runaway above
uses same-frame distances and is independent of this limitation.

## Native investigation scope

Continue native tracking investigation under [QUO-38](nimbalyst://QUO-38), with
physical GUI/controller acceptance under [QUO-24](nimbalyst://QUO-24). Preserve
[QUO-59](nimbalyst://QUO-59)'s controller adapter and governed appearance. The
startup and head-view correction in [QUO-58](nimbalyst://QUO-58) has reached real
entry, stereo frames, exit and re-entry; that is not a blanket physical pass.

The inspected local Monado Lighthouse device calls relation-history prediction
without a freshness check in `Device::get_pose`. The history extrapolates the
latest pose/velocity and retains its flags when asked for a later timestamp.
This is a plausible route for a stale moving controller to keep flying while
reported tracked. Runtime timestamps and incoming driver poses have not been
captured, so it remains a hypothesis, not the established root cause.

The local source also converts OpenVR's documented seconds-valued
`poseTimeOffset` with 1,000,000 while the receiving clock uses nanoseconds. That
unit mismatch is a separate source finding; its contribution to this run is
unproved. [Hashes](controller-diagnosis-inputs.json) pin the inspected files and
runtime binary; source-to-binary correspondence was not re-established here.

The next native trace should capture driver update timestamps, validity/tracking
flags, incoming position/velocity, requested prediction time and output position
for each owned controller. It must distinguish optical loss, stopped updates
and excessive prediction, and correlate them with a same-reference browser
trace. No runtime restart, driver patch, pose clamping, smoothing, security
change, ontology update or further reset was performed in this diagnosis.

## Stop and restoration

Yan requested stopping after confirming both controllers were held in view with
green LEDs. [Cleanup](result.json) exited successfully: the owned browser was
closed, owned runtime exited 0, owned ChromeDriver terminated as intended,
desktop geometry and the previous headset display state were restored, and only
the exact temporary certificate trust was removed. No unexpected child exit
occurred. The second session's final snapshot precedes browser shutdown; it is
not evidence of a second app-initiated end event. The first app exit remains
the measured native-session cleanup check.
