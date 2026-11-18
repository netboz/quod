-module(quod_predicate_withdrawal_tests).
-include_lib("eunit/include/eunit.hrl").

signed_contents_and_selected_editor_withdraw_test_() ->
    {timeout, 90, fun() ->
        Dir = filename:join("/tmp", "quod-predicate-withdrawal-" ++
                           binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
        Ctx = quod_lobby_tests:start(Dir),
        {ontology_ref, Lobby, _} = maps:get(lobby, Ctx),
        {_, Base} = maps:get(Lobby, maps:get(ontologies, Ctx)),
        {AgentNs, AgentAnchor} = maps:get(agent, Ctx),
        Actor = {agent_instance_ref, AgentNs, AgentAnchor, {human_user, test_agent}},
        Ns = <<"predicate-withdrawal">>,
        {Sup, _} = quod_lobby_tests:start_namespace(Ns, Base#{
            data_dir => filename:join(Dir, "subject"),
            genesis_diff => quod_prolog:terms_to_diff([
                {can_invoke, {'_'}, Actor, {'_'}, {'_'}},
                {ontology_source_mode, editable},
                {rendering_vocabulary, <<"quod:gui">>, quod_simplex:genesis_hash(<<"quod:gui">>)},
                {instance_of, {':',quod,{':',space,space}}, gallery},
                {likes, alice, bob}, {unaffected, kept}, {empty_defined, last}] ++
                [gallery_member(I) || I <- [{'/',likes,2}, {'/',unaffected,1}, {'/',empty_defined,1}]] )}),
        Anchor = quod_simplex:genesis_hash(Ns),
        Subject = {predicate, {'/', likes, 2}},
        Choice = {eidolon, prolog, source, {recipe, Ns, Anchor, predicate_source}},
        Session = quod_gui_question_tests:gui_session(Ctx), Parent = self(),
        Sockets = [{Kind, spawn_monitor(fun() ->
            quod_gui_question_tests:gui_socket(Parent, #{peer => {{127,0,0,1},0}}, false)
        end)} || Kind <- [world, eidolon]],
        [{world, {World, _}}, {eidolon, {Editor, _}}] = Sockets,
        OpenWorld = fun() -> open(World, Ctx, Session, world, Ns, Anchor,
            ["client_world_view(gallery,playing,[],View)"]) end,
        OpenEditor = fun() -> open(Editor, Ctx, Session, eidolon, Ns, Anchor,
            ["client_eidolon(", text(Subject), ",", text(Choice), ",View)"]) end,
        try
            commit(Ctx, Ns, {retract, {empty_defined, last}}),
            OpenWorld(), Before = frame(World, <<"projection">>),
            ?assert(contains(Before, likes)), ?assert(contains(Before, unaffected)),
            ?assert(contains(Before, empty_defined)),
            OpenEditor(), Workspace = frame(Editor, <<"projection">>),
            ?assertNotEqual(nomatch, binary:match(maps:get(<<"value">>, Workspace), <<"prolog_editor">>)),
            Previous = state(Editor),
            quod_lobby_tests:assert_read_has_no_io(fun() ->
                [begin OpenEditor(), _ = frame(Editor, <<"projection">>) end || _ <- lists:seq(1,3)]
            end),
            ?assertEqual(maps:get(dependency_monitors, Previous),
                         maps:get(dependency_monitors, state(Editor))),
            commit(Ctx, Ns, {abolish, {'/', likes, 2}}),
            _ = frame(World, <<"refresh">>), _ = frame(Editor, <<"refresh">>),
            ?assertNot(maps:is_key(installed, state(Editor))),
            OpenEditor(), _ = frame(Editor, <<"unavailable">>),
            ?assertNot(maps:is_key(installed, state(Editor))),
            OpenWorld(), After = frame(World, <<"projection">>),
            ?assertNot(contains(After, likes)), ?assert(contains(After, unaffected)),
            ?assert(contains(After, empty_defined)),
            ?assertMatch({ok, [#{<<"V0">> := []}], _}, quod_lobby_tests:read(Ctx,
                scope(Ns, Anchor, {entity_eidolons, Subject, {0}}))),
            ?assertMatch(fail, quod_lobby_tests:read(Ctx,
                scope(Ns, Anchor, {client_eidolon, Subject, Choice, {0}}))),
            %% Repeat the missing selection without replay/rebuild/write work.
            quod_lobby_tests:assert_read_has_no_io(fun() ->
                [begin OpenEditor(), _ = frame(Editor, <<"unavailable">>) end || _ <- lists:seq(1,3)]
            end),
            commit(Ctx, Ns, {abolish, {'/', empty_defined, 1}}),
            _ = frame(World, <<"refresh">>), OpenWorld(), EmptyGone = frame(World, <<"projection">>),
            ?assertNot(contains(EmptyGone, empty_defined)), ?assert(contains(EmptyGone, unaffected))
        after
            [begin Socket ! stop,
                receive {'DOWN', Monitor, process, Socket, normal} -> ok
                after 5000 -> error(view_not_retired) end
             end || {_, {Socket, Monitor}} <- Sockets],
            quod_lobby_tests:stop_process(Sup), quod_lobby_tests:stop(Ctx)
        end
    end}.

%% This authored gallery displays three ordinary reflected members. Membership
%% remains derived from the real ontology catalogue, never copied into a registry.
gallery_member(Indicator) ->
    Ns = {'Ns'}, A = {'A'},
    {':-', {space_member, gallery, {entity_ref, Ns, A, {predicate, Indicator}}},
        {',', {current_ontology_identity, Ns, A},
            {space_member, {ontology_ref, Ns, A}, {entity_ref, Ns, A, {predicate, Indicator}}}}}.

contains(Frame, Name) ->
    Marks = maps:get(<<"marks">>, Frame),
    binary:match(Marks, iolist_to_binary(["predicate('/'(", atom_to_binary(Name), ","])) =/= nomatch.
text(Term) -> quod_client_goal_parser:value_text(Term).
scope(Ns, Anchor, Goal) -> {'::', Ns, {',', {current_ontology_identity, Ns, Anchor}, Goal}}.
commit(Ctx, Ns, Goal) ->
    {ok, Evidence, {normalized, {committed, _, _}}} =
        quod_lobby_tests:submit(Ctx, execute, scope(Ns, quod_simplex:genesis_hash(Ns), Goal)),
    {Source, _} = maps:get(agent, Ctx),
    ?assertMatch(#{operation_state := terminal}, quod_ct:await_operation_complete(
        Source, quod_client_goal:operation_ref(Evidence), 5000)).
open(Socket, Ctx, Session, Kind, Ns, Anchor, Inner) ->
    {Source, SourceAnchor} = maps:get(agent, Ctx),
    {Pub, _} = Pair = maps:get(key_pair, Ctx),
    Goal = iolist_to_binary([text(Ns), " :: (current_ontology_identity(", text(Ns), ",",
                            text(Anchor), "),", Inner, ")."]),
    {ok, Bytes} = quod_client_goal:encode(#{network_identity => maps:get(network, Ctx),
        agent_namespace => Source, agent_genesis_anchor => SourceAnchor,
        agent_instance_text => <<"human_user(test_agent).">>, signing_public_key => Pub,
        operation_id => crypto:strong_rand_bytes(32), not_after_ms => quod_time:now_ms() + 30000,
        mode => read, parser_version => 3, goal_text => Goal}),
    Enc = fun(B) -> base64:encode(B, #{mode => urlsafe, padding => false}) end,
    Socket ! {client, iolist_to_binary(json:encode(#{type => open, view_kind => Kind,
        session_id => Enc(Session), view_namespace => Ns, view_anchor => Enc(Anchor),
        request => Enc(Bytes), signature => Enc(quod_identity:sign(Bytes, quod_identity:key_term(Pair)))}))}.
frame(Socket, Type) ->
    receive {gui_view, Socket, #{<<"type">> := Type} = Message} -> Message;
            {gui_view, Socket, Unexpected} -> error({unexpected_view, Unexpected})
    after 10000 -> error({missing_view, Type}) end.
state(Socket) ->
    Ref = make_ref(), Socket ! {inspect, Ref},
    receive {Ref, State} -> State after 5000 -> error(missing_view_state) end.
