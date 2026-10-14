extends SceneTree
## Separate launches verify offline key entry, explicit connection and durable setup.
func _initialize() -> void:
	create_timer(30.0).timeout.connect(func(): push_error("Onboarding deadline"); quit(1))
	run.call_deferred()

func run() -> void:
	var cycle := OS.get_environment("QUOD_FIXTURE_CYCLE")
	var main = load("res://main.tscn").instantiate()
	main.identity_directory = OS.get_environment("QUOD_FIXTURE_STATE")
	main.settings_path = main.identity_directory + "-connection.cfg"
	main.identity_loaded.connect(func():
		if main.identity_present:
			enter.call_deferred(main, cycle)
		else:
			create_key.call_deferred(main))
	root.add_child(main)
	if cycle == "create":
		# Invalid network settings cannot block creation of a local key.
		main.address.text = "not a valid node/"
		main.ca_path.text = "/missing-certificate.pem"

func create_key(main: Node) -> void:
	if not main.welcome.visible or main.connection.visible or main.transport.request_count != 0:
		push_error("First launch did not isolate key creation")
		quit(1)
		return
	main.welcome.get_child(0).pressed.emit()

func enter(main: Node, cycle: String) -> void:
	if main.stage != main.Stage.CONNECTION or main.welcome.visible or main.transport.request_count != 0 or not main.identity_present:
		push_error("Key entry connected automatically or failed to skip welcome")
		quit(1)
		return
	print("Offline identity ready; connection awaits explicit click: PASS (", cycle, ")")
	if cycle == "create":
		main.address.text = "127.0.0.1"
		main.port.value = int(OS.get_environment("QUOD_FIXTURE_PORT"))
		main.ca_path.text = OS.get_environment("QUOD_FIXTURE_CA")
		main.tls_name.text = "localhost"
		main.status_changed.connect(func(message: String):
			if main.stage == main.Stage.SETUP and not main.busy and main.create_button.visible:
				enroll.call_deferred(main)
			if message.begins_with("Account setup awaits confirmation"):
				if main.create_button.visible or not main.reconnect_button.visible:
					push_error("Pending setup offered another account creation")
					quit(1)
					return
				print("Generated key and pending signup retained: PASS")
				quit())
	else:
		main.lobby_installed.connect(func():
			if main.scene.entries.size() != 1 or int(main.port.value) != int(OS.get_environment("QUOD_FIXTURE_PORT")) or main.panel.visible or not main.menu_button.visible:
				push_error("Account, saved connection or unobstructed lobby was not restored")
				quit(1)
			else:
				print("Remembered identity/endpoint and explicit connection to lobby: PASS (", cycle, ")")
				quit())
	main.connect_button.pressed.emit()

func enroll(main: Node) -> void:
	if main.transport.request_count != 2:
		push_error("Connection performed account work before user chose setup")
		quit(1)
		return
	main.create_button.pressed.emit()
