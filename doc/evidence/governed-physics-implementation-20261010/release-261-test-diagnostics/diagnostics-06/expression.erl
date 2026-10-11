Result=eunit:test([quod_create_root_tests,quod_e2e_tests,quod_physics_tests],[verbose]),
Pids=[{K,P} || {K,P,_} <- gproc:select([{{{n,l,{quod_ns,'_'}},'_','_'},[],['$_']}]),is_process_alive(P)],
io:format("REMAINING_NAMESPACES ~p~n",[Pids]),
[gen_server:stop(P,shutdown,5000) || {_,P} <- Pids],
case {Result,Pids} of {ok,[]}->halt(0);_->halt(1) end.