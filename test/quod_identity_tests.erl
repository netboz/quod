-module(quod_identity_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("public_key/include/public_key.hrl").

%% generate/0 yields a 32-byte Ed25519 public key + 32-byte seed; key_term/1 wraps
%% them in the standard ECPrivateKey form public_key/quic sign with.
generate_shape_test() ->
    {Pub, Seed} = quod_identity:generate(),
    ?assertEqual(32, byte_size(Pub)),
    ?assertEqual(32, byte_size(Seed)),
    ?assertMatch(#'ECPrivateKey'{privateKey = Seed,
                                 parameters = {namedCurve, ?'id-Ed25519'},
                                 publicKey = Pub},
                 quod_identity:key_term({Pub, Seed})).

%% A minted self-signed cert round-trips: the recovered pubkey == the keypair's pubkey.
cert_roundtrip_test() ->
    {Pub, _} = KP = quod_identity:generate(),
    DER = quod_identity:mint_cert(KP),
    ?assert(is_binary(DER)),
    ?assertEqual({ok, Pub}, quod_identity:pubkey_of_cert(DER)).

%% pubkey_of_cert recovers a key from a cert minted by a DIFFERENT keypair (the real
%% peercert case — the cert is not our own), and REJECTS garbage instead of crashing.
pubkey_of_foreign_cert_test() ->
    {Pub, _} = KP = quod_identity:generate(),
    DER = quod_identity:mint_cert(KP),
    ?assertEqual({ok, Pub}, quod_identity:pubkey_of_cert(DER)),
    ?assertEqual(error, quod_identity:pubkey_of_cert(<<"not-a-cert">>)),
    ?assertEqual(error, quod_identity:pubkey_of_cert(<<>>)).

%% Minting from the same seed is deterministic (same cert bytes), so a re-mint on
%% restart yields the same identity.
mint_deterministic_test() ->
    KP = quod_identity:generate(),
    ?assertEqual(quod_identity:mint_cert(KP), quod_identity:mint_cert(KP)).

%% ensure/1 generates + persists on first call, then reloads the SAME identity.
ensure_create_then_reload_test() ->
    Dir = tmp_dir(),
    try
        {ok, Id1} = quod_identity:ensure(Dir),
        ?assertEqual(32, byte_size(maps:get(pubkey, Id1))),
        %% the persisted secret is the 32-byte seed, locked down
        KeyFile = filename:join(Dir, "node.key"),
        ?assert(filelib:is_regular(KeyFile)),
        {ok, #file_info{size = 32, mode = Mode}} = file:read_file_info(KeyFile),
        ?assertEqual(8#600, Mode band 8#777),
        %% reload yields the identical pubkey + cert + key
        {ok, Id2} = quod_identity:ensure(Dir),
        ?assertEqual(Id1, Id2),
        %% the cert really carries that pubkey, and no readable tmp is left behind
        ?assertEqual({ok, maps:get(pubkey, Id1)},
                     quod_identity:pubkey_of_cert(maps:get(cert, Id1))),
        ?assertNot(filelib:is_regular(filename:join(Dir, "node.key.tmp")))
    after
        rm_rf(Dir)
    end.

%% A write failure (here: a data dir whose parent is a regular file) is RELAYED as
%% {error, _}, never a badmatch crash — so a node boot can report it cleanly.
ensure_write_failure_test() ->
    Base = tmp_dir(),
    ok = file:write_file(Base, <<"i am a file, not a dir">>),   %% Base is a regular file
    try
        Dir = filename:join(Base, "sub"),                       %% ensure_dir(Dir/node.key) must fail
        ?assertMatch({error, _}, quod_identity:ensure(Dir))
    after
        _ = file:delete(Base)
    end.

%% Two different dirs get two distinct identities (multiple nodes per host).
ensure_distinct_per_dir_test() ->
    A = tmp_dir(), B = tmp_dir(),
    try
        {ok, IdA} = quod_identity:ensure(A),
        {ok, IdB} = quod_identity:ensure(B),
        ?assertNotEqual(maps:get(pubkey, IdA), maps:get(pubkey, IdB))
    after
        rm_rf(A), rm_rf(B)
    end.

%% A corrupt identity file is reported, not silently treated as a key.
bad_identity_file_test() ->
    Dir = tmp_dir(),
    try
        ok = filelib:ensure_dir(filename:join(Dir, "x")),
        ok = file:write_file(filename:join(Dir, "node.key"), <<"not-a-32-byte-seed">>),
        ?assertEqual({error, bad_identity_file}, quod_identity:ensure(Dir))
    after
        rm_rf(Dir)
    end.

directory_epoch_is_durable_and_strictly_increases_test() ->
    Dir = tmp_dir(),
    try
        ?assertEqual({ok, 1}, quod_identity:advance_directory_epoch(Dir)),
        ?assertEqual({ok, 2}, quod_identity:advance_directory_epoch(Dir)),
        ?assertEqual(
           {ok, <<2:64/unsigned-big>>},
           file:read_file(filename:join(Dir, "directory.epoch"))),
        ?assertNot(
           filelib:is_regular(filename:join(Dir, "directory.epoch.tmp")))
    after
        rm_rf(Dir)
    end.

corrupt_directory_epoch_fails_closed_test() ->
    Dir = tmp_dir(),
    try
        ok = filelib:ensure_dir(filename:join(Dir, "x")),
        ok = file:write_file(
               filename:join(Dir, "directory.epoch"), <<"bad">>),
        ?assertEqual(
           {error, bad_directory_epoch_file},
           quod_identity:advance_directory_epoch(Dir))
    after
        rm_rf(Dir)
    end.

short_format_test() ->
    {Pub, _} = quod_identity:generate(),
    S = quod_identity:short(Pub),
    ?assertMatch(<<"kp_", _/binary>>, S),
    %% kp_ + 8 hex chars (first 4 bytes)
    ?assertEqual(11, byte_size(S)).

%% --- helpers ---

tmp_dir() ->
    filename:join("/tmp", "quod_id_test_" ++ integer_to_list(erlang:unique_integer([positive]))).

rm_rf(Dir) ->
    _ = [file:delete(F) || F <- filelib:wildcard(filename:join(Dir, "*"))],
    _ = file:del_dir(Dir),
    ok.
