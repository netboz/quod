"""Small additive closure seal: exact new bytes; no bulk inherited reconstruction."""
import hashlib,json,os,shutil,stat,subprocess,sys,tarfile,time
from pathlib import Path,PurePosixPath
sys.dont_write_bytecode=True
from freeze_hashes import TASK,raw
os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent
prior=TASK/'artifacts/quod-godot-m4-vive-focus15-handoff-ca84d4f8-20261030-01'
base=TASK/'builds/coordinator-focus13-source-reconstruction-104'
boundary=TASK/'artifacts/quod-godot-m4-vive-headset16-handoff-ca84d4f8-20261030-01'
runs=TASK/'artifacts/vive-headset16-freeze-runs01'
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def git(*args):return subprocess.check_output(['git',*args],cwd=root)
def inventory():return set(filter(None,git('ls-files','--cached','--others','--exclude-standard','-z').decode().split('\0')))
def row(p):
 m=p.lstat().st_mode&0o7777
 if p.is_symlink():return {'kind':'symlink','target':str(p.readlink()),'mode':m}
 if p.is_dir():return {'kind':'directory','mode':m}
 assert p.is_file();return {'kind':'file','mode':m,'sha256':raw(p),'bytes':p.stat().st_size}
if sys.argv[1:]!=['--child']:
 assert not sys.argv[1:];runs.mkdir(mode=0o700,exist_ok=False);copies=runs/'driver-inputs';copies.mkdir(mode=0o700)
 for p in ev.glob('*.py'):shutil.copy2(p,copies/p.name)
 command=[sys.executable,'-B',str(Path(__file__).resolve()),'--child'];started=time.monotonic()
 with (runs/'stdout.log').open('xb') as out,(runs/'stderr.log').open('xb') as err:
  child=subprocess.run(command,stdout=out,stderr=err,timeout=120)
 summary=None
 for line in (runs/'stdout.log').read_text().splitlines():
  if line.startswith('{'):
   candidate=json.loads(line)
   if candidate.get('frozen'):summary=candidate
 result={'command':command,'true_child_exit':child.returncode,'timed_out':False,'elapsed_seconds':time.monotonic()-started,
  'explicit_completion':summary is not None,'summary':summary,'passed':child.returncode==0 and summary is not None,
  'stdout':{'path':str(runs/'stdout.log'),'sha256':raw(runs/'stdout.log')},'stderr':{'path':str(runs/'stderr.log'),'sha256':raw(runs/'stderr.log')}}
 write(runs/'result.json',result);print(json.dumps(result));raise SystemExit(0 if result['passed'] else 1)
assert not boundary.exists() and raw(prior/'snapshot.json')=='78b6086c09e613db67f6e9b4e22820dca9c68efe728931ff565e80718139e9a2'
cache=TASK/'cache/coordinator-focus13-final104-hashes.json'
assert raw(cache)=='ce50196ffcbf29778e60b8c3242a659c0fdb196258ba9da5edf573829e831afa'
assert base.is_dir()
assert git('branch','--show-current').decode().strip()=='worktree/pearl-stone'
assert git('rev-parse','HEAD').decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert git('rev-parse','HEAD^').decode().strip()=='f716ddf5e578df957a5b18421a0727a32c634f87'
assert not git('diff','--cached','--name-only') and not git('diff','--check')
tracked_patch=git('diff','--binary','HEAD');assert tracked_patch==(prior/'tracked.patch').read_bytes()
ancestor=TASK/'artifacts/quod-godot-m4-vive-focus13-handoff-ca84d4f8-20261030-02'
inherited=json.loads((ancestor/'source-manifest.json').read_text());parent_delta=json.loads((prior/'delta-source-manifest.json').read_text())
middle=TASK/'artifacts/quod-godot-m4-vive-focus14-handoff-ca84d4f8-20261030-01'
middle_delta=json.loads((middle/'delta-source-manifest.json').read_text())
assert not(set(inherited)&set(parent_delta)) and not(set(middle_delta)&set(parent_delta))
old={**inherited,**middle_delta,**parent_delta};current=inventory();assert set(old)<=current
additions=sorted(current-set(old));assert additions
allowed={'nimbalyst-local/handoffs/godot-m4-vive-headset16-result.md'}
allowed.update(str(p.relative_to(root)) for p in (root/'doc/evidence/godot-m4-vive-physical-20261029/inputs').glob('*native-vive-product16-server*'))
assert all(n in allowed or n.startswith(('doc/evidence/godot-m4-vive-headset16-20261030/','doc/evidence/godot-m4-vive-headset-cue-20261030/','doc/evidence/godot-m4-vive-focus15-20261030/logs/cue-gates0')) for n in additions),additions
assert sum(n.startswith('.agents/') for n in current)==31
source={n:row(root/n) for n in additions};directories={}
for n in additions:
 for p in PurePosixPath(n).parents:
  if str(p)!='.':directories[str(p)]=(root/str(p)).stat().st_mode&0o7777
