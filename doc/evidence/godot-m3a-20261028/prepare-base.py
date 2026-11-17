#!/usr/bin/env python3
"""Retain the immutable committed base independently of running server gates."""
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

evidence=Path(__file__).resolve().parent
root=evidence.parents[2]
head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
assert head=='69196a36caeeb06e6ee07982f1ab1988d7c16b43'
path=root/'_build/m3a-retained'/('base-'+head+'.tar.gz')
path.parent.mkdir(mode=0o700,exist_ok=True)
assert not path.exists()
with path.open('xb') as raw:
    with gzip.GzipFile(fileobj=raw,filename='',mode='wb',mtime=0) as out:
        child=subprocess.Popen(['git','archive',head],cwd=root,stdout=subprocess.PIPE)
        try: shutil.copyfileobj(child.stdout,out)
        finally: child.stdout.close()
        status=child.wait()
assert status==0
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()==head
with path.open('rb') as stream: sha=hashlib.file_digest(stream,'sha256').hexdigest()
receipt=dict(head=head,path=str(path),sha256=sha,bytes=path.stat().st_size,git_archive_child_exit=status)
output=evidence/'inputs/source-base.json'
assert not output.exists()
output.write_text(json.dumps(receipt,indent=2)+'\n')
path.chmod(0o444)
print(json.dumps(receipt))
