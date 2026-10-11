import datetime, hashlib, json, os, pathlib, shutil, subprocess, sys, time

base=pathlib.Path('/home/yan/src/quod/_build/quod27-release-262/gates-02')
tree=base/'tree'; logs=base/'logs'; logs.mkdir()
manifest=json.loads((base/'source-manifest.json').read_text())
def unchanged():
    return all(hashlib.sha256((tree/name).read_bytes()).hexdigest()==digest for name,digest in manifest.items())
commands=[
 ('native-tests',['cargo','test','--locked','--manifest-path','native/quod_physics/Cargo.toml']),
 ('native-release-tests',['cargo','test','--release','--locked','--manifest-path','native/quod_physics/Cargo.toml']),
 ('native-clippy',['cargo','clippy','--locked','--manifest-path','native/quod_physics/Cargo.toml','--all-targets','--','-D','warnings']),
 ('client-tests',['npm','--prefix','client','test']),
 ('ui-build',['npm','--prefix','ui','run','build']),
 ('ui-lint',['npm','--prefix','ui','run','lint']),
 ('eunit',['rebar3','as','test','eunit']),
 ('ct',['rebar3','as','test','ct']),
 ('xref',['rebar3','xref']),
 ('dialyzer',['rebar3','dialyzer']),
 ('release',['rebar3','as','prod','release'])]
env=dict(os.environ,PATH='/home/yan/.asdf/shims:/home/yan/.cargo/bin:'+os.environ['PATH'],ERL_FLAGS='+S 4:4 +SDio 2 +SDcpu 2',CARGO_NET_OFFLINE='true')
for key in ['DEBUG','LD_LIBRARY_PATH','LD_PRELOAD']: env.pop(key,None)
tool_paths={name:shutil.which(name,path=env["PATH"]) for name in ["escript","erl","rebar3","cargo","npm"]}
assert all(tool_paths.values()), tool_paths
(base/"tool-paths.json").write_text(json.dumps(tool_paths,indent=2)+"\n")
results=[]
for name,args in commands:
    assert unchanged(), 'frozen input changed before '+name
    started=datetime.datetime.now(datetime.timezone.utc).isoformat(); start=time.monotonic()
    print('Starting '+name,flush=True)
    with (logs/(name+'.log')).open('xb') as out:
        result=subprocess.run(args,cwd=tree,env=env,stdout=out,stderr=subprocess.STDOUT)
    row={'name':name,'command':args,'started':started,'exit':result.returncode,'seconds':round(time.monotonic()-start,2),'sources_unchanged':unchanged()}
    (logs/(name+'.json')).write_text(json.dumps(row,indent=2)+'\n')
    results.append(row); (base/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps(row),flush=True)
    if result.returncode or not row['sources_unchanged']:
        (base/'STOP.json').write_text(json.dumps(row,indent=2)+'\n')
        sys.exit(result.returncode or 1)
outputs={str(p.relative_to(tree)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (tree/'priv/explorer').rglob('*') if p.is_file()}
(base/'explorer-manifest.json').write_text(json.dumps(outputs,indent=2)+'\n')
(base/'PASSED.json').write_text(json.dumps({'passed':True,'sources_unchanged':True,'results':results},indent=2)+'\n')