assert not any(n in old for n in source)
boundary.mkdir(mode=0o700);(boundary/'objects').mkdir(mode=0o700)
write(boundary/'delta-source-manifest.json',source);write(boundary/'delta-directory-modes.json',directories)
(boundary/'tracked.patch').write_bytes(tracked_patch)
write(boundary/'previous-boundary-reference.json',{'path':str(prior),'snapshot_sha256':raw(prior/'snapshot.json'),
 'accepted_complete_source':str(base),'accepted_root104_source_paths':len(inherited),'accepted14_delta_source_paths':len(middle_delta),'completed15_delta_source_paths':len(parent_delta),'completed15_independent_parent_acceptance_claimed':False,'logical_parent_path_count':len(old),'post_link_cache':str(cache),'post_link_cache_sha256':raw(cache),
 'scope':'Accepted root104 source referenced unchanged; no new full inherited-source audit, link mutation or bulk reconstruction. Only new delta files are materialized and independently checked.'})
work=runs/'delta-inputs';(work/'before').mkdir(parents=True);(work/'after').mkdir()
for n in additions:
 p=root/n;q=work/'after'/n;q.parent.mkdir(parents=True,exist_ok=True)
 if p.is_symlink():q.symlink_to(p.readlink())
 else:shutil.copy2(p,q)
diff=subprocess.run(['git','diff','--no-index','--binary','--src-prefix=a/','--dst-prefix=b/','before','after'],cwd=work,capture_output=True)
assert diff.returncode==1 and diff.stdout and not diff.stderr
(boundary/'delta.patch').write_bytes(diff.stdout)
with tarfile.open(boundary/'delta-contents.tar','x:') as archive:
 for n in additions:archive.add(root/n,arcname=n,recursive=False)
patched=TASK/'builds/vive-headset16-patch-materialization01';extracted=TASK/'builds/vive-headset16-tar-materialization01'
patched.mkdir(mode=0o700,exist_ok=False);extracted.mkdir(mode=0o700,exist_ok=False)
commands=[]
for args in [['git','apply','--check','-p2',str(boundary/'delta.patch')],['git','apply','-p2',str(boundary/'delta.patch')]]:
 r=subprocess.run(args,cwd=patched,capture_output=True);assert r.returncode==0
 commands.append({'command':args,'cwd':str(patched),'true_exit':r.returncode,'stdout':r.stdout.decode(),'stderr':r.stderr.decode()})
with tarfile.open(boundary/'delta-contents.tar') as archive:
 members=archive.getmembers();assert {m.name for m in members}==set(source) and len(members)==len(source)
 for m in members:
  n=PurePosixPath(m.name);assert not n.is_absolute() and '..' not in n.parts
  r=source[m.name];p=extracted/m.name;p.parent.mkdir(parents=True,exist_ok=True)
  if r['kind']=='file':
   assert m.isfile();p.write_bytes(archive.extractfile(m).read());p.chmod(r['mode'])
  else:assert r['kind']=='symlink' and m.issym() and m.linkname==r['target'];p.symlink_to(m.linkname)
for target in [patched,extracted]:
 for n,r in source.items():
  p=target/n
  if r['kind']=='file':p.chmod(r['mode'])
 for n,mode in sorted(directories.items(),key=lambda x:len(PurePosixPath(x[0]).parts),reverse=True):(target/n).chmod(mode)
 actual={str(p.relative_to(target)) for p in target.rglob('*')};assert actual==set(source)|set(directories)
 for n,r in source.items():assert row(target/n)==r
 for n,mode in directories.items():assert (target/n).stat().st_mode&0o7777==mode
write(boundary/'delta-materialization.json',{'binary_delta_generation_exit':diff.returncode,'exit1_means_differences':True,
 'patch_commands':commands,'actual_patch_tree':str(patched),'actual_tar_tree':str(extracted),'tar_members':len(source),
 'full_new_delta_paths_content_types_literal_links_file_and_directory_modes_checked':True,'changed_inherited_paths':[],
 'separate_copy_before_patch':'No inherited file changed or linked. All patch outputs are newly created and only their recorded modes restored.',
 'full_inherited_source_materialized_this_scope':False,'authorized_scope':'Case15 small additive actual evidence only; no full inherited reconstruction.'})
groups={};origins={};stored={}
def keep(p):
 digest=raw(p);q=boundary/'objects'/digest
 if digest not in stored:shutil.copyfile(p,q);q.chmod(0o444);assert raw(q)==digest;stored[digest]={'bytes':q.stat().st_size,'new_small_bytes':True}
 return digest
