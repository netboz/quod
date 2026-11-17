"""Freeze only the new case10 and offline observer evidence, referencing its sealed parent source graph."""
import json,os,shutil,signal,subprocess,sys,tarfile,time
sys.dont_write_bytecode=True
from pathlib import Path,PurePosixPath
from freeze_hashes import Digests,TASK,key,raw,SOURCES
from scope import server_artifacts
sys.path.append(str(Path(__file__).resolve().parent.parent/'godot-m4-vive-physical-20261029'))
from environment import environment
root=Path.cwd();ev=Path(__file__).resolve().parent;run_id='01'
prior=TASK/'artifacts/quod-godot-m4-vive-retest-handoff-ca84d4f8-20261030-01'
boundary=TASK/'artifacts/quod-godot-m4-vive-retest10-handoff-ca84d4f8-20261030-01'
runs=TASK/'artifacts/vive-retest10-freeze-runs01'
def load(p):return json.loads(Path(p).read_text())
def write(p,v):Path(p).write_text(json.dumps(v,indent=2)+'\n')
def git(*a):return subprocess.check_output(['git',*a],cwd=root)
def names(*a):return set(filter(None,git(*a,'-z').decode().split('\0')))
if sys.argv[1:]!=['--child']:
 assert not sys.argv[1:];os.umask(0o077);runs.mkdir(mode=0o700,exist_ok=False)
 copies=runs/'driver-inputs';copies.mkdir(mode=0o700)
 for p in ev.glob('*.py'):shutil.copy2(p,copies/p.name)
 command=[sys.executable,str(ev/'freeze.py'),'--child'];started=time.monotonic();timeout=False
 with (runs/'stdout.log').open('xb') as out,(runs/'stderr.log').open('xb') as err:
  child=subprocess.Popen(command,cwd=root,env=environment(),stdout=out,stderr=err,start_new_session=True)
  try:status=child.wait(timeout=900)
  except subprocess.TimeoutExpired:
   timeout=True;os.killpg(child.pid,signal.SIGTERM)
   try:status=child.wait(timeout=10)
   except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);status=child.wait()
 summary=None
 for line in (runs/'stdout.log').read_text().splitlines():
  if line.startswith('{'):
   row=json.loads(line)
   if row.get('frozen'):summary=row
 result={'command':command,'true_child_exit':status,'timed_out':timeout,'elapsed_seconds':time.monotonic()-started,
  'explicit_completion':summary is not None,'passed':status==0 and not timeout and summary is not None,'summary':summary,
  'stdout':{'path':str(runs/'stdout.log'),'sha256':raw(runs/'stdout.log')},
  'stderr':{'path':str(runs/'stderr.log'),'sha256':raw(runs/'stderr.log')}}
 write(runs/'result.json',result);print(json.dumps(result));raise SystemExit(0 if result['passed'] else 1)
os.umask(0o077);assert not boundary.exists();d=Digests();h=d.h
assert h(prior/'snapshot.json')=='560ee1a4b1be5c01bac72d35318b4c2f2a4199e107ba9cf9870a87a9599dbcc4'
parent=load(prior/'snapshot.json');old=load(prior/'source-manifest.json')
assert git('branch','--show-current').decode().strip()=='worktree/pearl-stone'
assert git('rev-parse','HEAD').decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert git('rev-parse','HEAD^').decode().strip()=='f716ddf5e578df957a5b18421a0727a32c634f87'
assert not git('diff','--cached','--name-only') and git('diff','--check')==b''
patch=git('diff','--binary','HEAD');assert patch==(prior/'tracked.patch').read_bytes()
assert load(ev/'qualification.json')['product_source_changes']==0
tracked=names('ls-files','--cached');untracked=names('ls-files','--others','--exclude-standard')
source={};dirs={};links={}
for n in sorted(tracked|untracked):
 p=root/n;mode=p.lstat().st_mode&0o7777
 if p.is_symlink():source[n]={'kind':'symlink','target':str(p.readlink()),'tracked':n in tracked};links[n]=mode
 else:assert p.is_file();source[n]={'kind':'file','sha256':h(p),'bytes':p.stat().st_size,'mode':mode,'tracked':n in tracked}
 for parentdir in PurePosixPath(n).parents:
  if str(parentdir)!='.':dirs[str(parentdir)]=(root/str(parentdir)).stat().st_mode&0o7777
