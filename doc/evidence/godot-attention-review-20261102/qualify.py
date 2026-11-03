"""Bind this attention scope's actual source, signed results and retained failures."""
import argparse,atexit,difflib,json,os,shutil,stat,subprocess
from pathlib import Path
from hashes import Digests,TASK,key,raw
os.umask(0o077)
p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('product');p.add_argument('selection');args=p.parse_args()
root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
completed=False
def save_prefix():
    if not completed:d.write(TASK/'cache'/(args.label+'-prefix-hashes.json'))
atexit.register(save_prefix)
private=TASK/'private'/args.label;private.mkdir(mode=0o700,exist_ok=False)
for f in [Path(__file__),ev/'hashes.py']:shutil.copy2(f,private/f.name)
def load(p):return json.loads(Path(p).read_text())
def cache(ref):
    path=Path(ref['path']);assert raw(path)==ref['sha256']
    for r in load(path)['records']:
        k=tuple(r['stat_key']);assert k not in d.values or d.values[k]==r['sha256'];d.values[k]=r['sha256']
def bound(p,h,size=None,inherited=False):
    p=Path(p)
    if inherited:assert key(p) in d.values,('missing exact-stat custody',str(p))
    assert d.h(p)==h,str(p)
    if size is not None:assert p.stat().st_size==size

def guard(p):
    p=Path(p);assert p.is_relative_to(TASK)
    assert stat.S_IMODE(p.stat().st_mode)==0o600 and stat.S_IMODE(p.parent.stat().st_mode)==0o700
parent_path=root/'doc/evidence/godot-question-attention-20261101/inputs/client-attention-product01-manifest.json'
bound(parent_path,'1a6c8463e73a7ff1db2aedbc048c5a0bef73759ae353b233cf8aef104345a29d',inherited=True)
parent=load(parent_path);manifests={};builds={}
for path in sorted((ev/'inputs').glob('client-*-manifest.json')):
    m=load(path);cache(m['digest_cache']);stage=Path(m['stage']);source=stage/'source'
    assert m['template']==parent['template'] and m['dependency_archives']==parent['dependency_archives']
    assert not m['compiled_application_inputs_copied'] and not m['distributable']
    for n,h in m['supplied_inputs'].items():bound(source/n,h)
    if m['passed']:
        assert len(m['commands'])==5 and all(c['true_exit']==0 for c in m['commands']) and len(m['export_outputs'])==196
        for n,r in m['export_outputs'].items():bound(Path(m['export_executable']).parent/n,r['sha256'],r['bytes'],inherited=True)
    manifests[d.h(path)]=(path,m)
    builds[stage.name]={'passed':m['passed'],'phases':[c.get('true_exit') for c in m['commands']],
                      'manifest':str(path),'manifest_sha256':d.h(path),'live':len(m['live_source_inputs']),'supplied':len(m['supplied_inputs'])}
product_path=ev/'inputs'/('client-'+args.product+'-manifest.json');product=load(product_path)
assert product['passed'] and product['trace_free'] and not product['diagnostic_overrides'] and product['live_source_inputs']==product['supplied_inputs']
for n,h in product['live_source_inputs'].items():bound(root/n,h)
bound(product['template']['path'],product['template']['sha256'],inherited=True)
for r in product['dependency_archives'].values():bound(r['referenced_path'],r['sha256'],inherited=True)
selection=load(args.selection);selected={};cases={};servers={};wrappers={}
for path in sorted((ev/'logs').glob('*.json')):
    r=load(path)
    if 'child_exit' not in r:continue
    for n,h in r.get('driver_inputs',{}).items():bound(TASK/'private/runs'/path.stem/'driver-inputs'/n,h)
    for r2 in r.get('private_streams',{}).values():guard(r2['path']);bound(r2['path'],r2['sha256'],r2['bytes'])
    for r2 in r.get('sanitized_streams',{}).values():bound(r2['path'],r2['sha256'],r2['bytes'])
    wrappers[path.stem]={'true_exit':r['child_exit'],'timed_out':r.get('timed_out',False),'receipt':str(path),'sha256':d.h(path)}
for path in sorted(ev.glob('*/result.json')):
    r=load(path)
    if 'exit' in r:wrappers[path.parent.name]={'true_exit':r['exit'],'receipt':str(path),'sha256':d.h(path)}

