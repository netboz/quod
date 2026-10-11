from pathlib import Path
import os,subprocess,json,time
p=Path(__file__).resolve().parent
commands=[('physics',['/usr/bin/rebar3','eunit','--module=quod_physics_tests,quod_physics_control_tests,quod_foreign_lifecycle_tests'],'.')]
env=dict(os.environ);env.pop('LD_LIBRARY_PATH',None);env.pop('LD_PRELOAD',None);env['ERL_FLAGS']='+S 4:4 +SDcpu 2 +SDio 2'
for name,args,cwd in commands:
 start=time.time()
 with (p/(name+'.log')).open('xb') as log:
  result=subprocess.run(args,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT)
 receipt={'command':args,'directory':cwd,'exit_code':result.returncode,'elapsed_seconds':time.time()-start}
 (p/(name+'-exit.json')).write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt),flush=True)
 if result.returncode:
  (p/'STOP.json').write_text(json.dumps(receipt,indent=2)+'\n');raise SystemExit(result.returncode)
