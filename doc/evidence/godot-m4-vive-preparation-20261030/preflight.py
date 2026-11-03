"""Retain the exact build inputs before the offline diagnostic compilation."""
import ast,hashlib,json,os,shutil,sys
sys.dont_write_bytecode=True
from pathlib import Path
os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent
task=Path('/data/quod-m4-vr-ca84d4f8-20261029');label='physical-preparation01'
target=task/'private/build-inputs'/label
target.mkdir(mode=0o700,parents=True,exist_ok=False)
files=[*sorted(ev.glob('*.py')),
 root/'doc/evidence/godot-m4-presentation-20261030/build.py',
 root/'doc/evidence/godot-m4-presentation-20261030/digests.py',
 root/'doc/evidence/godot-m4-vive-physical-20261029/environment.py',
 root/'doc/evidence/godot-m4-vive-charged-20261029/PhysicalChecks.cs',
 root/'doc/evidence/godot-m4-vive-charged-20261029/inputs/client-physical04-manifest.json',
 root/'doc/evidence/godot-m4-presentation-20261030/inputs/client-presentation-final02-manifest.json',
 root/'client/godot/tests/ExportChecks.cs',root/'client/native/tools/check.py',
 root/'client/godot-tools/run.py']
record={'label':label,'offline_build_only':True,'files':{},
 'data_free_bytes':shutil.disk_usage(task).free,'compiled_application_inputs_copied':False,
 'native_runtime_started':False,'functional_application_started':False}
for p in files:
 if p.suffix=='.py':ast.parse(p.read_text(),filename=str(p))
 q=target/p.relative_to(root);q.parent.mkdir(mode=0o700,parents=True,exist_ok=True);shutil.copy2(p,q)
 record['files'][str(p.relative_to(root))]={'path':str(q),'sha256':hashlib.sha256(q.read_bytes()).hexdigest(),
  'bytes':q.stat().st_size,'mode':q.stat().st_mode&0o7777}
assert record['data_free_bytes']>2_000_000_000
(ev/'inputs/preflight01.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'passed':True,'copied_sources':len(files),'data_free_bytes':record['data_free_bytes']}))
