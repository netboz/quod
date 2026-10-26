from pathlib import Path
import os,subprocess,time,json
root=Path('/home/yan/src/quod');evidence=Path(__file__).resolve().parent
out=root/'_build/quo-58-webxr-20261026/demo-01/client-02';out.mkdir(mode=0o700)
cert=root/'_build/quo-58-webxr-20261026/demo-01/deployment/client-public-certificate.pem'
assert json.loads((evidence/'https-verified.json').read_text())['normal_hostname_verification']
env=dict(os.environ,NODE_EXTRA_CA_CERTS=str(cert))
for name in ['NODE_TLS_REJECT_UNAUTHORIZED','LD_LIBRARY_PATH','LD_PRELOAD']:env.pop(name,None)
env['QUOD_PREFLIGHT_MODE']='diagnose'
import shutil
prior=out.parent/'client-01'
assert json.loads((prior/'private-operations.json').read_text())==[]
for name in ['private-browser-key.json','private-account.json','private-operations.json']:
    shutil.copy2(prior/name,out/name)
args=['node',str(evidence/'cluster-client-02.mjs'),'https://192.168.1.10:30519',str(out)]
with (evidence/'client-02-intent.json').open('x') as f:json.dump({'command':args,'normal_tls_checks':True,'fixture':False,'creation_submission':'once; preserve uncertain operation without resubmission'},f,indent=2)
start=time.monotonic()
with (evidence/'client-02.log').open('xb') as log:result=subprocess.run(args,env=env,stdout=log,stderr=subprocess.STDOUT)
with (evidence/'client-02-exit.json').open('x') as f:json.dump({'exit':result.returncode,'seconds':time.monotonic()-start},f)
print(json.dumps({'exit':result.returncode}),flush=True)
raise SystemExit(result.returncode)
