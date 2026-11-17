"""Bind the selected occurrence/form software results; retain every failed label."""
import argparse, collections, difflib, json, os, shutil, stat, subprocess
from pathlib import Path
from hashes import Digests, TASK, key, raw

os.umask(0o077)
parser=argparse.ArgumentParser()
parser.add_argument('label')
parser.add_argument('product')
args=parser.parse_args()
root=Path.cwd(); ev=Path(__file__).resolve().parent; d=Digests()
private=TASK/'private'/args.label; private.mkdir(mode=0o700,exist_ok=False)
for p in [Path(__file__),ev/'hashes.py']:shutil.copy2(p,private/p.name)
def load(p):return json.loads(Path(p).read_text())
def cache(ref):
    p=Path(ref['path']);assert raw(p)==ref['sha256']
    for r in load(p)['records']:
        k=tuple(r['stat_key']);assert k not in d.values or d.values[k]==r['sha256'];d.values[k]=r['sha256']
def bound(p,h,size=None,inherited=False):
    p=Path(p)
    if inherited:assert key(p) in d.values,('missing inherited exact-stat custody',str(p))
    assert d.h(p)==h,str(p)
    if size is not None:assert p.stat().st_size==size
def raw_private(p):
    p=Path(p);assert p.is_relative_to(TASK)
    assert stat.S_IMODE(p.stat().st_mode)==0o600 and stat.S_IMODE(p.parent.stat().st_mode)==0o700

parent_path=root/'doc/evidence/godot-space-experience-20261101/inputs/client-space-experience-product01-manifest.json'
bound(parent_path,'4f7fbe270e975238edbc93e5b68d39949809d72033f8a078368a95d628233e0d',inherited=True)
parent=load(parent_path); manifests={}; builds={}
for p in sorted((ev/'inputs').glob('client-*-manifest.json')):
    m=load(p);cache(m['digest_cache']);stage=Path(m['stage']);source=stage/'source'
    for n,h in m['supplied_inputs'].items():bound(source/n,h)
    assert m['template']==parent['template'] and m['dependency_archives']==parent['dependency_archives']
    assert not m['compiled_application_inputs_copied'] and not m['distributable']
    if m['passed']:
        assert len(m['commands'])==5 and all(c['true_exit']==0 for c in m['commands'])
        assert len(m['export_outputs'])==196
        for n,r in m['export_outputs'].items():bound(Path(m['export_executable']).parent/n,r['sha256'],r['bytes'],inherited=True)
    manifests[d.h(p)]=(p,m)
    builds[stage.name]={'passed':m['passed'],'phases':[c.get('true_exit') for c in m['commands']],
                        'manifest_sha256':d.h(p),'supplied':len(m['supplied_inputs']),'live':len(m['live_source_inputs'])}
product_path=ev/'inputs'/('client-'+args.product+'-manifest.json'); product=load(product_path)
assert product['passed'] and product['trace_free'] and not product['diagnostic_overrides']
assert product['live_source_inputs']==product['supplied_inputs']
for n,h in product['live_source_inputs'].items():bound(root/n,h)
bound(product['template']['path'],product['template']['sha256'],inherited=True)
for r in product['dependency_archives'].values():bound(r['referenced_path'],r['sha256'],inherited=True)

