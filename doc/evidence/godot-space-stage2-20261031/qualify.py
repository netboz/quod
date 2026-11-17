"""Bind the finite Stage2 software scope without reopening historical APIs."""
import difflib,json,os,stat,sys
from pathlib import Path
sys.dont_write_bytecode=True;os.umask(0o077)
from hashes import Digests,TASK,key,raw
root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
qualification_label=sys.argv[1] if len(sys.argv)==2 else 'stage2-qualification01'
def failed(kind,value,tb):
    progress=TASK/'cache'/(qualification_label+'-partial-hashes.json');d.write(progress)
    print(json.dumps({'failed_digest_progress':str(progress),'sha256':raw(progress),'failure_type':kind.__name__}),file=sys.stderr)
    sys.__excepthook__(kind,value,tb)
sys.excepthook=failed
def read(p):return json.loads(Path(p).read_text())
def write(p,v):Path(p).write_text(json.dumps(v,indent=2)+'\n')
def bind(p):
    p=Path(p);return {'path':str(p),'sha256':d.h(p),'bytes':p.stat().st_size,'mode':p.stat().st_mode,'stat_key':key(p)}
def cache(p,expected):
    assert raw(p)==expected,('cache identity',str(p))
    rows=read(p)['records']
    for r in rows.values() if isinstance(rows,dict) else rows:
        k=tuple(r['stat_key']);assert k not in d.values or d.values[k]==r['sha256'];d.values[k]=r['sha256']
wrappers={};build_wrappers={}
for p in sorted((ev/'logs').glob('*.json')):
    r=read(p);assert not r['timed_out'],('outer deadline failure retained separately',str(p))
    for kind,row in r['private_streams'].items():
        f=Path(row['path']);assert d.h(f)==row['sha256'] and f.stat().st_size==row['bytes']
        assert stat.S_IMODE(f.stat().st_mode)==0o600 and stat.S_IMODE(f.parent.stat().st_mode)==0o700
    for row in r['sanitized_streams'].values():assert d.h(row['path'])==row['sha256']
    saved=Path(next(iter(r['private_streams'].values()))['path']).parent/'driver-inputs'
    for n,h in r['driver_inputs'].items():assert d.h(saved/n)==h
    wrappers[p.stem]={'receipt':bind(p),'true_exit':r['child_exit'],'timed_out':r['timed_out'],'saved_inputs':len(r['driver_inputs'])}
    for i,arg in enumerate(r['command']):
        if Path(arg).name=='build.py':build_wrappers[r['command'][i+1]]=(p,r)
candidates={};partial_builds={}
for p in sorted((ev/'inputs').glob('client-*-manifest.json')):
    m=read(p);label=p.name[len('client-'):-len('-manifest.json')]
    if not m.get('passed'):
        partial_builds[label]={'manifest':bind(p),'commands_completed':m.get('commands',[]),'qualified_complete_export':False}
        continue
    assert not m['compiled_application_inputs_copied']
    cache(m['digest_cache']['path'],m['digest_cache']['sha256'])
    source=Path(m['stage'])/'source'
    for n,h in m['supplied_inputs'].items():
        assert d.h(source/n)==h,(label,n)
        original=root/n if (root/n).exists() else ev/'Stage2Checks.cs'
        assert (source/n).stat().st_mode==original.stat().st_mode,(label,n,'source mode')
    commands=[];assert len(m['commands'])==5
    for c in m['commands']:
        receipt=ev/('client-'+label+'-'+c['phase'])/'result.json';r=read(receipt)
        assert r['exit']==c['wrapper_exit']==0 and not r['diagnostic_failure'] and r['command']==c['command']
        commands.append({'receipt':bind(receipt),'log':bind(receipt.parent/'output.log'),'true_exit':r['exit']})
    dist=Path(m['export_executable']).parent
    files={str(f.relative_to(dist)):f for f in dist.rglob('*') if f.is_file()}
    assert len(files)==196 and set(files)==set(m['export_outputs'])
    for n,r in m['export_outputs'].items():assert d.h(files[n])==r['sha256'] and files[n].stat().st_size==r['bytes']
    wp,w=build_wrappers[label];assert w['child_exit']==0
    candidates[label]={'manifest':bind(p),'supplied_inputs':len(m['supplied_inputs']),'live_inputs':len(m['live_source_inputs']),'exports':196,'export_bytes':sum(r['bytes'] for r in m['export_outputs'].values()),'commands':commands,'outer':bind(wp),'current_source':m['compiled_from_actual_current_source'],'distributable':False}
