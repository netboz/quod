-module(godot_m1b_fixture).
-export([start/0]).
-define(L, quod_lifecycle_single_path_tests).

%% Test-only endpoint. Reuses the qualified M1a factory and the same production
%% founding, enrollment, atomic setup, auth, vault and view owners.
start() ->
    F = ?L:setup(genesis),
    #{dir := Dir, manager := Manager, actor_keypair := {Key,_}} = F,
    {ok,Network} = quod_ontology:network_identity(),
    {ok,Auth} = quod_client_auth:start_link(#{network_id=>Network,node_key=>Key}), unlink(Auth),
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
        endpoint(Dir,Network)
    after ?L:stop_process(Auth), ?L:cleanup(F), ?L:stop_process(Vault) end.

endpoint(Dir,Network) ->
    {ok,_} = application:ensure_all_started(ssl), {ok,_} = application:ensure_all_started(cowboy),
    {ok,Cursors} = quod_client_cursor:start_link(), unlink(Cursors),
    {ok,Tls} = quod_client_tls:ensure(Dir),
    {ok,started} = quod_http_listener:start(#{name=>quod_m1b_listener,ip=>{127,0,0,1},port=>0,
        routes=>quod_client:routes(),stream_handlers=>[quod_http_headers_h],tls=>Tls}),
    Evidence = os:getenv("QUOD_M1B_PRIVATE"),
    Ca = filename:join(Evidence,"backend-ca.pem"),
    ok = file:write_file(Ca,public_key:pem_encode([{'Certificate',maps:get(cert,Tls),not_encrypted}])),
    {ok,Control} = gen_tcp:listen(0,[binary,{packet,line},{active,false},{ip,{127,0,0,1}},{reuseaddr,true}]),
    {ok,{_,ControlPort}} = inet:sockname(Control),
    Driver = spawn_link(fun() -> control(Control) end),
    io:format("M1B_READY ~s~n",[json:encode(#{port=>ranch:get_port(quod_m1b_listener),control_port=>ControlPort,network=>?L:m1a_b64(Network),ca=>list_to_binary(Ca)})]),
    try commands() after exit(Driver,shutdown),gen_tcp:close(Control),quod_http_listener:stop(quod_m1b_listener),?L:stop_process(Cursors) end.

control(Listener) ->
    case gen_tcp:accept(Listener) of
        {ok,Socket} ->
            {ok,Line} = gen_tcp:recv(Socket,0,10000),
            #{<<"request">> := Encoded} = json:decode(Line),
            Bytes = base64:decode(Encoded,#{mode=>urlsafe,padding=>false}),
            {ok,#{mode:=Mode,goal_text:=Text,parser_version:=Parser}} = quod_client_goal:decode(Bytes),
            Original = case Mode of
                read -> {ok,#{goal:={{'$quod_symbol',<<"personal_instruction_accept">>},Target,_}}} = quod_client_goal_parser:parse(Text,Parser), Target;
                execute -> Bytes
            end,
            {ok,#{operation_ref:=Ref,request:=#{agent_namespace:=Ns}}} = quod_client_goal:request_identity(Original),
            #{operation_state:=terminal} = quod_ct:await_operation_complete(Ns,Ref,10000),
            ok = gen_tcp:send(Socket,<<"{\"terminal\":true}\n">>),gen_tcp:close(Socket),control(Listener);
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
