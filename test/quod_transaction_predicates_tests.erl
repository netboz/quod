-module(quod_transaction_predicates_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

failed_alternative_restores_its_writes_test() ->
    Goal = {transaction,
            {';',
             {',', {assertz, {branch, abandoned}}, fail},
             {assertz, {branch, selected}}}},
    {succeed, Final} = prove(Goal, []),
    ?assertNot(asserted({branch, abandoned}, Final)),
    ?assert(asserted({branch, selected}, Final)).

write_prefix_is_visible_to_later_alternative_test() ->
    Goal = {transaction,
            {',',
             {assertz, {prefix, retained}},
             {';',
              {',', {assertz, {branch, abandoned}}, fail},
              {assertz, {branch, selected}}}}},
    {succeed, Final} = prove(Goal, []),
    ?assert(asserted({prefix, retained}, Final)),
    ?assertNot(asserted({branch, abandoned}, Final)),
    ?assert(asserted({branch, selected}, Final)).

total_failure_restores_assert_retract_and_abolish_test() ->
    Goal = {',',
            {assertz, {kept, baseline}},
            {transaction,
             {',', {assertz, {temporary, value}},
              {',', {retract, {parent, tom, bob}},
               {',', {abolish, {'/', obsolete, 1}}, fail}}}}},
    {fail, Final} = prove(Goal, [{parent, tom, bob}, {obsolete, value}]),
    ?assert(asserted({kept, baseline}, Final)),
    ?assertNot(asserted({temporary, value}, Final)),
    ?assertNot(retracted({parent, tom, bob}, Final)),
    ?assertNot(retracted({obsolete, value}, Final)).

error_restores_entry_and_preserves_descriptor_test() ->
    Goal = {',',
            {assertz, {kept, baseline}},
            {transaction,
             {',', {assertz, {temporary, value}},
              {assertz, true}}}},
    Result = catch prove(Goal, []),
    ?assertMatch(
       {erlog_error,
        {permission_error, modify, static_procedure, {'/', true, 0}}, _},
       Result),
    {erlog_error, _Descriptor, Final} = Result,
    ?assert(asserted({kept, baseline}, Final)),
    ?assertNot(asserted({temporary, value}, Final)).

transaction_commits_first_complete_solution_test() ->
    Goal = {transaction,
            {';', {assertz, {chosen, first}},
                  {assertz, {chosen, second}}}},
    {succeed, Final} = prove(Goal, []),
    ?assert(asserted({chosen, first}, Final)),
    ?assertNot(asserted({chosen, second}, Final)),
    {fail, Exhausted} = erlog_int:fail(Final),
    ?assert(asserted({chosen, first}, Exhausted)),
    ?assertNot(asserted({chosen, second}, Exhausted)).

nested_transaction_composes_test() ->
    Success = {transaction,
               {',', {assertz, {outer, value}},
                {transaction,
                 {';', {',', {assertz, {inner, abandoned}}, fail},
                       {assertz, {inner, selected}}}}}},
    {succeed, Final} = prove(Success, []),
    ?assert(asserted({outer, value}, Final)),
    ?assertNot(asserted({inner, abandoned}, Final)),
    ?assert(asserted({inner, selected}, Final)),
    Failure = {transaction,
               {',', Success, fail}},
    {fail, RolledBack} = prove(Failure, []),
    ?assertEqual([], changes(RolledBack)).

cut_inside_transaction_prunes_only_inner_alternatives_test() ->
    Goal =
        {transaction,
         {';',
          {',', {assertz, {inner, selected}}, '!'},
          {assertz, {inner, pruned}}}},
    {succeed, Final} = prove(Goal, []),
    ?assert(asserted({inner, selected}, Final)),
    ?assertNot(asserted({inner, pruned}, Final)),
    ?assertMatch({fail, _}, erlog_int:fail(Final)).

caller_cut_keeps_ordinary_scope_test() ->
    Goal =
        {';',
         {',',
          {transaction, {assertz, {tx_result, selected}}},
          '!'},
         {assertz, {caller, pruned}}},
    {succeed, Final} = prove(Goal, []),
    ?assert(asserted({tx_result, selected}, Final)),
    ?assertNot(asserted({caller, pruned}, Final)),
    ?assertMatch({fail, _}, erlog_int:fail(Final)).

failure_reasons_survive_rollback_test() ->
    Goal = {';',
            {transaction,
             {fail_with_reason, rejected_candidate}},
            {get_fail_reasons, {'Reasons'}}},
    {succeed, Final} = prove(Goal, []),
    ?assertEqual([{transaction,
                   {fail_with_reason, rejected_candidate}},
                  rejected_candidate],
                 erlog_int:dderef({'Reasons'}, Final#est.bs)).

ordinary_backtracking_remains_non_transactional_test() ->
    Goal = {';',
            {',', {assertz, {ordinary, retained}}, fail},
            true},
    {succeed, Final} = prove(Goal, []),
    ?assert(asserted({ordinary, retained}, Final)).

prove(Goal, Facts) ->
    C = committed(Facts),
    W = quod_erlog_db_local_prove:wrap_state(C, #{read_set => true}),
    erlog_int:prove_goal(Goal, W).

committed(Facts) ->
    {ok, C0} = erlog_int:new(quod_erlog_db_mvcc, null),
    Db1 = erlog_bips:load(C0#est.db),
    Db2 = erlog_lib_lists:load(Db1),
    C1 = quod_transaction_predicates:load(
           quod_ask:load(C0#est{db = Db2})),
    quod_ct:commit_kb(quod_ct:assert_facts(Facts, C1)).

changes(#est{db = #db{ref = Overlay}}) ->
    quod_erlog_db_local_prove:get_local_changes(Overlay).

asserted(Fact, St) ->
    lists:any(fun({assert, {Head, _Body}}) -> Head =:= Fact;
                 (_) -> false
              end, changes(St)).

retracted(Fact, St) ->
    lists:any(fun({retract, {Head, _Body}}) -> Head =:= Fact;
                 (_) -> false
              end, changes(St)).
