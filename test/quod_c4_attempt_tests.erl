-module(quod_c4_attempt_tests).
-include_lib("eunit/include/eunit.hrl").

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
