"""Small completion/case19 source/receipt seal; inherited history and API bytes are referenced."""
import json,os,shutil,stat,subprocess,sys,tarfile,time
from pathlib import Path,PurePosixPath
from case_hashes import TASK,Digests,key,raw
sys.dont_write_bytecode=True;os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent
boundary=TASK/'artifacts/quod-godot-m4-vive-mapped19-handoff-ca84d4f8-20261030-01'
runs=TASK/'artifacts/mapped19-freeze-runs01';base=TASK/'builds/coordinator-focus13-source-reconstruction-104'
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def git(*args):return subprocess.check_output(['git',*args],cwd=root)
def inventory():return set(filter(None,git('ls-files','--cached','--others','--exclude-standard','-z').decode().split('\0')))
def row(p):
 mode=stat.S_IMODE(p.lstat().st_mode)
 if p.is_symlink():return {'kind':'symlink','target':str(p.readlink()),'mode':mode}
 if p.is_dir():return {'kind':'directory','mode':mode}
 assert p.is_file();return {'kind':'file','sha256':raw(p),'bytes':p.stat().st_size,'mode':mode}
if sys.argv[1:]!=['--child']:
 assert not sys.argv[1:];runs.mkdir(mode=0o700,exist_ok=False);copies=runs/'driver-inputs';copies.mkdir()
 for p in ev.glob('*.py'):shutil.copy2(p,copies/p.name)
 command=[sys.executable,'-B',str(Path(__file__).resolve()),'--child'];started=time.monotonic()
 with (runs/'stdout.log').open('xb') as out,(runs/'stderr.log').open('xb') as err:r=subprocess.run(command,stdout=out,stderr=err,timeout=120)
 summary=None
 for line in (runs/'stdout.log').read_text().splitlines():
  if line.startswith('{'):
   candidate=json.loads(line)
   if candidate.get('frozen'):summary=candidate
 result={'command':command,'true_child_exit':r.returncode,'explicit_completion':summary is not None,'summary':summary,'elapsed_seconds':time.monotonic()-started,'timed_out':False,'passed':r.returncode==0 and summary is not None,'stdout':{'sha256':raw(runs/'stdout.log'),'path':str(runs/'stdout.log')},'stderr':{'sha256':raw(runs/'stderr.log'),'path':str(runs/'stderr.log')}}
 write(runs/'result.json',result);print(json.dumps(result));raise SystemExit(0 if result['passed'] else 1)
assert not boundary.exists() and base.is_dir()
assert git('rev-parse','HEAD').decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert git('rev-parse','HEAD^').decode().strip()=='f716ddf5e578df957a5b18421a0727a32c634f87'
assert git('branch','--show-current').decode().strip()=='worktree/pearl-stone'
assert not git('diff','--check') and not git('diff','--cached','--name-only')
parents=[('quod-godot-m4-vive-focus13-handoff-ca84d4f8-20261030-02','b98c2ebf3f2085e0d75a4672f81965000e2b61c17de03f08c46faa137c81d6d9','source-manifest.json'),('quod-godot-m4-vive-focus14-handoff-ca84d4f8-20261030-01','3b373f5d671781de6e4aeb98495c66713eedf06bf2aa952fe20b02ce041e55aa','delta-source-manifest.json'),('quod-godot-m4-vive-focus15-handoff-ca84d4f8-20261030-01','78b6086c09e613db67f6e9b4e22820dca9c68efe728931ff565e80718139e9a2','delta-source-manifest.json'),('quod-godot-m4-vive-headset16-handoff-ca84d4f8-20261030-01','6db65d970df6a2c274e06b185394940bf46cb0bc6612bd2de141ffe5161c9cbb','delta-source-manifest.json')]
parents.append(('quod-godot-m4-xr-focus-handoff-ca84d4f8-20261030-01','c72733afbe87a36cc67d206a7cc6ff493f229961d64ef164a9c878e2f4af853a','delta-source-manifest.json'))
parents.append(('quod-godot-m4-vive-runtime-cue-handoff-ca84d4f8-20261030-01','9379b83ce94df3fbc6e5f30efab0ce9178e8aebc176fc447b31b3b942d48c039','delta-source-manifest.json'))
parents.append(('quod-godot-m4-vive-runtime17-handoff-ca84d4f8-20261030-01','cc01145c96b49946f205a718da61cc4628eb5939fc4bfa89c5820f58c477553a','delta-source-manifest.json'))
parents.append(('quod-godot-m4-vive-runtime18-handoff-ca84d4f8-20261030-01','99daf0bc40c62f09a549c765db4472f1d5aea55f57531054fc00bc6ae9376a85','delta-source-manifest.json'))
old={};references=[]
for name,digest,manifest in parents:
 p=TASK/'artifacts'/name;assert raw(p/'snapshot.json')==digest
 data=json.loads((p/manifest).read_text());overlap=set(old)&set(data)
 if name=='quod-godot-m4-xr-focus-handoff-ca84d4f8-20261030-01':assert overlap==set(json.loads((p/'snapshot.json').read_text())['changed_inherited_paths'])
 else:assert not overlap
 old.update(data)
 references.append({'path':str(p),'snapshot_sha256':digest,'source_index':manifest,'source_paths':len(data),'scope':'immutable prior custody; no new physical acceptance'})
