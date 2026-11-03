"""Current package composition and actual results, without rerunning any gate."""
import difflib,json,os,shutil,stat,subprocess
from pathlib import Path
from hashes import TASK,Digests,raw,key
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
dest=TASK/'private/current-space-package-qualification01';dest.mkdir(mode=0o700,exist_ok=False)
for f in [Path(__file__),ev/'hashes.py']:shutil.copy2(f,dest/f.name)
def load(p):return json.loads(Path(p).read_text())
def cache(ref):
    p=Path(ref['path']);assert raw(p)==ref['sha256']
    for row in load(p)['records']:
        k=tuple(row['stat_key']);assert k not in d.values or d.values[k]==row['sha256'];d.values[k]=row['sha256']
def bound(p,sha,size=None):
    p=Path(p);assert d.h(p)==sha,(str(p),'digest')
    if size is not None:assert p.stat().st_size==size

def private(p):
    p=Path(p);assert p.is_relative_to(TASK) and stat.S_IMODE(p.stat().st_mode)==0o600 and stat.S_IMODE(p.parent.stat().st_mode)==0o700
product_path=root/'doc/evidence/godot-space-experience-20261101/inputs/client-space-experience-product01-manifest.json'
bound(product_path,'4f7fbe270e975238edbc93e5b68d39949809d72033f8a078368a95d628233e0d')
product=load(product_path);cache(product['digest_cache'])
assert product['passed'] and product['trace_free'] and not product['diagnostic_overrides'] and not product['distributable']
assert product['supplied_inputs']==product['live_source_inputs'] and len(product['supplied_inputs'])==98
for n,h in product['live_source_inputs'].items():bound(root/n,h)
dist=Path(product['export_executable']).parent
for n,row in product['export_outputs'].items():bound(dist/n,row['sha256'],row['bytes'])
preparation=load(ev/'inputs/preparation-current-space-package-inputs01.json');cache(preparation['cache'])
assert preparation['source_inputs']==product['live_source_inputs']
for row in preparation['extras'].values():bound(row['path'],row['sha256'])
bound(preparation['extras_manifest'],preparation['extras_manifest_sha256'])
archives=[]
for label in ['private01','repro02']:
    receipt=load(ev/'inputs'/('current-space-package-'+label+'.json'))
    path=TASK/'artifacts'/('quod-space-linux-x86_64-'+label+'.tar.gz')
    archives.append({'path':str(path),**{k:receipt[k] for k in ['archive_sha256','archive_bytes','export_files','package_files','export_manifest_sha256']}})
    assert receipt['export_manifest_sha256']==d.h(product_path) and receipt['export_files']==196 and receipt['package_files']==207
assert archives[0]['archive_sha256']==archives[1]['archive_sha256'] and archives[0]['archive_bytes']==archives[1]['archive_bytes']
inspection=load(ev/'inputs/package-inspection01.json');cache(inspection['digest_cache'])
for archive in archives:bound(archive['path'],archive['archive_sha256'],archive['archive_bytes'])
assert inspection['passed'] and inspection['files']==207 and inspection['directory_count']==3
assert inspection['symbol_versions']['GLIBC']=='2.44' and len(inspection['elf_objects'])==16
bound(inspection['unchanged_elf_audit_reused']['path'],inspection['unchanged_elf_audit_reused']['sha256'])
extraction=Path(inspection['extracted']);index=load(extraction/'package-manifest.json')
assert index['files']==load(ev/'inputs/current-space-package-private01.json')['files']
assert set(index['files'])|{'package-manifest.json'}=={str(p.relative_to(extraction)) for p in extraction.rglob('*') if p.is_file()}
for n,row in index['files'].items():
    p=extraction/n;assert stat.S_ISREG(p.lstat().st_mode) and stat.S_IMODE(p.stat().st_mode)==row['mode'];bound(p,row['sha256'],row['bytes'])
