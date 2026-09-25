-module(quod_present_tests).

%% The `quod:present` ontology (priv/ontologies/quod_present.pl): the bounded
%% mark vocabulary a renderer is given. What is checked here is that the schema
%% actually refuses a malformed descriptor — a missing field, a reordered one, a
%% colour that is not one, a label that is too long, a float where a whole
%% number belongs — and that marks and the things they depict keep separate
%% identities.

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_vm_limits.hrl").

recipe_expressions_and_exact_subject_test() ->
    with_present(fun(St) ->
        Anchor = <<42:256>>,
        Parts = [{part, <<"one">>, {box, {'*', 2, 200}, 600, 100},
                  {transform, 0, {'-', 50}, 0, 0, 0, 0},
                  {pbr, <<"#0B3954">>, 0, 800, 0}, unlabelled,
                  {depicts, <<"personal">>, Anchor, console}}],
        [Marks] = solutions({'M'}, {model, Parts, {'M'}}, St),
        ?assertMatch([{mark, _, _, [{f, _, 400}, _, _],
                       {transform, 0, -50, 0, 0, 0, 0}, _, _, _}], Marks),
        holds({depicted, Marks, <<"one">>, <<"personal">>, Anchor, console}, St),
        fails({depicted, Marks, <<"one">>, <<"personal">>, <<0:256>>, console}, St)
    end).

kinds_declare_their_fields_in_order_test() ->
    with_present(fun(St) ->
        Kinds = solutions({'K'}, {mark_kind, {'K'}}, St),
        ?assertEqual([<<"box">>, <<"cylinder">>, <<"group">>, <<"plane">>, <<"sphere">>],
                     lists:sort(Kinds)),
        %% Every kind's fields are declared at consecutive positions from 1, so
        %% the order a descriptor must use is the order they are written in.
        lists:foreach(
          fun(Kind) ->
              Positions = solutions({'A'}, {geometry_field, Kind, {'A'}, {'_'}}, St),
              ?assertEqual(lists:seq(1, length(Positions)), Positions),
              Fields = solutions({'F'}, {geometry_field, Kind, {'_'}, {'F'}}, St),
              ?assert(lists:all(fun is_binary/1, Fields))
          end, Kinds),
        ?assertEqual([<<"width">>, <<"height">>, <<"depth">>],
                     solutions({'F'}, {geometry_field, <<"box">>, {'_'}, {'F'}}, St))
    end).

a_well_formed_mark_test() ->
    with_present(fun(St) ->
        holds({well_formed_mark, box(<<"m1">>)}, St),
        holds({well_formed_mark,
               {mark, <<"m2">>, <<"sphere">>, [{f, <<"diameter">>, 900}],
                {transform, 0, 450, 0, 0, 0, 0},
                {material, <<"#C14953">>, <<"emissive">>},
                unlabelled, depicts_nothing}}, St),
        %% a mark may sit behind the origin and be turned
        holds({well_formed_mark,
               {mark, <<"m3">>, <<"plane">>,
                [{f, <<"width">>, 4000}, {f, <<"height">>, 3000}],
                {transform, -2200, 10, -1800, 270, 0, 45},
                {material, <<"#0B3954">>, <<"matte">>},
                {label, <<"ground">>, <<"centre">>}, depicts_nothing}}, St)
    end).

the_schema_refuses_a_malformed_descriptor_test() ->
    with_present(fun(St) ->
        %% a field the kind does not take, and the right fields in the wrong order
        fails({well_formed_mark, sized(<<"box">>, [{f, <<"width">>, 400}])}, St),
        fails({well_formed_mark,
               sized(<<"box">>, [{f, <<"width">>, 400}, {f, <<"depth">>, 400},
                                 {f, <<"height">>, 400}])}, St),
        fails({well_formed_mark,
               sized(<<"box">>, [{f, <<"width">>, 400}, {f, <<"height">>, 400},
                                 {f, <<"depth">>, 400}, {f, <<"radius">>, 400}])}, St),
        %% an extent must be a positive whole number of millimetres
        fails({well_formed_mark, sized(<<"sphere">>, [{f, <<"diameter">>, 0}])}, St),
        fails({well_formed_mark, sized(<<"sphere">>, [{f, <<"diameter">>, -5}])}, St),
        fails({well_formed_mark, sized(<<"sphere">>, [{f, <<"diameter">>, 1.5}])}, St),
        fails({well_formed_mark, sized(<<"sphere">>, [{f, <<"diameter">>, {'/', 3, 2}}])}, St),
        fails({well_formed_mark, sized(<<"sphere">>, [{f, <<"diameter">>, 100001}])}, St),
        %% an unknown kind has no schema, so it has no answer either
        fails({well_formed_mark, sized(<<"torus">>, [{f, <<"diameter">>, 100}])}, St)
    end).

