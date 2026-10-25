-module(quod_lobby_tests).
-include_lib("eunit/include/eunit.hrl").
-export([start/1, start/4, stop/1, preview/1, read/2, submit/3,
         start_namespace/2, stop_process/1, assert_read_has_no_io/1, open_cursor/2,
         complete_source/2]).

cohosted_certified_progress_test_() ->
    {timeout, 30, fun() ->
        Dir = filename:join("/tmp", "quod-lobby-progress-" ++
                            integer_to_list(erlang:unique_integer([positive]))),
        Ctx = start(Dir),
        {ontology_ref, Ns, Anchor} = maps:get(lobby, Ctx),
        Identity = {Ns, Anchor},
        try
            {ok, Request} = quod_foreign_log:follow_request(Identity, progress),
            {reply, {ok, Follow}} = gen_server:wait_response(Request, 5000),
            try
                Height = certified_progress(Follow, Identity, -1),
                ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                    submit(Ctx, execute, editor_scope(Ns, {assertz, progress_probe}))),
                ?assert(certified_progress(Follow, Identity, Height) > Height),
                ?assertMatch(#{projection_workers := 0}, quod_foreign_log:stats())
            after ok = quod_foreign_log:unfollow(Follow) end
        after stop(Ctx), file:del_dir_r(Dir) end
    end}.

certified_progress(Follow, Identity, After) ->
    receive
        {quod_foreign_follow, Follow, Notice, Identity, Progress} ->
            ok = quod_foreign_log:ack(Follow, Notice),
            case Progress of
                {certified, Height, _} when Height > After -> Height;
                _ -> certified_progress(Follow, Identity, After)
            end
    after 5000 -> error(missing_certified_progress) end.

