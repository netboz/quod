-module(quod_space_tests).
-include_lib("eunit/include/eunit.hrl").

space_semantics_and_recovery_test_() ->
    {timeout, 90, fun() -> with_spaces(fun(C) ->
        #{namespace := Owner, a := A, b := B, subject := Subject} = C,
        ARef = ref(A, gallery), BRef = ref(B, gallery),
        holds(A, {isa, physical_space, space}),
        holds(A, {isa, reading_room, space}),
        fails(A, {isa, ontology, space}),
        fails(A, {isa, space, ontology}),
        %% Membership remains class-first and authored; dispatch explicitly asks isa.
        fails(A, {instance_of, space, gallery}),
        holds(A, {space_instance, gallery, space}),
        holds(A, {space_instance, catalogue, space}),
        fails(A, {space_instance, catalogue, physical_space}),
        no_simulation([Owner, A, B]),
        committed(A, {space_contain, catalogue, Subject}),
        holds(A, {space_contains, catalogue, Subject}),
        fails(Owner, {physical_assignment, artifact, {'_'}, {'_'}}),
        %% Classes and nested spaces use their original anchored identities.
        committed(A, {space_contain, catalogue, ref(Owner, manuscript)}),
        committed(B, {space_contain, catalogue, ref(A, catalogue)}),
        holds(B, {space_contains, catalogue, ref(A, catalogue)}),
        denied(A, {space_contain, closed, Subject}),
        denied(A, {space_contain, catalogue, ref(Owner, private_artifact)}),
        denied(A, {space_contain, catalogue, setelement(3, Subject, <<99:256>>)}),
        denied(Owner, {space_place, artifact, 0, ref(A, catalogue)}),
        denied(Owner, {space_place, private_artifact, 0, ARef}),
        denied(Owner, {space_place, artifact, 0, ref(A, closed)}),
        holds(Owner, {space_assignment, artifact, 0, none}),
        %% Neither participant entry can commit a half admission or withdrawal.
        denied(A, {space_accept_placement, gallery, Subject, 1}),
        committed(Owner, {space_place, artifact, 0, ARef}),
        holds(Owner, {physical_assignment, artifact, 1, ARef}),
        holds(A, {space_placement, gallery, Subject, 1}),
        denied(A, {space_release_placement, gallery, Subject, 1, 2}),
        denied(Owner, {space_place, artifact, 1, BRef}),
        %% Missing cleanup is a failed action, not a silently orphaned placement.
        edit(A, {retract, {space_uninstalled, gallery}}),
        denied(Owner, {space_withdraw, artifact, 1, ARef}),
        holds(Owner, {physical_assignment, artifact, 1, ARef}),
        holds(A, {space_placement, gallery, Subject, 1}),
        edit(A, {assertz, {space_uninstalled, gallery}}),
        {Bytes, Signature, _} = committed(Owner, {space_withdraw, artifact, 1, ARef}),
        holds(Owner, {physical_assignment, artifact, 2, none}),
        fails(A, {space_placement, gallery, Subject, {'_'}}),
        %% Organizational membership survives withdrawal of physical admission.
        holds(A, {space_member, catalogue, Subject}),
        denied(Owner, {space_place, artifact, 0, BRef}),
        committed(Owner, {space_place, artifact, 2, BRef}),
        %% Revocation uses the same action even after the subject loses its grant.
        edit(Owner, {retract, {can_leave_space, artifact, {'_'}, {'_'}, {'_'}}}),
        denied(Owner, {space_withdraw, artifact, 3, BRef}),
        edit(B, {assertz, {can_remove_space_member, gallery, maps:get(node, C), Subject, physical}}),
        committed(Owner, {space_withdraw, artifact, 3, BRef}),
        committed(A, {space_remove, catalogue, Subject}),
        fails(A, {space_member, catalogue, Subject}),
        %% Replay both owners from the existing histories and resolve the old request.
        restart(C, Owner), restart(C, A), restart(C, B),
        holds(Owner, {physical_assignment, artifact, 4, none}),
        holds(Owner, {instance_of, manuscript, artifact}),
        holds(Owner, {attribute, artifact, title, <<"Original manuscript">>}),
        fails(A, {space_placement, gallery, Subject, {'_'}}),
        fails(B, {space_placement, gallery, Subject, {'_'}}),
        ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                     quod_client_goal_ingress:resolve_operation(Bytes, Signature)),
        no_simulation([Owner, A, B])
    end) end}.

