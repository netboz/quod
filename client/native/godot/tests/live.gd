extends SceneTree
## Read-only live acceptance: local key, TLS authentication and public catalogue.
var main: Node
var finished := false
var authenticated := false

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	main = load("res://main.tscn").instantiate()
	main.auto_restore = false
	main.identity_directory = OS.get_environment("QUOD_LIVE_STATE")
	main.settings_path = main.identity_directory + "-connection.cfg"
	var key := QuodBridge.new()
	var opened: Dictionary = JSON.parse_string(key.open_identity(main.identity_directory, true, "", ""))
	key.lock()
	if not opened.ok:
		push_error(opened.error)
		quit(1)
		return
	root.add_child(main)
	main.status_changed.connect(func(message: String):
		print("LIVE_STATUS ", message)
		settled.call_deferred())
	main.session_authenticated.connect(func():
		authenticated = true
		verify_catalogue.call_deferred())
	create_timer(40.0).timeout.connect(func():
		if not finished:
			push_error("Live check deadline: " + main.status_label.text)
			quit(1))
	main.identity_loaded.connect(func(): main.connect_node.call_deferred(), CONNECT_ONE_SHOT)
	main.start_identity("restore")

func settled() -> void:
	if not finished and not authenticated and not main.busy and main.transport.request_count > 0:
		finished = true
		push_error("Live authentication failed: " + main.status_label.text)
		quit(1)

func verify_catalogue() -> void:
	var result: Dictionary = await main.transport.fetch("/api/ontologies/system")
	finished = true
	if not result.ok:
		push_error(result.error)
		quit(1)
		return
	var catalogue: Variant = JSON.parse_string(result.value.get_string_from_utf8())
	if not catalogue is Dictionary or not catalogue.get("ontologies") is Array:
		push_error("Invalid live catalogue")
		quit(1)
		return
	print("LIVE_CONNECTION_PASS ", JSON.stringify({"endpoint":main.transport.endpoint,"network_id":catalogue.get("network_id"),"authenticated":true,"signup_available":catalogue.ontologies.any(func(row): return row.namespace == "quod:signup"),"domain_writes":0}))
	quit()
