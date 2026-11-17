"""Verify completed new receipts and scope, never rerun a product campaign."""
import datetime,hashlib,json,re,sys
from pathlib import Path
sys.dont_write_bytecode=True
from freeze_hashes import Digests,TASK,key,raw
ev=Path(__file__).resolve().parent;root=Path.cwd();d=Digests()
def load(p):return json.loads(Path(p).read_text())
def write(p,v):Path(p).write_text(json.dumps(v,indent=2)+'\n')
case=ev.parent/'godot-m4-vive-retest-20261030/native-vive-product10';r=load(case/'result.json');c=load(case/'client-result.json')
wrapper=ev.parent/'godot-m4-vive-physical-20261029/logs/native-vive-product10-run.json';w=load(wrapper)
assert r['passed'] and r['product_finished'] and r['product_ready']
assert all(r[n+'_exit']==0 for n in ['client','runtime','server']) and w['child_exit']==0
assert not r['reader_errors'] and not w['reader_errors'] and not r['diagnostics']
assert all(r['eof'].values()) and all(w['eof'].values()) and not r.get('client_timeout') and not w.get('timed_out')
assert not any('stack_capture' in k for k in r)
assert r['startup_inventory']['exit']==0 and r['startup_inventory']['wand_devices']==2
assert r['original_calibration_unchanged'] and not r['runtime_processes_after']
assert r['display_rule']['desktop_unchanged'] and r['display_rule']['config_unchanged']
assert next(m for m in r['display_rule']['after']['monitors'] if m['name']=='HDMI-A-1')['disabled']
redactions={p['published_path']:p for p in load(ev/'publication-redaction.json')['changes']};streams={}
for name,row in r['streams'].items():
 p=Path(row['raw']);assert p.stat().st_mode&0o7777==0o600 and p.parent.stat().st_mode&0o7777==0o700
 data=p.read_bytes();assert hashlib.sha256(data).hexdigest()==row['sha256'] and len(data)==row['bytes']
 published=case/(name+'.log');expected=re.sub(rb'(?i)LHR-[A-Za-z0-9]+',b'<device-serial-redacted>',data)
 if str(published) in redactions:
  correction=redactions[str(published)];assert hashlib.sha256(expected).hexdigest()==correction['producer_published_sha256']==row['sanitized_sha256']
  expected,count=re.subn(rb'\bLHB-[A-Za-z0-9]+',b'<base-station-serial-redacted>',expected);assert count==correction['replacements']
  assert hashlib.sha256(expected).hexdigest()==correction['current_published_sha256']
 else:assert hashlib.sha256(expected).hexdigest()==row['sanitized_sha256']
 assert published.read_bytes()==expected
 assert not re.search(rb'\b(?:LHR|LHB)-[A-Za-z0-9]+',expected)
 streams[name]={'current_public_sha256':hashlib.sha256(expected).hexdigest(),'raw_sha256':row['sha256'],'raw_mode':'0600','eof':r['eof'][name]}
for kind,row in w['streams'].items():
 p=Path(row['path']);assert p.stat().st_mode&0o7777==0o600 and raw(p)==row['sha256']
 assert raw(wrapper.parent/('native-vive-product10-run-'+kind+'.log'))==row['sanitized_sha256']
api=load(ev/'api-lifecycle.json');assert api['raw_sha256']==r['api_dump']['sha256'] and api['raw_bytes']==r['api_dump']['bytes']
# The completed one-pass parser did not retain pre/post stat keys. Complete the
# missing strict binding with one separately labelled byte-only digest pass;
# do not replay its parsing, a campaign or any older dump.
dump=Path(r['api_dump']['path']);before=key(dump);assert dump.stat().st_mode&0o7777==0o600
assert d.h(dump)==api['raw_sha256'] and key(dump)==before
write(ev/'api-strict-binding.json',{'path':str(dump),'sha256':api['raw_sha256'],'bytes':api['raw_bytes'],'stat_key':before,
 'scope':'New completed case10 only. One parse already completed; this remaining byte-only stat binding does not parse or run anything.',
 'parse_count':1,'additional_byte_binding_pass':True,'raw_bytes_remain_private':True})
