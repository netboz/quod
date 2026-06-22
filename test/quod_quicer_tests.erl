-module(quod_quicer_tests).
-include_lib("eunit/include/eunit.hrl").

%% quod_quicer:frame/2 and unframe/1 are private, exported only under -ifdef(TEST).

frame_unframe_roundtrip_test() ->
    Cases =
        [{<<"blocks">>,  <<"hello">>},
         {<<>>,          <<"empty-channel-name">>},
         {<<"c">>,       <<>>},
         {<<"a/b/c">>,   <<0, 1, 2, 3, 255>>},
         {<<"big">>,     binary:copy(<<"z">>, 10000)}],
    [?assertEqual({Ch, Pl}, quod_quicer:unframe(quod_quicer:frame(Ch, Pl)))
     || {Ch, Pl} <- Cases].

frame_wire_layout_test() ->
    %% <<CLen:16, Channel/binary, Payload/binary>>
    ?assertEqual(<<3:16, "abc", "DATA">>,
                 quod_quicer:frame(<<"abc">>, <<"DATA">>)).

unframe_respects_channel_length_test() ->
    %% payload bytes that look like a length prefix must not confuse decoding
    Ch = <<"t">>,
    Pl = <<5:16, "xxxxx">>,
    ?assertEqual({Ch, Pl}, quod_quicer:unframe(quod_quicer:frame(Ch, Pl))).
