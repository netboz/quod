#!/usr/bin/env escript
%%! -pa _build/default/lib/quod/ebin

-mode(compile).
-include("../include/quod_ledger.hrl").

-define(NS, <<"bench:signatures">>).

main(Args) ->
    case parse_args(Args, 100) of
        help ->
            usage();
        {ok, Iterations} ->
            application:ensure_all_started(crypto),
            erlang:system_flag(scheduler_wall_time, true),
            io:format("iterations=~B (core validation; Prometheus process not started)~n",
                      [Iterations]),
            io:format("count operation p50_batch_us p95_batch_us p50_tx_us "
                      "p95_tx_us reductions scheduler_utilization~n"),
            lists:foreach(fun(Count) -> bench_count(Count, Iterations) end,
                          [1, 64, 256])
    end.

usage() ->
    io:format(
      "Usage: escript scripts/bench-signatures.escript [--iterations N]~n"
      "~n"
      "Benchmarks Ed25519 transaction signing and current-rule batch validation~n"
      "for 1, 64, and 256 transactions. N defaults to 100 and must be positive.~n").

parse_args([], Iterations) ->
    {ok, Iterations};
parse_args(["--help"], _Iterations) ->
    help;
parse_args(["-h"], _Iterations) ->
    help;
parse_args(["--iterations", Value], _Iterations) ->
    positive_integer(Value);
parse_args(_, _Iterations) ->
    usage(),
    halt(2).

positive_integer(Value) ->
    try list_to_integer(Value) of
        N when N > 0 -> {ok, N};
        _ -> usage(), halt(2)
    catch
        _:_ -> usage(), halt(2)
    end.

bench_count(Count, Iterations) ->
    {Pub, Seed} = quod_identity:generate(),
    Identity = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
    Unsigned = [transaction(Pub, N) || N <- lists:seq(1, Count)],
    Signed = sign_batch(Unsigned, Identity),
    true = quod_simplex:valid_history_entry(
             ?NS, 2, {batch, Signed}, [Pub]),
    report(Count, signing, Iterations,
           fun() -> sign_batch(Unsigned, Identity) end),
    report(Count, validation, Iterations,
           fun() ->
               true = quod_simplex:valid_history_entry(
                        ?NS, 2, {batch, Signed}, [Pub])
           end).

transaction(Pub, N) ->
    #transaction{
       tx_id = <<N:64>>,
       caller_ns = ?NS,
       goal = {assertz, {bench_value, N}},
       result = #{},
       diff = [{assert, {{bench_value, N}, true}}],
       read_check = #{},
       author = Pub,
       author_seq = N,
       submitted_at = 1750000000000 + N,
       sig = none}.

sign_batch(Transactions, Identity) ->
    [begin
         {ok, Signed} = quod_transaction:sign(?NS, Transaction, Identity),
         Signed
     end || Transaction <- Transactions].

report(Count, Operation, Iterations, Fun) ->
    {reductions, Reductions0} = process_info(self(), reductions),
    Schedulers0 = scheduler_totals(),
    Samples = [begin {Micros, _} = timer:tc(Fun), Micros end
               || _ <- lists:seq(1, Iterations)],
    Schedulers1 = scheduler_totals(),
    {reductions, Reductions1} = process_info(self(), reductions),
    P50 = percentile(Samples, 50),
    P95 = percentile(Samples, 95),
    Utilization = scheduler_utilization(Schedulers0, Schedulers1),
    io:format("~B ~s ~B ~B ~.2f ~.2f ~B ~.4f~n",
              [Count, Operation, P50, P95, P50 / Count, P95 / Count,
               Reductions1 - Reductions0, Utilization]).

percentile(Samples, Percent) ->
    Sorted = lists:sort(Samples),
    Index = max(1, (length(Sorted) * Percent + 99) div 100),
    lists:nth(Index, Sorted).

scheduler_totals() ->
    lists:foldl(
      fun({_Id, Active, Total}, {ActiveAcc, TotalAcc}) ->
              {ActiveAcc + Active, TotalAcc + Total}
      end, {0, 0}, erlang:statistics(scheduler_wall_time)).

scheduler_utilization({Active0, Total0}, {Active1, Total1}) ->
    case Total1 - Total0 of
        0 -> 0.0;
        Total -> (Active1 - Active0) / Total
    end.
