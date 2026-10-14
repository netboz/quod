extends Node3D
## Native account entry and lobby viewer. The connection screen remains on the desktop mirror.
signal status_changed(message: String)
signal lobby_installed
signal session_authenticated
signal identity_loaded
enum Stage { WELCOME, CONNECTION, SETUP, WORLD, KEY_ERROR }
var stage := Stage.WELCOME
var welcome := VBoxContainer.new()
var key_error := VBoxContainer.new()
var connection := VBoxContainer.new()
var setup := VBoxContainer.new()
var world := VBoxContainer.new()
var title := Label.new()
var subtitle := Label.new()
var menu_button := Button.new()
var reconnect_button := Button.new()
var disconnect_button := Button.new()
var more := VBoxContainer.new()

var bridge: QuodBridge
var transport := QuodTransport.new()
var resources := QuodResources.new()
var scene := QuodScene.new()
var desktop_camera := QuodDesktopCamera.new()
var navigation_hint := Label.new()
var reticle := Label.new()
var xr: QuodXRRig
var address := LineEdit.new()
var port := SpinBox.new()
var ca_path := LineEdit.new()
var tls_name := LineEdit.new()
var accounts := OptionButton.new()
var connect_button := Button.new()
var refresh_button := Button.new()
var status_label := Label.new()
var selection := Label.new()
var panel := PanelContainer.new()
var account_rows: Array = []
var revision := 0
var unlocking: Thread
var busy := false
var identity_present := false
var create_button := Button.new()
var import_button := Button.new()
var export_button := Button.new()
var identity_label := Label.new()
var auto_restore := true
var identity_directory := ""
var settings_path := "user://connection.cfg"

func _ready() -> void:
	add_child(transport)
	resources.transport = transport
	scene.resources = resources
	add_child(scene)
	desktop_camera.selected.connect(select_ray)
	add_child(desktop_camera)
	desktop_camera.position = Vector3(0, 1.7, -5.8)
	desktop_camera.look_at(Vector3(0, 1.1, 0))
	desktop_camera.current = true
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color("172237")
	# Directional sky irradiance preserves surface shape inside cast shadows.
	settings.sky = Sky.new()
	settings.sky.sky_material = ProceduralSkyMaterial.new()
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	settings.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	settings.ambient_light_energy = 0.65
	settings.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	settings.tonemap_exposure = 0.7
	environment.environment = settings
	add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, -30, 0)
	light.light_energy = 0.9
	light.shadow_enabled = true
	light.directional_shadow_max_distance = 30.0
	light.directional_shadow_blend_splits = true
	RenderingServer.directional_shadow_atlas_set_size(4096, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_HIGH)
	add_child(light)
	build_ui()
	if OS.get_cmdline_user_args().has("--xr"):
		xr = QuodXRRig.new()
		xr.position = Vector3(0, 0, -5.8)
		xr.rotation.y = PI
		xr.state_changed.connect(show_status)
		xr.selected.connect(select_ray)
		add_child(xr)
	if OS.get_cmdline_user_args().has("--diagnostic"):
		diagnostic()
	elif auto_restore:
		panel.hide()
		start_identity.call_deferred("restore")

func option(name: String, fallback: String) -> String:
	var arguments := OS.get_cmdline_user_args()
	var index := arguments.find(name)
	return arguments[index + 1] if index >= 0 and index + 1 < arguments.size() else fallback

