-module(quod_foreign_custody_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

%% File/watcher instrumentation is loaded only into fresh stdio peers. The
%% production verifier, reservations, signatures and file operations still run.
-export([run_case/2, mutation/2, before_append/2, after_append/2,
         watcher_ready/2, monitor_barrier/2, registration_barrier/1,
         watcher_only_register/1, watcher_only_claim/2]).

same_inode_restart_exclusion_test_() ->
    peer_test(restart, protected).

same_identity_root_alias_does_not_bypass_custody_test_() ->
    peer_test(restart, root_alias).

watcher_only_negative_control_test_() ->
    peer_test(restart, watcher_only).

callerless_custody_wait_and_other_identity_progress_test_() ->
    peer_test(queue, ordinary).

suspended_session_survives_custody_sweep_test_() ->
    peer_test(session, ordinary).

read_only_admission_and_custody_revalidation_test_() ->
    [peer_test(discovery, Mode) || Mode <- [valid, corrupt, repaired]].

custody_release_subscription_order_test_() ->
    [peer_test(release, Mode) || Mode <- [before_monitor, after_monitor, reacquire]].

unavailable_monitor_fails_owner_not_unmonitored_park_test_() ->
    peer_test(registry_outage, ordinary).

unfollow_custody_head_dispatches_queued_exact_sibling_test_() ->
    peer_test(follow_cancel, ordinary).

cancellation_before_denial_does_not_requeue_retiring_work_test_() ->
    [peer_test(cancel_denied, Mode) || Mode <- [source_down, follow_cancel]].

distinct_arrival_cannot_bypass_existing_custody_head_test_() ->
    [peer_test(custody_fifo, Mode) || Mode <- [direct, routed]].

peer_test(Case, Mode) ->
    {atom_to_list(Case) ++ "/" ++ atom_to_list(Mode), {timeout, 60, fun() ->
        Root = quod_foreign_log_tests:temp_dir("custody"),
        {ok, Peer, _} = peer:start(
          #{connection => standard_io,
            env => [{"ERL_CRASH_DUMP", "/dev/null"}],
            args => ["+S", "2:2", "-pa" | code:get_path()]}),
        try
            %% Pin the exact beams selected by this runner, including private
            %% snapshots. Shared builds may proceed while these peers execute.
            lists:foreach(fun(Module) ->
                Path = filename:absname(code:which(Module)),
                ?assertEqual({module, Module}, peer:call(
                    Peer, code, load_abs, [filename:rootname(Path)])),
                ?assertEqual(Path, peer:call(Peer, code, which, [Module]))
            end, [?MODULE, quod_foreign_log, quod_reg, quod_dtx_phase_index,
                  quod_foreign_log_tests]),
            ?assertEqual(ok, peer:call(Peer, ?MODULE, run_case,
                                      [{Case, Mode}, Root], 45000))
        after
            _ = catch peer:stop(Peer),
            _ = file:del_dir_r(Root)
        end
    end}}.

run_case({Case, Mode}, Root) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(gproc),
    true = register(quod_custody_test_controller, self()),
    case Case of
        restart -> restart_case(Root, Mode);
        queue -> queue_case(Root);
        session -> session_case(Root);
        discovery -> discovery_case(Root, Mode);
        release -> release_case(Root, Mode);
        registry_outage -> registry_outage_case(Root);
        follow_cancel -> follow_cancel_case(Root);
        cancel_denied -> cancel_denied_case(Root, Mode);
        custody_fifo -> custody_fifo_case(Root, Mode)
    end.

