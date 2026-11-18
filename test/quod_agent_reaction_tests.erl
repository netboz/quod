-module(quod_agent_reaction_tests).
-include_lib("eunit/include/eunit.hrl").
-import(quod_agent_hosting_tests, [agent/1, agent_ref/2]).
-include_lib("erlog/src/erlog_int.hrl").

committed_assertions_use_existing_event_admission_and_composition_test_() ->
    {timeout, 60, fun() ->
        Guard = {me, {agent_instance_ref, {'Ns'}, {'Anchor'}, actor}},
        Reaction = {':-', {react_on, {assert, {accepted_input, {'Value'}}},
                           {record_ping, {'Value'}}}, Guard},
        quod_agent_hosting_tests:with_host(fun(#{namespace := Ns, reference := Ref,
                                                node := Node, key := Key}) ->
            commit(Ns, agent({goal, {agent_hosted, agent_ref(Ns, actor), Node, 1, Key}})),
            receive {agent_installed, _, _, #{reference := Ref}, _} -> ok
            after 10000 -> error(assertion_test_agent_not_installed) end,
            Before = maps:get(reactions_executed, quod_runtime:stats(Ns)),
            commit(Ns, {assertz, {accepted_input, original}}),
            ?assertMatch({ok, _, {normalized, {committed, _, _}}}, finished(Ref)),
            ?assertEqual([original], pings(Ns)),
            %% Neither explicit events nor repeated identical composition can
            %% manufacture another committed assertion occurrence.
            lists:foreach(fun(Event) ->
                ?assertNot(quod_diff:valid_ops([{event, Event}])),
                ?assertEqual({error, {erlog, {domain_error, event, Event}}},
                             quod_ct:rp(Ns, {trigger_event, Event}))
            end, [{assert, {accepted_input, forged}},
                  {retract, {accepted_input, original}},
                  {from, Ns, <<1:256>>, {assert, {accepted_input, forged}}}]),
            commit(Ns, {assertz, {accepted_input, original}}),
            commit(Ns, {asserta, {accepted_input, next}}),
            ?assertMatch({ok, _, {normalized, {committed, _, _}}}, finished(Ref)),
            %% An ordinary later event provides processing evidence for the
            %% preceding notices; resulting fact dedup alone is insufficient.
            commit(Ns, {trigger_event, {do_work, barrier}}),
            ?assertMatch({ok, _, {normalized, {committed, _, _}}}, finished(Ref)),
            ?assertEqual([original, next, barrier], pings(Ns)),
            ?assertEqual(Before + 3,
                         maps:get(reactions_executed, quod_runtime:stats(Ns)))
        end, [Reaction, Reaction])
    end}.

committed_definition_removal_keeps_retract_reactions_test_() ->
    {timeout, 60, fun() ->
        Reaction = {':-', {react_on, {retract, {removed_input, {'Value'}}},
                           {record_ping, {'Value'}}},
                          {me, {agent_instance_ref, {'Ns'}, {'Anchor'}, actor}}},
        quod_agent_hosting_tests:with_host(fun(#{namespace := Ns, reference := Ref,
                                                node := Node, key := Key}) ->
            SignedCommit = fun(Goal) ->
                {ok, Bytes, Sig} = quod_node_actor:signed_goal(execute, {'::', Ns, Goal},
                    crypto:strong_rand_bytes(32), quod_time:now_ms() + 20000),
                ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                    quod_client_goal_ingress:submit(Bytes, Sig))
            end,
            commit(Ns, agent({goal, {agent_hosted, agent_ref(Ns, actor), Node, 1, Key}})),
            receive {agent_installed, _, _, #{reference := Ref}, _} -> ok
            after 10000 -> error(removal_test_agent_not_installed) end,
            Before = maps:get(reactions_executed, quod_runtime:stats(Ns)),
            SignedCommit({abolish, {'/', removed_input, 1}}),
            ?assertMatch({ok, _, {normalized, {committed, _, _}}}, finished(Ref)),
            ?assertEqual([original], pings(Ns)),
            ?assertEqual(fail, quod_prolog:prove_ro(
                Ns, {current_predicate, {'/', removed_input, 1}})),
            SignedCommit({trigger_event, {do_work, barrier}}),
            ?assertMatch({ok, _, {normalized, {committed, _, _}}}, finished(Ref)),
            ?assertEqual([original, barrier], pings(Ns)),
            ?assertEqual(Before + 2, maps:get(reactions_executed, quod_runtime:stats(Ns)))
        end, [Reaction, {removed_input, original}])
    end}.

