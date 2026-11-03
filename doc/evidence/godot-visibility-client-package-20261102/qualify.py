"""Verify this small package boundary; reuse authenticated parent custody."""
import json,os,stat,subprocess
from pathlib import Path
from hashes import TASK,Digests,raw,key
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests();evidence={}
def load(p):return json.loads(Path(p).read_text())
def cache(ref):
    assert raw(ref['path'])==ref['sha256']
    for r in load(ref['path'])['records']:
        k=tuple(r['stat_key']);assert k not in d.values or d.values[k]==r['sha256'];d.values[k]=r['sha256']
def bound(p,sha=None,size=None,known=False):
    p=Path(p);k=key(p)
    if known:assert k in d.values and (sha is None or d.values[k]==sha),str(p)
    h=d.h(p);assert sha is None or h==sha,str(p)
    if size is not None:assert p.stat().st_size==size
    evidence[str(p)]={'sha256':h,'stat_key':key(p),'mode':p.stat().st_mode,'bytes':p.stat().st_size}
    return h
def private(p):
    p=Path(p);assert p.is_relative_to(TASK) and stat.S_IMODE(p.stat().st_mode)==0o600 and stat.S_IMODE(p.parent.stat().st_mode)==0o700,str(p)
def streams(r):
    for group in ['streams','private_streams','sanitized_streams']:
        for row in r.get(group,{}).values():
            bound(row['path'],row['sha256'],row.get('bytes'))
            if group!='sanitized_streams':private(row['path'])
product_path=ev.parent/'godot-occurrence-visibility-20261102/inputs/client-visibility-product01-manifest.json'
product=load(product_path);bound(product_path,'40276e0371d70153f701eb15883e06c05ca97fe4ec21f78b4079cb79615b3bda');cache(product['digest_cache'])
assert product['passed'] and product['trace_free'] and not product['diagnostic_overrides'] and not product['distributable']
assert product['supplied_inputs']==product['live_source_inputs'] and len(product['live_source_inputs'])==98
for n,h in product['live_source_inputs'].items():bound(root/n,h,known=True)
for n,r in product['export_outputs'].items():bound(Path(product['export_executable']).parent/n,r['sha256'],r['bytes'],True)
for r in product['dependency_archives'].values():bound(r['referenced_path'],r['sha256'],known=True)
bound(product['template']['path'],product['template']['sha256'],known=True)
preparation=load(ev/'inputs/preparation-visibility-package-inputs01.json');cache(preparation['cache'])
assert preparation['source_inputs']==product['live_source_inputs']
bound(preparation['extras_manifest'],preparation['extras_manifest_sha256'])
for r in preparation['extras'].values():bound(r['path'],r['sha256'])
inspection=load(ev/'inputs/package-inspection01.json');cache(inspection['digest_cache'])
assert inspection['passed'] and inspection['files']==207 and inspection['exact_paths_types_bytes_modes']
assert len(inspection['elf_objects'])==16 and inspection['symbol_versions']['GLIBC']=='2.44'
bound(inspection['unchanged_elf_audit_reused']['path'],inspection['unchanged_elf_audit_reused']['sha256'],known=True)
archives=[]
for suffix in ['private01','repro02']:
    r=load(ev/'inputs'/('visibility-package-'+suffix+'.json'));p=TASK/'artifacts'/('quod-visibility-linux-x86_64-'+suffix+'.tar.gz')
    bound(p,r['archive_sha256'],r['archive_bytes'])
    assert r['export_manifest_sha256']==d.h(product_path) and r['export_files']==196 and r['package_files']==207
    archives.append({'path':str(p),'sha256':r['archive_sha256'],'bytes':r['archive_bytes'],'files':207})
assert archives[0]['sha256']==archives[1]['sha256'] and archives[0]['bytes']==archives[1]['bytes']
extraction=Path(inspection['extracted']);index=load(extraction/'package-manifest.json')
assert index['files']==load(ev/'inputs/visibility-package-private01.json')['files']
assert set(index['files'])|{'package-manifest.json'}=={str(p.relative_to(extraction)) for p in extraction.rglob('*') if p.is_file()}
for n,r in index['files'].items():
    p=extraction/n;assert stat.S_ISREG(p.lstat().st_mode) and stat.S_IMODE(p.stat().st_mode)==r['mode'];bound(p,r['sha256'],r['bytes'],True)
