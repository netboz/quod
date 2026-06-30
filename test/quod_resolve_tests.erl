-module(quod_resolve_tests).
-include_lib("eunit/include/eunit.hrl").

%% The transport resolver: a pubkey resolves to a learned endpoint; an endpoint dials
%% direct; an unknown pubkey / bad target is a miss. (quod_quic:learn/2 + resolve/1 work
%% on a public named ETS, so they run standalone without the gen_server.)

resolve_endpoint_direct_test() ->
    ?assertEqual({ok, {"h", 5}}, quod_quic:resolve({"h", 5})),
    ?assertEqual({ok, {<<"h">>, 14567}}, quod_quic:resolve({<<"h">>, 14567})),
    ?assertEqual(error, quod_quic:resolve({"h", 0})),        %% port out of range
    ?assertEqual(error, quod_quic:resolve({"h", 70000})),
    ?assertEqual(error, quod_quic:resolve(an_atom)).

learn_then_resolve_test() ->
    PK = crypto:strong_rand_bytes(32),
    ?assertEqual(error, quod_quic:resolve(PK)),              %% unknown pubkey ⇒ miss
    ok = quod_quic:learn(PK, {"10.0.0.1", 14567}),
    ?assertEqual({ok, {"10.0.0.1", 14567}}, quod_quic:resolve(PK)),
    %% re-learning updates the hint (a moved peer)
    ok = quod_quic:learn(PK, {"10.0.0.9", 14567}),
    ?assertEqual({ok, {"10.0.0.9", 14567}}, quod_quic:resolve(PK)).

learn_ignores_non_pubkey_test() ->
    %% a non-binary id has nothing to resolve; learn is a no-op, resolve is a miss
    ?assertEqual(ok, quod_quic:learn({"h", 1}, {"h", 1})),
    ?assertEqual(error, quod_quic:resolve(<<"short">>)).     %% binary but not learned
