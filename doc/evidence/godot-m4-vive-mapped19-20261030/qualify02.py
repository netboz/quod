"""Bind the completed case19 receipts; raw geometry and identity remain private."""
import hashlib,importlib.util,json,math,os,shutil,sys
from pathlib import Path
from case_hashes import TASK,Digests,key,raw
sys.dont_write_bytecode=True;os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
owners=TASK/'private/case19-preparation01/unchanged-owners'
case=owners/'godot-m4-vive-retest-20261030/native-vive-product19'
logs=owners/'godot-m4-vive-physical-20261029/logs'
private=TASK/'private/native-vive-product19'
def load(p):return json.loads(Path(p).read_text())
def write(p,v):Path(p).write_text(json.dumps(v,indent=2)+'\n')
r=load(case/'result.json');c=load(case/'client-result.json');w=load(logs/'native-vive-product19-run.json')
assert r['passed'] and r['product_ready'] and r['product_finished']
assert all(r[n+'_exit']==0 for n in ['client','runtime','server']) and w['child_exit']==0
assert all(r['eof'].values()) and all(w['eof'].values())
assert not r['reader_errors'] and not w['reader_errors'] and not r['diagnostics']
assert not r.get('client_timeout') and not w.get('timed_out') and not any('stack_capture' in k for k in r)
assert r['manual_bound_seconds']==1800 and r['normal_close_watchdog_seconds']==60 and w['bound_seconds']==2100
assert w['elapsed_seconds']<2100
assert r['startup_inventory']['exit']==0 and r['startup_inventory']['wand_devices']==2
instructions=[x['diagnostic_instruction'] for x in r['commands'] if 'diagnostic_instruction' in x]
assert instructions==['status','status','stop','finish']
dispatches=[x for x in r['commands'] if 'command' in x]
assert len(dispatches)==2 and all(x['exit']==0 for x in dispatches)
assert dispatches[0]['after_owned_focus'] and 'window.close' in dispatches[1]['command'][-1]
assert len(c['checks'])==13 and c['snapshots'][-1]['phase']=='observer-retired'
metrics=c['snapshots'][-1]['metrics'];resources=metrics['resources']
assert metrics['Subscriptions']==metrics['sources']==metrics['appearances']==metrics['captures']==0
assert resources['Acquisitions']==resources['Releases']==resources['InstancesCreated']==resources['InstancesReleased']==2
assert resources['LiveTemplates']==resources['LiveLeases']==metrics['LateCallbacks']==0
assert all(metrics[k]==0 for k in ['DriveRequests','StopRequests','SnapRequests','TeleportRequests'])
assert r['original_calibration_unchanged'] and not r['runtime_processes_after']
rule=r['display_rule'];assert rule['desktop_unchanged'] and rule['config_unchanged']
assert next(x for x in rule['after']['monitors'] if x['name']=='HDMI-A-1')['disabled']
assert rule['enable']['child_exit']==rule['restore']['child_exit']==0
display_source=root/'doc/evidence/godot-m4-vr-20261029/vive_display.py'
assert raw(display_source)==r['driver_inputs'][str(display_source.relative_to(root))]
# Reuse the completed first binder's actual display snapshot; no second host query.
first=load(ev/'logs/mapped19-receipt-binding01.json')
assert first['child_exit']==1 and first['driver_inputs']['qualify.py']=='eb90a4717ba66d1dc485267c6aafbc6ccdb025dd90aa8f78cd61b32bc9a6d1af'
assert raw(ev/'qualify.py')==first['driver_inputs']['qualify.py']
copies=TASK/'private/build-inputs/mapped19-closure01'
assert raw(display_source)==raw(copies/'vive_display.py')
prior_refs=load(ev/'restricted-output-references.json')
assert raw(private/'closure-current-display.json')==prior_refs[str(private/'closure-current-display.json')]['sha256']
current_display=load(private/'closure-current-display.json')
desktop=lambda s:sorted([m for m in s['monitors'] if m['name']!='HDMI-A-1'],key=lambda m:m['name'])
assert desktop(current_display)==desktop(rule['before'])
assert current_display['config_sha256']==rule['before']['config_sha256']==rule['after']['config_sha256']
assert next(x for x in current_display['monitors'] if x['name']=='HDMI-A-1')['disabled']
# The retained first binder display receipt is unchanged.
owner_path=TASK/'private/native-vive-product19-invocation.json';owner=load(owner_path)
proc=Path('/proc')/str(owner['pid'])/'stat';same=False
if proc.exists():
    text=proc.read_text();same=text[text.rfind(')')+2:].split()[19]==owner['start_ticks']
