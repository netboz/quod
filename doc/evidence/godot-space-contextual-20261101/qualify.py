"""Bind the contextual presentation delta to its real signed/native evidence."""
import argparse,json,os,shutil,stat
from pathlib import Path
from hashes import TASK,Digests,raw
os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
p=argparse.ArgumentParser()
for name in ['label','product','diagnostic','run','entry']:p.add_argument('--'+name,required=True)
a=p.parse_args();dest=TASK/'private'/a.label;dest.mkdir(mode=0o700,exist_ok=False)
for f in [Path(__file__).resolve(),ev/'hashes.py']:shutil.copy2(f,dest/f.name)
def load(p):return json.loads(p.read_text())
def cache(ref):
    p=Path(ref['path']);assert raw(p)==ref['sha256']
    for r in load(p)['records']:
        key=tuple(r['stat_key']);assert key not in d.values or d.values[key]==r['sha256'];d.values[key]=r['sha256']
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
assert set(diagnostic['diagnostic_overrides'])=={'client/godot/tests/ExportChecks.cs','client/godot/tests/ContextualChecks.cs'}
assert all(d.h(root/n)==h for n,h in product['live_source_inputs'].items())
later={n for n,h in diagnostic['live_source_inputs'].items() if product['live_source_inputs'][n]!=h}
assert later<={'client/godot/README.md'},later
wrappers={}
for receipt in sorted(ev.glob('*/result.json')):
    r=load(receipt)
    if 'exit' in r:
        assert type(r['exit']) is int
        wrappers[receipt.parent.name]={'true_exit':r['exit'],'diagnostic_failure':r.get('diagnostic_failure'),'receipt_sha256':d.h(receipt),'log_sha256':d.h(receipt.parent/'output.log')}
cases={}
for path in sorted((ev/'inputs').glob('contextual-*.json')):
    r=load(path)
    if 'streams' not in r:continue
    label=path.stem;private=TASK/'private'/label
    assert all(r['eof'].values()) and not r['reader_errors']
    assert not r['host_input_or_focus_action'] and r['native_input_count']==0 and r['production_auth_lifetime_unchanged']
    assert r['manifest_sha256'] in {b['manifest_sha256'] for b in builds.values()}
    for name,s in r['streams'].items():
        f=Path(s['path']);assert f.is_relative_to(TASK) and stat.S_IMODE(f.stat().st_mode)==0o600 and stat.S_IMODE(f.parent.stat().st_mode)==0o700
        assert d.h(f)==s['sha256'] and f.stat().st_size==s['bytes']
        projected=b''.join(line if line.startswith((b'PASS ',b'CONTEXTUAL_PASS')) else b'<private fixture/client diagnostic>\n' for line in f.read_bytes().splitlines(keepends=True))
        public=ev/'logs'/(label+'-'+f.stem+'.log');assert public.read_bytes()==projected;d.h(public)
    for f in (private/'drivers').iterdir():d.h(f)
    for f in (private/'sandbox/work').glob('*.png'):d.h(f)
    client=next(n for n in r['children'] if n!='server');phase=client.removeprefix('client-')
    checks=[line[5:] for line in (private/(client+'-stdout.raw')).read_text().splitlines() if line.startswith('PASS ')]
    cases[label]={'passed':r['passed'],'checks':checks,'exits':{n:c['true_exit'] for n,c in r['children'].items()},'EOF':r['eof'],'receipt_sha256':d.h(path),'manifest_sha256':r['manifest_sha256'],'unretired_failure':r.get('unretired_failure',False),'failure':r.get('failure')}
    if label in [a.run,a.entry]:
        assert r['passed'] and r['children'][client]['explicit_completion'] and all(c['true_exit']==0 for c in r['children'].values())
        assert r['manifest_sha256']==builds[a.diagnostic]['manifest_sha256']
        report=private/'sandbox/work'/(phase+'.json');value=load(report);assert value['passed'] and value['checks']==checks;d.h(report)
    if label==a.run:
        cost=private/'sandbox/work/unchanged-work.json';assert load(cost)['work']['calls']==[];d.h(cost)
    server=load(ev/'inputs'/('server-'+label+'-server.json'))
    assert server['child_exit']==0 and not server['runtime_recompiled'] and len(server['executed_current_sources'])==12
    assert d.h(Path(server['clean_source_binding']['path']))==server['clean_source_binding']['sha256']
    for n,s in server['executed_current_sources'].items():
        assert d.h(root/n)==s['sha256']==d.h(Path(s['saved_source']))
        if 'compiled_object' in s:
            obj=s['compiled_object'];assert d.h(Path(obj['path']))==obj['sha256'] and Path(obj['path']).stat().st_size==obj['bytes']
    for s in server['driver_sources'].values():assert d.h(Path(s['path']))==s['sha256']
    server_private=TASK/'private'/('quod-m4-live-'+label+'-server')
    for n,s in server['affected_compiled_outputs'].items():assert d.h(server_private/n)==s['sha256'] and (server_private/n).stat().st_size==s['bytes']
assert cases[a.run]['passed'] and cases[a.entry]['passed']
assert not cases['contextual-baseline01']['passed'] and cases['contextual-baseline01']['exits']=={'server':0,'client-contextual':1}
assert wrappers['contextual-candidate02-build']['true_exit']==1
delta={};counts={}
for n,r in load(ev/'inputs/before.json').items():
    before=root/r['copy'];after=root/n;assert d.h(before)==r['sha256'] and stat.S_IMODE(before.stat().st_mode)==r['mode']
    if d.h(after)==r['sha256']:continue
    assert stat.S_IMODE(after.stat().st_mode)==r['mode']
    import difflib
    changes=list(difflib.ndiff(before.read_text().splitlines(),after.read_text().splitlines()))
    counts[n]={'added':sum(x.startswith('+ ') for x in changes),'removed':sum(x.startswith('- ') for x in changes)}
    delta[n]={'before_path':str(before),'before_sha256':r['sha256'],'after_sha256':d.h(after),'mode':r['mode']}
d.write(dest/'computed-hashes.json')
q={'passed':True,'full_M4_or_M5':False,'all_selected_cases_passed':True,'product':builds[a.product],'diagnostic':builds[a.diagnostic],'selected_run':a.run,'selected_entry':a.entry,'selected_checks':len(cases[a.run]['checks']),'selected_current_doc_only_delta':sorted(later),'builds':builds,'cases':cases,'wrappers':wrappers,'source_delta':delta,'line_delta':counts,'native_XR_or_host_input':False,'human_acceptance':False,'historical_shutdown_fixed':False,'limits':['Actual native Control input in a disposable signed software fixture; no host input or human test.','Baseline native-choice existence is distinct from later actual clipping and raster checks.','Ontology identity remains separate from spatial membership; broader founding/D5/D6/terrain remain outside this slice.','Current normal retirement does not explain or fix prior whole failed no-EOF labels.','Appearance tokens and human headset ergonomics remain unqualified.'],'digest_cache':{'path':str(dest/'computed-hashes.json'),'sha256':raw(dest/'computed-hashes.json')}}
(ev/'result.json').write_text(json.dumps(q,indent=2)+'\n')
print(json.dumps({'qualified':True,'run':a.run,'checks':q['selected_checks'],'changed_sources':len(delta),'line_delta':counts}))
