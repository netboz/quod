"""Verify saved source, process and resource evidence without another app run."""
import json, os, subprocess
from pathlib import Path
from hashes import TASK, Digests, raw, key
from instrument_close import instrument

os.umask(0o077)
root = Path.cwd()
ev = Path(__file__).resolve().parent
d = Digests()
def load(path): return json.loads(Path(path).read_text())
def bound(path, digest, size=None):
    assert d.h(path) == digest, str(path)
    if size is not None: assert Path(path).stat().st_size == size

product_path = root/'doc/evidence/godot-occurrence-visibility-20261102/inputs/client-visibility-product01-manifest.json'
bound(product_path, '40276e0371d70153f701eb15883e06c05ca97fe4ec21f78b4079cb79615b3bda')
product = load(product_path)
manifest = ev/'inputs/client-shutdown-observation02-manifest.json'
m = load(manifest)
bound(m['digest_cache']['path'], m['digest_cache']['sha256'])
for row in load(m['digest_cache']['path'])['records']:
    k = tuple(row['stat_key'])
    assert k not in d.values or d.values[k] == row['sha256']
    d.values[k] = row['sha256']
assert m['passed'] and not m['distributable'] and not m['trace_free']
assert m['live_source_inputs'] == product['live_source_inputs']
assert len(m['live_source_inputs']) == 98 and len(m['supplied_inputs']) == 100
assert len(m['export_outputs']) == 196 and not m['compiled_application_inputs_copied']
source = Path(m['stage'])/'source'
dist = Path(m['export_executable']).parent
for n, h in m['live_source_inputs'].items(): bound(root/n, h)
for n, h in m['supplied_inputs'].items(): bound(source/n, h)
for n, row in m['export_outputs'].items(): bound(dist/n, row['sha256'], row['bytes'])
assert (source/'client/godot/Main.cs').read_text() == instrument((root/'client/godot/Main.cs').read_text())
dispatch = 'if (phase is "m5-initial" or "m5-reopen") { await PackageJourney(phase=="m5-reopen"); return; }'
assert (source/'client/godot/tests/ExportChecks.cs').read_text() == (root/'client/godot/tests/ExportChecks.cs').read_text().replace('if (phase == "menu")', dispatch+'\n            if (phase == "menu")')
assert m['template'] == product['template'] and m['dependency_archives'] == product['dependency_archives']
bound(m['template']['path'], m['template']['sha256'])
for row in m['dependency_archives'].values(): bound(row['referenced_path'], row['sha256'], row['bytes'])
for name, row in load(ev/'inputs/origins.json').items():
    bound(root/row['path'], row['sha256'])
    bound(ev/'before'/name, row['sha256'])
for name in ['PackageJourneyChecks.cs', 'CloseTrace.cs', 'instrument_close.py', 'shutdown_capture.py', 'isolation.py']:
    assert (ev/name).read_bytes() == (ev/'before'/name).read_bytes()
assert len(m['commands']) == 5 and all(c['true_exit'] == 0 for c in m['commands'])
for c in m['commands']:
    assert load(ev/('shutdown-observation02-'+c['phase'])/'result.json')['exit'] == 0
assert load(ev/'logs/shutdown-observation01-build.json')['child_exit'] == 1
assert load(ev/'shutdown-observation01-export/result.json')['diagnostic_failure']
assert 'SocketException (13): Permission denied' in (ev/'shutdown-observation01-export/output.log').read_text()
format_check = load(ev/'inputs/native-status-format01.json')
assert format_check['wrapper_exit'] == 7
assert [r['exit-code'] for r in map(json.loads, format_check['status'].splitlines()) if 'exit-code' in r] == [7]