competing_exclusive_admissions_test_() ->
    {timeout, 60, fun() -> with_spaces(fun(#{namespace := Owner, a := A, b := B,
                                           subject := Subject}) ->
        true = quod_reg:register({host_test, barrier}),
        Parent = self(),
        Jobs = [begin
            Goal = {',', {space_place, artifact, 0, ref(Ns, gallery)}, test_fipa_completion},
            {Bytes, Sig} = sign(Owner, Goal),
            {Pid, Mon} = spawn_monitor(fun() ->
                Parent ! {result, Ns, quod_client_goal_ingress:submit(Bytes, Sig)}
            end),
            {Ns, Pid, Mon}
        end || Ns <- [A, B]],
        try
            %% Both complete their proofs against revision zero before either seals.
            Prepared = [receive {fipa_completion_prepared, P, _} -> P
                        after 10000 -> error(admission_not_prepared) end || _ <- Jobs],
            [P ! release || P <- Prepared],
            Results = [receive {result, Ns, R} -> {Ns, R}
                       after 15000 -> error(admission_not_resolved) end || {Ns, _, _} <- Jobs],
            Winners = [Ns || {Ns, {ok, _, {normalized, {committed, _, _}}}} <- Results],
            ?assertEqual(1, length(Winners)),
            ?assertEqual(1, length([R || {_, {ok, _, {normalized, {failed, _}}} = R} <- Results])),
            [Winner] = Winners, [Loser] = [Ns || Ns <- [A, B], Ns =/= Winner],
            holds(Owner, {physical_assignment, artifact, 1, ref(Winner, gallery)}),
            holds(Winner, {space_placement, gallery, Subject, 1}),
            fails(Loser, {space_placement, gallery, Subject, {'_'}})
        after
            [begin exit(Pid, kill), receive {'DOWN', Mon, process, Pid, _} -> ok
                                   after 5000 -> error(worker_survived) end end || {_, Pid, Mon} <- Jobs],
            quod_reg:unregister({host_test, barrier})
        end
    end) end}.

