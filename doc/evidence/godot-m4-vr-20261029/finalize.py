"""Check new receipts and exact supplied/exported inputs; never rerun old gates."""
import hashlib,json,subprocess
from pathlib import Path
from environment import TASK
root=Path.cwd();ev=Path(__file__).resolve().parent
def h(p):
    with p.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def load(p):return json.loads(p.read_text())
def save(name,value):(ev/name).write_text(json.dumps(value,indent=2)+'\n')
assert subprocess.check_output(['git','rev-parse','HEAD']).decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert subprocess.check_output(['git','branch','--show-current']).decode().strip()=='worktree/pearl-stone'
assert not subprocess.check_output(['git','diff','--cached','--name-only'])
prior=Path('/home/yan/.cache/quod-m4-observation1-artifacts/quod-godot-m4-observation1-handoff-ca84d4f8-20261029-01')
patch=subprocess.check_output(['git','diff','--binary','HEAD']);assert patch==(prior/'previous/tracked.patch').read_bytes()
wrappers=[];missing_driver_capture=[]
for path in sorted((ev/'logs').glob('*.json')):
    record=load(path)
    if 'child_exit' not in record:continue
    for section in ['private_streams','sanitized_streams']:
        for stream in record[section].values():
            p=Path(stream['path']);assert p.stat().st_size==stream['bytes'] and h(p)==stream['sha256'],p
            if section=='private_streams':assert p.stat().st_mode&0o777==0o600
    inputs=record.get('driver_inputs')
    if inputs:
        directory=TASK/'private/runs'/path.stem/'driver-inputs'
        for name,digest in inputs.items():assert h(directory/name)==digest,(path,name)
    else:missing_driver_capture.append(path.stem)
    wrappers.append({'label':path.stem,'child_exit':record['child_exit'],'timed_out':record['timed_out'],'elapsed_seconds':record['elapsed_seconds'],'receipt_sha256':h(path),'pre_execution_driver_inputs':bool(inputs)})
builds={}
for path in sorted((ev/'inputs').glob('client-*-manifest.json')):
    manifest=load(path);stage=Path(manifest['stage']);assert manifest['passed'] and not manifest['compiled_application_inputs_copied'] and not manifest.get('distributable',False)
    live_inputs=manifest.get('live_source_inputs',manifest['supplied_inputs'])
    for name,digest in live_inputs.items():assert h(root/name)==digest,(path,name)
    for name,digest in manifest['supplied_inputs'].items():assert h(stage/'source'/name)==digest,(path,name)
    for name,row in manifest['export_outputs'].items():
        p=stage/'source/client/godot/dist'/name;assert p.stat().st_size==row['bytes'] and h(p)==row['sha256'],p
    assert len(manifest['commands'])==5
    phases=[]
    for row in manifest['commands']:
        receipt=load(ev/('client-'+path.stem.removeprefix('client-').removesuffix('-manifest')+'-'+row['phase'])/'result.json')
        assert row['wrapper_exit']==0 and receipt['exit']==0 and not receipt['diagnostic_failure'],(path,row)
        phases.append({'phase':row['phase'],'true_child_exit':receipt['exit'],'wrapper_exit':row['wrapper_exit']})
    for name,row in manifest['dependency_archives'].items():assert h(Path(row['referenced_path']))==row['sha256'],name
    builds[stage.name]={'supplied_inputs':len(manifest['supplied_inputs']),'unchanged_live_inputs':len(live_inputs),'outputs':len(manifest['export_outputs']),'phases':phases,'diagnostic_overrides':manifest.get('diagnostic_overrides',{}),'manifest_sha256':h(path),'stage':str(stage),'engine_sha256':manifest['template']['sha256'],'Quod_dll_sha256':manifest['export_outputs']['data_Quod_linuxbsd_x86_64/Quod.dll']['sha256'],'pck_sha256':manifest['export_outputs']['quod.pck']['sha256']}
