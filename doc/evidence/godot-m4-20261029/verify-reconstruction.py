#!/usr/bin/env python3
"""Independently materialize and check the complete source outside any checkout."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile

boundary, scratch = map(Path, sys.argv[1:3])
receipt_path = Path(sys.argv[3]) if len(sys.argv) == 4 else boundary/'independent-reconstruction.json'
expected = json.loads((boundary/'source-manifest.json').read_text())
scratch.mkdir(mode=0o700, exist_ok=False)
env = dict(os.environ)
for key in ['GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE']:
    env.pop(key, None)
assert subprocess.run(['git','rev-parse','--show-toplevel'], cwd=scratch,
                      env=env, capture_output=True).returncode != 0

def destination(name):
    relative = PurePosixPath(name)
    assert not relative.is_absolute() and '..' not in relative.parts, name
    target = scratch/name
    for parent in reversed(target.parents):
        if parent == scratch or scratch in parent.parents:
            assert not parent.is_symlink(), str(parent)
    target.parent.mkdir(parents=True, exist_ok=True)
    return target

def extract(path):
    with tarfile.open(path, 'r:*') as archive:
        for member in archive:
            target = destination(member.name)
            if member.isdir():
                target.mkdir(exist_ok=True)
            elif member.issym():
                target.symlink_to(member.linkname)
            elif member.islnk():
                original = destination(member.linkname)
                assert original.is_file() and not original.is_symlink()
                shutil.copyfile(original, target)
                target.chmod(member.mode)
            else:
                assert member.isfile(), member.name
                with target.open('xb') as output:
                    shutil.copyfileobj(archive.extractfile(member), output)
                target.chmod(member.mode)

extract(boundary/'base.tar.gz')
applied = subprocess.run(['git','apply','--binary',str(boundary/'tracked.patch')],
                         cwd=scratch, env=env, capture_output=True)
assert applied.returncode == 0, applied.stderr
extract(boundary/'untracked.tar.xz')

actual = {}
for directory, dirs, files in os.walk(scratch, followlinks=False):
    parent = Path(directory)
    for name in list(dirs):
        if (parent/name).is_symlink():
            files.append(name)
            dirs.remove(name)
    for name in files:
        path = parent/name
        relative = str(path.relative_to(scratch))
        if path.is_symlink():
            actual[relative] = {'kind':'symlink','target':str(path.readlink())}
        else:
            assert path.is_file(), relative
            with path.open('rb') as stream:
                digest = hashlib.file_digest(stream,'sha256').hexdigest()
            actual[relative] = {'kind':'file','sha256':digest,'bytes':path.stat().st_size,
                                'mode':path.stat().st_mode&0o777}
assert set(actual) == set(expected), 'Reconstructed file/symlink path set differs'
for name, row in expected.items():
    found = actual[name]
    assert found['kind'] == row['kind'], name
    if row['kind'] == 'symlink':
        assert found['target'] == row['target'], name
    else:
        assert (found['sha256'],found['bytes']) == (row['sha256'],row['bytes']), name
        assert found['mode']&0o111 == row['mode']&0o111, name
        # Git preserves executable bits; restore the recorded full source mode.
        (scratch/name).chmod(row['mode'])
        assert (scratch/name).stat().st_mode&0o777 == row['mode'], name
receipt = dict(method='Independent complete materialization, real Git binary patch, filesystem path-set/content/mode verification',
    workspace=str(scratch),outside_every_checkout=True,patch_child_exit=applied.returncode,
    exact_path_set=True,every_source_content_verified=True,full_recorded_modes_restored=True,
    entries=len(actual),source_bytes=sum(row.get('bytes',0) for row in actual.values()))
receipt_path.write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt))