current=inventory();assert set(old)<=current
changed=[]
assert set(changed)<=set(old)
additions=sorted(current-set(old));assert additions
allowed={'nimbalyst-local/handoffs/godot-m4-completion-result-124.md'}
allowed.update(str(p.relative_to(root)) for p in (root/'doc/evidence/godot-m4-vive-physical-20261029/inputs').glob('*native-vive-product19-server*'))
assert all(n in allowed or n.startswith('doc/evidence/godot-m4-vive-mapped19-20261030/') or n.startswith('doc/evidence/godot-m4-completion-20261030/') for n in additions),additions
assert sum(n.startswith('.agents/') for n in current)==31
digests=Digests();q=json.loads((ev/'qualification.json').read_text())
cache=TASK/'cache/coordinator-focus13-final104-hashes.json'
assert raw(cache)=='ce50196ffcbf29778e60b8c3242a659c0fdb196258ba9da5edf573829e831afa'
before={}
for n in changed:
 p=base/n;r=old[n];assert digests.h(p)==r['sha256'] and p.stat().st_size==r['bytes'] and stat.S_IMODE(p.stat().st_mode)==r['mode']
 before[n]={k:v for k,v in r.items() if k!='tracked'};assert raw(root/n)!=r['sha256']
names=sorted(changed+additions);source={n:row(root/n) for n in names};directories={}
for n in names:
 for p in PurePosixPath(n).parents:
  if str(p)!='.':directories[str(p)]=stat.S_IMODE((root/str(p)).stat().st_mode)
tracked=git('diff','--binary','HEAD');assert tracked==(TASK/'artifacts/quod-godot-m4-xr-focus-handoff-ca84d4f8-20261030-01/tracked.patch').read_bytes();boundary.mkdir(mode=0o700);(boundary/'objects').mkdir()
write(boundary/'delta-source-manifest.json',source);write(boundary/'changed-before-manifest.json',before);write(boundary/'delta-directory-modes.json',directories)
write(boundary/'previous-boundary-references.json',{'parents':references,'accepted_complete_source':str(base),'root104_cache_sha256':'ce50196ffcbf29778e60b8c3242a659c0fdb196258ba9da5edf573829e831afa','logical_parent_source_paths':len(old),'full_inherited_tree_reconstructed':False,'api_bytes_read':0})
(boundary/'tracked.patch').write_bytes(tracked)
work=runs/'patch-inputs';(work/'before').mkdir(parents=True);(work/'after').mkdir()
for n in changed:
 p=work/'before'/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(base/n,p);assert row(p)==before[n]
