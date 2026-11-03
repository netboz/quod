"""Bind selected current space gates and retain every earlier label literally."""
import argparse,difflib,json,os,shutil,stat,subprocess
from pathlib import Path
from hashes import TASK,Digests,raw,key
os.umask(0o077)
p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('product');p.add_argument('flow');p.add_argument('state');p.add_argument('presentation');a=p.parse_args()
root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests();dest=TASK/'private'/a.label;dest.mkdir(mode=0o700,exist_ok=False)
for f in [Path(__file__),ev/'hashes.py']:shutil.copy2(f,dest/f.name)
def load(p):return json.loads(Path(p).read_text())
def cache(ref):
    p=Path(ref['path']);assert raw(p)==ref['sha256']
    for r in load(p)['records']:
        k=tuple(r['stat_key']);assert k not in d.values or d.values[k]==r['sha256'];d.values[k]=r['sha256']
def bound(p,h,size=None,inherited=False):
    p=Path(p)
    if inherited:assert key(p) in d.values,('inherited custody missing',str(p))
    assert d.h(p)==h,str(p)
    if size is not None:assert p.stat().st_size==size
def private(p):
    p=Path(p);assert p.is_relative_to(TASK) and stat.S_IMODE(p.stat().st_mode)==0o600 and stat.S_IMODE(p.parent.stat().st_mode)==0o700
parent_path=root/'doc/evidence/godot-authored-appearance-20261101/inputs/client-appearance-product03-manifest.json'
bound(parent_path,'2fc8ea3a1326ccc9c211c2b9bdb285bc872cc82e890d71eae3880de84de35f2f',inherited=True);parent=load(parent_path)
manifests={};builds={}
for path in sorted((ev/'inputs').glob('client-*-manifest.json')):
    m=load(path);manifests[d.h(path)]=(path,m);cache(m['digest_cache']);stage=Path(m['stage']);src=stage/'source'
    for n,h in m['supplied_inputs'].items():bound(src/n,h)
    assert m['template']==parent['template'] and m['dependency_archives']==parent['dependency_archives']
    assert not m['compiled_application_inputs_copied'] and not m['distributable']
    if m['passed']:
        assert len(m['commands'])==5 and all(c['true_exit']==0 for c in m['commands']) and len(m['export_outputs'])==196
        dist=Path(m['export_executable']).parent
        for n,r in m['export_outputs'].items():bound(dist/n,r['sha256'],r['bytes'])
    builds[stage.name]={'passed':m['passed'],'phases':[c.get('true_exit') for c in m['commands']],'manifest_sha256':d.h(path),'supplied':len(m['supplied_inputs']),'live':len(m['live_source_inputs'])}
product_path=ev/'inputs'/('client-'+a.product+'-manifest.json');product=load(product_path)
assert product['passed'] and product['trace_free'] and not product['diagnostic_overrides'] and product['live_source_inputs']==product['supplied_inputs']
for n,h in product['live_source_inputs'].items():bound(root/n,h)
bound(product['template']['path'],product['template']['sha256'],inherited=True)
for r in product['dependency_archives'].values():bound(r['referenced_path'],r['sha256'],inherited=True)
wrappers={}
for path in sorted((ev/'logs').glob('*.json')):
    r=load(path)
    if 'driver_inputs' not in r:continue
    label=path.stem
    for n,h in r['driver_inputs'].items():bound(TASK/'private/runs'/label/'driver-inputs'/n,h)
    for row in r['private_streams'].values():private(row['path']);bound(row['path'],row['sha256'],row['bytes'])
    for row in r['sanitized_streams'].values():bound(row['path'],row['sha256'],row['bytes'])
    wrappers[label]={'true_exit':r['child_exit'],'timed_out':r['timed_out'],'receipt_sha256':d.h(path)}
