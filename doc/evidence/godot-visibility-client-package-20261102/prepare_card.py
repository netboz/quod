"""Bind the current companion and unchanged launch owners without launching them."""
import json,os,shlex,stat,subprocess,sys
from pathlib import Path
from hashes import TASK,Digests,raw,key

os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent
visual=ev.parent/'godot-vr-visual-readiness-20261102'
old=ev.parent/'godot-attention-vr-preparation-20261102'
d=Digests()
def load(p):return json.loads(Path(p).read_text())
def cache(row):
    assert raw(row['path'])==row['sha256']
    for r in load(row['path'])['records']:
        k=tuple(r['stat_key']);assert k not in d.values or d.values[k]==r['sha256'];d.values[k]=r['sha256']
def bound(p,sha=None,known=False):
    p=Path(p);k=key(p)
    if known:assert k in d.values and (sha is None or d.values[k]==sha),str(p)
    h=d.h(p);assert sha is None or h==sha,str(p)
    return {'path':str(p),'sha256':h,'stat_key':k,'mode':p.stat().st_mode}
product_path=ev.parent/'godot-occurrence-visibility-20261102/inputs/client-visibility-product01-manifest.json'
product=load(product_path);bound(product_path,'40276e0371d70153f701eb15883e06c05ca97fe4ec21f78b4079cb79615b3bda')
manifest=ev/'inputs/client-visibility-vr-visual-companion01-manifest.json';m=load(manifest);cache(m['digest_cache'])
assert m['passed'] and not m['trace_free'] and not m['distributable'] and not m['compiled_application_inputs_copied']
assert m['live_source_inputs']==product['live_source_inputs'] and len(m['live_source_inputs'])==98
assert len(m['supplied_inputs'])==100 and len(m['export_outputs'])==196
assert m['dependency_archives']==product['dependency_archives'] and m['template']==product['template']
assert len(m['commands'])==5 and all(c['true_exit']==0 for c in m['commands'])
for n,h in m['live_source_inputs'].items():bound(root/n,h,True)
for n,h in m['supplied_inputs'].items():bound(Path(m['stage'])/'source'/n,h,True)
for n,r in m['export_outputs'].items():bound(Path(m['export_executable']).parent/n,r['sha256'],True)
dispatch='if (phase == "vr-ready263") { await VrFrameReady(); return; }\n            '
base='client/godot/tests/ExportChecks.cs'
assert (Path(m['stage'])/'source'/base).read_text().replace(dispatch,'',1)==(root/base).read_text()
assert set(m['diagnostic_overrides'])=={base,'client/godot/tests/VrFrameReady.cs','client/godot/tests/FrameObservation.cs'}
for n in ['VrFrameReady.cs','FrameObservation.cs']:assert raw(ev/n)==raw(visual/n)==m['supplied_inputs']['client/godot/tests/'+n]

# Reuse actual finite-owner evidence by exact source identity. Fixture wording
# changed separately; the complete preparation-to-close observation body did not.
offline_path=visual/'logs/visual-readiness-offline01.json';offline=load(offline_path)
assert offline['child_exit']==0 and not offline['timed_out']
names=['FrameObservation.cs','live.py','supervision.py','owned_commands.py','pipe_ownership.py','launch_spec.py','FrameObservationChecks.cs','test_supervision.py','test_owned_commands.py','test_launch_spec.py','offline_checks.py','harmless_stop.py']
owners={n:bound(visual/n,offline['driver_inputs'][n]) for n in names}
before=root/'doc/evidence/godot-occurrence-visibility-20261102/inputs/before/doc/evidence/godot-vr-visual-readiness-20261102/VrFrameReady.cs'
bound(before,offline['driver_inputs']['VrFrameReady.cs'])
anchor='        static bool Finish(string? command)'
assert before.read_text().split(anchor,1)[1]==(ev/'VrFrameReady.cs').read_text().split(anchor,1)[1]
stop_path=old/'logs/visual-stop-transport01.json';stop=load(stop_path)
assert stop['child_exit']==0 and all(stop['eof'].values()) and not stop['reader_errors']
stoplog=Path(stop['streams']['stdout']['path']);bound(stoplog,stop['streams']['stdout']['sha256'],True)
assert '"stdin_hex": "73746f700a"' in stoplog.read_text() and '"stdin_is_tty": true' in stoplog.read_text()
server=load(ev/'inputs/server-visibility-package-journey01-server.json')
assert server['child_exit']==0 and not server['runtime_recompiled'] and len(server['executed_current_sources'])==14
sources={n:bound(root/n,r['sha256']) for n,r in server['executed_current_sources'].items()}
objects={}
for n,r in server['executed_current_sources'].items():
    bound(r['saved_source'],r['sha256'])
    if 'compiled_object' in r:objects[n]=bound(r['compiled_object']['path'],r['compiled_object']['sha256'],True)
