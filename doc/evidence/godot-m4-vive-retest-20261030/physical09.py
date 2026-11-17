"""Owned real signed application/runtime; manual steps never synthesize XR input."""
import argparse,ctypes,hashlib,importlib.util,json,os,queue,re,shutil,subprocess,sys,threading,time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent.parent/'godot-m4-vive-physical-20261029'))
from environment import TASK,environment
from publication import redact_devices

p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('--client-manifest',type=Path,required=True);p.add_argument('--require-wands',action='store_true');a=p.parse_args()
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent
out=ev/a.label;out.mkdir(exist_ok=False)
private=TASK/'private'/a.label;private.mkdir(mode=0o700,exist_ok=False)
for n in ['runtime','config','data','cache','drivers']:(private/n).mkdir(mode=0o700)
def h(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def load_module(name,p):
    spec=importlib.util.spec_from_file_location(name,p);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
vive=load_module('physical_private_vive',root/'doc/evidence/godot-m4-r2-20261029/private_vive.py')
display_module=load_module('physical_vive_display',root/'doc/evidence/godot-m4-vr-20261029/vive_display.py')
assert not vive.active_runtime_processes(),'Another runtime is active; no interference permitted'
manifest=json.loads(a.client_manifest.read_text());assert manifest['passed'] and manifest['diagnostic_physical_partial']
client=Path(manifest['export_executable'])
assert all(h(client.parent/n)==v['sha256'] and (client.parent/n).stat().st_size==v['bytes'] for n,v in manifest['export_outputs'].items())
drivers={}
for source in sorted(ev.iterdir()):
    if source.is_file() and source.suffix in ['.py','.cs','.erl','.patch']:
        shutil.copy2(source,private/'drivers'/source.name);drivers[source.name]=h(source)
for source in [root/'doc/evidence/godot-m4-r2-20261029/private_vive.py',root/'doc/evidence/godot-m4-vr-20261029/vive_display.py']:
    shutil.copy2(source,private/'drivers'/source.name);drivers[str(source.relative_to(root))]=h(source)
record={'label':a.label,'started_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'diagnostic':True,'hardware':True,'synthetic_input':False,'driver_inputs':drivers,'client_manifest':{'path':str(a.client_manifest),'sha256':h(a.client_manifest)},'engine_sha256':h(client),'payload':manifest['export_outputs'],'reader_errors':[],'manual_bound_seconds':1800,'normal_close_watchdog_seconds':60,'passed':False,'commands':[]}
processes={};readers=[];streams=[];events=queue.Queue();observed={};display=None;calibration=None;client_finished=False;product_ready=False;timer=None
runtime=Path('/home/yan/.cache/quod-m4-r2-artifacts/runtime/monado-compatible02-install')
def receive(name,process):
    for kind in ['stdout','stderr']:
        output=(private/(name+'-'+kind+'.raw')).open('xb');streams.append(output)
        def drain(pipe= getattr(process,kind),output=output,name=name,kind=kind):
            try:
                for line in pipe:
                    output.write(line);output.flush()
                    for prefix in [b'M1B_READY ',b'M4_VIVE_PRODUCT_READY',b'M4_VIVE_FIRST_DRAW',b'M4_VIVE_PRODUCT_FINISHED']:
                        if line.startswith(prefix):observed[(name,prefix)]=line[len(prefix):].strip()
                    if name=='runtime':
                        for prefix in [b'The Monado service has started.',b'Device search time complete.']:
                            if prefix in line:observed[(name,prefix)]=b''
                    events.put((name,kind,line))
                    if name=='client' and line.startswith((b'M4_VIVE_',b'PASS ')):print(line.decode(errors='replace').rstrip(),flush=True)
            except Exception as error:record['reader_errors'].append({'owner':name,'stream':kind,'error':type(error).__name__})
            finally:events.put((name,kind,None))
        thread=threading.Thread(target=drain);readers.append((name,kind,thread));thread.start()
def wait_line(name,prefix,seconds):
    deadline=time.monotonic()+seconds
    while True:
        # Preserve already delivered phase notifications even if the next
        # phase's first draw arrived while a preceding async save completed.
        if (name,prefix) in observed:return observed[(name,prefix)]
        left=deadline-time.monotonic()
        if left<=0:raise TimeoutError(name+' readiness deadline')
        owner,kind,line=events.get(timeout=left)
        if owner==name and line is None:raise RuntimeError(name+' EOF before readiness: '+kind)
        # Monado's existing startup notification is inside its banner. App and
        # fixture protocol markers remain anchored and payload-exact.
        if owner==name and name=='runtime' and prefix in line:return b''
        if owner==name and line.startswith(prefix):return line[len(prefix):].strip()
def owned_window():
    rows=json.loads(subprocess.check_output(['hyprctl','-j','clients'],timeout=5))
    owned=[w for w in rows if w.get('pid')==processes['client'].pid and w.get('mapped')]
    if len(owned)!=1 or not re.fullmatch(r'0x[0-9a-fA-F]+',owned[0]['address']):raise RuntimeError('Exact owned mapped PID/address window guard failed')
    if 'owned_window_address' in record and record['owned_window_address']!=owned[0]['address']:raise RuntimeError('Owned address changed')
    record['owned_window_address']=owned[0]['address'];return owned[0]['address']
def dispatch(action):
    address=owned_window();before=json.loads(subprocess.check_output(['hyprctl','-j','activewindow'],timeout=5))
    before_owned=before.get('pid')==processes['client'].pid and before.get('address')==address
    cmd=['hyprctl','dispatch','hl.dsp.focus({window="address:'+address+'"})']
    if action=='closewindow':cmd=['hyprctl','dispatch','hl.dsp.window.close({window="address:'+address+'"})']
    r=subprocess.run(cmd,capture_output=True,timeout=5);receipt={'command':cmd,'exit':r.returncode,'stdout':r.stdout.decode(),'stderr':r.stderr.decode(),'before_owned_focus':before_owned};record['commands'].append(receipt)
    if r.returncode:raise RuntimeError('Owned window dispatch failed')
    if action!='closewindow':
        active=json.loads(subprocess.check_output(['hyprctl','-j','activewindow'],timeout=5))
        receipt['after_owned_focus']=active.get('pid')==processes['client'].pid and active.get('address')==address
        if not receipt['after_owned_focus']:raise RuntimeError('Owned focus verification failed')
def capture():
    child=processes.get('client')
    if child is None or child.poll() is not None:return
    directory=private/'stacks';directory.mkdir(mode=0o700)
    command=['gdb','-q','-nx','-batch','-iex','set auto-load off','-iex','set print frame-arguments none','-iex','set print entry-values no','-p',str(child.pid),'-ex','thread apply all bt 20','-ex','detach']
    with (directory/'native.raw').open('xb') as f:
        try:record['stack_capture_exit']=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=15).returncode
        except Exception as error:record['stack_capture_error']=type(error).__name__
def request_close():
    global timer
    dispatch('closewindow')
    if timer is None:
        timer=threading.Timer(20,capture);timer.start()
try:
    server_label=a.label+'-server';server_private=TASK/'private'/('quod-m4-live-'+server_label)
    command=['python3',str(root/'doc/evidence/godot-m4-vive-physical-20261029/serve.py'),server_label,'--stage','/data/quod-m4-vr-ca84d4f8-20261029/artifacts/server-runtime-restoration05','--profile','prod','--qualified']
    record['server_command']=command;processes['server']=subprocess.Popen(command,env=environment(),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE);receive('server',processes['server'])
    ready=json.loads(wait_line('server',b'M1B_READY ',60));record['endpoint']=ready
    prefix,extra,calibration=vive.prepare(private)
    env=environment();env.update(extra,XDG_RUNTIME_DIR=str(private/'runtime'),XDG_CONFIG_HOME=str(private/'config'),XDG_DATA_HOME=str(private/'data'),XDG_CACHE_HOME=str(private/'cache'),TMPDIR=str(private/'temporary'),TMP=str(private/'temporary'),TEMP=str(private/'temporary'),SIMULATED_ENABLE='0',XRT_COMPOSITOR_FORCE_WAYLAND_DIRECT='1',XR_RUNTIME_JSON=str(runtime/'share/openxr/1/openxr_monado.json'),XR_ENABLE_API_LAYERS='XR_APILAYER_LUNARG_api_dump',XR_API_DUMP_EXPORT_TYPE='text',XR_API_DUMP_FILE_NAME=str(private/'api-dump.raw'),M1B_PHASE='vive-physical',M1B_RESULT=str(private/'client-result.raw.json'),M1B_NETWORK=ready['network'],DOTNET_ROOT=str(private/'no-installed-runtime'))
    if os.environ.get('WAYLAND_DISPLAY'):env['WAYLAND_DISPLAY']=str(Path(os.environ['XDG_RUNTIME_DIR'])/os.environ['WAYLAND_DISPLAY'])
    display=display_module.ViveDisplay(private);display.enable()
    command=prefix+[str(runtime/'bin/monado-service')];record['runtime_command']=command;record['runtime_manifest_sha256']=h(runtime/'share/openxr/1/openxr_monado.json')
    runtime_until=time.monotonic()+30
    processes['runtime']=subprocess.Popen(command,env=env,cwd=private,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE);receive('runtime',processes['runtime']);wait_line('runtime',b'The Monado service has started.',runtime_until-time.monotonic())
    if a.require_wands:
        wait_line('runtime',b'Device search time complete.',runtime_until-time.monotonic())
        # A single actual inventory query after the owner's startup notice,
        # never polling or extending its fixed discovery window. Derive the
        # named enum from the exact pinned provider header, not a guessed ID.
        header=Path('/home/yan/.cache/quod-m4-r2-artifacts/runtime/monado-current-source/monado-59be345db769a89c93d1bdf6ed8316fa6209d8ae/src/xrt/include/xrt/xrt_defines.h')
        body=header.read_text().split('enum xrt_device_name\n{',1)[1].split('};',1)[0]
        names=re.findall(r'^\s*(XRT_DEVICE_[A-Z0-9_]+)\s*,',body,re.M);assert names[0]=='XRT_DEVICE_INVALID'
        wand=names.index('XRT_DEVICE_VIVE_WAND')
        query=[str(runtime/'bin/monado-ctl')];r=subprocess.run(query,env=env,capture_output=True,timeout=5)
        for kind,data in [('stdout',r.stdout),('stderr',r.stderr)]:
            (private/('startup-inventory-'+kind+'.raw')).write_bytes(data)
            (out/('startup-inventory-'+kind+'.log')).write_bytes(redact_devices(data))
        devices=re.findall(rb'^\s*id:\s*(\d+)\s+name:\s*(\d+)\s+"([^"\r\n]*)"',r.stdout.split(b'Devices:',1)[-1],re.M)
        count=sum(int(name)==wand for _,name,_ in devices)
        record['startup_inventory']={'command':query,'exit':r.returncode,'enum_header_sha256':h(header),'named_enum':'XRT_DEVICE_VIVE_WAND','derived_value':wand,'wand_devices':count,'streams':{k:{'sha256':hashlib.sha256(d).hexdigest(),'bytes':len(d)} for k,d in [('stdout',r.stdout),('stderr',r.stderr)]}}
        print('M4_PHYSICAL_STARTUP_WANDS '+str(count),flush=True)
        if r.returncode or count<2:raise RuntimeError('Owned runtime startup did not admit both Vive wands; application not launched')
    command=[str(client),'--display-driver','wayland','--audio-driver','Dummy','--xr-mode','on','--rendering-method','mobile','--rendering-driver','vulkan','--','--qualification','--profile',str(private/'identity'),'--node','https://127.0.0.1:'+str(ready['port']),'--ca',str(server_private/'backend-ca.pem')]
    record['client_command']=command;owner=os.getpid()
    def trace_permission():
        if ctypes.CDLL(None).prctl(0x59616d61,owner,0,0,0)!=0:os._exit(125)
    processes['client']=subprocess.Popen(command,env=env,cwd=root,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,preexec_fn=trace_permission);receive('client',processes['client'])
    wait_line('client',b'M4_VIVE_PRODUCT_READY',60);product_ready=True;record['product_ready']=True;dispatch('focuswindow');wait_line('client',b'M4_VIVE_FIRST_DRAW',30);print('M4_PHYSICAL_APPLICATION_READY',flush=True)
    instructions=queue.Queue()
    def read_commands():
        for line in sys.stdin:instructions.put(line.strip())
        instructions.put(None)
    command_reader=threading.Thread(target=read_commands,daemon=True);command_reader.start();until=time.monotonic()+1800
    while True:
        command=instructions.get(timeout=max(0.001,until-time.monotonic()))
        if command is None:raise RuntimeError('Physical driver stdin ended without finish')
        if command=='focus':dispatch('focuswindow');print('M4_PHYSICAL_FOCUSED',flush=True);continue
        if command not in ['sample','status','geometry','gui-check','close-form','stop','restart','finish']:raise ValueError('Unknown manual qualification command')
        if processes['client'].poll() is not None:raise RuntimeError('Application exited before command '+command)
        record['commands'].append({'diagnostic_instruction':command,'utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())})
        processes['client'].stdin.write((command+'\n').encode());processes['client'].stdin.flush()
        if command=='finish':
            wait_line('client',b'M4_VIVE_PRODUCT_FINISHED',60);client_finished=True;break
    request_close()
    try:record['client_exit']=processes['client'].wait(timeout=60)
    except subprocess.TimeoutExpired:record['client_timeout']=True;processes['client'].kill();record['client_exit']=processes['client'].wait(timeout=10)
except Exception as error:record['error']=type(error).__name__+': '+str(error)
finally:
    if timer:timer.cancel();timer.join(timeout=16)
    for name in ['client','runtime','server']:
        child=processes.get(name)
        if child is None:continue
        if child.poll() is None:
            try:
                if name=='client':
                    # On an early qualification failure Main already closes1;
                    # otherwise request its actual owned native-window close.
                    child.stdin.close();request_close();child.wait(timeout=60)
                else:child.stdin.write(b'stop\n' if name=='server' else b'\n');child.stdin.flush();child.stdin.close();child.wait(timeout=30 if name=='server' else 15)
            except Exception as error:
                record[name+'_cleanup_error']=type(error).__name__+': '+str(error)
                if child.poll() is None:child.kill()
        record[name+'_exit']=child.wait(timeout=10)
    if timer:timer.cancel();timer.join(timeout=16)
    record['eof']={}
    for name,kind,thread in readers:thread.join(timeout=5);record['eof'][name+'-'+kind]=not thread.is_alive()
    for f in streams:f.close()
    if display:
        try:display.restore();record['display_rule']=display.record
        except Exception as error:record['display_restore_error']=type(error).__name__+': '+str(error)
    if calibration is not None:record['original_calibration_unchanged']=vive.unchanged(calibration)
    record['runtime_processes_after']=vive.active_runtime_processes();record['product_finished']=client_finished
    record['streams']={}
    for name in processes:
        for kind in ['stdout','stderr']:
            path=private/(name+'-'+kind+'.raw')
            if path.exists():
                path.chmod(0o600);data=path.read_bytes();target=out/(name+'-'+kind+'.log');target.write_bytes(redact_devices(data));record['streams'][name+'-'+kind]={'raw':str(path),'sha256':h(path),'bytes':len(data),'sanitized_sha256':h(target)}
    text=''.join((private/('client-'+kind+'.raw')).read_text(errors='replace') for kind in ['stdout','stderr'] if (private/('client-'+kind+'.raw')).exists())
    record['diagnostics']=[s for s in text.splitlines() if 'ERROR' in s or 'leaked' in s]
    dump=private/'api-dump.raw'
    if dump.exists():dump.chmod(0o600);record['api_dump']={'path':str(dump),'sha256':h(dump),'bytes':dump.stat().st_size,'scope':'call entries and arguments only; no returned-status or pixel claim'}
    observation=private/'client-result.raw.json'
    if observation.exists():
        observation.chmod(0o600)
        record['private_observation']={'path':str(observation),'sha256':h(observation),'bytes':observation.stat().st_size,'mode':observation.stat().st_mode&0o777,'raw_geometry_public':False}
        try:
            sanitized=json.loads(observation.read_text())
            for snapshot in sanitized['snapshots']:
                if snapshot.get('phase')=='ninety_frames':continue
                if 'phase' not in snapshot or 'geometry' not in snapshot:raise ValueError('Missing diagnostic geometry snapshot')
                geometry=snapshot.pop('geometry')
                node=geometry['node'];renderer=geometry['renderer']
                snapshot['geometry_receipt']={'raw_retained_privately':True,'window_focused':node['window_focused'],'session_state':node['session_state'],'render_getters_observed':renderer is not None,'native_view_success_not_exposed':True,'panel_size':node['panel_size'],'gui_pixels':node['gui_pixels'],'model_visibility':[{'hand':s['hand'],'current':s['current'],'visible_roots':sum(m['visible'] for m in s['models']),'visible_meshes':sum(mesh['visible_in_tree'] for m in s['models'] for mesh in m['meshes'])} for s in node['sources']]}
            (out/'client-result.json').write_text(json.dumps(sanitized,indent=2)+'\n')
        except Exception as error:record['observation_error']=type(error).__name__+': '+str(error)
    record['passed']=client_finished and observation.exists() and all(record.get(n+'_exit')==0 for n in ['client','runtime','server']) and all(record['eof'].values()) and not record.get('client_timeout') and not record.get('error') and not record.get('observation_error') and not record['reader_errors'] and not record['diagnostics'] and not record['runtime_processes_after'] and record.get('original_calibration_unchanged') and record.get('display_rule',{}).get('desktop_unchanged') and record.get('display_rule',{}).get('config_unchanged')
    (out/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps({k:v for k,v in record.items() if k not in ['payload','streams','display_rule']}),flush=True)
raise SystemExit(0 if record['passed'] else 1)
