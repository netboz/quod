"""Freeze applied source and literal affected evidence; never include fixture stores."""
from pathlib import Path
import hashlib,json,tarfile,stat
R=Path('/home/yan/src/quod_worktrees/pearl-stone');E=Path(__file__).resolve().parent
P=R/'nimbalyst-local/review-packets/stage2-remaining-admission-applied01'
assert not P.exists(),'Never replace an evidence freeze'
def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 return h.hexdigest()
items={};manifest={}
def add(p,name=None):
 if not p.is_file() or p.is_symlink():return
 name=name or str(p.relative_to(R));items[name]=p;manifest[name]=dict(sha256=digest(p),bytes=p.stat().st_size,mode=stat.S_IMODE(p.stat().st_mode))
for p in E.rglob('*'):
 if '__pycache__' not in p.parts:add(p)
for n in ['AGENTS.md','rebar.config','rebar.lock','doc/spaces.md','doc/multiwrite-architecture.md','doc/ontology-eidolons-plan.md','nimbalyst-local/plans/space-conceptual-architecture-review.md','nimbalyst-local/handoffs/stage2-d5-reconciliation-20261103.md']:add(R/n)
delta=json.loads((E/'application01/current-delta.json').read_text())
for n,row in delta['files'].items():
 p=R/n;assert (digest(p) if p.is_file() else hashlib.sha256(b'').hexdigest())==row['after'],n
 add(p)
# Every normal production input and header remains identical to its final compile.
prod=json.loads((E/'inputs/applied-production02.json').read_text())
assert prod['true_exit']==0 and prod['production_only']
for n,h in prod['source_inputs'].items():
 p=R/n
 if p.is_file():assert digest(p)==h,n
# Source-only application snapshots retain actual failed and corrected compile inputs.
build=R/'_build/stage2-remaining-admission'
allowed={'.erl','.hrl','.pl','.cs','.csproj','.js','.mjs','.py','.config','.lock','.json','.html','.css','.glb','.cpp','.h','.c'}
for stage in sorted(build.glob('applied-*')):
 source=stage/'source'
 if source.is_symlink():continue
 for p in source.rglob('*'):
  if p.suffix in allowed and not set(p.parts)&{'bin','obj','.godot','nuget','node_modules','dotnet'}:
   add(p,'application-source/'+str(p.relative_to(build)))
# The exact three-file reviewed dependency remains unchanged, including excluded
# generated/user-owned state in the repository-state receipt, not in the commit set.
erlog=json.loads((E/'application01/erlog-tested-inputs.json').read_text())
for n,h in erlog['files'].items():assert digest(R/'_build/default/lib/erlog'/n)==h,n
prior={}
for name in ['stage2-remaining-admission-proposal01','stage2-presentation-limits01','stage2-presentation-limits02','stage2-presentation-limits03','stage2-presentation-limits04','stage2-presentation-boundaries01','stage2-presentation-boundaries-parent01']:
 q=R/'nimbalyst-local/review-packets'/name;row=json.loads((q/'result.json').read_text());found={}
 for key,file in [('archive_sha256','snapshot.tar'),('manifest_sha256','manifest.json')]:
  found[key]=digest(q/file);assert found[key]==row[key],name
 prior[name]=found;add(q/'result.json')
for n in ['claude-fable-review.md','inputs/claude-heap-probe-evidence-correction.md','inputs/approval-rejections.json']:add(R/'doc/evidence/stage2-presentation-limits-20261103'/n)
for n in ['RESULTS.md','EVIDENCE-CORRECTIONS.md','inputs/carrier-edit-rejected-command.json','inputs/carrier-edit-rejection01.json']:add(R/'doc/evidence/stage2-presentation-boundaries-20261103'/n)
P.mkdir();mp=P/'manifest.json';ap=P/'snapshot.tar';mp.write_text(json.dumps(dict(sorted(manifest.items())),indent=2)+'\n')
with tarfile.open(ap,'w') as out:
 for n,p in sorted(items.items()):
  info=tarfile.TarInfo(n);info.size=manifest[n]['bytes'];info.mode=manifest[n]['mode'];info.mtime=0
  with p.open('rb') as f:out.addfile(info,f)
with tarfile.open(ap) as inp:
 assert len(inp.getmembers())==len(manifest)
 for member in inp.getmembers():
  h=hashlib.sha256();f=inp.extractfile(member)
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
  assert h.hexdigest()==manifest[member.name]['sha256'],member.name
assert all(digest(p)==manifest[n]['sha256'] for n,p in items.items()),'Inputs changed during freeze'
result=dict(freeze_verified=True,source_label=delta['source_label'],files=len(manifest),archive_sha256=digest(ap),manifest_sha256=digest(mp),archive_bytes=ap.stat().st_size,actual_delta=delta['categories'],prior_freezes_verified=prior,three_authorized_patches_applied=True,affected_software_validation_complete=True,all_production_compiled_without_test_exports=True,dependency_source_tested=True,dependency_published=False,dependency_pin_changed=False,dependency_delivery_blocker='Required editor commit tool repository attachment excludes exact pearl-stone Erlog repository; parent owns authorized publication/pin',original_aggregate_30s_three_renewal_acceptance='failed, unchanged and not rerun',large_signed_display_accepted=False,stage2_complete=False,whole_tree_acceptance=False,user_stores_accessed=False,storage_cutover_performed=False,hardware_or_human_tests=False,fixture_stores_credentials_profiles_beams_included=False,source_unchanged_after_freeze=True)
(P/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k!='prior_freezes_verified'},indent=2))
