"""Freeze source and public evidence only; preserve all prior packets."""
import hashlib,json,tarfile,io,stat,subprocess
from pathlib import Path
root=Path('/home/yan/src/quod_worktrees/pearl-stone');ev=root/'doc/evidence/stage2-predicate-composition-20261103'
packet=root/'nimbalyst-local/review-packets/stage2-predicate-composition01'
h=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
account=json.loads((ev/'inputs/accounting.json').read_text())
accepted=['candidate-signed04','moved-signed03','allowance-signed01','contents-signed07','delegated-signed02']
for label in accepted:
 row=account['runs'][label];assert row['passed'] and all(row['eof'].values()) and not row['forced_termination'] and not row['reader_errors'];assert all(code==0 for code in row['child_exits'].values())
server=json.loads((ev/'inputs/server-delegated-signed02.json').read_text());build=json.loads((ev/'inputs/delegated02-build.json').read_text())
assert all(h(root/n)==digest for n,digest in build['source_inputs'].items())
assert all(h(root/n)==row['sha256'] for n,row in server['executed_current_sources'].items())
files={n:root/n for n in build['source_inputs']};files.update({n:root/n for n in server['executed_current_sources']})
for n in account['production_delta']['paths']:files[n]=root/n
for n in ['AGENTS.md','doc/spaces.md','doc/multiwrite-architecture.md','doc/ontology-eidolons-plan.md','doc/system-ontology-acls.md','nimbalyst-local/plans/space-conceptual-architecture-review.md','nimbalyst-local/handoffs/stage2-d5-reconciliation-20261103.md','client/native/tools/check.py','client/test/world.test.js','client/test/prolog-edit.test.js','test/quod_lobby_tests.erl']:
 files[n]=root/n
for p in ev.rglob('*'):
 if p.is_file() and '__pycache__' not in p.parts:files[str(p.relative_to(root))]=p
# All historical diagnostic variants and changed build inputs remain reconstructible.
for receipt in (ev/'inputs').glob('*-build.json'):
 row=json.loads(receipt.read_text());stage=Path(row['stage'])/'source'
 for n,digest in row['source_inputs'].items():
  if n in row['diagnostic_inputs']:
   # The receipt separately records the production input and injected harness.
   assert h(root/n)==digest
   assert h(stage/n)==row['diagnostic_inputs'][n]
   files[n]=root/n
  else:
   assert h(stage/n)==digest
   if n not in files or h(files[n])!=digest:files['historical-source/'+digest+'/'+Path(n).name]=stage/n
 for n,digest in row['diagnostic_inputs'].items():
  assert h(stage/n)==digest;files['executed-diagnostic/'+receipt.stem+'/'+n]=stage/n
for label in account['runs']:
 private=root/'_build/stage2-predicate-composition'/label
 for n in ['signed.py','serve.py']:
  if (private/n).is_file():files['executed-driver/'+label+'/'+n]=private/n
 server_private=private.parent/('server-'+label)
 for n in ['quod_lifecycle_single_path_tests.erl','godot_m3b_fixture.erl','godot_m3b_physics_fixture.erl','quod_agent_hosting_tests.erl','stage2_cursor_trace.erl']:
  if (server_private/n).is_file():files['executed-fixture/'+label+'/'+n]=server_private/n
 # Metrics contain function counts only, never accounts or source text.
 for p in private.glob('result.json*work*.json'):files['observed-work/'+label+'/'+p.name]=p
stage=Path(server['stage'])
for n in ['test/quod_lifecycle_single_path_tests.erl','test/quod_physics_tests.erl','test/quod_agent_hosting_tests.erl','_build/default/lib/erlog/src/erlog_int.hrl']:
 files['referenced-server/'+n]=stage/n
files['referenced-server/source-manifest.json']=stage.parent/'source-manifest.json'
for n in ['doc/evidence/godot-space-experience-20261101/inputs/space-name-owner03.json','doc/evidence/godot-m4-presentation-20261030/digests.py','doc/evidence/godot-occurrence-visibility-20261102/inputs/client-visibility-product01-manifest.json']:
 files[n]=root/n
packet.mkdir(parents=True,exist_ok=False)
manifest={n:{'sha256':h(p),'bytes':p.stat().st_size,'mode':stat.S_IMODE(p.stat().st_mode)} for n,p in sorted(files.items())}
(packet/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
with tarfile.open(packet/'snapshot.tar','w') as archive:
 for n,p in sorted(files.items()):
  row=manifest[n];data=p.read_bytes();assert hashlib.sha256(data).hexdigest()==row['sha256']
  info=tarfile.TarInfo(n);info.size=len(data);info.mode=row['mode'];info.mtime=0;archive.addfile(info,io.BytesIO(data))
with tarfile.open(packet/'snapshot.tar','r') as archive:
 assert len(archive.getmembers())==len(manifest)
 for member in archive.getmembers():
  assert hashlib.sha256(archive.extractfile(member).read()).hexdigest()==manifest[member.name]['sha256'];assert member.mode==manifest[member.name]['mode']
assert all(h(p)==manifest[n]['sha256'] for n,p in files.items())
result={'passed':True,'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'accepted_signed_labels':accepted,'current_client_inputs':len(build['source_inputs']),'current_server_inputs':len(server['executed_current_sources']),'files':len(manifest),'archive_sha256':h(packet/'snapshot.tar'),'manifest_sha256':h(packet/'manifest.json'),'archive_bytes':(packet/'snapshot.tar').stat().st_size,'verified_every_archived_member':True,'production_delta':account['production_delta'],'retained_failures':{n:row for n,row in account['runs'].items() if not row['passed']},'private_state_and_credentials_included':False,'whole_tree_acceptance':False,'large_ontology_display_accepted':False,'definition_withdrawal_verified':False,'release_or_package':False}
(packet/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:v for k,v in result.items() if k not in ['production_delta','retained_failures']}))
