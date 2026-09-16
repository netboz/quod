-module(quod_atomic_format_tests).
-include_lib("eunit/include/eunit.hrl").

%% Actual .200 writer output, not invented version headers. The capture used
%% signed local fixtures and a real slot-2 QC, not a complete founded fleet.
%% QSJ4 is exercised by quod_signing_journal_tests with its own pinned fixture.
real_v6_ledger_is_named_and_unchanged_test() ->
    with_dir(fun(Dir) ->
        Ns = namespace(), Bytes = fixture("ledger-v6"),
        Path = filename:join(quod_ledger_store:ns_dir(Dir, Ns), "log.0001"),
        put_file(Path, Bytes),
        lists:foreach(fun(Mode) ->
            ?assertEqual({error, {scan_failed, error, {unsupported_ledger_format, 6, 0}}},
                         quod_ledger_store:open_ro(Ns, Dir, Mode)),
            ?assertError({unsupported_ledger_format, 6, 0},
                         quod_ledger_store:open(Ns, Dir, Mode))
        end, [materialized, wrapped]),
        ?assertEqual({ok, Bytes}, file:read_file(Path))
    end).

real_v14_signed_transaction_is_refused_by_version_test() ->
    {Binding, {ok, Submission}} = binary_to_term(fixture("transaction-v14")),
    ?assert(quod_transaction:verify_submission(Submission)),
    ?assertEqual({error, unsupported_version},
                 quod_transaction:decode_verified_submission(Binding, Submission)).

