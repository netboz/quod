"""Sequential release qualification of unrestricted tracked viewing."""
import datetime, hashlib, json, os, pathlib, re, shutil, subprocess, sys, time

root = pathlib.Path('/home/yan/src/quod')
evidence = pathlib.Path(__file__).resolve().parent / 'release-gates-04'
tree = root / '_build/quo-58-webxr-20261026/view-correction-01/release-tree-04'
evidence.mkdir(exist_ok=False)
tree.mkdir(parents=True, exist_ok=False)
head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
assert head == 'de1e9af4ad230f021887faca27efc89e97b7189a'
patch = subprocess.check_output(['git', 'diff', '--binary'], cwd=root)
assert not subprocess.check_output(['git','diff','--cached','--name-only'], cwd=root)
(evidence/'tested-changes.patch').write_bytes(patch)
names = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
roots = {'src', 'include', 'priv', 'native', 'client', 'test', 'ui', 'scripts', 'config', 'deploy'}
inputs = [n for n in names if n and (n.split('/')[0] in roots or '/' not in n)]
for name in inputs:
    target = tree / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / name, target)
manifest = {n: hashlib.sha256((tree/n).read_bytes()).hexdigest() for n in inputs}
(evidence/'input-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
sources = {n: h for n, h in manifest.items() if not n.startswith('priv/explorer/')}
prior = json.loads((evidence.parent/'release-gates-03/input-manifest.json').read_text())
prior_sources = {n:h for n,h in prior.items() if not n.startswith('priv/explorer/')}
changed = sorted(n for n in set(sources) | set(prior_sources) if sources.get(n) != prior_sources.get(n))
assert changed == ['test/quod_ct.erl', 'test/quod_space_creation_tests.erl'], changed
(evidence/'changes-since-failed-gate.json').write_text(json.dumps(changed, indent=2)+'\n')
(evidence/'freeze.json').write_text(json.dumps({
    'revision': head, 'tree': str(tree), 'frozen_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'scope': 'QUO-58/QUO-24 unrestricted tracked-view correction; prior failed demo evidence is preserved. Includes the explicitly recorded pre-existing tracked server working changes. Committed controller assets and dependency patch are included. No ledger mutation in this runner.',
    'working_patch_sha256': hashlib.sha256(patch).hexdigest(),
    'production_edits_since_failed_gate': False, 'fixture_cleanup_regressions': True, 'atomic_completion_wait_regression': True, 'user_untracked_files_excluded': True, 'controller_assets_committed': True,
}, indent=2)+'\n')
print('Frozen '+head, flush=True)
for dep in (root/'_build/default/lib').iterdir():
    if dep.name != 'quod' and dep.is_dir():
        shutil.copytree(dep, tree/'_build/default/lib'/dep.name,
                        ignore=shutil.ignore_patterns('_build', '*.beam'), symlinks=True)
for plt in (root/'_build/default').glob('*_plt*'):
    if plt.is_file(): shutil.copy2(plt, tree/'_build/default'/plt.name)
for name in ['client/node_modules', 'ui/node_modules', 'native/quod_physics/target']:
    subprocess.run(['cp', '-a', '--reflink=auto', str(root/name), str(tree/name)], check=True)
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
