"""Bind the closed case and launcher-only correction without any live query."""
import hashlib,json,os
from pathlib import Path
os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent;task=Path('/data/quod-m4-vr-ca84d4f8-20261029')
def load(p):return json.loads(p.read_text())
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
owners=task/'private/native-vive-product23-preparation/unchanged-owners'
out=owners/'godot-m4-vive-retest-20261030/native-vive-product23'
r=load(out/'result.json');observations=load(out/'client-result.json')['snapshots'];final=observations[-1]
wrapper=load(owners/'godot-m4-vive-physical-20261029/logs/native-vive-product23-run.json')
assert r['passed'] and wrapper['child_exit']==0 and all(wrapper['eof'].values()) and not wrapper['reader_errors']
assert all(r[n+'_exit']==0 for n in ['client','runtime','server']) and all(r['eof'].values())
assert not r['reader_errors'] and not r['diagnostics'] and not r['runtime_processes_after']
d=r['display_rule'];assert d['config_unchanged'] and d['desktop_unchanged'] and r['original_calibration_unchanged']
assert any(m['name']=='HDMI-A-1' and m['disabled'] for m in d['after']['monitors'])
m=final['metrics'];resources=m['resources']
assert final['phase']=='observer-retired' and not m['Running']
assert all(m[k]==0 for k in ['Subscriptions','sources','appearances','LateCallbacks','captures'])
assert resources['Acquisitions']==resources['Releases']==2 and resources['InstancesCreated']==resources['InstancesReleased']==2
assert resources['LiveTemplates']==resources['LiveLeases']==0
expired=[s for s in observations if s['state']['operation_status']=='Sign-in expired; reconnect explicitly.']
assert expired and expired[0]['state']['world_accepted'] is False and expired[0]['state']['operation_available'] is False
launch=root/'doc/evidence/godot-m4-morning-journey-20261031/launch.py'
before=task/'private/case22-failure01/invocation/launch.py'
assert digest(before)=='c92745e767e9eef8594391b747c205d91a47e46292bf0d32792836ccce040d56'
assert before.read_text().count("'--timeout','2100',")==1
assert before.read_text().replace("'--timeout','2100',",'')==launch.read_text()
seam=load(root/'doc/evidence/godot-m4-vive-morning22-20261031/argv-seam-result.json')
assert seam['passed'] and seam['actual_wrapper_exit']==seam['actual_child_exit']==0 and seam['original_wrapper_watchdog_seconds']==2100
assert digest(launch)==seam['source_inputs'][str(launch)]['sha256']
api=Path(r['api_dump']['path']);st=api.stat();assert st.st_size==r['api_dump']['bytes']
result={'case':'native-vive-product23','closure_passed':True,'physical_journey_accepted':False,
 'human_report_exact':'seems to work ut pretty unusable. If I push the round pad, I see a menu how do I select an option ?',
 'human_report_source':'coordinator meta-1793451126530-fcvv7ds; createdAt1793451126533 is a receipt upper bound, not look start/end',
 'human_scope':'Usability failure/confusion; no journey Submit/create/enter/leave/reconnect completion qualified',
 'later_expiry_sample':{'frame':expired[0]['frames'],'operation_expired':True,'world_accepted':False,'operation_available':False,'pending':expired[0]['state']['pending'],'look_interval_or_complete_event_order_established':False},
 'final_button_counts':final['button_presses'],'native_edges':'Real trigger/pad/squeeze edges observed; intent is not inferred from them',
 'closure':{'client':r['client_exit'],'runtime':r['runtime_exit'],'server':r['server_exit'],'physical_and_wrapper':wrapper['child_exit'],'case_eof':r['eof'],'wrapper_eof':wrapper['eof'],'reader_errors':[],'diagnostics':[],'wrapper_elapsed_seconds':wrapper['elapsed_seconds'],'config_unchanged':True,'other_displays_unchanged':True,'hdmi_disabled':True,'calibration_unchanged':True,'runtime_processes_after':0,'final_metrics':m},
 'source_delta':{'path':str(launch.relative_to(root)),'before_path':str(before),'before_sha256':digest(before),'after_sha256':digest(launch),'only_change':'Remove unsupported --timeout/2100 arguments; existing wrapper internal watchdog2100 unchanged','production_changes':0},
 'actual_finite_seam':{'wrapper_exit':0,'harmless_child_exit':0,'eof':seam['eof'],'unchanged_offline_parser_budget_stdin_build_server_suites_rerun':False},
 'api_reference':{**r['api_dump'],'producer_hashed_once':True,'read_again':False,'parsed':False,'copied_into_boundary':False,'stat_key':[st.st_dev,st.st_ino,st.st_size,st.st_mtime_ns,st.st_ctime_ns]},
 'accepted_parent_snapshot':'bf4b7235f3c9b923bbd7780a7a956540a5c18bedeb3e41870ad406eac82094f5',
 'payload_manifest_sha256':r['client_manifest']['sha256'],'payload_rebuilt':False,'case24_or_other_new_launch':'UNRUN',
 'private_output_origin':str(out),'inspection_failures':'Two metadata inspections failed (pending int treated as sequence; assumed old output origin). Retained separately; corrected metadata only, no native rerun.'}
(ev/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'recorded':True,'closure_passed':True,'human_usability':'FAILED','journey_pass':False,'source_changes':1,'production_changes':0,'api_bytes_read_again':0}))
