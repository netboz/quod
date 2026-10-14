extends SceneTree
## Drives the actual connection screen against a TLS protocol fixture.

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var main = load("res://main.tscn").instantiate()
	main.auto_restore = false
	main.identity_directory = OS.get_environment("QUOD_FIXTURE_STATE")
	main.settings_path = main.identity_directory + "-connection.cfg"
	root.add_child(main)
	main.address.text = "localhost"
	main.port.value = int(OS.get_environment("QUOD_FIXTURE_PORT"))
	main.ca_path.text = OS.get_environment("QUOD_FIXTURE_CA")
	main.lobby_installed.connect(func():
		if main.scene.entries.size() != 1 or main.transport.endpoint != "https://localhost:" + OS.get_environment("QUOD_FIXTURE_PORT"):
			push_error("wrong node/port or lobby projection")
			quit(1)
			return
		# Editing the destination must retire all old state immediately.
		var previous_account: Dictionary = main.account_rows[0].duplicate()
		main.port.value = 14571 if int(main.port.value) != 14571 else 14572
		if main.bridge == null or not main.identity_present or not main.scene.entries.is_empty() or not main.account_rows.is_empty():
			push_error("destination change retained the old session")
			quit(1)
			return
		var signed: Dictionary = JSON.parse_string(main.bridge.sign_read(JSON.stringify(previous_account), "true."))
		if signed.ok or main.stage != main.Stage.CONNECTION:
			push_error("Destination change retained authentication")
			quit(1)
			return
		failed_import.call_deferred(main))
	create_timer(30.0).timeout.connect(func(): push_error("connection test deadline: " + main.status_label.text); quit(1))
	main.identity_loaded.connect(func(): main.connect_node.call_deferred(), CONNECT_ONE_SHOT)
	main.start_identity("import", FileAccess.get_file_as_string(OS.get_environment("QUOD_FIXTURE_BUNDLE")), "public fixture passphrase")

func failed_import(main: Node) -> void:
	var saved := FileAccess.get_file_as_bytes(main.identity_directory.path_join("active.json"))
	var requests: int = main.transport.request_count
	main.start_identity("import", FileAccess.get_file_as_string(OS.get_environment("QUOD_FIXTURE_BUNDLE")), "wrong passphrase")
	await main.status_changed
	# Worker failure emits status before the error stage is installed.
	await process_frame
	if main.stage != main.Stage.KEY_ERROR or main.welcome.visible or FileAccess.get_file_as_bytes(main.identity_directory.path_join("active.json")) != saved:
		push_error("Failed import did not preserve saved identity and show recovery")
		quit(1)
		return
	main.key_error.get_child(0).pressed.emit()
	await main.identity_loaded
	if main.stage != main.Stage.CONNECTION or not main.identity_present or main.transport.request_count != requests:
		push_error("Retry did not restore the saved key offline")
		quit(1)
		return
	print("TLS connection, signed reads, destination retirement and failed-import recovery: PASS")
	quit()
