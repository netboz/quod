from pathlib import Path
import subprocess,os,json,time,hashlib
R=Path.cwd();E=R/'doc/evidence/stage2-finalization-20261103'
env=dict(os.environ,NUGET_PACKAGES=str(R/'client/_build/godot-clean/nuget'),DOTNET_CLI_TELEMETRY_OPTOUT='1')
commands=[('core02',['dotnet','run','--no-restore','--project','client/godot-tests/Quod.Client.Tests.csproj','--',str(R)]),('managed-build02',['dotnet','build','client/godot/Quod.csproj','--no-restore'])]
sources={str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest() for folder in ['client/godot','client/godot-tests'] for p in (R/folder).rglob('*') if p.is_file() and not any(v in p.relative_to(R/folder).parts for v in ['obj','bin','.godot','dist','__pycache__'])}
commands.insert(1,('admission02',['dotnet','run','--no-build','--no-restore','--project','client/godot-tests/Quod.Client.Tests.csproj','--','admission-codecs']))
for label,cmd in commands:
 t=time.monotonic();x=subprocess.run(cmd,cwd=R,env=env,capture_output=True)
 (E/(label+'-stdout.log')).write_bytes(x.stdout);(E/(label+'-stderr.log')).write_bytes(x.stderr)
 (E/(label+'.json')).write_text(json.dumps(dict(command=cmd,true_exit=x.returncode,stdout_eof=True,stderr_eof=True,elapsed=time.monotonic()-t,source_inputs=sources),indent=2)+'\n')
 print(label,'TRUE_EXIT',x.returncode,flush=True);print((x.stdout+x.stderr).decode(errors='replace')[-3500:],flush=True)
 if x.returncode:raise SystemExit(x.returncode)
