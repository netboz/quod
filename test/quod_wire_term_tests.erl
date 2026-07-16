-module(quod_wire_term_tests).
-include_lib("eunit/include/eunit.hrl").

roundtrip_existing_terms_test() ->
    Term = {diet, dog, [kibble, <<"raw">>, 42, 1.5 | tail]},
    {ok, Wire} = quod_wire_term:encode(Term),
    ?assertEqual({ok, Term}, quod_wire_term:decode(Wire)).

unknown_symbol_does_not_allocate_atom_test() ->
    Symbol = <<"quod_wire_never_intern_", (integer_to_binary(
                 erlang:unique_integer([positive])))/binary>>,
    ?assertException(error, badarg, binary_to_existing_atom(Symbol, utf8)),
    ?assertEqual({ok, {'$quod_symbol', Symbol}},
                 quod_wire_term:decode({0, Symbol})),
    ?assertException(error, badarg, binary_to_existing_atom(Symbol, utf8)),
    {ok, Wire} = quod_wire_term:encode({'$quod_symbol', Symbol}),
    ?assertEqual({0, Symbol}, Wire).

unknown_predicate_becomes_fail_only_functor_test() ->
    Symbol = <<"quod_unknown_predicate">>,
    WireGoal = {4, [{0, Symbol}, {0, <<"x">>}]},
    ?assertMatch({ok, {'$quod_unknown_goal', _}},
                 quod_wire_term:decode_goal(WireGoal)).

depth_limit_test() ->
    Deep = lists:foldl(fun(_, Acc) -> [Acc] end, ok, lists:seq(1, 70)),
    ?assertEqual({error, bad_term}, quod_wire_term:encode(Deep)).
