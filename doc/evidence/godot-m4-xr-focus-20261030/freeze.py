"""Small exact changed-source/software-evidence seal; inherited history is referenced."""
import json,os,shutil,stat,subprocess,sys,tarfile,time
from pathlib import Path,PurePosixPath
from hashes import TASK,Digests,raw
sys.dont_write_bytecode=True;os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent
boundary=TASK/'artifacts/quod-godot-m4-xr-focus-handoff-ca84d4f8-20261030-01'
runs=TASK/'artifacts/xr-focus-freeze-runs01';base=TASK/'builds/coordinator-focus13-source-reconstruction-104'
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
old={};references=[]
for name,digest,manifest in parents:
 p=TASK/'artifacts'/name;assert raw(p/'snapshot.json')==digest
 data=json.loads((p/manifest).read_text());assert not(set(old)&set(data));old.update(data)
 references.append({'path':str(p),'snapshot_sha256':digest,'source_index':manifest,'source_paths':len(data),'scope':'immutable prior custody; no new physical acceptance'})
current=inventory();assert set(old)<=current
changed=['client/godot/Main.cs','client/godot/OpenXRInput.cs','client/godot/README.md','client/godot/tests/ControllerChecks.cs','client/godot/tests/ControllerLiveChecks.cs','client/godot/tests/PhysicsChecks.cs']
assert set(changed)<=set(old)
additions=sorted(current-set(old));assert additions
allowed={'nimbalyst-local/handoffs/godot-m4-xr-focus-correction-prompt-118.md','nimbalyst-local/handoffs/godot-m4-xr-focus-correction-result.md'}
assert all(n in allowed or n.startswith('doc/evidence/godot-m4-xr-focus-20261030/') for n in additions),additions
assert sum(n.startswith('.agents/') for n in current)==31
digests=Digests();qualified=ev/'qualified-stat-digests.json';q=json.loads((ev/'qualification.json').read_text());assert raw(qualified)==q['digest_cache']['sha256']
for r in json.loads(qualified.read_text())['records']:digests.values[tuple(r['stat_key'])]=r['sha256']
before={}
for n in changed:
 p=base/n;r=old[n];assert digests.h(p)==r['sha256'] and p.stat().st_size==r['bytes'] and stat.S_IMODE(p.stat().st_mode)==r['mode']
 before[n]={k:v for k,v in r.items() if k!='tracked'};assert raw(root/n)!=r['sha256']
names=sorted(changed+additions);source={n:row(root/n) for n in names};directories={}
for n in names:
 for p in PurePosixPath(n).parents:
  if str(p)!='.':directories[str(p)]=stat.S_IMODE((root/str(p)).stat().st_mode)
tracked=git('diff','--binary','HEAD');boundary.mkdir(mode=0o700);(boundary/'objects').mkdir()
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
patched=TASK/'builds/xr-focus-patch-materialization01';extracted=TASK/'builds/xr-focus-tar-materialization01';patched.mkdir(mode=0o700,exist_ok=False);extracted.mkdir(mode=0o700,exist_ok=False)
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
write(boundary/'delta-materialization.json',{'generation_exit':diff.returncode,'exit1_means_differences':True,'patch_commands':commands,'changed_inherited_paths':changed,'separate_copies_before_patch':True,'patch_tree':str(patched),'tar_tree':str(extracted),'actual_tar_members':len(source),'full_delta_paths_contents_types_links_modes_checked':True,'full_inherited_source_reconstruction':False})
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
for p in sorted((TASK/'private/runs').glob('xr-focus-*')):
 if p.is_dir():
  selected(p.name+'-preexecution-code',p/'driver-inputs',sorted((p/'driver-inputs').glob('*.py')))
  selected(p.name+'-metadata-streams',p,[p/'stdout.raw',p/'stderr.raw'])
for label in ['xr-focus-baseline-controller01','xr-focus-baseline-controller02','xr-focus-final-controller01','xr-focus-final-presentation01','xr-focus-final-scene01','xr-focus-final-menu01','xr-focus-final02-menu01']:
 p=TASK/'private'/label
 if (p/'drivers').is_dir():selected(label+'-actual-driver-code',p/'drivers',sorted((p/'drivers').glob('*.py')))
 if (p/'stdout.raw').exists():selected(label+'-actual-child-streams',p,[p/'stdout.raw',p/'stderr.raw'])
