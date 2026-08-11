-module(quod_link_tests).
-include_lib("eunit/include/eunit.hrl").

%% header/3, parse_header/1, frame/1 and parse/1 are exported only under -ifdef(TEST).
-import(quod_link, [header/3, parse_header/1, frame/1, parse/1]).

peer_key_normalizes_transport_identity_test() ->
    Peer = <<7:256>>,
    ?assertEqual(Peer, quod_link:peer_key(Peer)),
    ?assertEqual(Peer, quod_link:peer_key({Peer, {"127.0.0.1", 14567}})),
    ?assertEqual(undefined, quod_link:peer_key(<<"short">>)),
    ?assertEqual(undefined, quod_link:peer_key({<<"short">>, ignored})),
    ?assertEqual(undefined, quod_link:peer_key(malformed)).

%% --- header: <<NLen:16, NodeId, CLen:16, Channel, LearnPolicy:8>> -------

header_roundtrip_test() ->
    Addr = {"127.0.0.1", 14567},
    Cases = [{{<<0:256>>, Addr}, <<"chan">>, learn},
             {{<<1:256>>, Addr}, <<"a/b">>, no_learn}],
    [?assertEqual({ok, NodeId, Ch, Policy, <<>>},
                  parse_header(header(NodeId, Ch, Policy)))
     || {NodeId, Ch, Policy} <- Cases].

%% the header consumes exactly its bytes; trailing payload frames are the Rest.
header_keeps_remainder_test() ->
    Tail = frame(<<"payload">>),
    Id = {<<0:256>>, {"h", 1}},
    Buf  = <<(header(Id, <<"c">>, no_learn))/binary, Tail/binary>>,
    ?assertEqual({ok, Id, <<"c">>, no_learn, Tail}, parse_header(Buf)).

%% a header that arrives in pieces -> `more` until complete, then decoded.
header_split_buffers_test() ->
    Id = {<<0:256>>, {"h", 1}},
    Full = header(Id, <<"chan">>, learn),
    Half = byte_size(Full) div 2,
    <<A:Half/binary, _/binary>> = Full,
    ?assertEqual(more, parse_header(A)),
    ?assertEqual({ok, Id, <<"chan">>, learn, <<>>}, parse_header(Full)).

%% a structurally complete header whose node id isn't a decodable term -> error
%% (defensive decode), not a crash.
header_bad_nodeid_rejected_test() ->
    ?assertEqual(error, parse_header(<<3:16, "abc", 0:16, 1:8>>)),
    [?assertEqual(error, parse_header(header(Bad, <<"c">>, learn)))
     || Bad <- [node_atom, 42, {a, b, c}, {{"h", 1}, {"h", 1}},
                {<<"short">>, {"h", 1}},
                {<<0:256>>, malformed_endpoint},
                {<<0:256>>, {<<>>, 1}},
                {<<0:256>>, {[], 1}},
                {<<0:256>>, {binary:copy(<<"h">>, 256), 1}},
                {<<0:256>>, {lists:duplicate(256, $h), 1}},
                {<<0:256>>, {{127, 0, 0, 999}, 1}},
                {<<0:256>>, {{arbitrary, tuple}, 1}},
                {<<0:256>>, {[0], 1}}]].

header_bad_learn_policy_rejected_test() ->
    Id = {<<0:256>>, {"h", 1}},
    Valid = header(Id, <<"c">>, learn),
    PrefixLen = byte_size(Valid) - 1,
    <<Prefix:PrefixLen/binary, _Policy:8>> = Valid,
    ?assertEqual(error, parse_header(<<Prefix/binary, 2:8>>)).

compressed_header_identity_rejected_before_expansion_test() ->
    Id = {<<0:256>>, {binary:copy(<<"h">>, 200), 1}},
    Compressed = term_to_binary(Id, [{compressed, 9}]),
    ?assertMatch(<<131, 80, _/binary>>, Compressed),
    Header = <<(byte_size(Compressed)):16, Compressed/binary,
               1:16, "c", 1:8>>,
    ?assertEqual(error, parse_header(Header)).

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
