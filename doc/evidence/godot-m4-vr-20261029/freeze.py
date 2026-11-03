"""Additive /data freeze; old immutable bytes remain explicit verified references."""
import hashlib,importlib.util,json,os,re,shutil,signal,subprocess,sys,tarfile,time
from pathlib import Path,PurePosixPath
from environment import TASK,environment
root=Path.cwd();ev=Path(__file__).resolve().parent
prior=Path('/home/yan/.cache/quod-m4-observation1-artifacts/quod-godot-m4-observation1-handoff-ca84d4f8-20261029-01')
boundary=TASK/'artifacts/quod-godot-m4-vr-handoff-ca84d4f8-20261029-01'
def h(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def load(p):return json.loads(p.read_text())
def git(*args):return subprocess.check_output(['git',*args],cwd=root)
def names(*args):return set(filter(None,git(*args,'-z').decode().split('\0')))

if sys.argv[1:]!=['--child']:
    runs=TASK/'artifacts/vr-freeze-runs01';runs.mkdir(mode=0o700,exist_ok=False)
    command=[sys.executable,str(Path(__file__).resolve()),'--child'];started=time.time();timeout=False
    with (runs/'stdout.log').open('xb') as output,(runs/'stderr.log').open('xb') as error:
        process=subprocess.Popen(command,cwd=root,env=environment(),stdout=output,stderr=error,start_new_session=True)
        try:status=process.wait(timeout=900)
        except subprocess.TimeoutExpired:
            timeout=True;os.killpg(process.pid,signal.SIGTERM)
            try:status=process.wait(timeout=10)
            except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);status=process.wait()
    for p in runs.iterdir():p.chmod(0o600)
    summary=None
    for line in (runs/'stdout.log').read_text().splitlines():
        if line.startswith('{'):
            row=json.loads(line)
            if row.get('frozen'):summary=row
    receipt={'command':command,'cwd':str(root),'true_child_exit':status,'timed_out':timeout,'elapsed_seconds':time.time()-started,'explicit_completion':summary is not None,'passed':status==0 and not timeout and summary is not None,'stdout':{'path':str(runs/'stdout.log'),'sha256':h(runs/'stdout.log')},'stderr':{'path':str(runs/'stderr.log'),'sha256':h(runs/'stderr.log')},'summary':summary}
    write(runs/'result.json',receipt);(runs/'result.json').chmod(0o600);print(json.dumps(receipt));raise SystemExit(0 if receipt['passed'] else 1)

os.umask(0o077)
assert not boundary.exists(),'Preserve every old or incomplete boundary'
assert h(prior/'snapshot.json')=='b914f02fa049f5c8698f04e9b855228185224207771bc882d815d36cc1e7ed92'
assert git('rev-parse','HEAD').decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert git('branch','--show-current').decode().strip()=='worktree/pearl-stone' and not git('diff','--cached','--name-only')
patch=git('diff','--binary','HEAD');assert patch==(prior/'previous/tracked.patch').read_bytes()
assert h(root/'client/godot/Main.cs')=='e9c010f71a9c1369fd5b451fe1d7fa275948089b3a96e69fe6d8f21b543fec1e'
assert not load(ev/'qualification.json')['full_M4_accepted']
assert shutil.disk_usage(TASK).free>20*1024**3
spec=importlib.util.spec_from_file_location('unchanged_vive_inventory',root/'doc/evidence/godot-m4-r2-20261029/private_vive.py')
vive=importlib.util.module_from_spec(spec);spec.loader.exec_module(vive);assert not vive.active_runtime_processes()
tracked=names('ls-files','--cached');untracked=names('ls-files','--others','--exclude-standard');source={};directories={};symlink_modes={}
for name in sorted(tracked|untracked):
    path=root/name;mode=path.lstat().st_mode&0o7777
    if path.is_symlink():source[name]={'kind':'symlink','target':str(path.readlink()),'tracked':name in tracked};symlink_modes[name]=mode
    else:
        assert path.is_file() and not mode&0o7000,name
        source[name]={'kind':'file','sha256':h(path),'bytes':path.stat().st_size,'mode':mode,'tracked':name in tracked}
    for parent in PurePosixPath(name).parents:
        if str(parent)=='.':continue
        p=root/str(parent);assert p.is_dir() and not p.is_symlink();directories[str(parent)]=p.stat().st_mode&0o7777
