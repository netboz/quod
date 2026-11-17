"""Fresh source-only C# application; the private native template is a dependency."""
import base64,hashlib,json,os,shutil,subprocess,sys
sys.dont_write_bytecode=True
from pathlib import Path
sys.path.append(str(Path(__file__).resolve().parent.parent/'godot-m4-vive-physical-20261029'))
from environment import TASK,environment
from hashes import Digests
digests=Digests()
def h(path):return digests.h(path)
root=Path.cwd();ev=Path(__file__).resolve().parent
label=sys.argv[1];template=Path(sys.argv[2]);assert template.is_file();assert len(sys.argv)==3
stage=TASK/'artifacts'/('client-'+label);stage.mkdir(parents=True,exist_ok=False)
source=stage/'source';source.mkdir()
manifest_path=root/'doc/evidence/godot-m4-workspace-20261030/inputs/client-workspace-final06-manifest.json'
assert h(manifest_path)=='d8c5dd1bb41845eb89a2d1dd874d9669cfef5ce417afc58d7971b816fb8ec92b'
manifest=json.loads(manifest_path.read_text());assert manifest['passed']
accepted_inputs=dict(manifest['supplied_inputs']);assert len(accepted_inputs)==93
inputs={name:h(root/name) for name in accepted_inputs};live_inputs=dict(inputs);overrides={}
changed={name for name in accepted_inputs if inputs[name]!=accepted_inputs[name]}
assert changed==({'client/godot/tests/WorkspaceChecks.cs'} if 'baseline' in label else {'client/godot/OpenXRInput.cs','client/godot/README.md','client/godot/tests/WorkspaceChecks.cs'})
assert len(inputs)==93
for name,digest in inputs.items():
    p=root/name;assert h(p)==digest,name
    target=source/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target)
diagnostic_source=root/'client/godot/tests/WorkspaceChecks.cs'
feed=stage/'dependency-feed';feed.mkdir();dependencies={}
for p in sorted(Path('/home/yan/.cache/quod-m1b-artifacts/quod-m1b-client-corrective-02/dependency-feed').glob('*.nupkg')):
    (feed/p.name).symlink_to(p);dependencies[p.name]={'referenced_path':str(p),'sha256':h(p),'bytes':p.stat().st_size}
cache=source/'client/_build/godot-clean';cache.mkdir(parents=True)
archives=json.loads((source/'doc/evidence/godot-m0-20261027/inputs/godot-artifacts.json').read_text())
for row in archives:
    p=root/'client/_build/godot-clean'/row['name'];assert h(p)==row['sha256'];(cache/row['name']).symlink_to(p)
(source/'NuGet.Config').write_text('<configuration><packageSources><clear/><add key="qualified" value="'+str(feed)+'"/></packageSources></configuration>\n')
env=environment();env['NUGET_PACKAGES']=str(cache/'nuget')
record={'stage':str(stage),'supplied_inputs':inputs,'live_source_inputs':live_inputs,'diagnostic_overrides':overrides,'accepted_workspace_final06_inputs':accepted_inputs,'accepted_input_manifest':{'path':str(manifest_path),'sha256':h(manifest_path)},'qualification_source':{'path':str(diagnostic_source),'sha256':h(diagnostic_source)},'qualification_phase':'workspace','diagnostic_physical_partial':False,'trace_free_product_source':True,'compiled_from_actual_current_source':True,'native_runtime_started':False,'physical_qualification':'UNRUN; offline build only','distributable':label.startswith('placement-final'),'compiled_application_inputs_copied':False,'engine_archives':archives,'dependency_archives':dependencies,'template':{'path':str(template),'sha256':h(template)},'commands':[],'passed':False,'core189':'unchanged source; accepted final03 core189 reused, no recount'}
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

