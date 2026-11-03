"""Invoke the exact qualified listener through the existing retained wrapper."""
import hashlib,json,os,shutil,sys,time
from pathlib import Path
os.umask(0o077);root=Path.cwd();task=Path('/data/quod-m4-vr-ca84d4f8-20261029')
ownerfile=task/'private/native-vive-product12-focus-invocation.json';owner=json.loads(ownerfile.read_text())
assert time.monotonic()<owner['deadline_monotonic']
helper=root/'doc/evidence/godot-m4-vive-retest10-20261030/focus_events.py'
assert hashlib.sha256(helper.read_bytes()).hexdigest()=='bb63ff9db8f3aef231f22043e8336c263afcf52b553c908419ff3e0abdd584e2'
manual=root/'doc/evidence/godot-m4-vive-physical-20261029/manual_run.py'
command=[sys.executable,'-B',str(manual),'native-vive-product12-focus-run','--',sys.executable,'-B',str(helper),
    '--pid',str(owner['pid']),'--address',owner['address'],'--executable',owner['executable'],
    '--instance-signature',owner['instance_signature'],'--deadline-monotonic',str(owner['deadline_monotonic']),
    '--private-dir',owner['private_dir']]
copies=task/'private/build-inputs/native-vive-product12-focus';copies.mkdir(mode=0o700,exist_ok=False);inputs={}
for p in [helper,manual,Path(__file__).resolve(),manual.parent/'publication.py']:
    q=copies/p.name;shutil.copy2(p,q);inputs[str(p.relative_to(root))]={'sha256':hashlib.sha256(q.read_bytes()).hexdigest(),'mode':q.stat().st_mode&0o7777}
owner['actual_command']=command;owner['preexecution_sources']=inputs
ownerfile.write_text(json.dumps(owner,indent=2)+'\n')
os.execv(sys.executable,command)
