"""Bind authored appearance to its real signed/native owners and exact inputs."""
import argparse,atexit,json,os,shutil,stat
from pathlib import Path
from hashes import TASK,Digests,raw
os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
p=argparse.ArgumentParser()
for name in ['label','product','diagnostic','run']:p.add_argument('--'+name,required=True)
p.add_argument('--additional',action='append',default=[],help='selected case=diagnostic build')
p.add_argument('--prior-cache',nargs=2,metavar=('PATH','SHA256'))
a=p.parse_args();selected={a.run:a.diagnostic,**dict(item.split('=',1) for item in a.additional)};dest=TASK/'private'/a.label;dest.mkdir(mode=0o700,exist_ok=False)
for f in [Path(__file__).resolve(),ev/'hashes.py']:shutil.copy2(f,dest/f.name)
atexit.register(lambda:d.write(dest/'completed-prefix-hashes.json'))
def load(p):return json.loads(p.read_text())
def cache(ref):
    p=Path(ref['path']);assert raw(p)==ref['sha256']
    for r in load(p)['records']:
        key=tuple(r['stat_key']);assert key not in d.values or d.values[key]==r['sha256'];d.values[key]=r['sha256']
if a.prior_cache:cache({'path':a.prior_cache[0],'sha256':a.prior_cache[1]})
def lens_only(before,after):
    def non_lens(source):
        begin=source.index('    async Task ReadLens(');end=source.index('    void AddPredicate()',begin)
        source=source[:begin]+'    // Separately qualified computed-lens body.\n'+source[end:]
        source=source.replace('if(!nextLens&&ReferenceEquals(this.session,session)', 'if(ReferenceEquals(this.session,session)')
        retain=[line for line in source.splitlines(keepends=True) if line.startswith('        bool retainLens=nextLens&&')]
        assert len(retain)<=1
        for line in retain:source=source.replace(line,'')
        source=source.replace('Withdraw(retainLens);this.session=session;', 'Withdraw();this.session=session;')
        return source
    return non_lens(before)==non_lens(after)
manifests={};builds={}
for path in sorted((ev/'inputs').glob('client-*-manifest.json')):
    m=load(path);cache(m['digest_cache']);stage=Path(m['stage']);src=stage/'source';label=stage.name.removeprefix('client-')
    assert not m['compiled_application_inputs_copied']
    assert all(d.h(src/n)==h for n,h in m['supplied_inputs'].items())
    for r in m['dependency_archives'].values():assert d.h(Path(r['referenced_path']))==r['sha256']
    assert d.h(Path(m['template']['path']))==m['template']['sha256']
    if m['passed']:
        assert len(m['commands'])==5 and all(c['true_exit']==0 for c in m['commands'])
        dist=Path(m['export_executable']).parent
        assert len(m['export_outputs'])==196 and set(m['export_outputs'])=={str(f.relative_to(dist)) for f in dist.rglob('*') if f.is_file()}
        for n,r in m['export_outputs'].items():assert d.h(dist/n)==r['sha256'] and (dist/n).stat().st_size==r['bytes']
    manifests[label]=m;builds[label]={'manifest_sha256':d.h(path),'passed':m['passed'],'supplied':len(m['supplied_inputs']),'live':len(m['live_source_inputs']),'phase_exits':[c.get('true_exit') for c in m['commands']]}
product=manifests[a.product];diagnostic=manifests[a.diagnostic]
assert product['passed'] and product['trace_free'] and not product['diagnostic_overrides']
assert diagnostic['passed'] and not diagnostic['trace_free'] and not diagnostic['distributable']
assert len(product['live_source_inputs'])==98 and product['supplied_inputs']==product['live_source_inputs']
assert len(diagnostic['supplied_inputs'])==99
assert set(diagnostic['diagnostic_overrides'])=={'client/godot/tests/ExportChecks.cs','client/godot/tests/AppearanceChecks.cs'}
assert all(d.h(root/n)==h for n,h in product['live_source_inputs'].items())
parent=load(root/'doc/evidence/godot-workbench-usability-20261101/inputs/client-workbench-ux-product01-manifest.json')
product_delta={n for n,h in product['live_source_inputs'].items() if parent['live_source_inputs'][n]!=h}
assert product_delta=={n for n in load(ev/'inputs/before.json') if n in product['live_source_inputs'] and product['live_source_inputs'][n]!=parent['live_source_inputs'][n]}
later={n for n,h in diagnostic['live_source_inputs'].items() if product['live_source_inputs'][n]!=h}
assert later<={'client/godot/README.md','client/godot/SourcePanel.cs','client/godot/FormPanel.cs'},later
wrappers={}
for receipt in sorted(ev.glob('*/result.json')):
    r=load(receipt)
    if 'exit' in r:
        assert type(r['exit']) is int
        wrappers[receipt.parent.name]={'true_exit':r['exit'],'diagnostic_failure':r.get('diagnostic_failure'),'receipt_sha256':d.h(receipt),'log_sha256':d.h(receipt.parent/'output.log')}