authored_space_composition_preserves_world_test_() ->
    {timeout, 90, fun() ->
        Dir = filename:join("/tmp", "quod-authored-space-" ++
                            integer_to_list(erlang:unique_integer([positive]))),
        Ctx = start(Dir),
        {ontology_ref, LobbyNs, _} = maps:get(lobby, Ctx),
        OtherNs = <<"authored-gallery">>,
        {_, Base} = maps:get(LobbyNs, maps:get(ontologies, Ctx)),
        {AgentNs, AgentAnchor} = maps:get(agent, Ctx),
        Owner = {agent_instance_ref, AgentNs, AgentAnchor, {human_user, test_agent}},
        {ok, [#{<<"V0">> := Scene}], _} = read(Ctx,
            editor_scope(LobbyNs, {world_view, personal_lobby, playing, {0}})),
        Other = start_namespace(OtherNs, Base#{
            data_dir => filename:join(Dir, "gallery"),
            genesis_diff => quod_prolog:terms_to_diff([
                {can_invoke, {'_'}, Owner, {'_'}, {'_'}},
                {world_view, gallery, playing, Scene}])}),
        try
            lists:foreach(fun({Ns, Space}) ->
                Anchor = quod_simplex:genesis_hash(Ns),
                Setup = editor_conjunction([
                    quod_ct:source_assertion({instance_of, space, Space}),
                    {assertz, {rendering_vocabulary, <<"lobby-test-rendering">>,
                               quod_simplex:genesis_hash(<<"lobby-test-rendering">>)}}] ++
                    case Ns of LobbyNs -> [quod_ct:source_assertion({instance_of, lobby, Space})]; _ -> [] end),
                commit_editor_goal(Ctx, editor_scope(Ns, Setup)),
                View = editor_scope(Ns, {client_world_view, Space, playing, [], {0}}),
                ?assertMatch({ok, [#{<<"V0">> := {world_view, _, [], unavailable}}], _},
                             read(Ctx, View)),
                Before = quod_prolog:applied(Ns),
                Edit = editor_scope(Ns, authored_space_composition_goal()),
                commit_editor_goal(Ctx, Edit),
                Expected = {world_view, {entity_ref, Ns, Anchor, Space}, Scene, nonphysical},
                ?assertMatch({ok, [#{<<"V0">> := Expected}], _}, read(Ctx, View)),
                ?assertEqual(Anchor, quod_simplex:genesis_hash(Ns)),
                ?assertEqual(Before + 1, quod_prolog:applied(Ns)),
                ?assertMatch({ok, _, {normalized, {failed, _}}}, submit(Ctx, execute, Edit)),
                ?assertEqual(Before + 1, quod_prolog:applied(Ns)),
                ?assertEqual(#{}, gen_server:call(quod_reg:via({quod_runtime, Ns}), physics_worlds))
            end, [{OtherNs, gallery}])
        after stop_process(element(1, Other)), stop(Ctx), file:del_dir_r(Dir) end
    end}.

authored_space_composition_goal() ->
    Terms = quod_prolog:read_terms(filename:join(code:priv_dir(quod), "ontologies/space.pl")),
    Heads = [case T of {':-', H, _} -> H; H -> H end || T <- Terms],
    Indicators = lists:usort([erlog_int:functor(H) || H <- Heads]),
    Checks = [{'$quod_predicate_source', {'/', F, A}, <<>>}
              || {F, A} <- Indicators, F =/= isa],
    Edges = [{'\\+', {clause, {isa, space, thing}, true}},
             {'\\+', {clause, {isa, physical_space, space}, true}}],
    Assertions = quod_ct:source_assertions(Terms),
    {transaction, balanced_space_goals(Checks ++ Edges ++ Assertions)}.

balanced_space_goals([G]) -> G;
balanced_space_goals(Gs) ->
    {Left, Right} = lists:split(length(Gs) div 2, Gs),
    {',', balanced_space_goals(Left), balanced_space_goals(Right)}.

inactive_physics_source_authoring_preserves_world_test_() ->
    {timeout, 300, fun() ->
        Dir = filename:join("/tmp", "quod-inactive-physics-authoring-" ++
                            integer_to_list(erlang:unique_integer([positive]))),
        Ctx = start(Dir),
        {ontology_ref, LobbyNs, _} = maps:get(lobby, Ctx),
        {_, Base} = maps:get(LobbyNs, maps:get(ontologies, Ctx)),
        {AgentNs, AgentAnchor} = maps:get(agent, Ctx),
        Owner = {agent_instance_ref, AgentNs, AgentAnchor, {human_user, test_agent}},
        OtherNs = <<"inactive-physics-gallery">>,
        {ok, [#{<<"V0">> := Scene}], _} = read(Ctx,
            editor_scope(LobbyNs, {world_view, personal_lobby, playing, {0}})),
        Other = start_namespace(OtherNs, Base#{
            data_dir => filename:join(Dir, "gallery"),
            genesis_diff => quod_prolog:terms_to_diff([
                {can_invoke, {'_'}, Owner, {'_'}, {'_'}},
                {world_view, gallery, playing, Scene}])}),
        ColdName = <<"authored_physics_", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
        ?assertError(badarg, binary_to_existing_atom(ColdName, utf8)),
        Sources = [begin
            {ok, Source} = file:read_file(filename:join(code:priv_dir(quod), "ontologies/" ++ File)),
            Source
        end || File <- ["agent_instance.pl", "quod_physics.pl", "quod_hinged.pl"]],
        Edits = source_predicate_drafts(iolist_to_binary(
            [Sources, "\n", ColdName, "(ready).\n"])),
        try
            lists:foreach(fun({Ns, Space, {Sup, Config}}) ->
                Anchor = quod_simplex:genesis_hash(Ns),
                Target = {ontology_ref, Ns, Anchor},
                Setup = editor_conjunction([
                    quod_ct:source_assertion({instance_of, space, Space}),
                    {assertz, {rendering_vocabulary, <<"lobby-test-rendering">>,
                               quod_simplex:genesis_hash(<<"lobby-test-rendering">>)}}] ++
                    case Ns of LobbyNs -> [quod_ct:source_assertion({instance_of, lobby, Space})]; _ -> [] end),
                commit_editor_goal(Ctx, editor_scope(Ns, Setup)),
                commit_editor_goal(Ctx, editor_scope(Ns, authored_space_composition_goal())),
                View = editor_scope(Ns, {client_world_view, Space, playing, [], {0}}),
                Expected = {world_view, {entity_ref, Ns, Anchor, Space}, Scene, nonphysical},
                Before = quod_prolog:applied(Ns),
                CheckInactive = fun() ->
                    ?assertMatch({ok, [#{<<"V0">> := Expected}], _}, read(Ctx, View)),
                    ?assertEqual(ok, quod_runtime:reconcile_resource(Ns, quod_prolog:applied(Ns),
                        agent_hosts, all, quod_time:mono_ms() + 10000)),
                    ?assertEqual(ok, quod_runtime:reconcile_resource(Ns, quod_prolog:applied(Ns),
                        physics_worlds, all, quod_time:mono_ms() + 10000)),
                    ?assertEqual(#{}, gen_server:call(quod_reg:via({quod_runtime, Ns}), physics_worlds)),
                    ?assertMatch({_, []}, quod_runtime:agents(Ns)),
                    ?assertMatch(#{resource_failures := Failures, reaction_failures := 0,
                                   reactions_executed := 0, reconcile_failures := 0}
                                 when map_size(Failures) =:= 0, quod_runtime:stats(Ns))
                end,
                Publish = fun({Indicator, Draft}) ->
                    Baseline = editor_source(Ctx, Target, Indicator),
                    ?assertEqual(<<>>, Baseline),
                    Edit = inactive_source_edit(
                        compile_source_edit(Ctx, Target, Indicator, Baseline, Draft)),
                    commit_editor_goal(Ctx, Edit),
                    ?assertEqual(Draft, editor_source(Ctx, Target, Indicator)),
                    CheckInactive()
                end,
                [First | Rest] = Edits,
                {Indicator, Draft} = First,
                Stale = inactive_source_edit(
                    compile_source_edit(Ctx, Target, Indicator, <<>>, Draft)),
                OtherOwner = Ctx#{instance => <<"human_user(other_agent).">>},
                assert_editor_refusal(OtherOwner, Stale, {not_allowed, Ns}),
                Publish(First),
                assert_editor_refusal(Ctx, Stale, {edit_conflict, Indicator}),
                {Part, Remaining} = lists:split(length(Rest) div 2, Rest),
                lists:foreach(Publish, Part),
                Partial = complete_source(Ctx, Target),
                PartialHeight = quod_prolog:applied(Ns),
                stop_process(Sup),
                {Resumed, _} = start_namespace(Ns, Config#{mode => join, genesis_hash => Anchor}),
                try
                    ?assertEqual(PartialHeight, quod_prolog:applied(Ns)),
                    ?assertEqual(Partial, complete_source(Ctx, Target)),
                    CheckInactive(),
                    lists:foreach(Publish, Remaining),
                    ?assertEqual(Anchor, quod_simplex:genesis_hash(Ns)),
                    ?assertEqual(Before + length(Edits), quod_prolog:applied(Ns)),
                    Cold = binary_to_existing_atom(ColdName, utf8),
                    ?assertMatch({ok, [#{}], _}, read(Ctx, editor_scope(Ns, {Cold, ready}))),
                    Complete = complete_source(Ctx, Target),
                    assert_repeat_source_has_no_io(Ctx, Target, Complete),
                    stop_process(Resumed),
                    {FinalBoot, _} = start_namespace(Ns, Config#{mode => join, genesis_hash => Anchor}),
                    try
                        ?assertEqual(Before + length(Edits), quod_prolog:applied(Ns)),
                        ?assertEqual(Complete, complete_source(Ctx, Target)),
                        CheckInactive(),
                        assert_repeat_source_has_no_io(Ctx, Target, Complete)
                    after stop_process(FinalBoot) end
                after stop_process(Resumed) end
            end, [{OtherNs, gallery, Other}])
        after stop_process(element(1, Other)), stop(Ctx), file:del_dir_r(Dir) end
    end}.

inactive_source_edit({'::', Ns, {',', Identity, {transaction, Edit}}}) ->
    %% Callable guards enter normal target symbol admission and capture even
    %% absent predicates. Cold source introspection alone records no read.
    Guards = [{'\\+', {physics_space, {'_'}, {'_'}, {'_'}}},
              {'\\+', {agent_host, {'_'}, {'_'}, {'_'}, {'_'}}},
              {'$quod_predicate_source', {'/', physics_space, 3}, <<>>},
              {'$quod_predicate_source', {'/', agent_host, 4}, <<>>}],
    {'::', Ns, {',', Identity, {transaction, editor_conjunction(Guards ++ [Edit])}}}.

assert_editor_refusal(Ctx, Goal, Reason) ->
    {ok, _, {normalized, {failed, Encoded}}} = submit(Ctx, execute, Goal),
    {ok, Reasons} = quod_wire_term:decode_failure_reasons(Encoded),
    ?assert(lists:member(quod_wire_term:encode_canonical(Reason),
                         [quod_wire_term:encode_canonical(R) || R <- Reasons])).

source_predicate_drafts(Source) ->
    {ok, Program} = quod_client_goal_parser:parse_program(Source, 3),
    Groups = lists:foldl(fun(#{goal := Clause}, Acc) ->
        Head = case Clause of {':-', H, _} -> H; _ -> Clause end,
        {ok, {Name, Arity}} = quod_wire_term:callable_functor(Head),
        Indicator = {'/', Name, Arity},
        {ok, Key} = quod_wire_term:encode_canonical(Indicator),
        Rule = case Clause of {':-', _, _} -> Clause; _ -> {':-', Clause, true} end,
        {Canonical, _, _} = erlog_int:term_instance(Rule, 0),
        {ok, Text} = quod_client_goal_parser:format_clause(Canonical),
        maps:update_with(Key, fun({I, Parts}) -> {I, [Parts, Text, $\n]} end,
                         {Indicator, [Text, $\n]}, Acc)
    end, #{}, Program),
    Drafts = [{Indicator, iolist_to_binary(Parts)}
              || {_, {Indicator, Parts}} <- lists:sort(maps:to_list(Groups))],
    %% Publishing a selector makes it callable by the current runtime, even
    %% with no configured space. Its helpers must already be complete.
    EntryPoints = [<<"agent_hosting_projection">>, <<"physics_projection">>, <<"react_on">>],
    {Helpers, Entries} = lists:partition(fun({{'/', Name, _}, _}) ->
        {ok, [Symbol]} = quod_wire_term:symbol_names(Name),
        not lists:member(Symbol, EntryPoints)
    end, Drafts),
    Helpers ++ Entries.

incomplete_hosting_selector_is_not_inactive_test_() ->
    {timeout, 60, fun() ->
        Dir = filename:join("/tmp", "quod-incomplete-selector-" ++
                            integer_to_list(erlang:unique_integer([positive]))),
        Ctx = start(Dir),
        try
            {ontology_ref, Ns, _} = Target = maps:get(lobby, Ctx),
            {ok, Source} = file:read_file(filename:join(code:priv_dir(quod),
                                                       "ontologies/agent_instance.pl")),
            [{Indicator, Draft}] = [D || D = {{'/', {'$quod_symbol',
                <<"agent_hosting_projection">>}, 4}, _} <- source_predicate_drafts(Source)],
            commit_editor_goal(Ctx, inactive_source_edit(
                compile_source_edit(Ctx, Target, Indicator, <<>>, Draft))),
            ?assertEqual({error, {resource_selection_failed,
                                  {no_solution, {agent_hosting_projection, 4}}}},
                quod_runtime:reconcile_resource(Ns, quod_prolog:applied(Ns),
                    agent_hosts, all, quod_time:mono_ms() + 10000))
        after stop(Ctx), file:del_dir_r(Dir) end
    end}.

physics_reactions_ignore_domain_notices_test() ->
    Terms = lists:append([quod_prolog:read_terms(filename:join(code:priv_dir(quod),
        "ontologies/" ++ File)) || File <- ["quod_physics.pl", "quod_hinged.pl"]]),
    Reactions = [T || T = {':-', {react_on, _, _}, _} <- Terms],
    Binding = #{reference => {agent_instance_ref, <<"inactive-physics">>, <<1:256>>, observer},
                epoch => 1, public_key => <<2:256>>, request_timeout_ms => 1000},
    ?assertEqual(2, length(Reactions)),
    lists:foreach(fun(Reaction) ->
        ?assertEqual(unmatched, quod_runtime_predicates:run_reaction(
            <<"inactive-physics">>, 1, Binding, Reaction, {observed, {ready, ontology, all}},
            quod_committed_projection:new_est()))
    end, Reactions).

lobby_projection_recovery_test_() ->
    {timeout, 90, fun() ->
        Dir = filename:join("/tmp", "quod-lobby-" ++ integer_to_list(erlang:unique_integer([positive]))),
        Ctx = start(Dir),
        try
            Ref = maps:get(lobby, Ctx),
            {ok, [#{<<"V0">> := Ref}], _} = read(Ctx, {lobby_reference, {0}}),
            {ontology_ref, Ns, Anchor} = Ref,
            Goal = {'::', Ns, {',', {current_ontology_identity, Ns, Anchor},
                                    {world_view, personal_lobby, playing, {0}}}},
            {ok, [#{<<"V0">> := Scene}], _} = read(Ctx, Goal),
            ?assertEqual(8, length(Scene)),
            ?assertMatch({mark, <<"floor/model">>, <<"mesh">>,
                          {mesh_asset, {asset,
                              <<"766c7015b7281f6009838145a06ae8c8b61c37bfc6116be16aaeaba1d8b817ee">>, _}, _,
                           {scale, 1000}, {frame, {aabb, -9000, -570, -9000, 9000, 1000, 9000},
                            {pivot, 0, 0, 0}, _}, _},
                          {relative,<<"floor">>,{transform, 0, 0, 0, 0, 0, 0}}, asset_surfaces, unlabelled, depicts_nothing},
                         lists:keyfind(<<"floor/model">>, 2, Scene)),
            ?assertMatch({mark,<<"floor">>,<<"group">>,[],_,_,_,{depicts,Ns,Anchor,floor}},
                         lists:keyfind(<<"floor">>,2,Scene)),
            ?assertMatch({mark, <<"roof">>, <<"group">>, [], _, _, _,
                          {depicts, Ns, Anchor, personal_roof}}, lists:keyfind(<<"roof">>, 2, Scene)),
            RoofModel = lists:keyfind(<<"roof/model">>, 2, Scene),
            ?assertMatch({mark, <<"roof/model">>, <<"mesh">>,
                          {mesh_asset, {asset,
                              <<"e2342ad365f644003e22372f41a25e833541c6c30b314ac539534e5c3a077121">>, _}, _,
                           {scale, 1000}, _, _},
                          {relative, <<"roof">>, _}, asset_surfaces, unlabelled, depicts_nothing}, RoofModel),
            {ok, [#{<<"V0">> := Edition}], _} = read(Ctx,
                {'::', Ns, {',', {current_ontology_identity, Ns, Anchor}, {world_view, personal_lobby, edition, {0}}}}),
            ?assertEqual(RoofModel, lists:keyfind(<<"roof/model">>, 2, Edition)),
            ?assertMatch({mark, <<"sky/sky">>, <<"sky_sphere">>,
                          [{f, <<"diameter">>, 80000}],
                          {relative,<<"sky">>,{transform, 0, 0, 0, 0, 75, 0}}, _, unlabelled,
                          {depicts, Ns, Anchor, personal_sky}},
                         lists:keyfind(<<"sky/sky">>, 2, Scene)),
            ?assert(lists:member({mark, <<"console">>, <<"group">>, [],
               {transform, 0, 0, 3850, 0, 0, 0}, no_surface, unlabelled,
               {depicts, Ns, Anchor, console}}, Scene)),
            ?assertMatch({mark, <<"console/model">>, <<"mesh">>,
                          {mesh_asset, {asset,
                              <<"2be70465da809e6e29b8b12aae01a568e54cd150e86f35f790e06a61fc82bc04">>,
                              <<"model/gltf-binary">>}, <<"gltf2-static-v1">>,
                           {scale, 1000},
                           {frame, {aabb, -921, -929, -898, 881, 904, 894},
                            {pivot, 0, -929, 0}, {front, <<"-z">>}},
                           {resources, 5357484, 1227580, 31379, 50000, 1, 1, 4194304}},
                          {relative, <<"console">>, _}, asset_surfaces,
                          {label, <<"PROLOG CONSOLE">>, <<"above">>}, depicts_nothing},
                         lists:keyfind(<<"console/model">>, 2, Scene)),
            %% Expected identity is proved before any scene content is selected.
            ?assertMatch({fail, _}, read(Ctx, {'::', Ns,
                {',', {current_ontology_identity, Ns, <<0:256>>},
                      {world_view, personal_lobby, playing, {0}}}})),
            {ok, [#{<<"V0">> := {component, workspace, form, _, Components}}], _} = read(Ctx,
                {'::', Ns, {lobby_workspace, console, proof_console, {0}}}),
            ?assertEqual([editor, bindings, button, button, button, button, button],
                         [element(3, Component) || Component <- Components]),
            ?assertMatch({ok, [#{<<"V0">> := [{menu_entry, my_worlds, _, _},{menu_entry, prove_goal, _, _}]}], _},
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
            ?assertMatch({mark, <<"sky/sky">>, <<"sky_sphere">>, _,
                          {relative,<<"sky">>,{transform, 0, 0, 0, 0, 215, 0}}, _, _, _},
                         lists:keyfind(<<"sky/sky">>, 2, ChangedScene)),
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
            lists:foreach(fun(Name) ->
                ?assertMatch({ok, [#{<<"V0">> := prolog_console}], _},
                    read(Ctx, Scope({vocabulary_class, Name, <<"quod:lobby">>, {0}})))
            end, [{':', quod, {':', lobby, prolog_console}},
                  {':', {':', quod, lobby}, prolog_console}]),
            {ok, [#{<<"V0">> := Scene}], _} = read(Ctx, Scope({world_view, personal_lobby, playing, {0}})),
            {ok, [#{<<"V0">> := Menu}], _} = read(Ctx, Scope({lobby_menu, console, {0}})),
            {ok, [#{<<"V0">> := View}], _} = read(Ctx, Scope({lobby_workspace, console, proof_console, {0}})),
            Edit = {',', {retract, {instance_of, prolog_console, console}},
                    {',', quod_ct:source_assertion({instance_of, smart_console, console}),
                     {',', quod_ct:source_assertion({instance_of, device, console}),
                           {assertz, {isa, smart_console, prolog_console}}}}},
            ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                         submit(Ctx, execute, Scope(Edit))),
            ?assertMatch({ok, [#{<<"V0">> := Scene}], _},
                         read(Ctx, Scope({world_view, personal_lobby, playing, {0}}))),
            ?assertMatch({ok, [#{<<"V0">> := Menu}], _},
                         read(Ctx, Scope({lobby_menu, console, {0}}))),
            ?assertMatch({ok, [#{<<"V0">> := View}], _},
                         read(Ctx, Scope({lobby_workspace, console, proof_console, {0}}))),
            {ok, [#{<<"V0">> := [{eidolon,playing,solid,Recipe}]}], _} = read(Ctx,
                Scope({entity_eidolons, console, playing, solid, {0}})),
            ?assertMatch({recipe, <<"lobby-test-classes">>, _, console_playing}, Recipe),
            %% The normal qualified class reference has the same behavior;
            %% its namespace is resolved only through this pinned vocabulary.
            Qualify = {',', {retract, {isa, smart_console, prolog_console}},
                           {assertz, {isa, smart_console,
                                     {':', <<"lobby-test-classes">>, prolog_console}}}},
            ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                         submit(Ctx, execute, Scope(Qualify))),
            ?assertMatch({ok, [#{<<"V0">> := Scene}], _},
                         read(Ctx, Scope({world_view, personal_lobby, playing, {0}}))),
            ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                submit(Ctx, execute, Scope({assertz, {isa, smart_console, diagnostic_console}}))),
            {ok, [#{<<"V0">> := Choices}], _} = read(Ctx,
                Scope({entity_eidolons, console, playing, solid, {0}})),
            ?assertEqual([console_edition, console_playing],
                         [Id || {eidolon,playing,solid,{recipe, <<"lobby-test-classes">>, _, Id}} <- Choices]),
            %% An unresolved choice affects this device, not the entire world.
            {ok, [#{<<"V0">> := Ambiguous}], _} = read(Ctx, Scope({world_view, personal_lobby, playing, {0}})),
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
                {',', {current_ontology_identity, Ns, Anchor}, {world_view, personal_lobby, playing, {0}}}})}
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
                        [_,_,_,_,_,_,_,_]}], _}, Result)
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
            Mesh = {mesh_asset,
                {asset, <<"ad1f1cbe8c100fd774e315b629d0bb1082820c9a7abe2a2a999aef846d675064">>,
                 <<"model/gltf-binary">>}, <<"gltf2-static-v1">>, {scale, 1000},
                {frame, {aabb, -300, 0, -400, 1200, 1400, 300},
                 {pivot, 200, 0, -100}, {front, <<"+x">>}},
                {resources, 8000000, 16000000, 250000, 250000, 1024, 256, 16000000}},
            {ontology_ref, MeshLobbyNs, MeshLobbyAnchor} = maps:get(lobby, Ctx),
            Subject = {depicts, MeshLobbyNs, MeshLobbyAnchor, console},
            MeshParts = [{part, <<"imported">>, Mesh, At, asset_surfaces,
                          {label, <<"asset">>, <<"above">>}, depicts_nothing}],
            {ok, [#{<<"V0">> := First}], _} = Ask(ModelNs,
                {place_model, <<"first">>, {transform, 0, 0, 0, 0, 90, 0},
                 Subject, MeshParts, {0}}),
            {ok, [#{<<"V0">> := Second}], _} = Ask(ModelNs,
                {place_model, <<"second">>, {transform, 2000, 0, 0, 0, 270, 0},
                 Subject, MeshParts, {0}}),
            {ok, [#{<<"V0">> := MeshScene}], _} = Ask(ModelNs,
                {model, First ++ Second, {0}}),
            ?assertEqual([<<"first">>, <<"first/imported">>, <<"second">>,
                          <<"second/imported">>],
                         [element(2, Mark) || Mark <- MeshScene]),
            ?assertEqual(Subject, element(8, hd(MeshScene))),
            ?assertEqual(Mesh, element(4, lists:nth(2, MeshScene))),
            ClassNsMesh = <<"lobby-test-classes">>,
            ?assertMatch({ok, [#{<<"V0">> := [{eidolon,playing,solid,{recipe, ClassNsMesh, _, imported_artifact_playing}}]}], _},
                Ask(ClassNsMesh, {class_eidolons, [imported_artifact], playing, solid, {0}})),
            {ok, [#{<<"V0">> := SampleParts}], _} = Ask(ClassNsMesh,
                {eidolon, imported_artifact_playing, {device, artifact}, {0}}),
            {ok, [#{<<"V0">> := SamplePlaced}], _} = Ask(ModelNs,
                {place_model, <<"sample">>, At, Subject, SampleParts, {0}}),
            ?assertMatch({ok, [#{<<"V0">> := [{mark, <<"sample">>, _, _, _, _, _, _},
                                             {mark, <<"sample/model">>, <<"mesh">>, _, _,
                                              asset_surfaces, _, _}]}], _},
                Ask(ModelNs, {model, SamplePlaced, {0}})),
            {ok, [#{<<"V0">> := MeshAt}], _} = Ask(ModelNs,
                {align, Mesh, centre, {box, 1200, 800, 200}, front, 5, {0}}),
            ?assertEqual({transform, -50, -700, 145, 0, 0, 0}, MeshAt),
            OtherViewer = Ctx#{instance => <<"human_user(other_agent).">>},
            ?assertMatch({fail, _}, read(OtherViewer,
                {'::', MeshLobbyNs,
                 {',', {current_ontology_identity, MeshLobbyNs, MeshLobbyAnchor},
                  {world_view, personal_lobby, playing, {0}}}})),
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
            {ok, [#{<<"V0">> := Playing}], _} = Ask(LobbyNs, {world_view, personal_lobby, playing, {0}}),
            {ok, [#{<<"V0">> := Edition}], _} = Ask(LobbyNs, {world_view, personal_lobby, edition, {0}}),
            ?assertNotEqual(Playing, Edition),
            ?assertMatch({mark, <<"console/model">>, <<"mesh">>, _, _, _, _, _},
                         lists:keyfind(<<"console/model">>, 2, Playing)),
            ?assertMatch({mark, <<"console/screen">>, <<"plane">>, _, _, _, _, _},
                         lists:keyfind(<<"console/screen">>, 2, Edition))
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
                Scope(Ns, {entity_eidolons, Target, {0}})),
            ?assert(lists:member(CodeEidolon, OntologyChoices)),
            ?assertMatch({ok, [#{<<"V0">> := [{menu_entry, my_worlds, _, _},{menu_entry, prove_goal, _, _}]}], _},
                         read(Ctx, Scope(Ns, {lobby_menu, console, {0}}))),
            Tools = <<"quod:prolog">>,
            ToolsAnchor = quod_simplex:genesis_hash(Tools),
            {ok, [#{<<"V0">> := Workspace}], _} = read(Ctx, Scope(RecipeNs,
                {eidolon, prolog_editor, {subject, Target, console}, {0}})),
            ?assertMatch({workspace, Target, console, {ontology_ref, Tools, ToolsAnchor},
                          {component, workspace, form, _,
                           [{component, predicate, catalogue_selection, _, []},
                            {component, new_predicate, text_box, _, []},
                            {component, source, editor, _, []} | _]}},
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

complete_source_cursor_retains_current_snapshot_test_() ->
    {timeout, 120, fun() ->
        Dir = filename:join("/tmp", "quod-current-source-" ++
                           integer_to_list(erlang:unique_integer([positive]))),
        Ctx = start(Dir, [], extended_system_catalogue),
        try
            RootNs = quod_ontology:root_ns(),
            {AgentNs, AgentAnchor} = maps:get(agent, Ctx),
            Owner = {agent_instance_ref, AgentNs, AgentAnchor, {human_user, test_agent}},
            ?assertMatch({ok, _, _}, quod_prolog:execute(RootNs,
                {assertz, {root_administrator_agent, Owner}})),
            Reader = Ctx#{instance => <<"human_user(other_agent).">>},
            Target = system_target(<<"quod:node">>),
            LensTarget = system_target(<<"quod:lens">>),
            LensIndicator = {'/', source_chunk_bytes, 1},
            ok = commit_editor_goal(Ctx, compile_source_edit(Ctx, LensTarget, LensIndicator,
                editor_source(Ctx, LensTarget, LensIndicator), <<"source_chunk_bytes(4096).">>)),
            %% A real signed administrator edit supplies a fact to retract.
            Old = <<"inspection_marker(old) :- true.\n">>,
            New = <<"inspection_marker(new) :- true.\n">>,
            Indicator = {'/', inspection_marker, 1},
            Edit = compile_source_edit(Ctx, Target, Indicator, <<>>, Old),
            ok = commit_editor_goal(Ctx, Edit),
            Before = complete_source(Reader, Target),
            ?assertNotEqual(nomatch, binary:match(Before, Old)),
            ?assertNotEqual(nomatch, binary:match(Before, <<"can_invoke(">>)),
            ?assertNotEqual(nomatch, binary:match(Before, <<"ontology_hosting_allowed(">>)),
            ?assertNotEqual(nomatch, binary:match(Before, <<"'$quod_known_class'">>)),
            %% Freeze a cursor, then assert/retract while its first chunk is
            %% suspended. Every remaining chunk must still be from Before.
            Query = editor_scope(<<"quod:prolog">>, {prolog_source, Target, {0}}),
            {CursorOwner, Id, Evidence, First} = open_source_cursor(Reader, Query),
            ?assertMatch({source_chunk, more, _}, First),
            Change = compile_source_edit(Ctx, Target, Indicator, Old, New),
            ok = commit_editor_goal(Ctx, Change),
            ?assertEqual(Before, finish_source(CursorOwner, Id, Evidence, First, [])),
            After = complete_source(Reader, Target),
            ?assertEqual(binary:replace(Before, Old, New), After),
            %% The explicit lens narrows only its view, not target access.
            ?assertEqual(New, editor_source(Reader, Target, Indicator)),
            ?assertMatch({fail, _}, read(Reader,
                editor_scope(<<"quod:node">>, {inspection_marker, new}))),
            assert_repeat_source_has_no_io(Reader, Target, After),
            {NodeSup, NodeConfig} = maps:get(<<"quod:node">>, maps:get(ontologies, Ctx)),
            {ontology_ref, NodeNs, NodeAnchor} = Target,
            stop_process(NodeSup),
            {Resumed, _} = start_namespace(NodeNs,
                NodeConfig#{mode => join, genesis_hash => NodeAnchor}),
            try
                ?assertEqual(After, complete_source(Reader, Target)),
                ?assertMatch({fail, _}, read(Reader, editor_scope(<<"quod:prolog">>,
                    {prolog_source, maps:get(lobby, Ctx), {0}}))),
                ?assertMatch({fail, _}, read(Reader, editor_scope(<<"quod:prolog">>,
                    {prolog_source, {ontology_ref, NodeNs, <<0:256>>}, {0}})))
            after stop_process(Resumed) end
        after stop(Ctx), file:del_dir_r(Dir) end
    end}.

complete_source(Ctx, Target) ->
    complete_text(Ctx, editor_scope(<<"quod:prolog">>, {prolog_source, Target, {0}})).

complete_inspection(Ctx, Target, Lens) ->
    complete_text(Ctx, editor_scope(<<"quod:lens">>, {view, Lens, [Target], {0}})).

complete_text(Ctx, Query) ->
    {Owner, Id, Evidence, First} = open_source_cursor(Ctx, Query),
    finish_source(Owner, Id, Evidence, First, []).

ontology_instances_share_selection_and_authorized_inspection_test_() ->
    {timeout, 120, fun() ->
        Dir = filename:join("/tmp", "quod-ontology-inspection-" ++
                            integer_to_list(erlang:unique_integer([positive]))),
        Ctx = start(Dir, [], extended_system_catalogue),
        try
            {ontology_ref, Ns, Anchor} = Target = maps:get(lobby, Ctx),
            Reader = Ctx#{instance => <<"human_user(other_agent).">>},
            Tools = <<"quod:prolog">>, Recipe = <<"quod:prolog:eidolons">>,
            ?assertMatch({ok, _, _}, read(Ctx,
                editor_scope(Ns, {instance_of, ontology, Target}))),
            ?assertMatch({fail, _}, read(Ctx, editor_scope(Ns, {isa, ontology, space}))),
            {ok, [#{<<"V0">> := OwnedChoices}], _} = read(Ctx,
                editor_scope(Ns, {entity_eidolons, Target, {0}})),
            System = system_target(<<"quod:prolog">>),
            {ok, [#{<<"V0">> := OwnedChoices}], _} = read(Ctx,
                editor_scope(<<"quod:prolog">>, {entity_eidolons, System, {0}})),
            ?assertEqual(4, length(OwnedChoices)),
            ?assertMatch({fail, _}, read(Reader,
                editor_scope(Ns, {entity_eidolons, Target, {0}}))),
            ?assertMatch({fail, _}, read(Ctx, {'::', Ns,
                {',', {current_ontology_identity, Ns, <<0:256>>},
                 {entity_eidolons, Target, {0}}}})),
            lists:foreach(fun(Style) ->
                ?assertMatch({ok, [#{<<"V0">> := {lens_view, Target, Target, _, _, [Target]}}], _},
                    read(Ctx, editor_scope(Recipe, {eidolon, Style, {subject, Target, Target}, {0}}))),
                ?assertMatch({fail, _}, read(Reader,
                    editor_scope(Recipe, {eidolon, Style, {subject, Target, Target}, {0}}))),
                Bad = {ontology_ref, Ns, <<0:256>>},
                ?assertMatch({fail, _}, read(Ctx,
                    editor_scope(Recipe, {eidolon, Style, {subject, Bad, Bad}, {0}})))
            end, [policy, interfaces, routes]),
            Policy = complete_inspection(Ctx, Target, <<"ontology_policy">>),
            ?assertNotEqual(nomatch, binary:match(Policy, <<"can_invoke(">>)),
            ?assertEqual(<<>>, complete_inspection(Ctx, Target, <<"ontology_interfaces">>)),
            Interfaces = complete_inspection(Ctx, System, <<"ontology_interfaces">>),
            ?assertNotEqual(nomatch, binary:match(Interfaces, <<"ontology_interface(">>)),
            ?assertEqual(nomatch, binary:match(Interfaces, <<"prolog_query(">>)),
            LensInterfaces = complete_inspection(Ctx, system_target(<<"quod:lens">>), <<"ontology_interfaces">>),
            ?assertNotEqual(nomatch, binary:match(LensInterfaces, <<"authored lens selection">>)),
            RouteStatus = complete_inspection(Ctx, Target, <<"ontology_routes">>),
            assert_read_has_no_io(fun() ->
                ?assertEqual(Policy, complete_inspection(Ctx, Target, <<"ontology_policy">>)),
                ?assertEqual(Policy, complete_inspection(Ctx, Target, <<"ontology_policy">>)),
                ?assertEqual(Interfaces, complete_inspection(Ctx, System, <<"ontology_interfaces">>)),
                ?assertEqual(RouteStatus, complete_inspection(Ctx, Target, <<"ontology_routes">>))
            end),
            %% Readable ACL rules are not a grant to edit those rules.
            Indicator = {'/', can_invoke, 4},
            SystemBefore = editor_source(Ctx, System, Indicator),
            SystemEdit = compile_source_edit(Ctx, System, Indicator, SystemBefore,
                <<SystemBefore/binary, "can_invoke(_, _, _, _).\n">>),
            ?assertMatch({ok, _, {normalized, {failed, _}}}, submit(Ctx, execute, SystemEdit)),
            ?assertEqual(SystemBefore, editor_source(Ctx, System, Indicator)),
            Before = editor_source(Ctx, Target, Indicator),
            Edit = compile_source_edit(Ctx, Target, Indicator, Before,
                <<Before/binary, "can_invoke(custom_query, unrelated, [], custom_namespace).\n">>),
            ?assertMatch({ok, _, {normalized, {failed, _}}}, submit(Reader, execute, Edit)),
            commit_editor_goal(Ctx, Edit),
            Changed = complete_inspection(Ctx, Target, <<"ontology_policy">>),
            ?assertNotEqual(nomatch, binary:match(Changed, <<"custom_query">>)),
            ?assertNotEqual(nomatch, binary:match(complete_source(Ctx, Target), Changed)),
            %% A previously editable presentation and compiled edit confer no
            %% future authority after the real owner changes.
            ?assertMatch({ok, [#{<<"V0">> := editable}], _}, read(Ctx,
                editor_scope(Tools, {prolog_inspect, Target, presentation, {0}}))),
            Stale = compile_source_edit(Ctx, Target, {'/', stale_edit, 1}, <<>>, <<"stale_edit(forbidden).">>),
            {AgentNs, AgentAnchor} = maps:get(agent, Ctx),
            Owner = {agent_instance_ref, AgentNs, AgentAnchor, {human_user, other_agent}},
            {ok, OwnerSource} = quod_client_goal_parser:format_clause({lobby_owner, Owner}),
            commit_editor_goal(Ctx, compile_source_edit(Ctx, Target, {'/', lobby_owner, 1},
                editor_source(Ctx, Target, {'/', lobby_owner, 1}), OwnerSource)),
            ?assertMatch({ok, _, {normalized, {failed, _}}}, submit(Ctx, execute, Stale)),
            ?assertEqual(<<>>, editor_source(Reader, Target, {'/', stale_edit, 1})),
            ?assertMatch({fail, _}, read(Ctx,
                editor_scope(Tools, {prolog_inspect, Target, presentation, {0}}))),
            ?assertEqual(Anchor, quod_simplex:genesis_hash(Ns))
        after stop(Ctx), file:del_dir_r(Dir) end
    end}.

presentation_modes_and_ground_lens_targets_use_authorized_owner_reads_test_() ->
    {timeout, 120, fun() ->
        Dir = filename:join("/tmp", "quod-ontology-modes-" ++
                            integer_to_list(erlang:unique_integer([positive]))),
        Ctx = start(Dir),
        try
            {ontology_ref, _, _} = Target = maps:get(lobby, Ctx),
            Recipe = <<"quod:prolog:eidolons">>,
            Workspace = editor_scope(Recipe, {eidolon, prolog_editor, {subject, Target, Target}, {0}}),
            Source = editor_source(Ctx, Target, {'/', ontology_source_mode, 1}),
            Duplicate = <<Source/binary, "ontology_source_mode(editable).\n">>,
            commit_editor_goal(Ctx, compile_source_edit(Ctx, Target, {'/', ontology_source_mode, 1}, Source, Duplicate)),
            ?assertMatch({ok, [#{<<"V0">> := {workspace, Target, Target, _,
                {component, workspace, form, _, [_, {component, new_predicate, _, _, _} | _]}}}], _},
                read(Ctx, Workspace)),
            lists:foreach(fun(BadSource) ->
                Baseline = editor_source(Ctx, Target, {'/', ontology_source_mode, 1}),
                commit_editor_goal(Ctx, compile_source_edit(Ctx, Target, {'/', ontology_source_mode, 1}, Baseline, BadSource)),
                ?assertMatch({fail, _}, read(Ctx, Workspace))
            end, [<<Source/binary, "ontology_source_mode(read_only).\n">>,
                  <<"ontology_source_mode(invalid).">>, <<"ontology_source_mode(_).">>]),
            ?assertMatch({fail, _}, read(Ctx, editor_scope(Recipe,
                {eidolon, policy, {subject, {0}, {0}}, {1}}))),
            System = system_target(<<"quod:prolog">>),
            ?assertNotEqual(nomatch, binary:match(complete_inspection(Ctx, System, <<"ontology_routes">>), <<"route_status(live,">>)),
            RootNs = quod_ontology:root_ns(),
            {AgentNs, AgentAnchor} = maps:get(agent, Ctx),
            Owner = {agent_instance_ref, AgentNs, AgentAnchor, {human_user, test_agent}},
            ?assertMatch({ok, _, _}, quod_prolog:execute(RootNs, {assertz, {root_administrator_agent, Owner}})),
            ?assertNotEqual(nomatch, binary:match(complete_inspection(Ctx, system_target(RootNs), <<"ontology_routes">>), <<"route_status(live,">>)),
            ?assertMatch({ok, [#{<<"V0">> := editable}], _}, read(Ctx, editor_scope(<<"quod:prolog">>,
                {prolog_inspect, system_target(RootNs), presentation, {0}})))
        after stop(Ctx), file:del_dir_r(Dir) end
    end}.

finish_source(Owner, Id, Evidence, {source_chunk, done, Text}, Chunks) ->
    ?assertMatch({ok, Evidence, _}, quod_client_cursor:command(Owner, Id, stop)),
    iolist_to_binary(lists:reverse([Text | Chunks]));
finish_source(Owner, Id, Evidence, {source_chunk, more, Text}, Chunks) ->
    {ok, Evidence, Raw} = quod_client_cursor:command(Owner, Id, next),
    {solution, Id, _, Blob} = quod_client_result:normalize(Evidence, Raw),
    {ok, [{<<"V0">>, Chunk}]} = quod_client_result:decode_binding(Blob),
    finish_source(Owner, Id, Evidence, Chunk, [Text | Chunks]).

assert_repeat_source_has_no_io(Ctx, Target, Expected) ->
    assert_read_has_no_io(fun() ->
        ?assertEqual(Expected, complete_source(Ctx, Target)),
        ?assertEqual(Expected, complete_source(Ctx, Target))
    end).

assert_read_has_no_io(Check) ->
    Parent = self(), Tag = make_ref(),
    Tracer = spawn_link(fun() -> source_trace_relay(Parent, Tag) end),
    Trace = trace:session_create(source_read_test, Tracer, []),
    MFAs = [{quod_committed_projection, new, 5},
            {quod_committed_projection, read_terms, 1}, {quod_committed_projection, new_est, 0},
            {quod_simplex, history_view, 3}, {quod_ledger_store, open_ro_snapshot, 1},
            {quod_ledger_store, read_at, 2}, {file, write, 2}, {file, pwrite, 3},
            {file, write_file, 2}, {file, write_file, 3}, {file, sync, 1}, {file, datasync, 1}],
    [trace:function(Trace, MFA, [{'_', [], [{message, {caller}}]}], [local]) || MFA <- MFAs],
    trace:process(Trace, all, true, [call]),
    try
        Check(),
        Ref = trace:delivered(Trace, all),
        receive {trace_delivered, all, Ref} -> ok after 10000 -> error(trace_timeout) end,
        Tracer ! {barrier, Ref},
        receive {Tag, barrier, Ref} -> ok after 10000 -> error(trace_barrier_timeout) end,
        Calls = source_io_calls(Tag, []),
        ?assertEqual([], Calls)
    after trace:session_destroy(Trace), Tracer ! stop end.

source_trace_relay(Parent, Tag) ->
    receive
        {barrier, Ref} -> Parent ! {Tag, barrier, Ref}, source_trace_relay(Parent, Tag);
        stop -> ok;
        Message -> Parent ! {Tag, Message}, source_trace_relay(Parent, Tag)
    end.

source_io_calls(Tag, Calls) ->
    receive {Tag, {trace, Pid, call, {M, F, Args}, Caller}} ->
        %% Keep ownership and caller attribution if background durability
        %% overlaps a read. The zero-work assertion still covers every call.
        Names = gproc:info(Pid, gproc),
        source_io_calls(Tag, [{Pid, {M, F, length(Args)}, Caller, Names} | Calls])
    after 0 -> Calls end.

public_system_ontology_source_is_readable_but_not_mutable_test_() ->
    {timeout, 90, fun() ->
        Dir = filename:join("/tmp", "quod-public-system-source-" ++
                                   integer_to_list(erlang:unique_integer([positive]))),
        Ctx = start(Dir, [], extended_system_catalogue),
        try
            Tools = <<"quod:prolog">>,
            Recipe = <<"quod:prolog:eidolons">>,
            Targets = [{<<"quod:modelling">>, {'/', model, 2}},
                       {<<"quod:rendering">>, {'/', mark_kind, 1}},
                       {<<"quod:material">>, {'/', material_class, 1}},
                       {<<"quod:measure">>, {'/', convert, 4}},
                       {<<"quod:environment">>, {'/', isa, 2}},
                       {<<"quod:environment:eidolons">>, {'/', panorama_asset, 3}},
                       {<<"quod:material:eidolons">>, {'/', texture_asset, 4}},
                       {<<"quod:gui">>, {'/', gui_view, 2}},
                       {<<"quod:prolog">>, {'/', prolog_predicates, 2}},
                       {<<"quod:prolog:eidolons">>, {'/', eidolon, 3}},
                       {<<"quod:agent">>, {'/', isa, 2}},
                       {<<"quod:human_user">>, {'/', isa, 2}},
                       {<<"quod:lens">>, {'/', lens, 2}},
                       {<<"quod:licence">>, {'/', family, 1}},
                       {<<"quod:lobby">>, {'/', lobby_definitions, 1}},
                       {<<"quod:names">>, {'/', count, 4}},
                       {<<"quod:node">>, {'/', isa, 2}}],
            lists:foreach(fun({Ns, Indicator}) ->
                Target = system_target(Ns),
                {ok, [#{<<"V0">> := Choices}], _} = read(Ctx,
                    editor_scope(Ns, {entity_eidolons, Target, {0}})),
                ?assert(lists:any(fun({eidolon, prolog, source, _}) -> true;
                                     (_) -> false
                                  end, Choices)),
                {ok, [#{<<"V0">> := Workspace}], _} = read(Ctx,
                    editor_scope(Recipe,
                        {eidolon, prolog_editor, {subject, Target, Target}, {0}})),
                ?assertMatch({workspace, Target, Target, _,
                              {component, workspace, form, _,
                               [{component, predicate, catalogue_selection, _, []},
                                {component, source, editor, _, []}]}},
                             Workspace),
                {ok, [#{<<"V0">> := Indicators}], _} = read(Ctx,
                    editor_scope(Tools, {prolog_predicates, Target, {0}})),
                ?assert(lists:member(Indicator, Indicators)),
                ?assert(lists:member({'/', can_invoke, 4}, Indicators)),
                {ok, [#{<<"V0">> := Source}], _} = read(Ctx, editor_scope(Tools,
                    {prolog_source, Target, Indicator, {0}})),
                {ok, [#{<<"V0">> := Policy}], _} = read(Ctx, editor_scope(Tools,
                    {prolog_source, Target, {'/', can_invoke, 4}, {0}})),
                ?assert(byte_size(Source) > 0), ?assert(byte_size(Policy) > 0),
                Complete = complete_source(Ctx, Target),
                ?assertNotEqual(nomatch, binary:match(Complete, Source)),
                ?assertNotEqual(nomatch, binary:match(Complete, Policy))
            end, Targets),
            %% Representative public domain calls keep working through their
            %% real signed and exactly anchored entry points.
            ?assertMatch({ok, _, _}, read(Ctx,
                editor_scope(<<"quod:modelling">>,
                    {shape, {box, 1, 2, 3}, {0}, {1}}))),
            ?assertMatch({ok, _, _}, read(Ctx,
                editor_scope(<<"quod:rendering">>, {mark_kind, <<"mesh">>}))),
            ?assertMatch({ok, _, _}, read(Ctx,
                editor_scope(<<"quod:material">>, {material_class, wood}))),
            ?assertMatch({ok, _, _}, read(Ctx,
                editor_scope(<<"quod:agent">>, {isa, agent, thing}))),
            ?assertMatch({ok, _, _}, read(Ctx,
                editor_scope(<<"quod:human_user">>, {isa, human_user, agent}))),
            ?assertMatch({ok, _, _}, read(Ctx,
                editor_scope(<<"quod:node">>, {isa, node, agent}))),
            ?assertMatch({ok, _, _}, read(Ctx,
                editor_scope(<<"quod:lens">>, {lens, <<"work_licences">>, {0}}))),
            ?assertMatch({ok, _, _}, read(Ctx,
                editor_scope(<<"quod:licence">>, {family, <<"permissive">>}))),
            %% Root's administrator list and policy source are confidential to
            %% an ordinary account, including through the public source tool.
            Root = system_target(quod_ontology:root_ns()),
            ?assertMatch({fail, _}, read(Ctx,
                editor_scope(quod_ontology:root_ns(), {root_administrator_agent, {0}}))),
            ?assertMatch({fail, _}, read(Ctx, editor_scope(Tools,
                {prolog_predicates, Root, {0}}))),
            Signup = system_target(<<"quod:signup">>),
            ?assertMatch({fail, _}, read(Ctx,
                editor_scope(<<"quod:signup">>, {entity_eidolons, Signup, {0}}))),
            ?assertMatch({fail, _}, read(Ctx, editor_scope(Tools,
                {prolog_predicates, Signup, {0}}))),
            %% Read mode is not a syntactic bypass: direct, qualified,
            %% conjunctive, meta-called and source-generated mutations all
            %% remain target-authorized and leave the target unchanged.
            Target = system_target(<<"quod:modelling">>),
            Fact = {ordinary_system_edit, forbidden},
            Mutations = [
                editor_scope(<<"quod:modelling">>, {assertz, Fact}),
                editor_scope(<<"quod:modelling">>,
                    {',', {model, [], {0}}, {assertz, Fact}}),
                editor_scope(<<"quod:modelling">>, {call, {assertz, Fact}})
            ],
            lists:foreach(fun(Goal) ->
                ?assertMatch({ok, _, {normalized, {failed, _}}},
                             submit(Ctx, execute, Goal))
            end, Mutations),
            {ok, [#{<<"V0">> := Before}], _} = read(Ctx, editor_scope(Tools,
                {prolog_source, Target, {'/', model, 2}, {0}})),
            {ok, [#{<<"V0">> := Edit}], _} = read(Ctx, editor_scope(Tools,
                {prolog_edit_goal, Target, {'/', model, 2}, Before,
                 <<Before/binary, "model(ordinary_system_edit, forbidden).\n">>, {0}})),
            ?assertMatch({'::', <<"quod:modelling">>, _}, Edit),
            ?assertMatch({ok, _, {normalized, {failed, _}}},
                         submit(Ctx, execute, Edit)),
            ?assertMatch({fail, _}, read(Ctx,
                editor_scope(<<"quod:modelling">>, Fact))),
            ?assertMatch({ok, _, _}, read(Ctx,
                editor_scope(<<"quod:modelling">>,
                    {system_prolog_introspection, predicates, {0}}))),
            ?assertMatch({fail, _}, read(Ctx, editor_scope(Tools,
                {prolog_source, {ontology_ref, <<"quod:modelling">>, <<0:256>>},
                 {'/', model, 2}, {0}})))

        after stop(Ctx), file:del_dir_r(Dir) end
    end}.

system_ontology_editing_uses_universal_scope_identity_test_() ->
    {timeout, 90, fun() ->
        Dir = filename:join("/tmp", "quod-system-editor-" ++
                                   integer_to_list(erlang:unique_integer([positive]))),
        Ctx = start(Dir, [], extended_system_catalogue),
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
            lists:foreach(fun(Ns) -> verify_system_editor(Ctx, Ns) end,
                          [RootNs, <<"quod:modelling">>, <<"quod:prolog">>,
                           <<"quod:signup">>]),
            %% A retained target without the wrapper refuses inspection;
            %% there is no silent fallback to an API subset.
            RenderNs = <<"quod:rendering">>,
            Wrapper = {':-', {can_invoke, {'Goal'}, {'_'}, {'_'}, {'_'}},
                       {system_source_query, {'Goal'}}},
            ?assertMatch({ok, _, _}, quod_prolog:execute(RenderNs, {retract, Wrapper})),
            RenderTarget = system_target(RenderNs),
            ToolsNs = <<"quod:prolog">>,
            ?assertMatch({fail, _}, read(Ctx,
                editor_scope(ToolsNs, {prolog_predicates, RenderTarget, {0}}))),
            ?assertMatch({fail, _},
                read(Ctx, editor_scope(<<"quod:prolog:eidolons">>,
                    {eidolon, prolog_editor, {subject, RenderTarget, RenderTarget}, {0}}))),
            {ok, [#{<<"V0">> := RenderEdit}], _} = read(Ctx, editor_scope(ToolsNs,
                {prolog_edit_goal, RenderTarget, {'/', editor_system_fact, 1}, <<>>,
                 <<"editor_system_fact(saved).">>, {0}})),
            ?assertMatch({ok, _, {normalized, {failed, _}}},
                         submit(Ctx, execute, RenderEdit)),
            ?assertMatch({ok, _, _}, quod_prolog:execute(RenderNs, {assertz, Wrapper})),
            ?assertEqual(<<>>, editor_source(Ctx, RenderTarget, {'/', editor_system_fact, 1})),
            %% Packaged source is only a founding input. The committed edit is
            %% recovered from the retained exact history after this owner is
            %% restarted with the same anchor and data directory.
            ModelNs = <<"quod:modelling">>,
            {ModelSup, ModelConfig} = maps:get(ModelNs, maps:get(ontologies, Ctx)),
            ModelAnchor = quod_simplex:genesis_hash(ModelNs),
            stop_process(ModelSup),
            {Resumed, _} = start_namespace(ModelNs,
                ModelConfig#{mode => join, genesis_hash => ModelAnchor}),
            try
                Target = {ontology_ref, ModelNs, ModelAnchor},
                ?assertEqual(<<"editor_system_fact(saved) :- true.\n">>,
                             editor_source(Ctx, Target, {'/', editor_system_fact, 1}))
            after stop_process(Resumed) end
        after stop(Ctx), file:del_dir_r(Dir) end
    end}.

verify_system_editor(Ctx, Ns) ->
    Anchor = quod_simplex:genesis_hash(Ns),
    Target = {ontology_ref, Ns, Anchor},
    Guard = {current_ontology_identity, Ns, Anchor},
    ?assertMatch({fail, _}, read(Ctx, {'::', Ns,
        {current_ontology_identity, Ns, <<0:256>>}})),
    Tools = <<"quod:prolog">>,
    ToolsGuard = {current_ontology_identity, Tools, quod_simplex:genesis_hash(Tools)},
    Query = fun(Goal) -> {'::', Tools, {',', ToolsGuard, Goal}} end,
    Recipe = <<"quod:prolog:eidolons">>,
    ?assertMatch({ok, [#{<<"V0">> :=
        {workspace, Target, Target, _,
         {component, workspace, form, _,
          [{component, predicate, catalogue_selection, _, []},
           {component, new_predicate, text_box, _, []},
           {component, source, editor, _, []} | _]}}}], _},
        read(Ctx, editor_scope(Recipe,
            {eidolon, prolog_editor, {subject, Target, Target}, {0}}))),
    Indicator = {'/', editor_system_fact, 1},
    Source = Query({prolog_source, Target, Indicator, {0}}),
    %% Root administration uses root's one committed administrator list. The
    %% source tool relays full inspection and wraps mutation in exact root and
    %% target identities; it does not copy root facts into target policies.
    ?assertMatch({ok, [#{<<"V0">> := <<>>}], _}, read(Ctx, Source)),
    ?assertMatch({ok, [#{<<"V0">> := PolicySource}], _} when byte_size(PolicySource) > 0,
                 read(Ctx,
        Query({prolog_source, Target, {'/', can_invoke, 4}, {0}}))),
    {ok, [#{<<"V0">> := Edit}], _} = read(Ctx,
        Query({prolog_edit_goal, Target, Indicator, <<>>,
               <<"editor_system_fact(saved).">>, {0}})),
    case Ns of
        <<"quod:root">> ->
            ?assertMatch({'::', Ns, {',', Guard, {transaction, _}}}, Edit);
        _ ->
            ?assertMatch({'::', Ns,
                          {',', Guard,
                           {',', system_prolog_edit, {transaction, _}}}}, Edit)
    end,
    Other = Ctx#{instance => <<"human_user(other_agent).">>},
    case Ns of
        <<"quod:root">> -> ?assertMatch({fail, _}, read(Other, Source));
        <<"quod:signup">> -> ?assertMatch({fail, _}, read(Other, Source));
        _ -> ?assertMatch({ok, _, _}, read(Other, Source))
    end,
    ?assertMatch({ok, _, {normalized, {failed, _}}}, submit(Other, execute, Edit)),
    {Owner, CursorId, Evidence} = open_cursor(Ctx, Edit),
    {ok, Evidence, CursorResult} =
        quod_client_cursor:command(Owner, CursorId, accept),
    ?assertMatch({committed, _, _},
                 quod_client_result:normalize(Evidence, CursorResult)),
    ?assertMatch({ok, [#{<<"V0">> := <<"editor_system_fact(saved) :- true.\n">>}], _},
                 read(Ctx, Source)),
    ?assertMatch({ok, _, {normalized, {failed, _}}}, submit(Ctx, execute, Edit)).

system_target(Ns) -> {ontology_ref, Ns, quod_simplex:genesis_hash(Ns)}.

non_system_read_only_source_uses_the_same_recipe_test_() ->
    {timeout, 90, fun() ->
        Dir = filename:join("/tmp", "quod-ontology-readonly-" ++
                            integer_to_list(erlang:unique_integer([positive]))),
        Ctx = start(Dir),
        {ontology_ref, LobbyNs, _} = maps:get(lobby, Ctx),
        {_, Base} = maps:get(LobbyNs, maps:get(ontologies, Ctx)),
        Ns = <<"inspection:read-only">>,
        Terms = [{can_invoke,
                  {',', {current_ontology_identity, {'_'}, {'_'}},
                   {prolog_introspection, {'_'}, {'_'}}}, {'_'}, {'_'}, {'_'}},
                 {':-', {can_invoke, {'Goal'}, {'_'}, {'_'}, {'_'}},
                   {public_source_query, {'Goal'}}},
                 {':-', {can_invoke,
                   {',', {current_ontology_identity, {'_'}, {'_'}}, {'Goal'}},
                   {'_'}, {'_'}, {'_'}}, {public_source_query, {'Goal'}}},
                 {readonly_content, visible}],
        {Sup, _} = start_namespace(Ns, Base#{data_dir => filename:join(Dir, "readonly"),
            genesis_diff => quod_prolog:terms_to_diff(Terms)}),
        try
            Target = system_target(Ns),
            {ok, [#{<<"V0">> := Choices}], _} = read(Ctx, editor_scope(Ns,
                {entity_eidolons, Target, {0}})),
            ?assertEqual(4, length(Choices)),
            ?assertMatch({ok, [#{<<"V0">> := {workspace, Target, Target, _,
                {component, workspace, form, _,
                 [{component, predicate, catalogue_selection, _, []},
                  {component, source, editor, _, []}]}}}], _}, read(Ctx,
                editor_scope(<<"quod:prolog:eidolons">>,
                    {eidolon, prolog_editor, {subject, Target, Target}, {0}}))),
            ?assertEqual(<<"readonly_content(visible) :- true.\n">>,
                editor_source(Ctx, Target, {'/', readonly_content, 1})),
            Edit = compile_source_edit(Ctx, Target, {'/', readonly_content, 1},
                editor_source(Ctx, Target, {'/', readonly_content, 1}), <<"readonly_content(forbidden).">>),
            ?assertMatch({ok, _, {normalized, {failed, _}}}, submit(Ctx, execute, Edit)),
            ?assertEqual(<<"readonly_content(visible) :- true.\n">>,
                editor_source(Ctx, Target, {'/', readonly_content, 1})),
            ?assertMatch({fail, _}, read(Ctx, editor_scope(Ns, {readonly_content, visible})))
        after stop_process(Sup), stop(Ctx), file:del_dir_r(Dir) end
    end}.

scoped_routes_reuse_the_directory_and_preserve_private_admission_test_() ->
    {timeout, 120, fun() ->
        Dir = filename:join("/tmp", "quod-ontology-routes-" ++
                            integer_to_list(erlang:unique_integer([positive]))),
        Ctx = start(Dir),
        {ok, Directory} = quod_directory:start_link(#{expire_tick_ms => 60000, ttl_ms => 60000}),
        try
            {ontology_ref, Ns, Anchor} = Target = maps:get(lobby, Ctx),
            Lens = <<"ontology_routes">>,
            ?assertEqual(<<"route_status(live, unavailable).\n">>, complete_inspection(Ctx, Target, Lens)),
            HostNs = <<"route:node">>, HostAnchor = <<81:256>>,
            HostRef = {agent_instance_ref, HostNs, HostAnchor, host},
            {ok, AuthorBytes} = quod_wire_term:encode_canonical(HostRef),
            NodeKey = <<82:256>>,
            Generation = fun(Number, Host, Hosted) ->
                #{author => {node_actor, AuthorBytes}, node_key => NodeKey,
                  endpoint => {Host, 14567}, epoch => 1, generation => Number,
                  page => 0, last => true, hosted => lists:sort(Hosted)} end,
            ok = quod_directory:install_private_projection([
                #{namespace => Ns, anchor => Anchor, host_node_ref => HostRef}]),
            {ok, _} = quod_directory:install_generation(Generation(1, <<"first-host">>,
                [{HostNs, HostAnchor, validator, node}])),
            ?assertEqual([], quod_directory:directory_hosts(Ns)),
            First = complete_inspection(Ctx, Target, Lens),
            ?assertNotEqual(nomatch, binary:match(First, <<"first-host">>)),
            BeforeHeight = quod_prolog:applied(Ns),
            LiveWrite = editor_scope(Ns, {',',
                {prolog_introspection, {route_chunks, 4096}, {0}},
                {assertz, forbidden_route_write}}),
            ?assertMatch({ok, _, {normalized, {error, proof_unavailable}}},
                submit(Ctx, execute, LiveWrite)),
            ?assertEqual(BeforeHeight, quod_prolog:applied(Ns)),
            ?assertMatch({fail, _}, read(Ctx, editor_scope(Ns, forbidden_route_write))),
            Reader = Ctx#{instance => <<"human_user(other_agent).">>},
            ?assertMatch({fail, _}, read(Reader, editor_scope(<<"quod:lens">>, {view, Lens, [Target], {0}}))),
            assert_read_has_no_io(fun() ->
                ?assertEqual(First, complete_inspection(Ctx, Target, Lens)),
                ?assertEqual(First, complete_inspection(Ctx, Target, Lens))
            end),
            {ok, _} = quod_directory:install_generation(Generation(2, <<"moved-host">>,
                [{HostNs, HostAnchor, validator, node}])),
            Moved = complete_inspection(Ctx, Target, Lens),
            ?assertEqual(nomatch, binary:match(Moved, <<"first-host">>)),
            ?assertNotEqual(nomatch, binary:match(Moved, <<"moved-host">>)),
            lists:foreach(fun({GenerationNumber, Host, Text}) ->
                {ok, _} = quod_directory:install_generation(Generation(GenerationNumber, Host,
                    [{HostNs, HostAnchor, validator, node}])),
                ?assertNotEqual(nomatch, binary:match(complete_inspection(Ctx, Target, Lens), Text))
            end, [{3, "list-host", <<"list-host">>},
                  {4, {127,0,0,1}, <<"127.0.0.1">>},
                  {5, {0,0,0,0,0,0,0,1}, <<"::1">>}]),
            %% A second simultaneously confirmed history is not filtered away.
            {ok, _} = quod_ct:install_directory_generation(<<83:256>>, {<<"conflict">>, 24567},
                [{Ns, <<84:256>>, validator}], 1, 1),
            ?assertEqual(<<"route_status(live, anchor_conflict).\n">>,
                complete_inspection(Ctx, Target, Lens)),
            ok = quod_directory:install_private_projection([]),
            ?assertEqual(<<"route_status(live, anchor_conflict).\n">>,
                complete_inspection(Ctx, Target, Lens)),
            ?assertEqual(Anchor, quod_simplex:genesis_hash(Ns))
        after gen_server:stop(Directory), stop(Ctx), file:del_dir_r(Dir) end
    end}.

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
                     {attribute, console_b, mark_id, <<"console_b">>},
                     {attribute, console_b, layout, {transform, 3000, 0, 0, 0, 0, 0}}],
            commit_editor_goal(Ctx, editor_scope(Ns, editor_conjunction(quod_ct:source_assertions(Added)))),
            ?assertEqual([<<"PROLOG CONSOLE">>, <<"PROLOG CONSOLE">>], shared_editor_titles(Ctx, Ns)),
            edit_shared_source(Ctx, ClassNs, {'/', eidolon, 3}, fun(Source) ->
                ?assertNotEqual(nomatch, binary:match(Source, <<"PROLOG CONSOLE">>)),
                binary:replace(Source, <<"PROLOG CONSOLE">>, <<"SHARED REVISION">>, [global])
            end),
            ?assertEqual([<<"SHARED REVISION">>, <<"SHARED REVISION">>], shared_editor_titles(Ctx, Ns)),
            ?assertMatch({ok, [#{<<"V0">> := <<>>}], _},
                read(Ctx, editor_scope(Ns, {'$quod_predicate_source', {'/', eidolon, 3}, {0}}))),
            edit_shared_source(Ctx, ClassNs, {'/', isa, 2}, fun(Source) ->
                <<Source/binary, "isa(smart_console, prolog_console).\n">>
            end),
            edit_shared_source(Ctx, ClassNs, {'/', device_eidolon, 4}, fun(Source) ->
                <<Source/binary, "device_eidolon(smart_console, playing, solid, console_edition).\n">>
            end),
            commit_editor_goal(Ctx, editor_scope(Ns, {',', {retract, {instance_of, prolog_console, console_b}},
                                       quod_ct:source_assertion({instance_of, smart_console, console_b})})),
            ?assertEqual([<<"SHARED REVISION">>, <<"CONSOLE PARTS">>], shared_editor_titles(Ctx, Ns)),
            {ok, [#{<<"V0">> := [{eidolon,playing,solid,Chosen}]}], _} = read(Ctx,
                editor_scope(Ns, {entity_eidolons, console_b, playing, solid, {0}})),
            ?assertMatch({recipe, ClassNs, _, console_edition}, Chosen),
            {ok, [#{<<"V0">> := [{eidolon,playing,solid,Original}]}], _} = read(Ctx,
                editor_scope(Ns, {entity_eidolons, console, playing, solid, {0}})),
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
    {ok, [#{<<"V0">> := Scene}], _} = read(Ctx, editor_scope(Ns, {world_view, personal_lobby, playing, {0}})),
    ?assertEqual(Heights, maps:map(fun(At, _) -> quod_prolog:applied(At) end,
                                  maps:get(ontologies, Ctx))),
    [begin
        MeshId = <<Prefix/binary, "/model">>,
        Id = case lists:keyfind(MeshId, 2, Scene) of
            false -> <<Prefix/binary, "/top-sign">>;
            _ -> MeshId
        end,
        {mark, Id, _, _, _, _, {label, Title, _}, _} = lists:keyfind(Id, 2, Scene),
        Title
     end || Prefix <- [<<"console">>, <<"console_b">>]].

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
    start(Dir, ExtraClassFacts, base_system_catalogue).

start(Dir, ExtraClassFacts, CatalogueKind) ->
    start(Dir, ExtraClassFacts, CatalogueKind, []).

start(Dir, ExtraClassFacts, CatalogueKind, ExtraLobbyTerms) ->
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
    {ok, Effects} = quod_effect_journal:start_link(#{data_dir => filename:join(Dir, "effects")}),
    %% Atomic coordinators follow other identities even when they are co-hosted.
    {ok, Foreign} = quod_foreign_log:start_link(#{cache_dir => filename:join(Dir, "foreign")}),
    Base = #{node_id => Pub, identity => Identity, mode => create,
             external_predicate_modules => [quod_agent_predicates]},
    BaseSpec = [{<<"lobby-test-rendering">>, "quod_rendering.pl", []},
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
            {<<"quod:lens">>, "quod_lens.pl", []},
            {<<"quod:gui">>, "quod_gui.pl", []},
            {<<"quod:prolog">>, "quod_prolog.pl", []},
            {<<"quod:prolog:eidolons">>, "quod_prolog_eidolons.pl", []}],
    ExtraSpec = [{<<"quod:agent">>, "quod_agent.pl", []},
                 {<<"quod:environment">>, "quod_environment.pl", []},
                 {<<"quod:environment:eidolons">>, "quod_environment_eidolons.pl",
                  [{environment_vocabulary, <<"quod:environment">>}]},
                 {<<"quod:human_user">>, "quod_human_user.pl", []},
                 {<<"quod:licence">>, "quod_licence.pl", []},
                 {<<"quod:lobby">>, "quod_lobby.pl", []},
                 {<<"quod:material">>, "quod_material.pl",
                  [{measure_vocabulary, <<"quod:measure">>}]},
                 {<<"quod:material:eidolons">>, "quod_material_eidolons.pl",
                  [{material_vocabulary, <<"quod:material">>}]},
                 {<<"quod:measure">>, "quod_measure.pl", []},
                 {<<"quod:modelling">>, "quod_modelling.pl",
                  [{rendering_vocabulary, <<"quod:rendering">>}]},
                 {<<"quod:names">>, "quod_names.pl", []},
                 {<<"quod:node">>, "quod_node.pl", []},
                 {<<"quod:rendering">>, "quod_rendering.pl", []},
                 {<<"quod:signup">>, "quod_signup.pl", []}],
    Spec = case CatalogueKind of
        extended_system_catalogue -> BaseSpec ++ ExtraSpec;
        base_system_catalogue -> BaseSpec
    end,
    Ontologies0 = maps:from_list([begin
        Refs = [{Predicate, Target, quod_simplex:genesis_hash(Target)}
                || {Predicate, Target} <- Facts],
        VocabularyBase = case Ns of
            <<"quod:gui">> -> Base#{external_predicate_modules => [quod_agent_predicates,quod_gui_predicates]};
            _ -> Base
        end,
        Config = config(Dir, Ns, VocabularyBase, Source, Refs),
        {Ns, start_namespace(Ns, Config)}
    end || {Ns, Source, Facts} <- Spec]),
    %% Use the actual system ontology catalogue and policies. Universal
    %% eidolon discovery must cross these exact identities through signed ACLs.
    RootNs = quod_ontology:root_ns(),
    Catalogue = [{system_ontology, Ns, quod_simplex:genesis_hash(Ns)}
                 || {Ns, _, _} <- Spec,
                    binary:match(Ns, <<"quod:">>) =:= {0, 5}],
    RootBase = Base#{external_predicate_modules => [quod_directory_predicates, quod_ontology_predicates]},
    Root = start_namespace(RootNs, config(Dir, RootNs, RootBase, "quod_root.pl", Catalogue)),
    Network = quod_simplex:genesis_hash(RootNs),
    application:set_env(quod, namespace_desired,
        #{content => #{RootNs => #{genesis_hash => Network}}, brahms => #{}}),
    {ok, Auth} = quod_client_auth:start_link(#{network_id => Network, node_key => Pub}),
    {ok, Cursors} = quod_client_cursor:start_link(),
    ClassNs = <<"lobby-test-classes">>,
    ClassFacts = [{rendering_vocabulary, <<"lobby-test-rendering">>,
                   quod_simplex:genesis_hash(<<"lobby-test-rendering">>)},
                  {modelling_vocabulary, <<"lobby-test-modelling">>,
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
       {attribute, personal_sky, brightness, 1000},
       {attribute, personal_sky, tint, <<"#FFFFFF">>},
       {instance_of, prolog_console, console},
       {instance_of, space, personal_lobby},
       {instance_of, lobby_floor, floor},
       {attribute, floor, mark_id, <<"floor">>},
       {attribute, floor, layout, {transform, 0, 0, 0, 0, 0, 0}},
       {attribute, console, mark_id, <<"console">>},
       {attribute, console, layout, {transform, 0, 0, 3850, 0, 0, 0}},
       {attribute, personal_sky, mark_id, <<"sky">>},
       {instance_of, lobby_roof, personal_roof},
       {attribute, personal_roof, mark_id, <<"roof">>},
       {attribute, personal_roof, layout, {transform, 0, 0, 0, 0, 0, 0}},
       {environment_eidolons, <<"lobby-test-environment-eidolons">>,
            quod_simplex:genesis_hash(<<"lobby-test-environment-eidolons">>)},
       {modelling_vocabulary, <<"lobby-test-modelling">>, quod_simplex:genesis_hash(<<"lobby-test-modelling">>)},
       {environment_vocabulary, <<"lobby-test-environment">>, quod_simplex:genesis_hash(<<"lobby-test-environment">>)},
       {gui_vocabulary, <<"quod:gui">>, quod_simplex:genesis_hash(<<"quod:gui">>)},
       {lobby_vocabulary, <<"lobby-test-classes">>, quod_simplex:genesis_hash(<<"lobby-test-classes">>)}],
    Lobby = start_namespace(LobbyNs, config(Dir, LobbyNs, Base, none,
                       presentation_fixture_terms() ++ LobbyFacts ++ ExtraLobbyTerms)),
    LobbyRef = {ontology_ref, LobbyNs, quod_simplex:genesis_hash(LobbyNs)},
    Ctx = #{ontologies => Ontologies0#{RootNs => Root, ClassNs => Classes, AgentNs => User, LobbyNs => Lobby},
            services => [Foreign, Effects, Cursors, Auth, Router], saved => Saved, directory => Dir,
            agent => {AgentNs, AgentAnchor}, key_pair => UserPair, network => Network,
            lobby => LobbyRef},
    ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                 submit(Ctx, execute, {assertz, {lobby_reference, LobbyRef}})),
    Ctx.

%% Source/GUI tests use an authored information space with decorative poses.
%% The complete physical factory and admitted-body/native contract are exercised
%% by default_lobby_physics_startup_test_, not simulated by this presentation fixture.
presentation_fixture_terms() ->
    Shared = lists:append([quod_prolog:read_terms(filename:join(code:priv_dir(quod),
                        "ontologies/" ++ File)) || File <- ["space.pl","space_view.pl"]]),
    Appearance = [presentation_layout(T) || T <- quod_prolog:read_terms(
        filename:join(code:priv_dir(quod),"ontologies/lobby_instance.pl")),
        presentation_clause(T)],
    Shared ++ Appearance ++ [
        {lobby_space,personal_lobby,[edition,playing]},
        {':-',{space_member,personal_lobby,{entity_ref,{'Ns'},{'A'},{'E'}}},
              {',',{current_ontology_identity,{'Ns'},{'A'}},{attribute,{'E'},mark_id,{'_'}}}}].

presentation_clause({':-',{can_invoke,_,_,_,_},{lobby_owner,_}}) -> true;
presentation_clause(T) ->
    H = case T of {':-',Head,_} -> Head; Head -> Head end,
    {F,_} = erlog_int:functor(H),
    lists:member(F,[ontology_source_mode,lobby_modes,lobby_sky,one_attribute,
                   entity_scene,lobby_physical_space,class_eidolon,no_follow,vocabulary_class,lobby_menu,lobby_workspace]).

presentation_layout({'=',{'Layout'},physical}) -> {one_attribute,{'Entity'},layout,{'Layout'}};
presentation_layout(T) when is_tuple(T) -> list_to_tuple([presentation_layout(X) || X <- tuple_to_list(T)]);
presentation_layout([H|T]) -> [presentation_layout(H)|presentation_layout(T)];
presentation_layout(T) -> T.

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
    {Bytes, Signature} = signed_request(Ctx, Mode, Goal),
    quod_client_goal_ingress:submit(Bytes, Signature).

signed_request(Ctx, Mode, Goal) ->
    {Ns, Anchor} = maps:get(agent, Ctx),
    {Public, _} = KeyPair = maps:get(key_pair, Ctx),
    %% Returned compiler terms have fresh proof variable IDs. Current browser
    %% text entry re-numbers those names through the parser-v3 signed path.
    {Numbered, _, _} = erlog_int:term_instance(Goal, 0),
    {ok, Text} = quod_client_goal_parser:format(Numbered),
    Request = #{network_identity => maps:get(network, Ctx), signing_public_key => Public,
        operation_id => crypto:strong_rand_bytes(32), agent_namespace => Ns,
        agent_genesis_anchor => Anchor, agent_instance_text => maps:get(instance, Ctx, <<"human_user(test_agent).">>),
        mode => Mode, parser_version => 3, not_after_ms => quod_time:now_ms() + 30000,
        goal_text => Text},
    {ok, Bytes} = quod_client_goal:encode(Request),
    Signature = quod_identity:sign(Bytes, quod_identity:key_term(KeyPair)),
    {Bytes, Signature}.

open_cursor(Ctx, Goal) ->
    {Owner, Id, Evidence, _} = open_source_cursor(Ctx, Goal),
    {Owner, Id, Evidence}.

open_source_cursor(Ctx, Goal) ->
    {Bytes, Signature} = signed_request(Ctx, cursor, Goal),
    {ok, Evidence = #{request := #{signing_public_key := SigningKey}}} =
        quod_client_goal_target:verify_request(Bytes, Signature),
    {ok, Peer} = application:get_env(quod, node_pubkey),
    Owner = {session, crypto:strong_rand_bytes(32), SigningKey},
    CursorId = crypto:strong_rand_bytes(32),
    {ok, {Evidence, MaterializedGoal, Principal, Owner}} =
        quod_client_goal_target:prepare_local(
          Evidence, Peer, Owner, CursorId),
    {ok, Evidence, {normalized, {solution, CursorId, _, Blob}}} =
       quod_client_goal_target:execute(Evidence, MaterializedGoal, Principal, Owner, CursorId),
    {ok, Bindings} = quod_client_result:decode_binding(Blob),
    {Owner, CursorId, Evidence, proplists:get_value(<<"V0">>, Bindings)}.

read(Ctx, Goal) ->
    case submit(Ctx, read, Goal) of
        {ok, _, {normalized, {read, _, {answers, Height, Blobs}}}} ->
            {ok, [begin {ok, Pairs} = quod_client_result:decode_binding(B), maps:from_list(Pairs) end
                  || B <- Blobs], Height};
        {ok, _, {normalized, {read, _, {failed, Reasons}}}} ->
            {ok, Decoded} = quod_wire_term:decode_failure_reasons(Reasons),
            {fail, Decoded};
        Other -> Other
    end.

%% Manual/browser acceptance uses these same real owners and signed endpoints.
%% Only the disposable fixture's identity is written, into an owner-only file.
preview(Dir) ->
    Ctx = start(Dir, [], extended_system_catalogue),
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
