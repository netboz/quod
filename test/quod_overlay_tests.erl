-module(quod_overlay_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

%%%===================================================================
%%% helpers
%%%===================================================================

tab() -> list_to_atom("qovl_" ++ integer_to_list(erlang:unique_integer([positive]))).

%% a committed erlog db (erlog_db_ets) preloaded with `Facts` (erlog terms)
committed(Facts) ->
    {ok, C0} = erlog_int:new(erlog_db_ets, tab()),
    lists:foldl(fun(Fact, C) ->
                        {succeed, C1} = erlog_int:prove_goal({assertz, Fact}, C),
                        C1
                end, C0, Facts).

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
    %% with a content hash for each dependency.
    ?assertEqual([{no_follow, 1}, {parent, 2}], maps:keys(ReadSet)),
    ?assert(is_integer(maps:get({parent, 2}, ReadSet))),
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
    M = db_mod(C), R = db_ref(C),
    %% nothing changed under us → valid
    ?assertEqual(ok, quod_diff:validate(ReadSet, M, R)),
    %% mutate parent/2 in the committed db → the read is now stale
    {succeed, _} = erlog_int:prove_goal({assertz, {parent, tom, sue}}, C),
    ?assertEqual({conflict, {parent, 2}}, quod_diff:validate(ReadSet, M, R)).

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
    M = db_mod(C),
    R = db_ref(C),
    {succeed, _} =
        erlog_int:prove_goal(
          {assertz, {parent, tom, sue}}, C),
    ?assertEqual(
       {conflict, {parent, 2}},
       quod_diff:validate(ReadSet, M, R)),
    quod_erlog_db_local_prove:cleanup_read_set(W0).

%%%===================================================================
%%% a pure read stages nothing (empty write-set)
%%%===================================================================

pure_read_no_writes_test() ->
    C = committed([{parent, tom, bob}]),
    {Changes, _ReadSet} = scope(C, {parent, tom, {'X'}}),
    ?assertEqual([], Changes).
