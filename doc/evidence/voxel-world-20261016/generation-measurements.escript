#!/usr/bin/env escript
-mode(compile).
main([Output]) ->
    code:add_paths(filelib:wildcard("_build/test/lib/*/ebin")),
    {ok,_} = application:ensure_all_started(crypto),
    Bands = [{biome,-40000,2000,1000,3,4,1500},{biome,0,6000,2500,1,2,1500},
             {biome,40000,11000,6500,1,6,1000}],
    Cases = [{flat,[{plane,1000}]},
        {rough,[{plane,2000},{relief,4000,2000,11}]},
        {thin_tunnel,[{plane,2000},{carve_tunnel,{vector,-16000,0,0},{vector,16000,0,0},750}]},
        {materials,[{plane,1000},{material_below,750,2},{material_below,0,3}]},
        {biomes_and_caves,[{plane,0},{biome_relief,128000,10,16000,11,Bands},{caves,16000,12,9830,2000}]}],
    Chunks = [{chunk_v1,X,Y,Z} || X <- lists:seq(-1,2),Y <- lists:seq(-1,2),Z <- lists:seq(-1,2)],
    Sampling = {sampling_limits,1331,20000,200000,3993},
    Limits = {prepare_limits,Sampling,{surface_limits,512,10000,10000},200000,500000},
    Rows = [measure(Name,{field_v1,1947,500,Ops,1},Chunks,Sampling,Limits) || {Name,Ops} <- Cases],
    ok = file:write_file(Output,json:encode(#{spacing_mm => 500,chunks_per_case => length(Chunks),
        halo_samples_per_chunk => 1331,cases => Rows,
        method => <<"One sequential local run; wall-clock microseconds, no network or consensus. Sampling includes halo patch merge. Native preparation includes triangulation, packing and collider preparation. Retained checks use the same production prepare function. RSS is captured separately for the complete VM process.">>})),
    io:format("~p~n",[Rows]).

measure(Name,Field,Chunks,Sampling,Limits) ->
    Results = [begin
        {SampleUs,{ok,{samples_v1,D,M}}} = timer:tc(fun() ->
            quod_voxel:chunk(Field,C,[],{chunk_limits,Sampling,200000}) end),
        {NativeUs,Native} = timer:tc(fun() ->
            quod_physics_native:voxel_prepare(D,M,500,{512,10000,10000,500000},[]) end),
        case Native of
            {ok,{_Handle,Payload}} ->
                <<"QVT1",_:32,T:32,V:32,_/binary>> = Payload,
                {ok,{Artifact,generated}} = quod_voxel:prepare(Field,C,[],Limits,none),
                {RetainUs,{ok,{Artifact,retained}}} = timer:tc(fun() ->
                    quod_voxel:prepare(Field,C,[],Limits,Artifact) end),
                #{sample_us => SampleUs,native_us => NativeUs,retained_us => RetainUs,
                  bytes => byte_size(Payload),triangles => T,vertices => V};
            {error,Reason} -> #{sample_us => SampleUs,native_us => NativeUs,
                               refused => iolist_to_binary(io_lib:format("~p",[Reason]))}
        end
    end || C <- Chunks],
    #{name => Name,totals => maps:from_list([{K,lists:sum([maps:get(K,R,0) || R <- Results])}
        || K <- [sample_us,native_us,retained_us,bytes,triangles,vertices]]),
      maximum_chunk_bytes => lists:max([maps:get(bytes,R,0) || R <- Results]),
      failures => [R || R = #{refused := _} <- Results]}.
