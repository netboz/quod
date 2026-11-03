"""Prepare the finite pure compositor checks; no live client or IPC."""
import json,os,shutil
from pathlib import Path
from cue_hashes import TASK,raw
os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent
stage=TASK/'builds/morning-cue-composition01';stage.mkdir(mode=0o700,exist_ok=False)
for name in ['ViveLookCue.cs','CueCompositionChecks.cs']:shutil.copy2(ev/name,stage/name)
(stage/'Composition.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup></Project>\n')
shutil.copy2(root/'client/godot/global.json',stage/'global.json')
(stage/'NuGet.Config').write_text('<configuration><packageSources><clear/></packageSources></configuration>\n')
copies=TASK/'private/build-inputs/morning-cue-composition01';copies.mkdir(mode=0o700,parents=True,exist_ok=False)
record={}
for p in sorted(stage.iterdir()):
    shutil.copy2(p,copies/p.name);record[p.name]={'path':str(p),'before_execution_copy':str(copies/p.name),'sha256':raw(p),'bytes':p.stat().st_size,'mode':p.stat().st_mode&0o7777}
(ev/'inputs/composition-preexecution.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'prepared':str(stage),'before_execution_inputs':len(record),'live_started':False}))
