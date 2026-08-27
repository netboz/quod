-module(quod_lifecycle_single_path_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

-define(ROOT_NS, <<"quod:root">>).
-define(NODE_NS, <<"quod:node">>).

lifecycle_single_path_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(Fixture) ->
         [{timeout, 30, ?_test(effect_capacity_is_committed_root_policy(Fixture))},
          {timeout, 30, ?_test(create_is_one_normal_effect_transaction(Fixture))},
          {timeout, 30, ?_test(repeated_create_is_a_noop(Fixture))},
          {timeout, 30, ?_test(failed_transaction_branch_discards_its_effect(Fixture))},
          {timeout, 30, ?_test(join_uses_the_same_goal_path(Fixture))},
          {timeout, 30, ?_test(signed_agent_create_uses_the_same_goal_path(Fixture))},
          {timeout, 30, ?_test(signed_root_create_obeys_entry_acl(Fixture))},
          {timeout, 30, ?_test(prepared_source_is_used_exactly_once(Fixture))},
          {timeout, 30, ?_test(action_timeout_returns_exact_outcome(Fixture))},
          {timeout, 30, ?_test(effect_completion_survives_journal_restart(Fixture))},
          {timeout, 30, ?_test(effect_execution_uses_its_generic_descriptor(Fixture))},
          {timeout, 30, ?_test(stopped_ontology_resumes_same_anchor(Fixture))},
          ?_test(wrong_anchor_is_not_a_satisfied_effect(Fixture)),
          ?_test(structural_validation_is_total(Fixture)),
          ?_test(current_principal_is_engine_owned(Fixture)),
          ?_test(internal_staging_continuation_cannot_be_forged(Fixture)),
          ?_test(foreign_prerequisite_uses_normal_scope_boundary(Fixture)),
          ?_test(foreign_prerequisite_failure_keeps_its_reason(Fixture)),
          ?_test(agent_is_gated_by_root_creation_policy(Fixture)),
          ?_test(node_does_not_own_generic_creation_policy(Fixture)),
          ?_test(invalid_create_never_reaches_hosting(Fixture)),
          ?_test(reserved_initial_terms_never_reach_hosting(Fixture)),
          ?_test(collisions_preserve_existing_state(Fixture)),
          ?_test(failed_admission_rolls_back(Fixture)),
          ?_test(failed_root_policy_does_not_read_or_stage(Fixture)),
          ?_test(committed_agent_approval_uses_the_same_action(Fixture)),
          {timeout, 30, ?_test(false_postcondition_is_reported(Fixture))},
          ?_test(reconcile_republishes_running_content(Fixture)),
          {timeout, 30,
           ?_test(dynamic_hosting_survives_content_tree_restart(Fixture))}]
     end}.

