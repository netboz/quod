-module(quod_trace_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").
-include_lib("opentelemetry/src/otel_tracer.hrl").

-export([with_tracer/1, take_span/1, take_span/2]).

%% Real SDK storage, parent-based sampling, attachment and span completion;
%% only the exporter is replaced by a test mailbox. Do not start an SDK app or
%% mutate deployment sampling/export configuration. Sequential fixtures restore
%% the exact Quod application-tracer key and caller context even on failure.
with_tracer(Fun) ->
    {ok, Storage} = otel_span_ets:start_link([]),
    Key = {opentelemetry, global, tracer,
           opentelemetry:get_application(quod_trace)},
    Previous = persistent_term:get(Key, absent),
    LimitsKey = {otel_span_limits, span_limits},
    PreviousLimits = persistent_term:get(LimitsKey, absent),
    Token = otel_ctx:attach(otel_ctx:new()),
    Owner = self(),
    Tracer = {otel_tracer_default,
              #tracer{module = otel_tracer_default,
                      sampler = otel_sampler:new(
                                  {parent_based, #{root => always_on}}),
                      id_generator = otel_id_generator,
                      on_start_processors = fun(_Ctx, Span) -> Span end,
                      on_end_processors = fun(Span) ->
                          Owner ! {quod_test_span, Span}, true
                      end,
                      instrumentation_scope =
                          opentelemetry:instrumentation_scope(
                            ?MODULE, <<>>, undefined)}},
    try
        %% The standalone SDK storage does not run application initialization.
        %% Use the pinned SDK's own defaults only when no application supplied
        %% limits, and restore absence as well as pre-existing values below.
        case PreviousLimits of
            absent -> persistent_term:put(LimitsKey, #span_limits{});
            _ -> ok
        end,
        true = opentelemetry:verify_and_set_term(Tracer, Key, otel_tracer),
        Fun()
    after
        restore_term(Key, Previous),
        restore_term(LimitsKey, PreviousLimits),
        otel_ctx:detach(Token),
        gen_server:stop(Storage)
    end.

restore_term(Key, absent) -> persistent_term:erase(Key);
restore_term(Key, Value) -> persistent_term:put(Key, Value).

take_span(Name) ->
    receive
        {quod_test_span, Span = #span{name = Name}} -> Span
    after 2000 -> error({missing_span, Name})
    end.

%% The test tracer observes the whole Quod application, including unrelated
%% live background work. Request assertions must identify their exact trace,
%% not whichever same-named span happens to finish first.
take_span(Name, TraceId) ->
    receive
        {quod_test_span, Span = #span{name = Name, trace_id = TraceId}} -> Span
    after 2000 -> error({missing_span, Name, TraceId})
    end.

trace_correlated_selector_ignores_other_same_named_spans_test() ->
    with_tracer(fun() ->
        {OtherCtx, Other} = quod_trace:start_span(
                             otel_ctx:new(), <<"selector.other">>, internal, #{}),
        {ExpectedCtx, Expected} = quod_trace:start_span(
                                   otel_ctx:new(), <<"selector.expected">>, internal, #{}),
        try
            OtherTrace = otel_span:trace_id(Other),
            ExpectedTrace = otel_span:trace_id(Expected),
            ?assertNotEqual(OtherTrace, ExpectedTrace),
            Name = <<"selector.shared.name">>,
            %% Two actual SDK exports from the other request precede the
            %% wanted child. Consuming the first demonstrates the old hazard;
            %% the second makes a name-only correlated selector fail too.
            lists:foreach(fun(Ctx) ->
                ok = quod_trace:with_span(
                       Ctx, Name, internal, #{}, fun(_) -> ok end)
            end, [OtherCtx, OtherCtx, ExpectedCtx]),
            Wrong = take_span(Name),
            ?assertEqual(OtherTrace, Wrong#span.trace_id),
            Wanted = take_span(Name, ExpectedTrace),
            ?assertEqual(ExpectedTrace, Wanted#span.trace_id),
            ?assertEqual(otel_span:span_id(Expected), Wanted#span.parent_span_id),
            Leftover = take_span(Name),
            ?assertEqual(OtherTrace, Leftover#span.trace_id),
            Missing = <<"missing.shared.child">>,
            ok = quod_trace:with_span(OtherCtx, Missing, internal, #{}, fun(_) -> ok end),
            %% A broken propagation path must remain a failing missing-child
            %% assertion, never pass by accepting another request's child.
            ?assertError({missing_span, Missing, ExpectedTrace}, take_span(Missing, ExpectedTrace)),
            Unrelated = take_span(Missing),
            ?assertEqual(otel_span:trace_id(Other), Unrelated#span.trace_id)
        after
            quod_trace:finish_span(Other, ok),
            quod_trace:finish_span(Expected, ok),
            _ = take_span(<<"selector.other">>),
            _ = take_span(<<"selector.expected">>)
        end
    end).

sampled_parent_child_lifecycle_test() ->
    with_tracer(fun() ->
        Parent = <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>,
        Context = quod_trace:extract([{<<"traceparent">>, Parent}]),
        Before = quod_trace:context(),
        Value = quod_trace:with_span(
                  Context, <<"sampled_parent">>, server, #{},
                  fun(SpanCtx) ->
                      ?assertEqual(SpanCtx, otel_tracer:current_span_ctx()),
                      ?assertEqual(16#4bf92f3577b34da6a3ce929d0e0e4736,
                                   otel_span:trace_id(SpanCtx)),
                      quod_trace:with_span(
                        quod_trace:context(), <<"sampled_child">>, internal,
                        #{}, fun(_) -> unchanged end)
                  end),
        ?assertEqual(unchanged, Value),
        ?assertEqual(Before, quod_trace:context()),
        Outer = take_span(<<"sampled_parent">>),
        Child = take_span(<<"sampled_child">>),
        ?assertEqual(16#00f067aa0ba902b7, Outer#span.parent_span_id),
        ?assertEqual(true, Outer#span.parent_span_is_remote),
        ?assertEqual(Outer#span.span_id, Child#span.parent_span_id),
        ?assertEqual(Outer#span.trace_id, Child#span.trace_id),
        ?assert(Child#span.end_time =< Outer#span.end_time),
        ?assertNot(Outer#span.is_recording),
        ?assert(Outer#span.end_time >= Outer#span.start_time)
    end).

exception_restores_context_and_finishes_span_test() ->
    with_tracer(fun() ->
        Sentinel = otel_ctx:set_value(otel_ctx:new(), test_sentinel, retained),
        Token = otel_ctx:attach(Sentinel),
        try
            ?assertError(deliberate_trace_failure,
              quod_trace:with_span(
                otel_ctx:new(), <<"exception">>, internal, #{},
                fun(_) -> error(deliberate_trace_failure) end)),
            ?assertEqual(Sentinel, quod_trace:context()),
            Span = take_span(<<"exception">>),
            ?assertNot(Span#span.is_recording),
            ?assert(Span#span.end_time >= Span#span.start_time)
        after otel_ctx:detach(Token)
        end
    end).

shared_span_preserves_parent_and_links_other_request_test() ->
    with_tracer(fun() ->
        Before = quod_trace:context(),
        Parent = quod_trace:extract([{<<"traceparent">>,
          <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>}]),
        Other = quod_trace:extract([{<<"traceparent">>,
          <<"00-123456789abcdef0123456789abcdef0-123456789abcdef0-01">>}]),
        Links = opentelemetry:links([otel_tracer:current_span_ctx(Other)]),
        Result = quod_trace:with_span(
                   Parent, <<"shared.work">>, internal, #{}, Links,
                   fun(_Span) -> unchanged end),
        ?assertEqual(unchanged, Result),
        ?assertEqual(Before, quod_trace:context()),
        Span = take_span(<<"shared.work">>),
        ?assertEqual(16#4bf92f3577b34da6a3ce929d0e0e4736, Span#span.trace_id),
        ?assertEqual(16#00f067aa0ba902b7, Span#span.parent_span_id),
        [Link] = otel_links:list(Span#span.links),
        ?assertEqual(16#123456789abcdef0123456789abcdef0, Link#link.trace_id),
        ?assertEqual(16#123456789abcdef0, Link#link.span_id),
        ?assertEqual(0, otel_links:dropped(Span#span.links)),
        ?assertNot(Span#span.is_recording),
        ?assert(Span#span.end_time >= Span#span.start_time)
    end).

shared_context_prefers_recording_and_deduplicates_test_() ->
    [{atom_to_list(Order), fun() ->
        with_tracer(fun() -> shared_context_prefers_recording(Order) end)
      end} || Order <- [unsampled_first, sampled_first]].

shared_context_prefers_recording(Order) ->
    Unsampled = otel_tracer:current_span_ctx(quod_trace:extract([
      {<<"traceparent">>,
       <<"00-123456789abcdef0123456789abcdef0-123456789abcdef0-00">>}])),
    {_, First} = quod_trace:start_span(
                   otel_ctx:new(), <<"shared.first">>, internal, #{}),
    {_, Second} = quod_trace:start_span(
                    otel_ctx:new(), <<"shared.second">>, internal, #{}),
    ?assert(otel_span:is_recording(First)),
    ?assert(otel_span:is_recording(Second)),
    Inputs = case Order of
                 unsampled_first -> [Unsampled, First, Second];
                 sampled_first -> [First, Unsampled, Second]
             end,
    Sentinel = otel_ctx:set_value(otel_ctx:new(), private_request_value, secret),
    Token = otel_ctx:attach(Sentinel),
    try
        {Context, Links} = quod_trace:shared_context(
                             [undefined | Inputs] ++ [First, Unsampled, invalid]),
        ?assertEqual(otel_tracer:set_current_span(otel_ctx:new(), First), Context),
        ?assertEqual(Sentinel, quod_trace:context()),
        %% Stable recording-first order leaves the second recording request
        %% and then the unrecorded request as distinct SDK links.
        ?assertEqual(opentelemetry:links([Second, Unsampled]), Links),
        Ref = make_ref(),
        ?assertEqual(unchanged,
          quod_trace:with_span(Context, <<"shared.selected">>, internal, #{}, Links,
            fun(_) -> self() ! {shared_work_called, Ref}, unchanged end)),
        receive {shared_work_called, Ref} -> ok
        after 0 -> error(shared_work_not_called)
        end,
        receive {shared_work_called, Ref} -> error(shared_work_called_twice)
        after 0 -> ok
        end,
        Span = take_span(<<"shared.selected">>),
        ?assertEqual(otel_span:trace_id(First), Span#span.trace_id),
        ?assertEqual(otel_span:span_id(First), Span#span.parent_span_id),
        %% The API accepts maps; the SDK stores normalized link records.
        ?assertEqual(
          lists:sort([{maps:get(trace_id, Link), maps:get(span_id, Link),
                       maps:get(tracestate, Link), maps:get(attributes, Link)}
                      || Link <- Links]),
          lists:sort([{Link#link.trace_id, Link#link.span_id,
                       Link#link.tracestate, otel_attributes:map(Link#link.attributes)}
                      || Link <- otel_links:list(Span#span.links)])),
        ?assertEqual(Sentinel, quod_trace:context())
    after
        otel_ctx:detach(Token),
        quod_trace:finish_span(First, ok),
        quod_trace:finish_span(Second, ok)
    end,
    _ = take_span(<<"shared.first">>),
    _ = take_span(<<"shared.second">>),
    ok.

shared_context_all_unsampled_preserves_sampler_test() ->
    with_tracer(fun() ->
        First = otel_tracer:current_span_ctx(quod_trace:extract([
          {<<"traceparent">>,
           <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00">>}])),
        Second = otel_tracer:current_span_ctx(quod_trace:extract([
          {<<"traceparent">>,
           <<"00-123456789abcdef0123456789abcdef0-123456789abcdef0-00">>}])),
        {Context, Links} = quod_trace:shared_context([First, Second, First]),
        ?assertEqual(otel_tracer:set_current_span(otel_ctx:new(), First), Context),
        ?assertEqual(opentelemetry:links([Second]), Links),
        Result = quod_trace:with_span(
          Context, <<"shared.unsampled">>, internal, #{}, Links,
            fun(SpanCtx) ->
                ?assertEqual(otel_span:trace_id(First), otel_span:trace_id(SpanCtx)),
                ?assertNot(otel_span:is_recording(SpanCtx)),
                ?assertEqual(0, SpanCtx#span_ctx.trace_flags band 1),
                unchanged
            end),
        ?assertEqual(unchanged, Result),
        receive {quod_test_span, #span{name = <<"shared.unsampled">>}} ->
            error(unsampled_shared_span_exported)
        after 0 -> ok
        end
    end).

shared_context_without_valid_participants_returns_none_test() ->
    ?assertEqual(none, quod_trace:shared_context([])),
    ?assertEqual(none, quod_trace:shared_context([
      undefined, invalid, #{},
      #span_ctx{trace_id = 0, span_id = 1},
      #span_ctx{trace_id = 1, span_id = 0}])).

unsampled_parent_is_not_overridden_test() ->
    with_tracer(fun() ->
        Parent = <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00">>,
        Context = quod_trace:extract([{<<"traceparent">>, Parent}]),
        Result = quod_trace:with_span(
                   Context, <<"unsampled">>, server, #{},
                   fun(SpanCtx) ->
                       ?assertEqual(0, (SpanCtx#span_ctx.trace_flags band 1)),
                       ok
                   end),
        ?assertEqual(ok, Result),
        receive {quod_test_span, #span{name = <<"unsampled">>}} ->
            error(unsampled_span_exported)
        after 0 -> ok
        end
    end).

callback_context_is_nested_and_exception_safe_test() ->
    Before = quod_trace:context(),
    Outer = otel_ctx:set_value(otel_ctx:new(), callback_scope, outer),
    Inner = otel_ctx:set_value(otel_ctx:new(), callback_scope, inner),
    Result = quod_trace:with_context(Outer, fun() ->
          ?assertEqual(Outer, quod_trace:context()),
          ?assertThrow(callback_failed,
            quod_trace:with_context(Inner, fun() ->
                ?assertEqual(Inner, quod_trace:context()),
                throw(callback_failed)
            end)),
          ?assertEqual(Outer, quod_trace:context()),
          unchanged
      end),
    ?assertEqual(unchanged, Result),
    ?assertEqual(Before, quod_trace:context()),
    ?assertError(callback_failed,
      quod_trace:with_context(Outer, fun() -> error(callback_failed) end)),
    ?assertEqual(Before, quod_trace:context()).

bounded_trace_carrier_test() ->
    Parent = <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>,
    State = <<"vendor=value">>,
    ?assert(quod_trace:valid_carrier(
              [{<<"traceparent">>, Parent}, {<<"tracestate">>, State}])),
    ?assertNot(quod_trace:valid_carrier(
                 [{<<"traceparent">>, Parent},
                  {<<"tracestate">>, State},
                  {<<"traceparent">>, Parent}])),
    ?assertNot(quod_trace:valid_carrier([{<<"baggage">>, <<"secret">>}])),
    ?assertNot(quod_trace:valid_carrier(
                 [{<<"traceparent">>, binary:copy(<<"x">>, 513)}])).

invalid_carrier_extracts_empty_context_test() ->
    ?assertEqual(otel_ctx:new(),
                 quod_trace:extract([{<<"baggage">>, <<"secret">>}])).

opaque_binary_attributes_are_encoded_at_the_trace_boundary_test() ->
    with_tracer(fun() ->
        Opaque = <<16#80, 0, 16#ff>>,
        ok = quod_trace:with_span(
               otel_ctx:new(), <<"opaque_attribute">>, internal,
               #{'quod.namespace' => Opaque},
               fun(SpanCtx) ->
                   true = quod_trace:set_attributes(
                            SpanCtx, #{'quod.cache' => Opaque}),
                   ok
               end),
        Span = take_span(<<"opaque_attribute">>),
        Attributes = otel_attributes:map(Span#span.attributes),
        ?assertEqual(<<"hex:8000ff">>,
                     maps:get('quod.namespace', Attributes)),
        ?assertEqual(<<"hex:8000ff">>, maps:get('quod.cache', Attributes))
    end).
