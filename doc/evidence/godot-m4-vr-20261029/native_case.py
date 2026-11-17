"""Owned native qualification against a fresh source-only application export."""
import argparse,ctypes,hashlib,importlib.util,json,os,re,shutil,subprocess,sys,threading,time
from pathlib import Path
from environment import TASK,environment
from vive_display import ViveDisplay
p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('--client',type=Path,required=True);p.add_argument('--engine',type=Path);p.add_argument('--hardware',action='store_true');p.add_argument('--vive-rule',action='store_true');p.add_argument('--observe',action='store_true');a=p.parse_args()
root=Path.cwd();ev=Path(__file__).resolve().parent;out=ev/a.label;out.mkdir(exist_ok=False)
private=TASK/'private'/a.label;private.mkdir(mode=0o700,exist_ok=False)
for name in ['runtime','config','data','cache']:(private/name).mkdir(mode=0o700)
if not a.hardware:(private/'temporary').mkdir(mode=0o700)
runtime=Path('/home/yan/.cache/quod-m4-r2-artifacts/runtime/monado-compatible02-install')
helper=root/'doc/evidence/godot-m4-r2-20261029/private_vive.py'
spec=importlib.util.spec_from_file_location('qualified_private_vive',helper);vive=importlib.util.module_from_spec(spec);spec.loader.exec_module(vive)
assert not vive.active_runtime_processes(),'An unrelated runtime is active; do not interfere'
shutil.copy2(helper,private/'private_vive.py')
env=environment();env.update(XDG_RUNTIME_DIR=str(private/'runtime'),XDG_CONFIG_HOME=str(private/'config'),XDG_DATA_HOME=str(private/'data'),XDG_CACHE_HOME=str(private/'cache'),TMPDIR=str(private/'temporary'),TMP=str(private/'temporary'),TEMP=str(private/'temporary'),XR_RUNTIME_JSON=str(runtime/'share/openxr/1/openxr_monado.json'),M1B_PHASE='openxr',M1B_RESULT=str(out/'client-result.json'),XR_ENABLE_API_LAYERS='XR_APILAYER_LUNARG_api_dump',XR_API_DUMP_EXPORT_TYPE='text',XR_API_DUMP_FILE_NAME=str(private/'api-dump.raw'))
if os.environ.get('WAYLAND_DISPLAY'):env['WAYLAND_DISPLAY']=str(Path(os.environ['XDG_RUNTIME_DIR'])/os.environ['WAYLAND_DISPLAY'])
service_command=[str(runtime/'bin/monado-service')];before=None;display=None
if a.hardware:
    prefix,extra,before=vive.prepare(private);env.update(extra);service_command=prefix+service_command
    env.update(SIMULATED_ENABLE='0',XRT_COMPOSITOR_FORCE_WAYLAND_DIRECT='1')
else:env.update(SIMULATED_ENABLE='1',SIMULATED_LEFT='simple',SIMULATED_RIGHT='simple',XRT_COMPOSITOR_FORCE_XCB='1',XRT_COMPOSITOR_SCALE_PERCENTAGE='50',SDL_VIDEODRIVER='x11')
if a.engine:
    launch=private/'export';shutil.copytree(a.client.parent,launch,copy_function=os.link,symlinks=True)
    executable=launch/a.client.name;executable.unlink();shutil.copy2(a.engine,executable)
else:executable=a.client
command=[str(executable),'--display-driver','wayland','--audio-driver','Dummy','--xr-mode','on','--rendering-method','mobile','--rendering-driver','vulkan']
if a.observe:
    observer=ev/'display-observer.gd';shutil.copy2(observer,private/observer.name)
    env['M4_INTERACTIVE_RESULT']=str(out/'observation.json')
