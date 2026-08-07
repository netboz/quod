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
-export([eventually/2, stop_all/1, match_ok/1, ordinary_write_ok/1,
         peer_prove/3,
         datadir/2, generate_key_gt/1]).
-export([rp/2, rp/3, diff_for/1, change/2, change/3, batch/1, wait_until/1, wait_until/2]).
-export([commit_kb/1, commit_kb/3, set_ref/2, committed_kb/1, assert_facts/2]).

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
match_ok({badrpc, timeout}) ->
    throw({quod_retry_stop, {transport_timeout, peer_call}});
match_ok({ok, [_ | _], _}) -> true;
match_ok(_)                -> false.

%% Ordinary writes own their signed submission once accepted. A test may
%% resubmit only when the first attempt provably never entered custody.
%% In particular, skipped/retry/not_leader must fail the test: accepting any
%% of them here would hide a regression back to public slot-closure retries.
ordinary_write_ok({error, rebuilding}) ->
    false;
ordinary_write_ok({error, conflict_retry}) ->
    false;
ordinary_write_ok(Result) ->
    case match_ok(Result) of
        true ->
            true;
        false ->
            throw({quod_retry_stop, {ordinary_write_failed, Result}})
    end.

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

eventually_stops_on_transport_timeout_test() ->
    try eventually(fun() -> match_ok({badrpc, timeout}) end, 1000) of
        _ ->
            erlang:error(transport_timeout_was_retried)
    catch
        error:{unsafe_retry, {transport_timeout, peer_call}} ->
            ok
    end.

ordinary_write_does_not_retry_slot_closure_test() ->
    try eventually(
          fun() -> ordinary_write_ok({error, skipped}) end, 1000) of
        _ ->
            erlang:error(slot_closure_was_retried)
    catch
        error:{unsafe_retry, {ordinary_write_failed, {error, skipped}}} ->
            ok
    end.
-endif.

%% peer:call/4 defaults to five seconds, shorter than quod_prolog's 30-second
%% parked-write deadline. Let the application report outcome_unknown itself;
%% otherwise a test poll can resubmit a write that is still able to commit.
peer_prove(Peer, Ns, Goal) ->
    peer:call(Peer, quod_prolog, prove, [Ns, Goal, Ns], 35000).

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
%% body form matches what quod_prolog produces. No read set: only the write-set matters.
diff_for(Fact) ->
    {ok, C} = erlog_int:new(erlog_db_dict, null),
    W0 = quod_erlog_db_local_prove:wrap_state(C),
    {succeed, W1} = erlog_int:prove_goal({assertz, Fact}, W0),
    quod_erlog_db_local_prove:get_local_changes((W1#est.db)#db.ref).

%% publish a staged MVCC kb at `Version` with pruning floor `Floor` — the
%% committed state over which read-set overlays capture real version tokens.
commit_kb(Est) -> commit_kb(Est, 1, 1).

commit_kb(#est{db = #db{mod = quod_erlog_db_mvcc, ref = Ref} = Db} = Est,
          Version, Floor) ->
    Est#est{db = Db#db{ref = quod_erlog_db_mvcc:commit(Ref, Version, Floor)}}.

%% swap the db handle of an `#est{}` (e.g. after a direct mvcc mutation)
set_ref(#est{db = Db} = Est, Ref) -> Est#est{db = Db#db{ref = Ref}}.

%% a committed MVCC kb (unknown=fail) holding `Facts`, published at height 1
committed_kb(Facts) ->
    {ok, Erl} = erlog:new(quod_erlog_db_mvcc, null),
    State0 = element(3, Erl),
    {succeed, State1} =
        erlog_int:prove_goal({set_prolog_flag, unknown, fail}, State0),
    commit_kb(assert_facts(Facts, State1)).

%% assertz each erlog `Fact` into `Est`, failing loudly on the first refusal
assert_facts(Facts, Est) ->
    lists:foldl(
      fun(Fact, State) ->
              {succeed, Next} = erlog_int:prove_goal({assertz, Fact}, State),
              Next
      end, Est, Facts).

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