def reuse(m):
    """Exact, reviewable intervening edits; never call a different vector identical."""
    changes={}
    for n,h in m['live_source_inputs'].items():
        if h==product['live_source_inputs'][n]:continue
        old=(Path(m['stage'])/'source'/n).read_text();now=(root/n).read_text()
        if n=='client/godot/README.md':reason='Documentation only; exact current product README is bound separately.'
        elif n=='client/godot/Main.cs':
            assert old.replace('            if(retainDrafts&&node==representations)continue;\n','')==now,n
            reason='Removed obsolete body-child exception; the form is constructed once under FormSurface. Current signed and workspace gates qualify disposal.'
        elif n=='client/godot/SpatialGui.cs':
            old=old.replace('formHost.Theme=workspaceTheme;','formHost.Theme=workspaceTheme;formHost.MinimumSizeChanged+=ResizeSurface;') if 'formHost.MinimumSizeChanged+=ResizeSurface;' not in old else old
            old=old.replace('new InputEventMouseMotion {Position=position,GlobalPosition=position},true);','new InputEventMouseMotion {Position=position,GlobalPosition=position,Relative=position-Surface.GetMousePosition()},true);')
            assert old==now,n
            reason='Only native minimum-size notification and root relative-motion fixes intervene; current preview/world/workspace gates exercise these exact corrections.'
        elif n=='client/godot/tests/WorkspaceChecks.cs':
            assert old.replace('            var scroll=(ScrollContainer)target.GetParent().GetParent().GetParent();\n            var clip=new Rect2(Vector2.Zero,gui.Surface.Size).Intersection(scroll.GetGlobalRect());',
              '            var clip=target.GetViewport().GetVisibleRect();\n            for(Node? parent=target.GetParent();parent!=null;parent=parent.GetParent())\n                if(parent is Control control&&control.ClipContents)clip=clip.Intersection(control.GetGlobalRect());')==now,n
            reason='Replaced stale test ancestor cast with actual clipping ancestors; this phase did not execute WorkspaceAdapter.'
        else:raise AssertionError(('unqualified intervening input',n))
        changes[n]={'tested_sha256':h,'current_sha256':product['live_source_inputs'][n],'disposition':reason}
    return changes

wrappers={}
for p in sorted(ev.glob('*/result.json')):
    r=load(p)
    if 'command' in r and 'exit' in r:
        wrappers[p.parent.name]={'true_exit':r['exit'],'diagnostic_failure':r['diagnostic_failure'],
                                'receipt':str(p),'receipt_sha256':d.h(p),'elapsed_seconds':r['elapsed_seconds']}

signed_labels=['occurrence-interaction-final27','occurrence-preview-final27','occurrence-lifetime-final24',
               'occurrence-space-final24','occurrence-input-final25']
native_labels=['occurrence-workspace27','occurrence-keyboard21','occurrence-controller21',
               'occurrence-keyboard-ray21','occurrence-form-ray22','occurrence-scene23']
selected={};all_cases={};servers={}
def server_binding(label):
    p=root/'doc/evidence/godot-space-experience-20261101/inputs'/('server-'+label+'-server.json')
    s=load(p);assert s['child_exit']==0 and not s['runtime_recompiled'] and len(s['executed_current_sources'])==14
    for n,r in s['executed_current_sources'].items():
        bound(r['saved_source'],r['sha256']);bound(root/n,r['sha256'])
        if 'compiled_object' in r:
            v=r['compiled_object'];bound(v['path'],v['sha256'],v['bytes'],inherited=True)
        if 'presentation_overlay' in r:bound(r['presentation_overlay']['copy'],r['sha256'])
    for r in s['driver_sources'].values():bound(r['path'],r['sha256'])
    for n,r in s['affected_compiled_outputs'].items():bound(TASK/'private'/('quod-m4-live-'+label+'-server')/n,r['sha256'],r['bytes'])
    servers[label]={'path':str(p),'sha256':d.h(p),'source_count':14,'new_fixture_outputs':len(s['affected_compiled_outputs'])}
