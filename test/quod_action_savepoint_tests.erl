-module(quod_action_savepoint_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-export([stage_fixture_effect_0/3, stateful_fixture_error_0/3]).

%% Local interpreter controls use signed-admission metadata, not fabricated
%% signature verification. The real signed/co-hosted/remote CTs own that seam.
independent_action_preserves_candidate_rollback_test() ->
    with_state(<<"bad :- assertz(leaked), trigger_event(leaked_event), !, fail.\n"
                 "good :- assertz(done), trigger_event(done_event).\n"
                 "action(bad, [], done). action(good, [], done).">>,
      fun(St) ->
          {succeed, Final} = erlog_int:prove_goal({independent, {goal, done}}, St),
          ?assertEqual([done], facts(Final)),
          ?assertEqual([done_event], events(Final)),
          selected(Final, true, 2)
      end).

action_transition_may_choose_independent_test() ->
    with_state(<<"action(independent(assertz(done)), [], done).">>,
      fun(St) ->
          {succeed, Final} = erlog_int:prove_goal({goal, done}, St),
          ?assertEqual([done], facts(Final)), selected(Final, true, 2)
      end).

failed_independent_candidate_discards_intent_and_material_test() ->
    with_state(<<"bad :- independent(assertz(leaked)), fail.\n"
                 "action(bad, [], done). action(assertz(done), [], done).">>,
      fun(St) ->
          {succeed, Final} = erlog_int:prove_goal({goal, done}, St),
          ?assertEqual([done], facts(Final)), selected(Final, false, 1)
      end).

independent_action_failed_postcondition_rolls_back_test() ->
    with_state(<<"action(assertz(not_done), [], done).\n"
                 "action(assertz(done), [], done).">>,
      fun(St) ->
          {succeed, Final} = erlog_int:prove_goal({independent, {goal, done}}, St),
          ?assertEqual([done], facts(Final)), selected(Final, true, 2)
      end).

independent_action_error_preserves_descriptor_and_cleans_mode_test() ->
    with_state(<<"bad :- assertz(leaked), trigger_event(leaked_event), assertz(true).\n"
                 "action(bad, [], done).">>,
      fun(St) ->
          Error = catch erlog_int:prove_goal({independent, {goal, done}}, St),
          ?assertMatch({erlog_error,
             {permission_error, modify, static_procedure, {'/', true, 0}}, _}, Error),
          {erlog_error, _, Final} = Error,
          ?assertEqual([], facts(Final)), ?assertEqual([], events(Final)),
          selected(Final, false, 0)
      end).

caller_backtracking_discards_intent_but_not_successful_action_writes_test() ->
    with_state(<<"action(assertz(done), [], done).">>,
      fun(St) ->
          Goal = {';', {',', {independent, {goal, done}}, fail}, true},
          {succeed, Final} = erlog_int:prove_goal(Goal, St),
          ?assertEqual([done], facts(Final)), selected(Final, false, 2)
      end).

public_atomic_intent_remains_distinct_from_private_rollback_test() ->
    with_state(<<"action(independent(assertz(done)), [], done).">>,
      fun(St) ->
          ?assertThrow({quod_ask_error, independent_nesting},
              erlog_int:prove_goal({transaction, {goal, done}}, St)),
          ?assertThrow({quod_ask_error, independent_nesting},
              erlog_int:prove_goal({independent, {transaction, true}}, St))
      end).

already_satisfied_action_runs_no_transition_test() ->
    with_state(<<"done. action(assertz(unneeded), [], done).">>,
      fun(St) ->
          {succeed, Final} = erlog_int:prove_goal({independent, {goal, done}}, St),
          ?assertEqual([], facts(Final)), selected(Final, true, 0)
      end).

private_savepoint_is_not_a_new_public_prolog_control_test() ->
    with_state(<<>>, fun(St) ->
        ?assertMatch({fail, _}, erlog_int:prove_goal({proof_savepoint, true}, St)),
        ?assertMatch({fail, _}, erlog_int:prove_goal({savepoint, true}, St))
    end).

failed_candidate_restores_prepared_effect_and_provenance_test() ->
    %% Production overlay/savepoint seam, not an external effect execution.
    %% The signed Root CT separately proves the real lifecycle bridge.
    with_state(<<"bad :- stage_fixture_effect, trigger_event(discarded), !, fail.\n"
                 "action(bad, [], done). action(assertz(done), [], done).">>,
      fun(St) ->
          {succeed, Final} = erlog_int:prove_goal({independent, {goal, done}}, St),
          #est{db = #db{ref = Overlay}} = Final,
          ?assertEqual([], quod_erlog_db_local_prove:get_effects(Overlay)),
          ?assertEqual(error, quod_erlog_db_local_prove:prepared_effect(Final, fixture_effect())),
          ?assertEqual([], events(Final)), ?assertEqual([done], facts(Final)),
          selected(Final, true, 2)
      end).

stateful_candidate_error_restores_the_actual_error_revision_test() ->
    with_state(<<"bad :- assertz(leaked), trigger_event(leaked_event), stateful_fixture_error.\n"
                 "action(bad, [], done).">>, fun(St) ->
        {erlog_error, pinned_stateful_error, Final} =
            catch erlog_int:prove_goal({independent, {goal, done}}, St),
        ?assertEqual([], facts(Final)), ?assertEqual([], events(Final)),
        selected(Final, false, 0)
    end).

stateful_fixture_error_0(stateful_fixture_error, _Next, St) ->
    erlog_int:erlog_error(pinned_stateful_error, St).

stage_fixture_effect_0(stage_fixture_effect, Next, St) ->
    Prepared = quod_erlog_db_local_prove:put_prepared_effect(
                 St, fixture_action, fixture_desired, fixture_effect(), fixture_private),
    erlog_int:prove_body(Next, Prepared).
fixture_effect() ->
    {ok, Effect} = quod_effect:new(create, <<1:256>>, {node, <<1:256>>},
                     {<<"action:effect">>, <<2:256>>}, <<3:256>>, <<4:256>>),
    Effect.

failed_candidate_reads_are_monotonic_dependencies_test() ->
    with_state(<<"input(v). bad :- input(v), assertz(leaked), fail.\n"
                 "action(bad, [], done). action(assertz(done), [], done).">>,
      fun(St) ->
          {succeed, Final} = erlog_int:prove_goal({independent, {goal, done}}, St),
          #est{db = #db{ref = Overlay}} = Final,
          ?assert(maps:is_key({input, 1}, quod_erlog_db_local_prove:get_read_set(Overlay))),
          ?assertEqual([done], facts(Final)), selected(Final, true, 2)
      end).

public_atomic_mode_restores_before_the_caller_test() ->
    with_state(<<>>, fun(St) ->
        {succeed, Final} = erlog_int:prove_goal(
            {',', {transaction, true}, {independent, {assertz, done}}}, St),
        selected(Final, true, 2)
    end).

nested_public_transaction_restores_its_atomic_parent_test() ->
    with_state(<<>>, fun(St) ->
        ?assertThrow({quod_ask_error, independent_nesting},
          erlog_int:prove_goal({transaction,
            {',', {transaction, true}, {independent, true}}}, St))
    end).

selected(St, Intent, Mask) ->
    ?assertEqual(Intent, quod_erlog_db_local_prove:successful_independent(St)),
    ?assertEqual(Mask, quod_erlog_db_local_prove:provenance(St)),
    ?assertEqual(ordinary, quod_erlog_db_local_prove:write_intent(St)),
    ?assertEqual(0, St#est.checkpoint_depth).
facts(#est{db = #db{ref = Ov}}) ->
    lists:sort([H || {assert, {H, _}} <- quod_erlog_db_local_prove:get_local_changes(Ov)]).
events(#est{db = #db{ref = Ov}}) ->
    [E || {event, E} <- quod_erlog_db_local_prove:get_local_changes(Ov)].
with_state(Source, Fun) ->
    C0 = quod_committed_projection:new_est(),
    {ok, Terms} = erlog_io:read_string_terms(unicode:characters_to_list(Source)),
    C1 = C0#est{db = lists:foldl(fun erlog_int:assertz_clause/2, C0#est.db, Terms)},
    %% Compiled mechanics must be installed before wrapping: the temporary
    %% store deliberately refuses to add executable procedures of its own.
    D1 = erlog_int:add_compiled_proc({stage_fixture_effect, 0},
             ?MODULE, stage_fixture_effect_0, C1#est.db),
    D2 = erlog_int:add_compiled_proc({stateful_fixture_error, 0},
             ?MODULE, stateful_fixture_error_0, D1),
    Committed = quod_ct:commit_kb(C1#est{db = D2}),
    Wrapped = quod_erlog_db_local_prove:wrap_state(Committed,
                  #{read_set => true, signed_request => true}),
    St = quod_predicates:set_context(Wrapped,
           quod_predicates:proof_context(<<"test:action-savepoint">>, 1, undefined)),
    try Fun(St)
    after
        quod_erlog_db_local_prove:cleanup_read_set(St),
        #est{db = #db{ref = Ref}} = Committed,
        quod_erlog_db_mvcc:delete(Ref)
    end.