assert all(index['files'][n]['sha256']==row['sha256'] for n,row in product['export_outputs'].items())
for row in product['dependency_archives'].values():bound(row['referenced_path'],row['sha256'])
bound(product['template']['path'],product['template']['sha256'])
ordinary=load(ev/'inputs/current-space-ordinary-launch01.json')
assert ordinary['passed'] and ordinary['true_exit']==ordinary['normal_close_exit']==0 and ordinary['packaged_coreclr_loaded']
assert ordinary['ordinary_launch'] and ordinary['mapped_window_observed'] and not ordinary['qualification_flag']
assert not ordinary['native_xr'] and not ordinary['reader_errors'] and not ordinary.get('owned_cleanup_required')
assert load(ev/'inputs/isolation-probe01.json')['passed']
for row in ordinary['streams'].values():private(row['path']);bound(row['path'],row['sha256'],row['bytes'])
companion_path=ev/'inputs/client-current-space-companion01-manifest.json';companion=load(companion_path);cache(companion['digest_cache'])
assert companion['passed'] and not companion['trace_free'] and not companion['distributable']
assert companion['live_source_inputs']==product['live_source_inputs'] and len(companion['supplied_inputs'])==99
assert set(companion['diagnostic_overrides'])=={'client/godot/tests/ExportChecks.cs','client/godot/tests/PackageJourneyChecks.cs'}
assert len(companion['commands'])==5 and all(c['true_exit']==0 for c in companion['commands'])
src=Path(companion['stage'])/'source';companion_dist=Path(companion['export_executable']).parent
for n,h in companion['supplied_inputs'].items():bound(src/n,h)
for n,row in companion['export_outputs'].items():bound(companion_dist/n,row['sha256'],row['bytes'])
journey_path=ev/'inputs/current-space-journey01.json';journey=load(journey_path);jprivate=TASK/'private/current-space-journey01'
assert journey['manifest_sha256']==d.h(companion_path) and journey['native_input_count']==0 and not journey['host_input_or_focus_action']
assert all(journey['eof'].values()) and not journey['reader_errors']
counts={};states={}
for phase in ['initial','reopen']:
    name='client-'+phase;child=journey['children'].get(name)
    if child is None:continue
    report_path=jprivate/'sandbox/work'/(phase+'.json')
    if not report_path.exists():continue
    report=load(report_path);assert report['passed'] and child['explicit_completion'];counts[phase]=len(report['checks'])
    rows=(jprivate/(name+'-stdout.raw')).read_text().splitlines();assert [l[5:] for l in rows if l.startswith('PASS ')]==report['checks']
    state=json.loads([l[len('M1B_STATE '):] for l in rows if l.startswith('M1B_STATE ')][-1])
    assert state['scene_count']==state['live_sockets']==0
    metrics=state['controller_metrics'];assert not metrics['Running'] and all(metrics[k]==0 for k in ['Subscriptions','sources','appearances','captures'])
    states[phase]={'scenes':0,'sockets':0,'subscriptions':0,'sources':0,'appearances':0,'captures':0,'XR':False}
for row in journey['streams'].values():
    private(row['path']);bound(row['path'],row['sha256'],row['bytes'])
    f=Path(row['path']);projection=b''.join(line if line.startswith((b'PASS ',b'M5_PACKAGE_JOURNEY_PASS')) else b'<private fixture/client diagnostic>\n' for line in f.read_bytes().splitlines(keepends=True))
    assert (ev/'logs'/('current-space-journey01-'+f.stem+'.log')).read_bytes()==projection
if journey['passed']:
    assert set(journey['children'])=={'server','client-initial','client-reopen'} and len(journey['eof'])==6
    assert all(c['true_exit']==0 for c in journey['children'].values()) and set(counts)=={'initial','reopen'}
    assert not journey.get('post_completion_trigger') and not journey.get('unretired_failure')
server=load(ev/'inputs/server-current-space-journey01-server.json')
assert server['child_exit']==0 and not server['runtime_recompiled'] and len(server['executed_current_sources'])==14
for n,row in server['executed_current_sources'].items():
    bound(row['saved_source'],row['sha256']);bound(root/n,row['sha256'])
    if 'compiled_object' in row:
        obj=row['compiled_object'];bound(obj['path'],obj['sha256'],obj['bytes'])
assert all(n in server['executed_current_sources'] for n in ['priv/ontologies/quod_gui.pl','priv/ontologies/gui_forms.pl','src/quod_client_view.erl'])
for row in server['driver_sources'].values():bound(row['path'],row['sha256'])
for n,row in server['affected_compiled_outputs'].items():bound(TASK/'private/quod-m4-live-current-space-journey01-server'/n,row['sha256'],row['bytes'])
wrappers={}
for p in sorted((ev/'logs').glob('*.json')):
    r=load(p);expected=0 if p.stem!='current-space-journey01' or journey['passed'] else 1
    assert r['child_exit']==expected and not r.get('timed_out')
    for row in r.get('private_streams',r.get('streams',{})).values():private(row['path']);bound(row['path'],row['sha256'],row['bytes'])
    wrappers[p.stem]={'true_exit':r['child_exit'],'receipt_sha256':d.h(p),'retained_failure':expected!=0}
for p in sorted(ev.glob('*/result.json')):
    r=load(p);assert r['exit']==0;bound(p.parent/'output.log',r['output_sha256']) if 'output_sha256' in r else d.h(p.parent/'output.log')
    wrappers[p.parent.name]={'true_exit':r['exit'],'receipt_sha256':d.h(p)}
