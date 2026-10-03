-module(quod_agent_custody_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

prepared_observation_commits_custody_report_and_assignment_once_test_() ->
    {timeout, 60, fun() ->
        quod_agent_hosting_tests:with_host(fun(Ctx) -> exercise_preparation(Ctx, prepared) end)
    end}.

unavailable_custody_still_records_the_observation_test_() ->
    {timeout, 60, fun() ->
        quod_agent_hosting_tests:with_host(fun(Ctx) -> exercise_preparation(Ctx, unavailable) end)
    end}.

recovery_acl_external_query_is_rejected_at_commit_test_() ->
    {timeout, 60, fun() ->
        quod_agent_hosting_tests:with_host(fun(Ctx) -> exercise_preparation(Ctx, invalid_acl) end)
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
        quod_agent_hosting_tests:with_host(fun(#{reference := AgentRef,
                                               node := Node, identity := #{pubkey := Self}}) ->
            KB = quod_ct:action_kb(<<>>, [quod_agent_predicates], []),
            Binding = #{reference => Node, public_key => Self, epoch => 0,
                        source => {element(2, Node), element(3, Node)}, credential => node,
                        recovery => #{target => AgentRef, epoch => 1, observer => Node},
                        request_timeout_ms => 10000},
            Calls = [
                {{'Result'}, {probe, {'Result'}, {'Other'}}},
                {already_bound, {probe, already_bound}},
                {{'Result'}, probe}],
            try lists:foreach(fun({Result, Template}) ->
                Clause = {':-', {react_on, wake, Template},
                          {prepare_agent_custody, AgentRef, 1, Result}},
                ?assertEqual(unmatched, quod_runtime_predicates:run_reaction(
                    element(2, Node), 1, Binding, Clause, wake, KB))
            end, Calls)
            after
                #est{db = #db{ref = Ref}} = KB,
                quod_erlog_db_mvcc:delete(Ref)
            end
        end)
    end}.

worker_refuses_custody_for_wrong_target_anchor_test_() ->
    {timeout, 60, fun() ->
        quod_agent_hosting_tests:with_host(fun(#{namespace := Ns, reference := AgentRef,
                                               node := Node, identity := #{pubkey := Pub}}) ->
            Binding = #{reference => Node, epoch => 0,
                        public_key => Pub, source => {element(2, Node), element(3, Node)}},
            {ok, Child} = quod_agent:start(self(), node, Binding),
            true = quod_reg:subscribe({agent, Node}),
            try
                Ref = make_ref(),
                Work = {custody, setelement(3, AgentRef, <<99:256>>), 1, {0}, {probe, {0}}},
                Child ! {agent_request, self(), Ref, 1,
                         {{node, Node, execute}, Work,
                          quod_time:now_ms() + 10000, quod_time:mono_ms() + 10000},
                         erlang:monotonic_time(microsecond)},
                Child ! {agent_release, self(), 1},
                receive
                    {agent_request_finished, _, Child, _, Ref, Result} ->
                        ?assertMatch({ok, _, {normalized, {failed, _}}}, Result),
                        {ok, #{request := Request}, _} = Result,
                        ?assertEqual({ok, maps:get(goal_text, Request)},
                                     quod_client_goal_parser:format(
                                       {probe, {unavailable, preparation_not_authorized}})),
                        ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns,
                            {agent_hosted, actor, Node, 2, {'_'}}))
                after 5000 -> error(prepared_worker_did_not_finish) end
            after
                gen_server:stop(Child), quod_reg:unsubscribe({agent, Node})
            end
        end)
    end}.

