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

honest_threshold_has_one_arithmetic_owner_test() ->
    ?assertEqual([1, 1, 2, 3, 22],
                 [quod_quorum:honest_threshold(N) || N <- [1, 3, 4, 7, 64]]).

committee_is_validated_once_at_each_public_policy_test() ->
    {Pub, Identity} = identity(), Bytes = <<"one-committee-boundary">>,
    Rows = [{Pub, quod_identity:sign(Bytes, Identity)}],
    {module, quod_quorum} = code:ensure_loaded(quod_quorum),
    {ok, {call_count, Counts}} = tprof:profile(fun() ->
        ?assertEqual({ok, Rows}, quod_quorum:sanitize([Pub], Bytes, Rows)),
        ?assert(quod_quorum:verify([Pub], Bytes, Rows)),
        ?assert(quod_quorum:verify_honest([Pub], Bytes, Rows)),
        ok
    end, #{type => call_count, report => return,
           pattern => {quod_quorum, committee_size, 1}}),
    ?assertEqual(3, lists:sum([N || {quod_quorum, committee_size, 1, Ps} <- Counts,
                                  {_, N, _} <- Ps])).

exact_honest_verifier_rejects_noncanonical_and_extra_rows_test() ->
    Identities = [identity() || _ <- lists:seq(1, 4)],
    Committee = [P || {P, _} <- Identities], Bytes = <<"shared/exact-f-plus-one">>,
    [A, B, C, _] = lists:sort([{P, quod_identity:sign(Bytes, I)} || {P, I} <- Identities]),
    ?assert(quod_quorum:verify_honest(Committee, Bytes, [A, B])),
    lists:foreach(fun(Rows) ->
        ?assertNot(quod_quorum:verify_honest(Committee, Bytes, Rows))
    end, [[], [A], [B, A], [A, A], [A, B, C], [A | invalid],
          [A, setelement(2, B, <<0:512>>)]]),
    ?assertNot(quod_quorum:verify_honest([], Bytes, [A, B])),
    ?assertNot(quod_quorum:verify_honest([hd(Committee) | Committee], Bytes, [A, B])),
    ?assertNot(quod_quorum:verify_honest(Committee, <<"other-domain">>, [A, B])).

public_policies_share_member_signature_checks_test() ->
    Identities = [identity() || _ <- lists:seq(1, 4)],
    Committee = lists:sort([Pub || {Pub, _} <- Identities]),
    Bytes = <<"quod/test/public-quorum-policies">>,
    Rows = lists:keysort(
             1,
             [{Pub, quod_identity:sign(Bytes, Identity)}
              || {Pub, Identity} <- Identities]),
    [A, B, C | _] = Rows,
    ?assertEqual({ok, [A, B, C]},
                 quod_quorum:sanitize(Committee, Bytes, [C, B, A])),
    ?assert(quod_quorum:verify(Committee, Bytes, [C, B, A])),
    %% N=4 needs three votes for consensus, but exactly two for an honest
    %% witness. Both public policies use the same membership/signature checks.
    ?assert(quod_quorum:verify_honest(Committee, Bytes, [A, B])),
    {Outsider, OutsiderIdentity} = identity(),
    OutsiderRow = {Outsider, quod_identity:sign(Bytes, OutsiderIdentity)},
    ?assertNot(quod_quorum:verify_honest(Committee, Bytes, [A, OutsiderRow])),
    lists:foreach(fun(Invalid) ->
        ?assertEqual(error, quod_quorum:sanitize(Committee, Bytes, Invalid)),
        ?assertNot(quod_quorum:verify(Committee, Bytes, Invalid))
    end, [[], [A], [A, B], [A, B, OutsiderRow], [A, A, B],
          [A, B, setelement(2, C, <<0:512>>)], Rows ++ [OutsiderRow]]).

identity() ->
    {Pub, Seed} = quod_identity:generate(),
    {Pub, #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}}.
