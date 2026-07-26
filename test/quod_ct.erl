-module(quod_ct).
-moduledoc """
Shared test helpers (Common Test AND eunit), extracted from the per-module copies
(deferred cleanup #1).

These were byte-identical across suites/modules, so they live here once and are pulled in
via `-import(quod_ct, [...])` so call sites read unchanged (`eventually(F, T)`, `rp(Ns, G)`,
`diff_for(Fact)`, …). Helpers that genuinely vary — node boot (`start_peer`/`start_member`),
the self-signed dev cert (`make_cert`, whose CN differs), and the `?NS`-bound query helpers
(`status`/`role`/`prove`) — stay in their suites. `replica_SUITE` keeps its own
slightly-different `eventually`/`match_ok`/`datadir` variants.
""".
-include_lib("common_test/include/ct.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
-export([eventually/2, stop_all/1, match_ok/1, datadir/2, generate_key_gt/1]).
-export([rp/2, rp/3, diff_for/1, change/2, change/3, batch/1, wait_until/1, wait_until/2]).

%% Poll `F` every 150ms until it returns `true` or the budget runs out.
eventually(_F, Timeout) when Timeout =< 0 -> false;
eventually(F, Timeout) ->
    case (catch F()) of
        true ->
            true;
        {quod_retry_stop, Reason} ->
            erlang:error({unsafe_retry, Reason});
        _ ->
            timer:sleep(150),
            eventually(F, Timeout - 150)
    end.

%% Best-effort stop of a list of `peer` nodes (never throws).
stop_all(Peers) -> _ = [catch peer:stop(P) || P <- Peers], ok.

%% A `quod_prolog:prove/3` result with at least one binding.
%% A local deadline does not prove that a write failed. Tag it so even a nested
%% `lists:any/2` callback escapes `eventually/2` instead of resubmitting it.
match_ok({error, {outcome_unknown, TxId}}) ->
    throw({quod_retry_stop, {outcome_unknown, TxId}});
match_ok({ok, [_ | _], _}) -> true;
match_ok(_)                -> false.

-ifdef(TEST).
eventually_stops_on_unknown_outcome_test() ->
    TxId = <<"uncertain">>,
    try eventually(
          fun() -> match_ok({error, {outcome_unknown, TxId}}) end, 1000) of
        _ ->
            erlang:error(unknown_outcome_was_retried)
    catch
        error:{unsafe_retry, {outcome_unknown, TxId}} ->
            ok
    end.
-endif.

%% A per-port data_dir under the suite's private dir.
datadir(Config, Port) -> filename:join(?config(priv_dir, Config), "data_" ++ integer_to_list(Port)).

%% A fresh Ed25519 keypair whose pubkey sorts strictly after `Lo` (Erlang term order = the order
%% quod_simplex:leader/2 sorts by), so a suite can pin round-robin leadership deterministically.
generate_key_gt(Lo) ->
    {P, _} = Key = quod_identity:generate(),
    case P > Lo of true -> Key; false -> generate_key_gt(Lo) end.

%% prove, retrying only while the engine is still rebuilding (a transient state right after a
%% (re)start). `fail`/`{ok,_,_}`/other answers are returned as-is. Was copied per-module 4x.
rp(Ns, Goal) -> rp(Ns, Goal, 300).
rp(_Ns, _Goal, 0) -> {error, timeout};
rp(Ns, Goal, N) ->
    case quod_prolog:prove(Ns, Goal, Ns) of
        {error, rebuilding} -> timer:sleep(10), rp(Ns, Goal, N - 1);
        R -> R
    end.

%% a real content-diff asserting `Fact` (erlog term) — built via the overlay so the clause
%% body form matches what quod_prolog produces.
diff_for(Fact) ->
    Tab = list_to_atom("qct_" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, C} = erlog_int:new(erlog_db_ets, Tab),
    W0 = quod_erlog_db_local_prove:wrap_state(C, #{read_set => true}),
    {succeed, W1} = erlog_int:prove_goal({assertz, Fact}, W0),
    Diff = quod_erlog_db_local_prove:get_local_changes((W1#est.db)#db.ref),
    quod_erlog_db_local_prove:cleanup_read_set(W1),
    Diff.

%% a well-shaped unsigned test transaction carrying `Diff` (+ optional OCC read_check)
change(Ns, Diff) -> change(Ns, Diff, #{}).
change(Ns, Diff, RC) ->
    #transaction{tx_id = integer_to_binary(erlang:unique_integer([positive])),
                 caller_ns = Ns, diff = Diff, read_check = RC,
                 author = {"127.0.0.1", 5000}, sig = none}.

batch(Tx) -> {batch, [Tx]}.

%% Poll `F` (a boolean condition, side effects allowed) every 50 ms until true; error out
%% after `N` tries. The eunit sibling of `eventually/2`.
wait_until(F) -> wait_until(F, 100).
wait_until(_F, 0) -> erlang:error(condition_never_true);
wait_until(F, N) ->
    case F() of
        true -> ok;
        _    -> timer:sleep(50), wait_until(F, N - 1)
    end.
