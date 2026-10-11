Result=eunit:test(quod_create_root_tests,[verbose]),
Pids=[{K,P} || {{n,l,{quod_ns,_}=K},P,_} <- ets:tab2list(gproc),is_process_alive(P)],
io:format("REMAINING_NAMESPACES ~p~n",[Pids]),
[gen_server:stop(P,shutdown,5000) || {_,P} <- Pids],
case {Result,Pids} of {ok,[_|_]}->halt(0);_->halt(1) end.