# Diagnostic observation ownership

Production application, engine and runtime inputs remain unchanged. Physical03 compiled successfully but was never invoked as a native case; its direct render-getter observation lacked established render-thread ownership. That is an observer qualification limit, not proof that the product accessed a wrong thread or caused Yan's failed view. Physical04 is the separately built correction to the diagnostic.

The pinned engine source is retained at `/data/quod-m4-vr-ca84d4f8-20261029/builds/engine-clean02/godot-4.7.2-stable`:

- `scene/main/viewport.cpp:1204` obtains the XR viewport dimensions/view count from the initialized primary interface.
- `servers/rendering/renderer_scene_cull.cpp:2749` obtains XR world origin and interface eye transforms. It deliberately ignores the camera node position, which may contain older tracking. Its optional camera-lock composition is recorded separately.
- `scene/3d/xr/xr_nodes.cpp:87` updates XRCamera from the adjusted head pose. `servers/xr/xr_pose.cpp:90` applies world scale and reference frame to that adjusted pose. Raw, adjusted, node and renderer values must not be treated as interchangeable.
- `servers/rendering/rendering_server_default.cpp:130` defers post-draw steps to the main thread for a separate renderer; the same steps emit FramePostDraw at229. `rendering_server_default.h:1216` executes a render callable on the server thread or queues it there.

The explicit `geometry` command awaits the existing model owner and a FramePostDraw notification, captures all node/head/model values on the Godot context, then awaits one `RenderingServer.CallOnRenderThread` observation. The renderer callback reads no scene nodes. It receives a copied panel transform and copied camera metadata; each observation records its own time, thread and context. These observations are related in time, not asserted simultaneous.

Interface view getters can reuse cached transforms and do not expose their native return status through this API. Getter count is never a freshness, valid-eye, projection or pixel pass. Projection getters are omitted because the pinned implementation updates near/far/depth cache. No setter, calibration/recenter operation, panel-following change, synthetic pose/button, production trace, second executor or recurring discovery work is introduced.

Save('ready') can precede the first ordinary process/draw. Only the separately requested geometry snapshot establishes the later observed owner state. Initial tabletop heading/posture remains a hypothesis until actual baseline/later values discriminate it. Head confidence and the original ninety-draw qualification gate are preserved.

All numeric room/model geometry is written to the owned `/data` private result, under0700/0600 protection. Public results remove the complete geometry object and retain small availability, focus, dimensions and visibility summaries plus the private file hash/path. The new driver records actual focus before/after its existing owned PID/address guard. Its existing bounded argument-free capture is shared by normal and early-failure close requests, with the same20-second capture/15-second debugger/60-second close bounds and ordinary window-close owner.

This is a nondistributable diagnostic. A compiled observer, cached view, absence of a release-build error or process exit0 does not establish usable lenses, model alignment, physical gestures, comfort, a product fix or full M4 acceptance.
