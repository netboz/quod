"""Freeze the single case13 recipient/lifecycle observation against accepted97."""
import json,os,shutil,signal,subprocess,sys,tarfile,time
sys.dont_write_bytecode=True
from pathlib import Path,PurePosixPath
from freeze_hashes import Digests,TASK,key,raw,SOURCES
sys.path.append(str(Path(__file__).resolve().parent.parent/'godot-m4-vive-physical-20261029'))
from environment import environment
root=Path.cwd();ev=Path(__file__).resolve().parent;run_id='01'
prior=TASK/'artifacts/quod-godot-m4-vive-focus-recipient-handoff-ca84d4f8-20261030-01'
boundary=TASK/'artifacts/quod-godot-m4-vive-focus13-handoff-ca84d4f8-20261030-02'
runs=TASK/'artifacts/vive-focus13-freeze-runs02'
def load(p):return json.loads(Path(p).read_text())
def write(p,v):Path(p).write_text(json.dumps(v,indent=2)+'\n')
def git(*a):return subprocess.check_output(['git',*a],cwd=root)
def names(*a):return set(filter(None,git(*a,'-z').decode().split('\0')))
if sys.argv[1:]!=['--child']:
 assert not sys.argv[1:];os.umask(0o077);runs.mkdir(mode=0o700,exist_ok=False)
 copies=runs/'driver-inputs';copies.mkdir(mode=0o700)
 for p in ev.glob('*.py'):shutil.copy2(p,copies/p.name)
 shutil.copy2(ev.parent/'godot-m4-vive-retest10-20261030/focus_events.py',copies/'focus_events.py')
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
assert h(prior/'snapshot.json')=='2a31552df1860b7f0df312db7df83f9c1b639b17ef88bb5fe12a031a0a86ccf9'
parent=load(prior/'snapshot.json');old=load(prior/'source-manifest.json')
expected_changes=load(ev/'source-delta.json')['existing_changed_sources']
assert git('branch','--show-current').decode().strip()=='worktree/pearl-stone'
assert git('rev-parse','HEAD').decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert git('rev-parse','HEAD^').decode().strip()=='f716ddf5e578df957a5b18421a0727a32c634f87'
assert not git('diff','--cached','--name-only') and git('diff','--check')==b''
patch=git('diff','--binary','HEAD');assert patch==(prior/'tracked.patch').read_bytes()
assert load(ev/'qualification.json')['production_application_engine_runtime_changes']==0 and load(ev/'qualification.json')['inherited_source_changes']==0
tracked=names('ls-files','--cached');untracked=names('ls-files','--others','--exclude-standard')
source={};dirs={};links={}
for n in sorted(tracked|untracked):
 p=root/n;mode=p.lstat().st_mode&0o7777
 if p.is_symlink():source[n]={'kind':'symlink','target':str(p.readlink()),'tracked':n in tracked};links[n]=mode
 else:
  assert p.is_file()
  if n in old and n not in expected_changes:assert key(p) in d.values,('fresh prior source custody required',n)
  source[n]={'kind':'file','sha256':h(p),'bytes':p.stat().st_size,'mode':mode,'tracked':n in tracked}
 for parentdir in PurePosixPath(n).parents:
  if str(parentdir)!='.':dirs[str(parentdir)]=(root/str(parentdir)).stat().st_mode&0o7777
changed=sorted(n for n,r in old.items() if source.get(n)!=r)
assert changed==sorted(expected_changes),changed
for n,row in expected_changes.items():
 assert old[n]['kind']==source[n]['kind']=='file' and old[n]['mode']==source[n]['mode']
 assert old[n]['sha256']==row['before_sha256'] and source[n]['sha256']==row['after_sha256']
