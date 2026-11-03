"""Bind the offline visual-only admission companion; this never launches it."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import shlex
import stat
from hashes import Digests, TASK, key, raw

os.umask(0o077)
root=Path.cwd(); ev=Path(__file__).resolve().parent
frame=ev.parent/'godot-vr-frame-observation-20261102'
old=ev.parent/'godot-attention-vr-preparation-20261102'
d=Digests()

def saved(path, expected=None, known=False):
    path=Path(path);k=key(path)
    if known:
        assert k in d.values and d.values[k]==expected,str(path)
        sha=expected
    else:
        sha=d.h(path)
        if expected is not None:assert sha==expected,str(path)
    return {'path':str(path),'sha256':sha,'stat_key':k,'mode':path.stat().st_mode,
            'payload_reread':not known}

parent_path=frame/'artifacts-ready-frame-observation01.json'
saved(parent_path,'59593a19b053a4d757911adc4d7afe7c891e86aef160baa66ea1ae0bbaae19fb')
parent=json.loads(parent_path.read_text())
manifest_path=ev/'inputs/client-attention-vr-visual-companion01-manifest.json'
m=json.loads(manifest_path.read_text());cache=m['digest_cache']
assert raw(cache['path'])==cache['sha256']
for row in json.loads(Path(cache['path']).read_text())['records']:
    k=tuple(row['stat_key']);sha=row['sha256']
    assert k not in d.values or d.values[k]==sha
    d.values[k]=sha
product_path=root/'doc/evidence/godot-attention-review-20261102/inputs/client-attention-review-product01-manifest.json'
saved(product_path,'dce5fe3f690dec8e3b7fd54b2e8da622efaa5e61ff65c4330b09cb21833f05bf')
product=json.loads(product_path.read_text())
assert m['passed'] and not m['trace_free'] and not m['distributable'] and not m['compiled_application_inputs_copied']
assert m['live_source_inputs']==product['live_source_inputs'] and len(m['live_source_inputs'])==98
assert len(m['supplied_inputs'])==100 and len(m['export_outputs'])==196
assert m['dependency_archives']==product['dependency_archives'] and m['template']==product['template']
assert len(m['commands'])==5 and all(x['true_exit']==0 for x in m['commands'])
stage=Path(m['stage'])/'source'
live={n:saved(root/n,sha,True) for n,sha in m['live_source_inputs'].items()}
supplied={n:saved(stage/n,sha,True) for n,sha in m['supplied_inputs'].items()}
exports={n:saved(Path(m['export_executable']).parent/n,r['sha256'],True) for n,r in m['export_outputs'].items()}
dependencies={n:saved(r['referenced_path'],r['sha256'],True) for n,r in m['dependency_archives'].items()}
dispatch='if (phase == "vr-ready263") { await VrFrameReady(); return; }\n            '
base='client/godot/tests/ExportChecks.cs'
assert (stage/base).read_text().replace(dispatch,'',1)==(root/base).read_text()
assert set(m['diagnostic_overrides'])=={base,'client/godot/tests/VrFrameReady.cs','client/godot/tests/FrameObservation.cs'}

def receipt(path):
    r=json.loads(path.read_text());assert r['child_exit']==0 and not r.get('timed_out')
    for group in ['private_streams','sanitized_streams','streams']:
        for row in r.get(group,{}).values():
            saved(row['path'],row['sha256'])
            if group!='sanitized_streams':
                assert stat.S_IMODE(Path(row['path']).stat().st_mode)==0o600
                assert stat.S_IMODE(Path(row['path']).parent.stat().st_mode)==0o700
    return r

offline_path=ev/'logs/visual-readiness-offline01.json';offline=receipt(offline_path)
build_path=ev/'logs/attention-vr-visual-companion01-build.json';build=receipt(build_path)
stop_path=old/'logs/visual-stop-transport01.json';stop=receipt(stop_path)
assert stop['eof']=={'stdout':True,'stderr':True} and stop['reader_errors']==[]
for n in ['FrameObservation.cs','VrFrameReady.cs','live.py','supervision.py','owned_commands.py','pipe_ownership.py','launch_spec.py','FrameObservationChecks.cs','test_supervision.py','test_owned_commands.py','test_launch_spec.py','offline_checks.py','harmless_stop.py']:
    assert raw(ev/n)==offline['driver_inputs'][n],n
for n in ['FrameObservation.cs','VrFrameReady.cs','build.py','hashes.py']:
    assert raw(ev/n)==build['driver_inputs'][n],n
assert raw(ev/'harmless_stop.py')==offline['driver_inputs']['harmless_stop.py']
log=Path(offline['sanitized_streams']['stdout']['path']).read_text()
def marker(prefix):return json.loads(next(s[len(prefix):] for s in log.splitlines() if s.startswith(prefix)))
counts={'accumulator':marker('FRAME_OBSERVATION_PASS ')['checks'],
        'supervision':marker('SUPERVISION_PASS ')['checks'],
        'owned_commands':marker('OWNED_COMMANDS_PASS ')['checks'],
        'literal_arguments':marker('LAUNCH_SPEC_PASS ')['checks'],
        'source_parser':marker('VISUAL_OFFLINE_COMPLETE ')['source_checks']}
assert counts=={'accumulator':34,'supervision':33,'owned_commands':27,'literal_arguments':8,'source_parser':18}
stop_log=Path(stop['streams']['stdout']['path']).read_text()
assert '"stdin_hex": "73746f700a"' in stop_log and '"stdin_is_tty": true' in stop_log
sources={n:saved(r['path'],r['sha256'],True) for n,r in parent['server_sources'].items()}
assert len(sources)==14
objects={n:saved(r['path'],r['sha256'],True) for n,r in parent['qualified_objects'].items()}
reused={}
for n in ['serve.py','manual_run.py','godot_m3b_fixture.erl']:
    row=parent['unchanged_supervision_owners'][n]['source']
    reused[n]=saved(row['path'],row['sha256'],True)
archive=parent['accepted279_archive'];archive=saved(archive['path'],archive['sha256'],True)
closure=saved(frame/'closure281.json','7f2138a4473e38205d8c33a7b5f246a7667f83b7e504e2d3db8edc327d108963')
inv=json.loads((TASK/'private/attention281-human01/invocation.json').read_text())
timing={'coordinator_delay_seconds':248,'coordinator_delay_source':'Root/user-reported measured interval; not independently rederived from private conversation history',
        'app_preparation_seconds':inv['prepared_reported_monotonic']-inv['started_monotonic'],
        'local_begin_after_prepared_seconds':inv['begin_sent_monotonic']-inv['prepared_reported_monotonic'],
        'old_native_controller_gate_seconds':30,'old_result':inv['failure'],
        'new_controller_wait_for_visual':False}
card_path=ev/'run-card.json';card=json.loads(card_path.read_text())
assert card['fixture']['tty'] and card['client']['tty'] and not card['launch_authorized']
assert not (TASK/'private'/card['future_label']).exists()
assert not (TASK/'private'/('quod-m4-live-'+card['future_label']+'-server')).exists()
assert not (TASK/'private/runs/attention-visual-fixture-wrapper01').exists()
card['companion_manifest']=saved(manifest_path)
card['product_manifest']=saved(product_path)
card['observer_inputs']={n:saved(ev/n) for n in ['VrFrameReady.cs','FrameObservation.cs','live.py','supervision.py','owned_commands.py','pipe_ownership.py','launch_spec.py']}
card['fixture_owners']=reused
card['current_server_sources']=sources
card['timing281']=timing
card_path.write_text(json.dumps(card,indent=2)+'\n')
card_md=ev/'run-card.md'
card_md.write_text('''# Prepared direct visual-test launch card

OFFLINE ONLY. Root must verify this artifact and separately authorize one future launch. No app/fixture/XR session is running. Do not ask Yan to wear the headset during preparation: invite him only after actual VISUAL_READY. There is no AI preflight/build/audit at test time; the existing owners still perform exact mapped-incarnation, expiry and source checks as part of launch.

From `/home/yan/src/quod_worktrees/pearl-stone`, run the following with **tty:true**, then wait only for this fixture's actual M1B_READY:

```sh
'''+shlex.join(card['fixture']['argv'])+'''
```

Immediately run the client with **tty:true**. Its existing local owner sends one delegated begin after the exact mapped PREPARED state; no second coordinator round trip:

```sh
'''+shlex.join(card['client']['argv'])+'''
```

The fresh labels are reserved for one future opportunity only. If they already exist, stop rather than reusing a profile or replaying work. No old PTY/PID is a target.

**VISUAL_READY** is emitted on the first actual Focused/CanRender/advancing stereo callback with tracked head and currently accepted signed world/receiver, while authentication is unexpired. It immediately starts the visual participant interval. Invite Yan: “The visual scene is ready; you can put on the headset now. Look for Current space and the two Analyzer objects.” This is not a claim about headset pixels or interactive readiness. Report each controller's actual tracking/bindings. For any pointing or selection, use only a controller currently supported, tracked and admitted by the existing production input owner. The separate strict two-controller result is optional qualification, not a visual-test gate. When the corresponding input is admitted, the proposed user task is: choose an Analyzer, view its form near the object or in the personal workspace, then open an attention request and choose Later. Do not automate these actions or claim success without feedback.

The legacy VR263_READY remains a separate strict two-supported-controller result. It does not restart any deadline, and the visual path does not wait30 seconds for it. Missing controllers stay governed by production input fences. Temporary signed Updating remains locked and observable without closing a visually admitted session. The finite30-second failure bound is for failure to obtain a qualifying visual frame; preparation180, participant1800, close60, outer2100 and authentic earlier expiry remain absolute.

On explicit stop, expiry or failure: send client `finish\\n` once through its current exact-owned supervisor, await actual closure/EOF or retain the failure, then send fixture **`stop\\n` exactly once** (hex73746f700a). Never send an empty line, silently retry an uncertain write, signal a runtime helper or extend a deadline.

281 timing: coordinator-reported delay **4m8s** preceded app preparation. Saved app preparation was **'''+f"{timing['app_preparation_seconds']:.3f}"+'''s**, local begin followed PREPARED by **'''+f"{timing['local_begin_after_prepared_seconds']:.6f}"+'''s**, and the former native controller gate ended at30s. These are distinct intervals; the coordinator delay is not app startup latency. Failed281 remains unchanged, including native admission failure and incomplete client EOF.

Exact input hashes, current14-source server bindings and commands are in [run-card.json](run-card.json). Companion manifest SHA `'''+raw(manifest_path)+'''`; accepted product SHA `dce5fe3f690dec8e3b7fd54b2e8da622efaa5e61ff65c4330b09cb21833f05bf`. Per-process Qt=xcb and installed SteamVR selection preserve Godot Wayland/Vulkan/mobile and all global/user settings.
''')
private=TASK/'private/visual-readiness-preparation02';private.mkdir(mode=0o700,exist_ok=False)
copies=private/'inputs';copies.mkdir(mode=0o700)
drivers={}
for p in sorted(ev.iterdir()):
    if p.suffix in ['.py','.cs'] or p.name in ['run-card.json','run-card.md','future-stop-contract.json']:
        target=copies/p.name;shutil.copy2(p,target);assert raw(p)==raw(target)
        drivers[p.name]={'source':saved(p),'copy':saved(target)}
cache_path=TASK/'cache/visual-readiness-preparation02-hashes.json';d.write(cache_path)
result={'state':'ARTIFACTS_READY','passed':True,'launch_authorized':False,
        'writer':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','task':'QUO-65',
        'app_fixture_xr_hardware_started':False,'production_changes':0,'supersedes_metadata_only':'artifacts-ready-visual01.json: clarify that strict two-controller qualification is optional; the production owner governs each interactive action. No test/build rerun.',
        'manifest':saved(manifest_path),'executable':m['export_executable'],
        'production_inputs':98,'supplied_inputs':100,'exports':196,
        'export_bytes':sum(r['bytes'] for r in m['export_outputs'].values()),
        'live_bindings':live,'supplied_bindings':supplied,'export_bindings':exports,
        'dependency_bindings':dependencies,'accepted279_archive':archive,
        'server_sources':sources,'qualified_objects':objects,'fixture_owners':reused,
        'offline_checks':{'counts':counts,'receipt':saved(offline_path),'true_exit':0},
        'build':{'receipt':saved(build_path),'five_phases_exit0':True,'outer_exit':0},
        'stop_transport':{'receipt':saved(stop_path),'child_exit':0,'wrapper_exit':0,'both_eof':True,'tty':True,'input_hex':'73746f700a'},
        'closed281_unchanged':closure,'timing281':timing,'run_card':saved(card_path),
        'private_inputs':drivers,'digest_cache':{'path':str(cache_path),'sha256':raw(cache_path),'records':len(d.values),'pathless_preserved':True},
        'limits':['No native runtime/frame/pixel/human result from this preparation.',
                  'VISUAL_READY is visual admission only; no controller dispatch grant.',
                  'VR263_READY remains the unchanged strict interaction predicate; no controller wait delays visual admission.',
                  'Old failures, EOF limitations, profiles and accepted product/archive are unchanged.',
                  'No launch authority: stop for independent root verification.']}
out=ev/'artifacts-ready-visual02.json';assert not out.exists()
out.write_text(json.dumps(result,indent=2)+'\n');(private/out.name).write_bytes(out.read_bytes())
print('VISUAL_ARTIFACTS_PREPARED '+json.dumps({'receipt':str(out),'sha256':raw(out),'manifest_sha256':raw(manifest_path),'checks':counts,'launch_authorized':False}))
