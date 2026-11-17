"""Existing bounded exported-check protocol for offline real shared GUI owners.

No proxy, canned replies, native XR runtime, desktop focus or hardware query.
Explicit GUI checks drive real Controls. This offline gate performs no domain actions.
"""
import argparse,hashlib,json,os,queue,shutil,subprocess,sys,threading,time
from pathlib import Path
sys.dont_write_bytecode=True
root=Path.cwd();ev=Path(__file__).resolve().parent
sys.path.insert(0,str(ev.parent/'godot-m4-vive-physical-20261029'))
from environment import TASK,environment
from hashes import Digests,raw
p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('--manifest',type=Path,required=True);p.add_argument('--headed',action='store_true');p.add_argument('--phase',choices=['keyboard','keyboard-ray','controller-input','workspace','workspace-render'],default='keyboard');a=p.parse_args()
os.umask(0o077);private=TASK/'private'/a.label;private.mkdir(mode=0o700,exist_ok=False)
out=ev/a.label;out.mkdir(exist_ok=False);drivers=private/'drivers';drivers.mkdir()
sources={}
for src in [Path(__file__).resolve(),ev/'hashes.py',ev.parent/'godot-m4-vive-physical-20261029/environment.py']:
    shutil.copy2(src,drivers/src.name);sources[str(src.relative_to(root))]=raw(src)
m=json.loads(a.manifest.read_text());assert m['passed'] and not m['distributable'] and not m['compiled_application_inputs_copied']
d=Digests();cache=Path(m['digest_cache']['path']);assert raw(cache)==m['digest_cache']['sha256']
for row in json.loads(cache.read_text())['records']:d.values[tuple(row['stat_key'])]=row['sha256']
client=Path(m['export_executable']);dist=client.parent
assert {str(f.relative_to(dist)) for f in dist.rglob('*') if f.is_file()}==set(m['export_outputs'])
for n,row in m['export_outputs'].items():assert d.h(dist/n)==row['sha256'] and (dist/n).stat().st_size==row['bytes']
record={'label':a.label,'qualification_phase':a.phase,'passed':False,'physical':False,'native_runtime_started':False,'hardware_queried':False,'display_or_focus_action':False,
        'manifest':str(a.manifest),'manifest_sha256':raw(a.manifest),'sources':sources,'reader_errors':[],'children':{},'eof':{},'build_export_digest_reused':True}
completion={'keyboard-ray':b'KEYBOARD_PASS','keyboard':b'KEYBOARD_PASS','controller-input':b'M4_CONTROLLER_PASS'}.get(a.phase,b'M4_WORKSPACE_PASS')
events=queue.Queue();processes={};readers=[];ended=set();started=time.monotonic();owned={}
def start(name,command,env):
    record['children'][name]={'command':command}
    child=subprocess.Popen(command,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE);processes[name]=child
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
    images=private/'images';images.mkdir()
    env=environment();env.update(M1B_PHASE=a.phase,M1B_RESULT=str(private/'client-result.raw.json'),GUI_IMAGES=str(images),XDG_DATA_HOME=str(private/'data'),XDG_CONFIG_HOME=str(private/'config'))
    if a.phase.startswith('workspace') or a.phase in ['keyboard','keyboard-ray','controller-input']:
        inputs={'M4_MODEL':root/'priv/explorer/assets/models/bd201855c8114b9b0e9cdd465d6f08413d18604894c839fb78d54d890c2adc94.glb','M4_MAPPING':root/'doc/evidence/godot-m4-20261029/inputs/injected-mapping.term'}
        record['injected_inputs']={k:{'path':str(v),'sha256':d.h(v)} for k,v in inputs.items()}
        env.update({k:str(v) for k,v in inputs.items()});env['M4_PRESENTATION_IMAGES']=str(images)
    command=[str(client),*(['--display-driver','wayland'] if a.headed else ['--headless']),'--audio-driver','Dummy','--xr-mode','off','--rendering-method','gl_compatibility','--rendering-driver','opengl3','--','--qualification','--profile',str(private/'identity')]
    child=start('client',command,env)
    while len([k for k in ended if k[0]=='client'])<2:
        name,kind,line=events.get(timeout=60)
        if line is None:ended.add((name,kind));continue
        if name=='client' and line.startswith((b'PASS ',completion)):print(line.decode(errors='replace').rstrip(),flush=True)
        if name=='client' and line.startswith(completion):record['explicit_completion']=True
    record['children']['client']['true_exit']=child.wait(timeout=10)
except Exception as error:
    record['failure']=type(error).__name__+': '+str(error)
finally:
    for name in ['client']:
        child=processes.get(name)
        if child is None:continue
        if child.poll() is None:
            record['unretired_client_failure']=True;child.terminate()
            try:child.wait(timeout=60)
            except subprocess.TimeoutExpired:record[name+'_cleanup_timeout']=True;child.kill();child.wait(timeout=10)
        record['children'][name]['true_exit']=child.wait(timeout=10)
    for name,kind,thread in readers:thread.join(timeout=5);record['eof'][name+'-'+kind]=not thread.is_alive()
    record['streams']={};record['diagnostics']=[]
    for path in private.glob('*-*.raw'):
        path.chmod(0o600);data=path.read_bytes()
        if path.name.startswith('client-'):
            record['diagnostics'] += [{'stream':path.name,'line':i+1,'sha256':hashlib.sha256(line).hexdigest()} for i,line in enumerate(data.splitlines()) if b'ERROR:' in line or b'leaked' in line.lower()]
        public=b''.join(line if line.startswith((b'PASS ',completion)) else b'<private fixture/client diagnostic>\n' for line in data.splitlines(keepends=True))
        dest=out/(path.stem+'.log');dest.write_bytes(public)
        record['streams'][path.name]={'raw_path':str(path),'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),'public_sha256':hashlib.sha256(public).hexdigest()}
    result=private/'client-result.raw.json'
    if result.exists():
        result.chmod(0o600);value=json.loads(result.read_text());record['client_result_sha256']=raw(result);record['client_report_passed']=value.get('passed')==True
        record['checks']=value['checks'];record['prior_checks']=value.get('prior_checks',[]);record['total_checks']=len(record['checks'])+len(record['prior_checks'])
    record['elapsed_seconds']=time.monotonic()-started
    record['passed']=all(c.get('true_exit')==0 for c in record['children'].values()) and len(record['children'])==1 and all(record['eof'].values()) and not record['reader_errors'] and not record.get('failure') and record.get('explicit_completion')==True and record.get('client_report_passed')==True and not record['diagnostics']
    (out/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps({'passed':record['passed'],'children':{n:c.get('true_exit') for n,c in record['children'].items()},'eof':record['eof'],'failure':record.get('failure'),'checks':len(record.get('checks',[]))}),flush=True)
raise SystemExit(0 if record['passed'] else 1)
