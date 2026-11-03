"""Bind the finite native text-input slice to its actual sources and results."""
import argparse,json,os,stat,subprocess,shutil
from pathlib import Path
from hashes import TASK,Digests,key,raw
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
p=argparse.ArgumentParser()
for name in ['product','diagnostic','editing','ray','controller','workspace','signed','label']:p.add_argument('--'+name,required=True)
a=p.parse_args();dest=TASK/'private'/a.label;dest.mkdir(mode=0o700,exist_ok=False)
for original in [Path(__file__).resolve(),ev/'hashes.py']:shutil.copy2(original,dest/original.name)
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
        dist=Path(m['export_executable']).parent;assert len(m['export_outputs'])==196
        assert set(m['export_outputs'])=={str(f.relative_to(dist)) for f in dist.rglob('*') if f.is_file()}
        for n,r in m['export_outputs'].items():assert d.h(dist/n)==r['sha256'] and (dist/n).stat().st_size==r['bytes']
    label=stage.name.removeprefix('client-');manifests[label]=m
    builds[label]={'path':str(path),'sha256':d.h(path),'passed':m['passed'],'supplied':len(m['supplied_inputs']),'live':len(m['live_source_inputs']),'phase_exits':[c.get('true_exit') for c in m['commands']]}
product=manifests[a.product];diagnostic=manifests[a.diagnostic]
assert product['passed'] and product['trace_free'] and not product['diagnostic_overrides']
assert diagnostic['passed'] and not diagnostic['trace_free'] and not diagnostic['distributable']
assert set(diagnostic['diagnostic_overrides'])=={'client/godot/tests/ExportChecks.cs','client/godot/tests/KeyboardChecks.cs','client/godot/tests/KeyboardSignedChecks.cs'}
assert product['live_source_inputs']==product['supplied_inputs']==diagnostic['live_source_inputs']
assert len(product['live_source_inputs'])==98 and len(diagnostic['supplied_inputs'])==100
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
        assert path.is_relative_to(TASK) and stat.S_IMODE(path.stat().st_mode)==0o600
        assert stat.S_IMODE(path.parent.stat().st_mode)==0o700
        assert d.h(path)==r['sha256'] and path.stat().st_size==r['bytes']
selected={}
for role,label in [('editing',a.editing),('ray',a.ray),('controller',a.controller),('workspace',a.workspace)]:
    r=load(ev/label/'result.json');assert r['passed'] and r['client_report_passed'] and r['explicit_completion']
    assert [c['true_exit'] for c in r['children'].values()]==[0] and all(r['eof'].values()) and not r['reader_errors'] and not r['diagnostics']
    assert r['manifest_sha256']==builds[a.diagnostic]['sha256'];streams(r)
    assert not r['physical'] and not r['native_runtime_started'] and not r['hardware_queried'] and not r['display_or_focus_action']
    selected[role]={'label':label,'checks':len(r['checks']),'client_exit':0,'EOF':r['eof'],'receipt_sha256':d.h(ev/label/'result.json'),'executed_manifest':a.diagnostic}
    for image in (TASK/'private'/label/'images').glob('*.png'):d.h(image)
j=load(ev/'inputs'/(a.signed+'.json'));assert j['passed'] and all(c['true_exit']==0 for c in j['children'].values()) and all(j['eof'].values()) and not j['reader_errors']
assert j['manifest_sha256']==builds[a.diagnostic]['sha256'] and not j['host_input_or_focus_action'] and j['native_input_count']==0
assert j['children']['client-keyboard-signed']['explicit_completion'];streams(j)
private=TASK/'private'/a.signed;result=private/'sandbox/work/keyboard-signed.json';report=load(result);assert report['passed'];d.h(result)
selected['signed']={'label':a.signed,'checks':len(report['checks']),'true_exits':{n:c['true_exit'] for n,c in j['children'].items()},'EOF':j['eof'],'report_sha256':d.h(result),'host_input_count':0,'executed_manifest':a.diagnostic}
for image in (private/'sandbox/work').glob('*.png'):d.h(image)
server=load(ev/'inputs'/('server-'+a.signed+'-server.json'));assert server['child_exit']==0 and not server['runtime_recompiled'] and len(server['executed_current_sources'])==12
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
new='client/godot/SpatialKeyboard.cs';counts[new]={'added':len((root/new).read_text().splitlines()),'removed':0}
assert subprocess.run(['git','diff','--check']).returncode==0 and not subprocess.check_output(['git','diff','--cached','--name-only'])
d.write(dest/'computed-hashes.json')
q={'passed':True,'full_M4_or_M5':False,'full_QUO65_or_human_acceptance':False,'worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','actual_model':'openai-codex:gpt-6-astra','effective_backend_effort':'unexposed',
   'product':builds[a.product],'diagnostic':builds[a.diagnostic],'builds':builds,'selected':selected,'true_wrapper_outcomes':outcomes,'source_delta':delta,'new_product_sources':[new],'line_delta':counts,
   'old_package_rebuilt':False,'old_API_bytes_read':0,'commit_or_push':False,'review_started':False,'source_sharing_consent':'coordinator-owned; pending at last instruction',
   'server':'unchanged accepted policy/wire/space owners; fresh disposable signed fixture','input_scope':'setup uses Control signals; typing and rays use native in-process events/injected XRServer; zero host input or native XR',
   'limitations':['fixed AZERTY subset; hardware/platform input for other text','Main BackupDialog remains a separate desktop-only window','no human or headset ergonomics acceptance','historical shutdown pauses unresolved'],
   'digest_cache':{'path':str(dest/'computed-hashes.json'),'sha256':raw(dest/'computed-hashes.json')}}
(ev/'result.json').write_text(json.dumps(q,indent=2)+'\n')
print(json.dumps({'qualified':True,'selected':selected,'changed_sources':len(delta),'new_product_sources':[new],'line_delta':counts}))
