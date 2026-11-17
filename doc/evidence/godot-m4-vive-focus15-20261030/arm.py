"""Private-argument invocation of the exact recipient97 listener; no owner change."""
import hashlib,json,os,shutil,sys,time
from pathlib import Path
os.umask(0o077);root=Path.cwd();task=Path('/data/quod-m4-vr-ca84d4f8-20261029')
ownerfile=task/'private/native-vive-product15-focus-invocation.json';owner=json.loads(ownerfile.read_text())
assert time.monotonic()<owner['deadline_monotonic']
helper=root/'doc/evidence/godot-m4-vive-retest10-20261030/focus_events.py'
assert hashlib.sha256(helper.read_bytes()).hexdigest()=='a7b584c8b137b5617b89a98e57f6f42e895d3247278b4c3de52b595ecbea5889'
roles=task/'private/case15-preparation01/bindings.json'
assert roles.stat().st_mode&0o7777==0o600 and roles.parent.stat().st_mode&0o7777==0o700
assert json.loads(roles.read_text())==[]
manual=task/'private/case15-preparation01/unchanged-owners/godot-m4-vive-physical-20261029/manual_run.py'
command=[sys.executable,'-B',str(helper),'--pid',str(owner['pid']),'--address',owner['address'],
    '--executable',owner['executable'],'--instance-signature',owner['instance_signature'],
    '--deadline-monotonic',str(owner['deadline_monotonic']),'--private-dir',owner['private_dir'],
    '--recipient-bindings',str(roles)]
copies=task/'private/build-inputs/native-vive-product15-focus';copies.mkdir(mode=0o700,exist_ok=False);inputs={}
for p in [helper,manual,Path(__file__).resolve(),manual.parent/'publication.py',manual.parent/'environment.py']:
    q=copies/p.name;shutil.copy2(p,q);inputs[str(p)]={'sha256':hashlib.sha256(q.read_bytes()).hexdigest(),'mode':q.stat().st_mode&0o7777}
shutil.copy2(roles,copies/'bindings.json')
owner['actual_command']=command;owner['preexecution_sources']=inputs
owner['recipient_binding_sha256']=hashlib.sha256(roles.read_bytes()).hexdigest()
owner['live_invocation_and_role_bindings_public']=False
ownerfile.write_text(json.dumps(owner,indent=2)+'\n')
os.execv(sys.executable,command)
