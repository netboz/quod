-module(quod_log_formatter_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

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
