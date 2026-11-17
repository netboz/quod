-module(erlog_failure_reasons_tests).

-export([at_most_two_reasons/1]).

-include_lib("eunit/include/eunit.hrl").
-include("../src/erlog_int.hrl").

direct_failure_reason_test() ->
    {fail, Final} = prove({fail_with_reason, impossible_to_link}),
    ?assertEqual([impossible_to_link], Final#est.fail_reasons).

standard_predicate_gets_default_reason_test() ->
    {fail, Final} = prove({atom, 42}),
    ?assertEqual([{atom, 42}], Final#est.fail_reasons).

nested_predicates_form_failure_trace_test() ->
    St = clauses([
          {':-', {inner, {'X'}}, {atom, {'X'}}},
          {':-', {outer, {'X'}}, {inner, {'X'}}}
         ]),
    {fail, Final} = erlog_int:prove_goal({outer, 42}, St),
    ?assertEqual([{outer, 42}, {inner, 42}, {atom, 42}],
                 Final#est.fail_reasons).

explicit_reason_is_root_cause_of_trace_test() ->
    St = clauses([
          {':-', {inner, {'X'}},
           {fail_with_reason, {impossible_to_link, {'X'}}}},
          {':-', {outer, {'X'}}, {inner, {'X'}}}
         ]),
    {fail, Final} = erlog_int:prove_goal({outer, bob}, St),
    ?assertEqual([{outer, bob}, {inner, bob}, {impossible_to_link, bob}],
                 Final#est.fail_reasons).

internal_predicates_do_not_pollute_failure_trace_test() ->
    St = clauses([
          {':-', {'$internal_cleanup', {'X'}}, fail},
          {':-', {outer, {'X'}}, {'$internal_cleanup', {'X'}}}
         ]),
    {fail, Final} = erlog_int:prove_goal({outer, 42}, St),
    ?assertEqual([{outer, 42}], Final#est.fail_reasons).

ecall_is_not_available_test() ->
    erase(ecall_executed),
    Call = fun() -> put(ecall_executed, true), {succeed_last, unsafe} end,
    ?assertMatch(
       {erlog_error, {existence_error, procedure, {'/', ecall, 2}}, _},
       catch prove({ecall, Call, {'Result'}})),
    ?assertEqual(undefined, get(ecall_executed)).

unbound_default_arguments_are_frozen_test() ->
    {succeed, UnknownFails} = erlog_int:prove_goal(
                                {set_prolog_flag, unknown, fail}, state()),
    {fail, Final} = erlog_int:prove_goal({missing, {'X'}}, UnknownFails),
    ?assertEqual([{missing, unbound}], Final#est.fail_reasons).

non_prolog_default_arguments_are_sanitized_test() ->
    {succeed, UnknownFails} = erlog_int:prove_goal(
                                {set_prolog_flag, unknown, fail}, state()),
    {fail, Final} = erlog_int:prove_goal({missing, self()}, UnknownFails),
    ?assertEqual([{missing, opaque}], Final#est.fail_reasons).

backtracking_fallback_reads_reason_test() ->
    Goal = {';',
            {fail_with_reason, impossible_to_link},
            {get_fail_reasons, {'Reasons'}}},
    {succeed, Final} = prove(Goal),
    ?assertEqual([impossible_to_link], value('Reasons', Final)).

reasons_are_newest_first_test() ->
    Goal = {';',
            {';', {fail_with_reason, first}, {fail_with_reason, second}},
            {get_fail_reasons, {'Reasons'}}},
    {succeed, Final} = prove(Goal),
    ?assertEqual([second, first], value('Reasons', Final)).

cut_retains_reason_history_test() ->
    Goal = {';',
            {fail_with_reason, before_cut},
            {',', {get_fail_reasons, {'Reasons'}}, '!'}},
    {succeed, Final} = prove(Goal),
    ?assertEqual([before_cut], value('Reasons', Final)).

fresh_proof_resets_reasons_test() ->
    {fail, Failed} = prove({fail_with_reason, old_reason}),
    {succeed, Fresh} = erlog_int:prove_goal(
                         {get_fail_reasons, {'Reasons'}}, Failed),
    ?assertEqual([], value('Reasons', Fresh)).

negation_retains_explicit_reason_test() ->
    Goal = {',',
            {'\\+', {fail_with_reason, negated_failure}},
            {get_fail_reasons, {'Reasons'}}},
    {succeed, Final} = prove(Goal),
    ?assertEqual([negated_failure], value('Reasons', Final)).

findall_retains_explicit_reason_test() ->
    Goal = {',',
            {findall, {'X'}, {fail_with_reason, generator_failure}, {'Found'}},
            {get_fail_reasons, {'Reasons'}}},
    {succeed, Final} = prove(Goal),
    ?assertEqual([], value('Found', Final)),
    ?assertEqual([generator_failure], value('Reasons', Final)).

successful_negation_retains_automatic_trace_test() ->
    Goal = {',',
            {'\\+', {atom, 42}},
            {get_fail_reasons, {'Reasons'}}},
    {succeed, Final} = prove(Goal),
    ?assertEqual([{atom, 42}], value('Reasons', Final)).

successful_findall_retains_automatic_trace_test() ->
    Goal = {',',
            {findall, {'X'}, {atom, 42}, {'Found'}},
            {get_fail_reasons, {'Reasons'}}},
    {succeed, Final} = prove(Goal),
    ?assertEqual([], value('Found', Final)),
    ?assertEqual([{atom, 42}], value('Reasons', Final)).

get_fail_reasons_does_not_frame_itself_test() ->
    Goal = {',', {get_fail_reasons, {'Reasons'}}, fail},
    {fail, Final} = prove(Goal),
    ?assertEqual([], Final#est.fail_reasons).

successful_call_boundaries_are_capped_test() ->
    Goal = conjunction(lists:duplicate(?ERLOG_MAX_FAILURE_BOUNDARIES + 50,
                                       {atom, ok})),
    {succeed, Final} = prove(Goal),
    Boundaries = [Cp || #cp{type=predicate_failure}=Cp <- Final#est.cps],
    ?assertEqual(?ERLOG_MAX_FAILURE_BOUNDARIES, length(Boundaries)),
    ?assertEqual(?ERLOG_MAX_FAILURE_BOUNDARIES, Final#est.fail_boundaries),
    ?assert(Final#est.fail_reasons_truncated).

non_ground_reason_is_error_test() ->
    ?assertMatch({erlog_error, instantiation_error, _},
                 catch prove({fail_with_reason, {'Reason'}})).

non_portable_reason_is_error_test() ->
    ?assertMatch({erlog_error, {domain_error, failure_reason, _}, _},
                 catch prove({fail_with_reason, self()})).

oversized_reason_is_truncated_test() ->
    Reason = binary:copy(<<"x">>, ?ERLOG_MAX_FAILURE_REASON_BYTES + 1),
    {fail, Final} = prove({fail_with_reason, Reason}),
    ?assertEqual([fail_reasons_truncated], Final#est.fail_reasons),
    ?assertEqual(1, Final#est.fail_reason_count).

outer_frames_survive_an_inner_truncation_test() ->
    Oversized = binary:copy(<<"x">>, ?ERLOG_MAX_FAILURE_REASON_BYTES + 1),
    Inner = erlog_int:add_failure_reason(Oversized, state()),
    Outer = erlog_int:add_failure_reason({outer, failed}, Inner),
    ?assertEqual([{outer, failed}, fail_reasons_truncated],
                 Outer#est.fail_reasons),
    ?assertEqual(2, Outer#est.fail_reason_count).

total_reason_stack_is_bounded_test() ->
    Reason = binary:copy(<<"x">>, 4000),
    Final = lists:foldl(
              fun(N, St) -> erlog_int:add_failure_reason({reason, N, Reason}, St) end,
              state(), lists:seq(1, 10)),
    ?assert(erlang:external_size(Final#est.fail_reasons) =<
                ?ERLOG_MAX_FAILURE_REASONS_BYTES),
    ?assert(Final#est.fail_reason_count =< ?ERLOG_MAX_FAILURE_REASONS),
    ?assert(Final#est.fail_reasons_truncated),
    ?assert(lists:member(fail_reasons_truncated, Final#est.fail_reasons)).

custom_stack_policy_truncates_at_creation_test() ->
    St0 = erlog_int:set_failure_reason_policy(
            {?MODULE, at_most_two_reasons}, state()),
    St1 = erlog_int:add_failure_reason(first, St0),
    St2 = erlog_int:add_failure_reason(second, St1),
    ?assertEqual([fail_reasons_truncated, first], St2#est.fail_reasons),
    ?assertEqual(2, St2#est.fail_reason_count),
    ?assert(St2#est.fail_reasons_truncated).

remote_merge_preserves_order_and_bounds_test() ->
    Local = erlog_int:add_failure_reason(local, state()),
    {ok, Merged} = erlog_int:merge_failure_reasons([remote_new, remote_old], Local),
    ?assertEqual([remote_new, remote_old, local], Merged#est.fail_reasons),
    Opaque = {{'$quod_symbol', <<"remote_reason">>}, value},
    ?assertMatch({ok, _}, erlog_int:merge_failure_reasons([Opaque], Local)),
    ?assertEqual(error, erlog_int:merge_failure_reasons([{'Unbound'}], Local)),
    ?assertEqual(error, erlog_int:merge_failure_reasons([self()], Local)),
    Oversized = binary:copy(<<"x">>, ?ERLOG_MAX_FAILURE_REASON_BYTES + 1),
    ?assertEqual(error, erlog_int:merge_failure_reasons([Oversized], Local)).

prove(Goal) -> erlog_int:prove_goal(Goal, state()).

state() ->
    {ok, St0} = erlog_int:new(erlog_db_dict, null),
    Db1 = lists:foldl(fun(Mod, Db) -> Mod:load(Db) end,
                      St0#est.db,
                      [erlog_bips, erlog_lib_dcg, erlog_lib_lists]),
    St0#est{db = Db1}.

clauses(Clauses) ->
    St = state(),
    Db = lists:foldl(fun erlog_int:assertz_clause/2, St#est.db, Clauses),
    St#est{db = Db}.

value(Name, #est{bs = Bs}) -> erlog_int:dderef({Name}, Bs).

conjunction([Goal]) -> Goal;
conjunction([Goal | Goals]) -> {',', Goal, conjunction(Goals)}.

at_most_two_reasons(Reasons) -> length(Reasons) =< 2.
