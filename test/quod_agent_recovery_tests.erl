-module(quod_agent_recovery_tests).
-include_lib("eunit/include/eunit.hrl").

host_loss_drains_more_than_executor_capacity_without_collapsing_test_() ->
    {timeout, 90, fun() -> with_recovery_peer(20, fun(Ctx) ->
        #{namespace := Ns, runtime := Runtime, peer := Peer, assignments := Assignments} = Ctx,
        application:set_env(quod, runtime_max_queued_events, 8),
        ?assertMatch(#{collapses := 0}, quod_runtime:stats(Ns)),
        ok = quod_agent_peer:stop(Peer),
        Installed = await_recovered(Ns, Runtime, Assignments, quod_time:mono_ms() + 45000),
        assert_recovered(Ctx, Runtime, Installed)
    end) end}.

runtime_restart_after_host_loss_recovers_through_expired_contact_test_() ->
    {timeout, 90, fun() -> with_recovery_peer(2, fun(Ctx) ->
        #{namespace := Ns, runtime := Runtime, transport := Transport,
          peer := Peer, peer_key := PeerKey, contact := Contact,
          assignments := Assignments, old_host := Old} = Ctx,
        application:set_env(quod, runtime_max_queued_events, 8),
        true = quod_reg:reg({host_test, barrier}),
        true = quod_reg:subscribe({peer_connections, PeerKey}),
        try
            %% The real reaction barrier prevents a takeover racing the planned
            %% runtime restart. It does not stop the transport or its evidence.
            commit(Ns, {trigger_event, pause_batch}),
            receive {host_projection_waiting, _Runner} -> ok
            after 5000 -> error(recovery_barrier_not_reached) end,
            Snapshot = quod_quic:peer_connections(Transport, PeerKey),
            Revision = receive
                {Snapshot, {peer_connections, Transport, R, PeerKey, [_ | _]}} -> R
            after 5000 -> error(no_established_physical_connection) end,
            ok = quod_agent_peer:stop(Peer),
            await_disconnection(Transport, PeerKey, Revision, quod_time:mono_ms() + 5000),
            Sup = quod_reg:where({quod_ns, Ns}),
            ok = supervisor:terminate_child(Sup, quod_runtime),
            ?assertNot(is_process_alive(Runtime)),
            ?assertEqual(Transport, quod_reg:where({transport, node})),
            ok = quod_directory:expire(maps:get(expiry, Contact)),
            ?assertEqual(unknown, quod_directory:node_transport_route(Old)),
            ?assert(quod_directory:node_contact_current(Contact)),
            ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns,
                conjunction([{agent_hosted, I, Old, 1, OldKey}
                             || #{instance := I, old_key := OldKey} <- Assignments]))),
            {ok, NextRuntime} = supervisor:restart_child(Sup, quod_runtime),
            ?assertNotEqual(Runtime, NextRuntime),
            Installed = await_recovered(Ns, NextRuntime, Assignments,
                                         quod_time:mono_ms() + 45000),
            assert_recovered(Ctx, NextRuntime, Installed)
        after
            quod_reg:unsubscribe({peer_connections, PeerKey}),
            gproc:unreg(quod_reg:name({host_test, barrier}))
        end
    end) end}.

with_recovery_peer(Count, Fun) ->
    quod_agent_hosting_tests:with_host(fun(Ctx) ->
        with_transport(Ctx, fun(PeerCtx) ->
            Ready = prepare_assignments(Count, maps:merge(Ctx, PeerCtx)),
            Fun(Ready)
        end)
    end, fun(_Pub) ->
        {ok, Policy} = erlog_io:read_file(filename:join(code:priv_dir(quod),
                                                       "ontologies/agent_recovery_policy.pl")),
        Ns = <<"host-test-agent">>,
        Policy ++
          [{react_on, {agent, {'I'}}, {recovered_work, {'I'}},
            {submit_agent_goal, {'I'}, execute, {record_recovered_work, {'I'}}, 5000}},
           {can_invoke, {record_recovered_work, {'I'}},
            {agent_instance_ref, Ns, {'_'}, {'I'}}, {'_'}, Ns},
           {':-', {record_recovered_work, {'I'}}, {assertz, {recovery_work_done, {'I'}}}}]
    end).

with_transport(#{directory := Dir, identity := Identity, node := Node}, Fun) ->
    Keys = [listen_port, node_addr, identity_cert, runtime_max_queued_events],
    Saved = [{K, application:get_env(quod, K)} || K <- Keys],
    {ok, _} = application:ensure_all_started(quic),
    {ok, Socket} = gen_udp:open(0),
    {ok, Port} = inet:port(Socket),
    ok = gen_udp:close(Socket),
    application:set_env(quod, listen_port, Port),
    application:set_env(quod, node_addr, {"127.0.0.1", Port}),
    application:set_env(quod, identity_cert, maps:get(cert, Identity)),
    {ok, Directory} = quod_directory:start_link(),
    {ok, Transport} = quod_quic:start_link(),
    {Peer, PeerKey, Endpoint} = quod_agent_peer:start(filename:join(Dir, "fanout-peer")),
    Old = setelement(2, Node, <<"remote-node">>),
    try
        {ok, Blob} = quod_wire_term:encode_canonical(Old),
        {ok, _} = quod_directory:install_generation(
            #{author => {node_actor, Blob}, node_key => PeerKey, endpoint => Endpoint,
              epoch => 1, generation => 1, page => 0, last => true,
              hosted => [{element(2, Old), element(3, Old), observer, node}]}),
        {ok, Contact} = quod_directory:node_transport_route(Old),
        Fun(#{peer => Peer, peer_key => PeerKey, transport => Transport,
              old_host => Old, contact => Contact})
    after
        catch quod_agent_peer:stop(Peer),
        gen_server:stop(Transport),
        gen_server:stop(Directory),
        lists:foreach(fun({K, undefined}) -> application:unset_env(quod, K);
                         ({K, {ok, V}}) -> application:set_env(quod, K, V) end, Saved)
    end.

prepare_assignments(Count, Ctx = #{namespace := Ns, node := Node,
                                  reference := {agent_instance_ref, Ns, Anchor, _},
                                  identity := #{pubkey := Pub}, old_host := Old}) ->
    Runtime = quod_reg:where({quod_runtime, Ns}),
    Assignments = [begin
        Ref = {agent_instance_ref, Ns, Anchor, I},
        {ok, Blob} = quod_wire_term:encode_canonical(Ref),
        {ok, Key} = quod_agent_vault:prepare(Blob, 1),
        #{instance => I, reference => Ref, key => Key, old_key => crypto:strong_rand_bytes(32)}
    end || I <- lists:seq(1, Count)],
    Facts = [[{can_assign_agent_host, {node, Pub}, I, none, 0, Old, OldKey},
                          {agent_recovery_observer, I, Node},
                          {agent_recovery_threshold, I, 1},
                          {eligible_agent_host, I, Node}, {agent_host_rank, I, Node, 1},
                          {can_request_agent_signature, Node, I, {'_'}},
                          {agent_domain_state, I, {before_loss, I}}]
                         || #{instance := I, old_key := OldKey} <- Assignments],
    %% Observe actual runtime processing before the assignment commit creates
    %% its subscription. Healthy evidence cannot race ahead of this observer.
    1 = erlang:trace_pattern({quod_agent_observer, handle, 2},
                            [{'_', [], [{return_trace}]}], [local]),
    1 = erlang:trace(Runtime, true, [call]),
    try
        lists:foreach(fun({#{instance := I, old_key := OldKey}, AgentFacts}) ->
            commit(Ns, conjunction([{assertz, F} || F <- AgentFacts] ++
                [{goal, {agent_hosted, I, Old, 1, OldKey}}]))
        end, lists:zip(Assignments, Facts)),
        NodeNs = element(2, Node),
        Report = {report_agent_observation, {'_'}, Old, 1, {'_'}, {'_'}, {'_'}, {'_'}},
        Prepare = {prepare_agent_and_converge, {'_'}, Old, 1, Node, {'_'}},
        commit(NodeNs, conjunction([{assertz, {can_execute_for, Ns, Anchor, G}}
                                    || G <- [Report, Prepare]])),
        lists:foreach(fun(#{instance := I, key := Key}) ->
            Goal = {node_authorized_goal, Ns, Anchor,
                    {prepare_agent_and_converge, I, Old, 1, Node, Key}},
            {ok, Bytes, Signature} = quod_node_actor:signed_goal(execute, Goal,
                crypto:strong_rand_bytes(32), quod_time:now_ms() + 10000),
            ?assertMatch({ok, _, {normalized, {committed, [_], {transaction, Ns, Anchor, _}}}},
                         quod_client_goal_ingress:submit(Bytes, Signature))
        end, Assignments),
        await_healthy_return(Runtime, Old, Count, quod_time:mono_ms() + 10000),
        ok = quod_runtime:await_revision(Ns, agent_observation, quod_prolog:applied(Ns), 10000),
        ?assertMatch(#{mode := live, collapses := 0}, quod_runtime:stats(Ns)),
        Ctx#{runtime => Runtime, assignments => Assignments}
    after
        erlang:trace(Runtime, false, [call]),
        erlang:trace_pattern({quod_agent_observer, handle, 2}, false, [local])
    end.

await_healthy_return(Runtime, Host, Count, Deadline) ->
    receive
        {trace, Runtime, return_from, {quod_agent_observer, handle, 2},
         {#{hosts := Hosts}, _}} ->
            case maps:find(Host, Hosts) of
                {ok, #{instances := Is, delivered := {_, reachable, _}, pending := none}}
                  when map_size(Is) =:= Count -> ok;
                _ -> await_healthy_return(Runtime, Host, Count, Deadline)
            end
    after max(0, Deadline - quod_time:mono_ms()) -> error(no_processed_healthy_observation)
    end.

await_disconnection(Transport, Key, Revision, Deadline) ->
    receive
        {peer_connections, Transport, Next, Key, []} when Next > Revision -> ok;
        {peer_connections, Transport, Next, Key, _} when Next > Revision ->
            await_disconnection(Transport, Key, Next, Deadline)
    after max(0, Deadline - quod_time:mono_ms()) -> error(no_physical_disconnection)
    end.

await_recovered(Ns, Runtime, Assignments, Deadline) ->
    Expected = maps:from_list([{maps:get(reference, A), maps:get(key, A)} || A <- Assignments]),
    await_recovered(Ns, Runtime, Expected, #{}, Deadline).

await_recovered(_Ns, _Runtime, Expected, Installed, _Deadline) when map_size(Expected) =:= 0 ->
    Installed;
await_recovered(Ns, Runtime, Expected, Installed, Deadline) ->
    receive
        {agent_installed, Runtime, Child,
         #{reference := Ref, epoch := 2, public_key := Key}, _Height}
          when is_map_key(Ref, Expected) ->
            ?assertEqual(maps:get(Ref, Expected), Key),
            await_recovered(Ns, Runtime, maps:remove(Ref, Expected), Installed#{Ref => Child}, Deadline)
    after max(0, Deadline - quod_time:mono_ms()) ->
        error({not_all_assignments_recovered, maps:keys(Expected), quod_runtime:stats(Ns)})
    end.

assert_recovered(#{namespace := Ns, node := Node, assignments := Assignments}, Runtime, Installed) ->
    ?assertEqual(Runtime, quod_reg:where({quod_runtime, Ns})),
    ?assertMatch(#{mode := live, collapses := 0, reconcile_failures := 0}, quod_runtime:stats(Ns)),
    ?assert(lists:all(fun erlang:is_process_alive/1, maps:values(Installed))),
    Checks = lists:append([[{agent_hosted, I, Node, 2, Key},
                           {agent_key, I, OldKey, revoked},
                           {agent_domain_state, I, {before_loss, I}}]
                          || #{instance := I, key := Key, old_key := OldKey} <- Assignments]),
    ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, conjunction(Checks))),
    ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns,
        {agent_failure_report, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}})),
    [#{instance := First, reference := Ref} | _] = Assignments,
    Child = maps:get(Ref, Installed),
    true = quod_reg:subscribe({agent, Ref}),
    try
        commit(Ns, {trigger_event, {recovered_work, First}}),
        receive {agent_request_finished, Runtime, Child, _, _, Result} ->
            ?assertMatch({ok, _, {normalized, {committed, [_], _}}}, Result)
        after 10000 -> error(recovered_incarnation_not_executing) end,
        ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {recovery_work_done, First}))
    after quod_reg:unsubscribe({agent, Ref}) end.

commit(Ns, Goal) -> ?assertMatch({ok, _, _}, quod_ct:rp(Ns, Goal)).

conjunction([G]) -> G;
conjunction([G | Rest]) -> {',', G, conjunction(Rest)}.
