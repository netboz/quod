"""Restore the missing fixture runtime from accepted bytes; never rebuild it."""
import json,os,shutil,sys,tarfile
sys.dont_write_bytecode=True
from pathlib import Path,PurePosixPath
from hashes import Digests,TASK,raw
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests();h=d.h
old=Path('/home/yan/.cache/quod-m3b-artifacts/quod-godot-m3b-handoff-8b352c53-20261029-02')
assert h(old/'snapshot.json')=='bda8941e95012e55786fc93f95e5c3ce73ce6dcf1a35ccfc275b73cfcbbde80c'
snapshot=json.loads((old/'snapshot.json').read_text())
for n in ['clean-inputs.json','server-qualification.json']:
 assert h(old/n)==snapshot['artifacts'][n]['sha256']
clean=json.loads((old/'clean-inputs.json').read_text());qualified=json.loads((old/'server-qualification.json').read_text())
prior=TASK/'artifacts/quod-godot-m4-vive-preparation-handoff-ca84d4f8-20261030-01'
assert h(prior/'snapshot.json')=='86ece6910580d658eb954ba68596ea582e8ca6e0236dcc2fc6f3fd28fef7d82c'
source=json.loads((prior/'source-manifest.json').read_text())
original=TASK/'builds/coordinator-preparation-source-reconstruction-65'
stage=TASK/'artifacts/server-runtime-restoration03';stage.mkdir(mode=0o700,exist_ok=False)
record={'stage':str(stage),'original_missing_path':'/tmp/quod-m3b-8b352c53/m3b-gates01/source',
 'restored_qualified_execution_inputs_only':True,'original_full_build_tree_claimed':False,
 'server_rebuilt':False,'server_suites_repeated':False,'archives':{},'passed':False}
output=ev/'inputs/server-runtime-restoration03.json';output.parent.mkdir(exist_ok=True)
installed={}
def save():output.write_text(json.dumps(record,indent=2)+'\n')
try:
 authored=clean['server_authored_inputs'];assert len(authored)==1432
 for n,digest in authored.items():
  p=original/n;q=stage/n;r=source[n]
  assert r['kind']=='file' and h(p)==digest==r['sha256'] and p.stat().st_mode&0o7777==r['mode']
  q.parent.mkdir(mode=0o700,parents=True,exist_ok=True);d.link(p,q,digest)
 record['authored_inputs']=authored;record['authored_file_modes']={n:source[n]['mode'] for n in authored}
 for n,digest in authored.items():installed[n]={'sha256':digest,'bytes':source[n]['bytes'],'mode':source[n]['mode']}
 compiled={**qualified['compiled_outputs'],**qualified['native_packaged_outputs']};assert len(compiled)==2059
 for name,expected in [('server-compiled-outputs.tar.gz',compiled),('local-release-outputs.tar.gz',qualified['packaged_release_outputs'])]:
  p=old/name;receipt=snapshot['artifacts'][name]
  assert h(p)==receipt['sha256'] and p.stat().st_size==receipt['bytes']
  record['archives'][name]={'path':str(p),**receipt};members=[];shared=[]
  with tarfile.open(p,'r:gz') as archive:
   for member in archive:
    rel=PurePosixPath(member.name);assert not rel.is_absolute() and '..' not in rel.parts
    n=str(rel);assert n in expected;members.append(n);q=stage/n;q.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    for parent in q.parents:
     if parent==stage:break
     assert not parent.is_symlink()
    if member.isdir():q.mkdir(mode=0o700,exist_ok=True)
    else:
     assert member.isfile()
     if q.exists():
      r=expected[n];assert n in installed and installed[n]==r
      assert q.is_file() and not q.is_symlink() and q.stat().st_size==r['bytes'] and q.stat().st_mode&0o7777==r['mode'] and h(q)==r['sha256']
      shared.append(n)
     else:
      with q.open('xb') as out:shutil.copyfileobj(archive.extractfile(member),out)
      q.chmod(member.mode)
  assert len(members)==len(expected) and set(members)==set(expected)
  for n,r in sorted(expected.items(),key=lambda item:len(PurePosixPath(item[0]).parts),reverse=True):
   p=stage/n
   if r.get('directory'):assert p.is_dir() and not p.is_symlink();p.chmod(r['mode'])
   else:assert p.is_file() and not p.is_symlink() and p.stat().st_size==r['bytes'] and p.stat().st_mode&0o7777==r['mode'] and h(p)==r['sha256']
  record['archives'][name]['all_members_content_and_recorded_modes_checked']=len(expected)
  record['archives'][name]['identical_existing_paths_reused']=shared
  installed.update({n:r for n,r in expected.items() if not r.get('directory')})
 # The compiled-file archive does not contain Rebar's priv directory links.
 # Resolve each existing application to its own accepted packaged priv bytes.
 # This is declared execution layout, not a source/build or policy fallback.
 packaged={}
 for p in (stage/'_build/prod/rel/quod/lib').glob('*/ebin/*.app'):
  assert p.stem not in packaged;packaged[p.stem]=p.parent.parent
 aliases={}
 for profile in ['default','prod','test']:
  for p in (stage/('_build/'+profile+'/lib')).glob('*/ebin/*.app'):
   target=packaged.get(p.stem)
   if target is None or not (target/'priv').is_dir():continue
   q=p.parent.parent/'priv';assert not q.exists() and not q.is_symlink()
   literal=os.path.relpath(target/'priv',q.parent);q.symlink_to(literal)
   aliases[str(q.relative_to(stage))]={'target':literal,'accepted_release_directory':str((target/'priv').relative_to(stage))}
 record['explicit_runtime_priv_aliases']=aliases
 assert (stage/'_build/prod/lib/quod/priv/ontologies/quod_controllers.pl').is_file()
 assert h(stage/'_build/prod/lib/quod/priv/native/quod_physics.so')==qualified['native_packaged_outputs']['priv/native/quod_physics.so']['sha256']
 assert (stage/'_build/test/lib/quod/test').is_dir()
 for n,digest in authored.items():assert h(stage/n)==digest
 record['compiled_entries']=len(compiled);record['packaged_release_entries']=len(qualified['packaged_release_outputs'])
 cache=TASK/'cache/server-runtime-restoration03-hashes.json';d.write(cache)
 record['digest_cache']={'path':str(cache),'sha256':raw(cache),'hits':d.hits,'new_files':d.new,'new_bytes':d.bytes}
 record['passed']=True
finally:save()
print(json.dumps({'passed':True,'stage':str(stage),'authored_inputs':len(authored),'compiled_entries':len(compiled),
 'release_entries':len(qualified['packaged_release_outputs']),'explicit_priv_aliases':len(aliases),'new_build':False}))
