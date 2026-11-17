from pathlib import Path
import os,sys,shutil,json,hashlib,subprocess,time
R=Path.cwd();E=Path(__file__).resolve().parent;label=sys.argv[1];parent=sys.argv[2];candidate=parent=='runtime-candidate01'
Base=R/'_build/stage2-renewal-diagnosis'/parent;P=R/'_build/stage2-renewal-diagnosis'/label
shutil.copytree(Base,P,symlinks=True)
base=json.loads((E/'inputs'/f'{parent}.json').read_text());inputs=dict(base['source_inputs'])
for n in ['rebar.config','rebar.config.script']:
 name='_build/default/lib/erlog/'+n;shutil.copy2(R/name,P/'source'/name);inputs[name]=hashlib.sha256((P/'source'/name).read_bytes()).hexdigest()
expr='true=code:add_patha("/build/source/_build/default/lib/erlog/ebin"),true=code:add_patha("/build/lib/quod/ebin"),'
expr+='Dir="/build/source/_build/default/lib/erlog/",{ok,Config}=file:consult(Dir++"rebar.config"),{ok,Configured}=file:script(Dir++"rebar.config.script",[{\'CONFIG\',Config}]),Opts=proplists:get_value(erl_opts,Configured),io:format("CONFIGURED_ERLOG_OPTIONS ~p~n",[Opts]),'
expr+='Files=filelib:wildcard(Dir++"src/*.erl"),[begin {ok,_}=compile:file(F,[export_all,{d,\'TEST\'},{outdir,Dir++"ebin"},{i,Dir++"src"},report_errors|Opts]) end || F<-Files,filename:basename(F)=/="Elixir.Erlog.erl"],true=is_map(erlog_int:new_bindings()),io:format("BINDING_BACKEND maps~n",[]),'
mods='[erlog_failure_reasons_tests,erlog_findall_cut_tests,erlog_choicepoint_checkpoint_tests,erlog_choicepoint_owned_tests,erlog_observation_tests,erlog_opaque_functor_tests,erlog_io_tests,quod_wire_term_tests,quod_predicate_failure_tests]'
if candidate:
 expr+='true=code:add_patha("/build"),'
 mods='[reason_admission_tests|'+mods+']'
expr+='case eunit:test('+mods+',[verbose]) of ok->halt(0);_->halt(1) end.'
stage='/data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source'
cmd=['docker','run','--rm','--init','--user',f'{os.getuid()}:{os.getgid()}','-v',stage+':/work:ro','-v',str(P)+':/build','-w','/build/source','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2','--entrypoint','/bin/sh','sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c','exec erl -noshell -pa /work/_build/test/checkouts/*/ebin /work/_build/test/lib/*/ebin -eval "$1"','sh',expr]
t=time.monotonic();x=subprocess.run(cmd,capture_output=True)
for stream in ['stdout','stderr']:(E/'logs'/(label+'-'+stream+'.log')).write_bytes(getattr(x,stream))
record={'command':cmd,'true_exit':x.returncode,'stdout_eof':True,'stderr_eof':True,'elapsed':time.monotonic()-t,'source_inputs':inputs,'base_inputs':base.get('base_inputs',{}),'candidate_only':candidate,'candidate_installed':False,'configuration_script_executed':True,'backend_asserted':'maps','parent':parent}
(E/'inputs'/(label+'.json')).write_text(json.dumps(record,indent=2)+'\n')
print(x.stdout.decode(errors='replace')[:900]);print((x.stdout+x.stderr).decode(errors='replace')[-1400:]);print('TRUE_EXIT',x.returncode);raise SystemExit(x.returncode)
