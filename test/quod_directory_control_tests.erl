-module(quod_directory_control_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

renewals_reuse_certified_projection_test_() ->
    {timeout, 30, fun() -> with_node_generation(fun(F, Control, Owner) ->
        trace_projection_work(Owner, true),
        try
            Prime = prime_node_projection(F),
            submit_node_generation(F, Control, 1),
            await_generation(F, 1),
            ok = quod_foreign_log:unfollow(Prime),
            First = projection_work(),
            ?assertEqual(257, count_work(quod_committed_projection, First)),
            ?assert(count_work(dets, First) > 0),
            submit_node_generation(F, Control, 2),
            await_generation(F, 2),
            Repeat = projection_work(),
            ?assertEqual(#{replayed => 0, syncs => 0},
                         #{replayed => count_work(quod_committed_projection, Repeat),
                           syncs => count_work(dets, Repeat)}),
            ?assertMatch(#{projection_rebuilds := 1, projection_workers := 1},
                         quod_foreign_log:stats())
        after trace_projection_work(Owner, false)
        end
    end) end}.

cold_generation_waits_for_certified_height_test_() ->
    {timeout, 30, fun() -> with_node_generation(fun(F, Control, Owner) ->
        trace_projection_work(Owner, true),
        try
            submit_node_generation(F, Control, 1),
            await_generation(F, 1),
            ?assertEqual(257, count_work(quod_committed_projection, projection_work()))
        after trace_projection_work(Owner, false)
        end
    end) end}.

