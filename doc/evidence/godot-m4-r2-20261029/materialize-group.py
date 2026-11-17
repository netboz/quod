#!/usr/bin/env python3
"""Materialize and independently check a complete frozen output/dependency group."""
import hashlib,json,os,shutil,subprocess,sys
from pathlib import Path,PurePosixPath
boundary=Path(sys.argv[1]);group=sys.argv[2];destination=Path(sys.argv[3]);receipt=Path(sys.argv[4])
rows=json.loads((boundary/'object-groups.json').read_text())[group]
destination.mkdir(mode=0o700,exist_ok=False)
assert subprocess.run(['git','rev-parse','--show-toplevel'],cwd=destination,capture_output=True).returncode!=0
def target(name):
    p=PurePosixPath(name);assert not p.is_absolute() and '..' not in p.parts
    path=destination/name
    for parent in reversed(path.parents):
        if parent==destination or destination in parent.parents:assert not parent.is_symlink(),name
    path.parent.mkdir(mode=0o700,parents=True,exist_ok=True);return path
for name,row in sorted(rows.items(),key=lambda v:(len(PurePosixPath(v[0]).parts),v[0])):
    path=target(name)
    if row['kind']=='directory':path.mkdir(mode=0o700,exist_ok=True)
    elif row['kind']=='symlink':path.symlink_to(row['target'])
    else:
        shutil.copyfile(boundary/'objects'/row['sha256'],path);path.chmod(row['mode'])
for name,row in sorted(rows.items(),key=lambda v:len(PurePosixPath(v[0]).parts),reverse=True):
    if row['kind']=='directory':(destination/name).chmod(row['mode'])
actual={}
for directory,dirs,files in os.walk(destination,followlinks=False):
    parent=Path(directory)
    for name in list(dirs):
        p=parent/name;actual[str(p.relative_to(destination))]=p
        if p.is_symlink():dirs.remove(name)
    actual.update({str((parent/name).relative_to(destination)):parent/name for name in files})
assert set(actual)==set(rows),'Materialized path set differs'
for name,row in rows.items():
    p=actual[name];assert p.lstat().st_mode&0o7777==row['mode'],name
    if row['kind']=='symlink':assert p.is_symlink() and str(p.readlink())==row['target'],name
    elif row['kind']=='directory':assert p.is_dir() and not p.is_symlink(),name
    else:
        assert p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'],name
        with p.open('rb') as stream:assert hashlib.file_digest(stream,'sha256').hexdigest()==row['sha256'],name
result={'group':group,'workspace':str(destination),'outside_every_checkout':True,'entries':len(rows),'exact_path_set':True,
    'every_content_link_and_full_mode_verified':True,'actual_file_bytes_materialized':True,
    'absolute_links':'Original targets retained exactly; resolved file bytes are also preserved in the object store. Host OS/display/private-data prerequisites remain separate.'}
receipt.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
