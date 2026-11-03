#!/usr/bin/env python3
"""Append a reporting-only correction while preserving the sealed R2 boundary."""
import hashlib,json,os,shutil,signal,subprocess,sys,tarfile,time
from pathlib import Path

root=Path.cwd();ev=Path(__file__).resolve().parent
cache=Path('/home/yan/.cache/quod-m4-r2-artifacts')
prior=cache/'quod-godot-m4-r2-handoff-ca84d4f8-20261029-01'
boundary=cache/'quod-godot-m4-r2-handoff-ca84d4f8-20261029-02'
def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def write(path,value):path.write_text(json.dumps(value,indent=2)+'\n')
def git(*args):return subprocess.check_output(['git',*args],cwd=root)
def names(*args):return set(filter(None,git(*args,'-z').decode().split('\0')))

if sys.argv[1:] == ['--prepare']:
    original=root/'doc/evidence/godot-m4-r2-20261029/qualification.json'
    qualification=json.loads(original.read_text());cases={}
    for label in ['native-vive-final01','native-vive-final02','native-vive-final03']:
        log=root/'doc/evidence/godot-m4-r2-20261029'/label/'client.log'
        lines=log.read_text().splitlines();failures=[(i+1,line) for i,line in enumerate(lines) if line.startswith('System.Exception:')]
        assert len(failures)==1,label
        line,text=failures[0];assert ('actual XR scene rendering' in text)==(label=='native-vive-final01')
        if label!='native-vive-final01':assert 'real runtime supplies fresh stereo head frames cycle 1' in text
        cases[label]={'client_log_sha256':digest(log),'assertion_line':line,'failure':text,
            'preceding_passes':[text for text in lines[:line-1] if text.startswith('PASS ')],
            'later_render_assertion_reached':label=='native-vive-final01',
            'zero_swapchains_and_empty_layers':'Separate retained API entry observations, not a cause or returned-success/pixel proof'}
    write(ev/'assertion-attribution.json',cases)
    qualification['checkpoint']='M4-R2 reporting correction'
    qualification['preserved_original_qualification']={'path':str(original.relative_to(root)),'sha256':digest(original),
        'first_snapshot_sha256':'543cc3ac764bf15add7e88b450a104c992e3caabf92c00d508bc39e3fb1f1f2a'}
    qualification['remaining']=[('Cold final02/final03 exported hardware valid-head assertion fails before rendering assertion; zero swapchains/empty submissions are separate unexplained observations' if 'Cold hardware exported render assertion failure' in text else text) for text in qualification['remaining']]
    assert all('Cold hardware exported render assertion failure' not in text for text in qualification['remaining'])
    qualification['reporting_correction']={'product_or_test_changes':False,'test_reruns':False,
        'exact_assertion_proof':'assertion-attribution.json','source_and_output_acceptance_unchanged':True,
        'original_sealed_files_modified':False,'supersedes':'Only incorrect assertion attribution in first R2 handoff/qualification/failure prose'}
    qualification['inbox']['full_batch']='doc/evidence/godot-m4-r2-reporting-20261029/inputs/final-inbox-batch03.json'
    write(ev/'qualification.json',qualification)
    print(json.dumps({'reporting_only':True,'product_changes':0,'test_reruns':0,'corrected_cases':list(cases)}));sys.exit(0)

if sys.argv[1:] != ['--child']:
    runs=cache/'freeze-runs';log=runs/'m4-r2-reporting-freeze02.log';receipt=runs/'m4-r2-reporting-freeze02.json'
    assert not log.exists() and not receipt.exists()
    command=['python3',str(Path(__file__).resolve()),'--child']
    env=dict(os.environ);env['PYTHONDONTWRITEBYTECODE']='1'
    env.pop('LD_LIBRARY_PATH',None);env.pop('LD_PRELOAD',None)
    started=time.time();timeout=False
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
        'passed':status==0 and not timeout and summary is not None,'log':str(log),
        'log_sha256':digest(log),'summary':summary,
        'scope':'Reporting-only correction; source reconstruction rerun, exact unchanged output/dependency acceptance reused; no product tests rerun'}
    write(receipt,result);receipt.chmod(0o600);print(json.dumps(result));sys.exit(0 if result['passed'] else 1)

assert not boundary.exists(),'Preserve earlier boundaries'
assert digest(prior/'snapshot.json')=='543cc3ac764bf15add7e88b450a104c992e3caabf92c00d508bc39e3fb1f1f2a'
assert git('rev-parse','HEAD').decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert git('branch','--show-current').decode().strip()=='worktree/pearl-stone' and not git('diff','--cached','--name-only')
qualification=json.loads((ev/'qualification.json').read_text());assert qualification['reporting_correction']['product_or_test_changes'] is False
tracked=names('ls-files','--cached');untracked=names('ls-files','--others','--exclude-standard');source={}
for name in sorted(tracked|untracked):
    path=root/name
    if path.is_symlink():source[name]={'kind':'symlink','target':str(path.readlink()),'tracked':name in tracked}
    elif path.is_file():source[name]={'kind':'file','sha256':digest(path),'bytes':path.stat().st_size,'mode':path.stat().st_mode&0o777,'tracked':name in tracked}
