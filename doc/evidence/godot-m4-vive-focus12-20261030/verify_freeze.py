"""Independently materialize the complete source, additive patch, tar and groups."""
import json,os,shutil,subprocess,sys,tarfile
sys.dont_write_bytecode=True
from pathlib import Path,PurePosixPath
from freeze_hashes import Digests,TASK,key,raw
os.umask(0o077);b=Path(sys.argv[1]);d=Digests();h=d.h
def load(p):return json.loads(Path(p).read_text())
def write(p,v):Path(p).write_text(json.dumps(v,indent=2)+'\n')
groups=load(b/'object-groups.json');origins=load(b/'object-group-origins.json');storage=load(b/'object-storage.json');expected={}
for rows in groups.values():
 for r in rows.values():
  if r['kind']=='file':expected[r['sha256']]=r['bytes']
  elif 'resolved_sha256' in r:expected[r['resolved_sha256']]=r['resolved_bytes']
assert set(expected)==set(storage)=={p.name for p in (b/'objects').iterdir()}
reused=0;uncached=0
for digest,size in expected.items():
 p=b/'objects'/digest;r=storage[digest]
 assert p.is_file() and not p.is_symlink() and p.stat().st_size==size and p.stat().st_mode&0o222==0
 if r['method'].startswith('verified'):
  old=Path(r['source']);before=tuple(r['before_stat']);now=key(p)
  assert old.is_file() and not old.is_symlink() and key(old)==now and old.stat().st_mode&0o222==0
  if before in d.values:assert d.values[before]==digest
  else:assert h(p)==digest;uncached+=1
  assert now[:4]==before[:4] and old.stat().st_nlink==r['before_links']+1
  d.values[now]=digest;d.used[now]=digest;reused+=1
 else:assert h(p)==digest
print(json.dumps({'independent_objects_checked':len(expected),'actual_readonly_parent_inodes_reused':reused}),flush=True)
reference=load(b/'previous-boundary-reference.json');prior=Path(reference['path']);previous=Path(reference['previous_full_source'])
assert h(prior/'snapshot.json')==reference['snapshot_sha256']=='5e365156763eaefcd968fe7eaa1b3abc0f8044b0b5a203b534567e42dc592f9e'
old=load(prior/'source-manifest.json');source=load(b/'source-manifest.json');dirs=load(b/'source-directory-modes.json');links=load(b/'source-symlink-modes.json')
additions=set(source)-set(old);changed=set(load(b/'source-status.json')['changed_previous_paths']);delta_paths=additions|changed
assert len(changed)==2 and all(source.get(n)==r for n,r in old.items() if n not in changed)
copied=[]
scratch=TASK/'builds/vive-focus12-source-reconstruction01';scratch.mkdir(mode=0o700,exist_ok=False)
assert subprocess.run(['git','rev-parse','--show-toplevel'],cwd=scratch,capture_output=True).returncode!=0
for n,r in old.items():
 p=previous/n;q=scratch/n;q.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
 if r['kind']=='file':
  assert p.is_file() and not p.is_symlink() and p.stat().st_size==r['bytes'] and p.stat().st_mode&0o7777==r['mode'] and h(p)==r['sha256']
  if n in changed:
   original=key(p);original_links=p.stat().st_nlink;shutil.copy2(p,q)
   assert q.stat().st_nlink==1 and (q.stat().st_dev,q.stat().st_ino)!=(p.stat().st_dev,p.stat().st_ino) and h(q)==r['sha256']
   copied.append({'path':n,'original_stat':original,'original_links':original_links,'original_mode':r['mode'],'private_copy_stat_before_apply':key(q),'private_copy_links':1})
  else:
   assert p.stat().st_dev==scratch.stat().st_dev;d.link(p,q,r['sha256'])
 else:assert p.is_symlink() and str(p.readlink())==r['target'];q.symlink_to(r['target'])
