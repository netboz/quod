#!/usr/bin/env python3
"""Run an owned private Monado service and the exact clean exported XR consumer."""
import argparse,ctypes,hashlib,json,os,re,selectors,shutil,subprocess,sys,threading,time
from pathlib import Path

p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('--export',type=Path,required=True)
p.add_argument('--project',type=Path);p.add_argument('--script');p.add_argument('--completion-marker',default='M4_XR_PASS')
p.add_argument('--runtime-prefix',type=Path);p.add_argument('--lighthouse',action='store_true')
p.add_argument('--compositor',choices=['default','wayland-lease','window'],default='default')
p.add_argument('--api-dump',action='store_true')
p.add_argument('--phase',choices=['openxr','openxr-input'],default='openxr')
p.add_argument('--fault-output',action='store_true')
p.add_argument('--mode',choices=['simulated','hardware'],required=True);a=p.parse_args()
root=Path.cwd();evidence=Path(__file__).resolve().parent;out=evidence/a.label;out.mkdir(exist_ok=False)
private=Path('/home/yan/.cache/quod-m4-r2-artifacts/private')/a.label;private.mkdir(mode=0o700)
for n in ['runtime','config','data']:(private/n).mkdir(mode=0o700)
retained=out/'native-xr-driver.py';shutil.copy2(__file__,retained)
bundle=Path('/home/yan/.cache/quod-m4-r2-artifacts/runtime')
runtime=a.runtime_prefix or bundle/'monado-system'
libs='' if a.runtime_prefix else json.loads((evidence/'inputs/private-library-path.json').read_text())['LD_LIBRARY_PATH']
manifest=runtime/'share/openxr/1/openxr_monado.json' if a.runtime_prefix else runtime/'openxr_monado.json'
env=dict(os.environ,LD_LIBRARY_PATH=libs,XR_RUNTIME_JSON=str(manifest),
    XDG_RUNTIME_DIR=str(private/'runtime'),XDG_CONFIG_HOME=str(private/'config'),XDG_DATA_HOME=str(private/'data'),
    M1B_PHASE=a.phase,M1B_RESULT=str(out/'client-result.json'),XR_LOADER_DEBUG='all')
env.pop('LD_PRELOAD',None)
if a.fault_output:env['M1B_RESULT']=str(private/'missing-parent/result.json')
if a.api_dump:
    env.update(XR_ENABLE_API_LAYERS='XR_APILAYER_LUNARG_api_dump',XR_API_DUMP_EXPORT_TYPE='text',XR_API_DUMP_FILE_NAME=str(private/'api-dump-raw.txt'))
display=os.environ.get('WAYLAND_DISPLAY')
if display:env['WAYLAND_DISPLAY']=display if Path(display).is_absolute() else str(Path(os.environ['XDG_RUNTIME_DIR'])/display)
if a.mode=='simulated':env.update(SIMULATED_ENABLE='1',SIMULATED_LEFT='simple',SIMULATED_RIGHT='simple',XRT_COMPOSITOR_FORCE_XCB='1',XRT_COMPOSITOR_SCALE_PERCENTAGE='50',SDL_VIDEODRIVER='x11')
else:env['SIMULATED_ENABLE']='0'
if a.compositor=='wayland-lease':env['XRT_COMPOSITOR_FORCE_WAYLAND_DIRECT']='1'
elif a.compositor=='window':env.update(XRT_COMPOSITOR_FORCE_XCB='1',XRT_COMPOSITOR_SCALE_PERCENTAGE='50',SDL_VIDEODRIVER='x11')
service_command=[str(runtime/'bin/monado-service')]
before=None
if a.lighthouse:
    from private_vive import prepare,unchanged,active_runtime_processes
    running=active_runtime_processes()
    if running:raise RuntimeError('An existing runtime is active; do not interfere')
    prefix,extra,before=prepare(private);env.update(extra);service_command=prefix+service_command
    shutil.copy2(evidence/'private_vive.py',out/'private_vive.py')
client_command=[str(a.export),'--display-driver','wayland','--audio-driver','Dummy','--xr-mode','on','--rendering-method','mobile','--rendering-driver','vulkan']
if a.project:client_command+=['--path',str(a.project)]
if a.script:client_command+=['--script',a.script]
client_command+=['--','--qualification','--profile',str(private/'identity')]
record={'driver_command':[sys.executable,*sys.argv],'start_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'mode':a.mode,'phase':a.phase,'compositor':a.compositor,'physical_acceptance':False,'service_command':service_command,'client_command':client_command,
    'worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','driver_sha256':hashlib.sha256(retained.read_bytes()).hexdigest(),
    'client_executable_sha256':hashlib.sha256(a.export.read_bytes()).hexdigest(),'runtime_manifest':env['XR_RUNTIME_JSON'],
    'private_runtime_dir':env['XDG_RUNTIME_DIR'],'private_library_path':libs,'watchdog_seconds':90,'passed':False}
(out/'invocation.json').write_text(json.dumps(record,indent=2)+'\n')
service=client=drain=diagnostic_timer=None;start=time.monotonic()
disconnected=threading.Event()
prctl=ctypes.CDLL(None).prctl;driver_pid=os.getpid()
def allow_owned_trace():
    if prctl(0x59616d61,driver_pid,0,0,0)!=0:os._exit(125)
