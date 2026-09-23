-module(quod_file_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

directory_sync_errors_are_not_success_test() ->
    Dir = temporary_directory(),
    try
        ?assertEqual(ok, quod_file:sync_dir(Dir)),
        ?assertEqual({error, enoent}, quod_file:sync_dir(filename:join(Dir, "absent")))
    after file:del_dir_r(Dir) end.

atomic_replacement_preserves_private_mode_test() ->
    Dir = temporary_directory(),
    Path = filename:join(Dir, "custody"),
    try
        ok = quod_file:write_atomic(Path, <<"first">>, 8#600),
        ok = quod_file:write_atomic(Path, <<"second">>, 8#600),
        ?assertEqual({ok, <<"second">>}, file:read_file(Path)),
        {ok, #file_info{mode = Mode}} = file:read_file_info(Path),
        ?assertEqual(8#600, Mode band 8#777),
        ?assertEqual({ok, ["custody"]}, file:list_dir(Dir)),
        ?assertMatch({error, _}, quod_file:write_atomic(filename:join(Path, "invalid"), <<>>, 8#600)),
        ?assertEqual({ok, <<"second">>}, file:read_file(Path))
    after file:del_dir_r(Dir) end.

nested_parent_creation_and_existing_file_conflict_test() ->
    Dir = temporary_directory(),
    Path = filename:join([Dir, "outer", "inner", "key"]),
    try
        ?assertEqual(ok, quod_file:write_atomic(Path, <<"key">>, 8#600)),
        ?assertEqual({ok, <<"key">>}, file:read_file(Path)),
        ?assertEqual(ok, quod_file:ensure_parent(Path)),
        ?assertEqual({error, eexist}, quod_file:ensure_parent(filename:join(Path, "child")))
    after file:del_dir_r(Dir) end.

temporary_directory() ->
    Dir = filename:join("/tmp", "quod-file-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    ok = file:make_dir(Dir),
    Dir.
