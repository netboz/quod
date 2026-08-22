-module(quod_user_tests).

-include_lib("eunit/include/eunit.hrl").

deterministic_identity_test() ->
    Key = <<16#42:256>>,
    {ok, #{user_id := UserId,
           namespace := Namespace,
           public_key := Key}} = quod_user:identity(Key),
    ?assertMatch(<<"user-", _:64/binary>>, UserId),
    ?assertMatch(<<"user:", _:64/binary>>, Namespace),
    ?assertEqual({ok, Namespace}, quod_user:home_namespace(Key)),
    ?assertEqual({ok, {user, Key}}, quod_user:principal(Key)),
    ?assertNotEqual(
       {ok, Namespace},
       quod_user:home_namespace(<<16#43:256>>)).

fixed_home_genesis_test() ->
    Key = <<16#24:256>>,
    {ok, #{user_id := UserId, namespace := Namespace}} =
        quod_user:identity(Key),
    {ok, Options} = quod_user:home_options(Key),
    %% The exact genesis a registration is allowed to found: four facts derived
    %% from the key, plus the one fixed owner rule.
    ?assertEqual(
       [{terms, [{user, UserId},
                 {user_key, UserId, Key, active},
                 {user_home, UserId, Namespace},
                 {user_home_version, 1}]},
        {source, <<"can_invoke(_, user(Key), _, _) :- user_key(_, Key, active).\n">>}],
       Options),
    ?assertEqual({ok, Namespace}, quod_user:home_namespace(Key)).

invalid_public_key_test() ->
    ?assertEqual({error, invalid_public_key}, quod_user:identity(<<1, 2, 3>>)),
    ?assertEqual({error, invalid_public_key}, quod_user:home_options(not_a_key)),
    ?assertEqual({error, invalid_public_key}, quod_user:principal(<<1, 2, 3>>)).

signed_wire_bytes_are_browser_reproducible_test() ->
    Network = <<16#10:256>>,
    Node = <<16#11:256>>,
    ChallengeId = <<16#12:128>>,
    PublicKey = <<16#13:256>>,
    ClientNonce = <<16#14:256>>,
    ServerNonce = <<16#15:256>>,
    Expires = 1_700_000_000_000,
    {ok, Challenge} = quod_user:challenge_bytes(
                        Network, Node, ChallengeId, PublicKey, ClientNonce,
                        ServerNonce, Expires),
    ?assertEqual(
       <<"quod_user_challenge_v1", 0, Network/binary, Node/binary,
         ChallengeId/binary, PublicKey/binary, ClientNonce/binary,
         ServerNonce/binary, Expires:64/unsigned-big>>, Challenge).

challenge_is_bound_to_node_and_expiry_test() ->
    Network = <<16#10:256>>,
    Node = <<16#11:256>>,
    ChallengeId = <<16#12:128>>,
    ClientNonce = <<16#13:256>>,
    ServerNonce = <<16#14:256>>,
    Expires = 1_700_000_000_000,
    {PublicKey, _Seed} = KeyPair = quod_identity:generate(),
    {ok, Bytes} = quod_user:challenge_bytes(
                    Network, Node, ChallengeId, PublicKey, ClientNonce,
                    ServerNonce, Expires),
    Signature = quod_identity:sign(Bytes, quod_identity:key_term(KeyPair)),
    ?assertEqual(
       ok,
       quod_user:verify_challenge(
         Network, Node, ChallengeId, PublicKey, ClientNonce, ServerNonce,
         {Expires, Signature})),
    ?assertEqual(
       {error, invalid_challenge_signature},
       quod_user:verify_challenge(
         Network, <<16#15:256>>, ChallengeId, PublicKey, ClientNonce,
         ServerNonce, {Expires, Signature})),
    ?assertEqual(
       {error, invalid_challenge_signature},
       quod_user:verify_challenge(
         Network, Node, ChallengeId, PublicKey, ClientNonce, ServerNonce,
         {Expires + 1, Signature})).