selected=read(ev/'inputs/client-stage2-final03-manifest.json');prior_selected=read(ev/'inputs/client-stage2-final01-manifest.json');assert selected['live_source_inputs']==prior_selected['live_source_inputs'];product=read(ev/'inputs/client-stage2-product01-manifest.json')
assert selected['passed'] and product['passed'] and selected['live_source_inputs']==product['supplied_inputs']==product['live_source_inputs']
assert len(selected['supplied_inputs'])==96 and len(product['supplied_inputs'])==95
assert selected['stage2_partial'] and not product['stage2_partial'] and not product['diagnostic_overrides']
for n,h in product['supplied_inputs'].items():assert d.h(root/n)==h
for m in [selected,product]:
    assert m['template']['sha256']=='02310d903099bada10c86cedc90bbc11ef0bec8254d6e607d1a53f6150ab0268'
    for r in m['dependency_archives'].values():assert d.h(r['referenced_path'])==r['sha256'] and Path(r['referenced_path']).stat().st_size==r['bytes']
assert selected['dependency_archives']==product['dependency_archives']
rehearsals={}
for p in sorted(ev.glob('*/result.json')):
    r=read(p)
    if 'children' not in r:continue
    label=p.parent.name
    for name,row in r['streams'].items():
        f=Path(row['raw_path']);assert d.h(f)==row['sha256'] and f.stat().st_size==row['bytes']
        assert stat.S_IMODE(f.stat().st_mode)==0o600 and stat.S_IMODE(f.parent.stat().st_mode)==0o700
        assert d.h(p.parent/(f.stem+'.log'))==row['public_sha256']
    private=TASK/'private'/label
    for source,h in r['sources'].items():assert d.h(private/'drivers'/Path(source).name)==h
    if r.get('client_result_sha256'):assert d.h(private/'client-result.raw.json')==r['client_result_sha256']
    text='\n'.join(f.read_text() for f in p.parent.glob('client*-stdout.log'))
    rehearsals[label]={'receipt':bind(p),'passed':r['passed'],'children':{n:c.get('true_exit') for n,c in r['children'].items()},'eof':r['eof'],'reader_errors':r['reader_errors'],'failure':r.get('failure'),'unretired_client_failure':r.get('unretired_client_failure',False),'checks':len(r.get('checks',[])),'prior_checks':len(r.get('prior_checks',[])),'actual_pass_lines':sum(s.startswith('PASS ') for s in text.splitlines()),'native_runtime_started':r['native_runtime_started'],'hardware_queried':r['hardware_queried'],'display_or_focus_action':r['display_or_focus_action']}
    assert not r['native_runtime_started'] and not r['hardware_queried'] and not r['display_or_focus_action']
required=['stage2-final01-headless','stage2-final03-render','stage2-final03-contents','stage2-subject-final01-headless']
for label in required:
    r=rehearsals[label];assert r['passed'] and all(v==0 for v in r['children'].values()) and all(r['eof'].values()) and not r['reader_errors']
assert rehearsals['stage2-final01-headless']['checks']==9 and rehearsals['stage2-final01-headless']['prior_checks']==162
assert rehearsals['stage2-final01-headless']['actual_pass_lines']==171
assert rehearsals['stage2-final03-contents']['checks']==8
for label in ['stage2-race-baseline01-headless','stage2-credit-baseline01-headless','stage2-subject-baseline01-headless']:
    r=rehearsals[label];assert not r['passed'] and r['children']['client']==1 and r['children']['server']==0 and all(r['eof'].values())
applications={}
for label in ['stage2-final01-workspace']:
    p=ev/label/'result.json';r=read(p);assert r['passed'] and r['client_exit']==0 and all(r['eof'].values()) and not r['reader_errors'] and not r.get('capture') and not r['native_input']
    for kind,row in r['streams'].items():
        f=Path(row['raw_path']);assert d.h(f)==row['sha256'] and f.stat().st_size==row['bytes']
        assert d.h(p.parent/(kind+'.log'))==row['public_sha256'] and stat.S_IMODE(f.stat().st_mode)==0o600
    private=TASK/'private'/label
    for n,h in r['driver_hashes'].items():assert d.h(private/'drivers'/n)==h
    applications[label]={'receipt':bind(p),'stored_checks':len(read(p.parent/'client-result.json')['checks']),'client_exit':r['client_exit'],'eof':r['eof'],'native_input':r['native_input']}
