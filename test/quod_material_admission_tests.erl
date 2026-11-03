-module(quod_material_admission_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

policy_is_authored_and_ambiguous_values_fail_closed_test() ->
    Est = quod_ct:committed_kb([
        {material_limit_override, plan, symbols, 9}]),
    {ok, Limits, Reads} = quod_material_admission:policy(plan, Est),
    ?assertEqual(9, maps:get(symbols, Limits)),
    ?assert(maps:is_key({material_limit_override, 3}, Reads)),
    ?assertEqual({error, {material_limit, plan, symbols, 10, 9}},
        quod_material_admission:check(plan, #{symbols => 10}, Limits)),
    lists:foreach(fun(Override) ->
        Bad = quod_ct:committed_kb(Override),
        ?assertEqual({error, {invalid_material_policy, plan}},
            quod_material_admission:policy(plan, Bad))
    end, [[{material_limit_override, plan, symbols, 9},
           {material_limit_override, plan, symbols, 10}],
          [{material_limit_override, plan, symbols, -1}],
          [{material_limit_override, plan, symbols, {'Unbound'}}]]).

definition_removal_revalidates_affected_material_policy_test() ->
    Est = quod_ct:committed_kb([]),
    try
        {ok, _, Reads} = quod_material_admission:policy(plan, Est),
        ?assertEqual({error, {invalid_material_policy, plan}},
            quod_material_admission:validate_update(plan, Est,
                [{abolish, {material_limit, 3}}], Reads))
    after quod_erlog_db_mvcc:delete((Est#est.db)#db.ref) end.

policy_cannot_write_during_selection_test() ->
    Rule = {':-', {material_limit_override, plan, symbols, 1},
                  {assertz, policy_changed}},
    Est = quod_ct:committed_kb([Rule]),
    ?assertEqual({error, {invalid_material_policy, plan}},
        quod_material_admission:policy(plan, Est)),
    ?assertMatch({fail, _}, erlog_int:prove_goal(policy_changed, Est)).

source_symbol_refusal_precedes_allocation_and_storage_test() ->
    Prefix = integer_to_binary(erlang:unique_integer([positive])),
    Names = [<<"not_admitted_", Prefix/binary, "_", (integer_to_binary(N))/binary>>
             || N <- lists:seq(1, 3)],
    Terms = [{{'$quod_symbol', Name}, 1} || Name <- Names],
    {ok, Request} = quod_ontology:validate_action(
        {create_ontology, <<"admission:refused">>, [{terms, Terms}]}),
    Limits = (quod_ct:material_limits(founding))#{symbols => 2},
    ?assertEqual({error, {material_limit, founding, symbols, 3, 2}},
        quod_ontology:prepare_action(Request, Limits)),
    [?assertException(error, badarg, binary_to_existing_atom(Name, utf8))
     || Name <- Names].

staged_policy_cannot_authorize_its_own_write_test() ->
    with_session([{material_limit_override, plan, operations, 1}], fun(Session) ->
        Goal = {',', {retract, {material_limit_override, plan, operations, 1}},
                {',', {assertz, {material_limit_override, plan, operations, unlimited}},
                      {assertz, payload}}},
        first(Session, Goal),
        ?assertEqual({error, {material_limit, plan, operations, 3, 1}},
            quod_proof_session:seal(Session, binding()))
    end).

invalid_policy_updates_are_refused_before_sealing_test() ->
    lists:foreach(fun(Fact = {material_limit_override, Kind, _, _}) ->
        with_session([], fun(Session) ->
            first(Session, {assertz, Fact}),
            ?assertEqual({error, {invalid_material_policy, Kind}},
                         quod_proof_session:seal(Session, binding()))
        end)
    end, [{material_limit_override, plan, symbols, -1},
          {material_limit_override, plan, symbols, {'Any'}},
          {material_limit_override, plan, unknown_resource, 12},
          {material_limit_override, proof, heap_bytes, -1},
          {material_limit_override, proof, heap_bytes, {'Any'}},
          {material_limit_override, proof, answer_bytes, -1},
          {material_limit_override, proof, answer_bytes, {'Any'}},
          {material_limit_override, proof, unknown_resource, 12}]),
    with_session([{material_limit_override, plan, symbols, 100}], fun(Session) ->
        first(Session, {assertz, {material_limit_override, plan, symbols, 200}}),
        ?assertEqual({error, {invalid_material_policy, plan}},
                     quod_proof_session:seal(Session, binding()))
    end).

proof_budget_is_pinned_and_tracks_helper_changes_test() ->
    Budget = 64 * 1024 * 1024,
    Rule = {':-', {material_limit_override, proof, heap_bytes, {'Limit'}},
                  {proof_allowance, {'Limit'}}},
    with_session([Rule,{proof_allowance,Budget}], fun(Session) ->
        ExpectedWords = Budget div erlang:system_info(wordsize),
        ?assertMatch({max_heap_size,#{size := ExpectedWords}},
                     process_info(self(),max_heap_size)),
        first(Session,{',',{retract,{proof_allowance,Budget}},
                          {assertz,{proof_allowance,unlimited}}}),
        %% A staged increase cannot change the current worker's installed budget.
        ?assertMatch({max_heap_size,#{size := ExpectedWords}},
                     process_info(self(),max_heap_size)),
        {ok,Plan} = quod_proof_session:seal(Session,binding()),
        {ok,#{read_check := Reads}} = quod_dtx:material(Plan),
        ?assert(maps:is_key({proof_allowance,1},Reads)),
        Est = quod_proof_session:committed_state(Session),
        {ok,Changed} = quod_diff:apply_ops(Est,
            quod_ct:diff_for({proof_allowance,10000})),
        Published = quod_ct:commit_kb(Changed,2,1),
        ?assertEqual({conflict,{proof_allowance,1}},
            quod_diff:validate(Reads,(Published#est.db)#db.ref))
    end).

policy_replacement_uses_final_state_and_preserves_zero_allowance_test() ->
    with_session([{material_limit_override, plan, operations, 10}], fun(Session) ->
        first(Session, {',', {assertz, {material_limit_override, plan, operations, 0}},
                             {retract, {material_limit_override, plan, operations, 10}}}),
        ?assertMatch({ok, _}, quod_proof_session:seal(Session, binding()))
    end).

policy_helper_change_is_checked_through_captured_dependencies_test() ->
    Rule = {':-', {material_limit_override, plan, symbols, {'Limit'}},
                  {allocation, {'Limit'}}},
    with_session([Rule,{allocation,100}], fun(Session) ->
        first(Session, {assertz, {allocation,200}}),
        ?assertEqual({error, {invalid_material_policy, plan}},
                     quod_proof_session:seal(Session, binding()))
    end).

sealed_plan_carries_policy_reads_and_reuses_exact_result_test() ->
    with_session([], fun(Session) ->
        first(Session, {assertz, payload}),
        {ok, Plan} = quod_proof_session:seal(Session, binding()),
        {ok, #{read_check := Reads}} = quod_dtx:material(Plan),
        ?assertEqual(never_present, maps:get({material_limit_override, 3}, Reads)),
        ?assertEqual({ok, Plan}, quod_proof_session:seal(Session, binding())),
        ?assertEqual(Reads, quod_proof_session:read_set(Session))
    end).

canonical_byte_and_count_refusals_name_the_resource_test() ->
    lists:foreach(fun({Resource, Limit}) ->
        with_session([{material_limit_override, plan, Resource, Limit}], fun(Session) ->
            first(Session, {assertz, payload}),
            ?assertMatch({error, {material_limit, plan, Resource, Actual, Limit}}
                         when Actual > Limit,
                         quod_proof_session:seal(Session, binding()))
        end)
    end, [{canonical_bytes, 0}, {symbols, 0}, {reads, 0}]).

committed_policy_change_invalidates_the_sealed_plan_test() ->
    #est{db = #db{ref = Ref}} = Est = quod_ct:committed_kb([]),
    Session = quod_proof_session:start(Est,
        #{read_set => true, proof_context => {origin, test}, signer => none}),
    try
        first(Session, {assertz, payload}),
        {ok, Plan} = quod_proof_session:seal(Session, binding()),
        {ok, #{read_check := Reads}} = quod_dtx:material(Plan),
        ?assertEqual(ok, quod_diff:validate(Reads, Ref)),
        {ok, Changed} = quod_diff:apply_ops(Est,
            quod_ct:diff_for({material_limit_override, plan, operations, 0})),
        Published = quod_ct:commit_kb(Changed, 2, 1),
        ?assertEqual({conflict, {material_limit_override, 3}},
            quod_diff:validate(Reads, (Published#est.db)#db.ref)),
        {ok, Limits, _} = quod_material_admission:policy(plan, Published),
        ?assertEqual({error, {material_limit, plan, operations, 1, 0}},
            quod_material_admission:check(plan, #{operations => 1}, Limits)),
        %% Replaying already admitted history does not consult the new policy.
        {ok, Bytes} = quod_dtx:encode(Plan),
        ?assertEqual({ok, Plan}, quod_dtx:decode(Bytes))
    after quod_proof_session:stop(Session), quod_erlog_db_mvcc:delete(Ref)
    end.

with_session(Facts, Fun) ->
    #est{db = #db{ref = Ref}} = Est = quod_ct:committed_kb(Facts),
    {max_heap_size, PreviousHeap} = process_info(self(),max_heap_size),
    Session = quod_proof_session:start(Est,
        #{read_set => true, proof_context => {origin, test}, signer => none}),
    try Fun(Session)
    after
        process_flag(max_heap_size,PreviousHeap),
        quod_proof_session:stop(Session), quod_erlog_db_mvcc:delete(Ref)
    end.

first(Session, Goal) ->
    Id = crypto:strong_rand_bytes(16),
    Context = quod_predicates:proof_context(<<"admission:test">>, 1, undefined, []),
    ok = quod_proof_session:open(Session, Id, Goal, allowed, Context,
                                quod_transaction_scope:empty_selection()),
    ?assertMatch({solution, _}, quod_proof_session:next(Session, Id)).

binding() ->
    #{target => {<<"admission:test">>, <<1:256>>}, base_height => 1,
      proof_id => <<2:256>>, origin => {<<"admission:test">>, <<1:256>>},
      principal => anonymous, request_binding => none}.
