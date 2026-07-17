-module(quod_link_tests).
-include_lib("eunit/include/eunit.hrl").

%% header/2, parse_header/1, frame/1 and parse/1 are exported only under -ifdef(TEST).
-import(quod_link, [header/2, parse_header/1, frame/1, parse/1]).

%% --- header: <<NLen:16, NodeId, CLen:16, Channel>> ----------------------

header_roundtrip_test() ->
    Addr = {"127.0.0.1", 14567},
    Cases = [{{<<0:256>>, Addr}, <<"chan">>},
             {{<<1:256>>, Addr}, <<"a/b">>}],
    [?assertEqual({ok, NodeId, Ch, <<>>}, parse_header(header(NodeId, Ch)))
     || {NodeId, Ch} <- Cases].

%% the header consumes exactly its bytes; trailing payload frames are the Rest.
header_keeps_remainder_test() ->
    Tail = frame(<<"payload">>),
    Id = {<<0:256>>, {"h", 1}},
    Buf  = <<(header(Id, <<"c">>))/binary, Tail/binary>>,
    ?assertEqual({ok, Id, <<"c">>, Tail}, parse_header(Buf)).

%% a header that arrives in pieces -> `more` until complete, then decoded.
header_split_buffers_test() ->
    Id = {<<0:256>>, {"h", 1}},
    Full = header(Id, <<"chan">>),
    Half = byte_size(Full) div 2,
    <<A:Half/binary, _/binary>> = Full,
    ?assertEqual(more, parse_header(A)),
    ?assertEqual({ok, Id, <<"chan">>, <<>>}, parse_header(Full)).

%% a structurally complete header whose node id isn't a decodable term -> error
%% (defensive decode), not a crash.
header_bad_nodeid_rejected_test() ->
    ?assertEqual(error, parse_header(<<3:16, "abc", 0:16>>)),
    [?assertEqual(error, parse_header(header(Bad, <<"c">>)))
     || Bad <- [node_atom, 42, {a, b, c}, {{"h", 1}, {"h", 1}},
                {<<"short">>, {"h", 1}},
                {<<0:256>>, malformed_endpoint}]].

%% --- payload frames: <<PLen:32, Payload>> -------------------------------

frame_layout_test() ->
    ?assertEqual(<<4:32, "DATA">>, frame(<<"DATA">>)).

frame_roundtrip_test() ->
    Cases = [<<"hello">>, <<>>, <<0, 1, 255>>],
    [?assertEqual({[Pl], <<>>}, parse(frame(Pl))) || Pl <- Cases].

%% QUIC is a byte stream: two frames can coalesce into one buffer -> both parsed.
coalesced_frames_test() ->
    Buf = <<(frame(<<"p1">>))/binary, (frame(<<"p2">>))/binary>>,
    ?assertEqual({[<<"p1">>, <<"p2">>], <<>>}, parse(Buf)).

%% ...or a frame splits across reads -> incomplete kept buffered, then completed.
split_frame_reassembles_test() ->
    Full = frame(<<"payload">>),
    Half = byte_size(Full) div 2,
    <<A:Half/binary, B/binary>> = Full,
    {[], Buf} = parse(A),
    ?assertEqual(A, Buf),
    ?assertEqual({[<<"payload">>], <<>>}, parse(<<Buf/binary, B/binary>>)).

partial_header_buffers_test() ->
    %% fewer than 4 length bytes -> buffered, no crash
    ?assertEqual({[], <<1, 2, 3>>}, parse(<<1, 2, 3>>)).

whole_then_partial_test() ->
    Tail = <<99:32, "x">>,              %% length claims 99 bytes; only 1 present
    Buf  = <<(frame(<<"p">>))/binary, Tail/binary>>,
    {Frames, Rest} = parse(Buf),
    ?assertEqual([<<"p">>], Frames),
    ?assertEqual(Tail, Rest).

oversized_frame_rejected_test() ->
    Huge = <<(1 bsl 21):32, 0:16>>,     %% declares ~2 MiB payload
    ?assertEqual({error, oversized}, parse(Huge)).