old=load(prior/'source-manifest.json');assert all(source.get(n)==r for n,r in old.items()),'Previous source byte/link/mode changed'
additions=sorted(set(source)-set(old));assert additions
allowed=lambda n:n.startswith('doc/evidence/godot-m4-vr-20261029/') or n in ['nimbalyst-local/handoffs/godot-m4-vr-investigation-prompt.md','nimbalyst-local/handoffs/godot-m4-vr-result.md']
assert all(allowed(n) for n in additions),[n for n in additions if not allowed(n)]
boundary.mkdir(mode=0o700);objects=boundary/'objects';objects.mkdir()
write(boundary/'source-manifest.json',source);write(boundary/'source-directory-modes.json',directories);write(boundary/'source-symlink-modes.json',symlink_modes)
(boundary/'tracked.patch').write_bytes(patch)
write(boundary/'source-status.json',{'head':git('rev-parse','HEAD').decode().strip(),'parent':git('rev-parse','HEAD^').decode().strip(),'original_base_provenance':'f6c29fe925e666dd68ee7fa68c0e03f5d03391a2','branch':'worktree/pearl-stone','index_empty':True,'previous_source_entries':len(old),'source_entries':len(source),'new_additions':additions,'changed_previous_entries':[],'generated_agents_files':sum(n.startswith('.agents/') for n in untracked),'new_repository_production_test_spec_changes':0,'committed':False,'writer_idle_frozen':True})
with tarfile.open(boundary/'additions.tar','x:') as archive:
    for name in additions:archive.add(root/name,arcname=name,recursive=False)
previous=load(prior/'snapshot.json');references={}
for name,row in previous['artifacts'].items():
    p=prior/name;assert p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and p.stat().st_mode&0o222==0,name
    references[name]={'path':str(p),'sha256':row['sha256'],'bytes':row['bytes']}
assert {str(p.relative_to(prior)) for p in prior.rglob('*') if p.is_file()}==set(previous['artifacts'])|{'snapshot.json'}
write(boundary/'unchanged-artifact-references.json',{'previous_boundary':str(prior),'previous_descriptor_sha256':h(prior/'snapshot.json'),'references':references,
    'method':'Explicit references to the exact already independently verified immutable descriptor/artifact set; size, path set and readonly status checked. No cross-filesystem hardlinks or symbolic-copy claims. Old hashes/qualification reused, not an old test rerun or complete old-artifact rehash.',
    'complete_source_contents':'Exact old base/binary patch/full-untracked payload bytes remain at these immutable reference paths; actual new additions are in additions.tar. Full current source is independently reconstructed on /data.',
    'unchanged_runtime':'previous/object-groups.json: private-runtime-source-dependencies-and-build-outputs; unchanged source/output/dependency object bytes and R2 reconstruction receipts reused. Not a whole-host/kernel/GPU image.'})
groups={};origins={};stored={}
def preserve(path):
    digest=h(path);target=objects/digest
    if digest not in stored:
        # Existing task-captured toolchain objects are already immutable and
        # on this filesystem. Ordinary source/output files are always copied.
        if path.parent==TASK/'artifacts/toolchain-inputs01/objects' and path.name==digest and not path.stat().st_mode&0o222:
            os.link(path,target);method='same-filesystem verified readonly captured object'
        else:shutil.copyfile(path,target);assert h(target)==digest;target.chmod(0o444);method='actual new bytes copied and independently hashed'
        stored[digest]={'bytes':path.stat().st_size,'method':method}
    return digest
def row(path):
    mode=path.lstat().st_mode&0o7777
    if path.is_symlink():
        r={'kind':'symlink','target':str(path.readlink()),'mode':mode}
        if path.is_file():r.update(resolved_sha256=preserve(path),resolved_bytes=path.stat().st_size)
        return r
    if path.is_dir():return {'kind':'directory','mode':mode}
    assert path.is_file(),path
    assert path.name not in ['active.json','writer.lock','tls-key.pem','proxy-key.pem'],path
    return {'kind':'file','sha256':preserve(path),'bytes':path.stat().st_size,'mode':mode}
def tree(label,origin):
    rows={}
    for directory,dirs,files in os.walk(origin,followlinks=False):
        parent=Path(directory)
        for name in list(dirs):
            p=parent/name;rows[str(p.relative_to(origin))]=row(p)
            if p.is_symlink():dirs.remove(name)
        for name in files:
            p=parent/name;rows[str(p.relative_to(origin))]=row(p)
    groups[label]=rows;origins[label]={'root':str(origin),'scope':'complete tree without following directory symlinks'}
