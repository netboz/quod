-module(quod36_work_probe).
-export([unchanged/1,updated/2]).

unchanged(Ns) ->
    measured(Ns,fun() ->
        [ok=quod_runtime:reconcile_resource(Ns,quod_prolog:applied(Ns),physics_worlds,all,quod_time:mono_ms()+10000)
         || _ <- lists:seq(1,20)],
        #{checks=>20}
    end).

updated(Ns,Structure) ->
    true=quod_reg:subscribe({physics,Ns}),
    measured(Ns,fun() ->
        io:format("TRACE_READY~n"),
        await_structure(Ns,Structure,quod_time:mono_ms()+30000),
        #{real_structure=>Structure}
    end).

measured(Ns,Fun) ->
    Collector=spawn_link(fun()->collect(#{}) end),
    Trace=trace:session_create(quod36_work_probe,Collector,[]),
    Owners=[quod_reg:where({quod_runtime,Ns}),quod_reg:where({quod_prolog,Ns})] ++
       [P || #{pid:=P,stopping:=false} <- maps:values(worlds(Ns))],
    Watched=[{quod_physics_native,new_world,3},{quod_physics_native,install,2},
      {quod_physics_native,install_hinges,2},{quod_physics_native,control_hinge,4},
      {quod_physics,geometry,1},{quod_committed_projection,apply_entry,3},
      {quod_ledger_store,fold,5},{quod_ledger_store,open,3},
      {file,write,2},{file,pwrite,3},{file,sync,1},{file,datasync,1}],
    Before=state(Ns),
    try
        [begin {module,M}=code:ensure_loaded(M),N=trace:function(Trace,MFA,[{'_',[],[]}],[local]),true=N>0 end || MFA={M,_,_} <- Watched],
        [trace:process(Trace,P,true,[call,arity,set_on_spawn]) || P <- Owners],
        Result=Fun(),
        trace:process(Trace,all,false,[call,set_on_spawn]),
        Delivery=trace:delivered(Trace,all),
        receive {trace_delivered,all,Delivery}->ok after 5000->error(trace_delivery_deadline) end,
        Ref=make_ref(),Collector!{finish,self(),Ref},
        Counts=receive {counts,Ref,C}->C after 5000->error(trace_result_deadline) end,
        #{result=>Result,before=>Before,after_checks=>state(Ns),work=>Counts,redacted=>arity_only}
    after trace:session_destroy(Trace),unlink(Collector),exit(Collector,kill) end.

state(Ns) ->
    #{height=>quod_prolog:applied(Ns),runtime=>quod_runtime:stats(Ns),
      worlds=>[#{pid=>fmt(P),structure=>maps:get(structure,S),
                 status=>fmt(gen_server:call(P,status))}
          || #{pid:=P,spec:=S,stopping:=false} <- maps:values(worlds(Ns))]}.
worlds(Ns) -> {R,_}=quod_runtime:agents(Ns),gen_server:call(R,physics_worlds).
await_structure(Ns,Structure,D) ->
    Ready=[P || #{pid:=P,spec:=#{structure:=S},stopping:=false} <- maps:values(worlds(Ns)),
                S=:=Structure,maps:get(navigation_ready,gen_server:call(P,status),false)],
    case Ready of [_]->ok; _->receive {physics_status,_,_,_,_,_}->await_structure(Ns,Structure,D)
      after max(0,D-quod_time:mono_ms())->error({structure_deadline,Structure}) end end.
collect(Counts) -> receive
    {trace,_,call,MFA}->K=fmt(MFA),collect(maps:update_with(K,fun(N)->N+1 end,1,Counts));
    {finish,P,R}->P!{counts,R,Counts}
end.
fmt(T) -> iolist_to_binary(io_lib:format("~0p",[T])).
