-module(quod_quic_certkey_tests).
-moduledoc """
`quod_quic:identity_certkey/0` must resolve the transport cert+key to either
`{ok, {Cert, Key}}` or a clean `{error, Reason}` — never a badmatch or a thrown
`der_decode` that crashes the transport's `init/1` at boot (doc/deferred:
PEM-fallback badmatch).

Production sets the identity env (`identity_cert`/`identity_key`) via
`quod_app:apply_identity`; the PEM file pair (`certfile`/`keyfile`) is only the
explicit configuration-free test fallback, and a missing, empty, or malformed file there is
reported, not crashed on.
""".
-include_lib("eunit/include/eunit.hrl").

%% Snapshot the four env keys this function reads, run the body, restore them —
%% so a set/unset here never leaks into another test in the same VM.
with_clean_env(Body) ->
    Keys = [identity_cert, identity_key, certfile, keyfile],
    Saved = [{K, application:get_env(quod, K)} || K <- Keys],
    [application:unset_env(quod, K) || K <- Keys],
    try Body()
    after
        [application:unset_env(quod, K) || K <- Keys],
        [case V of
             {ok, Val} -> application:set_env(quod, K, Val);
             undefined -> ok
         end || {K, V} <- Saved]
    end.

%% Write a temp PEM, run Body(Path), and delete it even if Body throws — no build-tree litter.
with_tmp_file(Name, Bytes, Body) ->
    Path = filename:join(os:getenv("TMPDIR", "/tmp"), Name ++ ".pem"),
    ok = file:write_file(Path, Bytes),
    try Body(Path)
    after file:delete(Path)
    end.

%% A real, decodable self-signed cert PEM (so load_cert succeeds and we reach the key half).
real_cert_pem() ->
    KP = quod_identity:generate(),
    public_key:pem_encode([{'Certificate', quod_identity:mint_cert(KP), not_encrypted}]).

%% The identity env is the production path: the cert+key are returned verbatim.
identity_env_returns_pair_test() ->
    with_clean_env(fun() ->
        application:set_env(quod, identity_cert, my_cert_der),
        application:set_env(quod, identity_key, my_key_term),
        ?assertEqual({ok, {my_cert_der, my_key_term}}, quod_quic:identity_certkey())
    end).

%% No identity env and a certfile that does not exist: a clean, file-tagged error,
%% NOT a `{ok, _} = file:read_file(...)` badmatch that would crash init/1.
missing_certfile_is_clean_error_test() ->
    with_clean_env(fun() ->
        application:set_env(quod, certfile, "/no/such/dir/cert.pem"),
        application:set_env(quod, keyfile, "/no/such/dir/key.pem"),
        ?assertEqual({error, {certfile, "/no/such/dir/cert.pem", enoent}},
                     quod_quic:identity_certkey())
    end).

%% A certfile that exists but carries no 'Certificate' entry is reported by name.
empty_certfile_is_clean_error_test() ->
    with_clean_env(fun() ->
        with_tmp_file("quod-empty-cert", <<>>, fun(CertFile) ->
            application:set_env(quod, certfile, CertFile),
            application:set_env(quod, keyfile, "/no/such/dir/key.pem"),
            ?assertEqual({error, {certfile, CertFile, no_certificate_in_pem}},
                         quod_quic:identity_certkey())
        end)
    end).

%% A valid cert but a missing keyfile fails on the KEY half, tagged as such.
missing_keyfile_is_clean_error_test() ->
    with_clean_env(fun() ->
        with_tmp_file("quod-real-cert", real_cert_pem(), fun(CertFile) ->
            application:set_env(quod, certfile, CertFile),
            application:set_env(quod, keyfile, "/no/such/dir/key.pem"),
            ?assertEqual({error, {keyfile, "/no/such/dir/key.pem", enoent}},
                         quod_quic:identity_certkey())
        end)
    end).

%% A keyfile that PARSES as a private-key PEM entry but whose DER is garbage must
%% surface as a clean error — `public_key:der_decode/2` throws on it, and the guard
%% must catch that so init/1 gets `{error, _}` instead of a boot crash.
malformed_keyfile_is_clean_error_test() ->
    Garbage = <<"-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----\n">>,
    with_clean_env(fun() ->
        with_tmp_file("quod-real-cert2", real_cert_pem(), fun(CertFile) ->
            with_tmp_file("quod-bad-key", Garbage, fun(KeyFile) ->
                application:set_env(quod, certfile, CertFile),
                application:set_env(quod, keyfile, KeyFile),
                ?assertEqual({error, {keyfile, KeyFile,
                                      {undecodable_private_key, 'RSAPrivateKey'}}},
                             quod_quic:identity_certkey())
            end)
        end)
    end).
