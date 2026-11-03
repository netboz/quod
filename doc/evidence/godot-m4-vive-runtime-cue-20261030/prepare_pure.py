"""Prepare only the affected pure cue program and before-execution inputs."""
import json,shutil
from pathlib import Path
from cue_hashes import TASK,raw
root=Path.cwd();ev=Path(__file__).resolve().parent
stage=TASK/'builds/runtime-cue-gates01';stage.mkdir(mode=0o700,exist_ok=False)
for n in ['ViveLookCue.cs','CueChecks.cs']:shutil.copy2(ev/n,stage/n)
(stage/'CueGateChecks.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup></Project>\n')
shutil.copy2(root/'client/godot/global.json',stage/'global.json')
feed=TASK/'artifacts/client-runtime-cue01/dependency-feed';assert len(list(feed.glob('*.nupkg')))==8
(stage/'NuGet.Config').write_text('<configuration><packageSources><clear/><add key="qualified" value="'+str(feed)+'"/></packageSources></configuration>\n')
copies=TASK/'private/build-inputs/runtime-cue-gates01';copies.mkdir(mode=0o700,parents=True,exist_ok=False)
record={}
for p in sorted(stage.iterdir()):
 assert p.is_file();shutil.copy2(p,copies/p.name);record[p.name]={'path':str(p),'before_execution_copy':str(copies/p.name),'sha256':raw(p),'bytes':p.stat().st_size,'mode':p.stat().st_mode&0o7777}
(ev/'inputs/pure-preexecution.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'prepared':str(stage),'before_execution_inputs':len(record),'functional_application_started':False}))
