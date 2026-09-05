-module(quod_directory_control_tests).
-include_lib("eunit/include/eunit.hrl").

one_generation_wire_rejects_old_shapes_test() ->
    Page = <<1,2,3>>,
    Frame = term_to_binary({quod_directory_generation, Page}, [deterministic]),
    ?assertEqual({generation, Page}, quod_directory_control:decode_control(Frame)),
    ?assertEqual(
       resync_request,
       quod_directory_control:decode_control(
         term_to_binary(quod_directory_generation_resync, [deterministic]))),
    ?assertEqual(
       error,
       quod_directory_control:decode_control(
         term_to_binary({quod_directory_announce, Page}, [deterministic]))),
    ?assertEqual(
       error,
       quod_directory_control:decode_control(
         term_to_binary({quod_directory_snapshot, [Page], done},
                        [deterministic]))).

root_system_and_node_rows_use_separate_authorities_test() ->
    Root = {<<"quod:root">>, key(10), validator, bootstrap},
    System = {<<"quod:system">>, key(11), observer, system},
    Node = {<<"quod:ordinary">>, key(12), validator, node},
    ?assertEqual({[Root, System], [Node]},
                 quod_directory_control:test_partition_hosted(
                   [Root, System, Node])).

multiple_hosted_rows_are_canonicalized_without_crashing_test() ->
    Root = {<<"quod:root">>, key(10), validator, bootstrap},
    System = {<<"quod:node">>, key(11), validator, system},
    %% Manager projection order is semantic-free.  The directory shape owner
    %% returns canonical order, which may differ from the observed order.
    ?assertEqual(
       {ok, lists:sort([Root, System])},
       quod_directory_control:test_validate_described_hosted([Root, System])).

