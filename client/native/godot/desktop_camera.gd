class_name QuodDesktopCamera
extends Camera3D
## Local observer navigation only; does not move a server-owned body.
signal selected(origin: Vector3, direction: Vector3)
signal capture_changed(captured: bool)

const HELP := "Free view · WASD / ZQSD or arrows · R/F up/down · Shift faster · Click scene to capture mouse · Esc to release"
var enabled := false:
	set(value):
		enabled = value
		if not value:
			stop()
var keys: Dictionary = {}
var looking := false
var focused := true
var speed := 2.0

func stop() -> void:
	keys.clear()
	if looking:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		looking = false
		capture_changed.emit(false)

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		focused = false
		stop()
	elif what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		focused = true

func _unhandled_input(event: InputEvent) -> void:
	if not enabled or not focused:
		return
	if looking and event is InputEventKey and not event.echo:
		var code: Key = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		if code in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_R, KEY_F, KEY_SHIFT]:
			if event.pressed:
				keys[code] = true
			else:
				keys.erase(code)
			get_viewport().set_input_as_handled()
	if event is InputEventMouseMotion and looking:
		rotation.y -= event.screen_relative.x * 0.003
		rotation.x = clampf(rotation.x - event.screen_relative.y * 0.003, deg_to_rad(-85), deg_to_rad(85))
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if not looking:
				looking = true
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				capture_changed.emit(true)
			else:
				var centre := get_viewport().get_visible_rect().size / 2.0
				selected.emit(project_ray_origin(centre), project_ray_normal(centre))
			get_viewport().set_input_as_handled()
		elif looking and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			position += basis.z * (-0.25 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 0.25)

func held(first: Key, second: Key) -> float:
	return 1.0 if keys.has(first) or keys.has(second) else 0.0

func _process(delta: float) -> void:
	if not enabled or not focused or not looking:
		return
	var direction := basis.x * (held(KEY_D, KEY_RIGHT) - held(KEY_A, KEY_LEFT))
	direction += basis.z * (held(KEY_S, KEY_DOWN) - held(KEY_W, KEY_UP))
	direction += Vector3.UP * (held(KEY_R, KEY_R) - held(KEY_F, KEY_F))
	position += direction.normalized() * speed * (4.0 if keys.has(KEY_SHIFT) else 1.0) * delta

func _exit_tree() -> void:
	stop()
