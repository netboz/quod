"""Retain the exact unchanged execution sources before authorized case10."""
import hashlib,json,os,shutil,sys
from pathlib import Path
sys.dont_write_bytecode=True
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent
task=Path('/data/quod-m4-vr-ca84d4f8-20261029');label='native-vive-product10'
target=task/'private/build-inputs'/label;target.mkdir(mode=0o700,exist_ok=False)
names=['doc/evidence/godot-m4-vive-retest-20261030/physical09.py',
 'doc/evidence/godot-m4-vive-physical-20261029/manual_run.py',
 'doc/evidence/godot-m4-vive-physical-20261029/serve.py',
 'doc/evidence/godot-m4-vive-physical-20261029/environment.py',
 'doc/evidence/godot-m4-vive-physical-20261029/godot_m3b_fixture.erl',
 'doc/evidence/godot-m4-vive-physical-20261029/godot_m3b_physics_fixture.erl',
 'doc/evidence/godot-m4-r2-20261029/private_vive.py',
 'doc/evidence/godot-m4-vr-20261029/vive_display.py',
 'doc/evidence/godot-m4-vive-preparation-20261030/inputs/client-physical-preparation01-manifest.json']
record={'label':label,'scope':'Exact retained sources, no driver adaptation/build or application launched by this metadata helper.',
 'sources':{},'driver_unchanged':True,'product_changes':0}
for n in names:
 p=root/n;q=target/n;q.parent.mkdir(mode=0o700,parents=True,exist_ok=True);shutil.copy2(p,q)
 digest=hashlib.sha256(p.read_bytes()).hexdigest();assert hashlib.sha256(q.read_bytes()).hexdigest()==digest
 record['sources'][n]={'sha256':digest,'mode':p.stat().st_mode&0o7777,'bytes':p.stat().st_size,'saved':str(q)}
(ev/'preexecution.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'passed':True,'source_copies':len(names),'driver_unchanged':True,'runtime_started':False}))