restart_case(Root, Mode) ->
    Fixture = fixture(),
    Identity = identity(Fixture),
    Owner = start_owner(Root, fetch(Fixture)),
    seed_genesis(Owner, Fixture),
    await_name_free(Identity),
    install_mutation_observers(),
    install_append_barriers(),
    install_watcher_barrier(),
    case Mode of watcher_only -> install_watcher_only_mutant(); _ -> ok end,
    persistent_term:put({?MODULE, held_owner}, Owner),
    persistent_term:put({?MODULE, append_gate}, true),
    OwnerRef = monitor(process, Owner),
    OldRequest = request(Owner, Fixture, 30000),
    {OldWorker, OldStore, OldFile} = await_before(),
    OldWorkerRef = monitor(process, OldWorker),
    Watcher = receive
        {watcher_held, Owner, OldWorker, W} -> W
    after 5000 -> error(real_watcher_not_held)
    end,
    {monitors, WatcherMonitors} = process_info(Watcher, monitors),
    ?assert(lists:member({process, Owner}, WatcherMonitors)),
    ?assert(lists:member({process, OldWorker}, WatcherMonitors)),
    ?assertEqual(1, maps:get(last_index, OldFile)),
    ?assert(maps:get(offset, OldFile) > 0),
    ?assertEqual(maps:get(offset, OldFile), maps:get(bytes, OldFile)),
    _ = mutations(),
    1 = erlang:trace(Watcher, true, ['receive']),
    exit(Owner, kill),
    await_down(OwnerRef, Owner, killed),
    receive {trace, Watcher, 'receive', {'DOWN', _, process, Owner, killed}} -> ok
    after 5000 -> error(watcher_owner_down_delivery_not_observed) end,
    {messages, WatcherMessages} = process_info(Watcher, messages),
    ?assert(lists:any(fun({'DOWN', _, process, P, killed}) -> P =:= Owner;
                        (_) -> false end, WatcherMessages)),
    ReplacementRoot = case Mode of root_alias -> Root ++ "/."; _ -> Root end,
    Replacement = start_owner(ReplacementRoot, fetch(Fixture)),
    trace_owner(Replacement),
    NewRequest = request(Replacement, Fixture, 30000),
    case Mode of
        Protected when Protected =/= watcher_only ->
            {_Job, Denied} = await_park(Replacement, Identity),
            await_dead(Denied),
            ?assertEqual(OldWorker, quod_reg:where(writer_key(Identity))),
            ?assert(is_process_alive(OldWorker)),
            ?assertEqual([], mutations()),
            ?assertEqual(OldFile, store_summary(OldStore)),
            release_watcher(Watcher, OldWorkerRef, OldWorker);
        watcher_only -> ok
    end,
    {NewWorker, NewStore, NewFile} = await_before(),
    NewWorkerRef = monitor(process, NewWorker),
    ?assertNotEqual(OldWorker, NewWorker),
    ?assertNotEqual(element(4, OldStore), element(4, NewStore)),
    ?assertEqual(maps:remove(path, OldFile), maps:remove(path, NewFile)),
    Mutations = mutations(),
    [Initializer] = [P || {P, quod_ledger_store, open} <- Mutations],
    ?assertNotEqual(NewWorker, Initializer),
    ?assert(lists:member({NewWorker, quod_ledger_store, resume}, Mutations)),
    case Mode of
        watcher_only ->
            OldWorker ! {release_append, self()},
            OldAfter = await_after(OldWorker),
            ?assert(maps:get(bytes, OldAfter) > maps:get(bytes, OldFile)),
            ?assert(is_process_alive(OldWorker));
        _ ->
            ?assertNot(is_process_alive(OldWorker)),
            receive {append_after, OldWorker, _} -> error(retired_worker_wrote)
            after 0 -> ok end
    end,
    NewWorker ! {release_append, self()},
    NewAfter = await_after(NewWorker),
    ?assertEqual(maps:get(inode, OldFile), maps:get(inode, NewAfter)),
    ?assert(maps:get(bytes, NewAfter) > maps:get(bytes, OldFile)),
    case Mode of
        watcher_only ->
            %% The original append body ran for both writers on the same
            %% inode/offset. Identical certified bytes need not corrupt a file.
            ?assert(is_process_alive(OldWorker)),
            ?assertError(custody_exclusion_violated,
                         assert_excluded(is_process_alive(OldWorker))),
            release_watcher(Watcher, OldWorkerRef, OldWorker);
        _ -> assert_excluded(is_process_alive(OldWorker))
    end,
    NewWorker ! {finish_append, self()},
    assert_verified(NewRequest),
    await_down(NewWorkerRef, NewWorker, normal),
    ?assertMatch({error, {killed, _}}, gen_server:wait_response(OldRequest, 1000)),
    stop_owner(Replacement),
    ok.

assert_excluded(false) -> ok;
assert_excluded(true) -> error(custody_exclusion_violated).

queue_case(Root) ->
    First = fixture(), Other = fixture(),
    Identity = identity(First),
    Counts = atomics:new(2, []),
    Fetch1 = fetch(First), Fetch2 = fetch(Other),
    Fetch = fun(P, E, Ns, From, To) ->
        case Ns =:= maps:get(ns, First) of
            true -> atomics:add_get(Counts, 1, 1), Fetch1(P, E, Ns, From, To);
            false -> atomics:add_get(Counts, 2, 1), Fetch2(P, E, Ns, From, To)
        end
    end,
    Holder = holder(Identity),
    Owner = start_owner(Root, Fetch),
    trace_owner(Owner),
    Short = request(Owner, First, 100),
    {Job, _} = await_park(Owner, Identity),
    {custody, Monitor} = queued_field(Owner, Identity, parked),
    Owner ! {gproc, unreg, make_ref(), quod_reg:name(writer_key(Identity))},
    Owner ! {gproc, unreg, Monitor, quod_reg:name(writer_key(identity(Other)))},
    Owner ! {directory_route_available, Identity},
    ?assertEqual({custody, Monitor}, queued_field(Owner, Identity, parked)),
    ?assertEqual(0, atomics:get(Counts, 1)),
    ?assertEqual(Holder, quod_reg:where(writer_key(Identity))),
    ?assertEqual({reply, {error, retry}}, gen_server:wait_response(Short, 2000)),
    ?assertMatch(#{active := none, waiting := [#{ref := Job, callers := [],
                                                wait_reason := custody}]},
                 lifecycle(Owner, Identity)),
    OtherRequest = request(Owner, Other, 5000),
    assert_verified(OtherRequest),
    ?assert(atomics:get(Counts, 2) > 0),
    ?assert(is_process_alive(Holder)),
    ?assert(filelib:is_file(log_path(Root, identity(Other)))),
    ?assertEqual(0, atomics:get(Counts, 1)),
    Holder ! stop,
    await_done(Owner, Job),
    ?assertMatch(#{active := none, waiting := [], height := 2},
                 lifecycle(Owner, Identity)),
    ?assert(atomics:get(Counts, 1) > 0),
    %% A route-unavailable park has the opposite last-caller rule.
    Missing = fixture(),
    NoRoute = send_request(Owner,
      {verify_reference, maps:get(ref, Missing), finalize, none, none, 50}, 50),
    ?assertMatch(#{waiting := [#{wait_reason := route}]},
                 lifecycle(Owner, identity(Missing))),
    ?assertEqual({reply, {error, retry}}, gen_server:wait_response(NoRoute, 2000)),
    ?assertNot(maps:is_key(identity(Missing), gen_server:call(Owner, test_lifecycle_state))),
    stop_owner(Owner), ok.

