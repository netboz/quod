"""Existing exported-check protocol with one fresh real production fixture.

No proxy, canned replies, native XR runtime, desktop focus or hardware query.
Only explicit Stage2 C# qualification phases issue software Control gestures and signed fixture input.
"""
import argparse,ctypes,hashlib,json,os,queue,shutil,subprocess,sys,threading,time
from pathlib import Path
sys.dont_write_bytecode=True
root=Path.cwd();ev=Path(__file__).resolve().parent
sys.path.insert(0,str(ev.parent/'godot-m4-vive-physical-20261029'))
from environment import TASK,environment
from hashes import Digests,raw
p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('--manifest',type=Path,required=True);p.add_argument('--headed',action='store_true');p.add_argument('--physics',action='store_true');p.add_argument('--cursor-diagnostic',action='store_true');p.add_argument('--wire-qualification',type=Path);p.add_argument('--phase',choices=['workbench','scene'],default='workbench');p.add_argument('--shutdown-trace',action='store_true');a=p.parse_args()
os.umask(0o077);private=TASK/'private'/a.label;private.mkdir(mode=0o700,exist_ok=False)
out=ev/a.label;out.mkdir(exist_ok=False);drivers=private/'drivers';drivers.mkdir()
sources={}
for src in [Path(__file__).resolve(),ev/'hashes.py',ev.parent/'godot-m4-vive-physical-20261029/environment.py',ev/'serve.py']:
    shutil.copy2(src,drivers/src.name);sources[str(src.relative_to(root))]=raw(src)
m=json.loads(a.manifest.read_text());assert m['passed'] and not m['distributable'] and not m['compiled_application_inputs_copied']
d=Digests();cache=Path(m['digest_cache']['path']);assert raw(cache)==m['digest_cache']['sha256']
for row in json.loads(cache.read_text())['records']:d.values[tuple(row['stat_key'])]=row['sha256']
client=Path(m['export_executable']);dist=client.parent
assert {str(f.relative_to(dist)) for f in dist.rglob('*') if f.is_file()}==set(m['export_outputs'])
for n,row in m['export_outputs'].items():assert d.h(dist/n)==row['sha256'] and (dist/n).stat().st_size==row['bytes']
record={'diagnostic_question':'At the original post-completion no-EOF trigger, is the exact owned client still alive or only a pipe/reader waiting?', 'lifecycle':[], 'label':a.label,'qualification_phase':a.phase,'passed':False,'physical':False,'native_runtime_started':False,'hardware_queried':False,'display_or_focus_action':False,
        'manifest':str(a.manifest),'manifest_sha256':raw(a.manifest),'sources':sources,'reader_errors':[],'children':{},'eof':{},'build_export_digest_reused':True}
events=queue.Queue();processes={};readers=[];ended=set();started=time.monotonic();owned={}
def observed(kind,**fields):record['lifecycle'].append({'kind':kind,'utc':time.time(),'monotonic':time.monotonic(),**fields})
def starttime(pid):return Path('/proc/'+str(pid)+'/stat').read_text().rpartition(')')[2].split()[19]
def allow_owned_trace():
    # Reuse the existing local.py watchdog permission: this parent and its
    # descendants may inspect only their explicitly owned child.
    if ctypes.CDLL(None).prctl(0x59616d61,os.getppid(),0,0,0)!=0:os._exit(125)
def start(name,command,env):
    record['children'][name]={'command':command}
    options={'preexec_fn':allow_owned_trace} if a.shutdown_trace and name=='client' else {}
    child=subprocess.Popen(command,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**options);processes[name]=child
    if options:
        s=Path(command[0]).stat();owned.update(pid=child.pid,starttime=starttime(child.pid),device=s.st_dev,inode=s.st_ino)
    for kind in ['stdout','stderr']:
        def drain(kind=kind,name=name,child=child):
            try:
                with (private/(name+'-'+kind+'.raw')).open('xb') as stream:
                    for line in getattr(child,kind):stream.write(line);stream.flush();events.put((name,kind,line))
            except Exception as error:record['reader_errors'].append({'child':name,'stream':kind,'error':type(error).__name__})
            finally:events.put((name,kind,None))
        thread=threading.Thread(target=drain);readers.append((name,kind,thread));thread.start()
    return child
