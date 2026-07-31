-module(quod_ontology_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

-define(ROOT_NS, <<"quod:root">>).

ontology_creation_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(Fixture) ->
         [?_test(create_and_resume(Fixture)),
          ?_test(validation_precedes_mutation(Fixture)),
          ?_test(collisions_preserve_existing_state(Fixture)),
          ?_test(failed_admission_rolls_back(Fixture)),
          ?_test(effect_boundary_and_reasons(Fixture)),
          ?_test(join_validation_and_state(Fixture)),
          ?_test(join_resume_anchor_is_exact(Fixture))]
     end}.

setup() ->
    {ok, _} = application:ensure_all_started(gproc),
    Suffix = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join("/tmp", "quod_ontology_" ++ Suffix),
    Saved = save_env(
              [node_pubkey, identity_key, node_addr,
               namespace_desired, content_data_dirs]),
    {Pub, Seed} = quod_identity:generate(),
    application:set_env(quod, node_pubkey, Pub),
    application:set_env(
      quod, identity_key, quod_identity:key_term({Pub, Seed})),
    application:set_env(quod, node_addr, {"127.0.0.1", 14567}),
    application:set_env(
      quod, namespace_desired,
      #{content => #{}, brahms => #{}}),
    application:set_env(quod, content_data_dirs, #{}),
    {ok, BrahmsSup} = quod_brahms_sup:start_link(),
    unlink(BrahmsSup),
    {ok, NsSup} = quod_ns_sup:start_link(),
    unlink(NsSup),
    {ok, Manager} = quod_namespace_manager:start_link(),
    unlink(Manager),
    RootBlock =
        #{namespace => ?ROOT_NS, mode => create,
          genesis_file => <<"ontologies/quod_root.pl">>,
          data_dir => list_to_binary(Dir),
          seeds => []},
    {?ROOT_NS, RootConfig} = quod_app:build_ns_config(RootBlock),
    {ok, _RootPid} =
        quod_namespace_manager:start_content(?ROOT_NS, RootConfig),
    ok = wait_ready(?ROOT_NS, 200),
    #{dir => Dir, saved => Saved, manager => Manager,
      ns_sup => NsSup, brahms_sup => BrahmsSup,
      root_config => RootConfig}.

