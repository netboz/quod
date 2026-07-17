-module(quod_prolog_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").

%%%===================================================================
%%% fixtures
%%%===================================================================

setup() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"test:", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    {ok, Pid} = quod_prolog:start_link(
                  Ns, #{node_id => {"127.0.0.1", 5000}, max_proof_workers => 1}),
    %% no quod_simplex in these isolated tests — simulate the rebuild handshake completing
    ok = quod_prolog:mark_ready(Ns),
    {Ns, Pid}.

cleanup({_Ns, Pid}) ->
    case is_process_alive(Pid) of true -> gen_server:stop(Pid); false -> ok end,
    ok.

prolog_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun t_unknown_fails/1,
      fun t_apply_and_read/1,
      fun t_occ_reject/1,
      fun t_batch_apply/1,
      fun t_worker_limit/1]}.

absolute_proof_timeout_test_() ->
    {setup,
     fun() ->
         {ok, _} = application:ensure_all_started(gproc),
         Ns = <<"timeout:", (integer_to_binary(
                               erlang:unique_integer([positive])))/binary>>,
         {ok, Pid} = quod_prolog:start_link(
                       Ns, #{node_id => {"127.0.0.1", 5000},
                             proof_timeout_ms => 60}),
         ok = quod_prolog:mark_ready(Ns),
         {Ns, Pid}
     end,
     fun cleanup/1,
     fun({Ns, _Pid}) ->
         Rule = {':-', loop, loop},
         ok = ab(
                Ns, 1, batch(change(Ns, diff_for(Rule), #{}))),
         ?_assertEqual({error, no_progress},
                       quod_prolog:prove(Ns, loop, Ns))
     end}.

%% Slice B: the Prolog-side membership verdict + projection lockstep. Small validation TTL so the
%% reap-to-abstain case runs fast.
setup_mem() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"memtest:", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    {ok, Pid} = quod_prolog:start_link(
                  Ns, #{node_id => {"127.0.0.1", 5000}, validation_ttl_ms => 500}),
    ok = quod_prolog:mark_ready(Ns),
    {Ns, Pid}.

membership_test_() ->
    {foreach, fun setup_mem/0, fun cleanup/1,
     [fun t_verdict_basic/1,
      fun t_verdict_can_join_fail/1,
      fun t_verdict_side_effects/1,
      fun t_verdict_lifecycle/1,
      fun t_verdict_tag_reuse/1,
      fun t_lockstep/1]}.

%% Slice 1 increment 2: the post-apply event layer (doc/agent-fipa-plan.md §7) — apply origin drives
%% the applied_live event and the replay boundaries on the {runtime, Ns} property.
runtime_event_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun t_live_emits_event/1,
      fun t_replay_no_event/1,
      fun t_replay_reentry/1,
      fun t_no_boundary_without_advance/1]}.

%%%===================================================================
%%% helpers
%%%===================================================================

%% a real content-diff for asserting `Fact` (erlog term) — built via the overlay
%% so the clause body form matches what quod_prolog produces.
diff_for(Fact) ->
    Tab = list_to_atom("qpt_" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, C} = erlog_int:new(erlog_db_ets, Tab),
    W0 = quod_erlog_db_local_prove:wrap_state(C, #{read_set => true}),
    {succeed, W1} = erlog_int:prove_goal({assertz, Fact}, W0),
    Diff = quod_erlog_db_local_prove:get_local_changes((W1#est.db)#db.ref),
    quod_erlog_db_local_prove:cleanup_read_set(W1),
    Diff.

change(Ns, Diff, RC) ->
    #transaction{tx_id = integer_to_binary(erlang:unique_integer([positive])),
            caller_ns = Ns, diff = Diff, read_check = RC,
            author = {"127.0.0.1", 5000}, sig = none}.

batch(Transaction) -> {batch, [Transaction]}.

%% Apply a block as a LIVE commit (the common case these tests simulate). Increment-2 tests that need
%% the replay path call quod_prolog:apply_block/4 with `replay` explicitly.
ab(Ns, Index, Change) -> quod_prolog:apply_block(Ns, Index, Change, live).

%%%===================================================================
%%% tests
%%%===================================================================

t_unknown_fails({Ns, _}) ->
    fun() ->
        %% a goal over a predicate the ontology doesn't define → fail, not crash
        ?assertEqual(fail, quod_prolog:prove(Ns, {nonexistent, foo}, Ns)),
        %% routing: unknown namespace is distinct from goal-failure
        ?assertEqual({error, no_such_namespace},
                     quod_prolog:prove(<<"nope">>, {anything, x}, <<"nope">>))
    end.

t_apply_and_read({Ns, _}) ->
    fun() ->
        ok = ab(Ns, 1, batch(change(Ns, diff_for({parent, tom, bob}), #{}))),
        %% a bound read returns the binding and the height read
        ?assertMatch({ok, [#{'X' := bob}], 1}, quod_prolog:prove(Ns, {parent, tom, {'X'}}, Ns)),
        %% a ground read succeeds with an empty binding set
        ?assertEqual({ok, [#{}], 1}, quod_prolog:prove(Ns, {parent, tom, bob}, Ns)),
        %% a second committed block advances the applied height
        ok = ab(Ns, 2, batch(change(Ns, diff_for({parent, ann, eve}), #{}))),
        ?assertMatch({ok, [#{'P' := ann}], 2}, quod_prolog:prove(Ns, {parent, {'P'}, eve}, Ns))
    end.

t_occ_reject({Ns, _}) ->
    fun() ->
        ok = ab(Ns, 1, batch(change(Ns, diff_for({parent, tom, bob}), #{}))),
        %% a change whose read-set expects a stale hash of parent/2 → rejected at apply.
        %% apply_block is an async cast (returns ok); the OCC reject is observed by its
        %% EFFECT — the block changes no facts (sibling/1 stays absent). The apply_block cast
        %% is FIFO-ordered before the following prove call, so the effect is visible.
        Stale = change(Ns, diff_for({sibling, x}), #{{parent, 2} => 12345}),
        ok = ab(Ns, 2, batch(Stale)),
        ?assertEqual(fail, quod_prolog:prove(Ns, {sibling, x}, Ns)),
        %% a non-stale read-set (parent/2 matches its real hash) commits fine
        M = real_hash(Ns, {parent, 2}),
        Good = change(Ns, diff_for({sibling, y}), #{{parent, 2} => M}),
        ?assertEqual(ok, ab(Ns, 3, batch(Good))),
        ?assertEqual({ok, [#{}], 3}, quod_prolog:prove(Ns, {sibling, y}, Ns))
    end.

t_batch_apply({Ns, _}) ->
    fun() ->
        Parent = change(Ns, diff_for({parent, tom, bob}), #{}),
        Child = change(Ns, diff_for({child, bob}), #{}),
        ok = ab(Ns, 1, {batch, [Parent, Child]}),
        ?assertEqual({ok, [#{}], 1}, quod_prolog:prove(Ns, {parent, tom, bob}, Ns)),
        ?assertEqual({ok, [#{}], 1}, quod_prolog:prove(Ns, {child, bob}, Ns)),
        Stats = quod_prolog:stats(Ns),
        ?assertEqual(1, maps:get(applied, Stats)),
        ?assertEqual(2, maps:get(applies, Stats)),
        %% An improper batch is rejected as a whole: no prefix transaction can leak into the KB.
        Partial = change(Ns, diff_for({must_not_apply, x}), #{}),
        ok = ab(Ns, 2, {batch, [Partial | bad_tail]}),
        ?assertEqual(fail, quod_prolog:prove(Ns, {must_not_apply, x}, Ns)),
        Stats2 = quod_prolog:stats(Ns),
        ?assertEqual(2, maps:get(applied, Stats2)),
        ?assertEqual(2, maps:get(applies, Stats2))
    end.

t_worker_limit({Ns, _}) ->
    fun() ->
        Rule = {':-', loop, loop},
        ok = ab(Ns, 1, batch(change(Ns, diff_for(Rule), #{}))),
        Caller = spawn(fun() -> quod_prolog:prove(Ns, loop, Ns) end),
        ?assertEqual(ok, wait_proof_workers(Ns, 1, 100)),
        ?assertEqual({error, busy}, quod_prolog:prove(Ns, {anything, x}, Ns)),
        exit(Caller, kill),
        ?assertEqual(ok, wait_proof_workers(Ns, 0, 100))
    end.

wait_proof_workers(_Ns, _Expected, 0) -> timeout;
wait_proof_workers(Ns, Expected, Retries) ->
    case maps:get(proof_workers, quod_prolog:stats(Ns), undefined) of
        Expected -> ok;
        _ -> timer:sleep(10), wait_proof_workers(Ns, Expected, Retries - 1)
    end.

%%%===================================================================
%%% Slice B — membership verdict + lockstep
%%%===================================================================

%% helpers
mem_assert(Ns, Pk, H, P)  -> change(Ns, [{assert,  {{peer_admitted, Pk, H, P, Pk}, true}}], #{}).
mem_retract(Ns, Pk, H, P) -> change(Ns, [{retract, {{peer_admitted, Pk, H, P, Pk}, true}}], #{}).
canjoin_open(Ns)          -> change(Ns, diff_for({can_join, {'A'}, {'B'}, {'C'}}), #{}).

recv_verdict(Tag) -> receive {membership_verdict, Tag, V} -> V after 2000 -> timeout end.
no_verdict(Tag)   -> receive {membership_verdict, Tag, V} -> {unexpected, V} after 150 -> ok end.

%% ask + receive (used when applied == Slot-1, so the verdict is delivered immediately)
verdict(Ns, Change, Slot, Tag) ->
    ok = quod_prolog:request_membership_verdict(Ns, Change, Slot, self(), Tag),
    recv_verdict(Tag).

%% assert/dup/retract-present/retract-absent, judged against the parent-height kb.
t_verdict_basic({Ns, _}) ->
    fun() ->
        PkA = <<"pkA">>, PkB = <<"pkB">>,
        ok = ab(Ns, 1, batch(canjoin_open(Ns))),               %% default-open can_join
        ok = ab(Ns, 2, batch(mem_assert(Ns, PkA, "ha", 1))),   %% founder (lockstep applies it)
        %% applied == 2, so a verdict for Slot 3 (parent 2) is answered now
        ?assertEqual(valid, verdict(Ns, mem_assert(Ns, PkB, "hb", 2), 3, v1)),          %% new member
        ?assertEqual({invalid, already_admitted},
                     verdict(Ns, mem_assert(Ns, PkA, "ha", 1), 3, v2)),                 %% pubkey already admitted
        ?assertEqual(valid, verdict(Ns, mem_retract(Ns, PkA, "ha", 1), 3, v3)),         %% exact clause present
        ?assertEqual({invalid, no_such_member},
                     verdict(Ns, mem_retract(Ns, PkA, "WRONG", 9), 3, v4))              %% fabricated address
    end.

%% a narrowed can_join (only PkAllowed) rejects everyone else.
t_verdict_can_join_fail({Ns, _}) ->
    fun() ->
        PkAllowed = <<"pkAllowed">>, PkOther = <<"pkOther">>,
        ok = ab(Ns, 1, batch(change(Ns, diff_for({can_join, {'A'}, {'B'}, PkAllowed}), #{}))),
        ?assertEqual({invalid, can_join}, verdict(Ns, mem_assert(Ns, PkOther, "h", 1), 2, cf)),
        ?assertEqual(valid, verdict(Ns, mem_assert(Ns, PkAllowed, "h", 1), 2, cok))
    end.

%% a can_join that STAGES A WRITE is rejected (it must be side-effect-free).
t_verdict_side_effects({Ns, _}) ->
    fun() ->
        PkB = <<"pkB">>,
        Rule = {':-', {can_join, {'A'}, {'B'}, {'C'}}, {assertz, {sidelog, ok}}},
        ok = ab(Ns, 1, batch(change(Ns, diff_for(Rule), #{}))),
        ?assertEqual({invalid, can_join_side_effects}, verdict(Ns, mem_assert(Ns, PkB, "h", 1), 2, se))
    end.

%% park-until-parent-height (even when the parent lands on a noop), abstain-when-late, TTL reap.
t_verdict_lifecycle({Ns, _}) ->
    fun() ->
        PkB = <<"pkB">>,
        ok = ab(Ns, 1, batch(canjoin_open(Ns))),   %% applied == 1
        %% a verdict for Slot 3 (parent 2 > applied 1) parks — nothing delivered yet
        ok = quod_prolog:request_membership_verdict(Ns, mem_assert(Ns, PkB, "h", 1), 3, self(), park),
        ?assertEqual(ok, no_verdict(park)),
        %% advancing to height 2 via a NOOP still resolves it (shared tail across every apply path)
        ok = ab(Ns, 2, noop),
        ?assertEqual(valid, recv_verdict(park)),
        %% applied == 2: a verdict for Slot 2 (parent 1, already passed) abstains
        ?assertEqual(abstain, verdict(Ns, mem_assert(Ns, PkB, "h", 1), 2, late)),
        %% a verdict whose parent never arrives is reaped to abstain after the TTL (validation_ttl_ms=500)
        ok = quod_prolog:request_membership_verdict(Ns, mem_assert(Ns, PkB, "h", 1), 9, self(), ttl),
        ?assertEqual(abstain, recv_verdict(ttl))
    end.

%% Re-issuing a Tag still parked supersedes the old request: its timer is cancelled so it can't reap the
%% new one to a premature abstain, and the new request resolves at ITS own parent height — exactly once.
t_verdict_tag_reuse({Ns, _}) ->
    fun() ->
        PkB = <<"pkB">>,
        ok = ab(Ns, 1, batch(canjoin_open(Ns))),   %% applied == 1
        %% park Tag `t` for a far slot (parent 8, never reached)
        ok = quod_prolog:request_membership_verdict(Ns, mem_assert(Ns, PkB, "h", 1), 9, self(), t),
        %% re-issue the SAME Tag for a near slot (parent 2) — supersedes the far one + cancels its timer
        ok = quod_prolog:request_membership_verdict(Ns, mem_assert(Ns, PkB, "h", 1), 3, self(), t),
        ?assertEqual(ok, no_verdict(t)),                         %% neither has delivered yet
        ok = ab(Ns, 2, noop),               %% reach parent 2 → the NEW request resolves
        ?assertEqual(valid, recv_verdict(t)),
        %% the superseded far-slot timer was cancelled, so no stray abstain follows
        ?assertEqual(ok, no_verdict(t))
    end.

%% a committed membership tx applies UNCONDITIONALLY (skip OCC) — its projections stay in lockstep —
%% while a content tx with an equally-stale read_check is still OCC-rejected (the skip is scoped).
t_lockstep({Ns, _}) ->
    fun() ->
        PkB = <<"pkB">>,
        ok = ab(Ns, 1, batch(canjoin_open(Ns))),
        %% membership assert with a DELIBERATELY STALE read_check → still applies
        StaleMem = #{{peer_admitted, 4} => 999999},
        MemTx = (mem_assert(Ns, PkB, "h", 1))#transaction{read_check = StaleMem},
        ok = ab(Ns, 2, batch(MemTx)),
        %% the fact WAS applied (despite the stale read_check): PkB is now an admitted pubkey, so a fresh
        %% admit of it is rejected as already_admitted — this reads the committee via the same
        %% get_procedure path production uses (a direct prove of peer_admitted is a separate erlog quirk).
        ?assertEqual({invalid, already_admitted}, verdict(Ns, mem_assert(Ns, PkB, "h", 1), 3, lk)),
        %% content tx with an equally-stale read_check → still rejected (widget/z never asserted)
        StaleContent = change(Ns, diff_for({widget, z}), #{{widget, 1} => 12345}),
        ok = ab(Ns, 3, batch(StaleContent)),
        ?assertEqual(fail, quod_prolog:prove(Ns, {widget, z}, Ns))
    end.

%% A cast that does NOT advance the height — an already-applied no-op (Index =< applied) or a forward
%% gap (Index > applied+1, which bails to rebuild) — must NOT emit a replay boundary, even while the
%% engine is {replaying}. Regression for the note_origin ordering fix (boundaries gate on real advance).
t_no_boundary_without_advance({Ns, _}) ->
    fun() ->
        true = quod_reg:subscribe({runtime, Ns}),
        ok = quod_prolog:apply_block(Ns, 1, batch(change(Ns, diff_for({a, 1}), #{})), replay),
        {replay_started, Id, 0} = recv_rt(replay_started),
        %% already-applied live cast (Index 1 =< applied 1): no close, no event
        ok = quod_prolog:apply_block(Ns, 1, batch(change(Ns, diff_for({a, 1}), #{})), live),
        _ = quod_prolog:applied(Ns),        %% sync barrier: the cast above has been processed
        ok = refute_rt(replay_ready),
        ok = refute_rt(applied_live),
        %% forward-gap live cast (Index 5 > applied 1 + 1): no close either
        ok = quod_prolog:apply_block(Ns, 5, batch(change(Ns, diff_for({b, 5}), #{})), live),
        _ = quod_prolog:applied(Ns),
        ok = refute_rt(replay_ready),
        %% only a genuine advancing live apply closes the run (ready at the height replay reached)
        ok = quod_prolog:apply_block(Ns, 2, batch(change(Ns, diff_for({c, 2}), #{})), live),
        ?assertMatch({replay_ready, Id, 1}, recv_rt(replay_ready))
    end.

%% receive the next {runtime, Ns} message tagged Tag (selective — skips other tags), or fail.
recv_rt(Tag) ->
    receive M when element(1, M) =:= Tag -> M
    after 1000 -> erlang:error({no_runtime_msg, Tag}) end.

%% assert NO message tagged Tag arrives within a short window.
refute_rt(Tag) ->
    receive M when element(1, M) =:= Tag -> erlang:error({unexpected_runtime_msg, M})
    after 200 -> ok end.

%% (c) a LIVE commit publishes exactly one applied_live envelope at its height, carrying the diff and
%% tx id, and the committed fact is readable at that height (the event observes committed facts).
t_live_emits_event({Ns, _}) ->
    fun() ->
        true = quod_reg:subscribe({runtime, Ns}),
        Diff = diff_for({parent, tom, bob}),
        Tx = change(Ns, Diff, #{}),
        ok = quod_prolog:apply_block(Ns, 1, batch(Tx), live),
        {applied_live, Env} = recv_rt(applied_live),
        ?assertEqual(1, maps:get(height, Env)),
        ?assertEqual(Diff, maps:get(diff, Env)),
        ?assertEqual(Tx#transaction.tx_id, maps:get(tx_id, Env)),
        ?assertMatch({ok, [_], 1}, quod_prolog:prove(Ns, {parent, tom, {'X'}}, Ns))
    end.

%% (b) a REPLAY apply rebuilds D (fact readable) but publishes NO applied_live event — only the
%% replay_started boundary, carrying the height replay opened from.
t_replay_no_event({Ns, _}) ->
    fun() ->
        true = quod_reg:subscribe({runtime, Ns}),
        Tx = change(Ns, diff_for({parent, tom, bob}), #{}),
        ok = quod_prolog:apply_block(Ns, 1, batch(Tx), replay),
        ?assertMatch({replay_started, _Id, 0}, recv_rt(replay_started)),
        ok = refute_rt(applied_live),
        ?assertMatch({ok, [_], 1}, quod_prolog:prove(Ns, {parent, tom, {'X'}}, Ns))
    end.

%% (d) live -> replaying -> live -> replaying, without restarting quod_prolog: a replay run opens
%% (started), the resuming live apply closes the SAME run (ready, correlating Id) and fires its event,
%% and a second replay run mints a DISTINCT Id — so a consumer can ignore a stale boundary.
t_replay_reentry({Ns, _}) ->
    fun() ->
        true = quod_reg:subscribe({runtime, Ns}),
        ok = quod_prolog:apply_block(Ns, 1, batch(change(Ns, diff_for({a, 1}), #{})), live),
        ?assertMatch({applied_live, _}, recv_rt(applied_live)),
        %% gap-fill: replay at 2 opens a run from height 1; it is silent
        ok = quod_prolog:apply_block(Ns, 2, batch(change(Ns, diff_for({b, 2}), #{})), replay),
        {replay_started, Id, 1} = recv_rt(replay_started),
        ok = refute_rt(applied_live),
        %% the resuming live apply at 3 closes the run (same Id, ready height 2), then fires the event
        ok = quod_prolog:apply_block(Ns, 3, batch(change(Ns, diff_for({c, 3}), #{})), live),
        ?assertMatch({replay_ready, Id, 2}, recv_rt(replay_ready)),
        ?assertMatch({applied_live, #{height := 3}}, recv_rt(applied_live)),
        %% a second replay run mints a DISTINCT Id (stale-boundary immunity)
        ok = quod_prolog:apply_block(Ns, 4, batch(change(Ns, diff_for({d, 4}), #{})), replay),
        {replay_started, Id2, 3} = recv_rt(replay_started),
        ?assertNotEqual(Id, Id2)
    end.

%% read the committed hash of a predicate by asking quod_prolog to prove a probe
%% that records it — simplest is to recompute against a mirror of the same facts.
real_hash(_Ns, Functor) ->
    %% mirror the committed parent(tom,bob) into a throwaway db and hash it
    Tab = list_to_atom("qph_" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, C0} = erlog_int:new(erlog_db_ets, Tab),
    {succeed, C1} = erlog_int:prove_goal({assertz, {parent, tom, bob}}, C0),
    quod_diff:functor_hash((C1#est.db)#db.mod, (C1#est.db)#db.ref, Functor).
