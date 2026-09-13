-module(quod_operation_vector_tests).
-include_lib("eunit/include/eunit.hrl").

canonical_one_two_four_targets_test() ->
    lists:foreach(fun(N) ->
        Refs = [ref(I) || I <- lists:seq(1, N)],
        ?assertEqual({ok, Refs}, quod_operation_vector:references(lists:reverse(Refs))),
        {ok, Rows} = quod_operation_vector:included(lists:reverse(Refs)),
        ?assertEqual([{quod_operation_vector:target(R), {included, R}} || R <- Refs], Rows),
        ?assertEqual({ok, Refs}, quod_operation_vector:receipt_references(Rows)),
        lists:foreach(fun(R) ->
            ?assertEqual({ok, R}, quod_operation_vector:lookup(
                quod_operation_vector:target(R), Refs))
        end, Refs)
    end, [1, 2, 4]).

duplicate_target_cannot_be_hidden_by_another_transaction_id_test() ->
    R = ref(1),
    OtherId = setelement(4, R, <<99:256>>),
    ?assertEqual(error, quod_operation_vector:references([R, R])),
    ?assertEqual(error, quod_operation_vector:references([R, OtherId])),
    ?assertEqual(error, quod_operation_vector:included([R, OtherId])).

receipt_rejects_uncertified_verdict_labels_test() ->
    R = ref(1), T = quod_operation_vector:target(R),
    lists:foreach(fun(Bad) ->
        ?assertEqual(error, quod_operation_vector:receipt([{T, Bad}]))
    end, [{committed, R}, {rejected, R}, {certified_verdict, R}, R, {included, R, committed}]).

wrong_anchor_and_noncanonical_storage_refused_test() ->
    R = ref(1),
    ?assertEqual(error, quod_operation_vector:receipt([
        {{<<"target1">>, <<99:256>>}, {included, R}}])),
    {ok, Rows} = quod_operation_vector:included([R, ref(2)]),
    ?assertEqual(error, quod_operation_vector:receipt_references(lists:reverse(Rows))),
    ?assertEqual(error, quod_operation_vector:lookup({<<"target1">>, <<99:256>>}, [R])).

malformed_or_empty_vectors_refused_test() ->
    lists:foreach(fun(Bad) ->
        ?assertEqual(error, quod_operation_vector:references(Bad)),
        ?assertEqual(error, quod_operation_vector:receipt(Bad))
    end, [[], none, [ref(1) | tail], [{transaction, <<>>, <<1:256>>, <<1:256>>}],
         [[ref(1)] || _ <- lists:seq(1, 10000)]]).

ref(I) -> {transaction, <<"target", (integer_to_binary(I))/binary>>, <<I:256>>, <<I:256>>}.

%% These are schema/owner-bookkeeping controls, never certificate authority.
complete_vector_uses_bound_targets_not_arrival_order_test() ->
    [A, B] = Refs = refs(), TA = quod_operation_vector:target(A),
    TB = quod_operation_vector:target(B),
    M = maps:from_list([{TB, {{rejected, conflict_retry}, B}}, {TA, {committed, A}}]),
    Rows = [{TA, {committed, A}}, {TB, {{rejected, conflict_retry}, B}}],
    ?assertEqual({ok, Rows}, quod_operation_vector:results(Refs, M)),
    ?assertEqual(mixed, quod_operation_vector:aggregate(Rows)).

missing_extra_or_substituted_result_cannot_finish_test() ->
    [A, B] = Refs = refs(), TA = quod_operation_vector:target(A),
    TB = quod_operation_vector:target(B),
    Full = #{TA => {committed, A}, TB => {committed, B}},
    Extra = {<<"c">>, <<3:256>>},
    [ ?assertEqual(pending, quod_operation_vector:results(Refs, Results))
      || Results <- [#{}, maps:remove(TB, Full), Full#{Extra => {committed, B}},
                     Full#{TB := {committed, A}},
                     Full#{TB := {committed, setelement(4, B, <<99:256>>)}},
                     Full#{TB := pending}, Full#{TB := {included, B}},
                     Full#{TB := {{rejected, invented_reason}, B}}] ].

only_complete_canonical_rows_have_a_public_aggregate_test() ->
    [A, B] = refs(), TA = quod_operation_vector:target(A),
    TB = quod_operation_vector:target(B),
    Commit = [{TA, {committed, A}}, {TB, {committed, B}}],
    Reject = [{TA, {{rejected, not_authorized}, A}},
              {TB, {{rejected, conflict_retry}, B}}],
    ?assertEqual(all_applied, quod_operation_vector:aggregate(Commit)),
    ?assertEqual(all_rejected, quod_operation_vector:aggregate(Reject)),
    [?assertEqual(error, quod_operation_vector:result_rows(Rows))
     || Rows <- [[], lists:reverse(Commit), [hd(Commit), hd(Commit)],
                 [hd(Commit), malformed], [{TB, {committed, A}}],
                 [hd(Commit) | improper]]].

refs() -> [{transaction, <<"a">>, <<1:256>>, <<11:256>>},
           {transaction, <<"b">>, <<2:256>>, <<12:256>>}].
