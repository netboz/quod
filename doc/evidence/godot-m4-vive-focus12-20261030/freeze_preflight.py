"""Metadata-only coverage and scope before real delta materialization."""
import ast,json,os,subprocess,sys
from pathlib import Path
sys.dont_write_bytecode=True
from freeze_hashes import Digests,TASK,key,raw
root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
prior=TASK/'artifacts/quod-godot-m4-vive-focus11-handoff-ca84d4f8-20261030-03'
previous=TASK/'builds/vive-focus11-source-reconstruction03'
old=json.loads((prior/'source-manifest.json').read_text());changes=json.loads((ev/'publisher-source-delta.json').read_text())['existing_changed_sources']
missing={}
for label,folder in [('live',root),('previous-materialization',previous)]:
    rows=[]
    for n,row in old.items():
        p=folder/n
        if row['kind']=='file':
            assert p.is_file() and not p.is_symlink() and p.stat().st_mode&0o7777==row['mode']
            expected=changes[n]['after_sha256'] if label=='live' and n in changes else row['sha256']
            k=key(p)
            if k in d.values:assert d.values[k]==expected
            else:rows.append({'path':n,'bytes':p.stat().st_size})
        else:assert p.is_symlink() and str(p.readlink())==row['target']
    missing[label]={'entries':len(rows),'bytes':sum(r['bytes'] for r in rows),'paths':rows}
assert all(r['bytes']<1048576 for r in missing.values()),missing
for p in ev.glob('*.py'):ast.parse(p.read_text(),filename=str(p))
assert not subprocess.check_output(['git','diff','--cached','--name-only'])
assert subprocess.check_output(['git','diff','--binary','HEAD'])==(prior/'tracked.patch').read_bytes()
assert subprocess.check_output(['git','rev-parse','HEAD']).decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert raw(ev.parent/'godot-m4-vive-retest10-20261030/focus_events.py')=='bb63ff9db8f3aef231f22043e8336c263afcf52b553c908419ff3e0abdd584e2'
for n in ['artifacts/quod-godot-m4-vive-focus12-handoff-ca84d4f8-20261030-01','artifacts/vive-focus12-freeze-runs01',
    'builds/vive-focus12-source-reconstruction01','builds/vive-focus12-delta-reconstruction01','builds/vive-focus12-group-reconstruction01']:
    assert not (TASK/n).exists()
stat=os.statvfs(TASK);result={'passed':True,'scope':'Metadata/cache and source syntax only; no product/runtime/old API replay.',
    'prior_source_paths':len(old),'changed_inherited_publishers':sorted(changes),'uncached':missing,'free_bytes':stat.f_bavail*stat.f_frsize,
    'no_source_or_object_links_created':True,'root_quiescence':'Actual retirement/card-cancel reports state no nonignored additions or source/object links during sealing.'}
p=ev/'freeze-preflight.json';assert not p.exists();p.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k!='uncached'}));print(json.dumps({'uncached':{k:{'entries':v['entries'],'bytes':v['bytes']} for k,v in missing.items()}}))
