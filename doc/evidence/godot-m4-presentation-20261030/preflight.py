"""Preserve the exact new sources and build drivers before execution."""
import ast,hashlib,json,os,shutil,sys
from pathlib import Path
os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent
task=Path('/data/quod-m4-vr-ca84d4f8-20261029');label=sys.argv[1]
target=task/'private/build-inputs'/label;target.mkdir(parents=True,mode=0o700,exist_ok=False)
files=[*sorted(ev.glob('*.py')),root/'client/godot/tests/PresentationChecks.cs',root/'client/godot/tests/ExportChecks.cs',root/'client/godot/OpenXRInput.cs',root/'client/godot/ScenePanel.cs',root/'client/godot/tests/ControllerChecks.cs',root/'client/native/tools/check.py',root/'client/godot-tools/run.py',root/'client/godot-tests/desktop_input.py']
record={'label':label,'source_only':True,'files':{},'data_free_bytes':shutil.disk_usage(task).free}
for source in files:
    if source.suffix=='.py':ast.parse(source.read_text(),filename=str(source))
    destination=target/source.relative_to(root);destination.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,destination)
    record['files'][str(source.relative_to(root))]={'path':str(destination),'sha256':hashlib.sha256(destination.read_bytes()).hexdigest(),'bytes':destination.stat().st_size,'mode':destination.stat().st_mode&0o7777}
(ev/'inputs').mkdir(exist_ok=True)
(ev/'inputs'/(label+'-preflight.json')).write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'label':label,'copied_sources':len(files),'data_free_bytes':record['data_free_bytes'],'passed':True}))
