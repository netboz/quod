"""Fresh source-only C# application; the private native template is a dependency."""
import base64,hashlib,json,os,shutil,subprocess,sys
sys.dont_write_bytecode=True
from pathlib import Path
sys.path.append(str(Path(__file__).resolve().parent.parent/'godot-m4-vive-physical-20261029'))
from environment import TASK,environment
from cue_hashes import Digests
digests=Digests()
def h(path):return digests.h(path)
root=Path.cwd();ev=Path(__file__).resolve().parent
label=sys.argv[1];template=Path(sys.argv[2]);assert template.is_file();product=sys.argv[3:]==["--product"];assert len(sys.argv)==(4 if product else 3)
stage=TASK/'artifacts'/('client-'+label);stage.mkdir(parents=True,exist_ok=False)
source=stage/'source';source.mkdir()
manifest_path=root/'doc/evidence/godot-m4-workspace-placement-20261031/inputs/client-placement-final01-manifest.json'
assert h(manifest_path)=='285ef21b6699a89444ae8a583a20a6cd836f59b30ccfdfac1c59955fd7a81f8c'
manifest=json.loads(manifest_path.read_text());assert manifest['passed']
accepted_inputs=dict(manifest['supplied_inputs']);assert len(accepted_inputs)==93
inputs=dict(accepted_inputs);product_overrides={}
for name in ['client/godot/OperationsPanel.cs','client/godot/README.md','client/godot/FormPanel.cs','client/godot/tests/SpaceChecks.cs','client/godot/Core/Controllers.cs','client/godot/OpenXRInput.cs','client/godot/tests/ControllerChecks.cs']:
    digest=h(root/name)
    if digest!=inputs[name]:
        before=ev/'inputs'/(Path(name).name+'.before');assert h(before)==inputs[name]
        product_overrides[name]={'before':inputs[name],'after':digest,'before_source':str(before),'purpose':'measured long selector width/reflow correction in the existing shared presentation owner'}
        inputs[name]=digest
live_inputs=dict(inputs);overrides={}
assert 'client/godot/tests/PresentationChecks.cs' in inputs
assert h(template)==manifest['template']['sha256']=='02310d903099bada10c86cedc90bbc11ef0bec8254d6e607d1a53f6150ab0268'
for name,digest in inputs.items():
    p=root/name;assert h(p)==digest,name
    target=source/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target)
if not product:
    name='client/godot/tests/ExportChecks.cs';p=source/name;before=p.read_text()
    needle='if (phase == "physics") { await PhysicsJourney(); return; }'
    assert before.count(needle)==1 and 'phase == "vive-physical"' not in before
    assert before.count('phase == "presentation"')==1
    after=before.replace(needle,needle+'\n            if (phase == "vive-physical") { await VivePhysical(); return; }\n            if (phase == "morning-journey") { await MorningJourney(); return; }')
    p.write_text(after);inputs[name]=h(p)
    overrides[name]={'before':live_inputs[name],'after':inputs[name],'purpose':'one staged-only diagnostic dispatch; accepted production source unchanged'}
    physical_source=ev/'PhysicalChecks.cs'
    name='client/godot/tests/PhysicalChecks.cs';shutil.copy2(physical_source,source/name);inputs[name]=h(physical_source);assert len(inputs)==94
    overrides[name]={'after':h(physical_source),'purpose':'current workspace diagnostic frame observer; fixed-height shared-layout cue and actual workspace visibility; desktop focus is observation only'}
    cue=ev/'ViveLookCue.cs';name='client/godot/tests/ViveLookCue.cs';shutil.copy2(cue,source/name);inputs[name]=h(cue);assert len(inputs)==95
    for helper in ['MorningJourneyGuide.cs','MorningJourneyChecks.cs']:
        name='client/godot/tests/'+helper;shutil.copy2(ev/helper,source/name);inputs[name]=h(ev/helper)
        overrides[name]={'after':inputs[name],'purpose':'removable read-only journey guidance or explicit software-only rehearsal phase; no production action owner'}
    assert len(inputs)==97