try:
    server_label=a.label+'-server'
    command=['python3','-B',str(ev/'serve.py'),server_label,'--stage',str(TASK/'artifacts/server-runtime-restoration05'),'--profile','prod']
    if a.cursor_diagnostic:command.append('--cursor-diagnostic')
    if a.wire_qualification:command+=['--affected-wire',str(a.wire_qualification)]
    if a.physics:command.append('--physics')
    server=start('server',command,environment());deadline=time.monotonic()+60
    while True:
        name,kind,line=events.get(timeout=max(.001,deadline-time.monotonic()))
        if line is None:ended.add((name,kind));raise RuntimeError('fixture EOF before its readiness notification')
        if name=='server' and line.startswith(b'M1B_READY '):ready=json.loads(line[len(b'M1B_READY '):]);break
    record['fixture_ready']=True
    env=environment();env.update(M1B_PHASE=a.phase,M1B_NETWORK=ready['network'],M1B_RESULT=str(private/'client-result.raw.json'),
        M1B_CONTROL_PORT=str(ready['control_port']),M4_MORNING_IMAGES=str(private/'images'),XDG_DATA_HOME=str(private/'data'),XDG_CONFIG_HOME=str(private/'config'),DOTNET_ROOT=str(private/'no-installed-runtime'))
    if a.physics:
        server_private=TASK/'private'/('quod-m4-live-'+server_label)
        env.update(M1B_PHASE='stage2-contents',M3_PHYSICS_META=str(server_private/'physics.json'),M3_PHYSICS_KEY=str(server_private/'viewer.json'),M3_NODE='https://127.0.0.1:'+str(ready['port']),M3_CA=str(server_private/'backend-ca.pem'))
    command=[str(client),*(['--display-driver','wayland'] if a.headed else ['--headless']),'--audio-driver','Dummy','--xr-mode','off','--rendering-method','mobile','--rendering-driver','vulkan','--','--qualification','--profile',str(private/'identity'),'--node','https://127.0.0.1:'+str(ready['port']),'--ca',str(TASK/'private'/('quod-m4-live-'+server_label)/'backend-ca.pem')]
    child=start('client',command,env);restart=False
    completion=b'WORKBENCH_PASS' if a.phase=='workbench' else b'M2_SCENE_PASS'
    while len([k for k in ended if k[0]=='client'])<2:
        name,kind,line=events.get(timeout=60)
        if line is None:observed('pipe_eof',child=name,stream=kind);ended.add((name,kind));continue
        if name=='client' and line.startswith((b'PASS ',completion)):print(line.decode(errors='replace').rstrip(),flush=True)
        if name=='client' and line.startswith(completion):observed('explicit_completion');record['explicit_completion']=True
        if name=='client' and line.startswith(b'STAGE2_RESTART'):restart=True
    record['children']['client']['true_exit']=child.wait(timeout=10)
    if restart:
        assert child.returncode==0 and not a.physics
        # One explicitly declared lifecycle continuation, never a failed-run
        # retry or write resubmission. The server and original request stay put.
        context=private/'client-result.raw.json.recovery.json';assert context.is_file()
        command=list(command);command[command.index('--profile')+1]=str(private/'identity/source-account-recovery')
        env=env.copy();env.update(M1B_PHASE='stage2-recover',M1B_RECOVERY_META=str(context))
        child=start('client-reconnect',command,env)
        while len([k for k in ended if k[0]=='client-reconnect'])<2:
            name,kind,line=events.get(timeout=60)
            if line is None:observed('pipe_eof',child=name,stream=kind);ended.add((name,kind));continue
            if name=='client-reconnect' and line.startswith((b'PASS ',b'WORKBENCH_PASS')):print(line.decode(errors='replace').rstrip(),flush=True)
            if name=='client-reconnect' and line.startswith(b'WORKBENCH_PASS'):record['explicit_completion']=True
        record['children']['client-reconnect']['true_exit']=child.wait(timeout=10)
        record['ordinary_account_reconnect_executed']=True
