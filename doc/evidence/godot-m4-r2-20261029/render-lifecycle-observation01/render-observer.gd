# Qualification-only, bounded observation of the ordinary application owners.
extends SceneTree
var app: Node
var scene: SubViewportContainer
var viewport: SubViewport
var records = []
var frames = 0

func _initialize():
    app = load("res://main.tscn").instantiate()
    app.ready.connect(_application_ready)
    root.add_child.call_deferred(app)

func _application_ready():
    scene = app.find_child("space-scene", true, false)
    viewport = app.find_child("scene-viewport", true, false)
    scene.visibility_changed.connect(_visibility)
    root.visibility_changed.connect(_window_visibility)
    RenderingServer.frame_post_draw.connect(_frame)
    _record("application_ready")

func _record(reason):
    if records.size() >= 30:
        return
    var row = {"reason": reason, "frame": frames, "scene_visible": scene.visible,
        "scene_visible_in_tree": scene.is_visible_in_tree(), "window_visible": root.visible,
        "update_mode": viewport.render_target_update_mode, "use_xr": viewport.use_xr,
        "view_count": viewport.view_count, "size": str(viewport.size),
        "draw_calls": viewport.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)}
    records.append(row)
    print("M4_RENDER_OBSERVATION ", JSON.stringify(row))

func _visibility():
    _record("scene_visibility")

func _window_visibility():
    _record("window_visibility")

func _frame():
    frames += 1
    if frames <= 4 or frames == 60 or frames == 85:
        _record("frame_post_draw")

func _finalize():
    if scene != null:
        scene.visibility_changed.disconnect(_visibility)
        root.visibility_changed.disconnect(_window_visibility)
        RenderingServer.frame_post_draw.disconnect(_frame)
    var file = FileAccess.open(OS.get_environment("M1B_RESULT") + ".render-observation.json", FileAccess.WRITE)
    file.store_string(JSON.stringify({"observation_only": true, "records": records}))
    file.close()
