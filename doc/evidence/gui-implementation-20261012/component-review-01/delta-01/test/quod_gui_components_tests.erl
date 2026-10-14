-module(quod_gui_components_tests).
-include_lib("eunit/include/eunit.hrl").

forms_use_the_same_signed_ontology_path_test_() ->
    {timeout, 90, fun() ->
        Dir = filename:join("/tmp", "quod-gui-components-" ++
                                   integer_to_list(erlang:unique_integer([positive]))),
        Terms = source("gui_instance.pl") ++ fixture(),
        Ctx = quod_lobby_tests:start(Dir, [], base_system_catalogue, Terms),
        {ontology_ref, Lobby, _} = maps:get(lobby, Ctx),
        {_, Base} = maps:get(Lobby, maps:get(ontologies, Ctx)),
        {AgentNs, AgentAnchor} = maps:get(agent, Ctx),
        Owner = {agent_instance_ref, AgentNs, AgentAnchor, {human_user, test_agent}},
        Ns = <<"gui:independent-instrument">>,
        {Sup, _} = quod_lobby_tests:start_namespace(Ns, Base#{
            data_dir => filename:join(Dir, "instrument"),
            genesis_diff => quod_prolog:terms_to_diff([
                {can_invoke, {'_'}, Owner, {'_'}, {'_'}},
                {gui_vocabulary, <<"quod:gui">>, quod_simplex:genesis_hash(<<"quod:gui">>)}
                | Terms])}),
        try
            %% Both ontologies compose the same behavior at founding. Signed
            %% edits below change their declarations through existing owners.
            lists:foreach(fun(Target) -> exercise(Ctx, Target) end, [Lobby, Ns]),
            ?assertEqual(#{}, gen_server:call(quod_reg:via({quod_runtime, Ns}), physics_worlds))
        after
            quod_lobby_tests:stop_process(Sup), quod_lobby_tests:stop(Ctx),
            file:del_dir_r(Dir)
        end
    end}.

