-module(quod_agent_observation_drop_tests).
-include_lib("eunit/include/eunit.hrl").

missing_host_contact_requests_its_node_actor_route_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    {ok, Directory} = quod_directory:start_link(#{expire_tick_ms => 60000}),
    {Control, ControlMonitor} = fake_owner({directory, control}, true),
    {Transport, TransportMonitor} = fake_owner({transport, node}, false),
    Ns = <<"observation-route-node">>, Anchor = <<69:256>>,
    Host = {agent_instance_ref, Ns, Anchor, physical_node},
    Observer = quod_agent_observer:new(<<70:256>>),
    {ok, Installed} = quod_agent_observer:project(
                        all, [{watch, actor, Host, 1, none}], Observer),
    try
        receive
            {fake_cast, Control, {route_needed, {Ns, Anchor}}} -> ok
        after 1000 -> error(node_actor_route_not_requested)
        end
    after
        ok = quod_agent_observer:stop(Installed),
        stop_fake_owner(Transport, TransportMonitor),
        stop_fake_owner(Control, ControlMonitor),
        gen_server:stop(Directory)
    end.

fake_owner(Name, ForwardCasts) ->
    Parent = self(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        true = quod_reg:reg(Name),
        Parent ! {fake_owner_ready, self()},
        fake_owner_loop(Parent, ForwardCasts)
    end),
    receive {fake_owner_ready, Pid} -> {Pid, Monitor}
    after 1000 -> error({fake_owner_not_ready, Name}) end.

fake_owner_loop(Parent, ForwardCasts) ->
    receive
        {'$gen_cast', Message} when ForwardCasts ->
            Parent ! {fake_cast, self(), Message},
            fake_owner_loop(Parent, ForwardCasts);
        stop -> ok;
        _ -> fake_owner_loop(Parent, ForwardCasts)
    end.

stop_fake_owner(Pid, Monitor) ->
    Pid ! stop,
    receive {'DOWN', Monitor, process, Pid, normal} -> ok
    after 1000 -> error({fake_owner_not_stopped, Pid}) end.

expired_physical_batches_count_once_and_keep_fresh_work_test() ->
    with_observation(fun(#{batch := Batch, observer := Observer}) ->
        Expired = Batch#{at => quod_time:now_ms() - 60000},
        %% Each batch still has three bindings. Counter units are queued
        %% occurrences, not the number of unsubmitted instance reports.
        ?assertEqual({[], 1}, drain([Expired], Observer)),
        {Remaining, 0} = drain([Batch], Observer),
        ?assertEqual([{observed_host, Batch#{bindings => [{b, 1, none}, {c, 1, none}]}}],
                     Remaining),
        ?assertEqual({[], 0}, drain([Batch#{bindings => []}], Observer))
    end).

replaced_transport_owner_counts_unsent_batch_test() ->
    with_observation(fun(#{batch := Batch, observer := Observer}) ->
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
            ?assertEqual({[], 1}, drain([Batch], Observer))
        after
            Replacement ! stop,
            receive {'DOWN', Monitor, process, Replacement, _} -> ok
            after 1000 -> error(transport_not_stopped) end
        end
    end).

new_contact_generation_counts_batch_on_physical_turn_test() ->
    with_observation(fun(#{batch := Batch, observer := Observer,
                          generation := Generation}) ->
        {ok, _} = quod_directory:install_generation(Generation#{generation => 2}),
        ?assertNot(quod_agent_observer:current(Batch, Observer)),
        %% Ordinary work continues after the only physical batch is discarded.
        %% This also covers the alternating ordinary/physical admission branch.
        ?assertEqual({[], 1}, quod_runtime:test_drain_observations(
            [{observed, unrelated}, {observed_host, Batch}], Observer, true))
    end).

drain(Batches, Observer) ->
    quod_runtime:test_drain_observations(
        [{observed_host, Batch} || Batch <- Batches], Observer, false).

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
        Fun(#{batch => Batch, observer => Observer, generation => Generation})
    after
        case quod_reg:where({transport, node}) of
            Pid when Pid =:= self() -> gproc:unreg(quod_reg:name({transport, node}));
            _ -> ok
        end,
        gen_server:stop(Directory)
    end.
