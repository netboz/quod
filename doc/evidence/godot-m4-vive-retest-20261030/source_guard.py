"""Check additive source custody before final materialization, without a build."""
import json,os,subprocess,sys
from pathlib import Path
sys.dont_write_bytecode=True
from freeze_hashes import Digests,TASK,raw
os.umask(0o077);ev=Path(__file__).resolve().parent;root=Path.cwd();d=Digests()
def git(*args):return subprocess.check_output(['git',*args])
def paths(*args):return set(filter(None,git(*args,'-z').decode().split('\0')))
prior=TASK/'artifacts/quod-godot-m4-vive-preparation-handoff-ca84d4f8-20261030-01'
assert d.h(prior/'snapshot.json')=='86ece6910580d658eb954ba68596ea582e8ca6e0236dcc2fc6f3fd28fef7d82c'
assert git('branch','--show-current').decode().strip()=='worktree/pearl-stone'
assert git('rev-parse','HEAD').decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert git('rev-parse','HEAD^').decode().strip()=='f716ddf5e578df957a5b18421a0727a32c634f87'
assert not git('diff','--cached','--name-only') and git('diff','--binary','HEAD')==(prior/'tracked.patch').read_bytes()
old=json.loads((prior/'source-manifest.json').read_text());tracked=paths('ls-files','--cached');untracked=paths('ls-files','--others','--exclude-standard');actual={}
for name in sorted(tracked|untracked):
 p=root/name
 if p.is_symlink():r={'kind':'symlink','target':str(p.readlink()),'tracked':name in tracked}
 else:
  assert p.is_file();r={'kind':'file','sha256':d.h(p),'bytes':p.stat().st_size,'mode':p.stat().st_mode&0o7777,'tracked':name in tracked}
 actual[name]=r
changed=[n for n,r in old.items() if actual.get(n)!=r];assert not changed,changed
new=sorted(set(actual)-set(old))
allowed=['doc/evidence/godot-m4-vive-retest-20261030/','doc/evidence/godot-m4-r2-coordinator-20261029/',
 'nimbalyst-local/handoffs/godot-m4-vive-retest-',
 'doc/evidence/godot-m4-vive-physical-20261029/logs/native-vive-product08-run',
 'doc/evidence/godot-m4-vive-physical-20261029/logs/native-vive-product09-run',
 'doc/evidence/godot-m4-vive-physical-20261029/logs/display-reconnect-retest01-run']
assert all(any(n.startswith(p) for p in allowed) for n in new),new
assert sum(n.startswith('.agents/') for n in untracked)==31
cache=TASK/'cache/retest-source-guard01-hashes.json';d.write(cache)
record={'passed':True,'scope':'Pre-freeze current source custody only; active observer outcome not finalized.',
 'source_paths':len(actual),'previous_paths':len(old),'new_paths':new,'changed_previous_paths':changed,
 'generated_new_python_caches':[n for n in new if n.endswith('.pyc')],
 'index_empty':True,'generated_agents':31,'product_changes':0,
 'digest_cache':{'path':str(cache),'sha256':raw(cache),'strict_hits':d.hits,'new_hashes':d.new,'new_bytes':d.bytes}}
(ev/'inputs/source-guard01.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({k:v for k,v in record.items() if k!='new_paths'}))
