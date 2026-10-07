from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import urllib.error
import urllib.request

repo = Path('/home/yan/src/quod')
out = Path('/tmp/quod-release-253-20261007')
gates = out / 'attempt-03-after-interruption'
for name in ['eunit', 'ct', 'xref', 'dialyzer']:
    assert json.loads((gates / f'{name}.exit.json').read_text())['exit'] == 0
assert subprocess.check_output(['git', 'status', '--porcelain'], cwd=repo) == b''
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
assert commit == '3a97d47155419a24f038c7425bea2c24ddf1491a'
context = out / 'image-context'
context.mkdir()
paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=repo).decode().split('\0')
manifest = {}
for name in paths:
    if name in ['Dockerfile', 'rebar.config', 'rebar.lock', 'scripts/build-physics.sh'] or name.startswith(('config/', 'include/', 'priv/', 'src/', 'native/quod_physics/')):
        src = repo / name
        if not src.is_file():
            continue
        dest = context / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)
        manifest[name] = hashlib.sha256(src.read_bytes()).hexdigest()
(out / 'image-source-manifest.json').write_text(json.dumps({'commit': commit, 'files': manifest}, indent=2)+'\n')
image = '192.168.1.11:5000/quod:0.7.253'
try:
    urllib.request.urlopen(urllib.request.Request('http://192.168.1.11:5000/v2/quod/manifests/0.7.253', method='HEAD'))
except urllib.error.HTTPError as error:
    assert error.code == 404
else:
    raise RuntimeError('Image tag already exists; refusing overwrite')

def run(name, command):
    with (out / f'{name}.log').open('x') as output:
        completed = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT)
    (out / f'{name}.exit.json').write_text(json.dumps({'exit': completed.returncode, 'command': command}, indent=2)+'\n')
    assert completed.returncode == 0, name
    print(f'{name} passed', flush=True)

run('image-build', ['docker', 'build', '--progress=plain', '--label', f'org.opencontainers.image.revision={commit}', '-t', image, str(context)])
container = subprocess.check_output(['docker', 'create', image], text=True).strip()
try:
    subprocess.run(['docker', 'cp', f'{container}:/opt/quod/lib/quod-0.7.253/priv/explorer', str(out / 'image-explorer')], check=True)
finally:
    subprocess.run(['docker', 'rm', container], check=True, stdout=subprocess.DEVNULL)
for name, digest in manifest.items():
    if name.startswith('priv/explorer/'):
        extracted = out / 'image-explorer' / name.removeprefix('priv/explorer/')
        assert hashlib.sha256(extracted.read_bytes()).hexdigest() == digest, name
run('image-push', ['docker', 'push', image])
info = json.loads(subprocess.check_output(['docker', 'image', 'inspect', image]))[0]
digests = [digest for digest in info['RepoDigests'] if digest.startswith('192.168.1.11:5000/quod@sha256:')]
assert len(digests) == 1
(out / 'verified-image.json').write_text(json.dumps({'image': image, 'digest': digests[0], 'pinned_image': image+'@'+digests[0].split('@')[1], 'source_commit': commit, 'explorer_matches': True}, indent=2)+'\n')
print('Verified and published '+digests[0], flush=True)
