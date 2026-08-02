-module(quod_proof_scope_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

run_first_returns_bindings_diff_and_reads_test() ->
    Committed = committed([{parent, tom, bob}]),
    Goal = {',', {parent, tom, {'X'}},
            {assertz, {child, {'X'}}}},
    {ok, Bindings, Diff, ReadSet} =
        quod_proof_scope:run_first(
          Goal, Committed, #{read_set => true}),
    ?assertEqual(#{'X' => bob}, Bindings),
    ?assertMatch([{assert, {{child, bob}, _}}], Diff),
    ?assert(maps:is_key({parent, 2}, ReadSet)),
    ?assertEqual(undefined, procedure(Committed, {child, 1})).

resumable_scope_preserves_solution_order_test() ->
    Committed = committed([{choice, first}, {choice, second}]),
    Scope0 = quod_proof_scope:open(
               {choice, {'X'}}, Committed, #{read_set => true}),
    try
        {solution, {choice, first}, Scope1} =
            quod_proof_scope:next(Scope0),
        {solution, {choice, second}, Scope2} =
            quod_proof_scope:next(Scope1),
        {complete, Reasons, _Scope3} =
            quod_proof_scope:next(Scope2),
        ?assert(is_list(Reasons))
    after
        quod_proof_scope:close(Scope0)
    end.

ordinary_failed_branch_keeps_its_scope_write_test() ->
    Committed = committed([]),
    Goal = {';',
            {',', {assertz, {retained, value}}, fail},
            {retained, value}},
    Scope0 = quod_proof_scope:open(Goal, Committed, #{read_set => true}),
    try
        {solution, Goal, Scope1} =
            quod_proof_scope:next(Scope0),
        ?assertMatch(
           [{assert, {{retained, value}, _}}],
           quod_proof_scope:local_changes(Scope1))
    after
        quod_proof_scope:close(Scope0)
    end.

stateless_erlog_error_is_preserved_test() ->
    Scope0 = quod_proof_scope:open(
               {assertz, true}, committed([]), #{read_set => true}),
    try
        ?assertMatch(
           {error,
            {erlog,
             {permission_error, modify, static_procedure,
              {'/', true, 0}}}, _, keep_current},
           quod_proof_scope:next(Scope0))
    after
        quod_proof_scope:close(Scope0)
    end.

committed(Facts) ->
    %% Use Erlog's normal constructor so the fixture contains the standard
    %% built-ins that every production ontology receives.
    {ok, Erl} = erlog:new(erlog_db_dict, null),
    State0 = element(3, Erl),
    {succeed, State1} =
        erlog_int:prove_goal(
          {set_prolog_flag, unknown, fail}, State0),
    State2 = quod_ask:load(State1),
    lists:foldl(
      fun(Fact, State) ->
              {succeed, Next} =
                  erlog_int:prove_goal({assertz, Fact}, State),
              Next
      end, State2, Facts).

procedure(#est{db = #db{mod = Mod, ref = Ref}}, Functor) ->
    Mod:get_procedure(Ref, Functor).
