-module(quod_terrain_wire_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_client_goal_limits.hrl").

content_batches_fit_the_actual_json_frame_test() ->
    Token = <<42:256>>,
    Chunks = [{I,binary:copy(<<I>>,N)} || {I,N} <- [{0,233488},{1,100000},{2,233488},{3,100000}]],
    ?assertEqual(ok,quod_terrain_wire:admit(Token,1,[row(I,B) || {I,B} <- Chunks])),
    ?assert(frame_size({terrain_chunks,Token,Chunks,true}) > ?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES),
    ?assertEqual(2,check_batches(Token,Chunks,0)),
    ?assertEqual({[],[]},quod_terrain_wire:batch(Token,[])).

individual_content_and_manifest_bounds_test() ->
    Token = <<42:256>>,Payload = binary:copy(<<255>>,400000),
    ?assertMatch({error,<<"Terrain chunk encoding:",_/binary>>},quod_terrain_wire:admit(Token,1,[row(0,Payload)])),
    Rows = [row(I,<<>>) || I <- lists:seq(0,3999)],
    ?assert(frame_size({terrain_manifest,Token,1,Rows}) > ?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES),
    ?assertMatch({error,<<"Terrain manifest encoding:",_/binary>>},quod_terrain_wire:admit(Token,1,Rows)).

check_batches(_,[],Count) -> Count;
check_batches(Token,Chunks,Count) ->
    {Batch,Rest} = quod_terrain_wire:batch(Token,Chunks),
    ?assertNotEqual([],Batch),?assertEqual(Chunks,Batch++Rest),
    ?assert(frame_size({terrain_chunks,Token,Batch,Rest =:= []}) =< ?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES),
    case Rest of
        [Next|_] -> ?assert(frame_size({terrain_chunks,Token,Batch++[Next],false}) > ?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES);
        [] -> ok
    end,
    check_batches(Token,Rest,Count+1).

frame_size(Resource) ->
    Message = quod_terrain_wire:message(Resource),
    iolist_size(json:encode(Message#{view => base64:encode(<<7:256>>,#{mode => urlsafe,padding => false})})).
row(I,Payload) ->
    #{index => I,body => 1,revision => 1,chunk => {I,0,0},origin => {I*4000,0,0},
      spacing => 500,digest => crypto:hash(sha256,Payload),costs => [byte_size(Payload),0,0,0,1],payload => Payload}.