ordinary_owned_reactions_use_signed_goal_admission_test_() ->
    {timeout, 60, fun() ->
        Ns = <<"host-test-agent">>,
        Self = {agent_instance_ref, {'Ns'}, {'Anchor'}, {'Self'}},
        Guard = {',', {me, Self},
                   {',', {instance_of, special, {'Self'}}, {isa, special, reactive}}},
        quod_agent_hosting_tests:with_host(
          fun(#{reference := Ref, node := Node, key := Key}) ->
              commit(Ns, agent({goal, {agent_hosted, agent_ref(Ns, actor), Node, 1, Key}})),
              receive
                  {agent_installed, _, _, #{reference := Ref}, _} -> ok
              after 10000 -> error(actor_not_installed)
              end,
              Before = maps:get(reactions_executed, quod_runtime:stats(Ns)),
              commit(Ns, {trigger_event, {inherited_ping, inherited}}),
              ?assertMatch({ok, _, _}, finished(Ref)),
              %% The class has two paths to reactive; eligibility is an
              %% existence proof and queues this originating clause only once.
              ?assertEqual([inherited], pings(Ns)),
              ?assertEqual(Before + 1, maps:get(reactions_executed, quod_runtime:stats(Ns))),
              commit(Ns, {trigger_event, identify}),
              ?assertMatch({ok, _, _}, finished(Ref)),
              ?assertEqual([inherited, Ref], pings(Ns)),
              commit(Ns, {trigger_event, denied}),
              ?assertMatch({ok, _, {normalized, {failed, _}}}, finished(Ref)),
              commit(Ns, {trigger_event, bad_guard}),
              commit(Ns, {trigger_event, {inherited_ping, final}}),
              ?assertMatch({ok, _, _}, finished(Ref)),
              ?assertEqual([inherited, Ref, final], pings(Ns)),
              ?assertMatch(fail, quod_prolog:prove_ro(Ns, forbidden_guard_write)),
              ?assertMatch(fail, quod_prolog:prove_ro(Ns, forbidden_goal_write)),
              ?assertEqual(1, maps:get(reaction_failures, quod_runtime:stats(Ns)))
          end,
          [{instance_of, special, actor}, {isa, special, left}, {isa, special, right},
           {isa, left, reactive}, {isa, right, reactive},
           {':-', {react_on, {inherited_ping, {'Value'}}, {record_ping, {'Value'}}}, Guard},
           {':-', {react_on, identify, {record_identity, {'Identity'}}}, Guard},
           {':-', {record_identity, {'Identity'}},
             {',', {me, {'Identity'}}, {record_ping, {'Identity'}}}},
           {can_invoke, {record_identity, {'_'}},
             {agent_instance_ref, Ns, {'_'}, actor}, {'_'}, Ns},
           {':-', {react_on, denied, {assertz, forbidden_goal_write}}, Guard},
           {':-', {react_on, bad_guard, {record_ping, bad}},
             {',', Guard, {assertz, forbidden_guard_write}}}])
    end}.

reaction_guard_matching_is_read_only_test() ->
    {ok, Erl} = erlog:new(quod_erlog_db_mvcc, null),
    Est = quod_ask:load(quod_agent_predicates:load(quod_predicates:load(element(3, Erl)))),
    #est{db = #db{ref = Database}} = Committed = quod_ct:commit_kb(Est),
    Binding = #{reference => {agent_instance_ref, <<"guard">>, <<1:256>>, actor},
                epoch => 1, public_key => <<2:256>>, request_timeout_ms => 5000},
    try
        ?assertEqual(unmatched, quod_runtime_predicates:run_reaction(
          <<"guard">>, 1, Binding, {':-', {react_on, event, true}, fail}, event, Committed)),
        ?assertEqual(unmatched, quod_runtime_predicates:run_reaction(
          <<"guard">>, 1, Binding,
          {':-', {react_on, other, true}, {assertz, forbidden}}, event, Committed)),
        ?assertMatch({failed, {reaction_guard, _}}, quod_runtime_predicates:run_reaction(
          <<"guard">>, 1, Binding,
          {':-', {react_on, event, true}, {assertz, forbidden}}, event, Committed)),
        ?assertEqual({failed, {reaction_guard, {ask_requires_anchored_proof, <<"other">>}}},
          quod_runtime_predicates:run_reaction(<<"guard">>, 1, Binding,
            {':-', {react_on, event, true}, {'::', <<"other">>, true}}, event, Committed))
    after
        quod_erlog_db_mvcc:delete(Database)
    end.

nonground_committed_clause_events_do_not_capture_reaction_variables_test_() ->
    {timeout, 30, fun() ->
        quod_agent_hosting_tests:with_host(fun(#{namespace := Ns, reference := Ref,
                                               node := Node, key := Key}) ->
            commit(Ns, agent({goal, {agent_hosted, agent_ref(Ns, actor), Node, 1, Key}})),
            receive {agent_installed, _, _, #{reference := Ref}, _} -> ok
            after 5000 -> error(nonground_test_agent_not_installed) end,
            %% Both the authored reaction and this new clause contain {0}
            %% internally. Matching the real owner notice must standardize
            %% them apart; resource installation alone does not exercise it.
            commit(Ns, {assertz, {nonground_reaction_input, {'Value'}}}),
            ?assertMatch({ok, _, {normalized, {committed, _, _}}}, finished(Ref)),
            ?assertEqual([nonground_safe], pings(Ns))
        end, [{':-', {react_on, {observed, {ontology_changed, {'Heads'}}},
                                {record_ping, nonground_safe}},
                     {',', {me, {agent_instance_ref, {'Ns'}, {'Anchor'}, actor}},
                           {member, {nonground_reaction_input, {'Value'}}, {'Heads'}}}}])
    end}.

commit(Ns, Goal) -> ?assertMatch({ok, _, _}, quod_ct:rp(Ns, Goal)).

finished(Ref) ->
    receive
        {agent_request_finished, _, _, #{reference := Ref}, _, Result} -> Result
    after 10000 -> error(reaction_goal_not_finished)
    end.

pings(Ns) ->
    {ok, [#{'Values' := Values}], _} = quod_prolog:prove_ro(
      Ns, {findall, {'Value'}, {ping, {'Value'}}, {'Values'}}),
    Values.
