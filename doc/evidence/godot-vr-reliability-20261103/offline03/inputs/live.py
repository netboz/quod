"""One fresh SteamVR opportunity; existing native owners, bounded manual lifetime."""
import argparse,hashlib,json,os,queue,select,shutil,socket,subprocess,sys,threading,time
from pathlib import Path
os.umask(0o077);sys.dont_write_bytecode=True
root=Path.cwd();ev=Path(__file__).resolve().parent
sys.path.insert(0,str(root/'doc/evidence/godot-m4-vive-physical-20261029'))
from environment import environment
from hashes import Digests,TASK,key,raw
from supervision import Supervision
from owned_commands import OwnedCommands
from launch_spec import fixture_environment,client_arguments
from pipe_ownership import identity,engine_pipes,helper_pid,NamedWriter
p=argparse.ArgumentParser();p.add_argument('--label',required=True);p.add_argument('--manifest',type=Path,required=True);p.add_argument('--server-label',required=True);p.add_argument('--launch-and-begin',action='store_true',help='Only under explicit coordinator LAUNCH_AND_BEGIN authority');a=p.parse_args()
assert sys.stdin.isatty(),'interactive opportunity requires tty:true'
private=TASK/'private'/a.label;private.mkdir(mode=0o700,exist_ok=False);(private/'drivers').mkdir()
for f in ev.iterdir():
    if f.suffix in ['.py','.cs','.erl']:shutil.copy2(f,private/'drivers'/f.name)
d=Digests();manifest=json.loads(a.manifest.read_text());assert manifest['passed'] and not manifest['distributable'] and len(manifest['live_source_inputs'])==98
cache=manifest['digest_cache'];assert raw(cache['path'])==cache['sha256']
for row in json.loads(Path(cache['path']).read_text())['records']:
    k=tuple(row['stat_key']);assert k not in d.values or d.values[k]==row['sha256'];d.values[k]=row['sha256']
exe=Path(manifest['export_executable']);assert key(exe) in d.values and d.h(exe)==manifest['template']['sha256']
expected=exe.stat();server=TASK/'private'/('quod-m4-live-'+a.server_label)
rows=[json.loads(l[10:]) for l in (server/'server-raw.log').read_text().splitlines() if l.startswith('M1B_READY ')];assert len(rows)==1;server_ready=rows[0]
runtime=Path('/home/yan/.local/share/Steam/steamapps/common/SteamVR/steamxr_linux64.json');runtime_bytes=runtime.read_bytes()
assert hashlib.sha256(runtime_bytes).hexdigest()=='5954b3a1dc001cf3f496ac93de9a516c17445bff3d62e93a410bb10a113ed477'
record={'reader_errors':[],'runtime':str(runtime),'runtime_sha256':hashlib.sha256(runtime_bytes).hexdigest(),'participant_seconds':1800,'normal_close_seconds':60,'outer_seconds':2100,'prepare_seconds':180,'ordinary_product':False,'nondistributable_companion':True,'production_inputs':98,'host_input':False,'focus_requests':0,'delegated_launch_and_begin':a.launch_and_begin,'private_profile':str(private/'profile'),'manifest':str(a.manifest)}
def save(): (private/'invocation.json').write_text(json.dumps(record,indent=2)+'\n')
def windows():
    result=subprocess.run(['hyprctl','-j','clients'],capture_output=True,timeout=5);assert result.returncode==0
    return json.loads(result.stdout)
events=queue.Queue();read_event,write_event=os.pipe();threads=[];child=None;owned=None;failure=None;prepared_reported=False
monitor=runtime.parent/'bin/linux64/vrmonitor';helpers={}
record['runtime_helper_observations']=[]
def observe_helper(pid,phase):
    if pid not in helpers:helpers[pid]=NamedWriter(pid,monitor,record['engine_pipes'])
    observed=helpers[pid].observe()
    record['runtime_helper_observations'].append({'phase':phase,**observed})
sock=socket.socket(socket.AF_UNIX);sock.settimeout(5)
sock.connect(str(Path(os.environ['XDG_RUNTIME_DIR'])/'hypr'/os.environ['HYPRLAND_INSTANCE_SIGNATURE']/'.socket2.sock'))
env=environment()
qt_fields=['QT_QPA_PLATFORM','DISPLAY','WAYLAND_DISPLAY','QT_PLUGIN_PATH','QT_QPA_PLATFORM_PLUGIN_PATH']
record['launch_environment_before']={name:env.get(name) for name in qt_fields}
# SteamVR's bundled monitor offers xcb; keep Godot's explicit Wayland path.
env['QT_QPA_PLATFORM']='xcb'
record['launch_environment_after']={name:env.get(name) for name in qt_fields}
# Keep Steam's existing discovery paths; only this application's runtime is selected.
for name in ['XDG_CONFIG_HOME']:
    if name in os.environ:env[name]=os.environ[name]
    else:env.pop(name,None)
