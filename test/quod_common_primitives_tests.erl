-module(quod_common_primitives_tests).

%% `'$quod_draw'/3` and `binary_codes/2` on the base engine every ontology
%% starts from. The draw runs inside real proof sessions: an origin session
%% with a started proof context, a scope session carrying the same proof id,
%% and the contexts where it must refuse (no proof, verdict engines).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_vm_limits.hrl").
-export([quod_names_dormant_marker_function/1]).

-define(NS, <<"test:primitives">>).
-define(DRAW, '$quod_draw').

binary_codes_test() ->
    St = bare(),
    ?assertEqual([$U, $g], value({'C'}, {binary_codes, <<"Ug">>, {'C'}}, St)),
    ?assertEqual(<<"Ug">>, value({'B'}, {binary_codes, {'B'}, [$U, $g]}, St)),
    ?assertEqual([], value({'C'}, {binary_codes, <<>>, {'C'}}, St)),
    ?assertEqual(<<>>, value({'B'}, {binary_codes, {'B'}, []}, St)),
    ?assertEqual(<<0, 255>>, value({'B'}, {binary_codes, {'B'}, [0, 255]}, St)),
    ?assertMatch({succeed, _},
                 erlog_int:prove_goal({binary_codes, <<"Ug">>, [$U, $g]}, St)),
    lists:foreach(
      fun(Goal) -> ?assertMatch({fail, _}, erlog_int:prove_goal(Goal, St)) end,
      [{binary_codes, <<"Ug">>, [$U]},
       {binary_codes, ug, {'C'}},
       {binary_codes, 42, {'C'}},
       {binary_codes, [$U], {'C'}},
       {binary_codes, {'B'}, [300]},
       {binary_codes, {'B'}, [-1]},
       {binary_codes, {'B'}, [a]},
       {binary_codes, {'B'}, foo},
       {binary_codes, {'B'}, [$U | {'T'}]},
       {binary_codes, {'B'}, {'C'}}]).

authored_clauses_hide_followers_and_preserve_scope_test() ->
    with_authored([{choice, first}, {choice, second}], fun(St) ->
        ?assertEqual([{':-', {choice, first}, true},
                      {':-', {choice, second}, true}],
                     authored({choice, 1}, St)),
        ?assertEqual([], authored({missing, 1}, St)),
        %% Introspection does not disable following for the rest of the proof.
        Goal = {',', {'$quod_predicate_source', {'/', choice, 1}, {'Source'}},
                {findall, {'H'}, {clause, {choice, {'H'}}, {'Body'}}, {'Heads'}}},
        ?assertEqual(4, length(value({'Heads'}, Goal, St))),
        Reads = quod_erlog_db_local_prove:get_read_set(db_ref(St)),
        ?assert(maps:is_key({choice, 1}, Reads)),
        ?assert(maps:is_key({missing, 1}, Reads)),
        ?assertEqual([], quod_erlog_db_local_prove:get_local_changes(db_ref(St)))
    end).

authored_clauses_fresh_variables_and_control_bodies_test() ->
    X = {'X'}, Y = {'Y'},
    Body = {',', {pair, X, Y}, {',', '!', {';', {left, Y}, {right, X}}}},
    with_authored([{':-', {shared, X}, Body}, {':-', {shared, X}, {pair, X, X}}],
      fun(St) ->
          [First, Second] = authored({shared, 1}, St),
          ?assertEqual(canonical_source({':-', {shared, X}, Body}),
                       canonical_source(First)),
          ?assertEqual(canonical_source({':-', {shared, X}, {pair, X, X}}),
                       canonical_source(Second)),
          {':-', {shared, FirstVariable}, _} = First,
          {':-', {shared, SecondVariable}, _} = Second,
          ?assertNotEqual(FirstVariable, SecondVariable),
          %% Caller variables cannot alias the fresh variables in returned code.
          Goal = {',', {'=', {'Caller'}, untouched},
                  {',', {'$quod_predicate_source', {'/', shared, 1}, {'Source'}},
                   {',', {'$quod_program_source', [
                          {':-', {shared, {'V'}}, {'B'}}, {'Other'}], {'Source'}},
                    {'=', {'V'}, bound}}}},
          ?assertEqual(untouched, value({'Caller'}, Goal, St))
      end).

