"""Additive case20/workspace source and small evidence seal; no API/history reads."""
import json,os,shutil,stat,subprocess,sys,tarfile,time
from pathlib import Path,PurePosixPath
from hashes import TASK,Digests,key,raw
sys.dont_write_bytecode=True
os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent
case_ev=root/'doc/evidence/godot-m4-vive-mapped20-20261030'
boundary=TASK/'artifacts/quod-godot-m4-workspace-handoff-ca84d4f8-20261030-01'
runs=TASK/'artifacts/workspace-freeze-runs01'
base=TASK/'builds/coordinator-focus13-source-reconstruction-104'

def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def load(p):return json.loads(p.read_text())
def git(*args):return subprocess.check_output(['git',*args],cwd=root)
def inventory():return set(filter(None,git('ls-files','--cached','--others','--exclude-standard','-z').decode().split('\0')))

if sys.argv[1:]!=['--child']:
    assert not sys.argv[1:]
    runs.mkdir(mode=0o700,exist_ok=False);copies=runs/'driver-inputs';copies.mkdir()
    for p in ev.glob('*.py'):shutil.copy2(p,copies/p.name)
    command=[sys.executable,'-B',str(Path(__file__).resolve()),'--child'];started=time.monotonic()
    with (runs/'stdout.log').open('xb') as out,(runs/'stderr.log').open('xb') as err:
        r=subprocess.run(command,stdout=out,stderr=err,timeout=120)
    completion=None
    for line in (runs/'stdout.log').read_text().splitlines():
        if line.startswith('{'):
            candidate=json.loads(line)
            if candidate.get('frozen'):completion=candidate
    result={'command':command,'true_child_exit':r.returncode,'explicit_completion':completion is not None,
        'summary':completion,'elapsed_seconds':time.monotonic()-started,'timed_out':False,
        'passed':r.returncode==0 and completion is not None,
        'stdout':{'path':str(runs/'stdout.log'),'sha256':raw(runs/'stdout.log')},
        'stderr':{'path':str(runs/'stderr.log'),'sha256':raw(runs/'stderr.log')}}
    write(runs/'result.json',result);print(json.dumps(result))
    raise SystemExit(0 if result['passed'] else 1)

assert not boundary.exists() and base.is_dir()
assert git('rev-parse','HEAD').decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert git('rev-parse','HEAD^').decode().strip()=='f716ddf5e578df957a5b18421a0727a32c634f87'
assert git('branch','--show-current').decode().strip()=='worktree/pearl-stone'
assert not git('diff','--check') and not git('diff','--cached','--name-only')
parents=[
 ('quod-godot-m4-vive-focus13-handoff-ca84d4f8-20261030-02','b98c2ebf3f2085e0d75a4672f81965000e2b61c17de03f08c46faa137c81d6d9','source-manifest.json'),
 ('quod-godot-m4-vive-focus14-handoff-ca84d4f8-20261030-01','3b373f5d671781de6e4aeb98495c66713eedf06bf2aa952fe20b02ce041e55aa','delta-source-manifest.json'),
 ('quod-godot-m4-vive-focus15-handoff-ca84d4f8-20261030-01','78b6086c09e613db67f6e9b4e22820dca9c68efe728931ff565e80718139e9a2','delta-source-manifest.json'),
 ('quod-godot-m4-vive-headset16-handoff-ca84d4f8-20261030-01','6db65d970df6a2c274e06b185394940bf46cb0bc6612bd2de141ffe5161c9cbb','delta-source-manifest.json'),
 ('quod-godot-m4-xr-focus-handoff-ca84d4f8-20261030-01','c72733afbe87a36cc67d206a7cc6ff493f229961d64ef164a9c878e2f4af853a','delta-source-manifest.json'),
 ('quod-godot-m4-vive-runtime-cue-handoff-ca84d4f8-20261030-01','9379b83ce94df3fbc6e5f30efab0ce9178e8aebc176fc447b31b3b942d48c039','delta-source-manifest.json'),
 ('quod-godot-m4-vive-runtime17-handoff-ca84d4f8-20261030-01','cc01145c96b49946f205a718da61cc4628eb5939fc4bfa89c5820f58c477553a','delta-source-manifest.json'),
 ('quod-godot-m4-vive-runtime18-handoff-ca84d4f8-20261030-01','99daf0bc40c62f09a549c765db4472f1d5aea55f57531054fc00bc6ae9376a85','delta-source-manifest.json'),
 ('quod-godot-m4-vive-mapped19-handoff-ca84d4f8-20261030-01','dc7872a002c4cad5935406c77ac3ac5b3579d4e079352258adf9007853b36497','delta-source-manifest.json')]
