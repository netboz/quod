"""Bind actual case16 receipts; publish only minimal privacy projections."""
import hashlib,json,math,os,sys
from pathlib import Path
sys.dont_write_bytecode=True
from freeze_hashes import Digests,TASK,key,raw
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
def load(p):return json.loads(Path(p).read_text())
def write(p,v):Path(p).write_text(json.dumps(v,indent=2)+'\n')
owners=TASK/'private/case16-preparation01/unchanged-owners'
case=owners/'godot-m4-vive-retest-20261030/native-vive-product16'
logs=owners/'godot-m4-vive-physical-20261029/logs'
r=load(case/'result.json');c=load(case/'client-result.json')
w=load(logs/'native-vive-product16-run.json');fw=load(logs/'native-vive-product16-focus-run.json')
assert r['passed'] and r['product_ready'] and r['product_finished']
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
events_path=TASK/'private/native-vive-product16-focus/filtered-events.jsonl'
data=events_path.read_bytes();assert data.endswith(b'\n')
events=[json.loads(line) for line in data.splitlines()]
allowed={'kind','monotonic','utc','owned','ordered_event_barrier','incomplete_line','error',
 'event_receive_monotonic','event_receive_utc','role','validity','lookup_attempted','recipient_not_initiator',
 'lookup_start_monotonic','lookup_start_utc','lookup_end_monotonic','lookup_end_utc','incarnation_checked_monotonic'}
assert all(set(row)<=allowed for row in events)
f=load(events_path.parent/'result.json')
assert f['armed'] and f['subscription_count']==1 and not f['errors'] and not f['unparsed_fragment']
assert f['local_connection_closed'] and not f['remote_eof_observed']
assert events[-1]['kind']=='local_subscription_close' and not events[-1]['incomplete_line']
assert f['successor_classifications']==1 and f['successor_lookups']==0 and f['event_messages']==6
successors=[x for x in events if x['kind']=='successor_recipient'];assert len(successors)==1
assert successors[0]['role']=='unknown' and successors[0]['validity']=='unbound' and not successors[0]['lookup_attempted']
after=load(ev/'after-focus01.json');assert after['active_owned'] and after['lifecycle']['ApplicationFocused']  # Window.HasFocus is retained literally, not normalized or made a new gate
assert after['head']=={'tracked':True,'confidence':'High'}
assert all(x['current'] and x['visible_roots']==1 and x['visible_meshes']==6 and x['aim']==x['grip']=={'tracked':True,'confidence':'High'} for x in after['sources'])
assert after['owner_binding_sha256']==raw(TASK/'private/native-vive-product16-focus-invocation.json')
anchor=next(x for x in events if x.get('owned') is True and x['monotonic']==29489.433135162)
loss=next(x for x in events if x.get('owned') is False and x['monotonic']>anchor['monotonic'])
assert loss['monotonic']==30240.440744284 and loss['utc']=='2026-10-30T18:33:26.073708+00:00'
owner=load(TASK/'private/native-vive-product16-focus-invocation.json');deadline=owner['deadline_monotonic']
assert max(row['monotonic'] for row in events)<deadline
assert deadline==owner['derivation']['observed_monotonic']+1800-math.ceil(owner['derivation']['elapsed_since_client_start'])-5
# The completed actual driver hashed new API16. Retain its exact receipt/stat only; no raw API16 or historical API parse/read here.
dump=Path(r['api_dump']['path']);api_stat=key(dump)
pre=load(ev/'preexecution.json');assert pre['passed'] and pre['explicit_recipient_bindings_empty']
assert pre['hdmi_restored_disabled'] and pre['other_displays_unchanged'] and pre['config_unchanged']
for n,entry in pre['unchanged_private_invocation_sources'].items():assert d.h(root/n)==raw(Path(entry['private_executed_copy']))==entry['sha256']
for n,row in owner['preexecution_sources'].items():assert raw(Path(n))==row['sha256']
assert raw(Path(owner['actual_command'][2]))=='a7b584c8b137b5617b89a98e57f6f42e895d3247278b4c3de52b595ecbea5889'
roles=TASK/'private/case16-preparation01/bindings.json'
assert json.loads(roles.read_text())==[] and raw(roles)==owner['recipient_binding_sha256']
assert raw(roles)==raw(TASK/'private/build-inputs/native-vive-product16-focus/bindings.json')
assert roles.stat().st_mode&0o7777==0o600 and roles.parent.stat().st_mode&0o7777==0o700

