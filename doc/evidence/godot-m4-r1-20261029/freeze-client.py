#!/usr/bin/env python3
"""Build the final client from authored inputs and qualified dependency archives."""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path.cwd()
evidence = root / 'doc/evidence/godot-m4-r1-20261029'
label = sys.argv[1]
stage = Path('/home/yan/.cache/quod-m4-r1-artifacts/artifacts') / ('quod-m4-client-' + label)
storage = os.environ.get('QUOD_M4_BUILD_STORAGE')
actual_stage = Path(storage)/stage.name if storage else stage
actual_stage.mkdir(mode=0o700, parents=True, exist_ok=False)
if storage:stage.symlink_to(actual_stage)
source = stage / 'source'; source.mkdir()
inputs = {}
prefixes = ('client/godot/', 'client/godot-tests/', 'client/godot-tools/')
names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root).decode().split('\0')
needed = ['doc/evidence/godot-m0-20261027/inputs/godot-artifacts.json',
          'doc/evidence/godot-m0-20261027/production-protocol-fixtures.json',
          'doc/evidence/godot-m0-20261027/production-controller-reset-fixtures.json',
          'client/test/fixtures/native-contract/contracts.json', 'client/src/key-provider.js',
          'client/native/tools/check.py',
          'priv/explorer/assets/models/bd201855c8114b9b0e9cdd465d6f08413d18604894c839fb78d54d890c2adc94.glb',
          'doc/evidence/godot-m4-20261029/inputs/injected-mapping.term']
for name in sorted(set(n for n in names if n.startswith(prefixes)) | set(needed)):
    path = root / name
    if not path.is_file(): continue
    target = source / name; target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(path, target)
    inputs[name] = hashlib.sha256(path.read_bytes()).hexdigest()

feed = stage / 'dependency-feed'; feed.mkdir()
dependencies = {}
for package in sorted(Path('/home/yan/.cache/quod-m1b-artifacts/quod-m1b-client-corrective-02/dependency-feed').glob('*.nupkg')):
    target = feed / package.name
    assert not target.exists(), package
    target.symlink_to(package)
    dependencies[package.name] = {'sha256': hashlib.sha256(target.read_bytes()).hexdigest(), 'bytes': target.stat().st_size}
locks = [json.loads((source / 'client/godot' / name).read_text()) for name in
         ('packages.Debug.linux-x64.lock.json', 'packages.ExportRelease.linux-x64.lock.json')]

cache = source / 'client/_build/godot-clean'; cache.mkdir(parents=True)
artifacts = json.loads((source / needed[0]).read_text())
for row in artifacts:
    archive = root / 'client/_build/godot-clean' / row['name']
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == row['sha256']
    (cache / row['name']).symlink_to(archive)
config = '<configuration><packageSources><clear/><add key="qualified" value="' + str(feed) + '"/></packageSources></configuration>\n'
(source / 'NuGet.Config').write_text(config)
temporary=actual_stage/'temporary';temporary.mkdir(mode=0o700)
env = dict(os.environ, NUGET_PACKAGES=str(cache / 'nuget'),TMPDIR=str(temporary))
commands = []
def run(name, command, cwd=source, extra=None, godot=False):
    wrapper = ['python3', str(root / 'client/native/tools/check.py')]
    if godot: wrapper += ['--godot']
    wrapper += ['--evidence', str(evidence / ('client-' + label + '-' + name)), '--'] + command
    commands.append({'phase': name, 'command': command, 'cwd': str(cwd)})
    child = subprocess.run(wrapper, cwd=cwd, env=dict(env, **(extra or {})))
    if child.returncode: raise SystemExit(child.returncode)

