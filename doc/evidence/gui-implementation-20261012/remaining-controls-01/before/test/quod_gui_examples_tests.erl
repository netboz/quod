-module(quod_gui_examples_tests).
-include_lib("eunit/include/eunit.hrl").

%% Public opening, submission and automatic hosted completion use the real
%% signed owners. Only the browser native acknowledgement is a fixture.
lobby_and_nonphysical_component_forms_test_() ->
    {timeout, 120, fun examples/0}.

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
            ?assertEqual([button, container, form, rotary_knob, selection, slider, text_box],
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
        ?assertMatch({ok, [_], _}, read(Ctx, Lobby, {lobby_sky,
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
        external_predicate_modules => [quod_agent_predicates,quod_agent_work_predicates],
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
