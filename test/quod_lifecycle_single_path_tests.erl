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
          {timeout, 30, ?_test(node_actor_uses_ordinary_creation(Fixture))},
          {timeout, 30, ?_test(signed_agent_create_uses_the_same_goal_path(Fixture))},
          {timeout, 60, ?_test(create_and_host_is_one_ordinary_goal(Fixture))},
          {timeout, 30, ?_test(signed_root_create_obeys_entry_acl(Fixture))},
          {timeout, 30, ?_test(prepared_source_is_used_exactly_once(Fixture))},
          {timeout, 30, ?_test(prepared_genesis_survives_journal_restart(Fixture))},
          {timeout, 30, ?_test(malformed_present_prepared_genesis_fails_closed(Fixture))},
          {timeout, 30, ?_test(action_timeout_returns_exact_outcome(Fixture))},
          {timeout, 30, ?_test(effect_completion_survives_journal_restart(Fixture))},
          {timeout, 30, ?_test(effect_execution_uses_its_generic_descriptor(Fixture))},
          {timeout, 30, ?_test(stopped_ontology_resumes_same_anchor(Fixture))},
          ?_test(wrong_anchor_is_not_a_satisfied_effect(Fixture)),
          ?_test(ordinary_static_config_is_not_authority(Fixture)),
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
          ?_test(aborted_hosting_fact_changes_nothing(Fixture)),
          ?_test(retracted_hosting_fact_removes_restart_intent(Fixture)),
          {timeout, 30,
           ?_test(parked_hosting_starts_on_exact_directory_route(Fixture))},
          {timeout, 30,
           ?_test(dynamic_hosting_survives_content_tree_restart(Fixture))},
          {timeout, 30,
           ?_test(wrong_anchor_child_stops_then_exact_material_restarts(Fixture))},
          ?_test(obsolete_desired_file_has_no_authority(Fixture)),
          ?_test(parked_hosting_is_exact_event_driven_and_unsubscribes(Fixture)),
          ?_test(catalogue_worker_failures_are_terminal_owner_failures(Fixture))]
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
              [node_pubkey, identity_key, identity_dir, content_data_dir,
               node_actor_principal, node_addr,
               namespace_desired, namespace_static_content,
               content_storage_dirs]),
    {Pub, Seed} = quod_identity:generate(),
    application:set_env(quod, node_pubkey, Pub),
    application:set_env(
      quod, identity_key, quod_identity:key_term({Pub, Seed})),
    application:set_env(quod, identity_dir, Dir),
    application:set_env(quod, content_data_dir, Dir),
    application:set_env(quod, node_addr, {"127.0.0.1", 14567}),
    application:set_env(
      quod, namespace_desired, #{content => #{}, brahms => #{}}),
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
    RootBlock =
        #{namespace => ?ROOT_NS, mode => create,
          genesis_file => <<"ontologies/quod_root.pl">>,
          data_dir => list_to_binary(Dir), seeds => []},
    {?ROOT_NS, RootConfig0} = quod_app:build_ns_config(RootBlock),
    RootConfig = RootConfig0#{proof_timeout_ms => 5000},
    application:set_env(
      quod, namespace_static_content, #{?ROOT_NS => RootConfig}),
    {ok, Manager} = quod_namespace_manager:start_link(),
    unlink(Manager),
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
    ActorNs = unique_ns(<<"node-actor">>),
    ActorInstanceText = <<"physical_node(primary).">>,
    {ok, ActorOptions} = quod_node_actor:creation_options(
                           ActorNs, ActorInstanceText, 2, Pub),
    {ok, [#{'ActorAnchor' := CreatedActorAnchor}], _} = quod_prolog:execute(
                       ?ROOT_NS,
                       {create_ontology, ActorNs, ActorOptions,
                        {'ActorAnchor'}}),
    ok = wait_ready(ActorNs, 300),
    ActorAnchor = quod_simplex:genesis_hash(ActorNs),
    ?assertEqual(ActorAnchor, CreatedActorAnchor),
    {ok, ActorPrincipal} = quod_node_actor:bind(
                             ActorNs, ActorAnchor, ActorInstanceText, 2),
    ok = wait_node_actor_principal(ActorPrincipal, 300),
    #{dir => Dir, saved => Saved, manager => Manager,
      ns_sup => NsSup, brahms_sup => BrahmsSup, journal => Journal,
      router => Router, foreign_log => ForeignLog,
      root_config => RootConfig, actor_ns => ActorNs,
      actor_anchor => ActorAnchor, actor_principal => ActorPrincipal,
      actor_instance_text => ActorInstanceText,
      actor_keypair => {Pub, Seed}}.

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
             "hello(world).\n">>}], {'_'}},
    {ok, [#{}], Height} = quod_prolog:execute(?ROOT_NS, Goal),
    ok = wait_ready(Ns, 300),
    ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {hello, world})),
    {ok, Store} = quod_ledger_store:open_ro(
                    ?ROOT_NS, quod_ledger_store:ledger_dir(RootConfig)),
    try
        {ok, Entry} = quod_ledger_store:read_at(Store, Height),
        #entry{data = {batch, Transactions}} = quod_ledger:entry_view(Entry),
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
    Goal = create_goal(Ns, []),
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
          {',', create_goal(FirstNs, []), fail}},
         create_goal(SecondNs, [])},
    ?assertMatch({ok, [#{}], _}, quod_prolog:execute(?ROOT_NS, Goal)),
    ok = wait_ready(SecondNs, 300),
    ?assertEqual({ok, not_hosted}, quod_ontology:local_state(FirstNs)),
    ?assertEqual({ok, ready}, quod_ontology:local_state(SecondNs)).

join_uses_the_same_goal_path(_Fixture) ->
    Ns = unique_ns(<<"join">>),
    Create = create_goal(
               Ns,
               [{source, <<"can_invoke(_, _, _, _).\njoined_fact(ok).\n">>}]),
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

node_actor_uses_ordinary_creation(
  #{actor_ns := Ns, actor_anchor := Anchor,
    actor_principal := Principal, actor_instance_text := InstanceText,
    manager := Manager}) ->
    {ok, PublicKey} = application:get_env(quod, node_pubkey),
    ?assertEqual({ok, Principal}, quod_node_actor:principal()),
    Manager ! reconcile,
    ok = wait_manager_idle(Manager, 300),
    ?assertEqual({ok, Principal}, quod_node_actor:principal()),
    Blob = element(2, Principal),
    ?assertEqual({ok, Principal}, quod_node_actor:verify(Blob, PublicKey)),
    ?assertEqual(
       {error, node_actor_active_key_mismatch},
       quod_node_actor:verify(Blob, <<99:256>>)),
    {ok, WrongAnchorBlob} = quod_node_actor:reference(
                              Ns, <<0:256>>, InstanceText, 2),
    ?assertEqual(
       {error, node_actor_anchor_mismatch},
       quod_node_actor:verify(WrongAnchorBlob, PublicKey)),
    {ok, WrongInstanceBlob} = quod_node_actor:reference(
                                Ns, Anchor,
                                <<"physical_node(other).">>, 2),
    ?assertEqual(
       {error, node_actor_instance_mismatch},
       quod_node_actor:verify(WrongInstanceBlob, PublicKey)),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:prove_ro(
         Ns, {instance_of, node, {physical_node, primary}})),
    Instance = {physical_node, primary},
    OtherInstance = {physical_node, duplicate},
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:execute(
         Ns, {assertz, {instance_of, node, OtherInstance}})),
    ?assertEqual(
       {error, node_actor_instance_mismatch},
       quod_node_actor:verify(Blob, PublicKey)),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:execute(
         Ns, {retract, {instance_of, node, OtherInstance}})),
    RotatedKey = <<42:256>>,
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:execute(
         Ns, {retract, {agent_key, Instance, PublicKey, active}})),
    ?assertEqual(
       {error, node_actor_inactive_key},
       quod_node_actor:verify(Blob, PublicKey)),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:execute(
         Ns, {assertz, {agent_key, Instance, RotatedKey, active}})),
    ?assertEqual(
       {error, node_actor_active_key_mismatch},
       quod_node_actor:verify(Blob, PublicKey)),
    ?assertEqual({ok, Principal}, quod_node_actor:verify(Blob, RotatedKey)),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:execute(
         Ns,
         {',',
          {retract, {agent_key, Instance, RotatedKey, active}},
          {assertz, {agent_key, Instance, PublicKey, active}}})).

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
                      "\", [], _)."]),
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