base=load(ev/'native-sim-baseline01/result.json');patched=load(ev/'native-sim-patched01/result.json')
assert not base['passed'] and patched['passed']
assert all(any(marker in line for line in base['diagnostics']) for marker in ['nonexistent connection','leaked'])
observation=load(ev/'vive-display-observation03/result.json');pose=load(ev/'vive-display-observation03/observation.json')
assert observation['passed'] and observation['client_exit']==observation['runtime_exit']==0 and not observation['diagnostics']
assert observation['original_calibration_unchanged'] and observation['display_rule']['desktop_unchanged'] and observation['display_rule']['config_unchanged']
answer=load(ev/'inputs/vive-lens-observation03-response.json')['actual_interactive_answer']
assert answer['answers']['lenses']['selectedId']=='quod_both' and answer['answers']['led']['selectedId']=='green'
api=load(ev/'vive-display-observation03/api-lifecycle.json')
assert api['counts']['xrCreateSwapchain']==api['counts']['xrDestroySwapchain']==1
assert api['counts']['xrAcquireSwapchainImage']==api['counts']['xrWaitSwapchainImage']==api['counts']['xrReleaseSwapchainImage']==15203
assert api['submitted_layer_counts']=={'0':15094,'1':15203} and api['projection_view_counts']=={'2':15203}
reentry=load(ev/'native-fault-reentry01/result.json');assert reentry['passed']
assert [r['client_exit'] for r in reentry['cases']]==[1,0] and reentry['runtime_exit']==0
manual={'diagnostic_export':'client-display-observer02','human_lens_output':'Quod interface/text observed in both lenses; LED green','answer_receipt':'inputs/vive-lens-observation03-response.json','head_valid_frames':pose['valid_head_frames'],'head_high_confidence_frames':pose['high_head_frames'],'frames':pose['frames'],'tracked_controller_frames':{n:r['tracked_frames'] for n,r in pose['sources'].items()},'client_exit':0,'runtime_exit':0,'wrapper_exit':0,'eof':observation['eof'],'api_entry_counts':api['counts'],'submitted_layer_counts':api['submitted_layer_counts'],'projection_view_counts':api['projection_view_counts'],'targeted_cleanup_diagnostics':observation['diagnostics'],'scope':'Actual human pixels in a separately embedded observer export with unchanged C# application sources, real head-confidence counts and balanced native call entries. No returned-code, valid-controller, mapped-gesture, comfort, production-export physical or complete-resource proof.'}
save('inputs/receipt-audit.json',{'all_stream_hashes_and_sizes_verified':True,'wrappers':wrappers,'builds':builds,'initial_tooling_missing_pre_execution_driver_copies':missing_driver_capture,'limitation':'Initial tooling/build preparation preceded driver-copy support; commands, logs, source archives, original source manifest and later exact driver copies retained. Do not claim those early source copies were captured before their runs. All native counterfactual/manual/fault-reentry campaigns have pre-execution driver copies.','production_tracked_patch_sha256':hashlib.sha256(patch).hexdigest(),'production_main_sha256':h(root/'client/godot/Main.cs'),'new_production_test_spec_changes':0,'server_suites_rerun':0,'core_suites_rerun':0})
save('acceptance.json',{'ticket':'QUO-65','status':'in-review','full_M4_accepted':False,'new_qualified_scopes':[
    {'scope':'Private pinned engine ownership correction','evidence':['godot-4.7.2-openxr-lifetimes.patch','native-sim-baseline01','native-sim-patched01'],'result':'Same freshly compiled C# payload; only native executable differs. Baseline retains both targeted teardown errors; patch passes18 assertions/3adapter cycles in one native session, normal client/runtime/wrapper0 and EOF without those diagnostics.'},
    {'scope':'Real Vive display availability and physical lens observation','evidence':['inputs/display-exception-authorization.json','inputs/hdmi-reconnect-response.json','vive-display-observation03','inputs/vive-lens-observation03-response.json'],'result':manual},
    {'scope':'Faulted native application release and subsequent new session','evidence':['native-fault-reentry01'],'result':'Intentional DirectoryNotFoundException -> existing Main.CloseApplication(1), client1/disconnect/absent; next exact app on same owned simulator runtime ->18 checks/client0/disconnect/absent; runtime/wrapper0 and all EOF. No historical-stall attribution.'}],
    'unchanged_software_evidence_reused':{'client':'Final03 core189, desktop72+live21+backup8, controller43, scene15, physics39 and cancellation seams; exact91 supplied inputs unchanged. New private engine is a distinct dependency with the new native evidence above.','server':'1432 unchanged inputs; accepted M3b native56/EUnit4266/CT149/xref/Dialyzer/release, no rerun.'},
    'unqualified':['Cold production native-vive-direct02 fresh-valid-stereo-head assertion remains failed before rendering check; zero application swapchains/91empty submissions.','Current diagnostic observation has zero valid wand pose samples and no button edges. Native production-export canonical transforms, signed mapping/GUI/subject gestures, model appearance and movement are unqualified.','Native focus/disconnect/reentry with both actual tracked wands and active signed consumers/captures/models; comfort and extended platform hardware exit require further physical observations.','Independent returned-success-code telemetry for the API dump entries is absent.','Both original desktop shutdown stalls remain failed and causally unattributed; no new desktop observation1 or review.','Full QUO-27, QUO-59, broader Stage2 and M4 remain open. No Quest qualification.']})
save('qualification.json',{'checkpoint':'QUO-65 private Vive environment/engine investigation','worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','actual_api_model':'openai-codex:gpt-6.1-sol','launcher_requested_effort':'max','effective_backend_effort':'unexposed','head':'293cf6115c0a6b18315eccdbb42cbca396f443d3','branch':'worktree/pearl-stone','new_Quod_production_test_spec_changes':0,'private_engine_files_changed':2,'private_engine_lines_added':6,'private_engine_lines_removed':2,'engine_patch_sha256':h(ev/'godot-4.7.2-openxr-lifetimes.patch'),'private_engine_sha256':patched['engine_sha256'],'matched_baseline_engine_sha256':base['engine_sha256'],'builds':builds,'native_manual_observation':manual,'fault_reentry':{'true_client_exits':[1,0],'true_runtime_exit':0,'true_wrapper_exit':0,'actual_sessions':2,'single_runtime':True},'historical_desktop_failures_resolved':False,'production_export_physical_Vive_accepted':False,'full_M4_accepted':False,'commit':False,'M5':False,'remaining':load(ev/'acceptance.json')['unqualified']})
print(json.dumps({'checked_wrappers':len(wrappers),'builds':{k:[v['supplied_inputs'],v['outputs']] for k,v in builds.items()},'head_valid_frames':pose['valid_head_frames'],'actual_lens_response_recorded':True,'production_changes':0,'explicit_completion':True}))
