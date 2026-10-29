-module(quod_physics_coordinates_tests).
-include_lib("eunit/include/eunit.hrl").

composed_frames_match_independent_matrix_reference_test() ->
    Frames=[{transform,1300,-700,2900,17,43,89},{transform,-1900,1100,2300,31,67,113}],
    Local={pose,{vector,300,500,-900},{rotation,230,470,710}},
    {world_mm,Position,Angles}=quod_physics_frames:pose(Frames,Local),
    {ok,Metres}=quod_physics_coordinates:local(Position,{0,0,0},100000),
    near({1.4169198585141537,-1.3171043603401615,6.026684858429907},Metres),
    Q=quod_physics_frames:rotation(Angles),
    near({-0.09674393196105624,-0.9950443637077163,0.022963577295810056},
         quod_physics_frames:rotate(Q,{1,0,0})),
    near({0.15009013411519545,0.00822310889795426,0.9886381199009752},
         quod_physics_frames:rotate(Q,{0,1,0})),
    near({-0.9839276209508488,0.09909134540189937,0.1485508061117285},
         quod_physics_frames:rotate(Q,{0,0,1})),
    Huge=1 bsl 100,
    Shifted=[{transform,Huge+1300,-700,2900,17,43,89}|tl(Frames)],
    {world_mm,Large,_}=quod_physics_frames:pose(Shifted,Local),
    ?assertEqual({ok,Metres},quod_physics_coordinates:local(Large,{Huge,0,0},100000)),
    [begin
        {world_mm,_,Gimbal}=quod_physics_frames:pose([{transform,0,0,0,37,Pitch,113}],{vector,0,0,0}),
        Expected=quod_physics_frames:rotation({37*math:pi()/180,Pitch*math:pi()/180,113*math:pi()/180}),
        Actual=quod_physics_frames:rotation(Gimbal),
        [near(quod_physics_frames:rotate(Expected,Basis),quod_physics_frames:rotate(Actual,Basis))
         || Basis<-[{1,0,0},{0,1,0},{0,0,1}]]
    end || Pitch<-[90,270]].

near(A,B) ->
    ?assert(lists:all(fun({X,Y})->abs(X-Y)<1.0e-10 end,lists:zip(tuple_to_list(A),tuple_to_list(B)))).

large_signed_origins_preserve_exact_world_positions_test() ->
    lists:foreach(fun(Sign) ->
        Huge = Sign*((1 bsl 100)+12345),
        Point = {Huge,Huge+4000,Huge-7000},
        {ok,Origin} = quod_physics_coordinates:origin([Point],[4000,6000],{0,0,0},100000),
        ?assert(lists:all(fun(N) -> N rem 12000 =:= 0 end,tuple_to_list(Origin))),
        {ok,Local} = quod_physics_coordinates:local(Point,Origin,100000),
        ?assertEqual(Point,quod_physics_coordinates:canonical(Local,Origin)),
        ?assertEqual({ok,Origin},quod_physics_coordinates:origin([Point],[4000,6000],Origin,100000))
    end,[-1,1]),
    ?assertEqual({error,coordinate_allowance},
        quod_physics_coordinates:origin([{0,0,0},{300001,0,0}],[4000],{0,0,0},100000)),
    ?assertEqual({error,coordinate_allowance},
        quod_physics_coordinates:local({1 bsl 100,0,0},{0,0,0},100000)).

native_shift_refusal_preserves_live_resource_test() ->
    {ok,W} = quod_physics_native:new_world({2,2,8,100.0,8,100,100},1/60,0.0),
    Bodies = [{1,1,fixed,{{4.0,0.0,0.0},{0.0,0.0,0.0}},{solid,{ball,0.5}},1.0}],
    {ok,1} = quod_physics_native:install(W,{0,0,0},Bodies),
    {ok,_} = quod_physics_native:step(W,false),
    {ok,Before} = quod_physics_native:sample(W),
    ?assertEqual({ok,{unavailable,coordinate_allowance}},quod_physics_native:install(W,{200000,0,0},Bodies)),
    ?assertEqual({ok,Before},quod_physics_native:sample(W)),
    ?assertEqual({ok,1},quod_physics_native:install(W,{4000,0,0},Bodies)),
    ?assertMatch({ok,{_,[{1,{0.0,0.0,0.0},_,_}],_}},quod_physics_native:sample(W)),
    ok = quod_physics_native:retire(W).
