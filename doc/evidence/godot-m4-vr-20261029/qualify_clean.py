"""Exact clean output equality permits reuse of the actual native observations."""
import hashlib,json,subprocess
from pathlib import Path
from environment import TASK
ev=Path(__file__).resolve().parent;out=ev/'clean-build';out.mkdir(exist_ok=False)
def load(p):return json.loads(p.read_text())
def h(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
build=load(TASK/'artifacts/engine/clean02/receipt.json');assert build['passed'] and build['clean_source_only'] and not build['compiled_inputs_copied']
first=TASK/'artifacts/engine/patched01/godot.linuxbsd.template_release.x86_64.mono';clean=Path(build['binary'])
comparison=['cmp','-s',str(first),str(clean)];result=subprocess.run(comparison)
assert result.returncode==0 and h(first)==h(clean)=='02310d903099bada10c86cedc90bbc11ef0bec8254d6e607d1a53f6150ab0268'
source=Path(build['source']);original=load(TASK/'builds/engine01/original-source-manifest.json');deltas=load(TASK/'artifacts/engine/patch01/manifest.json')
for row in original:
    p=source/row['path'];assert p.lstat().st_mode&0o7777==row['mode'],row['path']
    if row['type']=='file':assert h(p)==deltas.get(row['path'],{}).get('after',row['sha256']),row['path']
state=load(source/'.scons_env.json');assert state['cache_path']=='' and state['CC']=='gcc' and state['CXX']=='g++'
assert set(state.get('ENV',{}))<= {'PATH','PKG_CONFIG_PATH','TERM'}
toolchain=load(TASK/'artifacts/toolchain-live-check02.json');assert toolchain['passed']
python=load(TASK/'artifacts/python-stdlib-inputs02/receipt.json');assert python['passed']
checks=[]
for label in ['engine-clean-build01','engine-clean-build02','toolchain-live-check02','python-stdlib-inputs02']:
    receipt=load(ev/'logs'/(label+'.json'))
    assert receipt['child_exit']==(1 if label=='engine-clean-build01' else 0) and not receipt['timed_out']
    for section in ['private_streams','sanitized_streams']:
        for stream in receipt[section].values():
            p=Path(stream['path']);assert p.stat().st_size==stream['bytes'] and h(p)==stream['sha256']
    for name,digest in receipt['driver_inputs'].items():assert h(TASK/'private/runs'/label/'driver-inputs'/name)==digest
    checks.append({'label':label,'true_child_exit':receipt['child_exit'],'timed_out':False,'elapsed_seconds':receipt['elapsed_seconds'],'receipt_sha256':h(ev/'logs'/(label+'.json'))})
proof=load(TASK/'builds/engine-clean02/source-reconstruction.json')
qualification={'passed':True,'checkpoint':'QUO-65 additive clean private engine provenance','worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','actual_api_model':'openai-codex:gpt-6.1-sol','launcher_requested_effort':'max','effective_backend_effort':'unexposed','production_test_spec_changes':0,'clean_source_only_native_build':build,'actual_full_byte_comparison':{'command':comparison,'true_exit':result.returncode,'identical':True},'official_source_and_actual_patch_application':proof,'all_original_authored_input_paths_content_modes_still_verified_after_build':len(original),'scons_cache_path':state['cache_path'],'native_compiler':{'CC':state['CC'],'CXX':state['CXX'],'production':state['production'],'debug_symbols':state['debug_symbols'],'lto':state['lto'],'accesskit':state['accesskit']},'actual_live_toolchain_comparison':toolchain,'python_standard_library_provider':python,'commands':checks,
    'qualified_native_evidence_reused_by_exact_binary_identity':['native-sim-baseline01 counterfactual vs native-sim-patched01: same application payload, only engine differs; patched18checks/3adaptercycles/one native session, client/runtime/wrapper0/EOF and no target diagnostics.','native-fault-reentry01: deliberate output exception true client1 releases session; next exact application on same runtime passes18/client0, runtime/wrapper0/EOF.','vive-display-observation03: exact same engine in diagnostic observer export, actual human both-lens Quod/green observation and native close0/EOF; zero current valid wand samples, no mapped-gesture/comfort claim.'],
    'first_failed_clean_attempt':'engine-clean-build01 failed full-mode assertion before compiling: real git apply recreated two text files under private077 umask as0600. Failed source/driver/logs preserved. Separately labelled clean02 restores the recorded original0644 modes explicitly and retains the same full-mode assertion. No product assertion relaxed.',
    'previous_immutable_boundary':'/data/quod-m4-vr-ca84d4f8-20261029/artifacts/quod-godot-m4-vr-handoff-ca84d4f8-20261029-01','previous_snapshot_sha256':'5af20d5f7b168c53f2eab7d4524862a9db2957169a66879d29b0bdd23ad817fe','original_desktop_stalls_resolved':False,'cold_hardware_head_assertion_resolved':False,'production_export_physical_controller_accepted':False,'full_M4_accepted':False,'commit':False,'M5':False}
(out/'qualification.json').write_text(json.dumps(qualification,indent=2)+'\n');print(json.dumps({'passed':True,'engine_sha256':h(clean),'full_binary_comparison_exit':0,'original_authored_entries':len(original),'new_product_or_native_campaigns':0,'explicit_completion':True}))
