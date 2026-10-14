class_name QuodScene
extends Node3D
## Reconciles visual occurrences; owns no domain state or physical simulation.

var entries: Dictionary = {}
var created := 0
var resources: QuodResources

func clear() -> void:
	for entry: Dictionary in entries.values():
		if entry.node.get_parent():
			entry.node.get_parent().remove_child(entry.node)
	for entry: Dictionary in entries.values():
		remove_occurrence(entry.node)
	entries.clear()

func remove_occurrence(node: Node) -> void:
	# Retained occurrences are reparented before any retired ancestor is freed.
	if is_instance_valid(node):
		if node.get_parent():
			node.get_parent().remove_child(node)
		node.free()

func install(marks: Array) -> void:
	var next: Dictionary = {}
	var retired: Array[Node] = []
	for mark: Dictionary in marks:
		var entry: Dictionary = entries.get(mark.id, {})
		var geometry: Array = [mark.kind, mark.size]
		if entry.is_empty() or entry.geometry != geometry:
			if not entry.is_empty():
				retired.append(entry.node)
			var root := Node3D.new()
			root.name = "Occurrence"
			add_child(root)
			var visual: Node3D = make_visual(mark)
			root.add_child(visual)
			entry = {"node": root, "visual": visual, "geometry": geometry, "mark": {}, "label": null}
			created += 1
		var root: Node3D = entry.node
		var parent: Node3D = self if mark.parent == null else next[mark.parent].node
		if root.get_parent() != parent:
			root.reparent(parent, false)
		if entry.mark != mark:
			var t: Dictionary = mark.transform
			root.position = Vector3(t.x, t.y, t.z) / 1000.0
			root.quaternion = Quaternion(Vector3.BACK, deg_to_rad(t.rz)) * Quaternion(Vector3.UP, deg_to_rad(t.ry)) * Quaternion(Vector3.RIGHT, deg_to_rad(t.rx))
			root.set_meta("depicts", mark.depicts)
			root.set_meta("mark_id", mark.id)
			if mark.material != null and entry.mark.get("material") != mark.material:
				(entry.visual as MeshInstance3D).material_override = material(mark)
			if entry.label == null or entry.mark.get("label") != mark.label or entry.mark.get("size") != mark.size:
				if entry.label != null:
					entry.label.free()
				entry.label = null
				if mark.label != null:
					var label := Label3D.new()
					label.text = mark.label.text
					label.font_size = 40
					label.pixel_size = 0.0055
					label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
					label.position.y = label_offset(mark)
					root.add_child(label)
					entry.label = label
			entry.mark = mark
		next[mark.id] = entry
	for id: String in entries:
		if not next.has(id):
			retired.append(entries[id].node)
	# Detach all retired roots first so freeing a parent cannot free another entry twice.
	for node in retired:
		if node.get_parent():
			node.get_parent().remove_child(node)
	for node in retired:
		node.free()
	entries = next

func make_visual(mark: Dictionary) -> Node3D:
	var s: Dictionary = mark.size
	if mark.kind == "group":
		return Node3D.new()
	if mark.kind == "mesh":
		var frame := Node3D.new()
		var model: Node = resources.entries["model:" + s.digest].resource.duplicate()
		frame.add_child(model)
		var yaw: float = {"-z": 0.0, "+z": PI, "+x": PI / 2.0, "-x": -PI / 2.0}[s.front]
		frame.rotation.y = yaw
		frame.scale = Vector3.ONE * s.scale
		frame.position = -(Basis(Vector3.UP, yaw) * Vector3(s.pivot[0], s.pivot[1], s.pivot[2])) * s.scale / 1000.0
		return frame
	var instance := MeshInstance3D.new()
	var mesh: Variant
	match mark.kind:
		"box":
			mesh = BoxMesh.new()
			mesh.size = Vector3(s.width, s.height, s.depth) / 1000.0
		"plane":
			mesh = QuadMesh.new()
			mesh.size = Vector2(s.width, s.height) / 1000.0
			mesh.flip_faces = true
		"sphere", "sky_sphere":
			mesh = SphereMesh.new()
			mesh.radius = s.diameter / 2000.0
			mesh.height = s.diameter / 1000.0
		"cylinder":
			mesh = CylinderMesh.new()
			mesh.top_radius = s.diameter / 2000.0
			mesh.bottom_radius = s.diameter / 2000.0
			mesh.height = s.height / 1000.0
		"capsule":
			mesh = CapsuleMesh.new()
			mesh.radius = s.diameter / 2000.0
			mesh.height = s.height / 1000.0
		"torus":
			mesh = TorusMesh.new()
			mesh.inner_radius = (s.diameter - s.thickness) / 2000.0
			mesh.outer_radius = (s.diameter + s.thickness) / 2000.0
	instance.mesh = mesh
	if mark.kind == "sky_sphere":
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance

func material(mark: Dictionary) -> ShaderMaterial:
	var out := ShaderMaterial.new()
	out.shader = preload("res://sky.gdshader") if mark.kind == "sky_sphere" else preload("res://surface.gdshader")
	var m: Dictionary = mark.material
	out.set_shader_parameter("colour", Color(m.colour))
	if mark.kind != "sky_sphere":
		out.set_shader_parameter("metal", m.metallic)
		out.set_shader_parameter("rough", m.roughness)
		out.set_shader_parameter("emission", m.emission)
	for texture: Dictionary in m.textures:
		var slot: String = {"base_colour": "base", "normal": "normal", "orm": "orm"}[texture.slot]
		out.set_shader_parameter("has_" + slot, true)
		out.set_shader_parameter(slot + "_map", resources.entries["texture:" + texture.digest].resource)
		out.set_shader_parameter(slot + "_repeat", Vector2(texture.repeat[0], texture.repeat[1]))
	return out

func label_offset(mark: Dictionary) -> float:
	var s: Dictionary = mark.size
	var placement: String = mark.label.placement
	if mark.kind == "mesh":
		if placement == "above":
			return (s.bounds[4] - s.pivot[1]) * s.scale / 1000.0 + 0.22
		if placement == "below":
			return (s.bounds[1] - s.pivot[1]) * s.scale / 1000.0 - 0.22
		return ((s.bounds[1] + s.bounds[4]) / 2.0 - s.pivot[1]) * s.scale / 1000.0
	var extent: float = s.get("height", s.get("diameter", 0)) / 1000.0
	return (extent / 2.0 + 0.22) * (1 if placement == "above" else -1) if placement != "centre" else 0.0

func pick(origin: Vector3, direction: Vector3) -> Dictionary:
	var nearest := INF
	var selected: Dictionary = {}
	for entry: Dictionary in entries.values():
		if entry.mark.kind == "sky_sphere" or entry.mark.depicts == null:
			continue
		var pending: Array[Node] = [entry.visual]
		while not pending.is_empty():
			var node: Node = pending.pop_back()
			pending.append_array(node.get_children())
			if node is MeshInstance3D and node.mesh != null:
				var inverse: Transform3D = node.global_transform.affine_inverse()
				var hit: Variant = node.get_aabb().intersects_ray(inverse * origin, inverse.basis * direction)
				if hit != null:
					var distance: float = origin.distance_to(node.global_transform * hit)
					if distance < nearest:
						nearest = distance
						selected = {"id": entry.mark.id, "depicts": entry.mark.depicts}
	return selected
