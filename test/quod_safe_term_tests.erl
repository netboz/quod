-module(quod_safe_term_tests).

-include_lib("eunit/include/eunit.hrl").

untrusted_etf_guards_test() ->
    Encoded = term_to_binary({ok, <<1, 2, 3>>}, [deterministic]),
    ?assertEqual(
       {ok, {ok, <<1, 2, 3>>}},
       quod_safe_term:decode(Encoded, byte_size(Encoded))),
    ?assertEqual(
       {error, too_large},
       quod_safe_term:decode(Encoded, byte_size(Encoded) - 1)),
    ?assertEqual(
       {error, trailing_data},
       quod_safe_term:decode(<<Encoded/binary, 0>>, byte_size(Encoded) + 1)),
    Compressed = term_to_binary(
                   {binary:copy(<<"compress">>, 200)}, [{compressed, 9}]),
    ?assertMatch(<<131, 80, _/binary>>, Compressed),
    ?assertEqual(
       {error, compressed},
       quod_safe_term:decode(Compressed, byte_size(Compressed))),
    Unknown = <<"quod_safe_term_unknown_atom_6f1868f4">>,
    UnknownAtomEtf = <<131, 119, (byte_size(Unknown)):8, Unknown/binary>>,
    ?assertEqual(
       {error, bad_term},
       quod_safe_term:decode(
         UnknownAtomEtf, byte_size(UnknownAtomEtf))).
