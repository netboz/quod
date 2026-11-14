-module(quod_space_tests).
-include_lib("eunit/include/eunit.hrl").
-export([await_runtime/1]).

class_owner_creation_and_action_chain_test_() ->
    {timeout,90,fun() -> quod_agent_hosting_tests:with_host(fun(C =
            #{namespace := Store,node := Node}) ->
        {ok,[{class,SpaceClass}]} = erlog_io:read_string_terms("class(quod:space:space)."),
        Owner = <<"quod:space">>, Destination = <<"owned-space-destination">>,
        start(C,Owner,quod_prolog:read_terms("priv/ontologies/quod_space.pl"),#{}),
        %% The space is asserted without a name: its class draws one here.
        start(C,<<"quod:names">>,quod_prolog:read_terms("priv/ontologies/quod_names.pl"),#{}),
        start(C,Destination,[{can_invoke,{'_'},Node,{'_'},Destination},
            {instance_of,SpaceClass,first},{instance_of,SpaceClass,second}],#{}),
        try
            Pose = {transform,10,20,30,0,0,0}, A = ref(Destination,first), B = ref(Destination,second),
            Inputs = [{attribute,owner,Node},{attribute,dimensions,infinite}],
            Goal = conjunction([{with_build_plan,Inputs,{assert,{instance_of,SpaceClass,{'Id'}}}},
                {'=',{'Ref'},{entity_ref,Store,quod_simplex:genesis_hash(Store),{'Id'}}},
                {'::',Owner,{goal,{inside,A,{'Ref'},Pose}}}]),
            {_,_,{ok,_,{normalized,{committed,[Blob],_}}}} = committed(Store,Goal),
            {ok,Bindings} = quod_client_result:decode_binding(Blob),
            [Subject = {entity_ref,Store,_,Id}] = [V || {_,V = {entity_ref,N,_,_}} <- Bindings, N =:= Store],
            holds(Store,{instance_of,SpaceClass,Id}),
            fails(Store,{isa,space,space}),
            holds(Store,{attribute,Id,transform,Pose}),
            ?assertMatch({ok,[#{'Poses':=[Pose]}],_},quod_prolog:prove_ro(Store,
                {findall,{'P'},{attribute,Id,transform,{'P'}},{'Poses'}})),
            holds(Store,{space_assignment_state,Id,1,A}),
            holds(Destination,{space_placement,first,Subject,1}),
            Height = quod_prolog:applied(Store),
            {Bytes,Sig} = sign(Store,{'::',Owner,{goal,{inside,A,Subject,Pose}}}),
            ?assertMatch({ok,_,{normalized,{answers,_,_}}},quod_client_goal_ingress:submit(Bytes,Sig)),
            ?assertEqual(Height,quod_prolog:applied(Store)),
            edit(Destination,{assertz,{instance_permission,second,space_admit,deny}}),
            denied(Store,{'::',Owner,{goal,{inside,B,Subject,Pose}}}),
            holds(Store,{space_assignment_state,Id,1,A}),
            holds(Destination,{space_placement,first,Subject,1}),
            fails(Destination,{space_placement,second,Subject,{'_'}}),
            edit(Destination,{retract,{instance_permission,second,space_admit,deny}}),
            committed(Store,{'::',Owner,{goal,{inside,B,Subject,Pose}}}),
            holds(Store,{space_assignment_state,Id,3,B}),
            fails(Destination,{space_placement,first,Subject,{'_'}}),
            holds(Destination,{space_placement,second,Subject,3}),
            committed(Store,{'::',Owner,{goal,{unplaced,Subject}}}),
            holds(Store,{space_assignment_state,Id,4,none}),
            fails(Destination,{space_placement,second,Subject,{'_'}})
        after
            stop(quod_reg:where({quod_ns,Destination})),stop(quod_reg:where({quod_ns,<<"quod:names">>})),
            stop(quod_reg:where({quod_ns,Owner}))
        end
    end) end}.

ordinary_travel_atomic_test_() ->
    {timeout,90,fun() -> with_spaces(fun(C) ->
        #{namespace:=Owner,a:=A,b:=B,subject:=Subject}=C,
        ARef=ref(A,catalogue), BRef=ref(B,catalogue), Pose={transform,137,-211,359,17,43,89},
        committed(Owner,inside(ARef,Subject,origin())),
        Denial={instance_permission,catalogue,space_admit,deny},
        edit(B,{assertz,Denial}),
        denied(Owner,inside(BRef,Subject,Pose)),
        holds(Owner,assignment(Owner,artifact,1,ARef)),
        holds(A,{space_placement,catalogue,Subject,1}),
        fails(B,{space_placement,catalogue,Subject,{'_'}}),
        holds(Owner,{attribute,artifact,transform,origin()}),
        edit(B,{retract,Denial}),
        denied(Owner,{transaction,{',',inside(BRef,Subject,Pose),
                                      {fail_with_reason,after_travel_ack}}},after_travel_ack),
        holds(Owner,assignment(Owner,artifact,1,ARef)),
        holds(A,{space_placement,catalogue,Subject,1}),
        fails(B,{space_placement,catalogue,Subject,{'_'}}),
        holds(Owner,{attribute,artifact,transform,origin()}),
        {Bytes,Sig,_}=committed(Owner,inside(BRef,Subject,Pose)),
        holds(Owner,space({space_location,Subject,{placed,BRef,Pose}})),
        fails(A,{space_placement,catalogue,Subject,{'_'}}),
        holds(B,{space_placement,catalogue,Subject,3}),
        committed(Owner,space({goal,{unplaced,Subject}})),
        holds(Owner,space({space_location,Subject,unplaced})),
        fails(B,{space_placement,catalogue,Subject,{'_'}}),
        restart(C,Owner), restart(C,A), restart(C,B),
        holds(Owner,assignment(Owner,artifact,4,none)),
        ?assertMatch({ok,_,{operation_outcome,_,#{status:=committed}}},
                     quod_client_goal_ingress:resolve_operation(Bytes,Sig)),
        no_simulation([Owner,A,B])
    end,[{attribute,artifact,transform,{transform,0,0,0,0,0,0}}]) end}.

space_semantics_and_recovery_test_() ->
    {timeout,90,fun() -> with_spaces(fun(C=#{namespace:=Owner,a:=A,b:=B,subject:=Subject,node:=Node}) ->
        ARef=ref(A,gallery), BRef=ref(B,gallery),
        holds(A,{isa,reading_room,space_class(space)}),
        holds(A,{isa,ontology,space_class(space)}), holds(A,{isa,ontology,space_class(thing)}),
        fails(A,{isa,space,ontology}),
        fails(A,{instance_of,space_class(space),gallery}),
        holds(A,space({space_instance,ARef,space})),
        holds(A,space({space_instance,ref(A,catalogue),space})),
        fails(A,space({space_instance,ref(A,catalogue),physical_space})),
        no_simulation([Owner,A,B]),
        edit(Owner,{assertz,{space_assignment_state,artifact,7,none}}),
        edit(Owner,{assertz,{space_assignment_state,artifact,8,none}}),
        denied(Owner,inside(ARef,Subject,origin()),{ambiguous_space_assignment,artifact}),
        edit(Owner,{retract,{space_assignment_state,artifact,7,none}}),
        edit(Owner,{retract,{space_assignment_state,artifact,8,none}}),
        edit(A,{assertz,{space_test_grant,{instance,gallery},Node,space_enter,ARef,placement}}),
        denied(A,inside(ARef,ARef,origin())),
        holds(A,assignment(A,gallery,0,none)),
        committed(A,shown(ref(A,catalogue),Subject)),
        holds(A,space({space_contains,ref(A,catalogue),Subject})),
        fails(Owner,{space_assignment_state,artifact,{'_'},{'_'}}),
        committed(A,shown(ref(A,catalogue),ref(Owner,manuscript))),
        committed(B,shown(ref(B,catalogue),ref(A,catalogue))),
        holds(B,space({space_contains,ref(B,catalogue),ref(A,catalogue)})),
        denied(A,shown(ref(A,catalogue),ref(A,catalogue))),
        denied(A,shown(ref(A,closed),Subject)),
        denied(A,shown(ref(A,catalogue),ref(Owner,private_artifact))),
        denied(A,shown(ref(A,catalogue),setelement(3,Subject,<<99:256>>))),
        denied(Owner,inside(ref(A,absent),Subject,origin())),
        denied(Owner,inside(ARef,ref(Owner,private_artifact),origin())),
        denied(Owner,inside(ref(A,closed),Subject,origin())),
        holds(Owner,assignment(Owner,artifact,0,none)),
        edit(A,{retract,{space_uninstalled,gallery}}),
        denied(Owner,inside(ARef,Subject,origin()),{space_physical_change_refused,ARef,admitted}),
        holds(Owner,assignment(Owner,artifact,0,none)),
        fails(A,{space_placement,gallery,Subject,{'_'}}),
        edit(A,{assertz,{space_uninstalled,gallery}}),
        committed(Owner,inside(ARef,Subject,origin())),
        holds(Owner,{space_assignment_state,artifact,1,ARef}),
        holds(A,{space_placement,gallery,Subject,1}),
        edit(A,{retract,{space_uninstalled,gallery}}),
        denied(Owner,space({goal,{unplaced,Subject}}),{space_physical_change_refused,ARef,withdrawn}),
        holds(Owner,{space_assignment_state,artifact,1,ARef}),
        holds(A,{space_placement,gallery,Subject,1}),
        edit(A,{assertz,{space_uninstalled,gallery}}),
        {Bytes,Signature,_}=committed(Owner,space({goal,{unplaced,Subject}})),
        holds(Owner,{space_assignment_state,artifact,2,none}),
        holds(A,{space_member,catalogue,Subject}),
        committed(Owner,inside(BRef,Subject,origin())),
        edit(Owner,{retract,{space_test_grant,{instance,artifact},{'_'},space_leave,{'_'},{'_'}}}),
        denied(Owner,space({goal,{unplaced,Subject}})),
        %% A destination's display-removal grant cannot replace the source's leave ACL.
        edit(B,{assertz,{space_test_grant,{instance,gallery},Node,space_remove,Subject,placement}}),
        denied(Owner,space({goal,{unplaced,Subject}})),
        edit(Owner,{assertz,{space_test_grant,{instance,artifact},Node,space_leave,BRef,placement}}),
        committed(Owner,space({goal,{unplaced,Subject}})),
        committed(A,hidden(ref(A,catalogue),Subject)),
        fails(A,{space_member,catalogue,Subject}),
        History=[{Ns,quod_simplex:genesis_hash(Ns),quod_prolog:applied(Ns)} || Ns <- [Owner,A,B]],
        restart(C,Owner),restart(C,A),restart(C,B),
        [?assertEqual({Anchor,Height},{quod_simplex:genesis_hash(Ns),quod_prolog:applied(Ns)})
            || {Ns,Anchor,Height} <- History],
        holds(Owner,{space_assignment_state,artifact,4,none}),
        holds(Owner,{instance_of,manuscript,artifact}),
        holds(Owner,{attribute,artifact,title,<<"Original manuscript">>}),
        fails(A,{space_placement,gallery,Subject,{'_'}}),fails(B,{space_placement,gallery,Subject,{'_'}}),
        ?assertMatch({ok,_,{operation_outcome,_,#{status:=committed}}},
                     quod_client_goal_ingress:resolve_operation(Bytes,Signature)),
        no_simulation([Owner,A,B])
    end) end}.

competing_exclusive_admissions_test_() ->
    [{atom_to_list(Space), {timeout, 60, fun() -> with_spaces(fun(#{namespace := Owner, a := A, b := B,
                                           subject := Subject}) ->
        true = quod_reg:reg({host_test, local_proof}),
        Parent = self(),
        Jobs = [begin
            Goal = {',', inside(ref(Ns, Space),ref(Owner,artifact),origin()), test_local_wait},
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
    Source = quod_prolog:read_terms("test/fixtures/space-permissions.pl") ++
             quod_prolog:read_terms("priv/ontologies/quod_physics.pl"),
    Node = {agent_instance_ref, <<"host-test-node">>, {'_'}, physical_node},
    Extra = Source ++ [
        {isa, manuscript, thing},
        {instance_of, manuscript, artifact}, {instance_of, manuscript, private_artifact},
        {attribute, artifact, title, <<"Original manuscript">>},
        {space_test_grant,{instance,artifact},Node,space_enter,{'_'},{'_'}},
        {space_test_grant,{class,manuscript},Node,space_enter,{'_'},display},
        {space_test_grant,{instance,artifact},{'_'},space_leave,{'_'},{'_'}}] ++ ExtraSource,
    quod_agent_hosting_tests:with_host(fun(C = #{namespace := Owner}) ->
        Names = [<<"space-archive">>, <<"space-exhibit">>],
        Class = <<"quod:space">>,
        start(C,Class,quod_prolog:read_terms("priv/ontologies/quod_space.pl") ++
            [{can_invoke,{'_'},maps:get(node,C),{'_'},Class}],#{}),
        try
            [start(C, Ns, Source ++ destination_rules(maps:get(node, C)), #{}) || Ns <- Names],
            [A, B] = Names,
            Fun(C#{a => A, b => B, subject => ref(Owner, artifact)})
        after
            [stop(quod_reg:where({quod_ns, Ns})) || Ns <- Names ++ [Class]],
            %% The hosting fixture's original PID may have been replaced by replay.
            stop(quod_reg:where({quod_ns, Owner}))
        end
    end, Extra).

destination_rules(Node) ->
    S = {'S'}, E = {'E'}, M = {'M'},
    [{can_invoke, {'_'}, Node, {'_'}, {'_'}},
     {isa, reading_room, space_class(space)},
     {instance_of, reading_room, catalogue}, {instance_of, space_class(physical_space), gallery},
     {instance_of, space_class(physical_space), closed},
     {space_test_grant,{instance,catalogue},Node,space_admit,{'_'},display},
     {space_test_grant,{instance,catalogue},Node,space_admit,{'_'},placement},
     {space_test_grant,{instance,gallery},Node,space_admit,{'_'},placement},
     {space_test_grant,{instance,catalogue},Node,space_enter,{'_'},display},
     {space_test_grant,{instance,catalogue},Node,space_remove,{'_'},display},
     {space_uninstalled, gallery},
     {':-', {space_physical_change, S, E, M}, {space_uninstalled, S}}].

ref(Ns, Entity) -> {entity_ref, Ns, quod_simplex:genesis_hash(Ns), Entity}.

sign(Ns, Goal) ->
    {Numbered,_,_} = erlog_int:term_instance({'::',Ns,Goal},0),
    {ok, Bytes, Sig} = quod_node_actor:signed_goal(execute, Numbered,
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
holds(Ns, Goal) -> ?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_|_]}}}},read(Ns,Goal)).
fails(Ns, Goal) -> ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},read(Ns,Goal)).
read(Ns,Goal) ->
    {Numbered,_,_}=erlog_int:term_instance({'::',Ns,Goal},0),
    {ok,Bytes,Sig}=quod_node_actor:signed_goal(read,Numbered,crypto:strong_rand_bytes(32),quod_time:now_ms()+20000),
    quod_client_goal_ingress:submit(Bytes,Sig).
space_class(Class) -> {':',quod,{':',space,Class}}.
space(Goal) -> {'::',<<"quod:space">>,Goal}.
origin() -> {transform,0,0,0,0,0,0}.
inside(Destination,Subject,Pose) -> space({goal,{inside,Destination,Subject,Pose}}).
shown(Destination,Subject) -> space({goal,{shown_in,Destination,Subject}}).
hidden(Destination,Subject) -> space({goal,{not_shown_in,Destination,Subject}}).
assignment(Ns,Id,Revision,Destination) -> space({space_assignment,ref(Ns,Id),Revision,Destination}).

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
    receive {local_proof_waiting, Pid, _} ->
        Mon = monitor(process, Pid),
        try with_prepared(Count - 1, [{Pid, Mon} | Workers], Fun)
        after
            exit(Pid, kill),
            receive {'DOWN', Mon, process, Pid, _} -> ok
            after 5000 -> error(proof_worker_survived) end
        end
    after 10000 -> error(admission_not_prepared) end.

distinct_owner_authorization_test_() ->
    [{atom_to_list(Kind),{timeout,60,fun() -> with_spaces(fun(#{namespace:=Owner,a:=A,subject:=Subject}) ->
        Publisher=principal(Owner,publisher), Curator=principal(A,curator),
        PubRef=maps:get(ref,Publisher), CurRef=maps:get(ref,Curator),
        Destination=ref(A,Kind), Display=shown(ref(A,catalogue),Subject),
        grant(A,CurRef,Display),
        edit(A,{assertz,{space_test_grant,{instance,catalogue},CurRef,space_admit,Subject,display}}),
        Callback = fun(Ns,Principal) -> edit(Ns,{assertz,
            {can_invoke,{'_'},Principal,[<<"quod:space">>|{'_'}],Ns}}) end,
        Callback(A,CurRef),
        assert_denied(as(Curator,Display),{not_allowed,Owner}),
        Callback(Owner,CurRef),
        assert_denied(as(Curator,Display),none),
        edit(Owner,{assertz,{space_test_grant,{instance,artifact},CurRef,space_enter,ref(A,catalogue),display}}),
        assert_committed(as(Curator,Display)), holds(A,{space_member,catalogue,Subject}),
        Place=inside(Destination,Subject,origin()), grant(Owner,PubRef,Place),
        Callback(Owner,PubRef),Callback(A,PubRef),
        edit(Owner,{assertz,{space_test_grant,{instance,artifact},PubRef,space_enter,Destination,placement}}),
        assert_denied(as(Publisher,Place),none),
        edit(A,{assertz,{space_test_grant,{instance,Kind},PubRef,space_admit,Subject,placement}}),
        assert_committed(as(Publisher,Place)), holds(Owner,{space_assignment_state,artifact,1,Destination}),
        assert_denied(as(Publisher,{assertz,{space_assignment_state,artifact,2,none}}),{not_allowed,Owner}),
        Withdraw=space({goal,{unplaced,Subject}}), grant(A,CurRef,Withdraw),
        edit(Owner,{retract,{space_test_grant,{instance,artifact},{'_'},space_leave,{'_'},{'_'}}}),
        edit(A,{assertz,{space_test_grant,{instance,Kind},CurRef,space_remove,Subject,placement}}),
        assert_denied(as(Curator,Withdraw),none),
        edit(Owner,{assertz,{space_test_grant,{instance,artifact},CurRef,space_leave,Destination,placement}}),
        assert_committed(as(Curator,Withdraw)),
        holds(Owner,{space_assignment_state,artifact,2,none}),fails(A,{space_placement,Kind,Subject,{'_'}}),
        no_simulation([Owner,A])
    end) end}} || Kind <- [gallery,catalogue]].

principal(Ns, Instance) ->
    {Pub, _} = Pair = quod_identity:generate(),
    edit(Ns, {assertz, {agent_key, Instance, Pub, active}}),
    #{ref => {agent_instance_ref, Ns, quod_simplex:genesis_hash(Ns), Instance}, pair => Pair}.

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
        committed(Owner, {';', inside(ref(A, closed),ref(Owner,artifact),origin()),
                               {assertz, refusal_observed}}),
        holds(Owner, assignment(Owner,artifact,0,none)),
        fails(A, {space_placement, closed, Subject, {'_'}}),
        {Bytes, Signature, _} = committed(Owner, inside(Destination,ref(Owner,artifact),origin())),
        holds(Owner, {space_assignment_state, artifact, 1, Destination}),
        holds(A, {space_placement, catalogue, Subject, 1}),
        %% Placement preserves storage and owner; destinations retain only references.
        holds(Owner, {instance_of, manuscript, artifact}),
        holds(Owner, {attribute, artifact, title, <<"Original manuscript">>}),
        [fails(N, {instance_of, manuscript, artifact}) || N <- [A, B]],
        [fails(N, {attribute, artifact, {'_'}, {'_'}}) || N <- [A, B]],
        restart(C, Owner), restart(C, A),
        holds(Owner, assignment(Owner,artifact,1,Destination)),
        holds(A, {space_placement, catalogue, Subject, 1}),
        ?assertMatch({ok, _, {operation_outcome, _, #{status := committed}}},
                     quod_client_goal_ingress:resolve_operation(Bytes, Signature)),
        committed(Owner, space({goal,{unplaced,Subject}})),
        holds(Owner, assignment(Owner,artifact,2,none)),
        fails(A, {space_placement, catalogue, Subject, {'_'}}),
        committed(Owner, inside(ref(B, catalogue),ref(Owner,artifact),origin())),
        no_simulation([Owner, A, B])
    end) end}.

ordinary_placement_committed_permissions_test_() ->
    {timeout, 90, fun() -> with_spaces(fun(#{namespace := Owner, a := A,
                                           node := Node, subject := Subject}) ->
        Destination = ref(A, catalogue), Place = inside(Destination,ref(Owner,artifact),origin()),
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
            RequirementOwner = case Ns of Owner -> Owner; _ -> <<"quod:space">> end,
            edit(RequirementOwner, {assertz, Requirement}), denied(Owner, Place),
            edit(RequirementOwner, {retract, Requirement}),
            committed(Ns, {set_instance_permission, Entity, Operation, inherit}),
            holds(Owner, assignment(Owner,artifact,0,none)),
            fails(A, {space_placement, catalogue, Subject, {'_'}})
        end, [{Owner, artifact, space_enter}, {A, catalogue, space_admit}]),
        committed(Owner, Place),
        %% Withdrawal grants also cannot authorize themselves within the write.
        committed(Owner, {set_instance_permission, artifact, space_leave, deny}),
        denied(Owner, space({goal,{unplaced,Subject}})),
        denied(Owner, {transaction, {',',
            {set_instance_permission, artifact, space_leave, allow},
            space({goal,{unplaced,Subject}})}}),
        holds(Owner, assignment(Owner,artifact,1,Destination)),
        holds(A, {space_placement, catalogue, Subject, 1}),
        committed(Owner, {set_instance_permission, artifact, space_leave, inherit}),
        committed(Owner, space({goal,{unplaced,Subject}}))
    end) end}.

ordinary_placement_policy_conflicts_test_() ->
    [{atom_to_list(Side), {timeout, 60, fun() -> with_spaces(fun(
        #{namespace := Owner, a := A, subject := Subject}) ->
        true = quod_reg:reg({host_test, local_proof}), Parent = self(),
        {Bytes, Sig} = sign(Owner, {',', inside(ref(A, catalogue),ref(Owner,artifact),origin()),
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
            holds(Owner, assignment(Owner,artifact,0,none)),
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
        committed(Owner, inside(Destination,ref(Owner,artifact),origin())),
        holds(Owner, assignment(Owner,artifact,1,Destination)),
        holds(Owner, {space_placement, room, Subject, 1}),
        committed(Owner, space({goal,{unplaced,Subject}})),
        holds(Owner, assignment(Owner,artifact,2,none)),
        fails(Owner, {space_placement, room, Subject, {'_'}}),
        no_simulation([Owner])
    end, [{instance_of, space_class(space), room},
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
             || Ns <- [A, B, <<"quod:space">>]],
            edit(Owner, {assertz, {attribute, artifact, owner, Node}}),
            Destination = ref(A, catalogue),
            committed(Owner, inside(Destination,ref(Owner,artifact),origin())),
            %% Two independent appearances neither move nor duplicate the subject.
            committed(A, shown(ref(A,catalogue),Subject)),
            committed(B, shown(ref(B,catalogue),Subject)),
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
                committed(B, hidden(ref(B,catalogue),Subject)),
                quod_physics_tests:simulation_reply(SocketB, <<"refresh">>),
                OpenB(), Empty = quod_physics_tests:simulation_reply(SocketB, <<"projection">>),
                ?assertEqual([], projection_marks(Empty)),
                %% Removing the colocated display also leaves the placed appearance.
                committed(A, hidden(ref(A,catalogue),Subject)),
                quod_physics_tests:simulation_reply(SocketA, <<"refresh">>),
                OpenA(), assert_manuscript_projection(SocketA, Subject, <<"Revised manuscript">>),
                holds(Owner, assignment(Owner,artifact,1,Destination)),
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
        committed(Owner, inside(ref(A, gallery),ref(Owner,artifact),origin())),
        Pose = space({space_subject_binding,ref(A,gallery),Subject,{'_'}}),
        fails(A, Pose),
        Binding = {physics_body_definition, gallery, 42, 3, fixed, {vector,0,0,0},
                   {live, Subject, 1, 1, <<0:256>>}},
        edit(A, {assertz, Binding}),
        holds(A, space({space_subject_binding,ref(A,gallery),Subject,{body_pose,42,3}})),
        fails(A, space({space_subject_binding,ref(A,gallery),Subject,{transform,100,200,300,0,0,0}})),
        Duplicate = setelement(3, Binding, 43), edit(A, {assertz, Duplicate}),
        fails(A, Pose),
        edit(A, {retract, Duplicate}), edit(A, {retract, Binding}),
        Stale = setelement(7, Binding, {live, Subject, 0, 1, <<0:256>>}),
        edit(A, {assertz, Stale}), fails(A, Pose)
    end) end}.
