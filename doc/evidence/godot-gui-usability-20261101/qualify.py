"""Bind this GUI-only checkpoint to actual source, child results and custody."""
import argparse,json,os,stat,subprocess,shutil
from pathlib import Path
from hashes import TASK,Digests,key,raw
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
p=argparse.ArgumentParser()
for name in ['product','diagnostic','signed','controls','layout','workspace','outcomes']:p.add_argument('--'+name,required=True)
p.add_argument('--label',required=True);a=p.parse_args()
dest=TASK/'private'/a.label;dest.mkdir(mode=0o700,exist_ok=False)
for original in [Path(__file__).resolve(),ev/'hashes.py']:
    shutil.copy2(original,dest/original.name)

def load(path):return json.loads(path.read_text())
def cache(ref):
    path=Path(ref['path']);assert raw(path)==ref['sha256']
    for r in load(path)['records']:
        k=tuple(r['stat_key']);assert k not in d.values or d.values[k]==r['sha256'];d.values[k]=r['sha256']
manifests={};builds={}
for path in sorted((ev/'inputs').glob('client-*-manifest.json')):
    m=load(path);cache(m['digest_cache']);stage=Path(m['stage']);source=stage/'source'
    assert not m['compiled_application_inputs_copied']
    assert all(d.h(source/n)==v for n,v in m['supplied_inputs'].items())
    for row in m['dependency_archives'].values():assert d.h(Path(row['referenced_path']))==row['sha256']
    assert d.h(Path(m['template']['path']))==m['template']['sha256']
    if m['passed']:
        assert len(m['commands'])==5 and all(c['true_exit']==0 for c in m['commands'])
        dist=Path(m['export_executable']).parent
        assert len(m['export_outputs'])==196
        assert set(m['export_outputs'])=={str(f.relative_to(dist)) for f in dist.rglob('*') if f.is_file()}
        for n,r in m['export_outputs'].items():assert d.h(dist/n)==r['sha256'] and (dist/n).stat().st_size==r['bytes']
    label=stage.name.removeprefix('client-');manifests[label]=m
    builds[label]={'path':str(path),'sha256':d.h(path),'passed':m['passed'],'supplied':len(m['supplied_inputs']),'live':len(m['live_source_inputs']),'phase_exits':[c.get('true_exit') for c in m['commands']]}
product=manifests[a.product];diagnostic=manifests[a.diagnostic]
assert product['passed'] and product['trace_free'] and not product['diagnostic_overrides']
assert diagnostic['passed'] and not diagnostic['trace_free'] and not diagnostic['distributable']
assert set(diagnostic['diagnostic_overrides'])=={'client/godot/tests/ExportChecks.cs','client/godot/tests/GuiUsabilityChecks.cs','client/godot/tests/SignedGuiChecks.cs'}
assert product['live_source_inputs']==product['supplied_inputs']==diagnostic['live_source_inputs']
assert len(product['live_source_inputs'])==97 and len(diagnostic['supplied_inputs'])==99
assert all(d.h(root/n)==v for n,v in product['live_source_inputs'].items())
outcomes={}
for directory in sorted(ev.iterdir()):
    path=directory/'result.json'
    if directory.is_dir() and path.exists():
        r=load(path)
        if 'exit' in r:
            assert isinstance(r['exit'],int);outcomes[directory.name]={'true_exit':r['exit'],'receipt_sha256':d.h(path),'diagnostic_failure':r.get('diagnostic_failure')}
            assert (directory/'output.log').is_file();d.h(directory/'output.log')
def streams(record):
    for name,r in record['streams'].items():
        path=Path(r.get('path',r.get('raw_path')))
        assert path.is_relative_to(TASK) and path.stat().st_mode&0o777==0o600
        assert path.parent.stat().st_mode&0o777==0o700
        assert d.h(path)==r['sha256'] and path.stat().st_size==r['bytes']
selected={}
for role,label in [('controls',a.controls),('layout',a.layout),('workspace',a.workspace),('outcomes',a.outcomes)]:
    r=load(ev/label/'result.json');assert r['passed'] and r['client_report_passed'] and r['explicit_completion']
    assert [c['true_exit'] for c in r['children'].values()]==[0] and all(r['eof'].values()) and not r['reader_errors'] and not r['diagnostics']
    bound=next(label for label,b in builds.items() if b['sha256']==r['manifest_sha256'])
    prior=manifests[bound]
    differences={n for n,v in prior['live_source_inputs'].items() if diagnostic['live_source_inputs'].get(n)!=v}
    assert differences <= {'client/godot/OperationsPanel.cs','client/godot/README.md'},differences
    assert prior['supplied_inputs']['client/godot/tests/GuiUsabilityChecks.cs']==diagnostic['supplied_inputs']['client/godot/tests/GuiUsabilityChecks.cs']
    old_dispatch=(Path(prior['stage'])/'source/client/godot/tests/ExportChecks.cs').read_text()
    new_dispatch=(Path(diagnostic['stage'])/'source/client/godot/tests/ExportChecks.cs').read_text()
    addition='if (phase == "gui-outcomes") { await GuiOutcomes(); return; }\n            '
    assert new_dispatch==old_dispatch or new_dispatch.replace(addition,'')==old_dispatch

    # These offline phases instantiate Main/FormPanel/workspace controls but no
    # signed OperationsPanel. Only its received-outcome presentation changed.
    streams(r)
    selected[role]={'label':label,'checks':len(r['checks']),'client_exit':0,'EOF':r['eof'],'receipt_sha256':d.h(ev/label/'result.json'),'executed_manifest':bound,'reused_production_differences':sorted(differences)}
    for image in (TASK/'private'/label/'images').glob('*.png'):d.h(image)
