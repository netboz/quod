-module(quod_terrain_wire).
-moduledoc "Pure terrain message encoding and packing under the existing view-frame bound.".
-include("quod_client_goal_limits.hrl").
-export([message/1, admit/3, batch/2]).

message({terrain_manifest,Token,Interest,Rows}) ->
    #{type => terrain_manifest,token => b64(Token),interest_seq => decimal(Interest),chunks => [
        #{index => maps:get(index,R),body => decimal(maps:get(body,R)),
          revision => decimal(maps:get(revision,R)),
          chunk => [decimal(N) || N <- tuple_to_list(maps:get(chunk,R))],
          origin_mm => [decimal(N) || N <- tuple_to_list(maps:get(origin,R))],
          spacing_mm => maps:get(spacing,R),digest => binary:encode_hex(maps:get(digest,R),lowercase),
          costs => maps:get(costs,R)} || R <- Rows]};
message({terrain_chunks,Token,Chunks,Complete}) ->
    #{type => terrain_chunks,token => b64(Token),complete => Complete,
      chunks => [chunk(I,Payload) || {I,Payload} <- Chunks]}.

%% View and resource tokens are canonical URL-safe encodings of 256-bit hashes.
%% Measure the actual envelope; false is one byte longer than the final true.
envelope(Token) -> encoded_size(message({terrain_chunks,Token,[],false})).
encoded_size(Message) ->
    iolist_size(json:encode(Message#{view => b64(<<0:256>>)})).

admit(Token,Interest,Rows) ->
    try
        check_size("manifest",encoded_size(message({terrain_manifest,Token,Interest,Rows}))),
        Base = envelope(Token),
        lists:foreach(fun(#{index := I,payload := Payload}) ->
            check_size("chunk",Base + chunk_size({I,Payload}))
        end,Rows),
        ok
    catch throw:Reason -> {error,Reason} end.

%% The owner retains the snapshot and remaining indices. This pure prefix
%% selection adds no queue or allocation policy; admit/3 already checked rows.
batch(Token,Chunks) ->
    take(Chunks,?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES-envelope(Token),0,[]).
take([],_,_,Acc) -> {lists:reverse(Acc),[]};
take([Row|Rest] = Remaining,Available,Separator,Acc) ->
    Needed = chunk_size(Row) + Separator,
    case Needed =< Available of
        true -> take(Rest,Available-Needed,1,[Row|Acc]);
        false -> {lists:reverse(Acc),Remaining}
    end.

%% URL-safe base64 needs no JSON escaping and omits padding. All other entry
%% bytes come from the same serializer used for delivery, including the index.
chunk_size({I,Payload}) ->
    iolist_size(json:encode(chunk(I,<<>>))) + (4*byte_size(Payload)+2) div 3.
chunk(I,Payload) -> #{index => I,payload => b64(Payload)}.
check_size(Kind,Bytes) when Bytes > ?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES ->
    throw(iolist_to_binary(io_lib:format("Terrain ~s encoding: required ~B bytes, frame limit ~B.",
                                        [Kind,Bytes,?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES])));
check_size(_,_) -> ok.
decimal(N) -> integer_to_binary(N).
b64(B) -> base64:encode(B,#{mode => urlsafe,padding => false}).