for p in sorted((ev/'inputs').glob('*.json')):
    j=load(p)
    if 'children' not in j:continue
    label=p.stem;pr=TASK/'private'/label;jr=load(pr/'result.raw.json');assert jr['passed']==j['passed']
    for n,r in j['driver_inputs'].items():bound(r['copy'],r['sha256'])
    for r in j['streams'].values():
        raw_private(r['path']);bound(r['path'],r['sha256'],r['bytes']);f=Path(r['path'])
        projection=b''.join(s if s.startswith((b'PASS ',b'OCCURRENCE_PASS')) else b'<private fixture/client diagnostic>\n' for s in f.read_bytes().splitlines(keepends=True))
        assert (ev/'logs'/(label+'-'+f.stem+'.log')).read_bytes()==projection
    name=next(n for n in j['children'] if n.startswith('client-'));phase=name[7:]
    lines=(pr/(name+'-stdout.raw')).read_text().splitlines()
    all_cases[label]={'passed':j['passed'],'children':{n:c['true_exit'] for n,c in j['children'].items()},
                     'eof':j['eof'],'failure':j.get('failure'),'passing_prefix':sum(s.startswith('PASS ') for s in lines),
                     'unretired_failure':jr.get('unretired_failure',False),'cleanup_timeout':jr.get('cleanup_timeout',False)}
    if label not in signed_labels+['material-final17']:continue
    assert j['passed'] and len(j['eof'])==4 and all(j['eof'].values()) and not j['reader_errors']
    assert all(c['true_exit']==0 for c in j['children'].values()) and wrappers[label+'-run']['true_exit']==0
    assert j['native_input_count']==0 and not j['host_input_or_focus_action'] and j['software_native_Control_inputs']
    assert not jr.get('unretired_failure') and not jr.get('cleanup_timeout')
    mp,m=manifests[j['manifest_sha256']];assert m['passed'] and not m['trace_free']
    report=load(pr/'sandbox/work'/(phase+'.json'));child=j['children'][name]
    assert report['passed'] and child['explicit_completion'] and child['checks']==report['checks']
    assert [s[5:] for s in lines if s.startswith('PASS ')]==report['checks'] and lines.count('OCCURRENCE_PASS')==1
    assert jr['children'][name]['owner_incarnation'][:2]==list(key(Path(m['export_executable'])))[:2]
    server_binding(label)
    if label=='material-final17':
        src=Path(m['stage'])/'source';n='client/godot/Core/Scene.cs';bound(root/n,m['live_source_inputs'][n])
        old=(src/'client/godot/ScenePanel.cs').read_text();now=(root/'client/godot/ScenePanel.cs').read_text()
        for start,end in [('    public override void _Ready()','    static Vector3[] Corners'),('    void Apply(SceneMark[] marks','    public void ApplyFrame()')]:
            assert old[old.index(start):old.index(end)]==now[now.index(start):now.index(end)]
        assert (src/'client/godot/tests/OccurrenceMaterial.cs').read_bytes()==(ev/'OccurrenceMaterial.cs').read_bytes()
        changes={'material_owner':'Exact Core/Scene, ScenePanel _Ready and Apply bodies and diagnostic unchanged; later selected preview-surface code is separately qualified.'}
    else:changes=reuse(m)
    costs={}
    for n in ['unchanged-work.json','preview-work.json']:
        f=pr/'sandbox/work'/n
        if f.exists():costs[n]=load(f);assert costs[n]['work']['calls']==[]
    states=[json.loads(s[10:]) for s in lines if s.startswith('M1B_STATE ')]
    if states:
        final=states[-1];metrics=final['controller_metrics'];assert final['scene_count']==final['live_sockets']==0
        assert not metrics['Running'] and all(metrics[k]==0 for k in ['Subscriptions','sources','appearances','captures'])
    selected[label]={'checks':len(report['checks']),'receipt':str(p),'sha256':d.h(p),'manifest':str(mp),
                     'manifest_sha256':d.h(mp),'current_input_reuse':changes,'cost':costs,'eof':j['eof'],'all_children_and_wrapper_zero':True}

