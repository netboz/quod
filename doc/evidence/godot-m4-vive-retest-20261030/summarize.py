"""Bind the new failed campaigns, metadata checks and unchanged product scope."""
import hashlib,json,subprocess,sys
from pathlib import Path
sys.dont_write_bytecode=True
ev=Path(__file__).resolve().parent;root=Path.cwd()
def load(p):return json.loads(Path(p).read_text())
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def write(p,r):Path(p).write_text(json.dumps(r,indent=2)+'\n')
checks={}
for name in ['server-runtime-restoration01','server-runtime-restoration02','server-runtime-restoration03',
 'server-runtime-restoration04','server-runtime-restoration05','server-owner-layout-probe01',
 'server-app-lookup-counterfactual01','server-closure-preflight01','server-closure-verification02',
 'current-connector-observation01','current-connector-exception01']:
 p=ev/name/'result.json';r=load(p)
 checks[name]={'receipt':str(p.relative_to(root)),'receipt_sha256':sha(p),
  'true_child_exit':r['exit'],'command':r['command'],'full_log_sha256':sha(p.parent/'output.log')}
cases={}
for number in ['08','09']:
 name='native-vive-product'+number;r=load(ev/name/'result.json')
 wrapper=ev.parent/'godot-m4-vive-physical-20261029/logs'/(name+'-run.json');w=load(wrapper)
 assert w['child_exit']==1 and all(w['eof'].values()) and not w['reader_errors']
 assert not r['passed'] and not r['product_finished'] and not r['reader_errors'] and all(r['eof'].values())
 cases[name]={'case_receipt':str((ev/name/'result.json').relative_to(root)),
  'case_receipt_sha256':sha(ev/name/'result.json'),'wrapper_receipt':str(wrapper.relative_to(root)),
  'wrapper_receipt_sha256':sha(wrapper),'driver_exit':w['child_exit'],'wrapper_exit':1,
  'server_exit':r['server_exit'],'runtime_exit':r.get('runtime_exit'),'client_launched':False,
  'eof':r['eof'],'wrapper_eof':w['eof'],'reader_errors':r['reader_errors'],
  'elapsed_seconds':w['elapsed_seconds'],'completed_product_campaign':False,
  'watchdog_expired':False,'retained_failure':r['error'],'raw_streams_private':True}
assert cases['native-vive-product08']['server_exit']==1
assert cases['native-vive-product09']['server_exit']==cases['native-vive-product09']['runtime_exit']==0
manifest=ev.parent/'godot-m4-vive-preparation-20261030/inputs/client-physical-preparation01-manifest.json'
assert sha(manifest)=='e34159ae24d5ec0ddf6f2324a93c3352203337d886f25b8aa0ff3e7074e01e53'
closure=load(ev/'inputs/server-closure-verification02.json');assert closure['passed']
assert len(closure['closure'])==34 and len(closure['modules'])==944 and len(closure['private_resources'])==250
assert sha(root/'client/godot/Main.cs')=='e9c010f71a9c1369fd5b451fe1d7fa275948089b3a96e69fe6d8f21b543fec1e'
patch=subprocess.check_output(['git','diff','--binary','HEAD'])
assert hashlib.sha256(patch).hexdigest()=='fc2482aecbfb1803f7328e4b216a449252e6d5f6bfa2a9aa5f21da5b7f2738ef'
assert subprocess.check_output(['git','diff','--cached','--name-only'])==b''
q={'checkpoint':'QUO-65 corrected-payload retest preparation failures',
 'worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','actual_api_model':'openai-codex:gpt-6.1-sol',
 'launcher_effort_requested_and_returned':'max','effective_backend_effort':'unexposed',
 'branch':'worktree/pearl-stone','head':'293cf6115c0a6b18315eccdbb42cbca396f443d3',
 'parent':'f716ddf5e578df957a5b18421a0727a32c634f87','index_empty':True,
 'product_source_changes':0,'new_product_builds':0,'new_server_suite_runs':0,
 'client_supplied_inputs':93,'accepted_exports':196,'diagnostic_nondistributable':True,
 'payload_manifest':str(manifest.relative_to(root)),'payload_manifest_sha256':sha(manifest),
 'payload_dll_sha256':'ca0fd3be6c207a17f15a6c83254d3cb5cfe1944f3c023614542d5aa4634181dc',
 'payload_pck_sha256':'591d84a27dc2752d86f9a148d9950c9c21f91f7c153802b20e1cfe6f47213578',
 'engine_sha256':'02310d903099bada10c86cedc90bbc11ef0bec8254d6e607d1a53f6150ab0268',
 'monado_source':'59be345db769a89c93d1bdf6ed8316fa6209d8ae','monado_modified':False,
 'checks':checks,'cases':cases,
 'dependency_preflight':{'applications':34,'declared_modules':944,'private_resources':250,
  'test_helpers':2,'complete_declared_closure_verified':True,'application_started_by_probe':False},
 'human_power_response':{'responded_at':1793353016763,'answer':'both_on','scope':'power only'},
 'new_current_head_wand_readiness':False,'new_physical_observation':False,'new_godot_xr_session':False,
 'remaining':['Current compositor offers no HDMI lease connector even under approved temporary exception; provider readiness must change before a separately warranted next native case.',
 'Corrected-payload actual model contrast, readable/comfortable panel, canonical current poses and transforms,90-draw qualification, signed mapped gestures and real focus/disconnect/reentry/resources/platform exit remain unrun.',
 'Original desktop stalls and old cold valid-head failures remain failed/unattributed; no full M4/QUO-27/QUO-59/Stage2/Quest acceptance.'],
 'no_commit_push_m5_tracker_mutation_or_cleanup':True}
write(ev/'qualification.json',q)
print(json.dumps({'explicit_completion':True,'checks':len(checks),'failed_physical_preparations':len(cases),'product_source_changes':0}))
