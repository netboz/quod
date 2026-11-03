"""Retain follow-up outcomes and exact source bindings; no runtime rerun or reclassification as a pass."""
from pathlib import Path
import hashlib,json,shutil
r=Path('/home/yan/src/quod_worktrees/pearl-stone');e=r/'doc/evidence/stage2-predicate-subjects-20261103'
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def retain(source,target):
 if target.exists():assert target.read_bytes()==source.read_bytes()
 else:shutil.copy2(source,target)
accepted=json.loads((e/'inputs/production-delta.json').read_text())
assert all(h(r/x['file'])==x['after_sha256'] for x in accepted['files'])
classifications=[
 'Fixture error: retract-all leaves an empty interpreted definition; waiting for definition withdrawal was invalid.',
 'Fixture error confirmed by signed reads: retract-all empties source but does not remove the definition.',
 'Rejected catalogue-filter experiment on the same invalid retract-all fixture. Production filter fully reverted; this label does not qualify current source.',
 'Corrected signed abolish confirms existing durable lifecycle gap: commit lowers abolish to retractions, retaining an empty interpreted definition. Definition-withdrawal requirement remains unverified.'
]
runs={}
for i in range(1,5):
 label=f'lifecycle-signed{i:02}';buildlabel=f'lifecycle{i:02}';private=r/'_build/stage2-predicate-subjects'/label
 receipt=json.loads((e/'inputs'/f'{label}.json').read_text());build=json.loads((e/'inputs'/f'{buildlabel}-build.json').read_text());server=json.loads((e/'inputs'/f'server-{label}.json').read_text())
 assert not receipt['passed'] and receipt['failure']=='AssertionError: client failure'
 assert receipt['children']['client']['true_exit']==1 and receipt['children']['server']['true_exit']==0
 assert all(receipt['eof'].values()) and not receipt['reader_errors'] and not receipt.get('unretired_failure') and not receipt.get('cleanup_timeout')
 assert build['passed'] and all(h(r/n)==v for n,v in build['source_inputs'].items())
 diagnostic={}
 for n,digest in build['diagnostic_inputs'].items():
  p=Path(build['stage'])/'source'/n;assert h(p)==digest
  dst=e/'inputs'/f'{buildlabel}-{p.name}';retain(p,dst);diagnostic[str(dst.relative_to(r))]=digest
 drivers={}
 for name in ['signed.py','serve.py','PredicateLifecycleChecks.cs']:
  p=private/name;dst=e/'inputs'/f'{label}-executed-{name}';retain(p,dst);drivers[str(dst.relative_to(r))]=h(p)
 for info in receipt['streams'].values():assert h(Path(info['path']))==info['sha256']
 for name,row in server['executed_current_sources'].items():assert h(Path(row['saved_source']))==row['sha256']
 positive=[line[5:] for line in (private/'client-stdout.raw').read_text().splitlines() if line.startswith('PASS ')]
 assert 'ordinary reconnect restores the same exact authorized predicate in a new signed session' in positive
 observation=None;obs=private/'result.json.deletion.json'
 if obs.exists():
  observation=json.loads(obs.read_text());assert observation=={'catalogue_retains_name':True,'stored_source_bytes':0,'current_choice_count':1}
  retain(obs,e/'inputs'/f'{label}-deletion.json')
 runs[label]={'runtime_passed':False,'wrapper_exit':1,'client_exit':1,'server_exit':0,'all_four_eof':True,'forced_termination':False,'wrapper_failure_literal':receipt['failure'],'first_child_exception_literal':(private/'client-stderr.raw').read_text().splitlines()[0],'classification':classifications[i-1],'completed_assertions':positive,'completed_assertions_are_not_whole_campaign_pass':True,'observation':observation,'build_label':buildlabel,'diagnostic_inputs':diagnostic,'executed_drivers':drivers,'common_predicates_sha256':server['executed_current_sources']['priv/ontologies/common_predicates.pl']['sha256']}
server=json.loads((e/'inputs/server-lifecycle-signed04.json').read_text());stage=Path(server['stage']);owners={}
for name in ['src/quod_erlog_db_local_prove.erl','src/quod_diff.erl','src/quod_erlog_db_mvcc.erl','include/quod_ledger.hrl']:
 assert h(r/name)==h(stage/name)
 dst=e/'inputs'/('lifecycle-owner-'+Path(name).name);retain(stage/name,dst)
 row={'current_and_executed_stage_source_sha256':h(r/name),'retained_source':str(dst.relative_to(r))}
 if name.endswith('.erl'):
  beam=stage/'_build/test/lib/quod/ebin'/(Path(name).stem+'.beam');row['executed_stage_object']={'path':str(beam),'sha256':h(beam)}
 owners[name]=row
result={'custody_checks_passed':True,'runtime_campaigns_all_passed':False,'runs':runs,'existing_lifecycle_owner_bindings':owners,'current_production_matches_accepted_37_check_source':True,'additional_production_delta':{'added':0,'removed':0},'total_predicate_slice_production_delta':{'added':41,'removed':7},'definition_withdrawal_verified':False,'reconnect_completed_assertions_verified':True,'whole_tree_acceptance':False,'private_credentials_included':False}
(e/'inputs/lifecycle-accounting.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k not in ['runs','existing_lifecycle_owner_bindings']}))
