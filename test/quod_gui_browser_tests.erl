%% Opt-in normal-UI acceptance. Run after compiling the test profile, with
%% QUOD_PLAYWRIGHT_MODULE naming the installed Playwright module. Every ontology
%% and key belongs to this disposable fixture; no running node is contacted.
-module(quod_gui_browser_tests).
-include_lib("eunit/include/eunit.hrl").
-export([run/0]).

run() ->
    quod_gui_stage1_tests:with_forms(fun(C) ->
        quod_space_creation_tests:with_models(C,fun() -> run_browser(C) end)
    end).

run_browser(C = #{namespace := Ns, directory := Dir, storage := Storage}) ->
        Anchor = quod_simplex:genesis_hash(Ns),
        [edit(Ns,{assertz,Fact}) || Fact <- [
            {rendering_vocabulary,<<"creation-rendering">>,quod_simplex:genesis_hash(<<"creation-rendering">>)},
            {':-',{account_navigation,{entity_ref,Ns,Anchor,room},[playing]},true}, {entity_scene,personal,{'_'},hidden},
            {space_member,room,{entity_ref,Storage,quod_simplex:genesis_hash(Storage),<<"foreign-display">>}}]],
        [edit(Storage,{assertz,Fact}) || Fact <- [
            {':-',{instance_of,space,<<"foreign-display">>},true},
            {attribute,room,name,<<"Foreign room">>},
            {attribute,<<"foreign-display">>,transform,{transform,5000,0,0,0,0,0}},
            {can_invoke,{'_'},maps:get(human,C),{'_'},{'_'}}]],
        {ViewBytes,ViewSignature} = quod_personal_agent_tests:request(C,read,
            {client_world_view,room,playing,[],{'World'}}),
        ViewReply = quod_client_goal_ingress:submit(ViewBytes,ViewSignature),
        ?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_]}}}},ViewReply),
        {ok,_} = application:ensure_all_started(ssl),
        {ok,_} = application:ensure_all_started(cowboy),
        {ok,Tls} = quod_client_tls:ensure(filename:join(Dir,"tls")),
        {ok,started} = quod_http_listener:start(#{name=>?MODULE,ip=>{127,0,0,1},port=>0,
            routes=>quod_client:routes(),stream_handlers=>[quod_http_headers_h],tls=>Tls}),
        Destination = {entity_ref,maps:get(destination,C),quod_simplex:genesis_hash(maps:get(destination,C)),room},
        edit(Ns,{retract,{':-',{attribute,space_placement,options,{'_'}},{'_'}}}),
        edit(Ns,{assertz,{attribute,space_placement,options,
            [{option,near_agent,<<"Near agent">>},{option,{at,Destination,{transform,0,0,0,0,0,0}},<<"Remote room">>}]}}),
        {Pub,Private} = maps:get(human_pair,C),
        Config = #{port=>ranch:get_port(?MODULE),public=>b64(Pub),private=>b64(Private),
            namespace=>Ns,storage=>Storage,anchor=>b64(quod_simplex:genesis_hash(Ns)),network=>b64(<<42:256>>)},
        Path = filename:join(Dir,"browser.json"),
        ok = quod_file:write_atomic(Path,json:encode(Config),8#600),
        Port = open_port({spawn_executable,os:find_executable("node")},
            [binary,exit_status,{line,1048576},{args,["test/gui-stage1-browser.mjs",Path]}]),
        try browser(Port,C)
        after catch port_close(Port), quod_http_listener:stop(?MODULE) end.

browser(Port,C) ->
    receive
        {Port,{data,{eol,<<"COMMAND ",Json/binary>>}}} ->
            #{<<"action">>:=Action} = Command = json:decode(Json),
            control(Action,Command,C),
            true = port_command(Port,<<"ok\n">>), browser(Port,C);
        {Port,{data,{eol,Line}}} -> io:format("~s~n",[Line]), browser(Port,C);
        {Port,{data,{noeol,Line}}} -> io:format("~s",[Line]), browser(Port,C);
        {local_proof_waiting, Proof, _} ->
            case erase(conflict_edit) of undefined -> ok; {Owner,Goal} -> edit(Owner,Goal) end,
            Proof ! release, browser(Port,C);
        {Port,{exit_status,0}} -> ok;
        {Port,{exit_status,Code}} -> error({browser_failed,Code})
    after 120000 -> error(browser_protocol_timeout)
    end.

control(<<"deny">>,_,#{namespace:=Ns}) -> edit(Ns,{retract,creation_enabled});
control(<<"allow">>,_,#{namespace:=Ns}) -> edit(Ns,{assertz,creation_enabled});
control(<<"deny_placement">>,_,#{storage:=Ns}) -> edit(Ns,{retract,admission_enabled});
control(<<"allow_placement">>,_,#{storage:=Ns}) -> edit(Ns,{assertz,admission_enabled});
control(<<"arm_conflict">>,_,C=#{storage:=Ns}) -> hold_creation(C,{Ns,{retract,creation_enabled}});
control(<<"arm_revocation">>,_,C=#{namespace:=Ns,human_pair:={Key,_}}) ->
    hold_creation(C,{Ns,{retract,{agent_key,me,Key,active}}});
control(<<"disarm_conflict">>,_,#{storage:=Ns}) ->
    gproc:unreg(quod_reg:name({host_test,local_proof})),
    {Original,Held} = erase(conflict_forms), edit(Ns,{retract,Held}), edit(Ns,{assertz,Original}),
    edit(Ns,{';',creation_enabled,{assertz,creation_enabled}});
control(<<"revoke_human">>,_,#{namespace:=Ns,human_pair:={Key,_}}) -> edit(Ns,{retract,{agent_key,me,Key,active}});
control(<<"restore_human">>,_,#{namespace:=Ns,human_pair:={Key,_}}) -> edit(Ns,{assertz,{agent_key,me,Key,active}});
control(<<"stop_agent">>,_,#{namespace:=Ns}) -> supervisor:terminate_child(quod_reg:where({quod_ns,Ns}),quod_runtime);
control(<<"start_agent">>,_,C) -> start_runtime(C);
control(<<"delete_created">>,_,#{namespace:=Ns}) ->
    {ok,[#{'Ids':=Ids}],_} = quod_prolog:prove_ro(Ns,{findall,{'Id'},
        {',',{instance_of,space,{'Id'}},{attribute,{'Id'},name,{'Name'}}},{'Ids'}}),
    [edit(Ns,{retract,{instance_of,space,Id}}) || Id <- Ids];
control(<<"restart">>,_,C=#{namespace:=Ns}) ->
    ok = supervisor:terminate_child(quod_reg:where({quod_ns,Ns}),quod_runtime), start_runtime(C);
control(<<"place_agent">>,_,C=#{namespace:=Ns}) ->
    Room = {entity_ref,Ns,quod_simplex:genesis_hash(Ns),room},
    quod_personal_agent_tests:await_runtime_ready(Ns),
    {Instruction,_} = quod_personal_agent_tests:instruction(C,{',',
        {space_place,personal,0,Room},{assertz,{attribute,personal,transform,{transform,200,300,400,0,45,0}}}}),
    {ok,Evidence,{normalized,{committed,_,_}}} = quod_personal_agent_tests:instruct(C,submit,Instruction),
    ?assertMatch(#{operation_state:=terminal},quod_ct:await_operation_complete(Ns,
        quod_client_goal:operation_ref(Evidence),10000));
control(<<"verify">>,_,C=#{namespace:=Ns}) ->
    {ok,[#{'Count':=Count}],_} = quod_prolog:prove_ro(Ns,
        {findall,{'Id'},{personal_instruction,maps:get(human,C),{'Id'},{'_'},{'_'},{'_'},{'_'},{'_'}},{'Count'}}),
    ?assertEqual(11,length(Count)),
    ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{attribute,{'_'},name,<<"A revised note">>})),
    ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{gui_pending_question,{'_'},{'_'}})).

hold_creation(#{storage:=Ns},Edit) ->
    true = quod_reg:reg({host_test,local_proof}), put(conflict_edit,Edit),
    [Original={':-',{gui_form,Form,Fields,{submit,Control,Goal,Metadata}},Body}] =
        [Rule || Rule={':-',{gui_form,_,_,_},_} <- quod_prolog:read_terms("priv/ontologies/quod_space.pl")],
    Held = {':-',{gui_form,Form,Fields,{submit,Control,{',',Goal,test_local_wait},Metadata}},Body},
    put(conflict_forms,{Original,Held}), edit(Ns,{retract,Original}), edit(Ns,{assertz,Held}).

start_runtime(#{namespace:=Ns,agent:=Agent}) ->
    true = quod_reg:subscribe({agent,Agent}),
    try
        {ok,_} = supervisor:restart_child(quod_reg:where({quod_ns,Ns}),quod_runtime),
        receive {agent_installed,_,_,#{reference:=Agent},_} -> ok
        after 10000 -> error(agent_not_restarted) end,
        quod_personal_agent_tests:await_runtime_ready(Ns)
    after quod_reg:unsubscribe({agent,Agent}) end.

edit(Ns,Goal) -> ?assertMatch({ok,_,_},quod_prolog:execute(Ns,Goal)).
b64(B) -> base64:encode(B,#{mode=>urlsafe,padding=>false}).
