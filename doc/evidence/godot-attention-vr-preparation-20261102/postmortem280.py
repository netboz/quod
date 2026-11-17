"""Bounded offline analysis of the closed attention280 invocation; no probes."""
import hashlib
import json
import os
from pathlib import Path

E = Path(__file__).resolve().parent
P = Path('/data/quod-m4-vr-ca84d4f8-20261029/private/attention280-human01')
ROOT = E.parents[2]
inputs = {}


def read(path, expected=None):
    path = Path(path)
    before = path.stat()
    raw = path.read_bytes()
    after = path.stat()
    key = lambda s: [s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns]
    assert key(before) == key(after), str(path)
    digest = hashlib.sha256(raw).hexdigest()
    if expected is not None:
        assert digest == expected, str(path)
    inputs[str(path)] = {'sha256': digest, 'bytes': len(raw), 'mode': after.st_mode,
                         'stat_key': key(after)}
    return raw


closure = json.loads(read(E / 'closure280.json',
    'd10d988cb0bbf454aabff0150cb957b2755980a437b399f63de8513bb41262dc'))
bound = {}
for name, entry in {**closure['receipts'], **closure['raw'],
                    'server_raw': closure['server_raw']}.items():
    path = Path(entry['path'])
    if not path.is_absolute():
        path = ROOT / path
    raw = read(path, entry['sha256'])
    assert len(raw) == entry['bytes']
    assert inputs[str(path)]['mode'] == entry['mode']
    assert inputs[str(path)]['stat_key'] == entry['stat_key']
    bound[name] = raw

invocation = json.loads(bound['invocation'])
stdout = bound['stdout'].decode().splitlines()
stderr = bound['stderr'].decode().splitlines()
server = bound['server_raw'].decode().splitlines()
godot = read(P / 'data/godot/app_userdata/Quod/logs/godot.log').decode().splitlines()
observer = read(P / 'drivers/VrReady280.cs',
    '9ea98c4911a1aafddc29909d002ca5f25c732b72cffbe9289361c120be1e2095').decode()
fixture = read(P / 'drivers/godot_m3b_fixture.erl',
    'bdb10e1a18d12574a7a2a491e46b84e21c436b636adaed0cebb4adbb89c84a69').decode()
commands = read(P / 'drivers/owned_commands.py',
    '60c693b94cc8113263f0238f47337430a18108ac544132bfff8ed3f5ef8aa6a0').decode()
read(P / 'drivers/live.py',
    'ecfd79218e8e14a5eb224c304a031cefefa802d365b193a145823bedb5f313ee')
contract = json.loads(read(E / 'future-stop-contract-after280.json'))

assert contract['launch_authorized'] is False
client_stop, fixture_stop = contract['sequence']
assert client_stop['stdin'] == 'finish\n'
assert fixture_stop['stdin'] == 'stop\n'
for step in contract['sequence']:
    assert step['stdin'].encode().hex() == step['utf8_hex']
    assert step['maximum_writes'] == 1
assert "self.child.stdin.write(b'finish\\n')" in commands
assert '"stop\\n" -> ok;' in fixture
assert 'case json:decode(list_to_binary(Line)) of' in fixture
assert any('unexpected_end' in line for line in server)
assert closure['fixture_stop']['operator_error'] is True
assert closure['actual_children'] == {'client': 1, 'fixture': 1}
assert all(closure['EOF'].values())
assert not any(closure['reader_errors'].values())
assert closure['ready'] is False and closure['participant_started'] is False

markers = {}
for number, line in enumerate(stdout, 1):
    if line.startswith('VR263_'):
        name, payload = line.split(' ', 1)
        markers.setdefault(name, []).append({'line': number, 'value': json.loads(payload)})
blockers = markers['VR263_BLOCKER']
assert len(blockers) == 1
blocker = blockers[0]['value']
assert blocker == closure['native_blocker'] == invocation['VR263_BLOCKER']
assert not any(name in markers for name in ('VR263_READY', 'VR263_FIRST_XR_FRAME', 'VR263_STATE'))
assert 'previous=now;if(frame)rendered++;' in observer
assert 'api.CanRender()' in observer and 'now>previous' in observer
assert invocation['runtime_helper_observations'] == []
assert invocation['launch_environment_after']['QT_QPA_PLATFORM'] == 'xcb'


def selected(lines, predicate):
    return [{'line': i, 'text': line} for i, line in enumerate(lines, 1) if predicate(line)]


native_lines = selected(stdout, lambda s: s.startswith('OpenXR EVENT: session state changed')
    or s == 'OpenXR: No viewport was marked with use_xr, there is no rendered output!')
godot_lines = selected(godot, lambda s: s.startswith('OpenXR EVENT: session state changed')
    or s == 'OpenXR: No viewport was marked with use_xr, there is no rendered output!')
non_payload = [s for s in stdout + stderr + godot
               if not s.startswith(('AUTHORED_', 'M1B_', 'VR263_', '{'))]
standby = selected(non_payload, lambda s: 'standby' in s.lower())
frame_calls = selected(non_payload, lambda s: any(k in s for k in
    ('xrWaitFrame', 'xrBeginFrame', 'xrEndFrame', 'shouldRender')))
