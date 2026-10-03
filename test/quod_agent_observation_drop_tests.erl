-module(quod_agent_observation_drop_tests).
-include_lib("eunit/include/eunit.hrl").

expired_physical_batches_count_once_and_keep_fresh_work_test() ->
    with_observation(fun(#{batch := Batch, observer := Observer, plan := Plan}) ->
        Expired = Batch#{at => quod_time:now_ms() - 60000},
        %% Each batch still has three bindings. Counter units are queued
        %% occurrences, not the number of unsubmitted instance reports.
        ?assertEqual({[], [], 1}, drain([Expired], Observer, Plan)),
        {First, Remaining, 1} = drain([Expired, Batch], Observer, Plan),
        ?assertEqual([a], selected_instances(First)),
        ?assertEqual([{observed_host, Batch#{bindings => [{b, 1, none}, {c, 1, none}]}}],
                     Remaining),
        {Second, Last, 0} = quod_runtime:test_drain_observations(Remaining, Observer, Plan, false),
        ?assertEqual([b], selected_instances(Second)),
        ?assertEqual([{observed_host, Batch#{bindings => [{c, 1, none}]}}], Last),
        {Third, EmptyBatch, 0} = quod_runtime:test_drain_observations(Last, Observer, Plan, false),
        ?assertEqual([c], selected_instances(Third)),
        ?assertEqual({[], [], 0}, quod_runtime:test_drain_observations(EmptyBatch, Observer, Plan, false)),
        ?assertEqual({[], [], 0}, drain([Batch#{bindings => []}], Observer, Plan))
    end).

replaced_transport_owner_counts_unsent_batch_test() ->
    with_observation(fun(#{batch := Batch, observer := Observer, plan := Plan}) ->
        true = gproc:unreg(quod_reg:name({transport, node})),
        Parent = self(),
        {Replacement, Monitor} = spawn_monitor(fun() ->
            true = quod_reg:reg({transport, node}),
            Parent ! {transport_installed, self()},
            receive stop -> ok end
        end),
        try
            receive {transport_installed, Replacement} -> ok
            after 1000 -> error(transport_not_installed) end,
            %% The former owner is still alive; identity replacement alone
            %% must fence its captured evidence.
            ?assert(is_process_alive(maps:get(transport, Batch))),
            ?assertNot(quod_agent_observer:current(Batch, Observer)),
            ?assertEqual({[], [], 1}, drain([Batch], Observer, Plan))
        after
            Replacement ! stop,
            receive {'DOWN', Monitor, process, Replacement, _} -> ok
            after 1000 -> error(transport_not_stopped) end
        end
    end).

new_contact_generation_counts_batch_on_physical_turn_test() ->
    with_observation(fun(#{batch := Batch, observer := Observer,
                          generation := Generation, plan := Plan}) ->
        {ok, _} = quod_directory:install_generation(Generation#{generation => 2}),
        ?assertNot(quod_agent_observer:current(Batch, Observer)),
        %% Ordinary work continues after the only physical batch is discarded.
        %% This also covers the alternating ordinary/physical admission branch.
        ?assertEqual({[{snapshot, 1, unused}], [], 1}, quod_runtime:test_drain_observations(
            [{snapshot, 1, unused}, {observed_host, Batch}], Observer, Plan, true))
    end).

drain(Batches, Observer, Plan) ->
    quod_runtime:test_drain_observations(
        [{observed_host, Batch} || Batch <- Batches], Observer, Plan, false).

selected_instances(Selected) ->
    [I || {recovery_selection, _,
           {agent_host_observed, _, _, I, _, _, _, _, _, _, _, _}, _} <- Selected].

with_observation(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    {ok, Directory} = quod_directory:start_link(#{expire_tick_ms => 60000, ttl_ms => 600000}),
    true = quod_reg:reg({transport, node}),
    try
        Ns = <<"observation-drop-node">>, Anchor = <<71:256>>,
        Host = {agent_instance_ref, Ns, Anchor, physical_node},
        {ok, Blob} = quod_wire_term:encode_canonical(Host),
        Generation = #{author => {node_actor, Blob}, node_key => <<72:256>>,
            endpoint => {<<"127.0.0.1">>, 14567}, epoch => 1,
            generation => 1, page => 0, last => true,
            hosted => [{Ns, Anchor, observer, node}]},
        {ok, _} = quod_directory:install_generation(Generation),
        {ok, Contact} = quod_directory:node_transport_route(Host),
        Observer = #{transport => self(), hosts => #{Host => #{contact => Contact}}},
        Batch = #{host => Host, self => <<73:256>>, observer => Host,
            episode => <<74:256>>, transport => self(), contact => Contact,
            kind => suspected_unreachable, at => quod_time:now_ms(),
            bindings => [{a, 1, none}, {b, 1, none}, {c, 1, none}]},
        ?assert(quod_agent_observer:current(Batch, Observer)),
        Clause = {':-', {react_on,
                    {observed, {agent_host_observed, {'_'}, {'Observer'}, {'I'}, {'_'}, {'_'},
                                {'_'}, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}}},
                    {record_observation, {'I'}}}, {me, {'Observer'}}},
        {ok, Plan} = quod_runtime:plan_runtime_catalog(#{subscriptions => [], reactions => [Clause]}),
        Fun(#{batch => Batch, observer => Observer, generation => Generation, plan => Plan})
    after
        case quod_reg:where({transport, node}) of
            Pid when Pid =:= self() -> gproc:unreg(quod_reg:name({transport, node}));
            _ -> ok
        end,
        gen_server:stop(Directory)
    end.
