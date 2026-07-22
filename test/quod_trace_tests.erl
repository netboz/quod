-module(quod_trace_tests).

-include_lib("eunit/include/eunit.hrl").

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
