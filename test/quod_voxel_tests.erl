-module(quod_voxel_tests).
-include_lib("eunit/include/eunit.hrl").

nearby_chunk_order_follows_travel_without_losing_large_coordinates_test() ->
    X = -(1 bsl 100), Width = 4000,
    Left = {chunk_v1,X-1,0,0}, Here = {chunk_v1,X,0,0}, Right = {chunk_v1,X+1,0,0},
    Above = {chunk_v1,X,1,0}, Far = {chunk_v1,X+2,0,0},
    Chunks = [Far,Above,Left,Right,Here], Centre = {X*Width+2000,2000,2000},
    ?assertEqual([Here,Right,Above,Left,Far],
        quod_voxel:prioritize_chunks(Chunks,500,{Centre,{1,0,0}})),
    ?assertEqual([Here,Left,Above,Right,Far],
        quod_voxel:prioritize_chunks(Chunks,500,{Centre,{-1,0,0}})),
    ?assertEqual(Chunks,quod_voxel:prioritize_chunks(Chunks,500,none)).

biomes_blend_terrain_keep_categorical_materials_and_charge_work_test() ->
    Band = {biome,0,1000,0,1,2,500},
    Spec = {field_v1,1,500,[{plane,0},{biome_relief,20000,10,5000,11,[Band]}],9},
    {ok,{samples_v1,_,Materials}} = sample(Spec,{0,0,0},{1,4,1}),
    ?assertEqual(<<2:16,1:16,1:16,1:16>>,Materials),
    Bands = [{biome,-32768,1000,200,1,2,1000},{biome,32768,2000,500,3,4,1000}],
    Mixed = setelement(5,Spec,9),
    Field = setelement(4,Mixed,[{plane,0},{biome_relief,1000,10,5000,11,Bands}]),
    {ok,{samples_v1,D,M}} = sample(Field,{-8,0,-8},{17,9,17}),
    ?assertEqual([1,2,3,4],lists:usort([Id || <<Id:16>> <= M])),
    {ok,{samples_v1,D2,M2}} = sample(Field,{-8,0,-8},{8,9,17}),
    lists:foreach(fun(Row) ->
        ?assertEqual(binary:part(D,Row*17,8),binary:part(D2,Row*8,8)),
        ?assertEqual(binary:part(M,Row*34,16),binary:part(M2,Row*16,16))
    end,lists:seq(0,9*17-1)),
    ?assertEqual({error,{voxel_allowance,operator_evaluations,4,3}},
        quod_voxel:sample(Field,{vector,0,0,0},{dimensions,1,1,1},{sampling_limits,1,3,16,3})),
    ?assertEqual({error,{voxel_allowance,hash_evaluations,16,15}},
        quod_voxel:sample(Field,{vector,0,0,0},{dimensions,1,1,1},{sampling_limits,1,4,15,3})),
    Bad = setelement(4,Field,[{plane,0},{biome_relief,1000,10,5000,11,lists:reverse(Bands)}]),
    ?assertEqual({error,invalid_voxel_field},sample(Bad,{0,0,0},{1,1,1})).

procedural_caves_preserve_the_roof_and_repeat_across_negative_chunks_test() ->
    Field = {field_v1,41,500,[{plane,5000},{caves,5000,8,12000,1500}],9},
    {ok,{samples_v1,Roof,_}} = sample(Field,{-12,9,-12},{25,1,25}),
    ?assertEqual([-127],lists:usort([D || <<D:8/signed>> <= Roof])),
    {ok,{samples_v1,Underground,_}} = sample(Field,{-12,0,-12},{25,5,25}),
    ?assert(lists:any(fun(D) -> D > 0 end,[D || <<D:8/signed>> <= Underground])),
    ?assert(lists:any(fun(D) -> D < 0 end,[D || <<D:8/signed>> <= Underground])),
    Limits = {prepare_limits,limits(1331),{surface_limits,512,10000,10000},69120,500000},
    {ok,{First,generated}} = quod_voxel:prepare(Field,{chunk_v1,-1,0,-1},[],Limits,none),
    ?assert(maps:get(triangles,First) > 0),
    ?assertEqual({ok,{First,retained}},quod_voxel:prepare(Field,{chunk_v1,-1,0,-1},[],Limits,First)).

