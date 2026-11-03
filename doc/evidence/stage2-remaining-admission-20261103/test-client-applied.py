from pathlib import Path
import subprocess,json,hashlib,shutil,os
r=Path('/home/yan/src/quod_worktrees/pearl-stone');e=Path(__file__).resolve().parent
p=r/'_build/stage2-remaining-admission/applied-client01';p.mkdir(parents=True,exist_ok=False)
src=p/'source'
for folder in ['client/godot/Core','client/godot-tests','client/src','client/test']:
 for f in (r/folder).glob('*'):
  if f.suffix not in ['.cs','.csproj','.json','.js']:continue
  n=f.relative_to(r);d=src/n;d.parent.mkdir(parents=True,exist_ok=True)
  shutil.copy2(f,d)
# Reuse the previously restored, pinned package assets; no restore or install.
prior=r/'_build/stage2-presentation-boundaries/native02'
shutil.copytree(prior/'source/client/godot-tests/obj',src/'client/godot-tests/obj')
env=dict(os.environ,NUGET_PACKAGES=str(prior/'nuget'),DOTNET_CLI_HOME=str(prior/'dotnet'),DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',DOTNET_CLI_TELEMETRY_OPTOUT='1')
steps=[]
for label,cmd,cwd in [('native-build',['dotnet','build','--no-restore'],src/'client/godot-tests'),('native-namespace',['dotnet','run','--no-build','--','admission-codecs'],src/'client/godot-tests'),('browser-namespace',['node','--test','client/test/agent-references.test.js','client/test/signed-client.test.js'],src)]:
 c=subprocess.run(cmd,cwd=cwd,env=env,capture_output=True)
 for stream in ['stdout','stderr']:(e/'logs'/('applied-client01-'+label+'-'+stream+'.log')).write_bytes(getattr(c,stream))
 steps.append(dict(label=label,command=cmd,true_exit=c.returncode,stdout_eof=True,stderr_eof=True,applied_modules_executed=True));print(steps[-1],flush=True)
 print((c.stdout+c.stderr).decode(errors='replace')[-2000:])
(e/'inputs/applied-client01.json').write_text(json.dumps(dict(steps=steps,source_inputs={str(f.relative_to(src)):hashlib.sha256(f.read_bytes()).hexdigest() for f in src.rglob('*') if f.is_file() and f.suffix in ['.cs','.csproj','.js'] and 'obj' not in f.parts}),indent=2)+'\n')
raise SystemExit(0 if all(s['true_exit']==0 for s in steps) else 1)
