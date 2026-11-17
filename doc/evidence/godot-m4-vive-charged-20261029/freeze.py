"""Additive source/object freeze; no product execution or old bulk recount."""
import hashlib,json,os,re,shutil,signal,subprocess,sys,tarfile,time
sys.dont_write_bytecode=True
from pathlib import Path,PurePosixPath
sys.path.insert(0,str(Path(__file__).resolve().parent.parent/'godot-m4-presentation-20261030'))
sys.path.append(str(Path(__file__).resolve().parent.parent/'godot-m4-vive-physical-20261029'))
from environment import TASK,environment
from digests import Digests,key,raw,SOURCES
root=Path.cwd();ev=Path(__file__).resolve().parent
run_id=sys.argv[-1];assert re.fullmatch(r'[0-9]{2}',run_id)
assert sys.argv[1:] in [[run_id],['--child',run_id]]
prior=TASK/'artifacts/quod-godot-m4-vive-physical-handoff-ca84d4f8-20261029-01'
older=TASK/'artifacts/quod-godot-m4-vr-handoff-ca84d4f8-20261029-01'
boundary=TASK/'artifacts'/('quod-godot-m4-vive-charged-handoff-ca84d4f8-20261030-'+run_id)
def load(p):return json.loads(Path(p).read_text())
def write(p,v):Path(p).write_text(json.dumps(v,indent=2)+'\n')
def git(*args):return subprocess.check_output(['git',*args],cwd=root)
def names(*args):return set(filter(None,git(*args,'-z').decode().split('\0')))
if sys.argv[1:]!=['--child',run_id]:
    os.umask(0o077);runs=TASK/('artifacts/vive-charged-freeze-runs'+run_id);runs.mkdir(mode=0o700,exist_ok=False)
    copies=runs/'driver-inputs';copies.mkdir(mode=0o700)
    for folder,prefix in [(ev,''),(ev.parent/'godot-m4-presentation-20261030','presentation--')]:
        for p in folder.iterdir():
            if p.is_file() and p.suffix in ['.py','.cs','.erl']:shutil.copy2(p,copies/(prefix+p.name))
    cmd=[sys.executable,str(Path(__file__).resolve()),'--child',run_id];started=time.time();timeout=False
    with (runs/'stdout.log').open('xb') as out,(runs/'stderr.log').open('xb') as err:
        child=subprocess.Popen(cmd,cwd=root,env=environment(),stdout=out,stderr=err,start_new_session=True)
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
    result={'command':cmd,'true_child_exit':status,'timed_out':timeout,'elapsed_seconds':time.time()-started,'explicit_completion':summary is not None,'passed':status==0 and not timeout and summary is not None,'summary':summary,'stdout':{'path':str(runs/'stdout.log'),'sha256':raw(runs/'stdout.log')},'stderr':{'path':str(runs/'stderr.log'),'sha256':raw(runs/'stderr.log')}}
    write(runs/'result.json',result);print(json.dumps(result));raise SystemExit(0 if result['passed'] else 1)
os.umask(0o077);assert not boundary.exists();d=Digests();h=d.h
for label in ['presentation-baseline01','presentation-final01','presentation-resize-diagnostic01','presentation-final02']:
    manifest=load(ev.parent/'godot-m4-presentation-20261030/inputs'/('client-'+label+'-manifest.json'))
    cache=manifest['digest_cache'];assert raw(cache['path'])==cache['sha256']
    for row in load(cache['path'])['records']:
        k=tuple(row['stat_key']);assert k not in d.values or d.values[k]==row['sha256'];d.values[k]=row['sha256']
parents=[]
for path,expected in [(prior,'be0f437252566a75268c616c18faf4fa0a4faa9724c5f89db7e3293b5aad7656'),(older,'5af20d5f7b168c53f2eab7d4524862a9db2957169a66879d29b0bdd23ad817fe')]:
    assert h(path/'snapshot.json')==expected
    descriptor=load(path/'snapshot.json');actual={str(p.relative_to(path)):p for p in path.rglob('*') if p.is_file()}
    assert set(actual)==set(descriptor['artifacts'])|{'snapshot.json'}
    for n,r in descriptor['artifacts'].items():assert actual[n].stat().st_size==r['bytes'] and actual[n].stat().st_mode&0o222==0
    parents.append((path,descriptor))
