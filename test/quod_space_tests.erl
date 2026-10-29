-module(quod_space_tests).
-include_lib("eunit/include/eunit.hrl").
-export([await_runtime/1]).

ordinary_travel_atomic_test_() ->
    {timeout,90,fun() -> with_spaces(fun(C) ->
        #{namespace:=Owner,a:=A,b:=B,subject:=Subject}=C,
        ARef=ref(A,catalogue), BRef=ref(B,catalogue),
        Pose={transform,137,-211,359,17,43,89},
        committed(Owner,{space_place,artifact,0,ARef}),
        [Receiver={':-',Head,Body}]=[R||R={':-',{space_accept_placement,_,_,_},_}<-
            quod_prolog:read_terms("priv/ontologies/quod_space.pl")],
        Broken={':-',Head,{',',Body,{fail_with_reason,after_foreign_travel_ack}}},
        RemoveReceiver={retract,{':-',{space_accept_placement,{'_'},{'_'},{'_'}},{'_'}}},
        edit(B,{',',RemoveReceiver,{assertz,Broken}}),
        denied(Owner,{space_travel,artifact,1,ARef,{placed,BRef,Pose},3}),
        holds(Owner,{space_assignment,artifact,1,ARef}),
        holds(A,{space_placement,catalogue,Subject,1}),
        fails(B,{space_placement,catalogue,Subject,{'_'}}),
        holds(Owner,{attribute,artifact,transform,{transform,0,0,0,0,0,0}}),
        edit(B,{',',RemoveReceiver,{assertz,Receiver}}),
        %% A failed final receiver consequence restores every owner and pose.
        denied(Owner,{transaction,{',',
            {space_travel,artifact,1,ARef,{placed,BRef,Pose},3},
            {fail_with_reason,after_travel_ack}}},after_travel_ack),
        holds(Owner,{space_assignment,artifact,1,ARef}),
        holds(A,{space_placement,catalogue,Subject,1}),
        fails(B,{space_placement,catalogue,Subject,{'_'}}),
        holds(Owner,{attribute,artifact,transform,{transform,0,0,0,0,0,0}}),
        denied(Owner,{space_travel,artifact,0,ARef,{placed,BRef,Pose},3},
               {space_revision_conflict,artifact,1}),
        denied(Owner,{space_travel,artifact,1,BRef,{placed,ARef,Pose},3},
               {space_destination_conflict,artifact}),
        {Bytes,Sig,_}=committed(Owner,{space_travel,artifact,1,ARef,{placed,BRef,Pose},3}),
        holds(Owner,{space_location,artifact,{placed,BRef,Pose}}),
        fails(A,{space_placement,catalogue,Subject,{'_'}}),
        holds(B,{space_placement,catalogue,Subject,3}),
        committed(Owner,{space_travel,artifact,3,BRef,unplaced,4}),
        holds(Owner,{space_location,artifact,unplaced}),
        fails(B,{space_placement,catalogue,Subject,{'_'}}),
        restart(C,Owner), restart(C,A), restart(C,B),
        holds(Owner,{space_assignment,artifact,4,none}),
        ?assertMatch({ok,_,{operation_outcome,_,#{status:=committed}}},
                     quod_client_goal_ingress:resolve_operation(Bytes,Sig)),
        no_simulation([Owner,A,B])
    end,[{attribute,artifact,transform,{transform,0,0,0,0,0,0}}]) end}.

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
        ?assertMatch({ok,[#{'Spaces':=[catalogue,closed,gallery]}],_},quod_prolog:prove_ro(A,
            {findall,{'S'},{space_instance,{'S'},space},{'Spaces'}})),
        fails(A, {space_instance, catalogue, physical_space}),
        no_simulation([Owner, A, B]),
        edit(Owner, {assertz, {space_assignment_state, artifact, 7, none}}),
        edit(Owner, {assertz, {space_assignment_state, artifact, 8, none}}),
        denied(Owner, {space_place, artifact, 0, ARef}, {ambiguous_space_assignment, artifact}),
        edit(Owner, {retract, {space_assignment_state, artifact, 7, none}}),
        edit(Owner, {retract, {space_assignment_state, artifact, 8, none}}),
        edit(A, {assertz, {space_test_grant,{instance,gallery},maps:get(node, C),space_enter,ARef,placement}}),
        denied(A, {space_place, gallery, 0, ARef}),
        holds(A, {space_assignment, gallery, 0, none}),
        committed(A, {space_contain, catalogue, Subject}),
        holds(A, {space_contains, catalogue, Subject}),
        fails(Owner, {space_assignment_state, artifact, {'_'}, {'_'}}),
        %% Classes and nested spaces use their original anchored identities.
        committed(A, {space_contain, catalogue, ref(Owner, manuscript)}),
        committed(B, {space_contain, catalogue, ref(A, catalogue)}),
        holds(B, {space_contains, catalogue, ref(A, catalogue)}),
        denied(A, {space_contain, catalogue, ref(A, catalogue)}),
        denied(A, {space_contain, closed, Subject}),
        denied(A, {space_contain, catalogue, ref(Owner, private_artifact)}),
        denied(A, {space_contain, catalogue, setelement(3, Subject, <<99:256>>)}),
        denied(Owner, {space_place, artifact, 0, ref(A, absent)},
               {not_space, absent}),
        denied(Owner, {space_place, private_artifact, 0, ARef}),
        denied(Owner, {space_place, artifact, 0, ref(A, closed)}),
        holds(Owner, {space_assignment, artifact, 0, none}),
        %% Neither participant entry can commit a half admission or withdrawal.
        denied(A, {space_accept_placement, gallery, Subject, 1}),
        edit(A, {retract, {space_uninstalled, gallery}}),
        denied(Owner, {space_place, artifact, 0, ARef},
               {space_physical_change_refused, gallery, admitted}),
        holds(Owner, {space_assignment, artifact, 0, none}),
        fails(A, {space_placement, gallery, Subject, {'_'}}),
        edit(A, {assertz, {space_uninstalled, gallery}}),
        committed(Owner, {space_place, artifact, 0, ARef}),
        holds(Owner, {space_assignment_state, artifact, 1, ARef}),
        holds(A, {space_placement, gallery, Subject, 1}),
        denied(A, {space_release_placement, gallery, Subject, 1, 2}),
        denied(A, {space_accept_placement, gallery, Subject, 1},
               {space_placement_exists, gallery, Subject}),
        denied(Owner, {space_place, artifact, 1, BRef}, {space_already_placed, artifact}),
        %% Missing cleanup is a failed action, not a silently orphaned placement.
        edit(A, {retract, {space_uninstalled, gallery}}),
        denied(Owner, {space_withdraw, artifact, 1, ARef},
               {space_physical_change_refused, gallery, withdrawn}),
        holds(Owner, {space_assignment_state, artifact, 1, ARef}),
        holds(A, {space_placement, gallery, Subject, 1}),
        edit(A, {assertz, {space_uninstalled, gallery}}),
        {Bytes, Signature, _} = committed(Owner, {space_withdraw, artifact, 1, ARef}),
        holds(Owner, {space_assignment_state, artifact, 2, none}),
        denied(Owner, {space_withdraw, artifact, 1, ARef}, {space_revision_conflict, artifact, 2}),
        denied(Owner, {space_withdraw, artifact, 2, BRef}, {space_destination_conflict, artifact}),
        fails(A, {space_placement, gallery, Subject, {'_'}}),
        %% Display membership survives withdrawal of physical admission.
        holds(A, {space_member, catalogue, Subject}),
        denied(A, {space_accept_placement, gallery, Subject, 2}),
        denied(A, {space_release_placement, gallery, Subject, 2, 3}),
        denied(Owner, {space_place, artifact, 0, BRef}, {space_revision_conflict, artifact, 2}),
        committed(Owner, {space_place, artifact, 2, BRef}),
        %% Revocation uses the same action even after the subject loses its grant.
        edit(Owner, {retract, {space_test_grant,{instance,artifact},{'_'},space_leave,{'_'},{'_'}}}),
        denied(Owner, {space_withdraw, artifact, 3, BRef}),
        edit(B, {assertz, {space_test_grant,{instance,gallery},maps:get(node, C),space_remove,Subject,placement}}),
        committed(Owner, {space_withdraw, artifact, 3, BRef}),
        committed(A, {space_remove, catalogue, Subject}),
        fails(A, {space_member, catalogue, Subject}),
        %% Replay both owners from the existing histories and resolve the old request.
        History = [{Ns, quod_simplex:genesis_hash(Ns), quod_prolog:applied(Ns)} || Ns <- [Owner, A, B]],
        restart(C, Owner), restart(C, A), restart(C, B),
        [?assertEqual({Anchor, Height}, {quod_simplex:genesis_hash(Ns), quod_prolog:applied(Ns)})
         || {Ns, Anchor, Height} <- History],
        holds(Owner, {space_assignment_state, artifact, 4, none}),
        holds(Owner, {instance_of, manuscript, artifact}),
        holds(Owner, {attribute, artifact, title, <<"Original manuscript">>}),
        fails(A, {space_placement, gallery, Subject, {'_'}}),
        fails(B, {space_placement, gallery, Subject, {'_'}}),
        ?assertMatch({ok, _, {operation_outcome, _, #{status := committed}}},
                     quod_client_goal_ingress:resolve_operation(Bytes, Signature)),
        no_simulation([Owner, A, B])
    end) end}.

competing_exclusive_admissions_test_() ->
    [{atom_to_list(Space), {timeout, 60, fun() -> with_spaces(fun(#{namespace := Owner, a := A, b := B,
                                           subject := Subject}) ->
        true = quod_reg:reg({host_test, local_proof}),
        Parent = self(),
        Jobs = [begin
            Goal = {',', {space_place, artifact, 0, ref(Ns, Space)}, test_local_wait},
            {Bytes, Sig} = sign(Owner, Goal),
            {Pid, Mon} = spawn_monitor(fun() ->
                Parent ! {result, Ns, quod_client_goal_ingress:submit(Bytes, Sig)}
            end),
            {Ns, Pid, Mon}
        end || Ns <- [A, B]],
        try
            %% Both complete their proofs against revision zero before either seals.
            with_prepared(2, [], fun(Prepared) ->
            [{First, _}, {Second, _}] = Prepared,
            First ! release,
            FirstResult = receive {result, N1, R1} -> {N1, R1}
                          after 15000 -> error(first_admission_not_resolved) end,
            Second ! release,
            SecondResult = receive {result, N2, R2} -> {N2, R2}
                           after 15000 -> error(second_admission_not_resolved) end,
            Results = [FirstResult, SecondResult],
            Winners = [Ns || {Ns, {ok, _, {normalized, {committed, _, _}}}} <- Results],
            ?assertEqual(1, length(Winners)),
            ?assertEqual(1, length([R || {_, {ok, _, {normalized, {failed, _}}} = R} <- Results])),
            [Winner] = Winners, [Loser] = [Ns || Ns <- [A, B], Ns =/= Winner],
            holds(Owner, {space_assignment_state, artifact, 1, ref(Winner, Space)}),
            holds(Winner, {space_placement, Space, Subject, 1}),
            fails(Loser, {space_placement, Space, Subject, {'_'}}),
            [assert_denied(R, conflict_retry) || {Ns, R} <- Results, Ns =:= Loser]
            end)
        after
            [begin exit(Pid, kill), receive {'DOWN', Mon, process, Pid, _} -> ok
                                   after 5000 -> error(worker_survived) end end || {_, Pid, Mon} <- Jobs],
            gproc:unreg(quod_reg:name({host_test, local_proof}))
        end
    end) end}} || Space <- [gallery, catalogue]].

with_spaces(Fun) -> with_spaces(Fun, []).
with_spaces(Fun, ExtraSource) ->
    Source = quod_prolog:read_terms("priv/ontologies/quod_space.pl") ++
             quod_prolog:read_terms("test/fixtures/space-permissions.pl") ++
             quod_prolog:read_terms("priv/ontologies/quod_physics.pl"),
    Node = {agent_instance_ref, <<"host-test-node">>, {'_'}, physical_node},
    Extra = Source ++ [
        {isa, manuscript, thing}, {isa, ontology, thing},
        {instance_of, manuscript, artifact}, {instance_of, manuscript, private_artifact},
        {attribute, artifact, title, <<"Original manuscript">>},
        {space_test_grant,{instance,artifact},Node,space_enter,{'_'},{'_'}},
        {space_test_grant,{class,manuscript},Node,space_enter,{'_'},display},
        {space_test_grant,{instance,artifact},{'_'},space_leave,{'_'},{'_'}}] ++ ExtraSource,
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
    S = {'S'}, E = {'E'}, M = {'M'},
    [{can_invoke, {'_'}, Node, {'_'}, {'_'}},
     {isa, reading_room, space}, {isa, ontology, thing},
     {instance_of, reading_room, catalogue}, {instance_of, physical_space, gallery},
     {instance_of, physical_space, closed},
     {space_test_grant,{instance,catalogue},Node,space_admit,{'_'},display},
     {space_test_grant,{instance,catalogue},Node,space_admit,{'_'},placement},
     {space_test_grant,{instance,gallery},Node,space_admit,{'_'},placement},
     {space_test_grant,{instance,catalogue},Node,space_enter,{'_'},display},
     {space_test_grant,{instance,catalogue},Node,space_remove,{'_'},display},
     {space_uninstalled, gallery},
     {':-', {space_physical_change, S, E, M}, {space_uninstalled, S}}].

ref(Ns, Entity) -> {entity_ref, Ns, quod_simplex:genesis_hash(Ns), Entity}.

sign(Ns, Goal) ->
    {ok, Bytes, Sig} = quod_node_actor:signed_goal(execute, {'::', Ns, Goal},
        crypto:strong_rand_bytes(32), quod_time:now_ms() + 20000),
    {Bytes, Sig}.

committed(Ns, Goal) ->
    {Bytes, Sig} = sign(Ns, Goal),
    Result = quod_client_goal_ingress:submit(Bytes, Sig),
    ?assertMatch({ok, _, {normalized, {committed, _, _}}}, Result),
    complete(Result),
    {Bytes, Sig, Result}.

denied(Ns, Goal) -> denied(Ns, Goal, none).
denied(Ns, Goal, Reason) ->
    {Bytes, Sig} = sign(Ns, Goal),
    assert_denied(quod_client_goal_ingress:submit(Bytes, Sig), Reason).

assert_denied(Result, Reason) ->
    ?assertMatch({ok, _, {normalized, {failed, _}}}, Result),
    {ok, _, {normalized, {failed, Blob}}} = Result,
    {ok, Reasons} = quod_wire_term:decode_failure_reasons(Blob),
    case Reason of none -> ?assert(is_list(Reasons));
                   _ -> ?assertMatch({true, _}, {lists:member(Reason, Reasons), Reasons}) end.

edit(Ns, Goal) -> ?assertMatch({ok, _, _}, quod_ct:rp(Ns, Goal)).
holds(Ns, Goal) -> ?assertMatch({ok, [_ | _], _}, quod_prolog:prove_ro(Ns, Goal)).
fails(Ns, Goal) -> ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, Goal)).

