import datetime, hashlib, json, os, pathlib, re, shutil, subprocess, sys, tarfile, time

root=pathlib.Path('/home/yan/src/quod')
label=sys.argv[1]
base=root/'_build/world-library-20261016'/label
evidence=root/'doc/evidence/world-library-20261016'/label
tree=base/'tree'
base.mkdir(parents=True,exist_ok=False); evidence.mkdir(exist_ok=False); tree.mkdir()
shutil.copy2(__file__,evidence/'run-gates.py')
head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
with (base/'head.tar').open('xb') as out:
    subprocess.run(['git','archive',head],cwd=root,stdout=out,check=True)
with tarfile.open(base/'head.tar') as archive: archive.extractall(tree,filter='data')
(base/'head.tar').unlink()
changed=subprocess.check_output(['git','ls-files','-m','-o','--exclude-standard'],cwd=root,text=True).splitlines()
review_docs={'doc/voxel-world.md','doc/physics-native.md','doc/gui-examples.md','doc/multiwrite-architecture.md','AGENTS.md'}
owned=sorted({f for f in changed if f.split('/')[0] in {'src','include','priv','native','client','test','ui','scripts'} or f in review_docs})
for name in owned:
    target=tree/name
    if (root/name).exists():
        target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/name,target)
    elif target.exists(): target.unlink()
tracked=subprocess.check_output(['git','ls-tree','-r','--name-only',head],cwd=root,text=True).splitlines()
inputs=sorted({n for n in tracked+owned if (tree/n).is_file() and (not n.startswith(('doc/','priv/explorer/')) or n in review_docs)})
manifest={n:hashlib.sha256((tree/n).read_bytes()).hexdigest() for n in inputs}
(evidence/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
(evidence/'freeze.json').write_text(json.dumps({'head':head,'tree':str(tree),'label':label,
    'frozen_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'owned_changes':owned,
    'scope':'World-library composition and shared material admission validation; includes prior terrain work. No version bump, commit, deployment or live mutation.',
    'excluded':'User-owned transcript images and nimbalyst-local files; historical evidence.'},indent=2)+'\n')
for dep in (root/'_build/default/lib').iterdir():
    if dep.name!='quod' and dep.is_dir():
        shutil.copytree(dep,tree/'_build/default/lib'/dep.name,ignore=shutil.ignore_patterns('_build','*.beam'),symlinks=True)
for plt in (root/'_build/default').glob('*_plt*'):
    if plt.is_file(): shutil.copy2(plt,tree/'_build/default'/plt.name)
for relative in ['client/node_modules','ui/node_modules','native/quod_physics/target']:
    subprocess.run(['cp','-a','--reflink=auto',str(root/relative),str(tree/relative)],check=True)
env=dict(os.environ,PATH='/home/yan/.asdf/shims:/home/yan/.cargo/bin:'+os.environ['PATH'],
    ERL_FLAGS='+S 4:4 +SDio 2 +SDcpu 2',CARGO_NET_OFFLINE='true')
for key in ['DEBUG','LD_LIBRARY_PATH','LD_PRELOAD']: env.pop(key,None)
commands=[
 ('native-clean',['cargo','clean','--manifest-path','native/quod_physics/Cargo.toml','-p','quod_physics']),
 ('native-tests',['cargo','test','--locked','--manifest-path','native/quod_physics/Cargo.toml']),
 ('native-release-tests',['cargo','test','--release','--locked','--manifest-path','native/quod_physics/Cargo.toml']),
 ('native-clippy',['cargo','clippy','--locked','--manifest-path','native/quod_physics/Cargo.toml','--all-targets','--','-D','warnings']),
 ('client-tests',['npm','--prefix','client','test']),
 ('ui-build',['npm','--prefix','ui','run','build']),
 ('ui-lint',['npm','--prefix','ui','run','lint']),
 ('eunit',['rebar3','as','test','eunit','--verbose']),
 ('ct',['rebar3','as','test','ct']),
 ('xref',['rebar3','xref']),
 ('dialyzer',['rebar3','dialyzer']),
 ('release',['rebar3','as','prod','release'])]
def unchanged():
    return all((tree/n).is_file() and hashlib.sha256((tree/n).read_bytes()).hexdigest()==h for n,h in manifest.items())
results=[]
for name,args in commands:
    assert unchanged(), 'frozen source changed before '+name
    print('Starting '+name,flush=True)
    started=datetime.datetime.now(datetime.timezone.utc).isoformat();tick=time.monotonic()
    with (evidence/(name+'.log')).open('xb') as out:
        result=subprocess.run(args,cwd=tree,env=env,stdout=out,stderr=subprocess.STDOUT)
    row={'name':name,'command':args,'started':started,'exit':result.returncode,
         'seconds':round(time.monotonic()-tick,2),'sources_unchanged':unchanged()}
    completion = {
        'native-tests': r'test result: ok\. ([1-9][0-9]*) passed; 0 failed',
        'native-release-tests': r'test result: ok\. ([1-9][0-9]*) passed; 0 failed',
        'client-tests': r'ℹ pass ([1-9][0-9]*)\nℹ fail 0\nℹ cancelled 0',
        'eunit': r'All ([1-9][0-9]*) tests passed\.',
        'ct': r'All ([1-9][0-9]*) tests passed\.',
    }
    if name in completion:
        clean_log = re.sub(r'\x1b\[[0-9;]*m','',(evidence/(name+'.log')).read_text())
        summary = re.search(completion[name],clean_log)
        row['test_summary_complete'] = summary is not None
        if summary: row['passed_tests'] = int(summary.group(1))
    row['stop_requested'] = (evidence/'stop-request.json').exists()
    if name == 'ui-build' and result.returncode == 0:
        row['public_assets_preserved'] = all((tree/'priv/explorer'/p.relative_to(tree/'ui/public')).is_file() and hashlib.sha256(p.read_bytes()).digest() == hashlib.sha256((tree/'priv/explorer'/p.relative_to(tree/'ui/public')).read_bytes()).digest() for p in (tree/'ui/public').rglob('*') if p.is_file())
    (evidence/(name+'.json')).write_text(json.dumps(row,indent=2)+'\n')
    results.append(row);(evidence/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps(row),flush=True)
    if result.returncode or not row['sources_unchanged'] or row.get('public_assets_preserved') is False or row.get('test_summary_complete') is False or row['stop_requested']:
        (evidence/'STOP.json').write_text(json.dumps(row,indent=2)+'\n');sys.exit(result.returncode or 1)
(evidence/'PASSED.json').write_text(json.dumps({'passed':True,'sources_unchanged':True,'results':results},indent=2)+'\n')
