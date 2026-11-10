-module(quod_lifecycle_single_path_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

-define(ROOT_NS, <<"quod:root">>).
-define(NODE_NS, <<"quod:node">>).

-export([preview_worlds/1]).

terms_creation_preserves_clauses_test_() ->
    {timeout, 60, fun() ->
        F = setup(genesis),
        #{actor_keypair := {NodeKey, _}} = F,
        {ok, Network} = quod_ontology:network_identity(),
        {ok, Auth} = quod_client_auth:start_link(#{network_id => Network, node_key => NodeKey}),
        unlink(Auth),
        try
            {Key, _} = Pair = quod_identity:generate(),
            Agent = provision_agent(Key, true),
            Client = Agent#{keypair => Pair, network => Network, parser_version => 3},
            Ns = unique_ns(<<"terms-clauses">>),
            Terms = [{can_invoke, {'_'}, {'_'}, {'_'}, {'_'}},
                {':-', {same_value, {'X'}, {'Y'}}, {'=', {'X'}, {'Y'}}}],
            {Goal, _, _} = erlog_int:term_instance(
                {',', {'::', ?ROOT_NS, create_goal(Ns, [{terms, Terms}])}, {'=', {'X'}, later_binding}}, 0),
            true = quod_reg:subscribe({runtime, Ns}),
            try
                {ok, Evidence, {normalized, {committed, _, _}}} = submit_lobby(Client, execute, Goal),
                m1a_complete(Evidence),
                [Anchor] = [A || #{target := {N, A}} <- quod_effect_journal:rows(), N =:= Ns],
                ok = await_enrolled_identity({Ns, Anchor}, quod_time:mono_ms() + 10000),
                %% Binding a caller variable after preparation cannot specialize
                %% the immutable clause that was already prepared and admitted.
                ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Ns, {same_value, first, first})),
                ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Ns, {same_value, second, second})),
                ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {same_value, first, second})),
                ?assertEqual(Anchor, quod_simplex:genesis_hash(Ns))
            after quod_reg:unsubscribe({runtime, Ns}) end,
            %% A bound name and list are still required; rule data cannot make
            %% other creation options or a join request accept missing inputs.
            [ ?assertEqual({error, invalid_arguments}, quod_ontology:validate_action(Action)) || Action <-
                [{create_ontology, {'Name'}, [{terms, Terms}]},
                 {create_ontology, Ns, [{terms, {'Terms'}}]},
                 {create_ontology, Ns, [{terms, Terms}, {external_predicate_modules, {'Modules'}}]},
                 {create_ontology, Ns, [{terms, Terms}, {source_file, {'Path'}}]},
                 {join_ontology, Ns, {'Anchor'}, []}]],
            internal_staging_continuation_cannot_be_forged(F),
            reserved_initial_terms_never_reach_hosting(F),
            structural_validation_is_total(F)
        after stop_process(Auth), cleanup(F) end
    end}.

creation_clauses_regression_test_() ->
    [{Name, {timeout, 60, fun() ->
        F = setup(genesis),
        try Test(F) after cleanup(F) end
    end}} || {Name, Test} <- [
        {"prepared clauses survive journal restart", fun prepared_genesis_survives_journal_restart/1},
        {"root entry ACL remains required", fun signed_root_create_obeys_entry_acl/1},
        {"failed policy prepares nothing", fun failed_root_policy_does_not_read_or_stage/1},
        {"false postcondition refuses", fun false_postcondition_is_reported/1}]].

