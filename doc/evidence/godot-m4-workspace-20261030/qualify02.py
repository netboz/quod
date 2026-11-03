"""Bind the finite workspace correction, actual failures and selected software gates."""
import difflib,json,math,os,stat,subprocess,sys
from pathlib import Path
from hashes import Digests,TASK,key,raw
sys.dont_write_bytecode=True;os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
def load(p):return json.loads(Path(p).read_text())
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
root_cache=root/'_build/godot-m4-r2-coordinator-20261029/workspace06-hashes-127.json'
assert raw(root_cache)=='2494302da7bbee68b595fc3cdb6503e55dd2f86e377e516a18aa912e02f8f8a8'
for row in load(root_cache)['records'].values():d.values[tuple(row['key'])]=row['sha256']
builds={};output_bytes=0
for path in sorted((ev/'inputs').glob('client-workspace-*-manifest.json')):
    m=load(path);label=path.name[len('client-'):-len('-manifest.json')]
    commands=[]
    for command in m['commands']:
        p=ev/('client-'+label+'-'+command['phase'])/'result.json';r=load(p)
        assert r['exit']==command['wrapper_exit'];commands.append({'phase':command['phase'],'true_exit':r['exit'],'receipt_sha256':d.h(p)})
    row={'manifest':str(path),'manifest_sha256':d.h(path),'passed':m['passed'],'supplied_inputs':len(m['supplied_inputs']),'commands':commands}
    assert len(m['supplied_inputs'])==93 and not m['compiled_application_inputs_copied']
    if m['passed']:
        assert len(commands)==5 and all(c['true_exit']==0 for c in commands)
        cache=Path(m['digest_cache']['path']);assert raw(cache)==m['digest_cache']['sha256']
        for entry in load(cache)['records']:d.values[tuple(entry['stat_key'])]=entry['sha256']
        stage=Path(m['stage'])/'source'
        for name,digest in m['supplied_inputs'].items():assert key(stage/name) in d.values and d.h(stage/name)==digest
        dist=Path(m['export_executable']).parent
        actual={str(p.relative_to(dist)):p for p in dist.rglob('*') if p.is_file()}
        assert set(actual)==set(m['export_outputs']) and len(actual)==196
        for name,output in m['export_outputs'].items():
            p=actual[name];assert key(p) in d.values and d.h(p)==output['sha256'] and p.stat().st_size==output['bytes']
        row['exports']=196;row['export_bytes']=sum(x['bytes'] for x in m['export_outputs'].values());output_bytes+=row['export_bytes']
        row['digest_cache']=m['digest_cache'];row['output_bytes_hashed_again']=0
    else:
        assert label=='workspace-final04' and [c['true_exit'] for c in commands]==[0,0,0,0,1]
        row['failure']='Retained test-only CS1061 Node.As casts; no complete export or runtime execution credited.'
    builds[label]=row
assert len(builds)==10 and sum(r['passed'] for r in builds.values())==9
selected_path=ev/'inputs/client-workspace-final06-manifest.json';selected=load(selected_path)
assert selected['distributable'] and not selected['diagnostic_overrides'] and selected['trace_free_product_source']
assert selected['template']['sha256']=='02310d903099bada10c86cedc90bbc11ef0bec8254d6e607d1a53f6150ab0268'
for name,digest in selected['live_source_inputs'].items():assert d.h(root/name)==digest
prior=load(root/'doc/evidence/godot-m4-xr-focus-20261030/inputs/client-xr-focus-final01-manifest.json')['supplied_inputs']
assert all(selected['supplied_inputs'][n]==v for n,v in prior.items() if n.startswith('client/godot/Core/'))
delta={}
for name,before in [('client/godot/Main.cs','Main.cs.before'),('client/godot/OpenXRInput.cs','OpenXRInput.cs.before'),('client/godot/SpatialGui.cs','SpatialGui.cs.before'),('client/godot/README.md','README.md.before'),('client/godot/tests/ExportChecks.cs','ExportChecks.cs.before')]:
    p=ev/'inputs'/before;assert d.h(p)==prior[name]
    result=subprocess.run(['git','diff','--no-index','--numstat',str(p),str(root/name)],capture_output=True)
    assert result.returncode==1 and not result.stderr
    added,removed,_=result.stdout.decode().split('\t',2)
    delta[name]={'before_sha256':d.h(p),'after_sha256':d.h(root/name),'added_lines':int(added),'removed_lines':int(removed),'counting_method':'actual Git no-index numstat','before_mode':stat.S_IMODE(p.stat().st_mode),'after_mode':stat.S_IMODE((root/name).stat().st_mode)}
