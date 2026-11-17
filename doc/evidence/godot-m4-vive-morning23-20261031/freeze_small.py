"""Seal only new case22/23 evidence and the one inherited launcher delta."""
import hashlib,importlib.util,json,os,shutil,stat,subprocess,sys,tarfile,time
from pathlib import Path,PurePosixPath
os.umask(0o077);sys.dont_write_bytecode=True
root=Path.cwd();ev=Path(__file__).resolve().parent;task=Path('/data/quod-m4-vr-ca84d4f8-20261029')
parent=task/'artifacts/quod-godot-m4-morning-journey-handoff-ca84d4f8-20261031-01'
boundary=task/'artifacts/quod-godot-m4-morning23-handoff-ca84d4f8-20261031-02'
runs=task/'artifacts/morning23-freeze-runs02'
def raw(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def load(p):return json.loads(p.read_text())
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def git(*a):return subprocess.check_output(['git',*a],cwd=root)
def inventory():return set(filter(None,git('ls-files','--cached','--others','--exclude-standard','-z').decode().split('\0')))
if sys.argv[1:]!=['--child']:
    assert not sys.argv[1:];runs.mkdir(mode=0o700,exist_ok=False);copies=runs/'driver-inputs';copies.mkdir()
    for p in ev.glob('*.py'):shutil.copy2(p,copies/p.name)
    command=[sys.executable,'-B',str(Path(__file__).resolve()),'--child'];started=time.monotonic()
    with (runs/'stdout.raw').open('xb') as out,(runs/'stderr.raw').open('xb') as err:r=subprocess.run(command,stdout=out,stderr=err,timeout=120)
    completion=None
    for line in (runs/'stdout.raw').read_text().splitlines():
        if line.startswith('{'):
            value=json.loads(line)
            if value.get('frozen'):completion=value
    result={'command':command,'true_child_exit':r.returncode,'explicit_completion':completion is not None,'elapsed_seconds':time.monotonic()-started,'passed':r.returncode==0 and completion is not None,'summary':completion,'streams':{k:{'path':str(runs/(k+'.raw')),'sha256':raw(runs/(k+'.raw')),'bytes':(runs/(k+'.raw')).stat().st_size} for k in ['stdout','stderr']}}
    write(runs/'result.json',result);print(json.dumps(result));raise SystemExit(0 if result['passed'] else 1)
assert not boundary.exists() and raw(parent/'snapshot.json')=='bf4b7235f3c9b923bbd7780a7a956540a5c18bedeb3e41870ad406eac82094f5'
assert git('rev-parse','HEAD').decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert git('branch','--show-current').decode().strip()=='worktree/pearl-stone' and not git('diff','--cached','--name-only') and not git('diff','--check')
cache=root/'_build/godot-m4-r2-coordinator-20261029/morning-seal-hashes-144-corrected.json'
assert raw(cache)=='41a1830a49eaf1ffc3e05ab03ac770872966e8dc79b68127fa5d6e2a8ec09f08'
digests={tuple(r['stat_key']):r['sha256'] for r in load(cache)['records']};used=set()
def key(p):
    s=p.stat();return (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
def h(p):
    k=key(p);used.add(k)
    if k not in digests:digests[k]=raw(p)
    return digests[k]
def row(p):
    mode=stat.S_IMODE(p.lstat().st_mode)
    if p.is_symlink():return {'kind':'symlink','target':str(p.readlink()),'mode':mode}
    if p.is_dir():return {'kind':'directory','mode':mode}
    assert p.is_file() and p.name!='api-dump.raw'
    return {'kind':'file','sha256':h(p),'bytes':p.stat().st_size,'mode':mode}
refs=load(parent/'previous-boundary-references.json')['parents']
assert raw(parent/'previous-boundary-references.json')==load(parent/'snapshot.json')['artifacts']['previous-boundary-references.json']['sha256']
refs=refs+[{'path':str(parent),'snapshot_sha256':raw(parent/'snapshot.json'),'source_index':'delta-source-manifest.json'}]
old={}
for ref in refs:old.update(load(Path(ref['path'])/ref['source_index']))
current=inventory();assert set(old)<=current
changed=['doc/evidence/godot-m4-morning-journey-20261031/launch.py'];additions=sorted(current-set(old))
allowed=('doc/evidence/godot-m4-vive-morning22-20261031/','doc/evidence/godot-m4-vive-morning23-20261031/','doc/evidence/godot-m4-vive-physical-20261029/logs/morning-launch-argv01-run')
generated={'doc/evidence/godot-m4-vive-physical-20261029/inputs/'+n for n in ['native-vive-product23-server-godot_m3b_fixture.erl','native-vive-product23-server-godot_m3b_physics_fixture.erl','native-vive-product23-server-serve.py','server-native-vive-product23-server.json']}
assert all(n.startswith(allowed) or n in generated or n=='nimbalyst-local/handoffs/godot-m4-morning23-result-144.md' for n in additions),additions
assert sum(n.startswith('.agents/') for n in current)==31
q=load(ev/'result.json');assert q['closure_passed'] and not q['physical_journey_accepted']
before_path=Path(q['source_delta']['before_path']);before={k:v for k,v in old[changed[0]].items() if k!='tracked'}
assert row(before_path)==before and h(root/changed[0])==q['source_delta']['after_sha256']!=before['sha256']
assert row(ev/'record.py')==row(task/'private/morning23-record01/record.py')
names=sorted(changed+additions);source={n:row(root/n) for n in names};directories={}
for n in names:
    for p in PurePosixPath(n).parents:
        if str(p)!='.':directories[str(p)]=stat.S_IMODE((root/str(p)).stat().st_mode)
tracked=git('diff','--binary','HEAD');boundary.mkdir(mode=0o700);(boundary/'objects').mkdir()
write(boundary/'delta-source-manifest.json',source);write(boundary/'changed-before-manifest.json',{changed[0]:before});write(boundary/'delta-directory-modes.json',directories)
write(boundary/'previous-boundary-references.json',{'parents':refs,'logical_parent_paths':len(old),'full_inherited_source_reconstructed':False,'accepted_root_delta':'coordinator-morning-delta-reconstruction-144','authenticated_root144_cache':{'path':str(cache),'sha256':raw(cache)},'unchanged_inherited_source_bytes_audited':0,'changed_before_file_verified':True})
work=runs/'patch-inputs';(work/'before').mkdir(parents=True);(work/'after').mkdir()
p=work/'before'/changed[0];p.parent.mkdir(parents=True);shutil.copy2(before_path,p);assert p.stat().st_ino!=before_path.stat().st_ino
for n in names:
    p=work/'after'/n;p.parent.mkdir(parents=True,exist_ok=True)
    if (root/n).is_symlink():p.symlink_to((root/n).readlink())
    else:shutil.copy2(root/n,p)
diff=subprocess.run(['git','diff','--no-index','--binary','--src-prefix=a/','--dst-prefix=b/','before','after'],cwd=work,capture_output=True);assert diff.returncode==1 and diff.stdout and not diff.stderr
(boundary/'delta.patch').write_bytes(diff.stdout)
with tarfile.open(boundary/'delta-contents.tar','x:') as tar:
    for n in names:tar.add(root/n,arcname=n,recursive=False)
patched=task/'builds/morning23-patch-materialization02';extracted=task/'builds/morning23-tar-materialization02';patched.mkdir(mode=0o700,exist_ok=False);extracted.mkdir(mode=0o700,exist_ok=False)
p=patched/changed[0];p.parent.mkdir(parents=True);shutil.copy2(before_path,p);assert p.stat().st_ino!=before_path.stat().st_ino and row(p)==before
commands=[]
for command in [['git','apply','--check','-p2',str(boundary/'delta.patch')],['git','apply','-p2',str(boundary/'delta.patch')]]:
    r=subprocess.run(command,cwd=patched,capture_output=True);commands.append({'command':command,'true_exit':r.returncode,'stdout':r.stdout.decode(),'stderr':r.stderr.decode()});assert r.returncode==0
with tarfile.open(boundary/'delta-contents.tar') as tar:
    members=tar.getmembers();assert len(members)==len(source) and {m.name for m in members}==set(source)
    for m in members:
        n=PurePosixPath(m.name);assert not n.is_absolute() and '..' not in n.parts
        p=extracted/m.name;p.parent.mkdir(parents=True,exist_ok=True);r=source[m.name]
        if r['kind']=='file':assert m.isfile();p.write_bytes(tar.extractfile(m).read());p.chmod(r['mode'])
        else:assert r['kind']=='symlink' and m.issym() and m.linkname==r['target'];p.symlink_to(m.linkname)
for target in [patched,extracted]:
    for n,r in source.items():
        if r['kind']=='file':(target/n).chmod(r['mode'])
    for n,mode in sorted(directories.items(),key=lambda x:len(PurePosixPath(x[0]).parts),reverse=True):(target/n).chmod(mode)
    assert {str(p.relative_to(target)) for p in target.rglob('*')}==set(source)|set(directories)
    for n,r in source.items():assert row(target/n)==r
    for n,mode in directories.items():assert stat.S_IMODE((target/n).stat().st_mode)==mode
write(boundary/'delta-materialization.json',{'patch_commands':commands,'separate_inherited_copy_before_patch':True,'changed_inherited_paths':changed,'patch_tree':str(patched),'tar_tree':str(extracted),'actual_tar_members':len(source),'full_delta_paths_contents_types_links_modes_checked':True,'full_inherited_source_reconstruction':False})
groups={};origins={};root_modes={};stored={}
def selected(label,origin,paths):
    assert paths and label not in groups;rows={};where={};root_modes[label]=stat.S_IMODE(origin.stat().st_mode)
    for p in paths:
        assert p.is_relative_to(origin) and p.name!='api-dump.raw'
        while p!=origin:
            n=str(p.relative_to(origin));r=row(p)
            if r['kind']=='file':
                dest=boundary/'objects'/r['sha256']
                if not dest.exists():shutil.copyfile(p,dest);assert raw(dest)==r['sha256'];dest.chmod(0o444);stored[r['sha256']]={'bytes':r['bytes'],'storage':'ordinary new copy; original inode unchanged'}
            rows[n]=r;where[n]=str(p);p=p.parent
    groups[label]=rows;origins[label]=where
def files(origin):return sorted(p for p in origin.rglob('*') if p.is_file())
selected('failed22-preserved',task/'private/case22-failure01',files(task/'private/case22-failure01'))
for label in ['morning-launch-argv01','morning23-record01','morning22-23-tool-custody01']:
    origin=task/'private'/label;selected(label,origin,files(origin))
for label in ['morning-launch-argv01-run','native-vive-product23-run']:
    origin=task/'private/runs'/label;selected(label+'-preexecution',origin/'driver-inputs',files(origin/'driver-inputs'));selected(label+'-streams',origin,[origin/'stdout.raw',origin/'stderr.raw'])
prep=task/'private/native-vive-product23-preparation';owners=prep/'unchanged-owners';out=owners/'godot-m4-vive-retest-20261030/native-vive-product23'
selected('case23-preflight',prep,sorted(p for p in prep.iterdir() if p.is_file()))
selected('case23-invocation-owners',owners,sorted(p for p in owners.rglob('*') if p.is_file() and not p.is_relative_to(out) and 'logs' not in p.parts))
selected('case23-owner-publication-private',out,files(out))
origin=task/'private/native-vive-product23';selected('case23-executed-sources',origin/'drivers',files(origin/'drivers'))
selected('case23-private-streams-observations',origin,[origin/n for n in ['server-stdout.raw','server-stderr.raw','runtime-stdout.raw','runtime-stderr.raw','client-stdout.raw','client-stderr.raw','client-result.raw.json','expiry-status01.raw.json']])
fixture=task/'private/quod-m4-live-native-vive-product23-server'
selected('case23-fresh-fixture-code-only',fixture,sorted(p for p in fixture.iterdir() if p.is_file() and p.suffix in ['.erl','.beam']))
selected('freeze-preexecution',runs/'driver-inputs',files(runs/'driver-inputs'))
failed=task/'artifacts/morning23-freeze-runs01';selected('failed-freeze01',failed,files(failed))
# Verify the actual new publications using their unchanged pure publisher.
spec=importlib.util.spec_from_file_location('case23_publication',owners/'godot-m4-vive-physical-20261029/publication.py');publication=importlib.util.module_from_spec(spec);spec.loader.exec_module(publication)
for name in ['server','runtime','client']:
    for kind in ['stdout','stderr']:assert publication.redact_devices((origin/(name+'-'+kind+'.raw')).read_bytes())==(out/(name+'-'+kind+'.log')).read_bytes()
group_tree=task/'builds/morning23-group-materialization02';group_tree.mkdir(mode=0o700,exist_ok=False)
for label,rows in groups.items():
    target=group_tree/label;target.mkdir()
    for n,r in rows.items():
        p=target/n
        if r['kind']=='directory':p.mkdir(parents=True,exist_ok=True)
        elif r['kind']=='file':p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(boundary/'objects'/r['sha256'],p);p.chmod(r['mode'])
        else:p.parent.mkdir(parents=True,exist_ok=True);p.symlink_to(r['target'])
    for n,r in sorted(rows.items(),key=lambda x:len(PurePosixPath(x[0]).parts),reverse=True):
        if r['kind']=='directory':(target/n).chmod(r['mode'])
    target.chmod(root_modes[label]);assert {str(p.relative_to(target)) for p in target.rglob('*')}==set(rows)
    for n,r in rows.items():assert row(target/n)==r and row(Path(origins[label][n]))==r
write(boundary/'object-groups.json',groups);write(boundary/'object-group-origins.json',origins);write(boundary/'group-root-modes.json',root_modes);write(boundary/'object-storage.json',stored)
assert inventory()==current and git('diff','--binary','HEAD')==tracked and not git('diff','--cached','--name-only')
for n,r in source.items():assert row(root/n)==r
write(boundary/'qualification.json',q);write(boundary/'used-stat-digests.json',{'records':[{'stat_key':list(k),'sha256':digests[k]} for k in sorted(used)]})
artifacts={str(p.relative_to(boundary)):{'sha256':raw(p),'bytes':p.stat().st_size} for p in boundary.rglob('*') if p.is_file()}
write(boundary/'snapshot.json',{'worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','checkpoint':'Failed22, launcher argv correction, closed23 and exact usability failure','artifacts':artifacts,'previous_snapshot_sha256':'bf4b7235f3c9b923bbd7780a7a956540a5c18bedeb3e41870ad406eac82094f5','changed_inherited_paths':changed,'new_source_paths':len(additions),'actual_delta_materialized':True,'full_inherited_source_reconstructed':False,'production_changed':False,'api_reference':q['api_reference'],'api_bytes_read_again':0,'exports_rehashed_or_copied':0,'physical_journey_accepted':False,'case24_started':False,'commit_or_M5':False,'privacy':'Room/process/invocation data and original/publication streams remain private Data; no credential/identity store copied.'})
for p in boundary.rglob('*'):
    if p.is_file():p.chmod(0o444)
for p in sorted([p for p in boundary.rglob('*') if p.is_dir()],key=lambda p:len(p.parts),reverse=True):p.chmod(0o555)
boundary.chmod(0o555)
print(json.dumps({'frozen':True,'boundary':str(boundary),'snapshot_sha256':raw(boundary/'snapshot.json'),'artifacts':len(artifacts),'objects':len(stored),'groups':len(groups),'group_paths':sum(len(v) for v in groups.values()),'changed_inherited_paths':1,'new_source_paths':len(additions),'full_inherited_source_reconstructed':False,'api_bytes_read_again':0,'exports_rehashed':0}),flush=True)
