"""Bind the one completed lifetime observation; no runtime or historical recount."""
import json,os,shutil,stat,subprocess
from pathlib import Path
from hashes import TASK,Digests,raw,key
from instrument_close import instrument

os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
dest=TASK/'private/retirement-qualification01';dest.mkdir(mode=0o700,exist_ok=False)
for p in [Path(__file__),ev/'hashes.py',ev/'instrument_close.py']:shutil.copy2(p,dest/p.name)
def load(p):return json.loads(Path(p).read_text())
def cache(ref):
    p=Path(ref['path']);assert raw(p)==ref['sha256']
    for row in load(p)['records']:
        k=tuple(row['stat_key']);assert k not in d.values or d.values[k]==row['sha256'];d.values[k]=row['sha256']
def bound(p,sha,size=None,inherited=False):
    p=Path(p)
    if inherited:assert key(p) in d.values,('inherited custody missing',str(p))
    assert d.h(p)==sha,(str(p),sha)
    if size is not None:assert p.stat().st_size==size
def private(p):
    p=Path(p);assert p.is_relative_to(TASK) and stat.S_IMODE(p.stat().st_mode)==0o600 and stat.S_IMODE(p.parent.stat().st_mode)==0o700

product_path=root/'doc/evidence/godot-authored-appearance-20261101/inputs/client-appearance-product03-manifest.json'
bound(product_path,'2fc8ea3a1326ccc9c211c2b9bdb285bc872cc82e890d71eae3880de84de35f2f',inherited=True)
product=load(product_path)
assert product['passed'] and product['trace_free'] and product['supplied_inputs']==product['live_source_inputs'] and len(product['live_source_inputs'])==98
manifest=ev/'inputs/client-retirement-observation01-manifest.json';m=load(manifest);cache(m['digest_cache'])
assert m['passed'] and not m['trace_free'] and not m['distributable'] and not m['compiled_application_inputs_copied']
assert m['product_manifest_sha256']==d.h(product_path) and m['live_source_inputs']==product['live_source_inputs']
assert len(m['supplied_inputs'])==100 and len(m['export_outputs'])==196
assert set(m['diagnostic_overrides'])=={'client/godot/Main.cs','client/godot/tests/ExportChecks.cs','client/godot/tests/PackageJourneyChecks.cs','client/godot/tests/CloseTrace.cs'}
src=Path(m['stage'])/'source';dist=Path(m['export_executable']).parent
for n,h in m['live_source_inputs'].items():bound(root/n,h,inherited=True)
for n,h in m['supplied_inputs'].items():bound(src/n,h)
for n,row in m['export_outputs'].items():bound(dist/n,row['sha256'],row['bytes'])
assert (src/'client/godot/Main.cs').read_text()==instrument((root/'client/godot/Main.cs').read_text())
dispatch='if (phase is "m5-initial" or "m5-reopen") { await PackageJourney(phase=="m5-reopen"); return; }'
original=(root/'client/godot/tests/ExportChecks.cs').read_text()
assert (src/'client/godot/tests/ExportChecks.cs').read_text()==original.replace('if (phase == "menu")',dispatch+'\n            if (phase == "menu")')
for name in ['PackageJourneyChecks.cs','CloseTrace.cs']:assert (ev/name).read_bytes()==(src/'client/godot/tests'/name).read_bytes()
bound(ev/'PackageJourneyChecks.cs','ac3f699a3949f9769dd9a702b01f917b5b2e952072011cde5226d72e5d249433')
assert m['template']==product['template'] and m['dependency_archives']==product['dependency_archives']
bound(m['template']['path'],m['template']['sha256'],inherited=True)
for row in m['dependency_archives'].values():bound(row['referenced_path'],row['sha256'],inherited=True)
assert len(m['commands'])==5 and all(c['true_exit']==0 for c in m['commands'])
for c in m['commands']:
    p=ev/('retirement-observation01-'+c['phase']);r=load(p/'result.json');assert r['exit']==0
    if 'output_sha256' in r:bound(p/'output.log',r['output_sha256'])
    else:d.h(p/'output.log')
for p in (Path(m['stage'])/'drivers').iterdir():assert p.read_bytes()==(ev/p.name).read_bytes()

