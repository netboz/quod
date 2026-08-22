-module(quod_client_goal_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_client_goal_limits.hrl").

-define(NETWORK, <<16#10:256>>).
-define(ANCHOR, <<16#20:256>>).
-define(OPERATION, <<16#30:256>>).
-define(NAMESPACE, <<"quod:goal-test">>).
-define(DEADLINE, 1_800_000_000_000).

wire_bytes_are_browser_reproducible_test() ->
    PublicKey = <<16#40:256>>,
    Goal = <<"capital(france, X).">>,
    Request = request(PublicKey, read, Goal),
    {ok, Bytes} = quod_client_goal:encode(Request),
    NsBytes = byte_size(?NAMESPACE),
    GoalBytes = byte_size(Goal),
    ?assertEqual(
       <<"quod.user.goal.v1", 0, ?NETWORK/binary, PublicKey/binary,
         ?OPERATION/binary, NsBytes:16/unsigned-big, ?NAMESPACE/binary,
         ?ANCHOR/binary, 0:8, 1:8, ?DEADLINE:64/unsigned-big,
         GoalBytes:32/unsigned-big, Goal/binary>>,
       Bytes),
    ?assertEqual({ok, Request}, quod_client_goal:decode(Bytes)).

browser_ed25519_golden_vector_test() ->
    %% This seed and every expected byte are fixed so a browser implementation
    %% can reproduce the request and WebCrypto Ed25519 signature independently.
    Seed = list_to_binary(lists:seq(0, 31)),
    {PublicKey, Seed} = crypto:generate_key(eddsa, ed25519, Seed),
    ?assertEqual(
       hex(<<"03a107bff3ce10be1d70dd18e74bc099",
             "67e4d6309ba50d5f1ddc8664125531b8">>),
       PublicKey),
    Request = request(
                PublicKey, execute, <<"assertz(saved(ok)).">>),
    {ok, Bytes} = quod_client_goal:encode(Request),
    ?assertEqual(
       hex(<<"71756f642e757365722e676f616c2e763100",
             "0000000000000000000000000000000000000000000000000000000000000010",
             "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8",
             "0000000000000000000000000000000000000000000000000000000000000030",
             "000e71756f643a676f616c2d74657374",
             "0000000000000000000000000000000000000000000000000000000000000020",
             "0101000001a3185c5000000000136173736572747a287361766564286f6b29292e">>),
       Bytes),
    Signature = quod_identity:sign(
                  Bytes, quod_identity:key_term({PublicKey, Seed})),
    ?assertEqual(
       hex(<<"9bf65ef132a84c467b9f14dabb2d4ee74fa090ca31d331c731b884272c08d9e3",
             "3ec943587bee5ca0a74738cc7daa48b23611653abd0cb31501a802b8288af90d">>),
       Signature),
    ?assertEqual(
       {ok, hex(<<"0ad257a5b370e5d5b9ff7bedc15b7ba4",
                  "b8b8b3d9fd473fc0c988eaef9121bfc2">>)},
       quod_client_goal:digest(Bytes)),
    ?assertMatch({ok, _}, quod_client_goal:verify(Bytes, Signature)).

v2_binary_literals_are_signed_as_exact_opaque_bytes_test() ->
    KeyPair = quod_identity:generate(),
    {PublicKey, _} = KeyPair,
    GoalText = <<"capture(<<\"\\x00\\\\n\\xff\\\">>).">>,
    V2 = (request(PublicKey, execute, GoalText))#{parser_version => 2},
    {ok, Bytes} = quod_client_goal:encode(V2),
    Signature = quod_identity:sign(Bytes, quod_identity:key_term(KeyPair)),
    {ok, #{goal := Goal}} = quod_client_goal:verify(Bytes, Signature),
    ?assertEqual(
       {{'$quod_symbol', <<"capture">>}, <<0, $\n, 16#ff>>}, Goal),
    V1 = V2#{parser_version => 1},
    {ok, V1Bytes} = quod_client_goal:encode(V1),
    V1Signature = quod_identity:sign(V1Bytes, quod_identity:key_term(KeyPair)),
    ?assertEqual({error, invalid_goal},
                 quod_client_goal:verify(V1Bytes, V1Signature)).

non_ascii_browser_signature_vector_test() ->
    Seed = list_to_binary(lists:seq(0, 31)),
    {PublicKey, Seed} = crypto:generate_key(eddsa, ed25519, Seed),
    Goal = hex(<<"736179282268c3a96c6cc3b620f09f8c8d22292e">>),
    {ok, Bytes} = quod_client_goal:encode(
                    request(PublicKey, read, Goal)),
    ?assertEqual(Goal, binary:part(
                         Bytes, byte_size(Bytes) - byte_size(Goal),
                         byte_size(Goal))),
    ?assertEqual(
       {ok, hex(<<"293034ffa07b0a7c3b58bf503f829c3f",
                  "bb901cf9e96dd63e9d9b27708017f1fd">>)},
       quod_client_goal:digest(Bytes)),
    Signature = quod_identity:sign(
                  Bytes, quod_identity:key_term({PublicKey, Seed})),
    ?assertEqual(
       hex(<<"6334389dc6bea017fc1626d5e2aec6d52a065a69c0c254a2c2491714d72a5c95",
             "d5a539389fb07b075a9b163471e07aec0b4f8ce27c6d7b5884071772ed639601">>),
       Signature),
    ?assertMatch({ok, _}, quod_client_goal:verify(Bytes, Signature)).

all_mode_tags_roundtrip_test() ->
    lists:foreach(
      fun(Mode) ->
              Request = request(<<16#41:256>>, Mode, <<"true.">>),
              {ok, Bytes} = quod_client_goal:encode(Request),
              ?assertEqual({ok, Request}, quod_client_goal:decode(Bytes))
      end, [read, execute, cursor]).

signature_binds_every_request_field_test() ->
    KeyPair = quod_identity:generate(),
    {PublicKey, _} = KeyPair,
    Request = request(PublicKey, execute, <<"assertz(saved(ok)).">>),
    {ok, Bytes} = quod_client_goal:encode(Request),
    Signature = quod_identity:sign(Bytes, quod_identity:key_term(KeyPair)),
    {ok, Evidence} = quod_client_goal:verify(Bytes, Signature),
    ?assertEqual(crypto:hash(sha256, Bytes),
                 maps:get(request_digest, Evidence)),
    ?assertEqual(
       {operation, ?NAMESPACE, ?ANCHOR, PublicKey, ?OPERATION},
       maps:get(operation_ref, Evidence)),
    lists:foreach(
      fun(Change) ->
              {ok, ChangedBytes} = quod_client_goal:encode(Change(Request)),
              ?assertEqual({error, invalid_signature},
                           quod_client_goal:verify(ChangedBytes, Signature))
      end,
      [fun(R) -> R#{network_identity => <<16#11:256>>} end,
       fun(R) -> R#{user_public_key => <<16#12:256>>} end,
       fun(R) -> R#{operation_id => <<16#31:256>>} end,
       fun(R) -> R#{target_namespace => <<"quod:other">>} end,
       fun(R) -> R#{target_genesis_anchor => <<16#21:256>>} end,
       fun(R) -> R#{mode => cursor} end,
       fun(R) -> R#{not_after_ms => ?DEADLINE + 1} end,
       fun(R) -> R#{goal_text => <<"assertz(saved(no)).">>} end]).

verified_variable_names_bind_the_durable_result_test() ->
    KeyPair = quod_identity:generate(),
    {PublicKey, _} = KeyPair,
    {ok, Bytes} = quod_client_goal:encode(
                    request(PublicKey, execute, <<"pair(X, Y).">>)),
    Signature = quod_identity:sign(
                  Bytes, quod_identity:key_term(KeyPair)),
    {ok, Evidence} = quod_client_goal:verify(Bytes, Signature),
    ?assertEqual(
       {ok, #{<<"X">> => first, <<"Y">> => second}},
       quod_client_goal:durable_bindings(
         Evidence, #{0 => first, 1 => second})),
    %% Results are projected from the signed name table. Proof-only indices,
    %% including anonymous variables, are intentionally not public results.
    ?assertEqual(
       {ok, #{}},
       quod_client_goal:durable_bindings(Evidence, #{2 => unknown})).

anonymous_variables_are_omitted_from_named_results_test() ->
    KeyPair = quod_identity:generate(),
    {PublicKey, _} = KeyPair,
    {ok, Bytes} = quod_client_goal:encode(
                    request(PublicKey, execute, <<"pair(X, _).">>)),
    Signature = quod_identity:sign(
                  Bytes, quod_identity:key_term(KeyPair)),
    {ok, Evidence} = quod_client_goal:verify(Bytes, Signature),
    ?assertEqual(
       {ok, #{<<"X">> => first}},
       quod_client_goal:named_bindings(
         Evidence, #{0 => first, 1 => intentionally_hidden})),
    ?assertEqual(
       {ok, #{<<"X">> => first}},
       quod_client_goal:durable_bindings(
         Evidence, #{0 => first, 1 => intentionally_hidden})).

validator_context_is_exact_and_uses_admission_time_test() ->
    KeyPair = quod_identity:generate(),
    {PublicKey, _} = KeyPair,
    {ok, Bytes} = quod_client_goal:encode(
                    request(PublicKey, read, <<"true.">>)),
    Signature = quod_identity:sign(Bytes, quod_identity:key_term(KeyPair)),
    ?assertMatch(
       {ok, _},
       quod_client_goal:verify_for(
         Bytes, Signature, ?NETWORK, {?NAMESPACE, ?ANCHOR}, ?DEADLINE)),
    ?assertEqual(
       {error, expired},
       quod_client_goal:verify_for(
         Bytes, Signature, ?NETWORK, {?NAMESPACE, ?ANCHOR}, ?DEADLINE + 1)),
    ?assertEqual(
       {error, wrong_network},
       quod_client_goal:verify_for(
         Bytes, Signature, <<16#12:256>>,
         {?NAMESPACE, ?ANCHOR}, ?DEADLINE)),
    ?assertEqual(
       {error, wrong_target},
       quod_client_goal:verify_for(
         Bytes, Signature, ?NETWORK,
         {<<"quod:other">>, ?ANCHOR}, ?DEADLINE)),
    ?assertEqual(
       {error, invalid_admission_time},
       quod_client_goal:verify_for(
         Bytes, Signature, ?NETWORK,
         {?NAMESPACE, ?ANCHOR}, -1)),
    ?assertEqual(
       {error, invalid_admission_time},
       quod_client_goal:verify_for(
         Bytes, Signature, ?NETWORK,
         {?NAMESPACE, ?ANCHOR}, not_a_timestamp)).

decode_is_exact_bounded_and_total_test() ->
    Request = request(<<16#42:256>>, read, <<"true.">>),
    {ok, Bytes} = quod_client_goal:encode(Request),
    ?assertEqual({error, invalid_request},
                 quod_client_goal:decode(<<Bytes/binary, 0>>)),
    ?assertEqual({error, invalid_request},
                 quod_client_goal:decode(binary:part(Bytes, 1,
                                                      byte_size(Bytes) - 1))),
    ?assertEqual(
       {error, {too_large, request}},
       quod_client_goal:decode(
         <<0:(?QUOD_CLIENT_GOAL_REQUEST_BYTES + 1)/unit:8>>)),
    ?assertEqual({error, invalid_signature},
                 quod_client_goal:verify(Bytes, <<0:512>>)),
    ?assertEqual({error, invalid_signature},
                 quod_client_goal:verify(Bytes, <<0:8>>)).

invalid_goal_is_rejected_after_authentication_test() ->
    KeyPair = quod_identity:generate(),
    {PublicKey, _} = KeyPair,
    {ok, Bytes} = quod_client_goal:encode(
                    request(PublicKey, read, <<"not closed(">>)),
    Signature = quod_identity:sign(Bytes, quod_identity:key_term(KeyPair)),
    ?assertEqual({error, invalid_goal},
                 quod_client_goal:verify(Bytes, Signature)).

field_bounds_and_utf8_are_rejected_before_signature_work_test() ->
    PublicKey = <<16#43:256>>,
    Base = request(PublicKey, read, <<"true.">>),
    ExactGoal =
        iolist_to_binary(
          [lists:duplicate(?QUOD_CLIENT_GOAL_TEXT_BYTES - 5, " "),
           "true."]),
    ExactNamespace =
        binary:copy(<<"n">>, ?DIRECTORY_MAX_NAMESPACE_BYTES),
    Exact = Base#{target_namespace => ExactNamespace,
                  goal_text => ExactGoal},
    {ok, ExactBytes} = quod_client_goal:encode(Exact),
    ?assertEqual({ok, Exact}, quod_client_goal:decode(ExactBytes)),
    ?assertEqual(
       {error, invalid_request},
       quod_client_goal:encode(Base#{unexpected => value})),
    ?assertEqual(
       {error, invalid_request},
       quod_client_goal:encode(Base#{parser_version => 3})),
    ?assertEqual(
       {error, {too_large, namespace}},
       quod_client_goal:encode(
         Base#{target_namespace =>
                   binary:copy(<<"n">>,
                               ?DIRECTORY_MAX_NAMESPACE_BYTES + 1)})),
    ?assertEqual(
       {error, {too_large, goal_text}},
       quod_client_goal:encode(
         Base#{goal_text =>
                   binary:copy(<<"g">>,
                               ?QUOD_CLIENT_GOAL_TEXT_BYTES + 1)})),
    ?assertEqual(
       {error, invalid_request},
       quod_client_goal:encode(Base#{goal_text => <<16#ff>>})).

request(PublicKey, Mode, GoalText) ->
    #{network_identity => ?NETWORK,
      user_public_key => PublicKey,
      operation_id => ?OPERATION,
      target_namespace => ?NAMESPACE,
      target_genesis_anchor => ?ANCHOR,
      mode => Mode,
      parser_version => 1,
      not_after_ms => ?DEADLINE,
      goal_text => GoalText}.

hex(Bytes) ->
    binary:decode_hex(Bytes).
