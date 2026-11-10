-module(quod_space_creation_tests).
-include_lib("eunit/include/eunit.hrl").
-export([with_spaces/2, with_spaces/3, with_models/2]).

signed_empty_space_results_and_recovery_test_() ->
    [{atom_to_list(Lane), {timeout, 90, fun() -> with_spaces(fun(C) ->
        Ns = maps:get(namespace, C), Target = case Lane of ordinary -> Ns; _ -> maps:get(storage, C) end,
        Destination = ref(maps:get(destination, C), room),
        Inputs = case Lane of
            ordinary -> [];
            foreign -> [{attribute, name, <<"Workshop">>}, {attribute, dimensions, mixed_dimensions()}];
            atomic -> [{attribute, dimensions, infinite}]
        end,
        Placement = case Lane of atomic -> placement(Destination); _ -> near_agent end,
        {Bindings, Bytes, Outcome} = create(C, Target, Inputs, Placement),
        [Space = {entity_ref, Target, _, Id}, Name] = [V || {_, V} <- Bindings],
        ?assertEqual(26, byte_size(Id)),
        ?assertEqual(case Lane of foreign -> <<"Workshop">>; _ -> <<"Space">> end, Name),
        holds(Target, {attribute, Id, owner, maps:get(human, C)}),
        Dimensions = case Lane of ordinary -> default_dimensions(); foreign -> mixed_dimensions(); atomic -> infinite end,
        Saved = conj([{instance_of, space_class(), Id}, {attribute, Id, name, Name},
                      {attribute, Id, dimensions, Dimensions}]),
        holds(Target, Saved),
        fails(Target, {attribute, Id, placement, {'_'}}),
        case Lane of
            atomic ->
                assignment(C, Target, Id, 1, Destination),
                holds(maps:get(destination, C), {space_placement, room, Space, 1});
            _ -> assignment(C, Target, Id, 0, none)
        end,
        empty_resources(C, Target, Id),
        %% No received reference or browser journal is used by the fresh device.
        Device = C#{session => quod_personal_agent_tests:session(maps:get(human_pair, C))},
        Resolve = fun() -> ?assertMatch({ok, _, {operation_outcome, _, Outcome}},
                                       quod_personal_agent_tests:lookup(Device, Bytes)) end,
        Reads = case Lane of ordinary -> 3; foreign -> 9; atomic -> 0 end,
        Owners = lists:usort([Ns, Target, maps:get(destination, C)]),
        quod_outcome_result_tests:assert_unchanged_reads(Owners, Resolve, Reads),
        quod_outcome_result_tests:assert_no_generation(fun() ->
            [quod_outcome_result_tests:restart_outcome_owner(O) || O <- Owners]
        end),
        holds(Target, Saved), Resolve(),
        %% Current membership is not the creation receipt.
        edit(Target, {retract, {instance_of, space_class(), Id}}),
        Resolve(),
        quod_outcome_result_tests:assert_unchanged_reads(Owners, Resolve, Reads)
    end) end}} || Lane <- [ordinary, foreign, atomic]].

explicit_and_near_agent_placement_test_() ->
    {timeout, 90, fun() -> with_spaces(fun(C = #{namespace := Ns, storage := Target,
                                               destination := Dest}) ->
        Room = ref(Dest, room), Local = ref(Ns, room),
        signed(C, inside(Room, ref(Ns,personal), {transform,200,300,400,0,45,0})),
        {Bindings, _, _} = create(C, Target, []),
        [{_, Space = {entity_ref, Target, _, Id}}, _] = Bindings,
        assignment(C, Target, Id, 1, Room),
        holds(Target, {attribute, Id, transform, {transform, 200,300,-51600,0,45,0}}),
        holds(Dest, {space_placement, room, Space, 1}),
        {Explicit, _, _} = create(C, Target, [], placement(Local)),
        [{_, ExplicitRef = {entity_ref, Target, _, ExplicitId}}, _] = Explicit,
        assignment(C, Target, ExplicitId, 1, Local),
        holds(Ns, {space_placement, room, ExplicitRef, 1}),
        fails(Dest, {space_placement, room, ExplicitRef, {'_'}}),
        %% Execute the complete existing scene/recipe/modelling/rendering path.
        with_models(C, fun() ->
            Marks = read(C, space({world_view,ref(Ns,room),playing,{'Marks'}})),
            ?assertMatch([{mark,_,<<"group">>,[],{transform,10,20,30,0,0,0},
                          no_surface,unlabelled,{depicts,Target,_,ExplicitId}},
                         {mark,_,<<"box">>,[{f,<<"width">>,500},{f,<<"height">>,500},
                            {f,<<"depth">>,500}],_,_,_,_}], Marks)
        end),
        %% Placement is one-time, not a subscription following A.
        edit(Ns, {retract, {attribute,personal,transform,{'_'}}}),
        holds(Target, {attribute, Id, transform, {transform,200,300,-51600,0,45,0}}),
        denied_creation(C, Target, []),
        create(C, Target, [], placement(Local))
    end) end}.

