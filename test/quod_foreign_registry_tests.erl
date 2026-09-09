-module(quod_foreign_registry_tests).
-include_lib("eunit/include/eunit.hrl").

%% Destructive registry faults belong in isolated VMs, never the EUnit VM's
%% shared gproc application. These are real lifecycle tests, not source-shape
%% assertions and not substitutes for the foreign owner's same-file test.
-export([server_restart_case/0, table_owner_fixture/1,
         temporary_table_owner_case/0]).

server_crash_preserves_custody_and_rearms_monitors_test_() ->
    {timeout, 45, fun() ->
        with_peer(fun(Peer) ->
            ?assertEqual(ok, peer:call(Peer, ?MODULE, server_restart_case,
                                      [], 20000))
        end)
    end}.

permanent_table_owner_death_terminates_node_test_() ->
    {timeout, 45, fun() ->
        with_peer(fun(Peer) ->
            {Sup, Holder, Key} = peer:call(
                                  Peer, ?MODULE, table_owner_fixture,
                                  [permanent]),
            %% A live, separately spawned custodian exists at the failure
            %% boundary. Killing the table owner, not the custodian or VM,
            %% must terminate the whole permanent-application peer.
            ?assertEqual(Holder, peer:call(Peer, quod_reg, where, [Key])),
            ?assertEqual(true, peer:call(Peer, erlang, is_process_alive,
                                        [Holder])),
            Ref = erlang:monitor(process, Peer),
            ok = peer:cast(Peer, erlang, exit, [Sup, kill]),
            receive
                {'DOWN', Ref, process, Peer, {exit_status, Status}} ->
                    ?assertNotEqual(0, Status)
            after 10000 ->
                erlang:error(permanent_registry_failure_did_not_stop_node)
            end
        end)
    end}.

temporary_application_is_not_a_safe_registry_boundary_test_() ->
    %% Positive observer control: changing only the application start type
    %% admits the very live-holder/table-recreation schedule we exclude.
    {timeout, 45, fun() ->
        with_peer(fun(Peer) ->
            ?assertEqual(ok, peer:call(Peer, ?MODULE,
                                      temporary_table_owner_case, [], 20000))
        end)
    end}.

with_peer(Fun) ->
    %% stdio needs neither distribution nor a listening network socket.
    %% Do not leave a VM crash dump in the repository after the fatal case.
    {ok, Peer, _} = peer:start(
                      #{connection => standard_io, peer_down => crash,
                        env => [{"ERL_CRASH_DUMP", "/dev/null"}],
                        args => ["+S", "2:2", "-pa" | code:get_path()]}),
    try Fun(Peer)
    after
        _ = catch peer:stop(Peer)
    end.

server_restart_case() ->
    {Sup, Holder, Key} = table_owner_fixture(permanent),
    Name = quod_reg:name(Key),
    NameRef = quod_reg:monitor_name(Key, info),
    Server = whereis(gproc),
    ServerRef = erlang:monitor(process, Server),
    ?assertNotEqual(Sup, Server),
    ?assertEqual(Sup, ets:info(gproc, owner)),
    %% Hold the supervisor, not a time interval, so the outage is real and
    %% cannot disappear before registration/monitor failure is observed.
    ok = sys:suspend(Sup),
    1 = erlang:trace(Sup, true, [procs]),
    try
        exit(Server, kill),
        await_down(ServerRef, Server, killed),
        ?assertEqual(undefined, whereis(gproc)),
        ?assertEqual(Sup, ets:info(gproc, owner)),
        ?assertEqual(Holder, quod_reg:where(Key)),
        ?assert(is_process_alive(Holder)),
        ?assertExit({noproc, _}, quod_reg:reg(Key)),
        ?assertExit({noproc, _}, quod_reg:reg({foreign_cache_writer, make_ref()})),
        ?assertExit({noproc, _}, quod_reg:monitor_name(Key, info)),
        receive
            {gproc, unreg, NameRef, Name} ->
                erlang:error(server_crash_falsely_released_custody)
        after 0 -> ok
        end,
        ok = sys:resume(Sup),
        %% A real supervisor spawn edge followed by its synchronous API is
        %% the restart barrier; no sleep/poll or direct gproc restart driver.
        NewServer = receive
            {trace, Sup, spawn, Pid, _MFA} -> Pid
        after 5000 -> erlang:error(registry_server_was_not_restarted)
        end,
        Children = supervisor:which_children(Sup),
        ?assertMatch({gproc, NewServer, worker, _},
                     lists:keyfind(gproc, 1, Children)),
        ?assertNotEqual(Server, NewServer),
        ?assertEqual(NewServer, whereis(gproc)),
        ?assertEqual(Sup, ets:info(gproc, owner)),
        ?assertEqual(Holder, quod_reg:where(Key)),
        ?assertError(badarg, quod_reg:reg(Key)),
        {monitors, Monitors} = process_info(NewServer, monitors),
        ?assert(lists:member({process, Holder}, Monitors)),
        %% This name monitor was created before the crash. Its notification
        %% after holder death proves both preserved monitor data and rearm.
        exit(Holder, kill),
        await_unregistered(NameRef, Name),
        ?assertEqual(undefined, quod_reg:where(Key)),
        Successor = start_holder(Key),
        ?assertEqual(Successor, quod_reg:where(Key)),
        SuccessorRef = quod_reg:monitor_name(Key, info),
        Successor ! stop,
        await_unregistered(SuccessorRef, Name),
        ok
    after
        _ = catch sys:resume(Sup),
        _ = erlang:trace(Sup, false, [procs]),
        exit(Holder, kill)
    end.

