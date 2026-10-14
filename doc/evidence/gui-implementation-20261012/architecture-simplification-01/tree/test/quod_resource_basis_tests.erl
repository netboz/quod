-module(quod_resource_basis_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-export([opaque_native/3]).

helper_reads_are_selective_test() ->
    with_kb([{':-', enabled, helper}, helper], fun(Est) ->
        {succeed, Basis} = prove(enabled, Est),
        ?assert(quod_resource_basis:affected(Basis, #{{fact, {helper, 0}} => true})),
        ?assertNot(quod_resource_basis:affected(Basis, #{{fact, {unrelated, 1}} => true})),
        ?assertNot(maps:is_key(parent, Basis))
    end).

failed_negative_and_backtracked_reads_test_() ->
    [?_test(with_kb([observed], fun(Est) ->
        {_Result, Basis} = prove(Goal, Est),
        ?assert(maps:is_key({fact, {observed, 0}}, Basis)),
        ?assertNot(maps:is_key(parent, Basis))
    end)) || Goal <- [{',', observed, fail},
                     {'\\+', {',', observed, fail}},
                     {';', {',', observed, fail}, true},
                     {',', {';', {',', observed, fail}, true}, '!'}]].

absent_optional_predicate_is_retained_test() ->
    with_kb([], fun(Est) ->
        {fail, Basis} = prove(optional_selector, Est),
        ?assert(quod_resource_basis:affected(
                  Basis, #{{fact, {optional_selector, 0}} => true})),
        ?assertNot(quod_resource_basis:affected(Basis, #{{fact, {other, 0}} => true}))
    end).

predicate_enumeration_remembers_absent_names_test() ->
    with_kb([], fun(Est) ->
        {fail, Basis} = prove({current_predicate, {'/', enabled, 0}}, Est),
        ?assert(maps:is_key(predicate_registry, Basis)),
        ?assert(quod_resource_basis:affected(Basis, #{predicate_registry => true})),
        Added = quod_ct:commit_kb(quod_ct:assert_facts([enabled], Est), 2, 1),
        {succeed, _} = prove({current_predicate, {'/', enabled, 0}}, Added)
    end).

reflection_is_observed_without_changing_transaction_tokens_test() ->
    with_kb([enabled], fun(Est) ->
        {{ok, _, [], Reads}, Basis} = select(
            {predicate_property, enabled, interpreted}, Est),
        ?assert(maps:is_key({fact, {enabled, 0}}, Basis)),
        ?assertNot(maps:is_key({enabled, 0}, Reads)),
        {{fail, _}, Missing} = select(
            {predicate_property, absent, interpreted}, Est),
        ?assert(maps:is_key({fact, {absent, 0}}, Missing))
    end).

pure_native_backtracking_keeps_normal_selection_selective_test() ->
    with_kb([{item, one}, {item, two}], fun(Est) ->
        Goal = {findall, {'X'},
                {',', {member, {'X'}, [one, two]},
                 {',', {atom, {'X'}}, {item, {'X'}}}}, {'Rows'}},
        {{ok, #{'Rows' := [one, two]}, [], _}, Basis} = select(Goal, Est),
        ?assertNot(maps:is_key(parent, Basis)),
        ?assertNot(quod_resource_basis:affected(Basis, #{{fact, {other, 0}} => true})),
        ?assert(quod_resource_basis:affected(Basis, #{{fact, {item, 1}} => true}))
    end).

unknown_native_and_its_continuation_stay_conservative_test() ->
    with_kb([], fun(#est{db = Db} = Est) ->
        Native = Est#est{db = erlog_int:add_compiled_proc(
                               {opaque_native, 0}, ?MODULE, opaque_native, Db)},
        {fail, Basis} = prove(opaque_native, Native),
        ?assert(quod_resource_basis:affected(Basis, #{}))
    end).

opaque_native(opaque_native, Next, St) ->
    erlog_int:prove_body([{member, {'X'}, [one, two]}, fail | Next], St).

errors_retain_prior_dependencies_and_cleanup_test() ->
    with_kb([helper], fun(Est) ->
        Owned = owned_tables(),
        {{error, {error, selector_crashed, _Stack}}, Basis} =
            quod_resource_basis:capture(Est, fun(Observed) ->
                {succeed, _} = erlog_int:prove_goal(helper, Observed),
                error(selector_crashed)
            end),
        ?assert(maps:is_key({fact, {helper, 0}}, Basis)),
        ?assertEqual(Owned, owned_tables()),
        %% The underlying committed handle never retains the expired sink.
        ?assertMatch({succeed, _}, erlog_int:prove_goal(helper, Est))
    end).

proof_errors_retain_dependencies_after_session_cleanup_test() ->
    with_kb([helper], fun(Est) ->
        Owned = owned_tables(),
        {{error, _}, Basis} = select({',', helper, {'is', {'X'}, impossible}}, Est),
        ?assert(maps:is_key({fact, {helper, 0}}, Basis)),
        ?assertEqual(Owned, owned_tables())
    end).

context_and_unknown_inputs_are_conservative_test() ->
    with_kb([], fun(Est) ->
        Contextual = quod_predicates:set_context(
                       Est, quod_predicates:policy_verdict_context(<<"basis">>, 1)),
        {succeed, ContextBasis} = prove(
            {current_prolog_flag, '$quod_ctx', {'Ctx'}}, Contextual),
        ?assert(quod_resource_basis:affected(ContextBasis, #{})),
        {ok, Unknown} = quod_resource_basis:capture(Est, fun(Observed) ->
            quod_observation:note(unclassified_input, Observed)
        end),
        ?assert(quod_resource_basis:affected(Unknown, #{}))
    end).

explicit_owner_inputs_are_selective_test() ->
    with_kb([], fun(Est) ->
        {ok, Basis} = quod_resource_basis:capture(Est, fun(Observed) ->
            quod_observation:note({input, node_identity}, Observed)
        end),
        ?assert(quod_resource_basis:affected(Basis, #{{input, node_identity} => true})),
        ?assertNot(quod_resource_basis:affected(Basis, #{{fact, {other, 0}} => true}))
    end).

select(Goal, Est) ->
    Context = quod_predicates:policy_verdict_context(<<"basis">>, 1),
    quod_resource_basis:capture(quod_predicates:set_context(Est, Context),
      fun(Observed) ->
          quod_proof_session:run_first(Goal, Observed,
                                      #{read_set => true, read_only => true})
      end).

prove(Goal, Est) ->
    quod_resource_basis:capture(Est, fun(Observed) ->
        {Result, _} = erlog_int:prove_goal(Goal, Observed), Result
    end).

with_kb(Facts, Evaluate) ->
    #est{db = #db{ref = Ref}} = Est = quod_ct:committed_kb(Facts),
    try Evaluate(Est) after quod_erlog_db_mvcc:delete(Ref) end.

owned_tables() -> lists:sort([T || T <- ets:all(), ets:info(T, owner) =:= self()]).