func build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	canvas.add_child(panel)
	panel.visibility_changed.connect(update_navigation)
	canvas.add_child(navigation_hint)
	navigation_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	navigation_hint.offset_left = 18
	navigation_hint.offset_right = -18
	navigation_hint.offset_top = -60
	navigation_hint.offset_bottom = -12
	navigation_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	navigation_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	navigation_hint.add_theme_color_override("font_shadow_color", Color.BLACK)
	navigation_hint.add_theme_constant_override("shadow_offset_x", 1)
	navigation_hint.add_theme_constant_override("shadow_offset_y", 1)
	navigation_hint.text = QuodDesktopCamera.HELP
	canvas.add_child(reticle)
	reticle.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	reticle.offset_left = -10
	reticle.offset_top = -10
	reticle.offset_right = 10
	reticle.offset_bottom = 10
	reticle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	reticle.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	reticle.text = "+"
	reticle.hide()
	desktop_camera.capture_changed.connect(reticle.set_visible)
	var style := StyleBoxFlat.new()
	style.bg_color = Color("182231")
	style.border_color = Color("35455c")
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	panel.add_theme_stylebox_override("panel", style)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	panel.add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 12)
	scroll.add_child(rows)
	title.add_theme_font_size_override("font_size", 28)
	rows.add_child(title)
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	subtitle.add_theme_color_override("font_color", Color("a9b9ce"))
	rows.add_child(subtitle)
	for section in [welcome, connection, setup, world, key_error, more]:
		section.add_theme_constant_override("separation", 10)
		rows.add_child(section)
	var key_button := Button.new()
	key_button.text = "Create my key"
	key_button.pressed.connect(func(): start_identity("create"))
	welcome.add_child(key_button)
	import_button.text = "I already have a key…"
	import_button.pressed.connect(import_dialog)
	welcome.add_child(import_button)
	var retry_key := Button.new()
	retry_key.text = "Retry saved key"
	retry_key.pressed.connect(func(): start_identity("restore"))
	key_error.add_child(retry_key)
	var recover_key := Button.new()
	recover_key.text = "Import a backup…"
	recover_key.pressed.connect(import_dialog)
	key_error.add_child(recover_key)
	var settings := ConfigFile.new()
	settings.load(settings_path)
	address.text = option("--node", str(settings.get_value("connection", "node", "localhost")))
	address.placeholder_text = "Node hostname or IP address"
	field(connection, "Node address", address)
	port.min_value = 1
	port.max_value = 65535
	port.value = int(option("--port", str(settings.get_value("connection", "port", 14570))))
	field(connection, "Port", port)
	connect_button.text = "Connect"
	connect_button.pressed.connect(connect_node)
	connection.add_child(connect_button)
	var advanced := VBoxContainer.new()
	var advanced_button := Button.new()
	advanced_button.text = "Certificate settings…"
	advanced_button.pressed.connect(func(): advanced.visible = not advanced.visible)
	connection.add_child(advanced_button)
	connection.add_child(advanced)
	advanced.hide()
	ca_path.text = option("--ca", str(settings.get_value("connection", "ca", "")))
	file_field(advanced, "CA certificate (optional)", ca_path, ["*.pem,*.crt ; CA certificate"])
	tls_name.text = option("--tls-name", str(settings.get_value("connection", "tls_name", "")))
	tls_name.placeholder_text = "Defaults to the node address"
	field(advanced, "Name on the trusted certificate", tls_name)
	create_button.text = "Create account and enter"
	create_button.pressed.connect(enroll_account)
	setup.add_child(create_button)
	reconnect_button.text = "Check account setup"
	reconnect_button.pressed.connect(connect_node)
	setup.add_child(reconnect_button)
	accounts.item_selected.connect(change_account)
	field(world, "Account on this network", accounts)
	refresh_button.text = "Refresh lobby"
	refresh_button.pressed.connect(load_lobby)
	world.add_child(refresh_button)
	var resume_button := Button.new()
	resume_button.text = "Return to lobby"
	resume_button.pressed.connect(func(): panel.hide())
	world.add_child(resume_button)
	disconnect_button.text = "Change node / disconnect"
	disconnect_button.pressed.connect(disconnect_session)
	rows.add_child(disconnect_button)
	var more_button := Button.new()
	more_button.text = "Key & backups…"
	more_button.pressed.connect(func(): more.visible = not more.visible)
	connection.add_child(more_button)
	var world_more := Button.new()
	world_more.text = "Key & backups…"
	world_more.pressed.connect(func(): more.visible = not more.visible)
	world.add_child(world_more)
	more.add_child(identity_label)
	export_button.text = "Export encrypted key…"
	export_button.pressed.connect(func(): backup_dialog(false))
	more.add_child(export_button)
	var replace := Button.new()
	replace.text = "Import a different key…"
	replace.pressed.connect(import_dialog)
	more.add_child(replace)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_color_override("font_color", Color("afc1d9"))
	rows.add_child(status_label)
	menu_button.text = "Quod · Menu"
	menu_button.focus_mode = Control.FOCUS_NONE
	menu_button.position = Vector2(18, 18)
	menu_button.pressed.connect(func(): panel.visible = not panel.visible)
	canvas.add_child(menu_button)
	selection.position = Vector2(18, 62)
	canvas.add_child(selection)
	address.text_changed.connect(func(_value: String): disconnect_session())
	port.value_changed.connect(func(_value: float): disconnect_session())
	ca_path.text_changed.connect(func(_value: String): disconnect_session())
	tls_name.text_changed.connect(func(_value: String): disconnect_session())
	rows.minimum_size_changed.connect(func(): fit_panel.call_deferred(rows))
	get_viewport().size_changed.connect(func(): fit_panel.call_deferred(rows))
	for button in [key_button, connect_button, create_button, reconnect_button, retry_key]:
		primary_button(button)
	for button in [import_button, advanced_button, more_button, world_more, replace]:
		button.flat = true
	set_stage(Stage.WELCOME)
	set_busy(false)
	show_status("")