def selected(label,origin,paths):
    rows={}
    for p in sorted(paths):
        relative=p.relative_to(origin);rows[str(relative)]=row(p)
        for parent in relative.parents:
            if str(parent)!='.':rows[str(parent)]=row(origin/parent)
    groups[label]=rows;origins[label]={'root':str(origin),'scope':'selected explicitly listed nonprivate evidence/input files; parents included'}
tree('engine-final-source-generated-output',TASK/'builds/engine01')
tree('engine-baseline-patched-binaries-and-exact-patch',TASK/'artifacts/engine')
for label in ['private01','display-observer01','display-observer02']:tree('client-'+label+'-stage',TASK/'artifacts'/('client-'+label))
tree('native-toolchain-captured-provider',TASK/'artifacts/toolchain-inputs01')
tree('scons-tool',TASK/'cache/tools/scons-4.11.1')
for number in ['01','02']:tree('display-inventory-'+number+'-build',TASK/'builds'/('display-inventory'+number))
selected('downloaded-primary-inputs',TASK/'downloads',[p for p in (TASK/'downloads').iterdir() if p.is_file() and not p.name.endswith('.receipt.json')])
tree('sanitized-download-provenance',TASK/'artifacts/download-provenance')
selected('root-receipts',TASK,[TASK/'storage-verification.json',TASK/'artifacts/source-baseline-receipt.json'])
selected('executed-driver-source-copies',TASK/'private/runs',[p for p in (TASK/'private/runs').glob('*/driver-inputs/*') if p.is_file()])
coord=root/'_build/godot-m4-r2-coordinator-20261029'
selected('independent-coordination-inputs',coord,[p for p in coord.iterdir() if p.is_file() and (re.fullmatch(r'(?:vr-.*-(?:35|36|36-corrected|37|38)|verify-vr-.*-(?:35|36|37|38))\.(?:json|py)',p.name) or p.name in ['progress-check-32.json','progress-check-33.json'])])
write(boundary/'object-groups.json',groups);write(boundary/'object-group-origins.json',origins);write(boundary/'object-storage.json',stored)
engine_original=load(TASK/'builds/engine01/original-source-manifest.json')
classification={'engine_original_authored_paths':['godot-4.7.2-stable/'+r['path'] for r in engine_original],
    'engine_only_original_input_deltas':load(TASK/'artifacts/engine/patch01/manifest.json'),
    'engine_generated_output_paths':sorted(set(groups['engine-final-source-generated-output'])-{'godot-4.7.2-stable/'+r['path'] for r in engine_original}),
    'toolchain_capture':'Captured provider contains76047 original path/mode rows and actual deduplicated bytes; conservative default includes plus SCons observed graph. Reconstructed provider storage is not an OS image or relocated runnable sysroot.',
    'clients':{label:load(ev/'inputs'/('client-'+label+'-manifest.json')) for label in ['private01','display-observer01','display-observer02']},
    'private_exclusions':['raw stdout/stderr/API/stacks','Steam calibration/private state','active keys/profiles/stores/credentials','raw signed download redirect receipts'],
    'baseline_intermediates':'Unpatched baseline binary and original source retained; two native object files were later replaced by incremental patched build. Separate complete baseline intermediate tree not claimed.'}
write(boundary/'input-output-classification.json',classification)
write(boundary/'qualification.json',load(ev/'qualification.json'))
print(json.dumps({'objects_retained':len(stored),'groups':len(groups),'source_entries':len(source),'new_source_entries':len(additions)}),flush=True)

# Apply the real additive tar to the single actual cross-filesystem baseline.
scratch=TASK/'builds/complete-source-materialization01';transfer=load(TASK/'artifacts/source-baseline-receipt.json')
assert transfer['source_entries']==len(old) and transfer['new_materialization']==str(scratch)
assert subprocess.run(['git','rev-parse','--show-toplevel'],cwd=scratch,capture_output=True).returncode!=0
for name,value in old.items():
    path=scratch/name
    if value['kind']=='file':assert not path.is_symlink() and h(path)==value['sha256'] and path.stat().st_mode&0o7777==value['mode'],name
    else:assert path.is_symlink() and str(path.readlink())==value['target'],name
