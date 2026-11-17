#!/usr/bin/env python3
"""Freeze actual M3a source and artifacts without duplicating a materialized tree."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

evidence=Path(__file__).resolve().parent
root=evidence.parents[2]
campaign,label=sys.argv[1:]
prior=Path('/home/yan/.cache/quod-m2-artifacts/quod-godot-m2-handoff-8db34a85-20261028-01')
parent=Path('/home/yan/.cache/quod-m3a-artifacts')
stage=parent/label
assert not stage.exists(),'Never replace an earlier boundary'
gates=json.loads((evidence/(campaign+'-result.json')).read_text())
assert gates['all_true_exits_zero'] and gates['source_unchanged'] and not gates['unrun']
inputs=json.loads((evidence/'inputs'/(campaign+'-source-manifest.json')).read_text())
compiled=json.loads((evidence/'inputs'/(campaign+'-compiled-manifest.json')).read_text())

def digest(path):
    with path.open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()

def write(path,data): path.write_text(json.dumps(data,indent=2)+'\n')
def git(*args): return subprocess.check_output(['git',*args],cwd=root)
def names(*args): return set(filter(None,git(*args,'-z').decode().split('\0')))

head=git('rev-parse','HEAD').decode().strip()
branch=git('branch','--show-current').decode().strip()
assert head==inputs['head']=='69196a36caeeb06e6ee07982f1ab1988d7c16b43'
assert branch==inputs['branch']=='worktree/pearl-stone'
for name,expected in inputs['files'].items(): assert digest(root/name)==expected,name
client=json.loads((prior/'client-qualification.json').read_text())
for name,expected in client['authored_inputs'].items(): assert digest(root/name)==expected,name
assert inputs['dependency_sources']==json.loads((prior/'dependency-inputs.json').read_text())
assert inputs['cargo_package_inputs']==json.loads((prior/'cargo-inputs.json').read_text())['packages']
tracked=names('ls-files','--cached')
untracked=names('ls-files','--others','--exclude-standard')
changed=names('diff','--name-only','HEAD')
manifest={}
for name in sorted(tracked|untracked):
    path=root/name
    if path.is_symlink(): row=dict(kind='symlink',target=str(path.readlink()))
    elif path.is_file(): row=dict(kind='file',bytes=path.stat().st_size,sha256=digest(path),mode=path.stat().st_mode&0o777)
    elif not path.exists(): continue
    else: raise ValueError(('Non-file source entry',name))
    manifest[name]=dict(row,tracked=name in tracked)
parent.mkdir(mode=0o755,exist_ok=True)
stage.mkdir(mode=0o755)
patch=stage/'tracked.patch'
patch.write_bytes(git('diff','--binary','HEAD'))
write(stage/'source-manifest.json',manifest)
write(stage/'source-status.json',dict(head=head,branch=branch,status=git('status','--short').decode(),
    worker_session='8d55a3f3-e558-46e2-afbb-2e028558f371',
    model='openai-codex:gpt-6.1-sol',requested_effort='xhigh',effective_effort='Not exposed by installed API',
    preserved_preexisting=['nimbalyst-local/handoffs/godot-m3a-prompt.md','.agents/'],
    source_entries=len(manifest),tracked_entries=sum(r['tracked'] for r in manifest.values()),
    untracked_entries=sum(not r['tracked'] for r in manifest.values()),compiled_inputs_copied=False))

# Reuse the independently retained immutable committed base. There is no
# second full working tree, Git index, branch or checkout.
base=stage/'base.tar.gz'
prepared=json.loads((evidence/'inputs/source-base.json').read_text())
assert prepared['head']==head and prepared['git_archive_child_exit']==0
assert digest(Path(prepared['path']))==prepared['sha256']
os.link(prepared['path'],base)

scratch=Path('/tmp')/(label+'-patch-verification')
scratch.mkdir(mode=0o700,exist_ok=False)
reconstructed={}
with tarfile.open(base,mode='r|gz') as archive:
    for member in archive:
        name=member.name
        if member.isdir(): continue
        assert name not in reconstructed
        if member.issym(): row=dict(kind='symlink',target=member.linkname)
        else:
            assert member.isfile(),name
            stream=archive.extractfile(member)
            hasher=hashlib.sha256()
            output=None
            if name in changed:
                path=scratch/name
                path.parent.mkdir(parents=True,exist_ok=True)
                output=path.open('xb')
            try:
                for chunk in iter(lambda:stream.read(1024*1024),b''):
                    hasher.update(chunk)
                    if output: output.write(chunk)
            finally:
                if output: output.close()
            row=dict(kind='file',bytes=member.size,sha256=hasher.hexdigest(),mode=member.mode)
        reconstructed[name]=row
        if name in changed:
            path=scratch/name
            path.parent.mkdir(parents=True,exist_ok=True)
            if member.issym(): path.symlink_to(member.linkname)
            else: path.chmod(member.mode)
env=dict(os.environ)
for key in ['GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE']: env.pop(key,None)
outside=subprocess.run(['git','rev-parse','--show-toplevel'],cwd=scratch,env=env,capture_output=True)
assert outside.returncode!=0,'Patch verification must run outside every Git checkout'
applied=subprocess.run(['git','apply','--binary',str(patch)],cwd=scratch,env=env,capture_output=True)
write(stage/'patch-result.json',dict(child_exit=applied.returncode,
    stdout=applied.stdout.decode(),stderr=applied.stderr.decode(),workspace=str(scratch)))
assert applied.returncode==0
for name in changed:
    path=scratch/name
    if path.is_symlink(): reconstructed[name]=dict(kind='symlink',target=str(path.readlink()))
    elif path.is_file(): reconstructed[name]=dict(kind='file',sha256=digest(path),bytes=path.stat().st_size,mode=path.stat().st_mode&0o777)
    else: reconstructed.pop(name,None)

untracked_archive=stage/'untracked.tar.xz'
with tarfile.open(untracked_archive,'x:xz',preset=9) as archive:
    for name in sorted(untracked): archive.add(root/name,arcname=name,recursive=False)
seen=set()
with tarfile.open(untracked_archive,mode='r|xz') as archive:
    for member in archive:
        name=member.name
        assert name not in seen and name not in reconstructed
        seen.add(name)
        if member.issym(): row=dict(kind='symlink',target=member.linkname)
        elif member.islnk(): row=dict(reconstructed[member.linkname])
        else:
            assert member.isfile()
            row=dict(kind='file',sha256=hashlib.file_digest(archive.extractfile(member),'sha256').hexdigest(),bytes=member.size,mode=member.mode)
        reconstructed[name]=row
assert seen==untracked
assert set(reconstructed)==set(manifest),'Reconstructed path set differs'
for name,expected in manifest.items():
    actual=reconstructed[name]
    assert actual['kind']==expected['kind'],name
    if expected['kind']=='symlink': assert actual['target']==expected['target'],name
    else:
        assert (actual['sha256'],actual['bytes'])==(expected['sha256'],expected['bytes']),name
        assert (actual['mode']&0o111)==(expected['mode']&0o111),name
write(stage/'reconstruction-verification.json',dict(exact_source_path_set=True,
    source_entries_verified=len(manifest),tracked_patch_applied=True,patch_child_exit=applied.returncode,
    method='Stream every base/untracked byte; materialize and apply the binary patch to all changed tracked files; compare combined exact path set and every content hash',
    dependency_entries_verified=len(inputs['dependency_sources']),scratch=str(scratch)))

# Hardlinks only reuse immutable M2 archives; never chmod their shared inodes.
reused=['dependency-inputs.tar.gz','dependency-inputs.json','dependency-authored-sources.json',
    'dependency-generated-sources.json','cargo-package-inputs.tar.gz','cargo-index-metadata.tar.gz','cargo-inputs.json',
    'client-package-inputs.tar.gz','godot-toolchain-inputs.tar','dotnet-toolchain.tar.gz',
    'dotnet-toolchain-manifest.json','native-desktop-host-inputs.tar.gz','native-desktop-host-inputs.json',
    'client-export.tar.gz','client-qualification.json']
reused_hashes={}
assert digest(prior/'snapshot.json')=='e0207809bdff81c01bf7884601dfdc5948276442a5224267d09e0baef26c546e'
prior_descriptor=json.loads((prior/'snapshot.json').read_text())
for name in reused:
    source=prior/name
    assert source.stat().st_mode&0o222==0,name
    os.link(source,stage/name)
    reused_hashes[name]=digest(source)
    assert reused_hashes[name]==prior_descriptor['artifacts'][name],name
write(stage/'reused-m2-inputs.json',dict(boundary=str(prior),artifacts=reused_hashes,
    client_authored_inputs_verified=len(client['authored_inputs']),
    qualification_scope='Unchanged client, crypto and toolchain input bytes/evidence only; no M3b installed-client acceptance claim'))

retained_native={}
for receipt in sorted(evidence.glob('gates*-native-retention.json')):
    row=json.loads(receipt.read_text())
    for field,expected in [('archive','archive_sha256'),('manifest','manifest_sha256')]:
        path=Path(row[field]); assert digest(path)==row[expected]
        target=stage/path.name
        owned=path.stat().st_uid==os.getuid()
        if owned: os.link(path,target)
        else: shutil.copy2(path,target)
        retained_native[path.name]=dict(sha256=row[expected],storage='hardlink' if owned else 'copy')
write(stage/'retained-native-outputs.json',retained_native)

server=Path(inputs['stage'])/'source'
outputs=compiled['compiled_outputs']|compiled['native_packaged_outputs']
with tarfile.open(stage/'server-compiled-outputs.tar.gz','x:gz',dereference=False) as archive:
    for name,expected in sorted(outputs.items()):
        path=server/name
        if 'sha256' in expected: assert digest(path)==expected['sha256'],name
        else: assert str(path.readlink())==expected['symlink'],name
        archive.add(path,arcname=name,recursive=False)
providers={}
provider_expected={}
with tarfile.open(stage/'provider-compiled-outputs.tar.gz','x:gz') as archive:
    for receipt in sorted((evidence/'inputs').glob('gates[0-9][0-9]-*-objects.json')):
        provider=receipt.name[:-len('-objects.json')]
        rows=json.loads(receipt.read_text()); providers[provider]=rows
        for name,row in rows.items():
            path=Path(row['path']); assert digest(path)==row['sha256']
            archive_name=provider+'/'+name
            provider_expected[archive_name]=dict(sha256=row['sha256'],bytes=path.stat().st_size)
            archive.add(path,arcname=archive_name,recursive=False)
write(stage/'provider-compiled-outputs.json',providers)

def verify_archive(path,expected):
    seen=set()
    with tarfile.open(path,mode='r|gz') as archive:
        for member in archive:
            name=member.name;row=expected[name]
            assert name not in seen,name
            seen.add(name)
            if row.get('directory'):
                assert member.isdir(),name
            elif 'symlink' in row:
                assert member.issym() and member.linkname==row['symlink'],name
            elif member.islnk():
                assert member.linkname in seen,name
                assert expected[member.linkname]['sha256']==row['sha256'],name
                assert expected[member.linkname]['bytes']==row['bytes'],name
            else:
                assert member.isfile() and member.size==row['bytes'],name
                assert hashlib.file_digest(archive.extractfile(member),'sha256').hexdigest()==row['sha256'],name
            if 'mode' in row: assert member.mode&0o111==row['mode']&0o111,name
    assert seen==set(expected)
    return len(seen)
release_outputs=compiled['packaged_release_outputs']
with tarfile.open(stage/'local-release-outputs.tar.gz','x:gz',dereference=False) as archive:
    for name,row in sorted(release_outputs.items()):
        path=server/name
        if 'sha256' in row: assert digest(path)==row['sha256'],name
        elif 'symlink' in row: assert str(path.readlink())==row['symlink'],name
        else: assert path.is_dir(),name
        archive.add(path,arcname=name,recursive=False)
derived_outputs=compiled['derived_rebar_indexes']
with tarfile.open(stage/'derived-rebar-outputs.tar.gz','x:gz',dereference=False) as archive:
    for name,row in sorted(derived_outputs.items()):
        path=server/name
        if 'sha256' in row: assert digest(path)==row['sha256'],name
        else: assert str(path.readlink())==row['symlink'],name
        archive.add(path,arcname=name,recursive=False)
write(stage/'output-content-verification.json',dict(
    compiled_entries=verify_archive(stage/'server-compiled-outputs.tar.gz',outputs),
    derived_rebar_entries=verify_archive(stage/'derived-rebar-outputs.tar.gz',derived_outputs),
    local_release_entries=verify_archive(stage/'local-release-outputs.tar.gz',release_outputs),
    provider_original_entries=verify_archive(stage/'provider-compiled-outputs.tar.gz',provider_expected),
    exact_path_sets=True,every_content_hash_verified=True,
    includes_retained_failed_campaign_providers=True))

shutil.copy2(evidence/'inputs'/(campaign+'-compiled-manifest.json'),stage/'server-qualification.json')

(stage/'RECONSTRUCT.md').write_text('''# Reconstruct M3a

Extract base.tar.gz in an empty directory outside a Git checkout, apply
tracked.patch with `git apply --binary`, then extract untracked.tar.xz. Verify
the exact file/symlink path set, hashes, byte counts, symlink targets and execute
bits against source-manifest.json. Git preserves executable bits; the manifest
also records observed full permission modes. Apply those modes explicitly after
extraction when reproducing the original source permissions.
The source includes every tracked and non-ignored untracked entry, including
pre-existing coordination files and all retained failed/cancelled campaigns.
Ignored private stores, credentials and raw logs remain outside this boundary.

Extract dependency-inputs.tar.gz, cargo-package-inputs.tar.gz and
cargo-index-metadata.tar.gz into the reconstructed source. The dependency and
Cargo manifests distinguish authored source, generated parser annotations,
extraction/index metadata and package archives. Clean campaigns do not reuse
compiled inputs. Follow the exact gates command receipts and local builder
identity in the evidence directory. The image ID is local, not a published digest.

local-release-outputs.tar.gz preserves the entire locally built release, including
ERTS executables, configuration, scripts, resources and symlink/directory metadata.
It is a qualified output, not a deployment. derived-rebar-outputs.tar.gz separately
preserves actual Rebar indexes and PLT outputs; none was a clean input.
output-content-verification.json
records exact path sets and every archived content hash.

server-compiled-outputs.tar.gz and provider-compiled-outputs.tar.gz preserve
qualified outputs and every retained provider's original objects separately
from clean inputs. server-qualification.json distinguishes derived Rebar/PLT
indexes, generated parser sources, source inputs and compiled/native outputs.
retained-native-outputs.json also indexes the exact losslessly archived native
intermediates of closed campaigns; these are outputs, never clean build inputs.

reused-m2-inputs.json lists actual immutable archive bytes hardlinked from the
accepted M2 boundary. Their hashes and all59 unchanged client authored inputs
were checked. Existing M2 evidence documents client/crypto/toolchain recipes and
desktop host requirements. No current installed native client, Vive/XR,
controller, power-cut or non-Linux acceptance is asserted. M3b remains open.

Reconstruction verification streams every archived byte and materializes only
the changed tracked paths for a real binary patch application. It compares the
complete combined path set and every content hash without another full tree.
The snapshot is an uncommitted review boundary; it is not a deployment or commit.
''')
# Packing must not race a source edit or create a new source path.
assert tracked==names('ls-files','--cached')
assert untracked==names('ls-files','--others','--exclude-standard')
assert git('diff','--binary','HEAD')==patch.read_bytes()
for name,row in manifest.items():
    path=root/name
    if row['kind']=='symlink': assert path.is_symlink() and str(path.readlink())==row['target'],name
    else: assert path.is_file() and digest(path)==row['sha256'] and path.stat().st_size==row['bytes'],name
artifacts={p.name:dict(sha256=digest(p),bytes=p.stat().st_size) for p in sorted(stage.iterdir()) if p.is_file()}
write(stage/'snapshot.json',dict(schema='quod-m3a-immutable-v1',label=label,head=head,branch=branch,
    worker_session='8d55a3f3-e558-46e2-afbb-2e028558f371',campaign=campaign,artifacts=artifacts,
    source_entries=len(manifest),server_inputs=len(inputs['files']),
    dependency_inputs=len(inputs['dependency_sources']),cargo_packages=len(inputs['cargo_package_inputs']),
    provider_originals=sum(len(r) for r in providers.values()),compiled_outputs=len(outputs),
    packaged_release_entries=len(release_outputs),
    shared_publication=False,committed=False,m3b_complete=False))
for path in stage.iterdir():
    if path.name not in reused: path.chmod(0o444)
stage.chmod(0o555)
print(json.dumps(dict(boundary=str(stage),snapshot_sha256=digest(stage/'snapshot.json'),
    patch_sha256=digest(patch),base_sha256=digest(base),source_entries=len(manifest),
    reconstruction_verified=True)))