selected('actual-seal-source',runs/'driver-inputs',sorted((runs/'driver-inputs').glob('*.py')))
prepared=TASK/'artifacts/quod-godot-m4-vive-preparation-handoff-ca84d4f8-20261030-01';assert raw(prepared/'snapshot.json')=='86ece6910580d658eb954ba68596ea582e8ca6e0236dcc2fc6f3fd28fef7d82c'
base_groups=json.loads((prepared/'object-groups.json').read_text())['new-source-only-diagnostic-build'];accepted=json.loads((root/'doc/evidence/godot-m4-vive-preparation-20261030/inputs/client-physical-preparation01-manifest.json').read_text());accepted_source=json.loads((root/'doc/evidence/godot-m4-presentation-20261030/inputs/client-presentation-final02-manifest.json').read_text())
payloads={}
for label in ['xr-focus-baseline02','xr-focus-final01','xr-focus-final02']:
 m=json.loads((ev/'inputs'/('client-'+label+'-manifest.json')).read_text());dist=Path(m['export_executable']).parent;stage=Path(m['stage'])/'source'
 changed_exports={n:r for n,r in m['export_outputs'].items() if r!=accepted['export_outputs'].get(n)};refs={}
 for n,r in m['export_outputs'].items():
  if n in changed_exports:continue
  before=base_groups['source/client/godot/dist/'+n];obj=prepared/'objects'/r['sha256']
  assert before['kind']=='file' and before['sha256']==r['sha256'] and before['bytes']==r['bytes'] and stat.S_IMODE((dist/n).stat().st_mode)==before['mode']
  assert obj.is_file() and not obj.is_symlink() and not obj.stat().st_mode&0o222
  refs[n]={'readonly_object':str(obj),'sha256':r['sha256'],'bytes':r['bytes'],'mode':before['mode']}
 selected(label+'-new-exports',dist,[dist/n for n in sorted(changed_exports)])
 changed_inputs={n:d for n,d in m['supplied_inputs'].items() if accepted_source['supplied_inputs'].get(n)!=d}
 selected(label+'-changed-supplied-inputs',stage,[stage/n for n in sorted(changed_inputs)])
 payloads[label]={'supplied_inputs':m['supplied_inputs'],'changed_supplied_inputs':changed_inputs,'export_outputs':m['export_outputs'],'changed_export_members':changed_exports,'unchanged_export_object_references':refs,'dependency_archives':m['dependency_archives'],'compiled_application_inputs_copied':False,'diagnostic_overrides':m['diagnostic_overrides'],'full_export_tree_materialized_this_scope':False}
write(boundary/'payload-base-and-deltas.json',{'accepted_readonly_base':str(prepared),'base_snapshot_sha256':raw(prepared/'snapshot.json'),'source_base_manifest_sha256':raw(root/'doc/evidence/godot-m4-presentation-20261030/inputs/client-presentation-final02-manifest.json'),'payloads':payloads,'selected':'xr-focus-final01','scope':'complete logical maps; actual new member bytes and193 unchanged readonly references per payload; no193MB/3GB repeat copy'})
group_tree=TASK/'builds/xr-focus-group-materialization01';group_tree.mkdir(mode=0o700,exist_ok=False)
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
write(boundary/'snapshot.json',{'checkpoint':'approved XR desktop focus cancellation-only policy; bounded software qualification','worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','artifacts':artifacts,'previous_snapshot_sha256':parents[-1][1],'changed_inherited_paths':changed,'new_source_paths':len(additions),'actual_delta_materialized':True,'full_inherited_source_reconstructed':False,'selected_payload':'xr-focus-final01','trace_free_product_source':True,'software_checks':{'controller':67,'presentation':15,'scene':15},'extra_menu':'FAILED/inconclusive; retained guards','api_bytes_read':0,'physical_case_started':False,'startup_complaint':'OPEN','full_M4_accepted':False,'commit_or_M5':False})
for p in boundary.rglob('*'):
 if p.is_file():p.chmod(0o444)
for p in sorted([p for p in boundary.rglob('*') if p.is_dir()],key=lambda p:len(p.parts),reverse=True):p.chmod(0o555)
boundary.chmod(0o555)
print(json.dumps({'frozen':True,'boundary':str(boundary),'snapshot_sha256':raw(boundary/'snapshot.json'),'artifacts':len(artifacts),'objects':len(stored),'groups':len(groups),'group_paths':sum(len(v) for v in groups.values()),'changed_inherited_paths':len(changed),'new_source_paths':len(additions),'full_inherited_source_reconstructed':False,'api_bytes_read':0}),flush=True)
