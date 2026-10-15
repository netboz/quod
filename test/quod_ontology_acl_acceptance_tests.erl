-module(quod_ontology_acl_acceptance_tests).
-include_lib("eunit/include/eunit.hrl").

%% The real HTTPS client drives this disposable owner graph. The test controller
%% supplies only receipt/trace barriers and observes this fixture's fixed target.
two_independent_users_over_https_test_() ->
    {timeout, 180, fun run/0}.

run() ->
    Label = integer_to_list(erlang:system_time(millisecond)) ++ "-" ++
            integer_to_list(erlang:unique_integer([positive])),
    Evidence = filename:absname(filename:join(["_build", "ontology-acl-acceptance", Label])),
    with_fixture(Evidence, fun https/5).

with_fixture(Evidence, Fun) ->
    Dir = filename:join(Evidence, "fixture"),
    ok = filelib:ensure_dir(filename:join(Dir, "placeholder")),
    Ctx = quod_lobby_tests:start(Dir),
    try
        {Guest, GuestSup} = guest(Ctx, Dir),
        try
            {Target, TargetSup} = target(Ctx, Dir),
            try
                Fun(Ctx, Guest, Target, Dir, Evidence)
            after quod_lobby_tests:stop_process(TargetSup) end
        after quod_lobby_tests:stop_process(GuestSup) end
    after
        quod_lobby_tests:stop(Ctx),
        ok = file:del_dir_r(Dir)
    end.

guest(Ctx, Dir) ->
    {Ns, _} = maps:get(agent, Ctx),
    {_, Base} = maps:get(Ns, maps:get(ontologies, Ctx)),
    GuestNs = <<"acl-test-guest">>,
    {Key, _} = Pair = quod_identity:generate(),
    Instance = {human_user, guest},
    Terms = [{agent_key, Instance, Key, active},
             {can_invoke, {'_'}, {agent_instance_ref, GuestNs, {'_'}, Instance}, {'_'}, {'_'}}],
    {Sup, _} = quod_lobby_tests:start_namespace(GuestNs, Base#{
        data_dir => filename:join(Dir, "guest"), genesis_diff => quod_prolog:terms_to_diff(Terms)}),
    {Ctx#{agent => {GuestNs, quod_simplex:genesis_hash(GuestNs)},
          key_pair => Pair, instance => <<"human_user(guest).">>}, Sup}.

target(Ctx, Dir) ->
    {ontology_ref, Ns, _} = maps:get(lobby, Ctx),
    {_, Base} = maps:get(Ns, maps:get(ontologies, Ctx)),
    {AgentNs, AgentAnchor} = maps:get(agent, Ctx),
    Owner = {agent_instance_ref, AgentNs, AgentAnchor, {human_user, test_agent}},
    TargetNs = <<"acl-test-owned-ontology">>,
    Terms = quod_prolog:read_terms("test/fixtures/ontology-acl-acceptance.pl"),
    %% Shared definitions plus these UTF-8 rows cross source chunks. Keep the
    %% complete baseline/draft request inside its existing wire encoding bound.
    Padding = [{acl_test_padding, I, binary:copy(<<"héllo 🌍"/utf8>>, 20)}
               || I <- lists:seq(1, 8)],
    {Sup, _} = quod_lobby_tests:start_namespace(TargetNs, Base#{
        data_dir => filename:join(Dir, "target"),
        genesis_diff => quod_prolog:terms_to_diff([{acl_test_owner, Owner} | Terms ++ Padding])}),
    {{ontology_ref, TargetNs, quod_simplex:genesis_hash(TargetNs)}, Sup}.

https(Ctx, Guest, Target, Dir, Evidence) ->
    serve(Ctx, Guest, Target, Dir, fun(ConfigPath, CaPath) ->
        Node = os:find_executable("node"),
        ?assertNotEqual(false, Node),
        Script = filename:absname("client/test/ontology-acl.acceptance.mjs"),
        Port = open_port({spawn_executable, Node}, [binary, exit_status, use_stdio,
            stderr_to_stdout, {line, 65536}, {args, [Script, ConfigPath, Evidence]},
            {env, [{"NODE_EXTRA_CA_CERTS", CaPath},
                   {"NODE_TLS_REJECT_UNAUTHORIZED", false}]}]),
        try
            drive(Port, Target, Evidence),
            {ok, Result} = file:read_file(filename:join(Evidence, "result.json")),
            #{<<"passed">> := true} = json:decode(Result)
        after catch port_close(Port) end
    end).

