"""Bind the failed11 receipts and disposable transport counterfactual, no replay."""
import hashlib,json,re,sys
from pathlib import Path
sys.dont_write_bytecode=True
from freeze_hashes import Digests,TASK,key,raw
root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
def load(p):return json.loads(Path(p).read_text())
def write(p,v):Path(p).write_text(json.dumps(v,indent=2)+'\n')
case=ev.parent/'godot-m4-vive-retest-20261030/native-vive-product11';r=load(case/'result.json');c=load(case/'client-result.json')
wrapper=ev.parent/'godot-m4-vive-physical-20261029/logs/native-vive-product11-run.json';w=load(wrapper)
assert r['error']=='RuntimeError: Physical driver stdin ended without finish'
assert not r['passed'] and not r['product_finished'] and r['product_ready']
assert [r[k+'_exit'] for k in ['client','runtime','server']]==[1,0,0] and w['child_exit']==1
assert not r['reader_errors'] and not w['reader_errors'] and not r['diagnostics']
assert all(r['eof'].values()) and all(w['eof'].values()) and not r.get('client_timeout') and not w.get('timed_out')
assert not any('stack_capture' in k for k in r)
assert r['startup_inventory']['exit']==0 and r['startup_inventory']['wand_devices']==2
assert not any('diagnostic_instruction' in x for x in r['commands'])
assert r['original_calibration_unchanged'] and not r['runtime_processes_after']
rule=r['display_rule'];assert rule['desktop_unchanged'] and rule['config_unchanged']
assert next(m for m in rule['after']['monitors'] if m['name']=='HDMI-A-1')['disabled']
assert rule['enable']['child_exit']==rule['restore']['child_exit']==0
assert rule['before']['config_sha256']==rule['after']['config_sha256']
for p,digest in rule['after']['config_sha256'].items():assert raw(Path(p))==digest
redactions={x['published_path']:x for x in load(ev/'publication-redaction.json')['changes']};streams={}
for name,row in r['streams'].items():
    p=Path(row['raw']);assert p.stat().st_mode&0o7777==0o600 and p.parent.stat().st_mode&0o7777==0o700
    data=p.read_bytes();assert hashlib.sha256(data).hexdigest()==row['sha256'] and len(data)==row['bytes']
    published=case/(name+'.log');expected=re.sub(rb'(?i)LHR-[A-Za-z0-9]+',b'<device-serial-redacted>',data)
    assert hashlib.sha256(expected).hexdigest()==row['sanitized_sha256']
    if str(published) in redactions:
        change=redactions[str(published)];assert change['producer_published_sha256']==row['sanitized_sha256']
        saved=Path(change['preserved_original']);assert saved.stat().st_mode&0o7777==0o600 and saved.read_bytes()==expected
        expected,count=re.subn(rb'\bLHB-[A-Za-z0-9]+',b'<base-station-serial-redacted>',expected)
        assert count==change['replacements'] and hashlib.sha256(expected).hexdigest()==change['current_published_sha256']
    assert published.read_bytes()==expected and not re.search(rb'\b(?:LHR|LHB)-[A-Za-z0-9]+',expected)
    streams[name]={'raw_sha256':row['sha256'],'current_public_sha256':hashlib.sha256(expected).hexdigest(),'raw_mode':'0600','eof':r['eof'][name]}
for kind,row in w['streams'].items():
    p=Path(row['path']);assert p.stat().st_mode&0o7777==0o600 and raw(p)==row['sha256']
    assert raw(wrapper.parent/('native-vive-product11-run-'+kind+'.log'))==row['sanitized_sha256']
api=load(ev/'api-lifecycle.json');dump=Path(api['raw_path']);current=key(dump)
assert list(current)==api['raw_stat_key'] and dump.stat().st_mode&0o7777==0o600
assert api['raw_sha256']==r['api_dump']['sha256'] and api['raw_bytes']==r['api_dump']['bytes']
d.values[current]=api['raw_sha256'];d.used[current]=api['raw_sha256']
assert len(c['checks'])==11 and [s['phase'] for s in c['snapshots']]==['ready','observer-retired']
snapshots=[]
for s in c['snapshots']:
    assert 'geometry_receipt' in s and 'geometry' not in s
    snapshots.append({'phase':s['phase'],'frames':s['frames'],'metrics':s['metrics'],'geometry_receipt':s['geometry_receipt']})
