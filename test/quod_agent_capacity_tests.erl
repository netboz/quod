-module(quod_agent_capacity_tests).
-include_lib("eunit/include/eunit.hrl").

capacity_refuses_only_new_children_and_retries_on_slot_release_test_() ->
    {timeout, 60, fun() ->
        Saved = application:get_env(quod, runtime_max_hosted_agents),
        application:set_env(quod, runtime_max_hosted_agents, 2),
        try quod_agent_hosting_tests:with_host(fun capacity/1)
        after
            case Saved of
                undefined -> application:unset_env(quod, runtime_max_hosted_agents);
                {ok, Limit} -> application:set_env(quod, runtime_max_hosted_agents, Limit)
            end
        end
    end}.

capacity(#{namespace := Ns, reference := Ref,
           node := {agent_instance_ref, NodeNs, NodeAnchor, _} = Node, key := Key}) ->
    Other = setelement(4, Ref, other), Extra = setelement(4, Ref, extra),
    OtherKey = <<71:256>>, ExtraKey = <<72:256>>,
    commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
    {Owner, ActorPid} = installed(Ref),
    commit(Ns, {goal, {agent_hosted, other, Node, 1, OtherKey}}),
    {Owner, OtherPid} = installed(Other),
    commit(Ns, {',', {assertz, {agent_host, extra, Node, 1, ExtraKey}},
                       {assertz, {agent_key, extra, ExtraKey, active}}}),
    receive
        {agent_refused, Owner, #{reference := Extra, epoch := 1, public_key := ExtraKey},
         capacity, _Height} -> ok
    after 10000 -> error(capacity_refusal_not_published) end,
    ?assertMatch(#{mode := live, hosted_agent_instances := 2,
                   agent_capacity_status := blocked, agent_capacity_refusals_total := 1,
                   collapses := 0, reconcile_failures := 0}, quod_runtime:stats(Ns)),
    ?assertEqual({Owner, [ActorPid, OtherPid]}, current_children(Ns, [Ref, Other])),

    %% The containing ontology cannot borrow node authority when its slots are
    %% full. Its logical node acts through its own scope and an explicit grant.
    Anchor = element(3, Ref),
    Operation = {record_ping, at_capacity},
    commit(NodeNs,
      {',', {assertz, {can_execute_for, Ns, Anchor, Operation}},
        {assertz, {':-', {react_on, capacity_probe,
                          {node_authorized_goal, Ns, Anchor, Operation}}, {me, Node}}}}),
    NodeOwner = quod_reg:where({quod_runtime, NodeNs}),
    true = quod_reg:subscribe({agent, Node}),
    NodePid = try
        commit(NodeNs, {trigger_event, capacity_probe}),
        receive
            {agent_request_finished, NodeOwner, Pid,
             #{reference := Node, source := {NodeNs, NodeAnchor}}, _,
             {ok, _, {normalized, {committed, _, _}}}} -> Pid
        after 10000 -> error(node_work_blocked_by_agent_capacity) end
    after quod_reg:unsubscribe({agent, Node}) end,
    ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {ping, at_capacity})),
    ?assertEqual({NodeOwner, [NodePid]}, current_children(NodeNs, [Node])),
    ?assertMatch(#{hosted_agents := 2, hosted_agent_instances := 2,
                   agent_capacity_refusals_total := 1}, quod_runtime:stats(Ns)),

    %% The slot is occupied until the retiring process actually exits. Hold it
    %% alive, and synchronize on the owner's processed retirement transition.
    ok = sys:suspend(OtherPid),
    OtherMonitor = monitor(process, OtherPid),
    1 = erlang:trace_pattern({quod_runtime, stop_agent, 2},
                             [{'_', [], [{return_trace}]}], [local]),
    1 = erlang:trace(Owner, true, [call]),
    try
        commit(Ns, {retract, {agent_host, other, Node, 1, OtherKey}}),
        receive
            {trace, Owner, return_from, {quod_runtime, stop_agent, 2},
             #{pid := OtherPid, stopping := true, successor := none}} -> ok
        after 10000 -> error(retirement_not_processed) end,
        %% This assignment change rechecks the refused binding while the
        %% retiring child still owns its slot; unrelated input did not do so.
        ?assertMatch(#{hosted_agent_instances := 2, agent_capacity_status := blocked,
                       agent_capacity_refusals_total := 2},
                     quod_runtime:stats(Ns)),
        {Owner, BeforeRelease} = quod_runtime:agents(Ns),
        ?assertNot(lists:any(fun(#{binding := #{reference := R}}) -> R =:= Extra end,
                            BeforeRelease))
    after
        erlang:trace(Owner, false, [call]),
        erlang:trace_pattern({quod_runtime, stop_agent, 2}, false, [local]),
        ok = sys:resume(OtherPid)
    end,
    receive {'DOWN', OtherMonitor, process, OtherPid, _} -> ok
    after 10000 -> error(retiring_agent_did_not_exit) end,
    {Owner, ExtraPid} = installed(Extra),
    ?assertEqual({Owner, [ActorPid, ExtraPid]}, current_children(Ns, [Ref, Extra])),
    ?assertEqual({NodeOwner, [NodePid]}, current_children(NodeNs, [Node])),
    ?assertEqual(#{mode => live, hosted_agent_instances => 2,
                   agent_capacity_status => ready, agent_capacity_refusals_total => 2,
                   collapses => 0, reconcile_failures => 0},
                 maps:with([mode, hosted_agent_instances, agent_capacity_status,
                            agent_capacity_refusals_total, collapses, reconcile_failures],
                           quod_runtime:stats(Ns))).

current_children(Ns, Refs) ->
    {Owner, Children} = quod_runtime:agents(Ns),
    ByRef = maps:from_list([{R, P} || #{binding := #{reference := R}, pid := P} <- Children]),
    {Owner, [maps:get(R, ByRef) || R <- Refs]}.

installed(Ref) ->
    receive
        {agent_installed, Owner, Pid, #{reference := Ref, epoch := 1}, _Height} -> {Owner, Pid}
    after 10000 -> error({agent_install_timeout, Ref}) end.

commit(Ns, Goal) -> ?assertMatch({ok, _, _}, quod_ct:rp(Ns, Goal)).