old=json.loads((prior/'source-manifest.json').read_text())
assert all(source[name]==row for name,row in old.items()),'Previously frozen source changed'
additions=sorted(set(source)-set(old));assert additions
assert all(name.startswith('doc/evidence/godot-m4-r2-reporting-20261029/') or name=='nimbalyst-local/handoffs/godot-m4-r2-reporting-addendum.md' for name in additions),additions
assert git('diff','--binary','HEAD')==(prior/'tracked.patch').read_bytes()
boundary.mkdir(mode=0o700)
replaced={'snapshot.json','source-manifest.json','source-status.json','untracked.tar.xz','independent-reconstruction.json','causal-qualification.json','RECONSTRUCT.md'}
shared={};descriptor=json.loads((prior/'snapshot.json').read_text())
expected=set(descriptor['artifacts'])|{'snapshot.json'}
actual={str(path.relative_to(prior)) for path in prior.rglob('*') if path.is_file()}
assert actual==expected
for name in sorted(expected):
    original=prior/name;assert original.is_file() and not original.is_symlink() and original.stat().st_mode&0o222==0
    target=boundary/('prerequisite-r2-01-'+name if name in replaced else name)
    target.parent.mkdir(mode=0o700,parents=True,exist_ok=True);os.link(original,target)
    left=original.stat();right=target.stat()
    assert (left.st_dev,left.st_ino,left.st_size,left.st_mode)==(right.st_dev,right.st_ino,right.st_size,right.st_mode)
    shared[name]={'target':str(target.relative_to(boundary)),'bytes':left.st_size,
        'sha256':digest(original) if name=='snapshot.json' else descriptor['artifacts'][name]['sha256']}
write(boundary/'source-manifest.json',source)
write(boundary/'source-status.json',{'head':git('rev-parse','HEAD').decode().strip(),'parent':git('rev-parse','HEAD^').decode().strip(),
    'branch':'worktree/pearl-stone','original_branch_base':'f6c29fe925e666dd68ee7fa68c0e03f5d03391a2','index_empty':True,
    'committed':False,'implementation_frozen':True,'reporting_only_correction':True,'source_entries':len(source),
    'unchanged_previous_entries':len(old),'additions':additions,'changed_previous_entries':[],
    'generated_agents_files':sum(name.startswith('.agents/') for name in untracked),'status':git('status','--short').decode()})
write(boundary/'causal-qualification.json',qualification)
with tarfile.open(boundary/'untracked.tar.xz','x:xz',preset=1) as archive:
    for name in sorted(untracked):archive.add(root/name,arcname=name,recursive=False)
write(boundary/'unchanged-artifact-reuse.json',{'previous_boundary':str(prior),
    'previous_snapshot_sha256':digest(prior/'snapshot.json'),'all_previous_artifacts_retained':shared,
    'method':'Every unchanged actual artifact/object is the same read-only filesystem inode; exact previous artifact path set checked. Recorded hashes and complete output materialization/verification receipts are reused for identical bytes, not claimed as another fresh output test.',
    'output_and_dependency_contents_changed':False,'new_production_or_test_inputs':False,
    'complete_output_materializations_reused':['independent-final-client-materialization.json','independent-runtime-materialization.json'],
    'all_object_verification_reused':'independent-object-verification.json'})
(boundary/'RECONSTRUCT.md').write_text('''# R2 reporting correction reconstruction

This boundary adds assertion-attribution documentation only. First boundary01,
all frozen source/evidence and all failures remain intact. Full corrected source
is base.tar.gz + actual tracked.patch + complete untracked.tar.xz, materialized
and independently checked outside every checkout. source-status lists every
addition and proves no previous source byte/link/mode changed.

Every prior artifact/object is retained by verified read-only hardlink identity.
unchanged-artifact-reuse.json documents exact provenance; previous snapshot and
superseded source/qualification receipts are retained with prerequisite-r2-01
prefixes. All9071 actual dependency/output objects and complete final-client/
runtime materializations retain their prior independent verification for these
same bytes. No new product test, output requalification or copied build input
is claimed. The actual final native failure is valid-head BEFORE rendering;
zero swapchain/empty-layer observations are separate and unexplained.
''')
scratch=boundary.parent/(boundary.name+'-complete-reconstruction')
assert subprocess.run(['python3',str(boundary/'verify-reconstruction.py'),str(boundary),str(scratch)]).returncode==0
assert tracked==names('ls-files','--cached') and untracked==names('ls-files','--others','--exclude-standard')
assert git('diff','--binary','HEAD')==(prior/'tracked.patch').read_bytes()
for name,row in source.items():
    path=root/name
    if row['kind']=='symlink':assert path.is_symlink() and str(path.readlink())==row['target']
    else:assert digest(path)==row['sha256'] and path.stat().st_mode&0o777==row['mode'],name
artifacts={}
for path in sorted(boundary.rglob('*')):
    if path.is_file():artifacts[str(path.relative_to(boundary))]={'sha256':digest(path),'bytes':path.stat().st_size}
write(boundary/'snapshot.json',{'checkpoint':'M4-R2 reporting correction','worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f',
    'source_entries':len(source),'source_frozen':True,'complete_source_reconstruction':True,
    'reporting_only_correction':True,'unchanged_outputs_reuse_actual_verified_bytes':True,'artifacts':artifacts})
for path in boundary.rglob('*'):
    if path.is_file() and path.stat().st_mode&0o222:path.chmod(0o444)
for path in sorted([path for path in boundary.rglob('*') if path.is_dir()],key=lambda path:len(path.parts),reverse=True):path.chmod(0o555)
boundary.chmod(0o555)
print(json.dumps({'boundary':str(boundary),'snapshot_sha256':digest(boundary/'snapshot.json'),
    'base_sha256':digest(boundary/'base.tar.gz'),'tracked_patch_sha256':digest(boundary/'tracked.patch'),
    'untracked_sha256':digest(boundary/'untracked.tar.xz'),'source_entries':len(source),'artifacts':len(artifacts),
    'preserved_prior_entries':len(old),'reporting_additions':len(additions),'production_or_test_changes':0,'frozen':True}))
