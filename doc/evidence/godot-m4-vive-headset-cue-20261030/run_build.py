"""Retain both driver streams, real EOF and the true bounded build exit."""
import hashlib,json,os,re,shutil,signal,subprocess,sys,threading,time
sys.dont_write_bytecode=True
from pathlib import Path
sys.path.append(str(Path(__file__).resolve().parent.parent/'godot-m4-vive-physical-20261029'))
from environment import TASK,environment
from publication import redact_devices
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent
label='headset-cue-build01';private=TASK/'private/runs'/label
private.mkdir(mode=0o700,parents=True,exist_ok=False)
copies=private/'driver-inputs';copies.mkdir(mode=0o700)
inputs={}
for p in sorted(ev.glob('*.py')):
 shutil.copy2(p,copies/p.name);inputs[p.name]=hashlib.sha256(p.read_bytes()).hexdigest()
manifest=json.loads((root/'doc/evidence/godot-m4-presentation-20261030/inputs/client-presentation-final02-manifest.json').read_text())
command=[sys.executable,str(ev/'build.py'),'headset-cue01',manifest['template']['path']]
record={'command':command,'cwd':str(root),'bound_seconds':2100,'driver_inputs':inputs,
 'reader_errors':[],'offline_build_only':True,'native_runtime_started':False,
 'functional_application_started':False,'explicit_completion':False,'timed_out':False}
started=time.monotonic();child=subprocess.Popen(command,cwd=root,env=environment(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
def drain(kind):
 try:
  with (private/(kind+'.raw')).open('xb') as out:
   for line in getattr(child,kind):
    out.write(line);out.flush()
    if kind=='stdout':
     try:
      summary=json.loads(line)
      if summary.get('passed') is True and summary.get('inputs')==94 and summary.get('outputs')==196:
       record['explicit_completion']=True;record['completion']=summary
     except (ValueError,AttributeError):pass
    sys.stdout.buffer.write(redact_devices(line));sys.stdout.buffer.flush()
 except Exception as error:record['reader_errors'].append({'stream':kind,'error':type(error).__name__})
 finally:getattr(child,kind).close()
threads={kind:threading.Thread(target=drain,args=(kind,)) for kind in ['stdout','stderr']}
for thread in threads.values():thread.start()
try:record['true_child_exit']=child.wait(timeout=record['bound_seconds'])
except subprocess.TimeoutExpired:
 record['timed_out']=True;os.killpg(child.pid,signal.SIGTERM)
 try:record['true_child_exit']=child.wait(timeout=10)
 except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);record['true_child_exit']=child.wait()
record['eof']={}
for kind,thread in threads.items():thread.join(timeout=5);record['eof'][kind]=not thread.is_alive()
record['elapsed_seconds']=time.monotonic()-started;record['streams']={};(ev/'logs').mkdir(exist_ok=True)
for kind in threads:
 p=private/(kind+'.raw');p.chmod(0o600);data=p.read_bytes();q=ev/'logs'/(label+'-'+kind+'.log')
 q.write_bytes(redact_devices(data))
 record['streams'][kind]={'path':str(p),'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),
  'sanitized_sha256':hashlib.sha256(q.read_bytes()).hexdigest()}
record['passed']=record['true_child_exit']==0 and record['explicit_completion'] and not record['timed_out'] and not record['reader_errors'] and all(record['eof'].values())
(ev/'logs'/(label+'.json')).write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record),flush=True)
raise SystemExit(0 if record['passed'] else 1)
