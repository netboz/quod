%% Removable diagnostic: arrange an old projection read in the new measurement.
%% The original test body, assertions and absolute deadlines stay unchanged.
-module(phase0_resolver_schedule_probe).
-export([run/0]).
run() ->
    MFAs = [{quod_evidence_resolver_tests,calls,4},
            {quod_foreign_projection,init,5},
            {quod_foreign_log,resolve_reference,6},
            {quod_ledger_store,open_ro_snapshot,1}],
    [{module,M} = code:ensure_loaded(M) || {M,_,_} <- MFAs],
    Parent = self(),
    Tracer = spawn_opt(fun() -> observe(Parent,#{resolves => 0}) end,[{priority,high}]),
    Session = trace:session_create(phase0_resolver_schedule_probe,Tracer,[]),
    [trace:function(Session,MFA,[{'_',[],[{message,{caller}}]}],[local]) || MFA <- MFAs],
    trace:process(Session,all,true,[call,set_on_spawn]),
    Result = try
        eunit:test({quod_evidence_resolver_tests,
                    persisted_cache_replays_at_startup_not_on_later_requests_test},[verbose])
    after
        trace:session_destroy(Session),
        Tracer ! cleanup,
        receive {probe_cleaned,Tracer} -> ok after 2000 -> error(probe_cleanup_timeout) end
    end,
    io:format("SCHEDULE_PROBE_RESULT ~p~n",[Result]),
    case Result of ok -> halt(0); _ -> halt(1) end.
observe(Parent,S) ->
    receive
        {trace,Pid,call,{quod_foreign_projection,init,[Owner|_]},_}
          when not is_map_key(held,S) ->
            true = erlang:suspend_process(Pid),
            io:format("HELD_OLD_PROJECTION pid=~p owner=~p~n",[Pid,Owner]),
            observe(Parent,S#{held => Pid});
        {trace,Pid,call,{quod_foreign_log,resolve_reference,_},_} ->
            N = maps:get(resolves,S)+1,
            case {N,S} of
                {2,#{held := Old}} ->
                    true = erlang:suspend_process(Pid),
                    true = erlang:resume_process(Old),
                    io:format("RESUMED_OLD_PROJECTION pid=~p held_request=~p~n",[Old,Pid]),
                    observe(Parent,S#{resolves := N,request => Pid});
                _ -> observe(Parent,S#{resolves := N})
            end;
        {trace,Pid,call,{quod_ledger_store,open_ro_snapshot,[_]},Caller} ->
            io:format("SNAPSHOT_CALL pid=~p caller=~p~n",[Pid,Caller]),
            case S of
                #{held := Pid,request := Request} ->
                    true = erlang:resume_process(Request),
                    observe(Parent,maps:remove(request,S));
                _ -> observe(Parent,S)
            end;
        {trace,Pid,call,{quod_evidence_resolver_tests,calls,
                        [Rows,quod_ledger_store,open_ro_snapshot,1]},_} ->
            Pids = [P || {trace,P,call,{quod_ledger_store,open_ro_snapshot,[_]}} <- Rows],
            io:format("ASSERTED_SNAPSHOT_CALLS test=~p pids=~p~n",[Pid,Pids]),
            observe(Parent,S);
        cleanup ->
            [catch erlang:resume_process(P) || K <- [held,request],
                                              {ok,P} <- [maps:find(K,S)]],
            Parent ! {probe_cleaned,self()};
        _ -> observe(Parent,S)
    end.