func primary_button(button: Button) -> void:
	button.custom_minimum_size.y = 44
	button.add_theme_font_size_override("font_size", 18)
	for state: String in ["normal", "hover", "pressed"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color({"normal": "315f84", "hover": "3d749f", "pressed": "264a68"}[state])
		style.set_corner_radius_all(6)
		button.add_theme_stylebox_override(state, style)

func fit_panel(rows: VBoxContainer) -> void:
	var viewport := get_viewport().get_visible_rect().size
	panel.size = Vector2(minf(480, viewport.x - 32), minf(rows.get_combined_minimum_size().y + 52, viewport.y - 48))
	panel.position = (viewport - panel.size) / 2

func set_stage(value: Stage) -> void:
	stage = value
	welcome.visible = value == Stage.WELCOME
	key_error.visible = value == Stage.KEY_ERROR
	connection.visible = value == Stage.CONNECTION
	setup.visible = value == Stage.SETUP
	world.visible = value == Stage.WORLD
	menu_button.visible = value == Stage.WORLD
	disconnect_button.visible = value == Stage.SETUP or value == Stage.WORLD
	more.hide()
	panel.visible = value != Stage.WORLD
	title.text = ["Welcome to Quod", "Connect to Quod", "Your account", "Your lobby", "Could not open your key"][value]
	subtitle.text = [
		"First, create your personal key. It stays on this computer and is remembered next time. No connection is needed.",
		"Your key is ready. Choose a node to sign in.",
		"Your key is connected. Create an account on this network to enter your lobby.",
		QuodDesktopCamera.HELP + "\nScroll to step forward/back · Click to select at crosshair\nTab or Esc opens or closes this menu.",
		"No new key was created. Retry your saved key or import a backup."
	][value]
	update_navigation()

func field(rows: VBoxContainer, caption: String, control: Control) -> void:
	var label := Label.new()
	label.text = caption
	rows.add_child(label)
	rows.add_child(control)

func file_field(rows: VBoxContainer, caption: String, path: LineEdit, filters: Array[String]) -> void:
	field(rows, caption, path)
	var button := Button.new()
	button.text = "Browse…"
	rows.add_child(button)
	var dialog := FileDialog.new()
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.filters = PackedStringArray(filters)
	add_child(dialog)
	dialog.file_selected.connect(func(chosen: String): path.text = chosen; disconnect_session())
	button.pressed.connect(func():
		if path.editable:
			dialog.popup_centered_ratio(0.75))

func disconnect_session() -> void:
	revision += 1
	transport.cancel()
	scene.clear()
	resources.clear()
	if bridge != null and identity_present:
		bridge.end_auth()
	account_rows.clear()
	accounts.clear()
	set_busy(unlocking != null and unlocking.is_started())
	selection.text = ""
	set_stage(Stage.CONNECTION if identity_present else Stage.WELCOME)
	show_status("")

func change_account(_index: int) -> void:
	revision += 1
	transport.cancel()
	scene.clear()
	resources.clear()
	selection.text = ""
	load_lobby()

func set_busy(value: bool) -> void:
	busy = value
	for button in [connect_button, create_button, import_button, export_button, reconnect_button]:
		button.disabled = value
	for button in welcome.get_children() + key_error.get_children():
		if button is Button:
			button.disabled = value
	for button in more.get_children():
		if button is Button:
			button.disabled = value
	disconnect_button.disabled = value
	address.editable = not value
	port.editable = not value
	ca_path.editable = not value
	tls_name.editable = not value
	export_button.disabled = value or not identity_present or bridge == null
	refresh_button.disabled = value or account_rows.is_empty()
	accounts.disabled = value or account_rows.is_empty()
	update_navigation()

func start_identity(mode: String, encoded := "", password := "") -> void:
	if busy:
		return
	disconnect_session()
	if bridge != null:
		bridge.lock()
	bridge = null
	resources.bridge = null
	identity_present = false
	welcome.hide()
	key_error.hide()
	connection.hide()
	setup.hide()
	world.hide()
	title.text = "Quod"
	subtitle.text = "Opening your personal key…"
	if identity_directory.is_empty():
		identity_directory = OS.get_user_data_dir().path_join("identity")
	set_busy(true)
	show_status("Preparing your identity…")
	unlocking = Thread.new()
	var error := unlocking.start(identity_worker.bind(mode, encoded, password, revision))
	if error != OK:
		set_busy(false)
		show_status("Cannot prepare identity: " + error_string(error))

func identity_worker(mode: String, encoded: String, password: String, version: int) -> void:
	var candidate := QuodBridge.new()
	var result: Dictionary = JSON.parse_string(candidate.open_identity(identity_directory, mode == "create", encoded, password))
	identity_ready.call_deferred(candidate, result, version)

func identity_ready(candidate: QuodBridge, result: Dictionary, version: int) -> void:
	unlocking.wait_to_finish()
	if version != revision:
		candidate.lock()
		set_busy(false)
		return
	if not checked(result, version):
		set_stage(Stage.KEY_ERROR)
		return
	bridge = candidate
	identity_present = result.value.present
	resources.bridge = bridge
	set_busy(false)
	set_stage(Stage.CONNECTION if identity_present else Stage.WELCOME)
	show_status("")
	identity_label.text = "Saved key · " + result.value.public_key.substr(0, 12) if identity_present else ""
	identity_loaded.emit()

func connect_node() -> void:
	if busy or not identity_present or bridge == null:
		return
	disconnect_session()
	var problem := transport.configure(address.text, int(port.value), ca_path.text, tls_name.text)
	if not problem.is_empty():
		show_status(problem)
		return
	var settings := ConfigFile.new()
	settings.load(settings_path)
	var changed: bool = settings.get_value("connection", "node", "") != address.text or int(settings.get_value("connection", "port", 0)) != int(port.value) or settings.get_value("connection", "ca", "") != ca_path.text or settings.get_value("connection", "tls_name", "") != tls_name.text
	settings.set_value("connection", "node", address.text)
	settings.set_value("connection", "port", int(port.value))
	settings.set_value("connection", "ca", ca_path.text)
	settings.set_value("connection", "tls_name", tls_name.text)
	if changed and settings.save(settings_path) != OK:
		show_status("Cannot remember connection settings.")
		return
	var version := revision
	set_busy(true)
	show_status("Connecting to %s…" % transport.endpoint)
	var begin: Dictionary = JSON.parse_string(bridge.begin_auth())
	if not checked(begin, version):
		return
	var challenge := await transport.post("/api/auth/challenge", begin.value)
	if not checked(challenge, version):
		return
	var answer: Dictionary = JSON.parse_string(bridge.answer_challenge(JSON.stringify(challenge.value)))
	if not checked(answer, version):
		return
	var authenticated := await transport.post("/api/auth/complete", answer.value)
	if not checked(authenticated, version):
		return
	var completed: Dictionary = JSON.parse_string(bridge.complete_auth(JSON.stringify(authenticated.value)))
	if not checked(completed, version):
		return
	session_authenticated.emit()
	var resumed: Dictionary = JSON.parse_string(bridge.resume_setup())
	if not checked(resumed, version):
		return
	if resumed.value.has("path"):
		await setup_steps(resumed.value, version)
		return
	await connected_accounts(resumed.value.accounts)

func enroll_account() -> void:
	if busy or bridge == null or stage != Stage.SETUP:
		return
	set_busy(true)
	var version := revision
	var catalogue := await transport.fetch("/api/ontologies/system")
	if not checked(catalogue, version):
		return
	var command: Dictionary = JSON.parse_string(bridge.enroll(catalogue.value.get_string_from_utf8()))
	if checked(command, version):
		await setup_steps(command.value, version)

func setup_steps(command: Dictionary, version: int) -> void:
	set_stage(Stage.SETUP)
	create_button.hide()
	reconnect_button.show()
	subtitle.text = "Your account setup is saved. We will check its result without submitting it again."
	while command.has("path"):
		show_status("Checking account setup…" if command.resolving else "Preparing your account and lobby…")
		var body: Dictionary = command.body.duplicate(true)
		var deadline := int(body.get("deadline_ms", 0))
		body.erase("deadline_ms")
		var response := await transport.post(command.path, body, deadline)
		if version == revision and not response.ok and response.get("rejected", false) and not command.resolving:
			var refused: Dictionary = JSON.parse_string(bridge.refuse_setup())
			if not checked(refused, version):
				return
			create_button.show()
			reconnect_button.hide()
			checked(response, version)
			return
		if not checked(response, version):
			if version == revision:
				show_status(response.error + " Connect checks the saved outcome without resubmitting it.")
			return
		var next: Dictionary = JSON.parse_string(bridge.accept_setup(JSON.stringify(response.value), command.resolving))
		if not checked(next, version):
			return
		command = next.value
		if command.get("pending", false):
			set_busy(false)
			show_status("Account setup awaits confirmation. Connect checks its outcome.")
			return
	await connected_accounts(command.accounts)

func connected_accounts(rows: Array) -> void:
	account_rows = rows
	accounts.clear()
	for account: Dictionary in rows:
		accounts.add_item(account.namespace)
	set_busy(false)
	if rows.is_empty():
		set_stage(Stage.SETUP)
		create_button.text = "Create account and enter"
		create_button.show()
		reconnect_button.hide()
		show_status("")
		return
	accounts.select(0)
	await load_lobby()

func import_dialog() -> void:
	var directory := identity_directory if not identity_directory.is_empty() else OS.get_user_data_dir().path_join("identity")
	if not FileAccess.file_exists(directory.path_join("active.json")):
		backup_dialog(true)
		return
	var confirm := ConfirmationDialog.new()
	confirm.title = "Import an identity"
	confirm.dialog_text = "This replaces the active identity on this computer. Export your current key first if you need it."
	add_child(confirm)
	confirm.confirmed.connect(func(): backup_dialog(true))
	confirm.confirmed.connect(confirm.queue_free)
	confirm.canceled.connect(confirm.queue_free)
	confirm.popup_centered()

func backup_dialog(importing: bool) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Import encrypted key" if importing else "Export encrypted key"
	var rows := VBoxContainer.new()
	var password := LineEdit.new()
	password.secret = true
	password.placeholder_text = "Backup passphrase" if importing else "Choose at least 12 characters"
	var confirmation := LineEdit.new()
	confirmation.secret = true
	confirmation.placeholder_text = "Repeat passphrase"
	rows.add_child(password)
	if not importing:
		rows.add_child(confirmation)
	dialog.add_child(rows)
	add_child(dialog)
	dialog.canceled.connect(dialog.queue_free)
	dialog.confirmed.connect(func():
		var phrase := password.text
		if not importing and (phrase.length() < 12 or phrase != confirmation.text):
			show_status("Use matching passphrases of at least 12 characters.")
			dialog.queue_free()
			return
		var file := FileDialog.new()
		file.access = FileDialog.ACCESS_FILESYSTEM
		file.file_mode = FileDialog.FILE_MODE_OPEN_FILE if importing else FileDialog.FILE_MODE_SAVE_FILE
		file.filters = PackedStringArray(["*.quodkey,*.json ; Quod encrypted key"])
		if not importing:
			file.current_file = "quod-identity.quodkey"
		add_child(file)
		file.file_selected.connect(func(path: String):
			if importing:
				var input := FileAccess.open(path, FileAccess.READ)
				if input == null or input.get_length() > 16384:
					show_status("Select a readable Quod key file (at most 16 KiB).")
				else:
					start_identity("import", input.get_as_text(), phrase)
			else:
				export_backup(path, phrase)
			file.queue_free())
		file.canceled.connect(file.queue_free)
		file.popup_centered_ratio(0.75)
		dialog.queue_free())
	dialog.popup_centered(Vector2i(440, 150))

func export_backup(path: String, phrase: String) -> void:
	if busy or bridge == null:
		return
	set_busy(true)
	# Exclusive bridge ownership moves to the worker until it returns.
	var candidate := bridge
	var version := revision
	bridge = null
	resources.bridge = null
	unlocking = Thread.new()
	var error := unlocking.start(func():
		var result: Dictionary = JSON.parse_string(candidate.export_identity(phrase))
		export_ready.call_deferred(candidate, result, path, version))
	if error != OK:
		bridge = candidate
		resources.bridge = bridge
		set_busy(false)
		show_status("Cannot start backup export.")

func export_ready(candidate: QuodBridge, result: Dictionary, path: String, version: int) -> void:
	unlocking.wait_to_finish()
	if version != revision:
		candidate.lock()
		set_busy(false)
		return
	bridge = candidate
	resources.bridge = bridge
	if not checked(result, version):
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		show_status("Cannot write the selected backup file.")
	else:
		file.store_string(result.value)
		file.flush()
		var error := file.get_error()
		file.close()
		show_status("Encrypted backup exported." if error == OK and FileAccess.get_file_as_string(path) == result.value else "Backup write failed; your active identity remains saved.")
	set_busy(false)

func checked(result: Dictionary, version: int) -> bool:
	if version != revision:
		return false
	if not result.ok:
		set_busy(false)
		panel.show()
		show_status(result.error)
		return false
	return true

func read_goal(goal: String, account: Dictionary) -> Dictionary:
	var signed: Dictionary = JSON.parse_string(bridge.sign_read(JSON.stringify(account), goal))
	if not signed.ok:
		return signed
	var deadline := int(signed.value.deadline_ms)
	signed.value.erase("deadline_ms")
	return await transport.post("/api/goals/read", signed.value, deadline)

func binding(reply: Dictionary, name: String) -> Dictionary:
	if reply.get("result") == "fail":
		return {"ok": false, "error": "The server returned no answer or refused access for this account."}
	var answers: Variant = reply.get("bindings")
	if reply.get("result") != "ok" or not answers is Array or answers.size() != 1 or not answers[0] is Dictionary or not answers[0].get(name) is String:
		return {"ok": false, "error": "Invalid %s response." % name}
	return {"ok": true, "value": answers[0][name]}

func load_lobby() -> void:
	if bridge == null or accounts.selected < 0 or account_rows.is_empty():
		return
	# Only one loading operation per view; destination changes still cancel it.
	set_busy(true)
	var version := revision
	var account: Dictionary = account_rows[accounts.selected]
	show_status("Reading the authorized lobby…")
	var reference := await read_goal("lobby_reference(Lobby).", account)
	if not checked(reference, version):
		finish_load(version)
		return
	var lobby := binding(reference.value, "Lobby")
	if not checked(lobby, version):
		finish_load(version)
		return
	var goal: Dictionary = JSON.parse_string(bridge.lobby_goal(lobby.value))
	if not checked(goal, version):
		finish_load(version)
		return
	var reply := await read_goal(goal.value, account)
	if not checked(reply, version):
		finish_load(version)
		return
	var projection := binding(reply.value, "Scene")
	if not checked(projection, version):
		finish_load(version)
		return
	var marks: Dictionary = JSON.parse_string(bridge.decode_marks(projection.value))
	if not checked(marks, version):
		finish_load(version)
		return
	show_status("Loading verified scene assets…")
	var prepared := await resources.prepare(marks.value)
	if checked(prepared, version):
		scene.install(marks.value)
		resources.retain(prepared.value)
		set_stage(Stage.WORLD)
		show_status("Connected to %s · %d scene marks · read-only" % [transport.endpoint, marks.value.size()])
		lobby_installed.emit()
	finish_load(version)

func finish_load(version: int) -> void:
	if version == revision:
		set_busy(false)
		if stage != Stage.WORLD:
			set_stage(Stage.SETUP)
			subtitle.text = "Your account is connected. If its lobby has not been created yet, finish setup to enter."
			create_button.text = "Finish account setup"
			create_button.show()
			reconnect_button.hide()

func show_status(message: String) -> void:
	status_label.text = message
	status_label.visible = not message.is_empty()
	status_changed.emit(message)
	if xr != null:
		xr.status(message)

func select_ray(origin: Vector3, direction: Vector3) -> void:
	var chosen := scene.pick(origin, direction)
	selection.text = "" if chosen.is_empty() else "%s · %s\n%s" % [chosen.id, chosen.depicts.ontology, chosen.depicts.entityText]

func update_navigation() -> void:
	desktop_camera.enabled = stage == Stage.WORLD and not panel.visible and not busy and xr == null
	navigation_hint.visible = desktop_camera.enabled

func _input(event: InputEvent) -> void:
	if stage == Stage.WORLD and event is InputEventKey and event.pressed and not event.echo and event.keycode in [KEY_TAB, KEY_ESCAPE]:
		panel.visible = not panel.visible
		get_viewport().set_input_as_handled()

func diagnostic() -> void:
	bridge = QuodBridge.new()
	resources.bridge = bridge
	var marks: Dictionary = JSON.parse_string(bridge.decode_marks('[mark(<<"diagnostic">>,<<"box">>,[f(<<"width">>,1000),f(<<"height">>,1000),f(<<"depth">>,1000)],transform(0,1000,0,0,25,0),surface(<<"#42B8D5">>,0,700,0,[]),label(<<"Native XR diagnostic">>,<<"above">>),depicts_nothing)]'))
	if marks.ok:
		scene.install(marks.value)
	set_stage(Stage.WORLD)
	show_status("Diagnostic scene · no Quod connection")

func _exit_tree() -> void:
	if unlocking != null and unlocking.is_started():
		unlocking.wait_to_finish()
	transport.cancel()
	resources.clear()
