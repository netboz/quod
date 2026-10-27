#!/usr/bin/env python3
"""Verify the M0 source/evidence relationship before review or handoff."""
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

base = Path(__file__).resolve().parent
root = base.parents[2]
def read(name): return json.loads((base / name).read_text())
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
assert subprocess.check_output(['git', 'branch', '--show-current'], cwd=root).decode().strip() == 'worktree/pearl-stone'
assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root).decode().strip() == 'f6c29fe925e666dd68ee7fa68c0e03f5d03391a2'
subprocess.run(['git', 'diff', '--check'], cwd=root, check=True)
assert all(sha(root / r['path']) == r['sha256'] for r in read('runtime-manifest.json')['files'])
built = read('runtime-build-manifest.json')
assert built['source_manifest'] == 'inputs/r1-gates-06-source-manifest.json'
for row in built['files'] + built['dependencies']:
    assert sha(Path(built['source_copy']) / row['path']) == row['sha256']
assert read('logs/r1-release-02.json')['child_exit'] == 0
assert read('inputs/r1-release-02-source-check.json')['verified']
for row in read('inputs/r1-release-02-source-check.json')['generated_metadata']:
    assert (sha(Path(built['source_copy']) / row['path']) == row['sha256'] ==
            sha(base / row['retained_output']))
worker = read('inputs/worker-outcome-codec.json')['files']
overrides = {r['path']: r['worker_sha256'] for r in worker}
review_fix = read('inputs/worker-review-depth-source.json')['files']
overrides.update({r['path']: r['sha256'] for r in review_fix})
cache = read('inputs/worker-ct-cache.json')
overrides[cache['path']] = cache['worker_sha256']
imports = read('inputs/runtime-prerequisite-scope.json')['files']
assert len(imports) == 46
for row in imports:
    assert sha(root / row['path']) == overrides.get(row['path'], row['sha256']), row['path']
assert sum(sha(root / r['path']) == r['sha256'] for r in imports) == 44
bootstrap = read('inputs/worker-bootstrap-fixture-source.json')
assert sha(root / bootstrap['path']) == bootstrap['sha256']
for row in read('inputs/generated-dependencies-post-review-check.json')['files']:
    old, new = base / row['retained_original'], base / row['compiled_source']
    assert sha(old) == row['original_sha256'] and sha(new) == row['compiled_sha256']
    assert ([s for s in old.read_text().splitlines() if not s.startswith('-file(')] ==
            [s for s in new.read_text().splitlines() if not s.startswith('-file(')])
audit = read('ontology-audit.json')['sources']
dispositions = read('retirement-map.json')
reachability = read('source-reachability.json')
assert len(audit) == len(dispositions) == len(reachability) == 50
assert {r['path'] for r in audit} == {r['source'] for r in dispositions} == {r['source'] for r in reachability}
assert len({r['final_destination'] for r in dispositions if not r['final_destination'].startswith('test/')}) == 24
assert sum(r['final_destination'].startswith('test/') for r in dispositions) == 7
for old, new in [('inputs/spaces-onboarding.md', 'doc/spaces.md'),
                 ('inputs/space-architecture-onboarding.md', 'nimbalyst-local/plans/space-conceptual-architecture-review.md')]:
    delta = difflib.unified_diff((base / old).read_text().splitlines(), (root / new).read_text().splitlines())
    assert not any(s.startswith('-') and not s.startswith('---') for s in delta), new
for row in read('export-manifest.json'):
    assert sha(Path('/tmp/quod-godot-m0-export') / row['path']) == row['sha256']
storage = read('logs/storage-detail-07/storage-result.json')
assert storage['pass_'] and storage['unchanged_read_sync_calls'] == 0
assert all(r['child_exit'] == r.get('expected_exit', 0) for r in storage['children'])
for label in ['godot-export-11', 'exported-crypto-final-06', 'exported-protocol-final-02',
              'storage-final-07', 'tls-final-05', 'wire-fixtures-final-06', 'production-wire-03',
              'endpoint-symbol-regression-green-02', 'remote-symbol-outcome-green-07']:
    receipt = read('logs/' + label + '.json')
    assert receipt['child_exit'] == 0 and not receipt['timed_out'], label
