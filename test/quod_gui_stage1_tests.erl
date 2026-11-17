-module(quod_gui_stage1_tests).
-include_lib("eunit/include/eunit.hrl").
-export([with_forms/1]).

created_spaces_show_the_shared_marker_test_() ->
    {timeout,90,fun() -> with_forms(fun(C=#{namespace:=Ns}) ->
        Subject=subject(<<"quod:space">>,class_ref,space), Room=subject(Ns,entity_ref,room),
        Pose={transform,1000,2000,3000,15,35,75}, Placement={at,Room,Pose},
        replace_placement_options(Ns,[{option,near_agent,<<"Near agent">>},
            {option,unplaced,<<"Unplaced">>},{option,Placement,<<"Rotated room">>}]),
        [Finite,Exact,Infinite]=views(C,Ns,Subject),
        Defaults=fields(element(7,Finite),[{placement_field(Ns),Placement}]),
        %% The form opens with a place name drawn for it.
        {field,space_name,Suggested}=lists:keyfind(space_name,2,Defaults),
        holds(<<"quod:names">>,{name,Suggested,{'_'},<<"place">>,<<"neutral">>}),
        {Reply,Bytes}=submit(C,Ns,Finite,Defaults),{Ref,_}=created(C,Reply,Bytes,space),
        holds(Ns,{attribute,element(4,Ref),dimensions,default_dimensions()}),
        holds(Ns,{attribute,element(4,Ref),exterior,solid}),
        assert_marker(scene(C,Ns,room),Ref,Pose,{label,Suggested,<<"above">>}),
        Values=fields(element(7,Exact),[{space_name,<<>>},{space_unit,<<"mm">>},
            {{space_length,width},1},{{space_divisor,width},3},
            {{space_length,height},1001},{{space_divisor,height},1},
            {{space_length,depth},1001},{{space_divisor,depth},2},
            {placement_field(Ns),Placement}]),
        {Rational,RationalBytes}=submit(C,Ns,Exact,Values),
        {RationalRef,_}=created(C,Rational,RationalBytes,space),
        holds(Ns,{attribute,element(4,RationalRef),name,<<>>}),
        holds(Ns,{attribute,element(4,RationalRef),dimensions,
            {box,{q,{'/',1,3},<<"mm">>},{q,{'/',1001,1},<<"mm">>},{q,{'/',1001,2},<<"mm">>}}}),
        %% The marker keeps one size whatever the space measures inside.
        assert_marker(scene(C,Ns,room),RationalRef,Pose,unlabelled),
        %% Explicit unplaced creation succeeds even though an ordinary
        %% near-agent location read is unavailable, without admission.
        edit(Ns,{assertz,{space_assignment_state,personal,1,Room}}),
        [Current|_]=views(C,Ns,Subject),
        {Unplaced,UnplacedBytes}=submit(C,Ns,Current,fields(element(7,Current),[{placement_field(Ns),unplaced}])),
        {UnplacedRef,_}=created(C,Unplaced,UnplacedBytes,space),
        ?assertEqual(unplaced,read(C,space({space_location,UnplacedRef,{'Location'}}))),
        %% No form offers an outside choice, and a direct request for the
        %% retired full-size one is refused.
        [?assertEqual(undefined,tree_property(element(5,View),{space_exterior,Extent},options))
            || {View,Extent} <- [{Finite,finite},{Exact,exact},{Infinite,infinite}]],
        Before=instances(Ns),
        Goal={with_build_plan,[{attribute,exterior,wireframe}],{assert,{instance_of,space_class(),{'Space'}}}},
        {Instruction,_}=quod_personal_agent_tests:instruction(C,Goal),
        quod_personal_agent_tests:await_runtime_ready(Ns),
        ?assertMatch({ok,_,{normalized,{failed,_}}},quod_personal_agent_tests:instruct(C,submit,Instruction)),
        ?assertEqual(Before,instances(Ns))
    end) end}.

fields(Values,Changes) ->
    lists:foldl(fun({Id,Value},Acc)->lists:keyreplace(Id,2,Acc,{field,Id,Value}) end,Values,Changes).
default_dimensions() -> {box,{q,10,<<"m">>},{q,10,<<"m">>},{q,10,<<"m">>}}.
instances(Ns) ->
    {ok,[#{'Rows':=Rows}],_}=quod_prolog:prove_ro(Ns,{findall,{'I'},{instance_of,space_class(),{'I'}},{'Rows'}}),Rows.
scene(C,Ns,Space) ->
    read(C,space({world_view,subject(Ns,entity_ref,Space),playing,{'Marks'}})).
assert_marker(Marks,{entity_ref,Ns,Anchor,Id},Pose,Label) ->
    [Root]=[M||M={mark,_,<<"group">>,[],Pose0,_,_,{depicts,N,A,I}}<-Marks,
        {N,A,I,Pose0}=:={Ns,Anchor,Id,Pose}],
    RootId=element(2,Root), At={relative,RootId,{transform,0,0,0,0,0,0}},
    Size=[{f,<<"width">>,500},{f,<<"height">>,500},{f,<<"depth">>,500}],
    ?assertMatch([{mark,_,<<"box">>,Size,At,{surfaces,_,_,_},unlabelled,depicts_nothing},
                  {mark,_,<<"corner_box">>,Size,At,{surfaces,_,_,_},Label,depicts_nothing}],
        [M||M={mark,_,_,_,{relative,Parent,_},_,_,_}<-Marks,Parent=:=RootId]).
tree_property({component,Id,_,Properties,_},Id,Key) -> proplists:get_value(Key,[{K,V}||{property,K,V}<-Properties]);
tree_property({component,_,_,_,Children},Id,Key) ->
    case [V||Child<-Children,(V=tree_property(Child,Id,Key))=/=undefined] of
        [Value]->Value; []->undefined end.

authored_creation_recovery_test_() ->
    [{atom_to_list(Lane), {timeout,90,fun() -> with_forms(fun(C) ->
        Ns = case Lane of ordinary -> maps:get(namespace,C); atomic -> maps:get(storage,C) end,
        Subject = subject(<<"quod:space">>,class_ref,space),
        {ok,[#{'Classes':=Classes}],_} = quod_prolog:prove_ro(Ns,{gui_operation_classes,{'Classes'}}),
        ?assert(lists:member(subject(Ns,class_ref,note),Classes)),
        [Finite,Exact,Infinite] = views(C,Ns,Subject),
        ?assertMatch({operation_view,create_exact,_,_,_,_,_,_,[space,location,owner],requires_input},Exact),
        ?assertMatch({operation_view,create,_,_,_,_,_,_,[space,location,owner],requires_input},Finite),
        ?assertMatch({operation_view,create_infinite,_,_,_,_,_,_,[space,location,owner],requires_input},Infinite),
        Values = element(7,Finite),
        Destination = subject(maps:get(destination,C),entity_ref,room),
        Fields = case Lane of ordinary -> Values;
            atomic -> lists:keyreplace(placement_field(Ns),2,Values,
                {field,placement_field(Ns),{at,Destination,{transform,0,0,0,0,0,0}}}) end,
        %% The destination is an authored choice, not injected field data.
        case Lane of atomic ->
            edit(Ns,{assertz,{attribute,room,name,<<"Room">>}}),
            %% The class owner authors choices for this storing ontology.
            Choice = {option,{at,Destination,{transform,0,0,0,0,0,0}},<<"Remote room">>},
            replace_placement_options(Ns,[{option,near_agent,<<"Near agent">>},Choice]);
            _ -> ok end,
        [Current|_] = views(C,Ns,Subject),
        {Reply,Bytes} = submit(C,Ns,Current,Fields),
        {Ref,Outcome} = created(C,Reply,Bytes,space),
        {entity_ref,Ns,_,Id} = Ref,
        {field,space_name,Suggested} = lists:keyfind(space_name,2,Fields),
        holds(Ns,{attribute,Id,name,Suggested}),
        holds(Ns,{attribute,Id,dimensions,default_dimensions()}),
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
        edit(Ns,{retract,{instance_of,space_class(),Id}}), Resolve()
    end) end}} || Lane <- [ordinary,atomic]].

non_space_binding_and_updates_test_() ->
    {timeout,90,fun() -> with_forms(fun(C=#{storage:=Ns}) ->
        [View] = views(C,Ns,subject(Ns,class_ref,note)),
        {Reply,Bytes} = submit(C,Ns,View,[{field,note_name,<<"Original">>}]),
        {Ref,_} = created(C,Reply,Bytes,note),
        {entity_ref,_,_,Id} = Ref,
        fails(Ns,{entity_eidolons,Id,{operation,class},{'_'},[{'_'}|{'_'}]}),
        [Rename] = views(C,Ns,Ref),
        {Updated,_} = submit(C,Ns,Rename,[{field,note_name,<<"Changed">>}]),
        wait(Updated),
        [Next] = views(C,Ns,Ref), ?assertNotEqual(element(4,Rename),element(4,Next)),
        ?assertEqual([{field,note_name,<<"Changed">>}],element(7,Next)),
        {Stale,_} = submit(C,Ns,Rename,[{field,note_name,<<"Stale">>}]),
        ?assertMatch({ok,_,{normalized,{failed,_}}},Stale),
        ?assertEqual([],views(C,Ns,setelement(3,Ref,<<0:256>>)))
    end) end}.

retained_operation_views_update_and_revoke_test_() ->
    {timeout,90,fun() -> with_forms(fun(C=#{namespace:=Ns,human_pair:={Key,_}}) ->
        [Create] = views(C,Ns,subject(Ns,class_ref,note)),
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
            [Rename] = views(C,Ns,Ref),
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
    Sources = source("gui_instance.pl") ++
        quod_prolog:read_terms("test/fixtures/note-operations.pl"),
    quod_space_creation_tests:with_spaces(fun(C=#{identity:=Node,directory:=Dir}) ->
        Gui = <<"quod:gui">>,
        Sup = quod_agent_hosting_tests:start_ontology(Gui,Dir,Node,[],quod_ct:gui_terms()),
        try
            [edit(Ns,{assertz,{gui_vocabulary,Gui,quod_simplex:genesis_hash(Gui)}})
                || Ns <- [maps:get(namespace,C),maps:get(storage,C),maps:get(destination,C),<<"quod:space">>]],
            Fun(C)
        after quod_agent_hosting_tests:stop_ontology(Sup) end
    end,Sources).

replace_placement_options(Ns,Options) ->
    edit(<<"quod:space">>,{retract,{':-',
        {attribute,{space_placement,{'_'}},options,{'_'}},{'_'}}}),
    edit(<<"quod:space">>,{assertz,{attribute,placement_field(Ns),options,Options}}).
placement_field(Ns) -> {space_placement,{ontology_ref,Ns,quod_simplex:genesis_hash(Ns)}}.
space_class() -> {':',quod,{':',space,space}}.
space(Goal) -> {'::',<<"quod:space">>,Goal}.
source(File) ->
    case File of
        "gui_measure.pl" -> quod_ct:gui_terms();
        "gui_scene.pl" -> quod_ct:gui_terms();
        "gui_tools.pl" -> quod_ct:gui_terms();
        "quod_gui.pl" -> quod_ct:gui_terms();
        _ -> quod_prolog:read_terms(filename:join(code:priv_dir(quod),"ontologies/"++File))
    end.
subject(Ns,Kind,Id) -> {Kind,Ns,quod_simplex:genesis_hash(Ns),Id}.
views(C,Ns,Subject) ->
    read(C,{'::',Ns,{gui_operations,Subject,{'Views'}}}).
read(C,Goal) ->
    {Bytes,Signature} = quod_personal_agent_tests:request(C,read,Goal),
    read_result(quod_client_goal_ingress:submit(Bytes,Signature)).
read_result({ok,_,{normalized,{read,_,{failed,_}}}}) -> [];
read_result({ok,_,{normalized,{read,_,{answers,_,[Blob]}}}}) ->
    {ok,Bindings} = quod_client_result:decode_binding(Blob),
    [Value] = [V || {_,V} <- Bindings, not (is_tuple(V) andalso tuple_size(V)=:=1)], Value.
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
    Lookup = quod_personal_agent_tests:request(C,read,{'::',<<"quod:user">>,{personal_instruction_lookup,Id,{'Bytes'},{'Signature'}}}),
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
