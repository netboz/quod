"""Check final source/exports/true exits and retain every failed causal attempt."""
import difflib,hashlib,json,subprocess,sys
from pathlib import Path
from digests import Digests,raw
root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests();h=d.h
old=Path('/data/quod-m4-vr-ca84d4f8-20261029/builds/coordinator-physical-source-reconstruction-53')
def load(p):return json.loads(Path(p).read_text())
def write(p,v):assert not p.exists();p.write_text(json.dumps(v,indent=2)+'\n')
builds={}
for label,wrapper in [('presentation-baseline01','presentation-baseline-build01'),('presentation-final01','presentation-final-build01'),('presentation-resize-diagnostic01','presentation-resize-diagnostic-build01'),('presentation-final02','presentation-final-build02')]:
    m=load(ev/'inputs'/('client-'+label+'-manifest.json'));assert m['passed'] and not m['compiled_application_inputs_copied'] and not m['diagnostic_overrides']
    assert len(m['supplied_inputs'])==92 and len(m['export_outputs'])==196
    source=Path(m['stage'])/'source'
    for name,digest in m['supplied_inputs'].items():assert h(source/name)==digest
    cache=m['digest_cache'];assert raw(cache['path'])==cache['sha256']
    for row in load(cache['path'])['records']:d.values[tuple(row['stat_key'])]=row['sha256']
    dist=Path(m['export_executable']).parent;files={str(p.relative_to(dist)):p for p in dist.rglob('*') if p.is_file()}
    assert set(files)==set(m['export_outputs'])
    for name,row in m['export_outputs'].items():assert files[name].stat().st_size==row['bytes'] and h(files[name])==row['sha256']
    commands=[]
    for row in m['commands']:
        r=load(ev/('client-'+label+'-'+row['phase'])/'result.json');assert row['wrapper_exit']==r['exit']==0 and not r['diagnostic_failure'] and row['command']==r['command']
        commands.append({'phase':row['phase'],'true_child_exit':r['exit'],'receipt':str(ev/('client-'+label+'-'+row['phase'])/'result.json')})
    w=load(root/'doc/evidence/godot-m4-vive-physical-20261029/logs'/(wrapper+'.json'));assert w['child_exit']==0 and all(w['eof'].values()) and not w['reader_errors'] and not w.get('timed_out')
    builds[label]={'supplied_inputs':len(m['supplied_inputs']),'outputs':len(files),'commands':commands,'outer_exit':w['child_exit'],'eof':w['eof'],'payload':{n:m['export_outputs'][n] for n in ['quod.x86_64','quod.pck','data_Quod_linuxbsd_x86_64/Quod.dll']}}
final=load(ev/'inputs/client-presentation-final02-manifest.json')
for name,digest in final['supplied_inputs'].items():assert h(root/name)==digest
assert all(final['supplied_inputs'][n]==digest for n,digest in final['accepted_final03_inputs'].items() if n.startswith('client/godot/Core/'))
assert h(root/'client/godot/Main.cs')=='e9c010f71a9c1369fd5b451fe1d7fa275948089b3a96e69fe6d8f21b543fec1e'
assert 'M4_PANEL_RESIZE' not in (root/'client/godot/tests/ControllerChecks.cs').read_text()
cases={}
for label,expected in [('presentation-baseline-render01',1),('presentation-final-render01',0),('presentation-controller-final01',1),('presentation-resize-diagnostic-check01',1),('presentation-final-render02',0),('presentation-controller-final02',0),('presentation-scene-final02',0)]:
    r=load(ev/label/'result.json');w=load(root/'doc/evidence/godot-m4-vive-physical-20261029/logs'/(label+'.json'))
    assert r['client_exit']==w['child_exit']==expected and all(r['eof'].values()) and all(w['eof'].values()) and not r['reader_errors'] and not w['reader_errors'] and not w.get('timed_out') and 'capture' not in r
    if expected==0:assert r['passed'] and r['completion_marker']
    else:assert not r['passed'] and not r['completion_marker']
    if label.endswith('02'):assert r['manifest_sha256']==h(ev/'inputs/client-presentation-final02-manifest.json')
    client=load(ev/label/'client-result.json') if (ev/label/'client-result.json').exists() else None
    probes=sum('name' in x for x in client.get('reports',[])) if client else 0
    cases[label]={'true_client_exit':r['client_exit'],'true_driver_exit':w['child_exit'],'eof':r['eof'],'wrapper_eof':w['eof'],'passed':r['passed'],'checks':len(client.get('checks',[]))+probes if client else None,'native_input':r['native_input'],'client_result':str(ev/label/'client-result.json') if client else None}
before=load(ev/'presentation-baseline-render01/client-result.json');after=load(ev/'presentation-final-render02/client-result.json')
assert len(before['failures'])==4 and not after['failures']
rasters=lambda c:{r['raster']:r for r in c['reports'] if 'raster' in r}
assert rasters(before)['original']['lit']==rasters(before)['restored']['lit']==0
assert rasters(after)['original']['lit']==rasters(after)['restored']['lit']==rasters(before)['ambient-white']['lit']==1810
delta={};patch=[]
for name in ['client/godot/OpenXRInput.cs','client/godot/ScenePanel.cs','client/godot/tests/ControllerChecks.cs','client/godot/tests/ExportChecks.cs','client/godot/README.md']:
    a=(old/name).read_text().splitlines(True);b=(root/name).read_text().splitlines(True)
    diff=list(difflib.unified_diff(a,b,fromfile='a/'+name,tofile='b/'+name));patch.extend(diff)
    delta[name]={'before_sha256':h(old/name),'after_sha256':h(root/name),'added':sum(l.startswith('+') and not l.startswith('+++') for l in diff),'removed':sum(l.startswith('-') and not l.startswith('---') for l in diff)}
new='client/godot/tests/PresentationChecks.cs';delta[new]={'before':None,'after_sha256':h(root/new),'added':len((root/new).read_text().splitlines()),'removed':0}
write(ev/'inputs/source-delta.json',delta);(ev/'inputs/previous-source-delta.patch').write_text(''.join(patch))
qualification={'checkpoint':'QUO-65 charged-controller and bounded presentation correction','builds':builds,'cases':cases,'final_exact_source':final['supplied_inputs'],'final_payload':builds['presentation-final02']['payload'],'production_changes':2,'production_source_deltas':{n:r for n,r in delta.items() if n in ['client/godot/OpenXRInput.cs','client/godot/ScenePanel.cs']},'temporary_resize_trace_removed':True,'server1432_and_core189':'unchanged accepted M3b/server and final03/core189 reused; no recount campaign','new_native_or_physical_case_after_presentation':False,'full_m4_accepted':False,'remaining':['Physical readability, contrast and comfort after these exact changes','Current readiness then formal90draw gate, signed mapped GUI/subject/model/movement gestures and physical focus/disconnect/reentry','Original gui-final03-backup-import and physics-final06 desktop stalls remain failed/unattributed','Legacy/replacement native obligations outside specific already verified cleanup cases; no Quest acceptance'],'source_relocations':0,'source_only':True,'source_delta':'inputs/source-delta.json','stat_bound_cache_hits':d.hits,'new_files_hashed':d.new,'new_bytes_hashed':d.bytes}
write(ev/'qualification.json',qualification);d.write(ev/'inputs/verification-digests.json')
print(json.dumps({'passed':True,'builds':len(builds),'retained_failed_cases':[n for n,r in cases.items() if not r['passed']],'final_checks':{n:r['checks'] for n,r in cases.items() if n.endswith('02')},'final_deltas':delta,'full_m4_accepted':False}))
