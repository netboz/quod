"""Earliest saved input owns attribution; missing current inputs are deletions."""
from pathlib import Path
import difflib,hashlib,json
r=Path('/home/yan/src/quod_worktrees/pearl-stone');e=Path(__file__).resolve().parent
sources={}
for folder in ['before','before-admission']:
 for f in sorted((e/folder).rglob('*')):
  if f.is_file():sources.setdefault(str(f.relative_to(e/folder)),f)
rows=[];h=lambda b:hashlib.sha256(b).hexdigest()
for name,before in sorted(sources.items()):
 a=before.read_bytes();current=r/name;b=current.read_bytes() if current.exists() else b''
 if a==b:continue
 diff=list(difflib.unified_diff(a.decode().splitlines(True),b.decode().splitlines(True)))
 rows.append(dict(path=name,baseline=str(before.relative_to(r)),production=name.startswith(('src/','include/','priv/','client/src/','client/godot/Core/')),added=sum(x.startswith('+') and not x.startswith('+++') for x in diff),removed=sum(x.startswith('-') and not x.startswith('---') for x in diff),before_sha256=h(a),current_sha256=h(b) if current.exists() else None,deleted=not current.exists()))
p=[x for x in rows if x['production']]
v=dict(production_delta=dict(added=sum(x['added'] for x in p),removed=sum(x['removed'] for x in p),net=sum(x['added']-x['removed'] for x in p),paths=p),all_saved_changes=rows)
(e/'inputs/account-current02.json').write_text(json.dumps(v,indent=2)+'\n');print({k:v for k,v in v['production_delta'].items() if k!='paths'})
