"""Package only this campaign's passing frozen tree; never overwrite a tag."""
from pathlib import Path
import hashlib, json, os, shutil, subprocess, sys, time, urllib.error, urllib.request

for variable in ['DEBUG','LD_LIBRARY_PATH','LD_PRELOAD']: os.environ.pop(variable,None)

root = Path('/home/yan/src/quod')
evidence = Path(__file__).resolve().parent
gate = Path('/home/yan/src/quod/doc/evidence/quo-58-webxr-20261026/view-correction-01/release-gates-02')
out = root/'_build/quo-58-webxr-20261026/view-correction-01/deployment'
tree = Path('/home/yan/src/quod/_build/quo-58-webxr-20261026/view-correction-01/release-tree-02')
passed = json.loads((gate/'PASSED.json').read_text())
assert passed['passed'] and len(passed['results']) == 12
assert all(r['exit'] == 0 and r['sources_unchanged'] for r in passed['results'])
freeze = json.loads((gate/'freeze.json').read_text())
head = freeze['revision']
patch_hash = freeze['working_patch_sha256']
assert head == '5c1a90e604131aaa29adfb18ea176f5af8433eae'
manifest = json.loads((gate/'input-manifest.json').read_text())
source = {n:h for n,h in manifest.items() if not n.startswith('priv/explorer/')}
assert all(hashlib.sha256((tree/n).read_bytes()).hexdigest()==h for n,h in source.items())
assets = json.loads((gate/'bundle-manifest.json').read_text())
assert assets and all(hashlib.sha256((tree/n).read_bytes()).hexdigest()==h for n,h in assets.items())
fixed = {'Dockerfile','.dockerignore','rebar.config','rebar.lock','scripts/build-physics.sh'}
files = {n:h for n,h in source.items() if n in fixed or n.startswith(('config/','include/','priv/','src/','native/quod_physics/'))}
files = {n:h for n,h in files.items() if '/target/' not in n and not n.startswith(('priv/native/','priv/certs/'))}
files.update(assets)
context = out/'image-context'
context.mkdir(exist_ok=False)
for name,digest in files.items():
    assert hashlib.sha256((tree/name).read_bytes()).hexdigest()==digest
    target=context/name; target.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(tree/name,target)
record = {'revision':head,'working_patch_sha256':patch_hash,'internal_release_version':'0.7.275','label_changes':False,'files':files}
with (out/'image-source-manifest.json').open('x') as f: json.dump(record,f,indent=2)
source_hash = hashlib.sha256((out/'image-source-manifest.json').read_bytes()).hexdigest()
tag = '0.7.275-head-view-5c1a90e6-'+patch_hash[:8]+'-20261026-v01'
image = '192.168.1.11:5000/quod:'+tag
url = 'http://192.168.1.11:5000/v2/quod/manifests/'+tag
headers = {'Accept':'application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json'}
try:
    urllib.request.urlopen(urllib.request.Request(url,method='HEAD',headers=headers),timeout=20)
except urllib.error.HTTPError as error:
    assert error.code == 404
else:
    raise RuntimeError('Image tag exists; will not overwrite or retry publication')

def run(label,args):
    with (out/(label+'.intent.json')).open('x') as f:json.dump({'command':args},f,indent=2)
    started=time.monotonic()
    with (out/(label+'.log')).open('xb') as log:
        result=subprocess.run(args,stdout=log,stderr=subprocess.STDOUT)
    receipt={'command':args,'exit':result.returncode,'seconds':time.monotonic()-started}
    with (out/(label+'.exit.json')).open('x') as f:json.dump(receipt,f,indent=2)
    print(json.dumps(receipt),flush=True)
    if result.returncode:raise SystemExit(result.returncode)

run('image-build',['docker','build','--progress=plain','--label','org.opencontainers.image.revision='+head,
    '--label','org.quod.working-patch.sha256='+patch_hash,
    '--label','org.quod.source-manifest.sha256='+source_hash,'-t',image,str(context)])
container=subprocess.check_output(['docker','create',image],text=True).strip()
try:
    subprocess.run(['docker','cp',container+':/opt/quod/lib/quod-0.7.275/priv',str(out/'packaged-priv')],check=True)
finally:
    subprocess.run(['docker','rm',container],check=True,stdout=subprocess.DEVNULL)
for name,digest in files.items():
    if name.startswith('priv/'):
        assert hashlib.sha256((out/'packaged-priv'/name.removeprefix('priv/')).read_bytes()).hexdigest()==digest,name
run('stable-source-path',['docker','run','--rm','--network=none','--entrypoint=/bin/sh',image,'-ec',
    'test -L /opt/quod/priv; for f in human_user_instance agent_instance personal_agent gui_instance gui_operation controller_preferences space_gui lobby_instance space space_view node_execution; do test -f /opt/quod/priv/ontologies/$f.pl; done'])
run('boot-probe-compile',['erlc','-Werror','-o',str(out),str(out/'quod_vault_boot_probe.erl')])
run('vault-boot',[sys.executable,str(out/'boot_probe.py'),image,'vault-boot-01'])
assert json.loads((out/'vault-boot-01/boot-result.json').read_text())['version']=='0.7.275'
run('image-push',['docker','push',image])
info=json.loads(subprocess.check_output(['docker','image','inspect',image]))[0]
digests=[d for d in info['RepoDigests'] if d.startswith('192.168.1.11:5000/quod@sha256:')]
assert len(digests)==1
digest=digests[0].split('@',1)[1]
with urllib.request.urlopen(urllib.request.Request(url,method='HEAD',headers=headers),timeout=20) as response:
    assert response.headers['Docker-Content-Digest']==digest
verified={'revision':head,'working_patch_sha256':patch_hash,'image':image,'pinned_image':image+'@'+digest,'image_id':info['Id'],
          'source_manifest_sha256':source_hash,'packaged_priv_matches':True,'registry_digest_matches':True}
with (out/'verified-image.json').open('x') as f:json.dump(verified,f,indent=2)
with (evidence/'verified-image.json').open('x') as f:json.dump(verified,f,indent=2)
print(json.dumps(verified),flush=True)
