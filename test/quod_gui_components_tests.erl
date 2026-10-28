-module(quod_gui_components_tests).
-include_lib("eunit/include/eunit.hrl").

remaining_controls_preserve_binding_and_atomic_refusal_test_() ->
    {timeout, 90, fun() ->
        Dir = filename:join("/tmp", "quod-gui-remaining-" ++
            binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
        Terms = source("gui_instance.pl") ++ quod_prolog:read_terms("test/fixtures/gui-remaining.pl"),
        Ctx = quod_lobby_tests:start(Dir, [], base_system_catalogue, Terms),
        {ontology_ref, Ns, _} = maps:get(lobby, Ctx),
        try
            {Result, 1} = vocabulary_calls(fun() -> read(Ctx, Ns, {gui_schema, extra, {0}, {1}}) end),
            {ok, [#{<<"V0">> := Revision, <<"V1">> := Tree}], _} = Result,
            ?assertEqual([form,image,table,dialog,text_area,menu,checkbox,button], kinds(Tree)),
            Values = [{field,rows,[{row,b},{row,a}]},{field,note,<<"two\nlines">>},{field,flag,true}],
            Bind = fun(Fields) -> {gui_bind,extra,Revision,apply,Fields,{0}} end,
            quod_lobby_tests:assert_read_has_no_io(fun() ->
                lists:foreach(fun(_) -> ?assertMatch({ok,[_],_},read(Ctx,Ns,Bind(Values))) end,[first,repeated])
            end),
            lists:foreach(fun(Bad) ->
                ?assertMatch({ok,_,{normalized,{failed,_}}},quod_lobby_tests:submit(Ctx,execute,
                    scope(Ns,{transaction,{',',{assertz,bad_table_write},Bind(Bad)}}))),
                ?assertMatch({fail,_},read(Ctx,Ns,bad_table_write))
            end,[lists:keyreplace(rows,2,Values,{field,rows,[{row,missing}]}),
                 lists:keyreplace(rows,2,Values,{field,rows,[{row,a},{row,a}]}),
                 Values ++ [{field,picture,<<"ignored">>}]]),
            commit(Ctx,Ns,{transaction,{',',Bind(Values),{assertz,{extra_answer,{0}}}}}),
            ?assertMatch({ok,[_],_},read(Ctx,Ns,{extra_answer,{entered,[{row,b},{row,a}],<<"two\nlines">>,true}})),
            commit(Ctx,Ns,{transaction,{',',{retract,{attribute,rows,headings,{'_'}}},
                                          {assertz,{attribute,rows,headings,[<<"Wrong column count">>]}}}}),
            ?assertMatch({fail,_},read(Ctx,Ns,{gui_schema,extra,{0},{1}}))
        after quod_lobby_tests:stop(Ctx), file:del_dir_r(Dir) end
    end}.

composition_uses_inherited_defaults_and_only_binds_inputs_test_() ->
    {timeout, 90, fun() ->
        Dir = filename:join("/tmp", "quod-gui-composition-" ++
            binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
        Terms = source("gui_instance.pl") ++ quod_prolog:read_terms("test/fixtures/gui-composition.pl"),
        Ctx = quod_lobby_tests:start(Dir, [], base_system_catalogue, Terms),
        {ontology_ref, Ns, _} = maps:get(lobby, Ctx),
        try
            {Result, 1} = vocabulary_calls(fun() -> read(Ctx, Ns, {gui_schema, composed, {0}, {1}}) end),
            {ok, [#{<<"V0">> := Revision, <<"V1">> := Tree}], _} = Result,
            Nodes = fun Walk({component, _, _, _, Children} = Node) ->
                [Node | lists:append([Walk(Child) || Child <- Children])]
            end,
            All = Nodes(Tree),
            Property = fun(Id, Key) ->
                {component, Id, _, Props, _} = lists:keyfind(Id, 2, All),
                {property, Key, Value} = lists:keyfind(Key, 2, Props), Value
            end,
            ?assertEqual(grid, Property(inputs, layout)),
            ?assertEqual(3, Property(inputs, columns)),
            ?assertEqual(row, Property(summary, layout)),
            ?assertEqual(column, Property(explanation, layout)),
            ?assertEqual(2, Property(details, visible_rows)),
            ?assertEqual(65, Property(loading, percent)),
            {ok, [#{<<"V1">> := Defaults}], _} = read(Ctx, Ns, {gui_values, composed, {0}, {1}}),
            ?assertEqual([{field, left, <<>>}, {field, right, <<>>}], Defaults),
            Values = [{field, left, <<"L">>}, {field, right, <<"R">>}],
            Bind = fun(Fields) -> {gui_bind, composed, Revision, apply, Fields, {0}} end,
            quod_lobby_tests:assert_read_has_no_io(fun() ->
                lists:foreach(fun(_) ->
                    ?assertMatch({ok, [#{<<"V0">> := {entered, <<"L">>, <<"R">>}}], _},
                                 read(Ctx, Ns, Bind(Values)))
                end, [first, repeated])
            end),
            ?assertMatch({fail, _}, read(Ctx, Ns, Bind(Values ++ [{field, loading, 65}]))),
            commit(Ctx, Ns, {transaction, {',', Bind(Values), {assertz, {composed_answer, {0}}}}}),
            ?assertMatch({ok, [_], _}, read(Ctx, Ns, {composed_answer, {entered, <<"L">>, <<"R">>}})),
            lists:foreach(fun({Id, Key, Before, Invalid}) ->
                commit(Ctx, Ns, {transaction, {',', {retract, {attribute, Id, Key, Before}},
                                                       {assertz, {attribute, Id, Key, Invalid}}}}),
                ?assertMatch({fail, _}, read(Ctx, Ns, {gui_schema, composed, {0}, {1}})),
                commit(Ctx, Ns, {transaction, {',', {retract, {attribute, Id, Key, Invalid}},
                                                       {assertz, {attribute, Id, Key, Before}}}})
            end, [{loading, percent, 65, 101}, {inputs, columns, 3, 0}, {details, visible_rows, 2, -1}])
        after quod_lobby_tests:stop(Ctx), file:del_dir_r(Dir) end
    end}.

input_variants_keep_typed_binding_and_rollback_test_() ->
    {timeout, 120, fun() ->
        Dir = filename:join("/tmp", "quod-gui-inputs-" ++
            binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
        Kinds = [text_area, number_input, checkbox, toggle, radio_group, selectable_list],
        Declarations = [{field, Kind, {N}} || {Kind, N} <- lists:zip(Kinds, lists:seq(0, 5))],
        Terms = [{instance_of, {':', quod, {':', gui, form}}, variants},
                 {instance_of, {':', quod, {':', gui, button}}, apply},
                 {attribute, variants, label, <<"Input variants">>},
                 {attribute, apply, label, <<"Apply">>},
                 {gui_children, variants, Kinds ++ [apply]},
                 {gui_form, variants, Declarations, {submit, apply, {entered, Declarations}}},
                 {attribute, text_area, max_bytes, 12},
                 {attribute, checkbox, required, true},
                 {attribute, selectable_list, required, true},
                 {attribute, selectable_list, multiple, true},
                 {attribute, number_input, range, {range, -2, 8, 3}}]
            ++ lists:append([[{instance_of, {':', quod, {':', gui, Kind}}, Kind},
                              {attribute, Kind, label, atom_to_binary(Kind)}] || Kind <- Kinds])
            ++ [{attribute, Kind, options, [{option, {mode, a}, <<"A">>},
                                            {option, {mode, b}, <<"B">>}]} || Kind <- [radio_group, selectable_list]],
        Ctx = quod_lobby_tests:start(Dir, [], base_system_catalogue, source("gui_instance.pl") ++ Terms),
        {ontology_ref, Ns, _} = maps:get(lobby, Ctx),
        try
            {Schema, 1} = vocabulary_calls(fun() -> read(Ctx, Ns, {gui_schema, variants, {0}, {1}}) end),
            {ok, [#{<<"V0">> := Revision, <<"V1">> := Tree}], _} = Schema,
            ?assertEqual([form | Kinds] ++ [button], kinds(Tree)),
            {ok, [#{<<"V1">> := Defaults}], _} = read(Ctx, Ns, {gui_values, variants, {0}, {1}}),
            ?assertEqual([{field, text_area, <<>>}, {field, number_input, -2},
                          {field, checkbox, false}, {field, toggle, false},
                          {field, radio_group, {mode, a}}, {field, selectable_list, []}], Defaults),
            Fields = [{field, text_area, <<"one\ntwo">>}, {field, number_input, 7},
                      {field, checkbox, true}, {field, toggle, false},
                      {field, radio_group, {mode, b}}, {field, selectable_list, [{mode, b}, {mode, a}]}],
            Bind = fun(Values) -> {gui_bind, variants, Revision, apply, Values, {0}} end,
            {Bound, 2} = vocabulary_calls(fun() -> read(Ctx, Ns, Bind(Fields)) end),
            ?assertMatch({ok, [#{<<"V0">> := {entered, Fields}}], _}, Bound),
            quod_lobby_tests:assert_read_has_no_io(fun() ->
                lists:foreach(fun(_) -> ?assertMatch({ok, [_], _}, read(Ctx, Ns, Bind(Fields))) end,
                              [first, repeated])
            end),
            Invalid = [{text_area, <<"ééééééé"/utf8>>}, {number_input, 8}, {checkbox, false},
                       {toggle, <<"false">>}, {radio_group, {mode, unknown}},
                       {selectable_list, []}, {selectable_list, [{mode, a}, {mode, a}]},
                       {selectable_list, [{':', unintended, value}]}, {selectable_list, {mode, a}}],
            lists:foreach(fun({Kind, Value}) ->
                Bad = lists:keyreplace(Kind, 2, Fields, {field, Kind, Value}),
                ?assertMatch({ok, _, {normalized, {failed, _}}},
                    quod_lobby_tests:submit(Ctx, execute, scope(Ns, {transaction,
                        {',', {assertz, invalid_variant_write}, Bind(Bad)}}))),
                ?assertMatch({fail, _}, read(Ctx, Ns, invalid_variant_write))
            end, Invalid),
            ?assertMatch({fail, _}, read(Ctx#{instance => <<"human_user(other_agent).">>}, Ns, Bind(Fields))),
            commit(Ctx, Ns, {transaction, {',', Bind(Fields), {assertz, {variant_answer, {0}}}}}),
            ?assertMatch({ok, [_], _}, read(Ctx, Ns, {variant_answer, {entered, Fields}}))
        after quod_lobby_tests:stop(Ctx), file:del_dir_r(Dir) end
    end}.

elaborate_form_uses_one_vocabulary_projection_test_() ->
    {timeout, 90, fun() ->
        Dir = filename:join("/tmp", "quod-gui-elaborate-" ++
                                   binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
        Ids = [{setting, N} || N <- lists:seq(1, 32)],
        Fields = [{field, Id, {N}} || {Id, N} <- lists:zip(Ids, lists:seq(0, 31))],
        Terms = [{instance_of, {':', quod, {':', gui, form}}, elaborate},
                 {instance_of, {':', quod, {':', gui, button}}, apply},
                 {attribute, elaborate, label, <<"Elaborate form">>},
                 {attribute, apply, label, <<"Apply">>},
                 {gui_children, elaborate, Ids ++ [apply]},
                 {gui_form, elaborate, Fields, {submit, apply, {entered, Fields}}}]
            ++ lists:append([[{instance_of, {':', quod, {':', gui, slider}}, Id},
                              {attribute, Id, label, <<"Setting">>},
                              {attribute, Id, range, {range, 0, 100, 1}}]
                             || Id <- Ids]),
        Ctx = quod_lobby_tests:start(Dir, [], base_system_catalogue,
                                    source("gui_instance.pl") ++ Terms),
        {ontology_ref, Ns, _} = maps:get(lobby, Ctx),
        try
            {Schema, 1} = vocabulary_calls(fun() ->
                read(Ctx, Ns, {gui_schema, elaborate, {0}, {'_'}}) end),
            {ok, [#{<<"V0">> := Revision}], _} = Schema,
            Values = [{field, Id, 50} || Id <- Ids],
            {Bound, 2} = vocabulary_calls(fun() ->
                read(Ctx, Ns, {gui_bind, elaborate, Revision, apply, Values, {0}}) end),
            ?assertMatch({ok, [#{<<"V0">> := {entered, Values}}], _}, Bound),
            ?assertMatch({ok, [#{<<"V0">> := {entered, Values}}], _},
                read(Ctx, Ns, {gui_bind, elaborate, Revision, apply, lists:reverse(Values), {0}})),
            ?assertMatch({fail, _}, read(Ctx, Ns,
                {gui_bind, elaborate, Revision, apply, Values ++ [hd(Values)], {0}})),
            ?assertMatch({fail, _}, read(Ctx, Ns,
                {gui_bind, elaborate, Revision, apply,
                 lists:keyreplace({setting, 32}, 2, Values, {field, {setting, 32}, 101}), {0}})),
            {Initial, 2} = vocabulary_calls(fun() ->
                read(Ctx, Ns, {gui_values, elaborate, {0}, {1}}) end),
            ?assertMatch({ok, [_], _}, Initial)
        after quod_lobby_tests:stop(Ctx), file:del_dir_r(Dir) end
    end}.

forms_use_the_same_signed_ontology_path_test_() ->
    {timeout, 90, fun() ->
        Dir = filename:join("/tmp", "quod-gui-components-" ++
                                   binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
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
            schema_only_reader(Ctx, Base, Owner, Terms, Dir),
            ?assertEqual(#{}, gen_server:call(quod_reg:via({quod_runtime, Ns}), physics_worlds))
        after
            quod_lobby_tests:stop_process(Sup), quod_lobby_tests:stop(Ctx),
            file:del_dir_r(Dir)
        end
    end}.

schema_only_reader(Ctx, Base, Owner, Terms, Dir) ->
    Ns = <<"gui:schema-reader">>,
    Grant = fun(Query) ->
        {can_invoke, {',', {current_ontology_identity, Ns, {'Anchor'}}, Query},
         Owner, {'Chain'}, Ns}
    end,
    {Sup, _} = quod_lobby_tests:start_namespace(Ns, Base#{
        data_dir => filename:join(Dir, "schema-reader"),
        genesis_diff => quod_prolog:terms_to_diff([
            Grant({gui_schema, {'Form'}, {'Revision'}, {'Tree'}}),
            Grant({gui_values, {'Form'}, {'Token'}, {'Values'}}),
            {gui_vocabulary, <<"quod:gui">>, quod_simplex:genesis_hash(<<"quod:gui">>)} | Terms])}),
    try
        {ok, [#{<<"V0">> := Revision}], _} =
            read(Ctx, Ns, {gui_schema, settings, {0}, {'_'}}),
        {ok, [#{<<"V1">> := Values}], _} = read(Ctx, Ns, {gui_values, settings, {'_'}, {0}}),
        ?assertMatch({fail, _}, read(Ctx, Ns, {gui_bind, settings, Revision, apply, Values, {0}})),
        ?assertMatch({fail, _}, read(Ctx, Ns, {gui_definition, settings, {0}, {1}, {2}, {3}}))
    after quod_lobby_tests:stop_process(Sup) end.

exercise(Ctx, Ns) ->
    %% A foreign application sees the original signed operation, not a new
    %% GUI id. It can bind durable state without consulting a live owner.
    {ok, #{operation_ref := ReadOperation}, {normalized, {read, _,
        {answers, _, [ReadBinding]}}}} =
        quod_lobby_tests:submit(Ctx, read, scope(Ns, {current_request_operation, {0}})),
    ?assertEqual({ok, [{<<"V0">>, ReadOperation}]}, quod_client_result:decode_binding(ReadBinding)),
    {ok, #{operation_ref := WriteOperation}, {normalized, {committed, _, _}}} =
        quod_lobby_tests:submit(Ctx, execute, scope(Ns,
            {',', {current_request_operation, {0}}, {assertz, {recorded_operation, {0}}}})),
    ?assertMatch({ok, [_], _}, read(Ctx, Ns, {recorded_operation, WriteOperation})),
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
    %% Validate inside the same transaction shape used by submission. Local
    %% schema alternatives must not exhaust distributed checkpoints, and a
    %% rejected field set must roll back a preceding application write.
    ?assertMatch({ok, _, {normalized, {failed, _}}},
        quod_lobby_tests:submit(Ctx, execute, scope(Ns, {transaction,
            {',', {assertz, invalid_form_write}, Bind(Revision, tl(Fields))}}))),
    ?assertMatch({fail, _}, read(Ctx, Ns, invalid_form_write)),
    quod_lobby_tests:assert_read_has_no_io(fun() ->
        lists:foreach(fun(_) ->
            ?assertMatch({ok, [_], _},
                read(Ctx, Ns, {transaction, Bind(Revision, Fields)}))
        end, [first, repeated])
    end),
    commit(Ctx, Ns, {transaction,
        {',', Bind(Revision, Fields), {assertz, {bound_form, {0}}}}}),
    ?assertMatch({ok, [_], _}, read(Ctx, Ns,
        {bound_form, {settings_entered, <<"Edited">>, square, 75, 180}})),
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
          lists:keyreplace(name, 2, Fields, {field, name, 42}),
          lists:keyreplace(name, 2, Fields, {field, name, not_binary}),
          lists:keyreplace(name, 2, Fields, {field, name, <<"ééééééé"/utf8>>}),
          lists:keyreplace(name, 2, Fields, {field, name, <<>>})]),
    ?assertMatch({ok, [_], _}, read(Ctx, Ns,
        Bind(Revision, lists:keyreplace(name, 2, Fields, {field, name, <<"éééééé"/utf8>>})))),
    ?assertMatch({fail, _}, read(Ctx, Ns, Bind(<<0:256>>, Fields))),
    %% Colon-valued input is data. It cannot turn a failed lookup into a
    %% foreign invocation under the authenticated human's authority.
    lists:foreach(fun(Goal) ->
        {ok, _, {normalized, {read, Dependencies, {failed, _}}}} =
            quod_lobby_tests:submit(Ctx, read, scope(Ns, Goal)),
        ?assertEqual(false, lists:keymember(<<"unintended">>, 1, Dependencies))
    end, [{gui_schema, {':', unintended, settings}, {0}, {1}},
          {gui_bind, settings, Revision, {':', unintended, apply}, Fields, {0}},
          Bind(Revision, lists:keyreplace(mode, 2, Fields, {field, mode, {':', unintended, value}}))]),
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
    commit(Ctx, Ns, {assertz, {attribute, name, readonly, true}}),
    ?assertMatch({fail, _}, read(Ctx, Ns, {gui_schema, settings, {0}, {1}})),
    commit(Ctx, Ns, {retract, {attribute, name, readonly, true}}),
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
    %% Proof/source presentation capabilities require their existing controller;
    %% a generic submitted form must not admit an unowned editor or catalogue.
    lists:foreach(fun(Kind) ->
        Extra = [{instance_of, {':', quod, {':', gui, Kind}}, presentation_only},
                 {attribute, presentation_only, label, <<"Controller owned">>}],
        commit(Ctx, Ns, conjunction([
            {retract, {gui_children, tuning, [level, angle]}},
            {assertz, {gui_children, tuning, [level, angle, presentation_only]}}
            | quod_ct:source_assertions(Extra)])),
        ?assertMatch({fail, _}, read(Ctx, Ns, {gui_schema, settings, {0}, {1}})),
        commit(Ctx, Ns, conjunction([
            {retract, {gui_children, tuning, [level, angle, presentation_only]}},
            {assertz, {gui_children, tuning, [level, angle]}}
            | [{retract, Term} || Term <- Extra]]))
    end, [editor, bindings, catalogue_selection]),
    Form = lists:keyfind(gui_form, 1, fixture()),
    {gui_form, settings, DeclaredFields, {submit, apply, Callback}} = Form,
    lists:foreach(fun(InvalidForm) ->
        commit(Ctx, Ns, conjunction([{retract, Form}, {assertz, InvalidForm}])),
        ?assertMatch({fail, _}, read(Ctx, Ns, {gui_schema, settings, {0}, {1}})),
        commit(Ctx, Ns, conjunction([{retract, InvalidForm}, {assertz, Form}]))
    end, [{gui_form, settings, DeclaredFields, {submit, apply, {unbound, {'Missing'}}}},
          {gui_form, settings, DeclaredFields, {submit, {'Button'}, Callback}},
          {gui_form, settings, DeclaredFields ++ [{'UnboundField'}], {submit, apply, Callback}}]),
    %% Shared Prolog variables constrain the submitted fields together.
    {field, level, LevelVariable} = lists:keyfind(level, 2, DeclaredFields),
    Shared = {gui_form, settings,
              lists:keyreplace(angle, 2, DeclaredFields, {field, angle, LevelVariable}),
              {submit, apply, {equal_angles, LevelVariable}}},
    commit(Ctx, Ns, conjunction([{retract, Form}, {assertz, Shared}])),
    {ok, [#{<<"V0">> := SharedRevision}], _} =
        read(Ctx, Ns, {gui_schema, settings, {0}, {'_'}}),
    ?assertMatch({fail, _}, read(Ctx, Ns, Bind(SharedRevision, Fields))),
    ?assertMatch({ok, [#{<<"V0">> := {equal_angles, 75}}], _}, read(Ctx, Ns,
        Bind(SharedRevision, lists:keyreplace(angle, 2, Fields, {field, angle, 75})))),
    commit(Ctx, Ns, conjunction([{retract, Shared}, {assertz, Form}])),
    %% Parameterized forms and several instances can reuse the same controls.
    Parameterized = {settings, instrument},
    commit(Ctx, Ns, conjunction([
        quod_ct:source_assertion({instance_of, {':', quod, {':', gui, form}}, Parameterized}),
        {assertz, {attribute, Parameterized, label, <<"Instrument">>}},
        {assertz, {gui_children, Parameterized, [name, mode, tuning, apply]}},
        {assertz, {gui_form, Parameterized, DeclaredFields, {submit, apply, Callback}}}])),
    {ok, [#{<<"V0">> := ParameterRevision}], _} =
        read(Ctx, Ns, {gui_schema, Parameterized, {0}, {'_'}}),
    ?assertMatch({ok, [_], _}, read(Ctx, Ns,
        {gui_bind, Parameterized, ParameterRevision, apply, Fields, {0}})),
    commit(Ctx, Ns, {assertz, {gui_validation_context, settings, {domain_version, 2}}}),
    ?assertMatch({fail, _}, read(Ctx, Ns, Bind(Revision, Fields))),
    commit(Ctx, Ns, conjunction([
        {retract, {gui_children, tuning, [level, angle]}},
        {assertz, {gui_children, tuning, [level, settings]}}])),
    ?assertMatch({fail, _}, read(Ctx, Ns, {gui_schema, settings, {0}, {1}})).

source(File) ->
    case File of
        "gui_measure.pl" -> quod_ct:gui_terms();
        "gui_scene.pl" -> quod_ct:gui_terms();
        "gui_tools.pl" -> quod_ct:gui_terms();
        "quod_gui.pl" -> quod_ct:gui_terms();
        _ -> quod_prolog:read_terms(filename:join(code:priv_dir(quod), "ontologies/" ++ File))
    end.
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

vocabulary_calls(Check) ->
    Parent = self(), Tag = make_ref(),
    Tracer = spawn_link(fun() -> vocabulary_trace(Parent, Tag, 0) end),
    Trace = trace:session_create(gui_vocabulary_test, Tracer, []),
    trace:function(Trace, {quod_proof_session, open, 6}, true, [local]),
    trace:process(Trace, all, true, [call]),
    try
        Result = Check(), Ref = trace:delivered(Trace, all),
        receive {trace_delivered, all, Ref} -> ok after 10000 -> error(trace_timeout) end,
        Tracer ! {barrier, Ref},
        receive {Tag, Ref, Count} -> {Result, Count}
        after 10000 -> error(trace_barrier_timeout) end
    after trace:session_destroy(Trace), Tracer ! stop end.

vocabulary_trace(Parent, Tag, Count) ->
    receive
        {trace, _, call, {quod_proof_session, open, [_, _, _, _, Context, _]}} ->
            Add = case quod_predicates:ctx_ns(Context) of <<"quod:gui">> -> 1; _ -> 0 end,
            vocabulary_trace(Parent, Tag, Count + Add);
        {barrier, Ref} -> Parent ! {Tag, Ref, Count}, vocabulary_trace(Parent, Tag, Count);
        stop -> ok
    end.