for n in names:
 p=work/'after'/n;p.parent.mkdir(parents=True,exist_ok=True)
 if (root/n).is_symlink():p.symlink_to((root/n).readlink())
 else:shutil.copy2(root/n,p)
diff=subprocess.run(['git','diff','--no-index','--binary','--src-prefix=a/','--dst-prefix=b/','before','after'],cwd=work,capture_output=True)
assert diff.returncode==1 and diff.stdout and not diff.stderr;(boundary/'delta.patch').write_bytes(diff.stdout)
with tarfile.open(boundary/'delta-contents.tar','x:') as tar:
 for n in names:tar.add(root/n,arcname=n,recursive=False)
patched=TASK/'builds/mapped19-patch-materialization01';extracted=TASK/'builds/mapped19-tar-materialization01';patched.mkdir(mode=0o700,exist_ok=False);extracted.mkdir(mode=0o700,exist_ok=False)
for n in changed:
 p=patched/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(base/n,p)
 assert p.stat().st_ino!=(base/n).stat().st_ino and row(p)==before[n]
commands=[]
for args in [['git','apply','--check','-p2',str(boundary/'delta.patch')],['git','apply','-p2',str(boundary/'delta.patch')]]:
 r=subprocess.run(args,cwd=patched,capture_output=True);assert r.returncode==0;commands.append({'command':args,'true_exit':r.returncode,'stdout':r.stdout.decode(),'stderr':r.stderr.decode()})
with tarfile.open(boundary/'delta-contents.tar') as tar:
 members=tar.getmembers();assert len(members)==len(source) and {m.name for m in members}==set(source)
 for m in members:
  n=PurePosixPath(m.name);assert not n.is_absolute() and '..' not in n.parts;r=source[m.name];p=extracted/m.name;p.parent.mkdir(parents=True,exist_ok=True)
  if r['kind']=='file':assert m.isfile();p.write_bytes(tar.extractfile(m).read());p.chmod(r['mode'])
  else:assert r['kind']=='symlink' and m.issym() and m.linkname==r['target'];p.symlink_to(m.linkname)
for target in [patched,extracted]:
 for n,r in source.items():
  if r['kind']=='file':(target/n).chmod(r['mode'])
 for n,mode in sorted(directories.items(),key=lambda x:len(PurePosixPath(x[0]).parts),reverse=True):(target/n).chmod(mode)
 assert {str(p.relative_to(target)) for p in target.rglob('*')}==set(source)|set(directories)
 for n,r in source.items():assert row(target/n)==r
 for n,mode in directories.items():assert stat.S_IMODE((target/n).stat().st_mode)==mode
write(boundary/'delta-materialization.json',{'generation_exit':diff.returncode,'exit1_means_differences':True,'patch_commands':commands,'changed_inherited_paths':changed,'separate_inherited_copies_before_patch':len(changed),'copy_scope':'Addition-only source delta; no inherited source is patched or chmodded. The accepted diagnostic payload was reused without a build.','patch_tree':str(patched),'tar_tree':str(extracted),'actual_tar_members':len(source),'full_delta_paths_contents_types_links_modes_checked':True,'full_inherited_source_reconstruction':False})
groups={};origins={};group_modes={};stored={}
def keep(p):
 d=digests.h(p);dest=boundary/'objects'/d
 if not dest.exists():shutil.copyfile(p,dest);assert raw(dest)==d;dest.chmod(0o444);stored[d]={'bytes':p.stat().st_size,'storage':'new copied object; no old source/object links'}
 return d
def selected(label,origin,paths):
 rows={};where={};group_modes[label]=stat.S_IMODE(origin.stat().st_mode)
 for p in paths:
  assert p.is_relative_to(origin)
  while p!=origin:
   n=str(p.relative_to(origin));r=row(p)
   if r['kind']=='file':assert keep(p)==r['sha256']
   rows[n]=r;where[n]=str(p);p=p.parent
 groups[label]=rows;origins[label]=where