for receipt in sorted((ev/'logs').glob('*.json')):
    r=load(receipt)
    if 'child_exit' not in r:continue
    assert type(r['child_exit']) is int
    for group in ['private_streams','sanitized_streams']:
        for value in r[group].values():
            path=Path(value['path']);assert d.h(path)==value['sha256'] and path.stat().st_size==value['bytes']
    wrappers[receipt.stem]={'true_exit':r['child_exit'],'timed_out':r['timed_out'],'receipt_sha256':d.h(receipt)}
cases={}
for path in sorted((ev/'inputs').glob('appearance-*.json')):
    r=load(path)
    if 'streams' not in r:continue
    label=path.stem;private=TASK/'private'/label
    assert all(r['eof'].values()) and not r['reader_errors']
    assert not r['host_input_or_focus_action'] and r['native_input_count']==0 and r['production_auth_lifetime_unchanged']
    assert r['manifest_sha256'] in {b['manifest_sha256'] for b in builds.values()}
    for name,s in r['streams'].items():
        f=Path(s['path']);assert f.is_relative_to(TASK) and stat.S_IMODE(f.stat().st_mode)==0o600 and stat.S_IMODE(f.parent.stat().st_mode)==0o700
        assert d.h(f)==s['sha256'] and f.stat().st_size==s['bytes']
        projected=b''.join(line if line.startswith((b'PASS ',b'APPEARANCE_PASS')) else b'<private fixture/client diagnostic>\n' for line in f.read_bytes().splitlines(keepends=True))
        public=ev/'logs'/(label+'-'+f.stem+'.log');assert public.read_bytes()==projected;d.h(public)
    for f in (private/'drivers').iterdir():d.h(f)
    for f in (private/'sandbox/work').glob('*.png'):d.h(f)
    client=next((n for n in r['children'] if n!='server'),None);phase=client.removeprefix('client-') if client else ''
    checks=[line[5:] for line in (private/(client+'-stdout.raw')).read_text().splitlines() if line.startswith('PASS ')] if client else []
    cases[label]={'passed':r['passed'],'checks':checks,'exits':{n:c['true_exit'] for n,c in r['children'].items()},'EOF':r['eof'],'receipt_sha256':d.h(path),'manifest_sha256':r['manifest_sha256'],'unretired_failure':r.get('unretired_failure',False),'failure':r.get('failure')}
    if label in selected:
        assert r['passed'] and r['children'][client]['explicit_completion'] and all(c['true_exit']==0 for c in r['children'].values())
        assert r['manifest_sha256']==builds[selected[label]]['manifest_sha256']
        vector=manifests[selected[label]]['live_source_inputs'];delta={n for n,h in vector.items() if product['live_source_inputs'][n]!=h};assert delta<={'client/godot/README.md','client/godot/SourcePanel.cs','client/godot/FormPanel.cs'}
        if 'client/godot/SourcePanel.cs' in delta:
            staged=Path(manifests[selected[label]]['stage'])/'source/client/godot/SourcePanel.cs';assert lens_only(staged.read_text(),(root/'client/godot/SourcePanel.cs').read_text())
            assert phase not in ('appearance-inspection','appearance-lens-dependency');cases[label]['reuse_limit']='SourcePanel changes only the separately qualified readonly ReadLens branch and lens-only hidden retention; this case does not select an inspection lens.'
        if 'client/godot/FormPanel.cs' in delta:
            before=(Path(manifests[selected[label]]['stage'])/'source/client/godot/FormPanel.cs').read_text();after=(root/'client/godot/FormPanel.cs').read_text()
            line='        Descriptor=null!;\n';assert after.count(line)==1 and after.replace(line,'')==before
            cases[label]['cleared_form_reuse_limit']='Only clearing Descriptor when removing controls differs; the selected current independence/retirement gate covers that demonstrated callback defect.'
        cases[label]['current_input_delta']=sorted(delta)
        report=private/'sandbox/work'/(phase+'.json');value=load(report);assert value['passed'] and value['checks']==checks;d.h(report)
    if label==a.run:
        cost=private/'sandbox/work/unchanged-work.json';assert load(cost)['work']['calls']==[];d.h(cost)
    server_path=ev/'inputs'/('server-'+label+'-server.json')
    if not server_path.exists():
        assert not r['passed'] and client is None;continue
    server=load(server_path)
    if server['child_exit']!=0:
        assert not r['passed'] and client is None;continue
    assert server['child_exit']==0 and not server['runtime_recompiled']
    assert len(server['executed_current_sources']) in ([14] if label in selected else [13,14]),label
    assert d.h(Path(server['clean_source_binding']['path']))==server['clean_source_binding']['sha256']
    for n,s in server['executed_current_sources'].items():
        assert s['sha256']==d.h(Path(s['saved_source']))
        if label in selected:assert d.h(root/n)==s['sha256']
        if 'compiled_object' in s:
            obj=s['compiled_object'];assert d.h(Path(obj['path']))==obj['sha256'] and Path(obj['path']).stat().st_size==obj['bytes']
    for s in server['driver_sources'].values():assert d.h(Path(s['path']))==s['sha256']
    server_private=TASK/'private'/('quod-m4-live-'+label+'-server')
    for n,s in server['affected_compiled_outputs'].items():assert d.h(server_private/n)==s['sha256'] and (server_private/n).stat().st_size==s['bytes']
