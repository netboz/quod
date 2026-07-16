-module(quod_schema_tests).
-include_lib("eunit/include/eunit.hrl").

%% A minimal valid config as a HOCON binary. `content` is a LIST of ontology blocks.
conf() ->
    <<"node { ip = \"10.0.0.1\", port = 14000 }\n"
      "metrics { port = 14001 }\n"
      "content = [{ namespace = \"quod:root\", mode = create, "
      "genesis_file = \"ontologies/quod_root.pl\", seeds = [\"1.2.3.4:14567\"] }]\n">>.

check(Bin) ->
    {ok, Raw} = hocon:binary(Bin, #{format => map}),
    hocon_tconf:check_plain(quod_schema, Raw,
                            #{atom_key => true, apply_override_envs => true}).

%% The single content block of a checked config (the common one-ontology case).
content1(C) -> [Block] = maps:get(content, C), Block.

%% --- defaults + parsing -------------------------------------------------

parse_test() ->
    C = check(conf()),
    ?assertEqual(<<"10.0.0.1">>, deep(C, [node, ip])),
    ?assertEqual(14000,          deep(C, [node, port])),
    ?assertEqual(14001,          deep(C, [metrics, port])),
    B = content1(C),
    ?assertEqual(<<"quod:root">>, maps:get(namespace, B)),
    ?assertEqual(create,          maps:get(mode, B)),
    ?assertEqual([<<"1.2.3.4:14567">>], maps:get(seeds, B)).

defaults_test() ->
    %% omit node.ip and metrics → schema defaults apply (incl. inside a content entry)
    C = check(<<"content = [{ namespace = \"quod:root\" }]\n">>),
    ?assertEqual(<<"127.0.0.1">>, deep(C, [node, ip])),
    ?assertEqual(14567,           deep(C, [node, port])),
    ?assertEqual(14568,           deep(C, [metrics, port])),
    ?assertEqual(<<"">>,          deep(C, [identity, dir])),
    B = content1(C),
    ?assertEqual(create,          maps:get(mode, B)),
    ?assertEqual(<<"ontologies/quod_root.pl">>, maps:get(genesis_file, B)),
    ?assertEqual([],              maps:get(seeds, B)).

%% Two ontologies side by side: each entry keeps its own mode/anchor.
two_ontologies_test() ->
    C = check(<<"content = [{ namespace = \"quod:root\" },\n"
                "           { namespace = \"animals\", mode = join, genesis_hash = \"ff\" }]\n">>),
    [B1, B2] = maps:get(content, C),
    ?assertEqual(<<"quod:root">>, maps:get(namespace, B1)),
    ?assertEqual(create,          maps:get(mode, B1)),
    ?assertEqual(<<"animals">>,   maps:get(namespace, B2)),
    ?assertEqual(join,            maps:get(mode, B2)),
    ?assertEqual(<<"ff">>,        maps:get(genesis_hash, B2)).

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
    %% Scalar keys are env-overridable; the `content` LIST is not (deploys render the file).
    {setup,
     fun() ->
         os:putenv("HOCON_ENV_OVERRIDE_PREFIX", "QUOD_"),
         os:putenv("QUOD_NODE__PORT", "15000")
     end,
     fun(_) ->
         os:unsetenv("HOCON_ENV_OVERRIDE_PREFIX"),
         os:unsetenv("QUOD_NODE__PORT")
     end,
     fun() ->
         C = check(conf()),
         %% env wins over the file value
         ?assertEqual(15000, deep(C, [node, port])),
         %% untouched keys keep their file value
         ?assertEqual(<<"10.0.0.1">>, deep(C, [node, ip])),
         ?assertEqual(create, maps:get(mode, content1(C)))
     end}.

%% --- genesis_hash: schema field + build_ns_config hex→binary plumbing ----

genesis_hash_default_test() ->
    C = check(<<"content = [{ namespace = \"quod:root\" }]\n">>),
    ?assertEqual(<<"">>, maps:get(genesis_hash, content1(C))).

genesis_hash_parse_test() ->
    Hex = <<"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff">>,
    C = check(<<"content = [{ namespace = \"quod:root\", mode = join, genesis_hash = \"",
                Hex/binary, "\" }]\n">>),
    B = content1(C),
    ?assertEqual(join, maps:get(mode, B)),
    ?assertEqual(Hex,  maps:get(genesis_hash, B)).

%% A mode=join content config with a hex genesis_hash lands in the ns config as the raw 32-byte binary
%% quod_simplex pins, with mode + seeds forwarded. (genesis_file/data_dir left "" so build_ns_config
%% doesn't touch code:priv_dir in the eunit VM.)
build_ns_config_genesis_hash_test() ->
    Raw = crypto:strong_rand_bytes(32),
    Content = #{namespace => <<"quod:root">>, mode => join, role => member, seeds => [<<"1.2.3.4:14567">>],
                genesis_file => <<"">>, data_dir => <<"">>, genesis_hash => binary:encode_hex(Raw)},
    {<<"quod:root">>, NsCfg} = quod_app:build_ns_config(Content),
    ?assertEqual(join, maps:get(mode, NsCfg)),
    ?assertEqual(Raw,  maps:get(genesis_hash, NsCfg)),
    ?assertEqual([{"1.2.3.4", 14567}], maps:get(seed_peers, NsCfg)).

%% A create node (blank genesis_hash) carries no anchor key at all — quod_simplex needs none.
build_ns_config_no_genesis_hash_test() ->
    Content = #{namespace => <<"quod:root">>, mode => create, role => member, seeds => [],
                genesis_file => <<"">>, data_dir => <<"">>, genesis_hash => <<"">>},
    {_, NsCfg} = quod_app:build_ns_config(Content),
    ?assertNot(maps:is_key(genesis_hash, NsCfg)).

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
            "content = [{ namespace = \"bootid:", U, "\", data_dir = \"", Dir, "\" }]\n"],
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
