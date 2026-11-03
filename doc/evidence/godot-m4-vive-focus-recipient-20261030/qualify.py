"""Bind finite offline receipts and exact diagnostic source delta; no live I/O."""
import ast,hashlib,json,os,subprocess,sys
from pathlib import Path
sys.dont_write_bytecode=True
from freeze_hashes import Digests,TASK,raw,key
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
helper=root/'doc/evidence/godot-m4-vive-retest10-20261030/focus_events.py'
before=TASK/'private/metadata-inputs/focus-recipient-base01/focus_events.py'
old_sha=raw(before);new_sha=raw(helper)
assert old_sha=='bb63ff9db8f3aef231f22043e8336c263afcf52b553c908419ff3e0abdd584e2'
assert new_sha=='a7b584c8b137b5617b89a98e57f6f42e895d3247278b4c3de52b595ecbea5889'
def segment(p,name):
    text=p.read_text();node=next(n for n in ast.parse(text).body if isinstance(n,ast.ClassDef) and n.name==name)
    return ast.get_source_segment(text,node)
assert segment(before,'RemainingBudget')==segment(helper,'RemainingBudget')
original=json.loads((TASK/'artifacts/quod-godot-m4-vive-focus12-handoff-ca84d4f8-20261030-01/source-manifest.json').read_text())
changed=[]
for name,row in original.items():
    p=root/name
    if row['kind']=='symlink':assert p.is_symlink() and str(p.readlink())==row['target'];continue
    assert p.is_file() and not p.is_symlink() and p.stat().st_mode&0o7777==row['mode']
    if name==str(helper.relative_to(root)):assert new_sha!=row['sha256'];changed.append(name)
    else:assert key(p) in d.values and d.h(p)==row['sha256'] and p.stat().st_size==row['bytes']
assert changed==[str(helper.relative_to(root))]
gates=[]
for label,count,result_name in [('focus-recipient-parser01',14,'focus-checks-result.json'),('focus-recipient-checks01',33,'recipient-checks-result.json')]:
    receipt=json.loads((ev/'logs'/(label+'.json')).read_text());result=json.loads((ev/result_name).read_text())
    assert receipt['child_exit']==0 and not receipt['timed_out'] and result['passed'] and result['count']==count
    inputs=TASK/'private/runs'/label/'driver-inputs'
    for n,digest in receipt['driver_inputs'].items():assert raw(inputs/n)==digest
    assert raw(inputs/'external-inputs/focus_events.py')==new_sha
    for stream in ['stdout','stderr']:
        row=receipt['private_streams'][stream];p=Path(row['path']);published=Path(receipt['sanitized_streams'][stream]['path'])
        assert p.stat().st_mode&0o7777==0o600 and p.parent.stat().st_mode&0o7777==0o700
        assert raw(p)==row['sha256']==raw(published)==receipt['sanitized_streams'][stream]['sha256']
        assert p.stat().st_size==row['bytes'] and p.read_bytes()==published.read_bytes()
    gates.append({'label':label,'checks':count,'true_child_exit':0,'timeout':False,'stdout_stderr_eof':True,
                  'exact_preexecution_inputs':True,'no_real_ipc':True})
delta=subprocess.run(['git','diff','--no-index','--numstat',str(before),str(helper)],capture_output=True,text=True)
assert delta.returncode==1 and not delta.stderr
added,removed,_=delta.stdout.split('\t',2)
source_delta={'existing_changed_sources':{str(helper.relative_to(root)):{'before_sha256':old_sha,'after_sha256':new_sha,
 'added_lines':int(added),'removed_lines':int(removed),'mode':helper.stat().st_mode&0o7777}},
 'production_lines_changed':0,'new_parallel_observer':False,'remaining_budget_class_unchanged':True,
 'remaining_budget_class_sha256':hashlib.sha256(segment(helper,'RemainingBudget').encode()).hexdigest(),
 'exact_old_executed_source_preserved':'Accepted case12 snapshot and private before-inputs copy',
 'changed_behavior':'Existing parser invokes one successor classification after event-anchored owned loss; explicit bindings and shared process identity/budget owners, no persistent recipient registry.'}
(ev/'source-delta.json').write_text(json.dumps(source_delta,indent=2)+'\n')
record={'checkpoint':'QUO-65 offline successor-recipient diagnostic preparation','worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f',
 'actual_api_model':'openai-codex:gpt-6.1-sol','launcher_requested_and_returned_effort':'max','effective_backend_effort':'unexposed',
 'branch':'worktree/pearl-stone','head':'293cf6115c0a6b18315eccdbb42cbca396f443d3','parent':'f716ddf5e578df957a5b18421a0727a32c634f87',
 'offline_preparation_passed':True,'gates':gates,'new_pure_recipient_checks':33,'affected_existing_parser_checks':14,
 'unchanged_budget6_stdin_build_server_core_native_suites_repeated':False,'production_application_engine_runtime_changes':0,
 'diagnostic_existing_helper_changes':1,'application_inputs_exports_unchanged':[93,196],
 'live_commands_queries_subscription_focus_display_runtime_fixture_or_physical_actions':False,
 'live_recipient_observed':False,'recipient_or_focus_cause_established':False,'full_m4_accepted':False,
 'distributable':False,'remaining':['Parent independent qualification of this exact new scope.',
 'No live/native/desktop case13 or observer arm is authorized. A future caller must supply current private owner/incarnation bindings and the original absolute deadline.',
 'Recipient roles identify a lookup-time recipient only; no initiating actor or historical desktop/cold-head failure resolution. Controller gestures/comfort/fullM4 remain unqualified.'],
 'failure_dispositions':['No finite check failed. One earlier rg inspection used an absent guessed model-session.json path (exit2); actual retained launcher-metadata.json was read. No product or live result follows.',
 'Parent91 failed only its obsolete archive-name assumption; accepted corrected92 reused authenticated bytes. Both parent trees and every earlier failure/snapshot are retained.'],
 'tracker':'Required ownUUID explicit-project work_radar0/nestedisErrorfalse, no mutations/publication or fresh issue-state inference.',
 'source_delta':source_delta}
(ev/'qualification.json').write_text(json.dumps(record,indent=2)+'\n');d.write(TASK/'cache/focus-recipient-qualified-inputs.json')
print(json.dumps({'passed':True,'finite_new_checks':33,'affected_parser_checks':14,'new_helper_sha256':new_sha,'diagnostic_lines_added':int(added),'diagnostic_lines_removed':int(removed),'real_listener_armed':False}))
