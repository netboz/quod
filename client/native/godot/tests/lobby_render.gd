extends SceneTree
## Offline rendering of the packaged lobby through the production resource owner.
class LocalAssets extends QuodTransport:
	func fetch(path: String, _body: Variant = null, _maximum: int = -1, _deadline_ms: int = 0) -> Dictionary:
		return {"ok": true, "value": FileAccess.get_file_as_bytes("res://../../../priv/explorer" + path)}

var destination := OS.get_environment("QUOD_RENDER_EVIDENCE")

func _initialize() -> void:
	create_timer(40).timeout.connect(func(): push_error("Lobby render deadline"); quit(1))
	run.call_deferred()

func capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(destination.path_join(name + ".png"))

func run() -> void:
	var main = load("res://main.tscn").instantiate()
	main.auto_restore = false
	root.add_child(main)
	root.content_scale_size = Vector2i(1280, 800)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	main.bridge = QuodBridge.new()
	main.resources.bridge = main.bridge
	var local := LocalAssets.new()
	root.add_child(local)
	main.resources.transport = local
	var parts := PackedStringArray()
	for digest: String in ["766c7015b7281f6009838145a06ae8c8b61c37bfc6116be16aaeaba1d8b817ee", "e2342ad365f644003e22372f41a25e833541c6c30b314ac539534e5c3a077121", "2be70465da809e6e29b8b12aae01a568e54cd150e86f35f790e06a61fc82bc04"]:
		var bytes := FileAccess.get_file_as_bytes("res://../../../priv/explorer/assets/models/" + digest + ".glb")
		var info: Dictionary = JSON.parse_string(main.bridge.verify_asset(bytes, digest, true))
		if not info.ok:
			push_error(info.error)
			quit(1)
			return
		var bounds := PackedStringArray()
		var costs := PackedStringArray()
		for number in info.value.boundsMm:
			bounds.append(str(int(number)))
		for number in info.value.costs:
			costs.append(str(maxi(1, int(number))))
		var pivot := "0,-929,0" if parts.size() == 2 else "0,0,0"
		parts.append('mark(<<"%s">>,<<"mesh">>,mesh_asset(asset(<<"%s">>,<<"model/gltf-binary">>),<<"gltf2-static-v1">>,scale(1000),frame(aabb(%s),pivot(%s),front(<<"-z">>)),resources(%s)),transform(0,0,0,0,0,0),asset_surfaces,unlabelled,depicts_nothing)' % [digest, digest, ",".join(bounds), pivot, ",".join(costs)])
	parts.append('mark(<<"sky">>,<<"sky_sphere">>,[f(<<"diameter">>,80000)],transform(0,0,0,0,0,0),surface(<<"#849DBD">>,0,1000,0,[]),unlabelled,depicts_nothing)')
	var marks: Dictionary = JSON.parse_string(main.bridge.decode_marks("[" + ",".join(parts) + "]"))
	if not marks.ok:
		push_error(marks.error)
		quit(1)
		return
	var prepared: Dictionary = await main.resources.prepare(marks.value)
	if not prepared.ok:
		push_error(prepared.error)
		quit(1)
		return
	main.scene.install(marks.value)
	main.set_stage(main.Stage.WORLD)
	main.desktop_camera.enabled = false
	for frame in range(12):
		await RenderingServer.frame_post_draw
	await capture("after")
	var after := roof_range(root.get_texture().get_image())
	var sky: MeshInstance3D = main.scene.entries.sky.visual
	if sky.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
		push_error("Sky backdrop casts shadows")
		quit(1)
		return
	var environment: WorldEnvironment
	var light: DirectionalLight3D
	for child in main.get_children():
		if child is WorldEnvironment:
			environment = child
		if child is DirectionalLight3D:
			light = child
	var delivered := environment.environment
	var previous := delivered.duplicate() as Environment
	previous.sky = null
	previous.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	previous.ambient_light_color = Color("c4dcff")
	previous.ambient_light_energy = 0.22
	previous.reflected_light_source = Environment.REFLECTION_SOURCE_BG
	environment.environment = previous
	light.directional_shadow_max_distance = 100.0
	light.directional_shadow_blend_splits = false
	RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_LOW)
	await capture("before")
	var before := roof_range(root.get_texture().get_image())
	# This sloped, shadowed roof patch was a uniform color with the old fill.
	if after - before < 0.02:
		push_error("Shadowed geometry lost its directional shading")
		quit(1)
		return
	print("Shadowed roof luminance range: ", JSON.stringify({"before": before, "after": after}))
	environment.environment = delivered
	light.directional_shadow_max_distance = 30.0
	light.directional_shadow_blend_splits = true
	RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_HIGH)
	main.desktop_camera.position.x += 0.25
	await capture("after-moved")
	var created: int = main.scene.created
	var decodes: int = main.resources.decodes
	main.scene.install(marks.value)
	await main.resources.prepare(marks.value)
	if main.scene.created != created or main.resources.decodes != decodes:
		push_error("Unchanged lobby recreated geometry or decoded models")
		quit(1)
		return
	print("Packaged lobby, shadowed surface shape and unchanged resource reuse: PASS")
	quit()

func roof_range(frame: Image) -> float:
	var minimum := 1.0
	var maximum := 0.0
	for y in range(130, 250, 4):
		for x in range(480, 800, 4):
			var brightness := frame.get_pixel(x, y).get_luminance()
			minimum = minf(minimum, brightness)
			maximum = maxf(maximum, brightness)
	return maximum - minimum