failed_object_sources=[]
for attempt in sorted((TASK/'artifacts').glob('quod-godot-m4-vive-charged-handoff-ca84d4f8-20261030-*')):
    if attempt==boundary or (attempt/'snapshot.json').exists() or not (attempt/'object-storage.json').exists():continue
    rows=load(attempt/'object-storage.json')
    descriptor={'artifacts':{'objects/'+digest:{'sha256':digest,'bytes':entry['bytes']} for digest,entry in rows.items()}}
    for digest,entry in rows.items():
        p=attempt/'objects'/digest;assert p.is_file() and not p.is_symlink() and p.stat().st_size==entry['bytes'] and p.stat().st_mode&0o222==0
    parents.insert(0,(attempt,descriptor));failed_object_sources.append({'path':str(attempt),'qualification':'FAILED; readonly byte custody only, each reused object requires an authenticated current stat digest or actual byte hash','object_storage_sha256':h(attempt/'object-storage.json')})
assert git('branch','--show-current').decode().strip()=='worktree/pearl-stone'
assert git('rev-parse','HEAD').decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert not git('diff','--cached','--name-only')
patch=git('diff','--binary','HEAD')
assert patch and git('diff','--check')==b''
assert h(root/'client/godot/Main.cs')=='e9c010f71a9c1369fd5b451fe1d7fa275948089b3a96e69fe6d8f21b543fec1e'
assert load(ev/'acceptance.json')['full_m4_accepted'] is False
for label in ['native-vive-product06','native-vive-product07']:
    folder=ev.parent/'godot-m4-vive-physical-20261029' if label.endswith('06') else ev
    r=load(folder/label/'result.json');assert r['client_exit']==r['runtime_exit']==r['server_exit']==0 and all(r['eof'].values()) and not r['runtime_processes_after']
    assert not any(c.get('diagnostic_instruction') in ['sample','gui-check'] for c in r['commands'])
tracked=names('ls-files','--cached');untracked=names('ls-files','--others','--exclude-standard');source={};dirs={};links={}
for n in sorted(tracked|untracked):
    p=root/n;mode=p.lstat().st_mode&0o7777
    if p.is_symlink():source[n]={'kind':'symlink','target':str(p.readlink()),'tracked':n in tracked};links[n]=mode
    else:assert p.is_file();source[n]={'kind':'file','sha256':h(p),'bytes':p.stat().st_size,'mode':mode,'tracked':n in tracked}
    for parent in PurePosixPath(n).parents:
        if str(parent)!='.':dirs[str(parent)]=(root/str(parent)).stat().st_mode&0o7777
old=load(prior/'source-manifest.json')
changed=sorted(n for n,r in old.items() if source.get(n)!=r)
expected_changes=sorted(['client/godot/OpenXRInput.cs','client/godot/ScenePanel.cs','client/godot/tests/ControllerChecks.cs','client/godot/tests/ExportChecks.cs','client/godot/README.md'])
assert changed==expected_changes,(changed,'unexpected source change')
assert all(source[n]['kind']==old[n]['kind']=='file' and source[n]['mode']==old[n]['mode'] for n in changed)
additions=sorted(set(source)-set(old));assert additions
generated_python_caches={}
for n in additions:
    if n.endswith('.pyc') and '/__pycache__/' in n:
        import importlib.util
        original=str(Path(importlib.util.source_from_cache(str(root/n))).relative_to(root))
        assert original in source and source[original]['kind']=='file'
        generated_python_caches[n]={'source':original,'source_sha256':source[original]['sha256'],'classification':'generated non-build Python cache; never an authored/compiled application input'}
allowed=('doc/evidence/godot-m4-vive-physical-20261029/','doc/evidence/godot-m4-vive-charged-20261029/','doc/evidence/godot-m4-presentation-20261030/','doc/evidence/godot-m4-r2-coordinator-20261029/','nimbalyst-local/handoffs/godot-m4-vive-')
outside=[n for n in additions if not (n.startswith(allowed) or n=='client/godot/tests/PresentationChecks.cs')]
assert all(n in generated_python_caches and source[generated_python_caches[n]['source']]==old.get(generated_python_caches[n]['source']) for n in outside),outside
boundary.mkdir(mode=0o700);(boundary/'objects').mkdir()
write(boundary/'source-manifest.json',source);write(boundary/'source-directory-modes.json',dirs);write(boundary/'source-symlink-modes.json',links);(boundary/'tracked.patch').write_bytes(patch)
shutil.copyfile(ev.parent/'godot-m4-presentation-20261030/inputs/previous-source-delta.patch',boundary/'delta.patch')
write(boundary/'generated-non-build-cache-inputs.json',generated_python_caches)
write(boundary/'failed-readonly-object-sources.json',failed_object_sources)
write(boundary/'source-status.json',{'head':'293cf6115c0a6b18315eccdbb42cbca396f443d3','branch':'worktree/pearl-stone','index_empty':True,'source_entries':len(source),'previous_entries':len(old),'new_additions':additions,'changed_previous_paths':changed,'generated_agents':sum(n.startswith('.agents/') for n in untracked),'production_owner_changes':2,'test_changes':3,'readme_changes':1,'spec_changes':0,'implementation_writer_frozen':True,'custom_question37_pending':False,'session_turn_completion_not_inferred':True})
with tarfile.open(boundary/'additions.tar','x:') as archive:
    for n in additions:archive.add(root/n,arcname=n,recursive=False)
