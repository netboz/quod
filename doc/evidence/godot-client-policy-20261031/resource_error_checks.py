"""Focused real Transport response qualification with the pinned source-only SDK."""
import json,os,shutil,subprocess,sys
from pathlib import Path
from hashes import Digests,TASK,raw
sys.path.append(str(Path.cwd()/'doc/evidence/godot-m4-vive-physical-20261029'))
from environment import environment
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;label=sys.argv[1]
stage=TASK/'builds'/label;stage.mkdir(mode=0o700,exist_ok=False);d=Digests()
inputs={}
names=[*sorted((root/'client/godot/Core').glob('*.cs')),root/'client/godot-tests/Program.cs',root/'client/godot-tests/ResourceErrorChecks.cs',root/'client/godot-tests/Quod.Client.Tests.csproj',root/'client/godot-tests/packages.lock.json']
for p in names:
    n=p.relative_to(root);target=stage/n;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target);inputs[str(n)]=d.h(p)
m=json.loads((ev.parent/'godot-ontology-workbench-20261031/inputs/client-workbench-product01-manifest.json').read_text());feed=stage/'feed';feed.mkdir()
for name,r in m['dependency_archives'].items():
    p=Path(r['referenced_path']);assert d.h(p)==r['sha256'];(feed/name).symlink_to(p)
(stage/'NuGet.Config').write_text('<configuration><packageSources><clear/><add key="qualified" value="'+str(feed)+'"/></packageSources></configuration>\n')
env=environment();env['NUGET_PACKAGES']=str(stage/'cache');cwd=stage/'client/godot-tests'
record={'stage':str(stage),'inputs':inputs,'commands':[],'passed':False}
try:
    for command in [['dotnet','restore','Quod.Client.Tests.csproj','--locked-mode','--source',str(feed)],['dotnet','run','--no-restore','--project','Quod.Client.Tests.csproj','--','resource-errors']]:
        r=subprocess.run(command,cwd=cwd,env=env);record['commands'].append({'command':command,'true_exit':r.returncode})
        if r.returncode:raise SystemExit(r.returncode)
    record['passed']=True
finally:
    record['outputs']={str(p.relative_to(stage)):{'sha256':d.h(p),'bytes':p.stat().st_size} for p in sorted(cwd.glob('bin/Debug/net10.0/*')) if p.is_file()}
    d.write(stage/'computed-hashes.json');record['digest_cache']={'path':str(stage/'computed-hashes.json'),'sha256':raw(stage/'computed-hashes.json')}
    (ev/'inputs'/(label+'.json')).write_text(json.dumps(record,indent=2)+'\n')
