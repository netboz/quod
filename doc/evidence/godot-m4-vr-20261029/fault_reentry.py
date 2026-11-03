"""Two real application sessions on one owned simulator runtime, no input injection.

First fail the existing qualification output write, then reenter using the same
unchanged application. Both use Main.CloseApplication and the original bounds.
This is a diagnostic lifecycle campaign, not a historical desktop-stall repro.
"""
import argparse,ctypes,hashlib,importlib.util,json,os,re,subprocess,threading
from pathlib import Path
from environment import TASK,environment

p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('--client',type=Path,required=True);a=p.parse_args()
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent
out=ev/a.label;out.mkdir(exist_ok=False)
private=TASK/'private'/a.label;private.mkdir(mode=0o700,exist_ok=False)
spec=importlib.util.spec_from_file_location('qualified_vive_inventory',root/'doc/evidence/godot-m4-r2-20261029/private_vive.py')
vive=importlib.util.module_from_spec(spec);spec.loader.exec_module(vive)
assert not vive.active_runtime_processes(),'Do not interfere with another runtime'
runtime=Path('/home/yan/.cache/quod-m4-r2-artifacts/runtime/monado-compatible02-install')
env=environment()
for key,name in [('XDG_RUNTIME_DIR','runtime'),('XDG_CONFIG_HOME','config'),('XDG_DATA_HOME','data'),('XDG_CACHE_HOME','cache')]:
    directory=private/name;directory.mkdir(mode=0o700);env[key]=str(directory)
if os.environ.get('WAYLAND_DISPLAY'):env['WAYLAND_DISPLAY']=str(Path(os.environ['XDG_RUNTIME_DIR'])/os.environ['WAYLAND_DISPLAY'])
env.update(XR_RUNTIME_JSON=str(runtime/'share/openxr/1/openxr_monado.json'),SIMULATED_ENABLE='1',SIMULATED_LEFT='simple',SIMULATED_RIGHT='simple',XRT_COMPOSITOR_FORCE_XCB='1',XRT_COMPOSITOR_SCALE_PERCENTAGE='50',SDL_VIDEODRIVER='x11',M1B_PHASE='openxr',XR_ENABLE_API_LAYERS='XR_APILAYER_LUNARG_api_dump',XR_API_DUMP_EXPORT_TYPE='text')
command=[str(a.client),'--display-driver','wayland','--audio-driver','Dummy','--xr-mode','on','--rendering-method','mobile','--rendering-driver','vulkan','--','--qualification']
record={'passed':False,'client_command':command,'engine_sha256':hashlib.sha256(a.client.read_bytes()).hexdigest(),
    'application_payload':{str(f.relative_to(a.client.parent)):{'sha256':hashlib.sha256(f.read_bytes()).hexdigest(),'bytes':f.stat().st_size} for f in sorted(a.client.parent.rglob('*')) if f.is_file()},
    'runtime_manifest_sha256':hashlib.sha256((runtime/'share/openxr/1/openxr_monado.json').read_bytes()).hexdigest(),
    'native_session_scope':'Two application/native-session lifetimes on one owned runtime; first intentional output failure, then ordinary three-adapter-cycle success.',
    'runtime_start_bound_seconds':30,'client_bound_seconds':90,'runtime_stop_bound_seconds':15,'reader_errors':[],'cases':[],'physical_acceptance':False}
service=client=None;readers=[];ready=threading.Event();condition=threading.Condition();service_ready=False;disconnects=0
owner=os.getpid();prctl=ctypes.CDLL(None).prctl
def allow_trace():
    if prctl(0x59616d61,owner,0,0,0)!=0:os._exit(125)
def drain(process,name,directory):
    handles=[]
    for kind in ['stdout','stderr']:
        target=directory/(name+'-'+kind+'.raw')
        def receive(pipe,target=target):
            global service_ready,disconnects
            try:
                with target.open('xb') as stream:
                    for line in pipe:
                        stream.write(line);stream.flush()
                        if name=='runtime' and b'The Monado service has started.' in line:service_ready=True;ready.set()
                        if name=='runtime' and b'[client_disconnected]' in line:
                            with condition:disconnects+=1;condition.notify_all()
            except Exception as error:record['reader_errors'].append(name+':'+type(error).__name__)
            finally:
                if name=='runtime':ready.set()
        thread=threading.Thread(target=receive,args=(getattr(process,kind),));thread.start();handles.append((kind,thread))
    return handles
def capture(process,directory,row):
    if process.poll() is not None:return
    stacks=directory/'stacks';stacks.mkdir(mode=0o700)
    cmd=['gdb','-q','-nx','-batch','-iex','set auto-load off','-iex','set print frame-arguments none','-iex','set print entry-values no','-p',str(process.pid),'-ex','thread apply all bt 20','-ex','detach']
    with (stacks/'native.raw').open('xb') as stream:
        try:row['bounded_stack_capture_exit']=subprocess.run(cmd,stdout=stream,stderr=subprocess.STDOUT,timeout=15).returncode
        except Exception as error:row['bounded_stack_capture_error']=type(error).__name__
