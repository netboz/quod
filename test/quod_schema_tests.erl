-module(quod_schema_tests).
-include_lib("eunit/include/eunit.hrl").

%% A minimal valid config as a HOCON binary.
conf() ->
    <<"node { ip = \"10.0.0.1\", port = 14000 }\n"
      "metrics { port = 14001 }\n"
      "content { namespace = \"quod:root\", mode = create, "
      "genesis_file = \"ontologies/quod_root.pl\", seeds = [\"1.2.3.4:14567\"] }\n">>.

check(Bin) ->
    {ok, Raw} = hocon:binary(Bin, #{format => map}),
    hocon_tconf:check_plain(quod_schema, Raw,
                            #{atom_key => true, apply_override_envs => true}).

%% --- defaults + parsing -------------------------------------------------

parse_test() ->
    C = check(conf()),
    ?assertEqual(<<"10.0.0.1">>, deep(C, [node, ip])),
    ?assertEqual(14000,          deep(C, [node, port])),
    ?assertEqual(14001,          deep(C, [metrics, port])),
    ?assertEqual(<<"quod:root">>, deep(C, [content, namespace])),
    ?assertEqual(create,         deep(C, [content, mode])),
    ?assertEqual([<<"1.2.3.4:14567">>], deep(C, [content, seeds])).

defaults_test() ->
    %% omit node.ip and metrics → schema defaults apply
    C = check(<<"content { namespace = \"quod:root\" }\n">>),
    ?assertEqual(<<"127.0.0.1">>, deep(C, [node, ip])),
    ?assertEqual(14567,           deep(C, [node, port])),
    ?assertEqual(14568,           deep(C, [metrics, port])),
    ?assertEqual(<<"">>,          deep(C, [identity, dir])),
    ?assertEqual(create,          deep(C, [content, mode])),
    ?assertEqual(<<"ontologies/quod_root.pl">>, deep(C, [content, genesis_file])),
    ?assertEqual([],              deep(C, [content, seeds])).

%% --- boot wiring: load_config generates + exposes the node identity ------

boot_identity_test() ->
    _ = application:load(quod),
    U   = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join("/tmp", "quod_boot_id_" ++ U),
    ok  = filelib:ensure_dir(filename:join(Dir, "x")),
    Conf = ["node { ip = \"127.0.0.1\", port = 14999 }\n",
            "content { namespace = \"bootid:", U, "\", mode = join, "
            "data_dir = \"", Dir, "\" }\n"],
    ConfPath = filename:join(Dir, "quod.conf"),
    ok = file:write_file(ConfPath, Conf),
    os:putenv("QUOD_CONF", ConfPath),
    [application:unset_env(quod, K) || K <- [node_pubkey, identity_cert, identity_key]],
    try
        _ = quod_app:load_config(),
        {ok, Pub} = application:get_env(quod, node_pubkey),
        ?assertEqual(32, byte_size(Pub)),
        %% the keypair was persisted under <data_dir>/identity, and the cert carries it
        ?assert(filelib:is_regular(filename:join([Dir, "identity", "node.key"]))),
        {ok, Cert} = application:get_env(quod, identity_cert),
        ?assertEqual({ok, Pub}, quod_identity:pubkey_of_cert(Cert)),
        ?assertMatch({ok, _}, application:get_env(quod, identity_key))
    after
        os:unsetenv("QUOD_CONF"),
        [application:unset_env(quod, K) || K <- [node_pubkey, identity_cert, identity_key]],
        _ = file:del_dir_r(Dir)
    end.

%% --- env overrides individual keys, file stays primary -------------------

env_override_test_() ->
    {setup,
     fun() ->
         os:putenv("HOCON_ENV_OVERRIDE_PREFIX", "QUOD_"),
         os:putenv("QUOD_CONTENT__MODE", "join"),
         os:putenv("QUOD_NODE__PORT", "15000")
     end,
     fun(_) ->
         os:unsetenv("HOCON_ENV_OVERRIDE_PREFIX"),
         os:unsetenv("QUOD_CONTENT__MODE"),
         os:unsetenv("QUOD_NODE__PORT")
     end,
     fun() ->
         C = check(conf()),
         %% env wins over the file value
         ?assertEqual(join,  deep(C, [content, mode])),
         ?assertEqual(15000, deep(C, [node, port])),
         %% untouched keys keep their file value
         ?assertEqual(<<"10.0.0.1">>, deep(C, [node, ip]))
     end}.

deep(Map, Path) -> lists:foldl(fun(K, M) -> maps:get(K, M) end, Map, Path).