transforms_are_whole_millimetres_and_degrees_test() ->
    with_present(fun(St) ->
        Turned = fun(RX) ->
                     {mark, <<"m1">>, <<"sphere">>, [{f, <<"diameter">>, 100}],
                      {transform, 0, 0, 0, RX, 0, 0},
                      {material, <<"#698F3F">>, <<"matte">>},
                      unlabelled, depicts_nothing}
                 end,
        holds({well_formed_mark, Turned(359)}, St),
        fails({well_formed_mark, Turned(360)}, St),
        fails({well_formed_mark, Turned(-1)}, St),
        fails({well_formed_mark, Turned(90.0)}, St),
        Moved = fun(X) ->
                    {mark, <<"m1">>, <<"sphere">>, [{f, <<"diameter">>, 100}],
                     {transform, X, 0, 0, 0, 0, 0},
                     {material, <<"#698F3F">>, <<"matte">>},
                     unlabelled, depicts_nothing}
                end,
        holds({well_formed_mark, Moved(-1000000)}, St),
        fails({well_formed_mark, Moved(1000001)}, St),
        fails({well_formed_mark, Moved(0.5)}, St)
    end).

materials_and_labels_are_bounded_test() ->
    with_present(fun(St) ->
        Surfaced = fun(Material) ->
                       {mark, <<"m1">>, <<"sphere">>, [{f, <<"diameter">>, 100}],
                        {transform, 0, 0, 0, 0, 0, 0}, Material,
                        unlabelled, depicts_nothing}
                   end,
        holds({well_formed_mark, Surfaced({material, <<"#F9C80E">>, <<"glossy">>})}, St),
        fails({well_formed_mark, Surfaced({material, <<"F9C80E">>, <<"glossy">>})}, St),
        fails({well_formed_mark, Surfaced({material, <<"#f9c80e">>, <<"glossy">>})}, St),
        fails({well_formed_mark, Surfaced({material, <<"#F9C80">>, <<"glossy">>})}, St),
        fails({well_formed_mark, Surfaced({material, <<"#F9C80EE">>, <<"glossy">>})}, St),
        fails({well_formed_mark, Surfaced({material, <<"#GGGGGG">>, <<"glossy">>})}, St),
        fails({well_formed_mark, Surfaced({material, <<"#F9C80E">>, <<"velvet">>})}, St),
        Labelled = fun(Label) ->
                       {mark, <<"m1">>, <<"sphere">>, [{f, <<"diameter">>, 100}],
                        {transform, 0, 0, 0, 0, 0, 0},
                        {material, <<"#F9C80E">>, <<"matte">>}, Label, depicts_nothing}
                   end,
        holds({well_formed_mark, Labelled({label, text(24), <<"above">>})}, St),
        fails({well_formed_mark, Labelled({label, text(25), <<"above">>})}, St),
        fails({well_formed_mark, Labelled({label, <<>>, <<"above">>})}, St),
        fails({well_formed_mark, Labelled({label, <<"here">>, <<"left">>})}, St),
        fails({well_formed_mark, Labelled({label, <<"here">>})}, St)
    end).

a_mark_names_the_thing_it_shows_or_says_it_shows_none_test() ->
    with_present(fun(St) ->
        Refers = fun(Depicts) ->
                     {mark, <<"m1">>, <<"sphere">>, [{f, <<"diameter">>, 100}],
                      {transform, 0, 0, 0, 0, 0, 0},
                      {material, <<"#F9C80E">>, <<"matte">>}, unlabelled, Depicts}
                 end,
        holds({well_formed_mark, Refers(depicts_nothing)}, St),
        holds({well_formed_mark,
               Refers({depicts, <<"quod:licence">>,
                       {component, <<"quod">>, <<"cowboy">>}})}, St),
        %% the subject must be ground: a descriptor cannot ship a variable
        fails({well_formed_mark,
               Refers({depicts, <<"quod:licence">>, {component, <<"quod">>, {'X'}}})}, St),
        fails({well_formed_mark, Refers({depicts, <<>>, thing})}, St)
    end).