j=load(ev/'inputs'/(a.signed+'.json'));assert j['passed'] and all(c['true_exit']==0 for c in j['children'].values()) and all(j['eof'].values()) and not j['reader_errors']
signed_bound=next(label for label,b in builds.items() if b['sha256']==j['manifest_sha256'])
signed_manifest=manifests[signed_bound]
signed_differences={n for n,v in signed_manifest['live_source_inputs'].items() if product['live_source_inputs'][n]!=v}
assert signed_differences <= {'client/godot/OperationsPanel.cs'}
old_owner=(Path(signed_manifest['stage'])/'source/client/godot/OperationsPanel.cs').read_text()
new_owner=(Path(product['stage'])/'source/client/godot/OperationsPanel.cs').read_text()
assert new_owner==old_owner or new_owner==old_owner.replace('Text=status.Text,Name="operation-outcome"','Text="Received outcome · "+status.Text,Name="operation-outcome"')
assert not j['host_input_or_focus_action'] and j['native_input_count']==0
assert j['children']['client-gui-signed']['explicit_completion'];streams(j)
private=TASK/'private'/a.signed;result=private/'sandbox/work/gui-signed.json';report=load(result);assert report['passed'];d.h(result)
selected['signed']={'label':a.signed,'checks':len(report['checks']),'true_exits':{n:c['true_exit'] for n,c in j['children'].items()},'EOF':j['eof'],'report_sha256':d.h(result),'host_input_count':0,'executed_manifest':signed_bound,'later_product_delta':'received-outcome wording only; native display cases separately qualified','reused_production_differences':sorted(signed_differences)}
for image in (private/'sandbox/work').glob('*.png'):d.h(image)
server=load(ev/'inputs'/('server-'+a.signed+'-server.json'));assert server['child_exit']==0 and not server['runtime_recompiled']
assert len(server['executed_current_sources'])==12
assert d.h(Path(server['clean_source_binding']['path']))==server['clean_source_binding']['sha256']
for n,r in server['executed_current_sources'].items():
    assert d.h(root/n)==r['sha256']==d.h(Path(r['saved_source']))
    if 'compiled_object' in r:
        obj=r['compiled_object'];assert d.h(Path(obj['path']))==obj['sha256'] and Path(obj['path']).stat().st_size==obj['bytes']
for r in server['driver_sources'].values():assert d.h(Path(r['path']))==r['sha256']
server_private=TASK/'private'/('quod-m4-live-'+a.signed+'-server')
for n,r in server['affected_compiled_outputs'].items():assert d.h(server_private/n)==r['sha256'] and (server_private/n).stat().st_size==r['bytes']
delta={};counts={}
for n,r in load(ev/'inputs/before.json').items():
    before=Path(r['before']);assert d.h(before)==r['sha256'] and before.stat().st_mode==r['mode']
    after=d.h(root/n)
    if after==r['sha256']:continue
    delta[n]={'before_path':str(before),'before_sha256':r['sha256'],'after_sha256':after,'full_mode':(root/n).stat().st_mode}
    process=subprocess.run(['git','diff','--no-index','--numstat',str(before),n],capture_output=True,text=True);assert process.returncode==1
    added,removed=map(int,process.stdout.split('\t')[:2]);counts[n]={'added':added,'removed':removed}
assert set(delta)<=set(load(ev/'inputs/before.json'))
assert subprocess.run(['git','diff','--check']).returncode==0 and not subprocess.check_output(['git','diff','--cached','--name-only'])
d.write(dest/'computed-hashes.json')
q={'passed':True,'full_M4_or_M5':False,'full_QUO24_or_human_acceptance':False,'worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','actual_model':'openai-codex:gpt-6-astra','effective_backend_effort':'unexposed',
   'product':builds[a.product],'diagnostic':builds[a.diagnostic],'builds':builds,'selected':selected,'true_wrapper_outcomes':outcomes,'source_delta':delta,'line_delta':counts,
   'old_package_rebuilt':False,'old_API_bytes_read':0,'commit_or_push':False,'review_started':False,'source_sharing_consent':'coordinator-owned; pending at last instruction',
   'server':'unchanged accepted policy/wire/space owners; fresh disposable signed fixture','input_scope':'setup uses Control signals; measured native pointer/keyboard events stay inside the app; zero host input or native XR',
   'digest_cache':{'path':str(dest/'computed-hashes.json'),'sha256':raw(dest/'computed-hashes.json')}}
(ev/'result.json').write_text(json.dumps(q,indent=2)+'\n')
print(json.dumps({'qualified':True,'selected':selected,'changed_sources':len(delta),'line_delta':counts}))
