#!/usr/bin/env python3
"""Read-only coordinator audit of the frozen R1 diagnostic report. No suites."""
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
BOUNDARY = Path('/home/yan/.cache/quod-m4-r1-artifacts/quod-godot-m4-r1-handoff-ca84d4f8-20261029-01')
PREVIOUS = Path('/home/yan/.cache/quod-m4-artifacts/quod-godot-m4-handoff-ca84d4f8-20261029-01')
OUT = WORK/'_build/godot-m4-r1-coordinator-verification-20261029'
SNAPSHOT_SHA = '5a09fda58101a38d362c5e50cd9bcd4f827dcca74295abaa3b1f521c95379fcc'
HEAD = '293cf6115c0a6b18315eccdbb42cbca396f443d3'

def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def safe(name):
    path = PurePosixPath(name)
    assert not path.is_absolute() and '..' not in path.parts and str(path) == name, name
    return name

def filesystem(row):
    return {key:value for key,value in row.items() if key != 'tracked'}

def file_entry(path):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode):
        return {'kind':'symlink','target':os.readlink(path)}
    assert stat.S_ISREG(info.st_mode), str(path)
    return {'kind':'file','sha256':sha(path),'bytes':info.st_size,'mode':stat.S_IMODE(info.st_mode)}

def exact_tree(root, expected, paths=None):
    if paths is None:
        paths = []
        for folder, dirs, files in os.walk(root, followlinks=False):
            for name in list(dirs):
                if (Path(folder)/name).is_symlink():
                    files.append(name)
                    dirs.remove(name)
            paths.extend(str((Path(folder)/name).relative_to(root)) for name in files)
    assert len(paths) == len(set(paths))
    assert set(paths) == set(expected), {'extra':sorted(set(paths)-set(expected))[:10], 'missing':sorted(set(expected)-set(paths))[:10]}
    for name,row in expected.items():
        safe(name)
        assert file_entry(root/name) == filesystem(row), name
    return {'entries':len(expected),'bytes':sum(row.get('bytes',0) for row in expected.values()),'exact_paths_content_links_full_modes':True}

def read_archive(name, include_directories):
    actual = {}
    with tarfile.open(BOUNDARY/name, 'r:*') as archive:
        for member in archive:
            safe(member.name)
            if member.isdir() and not include_directories:
                continue
            assert member.name not in actual, member.name
            if member.isdir():
                row = {'directory':True,'mode':member.mode & 0o777}
            elif member.issym():
                row = {'symlink':member.linkname}
            else:
                assert member.isfile() or member.islnk(), member.name
                if member.islnk():
                    safe(member.linkname)
                with archive.extractfile(member) as stream:
                    digest = hashlib.file_digest(stream,'sha256').hexdigest()
                size = actual[member.linkname]['bytes'] if member.islnk() else member.size
                row = {'sha256':digest,'bytes':size,'mode':member.mode & 0o777}
            actual[member.name] = row
    return actual

def output_archive(name):
    expected = json.loads((BOUNDARY/(name+'.json')).read_text())
    actual = read_archive(name,True)
    assert set(actual) == set(expected), name+' path set'
    for path,row in expected.items():
        assert all(actual[path].get(key) == value for key,value in row.items()), (name,path)
    return {'entries':len(actual),'directories':sum(bool(r.get('directory')) for r in actual.values()),'every_path_content_mode_verified':True}

def campaigns():
    base = WORK/'doc/evidence/godot-m4-r1-20261029'
    qualification = json.loads((BOUNDARY/'causal-qualification.json').read_text())
    assert sha(base/'qualification.json') == sha(BOUNDARY/'causal-qualification.json')
    result = {}
    for name,expected in qualification['tests'].items():
        wrapper = json.loads((base/'logs'/f'{name}.json').read_text())
        assert wrapper['child_exit']==0 and not wrapper['timed_out'] and wrapper['error_diagnostics']==0
        assert sha(base/'logs'/f'{name}.log') == wrapper['sanitized_sha256']
        if name.startswith('physics-'):
            receipt = json.loads((base/name/'campaign.json').read_text())
            assert receipt['passed'] and receipt['client_child_exit']==0 and receipt['server_child_exit']==0
            client = base/name/'client.log'
            assert sha(client) == expected['client_log_sha256']
            server = json.loads((base/'logs'/f'{name}-server-log.json').read_text())
            assert server['child_exit']==0 and not server['timed_out'] and server['error_diagnostics']==0
            assert sha(base/'logs'/f'{name}-server-log.log') == server['sanitized_sha256']
        else:
            rows = json.loads((base/name/'result.json').read_text())
            assert len(rows)==1 and rows[0]['passed'] and rows[0]['child_exit']==0 and not rows[0]['external_sigkill_at_observed_seam']
            client = base/name/'backup-cancel.log'
        text = client.read_text()
        assert expected['completion'] in text
        phases = [json.loads(line.split('M4_R1_SHUTDOWN ',1)[1]) for line in text.splitlines() if line.startswith('M4_R1_SHUTDOWN ')]
        assert phases == expected['phase_observations']
        assert not expected.get('diagnostic_captured')
        result[name] = {'wrapper_exit':0,'client_exit':0,'client_log_sha256':sha(client),'phases_checked':len(phases),'stall_captured':False}
    assert not qualification['cause_determined'] and not qualification['production_correction'] and not qualification['historical_failures_resolved']
    return result

