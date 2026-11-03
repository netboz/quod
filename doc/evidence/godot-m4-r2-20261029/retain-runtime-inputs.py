#!/usr/bin/env python3
"""Retain actual owned-process modules and native compile dependency bytes.

No process memory, environment, command line, key store or calibration is read.
This is a userspace dependency snapshot, not an OS/kernel/display image.
"""
import argparse,hashlib,json,os,re,shutil,stat,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--owned-client-pid',type=int,required=True);a=p.parse_args()
evidence=Path(__file__).resolve().parent;cache=Path('/home/yan/.cache/quod-m4-r2-artifacts/runtime')
objects=cache/'retained-dependencies/objects';objects.mkdir(parents=True,mode=0o700)
def parent(pid):
    for line in (Path('/proc')/str(pid)/'status').read_text().splitlines():
        if line.startswith('PPid:'):return int(line.split()[1])
def descendants(pid,ancestor):
    seen=set()
    while pid>1 and pid not in seen:
        if pid==ancestor:return True
        seen.add(pid)
        try:pid=parent(pid)
        except (FileNotFoundError,ProcessLookupError):return False
    return False
owner=parent(a.owned_client_pid);pids=[a.owned_client_pid]
for entry in Path('/proc').iterdir():
    if not entry.name.isdigit():continue
    try:name=(entry/'comm').read_text().strip()
    except (FileNotFoundError,PermissionError,ProcessLookupError):continue
    if name=='monado-service' and descendants(int(entry.name),owner):pids.append(int(entry.name))
assert len(pids)==2,('Expected this owner\'s client and one private Monado',pids)
paths={};mapped={}
for pid in pids:
    entries=[]
    for line in (Path('/proc')/str(pid)/'maps').read_text().splitlines():
        row=line.split(maxsplit=5)
        if len(row)!=6 or not row[5].startswith('/'):continue
        name=row[5]
        if re.search(r'\.so(?:\.[A-Za-z0-9_.-]+)?$',name) or name.endswith('.dll') or name==os.readlink(Path('/proc')/str(pid)/'exe'):
            paths[name]='actual owned-process mapped code';entries.append(name)
    mapped[str(pid)]=sorted(set(entries))
dependency_log=evidence/'logs/runtime-native-dependency-inputs.log'
for line in dependency_log.read_text().splitlines():
    name=line.strip()
    if name.startswith('/') and Path(name).is_file():paths.setdefault(name,'actual compiler dependency from Ninja database')
for name in ['cc','c++','gcc','g++','as','ld','ar','ranlib','strip','cmake','ninja','pkg-config','glslangValidator']:
    path=shutil.which(name)
    if path:paths.setdefault(path,'native build tool')
for pattern in ['cc1','cc1plus','collect2']:
    for path in Path('/usr/lib/gcc').glob('**/'+pattern):paths.setdefault(str(path),'GCC build tool component')
rows={};unique={}
for name,origin in sorted(paths.items()):
    path=Path(name);data=path.read_bytes();digest=hashlib.sha256(data).hexdigest();target=objects/digest
    if not target.exists():target.write_bytes(data);target.chmod(0o444)
    assert hashlib.sha256(target.read_bytes()).hexdigest()==digest
    unique[digest]=len(data)
    rows[name]={'origin':origin,'sha256':digest,'bytes':len(data),'source_mode':oct(stat.S_IMODE(path.lstat().st_mode)),
       'kind':'symlink' if path.is_symlink() else 'file','link_target':os.readlink(path) if path.is_symlink() else None,
       'resolved_path':str(path.resolve()),'retained_object':str(target)}
commands={}
env=dict(os.environ);env.pop('LD_LIBRARY_PATH',None);env.pop('LD_PRELOAD',None)
for command in [['gcc','--version'],['c++','--version'],['cmake','--version'],['ninja','--version'],['pacman','-Q','openxr','monado-git','nvidia-utils','gcc','gcc-libs','glibc','binutils','cmake','ninja','wayland','wayland-protocols']]:
    child=subprocess.run(command,env=env,capture_output=True,text=True);commands[' '.join(command)]={'command':command,'child_exit':child.returncode,'stdout':child.stdout,'stderr':child.stderr}
record={'owned_pids':pids,'owner_pid':owner,'mapped_code_paths':mapped,'inputs':rows,'unique_objects':len(unique),'unique_bytes':sum(unique.values()),'toolchain_receipts':commands,
    'scope':'exact observed userspace code and compiler dependency bytes; excludes private calibration/stores/raw diagnostic data and does not snapshot the host kernel or display session'}
(evidence/'inputs/runtime-observed-dependencies.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'input_paths':len(rows),'unique_objects':len(unique),'unique_bytes':sum(unique.values()),'owned_processes':len(pids),'toolchain_exits':[r['child_exit'] for r in commands.values()]}))
