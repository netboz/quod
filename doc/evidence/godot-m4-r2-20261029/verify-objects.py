#!/usr/bin/env python3
"""Independently verify every supplied/generated/dependency object and index."""
import hashlib,json,os,sys
from pathlib import Path,PurePosixPath

boundary=Path(sys.argv[1]);manifest=json.loads((boundary/'object-groups.json').read_text())
origins=json.loads((boundary/'object-group-origins.json').read_text())
receipt_path=Path(sys.argv[2]) if len(sys.argv)==3 else boundary/'independent-object-verification.json'
objects=boundary/'objects';expected=set();counts={};bytes_indexed=0
for group,rows in manifest.items():
    origin=Path(origins[group]['root']);assert origin.is_dir(),str(origin)
    actual_paths=set()
    if origins[group]['scope'].startswith('complete-tree'):
        for directory,dirs,files in os.walk(origin,followlinks=False):
            parent=Path(directory)
            for name in list(dirs):
                p=parent/name;actual_paths.add(str(p.relative_to(origin)))
                if p.is_symlink():dirs.remove(name)
            actual_paths.update(str((parent/name).relative_to(origin)) for name in files)
    else:
        for owner in origin.glob('quod-m4-live-*'):
            actual_paths.update(str(p.relative_to(origin)) for p in list(owner.glob('*.erl'))+list((owner/'ebin').glob('*.beam'))+list((owner/'predicates-ebin').glob('*.beam')))
    assert actual_paths==set(rows),(group,'original output path set differs')
    names=set()
    for name,row in rows.items():
        p=PurePosixPath(name);assert not p.is_absolute() and '..' not in p.parts,name
        assert name not in names;names.add(name)
        assert 0<=row['mode']<=0o7777,name
        original=origin/name;assert original.lstat().st_mode&0o7777==row['mode'],(group,name,'original mode')
        if row['kind']=='file':
            assert original.is_file() and not original.is_symlink(),(group,name)
            with original.open('rb') as stream:assert hashlib.file_digest(stream,'sha256').hexdigest()==row['sha256'],(group,name,'original bytes')
            assert row['bytes']>=0 and len(row['sha256'])==64
            expected.add(row['sha256']);bytes_indexed+=row['bytes']
        elif row['kind']=='symlink':
            assert isinstance(row['target'],str)
            assert original.is_symlink() and str(original.readlink())==row['target'],(group,name)
            if 'resolved_sha256' in row:
                expected.add(row['resolved_sha256'])
                with original.open('rb') as stream:assert hashlib.file_digest(stream,'sha256').hexdigest()==row['resolved_sha256'],(group,name,'resolved dependency bytes')
        else:assert row['kind']=='directory' and original.is_dir() and not original.is_symlink(),name
    counts[group]=len(rows)
actual={p.name for p in objects.iterdir()};assert actual==expected,'Object path set differs'
unique_bytes=0
for sha in sorted(expected):
    path=objects/sha;assert path.is_file() and not path.is_symlink()
    with path.open('rb') as stream:assert hashlib.file_digest(stream,'sha256').hexdigest()==sha,sha
    unique_bytes+=path.stat().st_size
for group,rows in manifest.items():
    for name,row in rows.items():
        if row['kind']=='file':assert (objects/row['sha256']).stat().st_size==row['bytes'],(group,name)
receipt={'method':'Independent complete output/dependency index, actual object path set, every byte hash and per-path type/link/mode validation',
    'groups':counts,'logical_entries':sum(counts.values()),'indexed_file_bytes':bytes_indexed,'unique_objects':len(expected),'unique_bytes':unique_bytes,
    'exact_object_path_set':True,'every_content_verified':True,'all_recorded_links_and_modes_verified':True,'every_live_or_staged_output_path_content_link_mode_independently_compared':True,
    'note':'Complete source is separately materialized with the actual binary patch. Output/dependency objects preserve actual bytes and exact path/link/mode indices, not hashes alone.'}
receipt_path.write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt))