serve(Ctx, Guest, Target, Dir, Fun) ->
    application:set_env(quod, client_enabled, true),
    application:set_env(quod, client_ip, {127, 0, 0, 1}),
    application:set_env(quod, client_port, 0),
    application:set_env(quod, identity_dir, Dir),
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, Client} = quod_client:start_link(),
    try
        PortNumber = ranch:get_port(quod_client_listener),
        Config = #{origin => list_to_binary("https://127.0.0.1:" ++ integer_to_list(PortNumber)),
                   network => b64(maps:get(network, Ctx)), target => reference(Target),
                   owner => actor(Ctx), guest => actor(Guest)},
        ConfigPath = filename:join(Dir, "actors.json"),
        ok = quod_file:write_atomic(ConfigPath, iolist_to_binary(json:encode(Config)), 8#600),
        %% The listener stores its certificate as DER; Node's CA input is PEM.
        {ok, Cert} = file:read_file(filename:join(Dir, "client_tls.crt")),
        CaPath = filename:join(Dir, "client_ca.pem"),
        ok = file:write_file(CaPath, public_key:pem_encode([{'Certificate', Cert, not_encrypted}])),
        Fun(ConfigPath, CaPath)
    after quod_lobby_tests:stop_process(Client) end.

drive(Port, {ontology_ref, Ns, Anchor} = Target, Evidence) ->
    case event(Port) of
        #{<<"phase">> := <<"settle">>, <<"request">> := Request} ->
            {ok, #{operation_ref := Ref, request := #{agent_namespace := AgentNs}}} =
                quod_client_goal:request_identity(unb64(Request)),
            #{operation_state := terminal} = quod_ct:await_operation_complete(AgentNs, Ref, 10000),
            reply(Port, #{ready => true}), drive(Port, Target, Evidence);
        #{<<"phase">> := <<"height">>} ->
            ?assertEqual(Anchor, quod_simplex:genesis_hash(Ns)),
            reply(Port, #{height => quod_prolog:applied(Ns)}), drive(Port, Target, Evidence);
        #{<<"phase">> := <<"inspect_ready">>} ->
            Before = quod_prolog:applied(Ns),
            quod_lobby_tests:assert_read_has_no_io(fun() ->
                reply(Port, #{ready => true}),
                ?assertMatch(#{<<"phase">> := <<"inspect_done">>}, event(Port))
            end),
            ?assertEqual(Before, quod_prolog:applied(Ns)),
            ok = file:write_file(filename:join(Evidence, "inspection-cost.json"),
                json:encode(#{passed => true, forbidden_calls => 0, height_before => Before,
                              height_after => Before, repeats => 3})),
            reply(Port, #{ready => true}), drive(Port, Target, Evidence);
        #{<<"phase">> := <<"done">>} ->
            receive {Port, {exit_status, Status}} -> ?assertEqual(0, Status)
            after 10000 -> error(client_exit_timeout) end
    end.

event(Port) ->
    receive
        {Port, {data, {eol, <<"{", _/binary>> = Line}}} -> json:decode(Line);
        {Port, {data, {_, Line}}} -> io:format("~s~n", [Line]), event(Port);
        {Port, {exit_status, Status}} -> error({client_exited_before_completion, Status})
    after 60000 -> error(client_step_timeout) end.

reply(Port, Value) -> true = port_command(Port, [json:encode(Value), $\n]), ok.

reference({ontology_ref, Ns, Anchor}) -> #{namespace => Ns, anchor => b64(Anchor)}.

actor(Ctx) ->
    {Ns, Anchor} = maps:get(agent, Ctx),
    {Key, Seed} = maps:get(key_pair, Ctx),
    #{agent => #{namespace => Ns, anchor => b64(Anchor),
                 instanceText => maps:get(instance, Ctx, <<"human_user(test_agent).">>)},
      public_key => b64(Key), seed => b64(Seed)}.

b64(Bytes) -> base64:encode(Bytes, #{mode => urlsafe, padding => false}).
unb64(Bytes) -> base64:decode(Bytes, #{mode => urlsafe, padding => false}).
