"""Additive source/object freeze; no product execution or old bulk recount."""
import hashlib,json,os,shutil,signal,subprocess,sys,tarfile,time
from pathlib import Path,PurePosixPath
from environment import TASK,environment
from digests import Digests,key,raw,SOURCES
root=Path.cwd();ev=Path(__file__).resolve().parent
prior=TASK/'artifacts/quod-godot-m4-vr-handoff-ca84d4f8-20261029-02'
older=TASK/'artifacts/quod-godot-m4-vr-handoff-ca84d4f8-20261029-01'
boundary=TASK/'artifacts/quod-godot-m4-vive-physical-handoff-ca84d4f8-20261029-01'
def load(p):return json.loads(Path(p).read_text())
def write(p,v):Path(p).write_text(json.dumps(v,indent=2)+'\n')
def git(*args):return subprocess.check_output(['git',*args],cwd=root)
def names(*args):return set(filter(None,git(*args,'-z').decode().split('\0')))
if sys.argv[1:]!=['--child']:
    os.umask(0o077);runs=TASK/'artifacts/vive-physical-freeze-runs01';runs.mkdir(mode=0o700,exist_ok=False)
    copies=runs/'driver-inputs';copies.mkdir(mode=0o700)
    for p in ev.iterdir():
        if p.is_file() and p.suffix in ['.py','.cs','.erl']:shutil.copy2(p,copies/p.name)
    cmd=[sys.executable,str(Path(__file__).resolve()),'--child'];started=time.time();timeout=False
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
parents=[]
for path,expected in [(prior,'ecddd5be576a0062afc5f88ad565c0bc2cec54250a721f40ce7e58cb1a650933'),(older,'5af20d5f7b168c53f2eab7d4524862a9db2957169a66879d29b0bdd23ad817fe')]:
    assert h(path/'snapshot.json')==expected
    descriptor=load(path/'snapshot.json');actual={str(p.relative_to(path)):p for p in path.rglob('*') if p.is_file()}
    assert set(actual)==set(descriptor['artifacts'])|{'snapshot.json'}
    for n,r in descriptor['artifacts'].items():assert actual[n].stat().st_size==r['bytes'] and actual[n].stat().st_mode&0o222==0
    parents.append((path,descriptor))
assert git('branch','--show-current').decode().strip()=='worktree/pearl-stone'
assert git('rev-parse','HEAD').decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert not git('diff','--cached','--name-only')
patch=git('diff','--binary','HEAD');assert patch==(prior/'tracked.patch').read_bytes()
assert hashlib.sha256(patch).hexdigest()=='c0f9395a9b8fe09abcd71aa13ec9917aae9241bf307a5fc4b0af07e0baa4f998'
assert h(root/'client/godot/Main.cs')=='e9c010f71a9c1369fd5b451fe1d7fa275948089b3a96e69fe6d8f21b543fec1e'
assert load(ev/'acceptance.json')['full_m4_accepted'] is False
for label in ['native-vive-product03','native-vive-product05']:
    r=load(ev/label/'result.json');assert r['client_exit']==r['runtime_exit']==r['server_exit']==0 and all(r['eof'].values()) and not r['runtime_processes_after']
    assert not any(c.get('diagnostic_instruction') in ['sample','gui-check'] for c in r['commands'])
tracked=names('ls-files','--cached');untracked=names('ls-files','--others','--exclude-standard');source={};dirs={};links={}
for n in sorted(tracked|untracked):
    p=root/n;mode=p.lstat().st_mode&0o7777
    if p.is_symlink():source[n]={'kind':'symlink','target':str(p.readlink()),'tracked':n in tracked};links[n]=mode
    else:assert p.is_file();source[n]={'kind':'file','sha256':h(p),'bytes':p.stat().st_size,'mode':mode,'tracked':n in tracked}
    for parent in PurePosixPath(n).parents:
        if str(parent)!='.':dirs[str(parent)]=(root/str(parent)).stat().st_mode&0o7777
old=load(prior/'source-manifest.json');assert all(source.get(n)==r for n,r in old.items()),'A previously frozen source path changed'
additions=sorted(set(source)-set(old));assert additions
allowed=('doc/evidence/godot-m4-vive-physical-20261029/','doc/evidence/godot-m4-r2-coordinator-20261029/')
assert all(n.startswith(allowed) or n in ['nimbalyst-local/handoffs/godot-m4-vive-physical-prompt.md','nimbalyst-local/handoffs/godot-m4-vive-physical-result.md'] for n in additions),additions
boundary.mkdir(mode=0o700);(boundary/'objects').mkdir()
write(boundary/'source-manifest.json',source);write(boundary/'source-directory-modes.json',dirs);write(boundary/'source-symlink-modes.json',links);(boundary/'tracked.patch').write_bytes(patch)
write(boundary/'source-status.json',{'head':'293cf6115c0a6b18315eccdbb42cbca396f443d3','branch':'worktree/pearl-stone','index_empty':True,'source_entries':len(source),'previous_entries':len(old),'new_additions':additions,'changed_previous_paths':[],'generated_agents':sum(n.startswith('.agents/') for n in untracked),'production_test_spec_changes':0,'implementation_writer_frozen':True,'custom_question37_pending':True,'session_turn_completion_not_inferred':True})
with tarfile.open(boundary/'additions.tar','x:') as archive:
    for n in additions:archive.add(root/n,arcname=n,recursive=False)
