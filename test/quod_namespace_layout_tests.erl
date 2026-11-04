-module(quod_namespace_layout_tests).
-include_lib("eunit/include/eunit.hrl").

long_namespace_has_one_exact_representable_key_test() ->
    Ns = binary:copy(<<"n">>, 1024),
    Key = quod_ledger_store:namespace_key(Ns),
    ?assertEqual(<<"ns.", (binary:encode_hex(crypto:hash(sha256, Ns)))/binary>>, Key),
    ?assertNotEqual(Key, quod_ledger_store:namespace_key(<<Ns/binary, "x">>)),
    ?assertEqual(Key, quod_ledger_store:namespace_key(Ns)),
    ?assert(byte_size(quod_simplex:genesis_table_name(Ns)) < 255),
    ?assert(byte_size(atom_to_binary(quod_feed:digest_table(Ns), utf8)) < 255).

old_journal_in_other_root_refuses_before_ledger_creation_test() ->
    temporary(fun(Root) ->
        Ns = <<"preserved:namespace">>,
        Ledger = filename:join(Root, "ledger"), Data = filename:join(Root, "data"),
        Old = legacy(Data, Ns), Marker = filename:join(Old, "signing.journal"),
        ok = filelib:ensure_dir(Marker), ok = file:write_file(Marker, <<"preserved">>),
        Config = #{ledger_dir => Ledger, data_dir => Data},
        Error = {error, {unsupported_namespace_layout, Old}},
        ?assertEqual(Error, quod_ledger_store:preflight_namespace(Ns, Config)),
        ?assertError({badmatch, Error}, quod_simplex:test_restore_storage(Ns, Config, <<1:256>>)),
        ?assertNot(filelib:is_dir(Ledger)),
        ?assertEqual({ok, <<"preserved">>}, file:read_file(Marker)),
        ?assertEqual(Error, quod_outcome:lookup_live(Ns, Data, <<1:256>>)),
        ?assertError({badmatch, Error}, quod_signing_journal:initialize(Ns, <<2:256>>, Data)),
        ?assertError({badmatch, Error}, quod_signing_journal:recover(Ns, <<2:256>>, Data)),
        ?assertError({badmatch, Error}, quod_dtx_phase_index:open(Data, Ns)),
        ?assertError({badmatch, Error}, quod_outcome:open(Ns, <<2:256>>, #{data_dir => Data})),
        ?assertNot(filelib:is_dir(quod_ledger_store:ns_dir(Data, Ns)))
    end).

old_archive_refuses_even_when_new_layout_exists_test() ->
    temporary(fun(Root) ->
        Ns = <<"preserved:archive">>, Old = legacy(Root, Ns),
        ok = filelib:ensure_dir(filename:join(Old, "log.0001")),
        New = quod_ledger_store:ns_dir(Root, Ns),
        ok = filelib:ensure_path(New),
        ?assertError({unsupported_namespace_layout, Old}, quod_ledger_store:open_ro(Ns, Root)),
        ?assertError({unsupported_namespace_layout, Old}, quod_ledger_store:open(Ns, Root)),
        ?assertEqual({ok, []}, file:list_dir(New))
    end).

long_namespace_reopens_same_store_without_alias_test() ->
    temporary(fun(Root) ->
        Ns = binary:copy(<<"x">>, 1024),
        {ok, Store} = quod_ledger_store:open(Ns, Root),
        ?assertEqual(Ns, quod_ledger_store:namespace(Store)),
        ok = quod_ledger_store:close(Store),
        {ok, Reader} = quod_ledger_store:open_ro(Ns, Root),
        ?assertEqual(Ns, quod_ledger_store:namespace(Reader)),
        ok = quod_ledger_store:close(Reader),
        ?assertEqual({error, no_log}, quod_ledger_store:open_ro(<<Ns/binary, "x">>, Root))
    end).

legacy(Root, Ns) -> filename:join(Root, binary_to_list(base64:encode(Ns, #{mode => urlsafe, padding => false}))).
temporary(Fun) ->
    Root = filename:join("/tmp", "quod_namespace_layout_" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16)))) ,
    try Fun(Root) after file:del_dir_r(Root) end.

old_foreign_manifest_refuses_before_projection_cleanup_test() ->
    temporary(fun(Root) ->
        Ns = <<"foreign:preserved">>, Anchor = <<7:256>>, Identity = {Ns, Anchor},
        CacheNs = quod_foreign_log:cache_namespace(Identity),
        Old = legacy(Root, CacheNs),
        %% The original valid manifest version is taken from the production owner.
        Manifest = {quod_foreign_log_cache, 7, Ns, Anchor, CacheNs},
        Path = filename:join(Old, "identity.term"),
        ok = filelib:ensure_dir(Path),
        Blob = term_to_binary(Manifest, [deterministic]), ok = file:write_file(Path, Blob),
        ProjectionMarker = filename:join([Root, "projections", "retained", "marker"]),
        ok = filelib:ensure_dir(ProjectionMarker), ok = file:write_file(ProjectionMarker, <<"preserved">>),
        ?assertError({badmatch, {error, {unsupported_namespace_layout, Old}}},
                     quod_foreign_log:init(#{cache_dir => Root})),
        ?assertEqual({ok, Blob}, file:read_file(Path)),
        ?assertEqual({ok, <<"preserved">>}, file:read_file(ProjectionMarker)),
        ?assertNot(filelib:is_dir(quod_ledger_store:ns_dir(Root, CacheNs)))
    end).
