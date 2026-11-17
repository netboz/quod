-module(quod_rendering_tests).

%% The `quod:gui` ontology (priv/ontologies/gui_scene.pl): the
%% mark vocabulary a renderer is given. What is checked here is that the schema
%% actually refuses a malformed descriptor — a missing field, a reordered one, a
%% colour that is not one, an invalid label placement, a float where a whole
%% number belongs — and that marks and the things they depict keep separate
%% identities.

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

kinds_declare_their_fields_in_order_test() ->
    with_rendering(fun(St) ->
        Kinds = solutions({'K'}, {mark_kind, {'K'}}, St),
        ?assertEqual([<<"box">>, <<"capsule">>, <<"cylinder">>, <<"group">>, <<"mesh">>,
                      <<"plane">>, <<"sky_sphere">>, <<"sphere">>, <<"terrain">>, <<"torus">>, <<"wire_box">>],
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

exact_edge_box_retains_rational_lengths_test() ->
    with_rendering(fun(St) ->
        Width = {'/',1,3}, Height = 100001, Depth = {'/',1001,2},
        Size = [{f,<<"width">>,Width},{f,<<"height">>,Height},{f,<<"depth">>,Depth}],
        Mark = sized(<<"wire_box">>,Size),
        holds({well_formed_mark,Mark},St),
        Expected = {mark,<<"edges">>,<<"wire_box">>,Size,{transform,10,20,30,15,35,75},
            {surface,<<"#FFFFFF">>,0,700,0,[]},unlabelled,depicts_nothing},
        holds({model,[{part,<<"edges">>,{wire_box,Width,Height,Depth},
            {transform,10,20,30,15,35,75},{surface,<<"#FFFFFF">>,0,700,0,[]},
            unlabelled,depicts_nothing}],[Expected]},St),
        [fails({well_formed_mark,sized(<<"wire_box">>,lists:keyreplace(<<"width">>,2,Size,{f,<<"width">>,Bad}))},St)
            || Bad <- [0,-1,0.5,{'/',1,0},{'/',2,6},{'/',1,1},{'/',-1,3}]],
        fails({well_formed_mark,sized(<<"box">>,Size)},St)
    end).

a_well_formed_mark_test() ->
    with_rendering(fun(St) ->
        holds({well_formed_mark, box(<<"m1">>)}, St),
        holds({well_formed_mark,
               {mark, <<"m2">>, <<"sphere">>, [{f, <<"diameter">>, 900}],
                {transform, 0, 450, 0, 0, 0, 0},
                {surface, <<"#C14953">>, 0, 900, 650, []},
                unlabelled, depicts_nothing}}, St),
        holds({well_formed_mark,
               sized(<<"capsule">>, [{f, <<"diameter">>, 460},
                                      {f, <<"height">>, 850}])}, St),
        holds({well_formed_mark,
               sized(<<"torus">>, [{f, <<"diameter">>, 110},
                                    {f, <<"thickness">>, 18}])}, St),
        holds({well_formed_mark,
               sized(<<"sky_sphere">>, [{f, <<"diameter">>, 80000}])}, St),
        %% a mark may sit behind the origin and be turned
        holds({well_formed_mark,
               {mark, <<"m3">>, <<"plane">>,
                [{f, <<"width">>, 4000}, {f, <<"height">>, 3000}],
                {transform, -2200, 10, -1800, 270, 0, 45},
                {surface, <<"#0B3954">>, 0, 900, 0, []},
                {label, <<"ground">>, <<"centre">>}, depicts_nothing}}, St)
    end).

the_schema_refuses_a_malformed_descriptor_test() ->
    with_rendering(fun(St) ->
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
        holds({well_formed_mark, sized(<<"sphere">>, [{f, <<"diameter">>, 100001}])}, St),
        fails({well_formed_mark,
               sized(<<"capsule">>, [{f, <<"diameter">>, 460},
                                      {f, <<"height">>, 459}])}, St),
        fails({well_formed_mark,
               sized(<<"torus">>, [{f, <<"diameter">>, 110},
                                    {f, <<"thickness">>, 110}])}, St),
        %% an unknown kind has no schema, so it has no answer either
        fails({well_formed_mark, sized(<<"cone">>, [{f, <<"diameter">>, 100}])}, St)
    end).

transforms_are_whole_millimetres_and_degrees_test() ->
    with_rendering(fun(St) ->
        Turned = fun(RX) ->
                     {mark, <<"m1">>, <<"sphere">>, [{f, <<"diameter">>, 100}],
                      {transform, 0, 0, 0, RX, 0, 0},
                      {surface, <<"#698F3F">>, 0, 900, 0, []},
                      unlabelled, depicts_nothing}
                 end,
        holds({well_formed_mark, Turned(359)}, St),
        fails({well_formed_mark, Turned(360)}, St),
        fails({well_formed_mark, Turned(-1)}, St),
        fails({well_formed_mark, Turned(90.0)}, St),
        Moved = fun(X) ->
                    {mark, <<"m1">>, <<"sphere">>, [{f, <<"diameter">>, 100}],
                     {transform, X, 0, 0, 0, 0, 0},
                     {surface, <<"#698F3F">>, 0, 900, 0, []},
                     unlabelled, depicts_nothing}
                end,
        holds({well_formed_mark, Moved(-1000000)}, St),
        holds({well_formed_mark, Moved(1000001)}, St),
        fails({well_formed_mark, Moved(0.5)}, St)
    end).

materials_are_typed_and_labels_complete_test() ->
    with_rendering(fun(St) ->
        Surfaced = fun(Material) ->
                       {mark, <<"m1">>, <<"sphere">>, [{f, <<"diameter">>, 100}],
                        {transform, 0, 0, 0, 0, 0, 0}, Material,
                        unlabelled, depicts_nothing}
                   end,
        holds({well_formed_mark, Surfaced({surface, <<"#F9C80E">>, 0, 200, 0, []})}, St),
        fails({well_formed_mark, Surfaced({surface, <<"F9C80E">>, 0, 200, 0, []})}, St),
        fails({well_formed_mark, Surfaced({surface, <<"#f9c80e">>, 0, 200, 0, []})}, St),
        fails({well_formed_mark, Surfaced({surface, <<"#F9C80">>, 0, 200, 0, []})}, St),
        fails({well_formed_mark, Surfaced({surface, <<"#F9C80EE">>, 0, 200, 0, []})}, St),
        fails({well_formed_mark, Surfaced({surface, <<"#GGGGGG">>, 0, 200, 0, []})}, St),
        fails({well_formed_mark, Surfaced({material, <<"#F9C80E">>, <<"velvet">>})}, St),
        Labelled = fun(Label) ->
                       {mark, <<"m1">>, <<"sphere">>, [{f, <<"diameter">>, 100}],
                        {transform, 0, 0, 0, 0, 0, 0},
                        {surface, <<"#F9C80E">>, 0, 900, 0, []}, Label, depicts_nothing}
                   end,
        holds({well_formed_mark, Labelled({label, text(24), <<"above">>})}, St),
        holds({well_formed_mark, Labelled({label, text(1025), <<"above">>})}, St),
        fails({well_formed_mark, Labelled({label, <<>>, <<"above">>})}, St),
        fails({well_formed_mark, Labelled({label, <<"here">>, <<"left">>})}, St),
        fails({well_formed_mark, Labelled({label, <<"here">>})}, St)
    end).

a_mark_names_the_thing_it_shows_or_says_it_shows_none_test() ->
    with_rendering(fun(St) ->
        Refers = fun(Depicts) ->
                     {mark, <<"m1">>, <<"sphere">>, [{f, <<"diameter">>, 100}],
                      {transform, 0, 0, 0, 0, 0, 0},
                      {surface, <<"#F9C80E">>, 0, 900, 0, []}, unlabelled, Depicts}
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
    with_rendering(fun(St) ->
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
    with_rendering(fun(St) ->
        holds({well_formed_scene, []}, St),
        holds({well_formed_scene, [box(<<"m1">>), box(<<"m2">>)]}, St),
        fails({well_formed_scene, [box(<<"m1">>), box(<<"m1">>)]}, St),
        %% one malformed mark condemns the scene rather than being skipped
        fails({well_formed_scene,
               [box(<<"m1">>), sized(<<"box">>, [{f, <<"width">>, 1}])]}, St)
    end).

the_class_view_is_derived_test() ->
    with_rendering(fun(St) ->
        holds({isa, mark, thing}, St),
        ?assertEqual([<<"box">>, <<"capsule">>, <<"cylinder">>, <<"group">>, <<"mesh">>,
                      <<"plane">>, <<"sky_sphere">>, <<"sphere">>, <<"terrain">>, <<"torus">>, <<"wire_box">>],
                     lists:sort(solutions({'K'}, {instance_of, geometry, {'K'}}, St))),
        ?assertEqual([<<"diameter">>, <<"height">>],
                     solutions({'F'}, {attribute, <<"cylinder">>, field, {'F'}}, St))
    end).

policy_test() ->
    with_committed_rendering(<<"peer_admitted(k, h, p, k).">>, fun(_C, St) ->
        lists:foreach(fun(Goal) -> holds({can_invoke, Goal, anyone, [], ns}, St) end,
                      [{mark_kind, {'K'}},
                       {well_formed_mark, box(<<"m1">>)},
                       {well_formed_scene, [box(<<"m1">>)]},
                       {instance_of, geometry, {'K'}}]),
        Change = {assertz, {mark_kind, <<"cone">>}},
        fails({can_invoke, Change, anyone, [], ns}, St),
        holds({can_invoke, Change, {node, k}, [], ns}, St)
    end).

vocabulary_fits_the_genesis_budget_test() ->
    lists:foreach(fun(Name) ->
        Terms = quod_committed_projection:read_terms(filename:join("priv/ontologies", Name)),
        quod_ct:assert_material_admissible(Terms),
        ?assertNot(lists:any(fun has_float/1, Terms))
    end, ["gui_scene.pl", "quod_material.pl", "quod_material_eidolons.pl", "quod_environment.pl", "quod_environment_eidolons.pl"]).

texture_bindings_are_typed_and_unique_test() ->
    with_rendering(fun(St) ->
        Asset = {asset, binary:copy(<<"a">>, 64), <<"image/jpeg">>},
        Texture = {texture, <<"base_colour">>, Asset, {repeat, 1000, 2500}},
        Surface = fun(Ts) -> setelement(6, box(<<"wood">>),
            {surface, <<"#FFFFFF">>, 0, 1000, 0, Ts}) end,
        holds({well_formed_mark, Surface([Texture])}, St),
        lists:foreach(fun(Ts) -> fails({well_formed_mark, Surface(Ts)}, St) end,
            [[Texture, Texture],
             [setelement(2, Texture, <<"shader">>)],
             [setelement(3, Texture, {asset, <<"bad">>, <<"image/jpeg">>})],
             [setelement(4, Texture, {repeat, 0, 1000})]])
    end).

has_float(T) when is_float(T) -> true;
has_float([Head | Tail]) -> has_float(Head) orelse has_float(Tail);
has_float(T) when is_tuple(T) -> lists:any(fun has_float/1, tuple_to_list(T));
has_float(_) -> false.

parent_order_prevents_cycles_and_dangling_children_test() ->
    with_rendering(fun(St) ->
        Group = {mark, <<"root">>, <<"group">>, [],
                 {transform, 0, 0, 0, 0, 0, 0}, no_surface, unlabelled, depicts_nothing},
        Child = setelement(5, box(<<"child">>),
                           {relative, <<"root">>, {transform, 0, 0, 0, 0, 0, 0}}),
        holds({well_formed_scene, [Group, Child]}, St),
        Driven = setelement(5, Child, {relative, <<"root">>, {body_pose, 10, 2}}),
        holds({well_formed_scene, [Group, Driven]}, St),
        fails({well_formed_scene, [Driven, Group]}, St),
        fails({well_formed_scene, [Group, setelement(5, Driven,
            {relative, <<"root">>, {body_pose, 10, 0}})]}, St),
        fails({well_formed_scene, [Group, setelement(5, Driven,
            {relative, <<"root">>, {relative, <<"root">>, {body_pose, 10, 2}}})]}, St),
        fails({well_formed_scene, [Child]}, St),
        fails({well_formed_scene, [Child, Group]}, St),
        Cycle = setelement(5, Group,
                           {relative, <<"child">>, {transform, 0, 0, 0, 0, 0, 0}}),
        fails({well_formed_scene, [Cycle, Child]}, St),
        fails({well_formed_scene, [Group, Group]}, St),
        fails({well_formed_scene, [setelement(6, Group, {surface, <<"#FFFFFF">>, 0, 900, 0, []})]}, St)
    end).

model_recipes_preserve_body_and_attachment_references_test() ->
    with_rendering(fun(St) ->
        Body = {part,<<"body">>,group,{body_pose,42,7},no_surface,unlabelled,
                {depicts,<<"objects">>,<<7:256>>,object}},
        Child = {part,<<"child">>,group,{relative,<<"body">>,{body_pose,43,8}},
                 no_surface,unlabelled,{depicts,<<"objects">>,<<7:256>>,child}},
        [Marks] = solutions({'Marks'},{model_parts,[Body,Child],{'Marks'}},St),
        ?assertMatch([{mark,<<"body">>,_,_,{body_pose,42,7},_,_,_},
                      {mark,<<"child">>,_,_,{relative,<<"body">>,{body_pose,43,8}},_,_,_}],Marks),
        holds({well_formed_scene,Marks},St),
        fails({model_transform,{relative,<<"body">>,{relative,<<"body">>,{body_pose,43,8}}},{'_'}},St)
    end).

pbr_factors_are_bounded_integers_test() ->
    with_rendering(fun(St) ->
        lists:foreach(fun(Value) ->
            Mark = setelement(6, box(<<"surface">>), {surface, <<"#F9C80E">>, Value, 300, 0, []}),
            fails({well_formed_mark, Mark}, St)
        end, [-1, 1001, 0.5, {'X'}]),
        holds({well_formed_mark, setelement(6, box(<<"surface">>),
                                          {surface, <<"#F9C80E">>, 1000, 0, 1000, []})}, St)
    end).

mesh_geometry_is_typed_and_resource_policy_owned_test() ->
    with_rendering(fun(St) ->
        Mark = mesh_mark(),
        holds({well_formed_mark, Mark}, St),
        Asset = element(4, Mark),
        fails({well_formed_mark, setelement(4, Mark,
            setelement(2, Asset, {asset, <<"wrong">>, <<"model/gltf-binary">>}))}, St),
        fails({well_formed_mark, setelement(4, Mark,
            setelement(3, Asset, <<"unknown-profile">>))}, St),
        fails({well_formed_mark, setelement(4, Mark,
            setelement(4, Asset, {scale, 0}))}, St),
        SmallFrame = {frame, {aabb, 0, 0, 0, 1, 1, 1},
                      {pivot, 0, 0, 0}, {front, <<"-z">>}},
        SmallAsset = setelement(5, Asset, SmallFrame),
        holds({well_formed_mark, setelement(4, Mark,
            setelement(4, SmallAsset, {scale, 100000}))}, St),
        holds({well_formed_mark, setelement(4, Mark,
            setelement(4, SmallAsset, {scale, 100001}))}, St),
        fails({well_formed_mark, setelement(4, Mark,
            setelement(5, Asset, {frame, {aabb, 1, 0, 0, 0, 100, 100},
                                  {pivot, 0, 0, 0}, {front, <<"-z">>}}))}, St),
        holds({well_formed_mark, setelement(4, Mark,
            setelement(6, Asset, {resources, 8000001, 1000, 100, 100, 10, 2, 1000}))}, St),
        fails({well_formed_mark, setelement(6, Mark,
            {surface, <<"#FFFFFF">>, 0, 1000, 0, []})}, St)
    end).

terrain_descriptor_is_body_bound_and_allocated_test() ->
    with_rendering(fun(St) ->
        Geometry = {terrain_geometry,<<"qvt1">>,[{material,9,{surface,<<"#447722">>,0,900,0,[]}}],
                    {view_distance,4000,1000,2000},
                    {resources,500000,1000000,20000,10000,64}},
        Mark = {mark,<<"ground">>,<<"terrain">>,Geometry,{body_pose,4,2},
                terrain_surfaces,unlabelled,{depicts,<<"world">>,<<7:256>>,land}},
        holds({well_formed_mark,Mark},St),
        fails({well_formed_mark,setelement(5,Mark,{transform,0,0,0,0,0,0})},St),
        fails({well_formed_mark,setelement(8,Mark,depicts_nothing)},St),
        fails({well_formed_mark,setelement(4,Mark,[])},St),
        fails({well_formed_mark,setelement(4,Mark,setelement(3,Geometry,
            [{material,9,{surface,<<"#447722">>,0,900,0,[]}},{material,9,{surface,<<"#FFFFFF">>,0,900,0,[]}}]))},St),
        holds({well_formed_mark,setelement(4,Mark,setelement(5,Geometry,
            {resources,500000,1000000,20000,10000,1025}))},St)
    end).

lobby_terrain_recipe_uses_shared_unallocated_resources_test() ->
    {ok,Source}=file:read_file("priv/ontologies/lobby_worlds.pl"),
    with_committed_rendering(Source,fun(_,St) ->
        [Resources]=solutions({'R'},{world_render_resources,{'R'}},St),
        Geometry={terrain_geometry,<<"qvt1">>,[{material,9,{surface,<<"#447722">>,0,900,0,[]}}],
                  {view_distance,100001,1000,2000},Resources},
        holds({well_formed_mark,{mark,<<"ground">>,<<"terrain">>,Geometry,{body_pose,4,2},
              terrain_surfaces,unlabelled,{depicts,<<"world">>,<<7:256>>,land}}},St)
    end).

complete_scenes_and_authored_resources_test() ->
    with_rendering(fun(St) ->
        Marks = [box(integer_to_binary(N)) || N <- lists:seq(1, 600)],
        holds({well_formed_scene, Marks}, St),
        fails({well_formed_scene, [hd(Marks)|Marks]}, St),
        holds({well_formed_mark, box(text(300))}, St),
        M = mesh_mark(), A = element(4,M),
        holds({well_formed_mark,setelement(4,M,setelement(6,A,
            {resources,unlimited,unlimited,unlimited,unlimited,unlimited,unlimited,unlimited}))},St),
        fails({well_formed_mark,setelement(4,M,setelement(6,A,
            {resources,0,unlimited,unlimited,unlimited,unlimited,unlimited,unlimited}))},St),
        holds({gui_properties,[{property,max_bytes,optional}],[],[]},St),
        holds({gui_value,text_area,[{property,required,false}],text(4097)},St),
        fails({gui_value,text_area,[{property,required,false},{property,max_bytes,4096}],text(4097)},St)
    end).

mesh_mark() ->
    {mark, <<"mesh-a">>, <<"mesh">>,
     {mesh_asset, {asset, binary:copy(<<"a">>, 64), <<"model/gltf-binary">>},
      <<"gltf2-static-v1">>, {scale, 1000},
      {frame, {aabb, -400, -100, -800, 1300, 1800, 500},
       {pivot, 200, 0, -100}, {front, <<"+x">>}},
      {resources, 8000000, 16000000, 250000, 250000, 1024, 256, 16000000}},
     {transform, 0, 0, 0, 0, 0, 0}, asset_surfaces, unlabelled, depicts_nothing}.

%% --- helpers ---------------------------------------------------------------


box(Id) -> sized_with(Id, <<"box">>,
                      [{f, <<"width">>, 400}, {f, <<"height">>, 400},
                       {f, <<"depth">>, 400}]).

sized(Kind, Size) -> sized_with(<<"m1">>, Kind, Size).

sized_with(Id, Kind, Size) ->
    {mark, Id, Kind, Size, {transform, 0, 200, 0, 0, 0, 0},
     {surface, <<"#0B3954">>, 0, 900, 0, []},
     {label, <<"part">>, <<"above">>}, depicts_nothing}.

depicting(Id, Thing) ->
    {mark, Id, <<"box">>,
     [{f, <<"width">>, 400}, {f, <<"height">>, 400}, {f, <<"depth">>, 400}],
     {transform, 0, 200, 0, 0, 0, 0}, {surface, <<"#0B3954">>, 0, 900, 0, []},
     unlabelled, {depicts, <<"quod:licence">>, Thing}}.

text(N) -> list_to_binary(lists:duplicate(N, $a)).

holds(Goal, St) -> ?assertMatch({succeed, _}, erlog_int:prove_goal(Goal, St)).
fails(Goal, St) -> ?assertMatch({fail, _}, erlog_int:prove_goal(Goal, St)).

solutions(Template, Goal, St) ->
    {succeed, Final} = erlog_int:prove_goal({findall, Template, Goal, {'L'}}, St),
    erlog_int:dderef({'L'}, Final#est.bs).

with_rendering(Fun) ->
    with_committed_rendering(<<>>, fun(_Committed, St) -> Fun(St) end).

with_committed_rendering(Extra, Fun) ->
    Base = quod_committed_projection:new_est(),
    Loaded = load_terms(quod_ct:gui_terms(), Base),
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