exercise(Ctx, Ns) ->
    {ok, [#{<<"V0">> := Revision, <<"V1">> := Tree}], _} =
        read(Ctx, Ns, {gui_schema, settings, {0}, {1}}),
    ?assertMatch(<<_:256>>, Revision),
    quod_lobby_tests:assert_read_has_no_io(fun() ->
        lists:foreach(fun(_) ->
            ?assertMatch({ok, [#{<<"V0">> := Revision, <<"V1">> := Tree}], _},
                         read(Ctx, Ns, {gui_schema, settings, {0}, {1}}))
        end, [first, repeated])
    end),
    ?assertMatch({component, settings, form, _, [_, _, _, _]}, Tree),
    ?assertEqual([form, text_box, selection, container, slider, rotary_knob, button], kinds(Tree)),
    Fields = [{field, name, <<"Edited">>}, {field, mode, square},
              {field, level, 75}, {field, angle, 180}],
    Bind = fun(Rev, Values) -> {gui_bind, settings, Rev, apply, Values, {0}} end,
    Other = Ctx#{instance => <<"human_user(other_agent).">>},
    ?assertMatch({fail, _}, read(Other, Ns, {gui_schema, settings, {0}, {1}})),
    ?assertMatch({ok, [#{<<"V0">> := {settings_entered, <<"Edited">>, square, 75, 180}}], _},
                 read(Ctx, Ns, Bind(Revision, lists:reverse(Fields)))),
    lists:foreach(fun(Invalid) ->
        ?assertMatch({fail, _}, read(Ctx, Ns, Bind(Revision, Invalid)))
    end, [tl(Fields), Fields ++ [{field, name, <<"Duplicate">>}],
          Fields ++ [{field, unknown, 1}],
          lists:keyreplace(level, 2, Fields, {field, level, 76}),
          lists:keyreplace(mode, 2, Fields, {field, mode, triangle}),
          lists:keyreplace(name, 2, Fields, {field, name, <<"too much text">>}),
          lists:keyreplace(name, 2, Fields, {field, name, <<"ééééééé"/utf8>>}),
          lists:keyreplace(name, 2, Fields, {field, name, <<>>})]),
    ?assertMatch({ok, [_], _}, read(Ctx, Ns,
        Bind(Revision, lists:keyreplace(name, 2, Fields, {field, name, <<"éééééé"/utf8>>})))),
    ?assertMatch({fail, _}, read(Ctx, Ns, Bind(<<0:256>>, Fields))),
    {ok, [#{<<"V0">> := ValuesToken, <<"V1">> := _}], _} =
        read(Ctx, Ns, {gui_values, settings, {0}, {1}}),
    commit(Ctx, Ns, conjunction([
        {retract, {gui_initial, settings, level, 50}},
        {assertz, {gui_initial, settings, level, 55}}])),
    ?assertMatch({ok, [#{<<"V0">> := Revision}], _},
                 read(Ctx, Ns, {gui_schema, settings, {0}, {'_'}})),
    {ok, [#{<<"V0">> := ChangedValues}], _} =
        read(Ctx, Ns, {gui_values, settings, {0}, {'_'}}),
    ?assertNotEqual(ValuesToken, ChangedValues),
    %% Required inputs can start blank; submission still requires a value.
    commit(Ctx, Ns, {retract, {gui_initial, settings, name, <<"Oscillator">>}}),
    {ok, [#{<<"V1">> := Defaults}], _} = read(Ctx, Ns, {gui_values, settings, {'_'}, {0}}),
    ?assert(lists:member({field, name, <<>>}, Defaults)),
    ?assertMatch({fail, _}, read(Ctx, Ns,
        Bind(Revision, lists:keyreplace(name, 2, Fields, {field, name, <<>>})))),
    commit(Ctx, Ns, {assertz, {gui_initial, settings, name, <<"Oscillator">>}}),
    %% An ambiguous property fails as a whole, never silently drops a control.
    commit(Ctx, Ns, {assertz, {attribute, level, range, {range, 0, 200, 5}}}),
    ?assertMatch({fail, _}, read(Ctx, Ns, {gui_schema, settings, {0}, {1}})),
    commit(Ctx, Ns, {retract, {attribute, level, range, {range, 0, 200, 5}}}),
    commit(Ctx, Ns, {assertz, {attribute, tuning, enabled, false}}),
    ?assertMatch({fail, _}, read(Ctx, Ns, Bind(Revision, Fields))),
    {ok, [#{<<"V0">> := DisabledRevision}], _} =
        read(Ctx, Ns, {gui_schema, settings, {0}, {'_'}}),
    ?assertMatch({fail, _}, read(Ctx, Ns, Bind(DisabledRevision, Fields))),
    Frozen = lists:keyreplace(angle, 2,
        lists:keyreplace(level, 2, Fields, {field, level, 55}), {field, angle, 90}),
    ?assertMatch({ok, [_], _}, read(Ctx, Ns, Bind(DisabledRevision, Frozen))),
    commit(Ctx, Ns, conjunction([
        {retract, {gui_initial, settings, level, 55}},
        {assertz, {gui_initial, settings, level, 60}}])),
    ?assertMatch({fail, _}, read(Ctx, Ns, Bind(DisabledRevision, Frozen))),
    commit(Ctx, Ns, {retract, {attribute, tuning, enabled, false}}),
    %% Mixed unrelated kinds are not resolved by declaration order.
    commit(Ctx, Ns, {assertz, {instance_of, {':', quod, {':', gui, button}}, level}}),
    ?assertMatch({fail, _}, read(Ctx, Ns, {gui_schema, settings, {0}, {1}})),
    commit(Ctx, Ns, {retract, {instance_of, {':', quod, {':', gui, button}}, level}}),
    Form = lists:keyfind(gui_form, 1, fixture()),
    {gui_form, settings, DeclaredFields, {submit, apply, Callback}} = Form,
    lists:foreach(fun(InvalidForm) ->
        commit(Ctx, Ns, conjunction([{retract, Form}, {assertz, InvalidForm}])),
        ?assertMatch({fail, _}, read(Ctx, Ns, {gui_schema, settings, {0}, {1}})),
        commit(Ctx, Ns, conjunction([{retract, InvalidForm}, {assertz, Form}]))
    end, [{gui_form, settings, DeclaredFields, {submit, apply, {unbound, {'Missing'}}}},
          {gui_form, settings, DeclaredFields, {submit, {'Button'}, Callback}},
          {gui_form, settings, DeclaredFields ++ [{'UnboundField'}], {submit, apply, Callback}}]),
    commit(Ctx, Ns, conjunction([
        {retract, {gui_children, tuning, [level, angle]}},
        {assertz, {gui_children, tuning, [level, settings]}}])),
    ?assertMatch({fail, _}, read(Ctx, Ns, {gui_schema, settings, {0}, {1}})).

source(File) -> quod_prolog:read_terms(filename:join(code:priv_dir(quod), "ontologies/" ++ File)).
fixture() -> quod_prolog:read_terms("test/fixtures/gui-components.pl").
scope(Ns, Goal) -> {'::', Ns,
    {',', {current_ontology_identity, Ns, quod_simplex:genesis_hash(Ns)}, Goal}}.
read(Ctx, Ns, Goal) -> quod_lobby_tests:read(Ctx, scope(Ns, Goal)).
commit(Ctx, Ns, Goal) ->
    ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                 quod_lobby_tests:submit(Ctx, execute, scope(Ns, Goal))).
conjunction([Goal]) -> Goal;
conjunction(Goals) ->
    {Left, Right} = lists:split(length(Goals) div 2, Goals),
    {',', conjunction(Left), conjunction(Right)}.
kinds({component, _, Kind, _, Children}) -> [Kind | lists:append([kinds(C) || C <- Children])].
