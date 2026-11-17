#!/usr/bin/env python3
"""Separate negative engine-only repro; never a production shutdown success."""
import argparse,hashlib,json,shutil,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('--profiles',choices=['none','vive'],required=True);a=p.parse_args()
root=Path.cwd();evidence=Path(__file__).resolve().parent
project=Path('/home/yan/.cache/quod-m4-r2-artifacts/runtime')/a.label;project.mkdir(exist_ok=False)
project.joinpath('project.godot').write_text('config_version=5\n[application]\nconfig/name="Pinned engine teardown isolation"\n[xr]\nopenxr/enabled=true\nopenxr/default_action_map="res://xr_actions.tres"\n[rendering]\nrenderer/rendering_method="mobile"\n')
action=(root/'client/godot/xr_actions.tres').read_text()
if a.profiles=='none':action=action.replace('interaction_profiles = [SubResource("vive")]','interaction_profiles = []')
project.joinpath('xr_actions.tres').write_text(action)
project.joinpath('close.gd').write_text('''extends SceneTree
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
''')
inputs=evidence/'inputs'/a.label;inputs.mkdir(exist_ok=False)
for name in ['project.godot','close.gd','xr_actions.tres']:shutil.copy2(project/name,inputs/name)
shutil.copy2(__file__,inputs/'engine-isolation-driver.py')
record={'purpose':'negative engine-only isolation; direct engine quit intentionally does not claim production shutdown acceptance',
 'profiles':a.profiles,'supplied_inputs':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in inputs.iterdir()}}
(inputs/'manifest.json').write_text(json.dumps(record,indent=2)+'\n')
engine=root/'client/_build/godot-clean/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64'
command=['python3',str(evidence/'native-xr.py'),a.label,'--mode','simulated','--export',str(engine),'--project',str(project),'--script','close.gd','--completion-marker','ENGINE_ONLY_CLOSE']
raise SystemExit(subprocess.run(command).returncode)