command+=['--',*([] if a.observe else ['--qualification']),'--profile',str(private/'identity')]
record={'client_command':command,'service_command':service_command,'hardware':a.hardware,'headset_pixels':False,'watchdog_seconds':90,'engine_sha256':hashlib.sha256(executable.read_bytes()).hexdigest(),'application_payload':{str(p.relative_to(a.client.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(a.client.parent.rglob('*')) if p.is_file()},'runtime_manifest_sha256':hashlib.sha256((runtime/'share/openxr/1/openxr_monado.json').read_bytes()).hexdigest(),'passed':False,'reader_errors':[]}
(out/'invocation.json').write_text(json.dumps(record,indent=2)+'\n')
record['manual_observation']=a.observe
service=client=None;readers=[];streams=[];ready=threading.Event();app_ready=threading.Event();service_ready=False;timer=None
owner=os.getpid();prctl=ctypes.CDLL(None).prctl
def trace_permission():
    if prctl(0x59616d61,owner,0,0,0)!=0:os._exit(125)
def receive(process,name):
    def drain(pipe,stream):
        global service_ready
        try:
            for line in pipe:
                stream.write(line);stream.flush()
                if name=='runtime' and b'The Monado service has started.' in line:service_ready=True;ready.set()
                if name=='client' and line.startswith(b'M4_INTERACTIVE_XR_READY'):app_ready.set()
                if name=='client' and line.startswith((b'M4_XR_',b'PASS ')):print(line.decode(errors='replace').rstrip(),flush=True)
        except Exception as error:record['reader_errors'].append(name+':'+type(error).__name__)
        finally:
            if name=='runtime':ready.set()
    for kind in ['stdout','stderr']:
        stream=(private/(name+'-'+kind+'.raw')).open('xb');streams.append(stream)
        thread=threading.Thread(target=drain,args=(getattr(process,kind),stream));readers.append((name,kind,thread));thread.start()
def capture():
    if client is None or client.poll() is not None:return
    directory=private/'stacks';directory.mkdir(mode=0o700)
    cmd=['gdb','-q','-nx','-batch','-iex','set auto-load off','-iex','set print frame-arguments none','-iex','set print entry-values no','-p',str(client.pid),'-ex','thread apply all bt 20','-ex','detach']
    with (directory/'native.raw').open('xb') as output:
        try:record['bounded_stack_capture_exit']=subprocess.run(cmd,stdout=output,stderr=subprocess.STDOUT,timeout=15).returncode
        except Exception as error:record['bounded_stack_capture_error']=type(error).__name__
try:
    if a.vive_rule:
        assert a.hardware;display=ViveDisplay(private);display.enable()
    service=subprocess.Popen(service_command,cwd=private,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE);receive(service,'runtime')
    if not ready.wait(timeout=30) or not service_ready:raise RuntimeError('Owned runtime did not reach startup readiness')
    client=subprocess.Popen(command,cwd=root,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,preexec_fn=trace_permission);receive(client,'client')
    timeout=90
    if a.observe:
        if not app_ready.wait(timeout=30):raise RuntimeError('Owned application observation readiness deadline')
        windows=json.loads(subprocess.check_output(['hyprctl','-j','clients'],timeout=5));owned=[w for w in windows if w.get('pid')==client.pid and w.get('mapped')]
        if len(owned)!=1 or not re.fullmatch(r'0x[0-9a-fA-F]+',owned[0]['address']):raise RuntimeError('Exact owned mapped window guard failed')
        address=owned[0]['address'];record['owned_window_address']=address;print('VIVE_DISPLAY_APPLICATION_READY',flush=True)
        record['participant_finish_received']=sys.stdin.readline().strip()=='finish'
        if not record['participant_finish_received']:raise RuntimeError('Human observation ended without finish')
        windows=json.loads(subprocess.check_output(['hyprctl','-j','clients'],timeout=5));assert len([w for w in windows if w.get('pid')==client.pid and w.get('mapped') and w['address']==address])==1,'Owned window changed before close'
        close=['hyprctl','dispatch','hl.dsp.window.close({window="address:'+address+'"})'];record['close_command']=close
        record['close_delivery_exit']=subprocess.run(close,capture_output=True,timeout=5).returncode;timeout=60
    timer=threading.Timer(20 if a.observe else 70,capture);timer.start()
    try:record['client_exit']=client.wait(timeout=timeout)
    except subprocess.TimeoutExpired:record['client_timeout']=True;client.kill();record['client_exit']=client.wait(timeout=10)
except Exception as error:record['error']=type(error).__name__+': '+str(error)
finally:
    if client is not None and client.poll() is None:client.kill();record['client_exit']=client.wait(timeout=10)
    if timer:timer.cancel();timer.join(timeout=16)
    if service is not None:
        if service.poll() is None:
            try:service.stdin.write(b'\n');service.stdin.flush();service.stdin.close();service.wait(timeout=15)
            except Exception as error:record['service_stop_error']=type(error).__name__;service.terminate()
        try:record['runtime_exit']=service.wait(timeout=15)
        except subprocess.TimeoutExpired:service.kill();record['runtime_exit']=service.wait(timeout=10)
    record['eof']={}
    for name,kind,thread in readers:thread.join(timeout=5);record['eof'][name+'-'+kind]=not thread.is_alive()
    for stream in streams:stream.close()
    if display:display.restore();record['display_rule']=display.record
    if before is not None:record['original_calibration_unchanged']=vive.unchanged(before)
    for name in ['runtime','client']:
        for kind in ['stdout','stderr']:
            path=private/(name+'-'+kind+'.raw')
            if path.exists():path.chmod(0o600);(out/(name+'-'+kind+'.log')).write_bytes(re.sub(rb'(?i)LHR-[A-Za-z0-9]+',b'<device-serial-redacted>',path.read_bytes()))
    client_text=''.join((private/('client-'+kind+'.raw')).read_text(errors='replace') for kind in ['stdout','stderr'] if (private/('client-'+kind+'.raw')).exists())
    record['completion_marker']=('M4_INTERACTIVE_OBSERVATION_RECORDED' if a.observe else 'M4_XR_PASS') in client_text
    record['diagnostics']=[line for line in client_text.splitlines() if 'ERROR' in line or 'leaked' in line]
    record['result_present']=(out/('observation.json' if a.observe else 'client-result.json')).is_file()
    record['runtime_processes_after']=vive.active_runtime_processes()
    dump=private/'api-dump.raw'
    if dump.exists():dump.chmod(0o600);record['api_dump']={'path':str(dump),'sha256':hashlib.sha256(dump.read_bytes()).hexdigest(),'bytes':dump.stat().st_size,'scope':'call entries/arguments only; returned codes and pixels not established'}
    record['passed']=record['completion_marker'] and record['result_present'] and record.get('client_exit')==0 and record.get('runtime_exit')==0 and all(record['eof'].values()) and not record.get('client_timeout') and not record.get('error') and not record['diagnostics'] and not record['reader_errors'] and not record['runtime_processes_after']
    (out/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps({k:v for k,v in record.items() if k!='application_payload'}),flush=True)
raise SystemExit(0 if record['passed'] else 1)