no_simulation(Namespaces) ->
    [begin
        await_runtime(Ns),
        ok = quod_runtime:reconcile_resource(Ns, quod_prolog:applied(Ns), physics_worlds,
                                            all, quod_time:mono_ms() + 10000),
        ?assertEqual(#{}, gen_server:call(quod_reg:via({quod_runtime, Ns}), physics_worlds)),
        ?assertMatch({_, []}, quod_agent_hosting_tests:domain_agents(Ns))
    end || Ns <- Namespaces].

%% Prolog replay readiness precedes the runtime's asynchronous reconciliation.
%% Observe completion before the snapshot so a ready transition cannot be lost.
await_runtime(Ns) ->
    Runtime = quod_reg:where({quod_runtime,Ns}), Parent = self(), Token = make_ref(),
    Observe = fun(State,{in,{'$gen_cast',{runner_done,_,_}}},_) ->
                      Parent ! {runtime_processed,Token}, State;
                 (State,_,_) -> State end,
    ok = sys:install(Runtime,{Observe,none}),
    try await_runtime(Ns,Token,quod_time:mono_ms()+10000)
    after sys:remove(Runtime,Observe) end.

await_runtime(Ns,Token,Deadline) ->
    case quod_runtime:stats(Ns) of
        #{mode := live} -> ok;
        State ->
            receive {runtime_processed,Token} -> await_runtime(Ns,Token,Deadline)
            after max(0,Deadline-quod_time:mono_ms()) -> error({runtime_not_ready,Ns,State}) end
    end.

start(#{directory := Dir, identity := Identity}, Ns, Terms, Options) ->
    true = quod_reg:subscribe({runtime, Ns}),
    {ok, Sup} = quod_ns:start_link(Ns, maps:merge(
        #{node_id => maps:get(pubkey, Identity), identity => Identity,
          data_dir => filename:join(Dir, binary_to_list(Ns)), mode => create,
          external_predicate_modules => [quod_agent_predicates, quod_agent_hosting_tests],
          genesis_diff => quod_prolog:terms_to_diff(Terms)}, Options)),
    unlink(Sup),
    Engine = quod_reg:where({quod_prolog,Ns}),
    receive {replay_ready, {Engine,_}, _} -> ok after 10000 -> error({not_ready, Ns}) end,
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

%% Monitor every parked proof, including when gathering the second proof fails.
with_prepared(0, Workers, Fun) -> Fun(Workers);
with_prepared(Count, Workers, Fun) ->
    receive {local_proof_waiting, Pid} ->
        Mon = monitor(process, Pid),
        try with_prepared(Count - 1, [{Pid, Mon} | Workers], Fun)
        after
            exit(Pid, kill),
            receive {'DOWN', Mon, process, Pid, _} -> ok
            after 5000 -> error(proof_worker_survived) end
        end
    after 10000 -> error(admission_not_prepared) end.

distinct_owner_authorization_test_() ->
    [{atom_to_list(Space), {timeout, 60, fun() -> with_spaces(fun(#{namespace := Owner, a := A, subject := Subject}) ->
        Publisher = principal(Owner, publisher), Curator = principal(A, curator),
        PubRef = maps:get(ref, Publisher), CurRef = maps:get(ref, Curator),
        Destination = ref(A, Space),
        Contain = {space_contain, catalogue, Subject},
        Consent = {space_consent, artifact, CurRef, ref(A, catalogue), display},
        grant(A, CurRef, Contain),
        edit(A, {assertz, {space_test_grant,{instance,catalogue},CurRef,space_admit,Subject,display}}),
        %% Destination authorization does not grant a read at the instance owner.
        assert_denied(as(Curator, Contain), {not_allowed, Owner}),
        grant(Owner, CurRef, anchored(Owner, Consent)),
        %% Nor does permission to invoke the consent query itself supply delegation.
        assert_denied(as(Curator, Contain), none),
        edit(Owner, {assertz, {space_test_grant,{instance,artifact},CurRef,space_enter,ref(A, catalogue),display}}),
        assert_committed(as(Curator, Contain)),
        holds(A, {space_member, catalogue, Subject}),
        Place = {space_place, artifact, 0, Destination},
        Accept = {space_accept_placement, Space, Subject, 1},
        Assignment = {space_assignment, artifact, {'_'}, {'_'}},
        grant(Owner, PubRef, Place),
        grant(Owner, PubRef, anchored(Owner, Assignment)),
        grant(A, PubRef, anchored(A, Accept)),
        edit(Owner, {assertz, {space_test_grant,{instance,artifact},PubRef,space_enter,Destination,placement}}),
        %% The instance owner cannot borrow the curator's destination policy.
        assert_denied(as(Publisher, Place), none),
        edit(A, {assertz, {space_test_grant,{instance,Space},PubRef,space_admit,Subject,placement}}),
        assert_committed(as(Publisher, Place)),
        holds(Owner, {space_assignment_state, artifact, 1, Destination}),
        %% Destination policy cannot authorize raw source writes or the removed helper.
        Attack = {space_assign, artifact, 1, Destination, none, 2},
        assert_denied(as(Publisher, Attack), {not_allowed, Owner}),
        ?assertEqual(fail, quod_prolog:prove_ro(Owner, {current_predicate, {'/', space_assign, 5}})),
        Release = {space_release_placement, Space, Subject, 1, 2},
        grant(A, CurRef, Release),
        grant(Owner, CurRef, anchored(Owner, Assignment)),
        edit(A, {assertz, {space_test_grant,{instance,Space},CurRef,space_remove,Subject,placement}}),
        %% Even the authorized curator cannot commit just its half of withdrawal.
        assert_denied(as(Curator, Release), {space_assignment, artifact, 2, none}),
        Withdraw = {space_withdraw, artifact, 1, Destination},
        CrossWithdraw = {'::', Owner, anchored(Owner, Withdraw)},
        grant(A, CurRef, CrossWithdraw),
        assert_denied(as(Curator, CrossWithdraw), {not_allowed, Owner}),
        grant(Owner, CurRef, anchored(Owner, Withdraw)),
        grant(A, CurRef, anchored(A, Release)),
        %% No instance leave grant for curator: destination revocation is independently governed.
        edit(Owner, {retract, {space_test_grant,{instance,artifact},{'_'},space_leave,{'_'},{'_'}}}),
        assert_committed(as(Curator, CrossWithdraw)),
        holds(Owner, {space_assignment_state, artifact, 2, none}),
        fails(A, {space_placement, Space, Subject, {'_'}}),
        no_simulation([Owner, A])
    end) end}} || Space <- [gallery, catalogue]].

principal(Ns, Instance) ->
    {Pub, _} = Pair = quod_identity:generate(),
    edit(Ns, {assertz, {agent_key, Instance, Pub, active}}),
    #{ref => {agent_instance_ref, Ns, quod_simplex:genesis_hash(Ns), Instance}, pair => Pair}.

anchored(Ns, Goal) -> {',', {current_ontology_identity, Ns, quod_simplex:genesis_hash(Ns)}, Goal}.
grant(Ns, Principal, Goal) -> edit(Ns, {assertz, {can_invoke, Goal, Principal, {'_'}, Ns}}).

as(#{ref := {agent_instance_ref, Ns, Anchor, Instance}, pair := {Pub, _} = Pair}, Goal) ->
    {ok, Network} = quod_ontology:network_identity(),
    {ok, Text} = quod_client_goal_parser:format(Goal),
    {ok, InstanceText} = quod_client_goal_parser:format(Instance),
    Request = #{network_identity => Network, agent_namespace => Ns,
                agent_genesis_anchor => Anchor, agent_instance_text => InstanceText,
                signing_public_key => Pub, not_after_ms => quod_time:now_ms() + 10000,
                operation_id => crypto:strong_rand_bytes(32), mode => execute,
                parser_version => 2, goal_text => Text},
    {ok, Bytes} = quod_client_goal:encode(Request),
    quod_client_goal_ingress:submit(Bytes, quod_identity:sign(Bytes, quod_identity:key_term(Pair))).

assert_committed(Result) -> ?assertMatch({ok, _, {normalized, {committed, _, _}}}, Result).

ordinary_placement_rollback_and_recovery_test_() ->
    {timeout, 90, fun() -> with_spaces(fun(C = #{namespace := Owner, a := A,
                                               b := B, subject := Subject}) ->
        Destination = ref(A, catalogue),
        %% A caught destination refusal restores the source's staged assignment.
        committed(Owner, {';', {space_place, artifact, 0, ref(A, closed)},
                               {assertz, refusal_observed}}),
        holds(Owner, {space_assignment, artifact, 0, none}),
        fails(A, {space_placement, closed, Subject, {'_'}}),
        denied(A, {space_accept_placement, catalogue, Subject, 1}),
        {Bytes, Signature, _} = committed(Owner, {space_place, artifact, 0, Destination}),
        holds(Owner, {space_assignment_state, artifact, 1, Destination}),
        holds(A, {space_placement, catalogue, Subject, 1}),
        denied(Owner, {space_place, artifact, 1, ref(B, catalogue)},
               {space_already_placed, artifact}),
        denied(A, {space_release_placement, catalogue, Subject, 1, 2}),
        %% Placement preserves storage and owner; destinations retain only references.
        holds(Owner, {instance_of, manuscript, artifact}),
        holds(Owner, {attribute, artifact, title, <<"Original manuscript">>}),
        [fails(N, {instance_of, manuscript, artifact}) || N <- [A, B]],
        [fails(N, {attribute, artifact, {'_'}, {'_'}}) || N <- [A, B]],
        restart(C, Owner), restart(C, A),
        holds(Owner, {space_assignment, artifact, 1, Destination}),
        holds(A, {space_placement, catalogue, Subject, 1}),
        ?assertMatch({ok, _, {operation_outcome, _, #{status := committed}}},
                     quod_client_goal_ingress:resolve_operation(Bytes, Signature)),
        committed(Owner, {space_withdraw, artifact, 1, Destination}),
        holds(Owner, {space_assignment, artifact, 2, none}),
        fails(A, {space_placement, catalogue, Subject, {'_'}}),
        denied(Owner, {space_withdraw, artifact, 1, Destination},
               {space_revision_conflict, artifact, 2}),
        denied(Owner, {space_place, artifact, 0, ref(B, catalogue)},
               {space_revision_conflict, artifact, 2}),
        committed(Owner, {space_place, artifact, 2, ref(B, catalogue)}),
        no_simulation([Owner, A, B])
    end) end}.

ordinary_placement_committed_permissions_test_() ->
    {timeout, 90, fun() -> with_spaces(fun(#{namespace := Owner, a := A,
                                           node := Node, subject := Subject}) ->
        Destination = ref(A, catalogue), Place = {space_place, artifact, 0, Destination},
        edit(Owner, {assertz, {attribute, artifact, owner, Node}}),
        edit(A, {assertz, {attribute, catalogue, owner, Node}}),
        %% Both owners use the same committed guard as advisory/direct operations.
        lists:foreach(fun({Ns, Entity, Operation}) ->
            committed(Ns, {set_instance_permission, Entity, Operation, deny}),
            denied(Owner, Place),
            Grant = {set_instance_permission, Entity, Operation, allow},
            Staged = case Ns of Owner -> Grant; _ -> {'::', Ns, Grant} end,
            denied(Owner, {transaction, {',', Staged, Place}}),
            holds(Ns, {instance_permission, Entity, Operation, deny}),
            committed(Ns, Grant),
            %% An override cannot waive a compulsory inherited class requirement.
            Requirement = {class_requirement, thing, Operation, missing_requirement},
            edit(Ns, {assertz, Requirement}), denied(Owner, Place),
            edit(Ns, {retract, Requirement}),
            committed(Ns, {set_instance_permission, Entity, Operation, inherit}),
            holds(Owner, {space_assignment, artifact, 0, none}),
            fails(A, {space_placement, catalogue, Subject, {'_'}})
        end, [{Owner, artifact, space_enter}, {A, catalogue, space_admit}]),
        committed(Owner, Place),
        %% Withdrawal grants also cannot authorize themselves within the write.
        committed(Owner, {set_instance_permission, artifact, space_leave, deny}),
        denied(Owner, {space_withdraw, artifact, 1, Destination}),
        denied(Owner, {transaction, {',',
            {set_instance_permission, artifact, space_leave, allow},
            {space_withdraw, artifact, 1, Destination}}}),
        holds(Owner, {space_assignment, artifact, 1, Destination}),
        holds(A, {space_placement, catalogue, Subject, 1}),
        committed(Owner, {set_instance_permission, artifact, space_leave, inherit}),
        committed(Owner, {space_withdraw, artifact, 1, Destination})
    end) end}.

ordinary_placement_policy_conflicts_test_() ->
    [{atom_to_list(Side), {timeout, 60, fun() -> with_spaces(fun(
        #{namespace := Owner, a := A, subject := Subject}) ->
        true = quod_reg:reg({host_test, local_proof}), Parent = self(),
        {Bytes, Sig} = sign(Owner, {',', {space_place, artifact, 0, ref(A, catalogue)},
                                       test_local_wait}),
        {Caller, Monitor} = spawn_monitor(fun() ->
            Parent ! {policy_result, quod_client_goal_ingress:submit(Bytes, Sig)} end),
        try with_prepared(1, [], fun([{Proof, _}]) ->
            {Ns, Entity, Operation} = case Side of
                source -> {Owner, artifact, space_enter};
                destination -> {A, catalogue, space_admit}
            end,
            edit(Ns, {assertz, {instance_permission, Entity, Operation, deny}}),
            Proof ! release,
            receive {policy_result, Result} -> assert_denied(Result, conflict_retry)
            after 15000 -> error(policy_conflict_not_resolved) end,
            holds(Owner, {space_assignment, artifact, 0, none}),
            fails(A, {space_placement, catalogue, Subject, {'_'}})
        end)
        after
            exit(Caller, kill),
            receive {'DOWN', Monitor, process, Caller, _} -> ok
            after 5000 -> error(policy_caller_survived) end,
            gproc:unreg(quod_reg:name({host_test, local_proof}))
        end
    end) end}} || Side <- [source, destination]].

same_ontology_ordinary_placement_test_() ->
    {timeout, 60, fun() -> with_spaces(fun(#{namespace := Owner}) ->
        Destination = ref(Owner, room), Subject = ref(Owner, artifact),
        committed(Owner, {space_place, artifact, 0, Destination}),
        holds(Owner, {space_assignment, artifact, 1, Destination}),
        holds(Owner, {space_placement, room, Subject, 1}),
        committed(Owner, {space_withdraw, artifact, 1, Destination}),
        holds(Owner, {space_assignment, artifact, 2, none}),
        fails(Owner, {space_placement, room, Subject, {'_'}}),
        no_simulation([Owner])
    end, [{instance_of, space, room},
          {space_test_grant, {instance, room}, {'_'}, space_admit, {'_'}, placement}]) end}.

complete({ok, Evidence, {normalized, {committed, _, _}}}) ->
    Operation = quod_client_goal:operation_ref(Evidence),
    ?assertMatch(#{operation_state := terminal},
        quod_ct:await_operation_complete(element(2, Operation), Operation, 10000)).

conjunction([Goal]) -> Goal;
conjunction([Goal | Rest]) -> {',', Goal, conjunction(Rest)}.

ordinary_placement_and_shared_display_projection_test_() ->
    {timeout, 90, fun() -> with_spaces(fun(C = #{namespace := Owner, a := A,
            b := B, node := Node, subject := Subject, identity := Identity}) ->
        Model = <<"space-test-modelling">>, Rendering = <<"space-test-rendering">>,
        RenderingSup = start(C, Rendering,
            quod_ct:gui_terms(), #{}),
        ModelSup = start(C, Model,
            quod_ct:gui_terms() ++
            [{rendering_vocabulary, Rendering, quod_simplex:genesis_hash(Rendering)}], #{}),
        try
            [edit(Ns, {transaction, conjunction([
                {assertz, {modelling_vocabulary, Model, quod_simplex:genesis_hash(Model)}},
                {assertz, {rendering_vocabulary, Rendering, quod_simplex:genesis_hash(Rendering)}}])})
             || Ns <- [A, B]],
            edit(Owner, {assertz, {attribute, artifact, owner, Node}}),
            Destination = ref(A, catalogue),
            committed(Owner, {space_place, artifact, 0, Destination}),
            %% Two independent appearances neither move nor duplicate the subject.
            committed(A, {space_contain, catalogue, Subject}),
            committed(B, {space_contain, catalogue, Subject}),
            no_simulation([Owner, A, B]),
            Session = quod_physics_tests:simulation_session(Identity), Parent = self(),
            Views = [begin
                Socket = spawn_link(fun() -> quod_physics_tests:simulation_socket(
                    Parent, #{peer => {127,0,0,1}}) end),
                F = #{namespace => Ns, identity => Identity, space => catalogue,
                      reference => {agent_instance_ref, Ns, element(3, ref(Ns, catalogue)), viewer}},
                Open = fun() -> Socket ! {client,
                    quod_physics_tests:simulation_open(F, Session, Node)} end,
                {Ns, Socket, Open}
            end || Ns <- [A, B]],
            try
                [begin Open(), assert_manuscript_projection(Socket, Subject,
                    <<"Original manuscript">>) end || {_, Socket, Open} <- Views],
                %% Real retained socket owners reuse dependencies and resources.
                %% Trace actual work, including history/projection/I/O and physics.
                quod_lobby_tests:assert_read_has_no_io(fun() ->
                    [quod_physics_tests:renew_simulation(Socket, Open, 3)
                     || {_, Socket, Open} <- Views]
                end),
                committed(Owner, {transaction, {',',
                    {retract, {attribute, artifact, title, <<"Original manuscript">>}},
                    {assertz, {attribute, artifact, title, <<"Revised manuscript">>}}}}),
                [begin quod_physics_tests:simulation_reply(Socket, <<"refresh">>),
                    Open(), assert_manuscript_projection(Socket, Subject,
                        <<"Revised manuscript">>) end || {_, Socket, Open} <- Views],
                [{A, SocketA, OpenA}, {B, SocketB, OpenB}] = Views,
                committed(B, {space_remove, catalogue, Subject}),
                quod_physics_tests:simulation_reply(SocketB, <<"refresh">>),
                OpenB(), Empty = quod_physics_tests:simulation_reply(SocketB, <<"projection">>),
                ?assertEqual([], projection_marks(Empty)),
                %% Removing the colocated display also leaves the placed appearance.
                committed(A, {space_remove, catalogue, Subject}),
                quod_physics_tests:simulation_reply(SocketA, <<"refresh">>),
                OpenA(), assert_manuscript_projection(SocketA, Subject, <<"Revised manuscript">>),
                holds(Owner, {space_assignment, artifact, 1, Destination}),
                holds(Owner, {attribute, artifact, owner, Node}),
                holds(Owner, {instance_of, manuscript, artifact}),
                [fails(N, {instance_of, manuscript, artifact}) || N <- [A, B]],
                [fails(N, {attribute, artifact, {'_'}, {'_'}}) || N <- [A, B]],
                no_simulation([Owner, A, B])
            after [Socket ! stop || {_, Socket, _} <- Views] end
        after stop(ModelSup), stop(RenderingSup) end
    end, quod_prolog:read_terms("test/fixtures/space-view.pl")) end}.

assert_manuscript_projection(Socket, {entity_ref, Ns, Anchor, Entity}, Title) ->
    Projection = quod_physics_tests:simulation_reply(Socket, <<"projection">>),
    ?assertEqual(<<"nonphysical">>, maps:get(<<"selection">>, Projection)),
    [Root,Child]=projection_marks(Projection), Id=element(2,Root),
    ?assertEqual(64,byte_size(Id)),
    ChildId = <<Id/binary,"/title">>,
    ?assertMatch([
        {mark, Id, <<"group">>, [], {transform,100,200,300,0,45,0},
         no_surface, unlabelled, {depicts, Ns, Anchor, Entity}},
        {mark, ChildId, <<"group">>, [],
         {relative, Id, {transform,0,0,0,0,0,0}},
         no_surface, {label, Title, <<"above">>}, depicts_nothing}], [Root,Child]).

projection_marks(Projection) ->
    {ok, #{goal := Parsed}} = quod_client_goal_parser:parse(
        <<(maps:get(<<"marks">>, Projection))/binary, ".">>, 3),
    {ok, Marks} = quod_wire_term:materialize_symbols(Parsed), Marks.

physical_placement_requires_its_body_pose_test_() ->
    {timeout, 60, fun() -> with_spaces(fun(#{namespace := Owner, a := A, subject := Subject}) ->
        committed(Owner, {space_place, artifact, 0, ref(A, gallery)}),
        Pose = {space_subject_binding, gallery, Subject, {'_'}},
        fails(A, Pose),
        Binding = {physics_body_definition, gallery, 42, 3, fixed, {vector,0,0,0},
                   {live, Subject, 1, 1, <<0:256>>}},
        edit(A, {assertz, Binding}),
        holds(A, {space_subject_binding, gallery, Subject, {body_pose,42,3}}),
        fails(A, {space_subject_binding, gallery, Subject, {transform,100,200,300,0,0,0}}),
        Duplicate = setelement(3, Binding, 43), edit(A, {assertz, Duplicate}),
        fails(A, Pose),
        edit(A, {retract, Duplicate}), edit(A, {retract, Binding}),
        Stale = setelement(7, Binding, {live, Subject, 0, 1, <<0:256>>}),
        edit(A, {assertz, Stale}), fails(A, Pose)
    end) end}.
