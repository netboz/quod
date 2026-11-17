"""Retain exact native compiler tools, dynamic dependencies and include roots.

The include-root collection is conservative, not an assertion that every header
was opened by the compiler. SCons' separately retained dependency database is
the observed build graph; it does not enumerate every system header.
"""
import hashlib,json,os,pickle,re,shutil,subprocess,sys
from pathlib import Path
from environment import TASK
sys.path.insert(0,str(TASK/'cache/tools/scons-4.11.1'))
import SCons.dblite
out=TASK/'artifacts/toolchain-inputs01';out.mkdir(mode=0o700,exist_ok=False)
objects=out/'objects';objects.mkdir();rows={};commands=[]
def h(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def preserve(p):
    p=Path(p)
    if str(p) in rows:return
    st=p.lstat();r={'mode':st.st_mode&0o7777}
    if p.is_symlink():r.update(kind='symlink',target=os.readlink(p));rows[str(p)]=r;preserve(p.resolve());return
    if p.is_dir():r['kind']='directory';rows[str(p)]=r;return
    assert p.is_file(),p
    sha=h(p);target=objects/sha
    if not target.exists():shutil.copyfile(p,target);assert h(target)==sha;target.chmod(0o444)
    r.update(kind='file',sha256=sha,bytes=st.st_size);rows[str(p)]=r
def command(args,input=None):
    result=subprocess.run(args,input=input,capture_output=True);commands.append({'command':args,'exit':result.returncode,'stdout':result.stdout.decode(errors='replace'),'stderr':result.stderr.decode(errors='replace')});assert result.returncode==0,args
    return result.stdout.decode()
tools=[]
for name in ['g++','gcc','ar','ranlib','as','ld','pkg-config','wayland-scanner','python3']:
    p=Path(shutil.which(name));preserve(p);tools.append(p.resolve())
for name in ['cc1plus','cc1','collect2']:
    p=Path(command(['g++','-print-prog-name='+name]).strip());preserve(p);tools.append(p.resolve())
for name in ['crtbeginS.o','crtendS.o','libgcc.a','libgcc_s.so','libstdc++.so','Scrt1.o','crti.o','crtn.o']:
    p=Path(command(['g++','-print-file-name='+name]).strip());assert p.is_absolute();preserve(p)
pending=list(tools);seen=set()
while pending:
    p=pending.pop()
    if p in seen:continue
    seen.add(p);result=subprocess.run(['ldd',str(p)],capture_output=True)
    commands.append({'command':['ldd',str(p)],'exit':result.returncode,'stdout':result.stdout.decode(),'stderr':result.stderr.decode()})
    assert result.returncode==0,p
    for name in re.findall(r'(?:=>\s*)?(/[^\s()]+)',result.stdout.decode()):
        dependency=Path(name);preserve(dependency);pending.append(dependency.resolve())
preprocess=subprocess.run(['g++','-E','-x','c++','-v','-'],input=b'',capture_output=True);assert preprocess.returncode==0
commands.append({'command':['g++','-E','-x','c++','-v','-'],'exit':preprocess.returncode,'stdout':preprocess.stdout.decode(),'stderr':preprocess.stderr.decode()})
section=preprocess.stderr.decode().split('#include <...> search starts here:\n',1)[1].split('End of search list.',1)[0]
include_roots=[Path(line.strip()) for line in section.splitlines() if line.strip()]
for include in include_roots:
    assert include.is_absolute() and include.is_dir();preserve(include)
    for directory,dirs,files in os.walk(include,followlinks=False):
        for name in dirs+files:preserve(Path(directory)/name)
for include in [Path('/usr/lib/pkgconfig'),Path('/usr/share/pkgconfig')]:
    if include.exists():
        preserve(include)
        for p in include.iterdir():
            if p.is_file() or p.is_symlink():preserve(p)
source=TASK/'builds/engine01/godot-4.7.2-stable'
db=SCons.dblite.open(str(source/'.sconsign5'),'r');graph={};dependencies=set()
for directory in db.keys():
    entries={}
    for name,entry in pickle.loads(db[directory]).items():
        b=entry.binfo;r={field:getattr(b,field,[]) or [] for field in ['bsources','bdepends','bimplicit']}
        for value in r.values():dependencies.update(str(p) for p in value)
        entries[name]=r
    graph[directory]=entries
for name in dependencies:
    if name.startswith('/') and Path(name).exists():preserve(Path(name))
for name in ['.sconsign5.dblite','.scons_env.json']:shutil.copy2(source/name,out/name)
env=json.loads((out/'.scons_env.json').read_text());assert set(env.get('ENV',{}))<= {'PATH','PKG_CONFIG_PATH','TERM'}
(out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n')
(out/'files.json').write_text(json.dumps(rows,indent=2)+'\n')
(out/'scons-build-graph.json').write_text(json.dumps(graph,indent=2)+'\n')
receipt={'files':len(rows),'objects':len(list(objects.iterdir())),'bytes':sum(p.stat().st_size for p in objects.iterdir()),'include_roots':[str(p) for p in include_roots],'include_collection':'conservative complete files in compiler default include roots, plus pkgconfig metadata; not a claim every file was used','scons_graph_dependencies':len(dependencies),'compiler_version':command(['g++','--version']),'runtime_portability':'not an OS/kernel/GPU-driver image; actual runtime/display dependencies remain separately qualified'}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt))