create_and_host_is_one_ordinary_goal(
  #{actor_ns := ActorNs, actor_anchor := ActorAnchor,
    actor_instance_text := InstanceText,
    actor_keypair := {PublicKey, _} = KeyPair,
    actor_principal := Principal}) ->
    {ok, NetworkId} = quod_ontology:genesis_anchor(?ROOT_NS),
    {ok, NodeKey} = application:get_env(quod, node_pubkey),
    {ok, NodeRef} = quod_agent_ref:materialize_principal(Principal),
    NewNs = unique_ns(<<"composed-created">>),
    Peer = {127, 0, 0, 7},
    {ok, AuthPid} = quod_client_auth:start_link(
                      #{network_id => NetworkId, node_key => NodeKey,
                        max_challenges => 4, max_sessions => 4}),
    unlink(AuthPid),
    ok = commit_root({assertz, {ontology_creator_agent, NodeRef}}),
    try
        #{session_id := SessionId, expires_ms := SessionExpires} =
            open_client_session(NetworkId, NodeKey, KeyPair, Peer),
        Agent = #{namespace => ActorNs, anchor => ActorAnchor,
                  instance_text => InstanceText},
        GoalText = iolist_to_binary(
                     ["quod:root::create_ontology(\"", NewNs,
                      "\", [], Anchor), \"", ActorNs,
                      "\"::assertz(hosts_ontology(",
                      agent_ref_source(NodeRef, InstanceText), ", ",
                      prolog_binary_literal(NewNs),
                      ", Anchor, private))."]),
        {RequestBytes, Signature} = signed_agent_goal_version(
                                      NetworkId, PublicKey, KeyPair,
                                      Agent, execute, SessionExpires,
                                      GoalText, 2),
        ok = assert_signed_action_result(
               quod_client_goal_ingress:submit(
                 execute, SessionId, RequestBytes, Signature, Peer),
               SessionId, RequestBytes, Signature, Peer),
        ok = wait_ready(NewNs, 300),
        Anchor = quod_simplex:genesis_hash(NewNs),
        ok = wait_desired_content(NewNs, Anchor, 300),
        {ok, HostRows, _} = quod_prolog:prove_ro(
                              ActorNs,
                              {hosts_ontology, {'NodeRef'}, {'Namespace'},
                               {'Anchor'}, private}),
        ?assert(
           lists:any(
              fun(#{'NodeRef' := Ref, 'Namespace' := Ns,
                    'Anchor' := A}) ->
                      Ref =:= NodeRef andalso Ns =:= NewNs
                          andalso A =:= Anchor
              end, HostRows))
    after
        _ = quod_prolog:execute(
              ?ROOT_NS, {retract, {ontology_creator_agent, NodeRef}}),
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
                          "\", [], _)."]),
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

