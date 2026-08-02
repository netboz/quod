-module(quod_action_predicates_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

shape_validation_test() ->
    St = overlay(<<>>),
    lists:foreach(
      fun(Goal) -> ?assertMatch({succeed, _}, erlog_int:prove_goal(Goal, St)) end,
      [{'$quod_callable', ready},
       {'$quod_callable', {ready, value}},
       {'$quod_action_shape', {move, one}, [], {at, one}},
       {'$quod_action_shape', [{step, one}, {step, two}],
        [{allowed, one}], {at, two}}]),
    lists:foreach(
      fun(Goal) -> ?assertMatch({fail, _}, erlog_int:prove_goal(Goal, St)) end,
      [{'$quod_callable', {'Variable'}},
       {'$quod_callable', 42},
       {'$quod_action_shape', [], [], ready},
       {'$quod_action_shape', move, [], true},
       {'$quod_action_shape', move, [allowed | improper], ready},
       {'$quod_action_shape', [move | improper], [], ready}]).

state_check_preserves_alternatives_and_restores_write_mode_test() ->
    St = overlay(<<"choice(first). choice(second).">>),
    Goal =
        {',', {'$quod_state_check', {choice, {'X'}}},
         {',', {'=', {'X'}, second},
          {assertz, {selected, {'X'}}}}},
    {succeed, Final} = erlog_int:prove_goal(Goal, St),
    ?assertEqual(second, erlog_int:dderef({'X'}, Final#est.bs)),
    ?assert(asserted({selected, second}, Final)).

state_check_rejects_mutation_and_restores_after_error_test() ->
    St = overlay(<<>>),
    Result = catch erlog_int:prove_goal(
                     {'$quod_state_check',
                      {',', {assertz, temporary},
                       {retract, temporary}}},
                     St),
    ?assertMatch(
       {erlog_error,
        {permission_error, modify, static_procedure, {'/', temporary, 0}}, _},
       Result),
    {erlog_error, _Descriptor, ErrorSt} = Result,
    ?assertEqual([], changes(ErrorSt)),
    {succeed, Writable} = erlog_int:prove_goal(
                            {assertz, writable_after_error}, ErrorSt),
    ?assert(asserted(writable_after_error, Writable)).

goal_rolls_back_failed_candidate_then_selects_next_test() ->
    St = overlay(
           <<"try_candidate(bad) :- assertz(leaked(bad)), fail.\n"
             "try_candidate(good) :- assertz(reached(target)).\n"
             "action(try_candidate(bad), [], reached(target)).\n"
             "action(try_candidate(good), [], reached(target)).\n">>),
    {succeed, Final} = erlog_int:prove_goal(
                         {goal, {reached, target}}, St),
    ?assertNot(asserted({leaked, bad}, Final)),
    ?assert(asserted({reached, target}, Final)).

goal_backtracks_inside_read_only_prerequisite_test() ->
    St = overlay(
           <<"candidate(bad). candidate(good).\n"
             "finish(good) :- assertz(done).\n"
             "action(finish(X), [candidate(X)], done).\n">>),
    {succeed, Final} = erlog_int:prove_goal({goal, done}, St),
    ?assert(asserted(done, Final)).

goal_skips_transition_when_target_already_holds_test() ->
    St = overlay(
           <<"ready.\n"
             "unneeded :- assertz(transition_ran).\n"
             "action(unneeded, [], ready).\n">>),
    {succeed, Final} = erlog_int:prove_goal({goal, ready}, St),
    ?assertNot(asserted(transition_ran, Final)).

goal_rolls_back_failed_postcondition_before_next_candidate_test() ->
    St = overlay(
           <<"incomplete :- assertz(leaked_after_transition).\n"
             "complete :- assertz(reached).\n"
             "action(incomplete, [], reached).\n"
             "action(complete, [], reached).\n">>),
    {succeed, Final} = erlog_int:prove_goal({goal, reached}, St),
    ?assertNot(asserted(leaked_after_transition, Final)),
    ?assert(asserted(reached, Final)).

goal_runs_transition_list_in_order_test() ->
    St = overlay(
           <<"first_step :- assertz(progress(one)).\n"
             "second_step :- progress(one), assertz(progress(two)), assertz(done).\n"
             "action([first_step, second_step], [], done).\n">>),
    {succeed, Final} = erlog_int:prove_goal({goal, done}, St),
    ?assert(asserted({progress, one}, Final)),
    ?assert(asserted({progress, two}, Final)),
    ?assert(asserted(done, Final)).

invalid_action_shape_runs_nothing_test() ->
    St = overlay(
           <<"mark_prerequisite :- assertz(prerequisite_ran).\n"
             "action([], [mark_prerequisite], target).\n">>),
    {fail, Final} = erlog_int:prove_goal({goal, target}, St),
    ?assertEqual([], changes(Final)).

recursive_goal_prerequisite_uses_visited_chain_test() ->
    St = overlay(
           <<"reach_a :- assertz(a).\n"
             "reach_b_via_a :- assertz(wrong_cycle_path).\n"
             "reach_b :- assertz(b).\n"
             "action(reach_a, [goal(b)], a).\n"
             "action(reach_b_via_a, [goal(a)], b).\n"
             "action(reach_b, [], b).\n">>),
    {succeed, Final} = erlog_int:prove_goal({goal, a}, St),
    ?assertNot(asserted(wrong_cycle_path, Final)),
    ?assert(asserted(b, Final)),
    ?assert(asserted(a, Final)).

failed_candidates_retain_explicit_failure_reasons_test() ->
    St = overlay(
           <<"action(first, [fail_with_reason(denied_first)], target).\n"
             "action(second, [fail_with_reason(denied_second)], target).\n">>),
    {fail, Final} = erlog_int:prove_goal({goal, target}, St),
    ?assert(lists:member(denied_first, Final#est.fail_reasons)),
    ?assert(lists:member(denied_second, Final#est.fail_reasons)).

overlay(Source) ->
    Name = list_to_atom(
             "qaction_" ++
             integer_to_list(erlang:unique_integer([positive]))),
    {ok, Erl} = erlog:new(erlog_db_ets, Name),
    C0 = element(3, Erl),
    C1 = quod_predicates:load(C0),
    C2 = quod_ask:load(C1),
    C3 = quod_transaction_predicates:load(C2),
    C4 = quod_action_predicates:load(C3),
    C5 = load_source(common_source(), C4),
    C6 = load_source(Source, C5),
    {succeed, Committed} = erlog_int:prove_goal(
                             {set_prolog_flag, unknown, fail}, C6),
    quod_erlog_db_local_prove:wrap_state(
      Committed, #{read_set => true}).

common_source() ->
    File = filename:join(code:priv_dir(quod),
                         "ontologies/common_predicates.pl"),
    {ok, Binary} = file:read_file(File),
    Binary.

load_source(<<>>, St) -> St;
load_source(Source, #est{db = Db0} = St) ->
    {ok, Terms} = erlog_io:read_string_terms(
                    unicode:characters_to_list(Source)),
    Db1 = lists:foldl(fun erlog_int:assertz_clause/2, Db0, Terms),
    St#est{db = Db1}.

changes(#est{db = #db{ref = Overlay}}) ->
    quod_erlog_db_local_prove:get_local_changes(Overlay).

asserted(Fact, St) ->
    lists:any(fun({assert, {Head, _Body}}) -> Head =:= Fact;
                 (_) -> false
              end, changes(St)).
