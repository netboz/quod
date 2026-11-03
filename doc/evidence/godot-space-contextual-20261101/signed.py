"""One fresh signed shared GUI presentation gate through current owners."""
import json,os,queue,shutil,subprocess,sys,threading,time
from pathlib import Path
from hashes import TASK,Digests,raw
from isolation import command
sys.dont_write_bytecode=True;sys.path.append(str(Path.cwd()/'client/godot-tests'))
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;label=sys.argv[1];m=json.loads(Path(sys.argv[2]).read_text());server_stage=Path(sys.argv[3]);assert m['passed'] and not m['distributable']
private=TASK/'private'/label;private.mkdir(mode=0o700,exist_ok=False);events=queue.Queue();processes={};threads=[];ended=set();record={'passed':False,'children':{},'reader_errors':[],'native_inputs':[],'host_input_or_focus_action':False,'software_native_Control_inputs':True,'setup_Control_signals':True,'no_headset_or_runtime':True,'companion_not_distributed':True,'production_auth_lifetime_unchanged':True,'manifest_sha256':raw(Path(sys.argv[2]))}
d=Digests();cache=Path(m['digest_cache']['path']);assert raw(cache)==m['digest_cache']['sha256']
for r in json.loads(cache.read_text())['records']:d.values[tuple(r['stat_key'])]=r['sha256']
dist=Path(m['export_executable']).parent;assert all(d.h(dist/n)==r['sha256'] for n,r in m['export_outputs'].items())
drivers=private/'drivers';drivers.mkdir()
for p in [Path(__file__).resolve(),ev/'isolation.py',ev/'serve.py',ev/'hashes.py']:shutil.copy2(p,drivers/p.name)
def start(name,args,**kw):
    child=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**kw);processes[name]=child;record['children'][name]={'command':args}
    for stream in ['stdout','stderr']:
        def drain(name=name,stream=stream,child=child):
            try:
                with (private/(name+'-'+stream+'.raw')).open('xb') as f:
                    for line in getattr(child,stream):f.write(line);f.flush();events.put((name,stream,line))
            except Exception as error:record['reader_errors'].append(type(error).__name__)
            finally:events.put((name,stream,None))
        t=threading.Thread(target=drain);t.start();threads.append((name,stream,t))
    return child
def event(deadline):
    name,stream,line=events.get(timeout=max(.001,deadline-time.monotonic()))
    if line is None:ended.add((name,stream))
    return name,stream,line
def identity(pid):
    p=Path('/proc')/str(pid);s=(p/'exe').stat();f=(p/'stat').read_text().rsplit(')',1)[1].split();return [s.st_dev,s.st_ino,int(f[19])]
try:
    server_label=label+'-server';server=start('server',['python3','-B',str(ev/'serve.py'),server_label,'--stage',str(server_stage),'--profile','test','--qualified','--clean-manifest',str(server_stage.parent/'source-manifest.json')]);deadline=time.monotonic()+60
    while True:
        name,stream,line=event(deadline)
        if line is None:raise RuntimeError('fixture ended before actual readiness')
        if name=='server' and line.startswith(b'M1B_READY '):ready=json.loads(line[len(b'M1B_READY '):]);break
    sandbox=private/'sandbox';sandbox.mkdir();ca=TASK/'private'/('quod-m4-live-'+server_label)/'backend-ca.pem'
    requested=sys.argv[4] if len(sys.argv)>4 else 'contextual'
    for phase in [requested]:
        name='client-'+phase;info=private/(name+'-bwrap.json')
        with info.open('xb') as status:
            args=command(dist,sandbox,['--display-driver','wayland','--audio-driver','Dummy','--xr-mode','off','--','--qualification','--profile','/home/test/profile','--node','https://127.0.0.1:'+str(ready['port']),'--ca','/fixture/ca.pem'],wayland=True,network=True)
            at=args.index('--');args[at:at]=['--info-fd',str(status.fileno()),'--ro-bind',str(ca),'/fixture/ca.pem','--setenv','M1B_CONTROL_PORT',str(ready['control_port']),'--setenv','M1B_PHASE',phase,'--setenv','M1B_NETWORK',ready['network'],'--setenv','M1B_RESULT','/work/'+phase+'.json'];args[args.index('/opt/Quod app/quod')]='/opt/Quod app/quod.x86_64'
            client=start(name,args,pass_fds=(status.fileno(),));deadline=time.monotonic()+180;owner=None
            while len([x for x in ended if x[0]==name])<2:
                who,stream,line=event(deadline)
                if line is None:continue
                if who!=name:continue
                text=line.decode(errors='replace').strip()
                if text.startswith('M2_NATIVE_'):raise RuntimeError('host input is outside this software qualification')
                if owner is None and text.startswith(('PASS ', 'CONTEXTUAL_PASS')):
                    if owner is None:
                        pid=json.loads(info.read_text())['child-pid'];owner=identity(pid);expected=(dist/'quod.x86_64').stat();assert owner[:2]==[expected.st_dev,expected.st_ino];record['children'][name]['owner_incarnation']=owner
                    assert identity(pid)==owner
                if text.startswith('PASS '):print(text,flush=True)
                if text.startswith('CONTEXTUAL_PASS'):record['children'][name]['explicit_completion']=True
                if text.startswith('CONTEXTUAL_PASS'):
                    record['children'][name]['completion_monotonic']=time.monotonic()
                    deadline=min(deadline,time.monotonic()+60)
            record['children'][name]['true_exit']=client.wait(timeout=10);assert client.returncode==0
            value=json.loads((sandbox/'work'/(phase+'.json')).read_text());assert value['passed'];record['children'][name]['checks']=value['checks']
    record['passed']=True
except Exception as error:
    record['failure']=type(error).__name__+': '+str(error)

finally:
    for name,child in reversed(list(processes.items())):
        if child.poll() is None:
            if name=='server':child.stdin.write(b'stop\n');child.stdin.flush();child.stdin.close()
            else:
                record['unretired_failure']=True;child.terminate()
            try:child.wait(timeout=60)
            except subprocess.TimeoutExpired:record['cleanup_timeout']=True;child.kill();child.wait(timeout=10)
        record['children'][name]['true_exit']=child.returncode
    for name,stream,t in threads:t.join(timeout=5)
    record['eof']={name+'-'+stream:not t.is_alive() for name,stream,t in threads};record['streams']={}
    for p in private.glob('*.raw'):
        p.chmod(0o600);data=p.read_bytes();record['streams'][p.name]={'path':str(p),'sha256':raw(p),'bytes':len(data)}
        public=b''.join(line if line.startswith((b'PASS ',b'CONTEXTUAL_PASS')) else b'<private fixture/client diagnostic>\n' for line in data.splitlines(keepends=True));(ev/'logs'/(label+'-'+p.stem+'.log')).write_bytes(public)
    record['passed'] &= all(c['true_exit']==0 for c in record['children'].values()) and all(record['eof'].values()) and not record['reader_errors']
    record['native_input_count']=len(record['native_inputs']);(private/'result.raw.json').write_text(json.dumps(record,indent=2)+'\n')
    public={k:v for k,v in record.items() if k not in ['native_inputs','children']};public['children']={n:{k:v for k,v in c.items() if k not in ['command','owner_incarnation']} for n,c in record['children'].items()}
    (ev/'inputs'/(label+'.json')).write_text(json.dumps(public,indent=2)+'\n');print(json.dumps({'passed':record['passed'],'failure':record.get('failure'),'children':{n:c['true_exit'] for n,c in record['children'].items()},'native_inputs':record['native_input_count']}))
raise SystemExit(0 if record['passed'] else 1)
