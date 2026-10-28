#!/usr/bin/env python3
"""Immutable review/source snapshot, retaining full source and reconstruction."""
import hashlib,json,os,re,shutil,subprocess,tarfile
from pathlib import Path
root=Path(__file__).resolve().parents[3]
evidence=Path(__file__).resolve().parent
private=Path('/tmp/quod-m1a-private-logs-922c7c06-20261027-01')
private.mkdir(mode=0o700,exist_ok=False)
redactions=[]
pattern=re.compile(rb'<<\s*(\d+(?:,\s*\d+)*)\s*>>')
for log in sorted((evidence/'logs').glob('*.log')):
 raw=log.read_bytes();counter=[0]
 def redact(m):
  values=re.findall(rb'\d+',m[1])
  if len(values) in [32,64] and all(int(n)<256 for n in values):
   counter[0]+=1;return b'<<REDACTED_DISPOSABLE_BINARY_'+str(len(values)).encode()+b'>>'
  return m[0]
 clean=pattern.sub(redact,raw)
 if clean!=raw:
  target=private/log.name;target.write_bytes(raw);target.chmod(0o600)
  log.write_bytes(clean)
  redactions.append(dict(file=str(log.relative_to(root)),raw_sha256=hashlib.sha256(raw).hexdigest(),
    redacted_sha256=hashlib.sha256(clean).hexdigest(),replacements=counter[0]))
(evidence/'log-redactions-01.json').write_text(json.dumps(dict(private_originals=str(private),
  rule='All numeric Erlang binaries of exactly 32 or 64 bytes, including public identifiers, are removed to exclude random disposable secret seeds from exported source/evidence.',files=redactions),indent=2)+'\n')
stage=Path('/tmp/quod-godot-m1a-review-922c7c06-20261027-01')
stage.mkdir(mode=0o755,exist_ok=False)
head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root).decode().strip()
branch=subprocess.check_output(['git','branch','--show-current'],cwd=root).decode().strip()
tracked=subprocess.check_output(['git','ls-files','-z'],cwd=root).decode().split('\0')
untracked=subprocess.check_output(['git','ls-files','--others','--exclude-standard','-z'],cwd=root).decode().split('\0')
patch=subprocess.check_output(['git','diff','--binary','HEAD'],cwd=root)
(stage/'tracked.patch').write_bytes(patch)
base=stage/'base.tar'
with base.open('wb') as output:subprocess.run(['git','archive','HEAD'],cwd=root,stdout=output,check=True)
tree=stage/'review-tree';tree.mkdir()
with tarfile.open(base) as archive:archive.extractall(tree,filter='data')
manifest=[]
for name in sorted(set(tracked+untracked)):
 if not name:continue
 src=root/name;dst=tree/name
 if not src.exists() and not src.is_symlink():
  if dst.exists():dst.unlink()
  continue
 dst.parent.mkdir(parents=True,exist_ok=True)
 if dst.is_symlink() or dst.is_file():dst.unlink()
 if src.is_symlink():
  target=os.readlink(src);dst.symlink_to(target)
  manifest.append(dict(path=name,kind='symlink',target=target,tracked=name in tracked))
 elif src.is_file():
  shutil.copy2(src,dst)
  manifest.append(dict(path=name,kind='file',sha256=hashlib.sha256(src.read_bytes()).hexdigest(),
    bytes=src.stat().st_size,mode=oct(src.stat().st_mode&0o777),tracked=name in tracked))
with tarfile.open(stage/'untracked.tar.gz','w:gz') as archive:
 for name in sorted(untracked):
  if name and (root/name).is_file():archive.add(root/name,arcname=name,recursive=False)
(stage/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
(stage/'RECONSTRUCT.md').write_text('''# Reconstruction

The review-tree is a complete materialized source tree; it has no .git directory.
Alternatively, extract base.tar into an empty directory, apply tracked.patch
with git apply --binary, then extract untracked.tar.gz there. Verify every current
entry against source-manifest.json (deleted tracked paths are represented by the
patch). This snapshot contains source, archived originals and sanitized retained
evidence, not a clean compiled build. It excludes ignored build/dependency caches
and private credential files. Raw disposable test-log seeds are retained only in
a separate permission-restricted directory named by the redaction manifest, not
in this snapshot. M0 evidence is copied unchanged. The local builder identity is
not a published repository digest. No commit or deployment is implied.
''')
info=dict(label=stage.name,head=head,branch=branch,worker_session='922c7c06-1acb-4c2b-9141-fccf4ab4c947',
 complete_M1a=False,clean_final_gates_run=False,files=len(manifest),tracked_patch_sha256=hashlib.sha256(patch).hexdigest(),
 artifacts={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [base,stage/'untracked.tar.gz',stage/'source-manifest.json',stage/'RECONSTRUCT.md']})
(stage/'snapshot.json').write_text(json.dumps(info,indent=2)+'\n')
# All snapshot bytes are write-protected after materialization. No hardlinks to
# the live worktree are used. Later fixes require another separately named input.
for path in stage.rglob('*'):
 if not path.is_symlink():path.chmod(0o555 if path.is_dir() else 0o444)
stage.chmod(0o555)
print(json.dumps(dict(path=str(stage),snapshot_sha256=hashlib.sha256((stage/'snapshot.json').read_bytes()).hexdigest(),entries=len(manifest))))
