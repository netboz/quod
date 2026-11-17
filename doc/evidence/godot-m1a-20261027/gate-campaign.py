#!/usr/bin/env python3
"""Clean M1a gates, using only the exact qualified M0 dependency sources."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

p = argparse.ArgumentParser()
p.add_argument('label')
a = p.parse_args()
evidence = Path(__file__).resolve().parent
root = evidence.parents[2]
image = 'sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55'
stage = Path('/tmp') / ('quod-m1a-' + a.label)
stage.mkdir(mode=0o700, exist_ok=False)
work = stage / 'source'
work.mkdir()
(stage / 'tmp').mkdir()
names = subprocess.check_output(
    ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root
).decode().split('\0')
sources = {}
for name in sorted(set(names)):
    if not (name.startswith(('src/', 'include/', 'priv/', 'test/', 'config/',
                             'scripts/', 'client/', 'ui/', 'assets/', 'native/')) or
            name in ['rebar.config', 'rebar.lock', 'README.md', 'Dockerfile',
                     '.forgejo/workflows/gates.yml', 'deploy/ci/Dockerfile']):
        continue
    src = root / name
    if not src.is_file():
        continue
    dst = work / name
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    sources[name] = hashlib.sha256(dst.read_bytes()).hexdigest()

# This manifest's source/resource entries were independently verified against
# the current development dependency source. Copy exactly those entries,
# preserving symlinks, with no Rebar indexes or compiled/native artifacts.
prior = json.loads((root / 'doc/evidence/godot-m0-20261027/inputs/'
                   'r1-gates-06-source-manifest.json').read_text())['dependencies']
dep_source = Path('/tmp/quod-m1a-dev-01')
dependencies = {}
excluded_metadata = {}
for name, expected in prior.items():
    if name.startswith('_build/default/lib/.'):
        excluded_metadata[name] = expected
        continue
    src, dst = dep_source / name, work / name
    dst.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(expected, dict):
        assert src.is_symlink() and str(src.readlink()) == expected['symlink'], name
        target = src.readlink()
        assert not target.is_absolute(), name
        dst.symlink_to(target)
        assert dst.resolve().is_relative_to(work), name
    else:
        assert hashlib.sha256(src.read_bytes()).hexdigest() == expected, name
        shutil.copy2(src, dst)
    dependencies[name] = expected

def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')

record = dict(label=a.label, stage=str(stage), image=image,
              head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root).decode().strip(),
              branch=subprocess.check_output(['git', 'branch', '--show-current'], cwd=root).decode().strip(),
              worker_session='922c7c06-1acb-4c2b-9141-fccf4ab4c947',
              files=sources, dependency_sources=dependencies,
              excluded_derived_metadata=excluded_metadata, compiled_inputs_copied=False)
runner = evidence / 'inputs' / (a.label + '-gate-campaign.py')
shutil.copy2(__file__,runner)
record['runner_sha256'] = hashlib.sha256(runner.read_bytes()).hexdigest()
record['command_runner_sha256'] = hashlib.sha256((evidence/'run.py').read_bytes()).hexdigest()
write_json(evidence / 'inputs' / (a.label + '-source-manifest.json'), record)
write_json(stage / 'source-manifest.json', record)
gates = [('native', ['cargo', 'test', '--locked', '--manifest-path', 'native/quod_physics/Cargo.toml'], 900),
         ('eunit', ['rebar3', 'as', 'test', 'eunit', '-v'], 2400),
         ('ct', ['rebar3', 'as', 'test', 'ct'], 2400),
         ('xref', ['rebar3', 'xref'], 900),
         ('dialyzer', ['rebar3', 'dialyzer'], 1800),
         ('release', ['rebar3', 'as', 'prod', 'release'], 900)]
results = []
try:
    for gate, command, timeout in gates:
        docker = ['docker', 'run', '--rm', '--init', '--name', 'quod-m1a-' + a.label + '-' + gate,
                  '-v', str(work) + ':/work', '-v', str(stage / 'tmp') + ':/tmp',
                  '-v', str(evidence) + ':/evidence', '-w', '/work',
                  '-e', 'ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2',
                  '-e', 'REBAR_CACHE_DIR=/work/.cache/rebar3', '-e', 'CARGO_HOME=/work/.cache/cargo',
                  '-e', 'XDG_CACHE_HOME=/work/.cache/quod',
                  '-e', 'QUOD_M1A_EVIDENCE=/evidence/' + a.label + '-founding.json',
                  '--entrypoint', '/usr/bin/env', image] + command
        done = subprocess.run(['python3', str(evidence / 'run.py'), '--timeout', str(timeout),
                               a.label + '-' + gate, '--'] + docker, cwd=root)
        receipt = json.loads((evidence / 'logs' / (a.label + '-' + gate + '.json')).read_text())
        # Providers recompile these objects with different flags. Preserve each
        # provider's actual output before the next provider replaces it.
        profile = 'test' if gate in ('eunit', 'ct') else 'prod' if gate == 'release' else 'default'
        objects = {}
        for beam in sorted((work / '_build' / profile / 'lib/quod/ebin').glob('*.beam')):
            relative = beam.relative_to(work)
            retained = stage / 'gate-artifacts' / gate / relative
            retained.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(beam, retained)
            objects[str(relative)] = dict(path=str(retained), sha256=hashlib.sha256(beam.read_bytes()).hexdigest())
        write_json(evidence / 'inputs' / (a.label + '-' + gate + '-objects.json'), objects)
        results.append(receipt)
        if done.returncode:
            break
finally:
    unchanged = all((root / name).is_file() and
                    hashlib.sha256((root / name).read_bytes()).hexdigest() == digest and
                    hashlib.sha256((work / name).read_bytes()).hexdigest() == digest
                    for name, digest in sources.items())
    dependency_changes = {}
    for name, expected in dependencies.items():
        f = work / name
        actual = {'symlink': str(f.readlink())} if f.is_symlink() else hashlib.sha256(f.read_bytes()).hexdigest()
        if actual != expected:
            # Generated parser annotations remain separate from real source.
            dependency_changes[name] = dict(input=expected, output=actual)
    summary = dict(label=a.label, image=image, source_unchanged=unchanged,
                   completed_gates=len(results), required_gates=len(gates),
                   all_true_exits_zero=len(results) == len(gates) and
                       all(r['child_exit'] == 0 and not r['timed_out'] for r in results),
                   results=results, unrun=[g[0] for g in gates[len(results):]],
                   dependency_generated_changes=dependency_changes)
    write_json(evidence / (a.label + '-result.json'), summary)
    print(json.dumps({k: v for k, v in summary.items() if k not in ['results', 'dependency_generated_changes']}), flush=True)
if not unchanged or not summary['all_true_exits_zero']:
    raise SystemExit(1)
