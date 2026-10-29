#!/usr/bin/env python3
"""Preserve artifact bytes while giving our retained files the caller's owner."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys

evidence=Path(__file__).resolve().parent
root=evidence.parents[2]
label=sys.argv[1]
assert label in ['gates01','gates02']
receipt=json.loads((evidence/(label+'-native-retention.json')).read_text())
output=evidence/(label+'-native-output-ownership.json')
assert not output.exists()

def digest(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()

rows=[]
for field,expected in [('archive','archive_sha256'),('manifest','manifest_sha256')]:
    path=Path(receipt[field])
    assert path.parent==root/'_build/m3a-retained' and path.name.startswith(label+'-native-target')
    before=path.stat()
    assert not path.is_symlink() and before.st_nlink==1
    assert digest(path)==receipt[expected]
    if before.st_uid!=os.getuid():
        copy=path.with_name(path.name+'.owned-copy')
        assert not copy.exists()
        with path.open('rb') as source,copy.open('xb') as target: shutil.copyfileobj(source,target)
        shutil.copystat(path,copy)
        assert digest(copy)==receipt[expected]
        os.replace(copy,path)
    assert digest(path)==receipt[expected] and path.stat().st_uid==os.getuid()
    path.chmod(0o444)
    rows.append(dict(path=str(path),sha256=receipt[expected],bytes=before.st_size,
        original_uid=before.st_uid,current_uid=path.stat().st_uid,logical_path_preserved=True,
        content_bytes_unchanged=True))
output.write_text(json.dumps(rows,indent=2)+'\n')
print(json.dumps(rows))
