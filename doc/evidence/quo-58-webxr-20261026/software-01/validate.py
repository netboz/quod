"""Sequential software checks; not the twelve-gate release qualification."""
import hashlib, json, os, pathlib, re, subprocess, time

root = pathlib.Path('/home/yan/src/quod')
out = pathlib.Path(__file__).resolve().parent
env = dict(os.environ)
for name in ['LD_LIBRARY_PATH', 'LD_PRELOAD', 'DEBUG']:
    env.pop(name, None)
names = set(subprocess.check_output(['rg', '--files', 'client/src', 'client/test', 'client/tools',
    'client/patches', 'ui'], cwd=root, text=True).splitlines())
names.update(['client/package.json', 'client/package-lock.json'])
patched = json.loads((root/'client/patches/babylon.json').read_text())
names.update('client/node_modules/@babylonjs/core/' + path for path in patched['files'])
manifest = {p: hashlib.sha256((root/p).read_bytes()).hexdigest() for p in sorted(names)}
(out/'source-checkpoint.json').write_text(json.dumps(manifest, indent=2)+'\n')
def unchanged():
    return all(hashlib.sha256((root/p).read_bytes()).hexdigest() == h for p,h in manifest.items())

commands = [('dependencies', ['node', 'client/tools/check-dependencies.mjs'])]
# Node 26's child-process reporter here summarizes files only. Run each file
# directly in its own process to retain every individual test and its true exit.
commands += [(p.stem, ['node', str(p.relative_to(root))]) for p in sorted((root/'client/test').glob('*.test.js'))]
commands += [('ui-build', ['npm', '--prefix', 'ui', 'run', 'build', '--', '--outDir',
    '/tmp/quo-58-owner-cleanup-qZXJVcsT/ui-build-final']), ('ui-lint', ['npm', '--prefix', 'ui', 'run', 'lint'])]
results = []
for name, command in commands:
    assert unchanged(), 'source changed before ' + name
    started = time.monotonic()
    with (out/(name+'.log')).open('xb') as log:
        child = subprocess.run(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
    row = {'name': name, 'command': command, 'exit': child.returncode,
           'seconds': round(time.monotonic()-started, 3), 'sources_unchanged': unchanged()}
    if name.endswith('.test'):
        content = re.sub(r'\x1b\[[0-9;]*m', '', (out/(name+'.log')).read_text())
        matched = re.search(r'ℹ pass (\d+)\nℹ fail 0\nℹ cancelled 0', content)
        row['passed_tests'] = int(matched[1]) if matched else None
    results.append(row)
    (out/'results.json').write_text(json.dumps(results, indent=2)+'\n')
    if child.returncode or not row['sources_unchanged'] or row.get('passed_tests', 1) is None:
        (out/'STOP.json').write_text(json.dumps(row, indent=2)+'\n')
        raise SystemExit(child.returncode or 1)
bundle = pathlib.Path('/tmp/quo-58-owner-cleanup-qZXJVcsT/ui-build-final')
assets = all((bundle/p.relative_to(root/'ui/public')).read_bytes() == p.read_bytes()
             for p in (root/'ui/public').rglob('*') if p.is_file())
assert assets
(out/'bundle-manifest.json').write_text(json.dumps({str(p.relative_to(bundle)): hashlib.sha256(p.read_bytes()).hexdigest()
    for p in sorted(bundle.rglob('*')) if p.is_file()}, indent=2)+'\n')
summary = {'passed': True, 'test_files': sum('passed_tests' in r for r in results),
    'tests': sum(r.get('passed_tests', 0) for r in results), 'public_assets_preserved': assets,
    'release_qualified': False, 'production_https_accepted': False, 'physical_accepted': False}
(out/'PASSED.json').write_text(json.dumps(summary, indent=2)+'\n')
print(json.dumps(summary))