exercise_preparation(#{namespace := Ns, reference := AgentRef, node := Node,
                       key := OldKey, identity := #{pubkey := NodeKey}}, Kind) ->
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
    Entry = {report_agent_observation_with_custody, actor, Old, 1, none,
             {'_'}, {'_'}, suspected_unreachable, {'_'}},
    %% Exercise the real foreign-entry ACL, without the fixture's broad node
    %% grant masking an invalid commit-time authorization rule. The anchored
    %% guard is part of the admitted goal; the policy body stays pure Prolog.
    Guarded = {',', {current_ontology_identity, Ns, Anchor}, {call, Entry}},
    Policy = case Kind of
        invalid_acl -> {current_ontology_identity, Ns, Anchor};
        _ -> {can_report_agent_failure, Node, actor, Old, suspected_unreachable}
    end,
    commit(Ns, {',', {abolish, {'/', can_invoke, 4}},
                {',', {assertz, {':-', {can_invoke, Guarded, Node, {'_'}, Ns}, Policy}},
                      {assertz, {can_invoke, {'_'}, {node, NodeKey}, [], Ns}}}}),
    Grant = {can_execute_for, Ns, Anchor,
             {report_agent_observation_with_custody, actor, Old, 1, none,
              {'_'}, {'_'}, suspected_unreachable, {'_'}}},
    commit(element(2, Node), {assertz, Grant}),
    true = quod_reg:subscribe({agent, Node}),
    NodeNs = element(2, Node), NodeAnchor = element(3, Node),
    Binding = #{reference => Node, public_key => NodeKey, epoch => 0,
                source => {NodeNs, NodeAnchor}},
    {ok, Child} = quod_agent:start(self(), node, Binding),
    try
        Before = quod_prolog:applied(Ns),
        Episode = crypto:strong_rand_bytes(32),
        Expiry = quod_time:now_ms() + 10000,
        Template = {report_agent_observation_with_custody, actor, Old, 1, none,
                    Episode, {observation, 1, Episode, Expiry}, suspected_unreachable, {0}},
        Work = case Kind of
            unavailable -> {node_authorized_goal, Ns, Anchor,
                             setelement(9, Template, {unavailable, vault_unavailable})};
            _ -> {custody, AgentRef, 1, {0}, {node_authorized_goal, Ns, Anchor, Template}}
        end,
        Token = make_ref(),
        %% The real queue consumes the same private request description that
        %% matching produces. No user-authored event borrows node authority.
        Child ! {agent_request, self(), Token, 1,
                 {{node, Node, execute}, Work, Expiry, quod_time:mono_ms() + 10000},
                 erlang:monotonic_time(microsecond)},
        Child ! {agent_release, self(), 1},
        receive
            {agent_request_finished, _, Child, #{source := {NodeNs, NodeAnchor}}, Token, Result} ->
                case Kind of
                    invalid_acl -> ?assertMatch({ok, _, {normalized, {error, proof_unavailable}}}, Result);
                    _ -> ?assertMatch({ok, _, {normalized, {committed, _, _}}}, Result)
                end,
                {ok, #{request := Request}, _} = Result,
                ?assertEqual(Expiry, maps:get(not_after_ms, Request))
        after 15000 -> error({prepared_observation_not_completed, quod_runtime:stats(Ns)}) end,
        %% Custody, report and assignment are one committed domain transition.
        case Kind of invalid_acl -> ok; _ -> ?assertEqual(Before + 1, quod_prolog:applied(Ns)) end,
        assert_preparation_result(Kind, Ns, AgentRef, Node, Old, OldKey, Episode, Expiry)
    after gen_server:stop(Child), quod_reg:unsubscribe({agent, Node}) end.

assert_preparation_result(prepared, Ns, AgentRef, Node, _Old, OldKey, _Episode, _Expiry) ->
    {ok, Blob} = quod_wire_term:encode_canonical(AgentRef),
    {ok, Pub} = quod_agent_vault:prepare(Blob, 1),
    ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {agent_hosted, actor, Node, 2, Pub})),
    ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {agent_key, actor, OldKey, revoked})),
    ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {agent_candidate_key, actor, {'_'}, {'_'}, {'_'}, {'_'}})),
    receive {agent_installed, _, _, #{reference := AgentRef, epoch := 2}, _} -> ok
    after 5000 -> error({prepared_assignment_not_installed,
                         quod_runtime:stats(Ns), quod_runtime:agents(Ns)}) end;
assert_preparation_result(unavailable, Ns, _AgentRef, Node, Old, OldKey, Episode, Expiry) ->
    ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {agent_hosted, actor, Old, 1, OldKey})),
    ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns,
        {agent_failure_report, actor, Old, 1, Episode, Node,
         {observation, 1, Episode, Expiry}, suspected_unreachable})),
    ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {agent_candidate_key, actor, {'_'}, {'_'}, {'_'}, {'_'}}));
assert_preparation_result(invalid_acl, Ns, _AgentRef, _Node, Old, OldKey, _Episode, _Expiry) ->
    ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {agent_hosted, actor, Old, 1, OldKey})),
    ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {agent_candidate_key, actor, {'_'}, {'_'}, {'_'}, {'_'}})),
    ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns,
        {agent_failure_report, actor, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}})).

commit(Ns, Goal) -> ?assertMatch({ok, _, _}, quod_ct:rp(Ns, Goal)).
