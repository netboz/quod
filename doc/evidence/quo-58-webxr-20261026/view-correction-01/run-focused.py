import json,os,subprocess,time
from pathlib import Path
root=Path('/home/yan/src/quod');out=Path(__file__).resolve().parent/'focused-01';out.mkdir()
env=dict(os.environ,PATH='/home/yan/.asdf/shims:/home/yan/.cargo/bin:'+os.environ['PATH'],ERL_FLAGS='+S 4:4 +SDio 2 +SDcpu 2',CARGO_NET_OFFLINE='true')
for key in ['LD_LIBRARY_PATH','LD_PRELOAD','DEBUG']:env.pop(key,None)
commands=[('navigation',['node','client/test/controlled-navigation.test.js']),('client',['npm','--prefix','client','test']),('native',['cargo','test','--locked','--manifest-path','native/quod_physics/Cargo.toml']),('physics',['rebar3','as','test','eunit','--module=quod_physics_tests,quod_physics_control_tests','--verbose'])]
for name,command in commands:
 start=time.monotonic()
 with (out/(name+'.log')).open('xb') as log:child=subprocess.run(command,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT)
 result={'command':command,'exit':child.returncode,'seconds':time.monotonic()-start}
 with (out/(name+'.exit.json')).open('x') as f:json.dump(result,f,indent=2)
 print(name,json.dumps(result),flush=True)
 if child.returncode:raise SystemExit(child.returncode)
