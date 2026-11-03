"""Read-only exact current case16 owner guard before the single post-card focus."""
import hashlib,json,os,subprocess,time
from pathlib import Path
os.umask(0o077);ev=Path(__file__).resolve().parent
task=Path('/data/quod-m4-vr-ca84d4f8-20261029');p=task/'private/native-vive-product16-focus-invocation.json'
owner=json.loads(p.read_text());now=time.monotonic();assert now<owner['deadline_monotonic']
proc=Path('/proc')/str(owner['pid']);data=(proc/'stat').read_text();started=data[data.rfind(')')+2:].split()[19]
exe=proc/'exe';expected=Path(owner['executable']);s=exe.stat()
assert started==owner['start_ticks'] and [s.st_dev,s.st_ino]==owner['executable_dev_inode']
assert exe.resolve()==expected.resolve() and (expected.stat().st_dev,expected.stat().st_ino)==(s.st_dev,s.st_ino)
assert os.environ['HYPRLAND_INSTANCE_SIGNATURE']==owner['instance_signature']
rows=json.loads(subprocess.check_output(['hyprctl','-j','clients'],stderr=subprocess.PIPE,timeout=5))
matched=[w for w in rows if w.get('pid')==owner['pid'] and w.get('mapped')]
assert len(matched)==1 and matched[0]['address']==owner['address'] and time.monotonic()<owner['deadline_monotonic']
record={'exact_live_incarnation':True,'checked_monotonic':time.monotonic(),'deadline_monotonic':owner['deadline_monotonic'],
 'remaining_seconds':owner['deadline_monotonic']-time.monotonic(),'actual_owner_binding_private':True,'owner_binding_sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
(ev/'pre-focus-owner-guard.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record))
