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

%%%===================================================================
%%% peer_ready — the passive liveness verdict (fresh / stale / height slack)
%%%===================================================================

%% ready/4 is the pure classification: digest age ≤ 15 s AND height within one pull window (256) of
%% the judge's applied height.
ready_test_() ->
    Now = 100000,
    [ ?_assert(quod_feed:ready(50, Now, Now, 50)),            %% fresh, at the judge's height
      ?_assert(quod_feed:ready(50, Now - 15000, Now, 50)),    %% freshness boundary (inclusive)
      ?_assertNot(quod_feed:ready(50, Now - 15001, Now, 50)), %% one ms past: a dead/mute peer
      ?_assert(quod_feed:ready(50, Now, Now, 306)),           %% exactly one window (256) behind: ok
      ?_assertNot(quod_feed:ready(50, Now, Now, 307)),        %% beyond one window: too far behind
      ?_assert(quod_feed:ready(0, Now, Now, 0)) ].            %% fresh empty follower vs fresh judge

%% The table path peer_ready/3 reads: record → ready; unknown pubkey and non-pubkey ids are never ready.
peer_ready_table_test() ->
    Ns = <<"feed:ready">>,
    T  = ets:new(quod_feed:digest_table(Ns), [named_table, public, set]),
    ?assertNot(quod_feed:peer_ready(Ns, <<1>>, 0)),             %% no digest ever recorded
    true = quod_feed:record_digest(T, <<1>>, 7),
    ?assert(quod_feed:peer_ready(Ns, <<1>>, 7)),
    ?assert(quod_feed:peer_ready(Ns, <<1>>, 7 + 256)),          %% slack: one window behind the judge
    ?assertNot(quod_feed:peer_ready(Ns, <<1>>, 7 + 257)),
    true = quod_feed:record_digest(T, {"127.0.0.1", 1}, 9),     %% test/no-identity id: not tracked
    ?assertEqual([], ets:lookup(T, {"127.0.0.1", 1})),
    ets:delete(T).

%% No table at all (the feed is down/restarting, or never created): fail closed, never crash the proving
%% process. binary_to_existing_atom on a name whose table was never made throws badarg -> caught -> false.
peer_ready_no_table_test() ->
    ?assertNot(quod_feed:peer_ready(<<"feed:absent">>, <<1>>, 0)).

%%%===================================================================
%%% readiness_config_ok — the freshness↔digest-period boot guard
%%%===================================================================

%% The window (15000) must span at least two digest periods, so a node that digests too slowly (and could
%% never stay fresh enough to be admitted) is refused at boot instead of silently wedging committee growth.
readiness_config_test_() ->
    [ ?_assertEqual(ok, quod_feed:readiness_config_ok(3000)),            %% default: 5 periods fit
      ?_assertEqual(ok, quod_feed:readiness_config_ok(7500)),            %% boundary: window spans exactly 2
      ?_assertMatch({error, _}, quod_feed:readiness_config_ok(7501)),    %% one ms too slow
      ?_assertMatch({error, _}, quod_feed:readiness_config_ok(600000)) ].%% feed_SUITE's runtime push-isolation value