for name,subdir in [('XDG_DATA_HOME','data'),('XDG_CACHE_HOME','cache')]:
    path=private/subdir;path.mkdir(mode=0o700);env[name]=str(path)
env.update(fixture_environment(server_ready,private,runtime))
for name in ['XR_ENABLE_API_LAYERS','SIMULATED_ENABLE']:env.pop(name,None)
args=client_arguments(exe,private,server,server_ready)
record['command']=args;record['environment_overrides']={n:env[n] for n in ['XR_RUNTIME_JSON','M1B_PHASE','M1B_NETWORK','VR263_PRIVATE','QT_QPA_PLATFORM','M1B_CONTROL_PORT']}
started=time.monotonic();record['started_monotonic']=started
def notify(item):events.put(item);os.write(write_event,b'x')
def record_write(name,reason):
    record[name+'_sent_monotonic']=time.monotonic()
    if name=='finish':record['finish_reason']=reason
    save()
commands=None
supervisor=Supervision(started,lambda reason:commands.finish(reason),lambda:commands.begin(supervisor))
def wait_normal():
    if child.poll() is not None:return child.wait()
    deadline=min(started+2100,(supervisor.finish_at if supervisor.finish_at is not None else time.monotonic())+60)
    return child.wait(timeout=max(0,deadline-time.monotonic()))
