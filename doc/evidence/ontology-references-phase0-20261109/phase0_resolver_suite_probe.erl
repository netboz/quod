%% Removable observation only. The production and test modules are unchanged.
-module(phase0_resolver_suite_probe).
-export([run/0]).

run() ->
    MFAs = [{quod_evidence_resolver_tests,calls,4},
            {quod_ledger_store,open_ro_snapshot,1},
            {quod_foreign_log,spawn_verification_worker,3},
            {quod_foreign_log,replay_cache,7}],
    [{module,M} = code:ensure_loaded(M) || {M,_,_} <- MFAs],
    Parent = self(),
    Tracer = spawn(fun() -> observe(Parent) end),
    Session = trace:session_create(phase0_resolver_suite_probe,Tracer,[]),
    [trace:function(Session,MFA,[{'_',[],[{message,{caller}}]}],[local]) || MFA <- MFAs],
    trace:process(Session,all,true,[call,set_on_spawn]),
    Result = try
        eunit:test({application,quod},[verbose])
    after
        Barrier = trace:delivered(Session,all),
        receive {trace_delivered,all,Barrier} -> ok
        after 2000 -> error(probe_trace_delivery_timeout) end,
        Tracer ! {barrier,Barrier},
        receive {probe_observed,Barrier} -> ok
        after 2000 -> error(probe_trace_barrier_timeout) end,
        trace:session_destroy(Session),
        Tracer ! stop
    end,
    io:format("RESOLVER_PROBE_RESULT ~p~n",[Result]),
    case Result of ok -> halt(0); _ -> halt(1) end.

observe(Parent) ->
    receive
        {trace,Pid,call,{quod_evidence_resolver_tests,calls,
                        [Rows,quod_ledger_store,open_ro_snapshot,1]},_} ->
            Pids = [P || {trace,P,call,{quod_ledger_store,open_ro_snapshot,[_]}} <- Rows],
            io:format("ASSERTED_SNAPSHOT_CALLS test=~p pids=~p~n",[Pid,Pids]),
            observe(Parent);
        {trace,_,call,{quod_evidence_resolver_tests,calls,_},_} -> observe(Parent);
        {trace,Pid,call,{M,F,Args},Caller} ->
            io:format("OBSERVED_CALL pid=~p mfa=~p caller=~p~n",[Pid,{M,F,length(Args)},Caller]),
            observe(Parent);
        {barrier,Barrier} -> Parent ! {probe_observed,Barrier}, observe(Parent);
        stop -> ok;
        _ -> observe(Parent)
    end.
