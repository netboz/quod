"""Bind new finite software results and exact-stat build references, no old API."""
import json,os,stat,subprocess,sys
from pathlib import Path
from cue_hashes import TASK,Digests,key,raw
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
selected_label=sys.argv[1];product_label=sys.argv[2]
def load(p):return json.loads(p.read_text())
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
builds={}
for path in sorted((ev/'inputs').glob('client-*-manifest.json')):
    m=load(path);assert not m['compiled_application_inputs_copied'] and len(m['commands'])==5
    if not m['passed']:
        assert path.name=='client-morning-final13-manifest.json' and m['commands'][-1]['phase']=='export' and m['commands'][-1]['wrapper_exit']==1
        assert all(c['wrapper_exit']==0 for c in m['commands'][:-1])
        builds['morning-final13']={'manifest':str(path),'manifest_sha256':raw(path),'passed':False,'supplied_inputs':len(m['supplied_inputs']),
            'failure':'retained CS0021 Term index typo in concise context; no export output set or application qualification',
            'child_exits':[0,0,0,0,1],'export_outputs':0,'outer_receipt':str(ev/'logs/morning-final13-build.json')}
        continue
    cache=Path(m['digest_cache']['path']);assert raw(cache)==m['digest_cache']['sha256']
    for r in load(cache)['records']:d.values[tuple(r['stat_key'])]=r['sha256']
    stage=Path(m['stage'])/'source';label=path.name[len('client-'):-len('-manifest.json')]
    for n,h in m['supplied_inputs'].items():
        p=stage/n;assert key(p) in d.values and d.h(p)==h
    for command in m['commands']:
        assert command['wrapper_exit']==0
        receipt=ev/('client-'+label+'-'+command['phase'])/'result.json';r=load(receipt)
        assert r['exit']==0
    dist=Path(m['export_executable']).parent
    assert len(m['export_outputs'])==196 and {str(p.relative_to(dist)) for p in dist.rglob('*') if p.is_file()}==set(m['export_outputs'])
    for n,r in m['export_outputs'].items():
        p=dist/n;assert key(p) in d.values and d.h(p)==r['sha256'] and p.stat().st_size==r['bytes']
    nuget=stage/'NuGet.Config'
    assert str(Path(m['stage'])/'dependency-feed') in nuget.read_text()
    builds[label]={'manifest':str(path),'manifest_sha256':raw(path),'supplied_inputs':len(m['supplied_inputs']),
        'export_outputs':196,'export_bytes':sum(r['bytes'] for r in m['export_outputs'].values()),
        'distributable':m['distributable'],'five_true_child_exits':[0]*5,'outer_receipt':str(ev/'logs'/(label+'-build.json')),
        'generated_configuration':{'path':str(nuget),'sha256':d.h(nuget),'purpose':'isolated accepted dependency-feed reference; not authored or compiled application input'},
        'digest_cache':m['digest_cache'],'export_byte_hashes_reused':True}
selected=load(ev/'inputs'/('client-'+selected_label+'-manifest.json'));product=load(ev/'inputs'/('client-'+product_label+'-manifest.json'))
assert selected['live_source_inputs']==product['supplied_inputs']==product['live_source_inputs'] and len(product['supplied_inputs'])==93
for n,h in product['supplied_inputs'].items():assert d.h(root/n)==h
assert not product['diagnostic_physical_partial'] and not product['diagnostic_overrides'] and product['distributable']
source=Path(product['stage'])/'source'
for name in ['PhysicalChecks.cs','ViveLookCue.cs','MorningJourneyChecks.cs','MorningJourneyGuide.cs']:assert not (source/'client/godot/tests'/name).exists()
assert 'phase == "vive-physical"' not in (source/'client/godot/tests/ExportChecks.cs').read_text()
dlls=[n for n in product['export_outputs'] if n.endswith('/Quod.dll')];assert len(dlls)==1
dll=(Path(product['export_executable']).parent/dlls[0]).read_bytes()
assert all(word not in dll for word in [b'VivePhysical',b'MorningJourneyGuide',b'MorningJourneyChecks',b'MorningInstruction'])
passes={};failures={}
for path in sorted(ev.glob('*/result.json')):
    r=load(path);label=path.parent.name
    if 'children' in r:
        assert all(r['eof'].values()) and len(r['eof'])==4 and not r['reader_errors']
        assert r['children']['server']['true_exit']==0
        assert not r['native_runtime_started'] and not r['hardware_queried'] and not r['display_or_focus_action']
        for n,row in r['streams'].items():
            p=Path(row['raw_path']);assert d.h(p)==row['sha256'] and p.stat().st_size==row['bytes'] and stat.S_IMODE(p.stat().st_mode)==0o600 and stat.S_IMODE(p.parent.stat().st_mode)==0o700
            public=path.parent/(p.stem+'.log');assert d.h(public)==row['public_sha256']
        summary={'client_exit':r['children']['client']['true_exit'],'server_exit':0,'all_four_EOF':True,'reader_errors':[],
            'checks':len(r.get('checks',[])),'result_sha256':d.h(path),'elapsed_seconds':r['elapsed_seconds']}
        if r['passed']:
            assert label in ['morning-final12-rehearsal01','morning-final12-render01',selected_label+'-render01'] and r['guide_step']==10 and not r['diagnostics']
            resources=r['metrics']['resources'];assert resources['Acquisitions']==resources['Releases']==2 and resources['InstancesCreated']==resources['InstancesReleased']==2 and resources['LiveTemplates']==resources['LiveLeases']==0
            summary['resources']=resources;passes[label]=summary
        else:failures[label]=summary
    elif label=='morning-final12-controller01':
        assert r['passed'] and r['client_exit']==0 and all(r['eof'].values()) and not r['reader_errors']
        checks=load(path.parent/'client-result.json')['checks'];assert len(checks)==75
        passes[label]={'client_exit':0,'both_EOF':True,'checks':75,'result_sha256':d.h(path)}
