from pathlib import Path
import os,sys,shutil,json,hashlib,subprocess,time
R=Path.cwd();E=Path(__file__).resolve().parent;label=sys.argv[1];candidate=sys.argv[2]=='candidate'
Base=R/'_build/stage2-renewal-diagnosis/configured-candidate01';P=R/'_build/stage2-renewal-diagnosis'/label
if candidate:shutil.copytree(Base,P,symlinks=True)
else:P.mkdir(exist_ok=False)
B=P if candidate else Base
shutil.copy2(E/'completion_admission_tests.erl',P/'completion_admission_tests.erl')
base=json.loads((E/'inputs/configured-candidate01.json').read_text());inputs=dict(base['source_inputs']);changed=dict(base['base_inputs']);compile_expr=''
if candidate:
 name='src/predicates/quod_ask.erl';shutil.copy2(E/'proposal02'/name,P/'source'/name);changed[name]=inputs[name];inputs[name]=hashlib.sha256((P/'source'/name).read_bytes()).hexdigest()
 compile_expr='{ok,quod_ask}=compile:file("/build/source/src/predicates/quod_ask.erl",[debug_info,export_all,{d,\'TEST\'},{outdir,"/build/lib/quod/ebin"},{i,"/build/source/include"},{i,"/build/source/_build/default/lib"},report_errors]),'
expr='true=code:add_patha("/build/source/_build/default/lib/erlog/ebin"),true=code:add_patha("/build/lib/quod/ebin"),true=is_map(erlog_int:new_bindings()),'+compile_expr
expr+='{ok,completion_admission_tests}=compile:file("/checks/completion_admission_tests.erl",[debug_info,{outdir,"/checks"},report_errors]),true=code:add_patha("/checks"),'
mods='[completion_admission_tests]'
if candidate:mods='[completion_admission_tests,reason_admission_tests,erlog_failure_reasons_tests,erlog_findall_cut_tests,erlog_choicepoint_checkpoint_tests,erlog_choicepoint_owned_tests,erlog_observation_tests,erlog_opaque_functor_tests,erlog_io_tests,quod_wire_term_tests,quod_predicate_failure_tests,quod_ask_tests,quod_proof_session_tests,quod_scope_session_tests]'
expr+='case eunit:test('+mods+',[verbose]) of ok->halt(0);_->halt(1) end.'
stage='/data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source'
cmd=['docker','run','--rm','--init','--user',f'{os.getuid()}:{os.getgid()}','-v',stage+':/work:ro','-v',str(B)+':/build'+('' if candidate else ':ro'),'-v',str(P)+':/checks','-w','/build/source','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2','--entrypoint','/bin/sh','sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c','exec erl -setcookie renewal_diagnosis_cookie -noshell -pa /work/_build/test/checkouts/*/ebin /work/_build/test/lib/*/ebin -eval "$1"','sh',expr]
t=time.monotonic();x=subprocess.run(cmd,capture_output=True)
for stream in ['stdout','stderr']:(E/'logs'/(label+'-'+stream+'.log')).write_bytes(getattr(x,stream))
record={'command':cmd,'true_exit':x.returncode,'stdout_eof':True,'stderr_eof':True,'elapsed':time.monotonic()-t,'source_inputs':inputs,'base_inputs':changed,'candidate_only':True,'candidate_installed':False,'configuration_script_executed':True,'backend_asserted':'maps','parent':'configured-candidate01','fixture_sha256':hashlib.sha256((P/'completion_admission_tests.erl').read_bytes()).hexdigest()}
(E/'inputs'/(label+'.json')).write_text(json.dumps(record,indent=2)+'\n')
print((x.stdout+x.stderr).decode(errors='replace')[-3000:]);print('TRUE_EXIT',x.returncode);raise SystemExit(x.returncode)
