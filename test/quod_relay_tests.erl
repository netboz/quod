-module(quod_relay_tests).

-include_lib("eunit/include/eunit.hrl").

frame_dispatch_test() ->
    Ns = <<"relay:test">>,
    ReqId = <<1:128>>,
    Result = {relay_result, ReqId, {ok, 7}},
    ?assertEqual({relay, Result},
                 quod_relay:decode_frame(quod_relay:encode(Ns, Result), Ns)),
    Consensus = {share, example},
    Inner = term_to_binary(Consensus, [deterministic]),
    Frame = term_to_binary({sx, Ns, Inner}, [deterministic]),
    ?assertEqual({consensus, Consensus},
                 quod_relay:decode_frame(Frame, Ns)),
    ?assertEqual(error, quod_relay:decode_frame(Frame, <<"other">>)).

bounded_result_cache_test() ->
    Now = quod_time:mono_ms(),
    Expired = #{<<0:128>> => {peer, old, Now - 1}},
    Live = quod_relay:put_result(
             <<1:128>>, {peer, fresh, Now + 1000}, Expired),
    ?assertEqual(false, maps:is_key(<<0:128>>, Live)),
    ?assertEqual({peer, fresh, Now + 1000}, maps:get(<<1:128>>, Live)).
