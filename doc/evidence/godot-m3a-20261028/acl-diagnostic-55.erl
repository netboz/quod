-module(quod_m3a_acl_diagnostic_tests).
-include_lib("eunit/include/eunit.hrl").

diagnose_test_() ->
    {setup,fun start/0,fun stop/1,
     fun(_)->quod_ontology_acl_acceptance_tests:two_independent_users_over_https_test_() end}.

start() ->
    Collector=spawn_link(fun()->collect([]) end),
    [code:ensure_loaded(M)||M<-[quod_client_result,quod_client_goal_parser]],
    Session=trace:session_create(m3a_acl_refusal,Collector,[]),
    trace:function(Session,{quod_client_result,public_error,1},true,[local]),
    trace:function(Session,{quod_client_result,encode,1},[{'_',[],[{return_trace}]}],[local]),
    trace:function(Session,{quod_client_goal_parser,parse_program,2},[{'_',[],[{return_trace}]}],[local]),
    trace:process(Session,all,true,[call]),
    trace:process(Session,new,true,[call]),
    {Session,Collector}.
stop({Session,Collector}) ->
    Delivered=trace:delivered(Session,all),
    receive {trace_delivered,all,Delivered}->ok after 5000->error(trace_delivery_timeout) end,
    Ref=make_ref(),Collector!{finish,self(),Ref},
    receive {Ref,Rows}->
        Text=iolist_to_binary(io_lib:format("~tp~n",[Rows])),
        Prefix=os:getenv("QUOD_M3A_EVIDENCE"),
        ok=file:write_file(Prefix++"-acl-diagnostic.txt",Text,[exclusive]),
        io:format("M3a ACL diagnostic causes: ~tp~n",[Rows])
    after 5000->error(trace_collector_timeout) end,
    trace:session_destroy(Session).
collect(Rows) ->
    receive
        {trace,_,call,{quod_client_result,public_error,[Reason]}} ->
            collect([{public_error,redact(Reason,6)}|Rows]);
        {trace,_,return_from,MFA,{error,Reason}} ->
            collect([{MFA,redact(Reason,6)}|Rows]);
        {finish,Parent,Ref}->Parent!{Ref,lists:reverse(Rows)};
        _->collect(Rows)
    end.
redact(_,0)->depth_limit;
redact(B,_) when is_binary(B)->{binary_bytes,byte_size(B)};
redact(T,N) when is_tuple(T)->list_to_tuple([redact(V,N-1)||V<-lists:sublist(tuple_to_list(T),8)]);
redact(L,N) when is_list(L)->[redact(V,N-1)||V<-lists:sublist(L,8)];
redact(M,N) when is_map(M)->[{redact(K,N-1),redact(V,N-1)}||{K,V}<-lists:sublist(maps:to_list(M),8)];
redact(V,_)->V.