changed=sorted(n for n,r in old.items() if source.get(n)!=r);assert changed==[],changed
additions=sorted(set(source)-set(old));assert additions
published_server_inputs=server_artifacts(root,h)
assert all(n in published_server_inputs or n.startswith(('doc/evidence/godot-m4-vive-retest10-20261030/',
 'doc/evidence/godot-m4-r2-coordinator-20261029/','nimbalyst-local/handoffs/godot-m4-vive-retest10-',
 'doc/evidence/godot-m4-vive-retest-20261030/native-vive-product10/',
 'doc/evidence/godot-m4-vive-physical-20261029/logs/native-vive-product10-run')) for n in additions),additions
assert sum(n.startswith('.agents/') for n in untracked)==31
boundary.mkdir(mode=0o700);(boundary/'objects').mkdir(mode=0o700)
write(boundary/'source-manifest.json',source);write(boundary/'source-directory-modes.json',dirs);write(boundary/'source-symlink-modes.json',links)
(boundary/'tracked.patch').write_bytes(patch)
write(boundary/'source-status.json',{'head':'293cf6115c0a6b18315eccdbb42cbca396f443d3','parent':'f716ddf5e578df957a5b18421a0727a32c634f87',
 'branch':'worktree/pearl-stone','index_empty':True,'source_entries':len(source),'previous_entries':len(old),
 'new_additions':additions,'changed_previous_paths':changed,'generated_agents':31,'production_changes':0,
 'functional_application_executed':True,'full_physical_acceptance':False,'prepared_focus_listener_armed':False,'implementation_writer_frozen':True})
with tarfile.open(boundary/'additions.tar','x:') as archive:
 for n in additions:archive.add(root/n,arcname=n,recursive=False)
diffroot=runs/'source-delta-inputs';diffroot.mkdir();(diffroot/'before').mkdir();after=diffroot/'after';after.mkdir()
for n in additions:
 p=root/n;q=after/n;q.parent.mkdir(parents=True,exist_ok=True)
 if p.is_symlink():q.symlink_to(p.readlink())
 else:shutil.copy2(p,q)
command=['git','diff','--no-index','--binary','--src-prefix=a/','--dst-prefix=b/','before','after']
delta=subprocess.run(command,cwd=diffroot,capture_output=True);assert delta.returncode==1 and delta.stdout and not delta.stderr
(boundary/'delta.patch').write_bytes(delta.stdout)
write(boundary/'delta-generation.json',{'command':command,'cwd':str(diffroot),'true_exit':delta.returncode,
 'exit1_means_actual_differences':True,'stderr':delta.stderr.decode(),'strip_components_for_apply':2,
 'scope':'Actual binary no-index delta of all added paths; no prior source path changed.'})
write(boundary/'previous-boundary-reference.json',{'path':str(prior),'snapshot_sha256':h(prior/'snapshot.json'),
 'previous_full_source':str(TASK/'builds/vive-retest-source-reconstruction01'),
 'scope':'Sealed worker retest01 references the accepted65/base/HEAD/full-untracked graph recursively. This boundary retains actual unchanged HEAD patch, actual binary additive delta and full additions archive. No fresh whole-HEAD base-apply claim or extra3GB history copy.'})
