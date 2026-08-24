-module(quod_quorum_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ingress_limits.hrl").

threshold_matches_simplex_rule_test() ->
    ?assertEqual([{1, 1}, {3, 3}, {4, 3}, {7, 5}, {64, 43}],
                 [{N, quod_quorum:threshold(N)} || N <- [1, 3, 4, 7, 64]]).

committee_and_signature_bounds_are_shared_test() ->
    Members = [<<N:256>> || N <- lists:seq(1, ?MAX_VALIDATORS)],
    ?assertEqual({ok, ?MAX_VALIDATORS},
                 quod_quorum:committee_size(Members)),
    ?assertEqual(error,
                 quod_quorum:committee_size(Members ++ [<<0:256>>])),
    ?assertEqual(error,
                 quod_quorum:committee_size([<<1:256>>, <<1:256>>])),
    ?assertEqual({ok, 2},
                 quod_quorum:committee_size([<<2:256>>, <<1:256>>])),
    Rows = [{Member, <<0:512>>} || Member <- Members],
    ?assert(quod_quorum:valid_signature_list(Rows, ?MAX_VALIDATORS)),
    ?assertNot(
       quod_quorum:valid_signature_list(
         Rows ++ [{<<0:256>>, <<0:512>>}], ?MAX_VALIDATORS)).
