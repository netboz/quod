import datetime, hashlib, json, pathlib, shutil, subprocess, tarfile

root = pathlib.Path('/home/yan/src/quod')
base = root/'_build/quod27-release-259/gates-01'
tree = base/'tree'
base.mkdir(parents=True)
tree.mkdir()
head = subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
with (base/'head.tar').open('xb') as out:
    subprocess.run(['git','archive',head],cwd=root,stdout=out,check=True)
with tarfile.open(base/'head.tar') as archive:
    archive.extractall(tree,filter='data')
(base/'head.tar').unlink()
owned = ['client/src/signed-client.js', 'client/test/signed-client.test.js', 'include/quod_proof_limits.hrl', 'priv/ontologies/quod_root.pl', 'src/quod_client_result.erl', 'src/quod_effect_journal.erl', 'src/quod_metrics.erl', 'src/quod_ontology.erl', 'src/quod_runtime.erl', 'src/quod_scope_wire.erl', 'test/quod_ask_SUITE.erl', 'test/quod_client_result_tests.erl', 'test/quod_effect_journal_tests.erl', 'test/quod_lifecycle_single_path_tests.erl', 'test/quod_node_context_tests.erl', 'test/quod_resource_lifecycle_tests.erl', 'test/quod_root_resource_lifecycle_tests.erl', 'test/quod_scope_wire_tests.erl']
for name in owned:
    shutil.copy2(root/name, tree/name)
for name in ["rebar.config", "src/quod.app.src"]:
    old=(tree/name).read_text()
    assert old.count("0.7.258") == 1, name
    (tree/name).write_text(old.replace("0.7.258", "0.7.259"))
tracked = subprocess.check_output(['git','ls-tree','-r','--name-only',head],cwd=root,text=True).splitlines()
inputs = [name for name in tracked if not name.startswith(('doc/','priv/explorer/'))]
manifest = {name:hashlib.sha256((tree/name).read_bytes()).hexdigest() for name in inputs}
(base/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
(base/'freeze.json').write_text(json.dumps({'base_commit':head,'version':'0.7.259','purpose':'candidate release 259; implementation frozen with proposed separate version label','label_files':['rebar.config','src/quod.app.src'],'frozen_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'owned_changes':owned,'excluded_user_changes':['doc/README.md','untracked sibling native-client/planning files'],'tree':str(tree)},indent=2)+'\n')
for dep in (root/'_build/default/lib').iterdir():
    if dep.name != 'quod' and dep.is_dir():
        shutil.copytree(dep,tree/'_build/default/lib'/dep.name,ignore=shutil.ignore_patterns('_build','*.beam'),symlinks=True)
for plt in (root/'_build/default').glob('*_plt*'):
    if plt.is_file(): shutil.copy2(plt,tree/'_build/default'/plt.name)
for area in ['client','ui']:
    subprocess.run(['cp','-a','--reflink=auto',str(root/area/'node_modules'),str(tree/area/'node_modules')],check=True)
subprocess.run(['cp','-a','--reflink=auto',str(root/'native/quod_physics/target'),str(tree/'native/quod_physics/target')],check=True)
assert not list((tree/'_build/default/lib').rglob('*.beam'))
print(json.dumps({'freeze':str(base),'inputs':len(manifest),'owned_changes':owned}))