write(ev/'source-delta.json',{'inherited_files':delta,'new_test':{'path':'client/godot/tests/WorkspaceChecks.cs','sha256':d.h(root/'client/godot/tests/WorkspaceChecks.cs'),'lines':len((root/'client/godot/tests/WorkspaceChecks.cs').read_text().splitlines())},'production_owners':['Main','SpatialGui','OpenXRInput'],'domain_core_server_engine_runtime_changes':False,'growth_reason':'Missing shared spatial presentation controls/profile and native mirror/menu mapping; no second form/controller/executor or ontology owner.'})
gates={};failures={}
for folder in sorted(ev.iterdir()):
    p=folder/'result.json'
    if not folder.is_dir() or not p.exists() or not folder.name.startswith('workspace-'):continue
    r=load(p)
    if 'client_exit' not in r:continue
    stdout=folder/'stdout.log';stderr=folder/'stderr.log';text=stdout.read_text()
    report={'client_exit':r['client_exit'],'passed':r['passed'],'eof':r['eof'],'reader_errors':r['reader_errors'],'capture':r.get('capture'),'stdout_sha256':d.h(stdout),'stderr_sha256':d.h(stderr),'manifest_sha256':r['manifest_sha256'],'native_input':r['native_input'],'PASS_lines':sum(line.startswith('PASS ') for line in text.splitlines())}
    if (folder/'client-result.json').exists():
        c=load(folder/'client-result.json');report.update(stored_checks=len(c.get('checks',[])),seam_reports=[x for x in c.get('reports',[]) if 'passed' in x],result_sha256=d.h(folder/'client-result.json'))
    if folder.name.startswith('workspace-final06-'):
        assert r['passed'] and r['client_exit']==0 and all(r['eof'].values()) and not r['reader_errors'] and not r.get('capture')
        assert report['manifest_sha256']==d.h(selected_path)
        gates[folder.name]=report
    elif not r['passed']:failures[folder.name]=report
assert len(gates)==5
assert gates['workspace-final06-controller01']['stored_checks']==67 and gates['workspace-final06-scene01']['stored_checks']==15
assert gates['workspace-final06-presentation01']['stored_checks']==5 and len(gates['workspace-final06-presentation01']['seam_reports'])==10
assert gates['workspace-final06-headless01']['stored_checks']==34 and len(gates['workspace-final06-headless01']['seam_reports'])==6
assert gates['workspace-final06-render01']['stored_checks']==45 and len(gates['workspace-final06-render01']['seam_reports'])==6
for label,report in gates.items():
    for kind in ['stdout','stderr']:
        p=TASK/'private'/label/(kind+'.raw');assert stat.S_IMODE(p.stat().st_mode)==0o600 and stat.S_IMODE(p.parent.stat().st_mode)==0o700
        assert d.h(p)==report[kind+'_sha256']
