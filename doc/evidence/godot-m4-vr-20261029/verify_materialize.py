"""Independent object and complete group reconstruction checker (no execution)."""
import hashlib,json,os,shutil,subprocess,sys
from pathlib import Path,PurePosixPath
boundary=Path(sys.argv[1]);destination=Path(sys.argv[2]);receipt=Path(sys.argv[3])
def h(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def load(p):return json.loads(p.read_text())
groups=load(boundary/'object-groups.json');expected={}
for rows in groups.values():
    for value in rows.values():
        if value['kind']=='file':
            assert value['sha256'] not in expected or expected[value['sha256']]==value['bytes']
            expected[value['sha256']]=value['bytes']
        elif 'resolved_sha256' in value:expected[value['resolved_sha256']]=value['resolved_bytes']
assert {p.name for p in (boundary/'objects').iterdir()}==set(expected)
for digest,size in expected.items():
    path=boundary/'objects'/digest
    assert not path.is_symlink() and path.is_file() and path.stat().st_size==size and h(path)==digest,digest
    assert path.stat().st_mode&0o222==0,digest
destination.mkdir(mode=0o700,exist_ok=False)
assert subprocess.run(['git','rev-parse','--show-toplevel'],cwd=destination,capture_output=True).returncode!=0
results={}
for label,rows in groups.items():
    target=destination/label;target.mkdir(mode=0o700)
    for name,value in sorted(rows.items(),key=lambda p:(len(PurePosixPath(p[0]).parts),p[0])):
        relative=PurePosixPath(name);assert not relative.is_absolute() and '..' not in relative.parts and str(relative)!='.'
        path=target/name
        for parent in path.parents:
            if parent==target:break
            assert not parent.is_symlink(),(label,name,'symlink parent')
        path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        if value['kind']=='directory':path.mkdir(mode=0o700,exist_ok=True)
        elif value['kind']=='symlink':path.symlink_to(value['target'])
        else:shutil.copyfile(boundary/'objects'/value['sha256'],path);path.chmod(value['mode'])
    for name,value in sorted(rows.items(),key=lambda p:len(PurePosixPath(p[0]).parts),reverse=True):
        if value['kind']=='directory':(target/name).chmod(value['mode'])
    actual={}
    for directory,dirs,files in os.walk(target,followlinks=False):
        parent=Path(directory)
        for name in dirs+files:actual[str((parent/name).relative_to(target))]=parent/name
    assert set(actual)==set(rows),(label,'complete path mismatch',set(actual)-set(rows),set(rows)-set(actual))
    total=0
    for name,value in rows.items():
        path=actual[name];assert path.lstat().st_mode&0o7777==value['mode'],(label,name,'mode')
        if value['kind']=='file':assert path.is_file() and not path.is_symlink() and path.stat().st_size==value['bytes'] and h(path)==value['sha256'],(label,name);total+=value['bytes']
        elif value['kind']=='symlink':assert path.is_symlink() and str(path.readlink())==value['target'],(label,name)
        else:assert path.is_dir() and not path.is_symlink(),(label,name)
    results[label]={'entries':len(rows),'file_bytes':total,'all_paths_bytes_links_full_recorded_modes_verified':True}
    print(json.dumps({'materialized':label,**results[label]}),flush=True)
summary={'passed':True,'object_count':len(expected),'object_bytes':sum(expected.values()),'object_hashes_sizes_and_readonly_modes_verified':True,
    'method':'Independent object hashing; real complete file copies into each group, literal symlink reconstruction, exact complete path set/content/link/full recorded mode verification. External symlink targets are not called copied files; their verified resolved bytes are separate retained objects. No compiled input executed.',
    'outside_every_checkout':True,'destination':str(destination),'groups':results}
receipt.write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps({'explicit_completion':True,'groups':len(groups),'objects':len(expected)}))