real_v7_outcome_index_is_named_and_unchanged_test() ->
    with_dir(fun(Dir) ->
        Ns = namespace(), Bytes = fixture("outcome-v7"),
        Path = filename:join(quod_ledger_store:ns_dir(Dir, Ns), "outcomes.dets"),
        put_file(Path, Bytes),
        ?assertEqual({error, {unsupported_format, 7}},
                     quod_outcome:open(Ns, anchor(), #{ledger_dir => Dir})),
        ?assertEqual({ok, Bytes}, file:read_file(Path))
    end).

real_v1_phase_row_is_named_and_unchanged_test() ->
    with_dir(fun(Dir) ->
        Bytes = fixture("phase-history-v1"),
        {ok, {quod_dtx_phase_history, 1, #{group_id := Id}}} =
            quod_safe_term:decode_wrapped(Bytes, byte_size(Bytes)),
        {ok, Index} = quod_dtx_phase_index:open(Dir, namespace()),
        try
            ok = quod_dtx_phase_index:test_insert_raw(Index, Id, Bytes),
            ?assertEqual({error, {unsupported_dtx_phase_history, 1}},
                         quod_dtx_phase_index:history(Index, Id)),
            %% The reader did not translate or delete the stored old row.
            Path = quod_dtx_phase_index:test_path(Index),
            ?assertEqual([{{group, Id}, Bytes}], dets:lookup(Path, {group, Id}))
        after ok = quod_dtx_phase_index:close(Index)
        end
    end).

real_qej2_is_named_and_unchanged_test() ->
    with_dir(fun(Dir) ->
        {ok, _} = application:ensure_all_started(gproc),
        Bytes = fixture("effect-qej2"), Path = filename:join(Dir, "direct_effects.qej"),
        put_file(Path, Bytes),
        ?assertMatch({error, {{unsupported_effect_journal_format, 2}, _}},
                     isolated_start(fun() -> quod_effect_journal:start_link(#{data_dir => Dir}) end)),
        ?assertEqual({ok, Bytes}, file:read_file(Path))
    end).

real_v4_cache_is_named_at_owner_start_and_unchanged_test() ->
    with_dir(fun(Dir) ->
        {ok, _} = application:ensure_all_started(gproc),
        Manifest = fixture("cache-v4"),
        {quod_foreign_log_cache, 4, _, _, CacheNs} = binary_to_term(Manifest),
        CacheDir = quod_ledger_store:ns_dir(Dir, CacheNs),
        Files = [{"identity.term", Manifest}, {"log.0001", fixture("ledger-v6")},
                 {"checkpoint.term", fixture("checkpoint-v4")}],
        [put_file(filename:join(CacheDir, Name), Bytes) || {Name, Bytes} <- Files],
        ?assertMatch({error, {{unsupported_foreign_cache_format, 4}, _}},
                     isolated_start(fun() -> quod_foreign_log:start_link(#{cache_dir => Dir}) end)),
        [?assertEqual({ok, Bytes}, file:read_file(filename:join(CacheDir, Name)))
         || {Name, Bytes} <- Files]
    end).

real_v4_checkpoint_cannot_be_relabelled_corrupt_and_deleted_test() ->
    with_dir(fun(Dir) ->
        Identity = {namespace(), anchor()}, CacheNs = quod_foreign_log:cache_namespace(Identity),
        %% Deliberately mixed store to isolate the checkpoint's own guard: the
        %% manifest and ledger are current, only the actual checkpoint is old.
        {ok, Store} = quod_ledger_store:open(CacheNs, Dir, wrapped),
        ok = quod_ledger_store:close(Store),
        CacheDir = quod_ledger_store:ns_dir(Dir, CacheNs),
        Manifest = term_to_binary({quod_foreign_log_cache, 5, namespace(), anchor(), CacheNs},
                                  [deterministic]),
        put_file(filename:join(CacheDir, "identity.term"), Manifest),
        Bytes = fixture("checkpoint-v4"), Path = filename:join(CacheDir, "checkpoint.term"),
        put_file(Path, Bytes),
        %% Any reset request would be a call to self and fail, not silently
        %% rebuild. The exact unsupported result must survive initialization.
        ?assertEqual({error, {unsupported_foreign_checkpoint_format, 4}},
                     quod_foreign_log:open_verified_cache(self(), make_ref(), Identity,
                                                          Dir, {initialize, startup}, false)),
        ?assertEqual({ok, Bytes}, file:read_file(Path))
    end).

empty_current_indices_reopen_without_legacy_state_test() ->
    with_dir(fun(Dir) ->
        Ns = namespace(),
        {ok, Store} = quod_ledger_store:open(Ns, Dir),
        ?assertEqual(0, quod_ledger_store:last(Store)),
        ok = quod_ledger_store:close(Store),
        {ok, Index} = quod_outcome:open(Ns, anchor(), #{ledger_dir => Dir}),
        ok = quod_outcome:close(Index),
        {ok, Again} = quod_outcome:open(Ns, anchor(), #{ledger_dir => Dir}),
        ok = quod_outcome:close(Again),
        {ok, Phase} = quod_dtx_phase_index:open(Dir, Ns),
        ?assertEqual({ok, quod_atomic:initial_group_history()},
                     quod_dtx_phase_index:history(Phase, <<1:256>>)),
        ok = quod_dtx_phase_index:close(Phase)
    end).

isolated_start(Fun) ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        process_flag(trap_exit, true),
        Result = Fun(),
        case Result of {ok, Owner} -> unlink(Owner), gen_server:stop(Owner); _ -> ok end,
        Parent ! {self(), Result}
    end),
    Result = receive {Pid, R} -> R after 2000 -> error(format_start_timeout) end,
    receive {'DOWN', Ref, process, Pid, normal} -> Result
    after 2000 -> error(format_start_not_closed)
    end.

namespace() -> <<"quod:signed-fixture">>.
anchor() -> <<201:256>>.
put_file(Path, Bytes) ->
    ok = filelib:ensure_dir(Path), file:write_file(Path, Bytes, [exclusive]).
with_dir(Fun) ->
    Dir = filename:join("/tmp", "quod-atomic-format-" ++
                       binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
    try Fun(Dir) after _ = file:del_dir_r(Dir) end.

fixture(Name) ->
    Path = filename:join([filename:dirname(?FILE), "fixtures", "two-phase", Name ++ ".b64"]),
    {ok, Encoded} = file:read_file(Path), Bytes = base64:decode(Encoded),
    ?assertEqual(binary:decode_hex(fixture_hash(Name)), crypto:hash(sha256, Bytes)), Bytes.
fixture_hash("ledger-v6") -> <<"aa257d473bc6ca19ad29686848be0f01df44878c7da3d486ce71a8f699616653">>;
fixture_hash("outcome-v7") -> <<"4d07df0d334f6d3267aecb1e3e83606f9e32331cb319daeb350542d10e1ac3a4">>;
fixture_hash("phase-history-v1") -> <<"866c9defc9ce8d9c78a323229d7e80349dcc8126f2058835445c7c50b087966d">>;
fixture_hash("transaction-v14") -> <<"928a0d4ad6e865825c1c2275847ef6845144e0c38ad205d5ed438c7a0042f578">>;
fixture_hash("effect-qej2") -> <<"d7cc858f8681393fc5322aab329fbf4ea3ffa94816f50b3a44788f3486723c71">>;
fixture_hash("cache-v4") -> <<"ee34c541dc416977661ce10f721aca4aee9c8c46c94c328869bcb6857e461457">>;
fixture_hash("checkpoint-v4") -> <<"54cbd95329f244b1d24f9ce9f9e4f10b07dd3bf0d106c779f011d2bc8d0d99f6">>.
