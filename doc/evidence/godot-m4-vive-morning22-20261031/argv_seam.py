"""Exercise the exact launcher exec expression through the unchanged wrapper."""
import ast,hashlib,json,os,shutil,subprocess,sys,time
from pathlib import Path
from types import SimpleNamespace
os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent;task=Path('/data/quod-m4-vr-ca84d4f8-20261029')
launch=root/'doc/evidence/godot-m4-morning-journey-20261031/launch.py'
wrapper=root/'doc/evidence/godot-m4-vive-physical-20261029/manual_run.py'
private=task/'private/morning-launch-argv01';private.mkdir(mode=0o700,exist_ok=False)
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
assert digest(wrapper)=='2620ffe864b19135f1557e19280cec34fe18c19ac51f940379573da56b0e9639'
inputs={}
for p in [launch,wrapper,ev/'argv_child.py',Path(__file__)]:
    q=private/p.name;shutil.copy2(p,q);assert digest(p)==digest(q)
    inputs[str(p)]={'copy':str(q),'sha256':digest(q),'full_mode':q.stat().st_mode}
calls=[n for n in ast.walk(ast.parse(launch.read_text())) if isinstance(n,ast.Call) and isinstance(n.func,ast.Attribute) and isinstance(n.func.value,ast.Name) and n.func.value.id=='os' and n.func.attr=='execv']
assert len(calls)==1
captured=[]
context={'os':SimpleNamespace(execv=lambda executable,argv:captured.append((executable,argv))),
         'sys':sys,'wrapper':wrapper,'physical':private/'argv_child.py',
         'a':SimpleNamespace(label='morning-launch-argv01'),'v':{'manifest':'fixture-manifest'}}
eval(compile(ast.Expression(calls[0]),str(launch),'eval'),context)
executable,command=captured[0]
assert executable==sys.executable and command[:4]==[sys.executable,'-B',str(wrapper),'morning-launch-argv01-run']
assert '--timeout' not in command and '2100' not in command
started=time.monotonic();r=subprocess.run(command,cwd=root,capture_output=True,timeout=15)
for kind,data in [('stdout',r.stdout),('stderr',r.stderr)]:
    p=private/(kind+'.raw');p.write_bytes(data);p.chmod(0o600)
record=json.loads((wrapper.parent/'logs/morning-launch-argv01-run.json').read_text())
passed=r.returncode==0 and record['child_exit']==0 and all(record['eof'].values()) and not record['reader_errors'] and b'LAUNCH_ARGV_CHILD_PASS' in r.stdout
result={'passed':passed,'actual_wrapper_exit':r.returncode,'actual_child_exit':record['child_exit'],
        'eof':record['eof'],'reader_errors':record['reader_errors'],'elapsed_seconds':time.monotonic()-started,
        'source_inputs':inputs,'command':command,'launcher_expression_executed':True,
        'original_wrapper_watchdog_seconds':record['bound_seconds'],'hardware_runtime_fixture_or_application_started':False,
        'streams':{kind:{'path':str(private/(kind+'.raw')),'sha256':digest(private/(kind+'.raw')),'bytes':(private/(kind+'.raw')).stat().st_size} for kind in ['stdout','stderr']}}
(ev/'argv-seam-result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'passed':passed,'wrapper_exit':r.returncode,'child_exit':record['child_exit'],'eof':record['eof'],'watchdog_seconds':record['bound_seconds']}))
raise SystemExit(0 if passed else 1)