assert read('logs/endpoint-symbol-regression-red-01.json')['child_exit'] == 1
assert read('logs/review-depth-red-03.json')['child_exit'] == 1
assert read('logs/review-depth-green-04.json')['child_exit'] == 0
assert read('logs/bootstrap-fixture-repeat-02.json')['child_exit'] == 0
assert read('logs/remote-path-regressions-06.json')['child_exit'] == 1
assert not read('r1-gates-02-result.json')['all_true_exits_zero']
assert read('logs/r1-gates-02-eunit.json')['child_exit'] == 1
assert not read('r1-gates-03-result.json')['all_true_exits_zero']
assert read('logs/r1-gates-03-eunit.json')['child_exit'] == 1
assert read('r1-gates-04-result.json')['all_true_exits_zero']
assert not read('r1-gates-05-result.json')['all_true_exits_zero']
assert read('logs/r1-gates-05-eunit.json')['child_exit'] == 1
gates = read('r1-gates-06-result.json')
assert gates['all_true_exits_zero'] and gates['source_unchanged'] and not gates['unrun']
frozen = read('inputs/r1-gates-06-source-manifest.json')
assert not frozen['acl_observation']
pre_review = read('inputs/r1-gates-04-source-manifest.json')['files']
assert set(frozen['files']) == set(pre_review)
assert {n for n, digest in frozen['files'].items() if digest != pre_review[n]} == {
    'src/quod_dtx_endpoint.erl', 'test/quod_dtx_endpoint_tests.erl',
    'test/quod_foreign_log_tests.erl'}
pre_fixture = read('inputs/r1-gates-05-source-manifest.json')['files']
assert {n for n, digest in frozen['files'].items() if digest != pre_fixture[n]} == {
    'test/quod_foreign_log_tests.erl'}
previous = read('inputs/r1-gates-03-source-manifest.json')['files']
assert set(pre_review) == set(previous)
assert {n for n, digest in pre_review.items() if digest != previous[n]} == {'rebar.config', 'rebar.lock', 'README.md'}
for row in read('inputs/r1-gates-06-runner-source.json')['inputs']:
    assert sha(base / row['retained_source']) == row['sha256'], row['source']
for name, digest in frozen['files'].items():
    assert sha(root / name) == sha(Path(frozen['stage']) / 'source' / name) == digest, name
hygiene = read('inputs/r1-gates-06-copy-hygiene.json')
metadata = hygiene['copied_generated_metadata']
assert sha(base / metadata['retained_input']) == frozen['dependencies'][metadata['path']]
assert read('logs/compiler-index-cleanup-01.json')['child_exit'] == 0
assert (read('logs/compiler-index-cleanup-01.json')['start_utc'] <
        read('logs/r1-gates-06-xref.json')['start_utc'])
for name, expected in frozen['dependencies'].items():
    if name == metadata['path']: continue  # Derived compiler index, retained separately.
    path = Path(frozen['stage']) / 'source' / name
    if isinstance(expected, dict):
        assert path.is_symlink() and str(path.readlink()) == expected['symlink'], name
    else:
        assert sha(path) == expected, name
links = 0
docs = [root / 'doc/godot-foundation-contract.md', base / 'README.md', base / 'prerequisites.md',
        base / 'checked-fable-review.md',
        base / 'retirement-map.md', root / 'nimbalyst-local/handoffs/godot-m0-r1-result.md']
for doc in docs:
    for part in doc.read_text().split('](')[1:]:
        target = part.split(')', 1)[0]
        if target.startswith(('https:', 'nimbalyst:', '#', 'mailto:')): continue
        target = target.split('#', 1)[0]
        if target.rsplit(':', 1)[-1].isdigit():
            target = target.rsplit(':', 1)[0]
        path = Path(target) if target.startswith('/') else doc.parent / target
        assert path.is_file(), (str(doc), target)
        links += 1
print(json.dumps(dict(verified=True, runtime_files=len(read('runtime-manifest.json')['files']),
                      imports_unchanged=44, source_dispositions=50, local_links=links,
                      clean_sequential_gates=5, frozen_gate_inputs=len(frozen['files']))))