wire=root/'doc/evidence/godot-space-experience-20261101/inputs/space-name-owner03.json';bound(wire)
stage=TASK/'builds/answer-policy-clean-focused06/source';clean=stage.parent/'source-manifest.json';bound(clean,server['clean_source_binding']['sha256'],True)
for n in ['serve.py','godot_m3b_fixture.erl','godot_m3b_physics_fixture.erl']:
    assert d.h(ev/n)==server['driver_sources'][n]['sha256']
owners['manual_run.py']=bound(old/'manual_run.py')
future='visibility-visual-human01';wrapper='visibility-visual-fixture-wrapper01'
for p in [TASK/'private'/future,TASK/'private'/('quod-m4-live-'+future+'-server'),TASK/'private/runs'/wrapper]:assert not p.exists(),str(p)
fixture=['python3','-B',str(old/'manual_run.py'),wrapper,'--','python3','-B',str(ev/'serve.py'),future+'-server','--stage',str(stage),'--profile','test','--qualified','--presentation-source','--clean-manifest',str(clean),'--affected-wire',str(wire)]
client=['python3','-B',str(visual/'live.py'),'--label',future,'--manifest',str(manifest),'--server-label',future+'-server','--launch-and-begin']
checks=[]
private=TASK/'private/visibility-package-card-check01';private.mkdir(mode=0o700,exist_ok=False)
for name,command in [('fixture-parser',['python3','-B',str(ev/'serve.py'),'--help']),('client-parser',['python3','-B',str(visual/'live.py'),'--help']),('wrapper-parser',['python3','-B',str(old/'manual_run.py'),'--help'])]:
    r=subprocess.run(command,capture_output=True,timeout=10)
    for stream,b in [('stdout',r.stdout),('stderr',r.stderr)]: (private/(name+'-'+stream+'.raw')).write_bytes(b)
    assert r.returncode==0 and not r.stderr and b'usage:' in r.stdout
    checks.append({'name':name,'argv':command,'true_exit':r.returncode,'stdout':bound(private/(name+'-stdout.raw')),'stderr':bound(private/(name+'-stderr.raw'))})
