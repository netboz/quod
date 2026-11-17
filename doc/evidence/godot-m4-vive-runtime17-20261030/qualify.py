"""Bind the completed case17 receipts; raw geometry and identity remain private."""
import hashlib,importlib.util,json,math,os,shutil,sys
from pathlib import Path
from case_hashes import TASK,Digests,key,raw
sys.dont_write_bytecode=True;os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
owners=TASK/'private/case17-preparation01/unchanged-owners'
case=owners/'godot-m4-vive-retest-20261030/native-vive-product17'
logs=owners/'godot-m4-vive-physical-20261029/logs'
private=TASK/'private/native-vive-product17'
def load(p):return json.loads(Path(p).read_text())
def write(p,v):Path(p).write_text(json.dumps(v,indent=2)+'\n')
r=load(case/'result.json');c=load(case/'client-result.json');w=load(logs/'native-vive-product17-run.json')
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
copies=TASK/'private/build-inputs/runtime17-closure01';copies.mkdir(mode=0o700,exist_ok=False)
shutil.copy2(display_source,copies/'vive_display.py')
spec=importlib.util.spec_from_file_location('case17_display_snapshot',copies/'vive_display.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
current_display=module.snapshot()
assert raw(display_source)==raw(copies/'vive_display.py')
desktop=lambda s:sorted([m for m in s['monitors'] if m['name']!='HDMI-A-1'],key=lambda m:m['name'])
assert desktop(current_display)==desktop(rule['before'])
assert current_display['config_sha256']==rule['before']['config_sha256']==rule['after']['config_sha256']
assert next(x for x in current_display['monitors'] if x['name']=='HDMI-A-1')['disabled']
write(private/'closure-current-display.json',current_display)
owner_path=TASK/'private/native-vive-product17-invocation.json';owner=load(owner_path)
proc=Path('/proc')/str(owner['pid'])/'stat';same=False
if proc.exists():
    text=proc.read_text();same=text[text.rfind(')')+2:].split()[19]==owner['start_ticks']
assert not same
ready=load(ev/'ready01.json');waiting=load(ev/'waiting01.json')
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
assert waiting['window_focused'] is True
raw_wait=load(private/'read-only-captures/waiting01.raw.json')['snapshots'][-1]['state']
assert raw_wait['world_accepted'] is False and raw_wait['operation_available'] is False
assert raw_wait['controller_status']['available'] is False and raw_wait['pending']==0 and raw_wait['busy'] is False
operation_status_has_expired='expired' in raw_wait['operation_status'].lower()
assert operation_status_has_expired
safe_prefixes=(b'PASS ',b'M4_VIVE_',b'M4_PHYSICAL_')
sources={name:(Path(row['raw']),row['sha256']) for name,row in r['streams'].items()}
sources.update({'physical-wrapper-'+kind:(Path(row['path']),row['sha256']) for kind,row in w['streams'].items()})
projection_dir=ev/'sanitized-logs';projection_dir.mkdir(exist_ok=False)
stream_rows={}
for name,(path,digest) in sources.items():
    assert path.stat().st_mode&0o7777==0o600 and path.parent.stat().st_mode&0o7777==0o700
    value=path.read_bytes();assert hashlib.sha256(value).hexdigest()==digest
    output=[];restricted=0;errors=0
    for line in value.splitlines(keepends=True):
        if b'ERROR' in line or b'leaked' in line:errors+=1
        if line.startswith(safe_prefixes):output.append(line)
        else:
            restricted+=1;output.append(('<restricted private detail; sha256='+hashlib.sha256(line).hexdigest()+'>\n').encode())
    projected=b''.join(output)
    assert owner['address'].encode() not in projected and b'LHR-' not in projected and b'LHB-' not in projected
    out=projection_dir/(name+'.log');out.write_bytes(projected)
    stream_rows[name]={'raw_path':str(path),'raw_sha256':digest,'raw_bytes':len(value),'raw_mode':'0600',
        'raw_stat_key':list(key(path)),'public_sha256':raw(out),'lines':len(output),'restricted_lines':restricted,
        'raw_error_or_leak_lines':errors,'method':'Each original line is exact fixed protocol text or a restricted-detail placeholder carrying its original-line digest. Raw originals remain private.'}
write(ev/'stream-projections.json',stream_rows)
stderr=Path(r['streams']['client-stderr']['raw']).read_text()
cue_lines=[line for line in stderr.splitlines() if line.startswith('M4_VIVE_LOOK_CUE ')]
assert cue_lines==['M4_VIVE_LOOK_CUE READY frame=2','M4_VIVE_LOOK_CUE WAITING frame=52712']
manifest_path=root/r['client_manifest']['path'];manifest=load(manifest_path)
assert raw(manifest_path)==r['client_manifest']['sha256']=='9073b314599bd64531792acd63cbcd2e21ef54b73a41b25cd041260a4433fb08'
assert len(manifest['supplied_inputs'])==94 and len(manifest['export_outputs'])==196
assert r['engine_sha256']=='02310d903099bada10c86cedc90bbc11ef0bec8254d6e607d1a53f6150ab0268'
assert r['payload']==manifest['export_outputs']
assert raw(owners/'godot-m4-vive-retest-20261030/physical09.py')=='360b166bacb988cb972f53f1d78df15bca70baf95e4a7354c29094fc5cb053c0'
original=(owners/'godot-m4-vive-retest-20261030/physical09.py').read_text()
executed=owners/'godot-m4-vive-retest-20261030/physical17.py'
old="def h(p):\n    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()"
assert original.count(old)==1
replacement='from case_hashes import Digests\ndigests=Digests()\ndef h(p):return digests.h(p)'
assert executed.read_text()==original.replace(old,replacement)
assert raw(executed)==r['driver_inputs']['physical17.py']
refs={}
for path in [case/'result.json',case/'client-result.json',logs/'native-vive-product17-run.json',owner_path,
    private/'client-result.raw.json',private/'display-rule.json',private/'closure-current-display.json',
    private/'read-only-captures/ready01.raw.json',private/'read-only-captures/waiting01.raw.json']:
    refs[str(path)]={'sha256':raw(path),'bytes':path.stat().st_size,'mode':path.stat().st_mode&0o7777,'retained_privately_not_snapshot_object':True}
write(ev/'restricted-output-references.json',refs)
# The actual completed driver already hashed API17 once. Stat custody only;
# this verifier never opens the API or imports an old API's bytes.
api=Path(r['api_dump']['path']);assert api.stat().st_size==r['api_dump']['bytes']
api_ref={'path':str(api),'bytes':r['api_dump']['bytes'],'driver_recorded_sha256':r['api_dump']['sha256'],
    'stat_key':list(key(api)),'parsed':False,'hashed_again':False,'scope':'Original completed-driver digest plus post-exit stat identity only; no entry counts, returned-status or pixels.'}
q={'scope':'Case17 runtime-focus diagnostic preparation/retirement and sampled cue withdrawal; no human visibility result received.',
 'protocol_retirement_passed':True,'physical_model_visibility':'UNRUN/unqualified: no actual human result reached worker at receipt binding',
 'manual_instructions':instructions,'original_bounds':{'startup':30,'single_inventory':5,'participant':1800,'close':60,'wrapper':2100},
 'client_runtime_server_driver_wrapper_exits':[0,0,0,0,0],'case_eof':r['eof'],'wrapper_eof':w['eof'],'reader_errors':[],
 'case_elapsed_seconds':w['elapsed_seconds'],'timeout_or_stack':False,'target_diagnostics':[],
 'ordinary_launch_focus_dispatches':1,'extra_focus_dispatches':0,'ordinary_owned_close_dispatches':1,'focus_listener_started':False,
 'actual_frame_cue_markers':cue_lines,'ready_snapshot_utc':ready['node_utc'],'ready_native_head_both_hands_high_models_visible':True,
 'ready_window_has_focus_literal':False,'later_waiting_snapshot_utc':waiting['node_utc'],'later_native_head_hands_high_models_hidden':True,
 'later_world_accepted':False,'later_operation_available':False,'later_controller_available':False,'later_operation_status_contains_expired':operation_status_has_expired,
 'specific_withdrawal_cause':'Not independently attributed; no desktop-focus, hardware or historical-stall cause inferred.',
 'human_interval':'No human look time or result supplied; marker/snapshots are distinct instants, not pixel/continuous-interval proof.',
 'no_90sample_gui_button_gesture_movement':True,'final_metrics':metrics,'owned_client_incarnation_retired':True,
 'runtime_processes_after_reported':[],'calibration_unchanged_reported':True,'hdmi_restored_disabled':True,
 'fresh_closure_other_displays_and_current_configs_unchanged':True,'current_config_files':len(current_display['config_sha256']),
 'payload_manifest_sha256':r['client_manifest']['sha256'],'supplied_inputs':94,'export_files':196,'diagnostic_nondistributable':True,
 'production_source_policy_changes':0,'driver_delta':'Only digest h delegates to the existing exact-stat accepted cache owner. Control, guards and deadlines byte-identical.',
 'builds_or_unchanged_suite_recounts':0,'api_private_reference':api_ref,'full_M4_accepted':False,
 'remaining':['No case18 authorization; no new run or reauthentication performed.','Startup complaint, original desktop/cold-head failures, model transform/gestures/comfort/full M4 remain open.']}
write(ev/'qualification.json',q)
d.write(TASK/'cache/runtime17-receipt-binding-hashes.json')
write(ev/'receipt-cache.json',{'path':str(TASK/'cache/runtime17-receipt-binding-hashes.json'),'sha256':raw(TASK/'cache/runtime17-receipt-binding-hashes.json'),'api_not_opened':True})
print(json.dumps({'receipt_binding_passed':True,'retirement_all_zero':True,'fresh_display_config_restoration_passed':True,'physical_model_visibility':'UNRUN/unqualified','api_opened_or_parsed':False}))