baseline=load(ev/'workspace-baseline-layout01/client-result.json')
assert baseline['reports'][0]['accessible'] and not baseline['reports'][1]['accessible']
probe=load(ev/'workspace-probe03-headless01/client-result.json');assert len(probe['probeFailures'])==3
assert probe['reports'][3]['mirrorExpected']=='(580, 430)' and probe['reports'][3]['nativeClickDelta']==0
source=(root/'client/godot/OpenXRInput.cs').read_text();main=(root/'client/godot/Main.cs').read_text();gui=(root/'client/godot/SpatialGui.cs').read_text()
assert 'camera.Current=true;PresentWorkspace(true);' in source and 'PresentWorkspace(false);gui.Surface.GuiEmbedSubwindows=false;' in source
assert 'PlaceWorkspace(interactive);' in source and 'origin.GlobalTransform*pose.GetAdjustedTransform()' in source
assert 'api.IsRunning(),tracked' in source and 'focused && running && tracked && visible' in source
assert 'ApplicationFocused' not in source and 'HasFocus' not in source and 'workspaceShown' in source
assert 'WorkspaceMenuEntries' in main and 'operations?.IsVisibleInTree()' in main
assert 'mouse.Position*(Vector2)Surface.Size/Size' in gui and 'Surface.PushInput(mapped,true)' in gui
write(ev/'failure-dispositions.json',{'retained_failed_runs':failures,'dispositions':{
 'workspace-baseline-layout01':'Expected real Main layout failure at600x900; recorded1850x496 passed. Not case20 human-interval attribution.',
 'workspace-final01-headless01':'Fixture assigned LineEdit.Text but did not deliver its native TextChanged event; identity/draft object/font were retained.',
 'workspace-diagnostic01-headless01':'Assertion-only probe isolated value=draft/font30/identityTrue/sameDraftTrue. Historical manifest distributable field was overly broad; this diagnostic is not selected or distributable.',
 'workspace-final02-headless01':'Real new-owner defect: pending Move request survived native eligibility loss. StopMovingWorkspace now discards it; no automatic resume.',
 'workspace-final03-headless01':'Fixture attempted menu before full neutral; production guard correctly refused.',
 'workspace-probe02-headless01':'Fixture released press but retained non-neutral touchpad axes; new mirror/menu obligations not reached.',
 'workspace-probe03-headless01':'Three newly affected mirror/menu defects reproduced; XR ray surface coordinates passed. Shared mirror mapping and bounded native scroll owner corrected.',
 'workspace-final04':'Retained compiler failure from three test-only Node.As calls; ordinary casts corrected under new label.'},
 'inspection_failures':['qualification01 failed at the first root-cache import: coordinator records are a path-keyed dictionary with key, not worker list/stat_key; retained true1 before any output qualification. qualification02 changes only this schema adaptation.','Current raw geometry renderer field is null; first keys inspection raised TypeError, retained in tool transcript. Node-only geometry used thereafter, never reconstructed eyes/pixels.','A guessed software.py read failed; actual application.py was then read. No product run repeated.'],
 'new_hardware_cases_after20':0,'native_or_server_runs_after20':0})
q={'selected':'workspace-final06','scope':'Shared native GUI spatial presentation software only; case20 human failure retained separately.',
 'manifest':{'path':str(selected_path),'sha256':d.h(selected_path)},'supplied_inputs':93,'exports':196,'export_bytes':sum(x['bytes'] for x in selected['export_outputs'].values()),
 'DLL':selected['export_outputs']['data_Quod_linuxbsd_x86_64/Quod.dll']['sha256'],'PCK':selected['export_outputs']['quod.pck']['sha256'],'engine':selected['template']['sha256'],
 'trace_free_product':True,'diagnostic_physical_payload_prepared':False,'physical_qualification':'UNRUN for this corrected source; no case21 authority.',
 'builds':builds,'selected_gates':gates,'root127_independent_build_headless_cache':{'path':str(root_cache),'sha256':raw(root_cache)},
 'new_export_byte_recount':False,'core189_server1432':'Unchanged accepted inputs reused; no suite/build replay.',
 'presentation_defaults':{'surface_pixels':[1200,800],'body_font_pixels':26,'panel_height_metres':1,'initial_distance_metres':2,'nominal_em_angle_degrees':math.degrees(2*math.atan(26/800/4)),'not_ergonomic_acceptance':True},
 'case20_reference':{'qualification':'doc/evidence/godot-m4-vive-mapped20-20261030/qualification.json','sha256':d.h(root/'doc/evidence/godot-m4-vive-mapped20-20261030/qualification.json'),'human_panel_usability':'FAILED','target_activation':False,'human_interval_unknown':True},
 'limits':['Injected XRServer/native Controls are not physical controller gestures.','Independent scene update-mode guard is software field/lifetime evidence, not a fresh native stereo-frame proof.','Rasters are an offline qualification form at the trial26px profile, not the signed live-space GUI or headset pixels.','Broader Stage2 ontology editing/terrain, startup complaint, old desktop/cold-head failures, mapped physical actions and full M4 remain open.'],
 'commit_M5_fullM4':False}
write(ev/'qualification.json',q)
d.write(TASK/'cache/workspace-final06-qualification-hashes.json')
write(ev/'receipt-cache.json',{'path':str(TASK/'cache/workspace-final06-qualification-hashes.json'),'sha256':raw(TASK/'cache/workspace-final06-qualification-hashes.json'),'old_API_bytes_read':0,'new_export_bytes_rehashed':0})
print(json.dumps({'qualified':True,'selected':'workspace-final06','build_attempts':len(builds),'successful_builds':9,'selected_gates':len(gates),'source_inputs':93,'export_files':196,'physical_qualified':False,'API_bytes_read':0}),flush=True)