for p in sorted(ev.glob('*/result.json')):
    j=load(p)
    if 'qualification_phase' not in j:continue
    label=p.parent.name;pr=TASK/'private'/label
    for n,h in j['sources'].items():bound(pr/'drivers'/Path(n).name,h)
    for n,r in j['streams'].items():
        raw_private(r['raw_path']);bound(r['raw_path'],r['sha256'],r['bytes']);bound(p.parent/(Path(n).stem+'.log'),r['public_sha256'])
    all_cases[label]={'passed':j['passed'],'children':{n:c['true_exit'] for n,c in j['children'].items()},'eof':j['eof'],
                     'failure':j.get('failure'),'explicit_completion':j.get('explicit_completion',False),'diagnostics':j['diagnostics']}
    if label not in native_labels:continue
    assert j['passed'] and j['explicit_completion'] and not j['diagnostics'] and not j['reader_errors']
    assert j['children']['client']['true_exit']==wrappers[label+'-run']['true_exit']==0 and all(j['eof'].values())
    assert not any(j[k] for k in ['physical','native_runtime_started','hardware_queried','display_or_focus_action'])
    mp,m=manifests[j['manifest_sha256']];changes=reuse(m);report=load(pr/'client-result.raw.json')
    bound(pr/'client-result.raw.json',j['client_result_sha256']);assert report['passed']
    checks=report['checks']+report.get('prior_checks',[])
    probes=[r['name'] for r in report.get('reports',[]) if r.get('passed') is True]
    assert not any(r.get('passed') is False for r in report.get('reports',[]))
    lines=[s[5:] for s in (pr/'client-stdout.raw').read_text().splitlines() if s.startswith('PASS ')]
    assert collections.Counter(lines)==collections.Counter(checks+probes)
    selected[label]={'checks':len(checks),'additional_native_probes':len(probes),'actual_pass_lines':len(lines),
                     'receipt':str(p),'sha256':d.h(p),'manifest':str(mp),'manifest_sha256':d.h(mp),
                     'current_input_reuse':changes,'eof':j['eof'],'all_children_and_wrapper_zero':True}
assert set(selected)==set(signed_labels+native_labels+['material-final17'])

before={}
for name in ['before.json','before-additional.json','before-workspace.json','before-agents.json']:before.update(load(ev/'inputs'/name))
alignment=root/'doc/evidence/godot-vr-gui-alignment-20261101/inputs/before'
earlier=load(alignment.parent/'before.json');delta={};production={'added':0,'removed':0};tests={'added':0,'removed':0}
for n,r in before.items():
    p=alignment/n if n in earlier else ev/'inputs/before'/n
    expected=parent['live_source_inputs'].get(n,r['sha256']);bound(p,expected)
    h=d.h(root/n)
    if h==expected:continue
    lines=list(difflib.ndiff(p.read_text().splitlines(),(root/n).read_text().splitlines()))
    added=sum(s.startswith('+ ') for s in lines);removed=sum(s.startswith('- ') for s in lines)
    delta[n]={'before_path':str(p),'before_sha256':expected,'after_sha256':h,'added':added,'removed':removed,'before_stat_key':key(p)}
    destination=tests if n.startswith('client/godot/tests/') else production if n.startswith('client/godot/') and not n.endswith('.md') else None
    if destination is not None:destination['added']+=added;destination['removed']+=removed
assert subprocess.check_output(['git','rev-parse','HEAD']).decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert not subprocess.check_output(['git','diff','--cached','--name-only'])
cp=TASK/'cache'/(args.label+'-hashes.json');assert not cp.exists()
cp.write_text(json.dumps({'records':[{'stat_key':k,'sha256':v} for k,v in d.values.items()]})+'\n')
result={'passed':True,'evidence_verified':True,'selected':selected,'all_cases':all_cases,'builds':builds,'wrappers':wrappers,
        'server_bindings':servers,'source_delta':delta,'production_line_delta':production,'test_line_delta':tests,
        'product':{'manifest':str(product_path),'sha256':d.h(product_path),'inputs':len(product['live_source_inputs']),
                   'exports':len(product['export_outputs']),'export_bytes':sum(r['bytes'] for r in product['export_outputs'].values()),'trace_free':True,'distributable':False},
        'digest_cache':{'path':str(cp),'sha256':raw(cp)},'qualification_private':str(private),
        'digest_work':{'hits':d.hits,'new_objects':d.new,'new_bytes':d.bytes},
        'shutdown_fixed':False,'human_or_HMD_accepted':False,'full_GUI_Stage2_M4_M5':False,'packaged':False,
        'limits':['Attention selection and exact question subject remain open.','Generic authored arbitrary surface geometry and broader assets/components are not delivered.',
                  'No current human/HMD legibility, ergonomics or comfort acceptance.','Historical and current failed labels, including noEOF failures, remain whole failures.',
                  'No package, deployment, retirement or commit.','Necessary computed-lens cursor reevaluation remains unchanged; no new target-version cache.']}
(ev/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'passed':True,'selected':{k:v['checks'] for k,v in selected.items()},'production':production,'tests':tests,'product':result['product']}))
