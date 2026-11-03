"""Finite shared browser caller check from separately retained exact sources."""
import json,os,re,shutil,subprocess,sys
from pathlib import Path
from hashes import TASK,Digests,key
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;label=sys.argv[1]
stage=TASK/'private'/label;stage.mkdir(mode=0o700,exist_ok=False);d=Digests();pending=['client/src/simulation.js'];sources={}
while pending:
    name=pending.pop()
    if name in sources:continue
    p=root/name;assert p.is_relative_to(root/'client/src') and p.suffix=='.js'
    before=key(p);dest=stage/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dest)
    sources[name]={'path':str(dest),'sha256':d.h(dest),'original_stat_key':before,'mode':dest.stat().st_mode};assert d.h(p)==sources[name]['sha256'] and key(p)==before
    for relative in re.findall(r"(?:from\s*|import\s*\()\s*['\"](\.[^'\"]+)['\"]",dest.read_text()):
        next=(p.parent/relative).resolve();assert next.is_relative_to(root/'client/src');pending.append(str(next.relative_to(root)))
for p,name in [(ev/'browser-check.mjs','browser-check.mjs'),(root/'client/package.json','client/package.json'),(Path(__file__),'browser.py')]:
    dest=stage/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dest);sources[name]={'path':str(dest),'sha256':d.h(dest),'original_stat_key':key(p),'mode':dest.stat().st_mode};assert d.h(p)==sources[name]['sha256']
command=[shutil.which('node'),str(stage/'browser-check.mjs'),'client/src/world.js'];r=subprocess.run(command,cwd=stage)
assert all(d.h(Path(row['path']))==row['sha256'] for row in sources.values())
d.write(stage/'computed-hashes.json')
record={'passed':r.returncode==0,'true_exit':r.returncode,'command':command,'cwd':str(stage),'source_inputs':sources,'only_retained_sources_executed':True,'network_or_browser_runtime':False,'digest_cache':{'path':str(stage/'computed-hashes.json'),'sha256':d.h(stage/'computed-hashes.json')}}
(ev/'inputs'/(label+'.json')).write_text(json.dumps(record,indent=2)+'\n');raise SystemExit(r.returncode)
