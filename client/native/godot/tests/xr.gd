extends SceneTree
## Native frame evidence; never substitutes for physical Vive acceptance.

var main: Node
var frame_times: Array[int] = []
var last_frame := 0
var first_pose: Transform3D
var pose_seen := false
var pose_changed := false
var finished := false

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	main = load("res://main.tscn").instantiate()
	main.auto_restore = false
	root.add_child(main)
	main.diagnostic()
	main.panel.hide()
	if main.xr == null or main.xr.interface == null or not main.xr.interface.is_initialized():
		push_error("Native OpenXR initialization failed")
		quit(1)
		return
	RenderingServer.frame_post_draw.connect(rendered)
	create_timer(25.0).timeout.connect(func():
		if not finished:
			push_error("XR frame/tracking acceptance deadline exceeded")
			quit(1))

func rendered() -> void:
	if finished or not main.xr.focused:
		return
	var xr: QuodXRRig = main.xr
	if not xr.controllers.all(func(c: XRController3D): return c.get_has_tracking_data()):
		return
	var pose: Transform3D = xr.camera.get_camera_transform()
	if not pose_seen:
		first_pose = pose
		pose_seen = true
	elif not pose.is_equal_approx(first_pose):
		pose_changed = true
	var now := Time.get_ticks_usec()
	if last_frame:
		frame_times.append(now - last_frame)
	last_frame = now
	if frame_times.size() < 120 or not pose_changed:
		return
	finished = true
	var interface := xr.interface
	var left := interface.get_transform_for_view(0, Transform3D.IDENTITY)
	var right := interface.get_transform_for_view(1, Transform3D.IDENTITY)
	var floor_mode := interface.get_play_area_mode()
	var passed := interface.get_view_count() == 2 and left.origin.distance_to(right.origin) > 0.01 and root.use_xr and floor_mode in [XRInterface.XR_PLAY_AREA_STAGE, XRInterface.XR_PLAY_AREA_ROOMSCALE]
	var report := {"pass": passed, "view_count": interface.get_view_count(), "eye_separation": left.origin.distance_to(right.origin), "floor_mode": floor_mode, "rendered_frames": frame_times.size(), "moving_head_pose": pose_changed, "tracked_controllers": 2, "frame_intervals_us": frame_times, "physical_headset": false, "controller_buttons_exercised": false}
	var output := OS.get_environment("QUOD_XR_REPORT")
	if not output.is_empty():
		var file := FileAccess.open(output, FileAccess.WRITE)
		file.store_string(JSON.stringify(report, "  ") + "\n")
		file.close()
	var screenshot := OS.get_environment("QUOD_XR_SCREENSHOT")
	if not screenshot.is_empty():
		var eye := RenderingServer.texture_2d_layer_get(root.get_texture().get_rid(), 0)
		if eye != null:
			eye.save_png(screenshot)
	print("NATIVE_XR_RESULT ", JSON.stringify(report))
	quit(0 if passed else 1)
