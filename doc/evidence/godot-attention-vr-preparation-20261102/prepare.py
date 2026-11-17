"""Authenticate current preparation inputs and write an OFFLINE launch receipt.

No fixture, application, display, runtime or hardware observation is performed.
Accepted payloads are checked by authenticated exact stat keys, never reread.
"""
import ast,json,os,shlex,shutil,stat
from pathlib import Path
from hashes import Digests,TASK,key,raw

os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent
d=Digests()
def small(p):return {'path':str(p),'sha256':d.h(p),'stat_key':key(p),'mode':p.stat().st_mode}
def known(p,sha):
    p=Path(p);k=key(p)
    assert k in d.values and d.values[k]==sha, ('missing or changed exact custody',str(p))
    return {'path':str(p),'sha256':sha,'stat_key':k,'mode':p.stat().st_mode,'payload_reread':False}
def load_cache(row):
    assert raw(row['path'])==row['sha256']
    for item in json.loads(Path(row['path']).read_text())['records']:
        k=tuple(item['stat_key']);v=item['sha256']
        assert k not in d.values or d.values[k]==v
        d.values[k]=v

manifest=ev/'inputs/client-attention-vr-companion01-manifest.json';m=json.loads(manifest.read_text())
product=root/'doc/evidence/godot-attention-review-20261102/inputs/client-attention-review-product01-manifest.json'
assert raw(product)=='dce5fe3f690dec8e3b7fd54b2e8da622efaa5e61ff65c4330b09cb21833f05bf'
pm=json.loads(product.read_text());assert m['live_source_inputs']==pm['live_source_inputs'] and len(m['live_source_inputs'])==98
assert m['passed'] and not m['trace_free'] and not m['distributable'] and not m['compiled_application_inputs_copied']
assert len(m['supplied_inputs'])==99 and m['template']==pm['template'] and m['dependency_archives']==pm['dependency_archives']
assert len(m['commands'])==5 and all(c['true_exit']==0 for c in m['commands'])
load_cache(m['digest_cache'])
production={name:known(root/name,sha) for name,sha in m['live_source_inputs'].items()}
stage=Path(m['stage'])/'source';supplied={name:known(stage/name,sha) for name,sha in m['supplied_inputs'].items()}
dispatch='if (phase == "vr-ready263") { await VrReady280(); return; }\n            '
base='client/godot/tests/ExportChecks.cs'
assert (stage/base).read_text().replace(dispatch,'',1)==(root/base).read_text()
assert raw(ev/'VrReady280.cs')==m['supplied_inputs']['client/godot/tests/VrReady280.cs']
assert set(m['diagnostic_overrides'])=={base,'client/godot/tests/VrReady280.cs'}
exports={name:known(Path(m['export_executable']).parent/name,row['sha256']) for name,row in m['export_outputs'].items()}
assert len(exports)==196
dependencies={name:known(Path(row['referenced_path']),row['sha256']) for name,row in m['dependency_archives'].items()}
engine=known(Path(m['template']['path']),m['template']['sha256'])
parent_path=root/'doc/evidence/godot-attention-client-package-20261102/result.json'
parent=json.loads(parent_path.read_text());assert parent['passed'] and parent['package_passed']
archive=known(Path(parent['archives'][0]['path']),'c4f3942d7fd0928cd183fccc4a7bd96c209d682ab232931866d95f9ad6b74cba')
package=Path(parent['extraction']);package_files={}
for name in ['quod.x86_64','quod.pck','data_Quod_linuxbsd_x86_64/Quod.dll']:
    package_files[name]=known(package/name,pm['export_outputs'][name]['sha256'])
server={name:known(root/name,row['sha256']) for name,row in parent['server_sources'].items()};assert len(server)==14
objects={}
for name,row in parent['server_sources'].items():
    if 'compiled_object' in row:
        obj=row['compiled_object'];objects[name]=known(Path(obj['path']),obj['sha256'])
