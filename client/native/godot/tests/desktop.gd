extends SceneTree
## Capture entry stages and identical geometry with old/new lighting, offline.
var destination := OS.get_environment("QUOD_DESKTOP_SCREENSHOT")

func _initialize() -> void:
	create_timer(30.0).timeout.connect(func(): push_error("Desktop capture deadline"); quit(1))
	run.call_deferred()

func capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var error := root.get_texture().get_image().save_png(destination.path_join(name + ".png"))
	if error != OK:
		push_error("Cannot save desktop capture")
		quit(1)

func run() -> void:
	var main = load("res://main.tscn").instantiate()
	main.auto_restore = false
	main.identity_directory = destination.path_join("disposable-identity")
	main.settings_path = destination.path_join("connection.cfg")
	root.add_child(main)
	await capture("welcome")
	main.start_identity("create")
	await main.identity_loaded
	main.address.text = "192.168.1.10"
	main.port.value = 31609
	await capture("connection")
	root.content_scale_size = Vector2i(860, 440)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	await capture("connection-short")
	var area: Rect2 = main.get_viewport().get_visible_rect()
	if not area.encloses(main.panel.get_rect()):
		push_error("Entry panel escaped the short viewport")
		quit(1)
		return
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	main.connection.get_child(5).pressed.emit() # Certificate disclosure.
	await capture("certificates")
	main.start_identity("import", "{}", "wrong")
	await main.status_changed
	await process_frame
	await capture("key-error")
	main.start_identity("restore")
	await main.identity_loaded
	main.set_stage(main.Stage.SETUP)
	main.reconnect_button.hide()
	await capture("setup")
	var marks: Dictionary = JSON.parse_string(main.bridge.decode_marks('[mark(<<"floor">>,<<"box">>,[f(<<"width">>,9000),f(<<"height">>,100),f(<<"depth">>,7000)],transform(0,-50,1000,0,0,0),surface(<<"#8793A4">>,0,850,0,[]),unlabelled,depicts_nothing),mark(<<"box">>,<<"box">>,[f(<<"width">>,1200),f(<<"height">>,1200),f(<<"depth">>,1200)],transform(-900,600,0,0,25,0),surface(<<"#42B8D5">>,0,700,0,[]),unlabelled,depicts_nothing),mark(<<"sphere">>,<<"sphere">>,[f(<<"diameter">>,1200)],transform(900,600,0,0,0,0),surface(<<"#E7AC67">>,0,700,0,[]),unlabelled,depicts_nothing)]'))
	if not marks.ok:
		push_error(marks.error)
		quit(1)
		return
	main.scene.install(marks.value)
	main.set_stage(main.Stage.WORLD)
	main.desktop_camera.position = Vector3(3, 3.5, -6)
	main.desktop_camera.look_at(Vector3(0, 0.5, 0))
	await capture("lighting-after")
	main.panel.show()
	await capture("world-menu")
	main.panel.hide()
	for child in main.get_children():
		if child is WorldEnvironment:
			child.environment.sky = null
			child.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			child.environment.ambient_light_color = Color("c4dcff")
			child.environment.reflected_light_source = Environment.REFLECTION_SOURCE_BG
			child.environment.ambient_light_energy = 0.65
			child.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
			child.environment.tonemap_exposure = 1.0
		if child is DirectionalLight3D:
			child.light_energy = 1.1
			child.shadow_enabled = false
	await capture("lighting-before")
	if main.transport.request_count != 0:
		push_error("Offline visual check attempted network access")
		quit(1)
		return
	print("Desktop entry stages and lighting frames rendered: PASS")
	quit()
