"""Fresh source-only C# application; the private native template is a dependency."""
import base64,hashlib,json,os,shutil,subprocess,sys
from pathlib import Path
from environment import TASK,environment
root=Path.cwd();ev=Path(__file__).resolve().parent
label=sys.argv[1];template=Path(sys.argv[2]);assert template.is_file();physical=sys.argv[3:]==['--physical'];assert physical;observer=False
stage=TASK/'artifacts'/('client-'+label);stage.mkdir(parents=True,exist_ok=False)
source=stage/'source';source.mkdir();manifest=json.loads((root/'doc/evidence/godot-m4-r2-20261029/inputs/client-final03-manifest.json').read_text())
inputs=dict(manifest['authored_inputs']);live_inputs=dict(inputs);overrides={}
for name,digest in inputs.items():
    p=root/name;assert hashlib.sha256(p.read_bytes()).hexdigest()==digest,name
    target=source/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target)
if observer:
    name='client/godot/project.godot';p=source/name;before=p.read_text();assert 'run/main_scene="res://main.tscn"' in before
    after=before.replace('run/main_scene="res://main.tscn"','run/main_scene="res://display-observer.tscn"');p.write_text(after)
    inputs[name]=hashlib.sha256(after.encode()).hexdigest();overrides[name]={'before':live_inputs[name],'after':inputs[name],'purpose':'separate diagnostic normal-scene observer; production source/export unchanged'}
    for name in ['display-observer.gd','display-observer.tscn']:
        p=Path(__file__).resolve().parent/name;shutil.copy2(p,source/'client/godot'/name);inputs['client/godot/'+name]=hashlib.sha256(p.read_bytes()).hexdigest()
if physical:
    name='client/godot/tests/ExportChecks.cs';p=source/name;before=p.read_text()
    needle='if (phase == "physics") { await PhysicsJourney(); return; }'
    assert before.count(needle)==1
    after=before.replace(needle,needle+'\n            if (phase == "vive-physical") { await VivePhysical(); return; }')
    p.write_text(after);inputs[name]=hashlib.sha256(after.encode()).hexdigest()
    overrides[name]={'before':live_inputs[name],'after':inputs[name],'purpose':'separate diagnostic partial uses ordinary signed-in app; no production source changed'}
    name='client/godot/tests/PhysicalChecks.cs';p=Path(__file__).resolve().parent/'PhysicalChecks.cs'
    shutil.copy2(p,source/name);inputs[name]=hashlib.sha256(p.read_bytes()).hexdigest()
feed=stage/'dependency-feed';feed.mkdir();dependencies={}
for p in sorted(Path('/home/yan/.cache/quod-m1b-artifacts/quod-m1b-client-corrective-02/dependency-feed').glob('*.nupkg')):
    (feed/p.name).symlink_to(p);dependencies[p.name]={'referenced_path':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size}
cache=source/'client/_build/godot-clean';cache.mkdir(parents=True)
archives=json.loads((source/'doc/evidence/godot-m0-20261027/inputs/godot-artifacts.json').read_text())
for row in archives:
    p=root/'client/_build/godot-clean'/row['name'];assert hashlib.sha256(p.read_bytes()).hexdigest()==row['sha256'];(cache/row['name']).symlink_to(p)
(source/'NuGet.Config').write_text('<configuration><packageSources><clear/><add key="qualified" value="'+str(feed)+'"/></packageSources></configuration>\n')
env=environment();env['NUGET_PACKAGES']=str(cache/'nuget')
record={'stage':str(stage),'supplied_inputs':inputs,'live_source_inputs':live_inputs,'diagnostic_overrides':overrides,'diagnostic_observer_embedded':observer,'diagnostic_physical_partial':physical,'distributable':False,'compiled_application_inputs_copied':False,'engine_archives':archives,'dependency_archives':dependencies,'template':{'path':str(template),'sha256':hashlib.sha256(template.read_bytes()).hexdigest()},'commands':[],'passed':False,'core189':'unchanged source; accepted final03 core189 reused, no recount'}
output=ev/'inputs'/('client-'+label+'-manifest.json')
def run(name,command,cwd=source,godot=False):
    check=['python3',str(root/'client/native/tools/check.py'),*(['--godot'] if godot else []),'--evidence',str(ev/('client-'+label+'-'+name)),'--',*command]
    row={'phase':name,'command':command,'cwd':str(cwd)};record['commands'].append(row);output.write_text(json.dumps(record,indent=2)+'\n')
    result=subprocess.run(check,cwd=cwd,env=env);row['wrapper_exit']=result.returncode
    if result.returncode:raise RuntimeError('Build phase failed: '+name)
try:
    run('toolchain',['dotnet','--info'],source/'client/godot')
    run('bootstrap',['python3','client/godot-tools/run.py','--bootstrap'])
    original=cache/'templates/linux_release.x86_64'
    record['official_template_replaced']={'sha256':hashlib.sha256(original.read_bytes()).hexdigest(),'purpose':'generated dependency replaced only in this isolated source-only stage; production and official archives unchanged'}
    shutil.copy2(template,original)
    for configuration in ['Debug','ExportRelease']:
        run('restore-'+configuration.lower(),['dotnet','restore','Quod.csproj','--locked-mode','-p:Configuration='+configuration,'-p:SelfContained=true','--source',str(feed)],source/'client/godot')
    verified={}
    for configuration in ['Debug','ExportRelease']:
        locks=json.loads((source/'client/godot'/('packages.'+configuration+'.linux-x64.lock.json')).read_text())
        for framework in locks['dependencies'].values():
            for package,row in framework.items():
                directory=cache/'nuget'/package.lower()/row['resolved'];name=package.lower()+'.'+row['resolved']+'.nupkg';p=directory/name
                assert hashlib.sha256(p.read_bytes()).hexdigest()==dependencies[name]['sha256']
                sha512=base64.b64encode(hashlib.sha512(p.read_bytes()).digest()).decode();assert (directory/(name+'.sha512')).read_text().strip()==sha512
                assert json.loads((directory/'.nupkg.metadata').read_text())['contentHash']==row['contentHash']
                verified[name]={'archive_sha512':sha512,'locked_content_hash':row['contentHash']}
    record['verified_cold_restore']=verified
    run('export',['python3','client/godot-tools/run.py','--export'],godot=True)
    assert all(hashlib.sha256((source/n).read_bytes()).hexdigest()==d for n,d in inputs.items())
    assert all(hashlib.sha256((root/n).read_bytes()).hexdigest()==d for n,d in live_inputs.items())
    dist=source/'client/godot/dist'
    record['export_outputs']={str(p.relative_to(dist)):{'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size} for p in sorted(dist.rglob('*')) if p.is_file()}
    record['passed']=True;record['export_executable']=str(dist/'quod.x86_64')
finally:output.write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'passed':record['passed'],'inputs':len(inputs),'outputs':len(record.get('export_outputs',{})),'stage':str(stage)}))
