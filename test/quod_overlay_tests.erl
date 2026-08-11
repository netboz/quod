-module(quod_overlay_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

%%%===================================================================
%%% helpers
%%%===================================================================

%% a committed erlog db (quod_erlog_db_mvcc) with `Facts` (erlog terms)
%% committed at height 1 — read-set capture records real version tokens
committed(Facts) -> quod_ct:committed_kb(Facts).

%% commit one more `Fact` into C's shared table at `Version`; the returned
%% handle reads at the new height, like the apply-time validator does
mutated(C, Fact, Version) ->
    {succeed, C1} = erlog_int:prove_goal({assertz, Fact}, C),
    quod_ct:commit_kb(C1, Version, 1).

db_mod(#est{db = #db{mod = M}}) -> M.
db_ref(#est{db = #db{ref = R}}) -> R.
proc(Est, F) -> (db_mod(Est)):get_procedure(db_ref(Est), F).

%% run a goal on a fresh read-set overlay over `C`, return {Changes, ReadSet}
scope(C, Goal) ->
    W0 = quod_erlog_db_local_prove:wrap_state(C, #{read_set => true}),
    {succeed, W1} = erlog_int:prove_goal(Goal, W0),
    Ov = db_ref(W1),
    Changes = quod_erlog_db_local_prove:get_local_changes(Ov),
    ReadSet = quod_erlog_db_local_prove:get_read_set(Ov),
    quod_erlog_db_local_prove:cleanup_read_set(W1),
    {Changes, ReadSet}.

%%%===================================================================
%%% overlay → diff → apply round-trip (the quod_prolog flow)
%%%===================================================================

overlay_apply_roundtrip_test() ->
    C = committed([{parent, tom, bob}]),
    %% parent(tom, X), assertz(child(X)) — reads parent/2, binds X=bob, stages child(bob)
    {Changes, ReadSet} = scope(C, {',', {parent, tom, {'X'}}, {assertz, {child, {'X'}}}}),
    %% write-set is exactly the staged assert; X resolved to bob
    ?assertMatch([{assert, {{child, bob}, _Body}}], Changes),
    %% read-set records both the predicate and the agreed link-following policy,
    %% with an exact mutation-version token for each dependency.
    ?assertEqual([{no_follow, 1}, {parent, 2}], maps:keys(ReadSet)),
    ?assertEqual({present, 1}, maps:get({parent, 2}, ReadSet)),
    ?assertEqual(never_present, maps:get({no_follow, 1}, ReadSet)),
    %% the committed db was NOT touched — child(bob) is only staged
    ?assertEqual(undefined, proc(C, {child, 1})),
    %% applying the diff to a fresh db makes child(bob) provable
    C2 = committed([]),
    {ok, C3} = quod_diff:apply_ops(C2, Changes),
    ?assertMatch({succeed, _}, erlog_int:prove_goal({child, bob}, C3)),
    %% content dedup: re-applying the same diff does not duplicate the clause
    {ok, C4} = quod_diff:apply_ops(C3, Changes),
    {clauses, Cs} = proc(C4, {child, 1}),
    ?assertEqual(1, length(Cs)),
    %% retract-by-content (same clause form) removes it
    [{assert, Clause}] = Changes,
    {ok, C5} = quod_diff:apply_ops(C3, [{retract, Clause}]),
    ?assertMatch({fail, _}, erlog_int:prove_goal({child, bob}, C5)).

%%%===================================================================
%%% OCC: a read-set validates while unchanged, conflicts once mutated
%%%===================================================================

validate_conflict_test() ->
    C = committed([{parent, tom, bob}]),
    {_Changes, ReadSet} = scope(C, {parent, tom, {'X'}}),
    %% nothing changed under us → valid
    ?assertEqual(ok, quod_diff:validate(ReadSet, db_ref(C))),
    %% commit a parent/2 mutation at height 2 → the read is stale at the head
    C2 = mutated(C, {parent, tom, sue}, 2),
    ?assertEqual({conflict, {parent, 2}}, quod_diff:validate(ReadSet, db_ref(C2))),
    %% the reader's own pinned snapshot is deliberately unchanged
    ?assertEqual(ok, quod_diff:validate(ReadSet, db_ref(C))).

%% Any mutation that leaves no clauses to serve tokens {absent, Slot} — an
%% abolish tombstone or a retraction that emptied the predicate — so
%% absent → present → absent still conflicts with a read taken while the
%% predicate was first absent.
absent_present_absent_conflicts_test() ->
    C = committed([]),
    %% a read of the never-written predicate captures the never_present token
    ?assertEqual(never_present,
                 quod_erlog_db_mvcc:version_token(db_ref(C), {ghost, 1})),
    ReadSet = #{{ghost, 1} => never_present},
    ?assertEqual(ok, quod_diff:validate(ReadSet, db_ref(C))),
    C2 = mutated(C, {ghost, boo}, 2),
    ?assertEqual({conflict, {ghost, 1}}, quod_diff:validate(ReadSet, db_ref(C2))),
    {ok, Ref3} = quod_erlog_db_mvcc:abolish_clauses(db_ref(C2), {ghost, 1}),
    C3 = quod_ct:commit_kb(quod_ct:set_ref(C2, Ref3), 3, 1),
    %% the predicate is absent again, but its tombstone names height 3
    ?assertEqual({absent, 3},
                 quod_erlog_db_mvcc:version_token(db_ref(C3), {ghost, 1})),
    ?assertEqual({conflict, {ghost, 1}}, quod_diff:validate(ReadSet, db_ref(C3))).

%% Production absence: op() has no abolish, so a retract that empties the
%% predicate is what the apply path actually commits — it must token absent.
retract_to_empty_tokens_absent_test() ->
    [{assert, Clause}] = quod_ct:diff_for({ghost, boo}),
    C = committed([{ghost, boo}]),
    ?assertEqual({present, 1},
                 quod_erlog_db_mvcc:version_token(db_ref(C), {ghost, 1})),
    {ok, C1} = quod_diff:apply_ops(C, [{retract, Clause}]),
    C2 = quod_ct:commit_kb(C1, 2, 1),
    ?assertEqual({absent, 2},
                 quod_erlog_db_mvcc:version_token(db_ref(C2), {ghost, 1})),
    ?assertEqual({conflict, {ghost, 1}},
                 quod_diff:validate(#{{ghost, 1} => {present, 1}}, db_ref(C2))).

%% `staged` is never a capturable token: a recorded staged expectation must
%% conflict, never match a same-block staged write as fresh.
staged_expectation_never_validates_test() ->
    C = committed([]),
    ?assertEqual({conflict, {k, 1}},
                 quod_diff:validate(#{{k, 1} => staged}, db_ref(C))),
    {succeed, C1} = erlog_int:prove_goal({assertz, {k, v}}, C),
    ?assertEqual(staged, quod_erlog_db_mvcc:version_token(db_ref(C1), {k, 1})),
    ?assertEqual({conflict, {k, 1}},
                 quod_diff:validate(#{{k, 1} => staged}, db_ref(C1))).

%% Read-set capture is MVCC-only and only ever over published snapshots — both
%% refused at wrap time with a named reason, so the uncapturable `staged`
%% sentinel can never enter a read set (handles are immutable values).
capture_guards_test() ->
    {ok, Dict} = erlog_int:new(erlog_db_dict, null),
    ?assertError({read_set_requires_mvcc, erlog_db_dict},
                 quod_erlog_db_local_prove:wrap_state(
                   Dict, #{read_set => true})),
    C = committed([]),
    {succeed, Pending} = erlog_int:prove_goal({assertz, {k, v}}, C),
    ?assertError(read_set_over_unpublished_snapshot,
                 quod_erlog_db_local_prove:wrap_state(
                   Pending, #{read_set => true})),
    %% without capture, wrapping the mid-apply handle stays legal (apply path)
    _ = quod_erlog_db_local_prove:wrap_state(Pending),
    ok.

generation_guard_blocks_every_overlay_surface_test() ->
    with_proof_gate(
      fun(Tab, AccessGuard) ->
          C = committed([{parent, tom, bob}]),
          W = quod_erlog_db_local_prove:wrap_state(
                C, #{read_set => true, access_guard => AccessGuard}),
          Ov = db_ref(W),
          ?assertMatch({clauses, _},
                       quod_erlog_db_local_prove:get_procedure(
                         Ov, {parent, 2})),
          GroupId = <<91:256>>,
          true = ets:insert(
                   Tab, {proof_gate, true, {pending, GroupId}, 7, GroupId}),
          Expected = {quod_ask_error, {transaction_pending, GroupId}},
          ?assertThrow(
             Expected,
             quod_erlog_db_local_prove:get_procedure(Ov, {parent, 2})),
          ?assertThrow(
             Expected,
             quod_erlog_db_local_prove:assertz_clause(
               Ov, {child, 1}, {child, bob}, true)),
          ?assertThrow(
             Expected,
             quod_erlog_db_local_prove:get_local_changes(Ov)),
          ?assertThrow(
             Expected,
             quod_erlog_db_local_prove:record_live_bridge(
               W, {directory_host, 5})),
          ?assertThrow(
             Expected,
             quod_erlog_db_local_prove:absorb_read_set(W, #{})),
          lists:foreach(
            fun(Operation) -> ?assertThrow(Expected, Operation()) end,
            [fun() ->
                 quod_erlog_db_local_prove:get_procedure_type(
                   Ov, {parent, 2})
             end,
             fun() ->
                 quod_erlog_db_local_prove:get_interpreted_functors(Ov)
             end,
             fun() ->
                 quod_erlog_db_local_prove:asserta_clause(
                   Ov, {child, 1}, {child, bob}, true)
             end,
             fun() ->
                 quod_erlog_db_local_prove:retract_clause(
                   Ov, {parent, 2}, 1)
             end,
             fun() ->
                 quod_erlog_db_local_prove:abolish_clauses(
                   Ov, {parent, 2})
             end,
             fun() -> quod_erlog_db_local_prove:get_read_set(Ov) end,
             fun() -> quod_erlog_db_local_prove:get_dependencies(Ov) end,
             fun() -> quod_erlog_db_local_prove:get_live_bridges(Ov) end]),
          quod_erlog_db_local_prove:cleanup_read_set(W)
      end).

guard_is_preserved_by_overlay_revisions_test() ->
    with_proof_gate(
      fun(Tab, AccessGuard) ->
          W0 = quod_erlog_db_local_prove:wrap_state(
                 committed([]), #{access_guard => AccessGuard}),
          Revision = quod_erlog_db_local_prove:revision(W0),
          {succeed, W1} = erlog_int:prove_goal(
                            {assertz, {staged, value}}, W0),
          W2 = quod_erlog_db_local_prove:replace_revision(W1, Revision),
          ?assertEqual(AccessGuard,
                       quod_erlog_db_local_prove:access_guard(W2)),
          GroupId = <<92:256>>,
          true = ets:insert(
                   Tab, {proof_gate, true, {pending, GroupId}, 7, GroupId}),
          ?assertEqual(
             {error, {transaction_pending, GroupId}},
             quod_erlog_db_local_prove:check_access(W2))
      end).

%% A local write must not hide the committed predicate dependency of a later read.
%% This is the concurrency-sensitive case: another transaction can change parent/2
%% between proof and apply even though this overlay has also staged a parent/2 write.
read_after_local_write_is_tracked_test() ->
    C = committed([{parent, tom, bob}]),
    W0 = quod_erlog_db_local_prove:wrap_state(C, #{read_set => true}),
    Ov0 = db_ref(W0),
    {ok, Ov1} = quod_erlog_db_local_prove:assertz_clause(
                  Ov0, {parent, 2}, {parent, tom, sue}, true),
    ?assertMatch({clauses, _}, quod_erlog_db_local_prove:get_procedure(Ov1, {parent, 2})),
    ?assertEqual([{no_follow, 1}, {parent, 2}],
                 maps:keys(quod_erlog_db_local_prove:get_read_set(Ov1))),
    quod_erlog_db_local_prove:cleanup_read_set(W0).

%% Abolishing changes the local view to empty, but observing that empty view still
%% depends on the committed predicate that was hidden by the abolish.
read_after_local_abolish_is_tracked_test() ->
    C = committed([{parent, tom, bob}]),
    W0 = quod_erlog_db_local_prove:wrap_state(C, #{read_set => true}),
    Ov0 = db_ref(W0),
    {ok, Ov1} = quod_erlog_db_local_prove:abolish_clauses(Ov0, {parent, 2}),
    ?assertMatch({clauses, _}, quod_erlog_db_local_prove:get_procedure(Ov1, {parent, 2})),
    ?assertEqual([{no_follow, 1}, {parent, 2}],
                 maps:keys(quod_erlog_db_local_prove:get_read_set(Ov1))),
    quod_erlog_db_local_prove:cleanup_read_set(W0).

%% abolish/1 enumerates the committed clauses while extracting its retract
%% operations, so the write itself depends on that committed generation. A
%% concurrent assert must conflict even when the goal does not query the
%% abolished predicate afterwards.
write_only_abolish_conflicts_with_concurrent_change_test() ->
    C = committed([{parent, tom, bob}]),
    W0 = quod_erlog_db_local_prove:wrap_state(C, #{read_set => true}),
    Ov0 = db_ref(W0),
    {ok, Ov1} =
        quod_erlog_db_local_prove:abolish_clauses(
          Ov0, {parent, 2}),
    ReadSet =
        quod_erlog_db_local_prove:get_read_set(Ov1),
    ?assertEqual([{parent, 2}], maps:keys(ReadSet)),
    C2 = mutated(C, {parent, tom, sue}, 2),
    ?assertEqual(
       {conflict, {parent, 2}},
       quod_diff:validate(ReadSet, db_ref(C2))),
    quod_erlog_db_local_prove:cleanup_read_set(W0).

%%%===================================================================
%%% a pure read stages nothing (empty write-set)
%%%===================================================================

pure_read_no_writes_test() ->
    C = committed([{parent, tom, bob}]),
    {Changes, _ReadSet} = scope(C, {parent, tom, {'X'}}),
    ?assertEqual([], Changes).

%%%===================================================================
%%% private lifecycle authority + isolated committed view
%%%===================================================================

lifecycle_principal_is_private_overlay_state_test() ->
    C0 = committed([]),
    C = quod_predicates:set_context(
          C0, quod_predicates:effect_context(<<"quod:root">>, 7)),
    Principal = {node, <<42:256>>},
    W = quod_erlog_db_local_prove:wrap_state(
          C, #{lifecycle_principal => Principal}),
    ?assertEqual({ok, Principal},
                 quod_erlog_db_local_prove:lifecycle_principal(W)),
    ?assertEqual(undefined,
                 quod_erlog_db_local_prove:lifecycle_principal(C)),
    %% Carrying authority does not alter the Prolog-visible flag store.
    ?assertEqual(C#est.fs, W#est.fs).

committed_state_drops_staged_data_and_resets_proof_frame_test() ->
    C0 = committed([{parent, tom, bob}]),
    %% The first solution leaves a live choicepoint which would turn a later
    %% failing goal into success if committed_state/1 inherited it.
    {succeed, C1} = erlog_int:prove_goal({';', true, true}, C0),
    ?assertMatch([_ | _], C1#est.cps),
    W0 = quod_erlog_db_local_prove:wrap_state(C1),
    {succeed, W1} = erlog_int:prove_goal({assertz, {child, bob}}, W0),
    Committed = quod_erlog_db_local_prove:committed_state(W1),
    ?assertEqual([], Committed#est.cps),
    ?assertEqual(undefined, proc(Committed, {child, 1})),
    ?assertMatch({clauses, _}, proc(Committed, {parent, 2})),
    ?assertMatch({fail, _}, erlog_int:prove_goal(fail, Committed)).

%%%===================================================================
%%% O(1) write savepoints
%%%===================================================================

checkpoint_restores_all_write_kinds_but_not_reads_test() ->
    C = committed([{parent, tom, bob}, {obsolete, value}]),
    W0 = quod_erlog_db_local_prove:wrap_state(C, #{read_set => true}),
    {succeed, W1} = erlog_int:prove_goal({assertz, {kept, baseline}}, W0),
    Savepoint = quod_erlog_db_local_prove:checkpoint(W1),
    Goal = {',', {asserta, {temporary, first}},
            {',', {assertz, {temporary, last}},
             {',', {retract, {parent, tom, bob}},
                    {abolish, {'/', obsolete, 1}}}}},
    {succeed, W2} = erlog_int:prove_goal(Goal, W1),
    ?assert(length(quod_erlog_db_local_prove:get_local_changes(db_ref(W2))) > 1),
    W3 = quod_erlog_db_local_prove:restore(W2, Savepoint),
    ?assertMatch([{assert, {{kept, baseline}, _}}],
                 quod_erlog_db_local_prove:get_local_changes(db_ref(W3))),
    %% Reads made after the savepoint remain OCC dependencies even though the
    %% corresponding staged writes have been discarded.
    ?assertEqual([{no_follow, 1}, {obsolete, 1}, {parent, 2}],
                 maps:keys(quod_erlog_db_local_prove:get_read_set(db_ref(W3)))),
    quod_erlog_db_local_prove:cleanup_read_set(W3).

checkpoint_is_bound_to_one_overlay_test() ->
    C = committed([]),
    %% No read-set table is needed for identity: distinct wrapped proof scopes
    %% still reject each other's savepoints.
    W1 = quod_erlog_db_local_prove:wrap_state(C),
    W2 = quod_erlog_db_local_prove:wrap_state(C),
    Savepoint = quod_erlog_db_local_prove:checkpoint(W1),
    ?assertError(badarg, quod_erlog_db_local_prove:restore(W2, Savepoint)).

%%%===================================================================
%%% strict read-only policy overlays
%%%===================================================================

read_only_rejects_every_mutation_at_first_attempt_test() ->
    C = committed([{parent, tom, bob}]),
    Goals = [{assert, {child, bob}},
             {asserta, {child, bob}},
             {assertz, {child, bob}},
             {retract, {parent, tom, bob}},
             {abolish, {'/', parent, 2}},
             %% This would have an empty eventual diff on an ordinary overlay;
             %% the first assert must fail before retract can run.
             {',', {assertz, {temporary, value}},
                    {retract, {temporary, value}}}],
    lists:foreach(fun(Goal) -> assert_read_only_rejects(C, Goal) end, Goals).

read_only_bypasses_mutation_hooks_but_ordinary_overlay_keeps_them_test() ->
    C0 = committed([]),
    #est{db = Db0} = C0,
    Hooks = #{{child, 1} => {hook_must_not_run, mutation}},
    C = C0#est{db = Db0#db{assert_hooks = Hooks,
                            retract_hooks = Hooks}},
    Ordinary = quod_erlog_db_local_prove:wrap_state(C),
    ?assertEqual(Hooks, (Ordinary#est.db)#db.assert_hooks),
    ?assertEqual(Hooks, (Ordinary#est.db)#db.retract_hooks),
    ReadOnly = quod_erlog_db_local_prove:wrap_state(C, #{read_only => true}),
    ?assertEqual(#{}, (ReadOnly#est.db)#db.assert_hooks),
    ?assertEqual(#{}, (ReadOnly#est.db)#db.retract_hooks),
    Result = catch erlog_int:prove_goal({assertz, {child, bob}}, ReadOnly),
    ?assertMatch(
       {erlog_error,
        {permission_error, modify, static_procedure, {'/', child, 1}}},
       Result).

read_only_does_not_control_follower_policy_test() ->
    C = committed([]),
    Proof = quod_predicates:set_context(
              C, quod_predicates:proof_context(<<"test:proof">>, 0, undefined)),
    ProofW = quod_erlog_db_local_prove:wrap_state(Proof, #{read_only => true}),
    ?assertMatch(
       {clauses, [_ | _]},
       quod_erlog_db_local_prove:get_procedure(db_ref(ProofW), {foreign, 1})),
    Verdict = quod_predicates:set_context(
                C, quod_predicates:verdict_context(<<"test:verdict">>, 0)),
    VerdictW = quod_erlog_db_local_prove:wrap_state(
                 Verdict, #{read_only => true}),
    ?assertEqual(
       undefined,
       quod_erlog_db_local_prove:get_procedure(db_ref(VerdictW), {foreign, 1})).

read_only_frame_uses_same_staged_view_and_restores_writes_test() ->
    C = committed([]),
    W0 = quod_erlog_db_local_prove:wrap_state(C, #{read_set => true}),
    {succeed, W1} = erlog_int:prove_goal({assertz, {staged, value}}, W0),
    {Frame, ReadOnly} = quod_erlog_db_local_prove:enter_read_only(W1),
    ?assertMatch({succeed, _}, erlog_int:prove_goal({staged, value}, ReadOnly)),
    ?assertMatch(
       {erlog_error,
        {permission_error, modify, static_procedure, {'/', blocked, 1}}},
       catch erlog_int:prove_goal({assertz, {blocked, value}}, ReadOnly)),
    Writable = quod_erlog_db_local_prove:leave_read_only(ReadOnly, Frame),
    {succeed, W2} = erlog_int:prove_goal({assertz, {allowed, value}}, Writable),
    Changes = quod_erlog_db_local_prove:get_local_changes(db_ref(W2)),
    ?assertEqual(2, length(Changes)),
    ?assert(lists:any(fun({assert, {{staged, value}, _}}) -> true;
                         (_) -> false
                      end, Changes)),
    ?assert(lists:any(fun({assert, {{allowed, value}, _}}) -> true;
                         (_) -> false
                      end, Changes)),
    quod_erlog_db_local_prove:cleanup_read_set(W2).

read_only_frames_are_nestable_test() ->
    C = committed([]),
    W0 = quod_erlog_db_local_prove:wrap_state(C),
    {Outer, W1} = quod_erlog_db_local_prove:enter_read_only(W0),
    {Inner, W2} = quod_erlog_db_local_prove:enter_read_only(W1),
    W3 = quod_erlog_db_local_prove:leave_read_only(W2, Inner),
    ?assertMatch(
       {erlog_error, {permission_error, modify, static_procedure, _}},
       catch erlog_int:prove_goal({assertz, {still, blocked}}, W3)),
    W4 = quod_erlog_db_local_prove:leave_read_only(W3, Outer),
    ?assertMatch({succeed, _},
                 erlog_int:prove_goal({assertz, {now, writable}}, W4)).

assert_read_only_rejects(C, Goal) ->
    W = quod_erlog_db_local_prove:wrap_state(C, #{read_only => true}),
    Result = catch erlog_int:prove_goal(Goal, W),
    ?assertMatch(
       {erlog_error,
        {permission_error, modify, static_procedure, _}},
       Result),
    ?assertEqual(
       [],
       quod_erlog_db_local_prove:get_local_changes(db_ref(W))).

with_proof_gate(Fun) ->
    Namespace = <<"quod:overlay-guard-test">>,
    Table = 'quod_simplex_genesis_quod:overlay-guard-test',
    Tab = ets:new(Table, [named_table, protected, set]),
    true = ets:insert(Tab, {proof_gate, true, open, 7, none}),
    try Fun(Tab, {quod_proof_access, Namespace, 7})
    after
        ets:delete(Tab)
    end.
