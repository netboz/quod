"""Bind this finite caller/UI checkpoint to actual inputs, outcomes and custody."""
import argparse,json,os,shutil,stat,subprocess
from pathlib import Path
from hashes import TASK,Digests,raw
os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
p=argparse.ArgumentParser()
for name in ['label','product','diagnostic','full','source','numbers','workspace','context']:p.add_argument('--'+name,required=True)
a=p.parse_args();dest=TASK/'private'/a.label;dest.mkdir(mode=0o700,exist_ok=False)
for f in [Path(__file__).resolve(),ev/'hashes.py']:shutil.copy2(f,dest/f.name)
def load(p):return json.loads(p.read_text())
def cache(ref):
    p=Path(ref['path']);assert raw(p)==ref['sha256']
    for r in load(p)['records']:
        k=tuple(r['stat_key']);assert k not in d.values or d.values[k]==r['sha256'];d.values[k]=r['sha256']
manifests={};builds={}
for path in sorted((ev/'inputs').glob('client-*-manifest.json')):
    m=load(path);cache(m['digest_cache']);stage=Path(m['stage']);source=stage/'source';label=stage.name.removeprefix('client-')
    assert not m['compiled_application_inputs_copied']
    assert all(d.h(source/n)==h for n,h in m['supplied_inputs'].items())
    for r in m['dependency_archives'].values():assert d.h(Path(r['referenced_path']))==r['sha256']
    assert d.h(Path(m['template']['path']))==m['template']['sha256']
    if m['passed']:
        assert len(m['commands'])==5 and all(c['true_exit']==0 for c in m['commands'])
        dist=Path(m['export_executable']).parent
        assert len(m['export_outputs'])==196 and set(m['export_outputs'])=={str(f.relative_to(dist)) for f in dist.rglob('*') if f.is_file()}
        for n,r in m['export_outputs'].items():assert d.h(dist/n)==r['sha256'] and (dist/n).stat().st_size==r['bytes']
    manifests[label]=m;builds[label]={'path':str(path),'sha256':d.h(path),'passed':m['passed'],'supplied':len(m['supplied_inputs']),'live':len(m['live_source_inputs']),'phase_exits':[c.get('true_exit') for c in m['commands']]}
product=manifests[a.product];diagnostic=manifests[a.diagnostic]
assert product['passed'] and product['trace_free'] and not product['diagnostic_overrides']
assert diagnostic['passed'] and not diagnostic['trace_free'] and not diagnostic['distributable']
assert product['supplied_inputs']==product['live_source_inputs']==diagnostic['live_source_inputs']
assert len(product['live_source_inputs'])==98 and len(diagnostic['supplied_inputs'])==101
assert all(d.h(root/n)==h for n,h in product['live_source_inputs'].items())
assert set(diagnostic['diagnostic_overrides'])=={'client/godot/tests/'+n for n in ['ExportChecks.cs','OnboardingChecks.cs','OnboardingJourney.cs','OnboardingSource.cs']}
wrappers={}
for receipt in sorted(ev.glob('*/result.json')):
    r=load(receipt)
    if 'exit' in r:
        assert type(r['exit']) is int
        wrappers[receipt.parent.name]={'true_exit':r['exit'],'diagnostic_failure':r.get('diagnostic_failure'),'receipt_sha256':d.h(receipt),'log_sha256':d.h(receipt.parent/'output.log')}
def streams(record):
    for r in record['streams'].values():
        p=Path(r.get('path',r.get('raw_path')))
        assert p.is_relative_to(TASK) and stat.S_IMODE(p.stat().st_mode)==0o600 and stat.S_IMODE(p.parent.stat().st_mode)==0o700
        assert d.h(p)==r['sha256'] and p.stat().st_size==r['bytes']
