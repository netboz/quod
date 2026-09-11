-module(quod_independent_predicates_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

%% Local control-construct tests use a worker-private signed-admission fixture.
%% They do not claim to verify a client signature; ingress tests cover that seam.
failed_wrapper_residue_does_not_select_independent_test() ->
    check({';', {independent, {',', {assertz, p}, fail}}, true}, false, 2, [p]).

ordinary_failed_branch_still_contributes_provenance_test() ->
    check({',', {';', {',', {assertz, p}, fail}, true},
           {independent, {assertz, q}}}, true, 3, [p, q]).

wrapped_failed_branch_and_selected_wrapper_merge_test() ->
    check({',', {';', {independent, {',', {assertz, p}, fail}}, true},
           {independent, {assertz, q}}}, true, 2, [p, q]).

later_caller_failure_discards_intent_not_writes_test() ->
    check({';', {',', {independent, {assertz, p}}, fail}, true}, false, 2, [p]).

sequential_wrappers_merge_test() ->
    check({',', {independent, {assertz, p}}, {independent, {assertz, q}}},
          true, 2, [p, q]).

cancelled_ordinary_assert_does_not_count_test() ->
    check({',', {assertz, p}, {',', {retract, p}, {independent, {assertz, q}}}},
          true, 2, [q]).

cancelled_assert_with_retained_event_still_counts_test() ->
    check({',', {assertz, p},
           {',', {trigger_event, ordinary_event},
            {',', {retract, p}, {independent, {assertz, q}}}}}, true, 3, [q]).

empty_wrapper_is_valid_test() -> check({independent, true}, true, 0, []).

cut_pruned_wrapper_retains_provenance_not_intent_test() ->
    Inner = {',', {assertz, p}, {';', {',', '!', fail}, {assertz, pruned}}},
    check({';', {independent, Inner}, true}, false, 2, [p]).

cut_keeps_successful_intent_test() ->
    check({';', {',', {independent, {assertz, p}}, '!'}, {assertz, pruned}},
          true, 2, [p]).

wrapper_preserves_redo_test() ->
    with_state(true, fun(St) ->
        Goal = {independent, {';', {assertz, p}, {assertz, q}}},
        {succeed, First} = erlog_int:prove_goal(Goal, St),
        ?assert(quod_erlog_db_local_prove:successful_independent(First)),
        {succeed, Second} = erlog_int:fail(First),
        ?assert(quod_erlog_db_local_prove:successful_independent(Second)),
        ?assertEqual([p, q], facts(Second)),
        {fail, Last} = erlog_int:fail(Second),
        ?assertNot(quod_erlog_db_local_prove:successful_independent(Last)),
        ?assertEqual(2, quod_erlog_db_local_prove:provenance(Last))
    end).

unsigned_wrappers_are_uniformly_refused_test() ->
    with_state(false, fun(St) ->
        lists:foreach(fun(Goal) ->
            ?assertThrow({quod_ask_error, independent_requires_signed_request},
                         erlog_int:prove_goal({independent, Goal}, St))
        end, [true, {assertz, p}, {',', {assertz, p}, {assertz, q}}])
    end).

nesting_is_refused_in_both_directions_test() ->
    with_state(true, fun(St) ->
        lists:foreach(fun(Goal) ->
            ?assertThrow({quod_ask_error, independent_nesting},
                         erlog_int:prove_goal(Goal, St))
        end, [{independent, {independent, true}},
              {independent, {transaction, true}},
              {transaction, {independent, true}}])
    end).

abolish_of_cancelled_assert_has_no_provenance_test() ->
    check({',', {asserta, {p, one}},
           {',', {abolish, {'/', p, 1}}, {independent, {asserta, q}}}},
          true, 2, [q]).

committed_retract_and_abolish_keep_each_original_mark_test() ->
    with_state(true, [{p, one}, {p, two}], fun(St) ->
        {succeed, Final} = erlog_int:prove_goal(
          {',', {retract, {p, one}}, {independent, {abolish, {'/', p, 1}}}}, St),
        ?assertEqual(3, quod_erlog_db_local_prove:provenance(Final)),
        ?assertMatch([{retract, _}, {retract, _}], changes(Final))
    end).

empty_second_abolish_does_not_relabel_a_retained_retract_test() ->
    with_state(true, [{p, one}], fun(St) ->
        {succeed, Final} = erlog_int:prove_goal(
          {',', {independent, {retract, {p, one}}}, {abolish, {'/', p, 1}}}, St),
        ?assertEqual(2, quod_erlog_db_local_prove:provenance(Final)),
        ?assertMatch([{retract, _}], changes(Final))
    end).

prepared_effect_survives_cancelled_fact_test() ->
    %% Storage seam control, not a lifecycle execution claim. No effect runs.
    with_state(true, fun(St) ->
        {succeed, S1} = erlog_int:prove_goal({assertz, p}, St),
        {ok, Effect} = quod_effect:new(create, <<1:256>>, {node, <<1:256>>},
                                       {<<"s6:effect">>, <<2:256>>}, <<3:256>>, <<4:256>>),
        S2 = quod_erlog_db_local_prove:put_prepared_effect(
               S1, fixture_action, fixture_desired, Effect, fixture_private),
        {succeed, Final} = erlog_int:prove_goal(
          {',', {retract, p}, {independent, {assertz, q}}}, S2),
        ?assertEqual([q], facts(Final)),
        ?assertEqual(3, quod_erlog_db_local_prove:provenance(Final)),
        ?assertMatch({ok, {fixture_action, fixture_desired, Effect, fixture_private}},
                     quod_erlog_db_local_prove:prepared_effect(Final, Effect))
    end).

error_unwinds_mode_without_rolling_back_staged_writes_test() ->
    with_state(true, fun(St) ->
        Error = catch erlog_int:prove_goal(
          {independent, {',', {assertz, p}, {call, 42}}}, St),
        assert_unwound_error(Error, [p])
    end).

stateless_error_keeps_its_original_descriptor_test() ->
    with_state(true, fun(St) ->
        ?assertThrow({erlog_error,
                      {permission_error, modify, static_procedure, {'/', true, 0}}},
                     erlog_int:prove_goal(
                       {independent, {',', {assertz, p}, {assertz, true}}}, St))
    end).

redo_error_unwinds_mode_without_rolling_back_staged_writes_test() ->
    with_state(true, fun(St) ->
        {succeed, First} = erlog_int:prove_goal(
          {independent, {';', {assertz, p}, {',', {assertz, q}, {call, 42}}}}, St),
        assert_unwound_error(catch erlog_int:fail(First), [p, q])
    end).

assert_unwound_error(Error, Facts) ->
    ?assertMatch({erlog_error, {type_error, callable, 42}, _}, Error),
    {erlog_error, _, Final} = Error,
    ?assertEqual(ordinary, quod_erlog_db_local_prove:write_intent(Final)),
    ?assertNot(quod_erlog_db_local_prove:successful_independent(Final)),
    ?assertEqual(2, quod_erlog_db_local_prove:provenance(Final)),
    ?assertEqual(Facts, facts(Final)).

check(Goal, Selected, Mask, Facts) ->
    with_state(true, fun(St) ->
        {succeed, Final} = erlog_int:prove_goal(Goal, St),
        ?assertEqual(Selected, quod_erlog_db_local_prove:successful_independent(Final)),
        ?assertEqual(Mask, quod_erlog_db_local_prove:provenance(Final)),
        ?assertEqual(Facts, facts(Final)),
        ?assertEqual(ordinary, quod_erlog_db_local_prove:write_intent(Final))
    end).

facts(#est{db = #db{ref = Ov}}) ->
    lists:sort([H || {assert, {H, _}} <- quod_erlog_db_local_prove:get_local_changes(Ov)]).

changes(#est{db = #db{ref = Ov}}) -> quod_erlog_db_local_prove:get_local_changes(Ov).

with_state(Signed, Fun) -> with_state(Signed, [], Fun).

with_state(Signed, Facts, Fun) ->
    {ok, C0} = erlog_int:new(quod_erlog_db_mvcc, null),
    C1 = quod_transaction_predicates:load(C0#est{db = erlog_bips:load(C0#est.db)}),
    C2 = quod_ct:commit_kb(quod_ct:assert_facts(Facts, C1)),
    W0 = quod_erlog_db_local_prove:wrap_state(C2, #{read_set => true, signed_request => Signed}),
    W = quod_predicates:set_context(
          W0, quod_predicates:proof_context(<<"independent:test">>, 1, none)),
    try Fun(W)
    after quod_erlog_db_local_prove:cleanup_read_set(W)
    end.
