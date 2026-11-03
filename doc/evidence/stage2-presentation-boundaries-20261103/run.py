"""One affected check, full child streams and exit; no retries."""
from pathlib import Path
import json,os,subprocess,sys,time,hashlib
r=Path('/home/yan/src/quod_worktrees/pearl-stone');e=Path(__file__).resolve().parent
label,owner,mode=sys.argv[1:4];receipt=json.loads((e/'inputs'/(owner+'.json')).read_text());assert receipt['compile_passed']
stage='/data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source';p=Path(receipt['ebin']).parent
for name,row in receipt['source_inputs'].items(): assert hashlib.sha256((r/name).read_bytes()).hexdigest()==row['sha256'],name
overlays=[];prolog_inputs={}
if mode in ['terrain','inspection','projection']:
 for f in (r/'priv/ontologies').glob('*.pl'):
  prolog_inputs[str(f.relative_to(r))]=hashlib.sha256(f.read_bytes()).hexdigest();overlays+=['-v',str(f)+':/work/priv/ontologies/'+f.name+':ro']
modules={'projection':'[quod_physics_tests:m3a_shared_projection_test_()]','inspection':'[fun quod_lens_tests:exact_predicate_inspection_preserves_full_sorted_catalogue_test/0]','terrain':'[quod_physics_tests:terrain_delivery_credit_and_replacement_test_(),quod_physics_tests:voxel_signed_view_delivers_only_bound_resident_chunks_test_(),quod_physics_tests:voxel_signed_view_delivers_complete_large_resident_selection_test_()]','codecs':'[quod_wire_term_tests,quod_client_result_tests,quod_client_goal_endpoint_tests,quod_client_goal_router_tests,quod_terrain_wire_tests]', 'proof':'[quod_scope_wire_tests,quod_proof_session_tests,quod_proof_answer_tests,quod_scope_session_tests,quod_dtx_tests,quod_ask_tests,quod_material_admission_tests]'}
if mode=='browser':args=['node','--test','client/test/terrain-delivery.test.js','client/test/simulation.test.js','client/test/signed-client.test.js']
else:
 expr='true=code:add_patha("/checks/ebin"),case eunit:test('+modules[mode]+',[verbose]) of ok->halt(0);_->halt(1) end.'
 args=['docker','run','--rm','--init','--user',str(os.getuid())+':'+str(os.getgid()),'-v',stage+':/work:ro','-v',str(r)+':/code:ro','-v',str(p)+':/checks','-w','/code','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2',*overlays,'--entrypoint','/bin/sh','sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c','exec erl -noshell -pa /work/_build/test/checkouts/*/ebin /work/_build/test/lib/*/ebin /work/_build/test/lib/quod/test -eval "$1"','sh',expr]
assert not (e/'inputs'/(label+'.json')).exists()
start=time.monotonic();child=subprocess.run(args,cwd=r,capture_output=True)
(e/'logs'/(label+'-stdout.log')).write_bytes(child.stdout);(e/'logs'/(label+'-stderr.log')).write_bytes(child.stderr)
(e/'inputs'/(label+'.json')).write_text(json.dumps({'command':args,'source_owner':owner,'prolog_inputs':prolog_inputs,'true_exit':child.returncode,'stdout_eof':True,'stderr_eof':True,'elapsed_seconds':time.monotonic()-start},indent=2)+'\n')
print(json.dumps({'label':label,'exit':child.returncode}));print((child.stdout+child.stderr).decode(errors='replace')[-6500:]);sys.exit(child.returncode)