plane_sampling_and_native_surface_share_integer_units_test() ->
    Spec = {field_v1,1,500,[{plane,250}],7},
    {ok,Samples = {samples_v1,D,M}} = sample(Spec,{0,0,0},{2,2,2}),
    ?assertEqual(<<193,193,65,65,193,193,65,65>>,D),
    ?assertEqual(binary:copy(<<7:16>>,8),M),
    {ok,{surface,Vertices,Triangles}} = quod_voxel:surface(
        Samples,{dimensions,2,2,2},500,{surface_limits,1,13,12}),
    ?assertEqual(4,length(Vertices)),
    ?assertEqual(2,length(Triangles)),
    %% The odd sample quantizer explicitly fixes the zero tie outside solid;
    %% its represented crossing, rather than an unquantized height, is used.
    ?assert(lists:all(fun({vector,_,Y,_}) -> Y =:= 246 end,Vertices)).

negative_coordinate_seams_and_request_order_test() ->
    Spec = {field_v1,42,500,[{plane,1200},{relief,2400,4000,3},
                           {volume,300,2000,8},{material_below,1000,60000}],12},
    {ok,{samples_v1,L,LM}} = sample(Spec,{-4,0,-2},{5,5,5}),
    {ok,R = {samples_v1,RD,RM}} = sample(Spec,{0,0,-2},{5,5,5}),
    ?assertEqual({ok,R},sample(Spec,{0,0,-2},{5,5,5})),
    lists:foreach(fun(I) ->
        ?assertEqual(binary:at(L,I*5+4),binary:at(RD,I*5)),
        ?assertEqual(binary:part(LM,(I*5+4)*2,2),binary:part(RM,I*10,2))
    end,lists:seq(0,24)).

coordinates_do_not_wrap_at_32_or_64_bits_test() ->
    Spec = {field_v1,42,500,[{plane,1000},{relief,2000,2000,3}],1},
    {ok,A} = sample(Spec,{0,0,0},{5,5,5}),
    {ok,B} = sample(Spec,{1 bsl 32,0,0},{5,5,5}),
    {ok,C} = sample(Spec,{1 bsl 64,0,0},{5,5,5}),
    ?assertNotEqual(A,B), ?assertNotEqual(B,C), ?assertNotEqual(A,C),
    ?assertEqual({ok,C},sample(Spec,{1 bsl 64,0,0},{5,5,5})).

tunnel_carving_changes_inside_and_keeps_surrounding_rock_test() ->
    Spec = {field_v1,1,500,[{plane,2000},
                           {carve_tunnel,{vector,0,0,0},{vector,4000,0,0},750}],9},
    {ok,{samples_v1,<<Inside:8/signed>>,<<9:16>>}} = sample(Spec,{3,0,0},{1,1,1}),
    {ok,{samples_v1,<<Rock:8/signed>>,<<9:16>>}} = sample(Spec,{3,3,0},{1,1,1}),
    ?assert(Inside > 0), ?assert(Rock < 0).