def capture_stall():
    if client is None or client.poll() is not None:return
    diagnostics=private/'diagnostics';diagnostics.mkdir(mode=0o700)
    command=['gdb','-q','-nx','-batch','-p',str(client.pid),'-ex','set auto-load off','-ex','set print frame-arguments none','-ex','set print entry-values no','-ex','thread apply all bt 20','-ex','detach']
    detail={'owned_child_pid':client.pid,'command':command,'capture_timeout_seconds':15,'watchdog_seconds':90,'capture_after_seconds':70,'arguments':False,'memory_dump':False}
    try:
        trace=diagnostics/'native-stacks.log'
        with trace.open('x') as log:trace.chmod(0o600);detail['child_exit']=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=15).returncode
    except Exception as error:detail['error']=type(error).__name__
    (diagnostics/'capture.json').write_text(json.dumps(detail,indent=2)+'\n');record['diagnostic_capture']=detail
def sanitized(data):return re.sub(rb'LHR-[A-Za-z0-9]+',b'<device-serial-redacted>',data)
try:
    with (private/'runtime-raw.log').open('xb') as runtime_log:
        service=subprocess.Popen(service_command,cwd=private,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        selector=selectors.DefaultSelector();selector.register(service.stdout,selectors.EVENT_READ);received=b'';deadline=time.monotonic()+30
        while b'The Monado service has started.' not in received:
            left=deadline-time.monotonic()
            if left<=0 or not selector.select(left):raise TimeoutError('Owned service startup deadline')
            block=os.read(service.stdout.fileno(),65536)
            if not block:raise RuntimeError('Owned service ended before readiness')
            received+=block;runtime_log.write(block);runtime_log.flush()
        selector.close();record['service_ready']=True
        def receive():
            for line in service.stdout:
                runtime_log.write(line);runtime_log.flush()
                if b'[client_disconnected]' in line:disconnected.set()
        drain=threading.Thread(target=receive);drain.start()
        print('R2_PRIVATE_XR_SERVICE_READY '+a.label,flush=True)
        with (private/'client-raw.log').open('xb') as client_log:
            client=subprocess.Popen(client_command,cwd=root,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,preexec_fn=allow_owned_trace)
            diagnostic_timer=threading.Timer(70,capture_stall);diagnostic_timer.start()
            client_errors=[]
            def receive_client():
                try:
                    for line in client.stdout:
                        client_log.write(line);client_log.flush()
                        if line.startswith((b'M4_XR_INPUT_READY',b'M4_XR_INPUT_RECEIVED')):print(line.decode().rstrip(),flush=True)
                except Exception as error:client_errors.append(type(error).__name__)
            client_drain=threading.Thread(target=receive_client);client_drain.start()
            try:record['client_exit']=client.wait(timeout=90)
            except subprocess.TimeoutExpired:
                record['client_timeout']=True;client.kill();record['client_exit']=client.wait(timeout=10)
            client_drain.join(timeout=5)
            record['client_output_eof']=not client_drain.is_alive();record['client_output_errors']=client_errors
            if client_drain.is_alive() or client_errors:raise RuntimeError('Owned client output did not reach a clean EOF')
        if a.runtime_prefix and service.poll() is None:
            record['client_disconnect_notice']=disconnected.wait(timeout=5)
            command=[str(runtime/'bin/monado-ctl')]
            inventory=subprocess.run(command,env=env,capture_output=True,timeout=5)
            (private/'post-client-inventory.log').write_bytes(inventory.stdout+inventory.stderr)
            (out/'post-client-inventory.log').write_bytes(sanitized(inventory.stdout+inventory.stderr))
            record['post_client_inventory']={'command':command,'child_exit':inventory.returncode,'owned_client_present':bool(re.search(rb'pid:\s*'+str(client.pid).encode()+rb'\b',inventory.stdout))}
        # The service's documented stdin exit is owned by this driver. Keep its
        # output drain alive until the service has actually exited and EOF arrives.
        if service.poll() is None:service.stdin.write(b'\n');service.stdin.flush();service.stdin.close()
        record['service_exit']=service.wait(timeout=15);drain.join(timeout=5)
        if drain.is_alive():raise RuntimeError('Owned runtime output did not reach EOF')
except Exception as error:record['error']=type(error).__name__+': '+str(error)
finally:
    if client is not None and client.poll() is None:client.kill();record['client_exit']=client.wait(timeout=10)
    if diagnostic_timer is not None:diagnostic_timer.cancel();diagnostic_timer.join(timeout=16)
    if service is not None and service.poll() is None:
        service.terminate()
        try:record['service_exit']=service.wait(timeout=15)
        except subprocess.TimeoutExpired:service.kill();record['service_exit']=service.wait(timeout=10)
    if drain is not None:drain.join(timeout=5)
    for n in ['runtime','client']:
        raw=private/(n+'-raw.log')
        if raw.exists():raw.chmod(0o600);(out/(n+'.log')).write_bytes(sanitized(raw.read_bytes()))
    if (out/'client.log').exists():
        text=(out/'client.log').read_text(errors='replace')
        record['client_diagnostics']=[s for s in text.splitlines() if 'ERROR' in s or 'leaked' in s or "isn't part of an action set" in s]
        record['completion_marker']=a.completion_marker in text
    record['completed']=(out/'client-result.json').exists()
    record['elapsed_seconds']=time.monotonic()-start
    if a.api_dump:
        dump=private/'api-dump-raw.txt'
        if dump.exists():
            dump.chmod(0o600);record['api_dump']={'private_path':str(dump),'sha256':hashlib.sha256(dump.read_bytes()).hexdigest(),'bytes':dump.stat().st_size}
    if before is not None:record['original_lighthouse_unchanged']=unchanged(before)
    record['passed']=record['completed'] and record.get('completion_marker') and record.get('client_exit')==0 and record.get('service_exit')==0 and not record.get('client_timeout') and not record.get('client_diagnostics') and not record.get('error')
    (out/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record),flush=True)
raise SystemExit(0 if record['passed'] else 1)
