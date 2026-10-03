-module(quod_recovery_handoff_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

compact_evidence_retains_contact_generation_fence_test() ->
    with_evidence(fun(#{batch := Batch, contact := Contact, generation := Generation}) ->
        Evidence = maps:without([bindings], Batch),
        ?assert(quod_agent_observer:evidence_current(Evidence)),
        %% Lease expiry does not invalidate an already authenticated monitor.
        ok = quod_directory:expire(maps:get(expiry, Contact)),
        ?assert(quod_agent_observer:evidence_current(Evidence)),
        {ok, _} = quod_directory:install_generation(Generation#{generation => 2}),
        ?assertNot(quod_agent_observer:evidence_current(Evidence))
    end).

compact_evidence_retains_transport_incarnation_fence_test() ->
    with_evidence(fun(#{batch := Batch}) ->
        Evidence = maps:without([bindings], Batch),
        true = gproc:unreg(quod_reg:name({transport, node})),
        Parent = self(),
        {Replacement, Ref} = spawn_monitor(fun() ->
            true = quod_reg:reg({transport, node}),
            Parent ! {transport_installed, self()},
            receive stop -> ok end
        end),
        try
            receive {transport_installed, Replacement} -> ok
            after 1000 -> error(transport_not_installed) end,
            ?assert(is_process_alive(maps:get(transport, Evidence))),
            ?assertNot(quod_agent_observer:evidence_current(Evidence))
        after
            Replacement ! stop,
            receive {'DOWN', Ref, process, Replacement, _} -> ok
            after 1000 -> error(transport_not_stopped) end
        end
    end).

bootstrap_retains_owned_evidence_under_original_bounds_test() ->
    with_evidence(fun(#{batch := Batch}) ->
        Node = maps:get(observer, Batch), NodeNs = element(2, Node),
        SourceNs = <<"handoff-source">>, Anchor = <<81:256>>,
        Saved = application:get_env(quod, node_actor_principal),
        {ok, Blob} = quod_wire_term:encode_canonical(Node),
        application:set_env(quod, node_actor_principal, {agent, Blob}),
        true = quod_reg:reg({quod_runtime, SourceNs}),
        {ok, Runtime} = quod_runtime:start_link(NodeNs, #{node_id => <<82:256>>}),
        Token = make_ref(), Expiry = quod_time:now_ms() + 60000,
        Metadata = #{target => {agent_instance_ref, SourceNs, Anchor, actor},
                     epoch => 1, observer => Node, deadline => quod_time:mono_ms() + 5000,
                     evidence => maps:without([bindings], Batch)},
        try
            ?assertMatch(#{mode := booting, queue_len := 0}, quod_runtime:stats(NodeNs)),
            Runtime ! {owned_recovery, self(), {SourceNs, Anchor}, Token, event, Metadata, Expiry},
            ?assertMatch(#{mode := booting, queue_len := 1}, quod_runtime:stats(NodeNs)),
            quod_runtime:reconcile_now(NodeNs),
            ?assertMatch(#{mode := booting, queue_len := 1}, quod_runtime:stats(NodeNs)),
            %% A generous wall-clock expiry cannot renew the monotonic bound.
            Stale = make_ref(),
            Runtime ! {owned_recovery, self(), {SourceNs, Anchor}, Stale, event,
                       Metadata#{deadline => quod_time:mono_ms() - 1}, Expiry},
            receive {recovery_consumed, Runtime, Stale} -> ok
            after 1000 -> error(expired_receipt_not_released) end,
            ?assertMatch(#{queue_len := 1}, quod_runtime:stats(NodeNs))
        after
            gen_server:stop(Runtime),
            true = gproc:unreg(quod_reg:name({quod_runtime, SourceNs})),
            restore(node_actor_principal, Saved)
        end,
        receive {recovery_consumed, Runtime, Token} -> ok
        after 1000 -> error(stopped_owner_did_not_release_receipt) end
    end).

consumption_and_reset_cancel_receipt_deadline_test_() ->
    [?_test(with_pending(fun(Pending = {Owner, Token, _, Timer}) ->
        Message = case Action of consumed -> {recovery_consumed, Owner, Token}; reset -> reset end,
        ?assertEqual(none, quod_runtime:test_recovery_pending(Pending, Message)),
        ?assertEqual(false, erlang:read_timer(Timer)),
        ?assertNot(lists:member({process, Owner}, element(2, process_info(self(), monitors))))
    end)) || Action <- [consumed, reset]].

owner_death_cancels_receipt_deadline_test() ->
    with_pending(fun(Pending = {Owner, _, Monitor, Timer}) ->
        Owner ! stop,
        receive
            {recovery_owner_down, Monitor, process, Owner, _} = Message ->
                ?assertEqual(none, quod_runtime:test_recovery_pending(Pending, Message)),
                ?assertEqual(false, erlang:read_timer(Timer))
        after 1000 -> error(owner_death_not_delivered)
        end
    end).

deadline_releases_only_its_matching_receipt_test() ->
    with_pending(fun(Pending = {Owner, Token, Monitor, Timer}) ->
        ?assertEqual(Pending, quod_runtime:test_recovery_pending(
            Pending, {timeout, Timer, {recovery_expired, make_ref()}})),
        ?assert(is_integer(erlang:read_timer(Timer))),
        _ = erlang:cancel_timer(Timer),
        Due = erlang:start_timer(0, self(), {recovery_expired, Token}),
        receive
            {timeout, Due, {recovery_expired, Token}} = Message ->
                ?assertEqual(none, quod_runtime:test_recovery_pending(
                    {Owner, Token, Monitor, Due}, Message))
        after 1000 -> error(receipt_deadline_not_delivered)
        end
    end).

matching_keeps_original_monotonic_deadline_test_() ->
    [?_test(begin
        {ok, _} = application:ensure_all_started(gproc),
        Ns = <<"handoff-request-bound">>, Node = {agent_instance_ref, Ns, <<83:256>>, node},
        true = quod_reg:reg({quod_runtime, Ns}),
        Deadline = quod_time:mono_ms() + Remaining,
        Expiry = quod_time:now_ms() + 60000,
        Parent = self(),
        {Worker, Monitor} = spawn_monitor(fun() ->
            #est{db = #db{ref = Db}} = Est = quod_ct:action_kb(<<>>, [quod_ontology_predicates], []),
            Binding = #{reference => Node, credential => node, public_key => <<84:256>>,
                        request_timeout_ms => 60000, request_expiry => Expiry,
                        recovery => #{deadline => Deadline}},
            try Parent ! {matched, self(), quod_runtime_predicates:run_reaction(
                Ns, 1, Binding, {':-', {react_on, event, true}, true}, event, Est)}
            after quod_erlog_db_mvcc:delete(Db) end
        end),
        try
            receive
                {'$gen_call', From, {agent_request, 1, _, _, true, {ActualExpiry, ActualDeadline}}} ->
                    ?assert(ActualExpiry =< Expiry),
                    ?assertEqual(Deadline, ActualDeadline),
                    gen_server:reply(From, ok)
            after 1000 -> error(matching_did_not_submit)
            end,
            receive {matched, Worker, executed} -> ok
            after 1000 -> error(matching_did_not_finish) end,
            receive {'DOWN', Monitor, process, Worker, normal} -> ok
            after 1000 -> error(matching_worker_did_not_stop) end
        after
            exit(Worker, kill), demonitor(Monitor, [flush]),
            true = gproc:unreg(quod_reg:name({quod_runtime, Ns}))
        end
    end) || Remaining <- [5000, -1]].

with_pending(Fun) ->
    Owner = spawn(fun() -> receive stop -> ok end end),
    Monitor = monitor(process, Owner, [{tag, recovery_owner_down}]),
    Token = make_ref(), Timer = erlang:start_timer(60000, self(), {recovery_expired, Token}),
    try Fun({Owner, Token, Monitor, Timer})
    after
        _ = erlang:cancel_timer(Timer),
        demonitor(Monitor, [flush]), exit(Owner, kill)
    end.

with_evidence(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    {ok, Directory} = quod_directory:start_link(#{expire_tick_ms => 60000, ttl_ms => 600000}),
    true = quod_reg:reg({transport, node}),
    try
        Host = {agent_instance_ref, <<"handoff-peer">>, <<85:256>>, node},
        Node = {agent_instance_ref, <<"handoff-node">>, <<86:256>>, node},
        {ok, Blob} = quod_wire_term:encode_canonical(Host),
        Generation = #{author => {node_actor, Blob}, node_key => <<87:256>>,
            endpoint => {<<"127.0.0.1">>, 14568}, epoch => 1,
            generation => 1, page => 0, last => true,
            hosted => [{element(2, Host), element(3, Host), observer, node}]},
        {ok, _} = quod_directory:install_generation(Generation),
        {ok, Contact} = quod_directory:node_transport_route(Host),
        Batch = #{host => Host, self => <<88:256>>, observer => Node,
            episode => <<89:256>>, transport => self(), contact => Contact,
            kind => suspected_unreachable, at => quod_time:now_ms(), bindings => [{actor, 1, none}]},
        Fun(#{batch => Batch, contact => Contact, generation => Generation})
    after
        case quod_reg:where({transport, node}) of
            Pid when Pid =:= self() -> gproc:unreg(quod_reg:name({transport, node}));
            _ -> ok
        end,
        gen_server:stop(Directory)
    end.

restore(Key, undefined) -> application:unset_env(quod, Key);
restore(Key, {ok, Value}) -> application:set_env(quod, Key, Value).
