-module(quod_gui_stage1_tests).
-include_lib("eunit/include/eunit.hrl").
-export([with_forms/1]).

authored_creation_recovery_test_() ->
    [{atom_to_list(Lane), {timeout,90,fun() -> with_forms(fun(C) ->
        Ns = case Lane of ordinary -> maps:get(namespace,C); atomic -> maps:get(storage,C) end,
        Subject = subject(Ns,class_ref,space),
        {ok,[#{'Classes':=Classes}],_} = quod_prolog:prove_ro(Ns,{gui_operation_classes,{'Classes'}}),
        ?assert(lists:member(space,Classes)), ?assert(lists:member(note,Classes)),
        [Finite,Infinite] = views(Ns,Subject),
        ?assertMatch({operation_view,create,_,_,_,_,_,_,[space,location],requires_input},Finite),
        ?assertMatch({operation_view,create_infinite,_,_,_,_,_,_,[space,location],requires_input},Infinite),
        Values = element(7,Finite),
        Destination = subject(maps:get(destination,C),entity_ref,room),
        Fields = case Lane of ordinary -> Values;
            atomic -> lists:keyreplace(space_placement,2,Values,
                {field,space_placement,{at,Destination,{transform,0,0,0,0,0,0}}}) end,
        %% The destination is an authored choice, not injected field data.
        case Lane of atomic ->
            edit(Ns,{assertz,{attribute,room,name,<<"Room">>}}),
            %% Explicit foreign destinations can be authored by the storage owner.
            Choice = {option,{at,Destination,{transform,0,0,0,0,0,0}},<<"Remote room">>},
            replace_placement_options(Ns,[{option,near_agent,<<"Near agent">>},Choice]);
            _ -> ok end,
        [Current|_] = views(Ns,Subject),
        {Reply,Bytes} = submit(C,Ns,Current,Fields),
        {Ref,Outcome} = created(C,Reply,Bytes,space),
        {entity_ref,Ns,_,Id} = Ref,
        holds(Ns,{attribute,Id,name,<<"Space">>}),
        holds(Ns,{attribute,Id,dimensions,{box,{q,100,<<"m">>},{q,100,<<"m">>},{q,100,<<"m">>}}}),
        holds(Ns,{attribute,Id,owner,maps:get(human,C)}),
        fails(Ns,{gui_pending_question,{'_'},{'_'}}),
        %% Losing the first result, clearing browser journals and a new device
        %% need only the retained instruction association and original history.
        Device = C#{session=>quod_personal_agent_tests:session(maps:get(human_pair,C))},
        Resolve = fun() -> ?assertMatch({ok,_,{operation_outcome,_,Outcome}},
            quod_personal_agent_tests:lookup(Device,Bytes)) end,
        Owners = lists:usort([maps:get(namespace,C),Ns,maps:get(destination,C)]),
        Reads = case Lane of ordinary -> 3; atomic -> 0 end,
        quod_outcome_result_tests:assert_unchanged_reads(Owners,Resolve,Reads),
        quod_outcome_result_tests:assert_no_generation(fun() ->
            [quod_outcome_result_tests:restart_outcome_owner(O) || O <- Owners] end),
        edit(Ns,{retract,{instance_of,space,Id}}), Resolve()
    end) end}} || Lane <- [ordinary,atomic]].

non_space_binding_and_updates_test_() ->
    {timeout,90,fun() -> with_forms(fun(C=#{storage:=Ns}) ->
        [View] = views(Ns,subject(Ns,class_ref,note)),
        {Reply,Bytes} = submit(C,Ns,View,[{field,note_name,<<"Original">>}]),
        {Ref,_} = created(C,Reply,Bytes,note),
        {entity_ref,_,_,Id} = Ref,
        fails(Ns,{entity_eidolons,Id,{operation,class},{'_'},[{'_'}|{'_'}]}),
        [Rename] = views(Ns,Ref),
        {Updated,_} = submit(C,Ns,Rename,[{field,note_name,<<"Changed">>}]),
        wait(Updated),
        [Next] = views(Ns,Ref), ?assertNotEqual(element(4,Rename),element(4,Next)),
        ?assertEqual([{field,note_name,<<"Changed">>}],element(7,Next)),
        {Stale,_} = submit(C,Ns,Rename,[{field,note_name,<<"Stale">>}]),
        ?assertMatch({ok,_,{normalized,{failed,_}}},Stale),
        ?assertEqual([],views(Ns,setelement(3,Ref,<<0:256>>)))
    end) end}.

retained_operation_views_update_and_revoke_test_() ->
    {timeout,90,fun() -> with_forms(fun(C=#{namespace:=Ns,human_pair:={Key,_}}) ->
        [Create] = views(Ns,subject(Ns,class_ref,note)),
        {Reply,Bytes} = submit(C,Ns,Create,[{field,note_name,<<"Original">>}]),
        {Ref,_} = created(C,Reply,Bytes,note),
        Parent = self(),
        Sockets = [spawn_link(fun() -> quod_physics_tests:simulation_socket(Parent,#{peer=>{127,0,0,1}}) end)
                   || _ <- [ordinary,spatial]],
        Reader = #{agent=>{Ns,quod_simplex:genesis_hash(Ns)},key_pair=>maps:get(human_pair,C),
                   network=><<42:256>>,instance=><<"me.">>},
        Open = fun(Socket) -> Socket ! {client,quod_gui_question_tests:gui_open_message(
            Reader,maps:get(session,C),gui_operations,Ns,quod_simplex:genesis_hash(Ns),Ref,0)} end,
        Project = fun(Socket,Text) ->
            #{<<"value">>:=Value} = quod_physics_tests:simulation_reply(Socket,<<"projection">>),
            ?assertNotEqual(nomatch,binary:match(Value,Text)) end,
        try
            [begin Open(S),Project(S,<<"Original">>) end || S <- Sockets],
            quod_lobby_tests:assert_read_has_no_io(fun() ->
                [quod_physics_tests:renew_simulation(S,fun() -> Open(S) end,3) || S <- Sockets]
            end),
            [Rename] = views(Ns,Ref),
            {Changed,ChangedBytes} = submit(C,Ns,Rename,[{field,note_name,<<"Updated">>}]),
            wait(Changed),
            %% Wait for the original result publication before renewing either view.
            ?assertMatch({ok,_,{operation_outcome,_,_}},quod_personal_agent_tests:lookup(C,ChangedBytes)),
            [begin quod_physics_tests:simulation_reply(S,<<"refresh">>), Open(S),Project(S,<<"Updated">>) end || S <- Sockets],
            edit(Ns,{retract,{agent_key,me,Key,active}}),
            [begin quod_physics_tests:simulation_reply(S,<<"refresh">>), Open(S),
                   quod_physics_tests:simulation_reply(S,<<"unavailable">>) end || S <- Sockets]
        after [S ! stop || S <- Sockets] end
    end) end}.

with_forms(Fun) ->
    Sources = lists:append([source(F) || F <- ["gui_instance.pl","gui_operation.pl","space_gui.pl"]]) ++
        quod_prolog:read_terms("test/fixtures/note-operations.pl"),
    quod_space_creation_tests:with_spaces(fun(C=#{identity:=Node,directory:=Dir}) ->
        Gui = <<"quod:gui">>,
        Sup = quod_agent_hosting_tests:start_ontology(Gui,Dir,Node,[],source("quod_gui.pl")),
        try
            [edit(Ns,{assertz,{gui_vocabulary,Gui,quod_simplex:genesis_hash(Gui)}})
                || Ns <- [maps:get(namespace,C),maps:get(storage,C),maps:get(destination,C)]],
            Fun(C)
        after quod_agent_hosting_tests:stop_ontology(Sup) end
    end,Sources).

replace_placement_options(Ns,Options) ->
    edit(Ns,{retract,{':-',{attribute,space_placement,options,{'_'}},{'_'}}}),
    edit(Ns,{assertz,{attribute,space_placement,options,Options}}).
source(File) -> quod_prolog:read_terms(filename:join(code:priv_dir(quod),"ontologies/"++File)).
subject(Ns,Kind,Id) -> {Kind,Ns,quod_simplex:genesis_hash(Ns),Id}.
views(Ns,Subject) ->
    case quod_prolog:prove_ro(Ns,{gui_operations,Subject,{'Views'}}) of
        {ok,[#{'Views':=Views}],_} -> Views;
        {fail,_} -> []
    end.
submit(C,Ns,{operation_view,Name,Subject,Revision,_,_,_,Control,_,_},Values) ->
    quod_personal_agent_tests:await_runtime_ready(maps:get(namespace,C)),
    Goal = {gui_operation,Subject,Name,Revision,Control,Values,{'Results'}},
    Exact = {',',{current_ontology_identity,Ns,quod_simplex:genesis_hash(Ns)},Goal},
    Scoped = case maps:get(namespace,C) of Ns -> Exact; _ -> {'::',Ns,Exact} end,
    {Instruction,Bytes} = quod_personal_agent_tests:instruction(C,Scoped),
    {quod_personal_agent_tests:instruct(C,submit,Instruction),Bytes}.
created(C,Reply,Bytes,Name) ->
    wait(Reply),
    {ok,#{request:=#{operation_id:=Id}}} = quod_client_goal:request_identity(Bytes),
    Lookup = quod_personal_agent_tests:request(C,read,{personal_instruction_lookup,Id,{'Bytes'},{'Signature'}}),
    Ns = maps:get(namespace,C), true = quod_reg:subscribe({runtime,Ns}),
    {ok,_,{operation_outcome,_,Outcome}} = try
        quod_personal_agent_tests:await_result(C,Lookup,quod_time:mono_ms()+10000)
    after quod_reg:unsubscribe({runtime,Ns}) end,
    ?assertEqual(1,length(maps:get(bindings,Outcome))),
    [Ref] = [R || {_,Results} <- maps:get(bindings,Outcome), is_list(Results), {result,N,R} <- Results, N =:= Name],
    {Ref,Outcome}.
wait({ok,Evidence,{normalized,{committed,_,_}}}) ->
    Op = quod_client_goal:operation_ref(Evidence),
    ?assertMatch(#{operation_state:=terminal},quod_ct:await_operation_complete(element(2,Op),Op,10000)).
edit(Ns,Goal) -> ?assertMatch({ok,_,_},quod_prolog:execute(Ns,Goal)).
holds(Ns,Goal) -> ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,Goal)).
fails(Ns,Goal) -> ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,Goal)).
