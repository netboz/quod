from pathlib import Path
import hashlib, json, os, subprocess, sys, time

out = Path(__file__).resolve().parent
state = out/'execution'
state.mkdir(exist_ok=False)
environment = dict(os.environ)
for key in ['DEBUG','LD_LIBRARY_PATH','LD_PRELOAD']: environment.pop(key,None)
environment['PATH'] = '/home/yan/.asdf/shims:/home/yan/.cargo/bin:'+environment['PATH']

def run(label,args):
    with (state/(label+'.intent.json')).open('x') as f:
        json.dump({'command':args},f,indent=2)
    print('Starting '+label,flush=True)
    started=time.monotonic()
    with (state/(label+'.log')).open('x') as log:
        result=subprocess.run(args,stdout=log,stderr=subprocess.STDOUT,env=environment)
    row={'label':label,'command':args,'exit':result.returncode,'seconds':time.monotonic()-started}
    (state/(label+'.exit.json')).write_text(json.dumps(row,indent=2)+'\n')
    print(json.dumps(row),flush=True)
    if result.returncode:
        (state/'STOP.json').write_text(json.dumps(row,indent=2)+'\n')
        raise SystemExit(result.returncode)

def script(label): run(label,[sys.executable,str(out/(label+'.py'))])

refound=out/'refound'
run('compile-system-operator',['erlc','-Werror','-o',str(refound),str(refound/'quod_fresh_systems.erl')])
root = out.parents[2]
evidence = root/'doc/evidence/world-library-20261016'
gate = evidence/'clean-integration-07'
tree = out.parent/'clean-integration-07/tree'
passed = json.loads((gate/'PASSED.json').read_text())
assert passed['passed'] and len(passed['results']) == 12
assert all(r['exit'] == 0 and r['sources_unchanged'] for r in passed['results'])
assessment = json.loads((evidence/'review-07/assessment.json').read_text())
assert assessment['confirmed_defects_remaining'] == 0 and assessment['production_identical_to_review']
assert assessment['tree'] == str(tree)
manifest = json.loads((gate/'source-manifest.json').read_text())
assert all(hashlib.sha256((tree/n).read_bytes()).hexdigest() == h for n,h in manifest.items())
verified = json.loads((out/'verified-image.json').read_text())
assert verified == json.loads((out.parent/'deployment-01/verified-image.json').read_text())
assert hashlib.sha256((out.parent/'deployment-01/image-source-manifest.json').read_bytes()).hexdigest() == verified['source_manifest_sha256']
assert verified['pinned_image'] == '192.168.1.11:5000/quod:0.7.273@sha256:4fa80d816a4d7583b988d63b6ff4d530c74b3df2ef0379d5bb7b40ff763a33c5'
assert all(hashlib.sha256((out/n).read_bytes()).hexdigest() == h for n,h in json.loads((out/'script-manifest-final.json').read_text()).items())
script('prepare_refound')
script('create_new_volumes')
script('bootstrap')
operator=refound/'fresh_system_operator.py'
for phase in ('load','root-info'):
    run(phase,[sys.executable,str(operator),phase])
anchor=json.loads((refound/'root-info.json').read_text())['root_anchor']
assert len(anchor)==64 and anchor != '93252CF6227513EF93A5D42B36468D73773FA9369F45DA29BB6D1F0894B2D8C6'
for phase in ('found','publish'):
    run(phase+'-node',[sys.executable,str(operator),phase,'node'])
for phase in ('policy-node','request-enrollment','wait-principal','enrollment-evidence'):
    run(phase,[sys.executable,str(operator),phase])
script('install_remaining')
for phase in ('policy-apps','delegate-signup','final-gate'):
    run(phase,[sys.executable,str(operator),phase])
script('scale_out')
script('watch_deployment')
script('fleet_probe')
(state/'FLEET-PASSED.json').write_text(json.dumps({'passed':True,'release':'0.7.273','desktop':False},indent=2)+'\n')
print('Candidate fleet ready; deployed browser acceptance and old-volume purge remain.',flush=True)