old={};references=[]
for name,digest,manifest in parents:
    p=TASK/'artifacts'/name;assert raw(p/'snapshot.json')==digest
    data=load(p/manifest);overlap=set(old)&set(data)
    if name=='quod-godot-m4-xr-focus-handoff-ca84d4f8-20261030-01':
        assert overlap==set(load(p/'snapshot.json')['changed_inherited_paths'])
    else:assert not overlap
    old.update(data)
    references.append({'path':str(p),'snapshot_sha256':digest,'source_index':manifest,'source_paths':len(data)})
current=inventory();assert set(old)<=current
delta=load(ev/'source-delta.json');changed=sorted(delta['inherited_files'])
assert len(changed)==5 and set(changed)<=set(old)
additions=sorted(current-set(old));assert additions
allowed={'client/godot/tests/WorkspaceChecks.cs','nimbalyst-local/handoffs/godot-m4-workspace-result-127.md'}
allowed.update(str(p.relative_to(root)) for p in (root/'doc/evidence/godot-m4-vive-physical-20261029/inputs').glob('*native-vive-product20-server*'))
assert all(n in allowed or n.startswith('doc/evidence/godot-m4-workspace-20261030/') or n.startswith('doc/evidence/godot-m4-vive-mapped20-20261030/') for n in additions),additions
assert sum(n.startswith('.agents/') for n in current)==31
d=Digests()
root_cache=root/'_build/godot-m4-r2-coordinator-20261029/workspace06-hashes-127.json'
assert raw(root_cache)=='2494302da7bbee68b595fc3cdb6503e55dd2f86e377e516a18aa912e02f8f8a8'
for r in load(root_cache)['records'].values():d.values[tuple(r['key'])]=r['sha256']
qc=load(ev/'receipt-cache.json');assert raw(Path(qc['path']))==qc['sha256']
for r in load(Path(qc['path']))['records']:d.values[tuple(r['stat_key'])]=r['sha256']

def row(p):
    mode=stat.S_IMODE(p.lstat().st_mode)
    if p.is_symlink():return {'kind':'symlink','target':str(p.readlink()),'mode':mode}
    if p.is_dir():return {'kind':'directory','mode':mode}
    assert p.is_file()
    return {'kind':'file','sha256':d.h(p),'bytes':p.stat().st_size,'mode':mode}

before={};before_paths={}
for n in changed:
    p=ev/'inputs'/(Path(n).name+'.before');r={k:v for k,v in old[n].items() if k!='tracked'}
    assert row(p)==r and r['sha256']==delta['inherited_files'][n]['before_sha256']
    assert d.h(root/n)==delta['inherited_files'][n]['after_sha256']!=r['sha256']
    before[n]=r;before_paths[n]=p
names=sorted(changed+additions);source={n:row(root/n) for n in names};directories={}
for n in names:
    for p in PurePosixPath(n).parents:
        if str(p)!='.':directories[str(p)]=stat.S_IMODE((root/str(p)).stat().st_mode)
tracked=git('diff','--binary','HEAD');boundary.mkdir(mode=0o700);(boundary/'objects').mkdir()
write(boundary/'delta-source-manifest.json',source);write(boundary/'changed-before-manifest.json',before)
write(boundary/'delta-directory-modes.json',directories);(boundary/'tracked.patch').write_bytes(tracked)
write(boundary/'previous-boundary-references.json',{'parents':references,'accepted_complete_source':str(base),
    'root104_cache_sha256':'ce50196ffcbf29778e60b8c3242a659c0fdb196258ba9da5edf573829e831afa',
    'logical_parent_source_paths':len(old),'full_inherited_tree_reconstructed':False,'api_bytes_read':0})
work=runs/'patch-inputs';(work/'before').mkdir(parents=True);(work/'after').mkdir()
for n in changed:
    p=work/'before'/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(before_paths[n],p)
    assert p.stat().st_ino!=before_paths[n].stat().st_ino and row(p)==before[n]
for n in names:
    p=work/'after'/n;p.parent.mkdir(parents=True,exist_ok=True)
    if (root/n).is_symlink():p.symlink_to((root/n).readlink())
    else:shutil.copy2(root/n,p)