write(boundary/'previous-boundary-reference.json',{'path':str(prior),'snapshot_sha256':h(prior/'snapshot.json'),'previous_full_source':str(TASK/'builds/coordinator-physical-source-reconstruction-53'),'scope':'Complete prior base/HEAD patch/full untracked bytes retained recursively. Actual new HEAD binary patch plus applied five-file delta.patch and real additions.tar contain every current change/addition; exact complete reconstruction starts from coordinator53 actual materialization without another3GB copy.'})
stored={};groups={};origins={}
def keep(p):
    digest=h(p)
    if digest in stored:return digest
    q=boundary/'objects'/digest
    for parent,descriptor in parents:
        target=parent/'objects'/digest
        if target.exists():
            assert descriptor['artifacts']['objects/'+digest]['sha256']==digest and target.stat().st_mode&0o222==0 and target.stat().st_size==p.stat().st_size
            before=key(target);before_links=target.stat().st_nlink;assert h(target)==digest
            d.link(target,q,digest)
            stored[digest]={'method':'verified readonly prior object; actual same-filesystem inode reuse','source':str(target),'before_stat':before,'before_links':before_links,'bytes':q.stat().st_size}
            return digest
    shutil.copyfile(p,q);assert raw(q)==digest;q.chmod(0o444)
    stored[digest]={'method':'new actual bytes copied and independently hashed','bytes':q.stat().st_size};return digest
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
    rows={};paths={}
    for directory,children,files in os.walk(origin,followlinks=False):
        parent=Path(directory)
        for name in list(children):
            p=parent/name;n=str(p.relative_to(origin));rows[n]=row(p);paths[n]=str(p)
            if p.is_symlink():children.remove(name)
        for name in files:
            p=parent/name;n=str(p.relative_to(origin));rows[n]=row(p);paths[n]=str(p)
    groups[label]=rows;origins[label]=paths
for label in ['physical03','physical04','presentation-baseline01','presentation-final01','presentation-resize-diagnostic01','presentation-final02']:tree('source-only-client-'+label,TASK/'artifacts'/('client-'+label))
for attempt in sorted((TASK/'artifacts').glob('vive-charged-freeze-runs*')):
    if attempt.name!=('vive-charged-freeze-runs'+run_id) and (attempt/'result.json').exists():tree('retained-freeze-attempt-'+attempt.name,attempt)
for attempt in failed_object_sources:
    folder=Path(attempt['path']);selected={};paths={}
    for p in folder.iterdir():
        if p.is_file():selected[p.name]=row(p);paths[p.name]=str(p)
    name='retained-failed-boundary-metadata-'+folder.name;groups[name]=selected;origins[name]=paths
for directory in sorted((TASK/'private/build-inputs').iterdir()):
    if directory.is_dir() and directory.name.startswith(('charged-geometry-','presentation-')):tree('pre-execution-'+directory.name,directory)
for directory in sorted((TASK/'private/metadata-inputs').iterdir()):
    if directory.is_dir() and directory.name.startswith('geometry-'):tree('metadata-pre-execution-'+directory.name,directory)
for directory in sorted((TASK/'private').iterdir()):
    if directory.is_dir() and directory.name.startswith('presentation-') and (directory/'drivers').is_dir():tree('actual-application-drivers-'+directory.name,directory/'drivers')
selected={};paths={}
for directory in sorted((TASK/'private/runs').iterdir()):
    if (directory/'driver-inputs').is_dir() and (ev.parent/'godot-m4-vive-physical-20261029/logs'/(directory.name+'.json')).exists() and directory.name.startswith(('native-vive-product06','native-vive-product07','charged-','presentation-')):
        for p in (directory/'driver-inputs').iterdir():
            if p.is_file():n=directory.name+'--'+p.name;selected[n]=row(p);paths[n]=str(p)
for label in ['native-vive-product06','native-vive-product07']:
    for p in (TASK/'private'/label/'drivers').iterdir():
        if p.is_file():n=label+'--'+p.name;selected[n]=row(p);paths[n]=str(p)
