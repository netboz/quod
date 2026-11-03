-module(presentation_resource_checks).
-include_lib("eunit/include/eunit.hrl").

measured_terrain_retains_finite_authored_admission_test() ->
    {ok,Payload}=file:read_file("client/test/fixtures/voxel-plane.qvt"),
    A=#{payload=>Payload,triangles=>128,output_digest=>crypto:hash(sha256,Payload)},
    Spec=#{bodies=>[{4,2,fixed,unused,{terrain,500,unused},unused}]},
    Source=#{{4,{chunk_v1,0,0,0}}=>A},View={view_distance,4000,1000,2000},
    Unlimited=[unlimited,unlimited,unlimited,unlimited,unlimited],
    Exact=[4880,13824,384,128,1],
    {ok,[Row]}=quod_physics:terrain_snapshot([{4,2,View,Unlimited}],Spec,Source,#{}),
    ?assertEqual(Exact,maps:get(costs,Row)),
    ?assertEqual({ok,[Row]},quod_physics:terrain_snapshot([{4,2,View,Exact}],Spec,Source,#{})),
    ?assertMatch({error,<<"Terrain geometry bytes:",_/binary>>},
        quod_physics:terrain_snapshot([{4,2,View,[unlimited,13823,unlimited,unlimited,unlimited]}],Spec,Source,#{})),
    ?assertMatch({error,invalid_terrain_binding},
        quod_physics:terrain_snapshot([{4,2,View,[unlimited,-1,unlimited,unlimited,unlimited]}],Spec,Source,#{})).
