"""Verify actual archive/extraction, pinned payload, modes and ELF requirements."""
import hashlib,json,os,re,subprocess,sys,tarfile
from pathlib import Path,PurePosixPath
from hashes import TASK,raw,Digests,key
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent
label,archive,receipt_path=sys.argv[1:];archive=Path(archive);receipt=json.loads(Path(receipt_path).read_text())
digests=Digests();archive_key=key(archive);archive_sha=digests.h(archive);assert archive_sha==receipt['archive_sha256']
extraction=TASK/'private'/('current space clean '+label);extraction.mkdir(mode=0o700,exist_ok=False)
rows={};directories=set()
with tarfile.open(archive) as tar:
    members=tar.getmembers();assert len({m.name for m in members})==len(members)
    for m in members:
        p=PurePosixPath(m.name);assert not p.is_absolute() and '..' not in p.parts and p.parts[0]=='quod-linux-x86_64'
        assert m.uid==m.gid==m.mtime==0 and not m.uname and not m.gname
        assert m.isdir() or m.isfile()
        target=extraction/m.name
        if m.isdir():target.mkdir(parents=True,exist_ok=True);target.chmod(m.mode);directories.add(m.name)
        else:
            target.parent.mkdir(parents=True,exist_ok=True);data=tar.extractfile(m).read();target.write_bytes(data);target.chmod(m.mode)
            rows[str(p.relative_to('quod-linux-x86_64'))]={'sha256':digests.h(target),'bytes':len(data),'mode':m.mode}
package=extraction/'quod-linux-x86_64';index=json.loads((package/'package-manifest.json').read_text())
assert index['files']=={n:r for n,r in rows.items() if n!='package-manifest.json'}==receipt['files']
assert (package/'quod').stat().st_mode&0o111 and (package/'quod.x86_64').stat().st_mode&0o111
private=TASK/'private'/('current-space-elf-'+label);private.mkdir(mode=0o700,exist_ok=False)
objects={};needed=set();versions={}
prior_path=root/'doc/evidence/godot-m5-package-20261031/inputs/package-final-inspection04.json';prior=json.loads(prior_path.read_text())
for name in index['files']:
    f=package/name
    with f.open('rb') as stream:magic=stream.read(4)
    if magic!=b'\x7fELF':continue
    if name in prior['elf_objects'] and prior['elf_objects'][name]['sha256']==rows[name]['sha256']:
        objects[name]=prior['elf_objects'][name];needed.update(objects[name]['needed'])
        for family,version in objects[name]['maximum_symbol_versions'].items():
            if tuple(map(int,version.split('.')))>tuple(map(int,versions.get(family,'0').split('.'))):versions[family]=version
        continue
    r=subprocess.run(['readelf','--wide','-h','-d','--version-info',str(f)],capture_output=True);assert r.returncode==0 and not r.stderr
    text=r.stdout.decode();log=private/(f.name+'.readelf');log.write_bytes(r.stdout);log.chmod(0o600)
    libs=sorted(set(re.findall(r'Shared library: \[([^\]]+)\]',text)));needed.update(libs)
    ver={}
    for family in ['GLIBC','GLIBCXX','CXXABI']:
        found=re.findall(r'\b'+family+r'_(\d+(?:\.\d+)+)',text)
        if found:ver[family]=max(found,key=lambda x:tuple(map(int,x.split('.'))))
        if family in ver and tuple(map(int,ver[family].split('.')))>tuple(map(int,versions.get(family,'0').split('.'))):versions[family]=ver[family]
    objects[name]={'sha256':rows[name]['sha256'],'needed':libs,'maximum_symbol_versions':ver,'readelf_exit':r.returncode,'log_sha256':raw(log)}
assert len(objects)==16
assert key(archive)==archive_key
digests.write(TASK/'cache'/('current-space-package-'+label+'-digests.json'))
result={'passed':True,'archive':str(archive),'archive_sha256':archive_sha,'extracted':str(package),'files':len(rows),'directory_count':len(directories),'exact_paths_types_bytes_modes':True,'all_members_regular_files_or_directories':True,'elf_objects':objects,'external_needed':sorted(needed-{Path(n).name for n in objects}),'symbol_versions':versions,'no_build_or_runtime_started':True,'dlopen_coverage':'ordinary isolated launch and signed TLS journey measured separately; optional OpenXR/hardware unrun','managed_product_changed':True,'digest_cache':{'path':str(TASK/'cache'/('current-space-package-'+label+'-digests.json')),'sha256':raw(TASK/'cache'/('current-space-package-'+label+'-digests.json'))}}
result['unchanged_elf_audit_reused']={'path':str(prior_path),'sha256':raw(prior_path),'binding':'actual extracted content digest equality per object; no repeated readelf'}
(ev/'inputs'/('package-'+label+'.json')).write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:v for k,v in result.items() if k!='elf_objects'}))
