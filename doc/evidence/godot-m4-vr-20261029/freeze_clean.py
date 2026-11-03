"""Add clean-engine evidence without rewriting the immutable Vive boundary01."""
import hashlib,json,os,shutil,signal,subprocess,sys,tarfile,time
from pathlib import Path,PurePosixPath
from environment import TASK,environment
root=Path.cwd();ev=Path(__file__).resolve().parent
prior=TASK/'artifacts/quod-godot-m4-vr-handoff-ca84d4f8-20261029-01'
boundary=TASK/'artifacts/quod-godot-m4-vr-handoff-ca84d4f8-20261029-02'
def h(p):
    with p.open('rb') as s:return hashlib.file_digest(s,'sha256').hexdigest()
def load(p):return json.loads(p.read_text())
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def git(*args):return subprocess.check_output(['git',*args],cwd=root)
def names(*args):return set(filter(None,git(*args,'-z').decode().split('\0')))
if sys.argv[1:]!=['--child']:
    runs=TASK/'artifacts/vr-freeze-runs02';runs.mkdir(mode=0o700,exist_ok=False)
    command=[sys.executable,str(Path(__file__).resolve()),'--child'];started=time.time();timeout=False
    with (runs/'stdout.log').open('xb') as output,(runs/'stderr.log').open('xb') as error:
        child=subprocess.Popen(command,cwd=root,env=environment(),stdout=output,stderr=error,start_new_session=True)
        try:status=child.wait(timeout=900)
        except subprocess.TimeoutExpired:
            timeout=True;os.killpg(child.pid,signal.SIGTERM)
            try:status=child.wait(timeout=10)
            except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);status=child.wait()
    summary=None
    for line in (runs/'stdout.log').read_text().splitlines():
        if line.startswith('{'):
            value=json.loads(line)
            if value.get('frozen'):summary=value
    result={'command':command,'cwd':str(root),'true_child_exit':status,'timed_out':timeout,'elapsed_seconds':time.time()-started,'explicit_completion':summary is not None,'passed':status==0 and not timeout and summary is not None,'stdout':{'path':str(runs/'stdout.log'),'sha256':h(runs/'stdout.log')},'stderr':{'path':str(runs/'stderr.log'),'sha256':h(runs/'stderr.log')},'summary':summary}
    write(runs/'result.json',result)
    for p in runs.iterdir():p.chmod(0o600)
    print(json.dumps(result));raise SystemExit(0 if result['passed'] else 1)
os.umask(0o077)
assert not boundary.exists()
assert h(prior/'snapshot.json')=='5af20d5f7b168c53f2eab7d4524862a9db2957169a66879d29b0bdd23ad817fe'
assert load(ev/'clean-build/qualification.json')['passed']
assert load(TASK/'artifacts/engine/clean02/receipt.json')['passed']
assert load(TASK/'artifacts/toolchain-live-check02.json')['passed']
assert git('branch','--show-current').decode().strip()=='worktree/pearl-stone'
assert git('rev-parse','HEAD').decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3' and not git('diff','--cached','--name-only')
patch=git('diff','--binary','HEAD');assert patch==(prior/'tracked.patch').read_bytes()
tracked=names('ls-files','--cached');untracked=names('ls-files','--others','--exclude-standard');source={};dirs={};links={}
for name in sorted(tracked|untracked):
    p=root/name;mode=p.lstat().st_mode&0o7777
    if p.is_symlink():source[name]={'kind':'symlink','target':str(p.readlink()),'tracked':name in tracked};links[name]=mode
    else:assert p.is_file();source[name]={'kind':'file','sha256':h(p),'bytes':p.stat().st_size,'mode':mode,'tracked':name in tracked}
    for parent in PurePosixPath(name).parents:
        if str(parent)!='.':dirs[str(parent)]=(root/str(parent)).stat().st_mode&0o7777
old=load(prior/'source-manifest.json');assert all(source.get(n)==r for n,r in old.items()),'Frozen boundary01 source changed'
additions=sorted(set(source)-set(old));assert additions
assert all(n.startswith('doc/evidence/godot-m4-vr-20261029/') or n=='nimbalyst-local/handoffs/godot-m4-vr-clean-result.md' for n in additions),additions
boundary.mkdir(mode=0o700);objects=boundary/'objects';objects.mkdir()
write(boundary/'source-manifest.json',source);write(boundary/'source-directory-modes.json',dirs);write(boundary/'source-symlink-modes.json',links);(boundary/'tracked.patch').write_bytes(patch)
write(boundary/'source-status.json',{'branch':'worktree/pearl-stone','head':'293cf6115c0a6b18315eccdbb42cbca396f443d3','parent':'f716ddf5e578df957a5b18421a0727a32c634f87','index_empty':True,'source_entries':len(source),'previous_entries':len(old),'new_additions':additions,'changed_prior_entries':[],'generated_agents_files':sum(n.startswith('.agents/') for n in untracked),'new_repository_production_test_spec_changes':0,'writer_idle_frozen':True,'commit':False})
with tarfile.open(boundary/'additions.tar','x:') as archive:
    for name in additions:archive.add(root/name,arcname=name,recursive=False)
