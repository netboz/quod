from pathlib import Path
import hashlib,json,tarfile,os
R=Path.cwd();E=Path(__file__).resolve().parent;P=R/'nimbalyst-local/review-packets/stage2-renewal-diagnosis01'
P.mkdir(mode=0o700,exist_ok=False);os.umask(0o077)
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
base=json.loads((E/'inputs/runtime02.json').read_text());unchanged={}
for n,digest in base['source_inputs'].items():
 if n.startswith(('src/','include/','priv/ontologies/','_build/default/lib/erlog/src/')):
  assert h(R/n)==digest,n
  unchanged[n]=digest
files={}
def add(p):
 if p.is_file():files[str(p.relative_to(R))]={'sha256':h(p),'bytes':p.stat().st_size}
for p in E.rglob('*'):
 if '__pycache__' not in p.parts:add(p)
for name in ['nimbalyst-local/plans/space-conceptual-architecture-review.md','nimbalyst-local/handoffs/stage2-d5-reconciliation-20261103.md','AGENTS.md','rebar.config','rebar.lock']:add(R/name)
for label in ['runtime02','configured-current01','configured-candidate01','configured-candidate04']:
 B=R/'_build/stage2-renewal-diagnosis'/label
 for prefix in (['source','lib/quod/ebin'] if label=='runtime02' else ['source/_build/default/lib/erlog','source/src/quod_committed_projection.erl','source/src/quod_erlog_db_local_prove.erl','source/test/quod_ask_tests.erl','lib/quod/ebin/quod_committed_projection.beam','lib/quod/ebin/quod_erlog_db_local_prove.beam','lib/quod/ebin/quod_ask_tests.beam']):
  p=B/prefix
  if p.is_file():add(p)
  else:
   for f in p.rglob('*'):add(f)
for pattern in ['*/*.raw','server-*/server-raw.log','*/result.json','*/result.json.work.json','production-candidate01/*.beam']:
 for p in (R/'_build/stage2-renewal-diagnosis').glob(pattern):add(p)
# Retain exact authored native client inputs from its successful build manifest.
client=json.loads((E/'inputs/client-aggregate01-build.json').read_text())
client_root=R/'_build/stage2-renewal-diagnosis/client-aggregate01/source'
for p in client_root.rglob('*'):
 if p.is_file() and not any(x in p.parts for x in ['.godot','obj','bin']):add(p)
# Keep the removable selection probe and the compiled candidate's new tests.
for label,names in [('configured-selection-probe01',['source/src/quod_transaction_scope.erl']),('configured-candidate04',['selection_cost_tests.erl','selection_cost_tests.beam','reason_admission_tests.erl','reason_admission_tests.beam'])]:
 for n in names:add(R/'_build/stage2-renewal-diagnosis'/label/n)
manifest={'source_label':'renewal-diagnosis01','files':dict(sorted(files.items())),'production_unchanged':unchanged,'candidate_installed':False}
(P/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
with tarfile.open(P/'snapshot.tar.gz','w:gz') as tar:
 for n in sorted(files):tar.add(R/n,arcname=n,recursive=False)
with tarfile.open(P/'snapshot.tar.gz','r:gz') as tar:
 for m in tar:
  assert hashlib.sha256(tar.extractfile(m).read()).hexdigest()==files[m.name]['sha256'],m.name
result={'freeze_verified':True,'source_label':'renewal-diagnosis01','files':len(files),'manifest_sha256':h(P/'manifest.json'),'archive_sha256':h(P/'snapshot.tar.gz'),'candidate_installed':False,'production_delta':{'added':0,'removed':0},'proposal_production_delta':{'added':16,'removed':10},'historical_original_aggregate_acceptance':'failed and retained','isolated_candidate_original_aggregate_acceptance':'passed','installed_aggregate_acceptance':'not run; candidate uninstalled','dependency_pin':'5cad93c71579f138e053b3bb971c050bf2dacb7c','hardware':False,'deployment':False,'user_stores_accessed':False}
(P/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
