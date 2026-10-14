-module(quod_gui_examples_tests).
-include_lib("eunit/include/eunit.hrl").

%% Accepted rows are fixture inputs until native gui_open acceptance is wired.
%% Everything after that boundary uses real signed multi-ontology transactions.
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
    {Key, _} = maps:get(key_pair, Ctx),
    Admin = {can_invoke, {'_'}, Human, {'_'}, {'_'}},
    ResponderNs = <<"gui:examples-responder">>,
    {Responder, _} = quod_lobby_tests:start_namespace(ResponderNs, Base#{
        data_dir => filename:join(Dir, "responder"),
        genesis_diff => quod_prolog:terms_to_diff(source("agent_instance.pl") ++
            source("gui_question.pl") ++ [Admin, {agent_key, responder, Key, active},
                {gui_completion_allowance, responder, 30000}])}),
    Actor = {agent_instance_ref, ResponderNs, quod_simplex:genesis_hash(ResponderNs), responder},
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
                 {InstrumentNs, {instrument_settings, Instrument}, {apply_instrument, Instrument}, InstrumentFields}],
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
            [{instance_of, human_user, HumanInstance}]))),
        commit(Ctx, scope(Lobby, {assertz, {gui_question_policy, {atmosphere, personal_sky}, Human, Actor}})),
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
                Q = {example, Ns, Round}, Ref = {question_ref, ResponderNs, element(3, Actor), Q},
                Row = {gui_question, Q, {form_ref, Ns, quod_simplex:genesis_hash(Ns), Form},
                       Human, responder, Revision, awaiting},
                commit(Ctx, {transaction, conjunction([
                    scope(ResponderNs, {assertz, Row}),
                    scope(HumanNs, {assertz, {gui_pending, HumanInstance, Ref}})])}),
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
                {ok, [#{<<"V0">> := Bytes}], _} = read(Ctx, ResponderNs,
                    {',', {'=', {0}, {'Bytes'}},
                     {gui_question, Q, {'_'}, Human, responder, Revision,
                        {submitted, {'_'}, Control, Fields, {'Bytes'}}}}),
                Signature = quod_identity:sign(Bytes, quod_identity:key_term(maps:get(key_pair, Ctx))),
                ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                    quod_client_goal_ingress:submit(Bytes, Signature)),
                ?assertMatch({fail, _}, read(Ctx, ResponderNs,
                    {gui_question, Q, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}})),
                ?assertMatch({ok, [#{<<"V0">> := []}], _},
                    read(Ctx, HumanNs, {gui_pending_questions, {0}})),
                ?assertMatch({ok, [#{<<"V1">> := Fields}], _},
                    read(Ctx, Ns, {gui_values, Form, {0}, {1}}))
            end, [1, 2])
        end, Cases),
        ?assertMatch({ok, [_], _}, read(Ctx, InstrumentNs, InstrumentState)),
        ?assertMatch({ok, [_], _}, read(Ctx, InstrumentNs,
            setelement(1, InstrumentState, current_instrument_configuration))),
        ?assertMatch({ok, [_], _}, read(Ctx, Lobby, {lobby_sky,
            {sky, personal_sky, dusk, 80000, 45, 650, <<"#FFFFFF">>}})),
        ?assertMatch({fail, _}, read(Ctx, InstrumentNs, {instance_of, space, {'_'}})),
        ?assertEqual(#{}, gen_server:call(quod_reg:via({quod_runtime, InstrumentNs}), physics_worlds))
    after
        quod_lobby_tests:stop_process(Application), quod_lobby_tests:stop_process(Responder),
        quod_lobby_tests:stop(Ctx), file:del_dir_r(Dir)
    end.

source(Name) -> quod_prolog:read_terms(filename:join(code:priv_dir(quod), "ontologies/" ++ Name)).
scope(Ns, Goal) -> {'::', Ns, {',', {current_ontology_identity, Ns, quod_simplex:genesis_hash(Ns)}, Goal}}.
read(Ctx, Ns, Goal) -> quod_lobby_tests:read(Ctx, scope(Ns, Goal)).
commit(Ctx, Goal) ->
    ?assertMatch({ok, _, {normalized, {committed, _, _}}}, quod_lobby_tests:submit(Ctx, execute, Goal)).
assertions(Terms) ->
    {Goals, _} = lists:mapfoldl(fun(Term, N) ->
        {Fresh, _, Next} = erlog_int:term_instance(Term, N), {{assertz, Fresh}, Next}
    end, 0, Terms), conjunction(Goals).
conjunction([Goal]) -> Goal;
conjunction(Goals) ->
    {Left, Right} = lists:split(length(Goals) div 2, Goals),
    {',', conjunction(Left), conjunction(Right)}.
kinds({component, _, Kind, _, Children}) -> [Kind | lists:append([kinds(C) || C <- Children])].
