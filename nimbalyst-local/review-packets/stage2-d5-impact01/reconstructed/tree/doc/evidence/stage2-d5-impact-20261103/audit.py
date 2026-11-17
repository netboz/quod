"""Read-only impact/evidence audit. Does not run application code or resubmit work."""
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
RECON = ROOT / 'doc/evidence/stage2-d5-reconciliation-20261103'
VIS = ROOT / 'doc/evidence/godot-occurrence-visibility-20261102'
OCC = ROOT / 'doc/evidence/godot-occurrence-forms-20261101'
bound = {}


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def read(p):
    p = Path(p)
    if p.is_relative_to(ROOT):
        bound[str(p.relative_to(ROOT))] = sha(p)
    return json.loads(p.read_text())


def manifest(p):
    m = read(p)
    for name, expected in m['supplied_inputs'].items():
        assert sha(Path(m['stage']) / 'source' / name) == expected, (p, name)
    return m


old = manifest(ROOT / 'doc/evidence/godot-space-stage2-20261031/inputs/client-stage2-product01-manifest.json')
latest = manifest(VIS / 'inputs/client-visibility-product01-manifest.json')
changed = [p for p, h in old['live_source_inputs'].items() if sha(ROOT / p) != h]
assert sorted(changed) == sorted(read(OUT / 'changed-inputs.json')) and len(changed) == 20
assert all(sha(ROOT / p) == h for p, h in latest['live_source_inputs'].items())
vr = read(VIS / 'result.json')
assert all(sha(ROOT / p) == h for p, h in vr['server_sources'].items())
occ = read(OCC / 'result.json')
receipts = {}


def receipt(label, p, expected_hash, manifest_path):
    assert sha(p) == expected_hash, (label, 'receipt')
    r = read(p)
    m = manifest(manifest_path)
    assert r['manifest_sha256'] == sha(manifest_path)
    streams = r['streams']
    for stream in streams.values():
        path = Path(stream['path'])
        assert sha(path) == stream['sha256'] and path.stat().st_size == stream['bytes'], (label, path)
    receipts[label] = {
        'receipt': str(Path(p).relative_to(ROOT)), 'sha256': sha(p),
        'passed': r['passed'], 'failure': r.get('failure'),
        'unretired_failure': r.get('unretired_failure'), 'reader_errors': r['reader_errors'],
        'children': {k: {field: value for field, value in v.items()
                        if field in ['true_exit', 'explicit_completion', 'checks']} for k, v in r['children'].items()},
        'eof': r['eof'], 'streams': streams,
        'manifest': str(Path(manifest_path).relative_to(ROOT)), 'manifest_sha256': sha(manifest_path),
        'current_input_differences': [n for n,h in m['live_source_inputs'].items() if sha(ROOT/n) != h],
    }
    return r


for label in vr['selected_gates'] + ['visibility-interaction06', 'visibility-preview06']:
    gate = vr['gates'][label]
    p = VIS / 'inputs' / (label + '.json')
    r = receipt(label, p, sha(p), ROOT / gate['manifest'])
    receipts[label]['wrapper_exit'] = gate['wrapper_exit']
    assert {k: v['true_exit'] for k,v in r['children'].items()} == gate['children']
    assert r['eof'] == gate['eof']
    if label in vr['selected_gates']:
        assert r['passed'] and not r['reader_errors'] and all(r['eof'].values())
        assert all(v['true_exit'] == 0 for v in r['children'].values()) and gate['wrapper_exit'] == 0
    else:
        assert not r['passed'] and gate['wrapper_exit'] == 1
for label in ['occurrence-lifetime-final24', 'occurrence-interaction-final27', 'occurrence-preview-final27']:
    gate = occ['selected'][label]
    r = receipt(label, Path(gate['receipt']), gate['sha256'], Path(gate['manifest']))
    assert r['passed'] and not r['reader_errors'] and all(r['eof'].values())
    assert all(v['true_exit'] == 0 for v in r['children'].values())
    receipts[label]['wrapper_all_zero_in_qualification'] = gate['all_children_and_wrapper_zero']
    receipts[label]['cost'] = gate['cost']