d.write(b/'source-link-transition-digests.json')
write(b/'changed-files-copied-before-apply.json',copied)
commands=[]
for command in [['git','apply','-p2','--check',str(b/'delta.patch')],['git','apply','-p2',str(b/'delta.patch')]]:
 result=subprocess.run(command,cwd=scratch,capture_output=True)
 commands.append({'command':command,'true_exit':result.returncode,'stdout':result.stdout.decode(),'stderr':result.stderr.decode()})
 assert result.returncode==0
restored=[]
for n in sorted(delta_paths):
 r=source[n];p=scratch/n
 if r['kind']=='file':
  assert p.is_file() and not p.is_symlink() and p.stat().st_nlink==1
  before=p.stat().st_mode&0o7777;p.chmod(r['mode'])
  restored.append({'path':n,'scope':'Private copied changed file or newly patch-created file; no prior hardlinked file modified',
   'after_apply_mode':before,'recorded_mode':r['mode'],'restored_mode':p.stat().st_mode&0o7777})
write(b/'delta-apply-recorded-modes.json',restored)
for row in copied:
 p=previous/row['path'];assert key(p)==tuple(row['original_stat']) and p.stat().st_nlink==row['original_links'] and p.stat().st_mode&0o7777==row['original_mode']
 assert h(p)==old[row['path']]['sha256']
tarroot=TASK/'builds/vive-focus12-delta-reconstruction01';tarroot.mkdir(mode=0o700,exist_ok=False)
members=[];written=0
with tarfile.open(b/'delta-contents.tar','r:') as archive:
 for member in archive:
  rel=PurePosixPath(member.name);assert not rel.is_absolute() and '..' not in rel.parts and str(rel) in delta_paths
  n=str(rel);members.append(n);p=tarroot/n;assert not p.exists() and not p.is_symlink();p.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
  for parent in p.parents:
   if parent==tarroot:break
   assert not parent.is_symlink()
  if member.issym():p.symlink_to(member.linkname)
  else:
   assert member.isfile()
   with p.open('xb') as out:shutil.copyfileobj(archive.extractfile(member),out)
   p.chmod(member.mode);written+=p.stat().st_size
  r=source[n]
  if r['kind']=='file':assert p.is_file() and not p.is_symlink() and p.stat().st_mode&0o7777==r['mode'] and p.stat().st_size==r['bytes'] and h(p)==r['sha256']
  else:assert p.is_symlink() and str(p.readlink())==r['target'] and p.lstat().st_mode&0o7777==links[n]
assert len(members)==len(delta_paths) and set(members)==delta_paths
for n,mode in sorted(dirs.items(),key=lambda p:len(PurePosixPath(p[0]).parts),reverse=True):(scratch/n).chmod(mode)
def inventory(folder):
 files={};directories={}
 for parent,children,names in os.walk(folder,followlinks=False):
  parent=Path(parent)
  for name in list(children):
   p=parent/name
   if p.is_symlink():files[str(p.relative_to(folder))]=p;children.remove(name)
   else:directories[str(p.relative_to(folder))]=p.stat().st_mode&0o7777
  for name in names:files[str((parent/name).relative_to(folder))]=parent/name
 return files,directories
actual,actualdirs=inventory(scratch);assert set(actual)==set(source) and actualdirs==dirs
for n,r in source.items():
 p=actual[n]
 if r['kind']=='file':assert p.is_file() and not p.is_symlink() and p.stat().st_size==r['bytes'] and p.stat().st_mode&0o7777==r['mode'] and h(p)==r['sha256']
 else:assert p.is_symlink() and str(p.readlink())==r['target'] and p.lstat().st_mode&0o7777==links[n]
