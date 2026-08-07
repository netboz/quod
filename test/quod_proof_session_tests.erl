-module(quod_proof_session_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_proof_limits.hrl").

resumable_invocation_preserves_solution_order_test() ->
    Session = quod_proof_session:start(
                committed([{choice, first}, {choice, second}]),
                #{read_set => true}),
    Invocation = invocation_id(1),
    try
        ok = quod_proof_session:open(
               Session, Invocation, {choice, {'X'}}, context(),
               empty_selection()),
        ?assertEqual(
           {solution, {choice, first}},
           quod_proof_session:next(Session, Invocation)),
        ?assertEqual(
           {solution, {choice, second}},
           quod_proof_session:next(Session, Invocation)),
        ?assertMatch(
           {complete, _}, quod_proof_session:next(Session, Invocation))
    after
        quod_proof_session:stop(Session)
    end.

repeated_invocations_share_staged_writes_test() ->
    Session = quod_proof_session:start(committed([]), #{read_set => true}),
    Context = context(),
    First = invocation_id(1),
    Second = invocation_id(2),
    try
        ok = quod_proof_session:open(
               Session, First, {assertz, {first_write, value}}, Context,
               empty_selection()),
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, First)),

        ok = quod_proof_session:open(
               Session, Second,
               {',', {first_write, value},
                {assertz, {second_write, value}}},
               Context, empty_selection()),
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, Second)),

        Changes = quod_proof_session:local_changes(Session),
        ?assert(has_assert({first_write, value}, Changes)),
        ?assert(has_assert({second_write, value}, Changes)),
        ?assert(maps:is_key(
                  {first_write, 1}, quod_proof_session:read_set(Session))),
        ?assert(quod_proof_session:dirty(Session))
    after
        quod_proof_session:stop(Session)
    end.

failed_invocation_keeps_ordinary_prolog_writes_test() ->
    Session = quod_proof_session:start(committed([]), #{read_set => true}),
    Failing = invocation_id(1),
    try
        ok = quod_proof_session:open(
               Session, Failing,
               {',', {assertz, {retained, value}}, fail}, context(),
               empty_selection()),
        ?assertMatch(
           {complete, _}, quod_proof_session:next(Session, Failing)),
        ?assert(has_assert(
                  {retained, value},
                  quod_proof_session:local_changes(Session)))
    after
        quod_proof_session:stop(Session)
    end.

failed_branch_write_is_visible_to_its_next_alternative_test() ->
    Session = quod_proof_session:start(committed([]), #{read_set => true}),
    Invocation = invocation_id(1),
    Goal = {';',
            {',', {assertz, {retained, value}}, fail},
            {retained, value}},
    try
        ok = quod_proof_session:open(
               Session, Invocation, Goal, context(), empty_selection()),
        ?assertEqual(
           {solution, Goal}, quod_proof_session:next(Session, Invocation)),
        ?assert(has_assert(
                  {retained, value},
                  quod_proof_session:local_changes(Session)))
    after
        quod_proof_session:stop(Session)
    end.

stateless_erlog_error_keeps_the_current_revision_test() ->
    Session = quod_proof_session:start(committed([]), #{read_set => true}),
    Invocation = invocation_id(1),
    try
        ok = quod_proof_session:open(
               Session, Invocation, {assertz, true}, context(),
               empty_selection()),
        ?assertMatch(
           {error,
            {erlog,
             {permission_error, modify, static_procedure,
              {'/', true, 0}}}},
           quod_proof_session:next(Session, Invocation)),
        ?assertEqual([], quod_proof_session:local_changes(Session))
    after
        quod_proof_session:stop(Session)
    end.

stateful_erlog_error_preserves_its_revision_test() ->
    Session = quod_proof_session:start(committed([]), #{read_set => true}),
    Failing = invocation_id(1),
    Reader = invocation_id(2),
    try
        Goal = {',', {assertz, {before_error, retained}},
                {',', {set_prolog_flag, unknown, error},
                     missing_predicate}},
        ok = quod_proof_session:open(
               Session, Failing, Goal, context(), empty_selection()),
        ?assertMatch(
           {error,
            {erlog,
             {existence_error, procedure,
              {'/', missing_predicate, 0}}}},
           quod_proof_session:next(Session, Failing)),
        ?assert(has_assert(
                  {before_error, retained},
                  quod_proof_session:local_changes(Session))),
        ok = quod_proof_session:open(
               Session, Reader, {before_error, retained}, context(),
               empty_selection()),
        ?assertMatch({solution, _}, quod_proof_session:next(Session, Reader))
    after
        quod_proof_session:stop(Session)
    end.

transaction_error_adopts_rolled_back_revision_test() ->
    Committed = quod_transaction_predicates:load(committed([])),
    Session = quod_proof_session:start(Committed, #{read_set => true}),
    Failing = invocation_id(1),
    Reader = invocation_id(2),
    try
        Goal = {transaction,
                {',', {assertz, {rolled_back_on_error, hidden}},
                     {assertz, true}}},
        ok = quod_proof_session:open(
               Session, Failing, Goal, context(), empty_selection()),
        ?assertMatch(
           {error,
            {erlog,
             {permission_error, modify, static_procedure,
              {'/', true, 0}}}},
           quod_proof_session:next(Session, Failing)),
        ?assertNot(has_assert(
                     {rolled_back_on_error, hidden},
                     quod_proof_session:local_changes(Session))),
        ok = quod_proof_session:open(
               Session, Reader, {rolled_back_on_error, hidden},
               context(), empty_selection()),
        ?assertMatch({complete, _}, quod_proof_session:next(Session, Reader))
    after
        quod_proof_session:stop(Session)
    end.

older_continuation_rebases_to_newer_overlay_test() ->
    Session = quod_proof_session:start(committed([]), #{read_set => true}),
    Reader = invocation_id(1),
    Writer = invocation_id(2),
    try
        %% The second alternative cannot succeed in the initial ontology view.
        ok = quod_proof_session:open(
               Session, Reader, {';', true, {arrived, later}},
               context(), empty_selection()),
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, Reader)),

        ok = quod_proof_session:open(
               Session, Writer, {assertz, {arrived, later}},
               context(), empty_selection()),
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, Writer)),

        %% Resuming the old choice point keeps its continuation and bindings,
        %% but reads through the writer invocation's current overlay revision.
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, Reader)),
        ?assertMatch(
           {complete, _}, quod_proof_session:next(Session, Reader))
    after
        quod_proof_session:stop(Session)
    end.

