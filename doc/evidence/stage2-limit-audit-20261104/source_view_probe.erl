-module(source_view_probe).
-export([run/0]).

%% Exercise the exported WebSocket callback and observe its existing private
%% shape validator. Expiry=1 deliberately prevents workers, authorization or
%% stores from being opened: this is a pre-admission check, not a signed proof.
run() ->
    {module,quod_client_view}=code:ensure_loaded(quod_client_view),
    Parent=self(), Tracer=spawn(fun()->relay(Parent) end),
    1=erlang:trace(self(),true,[call,{tracer,Tracer}]),
    1=erlang:trace_pattern({quod_client_view,view_request,4},[{'_',[],[{return_trace}]}],[local]),
    try
        Results=[check(N) || N <- [255,256,1024]],
        [accepted,error,error]=Results,
        io:format("OBSERVED_EXISTING_GAP ~p~n",[lists:zip([255,256,1024],Results)]),
        io:format("LOADED_BEAMS ~p~n",[[{M,P} || {M,P} <- code:all_loaded(),is_list(P),
            lists:prefix("quod_",atom_to_list(M)) orelse lists:prefix("erlog",atom_to_list(M))]])
    after
        erlang:trace(self(),false,[call]),
        erlang:trace_pattern({quod_client_view,view_request,4},false,[local]),
        Tracer!stop
    end.

relay(Parent) -> receive stop->ok; Message->Parent!Message,relay(Parent) end.
check(Size) ->
    Ns=binary:copy(<<"n">>,Size), Gui = <<"quod:gui">>, Anchor = <<1:256>>,
    Value=fun quod_client_goal_parser:value_text/1,
    Goal=iolist_to_binary([Value(Gui)," :: (current_ontology_identity(",Value(Gui),",",
        Value(Anchor),"),prolog_inspect(",Value({ontology_ref,Ns,Anchor}),",presentation,View))."]),
    {Pub,Private}=crypto:generate_key(eddsa,ed25519),
    Request=#{network_identity=><<2:256>>,agent_namespace=><<"quod:agent">>,
        agent_genesis_anchor=>Anchor,agent_instance_text=><<"human_user(test_agent).">>,
        signing_public_key=>Pub,operation_id=><<3:256>>,not_after_ms=>1,
        mode=>read,parser_version=>3,goal_text=>Goal},
    {ok,Bytes}=quod_client_goal:encode(Request),
    Signature=crypto:sign(eddsa,none,Bytes,[Private,ed25519]),
    true=crypto:verify(eddsa,none,Bytes,Signature,[Pub,ed25519]),
    Enc=fun(B)->base64:encode(B,#{mode=>urlsafe,padding=>false}) end,
    Message=iolist_to_binary(json:encode(#{type=>open,view_kind=>source_access,
        session_id=>Enc(<<4:256>>),view_namespace=>Gui,view_anchor=>Enc(Anchor),
        request=>Enc(Bytes),signature=>Enc(Signature)})),
    {reply,{text,Reply},#{peer:=_}}=quod_client_view:websocket_handle({text,Message},#{peer=>{127,0,0,1}}),
    #{<<"reason">>:=<<"invalid_view_request">>}=json:decode(Reply),
    Self=self(),
    Verdict=receive
        {trace,Self,return_from,{quod_client_view,view_request,4},{ok,_,[]}}->accepted;
        {trace,Self,return_from,{quod_client_view,view_request,4},error}->error
    after 10000 -> error(missing_validator_return_trace)
    end,
    io:format("SOURCE_VIEW_NAMESPACE_BYTES ~p SHAPE ~p~n",[Size,Verdict]),Verdict.