diff=subprocess.run(['git','diff','--no-index','--binary','--src-prefix=a/','--dst-prefix=b/','before','after'],cwd=work,capture_output=True)
assert diff.returncode==1 and diff.stdout and not diff.stderr
(boundary/'delta.patch').write_bytes(diff.stdout)
with tarfile.open(boundary/'delta-contents.tar','x:') as tar:
    for n in names:tar.add(root/n,arcname=n,recursive=False)
patched=TASK/'builds/workspace-patch-materialization01';extracted=TASK/'builds/workspace-tar-materialization01'
patched.mkdir(mode=0o700,exist_ok=False);extracted.mkdir(mode=0o700,exist_ok=False)
for n in changed:
    p=patched/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(before_paths[n],p)
    assert p.stat().st_ino!=before_paths[n].stat().st_ino and row(p)==before[n]
commands=[]
for args in [['git','apply','--check','-p2',str(boundary/'delta.patch')],['git','apply','-p2',str(boundary/'delta.patch')]]:
    r=subprocess.run(args,cwd=patched,capture_output=True);assert r.returncode==0
    commands.append({'command':args,'true_exit':r.returncode,'stdout':r.stdout.decode(),'stderr':r.stderr.decode()})
with tarfile.open(boundary/'delta-contents.tar') as tar:
    members=tar.getmembers();assert len(members)==len(source) and {m.name for m in members}==set(source)
    for m in members:
        n=PurePosixPath(m.name);assert not n.is_absolute() and '..' not in n.parts
        r=source[m.name];p=extracted/m.name;p.parent.mkdir(parents=True,exist_ok=True)
        if r['kind']=='file':assert m.isfile();p.write_bytes(tar.extractfile(m).read());p.chmod(r['mode'])
        else:assert r['kind']=='symlink' and m.issym() and m.linkname==r['target'];p.symlink_to(m.linkname)
for target in [patched,extracted]:
    for n,r in source.items():
        if r['kind']=='file':(target/n).chmod(r['mode'])
    for n,mode in sorted(directories.items(),key=lambda x:len(PurePosixPath(x[0]).parts),reverse=True):(target/n).chmod(mode)
    assert {str(p.relative_to(target)) for p in target.rglob('*')}==set(source)|set(directories)
    for n,r in source.items():assert row(target/n)==r
    for n,mode in directories.items():assert stat.S_IMODE((target/n).stat().st_mode)==mode
write(boundary/'delta-materialization.json',{'generation_exit':diff.returncode,'exit1_means_differences':True,
    'patch_commands':commands,'changed_inherited_paths':changed,'separate_inherited_copies_before_patch':5,
    'copy_scope':'Five preserved exact before-files separately copied; sparse changed/new source only. No inherited links or full history copied or chmodded.',
    'patch_tree':str(patched),'tar_tree':str(extracted),'actual_tar_members':len(source),
    'full_delta_paths_contents_types_links_modes_checked':True,'full_inherited_source_reconstruction':False})
groups={};origins={};group_modes={};stored={}

def keep(p):
    digest=d.h(p);dest=boundary/'objects'/digest
    if not dest.exists():
        shutil.copyfile(p,dest);assert raw(dest)==digest;dest.chmod(0o444)
        stored[digest]={'bytes':p.stat().st_size,'storage':'new ordinary byte copy; no old source/object hardlinks'}
    return digest

def selected(label,origin,paths):
    assert paths and label not in groups
    rows={};where={};group_modes[label]=stat.S_IMODE(origin.stat().st_mode)
    for p in paths:
        assert p.is_relative_to(origin) and p.name!='api-dump.raw'
        while p!=origin:
            n=str(p.relative_to(origin));r=row(p)
            if r['kind']=='file':assert keep(p)==r['sha256']
            rows[n]=r;where[n]=str(p);p=p.parent
    groups[label]=rows;origins[label]=where

owners=TASK/'private/case20-preparation01/unchanged-owners'
selected('case20-private-invocation-code',owners,
    [owners/'godot-m4-vive-retest-20261030'/n for n in ['physical09.py','physical20.py','case_hashes.py']]+
    [owners/'godot-m4-vive-physical-20261029'/n for n in ['manual_run.py','environment.py','publication.py']])
