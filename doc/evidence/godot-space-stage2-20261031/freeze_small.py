"""Seal the bounded Stage2 delta and its finite signed software evidence only."""
import hashlib,importlib.util,json,os,shutil,stat,subprocess,sys,tarfile,time
from pathlib import Path,PurePosixPath
os.umask(0o077);sys.dont_write_bytecode=True
root=Path.cwd();ev=Path(__file__).resolve().parent;task=Path('/data/quod-m4-vr-ca84d4f8-20261029')
parent=task/'artifacts/quod-godot-m4-menu-handoff-ca84d4f8-20261031-01'
boundary=task/'artifacts/quod-space-stage2-handoff-ca84d4f8-20261031-02'
runs=task/'artifacts/stage2-freeze-runs02'
def raw(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def load(p):return json.loads(p.read_text())
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def git(*a):return subprocess.check_output(['git',*a],cwd=root)
def inventory():return set(filter(None,git('ls-files','--cached','--others','--exclude-standard','-z').decode().split('\0')))
if sys.argv[1:]!=['--child']:
    assert not sys.argv[1:];runs.mkdir(mode=0o700,exist_ok=False);copies=runs/'driver-inputs';copies.mkdir()
    for p in ev.glob('*.py'):shutil.copy2(p,copies/p.name)
    command=[sys.executable,'-B',str(Path(__file__).resolve()),'--child'];started=time.monotonic()
    with (runs/'stdout.raw').open('xb') as out,(runs/'stderr.raw').open('xb') as err:r=subprocess.run(command,stdout=out,stderr=err,timeout=300)
    completion=None
    for line in (runs/'stdout.raw').read_text().splitlines():
        if line.startswith('{'):
            value=json.loads(line)
            if value.get('frozen'):completion=value
    result={'command':command,'true_child_exit':r.returncode,'explicit_completion':completion is not None,'elapsed_seconds':time.monotonic()-started,'passed':r.returncode==0 and completion is not None,'summary':completion,'streams':{k:{'path':str(runs/(k+'.raw')),'sha256':raw(runs/(k+'.raw')),'bytes':(runs/(k+'.raw')).stat().st_size} for k in ['stdout','stderr']}}
    write(runs/'result.json',result);print(json.dumps(result));raise SystemExit(0 if result['passed'] else 1)
assert not boundary.exists() and raw(parent/'snapshot.json')=='ff51b0ea0e6ac1671b412a6c2f269b0c1ce0b8753945aa147dc7793974aee1d8'
assert git('rev-parse','HEAD').decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert git('branch','--show-current').decode().strip()=='worktree/pearl-stone' and not git('diff','--cached','--name-only') and not git('diff','--check')
from hashes import Digests,key
cache=root/'_build/godot-m4-r2-coordinator-20261029/menu-seal-hashes-151.json'
assert raw(cache)=='faf790b00dae6dd637c080b4971e64660bfc8f859b8a72c442cf21cb636e9bd7'
d=Digests()
qualified=load(ev/'result.json');qualified_cache=qualified['digest_cache'];assert qualified['passed']
for path,digest in [(cache,'faf790b00dae6dd637c080b4971e64660bfc8f859b8a72c442cf21cb636e9bd7'),(Path(qualified_cache['path']),qualified_cache['sha256'])]:
    assert raw(path)==digest
    records=load(path)['records']
    for r in records.values() if isinstance(records,dict) else records:
        k=tuple(r['stat_key']);assert k not in d.values or d.values[k]==r['sha256'];d.values[k]=r['sha256']
def h(p):return d.h(p)
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
q=load(ev/'result.json');assert q['passed'] and not q['full_M4'] and q['selected']=='stage2-final03'
changed=sorted(q['source_delta']);additions=sorted(current-set(old))
allowed=('doc/evidence/godot-space-stage2-20261031/',)
coordinator_additions={'nimbalyst-local/handoffs/godot-vr-ergonomics-152.md','nimbalyst-local/handoffs/godot-stage2-review-authority-153.md','nimbalyst-local/handoffs/godot-space-stage2-result-147.md'}
inherited_evidence=load(ev/'inputs/inherited-owner-evidence-disposition.json')['files']
for n,r in inherited_evidence.items():
    actual=row(root/n);assert actual['kind']==r['kind'] and actual['sha256']==r['sha256'] and actual['bytes']==r['bytes'] and (root/n).stat().st_mode==r['mode']
assert all(n.startswith(allowed) or n in coordinator_additions or n in q['added_product_sources'] or n in inherited_evidence for n in additions),additions
assert sum(n.startswith('.agents/') for n in current)==31
befores={n:{k:v for k,v in old[n].items() if k!='tracked'} for n in changed}
for n in changed:
    assert row(Path(q['source_delta'][n]['before_path']))==befores[n]
    assert h(root/n)==q['source_delta'][n]['after_sha256']!=befores[n]['sha256']
names=sorted(changed+additions);source={n:row(root/n) for n in names};directories={}
for n in names:
    for p in PurePosixPath(n).parents:
        if str(p)!='.':directories[str(p)]=stat.S_IMODE((root/str(p)).stat().st_mode)
tracked=git('diff','--binary','HEAD');boundary.mkdir(mode=0o700);(boundary/'objects').mkdir()
write(boundary/'delta-source-manifest.json',source);write(boundary/'changed-before-manifest.json',befores);write(boundary/'delta-directory-modes.json',directories)
write(boundary/'previous-boundary-references.json',{'parents':refs,'logical_parent_paths':len(old),'full_inherited_source_reconstructed':False,'accepted_root_delta':'coordinator-menu-delta-reconstruction-151','authenticated_root151_cache':{'path':str(cache),'sha256':raw(cache)},'unchanged_inherited_source_bytes_audited':0,'changed_before_file_verified':True})
work=runs/'patch-inputs';(work/'before').mkdir(parents=True);(work/'after').mkdir()
for n in changed:
    before_path=Path(q['source_delta'][n]['before_path']);p=work/'before'/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(before_path,p);assert p.stat().st_ino!=before_path.stat().st_ino
for n in names:
    p=work/'after'/n;p.parent.mkdir(parents=True,exist_ok=True)
    if (root/n).is_symlink():p.symlink_to((root/n).readlink())
    else:shutil.copy2(root/n,p)
diff=subprocess.run(['git','diff','--no-index','--binary','--src-prefix=a/','--dst-prefix=b/','before','after'],cwd=work,capture_output=True);assert diff.returncode==1 and diff.stdout and not diff.stderr
(boundary/'delta.patch').write_bytes(diff.stdout)
with tarfile.open(boundary/'delta-contents.tar','x:') as tar:
    for n in names:tar.add(root/n,arcname=n,recursive=False)
patched=task/'builds/stage2-patch-materialization02';extracted=task/'builds/stage2-tar-materialization02';patched.mkdir(mode=0o700,exist_ok=False);extracted.mkdir(mode=0o700,exist_ok=False)
for n in changed:
    before_path=Path(q['source_delta'][n]['before_path']);p=patched/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(before_path,p);assert p.stat().st_ino!=before_path.stat().st_ino and row(p)==befores[n]
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
failed_freeze=task/'artifacts/stage2-freeze-runs01'
selected('failed-freeze01',failed_freeze,files(failed_freeze))
for origin in sorted((task/'private').glob('stage2-tracker*')):
    selected(origin.name,origin,files(origin))
for origin in sorted((task/'private').glob('stage2-inbox*')):
    selected(origin.name,origin,files(origin))
for origin in sorted((task/'private/runs').glob('stage2-*')):
    selected('run-'+origin.name,origin,files(origin))
for p in sorted(ev.glob('*/result.json')):
    r=load(p)
    if 'children' not in r:continue
    origin=task/'private'/p.parent.name
    paths=sorted(set(list(origin.glob('*.raw'))+list(origin.glob('client-result.raw.json*'))+(files(origin/'drivers') if (origin/'drivers').exists() else [])+(files(origin/'images') if (origin/'images').exists() else [])))
    if paths:selected('case-'+p.parent.name,origin,paths)
    server=task/'private'/('quod-m4-live-'+p.parent.name+'-server')
    if server.exists():
        paths=[f for f in server.iterdir() if f.is_file() and (f.suffix in ['.erl','.pl'] or f.name in ['server-raw.log','physics.json'])]
        paths+=files(server/'ebin') if (server/'ebin').exists() else []
        paths+=files(server/'predicates-ebin') if (server/'predicates-ebin').exists() else []
        if paths:selected('server-'+p.parent.name,server,sorted(paths))
for origin in sorted((task/'private').glob('stage2-owner-*')):
    selected(origin.name,origin,files(origin))
for origin in sorted((task/'private').glob('stage2-wire-*')):
    selected(origin.name,origin,files(origin))
accepted=load(root/'doc/evidence/godot-m4-menu-20261031/inputs/client-menu-final02-manifest.json')
reference_map={}
for manifest in sorted((ev/'inputs').glob('client-*-manifest.json')):
    m=load(manifest);label=manifest.name[len('client-'):-len('-manifest.json')];stage=Path(m['stage']);supplied=stage/'source'
    paths=[supplied/n for n in m['supplied_inputs']]
    assert all(p.is_file() for p in paths)
    for n,digest in m['supplied_inputs'].items():assert h(supplied/n)==digest,(label,n)
    if (supplied/'NuGet.Config').exists():paths.append(supplied/'NuGet.Config')
    selected(label+'-actual-inputs',supplied,paths)
    if not m['passed']:
        reference_map[label]={'partial_build_preserved':True,'complete_export_qualified':False};continue
    dist=Path(m['export_executable']).parent;new=[];references={}
    for n,r in m['export_outputs'].items():
        assert row(dist/n)['sha256']==r['sha256'] and (dist/n).stat().st_size==r['bytes']
        if r!=accepted['export_outputs'].get(n):new.append(dist/n)
        else:references[n]={'accepted_parent_manifest':'doc/evidence/godot-m4-menu-20261031/inputs/client-menu-final02-manifest.json','sha256':r['sha256'],'bytes':r['bytes'],'actual_current_stat_key':key(dist/n),'mode':stat.S_IMODE((dist/n).stat().st_mode)}
    selected(label+'-changed-exports',dist,new)
    reference_map[label]={'actual_new_or_changed_exports':[str(p.relative_to(dist)) for p in new],'unchanged_accepted_parent_exports':references,'full_export_payload_duplicated':False,'original_cache_reference':m['digest_cache'],'cache_records_reused_into_single_sealed_used_stat_cache':True}
write(boundary/'export-reference-map.json',reference_map)
selected('freeze-preexecution',runs/'driver-inputs',files(runs/'driver-inputs'))
group_tree=task/'builds/stage2-group-materialization02';group_tree.mkdir(mode=0o700,exist_ok=False)
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
write(boundary/'qualification.json',q);d.write(boundary/'used-stat-digests.json')
artifacts={str(p.relative_to(boundary)):{'sha256':raw(p),'bytes':p.stat().st_size} for p in boundary.rglob('*') if p.is_file()}
write(boundary/'snapshot.json',{'worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','checkpoint':'Stage2 exact-subject representations and guarded source/editor software qualification','artifacts':artifacts,'previous_snapshot_sha256':'ff51b0ea0e6ac1671b412a6c2f269b0c1ce0b8753945aa147dc7793974aee1d8','changed_inherited_paths':changed,'new_source_paths':len(additions),'actual_delta_materialized':True,'full_inherited_source_reconstructed':False,'production_changed':True,'api_bytes_read_again':0,'unchanged_exports_copied':0,'physical_stage2_accepted':False,'case24_started':False,'commit_or_M5':False,'privacy':'Private fixture streams/results and tracker/inbox bodies remain under private Data. Credential/profile stores are preserved in place and excluded from groups; no hardware geometry/API read.'})
for p in boundary.rglob('*'):
    if p.is_file():p.chmod(0o444)
for p in sorted([p for p in boundary.rglob('*') if p.is_dir()],key=lambda p:len(p.parts),reverse=True):p.chmod(0o555)
boundary.chmod(0o555)
print(json.dumps({'frozen':True,'boundary':str(boundary),'snapshot_sha256':raw(boundary/'snapshot.json'),'artifacts':len(artifacts),'objects':len(stored),'groups':len(groups),'group_paths':sum(len(v) for v in groups.values()),'changed_inherited_paths':len(changed),'new_source_paths':len(additions),'full_inherited_source_reconstructed':False,'api_bytes_read_again':0,'unchanged_exports_copied':0}),flush=True)
