-module(quod_c4_sampler_observation_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include_lib("opentelemetry/src/otel_tracer.hrl").
-behaviour(otel_sampler).
-export([setup/1, description/1, should_sample/7]).

%% A real SDK sampler callback, confined to this fixture. Production sampling
%% remains unchanged. The SDK, not a manufactured #span_ctx{}, records it.
setup(record_only) -> record_only.
description(record_only) -> <<"c4-test-record-only">>.
should_sample(_Ctx, _Trace, _Links, _Name, _Kind, _Attributes, record_only) ->
    {record_only, #{}, []}.

real_record_only_is_allocated_but_real_batch_drops_it_test() ->
    quod_trace_tests:with_tracer(fun() ->
        Count = counters:new(1, []),
        Ref = make_ref(), Parent = self(),
        {Module, T} = tracer({?MODULE, record_only}),
        Real = {Module, T#tracer{on_end_processors = fun(Span) ->
            counters:add(Count, 1, 1),
            Result = otel_batch_processor:on_end(Span, #{reg_name => c4_absent_processor}),
            Parent ! {Ref, Result}, Result
        end}},
        Child = otel_tracer:start_span(otel_ctx:new(), Real, <<"c4.record_only">>, #{}),
        ?assertMatch(#{allocation_kind := new_identity,
                      span := #{sampled := false, recording := true}},
          quod_c4_sampler_observation:allocation(undefined, Child, Real)),
        Ended = otel_span:end_span(Child),
        ?assertEqual(Child#span_ctx{is_recording = false}, Ended),
        receive {Ref, dropped} -> ok after 1000 -> error(record_only_not_dropped) end,
        ?assertEqual(1, counters:get(Count, 1)),
        %% API hides the internal SDK false result on the stale second call.
        ?assertEqual(Ended, otel_span:end_span(Child)),
        ?assertEqual(1, counters:get(Count, 1))
    end).

real_disabled_sdk_returns_parent_without_allocation_test() ->
    ParentCtx = context(1), Parent = otel_tracer:current_span_ctx(ParentCtx),
    Child = otel_tracer:start_span(ParentCtx, {otel_tracer_noop, []}, <<"c4.disabled">>, #{}),
    ?assertEqual(Parent, Child),
    ?assertMatch(#{allocation_kind := borrowed_parent},
      quod_c4_sampler_observation:allocation(Parent, Child, {otel_tracer_noop, []})).

effective_parent_sampler_metadata_test() ->
    Tracer = tracer({parent_based, #{root => {trace_id_ratio_based, 0.05}}}),
    #{kind := parent_based, branches := Branches} = quod_c4_sampler_observation:describe(Tracer),
    ?assertMatch(#{kind := trace_id_ratio, probability := 0.05,
                   id_upper_bound := _}, maps:get(root, Branches)),
    ?assertEqual(#{kind => always_on}, maps:get(remote_parent_sampled, Branches)),
    ?assertEqual(#{kind => always_off}, maps:get(remote_parent_not_sampled, Branches)),
    ?assertEqual(5, map_size(Branches)).

sdk_float_threshold_is_preserved_bit_exactly_test() ->
    Tracer = {_, #tracer{sampler = {_, _, #{id_upper_bound := Bound}}}} =
      tracer({trace_id_ratio_based, 0.05}),
    ?assert(is_float(Bound)),
    #{id_upper_bound := #{encoding := ieee754_binary64, value := Hex}} =
        quod_c4_sampler_observation:describe(Tracer),
    ?assertEqual(<<Bound:64/float>>, binary:decode_hex(Hex)).

real_sampled_parent_bypasses_zero_root_ratio_test() ->
    with_allocation({parent_based, #{root => {trace_id_ratio_based, 0.0}}},
      context(1), fun(Observed) ->
        ?assertMatch(#{parent_class := remote_sampled,
                       allocation_kind := new_identity,
                       span := #{sampled := true, recording := true}}, Observed)
      end).

real_unsampled_parent_blocks_always_on_root_test() ->
    with_allocation({parent_based, #{root => always_on}}, context(0), fun(Observed) ->
        ?assertMatch(#{parent_class := remote_unsampled,
                       allocation_kind := new_identity,
                       span := #{sampled := false, recording := false}}, Observed)
    end).

real_always_on_samples_even_an_unsampled_parent_test() ->
    with_allocation(always_on, context(0), fun(Observed) ->
        ?assertMatch(#{sampler := #{kind := always_on},
                       parent_class := remote_unsampled,
                       allocation_kind := new_identity,
                       span := #{sampled := true, recording := true}}, Observed)
    end).

real_parentless_zero_root_ratio_allocates_unsampled_identity_test() ->
    with_allocation({parent_based, #{root => {trace_id_ratio_based, 0.0}}},
      otel_ctx:new(), fun(Observed) ->
        ?assertMatch(#{parent_class := parentless, allocation_kind := new_identity,
                       span := #{sampled := false, recording := false}}, Observed)
      end).

borrowed_parent_is_not_a_new_allocation_test() ->
    Parent = otel_tracer:current_span_ctx(context(1)),
    Observed = quod_c4_sampler_observation:allocation(Parent, Parent, unavailable),
    ?assertMatch(#{allocation_kind := borrowed_parent, sampler := #{kind := unknown}}, Observed).

recording_does_not_stand_in_for_sampling_test() ->
    %% Record-only classification shape. The separate processor/SDK matrix
    %% must exercise a real record-only sampler; this is a metadata unit case.
    Span = #span_ctx{trace_id = 1, span_id = 2, trace_flags = 0,
                     is_recording = true, is_remote = false},
    ?assertMatch(#{span := #{sampled := false, recording := true}},
      quod_c4_sampler_observation:allocation(undefined, Span, unavailable)).

closed_schema_never_renders_unknown_configuration_test() ->
    Secret = <<"fixture-secret-do-not-export">>,
    Tracer = {otel_tracer_default, #tracer{sampler = {custom, Secret, #{body => Secret}}}},
    Observed = quod_c4_sampler_observation:allocation(Secret, #{payload => Secret}, Tracer),
    ?assertEqual(#{sampler => #{kind => unknown}, parent => #{identity => unknown},
                   span => #{identity => unknown}, parent_class => unknown,
                   allocation_kind => unknown}, Observed),
    ?assertEqual(nomatch, binary:match(term_to_binary(Observed), Secret)).

tracer(Spec) ->
    {otel_tracer_default, #tracer{module = otel_tracer_default,
      sampler = otel_sampler:new(Spec), id_generator = otel_id_generator,
      on_start_processors = fun(_, Span) -> Span end,
      on_end_processors = fun(_) -> true end,
      instrumentation_scope = opentelemetry:instrumentation_scope(?MODULE, <<>>, undefined)}}.

context(Flags) ->
    Parent = #span_ctx{trace_id = 1, span_id = 2, trace_flags = Flags,
                       is_valid = true, is_recording = false, is_remote = true},
    otel_tracer:set_current_span(otel_ctx:new(), Parent).

with_allocation(Spec, ParentContext, Fun) ->
    quod_trace_tests:with_tracer(fun() ->
        Tracer = tracer(Spec),
        Before = otel_ctx:get_current(),
        Child = otel_tracer:start_span(ParentContext, Tracer, <<"c4.sampler.control">>, #{}),
        try
            Fun(quod_c4_sampler_observation:allocation(
                  otel_tracer:current_span_ctx(ParentContext), Child, Tracer)),
            ?assertEqual(Before, otel_ctx:get_current())
        after otel_span:end_span(Child)
        end
    end).