except Exception as error:
    record['failure']=type(error).__name__+': '+str(error)
    c=processes.get('client');observed('original_wait_failure',child_returncode=None if c is None else c.poll(),client_eof_streams=sorted(k[1] for k in ended if k[0]=='client'))
    if a.shutdown_trace and isinstance(error,queue.Empty) and record.get('explicit_completion') and processes.get('client') is not None:
        diagnostic={'original60s_no_progress_trigger':True,'inspected':False}
        try:
            child=processes['client'];assert child.poll() is None and starttime(child.pid)==owned['starttime']
            s=Path('/proc/'+str(child.pid)+'/exe').stat();assert (s.st_dev,s.st_ino)==(owned['device'],owned['inode'])
            observed('owned_client_alive_at_original_trigger',thread_count=len(list((Path('/proc')/str(child.pid)/'task').iterdir())),kernel_wait_channel=(Path('/proc')/str(child.pid)/'wchan').read_text().strip())
            guard=private/'shutdown-owner.json';guard.write_text(json.dumps(owned,indent=2)+'\n')
            command=['gdb','-nx','-nh','-q','-batch','-p',str(child.pid),'-ex','set print frame-arguments none','-ex','set print entry-values no','-ex','thread apply all bt 16']
            probe_input=private/'shutdown-probe.json';probe_input.write_text(json.dumps({'command':command,'owner_binding_sha256':raw(guard),'timeout_seconds':15},indent=2)+'\n')
            with (private/'shutdown-stacks.raw').open('xb') as log:
                probe=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,env={**environment(),'DEBUGINFOD_URLS':''})
                try:probe_exit=probe.wait(timeout=15)
                except subprocess.TimeoutExpired:diagnostic['trace_timeout']=True;probe.kill();probe_exit=probe.wait(timeout=5)
            diagnostic.update(attempted=True,inspected=probe_exit==0,true_exit=probe_exit,owner_binding_sha256=raw(guard),invocation_sha256=raw(probe_input))
        except Exception as probe_error:diagnostic['error_type']=type(probe_error).__name__
        record['shutdown_diagnostic']=diagnostic
finally:
    for name in ['client-reconnect','client','server']:
        child=processes.get(name)
        if child is None:continue
        if child.poll() is None:
            if name=='server':child.stdin.write(b'stop\n');child.stdin.flush();child.stdin.close()
            else:record['unretired_client_failure']=True;child.terminate()
            try:child.wait(timeout=30 if name=='server' else 60)
            except subprocess.TimeoutExpired:record[name+'_cleanup_timeout']=True;child.kill();child.wait(timeout=10)
        record['children'][name]['true_exit']=child.wait(timeout=10);observed('child_exit',child=name,true_exit=child.returncode)
    for name,kind,thread in readers:thread.join(timeout=5);record['eof'][name+'-'+kind]=not thread.is_alive()
    record['streams']={};record['diagnostics']=[]
    for path in private.glob('*-*.raw'):
        path.chmod(0o600);data=path.read_bytes()
        if path.name.startswith('client-'):
            record['diagnostics'] += [{'stream':path.name,'line':i+1,'sha256':hashlib.sha256(line).hexdigest()} for i,line in enumerate(data.splitlines()) if b'ERROR:' in line or b'leaked' in line.lower()]
        public=b''.join(line if line.startswith((b'PASS ',b'WORKBENCH_PASS',b'M2_SCENE_PASS')) else b'<private fixture/client diagnostic>\n' for line in data.splitlines(keepends=True))
        dest=out/(path.stem+'.log');dest.write_bytes(public)
        record['streams'][path.name]={'raw_path':str(path),'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),'public_sha256':hashlib.sha256(public).hexdigest()}
    result=private/'client-result.raw.json'
    if result.exists():
        result.chmod(0o600);value=json.loads(result.read_text());record['client_result_sha256']=raw(result);record['client_report_passed']=value.get('passed')==True
        record['checks']=value['checks'];record['prior_checks']=value.get('prior_checks',[]);record['total_checks']=len(record['checks'])+len(record['prior_checks'])
    record['elapsed_seconds']=time.monotonic()-started
    record['passed']=all(c.get('true_exit')==0 for c in record['children'].values()) and len(record['children'])==(3 if record.get('ordinary_account_reconnect_executed') else 2) and all(record['eof'].values()) and not record['reader_errors'] and not record.get('failure') and record.get('explicit_completion')==True and record.get('client_report_passed')==True and not record['diagnostics']
    (out/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps({'passed':record['passed'],'children':{n:c.get('true_exit') for n,c in record['children'].items()},'eof':record['eof'],'failure':record.get('failure'),'checks':len(record.get('checks',[]))}),flush=True)
raise SystemExit(0 if record['passed'] else 1)
