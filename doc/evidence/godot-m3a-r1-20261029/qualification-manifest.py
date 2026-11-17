#!/usr/bin/env python3
"""Index one retained clean M3a build, separating source, generated metadata and binaries."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

evidence = Path(__file__).resolve().parent
root = evidence.parents[2]
label = sys.argv[1]
inputs = json.loads((evidence / 'inputs' / (label + '-source-manifest.json')).read_text())
work = Path(inputs['stage']) / 'source'
output = evidence / 'inputs' / (label + '-compiled-manifest.json')
assert not output.exists(), 'Retain previous manifests; use a new campaign label'

def entry(path):
    if path.is_symlink():
        return {'symlink': str(path.readlink())}
    if path.is_dir(): return {'directory': True, 'mode': path.stat().st_mode & 0o777}
    return {'bytes': path.stat().st_size, 'mode': path.stat().st_mode & 0o777,
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}

live_names = {p for p, h in inputs['files'].items()
              if (root / p).is_file() and hashlib.sha256((root / p).read_bytes()).hexdigest() == h}
assert live_names == set(inputs['files']), 'Authored gate inputs changed'
all_names = subprocess.check_output(
    ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root
).decode().split('\0')
specifications={n for n in inputs['files'] if n.startswith('doc/')}
selected = {name for name in all_names if (root / name).is_file() and
            not name.startswith(('client/godot/', 'client/godot-tests/', 'client/godot-tools/')) and
            (name in specifications or name.startswith(('src/', 'include/', 'priv/', 'test/', 'config/', 'scripts/',
                              'client/', 'ui/', 'assets/', 'native/')) or
             name in ['rebar.config', 'rebar.lock', 'README.md', 'Dockerfile',
                      '.forgejo/workflows/gates.yml', 'deploy/ci/Dockerfile'])}
assert selected == set(inputs['files']), 'Authored gate paths added or removed'
for p, h in inputs['files'].items():
    assert hashlib.sha256((work / p).read_bytes()).hexdigest() == h, p

dependencies, generated_changes = {}, {}
for name, expected in inputs['dependency_sources'].items():
    path = work / name
    actual = entry(path)
    dependencies[name] = actual
    comparable = actual if 'symlink' in actual else actual['sha256']
    if comparable != expected:
        generated_changes[name] = {'input': expected, 'output': actual}
        dst = evidence / 'inputs' / (label + '-generated') / name
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, dst)

generated_parsers = {}
for grammar, expected in inputs['dependency_sources'].items():
    if not grammar.endswith(('.yrl', '.xrl')):
        continue
    generated = grammar[:-4] + '.erl'
    if generated not in dependencies:
        continue
    text = (work / generated).read_text(errors='replace')
    generated_parsers[generated] = dict(grammar=grammar, grammar_input=expected,
        generated_input=inputs['dependency_sources'][generated], output=dependencies[generated],
        annotations=[line for line in text.splitlines() if line.startswith('-file(')])
authored_dependencies = {name: value for name, value in dependencies.items()
                         if name not in generated_parsers}
assert set(generated_changes) <= set(generated_parsers), 'Authored dependency input changed during qualification'
(evidence / 'inputs' / (label + '-dependency-sources.json')).write_text(
    json.dumps(authored_dependencies, indent=2) + '\n')
(evidence / 'inputs' / (label + '-generated-parser-sources.json')).write_text(
    json.dumps(generated_parsers, indent=2) + '\n')

compiled, derived_indexes = {}, {}
for path in sorted((work / '_build').rglob('*')):
    if not (path.is_file() or path.is_symlink()):
        continue
    name = str(path.relative_to(work))
    if path.suffix in ('.beam', '.so', '.app', '.boot', '.rel', '.script'):
        compiled[name] = entry(path)
    elif '.rebar3/' in name or path.name.endswith(('_plt', '_plt.hash')):
        derived_indexes[name] = entry(path)
for cache in [work/'.cache/rebar3',work/'.cache/quod']:
    for path in sorted(cache.rglob('*')):
        if path.is_file() and path.name.endswith(('_plt','_plt.hash')):
            derived_indexes[str(path.relative_to(work))]=entry(path)
native = {str(path.relative_to(work)): entry(path)
          for path in sorted((work / 'priv').rglob('*.so'))}

release_root=work/'_build/prod/rel/quod'
assert release_root.is_dir(), 'The required local production release is absent'
release_package={str(path.relative_to(work)): entry(path)
                 for path in [release_root]+sorted(release_root.rglob('*'))}
assert not any('/outdated/' in name for name in release_package)

common = {name: digest for name, digest in inputs['files'].items()
          if name.startswith(('src/', 'include/')) or
          name in ['priv/ontologies/common_predicates.pl', 'priv/ontologies/construction.pl',
                   'priv/ontologies/material_policy.pl', 'priv/ontologies/gui_forms.pl',
                   'priv/ontologies/geometry_schema.pl']}
locks = {name: digest for name, digest in inputs['files'].items()
         if Path(name).name in ['rebar.lock', 'Cargo.lock', 'package-lock.json', 'yarn.lock',
                               'packages.lock.json', 'global.json']}
dependency_apps = sorted({Path(name).parts[3] for name in dependencies})
compiled_apps = {name: value for name, value in compiled.items() if name.endswith('.app')}
result = dict(label=label, image=inputs['image'], authored_inputs_unchanged=True,
              dependency_sources=authored_dependencies,
              generated_parser_sources=generated_parsers,
              generated_dependency_changes=generated_changes,
              derived_rebar_indexes=derived_indexes, compiled_outputs=compiled,
              native_packaged_outputs=native, packaged_release_outputs=release_package,
              runtime_common_sources=common, locks=locks,
              dependency_app_names=dependency_apps, compiled_app_resources=compiled_apps,
              compiled_input_reused=False,
              counts=dict(authored_inputs=len(inputs['files']), dependency_input_entries=len(dependencies),
                          dependency_authored_source_entries=len(authored_dependencies),
                          generated_parser_source_entries=len(generated_parsers),
                          generated_dependency_changes=len(generated_changes),
                          dependency_apps=len(dependency_apps),
                          derived_rebar_indexes=len(derived_indexes), compiled_outputs=len(compiled),
                          packaged_release_entries=len(release_package)))
output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result['counts']))
