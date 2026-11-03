"""Freeze exact partial source/evidence, not a release; never include fixture stores/keys."""
from pathlib import Path
import hashlib,json,tarfile,io,stat,subprocess
r=Path('/home/yan/src/quod_worktrees/pearl-stone');e=Path(__file__).resolve().parent
packet=r/'nimbalyst-local/review-packets/stage2-presentation-boundaries01'
assert not packet.exists(), 'immutable packet already exists'
h=lambda b:hashlib.sha256(b).hexdigest()
files={};private={}
def add(p,name=None,dest=files):
 p=Path(p)
 if not p.is_file() or p.is_symlink():return
 name=name or str(p.relative_to(r));data=p.read_bytes()
 dest[name]=(data,stat.S_IMODE(p.stat().st_mode))
for folder in ['src','include','priv/ontologies','test','client/src','client/test','client/godot/Core','client/godot/tests','client/godot-tests']:
 for p in (r/folder).rglob('*'):
  if p.is_file() and p.suffix in ['.erl','.hrl','.pl','.js','.mjs','.cs','.json','.csproj','.b64'] and not set(p.parts)&{'bin','obj','.godot','_build','node_modules'}:add(p)
for name in ['AGENTS.md','rebar.config','rebar.lock','doc/spaces.md','doc/multiwrite-architecture.md','doc/physics-native.md','doc/eidolon-mesh-support.md','nimbalyst-local/plans/space-conceptual-architecture-review.md','nimbalyst-local/handoffs/stage2-d5-reconciliation-20261103.md']:
 add(r/name)
for p in e.rglob('*'):add(p)
old=r/'doc/evidence/stage2-presentation-limits-20261103'
for name in ['claude-fable-review.md','inputs/claude-heap-probe-evidence-correction.md','inputs/approval-rejections.json']:
 add(old/name)
build=r/'_build/stage2-presentation-boundaries'
# Exact intermediate compiler inputs; only source files, never directories of state.
for stage in build.iterdir():
 if not stage.is_dir():continue
 for p in stage.glob('*.erl'):add(p,'executed-source/'+str(p.relative_to(build)))
 for p in (stage/'source').rglob('*'):
  if p.is_file() and not set(p.parts)&{'bin','obj','.godot','nuget','feed','node_modules'}:
   add(p,'executed-source/'+str(p.relative_to(build)))
 for p in stage.glob('*.raw'):add(p,'private-streams/'+str(p.relative_to(build)),private)
 p=stage/'server-raw.log'
 if p.exists():add(p,'private-streams/'+str(p.relative_to(build)),private)
# Owner receipts explicitly refer to saved exact source copies outside source/.
for p in (e/'inputs').glob('*.json'):
 try:rec=json.loads(p.read_text())
 except (ValueError,UnicodeDecodeError):continue
 def refs(v):
  if isinstance(v,dict):
   for k,x in v.items():
    if k in ['copy','saved_source'] and isinstance(x,str):
     q=Path(x)
     if q.is_relative_to(build) and q.suffix in ['.erl','.hrl','.pl','.cs','.py']:add(q,'executed-source/'+str(q.relative_to(build)))
    refs(x)
  elif isinstance(v,list):
   for x in v:refs(x)
 refs(rec)
prior={}
for label in ['01','02','03','04']:
 p=r/('nimbalyst-local/review-packets/stage2-presentation-limits'+label)
 actual={k:h((p/n).read_bytes()) for k,n in [('archive_sha256','snapshot.tar'),('manifest_sha256','manifest.json')]}
 rec=json.loads((p/'result.json').read_text())
 assert all(actual[k]==rec[k] for k in actual),label
 prior[label]=actual;add(p/'result.json')
account=json.loads((e/'inputs/account-current02.json').read_text())
# Check current source against accounting before snapshot creation.
for row in account['production_delta']['paths']:
 p=r/row['path']
 assert (not p.exists()) if row['deleted'] else h(p.read_bytes())==row['current_sha256'],row['path']
packet.mkdir()
def archive(name,items,restricted=False):
 manifest={n:dict(sha256=h(b),bytes=len(b),mode=m) for n,(b,m) in sorted(items.items())}
 mp=packet/(name+'manifest.json');ap=packet/(name+'snapshot.tar')
 mp.write_text(json.dumps(manifest,indent=2)+'\n')
 with tarfile.open(ap,'w') as out:
  for n,(b,m) in sorted(items.items()):
   t=tarfile.TarInfo(n);t.size=len(b);t.mode=m;t.mtime=0;out.addfile(t,io.BytesIO(b))
 if restricted:ap.chmod(0o600);mp.chmod(0o600)
 with tarfile.open(ap) as inp:
  assert len(inp.getmembers())==len(manifest)
  for member in inp.getmembers():assert h(inp.extractfile(member).read())==manifest[member.name]['sha256']
 return dict(files=len(manifest),archive_sha256=h(ap.read_bytes()),manifest_sha256=h(mp.read_bytes()),archive_bytes=ap.stat().st_size)
public_result=archive('',files);private_result=archive('private-',private,True)
result=dict(freeze_verified=True,source_label='applied-carrier02',scope_accepted=False,large_signed_display_accepted=False,whole_tree_acceptance=False,**public_result,private_streams=private_result,production_delta=account['production_delta'],deleted_source=[x['path'] for x in account['all_saved_changes'] if x['deleted']],prior_presentation_freezes_verified=prior,fixture_stores_profiles_and_private_keys_included=False,private_streams_restricted=True,optional_heap_policy_applied=False,interpreter_candidate_installed=False,head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=r,text=True).strip(),package_release_or_deploy=False)
(packet/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k not in ['production_delta','prior_presentation_freezes_verified']}))
