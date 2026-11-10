extends SceneTree

func _initialize():
    call_deferred("probe")

func probe():
    var editor = TextEdit.new()
    editor.size = Vector2(1100, 700)
    editor.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY if OS.get_environment("WRAP_PROBE") == "boundary" else TextEdit.LINE_WRAPPING_NONE
    root.add_child(editor)
    var text = FileAccess.get_file_as_string("/home/yan/src/quod_worktrees/pearl-stone/priv/ontologies/quod_gui.pl")
    var start = Time.get_ticks_usec()
    print("PROBE_BIND_START characters=", text.length())
    editor.text = text
    print("PROBE_BOUND elapsed_us=", Time.get_ticks_usec() - start)
    await process_frame
    await process_frame
    print("PROBE_FRAME elapsed_us=", Time.get_ticks_usec() - start)
    quit(0)
