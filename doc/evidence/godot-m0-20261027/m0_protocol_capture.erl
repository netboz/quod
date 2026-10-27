-module(m0_protocol_capture).
-export([run/0]).

run() ->
    Parent=self(), Tag=make_ref(),
    Collector=spawn_link(fun() -> collect(Parent,Tag,[],[]) end),
    Trace=trace:session_create(m0_protocol,Collector,[]),
    {module,quod_client_goal_ingress}=code:ensure_loaded(quod_client_goal_ingress),
    {module,quod_client_result}=code:ensure_loaded(quod_client_result),
    trace:function(Trace,{quod_client_goal_ingress,submit,2},true,[local]),
    trace:function(Trace,{quod_client_result,decode_binding,1},
                   [{'_',[],[{return_trace}]}],[]),
    trace:process(Trace,self(),true,[call,set_on_spawn]),
    try
        Tests = case os:getenv("M0_PROTOCOL_SCOPE") of
            "reset" -> [quod_controller_tests:invalid_saved_preferences_offer_fenced_reset_test_()];
            _ -> [
            quod_controller_tests:preferences_use_existing_instruction_and_form_test_(),
            quod_space_creation_tests:signed_empty_space_results_and_recovery_test_(),
            quod_gui_operations_tests:offered_creation_and_instance_operation_test_()
        ] end,
        ok=eunit:test(Tests,[verbose]),
        Barrier=trace:delivered(Trace,all),
        receive {trace_delivered,all,Barrier}->ok after 5000->error(trace_barrier) end,
        Collector!finish,
        receive {Tag,Requests,Bindings}->
            true=length(Requests)>4,
            Json=#{notice=><<"Disposable production-fixture identities only; no real account/session credentials">>,
                   requests=>[request(B,S)||{B,S}<-Requests],
                   decoded_binding_terms=>[iolist_to_binary(io_lib:format("~0p.",[B]))||B<-Bindings]},
            Out=os:getenv("M0_PROTOCOL_OUT"),
            ok=file:write_file(Out,json:encode(Json)),
            io:format("M0_CAPTURE_PASS requests=~p decoded_bindings=~p~n",[length(Requests),length(Bindings)])
        after 5000->error(capture_not_collected) end
    after trace:session_destroy(Trace),Collector!stop end,
    ok.

collect(Parent,Tag,Requests,Bindings) ->
    receive
        {trace,_,call,{quod_client_goal_ingress,submit,[B,S]}}
          when is_binary(B),is_binary(S) ->
            true=length(Requests)<128,
            collect(Parent,Tag,[{B,S}|Requests],Bindings);
        {trace,_,return_from,{quod_client_result,decode_binding,1},{ok,B}} ->
            true=length(Bindings)<256,
            collect(Parent,Tag,Requests,[B|Bindings]);
        finish -> Parent!{Tag,lists:reverse(Requests),lists:reverse(Bindings)},
                  collect(Parent,Tag,Requests,Bindings);
        stop -> ok;
        _ -> collect(Parent,Tag,Requests,Bindings)
    end.

request(Bytes,Signature) ->
    {ok,R}=quod_client_goal:decode(Bytes),
    #{request_bytes=>b64(Bytes),signature=>b64(Signature),
      namespace=>maps:get(agent_namespace,R),
      anchor=>b64(maps:get(agent_genesis_anchor,R)),
      actor=>maps:get(agent_instance_text,R),
      public_key=>b64(maps:get(signing_public_key,R)),
      operation_id=>b64(maps:get(operation_id,R)),
      not_after_ms=>integer_to_binary(maps:get(not_after_ms,R)),
      mode=>atom_to_binary(maps:get(mode,R)),goal=>maps:get(goal_text,R)}.
b64(B)->base64:encode(B,#{mode=>urlsafe,padding=>false}).
