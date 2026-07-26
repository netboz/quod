-module(quod_relay_tests).

-include_lib("eunit/include/eunit.hrl").

frame_dispatch_test() ->
    Ns = <<"relay:test">>,
    ReqId = <<1:128>>,
    Result = {relay_result, ReqId, {ok, 7}},
    ?assertEqual({relay, Result},
                 quod_relay:decode_frame(quod_relay:encode(Ns, Result), Ns)),
    Accepted = {relay_accepted, ReqId},
    ?assertEqual({relay, Accepted},
                 quod_relay:decode_frame(quod_relay:encode(Ns, Accepted), Ns)),
    Consensus = {share, example},
    Inner = term_to_binary(Consensus, [deterministic]),
    Frame = term_to_binary({sx, Ns, Inner}, [deterministic]),
    ?assertEqual({consensus, Consensus},
                 quod_relay:decode_frame(Frame, Ns)),
    ?assertEqual(error, quod_relay:decode_frame(Frame, <<"other">>)),
    Submit = {relay_submit, ReqId, 7,
              {submit, <<2:256>>, <<3:512>>, <<4, 5, 6>>},
              [{<<"traceparent">>,
                <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>}]},
    ?assertEqual({relay, Submit},
                 quod_relay:decode_frame(quod_relay:encode(Ns, Submit), Ns)),
    [BadSlot0, BadSlotHuge, BadSlotType] =
        [setelement(3, Submit, Slot)
         || Slot <- [0, 16#10000000000000000, <<"7">>]],
    [?assertEqual(error,
                  quod_relay:decode_frame(quod_relay:encode(Ns, Bad), Ns))
     || Bad <- [BadSlot0, BadSlotHuge, BadSlotType]],
    {relay_submit, ReqId, _Slot, Envelope, Carrier} = Submit,
    Legacy = {relay_submit, ReqId, Envelope, Carrier},
    ?assertEqual(error,
                 quod_relay:decode_frame(quod_relay:encode(Ns, Legacy), Ns)),
    BadCarrier = setelement(5, Submit, [{<<"baggage">>, <<"not-accepted">>}]),
    ?assertEqual(error,
                 quod_relay:decode_frame(quod_relay:encode(Ns, BadCarrier), Ns)).

bounded_result_cache_test() ->
    Now = quod_time:mono_ms(),
    Expired = #{<<0:128>> => {peer, old, Now - 1}},
    Live = quod_relay:put_result(
             <<1:128>>, {peer, fresh, Now + 1000}, Expired),
    ?assertEqual(false, maps:is_key(<<0:128>>, Live)),
    ?assertEqual({peer, fresh, Now + 1000}, maps:get(<<1:128>>, Live)).
