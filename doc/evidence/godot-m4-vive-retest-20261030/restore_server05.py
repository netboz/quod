"""Restore the accepted default dependency objects at the production lookup path."""
import json,os,sys
sys.dont_write_bytecode=True
from pathlib import Path
from hashes import Digests,TASK,raw
os.umask(0o077);ev=Path(__file__).resolve().parent;d=Digests();h=d.h
previous=json.loads((ev/'inputs/server-runtime-restoration04.json').read_text());assert previous['passed']
info=previous['digest_cache'];assert raw(info['path'])==info['sha256']
for row in json.loads(Path(info['path']).read_text())['records']:
 k=tuple(row['stat_key']);assert k not in d.values or d.values[k]==row['sha256'];d.values[k]=row['sha256']
canonical=Path('/home/yan/.cache/quod-m3b-artifacts/quod-godot-m3b-handoff-8b352c53-20261029-02')
assert h(canonical/'snapshot.json')=='bda8941e95012e55786fc93f95e5c3ce73ce6dcf1a35ccfc275b73cfcbbde80c'
descriptor=json.loads((canonical/'snapshot.json').read_text())
assert h(canonical/'server-qualification.json')==descriptor['artifacts']['server-qualification.json']['sha256']
qualified=json.loads((canonical/'server-qualification.json').read_text())
old=Path(previous['stage']);stage=TASK/'artifacts/server-runtime-restoration05';stage.mkdir(mode=0o700,exist_ok=False)
record={'stage':str(stage),'passed':False,'server_rebuilt':False,'server_suites_repeated':False,
 'source_stage04_scope':'Verified immutable bytes only; failed case08 proves its production dependency lookup incomplete.',
 'cause':'Fixture production code-path omits default dependency applications when original profile directory aliases are absent.',
 'files':{},'directory_modes':{},'production_dependency_projection':{}}
output=ev/'inputs/server-runtime-restoration05.json'
def install(n,p,r):
 q=stage/n;q.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
 assert p.is_file() and not p.is_symlink() and p.stat().st_size==r['bytes'] and p.stat().st_mode&0o7777==r['mode'] and h(p)==r['sha256']
 if n in record['files']:
  assert record['files'][n]==r and not q.is_symlink() and q.is_file() and h(q)==r['sha256'] and q.stat().st_mode&0o7777==r['mode']
 else:
  assert not q.exists() and not q.is_symlink();d.link(p,q,r['sha256']);record['files'][n]=r
try:
 actual=set()
 for directory,children,names in os.walk(old,followlinks=False):
  parent=Path(directory)
  for name in children:
   p=parent/name;assert not p.is_symlink();n=str(p.relative_to(old));(stage/n).mkdir(mode=0o700,parents=True,exist_ok=True);record['directory_modes'][n]=p.stat().st_mode&0o7777
  for name in names:actual.add(str((parent/name).relative_to(old)))
 assert actual==set(previous['files'])
 for n,r in previous['files'].items():install(n,old/n,r)
 for app in qualified['dependency_app_names']:
  prefix='_build/default/lib/'+app+'/'
  required=prefix+'ebin/'+app+'.app';assert required in previous['files']
  target_prefix='_build/prod/lib/'+app+'/'
  projected={}
  for n,r in previous['files'].items():
   if n.startswith(prefix):
    target=target_prefix+n[len(prefix):];install(target,old/n,r);projected[target]=n
  for n,mode in list(record['directory_modes'].items()):
   if (n+'/').startswith(prefix):
    target=target_prefix+(n+'/')[len(prefix):];target=target.rstrip('/')
    (stage/target).mkdir(mode=0o700,parents=True,exist_ok=True);record['directory_modes'][target]=mode
  record['production_dependency_projection'][app]=projected
 for n,mode in sorted(record['directory_modes'].items(),key=lambda pair:len(Path(pair[0]).parts),reverse=True):(stage/n).chmod(mode)
 for n,r in record['files'].items():
  p=stage/n;assert p.is_file() and not p.is_symlink() and p.stat().st_size==r['bytes'] and p.stat().st_mode&0o7777==r['mode'] and h(p)==r['sha256']
 for app in qualified['dependency_app_names']:assert (stage/'_build/prod/lib'/app/'ebin'/(app+'.app')).is_file()
 record['qualified_dependency_app_names']=qualified['dependency_app_names'];record['passed']=True
finally:
 cache=TASK/'cache/server-runtime-restoration05-hashes.json';d.write(cache)
 record['digest_cache']={'path':str(cache),'sha256':raw(cache),'hits':d.hits,'new_files':d.new,'new_bytes':d.bytes}
 output.write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'passed':True,'stage':str(stage),'dependency_apps':len(record['production_dependency_projection']),
 'production_quod_unchanged':True,'files':len(record['files']),'new_build':False}))
