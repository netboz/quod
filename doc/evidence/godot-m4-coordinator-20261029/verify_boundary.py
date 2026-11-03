#!/usr/bin/env python3
"""Coordinator-only source/archive verification; executes no product tests."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys
import tarfile
import time
import traceback

WORK = Path('/home/yan/src/quod_worktrees/pearl-stone')
BOUNDARY = Path('/home/yan/.cache/quod-m4-artifacts/quod-godot-m4-handoff-ca84d4f8-20261029-01')
PREDECESSOR = Path('/home/yan/.cache/quod-m3b-artifacts/quod-godot-m3b-handoff-8b352c53-20261029-02')
OUT = WORK/'_build/godot-m4-coordinator-verification-20261029'
SNAPSHOT_SHA = 'a06f1f934754d3d210e1b74c5685c2c523b1507bfc1a8af2ce9fc7ce4aec5349'
HEAD = '293cf6115c0a6b18315eccdbb42cbca396f443d3'

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def safe(name):
    p = PurePosixPath(name)
    assert not p.is_absolute() and '..' not in p.parts and str(p) == name, name
    return name

def content(path):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode):
        return {'kind':'symlink', 'target':os.readlink(path)}
    assert stat.S_ISREG(info.st_mode), str(path)
    return {'kind':'file', 'sha256':digest(path), 'bytes':info.st_size,
            'mode':stat.S_IMODE(info.st_mode)}

def exact_tree(root, expected, listed=None):
    if listed is None:
        listed = []
        for folder, dirs, files in os.walk(root, followlinks=False):
            for name in list(dirs):
                p = Path(folder)/name
                if p.is_symlink():
                    files.append(name)
                    dirs.remove(name)
            listed.extend(str((Path(folder)/name).relative_to(root)) for name in files)
    assert len(listed) == len(set(listed)), 'Duplicate source paths'
    assert set(listed) == set(expected), {
        'extra':sorted(set(listed)-set(expected))[:20],
        'missing':sorted(set(expected)-set(listed))[:20]}
    total = 0
    for name, entry in expected.items():
        safe(name)
        row = content(root/name)
        filesystem_entry = {key:value for key,value in entry.items() if key != 'tracked'}
        assert row == filesystem_entry, {'path':name, 'actual':row, 'expected':filesystem_entry}
        total += row.get('bytes', 0)
    return {'entries':len(expected), 'source_bytes':total,
            'exact_path_set':True, 'every_hash_link_mode_verified':True}

def archive_payload(name):
    expected = json.loads((BOUNDARY/(name+'.json')).read_text())
    found = {}
    total = 0
    with tarfile.open(BOUNDARY/name, 'r:*') as archive:
        for member in archive:
            safe(member.name)
            assert member.name not in found, member.name
            if member.isdir():
                row = {'directory':True, 'mode':member.mode & 0o777}
            elif member.issym():
                row = {'symlink':member.linkname}
            else:
                assert member.isfile() or member.islnk(), member.name
                if member.islnk():
                    safe(member.linkname)
                with archive.extractfile(member) as stream:
                    h = hashlib.file_digest(stream, 'sha256').hexdigest()
                row = {'sha256':h, 'bytes':member.size, 'mode':member.mode & 0o777}
                if member.islnk():
                    row['bytes'] = found[member.linkname]['bytes']
                total += row['bytes']
            found[member.name] = row
    assert set(found) == set(expected), name+' path set'
    for path, want in expected.items():
        # Compare every field actually recorded by the output index.
        assert all(found[path].get(k) == value for k,value in want.items()), (name,path,found[path],want)
    return {'entries':len(found), 'bytes':total, 'exact_path_set':True,
            'every_recorded_content_mode_verified':True}

def main():
    assert digest(BOUNDARY/'snapshot.json') == SNAPSHOT_SHA
    snapshot = json.loads((BOUNDARY/'snapshot.json').read_text())
    assert snapshot['head'] == HEAD and snapshot['branch'] == 'worktree/pearl-stone'
    assert stat.S_IMODE(BOUNDARY.stat().st_mode) == 0o555
    artifacts = {}
    shared = []
    for name, row in snapshot['artifacts'].items():
        p = BOUNDARY/safe(name)
        info = p.lstat()
        assert stat.S_ISREG(info.st_mode) and not info.st_mode & 0o222, name
        assert info.st_size == row['bytes'] and digest(p) == row['sha256'], name
        artifacts[name] = row
        if name.startswith('prerequisite-m3b-'):
            original = PREDECESSOR/name.removeprefix('prerequisite-m3b-')
            assert original.is_file(), str(original)
            previous = original.stat()
            assert info.st_ino == previous.st_ino and info.st_dev == previous.st_dev, name
            shared.append(name)
    print(json.dumps({'artifacts_verified':len(artifacts),'unchanged_predecessor_hardlinks':len(shared)}), flush=True)
    expected = json.loads((BOUNDARY/'source-manifest.json').read_text())
    tracked = set(os.fsdecode(x) for x in subprocess.check_output(
        ['git','ls-files','-z','--cached'], cwd=WORK).split(b'\0') if x)
    for name, row in expected.items():
        assert row['tracked'] == (name in tracked), ('Git tracking provenance',name)
    listed = subprocess.check_output(['git','ls-files','-z','--cached','--others','--exclude-standard'], cwd=WORK)
    listed = [os.fsdecode(x) for x in listed.split(b'\0') if x]
    live = exact_tree(WORK, expected, listed)
    worker = json.loads((BOUNDARY/'independent-reconstruction.json').read_text())
    materialized = Path(worker['workspace'])
    outside = subprocess.run(['git','rev-parse','--show-toplevel'], cwd=materialized, capture_output=True)
    assert outside.returncode != 0
    reconstruction = exact_tree(materialized, expected)
    patch = subprocess.check_output(['git','diff','--no-ext-diff','--binary',HEAD], cwd=WORK)
    assert hashlib.sha256(patch).hexdigest() == digest(BOUNDARY/'tracked.patch')
    assert not subprocess.check_output(['git','diff','--cached','--name-only'], cwd=WORK).strip()
    assert subprocess.check_output(['git','rev-parse','HEAD'], cwd=WORK).decode().strip() == HEAD
    previous = json.loads((BOUNDARY/'prerequisite-m3b-source-manifest.json').read_text())
    assert not set(previous)-set(expected), 'Missing predecessor source'
    filesystem = lambda row: {key:value for key,value in row.items() if key != 'tracked'}
    changed = [name for name in previous if filesystem(previous[name]) != filesystem(expected[name])]
    assert all(name.startswith(('client/godot/','client/godot-tests/','client/godot-tools/')) for name in changed), changed
    outputs = {name:archive_payload(name) for name in [
        'client-export.tar.gz','all-client-build-outputs.tar.gz',
        'all-client-supplied-inputs.tar.gz','fixture-code-and-provider-outputs.tar.gz',
        'inspected-engine-source.tar.gz']}
    return {'snapshot_sha256':SNAPSHOT_SHA,'head':HEAD,'branch':snapshot['branch'],
        'artifact_count':len(artifacts),'artifact_bytes_hashed':sum(r['bytes'] for r in artifacts.values()),
        'predecessor_hardlinks_verified':len(shared),'live_source':live,
        'worker_materialization_independently_checked':reconstruction,
        'exact_binary_head_patch_sha256':digest(BOUNDARY/'tracked.patch'),
        'original_head_archive_sha256':digest(BOUNDARY/'base.tar.gz'),
        'predecessor_changed_paths':changed,'outputs':outputs,'git_tracking_provenance_verified':True,
        'worker_idle_gate_recorded_separately':True,'tests_rerun':False,
        'full_m4_accepted':False,'commit_or_next_ticket_authorized_by_this_receipt':False}

started = time.time()
try:
    result = main()
    result['passed'] = True
except BaseException as error:
    result = {'passed':False,'error':str(error),'traceback':traceback.format_exc()}
result['elapsed_seconds'] = time.time()-started
(OUT/'boundary-verification.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result), flush=True)
sys.exit(0 if result['passed'] else 1)
