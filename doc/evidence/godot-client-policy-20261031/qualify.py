"""Bind completed current software/package evidence without rerunning its work."""
import json,os,stat,subprocess
from pathlib import Path
from hashes import TASK,Digests,key,raw
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
def load(p):return json.loads(p.read_text())
def cache(r):
    p=Path(r['path']);assert raw(p)==r['sha256']
    rows=load(p)['records']
    for row in rows.values() if isinstance(rows,dict) else rows:
        k=tuple(row['stat_key']);assert k not in d.values or d.values[k]==row['sha256'];d.values[k]=row['sha256']
def receipt(label,exit=0):
    r=load(ev/'logs'/(label+'.json'));assert r['child_exit']==exit and not r['timed_out'],label
    for rows in [r['private_streams'],r['sanitized_streams']]:
        for row in rows.values():
            p=Path(row['path']);assert d.h(p)==row['sha256'] and p.stat().st_size==row['bytes']
    return r
original=load(ev/'answer-policy-release01-result.json')
assert original['source_unchanged'] and original['completed_gates']==2 and not original['all_true_exits_zero']
assert [r['child_exit'] for r in original['results']]==[0,1] and all(not r['timed_out'] for r in original['results'])
assert 'Failed: 2.  Skipped: 0.  Passed: 4276.' in (ev/'logs/answer-policy-release01-eunit-stdout.log').read_text()
gates=load(ev/'answer-policy-release02-result.json')
assert gates['all_true_exits_zero'] and not gates['source_unchanged'] and gates['completed_gates']==5
receipt('policy-release-reconcile01')
reconciliation=load(ev/'release-reconciliation.json');assert reconciliation['passed'] and reconciliation['original_campaign_outer_exit']==1
assert reconciliation['original_failure_retained'] and not reconciliation['provider_or_app_rerun']
assert set(reconciliation['derived_source_outputs'])=={'rebar.lock'}
assert reconciliation['original_result']['sha256']==d.h(ev/'answer-policy-release02-result.json')
cache(reconciliation['digest_cache'])
for r in gates['results']:assert r['child_exit']==0 and not r['timed_out'] and r['completion_confirmed']
server_manifest=ev/'inputs/answer-policy-release02-source-manifest.json'
server=load(server_manifest);server_source=Path(server['stage'])/'source'
assert not server['compiled_inputs_copied']
assert server['remaining_qualification']['changed_inputs']==['test/quod_lobby_tests.erl']
assert server['remaining_qualification']['unchanged_eunit_passes_reused']==4276
assert all(d.h(root/n)==sha for n,sha in server['files'].items())
for n,sha in server['files'].items():
    output=reconciliation['derived_source_outputs'].get(n)
    if output:assert output['input_sha256']==sha and d.h(server_source/n)==output['generated_sha256']
    else:assert d.h(server_source/n)==sha
provider_objects={}
for inventory in sorted((ev/'inputs').glob('answer-policy-release02-*-objects.json')):
    rows=load(inventory)
    for row in rows.values():assert d.h(Path(row['path']))==row['sha256']
    provider_objects[inventory.name]={'sha256':d.h(inventory),'objects':len(rows)}
assert len(provider_objects)==5
receipt('answer-policy-baseline01',1);receipt('answer-policy-final02');receipt('answer-policy-remote06')
assert 'POLICY_CT_RESULT {1,0,{0,0}}' in (ev/'logs/answer-policy-remote06-stdout.log').read_text()
receipt('resource-error-baseline02',1);receipt('resource-error-final01')
assert 'RESOURCE_ERROR_PASS checks=9' in (ev/'logs/resource-error-final01-stdout.log').read_text()
receipt('shutdown-owner-observation02',1);receipt('shutdown-observation-reconcile01')
close=load(ev/'shutdown-observation-reconciliation.json');assert close['shutdown_cause']=='unresolved' and not close['client_rerun']
manifests={}
for label,inputs,supplied,product in [('policy-product02',97,97,True),('policy-journey02',97,98,False)]:
    p=ev/'inputs'/('client-'+label+'-manifest.json');m=load(p);cache(m['digest_cache'])
    assert m['passed'] and m['trace_free']==product and not m['distributable']
    assert len(m['live_source_inputs'])==inputs and len(m['supplied_inputs'])==supplied
    assert len(m['commands'])==5 and all(c['true_exit']==0 for c in m['commands'])
    assert all(d.h(root/n)==v for n,v in m['live_source_inputs'].items())
    source=Path(m['stage'])/'source';assert all(d.h(source/n)==v for n,v in m['supplied_inputs'].items())
    dist=Path(m['export_executable']).parent;assert len(m['export_outputs'])==196
    assert all(d.h(dist/n)==r['sha256'] and (dist/n).stat().st_size==r['bytes'] for n,r in m['export_outputs'].items())
    manifests[label]={'path':str(p),'sha256':d.h(p),'inputs':inputs,'supplied':supplied,'exports':196,'export_bytes':sum(r['bytes'] for r in m['export_outputs'].values()),'trace_free':product}