selected={};all_cases={}
for path in sorted((ev/'inputs').glob('space-experience-*.json')):
    j=load(path)
    if 'children' not in j:continue
    label=path.stem;pr=TASK/'private'/label;jr=load(pr/'result.raw.json');assert jr['passed']==j['passed']
    for row in j['streams'].values():
        private(row['path']);bound(row['path'],row['sha256'],row['bytes']);f=Path(row['path'])
        projection=b''.join(s if s.startswith((b'PASS ',b'SPACE_EXPERIENCE_PASS')) else b'<private fixture/client diagnostic>\n' for s in f.read_bytes().splitlines(keepends=True))
        assert (ev/'logs'/(label+'-'+f.stem+'.log')).read_bytes()==projection
    all_cases[label]={'passed':j['passed'],'children':{n:c['true_exit'] for n,c in j['children'].items()},'eof':j['eof'],'failure':j.get('failure'),'explicit_completion':any(c.get('explicit_completion') for c in j['children'].values())}
    if label not in [a.flow,a.state,a.presentation]:continue
    assert j['passed'] and len(j['eof'])==4 and all(j['eof'].values()) and not j['reader_errors']
    assert all(c['true_exit']==0 for c in j['children'].values()) and wrappers[label+'-run']['true_exit']==0 and not wrappers[label+'-run']['timed_out']
    assert not j['host_input_or_focus_action'] and j['native_input_count']==0 and j['software_native_Control_inputs']
    assert not any(jr.get(k) for k in ['unretired_failure','cleanup_timeout'])
    mp,m=manifests[j['manifest_sha256']];assert m['passed'] and not m['trace_free']
    assert {n:h for n,h in m['live_source_inputs'].items() if n!='client/godot/README.md'}=={n:h for n,h in product['live_source_inputs'].items() if n!='client/godot/README.md'}
    name=next(n for n in j['children'] if n.startswith('client-'));phase=name[len('client-'):];child=j['children'][name]
    report=load(pr/'sandbox/work'/(phase+'.json'));assert report['passed'] and child['explicit_completion'] and report['checks']==child['checks']
    lines=(pr/(name+'-stdout.raw')).read_text().splitlines();assert [s[5:] for s in lines if s.startswith('PASS ')]==report['checks']
    assert sum(s.startswith('SPACE_EXPERIENCE_PASS') for s in lines)==1
    state=json.loads([s[len('M1B_STATE '):] for s in lines if s.startswith('M1B_STATE ')][-1]);metrics=state['controller_metrics']
    assert state['scene_count']==state['live_sockets']==0 and not metrics['Running'] and all(metrics[k]==0 for k in ['Subscriptions','sources','appearances','captures'])
    dist=Path(m['export_executable']).parent;assert jr['children'][name]['owner_incarnation'][:2]==list(key(dist/'quod.x86_64'))[:2]
    server=load(ev/'inputs'/('server-'+label+'-server.json'));assert server['child_exit']==0 and not server['runtime_recompiled'] and len(server['executed_current_sources'])==14
    for n,r in server['executed_current_sources'].items():
        bound(r['saved_source'],r['sha256']);bound(root/n,r['sha256'])
        if 'compiled_object' in r:
            o=r['compiled_object'];bound(o['path'],o['sha256'],o['bytes'],inherited=True)
        if 'presentation_overlay' in r:bound(r['presentation_overlay']['copy'],r['sha256'])
    for r in server['driver_sources'].values():bound(r['path'],r['sha256'])
    for n,r in server['affected_compiled_outputs'].items():bound(TASK/'private'/('quod-m4-live-'+label+'-server')/n,r['sha256'],r['bytes'])
    cost=None
    if label in [a.flow,a.state]:
        cost=load(pr/'sandbox/work'/('unchanged-work.json' if label==a.flow else 'unchanged-world.json'));assert cost['work']['calls']==[]
    selected[label]={'checks':len(report['checks']),'manifest':str(mp),'manifest_sha256':d.h(mp),'children':all_cases[label]['children'],'eof':j['eof'],'final_resources_zero':True,'cost':cost,'server_sources':server['executed_current_sources']}
assert len(selected)==3
owner=load(ev/'inputs/space-name-owner03.json');assert owner['passed'] and owner['true_exit']==0;cache(owner['digest_cache'])
for n,r in owner['inputs'].items():bound(r['copy'],r['sha256']);bound(root/n,r['sha256'])
for n,r in owner['new_objects'].items():bound(TASK/'private/space-name-owner03'/n,r['sha256'],r['bytes'])
browser=load(ev/'inputs/space-browser02.json');assert browser['passed'] and browser['true_exit']==0 and browser['only_retained_sources_executed'] and not browser['network_or_browser_runtime'];cache(browser['digest_cache'])
for n,r in browser['source_inputs'].items():bound(r['path'],r['sha256'])
before=load(ev/'inputs/before.json');delta={};production={'added':0,'removed':0}
for n,r in before.items():
    original=root/r['copy'];bound(original,r['sha256']);h=d.h(root/n)
    if h==r['sha256']:continue
    diff=list(difflib.ndiff(original.read_text().splitlines(),(root/n).read_text().splitlines()));added=sum(s.startswith('+ ') for s in diff);removed=sum(s.startswith('- ') for s in diff)
    delta[n]={'before_path':str(original),'before_sha256':r['sha256'],'after_sha256':h,'added':added,'removed':removed,'original_stat_key':r['stat_key']}
    if n.startswith(('client/godot/','client/src/','priv/ontologies/','src/')) and not n.endswith('.md'):production['added']+=added;production['removed']+=removed
assert subprocess.check_output(['git','rev-parse','HEAD']).decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3' and not subprocess.check_output(['git','diff','--cached','--name-only'])
script=(ev/'signed.py').read_text()
for literal in ['deadline=time.monotonic()+180','deadline=min(deadline,time.monotonic()+60)','child.wait(timeout=60)','child.kill();child.wait(timeout=10)','t.join(timeout=5)',"'--xr-mode','off'"]:assert literal in script
cp=TASK/'cache'/(a.label+'-hashes.json');assert not cp.exists();d.write(cp)
result={'passed':True,'evidence_verified':True,'diagnostic_passed':True,'product_changed':True,'shutdown_fixed':False,'full_M4_or_M5':False,'selected':selected,'all_cases':all_cases,'builds':builds,'wrappers':wrappers,'run_labels':list(wrappers),'qualification_run_label':a.label+'-run','source_delta':delta,'production_line_delta':production,
 'product':{'manifest':str(product_path),'sha256':d.h(product_path),'inputs':len(product['live_source_inputs']),'exports':len(product['export_outputs']),'export_bytes':sum(r['bytes'] for r in product['export_outputs'].values()),'trace_free':True,'distributable':False},
 'owner_gates':{'affected_lobby_generators':2,'browser_parser_checks':5,'new_contract':'signed current-world name and authored exterior labels; no identity, permission or navigation change'},
 'limits':['Software native Controls only; no human or HMD usability acceptance.','Existing historical noEOF failures remain unresolved.','No package, deployment, retirement, full Stage2 or M4/M5 acceptance.','All earlier failed labels and partial prefixes retain their actual exits.'],
 'digest_cache':{'path':str(cp),'sha256':raw(cp)},'qualification_private':str(dest),'digest_work':{'hits':d.hits,'new_objects':d.new,'new_bytes':d.bytes}}
(ev/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'passed':True,'selected':{k:v['checks'] for k,v in selected.items()},'production_line_delta':production,'product':result['product']}))