def selected(label,origin,paths):
 rows={};where={}
 for p in paths:
  assert p.is_relative_to(origin)
  q=p
  while q!=origin:
   n=str(q.relative_to(origin));r=row(q)
   if r['kind']=='file':assert keep(q)==r['sha256']
   rows[n]=r;where[n]=str(q);q=q.parent
 groups[label]=rows;origins[label]=where
owners=TASK/'private/case16-preparation01/unchanged-owners'
selected('actual-unchanged-invocation-code',owners,[owners/'godot-m4-vive-retest-20261030/physical09.py',*[owners/'godot-m4-vive-physical-20261029'/n for n in ['manual_run.py','environment.py','publication.py']]])
for label,origin in [('case16-actual-driver-inputs',TASK/'private/native-vive-product16/drivers'),
 ('headset16-preexecution-code',TASK/'private/build-inputs/native-vive-product16-focus'),
 ('physical-wrapper-inputs',TASK/'private/runs/native-vive-product16-run/driver-inputs'),
 ('focus-wrapper-inputs',TASK/'private/runs/native-vive-product16-focus-run/driver-inputs')]:
 selected(label,origin,sorted(origin.glob('*.py')))
for name in ['headset16-preparation01','headset16-baseline-capture01','headset16-owner-guard01','headset16-after-focus-capture01','headset16-loss-capture01','headset16-receipt-binding01']:
 origin=TASK/'private/runs'/name
 selected(name+'-preexecution-code',origin/'driver-inputs',sorted((origin/'driver-inputs').glob('*.py')))
 selected(name+'-safe-metadata-streams',origin,[origin/'stdout.raw',origin/'stderr.raw'])
selected('actual-seal-source',runs/'driver-inputs',sorted((runs/'driver-inputs').glob('*.py')))
fixture=TASK/'private/quod-m4-live-native-vive-product16-server'
selected('actual-fresh-fixture-code-only',fixture,sorted(p for p in fixture.iterdir() if p.is_file() and p.suffix in ['.erl','.beam']))
provider=TASK/'private/case16-preparation01'
selected('actual-provider-preflight-code',provider,[provider/n for n in ['display-inventory','display_inventory.c','vive_display.py']])
# Retain new compilation/test bytes only; inherited input/output bytes stay
# in the accepted readonly preparation65 graph, avoiding a193MB repeat copy.
cue_ev=root/'doc/evidence/godot-m4-vive-headset-cue-20261030'
manifest=json.loads((cue_ev/'inputs/client-headset-cue01-manifest.json').read_text())
accepted_manifest=json.loads((root/'doc/evidence/godot-m4-vive-preparation-20261030/inputs/client-physical-preparation01-manifest.json').read_text())
prepared=TASK/'artifacts/quod-godot-m4-vive-preparation-handoff-ca84d4f8-20261030-01'
assert raw(prepared/'snapshot.json')=='86ece6910580d658eb954ba68596ea582e8ca6e0236dcc2fc6f3fd28fef7d82c'
base_groups=json.loads((prepared/'object-groups.json').read_text())['new-source-only-diagnostic-build']
dist=Path(manifest['export_executable']).parent
changed_exports={n:r for n,r in manifest['export_outputs'].items() if r!=accepted_manifest['export_outputs'].get(n)}
assert set(changed_exports)=={'data_Quod_linuxbsd_x86_64/Quod.dll','data_Quod_linuxbsd_x86_64/Quod.pdb','quod.pck'}
base_export_refs={}
for n,r in manifest['export_outputs'].items():
 if n in changed_exports:continue
 before=base_groups['source/client/godot/dist/'+n]
 assert before['kind']=='file' and before['sha256']==r['sha256'] and before['bytes']==r['bytes']
 assert (dist/n).stat().st_mode&0o7777==before['mode']
 obj=prepared/'objects'/r['sha256'];assert obj.is_file() and not obj.is_symlink() and obj.stat().st_mode&0o222==0
 base_export_refs[n]={'readonly_object':str(obj),'sha256':r['sha256'],'bytes':r['bytes'],'mode':before['mode'],'custody':'Accepted preparation65 readonly artifact reference; no old byte hash or new materialization here.'}
