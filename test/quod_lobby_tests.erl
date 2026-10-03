-module(quod_lobby_tests).
-include_lib("eunit/include/eunit.hrl").
-export([start/1, stop/1, preview/1]).

lobby_projection_recovery_test_() ->
    {timeout, 90, fun() ->
        Dir = filename:join("/tmp", "quod-lobby-" ++ integer_to_list(erlang:unique_integer([positive]))),
        Ctx = start(Dir),
        try
            Ref = maps:get(lobby, Ctx),
            {ok, [#{<<"V0">> := Ref}], _} = read(Ctx, {lobby_reference, {0}}),
            {ontology_ref, Ns, Anchor} = Ref,
            Goal = {'::', Ns, {',', {current_ontology_identity, Ns, Anchor},
                                    {lobby_view, playing, {0}}}},
            {ok, [#{<<"V0">> := Scene}], _} = read(Ctx, Goal),
            ?assertEqual(18, length(Scene)),
            ?assertMatch({mark, <<"sky">>, <<"sky_sphere">>,
                          [{f, <<"diameter">>, 80000}],
                          {transform, 0, 0, 0, 0, 75, 0}, _, unlabelled,
                          {depicts, Ns, Anchor, personal_sky}},
                         lists:keyfind(<<"sky">>, 2, Scene)),
            ?assert(lists:member({mark, <<"console">>, <<"group">>, [],
               {transform, 0, 0, 0, 0, 0, 0}, no_surface, unlabelled,
               {depicts, Ns, Anchor, console}}, Scene)),
            %% Expected identity is proved before any scene content is selected.
            ?assertMatch({fail, _}, read(Ctx, {'::', Ns,
                {',', {current_ontology_identity, Ns, <<0:256>>},
                      {lobby_view, playing, {0}}}})),
            {ok, [#{<<"V0">> := {form, _, Components}}], _} = read(Ctx,
                {'::', Ns, {lobby_workspace, console, proof_console, {0}}}),
            ?assertEqual([editor, bindings, button, button, button, button, button],
                         [element(1, Component) || Component <- Components]),
            ?assertMatch({ok, [#{<<"V0">> := [{menu_entry, prove_goal, _, _}]}], _},
                read(Ctx, {'::', Ns, {lobby_menu, console, {0}}})),
            %% A valid second actor can read its origin, but cannot read this
            %% private lobby. Privacy is the ontology policy, not UI filtering.
            Other = Ctx#{instance => <<"human_user(other_agent).">>},
            ?assertMatch({ok, _, _}, read(Other, {lobby_reference, {0}})),
            ?assertMatch({fail, _}, read(Other, Goal)),
            %% Sky settings are ordinary durable lobby facts. One transaction
            %% changes the recipe input; no client or system ontology changes.
            TuneSky = {'::', Ns, {',', {current_ontology_identity, Ns, Anchor},
                {',', {retract, {attribute, personal_sky, rotation, 75}},
                      {assertz, {attribute, personal_sky, rotation, 215}}}}},
            ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                         submit(Ctx, execute, TuneSky)),
            {ok, [#{<<"V0">> := ChangedScene}], _} = read(Ctx, Goal),
            ?assertMatch({mark, <<"sky">>, <<"sky_sphere">>, _,
                          {transform, 0, 0, 0, 0, 215, 0}, _, _, _},
                         lists:keyfind(<<"sky">>, 2, ChangedScene)),
            %% The exact same ledger restores the lobby; no creation event or
            %% model facts are replayed into another database.
            {Sup, Config} = maps:get(Ns, maps:get(ontologies, Ctx)),
            stop_process(Sup),
            ?assertEqual(undefined, quod_simplex:genesis_hash(Ns)),
            {Resumed, _} = start_namespace(Ns, Config#{mode => join, genesis_hash => Anchor}),
            try
                ?assertMatch({ok, [#{<<"V0">> := ChangedScene}], _}, read(Ctx, Goal))
            after stop_process(Resumed) end
        after stop(Ctx), file:del_dir_r(Dir) end
    end}.

first_scene_waits_for_new_lobby_route_test_() ->
    [first_scene_waits_for_new_lobby_route(Discovery)
     || Discovery <- [desired_hosting, starting_consensus]].

local_subclass_inherits_eidolons_controls_and_workspace_test_() ->
    {timeout, 90, fun() ->
        Dir = filename:join("/tmp", "quod-lobby-inheritance-" ++
                                   integer_to_list(erlang:unique_integer([positive]))),
        %% The two parent classes live in the pinned vocabulary. The new
        %% subclass and its memberships are edited in the personal ontology.
        Ctx = start(Dir, [{isa, diagnostic_console, device},
                         {device_eidolon, diagnostic_console, playing, solid,
                          console_edition}]),
        try
            {ontology_ref, Ns, Anchor} = maps:get(lobby, Ctx),
            Scope = fun(G) -> {'::', Ns,
                {',', {current_ontology_identity, Ns, Anchor}, G}} end,
            {ok, [#{<<"V0">> := Scene}], _} = read(Ctx, Scope({lobby_view, playing, {0}})),
            {ok, [#{<<"V0">> := Menu}], _} = read(Ctx, Scope({lobby_menu, console, {0}})),
            {ok, [#{<<"V0">> := View}], _} = read(Ctx, Scope({lobby_workspace, console, proof_console, {0}})),
            Edit = {',', {retract, {instance_of, prolog_console, console}},
                    {',', {assertz, {instance_of, smart_console, console}},
                     {',', {assertz, {instance_of, device, console}},
                           {assertz, {isa, smart_console, prolog_console}}}}},
            ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                         submit(Ctx, execute, Scope(Edit))),
            ?assertMatch({ok, [#{<<"V0">> := Scene}], _},
                         read(Ctx, Scope({lobby_view, playing, {0}}))),
            ?assertMatch({ok, [#{<<"V0">> := Menu}], _},
                         read(Ctx, Scope({lobby_menu, console, {0}}))),
            ?assertMatch({ok, [#{<<"V0">> := View}], _},
                         read(Ctx, Scope({lobby_workspace, console, proof_console, {0}}))),
            {ok, [#{<<"V0">> := [Recipe]}], _} = read(Ctx,
                Scope({lobby_eidolons, console, playing, solid, {0}})),
            ?assertMatch({recipe, <<"lobby-test-classes">>, _, console_playing}, Recipe),
            %% The normal qualified class reference has the same behavior;
            %% its namespace is resolved only through this pinned vocabulary.
            Qualify = {',', {retract, {isa, smart_console, prolog_console}},
                           {assertz, {isa, smart_console,
                                     {':', <<"lobby-test-classes">>, prolog_console}}}},
            ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                         submit(Ctx, execute, Scope(Qualify))),
            ?assertMatch({ok, [#{<<"V0">> := Scene}], _},
                         read(Ctx, Scope({lobby_view, playing, {0}}))),
            ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                submit(Ctx, execute, Scope({assertz, {isa, smart_console, diagnostic_console}}))),
            {ok, [#{<<"V0">> := Choices}], _} = read(Ctx,
                Scope({lobby_eidolons, console, playing, solid, {0}})),
            ?assertEqual([console_edition, console_playing],
                         [Id || {recipe, <<"lobby-test-classes">>, _, Id} <- Choices]),
            %% An unresolved choice affects this device, not the entire world.
            {ok, [#{<<"V0">> := Ambiguous}], _} = read(Ctx, Scope({lobby_view, playing, {0}})),
            ?assert(lists:keymember(<<"sky">>, 2, Ambiguous)),
            ?assert(lists:keymember(<<"floor">>, 2, Ambiguous)),
            ?assertMatch({mark, _, <<"group">>, _, _, no_surface,
                          {label, <<"Choose an eidolon">>, <<"above">>}, _},
                         lists:keyfind(<<"console/eidolon-status">>, 2, Ambiguous))
        after stop(Ctx), file:del_dir_r(Dir) end
    end}.

first_scene_waits_for_new_lobby_route(Discovery) ->
    {timeout, 30, fun() ->
        Dir = filename:join("/tmp", "quod-lobby-route-" ++ integer_to_list(erlang:unique_integer([positive]))),
        Ctx = start(Dir),
        {ontology_ref, Ns, Anchor} = maps:get(lobby, Ctx),
        Engine = quod_reg:where({quod_prolog, Ns}),
        Desired = application:get_env(quod, namespace_desired, #{}),
        Content = maps:get(content, Desired, #{}),
        NextContent = case Discovery of
            desired_hosting -> Content#{Ns => #{mode => join, genesis_hash => Anchor}};
            starting_consensus -> maps:remove(Ns, Content)
        end,
        application:set_env(quod, namespace_desired, Desired#{content => NextContent}),
        {ok, Directory} = quod_directory:start_link(#{}),
        Trace = trace:session_create(lobby_route_test, self(), []),
        trace:function(Trace, {quod_reg, subscribe, 1},
                       [{[{directory_route, {Ns, Anchor}}], [], [{return_trace}]}], [local]),
        trace:process(Trace, all, true, [call]),
        _ = sys:replace_state(Engine, fun(S) ->
            true = gproc:unreg(quod_reg:name({quod_prolog, Ns})), S
        end),
        Parent = self(),
        Caller = spawn(fun() ->
            Parent ! {first_scene, self(), read(Ctx, {'::', Ns,
                {',', {current_ontology_identity, Ns, Anchor}, {lobby_view, playing, {0}}}})}
        end),
        try
            receive
                {trace, _, return_from, {quod_reg, subscribe, 1}, true} -> ok
            after 1000 -> error(scene_did_not_subscribe)
            end,
            _ = sys:replace_state(Engine, fun(S) ->
                true = quod_reg:reg({quod_prolog, Ns}), S
            end),
            case Discovery of
                desired_hosting ->
                    {ok, _} = quod_ct:install_directory_generation(
                        <<98:256>>, {"127.0.0.1", 5001}, [{Ns, Anchor, validator}], 1, 1);
                starting_consensus ->
                    quod_reg:publish({runtime, Ns},
                        {proof_ready, {Ns, Anchor}, quod_reg:where({quod_simplex, Ns}),
                         quod_reg:where({quod_prolog, Ns}), 1})
            end,
            receive
                {first_scene, Caller, Result} ->
                    ?assertMatch({ok, [#{<<"V0">> :=
                        [_,_,_,_,_,_,_,_,_,_,_,_,_,_,_,_,_,_]}], _}, Result)
            after 5000 -> error(first_scene_timeout)
            end
        after
            trace:session_destroy(Trace),
            exit(Caller, kill),
            _ = sys:replace_state(Engine, fun(S) ->
                case quod_reg:where({quod_prolog, Ns}) of
                    undefined -> true = quod_reg:reg({quod_prolog, Ns});
                    Engine -> ok
                end, S
            end),
            gen_server:stop(Directory),
            stop(Ctx), file:del_dir_r(Dir)
        end
    end}.

modelling_and_material_libraries_test_() ->
    {timeout, 60, fun() ->
        Dir = filename:join("/tmp", "quod-modelling-" ++ integer_to_list(erlang:unique_integer([positive]))),
        Ctx = start(Dir),
        try
            ModelNs = <<"lobby-test-modelling">>,
            Ask = fun(Ns, Goal) -> read(Ctx, {'::', Ns,
                {',', {current_ontology_identity, Ns, quod_simplex:genesis_hash(Ns)}, Goal}}) end,
            {ok, [#{<<"V0">> := ScreenAt}], _} = Ask(ModelNs,
                {align, {plane, 1000, 600}, centre, {box, 1200, 800, 200}, front, 5, {0}}),
            ?assertEqual({transform, 0, 0, -105, 0, 0, 0}, ScreenAt),
            Surface = {surface, <<"#93613D">>, 0, 700, 0, []},
            Parts = [{part, <<"body">>, {box, 1200, 800, 200},
                      {transform, 0, 900, 0, 0, 30, 0}, Surface, unlabelled, depicts_nothing},
                     {part, <<"screen">>, {plane, 1000, 600},
                      {relative, <<"body">>, {transform, 0, 0, 105, 0, 0, 0}}, Surface, unlabelled, depicts_nothing}],
            {ok, [#{<<"V0">> := Scene}], _} = Ask(ModelNs, {model, Parts, {0}}),
            ?assertEqual(2, length(Scene)),
            ?assertMatch({ok, [#{<<"V0">> := Scene}], _}, Ask(ModelNs, {model, Parts, {0}})),
            ?assertMatch({fail, _}, Ask(ModelNs, {model, [{0}], {1}})),
            ?assertMatch({fail, _}, Ask(ModelNs,
                {align, {plane, 1000, 600}, centre, {box, 1200, 800, 201}, front, 5, {0}})),
            ?assertMatch({fail, _}, Ask(ModelNs,
                {align, {plane, 0, 600}, centre, {box, 1200, 800, 200}, front, 5, {0}})),
            ?assertMatch({ok, _, _}, Ask(ModelNs,
                {align, {torus, 110, 18}, centre, {box, 1200, 800, 200}, front, 5, {0}})),
            ?assertMatch({fail, _}, Ask(ModelNs,
                {align, {capsule, 460, 459}, centre, {box, 1200, 800, 200}, front, 5, {0}})),
            At = {transform, 0, 0, 0, 0, 0, 0},
            {ok, [#{<<"V0">> := A}], _} = Ask(ModelNs, {place_model, <<"a">>, At, depicts_nothing, Parts, {0}}),
            {ok, [#{<<"V0">> := B}], _} = Ask(ModelNs, {place_model, <<"b">>, At, depicts_nothing, Parts, {0}}),
            {ok, [#{<<"V0">> := Both}], _} = Ask(ModelNs, {model, A ++ B, {0}}),
            ?assertEqual([<<"a">>, <<"a/body">>, <<"a/screen">>, <<"b">>, <<"b/body">>, <<"b/screen">>],
                         [element(2, Mark) || Mark <- Both]),
            {ok, [#{<<"V0">> := Nested}], _} = Ask(ModelNs,
                {place_model, <<"room">>, At, depicts_nothing, A ++ B, {0}}),
            {ok, [#{<<"V0">> := NestedMarks}], _} = Ask(ModelNs, {model, Nested, {0}}),
            ?assert(lists:keymember(<<"room/a/screen">>, 2, NestedMarks)),
            MatNs = <<"lobby-test-material">>,
            ?assertMatch({ok, _, _}, Ask(MatNs, {isa, northern_red_oak, wood})),
            ?assertMatch({ok, _, _}, Ask(MatNs, {isa, northern_red_oak, material})),
            ?assertMatch({fail, _}, Ask(MatNs, {isa, bronze, wood})),
            ?assertMatch({fail, _}, Ask(MatNs, {material_property, wood, density, {0}, {1}, {2}})),
            {ok, [#{<<"V0">> := Converted}], _} = Ask(MatNs,
                {property_in, northern_red_oak, density,
                 [{moisture_content, {q, 12, <<"percent">>}}], <<"g/cm3">>, {0}, {1}}),
            ?assertEqual({q, {'/', 141, 200}, <<"g/cm3">>}, Converted),
            ?assertMatch({ok, [#{<<"V0">> := [oak_wood]}], _}, Ask(MatNs,
                {most_specific_classes, [northern_red_oak], [wood, material, oak_wood, stone], {0}})),
            ?assertMatch({ok, [#{<<"V0">> := [oak_wood]}], _}, Ask(MatNs,
                {most_specific_classes, [oak_wood], [wood, material, oak_wood, stone], {0}})),
            ?assertMatch({ok, [#{<<"V0">> := [marble]}], _}, Ask(MatNs,
                {most_specific_classes, [marble], [stone, marble, material], {0}})),
            ?assertMatch({ok, [#{<<"V0">> := []}], _}, Ask(MatNs,
                {most_specific_classes, [northern_red_oak], [stone, bronze], {0}})),
            EidolonNs = <<"lobby-test-material-eidolons">>,
            {ok, [#{<<"V0">> := {recipe, EidolonNs, _, oak}}], _} = Ask(EidolonNs,
                {class_eidolon, northern_red_oak, playing, solid, {0}}),
            ?assertMatch({fail, _}, Ask(EidolonNs,
                {class_eidolon, northern_red_oak, edition, solid, {0}})),
            EnvironmentNs = <<"lobby-test-environment">>,
            ?assertMatch({ok, _, _}, Ask(EnvironmentNs, {isa, sky_sphere, environment})),
            ?assertMatch({fail, _}, quod_prolog:prove_ro(
                <<"lobby-test-classes">>, {isa, sky_sphere, thing})),
            EnvironmentEidolonsNs = <<"lobby-test-environment-eidolons">>,
            ?assertMatch({ok, [#{<<"V0">> :=
                {recipe, EnvironmentEidolonsNs, _, sky_sphere_panoramic}}], _},
                Ask(EnvironmentEidolonsNs,
                    {class_eidolon, sky_sphere, playing, panoramic, {0}})),
            ?assertMatch({ok, _, _}, Ask(EnvironmentEidolonsNs,
                {panorama_asset, belfast_sunset_puresky, {0}, {1}})),
            ?assertMatch({fail, _}, quod_prolog:prove_ro(
                <<"lobby-test-classes">>,
                {panorama_asset, belfast_sunset_puresky, {'_'}, {'_'}})),
            {ontology_ref, LobbyNs, _} = maps:get(lobby, Ctx),
            {ok, [#{<<"V0">> := Playing}], _} = Ask(LobbyNs, {lobby_view, playing, {0}}),
            {ok, [#{<<"V0">> := Edition}], _} = Ask(LobbyNs, {lobby_view, edition, {0}}),
            ?assertNotEqual(Playing, Edition),
            Screen = fun(Marks) -> element(5, lists:keyfind(<<"console/screen">>, 2, Marks)) end,
            ?assertNotEqual(Screen(Playing), Screen(Edition))
        after stop(Ctx), file:del_dir_r(Dir) end
    end}.

signed_prolog_eidolon_edits_use_target_policy_test_() ->
    {timeout, 90, fun() ->
        Dir = filename:join("/tmp", "quod-prolog-eidolon-" ++
                                   integer_to_list(erlang:unique_integer([positive]))),
        Ctx = start(Dir),
        try
            {ontology_ref, Ns, Anchor} = Target = maps:get(lobby, Ctx),
            Scope = fun(At, Goal) -> {'::', At,
                {',', {current_ontology_identity, At, quod_simplex:genesis_hash(At)}, Goal}} end,
            %% Editing is selected through class_eidolon, including for an
            %% ontology itself. It is not an action injected into the console.
            {ok, [#{<<"V0">> := Choices}], _} = read(Ctx,
                Scope(Ns, {entity_eidolons, console, {0}})),
            RecipeNs = <<"quod:prolog:eidolons">>,
            RecipeAnchor = quod_simplex:genesis_hash(RecipeNs),
            CodeEidolon = {eidolon, prolog, source,
                           {recipe, RecipeNs, RecipeAnchor, prolog_editor}},
            ?assert(lists:member(CodeEidolon, Choices)),
            {ok, [#{<<"V0">> := OntologyChoices}], _} = read(Ctx,
                Scope(Ns, {ontology_eidolons, {0}})),
            ?assert(lists:member(CodeEidolon, OntologyChoices)),
            ?assertMatch({ok, [#{<<"V0">> := [{menu_entry, prove_goal, _, _}]}], _},
                         read(Ctx, Scope(Ns, {lobby_menu, console, {0}}))),
            Tools = <<"quod:prolog">>,
            ToolsAnchor = quod_simplex:genesis_hash(Tools),
            {ok, [#{<<"V0">> := Workspace}], _} = read(Ctx, Scope(RecipeNs,
                {eidolon, prolog_editor, {subject, Target, console}, {0}})),
            ?assertMatch({workspace, Target, console, {ontology_ref, Tools, ToolsAnchor},
                          {form, _, [{choice, predicate, _}, {input, new_predicate, _},
                                     {editor, source, _} | _]}},
                         Workspace),
            {ok, [#{<<"V0">> := Indicators}], _} = read(Ctx,
                Scope(Tools, {prolog_predicates, Target, {0}})),
            ?assert(lists:member({'/', lobby_owner, 1}, Indicators)),
            ?assertNot(lists:member({'/', assertz, 1}, Indicators)),
            Indicator = {'/', editor_fact, 1},
            {ok, [#{<<"V0">> := <<>>}], _} = read(Ctx,
                Scope(Tools, {prolog_source, Target, Indicator, {0}})),
            {ok, [#{<<"V0">> := Edit}], _} = read(Ctx,
                Scope(Tools, {prolog_edit_goal, Target, Indicator, <<>>,
                              <<"editor_fact(saved).">>, {0}})),
            ?assertMatch({'::', Ns, {',', {current_ontology_identity, Ns, Anchor},
                                         {transaction, _}}}, Edit),
            %% Compiling source is read-only. Selecting a public recipe or
            %% compiling the same explicit goal does not grant target rights.
            ?assertMatch({fail, _}, read(Ctx, Scope(Ns, {editor_fact, saved}))),
            Other = Ctx#{instance => <<"human_user(other_agent).">>},
            ?assertMatch({fail, _}, read(Other,
                Scope(Tools, {prolog_source, Target, {'/', lobby_owner, 1}, {0}}))),
            ?assertMatch({ok, _, {normalized, {failed, _}}},
                         submit(Other, execute, Edit)),
            ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                         submit(Ctx, execute, Edit)),
            ?assertMatch({ok, _, _}, read(Ctx, Scope(Ns, {editor_fact, saved}))),
            {ok, [#{<<"V0">> := SavedSource}], _} = read(Ctx,
                Scope(Tools, {prolog_source, Target, Indicator, {0}})),
            ?assertEqual(<<"editor_fact(saved) :- true.\n">>, SavedSource),
            %% A separately signed request with an old baseline fails; the
            %% compiler does not hide a write behind a privileged bridge.
            ?assertMatch({ok, _, {normalized, {failed, _}}},
                         submit(Ctx, execute, Edit)),
            ?assertMatch({ok, [#{<<"V0">> := SavedSource}], _}, read(Ctx,
                Scope(Tools, {prolog_source, Target, Indicator, {0}})))
        after stop(Ctx), file:del_dir_r(Dir) end
    end}.

system_ontology_editing_uses_universal_scope_identity_test_() ->
    {timeout, 90, fun() ->
        Dir = filename:join("/tmp", "quod-system-editor-" ++
                                   integer_to_list(erlang:unique_integer([positive]))),
        Ctx = start(Dir),
        try
            RootNs = quod_ontology:root_ns(),
            {_Root, RootConfig} = maps:get(RootNs, maps:get(ontologies, Ctx)),
            ?assertEqual([quod_directory_predicates, quod_ontology_predicates],
                         maps:get(external_predicate_modules, RootConfig)),
            {AgentNs, AgentAnchor} = maps:get(agent, Ctx),
            Owner = {agent_instance_ref, AgentNs, AgentAnchor, {human_user, test_agent}},
            %% Root and node retain their production module declarations and
            %% policy. Editing is authorized explicitly, not by loading agents.
            ?assertMatch({ok, _, _}, quod_prolog:execute(RootNs,
                {assertz, {root_administrator_agent, Owner}})),
            NodeNs = <<"node:editor-test">>,
            NodeBase = RootConfig#{external_predicate_modules => [quod_ontology_predicates]},
            NodeConfig = config(Dir, NodeNs, NodeBase, "node_execution.pl",
                [{node_ontology, NodeNs}, {instance_of, node, physical_node},
                 {agent_key, physical_node, maps:get(node_id, NodeBase), active},
                 {can_invoke, {'_'}, Owner, [AgentNs], NodeNs}]),
            {Node, _} = start_namespace(NodeNs, NodeConfig),
            try
                lists:foreach(fun(Ns) -> verify_system_editor(Ctx, Ns) end,
                              [RootNs, NodeNs])
            after stop_process(Node) end
        after stop(Ctx), file:del_dir_r(Dir) end
    end}.

verify_system_editor(Ctx, Ns) ->
    {AgentNs, AgentAnchor} = maps:get(agent, Ctx),
    Owner = {agent_instance_ref, AgentNs, AgentAnchor, {human_user, test_agent}},
    Anchor = quod_simplex:genesis_hash(Ns),
    Target = {ontology_ref, Ns, Anchor},
    Guard = {current_ontology_identity, Ns, Anchor},
    ?assertMatch({ok, [_], _}, read(Ctx, {'::', Ns, Guard})),
    ?assertMatch({fail, _}, read(Ctx, {'::', Ns,
        {current_ontology_identity, Ns, <<0:256>>}})),
    Tools = <<"quod:prolog">>,
    ToolsGuard = {current_ontology_identity, Tools, quod_simplex:genesis_hash(Tools)},
    Query = fun(Goal) -> {'::', Tools, {',', ToolsGuard, Goal}} end,
    Indicator = {'/', editor_system_fact, 1},
    Source = Query({prolog_source, Target, Indicator, {0}}),
    %% Administrative editing is direct. The shared tool needs a separate,
    %% exact inspection grant; calling it must not lend it mutation authority.
    ?assertMatch({fail, _}, read(Ctx, Source)),
    SourceGrant = {can_invoke,
        {',', Guard, {'$quod_predicate_source', Indicator, {'_'}}},
        Owner, [Tools, AgentNs], Ns},
    ?assertMatch({ok, _, {normalized, {committed, _, _}}},
        submit(Ctx, execute, {'::', Ns, {',', Guard, {assertz, SourceGrant}}})),
    ?assertMatch({ok, [#{<<"V0">> := <<>>}], _}, read(Ctx, Source)),
    ?assertMatch({fail, _}, read(Ctx,
        Query({prolog_source, Target, {'/', can_invoke, 4}, {0}}))),
    {ok, [#{<<"V0">> := Edit}], _} = read(Ctx,
        Query({prolog_edit_goal, Target, Indicator, <<>>,
               <<"editor_system_fact(saved).">>, {0}})),
    ?assertMatch({'::', Ns, {',', Guard, {transaction, _}}}, Edit),
    Other = Ctx#{instance => <<"human_user(other_agent).">>},
    ?assertMatch({fail, _}, read(Other, Source)),
    ?assertMatch({ok, _, {normalized, {failed, _}}}, submit(Other, execute, Edit)),
    ?assertMatch({ok, _, {normalized, {committed, _, _}}}, submit(Ctx, execute, Edit)),
    ?assertMatch({ok, [#{<<"V0">> := <<"editor_system_fact(saved) :- true.\n">>}], _},
                 read(Ctx, Source)),
    ?assertMatch({ok, _, {normalized, {failed, _}}}, submit(Ctx, execute, Edit)).

shared_class_edits_and_subclass_selection_use_live_definitions_test_() ->
    {timeout, 90, fun() ->
        Dir = filename:join("/tmp", "quod-shared-editor-" ++
                                   integer_to_list(erlang:unique_integer([positive]))),
        Ctx = start(Dir),
        try
            {ontology_ref, Ns, Anchor} = Lobby = maps:get(lobby, Ctx),
            ClassNs = <<"lobby-test-classes">>,
            {UserNs, UserAnchor} = maps:get(agent, Ctx),
            Owner = {agent_instance_ref, UserNs, UserAnchor, {human_user, test_agent}},
            ?assertMatch({ok, _, _}, quod_prolog:execute(ClassNs,
                {assertz, {can_invoke, {'_'}, Owner, {'_'}, ClassNs}})),
            Added = [{instance_of, prolog_console, console_b},
                     {lobby_device, personal_lobby, console_b},
                     {device_placement, console_b, <<"console_b">>,
                        {transform, 3000, 0, 0, 0, 0, 0}}],
            commit_editor_goal(Ctx, editor_scope(Ns, editor_conjunction([{assertz, T} || T <- Added]))),
            ?assertEqual([<<"PROLOG CONSOLE">>, <<"PROLOG CONSOLE">>], shared_editor_titles(Ctx, Ns)),
            edit_shared_source(Ctx, ClassNs, {'/', console_layout, 9}, fun(Source) ->
                ?assertNotEqual(nomatch, binary:match(Source, <<"PROLOG CONSOLE">>)),
                binary:replace(Source, <<"PROLOG CONSOLE">>, <<"SHARED REVISION">>, [global])
            end),
            ?assertEqual([<<"SHARED REVISION">>, <<"SHARED REVISION">>], shared_editor_titles(Ctx, Ns)),
            ?assertMatch({ok, [#{<<"V0">> := <<>>}], _},
                read(Ctx, editor_scope(Ns, {'$quod_predicate_source', {'/', console_layout, 9}, {0}}))),
            edit_shared_source(Ctx, ClassNs, {'/', isa, 2}, fun(Source) ->
                <<Source/binary, "isa(smart_console, prolog_console).\n">>
            end),
            edit_shared_source(Ctx, ClassNs, {'/', device_eidolon, 4}, fun(Source) ->
                <<Source/binary, "device_eidolon(smart_console, playing, solid, console_edition).\n">>
            end),
            commit_editor_goal(Ctx, editor_scope(Ns, {',', {retract, {instance_of, prolog_console, console_b}},
                                       {assertz, {instance_of, smart_console, console_b}}})),
            ?assertEqual([<<"SHARED REVISION">>, <<"CONSOLE PARTS">>], shared_editor_titles(Ctx, Ns)),
            {ok, [#{<<"V0">> := [Chosen]}], _} = read(Ctx,
                editor_scope(Ns, {lobby_eidolons, console_b, playing, solid, {0}})),
            ?assertMatch({recipe, ClassNs, _, console_edition}, Chosen),
            {ok, [#{<<"V0">> := [Original]}], _} = read(Ctx,
                editor_scope(Ns, {lobby_eidolons, console, playing, solid, {0}})),
            ?assertMatch({recipe, ClassNs, _, console_playing}, Original),
            Baseline = editor_source(Ctx, Lobby, {'/', can_invoke, 4}),
            Goal = compile_source_edit(Ctx, Lobby, {'/', can_invoke, 4}, Baseline,
                           <<Baseline/binary, "can_invoke(_, _, _, _).\n">>),
            Other = Ctx#{instance => <<"human_user(other_agent).">>},
            ?assertMatch({ok, _, {normalized, {failed, _}}},
                         submit(Other, execute, Goal)),
            ?assertEqual(Baseline, editor_source(Ctx, Lobby, {'/', can_invoke, 4})),
            ?assertMatch({fail, _}, read(Other,
                 {'::', Ns, {current_ontology_identity, Ns, Anchor}})),
            ok
        after stop(Ctx), file:del_dir_r(Dir) end
    end}.

shared_editor_titles(Ctx, Ns) ->
    Heights = maps:map(fun(At, _) -> quod_prolog:applied(At) end, maps:get(ontologies, Ctx)),
    {ok, [#{<<"V0">> := Scene}], _} = read(Ctx, editor_scope(Ns, {lobby_view, playing, {0}})),
    ?assertEqual(Heights, maps:map(fun(At, _) -> quod_prolog:applied(At) end,
                                  maps:get(ontologies, Ctx))),
    [begin
        {mark, Id, _, _, _, _, {label, Title, _}, _} = lists:keyfind(Id, 2, Scene),
        Title
     end || Id <- [<<"console/top-sign">>, <<"console_b/top-sign">>]].

large_signed_source_edit_does_not_return_inspection_scratch_test_() ->
    {timeout, 90, fun() ->
        Dir = filename:join("/tmp", "quod-large-editor-" ++
                                   integer_to_list(erlang:unique_integer([positive]))),
        Ctx = start(Dir),
        try
            {ontology_ref, Ns, _} = Target = maps:get(lobby, Ctx),
            Indicator = {'/', editor_payload, 1},
            Payload = binary:copy(<<"x">>, 10000),
            Draft = <<"editor_payload(<<\"", Payload/binary, "\">>).">>,
            Canonical = <<"editor_payload(<<\"", Payload/binary, "\">>) :- true.\n">>,
            ?assertMatch({error, {too_large, result}}, quod_durable_term:encode_result(
                #{<<"After">> => [{':-', {editor_payload, Payload}, true}],
                  <<"AfterSource">> => Canonical})),
            Goal = compile_source_edit(Ctx, Target, Indicator, <<>>, Draft),
            %% The complete compiled goal uses ordinary signing and scope
            %% admission. Its durable answer contains no inspected program.
            {ok, Evidence, {normalized, {committed, [Result], _}}} = submit(Ctx, execute, Goal),
            ?assertEqual({ok, []}, quod_durable_term:decode_result(Result)),
            {SourceNs, _} = maps:get(agent, Ctx),
            #{operation_state := terminal} = quod_ct:await_operation_complete(
                SourceNs, quod_client_goal:operation_ref(Evidence), 5000),
            ?assertMatch({ok, _, _}, read(Ctx, editor_scope(Ns, {editor_payload, Payload}))),
            ?assertEqual(Canonical, editor_source(Ctx, Target, Indicator)),
            {ok, _, {normalized, {failed, Reasons}}} = submit(Ctx, execute, Goal),
            {ok, DecodedReasons} = quod_wire_term:decode_failure_reasons(Reasons),
            ?assert(lists:member({edit_conflict, Indicator}, DecodedReasons))
        after stop(Ctx), file:del_dir_r(Dir) end
    end}.

edit_shared_source(Ctx, Ns, Indicator, Transform) ->
    Target = {ontology_ref, Ns, quod_simplex:genesis_hash(Ns)},
    Before = editor_source(Ctx, Target, Indicator),
    After = Transform(Before),
    ?assertNotEqual(Before, After),
    commit_editor_goal(Ctx, compile_source_edit(Ctx, Target, Indicator, Before, After)).

editor_source(Ctx, Target, Indicator) ->
    {ok, [#{<<"V0">> := Source}], _} = read(Ctx, editor_scope(<<"quod:prolog">>,
        {prolog_source, Target, Indicator, {0}})),
    Source.

compile_source_edit(Ctx, Target, Indicator, Before, After) ->
    {ok, [#{<<"V0">> := Goal}], _} = read(Ctx, editor_scope(<<"quod:prolog">>,
        {prolog_edit_goal, Target, Indicator, Before, After, {0}})),
    Goal.

commit_editor_goal(Ctx, Goal) ->
    {ok, Evidence, {normalized, {committed, _, _}}} = submit(Ctx, execute, Goal),
    {SourceNs, _} = maps:get(agent, Ctx),
    %% The client may learn target success before its source receipt lands.
    %% Wait on that existing operation before measuring later read-only work.
    #{operation_state := terminal} = quod_ct:await_operation_complete(
        SourceNs, quod_client_goal:operation_ref(Evidence), 5000),
    ok.

editor_scope(Ns, Goal) -> {'::', Ns, {',',
    {current_ontology_identity, Ns, quod_simplex:genesis_hash(Ns)}, Goal}}.
editor_conjunction([Goal]) -> Goal;
editor_conjunction([Goal | Rest]) -> {',', Goal, editor_conjunction(Rest)}.

start(Dir) ->
    start(Dir, []).

start(Dir, ExtraClassFacts) ->
    {ok, _} = application:ensure_all_started(gproc),
    Keys = [node_pubkey, identity_key, namespace_desired, client_enabled,
            client_ip, client_port, identity_dir],
    Saved = [{K, application:get_env(quod, K)} || K <- Keys],
    {Pub, _} = Pair = quod_identity:generate(),
    Identity = #{pubkey => Pub, key => quod_identity:key_term(Pair),
                 cert => quod_identity:mint_cert(Pair)},
    application:set_env(quod, node_pubkey, Pub),
    application:set_env(quod, identity_key, maps:get(key, Identity)),
    {ok, Router} = quod_ask_router:start_link(),
    {ok, Cursors} = quod_client_cursor:start_link(),
    {ok, Effects} = quod_effect_journal:start_link(#{data_dir => filename:join(Dir, "effects")}),
    Base = #{node_id => Pub, identity => Identity, mode => create,
             external_predicate_modules => [quod_agent_predicates]},
    Spec = [{<<"lobby-test-rendering">>, "quod_rendering.pl", []},
            {<<"lobby-test-measure">>, "quod_measure.pl", []},
            {<<"lobby-test-modelling">>, "quod_modelling.pl",
             [{rendering_vocabulary, <<"lobby-test-rendering">>}]},
            {<<"lobby-test-material">>, "quod_material.pl",
             [{measure_vocabulary, <<"lobby-test-measure">>}]},
            {<<"lobby-test-material-eidolons">>, "quod_material_eidolons.pl",
             [{material_vocabulary, <<"lobby-test-material">>}]},
            {<<"lobby-test-environment">>, "quod_environment.pl", []},
            {<<"lobby-test-environment-eidolons">>, "quod_environment_eidolons.pl",
             [{environment_vocabulary, <<"lobby-test-environment">>}]},
            {<<"quod:gui">>, "quod_gui.pl", []},
            {<<"quod:prolog">>, "quod_prolog.pl", []},
            {<<"quod:prolog:eidolons">>, "quod_prolog_eidolons.pl", []}],
    Ontologies0 = maps:from_list([begin
        Refs = [{Predicate, Target, quod_simplex:genesis_hash(Target)}
                || {Predicate, Target} <- Facts],
        Config = config(Dir, Ns, Base, Source, Refs),
        {Ns, start_namespace(Ns, Config)}
    end || {Ns, Source, Facts} <- Spec]),
    %% Use the actual system ontology catalogue and policies. Universal
    %% eidolon discovery must cross these exact identities through signed ACLs.
    RootNs = quod_ontology:root_ns(),
    Catalogue = [{system_ontology, Ns, quod_simplex:genesis_hash(Ns)}
                 || {Ns, _, _} <- Spec],
    RootBase = Base#{external_predicate_modules => [quod_directory_predicates, quod_ontology_predicates]},
    Root = start_namespace(RootNs, config(Dir, RootNs, RootBase, "quod_root.pl", Catalogue)),
    Network = quod_simplex:genesis_hash(RootNs),
    application:set_env(quod, namespace_desired,
        #{content => #{RootNs => #{genesis_hash => Network}}, brahms => #{}}),
    {ok, Auth} = quod_client_auth:start_link(#{network_id => Network, node_key => Pub}),
    ClassNs = <<"lobby-test-classes">>,
    ClassFacts = [{modelling_vocabulary, <<"lobby-test-modelling">>,
                   quod_simplex:genesis_hash(<<"lobby-test-modelling">>)},
                  {material_eidolons, <<"lobby-test-material-eidolons">>,
                   quod_simplex:genesis_hash(<<"lobby-test-material-eidolons">>)},
                  {environment_vocabulary, <<"lobby-test-environment">>,
                   quod_simplex:genesis_hash(<<"lobby-test-environment">>)},
                  {environment_eidolons, <<"lobby-test-environment-eidolons">>,
                   quod_simplex:genesis_hash(<<"lobby-test-environment-eidolons">>)}],
    Classes = start_namespace(ClassNs, config(Dir, ClassNs, Base, "quod_lobby.pl",
                                              ClassFacts ++ ExtraClassFacts)),
    AgentNs = <<"lobby-test-user">>,
    {UserKey, _} = UserPair = quod_identity:generate(),
    AgentFacts = [{agent_key, {human_user, other_agent}, UserKey, active},
       {can_invoke, {'_'}, {agent_instance_ref, AgentNs, {'_'}, {human_user, other_agent}}, {'_'}, {'_'}},
       {agent_key, {human_user, test_agent}, UserKey, active},
       {can_invoke, {'_'}, {agent_instance_ref, AgentNs, {'_'}, {human_user, test_agent}}, {'_'}, {'_'}}],
    User = start_namespace(AgentNs, config(Dir, AgentNs, Base, none, AgentFacts)),
    AgentAnchor = quod_simplex:genesis_hash(AgentNs),
    Owner = {agent_instance_ref, AgentNs, AgentAnchor, {human_user, test_agent}},
    LobbyNs = <<"lobby-test-personal">>,
    LobbyFacts = [{lobby_owner, Owner}, {instance_of, sky_sphere, personal_sky},
       {attribute, personal_sky, panorama, belfast_sunset_puresky},
       {attribute, personal_sky, diameter, 80000},
       {attribute, personal_sky, rotation, 75},
       {attribute, personal_sky, brightness, 120},
       {attribute, personal_sky, tint, <<"#FFFFFF">>},
       {instance_of, prolog_console, console},
       {lobby_device, personal_lobby, console},
       {device_placement, console, <<"console">>, {transform, 0, 0, 0, 0, 0, 0}},
       {modelling_vocabulary, <<"lobby-test-modelling">>, quod_simplex:genesis_hash(<<"lobby-test-modelling">>)},
       {environment_vocabulary, <<"lobby-test-environment">>, quod_simplex:genesis_hash(<<"lobby-test-environment">>)},
       {gui_vocabulary, <<"quod:gui">>, quod_simplex:genesis_hash(<<"quod:gui">>)},
       {lobby_vocabulary, <<"lobby-test-classes">>, quod_simplex:genesis_hash(<<"lobby-test-classes">>)}],
    Lobby = start_namespace(LobbyNs, config(Dir, LobbyNs, Base, "lobby_instance.pl", LobbyFacts)),
    LobbyRef = {ontology_ref, LobbyNs, quod_simplex:genesis_hash(LobbyNs)},
    Ctx = #{ontologies => Ontologies0#{RootNs => Root, ClassNs => Classes, AgentNs => User, LobbyNs => Lobby},
            services => [Effects, Cursors, Auth, Router], saved => Saved, directory => Dir,
            agent => {AgentNs, AgentAnchor}, key_pair => UserPair, network => Network,
            lobby => LobbyRef},
    ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                 submit(Ctx, execute, {assertz, {lobby_reference, LobbyRef}})),
    Ctx.

config(Dir, Ns, Base, Source, Facts) ->
    Diff = case Source of
        none -> [];
        _ -> quod_prolog:genesis_diff(filename:join(code:priv_dir(quod), "ontologies/" ++ Source))
    end,
    Base#{data_dir => filename:join(Dir, binary_to_list(Ns)),
          genesis_diff => Diff ++ quod_prolog:terms_to_diff(Facts)}.

start_namespace(Ns, Config) ->
    true = quod_reg:subscribe({runtime, Ns}),
    {ok, Sup} = quod_ns:start_link(Ns, Config),
    unlink(Sup),
    receive {replay_ready, _, _} -> ok after 15000 -> error({not_ready, Ns}) end,
    quod_reg:unsubscribe({runtime, Ns}),
    {Sup, Config}.

stop(Ctx) ->
    maps:foreach(fun(_, {Sup, _}) -> stop_process(Sup) end, maps:get(ontologies, Ctx)),
    lists:foreach(fun stop_process/1, maps:get(services, Ctx)),
    lists:foreach(fun({K, undefined}) -> application:unset_env(quod, K);
                     ({K, {ok, V}}) -> application:set_env(quod, K, V)
                  end, maps:get(saved, Ctx)).

stop_process(Pid) ->
    unlink(Pid),
    Ref = monitor(process, Pid), exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _} -> ok after 5000 -> error(stop_timeout) end.

submit(Ctx, Mode, Goal) ->
    {Ns, Anchor} = maps:get(agent, Ctx),
    {Public, _} = KeyPair = maps:get(key_pair, Ctx),
    %% Returned compiler terms have fresh proof variable IDs. Text entry
    %% re-numbers those names exactly as every ordinary signed request does.
    {Numbered, _, _} = erlog_int:term_instance(Goal, 0),
    {ok, Text} = quod_client_goal_parser:format(Numbered),
    Request = #{network_identity => maps:get(network, Ctx), signing_public_key => Public,
        operation_id => crypto:strong_rand_bytes(32), agent_namespace => Ns,
        agent_genesis_anchor => Anchor, agent_instance_text => maps:get(instance, Ctx, <<"human_user(test_agent).">>),
        mode => Mode, parser_version => 2, not_after_ms => quod_time:now_ms() + 30000,
        goal_text => Text},
    {ok, Bytes} = quod_client_goal:encode(Request),
    Signature = quod_identity:sign(Bytes, quod_identity:key_term(KeyPair)),
    quod_client_goal_ingress:submit(Bytes, Signature).

read(Ctx, Goal) ->
    case submit(Ctx, read, Goal) of
        {ok, _, {normalized, {answers, Height, Blobs}}} ->
            {ok, [begin {ok, Pairs} = quod_client_result:decode_binding(B), maps:from_list(Pairs) end
                  || B <- Blobs], Height};
        {ok, _, {normalized, {failed, Reasons}}} ->
            {ok, Decoded} = quod_wire_term:decode_failure_reasons(Reasons),
            {fail, Decoded};
        Other -> Other
    end.

%% Manual/browser acceptance uses these same real owners and signed endpoints.
%% Only the disposable fixture's identity is written, into an owner-only file.
preview(Dir) ->
    Ctx = start(Dir),
    application:set_env(quod, client_enabled, true),
    application:set_env(quod, client_ip, {127, 0, 0, 1}),
    application:set_env(quod, client_port, 0),
    application:set_env(quod, identity_dir, Dir),
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, Client} = quod_client:start_link(),
    {Public, Seed} = maps:get(key_pair, Ctx),
    {Ns, Anchor} = maps:get(agent, Ctx),
    Metadata = #{port => ranch:get_port(quod_client_listener), namespace => Ns,
        anchor => base64:encode(Anchor, #{mode => urlsafe, padding => false}),
        public_key => base64:encode(Public), seed => base64:encode(Seed)},
    ok = quod_file:write_atomic(filename:join(Dir, "browser.json"), iolist_to_binary(json:encode(Metadata)), 8#600),
    io:format("Local lobby acceptance endpoint ready.~n"),
    receive stop -> ok end,
    stop_process(Client), stop(Ctx).
