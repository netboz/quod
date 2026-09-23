-module(quod_agent_observation_capacity_tests).
-include_lib("eunit/include/eunit.hrl").

observation_capacity_preserves_hosts_and_wakes_on_withdrawal_test_() ->
    [{atom_to_list(Limit), {timeout, 30, fun() -> capacity(Limit) end}}
     || Limit <- [instances, bytes]].

capacity(Limit) ->
    Keys = [runtime_max_agent_observations, runtime_max_agent_observation_bytes],
    Saved = [{K, application:get_env(quod, K)} || K <- Keys],
    try quod_agent_hosting_tests:with_host(fun(Ctx) -> exercise(Limit, Ctx) end,
        fun(_) ->
            {ok, Policy} = erlog_io:read_file(filename:join(code:priv_dir(quod),
                                             "ontologies/agent_recovery_policy.pl")),
            Policy
        end)
    after
        lists:foreach(fun({K, undefined}) -> application:unset_env(quod, K);
                         ({K, {ok, V}}) -> application:set_env(quod, K, V) end, Saved)
    end.

exercise(Limit, #{namespace := Ns, node := Node, reference := Ref, key := Key}) ->
    Host = setelement(2, Node, <<"observed-remote-host">>),
    Size = erlang:external_size({watch, a, Host, 1, none}),
    application:set_env(quod, runtime_max_agent_observations,
                        case Limit of instances -> 2; bytes -> 3 end),
    application:set_env(quod, runtime_max_agent_observation_bytes,
                        case Limit of bytes -> Size * 2; instances -> 1048576 end),
    commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
    {Owner, Child} = receive
        {agent_installed, Runtime, Pid, #{reference := Ref, epoch := 1}, _} -> {Runtime, Pid}
    after 5000 -> error(local_agent_not_installed) end,
    lists:foreach(fun(I) ->
        commit(Ns, {',', {assertz, {agent_host, I, Host, 1, Key}},
                   {',', {assertz, {agent_key, I, Key, active}},
                         {assertz, {agent_recovery_observer, I, Node}}}})
    end, [a, b, c]),
    receive {agent_observation_refused, Owner, c, Host, 1, capacity, _} -> ok
    after 5000 -> error(observation_not_refused_explicitly) end,
    ?assertMatch(#{mode := live, observed_agent_instances := 2,
                   agent_observation_capacity := blocked,
                   agent_observation_refusals_total := 1,
                   collapses := 0, reconcile_failures := 0}, quod_runtime:stats(Ns)),
    ?assert(is_process_alive(Child)),
    ?assertMatch({Owner, [#{pid := Child}]}, quod_runtime:agents(Ns)),
    commit(Ns, {retract, {agent_recovery_observer, a, Node}}),
    Withdrawal = quod_prolog:applied(Ns),
    receive
        {agent_observation_installed, Owner,
         #{observed_agent_instances := 2, agent_observation_capacity := ready}, Height}
          when Height >= Withdrawal -> ok
    after 5000 -> error(capacity_release_did_not_reconcile_ontology) end,
    ?assertMatch(#{mode := live, observed_agent_instances := 2,
                   agent_observation_capacity := ready,
                   agent_observation_refusals_total := 1,
                   collapses := 0, reconcile_failures := 0}, quod_runtime:stats(Ns)),
    ?assertMatch({Owner, [#{pid := Child}]}, quod_runtime:agents(Ns)).

commit(Ns, Goal) -> ?assertMatch({ok, _, _}, quod_ct:rp(Ns, Goal)).