wire=root/'doc/evidence/godot-space-experience-20261101/inputs/space-name-owner03.json';wire_receipt=json.loads(wire.read_text())
assert wire_receipt['passed'] and wire_receipt['true_exit']==0
for name,row in wire_receipt['new_objects'].items():
    if name=='quod_lobby_tests.beam':continue
    source_name=next(n for n in wire_receipt['inputs'] if n.startswith('src/') and Path(n).stem==Path(name).stem)
    obj=Path(wire_receipt['inputs'][source_name]['copy']).parent/name
    objects[source_name]=known(obj,row['sha256'])

def run_receipt(label):
    p=ev/'logs'/(label+'.json');r=json.loads(p.read_text())
    assert r['child_exit']==0 and not r['timed_out']
    for group in ['private_streams','sanitized_streams']:
        for s in r[group].values():
            f=Path(s['path']);assert d.h(f)==s['sha256']
            if group=='private_streams':assert stat.S_IMODE(f.stat().st_mode)==0o600 and stat.S_IMODE(f.parent.stat().st_mode)==0o700
    return p,r
gates={}
for label in ['attention-vr-companion01-build','attention-vr-owned-guards01','attention-vr-launch-spec01']:
    p,r=run_receipt(label);gates[label]={'receipt':small(p),'child_exit':0,'timed_out':False}
    if label.endswith('guards01'):
        output=Path(r['sanitized_streams']['stdout']['path']).read_text()
        result=json.loads(next(s[20:] for s in output.splitlines() if s.startswith('OWNED_COMMANDS_PASS ')))
        assert result['checks']==27 and result['eof']
        for name in ['owned_commands.py','supervision.py','pipe_ownership.py','test_owned_commands.py']:assert raw(ev/name)==r['driver_inputs'][name]
        gates[label]['result']=result
    if label.endswith('spec01'):
        output=Path(r['sanitized_streams']['stdout']['path']).read_text()
        result=json.loads(next(s[len('LAUNCH_SPEC_PASS '):] for s in output.splitlines() if s.startswith('LAUNCH_SPEC_PASS ')))
        assert result['checks']==8 and result['finite_child_exit']==37
        for name in ['launch_spec.py','live.py','test_launch_spec.py']:assert raw(ev/name)==r['driver_inputs'][name]
        gates[label]['result']=result
reused={}
for folder,label,owner,count,marker in [
    ('godot-steamvr-coordinated-20261101','steamvr269-supervision01','supervision.py',28,'SUPERVISION_PASS '),
    ('godot-steamvr-working-20261101','steamvr271-pipe-owner02','pipe_ownership.py',22,'PIPE_OWNERSHIP_PASS ')]:
    p=ev.parent/folder/'logs'/(label+'.json');r=json.loads(p.read_text())
    assert r['child_exit']==0 and not r['timed_out'] and raw(ev/owner)==r['driver_inputs'][owner]
    log=Path(r['sanitized_streams']['stdout']['path']);assert d.h(log)==r['sanitized_streams']['stdout']['sha256']
    completed=json.loads(next(l[len(marker):] for l in log.read_text().splitlines() if l.startswith(marker)))
    assert completed['checks']==count
    reused[owner]={'receipt':small(p),'same_owner_sha256':r['driver_inputs'][owner],'checks':count,'rerun':False}

for p in ev.glob('*.py'):ast.parse(p.read_text(),filename=str(p))
live=(ev/'live.py').read_text();cs=(ev/'VrReady280.cs').read_text()
assert 'commands.delegated_begin(supervisor,a.launch_and_begin)' in live and "assert sys.stdin.isatty()" in live
assert live.index("sock.connect(")<live.index('child=subprocess.Popen(')<live.index('initial=[w for w in windows()')
assert 'TimeSpan.FromSeconds(30)' in cs and 'gui.Captures==0' in cs and 'OpenXRInterface.SessionState.Focused' in cs
assert 'scene.Viewport.UseXR' in cs and 'api.CanRender()' in cs and 'sources.Length==2' in cs
assert 'M1B_CONTROL_PORT' in (ev/'launch_spec.py').read_text()
# These are source composition assertions, not actual native admission evidence.

