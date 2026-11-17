# Pinned engine and runtime ownership

These are causal observations against the exact Godot4.7.2 official binary and
matching tag source, not permission to replace the pinned engine. No Godot engine
patch, custom GDExtension, Rust bridge, profile substitution or diagnostic
suppression is installed.

## Render ownership corrected in the existing client owner

Godot's SubViewportContainer visibility notification sets its child viewport to
UPDATE_DISABLED when hidden. Its stretch layout also refuses child view-count
changes. Separately, Viewport.set_use_xr(false) resets renderer view-count while
the node can retain its previous stereo count; reentry can then skip updating
an apparently unchanged node layout. The old desktop camera also remained
replaced by the XR camera after consumer pause.

ScenePanel now owns the complete transition: release stretched layout; set the
desktop container's presentation visibility; set XR layout or explicit mono
view-count and original desktop camera; finally install the desired update mode.
An unchanged mode is a no-op. OpenXRInput uses that owner. The engine retains
one native session across consumer pause/reentry, so its sole action set remains
active for that engine lifetime; detached sources/gestures cannot dispatch input.
Disabling the final action set had separately produced an active_sets.empty
engine error in native-simulated02.

native-simulated01 exposed repeated framebuffer layer/view-count errors. The
first attempted correction still failed its mono restoration assertion.
native-simulated03 passed pose/layout assertions but rendered nothing because
the new helper placed visibility last. The official API dump in
native-vive-api01 proved zero swapchains and269 no-output warnings. These runs
remain failed and do not qualify pixels. After the ordering correction,
native-simulated04 records real draw work, one swapchain and269 two-view layer
submissions with matching image acquisition/release and eventual destruction.

## Interaction-profile RID leak: engine collection owner

In matching modules/openxr/openxr_interface.cpp, _load_action_map creates an
interaction-profile RID, then tests interaction_profile_array.has(ip) and pushes
to that same local resource array. The local array contains profile Resources,
not the member interaction_profiles RID vector. free_interaction_profiles
iterates the member vector, which never received that RID. The missing owner
registration is the demonstrated cause. A correct upstream change must retain
each new RID in the member collection and free it through that existing owner.

Minimal engine-only GDScript repros contain no Quod code: zero configured
profiles emit no profile leak; one unchanged authored Vive profile emits exactly
one leaked OpenXRAPI::InteractionProfile RID. Native client runs reproduce it.
The raw engine source and exact source hashes are retained separately.

## Spatial-discovery diagnostic: unmatched engine subscription

OpenXRSpatialMarkerTrackingCapability.on_session_created returns immediately
when spatial_marker_tracking_ext is false. Its on_session_destroyed always
disconnects spatial_discovery_recommended, including that unsupported-extension
case where no connection was made. The matching plane capability has its own
support guard. Minimal engine-only and actual client runs reproduce the marker
diagnostic. The responsible engine capability must pair its real connection
lifetime with destruction; suppressing the error in Quod would not release it.

Primary pinned sources:

- https://github.com/godotengine/godot/blob/4.7.2-stable/modules/openxr/openxr_interface.cpp
- https://github.com/godotengine/godot/blob/4.7.2-stable/modules/openxr/extensions/spatial_entities/openxr_spatial_marker_tracking.cpp
- https://github.com/godotengine/godot/blob/4.7.2-stable/scene/gui/subviewport_container.cpp
- https://github.com/godotengine/godot/blob/4.7.2-stable/scene/main/viewport.cpp

## Session stopping and failing close

The engine's destroy_session calls xrEndSession while running, without itself
requesting STOPPING. Its uninitialize only releases interface consumers; it
does not destroy the native session and cannot implement native restart.
The application uses the existing OpenXRApiExtension procedure seam to request
exit, observes SessionStopping, resumes at the next engine processing boundary,
checks running=false and then uninitializes. Native API entry observations show
RequestExitSession before EndSession and eventual child/session/instance
destruction. API dump does not report returned result codes; app checks and
engine/runtime diagnostics provide separate evidence and limits.

The intentional direct-quit minimal engine repro emits SESSION_NOT_STOPPING.
The first timed wand test failed its assertions and the exported test error
catch used that same direct engine quit, reproducing the error. Main's existing
close method now accepts the requested exit code; the catch awaits it with1.
The failure remains a failure while resource retirement uses the shared owner.
This correction does not explain either historical desktop stall.

## Native pose names and head validity

The pinned interface translates authored action grip_pose into tracker pose
grip. The authored action/profile stays unchanged. The adapter, three injected
XRServer fixture callers and observation consumers use that one canonical key.
The retained old adapter fails actual native GUI capture with canonical fixtures;
the corrected adapter passes the same consumers. Observation05 independently
witnesses canonical aim/grip and side-grip edges from both real Vive wands.

Pinned OpenXRInterface.process sets the head pose even with confidence None;
actual startup reports HasTrackingData=true in that state. The old gate therefore
establishes calibration from an invalid sample. The pre-head negative control
records90 invalid startup frames and invalidHeadCalibration true; the corrected
native case records the same90 invalid frames with that flag false. Input and
calibration now also require non-None head confidence, consistent with the
existing source gate. No new tracking profile or high-confidence claim for low
samples is introduced.

This does not establish final01's zero-swapchain cause. Its viewport is Always/
stereo with a primary running interface; native shouldRender/render-view validity
was not captured as returned flags. Its render failure remains failed and
unattributed beyond those observations. Later valid human poses and simulator
submissions do not erase it.
