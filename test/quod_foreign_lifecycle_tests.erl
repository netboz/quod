-module(quod_foreign_lifecycle_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").

%% These tests drive the one public/owner verifier with the existing signed
%% fixtures. Finite waits below expire a caller deliberately; ordinary progress
%% is ordered by worker messages, trace delivery and owner mailbox barriers.

queued_and_running_share_one_job_record_test() ->
    {ok, {quod_foreign_log, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(code:which(quod_foreign_log), [abstract_code]),
    Records = [Name || {attribute, _, record, {Name, _}} <- Forms],
    ?assert(lists:member(request, Records)),
    ?assertNot(lists:member(queued_request, Records)),
    %% A single row crosses the existing queue/custody/running transitions.
    %% The old nine-argument common-field reconstruction is deleted, not
    %% hidden behind a new record name or an extra owner.
    ?assertEqual([4], [Arity || {function, _, launch_request_owned, Arity, _} <- Forms]),
    ?assertEqual([3], [Arity || {function, _, park_job, Arity, _} <- Forms]).

public_exact_deadline_includes_owner_mailbox_test() ->
    Fixture = fixture(exact),
    Parent = self(),
    Count = atomics:new(1, []),
    BaseFetch = fixture_fetch(Fixture),
    Fetch = fun(P, E, Ns, From, To) ->
        atomics:add_get(Count, 1, 1),
        BaseFetch(P, E, Ns, From, To)
    end,
    with_owner(Fetch, fun(Owner) ->
        Ref = maps:get(ref, Fixture),
        Contact = contact(Fixture),
        ?assertMatch({ok, #{slot := 2}},
                     quod_foreign_log:verify_reference(Ref, finalize, Contact, 2000)),
        %% Positive control: the same public call has valid evidence and fits
        %% this budget when its owner is not held before admission.
        1 = erlang:trace_pattern({quod_dtx_phase_index, capture, 2}, true, []),
        1 = erlang:trace(Owner, true, [call, procs, {tracer, self()}]),
        ?assertMatch({ok, #{slot := 2}},
                     quod_foreign_log:verify_reference(Ref, finalize, Contact, 100)),
        ?assertEqual([], owner_spawns(Owner)),
        ?assertEqual(1, owner_capture_calls(Owner)),
        Fetches = atomics:get(Count, 1),
        ok = sys:suspend(Owner),
        Caller = spawn(fun() ->
            receive go -> ok end,
            Parent ! {public_result, self(),
                      quod_foreign_log:verify_reference(Ref, finalize, Contact, 100)}
        end),
        try
            1 = erlang:trace(Caller, true, [send, {tracer, self()}]),
            Caller ! go,
            Deadline = receive
                {trace, Caller, send, {'$gen_call', _,
                 {verification, D, _, _,
                  {verify_reference, Ref, finalize, Contact, none, 100}}}, Owner} -> D
            after 1000 -> error(public_request_not_sent)
            end,
            wait_until(Deadline + 20),
            ok = sys:resume(Owner),
            ?assertEqual({error, retry}, receive_public_result(Caller)),
            ?assertMatch(#{pending := 0, queued := 0}, quod_foreign_log:stats()),
            %% The public return check must not conceal an owner which still
            %% admitted obsolete work and only finished it before this read.
            ?assertEqual([], owner_spawns(Owner)),
            ?assertEqual(0, owner_capture_calls(Owner)),
            ?assertEqual(Fetches, atomics:get(Count, 1))
        after
            _ = erlang:trace_pattern({quod_dtx_phase_index, capture, 2}, false, []),
            _ = catch sys:resume(Owner),
            exit(Caller, kill)
        end
    end).

queued_success_checks_each_caller_deadline_test() ->
    Fixture = fixture(exact), Token = make_ref(),
        with_owner(fixture_fetch(Fixture), fun(Owner) ->
            Identity = identity(Fixture),
            %% Warm certified genesis, then acquire the genuinely missing
            %% Finalize. Ready reads no longer have a worker result to hold.
            Genesis = hd(maps:get(chain, Fixture)),
            {batch, [GenesisTx]} = element(3, quod_ledger:entry_view(Genesis)),
            {ok, GenesisRef} = quod_dtx:certified_entry_ref(Identity, Genesis, GenesisTx),
            ?assertMatch({ok, #{slot := 1}}, quod_foreign_log:verify_reference(
                GenesisRef, transaction, contact(Fixture), 2000)),
            ok = gen_server:call(Owner, {test_hold_next_worker_result, self(), Token}),
            Deadline = quod_time:mono_ms() + 500,
            %% Bypass only the public return recheck: this pins the OWNER's
            %% refusal, which otherwise a fixed API boundary could conceal.
            Short = gen_server:send_request(Owner, envelope(
                exact_request(Fixture, 500), Deadline, trace_context(sampled))),
            Worker = receive {worker_result_held, Token, _, W} -> W
                     after 1000 -> error(worker_result_not_held) end,
            #{active := #{ref := RequestRef}} = lifecycle(Owner, Identity),
            Long = send_request(Owner, exact_request(Fixture, 3000),
                                trace_context(unsampled)),
            #{active := Active} = lifecycle(Owner, Identity),
            ?assertEqual(RequestRef, maps:get(ref, Active)),
            ?assertEqual(2, length(maps:get(callers, Active))),
            ok = sys:suspend(Owner),
            try
                1 = erlang:trace(Owner, true, ['receive', {tracer, self()}]),
                Worker ! {release_worker_result, Token},
                await_local_completion_delivery(Owner, RequestRef, 1000),
                ?assert(quod_time:mono_ms() < Deadline),
                {messages, Before} = process_info(Owner, messages),
                ?assertEqual([done], request_messages(Before, RequestRef)),
                wait_until(Deadline + 20),
                {messages, After} = process_info(Owner, messages),
                ?assertEqual([done, timeout], request_messages(After, RequestRef)),
                ok = sys:resume(Owner),
                ?assertEqual({reply, {error, retry}}, gen_server:wait_response(Short, 2000)),
                ?assertMatch({reply, {ok, #{slot := 2, phase := finalize}}},
                             gen_server:wait_response(Long, 2000)),
                ?assertMatch(#{pending := 0, queued := 0}, quod_foreign_log:stats())
            after
                stop_fixture_trace(Owner),
                _ = catch sys:resume(Owner),
                Worker ! {release_worker_result, Token}
            end
        end).

%% A VM-suspended recipient has not processed its incoming message signals.
%% A genuine sender trace is therefore available before recipient delivery
%% evidence. Replaying that trace to the barrier must not release it. This
%% controls the exact await helper used by the production-owner fixture above.
completion_delivery_barrier_rejects_send_only_test() ->
    RequestRef = make_ref(),
    Message = {foreign_worker_done, RequestRef, {ok, #{}}, #{}},
    {Owner, OwnerMonitor} = spawn_monitor(fun() ->
        receive Message -> receive stop -> ok end end
    end),
    {Worker, WorkerMonitor} = spawn_monitor(fun() ->
        receive go -> Owner ! Message, receive stop -> ok end end
    end),
    try
        true = erlang:suspend_process(Owner),
        1 = erlang:trace(Owner, true, ['receive', {tracer, self()}]),
        1 = erlang:trace(Worker, true, [send, {tracer, self()}]),
        Worker ! go,
        SenderTrace = receive
            {trace, Worker, send, Message, Owner} = Trace -> Trace
        after 1000 -> error(sender_trace_missing)
        end,
        self() ! SenderTrace,
        ?assertError(verified_completion_not_queued,
                     await_local_completion_delivery(Owner, RequestRef, 0)),
        receive SenderTrace -> ok
        after 0 -> error(sender_trace_was_consumed)
        end,
        true = erlang:resume_process(Owner),
        ?assertEqual(ok, await_local_completion_delivery(Owner, RequestRef, 1000))
    after
        _ = catch erlang:resume_process(Owner),
        stop_fixture_trace(Owner),
        stop_fixture_trace(Worker),
        Owner ! Message,
        Owner ! stop,
        Worker ! go,
        Worker ! stop,
        receive {'DOWN', OwnerMonitor, process, Owner, _} -> ok
        after 1000 -> error(barrier_owner_not_reaped)
        end,
        receive {'DOWN', WorkerMonitor, process, Worker, _} -> ok
        after 1000 -> error(barrier_worker_not_reaped)
        end
    end.

await_local_completion_delivery(Owner, RequestRef, Timeout) ->
    %% Sender trace delivery and destination signal delivery are different
    %% edges. Only the exact destination's receive event proves this barrier.
    receive
        {trace, Owner, 'receive', {foreign_worker_done, RequestRef, {ok, _}, _}} -> ok
    after Timeout -> error(verified_completion_not_queued)
    end.

stop_fixture_trace(Pid) ->
    _ = erlang:trace(Pid, false, [all]),
    Delivered = erlang:trace_delivered(Pid),
    receive {trace_delivered, Pid, Delivered} -> ok
    after 1000 -> error(fixture_trace_not_delivered)
    end,
    drain_fixture_trace(Pid).

drain_fixture_trace(Pid) ->
    receive
        {trace, Pid, _, _} -> drain_fixture_trace(Pid);
        {trace, Pid, _, _, _} -> drain_fixture_trace(Pid)
    after 0 -> ok
    end.

expired_caller_does_not_cancel_shared_exact_job_test() ->
    Fixture = fixture(exact),
    Token = make_ref(),
    Parent = self(),
    Attempts = atomics:new(1, []),
    BaseFetch = fixture_fetch(Fixture),
    Fetch = fun(P, E, Ns, From, To) ->
        case put(Token, held) of
            undefined ->
                atomics:add_get(Attempts, 1, 1),
                Parent ! {exact_fetch_held, Token, self()},
                receive {release_exact_fetch, Token} -> ok end;
            held -> ok
        end,
        BaseFetch(P, E, Ns, From, To)
    end,
    with_owner(Fetch, fun(Owner) ->
        Request = exact_request(Fixture, 60),
        First = send_request(Owner, Request, trace_context(sampled)),
        Worker = receive {exact_fetch_held, Token, W} -> W
                 after 1000 -> error(exact_fetch_not_started) end,
        try
            #{active := #{ref := Ref}} = lifecycle(Owner, identity(Fixture)),
            ?assertEqual({reply, {error, retry}}, gen_server:wait_response(First, 2000)),
            #{active := #{ref := Ref, callers := []}} = lifecycle(Owner, identity(Fixture)),
            ?assert(is_process_alive(Worker)),
            Second = send_request(Owner, exact_request(Fixture, 2000), trace_context(unsampled)),
            #{active := #{ref := Ref, callers := [_]}} = lifecycle(Owner, identity(Fixture)),
            ?assertEqual(1, atomics:get(Attempts, 1)),
            Worker ! {release_exact_fetch, Token},
            ?assertMatch({reply, {ok, #{slot := 2, phase := finalize}}},
                         gen_server:wait_response(Second, 2000)),
            ?assertEqual(1, atomics:get(Attempts, 1))
        after
            Worker ! {release_exact_fetch, Token}
        end
    end).

callerless_queued_job_preserves_fifo_and_accepts_late_join_test() ->
    Fixture = fixture(exact),
    Parent = self(),
    Token = make_ref(),
    Gate = atomics:new(1, []),
    BaseFetch = fixture_fetch(Fixture),
    Fetch = fun(P, E, Ns, From, To) ->
        case {From, atomics:get(Gate, 1)} of
            {_, 0} ->
                atomics:put(Gate, 1, 1),
                Parent ! {fifo_active, Token, self()},
                receive {release_fifo_active, Token} -> ok end;
            {3, 1} ->
                atomics:put(Gate, 1, 2),
                Parent ! {fifo_callerless, Token, self()},
                receive {release_fifo_callerless, Token} -> ok end;
            _ -> ok
        end,
        BaseFetch(P, E, Ns, From, To)
    end,
    with_owner(Fetch, fun(Owner) ->
        Identity = identity(Fixture),
        Active = send_request(Owner, exact_request(Fixture, 5000), undefined),
        Worker = receive {fifo_active, Token, W} -> W
                 after 1000 -> error(fifo_active_not_started) end,
        try
            First = send_request(Owner, current_request(Fixture, 60), trace_context(sampled)),
            Second = send_request(Owner, current_request(Fixture, 100), trace_context(unsampled)),
            #{waiting := [#{ref := QueuedRef, callers := [_, _]}]} = lifecycle(Owner, Identity),
            Later = send_request(Owner,
                {verify_reference, maps:get(ref, Fixture), entry, contact(Fixture), none, 5000},
                trace_context(sampled)),
            #{waiting := [#{ref := QueuedRef}, #{ref := LaterRef}]} = lifecycle(Owner, Identity),
            ?assertEqual({reply, {error, retry}}, gen_server:wait_response(First, 2000)),
            ?assertEqual({reply, {error, retry}}, gen_server:wait_response(Second, 2000)),
            #{waiting := [#{ref := QueuedRef, callers := []},
                          #{ref := LaterRef, callers := [_]}]} = lifecycle(Owner, Identity),
            Worker ! {release_fifo_active, Token},
            ?assertMatch({reply, {ok, _}}, gen_server:wait_response(Active, 2000)),
            NextWorker = receive {fifo_callerless, Token, Next} -> Next
                         after 2000 -> error(callerless_fifo_job_not_started) end,
            try
                #{active := #{ref := QueuedRef, callers := []},
                  waiting := [#{ref := LaterRef}]} = lifecycle(Owner, Identity),
                ?assertEqual(timeout, gen_server:wait_response(Later, 0)),
                Late = send_request(Owner, current_request(Fixture, 2000), trace_context(sampled)),
                #{active := #{ref := QueuedRef, callers := [_]},
                  waiting := [#{ref := LaterRef}]} = lifecycle(Owner, Identity),
                NextWorker ! {release_fifo_callerless, Token},
                ?assertMatch({reply, {ok, #{slot := 2}}}, gen_server:wait_response(Late, 2000)),
                ?assertMatch({reply, {ok, #{slot := 2}}}, gen_server:wait_response(Later, 2000)),
                ?assertEqual(2, atomics:get(Gate, 1))
            after
                NextWorker ! {release_fifo_callerless, Token}
            end
        after
            Worker ! {release_fifo_active, Token}
        end
    end).

callerless_route_park_is_retired_test() ->
    Fixture = fixture(exact),
    with_owner(no_network(), fun(Owner) ->
        Call = send_request(Owner,
            {verify_reference, maps:get(ref, Fixture), finalize, none, none, 50}, undefined),
        ?assertMatch(#{pending := 0, queued := 1}, quod_foreign_log:stats()),
        ?assertEqual({reply, {error, retry}}, gen_server:wait_response(Call, 2000)),
        ?assertMatch(#{pending := 0, queued := 0, histories := 0}, quod_foreign_log:stats())
    end).

infinite_direct_read_checks_source_after_read_test() ->
    with_local_source(fun(Fixture, Source, SourcePid) ->
        with_owner(no_network(), fun(_Owner) ->
            {Caller, Token} = quod_foreign_log_tests:hold_direct_local(
                Source, maps:get(ref, Fixture), infinity, after_read),
            try
                ?assertMatch(#{pending := 0, queued := 0, histories := 0},
                             quod_foreign_log:stats()),
                source_down(SourcePid),
                Caller ! {release_local_read, Token},
                ?assertEqual({error, retry},
                             quod_foreign_log_tests:receive_local_borrow_result(Caller)),
                ?assertMatch(#{pending := 0, queued := 0, histories := 0},
                             quod_foreign_log:stats())
            after exit(Caller, kill)
            end
        end)
    end).

local_read_does_not_acquire_foreign_custody_test() ->
    with_local_source(fun(Fixture, Source, SourcePid) ->
        with_owner(no_network(), fun(_Owner) ->
            Name = {foreign_cache_writer, identity(Fixture)},
            true = quod_reg:reg(Name),
            Registry = whereis(gproc),
            ok = sys:suspend(Registry),
            try
                %% Local evidence uses the immutable owned index, even while
                %% foreign writer registration is unavailable. There is no
                %% custody-denial queue for this read to become stranded in.
                ?assertMatch({ok, #{phase := finalize}},
                    quod_foreign_log:verify_local(
                        Source, maps:get(ref, Fixture), finalize, infinity)),
                {Caller, Token} = quod_foreign_log_tests:hold_direct_local(
                    Source, maps:get(ref, Fixture), infinity, after_read),
                try
                    source_down(SourcePid),
                    Caller ! {release_local_read, Token},
                    ?assertEqual({error, retry},
                        quod_foreign_log_tests:receive_local_borrow_result(Caller)),
                    ?assertMatch(#{pending := 0, queued := 0, histories := 0},
                                 quod_foreign_log:stats())
                after exit(Caller, kill)
                end
            after
                _ = catch sys:resume(Registry),
                _ = catch quod_reg:unreg(Name)
            end
        end)
    end).

source_down(SourcePid) ->
    MRef = monitor(process, SourcePid),
    exit(SourcePid, kill),
    receive {'DOWN', MRef, process, SourcePid, killed} -> ok
    after 1000 -> error(local_source_did_not_die)
    end.

late_sampled_caller_links_surviving_job_after_original_expiry_test() ->
    quod_trace_tests:with_tracer(fun() ->
        Fixture = fixture(exact),
        Parent = self(),
        Gate = make_ref(),
        Base = fixture_fetch(Fixture),
        Fetch = fun(P, E, Ns, From, To) ->
            Parent ! {sdk_fetch_context, Gate,
                      otel_ctx:get_value(lifecycle_private_sentinel)},
            case put(Gate, held) of
                undefined ->
                    Parent ! {sdk_worker_held, Gate, self()},
                    receive {release_sdk_worker, Gate} -> ok end;
                held -> ok
            end,
            Base(P, E, Ns, From, To)
        end,
        with_owner(Fetch, fun(Owner) ->
            {FirstCtx, FirstSpan} = sdk_parent(<<"test.lifecycle.original">>),
            {LateCtx, LateSpan} = sdk_parent(<<"test.lifecycle.late">>),
            Sentinel = <<"private-lifecycle-context-must-not-cross-owner">>,
            First = sdk_public_caller(Fixture, 100,
                otel_ctx:set_value(FirstCtx, lifecycle_private_sentinel, Sentinel)),
            Worker = receive {sdk_worker_held, Gate, Pid} -> Pid
                     after 1000 -> error(sdk_worker_not_held) end,
            try
                #{active := #{ref := Ref, worker := Worker}} = lifecycle(Owner, identity(Fixture)),
                ?assertEqual({error, retry}, receive_public_result(First)),
                FirstApi = sdk_span(<<"quod.foreign.owner_request">>, FirstSpan),
                FirstResidence = sdk_span(<<"quod.foreign.caller_residence">>, FirstSpan),
                FirstStages = sdk_owner_stages(FirstResidence, <<"expired">>),
                ?assertEqual([<<"admitted">>, <<"queued">>, <<"route_selection">>,
                              <<"acquiring">>, <<"running">>],
                             [maps:get('quod.owner.stage', sdk_attrs(S)) || S <- FirstStages]),
                ?assertEqual(FirstApi#span.span_id, FirstResidence#span.parent_span_id),
                ?assert(FirstResidence#span.end_time =< FirstApi#span.end_time),
                #{active := #{ref := Ref, worker := Worker, callers := []}} =
                    lifecycle(Owner, identity(Fixture)),
                quod_trace:finish_span(FirstSpan, ok),
                Late = sdk_public_caller(Fixture, 3000,
                    otel_ctx:set_value(LateCtx, lifecycle_private_sentinel, Sentinel)),
                Join = sdk_span(<<"quod.foreign.join">>, LateSpan),
                #{active := #{ref := Ref, worker := Worker, callers := [_]}, waiting := []} =
                    lifecycle(Owner, identity(Fixture)),
                Worker ! {release_sdk_worker, Gate},
                ?assertMatch({ok, #{phase := finalize, slot := 2}}, receive_public_result(Late)),
                LateApi = sdk_span(<<"quod.foreign.owner_request">>, LateSpan),
                LateResidence = sdk_span(<<"quod.foreign.caller_residence">>, LateSpan),
                LateStages = sdk_owner_stages(LateResidence, <<"ok">>),
                WorkerSpan = sdk_span(<<"quod.foreign.verification_worker">>, FirstSpan),
                ?assertEqual([<<"admitted">>, <<"running">>],
                             [maps:get('quod.owner.stage', sdk_attrs(S)) || S <- LateStages]),
                ?assertEqual(FirstApi#span.span_id, WorkerSpan#span.parent_span_id),
                ?assertEqual([], otel_links:list(WorkerSpan#span.links)),
                ?assertEqual(LateApi#span.span_id, Join#span.parent_span_id),
                ?assertEqual(LateApi#span.span_id, LateResidence#span.parent_span_id),
                ?assert(LateResidence#span.end_time =< LateApi#span.end_time),
                ?assert(FirstResidence#span.end_time < WorkerSpan#span.end_time),
                [Link] = otel_links:list(Join#span.links),
                ?assertEqual(WorkerSpan#span.trace_id, Link#link.trace_id),
                ?assertEqual(WorkerSpan#span.span_id, Link#link.span_id),
                JobId = maps:get('quod.foreign.job_id', sdk_attrs(WorkerSpan)),
                ?assertEqual(32, byte_size(JobId)),
                ?assertEqual(JobId, maps:get('quod.foreign.job_id', sdk_attrs(Join))),
                ?assertEqual(1, maps:get('quod.foreign.attempt', sdk_attrs(Join))),
                ?assertEqual(1, maps:get('quod.foreign.attempt', sdk_attrs(WorkerSpan))),
                quod_trace:finish_span(LateSpan, ok),
                Captured = [FirstApi, FirstResidence, LateApi, LateResidence,
                            Join, WorkerSpan | FirstStages ++ LateStages],
                ?assertEqual(nomatch, binary:match(term_to_binary(Captured), Sentinel)),
                ?assertEqual([undefined], lists:usort(sdk_fetch_contexts(Gate))),
                ?assertMatch(#{pending := 0, queued := 0}, quod_foreign_log:stats())
            after
                Worker ! {release_sdk_worker, Gate},
                quod_trace:finish_span(FirstSpan, ok),
                quod_trace:finish_span(LateSpan, ok)
            end
        end)
    end).

buffered_attempts_share_job_identity_and_close_owner_stage_inventory_test() ->
    quod_trace_tests:with_tracer(fun() ->
        Fixture = fixture(exact),
        Parent = self(),
        Gate = make_ref(),
        Attempts = atomics:new(1, []),
        Base = fixture_fetch(Fixture),
        Fetch = fun(P, E, Ns, From, To) ->
            case get(Gate) of
                undefined ->
                    Number = atomics:add_get(Attempts, 1, 1),
                    put(Gate, Number),
                    Parent ! {sdk_attempt, Gate, Number, self()},
                    receive {release_sdk_attempt, Gate} -> ok end,
                    case Number of
                        N when N =< 2 -> {error, unavailable};
                        3 -> Base(P, E, Ns, From, To)
                    end;
                _ -> Base(P, E, Ns, From, To)
            end
        end,
        with_owner(Fetch, fun(Owner) ->
            trace_owner(Owner),
            {Context, Span} = sdk_parent(<<"test.lifecycle.attempts">>),
            try
                Call = send_request(Owner, exact_request(Fixture, 3000), Context),
                First = receive {sdk_attempt, Gate, 1, W1} -> W1
                        after 1000 -> error(sdk_first_attempt_missing) end,
                Owner ! {directory_route_available, identity(Fixture)},
                #{active := #{ref := Ref, edge := true}} = lifecycle(Owner, identity(Fixture)),
                First ! {release_sdk_attempt, Gate},
                {Ref, {error, retry}, _} = await_done(Owner),
                Second = receive {sdk_attempt, Gate, 2, W2} -> W2
                         after 1000 -> error(sdk_second_attempt_missing) end,
                #{active := #{ref := Ref, edge := false}} = lifecycle(Owner, identity(Fixture)),
                Second ! {release_sdk_attempt, Gate},
                {Ref, {error, retry}, _} = await_done(Owner),
                assert_route_parked(Owner, identity(Fixture), Ref),
                ?assertEqual(2, atomics:get(Attempts, 1)),
                Owner ! {directory_route_available, identity(Fixture)},
                Third = receive {sdk_attempt, Gate, 3, W3} -> W3
                        after 1000 -> error(sdk_postpark_attempt_missing) end,
                Third ! {release_sdk_attempt, Gate},
                ?assertMatch({reply, {ok, #{slot := 2}}}, gen_server:wait_response(Call, 2000)),
                A = sdk_span(<<"quod.foreign.verification_worker">>, Span),
                B = sdk_span(<<"quod.foreign.verification_worker">>, Span),
                C = sdk_span(<<"quod.foreign.verification_worker">>, Span),
                Jobs = lists:sort(
                    fun(X, Y) -> maps:get('quod.foreign.attempt', sdk_attrs(X)) <
                                 maps:get('quod.foreign.attempt', sdk_attrs(Y)) end, [A, B, C]),
                ?assertEqual([1, 2, 3], [maps:get('quod.foreign.attempt', sdk_attrs(S)) || S <- Jobs]),
                ?assertEqual(1, length(lists:usort(
                    [maps:get('quod.foreign.job_id', sdk_attrs(S)) || S <- Jobs]))),
                ?assertEqual([otel_span:span_id(Span)],
                             lists:usort([S#span.parent_span_id || S <- Jobs])),
                Residence = sdk_span(<<"quod.foreign.caller_residence">>, Span),
                Stages = sdk_owner_stages(Residence, <<"ok">>),
                StageNames = [maps:get('quod.owner.stage', sdk_attrs(S)) || S <- Stages],
                ?assertEqual(3, length([ok || <<"running">> <- StageNames])),
                [Running1, Running2, _] = [sdk_attrs(S) || S <- Stages,
                    maps:get('quod.owner.stage', sdk_attrs(S)) =:= <<"running">>],
                ?assertEqual(<<"directory_route">>, maps:get('quod.owner.wake', Running1)),
                ?assertEqual(true, maps:get('quod.owner.progress_edge_buffered', Running1)),
                ?assertEqual(true, maps:get('quod.owner.progress_edge_consumed', Running1)),
                ?assertEqual(false, maps:get('quod.owner.progress_edge_consumed', Running2)),
                [Parked] = [sdk_attrs(S) || S <- Stages,
                    maps:get('quod.owner.stage', sdk_attrs(S)) =:= <<"parked">>],
                ?assertEqual(<<"no_progress_edge">>, maps:get('quod.owner.park_reason', Parked)),
                ?assertEqual(<<"directory_route">>, maps:get('quod.owner.wake', Parked)),
                ?assertEqual([<<"ready">>], lists:usort([
                    maps:get('quod.owner.route_result', sdk_attrs(S)) || S <- Stages,
                    maps:get('quod.owner.stage', sdk_attrs(S)) =:= <<"route_selection">>])),
                ?assertEqual(3, atomics:get(Attempts, 1))
            after
                quod_trace:finish_span(Span, ok)
            end
        end)
    end).

no_route_diagnostic_distinguishes_selection_from_parked_wait_test() ->
    quod_trace_tests:with_tracer(fun() ->
        Fixture = fixture(exact),
        with_owner(no_network(), fun(Owner) ->
            {Context, Span} = sdk_parent(<<"test.lifecycle.no-route">>),
            try
                Call = send_request(Owner,
                    {verify_reference, maps:get(ref, Fixture), finalize, none, none, 60}, Context),
                #{waiting := [#{ref := Ref}]} = lifecycle(Owner, identity(Fixture)),
                assert_route_parked(Owner, identity(Fixture), Ref),
                ?assertEqual({reply, {error, retry}}, gen_server:wait_response(Call, 1000)),
                Residence = sdk_span(<<"quod.foreign.caller_residence">>, Span),
                Stages = sdk_owner_stages(Residence, <<"expired">>),
                ?assertEqual([<<"admitted">>, <<"queued">>, <<"route_selection">>, <<"parked">>],
                             [maps:get('quod.owner.stage', sdk_attrs(S)) || S <- Stages]),
                [_, _, Selection, Parked] = Stages,
                ?assertEqual(<<"no_route">>, maps:get('quod.owner.route_result', sdk_attrs(Selection))),
                ?assertEqual(<<"no_route">>, maps:get('quod.owner.park_reason', sdk_attrs(Parked))),
                ?assertMatch(#{pending := 0, queued := 0, histories := 0}, quod_foreign_log:stats())
            after quod_trace:finish_span(Span, ok)
            end
        end)
    end).

unadmitted_malformed_public_reference_closes_diagnostic_residence_test() ->
    quod_trace_tests:with_tracer(fun() ->
        with_owner(no_network(), fun(_Owner) ->
            {Context, Span} = sdk_parent(<<"test.lifecycle.malformed">>),
            Sentinel = <<"untrusted-reference-is-not-a-trace-attribute">>,
            try
                Result = quod_trace:with_context(Context, fun() ->
                    quod_foreign_log:verify_reference({malformed, Sentinel}, finalize, 1000)
                end),
                ?assertEqual({error, bad_foreign_reference}, Result),
                Residence = sdk_span(<<"quod.foreign.caller_residence">>, Span),
                Api = sdk_span(<<"quod.foreign.owner_request">>, Span),
                Stages = sdk_owner_stages(Residence, <<"bad_foreign_reference">>),
                ?assertEqual([<<"admitted">>],
                             [maps:get('quod.owner.stage', sdk_attrs(S)) || S <- Stages]),
                ?assertEqual(Api#span.span_id, Residence#span.parent_span_id),
                ?assertEqual(nomatch, binary:match(term_to_binary([Api, Residence | Stages]), Sentinel)),
                ?assertMatch(#{pending := 0, queued := 0, histories := 0}, quod_foreign_log:stats())
            after quod_trace:finish_span(Span, ok)
            end
        end)
    end).

direct_source_death_does_not_fabricate_a_foreign_residence_test() ->
    quod_trace_tests:with_tracer(fun() ->
        with_local_source(fun(Fixture, Source, SourcePid) ->
            with_owner(no_network(), fun(_Owner) ->
                {Context, Span} = sdk_parent(<<"test.lifecycle.direct-source-death">>),
                Parent = self(), Token = make_ref(),
                Caller = spawn(fun() ->
                    put({quod_foreign_log, local_read_gate}, {after_read, Parent, Token}),
                    Result = quod_trace:with_context(Context, fun() ->
                        quod_foreign_log:verify_local(
                            Source, maps:get(ref, Fixture), finalize, infinity)
                    end),
                    Parent ! {direct_read_result, Token, Result}
                end),
                Monitor = monitor(process, Caller),
                try
                    receive {local_read_held, Token, Caller} -> ok
                    after 1000 -> error(direct_read_not_held) end,
                    source_down(SourcePid),
                    Caller ! {release_local_read, Token},
                    receive {direct_read_result, Token, Result} ->
                        ?assertEqual({error, retry}, Result)
                    after 1000 -> error(direct_read_did_not_finish) end,
                    receive {'DOWN', Monitor, process, Caller, normal} -> ok end,
                    %% Caller exit is the SDK export barrier. No foreign job
                    %% was admitted, so inventing its residence would be false.
                    TraceId = otel_span:trace_id(Span),
                    ForeignSpans = [S || S <- direct_trace_spans(TraceId),
                        binary:match(S#span.name, <<"quod.foreign.">>) =/= nomatch],
                    ?assertEqual([], ForeignSpans),
                    ?assertMatch(#{pending := 0, queued := 0, histories := 0},
                                 quod_foreign_log:stats())
                after exit(Caller, kill), quod_trace:finish_span(Span, ok)
                end
            end)
        end)
    end).

direct_trace_spans(TraceId) ->
    receive {quod_test_span, S = #span{trace_id = TraceId}} ->
        [S | direct_trace_spans(TraceId)]
    after 0 -> []
    end.

parked_sharing_ignores_trace_context_test_() ->
    [{atom_to_list(A) ++ " -> " ++ atom_to_list(B),
      fun() -> parked_sharing(A, B) end}
     || {A, B} <- [{sampled, sampled}, {sampled, unsampled},
                   {sampled, missing}, {missing, sampled}, {missing, missing}]].

parked_sharing(A, B) ->
    Fixture = fixture(exact),
    Count = atomics:new(1, []),
    Fetch = fun(_, _, _, _, _) -> atomics:add_get(Count, 1, 1), {error, unavailable} end,
    with_owner(Fetch, fun(Owner) ->
        trace_owner(Owner),
        First = send_request(Owner, current_request(Fixture, 3000), trace_context(A)),
        _ = await_done(Owner),
        #{active := none, waiting := [#{ref := Ref, callers := [_]}]} = lifecycle(Owner, identity(Fixture)),
        Fetches = atomics:get(Count, 1),
        Second = send_request(Owner, current_request(Fixture, 2500), trace_context(B)),
        #{active := none, waiting := [#{ref := Ref, callers := [_, _]}]} = lifecycle(Owner, identity(Fixture)),
        ?assertEqual(Fetches, atomics:get(Count, 1)),
        ?assertEqual(timeout, gen_server:wait_response(First, 0)),
        ?assertEqual(timeout, gen_server:wait_response(Second, 0))
    end).

different_supplied_routes_do_not_merge_parked_work_test() ->
    Fixture = fixture(exact),
    Count = atomics:new(1, []),
    Fetch = fun(_, _, _, _, _) -> atomics:add_get(Count, 1, 1), {error, unavailable} end,
    with_owner(Fetch, fun(Owner) ->
        trace_owner(Owner),
        _ = send_request(Owner, current_request(Fixture, 3000), trace_context(sampled)),
        _ = await_done(Owner),
        #{active := none, waiting := [#{ref := FirstRef}]} = lifecycle(Owner, identity(Fixture)),
        Different = {current, [{maps:get(pub, Fixture), [{"127.0.0.1", 19092}]}],
                     identity(Fixture), none, 3000},
        _ = send_request(Owner, Different, trace_context(sampled)),
        _ = await_done(Owner),
        #{active := none, waiting := Rows} = lifecycle(Owner, identity(Fixture)),
        ?assertEqual(2, length(Rows)),
        ?assertEqual(2, length(lists:usort([maps:get(ref, Row) || Row <- Rows]))),
        ?assert(lists:any(fun(#{ref := Ref}) -> Ref =:= FirstRef end, Rows))
    end).

exact_phase_entry_hint_and_contact_remain_nonshareable_test() ->
    Fixture = fixture(exact),
    Parent = self(),
    Token = make_ref(),
    BaseFetch = fixture_fetch(Fixture),
    Fetch = fun(P, E, Ns, From, To) ->
        case put(Token, held) of
            undefined ->
                Parent ! {binding_fetch_held, Token, self()},
                receive {release_binding_fetch, Token} -> ok end;
            held -> ok
        end,
        BaseFetch(P, E, Ns, From, To)
    end,
    with_owner(Fetch, fun(Owner) ->
        Ref = maps:get(ref, Fixture),
        Contact = contact(Fixture),
        Active = send_request(Owner, exact_request(Fixture, 5000), trace_context(sampled)),
        Worker = receive {binding_fetch_held, Token, W} -> W
                 after 1000 -> error(binding_fetch_not_started) end,
        try
            EntryHint = lists:last(maps:get(chain, Fixture)),
            Requests = [
                {verify_reference, Ref, entry, Contact, none, 5000},
                {verify_reference, Ref, finalize, Contact, EntryHint, 5000},
                {verify_reference, Ref, finalize,
                 {maps:get(pub, Fixture), {"127.0.0.1", 19092}}, none, 5000}],
            Calls = [send_request(Owner, Request, trace_context(unsampled)) || Request <- Requests],
            #{active := #{callers := [_]}, waiting := Rows} = lifecycle(Owner, identity(Fixture)),
            ?assertEqual(3, length(Rows)),
            ?assertEqual(3, length(lists:usort([maps:get(ref, Row) || Row <- Rows]))),
            ?assert(lists:all(fun(#{callers := Callers}) -> length(Callers) =:= 1 end, Rows)),
            Worker ! {release_binding_fetch, Token},
            ?assertMatch({reply, {ok, _}}, gen_server:wait_response(Active, 2000)),
            [?assertMatch({reply, {ok, _}}, gen_server:wait_response(Call, 2000)) || Call <- Calls]
        after
            Worker ! {release_binding_fetch, Token}
        end
    end).

buffered_external_edge_is_consumed_exactly_once_test() ->
    wake_schedule(buffered).

wrong_identity_stale_result_and_self_install_do_not_wake_test() ->
    wake_schedule(no_edge).

wake_schedule(Mode) ->
    Fixture = fixture(exact),
    Identity = identity(Fixture),
    Parent = self(),
    Token = make_ref(),
    Attempts = atomics:new(1, []),
    BaseFetch = fixture_fetch(Fixture),
    Fetch = fun(P, E, Ns, From, To) ->
        case get(Token) of
            undefined ->
                Attempt = atomics:add_get(Attempts, 1, 1),
                put(Token, Attempt),
                Parent ! {wake_attempt, Token, Attempt, self()},
                receive
                    {finish_wake_attempt, Token, unavailable} -> {error, unavailable};
                    {finish_wake_attempt, Token, valid} -> BaseFetch(P, E, Ns, From, To)
                end;
            _ -> BaseFetch(P, E, Ns, From, To)
        end
    end,
    with_owner(Fetch, fun(Owner) ->
        trace_owner(Owner),
        Call = send_request(Owner, exact_request(Fixture, 5000), trace_context(sampled)),
        Worker1 = receive_attempt(Token, 1),
        #{active := #{ref := Ref, edge := false}} = lifecycle(Owner, Identity),
        {Ns, Anchor} = Identity,
        Owner ! {directory_route_available, {<<"other:", Ns/binary>>, Anchor}},
        Owner ! {directory_route_available, {Ns, crypto:hash(sha256, Anchor)}},
        Owner ! {foreign_worker_done, make_ref(), {error, retry}, #{}},
        #{active := #{ref := Ref, edge := false}, waiting := []} = lifecycle(Owner, Identity),
        case Mode of
            buffered ->
                %% Multiple observations grant one dispatch, never one each.
                [Owner ! {directory_route_available, Identity} || _ <- lists:seq(1, 3)],
                #{active := #{ref := Ref, edge := true}} = lifecycle(Owner, Identity);
            no_edge -> ok
        end,
        Worker1 ! {finish_wake_attempt, Token, unavailable},
        {Ref, {error, retry}, _} = await_done(Owner),
        case Mode of
            buffered ->
                Worker2 = receive_attempt(Token, 2),
                #{active := #{ref := Ref, edge := false}} = lifecycle(Owner, Identity),
                Worker2 ! {finish_wake_attempt, Token, unavailable},
                {Ref, {error, retry}, _} = await_done(Owner),
                assert_route_parked(Owner, Identity, Ref),
                ?assertEqual(2, atomics:get(Attempts, 1));
            no_edge ->
                assert_route_parked(Owner, Identity, Ref),
                ?assertEqual(1, atomics:get(Attempts, 1))
        end,
        Before = lifecycle(Owner, Identity),
        Owner ! {foreign_worker_done, make_ref(), {error, retry}, #{}},
        ?assertEqual(Before, lifecycle(Owner, Identity)),
        %% Exact post-park edge is a positive control: same original job and
        %% caller obtain genuine certified fixture evidence without resubmission.
        Next = atomics:get(Attempts, 1) + 1,
        Owner ! {directory_route_available, Identity},
        LastWorker = receive_attempt(Token, Next),
        #{active := #{ref := Ref, edge := false}} = lifecycle(Owner, Identity),
        LastWorker ! {finish_wake_attempt, Token, valid},
        ?assertMatch({reply, {ok, #{phase := finalize, slot := 2}}},
                     gen_server:wait_response(Call, 2000)),
        ?assertEqual(Next, atomics:get(Attempts, 1)),
        ?assertMatch(#{pending := 0, queued := 0}, quod_foreign_log:stats())
    end).

assert_route_parked(Owner, Identity, Ref) ->
    %% A synchronous read after the traced result dequeue observes the finished
    %% callback. No absence sleep or polling can conceal a self-retry here.
    #{active := none, waiting := [#{ref := Ref, edge := false,
                                   wait_reason := route}]} = lifecycle(Owner, Identity),
    ok.

fixture(exact) -> quod_foreign_log_tests:foreign_fixture(unique_ns());
fixture(historical) -> quod_foreign_log_tests:membership_after_finalize_fixture(unique_ns()).

identity(Fixture) -> {maps:get(ns, Fixture), maps:get(anchor, Fixture)}.
contact(Fixture) -> {maps:get(pub, Fixture), {"127.0.0.1", 19091}}.
routes(Fixture) -> [{maps:get(pub, Fixture), [{"127.0.0.1", 19091}]}].
fixture_fetch(Fixture) ->
    quod_foreign_log_tests:peer_chain_fetch(
        maps:get(ns, Fixture), maps:get(chain, Fixture), [maps:get(pub, Fixture)]).

exact_request(Fixture, Timeout) ->
    {verify_reference, maps:get(ref, Fixture), finalize, contact(Fixture), none, Timeout}.
current_request(Fixture, Timeout) ->
    {current, routes(Fixture), identity(Fixture), none, Timeout}.

send_request(Owner, Request, Ctx) ->
    Timeout = element(tuple_size(Request), Request),
    Deadline = case Timeout of infinity -> infinity;
                              _ -> quod_time:mono_ms() + Timeout end,
    gen_server:send_request(Owner, envelope(Request, Deadline, Ctx)).

envelope(Request, Deadline, Ctx) ->
    {verification, Deadline, Ctx, erlang:monotonic_time(), Request}.

lifecycle(Owner, Identity) ->
    maps:get(Identity, gen_server:call(Owner, test_lifecycle_state)).

trace_context(missing) -> undefined;
trace_context(sampled) ->
    quod_trace:extract([{<<"traceparent">>,
        <<"00-11111111111111111111111111111111-1111111111111111-01">>}]);
trace_context(unsampled) ->
    quod_trace:extract([{<<"traceparent">>,
        <<"00-22222222222222222222222222222222-2222222222222222-00">>}]).

async_follow_installs_reference_before_first_notice_test() ->
    Parent = self(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        Result = try
            with_owner(fun(_, _, _, _, _) -> {error, unavailable} end, fun(_Owner) ->
                Target = {<<"quod:async-follow-order">>, <<173:256>>},
                {ok, RequestId} = quod_foreign_log:follow_request(Target),
                %% Receive in arrival order. A selective wait for just the
                %% reply would conceal the old notice-before-registration bug.
                Reply = receive Message -> Message
                        after 1000 -> error(missing_follow_registration) end,
                {reply, {ok, FollowRef}} = gen_server:check_response(Reply, RequestId),
                receive
                    {quod_foreign_follow, FollowRef, NoticeRef, Target, {building, _}} ->
                        ok = quod_foreign_log:ack(FollowRef, NoticeRef)
                after 1000 -> error(missing_initial_follow_credit)
                end,
                ?assertEqual(1, maps:get(follow_consumers, quod_foreign_log:stats())),
                {ok, CloseId} = quod_foreign_log:unfollow_request(FollowRef),
                ?assertEqual({reply, ok}, gen_server:receive_response(CloseId, 1000)),
                ?assertEqual(0, maps:get(follow_consumers, quod_foreign_log:stats()))
            end),
            ok
        catch Class:Reason:Stack -> {raised, Class, Reason, Stack}
        end,
        Parent ! {async_follow_result, self(), Result}
    end),
    receive
        {async_follow_result, Pid, Result} ->
            receive {'DOWN', Monitor, process, Pid, normal} -> ok end,
            case Result of
                ok -> ok;
                {raised, C, R, Stack} -> erlang:raise(C, R, Stack)
            end;
        {'DOWN', Monitor, process, Pid, Reason} -> error({follow_fixture_exit, Reason})
    after 5000 -> error(follow_fixture_stalled)
    end.

with_owner(Fetch, Fun) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(gproc),
    ?assertEqual(undefined, quod_reg:where({foreign_log, node})),
    Dir = temp_dir(),
    {ok, Owner} = quod_foreign_log:start_link(#{cache_dir => Dir, fetch_fun => Fetch,
                                              page_timeout_ms => 1000}),
    try Fun(Owner)
    after
        _ = catch sys:resume(Owner),
        unlink(Owner),
        _ = catch gen_server:stop(Owner),
        _ = file:del_dir_r(Dir)
    end.

with_local_source(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Fixture = fixture(historical),
    Dir = temp_dir(),
    {SourcePid, Monitor, Source} =
        quod_foreign_log_tests:start_local_borrow_source(Dir, Fixture),
    try Fun(Fixture, Source, SourcePid)
    after
        quod_foreign_log_tests:stop_local_borrow_source(SourcePid, Monitor),
        _ = file:del_dir_r(Dir)
    end.

no_network() -> fun(_, _, _, _, _) -> error(unexpected_network_fetch) end.
unique_ns() -> <<"foreign:lifecycle:", (binary:encode_hex(crypto:strong_rand_bytes(12), lowercase))/binary>>.
temp_dir() -> filename:join("/tmp", "quod_foreign_lifecycle_" ++
    binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12), lowercase))).

receive_public_result(Caller) ->
    receive {public_result, Caller, Result} -> Result
    after 2000 -> error(public_result_missing) end.


trace_owner(Owner) ->
    1 = erlang:trace(Owner, true, ['receive', {tracer, self()}]), ok.

await_done(Owner) ->
    receive
        {trace, Owner, 'receive', {foreign_worker_done, Ref, Result, Meta}}
          when map_size(Meta) > 0 -> {Ref, Result, Meta}
    after 2000 -> error(worker_result_not_observed) end.

receive_attempt(Token, Number) ->
    receive {wake_attempt, Token, Number, Worker} -> Worker
    after 2000 -> error({wake_attempt_missing, Number}) end.

owner_spawns(Owner) ->
    Delivered = erlang:trace_delivered(Owner),
    receive {trace_delivered, Owner, Delivered} -> ok
    after 1000 -> error(owner_spawn_trace_not_delivered) end,
    owner_spawns(Owner, []).

owner_spawns(Owner, Acc) ->
    receive {trace, Owner, spawn, Child, _Entry} -> owner_spawns(Owner, [Child | Acc])
    after 0 -> lists:reverse(Acc) end.

owner_capture_calls(Owner) ->
    receive
        {trace, Owner, call, {quod_dtx_phase_index, capture, _}} ->
            1 + owner_capture_calls(Owner)
    after 0 -> 0 end.

request_messages(Messages, Ref) ->
    [case Message of {foreign_worker_done, _, _, _} -> done;
                     {verification_caller_timeout, _, _} -> timeout end
     || Message <- Messages, is_request_message(Message, Ref)].
is_request_message({foreign_worker_done, Ref, _, _}, Ref) -> true;
is_request_message({verification_caller_timeout, Ref, _}, Ref) -> true;
is_request_message(_, _) -> false.


wait_until(Deadline) ->
    receive after max(0, Deadline - quod_time:mono_ms()) -> ok end.

sdk_parent(Name) -> quod_trace:start_span(otel_ctx:new(), Name, internal, #{}).

sdk_public_caller(Fixture, Timeout, Context) ->
    Parent = self(),
    spawn(fun() ->
        Result = quod_trace:with_context(Context, fun() ->
            quod_foreign_log:verify_reference(
                maps:get(ref, Fixture), finalize, contact(Fixture), Timeout)
        end),
        Parent ! {public_result, self(), Result}
    end).

sdk_span(Name, Parent) -> quod_trace_tests:take_span(Name, otel_span:trace_id(Parent)).
sdk_attrs(Span) -> otel_attributes:map(Span#span.attributes).

sdk_owner_stages(Residence, Terminal) ->
    Attrs = sdk_attrs(Residence),
    ?assertEqual(Terminal, maps:get('quod.owner.terminal', Attrs)),
    Count = maps:get('quod.owner.stages_expected', Attrs),
    ?assert(Count > 0),
    TraceId = Residence#span.trace_id,
    ParentId = Residence#span.span_id,
    Stages0 = [receive
        {quod_test_span, S = #span{name = <<"quod.foreign.owner_stage">>,
                                  trace_id = TraceId, parent_span_id = ParentId}} -> S
        after 1000 -> error({missing_owner_stage, I, Count})
        end || I <- lists:seq(1, Count)],
    Stages = lists:sort(fun(A, B) -> maps:get('quod.owner.stage_ordinal', sdk_attrs(A)) <
                                    maps:get('quod.owner.stage_ordinal', sdk_attrs(B)) end, Stages0),
    ?assertEqual(lists:seq(1, Count),
                 [maps:get('quod.owner.stage_ordinal', sdk_attrs(S)) || S <- Stages]),
    lists:foreach(fun(S) ->
        ?assert(S#span.start_time >= Residence#span.start_time),
        ?assert(S#span.end_time =< Residence#span.end_time)
    end, Stages),
    receive
        {quod_test_span, #span{name = <<"quod.foreign.owner_stage">>,
                             trace_id = TraceId, parent_span_id = ParentId}} ->
            error(unaccounted_owner_stage)
    after 0 -> ok
    end,
    Stages.

sdk_fetch_contexts(Token) ->
    receive {sdk_fetch_context, Token, Value} -> [Value | sdk_fetch_contexts(Token)]
    after 0 -> [] end.
