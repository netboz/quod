"""Verify the exact before/after dependency delta and actual invoked payloads."""
import hashlib,json,stat
from pathlib import Path
from environment import TASK
ev=Path(__file__).resolve().parent
def h(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
source=TASK/'builds/engine01/godot-4.7.2-stable';original=json.loads((source.parent/'original-source-manifest.json').read_text());changed=[]
for row in original:
    p=source/row['path'];assert p.exists() or p.is_symlink(),p
    assert p.lstat().st_mode&0o7777==row['mode'],p
    if row['type']=='file' and h(p)!=row['sha256']:changed.append(row['path'])
assert set(changed)=={'modules/openxr/openxr_interface.cpp','modules/openxr/extensions/spatial_entities/openxr_spatial_marker_tracking.cpp'},changed
client=json.loads((ev/'inputs/client-private01-manifest.json').read_text());assert client['passed']
assert len(client['supplied_inputs'])==91
assert all(h(Path.cwd()/n)==d and h(Path(client['stage'])/'source'/n)==d for n,d in client['supplied_inputs'].items())
cases={}
for label in ['native-sim-baseline01','native-sim-patched01']:
    result=json.loads((ev/label/'result.json').read_text());executable=Path(result['client_command'][0]);dist=executable.parent
    actual={str(p.relative_to(dist)):{'sha256':h(p),'bytes':p.stat().st_size} for p in sorted(dist.rglob('*')) if p.is_file()}
    expected=client['export_outputs'];assert set(actual)==set(expected)
    different=[n for n in actual if actual[n]!=expected[n]]
    assert different==(['quod.x86_64'] if label=='native-sim-baseline01' else []),different
    assert h(executable)==result['engine_sha256']
    cases[label]={'executable':str(executable),'engine_sha256':h(executable),'actual_export_outputs':actual,'different_from_fresh_export':different,'pck_sha256':h(dist/'quod.pck'),'note':'Original result.application_payload inventories the supplied fresh export, including its patched engine. This additive receipt inventories the actual invocation directory, including the baseline engine substitution. No application assembly, data or PCK differs.'}
    (ev/label/'actual-invoked-outputs.json').write_text(json.dumps(cases[label],indent=2)+'\n')
receipt={'private_engine_original_entries':len(original),'changed_original_engine_inputs':changed,'quod_supplied_inputs_unchanged':91,'source_only_export_outputs':len(client['export_outputs']),'compiled_application_inputs_copied':False,'native_cases':{k:{n:v for n,v in r.items() if n!='actual_export_outputs'} for k,r in cases.items()},'production_main_sha256':h(Path('client/godot/Main.cs')),'managed_api':'No ClassDB/API change; exact official managed SDK/library archive bytes reused through cold locked restore. Both engines execute the same freshly compiled application.'}
(ev/'inputs/final-input-audit.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt))