with tarfile.open(boundary/'additions.tar','r:') as archive:
    for member in archive:
        relative=PurePosixPath(member.name);assert not relative.is_absolute() and '..' not in relative.parts and str(relative) in additions
        path=scratch/str(relative);assert not path.exists() and not path.is_symlink()
        path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        if member.issym():path.symlink_to(member.linkname)
        else:
            assert member.isfile()
            with path.open('xb') as output:shutil.copyfileobj(archive.extractfile(member),output)
            path.chmod(member.mode)
for name,mode in sorted(directories.items(),key=lambda r:len(PurePosixPath(r[0]).parts),reverse=True):(scratch/name).chmod(mode)
actual={};actualdirs={}
for directory,dirs,files in os.walk(scratch,followlinks=False):
    parent=Path(directory)
    for name in list(dirs):
        p=parent/name
        if p.is_symlink():files.append(name);dirs.remove(name)
        else:actualdirs[str(p.relative_to(scratch))]=p.stat().st_mode&0o7777
    for name in files:actual[str((parent/name).relative_to(scratch))]=parent/name
assert set(actual)==set(source) and actualdirs==directories,'Complete source path/directory-mode mismatch'
for name,value in source.items():
    path=actual[name]
    if value['kind']=='file':assert not path.is_symlink() and h(path)==value['sha256'] and path.stat().st_size==value['bytes'] and path.stat().st_mode&0o7777==value['mode'],name
    else:assert path.is_symlink() and str(path.readlink())==value['target'] and path.lstat().st_mode&0o7777==symlink_modes[name],name
write(boundary/'independent-source-reconstruction.json',{'passed':True,'method':'Actual previous full3GB source byte copies across filesystems, exact real additive-tar extraction, independent COMPLETE path/content/link/file+directory+symlink modes check. No cross-device hardlinks or symbolic-copy claims.',
    'materialization':str(scratch),'outside_every_checkout':True,'entries':len(source),'directories':len(directories),'previous_entries_actually_copied':len(old),'additions_applied':len(additions),'previous_base_binary_patch_application':'Exact previously independently verified original base/binary-patch reconstruction reused. This is a new actual full source copy+delta proof, not another base extraction/git-apply claim.'})
command=[sys.executable,str(ev/'verify_materialize.py'),str(boundary),str(TASK/'builds/vr-boundary01-materialized-groups'),str(boundary/'independent-object-reconstruction.json')]
assert subprocess.run(command,cwd=root,env=environment()).returncode==0
assert tracked==names('ls-files','--cached') and untracked==names('ls-files','--others','--exclude-standard')
assert git('diff','--binary','HEAD')==patch and not git('diff','--cached','--name-only') and not vive.active_runtime_processes()
for name,value in source.items():
    p=root/name
    if value['kind']=='file':assert h(p)==value['sha256'] and p.stat().st_mode&0o7777==value['mode'],name
    else:assert p.is_symlink() and str(p.readlink())==value['target'],name
artifacts={str(p.relative_to(boundary)):{'sha256':h(p),'bytes':p.stat().st_size} for p in boundary.rglob('*') if p.is_file()}
write(boundary/'snapshot.json',{'checkpoint':'QUO-65 private Vive environment/engine investigation','worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','artifacts':artifacts,'source_entries':len(source),'source_additions':len(additions),'new_object_count':len(stored),'source_reconstruction_verified':True,'object_group_full_reconstruction_verified':True,'old_boundary_immutable_reference':str(prior),'private_diagnostics_excluded':True,'production_changes':0,'full_M4_accepted':False,'writer_idle_frozen':True})
for p in boundary.rglob('*'):
    if p.is_file() and p.stat().st_mode&0o222:p.chmod(0o444)
for p in sorted([p for p in boundary.rglob('*') if p.is_dir()],key=lambda p:len(p.parts),reverse=True):p.chmod(0o555)
boundary.chmod(0o555)
print(json.dumps({'frozen':True,'boundary':str(boundary),'snapshot_sha256':h(boundary/'snapshot.json'),'tracked_patch_sha256':h(boundary/'tracked.patch'),'additions_sha256':h(boundary/'additions.tar'),'source_entries':len(source),'source_additions':len(additions),'artifacts':len(artifacts),'new_object_count':len(stored),'group_entries':{label:len(rows) for label,rows in groups.items()}}),flush=True)
