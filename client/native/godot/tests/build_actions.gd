extends SceneTree
## Build a pinned, inspectable action resource. Run only when editing bindings.

func _initialize() -> void:
	var action_map := OpenXRActionMap.new()
	var action_set := OpenXRActionSet.new()
	action_set.resource_name = "quod_viewer"
	action_set.localized_name = "Quod viewer"
	var actions: Dictionary = {}
	for item in [["aim", 3], ["grip_pose", 3], ["select", 0], ["squeeze", 0], ["touchpad", 2], ["touchpad_click", 0]]:
		var action := OpenXRAction.new()
		action.resource_name = item[0]
		action.localized_name = item[0].capitalize()
		action.action_type = item[1]
		action.toplevel_paths = PackedStringArray(["/user/hand/left", "/user/hand/right"])
		action_set.add_action(action)
		actions[item[0]] = action
	action_map.add_action_set(action_set)
	var profiles := {
		"/interaction_profiles/htc/vive_controller": {"aim": "aim/pose", "grip_pose": "grip/pose", "select": "trigger/click", "squeeze": "squeeze/click", "touchpad": "trackpad", "touchpad_click": "trackpad/click"},
		"/interaction_profiles/khr/simple_controller": {"aim": "aim/pose", "grip_pose": "grip/pose", "select": "select/click"},
	}
	for name: String in profiles:
		var profile := OpenXRInteractionProfile.new()
		profile.interaction_profile_path = name
		var bindings: Array[OpenXRIPBinding] = []
		for action: String in profiles[name]:
			for hand in ["left", "right"]:
				var binding := OpenXRIPBinding.new()
				binding.action = actions[action]
				binding.binding_path = "/user/hand/%s/input/%s" % [hand, profiles[name][action]]
				bindings.append(binding)
		profile.bindings = bindings
		action_map.add_interaction_profile(profile)
	var result := ResourceSaver.save(action_map, "res://xr_actions.tres")
	quit(0 if result == OK else 1)