explicit_owner_and_class_defaults_test_() ->
    {timeout, 90, fun() -> with_spaces(fun(C = #{storage := Target, agent := Actor}) ->
        {Bindings, _, _} = create(C, Target, [{attribute, owner, Actor}]),
        [{_, {entity_ref, Target, _, Id}}, _] = Bindings,
        holds(Target, {attribute, Id, owner, Actor}),
        denied_creation(C, Target, [{attribute, owner, malformed}]),
        %% A plain local name is not an alias for the shared class.
        failed(signed_result(C, scoped(Target, {assert,{instance_of,space,{'Id'}}}))),
        fails(Target, {isa,space,space}),
        %% Constructor bodies are rejected at the real class owner.
        Body = {constructor,space,{'_'},[]},
        edit(<<"quod:space">>, {assertz,Body}),
        try denied_creation(C, Target, [])
        after edit(<<"quod:space">>, {retract,Body}) end
    end) end}.

invalid_dimensions_roll_back_through_signed_actor_test_() ->
    {timeout, 90, fun() -> with_spaces(fun(C = #{storage := Target}) ->
        Good = {q, 1, <<"m">>},
        Bad = [malformed, {box, Good, Good}, {box, 1, Good, Good},
            {box, {q,1,<<"kg">>}, Good, Good}, {box,{q,0,<<"m">>},Good,Good},
            {box,{q,-1,<<"m">>},Good,Good}, {box,{q,{'/',1,0},<<"m">>},Good,Good},
            {box,{q,{'/',-1,2},<<"m">>},Good,Good}, {box,{q,1.5,<<"m">>},Good,Good},
            {box,{q,1,<<"unknown">>},Good,Good}, {box,{q,1,metres},Good,Good}],
        [denied_creation(C, Target, [{attribute, dimensions, D}]) || D <- Bad],
        create(C, Target, [{attribute, dimensions, mixed_dimensions()}]),
        holds(maps:get(measure,C), {convert, {'/',1,3}, <<"ft">>, <<"m">>, {'/',127,1250}})
    end) end}.

authorization_and_lookup_failures_never_fall_back_test_() ->
    {timeout, 90, fun() -> with_spaces(fun(C = #{namespace := Ns, storage := Target,
                                               destination := Dest}) ->
        Room = ref(Dest, room),
        signed(C, inside(Room,ref(Ns,personal),{transform,0,0,0,0,0,0})),
        denied_creation(C, Target, [], placement(ref(Dest, closed))),
        [with_withheld(Operation, fun() ->
            denied_creation(C, Target, [], placement(Room))
         end) || Operation <- [create,space_enter,space_admit]],
        edit(Target, {retract,storage_open}),
        denied_creation(C, Target, [], placement(Room)),
        edit(Target, {assertz,storage_open}),
        Denial = {instance_permission,room,space_admit,deny},
        edit(Dest, {assertz,Denial}),
        %% A staged removal cannot bypass the committed destination ACL.
        failed(signed_result(C, {transaction,conj([
            scoped(Dest,{retract,Denial}),
            scoped(Target,creation_goal([],placement(Room)))])})),
        holds(Dest,Denial), edit(Dest,{retract,Denial}),
        Before = instances(Target),
        signed(C, scoped(Target, {';', creation_goal([],placement(ref(Dest,closed))),
                                      {assertz,refusal_observed}})),
        ?assertEqual(Before, instances(Target)), holds(Target, refusal_observed),
        AdmissionBefore = placements(Dest),
        signed(C, {';', {transaction,conj([scoped(Target,creation_goal([],placement(Room))),fail])},
                       {assertz,outer_refusal_observed}}),
        ?assertEqual(Before,instances(Target)),
        ?assertEqual(AdmissionBefore,placements(Dest)),
        %% Denied lookup is not absence; explicit placement avoids the lookup.
        [Grant = {':-',Head,Body}] = [T || T = {':-',
            {can_invoke,{'_'},{agent_instance_ref,{'Ns'},{'_'},personal},[{'Owner'}|{'_'}],{'Ns'}},_}
            <- quod_personal_agent_tests:user_terms()],
        Restricted = {':-',Head,setelement(3,Body,
            {member,{'Owner'},[<<"quod:gui">>,<<"quod:agent">>,<<"quod:user">>]})},
        edit(Ns,{',',{retract,Grant},{assertz,Restricted}}),
        try denied_creation(C,Target,[]), create(C,Target,[],placement(Room))
        after edit(Ns,{',',{retract,Restricted},{assertz,Grant}}) end,
        edit(Ns, {assertz, {space_assignment_state,personal,2,none}}),
        denied_creation(C, Target, []),
        edit(Ns, {retract, {space_assignment_state,personal,2,none}}),
        denied_creation(C, Target, [], placement(setelement(3,Room,<<0:256>>))),
        denied_creation(C, Target, [], placement(ref(Dest,absent)))
    end) end}.

existing_occupants_and_creation_commit_together_test_() ->
    [{atom_to_list(Lane), {timeout,90,fun() -> with_spaces(fun(C=#{namespace:=Ns,storage:=Target}) ->
        Occupant = case Lane of local -> ref(Target,resident); foreign -> ref(Ns,personal) end,
        Store = element(2,Occupant), Id = element(4,Occupant),
        Goal = conj([creation_goal([],unplaced),
                     inside({'Ref'},Occupant,{transform,0,0,0,0,0,0})]),
        Before = instances(Target),
        failed(signed_result(C,scoped(Target,{transaction,{',',Goal,fail}}))),
        ?assertEqual(Before,instances(Target)), assignment(C,Store,Id,0,none),
        ?assertEqual([],placements(Target)),
        %% Nonexistent participants and wrong histories leave no partial space.
        [begin
            BadGoal = conj([creation_goal([],unplaced),inside({'Ref'},Bad,{transform,0,0,0,0,0,0})]),
            failed(signed_result(C,scoped(Target,{transaction,BadGoal}))),
            ?assertEqual(Before,instances(Target))
         end || Bad <- [ref(Store,absent),setelement(3,Occupant,<<0:256>>)]],
        {ok,Evidence,{normalized,{committed,[Blob],_}}} = signed_result(C,scoped(Target,{transaction,Goal})),
        Op = quod_client_goal:operation_ref(Evidence),
        ?assertMatch(#{operation_state:=terminal},quod_ct:await_operation_complete(element(2,Op),Op,10000)),
        {ok,Bindings} = quod_client_result:decode_binding(Blob),
        [Space={entity_ref,Target,_,SpaceId}] = [R || {_,R={entity_ref,_,_,_}} <- Bindings],
        assignment(C,Store,Id,1,Space), holds(Target,{space_placement,SpaceId,Occupant,1}),
        %% Reaching the same desired state twice does not allocate another revision.
        Height = quod_prolog:applied(Target),
        ?assertMatch({ok,_,{normalized,{answers,_,_}}},
            signed_result(C,inside(Space,Occupant,{transform,0,0,0,0,0,0}))),
        ?assertEqual(Height,quod_prolog:applied(Target)), assignment(C,Store,Id,1,Space),
        empty_resources(C,Target,SpaceId,[Occupant])
    end,[{instance_of,{':',quod,{':',agent,agent}},resident}]) end}} || Lane <- [local,foreign]].

with_spaces(Fun) ->
    with_spaces(Fun, []).

with_spaces(Fun, Extra) ->
    with_spaces(Fun, Extra, source("quod_space.pl")).

with_spaces(Fun, Extra, SpaceSource) ->
    Sources = fixture() ++ Extra,
    quod_personal_agent_tests:with_personal(fun(C = #{namespace := Ns, agent := A, human := Human,
                                                    directory := Dir, identity := Node}) ->
        Measure = <<"creation-measure">>, Target = <<"creation-storage">>, Dest = <<"creation-destination">>,
        MSup = quod_agent_hosting_tests:start_ontology(Measure,Dir,Node,[],source("gui_measure.pl")),
        MeasureRef = {measure_vocabulary,Measure,quod_simplex:genesis_hash(Measure)},
        Owner = <<"quod:space">>,
        SSup = quod_agent_hosting_tests:start_ontology(Owner,Dir,Node,[],SpaceSource ++ [MeasureRef]),
        Pin = {space_vocabulary,Owner,quod_simplex:genesis_hash(Owner)},
        Terms = Sources ++ [Pin, storage_open,
            {':-', {can_invoke,{'_'},A,{'_'},{'_'}},storage_open},
            {':-', {can_invoke,{'_'},Human,{'_'},{'_'}},storage_open}],
        TSup = quod_agent_hosting_tests:start_ontology(Target,Dir,Node,[],Terms),
        DSup = quod_agent_hosting_tests:start_ontology(Dest,Dir,Node,[],Terms),
        edit(Ns, {assertz,Pin}),
        try Fun(C#{storage=>Target,destination=>Dest,measure=>Measure})
        after [quod_agent_hosting_tests:stop_ontology(S) || S <- [DSup,TSup,SSup,MSup]] end
    end, Sources).

source(File) ->
    case File of
        "gui_measure.pl" -> quod_ct:gui_terms();
        "gui_scene.pl" -> quod_ct:gui_terms();
        "gui_tools.pl" -> quod_ct:gui_terms();
        "quod_gui.pl" -> quod_ct:gui_terms();
        _ -> quod_prolog:read_terms(filename:join(code:priv_dir(quod),"ontologies/"++File))
    end.
fixture() -> quod_prolog:read_terms("test/fixtures/space-creation.pl").
ref(Ns, Entity) -> {entity_ref,Ns,quod_simplex:genesis_hash(Ns),Entity}.
placement(Ref) -> {at,Ref,{transform,10,20,30,0,0,0}}.
space_class() -> {':',quod,{':',space,space}}.
space(Goal) -> {'::',<<"quod:space">>,Goal}.
inside(Destination,Entity,Pose) -> space({goal,{inside,Destination,Entity,Pose}}).
default_dimensions() -> {box,{q,100,<<"m">>},{q,100,<<"m">>},{q,100,<<"m">>}}.
mixed_dimensions() -> {box,{q,{'/',1,3},<<"ft">>},{q,200,<<"cm">>},{q,3,<<"km">>}}.
creation_goal(Inputs,Placement) ->
    {creation_result,Inputs,Placement,{'Ref'},{'Name'}}.
at_target(#{namespace := Ns}, Ns, Goal) ->
    {',',{current_ontology_identity,Ns,quod_simplex:genesis_hash(Ns)},Goal};
at_target(_, Ns, Goal) -> scoped(Ns, Goal).
scoped(Ns, Goal) -> {'::',Ns,{',',{current_ontology_identity,Ns,quod_simplex:genesis_hash(Ns)},Goal}}.

create(C, Target, Inputs) -> create(C, Target, Inputs, near_agent).
create(C, Target, Inputs, Placement) ->
    quod_personal_agent_tests:await_runtime_ready(maps:get(namespace,C)),
    %% Anonymous locals leave only the anchored reference and name as outputs.
    Goal = at_target(C, Target, creation_goal(Inputs,Placement)),
    %% The fixture helper is authored Prolog composition, not another executor.
    {Instruction, Bytes} = quod_personal_agent_tests:instruction(C,Goal),
    Reply = quod_personal_agent_tests:instruct(C,submit,Instruction),
    case Reply of
        {ok,_,{normalized,{failed,Reasons}}} ->
            {ok,Decoded} = quod_wire_term:decode_failure_reasons(Reasons),
            error({creation_refused,Decoded});
        _ -> ok
    end,
    {ok, Evidence, {normalized,{committed,[Binding],_}}} = Reply,
    Operation = quod_client_goal:operation_ref(Evidence),
    ?assertMatch(#{operation_state:=terminal},
        quod_ct:await_operation_complete(element(2,Operation),Operation,10000)),
    {ok, Bindings} = quod_client_result:decode_binding(Binding),
    {ok, #{request := #{operation_id := OperationId}}} = quod_client_goal:request_identity(Bytes),
    Lookup = quod_personal_agent_tests:request(C,read,
        {'::',<<"quod:user">>,{personal_instruction_lookup,OperationId,{'Bytes'},{'Signature'}}}),
    Ns = maps:get(namespace,C), true = quod_reg:subscribe({runtime,Ns}),
    {ok, _, {operation_outcome,_,Outcome}} = try
        quod_personal_agent_tests:await_result(C,Lookup,quod_time:mono_ms()+10000)
    after quod_reg:unsubscribe({runtime,Ns}) end,
    ?assertEqual(Bindings,maps:get(bindings,Outcome)),
    {Bindings,Bytes,Outcome}.

signed_result(C,Goal) ->
    %% A reply precedes release of the attempt-now slot and reaction processing.
    %% Wait for the real owner before a new, independent fixture instruction.
    quod_personal_agent_tests:await_runtime_ready(maps:get(namespace,C)),
    {Instruction,_} = quod_personal_agent_tests:instruction(C,Goal),
    quod_personal_agent_tests:instruct(C,submit,Instruction).
signed(C,Goal) ->
    Result = signed_result(C,Goal),
    case Result of {ok,_,{normalized,{failed,Reasons}}}->
        {ok,Decoded}=quod_wire_term:decode_failure_reasons(Reasons),
        io:format("Creation fixture refusal: ~tp~n",[Decoded]); _->ok end,
    ?assertMatch({ok,_,{normalized,{committed,_,_}}},Result),
    {ok,Evidence,_} = Result,
    Op = quod_client_goal:operation_ref(Evidence),
    ?assertMatch(#{operation_state:=terminal},quod_ct:await_operation_complete(element(2,Op),Op,10000)).
failed(R) -> ?assertMatch({ok,_,{normalized,{failed,_}}},R).
denied_creation(C,Target,Inputs) -> denied_creation(C,Target,Inputs,near_agent).
denied_creation(C,Target,Inputs,Placement) ->
    Before = instances(Target),
    failed(signed_result(C,at_target(C,Target,creation_goal(Inputs,Placement)))),
    ?assertEqual(Before,instances(Target)).
instances(Ns) ->
    {ok,[#{'Rows':=Rows}],_} = quod_prolog:prove_ro(Ns,{findall,{'I'},{instance_of,space_class(),{'I'}},{'Rows'}}), Rows.
placements(Ns) ->
    {ok,[#{'Rows':=Rows}],_} = quod_prolog:prove_ro(Ns,
        {findall,{placement,{'S'},{'I'},{'R'}},{space_placement,{'S'},{'I'},{'R'}},{'Rows'}}), Rows.
holds(Ns,Goal) -> ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,Goal)).
fails(Ns,Goal) -> ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,Goal)).
edit(Ns,Goal) ->
    case quod_prolog:execute(Ns,Goal) of
        {ok,_,_} -> ok; Other -> error({fixture_edit_failed,Ns,Goal,Other})
    end.
conj([G]) -> G;
conj([G|Rest]) -> {',',G,conj(Rest)}.
empty_resources(C,Target,Id) -> empty_resources(C,Target,Id,[]).
empty_resources(C,Target,Id,ExpectedContents) ->
    Contents = read(C,{findall,{'E'},space({space_contains,ref(Target,Id),{'E'}}),{'Contents'}}),
    ?assertEqual(lists:sort(ExpectedContents),lists:sort(Contents)),
    [fails(Target,G) || G <- [{instance_of,physical_space,Id},
        {instance_of,voxel_world,Id},{instance_of,sky_sphere,{'_'}},{physics_space,Id,{'_'},{'_'}},
        {physics_body_definition,Id,{'_'},{'_'},{'_'},{'_'},{'_'}},{voxel_world,{'_'}}]],
    [begin
        quod_space_tests:await_runtime(Ns),
        ok = quod_runtime:reconcile_resource(Ns,quod_prolog:applied(Ns),physics_worlds,
                                             all,quod_time:mono_ms()+10000),
        ?assertEqual(#{},gen_server:call(quod_reg:via({quod_runtime,Ns}),physics_worlds))
    end || Ns <- lists:usort([Target,maps:get(namespace,C),maps:get(destination,C)])].

with_models(#{namespace := Ns, directory := Dir, identity := Node}, Fun) ->
    Render = <<"creation-rendering">>, Model = <<"creation-modelling">>,
    RSup = quod_agent_hosting_tests:start_ontology(Render,Dir,Node,[],source("gui_scene.pl")),
    MSup = quod_agent_hosting_tests:start_ontology(Model,Dir,Node,[],source("gui_scene.pl") ++
        [{rendering_vocabulary,Render,quod_simplex:genesis_hash(Render)}]),
    [edit(Store,{assertz,{modelling_vocabulary,Model,quod_simplex:genesis_hash(Model)}})
        || Store <- [Ns,<<"quod:space">>]],
    try Fun()
    after [quod_agent_hosting_tests:stop_ontology(S) || S <- [MSup,RSup]] end.

atomic_completion_wait_includes_complete_record_test_() ->
    {timeout, 30, fun() -> with_spaces(fun(C = #{namespace := Ns, destination := Dest}) ->
        Parent = self(),
        Trace = trace:session_create(atomic_completion_wait, Parent, []),
        Previous = application:get_env(quod, dtx_test_phase_barrier),
        trace:process(Trace, quod_reg:where({quod_simplex, Ns}), true, [call, set_on_spawn]),
        trace:function(Trace, {application, set_env, 3}, true, []),
        {module, quod_ct} = code:ensure_loaded(quod_ct),
        1 = trace:function(Trace, {quod_ct, await_applied_event, 5}, true, [local]),
        application:set_env(quod, dtx_test_phase_barrier, {hold, terminal}),
        try
            {ok, Evidence, {normalized, {committed, _, _}}} = signed_result(C,
                inside(ref(Dest,room),ref(Ns,personal),{transform,0,0,0,0,0,0})),
            Op = quod_client_goal:operation_ref(Evidence),
            {Coordinator, Barrier} = receive
                {trace, Pid, call, {application, set_env,
                    [quod, dtx_test_phase_barrier, {held, _, terminal, Ref}]}} -> {Pid, Ref}
            after 5000 -> error(complete_barrier_not_reached) end,
            try
                {ok, #{operation_state := terminal, outcome_ref := Group}} = quod_prolog:outcome(Op),
                ?assertMatch({ok, #{status := pending}}, quod_prolog:outcome(Group)),
                {Waiter, Monitor} = spawn_monitor(fun() ->
                    receive start -> ok end,
                    Result = quod_ct:await_operation_complete(Ns, Op, 10000),
                    Parent ! {atomic_wait_result, self(), Result}
                end),
                trace:process(Trace, Waiter, true, [call]), Waiter ! start,
                try
                    %% Observe the helper's actual pending wait, not a timed pause.
                    receive
                        {trace, Waiter, call, {quod_ct, await_applied_event, _}} -> ok;
                        {atomic_wait_result, Waiter, _} -> error(completed_before_group_complete)
                    after 5000 -> error(completion_wait_not_observed) end,
                    ?assertMatch({ok, #{status := pending}}, quod_prolog:outcome(Group)),
                    Coordinator ! {quod_dtx_test_release, Barrier},
                    receive {atomic_wait_result, Waiter, Row} ->
                        ?assertMatch(#{operation_state := terminal, ref := Op}, Row)
                    after 5000 -> error(complete_did_not_release_waiter) end,
                    ?assertMatch({ok, #{status := committed}}, quod_prolog:outcome(Group)),
                    quod_personal_agent_tests:await_runtime_ready(Ns),
                    denied_creation(C, maps:get(storage, C), [], placement(ref(Dest, closed)))
                after
                    exit(Waiter, kill), demonitor(Monitor, [flush])
                end
            after Coordinator ! {quod_dtx_test_release, Barrier} end
        after
            trace:session_destroy(Trace),
            case Previous of undefined -> application:unset_env(quod, dtx_test_phase_barrier);
                             {ok, Old} -> application:set_env(quod, dtx_test_phase_barrier, Old) end
        end
    end) end}.

assignment(C,Ns,Id,Revision,Destination) ->
    ?assertEqual(true,read(C,{',',space({space_assignment,ref(Ns,Id),Revision,Destination}),{'=',{'Result'},true}})).

read(C,Goal) ->
    {Bytes,Signature} = quod_personal_agent_tests:request(C,read,Goal),
    {ok,_,{normalized,{read,_,{answers,_,[Blob]}}}} =
        quod_client_goal_ingress:submit(Bytes,Signature),
    {ok,Bindings} = quod_client_result:decode_binding(Blob),
    %% findall leaves its generator variable unbound; select the bound answer.
    [Value] = [V || {_,V} <- Bindings, not (is_tuple(V) andalso tuple_size(V)=:=1)], Value.

with_withheld(Operation,Fun) ->
    [Default={':-',Head,Body}] = [T || T={':-',{class_permission,space,_,allow},_} <- source("quod_space.pl")],
    Withheld = {':-',Head,{',',Body,{'\\=',element(3,Head),Operation}}},
    edit(<<"quod:space">>,{',',{retract,Default},{assertz,Withheld}}),
    try Fun()
    after edit(<<"quod:space">>,{',',{retract,Withheld},{assertz,Default}}) end.
