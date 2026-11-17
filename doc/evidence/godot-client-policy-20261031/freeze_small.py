"""Existing additive seal owner for checkpoint200; no inherited tree copying."""
import json,os,shutil,stat,subprocess,sys,tarfile,time
from pathlib import Path,PurePosixPath
os.umask(0o077);sys.dont_write_bytecode=True
from hashes import Digests,TASK,key,raw
root=Path.cwd();ev=Path(__file__).resolve().parent
parent=TASK/'artifacts/quod-client-reliability-package-handoff-ca84d4f8-20261031-01'
boundary=TASK/'artifacts/quod-client-policy-handoff-ca84d4f8-20261031-02';runs=TASK/'artifacts/client-policy-freeze-runs02'
def load(p):return json.loads(p.read_text())
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def git(*a):return subprocess.check_output(['git',*a],cwd=root)
def source_inventory():return set(filter(None,git('ls-files','--cached','--others','--exclude-standard','-z').decode().split('\0')))
if sys.argv[1:]!=['--child']:
    assert not sys.argv[1:];runs.mkdir(mode=0o700,exist_ok=False);saved=runs/'driver-inputs';saved.mkdir()
    for p in [*ev.glob('*.py'),root/'client/godot-tools/package.py']:shutil.copy2(p,saved/p.name)
    cmd=[sys.executable,'-B',str(Path(__file__).resolve()),'--child'];started=time.monotonic()
    with (runs/'stdout.raw').open('xb') as out,(runs/'stderr.raw').open('xb') as err:r=subprocess.run(cmd,stdout=out,stderr=err,timeout=300)
    completed=next((json.loads(s) for s in (runs/'stdout.raw').read_text().splitlines() if s.startswith('{') and json.loads(s).get('frozen')),None)
    result={'command':cmd,'true_child_exit':r.returncode,'explicit_completion':completed is not None,'passed':r.returncode==0 and completed is not None,'summary':completed,'elapsed_seconds':time.monotonic()-started,'streams':{n:{'path':str(runs/(n+'.raw')),'sha256':raw(runs/(n+'.raw')),'bytes':(runs/(n+'.raw')).stat().st_size} for n in ['stdout','stderr']}}
    write(runs/'result.json',result);print(json.dumps(result));raise SystemExit(0 if result['passed'] else 1)
assert not boundary.exists() and raw(parent/'snapshot.json')=='63c883c5d0762d020bd7b900c17308422bc16f358181ebb5e4d049b0c443348a'
assert git('rev-parse','HEAD').decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert git('branch','--show-current').decode().strip()=='worktree/pearl-stone' and not git('diff','--cached','--name-only') and not git('diff','--check')
d=Digests();q=load(ev/'result.json');assert q['passed'] and not q['full_M4_or_M5']
def use_cache(reference):
    p=Path(reference['path']);assert raw(p)==reference['sha256']
    rows=load(p)['records']
    for r in rows.values() if isinstance(rows,dict) else rows:
        k=tuple(r['stat_key']);assert k not in d.values or d.values[k]==r['sha256'];d.values[k]=r['sha256']
    return p
cache=use_cache(q['digest_cache'])
def row(p):
    mode=stat.S_IMODE(p.lstat().st_mode)
    if p.is_symlink():return {'kind':'symlink','target':str(p.readlink()),'mode':mode}
    if p.is_dir():return {'kind':'directory','mode':mode}
    assert p.is_file() and 'api-dump' not in p.name
    return {'kind':'file','sha256':d.h(p),'bytes':p.stat().st_size,'mode':mode}
refs=load(parent/'previous-boundary-references.json')['parents']+[{'path':str(parent),'snapshot_sha256':raw(parent/'snapshot.json'),'source_index':'delta-source-manifest.json'}]
old={}
for r in refs:
    origin=Path(r['path']);assert d.h(origin/'snapshot.json')==r['snapshot_sha256']
    entry=load(origin/'snapshot.json')['artifacts'][r['source_index']];index=origin/r['source_index']
    assert d.h(index)==entry['sha256'] and index.stat().st_size==entry['bytes']
    old.update(load(index))