sampling_admission_is_explicit_and_precedes_allocation_test() ->
    Spec = {field_v1,1,500,[{plane,0},{relief,500,1000,1}],1},
    R = {vector,0,0,0}, D = {dimensions,5,5,5},
    ?assertEqual({error,{voxel_allowance,samples,125,124}},
        quod_voxel:sample(Spec,R,D,{sampling_limits,124,250,1000,375})),
    ?assertEqual({error,{voxel_allowance,operator_evaluations,250,249}},
        quod_voxel:sample(Spec,R,D,{sampling_limits,125,249,1000,375})),
    ?assertEqual({error,{voxel_allowance,hash_evaluations,1000,999}},
        quod_voxel:sample(Spec,R,D,{sampling_limits,125,250,999,375})),
    ?assertEqual({error,{voxel_allowance,sample_bytes,375,374}},
        quod_voxel:sample(Spec,R,D,{sampling_limits,125,250,1000,374})),
    ?assertEqual({error,invalid_voxel_field},sample(setelement(3,Spec,255),{0,0,0},{1,1,1})),
    ?assertEqual({error,invalid_voxel_field},sample(setelement(4,Spec,[{unknown,1}]),{0,0,0},{1,1,1})).

dig_across_negative_chunk_corner_is_current_state_and_idempotent_test() ->
    Spec = {field_v1,1,500,[{plane,100000}],9},
    Brush = {dig_sphere,{vector,0,0,0},600},
    {ok,Chunks} = quod_voxel:brush_chunks(Brush,500,{chunk_limits,8}),
    ?assertEqual(8,length(Chunks)),
    Patches = [begin
        {ok,{edit_v1,P,true,false,Consumers}} = edit(Spec,C,{patch_v1,<<>>},Brush),
        ?assert(lists:member(C,Consumers)),
        ?assertEqual({ok,{edit_v1,P,false,false,[]}},edit(Spec,C,P,Brush)),
        {override,C,P}
    end || C <- Chunks],
    {ok,{samples_v1,Left,LM}} = chunk(Spec,{chunk_v1,-1,0,0},Patches),
    {ok,{samples_v1,Right,RM}} = chunk(Spec,{chunk_v1,0,0,0},Patches),
    %% Three halo columns overlap, including the sole owner of x=0.
    lists:foreach(fun({Row,X}) ->
        ?assertEqual(binary:at(Left,Row*11+X+8),binary:at(Right,Row*11+X)),
        ?assertEqual(binary:part(LM,(Row*11+X+8)*2,2),binary:part(RM,(Row*11+X)*2,2))
    end,[{Row,X} || Row <- lists:seq(0,120),X <- [0,1,2]]),
    ?assertEqual(127,binary:at(Right,1+11+121)),
    ?assertEqual(129,binary:at(Right,9+11+121)),
    ?assertEqual({error,{voxel_allowance,edit_chunks,8,7}},
                 quod_voxel:brush_chunks(Brush,500,{chunk_limits,7})).

paint_uses_same_patch_and_restoring_base_removes_record_test() ->
    Spec = {field_v1,1,500,[{plane,100000}],9},
    C = {chunk_v1,0,0,0},
    {ok,{edit_v1,P,false,true,Consumers}} = edit(Spec,C,{patch_v1,<<>>},
        {paint_sphere,{vector,500,500,500},1,42}),
    %% A gradient at the preceding cell border also depends on sample 1.
    ?assert(lists:member({chunk_v1,-1,-1,-1},Consumers)),
    ?assertEqual({patch_v1,<<73:16,-127:8/signed,42:16>>},P),
    ?assertMatch({ok,{edit_v1,{patch_v1,<<>>},false,true,_}},
        edit(Spec,C,P,{paint_sphere,{vector,500,500,500},1,9})).

patch_format_and_budget_refuse_before_returning_partial_edits_test() ->
    Spec = {field_v1,1,500,[{plane,100000}],9},
    C = {chunk_v1,0,0,0}, Brush = {dig_sphere,{vector,0,0,0},600},
    lists:foreach(fun(B) ->
        ?assertEqual({error,invalid_voxel_patch},edit(Spec,C,{patch_v1,B},Brush))
    end,[<<0>>,<<512:16,1:8,9:16>>,<<0:16,0:8,9:16>>,
         <<1:16,1:8,9:16,0:16,1:8,9:16>>,<<0:16,1:8,9:16,0:16,1:8,9:16>>]),
    ?assertEqual({error,invalid_voxel_field},edit(Spec,C,{patch_v1,<<0:16,-127:8/signed,9:16>>},Brush)),
    ?assertMatch({error,{voxel_allowance,patch_bytes,_,0}},
        quod_voxel:edit(Spec,C,{patch_v1,<<>>},Brush,{edit_limits,limits(512),0})),
    ?assertEqual({error,invalid_voxel_field},chunk(Spec,C,[{override,C,{patch_v1,<<>>}},
                                                                   {override,C,{patch_v1,<<>>}}])).

