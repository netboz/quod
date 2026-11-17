#!/usr/bin/env python3
"""Freeze exact M4 source and outputs; share verified immutable prerequisites."""
import argparse,hashlib,json,os,shutil,subprocess,tarfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('boundary');a=p.parse_args()
root=Path.cwd();evidence=Path(__file__).resolve().parent;boundary=Path(a.boundary)
assert not boundary.exists(),'Retain every earlier boundary'
def digest(path):
 with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def write(path,value):path.write_text(json.dumps(value,indent=2)+'\n')
def git(*args):return subprocess.check_output(['git',*args],cwd=root)
def names(*args):return set(filter(None,git(*args,'-z').decode().split('\0')))
def entry(path):
 if path.is_symlink():return dict(symlink=str(path.readlink()))
 if path.is_dir():return dict(directory=True,mode=path.stat().st_mode&0o777)
 return dict(sha256=digest(path),bytes=path.stat().st_size,mode=path.stat().st_mode&0o777)
head=git('rev-parse','HEAD').decode().strip();branch=git('branch','--show-current').decode().strip()
assert head=='293cf6115c0a6b18315eccdbb42cbca396f443d3' and branch=='worktree/pearl-stone'
assert not git('diff','--cached','--name-only')
qualification=json.loads((evidence/'final06-result.json').read_text());assert qualification['passed'] and qualification['source_unchanged']
client=json.loads((evidence/'inputs/client-candidate09-manifest.json').read_text());assert client['passed']
for n,h in client['authored_inputs'].items():assert digest(root/n)==h and digest(Path(client['source'])/n)==h,n
tracked=names('ls-files','--cached');untracked=names('ls-files','--others','--exclude-standard');manifest={}
for n in sorted(tracked|untracked):
 path=root/n
 if not path.exists() and not path.is_symlink():continue
 row=entry(path);assert not row.get('directory'),n
 manifest[n]=dict(kind='symlink',target=row['symlink'],tracked=n in tracked) if 'symlink' in row else dict(kind='file',**row,tracked=n in tracked)
boundary.mkdir(mode=0o755,parents=True)
patch=boundary/'tracked.patch';patch.write_bytes(git('diff','--binary','HEAD'));write(boundary/'source-manifest.json',manifest)
write(boundary/'source-status.json',dict(head=head,branch=branch,parent=git('rev-parse','HEAD^').decode().strip(),original_branch_base='f6c29fe925e666dd68ee7fa68c0e03f5d03391a2',worker_session='ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f',status=git('status','--short').decode(),committed=False,sole_implementation_writer=True,implementation_frozen=True,model='openai-codex:gpt-6.1-sol',launcher_effort='max',effective_backend_effort='Not exposed by installed API',preserved_preexisting=['.agents/ (31 generated files)','nimbalyst-local/handoffs/godot-m4-prompt.md']))
base=json.loads((evidence/'inputs/source-base.json').read_text());assert base['head']==head and base['git_archive_child_exit']==0 and digest(Path(base['path']))==base['sha256']
assert Path(base['path']).stat().st_mode&0o222==0;os.link(base['path'],boundary/'base.tar.gz')
with tarfile.open(boundary/'untracked.tar.xz','x:xz',preset=6) as archive:
 for n in sorted(untracked):archive.add(root/n,arcname=n,recursive=False)
verified={}
def archive_rows(name,source,rows):
 target=boundary/name
 with tarfile.open(target,'x:gz',dereference=False) as archive:
  for relative,row in sorted(rows.items()):
   path=source/relative;assert entry(path)==row,(relative,'changed output');archive.add(path,arcname=relative,recursive=False)
 seen=set()
 with tarfile.open(target,'r|gz') as archive:
  for member in archive:
   n=member.name;row=rows[n];assert n not in seen;seen.add(n)
   if row.get('directory'):assert member.isdir(),n
   elif 'symlink' in row:assert member.issym() and member.linkname==row['symlink'],n
   elif member.islnk():assert member.linkname in seen and rows[member.linkname]['sha256']==row['sha256'] and rows[member.linkname]['bytes']==row['bytes'],n
   else:assert member.isfile() and member.size==row['bytes'] and hashlib.file_digest(archive.extractfile(member),'sha256').hexdigest()==row['sha256'],n
   if 'mode' in row:assert member.mode&0o777==row['mode'],n
 assert seen==set(rows),name
 verified[name]=dict(entries=len(rows),exact_path_set=True,every_content_hash_verified=True,full_modes_verified=True)
 write(boundary/(name+'.json'),rows)
 return target
client_source=Path(client['source']);export={n:entry(client_source/n) for n in client['export_outputs']}
for n,row in client['export_outputs'].items():assert (export[n]['sha256'],export[n]['bytes'])==(row['sha256'],row['bytes']),n
archive_rows('client-export.tar.gz',client_source,export)
artifacts=Path('/tmp/quod-m4-ca84d4f8/artifacts');generated={};retained_inputs={}
for receipt in sorted((evidence/'inputs').glob('client-*-manifest.json')):
 build=json.loads(receipt.read_text());build_source=Path(build['source']);prefix=build_source.relative_to(artifacts)
 for n,h in build['authored_inputs'].items():
  path=build_source/n;assert digest(path)==h,n;retained_inputs[str(prefix/n)]=entry(path)
 for parent in ['client/godot/.godot','client/godot-tests/bin','client/godot-tests/obj']:
  folder=build_source/parent
  if not folder.exists():continue
  generated[str(folder.relative_to(artifacts))]=entry(folder)
  for path in sorted(folder.rglob('*')):generated[str(path.relative_to(artifacts))]=entry(path)
