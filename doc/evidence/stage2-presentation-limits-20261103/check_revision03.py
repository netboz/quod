"""Read-only applicability/source accounting, NOT runtime verification."""
from pathlib import Path
import hashlib, json, runpy, subprocess

r = Path('/home/yan/src/quod_worktrees/pearl-stone')
e = Path(__file__).resolve().parent
state = runpy.run_path(str(e / 'revise_proposals.py'))
bundles = state['bundles']
out = e / 'proposals-revision03'
checks = []
for label in bundles:
    patch = out / (label + '.patch')
    child = subprocess.run(['git', 'apply', '--check', str(patch)], cwd=r, capture_output=True)
    log = out / (label + '.applicability.log')
    log.write_bytes(b'STDOUT\n' + child.stdout + b'\nSTDERR\n' + child.stderr)
    checks.append({'label': label, 'true_exit': child.returncode, 'stdout_eof': True,
                   'stderr_eof': True, 'patch_sha256': hashlib.sha256(patch.read_bytes()).hexdigest(),
                   'log_sha256': hashlib.sha256(log.read_bytes()).hexdigest()})

proposed = {}
for label, changes in bundles.items():
    for path, (before, after) in changes.items():
        assert (r / path).read_text() == before, path
        if path in proposed:
            # Optional memory patch and nested-goal patch have disjoint hunks.
            assert path == 'src/quod_proof_session.erl'
        else:
            proposed[path] = after
retired = ['QUOD_MAX_NESTED_GOAL_BYTES', 'QUOD_CLIENT_GOAL_MAX_REPLY_BYTES',
           'QUOD_CLIENT_GOAL_MAX_ENVELOPE_BYTES', 'quod_terrain_wire:batch(', 'quod_terrain_wire:admit(']
remaining = []
for root in ['src', 'include', 'test', 'client/src', 'client/test']:
    for path in (r / root).rglob('*'):
        if path.suffix not in ['.erl', '.hrl', '.js', '.mjs']: continue
        name = str(path.relative_to(r))
        text = proposed.get(name, path.read_text())
        for marker in retired:
            if marker in text: remaining.append({'path': name, 'marker': marker})

old = {}
for label in ['01', '02', '03']:
    packet = r / ('nimbalyst-local/review-packets/stage2-presentation-limits' + label)
    result = json.loads((packet / 'result.json').read_text())
    for filename, key in [('snapshot.tar', 'archive_sha256'), ('manifest.json', 'manifest_sha256')]:
        actual = hashlib.sha256((packet / filename).read_bytes()).hexdigest()
        assert actual == result[key], (label, filename)
    old[label] = {key: result[key] for key in ['archive_sha256', 'manifest_sha256']}

applied = json.loads((e / 'inputs/account.json').read_text())['production_delta']
for row in applied['paths']:
    assert hashlib.sha256((r / row['path']).read_bytes()).hexdigest() == row['current_sha256']
result = {'runtime_applied': False, 'runtime_compiled_or_executed': False,
          'production_delta_this_revision': {'added': 0, 'removed': 0},
          'applicability': checks, 'retired_marker_remaining': remaining,
          'prior_freezes_verified': old, 'applied_source_unchanged': True}
(out / 'verification.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'applicability': checks, 'remaining': remaining, 'applied_source_unchanged': True}))
assert all(row['true_exit'] == 0 for row in checks)
assert not remaining, remaining
