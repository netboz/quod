"""Bound the existing human-assisted read-only HDMI offer observation."""
import datetime,hashlib,json,os,select,shutil,subprocess,sys,threading,time
from pathlib import Path
sys.dont_write_bytecode=True
os.umask(0o077)
ev=Path(__file__).resolve().parent
sys.path.insert(0,str(ev.parent/'godot-m4-vr-20261029'))
from environment import TASK
from vive_display import ViveDisplay
label=sys.argv[1];private=TASK/'private'/label;private.mkdir(mode=0o700,exist_ok=False)
public=ev/label;public.mkdir(exist_ok=False)
binary=TASK/'builds/display-inventory02/display-inventory'
copies=private/'driver-inputs';copies.mkdir(mode=0o700)
record={'manual_display_preflight':True,'runtime_or_app_started':False,'lease_requested':False,
 'participant_bound_seconds':1800,'ready_bound_seconds':10,'post_response_bound_seconds':10,
 'cleanup_bound_seconds':5,'reader_errors':[],'eof':{},'passed':False,'inputs':{}}
for p in [Path(__file__).resolve(),binary,ev.parent/'godot-m4-vr-20261029/observe_display.py',
 ev.parent/'godot-m4-vr-20261029/display_inventory.c',ev.parent/'godot-m4-vr-20261029/vive_display.py']:
    shutil.copy2(p,copies/p.name)
    record['inputs'][str(p)]={'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),
      'mode':oct(p.stat().st_mode&0o7777),'bytes':p.stat().st_size}
display=ViveDisplay(private);child=None;threads=[];ready=threading.Event();offered=threading.Event();waiting=threading.Event()
started=time.monotonic();record['started_utc']=datetime.datetime.now(datetime.timezone.utc).isoformat()
def drain(kind):
    try:
        with (private/(kind+'.raw')).open('xb') as out:
            for line in getattr(child,kind):
                out.write(line);out.flush()
                if kind=='stdout':
                    if line.startswith(b'WAIT_CONNECTOR'):waiting.set();ready.set()
                    if line.startswith(b'LEASE_NOTIFICATION') or (line.startswith(b'LEASE_SNAPSHOT') and b'connectors=0 ' not in line):
                        offered.set();ready.set();print('VIVE_LEASE_OFFER_OBSERVED',flush=True)
    except Exception as error:record['reader_errors'].append({'stream':kind,'error':type(error).__name__})
    finally:
        record['eof'][kind]=True
        if kind=='stdout':ready.set()
try:
    owner=subprocess.run(['ps','-eo','pid=,comm='],capture_output=True,timeout=5)
    assert owner.returncode==0
    record['runtime_processes_before']=[line for line in owner.stdout.decode().splitlines()
      if any(x in line.lower() for x in ['monado','godot','quod.x86','steamvr','vrserver','vrcompositor'])]
    assert not record['runtime_processes_before'], 'Another runtime/application owns the environment'
    record['command']=[str(binary),'--await-connector']
    child=subprocess.Popen(record['command'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    record['observer_pid']=child.pid
    for kind in ['stdout','stderr']:
        t=threading.Thread(target=drain,args=(kind,));threads.append((kind,t));t.start()
    if not ready.wait(timeout=10):raise TimeoutError('Observer readiness10s expired')
    if offered.is_set():record['offer_already_present']=True
    else:
        if not waiting.is_set() or child.poll() is not None:raise RuntimeError('Observer exited without WAIT_CONNECTOR')
        display.enable();record['armed_monotonic']=time.monotonic()
        record['participant_deadline_monotonic']=record['armed_monotonic']+1800
        (private/'armed.json').write_text(json.dumps(record,indent=2)+'\n')
        print('VIVE_RECONNECT_OBSERVER_READY '+json.dumps({'observer_pid':child.pid,'participant_remaining_seconds':1800}),flush=True)
        if not select.select([sys.stdin],[],[],1800)[0]:raise TimeoutError('Participant1800s expired')
        response=sys.stdin.readline().strip();record['participant_response']=response
        if response=='finish':record['lease_offer']=offered.wait(timeout=10)
        elif response=='cancel':record['lease_offer']=offered.is_set()
        else:raise RuntimeError('Unsupported participant completion')
    record['lease_offer']=offered.is_set()
    if record['lease_offer']:
        record['observer_exit']=child.wait(timeout=5)
        record['passed']=record['observer_exit']==0 and (record.get('offer_already_present') or record.get('participant_response')=='finish')
except Exception as error:record['error']=type(error).__name__+': '+str(error)
finally:
    if child is not None:
        if child.poll() is None:
            record['cleanup_signal']='SIGTERM';child.terminate()
            try:child.wait(timeout=5)
            except subprocess.TimeoutExpired:record['cleanup_signal']='SIGKILL after5s';child.kill()
        record['observer_exit']=child.wait(timeout=5)
    for kind,t in threads:
        t.join(timeout=5);record['eof'][kind]=not t.is_alive()
    display.restore();record['display_rule']=display.record
    record['streams']={}
    for kind in ['stdout','stderr']:
        p=private/(kind+'.raw')
        if p.exists():
            p.chmod(0o600);data=p.read_bytes();(public/(kind+'.log')).write_bytes(data)
            record['streams'][kind]={'path':str(p),'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)}
    record['elapsed_seconds']=time.monotonic()-started
    record['passed']=record['passed'] and not record['reader_errors'] and all(record['eof'].values())
    (private/'result.json').write_text(json.dumps(record,indent=2)+'\n')
    (public/'result.json').write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps(record),flush=True)
raise SystemExit(0 if record['passed'] else 1)