additions=sorted(set(source)-set(old));assert additions
delta_paths=sorted(set(additions)|set(changed))
authorization='nimbalyst-local/handoffs/godot-m4-vive-focus-recipient-live-prompt-98.md'
assert h(root/authorization)=='a6d42471f7188c9720b4c653bba178dc6a6cbb7988c15ae27341a62a1501386a'
server_ev=root/'doc/evidence/godot-m4-vive-physical-20261029'
server_label='native-vive-product13-server';server_receipt=server_ev/'inputs'/('server-'+server_label+'.json')
r=load(server_receipt);assert r['profile']=='prod' and not r['runtime_recompiled'] and r['stage'].endswith('/server-runtime-restoration05')
assert set(r['driver_sources'])=={'serve.py','godot_m3b_fixture.erl','godot_m3b_physics_fixture.erl'}
server_inputs={str(server_receipt.relative_to(root))}
for name,row in r['driver_sources'].items():
 p=Path(row['path']);assert p==server_ev/'inputs'/(server_label+'-'+name)
 assert h(p)==row['sha256']==h(server_ev/name);server_inputs.add(str(p.relative_to(root)))
assert len(server_inputs)==4
assert all(n==authorization or n=='nimbalyst-local/handoffs/godot-m4-vive-focus13-result.md' or n in server_inputs or
 n.startswith('doc/evidence/godot-m4-vive-focus13-20261030/') for n in additions),additions
assert sum(n.startswith('.agents/') for n in untracked)==31
boundary.mkdir(mode=0o700);(boundary/'objects').mkdir(mode=0o700)
write(boundary/'source-manifest.json',source);write(boundary/'source-directory-modes.json',dirs);write(boundary/'source-symlink-modes.json',links)
(boundary/'tracked.patch').write_bytes(patch)
write(boundary/'source-status.json',{'head':'293cf6115c0a6b18315eccdbb42cbca396f443d3','parent':'f716ddf5e578df957a5b18421a0727a32c634f87',
 'branch':'worktree/pearl-stone','index_empty':True,'source_entries':len(source),'previous_entries':len(old),
 'new_additions':additions,'changed_previous_paths':changed,'generated_agents':31,'production_changes':0,
 'functional_application_executed':True,'full_physical_acceptance':False,'qualified_focus_listener_was_armed_once':True,'diagnostic_inherited_files_changed':changed,'implementation_writer_frozen':True})
with tarfile.open(boundary/'delta-contents.tar','x:') as archive:
 for n in delta_paths:archive.add(root/n,arcname=n,recursive=False)
diffroot=runs/'source-delta-inputs';diffroot.mkdir();(diffroot/'before').mkdir();after=diffroot/'after';after.mkdir()
for n in changed:
 p=TASK/'builds/coordinator-focus-recipient-source-reconstruction-97'/n;q=diffroot/'before'/n;q.parent.mkdir(parents=True,exist_ok=True)
 assert h(p)==old[n]['sha256'];shutil.copy2(p,q)
for n in delta_paths:
 p=root/n;q=after/n;q.parent.mkdir(parents=True,exist_ok=True)
 if p.is_symlink():q.symlink_to(p.readlink())
 else:shutil.copy2(p,q)
command=['git','diff','--no-index','--binary','--src-prefix=a/','--dst-prefix=b/','before','after']
delta=subprocess.run(command,cwd=diffroot,capture_output=True);assert delta.returncode==1 and delta.stdout and not delta.stderr
(boundary/'delta.patch').write_bytes(delta.stdout)
write(boundary/'delta-generation.json',{'command':command,'cwd':str(diffroot),'true_exit':delta.returncode,
 'exit1_means_actual_differences':True,'stderr':delta.stderr.decode(),'strip_components_for_apply':2,
 'scope':'Real binary delta of every new path; inherited source is unchanged. Before-side entries would be copied from accepted root97 if a changed inherited path existed; there are none.'})