owners=TASK/'private/case19-preparation01/unchanged-owners'
selected('actual-private-invocation-code',owners,[owners/'godot-m4-vive-retest-20261030'/n for n in ['physical09.py','physical19.py','case_hashes.py']]+[owners/'godot-m4-vive-physical-20261029'/n for n in ['manual_run.py','environment.py','publication.py']])
for label,origin in [('case19-executed-inputs',TASK/'private/native-vive-product19/drivers'),('physical-wrapper-inputs',TASK/'private/runs/native-vive-product19-run/driver-inputs'),('actual-closure-display-source',TASK/'private/build-inputs/mapped19-closure01')]:
 selected(label,origin,sorted(origin.glob('*.py')))
for name in ['mapped19-preparation01','mapped19-baseline-capture01','mapped19-withdrawal-capture01','mapped19-receipt-binding01','mapped19-receipt-binding02']:
 origin=TASK/'private/runs'/name
 selected(name+'-preexecution-code',origin/'driver-inputs',sorted((origin/'driver-inputs').glob('*.py')))
 selected(name+'-actual-streams',origin,[origin/'stdout.raw',origin/'stderr.raw'])
selected('actual-seal-source',runs/'driver-inputs',sorted((runs/'driver-inputs').glob('*.py')))
provider=TASK/'private/case19-preparation01'
selected('provider-preflight-code-and-actual-receipts',provider,[provider/n for n in ['display-inventory','display_inventory.c','vive_display.py','driver-digest-adaptation.patch','preparation-private.json','provider-stdout.raw','provider-stderr.raw','display-rule.json']])
fixture=TASK/'private/quod-m4-live-native-vive-product19-server'
selected('actual-fresh-fixture-code-only',fixture,sorted(p for p in fixture.iterdir() if p.is_file() and p.suffix in ['.erl','.beam']))
private=TASK/'private/native-vive-product19'
selected('actual-case-small-raw-streams',private,[private/n for n in ['server-stdout.raw','server-stderr.raw','runtime-stdout.raw','runtime-stderr.raw','client-stdout.raw','client-stderr.raw','startup-inventory-stdout.raw','startup-inventory-stderr.raw']])
wrapper=TASK/'private/runs/native-vive-product19-run'
selected('actual-wrapper-small-raw-streams',wrapper,[wrapper/'stdout.raw',wrapper/'stderr.raw'])
case=owners/'godot-m4-vive-retest-20261030/native-vive-product19'
selected('actual-private-case-results',case,[case/'result.json',case/'client-result.json'])
logs=owners/'godot-m4-vive-physical-20261029/logs'
selected('actual-wrapper-result',logs,[logs/'native-vive-product19-run.json'])
selected('actual-private-owner-binding',TASK/'private',[TASK/'private/native-vive-product19-invocation.json'])
selected('actual-display-preservation-receipts',private,[private/'display-rule.json',private/'closure-current-display.json'])
tracker=TASK/'private/completion124-tracker01'
selected('actual-own-UUID-explicit-project-tracker-receipts',tracker,sorted(tracker.iterdir()))
integration=TASK/'private/completion124-integration01'
selected('actual-full-instruction-and-PTY-control-receipts',integration,sorted(integration.iterdir()))
accepted=TASK/'artifacts/quod-godot-m4-vive-runtime-cue-handoff-ca84d4f8-20261030-01'
manifest=root/'doc/evidence/godot-m4-vive-runtime-cue-20261030/inputs/client-runtime-cue01-manifest.json'
assert raw(accepted/'snapshot.json')=='9379b83ce94df3fbc6e5f30efab0ce9178e8aebc176fc447b31b3b942d48c039'
assert raw(manifest)=='9073b314599bd64531792acd63cbcd2e21ef54b73a41b25cd041260a4433fb08'
write(boundary/'unchanged-payload-reference.json',{'accepted_boundary':str(accepted),'snapshot_sha256':raw(accepted/'snapshot.json'),'manifest_path':str(manifest),'manifest_sha256':raw(manifest),'supplied_inputs':94,'export_files':196,'new_builds':0,'new_export_hash_passes':0,'scope':'Exact accepted source/export objects referenced; no payload rebuild, bulk copy or output byte recount.'})
assert list(key(Path(q['api_private_reference']['path'])))==q['api_private_reference']['stat_key']
write(boundary/'api-reference.json',q['api_private_reference'])
assert all('api-dump.raw' not in p for rows in origins.values() for p in rows.values())
group_tree=TASK/'builds/mapped19-group-materialization01';group_tree.mkdir(mode=0o700,exist_ok=False)
for label,rows in groups.items():
 target=group_tree/label;target.mkdir()
 for n,r in rows.items():
  p=target/n
  if r['kind']=='directory':p.mkdir(parents=True,exist_ok=True)
  elif r['kind']=='file':p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(boundary/'objects'/r['sha256'],p);p.chmod(r['mode'])
  else:p.parent.mkdir(parents=True,exist_ok=True);p.symlink_to(r['target'])
 for n,r in sorted(rows.items(),key=lambda x:len(PurePosixPath(x[0]).parts),reverse=True):
  if r['kind']=='directory':(target/n).chmod(r['mode'])
 target.chmod(group_modes[label]);assert stat.S_IMODE(target.stat().st_mode)==group_modes[label]
 assert {str(p.relative_to(target)) for p in target.rglob('*')}==set(rows)
 for n,r in rows.items():assert row(target/n)==r and row(Path(origins[label][n]))==r
