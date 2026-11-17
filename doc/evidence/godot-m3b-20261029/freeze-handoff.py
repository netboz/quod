#!/usr/bin/env python3
"""Freeze M3b source, exact clean inputs and actual qualified outputs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

p=argparse.ArgumentParser()
p.add_argument('label')
p.add_argument('--campaign',default='gates01')
p.add_argument('--client',required=True)
a=p.parse_args()
root=Path.cwd();evidence=Path(__file__).resolve().parent
stage=Path('/home/yan/.cache/quod-m3b-artifacts')/a.label
assert not stage.exists(),'Never replace a retained boundary'

def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def write(path,value):path.write_text(json.dumps(value,indent=2)+'\n')
def git(*args):return subprocess.check_output(['git',*args],cwd=root)
def names(*args):return set(filter(None,git(*args,'-z').decode().split('\0')))
def entry(path):
    if path.is_symlink():return dict(symlink=str(path.readlink()))
    if path.is_dir():return dict(directory=True,mode=path.stat().st_mode&0o777)
    return dict(sha256=digest(path),bytes=path.stat().st_size,mode=path.stat().st_mode&0o777)

gates=json.loads((evidence/(a.campaign+'-result.json')).read_text())
assert gates['all_true_exits_zero'] and gates['source_unchanged'] and not gates['unrun']
server_inputs=json.loads((evidence/'inputs'/(a.campaign+'-source-manifest.json')).read_text())
server_outputs=json.loads((evidence/'inputs'/(a.campaign+'-compiled-manifest.json')).read_text())
client=json.loads((evidence/'inputs'/('client-'+a.client+'-manifest.json')).read_text())
assert client['passed'] and client['authored_inputs_unchanged']
head=git('rev-parse','HEAD').decode().strip();branch=git('branch','--show-current').decode().strip()
assert head==server_inputs['head']=='f716ddf5e578df957a5b18421a0727a32c634f87'
assert branch==server_inputs['branch']=='worktree/pearl-stone'
for mapping in [server_inputs['files'],client['authored_inputs']]:
    for name,expected in mapping.items():assert digest(root/name)==expected,name
tracked=names('ls-files','--cached');untracked=names('ls-files','--others','--exclude-standard')
manifest={}
for name in sorted(tracked|untracked):
    path=root/name
    if not path.exists() and not path.is_symlink():continue
    row=entry(path);assert not row.get('directory'),name
    if 'symlink' in row:row=dict(kind='symlink',target=row['symlink'])
    else:row=dict(kind='file',**row)
    manifest[name]=dict(row,tracked=name in tracked)
stage.mkdir(mode=0o755)
patch=stage/'tracked.patch';patch.write_bytes(git('diff','--binary','HEAD'))
write(stage/'source-manifest.json',manifest)
write(stage/'source-status.json',dict(head=head,branch=branch,status=git('status','--short').decode(),
    worker_session='8b352c53-1f93-4e4c-8d1f-c5f41e8efbb8',model='openai-codex:gpt-6.1-sol',
    requested_effort='max',effective_effort='Not exposed by installed API',
    preserved_preexisting=['nimbalyst-local/handoffs/godot-m3b-prompt.md','.agents/'],
    source_entries=len(manifest),tracked_entries=sum(r['tracked'] for r in manifest.values()),
    untracked_entries=sum(not r['tracked'] for r in manifest.values()),compiled_application_inputs_copied=False))
base=json.loads((evidence/'inputs/source-base.json').read_text())
assert base['head']==head and base['git_archive_child_exit']==0 and digest(Path(base['path']))==base['sha256']
assert Path(base['path']).stat().st_mode&0o222==0
os.link(base['path'],stage/'base.tar.gz')
with tarfile.open(stage/'untracked.tar.xz','x:xz',preset=6) as archive:
    for name in sorted(untracked):archive.add(root/name,arcname=name,recursive=False)

verified_archives={}
def archive_rows(name,source,rows):
    target=stage/name
    with tarfile.open(target,'x:gz',dereference=False) as archive:
        for relative,expected in sorted(rows.items()):
            path=source/relative;assert entry(path)==expected,(relative,'changed output')
            archive.add(path,arcname=relative,recursive=False)
    seen=set()
    with tarfile.open(target,'r|gz') as archive:
        for member in archive:
            relative=member.name;row=rows[relative];assert relative not in seen;seen.add(relative)
            if row.get('directory'):assert member.isdir(),relative
            elif 'symlink' in row:assert member.issym() and member.linkname==row['symlink'],relative
            elif member.islnk():
                assert member.linkname in seen and rows[member.linkname]['sha256']==row['sha256'],relative
                assert rows[member.linkname]['bytes']==row['bytes'],relative
            else:
                assert member.isfile() and member.size==row['bytes'],relative
                assert hashlib.file_digest(archive.extractfile(member),'sha256').hexdigest()==row['sha256'],relative
            assert member.mode&0o111==row.get('mode',member.mode)&0o111,relative
    assert seen==set(rows),name
    verified_archives[name]=dict(entries=len(rows),every_content_hash_verified=True,exact_path_set=True)
    return target

server=Path(server_inputs['stage'])/'source'
archive_rows('server-compiled-outputs.tar.gz',server,server_outputs['compiled_outputs']|server_outputs['native_packaged_outputs'])
archive_rows('local-release-outputs.tar.gz',server,server_outputs['packaged_release_outputs'])
archive_rows('derived-rebar-outputs.tar.gz',server,server_outputs['derived_rebar_indexes'])
native_root=server/'native/quod_physics/target'
native_command=['docker','run','--rm','--network','none','-v',str(native_root)+':/native:ro',
    '-w','/native','--entrypoint','/usr/bin/env',server_inputs['image']]
# The builder owns some mode600 incremental coordination files. Read this
# closed output through its real owner, without chmod or changing any source.
hash_command=native_command+['find','.','-type','f','-exec','sha256sum','{}','+']
hashed=subprocess.run(hash_command,capture_output=True)
assert hashed.returncode==0,hashed.stderr
native_hashes={}
for line in hashed.stdout.decode().splitlines():
    assert len(line)>66 and line[64:66]=='  ',line
    name=line[66:].removeprefix('./');assert name not in native_hashes
    native_hashes[name]=line[:64]
native={'.':entry(native_root)}
for path in sorted(native_root.rglob('*')):
    name=str(path.relative_to(native_root))
    if path.is_symlink():native[name]=dict(symlink=str(path.readlink()))
    elif path.is_dir():native[name]=entry(path)
    else:
        assert path.is_file(),name
        native[name]=dict(bytes=path.stat().st_size,mode=path.stat().st_mode&0o777,sha256=native_hashes[name])
assert set(native_hashes)=={n for n,r in native.items() if 'sha256' in r}
native_archive=stage/'native-build-outputs.tar.gz'
tar_command=native_command+['tar','--sort=name','-czf','-','.']
with native_archive.open('xb') as stream:
    packed=subprocess.run(tar_command,stdout=stream,stderr=subprocess.PIPE)
assert packed.returncode==0,packed.stderr
seen=set()
with tarfile.open(native_archive,'r|gz') as archive:
    for member in archive:
        name=member.name.removeprefix('./');row=native[name]
        assert name not in seen;seen.add(name)
        if row.get('directory'):assert member.isdir(),name
        elif 'symlink' in row:assert member.issym() and member.linkname==row['symlink'],name
        elif member.islnk():
            original=native[member.linkname.removeprefix('./')]
            assert (original['sha256'],original['bytes'])==(row['sha256'],row['bytes']),name
        else:
            assert member.isfile() and member.size==row['bytes'],name
            assert hashlib.file_digest(archive.extractfile(member),'sha256').hexdigest()==row['sha256'],name
        if 'mode' in row:assert member.mode&0o777==row['mode'],name
assert seen==set(native)
verified_archives['native-build-outputs.tar.gz']=dict(entries=len(native),every_content_hash_verified=True,
    exact_path_set=True,source_read_only=True,hash_command=hash_command,hash_child_exit=hashed.returncode,
    archive_command=tar_command,archive_child_exit=packed.returncode)
write(stage/'native-build-outputs.json',native)

providers={};provider_rows={}
with tarfile.open(stage/'provider-compiled-outputs.tar.gz','x:gz',dereference=True) as archive:
    for receipt in sorted((evidence/'inputs').glob('*-objects.json')):
        provider=receipt.name[:-len('-objects.json')];rows=json.loads(receipt.read_text());providers[provider]=rows
        for name,row in sorted(rows.items()):
            path=Path(row['path']);assert digest(path)==row['sha256'],name
            relative=provider+'/'+name;provider_rows[relative]=entry(path)
            archive.add(path,arcname=relative,recursive=False)
# Verify provider bytes independently of their original paths.
seen=set()
with tarfile.open(stage/'provider-compiled-outputs.tar.gz','r|gz') as archive:
    for member in archive:
        row=provider_rows[member.name];assert member.name not in seen;seen.add(member.name)
        assert member.isfile() and member.size==row['bytes']
        assert hashlib.file_digest(archive.extractfile(member),'sha256').hexdigest()==row['sha256']
assert seen==set(provider_rows)
verified_archives['provider-compiled-outputs.tar.gz']=dict(entries=len(seen),every_content_hash_verified=True,exact_path_set=True)
write(stage/'provider-compiled-outputs.json',providers)
shutil.copy2(evidence/'inputs'/(a.campaign+'-compiled-manifest.json'),stage/'server-qualification.json')
private=Path('/home/yan/.cache/quod-m3b-artifacts/private')
fixture_outputs={}
for owner in sorted(private.glob('quod-m3b-live-*')):
    paths=list(owner.glob('*.erl'))+list((owner/'ebin').glob('*.beam'))+list((owner/'predicates-ebin').glob('*.beam'))
    for path in paths:fixture_outputs[str(path.relative_to(private))]=entry(path)
archive_rows('fixture-code-and-provider-outputs.tar.gz',private,fixture_outputs)
write(stage/'fixture-code-and-provider-outputs.json',dict(entries=fixture_outputs,
    scope='Only known test-factory source and BEAM provider directories; excludes all keys, private account/backup/recovery stores and raw logs. Earlier helper source versions not retained at launch are not claimed reconstructed from their BEAMs.'))

client_source=Path(client['source'])
export={name:entry(client_source/name) for name in client['export_outputs']}
for name,row in client['export_outputs'].items():
    assert (export[name]['sha256'],export[name]['bytes'])==(row['sha256'],row['bytes']),name
archive_rows('client-export.tar.gz',client_source,export)
generated={}
for parent in ['client/godot/.godot','client/godot-tests/bin','client/godot-tests/obj']:
    for path in sorted((client_source/parent).rglob('*')):
        if path.is_file() or path.is_symlink():generated[str(path.relative_to(client_source))]=entry(path)
archive_rows('client-build-outputs.tar.gz',client_source,generated)
write(stage/'client-build-outputs.json',dict(entries=generated,
    meaning='Actual generated engine/NuGet metadata and intermediate compiled outputs, separate from authored inputs and final export. None was copied into the clean input.'))
write(stage/'client-qualification.json',client)
write(stage/'client-export-outputs.json',export)
write(stage/'output-content-verification.json',verified_archives)

prior=Path('/home/yan/.cache/quod-m3a-artifacts/quod-godot-m3a-r1-handoff-8d55a3f3-20261029-01')
assert digest(prior/'snapshot.json')=='7b12df73ac1493201ac9e06f7f2f16337580d343026be1fb7d3ed69aff292e1c'
descriptor=json.loads((prior/'snapshot.json').read_text());predecessors={};shared=set()
for source in sorted(prior.iterdir()):
    assert source.is_file() and source.stat().st_mode&0o222==0,source
    expected=descriptor['artifacts'].get(source.name)
    actual=digest(source)
    if expected is not None:assert actual==(expected['sha256'] if isinstance(expected,dict) else expected),source
    name='prerequisite-r1-'+source.name;os.link(source,stage/name);shared.add(name)
    predecessors[source.name]=dict(sha256=actual,bytes=source.stat().st_size)
write(stage/'prerequisite-r1.json',dict(boundary=str(prior),actual_immutable_artifacts=predecessors,
    meaning='Read-only predecessor bytes shared by hardlink, including exact dependency/toolchain archives and every prior retained milestone; no old compiled output is a new clean input.'))
assert server_inputs['dependency_sources']==json.loads((prior/'dependency-inputs.json').read_text())
assert server_inputs['cargo_package_inputs']==json.loads((prior/'cargo-inputs.json').read_text())['packages']
write(stage/'clean-inputs.json',dict(server_authored_inputs=server_inputs['files'],
    dependency_sources=server_inputs['dependency_sources'],cargo_packages=server_inputs['cargo_package_inputs'],
    client_authored_inputs=client['authored_inputs'],client_dependency_archives=client['dependency_archives'],
    engine_toolchain_archives=client['engine_archives'],compiled_application_inputs_copied=False))

(stage/'RECONSTRUCT.md').write_text('''# Reconstruct M3b

Outside every checkout, extract base.tar.gz, apply tracked.patch with real
`git apply --binary`, then extract untracked.tar.xz. Verify the exact complete
path set, bytes, hashes, symlink targets and modes against source-manifest.json.
The included verifier restores full recorded permission modes after checking
Git's executable bits. This source includes the inherited coordinator prompt,
generated .agents files, all prior evidence and all unique failed campaigns.

clean-inputs.json separates authored source from exact dependency/toolchain
archives retained as prerequisite-r1-* actual immutable predecessor bytes.
Follow the command/full-log/true-exit receipts in the reconstructed M3b evidence.
The pinned local Docker builder ID is not a published registry digest.

Server/client compiled outputs, native intermediates, derived Rebar/PLT outputs,
generated engine/NuGet metadata, full local release and complete self-contained
desktop export are separately archived and content-verified outputs. None was
copied into a clean build input. Credentials, raw secret-bearing logs and private
fixture/recovery stores stay outside this public boundary. This is an uncommitted
review boundary, not a deployment or full M3 acceptance.
''')
scratch=Path('/tmp')/(a.label+'-full-reconstruction')
verified=subprocess.run(['python3',str(evidence/'verify-reconstruction.py'),str(stage),str(scratch)])
assert verified.returncode==0
assert tracked==names('ls-files','--cached') and untracked==names('ls-files','--others','--exclude-standard')
assert patch.read_bytes()==git('diff','--binary','HEAD')
for name,row in manifest.items():
    path=root/name
    if row['kind']=='symlink':assert path.is_symlink() and str(path.readlink())==row['target'],name
    else:assert entry(path)=={key:row[key] for key in ['sha256','bytes','mode']},name
artifacts={path.name:dict(sha256=digest(path),bytes=path.stat().st_size) for path in sorted(stage.iterdir()) if path.is_file()}
write(stage/'snapshot.json',dict(schema='quod-m3b-immutable-v1',label=a.label,head=head,branch=branch,
    worker_session='8b352c53-1f93-4e4c-8d1f-c5f41e8efbb8',campaign=a.campaign,client=a.client,
    artifacts=artifacts,source_entries=len(manifest),server_inputs=len(server_inputs['files']),
    client_inputs=len(client['authored_inputs']),client_export_entries=len(export),native_output_entries=len(native),
    provider_originals=len(provider_rows),shared_publication=False,committed=False,m3b_complete=False))
for path in stage.iterdir():
    if path.name not in shared and path.name!='base.tar.gz':path.chmod(0o444)
stage.chmod(0o555)
print(json.dumps(dict(boundary=str(stage),snapshot_sha256=digest(stage/'snapshot.json'),
    patch_sha256=digest(patch),base_sha256=digest(stage/'base.tar.gz'),source_entries=len(manifest),
    independently_reconstructed=True,output_content_verified=True)))
