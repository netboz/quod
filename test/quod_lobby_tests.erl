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
            {ok, [#{<<"V0">> := Scene}], Height} = read(Ctx, Goal),
            ?assertEqual(7, length(Scene)),
            ?assert(lists:member({mark, <<"console">>, <<"group">>, [],
               {transform, 0, 0, 0, 0, 0, 0}, no_surface, unlabelled,
               {depicts, Ns, Anchor, console}}, Scene)),
            %% Expected identity is proved before any scene content is selected.
            ?assertMatch({fail, _}, read(Ctx, {'::', Ns,
                {',', {current_ontology_identity, Ns, <<0:256>>},
                      {lobby_view, playing, {0}}}})),
            {ok, [#{<<"V0">> := {form, _, Components}}], _} = read(Ctx,
                {'::', Ns, {lobby_workspace, console, {0}}}),
            ?assertEqual(6, length(Components)),
            ?assertMatch({ok, [#{<<"V0">> := [{menu_entry, prove_goal, _, _}]}], _},
                read(Ctx, {'::', Ns, {lobby_menu, console, {0}}})),
            %% A valid second actor can read its origin, but cannot read this
            %% private lobby. Privacy is the ontology policy, not UI filtering.
            Other = Ctx#{instance => <<"human_user(other_agent).">>},
            ?assertMatch({ok, _, _}, read(Other, {lobby_reference, {0}})),
            ?assertMatch({fail, _}, read(Other, Goal)),
            %% The exact same ledger restores the lobby; no creation event or
            %% model facts are replayed into another database.
            {Sup, Config} = maps:get(Ns, maps:get(ontologies, Ctx)),
            stop_process(Sup),
            ?assertEqual(undefined, quod_simplex:genesis_hash(Ns)),
            {Resumed, _} = start_namespace(Ns, Config#{mode => join, genesis_hash => Anchor}),
            try
                ?assertEqual({ok, [#{<<"V0">> => Scene}], Height}, read(Ctx, Goal))
            after stop_process(Resumed) end
        after stop(Ctx), file:del_dir_r(Dir) end
    end}.

first_scene_waits_for_new_lobby_route_test_() ->
    [first_scene_waits_for_new_lobby_route(Discovery)
     || Discovery <- [desired_hosting, starting_consensus]].

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
                    ?assertMatch({ok, [#{<<"V0">> := [_,_,_,_,_,_,_]}], _}, Result)
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

start(Dir) ->
    {ok, _} = application:ensure_all_started(gproc),
    Keys = [node_pubkey, identity_key, namespace_desired, client_enabled,
            client_ip, client_port, identity_dir],
    Saved = [{K, application:get_env(quod, K)} || K <- Keys],
    {Pub, _} = Pair = quod_identity:generate(),
    Identity = #{pubkey => Pub, key => quod_identity:key_term(Pair),
                 cert => quod_identity:mint_cert(Pair)},
    Network = <<42:256>>,
    application:set_env(quod, node_pubkey, Pub),
    application:set_env(quod, identity_key, maps:get(key, Identity)),
    application:set_env(quod, namespace_desired,
        #{content => #{quod_ontology:root_ns() => #{genesis_hash => Network}}, brahms => #{}}),
    {ok, Router} = quod_ask_router:start_link(),
    {ok, Auth} = quod_client_auth:start_link(#{network_id => Network, node_key => Pub}),
    {ok, Cursors} = quod_client_cursor:start_link(),
    Base = #{node_id => Pub, identity => Identity, mode => create,
             external_predicate_modules => [quod_agent_predicates]},
    Spec = [{<<"lobby-test-presentation">>, "quod_present.pl", []},
            {<<"lobby-test-gui">>, "quod_gui.pl", []}],
    Ontologies0 = maps:from_list([begin
        Config = config(Dir, Ns, Base, Source, Facts),
        {Ns, start_namespace(Ns, Config)}
    end || {Ns, Source, Facts} <- Spec]),
    ClassNs = <<"lobby-test-classes">>,
    ClassFacts = [{presentation_vocabulary, <<"lobby-test-presentation">>,
                   quod_simplex:genesis_hash(<<"lobby-test-presentation">>)}],
    Classes = start_namespace(ClassNs, config(Dir, ClassNs, Base, "quod_lobby.pl", ClassFacts)),
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
    LobbyFacts = [{lobby_owner, Owner}, {instance_of, prolog_console, console},
       {presentation_vocabulary, <<"lobby-test-presentation">>, quod_simplex:genesis_hash(<<"lobby-test-presentation">>)},
       {gui_vocabulary, <<"lobby-test-gui">>, quod_simplex:genesis_hash(<<"lobby-test-gui">>)},
       {lobby_vocabulary, <<"lobby-test-classes">>, quod_simplex:genesis_hash(<<"lobby-test-classes">>)}],
    Lobby = start_namespace(LobbyNs, config(Dir, LobbyNs, Base, "lobby_instance.pl", LobbyFacts)),
    LobbyRef = {ontology_ref, LobbyNs, quod_simplex:genesis_hash(LobbyNs)},
    Ctx = #{ontologies => Ontologies0#{ClassNs => Classes, AgentNs => User, LobbyNs => Lobby},
            services => [Cursors, Auth, Router], saved => Saved, directory => Dir,
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
    {ok, Text} = quod_client_goal_parser:format(Goal),
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
            {ok, [begin {ok, Pairs} = quod_durable_term:decode_result(B), maps:from_list(Pairs) end
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