%% Frozen using the pre-Cut2 codec, with an already-chosen incarnation. This
%% fixture binds the native journal shape independently of artifact internals.
prepared_genesis_native_format_golden_test() ->
    Ns = <<"quod:cut2-prepared">>,
    Executor = <<17:256>>,
    Config0 = #{committee => [], genesis_diff => []},
    %% Ambient node_addr must not enter the frozen vector. Pin only the
    %% generation input; the legacy serialized descriptor remains Config0.
    Genesis = quod_simplex:test_genesis_tx(
                Config0#{node_addr => undefined}, Ns, Executor, <<34:256>>),
    {ok, Entry} = quod_ledger:new_entry(1, {batch, [Genesis]}, 0, none),
    {ok, Block} = quod_ledger:block_from_entry(Entry),
    Anchor = quod_simplex:block_hash(Block),
    ?assertEqual(
       <<36,83,239,105,93,33,234,105,204,127,87,236,1,107,203,145,
         145,230,115,192,144,212,83,158,68,253,33,143,5,232,123,254>>,
       Anchor),
    Native = quod_ledger:entry_view(Entry),
    Config = Config0#{prepared_genesis_entry => Native, genesis_hash => Anchor},
    Prepared = {prepared_lifecycle, create, Ns, Anchor, Config, created},
    {ok, Bytes} = quod_ontology:prepared_bytes(Prepared),
    ?assertEqual(1777, byte_size(Bytes)),
    ?assertEqual(
       <<193,64,158,152,140,33,222,168,22,44,67,68,184,241,97,190,
         68,213,145,224,40,105,56,46,160,46,56,15,160,231,197,214>>,
       crypto:hash(sha256, Bytes)),
    ?assertEqual({ok, Prepared}, quod_ontology:decode_prepared(Bytes)),
    ?assertEqual({ok, Entry}, quod_ledger:from_entry_view(Native)),
    ?assertEqual({error, bad_entry}, quod_ledger:encode_entry(Native)),
    Action = {create_ontology, Ns, []},
    {ok, Effect0} = quod_ontology:prepared_effect(
                      Action, Prepared, Executor, {node, Executor}),
    %% Effect IDs are independently chosen, not derived from the preparation.
    Effect = setelement(6, Effect0, <<51:256>>),
    ?assert(quod_effect:validate(Effect)),
    ?assertEqual(<<51:256>>, quod_effect:effect_id(Effect)),
    ?assertEqual(Executor, quod_effect:executor(Effect)),
    ?assertEqual(crypto:hash(sha256, Bytes), quod_effect:prepared_digest(Effect)),
    ?assertEqual({Ns, Anchor}, quod_effect:target(Effect)).

prepared_genesis_survives_journal_restart(#{dir := Dir}) ->
    Ns = unique_ns(<<"prepared-journal-native">>),
    Action = {create_ontology, Ns, []},
    {ok, Structural} = quod_ontology:validate_action(Action),
    {ok, Prepared0} = quod_ontology:prepare_action(Structural),
    {prepared_lifecycle, create, Ns, _InitialAnchor, Config0, created} = Prepared0,
    %% Ordinary preparation itself must freeze a native entry, not an artifact.
    ?assertMatch(#entry{}, maps:get(prepared_genesis_entry, Config0)),
    {ok, Executor} = application:get_env(quod, node_pubkey),
    Incarnation = <<68:256>>,
    Genesis = quod_simplex:test_genesis_tx(Config0, Ns, Executor, Incarnation),
    {ok, Entry} = quod_ledger:new_entry(1, {batch, [Genesis]}, 0, none),
    {ok, Block} = quod_ledger:block_from_entry(Entry),
    Anchor = quod_simplex:block_hash(Block),
    Native = quod_ledger:entry_view(Entry),
    Config = Config0#{prepared_genesis_entry => Native, genesis_hash => Anchor},
    Prepared = {prepared_lifecycle, create, Ns, Anchor, Config, created},
    {ok, Bytes} = quod_ontology:prepared_bytes(Prepared),
    {ok, Effect} = quod_ontology:prepared_effect(
                     Action, Prepared, Executor, {node, Executor}),
    EffectId = quod_effect:effect_id(Effect),
    {ok, GoalBlob} = quod_durable_term:encode_goal(Action),
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
    Ref = {transaction, ?ROOT_NS, RootAnchor, Change#transaction.tx_id},
    {ok, Reservation} = quod_effect_journal:reserve(self()),
    ok = quod_effect_journal:stage(
           Reservation, Action, {ontology_hosted, Ns}, Effect, Prepared),
    ok = quod_effect_journal:bind_transaction(Effect, Change, Ref),
    %% Activation retains durable custody across restart; an unactivated row
    %% is intentionally retired by recovery and cannot exercise this contract.
    ok = quod_effect_journal:activate(EffectId),
    OldJournal = quod_reg:where({quod_effect_journal, node}),
    ok = gen_server:stop(OldJournal),
    ?assertEqual({ok, not_hosted}, quod_ontology:local_state(Ns)),
    {ok, NewJournal} = quod_effect_journal:start_link(#{data_dir => Dir}),
    unlink(NewJournal),
    ?assertMatch({ok, #{effect_id := EffectId, target := {Ns, Anchor}}},
                 quod_effect_journal:status(EffectId)),
    %% The existing ordered-apply release event activates the restored row.
    quod_effect_journal:release_applied(2, [Effect]),
    ok = wait_ready(Ns, 300),
    ok = wait_effect_target_state(Ns, applied, 300),
    ?assertEqual(Anchor, quod_simplex:genesis_hash(Ns)),
    ?assertMatch({ok, [#{'Incarnation' := Incarnation}], _},
                 quod_prolog:prove_ro(Ns, {consensus_incarnation, {'Incarnation'}})),
    ?assertEqual(crypto:hash(sha256, Bytes), quod_effect:prepared_digest(Effect)),
    ?assertMatch({ok, #{effect_id := EffectId, state := applied}},
                 quod_effect_journal:status(EffectId)).

malformed_present_prepared_genesis_fails_closed(_Fixture) ->
    lists:foreach(
      fun(Mutation) ->
          Ns = unique_ns(<<"bad-prepared-native">>),
          {ok, Structural} = quod_ontology:validate_action({create_ontology, Ns, []}),
          {ok, Prepared} = quod_ontology:prepare_action(Structural),
          {prepared_lifecycle, create, Ns, _Anchor, Config, created} = Prepared,
          BadConfig = Mutation(Config),
          ?assertMatch({error, _}, quod_ontology:execute_prepared(
                                    setelement(5, Prepared, BadConfig))),
          ?assertEqual(undefined, quod_simplex:genesis_hash(Ns)),
          ?assertEqual(undefined, quod_reg:where({quod_simplex, Ns})),
          {ok, Store} = quod_ledger_store:open_ro(
                          Ns, quod_ledger_store:ledger_dir(Config)),
          try ?assertEqual(0, quod_ledger_store:last(Store))
          after ok = quod_ledger_store:close(Store)
          end
      end,
      [fun(C) -> C#{prepared_genesis_entry => malformed} end,
       fun(C) ->
           View = maps:get(prepared_genesis_entry, C),
           C#{prepared_genesis_entry => View#entry{timestamp = 1}}
       end,
       fun(C) ->
           {ok, Artifact} = quod_ledger:from_entry_view(
                              maps:get(prepared_genesis_entry, C)),
           C#{prepared_genesis_entry => Artifact}
       end,
       fun(C) -> maps:remove(genesis_hash, C) end,
       fun(C) -> C#{genesis_hash => <<85:256>>} end]).

action_timeout_returns_exact_outcome(#{manager := Manager}) ->
    Ns = unique_ns(<<"action-timeout">>),
    ok = sys:suspend(Manager),
    Result =
        try quod_prolog:execute(?ROOT_NS, create_goal(Ns, []))
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
                     ?ROOT_NS, create_goal(Ns, []))}
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
    Action = create_goal(Ns, []),
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
       quod_prolog:execute(?ROOT_NS, create_goal(Ns, []))),
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
            create_goal(Ns, []), {ontology_hosted, Ns}},
    {fail, Reasons} = quod_prolog:execute(?ROOT_NS, Goal),
    ?assertEqual({ontology_creation_failed, invalid_action},
                 lists:last(Reasons)),
    ?assertEqual({ok, not_hosted}, quod_ontology:local_state(Ns)).

ordinary_static_config_is_not_authority(_Fixture) ->
    Ns = unique_ns(<<"static-anchor">>),
    StaticAnchor = crypto:strong_rand_bytes(32),
    DesiredAnchor = crypto:strong_rand_bytes(32),
    SavedDesired = application:get_env(quod, namespace_desired),
    SavedStatic = application:get_env(quod, namespace_static_content),
    Desired0 = application:get_env(quod, namespace_desired, #{}),
    Content0 = maps:get(content, Desired0, #{}),
    Static0 = application:get_env(quod, namespace_static_content, #{}),
    try
        application:set_env(
          quod, namespace_desired,
          Desired0#{content => maps:remove(Ns, Content0)}),
        application:set_env(
          quod, namespace_static_content,
          Static0#{Ns => #{genesis_hash => StaticAnchor}}),
        ?assertEqual({error, not_hosted}, quod_ontology:genesis_anchor(Ns)),

        %% Once the manager publishes its desired mirror, that single runtime
        %% owner remains authoritative over the earlier static input.
        application:set_env(
          quod, namespace_desired,
          Desired0#{content =>
                        Content0#{Ns => #{genesis_hash => DesiredAnchor}}}),
        ?assertEqual({ok, DesiredAnchor}, quod_ontology:genesis_anchor(Ns))
    after
        restore_env([{namespace_desired, SavedDesired},
                     {namespace_static_content, SavedStatic}])
    end.

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
        {ok, [#{}], Height} = quod_prolog:execute(
                                ?ROOT_NS,
                                create_goal(TargetNs, [])),
        ?assert(is_integer(Height) andalso Height > 0),
        ok = wait_ready(TargetNs, 300),
        ok = wait_effect_target_state(TargetNs, applied, 300),
        ?assertMatch(
           [#{state := applied,
              ref := {transaction, ?ROOT_NS, _, _}}],
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
                            create_goal(TargetNs, [])),
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
                      "\", [], _)."]),
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
        quod_prolog:execute(?NODE_NS, create_goal(Ns, [])),
    ?assertEqual({ontology_creation_failed, wrong_ontology},
                 lists:last(Reasons)),
    ?assertEqual({ok, not_hosted}, quod_ontology:local_state(Ns)).

invalid_create_never_reaches_hosting(_Fixture) ->
    BadNs = <<>>,
    {fail, Reasons} =
        quod_prolog:execute(?ROOT_NS, create_goal(BadNs, [])),
    ?assertEqual({ontology_creation_failed, invalid_name},
                 lists:last(Reasons)),
    ?assertEqual({error, invalid_name}, quod_ontology:local_state(BadNs)),
    {fail, VariableReasons} =
        quod_prolog:execute(
          ?ROOT_NS, create_goal({'Namespace'}, [])),
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
         create_goal(
           Ns,
           [{source,
             <<"can_invoke(_, _, _, _).\nkept(true).\n">>}]))),
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
                  "\", [source_file(\"", Missing, "\")], _)."]),
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
                  "\\napproved(ok).\\n\")], _)."]),
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
      {create_ontology, Name, Options, Anchor}, _OriginalDesired},
     Prerequisites, _Desired} = Original,
    FalseDesired = {never_reached, Name},
    Modified =
        {action,
         {'$quod_stage_ontology', Handle,
          {create_ontology, Name, Options, Anchor}, FalseDesired},
         Prerequisites, FalseDesired},
    ok = commit_root({',', {retract, Original}, {asserta, Modified}}),
    Ns = unique_ns(<<"false-postcondition">>),
    try
        ?assertEqual(
           {error, {operator_error, postcondition_failed}},
           quod_prolog:execute(?ROOT_NS, create_goal(Ns, []))),
        ok = wait_ready(Ns, 300),
        ?assertEqual({ok, ready}, quod_ontology:local_state(Ns))
    after
        ok = commit_root(
               {',', {retract, Modified}, {assertz, Original}})
    end.

reconcile_republishes_running_content(Fixture = #{manager := Manager}) ->
    Ns = unique_ns(<<"reconcile-publish">>),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:execute(?ROOT_NS, create_goal(Ns, []))),
    ok = wait_ready(Ns, 300),
    Anchor = quod_simplex:genesis_hash(Ns),
    ok = host_locally(Fixture, Ns, Anchor),
    Config = desired_content(Ns),
    ExpectedDirs = #{data => quod_ledger_store:data_dir(Config),
                     ledger => quod_ledger_store:ledger_dir(Config)},
    application:set_env(quod, content_storage_dirs, #{}),
    Manager ! reconcile,
    ok = wait_storage_dirs(Ns, ExpectedDirs, 300).

aborted_hosting_fact_changes_nothing(
  #{actor_ns := ActorNs, actor_principal := Principal}) ->
    Ns = unique_ns(<<"aborted-host">>),
    Anchor = crypto:strong_rand_bytes(32),
    {ok, NodeRef} = quod_agent_ref:materialize_principal(Principal),
    Host = {hosts_ontology, NodeRef, Ns, Anchor, private},
    ?assertMatch(
       {fail, _},
       quod_prolog:execute(ActorNs, {transaction, {',', {assertz, Host}, fail}})),
    ?assertEqual(false, desired_has_content(Ns)),
    ?assertMatch({fail, _}, quod_prolog:prove_ro(ActorNs, Host)).

retracted_hosting_fact_removes_restart_intent(
  #{actor_ns := ActorNs, actor_principal := Principal}) ->
    Ns = unique_ns(<<"retracted-host">>),
    Anchor = crypto:strong_rand_bytes(32),
    {ok, NodeRef} = quod_agent_ref:materialize_principal(Principal),
    Host = {hosts_ontology, NodeRef, Ns, Anchor, private},
    ?assertMatch({ok, [_], _}, quod_prolog:execute(ActorNs, {assertz, Host})),
    ok = wait_desired_content(Ns, Anchor, 300),
    ?assertMatch({ok, [_], _}, quod_prolog:execute(ActorNs, {retract, Host})),
    ok = wait_desired_absent(Ns, 300),
    ?assertEqual({ok, not_hosted}, quod_ontology:local_state(Ns)).

parked_hosting_starts_on_exact_directory_route(
  #{dir := Dir, actor_ns := ActorNs, actor_principal := Principal}) ->
    Ns = unique_ns(<<"route-arrival">>),
    Anchor = crypto:strong_rand_bytes(32),
    NodeKey = crypto:strong_rand_bytes(32),
    Identity = {Ns, Anchor},
    {ok, NodeRef} = quod_agent_ref:materialize_principal(Principal),
    Host = {hosts_ontology, NodeRef, Ns, Anchor, private},
    ?assertEqual(undefined, quod_reg:where({directory, node})),
    {ok, Directory} = quod_directory:start_link(
                        #{identity_dir => Dir,
                          expire_tick_ms => 60000, ttl_ms => 10000}),
    unlink(Directory),
    {ok, Control} = quod_directory_control:start_link(#{}),
    unlink(Control),
    try
        ?assertMatch(
           {ok, [_], _}, quod_prolog:execute(ActorNs, {assertz, Host})),
        ok = wait_route_wait(Identity, present, 300),
        ok = wait_directory_demand(Identity, 300),
        %% Installation publishes only the exact identity. The manager rereads
        %% the directory, prepares the ordinary pinned join and starts it.
        {ok, _} = quod_ct:install_directory_generation(
                    NodeKey, {<<"route-host">>, 15432},
                    [{Ns, Anchor, validator}], 1, 1),
        ok = wait_namespace_started(Ns, 300),
        ok = wait_route_wait(Identity, absent, 300),
        ?assertEqual(Anchor, maps:get(genesis_hash, desired_content(Ns)))
    after
        ?assertMatch({ok, [_], _},
                     quod_prolog:execute(ActorNs, {retract, Host})),
        ok = wait_desired_absent(Ns, 300),
        stop_process(Control),
        stop_process(Directory)
    end.

parked_hosting_is_exact_event_driven_and_unsubscribes(
  #{actor_ns := ActorNs, actor_principal := Principal}) ->
    Ns = unique_ns(<<"parked-host">>),
    Anchor = crypto:strong_rand_bytes(32),
    Other = crypto:strong_rand_bytes(32),
    Identity = {Ns, Anchor},
    {ok, NodeRef} = quod_agent_ref:materialize_principal(Principal),
    Host = {hosts_ontology, NodeRef, Ns, Anchor, private},
    ?assertMatch({ok, [_], _}, quod_prolog:execute(ActorNs, {assertz, Host})),
    ok = wait_route_wait(Identity, present, 300),
    Manager = quod_reg:where({namespace_manager, node}),
    ?assert(lists:member(
              Manager,
              gproc:lookup_pids(
                {p, l, {directory_route, Identity}}))),

    %% Wait subscriptions are process state. A replacement manager must derive
    %% the same park from the committed actor projection without a checkpoint.
    stop_process(Manager),
    {ok, NewManager} = quod_namespace_manager:start_link(),
    unlink(NewManager),
    ok = wait_route_wait(Identity, present, 300),
    ?assertNot(lists:member(
                 Manager,
                 gproc:lookup_pids(
                   {p, l, {directory_route, Identity}}))),
    ?assert(lists:member(
              NewManager,
              gproc:lookup_pids(
                {p, l, {directory_route, Identity}}))),

    %% An unrelated anchored identity cannot wake this work. The exact wake
    %% also cannot manufacture authority: without a route it merely rereads
    %% the directory and remains parked.
    NewManager ! {directory_route_available, {Ns, Other}},
    NewManager ! {directory_route_available, Identity},
    timer:sleep(350),
    ?assertEqual({ok, not_hosted}, quod_ontology:local_state(Ns)),
    ?assertMatch(#{route_waits := #{Identity := _}},
                 quod_namespace_manager:test_recovery_state()),

    %% 350 ms exceeds the deleted 250 ms retry. Time alone made no progress.
    ?assertMatch({ok, [_], _}, quod_prolog:execute(ActorNs, {retract, Host})),
    ok = wait_route_wait(Identity, absent, 300),
    ?assertNot(lists:member(
                 NewManager,
                 gproc:lookup_pids(
                   {p, l, {directory_route, Identity}}))).

catalogue_worker_failures_are_terminal_owner_failures(
  #{actor_principal := Principal}) ->
    ok = wait_system_query_idle(300),
    Manager1 = quod_reg:where({namespace_manager, node}),
    ManagerRef1 = monitor(process, Manager1),
    {Worker, _Token1} = quod_namespace_manager:test_arm_system_query(),
    exit(Worker, kill),
    receive
        {'DOWN', ManagerRef1, process, Manager1,
         {system_catalogue_worker_failed, killed}} -> ok
    after 1000 -> error(catalogue_worker_failure_did_not_stop_manager)
    end,
    {ok, Manager2} = quod_namespace_manager:start_link(),
    unlink(Manager2),
    ok = wait_node_actor_principal(Principal, 300),
    ok = wait_system_query_idle(300),

    ManagerRef2 = monitor(process, Manager2),
    {_Worker2, Token2} = quod_namespace_manager:test_arm_system_query(),
    Manager2 ! {system_catalogue_timeout, Token2},
    receive
        {'DOWN', ManagerRef2, process, Manager2,
         system_catalogue_query_timeout} -> ok
    after 1000 -> error(catalogue_worker_timeout_did_not_stop_manager)
    end,
    {ok, Manager3} = quod_namespace_manager:start_link(),
    unlink(Manager3),
    ok = wait_node_actor_principal(Principal, 300).

dynamic_hosting_survives_content_tree_restart(
  #{manager := Manager, ns_sup := NsSup,
    actor_ns := ActorNs, actor_anchor := ActorAnchor,
    actor_principal := ActorPrincipal}) ->
    Ns = unique_ns(<<"tree-restart">>),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:execute(?ROOT_NS, create_goal(Ns, []))),
    ok = wait_ready(Ns, 300),
    Anchor = quod_simplex:genesis_hash(Ns),
    ok = host_locally(
           #{actor_ns => ActorNs, actor_principal => ActorPrincipal},
           Ns, Anchor),
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
    ok = wait_ready(ActorNs, 300),
    ?assertEqual(RootAnchor, quod_simplex:genesis_hash(?ROOT_NS)),
    ?assertEqual(Anchor, quod_simplex:genesis_hash(Ns)),
    ?assertEqual(ActorAnchor, quod_simplex:genesis_hash(ActorNs)),
    ok = wait_node_actor_principal(ActorPrincipal, 300),
    ?assertEqual({ok, ready}, quod_ontology:local_state(Ns)),
    Config = desired_content(Ns),
    ?assertEqual(Anchor, maps:get(genesis_hash, Config)),
    ?assertNot(maps:is_key(prepared_genesis_entry, Config)),
    ?assertNot(maps:is_key(genesis_diff, Config)),
    ok = wait_effect_capacity(64, 300).

wrong_anchor_child_stops_then_exact_material_restarts(
  Fixture = #{actor_ns := ActorNs, actor_principal := Principal}) ->
    Ns = unique_ns(<<"anchor-swap">>),
    ?assertMatch(
       {ok, [#{}], _},
       quod_prolog:execute(?ROOT_NS, create_goal(Ns, []))),
    ok = wait_ready(Ns, 300),
    OldAnchor = quod_simplex:genesis_hash(Ns),
    ok = host_locally(Fixture, Ns, OldAnchor),
    {ok, NodeRef} = quod_agent_ref:materialize_principal(Principal),
    OldHost = {hosts_ontology, NodeRef, Ns, OldAnchor, private},

    %% Remove only this test-owned ledger directory while the old process still
    %% holds its open fd. This lets us prepare a genuinely different genesis
    %% for the same name before the committed hosting replacement stops it.
    OldConfig = desired_content(Ns),
    StoreDir = quod_ledger_store:ns_dir(
                 quod_ledger_store:ledger_dir(OldConfig), Ns),
    ok = file:del_dir_r(StoreDir),
    {ok, Structural} = quod_ontology:validate_action(
                         {create_ontology, Ns, []}),
    {ok, Prepared} = quod_ontology:prepare_action(Structural),
    NewAnchor = quod_ontology:prepared_anchor(Prepared),
    ?assertNotEqual(OldAnchor, NewAnchor),
    NewHost = {hosts_ontology, NodeRef, Ns, NewAnchor, private},
    ?assertMatch(
       {ok, [_ | _], _},
       quod_prolog:execute(
         ActorNs,
         {transaction, {',', {retract, OldHost}, {assertz, NewHost}}})),
    ok = wait_route_wait({Ns, NewAnchor}, present, 300),
    ok = wait_local_state(Ns, not_hosted, 300),

    %% Material arrival uses the ordinary lifecycle entry. The parked desired
    %% identity then becomes ready under the replacement anchor.
    ?assertMatch(
       {ok, created, Ns, NewAnchor},
       quod_ontology:execute_prepared(Prepared)),
    ok = wait_ready(Ns, 300),
    ?assertEqual(NewAnchor, quod_simplex:genesis_hash(Ns)),
    ok = wait_route_wait({Ns, NewAnchor}, absent, 300).

obsolete_desired_file_has_no_authority(
  #{dir := Dir, actor_principal := ActorPrincipal}) ->
    GhostNs = unique_ns(<<"obsolete-desired">>),
    GhostAnchor = crypto:strong_rand_bytes(32),
    Path = filename:join(Dir, "hosted_namespaces.qnd"),
    Payload = term_to_binary(
                {quod_namespace_desired, 1,
                 [{GhostNs, #{mode => join, genesis_hash => GhostAnchor}}]},
                [deterministic]),
    Bytes = <<16#514E4431:32/unsigned-big,
              (byte_size(Payload)):32/unsigned-big,
              (crypto:hash(sha256, Payload))/binary, Payload/binary>>,
    ok = file:write_file(Path, Bytes),
    ?assertMatch({ok, Bytes}, file:read_file(Path)),
    SavedPath = application:get_env(quod, namespace_desired_path),
    try
        application:set_env(quod, namespace_desired_path, Path),
        stop_process(quod_reg:where({namespace_manager, node})),
        application:set_env(
          quod, namespace_desired, #{content => #{}, brahms => #{}}),
        {ok, NewManager} = quod_namespace_manager:start_link(),
        unlink(NewManager),
        ok = wait_node_actor_principal(ActorPrincipal, 300),
        ?assertEqual(false, desired_has_content(GhostNs)),
        ?assertEqual({ok, not_hosted}, quod_ontology:local_state(GhostNs))
    after
        restore_env([{namespace_desired_path, SavedPath}])
    end.

commit_root(Goal) ->
    ?assertMatch({ok, [_ | _], _}, quod_prolog:execute(?ROOT_NS, Goal)),
    ok.

root_creation_action() ->
    File = filename:join(code:priv_dir(quod), "ontologies/quod_root.pl"),
    [Declaration] =
        [Term || {action,
                  {'$quod_stage_ontology', _, {create_ontology, _, _, _}, _},
                  _, _} = Term <- quod_prolog:read_terms(File)],
    Declaration.

create_goal(Ns, Options) ->
    {create_ontology, Ns, Options, {'_'}}.

host_locally(#{actor_ns := ActorNs, actor_principal := Principal}, Ns, Anchor) ->
    {ok, NodeRef} = quod_agent_ref:materialize_principal(Principal),
    ?assertMatch(
       {ok, [_ | _], _},
       quod_prolog:execute(
         ActorNs,
         {assertz, {hosts_ontology, NodeRef, Ns, Anchor, private}})),
    wait_desired_content(Ns, Anchor, 300).

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
    signed_agent_goal_version(
      NetworkId, PublicKey, KeyPair,
      #{namespace => AgentNs, anchor => AgentAnchor,
        instance_text => InstanceText},
      Mode, SessionExpires, GoalText, 1).

signed_agent_goal_version(
  NetworkId, PublicKey, KeyPair,
  #{namespace := AgentNs, anchor := AgentAnchor,
    instance_text := InstanceText},
  Mode, SessionExpires, GoalText, ParserVersion) ->
    Request = #{network_identity => NetworkId,
                signing_public_key => PublicKey,
                operation_id => crypto:strong_rand_bytes(32),
                agent_namespace => AgentNs,
                agent_genesis_anchor => AgentAnchor,
                agent_instance_text => InstanceText,
                mode => Mode,
                parser_version => ParserVersion,
                not_after_ms => min(SessionExpires,
                                    quod_time:now_ms() + 30000),
                goal_text => GoalText},
    {ok, RequestBytes} = quod_client_goal:encode(Request),
    {RequestBytes,
     quod_identity:sign(RequestBytes, quod_identity:key_term(KeyPair))}.

assert_signed_action_result(
  {ok, _, {normalized, {committed, [_],
                        {transaction, _, _, _}}}},
  _SessionId, _RequestBytes, _Signature, _Peer) ->
    ok;
assert_signed_action_result(
  {ok, _, {normalized, {committed, [_],
                        {group_outcome, _, _, _}}}},
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
         create_goal(AgentNs, [{source, InitialSource}]))),
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

agent_ref_source({agent_instance_ref, Ns, Anchor, _Instance}, InstanceText) ->
    InstanceSource = binary:part(InstanceText, 0, byte_size(InstanceText) - 1),
    ["agent_instance_ref(", prolog_binary_literal(Ns), ", ",
     prolog_binary_literal(Anchor), ", ",
     InstanceSource, ")"].

desired_content(Ns) ->
    Desired = application:get_env(
                quod, namespace_desired,
                #{content => #{}, brahms => #{}}),
    maps:get(Ns, maps:get(content, Desired)).

wait_desired_content(_Ns, _Anchor, 0) -> error(hosting_projection_not_installed);
wait_desired_content(Ns, Anchor, N) ->
    Desired = application:get_env(
                quod, namespace_desired,
                #{content => #{}, brahms => #{}}),
    case maps:get(Ns, maps:get(content, Desired), undefined) of
        #{genesis_hash := Anchor} -> ok;
        _ -> receive after 10 -> wait_desired_content(Ns, Anchor, N - 1) end
    end.

wait_desired_absent(_Ns, 0) -> error(hosting_projection_not_removed);
wait_desired_absent(Ns, N) ->
    case desired_has_content(Ns) of
        false -> ok;
        true -> receive after 10 -> wait_desired_absent(Ns, N - 1) end
    end.

wait_route_wait(Identity, Expected, 0) ->
    error({route_wait_state_timeout, Identity, Expected,
           quod_namespace_manager:test_recovery_state()});
wait_route_wait(Identity, Expected, N) ->
    #{route_waits := Waits} = quod_namespace_manager:test_recovery_state(),
    Present = maps:is_key(Identity, Waits),
    case {Expected, Present} of
        {present, true} -> ok;
        {absent, false} -> ok;
        _ -> receive after 10 ->
                 wait_route_wait(Identity, Expected, N - 1)
             end
    end.

wait_directory_demand(Identity, 0) ->
    error({directory_demand_timeout, Identity,
           quod_directory_control:test_control_state()});
wait_directory_demand(Identity, N) ->
    State = quod_directory_control:test_control_state(),
    case lists:member(Identity, maps:get(route_demands, State)) of
        true -> ok;
        false -> receive after 10 ->
                     wait_directory_demand(Identity, N - 1)
                 end
    end.

wait_local_state(Ns, Expected, 0) ->
    error({local_state_timeout, Ns, Expected,
           quod_ontology:local_state(Ns)});
wait_local_state(Ns, Expected, N) ->
    case quod_ontology:local_state(Ns) of
        {ok, Expected} -> ok;
        _ -> receive after 10 -> wait_local_state(Ns, Expected, N - 1) end
    end.

wait_system_query_idle(0) -> error(system_query_idle_timeout);
wait_system_query_idle(N) ->
    case quod_namespace_manager:test_recovery_state() of
        #{system_query := idle} -> ok;
        _ -> receive after 10 -> wait_system_query_idle(N - 1) end
    end.

wait_namespace_started(_Ns, 0) -> error(namespace_start_timeout);
wait_namespace_started(Ns, N) ->
    case quod_reg:where({quod_ns, Ns}) of
        Pid when is_pid(Pid) -> ok;
        undefined -> receive after 10 -> wait_namespace_started(Ns, N - 1) end
    end.

desired_has_content(Ns) ->
    Desired = application:get_env(
                quod, namespace_desired,
                #{content => #{}, brahms => #{}}),
    maps:is_key(Ns, maps:get(content, Desired)).

wait_ready(_Ns, 0) -> error(namespace_not_ready);
wait_ready(Ns, N) ->
    case quod_prolog:prove_ro(Ns, true) of
        {ok, _, _} -> ok;
        _ -> receive after 10 -> wait_ready(Ns, N - 1) end
    end.

wait_node_actor_principal(_Principal, 0) ->
    error(node_actor_activation_timeout);
wait_node_actor_principal(Principal, N) ->
    case quod_node_actor:principal() of
        {ok, Principal} -> ok;
        _ ->
            receive after 10 -> ok end,
            wait_node_actor_principal(Principal, N - 1)
    end.

wait_manager_idle(_Manager, 0) ->
    error(namespace_manager_idle_timeout);
wait_manager_idle(_Manager, N) ->
    %% The call is ordered after the test's reconcile message, so observing the
    %% manager-owned mutation lane idle proves that cycle completed.
    case quod_namespace_manager:test_mutation_worker() of
        undefined -> ok;
        _ ->
            receive after 10 -> ok end,
            wait_manager_idle(undefined, N - 1)
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