selected('case20-executed-inputs',TASK/'private/native-vive-product20/drivers',sorted((TASK/'private/native-vive-product20/drivers').glob('*.py')))
selected('case20-wrapper-inputs',TASK/'private/runs/native-vive-product20-run/driver-inputs',sorted((TASK/'private/runs/native-vive-product20-run/driver-inputs').glob('*.py')))
provider=TASK/'private/case20-preparation01'
selected('case20-provider-code-and-receipts',provider,[provider/n for n in
    ['display-inventory','display_inventory.c','vive_display.py','driver-digest-adaptation.patch','preparation-private.json','provider-stdout.raw','provider-stderr.raw','display-rule.json']])
fixture=TASK/'private/quod-m4-live-native-vive-product20-server'
selected('case20-fresh-fixture-code-only',fixture,sorted(p for p in fixture.iterdir() if p.is_file() and p.suffix in ['.erl','.beam']))
private=TASK/'private/native-vive-product20'
selected('case20-small-raw-streams',private,[private/n for n in
    ['server-stdout.raw','server-stderr.raw','runtime-stdout.raw','runtime-stderr.raw','client-stdout.raw','client-stderr.raw','startup-inventory-stdout.raw','startup-inventory-stderr.raw']])
case=owners/'godot-m4-vive-retest-20261030/native-vive-product20'
selected('case20-private-results',case,[case/'result.json',case/'client-result.json'])
selected('case20-private-owner-binding',TASK/'private',[TASK/'private/native-vive-product20-invocation.json'])
selected('case20-display-preservation',private,[private/'display-rule.json',private/'closure-current-display.json'])
selected('case20-private-captures',private/'read-only-captures',sorted((private/'read-only-captures').glob('*.json')))
logs=owners/'godot-m4-vive-physical-20261029/logs'
selected('case20-wrapper-result',logs,[logs/'native-vive-product20-run.json'])
labels=sorted(p.name for p in (TASK/'private/runs').iterdir() if p.name.startswith(('workspace-','mapped20-')))
labels.append('native-vive-product20-run')
for name in labels:
    origin=TASK/'private/runs'/name
    selected(name+'-preexecution',origin/'driver-inputs',sorted((origin/'driver-inputs').glob('*')))
    selected(name+'-wrapper-streams',origin,[origin/'stdout.raw',origin/'stderr.raw'])
for folder in sorted(ev.iterdir()):
    if not folder.is_dir() or not folder.name.startswith('workspace-') or not (folder/'result.json').exists():continue
    result=load(folder/'result.json')
    if 'client_exit' not in result:continue
    origin=TASK/'private'/folder.name
    selected(folder.name+'-executed-owners',origin/'drivers',sorted((origin/'drivers').glob('*.py')))
    selected(folder.name+'-app-streams',origin,[origin/'stdout.raw',origin/'stderr.raw'])
selected('freeze-preexecution',runs/'driver-inputs',sorted((runs/'driver-inputs').glob('*.py')))
selected('private-instruction-and-control-receipts',TASK/'private/workspace127-integration01',sorted((TASK/'private/workspace127-integration01').glob('*.json')))
q=load(ev/'qualification.json');case_q=load(case_ev/'qualification.json')
selected('workspace-qualification-cache',Path(qc['path']).parent,[Path(qc['path'])])
selected('root127-independent-build-headless-cache',root_cache.parent,[root_cache])
prior_inputs=load(root/'doc/evidence/godot-m4-xr-focus-20261030/inputs/client-xr-focus-final01-manifest.json')['supplied_inputs']
build_references={}
for path in sorted((ev/'inputs').glob('client-workspace-*-manifest.json')):
    m=load(path);name=path.name[len('client-'):-len('-manifest.json')];stage=Path(m['stage'])/'source'
    changed_inputs=[stage/n for n,digest in m['supplied_inputs'].items() if prior_inputs.get(n)!=digest]
    selected(name+'-actual-staged-source-delta',stage,changed_inputs)
    ref={'stage':m['stage'],'manifest_path':str(path),'manifest_sha256':d.h(path),'passed':m['passed'],
        'supplied_inputs':{},'exports':{},'dependency_archives':m['dependency_archives'],
        'engine_archives':m['engine_archives'],'template':m['template'],
        'compiled_outputs_stored_in_boundary':False,'scope':'Canonical new build objects referenced; source deltas copied above. No export byte rehash or copy.'}
    if m['passed']:
        cache=Path(m['digest_cache']['path']);assert raw(cache)==m['digest_cache']['sha256']
        selected(name+'-build-cache',cache.parent,[cache])
        for r in load(cache)['records']:d.values[tuple(r['stat_key'])]=r['sha256']
        for n,digest in m['supplied_inputs'].items():
            p=stage/n;assert key(p) in d.values and d.h(p)==digest
            ref['supplied_inputs'][n]={'path':str(p),'sha256':digest,'stat_key':key(p),'mode':stat.S_IMODE(p.stat().st_mode)}
        dist=Path(m['export_executable']).parent
        assert {str(p.relative_to(dist)) for p in dist.rglob('*') if p.is_file()}==set(m['export_outputs'])
        for n,r in m['export_outputs'].items():
            p=dist/n;assert key(p) in d.values and d.h(p)==r['sha256'] and p.stat().st_size==r['bytes']
            ref['exports'][n]={**r,'path':str(p),'stat_key':key(p),'mode':stat.S_IMODE(p.stat().st_mode)}
    else:ref['failure']='Retained test-only CS1061 failure; no completed output set or executed application credited.'
    build_references[name]=ref