archive_rows('all-client-build-outputs.tar.gz',artifacts,generated)
archive_rows('all-client-supplied-inputs.tar.gz',artifacts,retained_inputs)
private=artifacts/'private';providers={}
for owner in sorted(private.glob('quod-m4-live-*')):
 for path in list(owner.glob('*.erl'))+list((owner/'ebin').glob('*.beam'))+list((owner/'predicates-ebin').glob('*.beam')):providers[str(path.relative_to(private))]=entry(path)
archive_rows('fixture-code-and-provider-outputs.tar.gz',private,providers)
upstream=Path('/tmp/quod-m4-ca84d4f8/upstream');inspected={str(path.relative_to(upstream)):entry(path) for path in sorted(upstream.rglob('*')) if path.is_file()}
archive_rows('inspected-engine-source.tar.gz',upstream,inspected)
prior=Path('/home/yan/.cache/quod-m3b-artifacts/quod-godot-m3b-handoff-8b352c53-20261029-02')
assert digest(prior/'snapshot.json')=='bda8941e95012e55786fc93f95e5c3ce73ce6dcf1a35ccfc275b73cfcbbde80c'
descriptor=json.loads((prior/'snapshot.json').read_text());shared=set();predecessors={}
for path in sorted(prior.iterdir()):
 assert path.is_file() and path.stat().st_mode&0o222==0,path
 actual=digest(path);expected=descriptor['artifacts'].get(path.name)
 if expected is not None:assert actual==(expected['sha256'] if isinstance(expected,dict) else expected),path
 name='prerequisite-m3b-'+path.name;os.link(path,boundary/name);shared.add(name);predecessors[path.name]=dict(sha256=actual,bytes=path.stat().st_size)
write(boundary/'prerequisite-m3b.json',dict(boundary=str(prior),descriptor_sha256=digest(prior/'snapshot.json'),actual_immutable_artifacts=predecessors,meaning='Verified read-only hardlinks to actual predecessor source, dependency/toolchain archives, server/native/release outputs and prior evidence. No compiled output was a clean build input.'))
write(boundary/'clean-inputs.json',dict(client_inputs=client['authored_inputs'],input_classes=client['input_classes'],client_dependency_archives=client['dependency_archives'],engine_archives=client['engine_archives'],unchanged_server_inputs='prerequisite-m3b-clean-inputs.json',compiled_application_inputs_copied=False))
write(boundary/'output-content-verification.json',verified);write(boundary/'client-qualification.json',client)
(boundary/'RECONSTRUCT.md').write_text('''# Reconstruct M4

Outside every checkout, extract base.tar.gz (HEAD293cf6115), apply tracked.patch
with real git apply --binary, then extract untracked.tar.xz. The included
verify-reconstruction.py independently materializes the complete path set,
checks every byte/hash, executable bit and symlink target, then restores and
checks every full recorded mode. Use a fresh destination for each run.
An optional third verifier argument writes its receipt outside the immutable
boundary, allowing later independent verification without modifying it.

All source, inherited generated .agents files, coordinator prompt and failed
evidence are included. clean-inputs.json distinguishes authored client sources,
persistent generated UID seeds, fixtures, dependency archives and outputs.
The complete final export and all source-only client build intermediates are
separately archived with path/content/mode verification. Known test-factory
source and compiled providers are retained; private keys, stores and raw logs
are excluded. Development workspace exports were mutable; candidate09 / final06 is the
final source-only campaign. Read-only prerequisite-m3b-* hardlinks share actual
immutable dependency/toolchain and unchanged qualified server output bytes.
Their historical precommit labels remain provenance; M3b is now committed at
the M4 base. Do not apply the old M3b patch over HEAD293cf6115.

This is an uncommitted software review boundary. Native installed-runtime and
physical Vive/QUO-27 teardown obligations remain unqualified. No Quest pass,
network change, deployment or full M4 acceptance is claimed.
''')
scratch=boundary.parent/(boundary.name+'-complete-reconstruction')
child=subprocess.run(['python3',str(evidence/'verify-reconstruction.py'),str(boundary),str(scratch)]);assert child.returncode==0
assert tracked==names('ls-files','--cached') and untracked==names('ls-files','--others','--exclude-standard')
assert patch.read_bytes()==git('diff','--binary','HEAD')
for n,row in manifest.items():
 path=root/n
 if row['kind']=='symlink':assert path.is_symlink() and str(path.readlink())==row['target'],n
 else:assert entry(path)=={key:row[key] for key in ['sha256','bytes','mode']},n
files={path.name:dict(sha256=digest(path),bytes=path.stat().st_size) for path in sorted(boundary.iterdir()) if path.is_file()}
write(boundary/'snapshot.json',dict(schema='quod-m4-immutable-v1',head=head,branch=branch,worker_session='ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f',artifacts=files,source_entries=len(manifest),client_inputs=len(client['authored_inputs']),client_exports=len(export),committed=False,full_m4_accepted=False,shared_body_publication=False))
for path in boundary.iterdir():
 if path.name not in shared and path.name!='base.tar.gz':path.chmod(0o444)
boundary.chmod(0o555)
print(json.dumps(dict(boundary=str(boundary),descriptor_sha256=digest(boundary/'snapshot.json'),patch_sha256=digest(patch),base_sha256=digest(boundary/'base.tar.gz'),source_entries=len(manifest),client_inputs=len(client['authored_inputs']),exports=len(export))),flush=True)