last=c['snapshots'][-1];metrics=last['metrics'];resources=metrics['resources']
assert len(c['checks'])==13 and last['phase']=='observer-retired'
assert metrics['Subscriptions']==metrics['sources']==metrics['appearances']==metrics['captures']==0
assert resources['Acquisitions']==resources['Releases']==resources['InstancesCreated']==resources['InstancesReleased']==2
assert resources['LiveTemplates']==resources['LiveLeases']==0 and metrics['LateCallbacks']==0
assert all(s.get('phase')!='ninety_frames' for s in c['snapshots'])
assert all(row.get('diagnostic_instruction') not in ['sample','gui-check','close-form','restart'] for row in r['commands'])
observed=[s for s in c['snapshots'] if s.get('metrics',{}).get('resources',{}).get('Acquisitions')==2 and s['metrics']['resources']['Releases']==0]
assert all([s['metrics']['resources'][n] for n in ['Acquisitions','Decodes','InstancesCreated','NodesBuilt','TexturesDecoded']]==[2,1,2,114,1] for s in observed)
human=load(ev/'visual-response-80.json')['answer'];assert human['respondedAt']==1793358716056
answers=human['answers'];assert answers['headset_view']['selectedId']=='both_lenses' and answers['panel_readability']['selectedId']=='readable_comfortable'
exact='both missing. They were in visible only from one small black box';assert answers['controller_models']['otherText']==exact
pure=load(ev/'focus-checks-result.json');assert pure['passed'] and pure['count']==14 and not pure['actual_listener_armed']
assert (ev/'focus_events.py').read_bytes()==(TASK/'private/metadata-inputs/case10-focus-checks01/focus_events.py').read_bytes()
qualification={'checkpoint':'QUO-65 corrected-payload native-vive-product10 and offline event observer',
 'worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','actual_api_model':'openai-codex:gpt-6.1-sol','launcher_requested_and_returned_effort':'max','effective_backend_effort':'unexposed',
 'branch':'worktree/pearl-stone','head':'293cf6115c0a6b18315eccdbb42cbca396f443d3','parent':'f716ddf5e578df957a5b18421a0727a32c634f87','product_source_changes':0,
 'supplied_inputs_unchanged':93,'exported_files_unchanged':196,'new_builds_or_server_core_suites':0,'diagnostic_nondistributable':True,
 'client_runtime_server_driver_wrapper_exits':[0,0,0,0,0],'case_eof':r['eof'],'wrapper_eof':w['eof'],'reader_errors':[],'diagnostics':[],'watchdog_or_stack':False,'elapsed_seconds':w['elapsed_seconds'],
 'helper_checks_passed':13,'literal_helper_passed_scope':'Signed preparation/read-only observation/retirement only; not controller visibility or full physical acceptance.',
 'human':{'responded_at':human['respondedAt'],'both_lens_interface':True,'front_readable_comfortable_panel':True,'controller_exact_other':exact,'controller_visibility_pass':False,'neutral_or_sample_permission':False,'scope':'One actual look on this diagnostic payload; no general comfort claim.'},
 'later_pose_counts':[{'hand':s['hand'],'tracked_frames':s['tracked_frames'],'internal_adjusted_pose_disagreements':s['pose_disagreements'],'raw_edges':len(s['edges'])} for s in last['sources']],
 'pose_scope':'Recorded FramePostDraw availability/counts; Current(0) is not a separate freshness proof. Post-answer geometry cannot qualify the earlier human interval. Ninety-draw gate unrun.',
 'model_work_unchanged_in_recorded_repeats':{'acquisitions':2,'decodes':1,'instances':2,'nodes':114,'textures':1,'server_history_read_write_sync':'Not newly measured; unchanged accepted software evidence reused.'},
 'final_metrics':metrics,'api_counts':api['counts'],'api_layer_counts':api['submitted_layer_counts'],'api_projection_view_counts':api['projection_view_counts'],'api_scope':api['scope'],
 'focus_extension81':'UNRUN: normal stop11:18:35/finish11:18:41 occurred before instruction81 at11:20:03.725. Closed PID/address/exec never reused.',
 'prepared_event_listener':{'sha256':raw(ev/'focus_events.py'),'pure_checks':14,'pure_child_exit':0,'actual_listener_armed':False,'live_qualification':'UNRUN; future separately authorized owned case required.','snapshot_limit':'No socket2 acknowledgement or cross-socket ordering barrier/sequence; snapshot never overwrites event stream state.'},
 'streams':streams,'calibration_unchanged':True,'hdmi_restored_disabled':True,'other_displays_and76_configs_unchanged':True,
 'remaining':['Controller visibility/contrast and ambiguous black-box observation remain unresolved; no asset/light/pose/focus-policy cause established for the earlier look.',
 'Formal ninety-draw/current pose agreement and signed physical GUI/movement/neutral/focus/disconnect/reentry/comfort remain unrun.',
 'Future event observer requires actual new case authority/readiness; no automatic11 or human question. Historical08/09/cold-head and desktop stalls remain failed. No fullM4/QUO27/QUO59/Stage2/Quest credit.']}
write(ev/'qualification.json',qualification)
cache=TASK/'cache/case10-result-verification-hashes.json';d.write(cache)
write(ev/'result-cache.json',{'path':str(cache),'sha256':raw(cache),'strict_hits':d.hits,'new_hashes':d.new,'new_bytes':d.bytes})
print(json.dumps({'passed':True,'scope':'New receipt/source/privacy binding only; no product replay.','helper_checks':13,'pure_offline_checks':14,'full_physical_acceptance':False}))
