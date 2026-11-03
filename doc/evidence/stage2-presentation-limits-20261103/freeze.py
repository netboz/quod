"""Freeze partial applied source, unapplied proposals and literal failed evidence."""
from pathlib import Path
import hashlib,json,tarfile,io,stat,subprocess
r=Path('/home/yan/src/quod_worktrees/pearl-stone');e=Path(__file__).resolve().parent
packet=r/'nimbalyst-local/review-packets/stage2-presentation-limits03'
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
a=json.loads((e/'inputs/account.json').read_text());files={}
for row in a['production_delta']['paths']:
 assert h(r/row['path'])==row['current_sha256'];files[row['path']]=r/row['path']
for n in ['AGENTS.md','doc/spaces.md','doc/multiwrite-architecture.md','doc/eidolon-mesh-support.md','doc/gui-implementation-plan.md','doc/ontology-eidolons-plan.md','nimbalyst-local/plans/space-conceptual-architecture-review.md','nimbalyst-local/handoffs/stage2-d5-reconciliation-20261103.md','test/quod_rendering_tests.erl','test/quod_lens_tests.erl','test/quod_voxel_tests.erl','client/test/marks.test.js','client/test/glb-profile.test.js','client/test/voxel-profile.test.js','client/test/world.test.js','client/native/tools/check.py']:
 files[n]=r/n
for n in ['src/quod_scope_session.erl','src/quod_proof_session.erl','src/quod_scope_wire.erl','src/quod_dtx.erl','src/predicates/quod_ask.erl','src/quod_wire_term.erl','src/quod_client_result.erl','src/quod_client_view.erl','src/quod_client_goal_endpoint.erl','src/quod_terrain_wire.erl','src/quod_link.erl','include/quod_client_goal_limits.hrl','include/quod_proof_limits.hrl','include/quod_transport_limits.hrl','include/quod_term_limits.hrl']:
 assert h(r/n)==h(e/'before'/n),n
 files[n]=r/n
for p in (e/'proposals').glob('*.json'):
 for row in json.loads(p.read_text())['files']:
  assert h(r/row['path'])==row['before_sha256'];files[row['path']]=r/row['path']
for p in e.rglob('*'):
 if p.is_file() and '__pycache__' not in p.parts:files[str(p.relative_to(r))]=p
for receipt in (e/'inputs').glob('*-build.json'):
 b=json.loads(receipt.read_text());stage=Path(b['stage'])/'source'
 for n,digest in b['source_inputs'].items():
  assert h(r/n)==digest,n;files[n]=r/n
  if n not in b['diagnostic_inputs']:assert h(stage/n)==digest,n
 for n,digest in b['diagnostic_inputs'].items():
  assert h(stage/n)==digest;files['executed-diagnostic/'+receipt.stem+'/'+n]=stage/n
for receipt in (e/'inputs').glob('*.json'):
 x=json.loads(receipt.read_text())
 if 'inputs' in x and isinstance(x['inputs'],dict):
  for n,row in x['inputs'].items():
   if isinstance(row,dict) and 'copy' in row:
    p=Path(row['copy']);assert h(p)==row['sha256'];files['executed-owner/'+receipt.stem+'/'+n]=p
for label,row in a['runs'].items():
 if '-signed' not in label:continue
 assert all(row['eof'].values()) and not row['reader_errors']
 private=r/'_build/stage2-presentation-limits'/label;server=private.parent/('server-'+label)
 for n in ['signed.py','serve.py']:
  if (private/n).exists():files['executed-driver/'+label+'/'+n]=private/n
 for n in ['quod_lifecycle_single_path_tests.erl','godot_m3b_fixture.erl','godot_m3b_physics_fixture.erl','stage2_cursor_trace.erl']:
  if (server/n).exists():files['executed-fixture/'+label+'/'+n]=server/n
old=r/'nimbalyst-local/review-packets/stage2-predicate-composition01'
assert h(old/'snapshot.tar')=='80e7ebad24c25482a47a818a7dafca6bb15114d9243fcf453d031f4471aaeeea'
assert h(old/'manifest.json')=='ab5b02e9e15fab89b7be433736b0432a7861f909b49ed6f395ad6deb936f904e'
files['prior-freeze/composition01-result.json']=old/'result.json'
for n in ['doc/evidence/godot-space-experience-20261101/inputs/space-name-owner03.json','doc/evidence/godot-occurrence-visibility-20261102/inputs/client-visibility-product01-manifest.json']:
 files[n]=r/n
stage=Path('/data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source')
files['referenced-runtime/source-manifest.json']=stage.parent/'source-manifest.json'
for n in ['test/quod_lifecycle_single_path_tests.erl','test/quod_physics_tests.erl','test/quod_agent_hosting_tests.erl','test/quod_ct.erl','_build/default/lib/erlog/src/erlog_int.hrl']:
 files['referenced-runtime/'+n]=stage/n
packet.mkdir(parents=True,exist_ok=False)
manifest={n:{'sha256':h(p),'bytes':p.stat().st_size,'mode':stat.S_IMODE(p.stat().st_mode)} for n,p in sorted(files.items())}
(packet/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
with tarfile.open(packet/'snapshot.tar','w') as archive:
 for n,p in sorted(files.items()):
  data=p.read_bytes();assert hashlib.sha256(data).hexdigest()==manifest[n]['sha256'];info=tarfile.TarInfo(n);info.size=len(data);info.mode=manifest[n]['mode'];info.mtime=0;archive.addfile(info,io.BytesIO(data))
with tarfile.open(packet/'snapshot.tar','r') as archive:
 assert len(archive.getmembers())==len(manifest)
 for member in archive.getmembers():assert hashlib.sha256(archive.extractfile(member).read()).hexdigest()==manifest[member.name]['sha256']
assert all(h(p)==manifest[n]['sha256'] for n,p in files.items())
result={'freeze_verified':True,'scope_accepted':False,'source_label':'applied-presentation01','proposal_revision':2,'files':len(manifest),'archive_sha256':h(packet/'snapshot.tar'),'manifest_sha256':h(packet/'manifest.json'),'archive_bytes':(packet/'snapshot.tar').stat().st_size,'production_delta':a['production_delta'],'runs':a['runs'],'large_signed_display_accepted':False,'unapplied_proposals':['nested-goal-owner','presentation-reply-owner'],'whole_tree_acceptance':False,'private_state_and_credentials_included':False,'package_release_or_deploy':False,'prior_composition_freeze_unchanged':True,'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=r,text=True).strip()}
(packet/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:v for k,v in result.items() if k not in ['production_delta','runs']}))
