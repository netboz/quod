-module(quod_dtx_readiness_tests).
-include_lib("eunit/include/eunit.hrl").

%% Real signed/unsigned signing-journal rows, reducer-derived projections,
%% monitored coordinator and SDK. The inherited trace fixture supplies a
%% pre-verified Vote/Resolve/Complete snapshot (including AM3), not consensus
%% admission. A real store supplies read capability, not a history-replay proof.

pending_vote_survives_sync_and_prolog_unreadiness_test_() ->
    [{atom_to_list(Kind), fun() -> retained_owner(Kind) end}
     || Kind <- [signed_pending, unsigned_pending]].

committed_vote_survives_sync_and_prolog_unreadiness_test() ->
    retained_owner(committed).

retained_owner(Kind) ->
    SeedKind = case Kind of committed -> signed_pending; _ -> Kind end,
    with_parked(SeedKind, complete_snapshot, fun(F, Running) ->
        Before = case Kind of
            committed ->
                Adopted = quod_dtx_coordinator_trace_tests:adopt(F, Running),
                quod_simplex:test_state_set(prolog_ready, false, Adopted);
            _ -> Running
        end,
        Row = row(F, Before), Pid = maps:get(pid, Row),
        Snapshot = quod_dtx_coordinator:test_state(Pid),
        ?assertMatch(#{execution_ready := false, wave := none}, Snapshot),
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
        %% Admission loss retires committed takeover duty. Pre-vote source
        %% custody (signed OR unsigned) still owes delivery to current signers;
        %% it must keep this owner without acquiring local voting capability.
        Revoked = quod_simplex:test_state_set(author_admissions, #{}, StillPaused),
        Reconciled = quod_simplex:test_reconcile_dtx_coordinator(Revoked),
        Retired = case Kind of
            committed -> Reconciled;
            _ ->
                ?assertEqual(Row, row(F, Reconciled)),
                ok = quod_simplex:test_notify_dtx_coordinator_progress(StillPaused, Reconciled),
                ?assertEqual(Snapshot, quod_dtx_coordinator:test_state(Pid)),
                assert_no_notifications(Pid),
                quod_dtx_coordinator_trace_tests:assert_no_root(),
                ?assertEqual([], quod_dtx_coordinator_trace_tests:end_calls(get(attempt_trace))),
                %% Explicit owner stop still closes this pending attempt once.
                quod_simplex:test_stop_dtx_coordinator(Reconciled)
        end,
        ?assertEqual(#{}, quod_simplex:test_dtx_coordinator_state(Retired)),
        wait_dead(Pid),
        _ = quod_dtx_coordinator_trace_tests:root(),
        ?assertEqual(1, length(quod_dtx_coordinator_trace_tests:end_calls(get(attempt_trace)))),
        Retired
    end).

initial_execution_waits_for_exact_owner_capability_test_() ->
    [{atom_to_list(Kind), fun() -> exact_owner_capability(Kind) end}
     || Kind <- [signed_pending, unsigned_pending]].

exact_owner_capability(Kind) ->
    with_parked(Kind, complete_snapshot, fun(F, Running) ->
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
        %% Matching owner but wrong committed identity is not a capability.
        Pid ! {local_dtx_progress, self(), maps:get(remote, F), 1, true},
        ?assertMatch(#{execution_ready := false, wave := none},
                     quod_dtx_coordinator:test_state(Pid)),
        assert_no_notifications(Pid),
        PrologReady = quod_simplex:test_state_set(prolog_ready, true, Running),
        %% Write readiness alone must not stand in for committed-read readiness.
        ?assert(quod_simplex:test_dtx_endpoint_ready({submit, <<1:128>>, <<>>}, PrologReady)),
        ?assertNot(read_ready(F, PrologReady)),
        ok = quod_simplex:test_notify_dtx_coordinator_progress(Running, PrologReady),
        ?assertMatch(#{execution_ready := false, wave := none},
                     quod_dtx_coordinator:test_state(Pid)),
        assert_no_notifications(Pid),
        %% With a real reader but sync still unavailable the worker stays put.
        Unconfirmed = quod_simplex:test_state_set(sync, unconfirmed,
          quod_simplex:test_state_set(store, maps:get(read_store, F), PrologReady)),
        ok = quod_simplex:test_notify_dtx_coordinator_progress(PrologReady, Unconfirmed),
        ?assertNot(read_ready(F, Unconfirmed)),
        ?assertMatch(#{execution_ready := false, wave := none},
                     quod_dtx_coordinator:test_state(Pid)),
        assert_no_notifications(Pid),
        %% Durable source work may resume without local signing authority.
        Ready = quod_simplex:test_state_set(author_admissions, #{},
          quod_simplex:test_state_set(sync, ready, Unconfirmed)),
        ?assert(read_ready(F, Ready)),
        ?assertNot(quod_simplex:test_dtx_endpoint_ready({submit, <<1:128>>, <<>>}, Ready)),
        ?assertEqual(row(F, Running), row(F, quod_simplex:test_reconcile_dtx_coordinator(Ready))),
        ok = quod_simplex:test_notify_dtx_coordinator_progress(Unconfirmed, Ready),
        GroupId = maps:get(group_id, F), Complete = maps:get(complete_ref, F),
        receive {dtx_coordinator, Pid, GroupId, {done, Complete}} -> ok
        after 1000 -> error(ready_owner_did_not_complete) end,
        ?assertEqual(normal, quod_dtx_coordinator_trace_tests:wait_down(Pid, Monitor)),
        ?assertEqual(1, length(quod_dtx_coordinator_trace_tests:attempts(get(attempt_trace)))),
        Ready
    end).

terminal_execution_waits_for_readiness_test() ->
    with_parked(signed_pending, terminal_snapshot, fun(F, Running) ->
        #{pid := Pid} = row(F, Running),
        GroupId = maps:get(group_id, F),
        Before = quod_dtx_coordinator:test_state(Pid),
        assert_no_notifications(Pid),
        Previous = application:get_env(quod, dtx_test_phase_barrier),
        application:set_env(quod, dtx_test_phase_barrier, {hold, terminal}),
        try
            Ready = quod_simplex:test_state_set(store, maps:get(read_store, F),
              quod_simplex:test_state_set(prolog_ready, true, Running)),
            ?assert(read_ready(F, Ready)),
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

with_parked(Kind, SnapshotKey, Fun) ->
    quod_dtx_coordinator_trace_tests:with_case(fun(F0, S0, Parent) ->
      with_read_store(F0, fun(Store) ->
        F = F0#{read_store => Store},
        Key = dtx_test_observation_state,
        Previous = application:get_env(quod, Key),
        application:set_env(quod, Key,
            {maps:get(group_id, F), maps:get(SnapshotKey, F), #{}}),
        try
            quod_dtx_coordinator_trace_tests:with_attempt_trace(fun(Trace) ->
                put(attempt_trace, Trace),
                Seed = seed(Kind, F, S0),
                Running = quod_simplex:test_start_dtx_coordinator_worker(
                    maps:get(own_row, F), Parent, Seed),
                Pid = maps:get(pid, row(F, Running)),
                try
                    ?assertEqual(row(F, Running), row(F,
                      quod_simplex:test_reconcile_dtx_coordinator(Running))),
                    Fun(F, Running)
                of
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
      end)
    end).

seed(Kind, F, S0) ->
    Journal0 = quod_simplex:test_signing_journal(S0),
    Control = maps:get(vote_control, F), Material = quod_atomic:control_material(Control),
    {group, _, _, Author, Admission, G} = maps:get(group_ref, F),
    {Journal, S1} = case Kind of
        signed_pending ->
            %% Explicit post-selection fixture, not unsigned admission signed
            %% merely to make a paused owner observable.
            {ok, Signed, Envelope} = quod_signing_journal:record_dtx(Journal0, Control),
            ?assertMatch(#{G := #{sequence := 1, envelope := Envelope, material := Material}},
                         quod_signing_journal:pending_dtx(Signed)),
            ?assertEqual(1, quod_signing_journal:dtx_floor(Signed, {Admission, Author})),
            {Signed, quod_simplex:test_seed_dtx_submission(Control, [], S0)};
        unsigned_pending ->
            {ok, Missing} = quod_signing_journal:record_dtx_intent(
              Journal0, quod_atomic:source_presentation(Material)),
            {ok, Bound} = quod_signing_journal:record_dtx_intent(Missing, Material),
            ?assertMatch(#{G := #{sequence := 0, envelope := none, material := Material}},
                         quod_signing_journal:pending_dtx(Bound)),
            ?assertEqual(0, quod_signing_journal:dtx_floor(Bound, {Admission, Author})),
            Restored = quod_simplex:test_restore_pending_dtx(S0, Bound),
            ?assertMatch(#{active := 1, reserved := 0},
                         quod_simplex:test_dtx_admission_state(Restored)),
            ?assertMatch(#{retained := 0}, quod_simplex:test_retained_dtx_state(Restored)),
            {Bound, Restored}
    end,
    quod_simplex:test_state_set(signing_journal, Journal, S1).

with_read_store(F, Fun) ->
    {Ns, _} = maps:get(origin, F),
    Dir = filename:join("/tmp", "quod_readiness_" ++
      binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    {ok, Store} = quod_ledger_store:open(Ns, Dir),
    try Fun(Store)
    after
        ok = quod_ledger_store:close(Store),
        ok = file:del_dir_r(Dir)
    end.

read_ready(F, S) ->
    quod_simplex:test_dtx_endpoint_ready({phase, <<1:128>>, maps:get(group_id, F), vote}, S).

row(F, S) -> quod_dtx_coordinator_trace_tests:owner_row(F, S).
wait_dead(Pid) ->
    M = monitor(process, Pid),
    _ = quod_dtx_coordinator_trace_tests:wait_down(Pid, M), ok.
assert_no_notifications(Pid) ->
    receive {dtx_coordinator, Pid, _, _} = Event -> error({executed_while_parked, Event})
    after 0 -> ok
    end.
