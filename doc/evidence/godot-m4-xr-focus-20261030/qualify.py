"""Bind the finite software runs; never rerun a check or read a native API dump."""
import hashlib,json,stat,subprocess
from pathlib import Path
from hashes import Digests,TASK,raw
root=Path.cwd();ev=Path(__file__).resolve().parent;digests=Digests()
def write(p,value):p.write_text(json.dumps(value,indent=2)+'\n')
builds={}
for label in ['xr-focus-baseline02','xr-focus-final01','xr-focus-final02']:
 p=ev/'inputs'/('client-'+label+'-manifest.json');m=json.loads(p.read_text());assert m['passed'] and not m['diagnostic_overrides'] and not m['compiled_application_inputs_copied']
 assert len(m['supplied_inputs'])==92 and len(m['export_outputs'])==196
 cache=m['digest_cache'];assert raw(cache['path'])==cache['sha256']
 for r in json.loads(Path(cache['path']).read_text())['records']:digests.values[tuple(r['stat_key'])]=r['sha256']
 commands=[]
 for c in m['commands']:
  q=ev/('client-'+label+'-'+c['phase']);result=json.loads((q/'result.json').read_text())
  assert c['wrapper_exit']==0 and result['exit']==0 and not result['diagnostic_failure']
  commands.append({'phase':c['phase'],'true_child_exit':result['exit'],'result_sha256':raw(q/'result.json'),'full_log_sha256':raw(q/'output.log')})
 assert len(commands)==5
 stage=Path(m['stage'])/'source';dist=Path(m['export_executable']).parent
 for n,d in m['supplied_inputs'].items():assert digests.h(stage/n)==d
 for n,r in m['export_outputs'].items():assert (dist/n).stat().st_size==r['bytes'] and digests.h(dist/n)==r['sha256']
 builds[label]={'manifest_sha256':raw(p),'commands':commands,'supplied':92,'exports':196,'template':m['template'],'application_inputs_copied':False}
selected=json.loads((ev/'inputs/client-xr-focus-final01-manifest.json').read_text())
for n,d in selected['supplied_inputs'].items():assert digests.h(root/n)==d,n
passed={}
for label,count in [('xr-focus-final-controller01',67),('xr-focus-final-presentation01',15),('xr-focus-final-scene01',15)]:
 p=ev/label;r=json.loads((p/'result.json').read_text());c=json.loads((p/'client-result.json').read_text())
 assert r['passed'] and r['client_exit']==0 and all(r['eof'].values()) and not r['reader_errors'] and not r.get('capture')
 probes=[r for r in c.get('reports',[]) if 'passed' in r]
 assert c['passed'] and not c.get('failures') and all(r['passed'] for r in probes) and len(c['checks'])+len(probes)==count
 for n,d in r['driver_hashes'].items():assert raw(TASK/'private'/label/'drivers'/n)==d
 for stream in ['stdout','stderr']:
  private=TASK/'private'/label/(stream+'.raw');assert stat.S_IMODE(private.stat().st_mode)==0o600 and stat.S_IMODE(private.parent.stat().st_mode)==0o700
  assert private.read_bytes()==(p/(stream+'.log')).read_bytes()
 passed[label]={'checks':count,'client_exit':0,'eof':r['eof'],'reader_errors':r['reader_errors'],'result_sha256':raw(p/'result.json'),'client_result_sha256':raw(p/'client-result.json'),'guarded_native_inputs':r['native_input']}
metrics=json.loads((ev/'xr-focus-final-controller01/client-result.json').read_text())['metrics'];resources=metrics['resources']
assert all(metrics[n]==0 for n in ['Subscriptions','sources','appearances','captures','LateCallbacks'])
assert resources['Acquisitions']==resources['Releases']==resources['InstancesCreated']==resources['InstancesReleased']==2
assert resources['Decodes']==resources['TexturesDecoded']==1 and resources['LiveTemplates']==resources['LiveLeases']==0
baseline=json.loads((ev/'xr-focus-baseline-controller02/result.json').read_text())
assert baseline['client_exit']==1 and all(baseline['eof'].values()) and not baseline['reader_errors']
assert 'runtime-interactive models remain visible after desktop focus loss without replaying a held press' in (ev/'xr-focus-baseline-controller02/stderr.log').read_text()
failed={}
for label in ['xr-focus-final-menu01','xr-focus-final02-menu01']:
 r=json.loads((ev/label/'result.json').read_text());assert not r['passed'] and r['client_exit']==-9 and not r['completion_marker'] and not r['reader_errors']
 failed[label]={'client_exit':r['client_exit'],'eof':r['eof'],'failure':r['failure'],'result_sha256':raw(ev/label/'result.json')}
assert (root/'client/godot/tests/SpaceChecks.cs').read_bytes()==(ev/'inputs/SpaceChecks.before.cs').read_bytes()
assert not subprocess.check_output(['git','diff','--check']) and not subprocess.check_output(['git','diff','--cached','--name-only'])
digests.write(ev/'qualified-stat-digests.json')
write(ev/'qualification.json',{'software_focus_regression_passed':True,'all_requested_acceptance_claimed':False,'selected_manifest':'inputs/client-xr-focus-final01-manifest.json','selected_manifest_sha256':raw(ev/'inputs/client-xr-focus-final01-manifest.json'),'selected_trace_free_export':selected['export_executable'],'current_supplied_inputs_exact':92,'builds':builds,'passed_checks':passed,'final_controller_lifecycle_metrics':metrics,'baseline_expected_failure':{'client_exit':1,'eof':baseline['eof'],'failed_obligation':'model continuation after desktop focus loss'},'additional_desktop_menu_failures':failed,'failure_dispositions_sha256':raw(ev/'failure-dispositions.json'),'native_predicate_scope':'same Advance owner receives actual _Process session Focused, API running and valid-head predicates; fixtures inject those three values and actual XRServer source poses. No native API integration or headset visibility claimed.','old_diagnostic_scope':'Old frozen PhysicalChecks partials use removed applicationFocused field; no new composed diagnostic is claimed. Old payloads remain immutable historical evidence.','unchanged_server1432_core189':'accepted prior gates reused, not rerun','api_bytes_read':0,'native_headset_case_started':False,'startup_complaint':'OPEN, no startup correction','case16_human_visibility':'FAILED No controllers, look time/cause unknown; preserved','historical_desktop_stalls':'OPEN/unattributed','full_M4_accepted':False,'commit_or_M5':False,'digest_cache':{'path':str(ev/'qualified-stat-digests.json'),'sha256':raw(ev/'qualified-stat-digests.json'),'hits':digests.hits,'new_files':digests.new,'new_bytes':digests.bytes}})
print(json.dumps({'qualified':True,'controller':67,'presentation':15,'scene':15,'extra_menu':'two retained guard failures; no further retry','native_or_hardware':False,'api_bytes_read':0}))
