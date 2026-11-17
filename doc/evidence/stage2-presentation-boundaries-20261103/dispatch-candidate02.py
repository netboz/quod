from pathlib import Path
import subprocess,json,hashlib,os
r=Path('/home/yan/src/quod_worktrees/pearl-stone');e=Path(__file__).resolve().parent
p=r/'_build/stage2-presentation-boundaries/dispatch-candidate02';p.mkdir(exist_ok=False)
(p/'erlog_int.erl').write_bytes((e/'proposals/erlog_int.proposed.erl').read_bytes())
stage='/data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source'
expr='{ok,{erlog_int,[{compile_info,Info}]}}=beam_lib:chunks(code:which(erlog_int),[compile_info]),Options=[O||O<-proplists:get_value(options,Info),is_tuple(O),element(1,O)=:=d],{ok,erlog_int}=compile:file("/checks/erlog_int.erl",[debug_info,{i,"/work/_build/test/checkouts/erlog/src"},{outdir,"/checks"},report_errors,report_warnings|Options]),true=code:add_patha("/checks"),{ok,erlog_dispatch_tests}=compile:file("/code/doc/evidence/stage2-presentation-boundaries-20261103/proposals/erlog_dispatch_tests.erl",[{outdir,"/checks"},report_errors,report_warnings]),Ms=[erlog_failure_reasons_tests,erlog_findall_cut_tests,erlog_choicepoint_checkpoint_tests,erlog_choicepoint_owned_tests,erlog_observation_tests,erlog_opaque_functor_tests],lists:foreach(fun(M)->{ok,M}=compile:file("/code/_build/default/lib/erlog/test/"++atom_to_list(M)++".erl",[{outdir,"/checks"},{i,"/work/_build/test/checkouts/erlog/src"},report_errors,report_warnings]) end,Ms),case eunit:test([erlog_dispatch_tests|Ms],[verbose]) of ok->halt(0);_->halt(1) end.'
args=['docker','run','--rm','--init','--user',str(os.getuid())+':'+str(os.getgid()),'-v',stage+':/work:ro','-v',str(r)+':/code:ro','-v',str(p)+':/checks','-w','/code','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2','--entrypoint','/bin/sh','sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c','exec erl -noshell -pa /work/_build/test/checkouts/*/ebin /work/_build/test/lib/*/ebin -eval "$1"','sh',expr]
x=subprocess.run(args,capture_output=True)
(e/'logs/dispatch-candidate02-stdout.log').write_bytes(x.stdout);(e/'logs/dispatch-candidate02-stderr.log').write_bytes(x.stderr)
h=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
(e/'inputs/dispatch-candidate02.json').write_text(json.dumps(dict(command=args,true_exit=x.returncode,stdout_eof=True,stderr_eof=True,test_sha256=h(e/'proposals/erlog_dispatch_tests.erl'),erlog_source_sha256=h(Path(stage)/'_build/test/checkouts/erlog/src/erlog_int.erl'),erlog_beam_sha256=h(Path(stage)/'_build/test/checkouts/erlog/ebin/erlog_int.beam'),candidate_applied=False,candidate_executed_in_isolated_test=True,candidate_source_sha256=h(p/'erlog_int.erl')),indent=2)+'\n')
print((x.stdout+x.stderr).decode(errors='replace'));print('TRUE_EXIT',x.returncode)

raise SystemExit(x.returncode)
