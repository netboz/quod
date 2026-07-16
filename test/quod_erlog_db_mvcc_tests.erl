-module(quod_erlog_db_mvcc_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

shared_frozen_snapshots_test() ->
    {ok, Erl} = erlog:new(quod_erlog_db_mvcc, null),
    Base = element(3, Erl),
    {succeed, Pending1} = erlog_int:prove_goal({assertz, {value, one}}, Base),
    Version1 = publish(Pending1, 1, 1),
    {succeed, Pending2} = erlog_int:prove_goal({assertz, {value, two}}, Version1),
    Version2 = publish(Pending2, 2, 1),
    ?assertMatch({fail, _}, erlog_int:prove_goal({value, two}, Version1)),
    ?assertMatch({succeed, _}, erlog_int:prove_goal({value, two}, Version2)),
    Ref1 = db_ref(Version1),
    Parent = self(),
    Pid = spawn(fun() -> Parent ! {table, quod_erlog_db_mvcc:table(Ref1)} end),
    receive {table, Table} -> ?assertEqual(quod_erlog_db_mvcc:table(Ref1), Table) end,
    Ref = monitor(process, Pid),
    receive {'DOWN', Ref, process, Pid, _} -> ok after 1000 -> ?assert(false) end,
    {succeed, Pending3} = erlog_int:prove_goal({assertz, {value, three}}, Version2),
    Version3 = publish(Pending3, 3, 3),
    Table3 = quod_erlog_db_mvcc:table(db_ref(Version3)),
    VersionKeys = ets:select(Table3,
                             [{{{version, {value, 1}, '$1'}, '_'}, [], ['$1']}]),
    ?assertEqual([3], VersionKeys),
    quod_erlog_db_mvcc:delete(db_ref(Version3)).

committed_state_size_does_not_scale_with_kb_test() ->
    {ok, Erl} = erlog:new(quod_erlog_db_mvcc, null),
    Base = element(3, Erl),
    Pending = lists:foldl(
                fun(N, Est) ->
                    {succeed, Est1} = erlog_int:prove_goal({assertz, {item, N}}, Est),
                    Est1
                end, Base, lists:seq(1, 1000)),
    Committed = publish(Pending, 1, 1),
    %% The clauses live in ETS; the state copied into a worker remains a small shell.
    ?assert(erts_debug:flat_size(Committed) < 500),
    quod_erlog_db_mvcc:delete(db_ref(Committed)).

released_history_is_pruned_by_unrelated_commit_test() ->
    {ok, Erl} = erlog:new(quod_erlog_db_mvcc, null),
    Base = element(3, Erl),
    {succeed, Pending1} = erlog_int:prove_goal({assertz, {value, old}}, Base),
    Version1 = publish(Pending1, 1, 1),
    {succeed, Pending2} = erlog_int:prove_goal({assertz, {value, current}}, Version1),
    Version2 = publish(Pending2, 2, 1),
    Table = quod_erlog_db_mvcc:table(db_ref(Version2)),
    ?assertEqual([1, 2], versions(Table, {value, 1})),
    {succeed, Pending3} = erlog_int:prove_goal({assertz, {unrelated, fact}}, Version2),
    Version3 = publish(Pending3, 3, 3),
    ?assertEqual([2], versions(Table, {value, 1})),
    quod_erlog_db_mvcc:delete(db_ref(Version3)).

publish(#est{db = #db{ref = Ref0} = Db} = Est, Version, Floor) ->
    Ref1 = quod_erlog_db_mvcc:commit(Ref0, Version, Floor),
    Est#est{db = Db#db{ref = Ref1}}.

db_ref(#est{db = #db{ref = Ref}}) -> Ref.

versions(Table, Functor) ->
    lists:sort(ets:select(Table,
                          [{{{version, Functor, '$1'}, '_'}, [], ['$1']}])).
