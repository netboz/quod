from pathlib import Path
import json,os,re,shutil,subprocess,sys,time

out=Path(__file__).resolve().parent
root=Path('/home/yan/src/quod')
assert json.loads((out/'execution/FLEET-PASSED.json').read_text())['passed']
label=sys.argv[1]
assert re.fullmatch(r'desktop-deployed-[0-9]+',label)
assert not (out/'DEPLOYED.json').exists()
state=out/('acceptance-'+label);state.mkdir(exist_ok=False)
shutil.copy2(__file__,state/'runner.py')
environment=dict(os.environ)
for key in ['DEBUG','LD_LIBRARY_PATH','LD_PRELOAD']:environment.pop(key,None)
environment['PATH']='/home/yan/.asdf/shims:/home/yan/.cargo/bin:'+environment['PATH']

def run(label,args):
    with (state/(label+'.intent.json')).open('x') as f:json.dump({'command':args},f,indent=2)
    print('Starting '+label,flush=True);start=time.monotonic()
    with (state/(label+'.log')).open('x') as log:
        r=subprocess.run(args,cwd=root,env=environment,stdout=log,stderr=subprocess.STDOUT)
    row={'exit':r.returncode,'seconds':time.monotonic()-start,'command':args}
    (state/(label+'.exit.json')).write_text(json.dumps(row,indent=2)+'\n')
    print(json.dumps(row),flush=True)
    if r.returncode:
        (state/'STOP.json').write_text(json.dumps(row,indent=2)+'\n');raise SystemExit(r.returncode)

run('desktop',['node','doc/evidence/world-library-20261016/desktop-acceptance.mjs',
    label,'https://192.168.1.10:30519/','none',
    str(root/'_build/world-library-20261016/clean-integration-07/tree'),
    json.loads((out/'refound/root-info.json').read_text())['root_anchor']])
run('fleet-after-desktop',[sys.executable,str(out/'fleet_probe.py'),'fleet-probe-after-desktop'])
run('purge-old-volumes',[sys.executable,str(out/'purge_old_volumes.py'),label])
record={'passed':True,'version':'0.7.273','url':'https://192.168.1.10:30519/',
    'source_committed':False,'desktop':'../'+label+'/PASSED.json',
    'fleet':'refound/fleet-probe-after-desktop.json','old_volumes':'refound/old-volumes-deleted.json',
    'image':json.loads((out/'verified-image.json').read_text())['pinned_image']}
(out/'DEPLOYED.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record),flush=True)
