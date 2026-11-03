"""One read-only query of this case's private Monado service, never global IPC."""
import hashlib,json,os,re,subprocess,sys
from pathlib import Path
from environment import TASK,environment
os.umask(0o077);ev=Path(__file__).resolve().parent;case=sys.argv[1]
assert case=='native-vive-product03'
private=TASK/'private'/case/'inventory01';private.mkdir(mode=0o700,exist_ok=False)
runtime=Path('/home/yan/.cache/quod-m4-r2-artifacts/runtime/monado-compatible02-install')
env=environment();env['XDG_RUNTIME_DIR']=str(private.parent/'runtime')
command=[str(runtime/'bin/monado-ctl')];r=subprocess.run(command,env=env,capture_output=True,timeout=5)
record={'case':case,'command':command,'private_ipc':env['XDG_RUNTIME_DIR'],'true_child_exit':r.returncode,'streams':{},'scope':'One temporary inventory client on the owned service; not an application session or hardware gesture.'}
for name,data in [('stdout',r.stdout),('stderr',r.stderr)]:
    p=private/(name+'.raw');p.write_bytes(data);p.chmod(0o600)
    sanitized=re.sub(rb'(?i)LHR-[A-Za-z0-9]+',b'<device-serial-redacted>',data)
    target=ev/case/('inventory01-'+name+'.log');target.write_bytes(sanitized)
    record['streams'][name]={'raw':str(p),'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),'sanitized_sha256':hashlib.sha256(sanitized).hexdigest()}
(ev/case/'inventory01.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record))
raise SystemExit(r.returncode)