stored={};groups={};origins={}
def keep(p):
 digest=h(p)
 if digest in stored:return digest
 q=boundary/'objects'/digest;old_object=prior/'objects'/digest
 if ('objects/'+digest) in parent['artifacts']:
  before=key(old_object);before_links=old_object.stat().st_nlink
  assert not old_object.is_symlink() and old_object.stat().st_mode&0o222==0 and h(old_object)==digest
  d.link(old_object,q,digest)
  stored[digest]={'method':'verified readonly sealed retest01 object; actual same-filesystem inode reuse','source':str(old_object),
   'before_stat':before,'before_links':before_links,'bytes':q.stat().st_size}
 else:
  shutil.copyfile(p,q);q.chmod(0o444);assert raw(q)==digest
  d.values[key(q)]=digest;d.used[key(q)]=digest
  stored[digest]={'method':'new bytes copied and independently hashed','bytes':q.stat().st_size}
 return digest
def row(p):
 mode=p.lstat().st_mode&0o7777
 if p.is_symlink():
  r={'kind':'symlink','target':str(p.readlink()),'mode':mode}
  if p.is_file():r.update(resolved_sha256=keep(p),resolved_bytes=p.stat().st_size)
  return r
 if p.is_dir():return {'kind':'directory','mode':mode}
 assert p.is_file() and p.name not in ['active.json','writer.lock','tls-key.pem','proxy-key.pem']
 return {'kind':'file','mode':mode,'sha256':keep(p),'bytes':p.stat().st_size}
def tree(label,origin):
 assert origin.is_dir() and not origin.is_symlink(),('required captured group origin',str(origin))
 rows={};paths={}
 for directory,children,files in os.walk(origin,followlinks=False):
  directory=Path(directory)
  for name in list(children):
   p=directory/name;n=str(p.relative_to(origin));rows[n]=row(p);paths[n]=str(p)
   if p.is_symlink():children.remove(name)
  for name in files:
   p=directory/name;n=str(p.relative_to(origin));rows[n]=row(p);paths[n]=str(p)
 groups[label]=rows;origins[label]=paths
tree('case10-preexecution',TASK/'private/build-inputs/native-vive-product10')
tree('case10-executed-driver-inputs',TASK/'private/native-vive-product10/drivers')
tree('case10-wrapper-inputs',TASK/'private/runs/native-vive-product10-run/driver-inputs')
for name in ['case10-preflight01','case10-api01','case10-focus-source01','case10-sanitize01',
 'case10-focus-checks01','case10-focus-checks02','case10-provenance01','case10-result-verification01',
 'case10-result-verification02','case10-finalize-offline01','case10-deadline-checks01','case10-finalize-deadline01',
 'case10-freeze-preflight01']:
 tree('metadata-'+name,TASK/'private/metadata-inputs'/name)
groups['primary-protocol-sources']={};origins['primary-protocol-sources']={}
for name in ['hyprland-efb509-event-manager.cpp','hyprland-efb509-compositor.cpp','hyprland-efb509-focus-state.cpp','hyprland-efb509-tree.json']:
 for suffix in ['', '.receipt.json']:
  p=TASK/'downloads'/(name+suffix)
  groups['primary-protocol-sources'][name+suffix]=row(p);origins['primary-protocol-sources'][name+suffix]=str(p)

tree('actual-freeze-driver-inputs',runs/'driver-inputs')
label='actual-case10-fixture-helper-input-output';groups[label]={};origins[label]={}
fixture=TASK/'private/quod-m4-live-native-vive-product10-server'
for p in sorted(fixture.iterdir()):
 if p.is_file() and p.suffix in ['.erl','.beam']:
  groups[label][p.name]=row(p);origins[label][p.name]=str(p)
assert groups[label]
groups['accepted-independent-prerequisite']={};origins['accepted-independent-prerequisite']={}
for name in ['reconnect-completion-check-79.json','case10-closure-check-84.json',
 'focus-offline-check-85.json','retest-artifact-check-85.json']:
 p=root/'_build/godot-m4-r2-coordinator-20261029'/name
 groups['accepted-independent-prerequisite'][name]=row(p);origins['accepted-independent-prerequisite'][name]=str(p)

