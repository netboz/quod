"""One exact headed export, with separate streams and existing bounded close observation."""
import argparse,ctypes,hashlib,json,os,queue,shutil,subprocess,sys,threading
from pathlib import Path
sys.dont_write_bytecode=True
root=Path.cwd();ev=Path(__file__).resolve().parent
sys.path.append(str(ev.parent/'godot-m4-vive-physical-20261029'))
from environment import TASK,environment
from hashes import Digests,raw
p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('--manifest',type=Path,required=True);p.add_argument('--phase',choices=['presentation','controller-input','scene','menu','workspace','workspace-render'],required=True);a=p.parse_args()
os.umask(0o077);out=ev/a.label;out.mkdir(exist_ok=False);private=TASK/'private'/a.label;private.mkdir(parents=True,mode=0o700,exist_ok=False)
drivers=private/'drivers';drivers.mkdir();copies={}
for source in [Path(__file__).resolve(),ev/'hashes.py',root/'doc/evidence/godot-m4-presentation-20261030/digests.py',root/'client/godot-tests/desktop_input.py']:
    shutil.copy2(source,drivers/source.name);copies[source.name]=raw(source)
sys.path.insert(0,str(drivers));from desktop_input import deliver
manifest=json.loads(a.manifest.read_text());assert manifest['passed'] and not manifest['compiled_application_inputs_copied']
assert (set(manifest['diagnostic_overrides'])=={'client/godot/tests/ExportChecks.cs','client/godot/tests/WorkspaceChecks.cs'} and not manifest['distributable']) or (not manifest['diagnostic_overrides'] and manifest.get('compiled_from_actual_current_source'))
dist=Path(manifest['export_executable']).parent;cache=manifest['digest_cache'];assert raw(cache['path'])==cache['sha256']
digests=Digests()
for row in json.loads(Path(cache['path']).read_text())['records']:digests.values[tuple(row['stat_key'])]=row['sha256']
files={str(f.relative_to(dist)):f for f in dist.rglob('*') if f.is_file()};assert set(files)==set(manifest['export_outputs'])
for name,item in manifest['export_outputs'].items():assert files[name].stat().st_size==item['bytes'] and digests.h(files[name])==item['sha256']
command=[manifest['export_executable'],*(['--headless'] if a.phase=='workspace' else ['--display-driver','wayland']),'--audio-driver','Dummy','--xr-mode','off','--rendering-method','mobile','--rendering-driver','vulkan','--','--qualification','--profile',str(private/'identity')]
env=environment();env.update(M1B_PHASE=a.phase,M1B_RESULT=str(out/'client-result.json'),M4_PRESENTATION_IMAGES=str(private/'images'),M4_MODEL=str(root/'priv/explorer/assets/models/bd201855c8114b9b0e9cdd465d6f08413d18604894c839fb78d54d890c2adc94.glb'),M4_MAPPING=str(root/'doc/evidence/godot-m4-20261029/inputs/injected-mapping.term'),M2_SCENE_CAPTURE=str(private/'wireframe.png'))
for key,name in [('XDG_DATA_HOME','data'),('XDG_CONFIG_HOME','config')]:env[key]=str(private/name)
record={'command':command,'manifest':str(a.manifest),'manifest_sha256':raw(a.manifest),'actual_exports_admitted':len(files),'stat_bound_digest_hits':digests.hits,'driver_hashes':copies,'native_input':[],'watchdog_seconds':60,'physical_acceptance':False,'passed':False,'reader_errors':[]};lines=queue.Queue();threads=[];text='';timer=None
def allow_owned_trace():
    if ctypes.CDLL(None).prctl(0x59616d61,os.getppid(),0,0,0)!=0:os._exit(125)
child=subprocess.Popen(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,preexec_fn=allow_owned_trace)
def receive(kind):
    try:
        with (private/(kind+'.raw')).open('xb') as log:
            for line in getattr(child,kind):log.write(line);log.flush();lines.put((kind,line.decode(errors='replace')))
    except Exception as error:record['reader_errors'].append({'stream':kind,'error':type(error).__name__})
    finally:lines.put((kind,None))
for kind in ['stdout','stderr']:
    thread=threading.Thread(target=receive,args=(kind,));threads.append((kind,thread));thread.start()
def capture():
    if child.poll() is not None:return
    path=private/'native-stacks.raw';command=['gdb','-q','-nx','-batch','-iex','set auto-load off','-p',str(child.pid),'-ex','set print frame-arguments none','-ex','set print entry-values no','-ex','thread apply all bt 20','-ex','detach']
    detail={'command':command,'owned_pid':child.pid,'bound_seconds':15,'arguments':False,'memory_dump':False}
    try:
        with path.open('x') as stream:os.chmod(path,0o600);detail['exit']=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,timeout=15).returncode
    except Exception as error:detail['error']=type(error).__name__
    record['capture']=detail
ended=set()
try:
    while len(ended)<2:
        kind,line=lines.get(timeout=60)
        if line is None:ended.add(kind);continue
        text+=line;print(line,end='',flush=True);deliver(line,child.pid,True,record['native_input'])
        if line.startswith(('M4_PRESENTATION_OBSERVED','M4_CONTROLLER_PASS','M2_SCENE_PASS','M4_WORKSPACE_OBSERVED')) and timer is None:timer=threading.Timer(20,capture);timer.start()
    child.wait(timeout=10)
except Exception as error:record['failure']=type(error).__name__+': '+str(error)
finally:
    if timer is not None:timer.cancel();timer.join(timeout=16)
    if child.poll() is None:child.kill()
    record['client_exit']=child.wait(timeout=10);record['eof']={}
    for kind,thread in threads:thread.join(timeout=5);record['eof'][kind]=kind in ended and not thread.is_alive()
    for kind in ['stdout','stderr']:
        path=private/(kind+'.raw');os.chmod(path,0o600);data=path.read_bytes();(out/(kind+'.log')).write_bytes(data)
    for image in (private/'images').glob('*.png') if (private/'images').exists() else []:shutil.copy2(image,out/image.name)
    if (private/'wireframe.png').exists():shutil.copy2(private/'wireframe.png',out/'wireframe.png')
    marker={'presentation':'M4_PRESENTATION_PASS','controller-input':'M4_CONTROLLER_PASS','scene':'M2_SCENE_PASS','menu':'M2_MENU_PASS','workspace':'M4_WORKSPACE_PASS','workspace-render':'M4_WORKSPACE_PASS'}[a.phase]
    record['completion_marker']=marker in text;record['observation_marker']='M4_PRESENTATION_OBSERVED' in text
    record['passed']=record['client_exit']==0 and all(record['eof'].values()) and not record['reader_errors'] and record['completion_marker'] and (a.phase=='menu' or (out/'client-result.json').exists()) and 'ERROR:' not in text
    (out/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record),flush=True)
raise SystemExit(0 if record['passed'] else 1)
