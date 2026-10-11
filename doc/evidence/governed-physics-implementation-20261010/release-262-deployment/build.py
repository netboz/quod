#!/usr/bin/env python3
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

repo = Path('/home/yan/src/quod')
out = Path('/home/yan/src/quod/_build/quod27-release-262/deployment')
gate = json.loads((out.parent / 'gates-03/PASSED.json').read_text())
assert gate['passed'] and gate['sources_unchanged']
assert len(gate['results']) == 11 and all(r['exit'] == 0 for r in gate['results'])
attestation = json.loads((out/'committed-inputs.json').read_text())
assert attestation['all_inputs_match'] and attestation['version'] == '0.7.262'
assert attestation['commit'] == json.loads((out/'source-commit.json').read_text())['commit']
context = out / 'image-context'
image = '192.168.1.11:5000/quod:0.7.262'
head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
assert head == json.loads((out/'source-commit.json').read_text())['commit'], head
inputs = json.loads((out.parent/'gates-03/source-manifest.json').read_text())
for name, expected in inputs.items():
    observed = subprocess.check_output(['git','show',f'{head}:{name}'],cwd=repo)
    assert hashlib.sha256(observed).hexdigest() == expected, name
assert not context.exists()
context.mkdir(parents=True)

fixed = {'Dockerfile', '.dockerignore', 'rebar.config', 'rebar.lock',
         'scripts/build-physics.sh'}
listed = subprocess.check_output(
    ['git', 'ls-tree', '-r', '--name-only', head,
     'config', 'include', 'priv', 'src', 'native/quod_physics'],
    cwd=repo, text=True).splitlines()
files = sorted(fixed | {name for name in listed
                        if '/target/' not in name
                        and not name.startswith('priv/native/')
                        and not (name.startswith('priv/certs/') and name.endswith('.pem'))})
for name in files:
    data = subprocess.check_output(['git', 'show', f'{head}:{name}'], cwd=repo)
    target = context / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)

sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
manifest = {'commit': head, 'version': '0.7.262',
            'provenance': 'Exact committed Docker inputs extracted with git show',
            'files': {name: sha(context / name) for name in files}}
(out / 'image-source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
manifest_digest = sha(out / 'image-source-manifest.json')

request = urllib.request.Request(
    'http://192.168.1.11:5000/v2/quod/manifests/0.7.262', method='HEAD')
try:
    urllib.request.urlopen(request, timeout=20)
except urllib.error.HTTPError as error:
    assert error.code == 404, error
else:
    raise RuntimeError('0.7.262 already exists; refusing mutable tag overwrite')

def run(label, command):
    start = time.monotonic()
    with (out / f'{label}.log').open('x') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    (out / f'{label}.exit.json').write_text(json.dumps(
        {'command': command, 'exit': result.returncode,
         'seconds': time.monotonic() - start}, indent=2) + '\n')
    if result.returncode:
        raise SystemExit(result.returncode)

run('image-build', ['docker', 'build', '--progress=plain',
    '--label', 'org.quod.source-manifest.sha256=' + manifest_digest,
    '-t', image, str(context)])
container = subprocess.check_output(['docker', 'create', image], text=True).strip()
try:
    subprocess.run(['docker', 'cp', container + ':/opt/quod/lib/quod-0.7.262/priv/explorer',
                    str(out / 'image-explorer')], check=True)
finally:
    subprocess.run(['docker', 'rm', container], check=True, stdout=subprocess.DEVNULL)
for name, digest in manifest['files'].items():
    if name.startswith('priv/explorer/'):
        observed = out / 'image-explorer' / name.removeprefix('priv/explorer/')
        assert sha(observed) == digest, name

run('vault-boot', [sys.executable, str(out/'boot_probe.py'), image, 'vault-boot-01'])
assert json.loads((out/'vault-boot-01/boot-result.json').read_text())['version'] == '0.7.262'
run('image-push', ['docker', 'push', image])
info = json.loads(subprocess.check_output(['docker', 'image', 'inspect', image]))[0]
digests = [d for d in info['RepoDigests']
           if d.startswith('192.168.1.11:5000/quod@sha256:')]
assert len(digests) == 1, digests
digest = digests[0].split('@', 1)[1]
request = urllib.request.Request(
    'http://192.168.1.11:5000/v2/quod/manifests/0.7.262', method='HEAD',
    headers={'Accept': 'application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json'})
with urllib.request.urlopen(request, timeout=20) as response:
    assert response.headers['Docker-Content-Digest'] == digest
record = {'image': image, 'digest': digests[0],
          'pinned_image': image + '@' + digest,
          'commit': head, 'source_manifest_sha256': manifest_digest,
          'explorer_matches': True, 'registry_digest_matches': True}
(out / 'verified-image.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps(record, indent=2))
