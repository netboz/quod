"""Retain exact diagnostic sources before the separate source-only build."""
import ast,difflib,hashlib,json,os,shutil,sys,zipfile
from pathlib import Path

os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent
old=root/'doc/evidence/godot-m4-vive-physical-20261029'
task=Path('/data/quod-m4-vr-ca84d4f8-20261029')
label=sys.argv[1];output_prefix=sys.argv[2];destination=task/'private/build-inputs'/label
destination.mkdir(mode=0o700,parents=True,exist_ok=False)
items=[(ev/n,n) for n in ['PhysicalChecks.cs','physical.py','build.py','build_preflight.py']]
items += [(old/'environment.py','environment.py'),(old/'manual_run.py','manual_run.py'),
          (root/'client/native/tools/check.py','client-native-check.py'),
          (root/'client/godot-tools/run.py','godot-tools-run.py')]
record={'label':label,'pre_execution_copies':{},'production_inputs_changed':0,
        'csharp_build_executed':False,'diagnostic_distributable':False}
for source,name in items:
    if source.suffix=='.py':ast.parse(source.read_text(),filename=str(source))
    copy=destination/name;shutil.copy2(source,copy)
    record['pre_execution_copies'][str(source.relative_to(root))]={
        'path':str(copy),'sha256':hashlib.sha256(copy.read_bytes()).hexdigest(),
        'bytes':copy.stat().st_size,'mode':copy.stat().st_mode&0o7777}
manifest=json.loads((old/'inputs/client-physical02-manifest.json').read_text())
package=Path(manifest['dependency_archives']['godotsharp.4.7.2.nupkg']['referenced_path'])
with zipfile.ZipFile(package) as archive:
    xml=archive.read('lib/net8.0/GodotSharp.xml').decode()
required=['P:Godot.XRServer.CameraLockedToOrigin','M:Godot.VisualInstance3D.GetAabb',
          'M:Godot.Viewport.GetCamera3D','M:Godot.Window.HasFocus',
          'P:Godot.XROrigin3D.Current','P:Godot.XRServer.WorldScale',
          'P:Godot.XRServer.WorldOrigin','M:Godot.XRServer.GetReferenceFrame',
          'M:Godot.XRServer.GetHmdTransform',
          'M:Godot.XRInterface.GetTransformForView(System.UInt32,Godot.Transform3D)',
          'M:Godot.RenderingServer.CallOnRenderThread(Godot.Callable)']
record['pinned_api_members']={name:name in xml for name in required}
assert all(record['pinned_api_members'].values())
patch=[]
for name in ['PhysicalChecks.cs','physical.py','build.py']:
    patch.extend(difflib.unified_diff((old/name).read_text().splitlines(True),
        (ev/name).read_text().splitlines(True),fromfile=str((old/name).relative_to(root)),
        tofile=str((ev/name).relative_to(root))))
(ev/'inputs'/(output_prefix+'.patch')).write_text(''.join(patch))
record['passed']=True
(ev/'inputs'/(output_prefix+'.json')).write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record))
