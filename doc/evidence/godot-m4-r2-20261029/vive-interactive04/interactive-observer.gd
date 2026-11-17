# Read-only human observation of the ordinary exported application.
# No domain action, mapping, tracking pose or input value is fabricated here.
extends SceneTree
var app: Node
var instruction: Label
var trackers = {}
var observations = {}
var states = {}
var started = false
var frames = 0
var components = ["trigger_press", "squeeze_press", "pad_press"]

func _initialize():
    app = load("res://main.tscn").instantiate()
    app.ready.connect(_application_ready)
    root.add_child.call_deferred(app)

func _application_ready():
    root.title = "Quod — Vive observation"
    XRServer.tracker_added.connect(_tracker_event)
    XRServer.tracker_removed.connect(_tracker_event)
    XRServer.tracker_updated.connect(_tracker_event)
    for name in XRServer.get_trackers(XRServer.TRACKER_CONTROLLER):
        _reconcile(name)
    app.find_child("start-xr", true, false).emit_signal("pressed")
    instruction = Label.new()
    instruction.text = "VIVE OBSERVATION READY — no time limit for this human step\nPress/release trigger, grip and touchpad on each wand.\nReturn to Nimbalyst and select Done when finished."
    instruction.position = Vector2(30, 30)
    instruction.mouse_filter = Control.MOUSE_FILTER_IGNORE
    app.find_child("gui-viewport", true, false).add_child(instruction)
    started = true
    print("M4_INTERACTIVE_XR_READY")

func _tracker_event(name, _type):
    _reconcile.call_deferred(name)

func _reconcile(name):
    var tracker = XRServer.get_tracker(name)
    if tracker is XRControllerTracker:
        trackers[name] = tracker
        if not observations.has(str(name)):
            observations[str(name)] = {"profile": tracker.profile, "hand": tracker.hand,
                "tracked_frames": 0, "released": [], "edges": [], "previous": {}, "neutral": {}, "down": {}}
    else:
        trackers.erase(name)

func _process(_delta):
    if not started:
        return false
    frames += 1
    var xr = XRServer.find_interface("OpenXR")
    var state = str(xr.get_session_state())
    states[state] = states.get(state, 0) + 1
    for name in trackers:
        var tracker = trackers[name]
        var row = observations[str(name)]
        row.profile = tracker.profile
        row.hand = tracker.hand
        row.aim = str(tracker.get_pose("aim").tracking_confidence) if tracker.has_pose("aim") else "missing"
        row.grip = str(tracker.get_pose("grip_pose").tracking_confidence) if tracker.has_pose("grip_pose") else "missing"
        var pose_state = row.aim + ":" + row.grip
        if row.get("last_pose_state", "") != pose_state:
            row.last_pose_state = pose_state
            print("M4_INTERACTIVE_POSE ", JSON.stringify({"source": str(name), "aim": row.aim, "grip": row.grip, "frame": frames}))
        if tracker.has_pose("aim") and tracker.has_pose("grip_pose") and tracker.get_pose("aim").has_tracking_data and tracker.get_pose("grip_pose").has_tracking_data:
            row.tracked_frames += 1
        for component in components:
            var value = tracker.get_input(component)
            if typeof(value) != TYPE_BOOL:
                continue
            if not value:
                row.neutral[component] = true
            var before = row.previous.get(component, false)
            if value != before:
                row.edges.append({"component": component, "pressed": value, "frame": frames})
                print("M4_INTERACTIVE_INPUT ", str(name), " ", component, " ", value)
                print("M4_INTERACTIVE_SAMPLE ", JSON.stringify({"source": str(name), "aim": row.aim, "grip": row.grip, "tracked_frames": row.tracked_frames, "edges": row.edges}))
            if value and not before and row.neutral.has(component):
                row.down[component] = true
            if not value and before and row.down.has(component) and not row.released.has(component):
                row.released.append(component)
            row.previous[component] = value
    return false

func _finalize():
    XRServer.tracker_added.disconnect(_tracker_event)
    XRServer.tracker_removed.disconnect(_tracker_event)
    XRServer.tracker_updated.disconnect(_tracker_event)
    trackers.clear()
    for row in observations.values():
        row.erase("previous")
        row.erase("neutral")
        row.erase("down")
    var file = FileAccess.open(OS.get_environment("M4_INTERACTIVE_RESULT"), FileAccess.WRITE)
    file.store_string(JSON.stringify({"observation_only": true, "frames": frames, "states": states, "sources": observations}))
    file.close()
    print("M4_INTERACTIVE_OBSERVATION_RECORDED")
