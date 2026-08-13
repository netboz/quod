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
          ?_test(authenticated_registration_creates_its_home(Fixture)),
          ?_test(foreign_prerequisite_excludes_direct_effect(Fixture)),
          ?_test(action_timeout_is_outcome_unknown(Fixture)),
          ?_test(effect_completion_survives_journal_restart(Fixture)),
          ?_test(action_resume_reuses_existing_anchor(Fixture)),
          ?_test(desired_state_rejects_same_name_wrong_anchor(Fixture)),
          ?_test(lifecycle_actions_leave_root_facts_unchanged(Fixture)),
          ?_test(join_validation_and_state(Fixture)),
          ?_test(join_resume_anchor_is_exact(Fixture)),
          ?_test(action_resume_after_content_tree_restart(Fixture))]
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
               namespace_desired, content_storage_dirs]),
    {Pub, Seed} = quod_identity:generate(),
    application:set_env(quod, node_pubkey, Pub),
    application:set_env(
      quod, identity_key, quod_identity:key_term({Pub, Seed})),
    application:set_env(quod, node_addr, {"127.0.0.1", 14567}),
    application:set_env(
      quod, namespace_desired,
      #{content => #{}, brahms => #{}}),
    application:set_env(quod, content_storage_dirs, #{}),
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
    CurrentManager = quod_reg:where({namespace_manager, node}),
    CurrentNsSup = quod_reg:where({quod_ns_sup, node}),
    Desired = application:get_env(
                quod, namespace_desired,
                #{content => #{}, brahms => #{}}),
    Content = maps:get(content, Desired, #{}),
    case is_pid(CurrentManager) andalso is_process_alive(CurrentManager) of
        true ->
            lists:foreach(
              fun(Ns) ->
                  _ = quod_namespace_manager:stop_content(Ns)
              end, maps:keys(Content));
        false -> ok
    end,
    stop_processes([CurrentManager, Manager]),
    stop_processes([CurrentNsSup, NsSup]),
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
       quod_prolog:prove_ro(Ns, {note, welcome})),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove_ro(Ns, {welcomes, welcome})),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove(Ns, goal({made, reverse}))),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove(Ns, goal({common_fact, asserted}))),
    {fail, BlockedReasons} =
        quod_prolog:prove(Ns, goal(blocked_action)),
    ?assert(lists:member(blocked_by_policy, BlockedReasons)),
    ?assertMatch(
       {fail, _},
       quod_prolog:prove_ro(Ns, blocked_action)),
    lists:foreach(
      fun(Value) ->
          ?assertMatch(
             {ok, [#{}], _},
             quod_prolog:prove_ro(Ns, {ordered, Value}))
      end, [terms_first, file_one, file_two, inline]),
    ?assertMatch(
       {ok, [_], _},
       quod_prolog:prove_ro(Ns, {consensus_incarnation, {'Nonce'}})),
    ?assertMatch(
       {ok, [_], _},
       quod_prolog:prove_ro(
         Ns, {peer_admitted, {'Id'}, {'Host'}, {'Port'}, {'Key'}})),
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
    Dirs = application:get_env(quod, content_storage_dirs, #{}),
    ?assertEqual(
       #{data => quod_ledger_store:data_dir(CreatedConfig),
         ledger => quod_ledger_store:ledger_dir(CreatedConfig)},
       maps:get(Ns, Dirs)),
    ?assert(filelib:is_dir(quod_ledger_store:ns_dir(Dir, Ns))),
    ok = quod_namespace_manager:stop_content(Ns),
    {ok, resumed, Ns, GenesisHash} =
        quod_ontology:create(
          Ns, [{terms, [{note, must_not_appear}]}]),
    ok = wait_ready(Ns, 200),
    ?assertMatch(
       {fail, _},
       quod_prolog:prove_ro(Ns, {note, must_not_appear})),
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
       quod_prolog:prove_ro(Ns, {prepared_value, original})),
    ?assertMatch(
       {fail, _},
       quod_prolog:prove_ro(Ns, {prepared_value, changed})).

validation_precedes_mutation(#{dir := Dir}) ->
    Desired0 = application:get_env(quod, namespace_desired, #{}),
    DataDirs0 = application:get_env(quod, content_storage_dirs, #{}),
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
       application:get_env(quod, content_storage_dirs, #{})),

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
       quod_prolog:prove_ro(HostOnlyNs, {welcome, all})).

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
       quod_prolog:prove_ro(PrivateNs, {secret_value, {'V'}})).

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
       quod_prolog:prove_ro(Ns, {kept, true})).

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

action_boundary_and_reasons(#{dir := Dir, root_config := RootConfig}) ->
    Ns = unique_ns(<<"action-created">>),
    {ok, [#{}], EffectHeight} =
        quod_prolog:run_action(
          ?ROOT_NS,
           {create_ontology, Ns,
           [{source,
             <<"can_invoke(_, _, _, _).\n"
               "action_fact(works).\n"
               "action_rule(X) :- action_fact(X).">>}]}),
    {ok, RootStore} = quod_ledger_store:open_ro(
                        ?ROOT_NS,
                        quod_ledger_store:ledger_dir(RootConfig)),
    {ok, #entry{data = {batch,
                        [#transaction{diff = [], effects = [Effect]}]}}} =
        quod_ledger_store:read_at(RootStore, EffectHeight),
    ok = quod_ledger_store:close(RootStore),
    ?assertEqual(create, quod_effect:operation(Effect)),
    ?assertEqual(Ns, element(1, quod_effect:target(Effect))),
    ?assertMatch(
       {ok, #{state := applied, height := EffectHeight}},
       quod_effect_journal:status(quod_effect:effect_id(Effect))),
    ok = wait_ready(Ns, 200),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove_ro(Ns, {action_fact, works})),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove_ro(Ns, {action_rule, works})),
    ForbiddenNs = unique_ns(<<"forbidden">>),
    ?assertMatch(
       {error, {erlog, {context_violation,
                        {create_ontology, 2}, effect, proof}}},
       quod_prolog:prove(
         ?ROOT_NS,
         goal({create_ontology, ForbiddenNs, []}))),
    ?assertNot(filelib:is_dir(
                 quod_ledger_store:ns_dir(Dir, ForbiddenNs))),
    %% The common top-level executor recognizes a declared action.  The
    %% console uses this same entry point, so creation is not a separate
    %% operator-only mechanism.
    ConsoleNs = unique_ns(<<"console-created">>),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:execute(
         ?ROOT_NS, {create_ontology, ConsoleNs, [open_policy()]})),
    ok = wait_ready(ConsoleNs, 200),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove_ro(ConsoleNs, true)),
    %% The Explorer parser represents a quoted namespace as a character list.
    %% It shares the same canonical name grammar as Erlang callers.
    ConsoleTextNs = binary_to_list(unique_ns(<<"console-text">>)),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:execute(
         ?ROOT_NS, {create_ontology, ConsoleTextNs, [open_policy()]})),
    ?assertEqual(iolist_to_binary(ConsoleTextNs),
                 quod_ontology_name:flatten(ConsoleTextNs)),
    ?assertEqual(
       {error, invalid_action},
       quod_prolog:run_action(
         ?ROOT_NS, {assertz, {not_committed, true}})),
    ?assertMatch(
       {fail, _},
       quod_prolog:prove_ro(?ROOT_NS, {not_committed, true})),
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
       quod_prolog:prove(?ROOT_NS, RemovedAction)),
    DesiredBeforeRemovedGoal =
        application:get_env(quod, namespace_desired, #{}),
    ?assertMatch(
       {fail, _},
       quod_prolog:prove(?ROOT_NS, goal(RemovedAction))),
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
         {can_create_ontology, {node, SelfKey}, PolicyProbe, []})),
    ?assertMatch(
       {fail, _},
       quod_prolog:prove_ro(
         ?ROOT_NS,
         {can_create_ontology, {node, <<0:256>>}, PolicyProbe, []})),
    %% Open registration is not a second general creation authority.  Root
    %% accepts only the exact namespace and fixed terms derived from this key.
    {UserKey, _UserSeed} = quod_identity:generate(),
    {ok, UserNs} = quod_user:home_namespace(UserKey),
    {ok, UserOptions} = quod_user:home_options(UserKey),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove_ro(
         ?ROOT_NS,
         {can_create_ontology, {user, UserKey}, UserNs,
          UserOptions})),
    ?assertMatch(
       {fail, _},
       quod_prolog:prove_ro(
         ?ROOT_NS,
         {can_create_ontology, {user, UserKey}, PolicyProbe,
          UserOptions})),
    ?assertMatch(
       {fail, _},
       quod_prolog:prove_ro(
         ?ROOT_NS,
         {can_create_ontology, {user, UserKey}, UserNs,
          [{terms, [{user, forged}]}]})),
    %% `execute/2` is the common top-level entry, not an action-only wrapper:
    %% ordinary terms retain the exact proof path.
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:execute(?ROOT_NS, true)),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:execute_as(?ROOT_NS, true, {user, UserKey})),
    ?assertEqual(
       effect,
       quod_predicates:class({authorized_ontology_lifecycle, 1})),
    ?assertEqual(undefined,
                 quod_predicates:class({create_ontology_effect, 2})),
    ?assertEqual(undefined,
                 quod_predicates:class({join_ontology_effect, 3})),

    %% The authenticated-user action path is still mediated by the same root
    %% declaration and policy.  It creates one deterministic home locally;
    %% there is no global user registry and no node-ownership condition.
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:run_action_as(
         ?ROOT_NS, {create_ontology, UserNs, UserOptions},
         {user, UserKey})),
    ok = wait_ready(UserNs, 200),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove_ro(UserNs, {user_key, {'UserId'}, UserKey, active})),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove_ro(
         UserNs,
         {can_invoke, anything, {user, UserKey}, [remote], UserNs})),

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
         {authorized_ontology_lifecycle, DirectAction})),

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
           quod_prolog:prove_ro(?ROOT_NS, Marker)),
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
           quod_prolog:prove_ro(?ROOT_NS, PhaseMarker)),
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

    %% A typed start followed by a false selected postcondition is a definite
    %% operator failure recorded by the durable journal. Hosting changed, but
    %% the caller must not be told to resolve an already-known outcome or try
    %% another transition.
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
           {error, {operator_error, postcondition_failed}},
           quod_prolog:run_action(?ROOT_NS, BadPostAction)),
        ok = wait_ready(BadPostNs, 200),
        ?assertEqual({ok, ready}, quod_ontology:local_state(BadPostNs))
    after
        commit_root(
          {',', {retract, FalsePostDeclaration},
           {assertz, CreateDeclaration}})
    end.

