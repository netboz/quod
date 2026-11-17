"""Bind actual current source, retained failures and finite menu qualifications."""
import difflib,json,os,stat,sys
from pathlib import Path
sys.dont_write_bytecode=True;os.umask(0o077)
from hashes import Digests,TASK,key,raw
root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
def read(p):return json.loads(p.read_text())
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
contract=read(ev/'inputs/baseline-contract.json');parent=Path(contract['parent_manifest'])
assert raw(parent)==contract['sha256'];old=read(parent);assert old['passed']
candidates={};exports={}
for label in ['menu-baseline02','menu-final01','menu-geometry01','menu-final02']:
    path=ev/'inputs'/('client-'+label+'-manifest.json');m=read(path);assert m['passed'] and len(m['supplied_inputs'])==93
    assert not m['compiled_application_inputs_copied'] and not m['diagnostic_overrides']
    cache=m['digest_cache'];assert raw(cache['path'])==cache['sha256']
    for r in read(Path(cache['path']))['records']:
        k=tuple(r['stat_key']);assert k not in d.values or d.values[k]==r['sha256'];d.values[k]=r['sha256']
    source=Path(m['stage'])/'source'
    for n,h in m['supplied_inputs'].items():assert d.h(source/n)==h
    if label=='menu-final02':
        for n,h in m['live_source_inputs'].items():assert d.h(root/n)==h
    commands=[]
    assert len(m['commands'])==5
    for c in m['commands']:
        receipt=ev/('client-'+label+'-'+c['phase'])/'result.json';r=read(receipt)
        assert r['exit']==c['wrapper_exit']==0 and not r['diagnostic_failure'] and r['command']==c['command']
        log=receipt.parent/'output.log';assert log.is_file()
        commands.append({'receipt':str(receipt),'sha256':d.h(receipt),'log_sha256':d.h(log),'true_exit':r['exit']})
    dist=Path(m['export_executable']).parent
    files={str(p.relative_to(dist)):p for p in dist.rglob('*') if p.is_file()};assert set(files)==set(m['export_outputs']) and len(files)==196
    for n,r in m['export_outputs'].items():assert files[n].stat().st_size==r['bytes'] and d.h(files[n])==r['sha256']
    wrapper=read(ev/'logs'/(label+'-build01.json'));assert wrapper['child_exit']==0 and not wrapper['timed_out']
    exports[label]=m['export_outputs'];candidates[label]={'manifest':str(path),'sha256':d.h(path),'inputs':93,'exports':196,'export_bytes':sum(r['bytes'] for r in m['export_outputs'].values()),'commands':commands,'outer_exit':0}
    assert m['template']==old['template'] and m['dependency_archives']==old['dependency_archives']
def run(label,passed):
    p=ev/label;r=read(p/'result.json');w=read(ev/'logs'/(label+'-run.json'))
    assert r['passed']==passed and r['client_exit']==(0 if passed else 1) and w['child_exit']==(0 if passed else 1)
    assert all(r['eof'].values()) and not r['reader_errors'] and not r.get('failure') and not r.get('capture') and not w['timed_out'] and r['native_input']==[]
    for kind,row in w['private_streams'].items():
        path=Path(row['path']);assert path.stat().st_size==row['bytes'] and d.h(path)==row['sha256']
        assert stat.S_IMODE(path.stat().st_mode)==0o600 and stat.S_IMODE(path.parent.stat().st_mode)==0o700
    for row in w['sanitized_streams'].values():assert d.h(row['path'])==row['sha256']
    saved=TASK/'private/runs'/(label+'-run')/'driver-inputs'
    for n,h in w['driver_inputs'].items():assert d.h(saved/n)==h
    drivers=TASK/'private'/label/'drivers'
    for n,h in r['driver_hashes'].items():assert d.h(drivers/n)==h
    text=(p/'stdout.log').read_text();j=read(p/'client-result.json')
    return {'path':str(p/'result.json'),'sha256':d.h(p/'result.json'),'client_exit':r['client_exit'],'wrapper_exit':w['child_exit'],'eof':r['eof'],'reader_errors':[],'native_desktop_deliveries':0,'stored_checks':len(j.get('checks',[])),'pass_lines':sum(s.startswith('PASS ') for s in text.splitlines()),'fail_lines':[s for s in text.splitlines() if s.startswith('FAIL ')],'coverage':j.get('coverage')}
