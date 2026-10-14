import hashlib, json, pathlib, shutil, subprocess

root = pathlib.Path('/home/yan/src/quod')
base = root / '_build/ontology-eidolons-20261014/gates-01'
tree = base / 'tree'
tree.mkdir(parents=True)
excluded = shutil.ignore_patterns('node_modules', '_build', 'target', '.git', 'dist')
for name in ['src', 'include', 'test', 'client', 'ui', 'scripts', 'native', 'config', 'priv']:
    shutil.copytree(root/name, tree/name, ignore=excluded, symlinks=True)
for name in ['AGENTS.md', 'rebar.config', 'rebar.lock', 'Makefile', '.tool-versions']:
    if (root/name).exists(): shutil.copy2(root/name, tree/name)
for name in ['world.md', 'multiwrite-architecture.md', 'system-ontology-acls.md', 'spaces.md', 'ontology-eidolons-plan.md']:
    (tree/'doc').mkdir(exist_ok=True)
    shutil.copy2(root/'doc'/name, tree/'doc'/name)
inputs = [p for p in tree.rglob('*') if p.is_file() and not p.is_symlink()
          and not str(p.relative_to(tree)).startswith('priv/explorer/') and p.suffix != '.so']
manifest = {str(p.relative_to(tree)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
(base/'source-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
(base/'freeze.json').write_text(json.dumps({'purpose': 'Uncommitted ontology Eidolon implementation review; no deployment or label bump',
    'head': subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
    'working_tree': 'Includes existing user-owned source changes as integration context.',
    'input_count': len(manifest)},indent=2)+'\n')
for dep in (root/'_build/default/lib').iterdir():
    if dep.name != 'quod' and dep.is_dir():
        shutil.copytree(dep, tree/'_build/default/lib'/dep.name,
            ignore=shutil.ignore_patterns('_build','*.beam'), symlinks=True)
for plt in (root/'_build/default').glob('*_plt*'):
    if plt.is_file(): shutil.copy2(plt, tree/'_build/default'/plt.name)
for source, destination in [(root/'ui/node_modules',tree/'ui/node_modules'),
        (root/'client/node_modules',tree/'client/node_modules'),
        (root/'native/quod_physics/target',tree/'native/quod_physics/target')]:
    subprocess.run(['cp','-a','--reflink=auto',str(source),str(destination)],check=True)
print(json.dumps({'tree':str(tree),'inputs':len(manifest)}))
