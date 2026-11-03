"""Source-only diagnostic debug build. No export, package, release or hardware."""
import json,os,shutil,subprocess,sys,hashlib
from pathlib import Path
root=Path.cwd();ev=Path(__file__).resolve().parent;label=sys.argv[1]
diagnostic=ev/(sys.argv[2] if len(sys.argv)>2 else 'PredicateChecks.cs')
stage=root/'_build/stage2-presentation-boundaries'/label;stage.mkdir(parents=True,exist_ok=False)
m=json.loads((root/'doc/evidence/godot-occurrence-visibility-20261102/inputs/client-visibility-product01-manifest.json').read_text())
h=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
source=stage/'source';inputs={}
for name in m['live_source_inputs']:
 p=source/name;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/name,p);inputs[name]=h(p)
p=source/'client/godot/tests/ExportChecks.cs';s=p.read_text();needle='if (phase == "menu")';assert s.count(needle)==1;p.write_text(s.replace(needle,'if (phase == "predicates") { await '+diagnostic.stem+'(); return; }\n            '+needle))
shutil.copy2(diagnostic,p.parent/diagnostic.name)
feed=stage/'feed';feed.mkdir()
for name,row in m['dependency_archives'].items():
 assert h(row['referenced_path'])==row['sha256'];(feed/name).symlink_to(row['referenced_path'])
(source/'NuGet.Config').write_text('<configuration><packageSources><clear/><add key="qualified" value="'+str(feed)+'"/></packageSources></configuration>\n')
env=dict(os.environ,NUGET_PACKAGES=str(stage/'nuget'),DOTNET_CLI_HOME=str(stage/'dotnet'),DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',DOTNET_CLI_TELEMETRY_OPTOUT='1')
engine=root/'client/_build/godot-clean/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64'
record={'label':label,'passed':False,'source_inputs':inputs,'diagnostic_inputs':{str(p.relative_to(source)):h(p), 'client/godot/tests/'+diagnostic.name:h(diagnostic)},'stage':str(stage),'engine':str(engine),'commands':[]}
try:
 for phase,args in [('restore',['dotnet','restore','Quod.csproj','--locked-mode','--source',str(feed)]),('build',['dotnet','build','Quod.csproj','--no-restore']),('import',[str(engine),'--headless','--path',str(source/'client/godot'),'--editor','--import','--audio-driver','Dummy','--xr-mode','off'])]:
  command=['python3',str(root/'client/native/tools/check.py'),'--evidence',str(ev/'logs'/(label+'-'+phase)),'--',*args]
  r=subprocess.run(command,cwd=source/'client/godot',env=env);record['commands'].append({'phase':phase,'args':args,'exit':r.returncode});assert r.returncode==0,phase
 record['passed']=True
finally:(ev/'inputs'/(label+'-build.json')).write_text(json.dumps(record,indent=2)+'\n')