assert all(index['files'][n]['sha256']==r['sha256'] for n,r in product['export_outputs'].items())
assert load(ev/'inputs/visibility-package-checks01.json')['count']==9
assert load(ev/'inputs/isolation-probe01.json')['passed']
ordinary=load(ev/'inputs/visibility-package-ordinary-launch01.json');streams(ordinary)
assert ordinary['passed'] and ordinary['true_exit']==ordinary['normal_close_exit']==0 and ordinary['packaged_coreclr_loaded']
assert not ordinary['qualification_flag'] and not ordinary['native_xr'] and not ordinary.get('owned_cleanup_required') and not ordinary['reader_errors']
builds={}
for p in sorted((ev/'inputs').glob('client-*-manifest.json')):
    m=load(p);cache(m['digest_cache']);assert m['passed'] and not m['distributable'] and not m['trace_free']
    assert m['live_source_inputs']==product['live_source_inputs'] and not m['compiled_application_inputs_copied']
    assert m['dependency_archives']==product['dependency_archives'] and m['template']==product['template']
    assert len(m['commands'])==5 and all(c['true_exit']==0 for c in m['commands'])
    for n,h in m['supplied_inputs'].items():bound(Path(m['stage'])/'source'/n,h,known=True)
    for n,r in m['export_outputs'].items():bound(Path(m['export_executable']).parent/n,r['sha256'],r['bytes'],True)
    for f in (Path(m['stage'])/'drivers').iterdir():bound(f)
    builds[p.name]={'manifest':str(p),'sha256':bound(p),'production_inputs':98,'supplied':len(m['supplied_inputs']),'exports':len(m['export_outputs']),'five_phases_exit0':True}
