#!/usr/bin/env python3
"""Freeze only additive observation bytes; share the verified3GB source baseline."""
import hashlib,json,os,shutil,signal,subprocess,sys,tarfile,time
from pathlib import Path,PurePosixPath

root=Path.cwd();ev=Path(__file__).resolve().parent
cache=Path('/home/yan/.cache/quod-m4-observation1-artifacts')
prior=Path('/home/yan/.cache/quod-m4-r2-artifacts/quod-godot-m4-r2-handoff-ca84d4f8-20261029-02')
baseline=prior.parent/(prior.name+'-complete-reconstruction')
boundary=cache/'quod-godot-m4-observation1-handoff-ca84d4f8-20261029-01'
def h(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def write(path,value):path.write_text(json.dumps(value,indent=2)+'\n')
def git(*args):return subprocess.check_output(['git',*args],cwd=root)
def names(*args):return set(filter(None,git(*args,'-z').decode().split('\0')))

if sys.argv[1:]!=['--child']:
    runs=cache/'freeze-runs';runs.mkdir(mode=0o700,exist_ok=False)
    log=runs/'freeze01.log';receipt=runs/'freeze01.json'
    command=['python3',str(Path(__file__).resolve()),'--child'];started=time.time();timeout=False
    env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1');env.pop('LD_LIBRARY_PATH',None);env.pop('LD_PRELOAD',None)
    with log.open('xb') as output:
        child=subprocess.Popen(command,cwd=root,env=env,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        try:status=child.wait(timeout=900)
        except subprocess.TimeoutExpired:
            timeout=True;os.killpg(child.pid,signal.SIGTERM)
            try:status=child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid,signal.SIGKILL);status=child.wait()
    log.chmod(0o600);summary=None
    for line in log.read_text().splitlines():
        if line.startswith('{'):
            value=json.loads(line)
            if value.get('frozen'):summary=value
    result={'command':command,'cwd':str(root),'true_child_exit':status,'timed_out':timeout,
        'elapsed_seconds':time.time()-started,'explicit_completion':summary is not None,
        'passed':status==0 and not timeout and summary is not None,'log':str(log),'log_sha256':h(log),'summary':summary}
    write(receipt,result);receipt.chmod(0o600);print(json.dumps(result));sys.exit(0 if result['passed'] else 1)

assert not boundary.exists(),'Preserve existing boundaries'
assert h(prior/'snapshot.json')=='2ca34fc60549e753b0bebdb64fe863c4e37feffd76fede9e92837dfd63eeafa4'
assert git('rev-parse','HEAD').decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert git('branch','--show-current').decode().strip()=='worktree/pearl-stone' and not git('diff','--cached','--name-only')
assert git('diff','--binary','HEAD')==(prior/'tracked.patch').read_bytes()
qualification=json.loads((ev/'qualification.json').read_text())
assert qualification['desktop_observations']==1 and qualification['production_changes']==0 and qualification['marker_count']==1
tracked=names('ls-files','--cached');untracked=names('ls-files','--others','--exclude-standard');source={}
for name in sorted(tracked|untracked):
    path=root/name
    if path.is_symlink():source[name]={'kind':'symlink','target':str(path.readlink()),'tracked':name in tracked}
    elif path.is_file():
        assert not path.stat().st_mode&0o7000,name
        source[name]={'kind':'file','sha256':h(path),'bytes':path.stat().st_size,'mode':path.stat().st_mode&0o7777,'tracked':name in tracked}
old=json.loads((prior/'source-manifest.json').read_text())
assert all(source[name]==row for name,row in old.items()),'A previous source byte/link/mode changed'
additions=sorted(set(source)-set(old));assert additions
assert all(name.startswith('doc/evidence/godot-m4-observation1-20261029/') or name=='nimbalyst-local/handoffs/godot-m4-observation1-result.md' for name in additions),additions
boundary.mkdir(mode=0o700);objects=boundary/'objects';objects.mkdir()
descriptor=json.loads((prior/'snapshot.json').read_text());shared={}
expected=set(descriptor['artifacts'])|{'snapshot.json'}
assert {str(p.relative_to(prior)) for p in prior.rglob('*') if p.is_file()}==expected
for name in sorted(expected):
    original=prior/name;target=boundary/'previous'/name
    assert original.stat().st_mode&0o222==0 and original.is_file() and not original.is_symlink()
    target.parent.mkdir(mode=0o700,parents=True,exist_ok=True);os.link(original,target)
    left=original.stat();right=target.stat()
    assert (left.st_dev,left.st_ino,left.st_mode,left.st_size)==(right.st_dev,right.st_ino,right.st_mode,right.st_size)
    shared[name]={'sha256':h(original) if name=='snapshot.json' else descriptor['artifacts'][name]['sha256'],'bytes':left.st_size}
write(boundary/'source-manifest.json',source)
write(boundary/'source-status.json',{'head':git('rev-parse','HEAD').decode().strip(),'parent':git('rev-parse','HEAD^').decode().strip(),
    'branch':'worktree/pearl-stone','index_empty':True,'production_changes':0,'previous_source_entries':len(old),
    'source_entries':len(source),'additions':additions,'changed_prior_source_entries':[],
    'generated_agents_files':sum(n.startswith('.agents/') for n in untracked),'committed':False,'writer_idle_frozen':True})
with tarfile.open(boundary/'additions.tar','x:') as archive:
    for name in additions:archive.add(root/name,arcname=name,recursive=False)
write(boundary/'unchanged-artifact-reuse.json',{'previous_boundary':str(prior),'previous_snapshot_sha256':h(prior/'snapshot.json'),
    'actual_read_only_hardlinks':shared,'method':'Exact previous artifact path set; identical device/inode/size/full mode for each shared actual byte file. Existing hashes/qualification reused, not another old-artifact rehash or test rerun.',
    'no_source_compression_or_deletion':True,'no_3gb_baseline_copy':True})

groups={};origins={};stored={}
def preserve(path):
    sha=h(path)
    if sha not in stored:
        previous=prior/'objects'/sha;target=objects/sha
        if previous.exists():
            assert previous.stat().st_mode&0o222==0 and descriptor['artifacts']['objects/'+sha]['sha256']==sha
            os.link(previous,target);stored[sha]='same verified immutable previous object inode'
        else:
            shutil.copyfile(path,target);assert h(target)==sha;target.chmod(0o444);stored[sha]='new actual bytes copied and independently hashed'
    return sha
def row(path):
    mode=path.lstat().st_mode&0o7777
    if path.is_symlink():
        value={'kind':'symlink','target':str(path.readlink()),'mode':mode}
        if path.is_file():value['resolved_sha256']=preserve(path)
        return value
    if path.is_dir():return {'kind':'directory','mode':mode}
    assert path.is_file() and path.name not in ['active.json','writer.lock','tls-key.pem','proxy-key.pem']
    return {'kind':'file','sha256':preserve(path),'bytes':path.stat().st_size,'mode':mode}
def tree(label,origin):
    rows={}
    for directory,dirs,files in os.walk(origin,followlinks=False):
        parent=Path(directory)
        for name in list(dirs):
            path=parent/name;rows[str(path.relative_to(origin))]=row(path)
            if path.is_symlink():dirs.remove(name)
        for name in files:
            path=parent/name;rows[str(path.relative_to(origin))]=row(path)
    groups[label]=rows;origins[label]={'root':str(origin),'scope':'complete-tree-without-following-directory-symlinks'}
tree('diagnostic-client-stage',cache/'client-quit-marker01')
tree('account-preparation-provider',cache/'account-preparation-tool')
private=cache/'private';providers={}
for owner in private.glob('quod-m4-live-*'):
    for path in list(owner.glob('*.erl'))+list((owner/'ebin').glob('*.beam'))+list((owner/'predicates-ebin').glob('*.beam')):
        providers[str(path.relative_to(private))]=row(path)
groups['fixture-provider-code']=providers;origins['fixture-provider-code']={'root':str(private),'scope':'selected fixture .erl/.beam code only; private credentials/stores excluded'}
write(boundary/'object-groups.json',groups);write(boundary/'object-group-origins.json',origins)
write(boundary/'object-reuse.json',stored)
write(boundary/'qualification.json',qualification)

# Reuse actual independently reconstructed baseline bytes, never write/chmod them.
# Extract the real uncompressed source additions and verify the COMPLETE result.
scratch=cache/(boundary.name+'-complete-reconstruction');scratch.mkdir(mode=0o700)
assert subprocess.run(['git','rev-parse','--show-toplevel'],cwd=scratch,capture_output=True).returncode!=0
for name,value in old.items():
    original=baseline/name;target=scratch/name;target.parent.mkdir(parents=True,exist_ok=True)
    if value['kind']=='symlink':
        assert original.is_symlink() and str(original.readlink())==value['target'];target.symlink_to(value['target'])
    else:
        assert h(original)==value['sha256'] and original.stat().st_mode&0o7777==value['mode'],name
        os.link(original,target)
with tarfile.open(boundary/'additions.tar','r:') as archive:
    for member in archive:
        name=PurePosixPath(member.name);assert not name.is_absolute() and '..' not in name.parts and str(name) in additions
        target=scratch/str(name);target.parent.mkdir(parents=True,exist_ok=True)
        assert not target.exists() and not target.is_symlink()
        if member.issym():target.symlink_to(member.linkname)
        else:
            assert member.isfile()
            with target.open('xb') as output:shutil.copyfileobj(archive.extractfile(member),output)
            target.chmod(member.mode)
actual={}
for directory,dirs,files in os.walk(scratch,followlinks=False):
    parent=Path(directory)
    for name in list(dirs):
        if (parent/name).is_symlink():files.append(name);dirs.remove(name)
    for name in files:actual[str((parent/name).relative_to(scratch))]=parent/name
assert set(actual)==set(source)
for name,value in source.items():
    path=actual[name]
    if value['kind']=='symlink':assert path.is_symlink() and str(path.readlink())==value['target'],name
    else:assert h(path)==value['sha256'] and path.stat().st_size==value['bytes'] and path.stat().st_mode&0o7777==value['mode'],name
write(boundary/'independent-reconstruction.json',{'method':'Exact previously materialized baseline verified and hardlinked, actual uncompressed addition archive extraction, independently checked full resulting path set/content/link/full modes',
    'workspace':str(scratch),'outside_every_checkout':True,'entries':len(source),'baseline_entries_shared':len(old),'additions_applied':len(additions),
    'every_content_link_and_full_mode_verified':True,'baseline_bytes_not_copied':True,
    'previous_base_binary_patch_application':'Reused exact previous immutable full reconstruction and its receipt; not claimed as another fresh base extraction/git-apply run'})
print('Complete source reconstruction delta passed',flush=True)
assert subprocess.run(['python3',str(boundary/'previous/verify-objects.py'),str(boundary)]).returncode==0
materialized_bytes=sum(row.get('bytes',0) for label,rows in groups.items() if label!='fixture-provider-code' for row in rows.values())
assert shutil.disk_usage(cache).free>materialized_bytes+100_000_000,'Preserve capacity; do not delete data to force materialization'
for label in ['diagnostic-client-stage','account-preparation-provider']:
    target=cache/(boundary.name+'-'+label+'-materialization')
    assert subprocess.run(['python3',str(boundary/'previous/materialize-group.py'),str(boundary),label,str(target),str(boundary/('independent-'+label+'-materialization.json'))]).returncode==0
assert tracked==names('ls-files','--cached') and untracked==names('ls-files','--others','--exclude-standard')
assert git('diff','--binary','HEAD')==(prior/'tracked.patch').read_bytes()
for name,value in source.items():
    path=root/name
    if value['kind']=='symlink':assert path.is_symlink() and str(path.readlink())==value['target']
    else:assert h(path)==value['sha256'] and path.stat().st_mode&0o7777==value['mode'],name
artifacts={'previous/'+name:value for name,value in shared.items()}
for path in boundary.rglob('*'):
    if not path.is_file() or path.is_relative_to(boundary/'previous'):continue
    artifacts[str(path.relative_to(boundary))]={'sha256':h(path),'bytes':path.stat().st_size}
write(boundary/'snapshot.json',{'checkpoint':'QUO-65 observation1','worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','artifacts':artifacts,
    'source_entries':len(source),'source_reconstruction_delta_verified':True,'outputs_and_provider_objects_verified':True,
    'no_source_compression_or_deletion':True,'full_m4_accepted':False})
for path in boundary.rglob('*'):
    if path.is_file() and path.stat().st_mode&0o222:path.chmod(0o444)
for path in sorted([p for p in boundary.rglob('*') if p.is_dir()],key=lambda p:len(p.parts),reverse=True):path.chmod(0o555)
boundary.chmod(0o555)
print(json.dumps({'boundary':str(boundary),'snapshot_sha256':h(boundary/'snapshot.json'),
    'additions_sha256':h(boundary/'additions.tar'),'source_entries':len(source),'source_additions':len(additions),
    'prior_source_entries_shared':len(old),'artifacts':len(artifacts),'new_and_reused_objects':len(stored),
    'new_objects':sum(value.startswith('new ') for value in stored.values()),'frozen':True}))