write(boundary/'previous-boundary-reference.json',{'path':str(prior),'snapshot_sha256':h(prior/'snapshot.json'),'previous_full_source':str(TASK/'builds/coordinator-source-reconstruction-40'),'scope':'Actual prior base/binary HEAD patch/full untracked bytes and complete independently verified reconstruction retained recursively. New real additions.tar, not a hash-only source snapshot. Prior readonly path/size/modes checked without bulk old byte recount.'})
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
for label in ['physical01','physical02']:tree('source-only-client-'+label,TASK/'artifacts'/('client-'+label))
selected={};paths={}
for directory in sorted((TASK/'private/runs').iterdir()):
    if (directory/'driver-inputs').is_dir() and (ev/'logs'/(directory.name+'.json')).exists():
        for p in (directory/'driver-inputs').iterdir():
            if p.is_file():n=directory.name+'--'+p.name;selected[n]=row(p);paths[n]=str(p)
for label in ['native-vive-product01','native-vive-product02','native-vive-product03','native-vive-product04','native-vive-product05']:
    for p in (TASK/'private'/label/'drivers').iterdir():
        if p.is_file():n=label+'--'+p.name;selected[n]=row(p);paths[n]=str(p)
for p in (TASK/'artifacts/vive-physical-freeze-runs01/driver-inputs').iterdir():
    if p.is_file():n='freeze01--'+p.name;selected[n]=row(p);paths[n]=str(p)
groups['actual-executed-diagnostic-drivers']=selected;origins['actual-executed-diagnostic-drivers']=paths
coord=root/'_build/godot-m4-r2-coordinator-20261029';selected={};paths={}
for p in coord.iterdir():
    if p.is_file() and p.suffix in ['.json','.py','.stdout','.stderr','.log'] and any(remainder in p.name for remainder in ['-40','-42','-43','-44','-45','-46','-48','-49']):
        selected[p.name]=row(p);paths[p.name]=str(p)
groups['independent-coordinator-inputs']=selected;origins['independent-coordinator-inputs']=paths
selected={};paths={}
for i,(p,digest) in enumerate(SOURCES):selected[str(i)+'-'+p.name]=row(p);paths[str(i)+'-'+p.name]=str(p)
groups['verified-stat-cache-inputs']=selected;origins['verified-stat-cache-inputs']=paths
write(boundary/'object-groups.json',groups);write(boundary/'object-group-origins.json',origins);write(boundary/'object-storage.json',stored)
write(boundary/'input-output-classification.json',{'supplied_inputs':'Each source-only-client group supplies paths listed by its retained client manifest; one qualification dispatcher override+PhysicalChecks.cs;91 existing inputs unchanged.','dependencies':'Exact pinned toolchain/package archives/provider bytes reused by prior immutable graph; stage packages are cold-restore/generated dependencies, not copied compiled application inputs.','generated_outputs':'All remaining stage build/restore/export outputs and receipts explicitly captured, including196 exports each.','new_products':0,'source_relocation':0,'privacy_exclusions':'No active identity/store, credentials, original/private calibration, raw runtime/client/API/stacks copied. Sanitized complete logs/receipts are public source inputs; restricted raw bytes remain at recorded private paths.','raw_new_diagnostics':'Exact actual files/modes/digests retained privately and independently verified by root46/49; not converted to public objects.'})
print(json.dumps({'source_entries':len(source),'source_additions':len(additions),'new_object_groups':{k:len(v) for k,v in groups.items()},'objects':len(stored)}),flush=True)
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
write(boundary/'snapshot.json',{'checkpoint':'QUO-65 deferred physical preparation and retirement','worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','actual_model':'openai-codex:gpt-6.1-sol','launcher_effort':'max','backend_effective_effort':'unexposed','artifacts':artifacts,'previous_boundary':str(prior),'previous_snapshot_sha256':h(prior/'snapshot.json'),'source_entries':len(source),'source_additions':len(additions),'source_and_groups_actually_reconstructed':True,'implementation_writer_frozen':True,'custom_question37_pending':True,'session_turn_complete':False,'physical_acceptance':'UNRUN charging/deferred','full_m4_accepted':False})
for p in boundary.rglob('*'):
    if p.is_file() and p.stat().st_mode&0o222:p.chmod(0o444)
for p in sorted([p for p in boundary.rglob('*') if p.is_dir()],key=lambda p:len(p.parts),reverse=True):p.chmod(0o555)
boundary.chmod(0o555)
print(json.dumps({'frozen':True,'boundary':str(boundary),'snapshot_sha256':raw(boundary/'snapshot.json'),'additions_sha256':raw(boundary/'additions.tar'),'source_entries':len(source),'source_additions':len(additions),'artifacts':len(artifacts),'objects':len(stored),'prior_readonly_objects_reused':sum(r['method'].startswith('verified') for r in stored.values()),'source_materialization':str(TASK/'builds/vive-physical-source-reconstruction01'),'group_materialization':str(TASK/'builds/vive-physical-group-reconstruction01'),'cache_hits':d.hits,'new_hashes':d.new,'new_bytes_hashed':d.bytes}),flush=True)
