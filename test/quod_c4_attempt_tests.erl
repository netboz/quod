-module(quod_c4_attempt_tests).
-include_lib("eunit/include/eunit.hrl").

both_owner_kinds_record_exact_sdk_allocation_test() ->
    quod_dtx_coordinator_unwind_tests:with_sdk(fun(_Storage) ->
        Window = <<"both-owner-kinds">>, Parent = self(),
        ok = quod_c4_attempt:enable(Window, [<<"phase1:test">>]),
        {module, quod_c4_attempt} = code:ensure_loaded(quod_c4_attempt),
        Session = trace:session_create(both_owner_kinds, self(), []),
        1 = trace:function(Session, {quod_c4_attempt, record, 1}, true, [local]),
        try
            lists:foreach(fun({Name, Key}) ->
                Ctx = otel_ctx:new(),
                Tracer = opentelemetry:get_tracer(opentelemetry:get_application(quod_trace)),
                Group = binary:encode_hex(<<1:256>>, lowercase),
                A = #{'quod.namespace' => <<"phase1:test">>, Key => Group},
                Count = counters:new(1, []),
                {Pid, M} = spawn_monitor(fun() ->
                    receive go -> ok end,
                    Span = quod_c4_attempt:allocate_span(Ctx, Tracer, Name, A, fun() ->
                        counters:add(Count, 1, 1),
                        otel_tracer:start_span(Ctx, Tracer, Name, #{kind => internal})
                    end),
                    Parent ! {allocation_returned, self(), Span},
                    otel_span:end_span(Span)
                end),
                1 = trace:process(Session, Pid, true, [call]), Pid ! go,
                Record = receive {trace, Pid, call, {quod_c4_attempt, record, [R]}} -> R
                         after 2000 -> error({missing_allocation_metadata, Name}) end,
                Span = receive {allocation_returned, Pid, H} -> H
                       after 2000 -> error(missing_allocation_return) end,
                receive {'DOWN', M, process, Pid, normal} -> ok
                after 2000 -> error(allocation_worker_failure) end,
                ?assertEqual(1, counters:get(Count, 1)),
                ?assertEqual(Group, maps:get(group, Record)),
                ?assertMatch(#{allocation_kind := new_identity,
                  sampler := #{kind := parent_based},
                  span := #{sampled := true, recording := true}}, maps:get(metadata, Record)),
                #{span := #{identity := [_, SpanId]}} = maps:get(metadata, Record),
                ?assertEqual(binary:encode_hex(<<(otel_span:span_id(Span)):64>>, lowercase), SpanId)
            end, [{<<"quod.dtx.coordinate">>, 'quod.dtx.group_id'},
                  {<<"quod.operation.recover">>, 'quod.operation.id'}])
        after
            trace:session_destroy(Session), quod_c4_attempt:disable(Window)
        end
    end).

disabled_and_unrelated_spans_delegate_once_test() ->
    Count=counters:new(1,[]), Op=fun()->counters:add(Count,1,1),original_result end,
    ?assertEqual(original_result,quod_c4_attempt:allocate_span(unknown,unknown,
      <<"quod.dtx.coordinate">>,attributes(),Op)),
    ok=quod_c4_attempt:enable(<<"phase1-unit">>,[<<"phase1:test">>]),
    try
        ?assertEqual(original_result,quod_c4_attempt:allocate_span(unknown,unknown,
          <<"ordinary.span">>,attributes(),Op)),
        ?assertEqual(2,counters:get(Count,1))
    after ok=quod_c4_attempt:disable(<<"phase1-unit">>) end.

metadata_failure_preserves_result_and_exception_test() ->
    ok=quod_c4_attempt:enable(<<"phase1-unit">>,[<<"phase1:test">>]),
    Count=counters:new(1,[]),
    try
        ?assertEqual(original_result,quod_c4_attempt:allocate_span(bad_context,bad_tracer,
          <<"quod.dtx.coordinate">>,attributes(),fun()->counters:add(Count,1,1),original_result end)),
        ?assertException(throw,original_error,quod_c4_attempt:allocate_span(bad_context,bad_tracer,
          <<"quod.dtx.coordinate">>,attributes(),fun()->counters:add(Count,1,1),throw(original_error) end)),
        ?assertEqual(2,counters:get(Count,1))
    after ok=quod_c4_attempt:disable(<<"phase1-unit">>) end.

window_token_cannot_clear_another_capture_test() ->
    ok=quod_c4_attempt:enable(<<"phase1-unit">>,[<<"phase1:test">>]),
    try
        ?assertEqual({error,observation_already_enabled},
          quod_c4_attempt:enable(<<"other">>,[<<"other">>])),
        ?assertEqual({error,different_observation_window},quod_c4_attempt:disable(<<"other">>))
    after ok=quod_c4_attempt:disable(<<"phase1-unit">>) end.

sdk_configuration_snapshot_is_closed_and_read_only_test() ->
    Before=application:get_all_env(opentelemetry),
    Snapshot=quod_c4_sdk_config:snapshot(),
    ?assertEqual(Before,application:get_all_env(opentelemetry)),
    ?assertEqual([cached_application_sampler,cached_default_sampler,node,
                  observed_system_ms,requested_ratio,requested_sampler,schema],
                 lists:sort(maps:keys(Snapshot))),
    ?assert(is_binary(iolist_to_binary(json:encode(Snapshot)))).

attributes()->#{'quod.namespace'=><<"phase1:test">>,
  'quod.dtx.group_id'=>binary:encode_hex(<<1:256>>,lowercase)}.
