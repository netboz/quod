extends SceneTree

func _initialize():
	var contains_output := DirAccess.dir_exists_absolute("res://dist")
	print("EXPORT_OUTPUT_DIRECTORY_PRESENT=", contains_output)
	quit(1 if contains_output else 0)
