#!/usr/bin/env python3
"""Freeze exact test inputs in tmpfs; no Git branch or worktree is created."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

root=Path(__file__).resolve().parents[3]
target=Path('/tmp/quod-m0-validation-01')
target.mkdir(exist_ok=False)
files=subprocess.check_output(['git','ls-files'],cwd=root).decode().splitlines()
selected=[p for p in files if p.startswith(('src/','include/','priv/','test/','config/','scripts/','client/','assets/','native/')) or p in ['rebar.config','rebar.lock']]
manifest={}
for name in selected:
    p=root/name
    if not p.is_file():continue
    q=target/name;q.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,q)
    manifest[name]=hashlib.sha256(q.read_bytes()).hexdigest()
# Include the already built native output; the unchanged build hook still runs.
for name in ['native/quod_physics/target','priv/native']:
    src=root/name
    if src.exists():shutil.copytree(src,target/name,dirs_exist_ok=True)
deps=root/'_build/default/lib'
for dep in deps.iterdir():
    if dep.name=='quod':continue
    shutil.copytree(dep,target/'_build/default/lib'/dep.name,symlinks=True)
(target/'SOURCE-MANIFEST.json').write_text(json.dumps(manifest,indent=2)+'\n')
(Path(__file__).with_name('inputs')/'validation-source-manifest.json').write_text(json.dumps(dict(path=str(target),head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root).decode().strip(),files=manifest),indent=2)+'\n')
assert all(hashlib.sha256((root/p).read_bytes()).hexdigest()==v for p,v in manifest.items())
print('Frozen',len(manifest),'source inputs at',target,'matching the worker tree; build outputs separate')
