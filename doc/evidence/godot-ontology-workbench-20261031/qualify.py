"""Bind completed affected software evidence; execute no app, test or old dump."""
import argparse,json,os,stat,subprocess,sys
from pathlib import Path
from hashes import Digests,TASK,raw
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
p=argparse.ArgumentParser();p.add_argument('--diagnostic',required=True);p.add_argument('--product',required=True);p.add_argument('--headless',required=True);p.add_argument('--render',required=True);p.add_argument('--framing',required=True);p.add_argument('--scene',required=True);p.add_argument('--label',default='workbench-qualified01');p.add_argument('--resume',nargs=2);a=p.parse_args()
required_cases=[a.headless,a.render,a.framing,a.scene,'workbench-controls-final03-headless','workbench-draft-fault-final01-headless','workbench-scope-final01-headless','workbench-layout-final01-headless']
def load(path):return json.loads(path.read_text())
def cache(path,sha):
    assert raw(path)==sha
    rows=load(path)['records']
    for r in rows.values() if isinstance(rows,dict) else rows:
        k=tuple(r['stat_key']);assert k not in d.values or d.values[k]==r['sha256'];d.values[k]=r['sha256']
if a.resume:cache(Path(a.resume[0]),a.resume[1])
def failed(kind,value,tb):
    path=TASK/'cache'/(a.label+'-partial.json');assert not path.exists();d.write(path)
    print(json.dumps({'failed_digest_progress':str(path),'sha256':raw(path),'failure_type':kind.__name__}),file=sys.stderr);sys.__excepthook__(kind,value,tb)
sys.excepthook=failed
manifests={path.name[7:-14]:load(path) for path in sorted((ev/'inputs').glob('client-*-manifest.json'))}
for m in manifests.values():cache(Path(m['digest_cache']['path']),m['digest_cache']['sha256'])
builds={}
for label,m in manifests.items():
    stage=Path(m['stage'])/'source';assert not m['compiled_application_inputs_copied'] and not m['distributable']
    assert all(d.h(stage/n)==sha for n,sha in m['supplied_inputs'].items())
    for c in m['commands']:
        r=load(ev/(label+'-'+c['phase'])/'result.json');assert r['exit']==c['true_exit']
    if m['passed']:
        assert len(m['commands'])==5 and all(c['true_exit']==0 for c in m['commands']) and len(m['export_outputs'])==196
        dist=Path(m['export_executable']).parent
        assert {str(f.relative_to(dist)) for f in dist.rglob('*') if f.is_file()}==set(m['export_outputs'])
        assert all(d.h(dist/n)==r['sha256'] and (dist/n).stat().st_size==r['bytes'] for n,r in m['export_outputs'].items())
    builds[label]={'passed':m['passed'],'supplied':len(m['supplied_inputs']),'live':len(m['live_source_inputs']),'commands':[(c['phase'],c['true_exit']) for c in m['commands']],'manifest_sha256':raw(ev/'inputs'/('client-'+label+'-manifest.json'))}
selected=manifests[a.diagnostic];product=manifests[a.product]
assert selected['passed'] and product['passed'] and product['trace_free'] and not product['diagnostic_overrides']
assert selected['live_source_inputs']==product['live_source_inputs'] and product['supplied_inputs']==product['live_source_inputs']
assert 'client/godot/WorkbenchPanel.cs' in product['supplied_inputs']
assert all(d.h(root/n)==sha for n,sha in product['live_source_inputs'].items())
cases={}
for path in sorted(ev.glob('*/result.json')):
    q=load(path)
    if 'children' not in q:continue
    assert not q['reader_errors'] and all(q['eof'].values())
    for row in q['streams'].values():
        f=Path(row['raw_path']);assert d.h(f)==row['sha256'] and f.stat().st_size==row['bytes'] and stat.S_IMODE(f.stat().st_mode)==0o600 and stat.S_IMODE(f.parent.stat().st_mode)==0o700
        public=path.parent/(f.stem+'.log');assert d.h(public)==row['public_sha256']
    if path.parent.name in required_cases:
        assert q['passed'] and q['explicit_completion'] and q['client_report_passed'] and len(q['eof'])==4 and not q['diagnostics']
        assert all(c['true_exit']==0 for c in q['children'].values())
        private_report=TASK/'private'/path.parent.name/'client-result.raw.json'
        assert d.h(private_report)==q['client_result_sha256'] and load(private_report)['passed']
        assert load(private_report)['checks']==q['checks']
    cases[path.parent.name]={'passed':q['passed'],'checks':q.get('total_checks'),'children':{n:c['true_exit'] for n,c in q['children'].items()},'eof':q['eof'],'reader_errors':q['reader_errors'],'result_sha256':raw(path)}
for label in required_cases:assert cases[label]['passed']
for path in sorted((ev/'inputs').glob('server-*-server.json')):
    server=load(path);base=TASK/'private'/('quod-m4-live-'+path.stem[len('server-'):])
    for name,row in server['affected_compiled_outputs'].items():
        f=base/name;assert d.h(f)==row['sha256'] and f.stat().st_size==row['bytes']
    for row in server['driver_sources'].values():assert d.h(Path(row['path']))==row['sha256']
