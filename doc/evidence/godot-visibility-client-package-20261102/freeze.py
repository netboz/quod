"""Sparse source/evidence reconstruction; never copy an inherited full tree."""
import hashlib,json,os,shutil,stat,subprocess,tarfile,time
from pathlib import Path

os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent
data=Path('/data/quod-m4-vr-ca84d4f8-20261029')
boundary=data/'artifacts/quod-visibility-package-handoff-ca84d4f8-20261102-01'
boundary.mkdir(mode=0o700,exist_ok=False)
def digest(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def file_row(p):
    s=p.lstat();assert stat.S_ISREG(s.st_mode),p
    return {'sha256':digest(p),'bytes':s.st_size,'mode':s.st_mode}
before=json.loads((ev/'inputs/before.json').read_text())
paths=set(before)
paths.update(str(p.relative_to(root)) for p in ev.rglob('*') if p.is_file() and p.name!='freeze-result.json')
paths.add('nimbalyst-local/handoffs/godot-visibility-package-20261102.md')
assert all('..' not in Path(n).parts and not Path(n).is_absolute() for n in paths)
rows={n:file_row(root/n) for n in sorted(paths)}
parent=data/'artifacts/quod-occurrence-visibility-handoff-ca84d4f8-20261102-01/snapshot.json'
assert digest(parent)=='e19710d747b5f50d34d6ec652a161ff9a6abe74777d1ba6aa3deb3e85b2f6be2'
assert not before and not set(rows).intersection(json.loads(parent.read_text())['rows'])
directories={}
for n in rows:
    for p in (root/n).parents:
        if p==root:break
        directories[str(p.relative_to(root))]=p.stat().st_mode
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
for n,mode in directories.items():(trees['patch']/n).chmod(stat.S_IMODE(mode))
tar_path=boundary/'source.tar'
with tarfile.open(tar_path,'w') as tar:
    for n,mode in sorted(directories.items(),key=lambda row:(len(Path(row[0]).parts),row[0])):
        t=tarfile.TarInfo(n);t.type=tarfile.DIRTYPE;t.mode=stat.S_IMODE(mode);tar.addfile(t)
    for n in rows:tar.add(trees['after']/n,arcname=n,recursive=False)
command(['tar','--extract','--same-permissions','--file',str(tar_path),'--directory',str(trees['tar'])],boundary)
materialized={}
for kind in ['patch','tar']:
    actual={str(p.relative_to(trees[kind])):file_row(p) for p in trees[kind].rglob('*') if p.is_file()}
    assert actual==rows,(kind,'content/type/mode mismatch')
    actual_dirs={str(p.relative_to(trees[kind])):p.stat().st_mode for p in trees[kind].rglob('*') if p.is_dir()}
    assert actual_dirs==directories,(kind,'directory type/mode mismatch')
    assert not any(p.is_symlink() for p in trees[kind].rglob('*'))
    materialized[kind]={'path':str(trees[kind]),'files':len(actual),'full_types_modes':True}
assert all(file_row(root/n)==row for n,row in rows.items()),'origin changed during freeze'
# Freeze small current private receipts/captures and diagnostic inputs. Payloads,
# caches, profile stores and inherited objects stay referenced in place.
qualification=json.loads((ev/'result.json').read_text())
index=Path(qualification['evidence_index']['path']);assert digest(index)==qualification['evidence_index']['sha256']
objects=boundary/'objects';objects.mkdir();captured={}
for name,row in json.loads(index.read_text()).items():
    p=Path(name)
    current=(p.is_relative_to(data/'private') and any(part.startswith(('visibility-package','visibility-vr-visual','quod-m4-live-visibility-package')) for part in p.parts))
    current |= p.is_relative_to(data/'artifacts') and any(part.startswith(('client-visibility-package','client-visibility-vr-visual')) for part in p.parts) and 'drivers' in p.parts
    if not current:continue
    s=p.stat();assert (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)==tuple(row['stat_key'])
    target=objects/row['sha256']
    if not target.exists():shutil.copyfile(p,target);assert digest(target)==row['sha256'];target.chmod(0o600)
    captured[name]={'sha256':row['sha256'],'bytes':row['bytes'],'origin_mode':row['mode'],'object':str(target.relative_to(boundary))}
completion={}
for phase in ['initial','reopen']:
    p=data/'private/visibility-package-journey02/sandbox/work'/(phase+'.json')
    report=json.loads(p.read_text());assert report['passed'] and len(report['checks'])=={'initial':93,'reopen':68}[phase]
    raw_lines=(p.parents[2]/('client-'+phase+'-stdout.raw')).read_text().splitlines()
    assert [l[5:] for l in raw_lines if l.startswith('PASS ')]==report['checks']
    h=digest(p);target=objects/h
    if not target.exists():shutil.copyfile(p,target);target.chmod(0o600)
    completion[phase]={'origin':str(p),'sha256':h,'checks':len(report['checks']),'object':str(target.relative_to(boundary))}
(boundary/'private-evidence-objects.json').write_text(json.dumps({'captured':captured,'completion':completion},indent=2)+'\n')
manifest={'scope':'Private occurrence-visibility package and offline current visual companion',
 'parent':'sealed occurrence visibility e19710d747b5f50d34d6ec652a161ff9a6abe74777d1ba6aa3deb3e85b2f6be2',
 'inherited_changed':list(before),'new_paths':len(rows)-len(before),'rows':rows,
 'source_patch':file_row(patch_path),'source_tar':file_row(tar_path),'materialized':materialized,'directory_modes':directories,
 'private_evidence_objects':file_row(boundary/'private-evidence-objects.json'),'private_objects':len(list(objects.iterdir())),
 'before_copies':before_receipt,'evidence_index':json.loads((ev/'result.json').read_text())['evidence_index'],
 'all_selected_cases_passed':True,'all_attempts_passed':False,'historical_preview_retirement_fixed':False,
 'package':True,'human_hmd_acceptance':False}
snapshot=boundary/'snapshot.json';snapshot.write_text(json.dumps(manifest,indent=2)+'\n')
result={'passed':True,'true_child_exit':0,'explicit_completion':True,'boundary':str(boundary),
 'snapshot':str(snapshot),'snapshot_sha256':digest(snapshot),'source_paths':len(rows),
 'changed':len(before),'new':len(rows)-len(before),'separate_before_copies':len(before),
 'private_objects':len(list(objects.iterdir())),'private_origin_records':len(captured),'directories':len(directories),
 'patch_check_exit':receipts[1]['exit'],'patch_apply_exit':receipts[2]['exit'],'tar_exit':receipts[3]['exit'],
 'materialized':materialized,'selected_software_gates_passed':True,'human_acceptance':False,
 'closing_receipts_outside_snapshot':[str(ev/'freeze-result.json'),str(ev/'logs/visibility-package-freeze01.json'),
     str(ev/'logs/visibility-package-freeze01-stdout.log'),str(ev/'logs/visibility-package-freeze01-stderr.log')]}
(boundary/'result.json').write_text(json.dumps(result,indent=2)+'\n')
(ev/'freeze-result.json').write_text(json.dumps(result,indent=2)+'\n')
print('VISIBILITY_PACKAGE_FREEZE_COMPLETE '+json.dumps(result))
