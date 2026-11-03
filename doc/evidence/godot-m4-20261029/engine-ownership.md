# Engine ownership and runtime boundary

The pinned Godot4.7.2 source was inspected directly. Download commands and
content hashes are retained in the input receipts; original C++ source is
retained separately with the immutable output boundary.

`Viewport::_update_mouse_over` returns for a viewport attached through a
SubViewportContainer. A standalone SubViewport receives its local pointer
position. The shared GUI therefore renders one ordinary Control tree into a
standalone viewport and displays its texture for desktop and XR. Repeatedly
grabbing focus on the display texture cancels a pressed child button before
release; focus belongs to the real child Control. The retained native pointer
failures and corrected owned-window case distinguish both causes.

`OpenXRInterface::uninitialize` frees its trackers, action sets and interaction
profiles, but does not destroy the native OpenXR session. Reinitializing against
that retained session fails the engine's `session != null` guard. The adapter's
pause/reentry boundary releases its own observers, poses, captures and render
leases, disables its action set and retains the engine session for its real
application lifetime.

Application shutdown subscribes before calling the standard OpenXR
`xrRequestExitSession` function obtained through Godot's public
OpenXRApiExtension. It waits for the owning engine's SessionStopping notification
under an absolute deadline, resumes at a processing boundary after the engine's
`xrEndSession`, and only then uninitializes. It never destroys engine-owned
native handles. Errors remain visible and fail shutdown qualification.

This explains the responsible ownership boundary; it is not native teardown
acceptance. The installed service fails its dynamic loader before a session can
be created. The retained QUO-27 SESSION_NOT_STOPPING, spatial-discovery teardown
and interaction-profile RID obligations remain open until direct replacement
runtime observations establish their disposition.

Primary source locations: [Godot viewport](https://raw.githubusercontent.com/godotengine/godot/4.7.2-stable/scene/main/viewport.cpp),
[OpenXR interface](https://raw.githubusercontent.com/godotengine/godot/4.7.2-stable/modules/openxr/openxr_interface.cpp),
[OpenXR API](https://raw.githubusercontent.com/godotengine/godot/4.7.2-stable/modules/openxr/openxr_api.cpp).
