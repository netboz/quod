"""Check the two new diagnostic exports; reuse prior core/server acceptance."""
import hashlib,json,os,subprocess
from pathlib import Path
root=Path.cwd();ev=Path(__file__).resolve().parent
def load(p):return json.loads(p.read_text())
def h(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
accepted=load(root/'doc/evidence/godot-m4-r2-20261029/inputs/client-final03-manifest.json')['authored_inputs']
result={'builds':{},'production_main':h(root/'client/godot/Main.cs'),'tracked_patch':hashlib.sha256(subprocess.check_output(['git','diff','--binary','HEAD'])).hexdigest(),'server_inputs_changed':False,'server_gates':'unchanged accepted M3b; not rerun','core':'unchanged accepted final03 core189; not rerun','passed':False}
assert result['production_main']=='e9c010f71a9c1369fd5b451fe1d7fa275948089b3a96e69fe6d8f21b543fec1e'
assert result['tracked_patch']=='c0f9395a9b8fe09abcd71aa13ec9917aae9241bf307a5fc4b0af07e0baa4f998'
assert not subprocess.check_output(['git','diff','--cached','--name-only'])
for label in ['physical01','physical02']:
    manifest=load(ev/'inputs'/('client-'+label+'-manifest.json'));stage=Path(manifest['stage']);source=stage/'source';dist=Path(manifest['export_executable']).parent
    assert manifest['passed'] and manifest['diagnostic_physical_partial'] and not manifest['compiled_application_inputs_copied'] and not manifest['distributable']
    assert manifest['live_source_inputs']==accepted
    assert all(h(root/n)==digest for n,digest in accepted.items())
    assert len(manifest['supplied_inputs'])==92 and len(manifest['diagnostic_overrides'])==1
    assert set(manifest['supplied_inputs'])==set(accepted)|{'client/godot/tests/PhysicalChecks.cs'}
    assert all(h(source/n)==digest for n,digest in manifest['supplied_inputs'].items())
    actual={str(p.relative_to(dist)):p for p in dist.rglob('*') if p.is_file()}
    assert set(actual)==set(manifest['export_outputs']) and len(actual)==196
    assert all(h(actual[n])==r['sha256'] and actual[n].stat().st_size==r['bytes'] for n,r in manifest['export_outputs'].items())
    commands=[]
    outer=load(ev/'logs'/('physical-client'+label[-2:]+'-build.json'))
    assert outer['child_exit']==0 and not outer['timed_out']
    for row in manifest['commands']:
        assert row['wrapper_exit']==0
        receipt=load(ev/('client-'+label+'-'+row['phase'])/'result.json')
        assert receipt['exit']==0 and not receipt['diagnostic_failure'] and receipt['command']==row['command']
        commands.append({'phase':row['phase'],'wrapper_exit':0,'true_child_exit':receipt['exit'],'completion_evidence':'check.py writes receipt after subprocess.run returns; final manifest passed; outer true0/no timeout','no_timeout':True})
    result['builds'][label]={'supplied_inputs':92,'unchanged_live_inputs':91,'actual_export_files':196,'commands':commands,'engine':manifest['export_outputs']['quod.x86_64'],'dll':manifest['export_outputs']['data_Quod_linuxbsd_x86_64/Quod.dll'],'pck':manifest['export_outputs']['quod.pck'],'diagnostic_only':True,'stage':str(stage),'manifest_sha256':h(ev/'inputs'/('client-'+label+'-manifest.json'))}
result['passed']=True
(ev/'inputs/new-build-verification01.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