current=source_inventory();assert set(old)<=current
new=sorted(current-set(old));allowed={'nimbalyst-local/handoffs/godot-client-reliability-policy-prompt-200.md','nimbalyst-local/handoffs/godot-client-reliability-policy-result-200.md','test/quod_proof_answer_tests.erl','client/godot-tests/ResourceErrorChecks.cs'}
assert all(n in allowed or n.startswith('doc/evidence/godot-client-policy-20261031/') for n in new),new
assert sum(n.startswith('.agents/') for n in current)==31
changed=sorted(q['source_delta']);befores={n:{k:v for k,v in old[n].items() if k!='tracked'} for n in changed}
before_keys={n:key(Path(q['source_delta'][n]['before_path'])) for n in changed}
for n in changed:
    assert row(Path(q['source_delta'][n]['before_path']))==befores[n]
    assert row(root/n)['sha256']==q['source_delta'][n]['after_sha256']!=befores[n]['sha256']
names=sorted(changed+new);source={n:row(root/n) for n in names};directories={}
for n in names:
    for p in PurePosixPath(n).parents:
        if str(p)!='.':directories[str(p)]=stat.S_IMODE((root/str(p)).stat().st_mode)
tracked=git('diff','--binary','HEAD');boundary.mkdir(mode=0o700);(boundary/'objects').mkdir()
write(boundary/'delta-source-manifest.json',source);write(boundary/'changed-before-manifest.json',befores);write(boundary/'delta-directory-modes.json',directories)
write(boundary/'previous-boundary-references.json',{'parents':refs,'logical_inherited_paths':len(old),'changed_inherited_files':len(changed),'full_inherited_source_reconstructed':False,'source_custody':'accepted client/root199, workbench/root195 and authenticated parent references; no old source/object links or chmods','root199_cache_sha256':'4ec0e1cef38565b57cc3ae5ede20b3d6c696b91a1038819b94e7b2b4fb61ea1c'})
work=runs/'patch-inputs';(work/'before').mkdir(parents=True);(work/'after').mkdir()
for n in changed:
    original=Path(q['source_delta'][n]['before_path']);p=work/'before'/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(original,p);assert p.stat().st_ino!=original.stat().st_ino and row(p)==befores[n]
for n in names:
    p=work/'after'/n;p.parent.mkdir(parents=True,exist_ok=True)
    if (root/n).is_symlink():p.symlink_to((root/n).readlink())
    else:shutil.copy2(root/n,p)
diff=subprocess.run(['git','diff','--no-index','--binary','--src-prefix=a/','--dst-prefix=b/','before','after'],cwd=work,capture_output=True);assert diff.returncode==1 and not diff.stderr and diff.stdout
(boundary/'delta.patch').write_bytes(diff.stdout)
with tarfile.open(boundary/'delta-contents.tar','x:') as tar:
    for n in names:tar.add(root/n,arcname=n,recursive=False)
patched=TASK/'builds/client-policy-patch-materialization02';extracted=TASK/'builds/client-policy-tar-materialization02';patched.mkdir(mode=0o700,exist_ok=False);extracted.mkdir(mode=0o700,exist_ok=False)
for n in changed:
    original=Path(q['source_delta'][n]['before_path']);p=patched/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(original,p);assert p.stat().st_ino!=original.stat().st_ino and row(p)==befores[n]
commands=[]
for cmd in [['git','apply','--check','-p2',str(boundary/'delta.patch')],['git','apply','-p2',str(boundary/'delta.patch')]]:
    r=subprocess.run(cmd,cwd=patched,capture_output=True);commands.append({'command':cmd,'true_exit':r.returncode,'stdout':r.stdout.decode(),'stderr':r.stderr.decode()});assert r.returncode==0
