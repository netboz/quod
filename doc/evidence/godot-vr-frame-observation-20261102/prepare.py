"""Bind the new offline-built observer without launching or probing anything."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
from hashes import Digests, TASK, key, raw

os.umask(0o077)
root = Path.cwd()
ev = Path(__file__).resolve().parent
old = ev.parent / 'godot-attention-vr-preparation-20261102'
digest = Digests()


def saved(path, expected=None, known=False):
    path = Path(path)
    before = key(path)
    if known:
        assert before in digest.values and digest.values[before] == expected, str(path)
        actual = expected
    else:
        actual = digest.h(path)
        if expected is not None:
            assert actual == expected, str(path)
    return {'path': str(path), 'sha256': actual, 'stat_key': before,
            'mode': path.stat().st_mode, 'payload_reread': not known}


parent_path = old / 'artifacts-ready280.json'
saved(parent_path, 'f6f488a06f9c08fdd7c41e3695373fff865c79e3cce6548d93facc1a19d207a4')
parent = json.loads(parent_path.read_text())
manifest_path = ev / 'inputs/client-attention-vr-frame-companion01-manifest.json'
manifest = json.loads(manifest_path.read_text())
assert manifest['passed'] and not manifest['trace_free'] and not manifest['distributable']
assert manifest['compiled_application_inputs_copied'] is False
cache = manifest['digest_cache']
assert raw(cache['path']) == cache['sha256']
for row in json.loads(Path(cache['path']).read_text())['records']:
    k, sha = tuple(row['stat_key']), row['sha256']
    assert k not in digest.values or digest.values[k] == sha
    digest.values[k] = sha
product_path = root / 'doc/evidence/godot-attention-review-20261102/inputs/client-attention-review-product01-manifest.json'
saved(product_path, 'dce5fe3f690dec8e3b7fd54b2e8da622efaa5e61ff65c4330b09cb21833f05bf')
product = json.loads(product_path.read_text())
assert manifest['live_source_inputs'] == product['live_source_inputs']
assert len(manifest['live_source_inputs']) == 98 and len(manifest['supplied_inputs']) == 100
assert len(manifest['export_outputs']) == 196
assert manifest['template'] == product['template']
assert manifest['dependency_archives'] == product['dependency_archives']
assert len(manifest['commands']) == 5 and all(r['true_exit'] == 0 for r in manifest['commands'])
expected_overrides = {'client/godot/tests/ExportChecks.cs',
    'client/godot/tests/VrFrameReady.cs', 'client/godot/tests/FrameObservation.cs'}
assert set(manifest['diagnostic_overrides']) == expected_overrides
stage = Path(manifest['stage']) / 'source'
dispatch = 'if (phase == "vr-ready263") { await VrFrameReady(); return; }\n            '
base = 'client/godot/tests/ExportChecks.cs'
assert (stage / base).read_text().count(dispatch) == 1
assert (stage / base).read_text().replace(dispatch, '', 1) == (root / base).read_text()
live = {n: saved(root / n, sha, True) for n, sha in manifest['live_source_inputs'].items()}
supplied = {n: saved(stage / n, sha, True) for n, sha in manifest['supplied_inputs'].items()}
exports = {n: saved(Path(manifest['export_executable']).parent / n, r['sha256'], True)
           for n, r in manifest['export_outputs'].items()}
dependencies = {n: saved(r['referenced_path'], r['sha256'], True)
                for n, r in manifest['dependency_archives'].items()}
engine = saved(manifest['template']['path'], manifest['template']['sha256'], True)


def receipt(label, expected_exit):
    path = ev / 'logs' / (label + '.json')
    record = json.loads(path.read_text())
    assert record['child_exit'] == expected_exit and not record['timed_out']
    for group in ['private_streams', 'sanitized_streams']:
        for row in record[group].values():
            p = Path(row['path'])
            saved(p, row['sha256'])
            if group == 'private_streams':
                assert stat.S_IMODE(p.stat().st_mode) == 0o600
                assert stat.S_IMODE(p.parent.stat().st_mode) == 0o700
    return {'receipt': saved(path), 'true_child_exit': expected_exit,
            'timed_out': False}, record


failure, failed_record = receipt('frame-observation-offline01', 1)
offline, offline_record = receipt('frame-observation-offline02', 0)
build, build_record = receipt('attention-vr-frame-companion01-build', 0)
for name in ['FrameObservation.cs', 'FrameObservationChecks.cs', 'VrFrameReady.cs', 'offline_checks.py']:
    assert raw(ev / name) == offline_record['driver_inputs'][name]
for name in ['FrameObservation.cs', 'VrFrameReady.cs', 'build.py', 'hashes.py']:
    assert raw(ev / name) == build_record['driver_inputs'][name]
log = Path(offline_record['sanitized_streams']['stdout']['path']).read_text()
checks = json.loads(next(s[len('FRAME_OBSERVATION_PASS '):] for s in log.splitlines()
                        if s.startswith('FRAME_OBSERVATION_PASS ')))
assert checks['checks'] == 20 and checks['synthetic'] and not checks['native_runtime_started']
integration = json.loads(next(s[len('FRAME_OFFLINE_COMPLETE '):] for s in log.splitlines()
                             if s.startswith('FRAME_OFFLINE_COMPLETE ')))
assert integration['source_checks'] == 11

owners = {}
for name in ['live.py', 'supervision.py', 'owned_commands.py', 'pipe_ownership.py',
             'launch_spec.py', 'serve.py', 'manual_run.py', 'godot_m3b_fixture.erl']:
    row = parent['driver_inputs'][name]
    owners[name] = {where: saved(r['path'], r['sha256'], True)
                   for where, r in row.items()}
server = {name: saved(row['path'], row['sha256'], True)
          for name, row in parent['fixture']['current_sources'].items()}
assert len(server) == 14
objects = {name: saved(row['path'], row['sha256'], True)
           for name, row in parent['fixture']['qualified_objects'].items()}
archive_row = parent['accepted_package']['archive']
archive = saved(archive_row['path'], archive_row['sha256'], True)
contract = json.loads((ev / 'future-stop-contract.json').read_text())
assert contract['sequence'][1]['stdin'].encode() == bytes.fromhex('73746f700a')
assert contract['sequence'][0]['stdin'].encode() == bytes.fromhex('66696e6973680a')
assert not contract['launch_authorized']
closure = saved(old / 'closure280.json',
    'd10d988cb0bbf454aabff0150cb957b2755980a437b399f63de8513bb41262dc')
private = TASK / 'private/frame-observation-preparation01'
private.mkdir(mode=0o700, exist_ok=False)
copies = private / 'inputs'
copies.mkdir(mode=0o700)
drivers = {}
for source in sorted(ev.iterdir()):
    if source.suffix in ['.py', '.cs'] or source.name == 'future-stop-contract.json':
        target = copies / source.name
        shutil.copy2(source, target)
        assert raw(target) == raw(source)
        drivers[source.name] = {'source': saved(source), 'copy': saved(target)}
manifest_binding = saved(manifest_path)
stop_binding = saved(ev / 'future-stop-contract.json')
cache_path = TASK / 'cache/frame-observation-preparation01-hashes.json'
digest.write(cache_path)
result = {
    'state': 'DIAGNOSTIC_ARTIFACTS_PREPARED', 'passed': True,
    'label': 'attention-vr-frame-companion01', 'launch_authorized': False,
    'writer': 'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f',
    'existing_task': 'QUO-65', 'production_changes': 0,
    'app_fixture_runtime_or_hardware_started': False,
    'companion_manifest': manifest_binding,
    'executable': manifest['export_executable'],
    'production_inputs': 98, 'supplied_inputs': 100, 'exports': 196,
    'export_bytes': sum(r['bytes'] for r in manifest['export_outputs'].values()),
    'compiled_application_inputs_copied': False, 'distributable': False,
    'diagnostic_overrides': manifest['diagnostic_overrides'],
    'live_bindings': live, 'supplied_bindings': supplied, 'export_bindings': exports,
    'dependencies': dependencies, 'engine': engine,
    'offline_checks': {'receipt': offline, 'accumulator_checks': 20, 'source_checks': 11,
                       'synthetic_samples_only': True},
    'build': {'receipt': build, 'five_phases_exit0': True, 'outer_exit0': True,
              'headless_export_only': True},
    'retained_failure': {'receipt': failure, 'cause': 'empty offline dependency feed; NU1100 before accumulator execution'},
    'accepted279_archive': archive, 'failed280_closure_unchanged': closure,
    'unchanged_supervision_owners': owners,
    'reused_guard_receipts': parent['reused_gates'],
    'reused_owned_command_checks': parent['gates']['attention-vr-owned-guards01'],
    'server_sources': server, 'qualified_objects': objects,
    'fixture_launch_performed': False,
    'original_bounds_seconds': parent['original_bounds_seconds'],
    'auth': 'Existing absolute expiry remains an earlier cutoff; no renewal or replay',
    'stop_contract': stop_binding,
    'observation': {
        'owner': 'Existing Godot FramePostDraw callback after StartXR returns',
        'emission': 'Existing FIRST_XR_FRAME, READY, BLOCKER and requested/status snapshots; no periodic report or timer added',
        'counts': ['callback count', 'first/last/increasing/equal/decreasing predicted display times',
                   'positive/zero/negative predicted-time samples', 'CanRender true/false',
                   'sampled session-state transitions and omitted transitions'],
        'state_transition_limit': 64,
        'timing': 'First/last callback and retained state transitions have elapsed Stopwatch ticks plus frequency',
        'bounded_storage': 'Counters plus at most64 transition records; no per-frame list or payload retention',
        'rendered_frame_counter': 'Existing compound xr_frames remains separate and unchanged',
        'direct_native_frame_calls': 'unobserved', 'direct_shouldRender': 'unobserved',
        'sampled_state_limit': 'States between FramePostDraw callbacks may be missed; recording begins after StartXR returns',
        'native_validation': 'UNRUN; this build and synthetic checks do not demonstrate future runtime callbacks or headset pixels'
    },
    'next_action': 'Stop after preparation. A new separately authorized opportunity is required to run this companion; never reuse280 labels or targets.',
    'private_inputs': drivers,
    'digest_cache': {'path': str(cache_path), 'sha256': raw(cache_path),
                     'records': len(digest.values), 'pathless_preserved': True},
    'limits': ['No new application, signed fixture, native XR, SteamVR, display, focus, host input or hardware probe.',
               'No product/package/engine/policy/readiness/deadline/close-order change.',
               'The new diagnostic has two removable C# sources; this is100 supplied inputs, not the old99.',
               'Historical failures and unknown runtime/wearing causes remain literal.']
}
output = ev / 'artifacts-ready-frame-observation01.json'
assert not output.exists()
output.write_text(json.dumps(result, indent=2) + '\n')
(private / output.name).write_bytes(output.read_bytes())
print(json.dumps({'DIAGNOSTIC_ARTIFACTS_PREPARED': True, 'receipt': str(output),
    'sha256': raw(output), 'production_inputs': 98, 'supplied_inputs': 100,
    'exports': 196, 'export_bytes': result['export_bytes'], 'launch_authorized': False}))
