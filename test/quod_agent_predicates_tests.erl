-module(quod_agent_predicates_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-export([probe/3]).

reaction_me_is_selected_identity_without_signed_authority_test() ->
    with_state(fun(St0) ->
        Ref = {agent_instance_ref, <<"receiver">>, <<1:256>>, actor},
        Ctx = quod_predicates:with_executor(
          quod_predicates:reaction_context(<<"receiver">>, 1), {actor, Ref, #{}}),
        St = quod_predicates:set_context(St0, Ctx),
        {succeed, Final} = erlog_int:prove_goal({me, {'Self'}}, St),
        ?assertEqual(Ref, erlog_int:dderef({'Self'}, Final#est.bs)),
        ?assertEqual([], bridges(Final)),
        ?assertMatch({fail, _}, erlog_int:prove_goal({me, other}, St))
    end).

ordinary_me_reuses_authenticated_principal_test() ->
    with_state(fun(St0) ->
        Target = {<<"receiver">>, <<1:256>>},
        St = context(St0, element(1, Target), [Target]),
        #{principal := Principal, evidence := Evidence} = quod_ct:signed_goal_fixture(
          #{target => Target}),
        _ = quod_proof_context:start(<<2:256>>, false, Target,
                  quod_time:mono_ms() + 5000, Principal, Evidence),
        try
            {succeed, Final} = erlog_int:prove_goal(
                {',', {current_principal, {'Self'}}, {me, {'Self'}}}, St),
            ?assertEqual([], bridges(Final))
        after quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end) end
    end).

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

reaction_request_metadata_is_not_an_ordinary_goal_authority_test() ->
    with_state(fun(St0) ->
        St = context(St0, <<"receiver">>, [{<<"receiver">>, <<1:256>>}]),
        lists:foreach(fun(Goal) ->
            ?assertMatch({erlog_error, {context_violation, _, reaction, proof}},
                         catch erlog_int:prove_goal(Goal, St))
        end, [{limit_reaction_expiry, 1000}, {prepare_agent_custody, {agent_instance_ref, <<"receiver">>, <<1:256>>, actor}, 1, {'Key'}}]),
        lists:foreach(fun(Functor) ->
            ?assertEqual(undefined, quod_predicates:descriptor(St, Functor))
        end, [{submit_node_goal, 3}, {submit_agent_goal, 4}, {submit_node_prepared_goal, 5}])
    end).

resource_commands_cannot_run_in_reaction_eligibility_test() ->
    with_state(fun(St0) ->
        St = quod_predicates:set_context(St0, quod_predicates:reaction_context(<<"receiver">>, 1)),
        lists:foreach(fun(Goal) ->
            ?assertMatch({erlog_error, {context_violation, _, query, reaction}},
                         catch erlog_int:prove_goal(Goal, St))
        end, [{reconcile_agent_hosts, all}, {reconcile_agent_observers, all}])
    end).

reaction_metadata_backtracks_and_performs_no_preparation_test() ->
    with_state(fun(St0) ->
        Ref = {agent_instance_ref, <<"node">>, <<2:256>>, physical_node},
        Metadata = #{ceiling => 2000, source => {<<"receiver">>, <<1:256>>},
                     mode => {node, Ref, execute},
                     recovery => #{target => {agent_instance_ref, <<"receiver">>, <<1:256>>, actor},
                                   epoch => 1, observer => Ref}},
        Ctx = quod_predicates:with_executor(
          quod_predicates:reaction_context(<<"receiver">>, 1), {actor, Ref, Metadata}),
        {_Frame, St} = quod_erlog_db_local_prove:enter_read_only(
                        quod_predicates:set_context(St0, Ctx)),
        Abandoned = {',', {limit_reaction_expiry, 1000},
                      {',', {prepare_agent_custody, {agent_instance_ref, <<"receiver">>, <<1:256>>, actor}, 1, {'Preparation'}}, fail}},
        Chosen = {',', {limit_reaction_expiry, 1500},
                   {',', {current_request_expiry, {'Expiry'}},
                    {'=', {'Preparation'}, untouched}}},
        Match = {'$quod_reaction_match', event, event, {';', Abandoned, Chosen},
                  {record, {'Preparation'}, {'Expiry'}}, {'Request'}},
        {succeed, Final} = erlog_int:prove_goal(Match, St),
        ?assertEqual({request, {record, untouched, 1500}, 1500, none},
                     erlog_int:dderef({'Request'}, Final#est.bs)),
        Prepare = {'$quod_reaction_match', event, event,
                     {prepare_agent_custody, {agent_instance_ref, <<"receiver">>, <<1:256>>, actor}, 1, {'Preparation'}},
                     {record, {'Preparation'}}, {'Request'}},
        {succeed, Prepared} = erlog_int:prove_goal(Prepare, St),
        {request, {record, Variable}, 2000, {custody, AgentRef, 1, Variable}} =
            erlog_int:dderef({'Request'}, Prepared#est.bs),
        ?assertEqual({agent_instance_ref, <<"receiver">>, <<1:256>>, actor}, AgentRef),
        ?assertMatch({_}, Variable),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          {'$quod_reaction_match', event, event, {limit_reaction_expiry, 2001}, true, {'R'}}, St))
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
