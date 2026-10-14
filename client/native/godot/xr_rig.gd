class_name QuodXRRig
extends XROrigin3D
## Native tracking/input only. Domain movement is deliberately absent.
signal selected(origin: Vector3, direction: Vector3)
signal state_changed(message: String)
signal action_received(hand: String, action: String, value: Variant)

var camera: XRCamera3D
var controllers: Array[XRController3D] = []
var interface: OpenXRInterface
var focused := false
var frames := 0
var status_label: Label3D

func _ready() -> void:
	camera = XRCamera3D.new()
	add_child(camera)
	status_label = Label3D.new()
	status_label.font_size = 28
	status_label.pixel_size = 0.0015
	status_label.position = Vector3(0, -0.35, -1.0)
	camera.add_child(status_label)
	for hand in ["left_hand", "right_hand"]:
		var controller := XRController3D.new()
		controller.tracker = hand
		controller.pose = "aim"
		add_child(controller)
		controllers.append(controller)
		var marker := MeshInstance3D.new()
		var shape := BoxMesh.new()
		shape.size = Vector3(0.035, 0.035, 0.16)
		marker.mesh = shape
		marker.position.z = -0.08
		controller.add_child(marker)
		marker.visible = controller.get_has_tracking_data()
		controller.tracking_changed.connect(marker.set_visible)
		controller.button_pressed.connect(func(action: StringName):
			if focused and controller.get_has_tracking_data():
				action_received.emit(hand, action, true)
				if action == &"select":
					selected.emit(controller.global_position, -controller.global_basis.z))
		controller.button_released.connect(func(action: StringName): action_received.emit(hand, action, false))
		controller.input_vector2_changed.connect(func(action: StringName, value: Vector2): action_received.emit(hand, action, value))
	interface = XRServer.find_interface("OpenXR") as OpenXRInterface
	if interface == null or not interface.is_initialized():
		state_changed.emit("OpenXR initialization failed. Check the selected runtime and headset.")
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_viewport().use_xr = true
	camera.current = true
	interface.session_focussed.connect(func(): focused = true; state_changed.emit("OpenXR focused"))
	interface.session_visible.connect(func(): focused = false; state_changed.emit("OpenXR visible; input paused"))
	interface.session_stopping.connect(stopped)
	interface.session_loss_pending.connect(stopped)
	interface.instance_exiting.connect(stopped)
	state_changed.emit("OpenXR initialized; waiting for runtime focus")

func stopped() -> void:
	focused = false
	state_changed.emit("OpenXR session stopped")

func _process(_delta: float) -> void:
	if interface != null and interface.is_initialized() and get_viewport().use_xr:
		frames += 1

func status(message: String) -> void:
	if status_label:
		status_label.text = message

func _exit_tree() -> void:
	focused = false
	get_viewport().use_xr = false
	if interface != null and interface.is_initialized():
		interface.uninitialize()
