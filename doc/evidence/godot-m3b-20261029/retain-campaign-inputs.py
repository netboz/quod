#!/usr/bin/env python3
"""Retain exact closed-campaign authored deltas and current compiled outputs."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

evidence=Path(__file__).resolve().parent
root=evidence.parents[2]
labels=sys.argv[1:]
base_manifest=evidence/'inputs/committed-gate-input-hashes.json'
if base_manifest.exists(): base_hashes=json.loads(base_manifest.read_text())
else:
    listing=subprocess.check_output(['git','ls-tree','-rz','HEAD'],cwd=root)
    entries={}
    for row in listing.split(b'\0'):
        if not row:continue
        meta,name=row.split(b'\t',1);mode,kind,oid=meta.split()
        if kind==b'blob':entries[name.decode()]=oid
    selected=set()
    for label in labels:
        selected.update(json.loads((evidence/'inputs'/(label+'-source-manifest.json')).read_text())['files'])
    ordered=sorted(selected&entries.keys())
    data=subprocess.check_output(['git','cat-file','--batch'],cwd=root,
        input=b''.join(entries[n]+b'\n' for n in ordered))
    at=0;base_hashes={}
    for name in ordered:
        end=data.index(b'\n',at);header=data[at:end].split();size=int(header[2]);at=end+1
        blob=data[at:at+size];assert len(blob)==size
        base_hashes[name]=hashlib.sha256(blob).hexdigest();at+=size
        assert data[at:at+1]==b'\n';at+=1
    assert at==len(data)
    base_manifest.write_text(json.dumps(base_hashes,indent=2)+'\n')
for label in labels:
    closed=json.loads((evidence/(label+'-result.json')).read_text())
    assert closed['results'] and closed['completed_gates']==len(closed['results'])
    manifest=json.loads((evidence/'inputs'/(label+'-source-manifest.json')).read_text())
    source=Path(manifest['stage'])/'source'
    output=evidence/'inputs'/(label+'-authored-delta.json')
    assert not output.exists()
    changed={}
    for name,expected in manifest['files'].items():
        path=source/name
        assert hashlib.sha256(path.read_bytes()).hexdigest()==expected,name
        if base_hashes.get(name)==expected:continue
        saved=evidence/'inputs'/(label+'-authored-files')/name
        saved.parent.mkdir(parents=True,exist_ok=True)
        assert not saved.exists();shutil.copy2(path,saved)
        changed[name]=dict(path=str(saved.relative_to(evidence)),sha256=expected)
    output.write_text(json.dumps(dict(head=manifest['head'],base_archive='inputs/source-base.json',
        base_hashes='inputs/committed-gate-input-hashes.json',
        exact_selected_path_set=label+'-source-manifest.json',replacement_files=changed,
        reconstruction='Extract the committed base archive, overlay these actual replacement blobs, then select exactly the manifest file paths. Verify every selected SHA256. Dependency/package inputs remain separately retained.'),indent=2)+'\n')
    objects={}
    for profile in ['default','test','prod']:
        lib=source/'_build'/profile/'lib'
        for path in lib.rglob('*'):
            if not path.is_file() or path.is_symlink() or path.suffix not in ('.beam','.app','.so','.boot','.rel','.script'):continue
            name=str(path.relative_to(source));objects[name]=dict(path=str(path),sha256=hashlib.sha256(path.read_bytes()).hexdigest())
    native=source/'priv/native/quod_physics.so'
    if native.is_file():objects[str(native.relative_to(source))]=dict(path=str(native),sha256=hashlib.sha256(native.read_bytes()).hexdigest())
    compiled=evidence/'inputs'/(label+'-closed-profile-objects.json')
    assert not compiled.exists();compiled.write_text(json.dumps(objects,indent=2)+'\n')
    print(json.dumps(dict(label=label,selected_authored_inputs=len(manifest['files']),
                         retained_changed_blobs=len(changed),closed_profile_outputs=len(objects))))
