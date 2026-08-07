-module(quod_erlog_db_mvcc_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-import(quod_ct, [commit_kb/3, set_ref/2]).

shared_frozen_snapshots_test() ->
    {ok, Erl} = erlog:new(quod_erlog_db_mvcc, null),
    Base = element(3, Erl),
    {succeed, Pending1} = erlog_int:prove_goal({assertz, {value, one}}, Base),
    Version1 = commit_kb(Pending1, 1, 1),
    {succeed, Pending2} = erlog_int:prove_goal({assertz, {value, two}}, Version1),
    Version2 = commit_kb(Pending2, 2, 1),
    ?assertMatch({fail, _}, erlog_int:prove_goal({value, two}, Version1)),
    ?assertMatch({succeed, _}, erlog_int:prove_goal({value, two}, Version2)),
    Ref1 = db_ref(Version1),
    Parent = self(),
    Pid = spawn(fun() -> Parent ! {table, quod_erlog_db_mvcc:table(Ref1)} end),
    receive {table, Table} -> ?assertEqual(quod_erlog_db_mvcc:table(Ref1), Table) end,
    Ref = monitor(process, Pid),
    receive {'DOWN', Ref, process, Pid, _} -> ok after 1000 -> ?assert(false) end,
    {succeed, Pending3} = erlog_int:prove_goal({assertz, {value, three}}, Version2),
    Version3 = commit_kb(Pending3, 3, 3),
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
    Committed = commit_kb(Pending, 1, 1),
    %% The clauses live in ETS; the state copied into a worker remains a small shell.
    ?assert(erts_debug:flat_size(Committed) < 500),
    quod_erlog_db_mvcc:delete(db_ref(Committed)).

released_history_is_pruned_by_unrelated_commit_test() ->
    {ok, Erl} = erlog:new(quod_erlog_db_mvcc, null),
    Base = element(3, Erl),
    {succeed, Pending1} = erlog_int:prove_goal({assertz, {value, old}}, Base),
    Version1 = commit_kb(Pending1, 1, 1),
    {succeed, Pending2} = erlog_int:prove_goal({assertz, {value, current}}, Version1),
    Version2 = commit_kb(Pending2, 2, 1),
    Table = quod_erlog_db_mvcc:table(db_ref(Version2)),
    ?assertEqual([1, 2], versions(Table, {value, 1})),
    ?assertEqual(1, quod_erlog_db_mvcc:history_predicates(db_ref(Version2))),
    {succeed, Pending3} = erlog_int:prove_goal({assertz, {unrelated, fact}}, Version2),
    Version3 = commit_kb(Pending3, 3, 3),
    ?assertEqual([2], versions(Table, {value, 1})),
    ?assertEqual(0, quod_erlog_db_mvcc:history_predicates(db_ref(Version3))),
    quod_erlog_db_mvcc:delete(db_ref(Version3)).

%% The OCC token names the last committed mutation at the handle's snapshot;
%% a staged pending write reports `staged` (matching no capturable token, so a
%% same-block read-after-write fails validation), tombstones survive, statics
%% are tagged.
version_token_test() ->
    {ok, Erl} = erlog:new(quod_erlog_db_mvcc, null),
    Base = element(3, Erl),
    ?assertEqual(never_present, tok(Base, {value, 1})),
    {succeed, Pending1} = erlog_int:prove_goal({assertz, {value, one}}, Base),
    %% a staged write is not committed history: it can never validate as fresh
    ?assertEqual(staged, tok(Pending1, {value, 1})),
    ?assertEqual(never_present, tok(Pending1, {other, 1})),
    V1 = commit_kb(Pending1, 1, 1),
    ?assertEqual({present, 1}, tok(V1, {value, 1})),
    {succeed, Pending2} = erlog_int:prove_goal({assertz, {value, two}}, V1),
    V2 = commit_kb(Pending2, 2, 1),
    ?assertEqual({present, 2}, tok(V2, {value, 1})),
    %% an older pinned snapshot keeps its own stable token
    ?assertEqual({present, 1}, tok(V1, {value, 1})),
    %% abolish leaves an {absent, Height} tombstone, never never_present again
    {ok, Ref3} = quod_erlog_db_mvcc:abolish_clauses(db_ref(V2), {value, 1}),
    V3 = commit_kb(set_ref(V2, Ref3), 3, 1),
    ?assertEqual({absent, 3}, tok(V3, {value, 1})),
    ?assertEqual({present, 2}, tok(V2, {value, 1})),
    %% built-ins have no version history: they are static
    ?assertEqual(static, tok(V3, {true, 0})),
    quod_erlog_db_mvcc:delete(db_ref(V3)).

%% The boot KB publishes as the height-0 base: capture-eligible from the first
%% instant, tokens {present, 0}, publishable exactly once, commits stack above.
publish_base_test() ->
    {ok, Erl} = erlog:new(quod_erlog_db_mvcc, null),
    Base = element(3, Erl),
    {succeed, Loaded} = erlog_int:prove_goal({assertz, {boot, fact}}, Base),
    ?assertNot(quod_erlog_db_mvcc:published(db_ref(Loaded))),
    Published =
        set_ref(Loaded, quod_erlog_db_mvcc:publish_base(db_ref(Loaded))),
    ?assert(quod_erlog_db_mvcc:published(db_ref(Published))),
    ?assertEqual({present, 0}, tok(Published, {boot, 1})),
    ?assertMatch({succeed, _}, erlog_int:prove_goal({boot, fact}, Published)),
    ?assertError({badmatch, _},
                 quod_erlog_db_mvcc:publish_base(db_ref(Published))),
    {succeed, Pending} = erlog_int:prove_goal({assertz, {later, fact}},
                                              Published),
    V1 = commit_kb(Pending, 1, 1),
    ?assertEqual({present, 1}, tok(V1, {later, 1})),
    ?assertEqual({present, 0}, tok(V1, {boot, 1})),
    quod_erlog_db_mvcc:delete(db_ref(V1)).

tok(Est, Functor) -> quod_erlog_db_mvcc:version_token(db_ref(Est), Functor).

db_ref(#est{db = #db{ref = Ref}}) -> Ref.

versions(Table, Functor) ->
    lists:sort(ets:select(Table,
                          [{{{version, Functor, '$1'}, '_'}, [], ['$1']}])).
