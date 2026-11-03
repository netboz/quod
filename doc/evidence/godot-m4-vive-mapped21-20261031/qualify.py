"""Bind the completed case21 receipts; raw geometry and identity remain private."""
import hashlib,importlib.util,json,math,os,shutil,sys
from pathlib import Path
from case_hashes import TASK,Digests,key,raw
sys.dont_write_bytecode=True;os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
owners=TASK/'private/case21-preparation01/unchanged-owners'
case=owners/'godot-m4-vive-retest-20261030/native-vive-product21'
logs=owners/'godot-m4-vive-physical-20261029/logs'
private=TASK/'private/native-vive-product21'
def load(p):return json.loads(Path(p).read_text())
def write(p,v):Path(p).write_text(json.dumps(v,indent=2)+'\n')
r=load(case/'result.json');c=load(case/'client-result.json');w=load(logs/'native-vive-product21-run.json')
assert r['passed'] and r['product_ready'] and r['product_finished']
assert all(r[n+'_exit']==0 for n in ['client','runtime','server']) and w['child_exit']==0
assert all(r['eof'].values()) and all(w['eof'].values())
assert not r['reader_errors'] and not w['reader_errors'] and not r['diagnostics']
assert not r.get('client_timeout') and not w.get('timed_out') and not any('stack_capture' in k for k in r)
assert r['manual_bound_seconds']==1800 and r['normal_close_watchdog_seconds']==60 and w['bound_seconds']==2100
assert w['elapsed_seconds']<2100
assert r['startup_inventory']['exit']==0 and r['startup_inventory']['wand_devices']==2
instructions=[x['diagnostic_instruction'] for x in r['commands'] if 'diagnostic_instruction' in x]
assert instructions==['status','geometry','stop','finish']
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
copies=TASK/'private/build-inputs/mapped21-closure01';copies.mkdir(mode=0o700,exist_ok=False)
shutil.copy2(display_source,copies/'vive_display.py')
spec=importlib.util.spec_from_file_location('case21_display_snapshot',copies/'vive_display.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
current_display=module.snapshot()
assert raw(display_source)==raw(copies/'vive_display.py')
desktop=lambda s:sorted([m for m in s['monitors'] if m['name']!='HDMI-A-1'],key=lambda m:m['name'])
assert desktop(current_display)==desktop(rule['before'])
assert current_display['config_sha256']==rule['before']['config_sha256']==rule['after']['config_sha256']
assert next(x for x in current_display['monitors'] if x['name']=='HDMI-A-1')['disabled']
write(private/'closure-current-display.json',current_display)
owner_path=TASK/'private/native-vive-product21-invocation.json';owner=load(owner_path)
proc=Path('/proc')/str(owner['pid'])/'stat';same=False
if proc.exists():
    text=proc.read_text();same=text[text.rfind(')')+2:].split()[19]==owner['start_ticks']
assert not same
ready=load(ev/'baseline01.json');later=load(ev/'after-response01.json')
assert ready['owner_binding_sha256']==later['owner_binding_sha256']==raw(owner_path)
deadline=owner['deadline_monotonic'];derivation=owner['derivation']
assert deadline==derivation['observed_monotonic']+1800-math.ceil(derivation['elapsed_since_client_start'])-5
assert all(x['deadline_monotonic']==deadline and x['observed_at_monotonic']<deadline for x in [ready,later])
assert ready['native_session']=='Focused' and ready['lifecycle']['NativeRunning'] and ready['lifecycle']['PresentationVisible']
assert ready['head']=={'tracked':True,'confidence':'None'}
assert len(ready['sources'])==2 and all(x['current'] and x['aim']==x['grip']=={'tracked':True,'confidence':'High'} and x['visible_roots']==0 and x['visible_meshes']==0 for x in ready['sources'])
snapshots=[load(private/'read-only-captures'/n)['snapshots'][-1] for n in ['baseline01.raw.json','after-response01.raw.json']]
assert all(s['button_presses'].get('location-operations',0)==0 for s in snapshots)
assert [len(x['edges']) for x in snapshots[0]['sources']]==[0,0]
assert [len(x['edges']) for x in snapshots[1]['sources']]==[0,8]
assert all(s['state']['world_accepted'] and s['state']['operation_available'] and s['state']['controller_status']['available'] for s in snapshots)
assert all(s['state']['pending']==0 and not s['state']['busy'] and s['metrics']['captures']==0 for s in snapshots)
assert snapshots[0]['state']['current_location']==snapshots[1]['state']['current_location']
assert snapshots[0]['state']['assignment_revision']==snapshots[1]['state']['assignment_revision']=='1'
safe_prefixes=(b'PASS ',b'M4_VIVE_',b'M4_PHYSICAL_')
sources={name:(Path(row['raw']),row['sha256']) for name,row in r['streams'].items()}
sources.update({'physical-wrapper-'+kind:(Path(row['path']),row['sha256']) for kind,row in w['streams'].items()})
projection_dir=ev/'sanitized-logs';projection_dir.mkdir(exist_ok=False);stream_rows={}
for name,(path,digest) in sources.items():
    assert path.stat().st_mode&0o7777==0o600 and path.parent.stat().st_mode&0o7777==0o700
    value=path.read_bytes();assert hashlib.sha256(value).hexdigest()==digest
    output=[];restricted=0
    for line in value.splitlines(keepends=True):
        if line.startswith(safe_prefixes):output.append(line)
        else:restricted+=1;output.append(('<restricted private detail; sha256='+hashlib.sha256(line).hexdigest()+'>\n').encode())
    projected=b''.join(output);assert owner['address'].encode() not in projected and b'LHR-' not in projected and b'LHB-' not in projected
    out=projection_dir/(name+'.log');out.write_bytes(projected)
    stream_rows[name]={'raw_path':str(path),'raw_sha256':digest,'raw_bytes':len(value),'raw_mode':'0600','raw_stat_key':list(key(path)),'public_sha256':raw(out),'lines':len(output),'restricted_lines':restricted}
write(ev/'stream-projections.json',stream_rows)
stderr=Path(r['streams']['client-stderr']['raw']).read_text()
assert 'M4_VIVE_GUI location-operations' not in stderr
cue_lines=[line for line in stderr.splitlines() if line.startswith('M4_VIVE_LOOK_CUE ')]
manifest_path=root/r['client_manifest']['path'];manifest=load(manifest_path)
assert raw(manifest_path)==r['client_manifest']['sha256']=='4e6bcf7daf995305e004eb8a9164cb862f7aa84dd257404f37c089aa672ff884'
assert len(manifest['supplied_inputs'])==95 and len(manifest['export_outputs'])==196 and r['payload']==manifest['export_outputs']
assert r['engine_sha256']=='02310d903099bada10c86cedc90bbc11ef0bec8254d6e607d1a53f6150ab0268'
api=Path(r['api_dump']['path']);assert api.stat().st_size==r['api_dump']['bytes']
api_ref={'path':str(api),'bytes':r['api_dump']['bytes'],'driver_recorded_sha256':r['api_dump']['sha256'],'stat_key':list(key(api)),'parsed':False,'hashed_again':False,'scope':'Original executed-driver digest and post-exit stat only; not opened by this binder.'}
q={'scope':'Case21 human FAILED panel usability; mapped current-space GUI activation NOT passed. Normal owned retirement.',
 'protocol_retirement_passed':True,'human_response':{'exact_text':"so I see the controller, the gui looks better, but isstill displayed in an impossible position I mean you know I am a huma being, you know how I am made, where are my eyes.Them why displaying the panel in such impossible positions ?",'received_before_utc':'2026-10-31T00:33:21.993Z','exact_look_interval':None},
 'baseline_snapshot_utc':ready['node_utc'],'post_response_snapshot_utc':later['node_utc'],'post_response_later_than_human_look':True,
 'manual_instructions':instructions,'original_bounds':{'startup':30,'single_inventory':5,'participant':1800,'close':60,'wrapper':2100},
 'client_runtime_server_driver_wrapper_exits':[0,0,0,0,0],'case_eof':r['eof'],'wrapper_eof':w['eof'],'reader_errors':[],
 'case_elapsed_seconds':w['elapsed_seconds'],'target_button_counts':[0,0],'raw_edge_counts_baseline':[0,0],'raw_edge_counts_later':[0,8],
 'extra_edges':'Four RIGHT trigger press/release pairs, no LEFT edge; action not accessibly instructed, intent/authorization/product-effect credit not inferred.',
 'post_response_native_state':{k:later[k] for k in ['native_session','lifecycle','head','sources','window_focused','latest_cue_marker']},
 'assignment_unchanged_at_sampled_instants':True,'pending_unchanged_zero':True,'captures_zero_at_sampled_instants':True,
 'target_activation_passed':False,'hardware_button_defect_demonstrated':False,'final_metrics':metrics,
 'calibration_unchanged_reported':True,'hdmi_restored_disabled':True,'fresh_other_displays_and_current_configs_unchanged':True,'current_config_files':len(current_display['config_sha256']),
 'ordinary_launch_focus_dispatches':1,'extra_focus_dispatches':0,'focus_listener_started':False,
 'diagnostic_nondistributable':True,'payload_manifest_sha256':r['client_manifest']['sha256'],'supplied_inputs':95,'export_files':196,
 'no_90sample_gui_check_submit_travel_synthetic_input':True,'api_private_reference':api_ref,'full_M4_accepted':False,
 'human_controller_visibility':'positive','human_GUI_appearance':'improved','placement_usability':'FAILED','left_action_accessibly_instructed':False,'remaining':'Responsible-owner upright-placement correction and affected software qualification; first-wearing/heading lifetime remains a separate limitation; stage-specific instruction must use existing headset label before any separately authorized run.'}
write(ev/'qualification.json',q);d.write(TASK/'cache/mapped21-receipt-binding-hashes.json')
write(ev/'receipt-cache.json',{'path':str(TASK/'cache/mapped21-receipt-binding-hashes.json'),'sha256':raw(TASK/'cache/mapped21-receipt-binding-hashes.json'),'api_not_opened':True})
print(json.dumps({'receipt_binding_passed':True,'retirement_all_zero':True,'human_panel_usability':'FAILED','target_activation_passed':False,'api_opened_or_parsed':False}))
