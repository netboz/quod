-module(quod_token_bucket_tests).

-include_lib("eunit/include/eunit.hrl").

burst_refill_and_capacity_test() ->
    {ok, T1} = quod_token_bucket:charge(a, 1000, 2, 2, 2, 100, #{}),
    {ok, T2} = quod_token_bucket:charge(a, 1000, 2, 2, 2, 100, T1),
    {error, T3} = quod_token_bucket:charge(a, 1000, 2, 2, 2, 100, T2),
    {ok, T4} = quod_token_bucket:charge(a, 1500, 2, 2, 2, 100, T3),
    {ok, T5} = quod_token_bucket:charge(b, 1500, 2, 2, 2, 100, T4),
    {error, _T6} = quod_token_bucket:charge(c, 1500, 2, 2, 2, 100, T5).

full_table_prunes_idle_rows_before_admission_test() ->
    {ok, T1} = quod_token_bucket:charge(a, 0, 1, 1, 1, 100, #{}),
    {ok, T2} = quod_token_bucket:charge(b, 101, 1, 1, 1, 100, T1),
    ?assertEqual(false, maps:is_key(a, T2)),
    ?assert(maps:is_key(b, T2)).

malformed_row_fails_closed_test() ->
    {error, T1} = quod_token_bucket:charge(a, 1, 1, 1, 2, 100,
                                           #{a => malformed}),
    ?assertEqual(#{}, T1).
