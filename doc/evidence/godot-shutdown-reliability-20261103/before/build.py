"""Clean source-only shared GUI qualification; separately labelled diagnostics."""
import argparse,json,os,shutil,subprocess,sys
from pathlib import Path
from hashes import Digests,TASK,raw
sys.dont_write_bytecode=True;sys.path.append(str(Path.cwd()/'doc/evidence/godot-m4-vive-physical-20261029'))
from environment import environment
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent
parser=argparse.ArgumentParser();parser.add_argument('label');parser.add_argument('--product',action='store_true');a=parser.parse_args();label=a.label
d=Digests();m=json.loads((root/'doc/evidence/godot-authored-appearance-20261101/inputs/client-appearance-product03-manifest.json').read_text())
stage=TASK/'artifacts'/('client-'+label);stage.mkdir(mode=0o700,exist_ok=False);source=stage/'source';source.mkdir()
assert m['passed'] and m['trace_free'] and m['supplied_inputs']==m['live_source_inputs']
live={name:d.h(root/name) for name in m['live_source_inputs']}
assert live==m['live_source_inputs']
inputs=dict(live)
for name,digest in live.items():
    assert d.h(root/name)==digest;target=source/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/name,target)
overrides={}
if not a.product:
    for filename in ['PackageJourneyChecks.cs','CloseTrace.cs']:
        partial=ev/filename;name='client/godot/tests/'+partial.name;shutil.copy2(partial,source/name);inputs[name]=d.h(partial);overrides[name]=inputs[name]
    name='client/godot/tests/ExportChecks.cs';target=source/name;text=target.read_text();needle='if (phase == "menu")';assert text.count(needle)==1
    dispatch='if (phase is "m5-initial" or "m5-reopen") { await PackageJourney(phase=="m5-reopen"); return; }'
    target.write_text(text.replace(needle,dispatch+'\n            '+needle));inputs[name]=d.h(target);overrides[name]={'before':live[name],'after':inputs[name]}
if not a.product:
    from instrument_close import instrument
    name='client/godot/Main.cs';target=source/name
    target.write_text(instrument(target.read_text()));inputs[name]=d.h(target);overrides[name]={'before':live[name],'after':inputs[name]}
feed=stage/'dependency-feed';feed.mkdir();cache=source/'client/_build/godot-clean';cache.mkdir(parents=True)
for name,row in m['dependency_archives'].items():assert d.h(Path(row['referenced_path']))==row['sha256'];(feed/name).symlink_to(row['referenced_path'])
toolchain=json.loads((root/'doc/evidence/godot-space-stage2-20261031/inputs/client-stage2-product01-manifest.json').read_text())
for row in toolchain['engine_archives']:
    p=root/'client/_build/godot-clean'/row['name'];assert d.h(p)==row['sha256'];(cache/row['name']).symlink_to(p)
(source/'NuGet.Config').write_text('<configuration><packageSources><clear/><add key="qualified" value="'+str(feed)+'"/></packageSources></configuration>\n')
record={'passed':False,'stage':str(stage),'live_source_inputs':live,'supplied_inputs':inputs,'product_manifest_sha256':raw(root/'doc/evidence/godot-authored-appearance-20261101/inputs/client-appearance-product03-manifest.json'),'diagnostic_overrides':overrides,'trace_free':a.product,'distributable':False,'compiled_application_inputs_copied':False,'template':m['template'],'dependency_archives':m['dependency_archives'],'commands':[]}
output=ev/'inputs'/('client-'+label+'-manifest.json');drivers=stage/'drivers';drivers.mkdir();
for p in [Path(__file__).resolve(),ev/'hashes.py',ev/'PackageJourneyChecks.cs',ev/'CloseTrace.cs',ev/'instrument_close.py']:shutil.copy2(p,drivers/p.name)
env=environment();env['NUGET_PACKAGES']=str(cache/'nuget')
def run(phase,command,cwd=source,godot=False):
    check=['python3',str(root/'client/native/tools/check.py'),*(['--godot'] if godot else []),'--evidence',str(ev/(label+'-'+phase)),'--',*command]
    item={'phase':phase,'command':command,'cwd':str(cwd)};record['commands'].append(item);output.write_text(json.dumps(record,indent=2)+'\n')
    r=subprocess.run(check,cwd=cwd,env=env);item['true_exit']=r.returncode;assert r.returncode==0,phase
try:
    run('toolchain',['dotnet','--info'],source/'client/godot')
    run('bootstrap',['python3','client/godot-tools/run.py','--bootstrap'])
    template=Path(m['template']['path']);assert d.h(template)==m['template']['sha256'];shutil.copy2(template,cache/'templates/linux_release.x86_64')
    for c in ['Debug','ExportRelease']:run('restore-'+c.lower(),['dotnet','restore','Quod.csproj','--locked-mode','-p:Configuration='+c,'-p:SelfContained=true','--source',str(feed)],source/'client/godot')
    run('export',['python3','client/godot-tools/run.py','--export'],godot=True)
    assert all(d.h(source/n)==v for n,v in inputs.items()) and all(d.h(root/n)==v for n,v in live.items())
    dist=source/'client/godot/dist';record['export_outputs']={str(p.relative_to(dist)):{'sha256':d.h(p),'bytes':p.stat().st_size} for p in sorted(dist.rglob('*')) if p.is_file()};assert len(record['export_outputs'])==196
    record['export_executable']=str(dist/'quod.x86_64');record['passed']=True
finally:
    d.write(stage/'computed-hashes.json');record['digest_cache']={'path':str(stage/'computed-hashes.json'),'sha256':raw(stage/'computed-hashes.json')};output.write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'passed':True,'inputs':len(inputs),'exports':196}))
