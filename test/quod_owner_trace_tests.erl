-module(quod_owner_trace_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").
-include_lib("opentelemetry/src/otel_tracer.hrl").

-define(TURN, <<"quod.consensus.owner_turn">>).
-define(STEP, <<"quod.consensus.owner_step">>).
-define(OWNER_CONTEXT, {quod_trace, owner_context}).

callback_result_is_exact_and_each_callback_runs_once_test() ->
    with_worker(fun(Pid, Ns) ->
        Secret = unique(<<"private-result:">>),
        Value = {keep_state, #{payload => Secret, reference => make_ref()},
                 [{next_event, internal, {private_action, Secret}}]},
        {Actual, Root, Counts} = call(Pid, fun() ->
            Counter = make_ref(),
            put(Counter, []),
            Result = quod_trace:with_owner_turn(attributes(Ns), fun() ->
                put(test_root, owner_span()),
                mark(Counter, turn),
                quod_trace:with_owner_step(callback, fun() ->
                    mark(Counter, step),
                    Value
                end)
            end),
            ?assertEqual(undefined, get(?OWNER_CONTEXT)),
            {Result, erase(test_root), erase(Counter)}
        end),
        ?assertEqual(Value, Actual),
        ?assertEqual([step, turn], Counts),
        Turn = take_turn(Root, Pid, Ns),
        Step = take_step(Root),
        assert_child(Step, Turn),
        assert_redacted([Turn, Step], [Secret]),
        assert_no_export(otel_span:trace_id(Root))
    end).

exceptions_preserve_class_reason_stack_and_clean_context_test_() ->
    [{atom_to_list(Class), fun() ->
        with_worker(fun(Pid, Ns) -> exception_case(Class, Pid, Ns) end)
      end} || Class <- [error, throw, exit]].

exception_case(Class, Pid, Ns) ->
    Secret = unique(<<"private-exception:">>),
    Reason = {private_failure, Secret, make_ref()},
    Stack = [{?MODULE, private_callback, 0, [{line, 42}]}],
    {Caught, Root, Counts} = call(Pid, fun() ->
        Ambient = otel_ctx:set_value(otel_ctx:new(), private_context, Secret),
        quod_trace:with_context(Ambient, fun() ->
            Counter = make_ref(),
            put(Counter, []),
            Result = try quod_trace:with_owner_turn(attributes(Ns), fun() ->
                put(test_root, owner_span()),
                mark(Counter, turn),
                ?assertEqual(Ambient, quod_trace:context()),
                quod_trace:with_owner_step(failing_callback, fun() ->
                    mark(Counter, step),
                    ?assertEqual(Ambient, quod_trace:context()),
                    erlang:raise(Class, Reason, Stack)
                end)
            end) of
                Unexpected -> {unexpected_return, Unexpected}
            catch C:R:S -> {C, R, S}
            end,
            ?assertEqual(Ambient, quod_trace:context()),
            ?assertEqual(undefined, get(?OWNER_CONTEXT)),
            Outside = quod_trace:with_owner_step(after_failure, fun() ->
                ?assertEqual(undefined, get(?OWNER_CONTEXT)),
                outside
            end),
            ?assertEqual(outside, Outside),
            {Result, erase(test_root), erase(Counter)}
        end)
    end),
    ?assertEqual({Class, Reason, Stack}, Caught),
    ?assertEqual([step, turn], Counts),
    Turn = take_turn(Root, Pid, Ns),
    Step = take_step(Root),
    assert_child(Step, Turn),
    assert_redacted([Turn, Step], [Secret]),
    assert_no_export(otel_span:trace_id(Root)).

nested_steps_restore_parent_after_return_and_exception_test() ->
    with_worker(fun(Pid, Ns) ->
        Secret = unique(<<"private-nested:">>),
        Root = call(Pid, fun() ->
            Ambient = quod_trace:context(),
            Result = quod_trace:with_owner_turn(attributes(Ns), fun() ->
                Root0 = owner_span(),
                OuterResult = quod_trace:with_owner_step(outer, fun() ->
                    Outer = owner_span(),
                    InnerResult = quod_trace:with_owner_step(inner, fun() ->
                        ?assertEqual(Ambient, quod_trace:context()),
                        Secret
                    end),
                    ?assertEqual(Secret, InnerResult),
                    ?assertEqual(Outer, owner_span()),
                    ?assertThrow(Secret, quod_trace:with_owner_step(failed_inner,
                        fun() -> throw(Secret) end)),
                    ?assertEqual(Outer, owner_span()),
                    quod_trace:with_owner_step(after_inner, fun() -> Secret end)
                end),
                ?assertEqual(Secret, OuterResult),
                ?assertEqual(Root0, owner_span()),
                ?assertEqual(ok, quod_trace:with_owner_step(sibling, fun() -> ok end)),
                ?assertEqual(Root0, owner_span()),
                ?assertEqual(Ambient, quod_trace:context()),
                Root0
            end),
            ?assertEqual(undefined, get(?OWNER_CONTEXT)),
            ?assertEqual(Ambient, quod_trace:context()),
            Result
        end),
        Turn = take_turn(Root, Pid, Ns),
        Steps = [take_step(Root) || _ <- lists:seq(1, 5)],
        ByName = maps:from_list([{maps:get('quod.owner.step', span_attributes(S)), S}
                                || S <- Steps]),
        ?assertEqual(5, map_size(ByName)),
        Outer = maps:get(<<"outer">>, ByName),
        assert_child(Outer, Turn),
        assert_child(maps:get(<<"sibling">>, ByName), Turn),
        lists:foreach(fun(Name) -> assert_child(maps:get(Name, ByName), Outer) end,
                      [<<"inner">>, <<"failed_inner">>, <<"after_inner">>]),
        assert_redacted([Turn | Steps], [Secret]),
        assert_no_export(otel_span:trace_id(Root))
    end).

owner_root_is_independent_of_ambient_request_test_() ->
    [{atom_to_list(Sampling), fun() ->
        with_worker(fun(Pid, Ns) -> ambient_case(Sampling, Pid, Ns) end)
      end} || Sampling <- [sampled, unsampled]].

ambient_case(Sampling, Pid, Ns) ->
    Secret = unique(<<"private-request-context:">>),
    Flags = case Sampling of sampled -> <<"01">>; unsampled -> <<"00">> end,
    Trace = binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
    Span = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
    Carrier = <<"00-", Trace/binary, "-", Span/binary, "-", Flags/binary>>,
    Context = otel_ctx:set_value(quod_trace:extract([{<<"traceparent">>, Carrier}]),
                                private_request_context, {Secret, make_ref()}),
    Parent = otel_tracer:current_span_ctx(Context),
    RequestName = <<"owner.request:", Ns/binary>>,
    Root = call(Pid, fun() ->
        quod_trace:with_context(Context, fun() ->
            BeforeBytes = term_to_binary(quod_trace:context()),
            Result = quod_trace:with_owner_turn(attributes(Ns), fun() ->
                Root0 = owner_span(),
                ?assertEqual(BeforeBytes, term_to_binary(quod_trace:context())),
                quod_trace:with_owner_step(request_dispatch, fun() ->
                    ?assertEqual(BeforeBytes, term_to_binary(quod_trace:context())),
                    quod_trace:with_span(quod_trace:context(), RequestName, internal,
                        #{}, fun(Child) ->
                            ?assertEqual(otel_span:trace_id(Parent),
                                         otel_span:trace_id(Child)),
                            Secret
                        end),
                    ?assertEqual(BeforeBytes, term_to_binary(quod_trace:context()))
                end),
                ?assertEqual(Root0, owner_span()),
                Root0
            end),
            ?assertEqual(BeforeBytes, term_to_binary(quod_trace:context())),
            ?assertEqual(undefined, get(?OWNER_CONTEXT)),
            Result
        end)
    end),
    Turn = take_turn(Root, Pid, Ns),
    Step = take_step(Root),
    ?assertNotEqual(otel_span:trace_id(Parent), Turn#span.trace_id),
    ?assertEqual(undefined, Turn#span.parent_span_id),
    ?assertEqual([], otel_links:list(Turn#span.links)),
    assert_child(Step, Turn),
    case Sampling of
        sampled ->
            Request = quod_trace_tests:take_span(RequestName, otel_span:trace_id(Parent)),
            ?assertEqual(otel_span:span_id(Parent), Request#span.parent_span_id),
            assert_redacted([Request], [Secret]);
        unsampled -> assert_no_export(otel_span:trace_id(Parent))
    end,
    assert_redacted([Turn, Step], [Secret]),
    assert_no_export(otel_span:trace_id(Root)).

consecutive_turns_share_incarnation_not_trace_test() ->
    with_worker(fun(Pid, Ns) ->
        First = call(Pid, fun() -> turn_snapshot(Ns) end),
        Second = call(Pid, fun() -> turn_snapshot(Ns) end),
        A = take_turn(First, Pid, Ns),
        B = take_turn(Second, Pid, Ns),
        assert_same_incarnation(A, B, 1),
        ?assertEqual(1, maps:get('quod.owner.sequence', span_attributes(A))),
        ?assertNotEqual(A#span.trace_id, B#span.trace_id)
    end).

sdk_unsampled_turn_leaves_a_sequence_gap_test() ->
    with_worker(fun(Pid, Ns) ->
        First = call(Pid, fun() -> turn_snapshot(Ns) end),
        Dropped = with_sampler(always_off, fun() ->
            call(Pid, fun() ->
                Root = quod_trace:with_owner_turn(attributes(Ns), fun() ->
                    Root0 = owner_span(),
                    ?assert(otel_span:is_valid(Root0)),
                    ?assertNot(otel_span:is_recording(Root0)),
                    ?assertEqual(0, Root0#span_ctx.trace_flags band 1),
                    StepResult = quod_trace:with_owner_step(dropped_step,
                        fun() ->
                            ?assertNot(otel_span:is_recording(owner_span())),
                            retained
                        end),
                    ?assertEqual(retained, StepResult),
                    Root0
                end),
                ?assertEqual(undefined, get(?OWNER_CONTEXT)),
                Root
            end)
        end),
        Third = call(Pid, fun() -> turn_snapshot(Ns) end),
        A = take_turn(First, Pid, Ns),
        C = take_turn(Third, Pid, Ns),
        assert_same_incarnation(A, C, 2),
        ?assertNotEqual(A#span.trace_id, C#span.trace_id),
        assert_no_export(otel_span:trace_id(Dropped))
    end).

step_outside_a_turn_does_not_create_a_span_test() ->
    with_worker(fun(Pid, Ns) ->
        %% A unique ordinary request lets a mistakenly request-parented step be
        %% detected by exact trace, without accepting unrelated owner exports.
        {Context, Parent} = quod_trace:start_span(otel_ctx:new(), Ns, internal, #{}),
        try
            Counts = call(Pid, fun() ->
                quod_trace:with_context(Context, fun() ->
                    Ref = make_ref(),
                    put(Ref, []),
                    Outside = quod_trace:with_owner_step(outside_turn, fun() ->
                        mark(Ref, outside),
                        ?assertEqual(undefined, get(?OWNER_CONTEXT)),
                        ?assertEqual(Context, quod_trace:context()),
                        Ns
                    end),
                    ?assertEqual(Ns, Outside),
                    ?assertEqual(undefined, get(?OWNER_CONTEXT)),
                    erase(Ref)
                end)
            end),
            ?assertEqual([outside], Counts),
            assert_no_export(otel_span:trace_id(Parent))
        after quod_trace:finish_span(Parent, ok)
        end,
        _ = quod_trace_tests:take_span(Ns, otel_span:trace_id(Parent))
    end).

blocked_callback_records_real_occupancy_not_deferred_work_test() ->
    with_worker(fun(Pid, Ns) ->
        Owner = self(),
        Ref = make_ref(),
        DeferredName = <<"owner.deferred:", Ns/binary>>,
        with_process(fun() -> deferred_worker(Owner, Ref, DeferredName) end,
          fun(Deferred, DeferredMonitor) ->
            Request = start_call(Pid, fun() ->
                self() ! {queued_before, Ref, 1},
                self() ! {queued_before, Ref, 2},
                {message_queue_len, QueueBefore} = process_info(self(), message_queue_len),
                Root = quod_trace:with_owner_turn(attributes(Ns), fun() ->
                    Root0 = owner_span(),
                    receive {queued_before, Ref, 1} -> ok end,
                    Deferred ! {schedule, Ref, quod_trace:context()},
                    Work = quod_trace:with_owner_step(blocked_work, fun() ->
                        HeldAt = erlang:monotonic_time(nanosecond),
                        Owner ! {held, Ref, Root0, HeldAt},
                        receive {release, Ref} -> ok end,
                        {reductions, Before} = process_info(self(), reductions),
                        Sum = reduction_work(5000, 0),
                        {reductions, After} = process_info(self(), reductions),
                        ?assertEqual(12502500, Sum),
                        put(test_work_reductions, After - Before),
                        Sum
                    end),
                    ?assertEqual(12502500, Work),
                    self() ! {queued_after, Ref},
                    Root0
                end),
                {message_queue_len, QueueAfter} = process_info(self(), message_queue_len),
                ?assertEqual(undefined, get(?OWNER_CONTEXT)),
                %% The three real messages remain pending at the end boundary.
                receive {queued_before, Ref, 2} -> ok end,
                receive {queued_during, Ref} -> ok end,
                receive {queued_after, Ref} -> ok end,
                {Root, QueueBefore, QueueAfter, erase(test_work_reductions)}
            end),
            {Root0, HeldAt} = receive
                {held, Ref, RootHeld, At} -> {RootHeld, At}
            after 2000 -> error(owner_did_not_block)
            end,
            assert_no_export(otel_span:trace_id(Root0)),
            %% Message barriers, not sleeps or an invented duration, control the
            %% interval covered by both live SDK spans.
            ?assertEqual(50005000, reduction_work(10000, 0)),
            ReleaseAt = erlang:monotonic_time(nanosecond),
            Pid ! {queued_during, Ref},
            Pid ! {release, Ref},
            {Root, QueueBefore, QueueAfter, WorkReductions} = finish_call(Pid, Request),
            ?assertEqual(Root0, Root),
            Turn = take_turn(Root, Pid, Ns),
            Step = take_step(Root),
            assert_child(Step, Turn),
            Attrs = span_attributes(Turn),
            Start = maps:get('quod.owner.start_monotonic_ns', Attrs),
            End = maps:get('quod.owner.end_monotonic_ns', Attrs),
            ?assert(Start =< HeldAt),
            ?assert(HeldAt < ReleaseAt),
            ?assert(ReleaseAt =< End),
            ?assertEqual(End - Start, maps:get('quod.owner.wall_ns', Attrs)),
            ?assert(maps:get('quod.owner.wall_ns', Attrs) >= ReleaseAt - HeldAt),
            ?assert(erlang:convert_time_unit(Step#span.start_time, native, nanosecond)
                    =< HeldAt),
            ?assert(erlang:convert_time_unit(Step#span.end_time, native, nanosecond)
                    >= ReleaseAt),
            ?assertEqual(2, QueueBefore),
            ?assertEqual(3, QueueAfter),
            ?assertEqual(QueueBefore, maps:get('quod.owner.queue_before', Attrs)),
            ?assertEqual(QueueAfter, maps:get('quod.owner.queue_after', Attrs)),
            ?assert(WorkReductions >= 5000),
            ?assert(maps:get('quod.owner.reductions', Attrs) >= WorkReductions),
            Deferred ! {start_deferred, Ref},
            DeferredSpan = receive
                {deferred_started, Ref, DeferredCtx} -> DeferredCtx
            after 2000 -> error(deferred_work_not_started)
            end,
            ?assertNotEqual(Turn#span.trace_id, otel_span:trace_id(DeferredSpan)),
            assert_no_export(otel_span:trace_id(DeferredSpan)),
            Deferred ! {finish_deferred, Ref},
            receive
                {'DOWN', DeferredMonitor, process, Deferred, normal} -> ok;
                {'DOWN', DeferredMonitor, process, Deferred, Why} -> error({deferred_failed, Why})
            after 2000 -> error(deferred_work_not_finished)
            end,
            Later = quod_trace_tests:take_span(DeferredName, otel_span:trace_id(DeferredSpan)),
            ?assert(Turn#span.end_time =< Later#span.start_time),
            ?assert(End =< erlang:convert_time_unit(Later#span.start_time, native, nanosecond)),
            assert_no_export(otel_span:trace_id(Root)),
            assert_no_export(otel_span:trace_id(DeferredSpan))
        end)
    end).

deferred_worker(Owner, Ref, Name) ->
    receive {schedule, Ref, Context} ->
        receive {start_deferred, Ref} -> ok end,
        quod_trace:with_context(Context, fun() ->
            ?assertEqual(undefined, get(?OWNER_CONTEXT)),
            quod_trace:with_owner_step(deferred_outside_turn, fun() ->
                quod_trace:with_span(Context, Name, internal, #{}, fun(Span) ->
                    Owner ! {deferred_started, Ref, Span},
                    receive {finish_deferred, Ref} -> ok end,
                    ?assertEqual(12502500, reduction_work(5000, 0))
                end)
            end)
        end)
    end.

reduction_work(0, Acc) -> Acc;
reduction_work(N, Acc) -> reduction_work(N - 1, Acc + N).

turn_snapshot(Ns) ->
    Result = quod_trace:with_owner_turn(attributes(Ns), fun owner_span/0),
    ?assertEqual(undefined, get(?OWNER_CONTEXT)),
    Result.

owner_span() ->
    %% Inspect only the transient diagnostic context to correlate real SDK
    %% exports. It is deliberately not the ambient request context.
    Context = get(?OWNER_CONTEXT),
    ?assert(is_map(Context)),
    otel_tracer:current_span_ctx(Context).

attributes(Ns) -> #{'quod.namespace' => Ns, 'quod.owner.event_type' => <<"test">>}.

span_attributes(Span) -> otel_attributes:map(Span#span.attributes).

take_turn(Root, Pid, Ns) ->
    Turn = quod_trace_tests:take_span(?TURN, otel_span:trace_id(Root)),
    Attrs = span_attributes(Turn),
    ?assertEqual(Ns, maps:get('quod.namespace', Attrs)),
    ?assertEqual(list_to_binary(pid_to_list(Pid)), maps:get('quod.owner.pid', Attrs)),
    ?assertEqual(otel_span:span_id(Root), Turn#span.span_id),
    ?assertEqual(undefined, Turn#span.parent_span_id),
    ?assertNot(Turn#span.is_recording),
    ?assert(Turn#span.end_time >= Turn#span.start_time),
    Turn.

take_step(Root) -> quod_trace_tests:take_span(?STEP, otel_span:trace_id(Root)).

assert_child(Child, Parent) ->
    ?assertEqual(Parent#span.trace_id, Child#span.trace_id),
    ?assertEqual(Parent#span.span_id, Child#span.parent_span_id),
    ?assert(Child#span.start_time >= Parent#span.start_time),
    ?assert(Child#span.end_time =< Parent#span.end_time),
    ?assertNot(Child#span.is_recording).

assert_redacted(Spans, Secrets) ->
    lists:foreach(fun(Span) ->
        Attrs = span_attributes(Span),
        ?assertNot(maps:is_key('quod.outcome', Attrs)),
        ?assertEqual([], otel_events:list(Span#span.events)),
        Encoded = term_to_binary({Attrs, Span#span.status, Span#span.events}),
        lists:foreach(fun(Secret) -> ?assertEqual(nomatch, binary:match(Encoded, Secret)) end,
                      Secrets)
    end, Spans).

assert_same_incarnation(A, B, Delta) ->
    First = span_attributes(A),
    Second = span_attributes(B),
    Incarnation = maps:get('quod.owner.incarnation', First),
    ?assertEqual(32, byte_size(Incarnation)),
    ?assertEqual(Incarnation, maps:get('quod.owner.incarnation', Second)),
    ?assertEqual(maps:get('quod.owner.sequence', First) + Delta,
                 maps:get('quod.owner.sequence', Second)).

assert_no_export(TraceId) ->
    receive {quod_test_span, Span = #span{trace_id = TraceId}} ->
        error({unexpected_export, Span#span.name, TraceId})
    after 0 -> ok
    end.

mark(Counter, Value) -> put(Counter, [Value | get(Counter)]).

unique(Prefix) ->
    <<Prefix/binary, (binary:encode_hex(crypto:strong_rand_bytes(16), lowercase))/binary>>.

with_sampler(Sampler, Fun) ->
    Key = {opentelemetry, global, tracer, opentelemetry:get_application(quod_trace)},
    Previous = persistent_term:get(Key),
    {Module, Tracer} = Previous,
    Updated = {Module, Tracer#tracer{sampler = otel_sampler:new(Sampler)}},
    try
        true = opentelemetry:verify_and_set_term(Updated, Key, otel_tracer),
        Fun()
    after persistent_term:put(Key, Previous)
    end.

with_worker(Fun) ->
    quod_trace_tests:with_tracer(fun() ->
        Ns = unique(<<"owner-trace-test:">>),
        with_process(fun worker_loop/0, fun(Pid, _Monitor) -> Fun(Pid, Ns) end)
    end).

with_process(Body, Fun) ->
    {Pid, Monitor} = spawn_monitor(Body),
    try Fun(Pid, Monitor)
    after
        %% Re-monitor even if the test consumed DOWN, so failure at any barrier
        %% cannot leave a waiting worker or a stale monitor behind.
        Cleanup = monitor(process, Pid),
        exit(Pid, kill),
        receive {'DOWN', Cleanup, process, Pid, _} -> ok
        after 2000 -> error({worker_cleanup_timeout, Pid})
        end,
        demonitor(Monitor, [flush])
    end.

call(Pid, Fun) -> finish_call(Pid, start_call(Pid, Fun)).

start_call(Pid, Fun) ->
    Ref = make_ref(),
    Pid ! {run, self(), Ref, Fun},
    Ref.

finish_call(Pid, Ref) ->
    receive
        {result, Ref, {ok, Value}} -> Value;
        {result, Ref, {raised, Class, Reason, Stack}} -> erlang:raise(Class, Reason, Stack)
    after 3000 -> error({worker_call_timeout, Pid})
    end.

worker_loop() ->
    receive {run, Owner, Ref, Fun} ->
        Result = try {ok, Fun()} catch Class:Reason:Stack ->
            {raised, Class, Reason, Stack}
        end,
        Owner ! {result, Ref, Result},
        worker_loop()
    end.
