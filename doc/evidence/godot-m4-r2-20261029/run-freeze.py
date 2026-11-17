#!/usr/bin/env python3
"""Keep freeze output/true status outside the source being frozen."""
import hashlib,json,os,signal,subprocess,sys,time
from pathlib import Path

root=Path.cwd();ev=Path(__file__).resolve().parent
directory=Path('/home/yan/.cache/quod-m4-r2-artifacts/freeze-runs')
directory.mkdir(mode=0o700,parents=True,exist_ok=True)
label=sys.argv[1];boundary=Path(sys.argv[2]);log=directory/(label+'.log');receipt=directory/(label+'.json')
assert not log.exists() and not receipt.exists(),'Preserve prior freeze attempts'
command=['python3',str(ev/'freeze-handoff.py'),str(boundary)]
env=dict(os.environ);env.pop('LD_LIBRARY_PATH',None);env.pop('LD_PRELOAD',None)
env['PYTHONDONTWRITEBYTECODE']='1'
started=time.time();timeout=False
with log.open('xb') as output:
    child=subprocess.Popen(command,cwd=root,env=env,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
    try:status=child.wait(timeout=900)
    except subprocess.TimeoutExpired:
        timeout=True;os.killpg(child.pid,signal.SIGTERM)
        try:status=child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid,signal.SIGKILL);status=child.wait()
log.chmod(0o600)
data=log.read_text();summary=None
for line in data.splitlines():
    if line.startswith('{'):
        value=json.loads(line)
        if value.get('frozen'):summary=value
success=status==0 and not timeout and summary is not None
record={'command':command,'cwd':str(root),'start_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime(started)),
    'elapsed_seconds':time.time()-started,'true_child_exit':status,'timed_out':timeout,
    'explicit_completion':summary is not None,'passed':success,'log':str(log),
    'log_sha256':hashlib.sha256(log.read_bytes()).hexdigest(),
    'log_scope':'Freeze/verification counts, paths and errors only; no private stores/keys/raw native data are passed to this process',
    'receipt_location_reason':'Written after source capture, outside every checkout and immutable source boundary','summary':summary}
receipt.write_text(json.dumps(record,indent=2)+'\n');receipt.chmod(0o600)
print(json.dumps(record));sys.exit(0 if success else 1)
