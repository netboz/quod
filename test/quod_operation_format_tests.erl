-module(quod_operation_format_tests).
-include_lib("eunit/include/eunit.hrl").

real_v5_and_qsj3_are_named_and_unchanged_test() ->
    lists:foreach(fun({Ns, Encoded, LogHash, JournalHash}) ->
        Dir = temporary_dir(),
        try
            Source = filename:join(["test", "fixtures", "l2-s7-v5", Encoded]),
            Target = quod_ledger_store:ns_dir(Dir, Ns),
            ok = filelib:ensure_dir(filename:join(Target, "log.0001")),
            Log = pinned_file(filename:join(Source, "log.0001"), LogHash),
            Journal = pinned_file(filename:join(Source, "signing.0001"), JournalHash),
            LogPath = filename:join(Target, "log.0001"),
            JournalPath = filename:join(Target, "signing.0001"),
            ok = file:write_file(LogPath, Log, [exclusive]),
            ok = file:write_file(JournalPath, Journal, [exclusive]),
            lists:foreach(fun(Mode) ->
                ?assertEqual({error, {scan_failed, error, {unsupported_ledger_format, 5, 0}}},
                             quod_ledger_store:open_ro(Ns, Dir, Mode)),
                ?assertError({unsupported_ledger_format, 5, 0},
                             quod_ledger_store:open(Ns, Dir, Mode))
            end, [materialized, wrapped]),
            %% The superseded frame is rejected before its domain/body is
            %% interpreted. The old-side probe uses the real founding domain.
            ?assertError({unsupported_signing_journal_format, 3, 0},
                         quod_signing_journal:recover(Ns, <<0:256>>, Dir)),
            ?assertEqual({ok, Log}, file:read_file(LogPath)),
            ?assertEqual({ok, Journal}, file:read_file(JournalPath))
        after
            _ = file:del_dir_r(Dir)
        end
    end, fixtures()).

new_empty_stores_use_only_v6_and_qsj4_test() ->
    Dir = temporary_dir(), Ns = <<"quod:s7-empty-store">>,
    try
        {ok, Store} = quod_ledger_store:open(Ns, Dir),
        ?assertEqual(0, quod_ledger_store:last(Store)),
        ok = quod_ledger_store:close(Store),
        {ok, Journal} = quod_signing_journal:initialize(Ns, <<1:256>>, Dir),
        ok = quod_signing_journal:close(Journal),
        {ok, Bytes} = file:read_file(filename:join(quod_ledger_store:ns_dir(Dir, Ns), "signing.0001")),
        ?assertMatch(<<16#51534A34:32, _/binary>>, Bytes),
        {ok, Recovered} = quod_signing_journal:recover(Ns, <<1:256>>, Dir),
        ok = quod_signing_journal:close(Recovered)
    after _ = file:del_dir_r(Dir)
    end.

real_qej1_with_signed_submission_is_refused_by_name_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Dir = temporary_dir(),
    Bytes = pinned_file("test/fixtures/l2-s7-v5/direct_effects.qej",
      <<"d92e280f627d7cfcdde1b6210f3d007dcb562050ca73cb0b63307617c08b1018">>),
    Path = filename:join(Dir, "direct_effects.qej"),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Bytes, [exclusive]),
    Parent = self(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        process_flag(trap_exit, true),
        Parent ! {self(), quod_effect_journal:start_link(#{data_dir => Dir})}
    end),
    try
        receive
            {Pid, {error, {{unsupported_effect_journal_format, 1}, _Stack}}} -> ok;
            {Pid, Other} -> error({wrong_effect_format_refusal, Other})
        after 2000 -> error(effect_refusal_missing)
        end,
        receive {'DOWN', Monitor, process, Pid, normal} -> ok
        after 2000 -> error(effect_refusal_owner_not_stopped)
        end,
        ?assertEqual({ok, Bytes}, file:read_file(Path))
    after _ = file:del_dir_r(Dir)
    end.

pinned_file(Path, Hex) ->
    {ok, Bytes} = file:read_file(Path),
    ?assertEqual(binary:decode_hex(Hex), crypto:hash(sha256, Bytes)),
    Bytes.

temporary_dir() -> filename:join("/tmp", "quod_s7_format_" ++
    binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))).

fixtures() -> [
    {<<"chain_b">>, "Y2hhaW5fYg",
     <<"efb9d63f4c0b8e4d9fa23c69cd5d03572d1407454846401f32ca7c0847f67131">>,
     <<"5e411d1c25ac5f5ca98dc0053e38224c6bee2a1702466416bec8a763a773b141">>},
    {<<"chain_c">>, "Y2hhaW5fYw",
     <<"dbb2af33ae6ee2d2422036061ec22d0d65a63c0e4bac401a6c0a7128f62fb512">>,
     <<"4f3a63efbde77c3be01034c6f645258865e999bebdaaa72cb7d8f1c8ea601fc5">>}].