material_admission_uses_committed_root_policy_test_() ->
    {timeout,60,fun() ->
        F = setup(),
        Override = {material_limit_override,founding,canonical_bytes,0},
        try
            commit_root({assertz,Override}),
            Read = fun() -> ?assertMatch({ok,[#{}],_},
                quod_prolog:prove_ro(?ROOT_NS,{material_limit,founding,canonical_bytes,0})) end,
            Read(),
            quod_lobby_tests:assert_read_has_no_io(fun() -> Read(),Read() end),
            Ns = unique_ns(<<"governed-material">>), Goal = create_goal(Ns,[]),
            {fail,Reasons} = quod_prolog:execute(?ROOT_NS,Goal),
            ?assert(lists:any(fun
                ({ontology_creation_failed,{material_limit,founding,canonical_bytes,Actual,0}})
                  when Actual > 0 -> true;
                (_) -> false end,Reasons)),
            ?assertEqual({ok,not_hosted},quod_ontology:local_state(Ns)),
            ?assertEqual([], [R || R=#{target := {Target,_}} <- quod_effect_journal:rows(),Target =:= Ns]),
            commit_root({retract,Override}),
            ?assertMatch({ok,[#{}],_},quod_prolog:execute(?ROOT_NS,Goal)),
            ok = wait_ready(Ns,300),
            [ok = quod_effect_journal:await(Id,5000) || #{effect_id := Id} <- quod_effect_journal:rows()],
            Before = maps:get(committed,quod_simplex:stats(?ROOT_NS)),
            quod_lobby_tests:assert_read_has_no_io(fun() ->
                ?assertMatch({ok,[#{}],_},quod_prolog:execute(?ROOT_NS,Goal))
            end),
            ?assertEqual(Before,maps:get(committed,quod_simplex:stats(?ROOT_NS)))
        after cleanup(F) end
    end}.

%% Browser acceptance uses the same disposable factory and real signed owners.
%% Metadata contains only this fixture's key, in an owner-only file.
preview_worlds(MetadataPath) ->
    F = setup(),
    #{dir := Dir, actor_ns := ActorNs, actor_principal := Principal} = F,
    {ok, Node} = quod_agent_ref:materialize_principal(Principal),
    {ok, Network} = quod_ontology:network_identity(),
    {ok, NodeKey} = application:get_env(quod, node_pubkey),
    Unlock = filename:join(Dir, "vault-unlock"),
    ok = quod_file:write_atomic(Unlock, crypto:strong_rand_bytes(32), 8#600),
    {ok, Vault} = quod_agent_vault:start_link(
        #{directory => filename:join(Dir, "vault"), unlock_file => Unlock}),
    unlink(Vault),
    {ok, Auth} = quod_client_auth:start_link(#{network_id => Network, node_key => NodeKey}),
    unlink(Auth),
    {ok, Cursors} = quod_client_cursor:start_link(),
    unlink(Cursors),
    try
        User = found_lobby_user(found_lobby_classes(), Network, Node),
        #{reference := Owner = {agent_instance_ref, UserNs, UserAnchor, me},
          lobby_name := Ns, keypair := {Public, Seed}} = User,
        commit_root({assertz, {ontology_creator_agent, Owner}}),
        {ok, _, _} = quod_prolog:execute(ActorNs,
            {assertz, {can_host_ontology, Owner, Node, Ns, {'Anchor'}, discoverable}}),
        {ok, _, {normalized, {committed, _, _}}} =
            submit_lobby(User, execute, {physical_fixture_found, {0}}),
        ok = wait_ready(Ns, 300),
        {ontology_ref, Ns, Anchor} = lobby_user_reference(User),
        application:set_env(quod, client_enabled, true),
        application:set_env(quod, client_ip, {127, 0, 0, 1}),
        application:set_env(quod, client_port, 0),
        {ok, _} = application:ensure_all_started(ssl),
        {ok, _} = application:ensure_all_started(cowboy),
        {ok, Client} = quod_client:start_link(),
        unlink(Client),
        Encode = fun(B) -> base64:encode(B, #{mode => urlsafe, padding => false}) end,
        Metadata = #{port => ranch:get_port(quod_client_listener),
            namespace => UserNs, anchor => Encode(UserAnchor), instanceText => <<"me.">>,
            network => Encode(Network), public_key => Encode(Public), seed => Encode(Seed),
            lobby_namespace => Ns, lobby_anchor => Encode(Anchor)},
        ok = quod_file:write_atomic(MetadataPath, iolist_to_binary(json:encode(Metadata)), 8#600),
        io:format("Isolated world-library endpoint ready.~n"),
        try receive stop -> ok end
        after stop_process(Client) end
    after stop_process(Cursors), stop_process(Auth), cleanup(F), stop_process(Vault) end.

default_lobby_physics_startup_test_() ->
    {timeout, 90, fun() ->
        F = setup(),
        #{dir := Dir, actor_ns := ActorNs, actor_principal := Principal} = F,
        {ok, Node} = quod_agent_ref:materialize_principal(Principal),
        {ok, Network} = quod_ontology:network_identity(),
        {ok, NodeKey} = application:get_env(quod, node_pubkey),
        Unlock = filename:join(Dir, "vault-unlock"),
        ok = quod_file:write_atomic(Unlock, crypto:strong_rand_bytes(32), 8#600),
        {ok, Vault} = quod_agent_vault:start_link(#{directory => filename:join(Dir, "vault"), unlock_file => Unlock}),
        unlink(Vault),
        {ok, Auth} = quod_client_auth:start_link(#{network_id => Network, node_key => NodeKey}),
        unlink(Auth),
        try
            Classes = found_lobby_classes(),
            User = found_lobby_user(Classes, Network, Node),
            #{reference := Owner, lobby_name := Ns} = User,
            commit_root({assertz, {ontology_creator_agent, Owner}}),
            {ok, _, _} = quod_prolog:execute(ActorNs,
                {assertz, {can_host_ontology, Owner, Node, Ns, {'Anchor'}, discoverable}}),
            {ok,_,{normalized,Founded}}=submit_lobby(User,execute,{physical_fixture_found,{0}}),
            m3a_committed(Founded),
            ok = wait_ready(Ns, 300),
            {ontology_ref, Ns, Anchor} = lobby_user_reference(User),
            Scoped = fun(G) -> {'::', Ns, {',', {current_ontology_identity, Ns, Anchor}, G}} end,
            ?assertMatch({ok, _, {normalized, {read, _, {answers, _, [_]}}}},
                submit_lobby(User, read, Scoped({gui_schema,world_creation,{0},{1}}))),
            [ok = quod_effect_journal:await(Id,5000)
             || #{effect_id := Id} <- quod_effect_journal:rows()],
            Manager = quod_reg:where({namespace_manager,node}),
            Manager ! reconcile,
            ok = wait_manager_idle(Manager,500),
            Prepare = Scoped({physics_preparation, personal_lobby, {0}}),
            {ok, _, {normalized, {read, _, {answers, _, [Prepared]}}}} = submit_lobby(User, read, Prepare),
            {ok, [{<<"V0">>, {prepared, Node, Key}}]} = quod_client_result:decode_binding(Prepared),
            quod_lobby_tests:assert_read_has_no_io(fun() ->
                ?assertMatch({ok, _, {normalized, {read, _, {answers, _, [Prepared]}}}},
                    submit_lobby(User, read, Prepare))
            end),
            ?assertEqual(#{}, gen_server:call(quod_reg:via({quod_runtime, Ns}), physics_worlds)),
            Other = found_lobby_user(Classes, Network, Node),
            Start = Scoped({physics_initialize, personal_lobby, Node, Key}),
            ?assertMatch({ok, _, {normalized, {failed, _}}}, submit_lobby(Other, execute, Start)),
            ?assertMatch({ok, _, {normalized, {failed, _}}}, submit_lobby(User, execute,
                {'::', Ns, {',', {current_ontology_identity, Ns, <<0:256>>}, {physics_initialize, personal_lobby, Node, Key}}})),
            ?assertMatch({ok, _, {normalized, {committed, _, _}}}, submit_lobby(User, execute,
                Scoped({retract, {physics_initial_host, personal_lobby, Node}}))),
            ?assertMatch({ok, _, {normalized, {failed, _}}}, submit_lobby(User, execute, Start)),
            ?assertMatch({ok, _, {normalized, {committed, _, _}}}, submit_lobby(User, execute,
                Scoped({assertz, {physics_initial_host, personal_lobby, Node}}))),
            true = quod_reg:subscribe({physics, Ns}),
            try
                ?assertMatch({ok, _, {normalized, {committed, _, _}}}, submit_lobby(User, execute, Start)),
                Pid = await_lobby_physics(Ns, Anchor, quod_time:mono_ms() + 10000),
                ?assertMatch(#{phase := active, navigation_ready := true}, gen_server:call(Pid, status)),
                {ok, _, {normalized, {read, _, {answers, _, [Ready]}}}} = submit_lobby(User, read, Prepare),
                ?assertEqual({ok, [{<<"V0">>, ready}]}, quod_client_result:decode_binding(Ready)),
                ?assertMatch({ok, _, {normalized, {failed, _}}}, submit_lobby(User, execute, Start)),
                ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Ns,
                    {physics_control, personal_lobby, Owner, 1, {controlled, pilot, eye}})),
                ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Ns,
                    {agent_hosted, physics_authority, Node, 1, Key})),
                View = Scoped({client_world_view,personal_lobby,playing,[],{0}}),
                {ok,_,{normalized,{read,_,{answers,_,[Scene]}}}} = submit_lobby(User,read,View),
                {ok,[{<<"V0">>,{world_view,_,_,Marks,_}}]} = quod_client_result:decode_binding(Scene),
                ?assert(lists:any(fun({mark,_,_,_,{body_pose,_,_},_,_,_}) -> true; (_) -> false end,Marks)),
                [?assert(lists:keymember(quod_ct:scene_mark_id(Marks,
                    {entity_ref,Ns,Anchor,Entity},Part),2,Marks)) || {Entity,Part} <-
                    [{floor,<<"model">>},{personal_roof,<<"model">>},
                     {console,<<"model">>},{personal_sky,<<"sky">>}]],
                ?assertEqual([], [Id || {mark,Id,_,_,_,_,{label,Text,_},_} <- Marks,
                    Text =:= <<"No matching eidolon">> orelse Text =:= <<"Choose an eidolon">>]),
                Runtime = quod_reg:via({quod_runtime,Ns}),
                World = {world_ref,Ns,Anchor,personal_lobby},
                #{World := #{spec := BeforeSpec}} = gen_server:call(Runtime,physics_worlds),
                lobby_safety_queries(Pid,BeforeSpec),
                Before = gen_server:call(Pid,status),
                Shape = {box,900,900,300},
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},submit_lobby(User,execute,
                    Scoped({physics_edit_definition,console,1,{geometry,Shape,1}}))),
                Expected = #{fence => quod_physics:fence(BeforeSpec),
                    structure => maps:get(structure,BeforeSpec)+1,tick => -1},
                await_lobby_structure(Pid,World,Expected,quod_time:mono_ms()+10000),
                #{World := #{pid := Pid,spec := EditedSpec}} = gen_server:call(Runtime,physics_worlds),
                ?assert(lists:any(fun({_,_,fixed,_,{solid,{box,0.9,0.9,0.3}},_}) -> true;
                                    (_) -> false end,maps:get(bodies,EditedSpec))),
                ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
                    {physics_definition,console,2,{geometry,Shape,1}})),
                Edited = gen_server:call(Pid,status),
                ?assertEqual(maps:get(incarnation,Before),maps:get(incarnation,Edited)),
                ?assertEqual(ok,quod_runtime:reconcile_resource(Ns,quod_prolog:applied(Ns),
                    physics_worlds,all,quod_time:mono_ms()+10000)),
                ?assertEqual(maps:get(installs,Edited),maps:get(installs,gen_server:call(Pid,status)))
            after quod_reg:unsubscribe({physics, Ns}) end
        after stop_process(Auth), cleanup(F), stop_process(Vault) end
    end}.

lobby_safety_queries(Pid,Spec) ->
    [{Pilot,Revision,controlled,_,_,_}] = [B || B={_,_,controlled,_,_,_} <- maps:get(bodies,Spec)],
    {Floor,_,fixed,_,{surface,_,_},_} = hd([B || B={_,_,fixed,_,{surface,V,_},_} <- maps:get(bodies,Spec),length(V)>100]),
    Expected = #{fence => quod_physics:fence(Spec),structure => maps:get(structure,Spec),
        incarnation => maps:get(run_token,Spec)},
    Query = fun(Q) -> quod_physics:motion_query(Pid,Expected,{Pilot,Revision},Q,{query_limits,2,0,8,128},1000) end,
    ?assertMatch({ok,_,{0,0,0},{clear,_,_}},Query({place,{pose,{vector,0,1000,2800},{rotation,0,0,0}}})),
    {ok,_,{0,0,0},{clipped,{{X,Y,Z},_},Contacts,_}} = Query({landing,{vector,0,1000,0},4000,2000,900}),
    ?assert(abs(X)<0.01 andalso abs(Z)<0.01 andalso Y>0.19 andalso Y<0.23),
    ?assert(lists:keymember(Floor,1,Contacts)),
    {ok,_,{0,0,0},{clipped,{{_,RimY,RimZ},_},RimContacts,_}} = Query({travel,{vector,0,0,-15000},{angular,0,0,0}}),
    ?assert(RimZ > -8.6 andalso RimZ < -8.0 andalso RimY >= 0.99),
    ?assert(lists:keymember(Floor,1,RimContacts)),
    Before = gen_server:call(Pid,status),
    quod_lobby_tests:assert_read_has_no_io(fun() ->
        [?assertMatch({ok,_,{0,0,0},{clipped,_,_,_}},Query({landing,{vector,0,1000,0},4000,2000,900})) || _ <- lists:seq(1,3)]
    end),
    ?assertEqual(maps:with([installs,steps,incarnation],Before),
        maps:with([installs,steps,incarnation],gen_server:call(Pid,status))).

submit_lobby(User, Mode, Goal) ->
    {Bytes, Signature} = lobby_user_request(User, Mode, Goal),
    quod_client_goal_ingress:submit(Bytes, Signature).

await_lobby_structure(Pid,World,Expected,Deadline) ->
    case quod_physics:snapshot(Pid,Expected) of
        {ok,_,_} -> ok;
        _ -> receive
            {physics_status,_,Pid,World,_,installed} ->
                await_lobby_structure(Pid,World,Expected,Deadline)
        after max(0,Deadline-quod_time:mono_ms()) -> error(lobby_edit_not_installed) end
    end.

await_lobby_physics(Ns, Anchor, Deadline) ->
    receive
        {physics_status, _, Pid, {world_ref, Ns, Anchor, personal_lobby}, _, installed} ->
            case gen_server:call(Pid, status) of
                #{phase := active, navigation_ready := true} -> Pid;
                _ -> await_lobby_physics(Ns, Anchor, Deadline)
            end;
        {physics_status, _, _, {world_ref, Ns, Anchor, personal_lobby}, _, _} ->
            await_lobby_physics(Ns, Anchor, Deadline)
    after max(0, Deadline - quod_time:mono_ms()) ->
        error({lobby_physics_not_ready, quod_runtime:stats(Ns)})
    end.

lifecycle_single_path_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(Fixture) ->
         [{timeout, 30, ?_test(effect_limits_are_committed_root_policy(Fixture))},
          {timeout, 30, ?_test(create_is_one_normal_effect_transaction(Fixture))},
          {timeout, 60, ?_test(full_physical_composition_uses_governed_preparation_budget(Fixture))},
          {timeout, 30, ?_test(repeated_create_is_a_noop(Fixture))},
          {timeout, 30, ?_test(failed_transaction_branch_discards_its_effect(Fixture))},
          {timeout, 30, ?_test(join_uses_the_same_goal_path(Fixture))},
          {timeout, 30, ?_test(node_actor_uses_ordinary_creation(Fixture))},
          {timeout, 30, ?_test(signed_agent_create_uses_the_same_goal_path(Fixture))},
          {timeout, 60, ?_test(create_and_host_is_one_ordinary_goal(Fixture))},
          {timeout, 30, ?_test(hosting_action_checks_policy_and_conflicts(Fixture))},
          {timeout, 90, ?_test(personal_lobbies_use_shared_creation_and_recovery(Fixture))},
          {timeout, 90, ?_test(node_enrollment_uses_signed_atomic_creation(Fixture))},
          {timeout, 30, ?_test(bundled_agent_policy_uses_ordinary_creation(Fixture))},
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
          ?_test(oversized_vocabulary_never_reaches_hosting(Fixture)),
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
          ?_test(catalogue_worker_failures_are_terminal_owner_failures(Fixture)),
          {timeout, 60,
           ?_test(system_names_is_created_hosted_and_registered(Fixture))}]
     end}.

effect_limits_are_committed_root_policy(#{root_config := Config, actor_keypair := {Pub, _}}) ->
    ?assertNot(lists:member(quod_agent_predicates,
                           maps:get(external_predicate_modules, Config))),
    ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(?ROOT_NS, {me, {node, Pub}})),
    ?assertEqual({64, unlimited}, quod_effect_journal:limits()),
    ?assertMatch(
       {ok, [#{'Capacity' := 64}], _},
       quod_prolog:prove_ro(
         ?ROOT_NS, {effect_custody_limits, {'Capacity'}, unlimited})),
    try
        %% A direct assertion invalidates the resource selector. The owning
        %% journal installs the resulting committed policy without a reaction.
        commit_root(
          {assertz, {effect_custody_limits_override, 3, unlimited}}),
        ok = wait_effect_limits({3, unlimited}, 300),
        ?assertMatch(
           {ok, [#{'Capacity' := 3}], _},
           quod_prolog:prove_ro(
             ?ROOT_NS, {effect_custody_limits, {'Capacity'}, unlimited})),

        %% The convenience predicate replaces the override atomically and has
        %% no compiled maximum.
        commit_root({set_effect_custody_limits, unlimited, unlimited}),
        ok = wait_effect_limits({unlimited, unlimited}, 300),
        ?assertMatch(
           {fail, _},
           quod_prolog:execute(
             ?ROOT_NS, {set_effect_custody_limits, -1, unlimited}))
    after
        commit_root({set_effect_custody_limits, 64, unlimited}),
        ok = wait_effect_limits({64, unlimited}, 300)
    end.

setup() -> setup(manual).

setup(Mode) ->
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
    true = quod_reg:subscribe({runtime,?ROOT_NS}),
    try
        {ok,_}=quod_namespace_manager:start_content(?ROOT_NS,RootConfig),
        ok=await_enrolled_identity({?ROOT_NS,quod_simplex:genesis_hash(?ROOT_NS)},quod_time:mono_ms()+3000)
    after quod_reg:unsubscribe({runtime,?ROOT_NS}) end,
    Base = #{dir => Dir, saved => Saved, manager => Manager,
             ns_sup => NsSup, brahms_sup => BrahmsSup, journal => Journal,
             router => Router, foreign_log => ForeignLog,
             root_config => RootConfig, actor_keypair => {Pub, Seed}},
    case Mode of
    genesis -> Base;
    _ ->
    NodeSource = list_to_binary(
                   filename:join(code:priv_dir(quod),
                                 "ontologies/quod_node.pl")),
    {ok, created, ?NODE_NS, _} =
        quod_ontology:create(
          ?NODE_NS,
          [{source_file, NodeSource},
           {external_predicate_modules, [quod_ontology_predicates]}]),
    ok = wait_ready(?NODE_NS, 300),
    %% Authored GUI class references use the registered vocabulary identity.
    %% Every factory in this isolated node shares that immutable vocabulary.
    {<<"quod:gui">>, _} = found_lobby_named_sources(<<"quod:gui">>,
        ["quod_gui.pl"], [], [quod_agent_predicates,quod_gui_predicates]),
    ok = wait_effect_limits({64, unlimited}, 300),
    case Mode of
    automatic -> Base;
    manual ->
    ActorNs = unique_ns(<<"node-actor">>),
    ActorInstanceText = <<"physical_node(primary).">>,
    ActorOptions = quod_ct:node_identity_options(
                       ActorNs, {physical_node, primary}, Pub),
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
    Base#{actor_ns => ActorNs,
      actor_anchor => ActorAnchor, actor_principal => ActorPrincipal,
      actor_instance_text => ActorInstanceText,
      actor_keypair => {Pub, Seed}}
    end
    end.

m1a_guarded_source_test_() ->
    {timeout, 60, fun() ->
        F = setup(genesis),
        try
            Path = filename:join(maps:get(dir, F), "hash-checked.pl"),
            OldConsult = application:get_env(erlog, consult_path),
            application:set_env(erlog, consult_path, [maps:get(dir, F)]),
            Bytes = <<"can_invoke(_,_,_,_).\nsource_text(<<\"", 16#C3,16#A9, "\">>).\n">>,
            ok = file:write_file(Path, Bytes), Hash = crypto:hash(sha256, Bytes),
            Ns = unique_ns(<<"hash-checked">>),
            Wrong = unique_ns(<<"hash-refused">>),
            {fail, Reasons} = quod_prolog:execute(?ROOT_NS,
                {create_ontology, Wrong, [{source_file, list_to_binary(Path), <<0:256>>}], {'_'}}),
            ?assert(lists:member({ontology_creation_failed, {source_hash_mismatch, 1}}, Reasons)),
            ?assertEqual({ok, not_hosted}, quod_ontology:local_state(Wrong)),
            ?assertEqual({error, invalid_options}, quod_ontology:validate_action(
                {create_ontology, Wrong, [{source_file, Path, <<1>>}]})),
            {ok, OriginalTerms} = erlog_io:read_file(Path),
            {source_text, OriginalText} = lists:keyfind(source_text, 1, OriginalTerms),
            {ok, Descriptor} = quod_ontology:validate_action(
                {create_ontology, Ns, [{source_file, "hash-checked.pl", Hash}]}),
            {ok, Prepared} = quod_ontology:prepare_action(Descriptor),
            ok = file:delete(Path),
            true = quod_reg:subscribe({runtime, Ns}),
            try
                {ok, created, Ns, _} = quod_ontology:execute_prepared(Prepared),
                Anchor = quod_simplex:genesis_hash(Ns),
                ok = await_enrolled_identity({Ns, Anchor}, quod_time:mono_ms() + 10000),
                ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {source_text, OriginalText}))
            after quod_reg:unsubscribe({runtime, Ns}) end,
            case OldConsult of
                undefined -> application:unset_env(erlog, consult_path);
                {ok, PriorPaths} -> application:set_env(erlog, consult_path, PriorPaths)
            end
        after cleanup(F) end
    end}.

m1a_signup_terms_test_() ->
    {timeout, 300, fun() ->
        F = setup(genesis),
        #{dir := Dir, actor_keypair := {Key, _}} = F,
        {ok, Network} = quod_ontology:network_identity(),
        {ok, Auth} = quod_client_auth:start_link(#{network_id => Network, node_key => Key}),
        unlink(Auth),
        Unlock = filename:join(Dir, "m1a-vault-unlock"),
        ok = quod_file:write_atomic(Unlock, crypto:strong_rand_bytes(32), 8#600),
        {ok, Vault} = quod_agent_vault:start_link(#{directory => filename:join(Dir, "vault"), unlock_file => Unlock}),
        unlink(Vault),
        try
            #{node := Node, user := UserClass, node_client := NodeClient} = m1a_foundations(F),
            m1a_signup_denials(Network, UserClass, NodeClient),
            User = m1a_signup(Network, UserClass, Node),
            #{reference := {agent_instance_ref, Ns, _, me}} = User,
            ?assertEqual({pending, account}, m1a_read(User, {account_setup, me, {0}})),
            ?assertEqual([me], m1a_read(User, {findall, me,
                {instance_of, {':',quod,{':',user,human_user}}, me}, {0}})),
            ?assertEqual(8, m1a_read(User, {gui_pending_allowance, me, {0}})),
            ?assertEqual(12, m1a_read(User, {hud_allowance, my_hud, {0}})),
            ?assertMatch({ok, _, {normalized, {read, _, {answers, _, [_]}}}}, submit_lobby(User, read,
                {can_invoke, arbitrary, maps:get(reference, User), [], Ns})),
            [?assertEqual([], m1a_read(User, {findall, true, {current_predicate, {'/', Fun, Arity}}, {0}}))
                || {Fun, Arity} <- [{space_template_hash,1}, {space_source_digest,1},
                    {space_place,3}, {gui_open,2}, {personal_instruction_accept,2},
                    {account_space_create,3}, {setup_account,4}]],
            m1a_setup_failures(User),
            First = m1a_setup(User),
            Second = m1a_setup(m1a_signup(Network, UserClass, Node)),
            Space = m2_spaces(First, Second),
            Recover = m3a_travel(First, Second, Space),
            m1a_restart_accounts([First, Second],Vault,Dir,Unlock),
            Recover()
        after stop_process(Auth), cleanup(F), stop_process(Vault) end
    end}.

m1a_seven_foundations_test_() ->
    {timeout, 300, fun() ->
        F = setup(genesis),
        #{dir := Dir, actor_keypair := {Key, _}} = F,
        {ok, Network} = quod_ontology:network_identity(),
        {ok, Auth} = quod_client_auth:start_link(#{network_id => Network, node_key => Key}),
        unlink(Auth),
        Unlock = filename:join(Dir, "m1a-vault-unlock"),
        ok = quod_file:write_atomic(Unlock, crypto:strong_rand_bytes(32), 8#600),
        {ok, Vault} = quod_agent_vault:start_link(#{directory => filename:join(Dir, "vault"), unlock_file => Unlock}),
        unlink(Vault),
        try
            #{node := Node, agent := Agent, gui := Gui, user := UserClass,
              node_client := NodeClient, catalogue := Catalogue, gui_files := GuiFiles} = m1a_foundations(F),
            {UnrelatedPublic,_}=UnrelatedPair=quod_identity:generate(),
            UnrelatedNs = <<"m1a:unrelated-agent">>,
            UnrelatedAnchor=m1a_found(UnrelatedNs,["agent_instance.pl"],
                [{instance_of,{':',quod,{':',agent,agent}},outsider},{agent_key,outsider,UnrelatedPublic,active},
                 {agent_vocabulary,<<"quod:agent">>,Agent}],
                [quod_agent_predicates]),
            Unrelated=#{reference=>{agent_instance_ref,UnrelatedNs,UnrelatedAnchor,outsider},
                keypair=>UnrelatedPair,network=>Network,parser_version=>3},
            SharedSources=[{N,m1a_complete_source(N)} || N<-[<<"quod:gui">>,<<"quod:controllers">>,<<"quod:space">>]],
            m1a_signup_denials(Network,UserClass,NodeClient),
            Allocated = [m1a_signup(Network, UserClass, Node) || _ <- [first, second]],
            [FirstAllocated,SecondAllocated] = Allocated,
            ?assertNotEqual(maps:get(reference, FirstAllocated), maps:get(reference, SecondAllocated)),
            io:format(standard_error,"M1a setup_refusals~n",[]),
            m1a_setup_failures(FirstAllocated),
            Users = [m1a_setup(U) || U <- Allocated],
            [First,Second] = Users,
            io:format(standard_error,"M1a privacy~n",[]),
            m1a_private(First, Second, UserClass, Catalogue, Unrelated),
            io:format(standard_error,"M1a controller_views~n",[]),
            m1a_controller(First,Second),
            io:format(standard_error,"M1a https~n",[]),
            m1a_https(Dir, Network, Users, Gui, UserClass, Unrelated),
            io:format(standard_error,"M1a receipts~n",[]),
            %% Setup's atomic read participants append control records. Compare
            %% the complete authored state, not their advancing ledger heights.
            ?assertEqual(SharedSources,[{N,m1a_complete_source(N)} || {N,_}<-SharedSources]),
            m1a_revocation(First,Second),
            S1=m2_spaces(First, Second),
            RecoverTravel=m3a_travel(First,Second,S1),
            m1a_restart_accounts(Users,Vault,Dir,Unlock),
            RecoverTravel(),
            m1a_receipt(Network, Node, Catalogue, Users, GuiFiles, Unrelated)
        after stop_process(Auth), cleanup(F), stop_process(Vault) end
    end}.

m1a_foundations(F = #{dir := Dir, manager := Manager}) ->
    {ok, Network} = quod_ontology:network_identity(),
    NodeAnchor = m1a_found(?NODE_NS, ["quod_node.pl"],
        [{node_identity_template, m1a_source("node_instance.pl")}], [quod_agent_predicates]),
    observe_enrollment_completion(Manager),
    m1a_register(?NODE_NS, NodeAnchor, true),
    ok = quod_namespace_manager:enroll_node(),
    await_enrollment_completion(Manager),
    {ok, Blob} = quod_identity:load_node_actor_pointer(Dir),
    {ok, #{reference := Node = {agent_instance_ref, NodeNs, NodeHistory, me}}} = quod_agent_ref:decode(Blob),
    ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(NodeNs,
        {hosts_ontology, Node, NodeNs, NodeHistory, discoverable})),
    Agent = m1a_found(<<"quod:agent">>, ["quod_agent.pl"], [], [quod_agent_predicates]),
    m1a_register(<<"quod:agent">>, Agent, false),
    GuiFiles = ["quod_gui.pl", "gui_measure.pl", "gui_scene.pl", "gui_tools.pl"],
    Gui = m1a_found(<<"quod:gui">>, GuiFiles, [], [quod_agent_predicates, quod_gui_predicates]),
    m1a_register(<<"quod:gui">>, Gui, false),
    GuiPins = [{gui_vocabulary, <<"quod:gui">>, Gui}, {measure_vocabulary, <<"quod:gui">>, Gui},
        {rendering_vocabulary, <<"quod:gui">>, Gui}, {modelling_vocabulary, <<"quod:gui">>, Gui}],
    Controllers = m1a_found(<<"quod:controllers">>, ["quod_controllers.pl"],
        [{gui_vocabulary, <<"quod:gui">>, Gui}], [quod_agent_predicates]),
    m1a_register(<<"quod:controllers">>, Controllers, false),
    Space = m1a_found(<<"quod:space">>, ["quod_space.pl"], GuiPins,
        [quod_agent_predicates]),
    m1a_register(<<"quod:space">>, Space, false),
    Pins = GuiPins ++ [{agent_vocabulary, <<"quod:agent">>, Agent},
        {controllers_vocabulary, <<"quod:controllers">>, Controllers},
        {space_vocabulary, <<"quod:space">>, Space}],
    UserClass = m1a_found(<<"quod:user">>, ["quod_user.pl"], Pins ++
        [{signup_host, Node}], [quod_agent_predicates]),
    commit_root({assertz, {root_administrator_agent, Node}}),
    NodeClient = #{reference => Node, keypair => maps:get(actor_keypair, F), network => Network, parser_version => 3},
    {ok, RegEvidence, {normalized, {committed, _, _}}} = submit_lobby(NodeClient, execute,
        {transaction, m1a_conj([
            {'::', ?ROOT_NS, {transaction, m1a_conj([
                {assertz, {system_ontology, <<"quod:user">>, UserClass}},
                {assertz, {ontology_creation_policy, <<"quod:user">>, UserClass}}])}},
            {assertz, {ontology_hosting_policy, <<"quod:user">>, UserClass}}])}),
    m1a_complete(RegEvidence),
    {ok, [#{'Rows' := Catalogue}], _} = quod_prolog:prove_ro(?ROOT_NS,
        {findall, {ontology_ref, {'N'}, {'A'}}, {system_ontology, {'N'}, {'A'}}, {'Rows'}}),
    ?assertEqual(6, length(Catalogue)),
    ?assertEqual(6, length(lists:usort([A || {ontology_ref, _, A} <- Catalogue]))),
    ?assertEqual(lists:sort([?NODE_NS, <<"quod:agent">>, <<"quod:gui">>,
        <<"quod:controllers">>, <<"quod:space">>, <<"quod:user">>]),
        lists:sort([N || {ontology_ref, N, _} <- Catalogue])),
    #{node => Node, agent => Agent, gui => Gui, user => UserClass,
      node_client => NodeClient, catalogue => Catalogue, gui_files => GuiFiles}.

m1a_source(File) ->
    {ok, Bytes} = file:read_file(filename:join([code:priv_dir(quod), "ontologies", File])), Bytes.

%% Extend the real founding journey after all original M1 assertions. Storage
%% is another user's ontology, with narrowly authored owner consent below.
m2_spaces(User=#{reference:=Owner={agent_instance_ref,Ns,Anchor,me}}, Other) ->
    C=m1a_actor_context(User), Actor=maps:get(agent,C),
    {account,_,Actor,S0,_,_,_}=maps:get(setup_result,User),
    Class=m2_space_class(),
    Offers=m1a_read(User,{gui_operations,Class,{0}}),
    ?assertEqual([create,create_exact,create_infinite],[element(2,O)||O<-Offers]),
    Create=hd(Offers),
    {Outcome,Bytes}=m2_create(C,Ns,Create,element(7,Create)),
    [{result,space,S1={entity_ref,Ns,Anchor,Id}},{result,location,{placed,S0,Near}},{result,owner,Owner}]=m1a_output(Outcome),
    %% In front of the agent: 2 m clearance plus half the default 100 m depth.
    ?assertEqual({transform,0,0,-52000,0,0,0},Near),
    ?assertEqual(Owner,m1a_read(User,{attribute,Id,owner,{0}})),
    ?assertEqual({placed,S0,{transform,0,0,0,0,0,0}},m1a_read(User,m2_space({space_location,m2_entity(User,personal),{0}}))),
    ?assertEqual({placed,S0,Near},m1a_read(User,m2_space({space_location,m2_entity(User,Id),{0}}))),
    ok=m2_assert_scene(User,S0,S1,<<"box">>),
    %% A committed per-instance ACL can refuse later entry independently of
    %% the class default used for initial placement.
    NoEntry={instance_permission,personal,space_enter,deny},
    m2_edit(User,{assertz,NoEntry}),
    m1a_failed_personal(C,m2_space({goal,{inside,S1,setelement(1,Actor,entity_ref),{transform,0,0,0,0,0,0}}})),
    m2_edit(User,{retract,NoEntry}),
    {agent_instance_ref,Foreign,ForeignAnchor,me}=maps:get(reference,Other),
    ForeignClass=m2_space_class(),
    ForeignGoal={'::',Foreign,{',',{current_ontology_identity,Foreign,ForeignAnchor},
        {gui_operation,ForeignClass,create,element(4,Create),space_create_submit,element(7,Create),{0}}}},
    Before=m2_state([Ns,Foreign]), m1a_failed_personal(C,ForeignGoal),
    ?assertEqual(Before,m2_state([Ns,Foreign])),
    m2_foreign_policy(Other,Owner,Actor),
    [ForeignCreate|_]=m1a_read(User,{'::',Foreign,{',',{current_ontology_identity,Foreign,ForeignAnchor},
        {gui_operations,ForeignClass,{0}}}}),
    {ForeignOutcome,ForeignBytes}=m2_create(C,Foreign,ForeignCreate,element(7,ForeignCreate)),
    [{result,space,ForeignSpace={entity_ref,Foreign,ForeignAnchor,ForeignId}},
     {result,location,{placed,S0,Near}},{result,owner,Owner}]=m1a_output(ForeignOutcome),
    ?assertEqual(Owner,m1a_read(Other,{attribute,ForeignId,owner,{0}})),
    ?assertEqual({placed,S0,Near},m1a_read(Other,m2_space({space_location,m2_entity(Other,ForeignId),{0}}))),
    Contents=m1a_read(User,{findall,{'E'},m2_space({space_contains,S0,{'E'}}),{0}}),
    ?assertEqual(lists:sort([S1,ForeignSpace]),lists:sort(Contents -- [setelement(1,Actor,entity_ref)])),
    ok=m2_assert_scene(User,S0,ForeignSpace,<<"box">>),
    %% Original returned values remain available to an authorized new device,
    %% after both outcome owners restart, without constructor/reaction replay.
    Fresh=C#{session=>quod_personal_agent_tests:session(maps:get(human_pair,C),maps:get(network,C))},
    Resolve=fun() -> [begin
        {ok,_,{operation_outcome,_,Recovered}}=quod_personal_agent_tests:lookup(Fresh,B),
        ?assertEqual(m1a_output(O),proplists:get_value(<<"V0">>,maps:get(bindings,Recovered)))
    end || {O,B}<-[{Outcome,Bytes},{ForeignOutcome,ForeignBytes}]] end,
    Resolve(),
    quod_outcome_result_tests:assert_no_generation(fun() ->
        [quod_outcome_result_tests:restart_outcome_owner(N)||N<-[Ns,Foreign]] end),
    Resolve(), quod_outcome_result_tests:assert_unchanged_reads([Ns,Foreign],Resolve,3),
    %% Source/anchor and destination policy failures cannot become unplaced
    %% success. The same signed operation/form path remains authoritative.
    m2_failed_creation(C,User,Ns,Create,m1a_field(element(7,Create),{space_placement,{ontology_ref,Ns,quod_simplex:genesis_hash(Ns)}},
        {at,setelement(3,S0,<<0:256>>),{transform,0,0,0,0,0,0}}),[Ns,Foreign]),
    %% A destination that denies admission refuses the creation outright.
    Deny={instance_permission,element(4,S0),space_admit,deny},
    m2_edit(User,{assertz,Deny}),
    m2_failed_creation(C,User,Ns,Create,element(7,Create),[Ns,Foreign]),
    m2_edit(User,{retract,Deny}),
    %% Failure after the foreign scope acknowledged its whole construction
    %% rolls back the local marker, source object and receiver admission.
    Baseline=m2_state([Ns,Foreign]),
    [CurrentForeign|_]=m1a_read(User,{'::',Foreign,{',',{current_ontology_identity,Foreign,ForeignAnchor},
        {gui_operations,ForeignClass,{0}}}}),
    {operation_view,Name,Subject,Revision,_,_,Values,Control,_,_}=CurrentForeign,
    Final={transaction,m1a_conj([{assertz,m2_local_staging},
        {'::',Foreign,{',',{current_ontology_identity,Foreign,ForeignAnchor},
            {gui_operation,Subject,Name,Revision,Control,Values,{0}}}},
        {fail_with_reason,m2_after_foreign_ack}])},
    {{failed,EncodedReasons},_}=m1a_personal(C,Final),
    {ok,FailureReasons}=quod_wire_term:decode_failure_reasons(EncodedReasons),
    ?assert(lists:member(m2_after_foreign_ack,FailureReasons)),
    ?assertEqual(Baseline,m2_state([Ns,Foreign])),
    ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,m2_local_staging)),
    io:format("M2 production placement/recovery qualified: ~p ~p~n",[S1,ForeignSpace]), S1.

m3a_travel(User=#{reference:={agent_instance_ref,Ns,_,me}},Other,S1) ->
    C=m1a_actor_context(User), Actor=maps:get(agent,C),
    {account,_,Actor,S0,_,_,_}=maps:get(setup_result,User),
    Enter=m3a_offer(User,S1,enter),
    {EnterResult,EnterBytes}=m2_create(C,Ns,Enter,[]),
    m3a_committed(EnterResult),
    ?assertEqual([{result,agent,Actor},{result,location,{placed,S1,{transform,0,0,0,0,0,0}}},
                  {result,revision,3}],m1a_output(EnterResult)),
    ?assertEqual(S1,m1a_read(User,{'::',<<"quod:user">>,{account_navigation,{0},[playing,edition]}})),
    ?assertEqual({navigation,3,{placed,S1,{transform,0,0,0,0,0,0}},[playing,edition]},
        m1a_read(User,{'::',<<"quod:user">>,{account_navigation,{0}}})),
    %% An old offer names the original slot, rather than rebasing itself.
    Before=m2_state([Ns]), {{failed,_},_}=m2_create(C,Ns,Enter,[]),
    ?assertEqual(Before,m2_state([Ns])),
    Class=m2_space_class(),
    [Create|_]=m1a_read(User,{gui_operations,Class,{0}}),
    {Created,_}=m2_create(C,Ns,Create,element(7,Create)),
    [{result,space,S2},{result,location,{placed,S1,_}},{result,owner,_}]=m1a_output(Created),
    m3a_enter(User,C,S2,5), m3a_enter(User,C,S1,7), m3a_enter(User,C,S0,9),
    %% A foreign owner's destination remains independently denied.
    {account,_,_,ForeignS0,_,_,_}=maps:get(setup_result,Other),
    Unchanged=m2_state([Ns,element(2,ForeignS0)]),
    m1a_failed_personal(C,m2_space({goal,{inside,ForeignS0,setelement(1,Actor,entity_ref),
        {transform,0,0,0,0,0,0}}})),
    ?assertEqual(Unchanged,m2_state([Ns,element(2,ForeignS0)])),
    Leave=m3a_offer(User,S0,leave),
    {Left,_}=m2_create(C,Ns,Leave,[]),m3a_committed(Left),
    ?assertEqual([{result,agent,Actor},{result,location,unplaced},{result,revision,10}],m1a_output(Left)),
    ?assertEqual(unplaced,m1a_read(User,m2_space({space_location,m2_entity(User,personal),{0}}))),
    ?assertEqual({navigation,10,unplaced,[playing,edition]},m1a_read(User,{'::',<<"quod:user">>,{account_navigation,{0}}})),
    ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},submit_lobby(Other,read,
        {'::',Ns,{',',{current_ontology_identity,Ns,element(3,S0)},{'::',<<"quod:user">>,{account_navigation,{0}}}}})),
    m3a_enter(User,C,S0,11),
    m3a_entry_conflict(User,C,S0,S1),
    Fresh=C#{session=>quod_personal_agent_tests:session(maps:get(human_pair,C),maps:get(network,C))},
    Resolve=fun() ->
        {ok,_,{operation_outcome,_,Recovered}}=quod_personal_agent_tests:lookup(Fresh,EnterBytes),
        ?assertEqual(m1a_output(EnterResult),proplists:get_value(<<"V0">>,maps:get(bindings,Recovered)))
    end,
    Resolve(), quod_outcome_result_tests:assert_unchanged_reads([Ns],Resolve,3),
    ?assertEqual({placed,S0,{transform,0,0,0,0,0,0}},m1a_read(User,m2_space({space_location,m2_entity(User,personal),{0}}))),
    m3a_recursive(User,C,S0,S1,S2),
    FinalState=m2_state([Ns]),
    io:format("M3a signed same-agent route: ~p -> ~p -> ~p -> ~p -> ~p~n",[S0,S1,S2,S1,S0]),
    fun() ->
    %% The same vault keys and the original signed request resolve after the
    %% runtime and outcome owners restart, without another travel submission.
    ?assertEqual(FinalState,m2_state([Ns])),
    ?assertEqual({placed,S0,{transform,0,0,0,0,0,0}},m1a_read(User,m2_space({space_location,m2_entity(User,personal),{0}}))),
    {agent_instance_ref,_,_,Personal}=Actor,
    ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{space_assignment_state,Personal,11,S0})),
    Resolve(),
    ok=quod_ct:write_evidence_json("QUOD_M3A_EVIDENCE","same-agent-route",
        #{schema => <<"m3a-same-agent-v1">>,
          agent => quod_client_goal_parser:value_text(Actor),
          route => [quod_client_goal_parser:value_text(S)||S<-[S0,S1,S2,S1,S0,unplaced,S0]],
          original_enter_request_sha256 => binary:encode_hex(crypto:hash(sha256,EnterBytes)),
          original_enter_result => quod_client_goal_parser:value_text(m1a_output(EnterResult)),
          final_assignment_revision => 11,
          original_outcome_after_owner_restart => true,
          exact_state_after_owner_restart => true})
    end.

m3a_entry_conflict(User,C,S0,S1) ->
    Ns=element(2,S0),Actor=maps:get(agent,C),
    {ok,ActorBlob}=quod_wire_term:encode_canonical(Actor),Principal={agent,ActorBlob},
    Permission={instance_permission,personal,space_leave,deny},
    Enter=m3a_offer(User,S1,enter),
    {Numbered,_,_}=erlog_int:term_instance(m2_create_goal(C,Ns,Enter,[]),0),
    {ok,TravelGoal}=quod_wire_term:encode_canonical(Numbered),
    Engine=quod_reg:where({quod_prolog,Ns}),Parent=self(),Token=make_ref(),
    %% Pause only the proof worker at the existing sealed-plan checkpoint.
    %% The ontology owner stays responsive and commits the competing grant edit.
    Observe=fun(armed,{in,{'$gen_cast',{public_proof,_,_,execute,Goal,Request}}},_)
                  when is_tuple(Request),tuple_size(Request)=:=8,
                       element(1,Request)=:=proof_request,element(3,Request)=:=Principal ->
                   case quod_wire_term:encode_canonical(Goal) of
                       {ok,TravelGoal}->checkpoint;
                       _->armed
                   end;
               (checkpoint,{in,{'$gen_call',{Worker,_},
                      {checkpoint_and_release_proof_snapshot,_,_}}},_) ->
                   true=erlang:suspend_process(Worker),
                   Parent ! {entry_checkpoint,Token,Worker},done;
               (State,_,_)->State end,
    ok=sys:install(Engine,{Observe,armed}),
    {Caller,Monitor}=spawn_monitor(fun()->Parent ! {entry_conflict,Token,m2_create(C,Ns,Enter,[])} end),
    try
        Proof=receive {entry_checkpoint,Token,P}->P;
                      {entry_conflict,Token,{Early,_}}->error({entry_not_checkpointed,Early})
        after 5000 -> error(entry_proof_not_prepared) end,
        try
            Before=m2_state([Ns]),m2_edit(User,{assertz,Permission}),
            _=sys:replace_state(Engine,fun(State)->true=erlang:resume_process(Proof),State end),
            {Outcome,_}=receive {entry_conflict,Token,R}->R
            after 10000 -> error(entry_conflict_not_resolved) end,
            case Outcome of
                {failed,Blob} ->
                    {ok,Reasons}=quod_wire_term:decode_failure_reasons(Blob),
                    ?assert(lists:member(conflict_retry,Reasons));
                {error,conflict_retry} -> ok;
                Other -> error({entry_conflict_accepted,Other})
            end,
            ?assertEqual(Before,m2_state([Ns])),
            ?assertEqual({placed,S0,{transform,0,0,0,0,0,0}},m1a_read(User,m2_space({space_location,m2_entity(User,personal),{0}})))
        after catch sys:replace_state(Engine,
            fun(State)->catch erlang:resume_process(Proof),State end) end
    after
        exit(Caller,kill),
        receive {'DOWN',Monitor,process,Caller,_}->ok after 1000 -> error(entry_caller_alive) end,
        ok=sys:remove(Engine,Observe),
        m2_edit(User,{retract,Permission})
    end.

m3a_recursive(User,C,S0,S1,S2) ->
    Ns=element(2,S0), I0=element(4,S0), I1=element(4,S1), I2=element(4,S2),
    T1={transform,1300,-700,2900,17,43,89}, T2={transform,-1900,1100,2300,31,67,113},
    Old1=m1a_read(User,{attribute,I1,transform,{0}}),
    Old2=m1a_read(User,{attribute,I2,transform,{0}}),
    m2_edit(User,{transaction,m1a_conj([
        m2_space({space_represent,S1,solid,Old1,none,contents,T1,none}),
        m2_space({space_represent,S2,solid,Old2,none,contents,T2,none})])}),
    Class=m2_space_class(),
    [Create|_]=m1a_read(User,{gui_operations,Class,{0}}),
    Fields=m1a_field(element(7,Create),{space_placement,{ontology_ref,Ns,quod_simplex:genesis_hash(Ns)}},{at,S2,{transform,0,0,0,0,0,0}}),
    {LeafResult,_}=m2_create(C,Ns,Create,Fields),
    m3a_committed(LeafResult),
    [{result,space,Leaf}|_]=m1a_output(LeafResult),
    m2_edit(User,{transaction,{',',{retract,{attribute,element(4,Leaf),transform,{'_'}}},
        {assertz,{attribute,element(4,Leaf),transform,{transform,300,500,-900,23,47,71}}}}}),
    Read=fun() -> m1a_read(User,m2_space({space_projection,S0,playing,{0}})) end,
    {scene,Marks,Exposure}=Read(),
    [E1]=[E||E={exposure,_,_,S,_,_,_,_,contents}<-Exposure,S=:=S1],
    [E2]=[E||E={exposure,_,_,S,_,_,_,_,contents}<-Exposure,S=:=S2],
    [EL]=[E||E={exposure,_,_,S,_,_,_,_,model}<-Exposure,S=:=Leaf],
    ?assertEqual(T1,element(8,E1)), ?assertEqual(T2,element(8,E2)),
    ?assertEqual(4,length(element(3,EL))),
    ?assert(lists:any(fun({mark,_,_,_,{relative,P,T},_,_,_})->P=:=element(2,E1) andalso T=:=T2;(_)->false end,Marks)),
    %% A second branch keeps its own anchored occurrence path. A colocated
    %% display/placement reference continues to produce only one occurrence.
    m2_edit(User,{transaction,m1a_conj([{assertz,{space_member,I0,S1}},{assertz,{space_member,I0,S2}}])}),
    {scene,_,Independent}=Read(),
    Leaves=[E||E={exposure,_,_,S,_,_,_,_,model}<-Independent,S=:=Leaf],
    ?assertEqual(2,length(Leaves)), ?assertEqual(2,length(lists:usort([element(2,E)||E<-Leaves]))),
    ?assertEqual(1,length([E||E={exposure,_,_,S,_,_,_,_,contents}<-Independent,S=:=S1])),
    %% A cycle is reported at its exact occurrence, without suppressing the
    %% valid independent branch or recursively expanding the ancestor again.
    m2_edit(User,{assertz,{space_member,I2,S1}}),
    {scene,_,Cycles}=Read(), ?assertEqual(2,length([E||E={exposure,_,_,_,_,_,_,_,cycle}<-Cycles])),
    m2_edit(User,{retract,{space_member,I2,S1}}),
    [ContentsRecipe]=[R||R={':-',{class_eidolon,space,_,contents,_},_}<-
        quod_prolog:read_terms("priv/ontologies/quod_space.pl")],
    ?assertMatch({ok,_,_},quod_prolog:execute(<<"quod:space">>,{retract,ContentsRecipe})),
    ?assertMatch({world_view,S0,_,[],unavailable},
        m1a_read(User,{client_world_view,I0,playing,[],{0}})),
    ?assertMatch({ok,_,_},quod_prolog:execute(<<"quod:space">>,{assertz,ContentsRecipe})),
    {scene,_,Independent}=Read(),
    %% Ordinary scene reads need no ledger evidence read. The helper's last
    %% argument is the expected read count across its three repetitions.
    quod_outcome_result_tests:assert_unchanged_reads([Ns],Read,0),
    ?assertEqual({placed,S0,{transform,0,0,0,0,0,0}},m1a_read(User,m2_space({space_location,m2_entity(User,personal),{0}}))).

m3a_offer(User,Space,Name) ->
    Offers = m1a_read(User,{gui_operations,Space,{0}}),
    case [O || O <- Offers, element(2,O) =:= Name] of
        [Offer] -> Offer;
        _ -> error({missing_space_operation,Name,Space,[element(2,O) || O <- Offers]})
    end.

m3a_enter(User,C,Space,Revision) ->
    Enter=m3a_offer(User,Space,enter),
    {Result,_}=m2_create(C,element(2,Space),Enter,[]),
    m3a_committed(Result),
    ?assertEqual([{result,agent,maps:get(agent,C)},
        {result,location,{placed,Space,{transform,0,0,0,0,0,0}}},{result,revision,Revision}],m1a_output(Result)).
m3a_committed({committed,_,_}) -> ok;
m3a_committed({failed,Blob}) ->
    {ok,Reasons}=quod_wire_term:decode_failure_reasons(Blob),
    io:format("Signed operation refusal: ~tp~n",[Reasons]),error({m3a_failed,Reasons});
m3a_committed(Other) -> error({m3a_not_committed,element(1,Other)}).

m2_edit(User,Goal) ->
    {Numbered,_,_}=erlog_int:term_instance(Goal,0),
    {ok,Evidence,{normalized,{committed,_,_}}}=submit_lobby(User,execute,Numbered),m1a_complete(Evidence).
m2_state(Namespaces) ->
    [{N,m2_rows(N,{'I'},{instance_of,{':',quod,{':',space,space}},{'I'}}),
        m2_rows(N,{attribute,{'I'},{'K'},{'V'}},{',',{instance_of,{':',quod,{':',space,space}},{'I'}},{attribute,{'I'},{'K'},{'V'}}}),
        m2_rows(N,{assignment,{'I'},{'R'},{'D'}},{space_assignment_state,{'I'},{'R'},{'D'}}),
        m2_rows(N,{admission,{'S'},{'I'},{'R'}},{space_placement,{'S'},{'I'},{'R'}})} || N<-Namespaces].
m2_rows(Ns,Template,Goal) ->
    {ok,[#{'Rows':=Rows}],_}=quod_prolog:prove_ro(Ns,{findall,Template,Goal,{'Rows'}}),lists:sort(Rows).
m2_create(C,Ns,Offer,Fields) ->
    m1a_personal(C,m2_create_goal(C,Ns,Offer,Fields)).
m2_create_goal(C,Ns,{operation_view,Name,Subject,Revision,_,_,_,Control,_,_},Fields) ->
    Goal={gui_operation,Subject,Name,Revision,Control,Fields,{0}},
    Anchor=quod_simplex:genesis_hash(Ns),Exact={',',{current_ontology_identity,Ns,Anchor},Goal},
    case maps:get(namespace,C) of Ns->Exact; _->{'::',Ns,Exact} end.
m2_failed_creation(C,_User,Ns,Offer,Fields,Owners) ->
    Before=m2_state(Owners),{{failed,_},_}=m2_create(C,Ns,Offer,Fields),?assertEqual(Before,m2_state(Owners)).
m2_assert_scene(User,Space,Subject,Kind) ->
    {world_view,Space,_,Marks,nonphysical}=m1a_read(User,{client_world_view,element(4,Space),playing,[],{0}}),
    {entity_ref,Ns,Anchor,Entity}=Subject,
    [Root]=[Id||{mark,Id,<<"group">>,[],_,_,_,{depicts,Ns0,A0,E0}}<-Marks,
        {Ns0,A0,E0}=:={Ns,Anchor,Entity}],
    ?assert(lists:any(fun({mark,_,K,_,{relative,P,_},_,_,_})->K=:=Kind andalso P=:=Root;(_)->false end,Marks)),ok.
m2_foreign_policy(Other=#{reference:={agent_instance_ref,Ns,Anchor,me}},Owner,Actor) ->
    Class=m2_space_class(),
    {account,_,_,PrivateSpace,_,_,_}=maps:get(setup_result,Other),
    %% Only creation discovery, its request and owner callbacks are delegated.
    Grants=[{can_invoke,{',',{current_ontology_identity,Ns,Anchor},G},Principal,{'_'},Ns}
        || {Principal,G}<-[{Owner,{gui_operations,Class,{'_'}}},
            {Owner,{gui_operation_classes,{'_'}}},
            {Owner,{client_menu,Class,{'_'}}},
            {Owner,{gui_menu_source,{':',<<"quod:space">>,space},{'_'}}},
            {Actor,{gui_operation,Class,create,{'_'},space_create_submit,{'_'},{'_'}}}]] ++
        [{can_invoke,{'_'},Principal,[<<"quod:space">>|{'_'}],Ns} || Principal <- [Owner,Actor]],
    m2_edit(Other,{transaction,m1a_conj([
        {assertz,{instance_permission,element(4,PrivateSpace),space_admit,deny}}|
        [{assertz,G}||G<-Grants]])}).

m2_space_class() -> {class_ref,<<"quod:space">>,quod_simplex:genesis_hash(<<"quod:space">>),space}.
m2_space(Goal) -> {'::',<<"quod:space">>,Goal}.
m2_entity(#{reference:={agent_instance_ref,Ns,Anchor,_}},Id) -> {entity_ref,Ns,Anchor,Id}.

m1a_complete_source(Ns) ->
    {ok,[#{'Chunks':=Chunks}],_}=quod_prolog:prove_ro(Ns,
        {findall,{'Chunk'},{prolog_introspection,{chunks,16384},{'Chunk'}},{'Chunks'}}),
    Chunks.

m1a_found(Ns, Files, Terms, Modules) ->
    Sources = [{source_file, list_to_binary(filename:join([code:priv_dir(quod), "ontologies", File]))} || File <- Files],
    true = quod_reg:subscribe({runtime, Ns}),
    try
        {ok, [#{'Anchor' := Anchor}], _} = quod_prolog:execute(?ROOT_NS,
            {create_ontology, Ns, Sources ++ [{terms, Terms}, {external_predicate_modules, Modules}], {'Anchor'}}),
        ok = await_enrolled_identity({Ns, Anchor}, quod_time:mono_ms() + 10000),
        {ok, Expected} = quod_predicates:module_manifest(Modules),
        {ok, [#{'Profile' := Expected}], _} = quod_prolog:prove_ro(Ns, {external_predicate_modules, {'Profile'}}),
        ?assertEqual(Anchor, quod_simplex:genesis_hash(Ns)), Anchor
    after quod_reg:unsubscribe({runtime, Ns}) end.

m1a_register(Ns, Anchor, Creation) ->
    Goals = [{assertz, {system_ontology, Ns, Anchor}}] ++
        case Creation of true -> [{assertz, {ontology_creation_policy, Ns, Anchor}}]; false -> [] end,
    commit_root({transaction, m1a_conj(Goals)}).

m1a_signup_denials(Network, UserClass, NodeClient) ->
    {Public,_} = Pair = quod_identity:generate(), Token = crypto:strong_rand_bytes(32),
    Applicant = #{reference=>{agent_instance_ref,<<"quod:user">>,UserClass,{signup,Public}},
        keypair=>Pair,network=>Network,parser_version=>3},
    Name = signup_namespace(Token),
    [begin
        ?assertMatch({ok,_,{normalized,{failed,_}}}, submit_lobby(Applicant,execute,{signup,Token,Wrong,{0}})),
        ?assertEqual({ok,not_hosted},quod_ontology:local_state(Wrong))
     end || Wrong <- [<<"quod:reserved-signup-test">>,signup_namespace(crypto:strong_rand_bytes(32))]],
    [ ?assertMatch({ok,_,{normalized,{failed,_}}},submit_lobby(Applicant,execute,Bad))
        || Bad <- [{assertz,forbidden_account_write},{'::',?ROOT_NS,{assertz,{root_administrator_agent,{agent_instance_ref,Name,<<0:256>>,me}}}}]],
    %% The existing atomic transition includes the hosting receiver. With its
    %% committed delegation absent, allocation, receipt and intention all roll back.
    Policy = {ontology_hosting_policy,<<"quod:user">>,UserClass},
    {ok,Evidence,{normalized,{committed,_,_}}} = submit_lobby(NodeClient,execute,{retract,Policy}),
    m1a_complete(Evidence),
    try
        ?assertMatch({ok,_,{normalized,{failed,_}}},submit_lobby(Applicant,execute,{signup,Token,Name,{0}})),
        ?assertEqual({ok,not_hosted},quod_ontology:local_state(Name)),
        ?assertMatch({fail,_},quod_prolog:prove_ro(<<"quod:user">>,{enrollment_receipt,Public,Token,{'_'}})),
        ?assertEqual(false,desired_has_content(Name))
    after
        {ok,Restore,{normalized,{committed,_,_}}} = submit_lobby(NodeClient,execute,{assertz,Policy}),
        m1a_complete(Restore)
    end.

m1a_signup(Network, UserClass, Node) ->
    {Public, _} = Pair = quod_identity:generate(), Token = crypto:strong_rand_bytes(32),
    Applicant = #{reference => {agent_instance_ref, <<"quod:user">>, UserClass, {signup, Public}},
        keypair => Pair, network => Network, parser_version => 3},
    Name = signup_namespace(Token),
    true = quod_reg:subscribe({runtime, Name}),
    try
        Request = lobby_user_request(Applicant, execute, {signup, Token, Name, {0}}),
        {ok, Evidence, {normalized, {committed, [Binding], _}}} = m1a_submit(Request),
        {ok, [{_, Owner = {agent_instance_ref, Name, Anchor, me}}]} = quod_client_result:decode_binding(Binding),
        m1a_complete(Evidence),
        ok = await_enrolled_identity({Name, Anchor}, quod_time:mono_ms() + 10000),
        ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Name, {signup_origin, <<"quod:user">>, UserClass, Token})),
        ?assertMatch({ok, _, {operation_outcome, _, #{status := committed}}},
            resolve_lobby_request(element(1, Request), element(2, Request))),
        User = Applicant#{reference => Owner, signup_request => Request, signup_token => Token, signup_principal => maps:get(reference, Applicant), hosting_node => Node},
        ?assertEqual(unplaced, m1a_read(User, {'::', <<"quod:space">>,
            {space_location, {entity_ref, Name, Anchor, personal}, {0}}})), User
    after quod_reg:unsubscribe({runtime, Name}) end.

m1a_setup(User = #{reference := Owner = {agent_instance_ref, Ns, Anchor, me}}) ->
    {prepared, Storage, _Node, Custody = {prepared_key,Key,_}} = m1a_read(User, {'::', <<"quod:user">>, {account_setup_preparation, {0}}}),
    ?assertEqual({ontology_ref, Ns, Anchor}, Storage),
    Subject = {entity_ref, Ns, Anchor, me},
    {operation_view, setup, Subject, Revision, _, _, _, Button, _, _} =
        m1a_read(User, {gui_operation_view, Subject, setup, {0}}),
    {prepared_key, Key, Receipt} = Custody,
    Fields = [{field, setup_key, Key}, {field, setup_receipt, Receipt}],
    ?assertMatch({ok, _, {normalized, {failed, _}}}, submit_lobby(User, execute,
        {gui_operation, setelement(3, Subject, <<0:256>>), setup, Revision, Button, Fields, {0}})),
    Request = lobby_user_request(User, execute,
        {gui_operation, Subject, setup, Revision, Button, Fields, {0}}),
    {ok, Evidence, {normalized, {committed, [Binding], _}}} = m1a_submit(Request),
    m1a_complete(Evidence),
    {ok, [{_, [{result, setup, Result = {account, Owner, Agent, Room = {entity_ref, Ns, Anchor, Space}, Storage, Key, _}}]}]} =
        quod_client_result:decode_binding(Binding),
    ?assertNotEqual(Owner, Agent),
    ?assertEqual(Result, m1a_read(User, {'::', <<"quod:user">>, {account_setup_state, {0}}})),
    ?assertEqual(unplaced, m1a_read(User, {'::', <<"quod:space">>, {space_location, {entity_ref, Ns, Anchor, Space}, {0}}})),
    ?assertMatch({placed, Room, {transform, 0,0,0,0,0,0}}, m1a_read(User, {'::', <<"quod:space">>, {space_location, {entity_ref, Ns, Anchor, personal}, {0}}})),
    ?assertEqual(Owner, m1a_read(User, {attribute, Space, owner, {0}})),
    QualifiedClass = {class_ref,Ns,Anchor,{':',quod,{':',space,space}}},
    ?assertEqual([create,create_exact,create_infinite],
        [element(2,Offer) || Offer <- m1a_read(User,{gui_operations,QualifiedClass,{0}})]),
    Class = m2_space_class(),
    ?assert(lists:member(Class,m1a_read(User,{gui_operation_classes,{0}}))),
    ?assertMatch({menu,_},m1a_read(User,{client_menu,Class,{0}})),
    ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},submit_lobby(User,read,
        {client_menu,setelement(3,Class,<<0:256>>),{0}})),
    {ok,_,{normalized,{read,NavigationReads,{answers,_,[_]}}}} =
        submit_lobby(User,read,{'::',<<"quod:user">>,{account_navigation,{0}}}),
    Dependencies = [{dependency,N,A,H} || {N,A,H,_} <- NavigationReads],
    ?assertMatch({world_view,Room,_,[],nonphysical},
        m1a_read(User,{client_world_view,Space,playing,Dependencies,{0}})),
    ?assertEqual(Room,m1a_read(User,{'::', <<"quod:user">>, {account_navigation,{0},[playing,edition]}})),
    {ok,[#{'G':=GuiPin}],_}=quod_prolog:prove_ro(Ns,{rendering_vocabulary,<<"quod:gui">>,{'G'}}),
    {ok,ChangedPin,{normalized,{committed,_,_}}}=submit_lobby(User,execute,
        {transaction,{',',{retract,{rendering_vocabulary,<<"quod:gui">>,GuiPin}},
                         {assertz,{rendering_vocabulary,<<"quod:gui">>,<<0:256>>}}}}),
    m1a_complete(ChangedPin),
    ?assertMatch({world_view,Room,_,[],unavailable},m1a_read(User,{client_world_view,Space,playing,[],{0}})),
    {ok,RestoredPin,{normalized,{committed,_,_}}}=submit_lobby(User,execute,
        {transaction,{',',{retract,{rendering_vocabulary,<<"quod:gui">>,<<0:256>>}},
                         {assertz,{rendering_vocabulary,<<"quod:gui">>,GuiPin}}}}),
    m1a_complete(RestoredPin),
    ?assertEqual([], m1a_read(User, {'::', <<"quod:gui">>, {gui_pending_questions, {0}}})),
    ?assertEqual({complete, Result}, m1a_read(User, {'::', <<"quod:user">>, {account_setup_preparation, {0}}})),
    Resolve = fun() ->
        ?assertEqual(Result, m1a_read(User, {'::', <<"quod:user">>, {account_setup_state, {0}}})),
        ?assertMatch({ok, _, {operation_outcome, _, #{status := committed}}},
            resolve_lobby_request(element(1, Request), element(2, Request)))
    end,
    quod_outcome_result_tests:assert_unchanged_reads([Ns], Resolve, 0),
    ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {signup_origin, {'_'}, {'_'}, {'_'}})),
    ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {instance_of, {':',quod,{':',space,physical_space}}, Space})),
    User#{setup_request=>Request,setup_result=>Result,setup_custody=>Custody}.

m1a_private(First, Second, UserClass, Catalogue, PublicReader) ->
    #{reference := {agent_instance_ref, Ns, Anchor, me}} = First,
    WrongHistory=First#{reference=>{agent_instance_ref,Ns,<<0:256>>,me}},
    ?assertEqual({error,wrong_target},submit_lobby(WrongHistory,read,{account_setup_state,{0}})),
    ?assertEqual({error,wrong_target},submit_lobby(WrongHistory,execute,{assertz,forbidden_history_write})),
    ?assert(byte_size(m1a_read(First,{prolog_introspection,{source,{'/',account_setup,2}},{0}}))>0),
    Goals = [{account_setup,me,{0}},
        {personal_instruction,{'_'},{'_'},{'_'},{'_'},{'_'},{0},{1}},
        {agent_hosted,personal,{0},{1},{2}}, {agent_key,personal,{0},active},
        {gui_pending,me,{0}}, {attribute,me,controller_preferences,{0}},
        {prolog_introspection, {chunks, 16384}, {0}}],
    [begin
        Result = submit_lobby(Second, read, {'::', Ns, {',', {current_ontology_identity, Ns, Anchor}, G}}),
        ?assertMatch({ok, _, {normalized, {read, _, {failed, _}}}}, Result)
    end || G <- Goals],
    Writes = [{assertz, {attribute, me, controller_preferences, stolen}},
        {retract, {account_setup,me,{0}}},
        {assertz,{gui_pending,me,forbidden_question}},
        {assertz,{personal_instruction,forbidden_association}},
        {',',system_prolog_edit,{transaction,{assertz,forbidden_source_edit}}}],
    [ ?assertMatch({ok,_,{normalized,{failed,_}}}, submit_lobby(Second,execute,
        {'::',Ns,{',',{current_ontology_identity,Ns,Anchor},G}})) || G <- Writes],
    {ontology_ref,<<"quod:gui">>,GuiPin}=lists:keyfind(<<"quod:gui">>,2,Catalogue),
    [ ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},submit_lobby(Reader,read,
        {'::',<<"quod:gui">>,{',',{current_ontology_identity,<<"quod:gui">>,GuiPin},
          {view,<<"ontology_source">>,[{ontology_ref,Ns,Anchor}],{0}}}})) || Reader<-[Second,PublicReader]],
    Unrelated = m1a_actor_context(Second),
    [m1a_failed_personal(Unrelated,{'::',Ns,{',',{current_ontology_identity,Ns,Anchor},G}})
        || G <- Goals ++ Writes],
    ?assertMatch({ok, _, {normalized, {read, _, {failed, _}}}}, submit_lobby(Second, read,
        {'::', ?ROOT_NS, {system_source_access, {ontology_ref, <<"quod:user">>, UserClass}, {0}}})),
    [ ?assertMatch({ok, _, {normalized, {read, _, {failed, _}}}}, submit_lobby(Second, read,
        {'::', <<"quod:gui">>, {prolog_source, {ontology_ref, Private, History}, {0}}}))
      || {Private, History} <- [{Ns, Anchor}, {Ns,<<0:256>>}, {<<"quod:user">>, UserClass}]],
    ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},submit_lobby(Second,read,
        {'::',<<"quod:user">>,{enrollment_receipt,{0},{1},{2}}})),
    [?assertMatch({ok,_,{normalized,{failed,_}}},submit_lobby(Reader,execute,
        {'::',<<"quod:user">>,{assertz,{enrollment_receipt,<<0:256>>,<<0:256>>,maps:get(reference,First)}}}))
        || Reader<-[Second,PublicReader]],
    [begin
        ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},submit_lobby(PublicReader,read,
            {'::',Ns,{',',{current_ontology_identity,Ns,Anchor},G}}))
     end || G<-Goals],
    [ ?assertNotEqual(<<"quod:lobby">>, N) || {ontology_ref, N, _} <- Catalogue].

m1a_actor_context(User = #{reference:={agent_instance_ref,Ns,Anchor,me},keypair:=Pair,network:=Network}) ->
    Agent = {agent_instance_ref,Ns,Anchor,personal},
    #{namespace=>Ns,human=>maps:get(reference,User),human_pair=>Pair,agent=>Agent,
      key=>m1a_read(User,{'::',<<"quod:user">>,{personal_agent,Agent,{0}}}),network=>Network,
      session=>quod_personal_agent_tests:session(Pair,Network)}.

m1a_setup_failures(User = #{reference := Owner = {agent_instance_ref, Ns, Anchor, me}}) ->
    Preparation = {'::', <<"quod:user">>, {account_setup_preparation, {0}}},
    State = {'::', <<"quod:user">>, {account_setup_state, {0}}},
    {prepared, {ontology_ref, Ns, Anchor}, _, {prepared_key, Key, Receipt}} = Prepared = m1a_read(User, Preparation),
    ?assertEqual(Prepared, m1a_read(User, Preparation)),
    Pending = m1a_read(User, State), Subject = {entity_ref, Ns, Anchor, me},
    {operation_view, setup, Subject, Revision, _, _, _, Button, _, _} =
        m1a_read(User, {gui_operation_view, Subject, setup, {0}}),
    Setup = fun(K, R) -> {gui_operation, Subject, setup, Revision, Button,
        [{field, setup_key, K}, {field, setup_receipt, R}], {0}} end,
    Goal = Setup(Key, Receipt),
    NoChanges = fun() ->
        ?assertEqual(Pending, m1a_read(User, State)),
        ?assertEqual(unplaced, m1a_read(User, {'::', <<"quod:space">>,
            {space_location, {entity_ref, Ns, Anchor, personal}, {0}}})),
        [?assertEqual([], m1a_read(User, {findall, true, Query, {0}})) || Query <-
            [{attribute, personal, transform, {'_'}},
             {agent_hosted, personal, {'_'}, {'_'}, {'_'}},
             {instance_of, {':',quod,{':',space,space}}, {'_'}},
             {space_placement, {'_'}, {entity_ref, Ns, Anchor, personal}, {'_'}}]],
        ?assertEqual([true], m1a_read(User, {findall, true, {signup_origin, {'_'}, {'_'}, {'_'}}, {0}}))
    end,
    [begin
        ?assertMatch({ok, _, {normalized, {failed, _}}}, submit_lobby(User, execute, Setup(K, R))),
        NoChanges()
    end || {K, R} <- [{crypto:strong_rand_bytes(32), Receipt}, {Key, crypto:strong_rand_bytes(64)}]],
    %% Refuse the final acknowledgement after hosting and placement have been
    %% staged; the same atomic transaction must unwind all participants.
    [Ack] = [Clause || Clause = {':-', {acknowledge_signup, _, _}, _} <-
        quod_prolog:read_terms("priv/ontologies/quod_user.pl")],
    Refusal = {':-', {acknowledge_signup, {'_'}, {'_'}}, {fail_with_reason, injected_signup_ack_failure}},
    {ok, _, _} = quod_prolog:execute(<<"quod:user">>, {transaction, {',', {retract, Ack}, {assertz, Refusal}}}),
    try
        {ok, _, {normalized, {failed, Reasons}}} = submit_lobby(User, execute, Goal),
        {ok, Decoded} = quod_wire_term:decode_failure_reasons(Reasons),
        ?assert(lists:member(injected_signup_ack_failure, Decoded)),
        NoChanges(),
        ?assertEqual(Owner, m1a_read(User#{reference => maps:get(signup_principal, User)},
            {signup_status, maps:get(signup_token, User), {0}}))
    after
        {ok, _, _} = quod_prolog:execute(<<"quod:user">>, {transaction, {',', {retract, Refusal}, {assertz, Ack}}})
    end,
    %% The committed class owner's create/admit defaults govern the new S0.
    [Default = {':-', Head = {class_permission, space, Operation, allow}, Body}] =
        [Clause || Clause = {':-', {class_permission, space, _, allow}, _} <-
            quod_prolog:read_terms("priv/ontologies/quod_space.pl")],
    [begin
        Withheld = {':-', Head, {',', Body, {'\\=', Operation, Missing}}},
        {ok, _, _} = quod_prolog:execute(<<"quod:space">>, {transaction, {',', {retract, Default}, {assertz, Withheld}}}),
        try
            ?assertMatch({ok, _, {normalized, {failed, _}}}, submit_lobby(User, execute, Goal)),
            NoChanges()
        after
            {ok, _, _} = quod_prolog:execute(<<"quod:space">>, {transaction, {',', {retract, Withheld}, {assertz, Default}}})
        end
    end || Missing <- [create, space_admit]],
    %% Personal is already committed: its storing ACL override applies, and a
    %% staged removal of that denial cannot authorize the same setup request.
    Deny = {instance_permission, personal, space_enter, deny},
    {ok, _, {normalized, {committed, _, _}}} = submit_lobby(User, execute, {assertz, Deny}),
    try
        ?assertMatch({ok, _, {normalized, {failed, _}}}, submit_lobby(User, execute, Goal)),
        ?assertMatch({ok, _, {normalized, {failed, _}}},
            submit_lobby(User, execute, {transaction, {',', {retract, Deny}, Goal}})),
        NoChanges()
    after
        {ok, _, {normalized, {committed, _, _}}} = submit_lobby(User, execute, {retract, Deny})
    end.

m1a_controller(User = #{reference := {agent_instance_ref, Ns, Anchor, me}, keypair := Pair, network := Network},Other) ->
    Agent = {agent_instance_ref, Ns, Anchor, personal},
    C = #{namespace => Ns, human => maps:get(reference, User), human_pair => Pair,
        agent => Agent, key => m1a_read(User, {'::',<<"quod:user">>,{personal_agent,Agent,{0}}}),
        network => Network, session => quod_personal_agent_tests:session(Pair, Network)},
    Subject = {entity_ref, Ns, Anchor, me},
    Reader = #{agent => {Ns, Anchor}, key_pair => Pair, network => Network, instance => <<"me.">>},
    Parent = self(),
    Operations = spawn_link(fun() -> quod_gui_question_tests:gui_socket(Parent, #{peer => {{127,0,0,1},0}}, false) end),
    Hud = spawn_link(fun() -> quod_gui_question_tests:gui_socket(Parent, #{peer => {{127,0,0,1},0}}, false) end),
    Open = fun(Socket, Kind, Q) -> Socket ! {client, quod_gui_question_tests:gui_open_message(
        Reader, maps:get(session,C), Kind, Ns, Anchor, Q, 0)} end,
    try
        Open(Operations, gui_operations, Subject), _ = m1a_frame(Operations, <<"projection">>),
        Open(Hud, gui_hud, none), _ = m1a_frame(Hud, <<"projection">>),
        %% Retained-view renewals reuse exact owner incarnations and snapshots.
        io:format(standard_error,"M1a renew_operations~n",[]),
        m1a_renew(Operations, fun() -> Open(Operations, gui_operations, Subject) end, 3),
        m1a_renew(Hud, fun() -> Open(Hud, gui_hud, none) end, 3),
        [Offer] = m1a_read(User, {gui_operations, Subject, {0}}),
        {operation_view, controller_settings, Subject, Revision, _, _, Fields, controller_save, _, _} = Offer,
        ?assert(lists:member({field, controller_reset, false}, Fields)),
        Goal = {gui_operation, Subject, controller_settings, Revision, controller_save, Fields, {0}},
        %% The storing ontology refuses another human's settings mutation.
        ?assertMatch({ok, _, {normalized, {failed, _}}},
            submit_lobby(Other, execute, {'::',Ns,Goal})),
        {Outcome, Bytes} = m1a_personal(C, Goal),
        ?assertEqual([{result, revision, 1}], m1a_output(Outcome)),
        _ = m1a_frame(Operations, <<"refresh">>),
        Open(Operations, gui_operations, Subject), _ = m1a_frame(Operations, <<"projection">>),
        %% The old revision, invented control and mistyped/range-invalid values
        %% refuse without changing the saved revision.
        io:format(standard_error,"M1a stale_revision~n",[]),
        m1a_failed_personal(C, Goal),
        [NewOffer] = m1a_read(User, {gui_operations, Subject, {0}}),
        {operation_view, controller_settings, Subject, NewRevision, _, _, NewFields, controller_save, _, _} = NewOffer,
        [m1a_failed_personal(C, {gui_operation, Subject, controller_settings, NewRevision, Control, Values, {0}})
            || {Control,Values} <- [{invented_operation,NewFields},
                {controller_save,m1a_field(NewFields,controller_reset,<<"true">>)},
                {controller_save,m1a_field(NewFields,{controller_threshold,menu},1000)}]],
        %% Cancelling a local draft dispatches nothing. The offered revision
        %% and durable preferences stay unchanged.
        {_Unsent, _} = quod_personal_agent_tests:instruction(C,
            {gui_operation, Subject, controller_settings, NewRevision, controller_save, NewFields, {0}}),
        ?assertEqual([NewOffer], m1a_read(User, {gui_operations, Subject, {0}})),
        io:format(standard_error,"M1a reset~n",[]),
        {ResetOutcome, ResetBytes} = m1a_personal(C,
            {gui_operation, Subject, controller_settings, NewRevision, controller_save,
                m1a_field(NewFields,controller_reset,true), {0}}),
        ?assertEqual([{result, revision, 2}], m1a_output(ResetOutcome)),
        _ = m1a_frame(Operations, <<"refresh">>),
        %% A fresh authenticated session resolves original results without the
        %% originating device's local journal or dispatching another write.
        Fresh = C#{session => quod_personal_agent_tests:session(Pair,Network)},
        [ ?assertMatch({ok, _, {operation_outcome, _, #{status := committed}}},
            quod_personal_agent_tests:lookup(Fresh, Original)) || Original <- [Bytes,ResetBytes]],
        {controller_view,2,_,_} = m1a_read(User, {'::',<<"quod:user">>,{controller_preferences_view,{entity_ref,Ns,Anchor,me},{0}}}),
        Open(Operations, gui_operations, Subject), _ = m1a_frame(Operations, <<"projection">>),
        m1a_renew(Operations, fun() -> Open(Operations, gui_operations, Subject) end, 3)
    after
        Monitors = [{S,monitor(process,S)} || S <- [Operations,Hud]],
        [S ! stop || S <- [Operations,Hud]],
        [receive {'DOWN',M,process,S,normal} -> ok after 10000 -> error(view_cancellation_failed) end || {S,M} <- Monitors]
    end.

m1a_view_state(Socket) ->
    Ref = make_ref(), Socket ! {inspect,Ref},
    receive {Ref,State} -> State after 5000 -> error(view_state_missing) end.
m1a_renew(Socket, Open, Count) ->
    Before = m1a_view_state(Socket),
    Retained = [heights,anchors,owners,follows,dependency_monitors,dependency_names,local_ready,monitor,pid],
    quod_lobby_tests:assert_read_has_no_io(fun() ->
        lists:foreach(fun(_) ->
            Open(), _ = m1a_frame(Socket,<<"projection">>),
            ?assertEqual(maps:with(Retained,Before),maps:with(Retained,m1a_view_state(Socket)))
        end, lists:seq(1,Count))
    end).

m1a_field(Fields, Id, Value) ->
    [case Field of {field,Id,_} -> {field,Id,Value}; _ -> Field end || Field <- Fields].
m1a_personal(C, Goal) ->
    quod_personal_agent_tests:await_runtime_ready(maps:get(namespace,C)),
    {Instruction, Bytes} = quod_personal_agent_tests:instruction(C, Goal),
    {ok, Evidence, {normalized, Outcome}} = quod_personal_agent_tests:instruct(C, submit, Instruction),
    case Outcome of {committed,_,_} -> m1a_complete(Evidence); _ -> ok end,
    {Outcome, Bytes}.
m1a_failed_personal(C, Goal) ->
    {{failed,_}, _} = m1a_personal(C,Goal), ok.
m1a_output({committed,[Binding],_}) ->
    {ok,[{_,Value}]} = quod_client_result:decode_binding(Binding), Value.
m1a_frame(Socket, Type) ->
    receive {gui_view, Socket, #{<<"type">> := Type} = Frame} -> Frame;
            {gui_view, Socket, Unexpected} -> error({unexpected_m1a_frame,Unexpected})
    after 10000 -> error({missing_m1a_frame,Type}) end.

m1a_revocation(User=#{reference:={agent_instance_ref,Ns,Anchor,me},keypair:=Pair={Public,_},network:=Network},Other) ->
    Reader = #{agent=>{Ns,Anchor},key_pair=>Pair,network=>Network,instance=><<"me.">>},
    Session = quod_personal_agent_tests:session(Pair,Network), Parent=self(),
    Socket=spawn_link(fun()->quod_gui_question_tests:gui_socket(Parent,#{peer=>{{127,0,0,1},0}},false) end),
    Subject={entity_ref,Ns,Anchor,me},
    Open=fun(R,S)->Socket!{client,quod_gui_question_tests:gui_open_message(R,S,gui_operations,Ns,Anchor,Subject,0)} end,
    try
        #{reference:={agent_instance_ref,OtherNs,OtherAnchor,me},keypair:=OtherPair}=Other,
        WrongReader=Reader#{agent=>{OtherNs,OtherAnchor},key_pair=>OtherPair},
        Socket!{client,quod_gui_question_tests:gui_open_message(WrongReader,
            quod_personal_agent_tests:session(OtherPair,Network),gui_hud,Ns,Anchor,none,0)},
        _=m1a_frame(Socket,<<"unavailable">>),
        Open(WrongReader,quod_personal_agent_tests:session(OtherPair,Network)),
        _=m1a_frame(Socket,<<"unavailable">>),
        Open(Reader,Session),_=m1a_frame(Socket,<<"projection">>),
        KeyFact={agent_key,me,Public,active},
        {ok,Evidence,{normalized,{committed,_,_}}}=submit_lobby(User,execute,{retract,KeyFact}),
        m1a_complete(Evidence),_=m1a_frame(Socket,<<"refresh">>),
        Open(Reader,Session),_=m1a_frame(Socket,<<"unavailable">>),
        ?assertNot(maps:is_key(installed,m1a_view_state(Socket))),
        %% Restore an explicitly injected fixture revocation at the owner;
        %% the revoked principal cannot grant itself renewed authority.
        {ok,_,_}=quod_prolog:execute(Ns,{assertz,KeyFact})
    after Socket!stop end.

m1a_restart_accounts(Users,Vault,Dir,Unlock) ->
    Before=[m1a_read(U,{'::',<<"quod:user">>,{account_setup_state,{0}}})||U<-Users],
    stop_process(Vault),
    {ok,NextVault}=quod_agent_vault:start_link(#{directory=>filename:join(Dir,"vault"),unlock_file=>Unlock}),
    unlink(NextVault),
    try
        quod_outcome_result_tests:assert_no_generation(fun()->
            [begin
                Sup=quod_reg:where({quod_ns,Ns}),
                ok=supervisor:terminate_child(Sup,quod_runtime),
                {ok,_}=supervisor:restart_child(Sup,quod_runtime),
                quod_outcome_result_tests:restart_outcome_owner(Ns),
                quod_personal_agent_tests:await_runtime_ready(Ns)
             end || #{reference:={agent_instance_ref,Ns,_,_}}<-Users]
        end),
        ?assertEqual(Before,[m1a_read(U,{'::',<<"quod:user">>,{account_setup_state,{0}}})||U<-Users]),
        [begin
            ?assertEqual(Result,m1a_read(U,{'::',<<"quod:user">>,{account_setup_state,{0}}})),
            ?assertMatch({ok,_,{operation_outcome,_,#{status:=committed}}},
                resolve_lobby_request(element(1,Original),element(2,Original))),
            Ready=quod_runtime:stats(Ns),
            quod_lobby_tests:assert_read_has_no_io(fun()->
                [begin
                    ?assertEqual(ok,quod_client_goal_target:available({Ns,Anchor})),
                    ?assertEqual({complete,Result},m1a_read(U,{'::',<<"quod:user">>,{account_setup_preparation,{0}}}))
                 end || _<-lists:seq(1,3)]
            end),
            After=quod_runtime:stats(Ns),
            ?assertEqual(maps:get(reconciles,Ready),maps:get(reconciles,After)),
            %% A new offered operation exercises the original encrypted key
            %% after both custody/runtime and source/outcome owners restarted.
            C=m1a_actor_context(U), Subject={entity_ref,Ns,Anchor,me},
            {controller_view,Previous,_,_}=m1a_read(U,{'::',<<"quod:user">>,{controller_preferences_view,{entity_ref,Ns,Anchor,me},{0}}}),
            [{operation_view,controller_settings,Subject,Revision,_,_,Fields,controller_save,_,_}]=
                m1a_read(U,{gui_operations,Subject,{0}}),
            {Outcome,_}=m1a_personal(C,{gui_operation,Subject,controller_settings,Revision,controller_save,
                m1a_field(Fields,controller_reset,true),{0}}),
            ?assertEqual([{result,revision,Previous+1}],m1a_output(Outcome)),
            ?assertMatch({controller_view,_,_,_},m1a_read(U,{'::',<<"quod:user">>,{controller_preferences_view,{entity_ref,Ns,Anchor,me},{0}}})),
            ?assertEqual(Result,m1a_read(U,{'::',<<"quod:user">>,{account_setup_state,{0}}}))
         end || U=#{reference:={agent_instance_ref,Ns,Anchor,_},setup_request:=Original,setup_result:=Result}<-Users]
    after stop_process(NextVault) end.

%% The real client endpoint and browser signing/operation modules are exercised
%% under Node Web Crypto with ordinary TLS verification and disposable keys.
m1a_https(Dir, Network, Users, Gui, UserClass, PublicReader) ->
    {ok,_} = application:ensure_all_started(ssl),
    {ok,_} = application:ensure_all_started(cowboy),
    {ok,Cursor} = quod_client_cursor:start_link(), unlink(Cursor),
    {ok,Tls} = quod_client_tls:ensure(Dir),
    Listener = quod_m1a_client_listener,
    {ok,started} = quod_http_listener:start(#{name=>Listener,ip=>{127,0,0,1},port=>0,
        routes=>quod_client:routes(),stream_handlers=>[quod_http_headers_h],tls=>Tls}),
    try
        PortNumber = ranch:get_port(Listener),
        PublicCert = maps:get(cert,Tls),
        CaPath = filename:join(Dir,"m1a-public-ca.pem"),
        ok = file:write_file(CaPath,public_key:pem_encode([{'Certificate',PublicCert,not_encrypted}])),
        Actors = [begin
            #{reference := {agent_instance_ref,N,A,me},keypair := {Public,Seed}} = U,
            #{agent=>#{namespace=>N,anchor=>m1a_b64(A),instanceText=><<"me.">>},
              public_key=>m1a_b64(Public),seed=>m1a_b64(Seed)}
        end || U <- Users],
        [Owner|_] = Users, {agent_instance_ref,Ns,Anchor,me} = maps:get(reference,Owner),
        Key = m1a_read(Owner,{'::',<<"quod:user">>,{personal_agent,{agent_instance_ref,Ns,Anchor,personal},{0}}}),
        Origin = list_to_binary("https://127.0.0.1:" ++ integer_to_list(PortNumber)),
        #{reference:={agent_instance_ref,PublicNs,PublicAnchor,outsider},keypair:={ReaderKey,ReaderSeed}}=PublicReader,
        ReaderConfig=#{agent=>#{namespace=>PublicNs,anchor=>m1a_b64(PublicAnchor),instanceText=><<"outsider.">>},
            public_key=>m1a_b64(ReaderKey),seed=>m1a_b64(ReaderSeed)},
        Config = #{origin=>Origin,network=>m1a_b64(Network),users=>Actors,public_reader=>ReaderConfig,gui=>m1a_b64(Gui),
            user_class=>m1a_b64(UserClass),personal_key=>m1a_b64(Key)},
        ConfigPath = filename:join(Dir,"m1a-private-actors.json"),
        ok = quod_file:write_atomic(ConfigPath,iolist_to_binary(json:encode(Config)),8#600),
        ResultPath = filename:join(Dir,"m1a-https-result.json"),
        Node = os:find_executable("node"), ?assertNotEqual(false,Node),
        Port = open_port({spawn_executable,Node},[binary,exit_status,use_stdio,stderr_to_stdout,
            {line,65536},{args,[filename:absname("client/test/godot-m1a.acceptance.mjs"),ConfigPath,ResultPath]},
            {env,[{"NODE_EXTRA_CA_CERTS",CaPath},{"NODE_TLS_REJECT_UNAUTHORIZED",false}]}]),
        try m1a_drive_https(Port),
            {ok,Result} = file:read_file(ResultPath), #{<<"passed">>:=true} = json:decode(Result),
            case os:getenv("QUOD_M1A_EVIDENCE") of
                false -> ok;
                Evidence ->
                    ok = file:write_file(Evidence ++ ".https.json",Result),
                    ok = file:write_file(Evidence ++ ".trust.json",json:encode(#{endpoint=>Origin,
                        expected_hostname=><<"127.0.0.1">>,certificate_sha256=>binary:encode_hex(crypto:hash(sha256,PublicCert)),
                        network=>binary:encode_hex(Network)})),
                    ok = file:write_file(Evidence ++ ".ca.pem",public_key:pem_encode([{'Certificate',PublicCert,not_encrypted}]))
            end
        after catch port_close(Port),file:delete(ConfigPath) end
    after quod_http_listener:stop(Listener),stop_process(Cursor) end.
m1a_b64(Bytes) -> base64:encode(Bytes,#{mode=>urlsafe,padding=>false}).
m1a_drive_https(Port) ->
    receive
        {Port,{data,{eol,<<"{",_/binary>>=Line}}} ->
            case json:decode(Line) of
                #{<<"phase">>:=<<"settle">>,<<"request">>:=Encoded} ->
                    Bytes = base64:decode(Encoded,#{mode=>urlsafe,padding=>false}),
                    {ok,#{goal_text:=Text,parser_version:=Parser}} = quod_client_goal:decode(Bytes),
                    {ok,#{goal:={'::',<<"quod:user">>,{{'$quod_symbol',<<"personal_instruction_accept">>},TargetBytes,_}}}} =
                        quod_client_goal_parser:parse(Text,Parser),
                    {ok,#{operation_ref:=Operation,request:=#{agent_namespace:=Ns}}} =
                        quod_client_goal:request_identity(TargetBytes),
                    ?assertMatch(#{operation_state:=terminal},quod_ct:await_operation_complete(Ns,Operation,10000)),
                    true = port_command(Port,<<"{\"ready\":true}\n">>),m1a_drive_https(Port);
                #{<<"phase">>:=<<"done">>} ->
                    true = port_command(Port,<<"{\"ready\":true}\n">>),
                    receive {Port,{exit_status,Exit}} -> ?assertEqual(0,Exit)
                    after 10000 -> error(https_client_exit_missing) end
            end;
        {Port,{data,{_,Line}}} -> io:format("~s~n",[Line]),m1a_drive_https(Port);
        {Port,{exit_status,Exit}} -> error({https_client_failed,Exit})
    after 60000 -> error(https_client_event_missing) end.

m1a_receipt(Network, Node, Catalogue, Users, GuiFiles, PublicReader) ->
    case os:getenv("QUOD_M1A_EVIDENCE") of
        false -> ok;
        Path ->
            Sources = [#{file => list_to_binary(F), sha256 => binary:encode_hex(crypto:hash(sha256, m1a_source(F)))}
                || F <- lists:usort(GuiFiles ++ ["quod_space.pl", "common_predicates.pl", "construction.pl", "material_policy.pl", "gui_forms.pl", "geometry_schema.pl", "quod_node.pl", "node_instance.pl", "quod_agent.pl", "quod_controllers.pl", "quod_user.pl", "quod_root.pl"])],
            Rows = [#{namespace => N, anchor => binary:encode_hex(A)} || {ontology_ref, N, A} <- Catalogue],
            Accounts = [quod_client_goal_parser:value_text(m1a_read(U, {'::',<<"quod:user">>,{account_setup_state,{0}}})) || U <- Users],
            Profiles = [begin
                {ok, [#{'Profile' := Profile}], _} = quod_prolog:prove_ro(N, {external_predicate_modules, {'Profile'}}),
                #{namespace => N, modules => [#{module => M, sha256 => binary:encode_hex(H)} || {M, H} <- Profile]}
            end || N <- lists:sort(quod_simplex:namespaces())],
            Operations = [#{owner=>quod_client_goal_parser:value_text(maps:get(reference,U)),
                signup=>m1a_request_receipt(maps:get(signup_request,U)),
                setup=>m1a_request_receipt(maps:get(setup_request,U)),
                custody=>quod_client_goal_parser:value_text(maps:get(setup_custody,U))} || U<-Users],
            ?assertEqual(11, length(quod_simplex:namespaces())),
            Orders = #{root => [<<"quod_root.pl">>], node => [<<"quod_node.pl">>], agent => [<<"quod_agent.pl">>],
                gui => [list_to_binary(F) || F <- GuiFiles], controllers => [<<"quod_controllers.pl">>],
                space => [<<"quod_space.pl">>], user => [<<"quod_user.pl">>],
                private_account => <<"terms">>,
                startup_base => [<<"common_predicates.pl">>,<<"construction.pl">>,
                    <<"material_policy.pl">>,<<"gui_forms.pl">>,<<"geometry_schema.pl">>]},
            ok = file:write_file(Path, json:encode(#{network => binary:encode_hex(Network),
                node => quod_client_goal_parser:value_text(Node), catalogue => Rows, sources => Sources, accounts => Accounts,
                source_order => Orders, predicate_profiles => Profiles, signed_operations=>Operations,
                verified_checks=>[unchanged_views_no_rebuild_or_io,unchanged_outcomes_no_replay_or_io,
                    unchanged_readiness_no_reconcile_or_io,restart_no_constructor_or_reaction_replay,
                    original_vault_keys_sign_new_operation_after_restart],
                public_reader=>quod_client_goal_parser:value_text(maps:get(reference,PublicReader)),
                counts => #{shared_foundations => 7, catalogue_rows => 6, node_instances => 1,
                    user_histories => 2, personal_agents => 2, unrelated_agent_histories=>1, space_instances => 2, total_histories => 11}}))
    end.

m1a_request_receipt({Bytes,Signature}) ->
    {ok,#{operation_ref:=Operation}}=quod_client_goal:request_identity(Bytes),
    #{operation=>quod_client_goal_parser:value_text(Operation),
      request_sha256=>binary:encode_hex(crypto:hash(sha256,Bytes)),
      signature_sha256=>binary:encode_hex(crypto:hash(sha256,Signature))}.

m1a_conj([Goal]) -> Goal;
m1a_conj([Goal | Rest]) -> {',', Goal, m1a_conj(Rest)}.
m1a_submit({Bytes, Signature}) ->
    quod_client_goal_ingress:submit(Bytes, Signature).

m1a_read(User, Goal) ->
    {ok, _, {normalized, {read, _, {answers, _, [Binding]}}}} = submit_lobby(User, read, Goal),
    {_, Variables, _} = erlog_int:term_instance(Goal, 0),
    {Index} = orddict:fetch(0, Variables),
    Name = <<"V", (integer_to_binary(Index))/binary>>,
    {ok, Bindings} = quod_client_result:decode_binding(Binding),
    {Name, Value} = lists:keyfind(Name, 1, Bindings), Value.
m1a_complete(Evidence) ->
    Op = quod_client_goal:operation_ref(Evidence),
    ?assertMatch(#{operation_state := terminal}, quod_ct:await_operation_complete(element(2, Op), Op, 10000)).

automatic_founder_enrollment_and_restart_test_() ->
    {timeout, 90, fun() ->
        F = setup(automatic),
        #{dir := Dir, manager := Manager, actor_keypair := {Key, _}} = F,
        {ok, Network} = quod_ontology:network_identity(),
        {ok, Auth} = quod_client_auth:start_link(#{network_id => Network, node_key => Key}),
        unlink(Auth),
        true = quod_reg:subscribe({node_actor, node}),
        try
            observe_enrollment_completion(Manager),
            NodeAnchor = quod_simplex:genesis_hash(?NODE_NS),
            {ok, Template} = file:read_file(filename:join(code:priv_dir(quod),
                                                         "ontologies/node_instance.pl")),
            {ok, _, _} = quod_prolog:execute(?NODE_NS,
                {assertz, {node_identity_template, Template}}),
            commit_root({transaction, {',',
                {assertz, {system_ontology, ?NODE_NS, NodeAnchor}},
                {assertz, {ontology_creation_policy, ?NODE_NS, NodeAnchor}}}}),
            ok = quod_namespace_manager:enroll_node(),
            await_enrollment_completion(Manager),
            {ok, Blob} = quod_identity:load_node_actor_pointer(Dir),
            {ok, #{identity := {Ns, Anchor}, reference := Ref}} = quod_agent_ref:decode(Blob),
            ?assertEqual({ok, {agent, Blob}}, quod_node_actor:principal()),
            ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Ns,
                {hosts_ontology, Ref, Ns, Anchor, discoverable})),
            ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(?NODE_NS,
                {node_identity_allocation, Key, Ref, Ref})),
            {ok, Before} = file:read_file(filename:join(Dir, "node.actor")),
            stop_process(Manager),
            application:set_env(quod, node_addr, {"127.0.0.1", 24567}),
            {ok, NextManager} = quod_namespace_manager:start_link(),
            unlink(NextManager),
            receive
                {node_actor_installed, NextManager, {ok, {agent, Blob}}} -> ok
            after 10000 -> error(retained_node_not_installed)
            end,
            ?assertEqual({ok, Blob}, quod_identity:load_node_actor_pointer(Dir)),
            ?assertEqual({ok, Before}, file:read_file(filename:join(Dir, "node.actor"))),
            ?assertEqual(complete, maps:get(node_enrollment, quod_namespace_manager:stats())),
            {ok, PointerInfo} = file:read_file_info(filename:join(Dir, "node.actor")),
            RootCommits = maps:get(committed, quod_simplex:stats(?ROOT_NS)),
            %% Through the real owner: a completed repeat spawns no enrollment
            %% worker, cannot rebuild an enrollment proof, and writes no pointer.
            1 = erlang:trace(NextManager, true, [procs, {tracer, self()}]),
            ok = quod_namespace_manager:enroll_node(),
            ?assertEqual(complete, maps:get(node_enrollment, quod_namespace_manager:stats())),
            Delivery = erlang:trace_delivered(NextManager),
            receive {trace_delivered, NextManager, Delivery} -> ok end,
            1 = erlang:trace(NextManager, false, [procs]),
            receive {trace, NextManager, spawn, _, _} -> error(unchanged_enrollment_spawned)
            after 0 -> ok end,
            ?assertEqual(RootCommits, maps:get(committed, quod_simplex:stats(?ROOT_NS))),
            ?assertEqual({ok, PointerInfo}, file:read_file_info(filename:join(Dir, "node.actor")))
        after
            quod_reg:unsubscribe({node_actor, node}),
            stop_process(Auth), cleanup(F)
        end
    end}.

observe_enrollment_completion(Manager) ->
    Parent = self(),
    Observer = fun(State, {in, {node_enrollment_result, _, complete}}, _) ->
                       Parent ! {enrollment_complete, Manager}, State;
                  (State, {in, {node_enrollment_result, _, {error, Reason}}}, _) ->
                       Parent ! {enrollment_error, Manager, Reason}, State;
                  (State, _, _) -> State
               end,
    ok = sys:install(Manager, {Observer, observing}).

node_enrollment_crash_custody_test_() ->
    [{atom_to_list(Stage), {timeout, 60, fun() -> enrollment_crash_custody(Stage) end}}
     || Stage <- [before_send, after_commit, after_allocation, known_refusal, malformed_template,
                  admission_refusal, auth_restart]].

enrollment_crash_custody(Stage) ->
    F = setup(automatic),
    #{dir := Dir, manager := Manager, actor_keypair := {Key, _} = Pair} = F,
    stop_process(Manager),
    {ok, Network} = quod_ontology:network_identity(),
    AuthOptions = case Stage of
        admission_refusal -> #{goal_signing_key_limit =>
            #{window_ms => 60000, max_total => 8, max_per_key => 1, max_keys => 8}};
        _ -> #{}
    end,
    {ok, Auth} = quod_client_auth:start_link(AuthOptions#{network_id => Network, node_key => Key}),
    unlink(Auth),
    try
        PolicyAnchor = quod_simplex:genesis_hash(?NODE_NS),
        {ok, Template} = file:read_file(filename:join(code:priv_dir(quod),
                                                     "ontologies/node_instance.pl")),
        InitialTemplate = case Stage of malformed_template -> <<"broken(.">>; _ -> Template end,
        {ok, _, _} = quod_prolog:execute(?NODE_NS,
            {assertz, {node_identity_template, InitialTemplate}}),
        {ok, _, _} = quod_prolog:execute(?ROOT_NS, {transaction, {',',
            {assertz, {system_ontology, ?NODE_NS, PolicyAnchor}},
            {assertz, {ontology_creation_policy, ?NODE_NS, PolicyAnchor}}}}),
        Applicant = #{reference => {agent_instance_ref, ?NODE_NS, PolicyAnchor, {enrolling, Key}},
                      keypair => Pair, network => Network},
        {Bytes, Sig} = lobby_user_request(Applicant, execute, {enroll_node, {0}}),
        case Stage of
            auth_restart -> stop_process(Auth);
            admission_refusal ->
                ok = quod_client_auth:admit_forwarded_goal(Key, Key),
                ?assertMatch({refused, {?NODE_NS, PolicyAnchor}}, quod_node_actor:enroll()),
                ?assertMatch({pending, #{rejected := enrollment}},
                    quod_identity:load_node_actor_pointer(Dir)),
                ?assertMatch({fail, _}, quod_prolog:prove_ro(?NODE_NS,
                    {node_identity_allocation, Key, {'_'}, {'_'}})),
                %% A known refusal may recover when admission becomes ready;
                %% no clock advance or expiry of an uncertain write is used.
                stop_process(Auth),
                {ok, NextAuth} = quod_client_auth:start_link(#{network_id => Network, node_key => Key}),
                unlink(NextAuth);
            known_refusal ->
                %% A denied policy is a definite refusal. Malformed authored
                %% source uses the error channel and cannot authorize retry.
                CreationPolicy = [Term || {':-', {can_create_ontology, _, _, _}, _} = Term <-
                    quod_prolog:read_terms(filename:join(code:priv_dir(quod),
                                                        "ontologies/quod_root.pl"))],
                replace_root_policy(can_create_ontology, 3,
                    [{':-', {can_create_ontology, {'_'}, {'_'}, {'_'}}, fail}]),
                ?assertMatch({refused, {?NODE_NS, PolicyAnchor}}, quod_node_actor:enroll()),
                ?assertMatch({pending, #{rejected := enrollment}},
                    quod_identity:load_node_actor_pointer(Dir)),
                replace_root_policy(can_create_ontology, 3, CreationPolicy);
            malformed_template ->
                ?assertMatch({submitted, {ok, _, {normalized, {error, _}}}},
                    quod_node_actor:enroll()),
                ?assertMatch({pending, #{rejected := none}},
                    quod_identity:load_node_actor_pointer(Dir));
            _ -> ok = quod_identity:begin_node_enrollment(Dir, Bytes, Sig)
        end,
        case Stage of
            before_send -> ok;
            known_refusal -> ok;
            malformed_template -> ok;
            admission_refusal -> ok;
            auth_restart -> ok;
            _ ->
                ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                    quod_client_goal_ingress:submit(Bytes, Sig)),
                {ok, [#{'Ref' := Ref}], _} = quod_prolog:prove_ro(?NODE_NS,
                    {node_identity_allocation, Key, {'Ref'}, {'_'}}),
                {ok, Blob} = quod_wire_term:encode_canonical(Ref),
                case Stage of
                    after_allocation -> ok = quod_identity:retain_node_allocation(Dir, Blob);
                    after_commit -> ok
                end
        end,
        case Stage of
            Uncertain when Uncertain =:= before_send; Uncertain =:= malformed_template ->
                {ok, Before} = file:read_file(filename:join(Dir, "node.actor")),
                ?assertEqual(unresolved, quod_node_actor:enroll()),
                ?assertEqual(unresolved, quod_node_actor:enroll()),
                ?assertEqual({ok, Before}, file:read_file(filename:join(Dir, "node.actor"))),
                ?assertMatch({fail, _}, quod_prolog:prove_ro(?NODE_NS,
                    {node_identity_allocation, Key, {'_'}, {'_'}}));
            _ ->
                {ok, NextManager} = quod_namespace_manager:start_link(),
                unlink(NextManager),
                observe_enrollment_completion(NextManager),
                case Stage of
                    auth_restart ->
                        ?assertEqual(none, quod_identity:load_node_actor_pointer(Dir)),
                        %% This existing manager must wake from the new auth
                        %% owner's notice, without an application restart or
                        %% an explicit enrollment cast from the caller.
                        {ok, RestartedAuth} = quod_client_auth:start_link(
                            #{network_id => Network, node_key => Key}),
                        unlink(RestartedAuth);
                    _ -> ok = quod_namespace_manager:enroll_node()
                end,
                await_enrollment_completion(NextManager),
                {ok, Bound} = quod_identity:load_node_actor_pointer(Dir),
                {ok, #{reference := BoundRef}} = quod_agent_ref:decode(Bound),
                ?assertMatch({ok, [#{'Refs' := [BoundRef]}], _},
                    quod_prolog:prove_ro(?NODE_NS,
                        {findall, {'R'}, {node_identity_allocation, Key, {'R'}, {'_'}}, {'Refs'}})),
                ?assertEqual(complete, quod_node_actor:enroll())
        end
    after stop_process(whereis(quod_client_auth)), cleanup(F) end.

await_enrollment_completion(Manager) ->
    case maps:get(node_enrollment, quod_namespace_manager:stats()) of
        complete -> ok;
        _ -> await_enrollment_completion_event(Manager)
    end.

await_enrollment_completion_event(Manager) ->
    receive
        {enrollment_complete, Manager} ->
            ?assertEqual(complete, maps:get(node_enrollment, quod_namespace_manager:stats()));
        {enrollment_error, Manager, Reason} -> error({enrollment_failed, Reason})
    after 30000 -> error({enrollment_timeout, quod_namespace_manager:stats()})
    end.

cleanup(#{dir := Dir, saved := Saved, manager := Manager,
          ns_sup := NsSup, brahms_sup := BrahmsSup, journal := Journal,
          router := Router, foreign_log := ForeignLog}) ->
    CurrentManager = quod_reg:where({namespace_manager, node}),
    %% Stop the reconciler before tearing down its policy dependencies. Root
    %% withdrawal is a tested domain operation, not a fixture shutdown step.
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

full_physical_composition_uses_governed_preparation_budget(_Fixture) ->
    Ns = unique_ns(<<"physical-composition">>),
    Options = physical_composition_options(),
    Action = {create_ontology, Ns, Options},
    {ok, Structural} = quod_ontology:validate_action(Action),
    {ok, Prepared} = quod_ontology:prepare_action(Structural),
    {ok, Bytes} = quod_ontology:prepared_bytes(Prepared),
    Size = byte_size(Bytes),
    ?assert(Size > 262144),
    ?assertEqual({ok, Prepared}, quod_ontology:decode_prepared(Bytes)),
    Goal = {create_ontology, Ns, Options, {'Anchor'}},
    try
        commit_root({set_effect_custody_limits, 64, 1}),
        wait_effect_limits({64, 1}, 300),
        Before = quod_prolog:applied(?ROOT_NS),
        ?assertMatch({error, {effect_custody_limit, prepared_bytes, _, 1}},
                     quod_prolog:execute(?ROOT_NS, Goal)),
        ?assertEqual(Before, quod_prolog:applied(?ROOT_NS)),
        ?assertEqual(undefined, quod_reg:where({quod_prolog, Ns})),
        ?assertMatch(#{reservations := 0}, quod_effect_journal:stats()),
        commit_root({set_effect_custody_limits, 64, unlimited}),
        wait_effect_limits({64, unlimited}, 300),
        {ok, [#{'Anchor' := Anchor}], _} = quod_prolog:execute(?ROOT_NS, Goal),
        wait_ready(Ns, 300),
        ?assertEqual(Anchor, quod_simplex:genesis_hash(Ns)),
        ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Ns, {composition_marker, complete})),
        ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Ns, {current_predicate, {'/', physics_close_hinged, 4}})),
        %% The committed create retains the complete policy, not just the
        %% marker. Ordinary namespace recovery must use that same genesis.
        ok = quod_namespace_manager:stop_content(Ns),
        ?assertMatch({ok, [_], _}, quod_prolog:execute(?ROOT_NS, Goal)),
        wait_ready(Ns, 300),
        ?assertEqual(Anchor, quod_simplex:genesis_hash(Ns)),
        ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Ns, {composition_marker, complete}))
    after
        commit_root({set_effect_custody_limits, 64, unlimited}),
        wait_effect_limits({64, unlimited}, 300)
    end.

physical_composition_options() ->
    [{source_file, list_to_binary(filename:join([code:priv_dir(quod), "ontologies", File]))}
     || File <- ["agent_instance.pl", "quod_physics.pl", "quod_hinged.pl"]] ++
    [{source, <<"can_invoke(_, _, _, _).\ncomposition_marker(complete).\n">>},
     {external_predicate_modules, [quod_agent_predicates]}].

repeated_create_is_a_noop(_Fixture) ->
    Ns = unique_ns(<<"repeated">>),
    Goal = create_goal(Ns, []),
    ?assertMatch({ok, [#{}], _}, quod_prolog:execute(?ROOT_NS, Goal)),
    ok = wait_ready(Ns, 300),
    Before = maps:get(committed, quod_simplex:stats(?ROOT_NS)),
    ?assertMatch({ok, [#{}], _}, quod_prolog:execute(?ROOT_NS, Goal)),
    ?assertEqual(Before, maps:get(committed, quod_simplex:stats(?ROOT_NS))).

bundled_agent_policy_uses_ordinary_creation(_Fixture) ->
    Ns = unique_ns(<<"bundled-agent-policy">>),
    Options =
        [{source_file, filename:join([code:priv_dir(quod), "ontologies", File])}
         || File <- ["agent_instance.pl", "agent_recovery_policy.pl"]] ++
        [{terms, [{instance_of, {':',quod,{':',agent,agent}}, <<"worker">>},
                  {domain_state, <<"worker">>, <<"before-loss">>},
                  {agent_recovery_threshold, <<"worker">>, 2}]},
         {external_predicate_modules, [quod_agent_predicates]}],
    %% Go through root's action, prepared effect and namespace manager. Direct
    %% namespace startup with an already-parsed diff bypasses the cold guard.
    {ok, [#{'Anchor' := Anchor}], _} = quod_prolog:execute(
        ?ROOT_NS, {create_ontology, Ns, Options, {'Anchor'}}),
    ?assertEqual(Anchor, quod_simplex:genesis_hash(Ns)),
    ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(
        Ns, {domain_state, <<"worker">>, <<"before-loss">>})),
    %% Bundled policies are ordinary, readable reaction clauses. Their actual
    %% installation and recovery are covered through the hosting owner tests.
    lists:foreach(fun(Service) ->
        ?assertMatch({ok, [_ | _], _}, quod_prolog:prove_ro(Ns,
            {clause, {react_on, {observed, {'Event'}}, {Service, {'Scope'}}}, {'Guard'}}))
    end, [reconcile_agent_hosts, reconcile_agent_observers]),
    ?assertMatch([#{state := applied}],
        [Row || #{target := {Target, _}} = Row <- quod_effect_journal:rows(),
                Target =:= Ns]).

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
         Ns, quod_ct:source_assertion({instance_of, node, OtherInstance}))),
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
        commit_root({set_effect_custody_limits, 64, 1}),
        wait_effect_limits({64, 1}, 300),
        AgentNs = maps:get(namespace, Agent),
        Before = {quod_prolog:applied(?ROOT_NS), quod_prolog:applied(AgentNs)},
        lists:foreach(fun(Lane) ->
            Target = unique_ns(<<"budget-refused">>),
            Create = ["quod:root::create_ontology(\"", Target, "\", [], _)"],
            RefusedGoal = iolist_to_binary(case Lane of
                single -> [Create, "."];
                atomic -> ["assertz(budget_side_effect(atomic)), ", Create, "."];
                independent -> ["independent((assertz(budget_side_effect(independent)), ", Create, "))."]
            end),
            {RefusedBytes, RefusedSig} = signed_agent_goal(
                NetworkId, PublicKey, KeyPair, Agent, execute, SessionExpires, RefusedGoal),
            ?assertMatch({ok, _, {normalized, {error, {effect_custody_limit, prepared_bytes, _, 1}}}},
                quod_client_goal_ingress:submit(execute, SessionId, RefusedBytes, RefusedSig, Peer)),
            ?assertEqual({ok, not_hosted}, quod_ontology:local_state(Target)),
            ?assertEqual(Before, {quod_prolog:applied(?ROOT_NS), quod_prolog:applied(AgentNs)}),
            ?assertMatch(#{reservations := 0}, quod_effect_journal:stats())
        end, [single, atomic, independent]),
        ?assertMatch({fail, _}, quod_prolog:prove_ro(AgentNs, {budget_side_effect, {'_'}})),
        commit_root({set_effect_custody_limits, 64, unlimited}),
        wait_effect_limits({64, unlimited}, 300),
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
        commit_root({set_effect_custody_limits, 64, unlimited}),
        wait_effect_limits({64, unlimited}, 300),
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
                      "\"::host_ontology(",
                      agent_ref_source(NodeRef, InstanceText), ", ",
                      prolog_binary_literal(NewNs),
                      ", Anchor, private)."]),
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

hosting_action_checks_policy_and_conflicts(
  #{actor_ns := ActorNs, actor_principal := Principal}) ->
    {ok, NodeRef} = quod_agent_ref:materialize_principal(Principal),
    Ns = unique_ns(<<"hosting-action">>),
    Anchor = crypto:strong_rand_bytes(32),
    Goal = {host_ontology, NodeRef, Ns, Anchor, private},
    Host = {hosts_ontology, NodeRef, Ns, Anchor, private},
    ?assertMatch({ok, [_], _}, quod_prolog:execute(ActorNs, Goal)),
    ok = wait_desired_content(Ns, Anchor, 300),
    ?assertMatch({ok, [_], _}, quod_prolog:execute(ActorNs, Goal)),
    ?assertMatch({ok, [#{'Rows' := [Host]}], _},
       quod_prolog:prove_ro(ActorNs, {findall, Host, Host, {'Rows'}})),
    %% No silent identity/visibility replacement, and malformed inputs cannot
    %% enter the committed projection and strand its existing valid work.
    [begin
        ?assertMatch({fail, _}, quod_prolog:execute(ActorNs, Bad))
     end || Bad <- [{host_ontology, NodeRef, Ns, <<1:256>>, private},
                    {host_ontology, NodeRef, Ns, Anchor, discoverable},
                    {host_ontology, NodeRef, <<>>, Anchor, private},
                    {host_ontology, NodeRef, Ns, <<1>>, private},
                    {host_ontology, NodeRef, Ns, Anchor, unknown},
                    {host_ontology, NodeRef, {'Name'}, Anchor, private}]],
    {ok, Network} = quod_ontology:network_identity(),
    {ok, NodeKey} = application:get_env(quod, node_pubkey),
    {Public, _} = Pair = quod_identity:generate(),
    Agent = provision_agent(Public, false),
    AgentRef = maps:get(reference, Agent),
    User = Agent#{keypair => Pair, network => Network},
    {ok, Auth} = quod_client_auth:start_link(#{network_id => Network, node_key => NodeKey}),
    unlink(Auth),
    Submit = fun(G) ->
        {Bytes, Sig} = lobby_user_request(User, execute, {'::', ActorNs, G}),
        quod_client_goal_ingress:submit(Bytes, Sig)
    end,
    DelegatedNs = unique_ns(<<"delegated-hosting-action">>),
    DelegatedGoal = {host_ontology, NodeRef, DelegatedNs, Anchor, private},
    Grant = {can_host_ontology, AgentRef, NodeRef, DelegatedNs, Anchor, private},
    try
        ?assertMatch({ok, _, {normalized, {failed, _}}}, Submit(DelegatedGoal)),
        ?assertMatch({ok, _, _}, quod_prolog:execute(ActorNs, {assertz, Grant})),
        ?assertMatch({ok, _, {normalized, {committed, _, _}}}, Submit(DelegatedGoal)),
        ok = wait_desired_content(DelegatedNs, Anchor, 300),
        ?assertMatch({ok, _, _}, quod_prolog:execute(ActorNs, {retract, Grant})),
        %% Revocation is checked even when the requested hosting fact exists.
        ?assertMatch({ok, _, {normalized, {failed, _}}}, Submit(DelegatedGoal)),
        ?assertMatch({ok, _, {normalized, {failed, _}}}, Submit(
            {assertz, {hosts_ontology, NodeRef, Ns, <<2:256>>, private}}))
    after stop_process(Auth) end,
    ?assertMatch({ok, _, _}, quod_prolog:execute(ActorNs,
       {retract, {hosts_ontology, NodeRef, DelegatedNs, Anchor, private}})),
    ok = wait_desired_absent(DelegatedNs, 300),
    RollbackNs = unique_ns(<<"rollback-hosting-action">>),
    ?assertMatch({fail, _}, quod_prolog:execute(ActorNs,
       {transaction, {',', {host_ontology, NodeRef, RollbackNs, Anchor, private}, fail}})),
    ?assertEqual(false, desired_has_content(RollbackNs)),
    ?assertMatch({fail, _}, quod_prolog:prove_ro(ActorNs,
       {hosts_ontology, NodeRef, RollbackNs, Anchor, private})),
    ?assertMatch({ok, [_], _}, quod_prolog:execute(ActorNs, {retract, Host})),
    ok = wait_desired_absent(Ns, 300).

personal_lobbies_use_shared_creation_and_recovery(
  #{actor_ns := ActorNs, actor_principal := Principal}) ->
    {ok, Node} = quod_agent_ref:materialize_principal(Principal),
    {ok, Network} = quod_ontology:network_identity(),
    {ok, NodeKey} = application:get_env(quod, node_pubkey),
    {ok, Auth} = quod_client_auth:start_link(#{network_id => Network, node_key => NodeKey}),
    unlink(Auth),
    try
        Classes = found_lobby_classes(),
        Users = [found_lobby_user(Classes, Network, Node) || _ <- [first, second]],
        [begin
             #{reference := Owner, lobby_name := Name} = User,
             commit_root({assertz, {ontology_creator_agent, Owner}}),
             {ok, _, _} = quod_prolog:execute(ActorNs, {assertz,
                 {can_host_ontology, Owner, Node, Name, {'Anchor'}, discoverable}}),
             Goal = {physical_fixture_found, {0}},
             {Bytes, Signature} = lobby_user_request(User, execute, Goal),
             {ok,_,{normalized,Founded}}=quod_client_goal_ingress:submit(Bytes,Signature),
             m3a_committed(Founded),
             ok = wait_ready(Name, 300),
             Ref = {ontology_ref, Name, quod_simplex:genesis_hash(Name)},
             ?assertEqual(Ref, lobby_user_reference(User)),
             %% The committed operation is recoverable independently of the
             %% live reply; no new signed creation is used for resolution.
             Resolved = resolve_lobby_request(Bytes, Signature),
             ?assertMatch({ok, _, {operation_outcome, _, #{status := committed}}}, Resolved),
             {200, #{bindings := [Recovered]}} = quod_client_http:signed_goal_result(Resolved),
             ?assertEqual(quod_client_goal_parser:value_text(Ref), maps:get(<<"V0">>, Recovered)),
             {Again, AgainSignature} = lobby_user_request(User, execute, Goal),
             ?assertMatch({ok, _, {normalized, {failed, _}}},
                          quod_client_goal_ingress:submit(Again, AgainSignature)),
             ?assertEqual(Ref, lobby_user_reference(User)),
             commit_root({retract, {ontology_creator_agent, Owner}})
         end || User <- Users],
        [First, Second] = Users,
        {ontology_ref, FirstLobby, FirstAnchor} = FirstRef = lobby_user_reference(First),
        SecondRef = lobby_user_reference(Second),
        ?assertNotEqual(FirstRef, SecondRef),
        SceneGoal = {'::', FirstLobby,
            {',', {current_ontology_identity, FirstLobby, FirstAnchor},
                  {client_world_view, personal_lobby, playing, [], {0}}}},
        {SceneBytes, SceneSig} = lobby_user_request(First, read, SceneGoal),
        {ok, _, {normalized, {read, _, {answers, _, [SceneBinding]}}}} =
            quod_client_goal_ingress:submit(SceneBytes, SceneSig),
        {ok, ScenePairs} = quod_client_result:decode_binding(SceneBinding),
        ?assertMatch({world_view, {entity_ref, FirstLobby, FirstAnchor, personal_lobby},
                      _, [_ | _], recovering}, proplists:get_value(<<"V0">>, ScenePairs)),
        {DeniedBytes, DeniedSig} = lobby_user_request(Second, read, SceneGoal),
        ?assertMatch({ok, _, {normalized, {read, _, {failed, _}}}},
                     quod_client_goal_ingress:submit(DeniedBytes, DeniedSig)),
        {ok, _, _} = quod_prolog:execute(ActorNs,
            {retract, {hosts_ontology, Node, FirstLobby, FirstAnchor, discoverable}}),
        ok = wait_desired_absent(FirstLobby, 300),
        LobbyPid = quod_reg:where({quod_prolog, FirstLobby}),
        case LobbyPid of
            undefined -> ok;
            _ ->
                LobbyMonitor = monitor(process, LobbyPid),
                receive {'DOWN', LobbyMonitor, process, LobbyPid, _} -> ok
                after 5000 -> error(lobby_not_stopped) end
        end,
        {ok, resumed, FirstLobby, FirstAnchor} = quod_ontology:join(
            FirstLobby, binary:encode_hex(FirstAnchor, lowercase),
            [{seed, "127.0.0.1", 14567}]),
        ok = wait_ready(FirstLobby, 300),
        ?assertEqual(FirstRef, lobby_user_reference(First)),
        {ResumedBytes, ResumedSig} = lobby_user_request(First, read, SceneGoal),
        ?assertMatch({ok, _, {normalized, {read, _, {answers, _, [_]}}}},
            quod_client_goal_ingress:submit(ResumedBytes, ResumedSig)),
        %% A local join does not recreate a withdrawn hosting intention. Restore
        %% it explicitly for the later committed-inventory restart regression.
        {ok,_,_} = quod_prolog:execute(ActorNs,
            {host_ontology,Node,FirstLobby,FirstAnchor,discoverable}),
        ok = wait_desired_content(FirstLobby,FirstAnchor,300)
    after stop_process(Auth) end.

node_enrollment_uses_signed_atomic_creation(
  Fixture = #{actor_ns := ActorNs, actor_principal := Principal, actor_keypair := HostPair,
    dir := Dir}) ->
    {ok, Host} = quod_agent_ref:materialize_principal(Principal),
    {ok, Network} = quod_ontology:network_identity(),
    {ok, NodeKey} = application:get_env(quod, node_pubkey),
    NodeAnchor = quod_simplex:genesis_hash(?NODE_NS),
    {ok, Template} = file:read_file(filename:join(code:priv_dir(quod),
                                                 "ontologies/node_instance.pl")),
    Policy = {ontology_hosting_policy, ?NODE_NS, NodeAnchor},
    Grant = {ontology_creation_policy, ?NODE_NS, NodeAnchor},
    AdminGrant = {root_administrator_agent, Host},
    Catalogue = {system_ontology, ?NODE_NS, NodeAnchor},
    commit_root({transaction, {',', {assertz, AdminGrant}, {assertz, Catalogue}}}),
    {ok, Auth} = quod_client_auth:start_link(#{network_id => Network, node_key => NodeKey}),
    unlink(Auth),
    try
        %% Upgrade retained policy through a real administrator's signed
        %% atomic source edit, preserving the founder's exact identity.
        Admin = #{reference => Host, keypair => HostPair, network => Network},
        {ok, PointerBefore} = file:read_file(filename:join(Dir, "node.actor")),
        ClassEdit = {'::', ?NODE_NS, {',',
            {current_ontology_identity, ?NODE_NS, NodeAnchor}, {',', system_prolog_edit,
            {transaction, {',', {assertz, {node_identity_template, Template}},
                                {assertz, {node_identity_allocation, NodeKey, Host, Host}}}}}}},
        Upgrade = {transaction, {',', ClassEdit, {',',
            {assertz, Policy}, {'::', ?ROOT_NS, {assertz, Grant}}}}},
        {EditBytes, EditSig} = lobby_user_request(Admin, execute, Upgrade),
        ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                     quod_client_goal_ingress:submit(EditBytes, EditSig)),
        %% Restart the retained subtree, not its hosting policy. Removing a
        %% desired system copy would race the catalogue owner's reconciliation.
        NodeSup = quod_reg:where({quod_ns, ?NODE_NS}),
        OldEngine = quod_reg:where({quod_prolog, ?NODE_NS}),
        Restart = monitor(process, NodeSup),
        EngineRestart = monitor(process, OldEngine),
        exit(NodeSup, kill),
        receive {'DOWN', Restart, process, NodeSup, killed} -> ok end,
        receive {'DOWN', EngineRestart, process, OldEngine, _} -> ok end,
        ok = await_enrolled_identity({?NODE_NS, NodeAnchor}),
        ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(?NODE_NS,
            {node_identity_allocation, NodeKey, Host, Host})),
        ?assertEqual({ok, PointerBefore}, file:read_file(filename:join(Dir, "node.actor"))),
        {Public, _} = Pair = quod_identity:generate(),
        Applicant = #{reference => {agent_instance_ref, ?NODE_NS, NodeAnchor, {enrolling, Public}},
                      keypair => Pair, network => Network},
        {Bytes, Signature} = lobby_user_request(Applicant, execute, {enroll_node, {0}}),
        ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                     quod_client_goal_ingress:submit(Bytes, Signature)),
        {ok, [#{'Ref' := {agent_instance_ref, Name, Anchor, me} = Ref}], _} =
            quod_prolog:prove_ro(?NODE_NS, {node_identity_allocation, Public, {'Ref'}, Host}),
        %% The actual root executor keeps the new ontology alive and routable.
        ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(ActorNs,
            {hosts_ontology, Host, Name, Anchor, discoverable})),
        ok = await_enrolled_identity({Name, Anchor}),
        ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Name,
            {agent_key, me, Public, active})),
        ?assertMatch({fail, _}, quod_prolog:prove_ro(?ROOT_NS,
            {peer_admitted, Public, {'_'}, {'_'}, Public})),
        %% A caller duplicate returns the original allocation, never a second
        %% genesis. Runtime recovery separately retains the original request.
        {Duplicate, DupSig} = lobby_user_request(Applicant, execute, {enroll_node, {0}}),
        ?assertMatch({ok, _, {normalized, {answers, _, [_]}}},
                     quod_client_goal_ingress:submit(Duplicate, DupSig)),
        ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(?NODE_NS,
            {node_identity_allocation, Public, Ref, Host})),
        {Bad, BadSig} = lobby_user_request(Applicant, execute,
            {'::', ?ROOT_NS, {create_ontology, <<"node:unauthorized">>, [], {0}}}),
        ?assertMatch({ok, _, {normalized, {failed, _}}},
                     quod_client_goal_ingress:submit(Bad, BadSig))
    after
        stop_process(Auth),
        %% Restore the initially empty system catalogue while preserving this
        %% shared fixture's class as an ordinary, explicitly hosted copy.
        ok = host_locally(Fixture, ?NODE_NS, NodeAnchor),
        commit_root({transaction, {',', {retract, Grant}, {',',
            {retract, AdminGrant}, {retract, Catalogue}}}}),
        {ok, _, _} = quod_prolog:execute(ActorNs, {retract, Policy})
    end.

await_enrolled_identity({Name, _} = Identity) ->
    true = quod_reg:subscribe({runtime, Name}),
    try await_enrolled_identity(Identity, quod_time:mono_ms() + 10000)
    after quod_reg:unsubscribe({runtime, Name})
    end.

await_enrolled_identity(Identity, Deadline) ->
    case quod_client_goal_target:available(Identity) of
        ok -> ok;
        _ ->
            receive
                {proof_ready, Identity, _, _, _} ->
                    await_enrolled_identity(Identity, Deadline);
                {replay_ready, Identity, _} ->
                    await_enrolled_identity(Identity, Deadline)
            after max(0, Deadline - quod_time:mono_ms()) ->
                error({enrolled_identity_not_ready, Identity})
            end
    end.

signup_namespace(Token) ->
    Encoded = base64:encode(Token, #{mode => urlsafe, padding => false}),
    <<"human:", Encoded/binary>>.

found_lobby_classes() ->
    {NamesNs, NamesAnchor} = found_lobby_source(<<"names">>, "quod_names.pl", []),
    {RenderNs, RenderAnchor} = found_lobby_source(<<"rendering">>, "gui_scene.pl", []),
    {ModelNs, ModelAnchor} = found_lobby_source(<<"modelling">>, "gui_scene.pl",
        [{rendering_vocabulary, RenderNs, RenderAnchor}]),
    {MeasureNs, MeasureAnchor} = found_lobby_source(<<"measure">>, "gui_measure.pl", []),
    {MaterialNs, MaterialAnchor} = found_lobby_source(<<"material">>, "quod_material.pl",
        [{measure_vocabulary, MeasureNs, MeasureAnchor}]),
    {EidolonNs, EidolonAnchor} = found_lobby_source(<<"material-eidolons">>, "quod_material_eidolons.pl",
        [{material_vocabulary, MaterialNs, MaterialAnchor}]),
    {EnvironmentNs, EnvironmentAnchor} = found_lobby_source(
        <<"environment">>, "quod_environment.pl", []),
    {EnvironmentEidolonNs, EnvironmentEidolonAnchor} = found_lobby_source(
        <<"environment-eidolons">>, "quod_environment_eidolons.pl",
        [{environment_vocabulary, EnvironmentNs, EnvironmentAnchor}]),
    GuiNs = <<"quod:gui">>, GuiAnchor = quod_simplex:genesis_hash(GuiNs),
    found_lobby_named_sources(<<"quod:agent">>, ["quod_agent.pl"], [], [quod_agent_predicates]),
    found_lobby_named_sources(<<"quod:user">>, ["quod_user.pl"], [], [quod_agent_predicates]),
    found_lobby_named_sources(<<"quod:space">>, ["quod_space.pl"],
        [{measure_vocabulary, MeasureNs, MeasureAnchor},
         {rendering_vocabulary, RenderNs, RenderAnchor},
         {modelling_vocabulary, ModelNs, ModelAnchor},
         {gui_vocabulary, GuiNs, GuiAnchor}], [quod_agent_predicates]),
    Templates = [{lobby_source_file, list_to_binary(filename:join(
        code:priv_dir(quod), "ontologies/" ++ File))}
        || File <- ["lobby_instance.pl", "agent_instance.pl", "quod_physics.pl", "voxel_world.pl", "voxel_world_view.pl", "gui_instance.pl", "voxel_world_gui.pl", "lobby_worlds.pl"]],
    found_lobby_source(<<"lobby-classes">>, "quod_lobby.pl",
        [{names_vocabulary, NamesNs, NamesAnchor},
         {rendering_vocabulary, RenderNs, RenderAnchor},
         {modelling_vocabulary, ModelNs, ModelAnchor},
         {material_eidolons, EidolonNs, EidolonAnchor},
         {environment_vocabulary, EnvironmentNs, EnvironmentAnchor},
         {environment_eidolons, EnvironmentEidolonNs, EnvironmentEidolonAnchor},
         {gui_vocabulary, GuiNs, GuiAnchor} | Templates]).

found_lobby_source(Prefix, File, Facts) ->
    found_lobby_sources(Prefix, [File], Facts).

found_lobby_sources(Prefix, Files, Facts) ->
    found_lobby_named_sources(unique_ns(Prefix), Files, Facts, [quod_agent_predicates]).

found_lobby_named_sources(Ns, Files, Facts, Modules) ->
    Expanded = lists:uniq(lists:append([case File of
        Component when Component =:= "quod_gui.pl"; Component =:= "gui_scene.pl";
                       Component =:= "gui_measure.pl"; Component =:= "gui_tools.pl" ->
            ["quod_gui.pl","gui_measure.pl","gui_scene.pl","gui_tools.pl"];
        _ -> [File]
    end || File <- Files])),
    Sources = [{source_file,list_to_binary(case filename:pathtype(File) of
        absolute -> File;
        _ -> filename:join([code:priv_dir(quod), "ontologies", File])
    end)} || File <- Expanded],
    {ok, created, Ns, _} = quod_ontology:create(Ns,
        Sources ++ [{terms, Facts},
         {external_predicate_modules, Modules}]),
    ok = wait_ready(Ns, 300),
    {Ns, quod_simplex:genesis_hash(Ns)}.

found_lobby_user({ClassNs, ClassAnchor}, Network, Node) ->
    {Public, _} = Pair = quod_identity:generate(),
    Name = unique_ns(<<"personal-lobby">>),
    {Ns, Anchor} = found_lobby_sources(<<"human-user">>,
        ["agent_instance.pl",
         filename:absname("test/fixtures/physical-preset.pl")],
        quod_personal_agent_tests:user_terms() ++
        [{instance_of, {':',quod,{':',user,human_user}}, me}, {agent_key, me, Public, active},
         {lobby_vocabulary, ClassNs, ClassAnchor},
         {hosting_node, Node},
         {physical_fixture_name, Name}]),
    {agent_instance_ref, NodeNs, _, _} = Node,
    {ok,_,_} = quod_prolog:execute(NodeNs,{host_ontology,Node,Ns,Anchor,discoverable}),
    ok = wait_desired_content(Ns,Anchor,300),
    #{reference => {agent_instance_ref, Ns, Anchor, me},
      keypair => Pair, network => Network, lobby_name => Name}.

lobby_user_request(User = #{reference := {agent_instance_ref, Ns, Anchor, Instance},
                     keypair := {Public, _} = Pair, network := Network}, Mode, Goal) ->
    {ok, InstanceText} = quod_client_goal_parser:format(Instance),
    {CanonicalGoal, _, _} = erlog_int:term_instance(Goal, 0),
    {ok, GoalText} = quod_client_goal_parser:format(CanonicalGoal),
    {ok, Bytes} = quod_client_goal:encode(#{network_identity => Network,
        signing_public_key => Public, operation_id => crypto:strong_rand_bytes(32),
        agent_namespace => Ns, agent_genesis_anchor => Anchor,
        agent_instance_text => InstanceText, mode => Mode, parser_version => maps:get(parser_version, User, 2),
        not_after_ms => quod_time:now_ms() + 30000, goal_text => GoalText}),
    {Bytes, quod_identity:sign(Bytes, quod_identity:key_term(Pair))}.

lobby_user_reference(User) ->
    {Bytes, Signature} = lobby_user_request(User, read, {physical_fixture_reference, {0}}),
    {ok, _, {normalized, {read, _, {answers, _, [Answer]}}}} =
        quod_client_goal_ingress:submit(Bytes, Signature),
    {ok, [{<<"V0">>, Reference}]} = quod_durable_term:decode_result(Answer),
    Reference.

resolve_lobby_request(Bytes, Signature) ->
    {ok, #{agent_namespace := Ns}} = quod_client_goal:decode(Bytes),
    true = quod_reg:subscribe({runtime, Ns}),
    try
        resolve_lobby_request(Bytes, Signature, quod_reg:where({quod_prolog, Ns}),
                              quod_time:mono_ms() + 5000)
    after quod_reg:unsubscribe({runtime, Ns}) end.

resolve_lobby_request(Bytes, Signature, Engine, Deadline) ->
    Result = quod_client_goal_ingress:resolve_operation(Bytes, Signature),
    case Result of
        {ok, _, {operation_outcome, _, #{status := committed}}} -> Result;
        {ok, _, _} ->
            receive {projection_advanced, Engine, _} ->
                resolve_lobby_request(Bytes, Signature, Engine, Deadline)
            after max(0, Deadline - quod_time:mono_ms()) -> error({unresolved, Result}) end;
        Error -> Error
    end.

signed_root_create_obeys_entry_acl(_Fixture) ->
    RootClauses = root_invocation_clauses(),
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
        ok = replace_root_invocation_policy([HostEntry | RootClauses])
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

%% Fixed incarnation and current genesis block grammar. The local prepared
%% journal still excludes runtime caches from its stable native entry schema.
prepared_genesis_native_format_golden_test() ->
    Ns = <<"quod:cut2-prepared">>,
    Executor = <<17:256>>,
    Config0 = #{committee => [], genesis_diff => []},
    %% Ambient node_addr must not enter the frozen vector. Pin only the
    %% generation input; the serialized journal descriptor remains Config0.
    Genesis = quod_simplex:test_genesis_tx(
                Config0#{node_addr => undefined}, Ns, Executor, <<34:256>>),
    {ok, Block} = quod_ledger:new_block({genesis, 0}, none, 1, {batch, [Genesis]}, 0),
    {ok, GenesisBytes} = quod_transaction:encode_ledger_transaction(Genesis),
    ?assertEqual(
       {quod_block, 3, genesis, 0, none, 1,
        {batch, [{transaction, GenesisBytes}]}, 0},
       binary_to_term(quod_ledger:block_bytes(Block), [safe])),
    Entry = quod_ledger:entry(1, Block, none),
    Anchor = quod_simplex:block_hash(Block),
    ?assertEqual(
       <<157,246,183,25,41,169,120,216,19,142,234,148,83,169,7,95,
         59,18,153,114,197,71,35,94,203,91,92,144,238,86,60,84>>,
       Anchor),
    Native = quod_ledger:entry_view(Entry),
    Config = Config0#{prepared_genesis_entry => Native, genesis_hash => Anchor},
    Prepared = {prepared_lifecycle, create, Ns, Anchor, Config, created},
    {ok, Bytes} = quod_ontology:prepared_bytes(Prepared),
    ?assertEqual(1792, byte_size(Bytes)),
    ?assertEqual(
       <<26,32,232,69,85,59,39,59,25,68,232,243,181,104,242,160,
         143,151,56,239,201,201,76,221,168,223,148,171,18,158,196,154>>,
       crypto:hash(sha256, Bytes)),
    ?assertEqual({ok, Prepared}, quod_ontology:decode_prepared(Bytes)),
    %% The private journal owns one fixed native schema, not the runtime
    %% transaction tuple layout. Extra runtime fields are not a second format.
    ?assertEqual({error, invalid_action}, quod_ontology:decode_prepared(
        term_to_binary({quod_prepared_lifecycle, 1, Prepared}, [deterministic]))),
    CachedNative = Native#entry{data = {batch,
        [Genesis#transaction{claim_view = {untrusted_runtime_metadata}}]}},
    CachedPrepared = setelement(5, Prepared,
        Config#{prepared_genesis_entry => CachedNative}),
    ?assertEqual({ok, Bytes}, quod_ontology:prepared_bytes(CachedPrepared)),
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
    Clause = {':-', {prepared_identity, {'Value'}, {'Value'}}, true},
    Action = {create_ontology, Ns, [{terms, [Clause]} | physical_composition_options()]},
    {ok, Structural} = quod_ontology:validate_action(Action),
    {ok, Prepared0} = quod_ontology:prepare_action(Structural),
    {prepared_lifecycle, create, Ns, _InitialAnchor, Config0, created} = Prepared0,
    %% Ordinary preparation itself must freeze a native entry, not an artifact.
    ?assertMatch(#entry{}, maps:get(prepared_genesis_entry, Config0)),
    {ok, Executor} = application:get_env(quod, node_pubkey),
    Incarnation = <<68:256>>,
    Genesis = quod_simplex:test_genesis_tx(Config0, Ns, Executor, Incarnation),
    {ok, Block} = quod_ledger:new_block({genesis, 0}, none, 1, {batch, [Genesis]}, 0),
    Entry = quod_ledger:entry(1, Block, none),
    Anchor = quod_simplex:block_hash(Block),
    Native = quod_ledger:entry_view(Entry),
    Config = Config0#{prepared_genesis_entry => Native, genesis_hash => Anchor},
    Prepared = {prepared_lifecycle, create, Ns, Anchor, Config, created},
    {ok, Bytes} = quod_ontology:prepared_bytes(Prepared),
    ?assert(byte_size(Bytes) > 262144),
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
    ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Ns, {prepared_identity, first, first})),
    ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Ns, {prepared_identity, second, second})),
    ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {prepared_identity, first, second})),
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
    ?assertMatch({error,{erlog,{domain_error,ontology_request_handle,forged_handle}}},
        quod_prolog:execute(?ROOT_NS,Goal)),
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
    ?assertMatch({error,{erlog,{context_violation,create_ontology,staging,wrong_ontology}}},
        quod_prolog:execute(?NODE_NS,create_goal(Ns,[]))),
    ?assertEqual({ok, not_hosted}, quod_ontology:local_state(Ns)).

invalid_create_never_reaches_hosting(_Fixture) ->
    BadNs = <<>>,
    ?assertMatch({error,{erlog,{domain_error,ontology_action,_}}},
        quod_prolog:execute(?ROOT_NS,create_goal(BadNs,[]))),
    ?assertEqual({error, invalid_name}, quod_ontology:local_state(BadNs)),
    ?assertEqual({error,{erlog,instantiation_error}},
        quod_prolog:execute(?ROOT_NS,create_goal({'Namespace'},[]))).

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
          ?assertMatch({error,{erlog,{domain_error,ontology_action,_}}},
              quod_prolog:execute(?ROOT_NS,create_goal(Ns,[{terms,[Term]}]))),
          ?assertEqual({ok, not_hosted}, quod_ontology:local_state(Ns)),
          ?assertNot(filelib:is_dir(quod_ledger_store:ns_dir(Dir, Ns)))
      end, ReservedTerms),
    lists:foreach(fun(Term) ->
        [Head | Args] = tuple_to_list(Term),
        Opaque = list_to_tuple([{'$quod_symbol', atom_to_binary(Head)} | Args]),
        Ns = unique_ns(<<"reserved-remote-genesis">>),
        ?assertEqual({error, {invalid_initial_term, Term}},
            quod_ontology:create(Ns, [{terms, [Opaque]}])),
        ?assertEqual({ok, not_hosted}, quod_ontology:local_state(Ns))
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
    %% Include the explicitly hosted physical-fixture products in this restart.
    %% The only restart inventory after reset comes from committed hosting.
    {ok, NodeRef} = quod_agent_ref:materialize_principal(ActorPrincipal),
    {ok, [#{'Refs' := Hosted}], _} = quod_prolog:prove_ro(ActorNs,
        {findall, {ontology_ref, {'Ns'}, {'Anchor'}},
         {hosts_ontology, NodeRef, {'Ns'}, {'Anchor'}, discoverable}, {'Refs'}}),
    ?assert(length(Hosted) >= 4),
    Profiles = [{Name, Anchor0, State} || {ontology_ref, Name, Anchor0} <- Hosted,
        {ok, [#{'State' := State}], _} <-
            [quod_prolog:prove_ro(Name, {physical_fixture_reference, {'State'}})]],
    ?assertEqual(2, length(Profiles)),

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
    [begin
        ok = wait_ready(Name, 300),
        ?assertEqual(Anchor0, quod_simplex:genesis_hash(Name)),
        ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Name,
            {physical_fixture_reference, State})),
        {ontology_ref, LobbyName, LobbyAnchor} = State,
        ok = wait_ready(LobbyName, 300),
        ?assertEqual(LobbyAnchor, quod_simplex:genesis_hash(LobbyName)),
        ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(LobbyName,
            {lobby_owner, {agent_instance_ref, Name, Anchor0, me}}))
     end || {Name, Anchor0, State} <- Profiles],
    Config = desired_content(Ns),
    ?assertEqual(Anchor, maps:get(genesis_hash, Config)),
    ?assertNot(maps:is_key(prepared_genesis_entry, Config)),
    ?assertNot(maps:is_key(genesis_diff, Config)),
    ok = wait_effect_limits({64, unlimited}, 300).

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
         {host_ontology, NodeRef, Ns, Anchor, private})),
    wait_desired_content(Ns, Anchor, 300).

root_invocation_clauses() ->
    File = filename:join(code:priv_dir(quod), "ontologies/quod_root.pl"),
    [Term || {':-', {can_invoke, _, _, _, _}, _} = Term <-
                 quod_prolog:read_terms(File)].

replace_root_invocation_policy(Clauses) ->
    replace_root_policy(can_invoke, 4, Clauses).

replace_root_policy(Functor, Arity, Clauses) ->
    Assertions = [{assertz, Clause} || Clause <- Clauses],
    Goal = lists:foldr(
             fun(Assertion, Tail) -> {',', Assertion, Tail} end,
             true, Assertions),
    commit_root(
      {',', {abolish, {'/', Functor, Arity}}, Goal}).

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

wait_manager_idle(Manager0, Attempts) ->
    Manager = case Manager0 of undefined -> quod_reg:where({namespace_manager,node}); _ -> Manager0 end,
    Parent = self(), Tag = make_ref(),
    Observe = fun(State, {in,_}, _) -> Parent ! {manager_progress,Tag}, State;
                 (State, _, _) -> State end,
    ok = sys:install(Manager,{Observe,none}),
    try await_manager_idle(Tag,quod_time:mono_ms()+Attempts*10)
    after sys:remove(Manager,Observe) end.

await_manager_idle(Tag,Deadline) ->
    case quod_namespace_manager:test_mutation_worker() of
        undefined -> ok;
        _ -> receive {manager_progress,Tag} -> await_manager_idle(Tag,Deadline)
             after max(0,Deadline-quod_time:mono_ms()) -> error(namespace_manager_idle_timeout) end
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

wait_effect_limits(Expected, Attempts) ->
    Journal = quod_reg:where({quod_effect_journal, node}),
    Parent = self(), Token = make_ref(),
    Observe = fun(State, {in, {'$gen_call', _, {configure_limits, _, _}}}, _) ->
                      Parent ! {effect_limits_input, Token}, State;
                 (State, _, _) -> State end,
    %% Subscribe before querying installed state. The following capacity call
    %% joins a delivered configuration to completion of its real owner handler.
    ok = sys:install(Journal, {Observe, none}),
    try wait_effect_limits_notice(Expected, Token, quod_time:mono_ms() + Attempts * 10)
    after sys:remove(Journal, Observe) end.

wait_effect_limits_notice(Expected, Token, Deadline) ->
    case quod_effect_journal:limits() of
        Expected -> ok;
        _ -> receive
            {effect_limits_input, Token} ->
                wait_effect_limits_notice(Expected, Token, Deadline)
        after max(0, Deadline - quod_time:mono_ms()) ->
            error({effect_limits_timeout, quod_runtime:stats(?ROOT_NS)})
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

%% The procedure that adds quod:names to a running network, end to end on
%% one node and in the order the fleet uses: root creates it (an admitted
%% node's ordinary creation), the node actor commits its discoverable
%% hosting fact through its own signed goal, root registers the exact anchor,
%% and the namespace manager adopts it as system content from the catalogue
%% alone. Nothing is re-founded and no source is injected over a history.
system_names_is_created_hosted_and_registered(
  #{actor_ns := ActorNs, actor_anchor := ActorAnchor,
    actor_instance_text := InstanceText,
    actor_keypair := {PublicKey, _} = KeyPair,
    actor_principal := Principal}) ->
    Names = <<"quod:names">>,
    Source = list_to_binary(
               filename:join(code:priv_dir(quod), "ontologies/quod_names.pl")),
    ?assertMatch({ok, _, [], #{}}, quod_system_ontology:catalog()),
    {ok, [#{'Anchor' := Anchor}], _} =
        quod_prolog:execute(
          ?ROOT_NS,
          {create_ontology, Names, [{source_file, Source}], {'Anchor'}}),
    ok = wait_ready(Names, 300),
    ?assertEqual(Anchor, quod_simplex:genesis_hash(Names)),
    ?assertMatch({ok, [#{'N' := Name}], _} when is_binary(Name),
                 quod_prolog:prove(Names, {draw, before_registration, {'N'}})),
    %% Created, hosted locally, but not yet a catalogue row.
    ?assertMatch({ok, _, [], #{}}, quod_system_ontology:catalog()),
    ?assertNotMatch(#{system_ontology := true}, desired_content_or_none(Names)),
    {ok, NetworkId} = quod_ontology:genesis_anchor(?ROOT_NS),
    {ok, NodeKey} = application:get_env(quod, node_pubkey),
    {ok, NodeRef} = quod_agent_ref:materialize_principal(Principal),
    Peer = {127, 0, 0, 9},
    {ok, AuthPid} = quod_client_auth:start_link(
                      #{network_id => NetworkId, node_key => NodeKey,
                        max_challenges => 4, max_sessions => 4}),
    unlink(AuthPid),
    try
        #{session_id := SessionId, expires_ms := SessionExpires} =
            open_client_session(NetworkId, NodeKey, KeyPair, Peer),
        Agent = #{namespace => ActorNs, anchor => ActorAnchor,
                  instance_text => InstanceText},
        GoalText = iolist_to_binary(
                     ["\"", ActorNs, "\"::assertz(hosts_ontology(",
                      agent_ref_source(NodeRef, InstanceText), ", ",
                      prolog_binary_literal(Names), ", ",
                      prolog_binary_literal(Anchor), ", discoverable))."]),
        {RequestBytes, Signature} = signed_agent_goal_version(
                                      NetworkId, PublicKey, KeyPair,
                                      Agent, execute, SessionExpires,
                                      GoalText, 2),
        ok = assert_signed_action_result(
               quod_client_goal_ingress:submit(
                 execute, SessionId, RequestBytes, Signature, Peer),
               SessionId, RequestBytes, Signature, Peer)
    after
        stop_process(AuthPid)
    end,
    ok = wait_desired_content(Names, Anchor, 300),
    ok = commit_root({assertz, {system_ontology, {':', quod, names}, Anchor}}),
    ?assertMatch({ok, _, [#{namespace := Names, anchor := Anchor}], #{}},
                 quod_system_ontology:catalog()),
    ok = wait_system_content(Names, Anchor, 300),
    ?assertMatch({ok, [#{'N' := Name}], _} when is_binary(Name),
                 quod_prolog:prove(Names, {draw, after_registration, {'N'}})),
    ?assertMatch({ok, [#{'C' := 384}], _},
                 quod_prolog:prove(
                   Names, {count, <<"halfling">>, <<"personal">>, <<"male">>, {'C'}})).

desired_content_or_none(Ns) ->
    Desired = application:get_env(
                quod, namespace_desired, #{content => #{}, brahms => #{}}),
    maps:get(Ns, maps:get(content, Desired), none).

wait_system_content(_Ns, _Anchor, 0) -> error(system_content_not_adopted);
wait_system_content(Ns, Anchor, N) ->
    case desired_content_or_none(Ns) of
        #{genesis_hash := Anchor, system_ontology := true} -> ok;
        _ -> receive after 10 -> wait_system_content(Ns, Anchor, N - 1) end
    end.


%% Founding admission is authored policy, independent of current VM vocabulary.
%% The exact compiled source consumes the allowance, including its syntax.
oversized_vocabulary_never_reaches_hosting(#{dir := Dir}) ->
    Limits = quod_ct:material_limits(founding),
    Budget = maps:get(symbols, Limits),
    Novel = fun(N) ->
                    [{list_to_atom("cold_vocabulary_" ++ integer_to_list(I)), I}
                     || I <- lists:seq(1, N)]
            end,
    TooMany = unique_ns(<<"oversized-vocabulary">>),
    Over = Novel(Budget + 1),
    ?assertEqual({error, {material_limit, founding, symbols, Budget + 1, Budget}},
                 quod_ontology:create(TooMany, [{terms, Over}])),
    ?assertEqual({ok, not_hosted}, quod_ontology:local_state(TooMany)),
    ?assertNot(filelib:is_dir(quod_ledger_store:ns_dir(Dir, TooMany))),
    AtBudget = unique_ns(<<"budget-vocabulary">>),
    {ok, #{symbols := BaseSymbols}} = quod_material_admission:usage(
        quod_prolog:terms_to_diff(Novel(1))),
    AtLimit = Novel(Budget - BaseSymbols + 1),
    ?assertMatch({ok, created, AtBudget, _},
                 quod_ontology:create(AtBudget, [{terms, AtLimit}])),
    ok = wait_ready(AtBudget, 300),
    ?assertMatch({ok, [#{}], _},
                 quod_prolog:prove(AtBudget, {cold_vocabulary_1, 1})).
