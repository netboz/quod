import datetime, hashlib, json, os, pathlib, subprocess, sys, time

base = pathlib.Path('/home/yan/src/quod/_build/lobby-safety-20261016/release-gates-05')
tree = base/'tree'; logs = base/'logs'; logs.mkdir()
manifest = json.loads((base/'source-manifest.json').read_text())
def unchanged():
    return all(hashlib.sha256((tree/p).read_bytes()).hexdigest() == h for p,h in manifest.items())
commands = [('native-tests',['cargo','test','--locked','--manifest-path','native/quod_physics/Cargo.toml']), ('native-release-tests',['cargo','test','--release','--locked','--manifest-path','native/quod_physics/Cargo.toml']), ('native-clippy',['cargo','clippy','--locked','--manifest-path','native/quod_physics/Cargo.toml','--all-targets','--','-D','warnings']), ('client',['node','--test','--test-isolation=none']+[str(p.relative_to(tree)) for p in sorted((tree/'client/test').glob('*.test.js'))]),
    ('ui-build',['npm','--prefix','ui','run','build']),
    ('ui-lint',['npm','--prefix','ui','run','lint']),
    ('eunit',['rebar3','as','test','eunit']), ('ct',['rebar3','as','test','ct']),
    ('xref',['rebar3','xref']), ('dialyzer',['rebar3','dialyzer']), ('release',['rebar3','as','prod','release'])]
env = dict(os.environ, ERL_FLAGS='+S 4:4 +SDcpu 2 +SDio 2', CARGO_NET_OFFLINE='true', ERL_CRASH_DUMP=str(base/'erl-crash.dump'))
for key in ['LD_LIBRARY_PATH','LD_PRELOAD']: env.pop(key,None)
results = []
for name,args in commands:
    assert unchanged(), 'frozen source changed before '+name
    start = datetime.datetime.now(datetime.timezone.utc).isoformat(); clock = time.monotonic()
    print('Starting '+name, flush=True)
    with (logs/(name+'.log')).open('xb') as out:
        result = subprocess.run(args,cwd=tree,env=env,stdout=out,stderr=subprocess.STDOUT)
    row = {'name':name,'command':args,'started':start,'exit':result.returncode,
           'seconds':round(time.monotonic()-clock,2),'sources_unchanged':unchanged()}
    results.append(row); (base/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps(row),flush=True)
    if result.returncode or not row['sources_unchanged']:
        (base/'STOP.json').write_text(json.dumps(row,indent=2)+'\n');sys.exit(result.returncode or 1)
(base/'PASSED.json').write_text(json.dumps({'passed':True,'results':results},indent=2)+'\n')
