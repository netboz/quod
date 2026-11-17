#!/usr/bin/env python3
"""Freeze actual R2 source, private-runtime code and complete generated outputs."""
import hashlib,json,os,shutil,subprocess,sys,tarfile
from pathlib import Path

root=Path.cwd();ev=Path(__file__).resolve().parent;boundary=Path(sys.argv[1])
cache=Path('/home/yan/.cache/quod-m4-r2-artifacts')
prior=Path('/home/yan/.cache/quod-m4-r1-artifacts/quod-godot-m4-r1-handoff-ca84d4f8-20261029-01')
assert not boundary.exists(),'Preserve earlier boundaries'
def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def write(path,value):path.write_text(json.dumps(value,indent=2)+'\n')
def git(*args):return subprocess.check_output(['git',*args],cwd=root)
def names(*args):return set(filter(None,git(*args,'-z').decode().split('\0')))
assert git('rev-parse','HEAD').decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert git('branch','--show-current').decode().strip()=='worktree/pearl-stone'
assert not git('diff','--cached','--name-only')
assert digest(prior/'snapshot.json')=='5a09fda58101a38d362c5e50cd9bcd4f827dcca74295abaa3b1f521c95379fcc'
qualification=json.loads((ev/'qualification.json').read_text());assert qualification['implementation_frozen'] and not qualification['full_m4_accepted']
client=json.loads((ev/'inputs'/('client-'+qualification['final_client_label']+'-manifest.json')).read_text());assert client['passed'] and client['distributable'] and not client['diagnostic_overrides']
assert all(digest(root/n)==h for n,h in client['live_source_inputs'].items())
delta=json.loads((ev/'inputs'/(qualification['final_client_label']+'-source-delta.json')).read_text());assert delta['live_and_accepted_stage_verified']
allowed=set(delta['client_delta_vs_candidate09'])
tracked=names('ls-files','--cached');untracked=names('ls-files','--others','--exclude-standard');source={}
for n in sorted(tracked|untracked):
    p=root/n
    if p.is_symlink():source[n]={'kind':'symlink','target':str(p.readlink()),'tracked':n in tracked}
    elif p.exists():
        assert p.is_file(),n
        source[n]={'kind':'file','sha256':digest(p),'bytes':p.stat().st_size,'mode':p.stat().st_mode&0o777,'tracked':n in tracked}
old=json.loads((prior/'source-manifest.json').read_text())
assert all(source[n]==row for n,row in old.items() if n not in allowed),'Preserved M4/R1 bytes changed'
boundary.mkdir(mode=0o700,parents=True);objects=boundary/'objects';objects.mkdir()
os.link(prior/'base.tar.gz',boundary/'base.tar.gz')
patch=git('diff','--binary','HEAD');(boundary/'tracked.patch').write_bytes(patch)
write(boundary/'source-manifest.json',source)
write(boundary/'source-status.json',{'head':git('rev-parse','HEAD').decode().strip(),'parent':git('rev-parse','HEAD^').decode().strip(),
    'branch':'worktree/pearl-stone','original_branch_base':'f6c29fe925e666dd68ee7fa68c0e03f5d03391a2','index_empty':True,'committed':False,
    'sole_writer':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','implementation_frozen':True,'source_entries':len(source),
    'generated_agents_files':sum(n.startswith('.agents/') for n in untracked),'changed_prior_inputs':sorted(allowed),
    'preserved_prior_source_entries':len(old)-len(allowed),'subsequent_additions':sorted(set(source)-set(old)),
    'status':git('status','--short').decode(),'model':'openai-codex:gpt-6.1-sol','launcher_effort':'max','effective_backend_effort':'unexposed'})
with tarfile.open(boundary/'untracked.tar.xz','x:xz',preset=1) as archive:
    for n in sorted(untracked):archive.add(root/n,arcname=n,recursive=False)
print('Full base/binary patch/untracked source bytes frozen',flush=True)

