-module(quod_agent_custody_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

prepared_observation_commits_custody_report_and_assignment_once_test_() ->
    {timeout, 60, fun() ->
        quod_agent_hosting_tests:with_host(fun(Ctx) -> exercise_preparation(Ctx, prepared) end,
            fun(Self) -> recovery_reaction(Self, prepared) end)
    end}.

unavailable_custody_still_records_the_observation_test_() ->
    {timeout, 60, fun() ->
        quod_agent_hosting_tests:with_host(fun(Ctx) -> exercise_preparation(Ctx, unavailable) end,
            fun(Self) -> recovery_reaction(Self, unavailable) end)
    end}.

expired_vault_mailbox_request_never_creates_custody_test_() ->
    {timeout, 60, fun() ->
        quod_agent_hosting_tests:with_host(fun(#{reference := AgentRef, directory := Dir}) ->
            {ok, Blob} = quod_wire_term:encode_canonical(AgentRef),
            Keys = filename:join(Dir, "keys"),
            {ok, Before} = file:list_dir(Keys),
            Vault = quod_reg:where({agent_vault, node}),
            ok = sys:suspend(Vault),
            try
                Parent = self(), Tag = make_ref(),
                Deadline = quod_time:mono_ms() + 100,
                spawn(fun() -> Parent ! {Tag, quod_agent_vault:prepare(Blob, 1, Deadline)} end),
                receive {Tag, Reply} -> ?assertEqual({error, deadline_exceeded}, Reply)
                after 5000 -> error(preparation_call_did_not_expire) end
            after ok = sys:resume(Vault) end,
            %% This synchronous call joins processing of the earlier request;
            %% an expired caller cannot leave a queued key generation behind.
            ?assertEqual({error, invalid_vault_request}, gen_server:call(Vault, processed)),
            {ok, After} = file:list_dir(Keys),
            ?assertEqual(lists:sort(Before), lists:sort(After))
        end)
    end}.

prepared_bridge_rejects_extra_or_bound_result_variables_test_() ->
    {timeout, 60, fun() ->
        quod_agent_hosting_tests:with_host(fun(#{namespace := Ns, identity := #{pubkey := Self}}) ->
            KB = quod_ct:action_kb(<<>>, [quod_agent_predicates], []),
            Expiry = quod_time:now_ms() + 10000,
            Calls = [
                {submit_node_prepared_goal, actor, 1, {'Result'},
                 {probe, {'Result'}, {'Other'}}, Expiry},
                {submit_node_prepared_goal, actor, 1, already_bound,
                 {probe, already_bound}, Expiry},
                {submit_node_prepared_goal, actor, 1, {'Result'}, probe, Expiry}],
            try lists:foreach(fun(Call) ->
                ?assertEqual({failed, handler_failed}, quod_runtime_predicates:run_reaction(
                    Ns, 1, Self, {react_on, {node, Self}, wake, Call}, wake, KB))
            end, Calls)
            after
                #est{db = #db{ref = Ref}} = KB,
                quod_erlog_db_mvcc:delete(Ref)
            end
        end)
    end}.

worker_rejects_custody_from_another_source_identity_test_() ->
    {timeout, 60, fun() ->
        quod_agent_hosting_tests:with_host(fun(#{namespace := Ns, reference := AgentRef,
                                               node := Node, identity := #{pubkey := Pub}}) ->
            Anchor = element(3, AgentRef),
            Binding = #{reference => Node, public_key => Pub, source => {Ns, Anchor}},
            {ok, Child} = quod_agent:start(self(), node, Binding),
            true = quod_reg:subscribe({agent, Node}),
            try
                Ref = make_ref(),
                Work = {custody, setelement(3, AgentRef, <<99:256>>), 1, {0}, {probe, {0}}},
                Child ! {agent_request, self(), Ref, 1,
                         {execute, Work, quod_time:now_ms() + 10000, quod_time:mono_ms() + 10000},
                         erlang:monotonic_time(microsecond)},
                Child ! {agent_release, self(), 1},
                receive
                    {agent_request_finished, _, Child, _, Ref, Result} ->
                        ?assertEqual({error, invalid_preparation_request}, Result)
                after 5000 -> error(prepared_worker_did_not_finish) end
            after
                gen_server:stop(Child), quod_reg:unsubscribe({agent, Node})
            end
        end)
    end}.

recovery_reaction(Self, Kind) ->
    Entry = {report_agent_observation_with_custody, actor, {'Old'}, 1, none,
             {'Episode'}, {observation, 1, {'Episode'}, {'Expiry'}},
             suspected_unreachable, {'Preparation'}},
    Handler = case Kind of
        prepared -> {submit_node_prepared_goal, actor, 1, {'Preparation'}, Entry, {'Expiry'}};
        unavailable -> {submit_node_goal, execute,
                        setelement(9, Entry, {unavailable, vault_unavailable}), {'Expiry'}}
    end,
    Call = {prepare_recovery, {'Old'}, {'Episode'}, {'Expiry'}},
    [{react_on, {node, Self}, Call, Call}, {':-', Call, Handler}].

exercise_preparation(#{namespace := Ns, reference := AgentRef, node := Node,
                       key := OldKey}, Kind) ->
    Old = setelement(2, Node, <<"remote-node">>),
    Anchor = element(3, AgentRef),
    commit(Ns, {goal, {agent_hosted, actor, Old, 1, OldKey}}),
    Rules = [
        {can_report_agent_failure, Node, actor, Old, {'_'}},
        {can_prepare_agent_key, Node, actor, Old, 1},
        {can_assign_agent_host, Node, actor, Old, 1, Node, {'_'}},
        {':-', {agent_recovery_candidate, Node, actor, Old, 1, {'Round'}, Node, 1},
         {agent_failure_support, actor, Old, 1, {'Round'}, Node, suspected_unreachable}}],
    lists:foreach(fun(Fact) -> commit(Ns, {assertz, Fact}) end, Rules),
    Grant = {can_execute_for, Ns, Anchor,
             {report_agent_observation_with_custody, actor, Old, 1, none,
              {'_'}, {'_'}, suspected_unreachable, {'_'}}},
    commit(element(2, Node), {assertz, Grant}),
    true = quod_reg:subscribe({agent, Node}),
    try
        Before = quod_prolog:applied(Ns),
        Episode = crypto:strong_rand_bytes(32),
        Expiry = quod_time:now_ms() + 10000,
        commit(Ns, {trigger_event, {prepare_recovery, Old, Episode, Expiry}}),
        receive
            {agent_request_finished, _, _, #{source := {Ns, Anchor}}, _, Result} ->
                ?assertMatch({ok, _, {normalized, {committed, _, _}}}, Result),
                {ok, #{request := Request}, _} = Result,
                ?assertEqual(Expiry, maps:get(not_after_ms, Request))
        after 15000 -> error({prepared_observation_not_completed, quod_runtime:stats(Ns)}) end,
        %% One explicit wake occurrence and one complete recovery consequence.
        ?assertEqual(Before + 2, quod_prolog:applied(Ns)),
        assert_preparation_result(Kind, Ns, AgentRef, Node, Old, OldKey, Episode, Expiry)
    after quod_reg:unsubscribe({agent, Node}) end.

assert_preparation_result(prepared, Ns, AgentRef, Node, _Old, OldKey, _Episode, _Expiry) ->
    {ok, Blob} = quod_wire_term:encode_canonical(AgentRef),
    {ok, Pub} = quod_agent_vault:prepare(Blob, 1),
    ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {agent_hosted, actor, Node, 2, Pub})),
    ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {agent_key, actor, OldKey, revoked})),
    ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {agent_candidate_key, actor, {'_'}, {'_'}, {'_'}, {'_'}})),
    receive {agent_installed, _, _, #{reference := AgentRef, epoch := 2}, _} -> ok
    after 5000 -> error(prepared_assignment_not_installed) end;
assert_preparation_result(unavailable, Ns, _AgentRef, Node, Old, OldKey, Episode, Expiry) ->
    ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {agent_hosted, actor, Old, 1, OldKey})),
    ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns,
        {agent_failure_report, actor, Old, 1, Episode, Node,
         {observation, 1, Episode, Expiry}, suspected_unreachable})),
    ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {agent_candidate_key, actor, {'_'}, {'_'}, {'_'}, {'_'}})).

commit(Ns, Goal) -> ?assertMatch({ok, _, _}, quod_ct:rp(Ns, Goal)).
