-module(quod_feed_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%%%===================================================================
%%% classify/2 — the ordering decision (drop / take-next / gap)
%%%===================================================================

classify_test_() ->
    [ ?_assertEqual(duplicate, quod_feed:classify(1, 5)),   %% below our height
      ?_assertEqual(duplicate, quod_feed:classify(5, 5)),   %% exactly our height
      ?_assertEqual(next,      quod_feed:classify(6, 5)),   %% the contiguous next block (fast path)
      ?_assertEqual(gap,       quod_feed:classify(7, 5)),   %% ahead ⇒ out of order (F2 anti-entropy)
      ?_assertEqual(next,      quod_feed:classify(1, 0)) ]. %% genesis onto an empty follower

%%%===================================================================
%%% wire: encode/decode roundtrip + defensive rejects
%%%===================================================================

roundtrip_test() ->
    Ns = <<"quod:root">>,
    E  = #entry{index = 7, data = noop, cert = none},
    Payload = quod_feed:encode(Ns, {block, E}),
    ?assertEqual({block, E}, quod_feed:decode(Payload, Ns)).

decode_wrong_ns_test() ->
    E = #entry{index = 1, data = noop, cert = none},
    Payload = quod_feed:encode(<<"a">>, {block, E}),
    ?assertEqual(error, quod_feed:decode(Payload, <<"b">>)).

decode_garbage_test() ->
    ?assertEqual(error, quod_feed:decode(<<0, 1, 2, 3>>, <<"quod:root">>)),
    ?assertEqual(error, quod_feed:decode(term_to_binary({not_feed, x}), <<"quod:root">>)).
