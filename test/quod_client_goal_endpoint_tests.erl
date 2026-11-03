-module(quod_client_goal_endpoint_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_client_goal_limits.hrl").
-include("quod_transport_limits.hrl").

closed_request_and_response_algebra_roundtrips_test() ->
    Fixture = quod_ct:signed_goal_fixture(#{mode => read}),
    Id = <<1:128>>,
    CursorId = <<2:256>>,
    Trace = [{<<"traceparent">>,
              <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>}],
    Requests =
        [{submit, Id, maps:get(request_bytes, Fixture),
          maps:get(signature, Fixture), none, Trace},
         {submit, Id, maps:get(request_bytes, Fixture),
          maps:get(signature, Fixture), CursorId, []},
         {cursor, Id, CursorId, next},
         {cursor, Id, CursorId, accept},
         {cursor, Id, CursorId, stop}],
    Result = quod_client_result:normalize(
               maps:get(evidence, Fixture), {ok, [#{}], 1}),
    {ok, ResultBlob} = quod_client_result:encode(Result),
    Responses =
        [{refused, Id, not_ready}, {refused, Id, busy},
         {refused, Id, rate_limited}, {result, Id, ResultBlob},
         {cursor_result, Id, CursorId, ResultBlob},
         {error, Id, invalid_request}, {error, Id, invalid_signature},
         {error, Id, wrong_network}, {error, Id, wrong_target},
         {error, Id, expired}, {error, Id, operation_conflict}],
    lists:foreach(
      fun(Request) ->
          {ok, Frame} = quod_client_goal_endpoint:encode_request(Request),
          ?assertEqual({ok, Request},
                       quod_client_goal_endpoint:route_request(Frame))
      end, Requests),
    lists:foreach(
      fun(Response) ->
          {ok, Frame} = quod_client_goal_endpoint:encode_response(Response),
          ?assertEqual({ok, Response},
                       quod_client_goal_endpoint:decode_response(Frame))
      end, Responses).

correlation_binds_request_and_cursor_ids_test() ->
    Fixture = quod_ct:signed_goal_fixture(#{mode => cursor}),
    Id = <<3:128>>,
    OtherId = <<4:128>>,
    CursorId = <<5:256>>,
    OtherCursor = <<6:256>>,
    Request = {submit, Id, maps:get(request_bytes, Fixture),
               maps:get(signature, Fixture), CursorId, []},
    {ok, ResultBlob} = quod_client_result:encode(stopped),
    ?assert(quod_client_goal_endpoint:correlates(
              Request, {cursor_result, Id, CursorId, ResultBlob})),
    ?assertNot(quod_client_goal_endpoint:correlates(
                 Request,
                 {cursor_result, OtherId, CursorId, ResultBlob})),
    ?assertNot(quod_client_goal_endpoint:correlates(
                 Request, {cursor_result, Id, OtherCursor, ResultBlob})).

malformed_shapes_fail_closed_test() ->
    Fixture = quod_ct:signed_goal_fixture(#{}),
    Id = <<7:128>>,
    ?assertMatch(
       {error, {protocol_error, bad_request_id}},
       quod_client_goal_endpoint:encode_request(
         {submit, <<7:120>>, maps:get(request_bytes, Fixture),
          maps:get(signature, Fixture), none, []})),
    ?assertMatch(
       {error, {protocol_error, bad_signature}},
       quod_client_goal_endpoint:encode_request(
         {submit, Id, maps:get(request_bytes, Fixture), <<0:504>>, none, []})),
    ?assertMatch(
       {error, {protocol_error, bad_request}},
       quod_client_goal_endpoint:encode_request(
         {submit, Id, <<"not a request">>, maps:get(signature, Fixture),
          none, []})),
    ?assertMatch(
       {error, {protocol_error, bad_shape}},
       quod_client_goal_endpoint:route_request(
         term_to_binary({quod_client_goal_endpoint, 1,
                         term_to_binary({unknown, Id}, [deterministic])},
                        [deterministic]))),
    Oversized = <<0:((1024 * 1024) + 1)/unit:8>>,
    ?assertEqual(
       {error, {protocol_error, bad_etf}},
       quod_client_goal_endpoint:decode_response(Oversized)).

complete_large_envelope_roundtrips_without_old_quota_test() ->
    Id = <<7:128>>,
    {ok,Payload}=quod_wire_term:encode_bindings(#{<<"X">>=>binary:copy(<<$x>>,600000)},unlimited),
    {ok,Result}=quod_client_result:encode({answers,1,[Payload]}),
    {ok,Envelope}=quod_client_goal_endpoint:encode_response({result,Id,Result}),
    ?assertEqual({ok,{result,Id,Result}},quod_client_goal_endpoint:decode_response(Envelope)),
    ?assertEqual({ok,{result,Id,Result}},quod_client_goal_endpoint:route_response(Envelope)),
    {ok,HugePayload}=quod_wire_term:encode_bindings(#{<<"X">>=>binary:copy(<<$x>>,(1024 * 1024))},unlimited),
    {ok,Huge}=quod_client_result:encode({answers,1,[HugePayload]}),
    {ok,HugeEnvelope}=quod_client_goal_endpoint:encode_response({result,Id,Huge}),
    ?assertEqual({ok,{result,Id,Huge}},quod_client_goal_endpoint:decode_response(HugeEnvelope)),
    ?assertEqual(term_to_binary(quod_client_goal_v1,[deterministic]),quod_client_goal_endpoint:channel()).

routing_decode_keeps_signed_and_result_payloads_opaque_test() ->
    Id = <<8:128>>,
    Signature = <<9:512>>,
    OpaqueRequest = {submit, Id, <<"not yet parsed">>, Signature, none, []},
    RequestFrame = frame(OpaqueRequest),
    ?assertEqual({ok, OpaqueRequest},
                 quod_client_goal_endpoint:route_request(RequestFrame)),
    OpaqueResponse = {result, Id, term_to_binary(arbitrary)},
    ResponseFrame = frame(OpaqueResponse),
    ?assertEqual({ok, OpaqueResponse},
                 quod_client_goal_endpoint:route_response(ResponseFrame)),
    ?assertMatch({error, {protocol_error, bad_result}},
                 quod_client_goal_endpoint:decode_response(ResponseFrame)).

frame(Inner) ->
    InnerBlob = term_to_binary(Inner, [deterministic]),
    term_to_binary(
      {quod_client_goal_endpoint, 1, InnerBlob}, [deterministic]).
