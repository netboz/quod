#!/usr/bin/env python3
"""Fetch official .NET qualification tools outside the source worktree."""
import hashlib
import json
from pathlib import Path
import urllib.request
import zipfile

root = Path('/tmp/quod-godot-m0-tools')
root.mkdir(exist_ok=True)
release = json.load(urllib.request.urlopen('https://api.github.com/repos/godotengine/godot-builds/releases/tags/4.7.2-stable', timeout=30))
names = ['Godot_v4.7.2-stable_mono_linux_x86_64.zip', 'Godot_v4.7.2-stable_mono_export_templates.tpz']
expected = {
    names[0]: '129f82db7bafd54ae14bb5bb284041c73860e8c7a009a3a026ca5e946cbff247',
    names[1]: '92f8681e349ef1f90891b792da95e3b2b0bd1ed610b78018c58feb2d87e15a9d',
}
records = []
for name in names:
    asset = next(x for x in release['assets'] if x['name'] == name)
    target = root / name
    if not target.exists():
        print('Fetching', name, asset['size'], flush=True)
        with urllib.request.urlopen(asset['browser_download_url'], timeout=60) as source, target.open('xb') as out:
            while block := source.read(1024*1024):
                out.write(block)
    digest = 'sha256:' + hashlib.file_digest(target.open('rb'), 'sha256').hexdigest()
    assert digest == 'sha256:'+expected[name] == asset['digest'], (name, digest, asset['digest'])
    print('Verified', name, digest, flush=True)
    with zipfile.ZipFile(target) as archive:
        for member in archive.infolist():
            if name.endswith('.tpz') and not (member.filename.startswith('templates/linux_') or member.filename == 'templates/version.txt'):
                continue
            dest = (root/member.filename).resolve()
            assert dest.is_relative_to(root.resolve())
            archive.extract(member, root)
            mode = member.external_attr >> 16
            if mode:
                dest.chmod(mode & 0o777)
    records.append(dict(name=name, sha256=digest.removeprefix('sha256:'), size=asset['size'], url=asset['browser_download_url']))
Path(__file__).with_name('inputs').joinpath('godot-artifacts.json').write_text(json.dumps(records, indent=2)+'\n')
