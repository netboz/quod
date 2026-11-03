"""Materialize only the verified pinned source and private build tool on /data."""
import hashlib,json,os,stat,tarfile,zipfile
from pathlib import Path
from environment import TASK
os.umask(0o077)
archive=TASK/'downloads/godot-4.7.2-stable.tar.xz'
assert hashlib.sha256(archive.read_bytes()).hexdigest()=='a18ce0ccec3ecc40b0dd6c4f5132ca934e9fb7c2979717940ff32aee1eb35481'
build=TASK/'builds/engine01';build.mkdir(exist_ok=False)
with tarfile.open(archive) as t:t.extractall(build,filter='data')
source=build/'godot-4.7.2-stable'
manifest=[]
for p in sorted(source.rglob('*')):
    st=p.lstat();row={'path':str(p.relative_to(source)),'mode':stat.S_IMODE(st.st_mode)}
    if p.is_symlink():row.update(type='symlink',target=os.readlink(p))
    elif p.is_dir():row['type']='directory'
    elif p.is_file():row.update(type='file',bytes=st.st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
    else:raise RuntimeError('Unexpected source type')
    manifest.append(row)
(build/'original-source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
wheel=TASK/'downloads/scons-4.11.1-py3-none-any.whl'
assert hashlib.sha256(wheel.read_bytes()).hexdigest()=='454cef364348053422696e3d2ecb4fa593c96a624f955842eaaea64f95c8d11d'
tool=TASK/'cache/tools/scons-4.11.1';tool.mkdir(parents=True,exist_ok=False)
with zipfile.ZipFile(wheel) as z:
    for name in z.namelist():assert not name.startswith('/') and '..' not in Path(name).parts
    z.extractall(tool)
print(json.dumps({'source':str(source),'entries':len(manifest),'source_manifest_sha256':hashlib.sha256((build/'original-source-manifest.json').read_bytes()).hexdigest(),'tool':str(tool)}))
