-module(quod_log_formatter_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

rendering_failures_keep_only_the_redacted_message_test_() ->
    Secret = <<"synthetic-format-failure-secret">>,
    Key = #'ECPrivateKey'{version = 1, privateKey = Secret},
    [{atom_to_list(Case), fun() ->
        assert_safe_fallback(iolist_to_binary(quod_log_formatter:format(Event, #{})), Secret)
    end} || {Case, Event} <- [
        {format_arguments, #{level => error, msg => {"~p ~p", [Key]}, meta => #{time => 0}}},
        {invalid_unicode, #{level => error, msg => {string, [16#d800, Key]}, meta => #{time => 0}}},
        {invalid_timestamp, #{level => error, msg => {report, #{key => Key}},
                              meta => #{time => invalid, private_key => Secret}}},
        {metadata_encoding, #{level => error, msg => {report, #{key => Key}},
                               meta => #{time => 0, #{nested => key} => Key}}}
    ]].

otp_handler_render_failure_cannot_recover_the_raw_message_test() ->
    %% Drive the real standard handler directly: its production formatter
    %% fallback uses the original event if ours raises. No global handlers or
    %% logger levels are changed, and the key below is only a sentinel.
    Secret = <<"synthetic-otp-fallback-secret">>,
    Key = #'ECPrivateKey'{version = 1, privateKey = Secret},
    File = filename:join("/tmp", "quod-formatter-" ++
                         integer_to_list(erlang:unique_integer([positive])) ++ ".log"),
    Name = quod_formatter_fallback_test,
    {ok, Config} = logger_std_h:adding_handler(
      #{id => Name, module => logger_std_h, formatter => {quod_log_formatter, #{}},
        config => #{type => file, file => File, filesync_repeat_interval => no_repeat}}),
    try
        ok = logger_std_h:log(
          #{level => error, msg => {"~p ~p", [Key]}, meta => #{time => 0}}, Config),
        %% Same sender -> handler -> file controller, not a send-trace guess.
        ok = logger_std_h:filesync(Name),
        {ok, Bytes} = file:read_file(File),
        assert_safe_fallback(Bytes, Secret)
    after
        ok = logger_std_h:removing_handler(Config),
        ok = file:delete(File)
    end.

assert_safe_fallback(Bytes, Secret) ->
    ?assertEqual(nomatch, binary:match(Bytes, Secret)),
    ?assertEqual(nomatch, binary:match(Bytes, <<"ECPrivateKey">>)),
    Decoded = json:decode(Bytes),
    ?assertEqual(true, maps:get(<<"format_error">>, Decoded)),
    ?assertEqual(<<"error">>, maps:get(<<"level">>, Decoded)),
    ?assertNotEqual(nomatch, binary:match(maps:get(<<"msg">>, Decoded),
                                         <<"redacted_private_key">>)),
    ?assertEqual([<<"format_error">>, <<"level">>, <<"msg">>, <<"ts">>],
                 lists:sort(maps:keys(Decoded))).

binary_report_and_metadata_keep_original_message_test() ->
    lists:foreach(fun(Byte) ->
        Report = #{label => original_report, data => <<Byte>>},
        Decoded = json:decode(iolist_to_binary(quod_log_formatter:format(
          #{level => warning, msg => {report, Report},
            meta => #{time => 0, data => <<Byte>>}}, #{}))),
        Message = maps:get(<<"msg">>, Decoded),
        ?assertNotEqual(nomatch, binary:match(Message, <<"original_report">>)),
        ?assertEqual(nomatch, binary:match(Message, <<"log encode failure">>)),
        ?assertEqual(<<"warning">>, maps:get(<<"level">>, Decoded)),
        ?assert(is_binary(maps:get(<<"data">>, Decoded)))
    end, [128, 192, 226, 255]).

unicode_truncation_preserves_prefix_and_exact_omitted_count_test() ->
    lists:foreach(fun({Point, Split}) ->
        Prefix = binary:copy(<<$a>>, 4096 - Split),
        Codepoint = unicode:characters_to_binary([Point]),
        Input = <<Prefix/binary, Codepoint/binary, "tail">>,
        Decoded = json:decode(iolist_to_binary(quod_log_formatter:format(
          #{level => info, msg => {string, Input}, meta => #{time => 0}}, #{}))),
        Expected = <<Prefix/binary, "...[+",
                     (integer_to_binary(byte_size(Codepoint) + 4))/binary, " bytes]">>,
        ?assertEqual(Expected, maps:get(<<"msg">>, Decoded))
    end, [{16#e9, 1}, {16#20ac, 1}, {16#20ac, 2},
          {16#1f600, 1}, {16#1f600, 2}, {16#1f600, 3}]).

unicode_report_redaction_precedes_rendering_test() ->
    Secret = <<"not-for-the-log">>,
    Decoded = json:decode(iolist_to_binary(quod_log_formatter:format(
      #{level => error, msg => {report, #{data => <<192>>, private_key => Secret}},
        meta => #{time => 0}}, #{}))),
    Message = maps:get(<<"msg">>, Decoded),
    ?assertEqual(nomatch, binary:match(Message, Secret)),
    ?assertNotEqual(nomatch, binary:match(Message, <<"redacted_private_key">>)),
    ?assertEqual(nomatch, binary:match(Message, <<"log encode failure">>)).

private_keys_removed_from_every_structured_report_surface_test() ->
    Seed = <<"secret-test-seed-01234567890123456">>,
    Key = #'ECPrivateKey'{version = 1, privateKey = Seed},
    Reports = [
      #{label => {gen_server, terminate}, reason => outcome_index_conflict,
        state => {state, #{signer => #{key => Key}}}},
      #{label => {supervisor, child_terminated},
        report => [{reason, outcome_index_conflict},
          {offender, [{mfargs, {quod_prolog, start_link, [<<"test">>, #{identity => Key}]}}]}]},
      #{label => {proc_lib, crash}, dictionary => [{raw_secret, Key}],
        messages => [{tls_options, [{key, {'ECPrivateKey', Seed}}]}]},
      #{nested => {[Key | Key], #{Key => #{<<"private_key">> => Seed}}},
        not_a_stack_frame => {module, function, [Key | Key], []}},
      #{stack => [{crypto, sign, [eddsa, none, <<"message">>, [Seed, ed25519]],
                   [{file, "crypto.erl"}, {line, 1}]}]}],
    lists:foreach(fun(Report) ->
        Encoded = iolist_to_binary(quod_log_formatter:format(
          #{level => error, msg => {report, Report},
            meta => #{time => 0, ns => <<"test">>, identity_key => Key,
                      nested => #{<<"server_private_key">> => Seed}}}, #{})),
        Decoded = json:decode(Encoded),
        ?assertEqual(<<"error">>, maps:get(<<"level">>, Decoded)),
        ?assertEqual(<<"test">>, maps:get(<<"ns">>, Decoded)),
        ?assertEqual(nomatch, binary:match(Encoded, Seed)),
        ?assertEqual(nomatch, binary:match(Encoded, <<"ECPrivateKey">>)),
        ?assertNotEqual(nomatch, binary:match(Encoded, <<"redacted_private_key">>))
    end, Reports),
    ?assertEqual(#{stack => [{crypto, sign, 4, [{file, "crypto.erl"}, {line, 1}]}]},
                 quod_log_formatter:redact(lists:last(Reports))).

format_arguments_and_status_share_structural_key_redaction_test() ->
    Seed = <<"never-print-this-test-key">>,
    Key = #'ECPrivateKey'{version = 1, privateKey = Seed},
    Status = #{state => {state, Key}, message => {unexpected, Key},
               reason => test_crash, log => [#{identity_key => Key}]},
    Safe = quod_prolog:format_status(Status),
    ?assertEqual(test_crash, maps:get(reason, Safe)),
    ?assertEqual({state, redacted_private_key}, maps:get(state, Safe)),
    ?assertEqual(Safe, quod_log_formatter:redact(Status)),
    Encoded = iolist_to_binary(quod_log_formatter:format(
      #{level => error, msg => {"failure ~p ~p", [test_crash, Key]},
        meta => #{time => 0}}, #{})),
    ?assertEqual(nomatch, binary:match(Encoded, Seed)),
    ?assertNotEqual(nomatch, binary:match(Encoded, <<"test_crash">>)).

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
