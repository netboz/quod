from pathlib import Path
import json,re,subprocess,time
p=Path(__file__).resolve().parent;rows=[]
for path in sorted(Path('client/test').glob('*.test.js')):
 start=time.monotonic()
 with (p/(path.name+'.log')).open('x') as log:r=subprocess.run(['node',str(path)],stdout=log,stderr=subprocess.STDOUT)
 text=(p/(path.name+'.log')).read_text();counts=re.findall(r'ℹ tests (\d+)',text)
 row={'file':str(path),'child_exit':r.returncode,'tests':int(counts[-1]) if counts else None,'seconds':time.monotonic()-start}
 (p/(path.name+'.exit.json')).write_text(json.dumps(row)+'\n');rows.append(row)
 print(json.dumps(row),flush=True)
 assert r.returncode==0 and row['tests'] is not None,row
(p/'result.json').write_text(json.dumps({'tests':sum(r['tests'] for r in rows),'files':len(rows),'all_child_exits_zero':True,'results':rows},indent=2)+'\n')
print(json.dumps({'tests':sum(r['tests'] for r in rows),'files':len(rows),'all_child_exits_zero':True}))
