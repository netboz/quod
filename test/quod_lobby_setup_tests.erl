-module(quod_lobby_setup_tests).
-include_lib("eunit/include/eunit.hrl").

retained_lobby_setup_is_owner_authorized_atomic_and_repeatable_test_() ->
    {timeout, 90, fun() ->
        Dir = filename:join("/tmp", "quod-lobby-setup-" ++
            integer_to_list(erlang:unique_integer([positive]))),
        {ok, SpaceSource} = file:read_file(filename:join(code:priv_dir(quod), "ontologies/space.pl")),
        Ctx = quod_lobby_tests:start(Dir, [{space_template, SpaceSource}],
            base_system_catalogue, []),
        try
            ClassNs = <<"lobby-test-classes">>,
            {UserNs, UserAnchor} = maps:get(agent, Ctx),
            Owner = {agent_instance_ref, UserNs, UserAnchor, {human_user, test_agent}},
            {ontology_ref, LobbyNs, LobbyAnchor} = maps:get(lobby, Ctx),
            [OwnerRule] = [T || T = {':-', {human_user_owner, _}, _} <-
                quod_prolog:read_terms(filename:join(code:priv_dir(quod), "ontologies/human_user_instance.pl"))],
            committed(Ctx, conjunction([
                {assertz, OwnerRule},
                {assertz, {instance_of, human_user, {human_user, test_agent}}},
                {assertz, {lobby_vocabulary, ClassNs, quod_simplex:genesis_hash(ClassNs)}}])),
            committed(Ctx, scope(LobbyNs, conjunction([
                {assertz, {instance_of, lobby, personal_lobby}},
                {assertz, {custom_lobby_note, retained}}]))),
            View = scope(LobbyNs, {client_world_view, personal_lobby, playing, [], {0}}),
            ?assertMatch({ok, [#{<<"V0">> := {world_view, _, [], unavailable}}], _},
                quod_lobby_tests:read(Ctx, View)),
            Setup = scope(ClassNs, {complete_lobby_setup, Owner, {0}}),
            Before = quod_prolog:applied(LobbyNs),
            ?assertMatch({ok, _, {normalized, {failed, _}}},
                quod_lobby_tests:submit(Ctx#{instance => <<"human_user(other_agent).">>}, execute, Setup)),
            ?assertEqual(Before, quod_prolog:applied(LobbyNs)),
            ?assertMatch({ok, _, {normalized, {failed, _}}},
                quod_lobby_tests:submit(Ctx, execute, scope(ClassNs,
                    {complete_lobby_setup, Owner, {ontology_ref, LobbyNs, <<0:256>>}}))),
            ?assertEqual(Before, quod_prolog:applied(LobbyNs)),
            %% Stage the real setup, then overtake its complete source snapshot.
            {CursorOwner, Cursor, _} = quod_lobby_tests:open_cursor(Ctx, Setup),
            committed(Ctx, scope(LobbyNs, {transaction, {',',
                {assertz, {custom_lobby_note, intervening_edit}},
                {assertz, {intervening_lobby_note, retained}}}})),
            {ok, Evidence, Stale} = quod_client_cursor:command(CursorOwner, Cursor, accept),
            ?assertMatch({error, conflict_retry}, quod_client_result:normalize(Evidence, Stale)),
            %% The rejected transaction is durable outcome evidence even though
            %% its content never applies. It advances the ledger by one slot.
            ?assertEqual(Before + 2, quod_prolog:applied(LobbyNs)),
            ?assertMatch({ok, [#{<<"V0">> := {world_view, _, [], unavailable}}], _},
                quod_lobby_tests:read(Ctx, View)),
            ?assertMatch({ok, _, {normalized, {committed, _,
                {transaction, LobbyNs, LobbyAnchor, _}}}},
                quod_lobby_tests:submit(Ctx, execute, Setup)),
            ?assertEqual(LobbyAnchor, quod_simplex:genesis_hash(LobbyNs)),
            ?assertEqual(Before + 3, quod_prolog:applied(LobbyNs)),
            ?assertMatch({ok, [#{<<"V0">> := {world_view, _, [_ | _], nonphysical}}], _},
                quod_lobby_tests:read(Ctx, View)),
            ?assertMatch({ok, _, _}, quod_lobby_tests:read(Ctx,
                scope(LobbyNs, {',', {custom_lobby_note, retained}, {intervening_lobby_note, retained}}))),
            Height = quod_prolog:applied(LobbyNs),
            quod_lobby_tests:assert_read_has_no_io(fun() ->
                ?assertMatch({ok, _, _}, quod_lobby_tests:submit(Ctx, execute, Setup)),
                ?assertEqual(Height, quod_prolog:applied(LobbyNs))
            end)
        after quod_lobby_tests:stop(Ctx), file:del_dir_r(Dir) end
    end}.

scope(Ns, Goal) -> {'::', Ns,
    {',', {current_ontology_identity, Ns, quod_simplex:genesis_hash(Ns)}, Goal}}.
conjunction([Goal]) -> Goal;
conjunction([Goal | Rest]) -> {',', Goal, conjunction(Rest)}.
committed(Ctx, Goal) ->
    ?assertMatch({ok, _, {normalized, {committed, _, _}}},
        quod_lobby_tests:submit(Ctx, execute, Goal)).
