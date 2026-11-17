"""Materialize a typed union of accepted runtime bytes and package resources."""
import json,os,sys
sys.dont_write_bytecode=True
from pathlib import Path,PurePosixPath
from hashes import Digests,TASK,raw
os.umask(0o077);ev=Path(__file__).resolve().parent;d=Digests();h=d.h
archive=Path('/home/yan/.cache/quod-m3b-artifacts/quod-godot-m3b-handoff-8b352c53-20261029-02')
assert h(archive/'snapshot.json')=='bda8941e95012e55786fc93f95e5c3ce73ce6dcf1a35ccfc275b73cfcbbde80c'
snapshot=json.loads((archive/'snapshot.json').read_text())
for name in ['clean-inputs.json','server-qualification.json','server-compiled-outputs.tar.gz','local-release-outputs.tar.gz']:
 assert h(archive/name)==snapshot['artifacts'][name]['sha256'] and (archive/name).stat().st_size==snapshot['artifacts'][name]['bytes']
clean=json.loads((archive/'clean-inputs.json').read_text());qualified=json.loads((archive/'server-qualification.json').read_text())
prior=TASK/'artifacts/quod-godot-m4-vive-preparation-handoff-ca84d4f8-20261030-01'
assert h(prior/'snapshot.json')=='86ece6910580d658eb954ba68596ea582e8ca6e0236dcc2fc6f3fd28fef7d82c'
source=json.loads((prior/'source-manifest.json').read_text())
failed=TASK/'artifacts/server-runtime-restoration03';stage=TASK/'artifacts/server-runtime-restoration04';stage.mkdir(mode=0o700,exist_ok=False)
record={'stage':str(stage),'passed':False,'server_rebuilt':False,'server_suites_repeated':False,
 'original_full_build_tree_claimed':False,'failed03_reuse':'Actual verified byte custody only; failed stage qualification remains failed.',
 'archive_identity':{n:snapshot['artifacts'][n] for n in ['clean-inputs.json','server-qualification.json','server-compiled-outputs.tar.gz','local-release-outputs.tar.gz']}}
output=ev/'inputs/server-runtime-restoration04.json';files={};directories={};projections={}
def install(n,p,r):
 rel=PurePosixPath(n);assert not rel.is_absolute() and '..' not in rel.parts
 q=stage/n;q.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
 for parent in q.parents:
  if parent==stage:break
  assert not parent.is_symlink()
 assert p.is_file() and not p.is_symlink() and p.stat().st_size==r['bytes'] and p.stat().st_mode&0o7777==r['mode'] and h(p)==r['sha256']
 if n in files:assert files[n]==r and q.is_file() and not q.is_symlink() and h(q)==r['sha256'] and q.stat().st_mode&0o7777==r['mode']
 else:
  assert not q.exists() and not q.is_symlink();d.link(p,q,r['sha256']);files[n]=r
try:
 authored=clean['server_authored_inputs'];assert len(authored)==1432
 for n,digest in authored.items():
  r=source[n];assert r['kind']=='file' and r['sha256']==digest
  install(n,failed/n,{k:r[k] for k in ['sha256','bytes','mode']})
 compiled={**qualified['compiled_outputs'],**qualified['native_packaged_outputs']};assert len(compiled)==2059
 release=qualified['packaged_release_outputs'];shared=set(compiled)&set(release)
 assert all(compiled[n]==release[n] for n in shared)
 for entries in [compiled,release]:
  for n,r in entries.items():
   if r.get('directory'):directories[n]=r['mode'];(stage/n).mkdir(mode=0o700,parents=True,exist_ok=True)
   else:install(n,failed/n,r)
 packaged={}
 for p in (stage/'_build/prod/rel/quod/lib').glob('*/ebin/*.app'):
  assert p.stem not in packaged;packaged[p.stem]=p.parent.parent
 for profile in ['default','prod','test']:
  for app in (stage/('_build/'+profile+'/lib')).glob('*/ebin/*.app'):
   owner=packaged.get(app.stem)
   if owner is None or not (owner/'priv').is_dir():continue
   target=app.parent.parent/'priv';mapping=[]
   for p in sorted((owner/'priv').rglob('*')):
    assert not p.is_symlink();q=target/p.relative_to(owner/'priv');n=str(q.relative_to(stage))
    accepted=str(p.relative_to(stage));r=release[accepted]
    if r.get('directory'):q.mkdir(mode=0o700,parents=True,exist_ok=True);directories[n]=r['mode']
    else:install(n,p,r)
    mapping.append({'path':n,'accepted_package_path':accepted})
   target.mkdir(mode=0o700,parents=True,exist_ok=True)
   directories[str(target.relative_to(stage))]=release[str((owner/'priv').relative_to(stage))]['mode']
   projections[str(target.relative_to(stage))]=mapping
 for n,mode in sorted(directories.items(),key=lambda pair:len(PurePosixPath(pair[0]).parts),reverse=True):(stage/n).chmod(mode)
 for n,r in files.items():
  p=stage/n;assert p.is_file() and not p.is_symlink() and p.stat().st_size==r['bytes'] and p.stat().st_mode&0o7777==r['mode'] and h(p)==r['sha256']
 assert (stage/'_build/prod/lib/quod/priv/ontologies/quod_controllers.pl').is_file()
 assert h(stage/'_build/prod/lib/quod/priv/native/quod_physics.so')==qualified['native_packaged_outputs']['priv/native/quod_physics.so']['sha256']
 assert (stage/'_build/test/lib/quod/test').is_dir()
 record.update(passed=True,authored_inputs=authored,compiled_entries=len(compiled),release_entries=len(release),shared_archive_paths=len(shared),
  private_resource_projection=projections,private_layout='Actual app-owned accepted packaged priv files materialized at that app owner path; no invented literal directory links.',files=files,directory_modes=directories)
finally:
 cache=TASK/'cache/server-runtime-restoration04-hashes.json';d.write(cache)
 record['digest_cache']={'path':str(cache),'sha256':raw(cache),'hits':d.hits,'new_files':d.new,'new_bytes':d.bytes}
 output.write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'passed':True,'stage':str(stage),'authored_inputs':1432,'compiled_entries':2059,'release_entries':len(release),
 'shared_archive_paths':len(shared),'private_resource_projections':len(projections),'actual_files':len(files),'new_build':False}))