assert all(cases[n]['passed'] for n in selected)
assert manifests['appearance-lens-dependency-baseline14']['supplied_inputs']['client/godot/tests/AppearanceChecks.cs']==manifests['appearance-lens-dependency-final15']['supplied_inputs']['client/godot/tests/AppearanceChecks.cs']
lens_baseline=load(TASK/'private/appearance-lens-dependency-baseline14/sandbox/work/lens-dependency.json');assert lens_baseline['sameTargetVersion'] and lens_baseline['sameEditor'] and lens_baseline['sameText'] and not lens_baseline['expected']
lens_final=load(TASK/'private/appearance-lens-dependency-final15/sandbox/work/lens-dependency.json');assert lens_final['sameTargetVersion'] and lens_final['sameEditor'] and not lens_final['sameText'] and lens_final['expected']
assert not cases['appearance-lens-dependency-baseline14']['passed'] and cases['appearance-lens-dependency-final15']['passed']
measured=load(TASK/'private/appearance-inspection-final16/sandbox/work/inspection-unchanged-work.json')
assert measured['work']['work']['calls']==[] and measured['writes']==0 and measured['textChanges']==0 and measured['sameStyle'] and measured['readsAfter']==measured['readsBefore']+1
independent=load(TASK/'private/appearance-retirement-final17/sandbox/work/independent-current.json');assert independent['refusalValue']=='[]' and independent['available'] and independent['sameControl']
assert cases['appearance-retirement-final17']['passed'] and not cases['appearance-independence-final15']['passed']

assert not cases['appearance-baseline03']['passed'] and cases['appearance-baseline03']['exits']=={'server':0,'client-appearance':1}
assert wrappers['appearance-baseline03-run']['true_exit']==1
browser=load(ev/'inputs/appearance-browser-bound02.json');assert browser['passed'] and browser['true_exit']==0 and browser['only_retained_sources_executed']
cache(browser['digest_cache'])
for n,r in browser['source_inputs'].items():
    assert d.h(Path(r['path']))==r['sha256']
    current=(ev/n if n in ['browser-check.mjs','browser.py'] else root/n);assert d.h(current)==r['sha256']
assert wrappers['appearance-browser-bound02-run']['true_exit']==0
delta={};counts={}
for n,r in load(ev/'inputs/before.json').items():
    before=root/r['copy'];after=root/n;assert d.h(before)==r['sha256'] and before.stat().st_mode==r['mode']
    if d.h(after)==r['sha256']:continue
    assert after.stat().st_mode==r['mode']
    import difflib
    changes=list(difflib.ndiff(before.read_text().splitlines(),after.read_text().splitlines()))
    counts[n]={'added':sum(x.startswith('+ ') for x in changes),'removed':sum(x.startswith('- ') for x in changes)}
    delta[n]={'before_path':str(before),'before_sha256':r['sha256'],'after_sha256':d.h(after),'mode':r['mode']}
d.write(dest/'computed-hashes.json')
q={'passed':True,'full_M4_or_M5':False,'all_selected_cases_passed':True,'product':builds[a.product],'diagnostic':builds[a.diagnostic],'selected_run':a.run,'selected_cases':selected,'selected_case_checks':{n:len(cases[n]['checks']) for n in selected},'selected_checks':len(cases[a.run]['checks']),'selected_current_input_delta':sorted(later),'changed_product_inputs':sorted(product_delta),'builds':builds,'cases':cases,'wrappers':wrappers,'source_delta':delta,'line_delta':counts,'native_XR_or_host_input':False,'human_acceptance':False,'historical_shutdown_fixed':False,'new_context_source_paths':['nimbalyst-local/handoffs/godot-gui-authored-appearance-236.md','nimbalyst-local/handoffs/godot-gui-authored-appearance-result-236.md'],'browser_bound_case':browser,'limits':['Actual native Control input in a disposable signed software fixture; no host input or human test.','Real signed ontology and native-Control evidence; physical headset comfort is unqualified.','Ontology identity remains separate from spatial membership; broader founding/D5/D6/terrain remain outside this slice.','Current normal retirement does not explain or fix prior whole failed no-EOF labels.','Authored tokens are native Godot scope; the existing browser explicitly refuses non-inherit declarations.'],'digest_cache':{'path':str(dest/'computed-hashes.json'),'sha256':raw(dest/'computed-hashes.json')}}
(ev/'result.json').write_text(json.dumps(q,indent=2)+'\n')
print(json.dumps({'qualified':True,'run':a.run,'checks':q['selected_checks'],'changed_sources':len(delta),'line_delta':counts}))
