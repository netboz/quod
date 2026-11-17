#!/usr/bin/env python3
"""Preserve full R1 source/diagnostic outputs and verify a real reconstruction."""
import hashlib, json, os, shutil, subprocess, sys, tarfile
from pathlib import Path

root=Path.cwd(); evidence=Path(__file__).resolve().parent; boundary=Path(sys.argv[1])
prior=Path('/home/yan/.cache/quod-m4-artifacts/quod-godot-m4-handoff-ca84d4f8-20261029-01')
assert not boundary.exists(), 'Retain every earlier boundary'
def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def write(path,value):path.write_text(json.dumps(value,indent=2)+'\n')
def git(*args):return subprocess.check_output(['git',*args],cwd=root)
def names(*args):return set(filter(None,git(*args,'-z').decode().split('\0')))
def entry(path):
    if path.is_symlink():return {'symlink':str(path.readlink())}
    if path.is_dir():return {'directory':True,'mode':path.stat().st_mode&0o777}
    return {'sha256':digest(path),'bytes':path.stat().st_size,'mode':path.stat().st_mode&0o777}
head=git('rev-parse','HEAD').decode().strip();branch=git('branch','--show-current').decode().strip()
assert head=='293cf6115c0a6b18315eccdbb42cbca396f443d3' and branch=='worktree/pearl-stone'
assert not git('diff','--cached','--name-only')
assert digest(prior/'snapshot.json')=='a06f1f934754d3d210e1b74c5685c2c523b1507bfc1a8af2ce9fc7ce4aec5349'
qualification=json.loads((evidence/'qualification.json').read_text())
assert qualification['bounded_investigation_complete'] and not qualification['cause_determined']
assert not qualification['production_correction'] and not qualification['historical_failures_resolved']
client=json.loads((evidence/'inputs/client-diagnostic01-manifest.json').read_text());assert client['passed']
baseline=json.loads((root/'doc/evidence/godot-m4-20261029/inputs/client-candidate09-manifest.json').read_text())
assert all(digest(root/n)==h for n,h in baseline['authored_inputs'].items())
tracked=names('ls-files','--cached');untracked=names('ls-files','--others','--exclude-standard');manifest={}
for n in sorted(tracked|untracked):
    path=root/n
    if not path.exists() and not path.is_symlink():continue
    row=entry(path);assert not row.get('directory'),n
    manifest[n]=dict(kind='symlink',target=row['symlink'],tracked=n in tracked) if 'symlink' in row else dict(kind='file',**row,tracked=n in tracked)
original=json.loads((prior/'source-manifest.json').read_text())
assert all(manifest[n]==row for n,row in original.items()), 'Original frozen source changed'
patch=git('diff','--binary','HEAD');assert hashlib.sha256(patch).hexdigest()=='8d759963b1100714e6f1301175324168bab40bdb3125a02f8b5604cefeab4370'
boundary.mkdir(mode=0o755,parents=True)
shared=set()
for name in ['base.tar.gz','tracked.patch']:
    assert (prior/name).stat().st_mode&0o222==0
    os.link(prior/name,boundary/name);shared.add(name)
write(boundary/'source-manifest.json',manifest)
write(boundary/'source-status.json',{'head':head,'branch':branch,'parent':git('rev-parse','HEAD^').decode().strip(),
    'original_branch_base':'f6c29fe925e666dd68ee7fa68c0e03f5d03391a2','committed':False,'index_empty':True,
    'sole_writer':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','implementation_frozen':True,'production_delta_vs_candidate09':0,
    'original_M4_source_entries_preserved':len(original),'subsequent_additions':sorted(set(manifest)-set(original)),
    'status':git('status','--short').decode(),'model':'openai-codex:gpt-6.1-sol','launcher_effort':'max','effective_backend_effort':'unexposed'})
with tarfile.open(boundary/'untracked.tar.xz','x:xz',preset=6) as archive:
    for n in sorted(untracked):archive.add(root/n,arcname=n,recursive=False)
print('Complete current source/base/patch/untracked bytes preserved',flush=True)
verified={}
def archive_rows(name,source,rows):
    target=boundary/name
    with tarfile.open(target,'x:gz',dereference=False) as archive:
        for relative,row in sorted(rows.items()):
            path=source/relative;assert entry(path)==row,(relative,'changed output')
            archive.add(path,arcname=relative,recursive=False)
    seen=set()
    with tarfile.open(target,'r:gz') as archive:
        for member in archive:
            n=member.name;assert n not in seen and n in rows,n;seen.add(n);row=rows[n]
            if row.get('directory'):assert member.isdir(),n
            elif 'symlink' in row:assert member.issym() and member.linkname==row['symlink'],n
            elif member.islnk():assert member.linkname in seen and rows[member.linkname]['sha256']==row['sha256'] and rows[member.linkname]['bytes']==row['bytes'],n
            else:assert member.isfile() and member.size==row['bytes'] and hashlib.file_digest(archive.extractfile(member),'sha256').hexdigest()==row['sha256'],n
            if 'mode' in row:assert member.mode&0o777==row['mode'],n
    assert seen==set(rows),name
    verified[name]={'entries':len(rows),'exact_path_set':True,'every_content_hash_verified':True,'full_modes_verified':True}
    write(boundary/(name+'.json'),rows)
source=Path(client['source']);stage=Path(client['stage'])
export={n:entry(source/n) for n in client['export_outputs']}
for n,row in client['export_outputs'].items():assert (export[n]['sha256'],export[n]['bytes'])==(row['sha256'],row['bytes']),n
archive_rows('client-export.tar.gz',source,export)
supplied={}
for n,h in client['authored_inputs'].items():
    assert digest(source/n)==h,n;supplied[str(Path('source')/n)]=entry(source/n)