retained_geometry_does_no_generation_but_obeys_current_output_allocation_test() ->
    Spec = {field_v1,1,500,[{plane,1000}],9}, C = {chunk_v1,0,0,0},
    Limits = {prepare_limits,limits(1331),{surface_limits,512,10000,10000},69120,500000},
    {ok,{First,generated}} = quod_voxel:prepare(Spec,C,[],Limits,none),
    NoWork = {prepare_limits,{sampling_limits,0,0,0,0},{surface_limits,0,10000,10000},0,500000},
    ?assertEqual({ok,{First,retained}},quod_voxel:prepare(Spec,C,[],NoWork,First)),
    %% The neighboring patch changes, but this site lies outside the consumer's
    %% halo. It must retain geometry even with zero sampling allowance.
    Neighbor = {chunk_v1,1,0,0},
    Unread = [{override,Neighbor,{patch_v1,<<7:16,127:8/signed,42:16>>}}],
    ?assertEqual({ok,{First,retained}},quod_voxel:prepare(Spec,C,Unread,setelement(4,NoWork,5),First)),
    Read = [{override,Neighbor,{patch_v1,<<0:16,127:8/signed,42:16>>}}],
    ?assertMatch({error,{voxel_allowance,samples,1331,0}},
        quod_voxel:prepare(Spec,C,Read,setelement(4,NoWork,5),First)),
    ?assertMatch({error,{voxel_allowance,geometry_vertices,_,0}},
        quod_voxel:prepare(Spec,C,[],setelement(3,NoWork,{surface_limits,0,0,10000}),First)),
    ?assertMatch({error,{voxel_allowance,geometry_bytes,_,0}},
        quod_voxel:prepare(Spec,C,[],setelement(5,NoWork,0),First)),
    Changed = setelement(4,Spec,[{plane,500}]),
    ?assertMatch({error,{voxel_allowance,samples,1331,0}},
        quod_voxel:prepare(Changed,C,[],NoWork,First)),
    {ok,{Second,generated}} = quod_voxel:prepare(Changed,C,[],Limits,First),
    ?assertNotEqual(maps:get(handle,First),maps:get(handle,Second)),
    ?assertNotEqual(maps:get(output_digest,First),maps:get(output_digest,Second)).

material_change_retains_surface_with_zero_triangulation_allowance_test() ->
    Field = {field_v1,1,500,[{plane,1000}],9}, C = {chunk_v1,0,0,0},
    Limits = {prepare_limits,{sampling_limits,1331,100000,100000,3993},
              {surface_limits,512,10000,10000},69120,500000},
    {ok,{First,generated}} = quod_voxel:prepare(Field,C,[],Limits,none),
    Painted = setelement(5,Field,10),
    ReuseOnly = setelement(3,Limits,{surface_limits,0,10000,10000}),
    {ok,{Second,generated}} = quod_voxel:prepare(Painted,C,[],ReuseOnly,First),
    ?assertNotEqual(maps:get(output_digest,First),maps:get(output_digest,Second)),
    ?assertEqual(maps:get(vertices,First),maps:get(vertices,Second)),
    ?assertMatch({error,{voxel_cell_allowance,512,0}},
        quod_voxel:prepare(Painted,C,[],ReuseOnly,none)),
    ?assertEqual({ok,{Second,retained}},quod_voxel:prepare(Painted,C,[],
        setelement(2,ReuseOnly,{sampling_limits,0,0,0,0}),Second)).

