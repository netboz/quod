from pathlib import Path
import subprocess,json,hashlib,os,shutil,sys,time
R=Path('/home/yan/src/quod_worktrees/pearl-stone');E=Path(__file__).resolve().parent;label=sys.argv[1];production_only=os.getenv('PRODUCTION_ONLY')=='1'
P=R/'_build/stage2-remaining-admission'/label;P.mkdir(parents=True,exist_ok=False);S=P/'source';S.mkdir()
for folder in ['src','include','test','priv/ontologies','_build/default/lib/erlog/src','_build/default/lib/erlog/test']:
 shutil.copytree(R/folder,S/folder)
for folder in ['priv/native','priv/explorer']:
 shutil.copytree(R/folder,S/folder)
for f in ['rebar.config','rebar.lock']:shutil.copy2(R/f,S/f)
Q=P/'lib/quod';Q.mkdir(parents=True);(Q/'ebin').mkdir();(Q/'priv').symlink_to('../../source/priv');(Q/'test').symlink_to('../../source/test')
D=S/'_build/default/lib/erlog';(D/'ebin').mkdir()
stage=Path('/data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source')
shutil.copy2(stage/'_build/test/lib/quod/ebin/quod.app',Q/'ebin/quod.app');shutil.copy2(R/'_build/default/lib/erlog/ebin/erlog.app',D/'ebin/erlog.app')
sourcehashes={str(f.relative_to(S)):hashlib.sha256(f.read_bytes()).hexdigest() for f in S.rglob('*') if f.is_file()}
# Compile the whole coordinated record family and its fixtures, without old Quod/Erlog beams.
erlog=[str(f.relative_to(S)) for f in (D/'src').glob('*.erl') if f.name!='Elixir.Erlog.erl']
quod=[str(f.relative_to(S)) for f in (S/'src').rglob('*.erl')]
tests=[str(f.relative_to(S)) for f in (S/'test').glob('*.erl')]+[str(f.relative_to(S)) for f in (D/'test').glob('*.erl') if f.name!='records_test.erl']
if production_only: tests=[]
expr='true=code:add_patha("/checks/source/_build/default/lib/erlog/ebin"),true=code:add_patha("/checks/lib/quod/ebin"),'
expr+='{ok,F}=epp:parse_file("/checks/source/src/quod_erlog_db_local_prove.erl",["/checks/source/include","/checks/source/_build/default/lib"],[]),{ok,G}=epp:parse_file("/checks/source/_build/default/lib/erlog/src/erlog_int.erl",[],[]),[Rec]=[X||{attribute,_,record,{est,_}=X}<-F],[Rec]=[X||{attribute,_,record,{est,_}=X}<-G],io:format("SHARED_EST_RECORD ~p~n",[Rec]),'
opts='[debug_info,export_all,{d,\'TEST\'},{i,"/checks/source/include"},{i,"/checks/source/test"},{i,"/checks/source/_build/default/lib"},{i,"/checks/source/_build/default/lib/erlog/src"},{i,"/checks/source/_build/default/lib/erlog/test"},report_errors,report_warnings]'
if production_only: opts=opts.replace("export_all,{d,'TEST'},",'')
expr+='Sets='+json.dumps([['/checks/source/_build/default/lib/erlog/ebin',erlog],['/checks/lib/quod/ebin',quod+tests]])+',Results=lists:append([[{N,compile:file("/checks/source/"++N,[{outdir,Out}|'+opts+'])}||N<-Names]||[Out,Names]<-Sets]),io:format("BUILD_RESULTS ~p~n",[Results]),case lists:all(fun({_,{ok,_}})->true;(_)->false end,Results) of true->halt(0);false->halt(1) end.'
args=['docker','run','--rm','--init','--user',f'{os.getuid()}:{os.getgid()}','-v',str(stage)+':/work:ro','-v',str(P)+':/checks','-w','/checks/source','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2','--entrypoint','/bin/sh','sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c','exec erl -noshell -pa /work/_build/test/checkouts/*/ebin /work/_build/test/lib/*/ebin -eval "$1"','sh',expr]
start=time.monotonic();x=subprocess.run(args,capture_output=True)
for stream in ['stdout','stderr']:(E/f'logs/{label}-{stream}.log').write_bytes(getattr(x,stream))
(E/f'inputs/{label}.json').write_text(json.dumps(dict(command=args,true_exit=x.returncode,stdout_eof=True,stderr_eof=True,source_inputs=sourcehashes,elapsed=time.monotonic()-start,source_label='applied-consolidated02-01',modules_compiled_only=True,production_only=production_only,unavailable_legacy_optional_test='records_test requires absent eqc/include/eqc.hrl; failure retained in applied-build01'),indent=2)+'\n')
print('TRUE_EXIT',x.returncode,'ELAPSED',time.monotonic()-start);print((x.stdout+x.stderr).decode(errors='replace')[-1200:]);sys.exit(x.returncode)
