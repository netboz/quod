-module(quod_durable_term_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_proof_limits.hrl").

atom_and_opaque_symbol_have_identical_bytes_test() ->
    AtomGoal = {durable_symbol_test, value},
    OpaqueGoal = {{'$quod_symbol', <<"durable_symbol_test">>}, value},
    {ok, Blob} = quod_durable_term:encode_goal(AtomGoal),
    ?assertEqual({ok, Blob}, quod_durable_term:encode_goal(OpaqueGoal)),
    ?assertEqual({ok, AtomGoal}, quod_durable_term:decode_goal(Blob)).

unknown_symbol_remains_roundtripable_data_test() ->
    Symbol = <<"quod_durable_term_symbol_that_is_not_an_atom_913741">>,
    Goal = {{'$quod_symbol', Symbol}, 42},
    {ok, Blob} = quod_durable_term:encode_goal(Goal),
    ?assertEqual({ok, Goal}, quod_durable_term:decode_goal(Blob)),
    ?assertEqual({ok, Blob}, quod_durable_term:encode_goal(Goal)).

result_names_are_canonical_binary_keys_test() ->
    {ok, Blob} = quod_durable_term:encode_result(#{z => 2, a => 1}),
    ?assertEqual({ok, [{<<"a">>, 1}, {<<"z">>, 2}]},
                 quod_durable_term:decode_result(Blob)),
    ?assertEqual(
       {ok, Blob},
       quod_durable_term:encode_result(#{<<"z">> => 2, <<"a">> => 1})).

duplicate_result_names_are_rejected_test() ->
    {ok, Wire} = quod_wire_term:encode(
                   [{<<"same">>, 1}, {<<"same">>, 2}]),
    Blob = term_to_binary(Wire, [deterministic]),
    ?assertEqual({error, invalid_result},
                 quod_durable_term:decode_result(Blob)).

empty_result_name_is_rejected_before_encoding_test() ->
    ?assertEqual({error, invalid_result},
                 quod_durable_term:encode_result(#{'' => value})),
    ?assertEqual(
       {error, invalid_result},
       quod_durable_term:encode_result(#{same => 1, <<"same">> => 2})).

noncanonical_etf_is_rejected_test() ->
    Goal = lists:duplicate(200, durable_repeated_value),
    {ok, Wire} = quod_wire_term:encode(Goal),
    Compressed = term_to_binary(Wire, [compressed]),
    ?assertMatch(<<131, 80, _/binary>>, Compressed),
    ?assertEqual({error, bad_term},
                 quod_durable_term:decode_goal(Compressed)).

malformed_wire_and_nonidentity_roundtrip_are_total_test() ->
    Improper = term_to_binary({4, [{2, 1} | 5]}, [deterministic]),
    Ambiguous = term_to_binary(
                  {4, [{0, <<"$quod_symbol">>}, {1, <<"foo">>}]},
                  [deterministic]),
    ?assertEqual({error, bad_term},
                 quod_durable_term:decode_goal(Improper)),
    ?assertEqual({error, bad_term},
                 quod_durable_term:decode_goal(Ambiguous)).

size_limits_are_checked_before_decode_test() ->
    ?assertEqual(
       {error, {too_large, goal}},
       quod_durable_term:decode_goal(
         <<0:(?QUOD_MAX_TOPLEVEL_GOAL_BYTES + 1)/unit:8>>)),
    ?assertEqual(
       {error, {too_large, result}},
       quod_durable_term:decode_result(
         <<0:(?QUOD_MAX_DURABLE_RESULT_BYTES + 1)/unit:8>>)).