with_spaces(Fun) ->
    Source = quod_prolog:read_terms("priv/ontologies/space.pl"),
    Node = {agent_instance_ref, <<"host-test-node">>, {'_'}, physical_node},
    Extra = Source ++ [
        {isa, manuscript, thing}, {isa, ontology, thing},
        {instance_of, manuscript, artifact}, {instance_of, manuscript, private_artifact},
        {attribute, artifact, title, <<"Original manuscript">>},
        {can_enter_space, artifact, Node, {'_'}, {'_'}},
        {can_enter_space, manuscript, Node, {'_'}, organizational},
        {can_leave_space, artifact, {'_'}, {'_'}, {'_'}}],
    quod_agent_hosting_tests:with_host(fun(C = #{namespace := Owner}) ->
        Names = [<<"space-archive">>, <<"space-exhibit">>],
        try
            [start(C, Ns, Source ++ destination_rules(maps:get(node, C)), #{}) || Ns <- Names],
            [A, B] = Names,
            Fun(C#{a => A, b => B, subject => ref(Owner, artifact)})
        after
            [stop(quod_reg:where({quod_ns, Ns})) || Ns <- Names],
            %% The hosting fixture's original PID may have been replaced by replay.
            stop(quod_reg:where({quod_ns, Owner}))
        end
    end, Extra).

destination_rules(Node) ->
    S = {'S'}, E = {'E'}, M = {'M'}, G = {'G'},
    [{can_invoke, {'_'}, Node, {'_'}, {'_'}},
     {isa, reading_room, space}, {isa, ontology, thing},
     {instance_of, reading_room, catalogue}, {instance_of, physical_space, gallery},
     {instance_of, physical_space, closed},
     {can_admit_space_member, catalogue, Node, {'_'}, organizational},
     {can_admit_space_member, gallery, Node, {'_'}, physical},
     {can_enter_space, catalogue, Node, {'_'}, organizational},
     {can_remove_space_member, catalogue, Node, {'_'}, organizational},
     {space_uninstalled, gallery},
     {':-', {space_physical_change, S, E, M}, {space_uninstalled, S}},
     %% An ordinary ACL entry is required even for anchored policy queries.
     {':-', {can_invoke, {',', {current_ontology_identity, {'_'}, {'_'}}, G},
             Node, {'_'}, {'_'}}, true}].

ref(Ns, Entity) -> {entity_ref, Ns, quod_simplex:genesis_hash(Ns), Entity}.

sign(Ns, Goal) ->
    {ok, Bytes, Sig} = quod_node_actor:signed_goal(execute, {'::', Ns, Goal},
        crypto:strong_rand_bytes(32), quod_time:now_ms() + 20000),
    {Bytes, Sig}.

committed(Ns, Goal) ->
    {Bytes, Sig} = sign(Ns, Goal),
    Result = quod_client_goal_ingress:submit(Bytes, Sig),
    ?assertMatch({ok, _, {normalized, {committed, _, _}}}, Result),
    {Bytes, Sig, Result}.

denied(Ns, Goal) ->
    {Bytes, Sig} = sign(Ns, Goal),
    ?assertMatch({ok, _, {normalized, {failed, _}}},
                 quod_client_goal_ingress:submit(Bytes, Sig)).

edit(Ns, Goal) -> ?assertMatch({ok, _, _}, quod_ct:rp(Ns, Goal)).
holds(Ns, Goal) -> ?assertMatch({ok, [_ | _], _}, quod_prolog:prove_ro(Ns, Goal)).
fails(Ns, Goal) -> ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, Goal)).

no_simulation(Namespaces) ->
    [begin
        ok = quod_runtime:reconcile_resource(Ns, quod_prolog:applied(Ns), physics_worlds,
                                            all, quod_time:mono_ms() + 10000),
        ?assertEqual(#{}, gen_server:call(quod_reg:via({quod_runtime, Ns}), physics_worlds)),
        ?assertMatch({_, []}, quod_agent_hosting_tests:domain_agents(Ns))
    end || Ns <- Namespaces].

start(#{directory := Dir, identity := Identity}, Ns, Terms, Options) ->
    true = quod_reg:subscribe({runtime, Ns}),
    {ok, Sup} = quod_ns:start_link(Ns, maps:merge(
        #{node_id => maps:get(pubkey, Identity), identity => Identity,
          data_dir => filename:join(Dir, binary_to_list(Ns)), mode => create,
          external_predicate_modules => [quod_agent_predicates, quod_physics_predicates,
                                         quod_agent_hosting_tests],
          genesis_diff => quod_prolog:terms_to_diff(Terms)}, Options)),
    unlink(Sup),
    receive {replay_ready, _, _} -> ok after 10000 -> error({not_ready, Ns}) end,
    quod_reg:unsubscribe({runtime, Ns}),
    {ok, #{content := Content} = Projection} = application:get_env(quod, namespace_desired),
    application:set_env(quod, namespace_desired,
        Projection#{content => Content#{Ns => #{genesis_hash => quod_simplex:genesis_hash(Ns)}}}),
    Sup.

restart(C, Ns) ->
    Anchor = quod_simplex:genesis_hash(Ns),
    stop(quod_reg:where({quod_ns, Ns})),
    start(C, Ns, [], #{mode => join, genesis_hash => Anchor}).

stop(undefined) -> ok;
stop(Pid) ->
    Mon = monitor(process, Pid), exit(Pid, shutdown),
    receive {'DOWN', Mon, process, Pid, _} -> ok after 5000 -> error(stop_timeout) end.
