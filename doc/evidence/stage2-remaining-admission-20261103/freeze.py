"""Immutable source/proposal/evidence packet; never execute or install proposal code."""
from pathlib import Path
import hashlib,json,tarfile,io,stat
R=Path('/home/yan/src/quod_worktrees/pearl-stone');E=Path(__file__).resolve().parent
P=R/'nimbalyst-local/review-packets/stage2-remaining-admission-proposal01'
assert not P.exists(), 'Never overwrite a freeze'
h=lambda b:hashlib.sha256(b).hexdigest()
items={};original={}
def add(f,name=None):
 if not f.is_file() or f.is_symlink():return
 name=name or str(f.relative_to(R));b=f.read_bytes();items[name]=(b,stat.S_IMODE(f.stat().st_mode));original[f]=h(b)
# Exact current preparation and its prior failed source/evidence revisions.
for f in E.rglob('*'):
 if '__pycache__' not in f.parts:add(f)
for n in ['AGENTS.md','rebar.config','rebar.lock','doc/spaces.md','doc/multiwrite-architecture.md','doc/ontology-eidolons-plan.md','nimbalyst-local/plans/space-conceptual-architecture-review.md','nimbalyst-local/handoffs/stage2-d5-reconciliation-20261103.md']:
 add(R/n)
# Source-only compiler/baseline snapshots, including failed attempts; no stores,
# emitted beams, dependency installation, native profiles/certificates or obj/bin.
build=R/'_build/stage2-remaining-admission'
allowed={'.erl','.hrl','.pl','.cs','.csproj','.js','.mjs','.py'}
for stage in build.iterdir():
 if not stage.is_dir():continue
 for f in (stage/'source').rglob('*'):
  if f.suffix in allowed and not set(f.parts)&{'bin','obj','.godot','nuget','node_modules'}:
   add(f,'compiler-and-baseline-source/'+str(f.relative_to(build)))
 for f in stage.glob('*.erl'):add(f,'compiler-and-baseline-source/'+str(f.relative_to(build)))
# Validate unchanged production and the exact reviewed patch preimages/afterimages.
start=json.loads((E/'inputs/starting-source.json').read_text())
assert all((R/n).is_file() and h((R/n).read_bytes())==digest for n,digest in start.items())
for label,base in [('manifest.json','proposal-after'),('namespace-manifest.json','namespace-after')]:
 for n,row in json.loads((E/'proposals'/label).read_text())['files'].items():
  assert h((E/base/n).read_bytes())==row['after'],n
prior={}
for name in ['stage2-presentation-limits01','stage2-presentation-limits02','stage2-presentation-limits03','stage2-presentation-limits04','stage2-presentation-boundaries01','stage2-presentation-boundaries-parent01']:
 p=R/'nimbalyst-local/review-packets'/name;record=json.loads((p/'result.json').read_text());found={}
 for key,file in [('archive_sha256','snapshot.tar'),('manifest_sha256','manifest.json')]:
  found[key]=h((p/file).read_bytes());assert found[key]==record[key],name
 prior[name]=found;add(p/'result.json')
for n in ['claude-fable-review.md','inputs/claude-heap-probe-evidence-correction.md','inputs/approval-rejections.json']:
 add(R/'doc/evidence/stage2-presentation-limits-20261103'/n)
for n in ['RESULTS.md','EVIDENCE-CORRECTIONS.md','inputs/carrier-edit-rejected-command.json','inputs/carrier-edit-rejection01.json']:
 add(R/'doc/evidence/stage2-presentation-boundaries-20261103'/n)
P.mkdir()
manifest={n:dict(sha256=h(b),bytes=len(b),mode=m) for n,(b,m) in sorted(items.items())}
mp=P/'manifest.json';ap=P/'snapshot.tar';mp.write_text(json.dumps(manifest,indent=2)+'\n')
with tarfile.open(ap,'w') as out:
 for n,(b,m) in sorted(items.items()):
  info=tarfile.TarInfo(n);info.size=len(b);info.mode=m;info.mtime=0;out.addfile(info,io.BytesIO(b))
with tarfile.open(ap) as inp:
 assert len(inp.getmembers())==len(manifest)
 for member in inp.getmembers():assert h(inp.extractfile(member).read())==manifest[member.name]['sha256'],member.name
assert all(h(f.read_bytes())==digest for f,digest in original.items()),'Source changed during freeze'
result=dict(freeze_verified=True,source_label='applied-carrier02',proposal_revision='consolidated02',applied_production_delta=dict(added=0,removed=0),proposal_delta=json.loads((E/'inputs/proposal-delta02.json').read_text()),files=len(manifest),archive_sha256=h(ap.read_bytes()),manifest_sha256=h(mp.read_bytes()),archive_bytes=ap.stat().st_size,patches={p.name:h(p.read_bytes()) for p in (E/'proposals').glob('*.patch')},prior_freezes_verified=prior,proposed_modules_executed=False,dependency_pin_changed=False,storage_migration_performed=False,scope_accepted=False,large_signed_display_accepted=False,original_aggregate_30s_three_renewal_acceptance='failed',whole_tree_acceptance=False,fixture_stores_profiles_credentials_and_beams_included=False,source_unchanged_after_freeze=True,approval='Unapplied remainder requires consolidated application authority; dependency delivery and storage cutover remain separate.')
(P/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k not in ['proposal_delta','prior_freezes_verified']},indent=2))
