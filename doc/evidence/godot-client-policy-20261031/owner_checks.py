"""Finite policy-owner checks in the retained network-disabled Erlang image."""
import argparse, hashlib, json, os, shutil, subprocess
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('label')
p.add_argument('--test', default='answer_policy_checks')
p.add_argument('--affected', action='store_true')
a = p.parse_args()
os.umask(0o077)
root = Path.cwd()
ev = Path(__file__).resolve().parent
task = Path('/data/quod-m4-vr-ca84d4f8-20261029')
stage = task / 'private' / a.label
stage.mkdir(mode=0o700, exist_ok=False)
runtime = task / 'artifacts/server-runtime-restoration05'
inputs = {}

def copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    inputs[str(source)] = {'copy': str(destination),
        'sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
        'mode': destination.stat().st_mode}

modules = ['quod_material_admission', 'quod_proof_session', 'quod_scope_session',
           'quod_scope_wire', 'quod_wire_term', 'quod_ontology_name', 'quod_ask']
for module in modules:
    source = root / 'src' / ('predicates' if module == 'quod_ask' else '') / (module + '.erl')
    copy(source, stage / (module + '.erl'))
copy(ev / 'answer_policy_checks.erl', stage / 'answer_policy_checks.erl')
tests = ['answer_policy_checks']
if a.affected:
    for name in ['quod_proof_answer_tests', 'quod_material_admission_tests',
                 'quod_proof_session_tests', 'quod_scope_session_tests', 'quod_scope_wire_tests']:
        copy(root / 'test' / (name + '.erl'), stage / (name + '.erl'))
        tests.append(name)
copy(root / 'priv/ontologies/material_policy.pl', stage / 'material_policy.pl')
for header in (root / 'include').glob('*.hrl'):
    copy(header, stage / 'include' / header.name)
qualified = json.loads((root / 'doc/evidence/godot-space-stage2-20261031/inputs/stage2-owner-final02.json').read_text())
header = next(v for n, v in qualified['inputs'].items() if n.endswith('/erlog_int.hrl'))
library = Path(header['copy']).parents[2]
if a.affected:
    for f in (root / '_build/default/lib/opentelemetry/include').glob('*.hrl'):
        copy(f, stage / 'lib/opentelemetry/include' / f.name)
    copy(runtime / '_build/prod/lib/opentelemetry/ebin/opentelemetry.app',
         stage / 'lib/opentelemetry/ebin/opentelemetry.app')
expression = ''.join(
    f'{{ok,{m}}}=compile:file("/input/{m}.erl",[report_errors,report_warnings,{{d,\'TEST\'}},{{i,"/input/include"}},{{outdir,"/input"}}]),'
    for m in modules + tests)
selected = '[' + ','.join(tests) + ']' if a.affected else a.test
expression += f'case eunit:test({selected},[verbose]) of ok->halt(0);error->halt(1) end.'
command = ['docker', 'run', '--rm', '--network', 'none', '--user', f'{os.getuid()}:{os.getgid()}',
    '-v', str(runtime) + ':/work:ro', '-v', str(stage) + ':/input',
    '-v', str(stage / 'material_policy.pl') + ':/work/_build/prod/lib/quod/priv/ontologies/material_policy.pl:ro',
    '-v', str(library) + ':/compiler:ro', '-w', '/input',
    '-e', 'ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2', '-e', 'ERL_CRASH_DUMP=/input/erl_crash.dump',
    '--entrypoint', '/bin/sh', 'sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55',
    '-c', 'exec erl -noshell -pa /work/_build/prod/lib/*/ebin /work/_build/test/lib/quod/test /compiler/erlog/ebin /input/lib/*/ebin /input -eval "$1"',
    'sh', expression]
record = {'command': command, 'inputs': inputs, 'network': 'none', 'hardware': False}
result = subprocess.run(command)
record.update(true_exit=result.returncode, passed=result.returncode == 0)
record['objects'] = {f.name: {'sha256': hashlib.sha256(f.read_bytes()).hexdigest(),
    'bytes': f.stat().st_size} for f in stage.glob('*.beam')}
(ev / 'inputs').mkdir(exist_ok=True)
(ev / 'inputs' / (a.label + '.json')).write_text(json.dumps(record, indent=2) + '\n')
raise SystemExit(result.returncode)