exact_retract_does_not_remove_general_clause_test() ->
    with_authored([{choice, {'X'}}, {choice, specific}], fun(St) ->
        {succeed, Final} = erlog_int:prove_goal(
                            {'$quod_retract_exact', {choice, specific}}, St),
        [Remaining] = authored({choice, 1}, Final),
        ?assertEqual(canonical_source({':-', {choice, {'X'}}, true}),
                     canonical_source(Remaining)),
        ?assertEqual([{retract, {{choice, specific}, {[], false}}}],
                     quod_erlog_db_local_prove:get_local_changes(db_ref(Final))),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
                                  {'$quod_retract_exact', {choice, specific}}, Final))
    end).

exact_retract_preserves_variable_sharing_test() ->
    X = {'X'}, Y = {'Y'},
    General = {':-', {pair, X, Y}, {same, X, Y}},
    Specific = {':-', {pair, X, X}, {same, X, X}},
    with_authored([General, Specific], fun(St) ->
        Z = {'Renamed'},
        {succeed, Final} = erlog_int:prove_goal(
          {'$quod_retract_exact', {':-', {pair, Z, Z}, {same, Z, Z}}}, St),
        ?assertEqual([canonical_source(General)],
                     [canonical_source(C) || C <- authored({pair, 2}, Final)])
    end).

exact_retract_compiler_control_forms_test() ->
    X = {'X'}, Tail = {'Tail'},
    Bodies = [{once, {same, X, X}},
              {'->', {condition, X}, {then_do, X}},
              {';', {'->', {condition, X}, {then_do, X}}, {otherwise, X}},
              {',', {items, [X | Tail]}, {',', '!', {rest, Tail}}}],
    lists:foreach(fun(Body) ->
        Rule = {':-', {control_example, X}, Body},
        with_authored([Rule], fun(St) ->
            ?assertEqual([canonical_source(Rule)],
              [canonical_source(C) || C <- authored({control_example, 1}, St)]),
            {succeed, Final} = erlog_int:prove_goal({'$quod_retract_exact', Rule}, St),
            ?assertEqual([], authored({control_example, 1}, Final))
        end)
    end, Bodies).

exact_retract_accepts_existing_opaque_symbols_test() ->
    with_authored([{choice, wood}], fun(St) ->
        Opaque = {'$quod_symbol', <<"wood">>},
        ?assertEqual(<<"choice(wood) :- true.\n">>,
          value({'Source'}, {'$quod_predicate_source',
                 {'/', {'$quod_symbol', <<"choice">>}, 1}, {'Source'}}, St)),
        {succeed, Final} = erlog_int:prove_goal(
          {'$quod_retract_exact', {choice, Opaque}}, St),
        ?assertEqual([], authored({choice, 1}, Final))
    end).

authored_cold_predicate_has_empty_baseline_without_atom_allocation_test() ->
    Name = <<"editor_new_predicate_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    with_authored([], fun(St) ->
        ?assertError(badarg, binary_to_existing_atom(Name, utf8)),
        ?assertEqual([], authored({{'$quod_symbol', Name}, 2}, St)),
        ?assertError(badarg, binary_to_existing_atom(Name, utf8))
    end).

predicate_source_compares_bound_text_without_parsing_or_unifying_code_test() ->
    with_authored([{choice, {'X'}}], fun(St) ->
        Source = value({'Source'}, {'$quod_predicate_source', {'/', choice, 1}, {'Source'}}, St),
        ?assertMatch({succeed, _}, erlog_int:prove_goal(
            {'$quod_predicate_source', {'/', choice, 1}, Source}, St)),
        lists:foreach(fun(Other) ->
            ?assertMatch({fail, _}, erlog_int:prove_goal(
                {'$quod_predicate_source', {'/', choice, 1}, Other}, St))
        end, [<<"choice(specific) :- true.\n">>, <<"choice(.\n">>,
              <<"choice(Renamed).\n">>]),
        ?assert(maps:is_key({choice, 1}, quod_erlog_db_local_prove:get_read_set(db_ref(St))))
    end).

