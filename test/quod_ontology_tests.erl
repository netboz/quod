-module(quod_ontology_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include("quod_ingress_limits.hrl").

-define(ROOT_NS, <<"quod:root">>).

ontology_creation_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(Fixture) ->
         [?_test(create_and_resume(Fixture)),
          ?_test(prepared_input_is_single_use(Fixture)),
          ?_test(reconcile_republishes_running_content(Fixture)),
          ?_test(validation_precedes_mutation(Fixture)),
          ?_test(restrictive_policy_founds_and_serves(Fixture)),
          ?_test(collisions_preserve_existing_state(Fixture)),
          ?_test(failed_admission_rolls_back(Fixture)),
          ?_test(action_boundary_and_reasons(Fixture)),
          ?_test(lifecycle_authorization_guards(Fixture)),
          ?_test(anchored_lifecycle_reuses_foreign_scope(Fixture)),
          ?_test(action_timeout_is_outcome_unknown(Fixture)),
          ?_test(join_validation_and_state(Fixture)),
          ?_test(join_resume_anchor_is_exact(Fixture))]
     end}.

setup() ->
    {ok, _} = application:ensure_all_started(gproc),
    %% The BEAM unique-integer counter restarts with each EUnit VM. A setup
    %% failure skips cleanup, so include fresh entropy and never reopen that
    %% abandoned ledger under a new test identity.
    Suffix = binary_to_list(
               binary:encode_hex(crypto:strong_rand_bytes(8))),
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
    {?ROOT_NS, RootConfig0} = quod_app:build_ns_config(RootBlock),
    RootConfig = RootConfig0#{proof_timeout_ms => 500},
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
        [open_policy(),
         {terms, [{ordered, terms_first}, {note, welcome},
                  {allowed, reverse}]},
         {source_file, SourceOne},
         {source_file, list_to_binary(SourceTwo)},
         {source,
          <<"ordered(inline).\n"
            "welcomes(Who) :- note(Who).\n"
            "make_marker(Value) :- assertz(made(Value)).\n"
            "record_common_fact(Value) :- assertz(common_fact(Value)).\n"
            "record_blocked_action :- assertz(blocked_action).\n"
            "action(make_marker(reverse), [allowed(reverse)], made(reverse)).\n"
            "action(record_common_fact(asserted), [], common_fact(asserted)).\n"
            "action(record_blocked_action, [fail_with_reason(blocked_by_policy)], blocked_action).">>}],
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
        quod_prolog:prove(Ns, goal(blocked_action), Ns),
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
                  [{goal, 1}, {goal, 2}, {resolve_goal, 2},
                   {prepare_lifecycle_action, 3},
                   {prepare_lifecycle_candidate, 3},
                   {check_prerequisites, 1},
                   {satisfy_prerequisites, 2},
                   {run_transition, 1}, {run_transitions, 1},
                   {member_eq, 2}])]),
    ?assertEqual(
       3,
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

prepared_input_is_single_use(#{dir := Dir}) ->
    Ns = unique_ns(<<"prepared-once">>),
    Source = filename:join(Dir, "prepared-once.pl"),
    ok = file:write_file(
           Source, <<"can_invoke(_, _, _, _).\nprepared_value(original).">>),
    Action = {create_ontology, Ns, [{source_file, Source}]},
    {ok, Structural} = quod_ontology:validate_action(Action),
    {ok, Prepared} = quod_ontology:prepare_action(Structural),
    %% Execution must use the captured diff, not reopen mutable caller input.
    ok = file:write_file(Source, <<"prepared_value(changed).">>),
    {ok, created, Ns, _GenesisHash} =
        quod_ontology:execute_prepared(Prepared),
    ok = wait_ready(Ns, 200),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove_ro(Ns, {prepared_value, original}, Ns)),
    ?assertMatch(
       {fail, _},
       quod_prolog:prove_ro(Ns, {prepared_value, changed}, Ns)).

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
         [{source,
           <<"ontology_join_state(Name, State) :- true.">>}])),
    ?assertNot(filelib:is_dir(
                 quod_ledger_store:ns_dir(Dir, StaticCollisionNs))),
    ImproperOptionsNs = unique_ns(<<"improper-options">>),
    ?assertEqual(
       {error, invalid_options},
       quod_ontology:create(
         ImproperOptionsNs, [{terms, []} | improper_tail])),
    ?assertNot(filelib:is_dir(
                 quod_ledger_store:ns_dir(Dir, ImproperOptionsNs))),
    OversizedNs = unique_ns(<<"oversized-initial-content">>),
    OversizedPayload =
        binary:copy(<<"x">>, ?MAX_GENESIS_INITIAL_DIFF_BYTES),
    ?assertEqual(
       {error, initial_content_too_large},
       quod_ontology:create(
         OversizedNs, [{terms, [{oversized, OversizedPayload}]}])),
    ?assertNot(filelib:is_dir(
                 quod_ledger_store:ns_dir(Dir, OversizedNs))),
    ?assertEqual(
       Desired0,
       application:get_env(quod, namespace_desired, #{})),
    ?assertEqual(
       DataDirs0,
       application:get_env(quod, content_data_dirs, #{})),

    %% An author need not supply a can_invoke/4 clause: founding injects the
    %% bodyless host-entry default, so a policy-less create succeeds and the
    %% host can query its own new ontology (remote callers stay fail-closed).
    HostOnlyNs = unique_ns(<<"host-only">>),
    ?assertMatch(
       {ok, created, HostOnlyNs, _},
       quod_ontology:create(HostOnlyNs, [{terms, [{welcome, all}]}])),
    ok = wait_ready(HostOnlyNs, 200),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove_ro(HostOnlyNs, {welcome, all}, HostOnlyNs)).

%% A genesis carrying an explicit RESTRICTIVE can_invoke/4 clause founds and
%% becomes ready: a private ontology is a real, usable ontology (acceptance 32).
%% Its own host reaches it because the founder is admitted, and the empty chain
%% here is this host's own top-level entry.
restrictive_policy_founds_and_serves(_Fixture) ->
    PrivateNs = unique_ns(<<"private-policy">>),
    {ok, created, PrivateNs, _} =
        quod_ontology:create(
          PrivateNs,
          [{source,
            <<"secret_value(42).\n"
              "can_invoke(_Goal, {node, K}, [], _Ns) :- "
              "peer_admitted(K, _, _, K).">>}]),
    ok = wait_ready(PrivateNs, 200),
    %% the host's own top-level proof is admitted by the restrictive rule
    ?assertMatch(
       {ok, [#{'V' := 42}], _},
       quod_prolog:prove_ro(PrivateNs, {secret_value, {'V'}}, PrivateNs)).

collisions_preserve_existing_state(_Fixture) ->
    Ns = unique_ns(<<"collision">>),
    {ok, created, Ns, _} =
        quod_ontology:create(Ns, [open_policy(), {terms, [{kept, true}]}]),
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

action_boundary_and_reasons(#{dir := Dir}) ->
    Ns = unique_ns(<<"action-created">>),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:run_action(
         ?ROOT_NS,
          {create_ontology, Ns,
          [{source,
            <<"can_invoke(_, _, _, _).\n"
              "action_fact(works).\n"
              "action_rule(X) :- action_fact(X).">>}]})),
    ok = wait_ready(Ns, 200),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove_ro(Ns, {action_fact, works}, Ns)),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove_ro(Ns, {action_rule, works}, Ns)),
    ForbiddenNs = unique_ns(<<"forbidden">>),
    ?assertMatch(
       {fail, _},
       quod_prolog:prove(
         ?ROOT_NS,
         goal({create_ontology, ForbiddenNs, []}),
         ?ROOT_NS)),
    ?assertNot(filelib:is_dir(
                 quod_ledger_store:ns_dir(Dir, ForbiddenNs))),
    ?assertEqual(
       {error, invalid_action},
       quod_prolog:run_action(
         ?ROOT_NS, {assertz, {not_committed, true}})),
    ?assertMatch(
       {fail, _},
       quod_prolog:prove_ro(?ROOT_NS, {not_committed, true}, ?ROOT_NS)),
    DesiredBeforeInvalidName =
        application:get_env(quod, namespace_desired, #{}),
    ?assertEqual(
       {fail, [{ontology_creation_failed, invalid_name}]},
       quod_prolog:run_action(
         ?ROOT_NS, {create_ontology, <<>>, []})),
    ?assertEqual(
       {fail, [{ontology_join_failed, invalid_name}]},
       quod_prolog:run_action(
         ?ROOT_NS,
         {join_ontology, <<255>>, binary:encode_hex(<<0:256>>),
          [{seed, "127.0.0.1", 14567}]})),
    ?assertEqual(
       DesiredBeforeInvalidName,
       application:get_env(quod, namespace_desired, #{})),
    %% The old direct functor has no compiled, action, or generic-fact path.
    RemovedNs = unique_ns(<<"removed-action">>),
    RemovedAction = {create_ontology_effect, RemovedNs, []},
    ?assertEqual(
       {error, invalid_action},
       quod_prolog:run_action(?ROOT_NS, RemovedAction)),
    ?assertMatch(
       {fail, _},
       quod_prolog:prove(?ROOT_NS, RemovedAction, ?ROOT_NS)),
    DesiredBeforeRemovedGoal =
        application:get_env(quod, namespace_desired, #{}),
    ?assertMatch(
       {fail, _},
       quod_prolog:prove(?ROOT_NS, goal(RemovedAction), ?ROOT_NS)),
    ?assertEqual(
       DesiredBeforeRemovedGoal,
       application:get_env(quod, namespace_desired, #{})),
    ?assertNot(
       filelib:is_dir(quod_ledger_store:ns_dir(Dir, RemovedNs))),
    RootOnlyTarget = Ns,
    {fail, RootOnlyReasons} =
        quod_prolog:run_action(
          RootOnlyTarget,
          {create_ontology, unique_ns(<<"root-only">>), []}),
    ?assert(
       lists:member(
         {ontology_creation_failed, root_only},
         RootOnlyReasons)),
    {fail, InvalidTermReasons} =
        quod_prolog:run_action(
          ?ROOT_NS,
          {create_ontology, unique_ns(<<"invalid-terms">>),
           [{terms, [{member, x, []}]}]}),
    ?assert(
       lists:member(
         {ontology_creation_failed, invalid_initial_terms},
         InvalidTermReasons)),
    {fail, ImproperTermReasons} =
        quod_prolog:run_action(
          ?ROOT_NS,
          {create_ontology, unique_ns(<<"improper-terms">>),
           [{terms, [{valid_fact, true} | improper_tail]}]}),
    ?assert(
       lists:member(
         {ontology_creation_failed, invalid_options},
         ImproperTermReasons)),
    {fail, InvalidSourceReasons} =
        quod_prolog:run_action(
          ?ROOT_NS,
          {create_ontology, unique_ns(<<"invalid-source">>),
           [{terms, [{valid, first}]},
            {source, "valid.\nbroken("}]}),
    ?assert(
       lists:member(
         {ontology_creation_failed, {invalid_source, 2, 2}},
         InvalidSourceReasons)),
    {fail, InvalidOptionsReasons} =
        quod_prolog:run_action(
          ?ROOT_NS,
          {create_ontology, unique_ns(<<"invalid-options">>),
           [{unknown_option, value}]}),
    ?assert(
       lists:member(
         {ontology_creation_failed, invalid_options},
         InvalidOptionsReasons)),
    Large = binary:copy(<<"x">>, 5000),
    {fail, Reasons} =
        quod_prolog:run_action(
          ?ROOT_NS,
          {create_ontology, <<"quod:forbidden">>,
           [{terms, [{payload, Large}]}]}),
    ?assert(
       lists:member(
         {ontology_creation_failed, reserved_system_namespace},
         Reasons)).

lifecycle_authorization_guards(#{dir := Dir}) ->
    {ok, SelfKey} = application:get_env(quod, node_pubkey),
    PolicyProbe = unique_ns(<<"policy-probe">>),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove_ro(
         ?ROOT_NS,
         {can_create_ontology, {node, SelfKey}, PolicyProbe, []},
         ?ROOT_NS)),
    ?assertMatch(
       {fail, _},
       quod_prolog:prove_ro(
         ?ROOT_NS,
         {can_create_ontology, {node, <<0:256>>}, PolicyProbe, []},
         ?ROOT_NS)),
    ?assertEqual(
       effect,
       quod_predicates:class({authorized_ontology_lifecycle, 1})),
    ?assertEqual(undefined,
                 quod_predicates:class({create_ontology_effect, 2})),
    ?assertEqual(undefined,
                 quod_predicates:class({join_ontology_effect, 3})),

    Desired0 = application:get_env(quod, namespace_desired, #{}),
    ?assertEqual(
       {fail, [{ontology_creation_failed, invalid_arguments}]},
       quod_prolog:run_action(
         ?ROOT_NS, {create_ontology, {'Name'}, []})),
    ?assertEqual(Desired0,
                 application:get_env(quod, namespace_desired, #{})),

    DirectAction =
        {create_ontology, unique_ns(<<"direct-auth">>), []},
    ?assertMatch(
       {error, {erlog, {context_violation,
                        {authorized_ontology_lifecycle, 1}, effect, proof}}},
       quod_prolog:prove(
         ?ROOT_NS,
         {authorized_ontology_lifecycle, DirectAction},
         ?ROOT_NS)),

    AlreadyNs = unique_ns(<<"already-authorized">>),
    AlreadyAction = {create_ontology, AlreadyNs, [open_policy()]},
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:run_action(?ROOT_NS, AlreadyAction)),
    ok = wait_ready(AlreadyNs, 200),
    %% The exact desired state makes a repeated valid request idempotent.
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:run_action(?ROOT_NS, AlreadyAction)),
    %% Full input validation still precedes the target check.
    {fail, AlreadyInvalidReasons} =
        quod_prolog:run_action(
          ?ROOT_NS,
          {create_ontology, AlreadyNs,
           [{source, "valid.\nbroken("}]}),
    ?assert(lists:member(
              {ontology_creation_failed, {invalid_source, 1, 2}},
              AlreadyInvalidReasons)),

    %% Even if committed root content accidentally omits the visible
    %% authorization prerequisite, the typed executor performs the same check
    %% again immediately before IO.
    NoGateNs = unique_ns(<<"missing-visible-gate">>),
    NoGateAction =
        {action, {create_ontology, NoGateNs, []},
         [{ontology_join_state, NoGateNs, not_hosted}],
         {ontology_hosted, NoGateNs}},
    CreatePolicy = root_create_policy(),
    DeniedSourceNs = unique_ns(<<"denied-source">>),
    MissingSource = filename:join(Dir, "must-not-be-read.pl"),
    commit_root(
      {',', {retract, CreatePolicy}, {asserta, NoGateAction}}),
    try
        {fail, NoGateReasons} =
            quod_prolog:run_action(
              ?ROOT_NS, {create_ontology, NoGateNs, []}),
        ?assert(lists:member(
                  {ontology_creation_failed, not_authorized},
                  NoGateReasons)),
        ?assertNot(filelib:is_dir(
                     quod_ledger_store:ns_dir(Dir, NoGateNs))),
        %% Authorization is required even when the target is already true.
        ?assertEqual(
           {fail, [{ontology_creation_failed, not_authorized}]},
           quod_prolog:run_action(?ROOT_NS, AlreadyAction)),
        %% A denied request cannot disclose whether an attacker-selected path
        %% exists or parses: the path is never opened before authorization.
        ?assertEqual(
           {fail, [{ontology_creation_failed, not_authorized}]},
           quod_prolog:run_action(
             ?ROOT_NS,
             {create_ontology, DeniedSourceNs,
              [{source_file, MissingSource}]})),
        ?assertNot(filelib:is_dir(
                     quod_ledger_store:ns_dir(Dir, DeniedSourceNs)))
    after
        commit_root({assertz, CreatePolicy})
    end,

    %% Authorization policy itself is strictly read-only. The first assert is
    %% rejected, so an assert/retract pair cannot authorize through a net-empty
    %% diff and cannot fall through to the general allow rule.
    PolicyWriteNs = unique_ns(<<"policy-write">>),
    Marker = {policy_write_marker, PolicyWriteNs},
    PolicyWriteRule =
        {':-',
         {can_create_ontology, {node, {'K'}}, PolicyWriteNs, []},
         {',', {assertz, Marker},
          {',', {retract, Marker},
           {peer_admitted, {'K'}, {'_'}, {'_'}, {'K'}}}}},
    commit_root(
      {',', {retract, CreatePolicy}, {asserta, PolicyWriteRule}}),
    try
        {fail, PolicyWriteReasons} =
            quod_prolog:run_action(
              ?ROOT_NS, {create_ontology, PolicyWriteNs, []}),
        ?assert(lists:member(
                  {ontology_creation_failed, not_authorized},
                  PolicyWriteReasons)),
        ?assertMatch(
           {fail, _},
           quod_prolog:prove_ro(?ROOT_NS, Marker, ?ROOT_NS)),
        ?assertNot(filelib:is_dir(
                     quod_ledger_store:ns_dir(Dir, PolicyWriteNs)))
    after
        commit_root(
          {',', {retract, PolicyWriteRule}, {assertz, CreatePolicy}})
    end,

    %% The whole action-preparation phase is read-only as well; a declaration
    %% that tries to stage a fact aborts before the typed executor.
    PhaseWriteNs = unique_ns(<<"phase-write">>),
    PhaseMarker = {phase_write_marker, PhaseWriteNs},
    PhaseWriteAction =
        {action, {create_ontology, PhaseWriteNs, [open_policy()]},
         [{assertz, PhaseMarker}], {ontology_hosted, PhaseWriteNs}},
    CreateDeclaration = root_creation_action(),
    commit_root(
      {',', {retract, CreateDeclaration}, {asserta, PhaseWriteAction}}),
    try
        ?assertEqual(
           {error, lifecycle_staged_write},
           quod_prolog:run_action(
             ?ROOT_NS, {create_ontology, PhaseWriteNs, [open_policy()]})),
        ?assertMatch(
           {fail, _},
           quod_prolog:prove_ro(?ROOT_NS, PhaseMarker, ?ROOT_NS)),
        ?assertNot(filelib:is_dir(
                     quod_ledger_store:ns_dir(Dir, PhaseWriteNs)))
    after
        commit_root(
          {',', {retract, PhaseWriteAction},
           {assertz, CreateDeclaration}})
    end,

    %% A root without the matching transition declaration fails with a stable
    %% public reason, not an internal preparer frame.
    MissingActionNs = unique_ns(<<"missing-action">>),
    commit_root({retract, CreateDeclaration}),
    try
        ?assertEqual(
           {fail, [{ontology_creation_failed, action_not_declared}]},
           quod_prolog:run_action(
             ?ROOT_NS, {create_ontology, MissingActionNs, []})),
        ?assertNot(filelib:is_dir(
                     quod_ledger_store:ns_dir(Dir, MissingActionNs)))
    after
        commit_root({assertz, CreateDeclaration})
    end,

    %% A literal-true desired state is malformed. Even when such a clause is
    %% ordered before the valid generic declaration for the same transition,
    %% selection skips it and executes the valid lifecycle action.
    MixedNs = unique_ns(<<"mixed-true-state">>),
    MixedAction = {create_ontology, MixedNs, [open_policy()]},
    InvalidTrueDeclaration = {action, MixedAction, [], true},
    commit_root({asserta, InvalidTrueDeclaration}),
    try
        ?assertMatch(
           {ok, [#{}], _},
           quod_prolog:run_action(?ROOT_NS, MixedAction)),
        ok = wait_ready(MixedNs, 200),
        ?assertEqual({ok, ready}, quod_ontology:local_state(MixedNs))
    after
        commit_root({retract, InvalidTrueDeclaration})
    end,

    %% A typed start followed by a false selected postcondition is ambiguous:
    %% hosting changed, so the runner reports outcome_unknown rather than a
    %% definite logical failure or trying another transition.
    BadPostNs = unique_ns(<<"bad-postcondition">>),
    BadPostAction = {create_ontology, BadPostNs, [open_policy()]},
    FalsePostDeclaration =
        {action, BadPostAction,
         [{authorized_ontology_lifecycle, BadPostAction},
          {ontology_join_state, BadPostNs, not_hosted}],
         {never_reached, BadPostNs}},
    commit_root(
      {',', {retract, CreateDeclaration},
       {asserta, FalsePostDeclaration}}),
    try
        ?assertEqual(
           {error, outcome_unknown},
           quod_prolog:run_action(?ROOT_NS, BadPostAction)),
        ok = wait_ready(BadPostNs, 200),
        ?assertEqual({ok, ready}, quod_ontology:local_state(BadPostNs))
    after
        commit_root(
          {',', {retract, FalsePostDeclaration},
           {assertz, CreateDeclaration}})
    end.

%% Both selected prerequisites and post-I/O verification execute through fresh
%% root invocations, but their pinned target identity belongs to the one
%% lifecycle proof context. Successful creation proves every foreign check ran;
%% the target's proof counter proves they reused one read-only scope session.
anchored_lifecycle_reuses_foreign_scope(_Fixture) ->
    ForeignNs = unique_ns(<<"lifecycle-prerequisite">>),
    {ok, created, ForeignNs, _ForeignAnchor} =
        quod_ontology:create(
          ForeignNs,
          [{source,
            <<"lifecycle_ready(yes).\n"
              "can_invoke(_, _, _, _).\n">>}]),
    ok = wait_ready(ForeignNs, 200),
    TargetNs = unique_ns(<<"anchored-action">>),
    Action = {create_ontology, TargetNs, [open_policy()]},
    ForeignCheck = {'::', ForeignNs, {lifecycle_ready, yes}},
    Declaration =
        {action, Action,
         [{authorized_ontology_lifecycle, Action},
          {ontology_join_state, TargetNs, not_hosted},
          ForeignCheck, ForeignCheck],
         {',', {ontology_hosted, TargetNs}, ForeignCheck}},
    CreateDeclaration = root_creation_action(),
    commit_root(
      {',', {retract, CreateDeclaration}, {asserta, Declaration}}),
    Before = maps:get(proves, quod_prolog:stats(ForeignNs)),
    try
        ?assertMatch(
           {ok, [#{}], _},
           quod_prolog:run_action(?ROOT_NS, Action)),
        ok = wait_ready(TargetNs, 200),
        ?assertEqual(
           Before + 1,
           maps:get(proves, quod_prolog:stats(ForeignNs)))
    after
        commit_root(
          {',', {retract, Declaration},
           {assertz, CreateDeclaration}})
    end.

action_timeout_is_outcome_unknown(#{manager := Manager}) ->
    Ns = unique_ns(<<"action-timeout">>),
    ok = sys:suspend(Manager),
    Result =
        try
            quod_prolog:run_action(
              ?ROOT_NS, {create_ontology, Ns, [open_policy()]})
        after
            ok = sys:resume(Manager)
        end,
    ?assertEqual({error, outcome_unknown}, Result),
    %% The manager may already hold the accepted request after the worker was
    %% killed. Polling local state is therefore the only safe retry decision.
    ok = wait_ready(Ns, 200),
    ?assertEqual({ok, ready}, quod_ontology:local_state(Ns)),
    GenesisHash = quod_simplex:genesis_hash(Ns),
    ?assertEqual(32, byte_size(GenesisHash)),
    Desired = application:get_env(quod, namespace_desired, #{}),
    Config = maps:get(Ns, maps:get(content, Desired)),
    Dirs = application:get_env(quod, content_data_dirs, #{}),
    ?assertEqual(
       quod_ledger_store:ledger_dir(Config),
       maps:get(Ns, Dirs)).

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
    {ok, created, StateNs, _} =
        quod_ontology:create(StateNs, [open_policy()]),
    ok = wait_ready(StateNs, 200),
    {fail, StateReasons} =
        quod_prolog:prove_ro(
          StateNs,
          {ontology_join_state, StateNs, {'State'}}, StateNs),
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
        quod_ontology:create(Ns, [open_policy(), {terms, [{durable, original}]}]),
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

commit_root(Goal) ->
    ?assertMatch(
       {ok, [_ | _], _},
       quod_prolog:prove(?ROOT_NS, Goal, ?ROOT_NS)),
    ok.

reconcile_republishes_running_content(#{manager := Manager}) ->
    Ns = unique_ns(<<"reconcile-publish">>),
    {ok, created, Ns, _GenesisHash} =
        quod_ontology:create(Ns, [open_policy()]),
    ok = wait_ready(Ns, 200),
    Desired = application:get_env(quod, namespace_desired, #{}),
    Config = maps:get(Ns, maps:get(content, Desired)),
    ExpectedDir = quod_ledger_store:ledger_dir(Config),
    application:set_env(quod, content_data_dirs, #{}),
    Manager ! reconcile,
    ok = wait_data_dir(Ns, ExpectedDir, 200).

root_creation_action() ->
    File = filename:join(code:priv_dir(quod), "ontologies/quod_root.pl"),
    [Declaration] =
        [Term || {action, {create_ontology, _, _}, _,
                  {ontology_hosted, _}} = Term <-
                     quod_prolog:read_terms(File)],
    Declaration.

root_create_policy() ->
    File = filename:join(code:priv_dir(quod), "ontologies/quod_root.pl"),
    [Policy] =
        [Term || {':-', {can_create_ontology, _, _, _}, _} = Term <-
                     quod_prolog:read_terms(File)],
    Policy.

%% Every genuinely fresh creation must carry a can_invoke/4 clause (an ontology
%% born without one could never be given one); positive fixtures prepend this.
open_policy() ->
    {source, <<"can_invoke(_, _, _, _).">>}.

wait_ready(_Ns, 0) ->
    {error, timeout};
wait_ready(Ns, N) ->
    case quod_prolog:prove_ro(Ns, true, Ns) of
        {ok, _, _} -> ok;
        _ ->
            timer:sleep(10),
            wait_ready(Ns, N - 1)
    end.

wait_data_dir(_Ns, _Expected, 0) ->
    {error, timeout};
wait_data_dir(Ns, Expected, N) ->
    Dirs = application:get_env(quod, content_data_dirs, #{}),
    case maps:get(Ns, Dirs, undefined) of
        Expected -> ok;
        _ ->
            timer:sleep(10),
            wait_data_dir(Ns, Expected, N - 1)
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
