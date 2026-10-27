-module(m0_outcome_diagnostic).
-export([run/0,start/0,finish/0,observe/0]).

run() ->
    Dir="/tmp/quod-m0-outcome-diagnostic-10",
    ok=filelib:ensure_dir(filename:join(Dir,"placeholder")),
    Config=quod_ask_SUITE:init_per_suite([{priv_dir,Dir}]),
    Asker=proplists:get_value(asker,Config),Target=proplists:get_value(target,Config),
    try
        ok=peer:call(Asker,?MODULE,start,[]),ok=peer:call(Target,?MODULE,start,[]),
        Result=try quod_ask_SUITE:remote_signed_gateway_read_execute_cursor(Config),passed
        catch C:R:S ->
            io:format("case_failure=~p:~p stack=~p~n",[C,R,S]),
            case R of
                {timeout,{gen_server,call,[_,{call,quod_prolog,outcome,[Ref]},5000]}} ->
                    io:format("target_exact_result=~p~n",[peer:call(Target,quod_prolog,outcome,[Ref])]),
                    {transaction,Ns,_,_}=Ref,
                    io:format("target_snapshot=~p~n",[peer:call(Target,quod_prolog,outcome_snapshot,[Ns,Ref,1000])]);
                _->ok
            end,
            failed
        end,
        io:format("source_observation=~p~n",[peer:call(Asker,?MODULE,observe,[])]),
        io:format("source_trace=~p~n",[peer:call(Asker,?MODULE,finish,[])]),
        io:format("target_trace=~p~n",[peer:call(Target,?MODULE,finish,[])]),
        Result
    after quod_ask_SUITE:end_per_suite(Config) end.

start() ->
    Collector=spawn(fun()->collect([],0) end),true=register(m0_outcome_events,Collector),
    Trace=trace:session_create(m0_outcome,Collector,[]),
    persistent_term:put(m0_outcome_trace,Trace),
    lists:foreach(fun({M,F,A})->
        {module,M}=code:ensure_loaded(M),
        trace:function(Trace,{M,F,A},[{'_',[],[{return_trace}]}],[local])
    end,[{quod_dtx_endpoint,decode_response,2},{quod_dtx_endpoint,encode_response,3},{quod_dtx_endpoint,correlates,2},{quod_dtx_endpoint,outcome_matches_ref,2},
         {quod_prolog,outcome,1},{quod_simplex,dtx_outcome_lookup,2},
         {quod_simplex,dtx_endpoint_request,7},
         {quod_dtx_current_view,lookup_outcome,4},
         {quod_dtx_current_view,call_current_view,4},
         {quod_dtx_current_view,probe_outcome,6},
         {quod_foreign_log,route_hints,2},{quod_foreign_log,current,4},
         {quod_foreign_log,verification_call,2},
         {quod_foreign_log,current_evidence,7},
         {quod_foreign_log,current_feed_tip,4}]),
    lists:foreach(fun({F,A})->trace:function(Trace,{quod_simplex,F,A},
        [{'_',[],[{return_trace},{message,false}]}],[local]) end,
        [{outcome_snapshot_wait,3},{current_outcome_snapshot,5},{endpoint_read_ready,1},{outcome_request_binding,2}]),
    trace:function(Trace,{quod_simplex,execute_outcome_snapshot,3},[{'_',[],[{return_trace}]}],[local]),
    trace:process(Trace,all,true,[call,set_on_spawn,monotonic_timestamp]),ok.

finish() ->
    Trace=persistent_term:get(m0_outcome_trace),
    Barrier=trace:delivered(Trace,all),
    receive {trace_delivered,all,Barrier}->ok after 2000->error(trace_barrier) end,
    whereis(m0_outcome_events)!{get,self()},
    Rows=receive {events,Events}->Events after 2000->error(collector) end,
    trace:session_destroy(Trace),whereis(m0_outcome_events)!stop,Rows.

collect(Rows,N) ->
    receive
        {trace_ts,P,call,{M,F,Args},T} when N<2048 ->
            Details=case {M,F,Args} of
                {quod_prolog,outcome,[Ref]}->Ref;
                {quod_simplex,dtx_outcome_lookup,[_Ref,Timeout]}->{timeout,Timeout};
                {quod_foreign_log,current,[_Routes,Identity,_Contact,Timeout]}->{Identity,Timeout};
                {quod_dtx_endpoint,decode_response,[Ns,Frame]}->put({frame,P},Frame),{Ns,byte_size(Frame),crypto:hash(sha256,Frame)};
                {quod_dtx_endpoint,encode_response,[Ns,Response,_]}->{Ns,brief_response(Response)};
                _->none
            end,
            collect([{T,P,call,{M,F,length(Args)},Details}|Rows],N+1);
        {trace_ts,P,return_from,MFA,Result,T} when N<2048 ->
            Details=case {MFA,Result,erase({frame,P})} of
                {{quod_dtx_endpoint,decode_response,2},{error,{protocol_error,Reason}},Frame} when is_binary(Frame)->
                    case quod_safe_term:decode(Frame,byte_size(Frame)) of
                        {ok,{_,_,_,Inner,_}}->
                            case quod_safe_term:decode_wrapped(Inner,byte_size(Inner)) of
                                {ok,Wrapped}->{protocol_error,Reason,unknown_symbols(Wrapped)};
                                _->{protocol_error,Reason,not_canonical}
                            end;
                        _->brief(Result)
                    end;
                _->brief(Result)
            end,
            collect([{T,P,return,MFA,Details}|Rows],N+1);
        {get,From}->From!{events,lists:reverse(Rows)},collect(Rows,N);
        stop->ok;
        _->collect(Rows,N)
    end.

brief({ok,Response,_Hints}) when is_tuple(Response)->{response,brief_response(Response)};
brief({ok,B}) when is_binary(B)->{frame,byte_size(B),crypto:hash(sha256,B)};
brief({outcome_state,#{applied_floor:=Floor,outcome:=Outcome}})->{outcome_state,Floor,brief({ok,Outcome})};
brief({ok,M}) when is_map(M)->{ok,maps:with([status,phase,slot,applied,applied_floor,height],M)};
brief({ok,L}) when is_list(L)->{ok,{list,length(L)}};
brief({error,R}) when is_atom(R)->{error,R};
brief({error,{Tag,_}})->{error,Tag};
brief({ok,_})->ok;
brief(X) when is_atom(X)->X;
brief(_)->other.

unknown_symbols({'$quod_symbol',Name})->[Name];
unknown_symbols(T) when is_tuple(T)->lists:usort(lists:append([unknown_symbols(X)||X<-tuple_to_list(T)]));
unknown_symbols(M) when is_map(M)->unknown_symbols(maps:to_list(M));
unknown_symbols([H|T])->lists:usort(unknown_symbols(H)++unknown_symbols(T));
unknown_symbols(_)->[].

brief_response({outcome,Id,_Target,_Committee,Floor,Outcome})->{outcome,Id,Floor,brief({ok,Outcome})};
brief_response(Response) when is_tuple(Response)->{element(1,Response),element(2,Response)}.

observe() ->
    Rows=[{P,process_info(P,[registered_name,current_function,current_stacktrace,
                           message_queue_len,status])} || P<-processes()],
    #{foreign_stats=>quod_foreign_log:stats(),
      stacks=>lists:sublist([R || R={_,I}<-Rows,I=/=undefined,
          lists:any(fun({M,_,_,_})->lists:member(M,[quod_foreign_log,quod_dtx_current_view,quod_dtx_endpoint,quod_simplex]);(_)->false end,
            proplists:get_value(current_stacktrace,I,[]))],32)}.
