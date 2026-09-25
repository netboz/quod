-module(quod_directory_tests).
-include_lib("eunit/include/eunit.hrl").

generation_replaces_one_author_atomically_test() ->
    with_directory(fun() ->
        Author = {root_bootstrap, key(90), key(1)},
        A = <<"quod:a">>, B = <<"quod:b">>,
        {ok, _} = quod_directory:install_generation(
                    generation(Author, key(1), 1,
                               [{A, anchor(A), validator, system}])),
        ?assertMatch({known, [_]}, quod_directory:resolve(A)),
        {ok, _} = quod_directory:install_generation(
                    generation(Author, key(1), 2,
                               [{B, anchor(B), validator, system}])),
        ?assertEqual({known, []}, quod_directory:resolve(A)),
        ?assertMatch({known, [_]}, quod_directory:resolve(B))
    end).

endpoint_rollover_replaces_the_old_contact_atomically_test() ->
    with_directory(fun() ->
        Author = {root_bootstrap, key(97), key(9)},
        Ns = <<"quod:rollover">>, Anchor = anchor(Ns),
        Old = {<<"old-host">>, 14567}, New = {<<"new-host">>, 24567},
        {ok, _} = quod_directory:install_generation(
                    generation_at(Author, key(9), Old, 1,
                                  [{Ns, Anchor, validator, system}])),
        {known, [#{endpoint := Old}]} = quod_directory:resolve(Ns),
        {ok, _} = quod_directory:install_generation(
                    generation_at(Author, key(9), New, 2,
                                  [{Ns, Anchor, validator, system}])),
        ?assertMatch({known, [#{endpoint := New}]},
                     quod_directory:resolve(Ns))
    end).

host_move_withdraws_the_old_node_and_keeps_only_the_destination_test() ->
    with_directory(fun() ->
        Ns = <<"quod:moved">>, Anchor = anchor(Ns),
        OldKey = key(10), NewKey = key(11),
        OldAuthor = {root_bootstrap, key(98), OldKey},
        NewAuthor = {root_bootstrap, key(98), NewKey},
        {ok, _} = quod_directory:install_generation(
                    generation(OldAuthor, OldKey, 1,
                               [{Ns, Anchor, validator, system}])),
        {ok, _} = quod_directory:install_generation(
                    generation(NewAuthor, NewKey, 1,
                               [{Ns, Anchor, validator, system}])),
        {known, Both} = quod_directory:resolve(Ns),
        ?assertEqual(lists:sort([OldKey, NewKey]),
                     lists:sort([maps:get(node_key, R) || R <- Both])),
        {ok, _} = quod_directory:install_generation(
                    generation(OldAuthor, OldKey, 2, [])),
        ?assertMatch({known, [#{node_key := NewKey}]},
                     quod_directory:resolve(Ns))
    end).

empty_generation_withdraws_every_route_from_its_author_test() ->
    with_directory(fun() ->
        Author = {root_bootstrap, key(94), key(6)},
        Ns = <<"quod:withdrawn">>,
        {ok, _} = quod_directory:install_generation(
                    generation(Author, key(6), 1,
                               [{Ns, anchor(Ns), validator, system}])),
        ?assertMatch({known, [_]}, quod_directory:resolve(Ns)),
        {ok, _} = quod_directory:install_generation(
                    generation(Author, key(6), 2, [])),
        ?assertEqual({known, []}, quod_directory:resolve(Ns))
    end).

withdrawal_retains_the_exact_known_identity_test() ->
    with_directory(fun() ->
        Author = {root_bootstrap, key(95), key(7)},
        Ns = <<"quod:known-after-withdrawal">>, Anchor = anchor(Ns),
        {ok, _} = quod_directory:install_generation(
                    generation(Author, key(7), 1,
                               [{Ns, Anchor, validator, system}])),
        {ok, _} = quod_directory:install_generation(
                    generation(Author, key(7), 2, [])),
        ?assertEqual({known, []}, quod_directory:resolve(Ns)),
        ?assertEqual([{Ns, Anchor}], quod_directory:known_identities(Ns))
    end).

exact_route_wait_is_woken_by_the_directory_transition_test() ->
    with_directory(fun() ->
        Ns = <<"quod:demanded">>, Anchor = anchor(Ns),
        Identity = {Ns, Anchor}, Parent = self(), Ref = make_ref(),
        Waiter = spawn(fun() ->
            Parent ! {Ref, quod_directory:await_validator_routes(Identity, 1000)}
        end),
        wait_for_route_subscription(Identity, Waiter, 100),
        {ok, _} = quod_directory:install_generation(
                    generation({root_bootstrap, key(96), key(8)}, key(8), 1,
                               [{Ns, Anchor, validator, system}])),
        receive
            {Ref, {ok, [#{genesis_anchor := Anchor}]}} -> ok
        after 1000 ->
            ?assert(false)
        end
    end).

exact_target_wait_prefers_the_installed_local_identity_test() ->
    with_directory(fun() ->
        Ns = <<"quod:local-target">>, Anchor = anchor(Ns),
        Identity = {Ns, Anchor}, State = atomics:new(1, []),
        LocalStatus = fun() ->
            case atomics:get(State, 1) of 1 -> ready; _ -> waiting end
        end,
        Parent = self(), Ref = make_ref(),
        Waiter = spawn(fun() ->
            Parent ! {Ref, quod_directory:await_validator_target(
                             Identity, LocalStatus, 1000)}
        end),
        wait_for_route_subscription(Identity, Waiter, 100),
        ?assert(lists:member(Waiter, gproc:lookup_pids(
                  quod_reg:prop({runtime, Ns})))),
        %% A stale incarnation's ready edge never releases the exact wait.
        quod_reg:publish({runtime, Ns},
                         {proof_ready, {Ns, <<0:256>>}, self()}),
        receive {Ref, _} -> ?assert(false) after 20 -> ok end,
        atomics:put(State, 1, 1),
        quod_reg:publish({runtime, Ns},
                         {proof_ready, Identity, self()}),
        receive {Ref, {ok, local}} -> ok
        after 1000 -> ?assert(false)
        end,
        ?assertNot(lists:member(Waiter, gproc:lookup_pids(
                     quod_reg:prop({runtime, Ns})))),
        ?assertNot(lists:member(Waiter, gproc:lookup_pids(
                     quod_reg:prop({directory_route, Identity}))))
    end).

stale_generation_cannot_restore_a_route_test() ->
    with_directory(fun() ->
        Author = {root_bootstrap, key(91), key(2)}, Ns = <<"quod:stale">>,
        {ok, _} = quod_directory:install_generation(
                    generation(Author, key(2), 2, [])),
        ?assertEqual(
           {error, stale_generation},
           quod_directory:install_generation(
             generation(Author, key(2), 1,
                        [{Ns, anchor(Ns), validator, system}]))),
        ?assertEqual(unknown, quod_directory:resolve(Ns))
    end).

root_hosts_have_distinct_generation_owners_test() ->
    with_directory(fun() ->
        Ns = <<"quod:root">>, Anchor = anchor(Ns),
        {ok, _} = quod_directory:install_generation(
                    generation({root_bootstrap, Anchor, key(21)}, key(21), 1,
                               [{Ns, Anchor, validator, bootstrap}])),
        {ok, _} = quod_directory:install_generation(
                    generation({root_bootstrap, Anchor, key(22)}, key(22), 1,
                               [{Ns, Anchor, validator, bootstrap}])),
        {known, Routes} = quod_directory:resolve(Ns),
        ?assertEqual([key(21), key(22)],
                     lists:sort([maps:get(node_key, R) || R <- Routes]))
    end).

generation_population_is_not_capped_test() ->
    with_directory(fun() ->
        Rows = [{iolist_to_binary([<<"quod:n-">>, integer_to_binary(I)]),
                 key(I), validator, system} || I <- lists:seq(1, 1200)],
        {ok, _} = quod_directory:install_generation(
                    generation({root_bootstrap, key(92), key(3)}, key(3), 1, Rows)),
        ?assertEqual(1200, maps:get(routes, quod_directory:stats()))
    end).

private_projection_uses_current_host_actor_route_test() ->
    with_directory(fun() ->
        HostNs = <<"quod:node-host">>, HostAnchor = anchor(HostNs),
        Target = <<"quod:private">>, TargetAnchor = anchor(Target),
        HostRef = {agent_instance_ref, HostNs, HostAnchor, node_one},
        {ok, _} = quod_directory:install_generation(
                    generation({root_bootstrap, key(93), key(4)}, key(4), 1,
                               [{HostNs, HostAnchor, validator, system}])),
        ok = quod_directory:install_private_projection(
               [#{namespace => Target, anchor => TargetAnchor,
                  host_node_ref => HostRef}]),
        {known, [Route]} = quod_directory:resolve(Target),
        ?assertEqual(private, maps:get(scope, Route)),
        ?assertEqual(key(4), maps:get(node_key, Route)),
        ?assertEqual(TargetAnchor, maps:get(genesis_anchor, Route)),
        ?assertEqual([], quod_directory:directory_hosts(Target))
    end).

private_projection_wakes_when_its_host_actor_becomes_reachable_test() ->
    with_directory(fun() ->
        HostNs = <<"quod:node-later">>, HostAnchor = anchor(HostNs),
        Target = <<"quod:private-later">>, TargetAnchor = anchor(Target),
        HostRef = {agent_instance_ref, HostNs, HostAnchor, node_later},
        true = quod_reg:subscribe(
                 {directory_route, {Target, TargetAnchor}}),
        ok = quod_directory:install_private_projection(
               [#{namespace => Target, anchor => TargetAnchor,
                  host_node_ref => HostRef}]),
        ?assertEqual({known, []}, quod_directory:resolve(Target)),
        receive {directory_route_available, {Target, TargetAnchor}} ->
            ?assert(false)
        after 20 -> ok
        end,
        {ok, EncodedRef} = quod_wire_term:encode_canonical(HostRef),
        {ok, _} = quod_directory:install_generation(
                    generation({node_actor, EncodedRef}, key(5), 1,
                               [{HostNs, HostAnchor, validator, node}])),
        receive {directory_route_available, {Target, TargetAnchor}} -> ok
        after 100 -> ?assert(false)
        end,
        ?assertMatch({known, [_]}, quod_directory:resolve(Target)),
        true = quod_reg:unsubscribe(
                 {directory_route, {Target, TargetAnchor}})
    end).

node_transport_requires_exact_author_test() ->
    with_directory(fun() ->
        Ns = <<"quod:physical-node">>, Anchor = anchor(Ns),
        Ref = {agent_instance_ref, Ns, Anchor, physical_node},
        {ok, Blob} = quod_wire_term:encode_canonical(Ref),
        Author = {node_actor, Blob},
        Owner = quod_reg:where({directory, node}),
        true = quod_reg:subscribe_tracked({node_identity_route, Ref}),
        %% A valid replica route says nothing about the physical actor's key.
        {ok, _} = quod_directory:install_generation(
                    generation({root_bootstrap, key(99), key(8)}, key(8), 1,
                               [{Ns, Anchor, validator, system}])),
        ?assertEqual(unknown, quod_directory:node_transport_route(Ref)),
        %% The node's own ontology may be private. Any nonempty generation
        %% signed by that exact actor certifies its physical contact; the
        %% advertised ontology is not the identity being monitored.
        HostedNs = <<"public:hosted-by-physical-node">>,
        {ok, Expiry} = quod_directory:install_generation(
                    generation(Author, key(5), 1,
                               [{HostedNs, anchor(HostedNs), observer, node}])),
        receive {node_identity_route_changed, Owner, Ref} -> ok
        after 1000 -> error(missing_identity_notice)
        end,
        ?assertMatch({ok, #{owner := Owner, node_key := _, generation := 1}},
                     quod_directory:node_transport_route(Ref)),
        {ok, #{node_key := Key} = Retained} = quod_directory:node_transport_route(Ref),
        ?assertEqual(key(5), Key),
        ?assert(quod_directory:node_contact_current(Retained)),
        ok = quod_directory:expire(Expiry),
        receive {node_identity_route_changed, Owner, Ref} -> ok
        after 1000 -> error(missing_expiry_notice)
        end,
        ?assertEqual(unknown, quod_directory:node_transport_route(Ref)),
        ?assert(quod_directory:node_contact_current(Retained)),
        {ok, _} = quod_directory:install_generation(
                    generation(Author, key(6), 2,
                               [{Ns, Anchor, observer, node}])),
        receive {node_identity_route_changed, Owner, Ref} -> ok
        after 1000 -> error(missing_replacement_notice)
        end,
        ?assertNot(quod_directory:node_contact_current(Retained)),
        {ok, #{node_key := NewKey, generation := 2} = Current} =
            quod_directory:node_transport_route(Ref),
        ?assertEqual(key(6), NewKey),
        {ok, _} = quod_directory:install_generation(
                    generation(Author, key(6), 3, [])),
        receive {node_identity_route_changed, Owner, Ref} -> ok
        after 1000 -> error(missing_withdrawal_notice)
        end,
        ?assertEqual(unknown, quod_directory:node_transport_route(Ref)),
        ?assertNot(quod_directory:node_contact_current(Current)),
        true = quod_reg:unsubscribe_tracked({node_identity_route, Ref})
    end).

with_directory(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    stop_directory(),
    {ok, Pid} = quod_directory:start_link(
                  #{expire_tick_ms => 60000, ttl_ms => 10000}),
    try Fun()
    after catch gen_server:stop(Pid) end.

stop_directory() ->
    case quod_reg:where({directory, node}) of
        P when is_pid(P) -> catch gen_server:stop(P);
        _ -> ok
    end.

wait_for_route_subscription(_Identity, _Pid, 0) ->
    error(route_subscription_timeout);
wait_for_route_subscription(Identity, Pid, Attempts) ->
    case lists:member(
           Pid, gproc:lookup_pids(quod_reg:prop({directory_route, Identity}))) of
        true -> ok;
        false ->
            receive after 5 -> ok end,
            wait_for_route_subscription(Identity, Pid, Attempts - 1)
    end.

generation(Author, NodeKey, Number, Hosted) ->
    generation_at(Author, NodeKey, {<<"host">>, 14567}, Number, Hosted).

generation_at(Author, NodeKey, Endpoint, Number, Hosted) ->
    #{author => Author, node_key => NodeKey,
      endpoint => Endpoint, epoch => 1,
      generation => Number, page => 0, last => true,
      hosted => lists:sort(Hosted)}.

anchor(Ns) -> crypto:hash(sha256, Ns).
key(N) -> crypto:hash(sha256, term_to_binary({key, N})).
