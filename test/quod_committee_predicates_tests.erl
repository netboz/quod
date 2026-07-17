-module(quod_committee_predicates_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

%%%===================================================================
%%% The admit/remove external predicates, at the predicate level: they GATE + STAGE (prove-before-broadcast)
%%% — the resulting write-set is what quod_prolog's normal write path commits. We check the staged diff
%%% directly on a read-set overlay, so no consensus/quorum is needed (the end-to-end admit-a-member is in
%%% quod_ns_SUITE; the happy-path remove needs a live 2-node committee, so its retract shape is pinned here).
%%%===================================================================

%% a committed erlog_db_dict kb built exactly like quod_prolog:build_kb (admit/remove/peer_ready
%% class-registered via quod_predicates, unknown=fail) + the real quod_root.pl (for can_join) + the
%% given peer_admitted facts.
kb(PeerAdmitted) ->
    {ok, Erl} = erlog:new(erlog_db_dict, null),
    Est0 = element(3, Erl),
    {succeed, Est1} = erlog_int:prove_goal({set_prolog_flag, unknown, fail}, Est0),
    Est2 = quod_predicates:load(Est1),
    File = filename:join(code:priv_dir(quod), "ontologies/quod_root.pl"),
    Terms = quod_prolog:read_terms(File),
    lists:foldl(fun(T, E) -> {succeed, E1} = erlog_int:prove_goal({assertz, T}, E), E1 end,
                Est2, Terms ++ PeerAdmitted).

pa(Pub, Host, Port) -> {peer_admitted, Pub, Host, Port, Pub}.

%% Set a proof execution context (`m:quod_predicates`) on the kb — the governed predicates are
%% class-gated on it (`staging`/`query` allowed in a proof), and admit/peer_ready read the namespace
%% and applied height (0) from it. Every real call runs inside such a context.
ctx(Ns, Est) -> quod_predicates:set_context(Est, quod_predicates:proof_context(Ns, 0, undefined)).

%% run Goal on a fresh read-set overlay over the kb; return the staged write-set, `fail`, or
%% `context_violation` (a governed predicate refused for its class in the running context).
scope(Est, Goal) ->
    W0 = quod_erlog_db_local_prove:wrap_state(Est, #{read_set => true}),
    try erlog_int:prove_goal(Goal, W0) of
        {succeed, W1} -> quod_erlog_db_local_prove:get_local_changes(db_ref(W1));
        {fail, _}     -> fail
    catch
        throw:{erlog_error, {context_violation, _, _, _}} -> context_violation
    after
        quod_erlog_db_local_prove:cleanup_read_set(W0)
    end.

db_ref(#est{db = #db{ref = R}}) -> R.

%% Run Fun with the readiness environment quod_root.pl's `can_join :- peer_ready(Pk)` reads: Ns's digest
%% table holding a fresh digest for Pub (as if it had been feed-following) at our own height. The namespace
%% and applied-height now travel in the proof context (see ctx/2), not the process dictionary.
with_ready(Ns, Pub, Fun) ->
    T = ets:new(quod_feed:digest_table(Ns), [named_table, public, set]),
    true = quod_feed:record_digest(T, Pub, 0),
    try Fun() after ets:delete(T) end.

%% admit(Pub,Host,Port): gate can_join (peer_ready-gated) then stage the peer_admitted assert (NodeId = Pub).
admit_stages_peer_admitted_test() ->
    Ns = <<"cp:test">>, Pub = <<1, 2, 3>>,
    Changes = with_ready(Ns, Pub, fun() -> scope(ctx(Ns, kb([])), {admit, Pub, "10.0.0.9", 9000}) end),
    ?assertMatch([{assert, {{peer_admitted, <<1, 2, 3>>, "10.0.0.9", 9000, <<1, 2, 3>>}, _}}], Changes).

%% The readiness gate: a candidate with NO fresh digest (dead, cold, or mid-recovery — it never digests
%% until `syncing=false`) is refused at the rule, so nothing is staged.
admit_unready_fails_test() ->
    Ns = <<"cp:unready">>, Ready = <<7>>, Cold = <<8>>,
    ?assertEqual(fail, with_ready(Ns, Ready,
                                  fun() -> scope(ctx(Ns, kb([])), {admit, Cold, "10.0.0.9", 9000}) end)).

%% admit with NO execution context: the class dispatcher fails closed (no managed context ⇒ no solution),
%% so nothing is staged.
admit_without_context_fails_test() ->
    ?assertEqual(fail, scope(kb([]), {admit, <<9>>, "h", 1})).

%% remove(Pub) retracts BY PATTERN — the staged op carries the fact's REAL address, so the kb and the
%% validator set (which keys on the pubkey) retract the SAME head and can't diverge.
remove_retracts_real_address_test() ->
    A = <<10>>, B = <<20>>,
    Changes = scope(ctx(<<"cp:rm">>, kb([pa(A, "hosta", 1), pa(B, "hostb", 2222)])), {remove, B}),
    ?assertMatch([{retract, {{peer_admitted, <<20>>, "hostb", 2222, <<20>>}, _}}], Changes).

%% remove refuses to empty the committee: a single-member kb → remove fails, nothing staged.
remove_refuses_last_test() ->
    A = <<10>>,
    ?assertEqual(fail, scope(ctx(<<"cp:rm">>, kb([pa(A, "h", 1)])), {remove, A})).

%% removing a non-member fails cleanly (retract-by-pattern finds no match) — with >1 member so the floor
%% guard isn't what trips it.
remove_nonmember_fails_test() ->
    A = <<10>>, B = <<20>>,
    ?assertEqual(fail, scope(ctx(<<"cp:rm">>, kb([pa(A, "h", 1), pa(B, "h", 2)])), {remove, <<99>>})).

%% A `staging` predicate is refused inside a VERDICT context (a membership re-proof must be
%% side-effect-free), and an `effect`-class predicate is refused inside a proof — both fail closed
%% with the distinct context_violation error rather than running.
staging_refused_in_verdict_test() ->
    Ns = <<"cp:vd">>,
    Est = quod_predicates:set_context(kb([]), quod_predicates:verdict_context(Ns, 0)),
    ?assertEqual(context_violation, scope(Est, {admit, <<1>>, "h", 1})).

effect_refused_in_proof_test() ->
    ?assertEqual(context_violation, scope(ctx(<<"cp:eff">>, kb([])), effect_noop)).