with tarfile.open(boundary/'delta-contents.tar') as tar:
    members=tar.getmembers();assert len(members)==len(source) and {m.name for m in members}==set(source)
    for m in members:
        n=PurePosixPath(m.name);assert not n.is_absolute() and '..' not in n.parts;p=extracted/m.name;p.parent.mkdir(parents=True,exist_ok=True);r=source[m.name]
        if r['kind']=='file':assert m.isfile();p.write_bytes(tar.extractfile(m).read());p.chmod(r['mode'])
        else:assert r['kind']=='symlink' and m.issym() and m.linkname==r['target'];p.symlink_to(m.linkname)
for target in [patched,extracted]:
    for n,r in source.items():
        if r['kind']=='file':(target/n).chmod(r['mode'])
    for n,mode in sorted(directories.items(),key=lambda x:len(PurePosixPath(x[0]).parts),reverse=True):(target/n).chmod(mode)
    assert {str(p.relative_to(target)) for p in target.rglob('*')}==set(source)|set(directories)
    for n,r in source.items():assert row(target/n)==r
assert before_keys=={n:key(Path(q['source_delta'][n]['before_path'])) for n in changed}
write(boundary/'delta-materialization.json',{'patch_commands':commands,'changed_inherited_paths':changed,'separate_before_copies_required':len(changed),'separate_before_copies_actual':len(changed),'before_copy_stat_keys_unchanged':before_keys,'no_original_inherited_file_patched_or_chmodded':True,'patch_tree':str(patched),'tar_tree':str(extracted),'actual_tar_members':len(source),'full_delta_paths_bytes_types_links_modes_checked':True,'full_inherited_source_reconstructed':False})
groups={};origins={};root_modes={};stored={}
def selected(label,origin,paths):
    if not paths:return
    assert label not in groups;rows={};where={};root_modes[label]=stat.S_IMODE(origin.stat().st_mode)
    for p in paths:
        assert p.is_relative_to(origin) and 'api-dump' not in p.name
        while p!=origin:
            n=str(p.relative_to(origin));r=row(p)
            if r['kind']=='file':
                dest=boundary/'objects'/r['sha256']
                if not dest.exists():shutil.copyfile(p,dest);assert raw(dest)==r['sha256'];dest.chmod(0o444);stored[r['sha256']]={'bytes':r['bytes'],'ordinary_new_copy':True}
            rows[n]=r;where[n]=str(p);p=p.parent
    groups[label]=rows;origins[label]=where
def files(p):
    # Preserve generated test stores in place; copy only source, receipts and
    # finite diagnostics. Common Test puts durable fixture stores here.
    return sorted(x for x in p.rglob('*') if 'log_private' not in x.parts and (x.is_file() or x.is_symlink())) if p.exists() else []
for label in q['run_labels']+['policy-final-qualification01']:
    p=TASK/'private/runs'/label;selected('run-'+label,p,files(p))
failed_runs=TASK/'artifacts/client-policy-freeze-runs01'
selected('failed-freeze01-receipts',failed_runs,[failed_runs/n for n in ['result.json','stdout.raw','stderr.raw']]+files(failed_runs/'driver-inputs'))
failed_boundary=TASK/'artifacts/quod-client-policy-handoff-ca84d4f8-20261031-01'
selected('failed-freeze01-metadata',failed_boundary,[p for p in failed_boundary.iterdir() if p.is_file()])
p=TASK/'private/policy-release-logs01';selected('release-sanitized-streams',p,files(p))
# New private streams and receipts, never private profile/key/certificate stores.
for label in ['shutdown-owner-observation01','shutdown-owner-observation02','policy-current-journey01','policy-ordinary-launch01','policy-isolation-probe01']:
    p=TASK/'private'/label
    paths=sorted(p.glob('*.raw'))+sorted(p.glob('*.json'))+files(p/'drivers')
    if label=='policy-current-journey01':paths+=files(p/'sandbox/work')
    selected(label,p,paths)
