#!/usr/bin/env python3
"""Check qualified source, public receipts, archives and the local release."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

evidence = Path(__file__).resolve().parent
root = evidence.parents[2]
label = sys.argv[1]
inputs = json.loads((evidence / 'inputs' / (label + '-source-manifest.json')).read_text())
result = json.loads((evidence / (label + '-result.json')).read_text())
assert result['all_true_exits_zero'] and result['source_unchanged'] and not result['unrun']
work = Path(inputs['stage']) / 'source'
release = work / '_build/prod/rel/quod'
apps = list((release / 'lib').glob('quod-*'))
assert len(apps) == 1
app = apps[0]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

for name, expected in inputs['files'].items():
    assert digest(root / name) == expected == digest(work / name), name
assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root).decode().strip() == inputs['head']
assert subprocess.check_output(['git', 'branch', '--show-current'], cwd=root).decode().strip() == inputs['branch']
subprocess.run(['git', 'diff', '--check'], cwd=root, check=True)
subprocess.run(['git', 'diff', '--exit-code', 'HEAD', '--',
                'doc/evidence/godot-m0-20261027',
                'nimbalyst-local/handoffs/godot-m0-r1-result.md'], cwd=root, check=True)

receipt = json.loads((evidence / (label + '-founding.json')).read_text())
assert receipt['counts']['shared_foundations'] == 7
assert receipt['counts']['catalogue_rows'] == 6
assert receipt['counts']['total_histories'] == 11
assert len(receipt['predicate_profiles']) == 11
assert {r['namespace'] for r in receipt['catalogue']} == {
    'quod:node', 'quod:agent', 'quod:gui', 'quod:controllers', 'quod:space', 'quod:user'}
for source in receipt['sources']:
    assert digest(root / 'priv/ontologies' / source['file']).upper() == source['sha256']

rebuild = json.loads((evidence / 'inputs/founding-beam-rebuild-01-result.json').read_text())
assert rebuild['all_recorded_founding_digests_match']
assert rebuild['no_object_copied_into_clean_gate_stage']
test_modules, ct_modules, release_modules = {}, {}, {}
for profile in receipt['predicate_profiles']:
    for module in profile['modules']:
        name, expected = module['module'], module['sha256']
        beam = root / rebuild['objects'][name]['path']
        assert digest(beam).upper() == expected, name
        test_modules[name] = {'path': str(beam), 'sha256': expected, 'reconstructed_exact_bytes': True}
        ct_beam = work / '_build/test/lib/quod/ebin' / (name + '.beam')
        ct_modules[name] = {'path': str(ct_beam), 'sha256': digest(ct_beam)}
        installed = app / 'ebin' / (name + '.beam')
        assert installed.resolve().is_relative_to(release)
        release_modules[name] = {'path': str(installed), 'sha256': digest(installed)}

packaged = {}
for name, expected in inputs['files'].items():
    if not name.startswith('priv/'):
        continue
    target = app / name
    assert target.resolve().is_relative_to(release), name
    assert digest(target) == expected, name
    packaged[name] = expected
archives = json.loads((evidence / 'final-source-03-line-accounting.json').read_text())['archives']['manifest']
for row in archives:
    assert digest(root / row['path']) == row['sha256']
    assert not (app / row['original_path']).exists(), row['original_path']
    assert subprocess.check_output(['git', 'show', 'HEAD:' + row['original_path']], cwd=root) == (root / row['path']).read_bytes()
native = {}
for path in (app / 'priv').rglob('*.so'):
    relative = path.relative_to(app)
    assert digest(path) == digest(work / relative)
    native[str(relative)] = digest(path)
assert native

output = evidence / (label + '-consistency.json')
assert not output.exists()
data = dict(label=label, head=inputs['head'], branch=inputs['branch'], source_unchanged=True,
            m0_evidence_unchanged=True, all_required_gates_true_exit_zero=True,
            receipt_profiles_verified=11, receipt_sources_verified=len(receipt['sources']),
            founding_test_beams=test_modules, post_ct_test_beams=ct_modules,
            production_release_beams=release_modules,
            packaged_source_and_assets=packaged, packaged_native=native,
            archived_originals_verified=len(archives), archived_sources_packaged=False,
            release=str(release), release_is_local_only=True)
output.write_text(json.dumps(data, indent=2) + '\n')
print(json.dumps({k: data[k] for k in ['label', 'source_unchanged', 'm0_evidence_unchanged',
    'receipt_profiles_verified', 'receipt_sources_verified', 'archived_originals_verified']}))
