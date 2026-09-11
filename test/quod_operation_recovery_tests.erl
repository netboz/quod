-module(quod_operation_recovery_tests).
-moduledoc """
Operation result custody at the existing Simplex owner. These regressions
drive the production transitions with real callers, worker messages and
monitors. The stub replaces only remote verification; it never supplies a
verdict until the test explicitly delivers the worker's verified result.
""".
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").

result_trace_marks_only_the_bound_delivery_test_() ->
    [{atom_to_list(Lifetime), fun() -> result_trace_marks_only_bound_delivery(Lifetime) end}
     || Lifetime <- [live_parent, ended_parent]].

result_trace_marks_only_bound_delivery(Lifetime) ->
    quod_trace_tests:with_tracer(fun() ->
        {Ctx, Parent} = quod_trace:start_span(
                          otel_ctx:new(), <<"operation.result_delivery.test">>, internal, #{}),
        case Lifetime of
            ended_parent -> quod_trace:finish_span(Parent, ok);
            live_parent -> ok
        end,
        try quod_trace:with_context(Ctx, fun() ->
              with_fixture(fun(F, S0, Worker, _LifeMonitor) ->
                  Ref = maps:get(operation_ref, F),
                  Target = maps:get(target_ref, F),
                  {Tag, S1} = wait_for_result(Ref, S0),
                  %% A wrong worker cannot produce an accepted-result event.
                  ?assertEqual(false, quod_simplex:finish_operation_target_result(
                                        self(), Ref, committed, Target, S1)),
                  assert_no_reply(Tag),
                  {true, S2} = quod_simplex:finish_operation_target_result(
                                 Worker, Ref, committed, Target, S1),
                  ?assertEqual({committed, Target}, reply(Tag)),
                  {true, S2} = quod_simplex:finish_operation_target_result(
                                 Worker, Ref, committed, Target, S2),
                  assert_no_reply(Tag)
              end)
          end)
        after quod_trace:finish_span(Parent, ok)
        end,
        _ = quod_trace_tests:take_span(<<"operation.result_delivery.test">>),
        Span = quod_trace_tests:take_span(<<"quod.operation.result_delivery">>),
        ?assertEqual(otel_span:trace_id(Parent), Span#span.trace_id),
        ?assertEqual(otel_span:span_id(Parent), Span#span.parent_span_id),
        %% No second span after duplicate/stale delivery, not just no reply.
        receive {quod_test_span, #span{name = <<"quod.operation.result_delivery">>}} ->
            error(duplicate_delivery_span)
        after 0 -> ok
        end,
        Events = lists:reverse(otel_events:list(Span#span.events)),
        ?assertEqual([<<"operation.target_result_accepted">>,
                      <<"operation.result_reply_ready">>],
                     [E#event.name || E <- Events]),
        [Accepted, Replied] = Events,
        ?assert(Accepted#event.system_time_native =< Replied#event.system_time_native),
        Attrs = otel_attributes:map(Accepted#event.attributes),
        ?assertEqual(1, maps:get('quod.waiter.count', Attrs)),
        ?assertEqual(64, byte_size(maps:get('quod.operation.id', Attrs)))
    end).

receipt_before_result_keeps_the_waiting_caller_test() ->
    with_fixture(fun(F, S0, Worker, LifeMonitor) ->
        Ref = maps:get(operation_ref, F),
        Target = maps:get(target_ref, F),
        {Tag, S1} = wait_for_result(Ref, S0),
        S2 = complete(F, S1),
        assert_no_reply(Tag),
        ?assertMatch(#{claim_state := terminal, result := pending,
                       pid := Worker}, owner(Ref, S2)),
        ?assertEqual([Ref], worker_wakes(Worker)),
        {true, S3} = quod_simplex:finish_operation_target_result(
                       Worker, Ref, committed, Target, S2),
        ?assertEqual({committed, Target}, reply(Tag)),
        assert_no_reply(Tag),
        ?assertEqual(#{}, owners(S3)),
        assert_worker_stopped(Worker, LifeMonitor)
    end).

result_before_receipt_replies_once_then_retires_test() ->
    with_fixture(fun(F, S0, Worker, LifeMonitor) ->
        Ref = maps:get(operation_ref, F),
        Target = maps:get(target_ref, F),
        {Tag, S1} = wait_for_result(Ref, S0),
        {true, S2} = quod_simplex:finish_operation_target_result(
                       Worker, Ref, committed, Target, S1),
        ?assertEqual({committed, Target}, reply(Tag)),
        ?assertMatch(#{claim_state := unresolved, waiters := #{},
                       result := {committed, Target}}, owner(Ref, S2)),
        ?assertEqual(#{}, maps:get(waiters, owner(Ref, S2))),
        %% Reuse while the unresolved operation still owns this worker is not
        %% a terminal cache: the receipt below removes the entire owner.
        ?assertEqual({reply, {committed, Target}, S2},
                     quod_simplex:await_operation_recovery(
                       {self(), make_ref()}, make_ref(), Ref, S2)),
        {true, S2} = quod_simplex:finish_operation_target_result(
                       Worker, Ref, committed, Target, S2),
        assert_no_reply(Tag),
        S3 = complete(F, S2),
        ?assertEqual(#{}, owners(S3)),
        assert_no_reply(Tag),
        assert_worker_stopped(Worker, LifeMonitor)
    end).

receipt_is_not_a_success_verdict_test() ->
    with_fixture(fun(F, S0, Worker, LifeMonitor) ->
        Ref = maps:get(operation_ref, F),
        Target = maps:get(target_ref, F),
        {Tag, S1} = wait_for_result(Ref, S0),
        S2 = complete(F, S1),
        assert_no_reply(Tag),
        {true, S3} = quod_simplex:finish_operation_target_result(
                       Worker, Ref, {rejected, conflict_retry}, Target, S2),
        ?assertEqual({{rejected, conflict_retry}, Target}, reply(Tag)),
        ?assertEqual(#{}, owners(S3)),
        assert_worker_stopped(Worker, LifeMonitor)
    end).

duplicate_receipts_neither_reply_nor_allocate_another_owner_test() ->
    with_fixture(fun(F, S0, Worker, LifeMonitor) ->
        Ref = maps:get(operation_ref, F),
        {Tag, S1} = wait_for_result(Ref, S0),
        S2 = complete(F, complete(F, S1)),
        ?assertEqual(1, map_size(owners(S2))),
        ?assertEqual(1, map_size(maps:get(waiters, owner(Ref, S2)))),
        ?assertEqual([Ref, Ref], worker_wakes(Worker)),
        assert_no_reply(Tag),
        {true, S3} = quod_simplex:finish_operation_target_result(
                       Worker, Ref, committed, maps:get(target_ref, F), S2),
        _ = reply(Tag),
        ?assertEqual(S3, complete(F, S3)),
        assert_no_reply(Tag),
        ?assertEqual(#{}, owners(S3)),
        assert_worker_stopped(Worker, LifeMonitor)
    end).

receipt_binding_cannot_replace_the_claim_test() ->
    with_fixture(fun(F, S0, Worker, LifeMonitor) ->
        Ref = maps:get(operation_ref, F),
        Target = maps:get(target_ref, F),
        Digest = maps:get(request_digest, F),
        Origin = maps:get(origin, F),
        {Tag, S1} = wait_for_result(Ref, S0),
        WrongDigest = crypto:hash(sha256, Digest),
        ?assertNotEqual(Digest, WrongDigest),
        WrongDigestReceipt = quod_transaction:remote_complete(
                               Origin, Ref, WrongDigest,
                               [{quod_operation_vector:target(Target), {included, Target}}]),
        ?assertError({operation_recovery_binding_conflict, Ref},
                     quod_simplex:apply_operation_projection(
                       8, WrongDigestReceipt, S1)),
        {transaction, Ns, Anchor, TxId} = Target,
        WrongTarget = {transaction, Ns, Anchor, crypto:hash(sha256, TxId)},
        WrongTargetReceipt = quod_transaction:remote_complete(
                               Origin, Ref, Digest,
                               [{quod_operation_vector:target(WrongTarget), {included, WrongTarget}}]),
        ?assertError({operation_recovery_binding_conflict, Ref},
                     quod_simplex:apply_operation_projection(
                       8, WrongTargetReceipt, S1)),
        {operation, OriginNs, OriginAnchor, Agent, OpId} = Ref,
        OtherRef = {operation, OriginNs, OriginAnchor, Agent,
                    crypto:hash(sha256, OpId)},
        OtherReceipt = quod_transaction:remote_complete(
                         Origin, OtherRef, Digest,
                         [{quod_operation_vector:target(Target), {included, Target}}]),
        ?assertEqual(S1, quod_simplex:apply_operation_projection(
                           8, OtherReceipt, S1)),
        ?assertEqual([], worker_wakes(Worker)),
        assert_no_reply(Tag),
        S2 = complete(F, S1),
        {true, S3} = quod_simplex:finish_operation_target_result(
                       Worker, Ref, committed, Target, S2),
        ?assertEqual({committed, Target}, reply(Tag)),
        ?assertEqual(#{}, owners(S3)),
        assert_worker_stopped(Worker, LifeMonitor)
    end).

snapshot_without_unresolved_row_preserves_result_delivery_test() ->
    with_fixture(fun(F, S0, Worker, LifeMonitor) ->
        Ref = maps:get(operation_ref, F),
        Target = maps:get(target_ref, F),
        {Tag, S1} = wait_for_result(Ref, S0),
        %% A rebuilt unresolved-only snapshot can precede this replica's
        %% receipt notification. Absence is not permission to fail its caller.
        S2 = quod_simplex:install_operation_snapshot([], S1),
        ?assertMatch(#{claim_state := unknown, pid := Worker,
                       result := pending}, owner(Ref, S2)),
        ?assertEqual([Ref], worker_wakes(Worker)),
        assert_no_reply(Tag),
        {true, S3} = quod_simplex:finish_operation_target_result(
                       Worker, Ref, committed, Target, S2),
        ?assertEqual({committed, Target}, reply(Tag)),
        ?assertEqual(#{}, owners(S3)),
        assert_worker_stopped(Worker, LifeMonitor)
    end).

snapshot_keeps_a_known_terminal_waiter_test() ->
    with_fixture(fun(F, S0, Worker, LifeMonitor) ->
        Ref = maps:get(operation_ref, F),
        {Tag, S1} = wait_for_result(Ref, S0),
        S2 = quod_simplex:install_operation_snapshot([], complete(F, S1)),
        ?assertMatch(#{claim_state := terminal, pid := Worker}, owner(Ref, S2)),
        assert_no_reply(Tag),
        {true, S3} = quod_simplex:finish_operation_target_result(
                       Worker, Ref, committed, maps:get(target_ref, F), S2),
        _ = reply(Tag),
        ?assertEqual(#{}, owners(S3)),
        assert_worker_stopped(Worker, LifeMonitor)
    end).

stale_worker_messages_cannot_take_result_custody_test() ->
    with_fixture(fun(F, S0, Worker, LifeMonitor) ->
        Ref = maps:get(operation_ref, F),
        Target = maps:get(target_ref, F),
        {Tag, S1} = wait_for_result(Ref, S0),
        OwnerMonitor = maps:get(monitor, owner(Ref, S1)),
        ?assertEqual(false, quod_simplex:finish_operation_target_result(
                              self(), Ref, committed, Target, S1)),
        ?assertEqual(false, quod_simplex:finish_operation_target_result(
                              Worker, Ref, committed,
                              {transaction, <<"wrong">>, <<1:256>>, <<2:256>>}, S1)),
        ?assertEqual(false, quod_simplex:drop_operation_recovery_owner(
                              OwnerMonitor, self(), killed, S1)),
        ?assertEqual(false, quod_simplex:drop_operation_recovery_owner(
                              make_ref(), Worker, killed, S1)),
        ?assertEqual(false, quod_simplex:settle_operation_recovery(
                              self(), Ref, S1)),
        assert_no_reply(Tag),
        {true, S2} = quod_simplex:finish_operation_target_result(
                       Worker, Ref, committed, Target, complete(F, S1)),
        ?assertEqual({committed, Target}, reply(Tag)),
        ?assertEqual(false, quod_simplex:finish_operation_target_result(
                              Worker, Ref, committed, Target, S2)),
        assert_no_reply(Tag),
        assert_worker_stopped(Worker, LifeMonitor)
    end).

terminal_worker_crash_is_itself_a_restart_wake_test() ->
    with_fixture(fun(F, S0, Worker, _LifeMonitor) ->
        Ref = maps:get(operation_ref, F),
        Target = maps:get(target_ref, F),
        {Tag, S1} = wait_for_result(Ref, S0),
        S2 = complete(F, S1),
        OwnerMonitor = maps:get(monitor, owner(Ref, S2)),
        exit(Worker, kill),
        receive
            {'DOWN', OwnerMonitor, process, Worker, killed} -> ok
        after 1000 -> error(worker_down_missing)
        end,
        {true, S3} = quod_simplex:drop_operation_recovery_owner(
                       OwnerMonitor, Worker, killed, S2),
        ?assertMatch(#{claim_state := terminal, status := pending,
                       pid := none, monitor := none, result := pending},
                     owner(Ref, S3)),
        assert_no_reply(Tag),
        %% No projection/receipt is sent between DOWN and the replacement's
        %% result. pending is immediately eligible in the same existing lane.
        with_worker(fun(Replacement, ReplacementMonitor) ->
            S4 = quod_simplex:test_seed_operation_worker(Ref, Replacement, S3),
            ?assertEqual(false, quod_simplex:finish_operation_target_result(
                                  Worker, Ref, committed, Target, S4)),
            {true, S5} = quod_simplex:finish_operation_target_result(
                           Replacement, Ref, committed, Target, S4),
            ?assertEqual({committed, Target}, reply(Tag)),
            ?assertEqual(#{}, owners(S5)),
            assert_worker_stopped(Replacement, ReplacementMonitor)
        end)
    end).

last_terminal_caller_down_retires_worker_and_monitors_test() ->
    with_fixture(fun(F, S0, Worker, LifeMonitor) ->
        Ref = maps:get(operation_ref, F),
        Caller = spawn(fun() -> receive stop -> ok end end),
        try
            {wait, S1} = quod_simplex:await_operation_recovery(
                           {Caller, make_ref()}, make_ref(), Ref, S0),
            S2 = complete(F, S1),
            [CallerMonitor] = maps:keys(maps:get(waiters, owner(Ref, S2))),
            WorkerMonitor = maps:get(monitor, owner(Ref, S2)),
            Caller ! stop,
            receive
                {'DOWN', CallerMonitor, process, Caller, normal} -> ok
            after 1000 -> error(caller_down_missing)
            end,
            {true, S3} = quod_simplex:drop_operation_waiter(
                           CallerMonitor, Caller, S2),
            ?assertEqual(#{}, owners(S3)),
            assert_worker_stopped(Worker, LifeMonitor),
            %% Retirement demonitor-flushes the worker's owned monitor.
            receive
                {'DOWN', WorkerMonitor, process, Worker, Reason} ->
                    error({retired_monitor_survived, Reason})
            after 0 -> ok
            end
        after exit(Caller, kill)
        end
    end).

unresolved_claim_still_recovers_after_last_caller_down_test() ->
    with_fixture(fun(F, S0, Worker, LifeMonitor) ->
        Ref = maps:get(operation_ref, F),
        {Tag, S1} = wait_for_result(Ref, S0),
        [Monitor] = maps:keys(maps:get(waiters, owner(Ref, S1))),
        %% Exercise the exact monitor path; unlike a terminal operation, an
        %% unresolved durable claim still needs the existing recovery worker.
        _ = erlang:demonitor(Monitor, [flush]),
        {true, S2} = quod_simplex:drop_operation_waiter(Monitor, self(), S1),
        ?assertMatch(#{claim_state := unresolved, pid := Worker, waiters := #{}},
                     owner(Ref, S2)),
        ?assertEqual(#{}, maps:get(waiters, owner(Ref, S2))),
        ?assert(is_process_alive(Worker)),
        assert_no_reply(Tag),
        ?assertEqual(#{}, owners(complete(F, S2))),
        assert_worker_stopped(Worker, LifeMonitor)
    end).

unchanged_claim_projection_wakes_the_exact_existing_worker_test() ->
    with_fixture(fun(F, S0, Worker, LifeMonitor) ->
        Ref = maps:get(operation_ref, F),
        S1 = quod_simplex:apply_operation_projection(7, maps:get(claim, F), S0),
        ?assertEqual(owner(Ref, S0), owner(Ref, S1)),
        ?assertEqual([Ref], worker_wakes(Worker)),
        ?assertEqual(#{}, owners(complete(F, S1))),
        assert_worker_stopped(Worker, LifeMonitor)
    end).

late_waiter_after_retirement_starts_with_reconstructible_result_custody_test() ->
    with_fixture(fun(F, S0, Worker, LifeMonitor) ->
        Ref = maps:get(operation_ref, F),
        S1 = complete(F, S0),
        ?assertEqual(#{}, owners(S1)),
        assert_worker_stopped(Worker, LifeMonitor),
        {Tag, S2} = wait_for_result(Ref, S1),
        %% No old result is retained, and no claim height has to be guessed.
        %% pending selects the same worker's durable-outcome reconstruction;
        %% the removed awaiting_projection state would wait for a lost edge.
        ?assertMatch(#{claim_state := unknown, status := pending,
                       slot := none, target_ref := none, digest := none,
                       pid := none, monitor := none, result := pending},
                     owner(Ref, S2)),
        assert_no_reply(Tag),
        [Monitor] = maps:keys(maps:get(waiters, owner(Ref, S2))),
        _ = erlang:demonitor(Monitor, [flush]),
        {true, S3} = quod_simplex:drop_operation_waiter(Monitor, self(), S2),
        ?assertEqual(#{}, owners(S3))
    end).

exact_wait_cancellation_releases_a_live_callers_terminal_worker_test() ->
    with_fixture(fun(F, S0, Worker, LifeMonitor) ->
        Ref = maps:get(operation_ref, F),
        Caller = self(),
        {Tag, S1} = wait_for_result(Ref, S0),
        S2 = complete(F, S1),
        [{CallerMonitor, {{Caller, Tag}, WaitRef}}] =
            maps:to_list(maps:get(waiters, owner(Ref, S2))),
        WorkerMonitor = maps:get(monitor, owner(Ref, S2)),
        ?assertEqual(S2, quod_simplex:cancel_operation_waiter(
                           Worker, WaitRef, Ref, S2)),
        ?assertEqual(S2, quod_simplex:cancel_operation_waiter(
                           Caller, make_ref(), Ref, S2)),
        OtherRef = setelement(5, Ref, crypto:hash(sha256, element(5, Ref))),
        ?assertEqual(S2, quod_simplex:cancel_operation_waiter(
                           Caller, WaitRef, OtherRef, S2)),
        ?assert(is_process_alive(Worker)),
        S3 = quod_simplex:cancel_operation_waiter(Caller, WaitRef, Ref, S2),
        ?assertEqual(#{}, owners(S3)),
        ?assert(is_process_alive(Caller)),
        ?assertEqual(false, erlang:demonitor(CallerMonitor, [flush, info])),
        ?assertEqual(false, erlang:demonitor(WorkerMonitor, [flush, info])),
        assert_no_reply(Tag),
        assert_worker_stopped(Worker, LifeMonitor)
    end).

cancel_one_wait_keeps_another_wait_from_the_same_caller_test() ->
    with_fixture(fun(F, S0, Worker, LifeMonitor) ->
        Ref = maps:get(operation_ref, F),
        Target = maps:get(target_ref, F),
        Caller = self(),
        {FirstTag, S1} = wait_for_result(Ref, S0),
        {SecondTag, S2} = wait_for_result(Ref, S1),
        S3 = complete(F, S2),
        Waiters = maps:get(waiters, owner(Ref, S3)),
        [{FirstMonitor, FirstWaitRef}] =
            [{M, W} || {M, {{P, T}, W}} <- maps:to_list(Waiters),
                       P =:= Caller, T =:= FirstTag],
        S4 = quod_simplex:cancel_operation_waiter(
               Caller, FirstWaitRef, Ref, S3),
        ?assertEqual(1, map_size(maps:get(waiters, owner(Ref, S4)))),
        ?assertEqual(false, erlang:demonitor(FirstMonitor, [flush, info])),
        ?assert(is_process_alive(Worker)),
        {true, S5} = quod_simplex:finish_operation_target_result(
                       Worker, Ref, committed, Target, S4),
        ?assertEqual({committed, Target}, reply(SecondTag)),
        assert_no_reply(FirstTag),
        ?assertEqual(#{}, owners(S5)),
        assert_worker_stopped(Worker, LifeMonitor)
    end).

deterministic_worker_fault_parks_instead_of_respawning_forever_test() ->
    with_fixture(fun(F, S0, Worker, _LifeMonitor) ->
        Ref = maps:get(operation_ref, F),
        {Tag, S1} = wait_for_result(Ref, S0),
        S2 = complete(F, S1),
        OwnerMonitor = maps:get(monitor, owner(Ref, S2)),
        Reason = {badmatch, invalid_operation_state},
        exit(Worker, Reason),
        receive {'DOWN', OwnerMonitor, process, Worker, Reason} -> ok
        after 1000 -> error(worker_down_missing)
        end,
        {true, S3} = quod_simplex:drop_operation_recovery_owner(
                       OwnerMonitor, Worker, Reason, S2),
        ?assertMatch(#{claim_state := terminal, status := blocked,
                       pid := none, monitor := none, result := pending},
                     owner(Ref, S3)),
        assert_no_reply(Tag),
        [{_Monitor, {{Caller, Tag}, WaitRef}}] =
            maps:to_list(maps:get(waiters, owner(Ref, S3))),
        ?assertEqual(#{}, owners(quod_simplex:cancel_operation_waiter(
                                   Caller, WaitRef, Ref, S3)))
    end).

public_wait_timeout_cancels_the_exact_wait_without_caller_death_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"quod:operation-wait-timeout-",
           (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
    Fixture = quod_ct:remote_operation_fixture(#{}),
    Ref = maps:get(operation_ref, Fixture),
    Test = self(),
    {Fake, Monitor} = spawn_monitor(fun() ->
        true = quod_reg:reg({quod_simplex, Ns}),
        Test ! {fake_simplex_ready, self()},
        timed_wait_owner(Test)
    end),
    try
        receive {fake_simplex_ready, Fake} -> ok
        after 1000 -> error(fake_simplex_not_ready)
        end,
        %% This exercises a real call deadline. The fake owner never replies;
        %% no sleep, forced caller crash, or benchmark retry creates the exit.
        ?assertEqual({error, {outcome_unknown, Ref}},
                     quod_simplex:await_operation_result(Ns, Ref, 1)),
        WaitRef = receive
            {timed_wait_call, Fake, {Test, _ReplyTag},
             {await_operation_result, W, Ref, _TraceCtx}} when is_reference(W) -> W
        after 1000 -> error(tagged_wait_request_missing)
        end,
        receive
            {timed_wait_cast, Fake,
             {cancel_operation_wait, Test, WaitRef, Ref}} -> ok
        after 1000 -> error(timed_out_wait_was_not_cancelled)
        end,
        ?assert(is_process_alive(Test)),
        ?assert(is_process_alive(Fake))
    after
        _ = erlang:demonitor(Monitor, [flush]),
        exit(Fake, kill)
    end.

timed_wait_owner(Test) ->
    receive
        {'$gen_call', From, Request} ->
            Test ! {timed_wait_call, self(), From, Request},
            timed_wait_owner(Test);
        {'$gen_cast', Request} ->
            Test ! {timed_wait_cast, self(), Request},
            timed_wait_owner(Test)
    end.

with_fixture(Fun) ->
    Fixture = quod_ct:remote_operation_fixture(#{}),
    Claim = maps:get(claim, Fixture),
    {ok, #{operation_ref := Ref, digest := Digest}} =
        quod_transaction:request_claim(Claim),
    {Ns, _Anchor} = maps:get(origin, Fixture),
    S0 = quod_simplex:test_state(#{ns => Ns, prolog_ready => false}),
    S1 = quod_simplex:apply_operation_projection(7, Claim, S0),
    with_worker(fun(Worker, LifeMonitor) ->
        S2 = quod_simplex:test_seed_operation_worker(Ref, Worker, S1),
        Fun(Fixture#{operation_ref => Ref, request_digest => Digest},
            S2, Worker, LifeMonitor)
    end).

with_worker(Fun) ->
    Parent = self(),
    {Worker, Monitor} = spawn_monitor(fun() -> worker_loop(Parent) end),
    try Fun(Worker, Monitor)
    after
        _ = erlang:demonitor(Monitor, [flush]),
        exit(Worker, kill)
    end.

worker_loop(Parent) ->
    receive
        {operation_wake, Ref} ->
            Parent ! {worker_wake, self(), Ref},
            worker_loop(Parent);
        {barrier, Tag} ->
            Parent ! {worker_barrier, self(), Tag},
            worker_loop(Parent)
    end.

worker_wakes(Worker) ->
    Tag = make_ref(),
    Worker ! {barrier, Tag},
    worker_wakes(Worker, Tag, []).

worker_wakes(Worker, Tag, Acc) ->
    receive
        {worker_wake, Worker, Ref} -> worker_wakes(Worker, Tag, [Ref | Acc]);
        {worker_barrier, Worker, Tag} -> lists:reverse(Acc)
    after 1000 -> error(worker_barrier_missing)
    end.

wait_for_result(Ref, S0) ->
    Tag = make_ref(),
    {wait, S1} = quod_simplex:await_operation_recovery(
                   {self(), Tag}, make_ref(), Ref, S0),
    {Tag, S1}.

complete(Fixture, S) ->
    quod_simplex:apply_operation_projection(8, maps:get(completion, Fixture), S).

owners(S) -> quod_simplex:test_operation_recoveries(S).
owner(Ref, S) -> maps:get(Ref, owners(S)).

reply(Tag) ->
    receive {Tag, Result} -> Result
    after 1000 -> error(operation_result_missing)
    end.

assert_no_reply(Tag) ->
    %% Direct owner transitions send replies from this process, so return from
    %% the call is already the ordering barrier for this negative assertion.
    receive {Tag, Result} -> error({premature_or_duplicate_reply, Result})
    after 0 -> ok
    end.

assert_worker_stopped(Worker, Monitor) ->
    receive {'DOWN', Monitor, process, Worker, shutdown} -> ok
    after 1000 -> error(retired_worker_survived)
    end.