assert not same
ready=load(ev/'baseline01.json');waiting=load(ev/'withdrawal01.json')
assert ready['owner_binding_sha256']==waiting['owner_binding_sha256']==raw(owner_path)
deadline=owner['deadline_monotonic'];derivation=owner['derivation']
assert deadline==derivation['observed_monotonic']+1800-math.ceil(derivation['elapsed_since_client_start'])-5
for snapshot in [ready,waiting]:
    assert snapshot['deadline_monotonic']==deadline and snapshot['observed_at_monotonic']<deadline
    assert snapshot['native_session']=='Focused' and snapshot['lifecycle']['NativeRunning'] and snapshot['lifecycle']['PresentationVisible']
    assert snapshot['head']=={'tracked':True,'confidence':'High'}
    assert len(snapshot['sources'])==2
    assert all(x['current'] and x['aim']==x['grip']=={'tracked':True,'confidence':'High'} for x in snapshot['sources'])
assert all(x['visible_roots']==1 and x['visible_meshes']==6 for x in ready['sources'])
assert ready['window_focused'] is False
assert all(x['visible_roots']==x['visible_meshes']==0 for x in waiting['sources'])
assert waiting['window_focused'] is False
raw_wait=load(private/'read-only-captures/withdrawal01.raw.json')['snapshots'][-1]['state']
assert raw_wait['world_accepted'] is False and raw_wait['operation_available'] is False
assert raw_wait['controller_status']['available'] is False and raw_wait['pending']==0 and raw_wait['busy'] is False
operation_status_has_expired=raw_wait['operation_status']=='Sign-in expired; reconnect explicitly.'
assert operation_status_has_expired
safe_prefixes=(b'PASS ',b'M4_VIVE_',b'M4_PHYSICAL_')
sources={name:(Path(row['raw']),row['sha256']) for name,row in r['streams'].items()}
sources.update({'physical-wrapper-'+kind:(Path(row['path']),row['sha256']) for kind,row in w['streams'].items()})
projection_dir=ev/'sanitized-logs'
stream_rows=load(ev/'stream-projections.json')
assert set(stream_rows)==set(sources)
for name,(path,digest) in sources.items():
    row=stream_rows[name]
    assert row['raw_path']==str(path) and row['raw_sha256']==digest
    assert list(key(path))==row['raw_stat_key'] and path.stat().st_size==row['raw_bytes']
    assert path.stat().st_mode&0o7777==0o600 and path.parent.stat().st_mode&0o7777==0o700
    projected=(projection_dir/(name+'.log')).read_bytes()
    assert hashlib.sha256(projected).hexdigest()==row['public_sha256']
    assert owner['address'].encode() not in projected and b'LHR-' not in projected and b'LHB-' not in projected
stderr=Path(r['streams']['client-stderr']['raw']).read_text()
cue_lines=[line for line in stderr.splitlines() if line.startswith('M4_VIVE_LOOK_CUE ')]
assert cue_lines==['M4_VIVE_LOOK_CUE READY frame=2','M4_VIVE_LOOK_CUE WAITING frame=52041']
manifest_path=root/r['client_manifest']['path'];manifest=load(manifest_path)
assert raw(manifest_path)==r['client_manifest']['sha256']=='9073b314599bd64531792acd63cbcd2e21ef54b73a41b25cd041260a4433fb08'
assert len(manifest['supplied_inputs'])==94 and len(manifest['export_outputs'])==196
assert r['engine_sha256']=='02310d903099bada10c86cedc90bbc11ef0bec8254d6e607d1a53f6150ab0268'
assert r['payload']==manifest['export_outputs']
assert raw(owners/'godot-m4-vive-retest-20261030/physical09.py')=='360b166bacb988cb972f53f1d78df15bca70baf95e4a7354c29094fc5cb053c0'
original=(owners/'godot-m4-vive-retest-20261030/physical09.py').read_text()
executed=owners/'godot-m4-vive-retest-20261030/physical19.py'
old="def h(p):\n    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()"
assert original.count(old)==1
replacement='from case_hashes import Digests\ndigests=Digests()\ndef h(p):return digests.h(p)'
assert executed.read_text()==original.replace(old,replacement)
assert raw(executed)==r['driver_inputs']['physical19.py']
refs={}
for path in [case/'result.json',case/'client-result.json',logs/'native-vive-product19-run.json',owner_path,
    private/'client-result.raw.json',private/'display-rule.json',private/'closure-current-display.json',
    private/'read-only-captures/baseline01.raw.json',private/'read-only-captures/withdrawal01.raw.json']:
    refs[str(path)]={'sha256':raw(path),'bytes':path.stat().st_size,'mode':path.stat().st_mode&0o7777,'retained_privately_not_snapshot_object':True}
write(ev/'restricted-output-references.json',refs)
# The actual completed driver already hashed API19 once. Stat custody only;
# this verifier never opens the API or imports an old API's bytes.
api=Path(r['api_dump']['path']);assert api.stat().st_size==r['api_dump']['bytes']
api_ref={'path':str(api),'bytes':r['api_dump']['bytes'],'driver_recorded_sha256':r['api_dump']['sha256'],
    'stat_key':list(key(api)),'parsed':False,'hashed_again':False,'scope':'Original completed-driver digest plus post-exit stat identity only; no entry counts, returned-status or pixels.'}