for label in ['shutdown-owner-observation01-server','shutdown-owner-observation02-server','policy-current-journey01-server']:
    p=TASK/'private'/('quod-m4-live-'+label)
    paths=[f for f in p.iterdir() if f.is_file() and (f.suffix in ['.erl','.pl'] or f.name=='server-raw.log')]+files(p/'ebin')+files(p/'predicates-ebin')
    selected(label,p,sorted(paths))
# Small baseline/remote fixtures retain their actual executed source and objects.
for label in ['answer-policy-before01','answer-policy-client-before01','answer-policy-tests-before01','policy-release-reconciliation01','answer-policy-baseline01','answer-policy-final01','answer-policy-final02','answer-policy-affected01','answer-policy-affected02',*[f'answer-policy-remote{i:02}' for i in range(2,7)]]:
    p=TASK/'private'/label;selected(label,p,files(p))
server_references={}
for manifest in sorted((ev/'inputs').glob('answer-policy-*-source-manifest.json')):
    m=load(manifest);stage=Path(m['stage']);src=stage/'source';label=stage.name
    paths=[src/n for n in m['files']]
    derived=q['sequential_release']['remaining_reconciliation']['derived_source_outputs'] if label=='answer-policy-release02' else {}
    for n,sha in m['files'].items():
        output=derived.get(n)
        if output:assert output['input_sha256']==sha and d.h(src/n)==output['generated_sha256']
        else:assert d.h(src/n)==sha
    selected(label+'-sources',src,paths)
    objects=[]
    for inventory in sorted((ev/'inputs').glob(label+'-*-objects.json')):
        for r in load(inventory).values():
            p=Path(r['path']);assert d.h(p)==r['sha256'];objects.append(p)
    selected(label+'-provider-outputs',stage,sorted(set(objects)))
    # These are qualified external source archives/ordinary checkout resources,
    # not another copy of dependency histories, cache trees or old binaries.
    server_references[label]={'manifest':str(manifest),'sha256':d.h(manifest),'derived_source_metadata':derived,'recorded_input_fields':{k:m[k] for k in ['archive_inputs','source_application_resources','offline_locked_checkouts','compiled_inputs_copied'] if k in m}}
    p=stage/'computed-hashes.json'
    if p.exists():selected(label+'-custody',stage,[p])
    # Common Test files are new finite run evidence. Its private generated
    # namespace/profile stores stay in place and are never selected here.
    logs=src/'_build/test/logs';selected(label+'-ct-logs',logs,files(logs))
write(boundary/'server-input-references.json',server_references)
native_proof=root/'_build/godot-m4-r2-coordinator-20261029/release-input-native-check-208.json'
assert d.h(native_proof)=='0027aa618658e1c296c5cc932f3df1c4012278d43d9f4bf831ea88dc94ad21d3'
harness=load(native_proof)['completed_native_gate']['currently_retained_test_harness'];hp=Path(harness['path'])
assert list(key(hp))==harness['stat_key'] and d.h(hp)==harness['sha256'] and hp.stat().st_mode==harness['mode']
selected('retained-native-test-harness',TASK/'builds/answer-policy-release01',[hp])
write(boundary/'native-harness-custody.json',{'root_current_custody':harness,'root_proof_sha256':d.h(native_proof),'original_execution_time_hash_receipt_claimed':False})
for manifest in sorted((ev/'inputs').glob('resource-error-*.json')):
    m=load(manifest);stage=Path(m['stage']);src=stage
    use_cache(m['digest_cache'])
    paths=[src/n for n in m['inputs']]
    assert all(d.h(src/n)==sha for n,sha in m['inputs'].items())
    paths += [src/n for n in m.get('outputs',{})]
    selected(stage.name+'-inputs-outputs',src,paths)
