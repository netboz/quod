#!/usr/bin/env python3
"""Own one isolated installed Monado simulator and the clean Godot consumer."""
import argparse,hashlib,json,os,selectors,subprocess,threading,time
from pathlib import Path

p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('--engine',required=True);p.add_argument('--project',required=True);p.add_argument('--export',action='store_true');a=p.parse_args()
root=Path.cwd();evidence=Path(__file__).resolve().parent;out=evidence/a.label;out.mkdir(exist_ok=False)
private=Path('/tmp/quod-m4-ca84d4f8/private')/a.label;private.mkdir(parents=True,mode=0o700,exist_ok=False)
for folder in ['runtime','config','data']:(private/folder).mkdir(mode=0o700)
env=dict(os.environ,XDG_RUNTIME_DIR=str(private/'runtime'),XDG_CONFIG_HOME=str(private/'config'),XDG_DATA_HOME=str(private/'data'),XR_RUNTIME_JSON='/usr/share/openxr/1/openxr_monado.json',
         SIMULATED_ENABLE='1',SIMULATED_LEFT='simple',SIMULATED_RIGHT='simple',SDL_VIDEODRIVER='x11',XRT_COMPOSITOR_FORCE_XCB='1',XRT_COMPOSITOR_SCALE_PERCENTAGE='50',XRT_NO_STDIN='1')
env.pop('LD_LIBRARY_PATH',None);env.pop('LD_PRELOAD',None)
display=env.get('WAYLAND_DISPLAY')
if display:
 source=Path(display) if Path(display).is_absolute() else Path(os.environ['XDG_RUNTIME_DIR'])/display
 (private/'runtime/wayland-display').symlink_to(source);env['WAYLAND_DISPLAY']='wayland-display'
env.update(M1B_PHASE='openxr',M1B_RESULT=str(out/'client-result.json'))
command=[a.engine,'--display-driver','wayland','--audio-driver','Dummy','--xr-mode','on','--rendering-method','mobile','--rendering-driver','vulkan']
if not a.export:command+=['--path',a.project]
command+=['--','--qualification','--profile',str(private/'identity')]
result=dict(simulated=True,physical_acceptance=False,command=command,service_command=['/usr/bin/monado-service'],completed=False,helper_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
(out/'invocation.json').write_text(json.dumps(result,indent=2)+'\n')
start=time.monotonic();service=None;drain=None;client=None
try:
 with (private/'runtime-raw.log').open('xb') as log:
  service=subprocess.Popen(result['service_command'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
  selector=selectors.DefaultSelector();selector.register(service.stdout,selectors.EVENT_READ);received=b'';deadline=time.monotonic()+30
  while b'The Monado service has started.' not in received:
   remaining=deadline-time.monotonic()
   if remaining<=0 or not selector.select(remaining):raise TimeoutError('Owned simulator startup deadline')
   block=os.read(service.stdout.fileno(),65536)
   if not block:raise RuntimeError('Owned simulator ended before readiness')
   received+=block;log.write(block);log.flush()
  selector.close()
  def drain_runtime():
   for line in service.stdout:log.write(line);log.flush()
  drain=threading.Thread(target=drain_runtime);drain.start()
  with (out/'client.log').open('xb') as output:
   client=subprocess.Popen(command,env=env,stdout=output,stderr=subprocess.STDOUT)
   try:result['client_exit']=client.wait(timeout=90)
   except subprocess.TimeoutExpired:
    result['client_timeout']=True;client.terminate();result['client_exit']=client.wait(timeout=10)
  result['client_diagnostics']=[line for line in (out/'client.log').read_text(errors='replace').splitlines() if 'ERROR' in line or 'leaked' in line or "isn't part of an action set" in line]
  result['completed']=(out/'client-result.json').exists()
except Exception as error:result['error']=str(error)
finally:
 if client and client.poll() is None:client.terminate();result['client_exit']=client.wait(timeout=10)
 if service:
  if service.poll() is None:service.terminate()
  result['service_exit']=service.wait(timeout=15)
 if drain:drain.join(timeout=5)
 raw=private/'runtime-raw.log'
 if raw.exists():
  result['runtime_log_sha256']=hashlib.sha256(raw.read_bytes()).hexdigest();(out/'runtime.log').write_bytes(raw.read_bytes())
 result['elapsed_seconds']=time.monotonic()-start
 result['passed']=result['completed'] and result.get('client_exit')==0 and result.get('service_exit')==0 and not result.get('client_diagnostics') and not result.get('error')
 (out/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result),flush=True)
raise SystemExit(0 if result['passed'] else 1)
