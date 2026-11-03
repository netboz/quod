#!/usr/bin/env python3
"""Own a normal application for human observation, then bound normal close.

This is a separate manual observation, not a rerun or relaxation of the timed
automated cases. Human preparation has no fabricated qualification deadline.
The original desktop close watchdog starts when the participant finishes.
"""
import argparse,ctypes,hashlib,json,os,re,selectors,shutil,subprocess,sys,threading,time
from pathlib import Path
from private_vive import prepare,unchanged,active_runtime_processes

p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('--export',type=Path,required=True);a=p.parse_args()
root=Path.cwd();evidence=Path(__file__).resolve().parent;out=evidence/a.label;out.mkdir(exist_ok=False)
private=Path('/home/yan/.cache/quod-m4-r2-artifacts/private')/a.label;private.mkdir(mode=0o700)
for n in ['runtime','config','data']:(private/n).mkdir(mode=0o700)
for name in ['interactive-vive.py','interactive-observer.gd','private_vive.py']:shutil.copy2(evidence/name,out/name)
if active_runtime_processes():raise RuntimeError('An existing runtime is active; do not interfere')
prefix,extra,before=prepare(private)
runtime=Path('/home/yan/.cache/quod-m4-r2-artifacts/runtime/monado-compatible02-install')
env=dict(os.environ,**extra,XDG_RUNTIME_DIR=str(private/'runtime'),XDG_CONFIG_HOME=str(private/'config'),XDG_DATA_HOME=str(private/'data'),
 XR_RUNTIME_JSON=str(runtime/'share/openxr/1/openxr_monado.json'),SIMULATED_ENABLE='0',XRT_COMPOSITOR_FORCE_XCB='1',XRT_COMPOSITOR_SCALE_PERCENTAGE='50',SDL_VIDEODRIVER='x11',
 XR_ENABLE_API_LAYERS='XR_APILAYER_LUNARG_api_dump',XR_API_DUMP_EXPORT_TYPE='text',XR_API_DUMP_FILE_NAME=str(private/'api-dump-raw.txt'),M4_INTERACTIVE_RESULT=str(out/'observation.json'))
env.pop('LD_LIBRARY_PATH',None);env.pop('LD_PRELOAD',None)
display=os.environ.get('WAYLAND_DISPLAY')
if display:env['WAYLAND_DISPLAY']=display if Path(display).is_absolute() else str(Path(os.environ['XDG_RUNTIME_DIR'])/display)
service_command=prefix+[str(runtime/'bin/monado-service')]
client_command=[str(a.export),'--display-driver','wayland','--audio-driver','Dummy','--xr-mode','on','--rendering-method','mobile','--rendering-driver','vulkan','--script',str(out/'interactive-observer.gd'),'--','--profile',str(private/'identity')]
record={'observation_only':True,'automated_qualification_pass':False,'physical_headset_pixels':False,'participant_placement':'wands on table',
 'client_command':client_command,'service_command':service_command,'shutdown_watchdog_seconds':60,'driver_inputs':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir()},'start_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}
(out/'invocation.json').write_text(json.dumps(record,indent=2)+'\n')
service=client=None;runtime_reader=client_reader=timer=None;start=time.monotonic();ready=threading.Event();errors=[]
prctl=ctypes.CDLL(None).prctl;owner=os.getpid()
def allow_trace():
 if prctl(0x59616d61,owner,0,0,0)!=0:os._exit(125)
def capture():
 if client.poll() is not None:return
 d=private/'diagnostics';d.mkdir(mode=0o700)
 command=['gdb','-q','-nx','-batch','-p',str(client.pid),'-ex','set print frame-arguments none','-ex','set print entry-values no','-ex','thread apply all bt 20','-ex','detach']
 with (d/'native-stacks.log').open('x') as log:
  try:record['native_capture_exit']=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=15).returncode
  except Exception as error:record['native_capture_error']=type(error).__name__
try:
 with (private/'runtime-raw.log').open('xb') as runtime_log,(private/'client-raw.log').open('xb') as client_log:
  service=subprocess.Popen(service_command,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
  def receive_runtime():
   try:
    for line in service.stdout:
     runtime_log.write(line);runtime_log.flush()
     if b'The Monado service has started.' in line:ready.set()
   except Exception as error:errors.append('runtime reader: '+type(error).__name__)
  runtime_reader=threading.Thread(target=receive_runtime);runtime_reader.start()
  if not ready.wait(timeout=30):raise RuntimeError('Private runtime startup deadline')
  client=subprocess.Popen(client_command,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,preexec_fn=allow_trace)
  def receive_client():
   try:
    for line in client.stdout:
     client_log.write(line);client_log.flush()
     if line.startswith(b'M4_INTERACTIVE_'):print(line.decode(errors='replace').rstrip(),flush=True)
   except Exception as error:errors.append('client reader: '+type(error).__name__)
  client_reader=threading.Thread(target=receive_client);client_reader.start()
  print('M4_INTERACTIVE_OWNED_PID '+str(client.pid),flush=True)
  control=sys.stdin.readline().strip();record['participant_finish_received']=control=='finish'
  if control!='finish':raise RuntimeError('Interactive owner input ended without participant finish')
  windows=json.loads(subprocess.check_output(['hyprctl','-j','clients'],timeout=5))
  owned=[w for w in windows if w.get('pid')==client.pid and w.get('title')=='Quod — Vive observation' and w.get('mapped')]
  if len(owned)!=1:raise RuntimeError('Expected one exact owned observation window')
  command=['hyprctl','dispatch','hl.dsp.window.close({window="address:'+owned[0]['address']+'"})']
  record['close_command']=command;record['close_delivery_exit']=subprocess.run(command,capture_output=True,timeout=5).returncode
  timer=threading.Timer(20,capture);timer.start()
  try:record['client_exit']=client.wait(timeout=60);record['shutdown_timeout']=False
  except subprocess.TimeoutExpired:record['shutdown_timeout']=True;client.kill();record['client_exit']=client.wait(timeout=10)
  timer.cancel();timer.join(timeout=16);client_reader.join(timeout=5)
  record['client_output_eof']=not client_reader.is_alive()
  if service.poll() is None:service.stdin.write(b'\n');service.stdin.flush();service.stdin.close()
  record['service_exit']=service.wait(timeout=15);runtime_reader.join(timeout=5);record['runtime_output_eof']=not runtime_reader.is_alive()
except Exception as error:record['failure']=type(error).__name__+': '+str(error)
finally:
 if timer:timer.cancel();timer.join(timeout=16)
 if client is not None and client.poll() is None:client.kill();record['client_exit']=client.wait(timeout=10)
 if service is not None and service.poll() is None:service.terminate();record['service_exit']=service.wait(timeout=15)
 for reader in [client_reader,runtime_reader]:
  if reader:reader.join(timeout=5)
 for name in ['client','runtime']:
  p=private/(name+'-raw.log')
  if p.exists():p.chmod(0o600);(out/(name+'.log')).write_bytes(re.sub(rb'(?i)LHR-[A-Za-z0-9]+',b'<device-serial-redacted>',p.read_bytes()))
 record['original_calibration_unchanged']=unchanged(before);record['reader_errors']=errors;record['elapsed_seconds']=time.monotonic()-start
 record['observation_recorded']=(out/'observation.json').exists()
 (out/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record),flush=True)
raise SystemExit(0 if record.get('client_exit')==0 and record.get('service_exit')==0 and record['observation_recorded'] and not record.get('failure') and not errors else 1)
