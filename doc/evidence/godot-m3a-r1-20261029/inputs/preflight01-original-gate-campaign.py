#!/usr/bin/env python3
"""Clean M3a gates from authored source and preserved dependency archives."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess

p = argparse.ArgumentParser()
p.add_argument('label')
p.add_argument('--generator', help='Run only this focused EUnit generator; not a full clean qualification')
a = p.parse_args()
evidence = Path(__file__).resolve().parent
root = evidence.parents[2]
image = 'sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55'
stage = Path('/tmp/quod-m3a-r1-8d55a3f3') / ('m3a-r1-' + a.label)
stage.mkdir(mode=0o700, exist_ok=False)
work = stage / 'source'
work.mkdir()
(stage / 'tmp').mkdir()
names = subprocess.check_output(
    ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root
).decode().split('\0')
sources = {}
specifications = set(subprocess.check_output(['git','diff','--name-only','HEAD'],cwd=root,text=True).splitlines())
specifications = {n for n in specifications if n.startswith('doc/') and not n.startswith('doc/evidence/')}
for name in sorted(set(names)):
    # These independently built .NET client inputs never enter the server gates.
    if name.startswith(('client/godot/', 'client/godot-tests/', 'client/godot-tools/')):
        continue
    if not (name in specifications or name.startswith(('src/', 'include/', 'priv/', 'test/', 'config/',
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

# Exact preserved source/resource archive; no Rebar indexes or compiled inputs.
import tarfile
snapshot=Path('/home/yan/.cache/quod-m2-artifacts/quod-godot-m2-handoff-8db34a85-20261028-01')
dependencies=json.loads((snapshot/'dependency-inputs.json').read_text())
with tarfile.open(snapshot/'dependency-inputs.tar.gz') as archive:
    archive.extractall(work,filter='data')
cargo = json.loads((snapshot/'cargo-inputs.json').read_text())
for artifact in ['cargo-package-inputs.tar.gz','cargo-index-metadata.tar.gz']:
    with tarfile.open(snapshot/artifact) as archive:
        archive.extractall(work,filter='data')
for name, expected in cargo['packages'].items():
    assert hashlib.sha256((work/name).read_bytes()).hexdigest() == expected['sha256'], name
assert hashlib.sha256((work/'native/quod_physics/Cargo.lock').read_bytes()).hexdigest() == cargo['cargo_lock_sha256']
excluded_metadata={}
for name, expected in dependencies.items():
    path=work/name
    actual={'symlink':str(path.readlink())} if path.is_symlink() else hashlib.sha256(path.read_bytes()).hexdigest()
    assert actual==expected,name

def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')

record = dict(label=a.label, stage=str(stage), image=image,
              head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root).decode().strip(),
              branch=subprocess.check_output(['git', 'branch', '--show-current'], cwd=root).decode().strip(),
              worker_session='8d55a3f3-e558-46e2-afbb-2e028558f371',
              files=sources, dependency_sources=dependencies, cargo_package_inputs=cargo['packages'],
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
if a.generator:
    gates = [('eunit', ['rebar3','as','test','eunit','-v','--generator='+a.generator],2400)]
results = []
try:
    for gate, command, timeout in gates:
        docker = ['docker', 'run', '--rm', '--init', '--name', 'quod-m3a-r1-' + a.label + '-' + gate,
                  '-v', str(work) + ':/work', '-v', str(stage / 'tmp') + ':/tmp',
                  '-v', str(evidence) + ':/evidence', '-w', '/work',
                  '-e', 'ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2',
                  '-e', 'REBAR_CACHE_DIR=/work/.cache/rebar3', '-e', 'CARGO_HOME=/work/.cache/cargo',
                  '-e', 'CARGO_NET_OFFLINE=true',
                  '-e', 'XDG_CACHE_HOME=/work/.cache/quod',
                  '-e', 'QUOD_M1A_EVIDENCE=/evidence/' + a.label + '-founding.json',
                  '-e', 'QUOD_M3A_EVIDENCE=/evidence/' + a.label,
                  '--entrypoint', '/usr/bin/env', image] + command
        done = subprocess.run(['python3', str(evidence / 'run.py'), '--timeout', str(timeout),
                               a.label + '-' + gate, '--'] + docker, cwd=root)
        receipt = json.loads((evidence / 'logs' / (a.label + '-' + gate + '.json')).read_text())
        # Providers recompile these objects with different flags. Preserve each
        # provider's actual output before the next provider replaces it.
        profile = 'test' if gate in ('eunit', 'ct') else 'prod' if gate == 'release' else 'default'
        objects = {}
        for beam in sorted((work / '_build' / profile / 'lib/quod').rglob('*.beam')):
            relative = beam.relative_to(work)
            retained = stage / 'gate-artifacts' / gate / relative
            retained.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(beam, retained)
            objects[str(relative)] = dict(path=str(retained), sha256=hashlib.sha256(beam.read_bytes()).hexdigest())
        native = work / 'priv/native/quod_physics.so'
        if native.exists():
            retained = stage / 'gate-artifacts' / gate / 'priv/native/quod_physics.so'
            retained.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(native,retained)
            objects['priv/native/quod_physics.so'] = dict(path=str(retained),sha256=hashlib.sha256(native.read_bytes()).hexdigest())
        write_json(evidence / 'inputs' / (a.label + '-' + gate + '-objects.json'), objects)
        text = (evidence / 'logs' / (a.label + '-' + gate + '.log')).read_text(errors='replace')
        completion = {
            'native': r'test result: ok\. [1-9][0-9]* passed; 0 failed',
            'eunit': r'All [1-9][0-9]* tests passed',
            'ct': r'All [1-9][0-9]* tests passed'}
        receipt['completion_confirmed'] = gate not in completion or bool(re.search(completion[gate], text))
        write_json(evidence / 'logs' / (a.label + '-' + gate + '.json'), receipt)
        results.append(receipt)
        stopped = (evidence / (a.label + '-stop.md')).exists()
        if done.returncode or stopped or not receipt['completion_confirmed']:
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
    stopped = (evidence / (a.label + '-stop.md')).exists()
    summary = dict(label=a.label, image=image, source_unchanged=unchanged,
                   kind='focused generator; not full qualification' if a.generator else 'clean sequential qualification',
                   explicitly_stopped=stopped,
                   completed_gates=len(results), required_gates=len(gates),
                   all_true_exits_zero=not stopped and len(results) == len(gates) and
                       all(r['child_exit'] == 0 and not r['timed_out'] and not r.get('error_diagnostics',0) and r.get('completion_confirmed',False) for r in results),
                   results=results, unrun=[g[0] for g in gates[len(results):]],
                   dependency_generated_changes=dependency_changes)
    write_json(evidence / (a.label + '-result.json'), summary)
    print(json.dumps({k: v for k, v in summary.items() if k not in ['results', 'dependency_generated_changes']}), flush=True)
if not unchanged or not summary['all_true_exits_zero']:
    raise SystemExit(1)