bindings={}
pre=load(ev/'preexecution.json');assert pre['passed'] and not pre['runtime_started']
for n,v in pre['sources'].items():
    p=root/n;q=Path(v['saved']);assert d.h(p)==raw(q)==v['sha256']
    assert p.stat().st_mode&0o7777==q.stat().st_mode&0o7777==v['mode']
    bindings[n]=v['sha256']
for name,digest in r['driver_inputs'].items():
    p=TASK/'private/native-vive-product11/drivers'/Path(name).name;assert raw(p)==digest
for name,digest in w['driver_inputs'].items():
    p=TASK/'private/runs/native-vive-product11-run/driver-inputs'/name;assert raw(p)==digest
probes={}
for name in ['focus11-stdin-pipes01','focus11-stdin-pty01']:
    run=load(ev/'logs'/(name+'.json'));assert run['child_exit']==0 and not run['timed_out']
    row=load(ev/'logs'/(name+'-stdout.log'));probes[name]=row
assert probes['focus11-stdin-pipes01']['stdin_eof'] and not probes['focus11-stdin-pipes01']['tty']
assert probes['focus11-stdin-pty01']['tty'] and probes['focus11-stdin-pty01']['expected_finish_received']
assert not (TASK/'private/native-vive-product11-focus').exists()
qualification={'checkpoint':'QUO-65 native-vive-product11 failed control-channel launch',
    'worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','actual_api_model':'openai-codex:gpt-6.1-sol',
    'launcher_requested_and_returned_effort':'max','effective_backend_effort':'unexposed',
    'branch':'worktree/pearl-stone','head':'293cf6115c0a6b18315eccdbb42cbca396f443d3','parent':'f716ddf5e578df957a5b18421a0727a32c634f87',
    'campaign_passed':False,'exact_failure':r['error'],'client_runtime_server_driver_wrapper_exits':[1,0,0,1,1],
    'case_eof':r['eof'],'wrapper_eof':w['eof'],'reader_errors':[],'diagnostics':[],'timeout_or_stack':False,
    'elapsed_seconds':w['elapsed_seconds'],'startup_both_wands':True,'startup_inventory_exit':0,
    'signed_preparation_checks':11,'product_ready_and_first_draw':True,'manual_instructions':[],
    'human_observation':None,'focus_listener_armed':False,'listener_deadline_or_interval':'UNRUN; no live listener owner/deadline was created.',
    'transport_probe':probes,'transport_attribution':'Current exec plain-pipe transport delivers EOF; same disposable code under PTY receives the owned finish line. No product/helper-policy correction or native retry.',
    'snapshots':snapshots,'resource_limit':'Last snapshot precedes Main cleanup: subscriptions13/live leases2/instances created1 remain recorded. No post-close model/subscription release observation or full resource acceptance is claimed.',
    'calibration_unchanged':True,'hdmi_restored_disabled':True,'other_displays_and_current_configs_unchanged':True,'current_config_files':len(rule['after']['config_sha256']),
    'api_counts':api['counts'],'api_layer_counts':api['submitted_layer_counts'],'api_projection_view_counts':api['projection_view_counts'],'api_scope':api['scope'],
    'source_bindings':bindings,'streams':streams,'product_source_changes':0,'qualified_focus_helper_changes':0,
    'supplied_inputs_unchanged':93,'exported_files_unchanged':196,'diagnostic_nondistributable':True,
    'new_application_engine_server_builds_or_unchanged_suites':0,
    'remaining':['Live filtered focus interval/model observation UNRUN; no card, neutral/sample/gesture/movement authority or physical pass.',
        'No case12 authority. Preserve failed11 and old failures; no fullM4/QUO27/59/Stage2/Quest or historical-desktop cause claim.']}
write(ev/'qualification.json',qualification)
cache=TASK/'cache/focus11-receipt-binding-hashes.json';d.write(cache)
write(ev/'receipt-cache.json',{'path':str(cache),'sha256':raw(cache),'strict_api_key_reused_from_single_parse':True})
print(json.dumps({'receipt_binding_passed':True,'campaign_passed':False,'signed_checks':11,'stdin_counterfactual_passed':True,'live_listener_or_human_observation':False}))
