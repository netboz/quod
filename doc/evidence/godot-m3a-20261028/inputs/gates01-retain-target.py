#!/usr/bin/env python3
"""Losslessly package one closed campaign's native intermediates before release."""
import gzip
import hashlib
import json
from pathlib import Path
import sys
import tarfile

evidence=Path(__file__).resolve().parent
root=evidence.parents[2]
label=sys.argv[1]
assert label=='gates01'
verify_existing=sys.argv[2:]==['--verify-existing']
closed=json.loads((evidence/(label+'-result.json')).read_text())
assert closed['source_unchanged'] and not closed['all_true_exits_zero']
target=root/'_build'/('m3a-'+label)/'source/native/quod_physics/target'
retained=root/'_build/m3a-retained'
retained.mkdir(mode=0o700,exist_ok=True)
archive=retained/(label+'-native-target.tar.gz')
assert archive.exists() if verify_existing else not archive.exists()

def digest(path):
    with path.open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()

manifest={}
for p in sorted(target.rglob('*')):
    name=str(p.relative_to(target))
    if p.is_symlink(): manifest[name]=dict(kind='symlink',target=str(p.readlink()))
    elif p.is_file(): manifest[name]=dict(kind='file',sha256=digest(p),bytes=p.stat().st_size,mode=p.stat().st_mode&0o777)
    elif p.is_dir(): manifest[name]=dict(kind='directory',mode=p.stat().st_mode&0o777)
    else: raise ValueError(name)
if not verify_existing:
    with archive.open('xb') as stream:
        with gzip.GzipFile(fileobj=stream,mode='wb',compresslevel=1,mtime=0) as compressed:
            with tarfile.open(fileobj=compressed,mode='w|') as out:
                for name in manifest: out.add(target/name,arcname=name,recursive=False)
seen=set()
with tarfile.open(archive,mode='r|gz') as source:
    for member in source:
        name=member.name
        row=manifest[name]
        assert name not in seen
        seen.add(name)
        if row['kind']=='file':
            if member.islnk():
                assert member.linkname in seen
                original=manifest[member.linkname]
                assert original['kind']=='file'
                assert (original['bytes'],original['sha256'])==(row['bytes'],row['sha256'])
            else:
                assert member.isfile() and member.size==row['bytes']
                assert hashlib.file_digest(source.extractfile(member),'sha256').hexdigest()==row['sha256']
            assert digest(target/name)==row['sha256']
        elif row['kind']=='symlink': assert member.issym() and member.linkname==row['target']
        else: assert member.isdir()
assert seen==set(manifest)
manifest_path=retained/(label+'-native-target-manifest.json')
manifest_path.write_text(json.dumps(manifest,indent=2)+'\n')
receipt=dict(source=str(target),archive=str(archive),archive_sha256=digest(archive),
    manifest=str(manifest_path),manifest_sha256=digest(manifest_path),entries=len(manifest),
    actual_content_verified=True,exact_path_set=True,unpacked_released=False)
(evidence/(label+'-native-retention.json')).write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt))
