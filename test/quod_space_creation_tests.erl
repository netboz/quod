-module(quod_space_creation_tests).
-include_lib("eunit/include/eunit.hrl").

signed_empty_space_results_and_recovery_test_() ->
    [{atom_to_list(Lane), {timeout, 90, fun() -> with_spaces(fun(C) ->
        Ns = maps:get(namespace, C), Target = case Lane of ordinary -> Ns; _ -> maps:get(storage, C) end,
        Destination = ref(maps:get(destination, C), room),
        Inputs = case Lane of
            ordinary -> [];
            foreign -> [{attribute, name, <<"Workshop">>}, {attribute, dimensions, mixed_dimensions()}];
            atomic -> [{attribute, dimensions, infinite}, placement(Destination)]
        end,
        {Bindings, Bytes, Outcome} = create(C, Target, Inputs),
        [Space = {entity_ref, Target, _, Id}, Name] = [V || {_, V} <- Bindings],
        ?assertEqual(26, byte_size(Id)),
        ?assertEqual(case Lane of foreign -> <<"Workshop">>; _ -> <<"Space">> end, Name),
        holds(Target, {attribute, Id, owner, maps:get(human, C)}),
        Dimensions = case Lane of ordinary -> default_dimensions(); foreign -> mixed_dimensions(); atomic -> infinite end,
        Saved = conj([{instance_of, space, Id}, {attribute, Id, name, Name},
                      {attribute, Id, dimensions, Dimensions}]),
        holds(Target, Saved),
        fails(Target, {attribute, Id, placement, {'_'}}),
        case Lane of
            atomic ->
                holds(Target, {space_assignment, Id, 1, Destination}),
                holds(maps:get(destination, C), {space_placement, room, Space, 1});
            _ -> holds(Target, {space_assignment, Id, 0, none})
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
        edit(Target, {retract, {instance_of, space, Id}}),
        Resolve(),
        quod_outcome_result_tests:assert_unchanged_reads(Owners, Resolve, Reads)
    end) end}} || Lane <- [ordinary, foreign, atomic]].

explicit_and_near_agent_placement_test_() ->
    {timeout, 90, fun() -> with_spaces(fun(C = #{namespace := Ns, storage := Target,
                                               destination := Dest}) ->
        Room = ref(Dest, room), Local = ref(Ns, room),
        signed(C, conj([{space_place, personal, 0, Room},
                       {assertz, {attribute, personal, transform, {transform, 200,300,400,0,45,0}}}])),
        {Bindings, _, _} = create(C, Target, []),
        [{_, Space = {entity_ref, Target, _, Id}}, _] = Bindings,
        holds(Target, {space_assignment, Id, 1, Room}),
        holds(Target, {attribute, Id, transform, {transform, 1200,300,400,0,45,0}}),
        holds(Dest, {space_placement, room, Space, 1}),
        {Explicit, _, _} = create(C, Target, [placement(Local)]),
        [{_, ExplicitRef = {entity_ref, Target, _, ExplicitId}}, _] = Explicit,
        holds(Target, {space_assignment, ExplicitId, 1, Local}),
        holds(Ns, {space_placement, room, ExplicitRef, 1}),
        fails(Dest, {space_placement, room, ExplicitRef, {'_'}}),
        %% Execute the complete existing scene/recipe/modelling/rendering path.
        with_models(C, fun() ->
            {ok,_,{normalized,{committed,[Binding],_}}} = signed_result(C,
                conj([{world_view,room,playing,{'Marks'}},{assertz,projected}])),
            {ok,[{_,Marks}]} = quod_client_result:decode_binding(Binding),
            ?assertMatch([{mark,_,<<"group">>,[],{transform,10,20,30,0,0,0},
                          no_surface,unlabelled,{depicts,Target,_,ExplicitId}},
                         {mark,_,<<"box">>,[{f,<<"width">>,500},{f,<<"height">>,500},
                            {f,<<"depth">>,500}],_,_,_,_}], Marks)
        end),
        %% Placement is one-time, not a subscription following A.
        edit(Ns, {retract, {attribute,personal,transform,{'_'}}}),
        holds(Target, {attribute, Id, transform, {transform,1200,300,400,0,45,0}}),
        denied_creation(C, Target, []),
        create(C, Target, [placement(Local)])
    end) end}.