jprivate=TASK/'private/retirement-observation01';journey=load(ev/'inputs/retirement-observation01.json');jr=load(jprivate/'result.raw.json')
assert journey['passed'] and jr['passed'] and journey['manifest_sha256']==d.h(manifest)
assert set(journey['children'])=={'server','client-initial','client-reopen'} and all(c['true_exit']==0 for c in journey['children'].values())
assert len(journey['eof'])==6 and all(journey['eof'].values()) and not journey['reader_errors']
assert journey['native_input_count']==0 and not journey['host_input_or_focus_action'] and journey['software_Control_signals']
assert not any(k in jr for k in ['failure','post_completion_trigger','lifetime_observation','unretired_failure','cleanup_timeout'])
assert not list(jprivate.glob('*stacks*'))
counts={};states={};close={};identities={}
expected=['close.enter','session.close.begin','session.close.returned','views.observed','views.completed','action.observed','action.completed','backup.observed','backup.completed','xr.completion.observed','xr.completion.completed','owners.await','owners.await.returned','models.dispose.begin','models.dispose.returned','models.observed','models.completed','models.await.returned','xr.shutdown.begin','xr.shutdown.returned','identity.release.begin','identity.release.returned','tree.quit.begin','tree.quit.returned','tree.exit.entered','tree.exit.returned']
for phase,count in [('initial',117),('reopen',36)]:
    name='client-'+phase;child=journey['children'][name];assert child['explicit_completion']
    report=load(jprivate/'sandbox/work'/(phase+'.json'));assert report['passed'] and len(report['checks'])==count;counts[phase]=count
    lines=(jprivate/(name+'-stdout.raw')).read_text().splitlines()
    assert [l[5:] for l in lines if l.startswith('PASS ')]==report['checks']==child['checks']
    assert sum(l.startswith('M5_PACKAGE_JOURNEY_PASS') for l in lines)==1
    state=json.loads([l[len('M1B_STATE '):] for l in lines if l.startswith('M1B_STATE ')][-1]);metrics=state['controller_metrics']
    assert state['scene_count']==state['live_sockets']==0 and not metrics['Running']
    assert all(metrics[k]==0 for k in ['Subscriptions','sources','appearances','captures'])
    states[phase]={'scenes':0,'sockets':0,'subscriptions':0,'sources':0,'appearances':0,'captures':0,'XR':False}
    stages=child['close_stages'];assert [r['stage'] for r in stages]==expected
    stderr=(jprivate/(name+'-stderr.raw')).read_text().splitlines()
    assert [json.loads(l[len('CLOSE_OWNER '):]) for l in stderr if l.startswith('CLOSE_OWNER ')]==stages
    assert all(r['thread']==1 and r['context']=='Godot.GodotSynchronizationContext' for r in stages)
    assert all(r['status']=='RanToCompletion' for r in stages if r['stage'].endswith(('.observed','.completed')))
    assert len({r['frequency'] for r in stages})==1 and all(a['monotonic']<=b['monotonic'] for a,b in zip(stages,stages[1:]))
    close[phase]={'stages':[r['stage'] for r in stages],'all_observed_tasks_already_completed':True,'thread':1,'context':'Godot.GodotSynchronizationContext','close_begin_to_ExitTree_return_seconds':(stages[-1]['monotonic']-stages[0]['monotonic'])/stages[0]['frequency'],'process_exit_latency_measured':False}
    owner=jr['children'][name];binding=load(jprivate/(name+'-engine-binding.json'))
    assert binding['pid']==owner['engine_pid'] and binding['incarnation']==owner['owner_incarnation']
    assert binding['incarnation'][:2]==list(key(dist/'quod.x86_64'))[:2] and owner['wrapper_pid']!=owner['engine_pid']
    assert binding['main_mappings'] and all(r['path']=='/opt/Quod app/quod.x86_64' and r['stat_key']==list(key(dist/'quod.x86_64')) for r in binding['main_mappings'])
    for r in binding['mapped_code_files']:
        if r['path'].startswith('/opt/Quod app/'):
            p=dist/r['path'][len('/opt/Quod app/'):];assert r['stat_key']==list(key(p));bound(p,m['export_outputs'][str(p.relative_to(dist))]['sha256'])
    identities[phase]={'engine_pid':owner['engine_pid'],'engine_incarnation':owner['owner_incarnation'],'wrapper_pid':owner['wrapper_pid'],'wrapper_incarnation':owner['wrapper_incarnation'],'binding_path':str(jprivate/(name+'-engine-binding.json')),'binding_sha256':d.h(jprivate/(name+'-engine-binding.json')),'at_failure_cutoff':False}
for row in journey['streams'].values():
    private(row['path']);bound(row['path'],row['sha256'],row['bytes']);p=Path(row['path'])
    projection=b''.join(line if line.startswith((b'PASS ',b'M5_PACKAGE_JOURNEY_PASS',b'CLOSE_OWNER ')) else b'<private fixture/client diagnostic>\n' for line in p.read_bytes().splitlines(keepends=True))
    assert (ev/'logs'/('retirement-observation01-'+p.stem+'.log')).read_bytes()==projection
