-module(quod_agent_predicates_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-export([probe/3]).

exact_scope_identity_can_bind_a_durable_fact_test() ->
    with_state(fun(St0) ->
        St = context(St0, <<"receiver">>, [{<<"receiver">>, <<1:256>>}]),
        {succeed, Final} = erlog_int:prove_goal(
          {',', {current_ontology_identity, {'N'}, {'A'}},
           {assertz, {observed_identity, {'N'}, {'A'}}}}, St),
        ?assertEqual(<<"receiver">>, erlog_int:dderef({'N'}, Final#est.bs)),
        ?assertEqual(<<1:256>>, erlog_int:dderef({'A'}, Final#est.bs)),
        ?assertEqual([], bridges(Final)),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          {current_ontology_identity, <<"receiver">>, <<2:256>>}, St))
    end).

missing_or_mismatched_scope_fails_closed_test() ->
    with_state(fun(St0) ->
        Goal = {current_ontology_identity, {'N'}, {'A'}},
        ?assertMatch({fail, _}, erlog_int:prove_goal(Goal, St0)),
        lists:foreach(fun(Chain) ->
            ?assertMatch({fail, _}, erlog_int:prove_goal(
              Goal, context(St0, <<"receiver">>, Chain)))
        end, [[], [{<<"other">>, <<1:256>>}], [{<<"receiver">>, <<1>>}]]),
        Policy = quod_predicates:set_context(
                   St0, quod_predicates:policy_verdict_context(<<"receiver">>, 1)),
        ?assertMatch({erlog_error, {context_violation, _, query, policy_verdict}},
                     catch erlog_int:prove_goal(Goal, Policy))
    end).

signed_expiry_is_proof_bound_not_a_live_clock_test() ->
    with_state(fun(St0) ->
        St = context(St0, <<"receiver">>, [{<<"receiver">>, <<1:256>>}]),
        ?assertMatch({fail, _}, erlog_int:prove_goal({current_request_expiry, {'D'}}, St)),
        #{principal := Principal, evidence := Evidence} = quod_ct:signed_goal_fixture(
          #{target => {<<"receiver">>, <<1:256>>}, deadline => 123456}),
        _ = quod_proof_context:start(<<2:256>>, false, {<<"receiver">>, <<1:256>>},
                  quod_time:mono_ms() + 5000, Principal, Evidence),
        try
            {succeed, Final} = erlog_int:prove_goal(
                {',', {current_request_expiry, {'D'}}, {assertz, {expiry, {'D'}}}}, St),
            ?assertEqual(123456, erlog_int:dderef({'D'}, Final#est.bs)),
            ?assertEqual([], bridges(Final))
        after quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end) end
    end).

node_submission_never_substitutes_for_an_agent_executor_test() ->
    with_state(fun(St0) ->
        Ctx = quod_predicates:with_executor(
          quod_predicates:reaction_context(<<"receiver">>, 1),
          {agent, worker, 1, <<1:256>>}),
        St = quod_predicates:set_context(St0, Ctx),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          {submit_node_goal, execute, true, quod_time:now_ms() + 1000}, St))
    end).

dependency_declaration_preserves_live_failure_reads_test() ->
    with_state(fun(Est) ->
        WithLive = quod_predicates:register(Est, {live_probe, 0}, query, ?MODULE, probe),
        quod_predicates:register(
          WithLive, {bound_probe, 0}, query, proof_bound, ?MODULE, probe)
    end, fun(St2) ->
        St = context(St2, <<"receiver">>, [{<<"receiver">>, <<1:256>>}]),
        {fail, Bound} = erlog_int:prove_goal(bound_probe, St),
        ?assertEqual([], bridges(Bound)),
        {fail, Live} = erlog_int:prove_goal(live_probe, St),
        ?assertEqual([{live_probe, 0}], bridges(Live)),
        ?assertException(error, {external_predicate_conflict, _, _, _},
          quod_predicates:register(St2, {live_probe, 0}, query, proof_bound,
                                   ?MODULE, probe)),
        ?assertException(error, function_clause,
          quod_predicates:register(St2, {bad_probe, 0}, staging, proof_bound,
                                   ?MODULE, probe))
    end).

probe(_Goal, _Next, St) -> erlog_int:fail(St).

context(St, Ns, Chain) ->
    quod_predicates:set_context(St, quod_predicates:proof_context(Ns, 1, undefined, Chain)).

bridges(#est{db = #db{ref = Overlay}}) ->
    quod_erlog_db_local_prove:get_live_bridges(Overlay).

with_state(Fun) ->
    with_state(fun(Est) -> Est end, Fun).

with_state(Configure, Fun) ->
    {ok, Erl} = erlog:new(quod_erlog_db_mvcc, null),
    Est = quod_agent_predicates:load(quod_predicates:load(element(3, Erl))),
    #est{db = #db{ref = Ref}} = Committed = quod_ct:commit_kb(Configure(Est)),
    try Fun(quod_erlog_db_local_prove:wrap_state(Committed, #{read_set => true}))
    after quod_erlog_db_mvcc:delete(Ref) end.
