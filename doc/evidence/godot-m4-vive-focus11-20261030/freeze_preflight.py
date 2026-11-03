"""Metadata-only additive-freeze readiness; no runtime or historical API reads."""
import ast,difflib,json,os,shutil,subprocess,sys,time
from pathlib import Path
sys.dont_write_bytecode=True
from freeze_hashes import Digests,TASK,key,raw
root=Path.cwd();ev=Path(__file__).resolve().parent
if sys.argv[1:]!=['--child']:
    assert not sys.argv[1:];os.umask(0o077)
    private=TASK/'private/metadata-inputs/focus11-freeze-preflight01';private.mkdir(mode=0o700,exist_ok=False)
    for p in ev.glob('*.py'):shutil.copy2(p,private/p.name)
    command=[sys.executable,'-B',str(ev/'freeze_preflight.py'),'--child'];started=time.monotonic()
    with (private/'stdout.raw').open('xb') as out,(private/'stderr.raw').open('xb') as err:
        result=subprocess.run(command,stdout=out,stderr=err,timeout=120)
    streams={}
    for name in ['stdout','stderr']:
        p=private/(name+'.raw');p.chmod(0o600);target=ev/('freeze-preflight01-'+name+'.log');target.write_bytes(p.read_bytes())
        streams[name]={'raw':str(p),'sha256':raw(p),'bytes':p.stat().st_size,'eof':True}
    receipt={'command':command,'true_child_exit':result.returncode,'timed_out':False,
        'elapsed_seconds':time.monotonic()-started,'streams':streams}
    (ev/'freeze-preflight01-result.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt))
    raise SystemExit(result.returncode)
d=Digests()
prior=TASK/'artifacts/quod-godot-m4-vive-retest10-handoff-ca84d4f8-20261030-01'
old=json.loads((prior/'source-manifest.json').read_text())
previous=TASK/'builds/coordinator-retest10-source-reconstruction-86'
uncovered={}
for label,folder in [('live',root),('previous-materialization',previous)]:
    missing=[]
    for name,row in old.items():
        p=folder/name
        if row['kind']=='file':
            assert p.is_file() and not p.is_symlink()
            assert p.stat().st_size==row['bytes'] and p.stat().st_mode&0o7777==row['mode']
            k=key(p)
            if k in d.values:assert d.values[k]==row['sha256']
            else:missing.append({'path':name,'bytes':row['bytes']})
        else:assert p.is_symlink() and str(p.readlink())==row['target']
    uncovered[label]={'entries':len(missing),'bytes':sum(r['bytes'] for r in missing),'paths':missing}
for name in ['freeze.py','verify_freeze.py','freeze_hashes.py','scope.py','freeze_preflight.py']:
    ast.parse((ev/name).read_text(),filename=name)
adaptations={}
for name in ['freeze.py','verify_freeze.py','freeze_hashes.py','scope.py']:
    before=ev.parent/'godot-m4-vive-retest10-20261030'/name;after=ev/name
    patch=''.join(difflib.unified_diff(before.read_text().splitlines(True),after.read_text().splitlines(True),
        fromfile='prior-retest/'+name,tofile='case10/'+name))
    path=ev/('freeze-adaptation-'+name+'.patch');assert not path.exists();path.write_text(patch)
    adaptations[name]={'original':str(before.relative_to(root)),'original_sha256':raw(before),
        'prepared':str(after.relative_to(root)),'prepared_sha256':raw(after),'delta':path.name,'delta_sha256':raw(path)}
assert subprocess.check_output(['git','rev-parse','HEAD']).decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert subprocess.check_output(['git','branch','--show-current']).decode().strip()=='worktree/pearl-stone'
assert not subprocess.check_output(['git','diff','--cached','--name-only'])
assert subprocess.check_output(['git','diff','--binary','HEAD'])==(prior/'tracked.patch').read_bytes()
assert raw(ev.parent/'godot-m4-vive-retest10-20261030/focus_events.py')=='bb63ff9db8f3aef231f22043e8336c263afcf52b553c908419ff3e0abdd584e2'
unused=[TASK/'artifacts/quod-godot-m4-vive-focus11-handoff-ca84d4f8-20261030-01',
    TASK/'artifacts/vive-focus11-freeze-runs01',TASK/'builds/vive-focus11-source-reconstruction01',
    TASK/'builds/vive-focus11-additions-reconstruction01',TASK/'builds/vive-focus11-group-reconstruction01']
assert all(not p.exists() for p in unused)
stat=os.statvfs(TASK);capacity=stat.f_bavail*stat.f_frsize
result={'passed':True,'scope':'Metadata/cache coverage and prepared-source syntax/adaptation only; no source qualification or live process/socket/display inspection.',
    'parent_source_entries':len(old),'uncached_prior_source':uncovered,'adaptations':adaptations,
    'free_bytes':capacity,'new_destinations_absent':True,'source_or_readonly_object_links_created':False,
    'root_custody_reply':'case11 instruction: root86 links occurred after accepted freeze; post-link cache authenticated.'}
path=ev/'freeze-preflight.json';assert not path.exists();path.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k not in ['uncached_prior_source','adaptations']},sort_keys=True))
print(json.dumps({'uncached_prior_source':{k:{'entries':v['entries'],'bytes':v['bytes']} for k,v in uncovered.items()}}))
