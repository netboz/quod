-module(quod_log_formatter_tests).
-include_lib("eunit/include/eunit.hrl").

unicode_format_message_is_encoded_as_utf8_test() ->
    Format =
        "quod[~s]: admitted to the committee — recovering at slot ~b "
        "(committee ~b)",
    Event =
        #{level => notice,
          msg => {Format, [<<"quod:root">>, 2, 2]},
          meta => #{time => 0}},
    Decoded = json:decode(iolist_to_binary(quod_log_formatter:format(Event, #{}))),
    ?assertEqual(
       unicode:characters_to_binary(
         "quod[quod:root]: admitted to the committee — recovering at slot 2 "
         "(committee 2)"),
       maps:get(<<"msg">>, Decoded)).