root_peer_proof_is_closed_and_exact_test() ->
    K1 = key(1), K2 = key(2),
    ?assertEqual(
       {ok, 7, #{K1 => true, K2 => true}},
       quod_directory_control:test_validate_peer_proof(
         {ok, [#{'DirectoryControlKeys' => [K1, K2]}], 7})),
    ?assertEqual(
       {error, malformed_peer_keys},
       quod_directory_control:test_validate_peer_proof(
         {ok, [#{'DirectoryControlKeys' => [K1, K1]}], 7})),
    ?assertMatch(
       {error, _},
       quod_directory_control:test_validate_peer_proof({ok, [#{}], 7})).

root_membership_edge_refreshes_a_quiet_control_test() ->
    with_control(fun() ->
        Control = quod_reg:where({directory, control}),
        wait_peer_query_idle(200),
        ?assert(lists:member(
                  Control,
                  gproc:lookup_pids(
                    quod_reg:prop({runtime, <<"quod:root">>})))),
        1 = erlang:trace(Control, true, [procs]),
        try
            %% Unrelated root traffic must not rescan authority.
            _ = quod_reg:publish(
                  {runtime, <<"quod:root">>},
                  {applied_live,
                   #{diff =>
                         [{assert, {{unrelated_root_fact, ok}, true}}]}}),
            receive
                {trace, Control, spawn, _Pid0, _MFA0} -> ?assert(false)
            after 30 -> ok
            end,
            %% This is the exact envelope published after a committed
            %% peer_admitted/4 change. No demand, link event, or tick helps it.
            _ = quod_reg:publish(
                  {runtime, <<"quod:root">>},
                  {applied_live,
                   #{diff =>
                         [{assert,
                           {{peer_admitted, key(201), "host", 14567,
                             key(201)}, true}}]}}),
            receive
                {trace, Control, spawn, Worker, _MFA} when is_pid(Worker) -> ok
            after 500 -> ?assert(false)
            end
        after
            _ = erlang:trace(Control, false, [procs])
        end
    end).

manager_snapshot_is_bound_to_current_pid_and_revision_test() ->
    with_control(fun() ->
        Manager = spawn(fun wait/0),
        Other = spawn(fun wait/0),
        try
            ok = quod_directory_control:test_set_manager_epoch(Manager),
            quod_directory_control:hosting_changed(
              Other, 1, [hosting_row(<<"quod:wrong">>)], []),
            _ = quod_directory_control:stats(),
            S0 = quod_directory_control:test_control_state(),
            ?assertEqual(-1, maps:get(hosting_revision, S0)),
            quod_directory_control:hosting_changed(
              Manager, 2, [hosting_row(<<"quod:right">>)], []),
            _ = quod_directory_control:stats(),
            S1 = quod_directory_control:test_control_state(),
            ?assertEqual(2, maps:get(hosting_revision, S1)),
            ?assertEqual([hosting_row(<<"quod:right">>)],
                         maps:get(hosting_projection, S1))
        after
            Other ! stop, Manager ! stop
        end
    end).

exact_route_demand_is_deduplicated_until_availability_test() ->
    with_directory_and_control(fun() ->
        Owner = self(),
        Link = spawn(fun() -> forwarding_link(Owner) end),
        NodeKey = key(31), Endpoint = {<<"host">>, 14567},
        Identity = {<<"quod:demand">>, key(32)},
        try
            ok = quod_directory_control:test_set_control_link(
                   NodeKey, Endpoint, Link),
            _ = quod_directory_control:stats(),
            drain_link_sends(),
            ok = quod_directory:route_needed(Identity),
            receive
                {directory_link_send, Frame} ->
                    ?assertEqual(
                       resync_request,
                       quod_directory_control:decode_control(Frame))
            after 500 -> ?assert(false)
            end,
            ?assertEqual(
               1, maps:get(route_demands, quod_directory_control:stats())),
            ?assertEqual(
               1, maps:get(route_demanded, quod_directory_control:stats())),
            ok = quod_directory:route_needed(Identity),
            _ = quod_directory_control:stats(),
            receive {directory_link_send, _} -> ?assert(false)
            after 30 -> ok
            end,
            {ok, _} = quod_directory:install_generation(
                        generation(NodeKey, Identity)),
            _ = quod_directory_control:stats(),
            ?assertEqual(
               0, maps:get(route_demands, quod_directory_control:stats())),
            ?assertEqual(
               1, maps:get(route_demanded, quod_directory_control:stats())),
            ?assertEqual(
               1, maps:get(route_wakes, quod_directory_control:stats()))
        after
            Link ! stop
        end
    end).

control_restart_recovers_live_property_demands_test() ->
    with_directory_and_control(fun() ->
        Identity = {<<"quod:restart-demand">>, key(42)},
        Parent = self(),
        Subscriber = spawn(fun() ->
            true = quod_reg:subscribe({directory_route, Identity}),
            Parent ! route_subscribed,
            receive stop -> ok end
        end),
        try
            receive route_subscribed -> ok after 500 -> ?assert(false) end,
            Old = quod_reg:where({directory, control}),
            ok = gen_server:stop(Old),
            {ok, New} = quod_directory_control:start_link(#{}),
            ?assert(is_pid(New)),
            wait_control_demand(Identity, 100),
            ?assertEqual(
               1, maps:get(route_demands, quod_directory_control:stats()))
        after
            Subscriber ! stop
        end
    end).

control_restart_recovers_private_demand_through_host_identity_test() ->
    with_directory_and_control(fun() ->
        HostIdentity = {<<"quod:restart-private-host">>, key(45)},
        TargetIdentity = {<<"quod:restart-private-target">>, key(46)},
        {HostNs, HostAnchor} = HostIdentity,
        {TargetNs, TargetAnchor} = TargetIdentity,
        HostRef = {agent_instance_ref, HostNs, HostAnchor, node_private},
        ok = quod_directory:install_private_projection(
               [#{namespace => TargetNs, anchor => TargetAnchor,
                  host_node_ref => HostRef}]),
        Parent = self(),
        Subscriber = spawn(fun() ->
            true = quod_reg:subscribe({directory_route, TargetIdentity}),
            Parent ! private_route_subscribed,
            receive stop -> ok end
        end),
        try
            receive private_route_subscribed -> ok
            after 500 -> ?assert(false)
            end,
            Old = quod_reg:where({directory, control}),
            ok = gen_server:stop(Old),
            {ok, New} = quod_directory_control:start_link(#{}),
            ?assert(is_pid(New)),
            wait_control_demand(HostIdentity, 100),
            Demands = maps:get(
                        route_demands,
                        quod_directory_control:test_control_state()),
            ?assert(lists:member(HostIdentity, Demands)),
            ?assertNot(lists:member(TargetIdentity, Demands))
        after
            Subscriber ! stop
        end
    end).

directory_restart_preserves_parked_exact_work_until_rebuild_test() ->
    with_directory_and_control(fun() ->
        Identity = {<<"quod:directory-restart-demand">>, key(43)},
        Parent = self(), Ref = make_ref(),
        Waiter = spawn(fun() ->
            Parent !
                {Ref, quod_directory:await_validator_routes(Identity, 2000)}
        end),
        wait_control_demand(Identity, 100),
        OldDirectory = quod_reg:where({directory, node}),
        ok = gen_server:stop(OldDirectory),
        {ok, NewDirectory} = quod_directory:start_link(
                               #{expire_tick_ms => 60000,
                                 ttl_ms => 10000}),
        try
            wait_control_demand(Identity, 100),
            {ok, _} = quod_directory:install_generation(
                        generation(key(41), Identity)),
            receive
                {Ref, {ok, [#{namespace := <<"quod:directory-restart-demand">>}]}} ->
                    ok
            after 1000 -> ?assert(false)
            end,
            ?assertEqual(false, is_process_alive(Waiter))
        after
            catch gen_server:stop(NewDirectory)
        end
    end).

private_target_demand_waits_for_its_host_actor_without_leaking_target_test() ->
    with_directory_and_control(fun() ->
        HostNs = <<"quod:private-host">>, HostAnchor = key(51),
        TargetNs = <<"quod:private-target">>, TargetAnchor = key(52),
        HostRef = {agent_instance_ref, HostNs, HostAnchor, node_private},
        ok = quod_directory:install_private_projection(
               [#{namespace => TargetNs, anchor => TargetAnchor,
                  host_node_ref => HostRef}]),
        ?assertEqual(
           {error, unavailable},
           quod_directory:await_validator_routes(
             {TargetNs, TargetAnchor}, 30)),
        _ = quod_directory_control:stats(),
        State = quod_directory_control:test_control_state(),
        ?assertEqual(
           [{HostNs, HostAnchor}], lists:sort(maps:get(route_demands, State))),
        ?assertNot(lists:member(
                     {TargetNs, TargetAnchor}, maps:get(route_demands, State)))
    end).

lease_renewal_tick_does_not_poll_for_routes_test() ->
    with_directory_and_control(fun() ->
        Owner = self(),
        Link = spawn(fun() -> forwarding_link(Owner) end),
        try
            ok = quod_directory_control:test_set_control_link(
                   key(61), {<<"host">>, 14567}, Link),
            _ = quod_directory_control:stats(),
            drain_link_sends(),
            Control = quod_reg:where({directory, control}),
            Control ! directory_tick,
            _ = quod_directory_control:stats(),
            receive {directory_link_send, _} -> ?assert(false)
            after 30 -> ok
            end
        after
            Link ! stop
        end
    end).

with_control(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    stop_control(),
    {ok, Pid} = quod_directory_control:start_link(#{}),
    try Fun()
    after catch gen_server:stop(Pid) end.

stop_control() ->
    case quod_reg:where({directory, control}) of
        P when is_pid(P) -> catch gen_server:stop(P);
        _ -> ok
    end.

with_directory_and_control(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    stop_control(),
    stop_directory(),
    {ok, Directory} = quod_directory:start_link(
                        #{expire_tick_ms => 60000, ttl_ms => 10000}),
    {ok, Control} = quod_directory_control:start_link(#{}),
    try Fun()
    after
        catch gen_server:stop(Control),
        catch gen_server:stop(Directory),
        stop_control(),
        stop_directory()
    end.

stop_directory() ->
    case quod_reg:where({directory, node}) of
        P when is_pid(P) -> catch gen_server:stop(P);
        _ -> ok
    end.

forwarding_link(Owner) ->
    receive
        {send, Frame} -> Owner ! {directory_link_send, Frame}, forwarding_link(Owner);
        stop -> ok
    end.

drain_link_sends() ->
    receive {directory_link_send, _} -> drain_link_sends()
    after 0 -> ok
    end.

wait_control_demand(_Identity, 0) ->
    error(route_demand_timeout);
wait_control_demand(Identity, Attempts) ->
    case lists:member(
           Identity,
           maps:get(route_demands,
                    quod_directory_control:test_control_state())) of
        true -> ok;
        false ->
            receive after 5 -> ok end,
            wait_control_demand(Identity, Attempts - 1)
    end.

wait_peer_query_idle(0) ->
    error(peer_query_idle_timeout);
wait_peer_query_idle(Attempts) ->
    case maps:get(peer_query, quod_directory_control:test_control_state()) of
        undefined -> ok;
        _ ->
            receive after 5 -> ok end,
            wait_peer_query_idle(Attempts - 1)
    end.

generation(NodeKey, {Ns, Anchor}) ->
    #{author => {root_bootstrap, key(99), NodeKey}, node_key => NodeKey,
      endpoint => {<<"host">>, 14567}, epoch => 1,
      generation => 1, page => 0, last => true,
      hosted => [{Ns, Anchor, validator, bootstrap}]}.

hosting_row(Ns) ->
    #{namespace => Ns, anchor => crypto:hash(sha256, Ns),
      source => node, visibility => discoverable}.

wait() ->
    receive stop -> ok end.

key(N) -> crypto:hash(sha256, term_to_binary({key, N})).