descriptor=load(prior/'snapshot.json');actual={str(p.relative_to(prior)):p for p in prior.rglob('*') if p.is_file()}
assert set(actual)==set(descriptor['artifacts'])|{'snapshot.json'}
for name,row in descriptor['artifacts'].items():assert actual[name].stat().st_size==row['bytes'] and actual[name].stat().st_mode&0o222==0,name
write(boundary/'previous-boundary-reference.json',{'path':str(prior),'snapshot_sha256':h(prior/'snapshot.json'),'artifacts':len(descriptor['artifacts']),'complete_path_set_sizes_readonly_modes_checked':True,'source_bytes_and_actual_base_binary_patch_untracked_contents':'Retained actual previous immutable artifact graph, including home-side observation1/R2 references, plus new real additions.tar; no hash-only source snapshot.','unchanged_output_reuse':'Exact previous object/group materializations and qualification reused; no old campaign rerun or full old-object rehash. New groups independently reconstructed below.'})
groups={};origins={};stored={}
def keep(p):
    digest=h(p);target=objects/digest
    if digest not in stored:
        prior_object=prior/'objects'/digest
        if prior_object.exists():
            assert descriptor['artifacts']['objects/'+digest]['sha256']==digest and prior_object.stat().st_mode&0o222==0
            assert prior_object.stat().st_dev==objects.stat().st_dev
            os.link(prior_object,target);method='actual verified readonly prior object, same filesystem/inode'
        else:shutil.copyfile(p,target);assert h(target)==digest;target.chmod(0o444);method='new actual bytes copied and independently hashed'
        stored[digest]={'method':method,'bytes':p.stat().st_size}
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
    rows={}
    for directory,children,files in os.walk(origin,followlinks=False):
        parent=Path(directory)
        for name in list(children):
            p=parent/name;rows[str(p.relative_to(origin))]=row(p)
            if p.is_symlink():children.remove(name)
        for name in files:
            p=parent/name;rows[str(p.relative_to(origin))]=row(p)
    groups[label]=rows;origins[label]={'root':str(origin),'scope':'complete tree without following directory symlinks'}
tree('failed-clean01-prebuild-source',TASK/'builds/engine-clean01')
tree('clean02-authored-generated-output',TASK/'builds/engine-clean02')
tree('clean02-retained-native-binary',TASK/'artifacts/engine/clean02')
tree('python-stdlib-native-dependency-provider',TASK/'artifacts/python-stdlib-inputs02')
selected={}
for label in ['engine-clean-build01','engine-clean-build02','toolchain-live-check02','python-stdlib-inputs02','qualify-clean02']:
    directory=TASK/'private/runs'/label/'driver-inputs'
    for p in directory.iterdir():
        if p.is_file():
            relative=p.relative_to(TASK/'private/runs');selected[str(relative)]=row(p)
            for parent in relative.parents:
                if str(parent)!='.':selected[str(parent)]=row(TASK/'private/runs'/parent)
selected['toolchain-live-check02.json']=row(TASK/'artifacts/toolchain-live-check02.json')
closure=TASK/'artifacts/vr-freeze-runs01';selected['prior-freeze']=row(closure)
for p in closure.iterdir():
    if p.is_file():selected['prior-freeze/'+p.name]=row(p)
groups['new-executed-drivers-and-toolchain-check']=selected;origins['new-executed-drivers-and-toolchain-check']={'scope':'Explicit source copies captured before the five new executions, live toolchain comparison receipt and the previous boundary closing stdout/stderr/result receipt; raw private application logs excluded.'}
coord=root/'_build/godot-m4-r2-coordinator-20261029';coordrows={}
for p in coord.iterdir():
    if p.is_file() and '39' in p.name and p.suffix in ['.json','.py','.log','.stderr','.stdout']:coordrows[p.name]=row(p)
groups['independent-coordination-inputs-39']=coordrows;origins['independent-coordination-inputs-39']={'root':str(coord),'scope':'Separately labelled read-only coordinator39 receipts/verifiers/errors; no product test rerun.'}
write(boundary/'object-groups.json',groups);write(boundary/'object-group-origins.json',origins);write(boundary/'object-storage.json',stored)
original=load(TASK/'builds/engine01/original-source-manifest.json');changes=load(TASK/'artifacts/engine/patch01/manifest.json')
for value in original:
    p=TASK/'builds/engine-clean02/godot-4.7.2-stable'/value['path'];assert p.lstat().st_mode&0o7777==value['mode']
    if value['type']=='file':assert h(p)==changes.get(value['path'],{}).get('after',value['sha256']),value['path']
write(boundary/'input-output-classification.json',{'clean_original_authored_paths':['godot-4.7.2-stable/'+v['path'] for v in original],'only_authored_deltas':changes,'all_other_clean_group_paths':'Generated build outputs/receipts; compiled inputs were absent from the fresh official extraction.','unchanged_dependencies':'Exact previous official archive/SCons/compiler/provider and pinned client/runtime dependencies retained by previous immutable reference. Live76047 toolchain paths matched.','no_private_inputs':'No calibration, active identity, credentials, raw API/stdout/stderr/stacks copied.'})
write(boundary/'qualification.json',load(ev/'clean-build/qualification.json'))
print(json.dumps({'new_groups_retained':{k:len(v) for k,v in groups.items()},'objects':len(stored),'new_source_additions':len(additions)}),flush=True)

