class_name QuodResources
extends RefCounted
## Session-owned verified templates. Scene replacements reuse resources still needed.

var entries: Dictionary = {}
var fetches := 0
var decodes := 0
var revision := 0
var bridge: QuodBridge
var transport: QuodTransport

func clear() -> void:
	revision += 1
	for entry: Dictionary in entries.values():
		if entry.model:
			entry.resource.free()
	entries.clear()

func prepare(marks: Array) -> Dictionary:
	var version := revision
	var needed: Dictionary = {}
	for mark: Dictionary in marks:
		if mark.kind == "mesh":
			var result := await acquire(mark.size.digest, true, int(mark.size.allowed[0]), version, mark.size)
			if not result.ok:
				return result
			var admitted: Dictionary = JSON.parse_string(bridge.check_model(JSON.stringify(result.value.info), JSON.stringify(mark.size.allowed), JSON.stringify(mark.size.bounds)))
			if not admitted.ok:
				return admitted
			needed["model:" + mark.size.digest] = true
		if mark.material != null:
			for texture: Dictionary in mark.material.textures:
				var result := await acquire(texture.digest, false, -1, version)
				if not result.ok:
					return result
				needed["texture:" + texture.digest] = true
	return {"ok": true, "value": needed}

func retain(needed: Dictionary) -> void:
	for key: String in entries.keys():
		if not needed.has(key):
			if entries[key].model:
				entries[key].resource.free()
			entries.erase(key)

func acquire(digest: String, model: bool, maximum: int, version: int, descriptor: Dictionary = {}) -> Dictionary:
	var key := ("model:" if model else "texture:") + digest
	if entries.has(key):
		return {"ok": true, "value": entries[key]}
	fetches += 1
	var path := "/assets/models/%s.glb" % digest if model else "/assets/textures/%s.jpg" % digest
	var response := await transport.fetch(path, null, maximum)
	if not response.ok:
		return response
	if version != revision:
		return {"ok": false, "error": "Asset load cancelled."}
	var verified: Dictionary = JSON.parse_string(bridge.verify_asset(response.value, digest, model))
	if not verified.ok:
		return verified
	var resource: Variant
	if model:
		var admitted: Dictionary = JSON.parse_string(bridge.check_model(JSON.stringify(verified.value), JSON.stringify(descriptor.allowed), JSON.stringify(descriptor.bounds)))
		if not admitted.ok:
			return admitted
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		var error := document.append_from_buffer(response.value, "", state)
		if error != OK:
			return {"ok": false, "error": "Cannot decode verified GLB: " + error_string(error)}
		resource = document.generate_scene(state)
		if resource == null:
			return {"ok": false, "error": "Cannot instantiate verified GLB."}
		clean_metadata(resource)
	else:
		var image := Image.new()
		if image.load_jpg_from_buffer(response.value) != OK:
			return {"ok": false, "error": "Cannot decode verified JPEG."}
		image.generate_mipmaps()
		resource = ImageTexture.create_from_image(image)
	decodes += 1
	var entry := {"model": model, "info": verified.value, "resource": resource}
	entries[key] = entry
	return {"ok": true, "value": entry}

func clean_metadata(node: Node) -> void:
	for key: StringName in node.get_meta_list():
		node.remove_meta(key)
	for child in node.get_children():
		clean_metadata(child)