write(b/'independent-source-reconstruction.json',{'passed':True,'destination':str(scratch),'outside_every_checkout':True,
 'source_paths':len(source),'directories':len(dirs),'previous_source_paths':len(old),
 'previous_files_shared_by_real_same_filesystem_inodes':sum(r['kind']=='file' for n,r in old.items() if n not in changed),
 'prior_changed_files':len(changed),'changed_paths_privately_copied_before_apply':sorted(changed),'actual_binary_delta_commands':commands,
 'actual_tar_materialization':str(tarroot),'delta_tar_members':len(members),'new_tar_paths':len(additions),'changed_tar_paths':len(changed),'tar_file_bytes_actually_written':written,
 'all_complete_paths_contents_links_full_recorded_modes_checked':True,
 'method':'Actual sealed failed11 complete source reused by verified data-filesystem inodes, except two changed publishers copied into private distinct inodes BEFORE real git apply --check/apply. Full changed/new contents also extracted from delta-contents.tar. Only private changed copies and new files receive recorded-mode restoration; old original bytes/stat/modes verified unchanged. Complete base/HEAD/untracked graph referenced; no fresh whole-HEAD apply or3GB copy.'})
print(json.dumps({'independent_complete_source':len(source),'actual_delta_members':len(members),'new_paths':len(additions),'changed_paths':len(changed),'tar_bytes_written':written}),flush=True)
destination=TASK/'builds/vive-focus12-group-reconstruction01';destination.mkdir(mode=0o700,exist_ok=False)
assert subprocess.run(['git','rev-parse','--show-toplevel'],cwd=destination,capture_output=True).returncode!=0
results={};same_device_links=0;copies=0
for label,rows in groups.items():
 target=destination/label;target.mkdir(mode=0o700)
 for n,r in sorted(rows.items(),key=lambda p:(len(PurePosixPath(p[0]).parts),p[0])):
  rel=PurePosixPath(n);assert not rel.is_absolute() and '..' not in rel.parts and str(rel)!='.'
  q=target/n;q.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
  for parent in q.parents:
   if parent==target:break
   assert not parent.is_symlink()
  if r['kind']=='directory':q.mkdir(mode=0o700,exist_ok=True)
  elif r['kind']=='symlink':q.symlink_to(r['target'])
  else:
   p=Path(origins[label][n]);assert p.is_file() and not p.is_symlink() and p.stat().st_size==r['bytes'] and p.stat().st_mode&0o7777==r['mode'] and h(p)==r['sha256']
   if p.stat().st_dev==destination.stat().st_dev:d.link(p,q,r['sha256']);same_device_links+=1
   else:shutil.copyfile(b/'objects'/r['sha256'],q);q.chmod(r['mode']);copies+=1
 for n,r in sorted(rows.items(),key=lambda p:len(PurePosixPath(p[0]).parts),reverse=True):
  if r['kind']=='directory':(target/n).chmod(r['mode'])
 files,dd=inventory(target);assert set(files)|set(dd)==set(rows)
 total=0
 for n,r in rows.items():
  q=target/n;assert q.lstat().st_mode&0o7777==r['mode'],(label,n,'mode')
  if r['kind']=='file':assert q.is_file() and not q.is_symlink() and q.stat().st_size==r['bytes'] and h(q)==r['sha256'];total+=r['bytes']
  elif r['kind']=='symlink':assert q.is_symlink() and str(q.readlink())==r['target']
  else:assert q.is_dir() and not q.is_symlink()
 results[label]={'entries':len(rows),'file_bytes':total,'full_paths_contents_links_recorded_modes_verified':True}
 print(json.dumps({'materialized':label,**results[label]}),flush=True)
write(b/'independent-object-reconstruction.json',{'passed':True,'objects':len(expected),
 'readonly_sealed_failed11_objects_reused_by_actual_inode':reused,'uncached_prior_objects_requiring_byte_verification':uncached,
 'destination':str(destination),'outside_every_checkout':True,'groups':results,
 'actual_same_filesystem_output_links':same_device_links,'actual_cross_filesystem_object_byte_copies':copies,
 'compiled_output_supplied_as_build_input':False,'method':'Complete actual new group materialization after qualification, preserving original modes and literal links. Referenced external targets retained as verified objects, not a runnable relocated sysroot.'})
d.write(b/'reconstruction-used-digests.json')
print(json.dumps({'explicit_completion':True,'source_paths':len(source),'object_groups':len(groups),'objects':len(expected),
 'strict_cache_hits':d.hits,'new_hashes':d.new,'new_bytes_hashed':d.bytes}),flush=True)
