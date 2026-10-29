#!/usr/bin/env python3
"""Retain a real committed Git archive with its actual producer exit."""
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time

root=Path.cwd()
evidence=Path(__file__).resolve().parent
head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
assert head=='f716ddf5e578df957a5b18421a0727a32c634f87'
assert subprocess.check_output(['git','branch','--show-current'],text=True).strip()=='worktree/pearl-stone'
target=Path('/home/yan/.cache/quod-m3b-artifacts/quod-m3b-base-'+head[:8]+'.tar.gz')
assert not target.exists()
started=time.monotonic()
with target.open('xb') as output:
    child=subprocess.Popen(['git','archive','--format=tar',head],stdout=subprocess.PIPE,stderr=subprocess.PIPE,cwd=root)
    with gzip.GzipFile(fileobj=output,mode='wb',mtime=0) as archive:
        shutil.copyfileobj(child.stdout,archive)
    stderr=child.stderr.read().decode()
    status=child.wait()
with target.open('rb') as stream: digest=hashlib.file_digest(stream,'sha256').hexdigest()
receipt=dict(head=head,path=str(target),sha256=digest,bytes=target.stat().st_size,
    git_archive_child_exit=status,stderr=stderr,elapsed_seconds=time.monotonic()-started)
(evidence/'inputs/source-base.json').write_text(json.dumps(receipt,indent=2)+'\n')
assert status==0,stderr
target.chmod(0o444)
print(json.dumps(receipt))