selected('actual-new-export-members',dist,[dist/n for n in sorted(changed_exports)])
staged=Path(manifest['stage'])/'source'
changed_inputs={n:d for n,d in manifest['supplied_inputs'].items() if accepted_manifest['supplied_inputs'].get(n)!=d}
assert set(changed_inputs)=={'client/godot/tests/PhysicalChecks.cs','client/godot/tests/ViveLookCue.cs'}
selected('actual-new-supplied-code',staged,[staged/n for n in sorted(changed_inputs)])
selected('actual-new-build-preexecution-inputs',TASK/'private/runs/headset-cue-build01/driver-inputs',sorted((TASK/'private/runs/headset-cue-build01/driver-inputs').glob('*.py')))
for label in ['cue-gates01','cue-gates02']:
 origin=TASK/'builds'/label
 selected('retained-'+label+'-project-inputs'+('-post-run' if label.endswith('01') else '-preexecution-bound'),origin,[origin/n for n in ['ViveLookCue.cs','CueChecks.cs','CueGateChecks.csproj','global.json','NuGet.Config']])
 selected('actual-'+label+'-wrapper-code',TASK/'private/runs'/label/'driver-inputs',sorted((TASK/'private/runs'/label/'driver-inputs').glob('*.py')))
origin=TASK/'private/build-inputs/cue-gates02';selected('actual-pure02-before-execution-copies',origin,sorted(origin.iterdir()))
write(boundary/'payload-base-and-delta.json',{'accepted_base':str(prepared),'base_snapshot_sha256':raw(prepared/'snapshot.json'),
 'base_group':'new-source-only-diagnostic-build','supplied_inputs':manifest['supplied_inputs'],'new_supplied_members':changed_inputs,
 'export_outputs':manifest['export_outputs'],'new_export_members':changed_exports,'unchanged_export_references':base_export_refs,
 'dependency_archives':manifest['dependency_archives'],'new_supplied_and_export_members_actually_materialized_in_groups':True,
 'full94_input_or196_output_reconstruction_this_scope':False,'scope':'Complete logical maps plus accepted immutable base and actual changed member bytes; no193MB or3GB history duplication.'})
group_tree=TASK/'builds/vive-headset16-group-materialization01';group_tree.mkdir(mode=0o700,exist_ok=False)
for label,rows in groups.items():
 target=group_tree/label;target.mkdir()
 for n,r in rows.items():
  p=target/n
  if r['kind']=='directory':p.mkdir(parents=True,exist_ok=True)
  elif r['kind']=='file':p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(boundary/'objects'/r['sha256'],p);p.chmod(r['mode'])
  else:p.parent.mkdir(parents=True,exist_ok=True);p.symlink_to(r['target'])
 for n,r in sorted(rows.items(),key=lambda x:len(PurePosixPath(x[0]).parts),reverse=True):
  if r['kind']=='directory':(target/n).chmod(r['mode'])
 assert {str(p.relative_to(target)) for p in target.rglob('*')}==set(rows)
 for n,r in rows.items():assert row(target/n)==r and row(Path(origins[label][n]))==r
write(boundary/'object-groups.json',groups);write(boundary/'object-group-origins.json',origins);write(boundary/'object-storage.json',stored)
assert inventory()==current and git('diff','--binary','HEAD')==tracked_patch and not git('diff','--cached','--name-only')
for n,r in source.items():assert row(root/n)==r
write(boundary/'qualification.json',json.loads((ev/'qualification.json').read_text()))
artifacts={str(p.relative_to(boundary)):{'sha256':raw(p),'bytes':p.stat().st_size} for p in boundary.rglob('*') if p.is_file()}
write(boundary/'snapshot.json',{'checkpoint':'QUO-65 diagnostic headset cue/case16 failed human controller visibility; small new evidence delta',
 'worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','artifacts':artifacts,'previous_snapshot_sha256':raw(prior/'snapshot.json'),
 'new_source_paths':len(source),'new_delta_actually_materialized':True,'full_inherited_source_reconstructed_this_scope':False,
 'unchanged_production_inputs':92,'new_diagnostic_supplied_inputs':94,'unchanged_export_files':196,'new_affected_diagnostic_build':True,'product_changes':False,
 'human_model_look':'FAILED: actual Yan No controllers; look time unknown, no cause attribution','distributable':False,'full_M4_accepted':False})
for p in boundary.rglob('*'):
 if p.is_file():p.chmod(0o444)
for p in sorted([p for p in boundary.rglob('*') if p.is_dir()],key=lambda p:len(p.parts),reverse=True):p.chmod(0o555)
boundary.chmod(0o555)
print(json.dumps({'frozen':True,'boundary':str(boundary),'snapshot_sha256':raw(boundary/'snapshot.json'),
 'artifacts':len(artifacts),'objects':len(stored),'groups':len(groups),'group_paths':sum(len(r) for r in groups.values()),
 'new_source_paths':len(source),'patch_and_tar_materialized':True,'full_inherited_source_reconstructed':False,
 'api_bytes_read':0,'old_history_replayed':False}),flush=True)
