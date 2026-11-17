#!/usr/bin/env python3
"""Index existing receipts and exact source deltas; never rerun product work."""
import difflib,hashlib,json,re,subprocess
from pathlib import Path

root=Path.cwd();ev=Path(__file__).resolve().parent
def read(name):return json.loads((ev/name).read_text())
def write(name,value):(ev/name).write_text(json.dumps(value,indent=2)+'\n')
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
client=read('inputs/client-final03-manifest.json')
assert client['passed'] and client['distributable'] and not client['diagnostic_overrides']
assert not client['compiled_application_inputs_copied']
assert all(sha(root/name)==digest for name,digest in client['live_source_inputs'].items())
build=[]
for entry in client['commands']:
    name='client-final03-'+entry['phase']+'/result.json';receipt=read(name)
    assert receipt['exit']==0 and not receipt['diagnostic_failure'],name
    build.append({'receipt':name,'sha256':sha(ev/name),'command':receipt['command'],'true_child_exit':receipt['exit']})
assert 'CORE_PASS checks=189' in (ev/'client-final03-core/output.log').read_text()
commands={}
for path in sorted((ev/'logs').glob('*.json')):
    value=json.loads(path.read_text())
    commands[path.stem]={'receipt':str(path.relative_to(ev)),'receipt_sha256':sha(path),
        'command':value.get('command'),'true_child_exit':value.get('child_exit'),
        'timed_out':value.get('timed_out'),'elapsed_seconds':value.get('elapsed_seconds'),
        'sanitized_log':str(path.with_suffix('.log').relative_to(ev)),
        'sanitized_log_sha256':sha(path.with_suffix('.log'))}
write('command-index.json',commands)
passed=['client-final03','gui-desktop-final03','gui-desktop-final03-journey',
    'gui-desktop-final03-backup-import','input-final03','scene-final03','physics-final03',
    'shutdown-connect-final03','backup-cancel-final03']
assert all(commands[n]['true_child_exit']==0 and not commands[n]['timed_out'] for n in passed)
for name in ['input-final03/result.json','scene-final03/result.json','physics-final03/campaign.json',
             'gui-desktop-final03-campaign.json','shutdown-connect-final03/result.json']:
    assert read(name)['passed'],name
assert all(row['passed'] and row['child_exit']==0 and row['output_eof'] for row in read('backup-cancel-final03/result.json'))
counts={}
for name in ['input-final03/client-result.json','scene-final03/client-result.json',
             'physics-final03/client-result.json','gui-desktop-final03/export-result.json',
             'gui-desktop-final03/export-result.json.m4.json',
             'gui-desktop-final03-backup-import/backup-import-result.json']:
    data=read(name);assert data['passed'];counts[name]=len(data['checks'])
native={}
for label in ['native-simulated-final03','native-fault-close-final03','native-vive-final03']:
    result=read(label+'/result.json');api=read(label+'/api-lifecycle.json')
    assert not result['passed'] and result['client_output_eof'] and result['service_exit']==0
    native[label]={'campaign_passed':False,'wrapper_exit':commands[label]['true_child_exit'],
        'client_exit':result['client_exit'],'runtime_exit':result['service_exit'],
        'completion_marker':result['completion_marker'],'completed':result['completed'],
        'output_eof':True,'timeout':commands[label]['timed_out'],
        'owned_client_present_after':result['post_client_inventory']['owned_client_present'],
        'diagnostics':result['client_diagnostics'],'api_counts':api['counts'],
        'submitted_layer_counts':api['submitted_layer_counts'],
        'projection_view_counts':api['projection_view_counts'],
        'api_scope':api['scope'],'result':label+'/result.json','api':label+'/api-lifecycle.json'}
head_delta={};patch=[]
for name in client['input_classes']['client_source']:
    current=(root/name).read_text()
    original=subprocess.run(['git','show','HEAD:'+name],capture_output=True)
    before=original.stdout.decode() if original.returncode==0 else ''
    if current==before:continue
    diff=list(difflib.unified_diff(before.splitlines(True),current.splitlines(True),fromfile='HEAD/'+name,tofile='final03/'+name))
    head_delta[name]={'status':'modified' if original.returncode==0 else 'added',
        'sha256':sha(root/name),'added':sum(x.startswith('+') and not x.startswith('+++') for x in diff),
        'removed':sum(x.startswith('-') and not x.startswith('---') for x in diff)}
    patch+=diff
write('inputs/final03-vs-head.json',{'head':'293cf6115c0a6b18315eccdbb42cbca396f443d3',
    'scope':'All changed client_source inputs including previously untracked M4 files; UID seeds and fixtures remain separately indexed. Full source binary patch/untracked archive is authoritative.',
    'files':head_delta,'added':sum(r['added'] for r in head_delta.values()),'removed':sum(r['removed'] for r in head_delta.values())})
(ev/'inputs/final03-vs-head.patch').write_text(''.join(patch))
patterns=[re.compile(rb'-----BEGIN (?:[A-Z ]+)?PRIVATE KEY-----'),
    re.compile(rb'"(?:privateKey|private_key|seed|access_token|refresh_token)"\s*:\s*"[^"\n]{16,}"',re.I)]
scanned=[];candidates=[]
for path in ev.rglob('*'):
    if path.is_file() and path.suffix in ['.json','.txt','.log']:
        scanned.append(str(path.relative_to(ev)))
        if any(pattern.search(path.read_bytes()) for pattern in patterns):candidates.append(str(path.relative_to(ev)))