several_marks_may_depict_one_entity_test() ->
    with_present(fun(St) ->
        Thing = {component, <<"quod">>, <<"erlog">>},
        Scene = [depicting(<<"m1">>, Thing), depicting(<<"m2">>, Thing),
                 depicting(<<"m3">>, {component, <<"quod">>, <<"ranch">>})],
        %% distinct mark ids, repeated subject: a scene tree over a graph that
        %% is not one
        holds({well_formed_scene, Scene}, St),
        ?assertEqual([<<"m1">>, <<"m2">>],
                     solutions({'I'},
                               {depicted, Scene, {'I'}, <<"quod:licence">>, Thing}, St)),
        ?assertEqual(3, length(solutions({'I'},
                                         {depicted, Scene, {'I'}, {'_'}, {'_'}}, St)))
    end).

a_scene_needs_distinct_mark_ids_test() ->
    with_present(fun(St) ->
        holds({well_formed_scene, []}, St),
        holds({well_formed_scene, [box(<<"m1">>), box(<<"m2">>)]}, St),
        fails({well_formed_scene, [box(<<"m1">>), box(<<"m1">>)]}, St),
        %% one malformed mark condemns the scene rather than being skipped
        fails({well_formed_scene,
               [box(<<"m1">>), sized(<<"box">>, [{f, <<"width">>, 1}])]}, St)
    end).

the_class_view_is_derived_test() ->
    with_present(fun(St) ->
        holds({isa, mark, thing}, St),
        ?assertEqual([<<"box">>, <<"cylinder">>, <<"group">>, <<"plane">>, <<"sphere">>],
                     lists:sort(solutions({'K'}, {instance_of, geometry, {'K'}}, St))),
        ?assertEqual([<<"diameter">>, <<"height">>],
                     solutions({'F'}, {attribute, <<"cylinder">>, field, {'F'}}, St))
    end).

policy_test() ->
    with_committed_present(<<"peer_admitted(k, h, p, k).">>, fun(_C, St) ->
        lists:foreach(fun(Goal) -> holds({can_invoke, Goal, anyone, [], ns}, St) end,
                      [{mark_kind, {'K'}},
                       {well_formed_mark, box(<<"m1">>)},
                       {limit, <<"label">>, {'N'}},
                       {instance_of, geometry, {'K'}}]),
        Change = {assertz, {mark_kind, <<"torus">>}},
        fails({can_invoke, Change, anyone, [], ns}, St),
        holds({can_invoke, Change, {node, k}, [], ns}, St)
    end).

vocabulary_fits_the_genesis_budget_test() ->
    Terms = quod_committed_projection:read_terms(source()),
    New = quod_wire_term:cold_new_symbols(Terms),
    ?assert(length(New) =< ?QUOD_MAX_NEW_MATERIAL_ATOMS - 10, {New, length(New)}),
    ?assertNot(lists:any(fun has_float/1, Terms)).

has_float(T) when is_float(T) -> true;
has_float([Head | Tail]) -> has_float(Head) orelse has_float(Tail);
has_float(T) when is_tuple(T) -> lists:any(fun has_float/1, tuple_to_list(T));
has_float(_) -> false.

recipe_compilation_and_alignment_test() ->
    with_present(fun(St) ->
        [ScreenAt] = solutions({'At'},
            {align, {plane, 1000, 600}, centre, {box, 1200, 800, 200},
             front, 5, {'At'}}, St),
        ?assertEqual({transform, 0, 0, -105, 0, 0, 0}, ScreenAt),
        BodyAt = {transform, 0, 900, 0, 0, 30, 0},
        Parts = [{part, <<"console">>, {box, 1200, 800, 200}, BodyAt,
                  {pbr, <<"#0B3954">>, 600, 300, 0}, unlabelled, depicts_nothing},
                 {part, <<"screen">>, {plane, 1000, 600},
                  {relative, <<"console">>, ScreenAt},
                  {pbr, <<"#F9C80E">>, 0, 900, 700}, unlabelled, depicts_nothing}],
        [Scene] = solutions({'Scene'}, {model, Parts, {'Scene'}}, St),
        holds({well_formed_scene, Scene}, St),
        ?assertEqual(2, length(Scene)),
        %% Pure authoring: repeated evaluation has exactly the same result.
        ?assertEqual([Scene], solutions({'Scene'}, {model, Parts, {'Scene'}}, St)),
        fails({model, [{'Unknown'}], {'Scene'}}, St),
        fails({align, {plane, 1000, 600}, centre, {box, 1200, 800, 201},
               front, 5, {'At'}}, St),
        fails({align, {plane, 0, 600}, centre, {box, 1200, 800, 200},
               front, 5, {'At'}}, St)
    end).