fixture=load(ev/'inputs/current-space-package-checks01.json');assert fixture['passed'] and fixture['count']==9
recipe=load(ev/'inputs/launch-recipe.json');assert recipe['passed'] and recipe['nothing_launched'];bound(recipe['prepared'],recipe['sha256'])
prepared=load(recipe['prepared']);cache(prepared['digest_cache'])
assert prepared['fixture']['tty'] and prepared['client']['tty'] and prepared['nothing_launched']
for n,h in prepared['source_bindings'].items():bound(root/n,h)
assert prepared['participant_seconds']==1800 and prepared['normal_close_seconds']==60 and prepared['wrapper_seconds']==2100
parser=load(ev/'logs/current-space-launch-parser01.json');assert parser['child_exit']==0 and all(parser['eof'].values()) and parser['bound_seconds']==2100
n='client/godot-tools/package/README.txt';before=ev/'inputs/before'/n;after=root/n
assert stat.S_IMODE(before.stat().st_mode)==stat.S_IMODE(after.stat().st_mode)==0o644
diff=list(difflib.ndiff(before.read_text().splitlines(),after.read_text().splitlines()))
delta={n:{'before_path':str(before),'before_sha256':d.h(before),'after_sha256':d.h(after),'mode':0o644}}
assert delta[n]['before_sha256']!=delta[n]['after_sha256']
for issue in ['QUO-66','QUO-60','QUO-61']:assert not load(ev/'inputs'/('tracker-'+issue+'.json')).get('isError')
assert subprocess.check_output(['git','rev-parse','HEAD']).decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert not subprocess.check_output(['git','diff','--cached','--name-only'])
# Cumulative custody preserves every authenticated parent row, including pathless
# rows. This adds current measurements; it does not reread inherited objects.
cache_path=TASK/'cache/current-space-package-qualified01-hashes.json'
cache_path.write_text(json.dumps({'records':[{'stat_key':k,'sha256':v} for k,v in d.values.items()], 'parent_sha256':'521362799df476d93b9c0ecdd626a5d2864a384d162163dec7711f249a7a2394','new_digest_bytes':d.bytes,'new_digest_objects':d.new})+'\n')
result={'passed':journey['passed'],'evidence_verified':True,'package_passed':True,'full_M4_or_M5':False,'all_selected_cases_passed':journey['passed'],'current_journey_complete':journey['passed'],'reopen':'passed' if journey['passed'] else 'see literal journey receipt',
 'product':{'manifest':str(product_path),'sha256':d.h(product_path),'inputs':98,'exports':196,'export_bytes':sum(r['bytes'] for r in product['export_outputs'].values()),'application_inputs_changed':False,'rebuilt':False},
 'archives':archives,'extraction':inspection['extracted'],'ordinary_launch':{'client_exit':0,'wrapper_exit':0,'mapped_exact_owned_close':True,'own_CoreCLR':True,'instrumented':False},
 'companion':{'manifest':str(companion_path),'sha256':d.h(companion_path),'production_inputs':98,'supplied':99,'exports':196,'checks':counts,'whole_case_passed':journey['passed'],'post_completion_trigger':journey.get('post_completion_trigger'),'children':{n:c['true_exit'] for n,c in journey['children'].items()},'EOF':journey['eof'],'control_signals_and_software_native_pointer':True,'host_input':False,'final_states':states},
 'server_sources':server['executed_current_sources'],'server_runtime_rebuilt':False,'broader_evidence_reused':'accepted254 flow137/state27/composition64, affected owner2 and browser5; appearance236 and policy200 exact owners retained',
 'package_checks':9,'launch_recipe':recipe,'wrappers':wrappers,'run_labels':sorted(p.stem for p in (ev/'logs').glob('*.json')),'source_delta':delta,'line_delta':{'added':sum(l.startswith('+ ') for l in diff),'removed':sum(l.startswith('- ') for l in diff)},
 'retained_new_failures':[] if journey['passed'] else [journey.get('failure')],'historical_shutdown_fixed':False,'human_acceptance':False,'native_XR_or_host_input':False,
 'limits':['Private current-host package; GLIBC2.44 and matching world-name server/trust required.','Ordinary uninstrumented launch is separate from the signed software Control/native-pointer companion.','Normal exits do not identify or fix historical noEOF failures.','No full M5 release, retirement, deployment, cutover, human usability or headset acceptance.'],
 'digest_cache':{'path':str(cache_path),'sha256':raw(cache_path)}}
(ev/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'evidence_verified':True,'package_passed':True,'current_journey_complete':journey['passed'],'archive':archives[0],'journey_checks':counts,'source_delta':result['line_delta'],'shutdown_fixed':False}))
