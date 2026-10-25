-module(quod_voxel_world_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

composed_gui_world_membership_enumeration_terminates_test() ->
    with_world(["voxel_world_gui.pl","lobby_worlds.pl"],fun(Store0,Owner) ->
        Query = {findall,{'W'},{instance_of,voxel_world,{'W'}},{'Worlds'}},
        ?assertEqual([],value({'Worlds'},Query,Store0)),
        Setup = quod_ct:source_assertions([{instance_of,voxel_world,land},
            {voxel_world_owner,land,Owner},{lobby_owner,Owner},
            {instance_of,sky_sphere,{world_sky,land}}]),
        {Store1,_} = commit(lists:foldr(fun(G,Rest) -> {',',G,Rest} end,true,Setup),Store0),
        ?assertEqual([land],value({'Worlds'},Query,Store1)),
        ?assertEqual(1,value({'N'},{world_library_count,{'N'}},Store1)),
        {Store2,_} = commit({retract,{lobby_owner,Owner}},Store1),
        ?assertEqual([{world_sky,land}],value({'Skies'},
            {findall,{'S'},{instance_of,sky_sphere,{'S'}},{'Skies'}},Store2))
    end).

sparse_chunk_inputs_preserve_absence_neighbors_and_ambiguity_test() ->
    with_world(fun(Store0,_) ->
        {Store1,_} = commit({voxel_create,land,0,spec()},Store0),
        Chunk = {chunk_v1,-1,0,0},
        Query = {voxel_chunk_inputs,land,Chunk,{'Field'},{'Rows'}},
        St = view(Store1),
        try
            Final = prove(Query,St),
            ?assertEqual([],erlog_int:dderef({'Rows'},Final#est.bs)),
            ?assert(maps:is_key({voxel_chunk_override,4},
                quod_erlog_db_local_prove:get_read_set(db_ref(Final))))
        after quod_erlog_db_local_prove:cleanup_read_set(St) end,
        Near = {chunk_v1,-2,1,1},Far = {chunk_v1,1,0,0},
        Patch = {patch_v1,<<0:16,127:8,9:16>>},
        {Store2,_} = commit({',',{assertz,{voxel_chunk_override,land,Near,1,Patch}},
            {assertz,{voxel_chunk_override,land,Far,1,Patch}}},Store1),
        ?assertEqual([{override,Near,Patch}],value({'Rows'},Query,Store2)),
        {Ambiguous,_} = commit({assertz,{voxel_chunk_override,land,Near,2,Patch}},Store2),
        assert_refused(Query,Ambiguous,ambiguous_voxel_patch)
    end).

world_library_spawn_candidates_cover_supported_presets_test_() ->
    {timeout,60,fun() -> with_world(["voxel_world_gui.pl","lobby_worlds.pl"],fun(Store,_) ->
        lists:foreach(fun({Preset,Spacing,Mode,Hills,Caves}) ->
            Recipe = {recipe,Preset,1947,Spacing,Mode,16,128,Hills,Caves},
            Spec = value({'S'},{voxel_generation_spec,Recipe,{'S'}},Store),
            {vector,0,Y,0} = value({'P'},{world_spawn_candidate,Spec,{'P'}},Store),
            Field = value({'F'},{voxel_sampling_field,Spec,{'F'}},Store),
            {view_distance,Distance,Prefetch,Retention} =
                value({'View'},{world_initial_view,Spec,{'View'}},Store),
            ?assertEqual({16*Spacing,4*Spacing,8*Spacing},{Distance,Prefetch,Retention}),
            %% Even fine detail has a bounded initial chunk window at every
            %% camera position; the renderer admits the generated mesh too.
            Axis = (2*(Distance+Retention)+8*Spacing-1) div (8*Spacing)+1,
            ?assert(Axis*Axis*Axis =< 1024),
            %% Cover every lattice corner enclosing the capsule (half-height
            %% 750 mm, radius 250 mm), not just the centre sample.
            Low = (Y-750) div Spacing, High = (Y+750+Spacing-1) div Spacing,
            {ok,{samples_v1,D,_}} = quod_voxel:sample(Field,{vector,-1,Low,-1},
                {dimensions,3,High-Low+1,3},{sampling_limits,100,1000,4000,300}),
            ?assert(lists:all(fun(V) -> V < 128 end,binary_to_list(D)),{Recipe,Y,D}),
            {WithArrival,_} = commit({assertz,{world_arrival,{spawn,Recipe},{vector,0,Y,0}}},Store),
            [_Chunk] = value({'C'},{voxel_initial_chunks,{spawn,Recipe},Spec,{'C'}},WithArrival)
        end,[{P,S,M,H,C} || P <- [meadow,highlands,badlands],S <- [500,1000,2000],
            M <- [bounded,unbounded],H <- [0,300],C <- [0,40]])
    end) end}.

creation_and_boundary_dig_use_one_existing_atomic_diff_test() ->
    with_world(fun(Store0,Owner) ->
        {Store1,Created} = commit({voxel_create,land,0,spec()},Store0),
        ?assert(length(Created) > 0),
        ?assertEqual(Owner,value({'P'},{voxel_world_owner,land,{'P'}},Store1)),
        ?assertEqual([land],value({'Worlds'},
            {findall,{'W'},{clause,{instance_of,voxel_world,{'W'}},true},{'Worlds'}},Store1)),
        ?assertEqual([0],value({'L'},{findall,{'B'},
            {voxel_terrain_binding,land,{'B'},2},{'L'}},Store1)),
        Brush = {dig_sphere,{vector,4000,0,0},600},
        Expected = basis(Brush,Store1),
        {Store2,Dig} = commit({voxel_edit,land,1,Expected,Brush},Store1),
        ?assertEqual(8,length(Expected)),
        ?assert(lists:any(fun({assert,{{voxel_chunk_override,land,_,1,_},_}}) -> true;
                            (_) -> false end,Dig)),
        ?assertEqual(3,value({'R'},{voxel_terrain_binding,land,0,{'R'}},Store2)),
        ?assertEqual(1,value({'R'},{voxel_world_definition,land,{'R'},spec()},Store2)),
        %% The existing committed projection applies the complete returned
        %% diff. Reconstructing a proof from it sees the current patches.
        Current = basis(Brush,Store2),
        ?assertNotEqual(Expected,Current),
        {Store3,Noop} = commit({voxel_edit,land,1,Current,Brush},Store2),
        ?assertEqual([],Noop),
        ?assertEqual(3,value({'R'},{physics_structure,land,{'R'}},Store3)),
        ?assertEqual(preserved,value({'C'},{physics_checkpoint,land,{'C'}},Store3)),
        assert_refused({voxel_edit,land,1,Expected,Brush},Store3,voxel_patch_conflict),
        assert_refused({voxel_create,land,0,spec()},Store3,voxel_world_conflict)
    end).

late_validation_failure_and_outer_cut_roll_back_all_chunks_test() ->
    with_world(fun(Store0,_) ->
        {Store1,_} = commit({voxel_create,land,0,spec()},Store0),
        Brush = {dig_sphere,{vector,4000,0,0},600},
        Goal = {voxel_edit,land,1,basis(Brush,Store1),Brush},
        TooSmall = {voxel_limits,sampling(),{surface_limits,512,10000,0},64,69120,1048576},
        Attempt = {transaction,{',',{retract,{voxel_allowances,land,limits()}},
            {',',{assertz,{voxel_allowances,land,TooSmall}},Goal}}},
        assert_refused(Attempt,Store1,voxel_triangle_allowance),
        %% Even a cut in the outer transaction cannot retain earlier patches.
        assert_refused({transaction,{',',Goal,{',','!',fail}}},Store1,any),
        ?assertEqual([],value({'Rows'},{findall,{'P'},
            {voxel_chunk_override,land,{'_'},{'_'},{'P'}},{'Rows'}},Store1)),
        ?assertEqual(2,value({'R'},{physics_structure,land,{'R'}},Store1))
    end).

paint_preserves_physical_revision_and_revocation_refuses_edits_test() ->
    with_world(fun(Store0,Owner) ->
        {Store1,_} = commit({voxel_create,land,0,spec()},Store0),
        Brush = {paint_sphere,{vector,500,500,500},1,42},
        {Store2,Ops} = commit({voxel_edit,land,1,basis(Brush,Store1),Brush},Store1),
        ?assertEqual(1,length(Ops)),
        ?assertEqual(2,value({'R'},{voxel_terrain_binding,land,0,{'R'}},Store2)),
        Expected = basis(Brush,Store2),
        {Store3,_} = commit({retract,{can_edit_voxel_world,land,Owner,{'_'}}},Store2),
        assert_refused({voxel_edit,land,1,Expected,Brush},Store3,any)
    end).

regeneration_and_removal_fence_edits_and_never_reuse_body_identity_test() ->
    with_world(fun(Store0,Owner) ->
        {Store1,_} = commit({voxel_create,land,0,spec()},Store0),
        Brush = {dig_sphere,{vector,500,500,500},600},
        {Store2,_} = commit({voxel_edit,land,1,basis(Brush,Store1),Brush},Store1),
        Versions = value({'V'},{voxel_lifecycle_basis,land,1,{'V'}},Store2),
        ?assertNotEqual([],Versions),
        NextSpec = {terrain_v1,unbounded,smooth,{field_v1,2,500,[{plane,2000}],9}},
        assert_refused({voxel_regenerate,land,1,[],NextSpec},Store2,voxel_patch_conflict),
        assert_refused({voxel_regenerate,land,1,Versions,NextSpec},Store2,voxel_world_edited),
        {Store4,_} = commit({voxel_remove,land,1,Versions},Store2),
        ?assertEqual(none,value({'S'},{voxel_world_definition,land,2,{'S'}},Store4)),
        ?assertEqual([],value({'B'},{findall,{'Id'},{physics_body_definition,land,{'Id'},{'_'},{'_'},{'_'},{'_'}},{'B'}},Store4)),
        {Store5,_} = commit({voxel_create,land,2,spec()},Store4),
        ?assertEqual(1,value({'B'},{voxel_terrain_binding,land,{'B'},5},Store5)),
        ?assertEqual(Owner,value({'P'},{voxel_world_owner,land,{'P'}},Store5))
    end).

regeneration_before_editing_keeps_body_identity_and_fences_old_drafts_test() ->
    with_world(fun(Store0,_) ->
        {Store1,_} = commit({voxel_create,land,0,spec()},Store0),
        NextSpec = {terrain_v1,unbounded,smooth,{field_v1,2,500,[{plane,2000}],9}},
        {Store2,_} = commit({voxel_regenerate,land,1,[],NextSpec},Store1),
        ?assertEqual(0,value({'B'},{voxel_terrain_binding,land,{'B'},3},Store2)),
        assert_refused({voxel_edit,land,1,[],{dig_sphere,{vector,500,500,500},600}},
                       Store2,voxel_world_conflict)
    end).

lifecycle_refuses_occupants_and_rolls_back_late_validation_test() ->
    with_world(fun(Store0,Owner) ->
        {Store1,_} = commit({voxel_create,land,0,spec()},Store0),
        Body = {physics_body_definition,land,5,2,dynamic,{vector,0,3000,0},{owned,{ball,100},1}},
        {Occupied,_} = commit({assertz,Body},Store1),
        assert_refused({voxel_remove,land,1,[]},Occupied,voxel_world_occupied),
        assert_refused({voxel_regenerate,land,1,[],spec()},Occupied,voxel_world_occupied),
        Bad = {terrain_v1,unbounded,smooth,{field_v1,1,500,[{plane,1000},{carve_sphere,{vector,0,0,0},bad}],9}},
        assert_refused({voxel_regenerate,land,1,[],Bad},Store1,any),
        Denied = {voxel_limits,sampling(),{surface_limits,512,10000,0},64,69120,1048576},
        assert_refused({transaction,{',',{retract,{voxel_allowances,land,limits()}},
            {',',{assertz,{voxel_allowances,land,Denied}},
             {voxel_regenerate,land,1,[],spec()}}}},Store1,voxel_triangle_allowance),
        assert_refused({transaction,{',',{voxel_remove,land,1,[]},{',','!',fail}}},Store1,any),
        {Revoked,_} = commit({retract,{can_manage_voxel_world,land,Owner,{'_'}}},Store1),
        assert_refused({voxel_remove,land,1,[]},Revoked,any),
        ?assertEqual(2,value({'R'},{voxel_terrain_binding,land,0,{'R'}},Store1))
    end).

spec() -> {terrain_v1,unbounded,smooth,{field_v1,1,500,[{plane,1000}],9}}.
sampling() -> {sampling_limits,1331,10648,85184,3993}.
limits() -> {voxel_limits,sampling(),{surface_limits,512,10000,10000},64,69120,1048576}.
basis(Brush,Store) -> value({'Rows'},{voxel_edit_basis,land,Brush,1,{'Rows'}},Store).

with_world(Fun) ->
    with_world([],Fun).
with_world(ExtraSources,Fun) ->
    Target = {Ns,Anchor} = {<<"voxel-domain">>,<<71:256>>},
    #{principal := Principal,evidence := Evidence,agent_reference := Owner} =
        quod_ct:signed_goal_fixture(#{target => Target}),
    Terms = lists:append([quod_committed_projection:read_terms(
        filename:join([code:priv_dir(quod),"ontologies",F])) || F <-
            ["space.pl","quod_physics.pl","voxel_world.pl"] ++ ExtraSources]),
    Facts = [{can_create_voxel_world,land,Owner},{can_edit_voxel_world,land,Owner,{'_'}},
        {can_manage_voxel_world,land,Owner,{'_'}},
        {voxel_allowances,land,limits()},
        {voxel_initial_chunks,land,{'_'},[{chunk_v1,0,0,0}]},
        {physics_structure,land,1},{physics_next_body,land,0},
        {physics_checkpoint,land,preserved},
        {physics_allowances,land,{limits,8,8,128,1000000,{geometry,128,100000,100000}},16667,-9810,10000}],
    Committed = quod_ct:action_kb(<<>>,[quod_agent_predicates],Terms ++ Facts),
    _ = quod_proof_context:start(<<72:256>>,false,Target,quod_time:mono_ms()+60000,Principal,Evidence),
    try Fun({Committed,1,Ns,Anchor},Owner)
    after
        quod_proof_context:stop(fun(_) -> ok end,fun(_) -> ok end),
        quod_erlog_db_mvcc:delete(db_ref(Committed))
    end.

view({Est,H,Ns,Anchor}) ->
    St = quod_erlog_db_local_prove:wrap_state(Est,#{read_set => true}),
    quod_predicates:set_context(St,quod_predicates:proof_context(Ns,H,undefined,[{Ns,Anchor}])).
value(Var,Goal,Store) ->
    St = view(Store),
    try
        Final = prove(Goal,St),
        erlog_int:dderef(Var,Final#est.bs)
    after quod_erlog_db_local_prove:cleanup_read_set(St) end.
commit(Goal,{Committed,H,Ns,A}=Store) ->
    St = view(Store),
    try
        Final = prove(Goal,St),
        Ops = changes(Final),
        {ok,Applied} = quod_diff:apply_ops(Committed,Ops),
        {{quod_ct:commit_kb(Applied,H+1,H),H+1,Ns,A},Ops}
    after quod_erlog_db_local_prove:cleanup_read_set(St) end.
assert_refused(Goal,Store,Reason) ->
    St = view(Store),
    try
        {fail,Final} = erlog_int:prove_goal(Goal,St),
        ?assertEqual([],changes(Final)),
        case Reason =:= any orelse lists:any(fun(R) ->
            is_tuple(R) andalso element(1,R) =:= Reason end,Final#est.fail_reasons) of
            true -> ok;
            false -> error({missing_refusal_reason,Reason,lists:sublist(Final#est.fail_reasons,8)})
        end
    after quod_erlog_db_local_prove:cleanup_read_set(St) end.
changes(St) -> quod_erlog_db_local_prove:get_local_changes(db_ref(St)).
db_ref(#est{db = #db{ref = Ref}}) -> Ref.
prove(Goal,St) ->
    case erlog_int:prove_goal(Goal,St) of
        {succeed,Final} -> Final;
        {fail,Final} -> error({proof_refused,Goal,lists:sublist(Final#est.fail_reasons,8)})
    end.