authenticated_registration_creates_its_home(_Fixture) ->
    {ok, NetworkId} = quod_ontology:genesis_anchor(?ROOT_NS),
    {ok, NodeKey} = application:get_env(quod, node_pubkey),
    {PublicKey, _Seed} = KeyPair = quod_identity:generate(),
    {ok, AuthPid} = quod_client_auth:start_link(
                      #{network_id => NetworkId, node_key => NodeKey,
                        max_challenges => 4, max_sessions => 4}),
    Peer = {127, 0, 0, 1},
    try
        LoginNonce = crypto:strong_rand_bytes(32),
        {ok, Challenge} =
            quod_client_auth:issue_challenge(PublicKey, LoginNonce, Peer),
        ChallengeId = maps:get(challenge_id, Challenge),
        {ok, ChallengeBytes} = quod_user:challenge_bytes(
                                 NetworkId, NodeKey, ChallengeId, PublicKey,
                                 LoginNonce, maps:get(server_nonce, Challenge),
                                 maps:get(expires_ms, Challenge)),
        LoginSignature =
            quod_identity:sign(ChallengeBytes, quod_identity:key_term(KeyPair)),
        {ok, #{session_id := SessionId}} =
            quod_client_auth:complete_challenge(ChallengeId, LoginSignature),
        RegistrationNonce = crypto:strong_rand_bytes(32),
        {ok, RegistrationBytes} =
            quod_user:registration_bytes(NetworkId, PublicKey, RegistrationNonce),
        RegistrationSignature =
            quod_identity:sign(RegistrationBytes, quod_identity:key_term(KeyPair)),
        {ok, #{namespace := UserNs}} =
            quod_client_registration:register(
              SessionId, RegistrationNonce, RegistrationSignature, Peer),
        ok = wait_ready(UserNs, 200),
        ?assertMatch(
           {ok, [#{}], _},
           quod_prolog:prove_ro(
             UserNs,
             {can_invoke, anything, {user, PublicKey}, [remote], UserNs}))
    after
        %% Synchronous: the registered name must be free before anything else
        %% starts this server again.
        unlink(AuthPid),
        AuthRef = monitor(process, AuthPid),
        exit(AuthPid, shutdown),
        receive {'DOWN', AuthRef, process, AuthPid, _} -> ok after 5000 -> ok end
    end.

%% A direct local effect cannot be hidden inside a distributed transaction.
%% Reading a foreign prerequisite makes that ontology a participant, so the
%% sealed request is rejected before the local ontology is created.
foreign_prerequisite_excludes_direct_effect(#{dir := Dir}) ->
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
        ?assertEqual(
           {error, effect_requires_single_participant},
           quod_prolog:run_action(?ROOT_NS, Action)),
        ?assertNot(filelib:is_dir(
                     quod_ledger_store:ns_dir(Dir, TargetNs))),
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
    ?assertMatch(
       {error,
        {outcome_unknown,
         {transaction, ?ROOT_NS, <<_:256>>, <<_:256>>}}}, Result),
    {error, {outcome_unknown, Ref}} = Result,
    %% The manager may already hold the accepted request. The exact reference
    %% is what makes later resolution safe; the action must not be re-proved.
    ok = wait_ready(Ns, 200),
    ok = wait_local_state(Ns, ready, 200),
    ?assertMatch({ok, #{status := committed}}, quod_prolog:outcome(Ref)),
    GenesisHash = quod_simplex:genesis_hash(Ns),
    ?assertEqual(32, byte_size(GenesisHash)),
    Desired = application:get_env(quod, namespace_desired, #{}),
    Config = maps:get(Ns, maps:get(content, Desired)),
    Dirs = application:get_env(quod, content_storage_dirs, #{}),
    ?assertEqual(
       #{data => quod_ledger_store:data_dir(Config),
         ledger => quod_ledger_store:ledger_dir(Config)},
       maps:get(Ns, Dirs)).

%% The manager mutation can complete immediately before the effect journal
%% dies.  Recovery must observe the already-satisfied postcondition, mark the
%% original row applied, and preserve the exact public recovery reference; it
%% must not attempt to found a second incarnation.
effect_completion_survives_journal_restart(_Fixture) ->
    Ns = unique_ns(<<"effect-journal-restart">>),
    Tag = make_ref(),
    Parent = self(),
    application:set_env(quod, effect_test_after_execute, {Parent, Tag}),
    {Caller, CallerMRef} = spawn_monitor(
                            fun() ->
                                Parent !
                                    {restarted_action_result, self(),
                                     quod_prolog:run_action(
                                       ?ROOT_NS,
                                       {create_ontology, Ns,
                                        [open_policy()]})}
                            end),
    try
        Worker =
            receive
                {effect_after_execute, Tag, EffectWorker} -> EffectWorker
            after 5000 ->
                error(effect_execution_timeout)
            end,
        OldJournal = quod_reg:where({quod_effect_journal, node}),
        ?assert(is_pid(OldJournal)),
        application:unset_env(quod, effect_test_after_execute),
        JournalMRef = monitor(process, OldJournal),
        exit(OldJournal, kill),
        receive
            {'DOWN', JournalMRef, process, OldJournal, _} -> ok
        after 5000 ->
            error(effect_journal_stop_timeout)
        end,
        %% The blocked test worker watches its owner and cannot outlive the
        %% journal it represented.
        WorkerMRef = monitor(process, Worker),
        receive
            {'DOWN', WorkerMRef, process, Worker, _} -> ok
        after 5000 ->
            error(effect_worker_stop_timeout)
        end,
        ok = wait_new_effect_journal(OldJournal, 200),
        ok = wait_ready(?ROOT_NS, 200),
        ok = wait_ready(Ns, 200),
        Result =
            receive
                {restarted_action_result, Caller, ActionResult} ->
                    ActionResult
            after 5000 ->
                error(action_result_timeout)
            end,
        ?assertMatch(
           {error,
            {outcome_unknown,
             {transaction, ?ROOT_NS, <<_:256>>, <<_:256>>}}},
           Result),
        ?assertMatch(
           {ok, #{state := applied}},
           wait_effect_target_state(Ns, applied, 200)),
        receive
            {'DOWN', CallerMRef, process, Caller, normal} -> ok
        after 5000 ->
            error(action_caller_stop_timeout)
        end
    after
        application:unset_env(quod, effect_test_after_execute),
        exit(Caller, kill)
    end.

%% Re-establishing hosting after the runtime manager forgot its in-memory
%% desired state must bind the new root receipt to the immutable slot-1
%% anchor already on disk.  It must not preview a second incarnation.
action_resume_reuses_existing_anchor(_Fixture) ->
    Ns = unique_ns(<<"action-resume">>),
    Action = {create_ontology, Ns, [open_policy()]},
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:run_action(?ROOT_NS, Action)),
    ok = wait_ready(Ns, 200),
    Anchor = quod_simplex:genesis_hash(Ns),
    ?assertMatch(<<_:256>>, Anchor),
    ok = quod_namespace_manager:stop_content(Ns),
    ?assertEqual({ok, not_hosted}, quod_ontology:local_state(Ns)),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:run_action(?ROOT_NS, Action)),
    ok = wait_ready(Ns, 200),
    ?assertEqual(Anchor, quod_simplex:genesis_hash(Ns)).

%% A name-only desired predicate is not enough: a locally hosted fork with a
%% different genesis must make this effect incompatible, never already-applied.
desired_state_rejects_same_name_wrong_anchor(_Fixture) ->
    Ns = unique_ns(<<"desired-anchor">>),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:run_action(
         ?ROOT_NS, {create_ontology, Ns, [open_policy()]})),
    ok = wait_ready(Ns, 200),
    Actual = quod_simplex:genesis_hash(Ns),
    <<First, Rest/binary>> = Actual,
    Wrong = <<(First bxor 1), Rest/binary>>,
    Executor = application:get_env(quod, node_pubkey, <<0:256>>),
    Effect = {quod_direct_effect, 1, local_durable,
              ontology_lifecycle, create,
              crypto:hash(sha256, <<"wrong-anchor-effect">>), Executor,
              {node, Executor}, {Ns, Wrong},
              crypto:hash(sha256, <<"wrong-anchor-request">>),
              crypto:hash(sha256, <<"wrong-anchor-prepared">>)},
    ?assertEqual(
       incompatible,
       quod_effect_journal:test_desired_state(
         {ontology_hosted, Ns}, Effect)).

%% Lifecycle operations are durable root-ledger effects, not root knowledge.
%% Repeating them must therefore commit effect descriptors with an empty
%% Prolog diff instead of accumulating one root fact per hosted ontology.
lifecycle_actions_leave_root_facts_unchanged(
  #{root_config := RootConfig}) ->
    Heights =
        [begin
             Ns = unique_ns(<<"root-diff-free">>),
             {ok, [#{}], Height} = quod_prolog:run_action(
                                    ?ROOT_NS,
                                    {create_ontology, Ns,
                                     [open_policy()]}),
             ok = wait_ready(Ns, 200),
             Height
         end || _ <- lists:seq(1, 3)],
    {ok, Store} = quod_ledger_store:open_ro(
                    ?ROOT_NS,
                    quod_ledger_store:ledger_dir(RootConfig)),
    try
        lists:foreach(
          fun(Height) ->
              {ok, #entry{data = {batch, Transactions}}} =
                  quod_ledger_store:read_at(Store, Height),
              ?assert(lists:any(
                        fun(#transaction{diff = [], effects = [_]}) -> true;
                           (_) -> false
                        end, Transactions)),
              ?assertEqual(
                 [], lists:append(
                       [Diff || #transaction{effects = [_], diff = Diff}
                                    <- Transactions]))
          end, Heights)
    after
        ok = quod_ledger_store:close(Store)
    end.

%% The supported recovery boundary is wider than stop_content/1: after the
%% namespace manager and the whole content supervisor tree disappear, a new
%% application-lifetime manager has no hosting intent for the user ontology.
%% Reissuing the action must inspect the preserved ledger and reuse slot 1's
%% exact anchor rather than previewing a new incarnation.
action_resume_after_content_tree_restart(
  #{manager := Manager, ns_sup := NsSup, root_config := RootConfig}) ->
    Ns = unique_ns(<<"action-tree-restart">>),
    Action = {create_ontology, Ns, [open_policy()]},
    ?assertMatch({ok, [#{}], _}, quod_prolog:run_action(?ROOT_NS, Action)),
    ok = wait_ready(Ns, 200),
    Anchor = quod_simplex:genesis_hash(Ns),

    stop_process(Manager),
    stop_process(NsSup),
    application:set_env(
      quod, namespace_desired, #{content => #{}, brahms => #{}}),
    application:set_env(quod, content_storage_dirs, #{}),
    {ok, NewNsSup} = quod_ns_sup:start_link(),
    unlink(NewNsSup),
    {ok, NewManager} = quod_namespace_manager:start_link(),
    unlink(NewManager),
    {ok, _RootPid} =
        quod_namespace_manager:start_content(?ROOT_NS, RootConfig),
    ok = wait_ready(?ROOT_NS, 200),
    ?assertEqual({ok, not_hosted}, quod_ontology:local_state(Ns)),
    ?assertMatch({ok, [#{}], _}, quod_prolog:run_action(?ROOT_NS, Action)),
    ok = wait_ready(Ns, 200),
    ?assertEqual(Anchor, quod_simplex:genesis_hash(Ns)).

join_validation_and_state(#{dir := Dir}) ->
    Ns = unique_ns(<<"join-validation">>),
    Desired0 = application:get_env(quod, namespace_desired, #{}),
    DataDirs0 = application:get_env(quod, content_storage_dirs, #{}),
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
             application:get_env(quod, content_storage_dirs, #{}))
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
       quod_prolog:prove_ro(Ns, {durable, original})),
    ok = quod_namespace_manager:stop_content(Ns).

commit_root(Goal) ->
    ?assertMatch(
       {ok, [_ | _], _},
       quod_prolog:prove(?ROOT_NS, Goal)),
    ok.

reconcile_republishes_running_content(#{manager := Manager}) ->
    Ns = unique_ns(<<"reconcile-publish">>),
    {ok, created, Ns, _GenesisHash} =
        quod_ontology:create(Ns, [open_policy()]),
    ok = wait_ready(Ns, 200),
    Desired = application:get_env(quod, namespace_desired, #{}),
    Config = maps:get(Ns, maps:get(content, Desired)),
    ExpectedDirs = #{data => quod_ledger_store:data_dir(Config),
                     ledger => quod_ledger_store:ledger_dir(Config)},
    application:set_env(quod, content_storage_dirs, #{}),
    Manager ! reconcile,
    ok = wait_storage_dirs(Ns, ExpectedDirs, 200).

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
        [Term || {':-', {can_create_ontology, {node, _}, _, _}, _} = Term <-
                     quod_prolog:read_terms(File)],
    Policy.

%% Every genuinely fresh creation must carry a can_invoke/4 clause (an ontology
%% born without one could never be given one); positive fixtures prepend this.
open_policy() ->
    {source, <<"can_invoke(_, _, _, _).">>}.

wait_ready(_Ns, 0) ->
    {error, timeout};
wait_ready(Ns, N) ->
    case quod_prolog:prove_ro(Ns, true) of
        {ok, _, _} -> ok;
        _ ->
            timer:sleep(10),
            wait_ready(Ns, N - 1)
    end.

wait_new_effect_journal(_OldPid, 0) ->
    {error, timeout};
wait_new_effect_journal(OldPid, N) ->
    case quod_reg:where({quod_effect_journal, node}) of
        Pid when is_pid(Pid), Pid =/= OldPid -> ok;
        _ ->
            timer:sleep(10),
            wait_new_effect_journal(OldPid, N - 1)
    end.

wait_effect_target_state(_Ns, _Expected, 0) ->
    {error, timeout};
wait_effect_target_state(Ns, Expected, N) ->
    Matches =
        [Row || #{target := {RowNs, _Anchor}} = Row <-
                    quod_effect_journal:rows(),
                RowNs =:= Ns],
    case Matches of
        [#{state := Expected} = Row] -> {ok, Row};
        _ ->
            timer:sleep(10),
            wait_effect_target_state(Ns, Expected, N - 1)
    end.

wait_local_state(_Ns, _Expected, 0) ->
    {error, timeout};
wait_local_state(Ns, Expected, N) ->
    case quod_ontology:local_state(Ns) of
        {ok, Expected} -> ok;
        _ ->
            timer:sleep(10),
            wait_local_state(Ns, Expected, N - 1)
    end.

wait_storage_dirs(_Ns, _Expected, 0) ->
    {error, timeout};
wait_storage_dirs(Ns, Expected, N) ->
    Dirs = application:get_env(quod, content_storage_dirs, #{}),
    case maps:get(Ns, Dirs, undefined) of
        Expected -> ok;
        _ ->
            timer:sleep(10),
            wait_storage_dirs(Ns, Expected, N - 1)
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
    end;
stop_process(_) -> ok.

stop_processes(Pids) ->
    lists:foreach(fun stop_process/1, lists:usort(Pids)).

save_env(Keys) ->
    [{Key, application:get_env(quod, Key)} || Key <- Keys].

restore_env(Saved) ->
    lists:foreach(
      fun({Key, {ok, Value}}) ->
              application:set_env(quod, Key, Value);
         ({Key, undefined}) ->
              application:unset_env(quod, Key)
      end, Saved).
