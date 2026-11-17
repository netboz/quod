extends SceneTree

# The exported pack holds no build output, and it carries the rain shader and
# its font; the font's licence ships beside the executable.
func _initialize():
	var contains_output := DirAccess.dir_exists_absolute("res://dist")
	print("EXPORT_OUTPUT_DIRECTORY_PRESENT=", contains_output)
	var shader := load("res://rain.gdshader") as Shader
	print("RAIN_SHADER=", shader != null and shader.code.contains("held_time"))
	var font := load("res://assets/JetBrainsMonoNL-Bold.ttf") as FontFile
	var digest := ""
	if font != null:
		var hashing := HashingContext.new()
		hashing.start(HashingContext.HASH_SHA256)
		hashing.update(font.data)
		digest = hashing.finish().hex_encode()
	var exact := digest == "0198e841824025f8876e5c297f0b9b497ee8d6eb9969710a3328e1303f996ec3"
	print("RAIN_FONT=", exact)
	var notice := OS.get_cmdline_user_args()[0] + "/rain-font-LICENSE.txt"
	var licence := FileAccess.file_exists(notice) and FileAccess.get_file_as_string(notice).contains("SIL Open Font License")
	print("RAIN_FONT_LICENCE=", licence)
	quit(0 if not contains_output and shader != null and exact and licence else 1)
