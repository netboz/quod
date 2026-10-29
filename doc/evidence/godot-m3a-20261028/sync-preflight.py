#!/usr/bin/env python3
"""Retain each focused input before updating the isolated incremental build."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

evidence = Path(__file__).resolve().parent
root = evidence.parents[2]
work = root / '_build/m3a-preflight01/source'
previous, label, *delta_base = sys.argv[1:]
manifest = json.loads((evidence / 'inputs' / (previous + '-source.json')).read_text())
archive = evidence / 'inputs' / (previous + '-authored.tar.gz')
if delta_base:
    archive=evidence/'inputs'/(delta_base[0]+'-authored.tar.gz')
    retained={}
    with tarfile.open(archive) as base:
        members={m.name:m for m in base if m.isfile()}
        for name,digest in manifest['files'].items():
            path=work/name
            assert hashlib.sha256(path.read_bytes()).hexdigest()==digest,name
            member=members.get(name)
            if member is None or hashlib.sha256(base.extractfile(member).read()).hexdigest()!=digest:
                saved=evidence/'inputs'/(previous+'-files')/name
                saved.parent.mkdir(parents=True,exist_ok=True)
                assert not saved.exists(),saved
                shutil.copy2(path,saved)
                retained[name]=str(saved.relative_to(evidence))
    (evidence/'inputs'/(previous+'-delta.json')).write_text(json.dumps(dict(
        base_archive=str(archive),base_archive_sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
        replacement_files=retained,exact_path_set_manifest=previous+'-source.json'),indent=2)+'\n')
else:
    with tarfile.open(archive, 'x:gz') as output:
        for name, digest in manifest['files'].items():
            path = work / name
            assert hashlib.sha256(path.read_bytes()).hexdigest() == digest, name
            output.add(path, arcname=name)
names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root).decode().split('\0')
selected = set(manifest['files'])
selected.update(n for n in names if n.startswith(('src/', 'test/', 'include/', 'priv/', 'native/', 'scripts/')))
for name in sorted(selected):
    source = root / name
    if source.is_file():
        destination = work / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
record = dict(kind='incremental focused preflight; compiled outputs reused, not a clean gate',
    base_head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
    files={n: hashlib.sha256((work/n).read_bytes()).hexdigest() for n in sorted(selected) if (root/n).is_file()},
    previous_authored_archive=str(archive), previous_archive_sha256=hashlib.sha256(archive.read_bytes()).hexdigest())
(evidence / 'inputs' / (label + '-source.json')).write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps(dict(label=label, inputs=len(record['files']), preserved=str(archive))))
