from pathlib import Path
import subprocess,json,hashlib,os
r=Path('/home/yan/src/quod_worktrees/pearl-stone');e=Path(__file__).resolve().parent
p=r/'_build/stage2-presentation-boundaries/dispatch-baseline01';p.mkdir(exist_ok=False)
stage='/data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source'
expr='true=code:add_patha("/checks"),{ok,erlog_dispatch_tests}=compile:file("/code/doc/evidence/stage2-presentation-boundaries-20261103/proposals/erlog_dispatch_tests.erl",[{outdir,"/checks"},report_errors,report_warnings]),case eunit:test(erlog_dispatch_tests,[verbose]) of ok->halt(0);_->halt(1) end.'
args=['docker','run','--rm','--init','--user',str(os.getuid())+':'+str(os.getgid()),'-v',stage+':/work:ro','-v',str(r)+':/code:ro','-v',str(p)+':/checks','-w','/code','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2','--entrypoint','/bin/sh','sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c','exec erl -noshell -pa /work/_build/test/checkouts/*/ebin /work/_build/test/lib/*/ebin -eval "$1"','sh',expr]
x=subprocess.run(args,capture_output=True)
(e/'logs/dispatch-baseline01-stdout.log').write_bytes(x.stdout);(e/'logs/dispatch-baseline01-stderr.log').write_bytes(x.stderr)
h=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
(e/'inputs/dispatch-baseline01.json').write_text(json.dumps(dict(command=args,true_exit=x.returncode,stdout_eof=True,stderr_eof=True,test_sha256=h(e/'proposals/erlog_dispatch_tests.erl'),erlog_source_sha256=h(Path(stage)/'_build/test/checkouts/erlog/src/erlog_int.erl'),erlog_beam_sha256=h(Path(stage)/'_build/test/checkouts/erlog/ebin/erlog_int.beam'),candidate_applied=False),indent=2)+'\n')
print((x.stdout+x.stderr).decode(errors='replace'));print('TRUE_EXIT',x.returncode)
