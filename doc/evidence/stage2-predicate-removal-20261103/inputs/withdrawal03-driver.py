from pathlib import Path
import sys, shutil, subprocess, hashlib, json, os, time
R=Path.cwd(); E=Path(__file__).resolve().parent; label=sys.argv[1]
P=R/'_build/stage2-predicate-removal'/label
shutil.copytree(R/'_build/stage2-renewal-diagnosis/configured-candidate04',P,symlinks=True)
S=P/'source'; Q=P/'lib/quod/ebin'; D=S/'_build/default/lib/erlog'
for directory in ['src','include','test','priv/ontologies']:
 shutil.copytree(R/directory,S/directory,dirs_exist_ok=True)
for f in (R/'_build/default/lib/erlog/src').glob('*'):
 if f.is_file(): shutil.copy2(f,D/'src'/f.name)
for name in ['rebar.config','rebar.config.script']:shutil.copy2(R/'_build/default/lib/erlog'/name,D/name)
inputs={str(f.relative_to(S)):hashlib.sha256(f.read_bytes()).hexdigest() for f in S.rglob('*') if f.is_file() and f.suffix in ['.erl','.hrl','.pl']}
base=R/'_build/default'
paths=[str(f) for folder in ['checkouts','lib'] for f in (base/folder).glob('*/ebin') if f.parent.name not in ['quod','erlog']]
T=P/'tests';T.mkdir(exist_ok=True)
paths += [str(D/'ebin'),str(Q),str(T)]
expr='{ok,Config}=file:consult("'+str(D/'rebar.config')+'"),{ok,Configured}=file:script("'+str(D/'rebar.config.script')+'",[{\'CONFIG\',Config}]),ErlogOpts=proplists:get_value(erl_opts,Configured),io:format("ERLOG_OPTIONS ~p~n",[ErlogOpts]),[begin {ok,_}=compile:file(F,[debug_info,{outdir,"'+str(D/'ebin')+'"},{i,"'+str(D/'src')+'"},report_errors|ErlogOpts]) end || F<-filelib:wildcard("'+str(D/'src')+'/*.erl"),filename:basename(F)=/="Elixir.Erlog.erl"],true=is_map(erlog_int:new_bindings()),'
opts='[debug_info,export_all,{d,\'TEST\'},{i,"'+str(S/'include')+'"},{i,"'+str(S/'test')+'"},{outdir,"'+str(Q)+'"},report_errors,report_warnings]'
mods=sys.argv[2:] or ['quod_predicate_removal_tests']
helpers=['quod_ct','quod_space_tests','quod_agent_hosting_tests','quod_lobby_tests','quod_gui_question_tests','quod_source_view_tests']
files=list((S/'src').rglob('*.erl'))+[S/'test'/(m+'.erl') for m in sorted(set(mods+helpers))]
opts=opts.replace('{outdir,"'+str(Q)+'"}', '{outdir,case lists:prefix("'+str(S/'test')+'",F) of true->"'+str(T)+'";false->"'+str(Q)+'" end}')
expr+='Results=[{F,compile:file(F,'+opts+')}||F<-'+json.dumps([str(f) for f in files])+'],io:format("COMPILE_RESULTS ~p~n",[Results]),true=lists:all(fun({_,{ok,_}})->true;(_)->false end,Results),'
expr+='case eunit:test(['+','.join(mods)+'],[verbose]) of ok->halt(0);_->halt(1) end.'
cmd=['erl','+S','4:4','+SDio','2','+SDcpu','2','-noshell','-pa',*paths,'-eval',expr]
(E/'inputs'/f'{label}-driver.py').write_bytes(Path(__file__).read_bytes())
t=time.monotonic(); x=subprocess.run(cmd,cwd=S,capture_output=True)
for stream in ['stdout','stderr']:(E/'logs'/f'{label}-{stream}.log').write_bytes(getattr(x,stream))
record=dict(command=cmd,true_exit=x.returncode,stdout_eof=True,stderr_eof=True,elapsed=time.monotonic()-t,source_inputs=inputs,compiled_sources=[str(f.relative_to(S)) for f in files],runtime_beams={str(f):hashlib.sha256(f.read_bytes()).hexdigest() for path in paths for f in Path(path).glob('*.beam')},erlog_head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=R/'_build/default/lib/erlog',text=True).strip())
(E/'inputs'/f'{label}.json').write_text(json.dumps(record,indent=2)+'\n')
print((x.stdout+x.stderr).decode(errors='replace')[-5500:]);print('TRUE_EXIT',x.returncode);sys.exit(x.returncode)
