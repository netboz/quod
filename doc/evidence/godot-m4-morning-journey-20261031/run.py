#!/usr/bin/env python3
"""All raw streams are private on /data; small sanitized receipts stay in worktree."""
import argparse,hashlib,json,os,re,shutil,signal,subprocess,sys,time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent.parent/'godot-m4-vive-physical-20261029'))
from environment import TASK,environment
from publication import redact_devices
p=argparse.ArgumentParser();p.add_argument('--timeout',type=int,default=300);p.add_argument('--cwd',default=str(Path.cwd()));p.add_argument('label');p.add_argument('command',nargs=argparse.REMAINDER);a=p.parse_args()
os.umask(0o077);ev=Path(__file__).resolve().parent
private=TASK/'private/runs'/a.label;private.mkdir(mode=0o700,parents=True,exist_ok=False)
public=ev/'logs'/a.label;public.parent.mkdir(exist_ok=True)
assert not public.with_suffix('.json').exists()
command=a.command[1:] if a.command[:1]==['--'] else a.command
supplied=private/'driver-inputs';supplied.mkdir(mode=0o700)
input_hashes={}
for source in sorted(ev.iterdir()):
    if source.is_file() and source.suffix in ['.py','.cs','.c','.gd','.tscn','.patch']:
        shutil.copy2(source,supplied/source.name)
        input_hashes[source.name]=hashlib.sha256(source.read_bytes()).hexdigest()
started=time.time();timed_out=False
with (private/'stdout.raw').open('xb') as out,(private/'stderr.raw').open('xb') as err:
    child=subprocess.Popen(command,cwd=a.cwd,env=environment(),stdout=out,stderr=err,start_new_session=True)
    try:status=child.wait(timeout=a.timeout)
    except subprocess.TimeoutExpired:
        timed_out=True;os.killpg(child.pid,signal.SIGTERM)
        try:status=child.wait(timeout=10)
        except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);status=child.wait()
record={'command':command,'cwd':a.cwd,'child_exit':status,'timed_out':timed_out,'driver_inputs':input_hashes,
    'start_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime(started)),'elapsed_seconds':time.time()-started,
    'private_streams':{},'sanitized_streams':{}}
for stream in ['stdout','stderr']:
    raw=private/(stream+'.raw');raw.chmod(0o600);data=raw.read_bytes()
    sanitized=redact_devices(data)
    sanitized=re.sub(rb'(https://release-assets\.githubusercontent\.com/[^"\s?]+)\?[^"\s]+',rb'\1?<signed-redirect-query-redacted>',sanitized)
    target=public.parent/(public.name+'-'+stream+'.log');target.write_bytes(sanitized)
    record['private_streams'][stream]={'path':str(raw),'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)}
    record['sanitized_streams'][stream]={'path':str(target),'sha256':hashlib.sha256(sanitized).hexdigest(),'bytes':len(sanitized)}
public.with_suffix('.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record))
sys.exit(status if status>=0 else 128-status)