write(boundary/'previous-boundary-reference.json',{'path':str(prior),'snapshot_sha256':h(prior/'snapshot.json'),
 'previous_full_source':str(TASK/'builds/coordinator-focus-recipient-source-reconstruction-97'),
 'scope':'Accepted recipient97 complete source references its retained earlier base/HEAD/full-untracked graph. New real binary delta/full changed-new contents retained; no fresh whole-HEAD base apply or3GB history copy.'})
stored={};groups={};origins={}
def keep(p):
 digest=h(p)
 if digest in stored:return digest
 q=boundary/'objects'/digest;old_object=prior/'objects'/digest
 if ('objects/'+digest) in parent['artifacts']:
  before=key(old_object);before_links=old_object.stat().st_nlink
  assert not old_object.is_symlink() and old_object.stat().st_mode&0o222==0 and h(old_object)==digest
  d.link(old_object,q,digest)
  stored[digest]={'method':'verified readonly sealed recipient97 object; actual same-filesystem inode reuse','source':str(old_object),
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
def selected(label,origin,paths):
 rows={};paths_by_name={}
 for p in paths:
  assert p.is_relative_to(origin)
  q=p
  while q!=origin:
   n=str(q.relative_to(origin));rows[n]=row(q);paths_by_name[n]=str(q);q=q.parent
 groups[label]=rows;origins[label]=paths_by_name
owners=TASK/'private/case13-preparation01/unchanged-owners'
selected('actual-unchanged-private-invocation-sources',owners,[owners/'godot-m4-vive-retest-20261030/physical09.py',
 *[(owners/'godot-m4-vive-physical-20261029'/n) for n in ['manual_run.py','environment.py','publication.py']]])
tree('actual-case13-executed-driver-sources',TASK/'private/native-vive-product13/drivers')
for name in ['native-vive-product13-run','native-vive-product13-focus-run']:
 tree(name+'-actual-wrapper-inputs',TASK/'private/runs'/name/'driver-inputs')
origin=TASK/'private/build-inputs/native-vive-product13-focus'
selected('actual-focus13-preexecution-code-only',origin,sorted(origin.glob('*.py')))
for name in ['focus13-preparation01','focus13-baseline-capture01','focus13-owner-guard01','focus13-after-focus-capture01','focus13-loss-capture01','focus13-api01','focus13-receipt-binding01','focus13-freeze-preflight01','focus13-freeze-preflight02','focus13-freeze-preflight03']:
 tree(name+'-actual-metadata-inputs',TASK/'private/runs'/name/'driver-inputs')
 label=name+'-safe-metadata-streams';groups[label]={};origins[label]={}
 for stream in ['stdout.raw','stderr.raw']:
  p=TASK/'private/runs'/name/stream;groups[label][stream]=row(p);origins[label][stream]=str(p)
tree('actual-freeze-driver-inputs',runs/'driver-inputs')
failed_runs=TASK/'artifacts/vive-focus13-freeze-runs01'
tree('preserved-failed-freeze01-executed-inputs',failed_runs/'driver-inputs')
selected('preserved-failed-freeze01-result-and-full-logs',failed_runs,[failed_runs/n for n in ['result.json','stdout.log','stderr.log']])
write(boundary/'preserved-failed-freeze01-reference.json',load(ev/'failed-freeze01-disposition.json'))
label='actual-filtered-focus13-events';p=TASK/'private/native-vive-product13-focus/filtered-events.jsonl'
groups[label]={p.name:row(p)};origins[label]={p.name:str(p)}
label='actual-fixture-code-outputs';groups[label]={};origins[label]={}
for p in sorted((TASK/'private/quod-m4-live-native-vive-product13-server').iterdir()):
 if p.is_file() and p.suffix in ['.erl','.beam']:groups[label][p.name]=row(p);origins[label][p.name]=str(p)
assert groups[label]
label='actual-provider-preflight-inputs';groups[label]={};origins[label]={}
for name in ['display-inventory','display_inventory.c','vive_display.py']:
 p=TASK/'private/case13-preparation01'/name;groups[label][name]=row(p);origins[label][name]=str(p)
groups['accepted-independent-prerequisite']={};origins['accepted-independent-prerequisite']={}
for name in ['focus-recipient-final-verification-97.json','coordinator-role-binding-check-98.json','focus13-delivery-guard-100.json']:
 p=root/'_build/godot-m4-r2-coordinator-20261029'/name
 groups['accepted-independent-prerequisite'][name]=row(p);origins['accepted-independent-prerequisite'][name]=str(p)

write(boundary/'object-groups.json',groups);write(boundary/'object-group-origins.json',origins);write(boundary/'object-storage.json',stored)
d.write(boundary/'pre-reconstruction-digests.json')
write(boundary/'input-output-classification.json',{'unchanged_supplied_inputs':93,'unchanged_exports':196,
 'source_delta':'No inherited source change. New case13 invocation, read-only capture and privacy projection/evidence helpers only; actual physical09/manual_run/publication/observer/engine/runtime bytes unchanged.',
 'dependencies':'Accepted preparation65 payload/private engine/Monado/restoration05/closure73 reused, no build or unchanged-suite recount. Actual invocation copied byte-identically into private Data so original publishers keep raw records private.',
 'outputs':'Actual filtered first-successor event/lifetime, safe gates/resource/display/calibration receipts, exact preexecution sources and fixture code/beam outputs. All full raw streams and their ownership/role/room records remain restricted at the exact referenced private origins.',
 'privacy':'Private roles/bindings/actual live command/owner/room/raw API/stores/keys are excluded from snapshot objects; public full stream projections retain every line as safe protocol or explicit restricted-line digest. No successor address or unrelated client reply retained.',
 'parent_scope':'Accepted recipient97 snapshot and actual root97 complete source retained. No inherited source changed; real additions binary delta/full tar materialized. Separate-copy-before-patch rule remains enforced for any changed paths (none here). No3GB history copy or old API reread.'})
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
write(boundary/'snapshot.json',{'checkpoint':'QUO-65 case13 first empty-notification focus-recipient observation; no human look confirmation','worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f',
 'actual_model':'openai-codex:gpt-6.1-sol','launcher_effort':'max','backend_effective_effort':'unexposed',
 'artifacts':artifacts,'previous_boundary':str(prior),'previous_snapshot_sha256':h(prior/'snapshot.json'),
 'source_entries':len(source),'source_additions':len(additions),'changed_previous_paths':changed,
 'source_and_groups_actually_reconstructed':True,'implementation_writer_frozen':True,
 'new_product_build':False,'godot_application_executed':True,'physical_observation_scope':'Actual native/source and protocol retirement only; no confirmed human model look, no case14','distributable':False,'full_m4_accepted':False})
for p in boundary.rglob('*'):
 if p.is_file() and p.stat().st_mode&0o222:p.chmod(0o444)
for p in sorted([p for p in boundary.rglob('*') if p.is_dir()],key=lambda p:len(p.parts),reverse=True):p.chmod(0o555)
boundary.chmod(0o555)
print(json.dumps({'frozen':True,'boundary':str(boundary),'snapshot_sha256':raw(boundary/'snapshot.json'),
 'delta_sha256':raw(boundary/'delta.patch'),'delta_contents_sha256':raw(boundary/'delta-contents.tar'),
 'source_entries':len(source),'source_additions':len(additions),'changed_previous_paths':changed,
 'artifacts':len(artifacts),'objects':len(stored),'prior_readonly_objects_reused':sum(r['method'].startswith('verified') for r in stored.values()),
 'source_materialization':str(TASK/'builds/vive-focus13-source-reconstruction02'),
 'group_materialization':str(TASK/'builds/vive-focus13-group-reconstruction02'),
 'cache_hits':d.hits,'new_hashes':d.new,'new_bytes_hashed':d.bytes}),flush=True)
