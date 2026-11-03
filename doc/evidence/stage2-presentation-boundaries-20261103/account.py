"""Compare only saved campaign inputs; inherited user changes are not our delta."""
from pathlib import Path
import difflib,hashlib,json
r=Path('/home/yan/src/quod_worktrees/pearl-stone');e=Path(__file__).resolve().parent
rows=[];h=lambda b:hashlib.sha256(b).hexdigest()
for before in sorted((e/'before').rglob('*')):
 if not before.is_file():continue
 name=str(before.relative_to(e/'before'));a=before.read_bytes();b=(r/name).read_bytes()
 if a==b:continue
 diff=list(difflib.unified_diff(a.decode().splitlines(True),b.decode().splitlines(True),fromfile='before/'+name,tofile=name))
 rows.append(dict(path=name,production=name.startswith(('src/','include/','priv/','client/src/','client/godot/Core/')),added=sum(x.startswith('+') and not x.startswith('+++') for x in diff),removed=sum(x.startswith('-') and not x.startswith('---') for x in diff),before_sha256=h(a),current_sha256=h(b)))
production=[x for x in rows if x['production']]
(e/'inputs/account.json').write_text(json.dumps(dict(production_delta=dict(added=sum(x['added'] for x in production),removed=sum(x['removed'] for x in production),net=sum(x['added']-x['removed'] for x in production),paths=production),all_saved_changes=rows),indent=2)+'\n')
print(json.dumps({k:v for k,v in json.loads((e/'inputs/account.json').read_text())['production_delta'].items() if k!='paths'}))