card={'state':'ARTIFACTS_READY_TO_LAUNCH','launch_authorized':False,'future_label':future,'cwd':str(root),
 'fixture':{'argv':fixture,'tty':True,'await':'actual M1B_READY','stop_literal':'stop\n','stop_hex':'73746f700a'},
 'client':{'argv':client,'tty':True,'begin':'existing local owner sends once only after exact mapped PREPARED and valid original bounds','finish_literal':'finish\n'},
 'bounds':{'preparation':180,'no_visual_frame':30,'participant':1800,'normal_close':60,'outer':2100,'authentic_expiry':'earlier absolute cutoff; never renewed'},
 'product_manifest':bound(product_path),'companion_manifest':bound(manifest),'executable':m['export_executable'],
 'same_production_inputs':98,'supplied_inputs':100,'diagnostic_only':True,'server_sources':sources,'qualified_objects':objects,
 'server_binding_receipt':bound(ev/'inputs/server-visibility-package-journey01-server.json'),'qualified_world_name_owner':bound(wire),
 'observer_sources':{n:bound(ev/n) for n in ['VrFrameReady.cs','FrameObservation.cs']},'launch_owners':owners,
 'process_environment':{'QT_QPA_PLATFORM':'xcb','XR_RUNTIME_JSON':'/home/yan/.local/share/Steam/steamapps/common/SteamVR/steamxr_linux64.json','DISPLAY_WAYLAND_DISPLAY':'preserve actual inherited values','global_changes':False},
 'renderer':'existing explicit Wayland / Vulkan / mobile',
 'visual_gate':'first Focused + CanRender + advancing stereo frame + tracked head + accepted signed world/receiver + unexpired authentication; no controller wait',
 'interaction':'separate production per-controller admission; optional strict two-controller VR263_READY never delays visual admission',
 'task':'Identify Current space. The left and right labeled views depict the SAME Analyzer. Select one view, read Analyzer settings / Measurement, move that same form to Personal workspace and back Near this object. Then open Your attention, choose the Measurement request, type only a local draft, use Later and recall it. Do not submit during this inspection.',
 'wear_instruction':'Invite Yan to put on the headset only after actual VISUAL_READY; artifact existence is not native readiness.',
 'stop_contract_reused':{'receipt':bound(stop_path),'child_exit':0,'wrapper_exit':0,'both_eof':True,'tty':True,'stdin_hex':'73746f700a'},
 'guard_evidence_reused':{'receipt':bound(offline_path),'checks':120,'true_exit':0,'observation_and_supervision_body_unchanged':True,'fixture_wording_updated_separately':True},
 'parser_checks':checks,'no_live_fixture_client_XR_or_hardware_launched':True,'no_test_time_AI_preflight_build_or_audit':True}
cache_path=TASK/'cache/visibility-package-card01-hashes.json';d.write(cache_path)
card['digest_cache']={'path':str(cache_path),'sha256':raw(cache_path),'records':len(d.values),'pathless_preserved':True}
(ev/'artifacts-ready.json').write_text(json.dumps(card,indent=2)+'\n')
(ev/'run-card.md').write_text('''# Offline direct launch card

This reserves one future opportunity; it does not authorize launch. Root must send the actual launch instruction. There is no test-time AI preflight, build or audit. Existing launch owners still enforce exact mapped identity, source, expiry and exactly-once begin.

From `/home/yan/src/quod_worktrees/pearl-stone`, use **tty:true** for each command. First start the fixture and await its actual `M1B_READY`:

```sh
'''+shlex.join(fixture)+'''
```

Then start the client. The same local owner immediately sends one begin after mapped PREPARED; no second root round trip:

```sh
'''+shlex.join(client)+'''
```

PREPARED is not visual readiness. Invite Yan to put on the headset only after actual **VISUAL_READY**: Focused, CanRender, advancing stereo, tracked head and accepted signed world/receiver. Controllers are reported separately; interaction remains subject to production tracking/binding/neutral guards. Optional strict two-controller readiness never delays the visual gate. Signed Updating stays locked and observable without resetting any deadline.

Task: “Look for Current space. Left and right are two views of the same Analyzer. Select either one. Can you read Analyzer settings and Measurement, and use the form near the object? Try Personal workspace, then Near this object. Finally open Your attention, choose the Measurement request, type a local draft and use Later; recall it.” No automated human action or Submit.

Bounds remain preparation180 / no-visual-frame30 / participant1800 / normal-close60 / outer2100 seconds, with authentic sign-in expiry an earlier cutoff. Never reuse labels, profiles, PTYs or uncertain work. On stop: current exact-owned client `finish\\n` once; await actual closure/EOF (retain any failure); then fixture **`stop\\n` exactly once**, hex `73746f700a`. An empty line is not fixture stop. No runtime helper signal, focus change, renewal or retry.

Exact manifest, source/runtime bindings, argv arrays and finite parser receipts are in [artifacts-ready.json](artifacts-ready.json). Headset placement/readability and historical retirement reliability remain unqualified by these artifacts.
''')
print(json.dumps({'state':card['state'],'receipt':str(ev/'artifacts-ready.json'),'sha256':raw(ev/'artifacts-ready.json'),'companion_sha256':raw(manifest),'parser_checks':len(checks),'launch_authorized':False}))