session_case(Root) ->
    Fixture = fixture(), Identity = identity(Fixture),
    Owner = start_owner(Root, fetch(Fixture)),
    assert_verified(request(Owner, Fixture, 5000)),
    await_name_free(Identity),
    Session = history_field(Owner, Identity, phase_session),
    Path = quod_dtx_phase_index:test_path(Session),
    ?assert(filelib:is_file(Path)),
    CacheNs = quod_foreign_log:cache_namespace(Identity),
    {ok, Abandoned0} = quod_dtx_phase_index:open(Root, CacheNs),
    {ok, Abandoned} = quod_dtx_phase_index:suspend(Abandoned0),
    AbandonedPath = quod_dtx_phase_index:test_path(Abandoned),
    ?assertNotEqual(Path, AbandonedPath),
    Holder = holder(Identity),
    trace_owner(Owner),
    Request = request(Owner, Fixture, 5000),
    await_park(Owner, Identity),
    ?assertEqual(Session, history_field(Owner, Identity, phase_session)),
    ?assert(filelib:is_file(Path)),
    ?assert(filelib:is_file(AbandonedPath)),
    Holder ! stop,
    assert_verified(Request),
    ?assertEqual(Path, quod_dtx_phase_index:test_path(
                         history_field(Owner, Identity, phase_session))),
    ?assert(filelib:is_file(Path)),
    ?assertNot(filelib:is_file(AbandonedPath)),
    stop_owner(Owner),
    %% Unique-path close is not the broad cleanup operation. Reject a foreign
    %% retained path/open session without sweeping anything in that directory.
    {ok, Old0} = quod_dtx_phase_index:open(Root, <<"index-control">>),
    {ok, Old} = quod_dtx_phase_index:suspend(Old0),
    {ok, Next0} = quod_dtx_phase_index:open(Root, <<"index-control">>),
    ?assertEqual({error, bad_phase_index_argument},
                 quod_dtx_phase_index:cleanup(Root, <<"index-control">>, Next0)),
    {ok, Next} = quod_dtx_phase_index:suspend(Next0),
    ?assertEqual({error, bad_phase_index_argument},
                 quod_dtx_phase_index:cleanup(Root, <<"other-index">>, Next)),
    ok = quod_dtx_phase_index:close(Old),
    ?assert(filelib:is_file(quod_dtx_phase_index:test_path(Next))),
    {ok, Resumed} = quod_dtx_phase_index:resume(Next),
    ok = quod_dtx_phase_index:close(Resumed), ok.

discovery_case(Root, Mode) ->
    Fixture = fixture(), Identity = identity(Fixture),
    Count = atomics:new(1, []), BaseFetch = fetch(Fixture),
    Fetch = fun(P, E, Ns, From, To) ->
        atomics:add_get(Count, 1, 1), BaseFetch(P, E, Ns, From, To)
    end,
    Seed = start_owner(Root, Fetch),
    assert_verified(request(Seed, Fixture, 5000)),
    ?assert(atomics:get(Count, 1) > 0),
    await_name_free(Identity), stop_owner(Seed),
    atomics:put(Count, 1, 0),
    Dir = filename:dirname(log_path(Root, Identity)),
    Checkpoint = filename:join(Dir, "checkpoint.term"),
    Temp = filename:join(Dir, "checkpoint.term.new.custody-control"),
    {ok, Saved} = file:read_file(Checkpoint),
    Before = file_summary(log_path(Root, Identity)),
    ok = file:write_file(Temp, <<"abandoned temporary checkpoint">>),
    case Mode of valid -> ok; _ -> ok = file:write_file(Checkpoint, <<"bad checkpoint">>) end,
    Holder = holder(Identity),
    install_mutation_observers(),
    Owner = start_owner(Root, Fetch),
    trace_owner(Owner),
    %% The startup initializer and then the request wait behind the same
    %% custody. Corrupt metadata is not permission to remove the cache early.
    _ = gen_server:call(Owner, {route_hints, Identity, []}),
    Request = request(Owner, Fixture, 10000),
    await_park(Owner, Identity),
    ?assertEqual(Before, file_summary(log_path(Root, Identity))),
    ?assert(filelib:is_file(Temp)),
    ?assertEqual([], mutations()),
    ?assertEqual(0, atomics:get(Count, 1)),
    case Mode of
        repaired ->
            Holder ! {repair, self(), Checkpoint, Saved},
            receive {repaired, Holder} -> ok after 1000 -> error(repair_not_done) end;
        _ -> ok
    end,
    Holder ! stop,
    assert_verified(Request),
    ?assertNot(filelib:is_file(Temp)),
    case Mode of
        corrupt -> ?assert(atomics:get(Count, 1) > 0);
        _ ->
            ?assertEqual(0, atomics:get(Count, 1)),
            ?assertEqual(Before, file_summary(log_path(Root, Identity)))
    end,
    ?assert(length(mutations()) > 0),
    stop_owner(Owner), ok.

release_case(Root, Mode) ->
    Fixture = fixture(), Identity = identity(Fixture),
    Holder = holder(Identity),
    install_monitor_barriers(),
    Owner = start_owner(Root, fetch(Fixture)),
    trace_owner(Owner),
    Stage = case Mode of before_monitor -> before; _ -> after_monitor end,
    persistent_term:put({?MODULE, monitor_gate}, {Owner, Stage}),
    Request = request(Owner, Fixture, 10000),
    receive {monitor_held, Owner, Stage} -> ok
    after 5000 -> error(monitor_barrier_missing) end,
    HolderRef = monitor(process, Holder), Holder ! stop,
    await_down(HolderRef, Holder, normal),
    %% Reacquisition is genuinely lost to another live holder. It must park
    %% again and await that holder's actual release, not respawn repeatedly.
    Next = case Mode of
        reacquire -> await_name_free(Identity), holder(Identity);
        _ -> none
    end,
    persistent_term:erase({?MODULE, monitor_gate}),
    Owner ! {release_monitor, self()},
    case Next of
        none -> ok;
        _ ->
            {_Job, _} = await_denial(Owner),
            %% First denial belonged to the deliberately held monitor call.
            %% Consume the second denial/repark before releasing the winner.
            {_Job2, _} = await_park(Owner, Identity),
            ?assertEqual(Next, quod_reg:where(writer_key(Identity))),
            ?assertNot(filelib:is_file(log_path(Root, Identity))),
            Next ! stop
    end,
    assert_verified(Request), stop_owner(Owner), ok.

