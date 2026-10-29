#!/usr/bin/env python3
"""Release only the verified redundant unpacking of a closed native target."""
import hashlib
import json
from pathlib import Path
import shutil
import sys
import re

evidence=Path(__file__).resolve().parent
root=evidence.parents[2]
label=sys.argv[1]
assert re.fullmatch(r'gates[0-9]{2}',label)
receipt=json.loads((evidence/(label+'-native-retention.json')).read_text())
assert receipt['actual_content_verified'] and receipt['exact_path_set']
target=Path(receipt['source'])
assert target==root/'_build'/('m3a-'+label)/'source/native/quod_physics/target'
assert not target.is_symlink()

def digest(path):
    with path.open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()

archive=Path(receipt['archive'])
assert digest(archive)==receipt['archive_sha256']
manifest_path=Path(receipt['manifest'])
assert digest(manifest_path)==receipt['manifest_sha256']
manifest=json.loads(manifest_path.read_text())
paths={str(p.relative_to(target)):p for p in target.rglob('*')}
assert set(paths)==set(manifest)
for name,row in manifest.items():
    path=paths[name]
    if row['kind']=='file': assert digest(path)==row['sha256']
    elif row['kind']=='symlink': assert path.is_symlink() and str(path.readlink())==row['target']
    else: assert path.is_dir()
output=evidence/(label+'-native-release.json')
assert not output.exists()
shutil.rmtree(target)
output.write_text(json.dumps(dict(
    action='Lossless relocation to verified archive; original bytes and exact path set retained',
    source=str(target),archive=str(archive),archive_sha256=receipt['archive_sha256'],
    manifest_sha256=receipt['manifest_sha256'],entries=len(manifest),
    unpacked_released=True),indent=2)+'\n')
print('Closed '+label+' native target retained; redundant unpacking released')
