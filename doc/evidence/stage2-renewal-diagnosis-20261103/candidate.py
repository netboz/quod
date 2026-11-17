from pathlib import Path
import os,sys,shutil,json,hashlib,subprocess,time
R=Path.cwd();E=Path(__file__).resolve().parent;label=sys.argv[1];candidate=sys.argv[2]=='candidate'
Base=R/'_build/stage2-renewal-diagnosis/runtime02';P=R/'_build/stage2-renewal-diagnosis'/label
if candidate:shutil.copytree(Base,P,symlinks=True)
else:P.mkdir(exist_ok=False)
B=P if candidate else Base
shutil.copy2(E/'reason_admission_tests.erl',P/'reason_admission_tests.erl')
base=json.loads((E/'inputs/runtime02.json').read_text());inputs=dict(base['source_inputs']);changed={};compile_expr=''
if candidate:
 for name in ['_build/default/lib/erlog/src/erlog_int.erl','src/quod_committed_projection.erl']:
  shutil.copy2(E/'proposal'/name,P/'source'/name);changed[name]=inputs[name]
  inputs[name]=hashlib.sha256((P/'source'/name).read_bytes()).hexdigest()
  out='/build/source/_build/default/lib/erlog/ebin' if name.startswith('_build') else '/build/lib/quod/ebin'
  compile_expr+='{ok,'+Path(name).stem+'}=compile:file("/build/source/'+name+'",[debug_info,export_all,{d,\'TEST\'},{outdir,"'+out+'"},{i,"/build/source/include"},{i,"/build/source/_build/default/lib"},{i,"/build/source/_build/default/lib/erlog/src"},report_errors]),'
expr='true=code:add_patha("/build/source/_build/default/lib/erlog/ebin"),true=code:add_patha("/build/lib/quod/ebin"),'+compile_expr
expr+='{ok,reason_admission_tests}=compile:file("/checks/reason_admission_tests.erl",[debug_info,{outdir,"/checks"},{i,"/build/source/_build/default/lib/erlog/src"},report_errors]),true=code:add_patha("/checks"),'
mods='[reason_admission_tests]'
if candidate:mods='[reason_admission_tests,erlog_failure_reasons_tests,erlog_findall_cut_tests,erlog_choicepoint_checkpoint_tests,erlog_choicepoint_owned_tests,erlog_observation_tests,erlog_opaque_functor_tests,erlog_io_tests,quod_wire_term_tests,quod_predicate_failure_tests]'
expr+='case eunit:test('+mods+',[verbose]) of ok->halt(0);_->halt(1) end.'
stage='/data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source'
cmd=['docker','run','--rm','--init','--user',f'{os.getuid()}:{os.getgid()}','-v',stage+':/work:ro','-v',str(B)+':/build'+('' if candidate else ':ro'),'-v',str(P)+':/checks','-w','/build/source','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2','--entrypoint','/bin/sh','sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c','exec erl -noshell -pa /work/_build/test/checkouts/*/ebin /work/_build/test/lib/*/ebin -eval "$1"','sh',expr]
t=time.monotonic();x=subprocess.run(cmd,capture_output=True)
for stream in ['stdout','stderr']:(E/'logs'/(label+'-'+stream+'.log')).write_bytes(getattr(x,stream))
record={'command':cmd,'true_exit':x.returncode,'stdout_eof':True,'stderr_eof':True,'elapsed':time.monotonic()-t,'source_inputs':inputs,'base_inputs':changed,'candidate_only':candidate,'candidate_installed':False,'fixture_sha256':hashlib.sha256((P/'reason_admission_tests.erl').read_bytes()).hexdigest()}
(E/'inputs'/(label+'.json')).write_text(json.dumps(record,indent=2)+'\n')
print((x.stdout+x.stderr).decode(errors='replace')[-4500:]);print('TRUE_EXIT',x.returncode);raise SystemExit(x.returncode)