write(boundary/'object-groups.json',groups);write(boundary/'object-group-origins.json',origins);write(boundary/'object-storage.json',stored)
d.write(boundary/'pre-reconstruction-digests.json')
write(boundary/'input-output-classification.json',{'unchanged_supplied_inputs':93,'unchanged_exports':196,
 'source_delta':'New case10 metadata and receipts only. Exact unchanged physical09 driver receives a new separately authorized label; no production/observer/engine/runtime source or policy change.',
 'dependencies':'Accepted preparation65 payload/private engine/Monado and accepted restoration05/34app944module250priv preflight reused. No build or unchanged suite recount.',
 'outputs':'Actual case10 helper sources/beams, preexecution copies and sanitized application/runtime/wrapper evidence. Private API/raw geometry/stores/keys/calibration/stacks stay in original restricted locations, bound by public sanitized receipts.',
 'privacy':'No private stores, credentials, room coordinates or raw serial-bearing logs are added to snapshot objects.',
 'parent_scope':'Sealed worker retest01 snapshot references accepted65/base/HEAD/untracked graph. Independent root85 checks parent artifacts and actual worker materialization; root new source materialization remains pending after this freeze. No claim that pending root tree already exists.'})
print(json.dumps({'source_entries':len(source),'source_additions':len(additions),'changed_previous_paths':changed,'groups':len(groups),'objects':len(stored)}),flush=True)
command=[sys.executable,str(ev/'verify_freeze.py'),str(boundary)]
assert subprocess.run(command,cwd=root,env=environment()).returncode==0
assert git('diff','--binary','HEAD')==patch and not git('diff','--cached','--name-only')
assert names('ls-files','--cached')==tracked and names('ls-files','--others','--exclude-standard')==untracked
for n,r in source.items():
 p=root/n
 if r['kind']=='file':assert h(p)==r['sha256'] and p.stat().st_mode&0o7777==r['mode']
 else:assert p.is_symlink() and str(p.readlink())==r['target']
write(boundary/'qualification.json',load(ev/'qualification.json'));d.write(boundary/'freeze-used-digests.json')
artifacts={str(p.relative_to(boundary)):{'sha256':h(p),'bytes':p.stat().st_size} for p in boundary.rglob('*') if p.is_file()}
write(boundary/'snapshot.json',{'checkpoint':'QUO-65 corrected-payload physical case10','worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f',
 'actual_model':'openai-codex:gpt-6.1-sol','launcher_effort':'max','backend_effective_effort':'unexposed',
 'artifacts':artifacts,'previous_boundary':str(prior),'previous_snapshot_sha256':h(prior/'snapshot.json'),
 'source_entries':len(source),'source_additions':len(additions),'changed_previous_paths':changed,
 'source_and_groups_actually_reconstructed':True,'implementation_writer_frozen':True,
 'new_product_build':False,'godot_application_executed':True,'physical_observation_scope':'See exact qualification receipt; no full M4 claim','distributable':False,'full_m4_accepted':False})
for p in boundary.rglob('*'):
 if p.is_file() and p.stat().st_mode&0o222:p.chmod(0o444)
for p in sorted([p for p in boundary.rglob('*') if p.is_dir()],key=lambda p:len(p.parts),reverse=True):p.chmod(0o555)
boundary.chmod(0o555)
print(json.dumps({'frozen':True,'boundary':str(boundary),'snapshot_sha256':raw(boundary/'snapshot.json'),
 'delta_sha256':raw(boundary/'delta.patch'),'additions_sha256':raw(boundary/'additions.tar'),
 'source_entries':len(source),'source_additions':len(additions),'changed_previous_paths':changed,
 'artifacts':len(artifacts),'objects':len(stored),'prior_readonly_objects_reused':sum(r['method'].startswith('verified') for r in stored.values()),
 'source_materialization':str(TASK/'builds/vive-retest10-source-reconstruction01'),
 'group_materialization':str(TASK/'builds/vive-retest10-group-reconstruction01'),
 'cache_hits':d.hits,'new_hashes':d.new,'new_bytes_hashed':d.bytes}),flush=True)
