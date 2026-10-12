#!/usr/bin/env python3
"""Seal the finished isolated campaign without replacing earlier evidence."""
import datetime
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import tarfile
import tempfile

root = pathlib.Path('/home/yan/src/quod')
evidence = pathlib.Path(__file__).resolve().parent
source = root / '_build/quod-generic-hinged/gates-03'
tree = source / 'tree'
destination = evidence / 'gates-03'
passed = json.loads((source / 'PASSED.json').read_text())
assert passed['passed'] and passed['sources_unchanged']
assert len(passed['results']) == 11
assert all(row['exit'] == 0 and row['sources_unchanged'] for row in passed['results'])
freeze = json.loads((source / 'freeze.json').read_text())
assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip() == freeze['base_commit']
manifest = json.loads((source / 'source-manifest.json').read_text())
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
assert all(digest(tree / name) == value for name, value in manifest.items())
assert all(digest(root / name) == manifest[name] for name in freeze['owned_changes'])
assert digest(root / 'doc/README.md') == '7756a489d740fea8bb4bc953284f00cfa062eed29e85e34a3acf443b22d6d18f'
destination.mkdir()
for path in source.iterdir():
    if path.is_file():
        shutil.copy2(path, destination / path.name)
shutil.copytree(source / 'logs', destination / 'logs')
with tarfile.open(destination / 'ct-logs.tar.gz', 'w:gz') as archive:
    archive.add(tree / '_build/test/logs', arcname='ct-logs')

patch = bytearray()
with tempfile.TemporaryDirectory(prefix='quod-hinged-seal-') as temporary:
    before = pathlib.Path(temporary) / 'before'
    check = pathlib.Path(temporary) / 'base'
    check.mkdir()
    for name in freeze['owned_changes']:
        original = subprocess.run(['git', 'show', 'HEAD:' + name], cwd=root, capture_output=True)
        before.write_bytes(original.stdout if original.returncode == 0 else b'')
        if original.returncode == 0:
            target = check / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(original.stdout)
        delta = subprocess.run(['diff', '-u', '--label', 'a/' + name, '--label', 'b/' + name,
                                str(before), str(tree / name)], capture_output=True)
        assert delta.returncode in (0, 1)
        patch.extend(delta.stdout)
    patch_path = destination / 'changes.patch'
    patch_path.write_bytes(patch)
    subprocess.run(['git', 'apply', '--check', str(patch_path)], cwd=check, check=True)

release = tree / '_build/prod/rel/quod/lib/quod-0.7.263'
packaged = {}
for relative in ['priv/ontologies/quod_physics.pl', 'priv/ontologies/quod_hinged.pl',
                 'priv/native/quod_physics.so']:
    assert digest(release / relative) == digest(tree / relative)
    packaged[relative] = digest(release / relative)
for module in ['quod_runtime', 'quod_physics', 'quod_physics_native']:
    packaged['ebin/' + module + '.beam'] = digest(release / 'ebin' / (module + '.beam'))

summaries = {}
for name in ['native-tests', 'native-release-tests', 'client-tests', 'eunit', 'ct']:
    log = re.sub(r'\x1b\[[0-9;]*m', '', (source / 'logs' / (name + '.log')).read_text(errors='replace'))
    summaries[name] = [line for line in log.splitlines() if re.search(
        r'^test result:|^\d+ tests, \d+ failures|^All \d+ tests passed|^ℹ (tests|pass|fail|skipped|cancelled) \d+', line)]
result = {
    'sealed_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'base_commit': freeze['base_commit'],
    'campaign': 'gates-03',
    'all_11_gates_passed': True,
    'frozen_input_count': len(manifest),
    'all_frozen_inputs_unchanged': True,
    'current_owned_scope_matches_frozen_tree': True,
    'user_document_unchanged': True,
    'summaries': summaries,
    'release_packaged_files': packaged,
    'deployed': False,
    'ledger_or_server_mutations': False,
}
(evidence / 'final-validation.json').write_text(json.dumps(result, indent=2) + '\n')
files = {str(path.relative_to(destination)): digest(path)
         for path in destination.rglob('*') if path.is_file()}
(destination / 'evidence-manifest.json').write_text(json.dumps(files, indent=2) + '\n')
print(json.dumps(result, indent=2))