# Preserve boundary01's source reconstruction, sharing only verified old file
# bytes/modes and never writing/chmodding their hardlinked inodes.
previous_source=TASK/'builds/complete-source-materialization01';scratch=TASK/'builds/complete-source-materialization02';scratch.mkdir(mode=0o700,exist_ok=False)
assert subprocess.run(['git','rev-parse','--show-toplevel'],cwd=scratch,capture_output=True).returncode!=0
for name,value in old.items():
    p=previous_source/name;q=scratch/name;q.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    if value['kind']=='symlink':assert p.is_symlink() and str(p.readlink())==value['target'];q.symlink_to(value['target'])
    else:assert h(p)==value['sha256'] and p.stat().st_mode&0o7777==value['mode'];os.link(p,q)
with tarfile.open(boundary/'additions.tar','r:') as archive:
    for member in archive:
        relative=PurePosixPath(member.name);assert not relative.is_absolute() and '..' not in relative.parts and str(relative) in additions
        p=scratch/str(relative);assert not p.exists() and not p.is_symlink();p.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        if member.issym():p.symlink_to(member.linkname)
        else:
            assert member.isfile()
            with p.open('xb') as output:shutil.copyfileobj(archive.extractfile(member),output)
            p.chmod(member.mode)
for name,mode in sorted(dirs.items(),key=lambda r:len(PurePosixPath(r[0]).parts),reverse=True):(scratch/name).chmod(mode)
actualsource={};actualdirs={}
for directory,children,files in os.walk(scratch,followlinks=False):
    parent=Path(directory)
    for name in list(children):
        p=parent/name
        if p.is_symlink():files.append(name);children.remove(name)
        else:actualdirs[str(p.relative_to(scratch))]=p.stat().st_mode&0o7777
    for name in files:actualsource[str((parent/name).relative_to(scratch))]=parent/name
assert set(actualsource)==set(source) and actualdirs==dirs
for name,value in source.items():
    p=actualsource[name]
    if value['kind']=='file':assert h(p)==value['sha256'] and p.stat().st_size==value['bytes'] and p.stat().st_mode&0o7777==value['mode']
    else:assert p.is_symlink() and str(p.readlink())==value['target'] and p.lstat().st_mode&0o7777==links[name]
write(boundary/'independent-source-reconstruction.json',{'passed':True,'source_entries':len(source),'directories':len(dirs),'new_additions':len(additions),'materialization':str(scratch),'outside_every_checkout':True,'method':'Verified actual previous complete source bytes/modes shared by same-filesystem file hardlinks without modifying old inodes; real new addition tar extracted; independently checked COMPLETE new source path/content/link/full file/directory/symlink mode set. Previous source reconstruction remains unchanged.'})
assert subprocess.run([sys.executable,str(ev/'verify_materialize.py'),str(boundary),str(TASK/'builds/vr-boundary02-materialized-groups'),str(boundary/'independent-object-reconstruction.json')],env=environment()).returncode==0
assert names('ls-files','--cached')==tracked and names('ls-files','--others','--exclude-standard')==untracked and git('diff','--binary','HEAD')==patch and not git('diff','--cached','--name-only')
for name,value in source.items():
    p=root/name
    if value['kind']=='file':assert h(p)==value['sha256'] and p.stat().st_mode&0o7777==value['mode'],name
    else:assert p.is_symlink() and str(p.readlink())==value['target'],name
artifacts={str(p.relative_to(boundary)):{'sha256':h(p),'bytes':p.stat().st_size} for p in boundary.rglob('*') if p.is_file()}
write(boundary/'snapshot.json',{'checkpoint':'QUO-65 private Vive clean-engine additive qualification','worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','artifacts':artifacts,'previous_boundary':str(prior),'previous_snapshot_sha256':h(prior/'snapshot.json'),'source_entries':len(source),'source_additions':len(additions),'source_and_new_object_groups_reconstructed':True,'production_changes':0,'full_M4_accepted':False,'writer_idle_frozen':True})
for p in boundary.rglob('*'):
    if p.is_file() and p.stat().st_mode&0o222:p.chmod(0o444)
for p in sorted([p for p in boundary.rglob('*') if p.is_dir()],key=lambda p:len(p.parts),reverse=True):p.chmod(0o555)
boundary.chmod(0o555)
print(json.dumps({'frozen':True,'boundary':str(boundary),'snapshot_sha256':h(boundary/'snapshot.json'),'additions_sha256':h(boundary/'additions.tar'),'source_entries':len(source),'source_additions':len(additions),'artifacts':len(artifacts),'objects':len(stored),'previous_objects_reused':sum(r['method'].startswith('actual verified') for r in stored.values()),'new_groups':{k:len(v) for k,v in groups.items()}}),flush=True)