before=(ev/'inputs/PackageJourneyChecks-before02.cs').read_text();after=(ev/'PackageJourneyChecks.cs').read_text()
old='var titles=PackageNodes(form).OfType<Label>().Where(l=>l.Text=="Analyzer settings"&&l.ThemeTypeVariation=="Title").ToArray();'
new='var titles=PackageNodes(pane).OfType<Label>().Where(l=>l.Name=="representation-title"&&l.Text=="Analyzer settings"&&l.ThemeTypeVariation=="Title").ToArray();'
assert before.replace(old,new)==after and before.count(old)==1
cases={};server=None;rasters={};states={}
for label in ['visibility-package-journey01','visibility-package-journey02']:
    p=ev/'inputs'/(label+'.json');r=load(p);streams(r);private_dir=TASK/'private'/label;actual=load(private_dir/'result.raw.json')
    assert r['eof']==actual['eof'] and r['passed']==actual['passed'] and all(r['eof'].values()) and not r['reader_errors']
    assert r['native_input_count']==0 and not r['host_input_or_focus_action']
    assert not r.get('post_completion_trigger') and not r.get('unretired_failure') and not r.get('cleanup_timeout')
    prefix={};counts={}
    for name,child in r['children'].items():
        if not name.startswith('client-'):continue
        lines=(private_dir/(name+'-stdout.raw')).read_text().splitlines();passes=[l[5:] for l in lines if l.startswith('PASS ')]
        prefix[name]=len(passes);phase=name.removeprefix('client-');result=private_dir/'sandbox/work'/(phase+'.json')
        if result.exists():
            report=load(result);assert report['passed'] and report['checks']==passes and child['explicit_completion'];counts[phase]=len(passes)
            state=json.loads([l[len('M1B_STATE '):] for l in lines if l.startswith('M1B_STATE ')][-1]);metrics=state['controller_metrics']
            assert state['scene_count']==state['live_sockets']==0 and not metrics['Running'] and all(metrics[k]==0 for k in ['Subscriptions','sources','appearances','captures'])
            states[phase]={'scenes':0,'sockets':0,'subscriptions':0,'sources':0,'appearances':0,'captures':0,'XR':False}
    if label.endswith('01'):
        assert not r['passed'] and prefix=={'client-initial':14} and {n:c['true_exit'] for n,c in r['children'].items()}=={'server':0,'client-initial':1}
        assert 'current authored title and Measurement section are visibly enclosed' in (private_dir/'client-initial-stderr.raw').read_text()
    else:
        assert r['passed'] and counts=={'initial':93,'reopen':68} and all(c['true_exit']==0 for c in r['children'].values()) and len(r['eof'])==6
        for phase in ['initial','reopen']:
            f=private_dir/'sandbox/work'/(phase+'-unchanged-work.json');assert load(f)['work']['calls']==[];bound(f)
        for f in (private_dir/'sandbox/work').glob('*.png'):rasters[f.name]={'path':str(f),'sha256':bound(f),'bytes':f.stat().st_size,'viewed':True}
        bound(private_dir/'sandbox/work/recovered-outcome.json')
    for row in r['streams'].values():
        f=Path(row['path']);projected=b''.join(l if l.startswith((b'PASS ',b'M5_PACKAGE_JOURNEY_PASS')) else b'<private fixture/client diagnostic>\n' for l in f.read_bytes().splitlines(keepends=True))
        assert (ev/'logs'/(label+'-'+f.stem+'.log')).read_bytes()==projected
    server=load(ev/'inputs'/('server-'+label+'-server.json'))
    assert server['child_exit']==0 and not server['runtime_recompiled'] and len(server['executed_current_sources'])==14
    for n,row in server['executed_current_sources'].items():
        bound(root/n,row['sha256']);bound(row['saved_source'],row['sha256'])
        if 'compiled_object' in row:bound(row['compiled_object']['path'],row['compiled_object']['sha256'],row['compiled_object']['bytes'],True)
    for row in server['driver_sources'].values():bound(row['path'],row['sha256'])
    for n,row in server['affected_compiled_outputs'].items():bound(TASK/'private'/('quod-m4-live-'+label+'-server')/n,row['sha256'],row['bytes'])
    for f in (private_dir/'drivers').iterdir():bound(f)
    bound(private_dir/'result.raw.json')
    cases[label]={'passed':r['passed'],'failure':r.get('failure'),'children':{n:c['true_exit'] for n,c in r['children'].items()},'checks':counts,'passing_prefix':prefix,'EOF':r['eof'],'receipt_sha256':bound(p),'post_completion_trigger':r.get('post_completion_trigger'),'reopen_executed':'client-reopen' in r['children']}
wrappers={}
for p in sorted((ev/'logs').glob('*.json')):
    r=load(p);expected=1 if p.stem=='visibility-package-journey01' else 0
    assert r['child_exit']==expected and not r['timed_out'];streams(r)
    for n,h in r['driver_inputs'].items():bound(TASK/'private/runs'/p.stem/'driver-inputs'/n,h)
    wrappers[p.stem]={'true_exit':r['child_exit'],'receipt_sha256':bound(p)}
for p in ev.glob('*/result.json'):
    r=load(p);assert r['exit']==0;bound(p);bound(p.parent/'output.log',r.get('output_sha256'))
card_path=ev/'artifacts-ready.json';card=load(card_path);cache(card['digest_cache'])
assert card['state']=='ARTIFACTS_READY_TO_LAUNCH' and not card['launch_authorized'] and card['no_live_fixture_client_XR_or_hardware_launched']
assert card['fixture']['tty'] and card['client']['tty'] and card['fixture']['stop_hex']=='73746f700a'
for group in ['observer_sources','launch_owners','server_sources','qualified_objects']:
    for row in card[group].values():bound(row['path'],row['sha256'],known=True)
assert card['server_sources'].keys()==server['executed_current_sources'].keys()
for n,row in card['server_sources'].items():assert row['sha256']==server['executed_current_sources'][n]['sha256']
for row in card['parser_checks']:
    assert row['true_exit']==0
    for stream in ['stdout','stderr']:private(row[stream]['path']);bound(row[stream]['path'],row[stream]['sha256'])
