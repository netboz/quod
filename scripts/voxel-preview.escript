#!/usr/bin/env escript
%% Reproducible offline inspection fixture from the production numerical kernel.
%% Run after `rebar3 as test compile`; this creates no ontology or live world.
main([Output]) ->
    code:add_paths(filelib:wildcard("_build/test/lib/*/ebin")),
    {ok,_} = application:ensure_all_started(crypto),
    Field = {field_v1,1947,1000,[{plane,7000},
        {relief,6500,20000,1},{relief,1200,6000,2},
        {carve_sphere,{vector,0,3000,0},6000},
        {carve_tunnel,{vector,-32000,3000,0},{vector,32000,3000,0},3000},
        {material_below,6000,2},{material_below,3000,3},{material_below,0,4},
        {clip_box,{vector,-24000,-4000,-16000},{vector,24000,22000,16000}}],1},
    Brush = {dig_sphere,{vector,11000,7000,-7000},4500},
    Sampling = {sampling_limits,1331,20000,200000,3993},
    Limits = {prepare_limits,Sampling,{surface_limits,512,10000,10000},200000,500000},
    {ok,Owners} = quod_voxel:brush_chunks(Brush,1000,{chunk_limits,64}),
    Overrides = [begin
        {ok,{edit_v1,Patch,_,_,_}} = quod_voxel:edit(Field,C,{patch_v1,<<>>},Brush,
                                                  {edit_limits,Sampling,200000}),
        {override,C,Patch}
    end || C <- Owners],
    Chunks = [{chunk_v1,X,Y,Z} || X <- lists:seq(-4,3),Y <- lists:seq(-1,2),Z <- lists:seq(-3,2)],
    {Before,After,Changed} = lists:foldl(fun(C = {chunk_v1,X,Y,Z},{B,A,N}) ->
        {ok,{Base,_}} = quod_voxel:prepare(Field,C,[],Limits,none),
        Nearby = [O || O = {override,{chunk_v1,I,J,K},_} <- Overrides,
                       abs(I-X) =< 1,abs(J-Y) =< 1,abs(K-Z) =< 1],
        {ok,{Edited,_}} = quod_voxel:prepare(Field,C,Nearby,Limits,Base),
        Count = case maps:get(output_digest,Base) =/= maps:get(output_digest,Edited) of true -> 1; false -> 0 end,
        {[row(C,Base)|B],[row(C,Edited)|A],N+Count}
    end,{[],[],0},Chunks),
    Result = #{title => <<"Emerald hollow">>,spacing_mm => 1000,changed_chunks => Changed,
        palette => [[1,<<"#668B45">>],[2,<<"#AC956A">>],[3,<<"#727F83">>],[4,<<"#46505C">>]],
        before => lists:reverse(Before),'after' => lists:reverse(After)},
    ok = filelib:ensure_dir(Output),
    ok = file:write_file(Output,json:encode(Result)),
    ok = file:write_file(Output++".term",io_lib:format("~p.~n",[#{field => Field,brush => Brush,limits => Limits}])),
    io:format("~p chunks, ~p changed; ~p triangles before, ~p after~n",[length(Chunks),Changed,
        lists:sum([maps:get(triangles,R) || R <- Before]),lists:sum([maps:get(triangles,R) || R <- After])]);
main(_) -> erlang:error("usage: scripts/voxel-preview.escript output.json").

row({chunk_v1,X,Y,Z},A) ->
    #{chunk => [integer_to_binary(I) || I <- [X,Y,Z]],
      origin_mm => [integer_to_binary(I*8000) || I <- [X,Y,Z]],
      digest => binary:encode_hex(maps:get(output_digest,A),lowercase),
      triangles => maps:get(triangles,A),
      payload => base64:encode(maps:get(payload,A))}.