# Full original streams stay private. Public logs preserve every line position;
# only fixed protocol markers/filtered event rows are published. Other lines
# are explicitly restricted with their own digest, never silently dropped.
safe_prefixes=(b'PASS ',b'M4_VIVE_',b'M4_PHYSICAL_',b'M4_FOCUS_EVENT_OBSERVER_READY ')
stream_rows={};sources={}
for name,row in r['streams'].items():sources[name]=(Path(row['raw']),row['sha256'])
for label,record in [('physical-wrapper',w),('focus-wrapper',fw)]:
    for kind,row in record['streams'].items():sources[label+'-'+kind]=(Path(row['path']),row['sha256'])
target=ev/'sanitized-logs';target.mkdir(exist_ok=False)
for name,(p,digest) in sources.items():
    assert p.stat().st_mode&0o7777==0o600 and p.parent.stat().st_mode&0o7777==0o700
    value=p.read_bytes();assert hashlib.sha256(value).hexdigest()==digest
    output=[];restricted=0;error_lines=0
    for line in value.splitlines(keepends=True):
        if b'ERROR' in line or b'leaked' in line:error_lines+=1
        keep=line.startswith(safe_prefixes)
        if not keep and line.startswith(b'{'):
            try:parsed=json.loads(line);keep=isinstance(parsed,dict) and parsed.get('kind') in {'transition','snapshot','successor_recipient','local_subscription_close','remote_eof','listener_error','absolute_deadline'} and set(parsed)<=allowed
            except (ValueError,TypeError):pass
        if keep:output.append(line)
        else:
            restricted+=1;output.append(('<restricted private detail; sha256='+hashlib.sha256(line).hexdigest()+'>\n').encode())
    projected=b''.join(output);out=target/(name+'.log');out.write_bytes(projected)
    assert owner['address'].encode() not in projected and all(b['address'].encode() not in projected for b in load(roles))
    stream_rows[name]={'raw_path':str(p),'raw_sha256':digest,'raw_bytes':len(value),'raw_mode':'0600',
        'public_sha256':raw(out),'lines':len(output),'restricted_lines':restricted,'raw_error_or_leak_lines':error_lines,
        'method':'Every original line retained either as exact safe protocol/filtered row or explicit private-detail placeholder with original-line SHA; full originals remain private.'}
safe_listener={k:v for k,v in f.items() if k!='peer_pid'}
write(ev/'focus-events.json',{'rows':events,'result':safe_listener,'scope':'Receive times/role/validity only; no initiating actor/cause/returned-native/pixel claim.'})
write(ev/'stream-projections.json',stream_rows)
private_refs={}
for p in [case/'result.json',case/'client-result.json',logs/'native-vive-product16-run.json',logs/'native-vive-product16-focus-run.json',
    TASK/'private/native-vive-product16-focus-invocation.json',roles,TASK/'private/native-vive-product16/client-result.raw.json']:
    private_refs[str(p)]={'sha256':raw(p),'bytes':p.stat().st_size,'mode':p.stat().st_mode&0o7777,'retained_privately_not_snapshot_object':True}