review=ev.parent/'godot-attention-review-20261102';prior=load(review/'result.json');ref=prior['shared_question_owners'];bound(ref['receipt'],ref['sha256'],known=True)
for n,r in load(ref['receipt'])['sources'].items():bound(root/n,r['sha256'],known=True)
browser_path=review/'inputs/attention-review-browser01.json';bound(browser_path,prior['browser']['receipt_sha256'],known=True);browser=load(browser_path)
assert browser['passed'] and browser['true_exit']==0 and browser['only_retained_sources_executed']
for n,r in browser['source_inputs'].items():bound(review/n if n=='browser.py' else root/n,r['sha256'],known=True)
assert subprocess.check_output(['git','rev-parse','HEAD']).decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert subprocess.check_output(['git','branch','--show-current']).decode().strip()=='worktree/pearl-stone'
assert not subprocess.check_output(['git','diff','--cached','--name-only'])
index_path=TASK/'cache/visibility-package-evidence01.json';index_path.write_text(json.dumps(evidence,indent=2)+'\n')
cache_path=TASK/'cache/visibility-package-qualified01-hashes.json';d.write(cache_path)
result={'passed':True,'package_passed':True,'evidence_verified':True,'all_selected_cases_passed':True,'all_attempts_passed':False,
 'product':{'manifest':str(product_path),'sha256':d.h(product_path),'inputs':98,'exports':196,'export_bytes':sum(r['bytes'] for r in product['export_outputs'].values()),'application_changed':False,'rebuilt':False,'trace_free':True,'distributable':False},
 'archives':archives,'extraction':inspection['extracted'],'package_checks':9,'unchanged_ELF_count':16,'GLIBC_floor':'2.44',
 'ordinary_launch':{'child_exit':0,'wrapper_exit':0,'normal_close_exit':0,'mapped_exact_owned_close':True,'packaged_CoreCLR':True,'qualification_flag':False,'XR':False},
 'builds':builds,'selected_journey':'visibility-package-journey02','cases':cases,'final_managed_states':states,
 'server_sources':server['executed_current_sources'],'server_runtime_rebuilt':False,'shared_question_owners_reused':ref,'browser_reused':prior['browser'],
 'rasters':rasters,'raster_limits':['Desktop initial and reopened forms visibly show Analyzer settings, Measurement, field and explicit action.','Both scene-only spatial textures show the two occurrences; they are not XR eye captures or a full associated-panel visibility proof.','Long descriptive occurrence labels overlap in the narrow desktop scene pane. No fixture spacing or production fix is included.'],
 'artifacts_ready':{'path':str(card_path),'sha256':d.h(card_path),'state':card['state'],'launch_authorized':False},
 'retained_new_failure':'journey01 asserted visibility of the deliberately hidden duplicate FormPanel title; whole1/client1/server0/4EOF/14 prefix. Diagnostic02 checks the actual representation-title outside the scroll; no production change.',
 'retained_parent_failures':['preview06: 118 functional checks but wholeFAIL original60s noEOF','interaction06: wholeFAIL unclassified compound assertion','all previous human/retirement failures unchanged'],
 'production_line_delta':{'added':0,'removed':0},'changed_inherited_paths':[],
 'historical_shutdown_fixed':False,'native_XR_or_host_input':False,'human_HMD_acceptance':False,'full_M4_M5_acceptance':False,'future_launch_authorized':False,
 'limits':['Private current-host package only; GLIBC2.44 and matching qualified server/trust required.','Fresh visual companion is built but has not been launched. Actual Focused/CanRender/stereo/signed admission remains required.','Visual admission does not grant interaction or prove headset pixels, reach or readability.','No full certified-negative application completion, broad browser appearance support, or historical shutdown fix.'],
 'wrappers':wrappers,'evidence_index':{'path':str(index_path),'sha256':raw(index_path),'records':len(evidence)},
 'digest_cache':{'path':str(cache_path),'sha256':raw(cache_path),'records':len(d.values),'pathless_preserved':True}}
(ev/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print('VISIBILITY_PACKAGE_QUALIFIED '+json.dumps({'package_passed':True,'selected_journey':{'initial':93,'reopen':68},'archive':archives[0],'artifacts_ready_sha256':d.h(card_path),'retained_failure':'journey01','evidence_records':len(evidence)}))