record = {'label': label, 'stage': str(stage), 'source': str(source), 'authored_inputs': inputs,
          'actual_stage_storage':str(actual_stage),'temporary_publish_storage':str(temporary),
          'input_classes': {'client_source': sorted(n for n in inputs if n.startswith(prefixes) and not n.endswith('.uid')),
                            'generated_uid_seeds': sorted(n for n in inputs if n.endswith('.uid')),
                            'protocol_model_provider_fixtures': sorted(n for n in inputs if not n.startswith(prefixes))},
          'input_label_note': 'Legacy authored_inputs is the complete supplied input map, including persistent engine-generated UID seeds. input_classes distinguishes their origins.',
          'dependency_archives': dependencies, 'engine_archives': artifacts,
          'generated_nuget_config_sha256': hashlib.sha256(config.encode()).hexdigest(),
          'compiled_application_inputs_copied': False, 'dependency_archives_only': True, 'commands': commands}
manifest = evidence / 'inputs' / ('client-' + label + '-manifest.json')
manifest.write_text(json.dumps(record, indent=2) + '\n')
try:
    run('toolchain', ['dotnet', '--info'], cwd=source / 'client/godot')
    run('bootstrap', ['python3', 'client/godot-tools/run.py', '--bootstrap'])
    for configuration in ('Debug', 'ExportRelease'):
        run('restore-' + configuration.lower(), ['dotnet', 'restore', 'Quod.csproj', '--locked-mode', '-p:Configuration=' + configuration, '-p:SelfContained=true', '--source', str(feed)], cwd=source / 'client/godot')
    # NuGet's maintained signed-package reader computes the content hash during
    # this cold restore. It intentionally differs from the signed ZIP file hash.
    # Retain and independently check both meanings; never relabel one as the other.
    verified = {}
    for graph in locks:
        for framework in graph['dependencies'].values():
            for package, row in framework.items():
                directory = cache / 'nuget' / package.lower() / row['resolved']
                name = package.lower() + '.' + row['resolved'] + '.nupkg'
                archive = directory / name
                raw_hash = base64.b64encode(hashlib.sha512(archive.read_bytes()).digest()).decode()
                assert (directory / (name + '.sha512')).read_text().strip() == raw_hash, package
                assert hashlib.sha256(archive.read_bytes()).hexdigest() == dependencies[name]['sha256'], package
                metadata = json.loads((directory / '.nupkg.metadata').read_text())
                assert metadata['contentHash'] == row['contentHash'], package
                verified[name] = {'archive_sha512': raw_hash, 'locked_content_hash': metadata['contentHash']}
    record['cold_restored_package_hashes'] = verified
    record['nuget_hash_contract'] = 'https://github.com/NuGet/NuGet.Client/blob/dev/src/NuGet.Core/NuGet.Packaging/PackageArchiveReader.cs'
    run('export', ['python3', 'client/godot-tools/run.py', '--export'], godot=True)
    run('core-restore', ['dotnet', 'restore', 'Quod.Client.Tests.csproj', '--locked-mode', '--source', str(feed)], cwd=source / 'client/godot-tests')
    run('core', ['dotnet', 'run', '--project', 'client/godot-tests/Quod.Client.Tests.csproj', '--no-restore', '--', str(source), str(stage / 'public-backup.json')])
    outputs = {str(p.relative_to(source)): {'sha256': hashlib.sha256(p.read_bytes()).hexdigest(), 'bytes': p.stat().st_size}
               for p in sorted((source / 'client/godot/dist').rglob('*')) if p.is_file()}
    unchanged = all(hashlib.sha256((root / n).read_bytes()).hexdigest() == h and hashlib.sha256((source / n).read_bytes()).hexdigest() == h for n,h in inputs.items())
    assert unchanged
    record.update(passed=True, authored_inputs_unchanged=True, export_outputs=outputs,
                  export_executable=str(source / 'client/godot/dist/quod.x86_64'))
finally:
    record['commands'] = commands
    manifest.write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps({'stage': str(stage), 'authored_inputs': len(inputs), 'dependency_archives': len(dependencies), 'export_outputs': len(record.get('export_outputs', {})), 'passed': record.get('passed', False)}))
