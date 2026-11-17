-module(quod_terrain_wire_tests).
-include_lib("eunit/include/eunit.hrl").

complete_content_and_manifest_keep_every_requested_row_test() ->
    Token = <<42:256>>,
    Chunks = [{I,binary:copy(<<I>>,N)} || {I,N} <- [{0,233488},{1,100000},{2,233488},{3,100000}]],
    Content = quod_terrain_wire:message({terrain_chunks,Token,Chunks,true}),
    ?assert(frame_size({terrain_chunks,Token,Chunks,true}) > 512*1024),
    ?assertEqual(Chunks,[{maps:get(index,R),base64:decode(maps:get(payload,R),
        #{mode => urlsafe,padding => false})} || R <- maps:get(chunks,Content)]),
    Rows = [row(I,<<>>) || I <- lists:seq(0,3999)],
    ?assert(frame_size({terrain_manifest,Token,1,Rows}) > 512*1024),
    ?assertEqual(4000,length(maps:get(chunks,quod_terrain_wire:message({terrain_manifest,Token,1,Rows})))),
    ?assertMatch(#{chunks := [],complete := true},quod_terrain_wire:message({terrain_chunks,Token,[],true})).

frame_size(Resource) ->
    Message = quod_terrain_wire:message(Resource),
    iolist_size(json:encode(Message#{view => base64:encode(<<7:256>>,#{mode => urlsafe,padding => false})})).
row(I,Payload) ->
    #{index => I,body => 1,revision => 1,chunk => {I,0,0},origin => {I*4000,0,0},
      spacing => 500,digest => crypto:hash(sha256,Payload),costs => [byte_size(Payload),0,0,0,1],payload => Payload}.