parent_order_prevents_cycles_and_dangling_children_test() ->
    with_present(fun(St) ->
        Group = {mark, <<"root">>, <<"group">>, [],
                 {transform, 0, 0, 0, 0, 0, 0}, no_surface, unlabelled, depicts_nothing},
        Child = setelement(5, box(<<"child">>),
                           {relative, <<"root">>, {transform, 0, 0, 0, 0, 0, 0}}),
        holds({well_formed_scene, [Group, Child]}, St),
        fails({well_formed_scene, [Child]}, St),
        fails({well_formed_scene, [Child, Group]}, St),
        Cycle = setelement(5, Group,
                           {relative, <<"child">>, {transform, 0, 0, 0, 0, 0, 0}}),
        fails({well_formed_scene, [Cycle, Child]}, St),
        fails({well_formed_scene, [Group, Group]}, St),
        fails({well_formed_scene, [setelement(6, Group, {material, <<"#FFFFFF">>, <<"matte">>})]}, St)
    end).

pbr_factors_are_bounded_integers_test() ->
    with_present(fun(St) ->
        lists:foreach(fun(Value) ->
            Mark = setelement(6, box(<<"surface">>), {pbr, <<"#F9C80E">>, Value, 300, 0}),
            fails({well_formed_mark, Mark}, St)
        end, [-1, 1001, 0.5, {'X'}]),
        holds({well_formed_mark, setelement(6, box(<<"surface">>),
                                          {pbr, <<"#F9C80E">>, 1000, 0, 1000})}, St)
    end).

%% --- helpers ---------------------------------------------------------------

source() -> filename:join(code:priv_dir(quod), "ontologies/quod_present.pl").

box(Id) -> sized_with(Id, <<"box">>,
                      [{f, <<"width">>, 400}, {f, <<"height">>, 400},
                       {f, <<"depth">>, 400}]).

sized(Kind, Size) -> sized_with(<<"m1">>, Kind, Size).

sized_with(Id, Kind, Size) ->
    {mark, Id, Kind, Size, {transform, 0, 200, 0, 0, 0, 0},
     {material, <<"#0B3954">>, <<"matte">>},
     {label, <<"part">>, <<"above">>}, depicts_nothing}.

depicting(Id, Thing) ->
    {mark, Id, <<"box">>,
     [{f, <<"width">>, 400}, {f, <<"height">>, 400}, {f, <<"depth">>, 400}],
     {transform, 0, 200, 0, 0, 0, 0}, {material, <<"#0B3954">>, <<"matte">>},
     unlabelled, {depicts, <<"quod:licence">>, Thing}}.

text(N) -> list_to_binary(lists:duplicate(N, $a)).

holds(Goal, St) -> ?assertMatch({succeed, _}, erlog_int:prove_goal(Goal, St)).
fails(Goal, St) -> ?assertMatch({fail, _}, erlog_int:prove_goal(Goal, St)).

solutions(Template, Goal, St) ->
    {succeed, Final} = erlog_int:prove_goal({findall, Template, Goal, {'L'}}, St),
    erlog_int:dderef({'L'}, Final#est.bs).

with_present(Fun) ->
    with_committed_present(<<>>, fun(_Committed, St) -> Fun(St) end).

with_committed_present(Extra, Fun) ->
    Base = quod_committed_projection:new_est(),
    Loaded = load_terms(quod_committed_projection:read_terms(source()), Base),
    Committed = quod_ct:commit_kb(load_source(Extra, Loaded)),
    St = quod_erlog_db_local_prove:wrap_state(Committed, #{read_set => true}),
    try Fun(Committed, St)
    after
        #est{db = #db{ref = Ref}} = Committed,
        quod_erlog_db_mvcc:delete(Ref)
    end.

load_source(<<>>, St) -> St;
load_source(Source, St) ->
    {ok, Terms} = erlog_io:read_string_terms(unicode:characters_to_list(Source)),
    load_terms(Terms, St).

load_terms(Terms, #est{db = Db0} = St) ->
    St#est{db = lists:foldl(fun erlog_int:assertz_clause/2, Db0, Terms)}.
