"""Fresh source-only C# application; the private native template is a dependency."""
import base64,hashlib,json,os,shutil,subprocess,sys
sys.dont_write_bytecode=True
from pathlib import Path
sys.path.append(str(Path.cwd()/'doc/evidence/godot-m4-vive-physical-20261029'))
from environment import TASK,environment
from hashes import Digests
digests=Digests()
def h(path):return digests.h(path)
root=Path.cwd();ev=Path(__file__).resolve().parent
label=sys.argv[1];template=Path(sys.argv[2]);assert template.is_file();product=sys.argv[3:]==["--product"];race_baseline=sys.argv[3:]==["--race-baseline"];credit_baseline=sys.argv[3:]==["--credit-baseline"];assert len(sys.argv)==(4 if product or race_baseline or credit_baseline else 3)
stage=TASK/'artifacts'/('client-'+label);stage.mkdir(parents=True,exist_ok=False)
source=stage/'source';source.mkdir()
contract=json.loads((ev/'inputs/source-contract.json').read_text())
manifest_path=root/contract['base_manifest'];assert h(manifest_path)==contract['sha256']
manifest=json.loads(manifest_path.read_text());assert manifest['passed']
accepted_inputs=dict(manifest['supplied_inputs']);assert len(accepted_inputs)==93
inputs=dict(accepted_inputs);product_overrides={}
for name in contract['overrides']:
    before=ev/'inputs/before'/name;assert h(before)==inputs[name]
    inputs[name]=h(root/name)
    product_overrides[name]={'before':h(before),'after':inputs[name],'before_source':str(before),'purpose':'existing exact-subject representation/source consumer'}
for name in contract['added_product_sources']:
    assert name not in inputs;inputs[name]=h(root/name)
live_inputs=dict(inputs);overrides={}
assert h(template)==manifest['template']['sha256']=='02310d903099bada10c86cedc90bbc11ef0bec8254d6e607d1a53f6150ab0268'
for name,digest in live_inputs.items():
    p=root/name;assert h(p)==digest,name
    target=source/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target)
if not product:
    partial=ev/'Stage2Checks.cs';name='client/godot/tests/Stage2Checks.cs';assert name not in inputs
    target=source/name;shutil.copy2(partial,target);inputs[name]=h(partial)
    name='client/godot/tests/ExportChecks.cs';target=source/name
    data=target.read_text();needle='if (phase == "menu")'
    assert data.count(needle)==1
    data=data.replace(needle,'if (phase == "stage2") { await Stage2(); return; }\n            if (phase == "stage2-recover") { await Stage2Recover(); return; }\n            if (phase == "stage2-contents") { await Stage2Contents(); return; }\n            '+needle)
    target.write_text(data);overrides[name]={'live':live_inputs[name],'staged':h(target),'purpose':'removable Stage2 signed/native-Control qualification dispatch'};inputs[name]=h(target)
if race_baseline:
    name='client/godot/SourcePanel.cs';target=source/name
    prior=TASK/'artifacts/client-stage2-candidate02/source'/name
    text=prior.read_text();before='compiled+".",Key,work.Token)';after='compiled+".",Key,draft!,work.Token)'
    assert text.count(before)==1;text=text.replace(before,after);target.write_text(text)
    overrides[name]={'live':live_inputs[name],'staged':h(target),'source':str(prior),'source_sha256':h(prior),'purpose':'retained pre-generation-fence owner; only current Preview signature supplies the same mutable draft','exact_binding_change':{'before':before,'after':after}};inputs[name]=h(target)
if credit_baseline:
    name='client/godot/ScenePanel.cs';target=source/name
    prior=TASK/'artifacts/client-stage2-frame-baseline01/source'/name;text=prior.read_text()
    changes=[('Actor target,Actor principal)','Actor target,Actor principal,Action<System.Text.Json.Nodes.JsonObject> processed)'),('ApplyFrame(System.Text.Json.Nodes.JsonNode message)','ApplyFrame(System.Text.Json.Nodes.JsonNode message,Action<System.Text.Json.Nodes.JsonObject> processed)')]
    for before,after in changes:assert text.count(before)==1;text=text.replace(before,after)
    target.write_text(text);inputs[name]=h(target)
    overrides[name]={'live':live_inputs[name],'staged':inputs[name],'source':str(prior),'source_sha256':h(prior),'purpose':'retained pre-credit scene consumer; only callback parameter signatures adapted, original bodies unchanged','exact_binding_changes':[{'before':b,'after':a} for b,a in changes]}
feed=stage/'dependency-feed';feed.mkdir();dependencies={}
for p in sorted(Path('/home/yan/.cache/quod-m1b-artifacts/quod-m1b-client-corrective-02/dependency-feed').glob('*.nupkg')):
    (feed/p.name).symlink_to(p);dependencies[p.name]={'referenced_path':str(p),'sha256':h(p),'bytes':p.stat().st_size}
cache=source/'client/_build/godot-clean';cache.mkdir(parents=True)
archives=json.loads((source/'doc/evidence/godot-m0-20261027/inputs/godot-artifacts.json').read_text())
for row in archives:
    p=root/'client/_build/godot-clean'/row['name'];assert h(p)==row['sha256'];(cache/row['name']).symlink_to(p)
(source/'NuGet.Config').write_text('<configuration><packageSources><clear/><add key="qualified" value="'+str(feed)+'"/></packageSources></configuration>\n')
env=environment();env['NUGET_PACKAGES']=str(cache/'nuget')
record={'stage':str(stage),'supplied_inputs':inputs,'live_source_inputs':live_inputs,'diagnostic_overrides':overrides,'product_overrides':product_overrides,'accepted_menu_final02_inputs':accepted_inputs,'accepted_input_manifest':{'path':str(manifest_path),'sha256':h(manifest_path)},'diagnostic_partial_source':None if product else {'path':str(ev/'Stage2Checks.cs'),'sha256':h(ev/'Stage2Checks.cs')},'qualification_phase':None if product else 'stage2','diagnostic_physical_partial':False,'stage2_partial':not product,'compiled_from_actual_current_source':not (race_baseline or credit_baseline),'functional_application_executed':False,'native_runtime_started':False,'physical_qualification':'UNRUN; offline build only','distributable':False,'tracefree_product_composition':product,'compiled_application_inputs_copied':False,'engine_archives':archives,'dependency_archives':dependencies,'template':{'path':str(template),'sha256':h(template)},'commands':[],'passed':False,'core_qualification':{'prior189':'accepted unchanged crypto/asset/dependency obligations reused; changed store/forms/scene/protocol behavior qualified through focused real-owner checks, no whole-suite recount','controller_arbitration':'accepted unchanged authored mapping/router/focus fences reused; current presentation and scene adapter changes have separate affected checks','server1432':'accepted base application/runtime dependencies reused; changed client-view/auth/wire/name/ask and Prolog inputs are bound and qualified separately, no whole server-suite rerun'}}
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