registry_outage_case(Root) ->
    Fixture = fixture(), Identity = identity(Fixture),
    Holder = holder(Identity),
    install_monitor_barriers(),
    Owner = start_owner(Root, fetch(Fixture)),
    OwnerRef = monitor(process, Owner),
    persistent_term:put({?MODULE, monitor_gate}, {Owner, before}),
    Request = request(Owner, Fixture, 10000),
    receive {monitor_held, Owner, before} -> ok
    after 5000 -> error(monitor_barrier_missing) end,
    Sup = whereis(gproc_sup), Server = whereis(gproc),
    ServerRef = monitor(process, Server),
    ok = sys:suspend(Sup), exit(Server, kill),
    await_down(ServerRef, Server, killed),
    Owner ! {release_monitor, self()},
    receive {'DOWN', OwnerRef, process, Owner, Reason} ->
        ?assertMatch({noproc, _}, Reason)
    after 5000 -> error(owner_stranded_on_unavailable_registry) end,
    ?assertMatch({error, _}, gen_server:wait_response(Request, 1000)),
    ?assert(is_process_alive(Holder)),
    ?assertEqual(Holder, quod_reg:where(writer_key(Identity))),
    ?assertNot(filelib:is_file(log_path(Root, Identity))),
    ok = sys:resume(Sup), Holder ! stop, ok.