native_terrain_coverage_refusal_preserves_existing_body_state_test() ->
    {ok,{Air,Payload}} = quod_physics_native:voxel_prepare(binary:copy(<<127>>,1331),
        binary:copy(<<9:16>>,1331),500,{512,10000,10000,500000},[]),
    ?assertMatch(<<"QVT1",500:32,0:32,0:32>>,Payload),
    {ok,World} = quod_physics_native:new_world({8,8,128,1000.0,512,100000,100000},1/60,-9.81),
    Body = {1,1,dynamic,{{2.0,2.0,2.0},{0.0,0.0,0.0}},{solid,{ball,0.25}},1.0},
    Terrain = fun(Chunks) -> {0,1,fixed,{{0.0,0.0,0.0},{0.0,0.0,0.0}},
                              {terrain,500,Chunks},1.0} end,
    try
        {ok,2} = quod_physics_native:install(World,{0,0,0},[Terrain([{{0,0,0},Air}]),Body]),
        {ok,Before} = quod_physics_native:sample(World),
        ?assertMatch({ok,{unavailable,{terrain_coverage,[_|_]}}},quod_physics_native:step(World,false)),
        ?assertEqual({ok,Before},quod_physics_native:sample(World)),
        Chunks = [{{X*4000,Y*4000,Z*4000},Air} || X <- lists:seq(-2,2),
                    Y <- lists:seq(-2,2),Z <- lists:seq(-2,2)],
        {ok,1} = quod_physics_native:install(World,{0,0,0},[Terrain(Chunks),Body]),
        {ok,{_,Poses,_}} = quod_physics_native:step(World,false),
        {1,{_,Y,_},_,_} = lists:keyfind(1,1,Poses), ?assert(Y < 2.0),
        ?assertEqual({ok,0},quod_physics_native:install(World,{0,0,0},[Terrain(Chunks),Body]))
    after quod_physics_native:retire(World) end.

resident_union_is_bounded_before_box_enumeration_test() ->
    A = {chunk_box,{chunk_v1,-1,0,0},{chunk_v1,1,0,0}},
    B = {chunk_box,{chunk_v1,0,0,0},{chunk_v1,2,0,0}},
    ?assertEqual({ok,[{chunk_v1,X,0,0} || X <- lists:seq(-1,2)]},
        quod_voxel:resident_chunks([{chunk_v1,0,0,0}],[A,B],{chunk_limits,4})),
    ?assertEqual(quod_voxel:resident_chunks([], [A,B], {chunk_limits,4}),
        quod_voxel:resident_chunks([], [A,B], {chunk_limits,unlimited})),
    ?assertEqual({error,{voxel_allowance,resident_chunks,4,3}},
        quod_voxel:resident_chunks([],[A,B],{chunk_limits,3})),
    Huge = 1 bsl 100,
    ?assertEqual({error,{voxel_allowance,resident_chunks,Huge+1,4}},
        quod_voxel:resident_chunks([],[{chunk_box,{chunk_v1,0,0,0},{chunk_v1,Huge,0,0}}],{chunk_limits,4})).

edit(Spec,C,P,B) -> quod_voxel:edit(Spec,C,P,B,{edit_limits,limits(512),2560}).
chunk(Spec,C,Rows) -> quod_voxel:chunk(Spec,C,Rows,{chunk_limits,limits(1331),27*2560}).
limits(N) -> {sampling_limits,N,N*8,N*64,N*3}.

sample(Spec,{X,Y,Z},{Nx,Ny,Nz}) ->
    N = Nx*Ny*Nz,
    quod_voxel:sample(Spec,{vector,X,Y,Z},{dimensions,Nx,Ny,Nz},
                      {sampling_limits,N,N*8,N*64,N*3}).
