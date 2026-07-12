-module(quod_committee_predicates_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

%%%===================================================================
%%% The admit/remove external predicates, at the predicate level: they GATE + STAGE (prove-before-broadcast)
%%% — the resulting write-set is what quod_prolog's normal write path commits. We check the staged diff
%%% directly on a read-set overlay, so no consensus/quorum is needed (the end-to-end admit-a-member is in
%%% quod_ns_SUITE; the happy-path remove needs a live 2-node committee, so its retract shape is pinned here).
%%%===================================================================

%% a committed erlog_db_dict kb built exactly like quod_prolog:build_kb (admit/remove registered,
%% unknown=fail) + the real quod_root.pl (for can_join) + the given peer_admitted facts.
kb(PeerAdmitted) ->
    {ok, Erl} = erlog:new(erlog_db_dict, null),
    Est0 = element(3, Erl),
    {succeed, Est1} = erlog_int:prove_goal({set_prolog_flag, unknown, fail}, Est0),
    Est2 = quod_committee_predicates:load(Est1),
    File = filename:join(code:priv_dir(quod), "ontologies/quod_root.pl"),
    Terms = quod_prolog:read_terms(File),
    lists:foldl(fun(T, E) -> {succeed, E1} = erlog_int:prove_goal({assertz, T}, E), E1 end,
                Est2, Terms ++ PeerAdmitted).

pa(Pub, Host, Port) -> {peer_admitted, Pub, Host, Port, Pub}.

%% run Goal on a fresh read-set overlay over the kb; return the staged write-set, or `fail`.
scope(Est, Goal) ->
    W0 = quod_erlog_db_local_prove:wrap_state(Est, #{read_set => true}),
    try erlog_int:prove_goal(Goal, W0) of
        {succeed, W1} -> quod_erlog_db_local_prove:get_local_changes(db_ref(W1));
        {fail, _}     -> fail
    after
        quod_erlog_db_local_prove:cleanup_read_set(W0)
    end.

db_ref(#est{db = #db{ref = R}}) -> R.

%% Run Fun with the readiness environment quod_root.pl's `can_join :- peer_ready(Pk)` reads: the pdict
%% namespace + applied-height mirror (both primed by quod_prolog:init in the real flow), and Ns's digest
%% table holding a fresh digest for Pub (as if it had been feed-following) at our own height.
with_ready(Ns, Pub, Fun) ->
    put('$quod_ns', Ns),
    put('$quod_applied', 0),
    T = ets:new(quod_feed:digest_table(Ns), [named_table, public, set]),
    true = quod_feed:record_digest(T, Pub, 0),
    try Fun() after ets:delete(T), erase('$quod_ns'), erase('$quod_applied') end.

%% admit(Pub,Host,Port): gate can_join (peer_ready-gated) then stage the peer_admitted assert (NodeId = Pub).
admit_stages_peer_admitted_test() ->
    Pub = <<1, 2, 3>>,
    Changes = with_ready(<<"cp:test">>, Pub, fun() -> scope(kb([]), {admit, Pub, "10.0.0.9", 9000}) end),
    ?assertMatch([{assert, {{peer_admitted, <<1, 2, 3>>, "10.0.0.9", 9000, <<1, 2, 3>>}, _}}], Changes).

%% The readiness gate: a candidate with NO fresh digest (dead, cold, or mid-catch-up — it never digests
%% until join=done) is refused at the rule, so nothing is staged.
admit_unready_fails_test() ->
    Ready = <<7>>, Cold = <<8>>,
    ?assertEqual(fail, with_ready(<<"cp:unready">>, Ready,
                                  fun() -> scope(kb([]), {admit, Cold, "10.0.0.9", 9000}) end)).

%% admit fails closed with no namespace stashed (self_ns undefined) — never stages a half-formed fact.
admit_without_ns_fails_test() ->
    erase('$quod_ns'),
    ?assertEqual(fail, scope(kb([]), {admit, <<9>>, "h", 1})).

%% remove(Pub) retracts BY PATTERN — the staged op carries the fact's REAL address, so the kb and the
%% validator set (which keys on the pubkey) retract the SAME head and can't diverge.
remove_retracts_real_address_test() ->
    A = <<10>>, B = <<20>>,
    Changes = scope(kb([pa(A, "hosta", 1), pa(B, "hostb", 2222)]), {remove, B}),
    ?assertMatch([{retract, {{peer_admitted, <<20>>, "hostb", 2222, <<20>>}, _}}], Changes).

%% remove refuses to empty the committee: a single-member kb → remove fails, nothing staged.
remove_refuses_last_test() ->
    A = <<10>>,
    ?assertEqual(fail, scope(kb([pa(A, "h", 1)]), {remove, A})).

%% removing a non-member fails cleanly (retract-by-pattern finds no match) — with >1 member so the floor
%% guard isn't what trips it.
remove_nonmember_fails_test() ->
    A = <<10>>, B = <<20>>,
    ?assertEqual(fail, scope(kb([pa(A, "h", 1), pa(B, "h", 2)]), {remove, <<99>>})).
