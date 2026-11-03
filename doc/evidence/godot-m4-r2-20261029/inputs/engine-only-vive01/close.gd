extends SceneTree
var frames = 0
func _initialize():
    var origin = XROrigin3D.new()
    root.add_child(origin)
    var camera = XRCamera3D.new()
    origin.add_child(camera)
    root.use_xr = true
func _process(_delta):
    frames += 1
    if frames == 90:
        var file = FileAccess.open(OS.get_environment("M1B_RESULT"), FileAccess.WRITE)
        file.store_string(JSON.stringify({"frames": frames, "engine_only": true, "production_shutdown": false}))
        file.close()
        print("ENGINE_ONLY_CLOSE")
        quit()
    return false
