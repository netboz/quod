-module(quod_system_ontology_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

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
           {query, quod_committee_predicates, peer_ready_1},
           quod_predicates:descriptor(Common, {peer_ready, 1})),
        ?assertEqual(
           undefined,
           quod_predicates:descriptor(Common, {directory_host, 5})),
        ?assertMatch(
           {query, quod_directory_predicates, directory_host_5},
           quod_predicates:descriptor(Root, {directory_host, 5})),
        ?assertMatch(
           {staging, quod_ontology_predicates,
            lifecycle_request_predicate},
           quod_predicates:descriptor(Root, {create_ontology, 3})),
        ?assertEqual(
           undefined,
           quod_predicates:descriptor(Common, {create_ontology, 3}))
    after
        delete_est(Common),
        delete_est(Root)
    end.

predicate_manifest_pins_owned_beam_test() ->
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
       {error,
        {predicate_module_digest_mismatch, quod_directory_predicates}},
       quod_predicates:valid_manifest(
         [{quod_directory_predicates, Wrong}])).

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

delete_est(#est{db = #db{ref = Ref}}) ->
    quod_erlog_db_mvcc:delete(Ref).
