-module(quod_terrain_wire).
-moduledoc "Pure encoding of the resource owner's complete terrain selection.".
-export([message/1]).

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

chunk(I,Payload) -> #{index => I,payload => b64(Payload)}.
decimal(N) -> integer_to_binary(N).
b64(B) -> base64:encode(B,#{mode => urlsafe,padding => false}).
