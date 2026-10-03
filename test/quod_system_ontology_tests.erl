-module(quod_system_ontology_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").
-export([quod_predicate_module/0, load/1]).

%% Native-loader fixture; copied into the release directory only by its test.
quod_predicate_module() -> get({?MODULE, native_marker}).
load(_Est) -> error(native_test_failure).

catalogue_requires_exact_existing_identity_test() ->
    Anchor = <<1:256>>,
    Row = {system_ontology, {':', quod, agent}, Anchor},
    ?assertMatch(
       {ok, [#{namespace := <<"quod:agent">>, anchor := Anchor}], #{}},
       quod_system_ontology:validate_rows([Row])),
    {ok, [], InvalidAnchor} = quod_system_ontology:validate_rows(
                                [{system_ontology, {':', quod, agent},
                                  not_an_anchor}]),
    assert_one_malformed(InvalidAnchor),
    {ok, [], InvalidRoot} = quod_system_ontology:validate_rows(
                              [{system_ontology, {':', quod, root}, Anchor}]),
    assert_one_malformed(InvalidRoot),
    Overlong = <<"quod:", (binary:copy(<<"x">>, 129))/binary>>,
    {ok, [], InvalidName} = quod_system_ontology:validate_rows(
                              [{system_ontology, Overlong, Anchor}]),
    assert_one_malformed(InvalidName).

catalogue_rejects_extra_fields_and_duplicates_test() ->
    Anchor = <<2:256>>,
    Good = {system_ontology, {':', quod, node}, Anchor},
    {ok, [], InvalidArity} = quod_system_ontology:validate_rows(
                               [{system_ontology, {':', quod, node}, Anchor,
                                 obsolete_field}]),
    assert_one_malformed(InvalidArity),
    %% Prolog permits an identical fact to be asserted twice. It still names
    %% one exact identity and must not poison unrelated catalogue rows.
    ?assertMatch(
       {ok, [#{namespace := <<"quod:node">>, anchor := Anchor}], #{}},
       quod_system_ontology:validate_rows([Good, Good])),
    OtherAnchor = <<3:256>>,
    ?assertMatch(
       {ok, [],
        #{<<"quod:node">> :=
              #{reason := conflicting_system_ontology,
                anchors := [Anchor, OtherAnchor]}}},
       quod_system_ontology:validate_rows(
         [Good, {system_ontology, {':', quod, node}, OtherAnchor}])).

malformed_row_does_not_hide_healthy_identity_test() ->
    Anchor = <<4:256>>,
    Good = {system_ontology, {':', quod, agent}, Anchor},
    {ok, Descriptors, Rejected} =
        quod_system_ontology:validate_rows(
          [{system_ontology, {':', quod, bad}, not_an_anchor}, Good]),
    ?assertEqual(
       [#{namespace => <<"quod:agent">>, anchor => Anchor}], Descriptors),
    assert_one_malformed(Rejected).

catalogue_rebuilding_shapes_share_one_root_not_ready_result_test() ->
    ?assertEqual(
       {error, root_not_ready},
       quod_system_ontology:validate_catalog_proof({error, rebuilding})),
    ?assertEqual(
       {error, root_not_ready},
       quod_system_ontology:validate_catalog_proof(
         {error, {ontology_rebuilding, <<"quod:root">>}})).

matching_materialized_identity_is_reused_without_reopening_ledger_test() ->
    Ns = <<"quod:cached">>,
    Anchor = <<5:256>>,
    %% These paths are deliberately unusable. An exact already-materialized
    %% identity is desired state, not a request to rescan its whole ledger on
    %% every unrelated root catalogue change or retry tick.
    Config = #{system_ontology => true, genesis_hash => Anchor,
               data_dir => <<0>>, ledger_dir => <<0>>},
    ?assertEqual(
       {ok, #{Ns => Config}, [], #{}},
       quod_system_ontology:materialize(
         [#{namespace => Ns, anchor => Anchor}], #{Ns => Config})).

ledger_read_failure_is_a_catalogue_owner_failure_test() ->
    Ns = <<"quod:unreadable-system">>,
    Anchor = <<6:256>>,
    Root = filename:join(
             "/tmp",
             "quod_system_read_" ++
                 binary_to_list(
                   binary:encode_hex(crypto:strong_rand_bytes(8)))),
    Saved = application:get_env(quod, namespace_desired),
    try
        application:set_env(
          quod, namespace_desired,
          #{content => #{<<"quod:root">> =>
                             #{data_dir => Root, ledger_dir => Root}},
            brahms => #{}}),
        Config = quod_ontology:local_resume_config(Ns, Anchor, Root),
        LedgerDir = quod_ledger_store:ledger_dir(Config),
        NsDir = quod_ledger_store:ns_dir(LedgerDir, Ns),
        ok = filelib:ensure_dir(NsDir),
        ok = file:write_file(NsDir, <<"not a ledger directory">>),
        ?assertMatch(
           {error, {ledger_read_failed, _}},
           quod_system_ontology:materialize(
             [#{namespace => Ns, anchor => Anchor}], #{}))
    after
        _ = file:del_dir_r(Root),
        case Saved of
            {ok, Value} -> application:set_env(quod, namespace_desired, Value);
            undefined -> application:unset_env(quod, namespace_desired)
        end
    end.

assert_one_malformed(Rejected) ->
    ?assertEqual(1, map_size(Rejected)),
    ?assertEqual(
       [malformed_system_ontology],
       [Reason || #{reason := Reason} <- maps:values(Rejected)]).

predicate_modules_are_engine_local_test() ->
    Common = quod_committed_projection:new_est(),
    {ok, Manifest} = quod_predicates:module_manifest(
                       [quod_directory_predicates,
                        quod_ontology_predicates]),
    {ok, Root} = quod_predicates:load_manifest(
                   quod_committed_projection:new_est(), Manifest),
    try
        ?assertMatch(
           {query, live_observation, quod_committee_predicates, peer_ready_1},
           quod_predicates:descriptor(Common, {peer_ready, 1})),
        ?assertEqual(
           undefined,
           quod_predicates:descriptor(Common, {directory_host, 5})),
        ?assertMatch(
           {query, live_observation, quod_directory_predicates, directory_host_5},
           quod_predicates:descriptor(Root, {directory_host, 5})),
        ?assertMatch(
           {staging, none, quod_ontology_predicates,
            lifecycle_request_predicate},
           quod_predicates:descriptor(Root, {create_ontology, 3})),
        ?assertEqual(
           undefined,
           quod_predicates:descriptor(Common, {create_ontology, 3}))
    after
        delete_est(Common),
        delete_est(Root)
    end.

predicate_manifest_selects_shipped_release_module_test() ->
    ?assertMatch(
       {error, {invalid_predicate_module, quod_ask}},
       quod_predicates:module_manifest([quod_ask])),
    ?assertMatch(
       {error, {invalid_predicate_module, '../quod_directory_predicates'}},
       quod_predicates:module_manifest(
         ['../quod_directory_predicates'])),
    {ok, [{quod_directory_predicates, Digest}]} =
        quod_predicates:module_manifest([quod_directory_predicates]),
    <<First, Rest/binary>> = Digest,
    Wrong = <<(First bxor 1), Rest/binary>>,
    ?assertEqual(
       {ok, [quod_directory_predicates]},
       quod_predicates:valid_manifest(
         [{quod_directory_predicates, Wrong}])),
    ?assertMatch({error, {predicate_module_unavailable, quod_unshipped_test_module}},
      quod_predicates:valid_manifest([{quod_unshipped_test_module, Wrong}])),
    %% Being loaded on a test code path does not make a module part of Quod's
    %% shipped predicate vocabulary.
    ?assertMatch({error, {predicate_module_unavailable, ?MODULE}},
      quod_predicates:valid_manifest([{?MODULE, Wrong}])),
    ?assertEqual({error, invalid_external_predicate_manifest},
      quod_predicates:valid_manifest([{quod_directory_predicates, <<>>}])),
    ?assertEqual({error, invalid_external_predicate_manifest},
      quod_predicates:valid_manifest([{quod_directory_predicates, Wrong},
                                     {quod_directory_predicates, Wrong}])).

principal_bridge_registration_is_independent_of_module_order_test() ->
    lists:foreach(fun(Modules) ->
        Est0 = quod_committed_projection:new_est(),
        try
            {ok, Manifest} = quod_predicates:module_manifest(Modules),
            {ok, Est} = quod_predicates:load_manifest(Est0, Manifest),
            ?assertEqual({query, proof_bound, quod_ontology_predicates,
                          current_principal_predicate},
                         quod_predicates:descriptor(Est, {current_principal, 1}))
        after delete_est(Est0) end
    end, [[quod_agent_predicates, quod_ontology_predicates],
          [quod_ontology_predicates, quod_agent_predicates]]).

conflicting_predicate_ownership_fails_loud_test() ->
    Est0 = quod_committed_projection:new_est(),
    try
        ?assertError(
           {external_predicate_conflict, {peer_ready, 1}, _, _},
           quod_predicates:register(
             Est0, {peer_ready, 1}, query,
             quod_directory_predicates, directory_control_peer_1))
    after
        delete_est(Est0)
    end.

native_marker_and_load_failure_keep_engine_unavailable_test() ->
    AppBeam = filename:join(filename:dirname(code:which(quod_predicates)),
                            atom_to_list(?MODULE) ++ ".beam"),
    {ok, _} = file:copy(code:which(?MODULE), AppBeam),
    Est = quod_committed_projection:new_est(),
    Manifest = [{?MODULE, <<0:256>>}],
    try
        put({?MODULE, native_marker}, false),
        ?assertEqual({error, {invalid_predicate_module_marker, ?MODULE, false}},
                     quod_predicates:load_manifest(Est, Manifest)),
        put({?MODULE, native_marker}, true),
        ?assertMatch({error, {predicate_module_load_failed, ?MODULE,
                             error, native_test_failure, _}},
                     quod_predicates:load_manifest(Est, Manifest))
    after
        erase({?MODULE, native_marker}),
        delete_est(Est),
        ok = file:delete(AppBeam)
    end.

existing_ledger_restart_loads_current_native_code_test_() ->
    {timeout, 30, fun() ->
        {ok, _} = application:ensure_all_started(gproc),
        {Self, _} = Pair = quod_identity:generate(),
        Identity = #{pubkey => Self, key => quod_identity:key_term(Pair),
                     cert => quod_identity:mint_cert(Pair)},
        Suffix = binary:encode_hex(crypto:strong_rand_bytes(8)),
        Ns = <<"native-release:", Suffix/binary>>,
        Dir = filename:join("/tmp", "quod_native_" ++ binary_to_list(Suffix)),
        Manifest = [{quod_agent_predicates, <<0:256>>}],
        Config0 = #{node_id => Self, identity => Identity, data_dir => Dir,
                    mode => create, external_predicate_modules => [quod_agent_predicates],
                    genesis_diff => quod_prolog:terms_to_diff([{saved, unchanged}])},
        Genesis0 = quod_simplex:test_genesis_tx(Config0, Ns, Self, <<98:256>>),
        Genesis = Genesis0#transaction{diff =
          [case Op of
               {assert, {{external_predicate_modules, _}, Body}} ->
                   {assert, {{external_predicate_modules, Manifest}, Body}};
               _ -> Op
           end || Op <- Genesis0#transaction.diff]},
        {ok, Block} = quod_ledger:new_block({genesis, 0}, none, 1, {batch, [Genesis]}, 0),
        Anchor = quod_simplex:block_hash(Block),
        Config = Config0#{genesis_hash => Anchor,
          prepared_genesis_entry => quod_ledger:entry_view(quod_ledger:entry(1, Block, none))},
        First = start_native_namespace(Ns, Config),
        try assert_native_state(Ns, Anchor, Manifest, Self)
        after stop_native_namespace(First) end,
        %% Restart from the same real ledger. No replacement genesis, module
        %% source injection or manifest mutation participates in this startup.
        Resume = maps:without([prepared_genesis_entry, genesis_diff,
                               external_predicate_modules], Config#{mode => join}),
        Second = start_native_namespace(Ns, Resume),
        try assert_native_state(Ns, Anchor, Manifest, Self)
        after stop_native_namespace(Second) end,
        ok = file:del_dir_r(Dir)
    end}.

start_native_namespace(Ns, Config) ->
    true = quod_reg:subscribe({runtime, Ns}),
    {ok, Sup} = quod_ns:start_link(Ns, Config),
    unlink(Sup),
    receive {replay_ready, _, _} -> ok
    after 10000 -> error({native_namespace_not_ready, Ns}) end,
    quod_reg:unsubscribe({runtime, Ns}),
    Sup.

stop_native_namespace(Sup) ->
    Monitor = monitor(process, Sup),
    exit(Sup, shutdown),
    receive {'DOWN', Monitor, process, Sup, _} -> ok
    after 5000 -> error(native_namespace_not_stopped) end.

assert_native_state(Ns, Anchor, Manifest, Self) ->
    ?assertEqual(Anchor, quod_simplex:genesis_hash(Ns)),
    ?assertMatch({ok, [#{'Self' := {node, Self}}], _}, quod_prolog:prove_ro(Ns,
      {',', {external_predicate_modules, Manifest},
       {',', {saved, unchanged}, {me, {'Self'}}}})).

delete_est(#est{db = #db{ref = Ref}}) ->
    quod_erlog_db_mvcc:delete(Ref).
