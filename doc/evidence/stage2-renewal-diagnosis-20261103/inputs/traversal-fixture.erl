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
        N = ?L:m1a_found(<<"quod:node">>,["quod_node.pl"],
            [{node_identity_template,?L:m1a_source("node_instance.pl")}],[quod_agent_predicates]),
        ?L:observe_enrollment_completion(Manager), ?L:m1a_register(<<"quod:node">>,N,true),
        ok = quod_namespace_manager:enroll_node(), ?L:await_enrollment_completion(Manager),
        {ok,Blob} = quod_identity:load_node_actor_pointer(Dir),
        {ok,#{reference := Node}} = quod_agent_ref:decode(Blob),
        A = ?L:m1a_found(<<"quod:agent">>,["quod_agent.pl"],[],[quod_agent_predicates]),
        ?L:m1a_register(<<"quod:agent">>,A,false),
        G = ?L:m1a_found(<<"quod:gui">>,["quod_gui.pl","gui_measure.pl","gui_scene.pl","gui_tools.pl"],[],[quod_agent_predicates,quod_gui_predicates]),
        ?L:m1a_register(<<"quod:gui">>,G,false),
        GP = [{gui_vocabulary,<<"quod:gui">>,G},{measure_vocabulary,<<"quod:gui">>,G},
              {rendering_vocabulary,<<"quod:gui">>,G},{modelling_vocabulary,<<"quod:gui">>,G}],
        C = ?L:m1a_found(<<"quod:controllers">>,["quod_controllers.pl"],[{gui_vocabulary,<<"quod:gui">>,G}],[quod_agent_predicates]),
        ?L:m1a_register(<<"quod:controllers">>,C,false),
        Digest = crypto:hash(sha256,?L:m1a_source("quod_space.pl")),
        S = ?L:m1a_found(<<"quod:space">>,["quod_space.pl"],GP++[space_foundation,{acl_sovereign,{':',quod,space}},{space_template_hash,Digest}],[quod_agent_predicates]),
        ?L:m1a_register(<<"quod:space">>,S,false),
        Files = ["user_instance.pl","agent_instance.pl","quod_space.pl","gui_instance.pl"],
        Frozen = [{user_source_component,list_to_binary(File),crypto:hash(sha256,?L:m1a_source(File))} || File<-Files],
        U = ?L:m1a_found(<<"quod:user">>,["quod_user.pl"],GP++Frozen++[
            {agent_vocabulary,<<"quod:agent">>,A},{controllers_vocabulary,<<"quod:controllers">>,C},
            {space_vocabulary,<<"quod:space">>,S},{space_source_digest,Digest},
            {user_source_directory,list_to_binary(filename:join(code:priv_dir(quod),"ontologies"))},{signup_host,Node}],[quod_agent_predicates]),
        ?L:commit_root({assertz,{root_administrator_agent,Node}}),
        NodeClient = #{reference=>Node,keypair=>maps:get(actor_keypair,F),network=>Network,parser_version=>3},
        {ok,Reg,{normalized,{committed,_,_}}} = ?L:submit_lobby(NodeClient,execute,
            {transaction,?L:m1a_conj([{'::',<<"quod:root">>,{transaction,?L:m1a_conj([
                {assertz,{system_ontology,<<"quod:user">>,U}},{assertz,{ontology_creation_policy,<<"quod:user">>,U}}])}},
                {assertz,{ontology_hosting_policy,<<"quod:user">>,U}}])}),
        ?L:m1a_complete(Reg),
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
            #{<<"appearance_lens_rows">> := true} ->
                Terms=quod_committed_projection:read_terms(filename:join(code:priv_dir(quod),"ontologies/gui_tools.pl")),
                [Before]=[T||T={':-',{rows,<<"ontology_policy">>,_,_},_}<-Terms],
                Target={'Target'},
                After={':-',{rows,<<"ontology_policy">>,[Target],[{source,{source_chunk,done,<<"% revised inspection lens\n">>}}]},
                       {source_rows,Target,identity,Target}},
                {ok,[#{'A':=A}],_}=quod_prolog:prove_ro(<<"quod:root">>,{system_ontology,<<"quod:gui">>,{'A'}}),
                Body={',',{'$quod_retract_exact',Before},{assertz,After}},
                Goal={'::',<<"quod:gui">>,{',',{current_ontology_identity,<<"quod:gui">>,A},{',',system_prolog_edit,{transaction,Body}}}},
                {Numbered,_,_}=erlog_int:term_instance(Goal,0),
                {ok,Evidence,{normalized,{committed,_,_}}}=?L:submit_lobby(NodeClient,execute,Numbered),
                ?L:m1a_complete(Evidence),#{lens_rows_changed=>true};
            #{<<"appearance_workspace">> := true} ->
                {ok,[#{'A':=A}],_}=quod_prolog:prove_ro(<<"quod:root">>,{system_ontology,<<"quod:gui">>,{'A'}}),
                Appearance={appearance,1,[{token,accent,{rgb,100,220,160}},{token,panel,{rgb,26,50,40}},{token,spacing,18}]},
                Clause={':-',{attribute,workspace,appearance,Appearance},true},
                Goal={'::',<<"quod:gui">>,{',',{current_ontology_identity,<<"quod:gui">>,A},
                       {',',system_prolog_edit,{transaction,{assertz,Clause}}}}},
                {Numbered,_,_}=erlog_int:term_instance(Goal,0),
                {ok,Evidence,{normalized,{committed,_,_}}}=?L:submit_lobby(NodeClient,execute,Numbered),
                ?L:m1a_complete(Evidence),#{appearance_changed=>true};
            #{<<"workbench_controls">> := true} ->
                %% One explicit administrator edit in this disposable fixture.
                %% The target graph facts and human's source draft stay unchanged.
                File=filename:join(code:priv_dir(quod),"ontologies/gui_tools.pl"),
                Terms=quod_committed_projection:read_terms(File),
                [Before]=[T||T={':-',{eidolon,workbench,_,_},_}<-Terms],
                After=workbench_caption(Before),true=Before=/=After,
                {ok,[#{'A':=A}],_}=quod_prolog:prove_ro(<<"quod:root">>,{system_ontology,<<"quod:gui">>,{'A'}}),
                Body={',',{'$quod_retract_exact',Before},{assertz,After}},
                Goal={'::',<<"quod:gui">>,{',',{current_ontology_identity,<<"quod:gui">>,A},
                       {',',system_prolog_edit,{transaction,Body}}}},
                {Numbered,_,_}=erlog_int:term_instance(Goal,0),
                {ok,Evidence,{normalized,{committed,_,_}}}=?L:submit_lobby(NodeClient,execute,Numbered),
                ?L:m1a_complete(Evidence),#{controls_changed=>true};
            #{<<"stage2_ontology_mark">> := #{<<"Namespace">> := Ns, <<"Anchor">> := Encoded}} ->
                Anchor=base64:decode(Encoded,#{mode=>urlsafe,padding=>false}),
                {ok,[#{'Depicts':=Depicts}],_}=quod_prolog:prove_ro(<<"quod:gui">>,
                    {subject,none,{ontology_ref,Ns,Anchor},{'Depicts'}}),
                #{depicts=>quod_client_goal_parser:value_text(Depicts)};
            #{<<"measure_catalogue">> := true} ->
                MFAs=[{quod_erlog_db_mvcc,get_interpreted_functors,1},{quod_common_primitives,program_source_2,3}],
                [code:ensure_loaded(M)||{M,_,_}<-MFAs],
                Trace=trace:session_create(composition_catalogue_work,self(),[]),
                try
                    [trace:function(Trace,MFA,true,[local,call_count])||MFA<-MFAs],
                    ok=gen_tcp:send(Socket,<<"{\"ready\":true}\n">>),
                    {ok,<<"finish\n">>}=gen_tcp:recv(Socket,0,30000),
                    #{counts=>[#{function=>quod_client_goal_parser:value_text(MFA),calls=>element(2,trace:info(Trace,MFA,call_count))}||MFA<-MFAs]}
                after trace:session_destroy(Trace) end;
            #{<<"profile_renewal">> := true} ->
                {ok,{erlog_int,ExpectedMd5}}=beam_lib:md5("/build/source/_build/default/lib/erlog/ebin/erlog_int.beam"),
                ExpectedMd5=erlog_int:module_info(md5),
                Table=ets:new(stage2_dispatch_profile,[set,public,{write_concurrency,true}]),
                persistent_term:put(stage2_dispatch_profile,Table),
                {Cpu0,_}=statistics(runtime),Start=erlang:monotonic_time(microsecond),
                Work=quod_physics_tests:observe_live_geometry_work(fun()->
                    ok=gen_tcp:send(Socket,<<"{\"ready\":true}\n">>),
                    gen_tcp:recv(Socket,0,30000)
                end),
                persistent_term:erase(stage2_dispatch_profile),
                {Cpu1,_}=statistics(runtime),
                Report=#{work=>quod_physics_tests:m3a_public_json(Work),
                  wall_us=>erlang:monotonic_time(microsecond)-Start,cpu_ms=>Cpu1-Cpu0,
                  engine_md5=>base64:encode(ExpectedMd5),
                  profile=>[#{predicate=>quod_client_goal_parser:value_text(F),calls=>N,deref_us=>T}
                    ||{F,N,T}<-ets:tab2list(Table)]},
                io:format("RENEWAL_PROFILE ~s~n",[json:encode(Report)]),Report;
            #{<<"measure">> := true} ->
                Trace=trace:session_create(renewal_catalogue_count,self(),[]),
                MFA={quod_erlog_db_mvcc,get_interpreted_functors,1},
                try
                    trace:function(Trace,MFA,true,[local,call_count]),
                    Work=quod_physics_tests:observe_live_geometry_work(fun()->
                        ok=gen_tcp:send(Socket,<<"{\"ready\":true}\n">>),
                        {ok,<<"finish\n">>}=gen_tcp:recv(Socket,0,30000)
                    end),
                    #{work=>quod_physics_tests:m3a_public_json(Work),
                      catalogue_calls=>element(2,trace:info(Trace,MFA,call_count))}
                after trace:session_destroy(Trace) end;
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
            #{<<"composition_target">> := #{<<"namespace">> := HumanNs, <<"anchor">> := HumanAnchor}} ->
                Human={agent_instance_ref,HumanNs,base64:decode(HumanAnchor,#{mode=>urlsafe,padding=>false}),me},
                Ns=?L:unique_ns(<<"predicate-content">>),
                Source=filename:join(os:getenv("QUOD_M3B_PRIVATE"),"composition_owner.pl"),
                Extra=[io_lib:format("presentation_item_~B(value).~n",[I])||I<-lists:seq(1,100)],
                ok=file:write_file(Source,[<<"can_invoke(_,P,_,_) :- composition_owner(P).\ncan_join(_,_,_).\nontology_source_mode(editable).\nsample(first,clause).\nsample(second,clause).\npredicate_with_a_complete_long_descriptive_name(first,clause).\n">>,Extra]),
                A=?L:m1a_found(Ns,[Source],[{composition_owner,Human}],[]),
                #{namespace=>Ns,anchor=>?L:m1a_b64(A)};
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
                read -> {ok,#{goal:={{'$quod_symbol',<<"personal_instruction_accept">>},Target,_}}} = quod_client_goal_parser:parse(Text,Parser), Target;
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

workbench_caption(<<"Ontology workbench">>)-><<"Ontology workbench - updated controls">>;
workbench_caption(T) when is_tuple(T)->list_to_tuple([workbench_caption(X)||X<-tuple_to_list(T)]);
workbench_caption([H|T])->[workbench_caption(H)|workbench_caption(T)];
workbench_caption(T)->T.