follow_cancel_case(Root) ->
    Fixture = fixture(), Identity = identity(Fixture),
    Holder = holder(Identity),
    Owner = start_owner(Root, fetch(Fixture)),
    trace_owner(Owner),
    ok = quod_foreign_log:observe_candidate(
           Identity, {maps:get(pub, Fixture), {"127.0.0.1", 31997}}),
    install_registration_barrier(),
    persistent_term:put({?MODULE, registration_gate}, writer_key(Identity)),
    {ok, Follow} = quod_foreign_log:follow(Identity),
    Worker = receive {registration_held, W} -> W
             after 5000 -> error(follow_registration_not_started) end,
    %% Queue the exact sibling while the real follow attempt is still active,
    %% before its first failed atomic registration parks the queue head.
    Sibling = request(Owner, Fixture, 10000),
    #{active := #{ref := FollowJob, worker := Worker},
      waiting := [#{ref := SiblingJob, wait_reason := runnable}]} = lifecycle(Owner, Identity),
    persistent_term:erase({?MODULE, registration_gate}),
    Worker ! {release_registration, self()},
    ?assertEqual({FollowJob, Worker}, await_denial(Owner)),
    #{active := none,
      waiting := [#{ref := FollowJob, wait_reason := custody},
                   #{ref := SiblingJob, wait_reason := runnable}]} = lifecycle(Owner, Identity),
    [QueuedFollow, _] = queue:to_list(history_field(Owner, Identity, waiting)),
    {custody, FollowMonitor} = field(queued_request, parked, QueuedFollow),
    ?assert(lists:member({Owner, FollowMonitor, info}, name_monitors(Holder, Identity))),
    ok = quod_foreign_log:unfollow(Follow),
    State = lifecycle(Owner, Identity),
    %% Fail immediately on the former stranded runnable sibling, rather than
    %% use a sleep or registry release to hide the missing dispatch edge.
    Dispatched = case State of
        #{active := #{ref := SiblingJob}, waiting := []} -> true;
        #{active := none, waiting := [#{ref := SiblingJob, wait_reason := custody}]} -> true;
        _ -> false
    end,
    ?assert(Dispatched),
    {SiblingJob, _} = await_park(Owner, Identity),
    {custody, SiblingMonitor} = queued_field(Owner, Identity, parked),
    ?assertNotEqual(FollowMonitor, SiblingMonitor),
    ?assertNot(lists:member({Owner, FollowMonitor, info}, name_monitors(Holder, Identity))),
    ?assert(lists:member({Owner, SiblingMonitor, info}, name_monitors(Holder, Identity))),
    Owner ! {gproc, unreg, FollowMonitor, quod_reg:name(writer_key(Identity))},
    ?assertEqual({custody, SiblingMonitor}, queued_field(Owner, Identity, parked)),
    ?assertNot(filelib:is_file(log_path(Root, Identity))),
    Holder ! stop,
    assert_verified(Sibling),
    ?assertEqual(0, map_size(history_field(Owner, Identity, consumers))),
    stop_owner(Owner), ok.

name_monitors(Holder, Identity) ->
    [{_, Options}] = ets:lookup(gproc, {Holder, quod_reg:name(writer_key(Identity))}),
    case Options of r -> []; _ -> proplists:get_value(monitor, Options, []) end.

cancel_denied_case(Root, source_down) ->
    %% The old historical-local job (and therefore its custody-denial race)
    %% no longer exists. Pin that absence against real occupied custody, and
    %% keep the source-death validity check on the direct reader itself.
    Fixture = quod_foreign_log_tests:membership_after_finalize_fixture(
                <<"foreign:custody:direct-borrow">>),
    Identity = identity(Fixture), Holder = holder(Identity),
    {SourcePid, SourceMonitor, View} =
        quod_foreign_log_tests:start_local_borrow_source(
            filename:join(Root, "source"), Fixture),
    CacheRoot = filename:join(Root, "cache"),
    Owner = start_owner(CacheRoot, fun(_, _, _, _, _) -> error(local_read_used_network) end),
    try
        ?assertMatch({ok, #{phase := finalize}},
            quod_foreign_log:verify_local(View, maps:get(ref, Fixture), finalize, infinity)),
        {Reader, Token} = quod_foreign_log_tests:hold_direct_local(
            View, maps:get(ref, Fixture), infinity, after_read),
        try
            ?assertEqual(#{}, gen_server:call(Owner, test_lifecycle_state)),
            exit(SourcePid, kill), await_down(SourceMonitor, SourcePid, killed),
            Reader ! {release_local_read, Token},
            ?assertEqual({error, retry},
                quod_foreign_log_tests:receive_local_borrow_result(Reader)),
            ?assertEqual(#{}, gen_server:call(Owner, test_lifecycle_state)),
            ?assertEqual(Holder, quod_reg:where(writer_key(Identity))),
            ?assertNot(lists:keymember(Owner, 1, name_monitors(Holder, Identity))),
            ?assertNot(filelib:is_file(log_path(CacheRoot, Identity)))
        after exit(Reader, kill)
        end
    after
        exit(SourcePid, kill), demonitor(SourceMonitor, [flush]),
        Holder ! stop, stop_owner(Owner)
    end,
    ok;
cancel_denied_case(Root, follow_cancel) ->
    Fixture = fixture(), Identity = identity(Fixture), Holder = holder(Identity),
    CacheRoot = filename:join(Root, "cache"),
    Owner = start_owner(CacheRoot, fetch(Fixture)),
    trace_owner(Owner),
    install_registration_barrier(),
    persistent_term:put({?MODULE, registration_gate}, writer_key(Identity)),
    ok = quod_foreign_log:observe_candidate(
           Identity, {maps:get(pub, Fixture), {"127.0.0.1", 31997}}),
    {ok, Follow} = quod_foreign_log:follow(Identity),
    Worker = receive {registration_held, W} -> W
             after 5000 -> error(canceled_worker_did_not_enter_registration) end,
    #{active := #{ref := Job, worker := Worker}} = lifecycle(Owner, Identity),
    WorkerRef = monitor(process, Worker),
    ok = sys:suspend(Owner),
    CancelRequest = gen_server:send_request(Owner, {unfollow, Follow}),
    persistent_term:erase({?MODULE, registration_gate}),
    Worker ! {release_registration, self()},
    await_down(WorkerRef, Worker, normal),
    _ = sys:get_state(Owner),
    receive {trace, Owner, 'receive', {'DOWN', _, process, Worker, normal}} -> ok
    after 5000 -> error(owner_worker_down_delivery_not_observed) end,
    {messages, Messages} = process_info(Owner, messages),
    ?assertEqual([cancel, denied, worker_down],
                 [Tag || Message <- Messages,
                         Tag <- [cancel_message_tag(Message, Identity, Job, Worker)],
                         Tag =/= other]),
    ok = sys:resume(Owner),
    State = gen_server:call(Owner, test_lifecycle_state),
    %% A name holder still lives, so no release can rescue a wrongly requeued
    %% follow. Only the real worker DOWN may retire this cancelled job.
    Row = maps:get(Identity, State, #{active => none, waiting => []}),
    ?assertMatch(#{active := none, waiting := []}, Row),
    ?assertEqual({reply, ok}, gen_server:wait_response(CancelRequest, 1000)),
    ?assert(is_process_alive(Holder)),
    ?assertEqual(Holder, quod_reg:where(writer_key(Identity))),
    ?assertNot(lists:keymember(Owner, 1, name_monitors(Holder, Identity))),
    ?assertNot(filelib:is_file(log_path(CacheRoot, Identity))),
    Holder ! stop, stop_owner(Owner), ok.

cancel_message_tag({{borrow_down, Identity, Job}, _, process, _, _}, Identity, Job, _) -> cancel;
cancel_message_tag({'$gen_call', _, {unfollow, _}}, _, _, _) -> cancel;
cancel_message_tag({cache_custody_denied, Job, Worker}, _, Job, Worker) -> denied;
cancel_message_tag({'DOWN', _, process, Worker, _}, _, _, Worker) -> worker_down;
cancel_message_tag(_, _, _, _) -> other.

custody_fifo_case(Root, Mode) ->
    Fixture = fixture(), Identity = identity(Fixture),
    Holder = holder(Identity),
    Owner = start_owner(Root, fetch(Fixture)),
    trace_owner(Owner),
    Head = request(Owner, Fixture, 10000),
    {HeadJob, Denied} = await_park(Owner, Identity),
    await_dead(Denied),
    {custody, HeadMonitor} = queued_field(Owner, Identity, parked),
    install_registration_barrier(),
    persistent_term:put({?MODULE, registration_gate}, writer_key(Identity)),
    1 = erlang:trace(Owner, true, [procs]),
    Ref = maps:get(ref, Fixture),
    Contact = {maps:get(pub, Fixture), {"127.0.0.1", 31997}},
    Work = case Mode of
        direct -> {verify, element(1, Contact), element(2, Contact), Ref, entry, 10000};
        routed -> {verify_reference, Ref, entry, Contact, none, 10000}
    end,
    Second = send_request(Owner, Work, 10000),
    #{active := none,
      waiting := [#{ref := HeadJob, wait_reason := custody},
                   #{ref := SecondJob, wait_reason := runnable}]} = lifecycle(Owner, Identity),
    [HeadRow, _] = queue:to_list(history_field(Owner, Identity, waiting)),
    ?assertEqual({custody, HeadMonitor}, field(queued_request, parked, HeadRow)),
    Barrier = erlang:trace_delivered(Owner),
    receive {trace_delivered, Owner, Barrier} -> ok
    after 5000 -> error(spawn_trace_barrier_missing) end,
    receive {trace, Owner, spawn, _, _} -> error(arrival_spawned_around_custody_head)
    after 0 -> ok end,
    receive {registration_held, _} -> error(arrival_attempted_registration_around_custody_head)
    after 0 -> ok end,
    ?assertNot(filelib:is_file(log_path(Root, Identity))),
    Holder ! stop,
    FirstWorker = receive {registration_held, W1} -> W1
                  after 5000 -> error(custody_head_not_dispatched_on_release) end,
    ?assertMatch(#{active := #{ref := HeadJob, worker := FirstWorker},
                   waiting := [#{ref := SecondJob}]}, lifecycle(Owner, Identity)),
    FirstWorker ! {release_registration, self()},
    assert_verified(Head),
    await_name_free(Identity),
    SecondWorker = receive {registration_held, W2} -> W2
                   after 5000 -> error(custody_sibling_not_dispatched) end,
    ?assertNotEqual(FirstWorker, SecondWorker),
    ?assertMatch(#{active := #{ref := SecondJob, worker := SecondWorker}, waiting := []},
                 lifecycle(Owner, Identity)),
    persistent_term:erase({?MODULE, registration_gate}),
    SecondWorker ! {release_registration, self()},
    ?assertMatch({reply, {ok, #{slot := 2}}}, gen_server:wait_response(Second, 10000)),
    stop_owner(Owner), ok.

fixture() -> quod_foreign_log_tests:foreign_fixture(
               <<"foreign:custody:", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>).
identity(F) -> {maps:get(ns, F), maps:get(anchor, F)}.
writer_key(Identity) -> {foreign_cache_writer, Identity}.
fetch(F) -> quod_foreign_log_tests:chain_fetch(maps:get(ns, F), maps:get(chain, F)).

start_owner(Root, Fetch) ->
    %% Install tracing before init: retained-cache custody acquisition is now
    %% startup work and may legitimately finish before start_link returns.
    Parent = self(), Tag = make_ref(),
    {Launcher, Monitor} = spawn_monitor(fun() ->
        receive {start, Tag} -> ok end,
        {ok, Pid} = quod_foreign_log:start_link(
            #{cache_dir => Root, fetch_fun => Fetch, page_timeout_ms => 1000}),
        unlink(Pid), Parent ! {Tag, Pid}
    end),
    1 = erlang:trace(Launcher, true, ['receive', set_on_spawn, {tracer, Parent}]),
    Launcher ! {start, Tag},
    receive
        {Tag, Pid} ->
            receive {'DOWN', Monitor, process, Launcher, normal} -> ok end,
            Pid;
        {'DOWN', Monitor, process, Launcher, Reason} -> error({owner_start_failed, Reason})
    end.
stop_owner(Owner) -> gen_server:stop(Owner).

request(Owner, F, Timeout) ->
    send_request(Owner, {verify, maps:get(pub, F), {"127.0.0.1", 31997},
                         maps:get(ref, F), finalize, Timeout}, Timeout).
send_request(Owner, Request, Timeout) ->
    gen_server:send_request(Owner, {verification, quod_time:mono_ms() + Timeout,
                                    undefined, erlang:monotonic_time(), Request}).
assert_verified(Request) ->
    ?assertMatch({reply, {ok, #{slot := 2, phase := finalize}}},
                 gen_server:wait_response(Request, 10000)).
seed_genesis(Owner, F) ->
    Entry = hd(maps:get(chain, F)),
    {batch, [Genesis]} = element(3, quod_ledger:entry_view(Entry)),
    {ok, Ref} = quod_dtx:certified_entry_ref(identity(F), Entry, Genesis),
    Request = send_request(Owner,
      {verify, maps:get(pub, F), {"127.0.0.1", 31997}, Ref, transaction, 5000}, 5000),
    ?assertMatch({reply, {ok, #{slot := 1}}}, gen_server:wait_response(Request, 10000)).

holder(Identity) ->
    Parent = self(),
    Pid = spawn(fun() ->
        true = quod_reg:reg(writer_key(Identity)),
        Parent ! {holder_ready, self()}, holder_loop()
    end),
    receive {holder_ready, Pid} -> Pid
    after 5000 -> error(holder_not_registered) end.
holder_loop() ->
    receive
        stop -> ok;
        {repair, Parent, Path, Bytes} ->
            ok = file:write_file(Path, Bytes), Parent ! {repaired, self()}, holder_loop()
    end.
await_name_free(Identity) ->
    Name = quod_reg:name(writer_key(Identity)),
    Ref = quod_reg:monitor_name(writer_key(Identity), info),
    receive {gproc, unreg, Ref, Name} -> ok
    after 5000 -> error(name_not_released) end.

trace_owner(Owner) -> 1 = erlang:trace(Owner, true, ['receive']), ok.
await_park(Owner, Identity) ->
    {Job, Worker} = await_denial(Owner),
    #{active := none, waiting := [Head | Tail]} = lifecycle(Owner, Identity),
    ?assertMatch(#{ref := Job, wait_reason := custody}, Head),
    case maps:get(work, Head) of
        {initialize, Identity, startup} ->
            ?assertMatch([#{wait_reason := runnable, callers := [_]}], Tail);
        _ -> ?assertEqual([], Tail)
    end,
    {Job, Worker}.
await_denial(Owner) ->
    receive
        {trace, Owner, 'receive', {cache_custody_denied, J, W}} -> {J, W}
    after 5000 -> error(custody_denial_missing) end.
await_done(Owner, Job) ->
    receive
        {trace, Owner, 'receive', {foreign_worker_done, Job, {ok, _}, _}} -> ok;
        {trace, Owner, 'receive', {foreign_worker_done, _Other, _, _}} -> await_done(Owner, Job)
    after 10000 -> error(callerless_job_did_not_finish) end.
lifecycle(Owner, Identity) -> maps:get(Identity, gen_server:call(Owner, test_lifecycle_state)).
history_field(Owner, Identity, Field) ->
    Histories = field(s, histories, sys:get_state(Owner)),
    field(history, Field, maps:get(Identity, Histories)).
queued_field(Owner, Identity, Field) ->
    [Q] = queue:to_list(history_field(Owner, Identity, waiting)),
    field(queued_request, Field, Q).
field(Record, Field, Tuple) ->
    Forms = original_forms(quod_foreign_log),
    [Fields] = [Fs || {attribute, _, record, {Tag, Fs}} <- Forms, Tag =:= Record],
    Names = [record_field_name(F) || F <- Fields],
    ?assertEqual(Record, element(1, Tuple)),
    element(1 + index_of(Field, Names, 1), Tuple).
record_field_name({typed_record_field, F, _}) -> record_field_name(F);
record_field_name({record_field, _, {atom, _, Name}}) -> Name;
record_field_name({record_field, _, {atom, _, Name}, _}) -> Name.
index_of(Name, [Name | _], N) -> N;
index_of(Name, [_ | Rest], N) -> index_of(Name, Rest, N + 1).

log_path(Root, Identity) -> filename:join(
    quod_ledger_store:ns_dir(Root, quod_foreign_log:cache_namespace(Identity)), "log.0001").
file_summary(Path) ->
    {ok, Info} = file:read_file_info(Path), {ok, Bytes} = file:read_file(Path),
    #{path => Path, inode => Info#file_info.inode, bytes => byte_size(Bytes),
      hash => crypto:hash(sha256, Bytes)}.
store_summary(Store) ->
    (file_summary(filename:join(element(2, Store), "log.0001")))#{
      offset => element(7, Store), last_index => element(6, Store)}.
await_down(Ref, Pid, Reason) ->
    receive {'DOWN', Ref, process, Pid, Reason} -> ok
    after 5000 -> error(expected_process_death_missing) end.
await_dead(Pid) ->
    Ref = monitor(process, Pid),
    receive {'DOWN', Ref, process, Pid, _} -> ok
    after 5000 -> error(denied_worker_survived) end.
release_watcher(Watcher, Ref, Worker) ->
    Watcher ! {release_watcher, self()}, await_down(Ref, Worker, killed).
await_before() ->
    receive {append_before, W, S, Summary} -> {W, S, Summary}
    after 5000 -> error(append_barrier_missing) end.
await_after(Worker) ->
    receive {append_after, Worker, Summary} -> Summary
    after 5000 -> error(original_append_did_not_complete) end.

%% All instrumentation below is peer-local, source-derived, and checked for
%% a non-vacuous match. It adds scheduling barriers around ORIGINAL bodies.
mutation(Module, Function) ->
    quod_custody_test_controller ! {mutation, self(), Module, Function}, ok.
mutations() -> mutations([]).
mutations(Acc) ->
    receive {mutation, Pid, M, F} -> mutations([{Pid, M, F} | Acc])
    after 0 -> lists:reverse(Acc) end.
before_append(Store, _Entries) ->
    case persistent_term:get({?MODULE, append_gate}, false) of
        true ->
            C = whereis(quod_custody_test_controller),
            C ! {append_before, self(), Store, store_summary(Store)},
            receive {release_append, C} -> ok after 15000 -> error(append_gate_expired) end;
        false -> ok
    end.
after_append(_Store, {ok, NewStore}) ->
    case persistent_term:get({?MODULE, append_gate}, false) of
        true ->
            C = whereis(quod_custody_test_controller),
            C ! {append_after, self(), store_summary(NewStore)},
            receive {finish_append, C} -> ok after 15000 -> error(append_finish_expired) end;
        false -> ok
    end.
watcher_ready(Owner, Worker) ->
    case persistent_term:get({?MODULE, held_owner}, none) of
        Owner ->
            C = whereis(quod_custody_test_controller),
            C ! {watcher_held, Owner, Worker, self()},
            receive {release_watcher, C} -> ok after 20000 -> error(watcher_gate_expired) end;
        _ -> ok
    end.
monitor_barrier(Stage, {foreign_cache_writer, _}) ->
    case persistent_term:get({?MODULE, monitor_gate}, none) of
        {Pid, Stage} when Pid =:= self() ->
            C = whereis(quod_custody_test_controller), C ! {monitor_held, self(), Stage},
            receive {release_monitor, C} -> ok after 10000 -> error(monitor_gate_expired) end;
        _ -> ok
    end;
monitor_barrier(_, _) -> ok.
registration_barrier(Key) ->
    case persistent_term:get({?MODULE, registration_gate}, none) of
        Key ->
            C = whereis(quod_custody_test_controller), C ! {registration_held, self()},
            receive {release_registration, C} -> ok
            after 10000 -> error(registration_gate_expired) end;
        _ -> ok
    end.
watcher_only_register(_Key) -> true.
watcher_only_claim(_Identity, _Worker) -> true.

install_mutation_observers() ->
    lists:foreach(fun({Module, Targets}) ->
        Forms = original_forms(Module),
        Found = [{F, A} || {function, _, F, A, _} <- Forms, lists:member({F, A}, Targets)],
        ?assertEqual(lists:sort(Targets), lists:sort(Found)),
        New = [case Form of
            {function, L, F, A, Cs} ->
                case lists:member({F, A}, Targets) of
                    true -> {function, L, F, A,
                      [{clause, CL, Args, Guards,
                        [remote(mutation, [{atom, L, Module}, {atom, L, F}]) | Body]}
                       || {clause, CL, Args, Guards, Body} <- Cs]};
                    false -> Form
                end;
            _ -> Form
        end || Form <- Forms],
        load_forms(Module, observe_cache_deletions(Module, New))
    end, [{quod_ledger_store, [{open, 3}, {resume, 1}, {trim, 4}]},
          {quod_dtx_phase_index, [{open, 2}, {resume, 1}, {cleanup, 3}, {close, 1}]},
          {quod_foreign_log, [{cleanup_cache_temps, 1}]}]).

observe_cache_deletions(quod_foreign_log, Forms) ->
    put(deletion_observers, 0),
    New = [case Form of
      %% Projection-materializer startup owns a separate scratch subtree,
      %% not the anchored certified cache whose custody is being tested.
      {function, _, cleanup_projection_dirs, 1, _} -> Form;
      _ -> walk(fun
        ({call, L, {remote, _, {atom, _, file}, {atom, _, F}}, [_]} = Call)
          when F =:= delete; F =:= del_dir_r ->
            put(deletion_observers, get(deletion_observers) + 1),
            {block, L, [remote(mutation, [{atom, L, file}, {atom, L, F}]), Call]};
        (Other) -> Other
      end, Form)
    end || Form <- Forms],
    ?assert(erase(deletion_observers) > 0), New;
observe_cache_deletions(_, Forms) -> Forms.

install_append_barriers() ->
    Module = quod_ledger_store,
    Forms = current_forms(Module),
    [{function, L, append, 2, [Empty, {clause, CL, Args, Guards, Body}]}] =
      [F || F = {function, _, append, 2, _} <- Forms],
    Result = {var, CL, 'CustodyAppendResult'},
    NewBody = [remote(before_append, [{var, CL, 'S'}, {var, CL, 'Entries'}]),
               {match, CL, Result, {block, CL, Body}},
               remote(after_append, [{var, CL, 'S'}, Result]), Result],
    New = {function, L, append, 2, [Empty, {clause, CL, Args, Guards, NewBody}]},
    load_forms(Module, [case F of {function, _, append, 2, _} -> New; _ -> F end || F <- Forms]).

install_watcher_barrier() ->
    Forms = original_forms(quod_process),
    put(watcher_matches, 0),
    New = walk(fun({'receive', L, Cs}) ->
        put(watcher_matches, get(watcher_matches) + 1),
        {block, L, [remote(watcher_ready, [{var, L, 'Owner'}, {var, L, 'Worker'}]),
                    {'receive', L, Cs}]}; (Other) -> Other end, Forms),
    ?assertEqual(1, erase(watcher_matches)), load_forms(quod_process, New).

install_monitor_barriers() ->
    Forms = original_forms(quod_reg),
    [{function, L, monitor_name, 2, [{clause, CL, Args, Guards, Body}]}] =
        [F || F = {function, _, monitor_name, 2, _} <- Forms],
    Result = {var, CL, 'CustodyMonitorResult'},
    Key = {var, CL, 'Key'},
    New = {function, L, monitor_name, 2, [{clause, CL, Args, Guards,
      [remote(monitor_barrier, [{atom, CL, before}, Key]),
       {match, CL, Result, {block, CL, Body}},
       remote(monitor_barrier, [{atom, CL, after_monitor}, Key]), Result]}]},
    load_forms(quod_reg, [case F of {function, _, monitor_name, 2, _} -> New; _ -> F end || F <- Forms]).

install_registration_barrier() ->
    Forms = original_forms(quod_reg),
    [{function, L, reg, 1, [{clause, CL, Args, Guards, Body}]}] =
        [F || F = {function, _, reg, 1, _} <- Forms],
    New = {function, L, reg, 1, [{clause, CL, Args, Guards,
                                [remote(registration_barrier, Args) | Body]}]},
    load_forms(quod_reg, [case F of {function, _, reg, 1, _} -> New; _ -> F end || F <- Forms]).

install_watcher_only_mutant() ->
    Forms = current_forms(quod_foreign_log),
    put(custody_mutations, 0),
    New = walk(fun
      ({call, L, {remote, _, {atom, _, quod_reg}, {atom, _, reg}},
        [{call, _, {atom, _, cache_writer_key}, _} = Key]}) ->
          put(custody_mutations, get(custody_mutations) + 1),
          remote(watcher_only_register, [Key], L);
      ({op, L, '=:=', {call, _, {remote, _, {atom, _, quod_reg}, {atom, _, where}},
         [{call, _, {atom, _, cache_writer_key}, [Identity]}]}, Worker}) ->
          put(custody_mutations, get(custody_mutations) + 1),
          remote(watcher_only_claim, [Identity, Worker], L);
      (Other) -> Other
    end, Forms),
    ?assertEqual(2, erase(custody_mutations)), load_forms(quod_foreign_log, New).

original_forms(Module) ->
    case persistent_term:get({?MODULE, original, Module}, undefined) of
        undefined ->
            {ok, {Module, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
                beam_lib:chunks(code:which(Module), [abstract_code]),
            persistent_term:put({?MODULE, original, Module}, Forms), Forms;
        Forms -> Forms
    end.
current_forms(Module) -> persistent_term:get({?MODULE, current, Module}, original_forms(Module)).
load_forms(Module, Forms) ->
    Compiled = compile:forms(Forms, [binary, debug_info, return_errors, return_warnings]),
    Beam = case Compiled of
        {ok, Module, Bin} -> Bin;
        {ok, Module, Bin, _} -> Bin;
        _ -> error({peer_instrumentation_compile_failed, Module})
    end,
    {module, Module} = code:load_binary(Module, atom_to_list(Module) ++ ".custody-test", Beam),
    persistent_term:put({?MODULE, current, Module}, Forms), ok.
remote(Function, Args) -> remote(Function, Args, 1).
remote(Function, Args, L) ->
    {call, L, {remote, L, {atom, L, ?MODULE}, {atom, L, Function}}, Args}.
walk(Fun, Tuple) when is_tuple(Tuple) ->
    Fun(list_to_tuple([walk(Fun, X) || X <- tuple_to_list(Tuple)]));
walk(Fun, List) when is_list(List) -> [walk(Fun, X) || X <- List];
walk(Fun, Other) -> Fun(Other).
