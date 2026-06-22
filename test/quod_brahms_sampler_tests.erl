-module(quod_brahms_sampler_tests).
-include_lib("eunit/include/eunit.hrl").

-import(quod_brahms_sampler, [new/1, observe/2, observe_all/2, sample/1, invalidate/2, slots/1]).

%% --- basics --------------------------------------------------------------

empty_test() ->
    S = new(5),
    ?assertEqual(5, slots(S)),
    ?assertEqual([], sample(S)).

observe_and_sample_test() ->
    Ids = [<<"a">>, <<"b">>, <<"c">>],
    Got = sample(observe_all(Ids, new(3))),
    ?assert(length(Got) =< 3),                       %% multiset over 3 slots
    [?assert(lists:member(Id, Ids)) || Id <- Got].

%% --- THE property: flooding does NOT bias the sample --------------------
%% One Byzantine id presented 1000x vs 99 honest ids once each. With a single
%% min-wise slot, P(evil wins) is ~1/100 regardless of multiplicity. The band
%% [1, 2x] around the expected count catches a *partial* flood-leak (e.g. a bug
%% giving P~0.09), not just the catastrophic "always picks evil".
anti_flood_test_() ->
    {timeout, 60, fun() ->
        Trials = 2000,
        Honest = [<<I:32>> || I <- lists:seq(1, 99)],
        EvilCnt =
            lists:foldl(
              fun(_, Acc) ->
                  Stream = shuffle([<<"EVIL">> || _ <- lists:seq(1, 1000)] ++ Honest),
                  case sample(observe_all(Stream, new(1))) of
                      [<<"EVIL">>] -> Acc + 1;
                      _ -> Acc
                  end
              end, 0, lists:seq(1, Trials)),
        Expect = Trials div 100,                     %% ~20
        ?assert(EvilCnt > 0),                        %% it IS sampled, ~1/100
        ?assert(EvilCnt < Expect * 2)                %% but never flood-dominated
    end}.

%% --- order independence: same SET, fixed adversarial orders, same keys --
%% Reuses ONE empty (already-keyed) sampler so every order shares the slot keys;
%% min-wise + the collision tie-break must make the result order-independent.
order_independence_test() ->
    Ids = [<<I:16>> || I <- lists:seq(1, 64)],
    S0  = new(16),
    Asc  = sample(observe_all(Ids, S0)),
    Desc = sample(observe_all(lists:reverse(Ids), S0)),
    Shuf = sample(observe_all(shuffle(Ids), S0)),
    ?assertEqual(Asc, Desc),
    ?assertEqual(Asc, Shuf).

%% --- uniformity: each distinct id ~equally likely -----------------------
uniformity_test_() ->
    {timeout, 60, fun() ->
        Ids    = [<<I:8>> || I <- lists:seq(1, 10)],
        Trials = 2000,
        Counts =
            lists:foldl(
              fun(_, Acc) ->
                  [Picked] = sample(observe_all(shuffle(Ids), new(1))),
                  maps:update_with(Picked, fun(C) -> C + 1 end, 1, Acc)
              end, #{}, lists:seq(1, Trials)),
        Expect = Trials div length(Ids),             %% 200
        [begin
             C = maps:get(Id, Counts, 0),
             ?assert(C > Expect div 2),              %% within ~2x band -> uniform
             ?assert(C < Expect * 2)
         end || Id <- Ids]
    end}.

%% --- slots are independent (distinct keys) ------------------------------
%% A copy/paste bug sharing one key across slots would make every slot agree, so
%% sample/1 would return one distinct id. Guard against it.
distinct_keys_test() ->
    Ids = [<<I:16>> || I <- lists:seq(1, 200)],
    Got = sample(observe_all(Ids, new(50))),
    ?assert(length(lists:usort(Got)) > 1).

%% --- secret-key regression: catches a swap to a keyless/predictable hash -
%% Two samplers with different keys, same input, must (almost surely) disagree.
%% If someone replaced the keyed HMAC with phash2 (no key), both would be
%% identical and this fails.
key_secrecy_test() ->
    Ids = [<<I:16>> || I <- lists:seq(1, 200)],
    S1  = sample(observe_all(Ids, new(20))),
    S2  = sample(observe_all(Ids, new(20))),
    ?assertNotEqual(S1, S2).

%% --- invalidate resets slots holding the failed id ----------------------

invalidate_test() ->
    S0 = observe(<<"x">>, new(1)),
    ?assertEqual([<<"x">>], sample(S0)),
    S1 = invalidate(<<"x">>, S0),
    ?assertEqual([], sample(S1)),                    %% slot cleared (new key)
    S2 = observe(<<"y">>, S1),
    ?assertEqual([<<"y">>], sample(S2)).             %% re-samples afresh

%% --- helpers -------------------------------------------------------------

shuffle(L) ->
    [X || {_, X} <- lists:sort([{rand:uniform(), E} || E <- L])].