feed=stage/'dependency-feed';feed.mkdir();dependencies={}
for p in sorted(Path('/home/yan/.cache/quod-m1b-artifacts/quod-m1b-client-corrective-02/dependency-feed').glob('*.nupkg')):
    (feed/p.name).symlink_to(p);dependencies[p.name]={'referenced_path':str(p),'sha256':h(p),'bytes':p.stat().st_size}
cache=source/'client/_build/godot-clean';cache.mkdir(parents=True)
archives=json.loads((source/'doc/evidence/godot-m0-20261027/inputs/godot-artifacts.json').read_text())
for row in archives:
    p=root/'client/_build/godot-clean'/row['name'];assert h(p)==row['sha256'];(cache/row['name']).symlink_to(p)
(source/'NuGet.Config').write_text('<configuration><packageSources><clear/><add key="qualified" value="'+str(feed)+'"/></packageSources></configuration>\n')
env=environment();env['NUGET_PACKAGES']=str(cache/'nuget')
record={'stage':str(stage),'supplied_inputs':inputs,'live_source_inputs':live_inputs,'diagnostic_overrides':overrides,'product_overrides':product_overrides,'accepted_placement_final01_inputs':accepted_inputs,'accepted_input_manifest':{'path':str(manifest_path),'sha256':h(manifest_path)},'diagnostic_partial_source':None if product else {'path':str(physical_source),'sha256':h(physical_source)},'qualification_phase':None if product else 'vive-physical','diagnostic_physical_partial':not product,'compiled_from_actual_current_source':True,'functional_application_executed':False,'native_runtime_started':False,'physical_qualification':'UNRUN; offline build only','distributable':product,'compiled_application_inputs_copied':False,'engine_archives':archives,'dependency_archives':dependencies,'template':{'path':str(template),'sha256':h(template)},'commands':[],'passed':False,'core_qualification':{'prior189':'accepted unchanged crypto/store/forms/scene/asset obligations; no fresh whole-suite credit','changed_controller_arbitration':'qualified separately through actual XRServer/native Control regression; no core189 recount','server1432':'unchanged accepted dependency'}}
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
    record['official_template_replaced']={'sha256':h(original),'purpose':'generated dependency replaced only in this isolated source-only stage; production and official archives unchanged'}
    shutil.copy2(template,original)
    for configuration in ['Debug','ExportRelease']:
        run('restore-'+configuration.lower(),['dotnet','restore','Quod.csproj','--locked-mode','-p:Configuration='+configuration,'-p:SelfContained=true','--source',str(feed)],source/'client/godot')
    verified={}
    for configuration in ['Debug','ExportRelease']:
        locks=json.loads((source/'client/godot'/('packages.'+configuration+'.linux-x64.lock.json')).read_text())
        for framework in locks['dependencies'].values():
            for package,row in framework.items():
                directory=cache/'nuget'/package.lower()/row['resolved'];name=package.lower()+'.'+row['resolved']+'.nupkg';p=directory/name
                assert h(p)==dependencies[name]['sha256']
                sha512=base64.b64encode(hashlib.sha512(p.read_bytes()).digest()).decode();assert (directory/(name+'.sha512')).read_text().strip()==sha512
                assert json.loads((directory/'.nupkg.metadata').read_text())['contentHash']==row['contentHash']
                verified[name]={'archive_sha512':sha512,'locked_content_hash':row['contentHash']}
    record['verified_cold_restore']=verified
    run('export',['python3','client/godot-tools/run.py','--export'],godot=True)
    assert all(h(source/n)==d for n,d in inputs.items())
    assert all(h(root/n)==d for n,d in live_inputs.items())
    dist=source/'client/godot/dist'
    record['export_outputs']={str(p.relative_to(dist)):{'sha256':h(p),'bytes':p.stat().st_size} for p in sorted(dist.rglob('*')) if p.is_file()}
    digest_cache=stage/'computed-hashes.json';digests.write(digest_cache)
    record['digest_cache']={'path':str(digest_cache),'sha256':h(digest_cache),'hits':digests.hits,'new_files':digests.new,'new_bytes':digests.bytes}
    assert len(record['export_outputs'])==196
    record['passed']=True;record['export_executable']=str(dist/'quod.x86_64')
finally:output.write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'passed':record['passed'],'inputs':len(inputs),'outputs':len(record.get('export_outputs',{})),'stage':str(stage)}))