write(boundary/'object-groups.json',groups);write(boundary/'object-group-origins.json',origins);write(boundary/'group-root-modes.json',group_modes);write(boundary/'object-storage.json',stored)
assert inventory()==current and git('diff','--binary','HEAD')==tracked and not git('diff','--cached','--name-only')
for n,r in source.items():assert row(root/n)==r
write(boundary/'qualification.json',q);digests.write(boundary/'used-stat-digests.json')
artifacts={str(p.relative_to(boundary)):{'sha256':raw(p),'bytes':p.stat().st_size} for p in boundary.rglob('*') if p.is_file()}
write(boundary/'snapshot.json',{'checkpoint':'M4 obligation reconciliation and case19 read-only mapped-action opportunity withdrawn on sign-in expiry; normal retirement, no physical action result','worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','artifacts':artifacts,'previous_snapshot_sha256':parents[-1][1],'changed_inherited_paths':changed,'new_source_paths':len(additions),'actual_delta_materialized':True,'full_inherited_source_reconstructed':False,'selected_payload':'runtime-cue01','production_inputs_unchanged':92,'diagnostic_supplied_inputs':94,'export_files_reused':196,'distributable':False,'protocol_retirement_passed':True,'physical_mapped_action':q['physical_mapped_action'],'human_response_received':False,'independent_software_gap_demonstrated':False,'new_production_test_spec_changes':0,'api_bytes_read':0,'api_scope':'Original executed-driver hash and post-exit stat receipt only; no parsing/recount','startup_complaint':'OPEN','full_M4_accepted':False,'commit_or_M5':False,'privacy':'Raw/owner groups remain inside private Data; no raw room matrices or unrelated process identities in public source.'})
for p in boundary.rglob('*'):
 if p.is_file():p.chmod(0o444)
for p in sorted([p for p in boundary.rglob('*') if p.is_dir()],key=lambda p:len(p.parts),reverse=True):p.chmod(0o555)
boundary.chmod(0o555)
print(json.dumps({'frozen':True,'boundary':str(boundary),'snapshot_sha256':raw(boundary/'snapshot.json'),'artifacts':len(artifacts),'objects':len(stored),'groups':len(groups),'group_paths':sum(len(v) for v in groups.values()),'changed_inherited_paths':len(changed),'new_source_paths':len(additions),'full_inherited_source_reconstructed':False,'api_bytes_read':0}),flush=True)
