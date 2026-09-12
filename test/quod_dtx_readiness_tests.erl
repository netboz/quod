-module(quod_dtx_readiness_tests).
-include_lib("eunit/include/eunit.hrl").

%% Real signing-journal owner rows, reducer-derived projections, monitored
%% coordinator and SDK. The inherited trace fixture supplies a pre-verified
%% snapshot, not consensus admission; endpoint/consensus tests remain separate.

pending_begin_survives_sync_and_prolog_unreadiness_test() ->
    retained_owner(pending).

committed_begin_survives_sync_and_prolog_unreadiness_test() ->
    retained_owner(committed).

retained_owner(Kind) ->
    with_parked(fun(F, Running) ->
        Before = case Kind of
            pending -> Running;
            committed ->
                Adopted = quod_dtx_coordinator_trace_tests:adopt(F, Running),
                Projected = quod_dtx_coordinator_trace_tests:projection_state(F, 'begin', Adopted),
                quod_simplex:test_state_set(prolog_ready, false, Projected)
        end,
        Row = row(F, Before), Pid = maps:get(pid, Row),
        Snapshot = quod_dtx_coordinator:test_state(Pid),
        Paused0 = quod_simplex:test_state_set(sync, unconfirmed, Before),
        Paused = quod_simplex:test_reconcile_dtx_coordinator(Paused0),
        ?assertEqual(Row, row(F, Paused)),
        ok = quod_simplex:test_notify_dtx_coordinator_progress(Before, Paused),
        ?assertEqual(Snapshot, quod_dtx_coordinator:test_state(Pid)),
        SyncReady = quod_simplex:test_state_set(sync, ready, Paused),
        StillPaused = quod_simplex:test_reconcile_dtx_coordinator(SyncReady),
        ?assertEqual(Row, row(F, StillPaused)),
        ok = quod_simplex:test_notify_dtx_coordinator_progress(Paused, StillPaused),
        ?assertEqual(Snapshot, quod_dtx_coordinator:test_state(Pid)),
        ?assert(is_process_alive(Pid)),
        assert_no_notifications(Pid),
        quod_dtx_coordinator_trace_tests:assert_no_root(),
        ?assertEqual([], quod_dtx_coordinator_trace_tests:end_calls(get(attempt_trace))),
        %% This is a real loss of local admission, not temporary readiness.
        Revoked = quod_simplex:test_state_set(author_admissions, #{}, StillPaused),
        Retired = quod_simplex:test_reconcile_dtx_coordinator(Revoked),
        ?assertEqual(#{}, quod_simplex:test_dtx_coordinator_state(Retired)),
        wait_dead(Pid),
        _ = quod_dtx_coordinator_trace_tests:root(),
        ?assertEqual(1, length(quod_dtx_coordinator_trace_tests:end_calls(get(attempt_trace)))),
        Retired
    end).

initial_execution_waits_for_exact_owner_capability_test() ->
    with_parked(fun(F, Running) ->
        #{pid := Pid, monitor := Monitor} = row(F, Running),
        ?assertMatch(#{execution_ready := false, wave := none},
                     quod_dtx_coordinator:test_state(Pid)),
        assert_no_notifications(Pid),
        Other = spawn(fun() -> receive stop -> ok end end),
        try
            Pid ! {local_dtx_progress, Other, maps:get(origin, F), 1, true},
            ?assertMatch(#{execution_ready := false}, quod_dtx_coordinator:test_state(Pid)),
            assert_no_notifications(Pid)
        after Other ! stop
        end,
        Ready = quod_simplex:test_state_set(prolog_ready, true, Running),
        ok = quod_simplex:test_notify_dtx_coordinator_progress(Running, Ready),
        GroupId = maps:get(group_id, F), Complete = maps:get(complete_ref, F),
        receive {dtx_coordinator, Pid, GroupId, {done, Complete}} -> ok
        after 1000 -> error(ready_owner_did_not_complete) end,
        ?assertEqual(normal, quod_dtx_coordinator_trace_tests:wait_down(Pid, Monitor)),
        ?assertEqual(1, length(quod_dtx_coordinator_trace_tests:attempts(get(attempt_trace)))),
        Ready
    end).

terminal_execution_waits_for_readiness_test() ->
    with_parked(terminal_snapshot, fun(F, Running) ->
        #{pid := Pid} = row(F, Running),
        GroupId = maps:get(group_id, F),
        Before = quod_dtx_coordinator:test_state(Pid),
        assert_no_notifications(Pid),
        Previous = application:get_env(quod, dtx_test_phase_barrier),
        application:set_env(quod, dtx_test_phase_barrier, {hold, terminal}),
        try
            Ready = quod_simplex:test_state_set(prolog_ready, true, Running),
            ok = quod_simplex:test_notify_dtx_coordinator_progress(Running, Ready),
            receive {dtx_coordinator, Pid, GroupId, {terminal, Terminal}} ->
                ?assertMatch(#{verdict := abort}, Terminal)
            after 1000 -> error(ready_owner_did_not_release_terminal)
            end,
            ?assertMatch(#{execution_ready := false, wave := none}, Before),
            ?assertEqual(row(F, Running), row(F, Ready)),
            Ready
        after
            case Previous of
                undefined -> application:unset_env(quod, dtx_test_phase_barrier);
                {ok, Value} -> application:set_env(quod, dtx_test_phase_barrier, Value)
            end
        end
    end).

with_parked(Fun) -> with_parked(complete_snapshot, Fun).
with_parked(SnapshotKey, Fun) ->
    quod_dtx_coordinator_trace_tests:with_case(fun(F, S0, Parent) ->
        Key = dtx_test_observation_state,
        Previous = application:get_env(quod, Key),
        application:set_env(quod, Key,
            {maps:get(group_id, F), maps:get(SnapshotKey, F), #{}}),
        try
            quod_dtx_coordinator_trace_tests:with_attempt_trace(fun(Trace) ->
                put(attempt_trace, Trace),
                Seed = quod_simplex:test_seed_dtx_submission(maps:get(begin_control, F), [], S0),
                Running = quod_simplex:test_start_dtx_coordinator_worker(
                    maps:get('begin', F), maps:get(group_ref, F), none, Parent, Seed),
                Pid = maps:get(pid, row(F, Running)),
                try Fun(F, Running) of
                    Installed ->
                        _ = quod_simplex:test_stop_dtx_coordinator(Installed)
                catch Class:Reason:Stack ->
                    _ = quod_simplex:test_stop_dtx_coordinator(Running),
                    erlang:raise(Class, Reason, Stack)
                after
                    wait_dead(Pid), erase(attempt_trace)
                end
            end)
        after
            case Previous of
                undefined -> application:unset_env(quod, Key);
                {ok, Value} -> application:set_env(quod, Key, Value)
            end
        end
    end).

row(F, S) -> quod_dtx_coordinator_trace_tests:owner_row(F, S).
wait_dead(Pid) ->
    M = monitor(process, Pid),
    _ = quod_dtx_coordinator_trace_tests:wait_down(Pid, M), ok.
assert_no_notifications(Pid) ->
    receive {dtx_coordinator, Pid, _, _} = Event -> error({executed_while_parked, Event})
    after 0 -> ok
    end.
