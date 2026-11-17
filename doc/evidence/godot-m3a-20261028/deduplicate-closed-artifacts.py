#!/usr/bin/env python3
"""Share identical closed-campaign blobs, preserving every path and content."""
import hashlib
import json
import os
from pathlib import Path
import re

root=Path(__file__).resolve().parents[3]
evidence=root/'doc/evidence/godot-m3a-20261028'
output=evidence/'closed-artifact-deduplication.json'
assert not output.exists()
candidates={}
for manifest in sorted((evidence/'inputs').glob('gates[0-9][0-9]-source-manifest.json')):
    label=manifest.name.split('-')[0]
    closed=evidence/(label+'-result.json')
    if not closed.exists(): continue
    record=json.loads(closed.read_text())
    assert record['results'] and (record['all_true_exits_zero'] or record['unrun'])
    source=json.loads(manifest.read_text())
    stage=Path(source['stage'])
    assert stage==root/'_build'/('m3a-'+label)
    for name,digest in source['files'].items(): candidates[stage/'source'/name]=digest
    for provider in (evidence/'inputs').glob(label+'-*-objects.json'):
        for name,row in json.loads(provider.read_text()).items():
            path=Path(row['path'])
            assert path.is_relative_to(stage/'gate-artifacts')
            candidates[path]=row['sha256']

def sha(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()

groups={};changes=[]
for path,expected in sorted(candidates.items()):
    assert path.is_file() and not path.is_symlink(),path
    before=path.stat()
    assert before.st_uid==os.getuid(),path
    assert sha(path)==expected,path
    key=(expected,before.st_size,before.st_mode&0o777,before.st_uid,before.st_gid)
    canonical=groups.setdefault(key,path)
    if canonical.stat().st_ino==before.st_ino: continue
    replacement=path.with_name(path.name+'.m3a-dedup')
    assert not replacement.exists()
    os.link(canonical,replacement)
    assert sha(replacement)==expected
    os.replace(replacement,path)
    assert sha(path)==expected and path.stat().st_mode&0o777==before.st_mode&0o777
    changes.append(dict(path=str(path),canonical=str(canonical),sha256=expected,
        bytes=before.st_size,original_mtime_ns=before.st_mtime_ns,
        original_atime_ns=before.st_atime_ns,original_inode=before.st_ino,
        hardlinked_inode=path.stat().st_ino))
for path,expected in candidates.items(): assert sha(path)==expected,path
output.write_text(json.dumps(dict(scope='Only closed disposable campaign authored copies and retained provider originals; no live worktree, package cache, private store or previous checkpoint boundary',
    exact_candidate_path_set_and_every_content_hash_verified=True,
    original_modes_owners_preserved=True,original_timestamps_retained_in_manifest=True,
    candidates=len(candidates),hardlinked_paths=len(changes),
    duplicate_content_bytes=sum(row['bytes'] for row in changes),paths=changes),indent=2)+'\n')
print(json.dumps(dict(candidates=len(candidates),hardlinked_paths=len(changes),
    duplicate_content_bytes=sum(row['bytes'] for row in changes),all_paths_and_hashes_preserved=True)))