for label in [a.headless,a.render,a.framing,a.scene]:
    case=load(ev/label/'result.json');case_manifest=Path(case['manifest']);assert case['manifest_sha256']==raw(case_manifest)
    assert load(case_manifest)['live_source_inputs']==selected['live_source_inputs']
    server=load(ev/'inputs'/('server-'+label+'-server.json'));assert server['child_exit']==0
    for name,row in server['executed_current_sources'].items():
        assert d.h(Path(row['saved_source']))==row['sha256']
        if d.h(root/name)!=row['sha256']:
            assert label==a.scene and case['qualification_phase']=='scene' and name=='priv/ontologies/gui_tools.pl'
            # The existing SceneAdapter phase runs before Connect; this fixture
            # ontology is unused. Exact current C# inputs were checked above.
scope_case=load(ev/'workbench-scope-final01-headless/result.json');scope_manifest=load(Path(scope_case['manifest']))
assert scope_manifest['live_source_inputs']['client/godot/SourcePanel.cs']==selected['live_source_inputs']['client/godot/SourcePanel.cs']
pure={}
for label in ['workbench-identity-final03','workbench-matching-final02','workbench-saved-fact-final01','workbench-large-final04','workbench-catalogue-final02']:
    path=ev/'inputs'/(label+'.json');q=load(path);assert q['passed'] and q['true_exit']==0
    for row in q['inputs'].values():assert d.h(Path(row['copy']))==row['sha256']
    pure[label]={'true_exit':0,'result_sha256':raw(path)}
runs={}
for path in sorted((ev/'logs').glob('*.json')):
    q=load(path)
    for section in ['private_streams','sanitized_streams']:
        for row in q[section].values():
            f=Path(row['path']);assert d.h(f)==row['sha256'] and f.stat().st_size==row['bytes']
    saved=TASK/'private/runs'/path.stem/'driver-inputs'
    for name,sha in q['driver_inputs'].items():assert d.h(saved/name)==sha
    runs[path.stem]={'true_exit':q['child_exit'],'timed_out':q['timed_out'],'result_sha256':raw(path)}
delta={}
for before in sorted((ev/'inputs/before').rglob('*')):
    if not before.is_file():continue
    n=str(before.relative_to(ev/'inputs/before'));after=root/n
    if d.h(after)!=d.h(before):
        diff=subprocess.run(['git','diff','--no-index','--numstat',str(before),str(after)],capture_output=True,text=True);assert diff.returncode==1 and not diff.stderr
        added,removed=diff.stdout.split('\t')[:2]
        delta[n]={'before_path':str(before),'before_sha256':d.h(before),'after_sha256':d.h(after),'mode':stat.S_IMODE(after.stat().st_mode),'added_lines':int(added),'removed_lines':int(removed)}
assert 'client/godot/FormPanel.cs' in delta and 'priv/ontologies/gui_tools.pl' in delta
rasters=[]
for p in sorted((TASK/'private'/a.render/'images').glob('*.png')):
    assert stat.S_IMODE(p.stat().st_mode)==0o600 and stat.S_IMODE(p.parent.stat().st_mode)==0o700
    rasters.append({'path':str(p),'sha256':d.h(p),'bytes':p.stat().st_size,'inspection':'actual native graph and26/48 Control rasters inspected; no human/VR acceptance'})
assert len(rasters)==3
result={'passed':True,'ticket':'QUO-34','scope':'bounded graphical ontology workbench, signed software/native-Control qualification','selected':a.diagnostic,'product':a.product,'builds':builds,'cases':cases,'pure':pure,'runs':runs,'product_input_count':len(product['live_source_inputs']),'product_exports':196,'product_DLL':product['export_outputs']['data_Quod_linuxbsd_x86_64/Quod.dll'],'product_PCK':product['export_outputs']['quod.pck'],'engine':product['template'],'source_delta':delta,'added_product_sources':['client/godot/WorkbenchPanel.cs'],'full_M4_or_M5':False,'hardware_or_human_ergonomics':False,'unknown_outcome_replay':False,'retirement_cutover_commit':False,'supported':['direct authored class inheritance and instance membership graph','selected ground attributes; text-valued attribute preparation','guarded class/attribute add and exact fact replace/remove','existing class-offered instance creation; raw membership removal without cascade','same source Preview/Save/Cancel, committed readback and original recovery owner'],'limits':['no universal Prolog graph editor, new founding, predicate/clause global identity or ontology-to-space cast','raw fact removal is not entity-history deletion','existing proof-answer resource-policy ownership concern remains separate; no cap increase or claimed intrinsic64KiB encoding necessity','selected native-Control events are software injections, not physical controller acceptance','private M5 package remains the accepted previous checkpoint; no release/cutover or refreshed package claim'],'tracker_publication':'body approval block retained; no retry/bypass; initial metadata link failed'}
result['raster_inspection']=rasters
path=TASK/'cache'/(a.label+'.json');assert not path.exists();d.write(path);result['digest_cache']={'path':str(path),'sha256':raw(path)}
(ev/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'passed':True,'selected':a.diagnostic,'product':a.product,'checks':{n:cases[n]['checks'] for n in [a.headless,a.render]},'source_delta':len(delta)}))
