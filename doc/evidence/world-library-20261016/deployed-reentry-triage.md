# Deployed reentry acceptance: input synchronization

`desktop-deployed-03` created two worlds, walked in both, returned to the lobby,
and reopened the generated-name world. It then timed out waiting for movement.
The stopped campaign and original harness are retained under
`_build/world-library-20261016/deployment-02/acceptance-desktop-deployed-03`.
No old volumes were deleted.

The initial collision hypothesis was not supported. Its final clipped contact
was the retained body's ordinary ground-support result, not evidence that a
nonzero movement command reached the native solver. The reentry sample also
showed "Loading terrain" after the harness had accepted readiness text.

The first bounded diagnostic reused the exact retained test account and world,
waited for the matching terrain manifest's completion acknowledgement and two
render frames, and captured the public signed control goals. It still timed
out: every transmitted drive was `vector(0,0,0)`. The harness checked
`document.pointerLockElement` but did not await the `pointerlockchange` event.
The production input controller clears held keys on that event, so an immediate
automated keypress can be cleared before its movement reaches the render loop.

The second diagnostic changed only that input synchronization: register the
capture-event promise before clicking, await the event, then await render
processing. The same ArrowLeft request reached the normal signed control path
as `vector(-2500,0,0)` and moved the same retained body 1.1260834751262383 metres
horizontally. No application code, terrain, pose, speed, deadline or collision
policy was changed. Full commands, delivery events, poses and DOM events are
retained in `deployment-02/reentry-diagnosis-02/observation.json`; the failed
first diagnostic remains beside it.

The acceptance harness now requires the current view's matching terrain
completion acknowledgement and render processing, then completed pointer
capture before pressing a key. The original creation, movement-distance,
return, reentry, no-error and empty-journal assertions remain unchanged.
`desktop-deployed-04` is a separately labelled campaign on the same deployed
image and fresh-v11 cluster; no reset or uncertain write retry is involved.