label='attention280-human01';server_label=label+'-server';private=TASK/'private'/label
fresh=[private,TASK/'private'/('quod-m4-live-'+server_label),TASK/'private/runs/attention280-fixture-wrapper01']
assert all(not p.exists() for p in fresh)
qualified=TASK/'builds/answer-policy-clean-focused06/source'
fixture=['python3','-B',str(ev.relative_to(root)/'manual_run.py'),'attention280-fixture-wrapper01','--','python3','-B',str(ev.relative_to(root)/'serve.py'),server_label,
         '--stage',str(qualified),'--profile','test','--qualified','--presentation-source','--clean-manifest',str(qualified.parent/'source-manifest.json'),'--affected-wire',str(wire.relative_to(root))]
client=['python3','-B',str(ev.relative_to(root)/'live.py'),'--label',label,'--manifest',str(manifest.relative_to(root)),'--server-label',server_label,'--launch-and-begin']
commands={name:{'argv':argv,'cmd':shlex.join(argv),'cwd':str(root),'tty':True} for name,argv in [('fixture',fixture),('client',client)]}
out=TASK/'private/attention-vr-preparation280/ready-inputs';out.mkdir(mode=0o700,exist_ok=False)
drivers={}
for p in sorted(ev.iterdir()):
    if p.suffix in ['.py','.cs','.erl']:
        copy=out/p.name;shutil.copy2(p,copy);assert raw(copy)==d.h(p)
        drivers[p.name]={'source':small(p),'retained':small(copy)}