cost=load(jprivate/'sandbox/work/unchanged-work.json');assert cost['work']['calls']==[]
appearance=load(jprivate/'sandbox/work/authored-appearance.json');assert appearance['fill']=='50c8f0ff' and not appearance['submitted']
server=load(ev/'inputs/server-retirement-observation01-server.json')
assert server['child_exit']==0 and not server['runtime_recompiled'] and len(server['executed_current_sources'])==14
for n,row in server['executed_current_sources'].items():
    bound(row['saved_source'],row['sha256']);bound(root/n,row['sha256'],inherited=True)
    if 'compiled_object' in row:
        o=row['compiled_object'];bound(o['path'],o['sha256'],o['bytes'],inherited=True)
    if 'presentation_overlay' in row:bound(row['presentation_overlay']['copy'],row['sha256'])
assert all(n in server['executed_current_sources'] for n in ['priv/ontologies/quod_gui.pl','priv/ontologies/gui_forms.pl'])
for row in server['driver_sources'].values():bound(row['path'],row['sha256'])
for n,row in server['affected_compiled_outputs'].items():bound(TASK/'private/quod-m4-live-retirement-observation01-server'/n,row['sha256'],row['bytes'])

wrappers={}
for label in ['retirement-observation01-build','retirement-observation01']:
    r=load(ev/'logs'/(label+'.json'));assert r['child_exit']==0 and not r['timed_out']
    for row in r['private_streams'].values():private(row['path']);bound(row['path'],row['sha256'],row['bytes'])
    for name,h in r['driver_inputs'].items():bound(TASK/'private/runs'/label/'driver-inputs'/name,h)
    wrappers[label]={'true_exit':0,'receipt_sha256':d.h(ev/'logs'/(label+'.json')),'elapsed_seconds':r['elapsed_seconds']}
assert (ev/'run.py').read_bytes()==(ev.parent/'godot-appearance-package-20261101/run.py').read_bytes()
assert (ev/'isolation.py').read_bytes()==(ev.parent/'godot-appearance-package-20261101/isolation.py').read_bytes()
text=(ev/'journey.py').read_text()
for literal in ['deadline=time.monotonic()+180','deadline=min(deadline,time.monotonic()+60)','child.wait(timeout=60)','child.kill();child.wait(timeout=10)','t.join(timeout=5)']:assert literal in text
assert '--xr-mode\',\'off' in text
assert subprocess.check_output(['git','rev-parse','HEAD']).decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert not subprocess.check_output(['git','diff','--cached','--name-only'])
cache_path=TASK/'cache/retirement-qualification01-hashes.json';assert not cache_path.exists();d.write(cache_path)
result={'passed':True,'evidence_verified':True,'diagnostic_passed':True,'cause_established':False,'shutdown_fixed':False,'product_changed':False,'capture_branch_executed':False,'full_M4_or_M5':False,
 'product':{'manifest':str(product_path),'sha256':d.h(product_path),'inputs':98,'exports':196,'export_bytes':193533744,'application_inputs_changed':False,'rebuilt':False,'accepted_archive_sha256':'491a83593cab1aa15a22fa489558f7aeaab57621a97c0c36cfa7d2df9049fb42'},
 'companion':{'manifest':str(manifest),'sha256':d.h(manifest),'production_inputs':98,'supplied':100,'exports':196,'export_bytes':sum(r['bytes'] for r in m['export_outputs'].values()),'checks':counts,'children':{n:c['true_exit'] for n,c in journey['children'].items()},'EOF':journey['eof'],'same_journey_assertions_as_failed246':True,'control_signals':True,'host_input':False,'final_states':states,'unchanged_work':cost,'authored_appearance_observed':appearance['fill']},
 'close_observations':close,'owned_identities':identities,'server_sources':server['executed_current_sources'],'server_runtime_rebuilt':False,'wrappers':wrappers,'run_labels':list(wrappers),'source_delta':{},'production_line_delta':{'added':0,'removed':0},
 'bounds':{'phase_seconds':180,'post_completion_seconds':60,'outer_seconds':300,'conditional_capture_seconds':15,'normal_cleanup_seconds':60},
 'historical_failures_preserved':['appearance-current-journey01 precompletion108 failure; reopen unrun','appearance-current-journey02 completed117 then original60s noEOF; reopen unrun','All earlier whole noEOF failures remain unchanged.'],
 'limits':['One new observation did not reproduce the original trigger. It neither identifies nor fixes the historical wait.','Successful close milestones are not native process-exit latency.','No cutoff-time engine/wrapper/pipe observation or native stack capture executed; those prepared branches are unexercised.','Current signed journey is nondistributable software companion evidence; no human or XR acceptance.','Application/server policy/package unchanged; existing private archive and full release limits remain.'],
 'digest_cache':{'path':str(cache_path),'sha256':raw(cache_path)},'digest_work':{'exact_stat_reuses':d.hits,'new_objects':d.new,'new_bytes':d.bytes}}
(ev/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'evidence_verified':True,'checks':counts,'close_intervals_seconds':{p:r['close_begin_to_ExitTree_return_seconds'] for p,r in close.items()},'cause_established':False,'shutdown_fixed':False,'product_changed':False,'capture_executed':False}),flush=True)
