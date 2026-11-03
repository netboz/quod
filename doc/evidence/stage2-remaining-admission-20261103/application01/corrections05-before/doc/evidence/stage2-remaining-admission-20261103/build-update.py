from pathlib import Path
import subprocess,json,hashlib,os,shutil,sys,time
R=Path('/home/yan/src/quod_worktrees/pearl-stone');E=Path(__file__).resolve().parent;label,base=sys.argv[1:3];names=sys.argv[3:]
B=R/'_build/stage2-remaining-admission'/base;P=R/'_build/stage2-remaining-admission'/label;shutil.copytree(B,P,symlinks=True);S=P/'source'
for n in names:shutil.copy2(R/n,S/n)
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
opts='[debug_info,export_all,{d,\'TEST\'},{i,"/checks/source/include"},{i,"/checks/source/test"},{i,"/checks/source/_build/default/lib"},{i,"/checks/source/_build/default/lib/erlog/src"},report_errors,report_warnings]'
expr='Results=[{N,compile:file("/checks/source/"++N,[{outdir,"/checks/lib/quod/ebin"}|'+opts+'])}||N<-'+json.dumps(names)+'],io:format("~p~n",[Results]),case lists:all(fun({_,{ok,_}})->true;(_)->false end,Results) of true->halt(0);false->halt(1) end.'
stage='/data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source'
args=['docker','run','--rm','--init','--user',f'{os.getuid()}:{os.getgid()}','-v',stage+':/work:ro','-v',str(P)+':/checks','-w','/checks/source','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2','--entrypoint','/bin/sh','sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c','exec erl -noshell -pa /work/_build/test/checkouts/*/ebin /work/_build/test/lib/*/ebin -eval "$1"','sh',expr]
start=time.monotonic();x=subprocess.run(args,capture_output=True)
for stream in ['stdout','stderr']:(E/f'logs/{label}-{stream}.log').write_bytes(getattr(x,stream))
(E/f'inputs/{label}.json').write_text(json.dumps(dict(command=args,true_exit=x.returncode,stdout_eof=True,stderr_eof=True,source_inputs={str(f.relative_to(S)):h(f) for f in S.rglob('*') if f.is_file()},elapsed=time.monotonic()-start,source_label=label,prior_build=base,prior_build_receipt_sha256=h(E/f'inputs/{base}.json'),unavailable_legacy_optional_test='erlog records_test requires absent eqc/include/eqc.hrl; not executed'),indent=2)+'\n')
print('TRUE_EXIT',x.returncode);print((x.stdout+x.stderr).decode(errors='replace')[-1500:]);sys.exit(x.returncode)