def bound(record):
    label=next(n for n,r in builds.items() if r['sha256']==record['manifest_sha256']);m=manifests[label]
    delta={n for n,h in m['live_source_inputs'].items() if product['live_source_inputs'].get(n)!=h}
    assert delta<={'client/godot/README.md','client/godot/tests/WorkspaceChecks.cs','client/godot/OperationsPanel.cs'},delta
    if 'client/godot/OperationsPanel.cs' in delta:
        old=(Path(m['stage'])/'source/client/godot/OperationsPanel.cs').read_text();new=(root/'client/godot/OperationsPanel.cs').read_text()
        begin=new.index('    void Initialize(SignedSession session, Accounts accounts)');end=new.index('    void SetBusy',begin)
        old_begin=old.index('    void Initialize(SignedSession session, Accounts accounts)');old_end=old.index('    void SetBusy',old_begin)
        assert new[:begin]+old[old_begin:old_end]+new[end:]==old
        assert 'this.session.Network!=session.Network || this.session.Key.PublicText!=session.Key.PublicText || human!=accounts.Human' in new[begin:end]
    if 'client/godot/tests/WorkspaceChecks.cs' in delta:
        old=(Path(m['stage'])/'source/client/godot/tests/WorkspaceChecks.cs').read_text().splitlines();new=(root/'client/godot/tests/WorkspaceChecks.cs').read_text().splitlines()
        assert len(old)==len(new) and sum(x!=y for x,y in zip(old,new))==1
        assert all(x==y or ('create-key' in x and 'offline spatial presentation retains its required key action' in y) for x,y in zip(old,new))
    return label,sorted(delta)
selected={}
for role,label in [('numbers',a.numbers),('workspace',a.workspace),('context',a.context)]:
    path=ev/label/'result.json';r=load(path)
    assert r['passed'] and r['explicit_completion'] and r['client_report_passed'] and not r['diagnostics'] and not r['reader_errors']
    assert all(r['eof'].values()) and [c['true_exit'] for c in r['children'].values()]==[0]
    assert not r['physical'] and not r['native_runtime_started'] and not r['hardware_queried'] and not r['display_or_focus_action']
    executed,delta=bound(r);streams(r)
    selected[role]={'label':label,'checks':len(r['checks']),'executed_manifest':executed,'later_input_differences':delta,'receipt_sha256':d.h(path),'true_exits':[0],'EOF':r['eof']}
for role,label in [('full',a.full),('source',a.source)]:
    path=ev/'inputs'/(label+'.json');r=load(path)
    # Preserve whole failures. Their completed functional observations are not
    # normal-exit qualification and cannot make the original wrapper pass.
    assert not r['passed'] and r['unretired_failure'] and r['failure']=='Empty: '
    expected={'server':0,'client-onboarding-source':-15} if role=='source' else {'server':0,'client-onboarding-full':0,'client-onboarding-return':0,'client-onboarding-import':0,'client-onboarding-unallocated':-15}
    assert {n:c['true_exit'] for n,c in r['children'].items()}==expected
    assert all(r['eof'].values()) and not r['reader_errors']
    assert not r['host_input_or_focus_action'] and r['native_input_count']==0
    executed,delta=bound(r);streams(r);reports={}
    for name,child in r['children'].items():
        if name=='server':continue
        assert child['explicit_completion'];phase=name.removeprefix('client-');report=TASK/'private'/label/'sandbox/work'/(phase+'.json')
        value=load(report);assert value['passed'];reports[phase]={'checks':len(value['checks']),'report_sha256':d.h(report)}
    if role=='full':assert set(reports)=={'onboarding-full','onboarding-return','onboarding-import','onboarding-unallocated'}
    if role=='source':
        assert set(reports)=={'onboarding-source'}
        work=TASK/'private'/label/'sandbox/work/unchanged-work.json';assert load(work)['work']['calls']==[];d.h(work)
    selected[role]={'label':label,'reports':reports,'whole_case_passed':False,'normal_exit_qualified':False,'failure':r['failure'],'unretired_failure':True,'executed_manifest':executed,'later_input_differences':delta,'receipt_sha256':d.h(path),'true_exits':{n:c['true_exit'] for n,c in r['children'].items()},'EOF_after_owned_cleanup':r['eof'],'host_input_count':0}
    server=load(ev/'inputs'/('server-'+label+'-server.json'))
    assert server['child_exit']==0 and not server['runtime_recompiled'] and len(server['executed_current_sources'])==12
    assert d.h(Path(server['clean_source_binding']['path']))==server['clean_source_binding']['sha256']
    for n,s in server['executed_current_sources'].items():
        assert d.h(root/n)==s['sha256']==d.h(Path(s['saved_source']))
        if 'compiled_object' in s:
            obj=s['compiled_object'];assert d.h(Path(obj['path']))==obj['sha256'] and Path(obj['path']).stat().st_size==obj['bytes']
    for s in server['driver_sources'].values():assert d.h(Path(s['path']))==s['sha256']
    private=TASK/'private'/('quod-m4-live-'+label+'-server')
    for n,s in server['affected_compiled_outputs'].items():assert d.h(private/n)==s['sha256'] and (private/n).stat().st_size==s['bytes']
    for image in (TASK/'private'/label/'sandbox/work').glob('*.png'):d.h(image)