publish_then_refresh_preserves_nested_revision_test() ->
    Metadata = {scope, <<"proof-id">>, self()},
    Session = quod_proof_session:start(
                committed([]),
                #{read_set => true, proof_context => Metadata}),
    Outer = invocation_id(1),
    Nested = invocation_id(2),
    try
        ok = quod_proof_session:open(
               Session, Outer, true, context(), empty_selection()),
        {ok, Outer0} =
            quod_proof_session:test_invocation_state(Session, Outer),
        {succeed, OuterWithWrite} =
            erlog_int:prove_goal(
              {assertz, {outer_write, published}}, Outer0),

        %% This is the selector boundary: the suspended outer invocation makes
        %% its in-progress revision canonical before servicing nested work.
        ok = quod_proof_session:publish(OuterWithWrite),
        ok = quod_proof_session:open(
               Session, Nested,
               {',', {outer_write, published},
                {assertz, {nested_write, published}}},
               context(), empty_selection()),
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, Nested)),

        RefreshedOuter = quod_proof_session:refresh(OuterWithWrite),
        ?assertEqual(Metadata, quod_proof_session:context(RefreshedOuter)),
        ?assertMatch(
           {succeed, _},
           erlog_int:prove_goal(
             {',', {outer_write, published},
              {nested_write, published}},
             RefreshedOuter)),
        Changes = quod_proof_session:local_changes(Session),
        ?assert(has_assert({outer_write, published}, Changes)),
        ?assert(has_assert({nested_write, published}, Changes))
    after
        quod_proof_session:stop(Session)
    end.

run_first_keeps_existing_result_contract_test() ->
    Est = quod_predicates:set_context(committed([{parent, tom, bob}]), context()),
    Goal = {',', {parent, tom, {'X'}}, {assertz, {child, {'X'}}}},
    {ok, Bindings, Changes, ReadSet} =
        quod_proof_session:run_first(Goal, Est, #{read_set => true}),
    ?assertEqual(#{'X' => bob}, Bindings),
    ?assert(has_assert({child, bob}, Changes)),
    ?assert(maps:is_key({parent, 2}, ReadSet)),
    ?assertMatch(
       {fail, _},
       quod_proof_session:run_first(
         {child, bob}, Est, #{read_set => true})).

invocation_continuations_are_bounded_test() ->
    Session = quod_proof_session:start(committed([]), #{}),
    try
        lists:foreach(
          fun(Id) ->
              ok = quod_proof_session:open(
                     Session, invocation_id(Id), true, context(),
                     empty_selection())
          end,
          lists:seq(1, ?QUOD_MAX_INVOCATIONS_PER_SCOPE)),
        ?assertEqual(
           {error,
            {proof_limit_exceeded, <<"quod:session-test">>}},
           quod_proof_session:open(
             Session, invocation_id(65535), true, context(),
             empty_selection()))
    after
        quod_proof_session:stop(Session)
    end.

context() ->
    quod_predicates:proof_context(<<"quod:session-test">>, 7, undefined).

empty_selection() -> quod_transaction_scope:empty_selection().

invocation_id(N) -> <<N:128>>.

has_assert(Fact, Changes) ->
    lists:any(
      fun({assert, {Fact0, _Body}}) -> Fact0 =:= Fact;
         (_) -> false
      end, Changes).

committed(Facts) -> quod_ct:committed_kb(Facts).
