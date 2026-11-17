"""Bind completed12 scope without another product run or API read."""
import hashlib,json,sys
from pathlib import Path
sys.dont_write_bytecode=True
from freeze_hashes import Digests,TASK,key,raw
sys.path.insert(0,str(Path(__file__).resolve().parent.parent/'godot-m4-vive-physical-20261029'))
from publication import redact_devices
root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
def load(p):return json.loads(Path(p).read_text())
def write(p,v):Path(p).write_text(json.dumps(v,indent=2)+'\n')
case=ev.parent/'godot-m4-vive-retest-20261030/native-vive-product12';r=load(case/'result.json');c=load(case/'client-result.json')
wrapper=ev.parent/'godot-m4-vive-physical-20261029/logs/native-vive-product12-run.json';w=load(wrapper)
focus_wrapper=ev.parent/'godot-m4-vive-physical-20261029/logs/native-vive-product12-focus-run.json';fw=load(focus_wrapper)
assert r['passed'] and r['product_finished'] and r['product_ready']
assert all(r[n+'_exit']==0 for n in ['client','runtime','server']) and w['child_exit']==fw['child_exit']==0
assert all(r['eof'].values()) and all(w['eof'].values()) and all(fw['eof'].values())
assert not r['reader_errors'] and not w['reader_errors'] and not fw['reader_errors'] and not r['diagnostics']
assert not r.get('client_timeout') and not w.get('timed_out') and not fw.get('timed_out')
assert not any('stack_capture' in k for k in r)
assert r['startup_inventory']['exit']==0 and r['startup_inventory']['wand_devices']==2
instructions=[x['diagnostic_instruction'] for x in r['commands'] if 'diagnostic_instruction' in x]
assert instructions==['geometry','geometry','geometry','stop','finish']
dispatches=[x for x in r['commands'] if 'command' in x]
assert len(dispatches)==3 and all(x['exit']==0 for x in dispatches)
assert dispatches[0]['after_owned_focus'] and dispatches[1]['after_owned_focus']
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
for p,digest in rule['after']['config_sha256'].items():assert raw(Path(p))==digest
streams={}
for name,row in r['streams'].items():
    p=Path(row['raw']);assert p.stat().st_mode&0o7777==0o600 and p.parent.stat().st_mode&0o7777==0o700
    data=p.read_bytes();assert hashlib.sha256(data).hexdigest()==row['sha256'] and len(data)==row['bytes']
    published=case/(name+'.log');expected=redact_devices(data)
    assert published.read_bytes()==expected and hashlib.sha256(expected).hexdigest()==row['sanitized_sha256']
    streams[name]={'raw_sha256':row['sha256'],'public_sha256':row['sanitized_sha256'],'raw_mode':'0600','eof':r['eof'][name]}
for label,record in [('native-vive-product12-run',w),('native-vive-product12-focus-run',fw)]:
    for kind,row in record['streams'].items():
        p=Path(row['path']);assert p.stat().st_mode&0o7777==0o600 and raw(p)==row['sha256']
        assert redact_devices(p.read_bytes())==(wrapper.parent/(label+'-'+kind+'.log')).read_bytes()
events_path=TASK/'private/native-vive-product12-focus/filtered-events.jsonl'
assert events_path.stat().st_mode&0o7777==0o600 and events_path.parent.stat().st_mode&0o7777==0o700
data=events_path.read_bytes();assert data.endswith(b'\n');events=[json.loads(line) for line in data.splitlines()]
assert all(set(row)<={'kind','monotonic','utc','owned','ordered_event_barrier','incomplete_line','error'} for row in events)
assert all(type(row['owned']) is bool for row in events if 'owned' in row)
f=load(events_path.parent/'result.json');assert f['armed'] and f['subscription_count']==1 and not f['errors'] and not f['unparsed_fragment']
assert f['local_connection_closed'] and not f['remote_eof_observed'] and events[-1]['kind']=='local_subscription_close' and not events[-1]['incomplete_line']
owner=load(TASK/'private/native-vive-product12-focus-invocation.json');deadline=owner['deadline_monotonic']
assert max(row['monotonic'] for row in events)<deadline
assert deadline==owner['derivation']['observed_monotonic']+1800-__import__('math').ceil(owner['derivation']['elapsed_since_client_start'])-5
after=load(ev/'after-focus01.json');lost=load(ev/'focus-loss01.json')
assert after['deadline_monotonic']==lost['deadline_monotonic']==deadline
assert after['active_owned'] and after['lifecycle']['ApplicationFocused'] and not after['window_focused']
assert all(s['current'] and s['visible_roots']==1 and s['visible_meshes']==6 for s in after['sources'])
assert not lost['active_owned'] and not lost['lifecycle']['ApplicationFocused'] and not lost['window_focused']
assert all(s['current'] and s['visible_roots']==s['visible_meshes']==0 for s in lost['sources'])
anchor=next(row for row in events if row.get('owned') is True and row['monotonic']>load(ev/'pre-focus-owner-guard.json')['checked_monotonic'])
loss=next(row for row in events if row.get('owned') is False and row['monotonic']>anchor['monotonic'])
assert anchor['utc']=='2026-10-30T12:22:51.897339+00:00' and loss['utc']=='2026-10-30T12:23:01.426439+00:00'
cancel=load(ev/'visual-cancel-response-89.json');assert not cancel['rootLookConfirmationIssued']
answer=json.loads(cancel['actualToolResponse']['content'][0]['text']);assert answer['cancelled'] is True and answer['respondedBy']=='desktop' and answer['respondedAt']==1793363140589
api=load(ev/'api-lifecycle.json');dump=Path(api['raw_path']);current=key(dump)
assert list(current)==api['raw_stat_key'] and api['raw_sha256']==r['api_dump']['sha256'] and api['raw_bytes']==r['api_dump']['bytes']
d.values[current]=api['raw_sha256'];d.used[current]=api['raw_sha256']
assert load(ev/'publication-checks.json')['passed'] and load(ev/'publication-checks.json')['count']==22
pre=load(ev/'preexecution.json');bindings={}
for name,row in pre['sources'].items():
    assert d.h(root/name)==raw(Path(row['saved']))==row['sha256'];bindings[name]=row['sha256']