delta={};counts={}
for n,r in load(ev/'inputs/before.json').items():
    before=root/r['copy'];assert d.h(before)==r['sha256'] and before.stat().st_mode==r['mode']
    after=d.h(root/n)
    if after==r['sha256']:continue
    delta[n]={'before_path':str(before),'before_sha256':r['sha256'],'after_sha256':after,'full_mode':(root/n).stat().st_mode}
    result=subprocess.run(['git','diff','--no-index','--numstat',str(before),n],capture_output=True,text=True);assert result.returncode==1
    added,removed=map(int,result.stdout.split('\t')[:2]);counts[n]={'added':added,'removed':removed}
assert set(delta)==set(load(ev/'inputs/before.json'))
assert subprocess.run(['git','diff','--check']).returncode==0 and not subprocess.check_output(['git','diff','--cached','--name-only'])
d.write(dest/'computed-hashes.json')
q={'passed':True,'verification_kind':'exact source/evidence custody and bounded functional observations; original failed cases stay failed','all_selected_cases_passed':False,'current_rendered_retirement_qualified':False,'full_M4_or_M5':False,'full_QUO62_or_human_acceptance':False,'worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','actual_model':'openai-codex:gpt-6-astra','effective_backend_effort':'unexposed',
   'product':builds[a.product],'diagnostic':builds[a.diagnostic],'builds':builds,'selected':selected,'true_wrapper_outcomes':wrappers,'source_delta':delta,'line_delta':counts,
   'old_package_rebuilt':False,'old_API_bytes_read':0,'commit_or_push':False,'review_started':False,'source_sharing_consent':'coordinator-owned; pending at last instruction',
   'server':'unchanged accepted policy/wire/space owners; existing TEST fixture option returns a real60000ms authenticated session expiry; production default unchanged',
   'input_scope':'real native-Control pointer/keyboard software events and setup/selector signals; zero host input or native XR',
   'limits':['unallocated-import and source rendered cases complete behavior but fail their original60s EOF guard; client-15 is not normal exit','baseline reflection expiry is simulated client expiry only','unwritten generic drafts survive this window, not process restart','durably signed never-sent original-work seam is not an admitted uncertain server write','context isolation gate uses normalized native presentation fixtures, not authenticated domain commits','backup/import and recovery after signed mapping withdrawal remain desktop-only','human usability and historical shutdown cause/fix remain unqualified'],
   'digest_cache':{'path':str(dest/'computed-hashes.json'),'sha256':raw(dest/'computed-hashes.json')}}
(ev/'result.json').write_text(json.dumps(q,indent=2)+'\n')
print(json.dumps({'qualified':True,'selected':selected,'changed_sources':len(delta),'line_delta':counts}))
