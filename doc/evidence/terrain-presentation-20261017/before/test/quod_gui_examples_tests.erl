-module(quod_gui_examples_tests).
-include_lib("eunit/include/eunit.hrl").

%% Public opening, submission and automatic hosted completion use the real
%% signed owners. Only the browser native acknowledgement is a fixture.
lobby_and_nonphysical_component_forms_test_() ->
    {timeout, 120, fun examples/0}.

world_library_creation_names_ownership_and_entry_test_() ->
    {timeout,180,fun world_library/0}.

world_library() ->
    Dir = filename:join("/tmp","quod-world-library-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
    Ctx = quod_lobby_tests:start(Dir,[],extended_system_catalogue,[]),
    {ontology_ref,Lobby,_} = maps:get(lobby,Ctx),
    {_,Base} = maps:get(Lobby,maps:get(ontologies,Ctx)),
    {HumanNs,HumanAnchor} = maps:get(agent,Ctx),Instance = {human_user,test_agent},
    Human = {agent_instance_ref,HumanNs,HumanAnchor,Instance},
    try with_responder(Ctx,Base,Human,fun({agent_instance_ref,ResponderNs,_,_}) ->
        {ok,[#{<<"V0">> := Node}],_} = read(Ctx,ResponderNs,{agent_hosted,responder,{0},{'_'},{'_'}}),
        Ns = <<"gui:world-library">>,
        Facts = [{lobby_owner,Human},{physics_initial_host,personal_lobby,Node},
            {gui_vocabulary,<<"quod:gui">>,quod_simplex:genesis_hash(<<"quod:gui">>)},
            {names_vocabulary,<<"quod:names">>,quod_simplex:genesis_hash(<<"quod:names">>)},
            {lobby_vocabulary,<<"lobby-test-classes">>,quod_simplex:genesis_hash(<<"lobby-test-classes">>)},
            {rendering_vocabulary,<<"lobby-test-rendering">>,quod_simplex:genesis_hash(<<"lobby-test-rendering">>)},
            {modelling_vocabulary,<<"lobby-test-modelling">>,quod_simplex:genesis_hash(<<"lobby-test-modelling">>)}],
        Files = ["space.pl","agent_instance.pl","quod_physics.pl","space_view.pl","lobby_instance.pl",
                 "voxel_world.pl","voxel_world_view.pl","gui_instance.pl","gui_question.pl",
                 "voxel_world_gui.pl","lobby_worlds.pl"],
        {Application,WorldConfig} = quod_lobby_tests:start_namespace(Ns,Base#{
            data_dir => filename:join(Dir,"worlds"),
            genesis_diff => quod_prolog:terms_to_diff(lists:append([source(F) || F <- Files]) ++ Facts)}),
        Anchor = quod_simplex:genesis_hash(Ns),Actor = {agent_instance_ref,Ns,Anchor,world_responder},
        true = quod_reg:subscribe({agent,Actor}),true = quod_reg:subscribe({agent_hosting,Ns}),
        true = quod_reg:subscribe({physics,Ns}),
        try
            commit(Ctx,scope(HumanNs,assertions(source("gui_hud.pl") ++
                [{instance_of,human_user,Instance},{gui_pending_allowance,Instance,8}]))),
            ?assertMatch({ok,[#{<<"V0">> := []}],_},read(Ctx,Ns,{world_library,{0}})),
            ?assertMatch({ok,[#{<<"V0">> := setup_required}],_},read(Ctx,Ns,{world_library_status,{0}})),
            ?assertMatch({fail,_},read(Ctx#{instance => <<"human_user(other_agent).">>},Ns,{world_library,{0}})),
            ?assertMatch({ok,_,{normalized,{failed,_}}},quod_lobby_tests:submit(Ctx,execute,
                scope(Ns,{world_creation_entered,<<"Forged">>,{recipe,meadow,1947,1000,bounded,32,128,100,15}}))),
            {ok,[#{<<"V0">> := {prepared,Node,Key}}],_} = read(Ctx,Ns,{world_library_preparation,{0}}),
            commit(Ctx,scope(Ns,{world_library_initialize,Node,Key})),
            receive {agent_installed,_,_,#{reference := Actor},_} -> ok
            after 10000 -> error(world_responder_not_installed) end,
            NamesTarget = {ontology_ref,<<"quod:names">>,quod_simplex:genesis_hash(<<"quod:names">>)},
            NamesBefore = quod_lobby_tests:complete_source(Ctx,NamesTarget),
            quod_gui_question_tests:with_receiver(Ctx,HumanNs,fun(Open) ->
                Create = fun(Name,Preset) ->
                    Form = world_creation,
                    {ok,[#{<<"V0">> := Revision}],_} = read(Ctx,Ns,{gui_schema,Form,{0},{1}}),
                    {ok,[#{<<"V1">> := Defaults}],_} = read(Ctx,Ns,{gui_values,Form,{0},{1}}),
                    Named = lists:keyreplace(world_creation_name,2,Defaults,{field,world_creation_name,Name}),
                    Fields = lists:keyreplace({voxel_setting,world_creation,preset},2,Named,
                        {field,{voxel_setting,world_creation,preset},Preset}),
                    {question_ref,Ns,Anchor,Q} = Open(Ns,Form),
                    Before = quod_prolog:applied(Ns),
                    commit(Ctx,scope(Ns,{gui_submit,Q,Revision,create_world,Fields})),
                    receive {agent_request_finished,_,_,#{reference := Actor},_,Result} ->
                        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Result)
                    after 30000 -> error(world_creation_completion_missing) end,
                    ?assert(quod_prolog:applied(Ns) >= Before+2),
                    ?assertMatch({ok,[#{<<"V0">> := []}],_},read(Ctx,HumanNs,{gui_pending_questions,{0}})),
                    ?assertMatch({ok,_,{normalized,{failed,_}}},quod_lobby_tests:submit(Ctx,execute,
                        scope(Ns,{gui_submit,Q,Revision,create_world,Fields}))),
                    {ok,[#{<<"V0">> := Rows}],_} = read(Ctx,Ns,{world_library,{0}}),Rows
                end,
                [{world,{entity_ref,Ns,Anchor,W1},Generated}] = Create(<<>>,meadow),
                ?assert(is_binary(Generated)),
                ?assertMatch({ok,[_],_},read(Ctx,Ns,{gui_schema,{voxel_excavation,W1},{0},{1}})),
                {question_ref,Ns,Anchor,Tools} = Open(Ns,{voxel_excavation,W1}),
                commit(Ctx,scope(Ns,{gui_cancel,Tools})),
                ?assertMatch({ok,[_],_},read(Ctx,<<"quod:names">>,
                    {name,Generated,<<"landscape">>,<<"world">>,<<"neutral">>})),
                ?assertEqual(NamesBefore,quod_lobby_tests:complete_source(Ctx,NamesTarget)),
                Two = Create(Generated,highlands),
                ?assertEqual([Generated,Generated],[Name || {world,_,Name} <- Two]),
                [W2] = [W || {world,{entity_ref,_,_,W},_} <- Two,W =/= W1],
                ?assertMatch({ok,[_],_},read(Ctx,Ns,{voxel_world_owner,W2,Human})),
                Worlds = Create(<<"Badlands">>,badlands),
                ?assertEqual(3,length(Worlds)),
                ?assertEqual(#{},gen_server:call(quod_reg:via({quod_runtime,Ns}),physics_worlds)),
                quod_lobby_tests:assert_read_has_no_io(fun() ->
                    ?assertEqual(read(Ctx,Ns,{world_library,{0}}),read(Ctx,Ns,{world_library,{0}}))
                end),
                Owners = [begin
                    {ok,[#{<<"V0">> := {prepared,Node,PhysicsKey}}],_} = read(Ctx,Ns,{physics_preparation,W,{0}}),
                    commit(Ctx,scope(Ns,{physics_initialize,W,Node,PhysicsKey})),
                    Owner = world_entry_ready({world_ref,Ns,Anchor,W},quod_time:mono_ms()+15000),
                    ?assertMatch(#{phase := active,navigation_ready := true},gen_server:call(Owner,status)),
                    %% Body IDs deliberately overlap; the exact world and pilot
                    %% remain distinct in control and presentation selection.
                    ?assertMatch({ok,[_],_},read(Ctx,Ns,{physics_control,W,Human,1,{controlled,{world_pilot,W},eye}})),
                    {ok,[#{<<"V0">> := {world_view,_,Visible,_}}],_} =
                        read(Ctx,Ns,{client_world_view,W,playing,[],{0}}),
                    ?assert(lists:any(fun({mark,_,<<"terrain">>,_,_,_,_,_}) -> true;
                                        (_) -> false end,Visible)),
                    {W,Owner}
                end || {world,{entity_ref,_,_,W},_} <- Worlds],
                World = {world_ref,Ns,Anchor,W1},
                {W1,Pid} = lists:keyfind(W1,1,Owners),
                ?assertMatch({ok,[#{<<"V0">> := ready}],_},read(Ctx,Ns,{physics_preparation,W1,{0}})),
                #{World := #{pid := Pid}} = gen_server:call(quod_reg:via({quod_runtime,Ns}),physics_worlds),
                %% Enter, release the visual consumer, then reenter a settled
                %% world with a larger view. Delivery cannot depend on motion.
                [?assertEqual(ok,world_terrain_delivery(Ns,World,Pid,Distance)) || Distance <- [8000,16000]],
                %% This recipe's wider window exceeds the authored renderer
                %% vertex allowance. Refuse the view promptly, keep the world
                %% alive, and permit a smaller view to enter again.
                ?assertEqual({error,<<"Terrain vertices: required 264522, allowance 250000. Reduce viewing distance.">>},
                    world_terrain_delivery(Ns,World,Pid,24000)),
                ?assertMatch(#{phase := active,navigation_ready := true},gen_server:call(Pid,status)),
                ?assertEqual(ok,world_terrain_delivery(Ns,World,Pid,16000)),
                ?assertMatch({ok,[#{<<"V0">> := Worlds}],_},read(Ctx,Ns,{world_library,{0}})),
                %% Rebuild from the same durable history, without redrawing
                %% names, replaying GUI completion or initializing again.
                quod_lobby_tests:stop_process(Application),
                {Recovered,_} = quod_lobby_tests:start_namespace(Ns,
                    WorldConfig#{mode => join,genesis_hash => Anchor}),
                try
                    ?assertEqual(Anchor,quod_simplex:genesis_hash(Ns)),
                    ?assertMatch({ok,[#{<<"V0">> := Worlds}],_},read(Ctx,Ns,{world_library,{0}})),
                    NewPid = world_entry_ready(World,quod_time:mono_ms()+15000),
                    ?assertNotEqual(Pid,NewPid),
                    ?assertMatch(#{phase := active,navigation_ready := true},gen_server:call(NewPid,status)),
                    ?assertMatch({ok,[#{<<"V0">> := ready}],_},read(Ctx,Ns,{physics_preparation,W1,{0}})),
                    ?assertEqual(NamesBefore,quod_lobby_tests:complete_source(Ctx,NamesTarget)),
                    quod_lobby_tests:assert_read_has_no_io(fun() ->
                        ?assertMatch({ok,[#{<<"V0">> := Worlds}],_},read(Ctx,Ns,{world_library,{0}}))
                    end)
                after quod_lobby_tests:stop_process(Recovered) end
            end)
        after
            quod_reg:unsubscribe({agent,Actor}),quod_reg:unsubscribe({agent_hosting,Ns}),
            quod_reg:unsubscribe({physics,Ns}),quod_lobby_tests:stop_process(Application)
        end
    end)
    catch Class:Reason:Stack -> io:format("World library fixture retained at ~s~n",[Dir]),erlang:raise(Class,Reason,Stack)
    after quod_lobby_tests:stop(Ctx) end,
    ok = file:del_dir_r(Dir).

world_entry_ready(World,Deadline) ->
    receive {physics_status,_,Pid,World,_,_} ->
        case is_process_alive(Pid) of
            false -> world_entry_ready(World,Deadline);
            true -> case gen_server:call(Pid,status) of
                #{phase := active,navigation_ready := true} -> Pid;
                #{phase := {failed,Reason}} -> error({world_entry_failed,Reason});
                _ -> world_entry_ready(World,Deadline)
            end
        end
    after max(0,Deadline-quod_time:mono_ms()) -> error(world_entry_not_ready) end.

world_terrain_delivery(Ns,World,Pid,Distance) ->
    Runtime = quod_reg:via({quod_runtime,Ns}),
    #{World := #{spec := Spec}} = gen_server:call(Runtime,physics_worlds),
    [{Id,Revision}] = [{B,R} || {B,R,fixed,_,{terrain,_,_},_} <- maps:get(bodies,Spec)],
    [Control] = maps:get(agent_controls,Spec),
    Expected = #{fence => quod_physics:fence(Spec),structure => maps:get(structure,Spec),
        incarnation => maps:get(run_token,Spec),control => Control,
        terrain => [{Id,Revision,{view_distance,Distance,4000,8000},
                     [8388608,16777216,250000,250000,1024]}]},
    {ok,Ref,Frame} = quod_physics:watch(Pid,Expected,none),
    try
        quod_physics:view_interest(Pid,Ref,1,{0,1535,2817}),
        quod_physics:ack(Pid,Ref,maps:get(tick,Frame),maps:get(origin_sequence,Frame)),
        consume_world_terrain(Runtime,World,Pid,Ref,none,quod_time:mono_ms()+15000)
    after quod_physics:unwatch(Pid,Ref),gen_server:call(Pid,status) end.

consume_world_terrain(Runtime,World,Pid,Ref,Current,Deadline) ->
    receive
        {physics_resource,Pid,Ref,{terrain_unavailable,Reason}} -> {error,Reason};
        {physics_refresh,Pid,Ref} -> error(terrain_projection_changed);
        {physics_resource,Pid,Ref,{terrain_manifest,Token,Interest,Rows}} ->
            quod_physics:resource_ack(Pid,Ref,Token,{want,[maps:get(index,R) || R <- Rows]}),
            consume_world_terrain(Runtime,World,Pid,Ref,{Token,Interest},Deadline);
        {physics_resource,Pid,Ref,{terrain_chunk,Token,Index,_}} ->
            quod_physics:resource_ack(Pid,Ref,Token,{chunk,Index}),
            consume_world_terrain(Runtime,World,Pid,Ref,Current,Deadline);
        {physics_resource,Pid,Ref,{terrain_complete,Token}} ->
            quod_physics:resource_ack(Pid,Ref,Token,complete),
            case Current of
                {Token,1} -> ok;
                _ -> consume_world_terrain(Runtime,World,Pid,Ref,Current,Deadline)
            end;
        {physics_frame,Pid,Ref,Frame} ->
            quod_physics:ack(Pid,Ref,maps:get(tick,Frame),maps:get(origin_sequence,Frame)),
            consume_world_terrain(Runtime,World,Pid,Ref,Current,Deadline)
    after max(0,Deadline-quod_time:mono_ms()) ->
        #{World := Entry} = gen_server:call(Runtime,physics_worlds),
        Spec = maps:get(spec,Entry),
        error({world_terrain_delivery_missing,gen_server:call(Pid,status),
               maps:with([terrain_demand,status,selection,needs_reconciliation],Entry),
               maps:with([terrain_demand],Spec),
               maps:with([runner_active,queue_len,resource_failures],gen_server:call(Runtime,get_stats))})
    end.

voxel_form_creates_user_owned_terrain_and_rejects_a_dig_stale_submission_test_() ->
    {timeout,120,fun() ->
        Dir = filename:join("/tmp","quod-voxel-gui-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
        Ctx = quod_lobby_tests:start(Dir,[],base_system_catalogue,[]),
        {ontology_ref,Lobby,_} = maps:get(lobby,Ctx),
        {_,Base} = maps:get(Lobby,maps:get(ontologies,Ctx)),
        {HumanNs,HumanAnchor} = maps:get(agent,Ctx), Instance = {human_user,test_agent},
        Human = {agent_instance_ref,HumanNs,HumanAnchor,Instance},
        try with_responder(Ctx,Base,Human,fun(Actor = {agent_instance_ref,ResponderNs,_,_}) ->
            Ns = <<"gui:voxel-world">>, Form = {voxel_generation,land},
            Facts = [{can_invoke,{'_'},Human,{'_'},Ns},{instance_of,voxel_world,land},
                {gui_question_policy,Form,Human,Actor},
                {gui_question_policy,{voxel_excavation,land},Human,Actor},
                {gui_question_policy,{voxel_view_settings,land},Human,Actor},
                {can_create_voxel_world,land,Actor},{can_manage_voxel_world,land,Actor,{'_'}},
                {can_edit_voxel_world,land,Human,{'_'}},
                {can_edit_voxel_world,land,Actor,{'_'}},
                {gui_vocabulary,<<"quod:gui">>,quod_simplex:genesis_hash(<<"quod:gui">>)},
                {rendering_vocabulary,<<"lobby-test-rendering">>,quod_simplex:genesis_hash(<<"lobby-test-rendering">>)},
                {modelling_vocabulary,<<"lobby-test-modelling">>,quod_simplex:genesis_hash(<<"lobby-test-modelling">>)},
                {voxel_presentation,land,<<"land">>,
                    [{material,I,{surface,<<"#887755">>,0,900,0,[]}} || I <- lists:seq(1,6)],
                    {view_distance,8000,4000,4000},{resources,1000000,2000000,20000,10000,64}},
                {voxel_view_range,land,{range,4,32,4}},
                {voxel_brush_controls,land,{range,-64000,64000,100},{range,600,2000,100}},
                {voxel_initial_chunks,land,{'_'},[{chunk_v1,0,0,0}]},
                {voxel_allowances,land,{voxel_limits,{sampling_limits,1331,20000,100000,3993},
                    {surface_limits,512,10000,10000},64,69120,1048576}},
                {physics_structure,land,1},{physics_next_body,land,0},
                {physics_allowances,land,{limits,8,8,128,1000000,{geometry,128,100000,100000}},16667,-9810,10000}],
            Terms = lists:append([source(F) || F <- ["space.pl","quod_physics.pl","voxel_world.pl",
                "space_view.pl","voxel_world_view.pl","gui_instance.pl","voxel_world_gui.pl"]]) ++ Facts,
            {Application,_} = quod_lobby_tests:start_namespace(Ns,Base#{data_dir => filename:join(Dir,"terrain"),
                genesis_diff => quod_prolog:terms_to_diff(Terms)}),
            try
                commit(Ctx,scope(HumanNs,assertions(source("gui_hud.pl") ++
                    [{instance_of,human_user,Instance},{gui_pending_allowance,Instance,4}]))),
                lists:foreach(fun(F) -> commit(Ctx,scope(ResponderNs,{assertz,{gui_responder_policy,responder,
                    {form_ref,Ns,quod_simplex:genesis_hash(Ns),F},Human}})) end,
                    [Form,{voxel_excavation,land},{voxel_view_settings,land}]),
                {ok,[#{<<"V0">> := Revision,<<"V1">> := Tree}],_} = read(Ctx,Ns,{gui_schema,Form,{0},{1}}),
                ?assertEqual([button,form,number_input,selection,slider],lists:usort(kinds(Tree))),
                {ok,[#{<<"V1">> := Fields}],_} = read(Ctx,Ns,{gui_values,Form,{0},{1}}),
                ?assertMatch({ok,[_],_},read(Ctx,Ns,{voxel_blueprint,meadow,1947,1000,128,100,15,{0}})),
                {ok,[#{<<"V0">> := Bound}],_} = read(Ctx,Ns,{gui_bind,Form,Revision,{generate_voxel,land},Fields,{0}}),
                ?assertEqual({voxel_generation_entered,land,0,[],meadow,1947,1000,bounded,32,128,100,15},Bound),
                quod_gui_question_tests:with_receiver(Ctx,HumanNs,fun(Open) ->
                    {question_ref,ResponderNs,_,Q} = Open(Ns,Form),
                    commit(Ctx,scope(ResponderNs,{gui_submit,Q,Revision,{generate_voxel,land},Fields})),
                    receive {agent_request_finished,_,_,#{reference := Actor},_,Completion} ->
                        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Completion)
                    after 10000 -> error(voxel_completion_missing) end,
                    ?assertMatch({ok,[_],_},read(Ctx,Ns,{voxel_world_owner,land,Human})),
                    ?assertMatch({ok,[_],_},read(Ctx,Ns,{voxel_world_definition,land,1,
                        {terrain_v1,{bounded,{chunk_v1,-4,-4,-4},{chunk_v1,4,4,4}},smooth,
                         {field_v1,1947,1000,{'_'},1}}})),
                    ?assertMatch({ok,[_],_},read(Ctx,Ns,{voxel_terrain_binding,land,0,2})),
                    ?assertMatch({ok,[#{<<"V0">> := []}],_},read(Ctx,HumanNs,{gui_pending_questions,{0}})),
                    {ok,[#{<<"V0">> := Scene}],_} = read(Ctx,Ns,{world_view,land,playing,{0}}),
                    ?assertMatch([{mark,<<"land">>,<<"group">>,_,_,_,_,_},
                        {mark,<<"land/ground">>,<<"terrain">>,_,{relative,<<"land">>,{body_pose,0,2}},
                         terrain_surfaces,unlabelled,{depicts,Ns,_,{terrain,land}}}],Scene),
                    SubmitForm = fun(F,Control,Values) ->
                        {ok,[#{<<"V0">> := R}],_} = read(Ctx,Ns,{gui_schema,F,{0},{1}}),
                        {question_ref,ResponderNs,_,Question} = Open(Ns,F),
                        commit(Ctx,scope(ResponderNs,{gui_submit,Question,R,Control,Values})),
                        receive {agent_request_finished,_,_,#{reference := Actor},_,Result} ->
                            ?assertMatch({ok,_,{normalized,{committed,_,_}}},Result)
                        after 10000 -> error(voxel_control_completion_missing) end
                    end,
                    SubmitForm({voxel_view_settings,land},{apply_voxel_view,land},
                               [{field,{voxel_distance,land},12}]),
                    ?assertMatch({ok,[_],_},read(Ctx,Ns,{voxel_presentation,land,{'_'},{'_'},
                        {view_distance,12000,4000,4000},{'_'}})),
                    ?assertMatch({ok,[_],_},read(Ctx,Ns,{voxel_terrain_binding,land,0,2})),
                    SubmitForm({voxel_excavation,land},{dig_voxel,land},
                        [{field,{voxel_brush,land,K},V} || {K,V} <- [{x,0},{y,0},{z,0},{radius,600}]]),
                    ?assertMatch({ok,[_],_},read(Ctx,Ns,{voxel_terrain_binding,land,0,3})),
                    {ok,[#{<<"V0">> := BeforeDig}],_} = read(Ctx,Ns,{gui_schema,Form,{0},{1}}),
                    {question_ref,ResponderNs,_,StaleQ} = Open(Ns,Form),
                    Brush = {dig_sphere,{vector,1000,0,0},600},
                    {ok,[#{<<"V0">> := Versions}],_} = read(Ctx,Ns,{voxel_edit_basis,land,Brush,1,{0}}),
                    commit(Ctx,scope(Ns,{voxel_edit,land,1,Versions,Brush})),
                    {ok,[#{<<"V0">> := AfterDig}],_} = read(Ctx,Ns,{gui_schema,Form,{0},{1}}),
                    ?assertNotEqual(BeforeDig,AfterDig),
                    ?assertMatch({ok,_,{normalized,{failed,_}}},quod_lobby_tests:submit(Ctx,execute,
                        scope(ResponderNs,{gui_submit,StaleQ,BeforeDig,{generate_voxel,land},Fields}))),
                    commit(Ctx,scope(ResponderNs,{gui_cancel,StaleQ}))
                end),
                quod_lobby_tests:assert_read_has_no_io(fun() ->
                    First = read(Ctx,Ns,{gui_schema,Form,{0},{1}}),
                    ?assertEqual(First,read(Ctx,Ns,{gui_schema,Form,{0},{1}}))
                end)
            after quod_lobby_tests:stop_process(Application) end
        end)
        catch Class:Reason:Stack ->
            io:format("Failed voxel GUI fixture retained at ~s~n",[Dir]),erlang:raise(Class,Reason,Stack)
        after quod_lobby_tests:stop(Ctx) end,
        ok = file:del_dir_r(Dir)
    end}.


examples() ->
    Dir = filename:join("/tmp", "quod-gui-examples-" ++
        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
    LobbyTerms = source("gui_instance.pl") ++ source("lobby_atmosphere.pl") ++
        [{attribute, personal_sky, preset_name, <<"Original">>},
         {atmosphere_panorama, belfast_sunset_puresky, <<"Belfast sunset">>},
         {atmosphere_panorama, dusk, <<"Dusk">>}],
    Ctx = quod_lobby_tests:start(Dir, [], base_system_catalogue, LobbyTerms),
    {ontology_ref, Lobby, _} = maps:get(lobby, Ctx),
    {_, Base} = maps:get(Lobby, maps:get(ontologies, Ctx)),
    {HumanNs, HumanAnchor} = maps:get(agent, Ctx),
    HumanInstance = {human_user, test_agent},
    Human = {agent_instance_ref, HumanNs, HumanAnchor, HumanInstance},
    Admin = {can_invoke, {'_'}, Human, {'_'}, {'_'}},
    try with_responder(Ctx,Base,Human,fun(Actor) ->
    {agent_instance_ref,ResponderNs,_,responder} = Actor,
    InstrumentNs = <<"gui:examples-instrument">>,
    Instrument = analyzer_a,
    Original = {instrument_configuration, Instrument, <<"Baseline">>, hold, 20, 0, false, [left], <<>>},
    {Application, _} = quod_lobby_tests:start_namespace(InstrumentNs, Base#{
        data_dir => filename:join(Dir, "instrument"),
        genesis_diff => quod_prolog:terms_to_diff(source("gui_instance.pl") ++
            source("instrument_configuration.pl") ++ [Admin, Original,
                {instance_of, instrument, Instrument},
                {gui_question_policy, {instrument_settings, Instrument}, Human, Actor},
                {gui_vocabulary, <<"quod:gui">>, quod_simplex:genesis_hash(<<"quod:gui">>)}])}),
    try
        LobbyFields = [{field, {preset, personal_sky}, <<"Evening">>},
            {field, {panorama, personal_sky}, dusk},
            {field, {brightness, personal_sky}, 650}, {field, {rotation, personal_sky}, 45}],
        InstrumentFields = [{field, {run_name, Instrument}, <<"Sweep A">>},
            {field, {mode, Instrument}, sweep}, {field, {gain, Instrument}, 40},
            {field, {phase, Instrument}, 90}, {field, {enabled, Instrument}, true},
            {field, {channels, Instrument}, [left, right]},
            {field, {notes, Instrument}, <<"Compare with baseline">>}],
        InstrumentState = {instrument_configuration, Instrument, <<"Sweep A">>, sweep,
            40, 90, true, [left, right], <<"Compare with baseline">>},
        Cases = [{Lobby, {atmosphere, personal_sky}, {apply_atmosphere, personal_sky}, LobbyFields},
                 {InstrumentNs, {instrument_settings, Instrument}, {apply_instrument, Instrument}, InstrumentFields},
                 {ResponderNs, {instrument_settings, Instrument}, {apply_instrument, Instrument}, InstrumentFields}],
        %% Before any transaction can leave asynchronous Complete work, measure
        %% unchanged signed reads through the actual retained schema owners.
        quod_lobby_tests:assert_read_has_no_io(fun() ->
            lists:foreach(fun({Ns, Form, _, _}) ->
                First = read(Ctx, Ns, {gui_schema, Form, {0}, {1}}),
                ?assertMatch({ok, [_], _}, First),
                ?assertEqual(First, read(Ctx, Ns, {gui_schema, Form, {0}, {1}}))
            end, Cases)
        end),
        commit(Ctx, scope(HumanNs, assertions(source("gui_hud.pl") ++
            [{instance_of, human_user, HumanInstance},{gui_pending_allowance,HumanInstance,4}]))),
        commit(Ctx, scope(Lobby, {assertz, {gui_question_policy, {atmosphere, personal_sky}, Human, Actor}})),
        commit(Ctx,scope(ResponderNs,{assertz,
            {gui_question_policy,{instrument_settings,Instrument},Human,Actor}})),
        lists:foreach(fun({Ns,Form,_,_}) ->
            commit(Ctx,scope(ResponderNs,{assertz,{gui_responder_policy,responder,
                {form_ref,Ns,quod_simplex:genesis_hash(Ns),Form},Human}}))
        end,Cases),
        quod_gui_question_tests:with_receiver(Ctx,HumanNs,fun(Open) ->
        lists:foreach(fun({Ns, Form, Control, Fields}) ->
            {ok, [#{<<"V0">> := Revision, <<"V1">> := Tree}], _} =
                read(Ctx, Ns, {gui_schema, Form, {0}, {1}}),
            ExpectedKinds = case Ns of Lobby -> [button, container, form, rotary_knob, selection, slider, text_box];
                _ -> [button, container, form, rotary_knob, selection, slider, table, tabs, text_area, text_box, toggle] end,
            ?assertEqual(ExpectedKinds,
                         lists:usort(kinds(Tree))),
            {ok, [#{<<"V1">> := Defaults}], _} = read(Ctx, Ns, {gui_values, Form, {0}, {1}}),
            ?assertEqual(length(Fields), length(Defaults)),
            %% Two distinct questions replace one domain state, never an
            %% accumulating answer log. Completion signs only retained bytes.
            lists:foreach(fun(Round) ->
                {question_ref,ResponderNs,_,Q} = Open(Ns,Form),
                Row = {gui_question, Q, {form_ref, Ns, quod_simplex:genesis_hash(Ns), Form},
                       Human, responder, Revision, awaiting},
                Submit = scope(ResponderNs, {gui_submit, Q, Revision, Control, Fields}),
                case {Ns, Round} of
                    {Lobby, 1} ->
                        Choice = {atmosphere_panorama, dusk, <<"Dusk">>},
                        commit(Ctx, scope(Lobby, {retract, Choice})),
                        ?assertMatch({ok, _, {normalized, {failed, _}}},
                            quod_lobby_tests:submit(Ctx, execute, Submit)),
                        ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs, Row)),
                        commit(Ctx, scope(Lobby, {assertz, Choice}));
                    _ -> ok
                end,
                commit(Ctx, Submit),
                receive
                    {agent_request_finished,_,_,#{reference := Actor},_,Completion} ->
                        {ok,#{request_bytes := CompletionBytes},{normalized,{committed,_,_}}} = Completion,
                        {ok,#{goal_text := CompletionText}} = quod_client_goal:decode(CompletionBytes),
                        {ok,ExpectedText} = quod_client_goal_parser:format({gui_complete,Q}),
                        ?assertEqual(quod_client_goal_parser:parse(ExpectedText,3),
                                     quod_client_goal_parser:parse(CompletionText,3))
                after 10000 -> error(example_completion_missing) end,
                ?assertMatch({fail, _}, read(Ctx, ResponderNs,
                    {gui_question, Q, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}})),
                ?assertMatch({ok, [#{<<"V0">> := []}], _},
                    read(Ctx, HumanNs, {gui_pending_questions, {0}})),
                ?assertMatch({ok, [#{<<"V1">> := Fields}], _},
                    read(Ctx, Ns, {gui_values, Form, {0}, {1}}))
            end, [1, 2])
        end, Cases) end),
        ?assertMatch({ok, [_], _}, read(Ctx, InstrumentNs, InstrumentState)),
        ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs, InstrumentState)),
        ?assertMatch({ok, [_], _}, read(Ctx, InstrumentNs,
            setelement(1, InstrumentState, current_instrument_configuration))),
        ?assertMatch({ok, [_], _}, read(Ctx, Lobby, {lobby_sky, personal_sky,
            {sky, personal_sky, dusk, 80000, 45, 650, <<"#FFFFFF">>}})),
        ?assertMatch({fail, _}, read(Ctx, InstrumentNs, {instance_of, space, {'_'}})),
        ?assertEqual(#{}, gen_server:call(quod_reg:via({quod_runtime, InstrumentNs}), physics_worlds))
    after
        quod_lobby_tests:stop_process(Application)
    end
    end)
    catch Class:Reason:Stack ->
        io:format("Failed live GUI examples retained at ~s~n",[Dir]),
        erlang:raise(Class,Reason,Stack)
    after quod_lobby_tests:stop(Ctx) end,
    ok = file:del_dir_r(Dir).

with_responder(Ctx,Base,Human,Fun) ->
    Dir = maps:get(directory,Ctx), Pub = maps:get(node_id,Base),
    Saved = application:get_env(quod,node_actor_principal),
    Unlock = filename:join(Dir,"unlock"),
    ok = quod_file:write_atomic(Unlock,crypto:strong_rand_bytes(32),8#600),
    {ok,Vault} = quod_agent_vault:start_link(#{directory => filename:join(Dir,"keys"),unlock_file => Unlock}),
    NodeNs = <<"gui:examples-node">>,
    {NodeOwner,_} = quod_lobby_tests:start_namespace(NodeNs,Base#{
        data_dir => filename:join(Dir,"node"),
        genesis_diff => quod_prolog:terms_to_diff(source("node_execution.pl") ++
            [{node_ontology,NodeNs},{instance_of,node,physical_node},{agent_key,physical_node,Pub,active}])}),
    Node = {agent_instance_ref,NodeNs,quod_simplex:genesis_hash(NodeNs),physical_node},
    {ok,NodeBlob} = quod_wire_term:encode_canonical(Node),
    application:set_env(quod,node_actor_principal,{agent,NodeBlob}),
    Ns = <<"gui:examples-responder">>,
    true = quod_reg:subscribe({agent_hosting,Ns}),
    {Responder,_} = quod_lobby_tests:start_namespace(Ns,Base#{
        data_dir => filename:join(Dir,"responder"),
        external_predicate_modules => [quod_agent_predicates],
        genesis_diff => quod_prolog:terms_to_diff(source("agent_instance.pl") ++ source("gui_question.pl") ++
            source("gui_instance.pl") ++ source("instrument_configuration.pl") ++
            [{can_invoke,{'_'},Human,{'_'},Ns},
             {instance_of,instrument,analyzer_a},
             {instrument_configuration,analyzer_a,<<"Baseline">>,hold,20,0,false,[left],<<>>},
             {gui_vocabulary,<<"quod:gui">>,quod_simplex:genesis_hash(<<"quod:gui">>)},
             {can_assign_agent_host,Human,responder,none,0,Node,{'_'}},
             {gui_pending_allowance,responder,4},{gui_completion_allowance,responder,30000}])}),
    Actor = {agent_instance_ref,Ns,quod_simplex:genesis_hash(Ns),responder},
    true = quod_reg:subscribe({agent,Actor}),
    try
        {ok,ActorBlob} = quod_wire_term:encode_canonical(Actor),
        {ok,Key} = quod_agent_vault:prepare(ActorBlob,0),
        commit(Ctx,scope(Ns,{goal,{agent_hosted,responder,Node,1,Key}})),
        receive {agent_installed,_,_,#{reference := Actor},_} -> ok
        after 10000 -> error(example_responder_not_installed) end,
        Fun(Actor)
    after
        quod_reg:unsubscribe({agent,Actor}), quod_reg:unsubscribe({agent_hosting,Ns}),
        quod_lobby_tests:stop_process(Responder), quod_lobby_tests:stop_process(NodeOwner),
        gen_server:stop(Vault),
        case Saved of undefined -> application:unset_env(quod,node_actor_principal);
            {ok,Value} -> application:set_env(quod,node_actor_principal,Value) end
    end.

source(Name) -> quod_prolog:read_terms(filename:join(code:priv_dir(quod), "ontologies/" ++ Name)).
scope(Ns, Goal) -> {'::', Ns, {',', {current_ontology_identity, Ns, quod_simplex:genesis_hash(Ns)}, Goal}}.
read(Ctx, Ns, Goal) -> quod_lobby_tests:read(Ctx, scope(Ns, Goal)).
commit(Ctx, Goal) ->
    quod_gui_question_tests:commit(Ctx,Goal).
assertions(Terms) ->
    {Goals, _} = lists:mapfoldl(fun(Term, N) ->
        {Fresh, _, Next} = erlog_int:term_instance(Term, N), {{assertz, Fresh}, Next}
    end, 0, Terms), conjunction(Goals).
conjunction([Goal]) -> Goal;
conjunction(Goals) ->
    {Left, Right} = lists:split(length(Goals) div 2, Goals),
    {',', conjunction(Left), conjunction(Right)}.
kinds({component, _, Kind, _, Children}) -> [Kind | lists:append([kinds(C) || C <- Children])].
