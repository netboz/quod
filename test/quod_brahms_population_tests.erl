-module(quod_brahms_population_tests).
-include_lib("eunit/include/eunit.hrl").

identity() ->
    {Pub, Seed} = quod_identity:generate(),
    #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}.

exact_below_k_test() ->
    Now = erlang:system_time(millisecond),
    Ps = [identity() || _ <- lists:seq(1, 30)],
    Records = lists:append([quod_brahms_population:records(
                              quod_brahms_population:tick(
                                quod_brahms_population:new(I, 128, 60000, 1000), Now)) || I <- Ps]),
    P = quod_brahms_population:merge(Records,
        quod_brahms_population:new(undefined, 128, 60000, 1000)),
    ?assertEqual(30, quod_brahms_population:estimate(P)).

expired_heartbeats_are_not_kept_alive_by_forwarding_test() ->
    Now = erlang:system_time(millisecond),
    I = identity(),
    Source = quod_brahms_population:tick(quod_brahms_population:new(I, 16, 100, 10), Now),
    [R] = quod_brahms_population:records(Source),
    P0 = quod_brahms_population:merge([R], quod_brahms_population:new(undefined, 16, 100, 10)),
    timer:sleep(120),
    P1 = quod_brahms_population:merge([R], P0),
    ?assertEqual(0, quod_brahms_population:estimate(P1)).

tampered_heartbeat_is_rejected_test() ->
    Now = erlang:system_time(millisecond),
    I = identity(),
    [R] = quod_brahms_population:records(
              quod_brahms_population:tick(quod_brahms_population:new(I, 16, 60000, 1000), Now)),
    {population_v1, Pub, At, Sig} = R,
    P = quod_brahms_population:merge([{population_v1, Pub, At + 1, Sig}],
        quod_brahms_population:new(undefined, 16, 60000, 1000)),
    ?assertEqual(0, quod_brahms_population:estimate(P)).
