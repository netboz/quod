from pathlib import Path
import os,subprocess,json,time,hashlib,shutil,datetime
root=Path('/home/yan/src/quod');p=Path(__file__).resolve().parent
assert json.loads((root/'_build/quod27-native-precision-build-01/results.json').read_text())[-1]['name']=='release'
assert all(r['exit']==0 for r in json.loads((root/'_build/quod27-native-precision-build-01/results.json').read_text()))
env={k:v for k,v in os.environ.items() if k not in ['LD_LIBRARY_PATH','LD_PRELOAD']};env['ERL_FLAGS']='+S 2:2 +SDcpu 2 +SDio 2';env['PATH']='/home/yan/.asdf/shims:'+env['PATH']
shutil.copy2(root/'_build/quod27-floor-occupancy-repro-01/target/release/libquod_physics.so',p/'binary64/lib/quod/priv/native/quod_physics.so')
results=[]
for label in ['binary32','binary64']:
 app=p/label/'lib/quod';ebin=app/'ebin'
 cmd=['erlc','-o',str(ebin),str(p/'quod_physics_native.erl'),str(p/'quod_physics_bench.erl')]
 r=subprocess.run(cmd,env=env,capture_output=True,text=True);(p/(label+'-compile.log')).write_text(r.stdout+r.stderr);assert r.returncode==0
 cmd=['erl','+S','2:2','+SDcpu','2','+SDio','2','-noshell','-pa',str(ebin),'-eval','true=quod_physics_native:available(), quod_physics_bench:run(), halt().']
 start=datetime.datetime.now(datetime.timezone.utc).isoformat();t=time.monotonic()
 with (p/(label+'.log')).open('x') as out:r=subprocess.run(cmd,env=env,stdout=out,stderr=subprocess.STDOUT)
 row={'label':label,'command':cmd,'started':start,'exit':r.returncode,'seconds':time.monotonic()-t,'nif_sha256':hashlib.sha256((app/'priv/native/quod_physics.so').read_bytes()).hexdigest()};results.append(row);(p/'results.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(row),flush=True)
 if r.returncode:(p/'STOP.json').write_text(json.dumps(row));raise SystemExit(r.returncode)
# Exercise the real NIF error boundary with the new precision, not a mock.
app=p/'binary64/lib/quod';r=subprocess.run(['erlc','-o',str(app/'ebin'),str(root/'test/quod_physics_tests.erl')],env=env,capture_output=True,text=True);(p/'boundary-compile.log').write_text(r.stdout+r.stderr);assert r.returncode==0
cmd=['erl','+S','2:2','+SDcpu','2','+SDio','2','-noshell','-pa',str(app/'ebin'),'-eval','ok=eunit:test([{quod_physics_tests,native_boundary_retires_on_unwind_test},{quod_physics_tests,native_nonfinite_quarantine_retires_world_test}],[verbose]), halt().']
with (p/'boundary.log').open('x') as out:r=subprocess.run(cmd,env=env,stdout=out,stderr=subprocess.STDOUT)
(p/'boundary-exit.json').write_text(json.dumps({'exit':r.returncode,'command':cmd},indent=2)+'\n');print('boundary_exit',r.returncode);raise SystemExit(r.returncode)
