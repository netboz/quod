"""Retain full driver stdout/stderr and true exit while allowing owned stdin."""
import argparse,hashlib,json,os,shutil,signal,subprocess,sys,threading,time
from pathlib import Path
from environment import TASK,environment
from publication import redact_devices
p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('command',nargs=argparse.REMAINDER);a=p.parse_args()
os.umask(0o077);ev=Path(__file__).resolve().parent;private=TASK/'private/runs'/a.label;private.mkdir(mode=0o700,parents=True,exist_ok=False)
copies=private/'driver-inputs';copies.mkdir(mode=0o700);inputs={}
for source in ev.iterdir():
    if source.is_file() and source.suffix in ['.py','.cs','.erl']:
        shutil.copy2(source,copies/source.name);inputs[source.name]=hashlib.sha256(source.read_bytes()).hexdigest()
command=a.command[1:] if a.command[:1]==['--'] else a.command
started=time.time();record={'command':command,'cwd':str(Path.cwd()),'driver_inputs':inputs,'bound_seconds':2100,'reader_errors':[]};threads=[]
child=subprocess.Popen(command,env=environment(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
def drain(kind):
    try:
        with (private/(kind+'.raw')).open('xb') as out:
            for line in getattr(child,kind):
                out.write(line);out.flush();sys.stdout.buffer.write(redact_devices(line));sys.stdout.buffer.flush()
    except Exception as error:record['reader_errors'].append({'stream':kind,'error':type(error).__name__})
for kind in ['stdout','stderr']:
    t=threading.Thread(target=drain,args=(kind,));threads.append((kind,t));t.start()
try:record['child_exit']=child.wait(timeout=2100)
except subprocess.TimeoutExpired:
    record['timed_out']=True;os.killpg(child.pid,signal.SIGTERM)
    try:record['child_exit']=child.wait(timeout=10)
    except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);record['child_exit']=child.wait()
record['eof']={}
for kind,t in threads:t.join(timeout=5);record['eof'][kind]=not t.is_alive()
record['elapsed_seconds']=time.time()-started;record['streams']={};(ev/'logs').mkdir(exist_ok=True)
for kind in ['stdout','stderr']:
    raw=private/(kind+'.raw');raw.chmod(0o600);data=raw.read_bytes();target=ev/'logs'/(a.label+'-'+kind+'.log');target.write_bytes(redact_devices(data))
    record['streams'][kind]={'path':str(raw),'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),'sanitized_sha256':hashlib.sha256(target.read_bytes()).hexdigest()}
(ev/'logs'/(a.label+'.json')).write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record),flush=True)
raise SystemExit(0 if record['child_exit']==0 and not record.get('timed_out') and not record['reader_errors'] and all(record['eof'].values()) else 1)