qt_errors = selected(non_payload, lambda s:
    'qt.qpa' in s.lower() or 'qt platform plugin' in s.lower())
assert standby == [] and frame_calls == [] and qt_errors == []
predicted = [row['value']['predicted_time'] for rows in markers.values()
             for row in rows if 'predicted_time' in row['value']]
assert predicted == [260162122767215]

result = {
    'scope': 'attention280-human01 saved receipts only; offline post-mortem',
    'analysis_complete': True,
    'opportunity_passed': False,
    'original_closure_unchanged': True,
    'new_runtime_or_fixture_invocations': 0,
    'host_or_hardware_queries': 0,
    'original_exits': closure['actual_children'],
    'original_wrapper_exits': closure['actual_tool_wrapper_exits'],
    'original_EOF': closure['EOF'],
    'owned_absence': 'Previously verified in closure280; no new process/container query',
    'participant_started': False,
    'prepared_to_begin_seconds': closure['begin_delay_from_prepared_seconds'],
    'original_remaining_preparation_at_begin': closure['remaining_preparation_at_begin'],
    'native_blocker_line': blockers[0]['line'],
    'native_observations': {
        'session_state': blocker['session_state'], 'can_render': blocker['can_render'],
        'compound_xr_frames': blocker['xr_frames'], 'primary': blocker['primary'],
        'action_set_active': blocker['action_set_active'], 'use_xr': blocker['use_xr'],
        'update_mode': blocker['viewport_update'], 'stereo_views': blocker['stereo_views'],
        'draw_count': blocker['draws'], 'predicted_time_samples': predicted,
        'presence_supported': blocker['presence_supported'], 'presence': blocker['presence'],
        'controller_sources': blocker['sources'],
        'router_has_supported_bindings': False,
        'signed_world': blocker['signed_world'], 'operation_available': blocker['operation_available'],
        'question_receiver_ready': blocker['question_receiver_ready'],
        'remaining_auth_ms': blocker['remaining_auth_ms'], 'captures': blocker['captures'],
        'model_resources': blocker['metrics']['resources']
    },
    'native_log_evidence': {'stdout': native_lines, 'godot_log': godot_lines},
    'standby': {
        'status': 'unestablished in the inspected invocation receipts',
        'matching_lines': standby,
        'limit': 'Synchronized, headHigh and the earlier availability statement are not standby/presence evidence. No separate SteamVR server/monitor interval log is identified in these retained inputs.'
    },
    'frame_pump': {
        'can_render_false': True, 'direct_shouldRender_sample': None,
        'native_frame_call_counts': None, 'predicted_time_progression': 'unestablished: one sample',
        'limit': 'The saved compound counter requires CanRender plus the other predicates and is not an xrWait/Begin/End counter. The single no-use_xr log warning does not establish a sustained defect; the blocker has UseXR true. Native and managed stdout blocks are buffered, not a common timestamped timeline.'
    },
    'qt_monitor': {
        'process_qt_platform': 'xcb', 'matched_helper_observations': [],
        'platform_error_lines_in_inspected_logs': qt_errors,
        'startup': 'unverified',
        'limit': 'The launch override and absence of a platform error do not prove that a new Qt monitor started. Preflight records an already-existing user-owned vrmonitor, not a newly owned helper.'
    },
    'additional_stderr': selected(stderr, lambda s: s.startswith('Error [GENERAL | xrCreateInstance')
        or s.startswith('System.TimeoutException:') or s.startswith('   at ExportChecks.')),
    'additional_stderr_limit': 'Initial xrCreateInstance errors coexist with later successful runtime initialization and a running session. Their causal role in admission failure is unestablished.',
    'controller_limit': 'Both native profiles are none and both trackers unsupported/untracked at the cutoff. This does not establish controller power, wearing, pairing failure or why SteamVR withheld profiles.',
    'fixture': {
        'classification': 'separate operator blank-line stop error',
        'sent_utf8_hex': '0a', 'required_utf8_hex': '73746f700a',
        'required_stdin': 'stop\n', 'writes': 1, 'replayed': False,
        'error_lines': selected(server, lambda s: 'unexpected_end' in s or 'commands,0' in s),
        'future_contract': str(E / 'future-stop-contract-after280.json'),
        'validation': 'Documented bytes match saved existing owners; no actual stop or runtime regression was executed'
    },
    'limits': [
        'No wearing, visible headset pixels, rendered stereo or human task success was established.',
        'No runtime/application root cause, Qt fix, hardware diagnosis or historical shutdown fix is claimed.',
        'The native blocker and separate nonzero fixture result remain literal.',
        'No same-attempt retry or new opportunity is authorized by this report.'
    ],
    'inputs': inputs
}
out = E / 'postmortem280.json'
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as stream:
    json.dump(result, stream, indent=2)
    stream.write('\n')
print(json.dumps({'OFFLINE_POSTMORTEM_COMPLETE': True, 'output': str(out),
    'sha256': hashlib.sha256(out.read_bytes()).hexdigest(), 'original_opportunity_passed': False,
    'new_runtime_invocations': 0, 'fixture_stop_utf8_hex': fixture_stop['utf8_hex']}))
