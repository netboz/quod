-module(quod_committee_predicates_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ingress_limits.hrl").

%%%===================================================================
%%% The admit/remove external predicates, at the predicate level: they GATE + STAGE (prove-before-broadcast)
%%% — the resulting write-set is what quod_prolog's normal write path commits. We check the staged diff
%%% directly on a read-set overlay, so no consensus/quorum is needed (the end-to-end admit-a-member is in
%%% quod_ns_SUITE; the happy-path remove needs a live 2-node committee, so its retract shape is pinned here).
%%%===================================================================

%% A committed MVCC kb built exactly like quod_committed_projection:new_est/0
%% (admit/remove/peer_ready are common bridges, unknown=fail) plus optional
%% ontology-declared bridge modules, the real quod_root.pl (for can_join), and
%% the given peer_admitted facts, published at height 1.
kb(PeerAdmitted) ->
    kb(PeerAdmitted, []).

kb(PeerAdmitted, ExternalModules) ->
    {ok, Erl} = erlog:new(quod_erlog_db_mvcc, null),
    Est0 = element(3, Erl),
    {succeed, Est1} = erlog_int:prove_goal({set_prolog_flag, unknown, fail}, Est0),
    Est2 = quod_predicates:load(Est1),
    Est3 = quod_predicates:load_modules(Est2, ExternalModules),
    File = filename:join(code:priv_dir(quod), "ontologies/quod_root.pl"),
    Terms = quod_prolog:read_terms(File),
    quod_ct:commit_kb(quod_ct:assert_facts(Terms ++ PeerAdmitted, Est3)).

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

%% The predicate gives an honest caller the same bounded-committee result as
%% the authoritative proposal/history gate: member 64 can be staged, member
%% 65 cannot.
admit_enforces_validator_cap_test() ->
    Ns = <<"cp:cap">>,
    Members = [<<I:256>> || I <- lists:seq(0, ?MAX_VALIDATORS - 1)],
    Candidate = lists:last(Members),
    AtLimitChanges =
        with_ready(
          Ns, Candidate,
          fun() ->
              scope(
                ctx(Ns, kb([pa(Pk, "h", 1)
                            || Pk <- lists:droplast(Members)])),
                {admit, Candidate, "h", 1})
          end),
    ?assertMatch([{assert, {{peer_admitted, Candidate, "h", 1,
                             Candidate}, _}}], AtLimitChanges),
    Extra = <<?MAX_VALIDATORS:256>>,
    ?assertEqual(
       fail,
       with_ready(
         Ns, Extra,
         fun() ->
             scope(ctx(Ns, kb([pa(Pk, "h", 1) || Pk <- Members])),
                   {admit, Extra, "h", 1})
         end)).

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
%% side-effect-free) with a distinct context_violation error rather than running.
staging_refused_in_verdict_test() ->
    Ns = <<"cp:vd">>,
    Est = quod_predicates:set_context(kb([]), quod_predicates:verdict_context(Ns, 0)),
    ?assertEqual(context_violation, scope(Est, {admit, <<1>>, "h", 1})).

policy_verdict_refuses_live_query_bridge_test() ->
    Ns = <<"cp:policy-vd">>,
    Est = quod_predicates:set_context(
            kb([]), quod_predicates:policy_verdict_context(Ns, 0)),
    ?assertEqual(context_violation, scope(Est, {peer_ready, <<1>>})).
