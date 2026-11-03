#!/usr/bin/env python3
"""Check only this observation's recorded bytes/exits, never rerun a campaign."""
import hashlib,json,re,subprocess
from pathlib import Path

root=Path.cwd();ev=Path(__file__).resolve().parent
def read(name):return json.loads((ev/name).read_text())
def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
observation=read('observation01.json');build=read('inputs/diagnostic-build.json')
assert observation['passed'] and observation['single_observation']
assert observation['marker_count']==1 and observation['marker_seen'] and observation['client_output_eof']
assert observation['client_exit']==0 and observation['server_child_exit']==0 and observation['server_output_eof']
assert not observation['client_watchdog'] and not observation['driver_reader_exception_text'] and not observation['server_reader_errors']
assert all(row['child_exit']==0 and not row['outer_timeout'] for row in observation['driver_commands'])
assert build['passed'] and not build['distributable'] and len(build['commands'])==3
assert len(build['authored_inputs'])==91 and len(build['export_outputs'])==196
assert all(digest(root/name)==sha for name,sha in build['live_source_inputs'].items())
production=root/'client/godot/Main.cs';diagnostic=ev/'inputs/diagnostic-Main.cs'
assert digest(production)=='e9c010f71a9c1369fd5b451fe1d7fa275948089b3a96e69fe6d8f21b543fec1e'
assert diagnostic.read_text()==production.read_text().replace('GetTree().Quit(xrStopped ? exitCode : 1);','GetTree().Quit(xrStopped ? exitCode : 1);\n        GD.Print("M4_QUIT_RETURNED");')
assert all(text not in diagnostic.read_text() for text in ['M4_R1_SHUTDOWN','M4_R2_RENEWAL'])
prior=json.loads((root/'doc/evidence/godot-m4-r2-20261029/inputs/client-final03-manifest.json').read_text())
assert all(digest(Path(prior['source'])/name)==row['sha256'] for name,row in prior['export_outputs'].items())
checks=read('backup-import01/backup-import-result.json');assert checks['passed'] and len(checks['checks'])==8
inputs=read('backup-import01/native-input.json')
assert all(row.get('child_exit')==0 for row in inputs)
streams={}
for path in ev.glob('*-stdout.log'):
    streams[path.name]={'bytes':path.stat().st_size,'sha256':digest(path)}
for path in ev.glob('*-stderr.log'):
    streams[path.name]={'bytes':path.stat().st_size,'sha256':digest(path)}
assert streams['desktop-driver-stderr.log']['bytes']==0
raw_private=Path('/home/yan/.cache/quod-m4-observation1-artifacts/private')
captures=list(raw_private.rglob('*stacks*'));assert not captures
scan=[];candidates=[]
patterns=[re.compile(rb'-----BEGIN (?:[A-Z ]+)?PRIVATE KEY-----'),re.compile(rb'"(?:private_jwk|privateKey|private_key|seed|access_token|refresh_token)"\s*:\s*(?:\{|"[^"\n]{16,}")',re.I)]
for path in ev.rglob('*'):
    if path.is_file() and path.suffix in ['.json','.log','.txt']:
        scan.append(str(path.relative_to(ev)))
        if any(pattern.search(path.read_bytes()) for pattern in patterns):candidates.append(str(path.relative_to(ev)))
assert not candidates,candidates
commands={}
for path in sorted((ev/'logs').glob('*.json')):commands[path.name]=json.loads(path.read_text())
record={'checkpoint':'QUO-65 observation1','worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f',
    'actual_api_model':'openai-codex:gpt-6.1-sol','launcher_requested_effort':'max','effective_backend_effort':'unexposed',
    'branch':subprocess.check_output(['git','branch','--show-current']).decode().strip(),
    'head':subprocess.check_output(['git','rev-parse','HEAD']).decode().strip(),
    'index_empty':not subprocess.check_output(['git','diff','--cached','--name-only']),
    'production_changes':0,'diagnostic_changed_inputs':1,'diagnostic_only':True,'distributable':False,
    'production_main_sha256':digest(production),'diagnostic_main_sha256':digest(diagnostic),
    'production_final03_inputs_unchanged':91,'production_final03_exports_unchanged':196,
    'diagnostic_supplied_inputs':91,'diagnostic_exports':196,'diagnostic_build_commands':3,
    'core189_reused_not_rerun':True,'server1432_and_m3b_gates_reused_not_rerun':True,
    'fixture_preparation':'Fresh account/backup calls accepted existing Accounts/Core module; helper provider build is separate from diagnostic input and no Core test entry point is run',
    'desktop_observations':1,'desktop_backup_import_checks':8,'marker_seen':True,'marker_count':1,
    'marker_client_log_line':61,'local_pass_client_log_line':58,'client_exit':0,'client_output_eof':True,
    'driver_exit':0,'driver_stderr_bytes':0,'wrapper_exit':0,'server_exit':0,'server_output_eof':True,
    'native_input_records':len(inputs),'native_owned_pids':sorted({row['owned_pid'] for row in inputs}),
    'watchdog_silence_seconds':60,'watchdog_fired':False,'native_stack_captured':False,
    'capture_prepared_not_exercised':{'only_owned_child':True,'timeout_seconds':15,'frame_arguments':False,
        'entry_values':False,'memory_dump':False,'user_init':False,'auto_load':False,'private_directory_mode':'0700','private_file_mode':'0600'},
    'driver_base_and_delta':'inputs/desktop-drivers/local-base.py and local-safety.patch',
    'stdout_and_stderr_streams':streams,'command_receipts':commands,
    'initial_free_disk_from_first_tool_read':3474042880,
    'historical_stalls_resolved':False,'historical_cause_inferred':False,'full_m4_accepted':False,
    'other_physics_or_soak_or_review':False,'committed':False,'tracker_mutated':False,
    'incoming_disposition':'A reporting gap remains; historical child-9/missing child traceback cannot rule out driver reader failure. B unproven; C/D no whole-shutdown proof from PASS/socket count; E rejected active-consumer cancellation-window claim. No app owner/order changes.',
    'inbox':{'method':'Full list-only','consume_available':False,'consumed':False,'receipt':'inputs/pre-freeze-inbox.json'},
    'public_content_audit':{'files':len(scan),'secret_candidates':candidates,'private_excluded':True},
    'implementation_idle_frozen':True,'owned_observation_complete':True,'no_interactive_prompt':True}
assert record['branch']=='worktree/pearl-stone' and record['head']=='293cf6115c0a6b18315eccdbb42cbca396f443d3' and record['index_empty']
(ev/'qualification.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'passed':True,'desktop_observations':1,'checks':8,'marker_count':1,'client_driver_wrapper_server_exits':[0,0,0,0],
    'client_and_server_eof':True,'watchdog':False,'capture':False,'production_changed':False,'original_stalls_resolved':False}))
