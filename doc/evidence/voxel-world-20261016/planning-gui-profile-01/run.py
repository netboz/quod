import datetime, hashlib, json, os, pathlib, subprocess, time

root = pathlib.Path('/home/yan/src/quod')
directory = pathlib.Path(__file__).resolve().parent
tree = root / '_build/voxel-world-20261016/clean-gates-04/tree'
manifest = json.loads((root / 'doc/evidence/voxel-world-20261016/clean-gates-04/source-manifest.json').read_text())
def unchanged(base):
    return all((base/n).is_file() and hashlib.sha256((base/n).read_bytes()).hexdigest() == h for n,h in manifest.items())
assert unchanged(root) and unchanged(tree)
beam = directory / 'beam'
beam.mkdir(exist_ok=False)
module = 'quod_gui_minimal_profile_review'
fixture = directory / (module + '.erl')
expression = ('{ok,' + module + '} = compile:file("' + str(fixture) + '",[report,{outdir,"' + str(beam) + '"}]), '
              'Result = eunit:test({generator,fun ' + module + ':voxel_form_creates_user_owned_terrain_and_rejects_a_dig_stale_submission_test_/0},[verbose]), '
              'case Result of ok -> halt(0); _ -> halt(1) end.')
paths = [str(p) for p in sorted((tree/'_build/test/lib').glob('*/ebin'))]
paths.extend([str(tree/'_build/test/lib/quod/test'), str(beam)])
arguments = ['erl', '+S', '4:4', '+SDio', '2', '+SDcpu', '2', '-pa', *paths, '-noshell', '-eval', expression]
env = dict(os.environ, PATH='/home/yan/.asdf/shims:' + os.environ['PATH'])
for key in ['DEBUG','LD_LIBRARY_PATH','LD_PRELOAD']: env.pop(key,None)
started = datetime.datetime.now(datetime.timezone.utc).isoformat()
tick = time.monotonic()
with (directory/'run.log').open('xb') as output:
    result = subprocess.run(arguments, cwd=tree, env=env, stdout=output, stderr=subprocess.STDOUT)
receipt = {'started':started,'finished':datetime.datetime.now(datetime.timezone.utc).isoformat(),
           'child_exit':result.returncode,'seconds':round(time.monotonic()-tick,2),
           'frozen_sources_unchanged':unchanged(tree),'workspace_sources_unchanged':unchanged(root),
           'command':arguments}
(directory/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt),flush=True)
raise SystemExit(result.returncode)