expired_generation_releases_projection_test_() ->
    {timeout, 30, fun() -> with_node_generation(fun(F, Control, _Owner) ->
        submit_node_generation(F, Control, 1),
        await_generation(F, 1),
        ?assertMatch(#{follow_consumers := 1, projection_workers := 1}, quod_foreign_log:stats()),
        ok = quod_directory_control:test_expire_generations(),
        await_control(fun(#{generations := G, follow_requests := R}) ->
            map_size(G) =:= 0 andalso R =:= 0
        end),
        ?assertMatch(#{follow_consumers := 0, projection_workers := 0}, quod_foreign_log:stats())
    end) end}.

cancelled_projection_handoff_is_released_test_() ->
    [{atom_to_list(Case), {timeout, 30, fun() ->
        with_node_generation(fun(F, Control, Owner) ->
            hold_generation_handoff(Control),
            submit_node_generation(F, Control, 1),
            {Token, Worker} = receive
                {projection_handoff, T, W} -> {T, W}
            after 10000 -> error(handoff_not_reached)
            end,
            ok = sys:suspend(Owner),
            try
                Control ! {release_handoff, Token},
                await_control(fun(#{follow_requests := N}) -> N =:= 1 end),
                case Case of
                    worker_down -> exit(Worker, kill);
                    superseded -> submit_node_generation(F, Control, 2);
                    owner_down -> unlink(Owner), exit(Owner, kill)
                end,
                await_control(fun(#{validations := V}) ->
                    lists:all(fun(#{pid := P}) -> P =/= Worker end, maps:values(V))
                end)
            after catch sys:resume(Owner)
            end,
            case Case of
                Cancelled when Cancelled =:= worker_down; Cancelled =:= owner_down ->
                    await_control(fun(#{validations := V, follow_requests := R}) ->
                        map_size(V) =:= 0 andalso R =:= 0
                    end),
                    ?assertMatch(#{follow_consumers := 0, projection_workers := 0},
                                 quod_foreign_log:stats());
                superseded ->
                    await_generation(F, 2),
                    await_control(fun(#{follow_requests := R}) -> R =:= 0 end),
                    ?assertMatch(#{follow_consumers := 1, projection_workers := 1},
                                 quod_foreign_log:stats())
            end
        end)
    end}} || Case <- [worker_down, superseded, owner_down]].

lease_expiry_during_validation_keeps_live_demand_test_() ->
    {timeout, 30, fun() -> with_node_generation(fun(F, Control, _Owner) ->
        submit_node_generation(F, Control, 1),
        await_generation(F, 1),
        hold_generation_handoff(Control),
        submit_node_generation(F, Control, 2),
        {Token, Worker} = receive {projection_handoff, T, W} -> {T, W}
                         after 10000 -> error(handoff_not_reached)
                         end,
        true = erlang:suspend_process(Worker),
        try
            Control ! {release_handoff, Token},
            await_control(fun(#{validations := V}) ->
                lists:any(fun(E) -> maps:is_key(projection, E) end, maps:values(V))
            end),
            ok = quod_directory_control:test_expire_generations(),
            ?assertMatch(#{follow_consumers := 2, projection_workers := 1,
                           projection_rebuilds := 1}, quod_foreign_log:stats())
        after erlang:resume_process(Worker)
        end,
        await_generation(F, 2),
        ?assertMatch(#{follow_consumers := 1, projection_workers := 1,
                       projection_rebuilds := 1}, quod_foreign_log:stats())
    end) end}.

projection_handoff_keeps_original_deadline_test_() ->
    {timeout, 30, fun() -> with_node_generation(fun(F, Control, Owner) ->
        hold_generation_handoff(Control),
        observe_validation_results(Control),
        submit_node_generation(F, Control, 1),
        Token = receive {projection_handoff, T, _Worker} -> T
                after 10000 -> error(handoff_not_reached)
                end,
        ok = sys:suspend(Owner),
        try
            Control ! {release_handoff, Token},
            State = await_control(fun(#{follow_requests := N}) -> N =:= 1 end),
            #{projection_deadline := Deadline} =
                maps:get(maps:get(author, F), maps:get(validations, State)),
            %% Wait for the real timeout result, including the existing
            %% bounded unfollow cleanup. Registration gets no new allowance.
            receive {validation_finished, Result} ->
                ?assertEqual({error, validation_timeout}, Result)
            after max(0, Deadline - quod_time:mono_ms()) + 2000 ->
                error(validation_deadline_extended)
            end,
            ?assertMatch(#{generations := G, validations := V}
                           when map_size(G) =:= 0 andalso map_size(V) =:= 0,
                         quod_directory_control:test_control_state())
        after sys:resume(Owner)
        end,
        await_control(fun(#{follow_requests := N}) -> N =:= 0 end),
        await_foreign_consumers(0)
    end) end}.

foreign_owner_restart_replaces_retained_follow_test_() ->
    {timeout, 30, fun() -> with_node_generation(fun(F, Control, Owner) ->
        submit_node_generation(F, Control, 1),
        First = await_generation(F, 1),
        Author = maps:get(author, F),
        #{projection := {Owner, OldRef}} = maps:get(Author, maps:get(generations, First)),
        quod_foreign_log_tests:stop_owner(Owner),
        Replacement = quod_foreign_log_tests:start_owner(maps:get(ledger_dir, F), maps:get(fetch, F)),
        try
            submit_node_generation(F, Control, 2),
            Next = await_generation(F, 2),
            #{projection := {Replacement, NewRef}} = maps:get(Author, maps:get(generations, Next)),
            ?assertNotEqual(OldRef, NewRef),
            ?assertMatch(#{follow_consumers := 1, projection_workers := 1}, quod_foreign_log:stats()),
            gen_server:stop(Control),
            await_foreign_consumers(0)
        after quod_foreign_log_tests:stop_owner(Replacement)
        end
    end) end}.

new_tip_revocation_refuses_renewal_test_() ->
    {timeout, 30, fun() -> with_node_generation(fun(F, Control, Owner) ->
        submit_node_generation(F, Control, 1),
        First = await_generation(F, 1),
        Author = maps:get(author, F),
        #{projection := {Owner, Ref}} = maps:get(Author, maps:get(generations, First)),
        {ok, Materializer, _} = gen_server:call(Owner, {projection_handle, Ref, Control}),
        Identity = {Ns, _} = maps:get(identity, F),
        Pub = maps:get(pubkey, maps:get(signer, F)),
        {ok, LastBlock} = quod_ledger:block_from_entry(lists:last(maps:get(chain, F))),
        Withdraw = node_history_entry(F, 258, quod_ledger:block_ref(LastBlock),
                     [{retract, {{agent_key, directory_node, Pub, active}, true}}]),
        true = ets:insert(maps:get(source, F), {chain, maps:get(chain, F) ++ [Withdraw]}),
        true = erlang:suspend_process(Materializer),
        observe_validation_results(Control),
        1 = erlang:trace_pattern({quod_directory_control, projection_notice, 2},
                                [{'_', [], [{return_trace}]}], [local]),
        1 = erlang:trace(Control, true, [call, set_on_spawn, {tracer, self()}]),
        trace_projection_work(Materializer, true),
        try
            Owner ! {quod_message, {Pub, self()}, quod_feed:channel(Ns),
                     quod_feed:encode(Ns, {digest, 258})},
            ?assertMatch({ok, #{slot := 258}}, quod_foreign_log:current(
                [{Pub, [{<<"127.0.0.1">>, 19000}]}], Identity, 5000)),
            submit_node_generation(F, Control, 2),
            receive
                {trace, _Worker, return_from,
                 {quod_directory_control, projection_notice, 2}, pending} -> ok
            after 5000 -> error(lagging_projection_not_parked)
            end,
            %% The certified tip includes revocation, while the paused
            %% materializer still has the old key. That cannot renew a lease.
            Still = quod_directory_control:test_control_state(),
            ?assert(maps:is_key(Author, maps:get(validations, Still))),
            ?assertEqual(maps:get(generations, First), maps:get(generations, Still)),
            true = erlang:resume_process(Materializer),
            receive {validation_finished, Result} ->
                ?assertEqual({error, unauthorized_generation}, Result)
            after 5000 -> error(revocation_not_validated)
            end,
            Final = await_control(fun(#{validations := V}) -> map_size(V) =:= 0 end),
            ?assertEqual(maps:get(generations, First), maps:get(generations, Final)),
            ?assertEqual(1, count_work(quod_committed_projection, projection_work())),
            ?assertMatch(#{projection_rebuilds := 1, follow_consumers := 1}, quod_foreign_log:stats())
        after
            catch erlang:resume_process(Materializer),
            trace_projection_work(Materializer, false),
            _ = erlang:trace(Control, false, [call, set_on_spawn]),
            _ = erlang:trace_pattern({quod_directory_control, projection_notice, 2}, false, [local])
        end
    end) end}.

hold_generation_handoff(Control) ->
    Parent = self(),
    Gate = fun(armed, {in, {directory_projection_verified, Token, Pid, _, _, _}}, _) ->
                   Parent ! {projection_handoff, Token, Pid},
                   receive {release_handoff, Token} -> done
                   after 10000 -> error(handoff_gate_not_released)
                   end;
              (State, _Event, _) -> State
           end,
    ok = sys:install(Control, {Gate, armed}).

observe_validation_results(Control) ->
    Parent = self(),
    Observer = fun(State, {in, {directory_generation_validated, _, Result}}, _) ->
                       Parent ! {validation_finished, Result}, State;
                  (State, _, _) -> State
               end,
    ok = sys:install(Control, {Observer, observing}).

await_foreign_consumers(Expected) ->
    await_foreign_consumers(Expected, quod_time:mono_ms() + 10000).
await_foreign_consumers(Expected, Deadline) ->
    case quod_foreign_log:stats() of
        #{follow_consumers := Expected} -> ok;
        _ ->
            ?assert(quod_time:mono_ms() < Deadline),
            await_foreign_consumers(Expected, Deadline)
    end.

%% Real signatures, catalogue proof, current-tip verification, materializer,
%% generation validation and directory installation. Only network delivery is
%% replaced by the existing signed-history source fixture.
with_node_generation(Fun) ->
    F = node_generation_fixture(257),
    {Ns, _Anchor} = maps:get(identity, F),
    Dir = quod_foreign_log_tests:temp_dir("directory-projection"),
    Source = ets:new(directory_source, [set, public]),
    true = ets:insert(Source, {chain, maps:get(chain, F)}),
    Fetch = fun(P, E, N, Query, Deadline, Consume) ->
        [{chain, Chain}] = ets:lookup(Source, chain),
        Read = quod_foreign_log_tests:chain_fetch(Ns, Chain),
        Read(P, E, N, Query, Deadline, Consume)
    end,
    try quod_ct:with_network_identity(key(254), fun() ->
        with_directory_and_control(fun() ->
            %% The proof gate is owned by the same named table as a real root.
            RootTable = ets:new('quod_simplex_genesis_quod:root', [named_table, set]),
            Signer = maps:get(signer, F), Pub = maps:get(pubkey, Signer),
            true = ets:insert(RootTable,
                [{anchor, key(254)}, {proof_gate, true, 1, [], Pub, [Pub], key(2), #{}}]),
            {ok, Root} = quod_prolog:start_link(<<"quod:root">>,
                #{node_id => Pub, identity => Signer, outcome_backend => memory}),
            Genesis = quod_simplex:test_genesis_tx(
                #{mode => create, node_id => Pub, committee => [],
                  external_predicate_modules => [],
                  genesis_diff => quod_prolog:terms_to_diff(
                    [{can_invoke, {'_'}, {'_'}, {'_'}, {'_'}}])},
                <<"quod:root">>, Pub, key(3)),
            ok = quod_prolog:apply_entry(<<"quod:root">>,
                quod_ct:committed_entry(<<"quod:root">>, 1, {batch, [Genesis]}), live),
            ok = quod_prolog:mark_ready(<<"quod:root">>),
            Owner = quod_foreign_log_tests:start_owner(Dir, Fetch),
            try
                ?assertMatch({ok, _, [], #{}}, quod_system_ontology:catalog()),
                Fun(F#{source => Source, fetch => Fetch, ledger_dir => Dir},
                    quod_reg:where({directory, control}), Owner)
            after
                quod_foreign_log_tests:stop_owner(Owner),
                gen_server:stop(Root),
                ets:delete(RootTable)
            end
        end)
    end)
    after ets:delete(Source), _ = file:del_dir_r(Dir)
    end.

node_generation_fixture(Height) ->
    F = quod_ct:protocol_fixture(quod_foreign_log_tests:unique_ns()),
    {Ns, Anchor} = maps:get(identity, F),
    Signer = maps:get(signer, F), Pub = maps:get(pubkey, Signer),
    Instance = directory_node,
    NodeRef = {agent_instance_ref, Ns, Anchor, Instance},
    {ok, Blob} = quod_wire_term:encode_canonical(NodeRef),
    {Entries, _} = lists:mapfoldl(fun(H, Parent) ->
        Terms = case H of
            2 -> [{agent_key, Instance, Pub, active},
                  {hosts_ontology, NodeRef, Ns, Anchor, discoverable}];
            _ -> [{directory_history, H}]
        end,
        Entry = node_history_entry(F, H, Parent, quod_prolog:terms_to_diff(Terms)),
        {ok, Block} = quod_ledger:block_from_entry(Entry),
        {Entry, quod_ledger:block_ref(Block)}
    end, maps:get(protocol_root, maps:get(projection, F)), lists:seq(2, Height)),
    F#{author => {node_actor, Blob},
       chain => [quod_ledger:entry(1, maps:get(genesis, F), none) | Entries]}.

node_history_entry(F, H, Parent, Diff) ->
    {Ns, Anchor} = Identity = maps:get(identity, F),
    Template = maps:get(transaction, F),
    Tx0 = Template#transaction{diff = Diff, author_seq = H - 1,
          submitted_at = H, sig = none, signed_bytes = none, authentication = none},
    {ok, Tx} = quod_transaction:sign({Ns, Anchor, maps:get(admission, F)},
        quod_transaction:bind_id(Identity, Tx0), maps:get(signer, F)),
    {ok, Block} = quod_ledger:new_block({maps:get(era, F), H - 1}, Parent,
                                      H, {batch, [Tx]}, H),
    quod_ledger:entry(H, Block, quod_ct:protocol_certificate(Block, F)).

submit_node_generation(F, Control, Number) ->
    {Ns, Anchor} = maps:get(identity, F),
    Signer = maps:get(signer, F), Pub = maps:get(pubkey, Signer),
    Endpoint = {<<"127.0.0.1">>, 19000},
    {ok, Page} = quod_directory_generation:sign(
        maps:get(author, F), Pub, Endpoint, 1, Number, 0, true,
        [{Ns, Anchor, validator, node}], maps:get(key, Signer)),
    Control ! {quod_message, {{Pub, Endpoint}, self()},
               quod_directory_control:channel(),
               term_to_binary({quod_directory_generation, Page}, [deterministic])}.

await_generation(F, Number) ->
    Author = maps:get(author, F),
    await_control(fun(#{generations := Generations, validations := Validations}) ->
        case {maps:find(Author, Generations), maps:is_key(Author, Validations)} of
            {{ok, #{pages := [Page]}}, false} ->
                {ok, Decoded} = quod_directory_generation:decode(Page),
                quod_directory_generation:generation(Decoded) =:= Number;
            _ -> false
        end
    end).

await_control(Predicate) -> await_control(Predicate, quod_time:mono_ms() + 10000).
await_control(Predicate, Deadline) ->
    State = quod_directory_control:test_control_state(),
    case Predicate(State) of
        true -> State;
        false ->
            ?assert(quod_time:mono_ms() < Deadline),
            await_control(Predicate, Deadline)
    end.

trace_projection_work(Owner, Enabled) ->
    lists:foreach(fun({Module, _, _} = MFA) ->
        {module, Module} = code:ensure_loaded(Module),
        1 = erlang:trace_pattern(MFA, Enabled, [local])
    end, [{quod_committed_projection, apply_entry, 3}, {dets, sync, 1}]),
    _ = erlang:trace(Owner, Enabled, [call, set_on_spawn, {tracer, self()}]),
    ok.

projection_work() ->
    Ref = erlang:trace_delivered(all),
    receive {trace_delivered, all, Ref} -> ok after 1000 -> error(trace_timeout) end,
    projection_work([]).
projection_work(Acc) ->
    receive
        {trace, _Pid, call, {Module, Function, _Args}}
          when Module =:= quod_committed_projection; Module =:= dets ->
            projection_work([{Module, Function} | Acc])
    after 0 -> lists:reverse(Acc)
    end.

count_work(Module, Calls) -> length([ok || {M, _} <- Calls, M =:= Module]).

prime_node_projection(F) ->
    Identity = maps:get(identity, F),
    Pub = maps:get(pubkey, maps:get(signer, F)),
    ok = quod_foreign_log:observe_candidate(Identity, {Pub, {<<"127.0.0.1">>, 19000}}),
    {ok, Ref} = quod_foreign_log:follow(Identity, projection),
    await_projection(Ref, Identity, length(maps:get(chain, F))),
    Ref.

await_projection(Ref, Identity, Minimum) ->
    receive
        {quod_foreign_follow, Ref, NoticeRef, Identity, Notice} ->
            ok = quod_foreign_log:ack(Ref, NoticeRef),
            case Notice of
                {resnapshot, H, _, _} when H >= Minimum -> ok;
                {advanced, _, H, _, _, _, _} when H >= Minimum -> ok;
                {unreachable, Reason, _} -> error({projection_unreachable, Reason});
                _ -> await_projection(Ref, Identity, Minimum)
            end
    after 10000 -> error(projection_timeout)
    end.

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
