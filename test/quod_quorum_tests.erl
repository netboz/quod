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

caller_selected_threshold_reuses_the_shared_signature_verifier_test() ->
    Identities = [identity() || _ <- lists:seq(1, 4)],
    Committee = lists:sort([Pub || {Pub, _} <- Identities]),
    Bytes = <<"quod/test/custom-threshold">>,
    Rows = lists:keysort(
             1,
             [{Pub, quod_identity:sign(Bytes, Identity)}
              || {Pub, Identity} <- Identities]),
    [A, B | _] = Rows,
    ?assertEqual({ok, [A, B]},
                 quod_quorum:sanitize_at_least(
                   Committee, Bytes, [B, A], 2)),
    ?assertEqual(error,
                 quod_quorum:sanitize_at_least(
                   Committee, Bytes, [A], 2)),
    {Outsider, OutsiderIdentity} = identity(),
    OutsiderRow = {Outsider, quod_identity:sign(Bytes, OutsiderIdentity)},
    ?assertEqual(error,
                 quod_quorum:sanitize_at_least(
                   Committee, Bytes, [A, OutsiderRow], 2)),
    ?assertEqual(error,
                 quod_quorum:sanitize_at_least(
                   Committee, Bytes, [A, A], 2)),
    ?assertEqual(error,
                 quod_quorum:sanitize_at_least(
                   Committee, Bytes, [A, setelement(2, B, <<0:512>>)], 2)),
    ?assertEqual(error,
                 quod_quorum:sanitize_at_least(
                   Committee, Bytes, Rows, 5)).

identity() ->
    {Pub, Seed} = quod_identity:generate(),
    {Pub, #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}}.