authored_introspection_and_exact_retract_include_staged_clauses_test() ->
    with_authored([{choice, original}], fun(St) ->
        Goal = {',', {asserta, {choice, first}},
                {',', {assertz, {choice, last}},
                 {'$quod_retract_exact', {choice, first}}}},
        {succeed, Final} = erlog_int:prove_goal(Goal, St),
        ?assertEqual([{':-', {choice, original}, true},
                      {':-', {choice, last}, true}], authored({choice, 1}, Final)),
        ?assertEqual([{assert, {{choice, last}, {[], false}}}],
                     quod_erlog_db_local_prove:get_local_changes(db_ref(Final)))
    end).

exact_retract_transaction_rollback_retains_reads_test() ->
    with_authored([{choice, original}], fun(St) ->
        Goal = {';', {transaction,
                       {',', {'$quod_retract_exact', {choice, original}}, fail}},
                true},
        {succeed, Final} = erlog_int:prove_goal(Goal, St),
        ?assertEqual([{':-', {choice, original}, true}], authored({choice, 1}, Final)),
        ?assertEqual([], quod_erlog_db_local_prove:get_local_changes(db_ref(Final))),
        ?assert(maps:is_key({choice, 1},
                  quod_erlog_db_local_prove:get_read_set(db_ref(Final))))
    end).

exact_retract_refuses_read_only_session_test() ->
    with_authored([{choice, original}], fun(St) ->
        {_Frame, ReadOnly} = quod_erlog_db_local_prove:enter_read_only(St),
        ?assertThrow({erlog_error, {permission_error, modify, static_procedure,
                                    {'/', choice, 1}}},
                     erlog_int:prove_goal(
                       {'$quod_retract_exact', {choice, original}}, ReadOnly)),
        ?assertEqual([{':-', {choice, original}, true}], authored({choice, 1}, St))
    end).

program_source_preserves_independent_clause_variables_test() ->
    with_authored([], fun(St) ->
        Text = <<"pair(X, X). pair(X, Y) :- once(same(X, Y)).">>,
        [First, Second] = value({'Program'},
          {'$quod_program_source', {'Program'}, Text}, St),
        {pair, A, A} = First,
        {':-', {pair, B, C}, {once, {same, B, C}}} = Second,
        ?assertNotEqual(A, B),
        ?assertNotEqual(B, C),
        Printed = value({'Source'}, {'$quod_program_source', [First, Second], {'Source'}}, St),
        Again = value({'Program'}, {'$quod_program_source', {'Program'}, Printed}, St),
        ?assertEqual([canonical_source(First), canonical_source(Second)],
                     [canonical_source(Clause) || Clause <- Again]),
        ?assertEqual([], value({'Program'},
          {'$quod_program_source', {'Program'}, <<"% Empty program\n">>}, St)),
        ?assertEqual(<<>>, value({'Source'}, {'$quod_program_source', [], {'Source'}}, St)),
        ?assertEqual([], quod_erlog_db_local_prove:get_local_changes(db_ref(St)))
    end).

program_source_does_not_allocate_callable_or_data_atoms_test() ->
    Suffix = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    Name = <<"quod_edit_callable_", Suffix/binary>>,
    Datum = <<"quod_edit_datum_", Suffix/binary>>,
    Text = <<Name/binary, "(", Datum/binary, ").">>,
    with_authored([], fun(St) ->
        [Clause] = value({'Program'}, {'$quod_program_source', {'Program'}, Text}, St),
        ?assertEqual({{'$quod_symbol', Name}, {'$quod_symbol', Datum}}, Clause),
        ?assertError(badarg, binary_to_existing_atom(Name, utf8)),
        ?assertError(badarg, binary_to_existing_atom(Datum, utf8))
    end).

program_source_large_draft_still_allocates_no_atoms_test() ->
    Suffix = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    Names = [<<"quod_edit_budget_", Suffix/binary, "_", (integer_to_binary(N))/binary>>
             || N <- lists:seq(1, ?QUOD_MAX_NEW_MATERIAL_ATOMS + 1)],
    Text = iolist_to_binary([[Name, ".\n"] || Name <- Names]),
    with_authored([], fun(St) ->
        Clauses = value({'Program'}, {'$quod_program_source', {'Program'}, Text}, St),
        ?assertEqual(length(Names), length(Clauses)),
        ?assertError(badarg, binary_to_existing_atom(hd(Names), utf8)),
        ?assertError(badarg, binary_to_existing_atom(lists:last(Names), utf8))
    end).