def public_streams(directory,destination,name):
    for kind in ['stdout','stderr']:
        raw=directory/(name+'-'+kind+'.raw')
        if raw.exists():raw.chmod(0o600);(destination/(name+'-'+kind+'.log')).write_bytes(re.sub(rb'(?i)LHR-[A-Za-z0-9]+',b'<device-serial-redacted>',raw.read_bytes()))
try:
    service=subprocess.Popen([str(runtime/'bin/monado-service')],cwd=private,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    record['owned_runtime_pid']=service.pid;readers=drain(service,'runtime',private)
    assert ready.wait(30) and service_ready,'Owned runtime startup failed'
    for phase in ['output-fault','reentry']:
        directory=private/phase;directory.mkdir(mode=0o700);destination=out/phase;destination.mkdir()
        row={'phase':phase,'expected_client_exit':1 if phase=='output-fault' else 0,'passed':False};record['cases'].append(row)
        childenv=dict(env,M1B_RESULT=str(directory/'missing-parent/result.json' if phase=='output-fault' else destination/'client-result.json'),XR_API_DUMP_FILE_NAME=str(directory/'api-dump.raw'))
        childcommand=command+['--profile',str(directory/'identity')];row['command']=childcommand
        count_before=disconnects
        client=subprocess.Popen(childcommand,cwd=root,env=childenv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,preexec_fn=allow_trace)
        row['owned_child_pid']=client.pid;child_readers=drain(client,'client',directory)
        timer=threading.Timer(70,capture,args=(client,directory,row));timer.start()
        try:
            try:row['client_exit']=client.wait(timeout=90)
            except subprocess.TimeoutExpired:row['timeout']=True;client.kill();row['client_exit']=client.wait(timeout=10)
        finally:timer.cancel();timer.join(timeout=16)
        row['eof']={}
        for kind,thread in child_readers:thread.join(timeout=5);row['eof'][kind]=not thread.is_alive()
        public_streams(directory,destination,'client')
        text=''.join((directory/('client-'+kind+'.raw')).read_text(errors='replace') for kind in ['stdout','stderr'])
        row['intentional_output_exception']='System.IO.DirectoryNotFoundException:' in text
        row['completion_marker']='M4_XR_PASS' in text
        row['targeted_native_diagnostics']=[line for line in text.splitlines() if any(marker in line for marker in ['XR_ERROR_SESSION_NOT_STOPPING','nonexistent connection','leaked','isn\'t part of an action set'])]
        with condition:row['disconnect_notice']=condition.wait_for(lambda:disconnects>count_before,timeout=5)
        inventory=subprocess.run([str(runtime/'bin/monado-ctl')],env=env,capture_output=True,timeout=5)
        (directory/'post-client-inventory.raw').write_bytes(inventory.stdout+inventory.stderr)
        row['inventory_exit']=inventory.returncode;row['owned_client_absent']=not bool(re.search(rb'pid:\s*'+str(client.pid).encode()+rb'\b',inventory.stdout))
        dump=directory/'api-dump.raw';dump.chmod(0o600);row['api_dump']={'path':str(dump),'sha256':hashlib.sha256(dump.read_bytes()).hexdigest(),'bytes':dump.stat().st_size}
        row['passed']=row['client_exit']==row['expected_client_exit'] and all(row['eof'].values()) and not row.get('timeout') and not row['targeted_native_diagnostics'] and row['disconnect_notice'] and inventory.returncode==0 and row['owned_client_absent']
        if phase=='output-fault':row['passed']&=row['intentional_output_exception'] and not row['completion_marker'] and not (directory/'missing-parent').exists()
        else:row['passed']&=row['completion_marker'] and json.loads((destination/'client-result.json').read_text())['passed']
        (destination/'result.json').write_text(json.dumps(row,indent=2)+'\n');print(json.dumps(row),flush=True)
        assert row['passed'],'Native failure/reentry expectation failed; do not silently retry'
    record['case_expectations_met']=True
except Exception as error:record['error']=type(error).__name__+': '+str(error)
finally:
    if client is not None and client.poll() is None:client.kill();record['cleanup_client_exit']=client.wait(timeout=10)
    if service is not None:
        if service.poll() is None:
            try:service.stdin.write(b'\n');service.stdin.flush();service.stdin.close();service.wait(timeout=15)
            except Exception as error:record['runtime_stop_error']=type(error).__name__;service.terminate()
        try:record['runtime_exit']=service.wait(timeout=15)
        except subprocess.TimeoutExpired:service.kill();record['runtime_exit']=service.wait(timeout=10)
    record['runtime_eof']={}
    for kind,thread in readers:thread.join(timeout=5);record['runtime_eof'][kind]=not thread.is_alive()
    public_streams(private,out,'runtime')
    record['runtime_processes_after']=vive.active_runtime_processes()
    record['passed']=record.get('case_expectations_met',False) and record.get('runtime_exit')==0 and all(record['runtime_eof'].values()) and not record.get('error') and not record['reader_errors'] and not record['runtime_processes_after']
    (out/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps({k:v for k,v in record.items() if k!='application_payload'}),flush=True)
raise SystemExit(0 if record['passed'] else 1)