for name,row in owner['preexecution_sources'].items():assert d.h(root/name)==row['sha256']
prior=TASK/'builds/vive-focus11-source-reconstruction03'
for name,row in load(ev/'publisher-source-delta.json')['existing_changed_sources'].items():assert d.h(root/name)==row['after_sha256'] and d.h(prior/name)==row['before_sha256']
write(ev/'focus-events.json',{'rows':events,'result':f,'scope':'Filtered receive timestamps/booleans only; no source acknowledgement, snapshot barrier or returned-native/pixel evidence.'})
qualification={'checkpoint':'QUO-65 case12 live focus evidence and diagnostic publication correction',
    'worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','actual_api_model':'openai-codex:gpt-6.1-sol','launcher_requested_and_returned_effort':'max','effective_backend_effort':'unexposed',
    'branch':'worktree/pearl-stone','head':'293cf6115c0a6b18315eccdbb42cbca396f443d3','parent':'f716ddf5e578df957a5b18421a0727a32c634f87',
    'protocol_retirement_passed':True,'full_physical_qualification_passed':False,'human_look_model_visibility':'UNRUN/cancelled; root never issued look confirmation.',
    'actual_cancel':answer,'client_runtime_server_driver_observer_and_wrappers_exits':[0,0,0,0,0,0,0],
    'case_eof':r['eof'],'wrapper_eof':w['eof'],'focus_wrapper_eof':fw['eof'],'reader_errors':[],'diagnostics':[],'timeout_or_stack':False,
    'helper_checks':13,'publication_checks':22,'qualified_old_checks_repeated':False,'case_elapsed_seconds':w['elapsed_seconds'],'listener_elapsed_seconds':fw['elapsed_seconds'],
    'original_bounds':{'runtime_startup':30,'single_inventory':5,'participant':1800,'close':60,'wrapper':2100},'original_listener_absolute_deadline':deadline,
    'listener_result':f,'owned_event_anchor':anchor,'subsequent_focus_loss':loss,'observed_receive_interval_seconds':loss['monotonic']-anchor['monotonic'],
    'focus_scope':'Event receive times are not server emission times. Owned interval lost before root look confirmation; no why-focus-changed attribution.',
    'baseline_and_post_focus':'Head/both aim+grip High, models visible and lifecycle AppFocus true at post-focus geometry. GetWindow.HasFocus false is retained.',
    'loss_geometry':'Later head/both aim+grip High remain but AppFocus false/models hidden; existing safety gating retained. No policy/source fix inferred.',
    'final_metrics':metrics,'manual_instructions':instructions,'calibration_unchanged':True,'hdmi_restored_disabled':True,'other_displays_and_current_configs_unchanged':True,'current_config_files':len(rule['after']['config_sha256']),
    'api_counts':api['counts'],'api_layer_counts':api['submitted_layer_counts'],'api_projection_view_counts':api['projection_view_counts'],'api_scope':api['scope'],
    'source_bindings':bindings,'streams':streams,'inherited_diagnostic_publishers_changed':2,'one_shared_identifier_owner':True,
    'product_csharp_export_engine_runtime_focus_helper_changes':0,'supplied_inputs_unchanged':93,'exported_files_unchanged':196,'diagnostic_nondistributable':True,
    'new_product_builds_or_unchanged_suites':0,'remaining':['No case13 authority. Why desktop focus changes remains unknown. No speculative asset, lighting, pose, calibration, placement, focus-policy or close-order correction.',
        'Controller visibility/readability/comfort and formal ninety-draw/transform/mapped physical gestures remain unqualified. Original failures and earlier panel pass retain their scope; no fullM4/QUO27/59/Stage2/Quest credit.']}
write(ev/'qualification.json',qualification)
cache=TASK/'cache/focus12-receipt-binding-hashes.json';d.write(cache);write(ev/'receipt-cache.json',{'path':str(cache),'sha256':raw(cache),'api_reused_from_single_stat_bound_parse':True})
print(json.dumps({'receipt_binding_passed':True,'protocol_retirement_passed':True,'physical_model_look':'UNRUN/cancelled','focus_receive_interval_seconds':qualification['observed_receive_interval_seconds'],'old_api_or_product_replay':False}))
