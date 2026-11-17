#!/usr/bin/env python3
"""Inspect accepted Linux ELF dependencies; never execute the client."""
import hashlib,json,os,re,subprocess,tarfile
from pathlib import Path

root=Path('/home/yan/src/quod_worktrees/pearl-stone')
boundary=Path('/home/yan/.cache/quod-m4-artifacts/quod-godot-m4-handoff-ca84d4f8-20261029-01')
snapshot=json.loads((boundary/'snapshot.json').read_text())
assert hashlib.sha256((boundary/'snapshot.json').read_bytes()).hexdigest()=='a06f1f934754d3d210e1b74c5685c2c523b1507bfc1a8af2ce9fc7ce4aec5349'
archive_path=boundary/'client-export.tar.gz'
with archive_path.open('rb') as stream:
    archive_sha=hashlib.file_digest(stream,'sha256').hexdigest()
assert archive_sha==snapshot['artifacts']['client-export.tar.gz']['sha256']
index=json.loads((boundary/'client-export.tar.gz.json').read_text())
rows=[]
seen=[]
with tarfile.open(archive_path,'r:gz') as archive:
    for member in archive:
        assert member.isfile(),member.name
        seen.append(member.name)
        data=archive.extractfile(member).read()
        assert hashlib.sha256(data).hexdigest()==index[member.name]['sha256']
        if not data.startswith(b'\x7fELF'):
            continue
        fd=os.memfd_create('quod-accepted-elf-inspection',flags=0)
        try:
            with os.fdopen(os.dup(fd),'wb') as output:
                output.write(data)
            path=f'/proc/self/fd/{fd}'
            dynamic=subprocess.run(['readelf','-d',path],pass_fds=(fd,),capture_output=True,text=True,check=True)
            version=subprocess.run(['readelf','--version-info',path],pass_fds=(fd,),capture_output=True,text=True,check=True)
            needed=re.findall(r'\(NEEDED\).*\[([^\]]+)\]',dynamic.stdout)
            soname=re.findall(r'\(SONAME\).*\[([^\]]+)\]',dynamic.stdout)
            # Read only external version-needs, excluding versions the object defines.
            section=version.stdout.split('Version needs section',1)
            requirements=sorted(set(re.findall(r'Name: ((?:GLIBC|GLIBCXX|CXXABI)_[0-9.]+)',section[1] if len(section)>1 else '')))
            rows.append({'path':member.name,'sha256':hashlib.sha256(data).hexdigest(),'soname':soname,'needed':needed,'requiredSymbolVersions':requirements})
        finally:
            os.close(fd)
assert set(seen)==set(index)
supplied={Path(name).name for name in index}
supplied.update(value for row in rows for value in row['soname'])
external=sorted({name for row in rows for name in row['needed'] if name not in supplied})
versions={}
for prefix in ['GLIBC_','GLIBCXX_','CXXABI_']:
    values={name for row in rows for name in row['requiredSymbolVersions'] if name.startswith(prefix)}
    if values:
        versions[prefix.removesuffix('_')]=max(values,key=lambda value:tuple(int(n) for n in value[len(prefix):].split('.')))
result={'method':'Read accepted immutable archive, hash every payload, inspect ELF metadata through anonymous memory descriptors; no client execution or product source changes','sourceHead':'293cf6115c0a6b18315eccdbb42cbca396f443d3','snapshotSHA256':hashlib.sha256((boundary/'snapshot.json').read_bytes()).hexdigest(),'archiveSHA256':archive_sha,'payloadEntries':len(index),'elfEntries':len(rows),'externalDtNeededNames':external,'maximumRecordedSymbolVersionRequirements':versions,'elfObjects':rows,'limits':['DT_NEEDED inspection does not include runtime dlopen/plugin dependencies or prove clean-host compatibility.','This is the production candidate09 export, not the R1 diagnostic export.','A later R2 source change requires its new qualified export and a refreshed package audit.'],'productTestsRun':False,'runtimeOrGlobalEnvironmentChanged':False,'M5AcceptanceCredited':False}
out=root/'_build/godot-m4-r2-coordinator-20261029/linux-export-dependency-audit.json'
out.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({key:value for key,value in result.items() if key!='elfObjects'},indent=2))
