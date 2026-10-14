extends SceneTree
## Drive production camera input; verify movement and UI/focus cancellation.
var failed := false

func check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)

func key(camera: QuodDesktopCamera, code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = pressed
	camera._unhandled_input(event)

func click(camera: QuodDesktopCamera, pressed := true) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = Vector2(7, 9)
	event.pressed = pressed
	camera._unhandled_input(event)

func _initialize() -> void:
	create_timer(10).timeout.connect(func(): push_error("Navigation deadline"); quit(1))
	run.call_deferred()

func run() -> void:
	var main = load("res://main.tscn").instantiate()
	main.auto_restore = false
	root.add_child(main)
	var camera: QuodDesktopCamera = main.desktop_camera
	camera.set_process(false)
	var initial := camera.position
	key(camera, KEY_W, true)
	camera._process(1)
	check(camera.position == initial, "entry screen allowed movement")
	click(camera)
	check(not camera.looking, "entry screen captured the mouse")
	main.set_stage(main.Stage.WORLD)
	key(camera, KEY_W, true)
	camera._process(1)
	check(camera.position == initial, "uncaptured view accepted keyboard movement")
	var selections: Array[Vector3] = []
	camera.selected.connect(func(_origin: Vector3, direction: Vector3): selections.append(direction))
	click(camera)
	click(camera, false)
	check(camera.looking and main.reticle.visible and selections.is_empty(), "capture click selected a subject or required holding the button")
	if DisplayServer.get_name() != "headless":
		check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "desktop pointer was not captured")
	var motion := InputEventMouseMotion.new()
	motion.screen_relative = Vector2(30, 0)
	var yaw := camera.rotation.y
	camera._unhandled_input(motion)
	check(not is_equal_approx(camera.rotation.y, yaw), "mouse look stopped after button release")
	click(camera)
	check(selections.size() == 1 and selections[0].is_equal_approx(-camera.global_basis.z), "captured selection did not use the centre ray")
	key(camera, KEY_W, true)
	camera._process(0.5)
	check(camera.position.is_equal_approx(initial - camera.basis.z), "forward input did not move in view direction")
	key(camera, KEY_D, true)
	initial = camera.position
	camera._process(0.5)
	check(is_equal_approx(camera.position.distance_to(initial), 1.0), "diagonal movement was faster")
	main.panel.show()
	initial = camera.position
	camera._process(1)
	check(camera.position == initial and camera.keys.is_empty(), "opening menu did not stop movement")
	main.panel.hide()
	camera._process(1)
	check(camera.position == initial, "closing menu resumed a stale held key")
	click(camera)
	key(camera, KEY_UP, true)
	key(camera, KEY_SHIFT, true)
	camera._process(0.25)
	check(is_equal_approx(camera.position.distance_to(initial), 2.0), "arrow or speed modifier failed")
	camera.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	initial = camera.position
	camera._process(1)
	check(camera.keys.is_empty() and camera.position == initial and not camera.looking and not main.reticle.visible, "focus loss retained movement or capture")
	camera.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_IN)
	check(not camera.looking, "refocus captured without a request")
	click(camera)
	key(camera, KEY_R, true)
	camera._process(0.5)
	check(camera.position.is_equal_approx(initial + Vector3.UP), "vertical movement failed")
	motion.screen_relative = Vector2(30, -10000)
	camera._unhandled_input(motion)
	check(absf(camera.rotation.x) <= deg_to_rad(85.01), "look pitch can flip upside down")
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	main._input(escape)
	check(main.panel.visible and not camera.looking and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "Escape did not release capture and open menu")
	main._input(escape)
	check(not main.panel.visible and not camera.looking, "closing menu captured without a request")
	click(camera)
	check(camera.looking, "scene click did not recapture after Escape")
	main.disconnect_session()
	check(not camera.enabled and camera.keys.is_empty() and not camera.looking and not main.reticle.visible, "disconnect retained navigation or capture")
	check(main.transport.request_count == 0, "local navigation sent network requests")
	print("Persistent capture, centre picking, movement, Escape, focus and disconnect: ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
