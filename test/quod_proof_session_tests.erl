-module(quod_proof_session_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_proof_limits.hrl").

repeated_invocations_share_staged_writes_test() ->
    Session = quod_proof_session:start(committed([]), #{read_set => true}),
    Context = context(),
    try
        ok = quod_proof_session:open(
               Session, first, {assertz, {first_write, value}}, Context),
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, first)),

        ok = quod_proof_session:open(
               Session, second,
               {',', {first_write, value},
                {assertz, {second_write, value}}},
               Context),
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, second)),

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
    try
        ok = quod_proof_session:open(
               Session, failing,
               {',', {assertz, {retained, value}}, fail}, context()),
        ?assertMatch(
           {complete, _}, quod_proof_session:next(Session, failing)),
        ?assert(has_assert(
                  {retained, value},
                  quod_proof_session:local_changes(Session)))
    after
        quod_proof_session:stop(Session)
    end.

stateful_erlog_error_preserves_its_revision_test() ->
    Session = quod_proof_session:start(committed([]), #{read_set => true}),
    try
        Goal = {',', {assertz, {before_error, retained}},
                {',', {set_prolog_flag, unknown, error},
                     missing_predicate}},
        ok = quod_proof_session:open(Session, failing, Goal, context()),
        ?assertMatch(
           {error,
            {erlog,
             {existence_error, procedure,
              {'/', missing_predicate, 0}}}},
           quod_proof_session:next(Session, failing)),
        ?assert(has_assert(
                  {before_error, retained},
                  quod_proof_session:local_changes(Session))),
        ok = quod_proof_session:open(
               Session, reader, {before_error, retained}, context()),
        ?assertMatch({solution, _}, quod_proof_session:next(Session, reader))
    after
        quod_proof_session:stop(Session)
    end.

transaction_error_adopts_rolled_back_revision_test() ->
    Committed = quod_transaction_predicates:load(committed([])),
    Session = quod_proof_session:start(Committed, #{read_set => true}),
    try
        Goal = {transaction,
                {',', {assertz, {rolled_back_on_error, hidden}},
                     {assertz, true}}},
        ok = quod_proof_session:open(Session, failing_tx, Goal, context()),
        ?assertMatch(
           {error,
            {erlog,
             {permission_error, modify, static_procedure,
              {'/', true, 0}}}},
           quod_proof_session:next(Session, failing_tx)),
        ?assertNot(has_assert(
                     {rolled_back_on_error, hidden},
                     quod_proof_session:local_changes(Session))),
        ok = quod_proof_session:open(
               Session, reader, {rolled_back_on_error, hidden}, context()),
        ?assertMatch({complete, _}, quod_proof_session:next(Session, reader))
    after
        quod_proof_session:stop(Session)
    end.

older_continuation_rebases_to_newer_overlay_test() ->
    Session = quod_proof_session:start(committed([]), #{read_set => true}),
    try
        %% The second alternative cannot succeed in the initial ontology view.
        ok = quod_proof_session:open(
               Session, reader, {';', true, {arrived, later}}, context()),
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, reader)),

        ok = quod_proof_session:open(
               Session, writer, {assertz, {arrived, later}}, context()),
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, writer)),

        %% Resuming the old choice point keeps its continuation and bindings,
        %% but reads through the writer invocation's current overlay revision.
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, reader)),
        ?assertMatch(
           {complete, _}, quod_proof_session:next(Session, reader))
    after
        quod_proof_session:stop(Session)
    end.

publish_then_refresh_preserves_nested_revision_test() ->
    Metadata = {scope, <<"proof-id">>, self()},
    Session = quod_proof_session:start(
                committed([]),
                #{read_set => true, proof_context => Metadata}),
    try
        ok = quod_proof_session:open(
               Session, outer, true, context()),
        {ok, Outer0} =
            quod_proof_session:test_invocation_state(Session, outer),
        {succeed, OuterWithWrite} =
            erlog_int:prove_goal(
              {assertz, {outer_write, published}}, Outer0),

        %% This is the selector boundary: the suspended outer invocation makes
        %% its in-progress revision canonical before servicing nested work.
        ok = quod_proof_session:publish(OuterWithWrite),
        ok = quod_proof_session:open(
               Session, nested,
               {',', {outer_write, published},
                {assertz, {nested_write, published}}},
               context()),
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, nested)),

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
    ?assert(maps:is_key({parent, 2}, ReadSet)).

invocation_continuations_are_bounded_test() ->
    Session = quod_proof_session:start(committed([]), #{}),
    try
        lists:foreach(
          fun(Id) ->
              ok = quod_proof_session:open(
                     Session, Id, true, context())
          end,
          lists:seq(1, ?QUOD_MAX_INVOCATIONS_PER_SCOPE)),
        ?assertEqual(
           {error, too_many_invocations},
           quod_proof_session:open(Session, overflow, true, context()))
    after
        quod_proof_session:stop(Session)
    end.

context() ->
    quod_predicates:proof_context(<<"quod:session-test">>, 7, undefined).

has_assert(Fact, Changes) ->
    lists:any(
      fun({assert, {Fact0, _Body}}) -> Fact0 =:= Fact;
         (_) -> false
      end, Changes).

committed(Facts) ->
    {ok, Erl} = erlog:new(erlog_db_dict, null),
    State0 = element(3, Erl),
    {succeed, State1} =
        erlog_int:prove_goal({set_prolog_flag, unknown, fail}, State0),
    lists:foldl(
      fun(Fact, State) ->
              {succeed, Next} =
                  erlog_int:prove_goal({assertz, Fact}, State),
              Next
      end, State1, Facts).
