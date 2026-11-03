"""Retain the native build interpreter's standard library and loaded-library inputs.

Conservative stdlib collection excludes third-party site-packages and user
directories; the separately pinned SCons wheel supplies the actual build tool.
"""
import hashlib,json,os,re,shutil,subprocess,sys,sysconfig
from pathlib import Path
from environment import TASK
out=TASK/'artifacts/python-stdlib-inputs02';out.mkdir(mode=0o700,exist_ok=False)
objects=out/'objects';objects.mkdir();rows={};commands=[]
def retain(p):
    p=Path(p)
    if str(p) in rows:return
    r={'mode':p.lstat().st_mode&0o7777}
    if p.is_symlink():r.update(kind='symlink',target=os.readlink(p));rows[str(p)]=r;retain(p.resolve());return
    if p.is_dir():r['kind']='directory';rows[str(p)]=r;return
    assert p.is_file(),p
    with p.open('rb') as stream:digest=hashlib.file_digest(stream,'sha256').hexdigest()
    target=objects/digest
    if not target.exists():
        shutil.copyfile(p,target)
        with target.open('rb') as stream:assert hashlib.file_digest(stream,'sha256').hexdigest()==digest
        target.chmod(0o444)
    r.update(kind='file',sha256=digest,bytes=p.stat().st_size);rows[str(p)]=r
stdlib=Path(sysconfig.get_path('stdlib'));assert stdlib.is_relative_to('/usr/lib')
retain(Path(sys.executable));retain(stdlib)
native=[]
for directory,dirs,files in os.walk(stdlib,followlinks=False):
    dirs[:]=[n for n in dirs if n not in ['site-packages','dist-packages']]
    for name in dirs+files:
        p=Path(directory)/name;retain(p)
        if p.is_file() and '.so' in p.name:native.append(p)
for p in Path('/usr/share/licenses/python').rglob('*'):
    if p.is_file():retain(p)
seen=set();pending=[Path(sys.executable).resolve(),*native]
while pending:
    p=pending.pop()
    if p.resolve() in seen:continue
    seen.add(p.resolve());result=subprocess.run(['ldd',str(p)],capture_output=True)
    commands.append({'command':['ldd',str(p)],'exit':result.returncode,'stdout':result.stdout.decode(errors='replace'),'stderr':result.stderr.decode(errors='replace')})
    assert result.returncode==0,p
    for name in re.findall(r'(?:=>\s*)?(/[^\s()]+)',result.stdout.decode()):retain(Path(name));pending.append(Path(name).resolve())
(out/'files.json').write_text(json.dumps(rows,indent=2)+'\n');(out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n')
receipt={'passed':True,'python_version':sys.version,'executable':sys.executable,'stdlib':str(stdlib),'paths':len(rows),'objects':len(list(objects.iterdir())),'bytes':sum(p.stat().st_size for p in objects.iterdir()),'scope':'Exact captured standard-library/provider bytes plus native module dynamic-library closure, conservative collection; third-party site-packages/user directories excluded. Pinned SCons4.11.1 wheel/compiled tool inputs already retained separately. Not an OS image or claim every stdlib file was used.'}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt))