def reuse(m,label):
    changes={}
    for n,h in m['live_source_inputs'].items():
        if h==product['live_source_inputs'][n]:continue
        old=(Path(m['stage'])/'source'/n).read_text();now=(root/n).read_text()
        if n=='client/godot/README.md':reason='Documentation only; exact current product README is separately bound.'
        elif n in selection.get('reuse_edits',{}).get(label,{}):
            # Only explicitly named, inspected intervening owner changes qualify
            # reuse; their exact text is bound in the selection disposition.
            edits=selection['reuse_edits'][label][n]
            for before,after in edits:
                assert before and old.count(before)==1
                old=old.replace(before,after,1)
            assert old==now,(label,n,'unlisted production change')
            reason=selection['reuse_reasons'][label][n]
        else:raise AssertionError(('unqualified current-input difference',label,n))
        changes[n]={'tested_sha256':h,'current_sha256':product['live_source_inputs'][n],'reason':reason}
    return changes

def server(label):
    path=root/'doc/evidence/godot-space-experience-20261101/inputs'/('server-'+label+'-server.json')
    r=load(path);assert r['child_exit']==0 and not r['runtime_recompiled'] and len(r['executed_current_sources'])==14
    for n,s in r['executed_current_sources'].items():
        bound(s['saved_source'],s['sha256']);bound(root/n,s['sha256'])
        if 'compiled_object' in s:
            o=s['compiled_object'];bound(o['path'],o['sha256'],o['bytes'],inherited=True)
        if 'presentation_overlay' in s:bound(s['presentation_overlay']['copy'],s['sha256'])
    for s in r['driver_sources'].values():bound(s['path'],s['sha256'])
    for n,s in r['affected_compiled_outputs'].items():bound(TASK/'private'/('quod-m4-live-'+label+'-server')/n,s['sha256'],s['bytes'])
    servers[label]={'path':str(path),'sha256':d.h(path),'current_sources':14,'fixture_outputs':len(r['affected_compiled_outputs'])}

for path in sorted((ev/'inputs').glob('*.json')):
    r=load(path)
    if 'children' not in r or 'manifest_sha256' not in r:continue
    label=path.stem;pr=TASK/'private'/label;actual=load(pr/'result.raw.json');assert r['passed']==actual['passed']
    for x in r['driver_inputs'].values():bound(x['copy'],x['sha256'])
    for x in r['streams'].values():
        f=Path(x['path']);guard(f);bound(f,x['sha256'],x['bytes'])
        projection=b''.join(s if s.startswith((b'PASS ',b'ATTENTION_PASS')) else b'<private fixture/client diagnostic>\n' for s in f.read_bytes().splitlines(keepends=True))
        assert (ev/'logs'/(label+'-'+f.stem+'.log')).read_bytes()==projection
    name=next((n for n in r['children'] if n.startswith('client-')),None)
    phase=name[7:] if name else None;lines=(pr/(name+'-stdout.raw')).read_text().splitlines() if name else []
    cases[label]={'passed':r['passed'],'children':{n:c['true_exit'] for n,c in r['children'].items()},'EOF':r['eof'],
                  'failure':r.get('failure'),'passing_prefix':sum(s.startswith('PASS ') for s in lines),
                  'client_started':name is not None,'explicit_completion':r['children'][name].get('explicit_completion',False) if name else False,'unretired_failure':actual.get('unretired_failure',False),
                  'cleanup_timeout':actual.get('cleanup_timeout',False),'receipt_sha256':d.h(path)}
    server_path=root/'doc/evidence/godot-space-experience-20261101/inputs'/('server-'+label+'-server.json')
    if server_path.exists():server(label)
    else:assert name is None and not r['passed']
    if label not in selection['signed']:continue
    assert r['passed'] and len(r['eof'])==4 and all(r['eof'].values()) and not r['reader_errors']
    assert all(c['true_exit']==0 for c in r['children'].values()) and wrappers[label+'-run']['true_exit']==0 and not wrappers[label+'-run']['timed_out']
    assert not actual.get('unretired_failure') and not actual.get('cleanup_timeout')
    assert not r['host_input_or_focus_action'] and r['native_input_count']==0 and r['software_native_Control_inputs']
    mp,m=manifests[r['manifest_sha256']];assert not m['trace_free'];changes=reuse(m,label)
    result=load(pr/'sandbox/work'/(phase+'.json'));assert result['passed'] and r['children'][name]['explicit_completion']
    assert result['checks']==r['children'][name]['checks']==[s[5:] for s in lines if s.startswith('PASS ')] and lines.count('ATTENTION_PASS')==1
    assert actual['children'][name]['owner_incarnation'][:2]==list(key(Path(m['export_executable'])))[:2]
    costs={}
    for n in ['unchanged-work.json']:
        f=pr/'sandbox/work'/n
        if f.exists():costs[n]=load(f);assert costs[n]['work']['calls']==[]
    final=json.loads([s[10:] for s in lines if s.startswith('M1B_STATE ')][-1]);metrics=final['controller_metrics']
    assert final['scene_count']==final['live_sockets']==0 and not metrics['Running'] and all(metrics[k]==0 for k in ['Subscriptions','sources','appearances','captures'])
    selected[label]={'checks':len(result['checks']),'receipt':str(path),'sha256':d.h(path),'manifest':str(mp),'manifest_sha256':d.h(mp),
                     'current_input_reuse':changes,'all_children_and_wrapper_zero':True,'EOF':r['eof'],'cost':costs}