for p in (TASK/('artifacts/vive-charged-freeze-runs'+run_id)/'driver-inputs').iterdir():
    if p.is_file():n='freeze'+run_id+'--'+p.name;selected[n]=row(p);paths[n]=str(p)
groups['actual-executed-diagnostic-drivers']=selected;origins['actual-executed-diagnostic-drivers']=paths
coord=root/'_build/godot-m4-r2-coordinator-20261029';selected={};paths={}
for p in coord.iterdir():
    if p.is_file() and p.suffix in ['.json','.py','.stdout','.stderr','.log'] and any(remainder in p.name for remainder in ['-53','-54','-55','-56','-57','-58','-59','-60','-61']):
        selected[p.name]=row(p);paths[p.name]=str(p)
groups['independent-coordinator-inputs']=selected;origins['independent-coordinator-inputs']=paths
selected={};paths={}
for i,(p,digest) in enumerate(SOURCES):selected[str(i)+'-'+p.name]=row(p);paths[str(i)+'-'+p.name]=str(p)
groups['verified-stat-cache-inputs']=selected;origins['verified-stat-cache-inputs']=paths
write(boundary/'object-groups.json',groups);write(boundary/'object-group-origins.json',origins);write(boundary/'object-storage.json',stored)
d.write(boundary/'pre-reconstruction-digests.json')
write(boundary/'input-output-classification.json',{'supplied_inputs':'Physical03/04 preserve their92 diagnostic supplied inputs; presentation stages preserve92 actual authored inputs with no overrides. Manifests distinguish baseline/temporary-test-observer/final02 and exact live source changes.','dependencies':'Exact pinned toolchain/package archives/provider bytes reused by prior immutable graph; stage packages are cold-restore/generated dependencies, not copied compiled application inputs.','generated_outputs':'All remaining stage build/restore/export outputs and receipts explicitly captured, including196 exports each.','new_product_owner_changes':2,'source_relocation':0,'privacy_exclusions':'No active identity/store, credentials, original/private calibration, raw runtime/client/API/stacks copied. Sanitized complete logs/receipts are public source inputs; restricted raw bytes remain at recorded private paths.','raw_new_diagnostics':'Room geometry, API streams and all profiles/calibration/stores remain private0700/0600. Root56/58/59 exact-stat caches bind retained outputs; no unchanged dump rehash/reparse. New render fixture PNGs depict only the admitted static model and contain no room observations.'})
print(json.dumps({'source_entries':len(source),'source_additions':len(additions),'changed_previous_paths':changed,'new_object_groups':{k:len(v) for k,v in groups.items()},'objects':len(stored)}),flush=True)
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
write(boundary/'snapshot.json',{'checkpoint':'QUO-65 charged Vive observations and bounded presentation corrections','worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','actual_model':'openai-codex:gpt-6.1-sol','launcher_effort':'max','backend_effective_effort':'unexposed','artifacts':artifacts,'previous_boundary':str(prior),'previous_snapshot_sha256':h(prior/'snapshot.json'),'source_entries':len(source),'source_additions':len(additions),'changed_previous_paths':changed,'source_and_groups_actually_reconstructed':True,'implementation_writer_frozen':True,'custom_question37_pending':False,'session_turn_complete':False,'physical_acceptance':'Case07 physical04 both-model/yellow-beam visibility only; contrast/distance poor. Corrected final02 physical qualification UNRUN.','full_m4_accepted':False})
for p in boundary.rglob('*'):
    if p.is_file() and p.stat().st_mode&0o222:p.chmod(0o444)
for p in sorted([p for p in boundary.rglob('*') if p.is_dir()],key=lambda p:len(p.parts),reverse=True):p.chmod(0o555)
boundary.chmod(0o555)
print(json.dumps({'frozen':True,'boundary':str(boundary),'snapshot_sha256':raw(boundary/'snapshot.json'),'additions_sha256':raw(boundary/'additions.tar'),'source_entries':len(source),'source_additions':len(additions),'changed_previous_paths':changed,'artifacts':len(artifacts),'objects':len(stored),'prior_readonly_objects_reused':sum(r['method'].startswith('verified') for r in stored.values()),'source_materialization':str(TASK/('builds/vive-charged-source-reconstruction'+run_id)),'group_materialization':str(TASK/('builds/vive-charged-group-reconstruction'+run_id)),'cache_hits':d.hits,'new_hashes':d.new,'new_bytes_hashed':d.bytes}),flush=True)