def main():
    assert sha(BOUNDARY/'snapshot.json') == SNAPSHOT_SHA
    snapshot = json.loads((BOUNDARY/'snapshot.json').read_text())
    assert snapshot['head'] == HEAD and snapshot['branch'] == 'worktree/pearl-stone'
    assert stat.S_IMODE(BOUNDARY.stat().st_mode) == 0o555
    shared = []
    for name,row in snapshot['artifacts'].items():
        path = BOUNDARY/safe(name)
        info = path.lstat()
        assert stat.S_ISREG(info.st_mode) and not info.st_mode & 0o222, name
        assert info.st_size == row['bytes'] and sha(path) == row['sha256'], name
        if name.startswith('prerequisite-m4-'):
            original = PREVIOUS/name.removeprefix('prerequisite-m4-')
            other = original.stat()
            assert info.st_ino == other.st_ino and info.st_dev == other.st_dev, name
            shared.append(name)
    print(json.dumps({'artifact_hashes_verified':len(snapshot['artifacts']),'shared_predecessor_hardlinks':len(shared)}),flush=True)
    expected = json.loads((BOUNDARY/'source-manifest.json').read_text())
    tracked = set(os.fsdecode(x) for x in subprocess.check_output(['git','ls-files','-z','--cached'],cwd=WORK).split(b'\0') if x)
    for name,row in expected.items():
        assert row['tracked'] == (name in tracked), name+' tracking provenance'
    paths = [os.fsdecode(x) for x in subprocess.check_output(['git','ls-files','-z','--cached','--others','--exclude-standard'],cwd=WORK).split(b'\0') if x]
    live = exact_tree(WORK,expected,paths)
    worker_receipt = json.loads((BOUNDARY/'independent-reconstruction.json').read_text())
    materialized = Path(worker_receipt['workspace'])
    assert subprocess.run(['git','rev-parse','--show-toplevel'],cwd=materialized,capture_output=True).returncode != 0
    reconstructed = exact_tree(materialized,expected)
    previous = json.loads((PREVIOUS/'source-manifest.json').read_text())
    assert not set(previous)-set(expected)
    changed = [name for name in previous if filesystem(previous[name]) != filesystem(expected[name])]
    assert changed == [], changed
    patch = subprocess.check_output(['git','diff','--no-ext-diff','--binary',HEAD],cwd=WORK)
    assert hashlib.sha256(patch).hexdigest() == sha(BOUNDARY/'tracked.patch') == sha(PREVIOUS/'tracked.patch')
    assert sha(BOUNDARY/'base.tar.gz') == sha(PREVIOUS/'base.tar.gz')
    assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=WORK).decode().strip() == HEAD
    assert not subprocess.check_output(['git','diff','--cached','--name-only'],cwd=WORK).strip()
    untracked = {name:filesystem(row) for name,row in expected.items() if not row['tracked']}
    packed = read_archive('untracked.tar.xz',False)
    assert set(packed) == set(untracked)
    for name,row in untracked.items():
        archive_row = packed[name]
        if row['kind']=='symlink':
            assert archive_row == {'symlink':row['target']}, name
        else:
            assert archive_row == {key:value for key,value in row.items() if key!='kind'}, name
    manifest = json.loads((BOUNDARY/'diagnostic-client-qualification.json').read_text())
    original = json.loads((PREVIOUS/'client-qualification.json').read_text())
    assert not manifest['compiled_application_inputs_copied']
    assert set(manifest['authored_inputs']) == set(original['authored_inputs'])
    diagnostic_changes = [name for name,digest in manifest['authored_inputs'].items() if original['authored_inputs'][name] != digest]
    assert diagnostic_changes == ['client/godot/Core/SignedView.cs','client/godot/Main.cs'], diagnostic_changes
    for name,digest in original['authored_inputs'].items():
        assert sha(WORK/name) == digest, name+' candidate09 restored'
    for name,digest in manifest['authored_inputs'].items():
        assert sha(Path(manifest['source'])/name) == digest, name+' diagnostic supplied input'
    outputs = {name:output_archive(name) for name in ['client-export.tar.gz','client-supplied-inputs.tar.gz','client-build-outputs.tar.gz','fixture-code-and-provider-outputs.tar.gz']}
    prior_real_patch = json.loads((WORK/'doc/evidence/godot-m4-coordinator-20261029/own-reconstruction.json').read_text())
    assert prior_real_patch['patch_child_exit']==0 and prior_real_patch['every_source_content_verified']
    return {'snapshot_sha256':SNAPSHOT_SHA,'head':HEAD,'artifact_count':len(snapshot['artifacts']),'artifact_bytes_hashed':sum(r['bytes'] for r in snapshot['artifacts'].values()),'previous_hardlinks':len(shared),'live_source':live,'worker_reconstruction_independently_hashed':reconstructed,'previous_m4_entries_unchanged':len(previous),'new_source_entries':len(expected)-len(previous),'exact_head_patch_sha256':sha(BOUNDARY/'tracked.patch'),'source_untracked_payload_verified':len(untracked),'outputs':outputs,'diagnostic_input_changes':diagnostic_changes,'live_candidate09_inputs_exact':len(original['authored_inputs']),'diagnostic_inputs_exact':len(manifest['authored_inputs']),'campaigns':campaigns(),'prior_real_coordinator_patch_application_reused':{'receipt':'doc/evidence/godot-m4-coordinator-20261029/own-reconstruction.json','same_base_and_patch_bytes':True,'new_untracked_payload_every_content_verified':True,'worker_r1_patch_child_exit':worker_receipt['patch_child_exit'],'another_multigigabyte_coordinator_materialization_created':False},'product_tests_rerun':False,'cause_determined':False,'full_m4_accepted':False,'commit_or_m5_started':False}

started = time.time()
try:
    result = main()
    result['passed'] = True
except BaseException as error:
    result = {'passed':False,'error':str(error),'traceback':traceback.format_exc()}
result['elapsed_seconds'] = time.time()-started
(OUT/'boundary-verification.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result),flush=True)
sys.exit(0 if result['passed'] else 1)
