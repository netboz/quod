"""Sparse source/evidence reconstruction; never copy an inherited full tree."""
import hashlib,json,os,shutil,stat,subprocess,tarfile,time
from pathlib import Path

os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent
data=Path('/data/quod-m4-vr-ca84d4f8-20261029')
boundary=data/'artifacts/quod-occurrence-visibility-handoff-ca84d4f8-20261102-01'
boundary.mkdir(mode=0o700,exist_ok=False)
def digest(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def file_row(p):
    s=p.lstat();assert stat.S_ISREG(s.st_mode),p
    return {'sha256':digest(p),'bytes':s.st_size,'mode':s.st_mode}
before=json.loads((ev/'inputs/before.json').read_text())
paths=set(before)
paths.update(str(p.relative_to(root)) for p in ev.rglob('*') if p.is_file() and p.name!='freeze-result.json')
paths.add('nimbalyst-local/handoffs/godot-occurrence-visibility-20261102.md')
server=root/'doc/evidence/godot-space-experience-20261101/inputs'
paths.update(str(p.relative_to(root)) for p in server.glob('visibility-*-server-*') if p.is_file())
paths.update(str(p.relative_to(root)) for p in server.glob('server-visibility-*-server.json'))
assert all('..' not in Path(n).parts and not Path(n).is_absolute() for n in paths)
rows={n:file_row(root/n) for n in sorted(paths)}
trees={n:boundary/n for n in ['before','after','patch','tar']}
for p in trees.values():p.mkdir()
receipts=[]
def command(argv,cwd,expected=0):
    r=subprocess.run(argv,cwd=cwd,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    index=len(receipts);out=boundary/(str(index)+'-stdout.raw');err=boundary/(str(index)+'-stderr.raw')
    out.write_bytes(r.stdout);err.write_bytes(r.stderr)
    receipts.append({'argv':argv,'cwd':str(cwd),'exit':r.returncode,'stdout':file_row(out),'stderr':file_row(err)})
    (boundary/'commands.json').write_text(json.dumps(receipts,indent=2)+'\n')
    assert r.returncode==expected,(argv,r.returncode,r.stderr.decode(errors='replace')[-1000:])
    return r.stdout
def copy(source,target,mode):
    target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target);target.chmod(stat.S_IMODE(mode))
    assert (source.stat().st_dev,source.stat().st_ino)!=(target.stat().st_dev,target.stat().st_ino)

# Each inherited file is a separate copy before any patch command runs.
for n,row in before.items():
    source=root/row['before'];assert digest(source)==row['sha256']
    copy(source,trees['before']/n,row['mode']);copy(source,trees['patch']/n,row['mode'])
before_receipt={'completed_before_patch_ns':time.time_ns(),'files':{n:file_row(trees['patch']/n) for n in before}}
(boundary/'before-copies.json').write_text(json.dumps(before_receipt,indent=2)+'\n')
for n,row in rows.items():copy(root/n,trees['after']/n,row['mode'])
patch=command(['git','diff','--no-index','--binary','--no-renames','--no-ext-diff','--no-textconv','--src-prefix=old/','--dst-prefix=new/','before','after'],boundary,1)
lines=[]
for line in patch.splitlines(keepends=True):
    if line.startswith((b'diff --git ',b'--- ',b'+++ ')):
        for source,target in [(b'old/before/',b'a/'),(b'old/after/',b'a/'),(b'new/before/',b'b/'),(b'new/after/',b'b/')]:line=line.replace(source,target)
    lines.append(line)
patch_path=boundary/'source.patch';patch_path.write_bytes(b''.join(lines))
command(['git','apply','--check','--binary',str(patch_path)],trees['patch'])
command(['git','apply','--binary',str(patch_path)],trees['patch'])
# Git expresses executable/type bits; restore the recorded full file modes on
# these new reconstruction copies only, then compare complete type/mode/content.
for n,row in rows.items():(trees['patch']/n).chmod(stat.S_IMODE(row['mode']))
tar_path=boundary/'source.tar'
with tarfile.open(tar_path,'w') as tar:
    for n in rows:tar.add(trees['after']/n,arcname=n,recursive=False)
command(['tar','--extract','--same-permissions','--file',str(tar_path),'--directory',str(trees['tar'])],boundary)
materialized={}
for kind in ['patch','tar']:
    actual={str(p.relative_to(trees[kind])):file_row(p) for p in trees[kind].rglob('*') if p.is_file()}
    assert actual==rows,(kind,'content/type/mode mismatch')
    materialized[kind]={'path':str(trees[kind]),'files':len(actual),'full_types_modes':True}
assert all(file_row(root/n)==row for n,row in rows.items()),'origin changed during freeze'
manifest={'scope':'occurrence visibility and hierarchy; partial qualification retained',
 'parent':'accepted attention278/279 plus preserved visual-readiness observer source',
 'inherited_changed':list(before),'new_paths':len(rows)-len(before),'rows':rows,
 'source_patch':file_row(patch_path),'source_tar':file_row(tar_path),'materialized':materialized,
 'before_copies':before_receipt,'evidence_index':json.loads((ev/'result.json').read_text())['evidence_index'],
 'all_affected_runs_passed':False,'preview_normal_retirement_qualified':False,
 'package':False,'human_hmd_acceptance':False}
snapshot=boundary/'snapshot.json';snapshot.write_text(json.dumps(manifest,indent=2)+'\n')
result={'passed':True,'true_child_exit':0,'explicit_completion':True,'boundary':str(boundary),
 'snapshot':str(snapshot),'snapshot_sha256':digest(snapshot),'source_paths':len(rows),
 'changed':len(before),'new':len(rows)-len(before),'separate_before_copies':len(before),
 'patch_check_exit':receipts[1]['exit'],'patch_apply_exit':receipts[2]['exit'],'tar_exit':receipts[3]['exit'],
 'materialized':materialized,'qualification_acceptance':False,
 'closing_receipts_outside_snapshot':[str(ev/'freeze-result.json'),str(ev/'logs/visibility-freeze01.json'),
     str(ev/'logs/visibility-freeze01-stdout.log'),str(ev/'logs/visibility-freeze01-stderr.log')]}
(boundary/'result.json').write_text(json.dumps(result,indent=2)+'\n')
(ev/'freeze-result.json').write_text(json.dumps(result,indent=2)+'\n')
print('VISIBILITY_FREEZE_COMPLETE '+json.dumps(result))