groups={};origins={};stored=set()
def preserve(path):
    sha=digest(path)
    if sha not in stored:
        target=objects/sha;shutil.copyfile(path,target);assert digest(target)==sha
        target.chmod(0o444);stored.add(sha)
    return sha
def row(path):
    stat=path.lstat();mode=stat.st_mode&0o7777
    if path.is_symlink():
        result={'kind':'symlink','target':str(path.readlink()),'mode':mode}
        if path.is_file():result['resolved_sha256']=preserve(path)
        return result
    if path.is_dir():return {'kind':'directory','mode':mode}
    assert path.is_file(),str(path)
    assert path.name not in ('active.json','tls-key.pem','proxy-key.pem','writer.lock'),str(path)
    return {'kind':'file','sha256':preserve(path),'bytes':stat.st_size,'mode':mode}
def tree(group,path):
    origins[group]={'root':str(path),'scope':'complete-tree-without-following-directory-symlinks'}
    rows={}
    for directory,dirs,files in os.walk(path,followlinks=False):
        parent=Path(directory)
        for name in list(dirs):
            p=parent/name;rows[str(p.relative_to(path))]=row(p)
            if p.is_symlink():dirs.remove(name)
        for name in files:
            p=parent/name;rows[str(p.relative_to(path))]=row(p)
    groups[group]=rows
    print('Preserved '+group+': '+str(len(rows))+' paths',flush=True)
for stage in sorted((cache/'artifacts').glob('quod-m4-client-*')):
    tree('client-stage-'+stage.name.removeprefix('quod-m4-client-'),stage)
tree('private-runtime-source-dependencies-and-build-outputs',cache/'runtime')
providers={}
for owner in sorted((cache/'private').glob('quod-m4-live-*')):
    for p in list(owner.glob('*.erl'))+list((owner/'ebin').glob('*.beam'))+list((owner/'predicates-ebin').glob('*.beam')):
        providers[str(p.relative_to(cache/'private'))]=row(p)
groups['new-fixture-code-and-provider-objects']=providers
origins['new-fixture-code-and-provider-objects']={'root':str(cache/'private'),'scope':'only retained .erl and .beam code in owned quod-m4-live-* fixtures; private data excluded'}
write(boundary/'object-groups.json',groups)
write(boundary/'object-group-origins.json',origins)
write(boundary/'final-client-qualification.json',client);write(boundary/'causal-qualification.json',qualification)
write(boundary/'clean-inputs.json',{'client_supplied_inputs':client['authored_inputs'],'input_classes':client['input_classes'],
    'dependency_archives':client['dependency_archives'],'engine_archives':client['engine_archives'],
    'unchanged_server_inputs':'prerequisite-r1-prerequisite-m4-prerequisite-m3b-clean-inputs.json','compiled_application_inputs_copied':False,
    'runtime_build_inputs':'object-groups.json','qualification_generated_outputs':'object-groups.json',
    'private_exclusions':['all credentials and private identity/stores','user calibration/config copies','raw API/managed/native diagnostics and raw server/client logs'],
    'scope':'Preserved code, build inputs/dependencies and outputs. No OS/kernel/display image or cold-host/native headset acceptance.'})
inherited={}
prior_descriptor=json.loads((prior/'snapshot.json').read_text())
assert {p.name for p in prior.iterdir()}==set(prior_descriptor['artifacts'])|{'snapshot.json'}
for p in sorted(prior.iterdir()):
    assert p.is_file() and p.stat().st_mode&0o222==0,p
    if p.name!='snapshot.json':
        expected=prior_descriptor['artifacts'][p.name]
        assert digest(p)==(expected['sha256'] if isinstance(expected,dict) else expected),p
    target=boundary/('prerequisite-r1-'+p.name);os.link(p,target)
    inherited[p.name]={'sha256':digest(p),'bytes':p.stat().st_size}
write(boundary/'prerequisite-r1.json',{'boundary':str(prior),'descriptor_sha256':digest(prior/'snapshot.json'),
    'verified_read_only_artifacts':inherited,'meaning':'Actual unchanged immutable M4/R1/M3b source, dependency, toolchain, provider and output bytes; no compiled outputs entered clean client builds.'})
