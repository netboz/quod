-module(quod_prolog_ontology_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

-define(TARGET, {ontology_ref, <<"test:edited">>, <<71:256>>}).

exact_edit_preserves_an_earlier_general_clause_test() ->
    with_editor([{choice, {'X'}}, {choice, specific}], fun(Compiler, Target, Committed) ->
        Indicator = {'/', choice, 1},
        Goal = edit(Compiler, Indicator, source(Target, Indicator), <<"choice(Renamed).">>),
        {succeed, Edited} = erlog_int:prove_goal(Goal, Target),
        Ops = changes(Edited),
        ?assertEqual([{retract, {{choice, specific}, {[], false}}}], Ops),
        {ok, Applied} = quod_diff:apply_ops(Committed, Ops),
        ?assertEqual(source(Edited, Indicator), source(read_view(Applied), Indicator))
    end).

unchanged_source_produces_no_mutations_test() ->
    with_editor([{':-', {choice, {'X'}}, {selected, {'X'}}}],
      fun(Compiler, Target, _Committed) ->
          Indicator = {'/', choice, 1},
          Goal = edit(Compiler, Indicator, source(Target, Indicator),
                      <<"% Formatting and variable names do not change code.\n"
                        "choice(Other) :- selected(Other).">>),
          {succeed, Edited} = erlog_int:prove_goal(Goal, Target),
          ?assertEqual([], changes(Edited)),
          ?assert(maps:is_key({choice, 1},
                   quod_erlog_db_local_prove:get_read_set(db_ref(Edited))))
      end).

changed_suffix_leaves_the_unchanged_prefix_alone_test() ->
    with_editor([{choice, first}, {choice, old_tail}], fun(Compiler, Target, _Committed) ->
        Indicator = {'/', choice, 1},
        Goal = edit(Compiler, Indicator, source(Target, Indicator),
                    <<"choice(first). choice(new_tail).">>),
        {succeed, Edited} = erlog_int:prove_goal(Goal, Target),
        ?assertEqual([{retract, {{choice, old_tail}, {[], false}}},
                      {assert, {{choice, new_tail}, {[], false}}}], changes(Edited))
    end).

reordered_program_survives_canonical_apply_test() ->
    with_editor([{choice, first}, {choice, second}], fun(Compiler, Target, Committed) ->
        Indicator = {'/', choice, 1},
        Goal = edit(Compiler, Indicator, source(Target, Indicator),
                    <<"choice(second). choice(first).">>),
        {succeed, Edited} = erlog_int:prove_goal(Goal, Target),
        ?assertEqual([second, first], choices(Edited)),
        {ok, Applied} = quod_diff:apply_ops(Committed, changes(Edited)),
        ?assertEqual([second, first], choices(read_view(Applied)))
    end).

compiled_edit_composes_inside_an_existing_transaction_test() ->
    with_editor([{choice, first}], fun(Compiler, Target, Committed) ->
        Indicator = {'/', choice, 1},
        Goal = edit(Compiler, Indicator, source(Target, Indicator), <<"choice(second).">>),
        {succeed, Edited} = erlog_int:prove_goal({transaction, Goal}, Target),
        ?assertEqual([second], choices(Edited)),
        {ok, Applied} = quod_diff:apply_ops(Committed, changes(Edited)),
        ?assertEqual([second], choices(read_view(Applied)))
    end).

compiled_edit_cut_and_outer_rollback_preserve_reads_test() ->
    with_editor([{choice, first}], fun(Compiler, Target, _Committed) ->
        Indicator = {'/', choice, 1},
        Goal = edit(Compiler, Indicator, source(Target, Indicator), <<"choice(second).">>),
        Attempt = {transaction, {',', Goal, {',', '!', fail}}},
        {succeed, Refused} = erlog_int:prove_goal({';', Attempt, true}, Target),
        ?assertEqual([], changes(Refused)),
        ?assertEqual([first], choices(Refused)),
        ?assert(maps:is_key({choice, 1},
            quod_erlog_db_local_prove:get_read_set(db_ref(Refused))))
    end).

numeric_facts_roundtrip_through_current_signed_grammar_and_commit_test() ->
    with_editor([{choice, -3}, {choice, -0.0}], fun(Compiler, Target, Committed) ->
        Indicator = {'/', choice, 1},
        Baseline = source(Target, Indicator),
        ?assertNotEqual(<<>>, Baseline),
        Goal0 = edit(Compiler, Indicator, Baseline, <<"choice(-4). choice(-0.0).">>),
        {Goal, _, _} = erlog_int:term_instance(Goal0, 0),
        {ok, Text} = quod_client_goal_parser:format(Goal),
        {ok, #{goal := Parsed}} = quod_client_goal_parser:parse(Text, 3),
        ?assertEqual(quod_wire_term:encode_canonical(Goal), quod_wire_term:encode_canonical(Parsed)),
        {succeed, Edited} = erlog_int:prove_goal(Goal0, Target),
        {ok, Applied} = quod_diff:apply_ops(Committed, changes(Edited)),
        ?assertEqual([-4, -0.0], choices(read_view(Applied))),
        ?assertEqual(source(Edited, Indicator), source(read_view(Applied), Indicator))
    end).

many_clauses_keep_one_ordered_transaction_within_shared_term_depth_test() ->
    with_editor([], fun(Compiler, Target, Committed) ->
        Values = lists:seq(1, 60),
        Draft = iolist_to_binary([io_lib:format("choice(~b).~n", [N]) || N <- Values]),
        Goal0 = edit(Compiler, {'/', choice, 1}, <<>>, Draft),
        {Goal, _, _} = erlog_int:term_instance(Goal0, 0),
        ?assertMatch({transaction, _}, Goal),
        ?assertMatch({ok, _}, quod_durable_term:encode_result(#{<<"Edit">> => Goal})),
        {ok, Text} = quod_client_goal_parser:format(Goal),
        {ok, #{goal := Parsed}} = quod_client_goal_parser:parse(Text, 3),
        ?assertEqual(quod_wire_term:encode_canonical(Goal), quod_wire_term:encode_canonical(Parsed)),
        {succeed, Edited} = erlog_int:prove_goal(Goal0, Target),
        ?assertEqual(60, length(changes(Edited))),
        {ok, Applied} = quod_diff:apply_ops(Committed, changes(Edited)),
        ?assertEqual(Values, choices(read_view(Applied))),
        Reversed = lists:reverse(Values),
        Draft2 = iolist_to_binary([io_lib:format("choice(~b).~n", [N]) || N <- Reversed]),
        Reorder = edit(Compiler, {'/', choice, 1}, source(Edited, {'/', choice, 1}), Draft2),
        {succeed, Reordered} = erlog_int:prove_goal(Reorder, Edited),
        {ok, Applied2} = quod_diff:apply_ops(Committed, changes(Reordered)),
        ?assertEqual(Reversed, choices(read_view(Applied2)))
    end).

stale_baseline_refuses_before_mutating_test() ->
    with_editor([{choice, first}], fun(Compiler, Target, Committed) ->
        Indicator = {'/', choice, 1},
        Goal = edit(Compiler, Indicator, source(Target, Indicator), <<"choice(replacement).">>),
        {ok, NewState} = quod_diff:apply_ops(Committed, quod_ct:diff_for({choice, intervening})),
        Published = quod_ct:commit_kb(NewState, 2, 1),
        Current = wrap(Published),
        try
            {fail, Refused} = erlog_int:prove_goal(Goal, Current),
            ?assert(lists:member({edit_conflict, Indicator}, Refused#est.fail_reasons)),
            ?assertEqual([], changes(Refused)),
            ?assertEqual([first, intervening], choices(Refused))
        after quod_erlog_db_local_prove:cleanup_read_set(Current) end
    end).

wrong_predicate_rolls_back_the_entire_edit_test() ->
    with_editor([{choice, original}], fun(Compiler, Target, _Committed) ->
        Indicator = {'/', choice, 1},
        Goal = edit(Compiler, Indicator, source(Target, Indicator), <<"unrelated(changed).">>),
        {fail, Refused} = erlog_int:prove_goal(Goal, Target),
        ?assert(lists:member({edit_not_representable, Indicator}, Refused#est.fail_reasons)),
        ?assertEqual([], changes(Refused)),
        ?assertEqual([original], choices(Refused)),
        ?assertEqual(<<>>, source(Refused, {'/', unrelated, 1}))
    end).

duplicate_clauses_are_refused_before_a_goal_is_returned_test() ->
    with_editor([], fun(Compiler, _Target, _Committed) ->
        Indicator = {'/', pair, 2},
        lists:foreach(fun(Draft) ->
            {fail, Refused} = erlog_int:prove_goal(
              {prolog_edit_goal, ?TARGET, Indicator, <<>>, Draft, {'Goal'}}, Compiler),
            ?assert(lists:member({duplicate_clause, Indicator}, Refused#est.fail_reasons)),
            ?assertEqual([], changes(Refused))
        end, [<<"pair(X,X). pair(Y,Y).">>,
              <<"pair(a,b). pair(a,b) :- true.">>])
    end).

new_clauses_keep_their_independent_variables_test() ->
    with_editor([], fun(Compiler, Target, Committed) ->
        Goal = edit(Compiler, {'/', pair, 2}, <<>>,
                    <<"pair(X,X). pair(X,Y) :- related(X,Y).">>),
        {succeed, Edited} = erlog_int:prove_goal(Goal, Target),
        {ok, Applied} = quod_diff:apply_ops(Committed, changes(Edited)),
        [{':-', {pair, A, A}, true},
         {':-', {pair, B, C}, {related, B, C}}] =
            value({'Clauses'}, {'$quod_program_source', {'Clauses'},
                       source(read_view(Applied), {'/', pair, 2})}, read_view(Applied)),
        ?assertNotEqual(A, B),
        ?assertNotEqual(B, C)
    end).

compiling_new_symbols_allocates_no_atoms_and_returns_explicit_assertions_test() ->
    Suffix = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    Name = <<"quod_editor_new_", Suffix/binary>>,
    Symbol = {'$quod_symbol', Name},
    with_editor([], fun(Compiler, _Target, _Committed) ->
        Goal = edit(Compiler, {'/', Symbol, 1}, <<>>, <<Name/binary, "(value).">>),
        ?assert(has_assertion(Goal, Symbol)),
        ?assertError(badarg, binary_to_existing_atom(Name, utf8)),
        ?assertEqual([], changes(Compiler))
    end).

edit(Compiler, Indicator, Expected, Draft) ->
    Returned = value({'Goal'},
      {prolog_edit_goal, ?TARGET, Indicator, Expected, Draft, {'Goal'}}, Compiler),
    %% The compiler returns the standard anchored target goal. Execution below
    %% exercises its real local scope through the normal transaction overlay.
    {'::', <<"test:edited">>,
     {',', {current_ontology_identity, <<"test:edited">>, <<71:256>>},
      {transaction, _} = ScopedEdit}} = Returned,
    ?assertEqual([], changes(Compiler)),
    ScopedEdit.

has_assertion({assertz, {':-', {Symbol, value}, true}}, Symbol) -> true;
has_assertion(Term, Symbol) when is_tuple(Term) ->
    lists:any(fun(Part) -> has_assertion(Part, Symbol) end, tuple_to_list(Term));
has_assertion(_, _) -> false.

source(St, Indicator) ->
    value({'Source'},
      {'$quod_predicate_source', Indicator, {'Source'}}, St).

choices(St) ->
    value({'Choices'}, {findall, {'X'}, {choice, {'X'}}, {'Choices'}}, St).

value(Variable, Goal, St) ->
    {succeed, Final} = erlog_int:prove_goal(Goal, St),
    erlog_int:dderef(Variable, Final#est.bs).

changes(St) -> quod_erlog_db_local_prove:get_local_changes(db_ref(St)).
db_ref(#est{db = #db{ref = Ref}}) -> Ref.
wrap(St) -> quod_erlog_db_local_prove:wrap_state(St, #{read_set => true}).
read_view(St) -> quod_erlog_db_local_prove:wrap_state(St).

with_editor(Facts, Fun) ->
    {ok, Terms} = erlog_io:read_file(filename:join(
                     [code:priv_dir(quod), "ontologies", "quod_prolog.pl"])),
    CompilerStore = committed(Terms), TargetStore = committed(Facts),
    Compiler = wrap(CompilerStore), Target = wrap(TargetStore),
    try Fun(Compiler, Target, TargetStore)
    after
        quod_erlog_db_local_prove:cleanup_read_set(Compiler),
        quod_erlog_db_local_prove:cleanup_read_set(Target),
        quod_erlog_db_mvcc:delete(db_ref(CompilerStore)),
        quod_erlog_db_mvcc:delete(db_ref(TargetStore))
    end.

committed(Terms) ->
    Base = quod_committed_projection:new_est(),
    quod_ct:commit_kb(Base#est{db = lists:foldl(
                                    fun erlog_int:assertz_clause/2, Base#est.db, Terms)}).