cleanup(#{dir := Dir, saved := Saved, manager := Manager,
          ns_sup := NsSup, brahms_sup := BrahmsSup}) ->
    Desired = application:get_env(
                quod, namespace_desired,
                #{content => #{}, brahms => #{}}),
    Content = maps:get(content, Desired, #{}),
    lists:foreach(
      fun(Ns) ->
          _ = quod_namespace_manager:stop_content(Ns)
      end, maps:keys(Content)),
    stop_process(Manager),
    stop_process(NsSup),
    stop_process(BrahmsSup),
    restore_env(Saved),
    _ = file:del_dir_r(Dir),
    ok.

create_and_resume(#{dir := Dir, root_config := RootConfig}) ->
    Ns = unique_ns(<<"created">>),
    SourceOne = filename:join(Dir, "ontology-source-one.pl"),
    SourceTwo = filename:join(Dir, "ontology-source-two.pl"),
    ok = file:write_file(SourceOne, <<"ordered(file_one).">>),
    ok = file:write_file(SourceTwo, <<"ordered(file_two).\n">>),
    Options =
        [{terms, [{ordered, terms_first}, {note, welcome},
                  {allowed, reverse},
                  {action, {make_marker, reverse},
                   [{allowed, reverse}], {made, reverse}},
                  {action, blocked_action,
                   [{fail_with_reason, blocked_by_policy}], true}]},
         {source_file, SourceOne},
         {source_file, list_to_binary(SourceTwo)},
         {source,
          <<"ordered(inline).\n"
            "welcomes(Who) :- note(Who).">>}],
    {ok, created, Ns, GenesisHash} =
        quod_ontology:create(Ns, Options),
    ?assertEqual(32, byte_size(GenesisHash)),
    ok = wait_ready(Ns, 200),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove_ro(Ns, {note, welcome}, Ns)),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove_ro(Ns, {welcomes, welcome}, Ns)),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove(Ns, goal({made, reverse}), Ns)),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove(Ns, goal({common_fact, asserted}), Ns)),
    {fail, BlockedReasons} =
        quod_prolog:effect(Ns, goal(blocked_action)),
    ?assert(lists:member(blocked_by_policy, BlockedReasons)),
    ?assertMatch(
       {fail, _},
       quod_prolog:prove_ro(Ns, blocked_action, Ns)),
    lists:foreach(
      fun(Value) ->
          ?assertMatch(
             {ok, [#{}], _},
             quod_prolog:prove_ro(Ns, {ordered, Value}, Ns))
      end, [terms_first, file_one, file_two, inline]),
    ?assertMatch(
       {ok, [_], _},
       quod_prolog:prove_ro(Ns, {consensus_incarnation, {'Nonce'}}, Ns)),
    ?assertMatch(
       {ok, [_], _},
       quod_prolog:prove_ro(
         Ns, {peer_admitted, {'Id'}, {'Host'}, {'Port'}, {'Key'}}, Ns)),
    Desired = application:get_env(quod, namespace_desired, #{}),
    CreatedConfig = maps:get(Ns, maps:get(content, Desired)),
    {ok, Store} =
        quod_ledger_store:open_ro(
          Ns, quod_ledger_store:ledger_dir(CreatedConfig)),
    {ok, #entry{data = {batch, [#transaction{diff = Diff}]}}} =
        quod_ledger_store:read_at(Store, 1),
    ok = quod_ledger_store:close(Store),
    OrderedValues =
        [Value || {assert, {{ordered, Value}, _Body}} <- Diff],
    ?assertEqual(
       [terms_first, file_one, file_two, inline], OrderedValues),
    %% The common action framework is a code baseline, not copied into genesis.
    ?assertEqual(
       [],
       [Head || {assert, {Head, _}} <- Diff,
                lists:member(
                  clause_functor(Head),
                  [{goal, 1}, {goal, 2},
                   {assert_effect, 1}, {satisfy_prereq, 2}])]),
    ?assertEqual(
       2,
       length([Head || {assert, {Head, _}} <- Diff,
                       clause_functor(Head) =:= {action, 3}])),
    ?assertEqual(
       quod_ledger_store:data_dir(RootConfig),
       quod_ledger_store:data_dir(CreatedConfig)),
    ?assertEqual(
       quod_ledger_store:ledger_dir(RootConfig),
       quod_ledger_store:ledger_dir(CreatedConfig)),
    Dirs = application:get_env(quod, content_data_dirs, #{}),
    ?assertEqual(
       quod_ledger_store:ledger_dir(CreatedConfig),
       maps:get(Ns, Dirs)),
    ?assert(filelib:is_dir(quod_ledger_store:ns_dir(Dir, Ns))),
    ok = quod_namespace_manager:stop_content(Ns),
    {ok, resumed, Ns, GenesisHash} =
        quod_ontology:create(
          Ns, [{terms, [{note, must_not_appear}]}]),
    ok = wait_ready(Ns, 200),
    ?assertMatch(
       {fail, _},
       quod_prolog:prove_ro(Ns, {note, must_not_appear}, Ns)),
    ?assert(maps:get(committed, quod_simplex:stats(Ns)) >= 3).

validation_precedes_mutation(#{dir := Dir}) ->
    Desired0 = application:get_env(quod, namespace_desired, #{}),
    DataDirs0 = application:get_env(quod, content_data_dirs, #{}),
    InvalidNames =
        [<<>>, <<255>>, binary:copy(<<"a">>, 129),
         <<"quod">>, <<"quod:private">>],
    lists:foreach(
      fun(Name) ->
          ?assertMatch({error, _}, quod_ontology:create(Name, [])),
          case Name of
              <<>> -> ok;
              _ ->
                  ?assertNot(filelib:is_dir(
                               quod_ledger_store:ns_dir(Dir, Name)))
          end
      end, InvalidNames),
    ReservedNs = unique_ns(<<"reserved-head">>),
    ?assertEqual(
       {error,
        {invalid_initial_term,
         {consensus_incarnation, forged}}},
       quod_ontology:create(
         ReservedNs, [{terms, [{consensus_incarnation, forged}]}])),
    ?assertNot(filelib:is_dir(
                 quod_ledger_store:ns_dir(Dir, ReservedNs))),
    ReservedPeerNs = unique_ns(<<"reserved-peer-head">>),
    ReservedPeer =
        {peer_admitted, <<0:256>>, "127.0.0.1", 14567, <<0:256>>},
    ?assertEqual(
       {error, {invalid_initial_term, ReservedPeer}},
       quod_ontology:create(ReservedPeerNs, [{terms, [ReservedPeer]}])),
    ?assertNot(filelib:is_dir(
                 quod_ledger_store:ns_dir(Dir, ReservedPeerNs))),
    BadTermsNs = unique_ns(<<"bad-terms">>),
    ?assertEqual(
       {error, invalid_initial_terms},
       quod_ontology:create(
         BadTermsNs, [{terms, [{"not-a-functor", x}]}])),
    ?assertNot(filelib:is_dir(
                 quod_ledger_store:ns_dir(Dir, BadTermsNs))),
    ImproperTermsNs = unique_ns(<<"improper-terms">>),
    ?assertEqual(
       {error, invalid_options},
       quod_ontology:create(
         ImproperTermsNs,
         [{terms, [{valid_fact, true} | improper_tail]}])),
    ?assertNot(filelib:is_dir(
                 quod_ledger_store:ns_dir(Dir, ImproperTermsNs))),
    LegacyTermsNs = unique_ns(<<"legacy-terms">>),
    ?assertEqual(
       {error, invalid_options},
       quod_ontology:create(LegacyTermsNs, [{legacy_fact, rejected}])),
    ?assertNot(filelib:is_dir(
                 quod_ledger_store:ns_dir(Dir, LegacyTermsNs))),
    InlineReservedNs = unique_ns(<<"inline-reserved">>),
    ?assertMatch(
       {error, {invalid_initial_term, _}},
       quod_ontology:create(
         InlineReservedNs,
         [{source, <<"consensus_incarnation(forged).">>}])),
    ?assertNot(filelib:is_dir(
                 quod_ledger_store:ns_dir(Dir, InlineReservedNs))),
    ReservedFile = filename:join(Dir, "reserved-source.pl"),
    ok = file:write_file(
           ReservedFile,
           <<"peer_admitted(a, b, c, d).">>),
    FileReservedNs = unique_ns(<<"file-reserved">>),
    ?assertMatch(
       {error, {invalid_initial_term, _}},
       quod_ontology:create(
         FileReservedNs, [{source_file, ReservedFile}])),
    ?assertNot(filelib:is_dir(
                 quod_ledger_store:ns_dir(Dir, FileReservedNs))),
    BadLaterNs = unique_ns(<<"bad-later-source">>),
    ?assertMatch(
       {error, {source_error, 2, 2, _}},
       quod_ontology:create(
         BadLaterNs,
         [{terms, [{would_be_partial, true}]},
          {source, <<"valid.\nbroken(">>}])),
    ?assertNot(filelib:is_dir(
                 quod_ledger_store:ns_dir(Dir, BadLaterNs))),
    MissingFileNs = unique_ns(<<"missing-file">>),
    ?assertMatch(
       {error, {source_file_error, 1, _, _}},
       quod_ontology:create(
         MissingFileNs,
         [{source_file,
           filename:join(Dir, "does-not-exist.pl")}])),
    ?assertNot(filelib:is_dir(
                 quod_ledger_store:ns_dir(Dir, MissingFileNs))),
    InvalidUtf8Ns = unique_ns(<<"invalid-utf8">>),
    ?assertEqual(
       {error, invalid_options},
       quod_ontology:create(
         InvalidUtf8Ns, [{source, <<255>>}])),
    ?assertNot(filelib:is_dir(
                 quod_ledger_store:ns_dir(Dir, InvalidUtf8Ns))),
    MalformedNs = unique_ns(<<"malformed-option">>),
    ?assertEqual(
       {error, invalid_options},
       quod_ontology:create(MalformedNs, [{source, <<"ok.">>, extra}])),
    ?assertNot(filelib:is_dir(
                 quod_ledger_store:ns_dir(Dir, MalformedNs))),
    StaticCollisionNs = unique_ns(<<"static-collision">>),
    ?assertEqual(
       {error, invalid_initial_terms},
       quod_ontology:create(
         StaticCollisionNs,
         [{terms,
           [{':-',
             {ontology_join_state, {'Name'}, {'State'}},
             true}]}])),
    ?assertNot(filelib:is_dir(
                 quod_ledger_store:ns_dir(Dir, StaticCollisionNs))),
    ImproperOptionsNs = unique_ns(<<"improper-options">>),
    ?assertEqual(
       {error, invalid_options},
       quod_ontology:create(
         ImproperOptionsNs, [{terms, []} | improper_tail])),
    ?assertNot(filelib:is_dir(
                 quod_ledger_store:ns_dir(Dir, ImproperOptionsNs))),
    ?assertEqual(
       Desired0,
       application:get_env(quod, namespace_desired, #{})),
    ?assertEqual(
       DataDirs0,
       application:get_env(quod, content_data_dirs, #{})).

collisions_preserve_existing_state(_Fixture) ->
    Ns = unique_ns(<<"collision">>),
    {ok, created, Ns, _} =
        quod_ontology:create(Ns, [{terms, [{kept, true}]}]),
    ok = wait_ready(Ns, 200),
    Pid0 = quod_reg:where({quod_ns, Ns}),
    Desired0 = application:get_env(quod, namespace_desired, #{}),
    ?assertEqual(
       {error, {already_configured, Ns}},
       quod_ontology:create(
         Ns, [{terms, [{replacement, forbidden}]}])),
    ?assertEqual(Pid0, quod_reg:where({quod_ns, Ns})),
    ?assert(is_process_alive(Pid0)),
    ?assertEqual(
       Desired0,
       application:get_env(quod, namespace_desired, #{})),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove_ro(Ns, {kept, true}, Ns)).

failed_admission_rolls_back(#{dir := Dir, manager := Manager}) ->
    Ns = unique_ns(<<"failed-start">>),
    Desired0 = application:get_env(quod, namespace_desired, #{}),
    ?assertMatch(
       {error, _},
       quod_namespace_manager:start_new_content(
         Ns, #{data_dir => Dir})),
    ?assertEqual(
       Desired0,
       application:get_env(quod, namespace_desired, #{})),
    ?assertEqual(undefined, quod_reg:where({quod_ns, Ns})),
    %% #s.retry is field 7. A failed normal start would arm this timer.
    ?assertEqual(undefined, element(7, sys:get_state(Manager))),
    OrphanNs = unique_ns(<<"orphan">>),
    Parent = self(),
    Orphan =
        spawn(
          fun() ->
              true = gproc:reg({n, l, {quod_ns, OrphanNs}}),
              Parent ! {orphan_ready, self()},
              receive stop -> ok end
          end),
    receive {orphan_ready, Orphan} -> ok after 1000 -> error(orphan_timeout) end,
    try
        ?assertEqual(
           {error, {already_configured, OrphanNs}},
           quod_namespace_manager:start_new_content(
             OrphanNs, #{data_dir => Dir})),
        ?assertEqual(
           Desired0,
           application:get_env(quod, namespace_desired, #{})),
        ?assert(is_process_alive(Orphan))
    after
        Orphan ! stop
    end.

effect_boundary_and_reasons(_Fixture) ->
    Ns = unique_ns(<<"effect-created">>),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:effect(
         ?ROOT_NS,
         goal(
           {create_ontology, Ns,
            [{source,
              <<"effect_fact(works).\n"
                "effect_rule(X) :- effect_fact(X).">>}]}))),
    ok = wait_ready(Ns, 200),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove_ro(Ns, {effect_fact, works}, Ns)),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove_ro(Ns, {effect_rule, works}, Ns)),
    ?assertMatch(
       {error, {erlog, {context_violation, _, effect, proof}}},
       quod_prolog:prove(
         ?ROOT_NS,
         goal({create_ontology, unique_ns(<<"forbidden">>), []}),
         ?ROOT_NS)),
    ?assertEqual(
       {error, effect_staged_write},
       quod_prolog:effect(?ROOT_NS, {assertz, {not_committed, true}})),
    ?assertMatch(
       {fail, _},
       quod_prolog:prove_ro(?ROOT_NS, {not_committed, true}, ?ROOT_NS)),
    %% The old direct functor has no compiled compatibility path.
    ?assertMatch(
       {fail, _},
       quod_prolog:effect(
         ?ROOT_NS,
         {create_ontology, unique_ns(<<"removed-direct">>), []})),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:effect(?ROOT_NS, goal(true))),
    RootOnlyTarget = Ns,
    {fail, RootOnlyReasons} =
        quod_prolog:effect(
          RootOnlyTarget,
          {create_ontology_effect,
           unique_ns(<<"root-only">>), []}),
    ?assert(
       lists:member(
         {ontology_creation_failed, root_only},
         RootOnlyReasons)),
    {fail, InvalidTermReasons} =
        quod_prolog:effect(
          ?ROOT_NS,
          goal(
            {create_ontology, unique_ns(<<"invalid-terms">>),
             [{terms, [{member, x, []}]}]})),
    ?assert(
       lists:member(
         {ontology_creation_failed, invalid_initial_terms},
         InvalidTermReasons)),
    {fail, ImproperTermReasons} =
        quod_prolog:effect(
          ?ROOT_NS,
          goal(
            {create_ontology, unique_ns(<<"improper-terms">>),
             [{terms, [{valid_fact, true} | improper_tail]}]})),
    ?assert(
       lists:member(
         {ontology_creation_failed, invalid_options},
         ImproperTermReasons)),
    {fail, InvalidSourceReasons} =
        quod_prolog:effect(
          ?ROOT_NS,
          goal(
            {create_ontology, unique_ns(<<"invalid-source">>),
             [{terms, [{valid, first}]},
              {source, "valid.\nbroken("}]})),
    ?assert(
       lists:member(
         {ontology_creation_failed, {invalid_source, 2, 2}},
         InvalidSourceReasons)),
    {fail, InvalidOptionsReasons} =
        quod_prolog:effect(
          ?ROOT_NS,
          goal(
            {create_ontology, unique_ns(<<"invalid-options">>),
             [{unknown_option, value}]})),
    ?assert(
       lists:member(
         {ontology_creation_failed, invalid_options},
         InvalidOptionsReasons)),
    Large = binary:copy(<<"x">>, 5000),
    {fail, Reasons} =
        quod_prolog:effect(
          ?ROOT_NS,
          goal(
            {create_ontology, <<"quod:forbidden">>,
             [{terms, [{payload, Large}]}]})),
    ?assert(
       lists:member(
         {ontology_creation_failed, reserved_system_namespace},
         Reasons)),
    ?assert(lists:member(fail_reasons_truncated, Reasons)).

join_validation_and_state(#{dir := Dir}) ->
    Ns = unique_ns(<<"join-validation">>),
    Desired0 = application:get_env(quod, namespace_desired, #{}),
    DataDirs0 = application:get_env(quod, content_data_dirs, #{}),
    GoodRaw = crypto:strong_rand_bytes(32),
    GoodHex = binary:encode_hex(GoodRaw),
    BadCalls =
        [{<<>>, GoodHex, [{seed, "127.0.0.1", 14567}]},
         {Ns, <<"bad">>, [{seed, "127.0.0.1", 14567}]},
         {Ns, GoodHex, []},
         {Ns, GoodHex, [{seed, "", 14567}]},
         {Ns, GoodHex, [{seed, "127.0.0.1", 0}]},
         {Ns, GoodHex,
          [{seed, "127.0.0.1", 14567},
           {seed, <<"127.0.0.1">>, 14567}]},
         {Ns, GoodHex,
          [{seed, "127.0.0.1", 14000 + I}
           || I <- lists:seq(1, 33)]}],
    lists:foreach(
      fun({Name, Hash, Seeds}) ->
          ?assertMatch({error, _}, quod_ontology:join(Name, Hash, Seeds)),
          ?assertEqual(
             Desired0,
             application:get_env(quod, namespace_desired, #{})),
          ?assertEqual(
             DataDirs0,
             application:get_env(quod, content_data_dirs, #{}))
      end, BadCalls),
    ?assertNot(filelib:is_dir(quod_ledger_store:ns_dir(Dir, Ns))),
    ?assertEqual({ok, ready}, quod_ontology:local_state(?ROOT_NS)),
    ?assertEqual({ok, not_hosted}, quod_ontology:local_state(Ns)),
    {ok, joining, Ns, GoodRaw} =
        quod_ontology:join(
          Ns, binary_to_list(GoodHex), [{seed, "::1", 65535}]),
    ?assertEqual({ok, joining}, quod_ontology:local_state(Ns)),
    Desired = application:get_env(quod, namespace_desired, #{}),
    JoinConfig = maps:get(Ns, maps:get(content, Desired)),
    ?assertEqual(join, maps:get(mode, JoinConfig)),
    ?assertEqual(GoodRaw, maps:get(genesis_hash, JoinConfig)),
    ?assertEqual([{"::1", 65535}], maps:get(seed_peers, JoinConfig)),
    ?assertEqual(ok, quod_namespace_manager:stop_content(Ns)),
    ?assertEqual({ok, not_hosted}, quod_ontology:local_state(Ns)),
    StateNs = unique_ns(<<"state-scope">>),
    {ok, created, StateNs, _} = quod_ontology:create(StateNs, []),
    ok = wait_ready(StateNs, 200),
    {fail, StateReasons} =
        quod_prolog:effect(
          StateNs,
          {ontology_join_state, StateNs, {'State'}}),
    ?assert(
       lists:member(
         {ontology_state_failed, root_only}, StateReasons)),
    ok = quod_namespace_manager:stop_content(StateNs),
    %% A live but mailbox-busy Simplex returns the status/1 default (`#{}`).
    %% The public state must conservatively remain joining, never ready.
    BusyNs = unique_ns(<<"busy-state">>),
    Parent = self(),
    BusyPid =
        spawn(
          fun() ->
              true = quod_reg:reg({quod_ns, BusyNs}),
              true = quod_reg:reg({quod_simplex, BusyNs}),
              Parent ! {busy_state_ready, self()},
              receive stop -> ok end
          end),
    receive
        {busy_state_ready, BusyPid} -> ok
    after 1000 ->
        error(busy_state_setup_timeout)
    end,
    DesiredBeforeBusy = application:get_env(quod, namespace_desired, #{}),
    BusyContent = maps:get(content, DesiredBeforeBusy, #{}),
    application:set_env(
      quod, namespace_desired,
      DesiredBeforeBusy#{content => BusyContent#{BusyNs => #{}}}),
    try
        ?assertEqual({ok, joining}, quod_ontology:local_state(BusyNs))
    after
        application:set_env(quod, namespace_desired, DesiredBeforeBusy),
        BusyPid ! stop
    end.

join_resume_anchor_is_exact(#{dir := Dir}) ->
    Ns = unique_ns(<<"join-resume">>),
    {ok, created, Ns, GenesisHash} =
        quod_ontology:create(Ns, [{terms, [{durable, original}]}]),
    ok = wait_ready(Ns, 200),
    ok = quod_namespace_manager:stop_content(Ns),
    LogPath = filename:join(
                quod_ledger_store:ns_dir(Dir, Ns), "log.0001"),
    {ok, Before} = file:read_file(LogPath),
    Desired0 = application:get_env(quod, namespace_desired, #{}),
    <<First, Rest/binary>> = GenesisHash,
    WrongHash = binary:encode_hex(<<(First bxor 1), Rest/binary>>),
    ?assertMatch(
       {error, _},
       quod_ontology:join(
         Ns, WrongHash, [{seed, "127.0.0.1", 14567}])),
    ?assertEqual(
       Desired0,
       application:get_env(quod, namespace_desired, #{})),
    ?assertEqual(undefined, quod_reg:where({quod_ns, Ns})),
    ?assertEqual({ok, Before}, file:read_file(LogPath)),
    {ok, resumed, Ns, GenesisHash} =
        quod_ontology:join(
          Ns, binary:encode_hex(GenesisHash),
          [{seed, "127.0.0.1", 14567}]),
    ok = wait_ready(Ns, 200),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove_ro(Ns, {durable, original}, Ns)),
    ok = quod_namespace_manager:stop_content(Ns).

wait_ready(_Ns, 0) ->
    {error, timeout};
wait_ready(Ns, N) ->
    case quod_prolog:prove_ro(Ns, true, Ns) of
        {ok, _, _} -> ok;
        _ ->
            timer:sleep(10),
            wait_ready(Ns, N - 1)
    end.

unique_ns(Prefix) ->
    <<Prefix/binary, ":",
      (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

goal(Goal) -> {goal, Goal}.

clause_functor(Head) when is_atom(Head) -> {Head, 0};
clause_functor(Head) when is_tuple(Head) ->
    {element(1, Head), tuple_size(Head) - 1}.

stop_process(Pid) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> gen_server:stop(Pid);
        false -> ok
    end.

save_env(Keys) ->
    [{Key, application:get_env(quod, Key)} || Key <- Keys].

restore_env(Saved) ->
    lists:foreach(
      fun({Key, {ok, Value}}) ->
              application:set_env(quod, Key, Value);
         ({Key, undefined}) ->
              application:unset_env(quod, Key)
      end, Saved).
