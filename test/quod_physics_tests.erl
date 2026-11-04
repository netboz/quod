-module(quod_physics_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_client_goal_limits.hrl").
-export([simulation_session/1, simulation_open/3, simulation_socket/2,
         simulation_reply/2, renew_simulation/3]).

m3a_shared_component_test_() ->
    {timeout,90,fun() -> with_live_source(<<"m3a-shared">>,fun(F =
            #{namespace := Ns,source := Source,subject := Leaf,node := Principal}) ->
        {S0,S1,S2,T1,T2,Local}=m3a_component_policy(F),
        {Pid,World}=enable(F),
        Ambiguous={physics_component_admission,room,S0,S1,fixed,T1},
        commit(Ns,{assertz,Ambiguous}),
        assert_reason({ambiguous_physics_admission,S1},door_action(Ns,{space_place,inner,0,S0})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{space_assignment,inner,0,none})),
        ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_frame_member,room,S1,{'_'},{'_'},{'_'}})),
        commit(Ns,{retract,Ambiguous}),
        m3a_component_commit(Ns,{space_place,inner,0,S0}),
        m3a_component_commit(Source,{space_place,nested,0,S1}),
        %% Discard only prior processing notices, before admitting the moving
        %% body. Its subsequent sleeping notice belongs to this installation.
        flush_sleeping(Pid),
        Admission=m3a_component_commit(Source,{space_place,obstacle,0,S2}),
        await_structure(Ns,Pid,World,2),
        ?assertEqual(1,map_size(worlds(Ns))), ?assertEqual(#{},worlds(Source)),
        #{World := #{spec := Before}}=worlds(Ns),
        {4,2,dynamic,{world_mm,Position,Rotation},{solid,{box,0.25,1.0,0.25}},1.0}=
            lists:keyfind(4,1,maps:get(bodies,Before)),
        ?assertEqual(quod_physics_frames:pose([T1,T2],Local),{world_mm,Position,Rotation}),
        {ok,[#{'Path' := Path}],_}=quod_prolog:prove_ro(Ns,
            {physics_frame_member,room,S2,1,{'_'},{'Path'}}),
        ?assertMatch([{frame,S1,1,_},{frame,S2,1,_}],Path),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
            {physics_body_definition,room,4,2,dynamic,{framed,Path,Local},{live,Leaf,1,1,{'_'}}})),
        %% Ordinary containment remains in the child; the root owns only the
        %% explicit domain binding, not another placement or source entity.
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,{space_assignment,obstacle,1,S2})),
        ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{space_placement,room,Leaf,{'_'}})),
        receive {physics_status,_,Pid,World,_,sleeping} -> ok
        after 15000 -> error(shared_component_never_slept) end,
        {ok,Contact,_}=quod_physics:snapshot(Pid,#{fence => quod_physics:fence(Before),structure => 2,tick => -1}),
        ?assert(lists:any(fun({A,_,B,_})->lists:sort([A,B])=:=[1,4] end,maps:get(contacts,Contact))),
        {4,2,world,{_,Y,_},_,_}=lists:keyfind(4,1,maps:get(poses,Contact)),
        ?assert(Y < 2.0),
        %% A decorative appearance is a display reference. It cannot delegate
        %% geometry, join a run, or consume the root allocator.
        commit(Ns,{',',{assertz,{space_member,room,S2}},{assertz,{space_member,inner,Leaf}}}),
        reconcile(Ns),
        AfterDisplay=gen_server:call(Pid,status),
        OwnerWork=observe_live_geometry_work(fun() ->
            [reconcile(Ns)||_<-lists:seq(1,3)],
            {ok,Contact,_}=quod_physics:snapshot(Pid,Contact#{tick => -1}),
            ?assertMatch({ok,unchanged,_},quod_physics:snapshot(Pid,Contact)),
            ?assertEqual(maps:with([installs,steps,tick,incarnation],AfterDisplay),
                         maps:with([installs,steps,tick,incarnation],gen_server:call(Pid,status)))
        end),
        ?assertEqual([],maps:get(calls,OwnerWork)),
        %% The original source edit revises this same native body through the
        %% foreign reader; it neither recreates the actor nor the constructor.
        m3a_component_commit(Source,{physics_edit_definition,obstacle,1,{geometry,{ball,600},1}}),
        await_structure(Ns,Pid,World,3),
        GeometryWork=gen_server:call(Pid,status),
        ?assert(maps:get(installs,GeometryWork)>maps:get(installs,AfterDisplay)),
        #{World := #{spec := Changed}}=worlds(Ns),
        ?assertMatch({4,3,dynamic,_,{solid,{ball,0.6}},1.0},lists:keyfind(4,1,maps:get(bodies,Changed))),
        ?assertEqual(maps:get(generation,Before),maps:get(generation,Changed)),
        ?assertEqual({error,unavailable},quod_physics:snapshot(Pid,Contact)),
        %% A source-frame edit updates all dependent body revisions in the same
        %% multiwrite as the source transform, preserving the body identity.
        T3={transform,-2100,1600,2500,53,71,127},
        m3a_component_commit(Source,{space_represent,nested,contents,T2,contents,T3}),
        await_structure(Ns,Pid,World,4),
        FrameWork=gen_server:call(Pid,status),
        ?assert(maps:get(installs,FrameWork)>maps:get(installs,GeometryWork)),
        #{World := #{spec := Reframed}}=worlds(Ns),
        {4,4,dynamic,Framed,{solid,{ball,0.6}},1.0}=lists:keyfind(4,1,maps:get(bodies,Reframed)),
        ?assertEqual(quod_physics_frames:pose([T1,T3],Local),Framed),
        ?assertEqual(3,length(maps:get(bodies,Reframed))),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,
            {physics_definition_delegate,nested,World,{agent_instance_ref,Ns,element(3,S0),actor},1})),
        %% An independently enabled child is an explicit refusal and cannot
        %% leave a partial assignment, source delegation, or frame member.
        Independent={entity_ref,Ns,element(3,S0),independent},
        m3a_frame_fixture(Ns,independent,{transform,700,900,1100,13,29,61},Principal),
        commit(Ns,list_conjunction([
            quod_ct:source_assertion({instance_of,physical_space,independent})|
            [{assertz,R}||R<-[{physics_space,independent,enabled,actor},
                {physics_run,independent,0,none},{physics_structure,independent,1},
                {physics_next_body,independent,2},
                {physics_allowances,independent,{limits,64,64,256,1000000,{geometry,256,4096,4096}},
                    16667,-9810,10000},
                {physics_body_definition,independent,1,1,fixed,{vector,0,0,0},
                    {owned,{box,1000,500,1000},1}}]]])),
        IndependentWorld=setelement(1,Independent,world_ref),
        {IndependentPid,IndependentWorld}=installed_world(IndependentWorld),
        ?assertNotEqual(Pid,IndependentPid),
        #{IndependentWorld := #{spec := IndependentSpec}}=worlds(Ns),
        IndependentNative=gen_server:call(IndependentPid,status),
        ?assert(maps:get(generation,IndependentSpec)>0),
        ?assertEqual(2,map_size(worlds(Ns))),
        m3a_component_grants(Ns,S0,Independent,Principal,World),
        assert_reason({incompatible_physics_run,independent},
            door_action(Ns,{space_place,independent,0,S0})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{space_assignment,independent,0,none})),
        ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_frame_member,room,Independent,{'_'},{'_'},{'_'}})),
        ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_definition_delegate,independent,{'_'},{'_'},{'_'}})),
        m3a_same_world(Ns,IndependentWorld,IndependentPid,{IndependentSpec,IndependentNative}),
        %% A selected body from that separate native world cannot silently
        %% turn into an authored/static pose in this world's scene adapter.
        [assert_reason({incompatible_physics_view,IndependentWorld,World},
            door_action(Ns,{space_scene_pose,Use,World,Independent,
                {in_frame,IndependentWorld,{body_pose,1,1}},Local,{0}}))
            || Use <- [physical,display]],
        assert_reason({frame_allowance,2},door_action(Ns,{physics_frame_capacity,room,1})),
        Bounded={entity_ref,Source,element(3,S2),bounded},
        m3a_frame_fixture(Source,bounded,{transform,1700,1900,2100,19,41,73},Principal),
        m3a_component_grants(Ns,S0,Bounded,Principal,World),
        ?assertMatch({ok,_,{normalized,{failed,_}}},door_action(Source,{space_place,bounded,0,S0})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,{space_assignment,bounded,0,none})),
        ?assertMatch({fail,_},quod_prolog:prove_ro(Source,{physics_definition_delegate,bounded,{'_'},{'_'},{'_'}})),
        %% Authenticated controls and the samples share the composed domain.
        %% Restart replaces only its run incarnation, never body identities.
        commit(Ns,list_conjunction([{assertz,{can_push_physics_body,room,Principal,4}},
            {assertz,{physics_push_allowances,room,Principal,4,{push_limits,2000,3000}}}])),
        {_,Expected,ControlFrame,Ref,Initial}=install_test_control(F,Pid,World,
            {motion,free,2000,1600,1000,{query_limits,2,0,8,128},[]}),
        Command=fun(Seq,Input) -> control_goal({'::',Ns,
            {physics_control_input,room,ControlFrame,1,Seq,Input,{0}}}) end,
        Zero={drive,{vector,0,0,0},{angular,0,0,0}},
        quod_physics:ack(Pid,Ref,maps:get(tick,Initial),maps:get(origin_sequence,Initial)),
        Rested=m3a_contact_at_rest(Pid,Ref,4,4,Initial,quod_time:mono_ms()+15000),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(1,Zero)),
        _=input_frame(Pid,Ref,Principal,1),
        {ok,_,Origin,{4,4,world,{BeforeX,_,_},_,_}}=
            quod_physics:body_state(Pid,Expected,{4,4},1000),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},
            Command(2,{push,{body,4,4},{vector,1000,0,0}})),
        {Pushed,pushed}=input_frame(Pid,Ref,Principal,2),
        {4,4,world,{AfterX,_,_},_,{VelocityX,_,_}}=lists:keyfind(4,1,maps:get(poses,Pushed)),
        ?assert(AfterX>BeforeX), ?assert(VelocityX>0.0),
        ?assertEqual(Origin,maps:get(origin,Pushed)),
        OldGeneration=maps:get(generation,Reframed),
        M=monitor(process,Pid),exit(Pid,kill),
        receive {'DOWN',M,process,Pid,killed} -> ok after 5000 -> error(shared_owner_alive) end,
        {Restarted,World}=installed_world(World), ?assertNotEqual(Pid,Restarted),
        #{World := #{spec := Recovered}}=worlds(Ns),
        ?assertEqual(OldGeneration+1,maps:get(generation,Recovered)),
        ?assertEqual(maps:get(bodies,Reframed),maps:get(bodies,Recovered)),
        ?assertEqual({error,unavailable},quod_physics:snapshot(Restarted,Expected)),
        ?assertMatch({ok,_,{normalized,{failed,_}}},Command(3,Zero)),
        ?assertEqual(#{},maps:get(inputs,gen_server:call(Restarted,status))),
        m3a_same_world(Ns,IndependentWorld,IndependentPid,{IndependentSpec,IndependentNative}),
        quod_physics:unwatch(Pid,Ref),
        %% Fresh original-outcome access does not resubmit the admission.
        await_live_receipt(Admission),
        ok=quod_ct:write_evidence_json("QUOD_M3A_EVIDENCE","shared-physics",
            #{schema => <<"m3a-server-physics-v1">>,
              world => quod_client_goal_parser:value_text(World),
              source_path => quod_client_goal_parser:value_text(Path),
              source_local_pose => quod_client_goal_parser:value_text(Local),
              frames => quod_client_goal_parser:value_text([T1,T2]),
              contact_sample => m3a_public_json(Contact),
              unchanged_owner_work => m3a_public_json(OwnerWork),
              native_install_counts => [maps:get(installs,AfterDisplay),
                  maps:get(installs,GeometryWork),maps:get(installs,FrameWork)],
              before_bodies => m3a_public_json(maps:get(bodies,Before)),
              source_update_bodies => m3a_public_json(maps:get(bodies,Changed)),
              frame_update_bodies => m3a_public_json(maps:get(bodies,Reframed)),
              nested_body_rest => m3a_public_json(maps:without([inputs,registration],Rested)),
              signed_nested_body_push => #{frame => m3a_public_json(maps:without([inputs,registration],Pushed)),
                  principal => quod_client_goal_parser:value_text(Principal),
                  control_feedback => m3a_public_json(maps:get(Principal,maps:get(inputs,Pushed)))},
              recovered_bodies => m3a_public_json(maps:get(bodies,Recovered)),
              generations => [OldGeneration,maps:get(generation,Recovered)],
              independently_installed_run => m3a_public_json(maps:with(
                  [world,generation,run_token,structure,bodies],IndependentSpec)),
              independent_world => quod_client_goal_parser:value_text(IndependentWorld),
              unrelated_native_installs => [maps:get(installs,IndependentNative),
                  maps:get(installs,gen_server:call(IndependentPid,status))],
              unrelated_run_preserved => true}),
        io:format("M3a shared component: one world, two anchored frames, one source body; contact, exact source and frame updates.~n")
    end) end}.

%% A speed-limited impulse is tested after a real native contact/rest frame,
%% not at an arbitrary point during gravity-driven fall. Ack owned frames and
%% keep one absolute deadline; no state polling or readiness timer is involved.
m3a_contact_at_rest(Pid,Ref,Body,Revision,Frame,Deadline) ->
    {Body,Revision,world,_,_,{VX,VY,VZ}}=lists:keyfind(Body,1,maps:get(poses,Frame)),
    Contact=lists:any(fun({A,_,B,_})->lists:sort([A,B])=:=[1,Body] end,maps:get(contacts,Frame)),
    case Contact andalso VX*VX+VY*VY+VZ*VZ<1.0e-12 of
        true -> Frame;
        false -> receive {physics_frame,Pid,Ref,Next} ->
            quod_physics:ack(Pid,Ref,maps:get(tick,Next),maps:get(origin_sequence,Next)),
            m3a_contact_at_rest(Pid,Ref,Body,Revision,Next,Deadline)
        after max(0,Deadline-quod_time:mono_ms()) -> error(nested_body_not_at_rest) end
    end.

m3a_same_world(Ns,World,Pid,{Before,Native}) ->
    #{World := #{pid := Pid,spec := After}}=worlds(Ns),
    %% Source policy edits may advance the retained navigation guard. Native
    %% truth, guard ownership and every other selected field stay identical.
    {Guard,Prior}=maps:get(navigation_guard,Before),
    {Guard,Current}=maps:get(navigation_guard,After), ?assert(Current>=Prior),
    ?assertEqual(maps:remove(navigation_guard,Before),maps:remove(navigation_guard,After)),
    ?assertEqual(maps:with([installs,incarnation],Native),
                 maps:with([installs,incarnation],gen_server:call(Pid,status))).

m3a_shared_projection_test_() ->
    {timeout,90,fun() -> with_live_source(<<"m3a-projection">>,fun(F =
            #{namespace := Ns,source := Source,subject := Leaf,identity := Identity}) ->
        {S0,S1,S2,T1,T2,_}=m3a_component_policy(F),
        {Human,SourceGrant}=m3a_scene_policy(F),
        {Pid,World}=enable(F),
        m3a_component_commit(Ns,{space_place,inner,0,S0}),
        m3a_component_commit(Source,{space_place,nested,0,S1}),
        m3a_component_commit(Source,{space_place,obstacle,0,S2}),
        await_structure(Ns,Pid,World,2),
        commit(Ns,{',',{assertz,{space_member,room,S2}},{assertz,{space_member,inner,Leaf}}}),
        Parent=self(),Socket=spawn_link(fun()->simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
        Session=simulation_session(Identity),
        Open=fun()->Socket ! {client,simulation_open(F,Session,Human)} end,
        try
            Open(),Projection=simulation_reply(Socket,<<"projection">>),
            ?assertEqual(<<"active">>,maps:get(<<"selection">>,Projection)),
            Marks=m3a_projection_term(Projection,<<"marks">>),
            LeafPoses=[P||{mark,_,<<"group">>,[],P,_,_,{depicts,N,A,E}}<-Marks,
                           {entity_ref,N,A,E}=:=Leaf],
            ?assertEqual([body_frame_pose,body_frame_pose,body_pose],
                lists:sort([element(1,element(3,P))||P<-LeafPoses])),
            {view_frame,S0,[],[{body_frame,4,2,PathId,[T1,T2]}]}=
                m3a_projection_term(Projection,<<"view_frame">>),
            ?assertEqual(64,byte_size(PathId)),
            ?assertEqual(1,length(maps:get(<<"poses">>,maps:get(<<"frame">>,Projection)))),
            State=simulation_state(Socket),
            ?assert(lists:member(Source,maps:values(maps:get(owners,State)))),
            Before=quod_runtime:stats(Ns),
            renew_simulation(Socket,Open,3),
            ?assertEqual(maps:get(source_attempts,Before),maps:get(source_attempts,quod_runtime:stats(Ns))),
            %% The C source delta reaches the outer A view through its retained
            %% dependency. Reopen proves current revisions, never a replay.
            m3a_component_commit(Source,{physics_edit_definition,obstacle,1,{geometry,{ball,600},1}}),
            _=simulation_reply(Socket,<<"refresh">>),await_structure(Ns,Pid,World,3),
            Open(),Changed=simulation_reply(Socket,<<"projection">>),
            ChangedMarks=m3a_projection_term(Changed,<<"marks">>),
            ?assertEqual(3,length([ok||{mark,_,<<"sphere">>,_,_,_,_,_}<-ChangedMarks])),
            ?assertEqual(lists:sort([Id||{mark,Id,_,_,_,_,_,_}<-Marks]),
                         lists:sort([Id||{mark,Id,_,_,_,_,_,_}<-ChangedMarks])),
            %% Disclosure and installation delegation are independent. Removing
            %% source read access withdraws the visible content, not its mass.
            commit(Source,{'$quod_retract_exact',SourceGrant}),
            _=simulation_reply(Socket,<<"refresh">>),
            Open(),Denied=simulation_reply(Socket,<<"projection">>),
            ?assertEqual(<<"unavailable">>,maps:get(<<"selection">>,Denied)),
            ?assertEqual([],m3a_projection_term(Denied,<<"marks">>)),
            reconcile(Ns),?assertMatch(#{navigation_ready := true},gen_server:call(Pid,status)),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
                {physics_body_definition,room,4,3,dynamic,{'_'},{live,Leaf,1,2,{'_'}}})),
            %% Branch withdrawal releases every delegate/body atomically while
            %% descendants retain their ordinary source-owned placements.
            m3a_component_commit(Ns,{space_withdraw,inner,1,S0}),
            await_structure(Ns,Pid,World,4),
            ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_frame_member,room,{'_'},{'_'},{'_'},{'_'}})),
            ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_body_definition,room,4,{'_'},{'_'},{'_'},{'_'}})),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,{space_assignment,obstacle,1,S2})),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,{space_assignment,nested,1,S1})),
            ?assertMatch({fail,_},quod_prolog:prove_ro(Source,{physics_definition_delegate,{'_'},World,{'_'},{'_'}})),
            ok=quod_ct:write_evidence_json("QUOD_M3A_EVIDENCE","recursive-projection",
                #{schema => <<"m3a-server-projection-v1">>,outer => m3a_projection_receipt(Projection),
                  source_update => m3a_projection_receipt(Changed),revoked_source => Denied,
                  source_attempts => [maps:get(source_attempts,Before),
                                      maps:get(source_attempts,quod_runtime:stats(Ns))]})
        after Socket ! stop end
    end) end}.

root_body_appearance_frame_test_() ->
    {timeout,60,fun() -> with_live_source(<<"root-appearance">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination,subject := Subject}) ->
        {Pid,World}=enable(F),
        m3a_component_commit(Source,{space_place,obstacle,0,Destination}),
        await_structure(Ns,Pid,World,2),
        Mark={mark,<<"appearance">>,<<"group">>,[],{body_frame_pose,4,2},
              no_surface,unlabelled,{depicts,Source,element(3,Subject),obstacle}},
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_view_bodies,[Mark],room})),
        ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_view_bodies,
            [setelement(8,Mark,{depicts,Source,element(3,Subject),other_entity})],room})),
        {ok,_,{normalized,{read,_,{answers,_,[Binding]}}}}=
            body_read(Ns,{physics_scene_frames,room,[Mark],{0}}),
        {ok,[{_,[{body_frame,4,2,PathId,[]}]}]}=quod_client_result:decode_binding(Binding),
        ?assertEqual(64,byte_size(PathId)),
        #{World := #{spec := Spec}}=worlds(Ns),
        ?assertEqual(3,length(maps:get(bodies,Spec)))
    end) end}.

m3a_projection_term(Projection,Key) ->
    {ok,#{goal := Parsed}}=quod_client_goal_parser:parse(<<(maps:get(Key,Projection))/binary,".">>,3),
    {ok,Term}=quod_wire_term:materialize_symbols(Parsed),Term.

m3a_projection_receipt(#{<<"frame">> := Frame}=Projection) ->
    Registration=maps:get(<<"registration">>,Frame),
    Projection#{<<"frame">> => (maps:remove(<<"registration">>,Frame))#{
        <<"registration_sha256">> => binary:encode_hex(crypto:hash(sha256,Registration)),
        <<"redactions">> => [<<"disposable viewer registration">>]}}.

%% Native samples contain tuples and arbitrary public incarnation bytes. Keep
%% those bytes explicit; projections above retain their actual wire JSON.
m3a_public_json(B) when is_binary(B) ->
    #{binary_base64url => base64:encode(B,#{mode => urlsafe,padding => false})};
m3a_public_json(T) when is_tuple(T) -> m3a_public_json(tuple_to_list(T));
m3a_public_json(L) when is_list(L) -> [m3a_public_json(V)||V<-L];
m3a_public_json(M) when is_map(M) -> maps:map(fun(_,V)->m3a_public_json(V) end,M);
m3a_public_json(V) when is_integer(V);is_float(V);V=:=true;V=:=false;V=:=null -> V;
m3a_public_json(A) when is_atom(A) -> atom_to_binary(A,utf8).

m3a_scene_policy(#{namespace := Ns,source := Source,identity := Identity}) ->
    A=quod_simplex:genesis_hash(Ns),B=quod_simplex:genesis_hash(Source),
    Human={agent_instance_ref,Ns,A,viewer},
    Rendering= <<"physics-test-rendering">>,RA=quod_simplex:genesis_hash(Rendering),
    [commit(N,{assertz,{modelling_vocabulary,Rendering,RA}})||N<-[Ns,Source]],
    commit(Ns,list_conjunction([{assertz,{agent_key,viewer,maps:get(pubkey,Identity),active}},
        {assertz,{can_invoke,{'_'},Human,{'_'},Ns}},{assertz,{can_view_physics,room,Human}}])),
    commit(Rendering,{assertz,{can_invoke,{'_'},Human,{'_'},Rendering}}),
    Grant={':-',{can_invoke,{',',{current_ontology_identity,Source,B},{'Query'}},Human,{'_'},Source},
        {member,{'Query'},[{entity_scene,{'_'},{'_'},{'_'}},{eidolon,{'_'},{'_'},{'_'}}]}},
    Pose={transform,300,500,-900,23,47,71},
    Rows=[Grant,
        {':-',{entity_scene,obstacle,{'Mode'},{appearance,obstacle,solid,obstacle,Pose,
            [{eidolon,{'Mode'},solid,{recipe,Source,B,m3a_leaf}}]}},{member,{'Mode'},[playing,edition]}},
        {':-',{eidolon,m3a_leaf,obstacle,[{part,<<"shape">>,{'Shape'},{transform,0,0,0,0,0,0},
            {surface,<<"#6A90D9">>,0,700,0,[]},unlabelled,depicts_nothing}]},
            {',',{physics_definition,obstacle,{'_'},{geometry,{'SourceShape'},{'_'}}},
                 {m3a_leaf_shape,{'SourceShape'},{'Shape'}}}},
        {':-',{m3a_leaf_shape,{box,{'X'},{'Y'},{'Z'}},{box,{'W'},{'H'},{'D'}}},
            list_conjunction([{is,{'W'},{'*',2,{'X'}}},{is,{'H'},{'*',2,{'Y'}}},{is,{'D'},{'*',2,{'Z'}}}])},
        {':-',{m3a_leaf_shape,{ball,{'R'}},{sphere,{'D'}}},{is,{'D'},{'*',2,{'R'}}}}],
    commit(Source,list_conjunction([{assertz,R}||R<-Rows])),{Human,Grant}.

m3a_component_commit(Ns,Goal) ->
    Result=door_action(Ns,Goal),
    case Result of
        {ok,_,{normalized,{committed,_,_}}} -> await_live_receipt(Result),Result;
        _ -> error({m3a_component_refused,Goal,brief(Result)})
    end.

m3a_component_policy(#{namespace := Ns,source := Source,subject := Leaf,node := P}) ->
    A=quod_simplex:genesis_hash(Ns), B=quod_simplex:genesis_hash(Source),
    S0={entity_ref,Ns,A,room},S1={entity_ref,Ns,A,inner},S2={entity_ref,Source,B,nested},
    World={world_ref,Ns,A,room},
    T1={transform,1300,3300,2900,17,43,89},T2={transform,-1900,1100,2300,31,67,113},
    Local={transform,300,500,-900,23,47,71},
    m3a_frame_fixture(Ns,inner,T1,P),m3a_frame_fixture(Source,nested,T2,P),
    m3a_component_grants(Ns,S0,S1,P,World),
    m3a_component_grants(Ns,S1,S2,P,World),
    commit(Source,list_conjunction([{assertz,R} || R <-
        [{attribute,obstacle,transform,Local},
         {space_test_grant,{instance,nested},P,space_admit,Leaf,placement},
         {space_test_grant,{instance,nested},P,space_remove,Leaf,placement},
         {space_test_grant,{instance,obstacle},P,space_enter,S2,placement},
         {space_test_grant,{instance,obstacle},P,space_leave,S2,placement},
         {':-',{space_physical_change,{'W'},{'S'},{'C'}},{physics_space_change,{'W'},{'S'},{'C'}}}]])),
    commit(Ns,list_conjunction([{assertz,{physics_frame_allowance,room,2}},
        {assertz,{physics_component_admission,room,S2,Leaf,dynamic,Local}},
        {retract,{physics_allowances,room,{'Limits'},{'Step'},0,{'Budget'}}},
        {assertz,{physics_allowances,room,{'Limits'},{'Step'},-9810,{'Budget'}}}])),
    {S0,S1,S2,T1,T2,Local}.

m3a_frame_fixture(Ns,Entity,Pose,P) ->
    commit(Ns,list_conjunction([quod_ct:source_assertion({instance_of,space,Entity})] ++
        [{assertz,R} || R <- [{attribute,Entity,exterior,contents},{attribute,Entity,transform,Pose},
            {attribute,Entity,dimensions,infinite},
            {instance_permission,Entity,space_represent,allow},
            {can_edit_physics_definition,Entity,P}]] )).

m3a_component_grants(Root,Parent={entity_ref,Dest,_,Space},Child={entity_ref,Source,_,Entity},P,World) ->
    Authority={agent_instance_ref,Root,element(3,World),actor},
    commit(Source,list_conjunction([{assertz,R} || R <-
        [{space_test_grant,{instance,Entity},P,space_enter,Parent,placement},
         {space_test_grant,{instance,Entity},P,space_leave,Parent,placement},
         {can_delegate_physics_definition,Entity,P,World,Authority}]])),
    commit(Dest,list_conjunction([{assertz,R} || R <-
        [{space_test_grant,{instance,Space},P,space_admit,Child,placement},
         {space_test_grant,{instance,Space},P,space_remove,Child,placement}]])),
    commit(Root,list_conjunction([{assertz,R} || R <-
        [{physics_frame_admission,room,Parent,Child},{can_refresh_physics_definition,room,P,Child}]] )).

first_host_and_complete_configuration_commit_together_test_() ->
    [{binary_to_list(Ns),{timeout,90,fun() -> with_world(Ns,
        fun(F) -> first_physical_configuration(F, Gravity) end,
        fun(Rules) -> [R || R <- Rules, not lists:member(element(1,R),
            [instance_of,physics_space,physics_run,physics_structure,
             physics_next_body,physics_allowances,physics_body_definition])] end)
    end}} || {Ns,Gravity} <- [{<<"gallery-first-physics">>,-9810},
                             {<<"workshop-first-physics">>,-1620}]].

first_physical_configuration(#{namespace := Ns,node := Node,reference := Agent,key := Key}, Gravity) ->
    Anchor = element(3,Agent), Remote = setelement(2,Node,<<"remote-node">>),
    Grant = {can_assign_agent_host,Node,actor,none,0,Node,Key},
    RemoteGrant = {can_assign_agent_host,Node,actor,none,0,Remote,<<33:256>>},
    commit(Ns,list_conjunction([{assertz,R} || R <-
        [Grant,RemoteGrant,{can_prepare_agent_key,Node,actor,none,0,Node}]])),
    {ok,ReadBytes,ReadSignature} = quod_node_actor:signed_goal(read,
        {'::',Ns,{prepare_agent_key_custody,Agent,none,0,Node,{0}}},
        crypto:strong_rand_bytes(32),quod_time:now_ms()+10000),
    {ok,_,{normalized,{read,_,{answers,1,[Prepared]}}}} =
        quod_client_goal_ingress:submit(ReadBytes,ReadSignature),
    ?assertEqual({ok,[{<<"V0">>,Key}]},quod_durable_term:decode_result(Prepared)),
    ?assertEqual(#{},worlds(Ns)),
    ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{space_instance,room,physical_space})),
    ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{agent_host,actor,{'_'},{'_'},{'_'}})),
    Rows = first_physics_rows(Ns,Anchor,Node,Gravity),
    %% Authored intent precedes runtime initialization, as in ordinary founding.
    commit(Ns,list_conjunction([quod_ct:source_assertion(R) || R <- Rows])),
    Goal = first_physics_goal(Ns,Anchor,Node,Key),
    [Camera] = [R || R = {':-',{physics_viewpoint,_,_,_,_,_,_},_} <- Rows],
    %% Missing camera rolls back both initialization and the attempted removal.
    ?assertMatch({ok,_,{normalized,{failed,_}}},
        door_action(Ns,{transaction,{',',{retract,Camera},Goal}})),
    assert_unconfigured(Ns),
    [Floor] = [R || R = {physics_definition,floor,_,_} <- Rows],
    [Allowance] = [R || R = {physics_allowances,_,_,_,_,_} <- Rows],
    Limited = setelement(3,Allowance,setelement(2,element(3,Allowance),3)),
    lists:foreach(fun({Before,Invalid}) ->
        ?assertMatch({ok,_,{normalized,{failed,_}}},door_action(Ns,
            {transaction,list_conjunction([{retract,Before},{assertz,Invalid},Goal])})),
        assert_unconfigured(Ns),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,Before))
    end,[{Floor,{physics_definition,floor,1,{geometry,{box,-1,250,8000},1}}},
         {Allowance,Limited}]),
    true = quod_reg:reg({host_test,local_proof}),
    true = quod_reg:subscribe({physics,Ns}),
    try
        %% A prepared key reserves no assignment right. Revoke after proof,
        %% before commit, and require the ordinary predicate OCC conflict.
        Parent = self(), Tag = make_ref(),
        {Caller,Monitor} = spawn_monitor(fun() -> Parent ! {first_assignment,Tag,
            door_action(Ns,{',',Goal,test_local_wait})} end),
        Proof = receive
            {local_proof_waiting,P} -> P;
            {first_assignment,Tag,Early} -> error({initial_proof_failed,brief(Early)})
        after 5000 -> error(initial_proof_missing) end,
        try
            commit(Ns,{retract,Grant}), Proof ! release,
            receive {first_assignment,Tag,Refused} ->
                ?assertMatch({ok,_,{normalized,{error,conflict_retry}}},Refused)
            after 10000 -> error(initial_revocation_not_resolved) end
        after
            Proof ! release, exit(Caller,kill),
            receive {'DOWN',Monitor,process,Caller,_} -> ok after 1000 -> error(initial_caller_alive) end
        end,
        assert_unconfigured(Ns), commit(Ns,{assertz,Grant}),
        %% Both candidates prove against the absent assignment. Releasing the
        %% local candidate first makes the competing destination deterministic.
        Results = live_compete(Ns,[Goal,first_physics_goal(Ns,Anchor,Remote,<<33:256>>)]),
        ?assertMatch([{1,{ok,_,{normalized,{committed,_,_}}}},
                      {2,{ok,_,{normalized,{error,conflict_retry}}}}],Results),
        {Pid,World = {world_ref,Ns,Anchor,room}} = installed(Ns),
        #{World := #{spec := Spec}} = worlds(Ns),
        ?assertEqual(Gravity/1000,maps:get(gravity,Spec)),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{agent_hosted,actor,Node,1,Key})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
            {physics_control,room,Node,1,{controlled,pilot,eye}})),
        {ok,[#{'Body' := PilotBody}],_} = quod_prolog:prove_ro(Ns,
            {physics_agent,room,pilot,1,{'Body'},{'_'}}),
        ?assertMatch({PilotBody,_,controlled,_,{solid,{capsule,0.5,0.25}},_},
            lists:keyfind(PilotBody,1,maps:get(bodies,Spec))),
        ?assertMatch(#{navigation_ready := true},gen_server:call(Pid,status)),
        ?assertEqual(Anchor,quod_simplex:genesis_hash(Ns))
    after gproc:unreg(quod_reg:name({host_test,local_proof})) end.

assert_unconfigured(Ns) ->
    [?assertMatch({fail,_},quod_prolog:prove_ro(Ns,Goal)) || Goal <-
        [{agent_host,actor,{'_'},{'_'},{'_'}},{agent_key,actor,{'_'},active},
         {space_assignment_state,{'_'},{'_'},{'_'}},
         {physics_control,room,{'_'},{'_'},{'_'}},
         {physics_body_definition,room,{'_'},{'_'},{'_'},{'_'},{'_'}}]],
    reconcile(Ns), ?assertEqual(#{},worlds(Ns)).

first_physics_goal(Ns,Anchor,Host,Key) ->
    {transaction,list_conjunction([
        {current_ontology_identity,Ns,Anchor},
        {physics_initial_host,room,{'PreviousHost'}},
        {retract,{physics_initial_host,room,{'PreviousHost'}}},
        {assertz,{physics_initial_host,room,Host}},
        {physics_initialize,room,Host,Key}])}.

first_physics_rows(Ns,Anchor,Principal,Gravity) ->
    Destination = {entity_ref,Ns,Anchor,room}, World = {world_ref,Ns,Anchor,room},
    Authority = {agent_instance_ref,Ns,Anchor,actor},
    Definitions = [{floor,fixed,{vector,0,-250,0},{box,8000,250,8000}},
        {pilot,controlled,{vector,0,1200,3000},{capsule,500,250}},
        {table,fixed,{vector,-1500,550,0},
            {parts,[{part,{vector,0,0,0},{box,600,100,300}},
                    {part,{vector,0,-300,0},{box,150,300,150}}]}},
        {arch,fixed,{vector,0,0,-4000},
            {parts,[{part,{vector,-2000,1500,0},{box,250,1500,250}},
                    {part,{vector,2000,1500,0},{box,250,1500,250}},
                    {part,{vector,0,3250,0},{box,2250,250,250}}]}}],
    Bodies = lists:append([[{instance_of,case E of pilot -> agent; _ -> thing end,E},
        {physics_definition,E,1,{geometry,Shape,1}}, {physics_definition_allowance,E,1000000},
        {physics_admission,room,{entity_ref,Ns,Anchor,E},Kind,Pose},
        {space_test_grant,{instance,E},Principal,space_enter,Destination,placement},
        {space_test_grant,{instance,room},Principal,space_admit,{entity_ref,Ns,Anchor,E},placement},
        {can_delegate_physics_definition,E,Principal,World,Authority}]
        || {E,Kind,Pose,Shape} <- Definitions]),
    Bodies ++ [{instance_of,physical_space,room},{physics_space,room,enabled,actor},
     {physics_run,room,0,none},{physics_structure,room,1},{physics_next_body,room,0},
     {physics_initial_host,room,Principal},{physics_initial_control,room,pilot,eye},
     {can_initialize_physics,room,Principal},
     {':-',{space_physical_change,{'W'},{'Subject'},{'Change'}},
            {physics_space_change,{'W'},{'Subject'},{'Change'}}},
     {physics_allowances,room,{limits,16,16,128,1000000,{geometry,32,128,128}},16667,Gravity,10000},
     {':-',{physics_agent,room,pilot,1,{'Body'},
         {motion,{grounded,900},2000,1600,500,{query_limits,2,0,8,128},[]}},
         {physics_body_definition,room,{'Body'},{'_'},controlled,{'_'},
            {live,{entity_ref,Ns,Anchor,pilot},{'_'},{'_'},{'_'}}}},
     {':-',{physics_viewpoint,room,pilot,eye,{'Body'},
         {pose,{vector,0,700,0},{rotation,0,100,0}},view_only},
         {physics_agent,room,pilot,1,{'Body'},{'_'}}},
     {can_view_physics,room,Principal},{can_control_physics_agent,room,Principal,pilot}].

live_source_control_continuity_test_() ->
    {timeout,90,fun() -> with_live_source(<<"live-controls">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination,subject := Subject}) ->
        commit(Ns,{',',{retract,{physics_admission,room,Subject,fixed,{vector,4000,1000,0}}},
            {assertz,{physics_admission,room,Subject,controlled,{vector,4000,1000,0}}}}),
        {Pid,World} = enable(F),
        Admission = door_action(Source,{space_place,obstacle,0,Destination}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Admission),
        {Pid,World} = installed_structure(Ns,2), await_live_receipt(Admission),
        Limits = {query_limits,2,0,8,128},
        {_,Expected,Frame,Ref,Initial} = install_test_control(F,Pid,World,
            {motion,free,2000,1600,1000,Limits,[]},4),
        Command = fun(Sequence) -> control_goal({'::',Ns,{physics_control_input,room,Frame,1,Sequence,
            {drive,{vector,0,0,0},{angular,0,0,0}},{0}}}) end,
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(1)),
        quod_physics:ack(Pid,Ref,maps:get(tick,Initial),maps:get(origin_sequence,Initial)),
        _ = input_frame(Pid,Ref,maps:get(node,F),1),
        Runtime = quod_reg:where({quod_runtime,Ns}), Parent = self(), Token = make_ref(),
        Observe = fun(State,{in,{quod_foreign_follow,_,_,{Source0,_},
                        {advanced,_,Height,_,_,_,_}}},_) when Source0 =:= Source ->
                        Parent ! {live_source_height,Token,Height}, State;
                     (State,_,_) -> State end,
        ok = sys:install(Runtime,{Observe,none}),
        try
            Before = gen_server:call(Pid,status),
            commit(Source,{assertz,{unrelated_note,hello}}), Height = quod_prolog:applied(Source),
            await_live_source_height(Token,Height), _ = quod_runtime:stats(Ns),
            After = gen_server:call(Pid,status),
            ?assertMatch(#{navigation_ready := true},After),
            ?assertEqual(maps:get(inputs,Before),maps:get(inputs,After)),
            ?assertEqual(maps:get(installs,Before),maps:get(installs,After)),
            receive {physics_refresh,Pid,Ref} -> error(unrelated_source_retired_view) after 0 -> ok end,
            %% The original registration remains valid. No source invocation
            %% grant is needed for hot input after signed view admission.
            commit(Source,{retract,{can_invoke,{'_'},maps:get(node,F),{'_'},Source}}),
            await_live_source_height(Token,quod_prolog:applied(Source)), _ = quod_runtime:stats(Ns),
            ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(2)),
            ?assertMatch({ok,_,_},quod_physics:snapshot(Pid,Expected#{tick => -1})),
            quod_physics:ack(Pid,Ref,maps:get(tick,Initial),maps:get(origin_sequence,Initial))
        after sys:remove(Runtime,Observe), quod_physics:unwatch(Pid,Ref) end
    end) end}.

live_source_signed_view_test_() ->
    {timeout,90,fun() -> with_live_source(<<"live-signed-view">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination,subject := Subject,
              identity := Identity}) ->
        commit(Ns,{',',{retract,{physics_admission,room,Subject,fixed,{vector,4000,1000,0}}},
            {assertz,{physics_admission,room,Subject,controlled,{vector,4000,1000,0}}}}),
        {Pid,World} = enable(F), Admission = door_action(Source,{space_place,obstacle,0,Destination}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Admission),
        {Pid,World} = installed_structure(Ns,2), await_live_receipt(Admission),
        Human = {agent_instance_ref,Ns,quod_simplex:genesis_hash(Ns),viewer},
        commit(Ns,{assertz,{agent_key,viewer,maps:get(pubkey,Identity),active}}),
        {_,_,OldFrame,OldRef,_} = install_test_control(F#{node => Human},Pid,World,
            {motion,free,2000,1600,1000,{query_limits,2,0,8,128},[]},4),
        quod_physics:unwatch(Pid,OldRef), _ = gen_server:call(Pid,status),
        %% This fixture intentionally depicts no source content. Replace the
        %% composed default, so a failed source read cannot become a dependency
        %% before backtracking to this explicitly authored empty view.
        DefaultView = default_world_view_rule(),
        commit(Ns,list_conjunction([{'$quod_retract_exact',DefaultView},
            {assertz,{can_view_physics,room,Human}},{assertz,{world_view,room,playing,[]}}])),
        reconcile(Ns),
        Parent = self(), Socket = spawn_link(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
        Runtime = quod_reg:where({quod_runtime,Ns}), Token = make_ref(),
        Observe = fun(State,{in,{quod_foreign_follow,_,_,{Source0,_},
                        {advanced,_,Height,_,_,_,_}}},_) when Source0 =:= Source ->
                        Parent ! {live_source_height,Token,Height}, State;
                     (State,_,_) -> State end,
        ok = sys:install(Runtime,{Observe,none}),
        try
            Session = simulation_session(Identity),
            Socket ! {client,simulation_open(F,Session,Human)},
            Projection = simulation_reply(Socket,<<"projection">>),
            #{pid := Pid,ref := Ref,view := View,owners := Owners} = simulation_state(Socket),
            ?assertNot(lists:member(Source,maps:values(Owners))),
            Initial = maps:get(<<"frame">>,Projection),
            Registration = base64:decode(maps:get(<<"registration">>,Initial),#{mode => urlsafe,padding => false}),
            Frame = setelement(3,OldFrame,Registration),
            Command = fun(Seq) ->
                Goal = {'::',Ns,{physics_control_input,room,Frame,1,Seq,
                    {drive,{vector,0,0,0},{angular,0,0,0}},{0}}},
                {ok,Text} = quod_client_goal_parser:format(Goal),
                Request = #{network_identity => <<42:256>>,agent_namespace => Ns,
                    agent_genesis_anchor => element(3,Human),agent_instance_text => <<"viewer.">>,
                    signing_public_key => maps:get(pubkey,Identity),operation_id => crypto:strong_rand_bytes(32),
                    not_after_ms => quod_time:now_ms()+10000,mode => control,parser_version => 3,goal_text => Text},
                {ok,Bytes} = quod_client_goal:encode(Request),
                quod_client_goal_ingress:submit(Bytes,quod_identity:sign(Bytes,Identity))
            end,
            ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(1)),
            commit(Source,{assertz,{unrelated_note,visible_view_stays_open}}),
            await_live_source_height(Token,quod_prolog:applied(Source)), _ = quod_runtime:stats(Ns),
            ?assertMatch(#{pid := Pid,ref := Ref,view := View,installed := true},simulation_state(Socket)),
            ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(2)),
            %% The source editor and viewer are different principals. Only
            %% the editor has source entry grants; both use ordinary signed goals.
            Edit = door_action(Source,{physics_edit_definition,obstacle,1,{geometry,{ball,600},1}}),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},Edit),
            _ = simulation_reply(Socket,<<"refresh">>),
            await_live_receipt(Edit), {Pid,World} = installed_structure(Ns,3),
            Socket ! {client,simulation_open(F,Session,Human)},
            Fresh = simulation_reply(Socket,<<"projection">>),
            ?assertNotEqual(Registration,base64:decode(maps:get(<<"registration">>,maps:get(<<"frame">>,Fresh)),
                #{mode => urlsafe,padding => false}))
        after sys:remove(Runtime,Observe), Socket ! stop end
    end) end}.

unsimulated_definition_edit_test_() ->
    {timeout,60,fun() -> with_live_source(<<"unsimulated-definitions">>,fun(
            #{namespace := Ns,source := Source,destination := Destination}) ->
        Hook = {':-',{space_physical_change,{'W'},{'S'},{'Change'}},{physics_space_change,{'W'},{'S'},{'Change'}}},
        commit(Ns,{',',{'$quod_retract_exact',Hook},{assertz,{space_physical_change,room,{'_'},{'_'}}}}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Source,{space_place,obstacle,0,Destination})),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},
            door_action(Source,{physics_edit_definition,obstacle,1,{geometry,{ball,600},1}})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,{physics_definition,obstacle,2,{geometry,{ball,600},1}})),
        ?assertEqual(#{},worlds(Ns))
    end) end}.

live_source_failure_isolates_world_test_() ->
    {timeout,90,fun() -> with_live_source(<<"independent-worlds">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination,node := Node}) ->
        {First,World} = enable(F), Admission = door_action(Source,{space_place,obstacle,0,Destination}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Admission),
        {First,World} = installed_structure(Ns,2), await_live_receipt(Admission),
        {Second,_SecondWorld} = independent_world(Ns,Node), reconcile(Ns),
        Before = gen_server:call(Second,status),
        #{World := #{spec := FirstSpec}} = worlds(Ns),
        Runtime = quod_reg:where({quod_runtime,Ns}), Parent = self(), Token = make_ref(),
        Observe = fun(State,{in,{physics_invalidation_seen,P,W,_}},_)
                        when P =:= First, W =:= World -> Parent ! {first_world_invalidated,Token}, State;
                     (State,_,_) -> State end,
        ok = sys:install(Runtime,{Observe,none}),
        try
            commit(Source,{retract,{physics_definition_delegate,obstacle,World,maps:get(authority,FirstSpec),1}}),
            receive {first_world_invalidated,Token} -> ok after 5000 -> error(source_not_invalidated) end,
            ?assertMatch({error,{physics_materialization,[{World,{no_solution,_,_}}]}},reconcile_physics(Ns)),
            ?assertMatch(#{navigation_ready := false},gen_server:call(First,status)),
            ?assertMatch(#{navigation_ready := true},gen_server:call(Second,status)),
            ?assertEqual(maps:with([installs,steps,tick,incarnation],Before),
                         maps:with([installs,steps,tick,incarnation],gen_server:call(Second,status)))
        after sys:remove(Runtime,Observe) end
    end) end}.

independent_world(Ns,Node) ->
    Anchor = quod_simplex:genesis_hash(Ns), World = {world_ref,Ns,Anchor,archive},
    Actor = {agent_instance_ref,Ns,Anchor,other},
    {ok,Blob} = quod_wire_term:encode_canonical(Actor), {ok,Key} = quod_agent_vault:prepare(Blob,0),
    commit(Ns,{goal,{agent_hosted,other,Node,1,Key}}),
    Rules = [{can_invoke,{physics_store_request,{'_'},{'_'},{'_'},{'_'},{'_'},{'_'}},Actor,{'_'},Ns},
             {can_invoke,{physics_activate,{'_'},{'_'},{'_'}},Actor,{'_'},Ns},
             {can_request_agent_signature,Node,other,{'_'}},
             {instance_of,physical_space,archive},{physics_space,archive,enabled,other},
             {physics_run,archive,0,none},{physics_structure,archive,1},{physics_next_body,archive,2},
             {physics_allowances,archive,{limits,8,8,32,1000000,{geometry,8,64,64}},16667,0,10000},
             {physics_body_definition,archive,1,1,fixed,{vector,0,0,0},{owned,{ball,500},1}}],
    commit(Ns,list_conjunction([quod_ct:source_assertion(R) || R <- Rules])),
    installed_world(Ns,World).

m3a_frame_failure_isolates_world_test_() ->
    [{atom_to_list(Failure),{timeout,90,fun() ->
        Ns = <<"frame-isolation-",(atom_to_binary(Failure))/binary>>,
        with_live_source(Ns,fun(F = #{source := Source,node := Node}) ->
            {S0,S1,S2,T1,_,_} = m3a_component_policy(F),
            {First,World} = enable(F),
            m3a_component_commit(Ns,{space_place,inner,0,S0}),
            m3a_component_commit(Source,{space_place,nested,0,S1}),
            m3a_component_commit(Source,{space_place,obstacle,0,S2}),
            await_structure(Ns,First,World,2),
            {Second,SecondWorld} = independent_world(Ns,Node),
            {_,Expected,ControlFrame,Ref,_} = install_test_control(F,First,World,
                {motion,free,2000,1600,1000,{query_limits,2,0,8,128},[]}),
            FrameExpected = Expected#{tick => -1},
            ?assertMatch({ok,_,_},quod_physics:snapshot(First,FrameExpected)),
            Stop = {drive,{vector,0,0,0},{angular,0,0,0}},
            Command = fun(Sequence) -> control_goal({'::',Ns,
                {physics_control_input,room,ControlFrame,1,Sequence,Stop,{0}}}) end,
            ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(1)),
            #{SecondWorld := #{spec := HealthySpec}} = worlds(Ns),
            HealthyExpected = #{fence => quod_physics:fence(HealthySpec),
                incarnation => maps:get(run_token,HealthySpec),structure => 1,tick => -1},
            {ok,HealthyFrame,_} = quod_physics:snapshot(Second,HealthyExpected),
            Before = gen_server:call(Second,status),
            {ok,[#{'Revision' := Revision,'Path' := Path}],_} = quod_prolog:prove_ro(Ns,
                {physics_frame_member,room,S1,1,{'Revision'},{'Path'}}),
            Member = {physics_frame_member,room,S1,1,Revision,Path},
            Removed = case Failure of
                export -> {attribute,inner,transform,T1};
                member -> Member
            end,
            Broken = door_action(Ns,{retract,Removed}),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},Broken), await_live_receipt(Broken),
            case Failure of
                export -> ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,Member));
                member -> ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,Member))
            end,
            Selection = reconcile_physics(Ns),
            HealthyResult = quod_physics:snapshot(Second,HealthyExpected),
            Label = "frame-"++atom_to_list(Failure),
            ok = quod_ct:write_evidence_json("QUOD_M3A_EVIDENCE",Label++"-selection",
                #{world => quod_client_goal_parser:value_text(World),
                  retained_member => Failure =:= export,
                  removed => quod_client_goal_parser:value_text(Removed),
                  selection => m3a_public_json(Selection),
                  independent_snapshot_available => element(1,HealthyResult) =:= ok}),
            ?assertMatch({ok,_,_},HealthyResult),
            ?assertMatch({error,{physics_materialization,[{World,_}]}},Selection),
            receive {physics_refresh,First,Ref} -> ok
            after 5000 -> error(frame_control_not_invalidated) end,
            ?assertEqual({error,unavailable},quod_physics:snapshot(First,FrameExpected)),
            ?assertMatch({ok,_,{normalized,{failed,_}}},Command(2)),
            Work = observe_live_geometry_work(fun() ->
                [?assertMatch({error,{physics_materialization,[{World,_}]}},reconcile_physics(Ns))
                    || _ <- lists:seq(1,3)]
            end),
            ?assertEqual([],maps:get(calls,Work)),
            m3a_same_world(Ns,SecondWorld,Second,{HealthySpec,Before}),
            ?assertEqual(maps:with([installs,steps,tick,incarnation],Before),
                maps:with([installs,steps,tick,incarnation],gen_server:call(Second,status))),
            {ok,StillHealthy,_} = HealthyResult,
            ?assertEqual(maps:with([poses,contacts,tick,origin,origin_sequence],HealthyFrame),
                maps:with([poses,contacts,tick,origin,origin_sequence],StillHealthy)),
            Repair = door_action(Ns,{assertz,Removed}),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},Repair), await_live_receipt(Repair),
            %% Recovery follows the committed source notification, without a
            %% request-time reconciliation to discover or repair readiness.
            await_structure(Ns,First,World,2),
            ?assertMatch({ok,_,_},quod_physics:snapshot(First,FrameExpected)),
            assert_reason(stale_registration,Command(3)),
            {ok,FreshRef,FreshView} = quod_physics:watch(First,Expected,none),
            FreshFrame = setelement(3,ControlFrame,maps:get(registration,FreshView)),
            ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal({'::',Ns,
                {physics_control_input,room,FreshFrame,1,4,Stop,{0}}})),
            Repeats = observe_live_geometry_work(fun() -> [reconcile(Ns)||_<-lists:seq(1,3)] end),
            ?assertEqual([],maps:get(calls,Repeats)),
            m3a_same_world(Ns,SecondWorld,Second,{HealthySpec,Before}),
            ?assertMatch({ok,_,_,_},quod_physics:body_state(Second,HealthyExpected,{1,1},1000)),
            ?assertEqual(maps:with([installs,steps,tick,incarnation],Before),
                maps:with([installs,steps,tick,incarnation],gen_server:call(Second,status))),
            ok = quod_ct:write_evidence_json("QUOD_M3A_EVIDENCE",Label++"-acceptance",
                #{schema => <<"m3a-r1-frame-isolation-v1">>,
                  world => quod_client_goal_parser:value_text(World),
                  independent_world => quod_client_goal_parser:value_text(SecondWorld),
                  exact_frame_member => quod_client_goal_parser:value_text(Member),
                  failed_selection => m3a_public_json(Selection),
                  unchanged_failed_work => m3a_public_json(Work),
                  unchanged_recovered_work => m3a_public_json(Repeats),
                  independent_native_before => m3a_public_json(maps:with([installs,steps,tick,incarnation],Before)),
                  independent_native_after => m3a_public_json(maps:with([installs,steps,tick,incarnation],gen_server:call(Second,status))),
                  affected_signed_control_refused => true,notification_recovery => true,
                  old_registration_refused => true,fresh_signed_control_recovered => true,
                  independent_native_identity_preserved => true}),
            quod_physics:unwatch(First,FreshRef)
        end)
    end}} || Failure <- [export,member]].

installed_world(Ns,Expected={world_ref,Ns,_,_}) -> installed_world(Expected).

await_live_source_height(Token,Minimum) ->
    receive
        {live_source_height,Token,H} when H >= Minimum -> ok;
        {live_source_height,Token,_} -> await_live_source_height(Token,Minimum)
    after 5000 -> error(source_delta_not_delivered) end.

live_source_busy_owner_coalesces_test_() ->
    {timeout,90,fun() -> with_live_source(<<"live-source-busy">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination}) ->
        {Pid,World} = enable(F),
        Admission = door_action(Source,{space_place,obstacle,0,Destination}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Admission),
        {Pid,World} = installed_structure(Ns,2), await_live_receipt(Admission), reconcile(Ns),
        Runtime = quod_reg:where({quod_runtime,Ns}), Parent = self(), Token = make_ref(),
        Observe = fun(State,{in,{quod_foreign_follow,_,_,{Source0,_},
                        {advanced,_,Height,_,_,_,_}}},_) when Source0 =:= Source ->
                        Parent ! {live_source_height,Token,Height}, State;
                     (State,_,_) -> State end,
        ok = sys:install(Runtime,{Observe,none}), ok = sys:suspend(Pid),
        try
            [begin
                commit(Source,{assertz,{unrelated_note,N}}),
                await_live_source_height(Token,quod_prolog:applied(Source)),
                _ = quod_runtime:stats(Ns)
             end || N <- lists:seq(1,10)],
            {message_queue_len,Queued} = process_info(Pid,message_queue_len),
            ?assert(Queued =< 2)
        after sys:resume(Pid), sys:remove(Runtime,Observe) end,
        {Pid,World} = installed_structure(Ns,2)
    end) end}.

live_source_shared_owner_busy_test_() ->
    {timeout,60,fun() -> with_live_source(<<"live-shared-busy">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination}) ->
        {Pid,World} = enable(F),
        Admission = door_action(Source,{space_place,obstacle,0,Destination}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Admission),
        {Pid,World} = installed_structure(Ns,2), await_live_receipt(Admission), reconcile(Ns),
        Foreign = quod_reg:where({foreign_log,node}),
        ok = sys:suspend(Foreign),
        try
            %% The retained verified reader remains alive and unchanged even
            %% while the shared log owner handles unrelated work.
            reconcile(Ns),
            ?assertMatch(#{navigation_ready := true},gen_server:call(Pid,status))
        after sys:resume(Foreign) end
    end) end}.

live_source_reader_replacement_test_() ->
    {timeout,60,fun() -> with_live_source(<<"live-reader-replacement">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination}) ->
        {Pid,World} = enable(F),
        Admission = door_action(Source,{space_place,obstacle,0,Destination}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Admission),
        {Pid,World} = installed_structure(Ns,2), await_live_receipt(Admission), reconcile(Ns),
        Identity = {Source,quod_simplex:genesis_hash(Source)},
        {ok,Probe} = quod_foreign_log:follow(Identity,projection),
        Reader = live_probe_reader(Probe,Identity),
        ok = quod_foreign_log:unfollow(Probe),
        Before = gen_server:call(Pid,status),
        Runtime = quod_reg:where({quod_runtime,Ns}), Parent = self(), Token = make_ref(),
        Observe = fun(State,{in,{quod_foreign_follow,_,_,Identity0,
                        {resnapshot,_,_,#{reader := {Next,_}}}}},_)
                        when Identity0 =:= Identity, Next =/= Reader ->
                        Parent ! {live_reader_replaced,Token,Next}, State;
                     (State,_,_) -> State end,
        ok = sys:install(Runtime,{Observe,none}),
        try
            Monitor = monitor(process,Reader), exit(Reader,kill),
            receive {'DOWN',Monitor,process,Reader,killed} -> ok after 5000 -> error(reader_not_retired) end,
            receive {live_reader_replaced,Token,_} -> ok after 5000 -> error(reader_not_rebuilt) end,
            _ = quod_runtime:stats(Ns),
            %% The same source/follow and physics incarnation now use a fresh
            %% reader generation, acknowledged by the actual runtime consumer.
            {Pid,World} = installed_structure(Ns,2),
            ?assertEqual(maps:get(incarnation,Before),maps:get(incarnation,gen_server:call(Pid,status)))
        after sys:remove(Runtime,Observe) end
    end) end}.

live_probe_reader(Probe,Identity) ->
    receive {quod_foreign_follow,Probe,Notice,Identity,State} ->
        quod_foreign_log:ack(Probe,Notice),
        case State of
            {resnapshot,_,_,#{reader := {Reader,_}}} -> Reader;
            {advanced,_,_,_,#{reader := {Reader,_}},_,_} -> Reader;
            _ -> live_probe_reader(Probe,Identity)
        end
    after 5000 -> error(missing_retained_reader) end.

live_source_requires_stored_subscription_test_() ->
    {timeout,60,fun() -> with_live_source(<<"live-subscription">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination}) ->
        _ = enable(F), Subscription = {subscribes,Source,quod_simplex:genesis_hash(Source)},
        commit(Ns,{',',{retract,Subscription},{assertz,{':-',Subscription,{'=',1,1}}}}),
        ?assertMatch({ok,_,{normalized,{failed,_}}},door_action(Source,{space_place,obstacle,0,Destination})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,{space_assignment,obstacle,0,none})),
        commit(Ns,{assertz,Subscription}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Source,{space_place,obstacle,0,Destination})),
        _ = installed_structure(Ns,2)
    end) end}.

live_source_authority_replacement_test_() ->
    {timeout,90,fun() -> with_live_source(<<"live-authority">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination,node := Node}) ->
        {Old,World} = enable(F),
        Admission = door_action(Source,{space_place,obstacle,0,Destination}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Admission),
        {Old,World} = installed_structure(Ns,2), await_live_receipt(Admission),
        #{World := #{spec := Before}} = worlds(Ns),
        Authority = {agent_instance_ref,Ns,quod_simplex:genesis_hash(Ns),other},
        {ok,Blob} = quod_wire_term:encode_canonical(Authority),
        {ok,Key} = quod_agent_vault:prepare(Blob, 0),
        commit(Ns,{goal,{agent_hosted,other,Node,1,Key}}),
        commit(Ns,list_conjunction([{assertz,R} || R <- [
            {can_invoke,{physics_store_request,{'_'},{'_'},{'_'},{'_'},{'_'},{'_'}},Authority,{'_'},Ns},
            {can_invoke,{physics_activate,{'_'},{'_'},{'_'}},Authority,{'_'},Ns},
            {can_request_agent_signature,Node,other,{'_'}}]])),
        Switch = {physics_assign_authority,room,actor,other},
        ?assertMatch({ok,_,{normalized,{failed,_}}},door_action(Ns,Switch)),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_space,room,enabled,actor})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,
            {physics_definition_delegate,obstacle,World,maps:get(authority,Before),1})),
        commit(Source,{assertz,{can_delegate_physics_definition,obstacle,Node,World,Authority}}),
        Monitor = monitor(process,Old),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,Switch)),
        receive {'DOWN',Monitor,process,Old,_} -> ok after 5000 -> error(old_authority_alive) end,
        {New,World} = installed_structure(Ns,2), ?assertNotEqual(Old,New),
        #{World := #{spec := After}} = worlds(Ns),
        ?assertEqual(Authority,maps:get(authority,After)),
        ?assertEqual(maps:get(generation,Before)+1,maps:get(generation,After)),
        ?assertEqual(maps:get(bodies,Before),maps:get(bodies,After)),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,
            {physics_definition_delegate,obstacle,World,Authority,1}))
    end) end}.

live_source_moving_door_contact_test_() ->
    {timeout,90,fun() -> with_live_source(<<"live-door">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination,subject := Subject}) ->
        Actor = {agent_instance_ref,Ns,quod_simplex:genesis_hash(Ns),actor},
        Rules = [{can_invoke,{physics_store_hinged_request,{'_'},{'_'},{'_'},{'_'}},Actor,{'_'},Ns},
                 {can_invoke,{physics_finish_hinged,{'_'},{'_'}},Actor,{'_'},Ns},
                 {can_close_physics_hinged,room,10,{'_'}},
                 {physics_hinged_class,basic_door,1,
                    hinged_recipe()}],
        commit(Ns,list_conjunction([{assertz,R} || R <- Rules] ++ [
            {retract,{physics_admission,room,Subject,fixed,{vector,4000,1000,0}}},
            {assertz,{physics_admission,room,Subject,fixed,{vector,1500,1500,-500}}},
            {retract,{physics_body_definition,room,2,{'_'},{'_'},{'_'},{'_'}}}])),
        {Pid,World} = enable(F),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},
            door_action(Source,{space_place,obstacle,0,Destination})),
        {Pid,World} = installed_structure(Ns,2),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
            {physics_add_hinged,room,10,11,{local,basic_door,1},{vector,0,1500,0},2})),
        {Pid,World} = installed_structure(Ns,3),
        true = quod_reg:subscribe({runtime,Ns}),
        try
            Id = <<153:256>>, Request = {close,1,Id},
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Ns,{physics_close_hinged,room,10,0,Id})),
            await_door(Ns,Request,{blocked,4}),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
                {physics_hinged,room,10,1,{finished,Request,{blocked,4}}}))
        after quod_reg:unsubscribe({runtime,Ns}) end
    end) end}.

%% Signed source edits and both receiver consequences use the actual atomic lane.
%% The runtime reads the retained certified projection, without a reaction rule.
live_source_lifecycle_test_() ->
    [{binary_to_list(WorldNs),{timeout,90,fun() ->
        with_live_source(WorldNs,fun(F = #{namespace := Ns,source := Source,subject := Subject,
                                     destination := Destination,node := Principal}) ->
            {Pid,World} = enable(F),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Source,{space_place,obstacle,0,Destination})),
            {Pid,World} = installed_structure(Ns,2),
            #{World := #{spec := Before}} = worlds(Ns),
            ?assertMatch({4,2,fixed,_,{solid,{box,0.25,1.0,0.25}},_},
                         lists:keyfind(4,1,maps:get(bodies,Before))),
            Query = {place,{pose,{vector,3000,1000,0},{rotation,0,0,0}}},
            Limits = {query_limits,2,0,8,128},
            ?assertMatch({ok,_,{0,0,0},{clear,_,_}},quod_physics:motion_query(Pid,
                #{fence => quod_physics:fence(Before),structure => 2,
                  incarnation => maps:get(run_token,Before)}, {2,1},Query,Limits,1000)),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{space_placement,room,Subject,1})),
            %% Receiver denial rolls back the staged source shape as well.
            commit(Ns,{retract,{can_refresh_physics_definition,room,Principal,Subject}}),
            ?assertMatch({ok,_,{normalized,{failed,_}}},door_action(Source,
                {physics_edit_definition,obstacle,1,{geometry,{ball,750},1}})),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,
                {physics_definition,obstacle,1,{geometry,{box,250,1000,250},1}})),
            commit(Ns,{assertz,{can_refresh_physics_definition,room,Principal,Subject}}),
            commit(Ns,{retract,{can_edit_physics,room,Principal}}),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Source,
                {physics_edit_definition,obstacle,1,{geometry,{ball,750},1}})),
            {Pid,World} = installed_structure(Ns,3),
            #{World := #{spec := After}} = worlds(Ns),
            ?assertMatch({4,3,fixed,_,{solid,{ball,0.75}},_},
                         lists:keyfind(4,1,maps:get(bodies,After))),
            ?assertMatch({ok,_,{0,0,0},{occupied,4,_}},quod_physics:motion_query(Pid,
                #{fence => quod_physics:fence(After),structure => 3,
                  incarnation => maps:get(run_token,After)}, {2,1},Query,Limits,1000)),
            ?assertEqual(lists:keyfind(2,1,maps:get(bodies,Before)),
                         lists:keyfind(2,1,maps:get(bodies,After))),
            ?assertMatch({error,unavailable},quod_physics:body_state(Pid,
                #{fence => quod_physics:fence(Before),structure => 2},{4,2},1000)),
            %% Deletion composes withdrawal and keeps the assignment tombstone.
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Source,{physics_delete_definition,obstacle,2})),
            {Pid,World} = installed_structure(Ns,4),
            #{World := #{spec := Removed}} = worlds(Ns),
            ?assertEqual(false,lists:keyfind(4,1,maps:get(bodies,Removed))),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,
                {',',{space_assignment_state,obstacle,2,none},{physics_definition,obstacle,3,none}})),
            ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{space_placement,room,Subject,{'_'}})),
            %% Recreate under the same entity, but never reuse its retired body.
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Source,
                {physics_edit_definition,obstacle,3,{geometry,{capsule,500,250},1}})),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Source,{space_place,obstacle,2,Destination})),
            {Pid,World} = installed_structure(Ns,5),
            #{World := #{spec := Recreated}} = worlds(Ns),
            ?assertEqual(false,lists:keyfind(4,1,maps:get(bodies,Recreated))),
            ?assertMatch({5,5,fixed,_,{solid,{capsule,0.5,0.25}},_},
                         lists:keyfind(5,1,maps:get(bodies,Recreated)))
        end)
    end}} || WorldNs <- [<<"live-workshop">>,<<"live-observatory">>]].

live_source_stale_install_and_revocation_test_() ->
    {timeout,90,fun() -> with_live_source(<<"live-fenced">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination,subject := Subject}) ->
        {Pid,World} = enable(F),
        Admission = door_action(Source,{space_place,obstacle,0,Destination}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Admission),
        {Pid,World} = installed_structure(Ns,2),
        await_live_receipt(Admission), reconcile(Ns),
        #{World := #{spec := Spec}} = worlds(Ns),
        Grant = {physics_definition_delegate,obstacle,World,maps:get(authority,Spec),1},
        Runtime = quod_reg:where({quod_runtime,Ns}), Parent = self(), Token = make_ref(),
        Pause = fun(false,{in,{'$gen_call',{Worker,_},{resource_selected,physics_worlds,_}}},_) ->
                        true = erlang:suspend_process(Worker),
                        Parent ! {source_selection_paused,Token,Worker}, true;
                   (State,_,_) -> State end,
        Seen = fun(State,{in,{physics_invalidation_seen,Pid0,World0,_}},_)
                        when Pid0 =:= Pid, World0 =:= World ->
                        Parent ! {source_invalidated,Token}, State;
                  (State,_,_) -> State end,
        ok = sys:install(Runtime,{Pause,false}), ok = sys:install(Runtime,{Seen,none}),
        {Caller,Monitor} = spawn_monitor(fun() ->
            Result = quod_runtime:reconcile_resource(Ns,quod_prolog:applied(Ns),
                         physics_worlds,all,quod_time:mono_ms()+10000),
            Parent ! {source_selection_result,Token,Result}
        end),
        Worker = receive {source_selection_paused,Token,W} -> W
                 after 5000 -> error(source_selector_not_paused) end,
        try
            _ = worlds(Ns),
            %% Administrative grant removal is deliberately outside normal
            %% withdrawal: it must fail closed, not erase the committed body.
            commit(Source,{retract,Grant}),
            receive {source_invalidated,Token} -> ok
            after 5000 -> error(source_did_not_invalidate) end,
            ?assertMatch(#{navigation_ready := false},gen_server:call(Pid,status)),
            true = resume_live_worker(Runtime,Worker),
            receive {source_selection_result,Token,Result} ->
                ?assertEqual({error,selection_superseded},Result)
            after 5000 -> error(stale_source_install_not_rejected) end,
            receive {'DOWN',Monitor,process,Caller,normal} -> ok
            after 5000 -> error(source_caller_not_finished) end,
            ?assertMatch({error,{physics_materialization,[{World,{no_solution,_,_}}]}},reconcile_physics(Ns)),
            ?assertMatch(#{World := #{pid := Pid}},worlds(Ns)),
            ?assertMatch(#{navigation_ready := false},gen_server:call(Pid,status)),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{space_placement,room,Subject,1})),
            commit(Source,{assertz,Grant}),
            {Pid,World} = installed_structure(Ns,2)
        after
            catch resume_live_worker(Runtime,Worker),
            catch sys:remove(Runtime,Pause), catch sys:remove(Runtime,Seen)
        end
    end) end}.

resume_live_worker(Runtime,Worker) ->
    _ = sys:replace_state(Runtime,fun(State) -> true = erlang:resume_process(Worker), State end), true.

live_source_unchanged_work_and_recovery_test_() ->
    {timeout,90,fun() -> with_live_source(<<"live-recovery">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination}) ->
        {Pid,World} = enable(F),
        Admission = door_action(Source,{space_place,obstacle,0,Destination}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Admission),
        {Pid,World} = installed_structure(Ns,2), await_live_receipt(Admission),
        reconcile(Ns), Before = gen_server:call(Pid,status),
        assert_no_live_geometry_work(fun() ->
            [reconcile(Ns) || _ <- lists:seq(1,20)],
            ?assertEqual(maps:with([installs,steps,tick,incarnation],Before),
                         maps:with([installs,steps,tick,incarnation],gen_server:call(Pid,status)))
        end),
        %% Retained source owner replacement rebuilds current verified state.
        %% No subscribed reaction exists to reconstruct the body.
        #{World := #{spec := BeforeSpec}} = worlds(Ns),
        Expected = #{fence => quod_physics:fence(BeforeSpec),structure => 2,
                     incarnation => maps:get(run_token,BeforeSpec)},
        ?assertMatch({ok,_,{0,0,0},_},quod_physics:body_state(Pid,Expected,{4,2},1000)),
        Runtime = quod_reg:where({quod_runtime,Ns}), Parent = self(), Token = make_ref(),
        Seen = fun(State,{in,{physics_invalidation_seen,Owner,_,_}},_) when Owner =:= Pid ->
                        Parent ! {live_source_lost,Token}, State;
                  (State,_,_) -> State end,
        ok = sys:install(Runtime,{Seen,none}),
        try
            Foreign = quod_reg:where({foreign_log,node}), gen_server:stop(Foreign),
            receive {live_source_lost,Token} -> ok after 5000 -> error(source_loss_not_delivered) end,
            ?assertEqual({error,unavailable},quod_physics:body_state(Pid,Expected,{4,2},1000))
        after sys:remove(Runtime,Seen) end,
        {ok,Replacement} = quod_foreign_log:start_link(
            #{cache_dir => filename:join(maps:get(directory,F),"foreign")}),
        try
            {Pid,World} = installed_structure(Ns,2),
            #{World := #{spec := Spec}} = worlds(Ns),
            ?assertMatch({4,2,fixed,_,{solid,{box,0.25,1.0,0.25}},_},
                         lists:keyfind(4,1,maps:get(bodies,Spec))),
            ?assertEqual(maps:get(incarnation,Before),maps:get(incarnation,gen_server:call(Pid,status)))
        after gen_server:stop(Replacement) end
    end) end}.

assert_no_live_geometry_work(Fun) ->
    ?assertEqual([],maps:get(calls,observe_live_geometry_work(Fun))).
observe_live_geometry_work(Fun) ->
    Collector = spawn_link(fun() -> trace_calls([]) end),
    Trace = trace:session_create(live_geometry_unchanged,Collector,[]),
    Watched = [{quod_foreign_projection,start_monitor,4},{quod_committed_projection,apply_entry,3},
               {quod_physics_native,install,3},{quod_physics_native,install_hinges,2},
               {quod_physics_native,new_world,3},{quod_ledger_store,fold,5},
               {quod_ledger_store,open,3},{file,write,2},{file,pwrite,3},
               {file,sync,1},{file,datasync,1}],
    [trace:function(Trace,MFA,[{'_',[],[{message,{caller}}]}],[local]) || MFA <- Watched],
    trace:process(Trace,all,true,[call]),
    try
        Fun(), Delivered = trace:delivered(Trace,all),
        receive {trace_delivered,all,Delivered} -> ok after 5000 -> error(trace_timeout) end,
        Ref = make_ref(), Collector ! {finish,self(),Ref},
        Calls = receive {trace_calls,Ref,Rows} -> Rows after 5000 -> error(trace_timeout) end,
        #{watched => Watched,calls => Calls}
    after trace:session_destroy(Trace),unlink(Collector),exit(Collector,kill) end.

await_live_receipt({ok,#{operation_ref := Op = {operation,Ns,_,_,_}},_}) ->
    #{operation_state := terminal} = quod_ct:await_operation_complete(Ns,Op,5000),
    ok.

live_source_atomic_conflicts_test_() ->
    {timeout,90,fun() -> with_live_source(<<"live-conflicts">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination,subject := Subject}) ->
        {Pid,World} = enable(F),
        true = quod_reg:reg({host_test,local_proof}),
        try
            %% Two complete candidate admissions cannot consume the same slot/ID.
            Results = live_compete(Source,[{space_place,obstacle,0,Destination},
                                           {space_place,obstacle,0,Destination}]),
            assert_live_conflict(Results), {Pid,World} = installed_structure(Ns,2),
            ?assertMatch({ok,[#{'Ids' := [4]}],_},quod_prolog:prove_ro(Ns,
                {findall,{'B'},{physics_body_definition,room,{'B'},{'_'},{'_'},{'_'},
                                       {live,Subject,1,1,{'_'}}},{'Ids'}})),
            %% Either edit or withdrawal may win. Their receiver changes stay
            %% atomic; the losing prepared proof cannot restore a retired body.
            Mixed = live_compete(Source,[{physics_edit_definition,obstacle,1,{geometry,{ball,600},1}},
                                        {space_withdraw,obstacle,1,Destination}]),
            assert_live_conflict(Mixed), {Pid,World} = installed_structure(Ns,3),
            #{World := #{spec := Spec}} = worlds(Ns),
            case lists:keyfind(edit,1,[{case N of 1 -> edit; 2 -> withdraw end,R} || {N,R} <- Mixed]) of
                {edit,{ok,_,{normalized,{committed,_,_}}}} ->
                    ?assertMatch({4,3,fixed,_,{solid,{ball,0.6}},_},lists:keyfind(4,1,maps:get(bodies,Spec))),
                    ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,{space_assignment_state,obstacle,1,Destination}));
                _ ->
                    ?assertEqual(false,lists:keyfind(4,1,maps:get(bodies,Spec))),
                    ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,{space_assignment_state,obstacle,2,none})),
                    ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,
                        {physics_definition,obstacle,1,{geometry,{box,250,1000,250},1}}))
            end
        after gproc:unreg(quod_reg:name({host_test,local_proof})) end
    end) end}.

live_compete(Source,Goals) ->
    Parent = self(), Token = make_ref(),
    Jobs = [begin
        {Pid,Monitor} = spawn_monitor(fun() -> Parent ! {live_race,Token,N,
            door_action(Source,{',',Goal,test_local_wait})} end),
        Proof = receive {local_proof_waiting,P} -> P after 5000 -> error(race_proof_missing) end,
        {Pid,Monitor,Proof}
    end || {N,Goal} <- lists:zip(lists:seq(1,length(Goals)),Goals)],
    try
        [{_,_,First},{_,_,Second}] = Jobs,
        try
            First ! release,
            One = receive {live_race,Token,N1,R1} -> {N1,R1} after 10000 -> error(first_race_timeout) end,
            Second ! release,
            Two = receive {live_race,Token,N2,R2} -> {N2,R2} after 10000 -> error(second_race_timeout) end,
            [One,Two]
        after First ! release, Second ! release end
    after
        [begin exit(P,kill), receive {'DOWN',M,process,P,_} -> ok after 1000 -> error(race_caller_alive) end end
         || {P,M,_} <- Jobs]
    end.

assert_live_conflict(Results) ->
    ?assertEqual(1,length([R || {_,{ok,_,{normalized,{committed,_,_}}} = R} <- Results])),
    [Failure] = [R || {_,R} <- Results, case R of
        {ok,_,{normalized,{committed,_,_}}} -> false; _ -> true end],
    case Failure of
        {ok,_,{normalized,{error,conflict_retry}}} -> ok;
        _ -> assert_reason(conflict_retry,Failure)
    end.

live_source_missing_space_admission_test_() ->
    {timeout,60,fun() -> with_live_source(<<"live-catalogue">>,fun(
            #{namespace := Ns,source := Source,destination := Destination}) ->
        commit(Ns,{retract,{instance_of,physical_space,room}}),
        Height = quod_prolog:applied(Source),
        assert_reason({not_space,room},door_action(Source,{space_place,obstacle,0,Destination})),
        ?assertEqual(Height,quod_prolog:applied(Source)),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,{space_assignment,obstacle,0,none})),
        ?assertMatch({fail,_},quod_prolog:prove_ro(Source,{physics_definition_delegate,obstacle,{'_'},{'_'},{'_'}})),
        ?assertEqual(#{},worlds(Ns))
    end) end}.

live_source_withdrawal_after_reclassification_test_() ->
    [{atom_to_list(Class), {timeout,90,fun() ->
        with_live_source(atom_to_binary(Class),fun(F = #{namespace := Ns,source := Source,
                subject := Subject,destination := Destination}) ->
            {Pid,World} = enable(F),
            Admission = door_action(Source,{space_place,obstacle,0,Destination}),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},Admission),
            await_live_receipt(Admission), {Pid,World} = installed_structure(Ns,2),
            Replacement = case Class of
                space -> [quod_ct:source_assertion({instance_of,space,room})];
                untyped -> []
            end,
            commit(Ns,list_conjunction([{retract,{instance_of,physical_space,room}} | Replacement])),
            Hook = {':-',{space_physical_change,{'W'},{'S'},{'Change'}},
                         {physics_space_change,{'W'},{'S'},{'Change'}}},
            commit(Ns,{'$quod_retract_exact',Hook}),
            %% Existing live obligations remain mandatory after a class edit.
            Withdraw = {space_withdraw,obstacle,1,Destination},
            assert_reason({space_physical_change_refused,room,withdrawn},door_action(Source,Withdraw)),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,
                {space_assignment,obstacle,1,Destination})),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
                {physics_body_definition,room,{'_'},{'_'},{'_'},{'_'},{live,Subject,1,{'_'},{'_'}}})),
            commit(Ns,{assertz,Hook}),
            Released = door_action(Source,Withdraw),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},Released), await_live_receipt(Released),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,{space_assignment,obstacle,2,none})),
            ?assertMatch({fail,_},quod_prolog:prove_ro(Source,
                {physics_definition_delegate,obstacle,{'_'},{'_'},{'_'}})),
            ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{space_placement,room,Subject,{'_'}})),
            ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,
                {physics_body_definition,room,{'_'},{'_'},{'_'},{'_'},{live,Subject,{'_'},{'_'},{'_'}}})),
            Restore = case Class of space -> [{retract,{instance_of,space,room}}]; untyped -> [] end,
            commit(Ns,list_conjunction(Restore ++
                [quod_ct:source_assertion({instance_of,physical_space,room})])),
            Replaced = door_action(Source,{space_place,obstacle,2,Destination}),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},Replaced), await_live_receipt(Replaced),
            {_,World} = installed_structure(Ns,4),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{space_placement,room,Subject,3}))
        end)
    end}} || Class <- [space,untyped]].

with_live_source(Ns,Fun) ->
    with_world(Ns,fun(F = #{directory := Dir,identity := Identity,node := Principal}) ->
        Source = <<Ns/binary,"-objects">>,
        Anchor = quod_simplex:genesis_hash(Ns), Destination = {entity_ref,Ns,Anchor,room},
        World = {world_ref,Ns,Anchor,room}, Authority = {agent_instance_ref,Ns,Anchor,actor},
        Terms = quod_prolog:read_terms("priv/ontologies/quod_physics.pl") ++
                (quod_prolog:read_terms("priv/ontologies/quod_space.pl") ++
                 quod_prolog:read_terms("test/fixtures/space-permissions.pl")) ++
            [{can_invoke,{'_'},Principal,{'_'},Source}, {isa,artifact,thing}, {instance_of,artifact,obstacle},
             {physics_definition,obstacle,1,{geometry,{box,250,1000,250},1}},
             {physics_definition_allowance,obstacle,1000000},
             {can_edit_physics_definition,obstacle,Principal},
             {can_delegate_physics_definition,obstacle,Principal,World,Authority},
             {space_test_grant,{instance,obstacle},Principal,space_enter,Destination,placement},
             {space_test_grant,{instance,obstacle},Principal,space_leave,Destination,placement}],
        SourceSup = quod_agent_hosting_tests:start_ontology(Source,Dir,Identity,[],Terms),
        {ok,Foreign} = quod_foreign_log:start_link(#{cache_dir => filename:join(Dir,"foreign")}),
        Subject = {entity_ref,Source,quod_simplex:genesis_hash(Source),obstacle},
        try
            Rules = [{subscribes,Source,quod_simplex:genesis_hash(Source)},
                     {space_test_grant,{instance,room},Principal,space_admit,Subject,placement},
                     {space_test_grant,{instance,room},Principal,space_remove,Subject,placement},
                     {can_edit_physics,room,Principal},
                     {can_refresh_physics_definition,room,Principal,Subject},
                     {physics_admission,room,Subject,fixed,{vector,4000,1000,0}},
                     {':-',{space_physical_change,{'W'},{'S'},{'Change'}},
                           {physics_space_change,{'W'},{'S'},{'Change'}}}],
            commit(Ns,list_conjunction([{assertz,R} || R <- Rules])),
            Fun(F#{source => Source,subject => Subject,destination => Destination})
        after
            catch gen_server:stop(Foreign), quod_agent_hosting_tests:stop_ontology(SourceSup)
        end
    end,fun(Rules) -> [case R of
        {physics_allowances,W,Limits,Step,_,Budget} -> {physics_allowances,W,Limits,Step,0,Budget};
        {physics_body_definition,W,2,Rev,_,Pose,Definition} ->
            {physics_body_definition,W,2,Rev,controlled,Pose,Definition};
        _ -> R end || R <- Rules] end).

installed_structure(Ns,Structure) ->
    {Pid,World} = installed(Ns),
    case worlds(Ns) of
        #{World := #{spec := #{structure := Structure}}} -> {Pid,World};
        _ -> installed_structure(Ns,Structure)
    end.

list_conjunction([]) -> true;
list_conjunction([Goal|Rest]) -> {',',Goal,list_conjunction(Rest)}.

supported_geometry_signed_edit_test_() ->
    Tetrahedron = [{vector,0,0,0},{vector,500,0,0},{vector,0,500,0},{vector,0,0,500}],
    Shapes = [{box,fixed,{box,500,500,500}}, {ball,fixed,{ball,500}}, {capsule,fixed,{capsule,500,250}},
        {convex,fixed,{convex,Tetrahedron}},
        {dynamic_ball,dynamic,{ball,500}}, {controlled_capsule,controlled,{capsule,500,250}},
        {dynamic_convex,dynamic,{convex,Tetrahedron}},
        {parts,fixed,{parts,[{part,{pose,{vector,-750,0,0},{rotation,0,100,0}},{box,250,500,250}},
                       {part,{vector,750,0,0},{ball,250}}]}},
        {surface,fixed,{surface,[{vector,-500,0,-500},{vector,500,0,-500},{vector,0,0,500}],
                           [{triangle,0,2,1}]}}],
    [{atom_to_list(Name),{timeout,60,fun() ->
        with_world(fun(F = #{namespace := Ns,node := Principal}) ->
            {Pid,World} = enable(F),
            #{World := #{spec := Spec}} = worlds(Ns), Fence = quod_physics:fence(Spec),
            Expected = #{fence => Fence,structure => 1,tick => -1},
            {ok,Before,_} = quod_physics:snapshot(Pid,Expected),
            {2,1,world,_,Rotation,_} = lists:keyfind(2,1,maps:get(poses,Before)),
            Move = {physics_move_body,room,2,1,1,{vector,4000,3000,0}},
            ?assertMatch({ok,_,{normalized,{failed,_}}},door_action(Ns,Move)),
            commit(Ns,{assertz,{can_edit_physics,room,Principal}}),
            MoveResult = door_action(Ns,Move),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},MoveResult),
            {Pid,World} = installed(Ns),
            {ok,After,#{installs := Installs}} = quod_physics:snapshot(Pid,Expected#{structure => 2}),
            {2,2,world,Position,Rotation,_} = lists:keyfind(2,1,maps:get(poses,After)),
            ?assertEqual({4.0,3.0,0.0},Position),
            ?assertEqual({error,unavailable},quod_physics:snapshot(Pid,Expected)),
            ?assertMatch({ok,_,{normalized,{failed,_}}},door_action(Ns,Move)),
            await_source_receipt(MoveResult),
            assert_no_physics_io(fun() ->
                reconcile(Ns), reconcile(Ns),
                ?assertMatch(#{installs := Installs},gen_server:call(Pid,status))
            end)
        end,fun(Rules) -> [case Rule of
            {physics_body_definition, room, 2, 1, _, _, {owned, _, _}} ->
                {physics_body_definition, room, 2, 1, Kind, {pose,{vector,0,3000,0},{rotation,0,250,0}}, {owned, Shape, 1}};
            {physics_allowances,W,Limits,Step,_,Budget} ->
                {physics_allowances,W,Limits,Step,0,Budget};
            _ -> Rule
        end || Rule <- Rules] end)
    end}} || {Name,Kind,Shape} <- Shapes].

invalid_geometry_signed_edit_leaves_state_unchanged_test_() ->
    Surface = {surface,[{vector,0,0,0},{vector,500,0,0},{vector,0,0,500}],[{triangle,0,1,2}]},
    Invalid = [{dynamic,Surface}, {controlled,Surface}, {fixed,{box,0,500,500}},
        {fixed,{ball,1000001}}, {fixed,{capsule,0,100}}, {fixed,{parts,[]}},
        {fixed,{parts,[{part,{vector,0,0,0},Surface}]}},
        {fixed,{parts,[{part,{pose,{vector,0,0,0},{rotation,bad,0,0}},{ball,100}}]}},
        {fixed,{convex,[{vector,0,0,0},{vector,500,0,0},{vector,0,0,500}]}},
        {fixed,setelement(3,Surface,[{triangle,0,1,3}])},
        {fixed,setelement(3,Surface,[{triangle,0,1,1}])}],
    {timeout,60,fun() -> with_world(fun(#{namespace := Ns,node := Principal}) ->
        commit(Ns,{assertz,{can_edit_physics,room,Principal}}),
        lists:foreach(fun({Kind,Shape}) ->
            Body = {physics_body_definition, room, 2, 1, Kind, {vector,0,3000,0}, {owned, Shape, 1}},
            commit(Ns,{',',{retract,{physics_body_definition, room, 2, {'_'}, {'_'}, {'_'}, {owned, {'_'}, {'_'}}}},
                          {assertz,Body}}),
            Height = quod_prolog:applied(Ns),
            assert_reason({invalid_physics_body,2},door_action(Ns,
                {physics_move_body,room,2,1,1,{vector,4000,3000,0}})),
            ?assertEqual(Height,quod_prolog:applied(Ns)),
            ?assertMatch({ok,[_],Height},quod_prolog:prove_ro(Ns,{',',Body,{physics_structure,room,1}})),
            ?assertEqual(#{},worlds(Ns))
        end,Invalid)
    end) end}.

numeric_geometry_and_hinge_refusals_test_() ->
    {timeout,60,fun() -> with_door(fun(#{namespace := Ns}) ->
        %% The envelope protects the existing integer-to-double conversion before
        %% unit division. Policy range failures below remain a separate refusal.
        {ok,[#{'NativeMax' := Max}],_} = quod_prolog:prove_ro(Ns,
            {physics_native_scalar_limit,{'NativeMax'}}),
        ?assertEqual(((1 bsl 53)-1) bsl 971,Max),
        [?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_milli_integer,X}))
            || X <- [-Max,0,Max]],
        [?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_milli_integer,X}))
            || X <- [-Max-1,Max+1]],
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_positive_scalar,Max})),
        ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_positive_scalar,Max+1})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
            {physics_motion_capabilities,[{jump,Max}],[]})),
        [?assertMatch({fail,_},quod_prolog:prove_ro(Ns,
            {physics_motion_capabilities,[{jump,X}],[]})) || X <- [0,Max+1]],
        ?assertEqual(1.7976931348623157e308,float(Max)),
        ?assert(is_float(Max/1000)), ?assert(is_float(-Max/1000000)),
        %% Max+1 still rounds to Max; test actual conversion overflow separately.
        ?assertError(badarith,(Max+(1 bsl 971))/1000),
        Huge = 1 bsl 2048,
        Position = {vector,0,3000,0}, Shape = {box,500,500,500},
        Bodies = [{physics_body_definition, room, 2, 1, fixed, Position, {owned, Shape, Huge}},
            {physics_body_definition, room, 2, 1, fixed, {pose,Position,{rotation,0,Huge,0}}, {owned, Shape, 1}},
            {physics_body_definition, room, 2, 1, fixed, Position, {owned, {parts,[{part,{vector,1000001,0,0},{ball,100}}]}, 1}},
            {physics_body_definition, room, 18446744073709551616, 1, fixed, Position, {owned, Shape, 1}}],
        lists:foreach(fun(Body) ->
            commit(Ns,{assertz,Body}), Height = quod_prolog:applied(Ns), Id = element(3,Body),
            assert_reason({invalid_physics_body,Id},door_action(Ns,
                {physics_move_body,room,Id,1,2,{vector,4000,3000,0}})),
            ?assertEqual(Height,quod_prolog:applied(Ns)), commit(Ns,{retract,Body})
        end,Bodies),
        Body = {physics_body_definition, room, 2, 1, fixed, Position, {owned, Shape, 1}}, commit(Ns,{assertz,Body}),
        BeforeRange = quod_prolog:applied(Ns),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
            {physics_checked_body,2,fixed,{vector,Huge,3000,0},Shape,1,1000000})),
        assert_reason({invalid_physics_body,2},door_action(Ns,
            {physics_move_body,room,2,1,2,{vector,1.5,3000,0}})),
        ?assertEqual(BeforeRange,quod_prolog:applied(Ns)), commit(Ns,{retract,Body}),
        lists:foreach(fun({Name,Recipe,Reason}) ->
            commit(Ns,{assertz,{physics_hinged_class,Name,1,Recipe}}),
            Height = quod_prolog:applied(Ns),
            assert_reason(Reason,door_action(Ns,
                {physics_add_hinged,room,12,13,{local,Name,1},Position,2})),
            ?assertEqual(Height,quod_prolog:applied(Ns)),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_next_body,room,12}))
        end,[{zero_axis,setelement(5,hinged_recipe(),{vector,0,0,0}),invalid_hinge_definition},
             {wide_arc,setelement(7,hinged_recipe(),{limits,-2500,2500}),invalid_hinge_definition},
             {outside_target,setelement(9,hinged_recipe(),hinged_command(2000)),invalid_hinge_command}]),
        commit(Ns,{assertz,{physics_hinged_class,non_box,1,setelement(3,hinged_recipe(),{ball,500})}}),
        Pose = {pose,Position,{rotation,0,250,0}},
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
            {physics_add_hinged,room,12,13,{local,non_box,1},Pose,2})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
            {physics_body_definition,room,12,3,dynamic,Pose,{owned,{ball,500},1}})),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
            {physics_move_hinged,room,10,0,3,Pose})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
            {physics_body_definition,room,10,4,dynamic,Pose,{owned,{box,1000,1000,100},1}})),
        ?assertEqual(#{},worlds(Ns))
    end,false) end}.

native_hinge_revision_and_restore_validation_test() ->
    Frame = {1,1,fixed,{{5.0,0.0,0.0},{0.0,0.25,0.0}},{solid,{box,0.05,1.0,0.05}},1.0},
    Moving = {2,3,dynamic,{{5.0,0.0,0.0},{0.0,0.25,0.0}},{solid,{ball,0.5}},1.0},
    Hinge = {{2,3},7,{1,1},{0.0,1.0,0.0},{{0.0,1.0,0.0},{-1.0,0.0,0.0}},{-1.5,1.5},1.5},
    lists:foreach(fun({Definition,Restore,Reason}) ->
        {ok,R} = quod_physics_native:new_world({2,2,4,100.0,2,0,0},1/60,0.0),
        try
            ?assertEqual({ok,2},quod_physics_native:install(R,{0,0,0},[Frame,Moving])),
            ?assertEqual({error,Reason},quod_physics_native:install_hinges(R,[{Definition,Restore}])),
            ?assertEqual({error,retired},quod_physics_native:sample(R))
        after quod_physics_native:retire(R) end
    end,[{setelement(3,Hinge,{1,2}),1.5,invalid_hinge},
         {setelement(4,Hinge,{0.0,0.0,0.0}),1.5,invalid_hinge},
         {Hinge,2.0,invalid_hinge},
         {setelement(5,Hinge,{{100.0,0.0,0.0},{-10.0,0.0,0.0}}),0.0,coordinate_allowance}]),
    {ok,Valid} = quod_physics_native:new_world({2,2,4,100.0,2,0,0},1/60,0.0),
    try
        {ok,2} = quod_physics_native:install(Valid,{0,0,0},[Frame,Moving]),
        ?assertEqual({ok,1},quod_physics_native:install_hinges(Valid,[{Hinge,1.5}])),
        ?assertEqual({ok,[{2,1500,false}]},quod_physics_native:hinge_samples(Valid)),
        ?assertEqual({error,stale_revision},quod_physics_native:control_hinge(Valid,2,6,hold)),
        ?assertEqual({error,retired},quod_physics_native:sample(Valid))
    after quod_physics_native:retire(Valid) end.

optional_retained_world_test_() ->
    {timeout, 90, fun() ->
        with_world(fun(#{namespace := Ns, node := Node, key := Key}) ->
            true = quod_reg:subscribe({physics, Ns}),
            try
                commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
                reconcile(Ns),
                ?assertEqual(#{}, worlds(Ns)),
                ?assertMatch({_, []}, quod_agent_hosting_tests:domain_agents(Ns)),
                commit(Ns, {',', {retract, {physics_space, room, disabled, actor}},
                                  {assertz, {physics_space, room, enabled, actor}}}),
                {Pid, World} = installed(Ns),
                #{World := #{spec := Spec}} = worlds(Ns),
                Fence = quod_physics:fence(Spec),
                {ok, Frame, Counters} = quod_physics:snapshot(Pid, #{fence => Fence, structure => 1, tick => -1}),
                ?assertEqual(2, length(maps:get(poses, Frame))),
                ?assertEqual(1, maps:get(installs, Counters)),
                reconcile(Ns),
                #{World := #{pid := Pid}} = worlds(Ns),
                #{installs := 1} = gen_server:call(Pid, status),
                commit(Ns, {',', {retract, {physics_body_definition, room, 2, 1, dynamic, {vector,0,3000,0}, {owned, {box,500,500,500}, 1}}},
                  {',', {assertz, {physics_body_definition, room, 2, 2, dynamic, {vector,0,5000,0}, {owned, {box,500,500,500}, 1}}},
                    {',', {retract, {physics_structure, room, 1}},
                          {assertz, {physics_structure, room, 2}}}}}),
                {Pid, World} = installed(Ns),
                {ok, #{structure := 2}, #{installs := 2}} = quod_physics:snapshot(Pid, #{fence => Fence, structure => 2, tick => -1}),
                ?assertEqual({error, unavailable}, quod_physics:snapshot(Pid, Frame)),
                Monitor = monitor(process, Pid),
                commit(Ns, {',', {retract, {physics_space, room, enabled, actor}},
                                  {assertz, {physics_space, room, disabled, actor}}}),
                receive {'DOWN', Monitor, process, Pid, _} -> ok
                after 10000 -> error(world_not_retired) end,
                reconcile(Ns),
                ?assertEqual(#{}, worlds(Ns))
            after quod_reg:unsubscribe({physics, Ns}) end
        end)
    end}.

system_physics_world_policy_test_() ->
    [{binary_to_list(Ns), {timeout, 60, fun() ->
        with_world(Ns, fun(F = #{node := Principal}) ->
            {ok, [#{'Manifest' := Manifest}], _} = quod_prolog:prove_ro(
                Ns, {external_predicate_modules, {'Manifest'}}),
            ?assertNot(lists:keymember(quod_physics_predicates, 1, Manifest)),
            ?assertEqual(#{}, worlds(Ns)),
            {Pid, World} = enable(F),
            ?assertEqual({world_ref, Ns, quod_simplex:genesis_hash(Ns), room}, World),
            #{World := #{spec := #{gravity := InstalledGravity}}} = worlds(Ns),
            ?assertEqual(Gravity / 1000, InstalledGravity),
            Goal = {physics_body_state, room, 1, {0}},
            ?assertMatch({ok, _, {normalized,{read,_,{failed, _}}}}, body_read(Ns, Goal)),
            case Permission of
                allowed ->
                    commit(Ns, {assertz, {can_read_physics_body, room, Principal, 1}}),
                    ?assertMatch({ok, _, {normalized,{read,_,{answers, _, [_]}}}}, body_read(Ns, Goal));
                denied ->
                    commit(Ns, {assertz, {can_read_physics_body, another_space, Principal, 1}}),
                    ?assertMatch({ok, _, {normalized,{read,_,{failed, _}}}}, body_read(Ns, Goal))
            end,
            %% A real instance-property edit reaches the retained resource selector.
            %% Gravity requires a replacement run; the world identity stays fixed.
            Monitor = monitor(process, Pid),
            commit(Ns, {',', {retract, {attribute, room, gravity, Gravity}},
                             {assertz, {attribute, room, gravity, 0}}}),
            receive {'DOWN', Monitor, process, Pid, _} -> ok
            after 10000 -> error(gravity_change_did_not_retire_run) end,
            {Replacement, World} = installed(Ns),
            ?assertNotEqual(Pid, Replacement),
            #{World := #{spec := #{gravity := 0.0}}} = worlds(Ns),
            ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(
                Ns, {external_predicate_modules, Manifest}))
        end, fun(Rules) ->
            [case Rule of
                 {physics_allowances, room, Limits, Step, _, Budget} ->
                     {':-', {physics_allowances, {'W'}, Limits, Step, {'G'}, Budget},
                            {attribute, {'W'}, gravity, {'G'}}};
                 _ -> Rule
             end || Rule <- Rules] ++ [{attribute, room, gravity, Gravity}]
        end)
    end}} || {Ns, Gravity, Permission} <-
        [{<<"physics-policy-earth">>, -9800, allowed},
         {<<"physics-policy-moon">>, -1620, denied}]].

signed_live_body_predicate_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Human}) ->
        {Pid,World} = enable(F),
        Goal = {physics_body_state,room,1,{0}},
        commit(Ns,{assertz,{can_invoke,{physics_body_state,{'_'},{'_'},{'_'}},Human,{'_'},Ns}}),
        ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},body_read(Ns,Goal)),
        commit(Ns,{assertz,{can_read_physics_body,room,Human,1}}),
        #{World := #{spec := Spec}} = worlds(Ns),
        Expected = #{fence => quod_physics:fence(Spec),structure => 1,
                     incarnation => maps:get(run_token,Spec)},
        ?assertMatch({ok,_,{0,0,0},{1,1,world,_,_,_}},quod_physics:body_state(Pid,Expected,{1,1},1000)),
        ?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_]}}}},body_read(Ns,Goal)),
        #{installs := Installs,queries := Queries} = gen_server:call(Pid,status),
        assert_no_physics_io(fun() ->
            [?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_]}}}},body_read(Ns,Goal))
             || _ <- lists:seq(1,3)]
        end),
        ?assertMatch(#{installs := Installs,queries := Q} when Q =:= Queries+3,
                     gen_server:call(Pid,status)),
        ?assertEqual({error,unavailable},quod_physics:body_state(Pid,Expected#{structure => 0},{1,1},1000)),
        ?assertEqual({error,unavailable},quod_physics:body_state(Pid,Expected,{1,0},1000)),
        ?assertEqual({error,unavailable},quod_physics:body_state(Pid,Expected#{incarnation => <<0:256>>},{1,1},1000)),
        %% Even a world invocation grant cannot manufacture the private handle.
        commit(Ns,{assertz,{can_invoke,{'$quod_sample_physics',{'_'},{'_'},{'_'},{'_'},{'_'},{'_'}},Human,{'_'},Ns}}),
        Frame = {physics_frame,World,maps:get(authority,Spec),maps:get(epoch,Spec),
                 maps:get(generation,Spec),maps:get(run_token,Spec),1},
        ?assertMatch({ok,_,{normalized,{read,_,{error,_}}}},
                     body_read(Ns,{'$quod_sample_physics',forged,{physics_body_state,room,1},Frame,1,none,{0}})),
        commit(Ns,{retract,{can_read_physics_body,room,Human,1}}),
        ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},body_read(Ns,Goal))
    end) end}.

body_read(Ns,Goal) ->
    {ok,Bytes,Signature} = quod_node_actor:signed_goal(read,{'::',Ns,Goal},
        crypto:strong_rand_bytes(32),quod_time:now_ms()+10000),
    quod_client_goal_ingress:submit(Bytes,Signature).

assert_reason(Reason,{ok,E,{normalized,{read,_,Outcome}}}) ->
    assert_reason(Reason,{ok,E,{normalized,Outcome}});
assert_reason(Reason,{ok,_,{normalized,{failed,Blob}}}) ->
    {ok,Reasons} = quod_wire_term:decode_failure_reasons(Blob),
    case lists:member(Reason,Reasons) of
        true -> ok;
        false -> error({missing_failure_reason,Reason,redact(Reasons)})
    end.

assert_reason_count(Reason, Count, {ok,E,{normalized,{read,_,Outcome}}}) ->
    assert_reason_count(Reason,Count,{ok,E,{normalized,Outcome}});
assert_reason_count(Reason, Count, {ok,_,{normalized,{failed,Blob}}}) ->
    {ok,Reasons} = quod_wire_term:decode_failure_reasons(Blob),
    ?assertEqual(Count,length([R || R <- Reasons,R =:= Reason])).

input_admission_reasons_test_() ->
    {timeout,60,fun() -> with_chair(fun(F = #{namespace := Ns}) ->
        {Pid,World} = enable(F), Limits = {query_limits,2,0,8,128},
        {_,Expected,Frame,_,_} = install_test_control(F,Pid,World,
            {motion,free,2000,1600,1000,Limits,[]}),
        {control_frame,_,Registration} = Frame,
        Installed = Expected#{registration => Registration}, Control = maps:get(control,Expected),
        Input = {{push,{body,3,1},{vector,1000,0,0}},{push_limits,3,1,5000,5000}},
        Request = fun(E,C,S,I,X,D) -> {physics_input,E,C,S,I,X,D} end,
        Expiry = quod_time:now_ms()+5000, Deadline = quod_time:mono_ms()+5000,
        Call = fun(E,C,S,I,X,D) -> gen_server:call(Pid,Request(E,C,S,I,X,D)) end,
        [?assertEqual({error,{stale_projection,1}},Call(E,Control,1,Input,Expiry,Deadline)) || E <-
            [Installed#{fence => stale},Installed#{structure => 0},Installed#{incarnation => <<0:256>>}]],
        ?assertEqual({error,control_not_installed},Call(Installed,setelement(3,Control,2),1,Input,Expiry,Deadline)),
        ?assertEqual({error,control_not_installed},Call(Installed,Control,1,
            {element(1,Input),{push_limits,3,1,6000,5000}},Expiry,Deadline)),
        ?assertEqual({error,stale_registration},Call(Installed#{registration => <<0:256>>},Control,1,Input,Expiry,Deadline)),
        ?assertEqual({error,expired},Call(Installed,Control,1,Input,quod_time:now_ms()-1,Deadline)),
        ?assertEqual({error,expired},Call(Installed,Control,1,Input,Expiry,quod_time:mono_ms()-1)),
        %% Both calls precede the owner's self-scheduled step. Response delivery
        %% proves processing; no sleep, polling or send trace selects this race.
        ok = sys:suspend(Pid),
        A = gen_server:send_request(Pid,Request(Installed,Control,1,Input,Expiry,Deadline)),
        B = gen_server:send_request(Pid,Request(Installed,Control,2,Input,Expiry,Deadline)),
        ok = sys:resume(Pid),
        ?assertEqual({reply,ok},gen_server:receive_response(A,5000)),
        ?assertEqual({reply,{error,discrete_pending}},gen_server:receive_response(B,5000)),
        ?assertEqual({error,{stale_sequence,1}},Call(Installed,Control,1,Input,Expiry,Deadline)),
        #{World := #{spec := #{navigation_guard := {Guard,G}}}} = worlds(Ns),
        atomics:put(Guard,1,G+1),
        try ?assertEqual({error,reinstalling},Call(Installed,Control,2,Input,Expiry,Deadline))
        after atomics:put(Guard,1,G) end
    end) end}.

hot_control_policy_reasons_test_() ->
    {timeout,90,fun() -> with_chair(fun(F = #{namespace := Ns,node := Human}) ->
        {Pid,World} = enable(F),
        {Definition,_,Frame,_,_} = install_test_control(F,Pid,World,
            {motion,free,2000,1600,1000,{query_limits,2,0,8,128},[]}),
        Runtime = quod_reg:where({quod_runtime,Ns}), ok = sys:suspend(Runtime),
        try
        assert_reason_count({ambiguous_control,room},0,body_read(Ns,
            {physics_control_state,room,Human,99,{0}})),
        assert_reason_count({ambiguous_agent,pilot},0,body_read(Ns,
            {physics_agent_configuration,room,Human,pilot,eye,setelement(3,Definition,99)})),
        Go = {physics_control_input,room,Frame,1,1,{drive,{vector,0,0,0},{angular,0,0,0}},{0}},
        [begin
            {ok,_,{normalized,{failed,Reasons}}} = control_goal({'::',Ns,setelement(6,Go,Input)}),
            {ok,Decoded} = quod_wire_term:decode_failure_reasons(Reasons),
            ?assertEqual([],[R || R = {coordinate_allowance,_} <- Decoded])
        end || Input <- [{drive,{vector,2001,0,0},{angular,0,0,0}},
                         {drive,{vector,0,0,0},{angular,0,1601,0}},
                         {push,{body,3,1},{vector,5001,0,0}}, {jump,4000}]],
        Checkpoint = {physics_checkpoint_body,room,3,1,0,<<209:256>>},
        assert_reason({control_conflict,1},door_action(Ns,{physics_control_agent,room,0,none,none})),
        Other = {agent_instance_ref,<<"other">>,<<99:256>>,someone},
        commit(Ns,{assertz,{physics_control,room,Other,1,{controlled,pilot,eye}}}),
        assert_reason({agent_controlled,pilot},door_action(Ns,
            {physics_control_agent,room,1,{controlled,pilot,eye},{controlled,pilot,eye}})),
        commit(Ns,{retract,{physics_control,room,Other,1,{controlled,pilot,eye}}}),
        Agent = {physics_agent,room,pilot,1,2,element(6,Definition)},
        Mount = {physics_viewpoint,room,pilot,eye,2,element(3,element(7,Definition)),element(4,element(7,Definition))},
        Body = {physics_body_definition, room, 2, 1, controlled, {vector,-3000,1000,0}, {owned, {box,500,1000,500}, 1}},
        [?assertEqual(ok,begin
            commit(Ns,{'$quod_retract_exact',Fact}),
            ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,Fact)),
            Result = control_goal({'::',Ns,Go}),
            case Result of
                {ok,_,{normalized,{failed,_}}} -> assert_reason({ambiguous_agent,pilot},Result);
                _ -> error({missing_configuration_accepted,Fact,redact(brief(Result))})
            end,
            commit(Ns,{assertz,Fact}),ok end) || Fact <- [Agent,Mount,Body]],
        Ambiguous = setelement(4,Agent,2),
        commit(Ns,{assertz,Ambiguous}),
        assert_reason({ambiguous_agent,pilot},control_goal({'::',Ns,Go})),
        commit(Ns,{'$quod_retract_exact',Ambiguous}),
        commit(Ns,{retract,{physics_control,room,Human,1,{controlled,pilot,eye}}}),
        assert_reason({no_control,room},control_goal({'::',Ns,Go})),
        assert_reason_count({no_control,room},1,control_goal({'::',Ns,
            setelement(6,Go,{push,{body,3,1},{vector,1000,0,0}})})),
        commit(Ns,{assertz,{physics_control,room,Human,1,{controlled,pilot,eye}}}),
        DuplicateControl = {physics_control,room,Human,2,none},
        commit(Ns,{assertz,DuplicateControl}),
        assert_reason({ambiguous_control,room},control_goal({'::',Ns,Go})),
        commit(Ns,{retract,DuplicateControl}),
        assert_reason({body_not_free,3},door_action(Ns,setelement(4,Checkpoint,0))),
        RestPolicy = {physics_rest_policy,room,3,{recovery,5,128}},
        commit(Ns,{retract,RestPolicy}),
        assert_reason({rest_policy_missing,3},door_action(Ns,Checkpoint)),
        commit(Ns,{assertz,RestPolicy}),
        Waiting = {physics_rest,room,3,1,{waiting,{rest,1,<<210:256>>}}},
        commit(Ns,{assertz,Waiting}),
        assert_reason_count({ambiguous_checkpoint,3},0,body_read(Ns,
            {physics_rest_state,room,3,99,{0}})),
        assert_reason({checkpoint_pending,3},door_action(Ns,setelement(5,Checkpoint,1))),
        assert_reason({checkpoint_conflict,3},door_action(Ns,Checkpoint)),
        OtherWaiting = setelement(5,Waiting,idle),
        commit(Ns,{assertz,OtherWaiting}),
        assert_reason({ambiguous_checkpoint,3},door_action(Ns,Checkpoint)),
        commit(Ns,{retract,OtherWaiting}), commit(Ns,{retract,Waiting}),
        {ok,HeldBytes,HeldSignature} = quod_node_actor:signed_goal(execute,
            {'::',Ns,{assertz,{held_checkpoint,1}}},crypto:strong_rand_bytes(32),quod_time:now_ms()+10000),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},quod_client_goal_ingress:submit(HeldBytes,HeldSignature)),
        Held = {physics_rest_request,room,3,{request,held,rest,HeldBytes,HeldSignature}},
        commit(Ns,{assertz,Held}),
        assert_reason_count({ambiguous_checkpoint_custody,3},0,body_read(Ns,
            {physics_rest_custody,room,3,none})),
        assert_reason({checkpoint_custody_held,3},door_action(Ns,Checkpoint)),
        OtherHeld = setelement(4,Held,{request,other,rest,HeldBytes,HeldSignature}),
        commit(Ns,{assertz,OtherHeld}),
        assert_reason({ambiguous_checkpoint_custody,3},door_action(Ns,Checkpoint)),
        commit(Ns,{retract,OtherHeld}), commit(Ns,{retract,Held}),
        PushPolicy = {physics_push_allowances,room,{'_'},3,{push_limits,5000,5000}},
        commit(Ns,{'$quod_retract_exact',PushPolicy}),
        assert_reason({push_allowances_missing,3},control_goal({'::',Ns,
            setelement(6,Go,{push,{body,3,1},{vector,1000,0,0}})})),
        commit(Ns,{assertz,PushPolicy}),
        SmallPush = {physics_push_allowances,room,{'_'},3,{push_limits,1,5000}},
        commit(Ns,{asserta,SmallPush}),
        ?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_]}}}},body_read(Ns,{',',
            {physics_push_configuration,room,Human,3,1,{0},5000},
            {'>',{0},1000}})),
        commit(Ns,{'$quod_retract_exact',SmallPush}),
        commit(Ns,{assertz,{can_query_physics_motion,room,Human,2,{'_'}}}),
        Query = {physics_motion_query,room,2,{travel,{vector,1,0,0},{angular,0,0,0}},{0}},
        assert_reason({query_allowances_missing,room},body_read(Ns,Query)),
        QueryPolicy = {physics_query_allowances,room,Human,{query_allowances,2,0,8,128,1,1000}},
        commit(Ns,{',',{assertz,QueryPolicy},
            {assertz,setelement(4,QueryPolicy,{query_allowances,2,0,8,128,2000,1000})}}),
        ?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_]}}}},body_read(Ns,
            setelement(4,Query,{travel,{vector,1000,0,0},{angular,0,0,0}}))),
        {ok,_,{normalized,{read,_,{failed,QueryReasons}}}} = body_read(Ns,
            setelement(4,Query,{travel,{vector,2001,0,0},{angular,0,0,0}})),
        {ok,DecodedQueryReasons} = quod_wire_term:decode_failure_reasons(QueryReasons),
        ?assertEqual([],[R || R = {coordinate_allowance,_} <- DecodedQueryReasons]),
        Allowances = {physics_allowances,room,{limits,64,64,256,1000000,{geometry,256,4096,4096}},16667,-9810,10000},
        commit(Ns,{retract,Allowances}),
        commit(Ns,{assertz,{can_view_physics,room,Human}}),
        assert_view_selection(unavailable,body_read(Ns,{client_world_view,room,playing,[],{0}}))
        after sys:resume(Runtime) end
    end) end}.

hot_control_error_and_owner_results_test_() ->
    {timeout,90,fun() -> with_chair(fun(F = #{namespace := Ns,node := Human}) ->
        {Pid,World} = enable(F),
        {Definition,_,ControlFrame,_,_} = install_test_control(F,Pid,World,
            {motion,free,2000,1600,1000,{query_limits,2,0,8,128},[]}),
        {control_frame,Frame,_} = ControlFrame,
        Drive = {drive,{vector,0,0,0},{angular,0,0,0}},
        Go = {physics_control_input,room,ControlFrame,1,1,Drive,{0}},
        Read = {physics_body_state,room,1,{0}},
        commit(Ns,{assertz,{can_read_physics_body,room,Human,1}}),
        [?assertMatch({ok,_,{normalized,{read,_,{error,_}}}},body_read(Ns,Goal)) || Goal <-
            [{physics_body_state,room,{0},{1}}, {physics_body_state,room,bad_body,{0}},
             {physics_body_state,room,-1,{0}},
             {physics_motion_query,room,1,{0},{1}},
             {'$quod_sample_physics',forged,{physics_body_state,room,1},Frame,1,none,{0}}]],
        ?assertMatch({ok,_,{normalized,{error,_}}},control_goal({'::',Ns,setelement(6,Go,{0})})),
        ?assertMatch({ok,_,{normalized,{error,_}}},door_action(Ns,Read)),
        ?assertMatch({ok,_,{normalized,{read,_,{error,_}}}},body_read(Ns,Go)),
        ?assertMatch({ok,_,{normalized,{error,_}}},door_action(Ns,Go)),
        ?assertMatch({ok,_,{normalized,{error,_}}},control_goal({'::',Ns,
            {'$quod_stage_physics_input',forged,Go,none,500,{query_limits,2,0,8,128},{0}}})),
        Runtime = quod_reg:where({quod_runtime,Ns}), ok = sys:suspend(Runtime),
        try
            %% Authored policy return values still cross the real opaque handle.
            remove_physics_policy(Ns,physics_body_read_projection),
            Policy = fun(Fence,Revision) -> {physics_body_read_projection,room,1,Fence,Revision} end,
            Bad = Policy(invalid_frame,1), commit(Ns,{assertz,Bad}),
            ?assertMatch({ok,_,{normalized,{read,_,{error,_}}}},body_read(Ns,Read)),
            commit(Ns,{retract,Bad}), WrongWorld = setelement(2,Frame,setelement(4,World,other)),
            Wrong = Policy(WrongWorld,1), commit(Ns,{assertz,Wrong}),
            ?assertMatch({ok,_,{normalized,{read,_,{error,_}}}},body_read(Ns,Read)),
            commit(Ns,{retract,Wrong}), BadRevision = Policy(Frame,0), commit(Ns,{assertz,BadRevision}),
            ?assertMatch({ok,_,{normalized,{read,_,{error,_}}}},body_read(Ns,Read)),
            commit(Ns,{retract,BadRevision}), MissingSample = Policy(Frame,2), commit(Ns,{assertz,MissingSample}),
            %% Missing body/revision is an explicit sample answer, not owner loss.
            {ok,_,{normalized,{read,_,{answers,_,[SampleBinding]}}}} = body_read(Ns,Read),
            {ok,SamplePairs} = quod_client_result:decode_binding(SampleBinding),
            ?assertEqual([unavailable],[Value || {_,Value} <- SamplePairs]),
            commit(Ns,{retract,MissingSample}), commit(Ns,{assertz,Policy(Frame,1)}),
            remove_physics_policy(Ns,physics_input_projection),
            Projection = fun(Lease,Limits) -> {physics_input_projection,room,ControlFrame,1,1,Drive,
                {control,Human,1,Definition},Lease,Limits} end,
            BadLease = Projection(0,{query_limits,2,0,8,128}), commit(Ns,{assertz,BadLease}),
            ?assertMatch({ok,_,{normalized,{error,_}}},control_goal({'::',Ns,Go})),
            commit(Ns,{retract,BadLease}), BadLimits = Projection(500,invalid_limits), commit(Ns,{assertz,BadLimits}),
            ?assertMatch({ok,_,{normalized,{error,_}}},control_goal({'::',Ns,Go})),
            commit(Ns,{retract,BadLimits}), commit(Ns,{assertz,Projection(500,{query_limits,2,0,8,128})}),
            gen_server:stop(Pid),
            assert_reason({physics_world_unavailable,room},body_read(Ns,Read)),
            assert_reason({physics_world_unavailable,room},control_goal({'::',Ns,Go})),
            Reader = refusing_test_owner(World,read),
            NameMonitor = quod_reg:monitor_name({physics_world,World},info),
            assert_reason({physics_owner_unavailable,room},body_read(Ns,Read)),
            receive {test_owner_called,Reader,read} -> ok after 5000 -> error(owner_not_called) end,
            receive {gproc,unreg,NameMonitor,_} -> ok after 5000 -> error(owner_name_not_retired) end,
            Releaser = refusing_test_owner(World,release),
            ?assertMatch({ok,_,{normalized,{error,_}}},control_goal({'::',Ns,Go})),
            receive {test_owner_called,Releaser,release} -> ok after 5000 -> error(release_not_called) end,
            receive {test_owner_called,Releaser,_} -> error(uncertain_release_repeated) after 0 -> ok end
        after sys:resume(Runtime) end
    end) end}.

remove_physics_policy(Ns,Functor) ->
    [commit(Ns,{'$quod_retract_exact',Rule}) || Rule = {':-',Head,_} <-
        quod_prolog:read_terms("priv/ontologies/quod_physics.pl"),element(1,Head) =:= Functor],ok.

%% A controlled owner disappearance tests the lost-reply production seam.
refusing_test_owner(World,Mode) ->
    Parent = self(), {Pid,Monitor} = spawn_monitor(fun() ->
        true = quod_reg:reg({physics_world,World}), Parent ! {test_owner_ready,self()},
        receive {'$gen_call',_,_Request} -> Parent ! {test_owner_called,self(),Mode} end
    end),
    receive {test_owner_ready,Pid} -> ok after 5000 -> error(test_owner_not_registered) end,
    erlang:demonitor(Monitor,[flush]), Pid.

signed_motion_query_owner_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Human}) ->
        {Pid,World} = enable(F),
        Goal = {physics_motion_query,room,2,{travel,{vector,5000,0,2000},{angular,0,0,0}},{0}},
        commit(Ns,{',',{assertz,{can_invoke,{physics_motion_query,{'_'},{'_'},{'_'},{'_'}},Human,{'_'},Ns}},
            {assertz,{physics_query_allowances,room,Human,{query_allowances,2,0,8,128,20000,3141}}}}),
        ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},body_read(Ns,Goal)),
        commit(Ns,{assertz,{can_query_physics_motion,room,Human,2,{'_'}}}),
        ?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_]}}}},body_read(Ns,Goal)),
        %% A write-mode proof cannot use a live query to admit a durable edit.
        ?assertMatch({ok,_,{normalized,{error,_}}},door_action(Ns,Goal)),
        #{World := #{spec := Spec}} = worlds(Ns),
        Expected = #{fence => quod_physics:fence(Spec),structure => 1,
                     incarnation => maps:get(run_token,Spec)},
        Query = {travel,{vector,5000,0,2000},{angular,0,0,0}},
        Limits = {query_limits,2,0,8,128},
        {ok,_,{0,0,0},{clipped,{{X,_,Z},_},_,_}} = quod_physics:motion_query(Pid,Expected,{2,1},Query,Limits,1000),
        ?assert(X < 1.4 andalso X > 1.39), ?assert(abs(Z-2.0) < 0.001),
        {ok,_,{0,0,0},Before} = quod_physics:body_state(Pid,Expected,{2,1},1000),
        assert_no_physics_io(fun() ->
            [?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_]}}}},body_read(Ns,Goal)) || _ <- lists:seq(1,3)]
        end),
        ?assertMatch({ok,_,{0,0,0},Before},quod_physics:body_state(Pid,Expected,{2,1},1000)),
        ?assertMatch({ok,_,{0,0,0},{occupied,3,_}},quod_physics:motion_query(Pid,Expected,{2,1},
            {place,{pose,{vector,2000,1002,0},{rotation,0,0,0}}},Limits,1000)),
        ?assertMatch({ok,_,{0,0,0},exhausted},quod_physics:motion_query(Pid,Expected,{2,1},Query,{query_limits,2,0,8,1},1000)),
        ?assertMatch({ok,_,{0,0,0},unavailable},quod_physics:motion_query(Pid,Expected,{2,0},Query,Limits,1000)),
        ?assertMatch({error,unavailable},quod_physics:motion_query(Pid,Expected#{structure => 0},{2,1},Query,Limits,1000)),
        ?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_]}}}},body_read(Ns,Goal)),
        commit(Ns,{retract,{can_query_physics_motion,room,Human,2,{'_'}}}),
        ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},body_read(Ns,Goal))
    end,fun(Rules) ->
        [case Rule of
            {physics_body_definition, room, 2, 1, _, _, {owned, _, _}} ->
                {physics_body_definition, room, 2, 1, controlled, {vector,0,1002,0}, {owned, {box,500,1000,500}, 1}};
            _ -> Rule
        end || Rule <- Rules] ++
        [{physics_body_definition, room, 3, 1, fixed, {vector,2000,2000,0}, {owned, {box,100,3000,10000}, 1}}]
    end) end}.

signed_control_releases_only_successful_proof_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Human}) ->
        {Pid,World} = enable(F),
        Limits = {query_limits,2,0,8,128},
        {_,Expected,Frame,Ref,Initial} = install_test_control(F,Pid,World,
            {motion,free,2000,1600,500,Limits,[]}),
        Drive = {drive,{vector,2000,0,0},{angular,0,0,0}},
        {control_frame,_,Registration} = Frame,
        ?assertEqual({error,expired},gen_server:call(Pid,
            {physics_input,Expected#{registration => Registration},maps:get(control,Expected),1,
             {Drive,Limits},quod_time:now_ms()+500,quod_time:mono_ms()-1})),
        Command = fun(Seq,Input) -> {physics_control_input,room,Frame,1,Seq,Input,{0}} end,
        Go = Command(10,Drive),
        ?assertMatch({ok,_,{normalized,{read,_,{error,_}}}},body_read(Ns,Go)),
        ?assertMatch({ok,_,{normalized,{error,_}}},door_action(Ns,Go)),
        ?assertMatch({ok,_,{normalized,{failed,_}}},control_goal({'::',Ns,{',',Go,fail}})),
        ?assertMatch(#{inputs := M} when map_size(M) =:= 0,gen_server:call(Pid,status)),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal(
            {';', {',',{'::',Ns,Go},fail},true})),
        ?assertMatch(#{inputs := M} when map_size(M) =:= 0,gen_server:call(Pid,status)),
        %% Negation and a cut followed by failure must restore the staged
        %% operation in another ontology's proof scope.
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal(
            {'\\+', {',',{'::',Ns,Go},fail}})),
        ?assertMatch({ok,_,{normalized,{failed,_}}},control_goal(
            {'::',Ns,{physics_test_cut,Go}})),
        ?assertMatch(#{inputs := M} when map_size(M) =:= 0,gen_server:call(Pid,status)),
        %% A control proof promises one indivisible live operation. A second
        %% staged command fails the entire proof rather than partially applying.
        assert_reason(transient_already_staged,control_goal(
            {'::',Ns,{',',Go,Command(11,Drive)}})),
        ?assertMatch(#{inputs := M} when map_size(M) =:= 0,gen_server:call(Pid,status)),
        quod_physics:ack(Pid,Ref,maps:get(tick,Initial),maps:get(origin_sequence,Initial)),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal({'::',Ns,Go})),
        ?assertMatch(#{inputs := #{Human := #{sequence := 10}}},gen_server:call(Pid,status)),
        Moved = receive {physics_frame,Pid,Ref,V} -> V after 5000 -> error(control_did_not_move) end,
        {2,1,world,{X,_,_},_,_} = lists:keyfind(2,1,maps:get(poses,Moved)),
        ?assert(X > 0.0),
        assert_reason({stale_sequence,10},control_goal({'::',Ns,Go})),
        Stop = {drive,{vector,0,0,0},{angular,0,0,0}},
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal({'::',Ns,Command(11,Stop)})),
        assert_no_physics_io(fun() ->
            [?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal({'::',Ns,Command(Seq,Stop)}))
             || Seq <- lists:seq(12,14)]
        end),
        commit(Ns,{retract,{can_control_physics_agent,room,Human,pilot}}),
        {Pid,World} = installed(Ns),
        ?assertMatch(#{inputs := #{Human := #{sequence := 14,result := suspended}}},gen_server:call(Pid,status)),
        ?assertMatch({ok,_,{normalized,{failed,_}}},control_goal({'::',Ns,Command(15,Drive)})),
        commit(Ns,{assertz,{can_control_physics_agent,room,Human,pilot}}),
        {Pid,World} = installed(Ns),
        assert_reason(stale_registration,control_goal({'::',Ns,Go})),
        %% Even a higher-sequence command from the disconnected view cannot
        %% control its replacement registration.
        assert_reason(stale_registration,control_goal({'::',Ns,Command(100,Drive)})),
        {ok,FreshRef,FreshView} = quod_physics:watch(Pid,Expected,none),
        {control_frame,BaseFrame,_} = Frame,
        FreshFrame = {control_frame,BaseFrame,maps:get(registration,FreshView)},
        assert_reason(stale_registration,control_goal({'::',Ns,Command(100,Drive)})),
        FreshCommand = setelement(3,Command(15,Stop),FreshFrame),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal({'::',Ns,FreshCommand})),
        quod_physics:unwatch(Pid,FreshRef)
    end,fun(Rules) -> [case R of
        {physics_body_definition, room, 2, 1, _, _, {owned, _, _}} ->
            {physics_body_definition, room, 2, 1, controlled, {vector,0,1002,0}, {owned, {box,500,1000,500}, 1}};
        _ -> R end || R <- Rules] ++
        [{':-',{physics_test_cut,{'Goal'}},
            {';',{',',{call,{'Goal'}},{',','!',fail}},true}}] end) end}.

install_test_control(F,Pid,World,Motion) -> install_test_control(F,Pid,World,Motion,2).
install_test_control(#{namespace := Ns,node := Human},Pid,World,Motion,Body) ->
    #{World := #{spec := Before}} = worlds(Ns),
    {Body,Revision,_,_,_,_} = lists:keyfind(Body,1,maps:get(bodies,Before)),
    View = {viewpoint,eye,{pose,{vector,0,100,0},{rotation,0,0,0}},view_only},
    Definition = {controlled_agent,pilot,1,Body,Revision,Motion,View},
    commit(Ns,{',',quod_ct:source_assertion({instance_of,agent,pilot}),
        {',',{assertz,{physics_agent,room,pilot,1,Body,Motion}},
        {',',{assertz,{physics_viewpoint,room,pilot,eye,Body,element(3,View),element(4,View)}},
        {',',{assertz,{can_control_physics_agent,room,Human,pilot}},
        {',',{assertz,{physics_control,room,Human,1,{controlled,pilot,eye}}},
             {assertz,{can_invoke,{'_'},Human,{'_'},Ns}}}}}}}),
    reconcile(Ns), {Pid,World} = installed_world(World),
    #{World := #{spec := Spec}} = worlds(Ns),
    Frame = {physics_frame,World,maps:get(authority,Spec),maps:get(epoch,Spec),
             maps:get(generation,Spec),maps:get(run_token,Spec),maps:get(structure,Spec)},
    Expected = #{fence => quod_physics:fence(Spec),incarnation => maps:get(run_token,Spec),
                 structure => maps:get(structure,Spec),control => {control,Human,1,Definition}},
    {ok,Ref,Initial} = quod_physics:watch(Pid,Expected,none),
    {Definition,Expected,{control_frame,Frame,maps:get(registration,Initial)},Ref,Initial}.

grounded_jump_and_ceiling_test_() ->
    [{atom_to_list(Terrain),{timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Human}) ->
        {Pid,World} = enable(F),
        Motion = {motion,{grounded,900},2500,1600,500,{query_limits,2,0,8,128},[{jump,4000}]},
        {_,Expected,Frame,Ref,Initial} = install_test_control(F,Pid,World,Motion),
        quod_physics:ack(Pid,Ref,maps:get(tick,Initial),maps:get(origin_sequence,Initial)),
        Command = fun(Seq,Input) -> control_goal({'::',Ns,
            {physics_control_input,room,Frame,1,Seq,Input,{0}}}) end,
        ?assertMatch({ok,_,{normalized,{failed,_}}},Command(0,{jump,4001})),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(1,{jump,4000})),
        {First,Result} = input_frame(Pid,Ref,Human,1),
        case Terrain of
            air -> ?assertEqual(no_support,Result);
            _ -> ?assertEqual(jumped,Result), ?assert(jump_height(First) > 0.502)
        end,
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(2,{jump,4000})),
        {Second,no_support} = input_frame(Pid,Ref,Human,2),
        assert_reason({stale_sequence,2},Command(2,{jump,4000})),
        Peak = jump_landing(Pid,Ref,jump_height(Second)),
        case Terrain of
            ceiling -> ?assert(Peak =< 1.002);
            floor -> ?assert(Peak > 1.2 andalso Peak < 1.4);
            air -> ?assert(Peak =< 1.5)
        end,
        %% A definite landing enables a new jump; disconnect clears input but
        %% preserves the accepted ascent and gravity in the same owner.
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(3,{jump,4000})),
        {_,jumped} = input_frame(Pid,Ref,Human,3),
        quod_physics:unwatch(Pid,Ref), _ = gen_server:call(Pid,status),
        {ok,NewRef,Restored} = quod_physics:watch(Pid,Expected,none),
        ?assert(jump_height(Restored) > 0.502),
        quod_physics:ack(Pid,NewRef,maps:get(tick,Restored),maps:get(origin_sequence,Restored)),
        assert_reason(stale_registration,Command(4,{jump,4000})),
        _ = jump_landing(Pid,NewRef,jump_height(Restored)),
        quod_physics:unwatch(Pid,NewRef)
    end,fun(Rules) ->
        Height = case Terrain of air -> 1500; _ -> 502 end,
        Base = [case R of
            {physics_body_definition,room,2,1,_,_,{owned,_,_}} ->
                {physics_body_definition,room,2,1,controlled,{vector,0,Height,0},{owned,{ball,500},1}};
            _ -> R end || R <- Rules],
        case Terrain of
            ceiling -> Base ++ [{physics_body_definition,room,3,1,fixed,
                {vector,0,1600,0},{owned,{box,5000,100,5000},1}}];
            _ -> Base
        end
    end) end}} || Terrain <- [floor,ceiling,air]].

jump_height(Frame) ->
    {2,_,world,{_,Y,_},_,_} = lists:keyfind(2,1,maps:get(poses,Frame)), Y.
jump_landing(Pid,Ref,Peak) ->
    receive {physics_frame,Pid,Ref,Frame} ->
        quod_physics:ack(Pid,Ref,maps:get(tick,Frame),maps:get(origin_sequence,Frame)),
        Y = jump_height(Frame), Maximum = max(Y,Peak),
        case Y =< 0.505 of true -> Maximum; false -> jump_landing(Pid,Ref,Maximum) end
    after 5000 -> error(jump_did_not_land) end.

lobby_rim_jump_test_() ->
    [{lists:concat([Angle,"-",Start]),{timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Human}) ->
        {Pid,World} = enable(F),
        [{':-',{physics_agent,_,_,1,_,Motion},_}] =
            [T || T={':-',{physics_agent,_,_,1,_,_},_} <-
                quod_prolog:read_terms("priv/ontologies/lobby_instance.pl")],
        {motion,_,_,_,_,_,Capabilities} = Motion,
        {jump,Launch} = lists:keyfind(jump,1,Capabilities),
        {_,_,Frame,Ref,Initial} = install_test_control(F,Pid,World,Motion),
        quod_physics:ack(Pid,Ref,maps:get(tick,Initial),maps:get(origin_sequence,Initial)),
        Command = fun(Seq,Input) -> control_goal({'::',Ns,
            {physics_control_input,room,Frame,1,Seq,Input,{0}}}) end,
        Direction = {vector,round(2499*math:sin(Angle*math:pi()/180)),0,
            -round(2499*math:cos(Angle*math:pi()/180))},
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(1,{jump,Launch})),
        {First,JumpResult} = input_frame(Pid,Ref,Human,1),
        ?assertEqual(jumped,JumpResult),
        Evidence = lobby_rim_frames(Pid,Ref,Command,Direction,2,120,First,
            #{first_contact_y => none,contact_rising => false,after_contact_peak => 0.0,
                previous_y => jump_height(First),peak => 0.0,max_radius => 0.0}),
        io:format(user,"lobby_rim_case ~p~n",[Evidence#{angle => Angle,start => Start,jump => JumpResult}]),
        #{first_contact_y := ContactY,after_contact_peak := Peak,contact_rising := Rising} = Evidence,
        ?assert(is_float(ContactY)),
        ?assert(Rising),
        ?assert(ContactY < 1.48),
        ?assert(Peak > ContactY+0.01),
        quod_physics:unwatch(Pid,Ref)
    end,fun(Rules) ->
        {ok,E} = erlog:new(),
        Loaded = lists:foldl(fun(T,A) -> {{succeed,_},B}=erlog:prove({assertz,T},A),B end,
            E,quod_prolog:read_terms("priv/ontologies/quod_lobby.pl")),
        {{succeed,Bindings},_} = erlog:prove({lobby_definitions,{'Definitions'}},Loaded),
        {physics_definition,floor,1,{geometry,Floor,1}} =
            lists:keyfind(floor,2,proplists:get_value('Definitions',Bindings)),
        Radius = case {Start,Angle} of
            {touching,7} -> 8230;
            {touching,_} -> 8300;
            {approaching,_} -> 8200
        end,
        [case R of
            {physics_body_definition,room,1,1,_,_,_} ->
                {physics_body_definition,room,1,1,fixed,{vector,0,0,0},{owned,Floor,1}};
            {physics_body_definition,room,2,1,_,_,_} ->
                {physics_body_definition,room,2,1,controlled,
                    {vector,round(Radius*math:sin(Angle*math:pi()/180)),752,
                        -round(Radius*math:cos(Angle*math:pi()/180))},
                    {owned,{capsule,500,250},1}};
            _ -> R
        end || R <- Rules]
    end) end}} || Angle <- [0,7,15],Start <- [approaching,touching]].

lobby_rim_frames(_,_,_,_,_,0,_,Evidence) -> Evidence;
lobby_rim_frames(Pid,Ref,Command,Direction={vector,Dx,0,Dz},Seq,Remaining,Frame,Evidence) ->
    {2,1,world,{X,Y,Z},_,_} = lists:keyfind(2,1,maps:get(poses,Frame)),
    ?assertMatch({true,true},{X*X+Z*Z < 8.56*8.56,Y > 0.7}),
    WallContacts = [Contact || #{result := {clipped,_,Contacts,_}} <- maps:values(maps:get(inputs,Frame)),
        Contact = {_,{Nx,Ny,Nz}} <- Contacts,Ny < 0.5,Nx*Dx+Nz*Dz < -1250],
    WallContact = WallContacts =/= [],
    ContactY = case {maps:get(first_contact_y,Evidence),WallContact} of
        {none,true} -> Y;
        {Previous,_} -> Previous
    end,
    Rising = case {maps:get(first_contact_y,Evidence),WallContact} of
        {none,true} -> Y > maps:get(previous_y,Evidence)+0.0001;
        _ -> maps:get(contact_rising,Evidence)
    end,
    AfterPeak = case ContactY of
        none -> 0.0;
        _ -> max(Y,maps:get(after_contact_peak,Evidence))
    end,
    FirstContacts = case {maps:get(first_contact_y,Evidence),WallContact} of
        {none,true} -> WallContacts;
        _ -> maps:get(first_contacts,Evidence,[])
    end,
    NextEvidence = Evidence#{first_contact_y => ContactY,peak => max(Y,maps:get(peak,Evidence)),
        contact_rising => Rising,after_contact_peak => AfterPeak,previous_y => Y,
        first_contacts => FirstContacts,
        max_radius => max(math:sqrt(X*X+Z*Z),maps:get(max_radius,Evidence))},
    case Remaining rem 6 of
        0 -> ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},
            Command(Seq,{drive,Direction,{angular,0,0,0}}));
        _ -> ok
    end,
    receive {physics_frame,Pid,Ref,Next} ->
        quod_physics:ack(Pid,Ref,maps:get(tick,Next),maps:get(origin_sequence,Next)),
        lobby_rim_frames(Pid,Ref,Command,Direction,Seq+1,Remaining-1,Next,NextEvidence)
    after 5000 -> error(lobby_rim_frame_missing) end.

grounded_reinstall_and_wedge_settling_test_() ->
    [{atom_to_list(Terrain),{timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Human}) ->
        {Pid,World} = enable(F),
        Motion = {motion,{grounded,900},2000,1600,500,{query_limits,2,0,8,128},[]},
        {_,Expected,Frame,Ref,Initial} = install_test_control(F,Pid,World,Motion),
        %% Consume only already-delivered idle notices before issuing input.
        _ = gen_server:call(Pid,status), flush_sleeping(Pid),
        quod_physics:ack(Pid,Ref,maps:get(tick,Initial),maps:get(origin_sequence,Initial)),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal({'::',Ns,
            {physics_control_input,room,Frame,1,1,{drive,{vector,0,0,0},{angular,0,0,0}},{0}}})),
        {Falling,_} = input_frame(Pid,Ref,Human,1),
        {2,1,world,{_,Y0,_},_,_} = lists:keyfind(2,1,maps:get(poses,Falling)),
        ?assert(Y0 > 1.0),
        %% This update invalidates navigation while the agent is in the air.
        %% No new command or view is supplied after installation.
        commit(Ns,{',',{retract,{physics_structure,room,1}},{assertz,{physics_structure,room,2}}}),
        {Pid,World} = installed(Ns),
        receive {physics_status,_,Pid,World,_,sleeping} -> ok
        after 5000 -> error(grounded_body_never_settled) end,
        {ok,Settled,_} = quod_physics:snapshot(Pid,Expected#{structure => 2,tick => -1}),
        {2,1,world,{_,Y,_},_,_} = lists:keyfind(2,1,maps:get(poses,Settled)),
        ?assert(Y < 0.72 andalso Y >= 0.5),
        Before = gen_server:call(Pid,status),
        assert_no_physics_io(fun() ->
            [reconcile(Ns) || _ <- lists:seq(1,3)],
            ?assertEqual(maps:with([steps,tick,installs],Before),
                maps:with([steps,tick,installs],gen_server:call(Pid,status)))
        end),
        %% Removing/moving the support wakes a settled body without another
        %% input, including when its old contact was a non-landing wedge.
        RemoveWedge = case Terrain of floor -> true; wedge -> {retract,{physics_body_definition, room, 3, {'_'}, {'_'}, {'_'}, {owned, {'_'}, {'_'}}}} end,
        commit(Ns,{',',{retract,{physics_body_definition, room, 1, 1, fixed, {vector,0,-500,0}, {owned, {box,10000,500,10000}, 1}}},
            {',',{assertz,{physics_body_definition, room, 1, 2, fixed, {vector,0,-2500,0}, {owned, {box,10000,500,10000}, 1}}},
            {',',RemoveWedge,{',',{retract,{physics_structure,room,2}},{assertz,{physics_structure,room,3}}}}}}),
        {Pid,World} = installed(Ns),
        receive {physics_status,_,Pid,World,_,sleeping} -> ok
        after 5000 -> error(changed_support_never_settled) end,
        {ok,Lower,_} = quod_physics:snapshot(Pid,Expected#{structure => 3,tick => -1}),
        {2,1,world,{_,LowerY,_},_,_} = lists:keyfind(2,1,maps:get(poses,Lower)),
        ?assert(LowerY < -1.49 andalso LowerY >= -1.5)
    end,fun(Rules) ->
        Base = [case R of
            {physics_body_definition, room, 2, 1, _, _, {owned, _, _}} ->
                {physics_body_definition, room, 2, 1, controlled, {vector,0,1500,0}, {owned, {ball,500}, 1}};
            _ -> R end || R <- Rules],
        case Terrain of
            floor -> Base;
            wedge -> Base ++ [{physics_body_definition, room, 3, 1, fixed, {vector,0,0,0}, {owned, {surface,[{vector,-10000,10000,-10000},{vector,0,0,-10000},{vector,10000,10000,-10000},
                          {vector,-10000,10000,10000},{vector,0,0,10000},{vector,10000,10000,10000}],
                         [{triangle,0,3,1},{triangle,1,3,4},{triangle,1,4,2},{triangle,2,4,5}]}, 1}}]
        end
    end) end}} || Terrain <- [floor,wedge]].

flush_sleeping(Pid) ->
    receive {physics_status,_,Pid,_,_,sleeping} -> flush_sleeping(Pid) after 0 -> ok end.

signed_landing_reposition_and_feedback_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Human}) ->
        {Pid,World} = enable(F),
        Motion = {motion,{grounded,700},2000,1600,500,{query_limits,2,0,8,128},
                  [{teleport,6000,2000,700},{snap,785},reposition]},
        {_,_,Frame,Ref,Initial} = install_test_control(F,Pid,World,Motion),
        ?assertNot(maps:is_key(view_clearance,Initial)),
        quod_physics:ack(Pid,Ref,maps:get(tick,Initial),maps:get(origin_sequence,Initial)),
        Command = fun(Seq,Input) -> control_goal({'::',Ns,
            {physics_control_input,room,Frame,1,Seq,Input,{0}}}) end,
        ?assertMatch({ok,_,{normalized,{failed,_}}},Command(0,{snap,2000})),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(1,{teleport,{vector,2000,2000,0}})),
        {Occupied,{occupied,3,_}} = input_frame(Pid,Ref,Human,1),
        ?assertMatch({2,1,world,{0.0,_,0.0},_,_},lists:keyfind(2,1,maps:get(poses,Occupied))),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(2,{teleport,{vector,4000,2000,0}})),
        {_,{blocked,3,_}} = input_frame(Pid,Ref,Human,2),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(3,{teleport,{vector,0,2000,3000}})),
        {Landed,{clipped,_,_,_}} = input_frame(Pid,Ref,Human,3),
        {2,1,world,{_,Y,3.0},_,_} = lists:keyfind(2,1,maps:get(poses,Landed)),
        ?assert(Y >= 1.0 andalso Y < 1.003),
        %% Reposition is explicit and occupancy checked, but unlike teleport it
        %% is permitted to repair an invalid placement without a clear path.
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(4,
            {reposition,{pose,{vector,2000,1002,0},{rotation,0,0,0}}})),
        {Rejected,{occupied,3,_}} = input_frame(Pid,Ref,Human,4),
        ?assertMatch({2,1,world,{_,_,3.0},_,_},lists:keyfind(2,1,maps:get(poses,Rejected))),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(5,{snap,785})),
        {Turned,_} = input_frame(Pid,Ref,Human,5),
        {2,1,world,_,{_,Qy,_,_},_} = lists:keyfind(2,1,maps:get(poses,Turned)),
        ?assert(Qy > 0.3),
        quod_physics:unwatch(Pid,Ref)
    end,fun(Rules) -> [case R of
        {physics_body_definition, room, 2, 1, _, _, {owned, _, _}} ->
            {physics_body_definition, room, 2, 1, controlled, {vector,0,1002,0}, {owned, {box,500,1000,500}, 1}};
        _ -> R end || R <- Rules] ++
        [{physics_body_definition, room, 3, 1, fixed, {vector,2000,2000,0}, {owned, {box,100,3000,2000}, 1}}]
    end) end}.

foreign_signed_control_view_and_reconnect_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Human,identity := Identity}) ->
        {Pid,World} = enable(F),
        Motion = {motion,free,2000,1600,500,{query_limits,2,0,8,128},[]},
        {_,_,_,Ref,_} = install_test_control(F,Pid,World,Motion),
        quod_physics:unwatch(Pid,Ref), _ = gen_server:call(Pid,status),
        commit(Ns,{assertz,{can_view_physics,room,Human}}),
        reconcile(Ns),
        Parent = self(), Socket = spawn_link(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
        try
            Session = simulation_session(Identity),
            Open = fun() -> Socket ! {client,simulation_open(F,Session,Human)} end,
            Open(), First = simulation_reply(Socket,<<"projection">>),
            Frame = maps:get(<<"frame">>,First),
            ?assertEqual(<<"2">>,maps:get(<<"body">>,hd(maps:get(<<"poses">>,Frame)))),
            ?assertEqual(<<"[]">>,maps:get(<<"marks">>,First)),
            ?assertMatch(#{<<"sequence">> := <<"-1">>},maps:get(<<"control_state">>,Frame)),
            %% Socket reopening revokes the old registration without changing
            %% body geometry or authority. The source principal remains Human.
            Open(), Second = simulation_reply(Socket,<<"projection">>),
            ?assertNotEqual(maps:get(<<"registration">>,Frame),
                maps:get(<<"registration">>,maps:get(<<"frame">>,Second))),
            %% A different signed session must retire the old subscription,
            %% even for the same actor, world and goal.
            SameScope = simulation_state(Socket), OtherSession = simulation_session(Identity),
            Socket ! {client,simulation_open(F,OtherSession,Human)},
            _ = simulation_reply(Socket,<<"projection">>),
            ChangedScope = simulation_state(Socket),
            ?assertNotEqual(maps:get(monitor,SameScope),maps:get(monitor,ChangedScope)),
            ?assertNotEqual(maps:get(dependency_monitors,SameScope),maps:get(dependency_monitors,ChangedScope)),
            ?assertEqual(false,erlang:read_timer(maps:get(timer,SameScope))),
            #{inputs := Inputs} = gen_server:call(Pid,status), ?assertEqual(#{},Inputs),
            %% An advance in the foreign signer's ontology invalidates this
            %% projection too, even if the world's height is much higher.
            {agent_instance_ref,Source,_,_} = Human,
            commit(Source,{assertz,{source_changed,true}}),
            _ = simulation_reply(Socket,<<"refresh">>),
            commit(Ns,{assertz,{physics_agent,room,pilot,2,2,Motion}}),
            Open(),
            ?assertMatch(#{<<"selection">> := <<"unavailable">>},simulation_reply(Socket,<<"projection">>))
        after Socket ! stop end
    end,fun(Rules) -> [case R of
        {physics_body_definition, room, 2, 1, _, _, {owned, _, _}} ->
            {physics_body_definition, room, 2, 1, controlled, {vector,0,1002,0}, {owned, {box,500,1000,500}, 1}};
        _ -> R end || R <- Rules] end) end}.

input_frame(Pid,Ref,Principal,Seq) ->
    receive {physics_frame,Pid,Ref,Frame} ->
        quod_physics:ack(Pid,Ref,maps:get(tick,Frame),maps:get(origin_sequence,Frame)),
        case maps:get(Principal,maps:get(inputs,Frame,#{}),none) of
            #{sequence := Seq,pending := false,result := Result} -> {Frame,Result};
            _ -> input_frame(Pid,Ref,Principal,Seq)
        end
    after 5000 -> error({missing_input_result,Seq,gen_server:call(Pid,status)}) end.

changed_control_view_retains_sequence_test_() ->
    {timeout,60,fun() -> with_chair(fun(F = #{namespace := Ns,node := Human,identity := Identity}) ->
        {Pid,World} = enable(F),
        Motion = {motion,free,2000,1600,1000,{query_limits,2,0,8,128},[]},
        {Definition,Expected,OldFrame,Ref,Initial} = install_test_control(F,Pid,World,Motion),
        quod_physics:ack(Pid,Ref,maps:get(tick,Initial),maps:get(origin_sequence,Initial)),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal({'::',Ns,
            {physics_control_input,room,OldFrame,1,7,
                {drive,{vector,0,0,0},{angular,0,0,0}},{0}}})),
        _ = input_frame(Pid,Ref,Human,7),
        quod_physics:unwatch(Pid,Ref), _ = gen_server:call(Pid,status),
        commit(Ns,{assertz,{can_view_physics,room,Human}}),
        Move = door_action(Ns,{physics_move_body,room,2,1,1,{vector,-3000,1000,0}}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Move),
        await_source_receipt(Move),
        {Pid,World} = installed(Ns),
        Parent = self(), Socket = spawn_link(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
        try
            Socket ! {client,simulation_open(F,simulation_session(Identity),Human)},
            Projection = simulation_reply(Socket,<<"projection">>),
            Frame = maps:get(<<"frame">>,Projection),
            ?assertMatch(#{<<"sequence">> := <<"7">>,<<"pending">> := false,<<"result">> := <<"suspended">>},
                maps:get(<<"control_state">>,Frame)),
            Monitor = monitor(process,Socket), Socket ! stop,
            receive {'DOWN',Monitor,process,Socket,normal} -> ok
            after 5000 -> error(socket_not_released) end,
            {ok,FreshRef,FreshView} = quod_physics:watch(Pid,Expected#{structure => 2,
                control => {control,Human,1,setelement(5,Definition,2)}},none),
            quod_physics:ack(Pid,FreshRef,maps:get(tick,FreshView),maps:get(origin_sequence,FreshView)),
            #{World := #{spec := Spec}} = worlds(Ns),
            ControlFrame = {control_frame,{physics_frame,World,maps:get(authority,Spec),maps:get(epoch,Spec),
                maps:get(generation,Spec),maps:get(run_token,Spec),2},
                maps:get(registration,FreshView)},
            ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal({'::',Ns,
                {physics_control_input,room,ControlFrame,1,8,{push,{body,3,1},{vector,1000,0,0}},{0}}})),
            _ = input_frame(Pid,FreshRef,Human,8),
            ?assertMatch(#{inputs := #{Human := #{sequence := 8,result := pushed}}},gen_server:call(Pid,status)),
            quod_physics:unwatch(Pid,FreshRef)
        after Socket ! stop end
    end) end}.

control_goal(Goal) ->
    {ok,Bytes,Signature} = quod_node_actor:signed_goal(control,Goal,
        crypto:strong_rand_bytes(32),quod_time:now_ms()+10000),
    quod_client_goal_ingress:submit(Bytes,Signature).

control_only_installation_and_revocation_test_() ->
    {timeout, 60, fun() -> with_world(fun(F = #{namespace := Ns, reference := Principal}) ->
        {Pid, World} = enable(F),
        commit(Ns, {',', quod_ct:source_assertion({instance_of,agent,pilot}),
            {',',{assertz,{physics_agent,room,pilot,1,2,{motion,grounded}}},
            {',',{assertz,{physics_viewpoint,room,pilot,eye,2,
                {pose,{vector,0,100,0},{rotation,0,0,0}},view_only}},
            {',',{assertz,{can_control_physics_agent,room,Principal,pilot}},
                 {assertz,{physics_control,room,Principal,1,{controlled,pilot,eye}}}}}}}),
        reconcile(Ns),
        #{World := #{spec := Spec}} = worlds(Ns),
        [Control] = maps:get(agent_controls, Spec),
        {Pid, World} = installed(Ns),
        Expected = #{fence => quod_physics:fence(Spec), structure => 1,
            incarnation => maps:get(run_token,Spec), control => Control},
        {ok, Ref, _} = quod_physics:watch(Pid,Expected,none),
        #{installs := Installs} = gen_server:call(Pid,status),
        assert_no_physics_io(fun() -> reconcile(Ns) end),
        ?assertMatch(#{installs := Installs},gen_server:call(Pid,status)),
        commit(Ns,{retract,{can_control_physics_agent,room,Principal,pilot}}),
        receive {physics_refresh,Pid,Ref} -> ok
        after 5000 -> error(control_not_revoked) end,
        {Pid,World} = installed(Ns),
        ?assertEqual({error,unavailable},quod_physics:watch(Pid,Expected,none)),
        ?assertMatch(#{installs := Installs},gen_server:call(Pid,status)),
        %% Grant dependencies are retained by the real runtime selector. Their
        %% restoration installs a fresh view opportunity without touching bodies.
        commit(Ns,{assertz,{can_control_physics_agent,room,Principal,pilot}}),
        {Pid,World} = installed(Ns),
        {ok,Fresh,_} = quod_physics:watch(Pid,Expected,none),
        quod_physics:unwatch(Pid,Fresh)
    end) end}.

renewed_control_preserves_input_and_fences_registration_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Human}) ->
        {Pid,World} = enable(F),
        Motion = {motion,free,2000,1600,1000,{query_limits,2,0,8,128},[{snap,785}]},
        {_,Expected,OldFrame,Ref,Initial} = install_test_control(F,Pid,World,Motion),
        quod_physics:ack(Pid,Ref,maps:get(tick,Initial),maps:get(origin_sequence,Initial)),
        Input = {drive,{vector,1000,0,0},{angular,0,0,0}},
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal({'::',Ns,
            {physics_control_input,room,OldFrame,1,7,Input,{0}}})),
        {Moving,_} = input_frame(Pid,Ref,Human,7),
        %% Inspect the actual retained row without duplicating the owner's
        %% record definition or creating a second input-state interface.
        Row = fun() ->
            [Inputs] = [M || M <- tuple_to_list(sys:get_state(Pid)),
                            is_map(M),is_map_key(Human,M)],
            maps:get(Human,Inputs)
        end,
        Original = maps:with([control,sequence,input,expiry],Row()),
        {ok,Fresh,Renewed} = quod_physics:watch(Pid,Expected,Ref),
        ?assertEqual(Original,maps:with([control,sequence,input,expiry],Row())),
        ?assertNotEqual(Ref,Fresh),
        ?assertNotEqual(maps:get(registration,Initial),maps:get(registration,Renewed)),
        ?assertEqual({error,view_busy},quod_physics:watch(Pid,Expected,Ref)),
        ?assertEqual({error,view_busy},quod_physics:watch(Pid,Expected#{structure => 99},Fresh)),
        Parent = self(),
        Other = spawn(fun() -> Parent ! {foreign_watch,self(),quod_physics:watch(Pid,Expected,Fresh)} end),
        receive {foreign_watch,Other,Reply} -> ?assertEqual({error,view_busy},Reply)
        after 5000 -> error(foreign_watch_missing) end,
        %% Retired acknowledgements and detach messages have no authority over
        %% the replacement. Only its own acknowledgement releases credit.
        quod_physics:ack(Pid,Ref,maps:get(tick,Moving),maps:get(origin_sequence,Moving)),
        quod_physics:unwatch(Pid,Ref), _ = gen_server:call(Pid,status),
        receive {physics_frame,Pid,Fresh,_} -> error(uncredited_renewal_frame) after 0 -> ok end,
        ?assertEqual(Original,maps:with([control,sequence,input,expiry],Row())),
        quod_physics:ack(Pid,Fresh,maps:get(tick,Renewed),maps:get(origin_sequence,Renewed)),
        {Continued,_} = input_frame(Pid,Fresh,Human,7),
        {2,1,world,{X0,_,_},_,_} = lists:keyfind(2,1,maps:get(poses,Renewed)),
        {2,1,world,{X1,_,_},_,_} = lists:keyfind(2,1,maps:get(poses,Continued)),
        ?assert(X1 > X0),
        ?assertMatch({ok,_,{normalized,{failed,_}}},control_goal({'::',Ns,
            {physics_control_input,room,OldFrame,1,8,Input,{0}}})),
        {control_frame,Physical,_} = OldFrame,
        CurrentFrame = {control_frame,Physical,maps:get(registration,Renewed)},
        ?assertMatch({ok,_,{normalized,{failed,_}}},control_goal({'::',Ns,
            {physics_control_input,room,CurrentFrame,1,7,Input,{0}}})),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal({'::',Ns,
            {physics_control_input,room,CurrentFrame,1,8,{snap,785},{0}}})),
        _ = input_frame(Pid,Fresh,Human,8),
        assert_no_physics_io(fun() ->
            {ok,Final,_} = quod_physics:watch(Pid,Expected,Fresh),
            ?assertEqual(8,maps:get(sequence,Row())),
            quod_physics:unwatch(Pid,Final), _ = gen_server:call(Pid,status)
        end),
        ?assertEqual(0,maps:get(expiry,Row())),
        ?assertEqual(disconnected,maps:get(result,Row()))
    end,fun(Rules) -> [case R of
        {physics_body_definition,room,2,1,_,_,{owned,_,_}} ->
            {physics_body_definition,room,2,1,controlled,{vector,0,1002,0},{owned,{box,500,1000,500},1}};
        _ -> R end || R <- Rules] end) end}.

current_view_credit_and_revision_test_() ->
    {timeout, 60, fun() -> with_world(fun(F = #{namespace := Ns}) ->
        {Pid, World} = enable(F),
        #{World := #{spec := Spec}} = worlds(Ns),
        Expected = #{fence => quod_physics:fence(Spec), structure => 1,
                     incarnation => maps:get(run_token, Spec)},
        {ok, Ref, First} = quod_physics:watch(Pid, Expected,none),
        ?assertEqual({error, view_busy}, quod_physics:watch(Pid, Expected,none)),
        %% Processing the owner's sleeping notice proves many actual steps
        %% completed while the initial frame held the only delivery credit.
        receive {physics_status, _, Pid, World, _, sleeping} -> ok
        after 15000 -> error(world_never_slept) end,
        _ = gen_server:call(Pid, status),
        receive {physics_frame, Pid, Ref, _} -> error(uncredited_frame)
        after 0 -> ok end,
        quod_physics:ack(Pid, Ref, maps:get(tick, First),maps:get(origin_sequence,First)),
        Latest = receive {physics_frame, Pid, Ref, Frame} -> Frame
                 after 5000 -> error(no_latest_frame) end,
        ?assert(maps:get(tick, Latest) > maps:get(tick, First)),
        assert_no_physics_io(fun() ->
            quod_physics:ack(Pid, Ref, maps:get(tick, Latest),maps:get(origin_sequence,Latest)),
            _ = gen_server:call(Pid, status),
            receive {physics_frame, Pid, Ref, _} -> error(unchanged_frame)
            after 0 -> ok end
        end),
        commit(Ns, {',', {retract, {physics_structure, room, 1}},
                        {assertz, {physics_structure, room, 2}}}),
        receive {physics_refresh, Pid, Ref} -> ok
        after 5000 -> error(no_revision_invalidation) end,
        ?assertEqual({error, unavailable}, quod_physics:watch(Pid, Expected,none)),
        {Pid,World} = installed(Ns),
        {ok, Fresh, _} = quod_physics:watch(Pid, Expected#{structure => 2},none),
        quod_physics:unwatch(Pid, Fresh)
    end) end}.

ordinary_space_views_test_() ->
    [{binary_to_list(Ns),{timeout,60,fun() -> with_world(Ns,
      fun(F = #{namespace := N,node := Human,identity := Identity}) ->
        Parent = self(), Socket = spawn_link(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
        Session = simulation_session(Identity),
        Open = fun() -> Socket ! {client,simulation_open(F,Session,Human)} end,
        Selection = fun(Expected) ->
            Open(), ?assertEqual(Expected,maps:get(<<"selection">>,simulation_reply(Socket,<<"projection">>)))
        end,
        Change = fun(Goal) -> commit(N,Goal), _ = simulation_reply(Socket,<<"refresh">>) end,
        try
            Selection(<<"disabled">>),
            renew_simulation(Socket,Open,20),
            ?assertEqual(#{},worlds(N)),
            #{timer := Timer,installed := true} = simulation_state(Socket),
            Socket ! {timeout,Timer,expired}, _ = simulation_reply(Socket,<<"refresh">>),
            Selection(<<"disabled">>),
            Change({retract,{can_view_physics,room,{'_'}}}), Selection(<<"denied">>),
            Change({assertz,{can_view_physics,room,{'_'}}}), Selection(<<"disabled">>),
            {Pid,World} = enable(F), _ = simulation_reply(Socket,<<"refresh">>),
            Selection(<<"active">>),
            renew_simulation(Socket,Open,20),
            Runtime = quod_reg:where({quod_runtime,N}), Token = make_ref(),
            Retired = fun(State,{in,{physics_down,_,process,P,_}},_) when P =:= Pid ->
                              Parent ! {retired,Token}, State;
                         (State,_,_) -> State end,
            ok = sys:install(Runtime,{Retired,none}),
            try
                ok = sys:suspend(Pid),
                try
                    Change({',',{retract,{instance_of,physical_space,room}},
                                quod_ct:source_assertion({instance_of,space,room})}),
                    reconcile(N),
                    ?assertMatch(#{World := #{pid := Pid,stopping := true}},worlds(N))
                after sys:resume(Pid) end,
                receive {retired,Token} -> ok after 10000 -> error(world_not_retired) end,
                %% This snapshot joins the runtime's DOWN handler, not just process death.
                ?assertEqual(#{},worlds(N))
            after sys:remove(Runtime,Retired) end,
            ?assertMatch({ok,[#{}],_},quod_prolog:prove_ro(N,{agent_hosting_projection,all,Human,all,[]})),
            Selection(<<"nonphysical">>),
            renew_simulation(Socket,Open,20),
            Change({assertz,{physics_control,room,Human,1,{controlled,pilot,eye}}}),
            Selection(<<"unavailable">>),
            Change({retract,{physics_control,room,Human,1,{controlled,pilot,eye}}}),
            Selection(<<"nonphysical">>),
            Change({assertz,{world_view,room,playing,[{mark,<<"other">>,<<"group">>,[],
                {transform,0,0,0,0,0,0},no_surface,unlabelled,depicts_nothing}]}}), Selection(<<"unavailable">>),
            Socket ! {client,simulation_open(F#{space => absent},Session,Human)},
            ?assertMatch(#{<<"selection">> := <<"unavailable">>},simulation_reply(Socket,<<"projection">>))
        after Socket ! stop end
      end,fun(Rules) -> Rules ++ [{can_view_physics,room,{'_'}}] end)
    end}} || Ns <- [<<"ordinary-workshop">>,<<"ordinary-observatory">>]].

renew_simulation(Socket,Open,Count) ->
    Before = simulation_state(Socket),
    Retained = [heights,anchors,owners,follows,dependency_monitors,dependency_names,local_ready,monitor,pid],
    assert_no_physics_io(fun() ->
        lists:foreach(fun(_) ->
            Old = simulation_state(Socket),
            Open(), _ = simulation_reply(Socket,<<"projection">>),
            Current = simulation_state(Socket),
            ?assertEqual(maps:with(Retained,Before),maps:with(Retained,Current)),
            ?assertNotEqual(maps:get(timer,Old),maps:get(timer,Current)),
            ?assertNot(maps:is_key(candidate_timer,Current)),
            ?assertEqual(false,erlang:read_timer(maps:get(timer,Old))),
            case maps:find(ref,Old) of
                {ok,Ref} -> ?assertNotEqual(Ref,maps:get(ref,Current));
                error -> ?assertNot(maps:is_key(ref,Current))
            end,
            Socket ! {timeout,maps:get(timer,Old),expired},
            ?assertEqual(Current,simulation_state(Socket))
        end,lists:seq(1,Count))
    end).

navigation_dependencies_fence_view_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Human,identity := Identity}) ->
        Rendering = <<"physics-test-rendering">>, Anchor = quod_simplex:genesis_hash(Rendering),
        Height = quod_prolog:applied(Rendering), OriginHeight = quod_prolog:applied(element(2,Human)),
        Parent = self(), Socket = spawn_link(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
        Session = simulation_session(Identity),
        Open = fun(H) -> Socket ! {client,simulation_open(F#{dependencies =>
            [{dependency,Rendering,Anchor,H}]},Session,Human)} end,
        try
            Open(Height), _ = simulation_reply(Socket,<<"projection">>),
            commit(Rendering,{assertz,{navigation_policy,changed}}),
            _ = simulation_reply(Socket,<<"refresh">>),
            ?assertEqual(OriginHeight,quod_prolog:applied(element(2,Human))),
            Open(Height), ?assertMatch(#{<<"reason">> := <<"navigation_changed">>},simulation_reply(Socket,<<"refresh">>)),
            ?assertNot(maps:is_key(installed,simulation_state(Socket))),
            Open(quod_prolog:applied(Rendering)), _ = simulation_reply(Socket,<<"projection">>),
            Open(18446744073709551615),
            ?assertMatch(#{<<"reason">> := <<"navigation_changed">>},simulation_reply(Socket,<<"refresh">>)),
            Fenced = F#{dependencies => [{dependency,Rendering,<<99:256>>,0}]},
            Socket ! {client,simulation_open(Fenced,Session,Human)},
            ?assertMatch(#{<<"reason">> := <<"navigation_changed">>},simulation_reply(Socket,<<"refresh">>)),
            ?assertNot(maps:is_key(installed,simulation_state(Socket))),
            ?assertEqual(#{},worlds(Ns))
        after Socket ! stop end
    end,fun(Rules) -> Rules ++ [{can_view_physics,room,{'_'}},{world_view,room,playing,[]}] end) end}.

opening_worker_cancellation_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{node := Human,identity := Identity}) ->
        Parent = self(), Socket = spawn(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
        Session = simulation_session(Identity),
        true = quod_reg:reg({host_test,local_proof}),
        try
            Open = fun() ->
                Socket ! {client,simulation_open(F,Session,Human)},
                receive {local_proof_waiting,Proof} -> Proof after 5000 -> error(opening_proof_not_waiting) end
            end,
            Socket ! {client,simulation_open(F#{expires => 18446744073709551615},Session,Human)},
            ?assertMatch(#{<<"reason">> := <<"invalid_view_deadline">>},simulation_reply(Socket,<<"unavailable">>)),
            ?assertEqual(#{peer => {127,0,0,1}},simulation_state(Socket)),
            Proof = Open(), #{opening := {Ref,Worker,_},timer := Timer} = simulation_state(Socket),
            M = monitor(process,Worker), ProofMonitor = monitor(process,Proof),
            Socket ! {timeout,Timer,expired},
            ?assertMatch(#{<<"reason">> := <<"expired">>},simulation_reply(Socket,<<"unavailable">>)),
            receive {'DOWN',M,process,Worker,Reason} -> ?assertEqual(killed,Reason)
            after 5000 -> error({opening_not_cancelled,opening_cancellation_state(Worker,Proof,Socket)}) end,
            receive {'DOWN',ProofMonitor,process,Proof,_} -> ok
            after 5000 -> error({proof_not_cancelled,opening_cancellation_state(Worker,Proof,Socket)}) end,
            receive {simulation_opening_down,Socket,Worker} -> ok after 5000 -> error(socket_cleanup_missing) end,
            Socket ! {view_opened,Ref,retired_result},
            ?assertEqual(#{peer => {127,0,0,1}},simulation_state(Socket)),
            Open(), #{opening := {_,Fresh,_}} = simulation_state(Socket),
            Socket ! {client,simulation_open(F,Session,Human)},
            ?assertMatch(#{<<"reason">> := <<"dependency_recovering">>},simulation_reply(Socket,<<"unavailable">>)),
            _ = simulation_reply(Socket,<<"refresh">>),
            receive {simulation_opening_down,Socket,Fresh} -> ok after 5000 -> error(reopen_cleanup_missing) end,
            Open(), #{opening := {_,Last,_}} = simulation_state(Socket),
            LastMonitor = monitor(process,Last), exit(Socket,kill),
            receive {'DOWN',LastMonitor,process,Last,killed} -> ok
            after 5000 -> error(socket_did_not_reap_opening) end
        after gproc:unreg(quod_reg:name({host_test,local_proof})), exit(Socket,kill) end
    end,fun(Rules) -> Rules ++ [{can_view_physics,room,{'_'}},
        {':-',{world_view,room,playing,[]},test_physics_snapshot}] end) end}.

uncertain_renewal_attachment_closes_and_releases_test_() ->
    {timeout,30,fun() -> with_world(fun(F = #{namespace := Ns,node := Human,identity := Identity}) ->
        {Pid,World} = enable(F),
        Motion = {motion,free,2000,1600,1000,{query_limits,2,0,8,128},[]},
        {_,Expected,_,Ref,_} = install_test_control(F,Pid,World,Motion),
        quod_physics:unwatch(Pid,Ref), _ = gen_server:call(Pid,status),
        commit(Ns,{assertz,{can_view_physics,room,Human}}),
        reconcile(Ns),
        Parent = self(), Socket = spawn_link(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
        SocketMonitor = monitor(process,Socket), Session = simulation_session(Identity),
        Open = fun() -> Socket ! {client,simulation_open(F,Session,Human)} end,
        Open(), _ = simulation_reply(Socket,<<"projection">>),
        Gate = fun(armed,{in,{'$gen_call',_,{watch,_,_}}},_) ->
                Parent ! {attachment_waiting,self()},
                receive resume_attachment -> released end;
            (released,{in,{'DOWN',_,process,Who,_}},_) when Who =:= Socket ->
                Parent ! {attachment_owner_down,self()}, observed;
            (State,_,_) -> State
        end,
        ok = sys:install(Pid,{Gate,armed}),
        try
            Open(),
            receive {attachment_waiting,Pid} -> ok after 5000 -> error(attachment_not_requested) end,
            %% Let the real local call time out with an unknown result. The
            %% socket must close; a late native registration must not survive it.
            receive {simulation_closed,Socket,1011,_} -> ok
            after 10000 -> error(uncertain_attachment_did_not_close) end,
            receive {'DOWN',SocketMonitor,process,Socket,normal} -> ok
            after 5000 -> error(uncertain_socket_not_terminated) end,
            Pid ! resume_attachment,
            receive {attachment_owner_down,Pid} -> ok
            after 5000 -> error(late_registration_not_released) end,
            {ok,Fresh,_} = quod_physics:watch(Pid,Expected,none),
            quod_physics:unwatch(Pid,Fresh), _ = gen_server:call(Pid,status)
        after Pid ! resume_attachment, sys:remove(Pid,Gate), Socket ! stop end
    end) end}.

renewal_retains_certified_foreign_dependency_test_() ->
    {timeout,30,fun() ->
        Fixture = quod_foreign_log_tests:foreign_fixture(<<"renewed-remote-view">>),
        Ns = maps:get(ns,Fixture), Anchor = maps:get(anchor,Fixture), Identity = {Ns,Anchor},
        Dir = quod_foreign_log_tests:temp_dir("renewed-view"),
        Foreign = quod_foreign_log_tests:start_owner(Dir,
            quod_foreign_log_tests:chain_fetch(Ns,maps:get(chain,Fixture))),
        try
            ?assertMatch({ok,#{slot := 2}},quod_foreign_log:current(
                [{maps:get(pub,Fixture),[{"127.0.0.1",19000}]}],Identity,1000)),
            {ok,Follow} = quod_foreign_log:follow(Identity,progress),
            await_foreign_view(Follow,Identity),
            Monitor = monitor(process,Foreign),
            true = quod_reg:subscribe({physics,Ns}),
            Timer = erlang:start_timer(30000,self(),expired),
            State = #{kind => world,peer => {127,0,0,1},namespace => Ns,anchor => Anchor,instance => room,
                source => Ns,source_anchor => Anchor,expected_dependencies => [],
                installed => true,expires => quod_time:now_ms()+30000,timer => Timer,
                heights => #{},anchors => #{},owners => #{},local_ready => #{},dependency_names => #{},
                dependency_monitors => #{Monitor => Foreign},follows => #{Follow => {Ns,Anchor,2,true}},
                follow_requests => gen_server:reqids_new(),snapshots => gen_server:reqids_new()},
            {ok,Binding} = quod_wire_term:encode_bindings(#{<<"View">> =>
                {world_view,{entity_ref,Ns,Anchor,room},unnamed,[],nonphysical}},10000),
            %% Enter at the trusted signed-proof completion seam. The foreign
            %% reference, certified progress and lifetime are the real owner's;
            %% this isolates retention from signature/ACL admission tests.
            try assert_no_physics_io(fun() ->
                Final = lists:foldl(fun(I,S) ->
                    Expiry = quod_time:now_ms()+30000+I, Ref = make_ref(), M = make_ref(),
                    Candidate = erlang:start_timer(Expiry-quod_time:now_ms(),self(),expired),
                    Pending = S#{candidate_timer => Candidate,opening => {Ref,self(),M}},
                    Result = {ok,#{request_digest => crypto:strong_rand_bytes(32),request => #{not_after_ms => Expiry}},
                        {normalized,{read,[{Ns,Anchor,2}],{answers,2,[Binding]}}}},
                    {ok,Completed} = quod_client_view:websocket_info({view_opened,Ref,Result},Pending),
                    Before = quod_time:now_ms(),
                    {[{set_options,#{idle_timeout := Idle}},{text,Json}],Renewed} = quod_client_view:websocket_info(
                        {'DOWN',M,process,self(),normal},Completed),
                    ?assert(Idle > 0 andalso Idle =< Expiry-Before),
                    ?assert(Idle >= Expiry-quod_time:now_ms()),
                    ?assertMatch(#{<<"type">> := <<"projection">>,<<"selection">> := <<"nonphysical">>},json:decode(Json)),
                    ?assertEqual(maps:get(follows,State),maps:get(follows,Renewed)),
                    ?assertEqual(maps:get(dependency_monitors,State),maps:get(dependency_monitors,Renewed)),
                    ?assertEqual(false,erlang:read_timer(maps:get(timer,S))),
                    Renewed
                end,State,lists:seq(1,20)),
                ?assertMatch(#{follow_consumers := 1},quod_foreign_log:stats()),
                quod_client_view:terminate(normal,unused,Final),
                ?assertMatch(#{follow_consumers := 0},quod_foreign_log:stats())
            end)
            after catch quod_client_view:terminate(normal,unused,State) end
        after quod_foreign_log_tests:stop_owner(Foreign), file:del_dir_r(Dir) end
    end}.

await_foreign_view(Follow,Identity) ->
    receive {quod_foreign_follow,Follow,Notice,Identity,State} ->
        quod_foreign_log:ack(Follow,Notice),
        case State of
            {certified,2,_} -> ok;
            {building,_} -> await_foreign_view(Follow,Identity);
            _ -> error({unexpected_foreign_view_state,State})
        end
    after 3000 -> error(foreign_view_not_certified) end.

renewal_worker_cancellation_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Human,identity := Identity}) ->
        _ = enable(F),
        Session = simulation_session(Identity), Parent = self(),
        true = quod_reg:reg({host_test,local_proof}),
        try lists:foreach(fun(Reason) ->
            Socket = spawn_link(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
            Open = fun() ->
                Socket ! {client,simulation_open(F,Session,Human)},
                receive {local_proof_waiting,Proof} -> Proof
                after 5000 -> error(renewal_proof_missing) end
            end,
            try
                InitialProof = Open(), InitialProof ! release,
                _ = simulation_reply(Socket,<<"projection">>),
                Installed = simulation_state(Socket),
                Proof = Open(),
                Pending = #{opening := {Ref,Worker,_},timer := Old,candidate_timer := Candidate} = simulation_state(Socket),
                ?assertEqual(maps:with([pid,ref,monitor,timer,follows,dependency_monitors],Installed),
                             maps:with([pid,ref,monitor,timer,follows,dependency_monitors],Pending)),
                WorkerMonitor = monitor(process,Worker), ProofMonitor = monitor(process,Proof),
                {Type,ExpectedReason} = case Reason of
                    expired -> Socket ! {timeout,Old,expired}, {<<"refresh">>,<<"expired">>};
                    candidate_expired -> Socket ! {timeout,Candidate,expired}, {<<"unavailable">>,<<"expired">>};
                    proof_failed -> exit(Worker,kill), {<<"unavailable">>,<<"proof_unavailable">>};
                    revoked -> commit(Ns,{retract,{can_view_physics,room,{'_'}}}), {<<"refresh">>,<<"durable_gap">>}
                end,
                ?assertEqual(ExpectedReason,maps:get(<<"reason">>,simulation_reply(Socket,Type))),
                receive {'DOWN',WorkerMonitor,process,Worker,_} -> ok
                after 5000 -> error(renewal_worker_not_cancelled) end,
                receive {'DOWN',ProofMonitor,process,Proof,_} -> ok
                after 5000 -> error(renewal_proof_not_cancelled) end,
                receive {simulation_opening_down,Socket,Worker} -> ok
                after 5000 -> error(renewal_cleanup_missing) end,
                ?assertEqual(false,erlang:read_timer(Old)),
                ?assertEqual(false,erlang:read_timer(Candidate)),
                Socket ! {view_opened,Ref,retired_result},
                ?assertEqual(#{peer => {127,0,0,1}},simulation_state(Socket))
            after Socket ! stop end
        end,[expired,candidate_expired,proof_failed,revoked])
        after gproc:unreg(quod_reg:name({host_test,local_proof})) end
    end,fun(Rules) -> Rules ++ [{can_view_physics,room,{'_'}},
        {':-',{world_view,room,playing,[]},test_physics_snapshot}] end) end}.

opening_cancellation_state(Worker,Proof,Socket) ->
    Info = fun(Pid) -> #{pid => Pid,alive => is_process_alive(Pid),
        info => process_info(Pid,[status,current_function,current_stacktrace,message_queue_len,monitored_by])} end,
    #{worker => Info(Worker),proof => Info(Proof),socket => Info(Socket),
      mailbox => process_info(self(),messages),
      socket_state => try simulation_state(Socket) catch Class:Reason -> {Class,Reason} end}.

assert_view_selection(Selection,{ok,_,{normalized,{read,_,{answers,_,[Blob]}}}}) ->
    {ok,Pairs} = quod_client_result:decode_binding(Blob),
    ?assert(lists:any(fun({_,{world_view,_,_,_,S}}) -> S =:= Selection; (_) -> false end,Pairs)).

signed_mixed_view_uses_rendering_policy_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns}) ->
        _ = enable(F),
        Body = {mark,<<"body">>,<<"group">>,[],{body_pose,1,1},no_surface,unlabelled,
                {depicts,<<"source-instance">>,<<91:256>>,object}},
        Decoration = {mark,<<"decoration">>,<<"group">>,[],
                       {relative,<<"body">>,{transform,0,1000,0,0,0,0}},
                       no_surface,unlabelled,depicts_nothing},
        Read = fun(Marks) ->
            commit(Ns,{assertz,{world_view,room,playing,Marks}}),
            Result = body_read(Ns,{client_world_view,room,playing,[],{0}}),
            commit(Ns,{retract,{world_view,room,playing,Marks}}), Result
        end,
        ?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_]}}}},Read([Body,Decoration])),
        Twin = setelement(2,Body,<<"second-occurrence">>),
        ?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_]}}}},Read([Body,Twin,Decoration])),
        lists:foreach(fun(Marks) ->
            assert_view_selection(unavailable,Read(Marks))
        end,[[Decoration,Body], [Body,Body], [setelement(8,Body,depicts_nothing)],
             [setelement(5,Body,{body_pose,1,2})],
             [Body,setelement(5,Decoration,{relative,<<"body">>,{transform,0,0.5,0,0,0,0}})]])
    end,fun(Rules) -> Rules ++ [{can_view_physics,room,{'_'}}] end) end}.

registered_view_dependency_waits_for_replay_test_() ->
    {timeout,30,fun() -> with_world(fun(#{namespace := Ns}) ->
        %% Enter at the retained-view dependency seam, after proof admission.
        %% Hold the real consensus owner so a restarted engine registers while
        %% still unable to reconstruct its committed projection.
        Sup = quod_reg:where({quod_ns,Ns}),
        Simplex = quod_reg:where({quod_simplex,Ns}),
        Anchor = quod_simplex:genesis_hash(Ns), Height = quod_prolog:applied(Ns),
        [ok = supervisor:terminate_child(Sup,Child) ||
            Child <- [quod_runtime,quod_feed,quod_catchup,quod_prolog]],
        ?assertEqual(undefined,quod_reg:where({quod_prolog,Ns})),
        ok = sys:suspend(Simplex),
        Parent = self(),
        Socket = spawn_link(fun() ->
            true = quod_reg:subscribe({runtime,Ns}),
            Name = quod_reg:monitor_name({quod_prolog,Ns},follow),
            Timer = erlang:start_timer(10000,self(),expired),
            State = #{peer => {127,0,0,1},timer => Timer,
                pending => {<<0:256>>,quod_time:now_ms()+10000,fail},
                heights => #{Ns => Height},anchors => #{Ns => Anchor},owners => #{},
                local_ready => #{Ns => false},dependency_monitors => #{},
                dependency_names => #{Name => Ns},follows => #{},
                follow_requests => gen_server:reqids_new(),snapshots => gen_server:reqids_new()},
            Parent ! {dependency_following,self()},
            simulation_socket(Parent,State)
        end),
        Monitor = monitor(process,Socket),
        try
            receive {dependency_following,Socket} -> ok
            after 1000 -> error(dependency_follow_not_installed) end,
            {ok,Engine} = supervisor:restart_child(Sup,quod_prolog),
            Paused = simulation_reply(Socket,<<"unavailable">>),
            ?assertEqual(<<"dependency_recovering">>,maps:get(<<"reason">>,Paused)),
            State = simulation_state(Socket),
            ?assertEqual(#{Engine => Ns},maps:get(owners,State)),
            ?assertEqual(#{Ns => {recovering,{Engine,boot}}},maps:get(local_ready,State)),
            ?assertEqual(#{},maps:get(dependency_names,State)),
            ?assertNot(maps:is_key(pid,State)),
            ok = sys:resume(Simplex),
            %% Boot readiness becomes the exact replay run before ready. Both
            %% notifications come from the actual engine, not the test.
            Replaying = simulation_reply(Socket,<<"unavailable">>),
            ?assertEqual(<<"dependency_recovering">>,maps:get(<<"reason">>,Replaying)),
            _ = simulation_reply(Socket,<<"refresh">>),
            ?assertEqual(#{peer => {127,0,0,1}},simulation_state(Socket)),
            ?assertEqual(Anchor,quod_simplex:genesis_hash(Ns)),
            ?assert(quod_prolog:applied(Ns) >= Height)
        after
            _ = catch sys:resume(Simplex),
            Socket ! stop,
            receive {'DOWN',Monitor,process,Socket,_} -> ok
            after 1000 -> error(dependency_socket_not_stopped) end
        end
    end) end}.

signed_client_view_lifecycle_test_() ->
    {timeout, 90, fun() -> with_door(fun(F = #{namespace := Ns, identity := Identity}) ->
        commit(Ns,{'$quod_retract_exact',default_world_view_rule()}),
        {Pid, World} = enable(F),
        Pub = maps:get(pubkey, Identity),
        commit(Ns, {assertz, {agent_key, viewer, Pub, active}}),
        reconcile(Ns),
        Parent = self(),
        Socket = spawn_link(fun() -> simulation_socket(Parent, #{peer => {127,0,0,1}}) end),
        try
            Session = simulation_session(Identity),
            Open = fun() ->
                Expiry = quod_time:now_ms()+300000,
                Before = quod_time:now_ms(),
                Socket ! {client, simulation_open(F#{expires => Expiry}, Session)},
                {Before,Expiry}
            end,
            {Opened,Expiry} = Open(),
            receive {simulation_transport_timeout,Socket,Idle} ->
                ?assert(Idle > 60000),
                ?assert(Idle =< Expiry-Opened),
                ?assert(Idle >= Expiry-quod_time:now_ms())
            after 10000 -> error(missing_transport_deadline) end,
            First = simulation_reply(Socket, <<"projection">>),
            FirstFrame = maps:get(<<"frame">>, First),
            ?assertEqual(1, length(maps:get(<<"poses">>, FirstFrame))),
            ?assertEqual(<<"10">>, maps:get(<<"body">>, hd(maps:get(<<"poses">>, FirstFrame)))),
            {ok, #{goal := ParsedMarks}} = quod_client_goal_parser:parse(
                <<(maps:get(<<"marks">>, First))/binary, ".">>, 3),
            {ok, ProjectedMarks} = quod_wire_term:materialize_symbols(ParsedMarks),
            ?assertMatch([{mark,<<"frame">>,_,_,{transform,5000,2000,3000,0,90,0},_,_,depicts_nothing},
                          {mark,<<"door">>,_,_,{relative,<<"frame">>,{body_pose,10,_}},_,_,
                           {depicts,<<"foreign-subject">>,<<99:256>>,door}},
                          {mark,<<"decoration">>,_,_,{relative,<<"door">>,_},_,_,depicts_nothing}], ProjectedMarks),
            %% The shared rendering policy is a real third proof dependency.
            %% Denial retains its subscription, so a grant wakes the same view.
            Rendering = <<"physics-test-rendering">>,
            #{heights := ViewHeights} = simulation_state(Socket),
            ?assertEqual(quod_prolog:applied(Rendering),maps:get(Rendering,ViewHeights)),
            ScenePolicy = well_formed_scene_rule(),
            commit(Rendering,{'$quod_retract_exact',ScenePolicy}),
            _ = simulation_reply(Socket,<<"refresh">>),
            Open(), ?assertMatch(#{<<"selection">> := <<"unavailable">>},simulation_reply(Socket,<<"projection">>)),
            ?assertNot(maps:is_key(pid,simulation_state(Socket))),
            commit(Rendering,{assertz,ScenePolicy}),
            _ = simulation_reply(Socket,<<"refresh">>),
            Open(), _ = simulation_reply(Socket,<<"projection">>),
            %% Hold the real engine's snapshot reply. The socket must still
            %% process expiry and cancel its request without re-proving.
            RenderingEngine = quod_reg:where({quod_prolog,Rendering}),
            SnapshotGate = fun(armed,{in,{'$gen_call',_,get_stats}},_) ->
                Parent ! {snapshot_waiting,self()},
                receive release_snapshot -> released end;
                (State,_,_) -> State
            end,
            ok = sys:install(RenderingEngine,{SnapshotGate,armed}),
            try
                Open(),
                receive {snapshot_waiting,RenderingEngine} -> ok
                after 5000 -> error(snapshot_not_requested) end,
                #{timer := SnapshotTimer,snapshots := Requests} = simulation_state(Socket),
                ?assert(gen_server:reqids_size(Requests) > 0),
                ?assertEqual(Pid,maps:get(pid,simulation_state(Socket))),
                ?assert(maps:is_key(candidate_timer,simulation_state(Socket))),
                Socket ! {timeout,SnapshotTimer,expired},
                ?assertEqual(<<"expired">>,maps:get(<<"reason">>,
                    simulation_reply(Socket,<<"refresh">>))),
                ?assertEqual(#{peer => {127,0,0,1}},simulation_state(Socket))
            after
                RenderingEngine ! release_snapshot,
                sys:remove(RenderingEngine,SnapshotGate)
            end,
            Open(), _ = simulation_reply(Socket,<<"projection">>),
            %% Appearance is a durable view change, never a physical reset.
            Before = gen_server:call(Pid, status),
            commit(Ns, {',', {retract, {view_colour, <<"#FFFFFF">>}},
                            {assertz, {view_colour, <<"#123456">>}}}),
            _ = simulation_reply(Socket, <<"refresh">>),
            Open(),
            Fresh = simulation_reply(Socket, <<"projection">>),
            ?assertNotEqual(maps:get(<<"view">>, First), maps:get(<<"view">>, Fresh)),
            ?assertEqual(maps:get(incarnation, Before), maps:get(incarnation, gen_server:call(Pid, status))),
            ?assertEqual(maps:get(installs, Before), maps:get(installs, gen_server:call(Pid, status))),
            %% Timer delivery is synchronized with the actual attached state;
            %% old timer references cannot invalidate a replacement projection.
            #{timer := AttachedTimer} = simulation_state(Socket),
            Socket ! {timeout, AttachedTimer, expired},
            _ = simulation_reply(Socket, <<"refresh">>),
            Open(), _ = simulation_reply(Socket, <<"projection">>),
            Socket ! {timeout, AttachedTimer, expired},
            ?assert(maps:is_key(pid, simulation_state(Socket))),
            %% Hold installation at its real lifecycle owner while the signed
            %% read observes a newer committed structure. No sleeps or polling.
            Runtime = quod_reg:where({quod_runtime, Ns}),
            ok = sys:suspend(Runtime),
            try
                commit(Ns, {',', {retract, {physics_structure,room,2}},
                                {assertz, {physics_structure,room,3}}}),
                _ = simulation_reply(Socket, <<"refresh">>),
                Open(),
                ?assertEqual(<<"waiting_for_installation">>,
                    maps:get(<<"reason">>, simulation_reply(Socket, <<"unavailable">>))),
                #{timer := WaitingTimer} = simulation_state(Socket),
                Socket ! {timeout, WaitingTimer, expired},
                ?assertEqual(<<"expired">>,
                    maps:get(<<"reason">>, simulation_reply(Socket, <<"unavailable">>))),
                ?assertEqual(#{peer => {127,0,0,1}}, simulation_state(Socket))
            after sys:resume(Runtime) end,
            {Pid, World} = installed(Ns),
            Open(), _ = simulation_reply(Socket, <<"projection">>),
            %% The existing signed close moves the real hinge. Its durable
            %% intent invalidates the view before accepting more current poses.
            true = quod_reg:subscribe({runtime, Ns}),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Ns, {physics_close_hinged,room,10,0,<<81:256>>})),
            _ = simulation_reply(Socket, <<"refresh">>),
            await_door(Ns, {close,1,<<81:256>>}, closed),
            reconcile(Ns),
            Open(),
            Closed = simulation_reply(Socket, <<"projection">>),
            ?assertNotEqual(maps:get(<<"poses">>, FirstFrame),
                            maps:get(<<"poses">>, maps:get(<<"frame">>, Closed))),
            %% Owner death invalidates this subscription; the new run cannot
            %% reuse its token or accept its outstanding acknowledgement.
            exit(Pid, kill),
            _ = simulation_reply(Socket, <<"refresh">>),
            {Next, World} = installed(Ns),
            ?assertNotEqual(Pid, Next),
            Open(),
            Restored = simulation_reply(Socket, <<"projection">>),
            ?assertNotEqual(maps:get(<<"incarnation">>, FirstFrame),
                            maps:get(<<"incarnation">>, maps:get(<<"frame">>, Restored))),
            %% Revocation must go back through ordinary signed proof policy.
            commit(Ns, {retract, {can_view_physics, room, {'_'}}}),
            _ = simulation_reply(Socket, <<"refresh">>),
            Open(),
            ?assertEqual(<<"denied">>,
                         maps:get(<<"selection">>, simulation_reply(Socket, <<"projection">>))),
            commit(Ns, {assertz, {can_view_physics,room,{'_'}}}),
            _ = simulation_reply(Socket, <<"refresh">>),
            commit(Ns, {',', {retract, {physics_allowances,room,{limits,64,64,256,1000000,{geometry,256,4096,4096}},16667,-9810,10000}},
                            {assertz, {physics_allowances,room,{limits,1,1,256,1000000,{geometry,256,4096,4096}},16667,-9810,10000}}}),
            receive {physics_status,_,_,World,_,{failed,body_allowance}} -> ok
            after 15000 -> error(no_failed_installation) end,
            Open(),
            ?assertEqual(<<"simulation_failed">>,
                maps:get(<<"reason">>, simulation_reply(Socket, <<"unavailable">>)))
        after Socket ! stop end
    end, false, fun(Rules) ->
        Ns = <<"host-test-agent">>,
        Marks = [{mark, <<"frame">>, <<"group">>, [],
                  {transform,5000,2000,3000,0,90,0},no_surface,unlabelled,depicts_nothing},
                 {mark, <<"door">>, <<"box">>,
                  [{f,<<"width">>,2000},{f,<<"height">>,2000},{f,<<"depth">>,200}],
                  {relative,<<"frame">>,{body_pose,10,{'R'}}}, {surface,{'Colour'},0,900,0,[]}, unlabelled,
                  {depicts,<<"foreign-subject">>,<<99:256>>,door}},
                 {mark,<<"decoration">>,<<"group">>,[],
                  {relative,<<"door">>,{transform,1000,0,0,0,0,45}},no_surface,unlabelled,depicts_nothing}],
        Rules ++ [{can_invoke,{',',{current_ontology_identity,Ns,{'_'}},{client_world_view,room,playing,{'_'},{'_'}}},
                    {agent_instance_ref,Ns,{'_'},viewer},{'_'},Ns},
                  {can_view_physics,room,{'_'}}, {view_colour,<<"#FFFFFF">>},
                  {':-', {world_view,room,playing,Marks},
                    {',', {current_ontology_identity,Ns,{'Anchor'}},
                      {',', {view_colour,{'Colour'}},
                            {physics_body_definition, room, 10, {'R'}, {'_'}, {'_'}, {owned, {'_'}, {'_'}}}}}}]
    end) end}.

simulation_session(Identity = #{pubkey := Pub}) ->
    Nonce = crypto:strong_rand_bytes(32),
    {ok, C} = quod_client_auth:issue_challenge(Pub, Nonce, {127,0,0,1}),
    Id = maps:get(challenge_id, C),
    {ok, Bytes} = quod_client_auth:challenge_bytes(<<42:256>>, Pub, Id, Pub, Nonce,
        maps:get(server_nonce, C), maps:get(expires_ms, C)),
    {ok, #{session_id := Session}} = quod_client_auth:complete_challenge(Id, quod_identity:sign(Bytes, Identity)),
    Session.

simulation_open(F = #{namespace := Ns, reference := {agent_instance_ref,_,Anchor,_}}, Session) ->
    simulation_open(F#{reference := {agent_instance_ref,Ns,Anchor,viewer}},
                    Session,{agent_instance_ref,Ns,Anchor,viewer}).
simulation_open(F = #{namespace := Ns, reference := {agent_instance_ref,_,Anchor,_}, identity := Identity}, Session,
                {agent_instance_ref,Source,SourceAnchor,Instance}) ->
    %% Render a named View binding with the same anchored goal as the client.
    Goal = iolist_to_binary([quod_client_goal_parser:value_text(Ns)," :: (current_ontology_identity(",
        quod_client_goal_parser:value_text(Ns),",",quod_client_goal_parser:value_text(Anchor),"), client_world_view(",
        quod_client_goal_parser:value_text(maps:get(space,F,room)),",playing,",
        quod_client_goal_parser:value_text(maps:get(dependencies,F,[])),",View))."]),
    {ok,InstanceText} = quod_client_goal_parser:format(Instance),
    Request = #{network_identity => <<42:256>>, agent_namespace => Source,
        agent_genesis_anchor => SourceAnchor, agent_instance_text => InstanceText,
        signing_public_key => maps:get(pubkey, Identity), operation_id => crypto:strong_rand_bytes(32),
        not_after_ms => maps:get(expires,F,quod_time:now_ms()+30000), mode => read, parser_version => 3,
        goal_text => Goal},
    {ok, Bytes} = quod_client_goal:encode(Request),
    Enc = fun(B) -> base64:encode(B, #{mode => urlsafe, padding => false}) end,
    iolist_to_binary(json:encode(#{type => open, view_kind => world, session_id => Enc(Session), request => Enc(Bytes),
        view_namespace => Ns,view_anchor => Enc(Anchor),
        signature => Enc(quod_identity:sign(Bytes, Identity))})).

simulation_reply(Socket, Type) ->
    receive
        {simulation, Socket, #{<<"type">> := Type} = Message} -> Message;
        {simulation, Socket, Message} -> error({unexpected_simulation_reply, Type, Message})
    after 10000 -> error({missing_simulation_reply, Type}) end.

simulation_socket(Parent, S) ->
    receive
        stop -> quod_client_view:terminate(normal, unused, S);
        {inspect, Ref} -> Parent ! {simulation_state, Ref, S}, simulation_socket(Parent, S);
        Message ->
            Result = case Message of
                {client, Bytes} -> quod_client_view:websocket_handle({text, Bytes}, S);
                _ -> quod_client_view:websocket_info(Message, S)
            end,
            Next = case Result of
                {[{set_options,#{idle_timeout := Idle}},{text,Json}], State} ->
                    Parent ! {simulation_transport_timeout,self(),Idle},
                    Parent ! {simulation,self(),json:decode(Json)}, State;
                {ok, State} -> State;
                {reply, {text, Json}, State} -> Parent ! {simulation, self(), json:decode(Json)}, State;
                {reply,{close,Code,Reason},State} ->
                    Parent ! {simulation_closed,self(),Code,Reason},
                    quod_client_view:terminate(normal,unused,State), closed;
                Other -> error({invalid_socket_result, Other})
            end,
            case {Message,S} of
                {{'DOWN',M,process,P,_},#{opening := {_,P,M}}} -> Parent ! {simulation_opening_down,self(),P};
                _ -> ok
            end,
            case Next of closed -> ok; _ -> simulation_socket(Parent,Next) end
    end.

simulation_state(Socket) ->
    Ref = make_ref(), Socket ! {inspect, Ref},
    receive {simulation_state, Ref, State} -> State
    after 5000 -> error(socket_state_unavailable) end.

voxel_runtime_retains_chunks_and_applies_committed_dig_test_() ->
    {timeout,90,fun() -> with_voxel_world(fun(F = #{namespace := Ns}) ->
        Field = {field_v1,1,500,[{plane,1000}],9},
        Created = door_action(Ns,{voxel_create,room,0,{terrain_v1,unbounded,smooth,Field}}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Created),
        await_source_receipt(Created),
        {Pid,World} = enable(F), reconcile(Ns),
        #{World := #{spec := Before}} = worlds(Ns),
        Artifacts = maps:get(voxel_resources,Before),
        ?assertEqual(3,map_size(Artifacts)),
        {Body,_} = hd(maps:keys(Artifacts)),
        ?assertMatch({Body,2,fixed,_,{terrain,500,[_,_,_]},_},
                     lists:keyfind(Body,1,maps:get(bodies,Before))),
        %% Observe the real worker/owner seam, including numerical calls and
        %% persistence: retaining a helper's result alone is insufficient.
        assert_no_physics_io(fun() -> [reconcile(Ns) || _ <- lists:seq(1,5)] end),
        Brush = {dig_sphere,{vector,4000,1000,2000},600},
        Dig = door_action(Ns,{',',{voxel_edit_basis,room,Brush,{'R'},{'Cs'}},
                                  {voxel_edit,room,{'R'},{'Cs'},Brush}}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Dig),
        await_source_receipt(Dig),
        {Pid,World} = installed_structure(Ns,3), reconcile(Ns),
        #{World := #{spec := After}} = worlds(Ns),
        NewArtifacts = maps:get(voxel_resources,After),
        ?assertEqual(maps:get(run_token,Before),maps:get(run_token,After)),
        lists:foreach(fun(C) ->
            ?assertNotEqual(maps:get(input_digest,maps:get({Body,C},Artifacts)),
                            maps:get(input_digest,maps:get({Body,C},NewArtifacts)))
        end,[{chunk_v1,0,0,0},{chunk_v1,1,0,0}]),
        ?assertEqual(maps:get({Body,{chunk_v1,3,0,0}},Artifacts),
                     maps:get({Body,{chunk_v1,3,0,0}},NewArtifacts)),
        assert_no_physics_io(fun() -> [reconcile(Ns) || _ <- lists:seq(1,5)] end),
        %% A retained window must also fit the current aggregate installation
        %% budget. Refusal reports the actual resource and preserves the owner.
        Allowance = {physics_allowances,room,
            {limits,64,64,256,1000000,{geometry,256,4096,4096}},16667,-9810,10000},
        TooSmall = setelement(3,Allowance,{limits,64,64,256,1000000,{geometry,256,0,4096}}),
        commit(Ns,{',',{retract,Allowance},{assertz,TooSmall}}),
        ?assertMatch({error,{physics_materialization,[{World,{geometry_allowance,{vertices,_,0}}}]}},
            quod_runtime:reconcile_resource(Ns,quod_prolog:applied(Ns),physics_worlds,
                                            all,quod_time:mono_ms()+10000)),
        ?assertMatch(#{World := #{pid := Pid,spec := #{voxel_resources := NewArtifacts}}},worlds(Ns)),
        ?assertMatch(#{navigation_ready := false},gen_server:call(Pid,status)),
        commit(Ns,{',',{retract,TooSmall},{assertz,Allowance}}),
        {Pid,World} = installed_structure(Ns,3),
        #{World := #{spec := Resumed}} = worlds(Ns),
        ?assertEqual(maps:get(run_token,Before),maps:get(run_token,Resumed)),
        ?assertEqual(NewArtifacts,maps:get(voxel_resources,Resumed)),
        %% Leave the edited region, actually reclaim its artifacts, then visit
        %% it again. The current patches, not a retained mesh, restore the dig.
        Definition = {owned,{ball,250},1}, Far = {vector,18000,2000,2000},
        Near = {vector,2000,2000,2000},
        commit(Ns,{',',{physics_advance_structure,room,{'R'}},
            {assertz,{physics_body_definition,room,7,{'R'},controlled,Far,Definition}}}),
        {Pid,World} = installed_structure(Ns,4),
        await_voxel_chunks(Pid,World,[{Body,{chunk_v1,4,0,0}}],quod_time:mono_ms()+10000),
        commit(Ns,{physics_replace_body,room,7,4,controlled,Far,Definition,Near,Definition,
                   {geometry,{ball,250},1}}),
        {Pid,World} = installed_structure(Ns,5),
        Key = {Body,{chunk_v1,0,0,0}},
        await_voxel_chunks(Pid,World,[Key],quod_time:mono_ms()+10000),
        #{World := #{spec := #{voxel_resources := Revisited}}} = worlds(Ns),
        EditedDigest = maps:get(output_digest,maps:get(Key,NewArtifacts)),
        ?assertEqual(EditedDigest,maps:get(output_digest,maps:get(Key,Revisited))),
        assert_no_physics_io(fun() -> reconcile(Ns),reconcile(Ns) end),
        Runtime = quod_reg:where({quod_runtime,Ns}),
        Monitor = monitor(process,Pid),exit(Runtime,kill),
        receive {'DOWN',Monitor,process,Pid,_} -> ok after 5000 -> error(runtime_kept_old_physics) end,
        {Recovered,World} = installed(Ns),
        ?assertNotEqual(Pid,Recovered),
        await_voxel_chunks(Recovered,World,[Key],quod_time:mono_ms()+10000),
        #{World := #{spec := RecoveredSpec}} = worlds(Ns),
        ?assertEqual(maps:get(generation,Resumed)+1,maps:get(generation,RecoveredSpec)),
        ?assertEqual(EditedDigest,maps:get(output_digest,maps:get(Key,maps:get(voxel_resources,RecoveredSpec))))
    end) end}.

voxel_missing_coverage_wakes_existing_resource_worker_test_() ->
    {timeout,90,fun() -> with_voxel_world(fun(F = #{namespace := Ns}) ->
        Field = {field_v1,1,500,[{plane,1000}],9},
        Created = door_action(Ns,{voxel_create,room,0,{terrain_v1,unbounded,smooth,Field}}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Created),
        await_source_receipt(Created),
        commit(Ns,{assertz,{physics_body_definition,room,7,2,controlled,
                            {vector,18000,2000,2000},{owned,{ball,250},1}}}),
        commit(Ns,{assertz,{physics_body_definition,room,8,2,controlled,
                            {vector,26000,2000,2000},{owned,{ball,250},1}}}),
        {Pid,World} = enable(F), reconcile(Ns),
        #{World := #{spec := Spec,terrain_demand := {Pid,Token,2,Ranges,Focus}}} = worlds(Ns),
        ?assertEqual(maps:get(run_token,Spec),Token),
        Artifacts = maps:get(voxel_resources,Spec),
        %% Startup coverage is not a permanent pin. Both live bodies retain
        %% their regions while the unused initial chunks are reclaimed.
        ?assertEqual(2,map_size(Artifacts)),
        RequiredKeys = [K || K = {_,{chunk_v1,X,0,0}} <- maps:keys(Artifacts),X =:= 4 orelse X =:= 6],
        ?assertEqual(2,length(RequiredKeys)),
        Height = quod_prolog:applied(Ns),
        Runtime = quod_reg:where({quod_runtime,Ns}),
        assert_no_physics_io(fun() ->
            Runtime ! {physics_terrain_demand,Pid,World,Token,2,Ranges,Focus},
            Runtime ! {physics_terrain_demand,self(),World,Token,2,[],#{}},
            [reconcile(Ns) || _ <- lists:seq(1,5)]
        end),
        ?assertEqual(Height,quod_prolog:applied(Ns)),
        ?assertMatch(#{phase := active,incarnation := Token,navigation_ready := true},gen_server:call(Pid,status)),
        ?assertMatch({ok,[#{'Rows' := []}],_},quod_prolog:prove_ro(Ns,
            {findall,{'P'},{voxel_chunk_override,room,{'_'},{'_'},{'P'}},{'Rows'}})),
        Brush = {dig_sphere,{vector,4000,1000,2000},600},
        Dig = door_action(Ns,{',',{voxel_edit_basis,room,Brush,{'R'},{'Cs'}},
                                  {voxel_edit,room,{'R'},{'Cs'},Brush}}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Dig), await_source_receipt(Dig),
        {Pid,World} = installed_structure(Ns,3), reconcile(Ns),
        #{World := #{spec := #{voxel_resources := Updated}}} = worlds(Ns),
        ?assertEqual(maps:with(RequiredKeys,Artifacts),maps:with(RequiredKeys,Updated)),
        commit(Ns,{',',{retract,{physics_body_definition,room,7,2,controlled,
            {vector,18000,2000,2000},{owned,{ball,250},1}}},
            {',',{retract,{physics_body_definition,room,8,2,controlled,
                {vector,26000,2000,2000},{owned,{ball,250},1}}},
                {physics_advance_structure,room,{'_'}}}}),
        {Pid,World} = installed_structure(Ns,4), reconcile(Ns),
        await_voxel_chunks(Pid,World,[],quod_time:mono_ms()+5000),
        #{World := #{spec := #{voxel_resources := Empty}}} = worlds(Ns),
        ?assertEqual(0,map_size(Empty)),
        assert_no_physics_io(fun() -> reconcile(Ns),reconcile(Ns) end)
    end) end}.

view_renewal_does_not_add_head_collision_terrain_test_() ->
    {timeout,90,fun() -> with_voxel_world(fun(F = #{namespace := Ns}) ->
        Created = door_action(Ns,{voxel_create,room,0,
            {terrain_v1,unbounded,smooth,{field_v1,1,500,[{plane,1000}],9}}}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Created),await_source_receipt(Created),
        commit(Ns,{assertz,{physics_body_definition,room,7,2,controlled,
                            {vector,3700,2000,2000},{owned,{ball,100},1}}}),
        {Pid,World} = enable(F),
        #{World := #{spec := #{voxel_resources := Resources}}} = worlds(Ns),
        [Terrain] = lists:usort([Id || {Id,_} <- maps:keys(Resources)]),
        Support = {Terrain,{chunk_v1,0,0,0}},
        {_,Expected,_,First,Initial} = install_test_control(F,Pid,World,
            {motion,free,2000,1600,1000,{query_limits,2,0,8,128},[reposition]},7),
        ?assertNot(maps:is_key(view_clearance,Initial)),
        await_voxel_chunks(Pid,World,[Support],quod_time:mono_ms()+10000),
        Renewals = make_ref(),
        assert_no_physics_io(fun() ->
            Last = lists:foldl(fun(_,Previous) ->
                {ok,Next,Frame} = quod_physics:watch(Pid,Expected,Previous),
                ?assertNot(maps:is_key(view_clearance,Frame)),Next
            end,First,lists:seq(1,3)),
            reconcile(Ns),self() ! {Renewals,Last},ok
        end),
        #{World := #{spec := #{voxel_resources := After}}} = worlds(Ns),
        ?assertEqual([Support],lists:sort(maps:keys(After))),
        receive {Renewals,Last} -> quod_physics:unwatch(Pid,Last) end,
        await_voxel_chunks(Pid,World,[Support],quod_time:mono_ms()+10000)
    end) end}.

voxel_query_gap_preserves_registered_input_and_its_expiry_test_() ->
    [{atom_to_list(Outcome),{timeout,90,fun() -> with_voxel_world(fun(F = #{namespace := Ns,node := Human}) ->
        Field = {field_v1,1,500,[{plane,1000}],9},
        Created = door_action(Ns,{voxel_create,room,0,{terrain_v1,unbounded,smooth,Field}}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Created), await_source_receipt(Created),
        commit(Ns,{assertz,{physics_body_definition,room,7,2,controlled,
                            {vector,2000,2000,2000},{owned,{ball,250},1}}}),
        {Pid,World} = enable(F), Limits = {query_limits,2,0,8,128},
        {_,Expected,_,Ref,Initial} = install_test_control(F,Pid,World,
            {motion,free,2000,1600,1000,Limits,[reposition]},7),
        quod_physics:ack(Pid,Ref,maps:get(tick,Initial),maps:get(origin_sequence,Initial)),
        Installed = Expected#{registration => maps:get(registration,Initial)},
        Control = maps:get(control,Expected), Runtime = quod_reg:where({quod_runtime,Ns}),
        Parent = self(), Tag = make_ref(),
        Seen = fun(State,{in,{timeout,_,step}},_) -> Parent ! {terrain_input_step,Tag},State;
                  (State,_,_) -> State end,
        Row = fun() ->
            [Inputs] = [M || M <- tuple_to_list(sys:get_state(Pid)),is_map(M),is_map_key(Human,M)],
            maps:get(Human,Inputs)
        end,
        Expiry = quod_time:now_ms()+case Outcome of expired -> 1000; _ -> 10000 end,
        ok = sys:install(Pid,{Seen,none}), ok = sys:suspend(Runtime),
        try
            ok = quod_physics:input(Pid,Installed,Control,1,
                {{reposition,{vector,18000,2000,2000}},Limits},Expiry,quod_time:mono_ms()+10000),
            receive {terrain_input_step,Tag} -> ok after 5000 -> error(input_step_missing) end,
            ?assertMatch(#{phase := coverage,navigation_ready := false},gen_server:call(Pid,status)),
            ?assertMatch(#{sequence := 1,pending := true,expiry := Expiry},Row()),
            case Outcome of
                applied -> ok;
                disconnected ->
                    quod_physics:unwatch(Pid,Ref),
                    _ = gen_server:call(Pid,status);
                source_changed ->
                    commit(Ns,{',',{retract,{physics_structure,room,2}},
                                   {assertz,{physics_structure,room,3}}});
                expired ->
                    Timer = erlang:start_timer(max(0,Expiry-quod_time:now_ms()+1),self(),input_expired),
                    receive {timeout,Timer,input_expired} -> ok end
            end,
            ok = sys:resume(Runtime),
            case Outcome of
                Removed when Removed =:= disconnected; Removed =:= source_changed ->
                    reconcile(Ns),
                    case gen_server:call(Pid,status) of
                        #{phase := active,navigation_ready := true} -> ok;
                        _ -> ?assertEqual({Pid,World},installed(Ns))
                    end,
                    ?assertMatch(#{phase := active,navigation_ready := true},gen_server:call(Pid,status)),
                    ?assertMatch(#{pending := false},Row()),
                    ?assertNot(maps:is_key(terrain,Row())),
                    CurrentExpected = case Outcome of source_changed -> Expected#{structure => 3}; _ -> Expected end,
                    ?assertMatch({ok,_,_,{7,2,world,{2.0,2.0,2.0},_,_}},
                        quod_physics:body_state(Pid,CurrentExpected,{7,2},1000)),
                    ?assertMatch({ok,_,_},quod_physics:watch(Pid,CurrentExpected,none));
                _ ->
                    {Frame,Result} = input_frame(Pid,Ref,Human,1),
                    Position = case Outcome of
                        applied -> ?assertMatch({clear,_,_},Result),{18.0,2.0,2.0};
                        expired -> ?assertEqual(expired,Result),{2.0,2.0,2.0}
                    end,
                    ?assertMatch({7,2,world,Position,_,_},lists:keyfind(7,1,maps:get(poses,Frame))),
                    ?assertMatch(#{sequence := 1,pending := false,expiry := Expiry},Row()),
                    ?assertNot(maps:is_key(terrain,Row())),
                    ?assertEqual(maps:get(registration,Initial),maps:get(registration,Frame))
            end
        after catch sys:resume(Runtime),sys:remove(Pid,Seen) end
    end) end}} || Outcome <- [applied,expired,disconnected,source_changed]].

with_voxel_world(Fun) -> with_voxel_world(Fun,[]).
with_voxel_world(Fun,Extra) ->
    with_world(Fun,fun(Rules) ->
        [R || R <- Rules,element(1,R) =/= physics_body_definition] ++
        quod_prolog:read_terms("priv/ontologies/voxel_world.pl") ++ Extra ++
        [{can_create_voxel_world,room,{'_'}},{can_edit_voxel_world,room,{'_'},{'_'}},
         {voxel_allowances,room,{voxel_limits,{sampling_limits,1331,10648,85184,3993},
              {surface_limits,512,10000,10000},64,69120,1048576}},
         {voxel_initial_chunks,room,{'_'},[{chunk_v1,0,0,0},{chunk_v1,1,0,0},{chunk_v1,3,0,0}]}]
    end).

with_world(Fun) -> with_world(Fun, fun(Rules) -> Rules end).
with_world(Fun, Transform) ->
    with_world(<<"host-test-agent">>, Fun, Transform).
with_world(Ns, Fun, Transform) ->
    Rules = world_rules(Ns),
    WithRendering = fun(F = #{directory := Dir, identity := Identity}) ->
        RenderingNs = <<"physics-test-rendering">>,
        Rendering = quod_agent_hosting_tests:start_ontology(RenderingNs, Dir, Identity,
            quod_prolog:terms_to_diff(quod_ct:gui_terms()),
            [{can_invoke,{'_'},{node,maps:get(pubkey,Identity)},{'_'},RenderingNs}]),
        try
            RA = quod_simplex:genesis_hash(RenderingNs),
            commit(Ns, {',', {assertz, {rendering_vocabulary, RenderingNs, RA}},
                              {assertz, {modelling_vocabulary, RenderingNs, RA}}}),
            Fun(F)
        after quod_agent_hosting_tests:stop_ontology(Rendering) end
    end,
    try quod_agent_hosting_tests:with_host(WithRendering, Transform(Rules), current, Ns)
    after catch quod_reg:unsubscribe({physics, Ns}) end.

default_world_view_rule() ->
    [Rule] = [T || T = {':-',{world_view,_,_,_},_} <-
                    quod_prolog:read_terms("priv/ontologies/common_predicates.pl")],
    Rule.

well_formed_scene_rule() ->
    [Rule] = [T || T = {':-',{well_formed_scene,_},_} <-
                    quod_prolog:read_terms("priv/ontologies/gui_scene.pl")],
    Rule.

world_rules(Ns) ->
    Actor = {agent_instance_ref, Ns, {'_'}, actor},
    quod_prolog:read_terms("priv/ontologies/quod_physics.pl") ++
        quod_prolog:read_terms("priv/ontologies/quod_hinged.pl") ++
        quod_prolog:read_terms("priv/ontologies/quod_space.pl") ++
        quod_prolog:read_terms("test/fixtures/space-permissions.pl") ++ [{instance_of,physical_space,room}] ++
        [{can_invoke, {physics_store_request, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}}, Actor, {'_'}, Ns},
         {can_invoke, {physics_activate, {'_'}, {'_'}, {'_'}}, Actor, {'_'}, Ns},
         {can_invoke, {physics_store_retired, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}}, Actor, {'_'}, Ns},
         {can_invoke, {physics_cancel_activation, {'_'}, {'_'}, {'_'}}, Actor, {'_'}, Ns},
         {physics_space, room, disabled, actor},
         {physics_run, room, 0, none}, {physics_structure, room, 1}, {physics_next_body,room,4},
         {physics_allowances, room, {limits, 64, 64, 256, 1000000,{geometry,256,4096,4096}}, 16667, -9810, 10000},
         {physics_body_definition, room, 1, 1, fixed, {vector,0,-500,0}, {owned, {box,10000,500,10000}, 1}},
         {physics_body_definition, room, 2, 1, dynamic, {vector,0,3000,0}, {owned, {box,500,500,500}, 1}}].

worlds(Ns) -> gen_server:call(quod_reg:via({quod_runtime, Ns}), physics_worlds).
reconcile(Ns) ->
    ?assertEqual(ok,reconcile_physics(Ns)).
reconcile_physics(Ns) ->
    quod_runtime:reconcile_resource(Ns,quod_prolog:applied(Ns),physics_worlds,
                                   all,quod_time:mono_ms()+10000).
installed(Ns) -> installed(Ns, quod_simplex:genesis_hash(Ns)).
installed(Ns, Anchor) ->
    installed(Ns,Anchor,any,quod_time:mono_ms()+15000).
installed_world(World={world_ref,Ns,Anchor,_}) ->
    installed(Ns,Anchor,World,quod_time:mono_ms()+15000).
installed(Ns,Anchor,Wanted,Deadline) ->
    receive
        {physics_status,_,_,Other={world_ref,Ns,Anchor,_},_,_}
          when Wanted =/= any, Other =/= Wanted -> installed(Ns,Anchor,Wanted,Deadline);
        {physics_status, _, Pid, World = {world_ref,Ns,Anchor,_}, _, installed} ->
            case is_process_alive(Pid) of
                false -> installed(Ns,Anchor,Wanted,Deadline);
                true -> case worlds(Ns) of
                    #{World := #{pid := Pid, stopping := false}} ->
                        case gen_server:call(Pid,status) of
                            #{phase := active,navigation_ready := true} -> {Pid,World};
                            _ -> installed(Ns,Anchor,Wanted,Deadline)
                        end;
                    _ -> installed(Ns,Anchor,Wanted,Deadline)
                end
            end;
        {physics_status, _, _, {world_ref,Ns,Anchor,_}, _, Status}
          when Status =:= activating; Status =:= awaiting_actor; Status =:= capacity;
               Status =:= sleeping -> installed(Ns,Anchor,Wanted,Deadline);
        {physics_status, _, _, {world_ref,Ns,Anchor,_}, _, {unavailable,_}} -> installed(Ns,Anchor,Wanted,Deadline);
        {physics_status, _, _, {world_ref,Ns,Anchor,_}, _, {observation,_,_}} -> installed(Ns,Anchor,Wanted,Deadline);
        {physics_status, _, _, {world_ref,Ns,Other,_}, _, _} when Other =/= Anchor -> installed(Ns,Anchor,Wanted,Deadline);
        {physics_status, _, Pid, World, _, Error} ->
            case worlds(Ns) of
                #{World := #{pid := Pid, stopping := false}} -> error({physics_installation, Error, request_result()});
                _ -> installed(Ns,Anchor,Wanted,Deadline)
            end
    after max(0,Deadline-quod_time:mono_ms()) ->
        error({physics_not_installed,Wanted,worlds(Ns),quod_runtime:stats(Ns)}) end.
commit(Ns, Goal) -> ?assertMatch({ok, _, _}, quod_ct:rp(Ns, Goal)).

request_result() ->
    receive {agent_request_finished, _, _, _, _, Result} -> brief(Result)
    after 1000 -> missing_result end.
brief({ok, _, {normalized, {failed, Blob}}}) -> redact(quod_wire_term:decode_failure_reasons(Blob));
brief({ok, _, Outcome}) -> Outcome;
brief({error, {custody_unresolved, Result}}) -> {custody_unresolved, brief(Result)};
brief(Result) -> Result.

redact(B) when is_binary(B) -> {bytes, byte_size(B)};
redact(T) when is_tuple(T) -> list_to_tuple([redact(X) || X <- tuple_to_list(T)]);
redact(L) when is_list(L) -> [redact(X) || X <- L];
redact(X) -> X.

sleeping_world_and_unchanged_cost_test_() ->
    {timeout, 60, fun() -> with_world(fun(F = #{namespace := Ns}) ->
        {Pid, World} = enable(F),
        receive {physics_status, _, Pid, World, _, sleeping} -> ok
        after 15000 -> error(world_never_slept) end,
        Before = gen_server:call(Pid, status),
        #{World := #{spec := Spec}} = worlds(Ns),
        Fence = quod_physics:fence(Spec),
        assert_no_physics_io(fun() ->
            [reconcile(Ns) || _ <- lists:seq(1, 5)],
            {ok, Frame, _} = quod_physics:snapshot(Pid, #{fence => Fence, structure => 1, tick => -1}),
            {ok, Frame, _} = quod_physics:snapshot(Pid, #{fence => Fence, structure => 1, tick => -1}),
            ?assertMatch({ok, unchanged, _}, quod_physics:snapshot(Pid, Frame)),
            After = gen_server:call(Pid, status),
            ?assertEqual(maps:with([installs,steps,tick,incarnation], Before),
                         maps:with([installs,steps,tick,incarnation], After))
        end)
    end) end}.

assert_no_physics_io(Fun) ->
    Collector = spawn_link(fun() -> trace_calls([]) end),
    Trace = trace:session_create(physics_unchanged, Collector, []),
    Watched = [{quod_voxel,sample,4}, {quod_physics_native,voxel_prepare,5},
               {quod_physics_native,new_world,3}, {quod_physics_native,install,3},
               {quod_physics_native,install_hinges,2}, {quod_physics_native,control_hinge,4}, {quod_ledger_store,append,2}, {quod_ledger_store,fold,5},
               {quod_ledger_store,fold_groups,3}, {quod_ledger_store,open,3},
               {quod_file,write_atomic,3}, {dets,insert,2}, {dets,sync,1}, {file,write,2}, {file,sync,1}, {file,datasync,1}],
    Match = [{'_',[],[{message,{caller}}]}],
    [trace:function(Trace, MFA, Match, [local]) || MFA <- Watched],
    trace:process(Trace, all, true, [call]),
    try
        Fun(),
        Delivered = trace:delivered(Trace, all),
        receive {trace_delivered, all, Delivered} -> ok after 5000 -> error(trace_timeout) end,
        Collected = make_ref(), Collector ! {finish,self(),Collected},
        Calls = receive {trace_calls,Collected,AllCalls} -> AllCalls
                after 5000 -> error(trace_collection_timeout) end,
        ?assertEqual([], Calls)
    after
        trace:session_destroy(Trace), unlink(Collector), exit(Collector,kill)
    end.

same_host_restart_and_runtime_retirement_test_() ->
    {timeout, 90, fun() -> with_world(fun(F = #{namespace := Ns}) ->
        {First, World} = enable(F),
        #{World := #{spec := Spec1}} = worlds(Ns),
        Fence1 = quod_physics:fence(Spec1),
        {ok, Frame1, _} = quod_physics:snapshot(First, #{fence => Fence1, structure => 1, tick => -1}),
        M = monitor(process, First), exit(First, kill),
        receive {'DOWN', M, process, First, killed} -> ok after 5000 -> error(still_alive) end,
        {Second, World} = installed(Ns),
        ?assertNotEqual(First, Second),
        #{World := #{spec := Spec2}} = worlds(Ns),
        ?assertEqual(maps:get(epoch, Spec1), maps:get(epoch, Spec2)),
        ?assertEqual(maps:get(generation, Spec1) + 1, maps:get(generation, Spec2)),
        ?assertEqual({error, unavailable}, quod_physics:snapshot(Second, Frame1)),
        {ok, Frame2, _} = quod_physics:snapshot(Second, #{fence => quod_physics:fence(Spec2), structure => 1, tick => -1}),
        ?assertNot(quod_physics:accepts(Frame1, Frame2)),
        Runtime = quod_reg:where({quod_runtime, Ns}),
        R = monitor(process, Runtime), M2 = monitor(process, Second),
        exit(Runtime, kill),
        receive {'DOWN', R, process, Runtime, killed} -> ok after 5000 -> error(runtime_alive) end,
        receive {'DOWN', M2, process, Second, _} -> ok after 5000 -> error(orphan_simulator) end,
        {Third, World} = installed(Ns),
        ?assertNotEqual(Second, Third),
        #{World := #{spec := Spec3}} = worlds(Ns),
        ?assertEqual(maps:get(generation, Spec2) + 1, maps:get(generation, Spec3))
    end) end}.

native_failure_does_not_retry_definition_test_() ->
    {timeout, 60, fun() -> with_world(fun(F = #{namespace := Ns, node := Node, key := Key}) ->
        commit(Ns, {',', {retract, {physics_allowances, room, {limits,64,64,256,1000000,{geometry,256,4096,4096}},16667,-9810,10000}},
                          {assertz, {physics_allowances, room, {limits,1,1,256,1000000,{geometry,256,4096,4096}},16667,-9810,10000}}}),
        true = quod_reg:subscribe({physics, Ns}),
        commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
        commit(Ns, {',', {retract, {physics_space,room,disabled,actor}},
                          {assertz, {physics_space,room,enabled,actor}}}),
        Pid = receive {physics_status, _, P, _, _, {failed, body_allowance}} -> P
              after 15000 -> error(native_failure_not_visible) end,
        Before = gen_server:call(Pid, status),
        [reconcile(Ns) || _ <- lists:seq(1, 5)],
        ?assertEqual(Before, gen_server:call(Pid, status)),
        ?assertEqual({error, unavailable}, quod_physics:snapshot(Pid, ignored)),
        ?assertEqual({error, simulation_failed}, quod_physics:watch(Pid, ignored,none)),
        commit(Ns, {',', {retract, {physics_allowances, room, {limits,1,1,256,1000000,{geometry,256,4096,4096}},16667,-9810,10000}},
                          {assertz, {physics_allowances, room, {limits,64,64,256,1000000,{geometry,256,4096,4096}},16667,-9810,10000}}}),
        {Replacement, _} = installed(Ns),
        ?assertNotEqual(Pid, Replacement),
        _ = F,
        quod_reg:unsubscribe({physics, Ns})
    end) end}.

enable(#{namespace := Ns, node := Node, key := Key}) ->
    true = quod_reg:subscribe({physics, Ns}),
    commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
    commit(Ns, {',', {retract, {physics_space,room,disabled,actor}},
                      {assertz, {physics_space,room,enabled,actor}}}),
    installed(Ns).
trace_calls(Acc) ->
    receive
        {trace, Pid, call, {M,F,Args}, Caller} ->
            Keys = case catch gproc:info(Pid,gproc) of
                {gproc,Entries} -> [Key || {Key,_} <- Entries];
                _ -> []
            end,
            trace_calls([#{pid => Pid,call => {M,F,length(Args)},
                           caller => Caller,registered_keys => Keys} | Acc]);
        {finish,From,Ref} -> From ! {trace_calls,Ref,lists:reverse(Acc)}
    end.

%% Target application finality can precede its source's durable receipt. Wait
%% for that original operation before measuring unrelated unchanged checks.
await_source_receipt({ok,#{operation_ref := Op = {operation,Ns,_,_,_}},
                     {normalized,{committed,_,Target}}}) ->
    Engine = quod_reg:where({quod_prolog,Ns}),
    Monitor = monitor(process,Engine),
    true = quod_reg:subscribe({runtime,Ns}),
    try await_source_receipt(Engine,Monitor,Ns,Op,Target,quod_time:mono_ms()+5000)
    after demonitor(Monitor,[flush]), quod_reg:unsubscribe({runtime,Ns}) end.

await_source_receipt(Engine,Monitor,Ns,Op,Target,Deadline) ->
    Remaining = Deadline-quod_time:mono_ms(),
    ?assert(Remaining > 0),
    {ok,#{applied_floor := Floor,outcome := Outcome}} =
        quod_prolog:outcome_snapshot(Ns,Op,Remaining),
    case Outcome of
        #{operation_state := terminal,receipt_height := Height,
          outcome_ref := {applications,[Target]}} when Height =< Floor -> ok;
        #{operation_state := unresolved,outcome_ref := {applications,[Target]}} ->
            receive
                {projection_advanced,Engine,Height} when Height > Floor ->
                    await_source_receipt(Engine,Monitor,Ns,Op,Target,Deadline);
                {'DOWN',Monitor,process,Engine,Reason} -> error({source_down,Reason})
            after max(0,Deadline-quod_time:mono_ms()) -> error(source_receipt_not_installed) end
    end.

uncertain_activation_keeps_original_custody_test_() ->
    {timeout, 90, fun() ->
        {ok, _} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test, barrier}),
        try with_world(fun(#{namespace := Ns, node := Node, key := Key}) ->
            true = quod_reg:subscribe({physics, Ns}),
            commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
            commit(Ns, {',', {retract, {physics_space,room,disabled,actor}},
                              {assertz, {physics_space,room,enabled,actor}}}),
            {Proof, Operation} = receive {fipa_completion_prepared, P, Op} -> {P, Op}
                                 after 10000 -> error(request_not_submitted) end,
            reconcile(Ns),
            [{World, #{pid := First, spec := Spec1}}] = maps:to_list(worlds(Ns)),
            {request, FirstToken, 0, Bytes, Signature} = maps:get(custody, Spec1),
            {ok, #{operation_ref := Operation}} = quod_client_goal:verify(Bytes, Signature),
            M = monitor(process, First), exit(First, kill),
            receive {'DOWN', M, process, First, killed} -> ok after 5000 -> error(still_alive) end,
            Second = receive {physics_status, _, P2, World, _, activating} when P2 =/= First -> P2
                     after 10000 -> error(replacement_not_started) end,
            ?assertMatch(#{installs := 0, steps := 0}, gen_server:call(Second, status)),
            ?assertMatch({ok, _, {operation_pending, Operation}},
                         quod_client_goal_ingress:resolve_operation(Bytes, Signature)),
            Proof ! release,
            NextProof = receive {fipa_completion_prepared, P3, Op2} when Op2 =/= Operation -> P3
                        after 15000 -> error(fresh_request_not_submitted) end,
            ?assertMatch(#{installs := 0, steps := 0}, gen_server:call(Second, status)),
            #{World := #{spec := #{generation := 1, run_token := FirstToken}}} = worlds(Ns),
            NextProof ! release,
            {Second, World} = installed(Ns),
            #{World := #{spec := #{generation := 2, run_token := NextToken}}} = worlds(Ns),
            ?assertNotEqual(FirstToken, NextToken),
            ?assertMatch({ok, _, {operation_outcome, _, #{status := committed}}},
                         quod_client_goal_ingress:resolve_operation(Bytes, Signature))
        end, fun(Rules) ->
            [case R of
                 {':-', Head = {physics_activate, _, _, _}, Body} ->
                     {':-', Head, {',', test_fipa_completion, Body}};
                 _ -> R
             end || R <- Rules]
        end)
        after gproc:unreg(quod_reg:name({host_test, barrier})) end
    end}.

host_assignment_replacement_test_() ->
    {timeout, 90, fun() -> with_world(fun(F = #{namespace := Ns, node := Node, reference := Ref}) ->
        {First, World} = enable(F),
        {ok, Blob} = quod_wire_term:encode_canonical(Ref),
        {ok, Key2} = quod_agent_vault:prepare(Blob, 1),
        commit(Ns, {goal, {agent_assignment,actor,Node,1,Node,2,Key2}}),
        {Second, World} = installed(Ns),
        ?assertNotEqual(First, Second),
        #{World := #{spec := #{epoch := 2, generation := 2}}} = worlds(Ns),
        Remote = setelement(2, Node, <<"remote-node">>),
        M = monitor(process, Second),
        commit(Ns, {goal, {agent_assignment,actor,Node,2,Remote,3,<<75:256>>}}),
        receive {'DOWN', M, process, Second, _} -> ok after 10000 -> error(old_host_running) end,
        reconcile(Ns), ?assertEqual(#{}, worlds(Ns)),
        {ok, Key4} = quod_agent_vault:prepare(Blob, 3),
        commit(Ns, {goal, {agent_assignment,actor,Remote,3,Node,4,Key4}}),
        {Third, World} = installed(Ns),
        ?assertNotEqual(Second, Third),
        #{World := #{spec := #{epoch := 4, generation := 3}}} = worlds(Ns)
    end) end}.

replay_retires_world_without_replaying_reactions_test_() ->
    {timeout, 90, fun() -> with_world(fun(F = #{namespace := Ns}) ->
        {First, World} = enable(F),
        commit(Ns, {trigger_event, {do_work, replay_once}}),
        {ok, GoalBlob} = quod_durable_term:encode_goal({record_ping,replay_once}),
        receive {agent_request_finished, _, _, _, _,
                 {ok, #{goal_blob := GoalBlob}, {normalized, {committed, _, _}}}} -> ok
        after 10000 -> error(live_reaction_not_completed) end,
        Before = worlds(Ns), #{World := #{spec := #{generation := G}}} = Before,
        M = monitor(process, First), Prolog = quod_reg:where({quod_prolog,Ns}),
        exit(Prolog, kill),
        receive {'DOWN', M, process, First, _} -> ok after 10000 -> error(replay_kept_old_world) end,
        {Next, World} = installed(Ns),
        ?assertNotEqual(First, Next),
        #{World := #{spec := #{generation := NextG}}} = worlds(Ns),
        ?assertEqual(G+1, NextG),
        ?assertMatch({ok, [#{'Rows' := [replay_once]}], _}, quod_prolog:prove_ro(Ns,
            {findall, {'V'}, {ping, {'V'}}, {'Rows'}}))
    end) end}.

runtime_collapse_retires_native_world_test_() ->
    {timeout, 90, fun() ->
        {ok, _} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test, local_proof}),
        Saved = application:get_env(quod, runtime_max_queued_events),
        try with_world(fun(F = #{namespace := Ns}) ->
            {First, World} = enable(F),
            #{World := #{spec := #{generation := G}}} = worlds(Ns),
            Runtime = quod_reg:where({quod_runtime,Ns}),
            commit(Ns, {assertz, physics_gate}),
            Reader = receive {local_proof_waiting, P} -> P after 10000 -> error({selector_not_waiting,quod_runtime:stats(Ns)}) end,
            M = monitor(process, First), R = monitor(process, Reader),
            Parent = self(), Tag = make_ref(),
            Observe = fun(State, {in, {'$gen_call', _, {reconcile_resource, _, physics_worlds, future, _}}}, _) ->
                              Parent ! {queued,Tag}, State;
                         (State, {in, {applied_live, _, _}}, _) -> Parent ! {committed,Tag}, State;
                         (State, _, _) -> State end,
            ok = sys:install(Runtime,{Observe,none}),
            try
                %% Retire the gate in committed truth while the old snapshot's
                %% reader is paused. Recovery must select an unblocked snapshot.
                commit(Ns,{retract,physics_gate}),
                receive {committed,Tag} -> ok after 5000 -> error(commit_not_delivered) end,
                BaseQueue = maps:get(queue_len,quod_runtime:stats(Ns)),
                application:set_env(quod,runtime_max_queued_events,BaseQueue+2),
                [begin
                    spawn(fun() -> Parent ! {future_result, Tag,
                        quod_runtime:reconcile_resource(Ns,quod_prolog:applied(Ns)+100,
                            physics_worlds,future,quod_time:mono_ms()+10000)} end),
                    receive {queued,Tag} -> ok after 5000 -> error(queue_not_received) end,
                    ?assertEqual(BaseQueue+Count,maps:get(queue_len,quod_runtime:stats(Ns)))
                 end || Count <- [1,2]],
                ?assertEqual({error,overloaded},quod_runtime:reconcile_resource(Ns,0,
                    physics_worlds,all,quod_time:mono_ms()+10000))
            after
                application:set_env(quod,runtime_max_queued_events,1024),
                sys:remove(Runtime,Observe)
            end,
            receive {'DOWN',M,process,First,_} -> ok after 5000 -> error(collapse_kept_world) end,
            receive {'DOWN',R,process,Reader,_} -> ok after 5000 -> error(collapse_kept_reader) end,
            [receive {future_result,Tag,{error,runtime_recovering}} -> ok
             after 5000 -> error(caller_not_released) end || _ <- [1,2]],
            {Next,World} = installed(Ns), ?assertNotEqual(First,Next),
            #{World := #{spec := #{generation := NextG}}} = worlds(Ns),
            ?assertEqual(G+1,NextG),
            ?assert(maps:get(collapses,quod_runtime:stats(Ns)) >= 1)
        end, fun(Rules) ->
            [case Rule of
                {':-',Head = {physics_projection,_,_},Body} ->
                    {':-',Head,{',', {';', {'->',physics_gate,test_physics_snapshot},true}, Body}};
                _ -> Rule
             end || Rule <- Rules]
        end)
        after
            case Saved of undefined -> application:unset_env(quod,runtime_max_queued_events);
                          {ok,V} -> application:set_env(quod,runtime_max_queued_events,V) end,
            gproc:unreg(quod_reg:name({host_test,local_proof}))
        end
    end}.

native_boundary_retires_on_unwind_test() ->
    {ok, R} = quod_physics_native:new_world({2,2,1,1000.0,256,4096,4096},1/60,-9.81),
    Body = {1,1,dynamic,{{0.0,3.0,0.0},{0.0,0.0,0.0}},{solid,{box,0.5,0.5,0.5}},1.0},
    {ok,1} = quod_physics_native:install(R,{0,0,0},[Body]),
    Parent = self(),
    spawn(fun() -> Parent ! {foreign_native_call,quod_physics_native:step(R,false)} end),
    receive {foreign_native_call, Result} -> ?assertEqual({error,wrong_owner},Result)
    after 5000 -> error(native_call_not_returned) end,
    ?assertMatch({ok,{true,[_],[]}},quod_physics_native:sample(R)),
    %% Rustler's list iterator panics on an improper tail. Decoding is inside
    %% this adapter's unwind boundary, so the partially touched resource dies.
    ?assertEqual({error,native_failure},quod_physics_native:install(R,{0,0,0},[Body|malformed])),
    ?assertEqual({error,retired},quod_physics_native:sample(R)),
    ?assertEqual(ok,quod_physics_native:retire(R)),
    ?assertEqual({error,invalid_step},quod_physics_native:new_world({2,2,1,1000.0,256,4096,4096},1.0e-320,-9.81)).

snapshot_replacement_coalesces_while_native_owner_is_busy_test_() ->
    {timeout, 60, fun() -> with_world(fun(F = #{namespace := Ns}) ->
        {Pid, World} = enable(F),
        receive {physics_status,_,Pid,World,_,sleeping} -> ok
        after 15000 -> error(world_never_slept) end,
        ok = sys:suspend(Pid),
        try
            [begin
                OldY = case Rev of 2 -> 3000; _ -> (Rev-1)*1000 end,
                commit(Ns, {',', {retract,{physics_body_definition, room, 2, Rev-1, dynamic, {vector,0,OldY,0}, {owned, {box,500,500,500}, 1}}},
                   {',', {assertz,{physics_body_definition, room, 2, Rev, dynamic, {vector,0,Rev*1000,0}, {owned, {box,500,500,500}, 1}}},
                    {',', {retract,{physics_structure,room,Rev-1}}, {assertz,{physics_structure,room,Rev}}}}}),
                reconcile(Ns)
             end || Rev <- lists:seq(2,6)],
            {message_queue_len, Queued} = process_info(Pid,message_queue_len),
            ?assert(Queued =< 2)
        after sys:resume(Pid) end,
        await_structure(Ns,Pid,World,6),
        #{installs := Installs} = gen_server:call(Pid,status),
        ?assert(Installs =< 3)
    end) end}.

await_structure(Ns,Pid,World,Structure) ->
    #{World := #{spec := Spec}} = worlds(Ns),
    Expected = #{fence => quod_physics:fence(Spec),structure => Structure,tick => -1},
    case quod_physics:snapshot(Pid,Expected) of
        {ok,_,_} -> ok;
        _ -> receive {physics_status,_,Pid,World,_,installed} -> await_structure(Ns,Pid,World,Structure)
             after 10000 -> error({latest_structure_not_installed,Structure,
                 worlds(Ns),quod_runtime:stats(Ns),gen_server:call(Pid,status)}) end
    end.

activation_timeout_is_unresolved_not_rejection_test_() ->
    {timeout, 60, fun() ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,barrier}),
        try with_world(fun(#{namespace := Ns,node := Node,key := Key}) ->
            true = quod_reg:subscribe({physics,Ns}),
            commit(Ns,{goal,{agent_hosted,actor,Node,1,Key}}),
            commit(Ns,{',',{retract,{physics_space,room,disabled,actor}},
                           {assertz,{physics_space,room,enabled,actor}}}),
            Operation = receive {fipa_completion_prepared,_,Op} -> Op
                        after 10000 -> error(activation_not_started) end,
            Pid = receive {physics_status,_,P,_,_,{unavailable,activation_unresolved}} -> P
                  after 10000 -> error(timeout_not_reported) end,
            [{World,#{spec := Spec}}] = maps:to_list(worlds(Ns)),
            {request,_,0,Bytes,Signature} = Custody = maps:get(custody,Spec),
            ?assertMatch({ok,#{operation_ref := Operation}},quod_client_goal:verify(Bytes,Signature)),
            [reconcile(Ns) || _ <- lists:seq(1,5)],
            ?assertMatch(#{phase := unresolved,installs := 0,steps := 0},gen_server:call(Pid,status)),
            #{World := #{spec := #{custody := Custody,generation := 0}}} = worlds(Ns),
            ?assertMatch({ok,_,{operation_pending,Operation}},quod_client_goal_ingress:resolve_operation(Bytes,Signature))
        end,fun(Rules) ->
            [case R of
                {':-',Head = {physics_activate,_,_,_},Body} -> {':-',Head,{',',test_fipa_completion,Body}};
                {physics_allowances,W,L,D,G,_} -> {physics_allowances,W,L,D,G,1000};
                _ -> R
             end || R <- Rules]
        end)
        after gproc:unreg(quod_reg:name({host_test,barrier})) end
    end}.

retained_activation_before_first_send_is_resolve_only_after_owner_loss_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Node,key := Key,reference := Actor}) ->
        Vault = quod_reg:where({agent_vault,node}), Parent = self(), Tag = make_ref(),
        Observe = fun(fresh,{in,{'$gen_call',{Worker,_},{retain,Scope,Receipt,_}}},_) ->
                          true = erlang:suspend_process(Worker),
                          Parent ! {retaining,Tag,Worker,Scope,Receipt}, held;
                     (State,_,_) -> State end,
        ok = sys:install(Vault,{Observe,fresh}),
        true = quod_reg:subscribe({physics,Ns}),
        try
            commit(Ns,{goal,{agent_hosted,actor,Node,1,Key}}),
            commit(Ns,{',',{retract,{physics_space,room,disabled,actor}},
                           {assertz,{physics_space,room,enabled,actor}}}),
            {Worker,Scope,Receipt} = receive {retaining,Tag,W,S,SavedReceipt} -> {W,S,SavedReceipt}
                                    after 5000 -> error(receipt_not_retained) end,
            %% This owner call follows the retain mutation. The signed worker
            %% is suspended before it can receive the reply or send C.
            ?assertEqual({ok,Receipt},quod_agent_vault:retained(Scope)),
            [{World,#{pid := Old}}] = maps:to_list(worlds(Ns)),
            exit(Worker,kill),
            New = receive {physics_status,_,P,World,_,{unavailable,activation_custody_unresolved}}
                            when P =/= Old -> P
                  after 10000 -> error(successor_did_not_resolve_retained_request) end,
            ?assertEqual({ok,Receipt},quod_agent_vault:retained(Scope)),
            #{store := {C,CSig},request := {R,RSig}} = Receipt,
            ?assertMatch({ok,_,{operation_pending,_}},quod_client_goal_ingress:resolve_operation(C,CSig)),
            ?assertMatch(#{phase := unresolved,installs := 0},gen_server:call(New,status)),
            {ok,#{goal_blob := GoalBlob}} = quod_client_goal:verify(R,RSig),
            {ok,{physics_activate,room,0,Token}} = quod_durable_term:decode_goal(GoalBlob),
            commit(Ns,{assertz,{can_cancel_physics_activation,room,Actor}}),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},submit_fixture(F,
                {physics_cancel_activation,room,0,{request,Token,0,R,RSig}})),
            {_,World} = installed(Ns),
            ?assertEqual(none,quod_agent_vault:retained(Scope)),
            %% Late delivery cannot resurrect the retired original request.
            ?assertMatch({ok,_,{normalized,{failed,_}}},quod_client_goal_ingress:submit(C,CSig))
        after sys:remove(Vault,Observe) end
    end) end}.

unobserved_custody_has_explicit_lifecycle_exit_test_() ->
    [{atom_to_list(Exit),{timeout,60,fun() ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,barrier}),
        try with_world(fun(F = #{namespace := Ns,node := Node,key := Key,reference := Actor}) ->
            true = quod_reg:subscribe({physics,Ns}),
            commit(Ns,{goal,{agent_hosted,actor,Node,1,Key}}),
            commit(Ns,{',',{retract,{physics_space,room,disabled,actor}},
                           {assertz,{physics_space,room,enabled,actor}}}),
            {Proof,Operation} = receive {fipa_completion_prepared,P,Op} -> {P,Op}
                    after 5000 -> error(custody_store_not_paused) end,
            Old = receive {physics_status,_,P0,_,_,{unavailable,activation_custody_unresolved}} -> P0
                  after 5000 -> error(unobserved_custody_not_reported) end,
            [reconcile(Ns) || _ <- lists:seq(1,3)],
            [{World,#{pid := Old,spec := #{generation := 0,custody := none}}}] = maps:to_list(worlds(Ns)),
            {ok,Network} = quod_ontology:network_identity(),
            {ok,ScopeBytes} = quod_wire_term:encode_canonical({World,physics_activation}),
            Scope = {Network,ScopeBytes},
            {ok,Receipt = #{store := {StoreBytes,StoreSig},request := {Bytes,Sig}}} =
                quod_agent_vault:retained(Scope),
            ?assertMatch({ok,#{operation_ref := Operation}},quod_client_goal:verify(StoreBytes,StoreSig)),
            {ok,#{goal_blob := GoalBlob}} = quod_client_goal:verify(Bytes,Sig),
            {ok,{physics_activate,room,0,Token}} = quod_durable_term:decode_goal(GoalBlob),
            M = monitor(process,Old),
            commit(Ns,{',',{retract,physics_store_gate},
                {',',{retract,{physics_space,room,enabled,actor}},
                     {assertz,{physics_space,room,disabled,actor}}}}),
            receive {'DOWN',M,process,Old,_} -> ok after 5000 -> error(old_owner_not_retired) end,
            commit(Ns,{',',{retract,{physics_space,room,disabled,actor}},
                           {assertz,{physics_space,room,enabled,actor}}}),
            New = receive {physics_status,_,P1,World,_,{unavailable,activation_custody_unresolved}}
                            when P1 =/= Old -> P1
                  after 5000 -> error(restarted_owner_did_not_resolve_original) end,
            ?assertEqual({ok,Receipt},quod_agent_vault:retained(Scope)),
            ?assertMatch(#{phase := unresolved,installs := 0},gen_server:call(New,status)),
            case Exit of
                cancel ->
                    %% Authority can change and return at the same generation.
                    %% Neither transition retires the original uncertain store.
                    Other = setelement(4,Actor,other),
                    {ok,OtherBytes} = quod_wire_term:encode_canonical(Other),
                    {ok,OtherKey} = quod_agent_vault:prepare(OtherBytes,0),
                    commit(Ns,list_conjunction([
                        {assertz,{can_invoke,{'_'},Other,{'_'},Ns}},
                        {assertz,{can_edit_physics,room,{node,maps:get(pubkey,maps:get(identity,F))}}},
                        {goal,{agent_hosted,other,Node,1,OtherKey}},
                        {physics_assign_authority,room,actor,other}])),
                    Swapped = receive
                        {physics_status,_,P2,World,_,{unavailable,activation_custody_unresolved}}
                          when P2 =/= New -> P2
                    after 10000 -> error(authority_swap_retired_uncertain_store) end,
                    ?assertEqual({ok,Receipt},quod_agent_vault:retained(Scope)),
                    commit(Ns,{physics_assign_authority,room,other,actor}),
                    receive
                        {physics_status,_,P3,World,_,{unavailable,activation_custody_unresolved}}
                          when P3 =/= Swapped -> ok
                    after 10000 -> error(returned_authority_lost_uncertain_store) end,
                    ?assertEqual({ok,Receipt},quod_agent_vault:retained(Scope)),
                    commit(Ns,{assertz,{can_cancel_physics_activation,room,Actor}}),
                    ?assertMatch({ok,_,{normalized,{committed,_,_}}},submit_fixture(F,
                        {physics_cancel_activation,room,0,{request,Token,0,Bytes,Sig}}));
                revoke ->
                    {ok,ActorBytes} = quod_wire_term:encode_canonical(Actor),
                    {ok,NextKey} = quod_agent_vault:prepare(ActorBytes,1),
                    commit(Ns,{goal,{agent_assignment,actor,Node,1,Node,2,NextKey}}),
                    ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{agent_key,actor,Key,revoked}))
            end,
            Proof ! release,
            {Active,World} = installed(Ns),
            ?assertNotEqual(Old,Active),
            ?assertMatch(#{World := #{spec := #{generation := 1}}},worlds(Ns)),
            ?assertEqual(none,quod_agent_vault:retained(Scope))
        end,fun(Rules) -> [physics_store_gate|[case Rule of
            {':-',Head = {physics_store_request,_,_,_,_,_,_},Body} ->
                {':-',Head,{',',{';',{'->',physics_store_gate,test_fipa_completion},true},Body}};
            {physics_allowances,W,L,D,G,_} -> {physics_allowances,W,L,D,G,1000};
            _ -> Rule
        end || Rule <- Rules]] end)
        after gproc:unreg(quod_reg:name({host_test,barrier})) end
    end}} || Exit <- [cancel,revoke]].

native_reports_the_exceeded_output_allowance_test() ->
    {ok,R} = quod_physics_native:new_world({2,0,2,1000.0,256,4096,4096},1/60,-9.81),
    {ok,1} = quod_physics_native:install(R,{0,0,0},[{1,1,dynamic,{{0.0,2.0,0.0},{0.0,0.0,0.0}},{solid,{box,0.5,0.5,0.5}},1.0}]),
    ?assertEqual({error,pose_allowance},quod_physics_native:sample(R)),
    ?assertEqual({error,retired},quod_physics_native:step(R,false)).

native_density_is_not_a_coordinate_budget_test() ->
    {ok,R} = quod_physics_native:new_world({1,1,1,1000.0,256,4096,4096},1/60,-9.81),
    {ok,1} = quod_physics_native:install(R,{0,0,0},[{1,1,dynamic,{{0.0,2.0,0.0},{0.0,0.0,0.0}},{solid,{box,0.5,0.5,0.5}},7850.0}]),
    ?assertMatch({ok,{true,[_],[]}},quod_physics_native:step(R,false)),
    ok = quod_physics_native:retire(R).

malformed_activation_is_a_selection_failure_test_() ->
    {timeout,60,fun() -> with_world(fun(#{namespace := Ns,node := Node,key := Key}) ->
        commit(Ns,{goal,{agent_hosted,actor,Node,1,Key}}),
        commit(Ns,{',',{retract,{physics_space,room,disabled,actor}},
                       {',',{assertz,{physics_request,room,malformed}},
                            {assertz,{physics_space,room,enabled,actor}}}}),
        [begin
            ?assertEqual({error,invalid_physics_projection},
                quod_runtime:reconcile_resource(Ns,quod_prolog:applied(Ns),physics_worlds,
                                                all,quod_time:mono_ms()+10000)),
            ?assertEqual(#{},worlds(Ns))
         end || _ <- lists:seq(1,3)],
        ?assertMatch({ok,[#{'G' := 0}],_},quod_prolog:prove_ro(Ns,{physics_run,room,{'G'},none}))
    end) end}.

physics_admission_preserves_event_release_test_() ->
    {timeout,60,fun() ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,barrier}),
        try with_world(fun(F = #{namespace := Ns}) ->
            {Pid,World} = enable(F),
            #{World := #{spec := #{custody := {request,_,_,Bytes,Signature}}}} = worlds(Ns),
            commit(Ns,{',',{trigger_event,{do_work,release_regression}},
                           {trigger_event,pause_batch}}),
            Runner = receive {host_projection_waiting,P} -> P
                     after 5000 -> error(event_batch_not_paused) end,
            Runtime = quod_reg:where({quod_runtime,Ns}),
            %% Exercise the admitted owner's production message while a real
            %% earlier reaction is queued above the installed event frontier.
            Runtime ! {physics_work,Pid,World,make_ref(),resolve,{Bytes,Signature},
                       {quod_time:now_ms()+5000,quod_time:mono_ms()+5000}},
            _ = quod_runtime:stats(Ns),
            Runner ! release,
            {ok,GoalBlob} = quod_durable_term:encode_goal({record_ping,release_regression}),
            receive {agent_request_finished,_,_,_,_,
                     {ok,#{goal_blob := GoalBlob},{normalized,{committed,_,_}}}} -> ok
            after 10000 -> error(reaction_lost_its_release) end,
            ?assertMatch({ok,[#{}],_},quod_prolog:prove_ro(Ns,{ping,release_regression}))
        end)
        after gproc:unreg(quod_reg:name({host_test,barrier})) end
    end}.


explicit_activation_cancellation_test_() ->
    [{atom_to_list(Scenario), {timeout,90,fun() -> cancelled_activation(Scenario) end}}
     || Scenario <- [never_submitted, prepared_before_cancellation, activation_wins, disabled]].

cancelled_activation(Scenario) ->
    {ok,_} = application:ensure_all_started(gproc),
    true = quod_reg:reg({host_test,barrier}),
    OldToken = <<77:256>>,
    %% Install the barrier after the old proof has captured its custody/run
    %% reads and staged writes, but before its transaction can submit them.
    BarrierTransform = fun(Rules) -> [case Rule of
        {':-',Head = {physics_activate,_,_,Token},{transaction,Body}}
          when Scenario =:= prepared_before_cancellation ->
            {':-',Head,{transaction,{',',Body,{';',{'->',{'=',Token,OldToken},test_fipa_completion},true}}}};
        _ -> Rule
    end || Rule <- Rules] end,
    try with_world(fun(F = #{namespace := Ns,node := Node,key := Key,reference := Actor}) ->
        true = quod_reg:subscribe({physics,Ns}),
        commit(Ns,{goal,{agent_hosted,actor,Node,1,Key}}),
        Runtime = quod_reg:where({quod_runtime,Ns}),
        ok = sys:suspend(Runtime),
        {Bytes,Signature} = try
            commit(Ns,{',',{retract,{physics_space,room,disabled,actor}},
                           {assertz,{physics_space,room,enabled,actor}}}),
            {B,Sig} = sign_fixture(F,{physics_activate,room,0,OldToken}),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},submit_fixture(F,
                {physics_store_request,room,0,none,OldToken,B,Sig})),
            {B,Sig}
        after sys:resume(Runtime) end,
        Request = {request,OldToken,0,Bytes,Signature},
        Anchor = element(3, Actor),
        Waiting = receive {physics_status,Runtime,P,{world_ref,Ns,Anchor,room},_,
                           {unavailable,activation_unresolved}} -> P
                  after 10000 -> error(stored_request_not_recovered) end,
        ?assertMatch({ok,[#{}],_},quod_prolog:prove_ro(Ns,
                      {physics_activation_status,room,Request,pending})),
        ?assertMatch({ok,_,{normalized,{failed,_}}},submit_fixture(F,
                      {physics_cancel_activation,room,0,Request})),
        commit(Ns,{assertz,{can_cancel_physics_activation,room,Actor}}),
        [?assertMatch({ok,_,{normalized,{failed,_}}},submit_fixture(F,Goal)) || Goal <-
            [{physics_cancel_activation,room,{'G'},Request},
             {physics_cancel_activation,room,0,{'Request'}}]],
        ?assertMatch({ok,_,{normalized,{failed,_}}},submit_fixture(F,
            {physics_cancel_activation,room,0,{request,<<78:256>>,0,Bytes,Signature}})),
        Parent = self(), Tag = make_ref(),
        Proof = case Scenario of
            prepared_before_cancellation ->
                spawn(fun() -> Parent ! {old_activation,Tag,quod_client_goal_ingress:submit(Bytes,Signature)} end),
                receive {fipa_completion_prepared,P0,_} -> P0
                after 10000 -> error(old_activation_not_prepared) end;
            activation_wins ->
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                             quod_client_goal_ingress:submit(Bytes,Signature)), none;
            never_submitted -> none;
            disabled ->
                commit(Ns,{',',{retract,{physics_space,room,enabled,actor}},
                               {assertz,{physics_space,room,disabled,actor}}}), none
        end,
        ok = sys:suspend(Runtime),
        Cancelled = try
            Result = submit_fixture(F,{physics_cancel_activation,room,0,Request}),
            case Scenario of
                never_submitted ->
                    %% With the owner paused, generation/prior still match:
                    %% only the durable cancellation fence forbids resurrection.
                    ?assertMatch({ok,_,{normalized,{failed,_}}},submit_fixture(F,
                        {physics_store_request,room,0,none,OldToken,Bytes,Signature}));
                disabled ->
                    commit(Ns,{',',{retract,{physics_space,room,disabled,actor}},
                                   {assertz,{physics_space,room,enabled,actor}}});
                _ -> ok
            end,
            Result
        after sys:resume(Runtime) end,
        case Scenario of
            activation_wins -> ?assertMatch({ok,_,{normalized,{failed,_}}},Cancelled);
            _ ->
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},Cancelled),
                ?assertMatch({ok,[#{}],_},quod_prolog:prove_ro(Ns,
                            {physics_activation_status,room,Request,cancelled}))
        end,
        case Proof of
            none when Scenario =:= never_submitted ->
                ?assertNotMatch({ok,_,{normalized,{committed,_,_}}},
                                quod_client_goal_ingress:submit(Bytes,Signature));
            none -> ok;
            _ -> Proof ! release,
                 receive {old_activation,Tag,Outcome} ->
                     ?assertNotMatch({ok,_,{normalized,{committed,_,_}}},Outcome)
                 after 10000 -> error(old_activation_did_not_finish) end
        end,
        {Next,World} = installed(Ns),
        #{World := #{spec := #{generation := Generation,run_token := NewToken}}} = worlds(Ns),
        ?assertNotEqual(OldToken,NewToken),
        case Scenario of
            activation_wins -> ?assertEqual(2,Generation);
            _ -> ?assertNotEqual(Waiting,Next), ?assertEqual(1,Generation)
        end
    end,BarrierTransform)
    after gproc:unreg(quod_reg:name({host_test,barrier})) end.

sign_fixture(F,Goal) -> sign_fixture(F,Goal,quod_time:now_ms()+30000).
sign_fixture(#{namespace := Ns,reference := {agent_instance_ref,Ns,Anchor,Instance},key := Key},Goal,Expiry) ->
    {ok,Network} = quod_ontology:network_identity(),
    {ok,InstanceText} = quod_client_goal_parser:format(Instance),
    {Canonical,_,_} = erlog_int:term_instance(Goal,0),
    {ok,GoalText} = quod_client_goal_parser:format(Canonical),
    Request = #{network_identity => Network,agent_namespace => Ns,agent_genesis_anchor => Anchor,
                agent_instance_text => InstanceText,signing_public_key => Key,
                operation_id => crypto:strong_rand_bytes(32),not_after_ms => Expiry,
                mode => execute,parser_version => 3,goal_text => GoalText},
    {ok,Bytes,Signature} = quod_agent_vault:sign(Request,quod_time:mono_ms()+5000),
    {Bytes,Signature}.
submit_fixture(F,Goal) ->
    {Bytes,Signature} = sign_fixture(F,Goal),
    quod_client_goal_ingress:submit(Bytes,Signature).

native_nonfinite_quarantine_retires_world_test() ->
    {ok,R} = quod_physics_native:new_world({1,1,1,1.7e308,256,4096,4096},1/60,-9.81),
    {ok,1} = quod_physics_native:install(R,{0,0,0},[{1,1,dynamic,{{1.5e308,2.0,0.0},{0.0,0.0,0.0}},{solid,{box,1.0e308,1.0e-150,1.0e-150}},1.0}]),
    ?assertEqual({error,non_finite_state},quod_physics_native:step(R,false)),
    ?assertEqual({error,retired},quod_physics_native:step(R,false)).

unexpected_owner_failure_is_quarantined_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns}) ->
        {Pid,World} = enable(F),
        #{World := #{spec := #{generation := G}}} = worlds(Ns),
        ok = sys:terminate(Pid,fixture_owner_fault),
        receive {physics_status,_,Pid,World,_,{failed,{owner_down,fixture_owner_fault}}} -> ok
        after 5000 -> error(owner_failure_not_visible) end,
        [reconcile(Ns) || _ <- lists:seq(1,3)],
        ?assertMatch(#{World := #{pid := Pid,stopping := dead,spec := #{generation := G}}},worlds(Ns)),
        commit(Ns,{',',{retract,{physics_structure,room,1}},
                       {assertz,{physics_structure,room,2}}}),
        {Next,World} = installed(Ns),
        ?assertNotEqual(Pid,Next),
        NextG = G+1,
        ?assertMatch(#{World := #{spec := #{generation := NextG}}},worlds(Ns))
    end) end}.

late_activation_does_not_clear_owner_quarantine_test_() ->
    {timeout,60,fun() ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,barrier}),
        try with_world(fun(#{namespace := Ns,node := Node,key := Key}) ->
            true = quod_reg:subscribe({physics,Ns}),
            commit(Ns,{goal,{agent_hosted,actor,Node,1,Key}}),
            commit(Ns,{',',{retract,{physics_space,room,disabled,actor}},
                           {assertz,{physics_space,room,enabled,actor}}}),
            {Proof,Operation} = receive {fipa_completion_prepared,P,Op} -> {P,Op}
                                after 5000 -> error(activation_not_paused) end,
            reconcile(Ns),
            [{World,#{pid := Pid,spec := #{generation := 0}}}] = maps:to_list(worlds(Ns)),
            ok = sys:terminate(Pid,fixture_owner_fault),
            receive {physics_status,_,Pid,World,_,{failed,{owner_down,fixture_owner_fault}}} -> ok
            after 5000 -> error(owner_failure_not_visible) end,
            Proof ! release,
            receive {agent_request_finished,_,_,_,_,
                     {ok,#{operation_ref := Operation},{normalized,{committed,_,_}}}} -> ok
            after 10000 -> error(late_activation_not_committed) end,
            [reconcile(Ns) || _ <- lists:seq(1,3)],
            ?assertMatch(#{World := #{pid := Pid,stopping := dead,spec := #{generation := 1}}},worlds(Ns))
        end,fun(Rules) -> [case Rule of
            {':-',Head = {physics_activate,_,_,_},Body} -> {':-',Head,{',',test_fipa_completion,Body}};
            _ -> Rule
        end || Rule <- Rules] end)
        after gproc:unreg(quod_reg:name({host_test,barrier})) end
    end}.

%% Deterministic delivery races at the real simulator's runtime protocol seam.
%% This owner controls replies; no signed write is fabricated or submitted.
activation_delivery_races_test() ->
    with_simulator(none,fun(Pid,Spec) ->
        Ref = physics_work(Pid,activate),
        assert_uncertain_custody_closed(Pid,Spec,Ref)
    end),
    Custody = {request,<<44:256>>,0,<<1>>,<<0:512>>},
    with_simulator(Custody,fun(Pid,Spec) ->
        Ref = physics_work(Pid,resolve),
        Selection = make_ref(),
        Current = Spec#{generation => 1,run_token => <<44:256>>},
        Pid ! {physics_selected,self(),Selection,Current},
        receive {physics_selection_applied,Pid,_,Selection} -> ok end,
        Pid ! {physics_result,self(),Ref,{ok,ignored,{operation_pending,ignored}}},
        NewRef = physics_work(Pid,resolve),
        Pid ! {physics_result,self(),NewRef,{ok,ignored,{operation_outcome,ignored,#{status => committed}}}},
        Activation = physics_work(Pid,activate),
        ?assertMatch(#{installs := 0},gen_server:call(Pid,status)),
        assert_uncertain_custody_closed(Pid,Current,Activation)
    end).

assert_uncertain_custody_closed(Pid,Spec,Ref) ->
    Pid ! {physics_result,self(),Ref,{error,{custody_unresolved,timeout}}},
    receive {physics_status,Pid,_,_,{unavailable,activation_custody_unresolved}} -> ok
    after 5000 -> error(custody_uncertainty_not_distinguished) end,
    [begin
        Selection = make_ref(),
        Pid ! {physics_selected,self(),Selection,Spec},
        receive {physics_selection_applied,Pid,_,Selection} -> ok end,
        ?assertMatch(#{phase := unresolved},gen_server:call(Pid,status))
     end || _ <- lists:seq(1,3)],
    receive {physics_work,Pid,_,_,_,_,_} -> error(uncertain_custody_resubmitted)
    after 0 -> ok end.

with_simulator(Custody,Fun) ->
    {ok,_} = application:ensure_all_started(gproc),
    Anchor = crypto:strong_rand_bytes(32),
    Guard = atomics:new(1,[{signed,false}]),
    Spec = #{world => {world_ref,<<"delivery-test">>,Anchor,room},
             authority => {agent_instance_ref,<<"delivery-test">>,Anchor,actor},
             epoch => 1,key => <<1:256>>,generation => 0,run_token => none,
             custody => Custody,budget => 5000,navigation_guard => {Guard,0}},
    {ok,Pid} = quod_physics:start(self(),Spec),
    try Fun(Pid,Spec) after gen_server:stop(Pid) end.

step_envelope_rebases_or_refuses_before_integration_test_() ->
    [{atom_to_list(Outcome),fun() -> with_simulator(none,fun(Pid,Spec) ->
        {Activation,Token} = receive
            {physics_work,Pid,_,Act,activate,{{physics_activate,room,0,T},_,_},_} -> {Act,T}
        after 5000 -> error(activation_missing) end,
        {Limit,Position} = case Outcome of
            rebase -> {10.0,{4900,0,0}};
            refuse -> {1.0,{0,0,0}}
        end,
        Body = {1,1,dynamic,{world_mm,Position,{0.0,0.0,0.0}},{solid,{ball,0.25}},1.0},
        Current = Spec#{generation => 1,run_token => Token,
            custody => {request,Token,0,<<2>>,<<0:512>>},
            limits => {2,2,8,Limit,2,100,100},dt => 0.02,gravity => 0.0,
            structure => 1,activities => #{},bodies => [Body]},
        Pid ! {physics_selected,self(),make_ref(),Current},
        Pid ! {physics_result,self(),Activation,{ok,ignored,{normalized,{committed,ignored,ignored}}}},
        case Outcome of
            rebase ->
                receive {physics_status,Pid,_,Token,installed} -> ok after 5000 -> error(frame_install_missing) end,
                ?assertMatch(#{phase := active,incarnation := Token},gen_server:call(Pid,status)),
                Expected = #{fence => quod_physics:fence(Current),structure => 1,incarnation => Token},
                {ok,_,Origin,{1,1,world,Local,_,_}} = quod_physics:body_state(Pid,Expected,{1,1},1000),
                ?assertEqual({4900,0,0},Origin),
                ?assertEqual(Position,quod_physics_coordinates:canonical(Local,Origin));
            refuse ->
                receive {physics_status,Pid,_,Token,{unavailable,coordinate_allowance}} -> ok
                after 5000 -> error(coordinate_refusal_missing) end,
                Before = gen_server:call(Pid,status),
                ?assertMatch(#{phase := {blocked,coordinate_allowance},incarnation := Token,steps := 0},Before),
                lists:foreach(fun(Next) ->
                    Selection = make_ref(), Pid ! {physics_selected,self(),Selection,Next},
                    receive {physics_selection_applied,Pid,_,Selection} -> ok after 5000 -> error(selection_missing) end,
                    ?assertEqual(Before,gen_server:call(Pid,status))
                end,[Current,Current#{budget => 6000}])
        end,
        receive {physics_work,Pid,_,_,activate,_,_} -> error(coordinate_refusal_restarted_world)
        after 0 -> ok end
    end) end} || Outcome <- [rebase,refuse]].

terrain_coverage_wait_retains_incarnation_and_unchanged_selection_test() ->
    {ok,{Air,_}} = quod_physics_native:voxel_prepare(binary:copy(<<127>>,1331),
        binary:copy(<<9:16>>,1331),500,{512,10000,10000,500000},[]),
    with_simulator(none,fun(Pid,Spec) ->
        {Activation,Token} = receive
            {physics_work,Pid,_,A,activate,{{physics_activate,room,0,T},_,_},_} -> {A,T}
        after 5000 -> error(activation_missing) end,
        Body = {1,1,dynamic,{world_mm,{2000,2000,2000},{0.0,0.0,0.0}},{solid,{ball,0.25}},1.0},
        Terrain = fun(Chunks) -> {0,1,fixed,{world_mm,{0,0,0},{0.0,0.0,0.0}},
                                  {terrain,500,Chunks},1.0} end,
        Current = Spec#{generation => 1,run_token => Token,
            custody => {request,Token,0,<<2>>,<<0:512>>},
            limits => {8,8,128,1000.0,512,100000,100000},dt => 1/60,gravity => -9.81,
            structure => 1,activities => #{},bodies => [Terrain([{{0,0,0},Air}]),Body]},
        Pid ! {physics_selected,self(),make_ref(),Current},
        Pid ! {physics_result,self(),Activation,{ok,ignored,{normalized,{committed,ignored,ignored}}}},
        receive {physics_status,Pid,_,Token,{unavailable,terrain_coverage}} -> ok
        after 5000 -> error(coverage_wait_missing) end,
        Before = gen_server:call(Pid,status),
        ?assertMatch(#{phase := coverage,steps := 0,navigation_ready := false},Before),
        Selection = make_ref(), Pid ! {physics_selected,self(),Selection,Current},
        receive {physics_selection_applied,Pid,_,Selection} -> ok
        after 5000 -> error(coverage_selection_missing) end,
        ?assertEqual(Before,gen_server:call(Pid,status)),
        receive {physics_status,Pid,_,_,installed} -> error(false_coverage_readiness)
        after 0 -> ok end,
        Chunks = [{{X*4000,Y*4000,Z*4000},Air} || X <- lists:seq(-2,2),
                    Y <- lists:seq(-2,2),Z <- lists:seq(-2,2)],
        Pid ! {physics_selected,self(),make_ref(),Current#{bodies => [Terrain(Chunks),Body]}},
        receive {physics_status,Pid,_,Token,installed} -> ok
        after 5000 -> error(coverage_install_missing) end,
        ?assertMatch(#{phase := active,incarnation := Token,navigation_ready := true},gen_server:call(Pid,status)),
        receive {physics_work,Pid,_,_,activate,_,_} -> error(coverage_restarted_world)
        after 0 -> ok end
    end).

input_uninstalled_world_and_expiry_test() ->
    with_simulator(none,fun(Pid,_) ->
        Request = {physics_input,#{},{control,principal,1,configuration},1,input,
                   quod_time:now_ms()+5000,quod_time:mono_ms()+5000},
        ?assertEqual({error,physics_world_unavailable},gen_server:call(Pid,Request)),
        Effect = {physics_input,Pid,#{},{control,principal,1,configuration},1,input,quod_time:now_ms()-1},
        ?assertEqual({error,expired},quod_effect:release_transient(Effect,quod_time:mono_ms()+5000))
    end).

unguarded_world_is_refused_test() ->
    {ok,_} = application:ensure_all_started(gproc),
    World = {world_ref,<<"unguarded-test">>,crypto:strong_rand_bytes(32),room},
    ?assertMatch({error,_},quod_physics:start(self(),#{world => World})),
    ?assertEqual(undefined,quod_reg:where({physics_world,World})).

physics_work(Pid,Kind) ->
    receive {physics_work,Pid,_,Ref,Kind,_,_} -> Ref
    after 5000 -> error({physics_work_missing,Kind}) end.

interrupted_initial_physics_selector_reselects_test_() ->
    {timeout,60,fun() ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,local_proof}),
        try with_world(fun(F = #{namespace := Ns}) ->
            {_,World} = enable(F),
            commit(Ns,{assertz,physics_gate}),
            OldReader = receive {local_proof_waiting,P0} -> P0
                        after 5000 -> error(old_selector_not_paused) end,
            Runtime = quod_reg:where({quod_runtime,Ns}),
            M = monitor(process,Runtime), exit(Runtime,kill),
            receive {'DOWN',M,process,Runtime,killed} -> ok end,
            FirstReader = receive {local_proof_waiting,P1} when P1 =/= OldReader -> P1
                          after 10000 -> error(initial_selector_not_paused) end,
            NewRuntime = quod_reg:where({quod_runtime,Ns}),
            Parent = self(), Tag = make_ref(),
            Observe = fun(State,{in,{'DOWN',_,process,P,_}},_) when P =:= FirstReader ->
                              Parent ! {selector_down,Tag}, State;
                         (State,_,_) -> State end,
            ok = sys:install(NewRuntime,{Observe,none}),
            try
                exit(FirstReader,kill),
                receive {selector_down,Tag} -> ok after 5000 -> error(selector_not_retired) end,
                ?assertMatch(#{resource_failures := #{physics_worlds :=
                    {error,{resource_worker_down,killed}}}},quod_runtime:stats(Ns)),
                %% No read basis was reported. Even an unrelated committed
                %% fact must wake this interrupted persistent consumer.
                commit(Ns,{assertz,unrelated_physics_reselection}),
                Reader = receive {local_proof_waiting,P2} -> P2
                         after 10000 -> error(interrupted_selector_lost_dependency) end,
                commit(Ns,{retract,physics_gate}),
                Reader ! release,
                {_,World} = installed(Ns)
            after sys:remove(NewRuntime,Observe) end
        end,fun(Rules) -> [case Rule of
            {':-',Head = {physics_projection,_,_},Body} ->
                {':-',Head,{',',{';',{'->',physics_gate,test_physics_snapshot},true},Body}};
            _ -> Rule
        end || Rule <- Rules] end)
        after gproc:unreg(quod_reg:name({host_test,local_proof})) end
    end}.

obstructed_door_signed_transition_test_() ->
    {timeout,90,fun() -> with_door(fun(F = #{namespace := Ns}) ->
        {Pid,World} = enable(F),
        true = quod_reg:subscribe({runtime,Ns}),
        Id = <<101:256>>, R = {close,1,Id},
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,0,Id})),
        await_door(Ns,R,{blocked,3}),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_hinged,room,10,1,{finished,R,{blocked,3}}})),
        {ok,[#{'Request' := {request,Sample,{blocked,3},Bytes,Signature}}],_} =
            quod_prolog:prove_ro(Ns,{physics_hinged_request,room,10,{'Request'}}),
        ?assertMatch({ok,_,{operation_outcome,_,#{status := committed}}},
                     quod_client_goal_ingress:resolve_operation(Bytes,Signature)),
        %% The same operation resolves to the original result; no second event.
        ?assertMatch({ok,_,_},quod_client_goal_ingress:submit(Bytes,Signature)),
        ?assertMatch({ok,_,{normalized,{failed,_}}},door_action(Ns,{physics_finish_hinged,Sample,{blocked,3}})),
        reconcile(Ns),
        #{World := #{pid := Pid,spec := Spec}} = worlds(Ns),
        {ok,Frame,Before} = quod_physics:snapshot(Pid,#{fence => quod_physics:fence(Spec),structure => 2,tick => -1}),
        [{10,_,_,_,_,_}] = [P || P = {10,_,_,_,_,_} <- maps:get(poses,Frame)],
        assert_no_physics_io(fun() ->
            [reconcile(Ns) || _ <- lists:seq(1,5)],
            #{installs := Installs} = Before,
            ?assertMatch(#{installs := Installs},gen_server:call(Pid,status))
        end),
        Monitor = monitor(process,Pid),exit(Pid,kill),
        receive {'DOWN',Monitor,process,Pid,killed} -> ok after 5000 -> error(door_owner_alive) end,
        {Next,World} = installed(Ns),
        ?assertNotEqual(Pid,Next),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_hinged,room,10,1,{finished,R,{blocked,3}}})),
        ok
    end,true) end}.

idle_compound_agent_blocks_moving_door_test_() ->
    {timeout,90,fun() -> with_door(fun(F = #{namespace := Ns}) ->
        {Pid,World} = enable(F), true = quod_reg:subscribe({runtime,Ns}),
        #{World := #{spec := Spec}} = worlds(Ns),
        Expected = #{fence => quod_physics:fence(Spec),structure => 2,tick => -1},
        {ok,Before,_} = quod_physics:snapshot(Pid,Expected),
        Body = lists:keyfind(3,1,maps:get(poses,Before)),
        R = {close,1,<<122:256>>},
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},
            door_action(Ns,{physics_close_hinged,room,10,0,<<122:256>>})),
        await_door(Ns,R,{blocked,3}), reconcile(Ns),
        {ok,After,_} = quod_physics:snapshot(Pid,Expected),
        ?assertEqual(Body,lists:keyfind(3,1,maps:get(poses,After))),
        %% Once the motor brakes, a player can leave contact through the
        %% retained physical query path without pushing the door.
        reconcile(Ns),
        QueryExpected = Expected#{incarnation => maps:get(run_token,Spec)},
        {ok,_,{0,0,0},Escape} = quod_physics:motion_query(Pid,QueryExpected,{3,1},
            {travel,{vector,0,0,2000},{angular,0,0,0}},{query_limits,2,0,8,128},1000),
        ?assertMatch({clear,_,_},Escape),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
            {physics_hinged,room,10,1,{finished,R,{blocked,3}}}))
    end,true,fun(Rules) ->
        [case Rule of
            {physics_body_definition, room, 3, Rev, fixed, Position, {owned, Box, Density}} ->
                {physics_body_definition, room, 3, Rev, controlled, {pose,Position,{rotation,0,0,0}}, {owned, {parts,[{part,{vector,0,0,0},Box},
                         {part,{vector,0,900,0},{ball,100}}]}, Density}};
            _ -> Rule
        end || Rule <- Rules]
    end) end}.

native_geometry_budget_and_retained_parts_test() ->
    Limits = {2,2,8,100.0,2,8,4},
    Shape = {parts,[{{{0.0,0.0,0.0},{0.0,0.0,0.0}},{ball,0.5}},
                   {{{1.0,0.0,0.0},{0.0,1.5,0.0}},{box,0.5,0.2,0.1}}]},
    Row = {1,1,controlled,{{0.0,1.0,0.0},{0.0,0.0,0.0}},Shape,1.0},
    {ok,R} = quod_physics_native:new_world(Limits,1/60,-9.81),
    ?assertEqual({ok,1},quod_physics_native:install(R,{0,0,0},[Row])),
    Before = quod_physics_native:sample(R),
    ?assertEqual({ok,0},quod_physics_native:install(R,{0,0,0},[Row])),
    ?assertEqual(Before,quod_physics_native:sample(R)),
    Extra = {2,1,fixed,{{5.0,0.0,0.0},{0.0,0.0,0.0}},{solid,{box,1.0,1.0,1.0}},1.0},
    ?assertEqual({error,geometry_allowance},quod_physics_native:install(R,{0,0,0},[Row,Extra])),
    ?assertEqual({error,retired},quod_physics_native:sample(R)).

unobstructed_door_signed_transition_test_() ->
    {timeout,90,fun() -> with_door(fun(F = #{namespace := Ns}) ->
        _ = enable(F),true = quod_reg:subscribe({runtime,Ns}),
        Id = <<102:256>>,R = {close,1,Id},
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,0,Id})),
        await_door(Ns,R,closed),
        ok
    end,false) end}.

hinged_command(Target) -> {position,Target,{motor,100,10,1000},{stop,20,target_or_contact}}.
hinged_recipe() ->
    {hinged,{box,50,1000,50},{box,1000,1000,100},1,{vector,0,1,0},
        {anchors,{vector,0,0,0},{vector,-1000,0,0}},{limits,-1500,1500},1500,hinged_command(0)}.

test_physics_frame(Spec) ->
    {physics_frame,maps:get(world,Spec),maps:get(authority,Spec),maps:get(epoch,Spec),
        maps:get(generation,Spec),maps:get(run_token,Spec),maps:get(structure,Spec)}.
test_hinge_sample(Spec,Revision,R,Tick,Angle,Contact,At,Expiry) ->
    {physics_sample,test_physics_frame(Spec),{activity,{hinge,10,Revision},R,hinged_command(0)},
        {revisions,[{joint,10,Revision},{body,10,Revision},{body,11,Revision}]},
        Tick,{validity,At,Expiry},{joint_position_mrad,Angle,Contact}}.

with_door(Fun,Obstructed) -> with_door(Fun,Obstructed,fun(Rules) -> Rules end).
with_door(Fun,Obstructed,Transform) ->
    with_world(fun(F = #{namespace := Ns}) ->
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
            {physics_add_hinged,room,10,11,{local,basic_door,1},{vector,0,1500,0},1})),
        %% Cleanup must preserve a failure before the test subscribed.
        try Fun(F) after catch quod_reg:unsubscribe({runtime,Ns}) end
    end,fun(Rules) ->
        Ns = <<"host-test-agent">>,Actor = {agent_instance_ref,Ns,{'_'},actor},
        Base = [Rule || Rule <- Rules, not (is_tuple(Rule) andalso element(1,Rule) =:= physics_body_definition andalso element(3,Rule) =:= 2)],
        Obstacle = case Obstructed of
            true -> [{physics_body_definition, room, 3, 1, fixed, {vector,1500,1500,-500}, {owned, {box,200,1000,200}, 1}}];
            false -> []
        end,
        Transform(Base ++ Obstacle ++ [
            {can_invoke,{physics_store_hinged_request,{'_'},{'_'},{'_'},{'_'}},Actor,{'_'},Ns},
            {can_invoke,{physics_finish_hinged,{'_'},{'_'}},Actor,{'_'},Ns},
            {can_edit_physics,room,{'_'}},
            {can_close_physics_hinged,room,10,{'_'}},
            {can_cancel_physics_hinged,room,10,{'_'}},
            {physics_hinged_class,basic_door,1,hinged_recipe()}])
    end).

door_action(Ns,Goal) ->
    {Scoped,_,_} = erlog_int:term_instance({'::',Ns,Goal},0),
    {ok,Bytes,Signature} = quod_node_actor:signed_goal(execute,Scoped,
        crypto:strong_rand_bytes(32),quod_time:now_ms()+10000),
    quod_client_goal_ingress:submit(Bytes,Signature).

await_door(Ns,R,Result) ->
    receive
        {applied_live,#{ns := Ns,applied_ops := Ops}} ->
            case lists:member({event,{physics_hinged_finished,room,10,R,Result}},Ops) of
                true -> ok;
                false -> await_door(Ns,R,Result)
            end;
        {physics_status,_,_,_,_,{failed,Why}} -> error({door_failed,Why});
        {physics_status,_,_,_,_,{observation,_,State}} when State =/= committed ->
            error({observation_failed,State,request_result()})
    after 15000 -> error({door_not_finished,
        maps:map(fun(_,#{pid := P,spec := S}) -> {gen_server:call(P,status),maps:with([generation,structure],S)} end,worlds(Ns)),
        quod_runtime:stats(Ns),request_result()}) end.

terminal_outcome_bridge_captures_failed_alternatives_test_() ->
    {timeout,90,fun() -> with_door(fun(F = #{namespace := Ns}) ->
        _ = enable(F),true = quod_reg:subscribe({runtime,Ns}),
        Id = <<111:256>>,R = {close,1,Id},
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,0,Id})),
        await_door_result(Ns,R,{blocked,3}),
        {ok,[#{'C' := {request,_,_,Bytes,Sig}}],_} =
            quod_prolog:prove_ro(Ns,{physics_hinged_request,room,10,{'C'}}),
        {ok,#{operation_ref := {operation,_,_,Agent,Op}}} = quod_client_goal:verify(Bytes,Sig),
        Height = quod_prolog:applied(Ns),Key = {1,Agent,Op},
        {ok,Key,Token} = quod_prolog:operation_dependency(Ns,Bytes,Height,1000),
        Query = {committed_operation_outcome,Bytes,committed},
        assert_no_physics_io(fun() ->
            [begin
                ?assertEqual({ok,Key,Token},quod_prolog:operation_dependency(Ns,Bytes,Height,1000)),
                with_outcome_session(Ns,Height,fun(Session,Bind,Ctx) ->
                    Goal = case Mode of
                        alternative -> {';', {',',Query,fail},true};
                        negation -> {'\\+',setelement(3,Query,rejected)};
                        cut -> {',',Query,'!'}
                    end,
                    ok = quod_proof_session:open(Session,<<1:128>>,Goal,allowed,Ctx,
                                                 quod_transaction_scope:empty_selection()),
                    ?assertMatch({solution,_},quod_proof_session:next(Session,<<1:128>>)),
                    ?assertEqual(Token,maps:get(Key,quod_proof_session:read_set(Session))),
                    {ok,Plan} = quod_proof_session:seal(Session,Bind),
                    ?assertEqual(Token,maps:get(Key,quod_ct:plan_material(read_check,Plan)))
                end)
            end || Mode <- [alternative,negation,cut]]
        end),
        {ok,Request} = quod_client_goal:decode(Bytes),
        {ok,ExpiredBytes} = quod_client_goal:encode(Request#{operation_id := <<113:256>>,
                                                          not_after_ms := 1}),
        ExpiredKey = {2,Agent,<<113:256>>},
        {ok,ExpiredKey,ExpiredToken} = quod_prolog:operation_dependency(Ns,ExpiredBytes,Height,1000),
        ?assertMatch({ExpiredBytes,Height,_},ExpiredToken),
        ExpiredQuery = {committed_operation_outcome,ExpiredBytes,expired},
        assert_no_physics_io(fun() ->
            [with_outcome_session(Ns,Height,fun(Session,Bind,Ctx) ->
                Goal = case Mode of
                    alternative -> {';', {',',ExpiredQuery,fail},true};
                    negation -> {'\\+',setelement(3,ExpiredQuery,committed)};
                    cut -> {',',ExpiredQuery,'!'};
                    rollback -> {';', {transaction,{',',ExpiredQuery,fail}},true}
                end,
                ok = quod_proof_session:open(Session,<<4:128>>,Goal,allowed,Ctx,
                                             quod_transaction_scope:empty_selection()),
                ?assertMatch({solution,_},quod_proof_session:next(Session,<<4:128>>)),
                ?assertEqual(ExpiredToken,maps:get(ExpiredKey,quod_proof_session:read_set(Session))),
                ok = quod_proof_session:open(Session,<<5:128>>,{assertz,{after_expired,true}},allowed,Ctx,
                                             quod_transaction_scope:empty_selection()),
                ?assertMatch({solution,_},quod_proof_session:next(Session,<<5:128>>)),
                {ok,Sealed} = quod_proof_session:seal(Session,Bind),
                ?assertEqual(ExpiredToken,maps:get(ExpiredKey,quod_ct:plan_material(read_check,Sealed)))
            end) || Mode <- [alternative,negation,cut,rollback]]
        end),
        %% An unsigned selector can neither change the committed request nor
        %% borrow another scope. Digest mismatches still retain the read that
        %% influenced failure; malformed/foreign selectors perform no read.
        lists:foreach(fun({Changed,ExpectedReads}) ->
            {ok,ChangedBytes} = quod_client_goal:encode(Changed),
            with_outcome_session(Ns,Height,fun(Session,_Bind,Ctx) ->
                ok = quod_proof_session:open(Session,<<3:128>>,
                    {committed_operation_outcome,ChangedBytes,{'Status'}},allowed,Ctx,
                    quod_transaction_scope:empty_selection()),
                ?assertMatch({complete,_},quod_proof_session:next(Session,<<3:128>>)),
                ?assertEqual(ExpectedReads,quod_proof_session:read_set(Session)),
                ?assertEqual([],quod_proof_session:live_bridges(Session))
            end)
        end, [{Request#{goal_text => <<"this is not a Prolog goal">>},#{Key => Token}},
              {Request#{network_identity => <<198:256>>},#{Key => Token}},
              {Request#{signing_public_key => <<199:256>>},#{Key => Token}},
              {Request#{not_after_ms => maps:get(not_after_ms,Request)+1},#{Key => Token}},
              {Request#{agent_genesis_anchor => <<200:256>>},#{}},
              {Request#{agent_namespace => <<"another-outcome-source">>},#{}},
              {Request#{mode => read},#{}}]),
        with_outcome_session(Ns,0,fun(Session,Bind,Ctx) ->
            ok = quod_proof_session:open(Session,<<1:128>>,{'\\+',Query},allowed,Ctx,
                                         quod_transaction_scope:empty_selection()),
            ?assertMatch({error,_},quod_proof_session:next(Session,<<1:128>>)),
            ?assertEqual([{committed_operation_outcome,2}],quod_proof_session:live_bridges(Session)),
            ok = quod_proof_session:open(Session,<<2:128>>,{assertz,{after_error,true}},allowed,Ctx,
                                         quod_transaction_scope:empty_selection()),
            ?assertMatch({solution,_},quod_proof_session:next(Session,<<2:128>>)),
            ?assertEqual({error,{non_transactional_dependency,{committed_operation_outcome,2}}},
                         quod_proof_session:seal(Session,Bind))
        end)
    end,true) end}.

with_outcome_session(Ns,Height,Fun) ->
    Anchor = quod_simplex:genesis_hash(Ns),
    Proof = <<112:256>>,
    _ = quod_proof_context:start(Proof,false,{Ns,Anchor},quod_time:mono_ms()+10000,anonymous),
    Session = quod_proof_session:start(
        quod_transaction_predicates:load(quod_runtime_predicates:load(quod_ct:committed_kb([]))),
        #{read_set => true}),
    try
        Fun(Session,#{target => {Ns,Anchor},origin => {Ns,Anchor},base_height => Height,
                      proof_id => Proof,principal => anonymous,request_binding => none},
            quod_predicates:proof_context(Ns,Height,undefined,[{Ns,Anchor}]))
    after
        quod_proof_session:stop(Session),
        quod_proof_context:stop(fun(_) -> ok end,fun(_) -> ok end)
    end.

competing_obstacle_edit_resolves_before_replacement_test_() ->
    {timeout,90,fun() ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,barrier}),
        try with_door(fun(F = #{namespace := Ns}) ->
            _ = enable(F),true = quod_reg:subscribe({runtime,Ns}),
            Id = <<103:256>>,R = {close,1,Id},
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,0,Id})),
            Proof = receive {fipa_completion_prepared,P,_} -> P
                    after 10000 -> error(door_proof_not_paused) end,
            {ok,[#{'C' := {request,_,_,Bytes,Signature}}],_} =
                quod_prolog:prove_ro(Ns,{physics_hinged_request,room,10,{'C'}}),
            ?assertMatch({ok,_,{operation_pending,_}},quod_client_goal_ingress:resolve_operation(Bytes,Signature)),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                {physics_move_body,room,3,1,2,{vector,5000,1500,-500}})),
            Proof ! release,
            await_door_result(Ns,R,closed),
            ?assertMatch({ok,_,{operation_outcome,_,#{status := rejected}}},
                         quod_client_goal_ingress:resolve_operation(Bytes,Signature)),
            {ok,[#{'C' := {request,_,closed,NewBytes,_}}],_} =
                quod_prolog:prove_ro(Ns,{physics_hinged_request,room,10,{'C'}}),
            ?assertNotEqual(Bytes,NewBytes)
        end,true,fun(Rules) -> [case Rule of
            {':-',Head = {physics_finish_hinged,_,_},Body} ->
                {':-',Head,{',',Body,{';',{'->',{physics_structure,room,2},test_fipa_completion},true}}};
            _ -> Rule
        end || Rule <- Rules] end)
        after gproc:unreg(quod_reg:name({host_test,barrier})) end
    end}.

%% Races may emit intermediate pending/rejected states; completion is the
%% applied consequence event, never a send trace or a delay.
await_door_result(Ns,R,Result) ->
    receive
        {applied_live,#{ns := Ns,applied_ops := Ops}} ->
            case lists:member({event,{physics_hinged_finished,room,10,R,Result}},Ops) of
                true -> ok;
                false -> await_door_result(Ns,R,Result)
            end;
        {physics_status,_,_,_,_,{failed,Why}} -> error({door_failed,Why})
    after 15000 -> error({door_not_finished,
        maps:map(fun(_,#{pid := P,spec := S}) -> {gen_server:call(P,status),maps:with([generation,structure],S)} end,worlds(Ns)),
        quod_runtime:stats(Ns),request_result()}) end.

saturated_actor_retains_required_observation_test_() ->
    {timeout,90,fun() ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,barrier}),
        try with_door(fun(F = #{namespace := Ns}) ->
            {Pid,_} = enable(F),true = quod_reg:subscribe({runtime,Ns}),
            commit(Ns,{trigger_event,fill_work_queue}),
            receive {work_queue_admitted,Results} -> ?assertEqual(lists:duplicate(16,ok),Results)
            after 5000 -> error(queue_not_filled) end,
            First = receive {fipa_completion_prepared,P,_} -> P
                    after 5000 -> error(queue_not_running) end,
            Id = <<104:256>>,R = {close,1,Id},
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,0,Id})),
            %% Sleeping is emitted only after the native contact has braked.
            receive {physics_status,_,Pid,_,_,sleeping} -> ok
            after 10000 -> error(door_not_braked) end,
            ?assertMatch(#{observations := #{{hinge,10} := offered}},gen_server:call(Pid,status)),
            First ! release,
            lists:foreach(fun(_) ->
                receive {fipa_completion_prepared,Next,_} -> Next ! release
                after 5000 -> error(queue_not_drained) end
            end,lists:seq(1,15)),
            await_door_result(Ns,R,{blocked,3})
        end,true,fun(Rules) ->
            Ns = <<"host-test-agent">>,Principal = {agent_instance_ref,Ns,{'_'},actor},
            Rules ++ [{can_invoke,{',',test_fipa_completion,{record_ping,queued}},Principal,{'_'},Ns},
                {':-',{react_on,fill_work_queue,true},test_fill_work_queue}]
        end)
        after gproc:unreg(quod_reg:name({host_test,barrier})) end
    end}.

pending_door_restart_preserves_original_outcome_test_() ->
    [{atom_to_list(Outcome),{timeout,90,fun() -> pending_door_restart(Outcome) end}} ||
      Outcome <- [committed,rejected]].

pending_door_restart(Outcome) ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,barrier}),
        try with_door(fun(F = #{namespace := Ns}) ->
            {First,World} = enable(F),true = quod_reg:subscribe({runtime,Ns}),
            Id = <<105:256>>,R = {close,1,Id},
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,0,Id})),
            Proof = receive {fipa_completion_prepared,P,_} -> P
                    after 10000 -> error(door_proof_not_paused) end,
            {ok,[#{'C' := {request,_,_,Bytes,Signature}}],_} =
                quod_prolog:prove_ro(Ns,{physics_hinged_request,room,10,{'C'}}),
            Monitor = monitor(process,First),exit(First,kill),
            receive {'DOWN',Monitor,process,First,killed} -> ok end,
            Second = receive {physics_status,_,P2,World,_,activating} when P2 =/= First -> P2
                     after 5000 -> error(successor_not_started) end,
            ?assertMatch({ok,_,{operation_pending,_}},quod_client_goal_ingress:resolve_operation(Bytes,Signature)),
            Result = case Outcome of
                committed -> {blocked,3};
                rejected ->
                    ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                        {physics_move_body,room,3,1,2,{vector,5000,1500,-500}})),
                    closed
            end,
            Proof ! release,
            await_door_result(Ns,R,Result),
            {Second,World} = installed(Ns),
            ?assertMatch({ok,_,{operation_outcome,_,#{status := Outcome}}},
                         quod_client_goal_ingress:resolve_operation(Bytes,Signature)),
            {ok,[#{'C' := {request,_,_,SavedBytes,_}}],_} =
                quod_prolog:prove_ro(Ns,{physics_hinged_request,room,10,{'C'}}),
            case Outcome of
                committed -> ?assertEqual(Bytes,SavedBytes);
                rejected -> ?assertNotEqual(Bytes,SavedBytes)
            end
        end,true,fun(Rules) -> [case Rule of
            {':-',Head = {physics_finish_hinged,_,_},Body} ->
                {':-',Head,{',',Body,{';',{'->',{physics_run,room,1,{'_'}},test_fipa_completion},true}}};
            _ -> Rule
        end || Rule <- Rules] end)
        after gproc:unreg(quod_reg:name({host_test,barrier})) end.

pending_custody_and_delayed_sample_cannot_finish_new_close_test_() ->
    {timeout,90,fun() -> with_door(fun(F = #{namespace := Ns}) ->
        {Pid,World} = enable(F),true = quod_reg:subscribe({runtime,Ns}),
        #{World := #{spec := Spec}} = worlds(Ns),
        ok = sys:suspend(Pid),
        try
            Id = <<106:256>>,R = {close,1,Id},
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,0,Id})),
            At = quod_time:now_ms(),Expiry = At+10000,
            Sample = test_hinge_sample(Spec,2,R,1,500,{contact,3,1},At,Expiry),
            %% Every forged/stale component is rejected even with the real
            %% physics actor's signature and an otherwise exact goal binding.
            Frame = element(2,Sample), WorldRef = element(2,Frame),
            Invalid = [setelement(2,Sample,setelement(2,Frame,setelement(2,WorldRef,<<"other-world">>))),
                setelement(2,Sample,setelement(2,Frame,setelement(3,WorldRef,<<99:256>>))),
                setelement(2,Sample,setelement(2,Frame,setelement(4,WorldRef,other_space))),
                setelement(2,Sample,setelement(3,Frame,maps:get(node,F))),
                setelement(2,Sample,setelement(4,Frame,2)),
                setelement(3,Sample,{activity,{hinge,10,1},R,hinged_command(0)}),
                setelement(3,Sample,{activity,{hinge,10,2},{close,2,Id},hinged_command(0)}),
                setelement(3,Sample,{activity,{hinge,10,2},R,hinged_command(100)}),
                setelement(4,Sample,{revisions,[{body,10,2},{body,11,2}]}),
                setelement(7,Sample,{rest_pose_mm_quaternion_million,{pose,{vector,0,0,0},{quaternion,0,0,0,1000000}}}),
                setelement(2,Sample,setelement(5,Frame,0)),
                setelement(2,Sample,setelement(6,Frame,<<99:256>>)),
                setelement(2,Sample,setelement(7,Frame,1)),
                setelement(4,Sample,{revisions,[{joint,10,2},{body,10,1},{body,11,2}]}),
                setelement(5,Sample,0),
                setelement(7,Sample,{joint_position_mrad,500,{contact,3,99}}),
                setelement(6,Sample,{validity,At,Expiry+1})],
            lists:foreach(fun(Bad) ->
                {B,SG} = sign_fixture(F,{physics_finish_hinged,Bad,{blocked,3}},Expiry),
                {SB,SS} = sign_fixture(F,{physics_store_hinged_request,Bad,{blocked,3},B,SG},Expiry),
                ?assertMatch({ok,_,{normalized,{failed,_}}},quod_client_goal_ingress:submit(SB,SS))
            end,Invalid),
            {Bytes,Sig} = sign_fixture(F,{physics_finish_hinged,Sample,{blocked,3}},Expiry),
            Store = {physics_store_hinged_request,Sample,{blocked,3},Bytes,Sig},
            {StoreBytes,StoreSig} = sign_fixture(F,Store,Expiry),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},quod_client_goal_ingress:submit(StoreBytes,StoreSig)),
            NewSample = setelement(5,Sample,2),
            {NewBytes,NewSig} = sign_fixture(F,{physics_finish_hinged,NewSample,{blocked,3}},Expiry),
            {ReplaceBytes,ReplaceSig} = sign_fixture(F,
                {physics_store_hinged_request,NewSample,{blocked,3},NewBytes,NewSig},Expiry),
            %% An absent outcome raises a typed unavailable error rather than
            %% proving absence. The public boundary conservatively normalizes it.
            ?assertMatch({ok,_,{normalized,{error,proof_unavailable}}},quod_client_goal_ingress:submit(ReplaceBytes,ReplaceSig)),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                {physics_move_body,room,3,1,2,{vector,1500,1500,-500}})),
            %% Edit after store but before the original proof: no transaction
            %% entered ordering, so exact resolution must remain unknown.
            ?assertMatch({ok,_,{normalized,{failed,_}}},quod_client_goal_ingress:submit(Bytes,Sig)),
            ?assertMatch({ok,_,{operation_pending,_}},quod_client_goal_ingress:resolve_operation(Bytes,Sig)),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_cancel_hinged,room,10,R})),
            ?assertNotMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Ns,{physics_close_hinged,room,10,1,Id})),
            ?assertMatch({ok,_,{operation_pending,_}},quod_client_goal_ingress:resolve_operation(Bytes,Sig)),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                {physics_move_hinged,room,10,1,3,{vector,0,1500,0}})),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,1,Id})),
            ?assertNotMatch({ok,_,{normalized,{committed,_,_}}},quod_client_goal_ingress:submit(Bytes,Sig)),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_hinged,room,10,2,{closing,{close,2,Id}}})),
            %% The reaction event pattern alone never supplies private owner authority.
            commit(Ns,{trigger_event,{observed,NewSample}})
        after sys:resume(Pid) end,
        await_door_result(Ns,{close,2,<<106:256>>},{blocked,3})
    end,true) end}.

shared_class_is_authorized_then_materialized_locally_test_() ->
    {timeout,90,fun() -> with_world(fun(F = #{namespace := Ns,node := Node}) ->
        {agent_instance_ref,ClassNs,ClassAnchor,_} = Node,
        Definition = hinged_recipe(),
        Class = {physics_hinged_class,shared_door,1,Definition},
        commit(ClassNs,{assertz,Class}),
        Source = {class_ref,ClassNs,ClassAnchor,shared_door,1},
        Add = {physics_add_hinged,room,10,11,Source,{vector,0,1500,0},1},
        %% Hosting the class ontology conveys no query authority.
        ?assertMatch({ok,_,{normalized,{failed,_}}},door_action(Ns,Add)),
        Query = {',',{current_ontology_identity,ClassNs,ClassAnchor},{physics_hinged_class,shared_door,1,{'_'}}},
        Grant = {can_invoke,Query,Node,{'_'},ClassNs},
        commit(ClassNs,{assertz,Grant}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,Add)),
        commit(ClassNs,{',',{retract,Grant},{retract,Class}}),
        {Pid,World} = enable(F),
        #{World := #{pid := Pid,spec := #{hinges := [_],structure := 2}}} = worlds(Ns),
        [reconcile(Ns) || _ <- lists:seq(1,3)],
        ?assertMatch(#{installs := 1},gen_server:call(Pid,status)),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_hinged_source,room,10,Source}))
    end,fun(Rules) -> Rules ++ [{can_edit_physics,room,{'_'}}] end) end}.

expired_queued_observation_is_freshly_sampled_test_() ->
    [{atom_to_list(Name),{timeout,90,fun() -> queued_observation_expiry(Admitted) end}} ||
      {Name,Admitted} <- [{runtime_cursor,false},{actor_queue,true}]].

queued_observation_expiry(Admitted) ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,barrier}),
        try with_door(fun(F = #{namespace := Ns}) ->
            {Pid,_} = enable(F),true = quod_reg:subscribe({runtime,Ns}),
            commit(Ns,{',',{retract,{physics_allowances,room,{limits,64,64,256,1000000,{geometry,256,4096,4096}},16667,-9810,10000}},
                {assertz,{physics_allowances,room,{limits,64,64,256,1000000,{geometry,256,4096,4096}},16667,-9810,1000}}}),
            reconcile(Ns),
            Runtime = quod_reg:where({quod_runtime,Ns}),Parent = self(),Tag = make_ref(),
            Observe = fun(State,{in,{physics_observation,P,_,_,_,Sample,_}},_) when P =:= Pid ->
                              Parent ! {sample_seen,Tag,element(5,Sample),element(6,Sample)},State;
                         (State,_,_) -> State end,
            Accepted = fun(State,{in,{physics_admitted,_,_}},_) ->
                               Parent ! {sample_admitted,Tag},State;
                          (State,_,_) -> State end,
            ok = sys:install(Runtime,{Observe,none}),
            ok = sys:install(Pid,{Accepted,none}),
            try
                commit(Ns,{trigger_event,fill_work_queue}),
                receive {work_queue_admitted,Results} -> ?assertEqual(lists:duplicate(16,ok),Results)
                after 5000 -> error(queue_not_filled) end,
                First = receive {fipa_completion_prepared,Running,_} -> Running
                        after 5000 -> error(queue_not_running) end,
                case Admitted of
                    true ->
                        First ! release,
                        receive {fipa_completion_prepared,_,_} -> ok
                        after 5000 -> error(second_not_running) end;
                    false -> ok
                end,
                Id = <<107:256>>,R = {close,1,Id},
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,0,Id})),
                {Tick,Expiry} = receive {sample_seen,Tag,T,{validity,_,E}} -> {T,E}
                               after 5000 -> error(sample_not_offered) end,
                case Admitted of
                    true -> receive {sample_admitted,Tag} -> ok
                            after 1000 -> error(sample_not_admitted) end;
                    false -> ok
                end,
                %% The held work reaches its original execution deadline. This
                %% real capacity edge consumes the expired cursor and resamples.
                await_door_result(Ns,R,{blocked,3}),
                {ok,[#{'C' := {request,Sample,_,_,_}}],_} =
                    quod_prolog:prove_ro(Ns,{physics_hinged_request,room,10,{'C'}}),
                ?assert(element(5,Sample) > Tick),
                {validity,NewAt,_} = element(6,Sample),?assert(NewAt >= Expiry)
            after sys:remove(Runtime,Observe),sys:remove(Pid,Accepted) end
        end,true,fun(Rules) ->
            Ns = <<"host-test-agent">>,Principal = {agent_instance_ref,Ns,{'_'},actor},
            Rules ++ [{can_invoke,{',',test_fipa_completion,{record_ping,queued}},Principal,{'_'},Ns},
                {':-',{react_on,fill_work_queue,true},test_fill_work_queue}]
        end)
        after gproc:unreg(quod_reg:name({host_test,barrier})) end.

full_event_queue_keeps_wake_after_hinge_sleeps_test_() ->
    {timeout,90,fun() ->
        Saved = application:get_env(quod,runtime_max_queued_events),
        try with_door(fun(F = #{namespace := Ns}) ->
            {Pid,_} = enable(F),true = quod_reg:subscribe({runtime,Ns}),
            Parent = self(),Tag = make_ref(),Runtime = quod_reg:where({quod_runtime,Ns}),
            Pause = fun(none,{in,{physics_selected,_,_,#{activities := #{{hinge,10} := #{request := {close,_,_}}}}}},_) ->
                            Parent ! {closing_selected,Tag,self()},receive release -> held end;
                       (State,_,_) -> State end,
            Queued = fun(State,{in,{'$gen_call',_,{reconcile_resource,_,physics_worlds,future,_}}},_) ->
                              Parent ! {future_queued,Tag},State;
                        (State,_,_) -> State end,
            ok = sys:install(Pid,{Pause,none}),ok = sys:install(Runtime,{Queued,none}),
            try
                Id = <<108:256>>,R = {close,1,Id},
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,0,Id})),
                receive {closing_selected,Tag,Pid} -> ok after 5000 -> error(close_not_selected) end,
                Base = maps:get(queue_len,quod_runtime:stats(Ns)),
                application:set_env(quod,runtime_max_queued_events,Base+1),
                Caller = spawn(fun() -> quod_runtime:reconcile_resource(Ns,quod_prolog:applied(Ns)+100,
                    physics_worlds,future,quod_time:mono_ms()+30000) end),
                receive {future_queued,Tag} -> ok after 5000 -> error(future_not_queued) end,
                ?assertEqual(Base+1,maps:get(queue_len,quod_runtime:stats(Ns))),
                Pid ! release,
                receive {physics_status,_,Pid,_,_,observation_capacity} -> ok
                after 5000 -> error(observation_not_refused) end,
                receive {physics_status,_,Pid,_,_,sleeping} -> ok
                after 5000 -> error(held_hinge_not_sleeping) end,
                ?assertMatch(#{observations := #{{hinge,10} := capacity}},gen_server:call(Pid,status)),
                case Saved of undefined -> application:unset_env(quod,runtime_max_queued_events);
                              {ok,Limit} -> application:set_env(quod,runtime_max_queued_events,Limit) end,
                exit(Caller,kill),
                await_door_result(Ns,R,{blocked,3})
            after Pid ! release,sys:remove(Pid,Pause),sys:remove(Runtime,Queued) end
        end,true)
        after case Saved of undefined -> application:unset_env(quod,runtime_max_queued_events);
                            {ok,V} -> application:set_env(quod,runtime_max_queued_events,V) end end
    end}.

sleeping_does_not_erase_explicit_reconciliation_test_() ->
    {timeout,90,fun() -> with_door(fun(F = #{namespace := Ns}) ->
        {Pid,World} = enable(F),true = quod_reg:subscribe({runtime,Ns}),
        #{World := #{spec := Spec}} = worlds(Ns),
        Runtime = quod_reg:where({quod_runtime,Ns}),
        Parent = self(),Tag = make_ref(),
        Observe = fun(State,{in,{physics_selected,_,_,_}},_) ->
                          Parent ! {selection_processed,Tag},State;
                     (State,_,_) -> State end,
        ok = sys:install(Pid,{Observe,none}),
        try
            Runtime ! {physics_status,Pid,World,maps:get(run_token,Spec),{unavailable,resolve}},
            Runtime ! {physics_status,Pid,World,maps:get(run_token,Spec),sleeping},
            _ = quod_runtime:stats(Ns),
            reconcile(Ns),
            receive {selection_processed,Tag} -> ok
            after 5000 -> error(reconciliation_lost_after_sleep) end
        after sys:remove(Pid,Observe) end
    end,true) end}.

generic_observation_clause_cannot_consume_door_request_test_() ->
    {timeout,90,fun() -> with_door(fun(F = #{namespace := Ns}) ->
        _ = enable(F),true = quod_reg:subscribe({runtime,Ns}),
        Id = <<109:256>>,R = {close,1,Id},
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,0,Id})),
        await_door_result(Ns,R,{blocked,3})
    end,true,fun(Rules) -> [{react_on,{observed,{'_'}},true}|Rules] end) end}.

%% A terminally rejected original remains in durable custody until its new
%% signed request is stored. Expiry of the unsigned replacement must still
%% obtain a fresh native sample. Exercise the real owner message protocol.
expired_replacement_observation_resamples_test_() ->
    {timeout,20,fun() -> with_door_simulator(true,fun(Pid,_,Token) ->
        {First,Tick} = door_sample_message(Pid,Token),
        Pid ! {physics_result,self(),First,{error,expired_observation}},
        {Second,NextTick} = door_sample_message(Pid,Token),
        ?assertNotEqual(First,Second), ?assert(NextTick > Tick)
    end) end}.

observation_edit_delivery_order_test_() ->
    observation_edit_delivery_order(#{structure => 2}).

observation_budget_delivery_order_test_() ->
    observation_edit_delivery_order(#{budget => 2500}).

observation_command_delivery_order_test_() ->
    observation_edit_delivery_order(control).

observation_edit_delivery_order(Change) ->
    [{lists:flatten(io_lib:format("~p/~p/~p",[Saved,Order,Result])),{timeout,20,fun() ->
        with_door_simulator(Saved,fun(Pid,Spec,Token) ->
            {First,Tick} = door_sample_message(Pid,Token),
            Changed = case Change of
                control ->
                    Activities = maps:get(activities,Spec), Activity = maps:get({hinge,10},Activities),
                    Spec#{activities => Activities#{{hinge,10} => Activity#{command => hinged_command(100),
                        native_command => {position,0.1,{100.0,10.0,1000.0},{0.02,target_or_contact}}}}};
                _ -> maps:merge(Spec,Change)
            end,
            Select = {physics_selected,self(),make_ref(),Changed},
            Reply = {physics_result,self(),First,Result},
            case Order of
                selection_first -> Pid ! Select, Pid ! Reply;
                result_first -> Pid ! Reply, Pid ! Select
            end,
            case Saved of true -> reject_door_resolve(Pid); false -> ok end,
            {Second,NextTick} = door_sample_message(Pid,Token),
            ?assertNotEqual(First,Second), ?assert(NextTick > Tick)
        end)
    end}} || Saved <- [false,true], Order <- [selection_first,result_first],
           Result <- [{error,stale_observation},{error,{request_not_submitted,refused}},
                      {error,unmatched},{error,{reaction_guard,refused}},
                      {error,invalid_reaction_request},{error,stale_executor}]].

actor_queue_expiry_resamples_test() ->
    with_door_simulator(false,fun(Pid,_,Token) ->
        {First,Tick} = door_sample_message(Pid,Token),
        Pid ! {physics_admitted,self(),First},
        Pid ! {physics_result,self(),First,{error,{request_not_submitted,deadline_exceeded}}},
        {Second,NextTick} = door_sample_message(Pid,Token),
        ?assertNotEqual(First,Second), ?assert(NextTick > Tick)
    end).

door_sample_message(Pid,Token) ->
    receive {physics_observation,Pid,_,Token,Ref,Sample,_} -> {Ref,element(5,Sample)}
    after 1000 -> error(required_observation_lost) end.

reject_door_resolve(Pid) ->
    Resolve = physics_work(Pid,resolve),
    Pid ! {physics_result,self(),Resolve,{ok,ignored,{operation_outcome,ignored,#{status => rejected}}}}.

with_door_simulator(SavedCustody,Fun) ->
    with_simulator(none,fun(Pid,Spec) ->
        {Activation,Token} = receive
            {physics_work,Pid,_,A,activate,{{physics_activate,room,0,T},_,_},_} -> {A,T}
        after 5000 -> error(activation_missing) end,
        R = {close,1,<<111:256>>},
        Sample = test_hinge_sample(Spec#{generation => 1,run_token => Token,structure => 1},
            1,R,1,0,clear,quod_time:now_ms(),quod_time:now_ms()+5000),
        Saved = case SavedCustody of true -> {request,Sample,closed,<<1>>,<<0:512>>}; false -> none end,
        Current = Spec#{generation => 1,run_token => Token,
            custody => {request,Token,0,<<2>>,<<0:512>>},
            limits => {2,2,1,100.0,2,0,0},dt => 1/60,gravity => 0.0,structure => 1,
            bodies => [{10,1,dynamic,{world_mm,{0,1000,0},{0.0,0.0,0.0}},{solid,{box,1.0,1.0,0.1}},1.0},
                       {11,1,fixed,{world_mm,{0,1000,0},{0.0,0.0,0.0}},{solid,{box,0.05,1.0,0.05}},1.0}],
            hinges => [{{{10,1},1,{11,1},{0.0,1.0,0.0},{{0.0,0.0,0.0},{-1.0,0.0,0.0}},
                         {-1.5,1.5},1.5},0.0}],
            activities => #{{hinge,10} => #{reference => {hinge,10,1},request => R,
                command => hinged_command(0),native_command => {position,0.0,{100.0,10.0,1000.0},{0.02,target_or_contact}},
                references => [{joint,10,1},{body,10,1},{body,11,1}],custody => Saved,outcome_key => none}}},
        Pid ! {physics_selected,self(),make_ref(),Current},
        Pid ! {physics_result,self(),Activation,{ok,ignored,{normalized,{committed,ignored,ignored}}}},
        case SavedCustody of true -> reject_door_resolve(Pid); false -> ok end,
        Fun(Pid,Current,Token)
    end).


same_namespace_signed_chair_push_test_() ->
    {timeout,60,fun() -> with_chair(fun(F = #{namespace := Ns,identity := Identity}) ->
        {Pid,World} = enable(F),
        Anchor = quod_simplex:genesis_hash(Ns),
        Principal = {agent_instance_ref,Ns,Anchor,viewer},
        commit(Ns,{assertz,{agent_key,viewer,maps:get(pubkey,Identity),active}}),
        {_,_,_,OldRef,_} = install_test_control(F#{node => Principal},Pid,World,
            {motion,free,2000,1600,1000,{query_limits,2,0,8,128},[]}),
        quod_physics:unwatch(Pid,OldRef), _ = gen_server:call(Pid,status),
        commit(Ns,{assertz,{can_view_physics,room,Principal}}), reconcile(Ns),
        Parent = self(), Socket = spawn_link(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
        try
            Socket ! {client,simulation_open(F,simulation_session(Identity),Principal)},
            Projection = simulation_reply(Socket,<<"projection">>),
            #{control := Control} = simulation_state(Socket),
            #{World := #{spec := Spec}} = worlds(Ns),
            Frame = {physics_frame,World,maps:get(authority,Spec),maps:get(epoch,Spec),
                maps:get(generation,Spec),maps:get(run_token,Spec),maps:get(structure,Spec)},
            Initial = maps:get(<<"frame">>,Projection),
            Registration = base64:decode(maps:get(<<"registration">>,Initial),#{mode => urlsafe,padding => false}),
            Goal = {'::',Ns,{',',{current_ontology_identity,Ns,Anchor},
                {physics_control_input,room,{control_frame,Frame,Registration},
                    1,1,{push,{body,3,1},{vector,1000,0,0}},{0}}}},
            {Canonical,_,_} = erlog_int:term_instance(Goal,0),
            {ok,Text} = quod_client_goal_parser:format(Canonical),
            Request = #{network_identity => <<42:256>>,
                agent_namespace => Ns,agent_genesis_anchor => Anchor,agent_instance_text => <<"viewer.">>,
                signing_public_key => maps:get(pubkey,Identity),operation_id => crypto:strong_rand_bytes(32),
                not_after_ms => quod_time:now_ms()+10000,mode => control,parser_version => 3,goal_text => Text},
            {Both,_,_} = erlog_int:term_instance({',',Goal,Goal},0),
            {ok,BothText} = quod_client_goal_parser:format(Both),
            {ok,BothBytes} = quod_client_goal:encode(Request#{goal_text => BothText}),
            assert_reason(transient_already_staged,
                quod_client_goal_ingress:submit(BothBytes,quod_identity:sign(BothBytes,Identity))),
            ?assertMatch(#{inputs := Empty} when map_size(Empty) =:= 0,gen_server:call(Pid,status)),
            {ok,Bytes} = quod_client_goal:encode(Request#{operation_id => crypto:strong_rand_bytes(32)}),
            ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},
                quod_client_goal_ingress:submit(Bytes,quod_identity:sign(Bytes,Identity))),
            ?assertMatch(#{inputs := #{Principal := #{sequence := 1}}},gen_server:call(Pid,status)),
            {ok,DuplicateBytes} = quod_client_goal:encode(Request#{operation_id => crypto:strong_rand_bytes(32)}),
            {ok,_,{normalized,{failed,DuplicateReasons}}} =
                quod_client_goal_ingress:submit(DuplicateBytes,quod_identity:sign(DuplicateBytes,Identity)),
            ?assertEqual({ok,[{stale_sequence,1}]},quod_wire_term:decode_failure_reasons(DuplicateReasons)),
            View = maps:get(<<"view">>,Projection),
            simulation_ack(Socket,View,Initial),
            _ = simulation_input_frame(Socket,View,<<"1">>),
            Expected = #{fence => quod_physics:fence(Spec),incarnation => maps:get(run_token,Spec),structure => 1},
            {ok,_,{0,0,0},{3,1,world,{X,_,_},_,_}} = quod_physics:body_state(Pid,Expected,{3,1},1000),
            ?assert(X > 0),
            ?assertMatch({control,Principal,_,_},Control)
        after Socket ! stop end
    end) end}.

simulation_ack(Socket,View,Frame) ->
    Socket ! {client,iolist_to_binary(json:encode(#{type => ack,origin_seq => <<"0">>,view => View,tick => maps:get(<<"tick">>,Frame)}))}.

simulation_input_frame(Socket,View,Sequence) ->
    Delivered = simulation_reply(Socket,<<"simulation_frame">>),
    Frame = maps:get(<<"frame">>,Delivered),
    simulation_ack(Socket,View,Frame),
    case maps:get(<<"control_state">>,Frame) of
        #{<<"sequence">> := Sequence,<<"pending">> := false,<<"result">> := <<"pushed">>} -> Frame;
        _ -> simulation_input_frame(Socket,View,Sequence)
    end.

signed_chair_push_checkpoint_and_recovery_test_() ->
    {timeout,90,fun() -> with_chair(fun(F = #{namespace := Ns,node := Human}) ->
        {Pid,World} = enable(F), true = quod_reg:subscribe({runtime,Ns}),
        try
            {_,Expected,OldFrame,_,_} = install_test_control(F,Pid,World,
                {motion,free,2000,1600,1000,{query_limits,2,0,8,128},[]}),
            Push = {push,{body,3,1},{vector,1000,0,0}},
            Send = fun(Fence,Seq,Input) -> control_goal({'::',Ns,
                {physics_control_input,room,Fence,1,Seq,Input,{0}}}) end,
            OldCommand = fun(Seq,Input) -> Send(OldFrame,Seq,Input) end,
            ?assertMatch({ok,_,{normalized,{failed,_}}},OldCommand(0,{push,{body,3,0},{vector,1000,0,0}})),
            ?assertMatch({ok,_,{normalized,{failed,_}}},OldCommand(0,{push,{body,3,1},{vector,5001,0,0}})),
            commit(Ns,{retract,{can_push_physics_body,room,{'_'},3}}), reconcile(Ns),
            ?assertMatch({ok,_,{normalized,{failed,_}}},OldCommand(0,Push)),
            commit(Ns,{assertz,{can_push_physics_body,room,{'_'},3}}), reconcile(Ns),
            assert_reason(stale_registration,OldCommand(1,Push)),
            {ok,Ref,Initial} = quod_physics:watch(Pid,Expected,none),
            Frame = setelement(3,OldFrame,maps:get(registration,Initial)),
            Command = fun(Seq,Input) -> Send(Frame,Seq,Input) end,
            ?assertMatch({ok,_,{normalized,{failed,_}}},control_goal({'::',Ns,
                {',',{physics_control_input,room,Frame,1,1,Push,{0}},fail}})),
            ?assertMatch(#{inputs := M} when map_size(M) =:= 0,gen_server:call(Pid,status)),
            quod_physics:ack(Pid,Ref,maps:get(tick,Initial),maps:get(origin_sequence,Initial)),
            ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(1,Push)),
            {Moved,pushed} = input_frame(Pid,Ref,Human,1),
            {3,1,world,{X,_,_},_,{Vx,_,_}} = lists:keyfind(3,1,maps:get(poses,Moved)),
            ?assert(X > 0.0), ?assert(Vx > 0.0),
            ?assertNotMatch({ok,_,{normalized,{answers,_,[_]}}},Command(1,Push)),
            %% Individually bounded impulses must also respect resulting speed.
            ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(2,
                {push,{body,3,1},{vector,5000,0,0}})),
            {_,refused} = input_frame(Pid,Ref,Human,2),
            %% Appearance and unchanged resource installation cannot reset the body.
            commit(Ns,{assertz,{chair_label,<<"Moved chair">>}}), reconcile(Ns),
            {ok,_,{0,0,0},{3,1,world,{Later,_,_},_,_}} = quod_physics:body_state(Pid,Expected,{3,1},1000),
            ?assert(Later >= X),
            R = {rest,1,<<201:256>>},
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Ns,{physics_checkpoint_body,room,3,1,0,<<201:256>>})),
            await_rest(Ns,R), reconcile(Ns),
            FirstCP = rest_checkpoint_fact(Ns),
            %% Explicitly checkpointing an unchanged sleeping chair still
            %% requires a new sample; routine reconciliation requires no work.
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Ns,{physics_checkpoint_body,room,3,1,1,<<205:256>>})),
            await_rest(Ns,{rest,2,<<205:256>>}), reconcile(Ns),
            CP = rest_checkpoint_fact(Ns),
            ?assert(element(7,element(4,CP)) > element(7,element(4,FirstCP))),
            {rest_v1,3,1,_,world_mm_quaternion_million,{pose,{vector,SavedX,_,_},_},zero_velocity} = CP,
            ?assert(SavedX > 0),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
                {physics_body_definition, room, 3, 1, dynamic, {vector,0,500,0}, {owned, {box,500,500,500}, 1}})),
            {ok,[#{'C' := {request,Sample,rest,Bytes,Signature}}],_} =
                quod_prolog:prove_ro(Ns,{physics_rest_request,room,3,{'C'}}),
            ?assertMatch({ok,_,{operation_outcome,_,#{status := committed}}},
                quod_client_goal_ingress:resolve_operation(Bytes,Signature)),
            ?assertMatch({ok,_,{normalized,{failed,_}}},submit_fixture(F,{physics_finish_rest,Sample})),
            Before = gen_server:call(Pid,status),
            assert_no_physics_io(fun() ->
                [reconcile(Ns) || _ <- lists:seq(1,3)],
                ?assertEqual(maps:with([installs,steps],Before),
                    maps:with([installs,steps],gen_server:call(Pid,status)))
            end),
            %% A second, uncheckpointed push is deliberately lost on runtime
            %% collapse. Recovery must use the rest checkpoint, not this motion.
            {ok,ResumeRef,ResumeView} = quod_physics:watch(Pid,Expected,none),
            ResumeFrame = setelement(3,Frame,maps:get(registration,ResumeView)),
            quod_physics:ack(Pid,ResumeRef,maps:get(tick,ResumeView),maps:get(origin_sequence,ResumeView)),
            ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Send(ResumeFrame,3,Push)),
            {Unsaved,pushed} = input_frame(Pid,ResumeRef,Human,3),
            {3,1,world,{UnsavedX,_,_},_,{UnsavedVx,_,_}} = lists:keyfind(3,1,maps:get(poses,Unsaved)),
            ?assert(UnsavedX > SavedX/1000), ?assert(UnsavedVx > 0),
            Monitor = monitor(process,Pid), exit(quod_reg:where({quod_runtime,Ns}),kill),
            receive {'DOWN',Monitor,process,Pid,_} -> ok after 5000 -> error(chair_owner_alive) end,
            {Next,World} = installed(Ns), ?assertNotEqual(Pid,Next),
            #{World := #{spec := Spec}} = worlds(Ns),
            ?assert(maps:get(generation,Spec) > element(5,element(2,Frame))),
            Fresh = #{fence => quod_physics:fence(Spec),structure => 1,incarnation => maps:get(run_token,Spec)},
            {ok,_,{0,0,0},{3,1,world,{RestoredX,_,_},_,_}} = quod_physics:body_state(Next,Fresh,{3,1},1000),
            ?assert(abs(RestoredX-SavedX/1000) < 0.002),
            ?assertNotMatch({ok,_,{normalized,{answers,_,[_]}}},Command(3,Push)),
            ?assertMatch(#{inputs := M} when map_size(M) =:= 0,gen_server:call(Next,status)),
            %% Editing owns the baseline and checkpoint invalidation in one commit.
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                {physics_move_body,room,3,1,1,{vector,4000,500,0}})),
            ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_checkpoint,room,CP})),
            {Next,World} = installed(Ns),
            {ok,_,{0,0,0},{3,2,world,{EditX,_,_},_,_}} = quod_physics:body_state(Next,Fresh#{structure => 2},{3,2},1000),
            ?assert(abs(EditX-4.0) < 0.001)
        after catch quod_reg:unsubscribe({runtime,Ns}) end
    end) end}.

with_chair(Fun) -> with_chair(Fun,fun(Rules) -> Rules end).
with_chair(Fun,Transform) -> with_world(Fun,fun(Rules) ->
    Ns = <<"host-test-agent">>, Actor = {agent_instance_ref,Ns,{'_'},actor},
    Transform([case R of {physics_body_definition, room, 2, 1, _, _, {owned, _, _}} ->
        {physics_body_definition, room, 2, 1, controlled, {vector,-3000,1000,0}, {owned, {box,500,1000,500}, 1}}; _ -> R end || R <- Rules] ++
    [{physics_body_definition, room, 3, 1, dynamic, {vector,0,500,0}, {owned, {box,500,500,500}, 1}},
     {can_push_physics_body,room,{'_'},3},
     {physics_push_allowances,room,{'_'},3,{push_limits,5000,5000}},
     {can_checkpoint_physics_body,room,3,{'_'}}, {physics_rest_policy,room,3,{recovery,5,128}},
     {can_edit_physics,room,{'_'}},
     {can_invoke,{physics_store_rest_request,{'_'},{'_'},{'_'}},Actor,{'_'},Ns},
     {can_invoke,{physics_finish_rest,{'_'}},Actor,{'_'},Ns}])
end).

rest_checkpoint_fact(Ns) ->
    {ok,[#{'C' := CP}],_} = quod_prolog:prove_ro(Ns,{physics_checkpoint,room,{'C'}}), CP.
await_rest(Ns,R) ->
    receive
        {applied_live,#{ns := Ns,applied_ops := Ops}} ->
            case lists:member({event,{physics_body_checkpointed,room,3,R}},Ops) of
                true -> ok; false -> await_rest(Ns,R)
            end;
        {physics_status,_,_,_,_,{failed,Why}} -> error({rest_failed,Why});
        {physics_status,_,_,_,_,{observation,{rest,3},State}} when State =/= committed ->
            error({rest_observation_failed,State,request_result()})
    after 15000 -> error({rest_not_finished,worlds(Ns),request_result()}) end.

native_rest_recovery_rejects_overlap_and_bad_rotation_test() ->
    Ground = {1,1,fixed,{{0.0,-0.5,0.0},{0.0,0.0,0.0}},{solid,{box,10.0,0.5,10.0}},1.0},
    Chair = {2,1,dynamic,{{0.0,0.5,0.0},{0.0,0.0,0.0}},{solid,{box,0.5,0.5,0.5}},1.0},
    Wall = {3,1,fixed,{{2.0,0.5,0.0},{0.0,0.0,0.0}},{solid,{box,0.5,0.5,0.5}},1.0},
    lists:foreach(fun({Rows,Pose}) ->
        {ok,Resource} = quod_physics_native:new_world({3,3,4,100.0,64,1024,1024},1/60,-9.81),
        {ok,_} = quod_physics_native:install(Resource,{0,0,0},Rows),
        ?assertEqual({error,invalid_checkpoint},quod_physics_native:restore_rest(Resource,[{2,1,Pose,0.005,128}])),
        ?assertEqual({error,retired},quod_physics_native:sample(Resource))
    end,[{[Ground,Chair,Wall],{{2.0,0.5,0.0},{0.0,0.0,0.0,1.0}}},
         {[Ground,Chair],{{2.0,0.5,0.0},{0.0,0.0,0.0,0.0}}}]).

rest_recovery_overlap_fails_visibly_test_() ->
    {timeout,60,fun() -> with_chair(fun(F = #{namespace := Ns}) ->
        {Pid,World} = enable(F),
        #{World := #{spec := Spec}} = worlds(Ns),
        Source = {source,maps:get(authority,Spec),maps:get(epoch,Spec),maps:get(generation,Spec),
                  maps:get(run_token,Spec),1,1},
        %% The live chair keeps its current pose; only its successor restores.
        CP = {rest_v1,3,1,Source,world_mm_quaternion_million,
              {pose,{vector,-3000,1000,0},{quaternion,0,0,0,1000000}},zero_velocity},
        commit(Ns,{assertz,{physics_checkpoint,room,CP}}), reconcile(Ns),
        Monitor = monitor(process,Pid), exit(Pid,kill),
        receive {'DOWN',Monitor,process,Pid,killed} -> ok after 5000 -> error(chair_owner_alive) end,
        receive {physics_status,_,Next,World,_,{failed,invalid_checkpoint}} when Next =/= Pid ->
            ?assertMatch(#{phase := {failed,invalid_checkpoint}},gen_server:call(Next,status)),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_checkpoint,room,CP}))
        after 10000 -> error(overlap_not_reported) end
    end) end}.

chair_edit_races_prepared_checkpoint_test_() ->
    {timeout,90,fun() ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,barrier}),
        try with_chair(fun(F = #{namespace := Ns}) ->
            {Pid,World} = enable(F), true = quod_reg:subscribe({runtime,Ns}),
            try
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                    {physics_checkpoint_body,room,3,1,0,<<202:256>>})),
                {Proof,Operation} = receive {fipa_completion_prepared,P,Op} -> {P,Op}
                        after 10000 -> error(rest_proof_not_paused) end,
                {ok,[#{'C' := Custody = {request,_,rest,Bytes,Signature}}],_} =
                    quod_prolog:prove_ro(Ns,{physics_rest_request,room,3,{'C'}}),
                ?assertMatch({ok,_,{operation_pending,_}},quod_client_goal_ingress:resolve_operation(Bytes,Signature)),
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                    {physics_move_body,room,3,1,1,{vector,4000,500,0}})),
                Proof ! release,
                receive {agent_request_finished,_,_,_,_,{ok,#{operation_ref := Operation},{normalized,{error,conflict_retry}}}} -> ok
                after 10000 -> error({rest_race_not_rejected,request_result()}) end,
                %% The client failure can precede terminal publication. Wait
                %% on applied progress; never infer rejection from that reply.
                await_checkpoint_rejection(Ns,Bytes,Signature,quod_time:mono_ms()+10000),
                ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_checkpoint,room,{'_'}})),
                ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_rest_request,room,3,Custody})),
                %% The cancelled request cannot be resampled or replayed on restart.
                Monitor = monitor(process,Pid), exit(Pid,kill),
                receive {'DOWN',Monitor,process,Pid,killed} -> ok after 5000 -> error(owner_alive) end,
                {Next,World} = installed(Ns),
                ?assertMatch(#{observations := O} when map_size(O) =:= 0,gen_server:call(Next,status))
            after catch quod_reg:unsubscribe({runtime,Ns}) end
        end,fun(Rules) -> [case Rule of
            {':-',Head = {physics_finish_rest,_},Body} -> {':-',Head,{',',Body,test_fipa_completion}};
            _ -> Rule end || Rule <- Rules] end)
        after gproc:unreg(quod_reg:name({host_test,barrier})) end
    end}.

chair_unknown_checkpoint_custody_is_not_resubmitted_test_() ->
    {timeout,60,fun() -> with_chair(fun(F = #{namespace := Ns}) ->
        {Pid,World} = enable(F),
        #{World := #{spec := Spec}} = worlds(Ns),
        ok = sys:suspend(Pid),
        try
            R = {rest,1,<<203:256>>},
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                {physics_checkpoint_body,room,3,1,0,<<203:256>>})),
            At = quod_time:now_ms(), Expiry = At+10000,
            Sample = {physics_sample,test_physics_frame(Spec),{activity,{rest,3,1},R,rest},
                {revisions,[{body,3,1}]},1,{validity,At,Expiry},
                {rest_pose_mm_quaternion_million,{pose,{vector,500,500,0},{quaternion,0,0,0,1000000}}}},
            {Bytes,Signature} = sign_fixture(F,{physics_finish_rest,Sample},Expiry),
            {Store,StoreSig} = sign_fixture(F,{physics_store_rest_request,Sample,Bytes,Signature},Expiry),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},quod_client_goal_ingress:submit(Store,StoreSig)),
            NewSample = setelement(5,Sample,2),
            {NewBytes,NewSig} = sign_fixture(F,{physics_finish_rest,NewSample},Expiry),
            {Replace,ReplaceSig} = sign_fixture(F,{physics_store_rest_request,NewSample,NewBytes,NewSig},Expiry),
            ?assertMatch({ok,_,{normalized,{error,proof_unavailable}}},quod_client_goal_ingress:submit(Replace,ReplaceSig)),
            ?assertMatch({ok,_,{operation_pending,_}},quod_client_goal_ingress:resolve_operation(Bytes,Signature))
        after sys:resume(Pid) end,
        reconcile(Ns),
        receive {physics_status,_,Pid,World,_,{unavailable,{observation,{rest,3},unresolved}}} -> ok
        after 10000 -> error(unknown_checkpoint_not_held) end,
        ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_checkpoint,room,{'_'}})),
        assert_no_physics_io(fun() -> [reconcile(Ns) || _ <- lists:seq(1,3)] end),
        {ok,[#{'C' := Original}],_} = quod_prolog:prove_ro(Ns,{physics_rest_request,room,3,{'C'}}),
        Monitor = monitor(process,Pid), exit(Pid,kill),
        receive {'DOWN',Monitor,process,Pid,killed} -> ok after 5000 -> error(chair_owner_alive) end,
        {Next,World} = installed(Ns),
        receive {physics_status,_,Next,World,_,{unavailable,{observation,{rest,3},unresolved}}} -> ok
        after 10000 -> error(recovered_unknown_not_held) end,
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_rest_request,room,3,Original})),
        ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_checkpoint,room,{'_'}})),
        %% An authored edit fences the old finish even if its backend outcome
        %% stays unknown. A distinct request must be able to checkpoint the edit.
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
            {physics_move_body,room,3,1,1,{vector,4000,500,0}})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_rest_request,room,3,Original})),
        {request,_,rest,OldBytes,OldSignature} = Original,
        ?assertMatch({ok,_,{operation_pending,_}},
            quod_client_goal_ingress:resolve_operation(OldBytes,OldSignature)),
        true = quod_reg:subscribe({runtime,Ns}),
        try
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                {physics_checkpoint_body,room,3,2,1,<<206:256>>})),
            await_rest(Ns,{rest,2,<<206:256>>}),
            ?assertMatch({rest_v1,3,2,_,_,_,_},rest_checkpoint_fact(Ns)),
            ?assertMatch({ok,_,{operation_pending,_}},
                quod_client_goal_ingress:resolve_operation(OldBytes,OldSignature))
        after catch quod_reg:unsubscribe({runtime,Ns}) end
    end) end}.

%% The real owner renews certainly-unsent rest evidence only after another
%% completed native step; no expiry is appended to an old sample identity.
expired_rest_observation_resamples_test_() ->
    {timeout,20,fun() -> with_simulator(none,fun(Pid,Spec) ->
        {Activation,Token} = receive
            {physics_work,Pid,_,A,activate,{{physics_activate,room,0,T},_,_},_} -> {A,T}
        after 5000 -> error(activation_missing) end,
        R = {rest,1,<<204:256>>},
        Current = Spec#{generation => 1,run_token => Token,
            custody => {request,Token,0,<<2>>,<<0:512>>},
            limits => {1,1,0,100.0,1,0,0},dt => 1/60,gravity => 0.0,structure => 1,
            bodies => [{3,1,dynamic,{world_mm,{0,500,0},{0.0,0.0,0.0}},{solid,{box,0.5,0.5,0.5}},1.0}],
            hinges => [],activities => #{{rest,3} => #{reference => {rest,3,1},
                request => R,command => rest,native_command => none,references => [{body,3,1}],
                custody => none,outcome_key => none}}},
        Pid ! {physics_selected,self(),make_ref(),Current},
        Pid ! {physics_result,self(),Activation,{ok,ignored,{normalized,{committed,ignored,ignored}}}},
        {First,Tick} = rest_sample_message(Pid,Token),
        Pid ! {physics_result,self(),First,{error,expired_observation}},
        {Second,NextTick} = rest_sample_message(Pid,Token),
        ?assertNotEqual(First,Second), ?assert(NextTick > Tick),
        ?assertMatch(#{steps := Steps} when Steps =:= NextTick,gen_server:call(Pid,status))
    end) end}.

rest_sample_message(Pid,Token) ->
    receive {physics_observation,Pid,_,Token,Ref,Sample = {physics_sample,_,{activity,{rest,_,_},_,rest},_,_,_,_},_} ->
        {Ref,element(5,Sample)}
    after 10000 -> error(rest_observation_lost) end.

authored_nonbox_edit_invalidates_rest_checkpoint_test_() ->
    [{atom_to_list(Kind),{timeout,60,fun() ->
        Shape = case Kind of
            ball -> {ball,500};
            compound -> {parts,[{part,{pose,{vector,0,0,0},{rotation,0,0,0}},{box,500,500,500}}]}
        end,
        OldPose = {pose,{vector,0,500,0},{rotation,0,785,0}},
        with_chair(fun(F = #{namespace := Ns}) ->
            _ = enable(F), true = quod_reg:subscribe({runtime,Ns}),
            try
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                    {physics_checkpoint_body,room,3,1,0,<<207:256>>})),
                await_rest(Ns,{rest,1,<<207:256>>}),
                ?assertMatch({rest_v1,3,1,_,_,_,_},rest_checkpoint_fact(Ns)),
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                    {physics_move_body,room,3,1,1,{vector,4000,500,0}})),
                ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_checkpoint,room,{'_'}})),
                ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_body_definition, room, 3, 2, dynamic, {pose,{vector,4000,500,0},{rotation,0,785,0}}, {owned, Shape, 1}}))
            after catch quod_reg:unsubscribe({runtime,Ns}) end
        end,fun(Rules) -> [case R of {physics_body_definition, room, 3, 1, dynamic, _, {owned, _, 1}} ->
            {physics_body_definition, room, 3, 1, dynamic, OldPose, {owned, Shape, 1}}; _ -> R end || R <- Rules] end)
    end}} || Kind <- [ball,compound]].

await_checkpoint_rejection(Ns,Bytes,Signature,Deadline) ->
    Engine = quod_reg:where({quod_prolog,Ns}),
    case quod_client_goal_ingress:resolve_operation(Bytes,Signature) of
        {ok,_,{operation_pending,_}} ->
            Remaining = max(0,Deadline-quod_time:mono_ms()),
            receive {projection_advanced,Engine,_} -> await_checkpoint_rejection(Ns,Bytes,Signature,Deadline)
            after Remaining -> error(checkpoint_rejection_not_published) end;
        Outcome -> ?assertMatch({ok,_,{operation_outcome,_,#{status := rejected}}},Outcome)
    end.

%% Both examples compose the same production libraries. Only these authored
%% data/rule files choose object geometry, axis, target and domain consequence.
generic_hinged_signed_view_recovery_test_() ->
    {timeout,180,fun() -> with_hinged_examples(fun(First,Second) ->
        [verify_hinged_signed_view(F) || F <- [First,Second]]
    end) end}.

verify_hinged_signed_view(F = #{namespace := Ns,identity := Identity,target := Target}) ->
    Obstacle = maps:get(obstacle,F),
    {Admission,_,_} = erlog_int:term_instance({transaction,list_conjunction([
            {current_principal,{'P'}},{can_edit_physics,room,{'P'}},
            {physics_body_capacity,room,1},{physics_allocate_body,room,12},
            {physics_advance_structure,room,3},
            {assertz,{physics_body_definition,room,12,3,fixed,Obstacle,{owned,{box,200,1000,200},1}}}])},0),
    ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,Admission)),
    {Pid,World} = enable(F),
    Pub = maps:get(pubkey,Identity),
    commit(Ns,{assertz,{agent_key,viewer,Pub,active}}),
    Principal = {agent_instance_ref,Ns,quod_simplex:genesis_hash(Ns),viewer},
    ViewGoal = {',',{current_ontology_identity,Ns,{'_'}},
                     {client_world_view,room,playing,{'_'},{'_'}}},
    Rules = quod_prolog:read_terms("priv/ontologies/hinged_example_view.pl") ++
        [{can_invoke,ViewGoal,Principal,{'_'},Ns},{can_view_physics,room,Principal},
         {':-',{world_view,room,playing,{'Marks'}},{hinged_example_view,room,{'Marks'}}}],
    commit(Ns,list_conjunction([{'$quod_retract_exact',default_world_view_rule()} |
                                [{assertz,R} || R <- Rules]])), reconcile(Ns),
    {ok,[#{'Marks' := AuthoredMarks}],_} = quod_prolog:prove_ro(Ns,{world_view,room,playing,{'Marks'}}),
    ?assertMatch({ok,[_],_},quod_prolog:prove_ro(<<"physics-test-rendering">>,{well_formed_scene,AuthoredMarks})),
    Parent = self(), Socket = spawn_link(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
    try
        Session = simulation_session(Identity),
        Open = fun() -> Socket ! {client,simulation_open(F,Session)} end,
        Open(), Initial = simulation_reply(Socket,<<"projection">>),
        ?assertEqual(<<"active">>,maps:get(<<"selection">>,Initial)),
        InitialPose = hinged_view_pose(Initial),
        assert_hinged_view_label(Initial,<<"Ready to close">>),
        %% The viewer's key is real, but viewing grants no mutation authority.
        Id = <<181:256>>, Goal = {physics_close_hinged,room,10,0,Id},
        ?assertMatch({ok,_,{normalized,{failed,_}}},hinged_view_action(F,Goal)),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_hinged,room,10,0,idle})),
        commit(Ns,{assertz,{can_invoke,Goal,Principal,{'_'},Ns}}),
        true = quod_reg:subscribe({runtime,Ns}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},hinged_view_action(F,Goal)),
        _ = await_hinged_ops(Ns,{close,1,Id},{blocked,12}),
        _ = simulation_reply(Socket,<<"refresh">>), Open(),
        Blocked = simulation_reply(Socket,<<"projection">>),
        assert_hinged_view_label(Blocked,<<"Blocked">>),
        BlockedPose = hinged_view_pose(Blocked), ?assertNotEqual(InitialPose,BlockedPose),
        {ok,[#{'Angle' := BlockedAngle}],_} = quod_prolog:prove_ro(Ns,
            {physics_checkpoint,room,{hinge,10,2,{body,10,2},{body,11,2},1,{'_'},{'Angle'}}}),
        ?assert(abs(BlockedAngle-Target) > 20),
        M1 = monitor(process,Pid), exit(Pid,kill),
        receive {'DOWN',M1,process,Pid,killed} -> ok after 5000 -> error(owner_alive) end,
        _ = simulation_reply(Socket,<<"refresh">>),
        {BlockedOwner,World} = installed(Ns), ?assertNotEqual(Pid,BlockedOwner), Open(),
        RestoredBlocked = simulation_reply(Socket,<<"projection">>),
        assert_hinged_view_label(RestoredBlocked,<<"Blocked">>),
        assert_hinged_view_restored_pose(BlockedPose,hinged_view_pose(RestoredBlocked)),
        {vector,OX,OY,OZ} = Obstacle,
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
            {physics_move_body,room,12,3,3,{vector,OX+5000,OY,OZ}})),
        _ = simulation_reply(Socket,<<"refresh">>), Open(),
        _ = simulation_reply(Socket,<<"projection">>),
        NextId = <<182:256>>, NextGoal = {physics_close_hinged,room,10,1,NextId},
        commit(Ns,{assertz,{can_invoke,NextGoal,Principal,{'_'},Ns}}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},hinged_view_action(F,NextGoal)),
        _ = await_hinged_ops(Ns,{close,2,NextId},closed),
        _ = simulation_reply(Socket,<<"refresh">>), Open(),
        Closed = simulation_reply(Socket,<<"projection">>),
        assert_hinged_view_label(Closed,<<"Closed">>),
        ClosedPose = hinged_view_pose(Closed), ?assertNotEqual(InitialPose,ClosedPose),
        {ok,[#{'Angle' := Angle}],_} = quod_prolog:prove_ro(Ns,
            {physics_checkpoint,room,{hinge,10,2,{body,10,2},{body,11,2},2,{'_'},{'Angle'}}}),
        ?assert(abs(Angle-Target) =< 20),
        BeforeOther = quod_prolog:applied(maps:get(other_namespace,F)),
        M = monitor(process,BlockedOwner), exit(BlockedOwner,kill),
        receive {'DOWN',M,process,BlockedOwner,killed} -> ok after 5000 -> error(owner_alive) end,
        _ = simulation_reply(Socket,<<"refresh">>),
        {Next,World} = installed(Ns), ?assertNotEqual(BlockedOwner,Next), Open(),
        Restored = simulation_reply(Socket,<<"projection">>),
        assert_hinged_view_label(Restored,<<"Closed">>),
        assert_hinged_view_restored_pose(ClosedPose,hinged_view_pose(Restored)),
        ?assertEqual(BeforeOther,quod_prolog:applied(maps:get(other_namespace,F))),
        {ok,[#{'Results' := Results}],_} = quod_prolog:prove_ro(Ns,
            {findall,{'R'},{hinged_result,maps:get(meaning,F),{'R'}},{'Results'}}),
        ?assertEqual([{close,2,NextId}],Results)
    after
        Socket ! stop, catch quod_reg:unsubscribe({runtime,Ns})
    end.

hinged_view_action(#{namespace := Ns,identity := Identity},Goal) ->
    Anchor = quod_simplex:genesis_hash(Ns),
    {Scoped,_,_} = erlog_int:term_instance({'::',Ns,Goal},0),
    {ok,Text} = quod_client_goal_parser:format(Scoped),
    Request = #{network_identity => <<42:256>>,agent_namespace => Ns,
        agent_genesis_anchor => Anchor,agent_instance_text => <<"viewer.">>,
        signing_public_key => maps:get(pubkey,Identity),operation_id => crypto:strong_rand_bytes(32),
        not_after_ms => quod_time:now_ms()+10000,mode => execute,parser_version => 3,goal_text => Text},
    {ok,Bytes} = quod_client_goal:encode(Request),
    quod_client_goal_ingress:submit(Bytes,quod_identity:sign(Bytes,Identity)).

hinged_view_pose(Projection) ->
    [Pose] = maps:get(<<"poses">>,maps:get(<<"frame">>,Projection)),
    ?assertEqual(<<"10">>,maps:get(<<"body">>,Pose)), Pose.

assert_hinged_view_label(Projection,Text) ->
    {ok,#{goal := Parsed}} = quod_client_goal_parser:parse(<<(maps:get(<<"marks">>,Projection))/binary,".">>,3),
    {ok,[{mark,<<"hinged-example">>,<<"group">>,[],{body_pose,10,2},no_surface,
          {label,Text,<<"above">>},{depicts,_,_,_}}|Parts]} = quod_wire_term:materialize_symbols(Parsed),
    ?assert(lists:all(fun({mark,_,_,_,{relative,<<"hinged-example">>,_},_,_,depicts_nothing}) -> true;
                        (_) -> false end,Parts)).

assert_hinged_view_restored_pose(Before,After) ->
    %% The durable angle rounds to mrad; recovery may differ by its half-mrad.
    [begin ?assert(abs(A-B) =< 0.002) end ||
        {A,B} <- lists:zip(maps:get(<<"position">>,Before),maps:get(<<"position">>,After))],
    Q = maps:get(<<"rotation">>,Before), R = maps:get(<<"rotation">>,After),
    Dot = lists:sum([A*B || {A,B} <- lists:zip(Q,R)]),
    ?assert(abs(Dot) >= 0.999999).

authored_hinged_examples_in_independent_worlds_test_() ->
    {timeout,120,fun() -> with_hinged_examples(fun(First,Second) ->
        {P1,W1} = enable(First), {P2,W2} = enable(Second),
        ?assertNotEqual(W1,W2), ?assertNotEqual(P1,P2),
        [begin
            Ns = maps:get(namespace,F), true = quod_reg:subscribe({runtime,Ns}),
            R = {close,1,<<161:256>>},
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Ns,{physics_close_hinged,room,10,0,<<161:256>>})),
            Ops = await_hinged_ops(Ns,R,closed),
            ?assert(lists:member({event,{physics_hinged_finished,room,10,R,closed}},Ops)),
            Meaning = maps:get(meaning,F),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{hinged_result,Meaning,R})),
            {ok,[#{'A' := Angle}],_} = quod_prolog:prove_ro(Ns,
                {physics_checkpoint,room,{hinge,10,2,{body,10,2},{body,11,2},1,{'_'},{'A'}}}),
            ?assert(abs(Angle-maps:get(target,F)) =< 20), reconcile(Ns)
        end || F <- [First,Second]],
        #{namespace := A,target := Target} = First, #{namespace := B} = Second,
        BeforeB = gen_server:call(P2,status), HeightB = quod_prolog:applied(B),
        %% A real command change affects only its owner; no geometry rebuild.
        Calls = physics_trace_calls([{quod_physics_native,control_hinge,4},
            {quod_physics_native,install,3},{quod_physics_native,install_hinges,2}],fun() ->
            commit(A,{',',{retract,{physics_hinged_control,room,10,hinged_command(Target)}},
                          {assertz,{physics_hinged_control,room,10,hinged_command(-200)}}}),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(A,{physics_close_hinged,room,10,1,<<162:256>>})),
            _ = await_hinged_ops(A,{close,2,<<162:256>>},closed), reconcile(A)
        end),
        ?assertMatch([#{pid := P1,call := {quod_physics_native,control_hinge,4}}],Calls),
        ?assertEqual(HeightB,quod_prolog:applied(B)),
        ?assertEqual(maps:with([installs,incarnation],BeforeB),
                     maps:with([installs,incarnation],gen_server:call(P2,status))),
        assert_no_physics_io(fun() -> assert_no_live_geometry_work(fun() ->
            [begin reconcile(A),reconcile(B) end || _ <- lists:seq(1,5)]
        end) end),
        %% Recovery restores each current result without replaying its effect.
        [begin
            Ns = maps:get(namespace,F), M = monitor(process,Pid), exit(Pid,kill),
            receive {'DOWN',M,process,Pid,killed} -> ok after 5000 -> error(owner_alive) end,
            {Next,World} = installed(Ns), ?assertNotEqual(Pid,Next),
            {ok,[#{'Rows' := Rows}],_} = quod_prolog:prove_ro(Ns,
                {findall,{'R'},{hinged_result,maps:get(meaning,F),{'R'}},{'Rows'}}),
            ?assertEqual(Count,length(Rows))
        end || {F,Pid,World,Count} <- [{First,P1,W1,2},{Second,P2,W2,1}]]
    end) end}.

with_hinged_examples(Fun) ->
    A = <<"hinged-gallery">>, B = <<"hinged-workshop">>,
    Door = "test/fixtures/hinged-door.pl", Lid = "test/fixtures/hinged-lid.pl",
    with_world(A,fun(F = #{node := Node,directory := Dir,identity := Identity}) ->
        Render = <<"physics-test-rendering">>, RA = quod_simplex:genesis_hash(Render),
        Rules = hinged_example_rules(B,world_rules(B),Lid) ++
            [{rendering_vocabulary,Render,RA},{modelling_vocabulary,Render,RA}],
        Sup = quod_agent_hosting_tests:start_ontology(B,Dir,Identity,
            quod_prolog:genesis_diff("priv/ontologies/agent_instance.pl"),
            [{can_assign_agent_host,{node,maps:get(pubkey,Identity)},actor,{'_'},{'_'},Node,{'_'}},
             {can_invoke,{'_'},Node,{'_'},B},{can_request_agent_signature,Node,actor,{'_'}}|Rules]),
        Ref = {agent_instance_ref,B,quod_simplex:genesis_hash(B),actor},
        {ok,Blob} = quod_wire_term:encode_canonical(Ref), {ok,Key} = quod_agent_vault:prepare(Blob,0),
        try Fun((add_hinged_example(F))#{other_namespace => B},
                (add_hinged_example(F#{namespace => B,reference => Ref,key => Key}))#{other_namespace => A})
        after
            [catch quod_reg:unsubscribe(Topic) || Topic <- [{physics,B},{runtime,A},{runtime,B}]],
            quod_agent_hosting_tests:stop_ontology(Sup)
        end
    end,fun(Rules) -> hinged_example_rules(A,Rules,Door) end).

hinged_example_rules(Ns,Rules,File) ->
    Actor = {agent_instance_ref,Ns,{'_'},actor},
    [R || R <- Rules, not (element(1,R) =:= physics_body_definition andalso element(3,R) =:= 2)] ++
        quod_prolog:read_terms(File) ++
        [{can_invoke,{physics_store_hinged_request,{'_'},{'_'},{'_'},{'_'}},Actor,{'_'},Ns},
         {can_invoke,{physics_finish_hinged,{'_'},{'_'}},Actor,{'_'},Ns},
         {can_edit_physics,room,{'_'}},{can_close_physics_hinged,room,10,{'_'}},
         {can_cancel_physics_hinged,room,10,{'_'}}].
add_hinged_example(F = #{namespace := Ns}) ->
    {ok,[#{'Name' := Name,'Pose' := Pose,'Target' := Target,'Obstacle' := Obstacle,'Meaning' := Meaning}],_} =
        quod_prolog:prove_ro(Ns,{hinged_example,{'Name'},{'Pose'},{'Target'},{'Obstacle'},{'Meaning'}}),
    ?assertMatch({normalized,{committed,_,_}},brief(door_action(Ns,
        {physics_add_hinged,room,10,11,{local,Name,1},Pose,1}))),
    F#{target => Target,meaning => Meaning,obstacle => Obstacle}.

await_hinged_ops(Ns,R,Result) ->
    receive
        {applied_live,#{ns := Ns,applied_ops := Ops}} ->
            case lists:member({event,{physics_hinged_finished,room,10,R,Result}},Ops) of
                true -> Ops; false -> await_hinged_ops(Ns,R,Result)
            end
    after 15000 -> error({hinged_consequence_missing,Ns,R,Result,quod_runtime:stats(Ns)}) end.

physics_trace_calls(Watched,Fun) ->
    Collector = spawn_link(fun() -> trace_calls([]) end),
    Trace = trace:session_create(hinged_controls,Collector,[]),
    [trace:function(Trace,MFA,[{'_',[],[{message,{caller}}]}],[local]) || MFA <- Watched],
    trace:process(Trace,all,true,[call]),
    try
        Fun(), Delivered = trace:delivered(Trace,all),
        receive {trace_delivered,all,Delivered} -> ok after 5000 -> error(trace_timeout) end,
        Ref = make_ref(), Collector ! {finish,self(),Ref},
        receive {trace_calls,Ref,Rows} -> Rows after 5000 -> error(trace_timeout) end
    after trace:session_destroy(Trace),unlink(Collector),exit(Collector,kill) end.

hinged_receiver_completion_is_atomic_test_() ->
    [{atom_to_list(Mode),{timeout,90,fun() -> hinged_receiver_completion(Mode) end}} ||
        Mode <- [commit,denied,rollback,conflict]].

hinged_receiver_completion(Mode) ->
    {ok,_} = application:ensure_all_started(gproc),
    true = quod_reg:reg({host_test,barrier}),
    try with_door(fun(F = #{namespace := Ns,node := {agent_instance_ref,Receiver,Anchor,_},reference := Actor}) ->
        {ok,Foreign} = quod_foreign_log:start_link(#{cache_dir => filename:join(maps:get(directory,F),"foreign")}),
        try
        R = {close,1,<<163:256>>},
        ReceiverAction = {'::',Receiver,{',',{current_ontology_identity,Receiver,Anchor},{receive_hinged,{'R'}}}},
        Consequence = {physics_hinged_consequence,room,10,{'R'},closed,ReceiverAction},
        ReceiverRules = [receiver_allowed,
            {':-',{receive_hinged,{'R'}},{',',receiver_allowed,{assertz,{received_hinged,{'R'}}}}}],
        Grants = case Mode of denied -> []; _ -> [{can_invoke,{'_'},Actor,{'_'},Receiver}] end,
        commit(Receiver,list_conjunction([{assertz,T} || T <- ReceiverRules++Grants])),
        Additional = case Mode of rollback -> [{physics_hinged_consequence,room,10,{'_'},closed,fail}]; _ -> [] end,
        commit(Ns,list_conjunction([{assertz,T} || T <- [Consequence|Additional]])),
        {Pid,World} = enable(F), true = quod_reg:subscribe({runtime,Ns}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},
            door_action(Ns,{physics_close_hinged,room,10,0,<<163:256>>})),
        case Mode of
            M when M =:= commit; M =:= conflict ->
                Proof = receive {fipa_completion_prepared,P,_} -> P
                        after 10000 -> error(atomic_hinge_proof_missing) end,
                try
                    assert_hinged_unfinished(Ns,Receiver,R),
                    case Mode of conflict -> commit(Receiver,{retract,receiver_allowed}); _ -> ok end
                after Proof ! release end;
            _ -> ok
        end,
        case Mode of
            commit ->
                _ = await_hinged_ops(Ns,R,closed),
                {ok,[#{'C' := {request,_,closed,Bytes,Sig}}],_} =
                    quod_prolog:prove_ro(Ns,{physics_hinged_request,room,10,{'C'}}),
                ?assertMatch({ok,_,{operation_outcome,_,#{status := committed}}},
                    await_hinged_outcome(Ns,Bytes,Sig,quod_time:mono_ms()+10000)),
                ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Receiver,{received_hinged,R}));
            _ ->
                receive {physics_status,_,Pid,World,_,{unavailable,{observation,{hinge,10},unresolved}}} -> ok
                after 15000 -> error(atomic_refusal_not_delivered) end,
                assert_hinged_unfinished(Ns,Receiver,R)
        end
        after gen_server:stop(Foreign) end
    end,false,fun(Rules) ->
        [case Rule of
            {':-',Head = {physics_finish_hinged,_,_},Body} when Mode =:= commit; Mode =:= conflict ->
                {':-',Head,{',',Body,test_fipa_completion}};
            _ -> Rule
        end || Rule <- Rules]
    end)
    after gproc:unreg(quod_reg:name({host_test,barrier})) end.

await_hinged_outcome(Ns,Bytes,Sig,Deadline) ->
    Owner = quod_reg:where({quod_prolog,Ns}),
    case quod_client_goal_ingress:resolve_operation(Bytes,Sig) of
        {ok,_,{operation_outcome,_,#{status := committed}}} = Result -> Result;
        Pending ->
            Remaining = max(0,Deadline-quod_time:mono_ms()),
            receive {projection_advanced,Owner,_} -> await_hinged_outcome(Ns,Bytes,Sig,Deadline)
            after Remaining -> error({hinged_outcome_not_published,brief(Pending)}) end
    end.

assert_hinged_unfinished(Ns,Receiver,R) ->
    ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_hinged,room,10,1,{closing,R}})),
    ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_checkpoint,room,{'_'}})),
    ?assertMatch({fail,_},quod_prolog:prove_ro(Receiver,{received_hinged,R})).

shared_fixed_support_moves_atomically_test_() ->
    {timeout,90,fun() -> with_door(fun(F = #{namespace := Ns}) ->
        Joint = {hinge,{body,20,2},2,{body,11,2},{vector,1,0,0},
            {anchors,{vector,0,2000,0},{vector,0,0,0}},{limits,-1000,1000},200},
        Body = {physics_body_definition,room,20,2,dynamic,{vector,0,1500,0},{owned,{ball,100},1}},
        commit(Ns,list_conjunction([{assertz,Body},{assertz,{physics_joint,room,Joint}}])),
        Move = {physics_move_hinged,room,10,0,2,{pose,{vector,3000,1500,0},{rotation,0,200,0}}},
        ?assertMatch({ok,_,{normalized,{failed,_}}},door_action(Ns,Move)),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_structure,room,2})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,Body)),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
            {physics_body_definition,room,11,2,fixed,{vector,0,1500,0},{'_'}})),
        commit(Ns,list_conjunction([{assertz,T} || T <-
            [{physics_hinged,room,20,0,idle},{physics_hinged_control,room,20,hinged_command(-300)},
             {can_close_physics_hinged,room,20,{'_'}}]])),
        {Pid,_} = enable(F), ok = sys:suspend(Pid),
        try
            [begin ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                {physics_close_hinged,room,D,0,<<164:256>>})) end || D <- [10,20]],
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,setelement(4,Move,1))),
            [begin
                ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
                    {physics_hinged,room,D,1,{cancelled,{close,1,<<164:256>>}}})),
                ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
                    {physics_joint,room,{hinge,{body,D,3},3,{body,11,3},{'_'},{'_'},{'_'},{'_'}}}))
            end || D <- [10,20]]
        after sys:resume(Pid) end,
        {Pid,_} = installed_structure(Ns,3),
        true = quod_reg:reg({host_test,local_proof}),
        try assert_live_conflict(live_compete(Ns,[setelement(5,setelement(4,Move,1),3),
                                               setelement(5,setelement(4,Move,1),3)]))
        after gproc:unreg(quod_reg:name({host_test,local_proof})) end,
        {Pid,_} = installed_structure(Ns,4)
    end,false) end}.

hinged_command_edit_fences_signed_sample_test_() ->
    [{atom_to_list(Stage),{timeout,60,fun() -> with_door(fun(F = #{namespace := Ns}) ->
        {Pid,World} = enable(F), #{World := #{spec := Spec}} = worlds(Ns),
        ok = sys:suspend(Pid),
        try
            R = {close,1,<<165:256>>},
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Ns,{physics_close_hinged,room,10,0,<<165:256>>})),
            At = quod_time:now_ms(), Expiry = At+10000,
            Sample = test_hinge_sample(Spec,2,R,1,500,{contact,3,1},At,Expiry),
            {Bytes,Sig} = sign_fixture(F,{physics_finish_hinged,Sample,{blocked,3}},Expiry),
            {Store,StoreSig} = sign_fixture(F,{physics_store_hinged_request,Sample,{blocked,3},Bytes,Sig},Expiry),
            case Stage of after_store ->
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},quod_client_goal_ingress:submit(Store,StoreSig));
                before_store -> ok
            end,
            commit(Ns,{',',{retract,{physics_hinged_control,room,10,hinged_command(0)}},
                          {assertz,{physics_hinged_control,room,10,hinged_command(100)}}}),
            {Submission,Signature} = case Stage of before_store -> {Store,StoreSig}; after_store -> {Bytes,Sig} end,
            ?assertMatch({ok,_,{normalized,{failed,_}}},quod_client_goal_ingress:submit(Submission,Signature)),
            ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_checkpoint,room,{'_'}})),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_hinged,room,10,1,{closing,R}})),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_cancel_hinged,room,10,R}))
        after sys:resume(Pid) end
    end,true) end}} || Stage <- [before_store,after_store]].

authored_hinged_obstruction_and_permissions_test_() ->
    {timeout,120,fun() -> with_hinged_examples(fun(First,Second) ->
        [begin
            #{namespace := Ns,obstacle := Position} = F,
            commit(Ns,{',',{physics_advance_structure,room,3},
                {assertz,{physics_body_definition,room,3,3,fixed,Position,{owned,{box,200,1000,200},1}}}}),
            {Pid,_} = enable(F),true = quod_reg:subscribe({runtime,Ns}),
            Close = {can_close_physics_hinged,room,10,{'_'}},
            Cancel = {can_cancel_physics_hinged,room,10,{'_'}},
            commit(Ns,{retract,Close}),
            ?assertMatch({ok,_,{normalized,{failed,_}}},
                door_action(Ns,{physics_close_hinged,room,10,0,<<166:256>>})),
            commit(Ns,{assertz,Close}),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Ns,{physics_close_hinged,room,10,0,<<166:256>>})),
            _ = await_hinged_ops(Ns,{close,1,<<166:256>>},{blocked,3}),
            ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{hinged_result,{'_'},{'_'}})),
            ok = sys:suspend(Pid),
            try
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                    door_action(Ns,{physics_close_hinged,room,10,1,<<167:256>>})),
                R = {close,2,<<167:256>>},commit(Ns,{retract,Cancel}),
                ?assertMatch({ok,_,{normalized,{failed,_}}},
                    door_action(Ns,{physics_cancel_hinged,room,10,R})),
                commit(Ns,{assertz,Cancel}),
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                    door_action(Ns,{physics_cancel_hinged,room,10,R})),
                ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_hinged,room,10,2,{cancelled,R}}))
            after sys:resume(Pid) end
        end || F <- [First,Second]]
    end) end}.

finished_hinged_group_move_can_close_again_test_() ->
    {timeout,120,fun() -> with_hinged_examples(fun(First,Second) ->
        [begin
            #{namespace := Ns} = F, {Pid,World} = enable(F),
            true = quod_reg:subscribe({runtime,Ns}),
            R1 = {close,1,<<168:256>>},
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Ns,{physics_close_hinged,room,10,0,<<168:256>>})),
            _ = await_hinged_ops(Ns,R1,closed),
            {ok,[#{'C' := {request,_,closed,OldBytes,OldSignature}}],_} =
                quod_prolog:prove_ro(Ns,{physics_hinged_request,room,10,{'C'}}),
            {ok,[#{'Pose' := Pose}],_} = quod_prolog:prove_ro(Ns,
                {hinged_example,{'_'},{'Pose'},{'_'},{'_'},{'_'}}),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Ns,{physics_move_hinged,room,10,1,2,Pose})),
            {Pid,World} = installed_structure(Ns,3),
            ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_checkpoint,room,{'_'}})),
            %% A group edit invalidates the physical checkpoint, not the
            %% recorded completion of the original custodied operation.
            ?assertMatch({normalized,{committed,_,_}},
                brief(door_action(Ns,{physics_close_hinged,room,10,1,<<169:256>>}))),
            _ = await_hinged_ops(Ns,{close,2,<<169:256>>},closed),
            {ok,[#{'C' := {request,_,closed,NewBytes,_}}],_} =
                quod_prolog:prove_ro(Ns,{physics_hinged_request,room,10,{'C'}}),
            ?assertNotEqual(OldBytes,NewBytes),
            ?assertMatch({ok,_,{operation_outcome,_,#{status := committed}}},
                quod_client_goal_ingress:resolve_operation(OldBytes,OldSignature)),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
                {physics_checkpoint,room,{hinge,10,3,{body,10,3},{body,11,3},1,{'_'},{'_'}}}))
        end || F <- [First,Second]]
    end) end}.

terrain_delivery_credit_and_replacement_test_() ->
    [{atom_to_list(Mode),{timeout,20,fun() ->
    Field = {field_v1,1,500,[{plane,1000}],9},
    Limits = {prepare_limits,{sampling_limits,1331,100000,100000,3993},
              {surface_limits,512,10000,10000},69120,500000},
    {ok,{A,generated}} = quod_voxel:prepare(Field,{chunk_v1,0,0,0},[],Limits,none),
    #{handle := Handle,payload := Payload} = A,
    with_simulator(none,fun(Pid,Spec) ->
        {Activation,Token} = receive
            {physics_work,Pid,_,Act,activate,{{physics_activate,room,0,T},_,_},_} -> {Act,T}
        after 5000 -> error(activation_missing) end,
        Initial = Spec#{generation => 1,run_token => Token,
            custody => {request,Token,0,<<2>>,<<0:512>>},
            %% This step keeps the full conservative dynamic envelope inside
            %% the fixture's one resident chunk throughout the fall.
            limits => {2,2,1,1000.0,2,10000,10000},dt => 1/600,gravity => -9.81,structure => 1,
            activities => #{},bodies => [{0,1,fixed,{world_mm,{0,0,0},{0.0,0.0,0.0}},
                {terrain,500,[{{0,0,0},Handle}]},1.0}] ++ case Mode of
                    static -> [];
                    moving -> [{1,1,dynamic,{world_mm,{2000,2500,2000},{0.0,0.0,0.0}},
                                 {solid,{ball,0.25}},1.0}]
                end,voxel_resources => #{{0,{chunk_v1,0,0,0}} => A}},
        Pid ! {physics_selected,self(),make_ref(),Initial},
        Pid ! {physics_result,self(),Activation,{ok,ignored,{normalized,{committed,ignored,ignored}}}},
        receive {physics_status,Pid,_,Token,installed} -> ok after 5000 -> error(install_missing) end,
        Current = case Mode of
            static -> Initial;
            moving ->
                receive {physics_terrain_demand,Pid,_,Token,1,Ranges,Focus} ->
                    ?assertEqual([{0,{0,0,0},{0,0,0}}],Ranges),
                    Selected = Initial#{terrain_demand => {Pid,Token,1,Ranges,Focus}},
                    Pid ! {physics_selected,self(),make_ref(),Selected},Selected
                after 5000 -> error(physical_demand_missing) end
        end,
        Expected = #{fence => quod_physics:fence(Current),structure => 1,incarnation => Token,
            control => none,terrain => [{0,1,{view_distance,4000,1000,2000},[10000,20000,1000,1000,2]}]},
        {ok,Ref,Frame} = quod_physics:watch(Pid,Expected,none),
        Tick = maps:get(tick,Frame),
        quod_physics:ack(Pid,Ref,Tick,0),
        {Manifest,[Row]} = receive {physics_resource,Pid,Ref,{terrain_manifest,M,0,Rows}} -> {M,Rows}
            after 5000 -> error(manifest_missing) end,
        ?assertMatch(#{body := 0,revision := 1,index := 0,costs := [4880,13824,384,128,1]},Row),
        case Mode of
            static -> ok;
            moving -> receive {physics_status,Pid,_,Token,sleeping} -> ok
                      after 15000 -> error(moving_body_did_not_settle) end
        end,
        quod_physics:ack(Pid,Ref,Tick,0),
        quod_physics:resource_ack(Pid,Ref,<<0:256>>,{want,[0]}),
        _ = gen_server:call(Pid,status),
        receive {physics_resource,Pid,Ref,_} -> error(stale_ack_released_credit) after 0 -> ok end,
        quod_physics:resource_ack(Pid,Ref,Manifest,{want,[0]}),
        case Mode of
            static -> ok;
            moving ->
                Latest = receive {physics_frame,Pid,Ref,F} -> F
                         after 5000 -> error(terrain_starved_pose_delivery) end,
                ?assert(maps:get(tick,Latest) > Tick),
                %% The resource acknowledgement cannot release the pose now
                %% holding credit; its own exact acknowledgement is required.
                quod_physics:resource_ack(Pid,Ref,Manifest,{want,[0]}),
                quod_physics:ack(Pid,Ref,Tick,0),
                _ = gen_server:call(Pid,status),
                receive {physics_resource,Pid,Ref,_} -> error(pose_credit_not_fenced) after 0 -> ok end,
                quod_physics:ack(Pid,Ref,maps:get(tick,Latest),maps:get(origin_sequence,Latest))
        end,
        receive {physics_resource,Pid,Ref,{terrain_chunks,Manifest,[{0,Payload}],true}} -> ok
            after 5000 -> error(chunk_missing) end,
        quod_physics:resource_ack(Pid,Ref,Manifest,{want,[0]}),
        _ = gen_server:call(Pid,status),
        receive {physics_resource,Pid,Ref,_} -> error(duplicate_ack_released_credit) after 0 -> ok end,
        %% A new retained selection replaces the manifest even if body revision
        %% and the current physical sample have not advanced.
        Pid ! {physics_selected,self(),make_ref(),Current#{voxel_resources => #{}}},
        _ = gen_server:call(Pid,status),
        quod_physics:resource_ack(Pid,Ref,Manifest,complete),
        Replacement = receive {physics_resource,Pid,Ref,{terrain_manifest,M2,0,[]}} -> M2
            after 5000 -> error(empty_replacement_missing) end,
        ?assertNotEqual(Manifest,Replacement),
        quod_physics:resource_ack(Pid,Ref,Replacement,{want,[]}),
        receive {physics_resource,Pid,Ref,{terrain_chunks,Replacement,[],true}} -> ok
            after 5000 -> error(empty_complete_missing) end
    end) end}} || Mode <- [static,moving]].

voxel_signed_view_delivers_only_bound_resident_chunks_test_() ->
    {timeout,90,fun() -> with_voxel_view(fun(F = #{namespace := Ns,identity := Identity,
        physics := Pid,world := World,socket := Socket,projection := Projection}) ->
            ?assertEqual(<<"active">>,maps:get(<<"selection">>,Projection)),
            View = maps:get(<<"view">>,Projection),
            Tick = maps:get(<<"tick">>,maps:get(<<"frame">>,Projection)),
            Socket ! {client,iolist_to_binary(json:encode(#{type => ack,origin_seq => <<"0">>,view => View,tick => Tick}))},
            Manifest = terrain_reply(Socket,View,<<"terrain_manifest">>),
            Rows = maps:get(<<"chunks">>,Manifest), Token = maps:get(<<"token">>,Manifest),
            ?assertEqual(3,length(Rows)),
            Ack = fun(Value) -> Socket ! {client,iolist_to_binary(json:encode(
                Value#{type => terrain_ack,view => View,token => Token}))} end,
            Ack(#{want => [0,1,2]}),
            #{World := #{spec := Spec}} = worlds(Ns), Artifacts = maps:get(voxel_resources,Spec),
            Content = terrain_reply(Socket,View,<<"terrain_chunks">>),
            ?assertEqual(Token,maps:get(<<"token">>,Content)),
            Chunks = maps:get(<<"chunks">>,Content),?assertEqual(length(Rows),length(Chunks)),
            lists:foreach(fun({Row,Chunk}) ->
                I = maps:get(<<"index">>,Row),
                ?assertEqual(I,maps:get(<<"index">>,Chunk)),
                Bytes = base64:decode(maps:get(<<"payload">>,Chunk),#{mode => urlsafe,padding => false}),
                ?assertEqual(binary:encode_hex(crypto:hash(sha256,Bytes),lowercase),maps:get(<<"digest">>,Row)),
                [X,Y,Z] = [binary_to_integer(N) || N <- maps:get(<<"chunk">>,Row)],
                B = binary_to_integer(maps:get(<<"body">>,Row)),
                ?assertEqual(maps:get(payload,maps:get({B,{chunk_v1,X,Y,Z}},Artifacts)),Bytes)
            end,lists:zip(Rows,Chunks)),
            Ack(#{complete => true}),
            ?assertMatch(#{pid := Pid},simulation_state(Socket)),
            assert_no_physics_io(fun() ->
                Socket ! {client,simulation_open(F,simulation_session(Identity))},
                Renewed = simulation_reply(Socket,<<"projection">>),
                NextView = maps:get(<<"view">>,Renewed),
                Socket ! {client,iolist_to_binary(json:encode(#{type => ack,origin_seq => <<"0">>,view => NextView,
                    tick => maps:get(<<"tick">>,maps:get(<<"frame">>,Renewed))}))},
                Retained = terrain_reply(Socket,NextView,<<"terrain_manifest">>),
                ?assertEqual(Rows,maps:get(<<"chunks">>,Retained)),
                Socket ! {client,iolist_to_binary(json:encode(#{type => terrain_ack,view => NextView,
                    token => maps:get(<<"token">>,Retained),want => []}))},
                ?assertEqual([],maps:get(<<"chunks">>,terrain_reply(Socket,NextView,<<"terrain_chunks">>)))
            end)
    end,{view_distance,4000,1000,2000},{resources,20000,60000,2000,1000,3},[]) end}.

voxel_signed_view_delivers_complete_large_resident_selection_test_() ->
    {timeout,90,fun() -> with_voxel_view(fun(#{physics := Pid,socket := Socket,projection := Projection}) ->
        View = maps:get(<<"view">>,Projection), Frame = maps:get(<<"frame">>,Projection),
        socket_command(Socket,#{type => terrain_interest,view => View,sequence => <<"1">>,
            centre_mm => [<<"2000">>,<<"2000">>,<<"2000">>]}),
        socket_command(Socket,#{type => ack,view => View,tick => maps:get(<<"tick">>,Frame),
            origin_seq => maps:get(<<"origin_seq">>,Frame)}),
        Manifest = large_terrain_manifest(Socket,View),
        Rows = maps:get(<<"chunks">>,Manifest),Token = maps:get(<<"token">>,Manifest),
        ?assertEqual(27,length(Rows)),
        ?assert(lists:sum([hd(maps:get(<<"costs">>,R)) || R <- Rows]) > (512*1024)),
        socket_command(Socket,#{type => terrain_ack,view => View,token => Token,
            want => [maps:get(<<"index">>,R) || R <- Rows]}),
        consume_large_terrain(Socket,Pid,View,Token,Rows),
        ?assertMatch(#{pid := Pid},simulation_state(Socket))
    end,{view_distance,4000,1000,2000},{resources,2000000,4000000,100000,50000,64},[],
    fun(#{namespace := Ns}) ->
        %% This authored field exercises the ordinary resident-resource path
        %% with more content than the retired presentation subquota.
        Before = {physics_allowances,room,{limits,64,64,256,1000000,{geometry,256,4096,4096}},16667,-9810,10000},
        After = setelement(3,Before,{limits,64,64,256,1000000,{geometry,256,100000,100000}}),
        commit(Ns,{',',{retract,Before},{assertz,After}}),
        {field_v1,41,500,[{plane,100000},{caves,2000,8,12000,1500}],9}
    end) end}.

large_terrain_manifest(Socket,View) ->
    Manifest = terrain_reply(Socket,View,<<"terrain_manifest">>),
    case maps:get(<<"interest_seq">>,Manifest) of
        <<"1">> -> Manifest;
        <<"0">> ->
            Token = maps:get(<<"token">>,Manifest),
            socket_command(Socket,#{type => terrain_ack,view => View,token => Token,want => []}),
            %% The owner may replace an obsolete snapshot immediately after
            %% its acknowledgement, without sending its empty completion.
            large_terrain_manifest(Socket,View)
    end.

consume_large_terrain(Socket,Pid,View,Token,Rows) ->
    Content = terrain_reply(Socket,View,<<"terrain_chunks">>),
    ?assert(iolist_size(json:encode(Content)) > 512*1024),
    ?assertEqual(Token,maps:get(<<"token">>,Content)),
    Chunks = maps:get(<<"chunks">>,Content),
    ?assertEqual(length(Rows),length(Chunks)),
    lists:foreach(fun({Row,Chunk}) ->
        ?assertEqual(maps:get(<<"index">>,Row),maps:get(<<"index">>,Chunk)),
        Bytes = base64:decode(maps:get(<<"payload">>,Chunk),#{mode => urlsafe,padding => false}),
        ?assertEqual(hd(maps:get(<<"costs">>,Row)),byte_size(Bytes)),
        ?assertEqual(maps:get(<<"digest">>,Row),binary:encode_hex(crypto:hash(sha256,Bytes),lowercase))
    end,lists:zip(Rows,Chunks)),
    ?assertEqual(true,maps:get(<<"complete">>,Content)),
    %% A completion for a different retained snapshot cannot release credit.
    socket_command(Socket,#{type => terrain_ack,view => View,
        token => base64:encode(<<0:256>>,#{mode => urlsafe,padding => false}),complete => true}),
    _ = simulation_state(Socket),_ = gen_server:call(Pid,status),
    receive {simulation,Socket,_} -> error(stale_ack_released_delivery) after 0 -> ok end,
    socket_command(Socket,#{type => terrain_ack,view => View,token => Token,complete => true}).

with_voxel_view(Fun,Distance,Resources,ExtraBodies) ->
    with_voxel_view(Fun,Distance,Resources,ExtraBodies,
        fun(_) -> {field_v1,1,500,[{plane,1000}],9} end).

with_voxel_view(Fun,Distance,Resources,ExtraBodies,FieldSetup) ->
    with_voxel_world(fun(F = #{namespace := Ns,identity := Identity,directory := Dir}) ->
        ModellingNs = <<"physics-test-modelling">>,
        Modelling = quod_agent_hosting_tests:start_ontology(ModellingNs,Dir,Identity,
            quod_prolog:terms_to_diff(quod_ct:gui_terms()),
            [{rendering_vocabulary,<<"physics-test-rendering">>,quod_simplex:genesis_hash(<<"physics-test-rendering">>)}]),
        try
        commit(Ns,{',',
            {retract,{modelling_vocabulary,<<"physics-test-rendering">>,
                quod_simplex:genesis_hash(<<"physics-test-rendering">>)}},
            {assertz,{modelling_vocabulary,ModellingNs,quod_simplex:genesis_hash(ModellingNs)}}}),
        Field = FieldSetup(F),
        Created = door_action(Ns,{voxel_create,room,0,
            {terrain_v1,unbounded,smooth,Field}}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Created), await_source_receipt(Created),
        lists:foreach(fun(Definition) -> commit(Ns,{assertz,Definition}) end,ExtraBodies),
        {Pid,World} = enable(F),
        Anchor = quod_simplex:genesis_hash(Ns),
        Presentation = {voxel_presentation,room,<<"land">>,
            [{material,9,{surface,<<"#447722">>,0,900,0,[]}}],Distance,Resources},
        commit(Ns,{',',{assertz,{agent_key,viewer,maps:get(pubkey,Identity),active}},
            {',',{assertz,{can_view_physics,room,{'_'}}},
                {assertz,Presentation}}}),
        commit(Ns,{assertz,{can_invoke,{'_'},
            {agent_instance_ref,Ns,Anchor,viewer},{'_'},Ns}}),
        reconcile(Ns),
        Parent = self(), Socket = spawn_link(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
        try
            Socket ! {client,simulation_open(F,simulation_session(Identity))},
            Projection = simulation_reply(Socket,<<"projection">>),
            Fun(F#{physics => Pid,world => World,socket => Socket,projection => Projection})
        after Socket ! stop end
        after quod_agent_hosting_tests:stop_ontology(Modelling) end
    end,lists:append([quod_prolog:read_terms("priv/ontologies/" ++ Name) ||
                      Name <- ["quod_space.pl", "voxel_world_view.pl"]])).


voxel_signed_camera_interest_reclaims_consumers_without_domain_writes_test_() ->
    Occupant = {physics_body_definition,room,7,2,controlled,{vector,2000,2000,2000},{owned,{ball,250},1}},
    {timeout,90,fun() -> with_voxel_view(fun(#{namespace := Ns,physics := Pid,world := World,
                                            socket := Socket,projection := Projection}) ->
        View = maps:get(<<"view">>,Projection), Frame = maps:get(<<"frame">>,Projection),
        Height = quod_prolog:applied(Ns),
        Interest = fun(Sequence,X) -> socket_command(Socket,#{type => terrain_interest,view => View,
            sequence => integer_to_binary(Sequence),centre_mm => [integer_to_binary(X),<<"2000">>,<<"2000">>]}) end,
        Interest(1,2000),
        socket_command(Socket,#{type => ack,view => View,tick => maps:get(<<"tick">>,Frame),
            origin_seq => maps:get(<<"origin_seq">>,Frame)}),
        First = consume_terrain_manifest(Socket,View,1),
        ?assertEqual(8,length(maps:get(<<"chunks">>,First))),
        #{World := #{spec := #{voxel_resources := Before}}} = worlds(Ns),
        [Terrain] = lists:usort([Id || {Id,_} <- maps:keys(Before)]),
        assert_no_physics_io(fun() ->
            Interest(1,2000),
            socket_command(Socket,#{type => terrain_interest,view => <<"stale">>,sequence => <<"20">>,
                centre_mm => [<<"18000">>,<<"2000">>,<<"2000">>]}),
            _ = simulation_state(Socket), _ = gen_server:call(Pid,status),reconcile(Ns)
        end),
        Interest(2,6000), Interest(3,18000),
        Last = consume_terrain_manifest(Socket,View,3),
        ?assertEqual(8,length(maps:get(<<"chunks">>,Last))),
        %% The current camera's nearest chunk is first; within the next shell,
        %% forward travel wins over sideways chunks. This is the actual signed
        %% delivery manifest, not a separate preview's ordering.
        [Nearest,Forward|_] = maps:get(<<"chunks">>,Last),
        ?assertEqual([<<"4">>,<<"0">>,<<"0">>],maps:get(<<"chunk">>,Nearest)),
        ?assertEqual([<<"5">>,<<"0">>,<<"0">>],maps:get(<<"chunk">>,Forward)),
        #{World := #{spec := #{voxel_resources := After}}} = worlds(Ns),
        #{World := #{terrain_demand := {Pid,_,_,_,Focus}}} = worlds(Ns),
        ?assertEqual({{18000,2000,2000},{12000,0,0}},maps:get(Terrain,Focus)),
        ?assertEqual(9,map_size(After)),
        Support = {Terrain,{chunk_v1,0,0,0}},
        ?assertEqual(maps:get(Support,Before),maps:get(Support,After)),
        ?assertEqual(Height,quod_prolog:applied(Ns)),
        ?assertEqual([], [K || K = {_,{chunk_v1,X,_,_}} <- maps:keys(After),X =/= 0,X =/= 4,X =/= 5]),
        Monitor = monitor(process,Socket),Socket ! stop,
        receive {'DOWN',Monitor,process,Socket,normal} -> ok after 5000 -> error(view_not_closed) end,
        await_voxel_chunks(Pid,World,[Support],quod_time:mono_ms()+10000),
        ?assertEqual(Height,quod_prolog:applied(Ns)),
        commit(Ns,{physics_remove_body,room,7,2,controlled,{vector,2000,2000,2000},{owned,{ball,250},1}}),
        await_voxel_chunks(Pid,World,[],quod_time:mono_ms()+10000),
        assert_no_physics_io(fun() -> reconcile(Ns),reconcile(Ns) end)
    end,{view_distance,1000,1000,2000},{resources,1000000,2000000,20000,10000,64},[Occupant]) end}.

voxel_camera_interest_refuses_its_signed_chunk_allowance_before_generation_test_() ->
    {timeout,90,fun() -> with_voxel_view(fun(#{namespace := Ns,physics := Pid,
                                            socket := Socket,projection := Projection}) ->
        Height = quod_prolog:applied(Ns),
        assert_no_physics_io(fun() ->
            socket_command(Socket,#{type => terrain_interest,view => maps:get(<<"view">>,Projection),
                sequence => <<"1">>,centre_mm => [<<"2000">>,<<"2000">>,<<"2000">>]}),
            Refused = simulation_reply(Socket,<<"unavailable">>),
            ?assertEqual(<<"terrain_chunk_allowance_exceeded">>,maps:get(<<"reason">>,Refused)),
            ?assertMatch(#{phase := active},gen_server:call(Pid,status)),reconcile(Ns)
        end),
        ?assertEqual(Height,quod_prolog:applied(Ns))
    end,{view_distance,1000,1000,2000},{resources,1000000,2000000,20000,10000,1},[]) end}.

voxel_camera_interest_refuses_an_incoherent_window_before_generation_test_() ->
    Occupant = {physics_body_definition,room,7,2,controlled,{vector,2000,2000,2000},{owned,{ball,250},1}},
    {timeout,90,fun() -> with_voxel_view(fun(#{namespace := Ns,physics := Pid,
                                            socket := Socket,projection := Projection}) ->
        Height = quod_prolog:applied(Ns),
        Before = gen_server:call(Pid,status),
        ?assertMatch(#{phase := active,navigation_ready := true},Before),
        assert_no_physics_io(fun() ->
            socket_command(Socket,#{type => terrain_interest,view => maps:get(<<"view">>,Projection),
                sequence => <<"1">>,centre_mm => [<<"4000000">>,<<"2000">>,<<"2000">>]}),
            Refused = simulation_reply(Socket,<<"unavailable">>),
            ?assertEqual(<<"coordinate_allowance">>,maps:get(<<"reason">>,Refused)),
            ?assertEqual(Before,gen_server:call(Pid,status)),reconcile(Ns)
        end),
        ?assertEqual(Height,quod_prolog:applied(Ns))
    end,{view_distance,1000,1000,2000},{resources,1000000,2000000,20000,10000,64},[Occupant]) end}.

voxel_camera_interest_admits_a_coherent_rebase_test_() ->
    Occupant = {physics_body_definition,room,7,2,controlled,{vector,2000,2000,2000},{owned,{ball,250},1}},
    {timeout,90,fun() -> with_voxel_view(fun(#{namespace := Ns,physics := Pid,world := World,
                                            socket := Socket,projection := Projection}) ->
        View = maps:get(<<"view">>,Projection), Frame = maps:get(<<"frame">>,Projection),
        Height = quod_prolog:applied(Ns), Before = gen_server:call(Pid,status),
        %% Outside the current local allowance, but inside a valid joint window
        %% after rebasing. The observer need not have its own controlled body.
        socket_command(Socket,#{type => terrain_interest,view => View,sequence => <<"1">>,
            centre_mm => [<<"1500000">>,<<"2000">>,<<"2000">>]}),
        socket_command(Socket,#{type => ack,view => View,tick => maps:get(<<"tick">>,Frame),
            origin_seq => maps:get(<<"origin_seq">>,Frame)}),
        Manifest = consume_terrain_manifest(Socket,View,1),
        ?assertEqual(8,length(maps:get(<<"chunks">>,Manifest))),
        After = gen_server:call(Pid,status),
        ?assertMatch(#{phase := active,navigation_ready := true},After),
        ?assertEqual(maps:get(incarnation,Before),maps:get(incarnation,After)),
        #{World := #{spec := Spec}} = worlds(Ns),
        Expected = #{fence => quod_physics:fence(Spec),structure => maps:get(structure,Spec),
                     incarnation => maps:get(incarnation,After)},
        {ok,_,Origin,{7,2,world,Local,_,_}} = quod_physics:body_state(Pid,Expected,{7,2},1000),
        ?assert(element(1,Origin) > 0),
        ?assertEqual({2000,2000,2000},quod_physics_coordinates:canonical(Local,Origin)),
        assert_no_physics_io(fun() -> reconcile(Ns),reconcile(Ns) end),
        ?assertEqual(Height,quod_prolog:applied(Ns))
    end,{view_distance,1000,1000,2000},{resources,1000000,2000000,20000,10000,64},[Occupant]) end}.

voxel_obstruction_reports_the_body_and_recovers_in_place_test_() ->
    [{atom_to_list(Correction),{timeout,30,fun() ->
        Limits = {prepare_limits,{sampling_limits,1331,100000,100000,3993},
                  {surface_limits,512,10000,10000},69120,500000},
        Field = {field_v1,1,500,[{plane,1000}],9},
        {ok,{Artifact = #{handle := Handle},generated}} =
            quod_voxel:prepare(Field,{chunk_v1,0,0,0},[],Limits,none),
        with_simulator(none,fun(Pid,Spec) ->
            {Activation,Token} = receive
                {physics_work,Pid,_,Act,activate,{{physics_activate,room,0,T},_,_},_} -> {Act,T}
            after 5000 -> error(activation_missing) end,
            Terrain = {0,1,fixed,{world_mm,{0,0,0},{0.0,0.0,0.0}},
                       {terrain,500,[{{0,0,0},Handle}]},1.0},
            Body = {1,1,controlled,{world_mm,{2000,500,2000},{0.0,0.0,0.0}},
                    {solid,{ball,0.25}},1.0},
            Current = Spec#{generation => 1,run_token => Token,
                custody => {request,Token,0,<<2>>,<<0:512>>},
                limits => {2,2,8,1000.0,2,10000,10000},dt => 1/60,gravity => 0.0,
                structure => 1,activities => #{},bodies => [Terrain,Body],
                voxel_resources => #{{0,{chunk_v1,0,0,0}} => Artifact}},
            Pid ! {physics_selected,self(),make_ref(),Current},
            Pid ! {physics_result,self(),Activation,{ok,ignored,{normalized,{committed,ignored,ignored}}}},
            receive {physics_status,Pid,_,Token,{unavailable,{terrain_occupied,1,0}}} -> ok
            after 5000 -> error(obstruction_notice_missing) end,
            Before = gen_server:call(Pid,status),
            ?assertMatch(#{phase := {blocked,{terrain_occupied,1,0}},steps := 0,
                          navigation_ready := false},Before),
            assert_no_physics_io(fun() ->
                Pid ! {physics_selected,self(),make_ref(),Current},
                ?assertEqual(Before,gen_server:call(Pid,status))
            end),
            {Updated,Position} = case Correction of
                body ->
                    Clear = setelement(4,setelement(2,Body,2),{world_mm,{2000,2000,2000},{0.0,0.0,0.0}}),
                    {Current#{bodies => [Terrain,Clear]},{2000,2000,2000}};
                terrain ->
                    {ok,{Air = #{handle := AirHandle},generated}} =
                        quod_voxel:prepare({field_v1,1,500,[{plane,-1000}],9},{chunk_v1,0,0,0},[],Limits,none),
                    Dug = setelement(5,setelement(2,Terrain,2),{terrain,500,[{{0,0,0},AirHandle}]}),
                    {Current#{bodies => [Dug,Body],voxel_resources => #{{0,{chunk_v1,0,0,0}} => Air}},
                     {2000,500,2000}}
            end,
            Pid ! {physics_selected,self(),make_ref(),Updated},
            receive {physics_status,Pid,_,Token,installed} -> ok after 5000 -> error(corrected_install_missing) end,
            ?assertMatch(#{phase := active,incarnation := Token,navigation_ready := true},gen_server:call(Pid,status)),
            Revision = case Correction of body -> 2; terrain -> 1 end,
            Expected = #{fence => quod_physics:fence(Updated),structure => 1,incarnation => Token},
            {ok,_,Origin,{1,Revision,world,Local,_,_}} = quod_physics:body_state(Pid,Expected,{1,Revision},1000),
            ?assertEqual(Position,quod_physics_coordinates:canonical(Local,Origin)),
            BadBinding = Expected#{terrain => [{99,1,{view_distance,1000,1000,2000},
                                               [1000000,2000000,20000,10000,64]}]},
            {ok,ViewRef,_} = quod_physics:watch(Pid,BadBinding,none),
            assert_no_physics_io(fun() ->
                quod_physics:view_interest(Pid,ViewRef,1,Position),
                receive {physics_resource,Pid,ViewRef,{terrain_unavailable,invalid_terrain_binding}} -> ok
                after 5000 -> error(invalid_binding_not_refused) end,
                ?assertMatch(#{phase := active,navigation_ready := true},gen_server:call(Pid,status))
            end)
        end)
    end}} || Correction <- [body,terrain]].

socket_command(Socket,Message) -> Socket ! {client,iolist_to_binary(json:encode(Message))}.

consume_terrain_manifest(Socket,View,Target) ->
    Manifest = terrain_reply(Socket,View,<<"terrain_manifest">>),
    #{<<"token">> := Token,<<"interest_seq">> := Sequence} = Manifest,
    socket_command(Socket,#{type => terrain_ack,view => View,token => Token,want => []}),
    Content = terrain_reply(Socket,View,<<"terrain_chunks">>),
    ?assertEqual(Token,maps:get(<<"token">>,Content)),?assertEqual([],maps:get(<<"chunks">>,Content)),
    socket_command(Socket,#{type => terrain_ack,view => View,token => Token,complete => true}),
    case binary_to_integer(Sequence) of
        Target -> Manifest;
        Earlier when Earlier < Target -> consume_terrain_manifest(Socket,View,Target);
        Other -> error({unexpected_interest,Other,Target})
    end.

terrain_reply(Socket,View,Type) -> terrain_reply(Socket,View,Type,quod_time:mono_ms()+10000).
terrain_reply(Socket,View,Type,Deadline) ->
    receive
        {simulation,Socket,#{<<"type">> := Type,<<"view">> := View} = Message} -> Message;
        {simulation,Socket,#{<<"type">> := <<"simulation_frame">>,<<"view">> := View,<<"frame">> := Frame}} ->
            socket_command(Socket,#{type => ack,view => View,tick => maps:get(<<"tick">>,Frame),
                origin_seq => maps:get(<<"origin_seq">>,Frame)}),
            terrain_reply(Socket,View,Type,Deadline);
        {simulation,Socket,Other} -> error({terrain_view_unavailable,Other})
    after max(0,Deadline-quod_time:mono_ms()) -> error({terrain_reply_missing,Type}) end.

voxel_dig_preserves_a_loaded_resting_body_in_the_same_chunk_test_() ->
    {timeout,90,fun() -> with_voxel_world(fun(F = #{namespace := Ns}) ->
        %% The fixture authors enough resident chunks for Rapier's conservative
        %% dynamic-body envelope; this is ordinary Prolog resource policy.
        Policy = {voxel_allowances,room,{voxel_limits,{sampling_limits,1331,10648,85184,3993},
                    {surface_limits,512,10000,10000},64,69120,1048576}},
        commit(Ns,{',',{retract,Policy},{assertz,setelement(3,Policy,setelement(4,element(3,Policy),128))}}),
        Created = door_action(Ns,{voxel_create,room,0,
            {terrain_v1,unbounded,smooth,{field_v1,1,500,[{plane,1000}],9}}}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Created),await_source_receipt(Created),
        commit(Ns,{',',
            {assertz,{physics_body_definition,room,7,2,dynamic,{vector,2000,1500,2000},{owned,{box,600,400,600},1}}},
            {assertz,{physics_body_definition,room,8,2,dynamic,{vector,2000,3000,2000},{owned,{box,400,400,400},100}}}}),
        {Pid,World} = enable(F),
        receive {physics_status,_,Pid,World,_,sleeping} -> ok after 15000 -> error(stack_did_not_settle) end,
        Before = gen_server:call(Pid,status),flush_sleeping(Pid),
        #{World := #{spec := Spec}} = worlds(Ns),
        assert_loaded_stack(Pid,Spec),
        Brush = {dig_sphere,{vector,3500,750,3500},300},
        Dig = door_action(Ns,{',',{voxel_edit_basis,room,Brush,{'R'},{'Cs'}},
                                  {voxel_edit,room,{'R'},{'Cs'},Brush}}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Dig),await_source_receipt(Dig),
        {Pid,World} = installed_structure(Ns,3),
        receive {physics_status,_,Pid,World,_,sleeping} -> ok after 15000 -> error(stack_stopped_after_dig) end,
        After = gen_server:call(Pid,status),
        ?assertMatch(#{phase := active,navigation_ready := true},After),
        ?assertEqual(maps:get(incarnation,Before),maps:get(incarnation,After)),
        ?assert(maps:get(steps,After) > maps:get(steps,Before)),
        #{World := #{spec := NewSpec}} = worlds(Ns),
        assert_loaded_stack(Pid,NewSpec),
        [Terrain] = lists:usort([Id || {Id,_} <- maps:keys(maps:get(voxel_resources,Spec))]),
        Key = {Terrain,{chunk_v1,0,0,0}},
        ?assertNotEqual(maps:get(input_digest,maps:get(Key,maps:get(voxel_resources,Spec))),
                        maps:get(input_digest,maps:get(Key,maps:get(voxel_resources,NewSpec)))),
        assert_no_physics_io(fun() -> reconcile(Ns),reconcile(Ns) end)
    end) end}.

assert_loaded_stack(Pid,Spec) ->
    {ok,Frame,_} = quod_physics:snapshot(Pid,#{fence => quod_physics:fence(Spec),
                                            structure => maps:get(structure,Spec),tick => -1}),
    ?assert(lists:any(fun({A,_,B,_}) -> lists:sort([A,B]) =:= [7,8] end,maps:get(contacts,Frame))),
    {7,_,world,{_,Lower,_},_,_} = lists:keyfind(7,1,maps:get(poses,Frame)),
    {8,_,world,{_,Upper,_},_,_} = lists:keyfind(8,1,maps:get(poses,Frame)),
    ?assert(Upper-Lower > 0.7).

voxel_pending_restore_keeps_its_original_insertion_test_() ->
    [{atom_to_list(Change),fun() ->
        Field = {field_v1,1,500,[{plane,-1000}],9},
        Limits = {prepare_limits,{sampling_limits,1331,100000,100000,3993},
                  {surface_limits,512,10000,10000},69120,500000},
        {ok,{#{handle := Handle},generated}} = quod_voxel:prepare(Field,{chunk_v1,0,0,0},[],Limits,none),
        with_simulator(none,fun(Pid,Spec) ->
            {Activation,Token} = receive
                {physics_work,Pid,_,Act,activate,{{physics_activate,room,0,T},_,_},_} -> {Act,T}
            after 5000 -> error(activation_missing) end,
            Terrain = {0,1,fixed,{world_mm,{0,0,0},{0.0,0.0,0.0}},
                       {terrain,500,[{{0,0,0},Handle}]},1.0},
            Actor = {1,1,dynamic,{world_mm,{2000,2000,2000},{0.0,0.0,0.0}},{solid,{ball,0.25}},1.0},
            CP = {1,1,{{18000,2000,2000},{0.0,0.0,0.0,1.0}},0.005,128},
            Current = Spec#{generation => 1,run_token => Token,
                custody => {request,Token,0,<<2>>,<<0:512>>},
                limits => {2,2,1,1000.0,2,10000,10000},dt => 0.001,gravity => 0.0,structure => 1,
                activities => #{},bodies => [Terrain,Actor],restores => [CP]},
            Pid ! {physics_selected,self(),make_ref(),Current},
            Pid ! {physics_result,self(),Activation,{ok,ignored,{normalized,{committed,ignored,ignored}}}},
            receive {physics_terrain_demand,Pid,_,Token,1,Required,_} ->
                ?assert(lists:member({0,{4,0,0},{4,0,0}},Required))
            after 5000 -> error(restore_demand_missing) end,
            ?assertMatch(#{phase := coverage},gen_server:call(Pid,status)),
            assert_no_physics_io(fun() ->
                Pid ! {physics_selected,self(),make_ref(),Current},
                _ = gen_server:call(Pid,status),
                Pid ! {physics_selected,self(),make_ref(),Current#{agent_controls => [],agent_bindings => []}},
                Pid ! advance,
                ?assertMatch(#{phase := coverage},gen_server:call(Pid,status)),
                %% A refused frame must not make an unfinished restore ready
                %% when the original selection is restored unchanged.
                Far = setelement(5,Terrain,{terrain,500,[{{4000000,0,0},Handle}]}),
                Pid ! {physics_selected,self(),make_ref(),Current#{bodies => [Far,Actor]}},
                ?assertMatch(#{phase := {blocked,coordinate_allowance}},gen_server:call(Pid,status)),
                Pid ! {physics_selected,self(),make_ref(),Current},
                ?assertMatch(#{phase := coverage,navigation_ready := false},gen_server:call(Pid,status)),
                receive {physics_terrain_demand,Pid,_,Token,_,Unexpected,_} ->
                    error({pending_restore_demand_replaced,Unexpected})
                after 0 -> ok end
            end),
            Updated = Current#{restores => case Change of
                removed -> [];
                changed -> [setelement(3,CP,{{22000,2000,2000},{0.0,0.0,0.0,1.0}})]
            end},
            Pid ! {physics_selected,self(),make_ref(),Updated},
            ?assertMatch(#{phase := coverage},gen_server:call(Pid,status)),
            Resident = setelement(5,Terrain,{terrain,500,[{{16000,0,0},Handle}]}),
            Pid ! {physics_selected,self(),make_ref(),Updated#{bodies => [Resident,Actor]}},
            receive {physics_status,Pid,_,Token,installed} -> ok after 5000 -> error(restore_install_missing) end,
            Expected = #{fence => quod_physics:fence(Current),structure => 1,incarnation => Token},
            {ok,_,Origin,{1,1,world,Position,_,_}} = quod_physics:body_state(Pid,Expected,{1,1},1000),
            ?assertEqual({18000,2000,2000},quod_physics_coordinates:canonical(Position,Origin))
        end)
    end} || Change <- [changed,removed]].

voxel_viewer_removal_preserves_unfinished_physics_test_() ->
    [{atom_to_list(Wait),fun() ->
        Field = {field_v1,1,500,[{plane,-1000}],9},
        Limits = {prepare_limits,{sampling_limits,1331,100000,100000,3993},
                  {surface_limits,512,10000,10000},69120,500000},
        {ok,{#{handle := Handle},generated}} = quod_voxel:prepare(Field,{chunk_v1,0,0,0},[],Limits,none),
        with_simulator(none,fun(Pid,Spec) ->
            {Activation,Token} = receive
                {physics_work,Pid,_,Act,activate,{{physics_activate,room,0,T},_,_},_} -> {Act,T}
            after 5000 -> error(activation_missing) end,
            Terrain = {0,1,fixed,{world_mm,{0,0,0},{0.0,0.0,0.0}},
                       {terrain,500,[{{0,0,0},Handle}]},1.0},
            Actor = {1,1,dynamic,{world_mm,{2000,2000,2000},{0.0,0.0,0.0}},{solid,{ball,0.25}},1.0},
            Current = Spec#{generation => 1,run_token => Token,
                custody => {request,Token,0,<<2>>,<<0:512>>},
                limits => {2,2,1,1000.0,2,10000,10000},dt => 0.001,gravity => 0.0,structure => 1,
                activities => #{},bodies => [Terrain,Actor],restores => []},
            Pid ! {physics_selected,self(),make_ref(),Current},
            Pid ! {physics_result,self(),Activation,{ok,ignored,{normalized,{committed,ignored,ignored}}}},
            receive {physics_status,Pid,_,Token,installed} -> ok after 5000 -> error(initial_install_missing) end,
            Expected = #{fence => quod_physics:fence(Current),structure => 1,incarnation => Token},
            {ok,View,_} = quod_physics:watch(Pid,Expected,none),
            Waiting = case Wait of
                restoration -> Current#{structure => 2,bodies => [Terrain,setelement(2,Actor,2)],
                    restores => [{1,2,{{18000,2000,2000},{0.0,0.0,0.0,1.0}},0.005,128}]};
                body_coverage -> Current#{structure => 2,bodies => [setelement(5,Terrain,{terrain,500,[]}),Actor]}
            end,
            Pid ! {physics_selected,self(),make_ref(),Waiting},
            ?assertMatch(#{phase := coverage,navigation_ready := false},gen_server:call(Pid,status)),
            quod_physics:unwatch(Pid,View),
            ?assertMatch(#{phase := coverage,navigation_ready := false},gen_server:call(Pid,status)),
            Resident = case Wait of
                restoration -> setelement(5,Terrain,{terrain,500,[{{16000,0,0},Handle}]});
                body_coverage -> Terrain
            end,
            [_OldTerrain,RetainedActor] = maps:get(bodies,Waiting),
            Pid ! {physics_selected,self(),make_ref(),Waiting#{bodies => [Resident,RetainedActor]}},
            ?assertMatch(#{phase := active,navigation_ready := true},gen_server:call(Pid,status))
        end)
    end} || Wait <- [restoration,body_coverage]].

voxel_checkpoint_recovery_loads_missing_terrain_test_() ->
    {timeout,90,fun() -> with_voxel_world(fun(F = #{namespace := Ns}) ->
        Allowance = {physics_allowances,room,
            {limits,64,64,256,1000000,{geometry,256,4096,4096}},16667,-9810,10000},
        commit(Ns,{',',{retract,Allowance},{assertz,setelement(4,setelement(5,Allowance,0),1000)}}),
        Created = door_action(Ns,{voxel_create,room,0,
            {terrain_v1,unbounded,smooth,{field_v1,1,500,[{plane,1000}],9}}}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Created),await_source_receipt(Created),
        commit(Ns,{',',{assertz,{physics_body_definition,room,3,2,dynamic,
            {vector,2000,2000,2000},{owned,{ball,250},1}}},
            {assertz,{physics_rest_policy,room,3,{recovery,5,128}}}}),
        {Pid,World} = enable(F),
        #{World := #{spec := Spec}} = worlds(Ns),
        Source = {source,maps:get(authority,Spec),maps:get(epoch,Spec),maps:get(generation,Spec),
                  maps:get(run_token,Spec),2,1},
        CP = {rest_v1,3,2,Source,world_mm_quaternion_million,
              {pose,{vector,18000,2000,2000},{quaternion,0,0,0,1000000}},zero_velocity},
        commit(Ns,{assertz,{physics_checkpoint,room,CP}}),reconcile(Ns),
        ?assert(lists:all(fun({_,C}) -> C =/= {chunk_v1,4,0,0} end,
                         maps:keys(maps:get(voxel_resources,Spec)))),
        Monitor = monitor(process,Pid),exit(Pid,kill),
        receive {'DOWN',Monitor,process,Pid,killed} -> ok after 5000 -> error(owner_alive) end,
        {Next,World} = installed(Ns),?assertNotEqual(Pid,Next),
        #{World := #{spec := Recovered}} = worlds(Ns),
        Fresh = #{fence => quod_physics:fence(Recovered),structure => 2,
                  incarnation => maps:get(run_token,Recovered)},
        {ok,_,Origin,{3,2,world,Position,_,_}} = quod_physics:body_state(Next,Fresh,{3,2},1000),
        ?assertEqual({18000,2000,2000},quod_physics_coordinates:canonical(Position,Origin)),
        ?assert(lists:any(fun({_,C}) -> C =:= {chunk_v1,4,0,0} end,
                         maps:keys(maps:get(voxel_resources,Recovered)))),
        assert_no_physics_io(fun() -> reconcile(Ns),reconcile(Ns) end)
    end) end}.

voxel_large_origin_rebases_pending_motion_without_restart_test_() ->
    {timeout,90,fun() -> with_voxel_world(fun(F = #{namespace := Ns,node := Human}) ->
        Cx = 1 bsl 100, Huge = Cx*4000,
        Initial = {voxel_initial_chunks,room,{'_'},[{chunk_v1,0,0,0},{chunk_v1,1,0,0},{chunk_v1,3,0,0}]},
        Before = {physics_allowances,room,{limits,64,64,256,1000000,{geometry,256,4096,4096}},16667,-9810,10000},
        After = setelement(3,Before,{limits,64,64,256,12000,{geometry,256,4096,4096}}),
        commit(Ns,{',',{retract,Initial},{',',{assertz,{voxel_initial_chunks,room,{'_'},[{chunk_v1,Cx,0,0}]}},
            {',',{retract,Before},{assertz,After}}}}),
        Created = door_action(Ns,{voxel_create,room,0,
            {terrain_v1,unbounded,smooth,{field_v1,1,500,[{plane,1000}],9}}}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Created),await_source_receipt(Created),
        Position = {vector,Huge+2000,2000,2000},
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
            {physics_checked_body,7,controlled,Position,{ball,250},1,12000})),
        commit(Ns,{assertz,{physics_body_definition,room,7,2,controlled,Position,{owned,{ball,250},1}}}),
        {Pid,World} = enable(F), Limits = {query_limits,2,0,8,128},
        {_,Expected,_,Ref,First} = install_test_control(F,Pid,World,
            {motion,free,2000,1600,1000,Limits,[reposition]},7),
        ?assertEqual({Huge,0,0},maps:get(origin,First)),
        quod_physics:ack(Pid,Ref,maps:get(tick,First),maps:get(origin_sequence,First)),
        Installed = Expected#{registration => maps:get(registration,First)},
        Control = maps:get(control,Expected),
        ok = quod_physics:input(Pid,Installed,Control,1,
            {{reposition,{vector,Huge+18000,2000,2000}},Limits},quod_time:now_ms()+10000,quod_time:mono_ms()+10000),
        {Moved,{clear,_,_}} = input_frame(Pid,Ref,Human,1),
        {7,2,world,Local,_,_} = lists:keyfind(7,1,maps:get(poses,Moved)),
        ?assertEqual({Huge+18000,2000,2000},quod_physics_coordinates:canonical(Local,maps:get(origin,Moved))),
        ?assert(maps:get(origin_sequence,Moved) > maps:get(origin_sequence,First)),
        ?assertEqual(maps:get(incarnation,First),maps:get(incarnation,Moved)),
        ?assertEqual(maps:get(registration,First),maps:get(registration,Moved)),
        #{World := #{spec := #{voxel_resources := CurrentChunks}}} = worlds(Ns),
        [TerrainBody] = lists:usort([Id || {Id,_} <- maps:keys(CurrentChunks)]),
        await_voxel_chunks(Pid,World,[{TerrainBody,{chunk_v1,Cx+4,0,0}}],quod_time:mono_ms()+5000),
        assert_no_physics_io(fun() -> reconcile(Ns),reconcile(Ns) end),
        %% An absolute command authored before the shift retains its meaning.
        ok = quod_physics:input(Pid,Installed,Control,2,
            {{reposition,Position},Limits},quod_time:now_ms()+10000,quod_time:mono_ms()+10000),
        {Returned,{clear,_,_}} = input_frame(Pid,Ref,Human,2),
        {7,2,world,Back,_,_} = lists:keyfind(7,1,maps:get(poses,Returned)),
        ?assertEqual({Huge+2000,2000,2000},quod_physics_coordinates:canonical(Back,maps:get(origin,Returned)))
    end) end}.

await_voxel_chunks(Pid,World,Keys,Deadline) ->
    case gen_server:call(Pid,status) of
        #{phase := active,terrain_chunks := Keys} -> ok;
        _ -> receive
            {physics_status,_,Pid,World,_,_} -> await_voxel_chunks(Pid,World,Keys,Deadline)
        after max(0,Deadline-quod_time:mono_ms()) ->
            error({terrain_residency_not_installed,Keys,gen_server:call(Pid,status)}) end
    end.
