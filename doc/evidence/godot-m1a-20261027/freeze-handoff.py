#!/usr/bin/env python3
"""Freeze the qualified handoff, preserving full tracked and untracked contents."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile

evidence = Path(__file__).resolve().parent
root = evidence.parents[2]
campaign, label = __import__('sys').argv[1:]
gates = json.loads((evidence / (campaign + '-result.json')).read_text())
assert gates['all_true_exits_zero'] and gates['source_unchanged'], 'Qualification remains open'
assert not gates['unrun']
qualified_inputs = json.loads((evidence / 'inputs' / (campaign + '-source-manifest.json')).read_text())
assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root).decode().strip() == qualified_inputs['head']
assert subprocess.check_output(['git', 'branch', '--show-current'], cwd=root).decode().strip() == qualified_inputs['branch']
for name, expected in qualified_inputs['files'].items():
    assert hashlib.sha256((root / name).read_bytes()).hexdigest() == expected, name
stage = Path('/tmp') / label
assert not stage.exists(), 'Never replace an earlier snapshot'
private = Path('/tmp') / (label + '-private-logs')
private.mkdir(mode=0o700, exist_ok=False)

# Redact only new, complete M1a logs; M0 and earlier snapshot bytes are untouched.
pattern = re.compile(rb'<<\s*(\d+(?:,\s*\d+)*)\s*>>')
redactions = []
for log in sorted((evidence / 'logs').glob('*.log')):
    raw = log.read_bytes()
    count = [0]
    def redact(match):
        values = re.findall(rb'\d+', match[1])
        if len(values) in (32, 64) and all(int(n) < 256 for n in values):
            count[0] += 1
            return b'<<REDACTED_DISPOSABLE_BINARY_' + str(len(values)).encode() + b'>>'
        return match[0]
    clean = pattern.sub(redact, raw)
    if clean != raw:
        saved = private / log.name
        saved.write_bytes(raw)
        saved.chmod(0o600)
        log.write_bytes(clean)
        redactions.append(dict(file=str(log.relative_to(root)),
                               raw_sha256=hashlib.sha256(raw).hexdigest(),
                               redacted_sha256=hashlib.sha256(clean).hexdigest(),
                               replacements=count[0]))
redaction_file = evidence / ('log-redactions-' + label + '.json')
assert not redaction_file.exists()
redaction_file.write_text(json.dumps(dict(private_originals=str(private), files=redactions,
    rule='All numeric Erlang binaries of exactly 32 or 64 bytes, including public identifiers; complete raw logs remain private outside this snapshot.'), indent=2) + '\n')

def git(*args):
    return subprocess.check_output(['git', *args], cwd=root)

head = git('rev-parse', 'HEAD').decode().strip()
branch = git('branch', '--show-current').decode().strip()
tracked = set(filter(None, git('ls-files', '-z').decode().split('\0')))
untracked = set(filter(None, git('ls-files', '--others', '--exclude-standard', '-z').decode().split('\0')))
stage.mkdir(mode=0o755)
patch = git('diff', '--binary', 'HEAD')
(stage / 'tracked.patch').write_bytes(patch)
base = stage / 'base.tar'
with base.open('wb') as output:
    subprocess.run(['git', 'archive', 'HEAD'], cwd=root, stdout=output, check=True)
tree = stage / 'source-tree'
tree.mkdir()
with tarfile.open(base) as archive:
    archive.extractall(tree, filter='data')

manifest = []
for name in sorted(tracked | untracked):
    src, dst = root / name, tree / name
    if not src.exists() and not src.is_symlink():
        if dst.exists():
            dst.unlink()
        continue
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.is_file() or dst.is_symlink():
        dst.unlink()
    if src.is_symlink():
        dst.symlink_to(os.readlink(src))
        manifest.append(dict(path=name, kind='symlink', target=os.readlink(src), tracked=name in tracked))
    elif src.is_file():
        shutil.copy2(src, dst)
        manifest.append(dict(path=name, kind='file', bytes=src.stat().st_size,
                             sha256=hashlib.sha256(src.read_bytes()).hexdigest(),
                             mode=oct(src.stat().st_mode & 0o777), tracked=name in tracked))

with tarfile.open(stage / 'untracked.tar.gz', 'w:gz') as archive:
    for name in sorted(untracked):
        src = root / name
        if src.is_file() or src.is_symlink():
            archive.add(src, arcname=name, recursive=False)
# Preserve dependency input bytes separately from generated parser annotations,
# Rebar indexes and compiled artifacts. This pool was checked when the clean
# stage was created; verify it again before archiving any entry.
dependency_pool = Path('/tmp/quod-m1a-dev-01')
dependencies = qualified_inputs['dependency_sources']
with tarfile.open(stage / 'dependency-inputs.tar.gz', 'w:gz', dereference=False) as archive:
    for name, expected in sorted(dependencies.items()):
        src = dependency_pool / name
        if isinstance(expected, dict):
            assert src.is_symlink() and str(src.readlink()) == expected['symlink'], name
        else:
            assert hashlib.sha256(src.read_bytes()).hexdigest() == expected, name
        archive.add(src, arcname=name, recursive=False)
(stage / 'dependency-inputs.json').write_text(json.dumps(dependencies, indent=2) + '\n')
generated_names = {name[:-4] + '.erl' for name in dependencies
                   if name.endswith(('.yrl', '.xrl')) and name[:-4] + '.erl' in dependencies}
(stage / 'dependency-authored-sources.json').write_text(json.dumps(
    {name: value for name, value in dependencies.items() if name not in generated_names}, indent=2) + '\n')
(stage / 'dependency-generated-sources.json').write_text(json.dumps(
    {name: value for name, value in dependencies.items() if name in generated_names}, indent=2) + '\n')
(stage / 'source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
# Prove that the independent reconstruction recipe reproduces every authored
# file and deletion. Its workspace is outside the immutable snapshot.
reconstructed = Path('/tmp') / (label + '-reconstruction')
reconstructed.mkdir(mode=0o700, exist_ok=False)
with tarfile.open(base) as archive:
    archive.extractall(reconstructed, filter='data')
subprocess.run(['git', 'apply', '--binary', str(stage / 'tracked.patch')],
               cwd=reconstructed, check=True)
with tarfile.open(stage / 'untracked.tar.gz') as archive:
    archive.extractall(reconstructed, filter='data')
expected_names = {row['path'] for row in manifest}
actual_names = {str(p.relative_to(reconstructed)) for p in reconstructed.rglob('*')
                if p.is_file() or p.is_symlink()}
assert expected_names == actual_names, 'Reconstructed source path set differs'
for row in manifest:
    path = reconstructed / row['path']
    if row['kind'] == 'symlink':
        assert path.is_symlink() and os.readlink(path) == row['target'], row['path']
    else:
        assert hashlib.sha256(path.read_bytes()).hexdigest() == row['sha256'], row['path']
with tarfile.open(stage / 'dependency-inputs.tar.gz') as archive:
    archive.extractall(reconstructed, filter='data')
for name, expected in dependencies.items():
    path = reconstructed / name
    if isinstance(expected, dict):
        assert path.is_symlink() and str(path.readlink()) == expected['symlink'], name
        assert path.resolve().is_relative_to(reconstructed), name
    else:
        assert hashlib.sha256(path.read_bytes()).hexdigest() == expected, name
(stage / 'reconstruction-verification.json').write_text(json.dumps(dict(
    source_entries_verified=len(manifest), dependency_entries_verified=len(dependencies),
    exact_source_path_set=True, tracked_patch_applied=True, child_exit=0,
    workspace=str(reconstructed)), indent=2) + '\n')
(stage / 'RECONSTRUCT.md').write_text('''# Reconstruct and verify

`source-tree` is a complete materialized tree, with no .git directory or links
back to the live source. Alternatively, extract base.tar into an empty directory,
apply tracked.patch with `git apply --binary`, then extract untracked.tar.gz.
Verify each file's SHA-256 and each symlink target against source-manifest.json.
Deleted tracked paths are recorded by the patch. The baseline is the exact HEAD
recorded in snapshot.json; do not reset the live worktree to reconstruct it.

For the qualified clean build, extract dependency-inputs.tar.gz into that source
copy and verify its separate dependency-inputs.json. These are exactly the
1,094 M0-qualified input entries: 1,091 authored source/resource/symlink entries
and three lexer/parser source outputs, whose grammar inputs and annotations are
recorded separately. The two category manifests remain separate from the complete
input manifest. No beams, native targets,
Rebar indexes or other compiled output are included. Generated parser output
is recorded separately in the M1a compiled manifest. Do not use the worktree's
older ignored dependency cache as a substitute. Use the recorded local builder
image/toolchain; its image ID is not a published repository digest.

The tree contains authored source, archived originals, public founding receipts,
full sanitized logs and retained M0 evidence. Ignored compiled/dependency caches,
private credentials and disposable fixture storage are excluded. Raw logs with
disposable private seeds are retained only in the restricted external directory
specified by the M1a redaction manifest, outside this snapshot. Clean compiled
outputs are retained in the separately identified gate stage and described by
the compiled manifest; they were not inputs to the clean campaign. This snapshot
does not authorize a commit, deployment, next milestone or another review.
''')
info = dict(label=label, head=head, branch=branch,
            worker_session='922c7c06-1acb-4c2b-9141-fccf4ab4c947',
            checkpoint='M1a', clean_campaign=campaign,
            all_clean_gate_true_exits_zero=True, source_unchanged=True,
            files=len(manifest), tracked_entries=sum(e['tracked'] for e in manifest),
            untracked_entries=sum(not e['tracked'] for e in manifest),
            separate_dependency_input_entries=len(dependencies),
            tracked_patch_sha256=hashlib.sha256(patch).hexdigest(),
            artifacts={p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                       for p in [base, stage / 'untracked.tar.gz', stage / 'source-manifest.json',
                                 stage / 'dependency-inputs.tar.gz', stage / 'dependency-inputs.json',
                                 stage / 'dependency-authored-sources.json', stage / 'dependency-generated-sources.json',
                                 stage / 'reconstruction-verification.json',
                                 stage / 'RECONSTRUCT.md']})
groups = {
    'm1a_evidence': 'doc/evidence/godot-m1a-20261027/',
    'preserved_m0_evidence': 'doc/evidence/godot-m0-20261027/',
    'archived_prolog': 'outdated/ontologies/prolog/',
    'active_prolog': 'priv/ontologies/',
    'tests_and_fixtures': 'test/',
    'browser_tests': 'client/test/',
    'derived_browser_package': 'priv/explorer/',
    'platform_generated_skills': '.agents/skills/.nimbalyst-generated/',
}
info['separate_scope_totals'] = {
    group: dict(entries=len(rows), bytes=sum(row.get('bytes', 0) for row in rows))
    for group, prefix in groups.items()
    for rows in [[row for row in manifest if row['path'].startswith(prefix)]]
}
(stage / 'snapshot.json').write_text(json.dumps(info, indent=2) + '\n')
snapshot_hash = hashlib.sha256((stage / 'snapshot.json').read_bytes()).hexdigest()
(stage / 'snapshot.sha256').write_text(snapshot_hash + '  snapshot.json\n')
for path in stage.rglob('*'):
    if not path.is_symlink():
        executable = path.is_dir() or bool(path.stat().st_mode & 0o111)
        path.chmod(0o555 if executable else 0o444)
stage.chmod(0o555)
print(json.dumps(dict(path=str(stage), files=len(manifest),
    snapshot_sha256=snapshot_hash)))