write(boundary/'canonical-build-references.json',build_references)
current_inputs={}
final_manifest=load(ev/'inputs/client-workspace-final06-manifest.json')
for n,digest in final_manifest['live_source_inputs'].items():
    p=root/n;assert key(p) in d.values and d.h(p)==digest
    current_inputs[n]={'sha256':digest,'stat_key':key(p),'mode':stat.S_IMODE(p.stat().st_mode)}
write(boundary/'current-product-input-custody.json',current_inputs)
assert list(key(Path(case_q['api_private_reference']['path'])))==case_q['api_private_reference']['stat_key']
write(boundary/'case20-api-reference.json',case_q['api_private_reference'])
assert all('api-dump.raw' not in p for rows in origins.values() for p in rows.values())
group_tree=TASK/'builds/workspace-group-materialization01';group_tree.mkdir(mode=0o700,exist_ok=False)
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
write(boundary/'object-groups.json',groups);write(boundary/'object-group-origins.json',origins)
write(boundary/'group-root-modes.json',group_modes);write(boundary/'object-storage.json',stored)
assert inventory()==current and git('diff','--binary','HEAD')==tracked and not git('diff','--cached','--name-only')
for n,r in source.items():assert row(root/n)==r
write(boundary/'qualification.json',q);write(boundary/'case20-qualification.json',case_q)
d.write(boundary/'used-stat-digests.json')
artifacts={str(p.relative_to(boundary)):{'sha256':raw(p),'bytes':p.stat().st_size} for p in boundary.rglob('*') if p.is_file()}
write(boundary/'snapshot.json',{'checkpoint':'Case20 failed panel usability followed by bounded shared spatial GUI correction and selected final06 software qualification',
    'worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','artifacts':artifacts,'previous_snapshot_sha256':parents[-1][1],
    'changed_inherited_paths':changed,'new_source_paths':len(additions),'actual_delta_materialized':True,
    'full_inherited_source_reconstructed':False,'selected_payload':'workspace-final06','product_supplied_inputs':93,
    'canonical_exports_referenced':196,'canonical_export_bytes':193322988,'export_objects_copied':0,'export_bytes_rehashed':0,
    'trace_free_product':True,'diagnostic_physical_payload_prepared':False,'physical_for_corrected_source':'UNRUN',
    'case20_protocol_retirement_passed':True,'case20_human_panel_usability':'FAILED','case20_target_activations':0,
    'api_bytes_read':0,'new_native_cases_after20':0,'full_M4_accepted':False,'commit_or_M5':False,
    'privacy':'Owner/raw/capture groups remain private Data; public source contains sanitized observations and software fixtures only.'})
for p in boundary.rglob('*'):
    if p.is_file():p.chmod(0o444)
for p in sorted([p for p in boundary.rglob('*') if p.is_dir()],key=lambda p:len(p.parts),reverse=True):p.chmod(0o555)
boundary.chmod(0o555)
print(json.dumps({'frozen':True,'boundary':str(boundary),'snapshot_sha256':raw(boundary/'snapshot.json'),
    'artifacts':len(artifacts),'objects':len(stored),'groups':len(groups),'group_paths':sum(len(v) for v in groups.values()),
    'changed_inherited_paths':len(changed),'new_source_paths':len(additions),'full_inherited_source_reconstructed':False,
    'canonical_exports_referenced':196,'export_bytes_rehashed':0,'api_bytes_read':0}),flush=True)
