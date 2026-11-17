#!/usr/bin/env python3
"""Own the actual export's input/render observation through close and output EOF."""
import argparse,ctypes,hashlib,json,os,queue,shutil,subprocess,sys,threading,time
from pathlib import Path
sys.dont_write_bytecode=True
p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('--engine',required=True);p.add_argument('--desktop',action='store_true');p.add_argument('--phase',choices=['controller-input','scene'],default='controller-input');a=p.parse_args()
root=Path.cwd();evidence=Path(__file__).resolve().parent;out=evidence/a.label;out.mkdir(exist_ok=False)
drivers=out/'drivers';drivers.mkdir()
for path in [Path(__file__).resolve(),root/'client/godot-tests/desktop_input.py']:shutil.copy2(path,drivers/path.name)
sys.path.insert(0,str(drivers));from desktop_input import deliver
private=Path('/home/yan/.cache/quod-m4-r2-artifacts/private')/a.label;private.mkdir(parents=True,mode=0o700,exist_ok=False)
command=[a.engine]+(['--display-driver','wayland'] if a.desktop else ['--headless'])+['--','--qualification','--profile',str(private/'identity')]
env=dict(os.environ,M1B_PHASE=a.phase,M1B_RESULT=str(out/'client-result.json'),M4_MODEL=str(root/'priv/explorer/assets/models/bd201855c8114b9b0e9cdd465d6f08413d18604894c839fb78d54d890c2adc94.glb'),M4_MAPPING=str(root/'doc/evidence/godot-m4-20261029/inputs/injected-mapping.term'),XDG_DATA_HOME=str(private/'data'),XDG_CONFIG_HOME=str(private/'config'))
if a.phase=='scene':env['M2_SCENE_CAPTURE']=str(out/'wireframe.png')
record=dict(command=command,desktop=a.desktop,physical_acceptance=False,driver_hashes={x.name:hashlib.sha256(x.read_bytes()).hexdigest() for x in drivers.iterdir()},native_input=[],watchdog_seconds=60,passed=False)
def allow_owned_trace():
    if ctypes.CDLL(None).prctl(0x59616d61,os.getppid(),0,0,0)!=0:os._exit(125)
child=subprocess.Popen(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,preexec_fn=allow_owned_trace)
lines=queue.Queue();reader_errors=[]
def receive():
    try:
        for line in child.stdout:lines.put(line)
    except Exception as error:reader_errors.append(type(error).__name__)
    finally:lines.put(None)
reader=threading.Thread(target=receive);reader.start();timer=None
def capture():
    if child.poll() is not None:return
    diagnostic=private/'native-stacks.log'
    command=['gdb','-q','-nx','-batch','-p',str(child.pid),'-ex','set auto-load off','-ex','set print frame-arguments none','-ex','set print entry-values no','-ex','thread apply all bt 20','-ex','detach']
    detail={'command':command,'owned_pid':child.pid,'capture_timeout_seconds':15,'memory_dump':False,'arguments':False}
    try:
        with diagnostic.open('x') as trace:
            diagnostic.chmod(0o600);detail['child_exit']=subprocess.run(command,stdout=trace,stderr=subprocess.STDOUT,timeout=15).returncode
    except Exception as error:detail['error']=type(error).__name__
    record['diagnostic']=detail
text=''
try:
    with (out/'client.log').open('x') as log:
        while True:
            line=lines.get(timeout=60)
            if line is None:break
            log.write(line);log.flush();text+=line
            deliver(line,child.pid,a.desktop,record['native_input'])
            if line.startswith(('M4_CONTROLLER_PASS','M2_SCENE_PASS')):
                timer=threading.Timer(20,capture);timer.start()
    record['client_exit']=child.wait(timeout=10)
except Exception as error:record['failure']=type(error).__name__+': '+str(error)
finally:
    if timer is not None:timer.cancel();timer.join(timeout=16)
    if child.poll() is None:child.kill()
    record['client_exit']=child.wait(timeout=10);reader.join(timeout=5)
    record['output_eof']=not reader.is_alive();record['reader_errors']=reader_errors
    marker='M4_CONTROLLER_PASS' if a.phase=='controller-input' else 'M2_SCENE_PASS'
    record['completion_marker']=marker in text
    record['passed']=record['client_exit']==0 and record['output_eof'] and not reader_errors and record['completion_marker'] and (out/'client-result.json').exists() and 'ERROR:' not in text
    (out/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record))
sys.exit(0 if record['passed'] else 1)