# Exact shared math; separate changed placement/capture behavior has signed coverage above.
scene = 'client/godot/ScenePanel.cs'
a = (Path(old['stage']) / 'source' / scene).read_text()
b = (ROOT / scene).read_text()
start, end = '    static Basis RotationBasis(float', '    public void Apply(Term terms)'
math_old = a[a.index(start):a.index(end)]
math_now = b[b.index(start):b.index(end)]
assert math_old == math_now
space = 'priv/ontologies/quod_space.pl'
committed = subprocess.check_output(['git', 'show', 'HEAD:' + space], cwd=ROOT).decode()
current = (ROOT / space).read_text()
start = 'space_scene_parts([],'
assert committed[committed.index(start):] == current[current.index(start):]
nav = 'client/godot/tests/NavigationChecks.cs'
a = (Path(old['stage']) / 'source' / nav).read_text()
b = (ROOT / nav).read_text()
# The historical recursive assertions themselves have no changed diff hunk.
assert 'RecursiveScene' not in (OUT / 'deltas' / (nav + '.diff')).read_text()
prior = read(RECON / 'audit-result.json')
for name,h in prior['historical_evidence_hashes'].items():
    expected = h['sha256'] if isinstance(h,dict) else h
    assert sha(ROOT/name) == expected, name
    bound[name] = expected
before = read(RECON / 'inherited-source.json')
for name,h in before.items():
    p = ROOT / name
    assert sha(p) == h['sha256'] and p.stat().st_mode & 0o7777 == h['mode'], name

owners = set(prior['current_owner_sources']) | set(latest['live_source_inputs']) | set(vr['server_sources'])
owners.update(['ui/src/World.tsx', 'ui/src/GuiForm.tsx', 'client/src/space-entry.js',
    'client/src/space-entry.d.ts', 'client/src/space-library.js', 'client/src/space-library.d.ts',
    'client/src/accounts.js', 'client/src/world.js', 'client/src/operation-controller.js',
    'client/src/prolog-edit.js', 'priv/ontologies/lobby_worlds.pl', 'priv/ontologies/lobby_instance.pl',
    'priv/ontologies/quod_lobby.pl', 'priv/ontologies/voxel_world.pl', 'priv/ontologies/voxel_world_view.pl',
    'priv/ontologies/voxel_world_gui.pl', 'priv/ontologies/gui_instance.pl',
    'test/quod_gui_examples_tests.erl', 'test/quod_lifecycle_single_path_tests.erl',
    'test/quod_space_tests.erl', 'test/quod_voxel_world_tests.erl', 'client/test/space-library.test.js',
    'doc/spaces.md', 'doc/godot-foundation-contract.md', 'doc/multiwrite-architecture.md', 'doc/gui-examples.md'])
result = {
    'kind': 'source-impact-and-retirement-audit-not-runtime-acceptance',
    'head': subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT).decode().strip(),
    'changed_historical_inputs': changed,
    'current_product_inputs_exact': len(latest['live_source_inputs']),
    'new_product_inputs_since_stage2': sorted(set(latest['live_source_inputs']) - set(old['live_source_inputs'])),
    'current_server_bindings_exact': len(vr['server_sources']),
    'shared_transform_block_unchanged_sha256': hashlib.sha256(math_now.encode()).hexdigest(),
    'recursive_traversal_equals_committed_m3': True,
    'retained_signed_receipts': receipts,
    'all_visibility_runs_passed': vr['all_affected_runs_passed'],
    'preview_normal_retirement_qualified': vr['preview_normal_retirement_qualified'],
    'interaction06_cause_established': vr['interaction06_cause_established'],
    'current_source': {n: {'sha256': sha(ROOT/n), 'mode': (ROOT/n).stat().st_mode & 0o7777} for n in sorted(owners)},
    'evidence_bindings': bound,
    'inherited_source_paths_unchanged': len(before),
    'production_delta': '+0/-0', 'new_runtime_runs': 0,
    'new_failing_runtime_baseline': None,
    'assessment': 'No changed D5 owner behavior lacks affected signed evidence. Historical whole-tree qualification is not transferred; selected later gates cover changed seams. Original unresolved failures stay open.'
}
(OUT / 'audit-result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:result[k] for k in ['kind','current_product_inputs_exact','current_server_bindings_exact','inherited_source_paths_unchanged','production_delta','new_runtime_runs','new_product_inputs_since_stage2']}))