private = TASK/'private/shutdown-observation02'
j = load(ev/'inputs/shutdown-observation02.json')
jr = load(private/'result.raw.json')
assert j['passed'] and jr['passed'] and j['manifest_sha256'] == d.h(manifest)
assert all(c['true_exit'] == 0 for c in j['children'].values())
assert len(j['eof']) == 6 and all(j['eof'].values()) and not j['reader_errors']
assert j['native_input_count'] == 0 and not j['host_input_or_focus_action']
assert not any(k in j for k in ['failure', 'post_completion_trigger', 'lifetime_observation', 'unretired_failure', 'cleanup_timeout'])
assert not list(private.glob('*stacks*'))
closes, states, native = {}, {}, {}
for phase, count in [('initial', 93), ('reopen', 68)]:
    name = 'client-'+phase
    child = j['children'][name]
    report = load(private/'sandbox/work'/(phase+'.json'))
    lines = (private/(name+'-stdout.raw')).read_text().splitlines()
    assert report['passed'] and len(report['checks']) == count
    assert [l[5:] for l in lines if l.startswith('PASS ')] == report['checks'] == child['checks']
    assert child['explicit_completion'] and sum(l.startswith('M5_PACKAGE_JOURNEY_PASS') for l in lines) == 1
    state = json.loads([l[len('M1B_STATE '):] for l in lines if l.startswith('M1B_STATE ')][-1])
    metrics = state['controller_metrics']
    assert state['scene_count'] == state['live_sockets'] == 0 and not metrics['Running']
    assert all(metrics[k] == 0 for k in ['Subscriptions', 'sources', 'appearances', 'captures'])
    assert metrics['resources']['LiveTemplates'] == metrics['resources']['LiveLeases'] == 0
    states[phase] = {'scenes': 0, 'sockets': 0, 'subscriptions': 0, 'sources': 0, 'appearances': 0, 'captures': 0, 'templates': 0, 'leases': 0, 'XR': False}
    stages = child['close_stages']
    assert len(stages) == 26 and stages[0]['stage'] == 'close.enter' and stages[-1]['stage'] == 'tree.exit.returned'
    assert all(s['thread'] == 1 and s['context'] == 'Godot.GodotSynchronizationContext' for s in stages)
    assert all(s['status'] == 'RanToCompletion' for s in stages if s['status'] is not None)
    assert all(a['monotonic'] <= b['monotonic'] for a, b in zip(stages, stages[1:]))
    assert [json.loads(l[len('CLOSE_OWNER '):]) for l in (private/(name+'-stderr.raw')).read_text().splitlines() if l.startswith('CLOSE_OWNER ')] == stages
    closes[phase] = {'stages': stages, 'close_to_ExitTree_seconds': (stages[-1]['monotonic']-stages[0]['monotonic'])/stages[0]['frequency'], 'native_exit_latency_measured': False}
    owner = jr['children'][name]
    binding = load(private/(name+'-engine-binding.json'))
    assert binding['incarnation'] == owner['owner_incarnation'] and binding['pid'] == owner['engine_pid']
    assert owner['engine_pid'] != owner['wrapper_pid'] and len(binding['main_mappings']) == 1
    assert binding['main_mappings'][0]['stat_key'][:2] == list(key(dist/'quod.x86_64'))[:2]
    assert child['engine_pidfd_exited']
    assert child['native_status'][0]['child-pid'] == owner['engine_pid']
    assert [r['exit-code'] for r in child['native_status'] if 'exit-code' in r] == [0]
    native[phase] = {'direct_engine_exit': 0, 'wrapper_exit': 0, 'pidfd_exited': True, 'both_EOF': True, 'identity_binding_sha256': d.h(private/(name+'-engine-binding.json'))}
    assert load(private/'sandbox/work'/(phase+'-unchanged-work.json'))['work']['calls'] == []
outcome = load(private/'sandbox/work/recovered-outcome.json')
assert all(outcome[k] for k in ['exact_operation', 'exact_request', 'committed', 'same_bindings']) and outcome['matching_outcomes'] == 1
for row in j['streams'].values(): bound(row['path'], row['sha256'], row['bytes'])
server = load(ev/'inputs/server-shutdown-observation02-server.json')
assert server['child_exit'] == 0 and not server['runtime_recompiled'] and len(server['executed_current_sources']) == 14
for n, row in server['executed_current_sources'].items():
    bound(root/n, row['sha256']); bound(row['saved_source'], row['sha256'])
    if 'compiled_object' in row:
        obj = row['compiled_object']; bound(obj['path'], obj['sha256'], obj['bytes'])
for n, row in server['affected_compiled_outputs'].items(): bound(TASK/'private/quod-m4-live-shutdown-observation02-server'/n, row['sha256'], row['bytes'])
wrappers = {label: load(ev/'logs'/(label+'.json')) for label in ['shutdown-observation02-build', 'shutdown-observation02']}
assert all(r['child_exit'] == 0 and not r['timed_out'] for r in wrappers.values())
for r in wrappers.values():
    for row in r['private_streams'].values(): bound(row['path'], row['sha256'], row['bytes'])
assert wrappers['shutdown-observation02']['elapsed_seconds'] < 300
assert subprocess.check_output(['git', 'diff', '--binary', 'HEAD']) == (ev/'inputs/baseline-tracked.patch').read_bytes()
assert not subprocess.check_output(['git', 'diff', '--cached', '--name-only'])
result = {'evidence_verified': True, 'diagnostic_passed': True, 'shutdown_fixed': False, 'cause_established': False,
          'checkpoint_complete': False, 'production_line_delta': {'added': 0, 'removed': 0},
          'checks': {'initial': 93, 'reopen': 68}, 'direct_children': native, 'server_exit': 0, 'outer_exit': 0,
          'EOF': j['eof'], 'reader_errors': j['reader_errors'], 'close_observations': closes, 'terminal_resources': states,
          'same_profile_original_outcome': outcome, 'unchanged_named_work_calls': [],
          'product_manifest_sha256': d.h(product_path), 'diagnostic_manifest_sha256': d.h(manifest),
          'production_inputs': 98, 'supplied_inputs': 100, 'exports': 196, 'server_current_sources': 14,
          'elapsed_seconds': wrappers['shutdown-observation02']['elapsed_seconds'],
          'bounds_seconds': {'phase': 180, 'post_completion': 60, 'outer': 300, 'cleanup': 60, 'kill_wait': 10, 'failure_capture': 15},
          'native_capture_executed': False, 'full_M4_M5_or_hardware_acceptance': False,
          'retained_new_failure': 'shutdown-observation01-build: local socket permission denied, child/wrapper 1',
          'remaining_causal_gap': 'No original failure cutoff occurred. The responsible managed/native/writer lifetime is unobserved during failure; successful current exits do not establish or fix the historical intermittent cause.'}
(ev/'result.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps({k: result[k] for k in ['evidence_verified', 'diagnostic_passed', 'shutdown_fixed', 'checkpoint_complete', 'checks', 'direct_children']}))
