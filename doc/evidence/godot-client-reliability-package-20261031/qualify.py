"""Qualify only the new package/journey receipts, reusing authenticated custody."""
import difflib,json,os,stat
from pathlib import Path
from hashes import Digests,TASK,key,raw
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
def load(p):return json.loads(p.read_text())
def put(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
product_path=root/'doc/evidence/godot-ontology-workbench-20261031/inputs/client-workbench-product01-manifest.json'
assert raw(product_path)=='9c894e440bcd0d4fb0f67c35ae4e4b1456c9131f168a3e1bf9852846ec1083c8'
product=load(product_path);assert product['passed'] and product['trace_free'] and not product['diagnostic_overrides']
assert len(product['live_source_inputs'])==len(product['supplied_inputs'])==96
assert all(d.h(root/n)==v for n,v in product['live_source_inputs'].items())
assert all(d.h(Path(product['export_executable']).parent/n)==r['sha256'] for n,r in product['export_outputs'].items())
wrappers={};failures={'package-schema-baseline01':1,'package-schema-final01':1,'shutdown-owner-probe01-run':1,'current-companion01-build-run':1}
for path in sorted((ev/'logs').glob('*.json')):
    v=load(path);assert 'child_exit' in v and not v['timed_out']
    assert v['child_exit']==failures.get(path.stem,0),(path.name,v['child_exit'])
    saved=TASK/'private/runs'/path.stem/'driver-inputs'
    for n,sha in v['driver_inputs'].items():assert d.h(saved/n)==sha
    for field in ['private_streams','sanitized_streams']:
        for row in v[field].values():
            p=Path(row['path']);assert d.h(p)==row['sha256'] and p.stat().st_size==row['bytes']
            if field=='private_streams':assert stat.S_IMODE(p.stat().st_mode)==0o600 and stat.S_IMODE(p.parent.stat().st_mode)==0o700
    wrappers[path.stem]={'child_exit':v['child_exit'],'timed_out':False,'receipt_sha256':d.h(path)}
assert set(failures)<=set(wrappers)
builds={}
for label in ['current-companion01','current-companion02']:
    path=ev/'inputs'/('client-'+label+'-manifest.json');m=load(path);src=Path(m['stage'])/'source'
    assert m['live_source_inputs']==product['live_source_inputs'] and len(m['supplied_inputs'])==97
    assert not m['compiled_application_inputs_copied'] and not m['distributable']
    cache=Path(m['digest_cache']['path']);assert raw(cache)==m['digest_cache']['sha256']
    for r in load(cache)['records']:d.values[tuple(r['stat_key'])]=r['sha256']
    assert all(d.h(src/n)==sha for n,sha in m['supplied_inputs'].items())
    phases=[]
    for c in m['commands']:
        r=load(ev/(label+'-'+c['phase'])/'result.json');assert r['exit']==c['true_exit']
        phases.append({'phase':c['phase'],'true_exit':c['true_exit']})
    assert [c['true_exit'] for c in phases]==([0,0,0,0,1] if label.endswith('01') else [0]*5)
    if m['passed']:
        assert len(m['export_outputs'])==196
        assert all(d.h(Path(m['export_executable']).parent/n)==r['sha256'] for n,r in m['export_outputs'].items())
    builds[label]={'passed':m['passed'],'supplied':97,'same96_product_inputs':True,'manifest_sha256':d.h(path),'phases':phases,'export_count':len(m.get('export_outputs',{}))}
package=load(ev/'inputs/package01.json');repro=load(ev/'inputs/package-repro02.json');inspection=load(ev/'inputs/package-inspection01.json')
assert package==repro and inspection['passed'] and inspection['archive_sha256']==package['archive_sha256']
assert package['export_files']==196 and package['package_files']==207
assert inspection['symbol_versions']=={'GLIBC':'2.44','GLIBCXX':'3.4.22','CXXABI':'1.3.7'}
ordinary=load(ev/'inputs/current-ordinary-launch01.json');assert ordinary['passed'] and ordinary['true_exit']==ordinary['normal_close_exit']==0 and ordinary['packaged_coreclr_loaded'] and not ordinary['qualification_flag']
assert load(ev/'inputs/isolation-probe01.json')['passed']
assert load(ev/'inputs/current-package-checks01.json')['count']==8
# These are actual newly-created owned files, content-hashed by the successful
# package/extraction child. No other writer has touched these private outputs.
# Bind that controlled transition to exact current stat identities before reuse.
transitions=[]
def created(p,sha,size,origin):
    assert p.is_file() and not p.is_symlink() and p.stat().st_size==size
    k=key(p);assert k not in d.values or d.values[k]==sha;d.values[k]=sha
    transitions.append({'path':str(p),'stat_key':k,'sha256':sha,'origin':origin})
for p in [TASK/'artifacts/quod-workbench-linux-x86_64-private01.tar.gz',TASK/'artifacts/quod-workbench-linux-x86_64-repro02.tar.gz']:
    created(p,package['archive_sha256'],package['archive_bytes'],'actual separate package child0 digest; unchanged owned output since construction')
extracted=Path(inspection['extracted']);index=load(extracted/'package-manifest.json')
assert index['files']==package['files']
for n,r in index['files'].items():
    assert stat.S_IMODE((extracted/n).stat().st_mode)==r['mode']
    created(extracted/n,r['sha256'],r['bytes'],'actual extraction child0 hash/type/fullmode check; private0700 tree unchanged since creation')
journey=load(ev/'inputs/current-journey01.json');assert journey['passed'] and all(journey['eof'].values()) and len(journey['eof'])==6 and not journey['reader_errors']
assert {n:c['true_exit'] for n,c in journey['children'].items()}=={'server':0,'client-initial':0,'client-reopen':0}
assert len(journey['children']['client-initial']['checks'])==99 and len(journey['children']['client-reopen']['checks'])==28
assert all(journey['children'][n]['explicit_completion'] for n in ['client-initial','client-reopen'])
assert 'shutdown_capture' not in journey and 'post_completion_trigger' not in journey
raw_journey=load(TASK/'private/current-journey01/result.raw.json')
assert len(raw_journey['native_inputs'])==34 and all(r['child_exit']==0 for r in raw_journey['native_inputs'])
retirement={}
for phase in ['initial','reopen']:
    p=TASK/'private/current-journey01'/('client-'+phase+'-stdout.raw')
    states=[json.loads(s[len('M1B_STATE '):]) for s in p.read_text().splitlines() if s.startswith('M1B_STATE ')]
    last=states[-1];metrics=last['controller_metrics']
    assert not last['world_accepted'] and last['scene_count']==0 and last['live_sockets']==0
    assert metrics['sources']==metrics['appearances']==metrics['captures']==0
    retirement[phase]={'scene_count':0,'live_sockets':0,'controller_sources':0,'controller_appearances':0,'captures':0,'XR_running':metrics['Running']}
work=load(TASK/'private/current-journey01/sandbox/work/unchanged-work.json');assert work['work']['calls']==[]
probe=load(ev/'shutdown-owner-probe01/result.json');assert not probe['passed'] and all(probe['eof'].values()) and not probe.get('explicit_completion') and not probe.get('shutdown_diagnostic')
source_delta={}
for name in ['client/godot-tools/package.py','client/godot-tools/package/README.txt']:
    before=ev/'inputs/before'/name;after=root/name
    diff=list(difflib.unified_diff(before.read_text().splitlines(),after.read_text().splitlines()))
    source_delta[name]={'before_path':str(before),'before_sha256':d.h(before),'after_sha256':d.h(after),'mode':stat.S_IMODE(after.stat().st_mode),'added_lines':sum(x.startswith('+') and not x.startswith('+++') for x in diff),'removed_lines':sum(x.startswith('-') and not x.startswith('---') for x in diff)}
put(ev/'inputs/controlled-output-custody.json',{'provenance':'owned construction/extraction child digests plus continuous private custody, no source/output link/mode mutation','records':transitions})
cache=TASK/'cache/client-reliability-qualified01.json';d.write(cache)
result={'passed':True,'checkpoint':'QUO-66 current private package / bounded shutdown diagnosis','worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','model':'openai-codex:gpt-6.1-sol','launcher_effort':'max','effective_backend_effort':'unexposed','source_delta':source_delta,'added_product_sources':[],'product':{'manifest':str(product_path),'manifest_sha256':d.h(product_path),'source_inputs':96,'exports':196,'unchanged_from_accepted194':True,'DLL':product['export_outputs']['data_Quod_linuxbsd_x86_64/Quod.dll'],'PCK':product['export_outputs']['quod.pck']},'package':{k:v for k,v in package.items() if k!='files'},'ordinary_product_launch':{'normal_exit':0,'packaged_coreclr':True,'build_tools_available':False,'no_qualification_flag':True,'current_host_only':True},'companion_builds':builds,'journey':{'initial_checks':99,'reopen_checks':28,'true_exits':[0,0,0],'EOF':6,'native_input_records':34,'text_entry_scope':'existing Godot native-Control InputEvent injection, distinct from host keyboard button/menu deliveries','unchanged_watched_calls':[],'retirement':retirement,'original_outcomes_no_replay':True,'companion_not_distributed':True},'shutdown':{'fixed':False,'retained05_09_whole_failures':True,'original_recorded_client_alive_at_cleanup':True,'new_probe_failed_before_shutdown':True,'ordinary_and_journey_normal_exits':True,'capture_triggered':False,'cause':'unresolved; no product/engine/close/deadline correction justified'},'wrappers':wrappers,'run_labels':list(wrappers),'digest_cache':{'path':str(cache),'sha256':raw(cache)},'full_M4_or_M5':False,'no_hardware_runtime_display_deployment_retirement_or_commit':True}
put(ev/'result.json',result)
print(json.dumps({'passed':True,'package_sha256':package['archive_sha256'],'checks':[99,28],'shutdown_fixed':False,'wrappers':len(wrappers)}))
