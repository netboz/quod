# Initial tracked-pose placement

The existing XR camera owns tracking readiness. A new panel waits until its
tracking state is TRACKING. Its existing tracking notification schedules placement
on the next existing before-render observation, after the camera has applied the
pose. No timer, new frame loop, domain transition or GUI queue was introduced.
An existing world-stable panel remains in place through tracking interruptions.
Closing or leaving XR before the callback runs cannot resurrect the workspace:
showWorkspace checks the current model and immersive state.

Final client172/0, build exit0; source manifests unchanged. Windowless software
Chromium:34 boolean checks passed, including tracking wait, close during wait,
placement from the updated pose, left/right-handed orientation, XR registrations,
material graph parse/build, real pointer/keyboard and disposal obligations.
Full console assessed separately: no JavaScript or unexpected network errors;
one fixture favicon404. Native VR was not started. Driver and Vite terminated
by their owning harness; their intentional termination codes are cleanup, not
test exit codes. Harness true exit0.

This addresses initial placement readiness. Actual headset startup/comfort
remains part of the deferred hardware acceptance.
