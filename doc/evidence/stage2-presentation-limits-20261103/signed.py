"""Fresh signed software fixture; full child exits, EOF and separate immutable labels."""
import json,os,queue,subprocess,sys,threading,time,hashlib,shutil
from pathlib import Path
root=Path.cwd();ev=Path(__file__).resolve().parent;label=sys.argv[1];build=json.loads((ev/'inputs'/(sys.argv[2]+'-build.json')).read_text());assert build['passed']
private=root/'_build/stage2-presentation-limits'/label;private.mkdir(mode=0o700,exist_ok=False)
os.umask(0o077);events=queue.Queue();children={};threads=[];ended=set();record={'passed':False,'children':{},'reader_errors':[],'hardware':False,'build_label':sys.argv[2]};physics='--physics' in sys.argv[3:];trace='--trace' in sys.argv[3:]
for n in ['signed.py','serve.py',*[Path(n).name for n in build['diagnostic_inputs'] if Path(n).name!='ExportChecks.cs']]:shutil.copy2(ev/n,private/n)
def start(name,args,**kw):
 p=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**kw);children[name]=p;record['children'][name]={'command':args}
 for stream in ['stdout','stderr']:
  def drain(name=name,stream=stream,p=p):
   try:
    with (private/(name+'-'+stream+'.raw')).open('xb') as f:
     for line in getattr(p,stream):f.write(line);f.flush();events.put((name,stream,line))
   except Exception as error:record['reader_errors'].append(str(error))
   finally:events.put((name,stream,None))
  t=threading.Thread(target=drain);t.start();threads.append((name,stream,t))
 return p
def event(deadline):
 n,s,line=events.get(timeout=max(.001,deadline-time.monotonic()))
 if line is None:ended.add((n,s))
 return n,s,line
try:
 stage='/data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source'
 server=start('server',['python3','-B',str(ev/'serve.py'),label,'--stage',stage,'--profile','test','--qualified','--clean-manifest',str(Path(stage).parent/'source-manifest.json'),'--presentation-source','--affected-wire',str(root/'doc/evidence/godot-space-experience-20261101/inputs/space-name-owner03.json')]+(['--physics'] if physics else [])+(['--cursor-diagnostic'] if trace else []));deadline=time.monotonic()+60
 while True:
  n,s,line=event(deadline)
  if line is None:raise RuntimeError('fixture ended before readiness')
  if line.startswith(b'M1B_READY '):ready=json.loads(line[len(b'M1B_READY '):]);break
 ca=private.parent/('server-'+label)/'backend-ca.pem'
 env=dict(os.environ,M1B_PHASE='predicates',M1B_CONTROL_PORT=str(ready['control_port']),M1B_NETWORK=ready['network'],M1B_RESULT=str(private/'result.json'),DOTNET_CLI_HOME=str(private/'dotnet'),HOME=str(private/'home'),XDG_CONFIG_HOME=str(private/'config'),XDG_DATA_HOME=str(private/'data'),XDG_CACHE_HOME=str(private/'cache'))
 if physics:env.update(M3_PHYSICS_META=str(private.parent/('server-'+label)/'physics.json'),M3_PHYSICS_KEY=str(private.parent/('server-'+label)/'viewer.json'),M3_NODE='https://127.0.0.1:'+str(ready['port']),M3_CA=str(ca))
 args=[build['engine'],'--headless','--audio-driver','Dummy','--xr-mode','off','--path',str(Path(build['stage'])/'source/client/godot'),'--','--qualification','--profile',str(private/'profile'),'--node','https://127.0.0.1:'+str(ready['port']),'--ca',str(ca)]
 client=start('client',args,env=env);deadline=time.monotonic()+180
 while len([x for x in ended if x[0]=='client'])<2:
  n,s,line=event(deadline)
  if line is None:continue
  if n=='client' and line.startswith(b'PASS '):print(line.decode().rstrip(),flush=True)
  if n=='client' and line.startswith(b'PREDICATE_PASS '):record['explicit_completion']=True;deadline=min(deadline,time.monotonic()+60)
 record['children']['client']['true_exit']=client.wait(timeout=10);assert client.returncode==0,'client failure'
 value=json.loads((private/'result.json').read_text());assert value['passed'];record['checks']=value['checks'];record['passed']=True
except Exception as error:record['failure']=type(error).__name__+': '+str(error)
finally:
 for n,p in reversed(list(children.items())):
  if p.poll() is None:
   if n=='server':p.stdin.write(b'stop\n');p.stdin.flush();p.stdin.close()
   else:record['unretired_failure']=True;p.terminate()
   try:p.wait(timeout=60)
   except subprocess.TimeoutExpired:record['cleanup_timeout']=True;p.kill();p.wait(timeout=10)
  record['children'][n]['true_exit']=p.returncode
 for n,s,t in threads:t.join(timeout=5)
 record['eof']={n+'-'+s:not t.is_alive() for n,s,t in threads};record['streams']={}
 for p in private.glob('*.raw'):
  data=p.read_bytes();record['streams'][p.name]={'path':str(p),'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)}
  (ev/'logs'/(label+'-'+p.stem+'.log')).write_bytes(b''.join(line if line.startswith((b'PASS ',b'PREDICATE_PASS')) else b'<private fixture/client diagnostic>\n' for line in data.splitlines(keepends=True)))
 record['passed'] &= all(c['true_exit']==0 for c in record['children'].values()) and all(record['eof'].values()) and not record['reader_errors']
 (ev/'inputs'/(label+'.json')).write_text(json.dumps(record,indent=2)+'\n');print(json.dumps({'passed':record['passed'],'failure':record.get('failure'),'children':{n:c['true_exit'] for n,c in record['children'].items()},'eof':record['eof']}))
sys.exit(0 if record['passed'] else 1)
