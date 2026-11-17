"""Freeze this bounded source/evidence scope without modifying prior packets."""
import hashlib,json,tarfile,io,stat,subprocess,sys
from pathlib import Path
root=Path('/home/yan/src/quod_worktrees/pearl-stone');ev=root/'doc/evidence/stage2-predicate-subjects-20261103'
packet=root/'nimbalyst-local/review-packets'/('stage2-predicate-subjects'+sys.argv[1]);packet.mkdir(parents=True,exist_ok=False)
h=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
build=json.loads((ev/'inputs/candidate06-build.json').read_text());server=json.loads((ev/'inputs/server-candidate-signed05.json').read_text());run=json.loads((ev/'inputs/candidate-signed05.json').read_text())
assert build['passed'] and run['passed'] and server['child_exit']==0
assert all(run['eof'].values()) and all(c['true_exit']==0 for c in run['children'].values())
assert all(h(root/n)==digest for n,digest in build['source_inputs'].items())
assert all(h(root/n)==row['sha256'] for n,row in server['executed_current_sources'].items())
assert all(h(Path(build['stage'])/'source'/n)==digest for n,digest in build['diagnostic_inputs'].items())
files={n:root/n for n in build['source_inputs']};files.update({n:root/n for n in server['executed_current_sources']})
for n in ['AGENTS.md','doc/spaces.md','doc/multiwrite-architecture.md','doc/ontology-eidolons-plan.md','doc/system-ontology-acls.md','nimbalyst-local/plans/space-conceptual-architecture-review.md','nimbalyst-local/handoffs/stage2-d5-reconciliation-20261103.md','client/native/tools/check.py']:
 files[n]=root/n
for p in ev.rglob('*'):
 if p.is_file():files[str(p.relative_to(root))]=p
private=root/'_build/stage2-predicate-subjects/server-candidate-signed05'
for n in ['quod_lifecycle_single_path_tests.erl','godot_m3b_fixture.erl','godot_m3b_physics_fixture.erl']:
 files['executed-fixture/'+n]=private/n
stage=Path(server['stage'])
for n in ['test/quod_lifecycle_single_path_tests.erl','test/quod_physics_tests.erl']:
 files['referenced-server/'+n]=stage/n
files['referenced-server/source-manifest.json']=stage.parent/'source-manifest.json'
files['referenced-server/space-name-owner03.json']=root/'doc/evidence/godot-space-experience-20261101/inputs/space-name-owner03.json'
# These source-only imported custody helpers are part of this driver's execution.
for n in ['doc/evidence/godot-m4-presentation-20261030/digests.py','doc/evidence/godot-occurrence-visibility-20261102/inputs/client-visibility-product01-manifest.json']:
 files[n]=root/n
manifest={n:{'sha256':h(p),'bytes':p.stat().st_size,'mode':stat.S_IMODE(p.stat().st_mode)} for n,p in sorted(files.items())}
(packet/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
with tarfile.open(packet/'snapshot.tar','w') as archive:
 for n,p in sorted(files.items()):
  row=manifest[n];data=p.read_bytes();assert hashlib.sha256(data).hexdigest()==row['sha256']
  info=tarfile.TarInfo(n);info.size=len(data);info.mode=row['mode'];info.mtime=0;archive.addfile(info,io.BytesIO(data))
with tarfile.open(packet/'snapshot.tar','r') as archive:
 assert len(archive.getmembers())==len(manifest)
 for member in archive.getmembers():
  data=archive.extractfile(member).read();assert hashlib.sha256(data).hexdigest()==manifest[member.name]['sha256'];assert member.mode==manifest[member.name]['mode']
assert all(h(p)==manifest[n]['sha256'] for n,p in files.items())
result={'passed':True,'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'source_label':'candidate06','signed_label':'candidate-signed05','signed_checks':len(run['checks']),'live_client_input_matches':len(build['source_inputs']),'live_server_input_matches':len(server['executed_current_sources']),'files':len(manifest),'archive_sha256':h(packet/'snapshot.tar'),'manifest_sha256':h(packet/'manifest.json'),'archive_bytes':(packet/'snapshot.tar').stat().st_size,'verified_every_archived_member':True,'production_delta':json.loads((ev/'inputs/production-delta.json').read_text()),'private_state_and_credentials_included':False,'release_or_package':False,'whole_tree_acceptance':False}
(packet/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:v for k,v in result.items() if k!='production_delta'}))
