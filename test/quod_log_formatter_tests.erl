-module(quod_log_formatter_tests).
-include_lib("eunit/include/eunit.hrl").

unicode_format_message_survives_ascii_json_boundary_test() ->
    Format =
        "quod[~s]: admitted to the committee — recovering at slot ~b "
        "(committee ~b)",
    Event =
        #{level => notice,
          msg => {Format, [<<"quod:root">>, 2, 2]},
          meta => #{time => 0}},
    Encoded = iolist_to_binary(quod_log_formatter:format(Event, #{})),
    ?assertNotEqual(nomatch, binary:match(Encoded, <<"\\u2014">>)),
    ?assertEqual(nomatch, binary:match(Encoded, <<16#E2, 16#80, 16#94>>)),
    Decoded = json:decode(Encoded),
    ?assertEqual(
       unicode:characters_to_binary(
         "quod[quod:root]: admitted to the committee — recovering at slot 2 "
         "(committee 2)"),
       maps:get(<<"msg">>, Decoded)).