assert len(passes)==4
for n in ['client/godot/Core/Controllers.cs','client/godot/OpenXRInput.cs','client/godot/tests/ControllerChecks.cs']:
    assert selected['live_source_inputs'][n]==load(ev/'inputs/client-morning-final12-manifest.json')['live_source_inputs'][n]
for label in ['morning-cue-composition01','morning-bindings03','morning-launch-offline02','morning-launch-checks02']:
    r=load(ev/'logs'/(label+'.json'));assert r['child_exit']==0 and not r['timed_out']
assert 'CUE_COMPOSITION_PASS 8' in (ev/'logs/morning-cue-composition01-stdout.log').read_text()
assert load(ev/'binding-checks.json')['passed'] and len(load(ev/'binding-checks.json')['checks'])==119
assert load(ev/'launch-checks.json')['passed'] and len(load(ev/'launch-checks.json')['checks'])==15
changed={}
reasons={
 'client/godot/OperationsPanel.cs':'long selector width/release-mode choices; concise context/outcomes, bounded explicit exact details and ordinary native scroll reveal of returned actions',
 'client/godot/FormPanel.cs':'one shared native choice factory prevents overflow and press-open release selection; offered values unchanged',
 'client/godot/Core/Controllers.cs':'working form no longer blocks its own presentation recovery menu; pointer capture/travel fences retained',
 'client/godot/OpenXRInput.cs':'existing native pointer/popup/exclusive window owner blocks or cancels presentation menu without a click',
 'client/godot/README.md':'current selector and presentation-menu behavior',
 'client/godot/tests/ControllerChecks.cs':'eight real-owner affected arbitration/lifecycle/resource obligations',
 'client/godot/tests/SpaceChecks.cs':'fixture lookup uses exact full target tooltip rather than presentation caption'}
for n in sorted(reasons):
    before=ev/'inputs'/(Path(n).name+'.before');after=root/n
    assert d.h(before)==selected['accepted_placement_final01_inputs'][n] and d.h(after)==selected['live_source_inputs'][n]
    diff=subprocess.run(['git','diff','--no-index','--numstat',str(before),str(after)],capture_output=True,text=True);assert diff.returncode==1
    added,removed=map(int,diff.stdout.split('\t')[:2])
    changed[n]={'before_sha256':d.h(before),'after_sha256':d.h(after),'before_source':str(before),'added':added,'removed':removed,'purpose':reasons[n]}
write(ev/'source-delta.json',{'inherited_files':changed,'production_delta':{k:v for k,v in changed.items() if '/tests/' not in k and not k.endswith('README.md')},
 'no_new_domain_owner':True,'no_product_draft_policy_change':True,'historical_build_override_purpose_note':'Early build metadata used one overbroad selector-purpose string for all seven files; exact per-file scope is recorded here. Original manifests are unchanged.'})
def package(m,label):
    dll=[r for n,r in m['export_outputs'].items() if n.endswith('/Quod.dll')];pck=[r for n,r in m['export_outputs'].items() if n.endswith('.pck')];assert len(dll)==len(pck)==1
    manifest=ev/'inputs'/('client-'+label+'-manifest.json')
    return {'label':label,'manifest':str(manifest),'manifest_sha256':raw(manifest),'stage':m['stage'],'exe':m['export_executable'],'dll_sha256':dll[0]['sha256'],'pck_sha256':pck[0]['sha256'],'engine_sha256':m['template']['sha256']}
q={'passed':True,'scope':'fresh-private signed GUI/software journey and affected presentation/menu owners; no new native or physical case',
 'worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','actual_model':'openai-codex:gpt-6.1-sol','launcher_effort':'max; backend unexposed',
 'parent_snapshot':'a6d386ecc75c9805db20e72171c8ff35cf63f5dc9febe2175354de9020723252',
 'builds':builds,'selected_diagnostic':package(selected,selected_label),'tracefree_product':package(product,product_label),'passes':passes,'retained_failed_rehearsals':failures,
 'pure_composition_checks':8,'source_binding_checks':119,'offline_launch_checks':15,
 'native_cases_after21':0,'device_or_display_queries':0,'api_bytes_read':0,'export_bytes_rehashed_by_qualifier':0,
 'reused_qualification':{'server1432':'unchanged accepted dependency, no suite replay','core189':'unchanged crypto/store/forms/scene/asset obligations reused; changed controller arbitration qualified by75 checks, no fresh whole189 claim'},
 'reconnect':'ordinary explicit desktop Disconnect/Connect same saved identity after resting headset; signed wand withdrawal is retained',
 'physical_and_human':'UNRUN for this new composition; first-wearing timing/heading, hardware availability and ergonomics remain open',
 'travel':'not offered by this fixture; no body/control/ability invented, no collision or locomotion acceptance',
 'tracker':'one ownUUID explicit-project work_radar failed ESRCH before MCP; no mutation/publication retry',
 'no_owned_rehearsal_processes_pending':True,'commit_M5_fullM4':False}
write(ev/'qualification.json',q)
cache=TASK/'cache/morning-journey-receipts01.json';assert not cache.exists();d.write(cache)
write(ev/'receipt-cache.json',{'path':str(cache),'sha256':raw(cache),'purpose':'new exact-stat bindings plus accepted immutable results; no API read'})
print(json.dumps({'passed':True,'builds':len(builds),'passes':{k:v['checks'] for k,v in passes.items()},'failed_labels_retained':len(failures),'pure':8,'bindings':119,'launch':15,'api_bytes_read':0}))