owners=read(ev/'inputs/stage2-owner-final02.json');assert owners['passed'] and owners['true_exit']==0
for n,r in owners['inputs'].items():
    assert d.h(r['copy'])==r['sha256']
    if n.startswith('src/') or n.startswith('test/'):assert d.h(root/n)==r['sha256']
for name,r in owners['new_objects'].items():assert d.h(Path(owners['inputs']['src/quod_wire_term.erl']['copy']).parent/name)==r['sha256']
servers={}
for p in sorted((ev/'inputs').glob('server-*.json')):
    r=read(p)
    for n,item in r['executed_current_sources'].items():
        assert d.h(item['saved_source'])==item['sha256']
        if 'mode' in item:assert Path(item['saved_source']).stat().st_mode==item['mode']
    for item in r['driver_sources'].values():assert d.h(item['path'])==item['sha256']
    private=Path(r['private_raw_log']).parent
    for n,item in r.get('affected_compiled_outputs',{}).items():assert d.h(private/n)==item['sha256'] and (private/n).stat().st_size==item['bytes']
    servers[p.name]={'receipt':bind(p),'true_exit':r.get('child_exit'),'executed_source_count':len(r['executed_current_sources']),'compiled_objects':len(r.get('affected_compiled_outputs',{}))}
    if 'stage2-final03-contents' in p.name or 'stage2-final03-render' in p.name or 'stage2-final01-headless' in p.name:
        for n,item in r['executed_current_sources'].items():assert d.h(root/n)==item['sha256']
delta={}
for before in sorted((ev/'inputs/before').rglob('*')):
    if not before.is_file():continue
    n=str(before.relative_to(ev/'inputs/before'));after=root/n
    assert before.stat().st_mode==after.stat().st_mode
    if d.h(before)==d.h(after):continue
    diff=list(difflib.unified_diff(before.read_text().splitlines(),after.read_text().splitlines(),fromfile=n+' before',tofile=n))
    delta[n]={'before_path':str(before),'before_sha256':d.h(before),'after_sha256':d.h(after),'added':sum(s.startswith('+') and not s.startswith('+++') for s in diff),'removed':sum(s.startswith('-') and not s.startswith('---') for s in diff),'mode':after.stat().st_mode}
    name=n.replace('/','__')+'.patch';(ev/'inputs'/name).write_text('\n'.join(diff)+'\n')
added={n:bind(root/n) for n in ['client/godot/Core/Eidolons.cs','client/godot/EidolonPanel.cs']}
images=TASK/'private/stage2-final03-render/images';rasters={p.name:bind(p) for p in images.glob('*.png')};assert len(rasters)==4
layout=read(TASK/'private/stage2-final03-render/client-result.raw.json.layout.json');assert len(layout)==9
assert all(abs(r['panel_degrees']-41.112090439)<.001 and r['nominal_target_degrees']>1 for r in layout)
used=TASK/'cache'/(qualification_label+'-hashes.json');d.write(used)
result={'passed':True,'selected':'stage2-final03','tracefree_product':'stage2-product01','candidates':candidates,'partial_builds_preserved':partial_builds,'wrappers':wrappers,'rehearsals':rehearsals,'applications':applications,'server_input_output_bindings':servers,'affected_symbol_owners':{'receipt':bind(ev/'inputs/stage2-owner-final02.json'),'checks':48,'already_independently_verified_by_root158':True,'not_replayed_for_recount':True},'source_delta':delta,'added_product_sources':added,'rasters':rasters,'raster_inspection':'worker viewed all four actual source/action and editor working-view rasters at26/48; no physical readability/comfort claim','layout_geometry':layout,'digest_cache':{'path':str(used),'sha256':raw(used),'hits':d.hits,'new_files':d.new,'new_bytes':d.bytes},'history_or_api_bytes_rehashed':0,'unchanged_full_server_or_core_suite_replayed':False,'ontology_implies_spatial_membership':False,'physical_case24_started':False,'physical_stage2_accepted':False,'full_M4':False,'commit_or_M5':False,'scope':'Exact-subject authored discovery, selected scene and native source/inspection/editor software scope; existing M1-M3 reused; graphical workbench/founding/terrain remain outside.'}
write(ev/'result.json',result)
print(json.dumps({'passed':True,'selected':result['selected'],'tracefree_product':result['tracefree_product'],'complete_source_only_candidates':len(candidates),'partial_builds':len(partial_builds),'selected_integration_checks':171,'changed_inherited_paths':len(delta),'new_product_sources':len(added),'cache_sha256':raw(used)}))
