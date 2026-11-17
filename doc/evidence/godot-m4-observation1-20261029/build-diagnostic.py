#!/usr/bin/env python3
"""Source-only one-marker diagnostic export; reuse unchanged core/toolchain evidence."""
import difflib,hashlib,json,os,shutil,subprocess
from pathlib import Path

root=Path.cwd();ev=Path(__file__).resolve().parent
cache=Path('/home/yan/.cache/quod-m4-observation1-artifacts')
stage=cache/'client-quit-marker01';source=stage/'source'
prior=json.loads((root/'doc/evidence/godot-m4-r2-20261029/inputs/client-final03-manifest.json').read_text())
def h(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def write(path,value):path.write_text(json.dumps(value,indent=2)+'\n')
assert prior['passed'] and prior['distributable']
assert all(h(root/name)==sha for name,sha in prior['live_source_inputs'].items())
assert h(root/'client/godot/Main.cs')=='e9c010f71a9c1369fd5b451fe1d7fa275948089b3a96e69fe6d8f21b543fec1e'
assert shutil.disk_usage(cache.parent).free>900_000_000,'Insufficient capacity for isolated compile/export'
stage.mkdir(mode=0o700,parents=True,exist_ok=False);source.mkdir()
for name in prior['authored_inputs']:
    target=source/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/name,target)
main=source/'client/godot/Main.cs';before=main.read_text()
needle='GetTree().Quit(xrStopped ? exitCode : 1);'
assert before.count(needle)==1 and 'M4_QUIT_RETURNED' not in before
after=before.replace(needle,needle+'\n        GD.Print("M4_QUIT_RETURNED");')
main.write_text(after)
shutil.copy2(main,ev/'inputs/diagnostic-Main.cs')
(ev/'inputs/one-marker.patch').write_text(''.join(difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile='final03/Main.cs',tofile='diagnostic/Main.cs')))
inputs={name:h(source/name) for name in prior['authored_inputs']}
assert [name for name in inputs if inputs[name]!=prior['authored_inputs'][name]]==['client/godot/Main.cs']
feed=stage/'dependency-feed';feed.mkdir()
oldstage=Path(prior['stage']);engine_cache=source/'client/_build/godot-clean';engine_cache.mkdir(parents=True)
dependencies={}
for name,row in prior['dependency_archives'].items():
    original=oldstage/'dependency-feed'/name;assert h(original)==row['sha256']
    (feed/name).symlink_to(original.resolve());dependencies[name]={**row,'reused_archive':str(original.resolve())}
generic=oldstage/'source/client/_build/godot-clean'
for name in ['Godot_v4.7.2-stable_mono_linux_x86_64','templates']:
    assert (generic/name).is_dir();(engine_cache/name).symlink_to(generic/name)
(source/'NuGet.Config').write_text('<configuration><packageSources><clear/><add key="qualified" value="'+str(feed)+'"/></packageSources></configuration>\n')
temporary=stage/'temporary';temporary.mkdir(mode=0o700)
env=dict(os.environ,NUGET_PACKAGES=str(engine_cache/'nuget'),TMPDIR=str(temporary),PYTHONDONTWRITEBYTECODE='1')
env.pop('LD_LIBRARY_PATH',None);env.pop('LD_PRELOAD',None)
record={'source':str(source),'stage':str(stage),'authored_inputs':inputs,'live_source_inputs':prior['live_source_inputs'],
    'input_classes':prior['input_classes'],'distributable':False,'diagnostic_only':True,'marker':'M4_QUIT_RETURNED',
    'one_changed_input':'client/godot/Main.cs','compiled_application_inputs_copied':False,
    'generic_engine_and_templates_reused':str(generic),'engine_archives':prior['engine_archives'],
    'dependency_archives':dependencies,'core189_reused':True,'server1432_and_m3b_gates_reused':True,'commands':[],'passed':False}
manifest=ev/'inputs/diagnostic-build.json';write(manifest,record)
def run(phase,command,cwd,godot=False):
    wrapper=['python3',str(root/'client/native/tools/check.py')]
    if godot:wrapper+=['--godot']
    wrapper+=['--evidence',str(ev/('build-'+phase)),'--']+command
    record['commands'].append({'phase':phase,'command':command,'cwd':str(cwd)})
    child=subprocess.run(wrapper,cwd=cwd,env=env)
    record['commands'][-1]['wrapper_exit']=child.returncode;write(manifest,record)
    if child.returncode:raise SystemExit(child.returncode)
try:
    for configuration in ['Debug','ExportRelease']:
        run('restore-'+configuration.lower(),['dotnet','restore','Quod.csproj','--locked-mode','-p:Configuration='+configuration,'-p:SelfContained=true','--source',str(feed)],source/'client/godot')
    run('export',['python3','client/godot-tools/run.py','--export'],source,godot=True)
    record['export_outputs']={str(p.relative_to(source)):{'sha256':h(p),'bytes':p.stat().st_size} for p in sorted((source/'client/godot/dist').rglob('*')) if p.is_file()}
    assert len(record['export_outputs'])==196
    assert all(h(source/name)==sha for name,sha in inputs.items())
    assert all(h(root/name)==sha for name,sha in prior['live_source_inputs'].items())
    record.update(passed=True,export_executable=str(source/'client/godot/dist/quod.x86_64'),authored_inputs_unchanged=True)
finally:write(manifest,record)
print(json.dumps({'diagnostic_only':True,'supplied_inputs':len(inputs),'export_outputs':len(record.get('export_outputs',{})),'passed':record['passed']}))
