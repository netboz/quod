"""Bind only the new case21/cue/placement scope, reusing exact-stat output custody."""
import json,os,stat,subprocess
from pathlib import Path
from hashes import Digests,TASK,key,raw
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
def load(p):return json.loads(Path(p).read_text())
def write(p,v):Path(p).write_text(json.dumps(v,indent=2)+'\n')
cache=root/'_build/godot-m4-r2-coordinator-20261029/placement-final-hashes-129-corrected.json'
assert raw(cache)=='d01575300079692c2e07ec2b6d491f7dfd52cb4007cee6c7b605695341e4dad1'
for r in load(cache)['records'].values():d.values[tuple(r['key'])]=r['sha256']
manifests=sorted((ev/'inputs').glob('client-*-manifest.json'))
manifests += [root/'doc/evidence/godot-m4-vive-workspace-cue-20261031/inputs/client-workspace-cue01-manifest.json',root/'doc/evidence/godot-m4-vive-space-action-cue-20261031/inputs/client-space-action-cue01-manifest.json']
builds={}
for path in manifests:
    m=load(path);name=path.name[len('client-'):-len('-manifest.json')];stage=Path(m['stage'])/'source'
    record={'manifest':str(path),'manifest_sha256':d.h(path),'passed':m['passed'],'inputs':len(m['supplied_inputs']),'commands':[]}
    assert not m['compiled_application_inputs_copied'] and m['template']['sha256']=='02310d903099bada10c86cedc90bbc11ef0bec8254d6e607d1a53f6150ab0268'
    for command in m['commands']:
        rpath=path.parent.parent/('client-'+name+'-'+command['phase'])/'result.json';r=load(rpath)
        assert r['exit']==command['wrapper_exit'];record['commands'].append({'phase':command['phase'],'true_exit':r['exit'],'receipt_sha256':d.h(rpath)})
    if m['passed']:
        assert len(record['commands'])==5 and all(x['true_exit']==0 for x in record['commands'])
        cachepath=Path(m['digest_cache']['path']);assert raw(cachepath)==m['digest_cache']['sha256']
        for r in load(cachepath)['records']:d.values[tuple(r['stat_key'])]=r['sha256']
        for n,digest in m['supplied_inputs'].items():assert key(stage/n) in d.values and d.h(stage/n)==digest
        dist=Path(m['export_executable']).parent
        assert {str(p.relative_to(dist)) for p in dist.rglob('*') if p.is_file()}==set(m['export_outputs']) and len(m['export_outputs'])==196
        for n,r in m['export_outputs'].items():assert key(dist/n) in d.values and d.h(dist/n)==r['sha256'] and (dist/n).stat().st_size==r['bytes']
        record.update(exports=196,export_bytes=sum(r['bytes'] for r in m['export_outputs'].values()),digest_cache=m['digest_cache'],export_bytes_rehashed=0)
    else:
        assert name=='placement-baseline01' and [x['true_exit'] for x in record['commands']]==[0,0,0,0,1]
        for n,digest in m['supplied_inputs'].items():assert d.h(stage/n)==digest
        record['failure']='Retained test-only CS1503 constructor error; no completed export credited.'
    builds[name]=record
assert len(builds)==5 and sum(b['passed'] for b in builds.values())==4
selected=load(ev/'inputs/client-placement-final01-manifest.json')
for n,digest in selected['live_source_inputs'].items():assert key(root/n) in d.values and d.h(root/n)==digest
assert len(selected['supplied_inputs'])==93 and selected['distributable'] and not selected['diagnostic_overrides']
gates={}
for suffix,count in [('headless01',36),('render01',47),('controller01',67)]:
    name='placement-final01-'+suffix;folder=ev/name;r=load(folder/'result.json');c=load(folder/'client-result.json');w=load(ev/'logs'/(name+'.json'))
    assert r['client_exit']==w['child_exit']==0 and r['passed'] and all(r['eof'].values()) and not r['reader_errors'] and not r.get('capture')
    assert len(c['checks'])==count and r['manifest_sha256']==builds['placement-final01']['manifest_sha256']
    for kind in ['stdout','stderr']:
        p=TASK/'private'/name/(kind+'.raw');assert stat.S_IMODE(p.stat().st_mode)==0o600 and stat.S_IMODE(p.parent.stat().st_mode)==0o700
        assert d.h(p)==d.h(folder/(kind+'.log'))
    gates[name]={'client_exit':r['client_exit'],'wrapper_exit':w['child_exit'],'checks':count,'seam_reports':len([x for x in c.get('reports',[]) if 'passed' in x]),'eof':r['eof'],'reader_errors':r['reader_errors'],'capture':r.get('capture')}