record={
 'checkpoint':280,'state':'ARTIFACTS_READY','passed':True,'application_runtime_or_fixture_started':False,
 'writer':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','model':'openai-codex:gpt-6-astra','backend_effort':'unexposed',
 'launch_authorized_now':False,'requires':'Fresh explicit physical availability/start followed by coordinator LAUNCH_AND_BEGIN280',
 'commands':commands,'fresh_paths':[str(p) for p in fresh],'profile':str(private/'profile'),
 'companion':{'manifest':small(manifest),'product_manifest':small(product),'production_inputs':98,'supplied_inputs':99,'outputs':196,'output_bytes':sum(v['bytes'] for v in m['export_outputs'].values()),'five_phases_exit0':True,'outer_exit0':True,'nondistributable':True,'diagnostic_overrides':m['diagnostic_overrides'],'live_bindings':production,'supplied_bindings':supplied,'export_bindings':exports,'dependencies':dependencies,'engine':engine},
 'accepted_package':{'archive':archive,'extraction':str(package),'selected_files':package_files,'read_export_or_archive_bytes':0,'rebuild':False,'parent_result':small(parent_path)},
 'fixture':{'current_sources':server,'count':14,'qualified_objects':objects,'stage':str(qualified),'clean_manifest':small(qualified.parent/'source-manifest.json'),'world_name_qualification':small(wire),'helper_compilation_only_at_future_launch':True},
 'gates':gates,'reused_gates':reused,'driver_inputs':drivers,
 'original_bounds_seconds':{'preparation':180,'native_admission':30,'participant':1800,'normal_close':60,'outer':2100},
 'auth':'Original signed absolute expiry is an earlier cutoff; no renewal, extension or uncertain replay.',
 'delegation':'After future explicit LAUNCH_AND_BEGIN280: fixture actual M1B_READY then client. At local PREPARED and exact current mapped PID/start/dev/inode/address, the same live owner immediately invokes Supervision.command(begin) once. No second root message or queued early begin. Recheck absolute cutoff after mapped-window query.',
 'notifications':'Subscribe before snapshot. The live owner subscribes to compositor events before Popen and checks current mappings immediately afterward. Coordinator should likewise subscribe before reading current invocation state; an existing PREPARED event must not be missed.',
 'native_ready_requires':['advancing rendered stereo compound frame observations; primary OpenXR/quod_inputs/UseXR/Always','XR Focused and CanRender','head and both current supported neutral Vive controller sources','signed world and current-place operation admission plus router mappings and question receiver','settled models; no captures; authentic unexpired sign-in; no production blocked state'],
 'native_state_now':'UNRUN; artifacts and historical272 provide no current native readiness, wearing, pixel or task result.',
 'environment':{'XR_RUNTIME_JSON':'/home/yan/.local/share/Steam/steamapps/common/SteamVR/steamxr_linux64.json','expected_manifest_sha256_at_launch':'5954b3a1dc001cf3f496ac93de9a516c17445bff3d62e93a410bb10a113ed477','QT_QPA_PLATFORM':'xcb','DISPLAY':'inherit actual','WAYLAND_DISPLAY':'inherit actual','Godot':'explicit wayland/vulkan/mobile','runtime_or_environment_probe_now':False,'global_defaults_unchanged':True},
 'bootstrap':'Ordinary fresh key/account setup, copied279 signed same-ontology Analyzer recipe/two occurrences and one attention request. Read-only current-place operation view then Home; no Analyzer selection, near/personal action, question selection, Enter/Leave/Apply/Send/Cancel/Preview/Save automation. All preparation is software input and receives no human credit.',
 'human_task':'Find Current space and select either Analyzer. Open its settings, move that form to Personal workspace and back Near this object. Open Your attention, choose Measurement request, type a short name, choose Later, then open that request again. Leave Apply configuration, Send answer and Cancel untouched for this check.',
 'stop':'Actual user stop or original cutoff: one finish newline through this current client supervisor, normal client exit/EOF first, then one newline to its current fixture PTY. No old target, forced success, next opportunity or deadline extension.',
 'availability':'Signed Updating locks remain production-owned and are reported without closing or resetting deadlines. Authentic expiry, admission failure, explicit stop and original cutoff retain normal finish fences.',
 'pipe_custody':'Capture direct engine stdout/stderr dev/inode immediately at Popen. Observe only its runtime-named helper; preserve process start across pre-exec without pinning a mismatching shell executable. EOF remains literal; no helper signaling or historical cause claim.',
 'privacy':'New private parents0700/raw0600; copied source and receipts remain under private Data. No profile or auth/session clock was created.',
 'tracker':'Actual own-UUID explicit-project radar/get65 exit0/non-error/zero signals; initial sandbox route ESRCH is a route observation only. No publication, duplicate item or tracker status claim.',
 'inbox':'One full current own batch read: executing activation meta-1793612841928-v51w1dc only; list-only is not consumption.',
 'limits':['Only compile/static/finite software guard qualification now; current native admission and human quality remain open.','Current published product/archive unchanged; companion is not distributed.','Certified-negative/Applied application presentation and residual P07/P08 limits are inherited.','Historical noEOF failures, all profiles and old human failures remain literal.','No notifier, fixture, test window, XR, SteamVR, hardware/focus/host input or human interaction performed.']}
cache=TASK/'cache/attention-vr-preparation280-hashes.json';d.write(cache)
record['digest_cache']={'path':str(cache),'sha256':raw(cache),'records':len(d.values),'pathless_preserved':True}
target=ev/'artifacts-ready280.json';target.write_text(json.dumps(record,indent=2)+'\n')
(TASK/'private/attention-vr-preparation280/artifacts-ready280.json').write_bytes(target.read_bytes())
print(json.dumps({'state':'ARTIFACTS_READY','receipt':str(target),'sha256':raw(target),'fixture_or_client_started':False,'runtime_or_hardware':False,'production_inputs':98,'supplied':99,'new_guard_checks':35,'reused_guard_checks':50}))