program_source_reports_syntax_errors_test() ->
    with_authored([], fun(St) ->
        try erlog_int:prove_goal(
              {'$quod_program_source', {'Program'}, <<"broken(.">>}, St) of
            _ -> error(invalid_source_accepted)
        catch
            throw:{erlog_error, {syntax_error, invalid_syntax}, _} -> ok
        end
    end).

origin_draw_test() ->
    ProofId = crypto:strong_rand_bytes(32),
    with_committed(fun(Committed) ->
        with_origin(ProofId, fun() ->
            Draw = fun(Salt, N) ->
                           draw(Committed, {origin, test}, Salt, N)
                   end,
            ?assertEqual(expected(ProofId, salt, 10), Draw(salt, 10)),
            ?assertEqual(Draw(salt, 10), Draw(salt, 10)),
            ?assertEqual(expected(ProofId, {agent, 1, [x]}, 1000),
                         Draw({agent, 1, [x]}, 1000)),
            ?assertEqual(0, Draw(salt, 1)),
            ?assert(lists:all(fun(I) -> I >= 0 andalso I < 7 end,
                              [Draw(S, 7) || S <- lists:seq(1, 20)])),
            Spread = [Draw(S, 1000000) || S <- lists:seq(1, 8)],
            ?assert(length(lists:usort(Spread)) > 1),
            %% The wrapper every ontology calls.
            ?assertEqual(Draw(salt, 10),
                         solve(Committed, {origin, test},
                               {proof_draw, salt, 10, {'I'}}, 'I')),
            %% Backtracking re-asks the same question and gets the same answer.
            ?assertEqual([Draw(s, 100), Draw(s, 100)],
                         solve(Committed, {origin, test},
                               {findall, {'I'},
                                {';', {?DRAW, s, 100, {'I'}},
                                 {?DRAW, s, 100, {'I'}}}, {'L'}}, 'L'))
        end)
    end).

scope_draw_matches_origin_test() ->
    ProofId = crypto:strong_rand_bytes(32),
    Scope = {scope, ProofId, self(), make_ref(), <<1:128>>},
    with_committed(fun(Committed) ->
        ?assertEqual(expected(ProofId, salt, 10),
                     draw(Committed, Scope, salt, 10)),
        with_origin(ProofId, fun() ->
            ?assertEqual(draw(Committed, {origin, test}, salt, 10),
                         draw(Committed, Scope, salt, 10))
        end)
    end).

refuses_outside_a_proof_test() ->
    ProofId = crypto:strong_rand_bytes(32),
    Scope = {scope, ProofId, self(), make_ref(), <<1:128>>},
    Goal = {?DRAW, salt, 10, {'I'}},
    with_committed(fun(Committed) ->
        %% No session metadata at all, and an origin whose proof context was
        %% never started.
        ?assertEqual(fail, quod_ct:session_prove(
                             Committed, undefined, proof_ctx(), Goal)),
        ?assertEqual(fail, quod_ct:session_prove(
                             Committed, {origin, test}, proof_ctx(), Goal)),
        %% Verdict engines never draw, whatever the session carries.
        ?assertEqual(fail, quod_ct:session_prove(
                             Committed, Scope,
                             quod_predicates:verdict_context(?NS, 1), Goal)),
        ?assertEqual(fail, quod_ct:session_prove(
                             Committed, Scope,
                             quod_predicates:policy_verdict_context(?NS, 1),
                             Goal)),
        %% A bare engine without any session fails plainly too.
        ?assertMatch({fail, _}, erlog_int:prove_goal(Goal, bare())),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
                                  {proof_draw, salt, 10, {'I'}}, bare()))
    end).

invalid_inputs_fail_plainly_test() ->
    ProofId = crypto:strong_rand_bytes(32),
    Scope = {scope, ProofId, self(), make_ref(), <<1:128>>},
    with_committed(fun(Committed) ->
        lists:foreach(
          fun(Goal) ->
                  ?assertEqual(fail, quod_ct:session_prove(
                                       Committed, Scope, proof_ctx(), Goal))
          end,
          [{?DRAW, salt, 0, {'I'}},
           {?DRAW, salt, -3, {'I'}},
           {?DRAW, salt, ten, {'I'}},
           {?DRAW, salt, {'N'}, {'I'}},
           {?DRAW, {'Salt'}, 10, {'I'}},
           {?DRAW, {f, {'X'}}, 10, {'I'}},
           {?DRAW, [a | {'T'}], 10, {'I'}},
           {?DRAW, salt, 10, 99}]),
        %% A ground compound salt, and a bound I that matches, succeed.
        I = draw(Committed, Scope, {f, [1, <<"b">>, c]}, 10),
        ?assertMatch({ok, _}, quod_ct:session_prove(
                                Committed, Scope, proof_ctx(),
                                {?DRAW, {f, [1, <<"b">>, c]}, 10, I}))
    end).