baseline=load(ev/'placement-baseline02-headless01/result.json')
assert baseline['client_exit']==1 and not baseline['passed'] and all(baseline['eof'].values())
failure_text=(ev/'placement-baseline02-headless01/stderr.log').read_text()
assert 'first tilted tracked head opens an upright workspace' in failure_text and "Object name: 'FormPanel'" in failure_text
delta={}
for n in ['client/godot/OpenXRInput.cs','client/godot/README.md','client/godot/tests/WorkspaceChecks.cs']:
    before=ev/'inputs'/(Path(n).name+'.before');after=root/n
    diff=subprocess.run(['git','diff','--no-index','--numstat',str(before),str(after)],capture_output=True)
    assert diff.returncode==1 and not diff.stderr;added,removed,_=diff.stdout.decode().split('\t',2)
    delta[n]={'before_sha256':d.h(before),'after_sha256':d.h(after),'before_bytes':before.stat().st_size,'after_bytes':after.stat().st_size,'mode':stat.S_IMODE(after.stat().st_mode),'added_lines':int(added),'removed_lines':int(removed)}
assert delta['client/godot/OpenXRInput.cs']['added_lines']==5 and delta['client/godot/OpenXRInput.cs']['removed_lines']==1
write(ev/'source-delta.json',{'inherited_files':delta,'production_owner':'OpenXRInput','production_delta':'+5/-1','Core_server_ontology_engine_runtime_policy_changes':False})
old=load(root/'doc/evidence/godot-m4-workspace-20261030/inputs/client-workspace-final06-manifest.json')
assert {n for n,v in selected['supplied_inputs'].items() if v!=old['supplied_inputs'][n]}==set(delta)
for name,nchecks in [('workspace-cue',12),('space-action-cue',14)]:
    cue=root/'doc/evidence'/('godot-m4-vive-'+name+'-20261031');r=load(cue/'binding-checks.json')
    assert r['passed'] and r['count']==nchecks and load(cue/'logs'/(name+'-binding01.json'))['child_exit']==0
action=load(root/'doc/evidence/godot-m4-vive-space-action-cue-20261031/inputs/client-space-action-cue01-manifest.json')
assert action['live_source_inputs']==selected['supplied_inputs'] and len(action['supplied_inputs'])==95 and not action['distributable']
case_path=root/'doc/evidence/godot-m4-vive-mapped21-20261031/qualification.json';case=load(case_path)
assert case['protocol_retirement_passed'] and case['placement_usability']=='FAILED' and not case['target_activation_passed']
q={'scope':'Case21 closed human placement failure; bounded upright correction and offline one-action diagnostic preparation only.',
    'selected':'placement-final01','manifest':builds['placement-final01'],'selected_gates':gates,'builds':builds,
    'DLL':selected['export_outputs']['data_Quod_linuxbsd_x86_64/Quod.dll']['sha256'],'PCK':selected['export_outputs']['quod.pck']['sha256'],'engine':selected['template']['sha256'],
    'diagnostic':{'name':'space-action-cue01','manifest':builds['space-action-cue01'],'DLL':action['export_outputs']['data_Quod_linuxbsd_x86_64/Quod.dll']['sha256'],'PCK':action['export_outputs']['quod.pck']['sha256'],'distributable':False,'functional_or_native_execution':'UNRUN'},
    'case21':{'qualification_path':str(case_path),'sha256':d.h(case_path),'controller_visibility':'positive','GUI_appearance':'improved','placement':'FAILED','LEFT_action':'UNRUN/not accessibly instructed','exact_human_interval':None},
    'baseline02':'Actual client/wrapper1 at tilted-head obligation, explicit EOF. Secondary FormPanel callback failure during assertion unwind retained; test callback now detaches on TreeExiting.',
    'failed_baseline01':'Actual compiler/outer1 from test-only invalid Basis constructor; separately corrected source label02, no product failure credit.',
    'root129_cache':{'path':str(cache),'sha256':raw(cache)},'new_export_bytes_rehashed':0,'API_bytes_read':0,
    'reused':'Accepted unchanged core189/server1432 and unaffected scene/presentation obligations; no suite/native/history recount.',
    'limits':['Later numeric geometry is not the unknown human look interval.','First valid head timing versus wearing and initial heading remain unproven; no wear detection, head-follow or calibration reset was added.','Upright placement uses the actual tracked head reference, not an anatomical/IPD estimate.','Cue text/layout bindings are offline evidence, not physical readability/reachability/LEFT-gesture acceptance.'],
    'new_case22_authorized_or_launched':False,'fullM4_commit_M5':False}
write(ev/'qualification.json',q);d.write(TASK/'cache/placement-final01-qualification-hashes.json')
write(ev/'receipt-cache.json',{'path':str(TASK/'cache/placement-final01-qualification-hashes.json'),'sha256':raw(TASK/'cache/placement-final01-qualification-hashes.json'),'API_bytes_read':0,'export_bytes_rehashed':0})
print(json.dumps({'qualified':True,'build_attempts':5,'successful_builds':4,'selected_gates':3,'current_inputs':93,'prepared_diagnostic_inputs':95,'exports_each':196,'API_bytes_read':0,'new_native_cases_after21':0}))
