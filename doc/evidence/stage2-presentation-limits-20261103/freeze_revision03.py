"""Freeze review artifacts only. Does not apply, build or run proposed code."""
from pathlib import Path
import hashlib, io, json, runpy, tarfile

r = Path('/home/yan/src/quod_worktrees/pearl-stone')
e = Path(__file__).resolve().parent
packet = r / 'nimbalyst-local/review-packets/stage2-presentation-limits04'
assert not packet.exists()
state = runpy.run_path(str(e / 'revise_proposals.py'))
out = e / 'proposals-revision03'
checks = json.loads((out / 'verification.json').read_text())
assert checks['applied_source_unchanged'] and not checks['retired_marker_remaining']
h = lambda data: hashlib.sha256(data).hexdigest()
files = {}
for path in [e / 'revise_proposals.py', e / 'revision03_tests.py',
             e / 'check_revision03.py', Path(__file__), e / 'propose.py',
             e / 'claude-fable-review.md', e / 'inputs/parent-review-notes.json',
             e / 'inputs/claude-heap-probe-evidence-correction.md',
             e / 'inputs/approval-rejections.json', e / 'inputs/account.json',
             r / 'AGENTS.md']:
    files[str(path.relative_to(r))] = path.read_bytes()
for directory in [out, e / 'inputs/otp28-accounting-source']:
    for path in directory.rglob('*'):
        if path.is_file(): files[str(path.relative_to(r))] = path.read_bytes()
for row in checks['applicability']:
    assert row['true_exit'] == 0 and row['stdout_eof'] and row['stderr_eof']
    assert h((out / (row['label'] + '.patch')).read_bytes()) == row['patch_sha256']
for label, changes in state['bundles'].items():
    for path, (before, after) in changes.items():
        assert (r / path).read_text() == before
        files[path] = before.encode()
        files['proposed-source/' + label + '/' + path] = after.encode()
for row in json.loads((e / 'inputs/account.json').read_text())['production_delta']['paths']:
    data = (r / row['path']).read_bytes()
    assert h(data) == row['current_sha256']
    files[row['path']] = data
for label, hashes in checks['prior_freezes_verified'].items():
    old = r / ('nimbalyst-local/review-packets/stage2-presentation-limits' + label)
    assert h((old / 'snapshot.tar').read_bytes()) == hashes['archive_sha256']
    assert h((old / 'manifest.json').read_bytes()) == hashes['manifest_sha256']
    files['prior-freeze/' + label + '-result.json'] = (old / 'result.json').read_bytes()
for path in ['nimbalyst-local/plans/space-conceptual-architecture-review.md',
             'nimbalyst-local/handoffs/stage2-d5-reconciliation-20261103.md',
             'doc/multiwrite-architecture.md', 'doc/spaces.md',
             'src/quod_link.erl', 'include/quod_transport_limits.hrl',
             'include/quod_term_limits.hrl', 'config/vm.args',
             'priv/ontologies/material_policy.pl']:
    files[path] = (r / path).read_bytes()
packet.mkdir()
manifest = {name: {'sha256': h(data), 'bytes': len(data)} for name, data in sorted(files.items())}
(packet / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
with tarfile.open(packet / 'snapshot.tar', 'w') as archive:
    for name, data in sorted(files.items()):
        info = tarfile.TarInfo(name)
        info.size, info.mtime, info.mode = len(data), 0, 0o644
        archive.addfile(info, io.BytesIO(data))
with tarfile.open(packet / 'snapshot.tar') as archive:
    assert len(archive.getmembers()) == len(manifest)
    for member in archive.getmembers():
        assert h(archive.extractfile(member).read()) == manifest[member.name]['sha256']
result = {'freeze_verified': True, 'scope_accepted': False, 'proposal_revision': 3,
          'source_label': 'applied-presentation01', 'files': len(files),
          'runtime_applied': False, 'runtime_compiled_or_executed': False,
          'production_delta_this_revision': {'added': 0, 'removed': 0},
          'proposed_required_production_delta': {'added': 112, 'removed': 199, 'net': -87},
          'proposed_optional_production_delta': {'added': 9, 'removed': 2, 'net': 7},
          'large_signed_display_accepted': False,
          'claimed_reviewer_probe_is_execution_evidence': False,
          'prior_freezes_verified': checks['prior_freezes_verified'],
          'archive_sha256': h((packet / 'snapshot.tar').read_bytes()),
          'manifest_sha256': h((packet / 'manifest.json').read_bytes())}
(packet / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))
