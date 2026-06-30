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
    Dir = tmp_dir(),
    try
        ConfPath = write_boot_conf(Dir, ""),    %% no explicit identity.dir ⇒ <data_dir>/identity
        os:putenv("QUOD_CONF", ConfPath),
        clear_identity_env(),
        _ = quod_app:load_config(),
        {ok, Pub} = application:get_env(quod, node_pubkey),
        ?assertEqual(32, byte_size(Pub)),
        %% the keypair was persisted under <data_dir>/identity, and the cert carries it
        ?assert(filelib:is_regular(filename:join([Dir, "identity", "node.key"]))),
        {ok, Cert} = application:get_env(quod, identity_cert),
        ?assertEqual({ok, Pub}, quod_identity:pubkey_of_cert(Cert)),
        ?assertMatch({ok, _}, application:get_env(quod, identity_key)),
        %% load-or-create: a SECOND boot reloads the SAME identity (durability — the
        %% whole point of persisting node.key), it does NOT regenerate.
        clear_identity_env(),
        _ = quod_app:load_config(),
        ?assertEqual({ok, Pub}, application:get_env(quod, node_pubkey))
    after
        reset_boot_env(),
        _ = file:del_dir_r(Dir)
    end.

%% An explicit `identity { dir = ... }` wins over the <data_dir>/identity default.
identity_dir_override_test() ->
    _ = application:load(quod),
    Dir   = tmp_dir(),
    IdDir = filename:join(Dir, "custom_id"),
    try
        ConfPath = write_boot_conf(Dir, IdDir),
        os:putenv("QUOD_CONF", ConfPath),
        clear_identity_env(),
        _ = quod_app:load_config(),
        ?assert(filelib:is_regular(filename:join(IdDir, "node.key"))),
        ?assertNot(filelib:is_regular(filename:join([Dir, "identity", "node.key"])))
    after
        reset_boot_env(),
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

%% --- boot-test helpers ---------------------------------------------------

tmp_dir() ->
    filename:join("/tmp", "quod_boot_id_" ++ integer_to_list(erlang:unique_integer([positive]))).

%% Write a minimal HOCON config into Dir (with content.data_dir = Dir). IdDir = "" omits
%% the identity block (default resolution); a non-empty IdDir pins `identity.dir`.
write_boot_conf(Dir, IdDir) ->
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    U  = filename:basename(Dir),
    IdBlock = case IdDir of "" -> ""; _ -> ["identity { dir = \"", IdDir, "\" }\n"] end,
    Conf = ["node { ip = \"127.0.0.1\", port = 14999 }\n",
            IdBlock,
            "content { namespace = \"bootid:", U, "\", data_dir = \"", Dir, "\" }\n"],
    ConfPath = filename:join(Dir, "quod.conf"),
    ok = file:write_file(ConfPath, Conf),
    ConfPath.

clear_identity_env() ->
    _ = [application:unset_env(quod, K) || K <- [node_pubkey, identity_cert, identity_key]],
    ok.

%% load_config sets HOCON_ENV_OVERRIDE_PREFIX globally — unset it (and QUOD_CONF + the
%% identity env) so the boot tests don't leak state into the rest of the eunit VM.
reset_boot_env() ->
    os:unsetenv("QUOD_CONF"),
    os:unsetenv("HOCON_ENV_OVERRIDE_PREFIX"),
    clear_identity_env().
