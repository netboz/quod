-module(quod_brahms_tests).
-include_lib("eunit/include/eunit.hrl").

-import(quod_brahms, [split_counts/1, reconstruct/8, encode/1, decode/1, take_random/2, clean_resp/3]).

-define(CFG, #{view_size => 16, alpha => 0.45, beta => 0.45, gamma => 0.10}).

%% --- split_counts: shares sum to ℓ --------------------------------------

split_counts_test() ->
    {L1, L2, L3} = split_counts(?CFG),
    ?assertEqual(16, L1 + L2 + L3),
    ?assertEqual(7, L1),
    ?assertEqual(7, L2),
    ?assertEqual(2, L3).

%% the sampler must ALWAYS contribute (L3 >= 1), even for configs that would
%% otherwise starve it (alpha=beta=0.5 -> L3 would be 0 without the guard).
split_counts_no_starvation_test() ->
    {_, _, L3} = split_counts(#{view_size => 16, alpha => 0.5, beta => 0.5, gamma => 0.0}),
    ?assert(L3 >= 1).

%% --- pull responses are capped (pulls are attacker-controllable too) ----

clean_resp_caps_and_strips_self_test() ->
    Flood = [<<I:16>> || I <- lists:seq(1, 1000)],
    ?assert(length(clean_resp(Flood, 16, self_id)) =< 16),
    ?assertEqual([a, b], clean_resp([self_id, a, b], 16, self_id)).

%% --- reconstruct prioritizes the mixed candidates over OldV (no sort bias)
%% A sort-biased impl (usort + take-smallest) would wrongly fill V with the
%% low-sorting OldV ids instead of the high-sorting mixed candidates.
reconstruct_prioritizes_candidates_test() ->
    Push = [<<"z1">>], Pull = [<<"z2">>], Smpl = [<<"z3">>],
    OldV = [<<"a1">>, <<"a2">>, <<"a3">>, <<"a4">>],
    V = reconstruct(OldV, Push, Pull, Smpl, {1, 1, 1}, 3, self_id, false),
    ?assertEqual(3, length(V)),
    [?assert(lists:member(Z, V)) || Z <- [<<"z1">>, <<"z2">>, <<"z3">>]].

%% --- take_random: bounded, distinct, subset -----------------------------

take_random_test() ->
    L = [a, b, c, d, e],
    R = take_random(3, L),
    ?assertEqual(3, length(R)),
    ?assertEqual(3, length(lists:usort(R))),     %% distinct
    [?assert(lists:member(X, L)) || X <- R],
    ?assertEqual(lists:sort(L), lists:sort(take_random(99, L))).  %% N>=len -> all

%% --- reconstruct: under attack (Limited) the PUSH contribution is dropped,
%% but pull + sample still rebuild V (so the sampler keeps healing it). -----

reconstruct_limited_drops_push_test() ->
    V = reconstruct([old], [evil_push], [good_pull], [good_sample],
                    {1, 1, 1}, 16, self_id, true),
    ?assertNot(lists:member(evil_push, V)),
    ?assert(lists:member(good_pull, V)),
    ?assert(lists:member(good_sample, V)).

%% --- reconstruct: mixes sources, excludes self, bounded, non-empty ------

reconstruct_mix_test() ->
    Old   = [o1, o2],
    Push  = [a, b, c],
    Pull  = [d, e, f],
    Smpl  = [g, h],
    V = reconstruct(Old, Push, Pull, Smpl, {7, 7, 2}, 16, self_id, false),
    ?assert(length(V) =< 16),
    ?assert(length(V) >= 1),
    ?assertNot(lists:member(self_id, V)),
    All = Old ++ Push ++ Pull ++ Smpl,
    [?assert(lists:member(X, All)) || X <- V].

%% --- reconstruct: self is never admitted, even if pushed ----------------

reconstruct_excludes_self_test() ->
    V = reconstruct([], [self_id, a], [self_id], [self_id], {7, 7, 2}, 16, self_id, false),
    ?assertNot(lists:member(self_id, V)),
    ?assert(lists:member(a, V)).

%% --- reconstruct: empty candidates fall back to old view (no collapse) --

reconstruct_no_collapse_test() ->
    Old = [o1, o2],
    ?assertEqual(Old, reconstruct(Old, [], [], [], {7, 7, 2}, 16, self_id, false)).

%% --- wire codec: roundtrip + defensive decode ---------------------------

codec_roundtrip_test() ->
    Msgs = [{push, <<"n1">>}, {pull_req, {"127.0.0.1", 14567}}, {pull_resp, <<"me">>, [a, b]}],
    [?assertEqual(M, decode(encode(M))) || M <- Msgs].

decode_garbage_is_safe_test() ->
    ?assertEqual(error, decode(<<"not erlang term binary">>)),
    ?assertEqual(error, decode(<<0, 1, 2, 3>>)).