baseline=load(ev/'baseline-flags.json');withdrawal=load(ev/'withdrawal-flags.json')
assert baseline['world_accepted'] and baseline['operation_available'] and baseline['controller_available']
assert baseline['current_location_present'] and baseline['assignment_revision']=='1'
assert baseline['location_operations_count']==withdrawal['location_operations_count']==0
assert not withdrawal['world_accepted'] and not withdrawal['operation_available'] and not withdrawal['controller_available']
assert withdrawal['operation_status_matches_signin_expired']
assert baseline['pending']==withdrawal['pending']==0 and baseline['busy'] is withdrawal['busy'] is False
assert withdrawal['assignment_revision'] is None
assert [x['bindings'] for x in baseline['sources']]==[['select','drive','snap','teleport'],['select','menu']]
for label in ['baseline01','withdrawal01']:
    snap=load(private/'read-only-captures'/f'{label}.raw.json')['snapshots'][-1]
    assert snap['button_presses'].get('location-operations',0)==0
    assert len(snap['sources'])==2 and all(isinstance(x['edges'],list) and len(x['edges'])==0 for x in snap['sources'])
    assert snap['metrics']['captures']==0
    assert all(snap['metrics'][n]==0 for n in ['DriveRequests','StopRequests','SnapRequests','TeleportRequests'])
assert not any('M4_VIVE_GUI location-operations' in p.read_text() for p in projection_dir.glob('*.log'))
q={'scope':'Case19 physical mapped read-only current-space-panel opportunity, expired sign-in before any recorded trigger edge/activation; normal retirement.',
 'protocol_retirement_passed':True,'physical_mapped_action':'UNRUN/inconclusive: zero recorded native edges, zero target-button activations, no actual human answer supplied.',
 'manual_instructions':instructions,'original_bounds':{'startup':30,'single_inventory':5,'participant':1800,'close':60,'wrapper':2100},
 'client_runtime_server_driver_wrapper_exits':[0,0,0,0,0],'case_eof':r['eof'],'wrapper_eof':w['eof'],'reader_errors':[],
 'case_elapsed_seconds':w['elapsed_seconds'],'timeout_or_stack':False,'target_diagnostics':[],
 'ordinary_launch_focus_dispatches':1,'extra_focus_dispatches':0,'ordinary_owned_close_dispatches':1,'focus_listener_started':False,
 'actual_frame_cue_markers':cue_lines,'baseline_snapshot_utc':ready['node_utc'],'baseline_native_head_both_hands_high_models_visible':True,
 'baseline_window_has_focus_literal':False,'later_withdrawal_snapshot_utc':waiting['node_utc'],'later_native_head_hands_high_models_hidden':True,
 'later_world_accepted':False,'later_operation_available':False,'later_controller_available':False,'later_operation_status':'Sign-in expired; reconnect explicitly.',
 'observed_withdrawal':'Expired sign-in and unavailable world/controller/operation presentation. Full event order and cause of each view transition are not exposed.',
 'assignment_scope':'Presentation revision/location withdraw to null; this is not proof the durable agent assignment moved.',
 'baseline_flags':baseline,'withdrawal_flags':withdrawal,'target_button_counts':[0,0],'recorded_source_edges':[0,0],
 'human_interval':'Root delivered one left-trigger instruction before21:07:36UTC; no human answer/look interval reached worker at binding. Samples are separate instants, not pixels.',
 'no_90sample_menu_submit_travel_or_synthetic_input':True,'final_metrics':metrics,'owned_client_incarnation_retired':True,
 'runtime_processes_after_reported':[],'calibration_unchanged_reported':True,'hdmi_restored_disabled':True,
 'fresh_closure_other_displays_and_current_configs_unchanged':True,'current_config_files':len(current_display['config_sha256']),
 'payload_manifest_sha256':r['client_manifest']['sha256'],'supplied_inputs':94,'export_files':196,'diagnostic_nondistributable':True,
 'new_production_test_spec_or_policy_changes':0,'driver_delta':'Existing cache-based digest owner reused byte-for-byte; new case path/label only. Control, guards and deadlines unchanged.',
 'builds_or_unchanged_suite_recounts':0,'failed_binder01':'Retained true1: expected numeric edge count but actual schema stores a list; both lists are empty. Correction checks type and length, reuses completed display and exact-stat stream qualification.','api_private_reference':api_ref,'full_M4_accepted':False,
 'remaining':['Actual physical mapped GUI/action qualification; no new case20 authority.','Canonical ninety-draw readiness, physical lifecycle/travel/exit/comfort remain scoped gaps.','Broader ontology editing and terrain delivery remain separate; no M5/commit.']}
write(ev/'qualification.json',q)
d.write(TASK/'cache/mapped19-receipt-binding-hashes.json')
write(ev/'receipt-cache.json',{'path':str(TASK/'cache/mapped19-receipt-binding-hashes.json'),'sha256':raw(TASK/'cache/mapped19-receipt-binding-hashes.json'),'api_not_opened':True})
print(json.dumps({'receipt_binding_passed':True,'retirement_all_zero':True,'fresh_display_config_restoration_passed':True,'physical_mapped_action':'UNRUN/inconclusive','api_opened_or_parsed':False}))
