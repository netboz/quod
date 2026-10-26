from pathlib import Path
import json,subprocess,sys,time,os
root=Path('/home/yan/src/quod')
evidence=Path(__file__).resolve().parent
out=root/'_build/quo-58-webxr-20261026/demo-02/deployment'
assert json.loads((out/'bootstrap-observed.json').read_text())['allocations']==1
steps=[['load'],['root-info'],['found','node'],['publish','node'],['policy-node'],['request-enrollment'],['wait-principal'],['enrollment-evidence']]
for name in ['agent','environment','environment:eidolons','gui','human_user','lens','licence','measure','material','material:eidolons','names','rendering','modelling','prolog','prolog:eidolons','lobby','signup']:
    steps.extend([['found',name],['publish',name]])
steps.extend([['policy-apps'],['delegate-signup'],['final-gate']])
with (evidence/'founding-intent.json').open('x') as f:json.dump({'steps':steps,'sources':'exact packaged ontologies','signup_recipe':'user_source_directory; composition owned by packaged signup ontology'},f,indent=2)
start=time.monotonic()
with (evidence/'founding.log').open('xb') as log:
    result=subprocess.run(['erlc','-Werror','-o',str(out),str(out/'quod_fresh_systems.erl'),str(out/'quod_fleet_probe.erl')],stdout=log,stderr=subprocess.STDOUT)
    if result.returncode:raise SystemExit(result.returncode)
    for step in steps:
        result=subprocess.run([sys.executable,str(out/'fresh_system_operator.py'),*step],stdout=log,stderr=subprocess.STDOUT)
        print(json.dumps({'step':step,'exit':result.returncode}),flush=True)
        if result.returncode:break
with (evidence/'founding-exit.json').open('x') as f:json.dump({'exit':result.returncode,'seconds':time.monotonic()-start},f)
raise SystemExit(result.returncode)
