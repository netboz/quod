-module(quod_physics_coordinates_tests).
-include_lib("eunit/include/eunit.hrl").

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
