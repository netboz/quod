"""Read-only ownership/label/qualified-input check before the one authorized10."""
import hashlib,json,os,shutil,subprocess,sys
from pathlib import Path
sys.dont_write_bytecode=True
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent
sys.path.insert(0,str(ev.parent/'godot-m4-vive-retest-20261030'))
from freeze_hashes import Digests,TASK,key,raw
d=Digests();label='native-vive-product10'
paths=[TASK/'private'/label,TASK/'private/runs'/(label+'-run'),
 TASK/'private'/('quod-m4-live-'+label+'-server'),
 ev.parent/'godot-m4-vive-retest-20261030'/label,
 ev.parent/'godot-m4-vive-charged-20261029'/label,
 ev.parent/'godot-m4-vive-physical-20261029/logs'/(label+'-run.json')]
assert all(not p.exists() and not p.is_symlink() for p in paths),'Case10 label already used'
assert subprocess.check_output(['git','branch','--show-current']).decode().strip()=='worktree/pearl-stone'
assert subprocess.check_output(['git','rev-parse','HEAD']).decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert not subprocess.check_output(['git','diff','--cached','--name-only'])
assert hashlib.sha256(subprocess.check_output(['git','diff','--binary','HEAD'])).hexdigest()=='fc2482aecbfb1803f7328e4b216a449252e6d5f6bfa2a9aa5f21da5b7f2738ef'
manifest=ev.parent/'godot-m4-vive-preparation-20261030/inputs/client-physical-preparation01-manifest.json'
driver=ev.parent/'godot-m4-vive-retest-20261030/physical09.py'
assert d.h(manifest)=='e34159ae24d5ec0ddf6f2324a93c3352203337d886f25b8aa0ff3e7074e01e53'
assert d.h(driver)=='f413eee667160b1fe6594c52fda01e73fa4ad81178a816172d512fa50c6fa153'
owners=subprocess.run(['ps','-eo','pid=,comm='],capture_output=True,timeout=5);assert owners.returncode==0
active=[s for s in owners.stdout.decode().splitlines() if any(n in s.lower() for n in ['monado','godot','quod.x86','steamvr','vrserver','vrcompositor'])]
assert not active,active
monitors=json.loads(subprocess.check_output(['hyprctl','-j','monitors','all'],timeout=5))
fields=['name','disabled','width','height','refreshRate','x','y','scale','transform','dpmsStatus']
windows=json.loads(subprocess.check_output(['hyprctl','-j','clients'],timeout=5))
record={'passed':True,'label':label,'unused_paths_checked':[str(p) for p in paths],
 'active_runtime_app_processes':active,'other_mapped_windows':sum(bool(w.get('mapped')) for w in windows),
 'monitors':[{k:m.get(k) for k in fields} for m in monitors],
 'manifest_sha256':d.h(manifest),'driver_sha256':d.h(driver),
 'server_stage':'/data/quod-m4-vr-ca84d4f8-20261029/artifacts/server-runtime-restoration05',
 'qualified_closure_reused':'root73:34apps/944modules/250priv/2helpers; no replay',
 'provider_offer_proof_reused':'root79:HDMI-A-1/id828; not acquisition/tracking',
 'runtime_started':False,'user_power_answer_scope':'1793353016763 both_on: POWER only',
 'capacity_free_bytes':shutil.disk_usage(TASK).free}
(ev/'preflight.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record))
