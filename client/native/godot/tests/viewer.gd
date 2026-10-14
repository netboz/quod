extends SceneTree
## Exercise the real bridge, renderer and resource owner, without a GPU/headset.

var failed := false

class FixtureTransport extends QuodTransport:
	var fixtures: Dictionary = {}
	var reads := 0
	func fetch(path: String, _body: Variant = null, maximum: int = -1, _deadline_ms: int = 0) -> Dictionary:
		reads += 1
		if not fixtures.has(path):
			return {"ok": false, "error": "unknown fixture asset"}
		var bytes: PackedByteArray = fixtures[path]
		if maximum >= 0 and bytes.size() > maximum:
			return {"ok": false, "error": "transfer allowance exceeded"}
		return {"ok": true, "value": bytes}

func check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var corpus: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://../../test/fixtures/native-contract/contracts.json"))
	var bridge := QuodBridge.new()
	var transport := FixtureTransport.new()
	root.add_child(transport)
	for fixture: Dictionary in corpus.glbs:
		transport.fixtures["/assets/models/%s.glb" % fixture.digest] = FileAccess.get_file_as_bytes("res://../../../" + fixture.path)
	var resources := QuodResources.new()
	resources.bridge = bridge
	resources.transport = transport
	var scene := QuodScene.new()
	scene.resources = resources
	root.add_child(scene)
	check(QuodTransport.origin("example.org", 14570).value == "https://example.org:14570", "hostname and port")
	check(QuodTransport.origin("127.0.0.1", 9443).value == "https://127.0.0.1:9443", "IPv4 and custom port")
	check(QuodTransport.origin("::1", 14570).value == "https://[::1]:14570", "IPv6 address")
	check(QuodTransport.origin("[::1]", 443).value == "https://[::1]:443", "bracketed IPv6")
	check(not transport.configure("127.0.0.1", 443, "", "localhost").is_empty(), "certificate-name override accepted without a trusted certificate")
	for invalid in [["https://example.org", 443], ["example.org/path", 443], ["user@example.org", 443], ["example.org", 0], ["example.org", 65536], ["example.org:443", 443]]:
		check(not QuodTransport.origin(invalid[0], invalid[1]).ok, "invalid destination accepted")
	var decoded: Dictionary = JSON.parse_string(bridge.decode_marks(corpus.marks[0].text))
	check(decoded.ok, "primitive projection failed")
	scene.install(decoded.value)
	var first: Node3D = scene.entries.box.node
	var before := scene.created
	scene.install(decoded.value)
	check(scene.entries.box.node == first and scene.created == before, "unchanged scene recreated nodes")
	var changed: Array = decoded.value.duplicate(true)
	changed[0].transform.x = 1250
	scene.install(changed)
	check(scene.entries.box.node == first and first.position.x == 1.25, "transform change replaced the occurrence or failed")
	var expected := Quaternion(Vector3.BACK, deg_to_rad(45.0)) * Quaternion(Vector3.UP, deg_to_rad(30.0)) * Quaternion(Vector3.RIGHT, deg_to_rad(15.0))
	check(first.quaternion.is_equal_approx(expected), "rotation composition differs")
	var picked := scene.pick(Vector3(1.25, 0.75, -4), Vector3.BACK)
	check(not picked.is_empty() and picked.depicts.entityText == "entity(18446744073709551615)", "picking lost exact subject identity")
	var model: Dictionary = JSON.parse_string(bridge.decode_marks(corpus.marks[2].text))
	var ready := await resources.prepare(model.value)
	check(ready.ok, "model resources failed: " + str(ready.get("error", "")))
	if ready.ok:
		scene.install(model.value)
		var instance: Node = scene.entries.model.node
		var frame: Node3D = scene.entries.model.visual
		check(frame.position.is_equal_approx(Vector3(0, 0, 0.1)), "front/pivot mapping differs")
		var counts := [transport.reads, resources.decodes, scene.created]
		var again := await resources.prepare(model.value)
		check(again.ok, "unchanged resources failed")
		scene.install(model.value)
		check(counts == [transport.reads, resources.decodes, scene.created], "unchanged repeat fetched, decoded or created nodes")
		check(scene.entries.model.node == instance, "model instance not retained")
		var too_small: Array = model.value.duplicate(true)
		too_small[0].size.allowed[2] = 1
		var denied := await resources.prepare(too_small)
		check(not denied.ok, "shared cache bypassed occurrence allowance")
		var fresh := QuodResources.new()
		fresh.bridge = bridge
		fresh.transport = transport
		denied = await fresh.prepare(too_small)
		check(not denied.ok and fresh.decodes == 0, "over-budget asset reached decoder")
		fresh.clear()
	var hierarchy: Dictionary = JSON.parse_string(bridge.decode_marks(corpus.marks[1].text))
	scene.install(hierarchy.value)
	var child: Node3D = scene.entries.sphere.node
	var survivor: Dictionary = hierarchy.value[1].duplicate(true)
	survivor.parent = null
	scene.install([survivor])
	check(is_instance_valid(child) and child.get_parent() == scene, "removed parent destroyed retained child")
	scene.clear()
	resources.retain({})
	check(resources.entries.is_empty(), "removed scene retained resources")
	resources.clear()
	scene.free()
	transport.free()
	print("Native viewer checks: ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
