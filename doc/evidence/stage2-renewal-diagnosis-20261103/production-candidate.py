from pathlib import Path
import os,sys,json,hashlib,subprocess,time
R=Path.cwd();E=Path(__file__).resolve().parent;label=sys.argv[1]
B=R/'_build/stage2-renewal-diagnosis/configured-candidate04';P=R/'_build/stage2-renewal-diagnosis'/label;P.mkdir(exist_ok=False)
source=['_build/default/lib/erlog/src/erlog_int.erl','src/quod_committed_projection.erl','src/quod_erlog_db_local_prove.erl']
expr='Dir="/build/source/_build/default/lib/erlog/",{ok,C}=file:consult(Dir++"rebar.config"),{ok,Configured}=file:script(Dir++"rebar.config.script",[{\'CONFIG\',C}]),Opts=proplists:get_value(erl_opts,Configured),io:format("CONFIGURED_ERLOG_OPTIONS ~p~n",[Opts]),{ok,erlog_int}=compile:file(Dir++"src/erlog_int.erl",[{outdir,"/checks"},{i,Dir++"src"},report_errors|Opts]),'
for n in source[1:]:expr+='{ok,'+Path(n).stem+'}=compile:file("/build/source/'+n+'",[debug_info,{outdir,"/checks"},{i,"/build/source/include"},{i,"/build/source/_build/default/lib"},report_errors]),'
expr+='[begin {ok,{_,[{compile_info,Info}]}}=beam_lib:chunks("/checks/"++atom_to_list(M)++".beam",[compile_info]),O=proplists:get_value(options,Info),false=lists:member(export_all,O),false=lists:member({d,\'TEST\'},O) end||M<-[erlog_int,quod_committed_projection,quod_erlog_db_local_prove]],io:format("NORMAL_PRODUCTION_OPTIONS_VERIFIED~n",[]),halt(0).'
cmd=['docker','run','--rm','--init','--user',f'{os.getuid()}:{os.getgid()}','-v',str(B)+':/build:ro','-v',str(P)+':/checks','-w','/build/source','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2','--entrypoint','/bin/sh','sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c','exec erl -noshell -eval "$1"','sh',expr]
t=time.monotonic();x=subprocess.run(cmd,capture_output=True)
for stream in ['stdout','stderr']:(E/'logs'/(label+'-'+stream+'.log')).write_bytes(getattr(x,stream))
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
record={'command':cmd,'true_exit':x.returncode,'stdout_eof':True,'stderr_eof':True,'elapsed':time.monotonic()-t,'source_inputs':{n:h(B/'source'/n) for n in source},'beams':{p.name:h(p) for p in P.glob('*.beam')},'candidate_installed':False,'source_label':'configured-candidate04','configuration_script_executed':True,'normal_production_options_asserted':True}
(E/'inputs'/(label+'.json')).write_text(json.dumps(record,indent=2)+'\n');print((x.stdout+x.stderr).decode(errors='replace')[-1800:]);print('TRUE_EXIT',x.returncode);raise SystemExit(x.returncode)
