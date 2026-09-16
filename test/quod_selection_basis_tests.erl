-module(quod_selection_basis_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

actual_policy_reads_not_the_advertised_read_set_test() ->
    Est = quod_ct:committed_kb([{':-', allowed, unadvertised_policy}, unadvertised_policy]),
    {succeed, Basis} = prove(allowed, Est),
    ?assert(maps:is_key({fact, {unadvertised_policy, 0}}, Basis)),
    ?assertNot(quod_selection_basis:affected(Basis, #{{fact, {unrelated, 1}} => true})),
    ?assert(quod_selection_basis:affected(Basis, #{{fact, {unadvertised_policy, 0}} => true})),
    ?assertNot(maps:is_key(parent, Basis)),
    destroy(Est).

failed_branch_negation_and_cut_keep_fact_reads_test_() ->
    [?_test(begin
        Est = quod_ct:committed_kb([observed]),
        {succeed, Basis} = prove(Goal, Est),
        ?assert(maps:is_key({fact, {observed, 0}}, Basis)),
        destroy(Est)
    end) || Goal <- [{';', {',', observed, fail}, true},
                     {'\\+', {',', observed, fail}},
                     {',', {';', {',', observed, fail}, true}, '!'},
                     {call, observed}]].

context_observation_is_conservative_through_control_constructs_test_() ->
    Read = {current_prolog_flag, '$quod_ctx', {'Ctx'}},
    [?_test(begin
        Est = quod_ct:committed_kb([]),
        Contextual = quod_predicates:set_context(Est, quod_predicates:policy_verdict_context(<<"basis">>, 1)),
        {succeed, Basis} = prove(Goal, Contextual),
        ?assert(maps:is_key({context, height}, Basis)),
        ?assert(quod_selection_basis:affected(Basis, #{})),
        destroy(Est)
    end) || Goal <- [Read, {call, Read}, {';', {',', Read, fail}, true},
                     {'\\+', {',', Read, fail}},
                     {',', {';', {',', Read, fail}, true}, '!'},
                     {findall, {'Name'}, {current_prolog_flag, {'Name'}, {'Value'}}, {'Names'}}]].

absent_flag_and_unclassified_execution_stay_parent_bound_test() ->
    Est = quod_ct:committed_kb([]),
    {fail, Missing} = prove({current_prolog_flag, nonexistent_flag, {'Value'}}, Est),
    ?assert(maps:is_key({flag_names, nonexistent_flag}, Missing)),
    ?assert(quod_selection_basis:affected(Missing, #{})),
    {succeed, Native} = prove({atom, known_atom}, Est),
    ?assert(maps:is_key(parent, Native)),
    destroy(Est).

observer_is_local_and_released_even_on_exception_test() ->
    Est = quod_ct:committed_kb([ok]),
    Owned = owned_tables(),
    ?assertException(error, original_failure,
        quod_selection_basis:capture(Est, fun(_) -> error(original_failure) end)),
    ?assertEqual(Owned, owned_tables()),
    {succeed, Basis} = prove(ok, Est),
    ?assertEqual(Owned, owned_tables()),
    ?assert(maps:is_key({fact, {ok, 0}}, Basis)),
    %% The original handle does not retain the collector after its lifetime.
    ?assertMatch({succeed, _}, erlog_int:prove_goal(ok, Est)),
    destroy(Est).

changed_functors_describe_only_the_staged_delta_test() ->
    Est = quod_ct:committed_kb([{old, 1}]),
    #est{db = #db{ref = Ref}} = quod_ct:assert_facts([{new, 1}], Est),
    ?assertEqual([{new, 1}], quod_erlog_db_mvcc:changed_functors(Ref)),
    #est{db = #db{ref = Original}} = Est,
    ?assertEqual([], quod_erlog_db_mvcc:changed_functors(Original)),
    destroy(Est).

real_context_policy_changes_verdict_with_unchanged_facts_test() ->
    F = quod_ct:remote_operation_fixture(#{}),
    Target = {Ns, _} = maps:get(participant_target, F), Plan = maps:get(plan, F),
    Transcript = [{_, Chain, GoalBytes, allowed, _, _, _}] = quod_ct:plan_material(transcript, Plan),
    {ok, Goal} = quod_durable_term:decode_goal(GoalBytes),
    Principal = quod_dtx:principal(Plan),
    {ok, NativePrincipal} = quod_agent_ref:materialize_principal(Principal),
    Policy = {can_invoke, Goal, NativePrincipal, [N || {N, _} <- tl(Chain)], Ns},
    Est = quod_ct:committed_kb([{':-', Policy,
        {',', {current_prolog_flag, '$quod_ctx', {'Ctx'}}, {arg, 3, {'Ctx'}, 1}}}]),
    [{ok, B1}, {{error, invalid_authorization_transcript}, B2}] =
        [quod_selection_basis:capture(State, fun(Observed) ->
            quod_ask:validate_authorization_transcript(Target, quod_dtx:origin(Plan),
                Principal, Height, Transcript, Observed)
        end) || {Height, State} <- [{1, Est}, {2, quod_ct:commit_kb(Est, 2, 1)}]],
    [?assert(maps:is_key({context, height}, B)) || B <- [B1, B2]],
    [?assert(quod_selection_basis:affected(B, #{})) || B <- [B1, B2]],
    destroy(Est).

prove(Goal, Est) ->
    quod_selection_basis:capture(Est, fun(Observed) ->
        {Result, _} = erlog_int:prove_goal(Goal, Observed), Result
    end).
destroy(#est{db = #db{ref = Ref}}) -> quod_erlog_db_mvcc:delete(Ref).
owned_tables() -> lists:sort([T || T <- ets:all(), ets:info(T, owner) =:= self()]).