for n in ['verify-reconstruction.py','verify-objects.py','materialize-group.py']:shutil.copy2(ev/n,boundary/n)
(boundary/'RECONSTRUCT.md').write_text('''# R2 reconstruction

Extract base.tar.gz outside every checkout, apply the actual tracked.patch with
git apply --binary, then extract complete untracked.tar.xz. The included source
verifier performs that real materialization and checks every path, content,
symlink and recorded full mode. Optional third argument selects an external
receipt path so a later verification never mutates this immutable boundary.

object-groups.json indexes every supplied/generated client-stage path, private
runtime source/dependency/build output, and new fixture/provider code object.
objects/<sha256> contains actual deduplicated bytes, including observed external
code/compiler dependencies. verify-objects.py independently checks the complete
object path set, every byte hash/size, and every indexed type/link/full mode.
Group names preserve provenance; compiled outputs are evidence, never supplied
application source inputs. Absolute links retain their original recorded target;
resolved file bytes are also preserved. Host kernel/display/calibration/private
data are separate prerequisites and are not represented as a portable OS image.

Verified prerequisite-r1-* hardlinks retain every immutable prior artifact.
The actual base here is current HEAD293cf611; the historical M3b base/patch is
provenance and must never be applied over this committed tree. Store credentials,
private profiles/calibration and raw restricted diagnostics outside snapshots.

Full M4/native/physical acceptance and both historical desktop-stall fixes remain
open. No commit, engine pin change, global runtime/display change or M5 occurred.
''')
scratch=boundary.parent/(boundary.name+'-complete-reconstruction')
assert subprocess.run(['python3',str(ev/'verify-reconstruction.py'),str(boundary),str(scratch)]).returncode==0
assert subprocess.run(['python3',str(ev/'verify-objects.py'),str(boundary)]).returncode==0
for group,suffix in [('client-stage-'+qualification['final_client_label'],'final-client'),('private-runtime-source-dependencies-and-build-outputs','runtime')]:
    workspace=boundary.parent/(boundary.name+'-'+suffix+'-materialization')
    assert subprocess.run(['python3',str(ev/'materialize-group.py'),str(boundary),group,str(workspace),str(boundary/('independent-'+suffix+'-materialization.json'))]).returncode==0
assert tracked==names('ls-files','--cached') and untracked==names('ls-files','--others','--exclude-standard')
assert patch==git('diff','--binary','HEAD')
for n,r in source.items():
    p=root/n
    if r['kind']=='symlink':assert p.is_symlink() and str(p.readlink())==r['target'],n
    else:assert digest(p)==r['sha256'] and p.stat().st_mode&0o777==r['mode'],n
artifacts={}
for p in sorted(boundary.rglob('*')):
    if p.is_file():artifacts[str(p.relative_to(boundary))]={'sha256':digest(p),'bytes':p.stat().st_size}
write(boundary/'snapshot.json',{'checkpoint':'M4-R2','worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','source_entries':len(source),
    'source_frozen':True,'complete_source_reconstruction':True,'output_and_dependency_object_verification':True,'artifacts':artifacts})
for p in boundary.rglob('*'):
    if p.is_file() and p.stat().st_mode&0o222:p.chmod(0o444)
for p in sorted([p for p in boundary.rglob('*') if p.is_dir()],key=lambda p:len(p.parts),reverse=True):p.chmod(0o555)
boundary.chmod(0o555)
print(json.dumps({'boundary':str(boundary),'snapshot_sha256':digest(boundary/'snapshot.json'),'base_sha256':digest(boundary/'base.tar.gz'),
    'tracked_patch_sha256':digest(boundary/'tracked.patch'),'untracked_sha256':digest(boundary/'untracked.tar.xz'),
    'source_entries':len(source),'artifacts':len(artifacts),'unique_output_objects':len(stored),'frozen':True}))
