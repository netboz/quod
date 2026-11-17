"""Isolated native core recovery check; no Godot, hardware or release."""
from pathlib import Path
import json,hashlib,os,subprocess,sys,shutil,time
r=Path('/home/yan/src/quod_worktrees/pearl-stone');e=Path(__file__).resolve().parent;label=sys.argv[1]
p=r/'_build/stage2-presentation-boundaries'/label;p.mkdir(parents=True,exist_ok=False);src=p/'source';inputs={}
for folder,glob in [('client/godot/Core','*.cs'),('client/godot-tests','*.cs'),('client/godot-tests','*.csproj'),('client/godot-tests','*.json')]:
 for f in (r/folder).glob(glob):
  rel=f.relative_to(r);dest=src/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(f,dest);inputs[str(rel)]=hashlib.sha256(f.read_bytes()).hexdigest()
feed=r/'_build/stage2-presentation-limits/native01/feed'
(src/'NuGet.Config').write_text('<configuration><packageSources><clear/><add key="qualified" value="'+str(feed)+'"/></packageSources></configuration>')
env=dict(os.environ,NUGET_PACKAGES=str(p/'nuget'),DOTNET_CLI_HOME=str(p/'dotnet'),DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',DOTNET_CLI_TELEMETRY_OPTOUT='1');steps=[]
try:
 for phase,args in [('restore',['dotnet','restore','--locked-mode']),('build',['dotnet','build','--no-restore']),('recovery',['dotnet','run','--no-build','--','recovery-errors',str(p/'profile')]),('finite',['dotnet','run','--no-build','--','resource-errors'])]:
  start=time.monotonic();c=subprocess.run(args,cwd=src/'client/godot-tests',env=env,capture_output=True)
  for stream in ['stdout','stderr']:(e/'logs'/(label+'-'+phase+'-'+stream+'.log')).write_bytes(getattr(c,stream))
  steps.append(dict(phase=phase,command=args,true_exit=c.returncode,stdout_eof=True,stderr_eof=True,elapsed_seconds=time.monotonic()-start));print(steps[-1],flush=True)
  if c.returncode: print((c.stdout+c.stderr).decode(errors='replace')[-4000:]);break
finally:(e/'inputs'/(label+'.json')).write_text(json.dumps(dict(source_inputs=inputs,steps=steps),indent=2)+'\n')
sys.exit(c.returncode)
