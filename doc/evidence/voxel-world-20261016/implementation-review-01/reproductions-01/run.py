import datetime, hashlib, json, os, pathlib, subprocess, time

root = pathlib.Path('/home/yan/src/quod')
directory = pathlib.Path(__file__).resolve().parent
tree = root / '_build/voxel-world-20261016/clean-gates-04/tree'
manifest = json.loads((directory.parent/'source-manifest.json').read_text())
def unchanged(base):
    return all((base/n).is_file() and hashlib.sha256((base/n).read_bytes()).hexdigest() == h for n,h in manifest.items())
assert unchanged(root) and unchanged(tree)
beam = directory/'beam'
beam.mkdir(exist_ok=False)
module = 'quod_physics_review_fixture'
source = (tree/'test/quod_physics_tests.erl').read_text()
source = source.replace('-module(quod_physics_tests).', '-module('+module+').', 1)
source += (directory/'checks.erl.fragment').read_text()
fixture = directory/(module+'.erl')
fixture.write_text(source)
expression = ('{ok,'+module+'} = compile:file("'+str(fixture)+'",[report,export_all,nowarn_export_all,{outdir,"'+str(beam)+'"}]), '
    'try A = '+module+':review_embedded_owner(), io:format("embedded_owner: ~p~n",[A]), '
    'B = '+module+':review_far_interest(), io:format("far_interest: ~p~n",[B]), halt(0) '
    'catch C:R:S -> io:format("FAILURE: ~p:~p~n~p~n",[C,R,S]),halt(1) end.')
paths = [str(p) for p in sorted((tree/'_build/test/lib').glob('*/ebin'))]
paths += [str(tree/'_build/test/lib/quod/test'),str(beam)]
arguments = ['erl','+S','4:4','+SDio','2','+SDcpu','2','-pa',*paths,'-noshell','-eval',expression]
env = dict(os.environ, PATH='/home/yan/.asdf/shims:'+os.environ['PATH'])
for key in ['DEBUG','LD_LIBRARY_PATH','LD_PRELOAD']: env.pop(key,None)
started = datetime.datetime.now(datetime.timezone.utc).isoformat()
tick = time.monotonic()
with (directory/'run.log').open('xb') as output:
    result = subprocess.run(arguments,cwd=tree,env=env,stdout=output,stderr=subprocess.STDOUT)
receipt = {'started':started,'finished':datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'child_exit':result.returncode,'seconds':round(time.monotonic()-tick,2),
    'purpose':'Characterize two reported defects through existing production owner/view seams; these are not correctness passes or fixes.',
    'frozen_sources_unchanged':unchanged(tree),'workspace_sources_unchanged':unchanged(root),
    'fixture_sha256':hashlib.sha256(fixture.read_bytes()).hexdigest(),'command':arguments}
(directory/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({k:v for k,v in receipt.items() if k!='command'}),flush=True)
raise SystemExit(result.returncode)
