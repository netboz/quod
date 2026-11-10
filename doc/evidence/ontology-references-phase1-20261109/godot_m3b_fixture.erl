-module(godot_m3b_fixture).
-export([start/0]).
-define(L, quod_lifecycle_single_path_tests).

%% Test-only endpoint. Reuses the qualified M1a factory and the same production
%% founding, enrollment, atomic setup, auth, vault and view owners.
start() ->
    F = ?L:setup(genesis),
    #{dir := Dir, manager := Manager} = F,
    {ok,Network} = quod_ontology:network_identity(),
    {ok,Auth} = quod_client_auth:start_link(), unlink(Auth),
    Unlock = filename:join(Dir,"m1b-unlock"),
    ok = quod_file:write_atomic(Unlock,crypto:strong_rand_bytes(32),8#600),
    {ok,Vault} = quod_agent_vault:start_link(#{directory=>filename:join(Dir,"vault"),unlock_file=>Unlock}), unlink(Vault),
    try
        #{node_client := NodeClient} = ?L:m1a_foundations(F),
        endpoint(Dir,Network,NodeClient)
    after ?L:stop_process(Auth), ?L:cleanup(F), ?L:stop_process(Vault) end.

endpoint(Dir,Network,NodeClient) ->
    {ok,_} = application:ensure_all_started(ssl), {ok,_} = application:ensure_all_started(cowboy),
    {ok,Cursors} = quod_client_cursor:start_link(), unlink(Cursors),
    {ok,Tls} = quod_client_tls:ensure(Dir),
    ok=application:set_env(quod,client_enabled,true),
    ok=application:set_env(quod,client_ip,{127,0,0,1}),
    ok=application:set_env(quod,client_port,0),
    {ok,Client}=quod_client:start_link(), unlink(Client),
    Evidence = os:getenv("QUOD_M3B_PRIVATE"),
    Ca = filename:join(Evidence,"backend-ca.pem"),
    ok = file:write_file(Ca,public_key:pem_encode([{'Certificate',maps:get(cert,Tls),not_encrypted}])),
    {ok,Control} = gen_tcp:listen(0,[binary,{packet,line},{active,false},{ip,{127,0,0,1}},{reuseaddr,true}]),
    {ok,{_,ControlPort}} = inet:sockname(Control),
    Driver = spawn_link(fun() -> control(Control,NodeClient) end),
    io:format("M1B_READY ~s~n",[json:encode(#{port=>ranch:get_port(quod_client_listener),control_port=>ControlPort,network=>?L:m1a_b64(Network),ca=>list_to_binary(Ca)})]),
    try commands() after exit(Driver,shutdown),gen_tcp:close(Control),?L:stop_process(Client),?L:stop_process(Cursors) end.

control(Listener,NodeClient) ->
    case gen_tcp:accept(Listener) of
        {ok,Socket} ->
            {ok,Line} = gen_tcp:recv(Socket,0,10000),
            Command = json:decode(Line),
            Result = case Command of
            #{<<"measure">> := true} ->
                Work=quod_physics_tests:observe_live_geometry_work(fun()->
                    ok=gen_tcp:send(Socket,<<"{\"ready\":true}\n">>),
                    {ok,<<"finish\n">>}=gen_tcp:recv(Socket,0,30000)
                end),
                #{work=>quod_physics_tests:m3a_public_json(Work)};
            #{<<"m3_restart_views">> := true} ->
                Connections=ranch:procs(quod_client_listener,connections),
                Mons=[{P,monitor(process,P)}||P<-Connections],
                [exit(P,kill)||P<-Connections],
                [receive {'DOWN',M,process,P,_}->ok after 5000->error(view_owner_survived) end||{P,M}<-Mons],
                #{view_connections_restarted=>length(Connections)};
            #{<<"m3_restart_runtime">> := #{<<"Namespace">> := HumanNs}} ->
                true=quod_reg:subscribe({agent_hosting,HumanNs}),
                Old=quod_reg:where({quod_runtime,HumanNs}),M=monitor(process,Old),exit(Old,kill),
                receive {'DOWN',M,process,Old,_}->ok after 5000->error(runtime_survived) end,
                receive {agent_installed,Next,_,#{reference:={agent_instance_ref,HumanNs,_,personal}},_} when Next=/=Old->ok
                after 10000->error(personal_owner_not_recovered) end,
                quod_reg:unsubscribe({agent_hosting,HumanNs}),#{runtime_restarted=>HumanNs};
            #{<<"m2_foreign_storage">> := #{<<"Namespace">> := HumanNs, <<"Anchor">> := HumanAnchor}} ->
                History=base64:decode(HumanAnchor,#{mode=>urlsafe,padding=>false}),
                Owner={agent_instance_ref,HumanNs,History,me},
                Actor={agent_instance_ref,HumanNs,History,personal},
                {ok,[#{'U':=UserClass}],_}=quod_prolog:prove_ro(<<"quod:root">>,
                    {system_ontology,<<"quod:user">>,{'U'}}),
                #{network:=Network,reference:=Node}=NodeClient,
                Other=?L:m1a_setup(?L:m1a_signup(Network,UserClass,Node)),
                ?L:m2_foreign_policy(Other,Owner,Actor),
                {agent_instance_ref,Foreign,ForeignAnchor,me}=maps:get(reference,Other),
                #{namespace=>Foreign,anchor=>?L:m1a_b64(ForeignAnchor)};
            #{<<"m2_restart">> := #{<<"Namespace">> := HumanNs}} ->
                quod_outcome_result_tests:assert_no_generation(fun()->
                    quod_outcome_result_tests:restart_outcome_owner(HumanNs) end),
                #{restarted=>HumanNs};
            #{<<"vector_target">> := #{<<"namespace">> := HumanNs, <<"anchor">> := HumanAnchor}} ->
                Human={agent_instance_ref,HumanNs,base64:decode(HumanAnchor,#{mode=>urlsafe,padding=>false}),me},
                #{reference:={agent_instance_ref,NodeNs,NodeAnchor,_}}=NodeClient,
                Rule={':-',{m1b_vector_write,{'Value'}},{assertz,{m1b_vector_mark,{'Value'}}}},
                Permit={can_invoke,{',',{current_ontology_identity,NodeNs,NodeAnchor},{m1b_vector_write,{'Value'}}},Human,{'Caller'},{'Context'}},
                Goal={transaction,{',',{assertz,Rule},{assertz,Permit}}},
                {Numbered,_,_}=erlog_int:term_instance(Goal,0),
                {ok,Evidence,{normalized,{committed,_,_}}}=?L:submit_lobby(NodeClient,execute,Numbered),
                ?L:m1a_complete(Evidence), #{namespace=>NodeNs,anchor=>?L:m1a_b64(NodeAnchor)};
            #{<<"request">> := Encoded} ->
            Bytes = base64:decode(Encoded,#{mode=>urlsafe,padding=>false}),
            {ok,#{mode:=Mode,goal_text:=Text,parser_version:=Parser}} = quod_client_goal:decode(Bytes),
            Original = case Mode of
                read -> {ok,#{goal:={'::',<<"quod:user">>,{{'$quod_symbol',<<"personal_instruction_accept">>},Target,_}}}} = quod_client_goal_parser:parse(Text,Parser), Target;
                execute -> Bytes
            end,
            {ok,#{operation_ref:=Ref,request:=#{agent_namespace:=Ns}}} = quod_client_goal:request_identity(Original),
            #{operation_state:=terminal} = quod_ct:await_operation_complete(Ns,Ref,10000),
            #{terminal=>true};
            #{<<"source_access">> := Access} ->
                [Policy] = [T || T={':-',{system_source_access,_,_},_} <-
                    quod_prolog:read_terms(filename:join(code:priv_dir(quod),"ontologies/quod_root.pl"))],
                Denied={':-',{system_source_access,{'_'},{'_'}},fail},
                {Before,After} = case Access of <<"deny">> -> {Policy,Denied}; <<"restore">> -> {Denied,Policy} end,
                Goal={'::',<<"quod:root">>,{transaction,{',',{retract,Before},{assertz,After}}}},
                {Numbered,_,_}=erlog_int:term_instance(Goal,0),
                {ok,Evidence,{normalized,{committed,_,_}}}=?L:submit_lobby(NodeClient,execute,Numbered),
                ?L:m1a_complete(Evidence), #{source_access=>Access}
            end,
            ok = gen_tcp:send(Socket,[json:encode(Result),<<"\n">>]),gen_tcp:close(Socket),control(Listener,NodeClient);
        {error,closed} -> ok
    end.

commands() ->
    case io:get_line("") of
        eof -> ok;
        "stop\n" -> ok;
        Line ->
            case json:decode(list_to_binary(Line)) of
                #{<<"request">> := Encoded} ->
                    Bytes = base64:decode(Encoded,#{mode=>urlsafe,padding=>false}),
                    {ok,#{operation_ref:=Ref,request:=#{agent_namespace:=Ns}}} = quod_client_goal:request_identity(Bytes),
                    Result = quod_ct:await_operation_complete(Ns,Ref,10000),
                    io:format("M1B_SETTLED ~s~n",[json:encode(#{terminal=>maps:get(operation_state,Result)=:=terminal})]);
                #{<<"status">> := true} -> io:format("M1B_STATUS ready~n",[])
            end,
            commands()
    end.
