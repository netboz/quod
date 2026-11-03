"""One fresh SteamVR opportunity; existing native owners, bounded manual lifetime."""
import argparse,hashlib,json,os,queue,select,shutil,socket,subprocess,sys,threading,time
from pathlib import Path
os.umask(0o077);sys.dont_write_bytecode=True
root=Path.cwd();ev=Path(__file__).resolve().parent
sys.path.insert(0,str(root/'doc/evidence/godot-m4-vive-physical-20261029'))
from environment import environment
from hashes import Digests,TASK,key,raw
from supervision import Supervision
p=argparse.ArgumentParser();p.add_argument('--label',required=True);p.add_argument('--manifest',type=Path,required=True);p.add_argument('--server-label',required=True);a=p.parse_args()
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
record={'reader_errors':[],'runtime':str(runtime),'runtime_sha256':hashlib.sha256(runtime_bytes).hexdigest(),'participant_seconds':1800,'normal_close_seconds':60,'outer_seconds':2100,'prepare_seconds':180,'ordinary_product':False,'nondistributable_companion':True,'production_inputs':98,'host_input':False,'focus_requests':0,'private_profile':str(private/'profile'),'manifest':str(a.manifest)}
def save(): (private/'invocation.json').write_text(json.dumps(record,indent=2)+'\n')
def identity(pid):
    q=Path('/proc')/str(pid);s=(q/'exe').stat();fields=(q/'stat').read_text().rsplit(')',1)[1].split()
    return [s.st_dev,s.st_ino,int(fields[19])]
def windows():
    result=subprocess.run(['hyprctl','-j','clients'],capture_output=True,timeout=5);assert result.returncode==0
    return json.loads(result.stdout)
events=queue.Queue();read_event,write_event=os.pipe();threads=[];child=None;owned=None;failure=None
sock=socket.socket(socket.AF_UNIX);sock.settimeout(5)
sock.connect(str(Path(os.environ['XDG_RUNTIME_DIR'])/'hypr'/os.environ['HYPRLAND_INSTANCE_SIGNATURE']/'.socket2.sock'))
env=environment()
# Keep Steam's existing discovery paths; only this application's runtime is selected.
for name in ['XDG_CONFIG_HOME']:
    if name in os.environ:env[name]=os.environ[name]
    else:env.pop(name,None)
for name,subdir in [('XDG_DATA_HOME','data'),('XDG_CACHE_HOME','cache')]:
    path=private/subdir;path.mkdir(mode=0o700);env[name]=str(path)
env.update(XR_RUNTIME_JSON=str(runtime),M1B_PHASE='vr-ready263',M1B_NETWORK=server_ready['network'],VR263_PRIVATE=str(private))
for name in ['XR_ENABLE_API_LAYERS','SIMULATED_ENABLE']:env.pop(name,None)
args=[str(exe),'--display-driver','wayland','--audio-driver','Dummy','--xr-mode','on','--rendering-method','mobile','--rendering-driver','vulkan','--verbose','--','--qualification','--profile',str(private/'profile'),'--node','https://127.0.0.1:'+str(server_ready['port']),'--ca',str(server/'backend-ca.pem')]
record['command']=args;record['environment_overrides']={n:env[n] for n in ['XR_RUNTIME_JSON','M1B_PHASE','M1B_NETWORK','VR263_PRIVATE']}
started=time.monotonic();record['started_monotonic']=started
def notify(item):events.put(item);os.write(write_event,b'x')
def send_finish(reason):
    if child.poll() is not None:return
    assert identity(child.pid)==record['engine_incarnation']
    record['finish_reason']=reason;record['finish_sent_monotonic']=time.monotonic();save()
    child.stdin.write(b'finish\n');child.stdin.flush()
supervisor=Supervision(started,send_finish)
def wait_normal():
    if child.poll() is not None:return child.wait()
    deadline=min(started+2100,(supervisor.finish_at if supervisor.finish_at is not None else time.monotonic())+60)
    return child.wait(timeout=max(0,deadline-time.monotonic()))
try:
    child=subprocess.Popen(args,cwd=exe.parent,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    record['engine_pid']=child.pid;record['engine_incarnation']=identity(child.pid)
    assert record['engine_incarnation'][:2]==[expected.st_dev,expected.st_ino]
    for stream in ['stdout','stderr']:
        def drain(stream=stream):
            try:
                with (private/(stream+'.raw')).open('xb') as out:
                    for line in getattr(child,stream):
                        out.write(line);out.flush()
                        if line.startswith(b'VR263_'):notify(('marker',line.decode().strip()))
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
                    record.update(participant_deadline_monotonic=supervisor.participant_deadline,auth_deadline_monotonic=supervisor.auth_deadline)
                    if first_ready:
                        assert owned is not None,'XR ready lacks exact mapped incarnation'
                        print(json.dumps({'READY':data,'owned':owned,'private_invocation':str(private/'invocation.json'),'remaining_seconds':supervisor.deadline-time.monotonic(),'finish_hook':'finish newline once to this current client PTY'}),flush=True)
                    elif marker=='VR263_BLOCKER':
                        failure='native admission deadline';print(json.dumps({'BLOCKER':data,'owned':owned,'private_invocation':str(private/'invocation.json')}),flush=True)
                    elif marker in ['VR263_STATE','VR263_STATUS']:
                        print(value,flush=True)
                    elif marker in ['VR263_PREPARED','VR263_FIRST_XR_FRAME']:print(value,flush=True)
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
        if sys.stdin in available:
            line=sys.stdin.readline().strip()
            if supervisor.command(line,time.monotonic()):break
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
    record['eof']={name:not t.is_alive() for name,t in threads};record['completed_monotonic']=time.monotonic();save()
    print(json.dumps({'closed':child is not None and child.poll() is not None,'client_exit':record.get('client_exit'),'eof':record['eof'],'failure':failure,'retirement_failure':record.get('retirement_failure'),'private_invocation':str(private/'invocation.json')}),flush=True)
raise SystemExit(0 if record.get('client_exit')==0 and not failure and not record.get('retirement_failure') and all(record['eof'].values()) and not record['reader_errors'] else 1)
