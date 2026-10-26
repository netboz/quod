"""Fresh sequential release run after the retained sandbox socket refusal."""
import datetime, hashlib, json, os, pathlib, re, shutil, subprocess, sys, time
root = pathlib.Path('/home/yan/src/quod')
evidence = pathlib.Path(__file__).resolve().parent / 'release-gates-02'
evidence.mkdir(exist_ok=False)
prior = evidence.parent/'release-gates-01'
tree = root/'_build/quo-58-webxr-20261026/demo-01/release-tree-01'
manifest = json.loads((prior/'input-manifest.json').read_text())
sources = {n:h for n,h in manifest.items() if not n.startswith('priv/explorer/')}
assert all((tree/n).is_file() and hashlib.sha256((tree/n).read_bytes()).hexdigest()==h for n,h in sources.items())
for name in ['input-manifest.json','tested-changes.patch']:
    shutil.copy2(prior/name,evidence/name)
freeze=json.loads((prior/'freeze.json').read_text())
freeze['qualification_run']='02: unchanged frozen tree; run 01 EUnit could not bind its local TLS listener under the sandbox (eperm). All original evidence retained.'
(evidence/'freeze.json').write_text(json.dumps(freeze,indent=2)+'\n')
env = dict(os.environ, PATH='/home/yan/.asdf/shims:/home/yan/.cargo/bin:'+os.environ['PATH'],
           ERL_FLAGS='+S 4:4 +SDio 2 +SDcpu 2', CARGO_NET_OFFLINE='true',
           ERL_CRASH_DUMP=str(evidence/'erl_crash.dump'))
for name in ['DEBUG', 'LD_LIBRARY_PATH', 'LD_PRELOAD']: env.pop(name, None)
commands = [
    ('native-clean', ['cargo','clean','--manifest-path','native/quod_physics/Cargo.toml','-p','quod_physics']),
    ('native-tests', ['cargo','test','--locked','--manifest-path','native/quod_physics/Cargo.toml']),
    ('native-release-tests', ['cargo','test','--release','--locked','--manifest-path','native/quod_physics/Cargo.toml']),
    ('native-clippy', ['cargo','clippy','--locked','--manifest-path','native/quod_physics/Cargo.toml','--all-targets','--','-D','warnings']),
    ('client-tests', ['npm','--prefix','client','test']),
    ('ui-build', ['npm','--prefix','ui','run','build']),
    ('ui-lint', ['npm','--prefix','ui','run','lint']),
    ('eunit', ['rebar3','as','test','eunit','--verbose']),
    ('ct', ['rebar3','as','test','ct']),
    ('xref', ['rebar3','xref']),
    ('dialyzer', ['rebar3','dialyzer']),
    ('release', ['rebar3','as','prod','release']),
]
patterns = {
    'native-tests': r'test result: ok\. ([1-9][0-9]*) passed; 0 failed',
    'native-release-tests': r'test result: ok\. ([1-9][0-9]*) passed; 0 failed',
    'client-tests': r'(?:ℹ |# )pass ([1-9][0-9]*)\n(?:ℹ |# )fail 0\n(?:ℹ |# )cancelled 0',
    'eunit': r'All ([1-9][0-9]*) tests passed\.',
    'ct': r'All ([1-9][0-9]*) tests passed\.',
}
def unchanged():
    return all((tree/n).is_file() and hashlib.sha256((tree/n).read_bytes()).hexdigest()==h for n,h in sources.items())
results = []
for name, command in commands:
    assert unchanged(), 'source changed before '+name
    print('Starting '+name, flush=True)
    started = time.monotonic()
    intent = {'name': name, 'command': command, 'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    (evidence/(name+'.intent.json')).write_text(json.dumps(intent, indent=2)+'\n')
    with (evidence/(name+'.log')).open('xb') as log:
        child = subprocess.run(command, cwd=tree, env=env, stdout=log, stderr=subprocess.STDOUT)
    row = dict(intent, exit=child.returncode, seconds=round(time.monotonic()-started,2), sources_unchanged=unchanged())
    if name in patterns:
        content = re.sub(r'\x1b\[[0-9;]*m', '', (evidence/(name+'.log')).read_text())
        summary = re.search(patterns[name], content)
        row['test_summary_complete'] = summary is not None
        if summary: row['passed_tests'] = int(summary.group(1))
    if name == 'ui-build' and child.returncode == 0:
        row['public_assets_preserved'] = all((tree/'priv/explorer'/p.relative_to(tree/'ui/public')).read_bytes()==p.read_bytes() for p in (tree/'ui/public').rglob('*') if p.is_file())
    row['stop_requested'] = (evidence/'stop-request.json').exists()
    (evidence/(name+'.exit.json')).write_text(json.dumps(row, indent=2)+'\n')
    results.append(row)
    (evidence/'results.json').write_text(json.dumps(results, indent=2)+'\n')
    print(json.dumps(row), flush=True)
    if child.returncode or not row['sources_unchanged'] or row.get('test_summary_complete') is False or row.get('public_assets_preserved') is False or row['stop_requested']:
        (evidence/'STOP.json').write_text(json.dumps(row, indent=2)+'\n')
        sys.exit(child.returncode or 1)
bundle = {str(p.relative_to(tree)): hashlib.sha256(p.read_bytes()).hexdigest() for p in (tree/'priv/explorer').rglob('*') if p.is_file()}
(evidence/'bundle-manifest.json').write_text(json.dumps(bundle, indent=2)+'\n')
(evidence/'PASSED.json').write_text(json.dumps({'passed': True, 'results': results}, indent=2)+'\n')