effect_capacity_is_committed_root_policy(_Fixture) ->
    ?assertEqual(64, quod_effect_journal:capacity()),
    ?assertMatch(
       {ok, [#{'Capacity' := 64}], _},
       quod_prolog:prove_ro(
         ?ROOT_NS, {effect_custody_capacity, {'Capacity'}})),
    try
        %% A direct assertion is sufficient; the founding handler projects the
        %% resulting committed policy through the same P-before-E tier.
        commit_root(
          {assertz, {effect_custody_capacity_override, 3}}),
        ok = wait_effect_capacity(3, 300),
        ?assertMatch(
           {ok, [#{'Capacity' := 3}], _},
           quod_prolog:prove_ro(
             ?ROOT_NS, {effect_custody_capacity, {'Capacity'}})),

        %% The convenience predicate replaces the override atomically and has
        %% no compiled maximum.
        commit_root({set_effect_custody_capacity, unlimited}),
        ok = wait_effect_capacity(unlimited, 300),
        ?assertMatch(
           {fail, _},
           quod_prolog:execute(
             ?ROOT_NS, {set_effect_custody_capacity, -1}))
    after
        commit_root({set_effect_custody_capacity, 64}),
        ok = wait_effect_capacity(64, 300)
    end.

setup() ->
    {ok, _} = application:ensure_all_started(gproc),
    Suffix = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8))),
    Dir = filename:join("/tmp", "quod_lifecycle_single_" ++ Suffix),
    Saved = save_env(
              [node_pubkey, identity_key, node_addr,
               namespace_desired, namespace_static_content,
               namespace_desired_path, content_storage_dirs]),
    {Pub, Seed} = quod_identity:generate(),
    application:set_env(quod, node_pubkey, Pub),
    application:set_env(
      quod, identity_key, quod_identity:key_term({Pub, Seed})),
    application:set_env(quod, node_addr, {"127.0.0.1", 14567}),
    application:set_env(
      quod, namespace_desired, #{content => #{}, brahms => #{}}),
    application:set_env(
      quod, namespace_desired_path,
      filename:join(Dir, "hosted_namespaces.qnd")),
    application:set_env(quod, content_storage_dirs, #{}),
    {ok, Router} = quod_ask_router:start_link(),
    unlink(Router),
    {ok, ForeignLog} = quod_foreign_log:start_link(
                         #{cache_dir => filename:join(Dir, "foreign-log"),
                           page_timeout_ms => 1000}),
    unlink(ForeignLog),
    {ok, Journal} = quod_effect_journal:start_link(#{data_dir => Dir}),
    unlink(Journal),
    {ok, BrahmsSup} = quod_brahms_sup:start_link(),
    unlink(BrahmsSup),
    {ok, NsSup} = quod_ns_sup:start_link(),
    unlink(NsSup),
    {ok, Manager} = quod_namespace_manager:start_link(),
    unlink(Manager),
    RootBlock =
        #{namespace => ?ROOT_NS, mode => create,
          genesis_file => <<"ontologies/quod_root.pl">>,
          data_dir => list_to_binary(Dir), seeds => []},
    {?ROOT_NS, RootConfig0} = quod_app:build_ns_config(RootBlock),
    RootConfig = RootConfig0#{proof_timeout_ms => 5000},
    application:set_env(
      quod, namespace_static_content, #{?ROOT_NS => RootConfig}),
    {ok, _} = quod_namespace_manager:start_content(?ROOT_NS, RootConfig),
    ok = wait_ready(?ROOT_NS, 300),
    NodeSource = list_to_binary(
                   filename:join(code:priv_dir(quod),
                                 "ontologies/quod_node.pl")),
    {ok, created, ?NODE_NS, _} =
        quod_ontology:create(
          ?NODE_NS,
          [{source_file, NodeSource},
           {external_predicate_modules, [quod_ontology_predicates]}]),
    ok = wait_ready(?NODE_NS, 300),
    ok = wait_effect_capacity(64, 300),
    #{dir => Dir, saved => Saved, manager => Manager,
      ns_sup => NsSup, brahms_sup => BrahmsSup, journal => Journal,
      router => Router, foreign_log => ForeignLog,
      root_config => RootConfig}.

cleanup(#{dir := Dir, saved := Saved, manager := Manager,
          ns_sup := NsSup, brahms_sup := BrahmsSup, journal := Journal,
          router := Router, foreign_log := ForeignLog}) ->
    Desired = application:get_env(
                quod, namespace_desired,
                #{content => #{}, brahms => #{}}),
    CurrentManager = quod_reg:where({namespace_manager, node}),
    case is_pid(CurrentManager) of
        true ->
            lists:foreach(
              fun(Ns) -> _ = quod_namespace_manager:stop_content(Ns) end,
              maps:keys(maps:get(content, Desired, #{})));
        false -> ok
    end,
    stop_process(CurrentManager),
    stop_process(Manager),
    stop_process(quod_reg:where({quod_ns_sup, node})),
    stop_process(NsSup),
    stop_process(BrahmsSup),
    stop_process(quod_reg:where({quod_effect_journal, node})),
    stop_process(Journal),
    stop_process(ForeignLog),
    stop_process(Router),
    restore_env(Saved),
    _ = file:del_dir_r(Dir),
    ok.

create_is_one_normal_effect_transaction(#{root_config := RootConfig}) ->
    Ns = unique_ns(<<"created">>),
    Goal =
        {create_ontology, Ns,
         [{source,
           <<"can_invoke(_, _, _, _).\n"
             "hello(world).\n">>}]},
    {ok, [#{}], Height} = quod_prolog:execute(?ROOT_NS, Goal),
    ok = wait_ready(Ns, 300),
    ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {hello, world})),
    {ok, Store} = quod_ledger_store:open_ro(
                    ?ROOT_NS, quod_ledger_store:ledger_dir(RootConfig)),
    try
        {ok, #entry{data = {batch, Transactions}}} =
            quod_ledger_store:read_at(Store, Height),
        ?assert(lists:any(
                  fun(#transaction{diff = [], effects = [_]}) -> true;
                     (_) -> false
                  end, Transactions))
    after
        ok = quod_ledger_store:close(Store)
    end,
    EffectRows =
        [Row || #{target := {RowNs, _}} = Row <-
                    quod_effect_journal:rows(),
                RowNs =:= Ns],
    ?assertMatch([#{state := applied}], EffectRows).

repeated_create_is_a_noop(_Fixture) ->
    Ns = unique_ns(<<"repeated">>),
    Goal = {create_ontology, Ns, []},
    ?assertMatch({ok, [#{}], _}, quod_prolog:execute(?ROOT_NS, Goal)),
    ok = wait_ready(Ns, 300),
    Before = maps:get(committed, quod_simplex:stats(?ROOT_NS)),
    ?assertMatch({ok, [#{}], _}, quod_prolog:execute(?ROOT_NS, Goal)),
    ?assertEqual(Before, maps:get(committed, quod_simplex:stats(?ROOT_NS))).

failed_transaction_branch_discards_its_effect(_Fixture) ->
    FirstNs = unique_ns(<<"discarded">>),
    SecondNs = unique_ns(<<"accepted">>),
    Goal =
        {';',
         {transaction,
          {',', {create_ontology, FirstNs, []}, fail}},
         {create_ontology, SecondNs, []}},
    ?assertMatch({ok, [#{}], _}, quod_prolog:execute(?ROOT_NS, Goal)),
    ok = wait_ready(SecondNs, 300),
    ?assertEqual({ok, not_hosted}, quod_ontology:local_state(FirstNs)),
    ?assertEqual({ok, ready}, quod_ontology:local_state(SecondNs)).

join_uses_the_same_goal_path(_Fixture) ->
    Ns = unique_ns(<<"join">>),
    Create = {create_ontology, Ns,
              [{source, <<"can_invoke(_, _, _, _).\njoined_fact(ok).\n">>}]},
    ?assertMatch({ok, [#{}], _}, quod_prolog:execute(?ROOT_NS, Create)),
    ok = wait_ready(Ns, 300),
    Anchor = quod_simplex:genesis_hash(Ns),
    ok = quod_namespace_manager:stop_content(Ns),
    ?assertEqual({ok, not_hosted}, quod_ontology:local_state(Ns)),
    Join = {join_ontology, Ns, binary:encode_hex(Anchor),
            [{seed, "127.0.0.1", 14567}]},
    ?assertMatch({ok, [#{}], _}, quod_prolog:execute(?NODE_NS, Join)),
    ok = wait_ready(Ns, 300),
    ?assertEqual(Anchor, quod_simplex:genesis_hash(Ns)),
    ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {joined_fact, ok})).

signed_agent_create_uses_the_same_goal_path(_Fixture) ->
    {ok, NetworkId} = quod_ontology:genesis_anchor(?ROOT_NS),
    {ok, NodeKey} = application:get_env(quod, node_pubkey),
    {PublicKey, _} = KeyPair = quod_identity:generate(),
    Agent = provision_agent(PublicKey, true),
    NewNs = unique_ns(<<"signed-agent-created">>),
    Peer = {127, 0, 0, 1},
    {ok, AuthPid} = quod_client_auth:start_link(
                      #{network_id => NetworkId, node_key => NodeKey,
                        max_challenges => 4, max_sessions => 4}),
    unlink(AuthPid),
    try
        #{session_id := SessionId, expires_ms := SessionExpires} =
            open_client_session(NetworkId, NodeKey, KeyPair, Peer),
        GoalText = iolist_to_binary(
                     ["quod:root::create_ontology(\"", NewNs,
                      "\", [])."]),
        {RequestBytes, Signature} = signed_agent_goal(
                                      NetworkId, PublicKey, KeyPair,
                                      Agent, execute, SessionExpires,
                                      GoalText),
        ok = assert_signed_action_result(
               quod_client_goal_ingress:submit(
                 execute, SessionId, RequestBytes, Signature, Peer),
               SessionId, RequestBytes, Signature, Peer),
        ok = wait_ready(NewNs, 300)
    after
        stop_process(AuthPid)
    end.

signed_root_create_obeys_entry_acl(_Fixture) ->
    OpenClause = root_open_invoke_clause(),
    HostEntry = {can_invoke, {'Goal'}, {'Principal'}, [], {'Namespace'}},
    ok = replace_root_invocation_policy([HostEntry]),
    try
        {ok, NetworkId} = quod_ontology:genesis_anchor(?ROOT_NS),
        {ok, NodeKey} = application:get_env(quod, node_pubkey),
        {PublicKey, _} = KeyPair = quod_identity:generate(),
        Agent = provision_agent(PublicKey, true),
        DeniedNs = unique_ns(<<"entry-denied">>),
        Peer = {127, 0, 0, 5},
        {ok, AuthPid} = quod_client_auth:start_link(
                          #{network_id => NetworkId, node_key => NodeKey,
                            max_challenges => 4, max_sessions => 4}),
        unlink(AuthPid),
        try
            #{session_id := SessionId, expires_ms := SessionExpires} =
                open_client_session(NetworkId, NodeKey, KeyPair, Peer),
            GoalText = iolist_to_binary(
                         ["quod:root::create_ontology(\"", DeniedNs,
                          "\", [])."]),
            {RequestBytes, Signature} = signed_agent_goal(
                                          NetworkId, PublicKey, KeyPair,
                                          Agent, execute, SessionExpires,
                                          GoalText),
            {ok, _, {normalized, {failed, ReasonsBlob}}} =
                quod_client_goal_ingress:submit(
                  execute, SessionId, RequestBytes, Signature, Peer),
            {ok, Reasons} = quod_wire_term:decode_failure_reasons(ReasonsBlob),
            ?assert(lists:member({not_allowed, ?ROOT_NS}, Reasons)),
            ?assertEqual({ok, not_hosted}, quod_ontology:local_state(DeniedNs))
        after
            stop_process(AuthPid)
        end
    after
        ok = replace_root_invocation_policy([HostEntry, OpenClause])
    end.

prepared_source_is_used_exactly_once(#{dir := Dir}) ->
    Ns = unique_ns(<<"prepared-once">>),
    SourcePath = filename:join(Dir, "prepared-once.pl"),
    ok = file:write_file(
           SourcePath,
           <<"can_invoke(_, _, _, _).\nprepared_value(original).\n">>),
    Action = {create_ontology, Ns,
              [{source_file, list_to_binary(SourcePath)}]},
    {ok, Structural} = quod_ontology:validate_action(Action),
    {ok, Prepared} = quod_ontology:prepare_action(Structural),
    ok = file:write_file(
           SourcePath,
           <<"can_invoke(_, _, _, _).\nprepared_value(changed).\n">>),
    {ok, created, Ns, _} = quod_ontology:execute_prepared(Prepared),
    ok = wait_ready(Ns, 300),
    ?assertMatch({ok, [#{}], _},
                 quod_prolog:prove_ro(Ns, {prepared_value, original})),
    ?assertMatch({fail, _},
                 quod_prolog:prove_ro(Ns, {prepared_value, changed})).

action_timeout_returns_exact_outcome(#{manager := Manager}) ->
    Ns = unique_ns(<<"action-timeout">>),
    ok = sys:suspend(Manager),
    Result =
        try quod_prolog:execute(?ROOT_NS, {create_ontology, Ns, []})
        after ok = sys:resume(Manager)
        end,
    ?assertMatch(
       {error,
        {outcome_unknown,
         {transaction, ?ROOT_NS, <<_:256>>, <<_:256>>}}},
       Result),
    {error, {outcome_unknown, Ref}} = Result,
    ok = wait_ready(Ns, 300),
    ?assertMatch({ok, #{status := committed}}, quod_prolog:outcome(Ref)),
    ?assertMatch(<<_:256>>, quod_simplex:genesis_hash(Ns)).

%% The namespace-manager mutation may finish immediately before the journal
%% records its terminal row. Recovery must observe the already-satisfied
%% desired state and must not found another incarnation.
effect_completion_survives_journal_restart(#{dir := Dir}) ->
    Ns = unique_ns(<<"journal-restart">>),
    Tag = make_ref(),
    Parent = self(),
    application:set_env(quod, effect_test_after_execute, {Parent, Tag}),
    {Caller, CallerMRef} =
        spawn_monitor(
          fun() ->
              Parent !
                  {journal_restart_result, self(),
                   quod_prolog:execute(
                     ?ROOT_NS, {create_ontology, Ns, []})}
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
        WorkerMRef = monitor(process, Worker),
        receive
            {'DOWN', WorkerMRef, process, Worker, _} -> ok
        after 5000 ->
            error(effect_worker_stop_timeout)
        end,
        {ok, NewJournal} = quod_effect_journal:start_link(#{data_dir => Dir}),
        unlink(NewJournal),
        Result =
            receive
                {journal_restart_result, Caller, ActionResult} -> ActionResult
            after 5000 ->
                error(action_result_timeout)
            end,
        ?assertMatch(
           {error,
            {outcome_unknown,
             {transaction, ?ROOT_NS, <<_:256>>, <<_:256>>}}},
           Result),
        ok = wait_ready(Ns, 300),
        Anchor = quod_simplex:genesis_hash(Ns),
        ?assertMatch(<<_:256>>, Anchor),
        ok = wait_effect_target_state(Ns, applied, 300),
        ?assertEqual(Anchor, quod_simplex:genesis_hash(Ns)),
        receive
            {'DOWN', CallerMRef, process, Caller, normal} -> ok
        after 5000 ->
            error(action_caller_stop_timeout)
        end
    after
        application:unset_env(quod, effect_test_after_execute),
        exit(Caller, kill)
    end.

effect_execution_uses_its_generic_descriptor(_Fixture) ->
    Ns = unique_ns(<<"descriptor-owned-effect">>),
    Create = {create_ontology, Ns, []},
    {ok, Structural} = quod_ontology:validate_action(Create),
    {ok, Prepared} = quod_ontology:prepare_action(Structural),
    {ok, Executor} = application:get_env(quod, node_pubkey),
    AuditLabel = deliberately_unrelated_audit_label,
    Desired = {ontology_hosted, Ns},
    {ok, Effect} = quod_ontology:prepared_effect(
                     AuditLabel, Prepared, Executor, {node, Executor}),
    {ok, GoalBlob} = quod_durable_term:encode_goal(AuditLabel),
    {ok, ResultBlob} = quod_durable_term:encode_result(#{}),
    RootAnchor = quod_simplex:genesis_hash(?ROOT_NS),
    Change = quod_transaction:bind_id(
               {?ROOT_NS, RootAnchor},
               #transaction{origin = {?ROOT_NS, RootAnchor},
                            proof_id = crypto:strong_rand_bytes(32),
                            plan_digest = crypto:strong_rand_bytes(32),
                            goal = GoalBlob, result = ResultBlob,
                            diff = [], read_check = #{}, effects = [Effect],
                            author = Executor}),
    Ref = {transaction, ?ROOT_NS, RootAnchor,
           Change#transaction.tx_id},
    {ok, Reservation} = quod_effect_journal:reserve(self()),
    ok = quod_effect_journal:stage(
           Reservation, AuditLabel, Desired, Effect, Prepared),
    ok = quod_effect_journal:bind_transaction(Effect, Change, Ref),
    quod_effect_journal:release_applied(2, [Effect]),
    ok = wait_ready(Ns, 300),
    ok = wait_effect_target_state(Ns, applied, 300),
    ?assertMatch({ok, #{state := applied, result := ok}},
                 quod_effect_journal:status(quod_effect:effect_id(Effect))).

stopped_ontology_resumes_same_anchor(_Fixture) ->
    Ns = unique_ns(<<"resume-anchor">>),
    Action = {create_ontology, Ns, []},
    ?assertMatch({ok, [#{}], _}, quod_prolog:execute(?ROOT_NS, Action)),
    ok = wait_ready(Ns, 300),
    Anchor = quod_simplex:genesis_hash(Ns),
    ?assertMatch(<<_:256>>, Anchor),
    ok = quod_namespace_manager:stop_content(Ns),
    ?assertEqual({ok, not_hosted}, quod_ontology:local_state(Ns)),
    ?assertMatch({ok, [#{}], _}, quod_prolog:execute(?ROOT_NS, Action)),
    ok = wait_ready(Ns, 300),
    ?assertEqual(Anchor, quod_simplex:genesis_hash(Ns)).

wrong_anchor_is_not_a_satisfied_effect(_Fixture) ->
    Ns = unique_ns(<<"wrong-anchor">>),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:execute(?ROOT_NS, {create_ontology, Ns, []})),
    ok = wait_ready(Ns, 300),
    Actual = quod_simplex:genesis_hash(Ns),
    <<First, Rest/binary>> = Actual,
    Wrong = <<(First bxor 1), Rest/binary>>,
    {ok, Executor} = application:get_env(quod, node_pubkey),
    Effect =
        {quod_direct_effect, 2, local_durable,
         ontology_lifecycle, create,
         crypto:hash(sha256, <<"wrong-anchor-effect">>), Executor,
         {node, Executor}, {Ns, Wrong},
         crypto:hash(sha256, <<"wrong-anchor-request">>),
         crypto:hash(sha256, <<"wrong-anchor-prepared">>)},
    ?assertEqual(
       incompatible,
       quod_effect_journal:test_desired_state(
         ?ROOT_NS, {ontology_hosted, Ns}, Effect)).

structural_validation_is_total(_Fixture) ->
    ?assertEqual({error, invalid_action},
                 quod_ontology:validate_action({unknown, value})),
    ?assertEqual({error, invalid_arguments},
                 quod_ontology:validate_action(
                   {create_ontology, {'Name'}, []})),
    ?assertEqual({error, invalid_name},
                 quod_ontology:validate_action(
                   {create_ontology, <<>>, []})),
    ?assertEqual({error, invalid_options},
                 quod_ontology:validate_action(
                   {create_ontology, <<"valid:name">>, malformed})),
    ?assertEqual({error, invalid_genesis_hash},
                 quod_ontology:validate_action(
                   {join_ontology, <<"valid:name">>, <<"bad">>,
                    [{seed, "127.0.0.1", 14567}]})),
    ?assertEqual({error, invalid_seeds},
                 quod_ontology:validate_action(
                   {join_ontology, <<"valid:name">>,
                    binary:encode_hex(crypto:strong_rand_bytes(32)), []})).

current_principal_is_engine_owned(_Fixture) ->
    {ok, NodeKey} = application:get_env(quod, node_pubkey),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove_ro(?NODE_NS,
                           {current_principal, {node, NodeKey}})),
    ?assertMatch(
       {fail, _},
       quod_prolog:prove_ro(
         ?ROOT_NS,
         {current_principal, {node, crypto:strong_rand_bytes(32)}})).

internal_staging_continuation_cannot_be_forged(_Fixture) ->
    Ns = unique_ns(<<"forged-continuation">>),
    Goal = {'$quod_stage_ontology', forged_handle,
            {create_ontology, Ns, []}, {ontology_hosted, Ns}},
    {fail, Reasons} = quod_prolog:execute(?ROOT_NS, Goal),
    ?assertEqual({ontology_creation_failed, invalid_action},
                 lists:last(Reasons)),
    ?assertEqual({ok, not_hosted}, quod_ontology:local_state(Ns)).

foreign_prerequisite_uses_normal_scope_boundary(_Fixture) ->
    ForeignNs = unique_ns(<<"foreign-prerequisite">>),
    {ok, created, ForeignNs, _} =
        quod_ontology:create(
          ForeignNs,
          [{source,
            <<"can_invoke(_, _, _, _).\n"
              "lifecycle_ready(yes).\n">>}]),
    ok = wait_ready(ForeignNs, 300),
    Original = root_creation_action(),
    {action, Transition, Prerequisites, Desired} = Original,
    ForeignCheck = {'::', ForeignNs, {lifecycle_ready, yes}},
    Modified = {action, Transition,
                Prerequisites ++ [ForeignCheck], Desired},
    ok = commit_root({',', {retract, Original}, {asserta, Modified}}),
    TargetNs = unique_ns(<<"effect-with-foreign-read">>),
    try
        {ok, [#{}],
         #{ref := GroupRef, participant_slots := ParticipantSlots}} =
            quod_prolog:execute(
              ?ROOT_NS, {create_ontology, TargetNs, []}),
        ?assertMatch({group, _, _, _, _, _}, GroupRef),
        ?assertEqual(2, length(ParticipantSlots)),
        ok = wait_ready(TargetNs, 300),
        ok = wait_effect_target_state(TargetNs, applied, 300),
        ?assertMatch(
           [#{state := applied,
              ref := {group_effect, 1, GroupRef, _, _}}],
           [Row || #{target := {RowNs, _}} = Row <-
                       quod_effect_journal:rows(),
                   RowNs =:= TargetNs])
    after
        ok = commit_root(
               {',', {retract, Modified}, {assertz, Original}})
    end.

foreign_prerequisite_failure_keeps_its_reason(_Fixture) ->
    ForeignNs = unique_ns(<<"foreign-prerequisite-failure">>),
    {ok, created, ForeignNs, _} =
        quod_ontology:create(
          ForeignNs,
          [{source,
            <<"can_invoke(_, _, _, _).\n"
              "lifecycle_ready(yes) :- "
              "fail_with_reason(remote_lifecycle_denied).\n">>}]),
    ok = wait_ready(ForeignNs, 300),
    Original = root_creation_action(),
    {action, Transition, Prerequisites, Desired} = Original,
    Modified =
        {action, Transition,
         Prerequisites ++
             [{'::', ForeignNs, {lifecycle_ready, yes}}],
         Desired},
    ok = commit_root({',', {retract, Original}, {asserta, Modified}}),
    TargetNs = unique_ns(<<"effect-with-refused-foreign-read">>),
    BeforeRows = quod_effect_journal:rows(),
    BeforeHeight = maps:get(committed, quod_simplex:stats(?ROOT_NS)),
    try
        {fail, Reasons} = quod_prolog:execute(
                            ?ROOT_NS,
                            {create_ontology, TargetNs, []}),
        ?assert(lists:member(remote_lifecycle_denied, Reasons)),
        ?assertEqual(BeforeRows, quod_effect_journal:rows()),
        ?assertEqual(BeforeHeight,
                     maps:get(committed, quod_simplex:stats(?ROOT_NS))),
        ?assertEqual({ok, not_hosted},
                     quod_ontology:local_state(TargetNs))
    after
        ok = commit_root(
               {',', {retract, Modified}, {assertz, Original}})
    end.

agent_is_gated_by_root_creation_policy(_Fixture) ->
    {ok, NetworkId} = quod_ontology:genesis_anchor(?ROOT_NS),
    {ok, NodeKey} = application:get_env(quod, node_pubkey),
    {PublicKey, _} = KeyPair = quod_identity:generate(),
    Agent = provision_agent(PublicKey, false),
    AgentRef = maps:get(reference, Agent),
    DeniedNs = unique_ns(<<"denied-agent">>),
    Peer = {127, 0, 0, 2},
    {ok, AuthPid} = quod_client_auth:start_link(
                      #{network_id => NetworkId, node_key => NodeKey,
                        max_challenges => 4, max_sessions => 4}),
    unlink(AuthPid),
    try
        #{session_id := SessionId, expires_ms := SessionExpires} =
            open_client_session(NetworkId, NodeKey, KeyPair, Peer),
        GoalText = iolist_to_binary(
                     ["quod:root::create_ontology(\"", DeniedNs,
                      "\", [])."]),
        {RequestBytes, Signature} = signed_agent_goal(
                                      NetworkId, PublicKey, KeyPair,
                                      Agent, execute, SessionExpires,
                                      GoalText),
        {ok, _, {normalized, {failed, ReasonsBlob}}} =
            quod_client_goal_ingress:submit(
              execute, SessionId, RequestBytes, Signature, Peer),
        {ok, Reasons} = quod_wire_term:decode_failure_reasons(ReasonsBlob),
        ?assert(
           lists:any(
             fun({can_create_ontology, Ref, _, _})
                   when Ref =:= AgentRef -> true;
                (_) -> false
             end, Reasons))
    after
        stop_process(AuthPid)
    end.

node_does_not_own_generic_creation_policy(_Fixture) ->
    Ns = unique_ns(<<"wrong-owner">>),
    {fail, Reasons} =
        quod_prolog:execute(?NODE_NS, {create_ontology, Ns, []}),
    ?assertEqual({ontology_creation_failed, wrong_ontology},
                 lists:last(Reasons)),
    ?assertEqual({ok, not_hosted}, quod_ontology:local_state(Ns)).

invalid_create_never_reaches_hosting(_Fixture) ->
    BadNs = <<>>,
    {fail, Reasons} =
        quod_prolog:execute(?ROOT_NS, {create_ontology, BadNs, []}),
    ?assertEqual({ontology_creation_failed, invalid_name},
                 lists:last(Reasons)),
    ?assertEqual({error, invalid_name}, quod_ontology:local_state(BadNs)),
    {fail, VariableReasons} =
        quod_prolog:execute(
          ?ROOT_NS, {create_ontology, {'Namespace'}, []}),
    ?assertEqual({ontology_creation_failed, invalid_arguments},
                 lists:last(VariableReasons)).

reserved_initial_terms_never_reach_hosting(#{dir := Dir}) ->
    ReservedTerms =
        [{consensus_incarnation, forged},
         {peer_admitted, <<0:256>>, "127.0.0.1", 14567, <<0:256>>},
         {external_predicate_modules, [quod_ontology_predicates]}],
    lists:foreach(
      fun(Term) ->
          Ns = unique_ns(<<"reserved-genesis">>),
          ?assertEqual(
             {error, {invalid_initial_term, Term}},
             quod_ontology:create(Ns, [{terms, [Term]}])),
          ?assertEqual({ok, not_hosted}, quod_ontology:local_state(Ns)),
          ?assertNot(filelib:is_dir(quod_ledger_store:ns_dir(Dir, Ns)))
      end, ReservedTerms),
    InlineNs = unique_ns(<<"reserved-inline">>),
    ?assertMatch(
       {error, {invalid_initial_term, _}},
       quod_ontology:create(
         InlineNs, [{source, <<"consensus_incarnation(forged).">>}])),
    ?assertEqual({ok, not_hosted}, quod_ontology:local_state(InlineNs)).

collisions_preserve_existing_state(_Fixture) ->
    Ns = unique_ns(<<"collision">>),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:execute(
         ?ROOT_NS,
         {create_ontology, Ns,
          [{source,
            <<"can_invoke(_, _, _, _).\nkept(true).\n">>}]})),
    ok = wait_ready(Ns, 300),
    Pid0 = quod_reg:where({quod_ns, Ns}),
    Desired0 = application:get_env(quod, namespace_desired, #{}),
    ?assertEqual(
       {error, {already_configured, Ns}},
       quod_ontology:create(Ns, [{terms, [{replacement, forbidden}]}])),
    ?assertEqual(Pid0, quod_reg:where({quod_ns, Ns})),
    ?assert(is_process_alive(Pid0)),
    ?assertEqual(Desired0,
                 application:get_env(quod, namespace_desired, #{})),
    ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {kept, true})),
    ?assertMatch({fail, _},
                 quod_prolog:prove_ro(Ns, {replacement, forbidden})).

failed_admission_rolls_back(#{dir := Dir, manager := Manager}) ->
    Ns = unique_ns(<<"failed-start">>),
    Desired0 = application:get_env(quod, namespace_desired, #{}),
    ?assertMatch(
       {error, _},
       quod_namespace_manager:start_new_content(Ns, #{data_dir => Dir})),
    ?assertEqual(Desired0,
                 application:get_env(quod, namespace_desired, #{})),
    ?assertEqual(undefined, quod_reg:where({quod_ns, Ns})),
    %% A rejected admission must not leave a retry timer pretending the
    %% namespace entered the desired set.
    ?assertEqual(undefined, element(7, sys:get_state(Manager))),

    OrphanNs = unique_ns(<<"orphan">>),
    Parent = self(),
    Orphan = spawn(
               fun() ->
                   true = gproc:reg({n, l, {quod_ns, OrphanNs}}),
                   Parent ! {orphan_ready, self()},
                   receive stop -> ok end
               end),
    receive {orphan_ready, Orphan} -> ok
    after 1000 -> error(orphan_timeout)
    end,
    try
        ?assertEqual(
           {error, {already_configured, OrphanNs}},
           quod_namespace_manager:start_new_content(
             OrphanNs, #{data_dir => Dir})),
        ?assertEqual(Desired0,
                     application:get_env(quod, namespace_desired, #{})),
        ?assert(is_process_alive(Orphan))
    after
        Orphan ! stop
    end.

failed_root_policy_does_not_read_or_stage(_Fixture) ->
    %% Root's entry ACL is currently open, while can_create_ontology/3 still
    %% requires an exact durable creator-agent grant.
    {ok, NetworkId} = quod_ontology:genesis_anchor(?ROOT_NS),
    {ok, NodeKey} = application:get_env(quod, node_pubkey),
    {PublicKey, _} = KeyPair = quod_identity:generate(),
    Agent = provision_agent(PublicKey, false),
    AgentRef = maps:get(reference, Agent),
    Peer = {127, 0, 0, 3},
    {ok, AuthPid} = quod_client_auth:start_link(
                      #{network_id => NetworkId, node_key => NodeKey,
                        max_challenges => 4, max_sessions => 4}),
    unlink(AuthPid),
    Ns = unique_ns(<<"policy-denied-before-source">>),
    Missing = <<"/this/path/must/not/be/read.pl">>,
    BeforeHeight = maps:get(committed, quod_simplex:stats(?ROOT_NS)),
    BeforeRows = quod_effect_journal:rows(),
    try
        #{session_id := SessionId, expires_ms := SessionExpires} =
            open_client_session(NetworkId, NodeKey, KeyPair, Peer),
        Goal = iolist_to_binary(
                 ["create_ontology(\"", Ns,
                  "\", [source_file(\"", Missing, "\")])."]),
        RoutedGoal = <<"quod:root::", Goal/binary>>,
        {RequestBytes, Signature} = signed_agent_goal(
                                      NetworkId, PublicKey, KeyPair,
                                      Agent, execute, SessionExpires,
                                      RoutedGoal),
        {ok, _, {normalized, {failed, ReasonsBlob}}} =
            quod_client_goal_ingress:submit(
              execute, SessionId, RequestBytes, Signature, Peer),
        {ok, Reasons} = quod_wire_term:decode_failure_reasons(ReasonsBlob),
        ?assert(
           lists:any(
             fun({can_create_ontology, Ref, _, _})
                   when Ref =:= AgentRef -> true;
                (_) -> false
             end, Reasons)),
        ?assertNot(
           lists:any(
             fun({ontology_creation_failed, {source_file_error, _}}) -> true;
                (_) -> false
             end, Reasons)),
        ?assertEqual(BeforeHeight,
                     maps:get(committed, quod_simplex:stats(?ROOT_NS))),
        ?assertEqual(BeforeRows, quod_effect_journal:rows()),
        ?assertEqual({ok, not_hosted}, quod_ontology:local_state(Ns))
    after
        stop_process(AuthPid)
    end.

committed_agent_approval_uses_the_same_action(_Fixture) ->
    {ok, NetworkId} = quod_ontology:genesis_anchor(?ROOT_NS),
    {ok, NodeKey} = application:get_env(quod, node_pubkey),
    {PublicKey, _} = KeyPair = quod_identity:generate(),
    Agent = provision_agent(PublicKey, false),
    AgentRef = maps:get(reference, Agent),
    Ns = unique_ns(<<"locally-approved-user">>),
    ok = commit_root({assertz, {ontology_creator_agent, AgentRef}}),
    Peer = {127, 0, 0, 4},
    {ok, AuthPid} = quod_client_auth:start_link(
                      #{network_id => NetworkId, node_key => NodeKey,
                        max_challenges => 4, max_sessions => 4}),
    unlink(AuthPid),
    try
        #{session_id := SessionId, expires_ms := SessionExpires} =
            open_client_session(NetworkId, NodeKey, KeyPair, Peer),
        Goal = iolist_to_binary(
                 ["create_ontology(\"", Ns,
                  "\", [source(\"can_invoke(_, _, _, _)."
                  "\\napproved(ok).\\n\")])."]),
        RoutedGoal = <<"quod:root::", Goal/binary>>,
        {RequestBytes, Signature} = signed_agent_goal(
                                      NetworkId, PublicKey, KeyPair,
                                      Agent, execute, SessionExpires,
                                      RoutedGoal),
        ok = assert_signed_action_result(
               quod_client_goal_ingress:submit(
                 execute, SessionId, RequestBytes, Signature, Peer),
               SessionId, RequestBytes, Signature, Peer),
        ok = wait_ready(Ns, 300),
        ?assertMatch({ok, [#{}], _},
                     quod_prolog:prove_ro(Ns, {approved, ok}))
    after
        stop_process(AuthPid)
    end.

false_postcondition_is_reported(_Fixture) ->
    Original = root_creation_action(),
    {action,
     {'$quod_stage_ontology', Handle,
      {create_ontology, Name, Options}, _OriginalDesired},
     Prerequisites, _Desired} = Original,
    FalseDesired = {never_reached, Name},
    Modified =
        {action,
         {'$quod_stage_ontology', Handle,
          {create_ontology, Name, Options}, FalseDesired},
         Prerequisites, FalseDesired},
    ok = commit_root({',', {retract, Original}, {asserta, Modified}}),
    Ns = unique_ns(<<"false-postcondition">>),
    try
        ?assertEqual(
           {error, {operator_error, postcondition_failed}},
           quod_prolog:execute(?ROOT_NS, {create_ontology, Ns, []})),
        ok = wait_ready(Ns, 300),
        ?assertEqual({ok, ready}, quod_ontology:local_state(Ns))
    after
        ok = commit_root(
               {',', {retract, Modified}, {assertz, Original}})
    end.

reconcile_republishes_running_content(#{manager := Manager}) ->
    Ns = unique_ns(<<"reconcile-publish">>),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:execute(?ROOT_NS, {create_ontology, Ns, []})),
    ok = wait_ready(Ns, 300),
    Config = desired_content(Ns),
    ExpectedDirs = #{data => quod_ledger_store:data_dir(Config),
                     ledger => quod_ledger_store:ledger_dir(Config)},
    application:set_env(quod, content_storage_dirs, #{}),
    Manager ! reconcile,
    ok = wait_storage_dirs(Ns, ExpectedDirs, 300).

dynamic_hosting_survives_content_tree_restart(
  #{manager := Manager, ns_sup := NsSup}) ->
    Ns = unique_ns(<<"tree-restart">>),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:execute(?ROOT_NS, {create_ontology, Ns, []})),
    ok = wait_ready(Ns, 300),
    Anchor = quod_simplex:genesis_hash(Ns),
    RootAnchor = quod_simplex:genesis_hash(?ROOT_NS),

    stop_process(Manager),
    stop_process(NsSup),
    application:set_env(
      quod, namespace_desired, #{content => #{}, brahms => #{}}),
    application:set_env(quod, content_storage_dirs, #{}),
    {ok, NewNsSup} = quod_ns_sup:start_link(),
    unlink(NewNsSup),
    {ok, NewManager} = quod_namespace_manager:start_link(),
    unlink(NewManager),
    ok = wait_ready(?ROOT_NS, 300),
    ok = wait_ready(Ns, 300),
    ?assertEqual(RootAnchor, quod_simplex:genesis_hash(?ROOT_NS)),
    ?assertEqual(Anchor, quod_simplex:genesis_hash(Ns)),
    ?assertEqual({ok, ready}, quod_ontology:local_state(Ns)),
    Config = desired_content(Ns),
    ?assertEqual(Anchor, maps:get(genesis_hash, Config)),
    ?assertNot(maps:is_key(prepared_genesis_entry, Config)),
    ?assertNot(maps:is_key(genesis_diff, Config)),
    ok = wait_effect_capacity(64, 300).

commit_root(Goal) ->
    ?assertMatch({ok, [_ | _], _}, quod_prolog:execute(?ROOT_NS, Goal)),
    ok.

root_creation_action() ->
    File = filename:join(code:priv_dir(quod), "ontologies/quod_root.pl"),
    [Declaration] =
        [Term || {action,
                  {'$quod_stage_ontology', _, {create_ontology, _, _}, _},
                  _, _} = Term <- quod_prolog:read_terms(File)],
    Declaration.

root_open_invoke_clause() ->
    File = filename:join(code:priv_dir(quod), "ontologies/quod_root.pl"),
    [Clause] =
        [Term || {can_invoke, _, _, _, _} = Term <-
                     quod_prolog:read_terms(File)],
    Clause.

replace_root_invocation_policy(Clauses) ->
    Assertions = [{assertz, Clause} || Clause <- Clauses],
    Goal = lists:foldr(
             fun(Assertion, Tail) -> {',', Assertion, Tail} end,
             true, Assertions),
    commit_root(
      {',', {abolish, {'/', can_invoke, 4}}, Goal}).

open_client_session(NetworkId, NodeKey,
                    KeyPair = {PublicKey, _Seed}, Peer) ->
    LoginNonce = crypto:strong_rand_bytes(32),
    {ok, Challenge} =
        quod_client_auth:issue_challenge(PublicKey, LoginNonce, Peer),
    ChallengeId = maps:get(challenge_id, Challenge),
    {ok, ChallengeBytes} = quod_client_auth:challenge_bytes(
                             NetworkId, NodeKey, ChallengeId, PublicKey,
                             LoginNonce, maps:get(server_nonce, Challenge),
                             maps:get(expires_ms, Challenge)),
    LoginSignature = quod_identity:sign(
                       ChallengeBytes, quod_identity:key_term(KeyPair)),
    {ok, Session} =
        quod_client_auth:complete_challenge(ChallengeId, LoginSignature),
    Session.

signed_agent_goal(NetworkId, PublicKey, KeyPair,
                  #{namespace := AgentNs, anchor := AgentAnchor,
                    instance_text := InstanceText},
                  Mode, SessionExpires, GoalText) ->
    Request = #{network_identity => NetworkId,
                signing_public_key => PublicKey,
                operation_id => crypto:strong_rand_bytes(32),
                agent_namespace => AgentNs,
                agent_genesis_anchor => AgentAnchor,
                agent_instance_text => InstanceText,
                mode => Mode,
                parser_version => 1,
                not_after_ms => min(SessionExpires,
                                    quod_time:now_ms() + 30000),
                goal_text => GoalText},
    {ok, RequestBytes} = quod_client_goal:encode(Request),
    {RequestBytes,
     quod_identity:sign(RequestBytes, quod_identity:key_term(KeyPair))}.

assert_signed_action_result(
  {ok, _, {normalized, {committed, [_],
                        {transaction, ?ROOT_NS, _, _}}}},
  _SessionId, _RequestBytes, _Signature, _Peer) ->
    ok;
assert_signed_action_result(
  {ok, _, {normalized,
           {pending, {operation, _, _, _, _}}}},
  SessionId, RequestBytes, Signature, Peer) ->
    wait_operation_result(SessionId, RequestBytes, Signature, Peer, 300);
assert_signed_action_result(
  {ok, _, {normalized, {failed, FailureBlob}}},
  _SessionId, _RequestBytes, _Signature, _Peer) ->
    {ok, FailureReasons} =
        quod_wire_term:decode_failure_reasons(FailureBlob),
    error({unexpected_signed_action_failure, FailureReasons});
assert_signed_action_result(
  Other, _SessionId, _RequestBytes, _Signature, _Peer) ->
    error({unexpected_signed_action_reply, Other}).

wait_operation_result(_SessionId, _RequestBytes, _Signature, _Peer, 0) ->
    error(operation_resolution_timeout);
wait_operation_result(SessionId, RequestBytes, Signature, Peer, Left) ->
    case quod_client_goal_ingress:resolve_operation(
           SessionId, RequestBytes, Signature, Peer) of
        {ok, _, {operation_outcome, _, _}} -> ok;
        {ok, _, {operation_pending, _}} ->
            receive after 10 -> ok end,
            wait_operation_result(
              SessionId, RequestBytes, Signature, Peer, Left - 1);
        Other ->
            error({unexpected_operation_resolution, Other})
    end.

provision_agent(PublicKey, GrantCreation) ->
    AgentNs = unique_ns(<<"agent">>),
    InstanceText = iolist_to_binary(
                     io_lib:format("human_user(~B).", [
                       erlang:unique_integer([positive])])),
    {ok, #{goal := Instance, variables := []}} =
        quod_client_goal_parser:parse(InstanceText, 1),
    InstanceSource = binary:part(InstanceText, 0, byte_size(InstanceText) - 1),
    NamespaceSource = prolog_binary_literal(AgentNs),
    KeySource = prolog_binary_literal(PublicKey),
    InitialSource =
        binary_to_list(
          iolist_to_binary(
            ["agent_key(", InstanceSource, ", ", KeySource,
             ", active).\ncan_invoke(_, agent_instance_ref(",
             NamespaceSource, ", _, ", InstanceSource, "), _, ",
             NamespaceSource, ").\n"])),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:execute(
         ?ROOT_NS,
         {create_ontology, AgentNs,
          [{source, InitialSource}]})),
    ok = wait_ready(AgentNs, 300),
    AgentAnchor = quod_simplex:genesis_hash(AgentNs),
    {ok, #{blob := AgentRefBlob}} =
        quod_agent_ref:from_text(AgentNs, AgentAnchor, InstanceText, 1),
    {ok, AgentRef} = quod_agent_ref:materialize(AgentRefBlob),
    case GrantCreation of
        true -> commit_root({assertz, {ontology_creator_agent, AgentRef}});
        false -> ok
    end,
    #{namespace => AgentNs, anchor => AgentAnchor,
      instance_text => InstanceText, reference => AgentRef,
      instance => Instance}.

prolog_binary_literal(Bytes) ->
    iolist_to_binary(
      ["<<\"",
       [["\\x", io_lib:format("~2.16.0B", [Byte]), "\\"]
        || <<Byte>> <= Bytes],
       "\">>"]).

desired_content(Ns) ->
    Desired = application:get_env(
                quod, namespace_desired,
                #{content => #{}, brahms => #{}}),
    maps:get(Ns, maps:get(content, Desired)).

wait_ready(_Ns, 0) -> error(namespace_not_ready);
wait_ready(Ns, N) ->
    case quod_prolog:prove_ro(Ns, true) of
        {ok, _, _} -> ok;
        _ -> receive after 10 -> wait_ready(Ns, N - 1) end
    end.

wait_effect_target_state(_Ns, _Expected, 0) ->
    error(effect_state_timeout);
wait_effect_target_state(Ns, Expected, N) ->
    case [State || #{target := {RowNs, _}, state := State} <-
                       quod_effect_journal:rows(),
                   RowNs =:= Ns] of
        [Expected] -> ok;
        _ -> receive after 10 ->
                 wait_effect_target_state(Ns, Expected, N - 1)
             end
    end.

wait_effect_capacity(_Expected, 0) ->
    error(effect_capacity_timeout);
wait_effect_capacity(Expected, N) ->
    case quod_effect_journal:capacity() of
        Expected -> ok;
        _ -> receive after 10 ->
                 wait_effect_capacity(Expected, N - 1)
             end
    end.

wait_storage_dirs(_Ns, _Expected, 0) ->
    error(storage_dirs_timeout);
wait_storage_dirs(Ns, Expected, N) ->
    Dirs = application:get_env(quod, content_storage_dirs, #{}),
    case maps:get(Ns, Dirs, undefined) of
        Expected -> ok;
        _ -> receive after 10 ->
                 wait_storage_dirs(Ns, Expected, N - 1)
             end
    end.

unique_ns(Prefix) ->
    <<Prefix/binary, "-", (integer_to_binary(
                            erlang:unique_integer([positive])))/binary>>.

stop_process(Pid) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> gen_server:stop(Pid, shutdown, 3000);
        false -> ok
    end;
stop_process(_) -> ok.

save_env(Keys) ->
    [{Key, application:get_env(quod, Key)} || Key <- Keys].

restore_env(Saved) ->
    lists:foreach(
      fun({Key, {ok, Value}}) -> application:set_env(quod, Key, Value);
         ({Key, undefined}) -> application:unset_env(quod, Key)
      end, Saved).