p=TASK/'artifacts/policy-package-inputs01';selected('package-inputs',p,files(p))
selected('private-package-and-repro',TASK/'artifacts',[TASK/'artifacts/quod-workbench-linux-x86_64-policy-private01.tar.gz',TASK/'artifacts/quod-workbench-linux-x86_64-policy-repro02.tar.gz'])
inspection=load(ev/'inputs/package-inspection02.json');p=Path(inspection['extracted'])
selected('extracted-notices-launcher-index',p,[p/n for n in [*load(ev/'inputs/preparation-policy-package-inputs01.json')['extras'],'package-manifest.json']])
product=load(root/'doc/evidence/godot-ontology-workbench-20261031/inputs/client-workbench-product01-manifest.json');references={}
for manifest in sorted((ev/'inputs').glob('client-*-manifest.json')):
    m=load(manifest);stage=Path(m['stage']);src=stage/'source';label=stage.name
    use_cache(m['digest_cache'])
    paths=[src/n for n in m['supplied_inputs']];assert all(d.h(src/n)==sha for n,sha in m['supplied_inputs'].items());selected(label+'-inputs',src,paths+[src/'NuGet.Config'])
    if not m['passed']:
        references[label]={'partial_build_preserved':True,'complete_export_qualified':False};continue
    dist=Path(m['export_executable']).parent;changed_exports=[];unchanged={}
    for n,r in m['export_outputs'].items():
        assert d.h(dist/n)==r['sha256']
        if r!=product['export_outputs'][n]:changed_exports.append(dist/n)
        else:unchanged[n]={'sha256':r['sha256'],'bytes':r['bytes'],'stat_key':key(dist/n),'mode':stat.S_IMODE((dist/n).stat().st_mode)}
    selected(label+'-changed-exports',dist,changed_exports);references[label]={'product_manifest_sha256':'9c894e440bcd0d4fb0f67c35ae4e4b1456c9131f168a3e1bf9852846ec1083c8','unchanged_exports_not_copied':unchanged,'changed_exports':[str(p.relative_to(dist)) for p in changed_exports]}
write(boundary/'export-reference-map.json',references);selected('qualification-digest-cache',cache.parent,[cache]);selected('freeze-preexecution',runs/'driver-inputs',files(runs/'driver-inputs'))
material=TASK/'builds/client-policy-group-materialization02';material.mkdir(mode=0o700,exist_ok=False)
for label,rows in groups.items():
    target=material/label;target.mkdir()
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
assert source_inventory()==current and git('diff','--binary','HEAD')==tracked and not git('diff','--cached','--name-only')
for n,r in source.items():assert row(root/n)==r
write(boundary/'qualification.json',q);d.write(boundary/'used-stat-digests.json')
artifacts={str(p.relative_to(boundary)):{'sha256':raw(p),'bytes':p.stat().st_size} for p in boundary.rglob('*') if p.is_file()}
write(boundary/'snapshot.json',{'worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','checkpoint':'QUO-66 governed proof-answer allocation, bounded shutdown observations and current private desktop package','artifacts':artifacts,'previous_snapshot_sha256':raw(parent/'snapshot.json'),'changed_inherited_paths':changed,'new_source_paths':len(new),'actual_delta_materialized':True,'full_inherited_source_reconstructed':False,'no_source_retirement_or_global_changes':True,'old_API_bytes_read':0,'trace_free_product':q['product'],'shutdown_reliability_fixed':False,'full_M4_M5_or_hardware_acceptance':False,'commit_or_push':False,'privacy':'All raw/capture/evidence objects remain under private task Data. Profile/key/certificate stores are preserved in place and excluded from groups. Diagnostic companions are never distributed.'})
for p in boundary.rglob('*'):
    if p.is_file():p.chmod(0o444)
for p in sorted([p for p in boundary.rglob('*') if p.is_dir()],key=lambda x:len(x.parts),reverse=True):p.chmod(0o555)
boundary.chmod(0o555)
print(json.dumps({'frozen':True,'boundary':str(boundary),'snapshot_sha256':raw(boundary/'snapshot.json'),'artifacts':len(artifacts),'objects':len(stored),'groups':len(groups),'group_paths':sum(map(len,groups.values())),'new_source_paths':len(new),'changed_inherited_paths':len(changed),'actual_delta_materialized':True,'full_inherited_source_reconstructed':False}),flush=True)