table_owner_fixture(RestartType) ->
    ok = application:start(gproc, RestartType),
    Sup = whereis(gproc_sup),
    ?assert(is_pid(Sup)),
    ?assertEqual(Sup, ets:info(gproc, owner)),
    Key = {foreign_cache_writer, {<<"registry-fixture">>, <<0:256>>}},
    Holder = start_holder(Key),
    ?assertEqual(Holder, quod_reg:where(Key)),
    {Sup, Holder, Key}.

temporary_table_owner_case() ->
    {Sup, Holder, Key} = table_owner_fixture(temporary),
    Master = application_controller:get_master(gproc),
    MasterRef = erlang:monitor(process, Master),
    %% Trace the application controller's actual processing of app death;
    %% only then send the synchronous restart request to that same process.
    Controller = whereis(application_controller),
    1 = erlang:trace(Controller, true, ['receive']),
    try
        exit(Sup, kill),
        receive
            {'DOWN', MasterRef, process, Master, _} -> ok
        after 5000 -> erlang:error(application_master_survived)
        end,
        receive
            {trace, Controller, 'receive', {'EXIT', Master, _}} -> ok
        after 5000 -> erlang:error(application_exit_not_processed)
        end,
        ?assertEqual(undefined, ets:info(gproc, owner)),
        ?assert(is_process_alive(Holder)),
        ok = application:start(gproc, temporary),
        ?assertNotEqual(Sup, ets:info(gproc, owner)),
        Successor = start_holder(Key),
        ?assertNotEqual(Holder, Successor),
        ?assert(is_process_alive(Holder)),
        ?assertEqual(Successor, quod_reg:where(Key)),
        Successor ! stop,
        ok
    after
        _ = erlang:trace(Controller, false, ['receive']),
        exit(Holder, kill)
    end.

start_holder(Key) ->
    Parent = self(),
    {Holder, Ref} = spawn_monitor(fun() ->
        true = quod_reg:reg(Key),
        Parent ! {holder_registered, self()},
        receive stop -> ok end
    end),
    receive
        {holder_registered, Holder} ->
            erlang:demonitor(Ref, [flush]),
            Holder;
        {'DOWN', Ref, process, Holder, Reason} ->
            erlang:error({holder_registration_failed, Reason})
    after 5000 ->
        exit(Holder, kill),
        erlang:error(holder_registration_timeout)
    end.

await_down(Ref, Pid, Reason) ->
    receive
        {'DOWN', Ref, process, Pid, Reason} -> ok
    after 5000 -> erlang:error(process_did_not_die)
    end.

await_unregistered(Ref, Name) ->
    receive
        {gproc, unreg, Ref, Name} -> ok
    after 5000 -> erlang:error(missing_custody_release)
    end.
