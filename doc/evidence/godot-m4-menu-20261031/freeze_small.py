"""Seal the bounded shared menu delta and its finite software evidence only."""
import hashlib,importlib.util,json,os,shutil,stat,subprocess,sys,tarfile,time
from pathlib import Path,PurePosixPath
os.umask(0o077);sys.dont_write_bytecode=True
root=Path.cwd();ev=Path(__file__).resolve().parent;task=Path('/data/quod-m4-vr-ca84d4f8-20261029')
parent=task/'artifacts/quod-godot-m4-morning23-handoff-ca84d4f8-20261031-02'
boundary=task/'artifacts/quod-godot-m4-menu-handoff-ca84d4f8-20261031-01'
runs=task/'artifacts/menu146-freeze-runs01'
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
assert not boundary.exists() and raw(parent/'snapshot.json')=='8e1e59ad6e6757224be891902575171857ffcb29efc7c91ad31c58c9dcdf31fe'
assert git('rev-parse','HEAD').decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert git('branch','--show-current').decode().strip()=='worktree/pearl-stone' and not git('diff','--cached','--name-only') and not git('diff','--check')
from hashes import Digests,key
cache=root/'_build/godot-m4-r2-coordinator-20261029/menu-final-hashes-150.json'
assert raw(cache)=='ba544be23574509ac5a0f5b2ca49ed399d825ad8c329b8c2beef93f0f8576ed2'
d=Digests()
for path,digest in [(cache,raw(cache)),(task/'cache/menu146-qualification01-hashes.json','f8e472e8bbb54425318214acdf270ef5cadee6760e3f3afca7e08f14617f4086')]:
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
q=load(ev/'result.json');assert q['passed'] and not q['full_M4'] and q['selected']=='menu-final02'
changed=sorted(q['source_delta']);additions=sorted(current-set(old))
allowed=('doc/evidence/godot-m4-menu-20261031/',)
coordinator_additions={'nimbalyst-local/handoffs/godot-space-gui-sequence-146.md','nimbalyst-local/handoffs/godot-space-stage2-prompt-147.md','nimbalyst-local/handoffs/godot-menu-result-146.md'}
generated=load(ev/'inputs/generated-cache-disposition.json');generated_path=generated['path']
assert generated_path=='doc/evidence/godot-m4-vive-physical-20261029/__pycache__/publication.cpython-314.pyc'
assert row(root/generated_path)=={k:generated[k] for k in ['kind','mode','sha256','bytes']}
assert all(n.startswith(allowed) or n in coordinator_additions or n==generated_path for n in additions),additions
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
write(boundary/'previous-boundary-references.json',{'parents':refs,'logical_parent_paths':len(old),'full_inherited_source_reconstructed':False,'accepted_root_delta':'coordinator-morning23-delta-reconstruction-148','authenticated_root150_cache':{'path':str(cache),'sha256':raw(cache)},'unchanged_inherited_source_bytes_audited':0,'changed_before_file_verified':True})
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
patched=task/'builds/menu146-patch-materialization01';extracted=task/'builds/menu146-tar-materialization01';patched.mkdir(mode=0o700,exist_ok=False);extracted.mkdir(mode=0o700,exist_ok=False)
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
for label in ['menu146-tracker01','menu146-inbox01']:
    origin=task/'private'/label;selected(label,origin,files(origin))
run_labels=['menu-baseline01-build01','menu-baseline02-build01','menu-baseline02-render01-run','menu-final01-build01','menu-final01-render01-run','menu-final01-controller01-run','menu-geometry01-build01','menu-geometry01-render01-run','menu-final02-build01','menu-final02-render01-run','menu-final02-controller01-run','menu-qualification01']
for label in run_labels:
    origin=task/'private/runs'/label;selected(label,origin,files(origin))
for label in ['menu-baseline02-render01','menu-final01-render01','menu-final01-controller01','menu-geometry01-render01','menu-final02-render01','menu-final02-controller01']:
    origin=task/'private'/label;selected(label,origin,files(origin))
accepted=load(Path(load(ev/'inputs/baseline-contract.json')['parent_manifest']))
reference_map={}
for label in q['candidates']:
    m=load(ev/'inputs'/('client-'+label+'-manifest.json'));stage=Path(m['stage']);supplied=stage/'source'
    selected(label+'-actual-inputs',supplied,[supplied/n for n in m['supplied_inputs']]+[supplied/'NuGet.Config'])
    selected(label+'-digest-cache',stage,[stage/'computed-hashes.json'])
    dist=Path(m['export_executable']).parent;new=[];references={}
    for n,r in m['export_outputs'].items():
        assert row(dist/n)['sha256']==r['sha256'] and (dist/n).stat().st_size==r['bytes']
        if r!=accepted['export_outputs'].get(n):new.append(dist/n)
        else:references[n]={'accepted_parent_manifest':load(ev/'inputs/baseline-contract.json')['parent_manifest'],'sha256':r['sha256'],'bytes':r['bytes'],'actual_current_stat_key':key(dist/n),'mode':stat.S_IMODE((dist/n).stat().st_mode)}
    selected(label+'-changed-exports',dist,new);reference_map[label]={'actual_new_or_changed_exports':[str(p.relative_to(dist)) for p in new],'unchanged_accepted_parent_exports':references,'full_export_payload_duplicated':False}
write(boundary/'export-reference-map.json',reference_map)
selected('freeze-preexecution',runs/'driver-inputs',files(runs/'driver-inputs'))
group_tree=task/'builds/menu146-group-materialization01';group_tree.mkdir(mode=0o700,exist_ok=False)
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
write(boundary/'snapshot.json',{'worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','checkpoint':'Shared radial menu presentation correction and finite software qualification','artifacts':artifacts,'previous_snapshot_sha256':'8e1e59ad6e6757224be891902575171857ffcb29efc7c91ad31c58c9dcdf31fe','changed_inherited_paths':changed,'new_source_paths':len(additions),'actual_delta_materialized':True,'full_inherited_source_reconstructed':False,'production_changed':True,'api_bytes_read_again':0,'unchanged_exports_copied':0,'physical_menu_accepted':False,'case24_started':False,'commit_or_M5':False,'privacy':'Private raw streams and tracker/inbox bodies remain under private Data; no hardware geometry or credential store read.'})
for p in boundary.rglob('*'):
    if p.is_file():p.chmod(0o444)
for p in sorted([p for p in boundary.rglob('*') if p.is_dir()],key=lambda p:len(p.parts),reverse=True):p.chmod(0o555)
boundary.chmod(0o555)
print(json.dumps({'frozen':True,'boundary':str(boundary),'snapshot_sha256':raw(boundary/'snapshot.json'),'artifacts':len(artifacts),'objects':len(stored),'groups':len(groups),'group_paths':sum(len(v) for v in groups.values()),'changed_inherited_paths':len(changed),'new_source_paths':len(additions),'full_inherited_source_reconstructed':False,'api_bytes_read_again':0,'unchanged_exports_copied':0}),flush=True)