write(ev/'restricted-output-references.json',private_refs)
lost=load(ev/'focus-loss01.json');assert not lost['active_owned'] and not lost['lifecycle']['ApplicationFocused']
assert lost['head']=={'tracked':True,'confidence':'High'}
assert all(x['current'] and x['aim']==x['grip']=={'tracked':True,'confidence':'High'} and x['visible_roots']==0 and x['visible_meshes']==0 for x in lost['sources'])
raw_client=Path(r['streams']['client-stderr']['raw']).read_text()
cue_lines=[line for line in raw_client.splitlines() if line.startswith('M4_VIVE_LOOK_CUE ')]
assert cue_lines[:4]==['M4_VIVE_LOOK_CUE READY frame=2','M4_VIVE_LOOK_CUE WAITING frame=48528','M4_VIVE_LOOK_CUE READY frame=50920','M4_VIVE_LOOK_CUE WAITING frame=50951']
assert len(cue_lines)==4
build=load(root/'doc/evidence/godot-m4-vive-headset-cue-20261030/inputs/client-headset-cue01-manifest.json')
assert build['passed'] and len(build['supplied_inputs'])==94 and len(build['export_outputs'])==196
assert r['client_manifest']['sha256']==raw(root/r['client_manifest']['path'])
qualification={'checkpoint':'QUO-65 diagnostic in-headset cue and case16 quiet interval/retirement',
 'worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','actual_api_model':'openai-codex:gpt-6.1-sol','launcher_requested_and_returned_effort':'max','effective_backend_effort':'unexposed',
 'branch':'worktree/pearl-stone','head':'293cf6115c0a6b18315eccdbb42cbca396f443d3','parent':'f716ddf5e578df957a5b18421a0727a32c634f87',
 'protocol_retirement_passed':True,'full_physical_qualification_passed':False,
 'human_look_model_visibility':'UNCONFIRMED: no actual supported visual answer/return reached worker at receipt binding. An earlier completed human look, if later reported, retains its own timing; no visual failure/pass inferred.',
 'new_protocol':'Root explicit meta1793383924548-hr9stjw: conditional in-headset cue, preagreed instructions; no card or live root LOOK NOW round trip.',
 'prelaunch_full_batch_read':True,'prelaunch_batch_count':4,'prefocus_full_batch_count':5,
 'ready_report_before_focus':'meta-1793384451139-wonpj77','loss_report':'meta-1793385323044-2m80995','closed_report':'meta-1793385434049-rrvknq9',
 'client_runtime_server_driver_observer_and_wrappers_exits':[0,0,0,0,0,0,0],
 'case_eof':r['eof'],'wrapper_eof':w['eof'],'focus_wrapper_eof':fw['eof'],'reader_errors':[],'diagnostics':[],'timeout_or_stack':False,
 'helper_checks':len(c['checks']),'new_pure_cue_checks':14,'pure_checks_true_exit':0,'pure01_failure_retained':'NU1100 before assertions; separate02 changes only qualified local dependency feed',
 'new_affected_source_only_build_commands':[0]*5,'build_outer_exit':0,'unchanged_server_core_engine_runtime_suites_or_builds':0,
 'case_elapsed_seconds':w['elapsed_seconds'],'listener_elapsed_seconds':fw['elapsed_seconds'],
 'original_bounds':{'runtime_startup':30,'single_inventory':5,'participant':1800,'close':60,'wrapper':2100},
 'original_listener_absolute_deadline':deadline,'listener_result':safe_listener,'post_focus_owned_event':anchor,'first_later_loss':loss,
 'received_owned_interval_seconds':loss['monotonic']-anchor['monotonic'],'quiet_after_single_focus_until_first_loss':True,
 'after_focus_node_utc':after['node_utc'],'window_has_focus_after_focus_literal':after['window_focused'],
 'after_focus_head_both_hands_high_models_visible':True,'later_loss_node_utc':lost['node_utc'],'later_app_focus_false_native_focused_head_hands_high_models_hidden':True,
 'actual_frame_cue_markers':cue_lines,'cue_scope':'State selection/withdrawal observed in actual frame callback; marker frame counts and separately received event UTC are not an atomic sample or raster/returned-status claim.',
 'focus_scope':'Received owner notifications; no initiating actor/cause/persistent native focus or human look proof. One unknown/unbound recipient, zero lookups, no rearm or second worker focus.',
 'raw_button_edges':'Actual native source edges retained; user action/origin/intent/product mapping or deliberate test success not inferred. No buttons were requested.',
 'final_metrics':metrics,'manual_instructions':instructions,'post_ready_report_focus_attempts':1,'post_focus_reports_before_first_loss':0,'notifier_during_interval':False,
 'ordinary_startup_focus_dispatches':1,'ordinary_owned_close_dispatches':1,
 'calibration_unchanged':True,'hdmi_restored_disabled':True,'other_displays_and_current_configs_unchanged':True,'current_config_files':len(rule['after']['config_sha256']),
 'new_api_private_reference':{'path':str(dump),'bytes':r['api_dump']['bytes'],'driver_recorded_sha256':r['api_dump']['sha256'],'stat_key':list(api_stat),'parsed':False,'hashed_again':False,'scope':'Actual completed driver hash receipt only; no counts/returned native status/pixel claim.'},
 'explicit_recipient_bindings_empty':True,'shared_physical_manual_publisher_observer_byte_unchanged':True,'production_application_engine_runtime_changes':0,
 'new_supplied_inputs':94,'new_exported_files':196,'diagnostic_nondistributable':True,
 'remaining':['No actual human model observation/neutral90/gui/gesture/movement/comfort acceptance; no case17 authorized.',
 'No fullM4/QUO27/59/Stage2/Quest/historical desktop/cold-head resolution; root independent acceptance pending.']}
write(ev/'qualification.json',qualification);d.write(TASK/'cache/headset16-receipt-binding-hashes.json')
write(ev/'receipt-cache.json',{'path':str(TASK/'cache/headset16-receipt-binding-hashes.json'),'sha256':raw(TASK/'cache/headset16-receipt-binding-hashes.json'),'raw_api_not_read':True})
print(json.dumps({'receipt_binding_passed':True,'protocol_retirement_passed':True,'cue_build_and14pure_checks_passed':True,'human_model_look':'UNCONFIRMED','single_focus_received_interval_seconds':qualification['received_owned_interval_seconds'],'live_cases_closed':True,'api_read_or_parsed':False}))
