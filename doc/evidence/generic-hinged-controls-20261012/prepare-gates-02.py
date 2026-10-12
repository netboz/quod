import datetime, hashlib, json, pathlib, shutil, subprocess, tarfile

root = pathlib.Path('/home/yan/src/quod')
base = root/'_build/quod-generic-hinged/gates-02'
tree = base/'tree'
base.mkdir(parents=True)
tree.mkdir()
head = subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
with (base/'head.tar').open('xb') as out:
    subprocess.run(['git','archive',head],cwd=root,stdout=out,check=True)
with tarfile.open(base/'head.tar') as archive:
    archive.extractall(tree,filter='data')
(base/'head.tar').unlink()
owned = ['native/quod_physics/src/lib.rs', 'native/quod_physics/src/geometry.rs', 'priv/ontologies/quod_physics.pl', 'priv/ontologies/quod_hinged.pl', 'src/quod_physics.erl', 'src/quod_physics_native.erl', 'src/quod_runtime.erl', 'test/quod_physics_tests.erl', 'test/fixtures/hinged-door.pl', 'test/fixtures/hinged-lid.pl', 'doc/physics-native.md', 'doc/world.md']
for name in owned:
    (tree/name).parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(root/name, tree/name)
tracked = subprocess.check_output(['git','ls-tree','-r','--name-only',head],cwd=root,text=True).splitlines()
inputs = sorted(set(name for name in tracked if not name.startswith(('doc/','priv/explorer/'))) | set(owned))
manifest = {name:hashlib.sha256((tree/name).read_bytes()).hexdigest() for name in inputs}
(base/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
(base/'freeze.json').write_text(json.dumps({'base_commit':head,'version':'0.7.263','purpose':'generic hinged implementation clean validation; no release label change or deployment','label_files':[],'frozen_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'owned_changes':owned,'excluded_user_changes':['doc/README.md','untracked sibling native-client/planning files'],'tree':str(tree)},indent=2)+'\n')
for dep in (root/'_build/default/lib').iterdir():
    if dep.name != 'quod' and dep.is_dir():
        shutil.copytree(dep,tree/'_build/default/lib'/dep.name,ignore=shutil.ignore_patterns('_build','*.beam'),symlinks=True)
for plt in (root/'_build/default').glob('*_plt*'):
    if plt.is_file(): shutil.copy2(plt,tree/'_build/default'/plt.name)
for area in ['client','ui']:
    subprocess.run(['cp','-a','--reflink=auto',str(root/area/'node_modules'),str(tree/area/'node_modules')],check=True)
subprocess.run(['cp','-a','--reflink=auto',str(root/'native/quod_physics/target'),str(tree/'native/quod_physics/target')],check=True)
with (base/'cargo-clean.log').open('xb') as out:
    cleaned=subprocess.run(['cargo','clean','--manifest-path',str(tree/'native/quod_physics/Cargo.toml'),'-p','quod_physics'],stdout=out,stderr=subprocess.STDOUT)
(base/'cargo-clean-exit.json').write_text(json.dumps({'exit':cleaned.returncode,'scope':'own package only; dependency caches retained'},indent=2)+'\n')
cleaned.check_returncode()
assert not list((tree/'_build/default/lib').rglob('*.beam'))
print(json.dumps({'freeze':str(base),'inputs':len(manifest),'owned_changes':owned}))
