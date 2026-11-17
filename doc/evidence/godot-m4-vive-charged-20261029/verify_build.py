"""Check the new diagnostic's actual source, nested exits and payload paths."""
import hashlib,json,sys
from pathlib import Path

root=Path.cwd();ev=Path(__file__).resolve().parent
label,preflight_name,wrapper_label=sys.argv[1:]
manifest=json.loads((ev/'inputs'/('client-'+label+'-manifest.json')).read_text())
def digest(path):
    with Path(path).open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
assert manifest['passed'] and manifest['diagnostic_physical_partial']
assert not manifest['compiled_application_inputs_copied'] and not manifest['distributable']
baseline=json.loads((root/'doc/evidence/godot-m4-r2-20261029/inputs/client-final03-manifest.json').read_text())
assert manifest['live_source_inputs']==baseline['authored_inputs']
source=Path(manifest['stage'])/'source'
for name,expected in manifest['live_source_inputs'].items():assert digest(root/name)==expected
for name,expected in manifest['supplied_inputs'].items():assert digest(source/name)==expected
assert set(manifest['diagnostic_overrides'])=={'client/godot/tests/ExportChecks.cs'}
assert set(manifest['supplied_inputs'])-set(manifest['live_source_inputs'])=={'client/godot/tests/PhysicalChecks.cs'}
pre=json.loads((ev/'inputs'/preflight_name).read_text())
for name,row in pre['pre_execution_copies'].items():assert digest(root/name)==row['sha256'] and digest(row['path'])==row['sha256']
commands=[]
for row in manifest['commands']:
    receipt=json.loads((ev/('client-'+label+'-'+row['phase'])/'result.json').read_text())
    assert row['wrapper_exit']==0 and receipt['exit']==0 and not receipt['diagnostic_failure']
    commands.append({'phase':row['phase'],'true_child_exit':receipt['exit'],'diagnostic_failure':receipt['diagnostic_failure']})
dist=Path(manifest['export_executable']).parent
files={str(p.relative_to(dist)):p for p in dist.rglob('*') if p.is_file()}
assert set(files)==set(manifest['export_outputs'])
for name,row in manifest['export_outputs'].items():assert files[name].stat().st_size==row['bytes']
payload={}
for basename in ['Quod.dll','quod.pck',Path(manifest['export_executable']).name]:
    matches=[name for name in files if Path(name).name==basename];assert len(matches)==1
    name=matches[0];row=manifest['export_outputs'][name]
    assert digest(files[name])==row['sha256'];payload[name]=row
assert payload[Path(manifest['export_executable']).name]['sha256']=='02310d903099bada10c86cedc90bbc11ef0bec8254d6e607d1a53f6150ab0268'
wrapper=json.loads((root/'doc/evidence/godot-m4-vive-physical-20261029/logs'/(wrapper_label+'.json')).read_text())
assert wrapper['child_exit']==0 and all(wrapper['eof'].values()) and not wrapper['reader_errors'] and not wrapper.get('timed_out')
result={'passed':True,'supplied_inputs':len(manifest['supplied_inputs']),'unchanged_live_inputs':len(manifest['live_source_inputs']),
        'actual_export_paths_and_sizes_checked':len(files),'actual_payload_byte_hashes_checked':payload,'commands':commands,
        'pre_execution_helper_copies_checked':len(pre['pre_execution_copies']),
        'full_output_hash_admission':'Build computed every export hash; the unchanged launch owner independently hashes every actual export before native invocation.',
        'core189_and_server1432':'unchanged accepted evidence reused, not rerun','distributable':False}
(ev/'inputs'/('client-'+label+'-verified.json')).write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