archive_rows('client-supplied-inputs.tar.gz',stage,supplied)
generated={}
for parent in ['source/client/godot/.godot','source/client/godot-tests/bin','source/client/godot-tests/obj','temporary']:
    folder=stage/parent
    if not folder.exists():continue
    generated[parent]=entry(folder)
    for path in sorted(folder.rglob('*')):generated[str(path.relative_to(stage))]=entry(path)
for n in ['source/NuGet.Config','public-backup.json']:
    path=stage/n
    if path.exists():generated[n]=entry(path)
archive_rows('client-build-outputs.tar.gz',stage,generated)
private=stage.parent/'private';providers={}
for owner in sorted(private.glob('quod-m4-live-*')):
    for path in list(owner.glob('*.erl'))+list((owner/'ebin').glob('*.beam'))+list((owner/'predicates-ebin').glob('*.beam')):
        providers[str(path.relative_to(private))]=entry(path)
archive_rows('fixture-code-and-provider-outputs.tar.gz',private,providers)
write(boundary/'output-content-verification.json',verified)
write(boundary/'diagnostic-client-qualification.json',client)
write(boundary/'causal-qualification.json',qualification)
write(boundary/'clean-inputs.json',{'current_unchanged_candidate09_inputs':baseline['authored_inputs'],
    'diagnostic_inputs':client['authored_inputs'],'diagnostic_input_classes':client['input_classes'],
    'diagnostic_only_source_changes':sorted(n for n,h in client['authored_inputs'].items() if h!=baseline['authored_inputs'][n]),
    'dependency_archives':client['dependency_archives'],'engine_archives':client['engine_archives'],
    'unchanged_server_inputs':'prerequisite-m4-prerequisite-m3b-clean-inputs.json','compiled_application_inputs_copied':False})
descriptor=json.loads((prior/'snapshot.json').read_text());inherited={}
for path in sorted(prior.iterdir()):
    assert path.is_file() and path.stat().st_mode&0o222==0,path
    actual=digest(path);expected=descriptor['artifacts'].get(path.name)
    if expected is not None:assert actual==(expected['sha256'] if isinstance(expected,dict) else expected),path
    name='prerequisite-m4-'+path.name;os.link(path,boundary/name);shared.add(name)
    inherited[path.name]={'sha256':actual,'bytes':path.stat().st_size}
write(boundary/'prerequisite-m4.json',{'boundary':str(prior),'descriptor_sha256':digest(prior/'snapshot.json'),
    'actual_read_only_artifacts':inherited,'meaning':'Verified immutable hardlinks preserve actual prior source, toolchain/dependency/server/native/release/output bytes and failures; no compiled output entered a clean build.'})
shutil.copy2(evidence/'verify-reconstruction.py',boundary/'verify-reconstruction.py')
(boundary/'RECONSTRUCT.md').write_text('''# Reconstruct the R1 boundary

Outside every checkout, extract actual HEAD base.tar.gz, apply tracked.patch
with real git apply --binary, then extract the complete current untracked.tar.xz.
Run the included verifier in a fresh destination. It checks exact paths, every
content/link, executable bits and all recorded source modes. Its optional third
argument puts a later verifier receipt outside this immutable directory.

Original M4 bytes remain unchanged. New diagnostic observations and subsequent
coordination additions have separate provenance. Current production is exactly
candidate09; the diagnostic export alone contains temporary observation. The
new archive indices preserve actual supplied inputs, generated outputs, full
export and provider objects. Verified prerequisite-m4-* hardlinks share actual
immutable source/dependency/toolchain/server/output bytes. The historical M3b
base remains provenance; do not apply an old M3b patch over the new HEAD.

This is an unresolved causal investigation. Passing repetitions do not fix
either historical hang. No native OpenXR/physical Vive acceptance, Quest claim,
commit, deployment, full-M4 credit or M5 launch is established here. Credentials,
private stores and raw restricted diagnostics are outside public artifacts.
''')
print('Actual diagnostic output archives and immutable prerequisites verified',flush=True)
scratch=boundary.parent/(boundary.name+'-complete-reconstruction')
child=subprocess.run(['python3',str(evidence/'verify-reconstruction.py'),str(boundary),str(scratch)])
assert child.returncode==0
assert tracked==names('ls-files','--cached') and untracked==names('ls-files','--others','--exclude-standard')
assert patch==git('diff','--binary','HEAD')
for n,row in manifest.items():
    path=root/n
    if row['kind']=='symlink':assert path.is_symlink() and str(path.readlink())==row['target'],n
    else:assert entry(path)=={key:row[key] for key in ['sha256','bytes','mode']},n
artifacts={p.name:{'sha256':digest(p),'bytes':p.stat().st_size} for p in sorted(boundary.iterdir()) if p.is_file()}
write(boundary/'snapshot.json',{'schema':'quod-m4-r1-immutable-v1','head':head,'branch':branch,
    'worker_session':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','artifacts':artifacts,'source_entries':len(manifest),
    'current_client_inputs':len(baseline['authored_inputs']),'diagnostic_client_inputs':len(supplied),'diagnostic_exports':len(export),
    'production_correction':False,'cause_determined':False,'historical_failures_resolved':False,
    'committed':False,'full_m4_accepted':False,'shared_body_publication':False})
for path in boundary.iterdir():
    if path.name not in shared:path.chmod(0o444)
boundary.chmod(0o555)
print(json.dumps({'boundary':str(boundary),'descriptor_sha256':digest(boundary/'snapshot.json'),
    'patch_sha256':digest(boundary/'tracked.patch'),'base_sha256':digest(boundary/'base.tar.gz'),
    'source_entries':len(manifest),'original_source_entries_preserved':len(original),'output_sets':verified}),flush=True)
