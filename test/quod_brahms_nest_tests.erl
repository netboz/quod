-module(quod_brahms_nest_tests).
-include_lib("eunit/include/eunit.hrl").

-import(quod_brahms_nest, [new/1, observe/2, observe_all/2, rotate/1, estimate/1]).

%% empty sketch estimates 0
empty_test() ->
    ?assertEqual(0, estimate(new(128))).

%% below k: the estimate is the EXACT distinct count, and duplicates don't inflate it
exact_below_k_test() ->
    N  = observe_all(lists:seq(1, 50), new(128)),
    ?assertEqual(50, estimate(N)),
    N2 = observe_all(lists:seq(1, 50), N),          %% same ids again
    ?assertEqual(50, estimate(N2)).

%% above k: the KMV estimate is in the right ballpark (within 2x — generous so it
%% never flakes, but a broken estimator returns ~k or ~0 and fails).
estimate_above_k_test() ->
    E = estimate(observe_all(lists:seq(1, 5000), new(128))),
    ?assert(E > 2500 andalso E < 10000).

%% windowing: ids seen only in OLD windows age out after two rotations, so n̂
%% tracks the currently-live ids (which keep being re-observed).
window_ages_out_test() ->
    N0 = observe_all(lists:seq(1, 50), new(128)),   %% window A: 50 ids
    ?assertEqual(50, estimate(N0)),
    N1 = rotate(N0),                                %% A -> prev
    N2 = observe_all(lists:seq(51, 80), N1),        %% window B: 30 new ids
    ?assertEqual(80, estimate(N2)),                 %% counts A ∪ B
    N3 = rotate(N2),                                %% B -> prev, A dropped
    N4 = observe_all(lists:seq(51, 80), N3),        %% the 30 are still live
    ?assertEqual(30, estimate(N4)).                 %% the old 50 aged out