failed={label:run(label,False) for label in ['menu-baseline02-render01','menu-final01-render01','menu-geometry01-render01']}
passed={label:run(label,True) for label in ['menu-final01-controller01','menu-final02-render01','menu-final02-controller01']}
initial=read(ev/'logs/menu-baseline01-build01.json');assert initial['child_exit']==1 and not initial['timed_out']
assert not (TASK/'artifacts/client-menu-baseline01').exists()
delta={}
for n,r in contract['sources'].items():
    before=Path(r['before']);assert d.h(before)==r['sha256']==old['supplied_inputs'][n] and before.stat().st_mode==r['mode']==(root/n).stat().st_mode
    a=before.read_text().splitlines();b=(root/n).read_text().splitlines();diff=list(difflib.unified_diff(a,b,fromfile=n+' before',tofile=n))
    delta[n]={'before_path':str(before),'before_sha256':r['sha256'],'after_sha256':d.h(root/n),'added':sum(s.startswith('+') and not s.startswith('+++') for s in diff),'removed':sum(s.startswith('-') and not s.startswith('---') for s in diff),'mode':r['mode']}
    (ev/'inputs'/(Path(n).name+'.patch')).write_text('\n'.join(diff)+'\n')
selected=read(ev/'inputs/client-menu-final02-manifest.json')
assert set(selected['product_overrides'])==set(delta)
assert all(h==selected['supplied_inputs'][n] for n,h in old['supplied_inputs'].items() if n not in delta)
before=Path(delta['client/godot/OpenXRInput.cs']['before_path']).read_text();after=(root/'client/godot/OpenXRInput.cs').read_text()
quantization=next(s.strip() for s in before.splitlines() if 'int next=axes.Length()' in s)
assert quantization in after and 'Router.MenuSelected();CancelMenu();if(e.Enabled())e.Activate();' in before and 'Router.MenuSelected();CancelMenu();if(e.Enabled())e.Activate();' in after
controller=read(ev/'menu-final02-controller01/client-result.json')['metrics'];resources=controller['resources']
assert controller['Subscriptions']==controller['sources']==controller['appearances']==controller['captures']==resources['LiveTemplates']==resources['LiveLeases']==0
assert resources['Acquisitions']==resources['Releases']==resources['InstancesCreated']==resources['InstancesReleased']==2
cache=TASK/'cache/menu146-qualification01-hashes.json';d.write(cache)
result={'passed':True,'selected':'menu-final02','candidates':candidates,'failed_before_correction':failed,'passed_runs':passed,'initial_helper_failure':{'label':'menu-baseline01-build01','exit':1,'before_stage':True,'reason':'new cache loader assumed records list; authenticated root143 cache uses dictionary; source/receipt retained'},'source_delta':delta,'production_paths':['client/godot/OpenXRInput.cs','client/godot/SpatialGui.cs'],'authored_mapping_and_router_changed':False,'same_native_callbacks':True,'approved_runtime_focus_policy_changed':False,'current_inputs_match_selected':93,'resources_after_controller_retirement':controller,'digest_cache':{'path':str(cache),'sha256':raw(cache),'hits':d.hits,'new_files':d.new,'new_bytes':d.bytes},'raster_inspection':{'baseline':'menu-baseline02-render01/menu-selection.png','selected':'menu-final02-render01/menu-selection.png','viewed_by_worker':True,'maximum_font':48,'conclusion':'matching numbered angular map/native list, selected mark and release caption; opaque background; distinct enclosed native label rectangles'},'stage2_map':str(ev/'stage2-seams.md'),'tracker':{'own_uuid':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','read_only_calls':8,'receipts':str(TASK/'private/menu146-tracker01/result.json'),'body_publication':'BLOCKED; no retry or write'},'scope':'source-only software/native Control and injected XRServer qualification; controller gate headless; no compositor/device query, physical/native runtime, mouse delivery or domain operation','physical_menu_usability':'UNRUN; case23 human failure preserved','full_M4':False,'Stage2_implementation_started':False,'commit_or_M5':False}
write(ev/'result.json',result);print(json.dumps({'passed':True,'selected':result['selected'],'renderer_pass_lines':passed['menu-final02-render01']['pass_lines'],'controller_checks':passed['menu-final02-controller01']['stored_checks'],'source_delta':{n:{k:r[k] for k in ['added','removed']} for n,r in delta.items()},'cache_sha256':raw(cache)}))
