Coordinator evidence addendum, 2026-10-29. This is a coordination addition. Prior frozen source, handoffs and failed receipts remain unchanged. M4 is uncommitted and full acceptance remains open.

Earlier coordinator wording about stereo frames qualified pose delivery, viewport state and local lifecycle assertions. It did not establish rendered XR output. The actual API trace for `native-vive-api01` has zero swapchain creation and 271 `xrEndFrame` entries with zero layers. Earlier pose-only runs must remain unqualified for rendering.

The subsequent development03 correction gives the XR renderer ownership after container visibility changes. Its exact 91 staged inputs and 196 export outputs were independently hashed, and both following campaign commands point to that export:

- `native-simulated04`: one swapchain created and destroyed; 269 image acquisitions, waits and releases; 269 EndFrame entries with one layer and two with zero layers.
- `native-vive-input01`: one swapchain created and destroyed; 3,568 image acquisitions, waits and releases; 3,568 EndFrame entries with one layer and one with zero layers.

These are argument-free call counts and layer-count arguments from the official API-dump layer. The layer does not record returned result codes. They establish the observed submission lifecycle, with successful image content, headset display, comfort and complete native teardown still requiring their applicable evidence. Both campaigns remain failed, with pinned-engine teardown errors retained.

Both actual wand profiles are now `/interaction_profiles/htc/vive_controller`. The first input observation reports neither tracked poses nor completed button releases. Yan confirmed both wands are on a table; existing calibration is unchanged. No wand gesture or mapped movement acceptance follows from profile discovery.

The four live inputs changed since development03 are Main, the client README, ExportChecks and OpenXRChecks. In particular, failed qualification now uses the shared CloseApplication owner while retaining exit code1. These later bytes require fresh affected qualification and a new final freeze.

[Independent API verification](/home/yan/src/quod_worktrees/pearl-stone/doc/evidence/godot-m4-r2-coordinator-20261029/render-api-verification-01.json)

The coordinator's initial parsing attempts are retained separately under `_build/godot-m4-r2-coordinator-20261029`. The corrected parser recognizes the actual return-type/function call headers and hexadecimal layer-count arguments. The earlier decimal-only layer-count fields must not be used. No product tests were rerun.

The two historical desktop shutdown stalls remain unresolved and independent of this XR work. The new withheld-TLS-reply close test passed its controlled cancellation case; it does not resolve those failures. No commit, full M4 credit or M5 launch is authorized by this addendum.