%% The founding guard's basis is the release's own applications, not the
%% code path: this test module is on the path and loaded here, yet a symbol
%% only it defines is still reported as new — as a release node that never
%% ships it would see it.
cold_vocabulary_ignores_modules_outside_the_basis_test() ->
    Marker = list_to_atom("quod_names_dormant_marker_" ++ integer_to_list(?LINE)),
    ?assert(lists:member(Marker, quod_wire_term:cold_new_symbols({Marker, x}))),
    ?assert(lists:member(quod_names_dormant_marker_function,
                         quod_wire_term:cold_new_symbols(
                           [{quod_names_dormant_marker_function, 1}]))),
    ?assertEqual([], quod_wire_term:cold_new_symbols({findall, ':-', is, member})),
    Modules = quod_wire_term:release_modules(),
    ?assert(lists:member(quod_wire_term, Modules)),
    ?assert(lists:member(erlog_int, Modules)),
    ?assertNot(lists:member(?MODULE, Modules)),
    ?assert(lists:all(fun(M) -> code:which(M) =/= non_existing end, Modules)).

quod_names_dormant_marker_function(X) -> X.

%% --- helpers ---------------------------------------------------------------

expected(ProofId, Salt, N) ->
    {ok, Bytes} = quod_wire_term:encode_canonical(Salt),
    binary:decode_unsigned(crypto:mac(hmac, sha256, ProofId, Bytes)) rem N.

draw(Committed, Metadata, Salt, N) ->
    solve(Committed, Metadata, {?DRAW, Salt, N, {'I'}}, 'I').

solve(Committed, Metadata, Goal, Var) ->
    {ok, Bindings} = quod_ct:session_prove(
                       Committed, Metadata, proof_ctx(), Goal),
    maps:get(Var, Bindings).

proof_ctx() -> quod_predicates:proof_context(?NS, 1, undefined).

with_origin(ProofId, Fun) ->
    _ = quod_proof_context:start(
          ProofId, false, {?NS, <<0:256>>},
          quod_time:mono_ms() + 60000, anonymous),
    try Fun()
    after quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end)
    end.

with_committed(Fun) ->
    Committed = quod_ct:commit_kb(quod_committed_projection:new_est()),
    try Fun(Committed)
    after
        #est{db = #db{ref = Ref}} = Committed,
        quod_erlog_db_mvcc:delete(Ref)
    end.

bare() ->
    quod_erlog_db_local_prove:wrap_state(
      quod_ct:commit_kb(quod_committed_projection:new_est()),
      #{read_set => true}).

value(Var, Goal, St) ->
    {succeed, Final} = erlog_int:prove_goal(Goal, St),
    erlog_int:dderef(Var, Final#est.bs).

authored({Name, Arity}, St) ->
    value({'Clauses'}, {',', {'$quod_predicate_source', {'/', Name, Arity}, {'Source'}},
                       {'$quod_program_source', {'Clauses'}, {'Source'}}}, St).

canonical_source(Clause) ->
    {Canonical, _, _} = erlog_int:term_instance(Clause, 0),
    Canonical.

db_ref(#est{db = #db{ref = Ref}}) -> Ref.

with_authored(Terms, Fun) ->
    #est{db = Db} = Base = quod_committed_projection:new_est(),
    Loaded = Base#est{db = lists:foldl(fun erlog_int:assertz_clause/2, Db, Terms)},
    Committed = quod_ct:commit_kb(Loaded),
    St = quod_erlog_db_local_prove:wrap_state(Committed, #{read_set => true}),
    try Fun(St)
    after
        quod_erlog_db_local_prove:cleanup_read_set(St),
        quod_erlog_db_mvcc:delete(db_ref(Committed))
    end.
