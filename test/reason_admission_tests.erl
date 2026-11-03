-module(reason_admission_tests).
-include_lib("eunit/include/eunit.hrl").
-include("erlog_int.hrl").

native_admission_validates_each_reason_once_test() ->
    {ok,St}=erlog_int:new(erlog_db_dict,null),
    {Final,Calls}=measured_add(St,{erlog_int,valid_failure_reason,1},128),
    ?assertEqual([{diagnostic,I}||I<-lists:seq(128,1,-1)],Final#est.fail_reasons),
    ?assertEqual(128,Calls).

projection_admission_encodes_only_at_delivery_test() ->
    St=quod_committed_projection:new_est(),
    {Final,Calls}=measured_add(St,{quod_wire_term,encode_failure_reasons,1},128),
    ?assertEqual(0,Calls),
    Reasons=Final#est.fail_reasons,
    ?assertEqual([{diagnostic,I}||I<-lists:seq(128,1,-1)],Reasons),
    {ok,Blob}=quod_wire_term:encode_failure_reasons(Reasons),
    ?assertEqual({ok,Reasons},quod_wire_term:decode_failure_reasons(Blob)).

native_and_wire_reason_shape_equivalence_test() ->
    Leaves=[ok,[],0,-3,1 bsl 256,1.25,<<>>,<<255>>,{'$quod_symbol',<<255>>},
            {'Variable'},{'_'},self(),make_ref(),fun()->ok end,#{a=>b},
            {},{42,a},{a},{a,b},{{'$quod_symbol',<<"opaque">>},b}],
    Terms=Leaves++[{reason,T}||T<-Leaves]++[[T,ok]||T<-Leaves]++
          [[ok|T]||T<-Leaves]++[{reason,{nested,[T]}}||T<-Leaves],
    lists:foreach(fun(T)->
        ?assertEqual(erlog_int:valid_failure_reason(T),
                     quod_wire_term:valid_failure_reason_stack([T]))
    end,Terms).

measured_add(St,MFA,N) ->
    {M,_,_}=MFA,{module,M}=code:ensure_loaded(M),
    Trace=trace:session_create(reason_admission,self(),[]),
    try
        trace:function(Trace,MFA,true,[local,call_count]),
        Final=lists:foldl(fun(I,Acc)->erlog_int:add_failure_reason({diagnostic,I},Acc) end,
                          St,lists:seq(1,N)),
        {call_count,Calls}=trace:info(Trace,MFA,call_count),
        {Final,Calls}
    after trace:session_destroy(Trace) end.