assert load(Path(manifests['policy-product02']['path']))['live_source_inputs']==load(Path(manifests['policy-journey02']['path']))['live_source_inputs']
receipt('policy-current-journey01')
j=load(ev/'inputs/policy-current-journey01.json')
assert j['passed'] and all(c['true_exit']==0 for c in j['children'].values()) and all(j['eof'].values()) and not j['reader_errors']
assert not j['host_input_or_focus_action'] and j['native_input_count']==0
assert [len(j['children'][n]['checks']) for n in ['client-initial','client-reopen']]==[72,21]
private=TASK/'private/policy-current-journey01'
work=load(private/'sandbox/work/unchanged-work.json');assert work['work']['calls']==[]
for name in ['client-initial','client-reopen']:
    rows=[json.loads(s[10:]) for s in (private/(name+'-stdout.raw')).read_text().splitlines() if s.startswith('M1B_STATE ')]
    last=rows[-1];metrics=last['controller_metrics']
    assert last['scene_count']==last['live_sockets']==metrics['sources']==metrics['appearances']==metrics['captures']==0 and not metrics['Running']
inspection=load(ev/'inputs/package-inspection02.json');assert inspection['passed'];cache(inspection['digest_cache'])
a=load(ev/'inputs/policy-package-private01.json');b=load(ev/'inputs/policy-package-repro02.json')
assert a['archive_sha256']==b['archive_sha256']==inspection['archive_sha256']
assert a['files']==b['files'] and a['package_files']==207
assert d.h(Path(inspection['archive']))==a['archive_sha256']
for label in ['policy-package-private01','policy-package-repro02','policy-package-inspection02','policy-ordinary-launch01','policy-isolation-probe01']:receipt(label)
ordinary=load(ev/'inputs/policy-ordinary-launch01.json');assert ordinary['passed'] and ordinary['true_exit']==ordinary['normal_close_exit']==0 and ordinary['packaged_coreclr_loaded']
assert load(ev/'inputs/isolation-probe01.json')['passed']
before=load(ev/'inputs/before.json')['files'];before.update(load(ev/'inputs/client-before.json'));before.update(load(ev/'inputs/test-before.json'))
delta={};counts={}
for name,r in before.items():
    p=Path(r['before']);assert d.h(p)==r['sha256'] and p.stat().st_mode==r['mode']
    after=d.h(root/name);assert after!=r['sha256'];delta[name]={'before_path':str(p),'before_sha256':r['sha256'],'after_sha256':after,'full_mode':(root/name).stat().st_mode}
    run=subprocess.run(['git','diff','--no-index','--numstat',str(p),str(root/name)],capture_output=True,text=True)
    assert run.returncode==1;added,removed=map(int,run.stdout.split('\t')[:2]);counts[name]={'added':added,'removed':removed}
labels=sorted(p.stem for p in (ev/'logs').glob('*.json') if 'child_exit' in load(p))
results={label:{k:load(ev/'logs'/(label+'.json'))[k] for k in ['child_exit','timed_out']} for label in labels}
new_tests={n:{'sha256':d.h(root/n),'lines':len((root/n).read_text().splitlines())} for n in ['test/quod_proof_answer_tests.erl','client/godot-tests/ResourceErrorChecks.cs']}
out=TASK/'private/policy-final-qualification01';out.mkdir(mode=0o700,exist_ok=False);d.write(out/'computed-hashes.json')
q={'passed':True,'full_M4_or_M5':False,'actual_model':'openai-codex:gpt-6-astra','effective_backend_effort':'unexposed','worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f',
   'product':manifests['policy-product02'],'companion':manifests['policy-journey02'],'package':{'path':inspection['archive'],'sha256':a['archive_sha256'],'bytes':a['archive_bytes'],'files':207,'GLIBC':'2.44','current_host_only':True},
   'policy_remote_case':True,'policy_focused_checks':105,'resource_error_checks':9,'journey_checks':[72,21],'journey_host_inputs':0,'ordinary_launch_exit':0,'shutdown_cause':'unresolved','shutdown_observation_normal':True,'close_original_wrapper_exit':1,
   'source_delta':delta,'line_delta':counts,'new_test_sources':new_tests,'run_labels':labels,'true_outcomes':results,
   'sequential_release':{'qualification':'explicit composite; original full EUnit and remaining campaign outer failure retained','original':original,'remaining':gates,'remaining_reconciliation':reconciliation,'native_checks_reused':56,'eunit_passes_reused':4276,'corrected_eunit_generators':2},
   'server_source':{'manifest':str(server_manifest),'sha256':d.h(server_manifest),'actual_authored_inputs':len(server['files']),'provider_objects':provider_objects},
   'digest_cache':{'path':str(out/'computed-hashes.json'),'sha256':raw(out/'computed-hashes.json')},'old_API_bytes_read':0,'commit_or_push':False}
(ev/'result.json').write_text(json.dumps(q,indent=2)+'\n')
print(json.dumps({'qualified':True,'changed_inherited':len(delta),'package':q['package'],'shutdown_cause':q['shutdown_cause']}))
