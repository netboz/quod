"""Bind completed offline preparation; no tests, old exports or API dumps replayed."""
import json,stat,subprocess
from pathlib import Path
from cue_hashes import Digests,TASK,raw
root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
manifest=ev/'inputs/client-runtime-cue01-manifest.json';assert raw(manifest)=='9073b314599bd64531792acd63cbcd2e21ef54b73a41b25cd041260a4433fb08'
m=json.loads(manifest.read_text());assert m['passed'] and not m['distributable'] and not m['compiled_application_inputs_copied']
cache=m['digest_cache'];assert raw(cache['path'])==cache['sha256']
for r in json.loads(Path(cache['path']).read_text())['records']:d.values[tuple(r['stat_key'])]=r['sha256']
stage=Path(m['stage'])/'source';dist=Path(m['export_executable']).parent
assert len(m['supplied_inputs'])==94 and len(m['live_source_inputs'])==92 and len(m['export_outputs'])==196
for n,v in m['supplied_inputs'].items():assert d.h(stage/n)==v
for n,v in m['live_source_inputs'].items():assert d.h(root/n)==v
for n,v in m['export_outputs'].items():assert (dist/n).stat().st_size==v['bytes'] and d.h(dist/n)==v['sha256']
commands=[]
for c in m['commands']:
 p=ev/('client-runtime-cue01-'+c['phase']);r=json.loads((p/'result.json').read_text());assert c['wrapper_exit']==r['exit']==0 and not r['diagnostic_failure']
 commands.append({'phase':c['phase'],'true_child_exit':0,'result_sha256':raw(p/'result.json'),'full_log_sha256':raw(p/'output.log')})
assert len(commands)==5
wrappers={}
for label in ['runtime-cue-build01','runtime-cue-pure-prepare01','runtime-cue-gates01','runtime-cue-binding01']:
 p=ev/'logs'/(label+'.json');r=json.loads(p.read_text());assert r['child_exit']==0 and not r['timed_out']
 for s,v in r['private_streams'].items():
  q=Path(v['path']);assert stat.S_IMODE(q.stat().st_mode)==0o600 and stat.S_IMODE(q.parent.stat().st_mode)==0o700 and raw(q)==v['sha256']
 for s,v in r['sanitized_streams'].items():assert raw(v['path'])==v['sha256']
 wrappers[label]={'true_child_exit':0,'receipt_sha256':raw(p),'stdout':r['sanitized_streams']['stdout'],'stderr':r['sanitized_streams']['stderr']}
assert 'M4_RUNTIME_CUE_GATES_COMPLETE checks=21 hardware=false samples=0 domain_writes=0' in (ev/'logs/runtime-cue-gates01-stdout.log').read_text()
binding=json.loads((ev/'binding-checks.json').read_text());assert binding['passed'] and binding['count']==20
pure=json.loads((ev/'inputs/pure-preexecution.json').read_text())
for n,r in pure.items():
 assert raw(r['path'])==raw(r['before_execution_copy'])==r['sha256'] and stat.S_IMODE(Path(r['before_execution_copy']).stat().st_mode)==r['mode']
for n in ['ViveLookCue.cs','CueChecks.cs']:assert raw(ev/n)==pure[n]['sha256']
test_outputs={str(p.relative_to(TASK/'builds/runtime-cue-gates01')):{'sha256':raw(p),'bytes':p.stat().st_size,'mode':stat.S_IMODE(p.stat().st_mode)} for p in sorted((TASK/'builds/runtime-cue-gates01/bin/Release/net10.0').iterdir()) if p.is_file()}
assert test_outputs
assert not subprocess.check_output(['git','diff','--check']) and not subprocess.check_output(['git','diff','--cached','--name-only'])
d.write(ev/'qualified-stat-digests.json')
q={'passed':True,'scope':'offline diagnostic preparation only','diagnostic_manifest_sha256':raw(manifest),'supplied_inputs':94,'unchanged_selected_product_inputs':92,'staged_original_input_override':['client/godot/tests/ExportChecks.cs'],'new_diagnostic_helpers':['client/godot/tests/PhysicalChecks.cs','client/godot/tests/ViveLookCue.cs'],'exports':196,'dll':m['export_outputs']['data_Quod_linuxbsd_x86_64/Quod.dll'],'pck':m['export_outputs']['quod.pck'],'template':m['template'],'build_commands':commands,'wrappers':wrappers,'pure_cue_checks':21,'source_binding_privacy_checks':20,'pure_preexecution_inputs':pure,'pure_test_outputs':test_outputs,'product_changes':False,'compiled_application_inputs_copied':False,'distributable':False,'functional_application_executed':False,'live_runtime_device_display_focus_socket_queries':0,'physical_case_started':False,'api_bytes_read':0,'actual_native_cue_or_controller_visibility':'UNRUN','old_helpers_and_failures':'preserved historical; ordinary menu guarded failures remain FAILED/inconclusive; case16 No controllers remains FAILED with unknown look time/cause','startup_complaint':'OPEN','future_human_contact':'coordinator only; separate explicit authorization required before a fresh owned run','full_M4_accepted':False,'commit_or_M5':False,'digest_cache':{'path':str(ev/'qualified-stat-digests.json'),'sha256':raw(ev/'qualified-stat-digests.json'),'hits':d.hits,'new_files':d.new,'new_bytes':d.bytes}}
(ev/'qualification.json').write_text(json.dumps(q,indent=2)+'\n');print(json.dumps({'qualified':True,'pure':21,'binding_privacy':20,'commands':5,'native_or_functional_app':False,'api_bytes_read':0}))
