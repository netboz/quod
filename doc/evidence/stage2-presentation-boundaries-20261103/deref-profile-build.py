from pathlib import Path
import subprocess,json,hashlib,os
r=Path('/home/yan/src/quod_worktrees/pearl-stone');e=Path(__file__).resolve().parent
p=r/'_build/stage2-presentation-boundaries/deref-profile-build01';p.mkdir(exist_ok=False)
(p/'erlog_int.erl').write_bytes((e/'proposals/erlog_int.deref-profile.erl').read_bytes())
stage='/data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source'
expr='{ok,{erlog_int,[{compile_info,Info}]}}=beam_lib:chunks(code:which(erlog_int),[compile_info]),Options=[O||O<-proplists:get_value(options,Info),is_tuple(O),element(1,O)=:=d],{ok,erlog_int}=compile:file("/checks/erlog_int.erl",[debug_info,{i,"/work/_build/test/checkouts/erlog/src"},{outdir,"/checks"},report_errors,report_warnings|Options]),halt(0).'
args=['docker','run','--rm','--init','--user',str(os.getuid())+':'+str(os.getgid()),'-v',stage+':/work:ro','-v',str(r)+':/code:ro','-v',str(p)+':/checks','-w','/code','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2','--entrypoint','/bin/sh','sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c','exec erl -noshell -pa /work/_build/test/checkouts/*/ebin /work/_build/test/lib/*/ebin -eval "$1"','sh',expr]
x=subprocess.run(args,capture_output=True)
(e/'logs/deref-profile-build01-stdout.log').write_bytes(x.stdout);(e/'logs/deref-profile-build01-stderr.log').write_bytes(x.stderr)
h=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
(e/'inputs/deref-profile-build01.json').write_text(json.dumps(dict(command=args,true_exit=x.returncode,stdout_eof=True,stderr_eof=True,test_sha256=h(e/'proposals/erlog_dispatch_tests.erl'),erlog_source_sha256=h(Path(stage)/'_build/test/checkouts/erlog/src/erlog_int.erl'),erlog_beam_sha256=h(Path(stage)/'_build/test/checkouts/erlog/ebin/erlog_int.beam'),candidate_applied=False,candidate_executed_in_isolated_test=True,candidate_source_sha256=h(p/'erlog_int.erl')),indent=2)+'\n')
print((x.stdout+x.stderr).decode(errors='replace'));print('TRUE_EXIT',x.returncode)

raise SystemExit(x.returncode)