assert not candidates,{'private_pattern_candidates':candidates}
write('inputs/public-content-audit.json',{'scope':'R2 JSON/text/full sanitized logs; mapped runtime input retention separately admits only executable/library code and compiler/tool dependencies',
    'files_scanned':len(scanned),'secret_pattern_candidates':[],
    'private_exclusions':['cache/private (all stores, credentials, calibration copies, raw diagnostics and raw logs)',
        'all user original Steam calibration/configuration'],'limits':'Pattern audit is supporting evidence, not a cryptographic proof of absence. Explicit artifact selection and retained code-only owner provide the privacy boundary.'})
qualification={'checkpoint':'M4-R2','date':'2026-10-29','worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f',
    'actual_api_model':'openai-codex:gpt-6.1-sol','launcher_requested_effort':'max','effective_backend_effort':'unexposed',
    'branch':'worktree/pearl-stone','head':'293cf6115c0a6b18315eccdbb42cbca396f443d3',
    'implementation_frozen':True,'full_m4_accepted':False,'committed':False,'final_client_label':'final03',
    'source_only_build':True,'compiled_application_inputs_copied':False,'production_tracing':False,
    'supplied_inputs':{k:len(v) for k,v in client['input_classes'].items()},
    'dependency_archives':len(client['dependency_archives']),'engine_archives':len(client['engine_archives']),
    'export_outputs':len(client['export_outputs']),'build_commands':build,'core_checks':189,
    'passed_final_command_labels':passed,'assertion_counts':counts,'native_final_campaigns':native,
    'hardware_observation':'inputs/canonical-hardware-observation05.json',
    'server_inputs_unchanged':1432,'server_gates_rerun':False,
    'reused_server_acceptance':'Committed M3b native56/EUnit4266/CT149/xref/Dialyzer/local release, exact live and accepted-stage hashes verified',
    'original_desktop_stalls_resolved':False,'physical_headset_acceptance':False,'quest_qualification':False,
    'native_engine_errors_resolved':False,'tracker':{'QUO-65':'in-review80','QUO-60':'67','metadata_mutated_in_r2':False,
        'body_publication':'Still blocked by prior automatic approval review; no retry or bypass'},
    'inbox':{'tool':'list_queued_prompts','full_batch':'inputs/final-inbox-batch02.json','consumed':False,
        'consume_session_inbox_available':False,'actionable_findings_dispositioned':True},
    'no_owned_product_process_or_interactive_prompt_pending':True,
    'remaining':['Pinned Godot interaction-profile RID leak and unsupported spatial-discovery disconnect',
        'Direct Vive HMD display/scanout, human pixels/comfort and complete mapped physical gestures/disconnect/reentry',
        'Cold hardware exported render assertion failure with zero swapchains; exact cause unproven',
        'Historical GUI backup-import and normal-close physics desktop stalls remain failed and unattributed']}
write('qualification.json',qualification)
acceptance=[
    {'id':1,'scope':'One signed mapping/adapter, strict profiles/components/roles',
     'result':'Final exported software qualified; canonical engine grip contract corrected; no full physical mapping claim',
     'evidence':['input-final03','gui-desktop-final03/export-result.json.m4.json','inputs/canonical-hardware-observation05.json','engine-ownership.md']},
    {'id':2,'scope':'Native desktop/pointing/generic GUI and fenced private preferences',
     'result':'Final exported software qualified including invalid-row ordinary Reset, conflict/recovery and fresh encrypted backup',
     'evidence':['gui-desktop-final03','gui-desktop-final03-backup-import','scene-final03','../godot-m4-20261029/acceptance.json']},
    {'id':3,'scope':'Lifecycle, source identity, cancellation, neutral rearm and arbitration',
     'result':'Actual desktop and injected real-engine frames qualified; native simulator assertions observed; full native teardown and physical reentry remain open',
     'evidence':['input-final03/client-result.json','native-simulated-final03','shutdown-connect-final03','backup-cancel-final03']},
    {'id':4,'scope':'Current signed transient physics, lease/sequence/incarnation/deadline and uncertainty',
     'result':'Final real HTTPS/WSS/native physics qualified with native WASD/injected controller source; prior unknown outcomes preserved',
     'evidence':['physics-final03','../godot-m4-20261029/navigation-final06','../godot-m3b-20261029']},
    {'id':5,'scope':'Licensed verified representations and real consumer/resource lifetime',
     'result':'Final admission/decode/render and unchanged renewals qualified; no watched history/install/write/sync work; real invalidation/repair and source release observed',
     'evidence':['input-final03','gui-desktop-final03/export-result.json.m4.json','scene-final03']},
    {'id':6,'scope':'Actual OpenXR/runtime/start-stop, native teardown and Vive hardware',
     'result':'Partial, not accepted: private runtime repaired, simulator stereo submissions and real canonical device poses/side-grips observed. Pinned-engine teardown errors, cold exported hardware rendering and HMD display/physical acceptance remain open; original desktop stalls unresolved',
     'evidence':['runtime-repair.md','engine-ownership.md','shutdown-investigation.md','native-simulated-final03','native-fault-close-final03','native-vive-final03','vive-interactive05']}
]
write('acceptance.json',acceptance)
print(json.dumps({'indexed_commands':len(commands),'final_build_commands':len(build),'core_checks':189,
    'final_assertion_counts':counts,'head_client_files_changed':len(head_delta),'public_files_scanned':len(scanned),
    'full_m4_accepted':False,'production_frozen':True}))