try:
    child=subprocess.Popen(args,cwd=exe.parent,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    record['engine_pid']=child.pid;record['engine_incarnation']=identity(child.pid)
    assert record['engine_incarnation'][:2]==[expected.st_dev,expected.st_ino]
    record['engine_pipes']=engine_pipes(child,record['engine_incarnation']);save()
    commands=OwnedCommands(child,record['engine_incarnation'],lambda:owned,windows,time.monotonic,record_write)
    initial=[w for w in windows() if w.get('pid')==child.pid and w.get('mapped')]
    assert len(initial)<=1
    if initial:
        assert identity(child.pid)==record['engine_incarnation']
        owned={'pid':child.pid,'incarnation':record['engine_incarnation'],'address':initial[0]['address']};record['owned_binding']=owned;save()
    for stream in ['stdout','stderr']:
        def drain(stream=stream):
            try:
                with (private/(stream+'.raw')).open('xb') as out:
                    for line in getattr(child,stream):
                        out.write(line);out.flush()
                        if line.startswith(b'VR263_'):notify(('marker',line.decode().strip()))
                        if stream=='stderr':
                            pid=helper_pid(line,monitor)
                            if pid is not None:notify(('helper_launch',pid))
                notify(('eof',stream))
            except Exception as e:record['reader_errors'].append(type(e).__name__);notify(('reader_error',stream))
        t=threading.Thread(target=drain,daemon=True);t.start();threads.append((stream,t))
    def wait_child():notify(('exit',child.wait()))
    threading.Thread(target=wait_child,daemon=True).start();save();buf=b''
    while child.poll() is None:
        now=time.monotonic()
        deadline=supervisor.deadline
        if now>=deadline:
            supervisor.cutoff(now);record['cutoff']=supervisor.finish_reason
            if supervisor.participant_deadline is None:failure='preparation deadline before readiness'
            break
        available,_,_=select.select([sock,read_event,sys.stdin],[],[],deadline-now)
        if read_event in available:
            os.read(read_event,65536)
            while not events.empty():
                kind,value=events.get()
                if kind=='marker':
                    marker,payload=value.split(' ',1);data=json.loads(payload);record[marker]=data
                    first_ready=supervisor.marker(marker,data,time.monotonic(),time.time())
                    record.update(participant_deadline_monotonic=supervisor.participant_deadline,auth_deadline_monotonic=supervisor.auth_deadline,auth_expires_ms=supervisor.auth_expires_ms)
                    if first_ready:
                        assert owned is not None,'visual ready lacks exact mapped incarnation'
                        print(json.dumps({'VISUAL_READY':data,'interactive_readiness_claim':False,'owned':owned,'private_invocation':str(private/'invocation.json'),'remaining_seconds':supervisor.deadline-time.monotonic(),'finish_hook':'finish newline once to this current client PTY'}),flush=True)
                    elif marker=='VR263_BLOCKER':
                        failure='visual frame admission deadline';print(json.dumps({'BLOCKER':data,'owned':owned,'private_invocation':str(private/'invocation.json')}),flush=True)
                    elif marker=='VR263_READY':
                        if supervisor.finish_reason is None and supervisor.participant_deadline is not None:
                            print(json.dumps({'INTERACTION_READY':data,'owned':owned,'private_invocation':str(private/'invocation.json'),'remaining_seconds':supervisor.deadline-time.monotonic()}),flush=True)
                        else:
                            print(json.dumps({'readiness_not_admitted':marker,'finish_reason':supervisor.finish_reason}),flush=True)
                    elif marker in ['VR263_STATE','VR263_STATUS']:
                        print(value,flush=True)
                    elif marker=='VR263_FIRST_XR_FRAME':
                        print(json.dumps({'RENDERING_ONLY':data,'visual_readiness_claim':False,'interactive_readiness_claim':False,'owned':owned}),flush=True)
                    elif marker=='VR263_VISUAL_READY':
                        print(json.dumps({'readiness_not_admitted':marker,'finish_reason':supervisor.finish_reason,'participant_interval_already_started':supervisor.participant_deadline is not None}),flush=True)
                elif kind=='helper_launch':observe_helper(value,'runtime_launch_line')
                elif kind=='exit':record['client_exit']=value
            save()
        if sock in available:
            data=sock.recv(65536)
            if not data:raise RuntimeError('compositor event EOF')
            buf+=data
            while b'\n' in buf:
                line,buf=buf.split(b'\n',1)
                if owned or not line.startswith(b'openwindow>>'):continue
                address='0x'+line.split(b'>>',1)[1].split(b',',1)[0].decode().removeprefix('0x')
                match=[w for w in windows() if w.get('pid')==child.pid and w.get('address')==address and w.get('mapped')]
                if match:
                    assert identity(child.pid)==record['engine_incarnation'];owned={'pid':child.pid,'incarnation':record['engine_incarnation'],'address':address};record['owned_binding']=owned
                    # XR focus owns readiness; no repeat of263's failed focus request.
                    save()
                    print(json.dumps({'mapped_only':owned,'not_ready':True}),flush=True)
        if supervisor.prepared and owned is not None and not prepared_reported and supervisor.finish_reason is None:
            for pid in list(helpers):observe_helper(pid,'prepared')
            prepared_reported=True
            record['prepared_reported_monotonic']=time.monotonic();save()
            print(json.dumps({'PREPARED':'LOCALLY_DELEGATED_BEGIN' if a.launch_and_begin else 'WAITING_FOR_WEAR','not_xr_ready':True,'owned':owned,'auth_expires_ms':supervisor.auth_expires_ms,'remaining_preparation_seconds':started+180-time.monotonic(),'remaining_auth_seconds':supervisor.auth_deadline-time.monotonic(),'participant_deadline':None,'commands':['begin once','status','finish or stop'],'private_invocation':str(private/'invocation.json')}),flush=True)
            commands.delegated_begin(supervisor,a.launch_and_begin)
            record['begin_at_monotonic']=supervisor.begin_at;save()
        if sys.stdin in available:
            line=sys.stdin.readline().strip()
            if supervisor.command(line,time.monotonic(),mapped=owned is not None):break
            record['begin_at_monotonic']=supervisor.begin_at;save()
            if line=='status' and child.poll() is None:child.stdin.write(b'status\n');child.stdin.flush()
        if supervisor.finish_reason is not None:break
    record['client_exit']=wait_normal()
except Exception as error:
    failure=type(error).__name__+': '+str(error)
finally:
    record['failure']=failure;sock.close()
    if child is not None and child.poll() is None:
        try:supervisor.stop('supervision_failure',time.monotonic());record['client_exit']=wait_normal()
        except Exception as error:record['retirement_failure']=type(error).__name__+': '+str(error)
    for name,t in threads:t.join(timeout=5)
    while not events.empty():
        kind,value=events.get()
        if kind=='helper_launch':observe_helper(value,'retirement_launch_line')
    for pid in list(helpers):observe_helper(pid,'after_client_wait')
    record['eof']={name:not t.is_alive() for name,t in threads};record['completed_monotonic']=time.monotonic();save()
    print(json.dumps({'closed':child is not None and child.poll() is not None,'client_exit':record.get('client_exit'),'eof':record['eof'],'failure':failure,'retirement_failure':record.get('retirement_failure'),'private_invocation':str(private/'invocation.json')}),flush=True)
raise SystemExit(0 if record.get('client_exit')==0 and not failure and not record.get('retirement_failure') and all(record['eof'].values()) and not record['reader_errors'] else 1)