assert set(selected)==set(selection['signed'])
owners=load(ev/'inputs/shared-question-owners.json')
bound(owners['qualified_manifest'],owners['manifest_sha256'],inherited=True)
for n,r in owners['sources'].items():
    assert key(Path(r['qualified_stage_path']))==tuple(r['stage_stat_key'])
    bound(r['qualified_stage_path'],r['sha256'],inherited=True);bound(root/n,r['sha256']);bound(r['copy'],r['copy_sha256'])
    assert Path(r['copy']).stat().st_mode==r['copy_mode']
browser=load(ev/'inputs/attention-review-browser01.json');assert browser['passed'] and browser['true_exit']==0 and browser['only_retained_sources_executed']
cache(browser['digest_cache'])
for n,r in browser['source_inputs'].items():
    bound(r['path'],r['sha256']);bound(ev/n if n=='browser.py' else root/n,r['sha256'])
    assert Path(r['path']).stat().st_mode==r['mode']
assert wrappers['attention-review-browser01']['true_exit']==0
browser_log=(ev/'logs/attention-review-browser01-stdout.log').read_text();assert 'ℹ pass 33\n' in browser_log and 'ℹ fail 0\n' in browser_log and 'ℹ skipped 0\n' in browser_log
before=load(ev/'inputs/before.json');delta={};production={'added':0,'removed':0};docs={'added':0,'removed':0}
for n,r in before.items():
    p=root/r['copy'];bound(p,r['sha256']);assert p.stat().st_mode==r['mode']
    h=d.h(root/n)
    if h==r['sha256']:continue
    lines=list(difflib.ndiff(p.read_text().splitlines(),(root/n).read_text().splitlines()));added=sum(s.startswith('+ ') for s in lines);removed=sum(s.startswith('- ') for s in lines)
    delta[n]={'before_path':str(p),'before_sha256':r['sha256'],'before_stat_key':key(p),'after_sha256':h,'mode':stat.S_IMODE((root/n).stat().st_mode),'added':added,'removed':removed}
    count=docs if n.endswith('.md') else production;count['added']+=added;count['removed']+=removed
assert subprocess.check_output(['git','rev-parse','HEAD']).decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert not subprocess.check_output(['git','diff','--cached','--name-only'])
cp=TASK/'cache'/(args.label+'-hashes.json');assert not cp.exists()
cp.write_text(json.dumps({'records':[{'stat_key':k,'sha256':v} for k,v in d.values.items()],'pathless_rows_preserved':True})+'\n')
result={'passed':True,'evidence_verified':True,'selected':selected,'cases':cases,'builds':builds,'wrappers':wrappers,'server_bindings':servers,
        'shared_question_owners':{'receipt':str(ev/'inputs/shared-question-owners.json'),'sha256':d.h(ev/'inputs/shared-question-owners.json'),'current_resources':list(owners['sources'])},
        'selection':{'path':str(Path(args.selection).resolve()),'sha256':d.h(Path(args.selection))},
        'browser':{'checks':33,'receipt_sha256':d.h(ev/'inputs/attention-review-browser01.json'),'source_only':True,'browser_runtime':False},
        'source_delta':delta,'production_line_delta':production,'documentation_line_delta':docs,
        'product':{'manifest':str(product_path),'sha256':d.h(product_path),'inputs':len(product['live_source_inputs']),'exports':196,'export_bytes':sum(r['bytes'] for r in product['export_outputs'].values()),'trace_free':True,'distributable':False},
        'digest_cache':{'path':str(cp),'sha256':raw(cp)},'qualification_private':str(private),'run_labels':sorted(n for n in wrappers if (TASK/'private/runs'/n).is_dir()),
        'digest_work':{'hits':d.hits,'new_objects':d.new,'new_bytes':d.bytes},'packaged':False,'historical_shutdown_fixed':False,'human_HMD_accepted':False,
        'limits':selection['limits']}
(ev/'result.json').write_text(json.dumps(result,indent=2)+'\n')
completed=True
print(json.dumps({'passed':True,'selected':{k:v['checks'] for k,v in selected.items()},'production':production,'product':result['product']}))