explicit_owner_obeys_committed_creation_policy_test_() ->
    {timeout, 90, fun() -> with_spaces(fun(C = #{storage := Target, agent := Actor}) ->
        Inputs = [{attribute, owner, Actor}],
        denied_creation(C, Target, Inputs),
        %% Proposed policy cannot authorize this operation's chosen owner.
        failed(signed_result(C, scoped(Target, conj([
            {assertz, {allowed_creation_owner, Actor}}, creation_goal(Inputs)])))),
        fails(Target, {allowed_creation_owner, Actor}),
        edit(Target, {assertz, {allowed_creation_owner, Actor}}),
        {Bindings, _, _} = create(C, Target, Inputs),
        [{_, {entity_ref, Target, _, Id}}, _] = Bindings,
        holds(Target, {attribute, Id, owner, Actor}),
        denied_creation(C, Target, [{attribute, owner, malformed}])
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
        signed(C, conj([{space_place,personal,0,Room},
                       {assertz,{attribute,personal,transform,{transform,0,0,0,0,0,0}}}])),
        denied_creation(C, Target, [placement(ref(Dest, closed))]),
        lists:foreach(fun({Owner, Flag}) ->
            edit(Owner, {retract, Flag}),
            denied_creation(C, Target, [placement(Room)]),
            edit(Owner, {assertz, Flag})
        end, [{Target,creation_enabled}, {Target,creation_requirement_enabled},
              {Target,entry_enabled}, {Target,storage_open}, {Dest,admission_enabled}]),
        %% Staging a permission does not replace committed class policy.
        edit(Target, {retract, entry_enabled}),
        Goal = scoped(Target, conj([{assertz,entry_enabled}, creation_goal([placement(Room)])])),
        failed(signed_result(C, Goal)),
        fails(Target, entry_enabled), edit(Target, {assertz, entry_enabled}),
        %% Even caught refusal restores creation and both placement participants.
        Before = instances(Target),
        signed(C, scoped(Target, {';', creation_goal([placement(ref(Dest,closed))]),
                                      {assertz,refusal_observed}})),
        ?assertEqual(Before, instances(Target)), holds(Target, refusal_observed),
        AdmissionBefore = placements(Dest),
        signed(C, {';', {transaction,conj([scoped(Target,creation_goal([placement(Room)])),fail])},
                       {assertz,outer_refusal_observed}}),
        ?assertEqual(Before,instances(Target)),
        ?assertEqual(AdmissionBefore,placements(Dest)),
        %% Denied lookup is not absence. An explicit destination avoids the lookup.
        edit(Ns, {retract, {personal_agent_query,{space_location,personal,{'_'}}}}),
        denied_creation(C, Target, []), create(C, Target, [placement(Room)]),
        edit(Ns, {assertz, {personal_agent_query,{space_location,personal,{'_'}}}}),
        edit(Ns, {assertz, {space_assignment_state,personal,2,none}}),
        denied_creation(C, Target, []),
        edit(Ns, {retract, {space_assignment_state,personal,2,none}}),
        %% Exact destination history is enforced before admission.
        denied_creation(C, Target, [placement(setelement(3,Room,<<0:256>>))]),
        denied_creation(C, Target, [placement(ref(Dest,absent))])
    end) end}.

with_spaces(Fun) ->
    Sources = source("space.pl") ++ source("space_view.pl") ++ fixture(),
    quod_personal_agent_tests:with_personal(fun(C = #{namespace := Ns, agent := A,
                                                    directory := Dir, identity := Node}) ->
        {ok, Foreign} = quod_foreign_log:start_link(#{cache_dir => filename:join(Dir,"foreign")}),
        Measure = <<"creation-measure">>, Target = <<"creation-storage">>, Dest = <<"creation-destination">>,
        MSup = quod_agent_hosting_tests:start_ontology(Measure,Dir,Node,[],source("quod_measure.pl")),
        MeasureRef = {measure_vocabulary,Measure,quod_simplex:genesis_hash(Measure)},
        Terms = Sources ++ [MeasureRef, {creation_actor,A}, storage_open,
            {':-', {can_invoke,{'_'},A,{'_'},{'_'}},storage_open}],
        TSup = quod_agent_hosting_tests:start_ontology(Target,Dir,Node,[],Terms),
        DSup = quod_agent_hosting_tests:start_ontology(Dest,Dir,Node,[],Terms),
        edit(Ns, conj([{assertz,MeasureRef},{assertz,{creation_actor,A}},
            {assertz,{can_invoke,{',',{current_ontology_identity,Ns,quod_simplex:genesis_hash(Ns)},
                {space_accept_placement,room,{'_'},{'_'}}}, A, {'_'}, Ns}},
            {assertz,{can_invoke,{',',{current_ontology_identity,Ns,quod_simplex:genesis_hash(Ns)},
                {space_assignment,{'_'},{'_'},{'_'}}}, A, {'_'}, Ns}}])),
        try Fun(C#{storage=>Target,destination=>Dest,measure=>Measure})
        after [quod_agent_hosting_tests:stop_ontology(S) || S <- [DSup,TSup,MSup]],
              gen_server:stop(Foreign) end
    end, Sources).

source(File) -> quod_prolog:read_terms(filename:join(code:priv_dir(quod),"ontologies/"++File)).
fixture() -> quod_prolog:read_terms("test/fixtures/space-creation.pl").
ref(Ns, Entity) -> {entity_ref,Ns,quod_simplex:genesis_hash(Ns),Entity}.
placement(Ref) -> {attribute,placement,{at,Ref,{transform,10,20,30,0,0,0}}}.
default_dimensions() -> {box,{q,100,<<"m">>},{q,100,<<"m">>},{q,100,<<"m">>}}.
mixed_dimensions() -> {box,{q,{'/',1,3},<<"ft">>},{q,200,<<"cm">>},{q,3,<<"km">>}}.
creation_goal(Inputs) ->
    conj([{with_build_plan,Inputs,{assert,{instance_of,space,{'Space'}}}},
          {current_ontology_identity,{'Ns'},{'Anchor'}},
          {'=',{'Ref'},{entity_ref,{'Ns'},{'Anchor'},{'Space'}}},
          {attribute,{'Space'},name,{'Name'}}]).
at_target(#{namespace := Ns}, Ns, Goal) ->
    {',',{current_ontology_identity,Ns,quod_simplex:genesis_hash(Ns)},Goal};
at_target(_, Ns, Goal) -> scoped(Ns, Goal).
scoped(Ns, Goal) -> {'::',Ns,{',',{current_ontology_identity,Ns,quod_simplex:genesis_hash(Ns)},Goal}}.

create(C, Target, Inputs) ->
    %% Anonymous locals leave only the anchored reference and name as outputs.
    Goal = at_target(C, Target, {creation_result, Inputs, {'Ref'}, {'Name'}}),
    %% The fixture helper is authored Prolog composition, not another executor.
    {Instruction, Bytes} = quod_personal_agent_tests:instruction(C,Goal),
    {ok, Evidence, {normalized,{committed,[Binding],_}}} =
        quod_personal_agent_tests:instruct(C,submit,Instruction),
    Operation = quod_client_goal:operation_ref(Evidence),
    ?assertMatch(#{operation_state:=terminal},
        quod_ct:await_operation_complete(element(2,Operation),Operation,10000)),
    {ok, Bindings} = quod_client_result:decode_binding(Binding),
    {ok, #{request := #{operation_id := OperationId}}} = quod_client_goal:request_identity(Bytes),
    Lookup = quod_personal_agent_tests:request(C,read,
        {personal_instruction_lookup,OperationId,{'Bytes'},{'Signature'}}),
    Ns = maps:get(namespace,C), true = quod_reg:subscribe({runtime,Ns}),
    {ok, _, {operation_outcome,_,Outcome}} = try
        quod_personal_agent_tests:await_result(C,Lookup,quod_time:mono_ms()+10000)
    after quod_reg:unsubscribe({runtime,Ns}) end,
    ?assertEqual(Bindings,maps:get(bindings,Outcome)),
    {Bindings,Bytes,Outcome}.

signed_result(C,Goal) ->
    {Instruction,_} = quod_personal_agent_tests:instruction(C,Goal),
    quod_personal_agent_tests:instruct(C,submit,Instruction).
signed(C,Goal) ->
    Result = signed_result(C,Goal),
    ?assertMatch({ok,_,{normalized,{committed,_,_}}},Result),
    {ok,Evidence,_} = Result,
    Op = quod_client_goal:operation_ref(Evidence),
    ?assertMatch(#{operation_state:=terminal},quod_ct:await_operation_complete(element(2,Op),Op,10000)).
failed(R) -> ?assertMatch({ok,_,{normalized,{failed,_}}},R).
denied_creation(C,Target,Inputs) ->
    Before = instances(Target),
    failed(signed_result(C,at_target(C,Target,creation_goal(Inputs)))),
    ?assertEqual(Before,instances(Target)).
instances(Ns) ->
    {ok,[#{'Rows':=Rows}],_} = quod_prolog:prove_ro(Ns,{findall,{'I'},{instance_of,space,{'I'}},{'Rows'}}), Rows.
placements(Ns) ->
    {ok,[#{'Rows':=Rows}],_} = quod_prolog:prove_ro(Ns,
        {findall,{placement,{'S'},{'I'},{'R'}},{space_placement,{'S'},{'I'},{'R'}},{'Rows'}}), Rows.
holds(Ns,Goal) -> ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,Goal)).
fails(Ns,Goal) -> ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,Goal)).
edit(Ns,Goal) -> ?assertMatch({ok,_,_},quod_prolog:execute(Ns,Goal)).
conj([G]) -> G;
conj([G|Rest]) -> {',',G,conj(Rest)}.
empty_resources(C,Target,Id) ->
    [fails(Target,G) || G <- [{space_contains,Id,{'_'}},{instance_of,physical_space,Id},
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
    RSup = quod_agent_hosting_tests:start_ontology(Render,Dir,Node,[],source("quod_rendering.pl")),
    MSup = quod_agent_hosting_tests:start_ontology(Model,Dir,Node,[],source("quod_modelling.pl") ++
        [{rendering_vocabulary,Render,quod_simplex:genesis_hash(Render)}]),
    edit(Ns,{assertz,{modelling_vocabulary,Model,quod_simplex:genesis_hash(Model)}}),
    try Fun()
    after [quod_agent_hosting_tests:stop_ontology(S) || S <- [MSup,RSup]] end.
